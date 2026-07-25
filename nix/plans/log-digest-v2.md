# logDigest v2 — grounded evidence, real tool-calling, bounded GPU window

> **Status: implemented and verified end-to-end against the live fleet on 2026-07-25.**
> See "What the build changed about this plan" at the end — several conclusions here
> were contradicted by measurement and the code follows the measurements, not this doc.

## Context

`services.logDigest` produces fluent, confident, and largely fictional digests. The
model is not the problem — it is being handed a statistically meaningless sample and
asked to narrate it, and half the GPU budget is spent on planning decisions the
Python then discards.

Measured on the live system (Loki on NIKKI, llama-cpp on OKAMI):

**The input is a 3.7-minute sample presented as 24 hours.** `maxLinesPer = 200` with
`direction=backward` and no server-side filter means the headline query
`{vm=~".+"}` + `priorityMax=4` returns the 200 most recent lines fleet-wide, spanning
3.7 minutes. Composition right now: 108 lines of Loki logging about itself, 34
MAMORU firewall, 27 seerr, 31 assorted. After the client-side PRIORITY filter,
**34 lines survive, 100% MAMORU firewall**. Real 24h volume is ~87,000 lines.

Fleet-wide, the *only* source logging at PRIORITY≤4 is the MAMORU firewall
(16,343/day), so that query structurally cannot surface anything else. Meanwhile
`seerr` (8,743/day), `grafana` (1,991/day) and `prowlarr` (716/day) are never queried
at all, and `loki`'s own `level=info` housekeeping (55,275/day — `index_set.go`,
`tables_manager.go`, `recalculate_owned_streams.go`) is 63% of all fleet log volume
and crowds out every sample.

**This shows up in the output as invented narrative.** Jul 23: *"OpenSubtitles API
failure resolved"* → Jul 24: *"the previous resolution has reversed"*. Jul 23:
*"Wolf service activity resumed, silent for 35 days"* → Jul 24: *"Wolf has gone
silent"* — Wolf logs 126 lines/week, steadily, and Loki retention is 168h so "35
days" is unknowable. Every per-service section reports exactly `200 lines`, the
truncation constant, as if it were a measurement.

**52% of GPU time is spent on discarded output.** Jul 25 run, from the service journal:

| Call | Wall | Outcome |
|---|---|---|
| planner 1 | 63s | said *finalize* → overridden, code bootstrapped 6 queries |
| planner 2 | 39s | said *finalize* → overridden, forced 5 refinements |
| planner 3 | 42s | said *finalize* → overridden, forced 5 refinements |
| planner 4 | 52s | hit round cap |
| summary | 99s | used |
| memory | 85s | used |
| | **380s GPU**, 12s Loki I/O | |

All four planner calls said finalize; `min_query_rounds_when_changed` overrode three
and ran mechanically-generated `|= "<needle>"` queries from `extract_focus_needle`'s
hardcoded string list instead.

**The prompt shape defeats llama.cpp's KV cache.** Each round rebuilds the prompt at a
different compaction level (2, 4, 5, 5…), so the prefix never matches:

```
W slot update_slots: forcing full prompt re-processing due to lack of cache data
W slot update_slots: erased invalidated context checkpoint (pos_min = 11791 ...)
I slot print_timing: prompt eval time = 62536 ms / 13808 tokens (220.80 tok/s)
I slot print_timing:        eval time = 135299 ms /  2066 tokens ( 15.27 tok/s)
```

Measured hardware rates: **prefill 220 tok/s, decode 15–30 tok/s** (degrades with
context length).

**Other findings:** context window is 196,608 tokens but the summary prompt is capped
at 36,000 chars (4.6%); the planner is explicitly forbidden from using
`count_over_time`, `sum`, `topk`, `rate`, `| json` — every LogQL feature that yields a
real number; llama-cpp serves nothing but logDigest (7d of traffic: two bursts, both
digest runs); `node_exporter` already exports 580 `node_systemd_unit_state` series
per VM plus filesystem/memory/PSI, none of which the digest can see.

**Outcome intended:** digests grounded in exact fleet-wide aggregates and a real 7-day
baseline; a genuinely agentic read-only loop; and GPU use cut from ~6.5 min/day to
~2–3 min/day inside a hard 03:25–03:50 window.

