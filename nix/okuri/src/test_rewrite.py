import unittest

import rewrite

# Captured verbatim from /var/lib/rffmpeg/rffmpeg.log on SOTO (trickplay job:
# CUDA decode + scale_cuda, CPU mjpeg encode).
TRICKPLAY = [
    "-loglevel", "error",
    "-init_hw_device", "cuda=cu:0",
    "-filter_hw_device", "cu",
    "-hwaccel", "cuda",
    "-hwaccel_output_format", "cuda",
    "-noautorotate",
    "-hwaccel_flags", "+unsafe_output",
    "-threads", "1",
    "-i", "file:/data/media/sonarr/Mushoku Tensei/S03E06.mkv",
    "-noautoscale", "-an", "-sn",
    "-vf",
    "fps=0.10000000149011612,setparams=color_primaries=bt709:"
    "color_trc=bt709:colorspace=bt709,"
    "scale_cuda=w=320:h=180:format=yuv420p,hwdownload,format=yuv420p",
    "-threads", "1",
    "-c:v", "mjpeg",
    "-qscale:v", "4",
    "-fps_mode", "passthrough",
    "-f", "image2",
    "/var/cache/jellyfin/transcodes/jellyfin/0a34/%08d.jpg",
]

# Jellyfin 10.10-shaped NVENC HLS transcode.
NVENC_HLS = [
    "-analyzeduration", "200M",
    "-init_hw_device", "cuda=cu:0",
    "-filter_hw_device", "cu",
    "-hwaccel", "cuda",
    "-hwaccel_output_format", "cuda",
    "-noautorotate",
    "-threads", "1",
    "-i", "file:/data/media/movie.mkv",
    "-map_metadata", "-1",
    "-map", "0:0", "-map", "0:1",
    "-codec:v:0", "h264_nvenc",
    "-preset", "p1",
    "-b:v", "5616000",
    "-maxrate", "5616000",
    "-bufsize", "11232000",
    "-g:v:0", "72",
    "-vf",
    "setparams=color_primaries=bt709:color_trc=bt709:colorspace=bt709,"
    "scale_cuda=w=1280:h=720:format=yuv420p",
    "-codec:a:0", "libfdk_aac",
    "-f", "hls",
    "-hls_segment_filename",
    "/var/cache/jellyfin/transcodes/x%d.ts",
    "-y", "/var/cache/jellyfin/transcodes/x.m3u8",
]


def has_gpu_token(args):
    return any("cuda" in a or "nvenc" in a or "cuvid" in a
               for a in args)


class TestWantsGpu(unittest.TestCase):
    def test_detects_cuda(self):
        self.assertTrue(rewrite.wants_gpu(TRICKPLAY))
        self.assertTrue(rewrite.wants_gpu(NVENC_HLS))

    def test_ignores_software_argv(self):
        self.assertFalse(rewrite.wants_gpu(
            ["-i", "x.mkv", "-c:v", "copy", "-c:a", "copy", "out.m3u8"]))

    def test_ignores_gpu_words_in_file_paths(self):
        self.assertFalse(rewrite.wants_gpu(
            ["-i", "file:/data/media/Barracuda (1978).mkv",
             "-c:v", "copy", "-f", "hls", "/tmp/out.m3u8"]))

    def test_detects_gpu_despite_gpu_word_in_path(self):
        self.assertTrue(rewrite.wants_gpu(
            ["-i", "file:/data/media/Barracuda (1978).mkv",
             "-c:v", "h264_nvenc", "/tmp/out.m3u8"]))


class TestRewriteTrickplay(unittest.TestCase):
    def setUp(self):
        self.out, self.notes = rewrite.rewrite_to_software(TRICKPLAY)

    def test_no_gpu_tokens_remain(self):
        self.assertFalse(has_gpu_token(self.out), self.out)

    def test_filter_chain(self):
        vf = self.out[self.out.index("-vf") + 1]
        self.assertEqual(
            vf,
            "fps=0.10000000149011612,setparams=color_primaries=bt709:"
            "color_trc=bt709:colorspace=bt709,"
            "scale=w=320:h=180,format=yuv420p",
        )

    def test_threads_unpinned(self):
        idx = [i for i, a in enumerate(self.out) if a == "-threads"]
        self.assertEqual([self.out[i + 1] for i in idx], ["0", "0"])

    def test_io_untouched(self):
        self.assertIn("file:/data/media/sonarr/Mushoku Tensei/S03E06.mkv",
                      self.out)
        self.assertEqual(self.out[-1],
                         "/var/cache/jellyfin/transcodes/jellyfin/0a34/%08d.jpg")


