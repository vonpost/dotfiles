"""Exercise infra's real shell control flow with inert Nix/SSH commands."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(os.environ.get("INFRA_TEST_SCRIPT", Path(__file__).resolve().parents[2] / "lib/infra.sh"))
FAKE = r'''
import json, os, shlex, sys
from pathlib import Path
p = Path(os.environ["FAKE_STATE"])
s = json.loads(p.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
source = "/nix/store/" + "a" * 32 + "-source"
old = "/nix/store/" + "b" * 32 + "-old"
candidate = "/nix/store/" + "c" * 32 + "-candidate"
system = "/nix/store/" + "d" * 32 + "-system"

def fail(flag):
    return os.environ.get(flag) == "1"

def run(cmd, remote=False):
    s["events"].append(["remote" if remote else "local", *cmd])
    tool, a = cmd[0], cmd[1:]
    if tool == "uname": return "TERRA", 0
    if tool == "id": return os.environ.get("FAKE_UID", "1000"), 0
    if tool == "sudo": return run(a, remote)
    if tool == "nixos-rebuild": return "", 0
    if tool == "sleep": return "", 0
    if tool == "git": return (" M file.nix" if fail("DIRTY") else ""), 0
    if tool == "ssh":
        if "root@mother.lan" in a:
            return run(shlex.split(a[-1]), True)
        return (old if fail("WRONG_HEALTH") else system), 0
    if tool == "nix":
        if "archive" in a:
            return json.dumps({"path": source}), int(fail("FAIL_ARCHIVE"))
        if "eval" in a:
            if any("vsock.cid" in v for v in a): return "10", 0
            return json.dumps(["MOTHER", "MAMORU", "DARE", "NIKKI"]), 0
        if "build" in a: return candidate, int(fail("FAIL_BUILD"))
        if "update" in a or "check" in a: return "", 0
    if tool == "readlink":
        path = a[-1]
        if path == "/run/current-system":
            return (candidate if s.get("mother_active") and not fail("WRONG_HEALTH") else old), 0
        if path.endswith("/share/microvm/system"): return system, 0
        if path.endswith("/booted"):
            return (candidate if s.get("vm_active") else old), 0
    if tool == "ln":
        s.setdefault("roots", {})[a[-1]] = a[-2]
        return "", 0
    if tool == "rm":
        for path in a[1:]: s.setdefault("roots", {}).pop(path, None)
        return "", 0
    if tool == "nix-env": return "", 0
    if tool.endswith("/bin/switch-to-configuration"):
        s["mother_active"] = True
        return "", int(fail("FAIL_SWITCH"))
    if tool == "/bin/sh" and a[:1] == ["-c"] and a[1].startswith('printf "%s'):
        s["recorded_source"] = a[-1]
        return "", 0
    if tool == "systemd-run":
        if fail("FAIL_ARM"): return "", 1
        s["armed"] = True
        return "", 0
    if tool == "systemctl":
        if a[0] == "show": return ("active" if fail("PREARMED") else "inactive"), 0
        if a[0] == "is-active": return "", 0 if s.get("armed") else 3
        if a[0] == "restart":
            s["vm_active"] = True
            return "", 0
        if a[0] == "is-system-running": return "running", 0
        if a[0] == "reset-failed": return "", 0
        if a[0] == "stop":
            if fail("FAIL_DISARM"): return "", 1
            if not a[1].endswith("-stage2.timer"): s["armed"] = False
            return "", 0
    raise RuntimeError("Unexpected command (never executed): " + repr(cmd))

try:
    output, code = run([name, *args])
    p.write_text(json.dumps(s))
    if output: print(output)
    sys.exit(code)
except Exception:
    p.write_text(json.dumps(s))
    raise
'''


class DeploymentTests(unittest.TestCase):
    def invoke(self, *args, **flags):
        with tempfile.TemporaryDirectory() as directory:
            work = Path(directory)
            root = work / "nix"
            root.mkdir()
            (root / "flake.nix").write_text("{}")
            locked = {"rev": "e" * 40, "lastModified": 1780749050}
            (root / "flake.lock").write_text(json.dumps({"nodes": {
                name: {"locked": locked} for name in ["nixpkgs", "nixpkgs-mother"]
            }}))
            bindir = work / "bin"
            bindir.mkdir()
            for tool in ["nix", "ssh", "git", "uname", "sleep", "id", "sudo", "nixos-rebuild"]:
                path = bindir / tool
                path.write_text(f"#!{sys.executable}\n" + FAKE)
                path.chmod(0o755)
            state = work / "state.json"
            state.write_text(json.dumps({"events": []}))
            env = os.environ | {
                "PATH": f"{bindir}:{os.environ['PATH']}",
                "FAKE_STATE": str(state),
                **{k: str(v) for k, v in flags.items()},
            }
            result = subprocess.run(
                ["bash", str(SCRIPT), "--root", str(root), *args],
                env=env, text=True, capture_output=True, timeout=20,
            )
            return result, json.loads(state.read_text())

    def test_laptop_fetches_as_user_and_elevates_only_activation(self):
        result, state = self.invoke("deploy", "terra")
        self.assertEqual(result.returncode, 0, result.stderr)
        events = state["events"]
        rebuild = next(e for e in events if e[:2] == ["local", "nixos-rebuild"])
        self.assertIn("--sudo", rebuild)
        self.assertEqual(rebuild[2], "switch")
        flake = rebuild[rebuild.index("--flake") + 1]
        self.assertTrue(flake.startswith("git+file://"), flake)
        self.assertTrue(flake.endswith("?dir=nix/laptop#TERRA"), flake)
        self.assertFalse(any(e[1] == "sudo" for e in events))
        self.assertFalse(any(e[0] == "remote" or "archive" in e for e in events))

    def test_laptop_already_root_does_not_need_sudo(self):
        result, state = self.invoke("deploy", "terra", FAKE_UID=0)
        self.assertEqual(result.returncode, 0, result.stderr)
        events = state["events"]
        rebuild = next(e for e in events if e[:2] == ["local", "nixos-rebuild"])
        self.assertNotIn("--sudo", rebuild)
        self.assertFalse(any(e[1] == "sudo" for e in events))

    def test_mother_activates_exact_prebuilt_candidate(self):
        result, state = self.invoke("deploy", "mother")
        self.assertEqual(result.returncode, 0, result.stderr)
        events = state["events"]
        build = next(i for i, e in enumerate(events) if e[:2] == ["remote", "nix"] and "build" in e)
        arm = next(i for i, e in enumerate(events) if e[:2] == ["remote", "systemd-run"])
        switch = next(i for i, e in enumerate(events) if e[1].endswith("/bin/switch-to-configuration"))
        self.assertLess(build, arm)
        self.assertLess(arm, switch)
        self.assertIn("c" * 32 + "-candidate/bin/", events[switch][1])
        self.assertFalse(state["armed"])
        self.assertFalse(any("nixos-rebuild" in e for e in events))

    def test_failed_build_never_arms_or_activates(self):
        result, state = self.invoke("deploy", "mother", FAIL_BUILD=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(state.get("armed"))
        self.assertFalse(state.get("mother_active"))

    def test_failed_archive_never_touches_host(self):
        result, state = self.invoke("deploy", "NIKKI", FAIL_ARCHIVE=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(e[0] == "remote" for e in state["events"]))

    def test_failed_switch_keeps_rollback(self):
        result, state = self.invoke("deploy", "mother", FAIL_SWITCH=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["armed"])

    def test_failed_arm_never_activates(self):
        result, state = self.invoke("deploy", "MAMORU", FAIL_ARM=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(state.get("vm_active"))

    def test_wrong_generation_keeps_rollback(self):
        for target in ["mother", "MAMORU"]:
            with self.subTest(target=target):
                result, state = self.invoke("deploy", target, WRONG_HEALTH=1)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(state["armed"])
                self.assertNotIn("recorded_source", state)

    def test_failed_disarm_keeps_old_generation_rooted(self):
        result, state = self.invoke("deploy", "mother", FAIL_DISARM=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(state["armed"])
        self.assertIn("/nix/var/nix/gcroots/infra-deadman-MOTHER", state["roots"])

    def test_keep_deadman_leaves_application_checks_protected(self):
        result, state = self.invoke("deploy", "NIKKI", "--keep-deadman")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(state["armed"])
        self.assertIn("/nix/var/nix/gcroots/infra-deadman-NIKKI", state["roots"])

    def test_existing_deadman_is_not_replaced(self):
        result, state = self.invoke("deploy", "MAMORU", PREARMED=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(state.get("vm_active"))
        self.assertFalse(any(e[:2] == ["remote", "systemd-run"] for e in state["events"]))
        self.assertNotIn("/nix/var/nix/gcroots/infra-deadman-MAMORU", state.get("roots", {}))

    def test_vm_records_archived_source_after_health(self):
        result, state = self.invoke("deploy", "nikki", DIRTY=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(state["recorded_source"], "path:/nix/store/" + "a" * 32 + "-source")
        self.assertTrue(state["vm_active"])
        self.assertFalse(any("rsync" in e for e in state["events"]))

    def test_validation_happens_before_transfer(self):
        for args in [("missing",), ("mother", "MAMORU"), ("MAMORU", "NIKKI"), ("DARE", "NIKKI"), ("NIKKI", "--deadman=0"), ("NIKKI", "--keep-deadman", "--no-deadman")]:
            with self.subTest(args=args):
                result, state = self.invoke("deploy", *args)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(any("archive" in e for e in state["events"]))
                self.assertFalse(any(e[0] == "remote" for e in state["events"]))

    def test_fleet_does_not_activate_router_or_dns(self):
        result, state = self.invoke("deploy", "vms")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any("microvm@MAMORU.service" in e for e in state["events"]))
        self.assertFalse(any("microvm@DARE.service" in e for e in state["events"]))

    def test_router_checks_exact_system_over_fresh_vsock(self):
        result, state = self.invoke("deploy", "MAMORU")
        self.assertEqual(result.returncode, 0, result.stderr)
        probe = next(e for e in state["events"] if e[:2] == ["remote", "ssh"])
        self.assertIn("ControlPath=none", probe)
        self.assertIn("vsock/10", probe)
        self.assertEqual(probe[-3:], ["readlink", "-f", "/run/current-system"])
        self.assertFalse(state["armed"])

    def test_explicit_disarm_reports_failure_and_preserves_roots(self):
        result, state = self.invoke("disarm", FAIL_DISARM=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(e[:2] == ["remote", "rm"] for e in state["events"]))

    def test_host_pin_update_does_not_update_shared_inputs(self):
        result, state = self.invoke("update", "mother")
        self.assertEqual(result.returncode, 0, result.stderr)
        update = next(e for e in state["events"] if "update" in e)
        self.assertEqual(update[-1], "nixpkgs-mother")
        self.assertNotIn("microvm", update)
        self.assertNotIn("sops-nix", update)

    def test_evaluation_check_cannot_start_builds(self):
        result, state = self.invoke("check")
        self.assertEqual(result.returncode, 0, result.stderr)
        check = next(e for e in state["events"] if "check" in e)
        self.assertIn("--no-build", check)
        self.assertEqual(check[check.index("max-jobs") + 1], "0")
        self.assertEqual(check[check.index("builders") + 1], "")


if __name__ == "__main__":
    unittest.main()
