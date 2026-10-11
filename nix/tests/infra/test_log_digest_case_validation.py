#!/usr/bin/env python3
"""Persisted experiment history is validated before rendering or resuming it."""
import copy
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import test_log_digest as fixtures


agent = fixtures.agent
NOW = fixtures.NOW


class CaseValidationTests(unittest.TestCase):
    setUp = fixtures.DigestTests.setUp

    def test_tighter_query_policy_keeps_history_readable_but_rejects_new_wide_reads(self):
        history = self.make_history()
        test = history["cases"][0]["tests"][0]
        test["query"] = {"tool": "logs_count", "arguments": {"selector": '{service="app"}', "window": "48h"}}
        Path(self.temp.name, "investigations.json").write_text(json.dumps(history))
        cfg = dict(self.cfg, queryMaxLookbackHours=24)
        loaded = agent.InvestigationCases(cfg, NOW)
        self.assertEqual(len(loaded.records), 1)
        with self.assertRaises(ValueError):
            agent.observation_query(test["query"], cfg, NOW)

    def make_history(self, *, complete=True):
        cases = agent.InvestigationCases(self.cfg, NOW)
        case, attempt, unused = cases.begin({
            "vm": "TEST", "service": "app", "question": "Is the unit failed?",
            "hypothesis": "The application unit is failed.",
            "alternative": "The unit is active and only optional requests failed.",
            "prediction": "The failed-state metric will equal one.",
            "query": {"tool": "metrics_query", "arguments": {
                "expr": 'node_systemd_unit_state{vm="TEST",name="app.service",state="failed"}'}},
            "expect": {"operator": "eq", "value": 1}, "refs": ["unit:test"],
        }, self.pack["refs"], "test-run")
        if complete:
            cases.finish(case, attempt, "tool:test-run:1", {
                "kind": "tool_result", "tool": "metrics_query", "arguments": attempt["query"]["arguments"],
                "result": "query: failed-state\nvalue: 1",
                "measurements": {"samples": [{"labels": {}, "value": 1}], "truncated": False},
            })
        return json.loads(Path(cases.path).read_text())

    def assert_rejected_unchanged(self, data):
        path = Path(self.temp.name) / "investigations.json"
        source = json.dumps(data)
        path.write_text(source)
        with patch.object(agent, "write_json", side_effect=AssertionError("loading must never write")):
            with self.assertRaises(ValueError):
                agent.InvestigationCases(self.cfg, NOW)
        self.assertEqual(path.read_text(), source)
        self.prom.instant.assert_not_called()
        self.loki.instant.assert_not_called()

    def test_round_trip_pending_and_completed_history_loads_without_writes_or_queries(self):
        for complete in (False, True):
            path = Path(self.temp.name) / "investigations.json"
            path.unlink(missing_ok=True)
            source = self.make_history(complete=complete)
            before = path.read_bytes()
            with patch.object(agent, "write_json", side_effect=AssertionError("loading must never write")):
                restored = agent.InvestigationCases(self.cfg, NOW)
                self.assertIn("Is the unit failed?", restored.render())
            self.assertEqual(restored.records, source["cases"])
            self.assertEqual(path.read_bytes(), before)
        self.prom.instant.assert_not_called()
        self.loki.instant.assert_not_called()

    def test_new_store_and_missing_version_do_not_write(self):
        path = Path(self.temp.name) / "investigations.json"
        self.assertEqual(agent.InvestigationCases(self.cfg, NOW).records, [])
        self.assertFalse(path.exists())
        history = self.make_history()
        history.pop("version")
        path.write_text(json.dumps(history))
        self.assertEqual(agent.InvestigationCases(self.cfg, NOW).records, history["cases"])

    def test_invalid_version_top_level_capacity_and_duplicate_case_ids_are_rejected(self):
        source = self.make_history()
        variants = [None, [], {}, {"version": 1, "cases": {}},
                    {**source, "cases": source["cases"] * 2},
                    {**source, "cases": source["cases"] * 17}]
        variants.extend({**source, "version": version} for version in (0, 2, True, 1.0, "1", None))
        for variant in variants:
            with self.subTest(variant=str(variant)[:70]):
                self.assert_rejected_unchanged(variant)

    def test_required_case_fields_are_bounded_and_timestamps_are_timezone_aware(self):
        source = self.make_history()
        invalid = [("id", "case:../../other.json"), ("id", "case:00000000000G")]
        for key, limit in (("vm", 80), ("service", 80), ("question", 240), ("hypothesis", 300), ("alternative", 300)):
            invalid.extend((key, value) for value in (None, "", "  ", "x" * (limit + 1), []))
        for key in ("created_at", "updated_at"):
            invalid.extend((key, value) for value in (None, "not-a-date", "2026-09-07T01:30:00", 1))
        invalid.append(("alternative", source["cases"][0]["hypothesis"].upper()))
        for key, value in invalid:
            with self.subTest(key=key, value=str(value)[:70]):
                history = copy.deepcopy(source)
                history["cases"][0][key] = value
                self.assert_rejected_unchanged(history)

    def test_missing_render_dependencies_are_rejected_instead_of_later_key_errors(self):
        source = self.make_history()
        for key in ("id", "vm", "service", "question", "hypothesis", "alternative", "tests", "created_at", "updated_at"):
            with self.subTest(key=key):
                history = copy.deepcopy(source)
                del history["cases"][0][key]
                self.assert_rejected_unchanged(history)

    def test_invalid_test_identity_and_text_are_rejected(self):
        source = self.make_history()
        invalid = [("id", "test:wrong"), ("fingerprint", "not-a-fingerprint"), ("run_id", ""),
                   ("at", "2026-09-07T01:30:00"), ("at", "invalid"),
                   ("prediction", ""), ("prediction", "x" * 301),
                   ("reason", "x" * 501), ("reason", None), ("observation", "x" * 1201),
                   ("prospective", "yes"), ("prospective", 1),
                   ("refs", []), ("refs", ["ref"] * 7), ("refs", [None]), ("refs", ["x" * 301]),
                   ("evidence_ref", ""), ("evidence_ref", ["tool:1"])]
        for key, value in invalid:
            with self.subTest(key=key, value=str(value)[:70]):
                history = copy.deepcopy(source)
                history["cases"][0]["tests"][0][key] = value
                self.assert_rejected_unchanged(history)
        for tests in (None, {}, [None], source["cases"][0]["tests"] * 2, source["cases"][0]["tests"] * 7):
            history = copy.deepcopy(source)
            history["cases"][0]["tests"] = tests
            self.assert_rejected_unchanged(history)

    def test_invalid_saved_capabilities_are_never_dispatched(self):
        source = self.make_history()
        invalid = [
            {"tool": "shell", "arguments": {"expr": "up"}},
            {"tool": "logs_sample", "arguments": {"selector": '{service="app"}'}},
            {"tool": "metrics_range", "arguments": {"expr": "up"}},
            {"tool": "metrics_query", "arguments": {"expr": "up", "url": "file:///etc/passwd"}},
            {"tool": "metrics_query", "arguments": {"expr": "up offset 999d"}},
            {"tool": "metrics_query", "arguments": {"expr": "up", "end_ago": "999d"}},
            {"tool": "metrics_query", "arguments": {"expr": "x" * 2001}},
            {"tool": "logs_count", "arguments": {"selector": '{service="app"}', "step": "1h"}},
            {"tool": "logs_count", "arguments": {"selector": '{service="app"}', "by": ["vm"]}},
        ]
        for query in invalid:
            with self.subTest(query=query):
                history = copy.deepcopy(source)
                history["cases"][0]["tests"][0]["query"] = query
                self.assert_rejected_unchanged(history)

    def test_invalid_expectations_and_inconsistent_test_results_are_rejected(self):
        source = self.make_history()
        changes = [
            {"expect": {"operator": "eq", "value": True}},
            {"expect": {"operator": "eq", "value": float("inf")}},
            {"expect": {"operator": "unsupported", "value": 1}},
            {"status": "running"}, {"verdict": "proven"}, {"verdict": "pending"},
            {"verdict": "inconclusive", "value": 1}, {"value": None},
            {"value": True}, {"value": float("nan")}, {"value": float("inf")},
            {"value": "1"}, {"evidence_ref": None},
            {"status": "pending", "verdict": "pending", "value": 1, "evidence_ref": None},
            {"status": "pending", "verdict": "pending", "value": None},
        ]
        for updates in changes:
            with self.subTest(updates=updates):
                history = copy.deepcopy(source)
                history["cases"][0]["tests"][0].update(updates)
                self.assert_rejected_unchanged(history)


if __name__ == "__main__":
    unittest.main()
