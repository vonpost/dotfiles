# Wolf: nix-native app images (v2)

Goal: stop porting GoW's bash scaffolding into `images.nix` and instead express the
app-container runtime natively in NixOS modules, keeping only Wolf's actual runner
contract. Research basis: wolf @ `7f416ec` (stable, 2026-08-08) and gow @ master,
inspected 2026-08-17.

## Where we are

Already nix-built: wolf binary (17 FetchContent deps vendored, `FETCHCONTENT_FULLY_DISCONNECTED`),
gst-wayland-display (cargo, `--features cuda`), gst-interpipe, fake-udev, all app images
via dockerTools. But `images.nix` (~1,900 lines) is a faithful port of GoW's boot chain
(`entrypoint.sh` → `cont-init.d` → gosu → `startup.sh` → `launch-comp.sh` → desktop-compat lib),
plus `wolf-nvidia-driver-sync` (~250 lines) recreating GoW's `/usr/nvidia` volume contract
with mesa-ICD renames. The desktop images are already half-native: pass-through rootfs +
host `/nix/store` mount + NixOS toplevel via `GOW_NIXOS_SYSTEM` — but still boot through
the compat shell layer. Remaining upstream images: `wolf-den:stable` (quadlet), possibly
`wolf-ui:main` and the `pulseaudio:master` fallback (`WOLF_PULSE_IMAGE`).

## Wolf's actual contract (everything else is GoW convention)

Injected env: `XDG_RUNTIME_DIR`, `WAYLAND_DISPLAY`, `PULSE_SERVER`, `PULSE_SINK`,
`PULSE_SOURCE` (per-session virtual sink/monitor), `GAMESCOPE_WIDTH/HEIGHT/REFRESH`
(Moonlight-negotiated), `WOLF_VIDEO_BUFFER_CAPS`, `WOLF_SESSION_ID`, `PUID`/`PGID`.

Injected mounts: host `$XDG_RUNTIME_DIR/wayland-N` → container `$XDG_RUNTIME_DIR/wayland-N`;
host pulse socket (filename hardcoded `pulse-socket`) → path in `PULSE_SERVER`;
`$HOST_APPS_STATE_FOLDER/profile_data/<profile>/<app>` → `/home/retro` (hardcoded);
`$HOST_APPS_STATE_FOLDER/fake-udev` → `/usr/bin/fake-udev`; `<app_state>/udev` → `/run/udev`;
optional `$NVIDIA_DRIVER_VOLUME_NAME` → `/usr/nvidia`.

Devices/hotplug: inputtino devices passed as Docker `Devices` (mrw); hotplug via
`docker exec` root: `mknod && chmod 777 && fake-udev -m <b64>`; `DeviceCgroupRules`
for hidraw/input rewritten from live `/proc/devices` majors.

Lifecycle: PID 1 exits → session ends (500 ms poll). `StopSignal`, caps, IpcMode,
tmpfs, extra mounts, Entrypoint all come from `base_create_json` — which *we* author.

NVIDIA trap: if GPU is NVIDIA and `NVIDIA_DRIVER_VOLUME_NAME` is unset, wolf injects
`DeviceRequests` + `Runtime: "nvidia"` (nvidia-container-toolkit path) into the create
JSON (`runners/docker.cpp:88-131`). Keep the volume env set (or patch this to opt-in).

Key simplification lever: host and app closure build from the same nixpkgs, so GoW's
runtime reconciliation (PUID userdel/useradd, `ensure-groups` gid matching, driver
version matching, ICD synthesis) disappears at build time — same uids/gids by
construction, nvidia userland is literally the same store path as the host's.

## Phases

### 1. Refresh wolf core + extract the contract
- Bump wolf `ea4a75d` → `7f416ec` (config v7; default video/audio ports now 48100/48200 —
  topology.nix already matches, module firewall defaults are stale; upstream replaced the
  WolfPulseAudio sidecar with embedded PA — our host-PA design matches direction).
- Pin `mdns_cpp` (upstream FetchContent leaves it unpinned — silent drift).
- New `wolf-nix/contract.nix`: single attrset for every shared path/env/port
  (pulse-socket name, /home/retro, fake-udev path, ports, cgroup rules). Module and
  images consume it; nothing hardcoded twice.

### 2. Nix-native session runtime (the core deliverable)
- **One stub OCI image for all apps** (KBs): `/etc/{passwd,group,os-release}`, mountpoint
  dirs (`/usr/bin` must exist for the fake-udev bind), tmpfs mounts stay in create JSON.
  Per-app differentiation moves to app TOML env `WOLF_APP_SYSTEM=<toplevel store path>`;
  `podman load` of fat archives goes away.
