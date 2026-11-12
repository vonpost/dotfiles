# Wolf launcher startup latency

Investigated on OKAMI, 2026-11-11. The reported delay is the black screen
before Steam or Battle.net first appears. A running systemd session does
not mean the launcher has drawn a window.

## Observed stages

Battle.net launch on 2026-11-11 (UTC, existing profile):

| Event | Time | Since container start |
| --- | --- | --- |
| Container starts | 08:37:57.83 | 0 s |
| Sway starts | 08:38:02 | ~4 s |
| UMU announces its version | 08:38:05 | ~7 s |
| Runtime is current; pressure-vessel starts | 08:38:06 | ~8 s |
| Proton starts | 08:38:15 | ~17 s |
| Xwayland compiles its keymap | 08:38:18 | ~20 s |
| Battle.net's own log begins | 08:38:20 | ~22 s |

These are process/log milestones, not measured first-frame timestamps.
This session later went through a login challenge; do not include the time
spent authenticating in a normal-launch benchmark.

Steam's 2026-11-08 logs show the same runtime stage: webhelper starts its
runtime at 01:10:09 and execs the browser at 01:10:19. Earlier client
updates make that launch unsuitable as an ordinary startup baseline.

## Isolated runtime measurements

Ran the installed steamrt4 pressure-vessel inside UMU's existing FHS mount
namespace as uid 1000, launching only `/bin/true`. Each probe used a separate
temporary runtime variable directory, removed afterward. No Wine process,
game prefix, launcher, or live session was restarted.

| Probe | Elapsed |
| --- | ---: |
| Existing runtime on VirtioFS, normal copy mode | 11.630 s |
| Existing runtime on VirtioFS, no-copy mode | 11.069 s |
| Temporary runtime copy on the container's local overlayfs | 6.313 s |

The local copy took 5.349 s to prepare, outside the measured launch. A useful
implementation must retain the local runtime across launches; copying it
every time would consume the saving. These are individual warm-filesystem
samples, not cold-start distributions or end-to-end launcher benchmarks.

A separate strace run showed extensive file opens, symlink resolution and
runtime hardlink creation. Tracing increased elapsed time; its 23.566 s is
not a comparable startup measurement. The local-disk probe still took six
seconds, so moving the runtime alone does not eliminate all setup overhead.

## Prepared change and next step

Both app Sway configurations now use `xwayland force`. This starts the X11
server alongside launcher/runtime preparation instead of waiting for the
first X11 connection. Verified Nix evaluation and a headless Sway test:
`enable` leaves Xwayland stopped until a client arrives; `force` starts it
without a client; both successfully map an X11 window. GPU streaming and
end-to-end time saved still need validation after deployment.

The larger next change is persistent, per-profile local runtime storage for
UMU and Steam's webhelper runtime. Keep game data and Wine prefixes in their
existing locations, preserve the existing copies during migration, and
retain normal runtime updates. Do not change the shared state export's cache
policy fleet-wide or disable updates based on this benchmark.

The running WoW session was left in place; the source change is not deployed.
