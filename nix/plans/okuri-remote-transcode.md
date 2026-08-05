# okuri: replace rffmpeg with a purpose-built remote transcode dispatcher

Supersedes the earlier rffmpeg-cpu-fallback plan. Decision: **replace, not
fork**. Working name `okuri` (送り, "send-off") to fit the fleet naming —
trivially renameable.

## Context

Jellyfin on SOTO (8 vcpu, no GPU) ships transcodes to OKAMI (12 vcpu, VFIO
NVIDIA GPU, also runs Wolf) by masquerading rffmpeg as ffmpeg/ffprobe. The
transcode dir and media are shared via host virtiofs staging, so either VM can
produce segments the other serves.

Why rffmpeg goes away rather than gets wrapped or forked:

- Upstream is unmaintained (~2 years idle). Its bulk — SQLite host/process/state
  DB, weighted least-connections scheduling, imperative `init/add/remove` CLI —
  serves multi-host fleets. This system has one GPU host; all of that is dead
  weight and an ongoing source of state bugs (host list never reconciles after
  init, "bad" markings keyed to caller PID, first-boot races).
- What we actually need, rffmpeg lacks entirely: GPU-aware health checks (its
  check is `ssh host ffmpeg -version` — passes with a wedged driver), CPU
  fallback that *works* (it replays NVENC argv on a GPU-less host), remote
  process lifetime management beyond `ssh -t`, tests.
- Both endpoints are NixOS modules in this repo deploying in lockstep — we can
  define exact controller↔target semantics without compatibility concerns.

## Architecture

Three small components, one flake dir (`okuri/`), all Python 3, stdlib only.

### 1. Controller (SOTO) — `okuri` package, `bin/ffmpeg` + `bin/ffprobe`

argv[0]-dispatched, **stateless** — no DB, no init service. Reads a
Nix-generated JSON config from `/etc/okuri/config.json` (target host, remote
user, ssh key/options, timeouts, fallback policy). Per invocation:

1. ssh to target with `ControlMaster=auto`/`ControlPersist` (socket in
   `/run/okuri`), `BatchMode=yes`, `ConnectTimeout=2`, the existing
   `jellyfin_transcode_ssh_key` credential. **No `-t`**: ffprobe's stdout must
   stay clean for Jellyfin's JSON parsing, and stderr (ffmpeg progress) passes
   through unmerged. Remote command is just `ffmpeg <args>`/`ffprobe <args>` —
   the target's ForceCommand decides what really runs.
2. stdin is piped through and doubles as the liveness channel (see target).
   Signals (SIGTERM/SIGINT from Jellyfin) forward to the ssh child.
3. Exit-code semantics: ssh returns the remote command's status; 255 =
   transport failure. On 255, or connect timeout, **fast-fail local fallback**:
   rewrite argv to software (shared rewriter below) and exec local
   `jellyfin-ffmpeg`. Fallback only when the failure happened before meaningful
   output existed (time threshold, ~15s default); a mid-stream death
   propagates the error and the client's retry lands on a fresh dispatch.
4. Every fallback logs a distinctive WARNING to journald (tag `okuri`) →
   loggingAgent → Loki/NIKKI, alertable in Grafana.

Degraded-GPU-but-VM-up is deliberately NOT the controller's problem — the
target handles it on its own 12 cores (more headroom than SOTO, which is
running Jellyfin/nginx/seerr).

### 2. Target (OKAMI) — ForceCommand wrapper, absorbs today's limited-wrapper

Keeps the current security posture (allowlist ffmpeg/ffprobe by resolved path,
same sshd Match block, key-restricted `from=` clause) and adds:

- **GPU preflight** when argv requests CUDA: `nvidia-smi` alive + optional
  NVENC session headroom + manual override file
  (`/run/okuri/force-software`). Unhealthy → rewrite argv to software and run
  on OKAMI's CPU.
- **Fast-fail GPU retry**: run real ffmpeg; if it dies quickly with a GPU
  signature on stderr (`OpenEncodeSessionEx`, `CUDA_ERROR_*`, `No capable
  devices`, session-limit messages), rewrite → rerun software. Catches what
  preflight can't (per-stream NVENC alloc failures, unsupported profiles).
- **Lifetime management**: spawn ffmpeg in its own process group, watch stdin;
  EOF/HUP (controller died, VM link dropped, Jellyfin killed the dispatch) →
  SIGTERM then SIGKILL the group. No orphaned NVENC sessions — replaces the
  `ssh -t` hack.
- `-version`/`-encoders`/`-hwaccels`/ffprobe pass straight through so
  Jellyfin's capability probing sees the GPU encoders.