## Target architecture

Two phases, split on the GPU boundary.

**Phase A — collector (no GPU, hourly).** Pure Python. Deterministic aggregate queries
against Loki and Prometheus. Writes an evidence pack and appends to a rolling
baseline in `/var/lib/logDigest/`. ~30s, zero GPU. Running it hourly costs nothing and
gives the daily digest 168 real samples to compare against instead of yesterday's
random 200 lines.

**Phase B — reasoning (GPU, once daily, hard-bounded).** Agent loop over the evidence
pack plus live read-only drill-down tools, then one synthesis call. Budget enforced in
*measured GPU milliseconds*, not wall clock.

Going properly agentic **reduces** GPU: a tool call is ~60–100 decode tokens against
the current 1,800-token JSON planning blobs, and an append-only transcript gets KV
prefix cache hits instead of forced full re-prefill.

## Phase A — collector

New `collect` subcommand in `lib/log-digest-agent.py`.

Per run, for each `(vm, service)` pair discovered via `/loki/api/v1/labels`:

- `sum by (vm, service) (count_over_time({...}[1h]))` — exact volume, no sampling
- `sum by (vm, service) (count_over_time({...} | json | PRIORITY <= 4 [1h]))` — real
  error/warn counts, filtered **server-side**
- top signatures per service: sample a bounded window, normalize messages (strip
  timestamps, UUIDs, IPs, hex, line numbers) into a signature, count by signature

From Prometheus (`http://127.0.0.1:9090`, NIKKI-local):

- `node_systemd_unit_state{state="failed"} == 1` — failed units fleet-wide (unused today)
- `node_filesystem_avail_bytes` + 7d `deriv()` — days-to-full projection
- `node_memory_MemAvailable_bytes`, `node_pressure_*_waiting_seconds_total`
- `node_boot_time_seconds` — unplanned reboot detection
- `up` — scrape failures

Persist to `/var/lib/logDigest/`:

- `baseline.jsonl` — one compact record per hourly run, 7d rolling, pruned on write
- `evidence-<date>.json` — the daily pack handed to Phase B
- `digest-<date>.md` — durable output, outside Loki's 168h retention

The daily pack computes, in Python, what the model currently burns decode tokens
guessing at:

- 24h totals per `(vm, service, priority)` vs **7d median and MAD** (robust — log
  volumes are heavy-tailed, mean/stddev is wrong here), flagged when `|z| > 3`
- signatures that are genuinely new vs the 7d window (not "fell out of a top-8 sample")
- signatures that stopped, with the count they used to have
- disk projections, failed units, reboots, scrape gaps

**Noise handling:** a `noiseSelectors` option excludes known-inert high-volume streams
from fleet-wide aggregates. Seed with Loki self-logs and MAMORU firewall drops — both
still get a one-line volume summary and are re-surfaced only on a structural change
(new `unit`, new drop reason, order-of-magnitude shift), never as prose.

Separately: set Loki's `log_level: warn` in `config/infra/services/observability.nix`.
That removes 55k lines/day of `level=info` housekeeping — 63% of fleet log volume — at
no loss.

## Phase B — bounded agentic loop

Replace the planner/summary/memory chain with a single append-only tool-calling
conversation. llama-server already runs with `--jinja`, so OpenAI-style `tools` work.

**Tool surface — read-only by construction. There is no privileged path to remove;
that is the safety boundary, not a prompt instruction.**

| Tool | Purpose |
|---|---|
| `logs_count(selector, by[], window, step?)` | exact `count_over_time` aggregates, instant or series |
| `logs_sample(selector, limit, start?, end?)` | actual lines, capped |
| `logs_labels(label?)` | `/labels` and `/label/{n}/values` — lets it *discover* the fleet |
| `metrics_query(expr)` | Prometheus instant |
| `metrics_range(expr, step)` | Prometheus range, downsampled to ≤60 points |
| `history(kind, days)` | prior digests and baseline records from `stateDir` |
| `note(key, text)` | scratchpad; stays uncompacted in the transcript |
| `finish(findings)` | terminal |

