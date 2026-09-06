# Shared infrastructure simplification

## Constraints

- Keep one VirtioFS **state** share per stateful VM, with host staging bind
  mounts and guest bind mounts. The separate read-only store share remains.
  Many concurrent VirtioFS shares previously caused host failures; direct
  per-service shares are explicitly excluded from this roadmap.
- Preserve current state locations, ownership, permissions, shared media and
  transcode paths, VM IDs, addresses, SSH identities, and package pins during
  structural refactors. Treat intentional behavior changes as separate steps.
- MOTHER and MAMORU carry the recovery/network path. DARE supplies DNS. A local
  evaluation is not evidence that any of these machines is safe to activate.
- Preserve the existing deadman, boot counting, watchdog, and rescue service.
  Do not combine their modification with storage or network migrations.

## Milestones

| Milestone | Scope | Exit evidence |
| --- | --- | --- |
| M0 — Baseline and checks | Capture existing generated settings; provide repeatable local comparisons and focused infrastructure tests. | All eight systems' relevant settings captured; build/evaluation limitations recorded. |
| M1 — One state specification | Derive host staging and guest bind mounts from the same evaluated service configuration. Use a normal guest module instead of configuration-dependent imports. | Existing mount sources, targets, share counts, IDs, modes and service settings match; override tests demonstrate host/guest agreement. |
| M2 — One VM inventory | Consolidate VM identity, network membership, resources, services and extra module references. Remove one-line VM wrappers and list synchronization checks. | Same VM names, autostart order, resources, addresses, MACs, vsock IDs, DNS and firewall output. |
| M3 — Explicit roles and resources | Separate application activation from shared resource access, starting with Jellyfin server/transcode worker. Retire ineffective options and confirmed unused implementations. | Worker/server enablement, credential recipients, media access and remote transcoding tested; every behavior change documented. |
| M4 — Smaller observability modules | Extract dashboards into data files; simplify collection around journal sources and explicit multi-unit services. | Dashboard content preserved; collector and reasoning logs both covered; logging checkpoints/persistence considered explicitly. |
| M5 — Explicit network policy | Name primary networks; centralize endpoints; clarify trusted segments versus per-host restrictions. Preserve existing policy first, then make separately reviewed policy changes. | Network tests cover permitted and denied same-segment/cross-segment traffic, DNS, NAT, management and IPv6. |
| M6 — Scoped deployment and recovery checks | Scope source synchronization and submodules; clarify shared input update effects; test deployment/rollback orchestration. | Evaluations avoid unrelated dotfiles; exact candidate activation and fresh-connection health checks verified; failure paths retain rollback. |

Keep milestone scopes reviewable using the contracts and evidence below. Complete local implementation
and verification before a rollout; record local and deployed status separately.
M6 recovery checks are a prerequisite to any activation whose impact cannot be
bounded using the existing deployment tooling.

## Rollout gates

1. Keep flake locks unchanged during structural work. Compare the candidate
   against the recorded source baseline, then check the currently deployed
   generations read-only before rollout. Investigate existing drift.
2. Run focused tests and evaluate all systems. Build the exact candidate before
   activation; keep its closure and the known-good rollback runner/generation
   rooted. Disable remote builders for checks intended to stay local.
3. Inspect MOTHER's generated mount units and microVM service dependencies even
   for a nominally storage-only change: changing host units can affect guests.
   Verify old host/new guest and new host/old guest compatibility where rolling
   upgrades depend on it. Do not assume a MOTHER switch leaves guests running.
4. Use NIKKI as the first canary when its host-side prerequisites are already
   compatible. Verify application health, logs, state access and persistence
   after a controlled restart. Then roll through UCHI, SOTO, KAIZOKU and OKAMI
   individually, checking permissions and remote transcoding where applicable.
5. Handle DARE, MOTHER and MAMORU as separate critical activations. Determine
   dependency order for the particular change. Never batch MOTHER and MAMORU
   into one deployment or combine a package update with their refactor rollout.
6. Before each critical activation, verify recovery access, capture the running
   generation/runner, prebuild the candidate, and confirm the rollback timer is
   armed. Use a bounded maintenance window with recovery access available.
7. Confirm the intended generation actually runs. Check fresh inbound access,
   DNS and relevant routing/NAT paths before disarming. MAMORU also needs a
   successful vsock probe from MOTHER. An old SSH connection or outbound ping
   alone does not establish that inbound recovery works.
8. Stop the rollout on a failed or ambiguous check; retain rollback. Record
   generation IDs and observations after each successful activation.

## Progress (2026-09-06)