### 3. Shared rewriter — one module, unit-tested, used by both ends

NVENC/CUDA argv → software translation (same table as previous plan): strip
`-hwaccel cuda`, `-hwaccel_output_format`, `-init_hw_device`,
`-filter_hw_device`, nvenc-only rate/AQ opts; map `h264_nvenc→libx264`,
`hevc_nvenc→libx265`, `av1_nvenc→libsvtav1`, `-preset p1..p7`→x264/x265
presets; in filter graphs `scale_cuda→scale`, `overlay_cuda→overlay`,
`tonemap_cuda→tonemap`+format fixup, drop `hwupload*`/`hwdownload`/
`format=cuda` links. Unknown constructs pass through untouched and get logged —
the stream had already failed, best-effort can only improve things. Fixture
argvs harvested from `/var/lib/rffmpeg/rffmpeg.log` on SOTO before cutover.

## Nix layout & file changes

- `okuri/` — new flake dir mirroring rffmpeg-nix's shape:
  - `pkgs/okuri.nix` (controller + rewriter, checkPhase runs unit tests)
  - `pkgs/okuri-target.nix` (wrapper + rewriter)
  - `nixos-modules/controller.nix` → `services.okuri` (target host, user, key
    credential, tmpdir, fallback policy; generates `/etc/okuri/config.json`;
    sets `TMPDIR` + tmpfiles like today, minus the init oneshot)
  - `nixos-modules/target.nix` → `services.okuri-target` (sshd Match block,
    ForceCommand, jellyfin user, authorized key option)
  - `tests/` — nixosTest (see below)
- `flake.nix` — swap `rffmpeg-nix` input for `okuri`.
- `common/vm-common.nix` — swap module import + overlay.
- `config/infra/services/jelly-media.nix` — `jellyfin-ffmpeg = pkgs.okuri`
  override (package exposes `bin/ffmpeg`, Jellyfin derives ffprobe from the
  sibling path, same as today); `services.okuri` instead of
  `services.rffmpeg`, hosts still derived from topology `sshJellyfin`
  providers (single target = head of that list; assert if >1 until priority
  ordering is implemented).
- `config/infra/vms/OKAMI.nix` — inline limited-wrapper + sshd block replaced
  by `services.okuri-target.enable` + key.
- Delete `rffmpeg-nix/` in the cutover commit; note `/var/lib/rffmpeg` and
  `/run/rffmpeg` can be removed on the next deploy (tmpfiles `r` rules or by
  hand).

## Policy defaults (changeable, not blocking)

- No Wolf gating: transcodes may use NVENC alongside a game session; the
  session-limit failure path now degrades gracefully. Preflight hook exists if
  reservation is ever wanted.
- Single target host; multi-host = ordered priority list later (10 lines, no
  DB), not least-connections scheduling.

## Testing — the robustness upgrade rffmpeg can't offer

1. Derivation checkPhase: rewriter fixtures (real Jellyfin NVENC argvs, HDR
   tonemap case included) + controller dispatch tests against a mock `ssh`.
2. **`nixosTest` two-node integration test** wired into `nix flake check` /
   `infra check`: controller node + target node with a stub `nvidia-smi` and
   stub ffmpeg recording its argv. Matrix:
   - healthy: dispatch lands remote with untouched argv;
   - GPU dead (stub nvidia-smi fails / force-software file): remote runs
     rewritten software argv;
   - fast GPU failure signature: retry path produces software argv;
   - target down: controller falls back locally with rewritten argv;
   - controller killed mid-stream: remote process group dies (no orphans).
3. Live verification after `infra deploy SOTO` + `infra deploy OKAMI` (dirty
   tree ships; MOTHER untouched, no deadman concerns):
   - baseline transcode → NVENC session visible in `nvidia-smi` on OKAMI;
   - `touch /run/okuri/force-software` on OKAMI → stream plays on OKAMI CPU,
     WARNING in Loki;
   - stop sshd on OKAMI → stream plays on SOTO CPU;
   - kill the playback → `pgrep ffmpeg` empty on OKAMI.

## Cutover & rollback

Single branch, but staged commits: (1) okuri flake dir + tests green, (2)
switch SOTO/OKAMI wiring, (3) delete rffmpeg-nix. Rollback at any point is
`git revert` of (2) — rffmpeg config is untouched until (3), and its on-disk
state remains valid.

## Estimated size

Controller ~200 lines, target wrapper ~250 (net ~+120 over the existing
limited-wrapper it absorbs), rewriter ~200 + fixtures, Nix modules ~200,
VM test ~150. Everything stdlib-only Python; no new flake inputs.
