# Jellyfin transcode share rollout

Status: implemented and validated locally; not deployed. MOTHER activation and
the two guest restarts remain a separate, explicitly approved operation.

## Change

The existing service-state modules now support explicitly uncached cache
subdirectories. Only the `jellyfin` and `transcode-worker` roles opt in, each
with `uncachedCacheDirectories = [ "transcodes" ];`.

| System | Result |
| --- | --- |
| MOTHER | Provision the existing transcode directory with UID/GID 2104; order SOTO/OKAMI VirtioFS services after tmpfiles and require its backing filesystem. |
| SOTO | Mount an extra VirtioFS export, `jellyfin-transcodes`, over `/var/cache/jellyfin/transcodes` with daemon policy `cache=never`; require it before Jellyfin starts. |
| OKAMI | Mount the same backing directory at the same path using its own uncached VirtioFS connection. |

This adds **two daemons total**. Both exports point directly at
`/state/services/cache/jellyfin/transcodes` on MOTHER. The generated source
contains the existing harmless `/./` path component from `state.paths.cache`.
The parent cache bind mounts, database storage, other guests, UID/GIDs, media
paths and package pins are preserved. No file migration or application wrapper
is involved. Database storage retains `cache=auto` and shared mmap support.

## Local validation

- All eight NixOS systems and all flake checks evaluate with
  `nix flake check --no-build --no-write-lock-file --option builders '' --max-jobs 0`.
- All six infrastructure contract suites pass, including ten new cache-share
  contracts covering real host/guest modules and service/path/ownership overrides.
- The disposable VirtioFS runtime test builds and passes. An independent
  `cache=auto` control reproduces stale zero-byte metadata; the uncached
  connections observe writes, replacements and deletions immediately in both
  directions. SQLite WAL works on the actual cached database mount definition.
  Real FFmpeg fMP4 output has a complete, nonempty initialization file when a
  later segment becomes visible.
- An eight-system configuration comparison against the immutable pre-edit
  source shows only the new tmpfiles rule, two shares/mounts and Jellyfin's new
  mount dependency. A separate generated-unit comparison shows only the two
  intended VirtioFS instance dependency additions on MOTHER; the template is
  unchanged. Every VM still has `restartIfChanged = false`, and existing VM
  directories still prevent initial-install units from replacing their runners.
- Full MOTHER/SOTO/OKAMI closure evaluation and build dry-run pass. Full
  production closures have **not** been built locally: the dry-run required
  1,212 derivations and 3.8 GiB of downloads (15.5 GiB unpacked). The runtime
  regression was built separately with local builders only.

Commands for the contract and runtime checks are in
[`tests/infra/README.md`](../tests/infra/README.md). Session evidence is under
`/tmp/jellyfin-transcode-fix/`, including before/after snapshots, generated host
units, the complete evaluation log and runtime build log. The successful runtime
artifact is
`/nix/store/vlpi0z2b750wha482hhhnm06rsmbxmdv-vm-test-run-infra-cache-shares-runtime`.
The original incident evidence is described in the
[investigation](jellyfin-violent-cop-2026-09-10.md).

The current checkout also has pre-existing log-digest/llama/dashboard changes.
They were preserved. Review and select this fix separately before archiving the
deployment source; the existing `infra` tool archives the selected source tree,
including other local edits. A patch containing only this task's changes is
provided at `/tmp/jellyfin-transcode-fix/transcode-fix.patch` (paths relative to
the dotfiles repository root). Do not assume a successful local evaluation is a
comparison with the currently deployed generation.

## Deployment sequence

Use one reviewed immutable source and the existing `infra` deployment tooling.
Keep the pins fixed. Build the MOTHER closure and both guest runners before
starting the maintenance window. Record/root the current MOTHER generation and
both guests' booted runners, as the existing deadman mechanism does.

1. Pause playback and wait for active transcodes to finish. Check current host
   health, generation drift and available resources for two more daemons. Run
   MOTHER's candidate `switch-to-configuration dry-activate` and review its unit
   changes. These production checks have not been run in this implementation.
2. **MOTHER first** (`infra deploy mother --keep-deadman`), retaining recovery through
   fresh SSH, router/vsock, DNS and failed-unit checks. Confirm the backing
   directory exists with the expected ownership and both VirtioFS drop-ins have
   the new dependencies. The evaluated restart/install policies preserve
   existing runners; verify that the live activation agrees with the dry run.
3. **OKAMI next**, installing the candidate `microvm.declaredRunner` and restarting
   the VM through `infra deploy OKAMI --keep-deadman`.
   Confirm its transcode path is a separate `virtiofs` mount with source
   `jellyfin-transcodes`, and its host daemon uses `--cache=never`.
4. **SOTO last**, installing its candidate runner and restarting via
   `infra deploy SOTO --keep-deadman`. Confirm the same mount/daemon policy, the cached database
   mount, Jellyfin health, and access to the worker. The worker is now ready when
   Jellyfin starts. A guest-only `nixos-rebuild switch` cannot add the required
   VirtioFS device to an already running VM.
5. Enable the affected client's fMP4 preference and start a fresh playback of
   Violent Cop. Verify the initialization request has a nonzero body, playback
   advances, seeking works, and no new Content-Length mismatch appears. Check
   both guests and host health before resuming normal use and disarming recovery.

Do not resume playback between guest updates: both sides must use the new
mounts. This rollout includes VM interruptions but requires no MOTHER reboot
for the storage change itself. A host switch alone does not update already
installed guest runners in this infrastructure.

## Rollback

Stop new playback, restore each saved guest runner and restart the affected VMs
using the existing recovery procedure. Restore MOTHER's saved system generation
if needed. Host generation rollback does not itself restore independently
updated guest runner links. Keep the saved runner roots until application
verification is complete.

No data conversion needs undoing: old and new runners use the same backing
directory. Restoring the old runners restores cached access and therefore the
original visibility bug; the client's fMP4 preference can be disabled as the
temporary workaround. Do not remove the backing directory during rollback.