class TestRewriteNvencHls(unittest.TestCase):
    def setUp(self):
        self.out, self.notes = rewrite.rewrite_to_software(NVENC_HLS)

    def test_encoder_mapped(self):
        self.assertIn("libx264", self.out)
        self.assertFalse(has_gpu_token(self.out), self.out)

    def test_preset_mapped(self):
        self.assertEqual(self.out[self.out.index("-preset") + 1], "ultrafast")

    def test_scale_rewritten(self):
        vf = self.out[self.out.index("-vf") + 1]
        self.assertIn("scale=w=1280:h=720,format=yuv420p", vf)

    def test_rate_control_kept(self):
        for flag, val in (("-b:v", "5616000"), ("-maxrate", "5616000"),
                          ("-bufsize", "11232000")):
            self.assertEqual(self.out[self.out.index(flag) + 1], val)


class TestRewriteHdrTonemap(unittest.TestCase):
    ARGS = [
        "-hwaccel", "cuda", "-hwaccel_output_format", "cuda",
        "-i", "hdr.mkv",
        "-codec:v:0", "h264_nvenc", "-preset", "p4",
        "-vf",
        "setparams=color_primaries=bt2020:color_trc=smpte2084,"
        "tonemap_cuda=format=yuv420p:p=bt709:t=bt709:m=bt709:"
        "tonemap=bt2390:peak=100:desat=0,"
        "scale_cuda=w=1920:h=1080",
        "out.m3u8",
    ]

    def setUp(self):
        self.out, self.notes = rewrite.rewrite_to_software(self.ARGS)

    def test_software_tonemap_chain(self):
        vf = self.out[self.out.index("-vf") + 1]
        self.assertNotIn("_cuda", vf)
        self.assertIn("zscale=transfer=linear:npl=100", vf)
        self.assertIn("tonemap=tonemap=hable:desat=0", vf)
        self.assertIn("format=gbrpf32le", vf)

    def test_preset_clamped_to_ceiling(self):
        # p4 maps to "fast", which is slower than the veryfast ceiling.
        self.assertEqual(self.out[self.out.index("-preset") + 1], "veryfast")


class TestRewriteGraphLabels(unittest.TestCase):
    def test_overlay_with_labels(self):
        args = [
            "-filter_complex",
            "[0:1]hwupload_cuda[sub];[0:0][sub]overlay_cuda=x=0:y=0[vout]",
            "-map", "[vout]",
        ]
        out, _ = rewrite.rewrite_to_software(args)
        self.assertEqual(
            out[out.index("-filter_complex") + 1],
            "[0:1]null[sub];[0:0][sub]overlay=x=0:y=0[vout]",
        )

    def test_escaped_commas_survive(self):
        args = ["-vf",
                "subtitles=filename='/data/a\\,b.srt',scale_cuda=w=100:h=50"]
        out, _ = rewrite.rewrite_to_software(args)
        self.assertEqual(out[1],
                         "subtitles=filename='/data/a\\,b.srt',scale=w=100:h=50")


class TestRewriteMisc(unittest.TestCase):
    def test_cuvid_decoder_dropped(self):
        out, _ = rewrite.rewrite_to_software(
            ["-c:v", "h264_cuvid", "-i", "in.mkv",
             "-c:v", "h264_nvenc", "out.ts"])
        self.assertNotIn("h264_cuvid", out)
        self.assertIn("libx264", out)

    def test_svtav1_numeric_preset(self):
        out, _ = rewrite.rewrite_to_software(
            ["-codec:v:0", "av1_nvenc", "-preset", "p3", "out.mkv"])
        self.assertIn("libsvtav1", out)
        self.assertEqual(out[out.index("-preset") + 1], "10")

    def test_software_argv_unchanged(self):
        args = ["-i", "x.mkv", "-c:v", "libx264", "-preset", "veryfast",
                "-vf", "scale=1280:720", "out.m3u8"]
        out, notes = rewrite.rewrite_to_software(args)
        self.assertEqual(out, args)
        self.assertEqual(notes, [])

    def test_nvenc_tune_dropped_x264_tune_kept(self):
        out, _ = rewrite.rewrite_to_software(
            ["-c:v", "h264_nvenc", "-tune", "hq", "out.ts"])
        self.assertNotIn("hq", out)
        out2, _ = rewrite.rewrite_to_software(
            ["-c:v", "h264_nvenc", "-tune", "film", "out.ts"])
        self.assertIn("film", out2)


class TestGpuErrorSignatures(unittest.TestCase):
    def test_matches_nvenc_session_failure(self):
        self.assertTrue(rewrite.stderr_looks_gpu_related(
            "[h264_nvenc @ 0x1] OpenEncodeSessionEx failed: out of memory"))

    def test_matches_missing_device(self):
        self.assertTrue(rewrite.stderr_looks_gpu_related(
            "CUDA_ERROR_NO_DEVICE: no CUDA-capable device is detected"))

    def test_ignores_ordinary_errors(self):
        self.assertFalse(rewrite.stderr_looks_gpu_related(
            "x.mkv: No such file or directory"))


if __name__ == "__main__":
    unittest.main()
