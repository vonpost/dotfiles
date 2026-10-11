#!/usr/bin/env python3
"""Regression cases for misleading digest evidence; no fleet or GPU access."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch


SOURCE = Path(os.environ.get("LOG_DIGEST_AGENT", Path(__file__).parents[2] / "lib/log-digest-agent.py"))
spec = importlib.util.spec_from_file_location("log_digest_evidence", SOURCE)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 10, 1, 1, 30, tzinfo=timezone.utc)


class EvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cfg = {"stateDir": self.temp.name, "baselineDays": 3,
                    "anomalyZThreshold": 3, "collectIntervalSeconds": 3600,
                    "digestVm": "TEST", "noiseServices": []}
        self.loki = Mock(spec=agent.Loki)
        self.prom = Mock(spec=agent.Prometheus)
        self.loki.instant.return_value = [({"vm": "TEST", "service": "app"}, 2400)]
        self.prom.instant.return_value = []
        self.catalog = agent.Catalog({"started_at": agent.iso(NOW - timedelta(days=10)), "signatures": {
            "sig:test": {"vm": "TEST", "service": "app", "unit": "app.service",
                         "severity": "error", "signature": "request failed", "example": "request failed",
                         "first_seen": agent.iso(NOW - timedelta(days=5)), "last_seen": agent.iso(NOW),
                         "total": 960, "days": {"2026-09-29": 240, "2026-09-30": 240}},
        }})
        self.rows = [
            {"at": agent.iso(NOW - timedelta(hours=hour)), "day": "2026-09-30",
             "interval_seconds": 3600, "volume": {"TEST/app": 100},
             "severity_counts": {"sig:test": 10}, "failed_units": [], "warnings": []}
            for hour in range(96)
        ]
        self.network = patch.object(agent.HTTP, "open", side_effect=AssertionError("network forbidden"))
        self.network.start()
        self.addCleanup(self.network.stop)

    def pack(self):
        Path(self.temp.name, "baseline.jsonl").write_text("".join(json.dumps(row) + "\n" for row in self.rows))
        return agent.build_evidence_pack(self.cfg, self.loki, self.prom, self.catalog, NOW)

    def test_small_stable_volume_shift_is_not_an_incident_candidate(self):
        for hour, row in enumerate(self.rows):
            totals = [2023, 1961, 1960, 1962]
            row["volume"]["TEST/app"] = totals[hour // 24] / 24
        self.assertEqual(self.pack()["volume_anomalies"], [])

    def test_volume_comparison_reports_the_measurement_used_for_its_score(self):
        for row in self.rows[:24]:
            row["volume"]["TEST/app"] = 200
        self.loki.instant.return_value = [({"vm": "TEST", "service": "app"}, 4500)]
        pack = self.pack()
        self.assertEqual(pack["volume_anomalies"][0]["today"], 4800)
        self.assertEqual(pack["totals"]["lines_24h"], 4500)
        self.assertIn('source_type!="digest"', self.loki.instant.call_args.args[0])

    def test_missing_stream_is_compared_with_its_previous_volume(self):
        for row in self.rows[:24]:
            row["volume"] = {}
        self.loki.instant.return_value = []
        pack = self.pack()
        self.assertEqual(pack["volume_anomalies"][0]["today"], 0)
        self.assertEqual(pack["volume_anomalies"][0]["median"], 2400)

    def test_small_stable_signature_shift_is_not_escalation(self):
        for hour, row in enumerate(self.rows):
            totals = [260, 240, 239, 241]
            row["severity_counts"]["sig:test"] = totals[hour // 24] / 24
        self.assertEqual(self.pack()["escalating"], [])

    def test_capped_or_failed_captures_cannot_establish_signature_silence(self):
        for warning in ("severity capture hit the 5000-line cap; counts are a floor, not a total",
                        "severity: query timed out"):
            with self.subTest(warning=warning):
                for row in self.rows[:24]:
                    row["severity_counts"] = {}
                self.rows[0]["warnings"] = [warning]
                pack = self.pack()
                self.assertEqual(pack["went_silent"], [])
                self.assertFalse(pack["baseline"]["signatures_complete"])
                self.assertTrue(any(warning in item for item in pack["warnings"]))

    def test_invalid_signature_baselines_do_not_disable_valid_volume_comparisons(self):
        for row in self.rows[:24]:
            row["volume"]["TEST/app"] = 200
            row["severity_counts"]["sig:test"] = 100
        for hour in (24, 48, 72):
            self.rows[hour]["warnings"] = ["severity: timeout"]
        pack = self.pack()
        self.assertEqual(pack["escalating"], [])
        self.assertEqual(len(pack["volume_anomalies"]), 1)

    def test_failed_volume_reads_do_not_disable_valid_signature_comparisons(self):
        self.rows[0]["warnings"] = ["volume: timeout"]
        for row in self.rows[:24]:
            row["volume"]["TEST/app"] = 200
            row["severity_counts"]["sig:test"] = 100
        pack = self.pack()
        self.assertEqual(pack["volume_anomalies"], [])
        self.assertEqual(len(pack["escalating"]), 1)

    def test_missing_unit_metric_does_not_claim_recovery(self):
        self.rows[0]["failed_units"] = ["TEST|app.service"]
        row = self.pack()["failed_units"][0]
        self.assertIsNone(row["current_failed"])
        self.assertIn("current state unavailable", row["state"])

    def test_zero_failed_metric_only_confirms_unit_no_longer_failed(self):
        self.rows[0]["failed_units"] = ["TEST|app.service"]
        self.prom.instant.side_effect = lambda expr, now: (
            [({"vm": "TEST", "name": "app.service"}, 0)]
            if expr == 'node_systemd_unit_state{state="failed"}' else []
        )
        row = self.pack()["failed_units"][0]
        self.assertIs(row["current_failed"], False)
        self.assertIn("activity unverified", row["state"])

    def test_old_and_future_boots_are_not_recent_reboots(self):
        self.prom.instant.return_value = [
            ({"vm": "OLD", "instance": "old"}, (NOW - timedelta(days=3)).timestamp()),
            ({"vm": "RECENT", "instance": "recent"}, (NOW - timedelta(hours=2)).timestamp()),
            ({"vm": "FUTURE", "instance": "future"}, (NOW + timedelta(hours=2)).timestamp()),
        ]
        baseline = [{"boot_time": {"old": (NOW - timedelta(days=9)).timestamp()}}]
        refs = {}
        rows = agent.build_reboot_rows(self.prom, NOW, refs, lambda label, fn, default: fn(), baseline)
        self.assertEqual([row["vm"] for row in rows], ["RECENT"])
        self.assertEqual(rows[0]["uptime_hours"], 2)

    def test_pack_labels_keep_measurement_separate_from_impact(self):
        pack = {"memory": [{"ref": "mem:TEST", "vm": "TEST", "pct_used": 90, "avail": "100MiB"}],
                "scrape_problems": [{"ref": "scrape:TEST", "vm": "TEST"}]}
        text = agent.render_pack(pack, self.cfg)
        self.assertIn("pressure or OOM not established", text)
        self.assertIn("does not establish host or application failure", text)
        self.assertNotIn("UNREACHABLE EXPORTERS", text)

    def test_media_command_options_and_titles_are_not_event_severity(self):
        messages = [
            'dispatch ffmpeg to gpu.lan: -hide_banner -threads 0 -loglevel warning -i /media/A Critical Error.mkv',
            'dispatch ffprobe to gpu.lan: -analyzeduration 200M -i file:/media/Failure.mkv -loglevel error',
            '[03:00:00] [INF] [16] MediaEncoder: Trickplay generation: /nix/store/example/bin/ffmpeg '
            '-loglevel error -i "/media/Fatal Error.mkv" -err_detect ignore_err',
        ]
        for message in messages:
            with self.subTest(message=message):
                self.assertEqual(agent.severity_of(message, 6), "info")

    def test_genuine_media_failures_survive_command_sanitization(self):
        messages = [
            'MediaBrowser.Common.FfmpegException: ffmpeg image extraction failed for /bin/ffmpeg -loglevel error',
            '[ERR] MediaEncoder: Trickplay generation: /bin/ffmpeg -loglevel error',
            'dispatch ffmpeg to gpu.lan: -loglevel warning -i /media/movie.mkv; failed with exit code 1',
            'dispatch ffmpeg to gpu.lan: -loglevel warning -i /media/movie.mkv; Error initializing filters',
            '[INF] ffmpeg image extraction failed for /bin/ffmpeg -loglevel error',
        ]
        for message in messages:
            with self.subTest(message=message):
                self.assertEqual(agent.severity_of(message, 6), "error")
        self.assertEqual(agent.severity_of('dispatch ffmpeg to gpu.lan: -loglevel error', 2), "critical")

    def test_native_log_level_is_preserved_when_message_has_no_severity_word(self):
        self.assertEqual(agent.severity_of('[ERR] encoder terminated unexpectedly', 6), "error")
        self.assertEqual(agent.severity_of('[WRN] indexer is slow', 6), "warn")

    def test_old_command_signatures_are_removed_from_every_pack_classification(self):
        entry = self.catalog.signatures["sig:test"]
        entry["example"] = '[03:00:00] [INF] MediaEncoder: Trickplay generation: /bin/ffmpeg -loglevel error'
        entry["severity"] = "critical"
        for age_days, count in ((0.1, 10), (5, 100), (5, 10), (5, 0)):
            with self.subTest(age_days=age_days, count=count):
                entry["first_seen"] = agent.iso(NOW - timedelta(days=age_days))
                for row in self.rows[:24]:
                    row["severity_counts"]["sig:test"] = count
                pack = self.pack()
                for section in ("new_signatures", "escalating", "ongoing", "went_silent"):
                    self.assertEqual(pack[section], [])
                self.assertNotIn("sig:test", pack["refs"])
        self.assertEqual(entry["severity"], "critical")  # Historical catalog is untouched.

    def test_catalog_reclassification_keeps_explicit_media_error(self):
        entry = self.catalog.signatures["sig:test"]
        entry["example"] = '[ERR] Trickplay generation: /bin/ffmpeg -loglevel error'
        entry["severity"] = "critical"
        pack = self.pack()
        self.assertEqual(pack["ongoing"][0]["severity"], "error")
        self.assertEqual(pack["refs"]["sig:test"]["severity"], "error")


if __name__ == "__main__":
    unittest.main()
