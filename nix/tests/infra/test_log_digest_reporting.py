#!/usr/bin/env python3
"""Evidence calibration and recurrence regressions; no model or network access."""
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta, timezone
from types import SimpleNamespace


SOURCE = Path(os.environ.get("LOG_DIGEST_AGENT", Path(__file__).parents[2] / "lib/log-digest-agent.py"))
spec = importlib.util.spec_from_file_location("log_digest_reporting", SOURCE)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 10, 1, 1, 30, tzinfo=timezone.utc)


class ReportingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cfg = {"stateDir": self.temp.name}
        self.pack = {"refs": {
            "sig:app": {"kind": "signature", "vm": "TEST", "service": "app"},
            "tool:impact": {"kind": "tool_result", "tool": "logs_sample",
                            "arguments": {"selector": '{service="app"}', "window": "1h"},
                            "result": "query: {service=\"app\"}\n10-01 01:29:00 TEST/app request failed: connection refused"},
            "tool:current": self.metric('node_systemd_unit_state{name="app.service",state="failed"}', 1),
            "tool:healthy": self.metric('node_systemd_unit_state{name="app.service",state="active"}', 1),
        }}

    def metric(self, expression, value=1, **arguments):
        return {"kind": "tool_result", "tool": "metrics_query",
                "arguments": dict(expr=expression, **arguments),
                "result": f"query: {expression}\nlabels value\nTEST {value}",
                "measurements": {"samples": [{"labels": {"vm": "TEST"}, "value": value}], "truncated": False}}

    def finding(self, **updates):
        return dict({"title": "App requests fail", "what": "Requests cannot reach the application.",
                     "severity": "warning", "confidence": "high", "status": "ongoing", "impact": "degraded",
                     "refs": ["sig:app", "tool:impact", "tool:current"],
                     "impact_refs": ["tool:impact"], "current_refs": ["tool:current"]}, **updates)

    def validate(self, *findings, **raw):
        return agent.validate_digest(dict({"headline": "Model headline", "state": "needs_attention",
                                           "findings": list(findings)}, **raw), self.pack)

    def previous(self, status="ongoing", **updates):
        row = dict({"issue_id": "issue:existing", "title": "Previous title", "status": status,
                    "anchors": ["sig:app"], "severity": "warning"}, **updates)
        self.pack["report_history"] = [row]
        return row

    def test_same_signature_with_new_title_is_compact_ongoing(self):
        self.previous()
        report = self.validate(self.finding(title="A rewritten description of app errors", change="new"))
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["ongoing"][0]["issue_id"], "issue:existing")
        self.assertEqual(report["ongoing"][0]["change"], "unchanged")
        self.assertIn("No material change", report["headline"])

    def test_unverified_change_cannot_promote_a_repeat(self):
        self.previous()
        report = self.validate(self.finding(change="worsened", change_summary="Worse now", change_refs=["sig:app"]))
        self.assertEqual(report["findings"], [])
        self.assertEqual(len(report["ongoing"]), 1)

    def count(self, name, value, *, window="1h", end_ago="0s", selector='{service="app"}', contains="request failed"):
        entry = {"kind": "tool_result", "tool": "logs_count", "observed_at": agent.iso(NOW),
                 "arguments": {"selector": selector, "window": window, "end_ago": end_ago},
                 "result": f"count: {value}", "measurements": {
                     "samples": [{"labels": {}, "value": value}], "truncated": False}}
        if contains:
            entry["arguments"]["contains"] = contains
        self.pack["refs"][name] = entry
        return name

    def count_change(self, before=20, after=0, **updates):
        earlier = self.count("tool:before", before, end_ago="1h")
        current = self.count("tool:after", after)
        return self.finding(refs=["sig:app", earlier, current], change="improved",
                            change_summary="Fewer failed requests were logged.",
                            change_refs=[earlier, current], **updates)

    def test_current_zero_without_comparison_cannot_promote_improvement(self):
        self.previous()
        ref = self.count("tool:zero", 0)
        report = self.validate(self.finding(refs=["sig:app", ref], change="improved",
                                            change_refs=[ref], change_summary="Errors dropped to zero."))
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["ongoing"][0]["change"], "unchanged")

    def test_material_equal_window_change_remains_visible_without_claiming_recovery(self):
        self.previous()
        report = self.validate(self.count_change())
        finding = report["findings"][0]
        self.assertEqual((finding["change"], finding["status"]), ("improved", "unknown"))
        self.assertEqual(len(finding["change_measurements"]), 2)

    def test_small_unequal_unfiltered_or_incomplete_counts_cannot_promote_repeat(self):
        for mode in ("small", "unequal", "overlap", "distant", "unfiltered", "truncated", "wrong_direction"):
            with self.subTest(mode=mode):
                self.previous()
                finding = self.count_change(3 if mode == "small" else 20, 0)
                before = self.pack["refs"]["tool:before"]
                after = self.pack["refs"]["tool:after"]
                if mode == "unequal":
                    before["arguments"]["window"] = "24h"
                elif mode == "overlap":
                    before["arguments"]["end_ago"] = "30m"
                elif mode == "distant":
                    before["arguments"]["end_ago"] = "12h"
                elif mode == "unfiltered":
                    for entry in (before, after):
                        entry["arguments"].pop("contains")
                elif mode == "truncated":
                    before["measurements"]["truncated"] = True
                elif mode == "wrong_direction":
                    finding["change"] = "worsened"
                self.assertEqual(self.validate(finding)["findings"], [])

    def test_new_measurement_can_be_compared_with_preceding_report(self):
        before = self.count("tool:older", 20, end_ago="1d")
        measurements = agent.change_measurements([before], self.pack["refs"])
        self.previous(change_measurements=measurements)
        current = self.count("tool:current_count", 0)
        report = self.validate(self.finding(refs=["sig:app", current], change="improved",
                                            change_refs=[current], change_summary="Failed request frequency decreased."))
        self.assertEqual(report["findings"][0]["change"], "improved")

    def test_same_count_state_cannot_be_announced_as_improved_every_night(self):
        before = self.count("tool:older", 0, end_ago="1d")
        self.previous(change_measurements=agent.change_measurements([before], self.pack["refs"]))
        report = self.validate(self.count_change(20, 0))
        self.assertEqual(report["findings"], [])

    def test_old_comparison_cannot_reannounce_a_change(self):
        finding = self.count_change()
        measurements = agent.change_measurements(finding["refs"], self.pack["refs"])
        self.previous(change_measurements=measurements)
        self.assertEqual(self.validate(finding)["findings"], [])

    def test_already_recovered_issue_is_not_resolved_again(self):
        for change in ("resolved", "improved", "changed"):
            with self.subTest(change=change):
                self.previous(status="recovered", anchors=["sig:app", "unit:TEST:app.service"])
                report = self.validate(self.finding(status="recovered", change=change,
                    refs=["sig:app", "tool:healthy"], recovery_refs=["tool:healthy"],
                    change_refs=["tool:healthy"], change_summary="It has recovered again."))
                self.assertEqual(report["findings"], [])
                self.assertEqual(report["ongoing"][0]["status"], "recovered")

    def test_rejected_recovery_is_removed_from_published_prose(self):
        self.previous()
        ref = self.count("tool:zero", 0)
        report = self.validate(self.finding(title="App requests recovered", what="Errors have cleared.",
            why_it_matters="Functionality is restored.", evidence="Errors resolved.",
            status="recovered", refs=["sig:app", ref], recovery_refs=[ref], change="improved",
            change_refs=[ref], change_summary="The service recovered.", suggested_action="Restart app."))
        finding = report["ongoing"][0]
        self.assertEqual(finding["status"], "unknown")
        self.assertIn("recovery unverified", finding["title"])
        self.assertIn("do not establish recovery", finding["what"])
        self.assertEqual(finding["suggested_action"], "")
        self.assertNotIn("Errors resolved", finding["evidence"])

    def test_direct_service_state_comparison_can_establish_material_change(self):
        self.previous()
        expr = 'node_systemd_unit_state{name="app.service",state="failed"}'
        for ref, value, shift in (("tool:before", 0, "1h"), ("tool:after", 1, "0s")):
            self.pack["refs"][ref] = dict(self.metric(expr, value, end_ago=shift), observed_at=agent.iso(NOW))
        report = self.validate(self.finding(change="worsened", change_refs=["tool:before", "tool:after"],
            refs=["sig:app", "tool:before", "tool:after", "tool:impact"],
            current_refs=["tool:after"], change_summary="Unit changed from not failed to failed."))
        self.assertEqual(report["findings"][0]["change"], "worsened")

    def test_unchanged_info_is_quiet_but_operational_degradation_stays_notable(self):
        self.previous()
        quiet = self.validate(self.finding(severity="info", impact="none"))
        self.assertEqual(quiet["state"], "quiet")
        degraded = self.validate(self.finding())
        self.assertEqual(degraded["state"], "notable")

    def test_comparisons_survive_quiet_report_without_repeating_info_titles(self):
        self.previous()
        report = self.validate(self.finding(title="Routine known noise", severity="info", impact="none"))
        current = {"start_exclusive": "2026-10-01T00:30:00+00:00", "end_inclusive": agent.iso(NOW),
                   "matches": {"status": "ok", "count": 0, "ref": "tool:now"}}
        previous = {"start_exclusive": "2026-09-30T23:30:00+00:00", "end_inclusive": current["start_exclusive"],
                    "matches": {"status": "ok", "count": 2, "ref": "tool:before"}}
        call = {"tool": "compare_logs", "arguments": {"selector": '{service="app"}', "contains": "failed"},
                "result": json.dumps({"current": current, "previous": previous,
                                      "window_seconds": 3600, "status": "complete"})}
        tools = SimpleNamespace(calls=[call], notebook=None)
        budget = SimpleNamespace(summary=lambda: "gpu=10s")
        rendered = agent.render_digest(report, self.pack, budget, tools, NOW)
        self.assertIn("## What we checked", rendered)
        self.assertIn("0 matching lines", rendered)
        self.assertIn("versus 2", rendered)
        self.assertIn(current["start_exclusive"], rendered)
        self.assertIn("not failed-request rates or proof of recovery", rendered)
        self.assertNotIn("Routine known noise", rendered)

    def test_report_history_retains_numeric_continuity(self):
        self.previous()
        report = self.validate(self.count_change())
        report["generated_at"] = agent.iso(NOW - timedelta(minutes=1))
        Path(self.temp.name, "digest-2026-10-01T012900000000Z.json").write_text(json.dumps(report))
        history = agent.report_history(self.cfg, NOW)
        self.assertEqual(history[0]["change_measurements"], report["findings"][0]["change_measurements"])

    def test_verified_relapse_after_recovery_is_an_update_without_model_change_fields(self):
        self.previous(status="recovered")
        report = self.validate(self.finding())
        self.assertEqual(report["ongoing"], [])
        self.assertEqual(report["findings"][0]["change"], "worsened")
        self.assertEqual(report["findings"][0]["issue_id"], "issue:existing")

    def test_verified_recovery_is_an_update_without_model_change_fields(self):
        self.previous(anchors=["sig:app", "unit:TEST:app.service"])
        report = self.validate(self.finding(status="recovered", refs=["sig:app", "tool:healthy"],
                                            recovery_refs=["tool:healthy"]))
        self.assertEqual(report["ongoing"], [])
        finding = report["findings"][0]
        self.assertEqual((finding["status"], finding["change"], finding["severity"]), ("recovered", "resolved", "info"))

    def test_active_process_does_not_resolve_an_application_operation(self):
        self.previous()
        report = self.validate(self.finding(status="recovered", refs=["sig:app", "tool:healthy"],
                                            recovery_refs=["tool:healthy"]))
        self.assertEqual(report["findings"], [])
        self.assertEqual(report["ongoing"][0]["status"], "unknown")

    def test_unrelated_successful_housekeeping_does_not_resolve_plugin_failure(self):
        self.previous()
        self.pack["refs"]["tool:housekeeping"] = dict(self.pack["refs"]["tool:impact"],
            result='query: {service="app"}\n10-01 01:29 TEST/app Database optimization completed successfully')
        finding = self.finding(status="recovered", refs=["sig:app", "tool:housekeeping"],
                               recovery_refs=["tool:housekeeping"])
        self.assertEqual(self.validate(finding)["ongoing"][0]["status"], "unknown")
        entry = self.pack["refs"]["tool:housekeeping"]
        entry["arguments"] = dict(entry["arguments"], contains="plugin request")
        entry["result"] = 'query: {service="app"}\n10-01 01:29 TEST/app plugin request completed successfully'
        self.assertEqual(self.validate(finding)["findings"][0]["status"], "recovered")

    def test_different_active_unit_cannot_resolve_failed_unit(self):
        self.previous(anchors=["sig:app", "unit:OTHER:app.service"])
        report = self.validate(self.finding(status="recovered", refs=["sig:app", "tool:healthy"],
                                            recovery_refs=["tool:healthy"]))
        self.assertEqual(report["ongoing"][0]["status"], "unknown")

    def test_same_generic_title_does_not_merge_different_failed_units(self):
        self.pack["refs"].update({"unit:A:app.service": {"kind": "failed_unit"},
                                  "unit:B:other.service": {"kind": "failed_unit"}})
        self.previous(title="Service failed", anchors=["unit:A:app.service"])
        report = self.validate(self.finding(title="Service failed", refs=["unit:B:other.service"]))
        self.assertEqual(len(report["findings"]), 1)
        self.assertNotEqual(report["findings"][0]["issue_id"], "issue:existing")

    def test_explicit_issue_identity_survives_a_different_investigation_query(self):
        self.previous(anchors=["sig:older"])
        report = self.validate(self.finding(issue_id="issue:existing"))
        self.assertEqual(report["ongoing"][0]["issue_id"], "issue:existing")

    def test_failed_latest_and_corrupt_reports_do_not_erase_successful_history(self):
        success = {"generated_at": agent.iso(NOW - timedelta(hours=6)), "state": "notable",
                   "findings": [self.finding()], "ongoing": []}
        Path(self.temp.name, "digest-2026-09-30T193000000000Z.json").write_text(json.dumps(success))
        Path(self.temp.name, "digest-2026-10-01T003000000000Z.json").write_text(json.dumps({
            "generated_at": agent.iso(NOW - timedelta(hours=1)), "state": "failed"}))
        Path(self.temp.name, "digest-2026-10-01T010000000000Z.json").write_text("{broken")
        Path(self.temp.name, "digest-latest.json").write_text('{"state": "failed"}')
        rows = agent.report_history(self.cfg, NOW)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["anchors"], ["sig:app"])
        self.assertEqual(rows[0]["last_reported"], success["generated_at"])

    def test_state_is_derived_from_calibrated_severity(self):
        critical = self.validate(self.finding(severity="critical", impact="outage"), state="quiet")
        self.assertEqual(critical["state"], "needs_attention")
        warning = self.validate(self.finding(severity="critical", impact="degraded"))
        self.assertEqual(warning["state"], "notable")
        self.assertEqual(warning["findings"][0]["severity"], "warning")
        catalog_only = self.validate(self.finding(severity="critical", refs=["sig:app"]))
        self.assertEqual(catalog_only["state"], "notable")
        self.assertEqual(catalog_only["findings"][0]["severity"], "info")
        self.assertEqual(self.validate()["state"], "quiet")

    def test_report_history_keeps_old_anchors_with_latest_status(self):
        for hours, status, anchors in ((6, "ongoing", ["sig:old"]), (3, "recovered", ["sig:latest"])):
            at = NOW - timedelta(hours=hours)
            report = {"generated_at": agent.iso(at), "state": "notable", "findings": [
                self.finding(issue_id="issue:existing", status=status, anchors=anchors, refs=[])
            ]}
            name = "digest-" + at.strftime("%Y-%m-%dT%H%M%S%fZ") + ".json"
            Path(self.temp.name, name).write_text(json.dumps(report))
        rows = agent.report_history(self.cfg, NOW)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["status"], "recovered")
        self.assertEqual(set(rows[0]["anchors"]), {"sig:old", "sig:latest"})
        self.assertEqual(rows[0]["last_reported"], agent.iso(NOW - timedelta(hours=3)))

    def test_exporter_up_cannot_establish_application_outage_or_recovery(self):
        self.pack["refs"]["tool:up"] = self.metric('up{job="node",vm="TEST"}')
        report = self.validate(self.finding(severity="critical", impact="outage", refs=["tool:up"],
                                            impact_refs=["tool:up"], current_refs=["tool:up"]))
        self.assertEqual(report["findings"][0]["severity"], "info")
        report = self.validate(self.finding(status="recovered", refs=["tool:up"], recovery_refs=["tool:up"]))
        self.assertEqual(report["findings"][0]["status"], "unknown")

    def test_unknown_or_mixed_refs_drop_the_whole_finding(self):
        for refs in ([], ["missing"], ["sig:app", "missing"], "sig:app", ["sig:app", 1]):
            with self.subTest(refs=refs):
                report = self.validate(self.finding(refs=refs))
                self.assertEqual(report["findings"], [])
                self.assertEqual(report["dropped_unsupported"], ["App requests fail"])
                self.assertEqual(report["state"], "notable")

    def test_recovery_requires_positive_current_health_instead_of_missing_failures(self):
        invalid = [
            self.metric('node_systemd_unit_state{state="failed"}', 0),
            self.metric('node_systemd_unit_state{state="failed"}', 1),
            self.metric('node_systemd_unit_state{state="active"}', 0),
            self.metric('node_systemd_unit_state{state="active"}', 1, end_ago="1h"),
            dict(self.metric("app_health"), result="no data\nquery: app_health"),
            self.pack["refs"]["tool:impact"],
        ]
        for evidence in invalid:
            with self.subTest(evidence=evidence):
                self.pack["refs"]["tool:recovery"] = evidence
                report = self.validate(self.finding(status="recovered", refs=["tool:recovery"],
                                                    recovery_refs=["tool:recovery"]))
                self.assertEqual(report["findings"][0]["status"], "unknown")
                self.assertEqual(report["findings"][0]["recovery_refs"], [])

    def test_recent_success_log_can_support_recovery_but_filter_text_cannot(self):
        entry = dict(self.pack["refs"]["tool:impact"],
                     arguments={"selector": '{service="app"}', "window": "1h", "contains": "request"},
                     result='query: {service="app"} |= "success"\nSAMPLE: latest 1 lines\n10-01 01:29 TEST/app request completed successfully')
        self.pack["refs"]["tool:recovery"] = entry
        finding = self.finding(status="recovered", refs=["tool:recovery"], recovery_refs=["tool:recovery"])
        self.assertEqual(self.validate(finding)["findings"][0]["status"], "recovered")
        entry["result"] = 'query: {service="app"} |= "success"\nSAMPLE: latest 1 lines\n10-01 01:29 TEST/app request failed'
        self.assertEqual(self.validate(finding)["findings"][0]["status"], "unknown")

    def test_negative_or_failed_success_messages_do_not_prove_recovery(self):
        for message in ("request completed with errors", "service not healthy", "server never ready",
                        "cannot confirm successful operation", "operation completed with failures",
                        "service isn't healthy", "operation completed without success",
                        "operation completed unsuccessfully", "startup completed but health check fails"):
            with self.subTest(message=message):
                entry = dict(self.pack["refs"]["tool:impact"], result=(
                    'query: {service="app"}\n10-01 01:29 TEST/app ' + message))
                self.pack["refs"]["tool:recovery"] = entry
                report = self.validate(self.finding(status="recovered", refs=["tool:recovery"],
                                                    recovery_refs=["tool:recovery"]))
                self.assertEqual(report["findings"][0]["status"], "unknown")

    def test_recovery_metric_requires_direct_current_boolean_health(self):
        invalid = ("request_count", "app_success_total", "app_health_count", "1 - app_health",
                   'max_over_time(node_systemd_unit_state{state="active"}[7d])',
                   "max_over_time(app_health[5m])", "app_health == bool 0")
        for expression in invalid:
            with self.subTest(expression=expression):
                self.pack["refs"]["tool:recovery"] = self.metric(expression)
                self.assertFalse(agent.checked_evidence("tool:recovery", self.pack["refs"], current=True, recovery=True))
        for expression in ("app_health", "probe_success", 'node_systemd_unit_state{state="active"} == 1'):
            with self.subTest(expression=expression):
                self.pack["refs"]["tool:recovery"] = self.metric(expression)
                self.assertTrue(agent.checked_evidence("tool:recovery", self.pack["refs"], current=True, recovery=True))

    def test_instant_historical_aggregates_are_not_current_evidence(self):
        for expression in ("max_over_time(app_health[7d])", "max_over_time(max_over_time(app_health[1h])[1h:1m])"):
            with self.subTest(expression=expression):
                self.pack["refs"]["tool:old"] = self.metric(expression)
                self.assertFalse(agent.checked_evidence("tool:old", self.pack["refs"], current=True))
        # Brackets inside a label value are data, not a lookback duration.
        self.pack["refs"]["tool:now"] = self.metric('app_health{description="daily [7d] check"}')
        self.assertTrue(agent.checked_evidence("tool:now", self.pack["refs"], current=True))

    def test_truncated_evidence_cannot_satisfy_impact_gate(self):
        for suffix, truncated in (("\n... 4 more rows omitted", False), ("\n... 2 series omitted; narrow the expression", False),
                                  ("", True), ("\n... TRUNCATED at 4000 chars", False)):
            with self.subTest(suffix=suffix, truncated=truncated):
                entry = self.metric("app_failed_requests", 12)
                entry["result"] += suffix
                entry["measurements"]["truncated"] = truncated
                self.pack["refs"]["tool:truncated"] = entry
                report = self.validate(self.finding(refs=["tool:truncated"], impact_refs=["tool:truncated"]))
                self.assertEqual(report["findings"][0]["severity"], "info")

    def test_digest_caps_new_findings_at_three(self):
        findings = []
        for index in range(5):
            ref = f"sig:{index}"
            self.pack["refs"][ref] = {"kind": "signature"}
            findings.append(self.finding(title=f"Different issue {index}", refs=[ref]))
        self.assertEqual(len(self.validate(*findings)["findings"]), 3)


if __name__ == "__main__":
    unittest.main()