| Milestone | Local status | Deployment status |
| --- | --- | --- |
| M0 | Baseline snapshots and repeatable contracts complete. | Pre-rollout NIKKI matched the original baseline; host/guest generations captured read-only. |
| M1 | Shared state layout complete; nine contracts pass. | Deployed on MOTHER; existing state paths and all guest processes preserved. |
| M2 | One inventory supplies identity, resources, services and extra modules; seven contracts pass. | Five full guest derivations remain identical to the baseline. |
| M3 | Explicit transcode-worker resource role; seven contracts pass; confirmed unused implementations removed. | OKAMI rollout passed GPU, service and real remote-transcode checks. |
| M4 | Dashboard data extracted; journal sources simplified; seven contracts pass. | NIKKI canary passed application, persistence and collector-ingestion checks. |
| M5 | Explicit primary networks and endpoint catalog; ten contracts plus fifteen isolated packet checks pass. | Generated network output unchanged; no network policy migration. |
| M6 | Scoped source archives, exact activation, retained rollback option; package build/ShellCheck and sixteen orchestration tests pass. | NIKKI, OKAMI and approved MOTHER activation passed; rollback retained through health checks, then disarmed. |

Manual approval is required before **MOTHER or MAMORU activation**. Local work,
builds, read-only preflight and application VM rollout proceed autonomously.
DARE supplies DNS and deploys separately, with rollback enabled by default.

### Behavior changes

- `transcode-worker` gives OKAMI Jellyfin's shared state/media/identity without
  an inactive Jellyfin daemon unit, controller private credential or log source.
  Actual remote transcoding target activation remains enabled.
- NIKKI now collects `logDigest-collect.service` alongside the reasoning unit.
  Digest topology metadata describes the actual worker role on OKAMI.
- VM primary networks are explicit and insensitive to list ordering.
  `routedFrom` names the existing cross-segment grants; same-segment trust,
  management access and IPv6 policy are preserved.
- The CLI transfers an immutable Nix source archive instead of rsyncing the
  dotfiles checkout. Pin updates distinguish host, fleet and shared inputs.
  Application batches exclude the router and DNS. Generation checks apply to
  every VM; `--keep-deadman` retains rollback for application/network checks.
- Unused machine IDs/options, alternate network implementations, VM wrappers
  and the unreferenced rffmpeg subflake were removed. Active flake locks and
  package pins remain unchanged; the removed subflake's lock is removed too.

### Local evidence

- Baseline commit: `98dcb437b57edb761eb96a950bc26a50a9cf13af`.
- Immutable baseline: `/nix/store/f5jlffgn8gqciylvnz1d462fxzppzgr3-source`.
- The final selected snapshots for all eight systems preserve filesystems,
  staging/share layout, identities, resources, autostart, networkd text,
  firewall/NAT, sysctls and recovery settings. Exceptions are the intended
  removal of OKAMI's inactive Jellyfin unit and an ordering-only change to two
  independent OKAMI tmpfiles directory rules (same paths and permissions).
- Complete derivation paths for DARE, MAMORU, UCHI, SOTO and KAIZOKU are identical
  to the original baseline. NIKKI's intended logging changes alter its closure.
  Complete MOTHER/OKAMI evaluation also passes after two existing Wolf IFD
  source derivations are materialized. Both full closures subsequently built successfully on MOTHER with two local
  jobs and remote builders disabled; no host activation was performed.
- Dashboard derivation paths are identical to the baseline. Vector changes
  are limited to the intended collector/worker changes.
- Forty configuration contracts, sixteen deployment orchestration tests and
  fifteen actual IPv4/IPv6 packet cases pass. The deployment package builds with
  ShellCheck. Packet tests use disposable rootless namespaces and the actual
  generated MAMORU rules, with no production network changes.
- Full `infra check` passes, including all eight NixOS configurations and
  every flake check derivation. The CLI permits cached IFD evaluation with
  both local and remote builds disabled.
- NIKKI's exact runner builds locally. Its candidate fstab matches the running
  baseline; closure comparison reports no package version changes.
- Reproduction and limitations: `../tests/infra/README.md`. Session artifacts
  are in `/tmp/infra-simplification/`; that directory is not permanent evidence.
- The first baseline evaluation triggered the configured remote builder through
  existing Wolf IFD and was interrupted. Subsequent local checks disabled
  remote builders. Full builds use caches and bounded local jobs after dry-run
  inspection; `--offline` is reserved for evaluation with IFD disabled.

### Rollout record

- MOTHER preflight: running
  `/nix/store/zq9isd5bpzhr8vyhk8ndibmg7dikqb97-nixos-system-MOTHER-26.11.20260606.a799d3e`.
  No recovery timers were armed. Existing failed units were `fwupd-refresh`
  and `btrfs-scrub-images`. The latter reported an overlapping scrub/cancel
  timeout; the scrub finished with no errors and all device error counters
  were zero. No storage repairs or unit resets performed.
