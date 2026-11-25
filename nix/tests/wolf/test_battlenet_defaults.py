"""Check preference preservation and safe failure during Battle.net setup."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


source = Path(__file__).resolve().parents[2] / "wolf-nix/packages/images/battlenet-defaults.py"
spec = importlib.util.spec_from_file_location("battlenet_defaults", source)
defaults = importlib.util.module_from_spec(spec)
spec.loader.exec_module(defaults)


class BattleNetDefaultsTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.prefix = Path(self.directory.name)
        self.config = self.prefix / "drive_c/users/steamuser/AppData/Roaming/Battle.net/Battle.net.config"

    def write_settings(self, content):
        self.config.parent.mkdir(parents=True, exist_ok=True)
        self.config.write_text(content, encoding="utf-8")

    def test_fresh_profile_gets_launcher_defaults(self):
        defaults.seed_defaults(self.prefix)
        settings = json.loads(self.config.read_text())
        self.assertEqual(settings["Client"]["GameLaunchWindowBehavior"], "0")
        self.assertEqual(settings["Client"]["HardwareAcceleration"], "false")
        self.assertEqual(settings["Client"]["Sound"]["Enabled"], "false")
        self.assertEqual(settings["Client"]["Streaming"]["StreamingEnabled"], "false")

    def test_existing_preferences_and_unrelated_settings_survive(self):
        self.write_settings(json.dumps({
            "Client": {"GameLaunchWindowBehavior": "2", "HardwareAcceleration": "true",
                       "Sound": {"Enabled": "true", "Volume": 7}},
            "Other": {"setting": "preserved"},
        }))
        defaults.seed_defaults(self.prefix)
        settings = json.loads(self.config.read_text())
        self.assertEqual(settings["Client"]["HardwareAcceleration"], "true")
        self.assertEqual(settings["Client"]["GameLaunchWindowBehavior"], "0")
        self.assertEqual(settings["Client"]["Sound"], {"Enabled": "true", "Volume": 7})
        self.assertEqual(settings["Other"], {"setting": "preserved"})
        self.assertEqual(settings["Client"]["Streaming"]["StreamingEnabled"], "false")

    def test_invalid_settings_are_left_untouched(self):
        for content in ('{"Client":', '[]', '{"Client":null}', '{"Client":{"Sound":false}}'):
            with self.subTest(content=content):
                self.write_settings(content)
                with self.assertRaises(ValueError):
                    defaults.seed_defaults(self.prefix)
                self.assertEqual(self.config.read_text(), content)

    def test_rerunning_setup_is_idempotent(self):
        defaults.seed_defaults(self.prefix)
        original = self.config.read_bytes()
        defaults.seed_defaults(self.prefix)
        self.assertEqual(self.config.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