- **PID 1 shim** (store path via the host store mount, set as Entrypoint in create JSON):
  capture injected env → `/run/wolf-session.env` → `exec $WOLF_APP_SYSTEM/init`.
- **`wolfApp` NixOS module** producing the toplevel: fixed uid-1000 user with
  supplementary groups at host gids (kills setup_user/ensure-groups/gosu);
  `wolf-session.target`; compositor units (sway / gamescope / KDE) with
  `EnvironmentFile=/run/wolf-session.env`; a small resolution unit replacing the
  wlr-randr bash; app unit with `SuccessAction=exit-force` so app exit → PID 1 exit →
  wolf ends session (replaces `&& killall sway`). StopSignal stays RTMIN+3.
- Irreducible runtime glue (values known only at session start: resolution, sockets)
  becomes small units reading the env file — not a ported script library.
- Validate: firefox first, then KDE parity on OKAMI.

### 3. NVIDIA, natively
- App closure: `hardware.graphics` (+32bit) with the *same driver package* as OKAMI
  (assert equality against the host config); container activation provides
  `/run/opengl-driver{,-32}` pointing at the same store paths as the kernel module.
  All ICD/EGL/GBM JSONs come from nixpkgs' own module.
- Delete `wolf-nvidia-driver-sync` and the mesa-ICD-overwrite shim entirely.
- Keep `NVIDIA_DRIVER_VOLUME_NAME` pointed at a tiny dummy path to suppress the
  toolkit auto-injection, or patch `docker.cpp` to make it opt-in (we build from source).
- Audit that `/dev/nvidia*` nodes are actually in create-JSON `Devices` (today masked
  by the GOW_REQUIRED_DEVICES perms dance).

#### Known issue folded into M4 (added 2026-08-18)
The current KDE session (`wolfKdeImage`, the only app OKAMI loads) **never worked
properly** — severe UI lag, cause never found. So M4's gate is NOT "parity with
current KDE"; it is "a desktop session that performs". Leads, in suspicion order:
1. **KWin on llvmpipe.** If the container's KWin doesn't find the NVIDIA
   EGL/GBM/Vulkan stack it silently falls back to software rendering. The
   mesa-ICD-overwrite shim in `wolf-nvidia-driver-sync` exists precisely because
   this area was fought before. First diagnostic in any session:
   `journalctl`/`qdbus org.kde.KWin /KWin supportInformation | grep -i renderer`
   (llvmpipe = confirmed). The M3 redesign (real `/run/opengl-driver` in the
   closure, same store paths as the host driver) may fix this outright.
2. **wlr-randr vs KWin.** The compat layer reconciles resolution with `wlr-randr`,
   but KWin does not implement wlr-output-management — so the KDE session likely
   never matched the Moonlight-negotiated mode (`kscreen-doctor` is the KDE way).
   Mode mismatch → scaling/copy overhead every frame.
3. Frame pacing between nested compositors (KWin client → wolf's smithay
   compositor) and/or a non-zero-copy pipeline path (verify `WOLF_USE_ZERO_COPY`
   actually engages nvidia zero-copy in wolf logs).
Strategy: validate M3 first on sway/gamescope sessions (wlroots — matches the
existing tooling, far simpler render path), get those *performing well*, then
bring up KDE on the nix-native stack with the diagnostics above before declaring
M4 done.

### 4. Steam
- `wolfApp` + nixpkgs `programs.steam` FHS env + gamescope; state via the `/home/retro`
  mount as today; Proton arrives via Steam's own downloads (upstream doesn't bake it either).
- **Schedule risk**: GoW builds a patched bubblewrap (`ignore_capabilities.patch`) so
  pressure-vessel tolerates CAP_SYS_ADMIN containers. Carry that patch as an overlay on
  whatever bwrap the steam FHS uses, and test this first — it's the phase's go/no-go.
- Optional parity extras only on demand: Decky, fake steamos shims, mangoapp/ibus.

### 5. Last upstream images
- `wolf-den`: research the stack once network research works again (blocked today by
  the classifier outage), then either a native systemd service on `wolf.sock`
  (preferred) or a nix-built image.
- Verify the generated config doesn't reference `wolf-ui:main`; make the
  `pulseaudio:master` fallback explicitly unreachable (host PA always up before wolf).

### 6. Integration cleanup
- Fold wolf into the service catalog (known todo in `plans/joyful-inventing-allen.md`).
- Make wolf-nix follow the root flake's nixpkgs (it has its own lock today; phase 3's
  driver-identity guarantee requires one nixpkgs) and resolve the flake-input-vs-path
  import duality.
- Firewall defaults from contract.nix; delete the compat layer from `images.nix`;
  NixOS VM test (wolf + process-runner test-ball + stub container boots).

