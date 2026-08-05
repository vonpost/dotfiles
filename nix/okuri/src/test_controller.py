import json
import os
import pathlib
import subprocess
import sys
import tempfile
import unittest

SRC = pathlib.Path(__file__).resolve().parent

GPU_ARGS = ["-hwaccel", "cuda", "-i", "file:/data/in.mkv",
            "-c:v", "h264_nvenc", "-preset", "p1", "/tmp/out.m3u8"]


def write_script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


class ControllerHarness(unittest.TestCase):
    def setUp(self):
        self.tmp = pathlib.Path(tempfile.mkdtemp())
        self.ssh_record = self.tmp / "ssh.argv"
        self.local_record = self.tmp / "local.argv"
        self.fake_local = self.tmp / "ffmpeg-local"
        write_script(self.fake_local, f'echo "$@" >> {self.local_record}\n')

    def make_ssh(self, body):
        fake_ssh = self.tmp / "ssh"
        write_script(fake_ssh, f'echo "$@" >> {self.ssh_record}\n' + body)
        return fake_ssh

    def make_config(self, ssh, fallback=None):
        cfg = {
            "target": {
                "ssh": str(ssh),
                "host": "okami.test",
                "user": "jf",
                "connect_timeout": 1,
                "persist": 0,
            },
            "local": {
                "ffmpeg": str(self.fake_local),
                "ffprobe": str(self.fake_local),
            },
            "fallback": {"enable": True, "fast_fail_seconds": 5,
                         **(fallback or {})},
        }
        path = self.tmp / "config.json"
        path.write_text(json.dumps(cfg))
        return path

    def run_controller(self, config, args, role="ffmpeg"):
        env = dict(os.environ,
                   OKURI_CONFIG=str(config),
                   OKURI_ROLE=role,
                   OKURI_LOG="stderr")
        return subprocess.run(
            [sys.executable, str(SRC / "controller.py")] + args,
            env=env, capture_output=True, text=True)

    def local_argv(self):
        return self.local_record.read_text() if self.local_record.exists() \
            else None


class TestDispatch(ControllerHarness):
    def test_success_passthrough(self):
        cfg = self.make_config(self.make_ssh("exit 0\n"))
        ret = self.run_controller(cfg, GPU_ARGS)
        self.assertEqual(ret.returncode, 0, ret.stderr)
        recorded = self.ssh_record.read_text()
        self.assertIn("jf@okami.test ffmpeg", recorded)
        self.assertIn("h264_nvenc", recorded)
        self.assertIsNone(self.local_argv())

    def test_argument_quoting(self):
        cfg = self.make_config(self.make_ssh("exit 0\n"))
        ret = self.run_controller(
            cfg, ["-i", "file:/data/media/A Show (2021) [x264]/e p.mkv",
                  "-f", "null", "-"])
        self.assertEqual(ret.returncode, 0, ret.stderr)
        self.assertIn("'file:/data/media/A Show (2021) [x264]/e p.mkv'",
                      self.ssh_record.read_text())


class TestFallback(ControllerHarness):
    def test_transport_failure_falls_back_with_rewrite(self):
        cfg = self.make_config(self.make_ssh("exit 255\n"))
        ret = self.run_controller(cfg, GPU_ARGS)
        self.assertEqual(ret.returncode, 0, ret.stderr)
        local = self.local_argv()
        self.assertIsNotNone(local)
        self.assertIn("libx264", local)
        self.assertNotIn("nvenc", local)
        self.assertIn("FALLBACK", ret.stderr)

    def test_remote_ffmpeg_error_is_not_retried(self):
        cfg = self.make_config(self.make_ssh("exit 1\n"))
        ret = self.run_controller(cfg, GPU_ARGS)
        self.assertEqual(ret.returncode, 1)
        self.assertIsNone(self.local_argv())

    def test_slow_transport_failure_propagates(self):
        cfg = self.make_config(self.make_ssh("sleep 1\nexit 255\n"),
                               fallback={"fast_fail_seconds": 0.2})
        ret = self.run_controller(cfg, GPU_ARGS)
        self.assertEqual(ret.returncode, 255)
        self.assertIsNone(self.local_argv())

    def test_fallback_disabled(self):
        cfg = self.make_config(self.make_ssh("exit 255\n"),
                               fallback={"enable": False})
        ret = self.run_controller(cfg, GPU_ARGS)
        self.assertEqual(ret.returncode, 255)
        self.assertIsNone(self.local_argv())

    def test_ffprobe_falls_back_without_rewrite(self):
        cfg = self.make_config(self.make_ssh("exit 255\n"))
        ret = self.run_controller(
            cfg, ["-v", "quiet", "-print_format", "json", "-show_streams",
                  "file:/data/in.mkv"],
            role="ffprobe")
        self.assertEqual(ret.returncode, 0, ret.stderr)
        self.assertIn("-show_streams", self.local_argv())


if __name__ == "__main__":
    unittest.main()
