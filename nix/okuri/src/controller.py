"""okuri controller: the ffmpeg/ffprobe the Jellyfin host actually runs.

Dispatches every invocation to the GPU target over SSH. When the transport
itself fails fast (target down, network cut), rewrites the argv to software
and runs the local CPU ffmpeg instead, so playback degrades instead of dying.

Remote ffmpeg failures are NOT retried here: the target wrapper already
handles GPU-level failures on its own (more capable) CPU. By the time a
non-255 exit reaches us it is a genuine encode error.
"""

import os
import shlex
import signal
import subprocess
import sys
import time

import rewrite
import runtime

DEFAULT_CONFIG = "/etc/okuri/config.json"


def build_ssh_command(cfg, role, args):
    t = cfg["target"]
    cmd = [t["ssh"]]
    cmd += ["-o", "BatchMode=yes"]
    cmd += ["-o", f"ConnectTimeout={t.get('connect_timeout', 2)}"]
    cmd += ["-o", "ConnectionAttempts=1"]
    if t.get("persist", 0) > 0 and rewrite.is_probe_invocation(role, args):
        # Transcodes deliberately skip the mux: they must own their TCP
        # connection so a killed dispatcher tears down the remote process
        # (pdeathsig on the target fires when the connection drops).
        control_dir = t.get("control_dir", "/run/okuri")
        cmd += ["-o", "ControlMaster=auto"]
        cmd += ["-o", f"ControlPath={control_dir}/cm-%r@%h:%p"]
        cmd += ["-o", f"ControlPersist={t['persist']}"]
    cmd += t.get("ssh_args", [])
    cmd.append(f"{t['user']}@{t['host']}")
    cmd.append(role)
    cmd += [shlex.quote(a) for a in args]
    return cmd


def run_and_wait(cmd, log):
    # pdeathsig: if Jellyfin SIGKILLs us, ssh must die too so the connection
    # drops and the target's own pdeathsig chain reaps the remote transcode.
    proc = subprocess.Popen(
        cmd, preexec_fn=runtime.set_pdeathsig(signal.SIGKILL))
    state = runtime.forward_signals(proc, log)
    returncode = proc.wait()
    return returncode, state


def local_fallback(cfg, role, args, log, reason):
    fb = cfg.get("fallback", {})
    binary = cfg["local"][role]
    if role == "ffmpeg" and rewrite.wants_gpu(args):
        args, notes = rewrite.rewrite_to_software(
            args, fb.get("preset_ceiling", rewrite.DEFAULT_PRESET_CEILING))
        for note in notes:
            log.info("rewrite: %s", note)
    log.warning("FALLBACK engaged (%s): running %s locally in software mode",
                reason, role)
    argv = [binary] + list(args)
    proc = subprocess.Popen(
        argv, preexec_fn=runtime.set_pdeathsig(signal.SIGKILL))
    runtime.forward_signals(proc, log)
    runtime.mirror_exit(proc.wait())


def dispatch(role, args):
    log = runtime.setup_logging("okuri")
    cfg = runtime.load_config("OKURI_CONFIG", DEFAULT_CONFIG)
    fb = cfg.get("fallback", {})

    ssh_cmd = build_ssh_command(cfg, role, args)
    log.debug("dispatch %s to %s: %s", role, cfg["target"]["host"],
              " ".join(args))

    start = time.monotonic()
    returncode, state = run_and_wait(ssh_cmd, log)
    elapsed = time.monotonic() - start

    if returncode == 0 or state["signalled"]:
        runtime.mirror_exit(returncode)

    # 255 is reserved for ssh transport failure: the target wrapper
    # translates ffmpeg's own 255 exits to 254.
    transport_failed = returncode == 255
    fast = elapsed < fb.get("fast_fail_seconds", 15)

    if transport_failed and fb.get("enable", True) and fast:
        local_fallback(cfg, role, args, log,
                       f"ssh transport failure after {elapsed:.1f}s")

    if transport_failed:
        log.error("transport failure after %.1fs, past fast-fail window; "
                  "propagating (client retry will fall back)", elapsed)
    runtime.mirror_exit(returncode)


def check():
    """`okuri check`: verify remote dispatch and the local fallback binary."""
    cfg = runtime.load_config("OKURI_CONFIG", DEFAULT_CONFIG)
    failures = 0

    ssh_cmd = build_ssh_command(cfg, "ffmpeg", ["-version"])
    ret = subprocess.run(ssh_cmd, capture_output=True, text=True)
    first = (ret.stdout or ret.stderr).splitlines()
    print(f"remote {cfg['target']['user']}@{cfg['target']['host']}: "
          f"exit {ret.returncode}" + (f" ({first[0]})" if first else ""))
    failures += ret.returncode != 0

    for role in ("ffmpeg", "ffprobe"):
        binary = cfg["local"][role]
        ok = os.access(binary, os.X_OK)
        print(f"local fallback {role}: {binary} "
              f"{'ok' if ok else 'MISSING'}")
        failures += not ok

    sys.exit(1 if failures else 0)


def main():
    role = os.environ.get("OKURI_ROLE")
    if role in ("ffmpeg", "ffprobe"):
        dispatch(role, sys.argv[1:])
    elif len(sys.argv) > 1 and sys.argv[1] == "check":
        check()
    else:
        print("usage: okuri check | (invoked as ffmpeg/ffprobe via OKURI_ROLE)",
              file=sys.stderr)
        sys.exit(2)


if __name__ == "__main__":
    main()
