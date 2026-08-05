import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SRC = pathlib.Path(__file__).resolve().parent

GPU_CMD = ("ffmpeg -hwaccel cuda -hwaccel_output_format cuda "
           "-i file:/data/in.mkv -c:v h264_nvenc -preset p1 /tmp/out.m3u8")


def write_script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


class TargetHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.record = self.tmp / "ffmpeg.argv"
        self.force_file = self.tmp / "force-software"

        # Stub ffmpeg: fails with a GPU signature when asked for nvenc,
        # succeeds otherwise. STUB_EXIT overrides the exit code.
        self.stub_ffmpeg = self.tmp / "ffmpeg"
        write_script(self.stub_ffmpeg, f'''echo "$@" >> {self.record}
if [ -n "$STUB_EXIT" ]; then exit "$STUB_EXIT"; fi
case "$*" in
  *nvenc*|*cuda*) echo "OpenEncodeSessionEx failed: out of memory" >&2; exit 1;;
esac
exit 0
''')
        self.stub_ffprobe = self.tmp / "ffprobe"
        write_script(self.stub_ffprobe, f'echo probe "$@" >> {self.record}\n')

        self.preflight = self.tmp / "preflight"
        write_script(self.preflight, "exit 0\n")

    def make_config(self, **overrides):
        cfg = {
            "ffmpeg": str(self.stub_ffmpeg),
            "ffprobe": str(self.stub_ffprobe),
            "preflight_command": [str(self.preflight)],
            "preflight_timeout": 4,
            "fast_fail_seconds": 20,
            "force_software_file": str(self.force_file),
            **overrides,
        }
        path = self.tmp / "target.json"
        path.write_text(json.dumps(cfg))
        return path

    def run_target(self, command, config=None, extra_env=None):
        env = dict(os.environ,
                   OKURI_TARGET_CONFIG=str(config or self.make_config()),
                   OKURI_LOG="stderr",
                   SSH_ORIGINAL_COMMAND=command)
        env.update(extra_env or {})
        return subprocess.run(
            [sys.executable, str(SRC / "target.py")],
            env=env, capture_output=True, text=True)

    def recorded(self):
        return self.record.read_text().splitlines() \
            if self.record.exists() else []


class TestSecurity(TargetHarness):
    def test_arbitrary_command_denied(self):
        ret = self.run_target("rm -rf /")
        self.assertEqual(ret.returncode, 126)
        self.assertEqual(self.recorded(), [])

    def test_absolute_path_smuggling_denied(self):
        ret = self.run_target("/bin/sh -c id")
        self.assertEqual(ret.returncode, 126)

    def test_empty_command_ok(self):
        ret = self.run_target("")
        self.assertEqual(ret.returncode, 0)


class TestGpuFallback(TargetHarness):
    def test_gpu_failure_retries_in_software(self):
        ret = self.run_target(GPU_CMD)
        self.assertEqual(ret.returncode, 0, ret.stderr)
        lines = self.recorded()
        self.assertEqual(len(lines), 2)
        self.assertIn("h264_nvenc", lines[0])
        self.assertIn("libx264", lines[1])
        self.assertNotIn("cuda", lines[1])
        self.assertIn("FALLBACK", ret.stderr)
        # The GPU attempt's stderr must still reach the caller.
        self.assertIn("OpenEncodeSessionEx", ret.stderr)

    def test_force_software_file_skips_gpu(self):
        self.force_file.touch()
        ret = self.run_target(GPU_CMD)
        self.assertEqual(ret.returncode, 0, ret.stderr)
        lines = self.recorded()
        self.assertEqual(len(lines), 1)
        self.assertIn("libx264", lines[0])

    def test_failed_preflight_skips_gpu(self):
        write_script(self.preflight, "exit 1\n")
        ret = self.run_target(GPU_CMD)
        self.assertEqual(ret.returncode, 0, ret.stderr)
        self.assertEqual(len(self.recorded()), 1)
        self.assertIn("libx264", self.recorded()[0])

    def test_non_gpu_error_not_retried(self):
        ret = self.run_target(
            "ffmpeg -i file:/data/in.mkv -c:v h264_nvenc out.ts",
            extra_env={"STUB_EXIT": "1"})
        self.assertEqual(ret.returncode, 1)
        self.assertEqual(len(self.recorded()), 1)


class TestPassthrough(TargetHarness):
    def test_version_goes_straight_through(self):
        ret = self.run_target("ffmpeg -version")
        self.assertEqual(ret.returncode, 0, ret.stderr)
        self.assertEqual(len(self.recorded()), 1)
        self.assertIn("-version", self.recorded()[0])

    def test_ffprobe_passthrough(self):
        ret = self.run_target("ffprobe -v quiet -show_streams x.mkv")
        self.assertEqual(ret.returncode, 0, ret.stderr)
        self.assertIn("probe", self.recorded()[0])

    def test_exit_255_translated(self):
        ret = self.run_target("ffmpeg -i plain.mkv out.ts",
                              extra_env={"STUB_EXIT": "255"})
        self.assertEqual(ret.returncode, 254)


if __name__ == "__main__":
    unittest.main()