No write, no exec, no shell. The digest gains a `suggested_actions` section — concrete
commands rendered for the operator, never executed.

**Budgeting.** llama-server returns a `timings` object per response
(`prompt_ms`, `predicted_ms`). Sum those across calls — that is *measured GPU compute
time*, not wall clock, and not an estimate. Stop issuing tool calls when
`gpuBudgetSeconds - synthesisReserveSeconds` is exhausted; always keep the reserve so a
truncated investigation still produces a digest. `maxToolCalls` is a backstop only.

**Cache discipline.** The transcript is append-only: system prompt + evidence pack are
built once and never rebuilt. Tool results append. This is what makes prefill nearly
free after the first call — and it is exactly what the current levelled-compaction
approach destroys.

**Token-efficient tool results.** Render as compact tables, not JSON with repeated
keys (3–5× fewer tokens). Truncate to `toolResultMaxChars` and say so explicitly when
truncated, so the model can narrow rather than silently reason on a fragment.

**Thinking.** Currently `enable_thinking: False` on every call including synthesis.
Invert: off for tool-selection turns (mechanical), **on for the single synthesis
call** — paid for by the 196s reclaimed from the discarded planners.

**Rolling memory** folds into the synthesis call's output schema rather than a separate
85–133s call. Keep the `content_sha256` staleness check.

**Failure handling.** Empty or unparseable synthesis is a hard failure that writes a
stub digest recording the failure — never a silent success with empty arrays.

## GPU window

llama-cpp serves nothing but logDigest, so it can be hard-bounded.

In `config/infra/services/llama-cpp.nix` (guarded by `svc.hasService "llama-cpp"`,
so it lands on OKAMI):

```nix
systemd.services.llama-cpp.wantedBy = lib.mkForce [ ];   # never auto-start

systemd.services.llama-cpp-window = {
  description = "Bounded GPU window for llama-cpp";
  serviceConfig = {
    Type = "oneshot";
    RemainAfterExit = true;
    ExecStart = "${pkgs.systemd}/bin/systemctl start llama-cpp.service";
    ExecStop  = "${pkgs.systemd}/bin/systemctl stop  llama-cpp.service";
    RuntimeMaxSec = "25min";        # hard ceiling
  };
};

systemd.timers.llama-cpp-window = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnCalendar = "03:25";
    Persistent = false;             # a missed window must NOT fire at boot
    AccuracySec = "1s";
  };
};
```

Schedule (host TZ is `Europe/Stockholm`, set in `common/vm-common.nix`):

| Time | Unit | GPU |
|---|---|---|
| hourly | `logDigest-collect.service` | none |
| 03:25 | `llama-cpp-window.service` starts llama-cpp | model loads |
| 03:30 | `logDigest.service` (reasoning) | ~2–3 min |
| 03:50 | `RuntimeMaxSec` stops llama-cpp unconditionally | released |

`OnCalendar = "03:30"` is local wall clock, so it stays 03:30 across DST. If you want a
fixed UTC offset year-round instead, use `OnCalendar = "02:30 UTC"`.

**Two landmines to remove — both currently make a fixed window impossible:**

1. `gpuBusyRetryDelay = "4h"` / `gpuBusyRetryCount` (`lib/log-digest.nix:206-216`) —
   sleeps 4h on a context error and retries at an arbitrary hour. It can also never
   succeed, because `TimeoutStartSec = "1h"` kills the unit first. Delete.
2. `Restart = "on-failure"` + `RestartSec = "360s"` on a `oneshot`
   (`lib/log-digest.nix:343-344`) — if llama-server is unhealthy this retries **every
   6 minutes indefinitely**, each retry a fresh GPU wake. Replace with `Restart = "no"`;
   fail, log, retry tomorrow.

Set `RuntimeMaxSec = "18min"` on the reasoning unit so it can never outlive the window.

## File-by-file

**`lib/log-digest-agent.py`** — restructure into `collect` / `reason` subcommands.

*Keep and reuse:* `http_json`, `push_digest`, `fetch_latest_digest`,
`normalize_whitespace`, `compact_text`, `extract_json_text`, `sha256_text`,
`render_summary_markdown` (extend with `suggested_actions`), `parse_duration`,
`strip_think_wrappers`.

