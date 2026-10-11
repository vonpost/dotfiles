#!/usr/bin/env python3
"""Durable hypothesis tests, query boundaries and incomplete-run recovery."""
import copy
import json
from pathlib import Path
import time
import unittest
from datetime import timedelta
from unittest.mock import patch

import test_log_digest as fixtures


agent = fixtures.agent
NOW = fixtures.NOW


class InvestigationCaseTests(unittest.TestCase):
    setUp = fixtures.DigestTests.setUp

    def proposal(self, **updates):
        return dict({
            "vm": "TEST", "service": "app",
            "question": "Is the app still unavailable?",
            "hypothesis": "The application unit remains failed.",
            "alternative": "The error was transient and the unit has recovered.",
            "prediction": "The failed-state metric will be one.",
            "query": {"tool": "metrics_query", "arguments": {
                "expr": 'node_systemd_unit_state{vm="TEST",name="app.service",state="failed"}'}},
            "expect": {"operator": "eq", "value": 1},
            "refs": ["unit:test"],
        }, **updates)

    def cases(self):
        return agent.InvestigationCases(self.cfg, NOW).records

    def run_case(self, proposal=None, tools=None):
        tools = tools or self.tools
        if tools.cases is None:
            tools.cases = agent.InvestigationCases(self.cfg, tools.now)
        result = tools.call("test_hypothesis", proposal or self.proposal())
        self.assertFalse(result.startswith("error:"), result)
        return json.loads(result)

    def restart(self, hours=3):
        at = NOW + timedelta(hours=hours)
        pack = {"generated_at": agent.iso(at), "refs": copy.deepcopy(self.pack["refs"])}
        tools = agent.Tools(self.cfg, self.loki, self.prom, pack, at, self.notebook)
        tools.cases = agent.InvestigationCases(self.cfg, at)
        return tools

    def test_prediction_is_saved_before_the_backend_sees_the_query(self):
        snapshots = []

        def dispatch(*unused):
            snapshots.append(agent.read_json(str(Path(self.temp.name) / "investigations.json")))
            return [({"vm": "TEST"}, 1)]

        self.prom.instant.side_effect = dispatch
        result = self.run_case()
        self.assertEqual(len(snapshots), 1)
        attempt = snapshots[0]["cases"][0]["tests"][0]
        self.assertEqual(attempt["status"], "pending")
        self.assertEqual(attempt["prediction"], self.proposal()["prediction"])
        self.assertEqual(attempt["query"], self.proposal()["query"])
        self.assertEqual(attempt["expect"], self.proposal()["expect"])
        self.assertEqual(result["verdict"], "observed")
        self.assertTrue(result["prospective"])
        self.assertEqual(self.cases()[0]["tests"][0]["status"], "complete")

    def test_result_has_an_actual_citable_query_and_does_not_certify_the_cause(self):
        result = self.run_case()
        ref = result["evidence_ref"]
        self.assertIn(ref, self.pack["refs"])
        self.assertEqual(self.pack["refs"][ref]["tool"], "metrics_query")
        self.assertEqual(result["value"], 1)
        self.assertIn("caus", result["caution"].lower())
        self.assertEqual([call["tool"] for call in self.tools.calls], ["metrics_query", "test_hypothesis"])

    def test_identical_plan_reuses_case_identity_across_sessions(self):
        first = self.run_case()
        second = self.run_case(tools=self.restart())
        self.assertEqual(first["case_id"], second["case_id"])
        self.assertEqual(len(self.cases()), 1)
        self.assertEqual(len(self.cases()[0]["tests"]), 2)
        self.assertEqual(self.prom.instant.call_count, 2)

    def test_large_declaration_stays_in_history_without_breaking_result_json(self):
        args = self.proposal(
            question='"' * 240, hypothesis='"' * 300,
            alternative='\\' * 300, prediction='"' * 300,
            query={"tool": "metrics_query", "arguments": {"expr": '"' * 1900}},
        )
        self.tools.max_chars = 2400
        result = self.run_case(args)
        self.assertLessEqual(len(self.tools.calls[-1]["result"]), 2400)
        self.assertEqual(result["verdict"], "observed")
        self.assertEqual(result["prediction"], args["prediction"])
        self.assertIn(result["evidence_ref"], self.pack["refs"])
        stored = self.cases()[0]
        self.assertEqual(stored["hypothesis"], args["hypothesis"])
        self.assertEqual(stored["tests"][0]["query"], args["query"])

    def test_same_run_duplicate_does_not_requery_or_append_history(self):
        first = self.run_case()
        second = self.run_case()
        self.assertEqual(first["case_id"], second["case_id"])
        self.assertEqual(first["evidence_ref"], second["evidence_ref"])
        self.assertEqual(first["prospective"], second["prospective"])
        self.assertEqual(len(self.cases()[0]["tests"]), 1)
        self.prom.instant.assert_called_once()

    def test_case_identifier_can_resume_without_repeating_immutable_prose(self):
        first = self.run_case()
        args = self.proposal()
        for key in ("vm", "service", "question", "hypothesis", "alternative"):
            args.pop(key)
        args["case_id"] = first["case_id"]
        args["prediction"] = "The active-state metric will be one."
        args["query"]["arguments"]["expr"] = 'node_systemd_unit_state{vm="TEST",name="app.service",state="active"}'
        second = self.run_case(args)
        self.assertEqual(second["case_id"], first["case_id"])
        self.assertEqual(len(self.cases()[0]["tests"]), 2)
        self.assertEqual(self.cases()[0]["hypothesis"], self.proposal()["hypothesis"])

    def test_reinterpreting_an_already_seen_query_is_marked_retrospective(self):
        args = self.proposal()
        self.tools.call("metrics_query", args["query"]["arguments"])
        original_ref = self.tools.calls[-1]["ref"]
        result = self.run_case(args)
        self.assertFalse(result["prospective"])
        self.assertEqual(result["evidence_ref"], original_ref)
        self.assertFalse(self.cases()[0]["tests"][0]["prospective"])
        self.prom.instant.assert_called_once()

    def test_changed_prediction_keeps_original_attempt_and_reuses_its_measurement(self):
        first = self.run_case()
        args = self.proposal(expect={"operator": "eq", "value": 0},
                             prediction="The failed-state metric will now be zero.")
        second = self.run_case(args)
        self.assertEqual(second["case_id"], first["case_id"])
        self.assertEqual(second["verdict"], "not_observed")
        self.assertFalse(second["prospective"])
        attempts = self.cases()[0]["tests"]
        self.assertEqual([attempt["verdict"] for attempt in attempts], ["observed", "not_observed"])
        self.assertTrue(attempts[0]["prospective"])
        self.prom.instant.assert_called_once()

    def test_same_question_on_distinct_targets_never_merges(self):
        first = self.run_case()
        args = self.proposal(vm="OTHER")
        args["query"]["arguments"]["expr"] = 'node_systemd_unit_state{vm="OTHER",name="app.service",state="failed"}'
        second = self.run_case(args)
        self.assertNotEqual(first["case_id"], second["case_id"])
        self.assertEqual(len(self.cases()), 2)

    def test_existing_case_cannot_be_repurposed_to_another_target(self):
        first = self.run_case()
        result = self.tools.call("test_hypothesis", self.proposal(case_id=first["case_id"], vm="OTHER"))
        self.assertTrue(result.startswith("error:"), result)
        self.assertEqual(self.cases()[0]["vm"], "TEST")
        self.assertEqual(len(self.cases()[0]["tests"]), 1)
        self.prom.instant.assert_called_once()

    def test_failed_read_keeps_plan_and_records_no_fabricated_measurement(self):
        self.prom.instant.side_effect = agent.QueryError("timeout")
        result = self.run_case()
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIsNone(result["evidence_ref"])
        self.assertIsNone(result["value"])
        saved = self.cases()[0]["tests"][0]
        self.assertIn("timeout", saved["reason"])
        self.assertEqual(saved["query"], self.proposal()["query"])
        self.assertEqual(set(self.pack["refs"]), {"unit:test"})

    def test_interrupted_backend_leaves_durable_pending_attempt(self):
        self.prom.instant.side_effect = KeyboardInterrupt()
        with self.assertRaises(KeyboardInterrupt):
            self.run_case()
        saved = self.cases()[0]["tests"][0]
        self.assertEqual(saved["status"], "pending")
        self.assertFalse(saved.get("evidence_ref"))
        self.assertEqual(saved["prediction"], self.proposal()["prediction"])

    def test_pending_case_survives_final_checkpoint_write_failure(self):
        self.tools.cases = agent.InvestigationCases(self.cfg, NOW)
        original_write = agent.write_json
        saves = []

        def fail_second_save(path, value):
            if path == self.tools.cases.path:
                saves.append(copy.deepcopy(value))
                if len(saves) == 2:
                    raise OSError("disk full")
            return original_write(path, value)

        with patch.object(agent, "write_json", side_effect=fail_second_save):
            result = self.tools.call("test_hypothesis", self.proposal())
        self.assertTrue(result.startswith("error:"), result)
        self.assertEqual(self.cases()[0]["tests"][0]["status"], "pending")
        self.assertTrue(any(entry.get("tool") == "metrics_query" for entry in self.pack["refs"].values()))

    def test_failed_initial_checkpoint_prevents_backend_dispatch(self):
        self.tools.cases = agent.InvestigationCases(self.cfg, NOW)
        with patch.object(agent, "write_json", side_effect=OSError("disk full")):
            result = self.tools.call("test_hypothesis", self.proposal())
        self.assertTrue(result.startswith("error:"), result)
        self.prom.instant.assert_not_called()

    def test_case_history_retains_only_six_most_recent_attempts(self):
        identifiers = []
        for index in range(9):
            args = self.proposal(prediction=f"Prediction number {index}.")
            result = self.run_case(args)
            identifiers.append(result["case_id"])
        cases = self.cases()
        self.assertEqual(len(set(identifiers)), 1)
        self.assertEqual(len(cases[0]["tests"]), 6)
        self.assertEqual(cases[0]["tests"][0]["prediction"], "Prediction number 3.")
        self.assertEqual(cases[0]["tests"][-1]["prediction"], "Prediction number 8.")

    def test_case_capacity_evicts_completed_history_and_preserves_pending_work(self):
        cases = agent.InvestigationCases(self.cfg, NOW)
        pending, unused, unused_reused = cases.begin(self.proposal(), self.pack["refs"], "interrupted")
        for index in range(18):
            case, attempt, unused_reused = cases.begin(
                self.proposal(question=f"Question number {index}?"), self.pack["refs"], f"run-{index}")
            cases.finish(case, attempt, None, None, error="temporarily unavailable")
        restored = self.cases()
        self.assertEqual(len(restored), 16)
        self.assertIn(pending["id"], {case["id"] for case in restored})
        self.assertEqual(next(case for case in restored if case["id"] == pending["id"])["tests"][0]["status"], "pending")

    def test_full_pending_case_and_attempt_queues_refuse_to_discard_unfinished_work(self):
        cases = agent.InvestigationCases(self.cfg, NOW)
        for index in range(6):
            cases.begin(self.proposal(prediction=f"Pending prediction {index}."), self.pack["refs"], "interrupted")
        before = copy.deepcopy(cases.records)
        with self.assertRaises(ValueError):
            cases.begin(self.proposal(prediction="One check too many."), self.pack["refs"], "interrupted")
        self.assertEqual(self.cases(), before)
        for index in range(15):
            cases.begin(self.proposal(question=f"Pending question {index}?"), self.pack["refs"], "interrupted")
        before = copy.deepcopy(cases.records)
        with self.assertRaises(ValueError):
            cases.begin(self.proposal(question="One case too many?"), self.pack["refs"], "interrupted")
        self.assertEqual(self.cases(), before)

    def test_competing_explanations_must_be_distinct_before_any_query(self):
        args = self.proposal()
        args["alternative"] = args["hypothesis"].upper()
        self.tools.cases = agent.InvestigationCases(self.cfg, NOW)
        result = self.tools.call("test_hypothesis", args)
        self.assertTrue(result.startswith("error:"), result)
        self.prom.instant.assert_not_called()
        self.assertEqual(self.cases(), [])

    def test_bad_nested_tools_are_rejected_before_any_backend_read(self):
        self.tools.cases = agent.InvestigationCases(self.cfg, NOW)
        for name in ("logs_sample", "metrics_range", "followup", "observation_plan", "test_hypothesis", "shell", "done"):
            with self.subTest(tool=name):
                args = self.proposal(query={"tool": name, "arguments": {"expr": "up"}})
                result = self.tools.call("test_hypothesis", args)
                self.assertTrue(result.startswith("error:"), result)
        self.prom.instant.assert_not_called()
        self.prom.series.assert_not_called()
        self.loki.instant.assert_not_called()
        self.loki.streams.assert_not_called()
        self.assertEqual(self.cases(), [])

    def test_range_log_counts_and_unknown_query_arguments_are_rejected(self):
        invalid = [
            {"tool": "logs_count", "arguments": {"selector": '{service="app"}', "step": "5m"}},
            {"tool": "metrics_query", "arguments": {"expr": "up", "url": "http://example.invalid"}},
            {"tool": "metrics_query", "arguments": {"expr": "up", "method": "POST"}},
        ]
        for query in invalid:
            with self.subTest(query=query):
                result = self.tools.call("test_hypothesis", self.proposal(query=query))
                self.assertTrue(result.startswith("error:"), result)
        self.prom.instant.assert_not_called()
        self.loki.instant.assert_not_called()

    def test_missing_or_invented_seed_evidence_cannot_start_an_investigation(self):
        for refs in ([], ["made-up"], ["unit:test", "made-up"], "unit:test"):
            with self.subTest(refs=refs):
                result = self.tools.call("test_hypothesis", self.proposal(refs=refs))
                self.assertTrue(result.startswith("error:"), result)
        self.prom.instant.assert_not_called()

    def test_nested_read_reserves_the_enclosing_call_budget(self):
        self.cfg["maxToolCalls"] = 1
        result = self.run_case()
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertEqual(len(self.tools.calls), 1)
        self.prom.instant.assert_not_called()

    def test_exact_two_call_budget_allows_one_test_and_one_real_query(self):
        self.cfg["maxToolCalls"] = 2
        result = self.run_case()
        self.assertEqual(result["verdict"], "observed")
        self.assertEqual(len(self.tools.calls), 2)
        self.prom.instant.assert_called_once()

    def test_synthesis_time_reserve_applies_inside_the_compound_tool(self):
        self.tools.query_deadline = time.monotonic() - 1
        result = self.run_case()
        self.assertEqual(result["verdict"], "inconclusive")
        self.assertIn("deadline", result["reason"])
        self.prom.instant.assert_not_called()

    def test_corrupt_case_store_is_not_silently_reset(self):
        path = Path(self.temp.name) / "investigations.json"
        path.write_text("{broken", encoding="utf-8")
        with self.assertRaises((ValueError, json.JSONDecodeError)):
            agent.InvestigationCases(self.cfg, NOW)
        self.assertEqual(path.read_text(encoding="utf-8"), "{broken")

    def test_failed_synthesis_preserves_a_readable_factual_test_result(self):
        llama = fixtures.FakeLlama([
            fixtures.completion([("test_hypothesis", self.proposal()), ("done", {})]),
            RuntimeError("model offline"), RuntimeError("model offline"),
        ])
        self.assertEqual(fixtures.DigestTests.run_reason(self, llama), 1)
        latest = agent.read_json(str(Path(self.temp.name) / "digest-latest.json"))
        self.assertEqual(latest["state"], "failed")
        checked = latest["investigation_results"]
        self.assertEqual(len(checked), 1)
        self.assertEqual(checked[0]["verdict"], "observed")
        self.assertEqual(checked[0]["value"], 1)
        self.assertIn("caus", checked[0]["caution"].lower())
        markdown = Path(self.temp.name, "digest-latest.md").read_text(encoding="utf-8")
        self.assertIn("What we checked", markdown)
        self.assertIn(checked[0]["evidence_ref"], markdown)
        saved_pack = agent.read_json(str(next(Path(self.temp.name).glob("evidence-*.json"))))
        self.assertIn(checked[0]["evidence_ref"], saved_pack["refs"])
        trace = agent.read_json(str(next(Path(self.temp.name).glob("trace-*.json"))))
        self.assertEqual(trace["status"], "failed")
        self.assertEqual(self.cases()[0]["tests"][0]["status"], "complete")

    def test_successful_report_retains_disconfirming_result_even_when_model_omits_it(self):
        self.prom.instant.return_value = [({"vm": "TEST"}, 0)]
        llama = fixtures.FakeLlama([
            fixtures.completion([("test_hypothesis", self.proposal()), ("done", {})]),
            fixtures.completion(content=json.dumps({"headline": "No new findings", "findings": []})),
        ])
        self.assertEqual(fixtures.DigestTests.run_reason(self, llama), 0)
        latest = agent.read_json(str(Path(self.temp.name) / "digest-latest.json"))
        checked = latest["investigation_results"]
        self.assertEqual(len(checked), 1)
        self.assertEqual(checked[0]["verdict"], "not_observed")
        markdown = Path(self.temp.name, "digest-latest.md").read_text(encoding="utf-8")
        self.assertIn("What we checked", markdown)
        self.assertIn(checked[0]["evidence_ref"], markdown)

    def test_historical_case_returns_to_prompt_without_becoming_current_evidence(self):
        previous = self.run_case()
        del self.pack["refs"][previous["evidence_ref"]]
        llama = fixtures.FakeLlama([
            fixtures.completion([("done", {})]),
            fixtures.completion(content=json.dumps({"headline": "No new findings", "findings": []})),
        ])
        self.assertEqual(fixtures.DigestTests.run_reason(self, llama, NOW + timedelta(hours=3)), 0)
        prompt = llama.requests[0][0][1]["content"]
        self.assertIn(previous["case_id"], prompt)
        self.assertIn("NOT current health evidence", prompt)
        latest = agent.read_json(str(Path(self.temp.name) / "digest-latest.json"))
        self.assertEqual(latest["investigation_results"], [])
        saved_pack = agent.read_json(str(next(Path(self.temp.name).glob("evidence-*.json"))))
        self.assertNotIn(previous["evidence_ref"], saved_pack["refs"])

    def test_historical_metric_report_uses_query_time_and_preserves_predeclared_prediction(self):
        args = self.proposal()
        args["query"]["arguments"]["end_ago"] = "3h"
        self.run_case(args)
        checked = agent.investigation_results(self.tools)
        self.assertEqual(checked[0]["observed_at"], agent.iso(NOW))
        self.assertEqual(checked[0]["query_evaluated_at"], agent.iso(NOW - timedelta(hours=3)))
        self.assertTrue(checked[0]["prospective"])
        rendered = agent.render_investigations(checked)
        self.assertIn("query evaluated at " + agent.iso(NOW - timedelta(hours=3)), rendered)
        self.assertIn("Historical query collected at " + agent.iso(NOW), rendered)
        self.assertIn("does not establish current health", rendered)
        self.assertNotIn("query already seen", rendered)

    def test_log_count_report_states_its_full_nonoverlapping_window(self):
        args = self.proposal(query={"tool": "logs_count", "arguments": {
            "selector": '{vm="TEST",service="app"}', "contains": "failed",
            "window": "1h", "end_ago": "2h"}})
        self.run_case(args)
        checked = agent.investigation_results(self.tools)
        self.assertEqual(checked[0]["query_evaluated_at"], agent.iso(NOW - timedelta(hours=2)))
        self.assertEqual(checked[0]["query_window_start"], agent.iso(NOW - timedelta(hours=3)))
        rendered = agent.render_investigations(checked)
        self.assertIn("log window (" + agent.iso(NOW - timedelta(hours=3)) + ", "
                      + agent.iso(NOW - timedelta(hours=2)) + "]", rendered)
        self.assertIn("does not establish current health", rendered)


if __name__ == "__main__":
    unittest.main()
