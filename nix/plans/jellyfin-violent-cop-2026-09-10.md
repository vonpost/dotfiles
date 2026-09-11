# Violent Cop playback failure, September 10, 2026

The failed playback at 19:07 CEST used fMP4 HLS. SOTO returned an empty
initialization segment on the original attempt and both video-transcoding
retries. OKAMI successfully generated video and audio; Jellyfin stopped each
FFmpeg process after the client retried. A bounded reproduction confirmed that
SOTO can see an empty initialization file after the video segments are already
readable. A separate synthetic test proved stale file-size metadata between the
two VMs.

The evidence identifies shared-filesystem visibility as the underlying problem.
It does not indicate a failed SSH dispatch, GPU crash, or an encoding error in
the tested opening of the movie. The user's fMP4 reproduction is relevant to
the original incident.

## Incident evidence

All times below are Europe/Amsterdam (CEST, UTC+02:00), September 10, 2026.
The client identified itself as Jellyfin Web 10.11.11 in Chrome 152 on Android.

| Time | Event |
| --- | --- |
| 19:07:45 | Client starts playback. FFmpeg copies H.264 video, converts AC-3 stereo to AAC, and packages fMP4 HLS. The request's reason is `AudioCodecNotSupported`. |
| 19:07:47 | Nginx records `GET …/hls1/main/-1.mp4` as **200, 0 response bytes**. Segments 0 and 1 return 1,698,004 and 4,278,582 bytes. |
| 19:07:49 | Client requests another playback configuration. Jellyfin sends `q` to FFmpeg, which exits 0. New job transcodes video with `hevc_nvenc`. |
| 19:07:51 | The new initialization segment again returns **200, 0 bytes**. Video segments have content. |
| 19:07:53 | Another retry starts HEVC encoding after the previous FFmpeg exits 0. |
| 19:07:55 | Initialization segment again returns **200, 0 bytes**. |
| 19:07:56–58 | FFmpeg exits 0 after `q`; client reports playback stopped at **0 ms**. |
| 19:08:03–05 | Another attempt starts the original H.264-copy/AAC path. Both the initialization segment and one media segment return 200 with zero bytes. |
| 19:08:08 | Kestrel throws `Response Content-Length mismatch: too many bytes written (18956288 of 18944000)`. Nginx records a 18,939,904-byte response for segment 3; a later retry returns 41,881,098 bytes. |
| 19:09:54 | Jellyfin's abandoned-session timer stops the remaining FFmpeg process; exit 0. |

The relevant FFmpeg logs have no decoding, muxing, or GPU error messages.
The original remux ran around 26 times real time, produced multiple segments,
and explicitly logged `[q] command received. Exiting.` OKAMI's journal shows
successful SSH authentication and normal session closure for all four jobs.
No okuri fallback was invoked.

The adjacent Seerr connection-refused errors belong to the request-management
plugin. They do not explain the empty HLS files.

## Reproduction and mechanism

Both VMs access `/var/cache/jellyfin` through their shared VirtioFS state trees.
MOTHER runs both relevant daemons with `--cache=auto`. The state share is
declared in `lib/modules/infra/guest-service-state.nix`, without an explicit
cache policy; Jellyfin and the transcode worker intentionally share the same
cache directory through `config/infra/service-map.nix`.

I remuxed only the first 24 seconds of the movie on OKAMI into a unique scratch
directory while polling file sizes and reading files on SOTO:

| Seconds after reader start | SOTO's view |
| --- | --- |
| 1.820 | Initialization file exists, size/read length 0. |
| 2.176 | Segment 0 is readable, 1,698,004 bytes; initialization file still 0. |
| 2.643 | Segment 1 is readable, 4,278,582 bytes; initialization file still 0. |
| 2.750 | Finished playlist is readable; initialization file still 0. |
| 2.862 | Initialization file finally reports and returns 1,329 bytes. |

The sample FFmpeg process exited 0 with no warnings. Its completed
initialization file was 1,329 bytes on OKAMI. The scratch directory was removed.