### 7. Stretch: containerless
Wolf's `process` runner is real (launches `run_cmd` with full session env via
boost::process) but does no mounts/devices; fake-udev hotplug is docker-exec-only —
though host processes see *real* udev events, so hotplug may work natively.
Candidate: trusted desktops as host units or nspawn reusing the same `wolfApp` module.
Only after 2–4 are stable.

## Deleted / kept
Deleted: gow entrypoint/startup/ensure-groups/setup_user/30-nvidia/launch-comp/
desktop-compat ports (~1,000 lines of bash-in-nix), nvidia-driver-sync (~250 lines),
per-app layered images and their load unit. Kept: `packages/wolf.nix` (plus pin bump),
podman+quadlet runtime, topology entries, host-PA anonymous socket.

## Integration plan

Branch: `wolf-native`, cut from `main`. OKAMI is the only affected host, so the branch
working tree deploys to okami.lan while everything else stays on main. wolf-den is
**skipped** (user call, 2026-08-17).

Loop per milestone: implement → `nix build` gate (OKAMI toplevel builds) → `infra deploy
OKAMI` from the branch tree (dirty-tree semantics: uncommitted changes ship) → automated
probes → manual stream gate where flagged → **commit only after gates pass**. Rollback at
any point = redeploy from a main checkout; wolf state risk is limited to
`/var/lib/wolf/config.toml` (backed up before M2's v6→v7 migration; `merge-pairings`
preserves `paired_clients` either way).

Automated probes after every deploy (via ssh root@okami.lan):
`systemctl is-active wolf` + journal scan for errors; `curl http://localhost:47989/serverinfo`
(Moonlight serverinfo XML answers without pairing — the cheapest end-to-end liveness check);
`podman ps`/`podman images` for expected containers; `gst-inspect-1.0` for
waylanddisplaysrc/interpipe/nvcodec presence where relevant.

Manual stream gates (I flag these; user tests from a Moonlight client): existing KDE
stream after M2; firefox after M3; KDE parity + gamepad hotplug (exercises fake-udev)
after M4; encoder check (nvh264enc in wolf logs) + stream after M5; Steam client + one
game launch after M6.

Milestones → commits:
- **M0** — branch, baseline capture (probe outputs recorded into `plans/`), this doc.
  Docs-only commit, no deploy.
- **M1** — `contract.nix` + module consumes it (ports/paths/env). *Deliberately do NOT
  refactor `images.nix` onto it — that file is deleted by M4; wasted motion.* Gate:
  OKAMI closure builds, deploy, probes green (behavior-neutral change). Commit.
- **M2** — wolf pin bump `ea4a75d`→`7f416ec` + mdns_cpp pin + module sync (config v7
  default parsing, firewall defaults 48100/48200, re-verify the run_uid/endpoints
  patches still apply or are upstreamed). Gate: probes + manual KDE stream + pairing
  survives. Commit.
- **M3** — stub image + PID-1 env shim + `wolfApp` module + firefox as first native app,
  old image path untouched alongside. Gate: firefox container boots to wolf-session
  units, manual firefox stream. Commit.
- **M4** — KDE on `wolfApp`. Gate: manual KDE parity + gamepad hotplug. Commit; then a
  second commit deleting the legacy `images.nix` compat layer once parity is confirmed.
- **M5** — native NVIDIA (same-store-path driver, dummy driver-volume env or opt-in
  patch, delete `wolf-nvidia-driver-sync`). Gate: `podman exec` nvidia-smi + vulkaninfo
  in an app container, wolf logs select nvcodec, manual stream. Commit.
- **M6** — Steam. bwrap `ignore_capabilities` overlay tested FIRST (go/no-go), then the
  full app. Gate: Steam boots big picture, one game launches under pressure-vessel.
  Commit.
- **M7** — cleanup: service-catalog fold-in, wolf-nix follows root nixpkgs, VM test.
  Commit(s). Natural merge points: after M2, after M4/M5, after M7 — merges to main are
  the user's call; the branch stays deployable at every commit.

## Risks
- Steam/pressure-vessel under podman+caps (phase 4; test bwrap patch first).
- systemd-in-podman quirks: `CgroupnsMode: host` works today for the desktops; consider
  private cgroupns once systemd is the universal PID 1.
- Wolf's nvidia-toolkit auto-injection (mitigated in phase 3).
- Upstream drift: watch `docker/*.Dockerfile` pins (gst-wayland-display `b15285a`,
  GStreamer 1.26.7, cargo-c 0.10.23, Rust 1.96.0) — add a check script.
- Community prior art unverified (web research was down 2026-08-17); do a quick sweep
  before phase 2 in case a wolfApp-style module already exists. Also locate the
  "dev-nix flake" referenced in `packages/wolf.nix`'s comments.