*Delete:* `UNSUPPORTED_FOLLOWUP_QUERY_TERMS`, `followup_query_support_error`,
`extract_focus_needle`, `build_investigation_leads`, `bootstrap_queries_from_leads`,
`build_refinement_queries_from_round_results`, `normalize_followup_expr` — the
heuristic scaffolding that replaced the model's judgment. Also `compact_snapshot`,
`compact_diff`, `compact_memory`, `compact_investigation_trace`,
`fit_request_to_budget`, `fit_planner_request_to_budget`, `planner_*_view`,
`calc_prompt_char_budget` — levelled compaction is what breaks the KV cache.

*Add:* matrix/vector result parsing for Loki metric queries and Prometheus (the missing
parser is the actual reason metric queries were banned); message-signature
normalization; robust z-score (median/MAD); the tool registry and dispatch loop;
`timings`-based GPU accounting.

**`lib/log-digest.nix`** — remove `charsPerTokenEstimate`, `contextReserveTokens`,
`contextWindowFallback`, `promptBudgetPercent`, `summaryMaxPromptChars`,
`memoryMaxPromptChars`, `investigationPlannerMaxPromptChars`, `maxLinesPer`,
`topRepeatsPerQuery`, `sampleLinesPerQuery`, all `investigation*` caps,
`gpuBusyRetry*`, `runBudgetSeconds`, `shutdownWarningSeconds`, `rollingMemoryMaxChars`.

Add `prometheusUrl`, `stateDir` (`/var/lib/logDigest`), `baselineDays` (7),
`collectOnCalendar` (`hourly`), `reasonOnCalendar` (`03:30`), `gpuBudgetSeconds` (240),
`synthesisReserveSeconds` (90), `maxToolCalls` (24), `toolResultMaxChars` (2000),
`thinkingForSynthesis` (true), `noiseSelectors`.

Split the unit into `logDigest-collect.service` (+ its own timer) and
`logDigest.service`. Keep the reasoning unit named `logDigest` so the state-mount
wiring in `lib/vm-service-state.nix` `mkOne` keeps working; add
`unitConfig.RequiresMountsFor = [ "/var/lib/logDigest" ]` to the collector explicitly.

**`config/infra/service-map.nix:83`** — flip `logDigest` to `managedState = true`. This
is what gets `/state/services/lib/logDigest` bind-mounted into the NIKKI microVM via
`svc.mkMany`; without it the baseline and durable digests do not survive reboot. NIKKI
already mounts `/state` (loki/grafana/prometheus are stateful), so this is additive.

**`config/infra/services/log-digest.nix`** — drop the `logQueries` list entirely; the
collector discovers services from Loki labels. Set `prometheusUrl`, the schedule, and
`noiseSelectors`.

**`config/infra/services/llama-cpp.nix`** — window units above.

**`config/infra/services/observability.nix`** — Loki `log_level: warn`; fix the digest
dashboard's `now-30d` range, which cannot work against 168h retention (either point the
panels at the durable files or drop the range to `now-7d`).

**`lib/daily-llm-journal.nix`** — delete. It is the v1 predecessor of log-digest,
imported by nothing (`grep -rn daily-llm-journal` matches only itself).

## Verification

1. **Collector standalone, no GPU.** `log-digest collect --config ... --dry-run`
   against live Loki/Prometheus. Assert: per-service 24h totals match a direct
   `sum by (service) (count_over_time({vm=~".+"}[24h]))` — the number that today reads
   `200` for every service should now read `1666` for sonarr, `8743` for seerr, etc.
2. **Baseline accumulates.** Run the collector hourly for a day; confirm
   `baseline.jsonl` prunes at 7d and z-scores are finite and sane once ≥24 samples exist.
3. **Offline replay.** `log-digest reason --evidence evidence-<date>.json` against a
   saved pack. This is the iteration loop the current design lacks entirely — prompt
   changes become testable without a `nixos-rebuild` and without waking the GPU.
4. **GPU accounting.** Assert the summed `timings.prompt_ms + predicted_ms` for a full
   run is under `gpuBudgetSeconds`. Target ≤180s against today's measured 380s.