- NIKKI source: `/nix/store/59j3pgr6lq9qg9s000m2h6mqryx2jknx-source`.
- Previous runner: `/nix/store/40r0q13k36mm63j9v2p1vmrq0a47v1ly-microvm-qemu-NIKKI`.
- Candidate runner: `/nix/store/shdqvi6shmdgf36vgsq81prvz9aydxlp-microvm-qemu-NIKKI`.
- Candidate system:
  `/nix/store/gqx0ilwzjlz7d175l7xan366dwvdqndc-nixos-system-NIKKI-26.11.20260606.a799d3e`.
- Activated only NIKKI using `--keep-deadman`. The exact runner/system are
  verified; Grafana, Loki, Prometheus and Vector are active, readiness endpoints
  respond, mounts and owners are preserved, historical monitoring/digest data
  remain available. Loki initially returned its startup readiness delay and
  became ready on the subsequent check. The collector completed successfully and its
  `logDigest-collect.service` stream appeared in Loki. The canary timer and
  service are now inactive; the previous runner remains rooted for recovery.
- UCHI, KAIZOKU, DARE and MAMORU candidate runners match the currently running
  runners exactly and need no restart. SOTO has pre-existing deployment drift:
  its original baseline and refactored runner are both
  `/nix/store/q6pxv4pq9x03wwk8l7rlsda1yr6rqwpk-microvm-qemu-SOTO`, while production
  runs `/nix/store/hddq52vs07pyqk7djz4r2lbrv7shziba-microvm-qemu-SOTO`. Reconcile
  that separately before rolling SOTO; no SOTO activation performed.
- MOTHER and OKAMI also have pre-existing baseline-to-production drift:
  original baseline system outputs are `az38zm7bww0awhq44mbq37xm08ag4428`
  (MOTHER) and `wz4czrdkn92vbqxbqk8y6yqxwvv58wgf` (OKAMI), while pre-rollout production
  ran `zq9isd5bpzhr8vyhk8ndibmg7dikqb97` and `p8q76vfw423kkx1wzpbvcavkn6mngqv6`.
  Built closure/unit comparison is complete. OKAMI's additional SSH change
  is the existing okuri package update; its target/runtime source is unchanged
  and the real transcode check passes. MOTHER's dry activation reports only a
  D-Bus reload and polkit restart, explicitly leaving changed VM units running.
- MOTHER was subsequently activated with explicit user approval, as recorded
  below. MAMORU remains unchanged; its future approval gate remains in place.

### Completed OKAMI rollout and host preparation

- OKAMI source: `/nix/store/iplv96k4hx66qsknnjr8m2hd36qxbh9m-source`.
- Previous runner: `/nix/store/31jnz1qwlh8lzqz4ycd42469mdg1qins-microvm-qemu-OKAMI`.
- Running runner: `/nix/store/2pf4yx75qc66j9grna7z3kmxphpa01zy-microvm-qemu-OKAMI`.
- Running system:
  `/nix/store/x856h1f9dflns0rqvr1sa56ppj4qgcac-nixos-system-OKAMI-26.11.20260606.a799d3e`.
- Wolf has no active sessions and its API responds; NVIDIA GPU is available.
  Llama was explicitly started to restore its pre-restart running state and
  passes `/health`; it intentionally does not autostart, and its window and
  watchdog timers remain enabled. No failed units. State/share mounts and
  ownership are preserved; the unused Jellyfin controller credential is absent.
- SOTO's existing Jellyfin user/key successfully ran `okuri check` and encoded
  a synthetic one-second 720p video on OKAMI using `h264_nvenc`. The resulting
  file was visible on SOTO through shared transcode storage with Jellyfin
  ownership, probed successfully, and deleted. The initial test's 128x128 frame
  was below NVENC's supported minimum; the supported 720p test passed.
- OKAMI's deadman timer is disarmed after those checks; its old runner remains
  rooted for recovery. NIKKI and OKAMI completed the application rollout before MOTHER activation.
- MOTHER candidate source: `/nix/store/rlmzzhfxwjdmqfmb0a3wi9g35zwfbxz2-source`.
- MOTHER candidate system:
  `/nix/store/k1hlryx3c872k83ikljcbn38bycqnyf6-nixos-system-MOTHER-26.11.20260606.a799d3e`.
  Both are rooted as `infra-review-source` and `infra-review-MOTHER`.
- MOTHER dry activation passes: D-Bus reload, polkit restart, no changed VM
  restarts. Existing `updateFlake` installs only absent VM directories; current
  runners are preserved. Staging units/network output remain unchanged.
