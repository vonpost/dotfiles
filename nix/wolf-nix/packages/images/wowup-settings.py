"""Keep WoWUp visible when requested and make closing it quit, preserving other settings."""

import json
from pathlib import Path
import sys
import tempfile


def configure(path: Path) -> None:
    settings = json.loads(path.read_text(encoding="utf-8")) if path.exists() else {}
    if not isinstance(settings, dict):
        raise ValueError(f"Expected a JSON object in {path}")
    # electron-store stores these preferences as strings, not JSON booleans.
    settings.update({
        "collapse_to_tray": "false",
        "start_minimized": "false",
        "start_with_system": "false",
    })
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent, delete=False) as f:
        temporary = Path(f.name)
        try:
            json.dump(settings, f, indent=2)
            f.write("\n")
            f.close()
            temporary.replace(path)
        finally:
            temporary.unlink(missing_ok=True)


if __name__ == "__main__":
    configure(Path(sys.argv[1]))
