"""okuri target wrapper: sshd ForceCommand on the GPU node.

Security: only the pinned ffmpeg/ffprobe binaries can be run, whatever the
incoming command claims (same posture as the limited-wrapper it replaces).

Resilience: when the argv wants the CUDA pipeline but the GPU is unhealthy
(preflight) or the attempt fails fast with a GPU error signature, the argv is
rewritten to software and re-run on this host's CPU.

Lifetime: the wrapper carries PDEATHSIG so it dies with the sshd session, and
the ffmpeg child carries PDEATHSIG too — a dropped connection can not leak an
orphaned NVENC session.
"""

import os
import shlex
import signal
import subprocess
import sys
import threading
import time

import rewrite
import runtime

DEFAULT_CONFIG = "/etc/okuri/target.json"
STDERR_RING_SIZE = 64 * 1024

SPECIAL_FLAGS = rewrite.SPECIAL_FLAGS


def deny(log, message):
    log.warning("deny: %s", message)
    print("ERROR: command not allowed.", file=sys.stderr)
    sys.exit(126)


def gpu_healthy(cfg, log):
    if os.path.exists(cfg.get("force_software_file",
                              "/run/okuri/force-software")):
        log.warning("force-software file present, skipping GPU")
        return False
    preflight = cfg.get("preflight_command")
    if not preflight:
        return True
    try:
        ret = subprocess.run(
            preflight,
            timeout=cfg.get("preflight_timeout", 4),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.TimeoutExpired:
        log.warning("GPU preflight timed out (wedged driver?)")
        return False
    except FileNotFoundError:
        log.info("preflight command missing; assuming GPU healthy")
        return True
    if ret.returncode != 0:
        log.warning("GPU preflight failed with exit %d", ret.returncode)
        return False
    return True


def supervise(argv, log, capture_stderr=False):
    """Run argv as a child (never exec: we translate exit codes and keep
    control of the child's lifetime). Returns (returncode, stderr_tail,
    signal_state)."""
    proc = subprocess.Popen(
        argv,
        stderr=subprocess.PIPE if capture_stderr else None,
        preexec_fn=runtime.set_pdeathsig(signal.SIGKILL),
    )
    state = runtime.forward_signals(proc, log)

    tail = bytearray()
    if capture_stderr:
        def _pump():
            # read1: return each chunk as it arrives — a greedy read() would
            # batch ffmpeg's progress lines and stall Jellyfin's parser.
            # Keep draining even if our own stderr goes away (dead session),
            # otherwise the child blocks forever on a full pipe.
            broken = False
            while True:
                chunk = proc.stderr.read1(8192)
                if not chunk:
                    return
                if not broken:
                    try:
                        sys.stderr.buffer.write(chunk)
                        sys.stderr.buffer.flush()
                    except OSError:
                        broken = True
                tail.extend(chunk)
                if len(tail) > STDERR_RING_SIZE:
                    del tail[:len(tail) - STDERR_RING_SIZE]
        pump = threading.Thread(target=_pump, daemon=True)
        pump.start()
        proc.wait()
        pump.join(timeout=5)
    else:
        proc.wait()

    return proc.returncode, bytes(tail).decode("utf-8", "replace"), state


def finish(returncode):
    if returncode == runtime.FFMPEG_EXIT_COLLISION:
        returncode = runtime.FFMPEG_EXIT_TRANSLATED
    runtime.mirror_exit(returncode)


def run_ffmpeg(cfg, args, log):
    binary = cfg["ffmpeg"]

    if any(a in SPECIAL_FLAGS for a in args) or not rewrite.wants_gpu(args):
        rc, _, _ = supervise([binary] + args, log)
        finish(rc)

    software_args = None
    if not gpu_healthy(cfg, log):
        software_args, notes = rewrite.rewrite_to_software(args)
        reason = "GPU unhealthy at preflight"
    else:
        start = time.monotonic()
        rc, stderr_tail, state = supervise([binary] + args, log,
                                           capture_stderr=True)
        elapsed = time.monotonic() - start
        if rc == 0 or rc < 0 or state["signalled"]:
            # Success, or our session is going away — never start a second
            # transcode into a dying session.
            finish(rc)
        fast = elapsed < cfg.get("fast_fail_seconds", 20)
        if fast and rewrite.stderr_looks_gpu_related(stderr_tail):
            software_args, notes = rewrite.rewrite_to_software(args)
            reason = f"GPU attempt failed in {elapsed:.1f}s"
        else:
            log.error("ffmpeg failed (exit %d after %.1fs), not GPU-related "
                      "or past fast-fail window; propagating", rc, elapsed)
            finish(rc)

    for note in notes:
        log.info("rewrite: %s", note)
    log.warning("FALLBACK engaged (%s): transcoding in software on this host",
                reason)
    rc, _, _ = supervise([binary] + software_args, log)
    finish(rc)


def main():
    log = runtime.setup_logging("okuri-target")
    runtime.set_pdeathsig(signal.SIGTERM)()
    cfg = runtime.load_config("OKURI_TARGET_CONFIG", DEFAULT_CONFIG)

    original = os.environ.get("SSH_ORIGINAL_COMMAND", "").strip()
    if not original:
        # ControlMaster opens commandless sessions; that is fine.
        sys.exit(0)

    try:
        args = shlex.split(original)
    except ValueError as exc:
        deny(log, f"unparseable command: {exc}")
    if not args:
        deny(log, "empty command")

    name = os.path.basename(args[0])
    if name == "ffprobe":
        rc, _, _ = supervise([cfg["ffprobe"]] + args[1:], log)
        finish(rc)
    elif name == "ffmpeg":
        run_ffmpeg(cfg, args[1:], log)
    else:
        deny(log, f"command not allowed: {args[0]}")


if __name__ == "__main__":
    main()
