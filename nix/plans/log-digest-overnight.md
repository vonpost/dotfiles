# Overnight log-digest investigations

Implemented September 2026; supersedes the single-session design in
[log-digest-v2.md](log-digest-v2.md).

The hourly GPU-free collector maintains the signature catalog and baseline. Two
reasoning sessions build fresh evidence, investigate with Loki/Prometheus, and
write a digest each. A durable notebook carries questions between sessions and
later nights. Deferring a question never creates a daytime GPU job.

## Schedule

All times are local to the VMs (currently Europe/Stockholm, matching Amsterdam).

| Time | Work |
| --- | --- |
| Hourly | GPU-free collection |
| Every five minutes, all day | CPU-only observation plans and incident captures |
| 01:25 | First model window opens |
| 01:30 | Investigation and first digest |
| 02:00 | Absolute GPU cutoff |
| 04:25 | Second model window opens |
| 04:30 | Fresh investigation, due follow-ups and another digest |
| 05:00 | Absolute GPU cutoff |

Each session targets 1,200 seconds of model compute, reserving 360 seconds for
synthesis: up to 40 minutes per night, three hours apart. The agent may finish
early. Model residency totals up to 70 minutes, plus up to 15 seconds each for
server shutdown; residency is different from generation time.

The runner accounts for reported prompt/decode timings after every response and
reduces subsequent token caps and HTTP timeouts. Failed requests conservatively
charge elapsed time; synthesis retries share the budget. One response can exceed
the compute estimate. The hard bounds are a 25-minute reasoning deadline,
28-minute systemd timeout including pack preparation, and the GPU window.

