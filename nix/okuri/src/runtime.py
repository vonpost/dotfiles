"""Shared runtime plumbing for the okuri controller and target wrapper."""

import ctypes
import json
import logging
import logging.handlers
import os
import signal
import sys
import threading

PR_SET_PDEATHSIG = 1

# ffmpeg exits 255 after a signal/'q' quit, which collides with ssh's
# transport-failure code. The target wrapper translates it to this value so
# the controller can trust 255 to mean "the connection itself failed".
FFMPEG_EXIT_COLLISION = 255
FFMPEG_EXIT_TRANSLATED = 254


def set_pdeathsig(sig=signal.SIGTERM):
    """Ask the kernel to deliver `sig` when our parent dies (Linux only).
    Returns a callable usable as Popen(preexec_fn=...)."""
    def _apply():
        try:
            libc = ctypes.CDLL("libc.so.6", use_errno=True)
            libc.prctl(PR_SET_PDEATHSIG, int(sig), 0, 0, 0)
        except OSError:
            pass
    return _apply


def setup_logging(tag):
    """Log to journald via /dev/log; OKURI_LOG=stderr overrides (tests)."""
    log = logging.getLogger(tag)
    log.setLevel(logging.DEBUG)
    log.handlers.clear()
    if os.environ.get("OKURI_LOG") == "stderr":
        handler = logging.StreamHandler(sys.stderr)
        handler.setFormatter(logging.Formatter(f"{tag}: %(message)s"))
    else:
        try:
            handler = logging.handlers.SysLogHandler(address="/dev/log")
            handler.setFormatter(logging.Formatter(f"{tag}: %(message)s"))
        except OSError:
            handler = logging.NullHandler()
    log.addHandler(handler)
    return log


def load_config(env_var, default_path):
    path = os.environ.get(env_var, default_path)
    with open(path, "r") as fh:
        return json.load(fh)


def mirror_exit(returncode):
    """Map a subprocess returncode onto our own exit status."""
    if returncode < 0:
        sys.exit(128 - returncode)  # killed by signal N -> 128+N
    sys.exit(returncode)


def forward_signals(proc, log, kill_after=10):
    """Forward termination signals to `proc`. The first signal is passed
    through (SIGINT as-is so ffmpeg can finalize, anything else as SIGTERM)
    and arms a SIGKILL timer; a repeated signal kills immediately. This keeps
    a wedged ffmpeg (NVENC teardown hangs are a real failure mode) from
    outliving its session and leaking the encoder slot."""
    state = {"signalled": False}

    def _escalate():
        if proc.poll() is None:
            log.warning("child ignored termination signal, sending SIGKILL")
            try:
                proc.kill()
            except ProcessLookupError:
                pass

    def _handler(signum, _frame):
        first = not state["signalled"]
        state["signalled"] = True
        try:
            if not first:
                proc.kill()
            elif signum == signal.SIGINT:
                proc.send_signal(signal.SIGINT)
            else:
                proc.terminate()
        except ProcessLookupError:
            return
        if first:
            timer = threading.Timer(kill_after, _escalate)
            timer.daemon = True
            timer.start()

    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP, signal.SIGQUIT):
        signal.signal(sig, _handler)
    return state
