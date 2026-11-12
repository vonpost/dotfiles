"""Exercise on-demand addons, independent locks, and session shutdown."""

import fcntl
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import unittest


SCRIPTS = Path(__file__).resolve().parents[2] / "wolf-nix/packages/images"


class SessionTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.home = Path(directory.name)
        self.bin = self.home / "bin"
        self.bin.mkdir()
        self.state = self.home / ".local/share/battlenet"
        self.state.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home),
                        XDG_CONFIG_HOME=str(self.home / ".config"),
                        WOLF_WOWUP_SETTINGS=str(SCRIPTS / "wowup-settings.py"),
                        PATH=f"{self.bin}:{os.environ['PATH']}")
        stub = f"#!{sys.executable}\n" + '''
import fcntl, os, pathlib, sys
home = pathlib.Path(os.environ["HOME"])
name = pathlib.Path(sys.argv[0]).name
with (home / "events").open("a") as events:
    if name == "zenity":
        assert "--error" in sys.argv, "session should not show a startup menu"
        events.write("error\\n")
    elif name == "swaymsg":
        events.write("sway " + " ".join(sys.argv[1:]) + "\\n")
    else:
        if name == "wowup-cf":
            # The parent wrapper must retain its own lock during the app.
            with (home / ".local/share/battlenet/wowup.lock").open("w") as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError("WoWUp wrapper released its lock too soon")
        events.write(name + " start\\n")
        events.write(name + " stop\\n")
        sys.exit(int(os.environ.get("APP_STATUS", "0")))
'''
        for name in ("zenity", "swaymsg", "wolf-battlenet", "wowup-cf"):
            path = self.bin / name
            path.write_text(stub)
            path.chmod(0o755)

    def run_script(self, name):
        return subprocess.run(["bash", SCRIPTS / name], env=self.env,
                              capture_output=True, text=True, timeout=5)

    def events(self):
        path = self.home / "events"
        return path.read_text().splitlines() if path.exists() else []

    def test_session_starts_only_battlenet_and_exits_when_done(self):
        result = self.run_script("battlenet-session.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["wolf-battlenet start", "wolf-battlenet stop", "sway exit"])

    def test_battlenet_failure_is_reported_before_session_exits(self):
        self.env["APP_STATUS"] = "7"
        result = self.run_script("battlenet-session.sh")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["wolf-battlenet start", "wolf-battlenet stop", "error", "sway exit"])

    def test_session_waits_for_open_addon_manager_after_game_quits(self):
        with (self.state / "wowup.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            process = subprocess.Popen(["bash", SCRIPTS / "battlenet-session.sh"], env=self.env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                deadline = time.monotonic() + 3
                while "sway workspace addons" not in self.events() and time.monotonic() < deadline:
                    time.sleep(0.02)
                self.assertIn("sway workspace addons", self.events())
                self.assertIsNone(process.poll(), "session ended while WoWUp was still open")
                fcntl.flock(lock, fcntl.LOCK_UN)
                _, stderr = process.communicate(timeout=3)
                self.assertEqual(process.returncode, 0, stderr)
                self.assertEqual(self.events()[-1], "sway exit")
            finally:
                fcntl.flock(lock, fcntl.LOCK_UN)
                if process.poll() is None:
                    process.kill()
                process.communicate(timeout=3)

    def test_duplicate_battlenet_is_still_rejected(self):
        with (self.state / "session.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("battlenet-launcher.sh")
            self.assertEqual(result.returncode, 1)
            self.assertIn("Battle.net is already running", result.stderr)

    def test_addons_can_run_while_game_lock_is_held(self):
        with (self.state / "session.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("wowup-launcher.sh")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), [
            "sway workspace addons", "wowup-cf start", "wowup-cf stop", "sway workspace game",
        ])

    def test_repeated_shortcut_focuses_existing_addon_manager(self):
        with (self.state / "wowup.lock").open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_script("wowup-launcher.sh")
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.events(), ["sway workspace addons", 'sway [class="(?i)wowup.*"] focus'])
        self.assertFalse((self.home / ".config/WowUpCf/preferences.json").exists())

    def test_addon_failure_is_reported_and_returns_to_game(self):
        self.env["APP_STATUS"] = "7"
        result = self.run_script("wowup-launcher.sh")
        self.assertEqual(result.returncode, 7, result.stderr)
        self.assertEqual(self.events(), [
            "sway workspace addons", "wowup-cf start", "wowup-cf stop", "error", "sway workspace game",
        ])

    def test_invalid_preferences_prevent_launch_and_return_to_game(self):
        preferences = self.home / ".config/WowUpCf/preferences.json"
        preferences.parent.mkdir(parents=True)
        preferences.write_text("{broken")
        result = self.run_script("wowup-launcher.sh")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(preferences.read_text(), "{broken")
        self.assertEqual(self.events(), ["sway workspace addons", "error", "sway workspace game"])


if __name__ == "__main__":
    unittest.main()