- Fresh VPN (`mother.lan`) and Tailscale (`mother`) SSH probes succeed. Public
  `https://jellyfin.daddyz.myaddr.io/` returns its normal HTTP 302. The legacy
  `mother_extern` alias (`daddyz.myaddr.tools:9545`) times out and is not treated
  as a recovery path.

### Completed MOTHER rollout (2026-09-06)

- The user explicitly approved activation of the reviewed candidate. Deployment
  used the immutable source above and `--keep-deadman`; the 30-minute rollback
  was armed before switching. MOTHER runs the exact approved `k1hlryx...`
  system, and the system profile points at that same generation.
- Actual activation reloaded D-Bus and restarted polkit, matching the dry run.
  All seven VM process IDs, active-start timestamps and booted runner paths
  are identical before/after activation. No guest was restarted or upgraded by
  the host switch. MAMORU remains on its original, already-identical runner.
- Fresh VPN and Tailscale SSH sessions reach the new generation; the vsock leg
  from MOTHER to MAMORU reaches the expected router generation. Direct UDP DNS
  queries to DARE resolve both `nikki.lan` and `example.com`. Public Jellyfin
  HTTPS returns HTTP 302. Grafana, Loki, Prometheus, Vector, Wolf and llama
  health checks pass; shared monitoring and GPU-service state is accessible.
- MOTHER reports `running` with no failed units after activation. The old scrub
  incident remains documented above; this refactor did not change scrub policy.
- After all checks passed, only MOTHER's deadman timer was stopped. Primary and
  second-stage timer/service states are all inactive. The previous host system
  `/nix/store/zq9isd5bpzhr8vyhk8ndibmg7dikqb97-nixos-system-MOTHER-26.11.20260606.a799d3e`
  remains rooted at `/nix/var/nix/gcroots/infra-deadman-MOTHER` for recovery.
- Session evidence: `mother-approved-preflight.txt`, `mother-deploy.txt`,
  `mother-postflight.txt`, `mother-tailscale-vsock.txt`, application health
  outputs and `mother-disarmed.txt` under `/tmp/infra-simplification/`.

### Completed SOTO rollout (2026-09-06)

- The user requested deployment of the previously deferred controller changes.
  SOTO was deployed from the reviewed immutable source
  `/nix/store/rlmzzhfxwjdmqfmb0a3wi9g35zwfbxz2-source` with `--keep-deadman`.
- Previous runner: `/nix/store/hddq52vs07pyqk7djz4r2lbrv7shziba-microvm-qemu-SOTO`.
- Running runner: `/nix/store/q6pxv4pq9x03wwk8l7rlsda1yr6rqwpk-microvm-qemu-SOTO`.
- Running system:
  `/nix/store/cdm00zcnai2pr52hm29k0dj5cwb0vj26-nixos-system-SOTO-26.11.20260606.a799d3e`.
- Jellyfin remains version 10.11.11 with the same server identity and completed
  setup. Its filesystem table is unchanged. The service now uses the Jellyfin
  wrapper containing the updated okuri controller; startup logs confirm the
  expected ffmpeg path. Jellyfin, nginx, seerr and Vector are active, and SOTO
  reports `running` with no failed units.
- All 49 okuri unit tests pass. Runtime tests as the Jellyfin user extract both
  subtitles and attachments locally from a synthetic input in SOTO's private
  `/tmp`, with routing logs confirming local execution. A separate one-second
  720p test dispatches to OKAMI and produces `h264_nvenc` output, visible on
  SOTO through shared transcode storage with Jellyfin ownership and verified
  through ffprobe. All temporary fixtures are removed.
- Public Jellyfin `/health` returns `Healthy`; Jellyfin and Requests web pages
  both return HTTP 200 after their normal redirects. Media-directory access,
  persistent Jellyfin database, state mounts and directory ownership pass.
  These are service/API and synthetic media-pipeline checks, not an
  authenticated interactive playback session.
- SOTO's timer and rollback service are inactive after successful checks. Its
  previous runner remains rooted at `infra-deadman-SOTO` for recovery.
  MOTHER and MAMORU generations are unchanged by this deployment.
- The previously recorded SOTO deployment drift is resolved. Session evidence
  is under `/tmp/infra-simplification/soto-*`, including preflight, reviewed
  diff, deployment, unit tests, extraction, GPU, final health and disarm logs.

### Follow-up work

1. MAMORU already runs the exact refactored runner; no activation is needed.
   Preserve its manual approval gate for any future actual change.
2. Recovery orchestration is covered by failure tests and live arming/disarming
   on NIKKI, OKAMI, SOTO and MOTHER. A timed full-host rollback drill has not
   been performed. The original watchdog, boot counting and rescue behavior
   remain.
