"""Seed Battle.net preferences without replacing existing user settings."""

import json
import os
from pathlib import Path
import sys
import tempfile


# Launcher defaults from https://lutris.net/games/install/36240/view.
# Keep Wine/renderer behavior with GE's own defaults.
DEFAULTS = {
    "Client": {
        "GameLaunchWindowBehavior": "2",
        "GameSearch": {"BackgroundSearch": "true"},
        "HardwareAcceleration": "false",
        "Sound": {"Enabled": "false"},
        "Streaming": {"StreamingEnabled": "false"},
    }
}


def merge_defaults(settings, defaults):
    if not isinstance(settings, dict):
        raise ValueError("Battle.net settings must contain JSON objects")
    for key, default in defaults.items():
        if isinstance(default, dict):
            merge_defaults(settings.setdefault(key, {}), default)
        else:
            settings.setdefault(key, default)


def seed_defaults(prefix):
    # UMU/Proton uses steamuser, with the Unix user linked to it. Wine's
    # legacy 'Application Data' path points at this same Roaming directory.
    config = Path(prefix) / "drive_c/users/steamuser/AppData/Roaming/Battle.net/Battle.net.config"
    settings = json.loads(config.read_text(encoding="utf-8-sig")) if config.exists() else {}
    merge_defaults(settings, DEFAULTS)
    config.parent.mkdir(parents=True, exist_ok=True)
    # An interrupted write or invalid input must not corrupt saved settings.
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=config.parent, delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(settings, stream, indent=4)
            stream.write("\n")
            stream.close()
            os.replace(temporary, config)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    seed_defaults(sys.argv[1])