5. **Cache reuse.** Grep the llama-cpp journal during a run for `forcing full prompt
   re-processing`. It should appear at most once (first call), not on every call as now.
6. **Window is hard.** `systemctl list-timers llama-cpp-window`; confirm llama-cpp is
   `inactive` at 03:24 and 03:51, and that
   `sum(count_over_time({service="llama-cpp"}[1h]))` is zero outside the window.
7. **Grounding check.** Take three claims from the first v2 digest and verify each
   against a direct LogQL/PromQL query. The current digest fails this test on nearly
   every claim; that is the bar being cleared.

## Rollout order

Each step is independently shippable and independently revertible.

1. Loki `log_level: warn`; delete `lib/daily-llm-journal.nix`; remove the 4h retry and
   the 6-minute restart loop. *(Immediate, no behaviour change to the digest itself.)*
2. `managedState = true`; collector + baseline, still writing today's prompt shape.
   Verify the numbers are real before touching the model.
3. Rewrite the reasoning phase as the tool-calling loop with GPU-ms budgeting.
4. Move the schedule and add the window units.
5. Durable-file delivery and dashboard fix.

## What the build changed about this plan

Measured during implementation. Where these conflict with the sections above, the code
follows these.

**Severity had to become content-based.** `PRIORITY <= 4` returns 16,388 firewall drops
and nothing else fleet-wide — the .NET/Java/Go services all log at PRIORITY 6 with
severity in the message text. A content regex finds ~431 real events/day, few enough to
capture exhaustively with no sampling. This is now the primary signal, PRIORITY only
escalates.

**Thinking for synthesis was wrong, then right.** At the measured ~18 tok/s decode a
thinking pass consumed the entire 2,600-token allowance and emitted no digest at all.
Raising `synthesisMaxTokens` to 5,000 and the budget to 900s made it work, and it is
what merges causal chains: with thinking off the digest reported the nekoBT outage as
three separate findings; with it on, one finding with the root cause named and the
downstream effects listed. Kept on, with an automatic no-thinking retry.

**The GPU budget was sized far too small.** 240s inside a 25-minute window left most of
it idle. Now 900s. The window is a fixed daily cost once opened, so under-using it buys
nothing.

**Three bugs the plan did not anticipate:**

- *ANSI escapes corrupted signatures.* `ESC[2m` was read as "2 minutes" by the quantity
  rule, turning wolf's logs into noise. Stripped at `message_of`, the single point all
  consumers pass through.
- *Calendar-day bucketing was wrong for a 03:30 run.* A UTC-day bucket held one or two
  hours against full-day medians. Replaced with rolling 24h windows anchored to the run,
  plus a collector-coverage guard so a collector outage cannot look like a fleet anomaly.
- *Truncated tool calls poisoned the transcript permanently.* When llama.cpp hits the
  token cap mid-argument it cannot re-parse that turn, and every later request returns
  HTTP 500 — including synthesis, so the run died with no digest. Fixed at three levels:
  a larger `investigatorMaxTokens`, canonical re-serialization of arguments, and a
  synthesis fallback that rebuilds a clean transcript-free prompt.

**Disk projections needed hard gating.** A 6h `deriv()` read Loki compaction as a trend
and reported 4.8 days-to-full on a half-empty 466 GiB volume; the same filesystem read
48 days over 24h. Now 24h, only projected above 60% used, and deduplicated by device
because every service bind mount was being counted separately (68 series → 18).

**Verified end-to-end.** A real run produced three findings: the nekoBT indexer outage
with its actual consequence measured (*"RSS syncs report 323-335 releases found but 0
grabbed"*), the failed `recyclarr.service`, and a llama-cpp fault — at 257s GPU of the
900s budget, with 86% KV cache reuse and every claim carrying a verify query.

## Open

- Delivery beyond the durable file — push notification is unresolved. You have no
  notification service today; self-hosted ntfy on NIKKI is the low-friction option.
  Nothing else in the plan depends on this.
- The baseline starts empty, so anomaly, novelty and silence detection stay suppressed
  (and say so in the digest footer) until the hourly collector has run for a day or two.
  The first digests will be weaker than the steady state.
