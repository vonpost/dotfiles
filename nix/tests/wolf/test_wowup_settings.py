"""Verify foreground behavior without losing addon or client preferences."""

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


source = Path(__file__).resolve().parents[2] / "wolf-nix/packages/images/wowup-settings.py"
spec = importlib.util.spec_from_file_location("wowup_settings", source)
settings = importlib.util.module_from_spec(spec)
spec.loader.exec_module(settings)


class WowUpSettingsTests(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.path = Path(directory.name) / "WowUpCf/preferences.json"

    def test_new_profile_closes_instead_of_hiding(self):
        settings.configure(self.path)
        self.assertEqual(json.loads(self.path.read_text()), {
            "collapse_to_tray": "false", "start_minimized": "false", "start_with_system": "false",
        })

    def test_existing_client_settings_survive(self):
        self.path.parent.mkdir()
        self.path.write_text(json.dumps({"collapse_to_tray": "true", "clients": [{"path": "/Games/WoW"}]}))
        settings.configure(self.path)
        actual = json.loads(self.path.read_text())
        self.assertEqual(actual["clients"], [{"path": "/Games/WoW"}])
        self.assertEqual(actual["collapse_to_tray"], "false")

    def test_invalid_settings_are_not_overwritten(self):
        self.path.parent.mkdir()
        for content in ("{broken", "[]", "null"):
            with self.subTest(content=content):
                self.path.write_text(content)
                with self.assertRaises(ValueError):
                    settings.configure(self.path)
                self.assertEqual(self.path.read_text(), content)


if __name__ == "__main__":
    unittest.main()
