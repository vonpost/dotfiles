"""Run inside the disposable VirtioFS test VM; all paths contain test data."""

import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import time


reader = Path("/var/cache/jellyfin/transcodes")
writer = Path("/worker-transcodes")
cached = Path("/cached-control")
payload = b"completed initialization data" * 100


def write_and_flush(path, data):
    with path.open("wb") as stream:
        stream.write(data)
        stream.flush()
        os.fsync(stream.fileno())


# A control using the original cached state mount must exhibit the original
# failure. Separate FUSE connections have independent caches even in one VM.
name = "cached-control"
write_and_flush(writer / name, b"")
assert (cached / name).stat().st_size == 0
write_and_flush(writer / name, payload)
assert (cached / name).stat().st_size == 0, "cached control did not reproduce stale metadata"
print("Original cached state mount reproduces stale zero-byte size", flush=True)

# The dedicated mount must observe writes, replacement and deletion immediately
# in both directions, including a size lookup made before the writer finishes.
for source, destination in [(writer, reader), (reader, writer)]:
    for index in range(10):
        name = f"coherence-{index}"
        write_and_flush(source / name, b"")
        assert (destination / name).stat().st_size == 0
        write_and_flush(source / name, payload)
        assert (destination / name).stat().st_size == len(payload)
        assert (destination / name).read_bytes() == payload
        write_and_flush(source / "replacement", b"replacement")
        (source / "replacement").replace(source / name)
        assert (destination / name).read_bytes() == b"replacement"
        (source / name).unlink()
        assert not (destination / name).exists()
print("Uncached exports observe writes, replacements and deletion in both directions", flush=True)

# Keep the database on its actual cached parent mount: WAL mode exercises the
# shared mmap used by SQLite, which cache=never would otherwise disable.
with sqlite3.connect("/var/lib/jellyfin/storage-test.db") as db:
    assert db.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    db.execute("CREATE TABLE probe (value TEXT)")
    db.execute("INSERT INTO probe VALUES ('database still works')")
    db.commit()
    assert db.execute("SELECT value FROM probe").fetchone()[0] == "database still works"
print("SQLite WAL remains usable on the cached database mount", flush=True)

# Generate real fMP4 HLS through the writer connection. As soon as a later
# segment exists, the reader must see a nonempty, complete initialization file.
command = [
    sys.argv[1], "-nostdin", "-hide_banner", "-loglevel", "error",
    "-re", "-f", "lavfi", "-i", "color=c=black:s=160x90:r=24",
    "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
    "-t", "6", "-c:v", "libx264", "-threads", "1", "-preset", "ultrafast",
    "-g", "24", "-c:a", "aac", "-f", "hls", "-hls_time", "1",
    "-hls_segment_type", "fmp4", "-hls_fmp4_init_filename", "init.mp4",
    "-hls_playlist_type", "vod", "-hls_segment_filename", str(writer / "seg%d.mp4"),
    str(writer / "out.m3u8"),
]
process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
try:
    deadline = time.monotonic() + 60
    while not (reader / "seg1.mp4").exists():
        assert time.monotonic() < deadline, "timed out waiting for HLS segments"
        assert process.poll() is None, "FFmpeg exited before producing two segments"
        # This deliberately examines the initialization file before it is ready.
        if (reader / "init.mp4").exists():
            (reader / "init.mp4").stat()
        time.sleep(0.01)
    size = (reader / "init.mp4").stat().st_size
    data = (reader / "init.mp4").read_bytes()
    assert size > 0 and size == len(data)
    assert data == (writer / "init.mp4").read_bytes()
    assert b"ftyp" in data and b"moov" in data
    _, error = process.communicate(timeout=60)
    assert process.returncode == 0, error.decode()
    for path in writer.glob("*.mp4"):
        observed = reader / path.name
        assert observed.stat().st_size == len(observed.read_bytes()) == path.stat().st_size
    print(f"fMP4 initialization is readable at segment readiness ({size} bytes)", flush=True)
finally:
    if process.poll() is None:
        process.kill()
    process.wait()
