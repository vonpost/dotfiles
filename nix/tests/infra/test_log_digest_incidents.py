"""Interruption evidence must survive the loss of the monitoring VM itself."""
import importlib.util
import json
import os
import re
from pathlib import Path
import unittest
from datetime import datetime, timedelta, timezone
from unittest.mock import Mock, patch

SOURCE = Path(os.environ.get("LOG_DIGEST_AGENT", Path(__file__).parents[2] / "lib/log-digest-agent.py"))
spec = importlib.util.spec_from_file_location("log_digest_incidents", SOURCE)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 11, 14, 17, 30, tzinfo=timezone.utc)
START = NOW - timedelta(hours=48)
GAP_START = datetime(2026, 11, 13, 23, 16, 40, tzinfo=timezone.utc).timestamp()
GAP_END = datetime(2026, 11, 14, 12, 20, 20, tzinfo=timezone.utc).timestamp()
BOOT = GAP_END - 86


def fleet():
    return [({"vm": vm}, [(GAP_START - 15 + n, 1), (GAP_START + n, 1)]
             + [(ts + n, 1) for ts in range(int(GAP_END), int(NOW.timestamp()), 15)])
            for n, vm in enumerate(("NIKKI", "SOTO", "MAMORU"))]


class InterruptionTests(unittest.TestCase):
    def test_incident_messages_do_not_publish_url_credentials(self):
        text = agent.incident_log_message('GET /videos/1/main/2.ts?ApiKey=secret&DeviceId=private HTTP/2 password=hunter2')
        self.assertNotIn("secret", text)
        self.assertNotIn("private", text)
        self.assertNotIn("hunter2", text)
        self.assertIn("/videos/1/main/2.ts?", text)

    def candidates(self, scrapes=None, boots=None):
        return agent.interruption_candidates(scrapes if scrapes is not None else fleet(),
                                             boots or [], START, NOW)

    def test_monitoring_outage_with_no_up_zero_is_grouped(self):
        # Deliberately only successful scrapes, as in the actual outage.
        events = self.candidates()
        first = events[0]
        self.assertEqual(first["kind"], "telemetry_gap")
        self.assertEqual(set(first["vms"]), {"NIKKI", "SOTO", "MAMORU"})
        self.assertEqual(first["start"], GAP_START)
        self.assertEqual(first["end"], GAP_END + 2)
        self.assertNotIn("scrape_failure", [e["kind"] for e in events])

    def test_recorded_mother_outage_reconstructs_one_fleet_interruption(self):
        data = json.loads((Path(__file__).parent / "fixtures/mother-20261114.json").read_text())
        end = datetime.fromtimestamp(max(g["next_sample"] for g in data["gaps"]) + 15, timezone.utc)
        scrapes = [({"vm": g["vm"]}, [(g["last_sample"], 1), (g["next_sample"], 1)])
                   for g in data["gaps"]]
        boots = [({"vm": b["vm"]}, [(end.timestamp(), agent.parse_iso(b["at"]).timestamp())])
                 for b in data["boots"]]
        events = agent.interruption_candidates(scrapes, boots, end - timedelta(hours=48), end)
        self.assertEqual(len(events), 1)
        self.assertEqual(len(events[0]["vms"]), 7)
        self.assertEqual(len(events[0]["boots"]), 7)
        self.assertAlmostEqual(events[0]["end"] - events[0]["start"], 47033.782, places=2)

    def test_boots_inside_gap_attach_to_same_event(self):
        boots = [({"vm": vm}, [(GAP_END, BOOT), (NOW.timestamp(), BOOT)])
                 for vm in ("NIKKI", "SOTO", "MAMORU")]
        first = self.candidates(boots=boots)[0]
        self.assertEqual(len(first["boots"]), 3)
        self.assertEqual(first["start"], GAP_START)  # Never anchor before reboot instead.

    def test_new_target_has_no_invented_leading_outage(self):
        self.assertEqual(self.candidates([({"vm": "NEW"}, [(NOW.timestamp() - 15, 1)])]), [])

    def test_old_boot_first_observed_today_is_not_a_reboot(self):
        self.assertEqual(self.candidates([], [({"vm": "NEW"}, [(NOW.timestamp(), START.timestamp() - 1)])]), [])

    def test_multiple_boots_in_window_are_not_reduced_to_latest_uptime(self):
        boots = [({"vm": "A"}, [(GAP_START, GAP_START - 60), (GAP_END, BOOT)])]
        events = self.candidates([], boots)
        self.assertEqual(len(events), 2)
        self.assertEqual({b["at"] for e in events for b in e["boots"]}, {GAP_START - 60, BOOT})

    def test_explicit_failed_scrapes_are_not_missing_telemetry(self):
        points = [(NOW.timestamp() - 15 * n, 0 if n > 1 else 1) for n in reversed(range(12))]
        events = self.candidates([({"vm": "A"}, points)])
        self.assertEqual([e["kind"] for e in events], ["scrape_failure"])

    def test_missing_tail_does_not_extend_explicit_failure(self):
        points = [(GAP_START - 15 * n, 0) for n in reversed(range(12))]
        events = self.candidates([({"vm": "A"}, points)])
        failed = next(e for e in events if e["kind"] == "scrape_failure")
        missing = next(e for e in events if e["kind"] == "telemetry_gap")
        self.assertEqual(failed["end"], GAP_START)
        self.assertEqual(missing["start"], GAP_START)
        self.assertTrue(missing["boundaries"][0]["open"])

    def test_exact_end_sample_is_not_marked_still_missing(self):
        events = self.candidates([({"vm": "A"}, [(GAP_START, 1), (NOW.timestamp(), 1)])])
        self.assertFalse(events[0]["boundaries"][0]["open"])

    def test_gap_start_before_daily_window_is_retained_until_recovery_ages_out(self):
        events = self.candidates([({"vm": "A"}, [
            (NOW.timestamp() - 30 * 3600, 1), (NOW.timestamp() - 15, 1)])])
        self.assertEqual(len(events), 1)
        self.assertEqual(events[0]["start"], NOW.timestamp() - 30 * 3600)

    def test_unrelated_outages_not_grouped_by_overlap(self):
        events = self.candidates([
            ({"vm": "A"}, [(GAP_START, 1), (NOW.timestamp(), 1)]),
            ({"vm": "B"}, [(GAP_START + 1000, 1), (NOW.timestamp(), 1)])])
        self.assertTrue(all(len(e["vms"]) == 1 for e in events))

    def test_raw_sample_api_preserves_real_timestamps_and_is_bounded(self):
        response = {"status": "success", "data": {"resultType": "matrix", "result": [
            {"metric": {"vm": "A"}, "values": [[GAP_START, "1"], [GAP_END, "1"]]}]}}
        with patch.object(agent, "http_get_json", return_value=response) as get:
            result = agent.Prometheus("http://test", 5).samples("up", START, NOW)
        self.assertEqual(result[0][1], [(GAP_START, 1), (GAP_END, 1)])
        self.assertTrue(get.call_args.args[0].endswith("/api/v1/query"))
        self.assertEqual(get.call_args.args[1]["query"], "up[172800s]")
        with self.assertRaises(agent.QueryError):
            agent.Prometheus("http://test").samples("up", START - timedelta(seconds=1), NOW)

    def test_evidence_failure_is_unknown_and_empty_synthesis_keeps_timeline(self):
        prom, loki = Mock(spec=agent.Prometheus), Mock(spec=agent.Loki)
        # Avoid artificial second gap after recovery in this focused fixture.
        scrapes = [({"vm": "NIKKI"}, [(GAP_START, 1), (NOW.timestamp() - 15, 1)])]
        prom.samples.side_effect = [scrapes, [({"vm": "NIKKI"}, [(NOW.timestamp(), BOOT)])]]
        prom.series.return_value = []
        loki.streams.side_effect = agent.QueryError("backend unavailable")
        refs, warnings = {}, []
        def guard(label, fn, default):
            try:
                return fn()
            except agent.QueryError as exc:
                warnings.append(str(exc))
                return default
        rows = agent.build_incident_rows({"digestVm": "NIKKI", "infrastructureHost": "MOTHER"},
                                         loki, prom, NOW, refs, guard)
        self.assertEqual(rows[0]["cause"], "unknown")
        self.assertTrue(warnings)
        self.assertTrue(any("no host scrape history" in s for s in rows[0]["limitations"]))
        self.assertTrue(any("monitoring VM" in s for s in rows[0]["limitations"]))
        # Pre-event metrics stop at the outage boundary, not at the recovery.
        for call in prom.series.call_args_list:
            self.assertEqual(call.args[2].timestamp(), GAP_START)
        pack = {"incidents": rows, "refs": refs, "warnings": warnings}
        digest = agent.validate_digest({"findings": [], "headline": "All fine"}, pack)
        self.assertEqual(digest["state"], "notable")
        self.assertIn("Infrastructure interruption", digest["headline"])
        tools = Mock(calls=[], notebook=None)
        tools.comparisons = []
        with patch.object(agent, "comparison_results", return_value=[]):
            report = agent.render_digest(digest, pack, Mock(summary=lambda: "no GPU"), tools, NOW)
        self.assertIn("Missing telemetry on NIKKI", report)
        self.assertNotIn("All fine", report)
        self.assertIn("Cause: unknown", report)
        self.assertTrue(all(c["ref"] in refs for c in rows[0]["context"]))

    def test_deadline_prevents_additional_network_reads(self):
        prom, loki = Mock(spec=agent.Prometheus), Mock(spec=agent.Loki)
        errors = []
        def guard(label, fn, default):
            try:
                return fn()
            except agent.QueryError as exc:
                errors.append(str(exc))
                return default
        with patch.object(agent.time, "monotonic", side_effect=[0, 91, 92]):
            rows = agent.build_incident_rows({}, loki, prom, NOW, {}, guard)
        self.assertEqual(rows, [])
        prom.samples.assert_not_called()
        self.assertEqual(len(errors), 2)

    def test_older_heavier_maintenance_is_available_as_counterevidence(self):
        prom, loki = Mock(spec=agent.Prometheus), Mock(spec=agent.Loki)
        prom.samples.side_effect = [fleet(), []]
        prom.series.return_value = []
        old = "btrbk-daily_state.service: Consumed 9G memory peak, 51G written to disk."
        recent = "btrbk-daily_state.service: Consumed 1G memory peak, 1G written to disk."
        history = [({"vm": "MOTHER", "service": "host-system"},
                    int((GAP_START - (13 - n) * 6 * 3600) * 1e9),
                    {"message": old if n == 0 else recent}, "") for n in range(12)]
        def streams(query, start, end, limit):
            return history if 'Consumed' in query else []
        loki.streams.side_effect = streams
        refs = {}
        rows = agent.build_incident_rows({"infrastructureHost": "MOTHER"},
                                        loki, prom, NOW, refs, lambda label, fn, default: fn())
        context = next(c for c in rows[0]["context"] if c["ref"].endswith(":maintenance_history"))
        self.assertEqual(len(context["rows"]), 12)
        self.assertEqual(agent.parse_iso(context["end"]).timestamp(), GAP_START - 1800)
        self.assertEqual(agent.parse_iso(context["start"]).timestamp(), GAP_START - 7 * 86400)
        self.assertIn('vm="MOTHER"', context["query"])
        self.assertEqual(context["sample_cap"], 40)
        self.assertIn("51G", agent.render_incidents(rows, evidence=True))
        self.assertNotIn("51G", agent.render_incidents(rows))  # Not a current crash signal.
        self.assertEqual(rows[0]["cause"], "unknown")
        self.assertEqual(refs[context["ref"]]["rows"], context["rows"])

    def test_host_reset_reason_before_guest_boots_is_retained_without_host_metrics(self):
        prom, loki = Mock(spec=agent.Prometheus), Mock(spec=agent.Loki)
        prom.samples.side_effect = [fleet(), [({"vm": "NIKKI"}, [(GAP_END, BOOT)])]]
        prom.series.return_value = []
        host_at = BOOT - 132
        message = ("x86/amd: Previous system reset reason [0x00080800]: "
                   "software wrote 0x6 to reset control register 0xCF9")
        def streams(query, start, end, limit):
            if (start.timestamp() <= host_at <= end.timestamp()
                    and re.search(agent.INCIDENT_LOG_PATTERN, message)):
                return [({"vm": "MOTHER", "service": "kernel"}, int(host_at * 1e9),
                         {"message": message}, "")]
            return []
        loki.streams.side_effect = streams
        rows = agent.build_incident_rows({"infrastructureHost": "MOTHER"},
                                        loki, prom, NOW, {}, lambda label, fn, default: fn())
        context = next(c for c in rows[0]["context"] if c["ref"].endswith(":boot_signals"))
        self.assertEqual(context["rows"][0]["message"], message)
        self.assertEqual(rows[0]["cause"], "unknown")
        self.assertTrue(any("no host scrape history" in s for s in rows[0]["limitations"]))


if __name__ == "__main__":
    unittest.main()