To distinguish filesystem caching from FFmpeg buffering, I also used a small
synthetic file: OKAMI created it empty, wrote 1,329 bytes, called `fsync`, and
closed it. SOTO continued to report size 0 for approximately **748 ms after the
write and fsync completed**, updating approximately one second after its initial
lookup. That file was also removed.

Jellyfin's HLS controller treats the existence of a later segment as evidence
that an earlier segment is ready, then serves it with `PhysicalFileResult`.
With stale metadata across the VMs, the later segment can be visible while the
initialization file still appears empty. This explains the empty initialization
responses. The observed change in file size is also consistent with the later
Content-Length mismatch, although that individual HTTP response was not replayed.
See the pinned [HLS controller](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Controllers/DynamicHlsController.cs#L1866)
and [file response helper](https://github.com/jellyfin/jellyfin/blob/v10.11.11/Jellyfin.Api/Helpers/FileStreamResponseHelpers.cs#L95).

## Why the setting matters

In Jellyfin Web 10.11.11, `preferFmp4HlsContainer` defaults to true for Chrome,
Firefox, Safari and Chromium Edge. It is stored in local client settings. The
affected Chrome user therefore need not have explicitly enabled it. See the
[versioned preference implementation](https://github.com/jellyfin/jellyfin-web/blob/v10.11.11/src/scripts/settings/userSettings.js#L148).

The user's September 11 comparison follows the same distinction: the 22:41
MPEG-TS attempt advanced playback, while the 22:42 fMP4 attempts retried and
ultimately reported 0 ms. Their direct/local access did not appear in nginx's
access log, so an empty HTTP initialization response for that specific
reproduction was not independently captured.

## Remediation

The immediate workaround is to disable **Prefer fMP4-HLS Media Container** on
the affected client, then start a fresh playback. This avoids the separate
initialization file for this H.264/AAC path. It does not fix shared-file
coherency for other streaming paths.

The implemented fix adds a dedicated `cache = "never"` VirtioFS share for
`/var/cache/jellyfin/transcodes` in SOTO and OKAMI: two extra daemons in total.
Both export the existing `/state/services/cache/jellyfin/transcodes` backing
directory, without moving files or changing Jellyfin/okuri paths. The service
map opts both roles into `uncachedCacheDirectories = [ "transcodes" ];`, and
the existing state-layout modules derive the shares, ownership and mount
dependencies. This follows service assignments and path overrides.

Do not blindly set `cache = "never"` on the entire existing state share:
the installed virtiofsd changes shared-mmap behavior with that policy, and the
running Jellyfin process maps `jellyfin.db-shm` from the same share. Also preserve
the repository's documented constraint that many concurrent VirtioFS shares
previously caused host failures. A storage fix must account for both facts.
The installed daemon's `--help` documents the mmap restriction; its
[versioned source](https://gitlab.com/virtio-fs/virtiofsd/-/blob/v1.13.3/src/passthrough/mod.rs)
describes the cache policies.

Nix configuration and regression tests have been changed locally. No production
settings, services or media files have been changed by this implementation, and
the fix has not been deployed or validated in the affected browser. See the
[deployment notes](jellyfin-transcode-shares-rollout.md) for validation, ordering
and rollback. The investigation tested startup and shared-file visibility, not
the entire movie's integrity.

## Local evidence

Collected evidence and reproducible probes are in the private directory
`/tmp/jellyfin-violent-cop-debug/`:

- `nginx-incident-redacted.log`: URL queries removed on SOTO before transfer.
- `soto-journal.log`, `okami-journal.log`: incident window.
- `FFmpeg.*.log`: incident and comparison logs.
- `probe_shared_hls.py`, `probe-shared-hls.log`: short movie remux and reader trace.
- `probe_metadata.py`, `probe-metadata.log`: synthetic file-size coherence test.

The probes are temporary diagnostics with paths pinned to the inspected hosts'
installed Python. They are not repository tests or production tools.