The window has a main process that exits after 35 minutes, a runtime backstop five
seconds later, and an independent absolute close timer. The server requires an
already active window and stops with it, including watchdog-restarted workers.
GPU timers never catch up on boot. Runner/collector oneshots use `TimeoutStartSec`:
`RuntimeMaxSec` does not bound oneshot activation, as documented by
[systemd](https://github.com/systemd/systemd/blob/main/man/systemd.service.xml).

Adjust both schedules together in
[llama-cpp-config.nix](../config/infra/services/llama-cpp-config.nix). Budgets and
limits are options in [log-digest.nix](../lib/log-digest.nix), with fleet overrides
in [services/log-digest.nix](../config/infra/services/log-digest.nix).

## Investigation and memory

The model chooses hypotheses, query sequences, comparisons with earlier windows,
downstream checks and recovery checks. `end_ago` shifts query time. Limits are
seven days of lookback, 169 range evaluation points, minimum 60-second steps,
2,000-character expressions, 40 sampled lines, 8 MiB HTTP responses and 30-second
query timeouts. Subqueries need explicit steps; expression `offset`/`@` use
`end_ago` instead. Durations use one `s`, `m`, `h` or `d` unit. Expression lookbacks
are summed conservatively, so large comparisons may need separate queries.

Successful queries get unique evidence references. The exact bounded result,
arguments and observation time are saved, including empty results and truncation
notices. Errors are retained but cannot be cited as successful observations.
Citation validation checks existence; it cannot prove causal interpretations.
Incomplete collection or discarded findings cannot silently produce an all-clear.
Pack preparation does not repeat an overlapping collector hour, which would
inflate the baseline. The model can query logs newer than the hourly catalog.

`/var/lib/logDigest/followups.json` contains up to 24 tasks, each with a question,
hypothesis, next read-only check, priority, historical evidence, earliest revisit
time, attempt count and status:

- `open`: up to six due tasks are highlighted by priority, then oldest check.
- `resolved`: a conclusion supported by fresh evidence and an explanation.
- `needs_human`: missing access/checks, or unresolved after six revisits or 14 days.

The `followup` tool accepts `wait_hours=0` for the next scheduled session or `24`
to wait at least another day. It updates existing IDs and requires current evidence
refs. Historical evidence must be rechecked before making current claims. Tasks
are descriptions; no scheduler executes their text.

Task updates are atomic and independent of synthesis. Notes and query results are
checkpointed after each tool operation, so completed work survives failed summaries
or killed sessions. Only resolved tasks can be evicted from a full notebook.
Corrupt notebook JSON fails visibly instead of resetting memory. Separate
nonblocking locks prevent duplicate runs of each phase.

The latest digest shows outstanding tasks and blockers. Durable files are:

- `digest-latest.md` and `.json`: latest outcome, including explicit failure status.
- `digest-<UTC timestamp>.md` and `.json`: separate reports for both sessions.
- `evidence-<UTC timestamp>.json`: initial pack plus cited query results.
- `trace-<UTC timestamp>.json`: status, accounting, tool results, notes and tasks.
- `followups.json`: notebook, unaffected by 180-day artifact pruning.

The existing Grafana dashboard receives both reports through the fixed Loki
publication path. Older daily filenames remain readable and prunable.

## Daytime observation plans

The overnight model can arrange typed recurring queries and event-triggered
captures with `observation_plan`. This is ordinary Python between sessions: no
GPU requests and no CPU model inference. It evaluates numeric conditions, detects
changes, and follows matching host/service labels into up to four capture queries
for up to three matching contexts. It can collect evidence while an incident is
happening, even if the logs have expired by the next reasoning session.

Built-in watchers check failed systemd units and unavailable Prometheus targets.
They capture nearby error logs, memory availability and uptime for affected VMs.
The model can add up to 20 plans: log counts/samples, instant metrics or metric
histories; comparisons `gt`, `lt`, `eq`, `present` or `changed`; intervals of
5–1,440 minutes; delayed starts and expiry after at most seven days of execution.
`{{vm}}`, `{{service}}`, `{{instance}}` and `{{name}}` placeholders are unquoted
in templates and JSON-quoted by the interpreter using trigger labels. Missing
labels fail visibly. Each plan can collect up to 48 snapshots, with a default
one-hour cooldown for persistent trigger conditions. A condition clearing records
another observation, not a diagnosis of recovery.

Model output is untrusted and fallible. Plan fields, tool names, types, durations,
query bounds and templates are validated before acceptance. Every proposed query
also runs through the real read API before the plan is saved, using dummy label
values for template syntax checks. Backend errors go back to the model for repair;
failed edits preserve the old plan. These validation reads consume the overnight
tool allowance. Invalid JSON/tool calls cannot become executable code. Each
daytime tick revalidates persisted plans; API failures retain errors and back off
up to six hours. Incomplete captures carry warnings, and a failed probe never
turns into a cleared condition. Valid syntax does not establish a correct
hypothesis or that a metric exists; the next model session must assess the data.

The worker runs every five minutes with up to 16 API reads per tick, 2,000 reads
and 96 captures per UTC day, ten-second query timeouts, a two-minute internal
deadline and three-minute service timeout. Quotas are charged before dispatch,
including failed or interrupted work. Identical queries share a result within a
tick. Oldest due plans run first; errors back off. The default watchers alone use
about 576 probe reads per day when healthy. CPU is capped at 25% of one core and
memory at 512 MiB. These limits bound load on the observability services too.

`observation-plans.json` is written only by overnight reasoning. The daytime
service can write only `observations/`, containing its independent runtime/quota
state and immutable timestamped captures. Snapshots are pruned to seven days,
512 files and 128 MiB after each tick. The next reasoning session receives the
latest capture per plan from the past 48 hours and worker warnings. The
`observation_read` tool discovers up to 12 recent captures per plan and reads
individual queries through fixed evidence references, never arbitrary paths.

## Safety boundary

The model has no shell, SSH, arbitrary file/URL access, service control, deployment,
or infrastructure mutation tool. Dispatch uses an explicit allowlist. Queries use
fixed GET API routes; label names cannot escape them. Redirects and environment
proxies are disabled. Logs, labels and historical notebook text are untrusted data.

Intended writes are limited to the agent's own state/reports, model requests to
the configured inference API, and reports to the existing fixed Loki push route.
Neither POST capability is exposed as a model-selectable tool.

All phases run as logDigest with a read-only filesystem except their state and
private temporary storage, no capabilities or privilege escalation, hidden homes,
private devices, protected kernel interfaces, restricted system calls and no Unix
sockets. Network access is limited to loopback and configured Loki/model IPs;
literal IP URLs avoid DNS. Local memory, CPU and process counts are capped.
The observer has a separate config without an inference endpoint, no GPU devices,
and a narrower network allowlist containing only loopback and Loki's IP. It cannot
connect to OKAMI. Its mount sandbox keeps the notebook, plans, baseline and reports
read-only. The worker exposes only the four read query types and never publishes
to Loki or invokes the model.
Read queries still use observability resources, and these restrictions are not a
proof against kernel/API bugs.

## Verification and rollout

Run `PYTHONDONTWRITEBYTECODE=1 python3 tests/infra/test_log_digest.py -v` for offline
behavior tests. The suite is also `checks.x86_64-linux.infra-log-digest`.
Observability contracts cover schedules, catch-up behavior, timeouts, server window
dependencies and all three sandboxes. See [test instructions](../tests/infra/README.md).

Deploy OKAMI (GPU window) first, check it, then deploy NIKKI (agent) through the
normal rollout. They do not require simultaneous activation. If a digest timer
fires between deployments, the old agent may miss its GPU window and fail that
session; its persistent state is retained.
No activation or live GPU run is part of offline verification. After deployment,
check both schedules and the first two traces for task continuity, compute usage,
query errors, useful findings and GPU shutdown outside the windows. Verify major
claims against saved queries. Model quality and hardware release timing require
live observation; synthetic tests cannot establish either.

## Deployment record — 2026-09-07

Deployed sequentially, OKAMI then NIKKI, from immutable source
`/nix/store/1b241sll844cdv3maipb47di26q85lxx-source`. Both exact runners were built
and compared with production before activation; storage layouts are unchanged.
The full flake evaluation passed on MOTHER. An incidental OKAMI SSH command path
change points to byte-identical okuri runtime files.

- OKAMI runner: `/nix/store/0nmfgb6bxryrjy6fga9mbdgyh9ijciqh-microvm-qemu-OKAMI`.
  System: `/nix/store/cywym9hcxp44kpdnvydhx58x6h5fdf3s-nixos-system-OKAMI-26.11.20260606.a799d3e`.
- NIKKI runner: `/nix/store/8qfh2hcb52m4dcjpqama5j93pdy1gn9w-microvm-qemu-NIKKI`.
  System: `/nix/store/lv30cgq6dd463452jkwgb99pa493dg4q-nixos-system-NIKKI-26.11.20260606.a799d3e`.

OKAMI's Wolf API, state mount and GPU pass. A real one-second 720p NVIDIA transcode
from SOTO passed and its fixture was removed. A brief manual window test started
the server, passed `/health`, and verified the server stopped when the window
closed. No inference was requested for that test.

NIKKI's Grafana, Loki, Prometheus and Vector are healthy; Loki's initial startup
readiness delay cleared. The existing catalog, baseline and digest files survived
the restart. A temporary unit copied the deployed digest sandbox and verified
UID 2110, read-only root, denied Unix sockets, state write/read access, successful
Loki/Prometheus queries and an existing-pack dry run without GPU requests. The
temporary unit and probe were removed afterwards.

Both rollback timers were disarmed after health checks; their previous runners
remain rooted. MOTHER was not activated. The new scheduled sessions are 01:30 and
04:30 local time. Model quality, cross-session task continuity and the automatic
deadline shutdown still need observation during scheduled runs.

Session evidence is in `/tmp/log-digest-*-deploy.log`,
`/tmp/log-digest-*-health.log`, `/tmp/log-digest-window-check.log`,
`/tmp/log-digest-transcode-check.log`, `/tmp/log-digest-sandbox-check.log`,
`/tmp/log-digest-live-diff.log` and `/tmp/log-digest-final-rollout.log` on the
operator machine. The local evaluation cache had invalid derivation references;
the complete successful evaluation is `/tmp/log-digest-remote-eval.log`.

## Daytime worker validation — 2026-09-07

Candidate source: `/nix/store/hrckxn7r8dbdsfblmzj4izk7dsx705g8-source`.
The full flake evaluation and all 53 Python tests passed, including the test run
inside the Nix build sandbox. The candidate runner is
`/nix/store/43pknlhwdwcaw5hhsizni8xx2w4v0qzr-microvm-qemu-NIKKI`, system
`/nix/store/9fzaiwdqzb7wj09w4vqk7j3vc3k5f7cb-nixos-system-NIKKI-26.11.20260606.a799d3e`.
VM hardware, networking, shares and fstab match the running generation.

A temporary unit using the exact candidate observer sandbox verified UID 2110,
read-only root and notebook, denied Unix sockets, hidden GPU devices, and blocked
TCP access to OKAMI while that port was reachable outside the sandbox. The filter
drops packets, so the negative test observes a timeout rather than requiring an
immediate permission error. No HTTP request was made on the control connection.

Live Loki and Prometheus rejected deliberately malformed query syntax; correction
allowed the plan to save. All four read query types and every standard capture
expression succeeded. The worker produced three private test snapshots with no
warnings, model calls or POST requests. Temporary units and test state were
removed. This check caught a Prometheus duration-format bug inherited from the
overnight deadline handling: fractional timeouts now use whole milliseconds,
rather than strings such as `30.0s` that the server rejects. A regression test
covers both instant and range queries.

Evidence: `/tmp/log-digest-observer-{eval,build,sandbox}.log` and
`/tmp/log-digest-observer-final-comparison.log` on the operator machine.

The final deployed source is
`/nix/store/ixfsfgh0xszfvr45xjwsvk0wlzn64dvx-source`. It also corrects scheduling
under timer jitter: next checks are anchored to five-minute slots, with one-second
timer accuracy. A regression test first reproduced the skipped-tick failure,
then passed with the fix. All 54 tests pass locally and in the Nix sandbox; full
configuration evaluation passes.

- Final NIKKI runner: `/nix/store/8dd5yzqwha8ahrb4kwc0zmvi2k3v1kkf-microvm-qemu-NIKKI`.
- Final system: `/nix/store/l9ngmxd64gcggsy7jxp6dfidv9bv97dl-nixos-system-NIKKI-26.11.20260606.a799d3e`.

The 01:30 investigation completed before rollout, using 672.3 seconds of reported
model compute and saving its report and four notes. Its five metric-tool failures
were the timeout-format issue fixed above. The new generation retained that report
and existing observation state. Grafana, Loki, Prometheus and Vector passed
readiness checks. The final observer ran at 01:49:37 with two successful reads,
no warnings, 191 ms of CPU time and about 55 MiB peak memory. Its GPU allowlist
exclusion and observation-directory-only write access match the validated sandbox.
The next reasoning session is 04:30; model-created daytime plans will be assessed
when it first uses the new tools.

NIKKI's rollback timer is disarmed after health checks, with the previous runner
retained. OKAMI and MOTHER were not redeployed for the daytime worker. Final
rollout evidence is `/tmp/log-digest-observer-{deploy,health,final-rollout,deployed-unit}.log`.
