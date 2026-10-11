#!/usr/bin/env python3
"""Measured hypothesis predictions cannot turn absent evidence into certainty."""
import copy
import unittest

import test_log_digest as fixtures


agent = fixtures.agent


class PredictionTests(unittest.TestCase):
    def entry(self, value=3, tool="metrics_query", **extra):
        return {
            "kind": "tool_result", "tool": tool,
            "arguments": {"expr": "service_failures"} if tool == "metrics_query" else {"selector": '{service="app"}'},
            "result": f"query: measurement\n\nvalue\n{value}",
            "measurements": {"samples": [{"labels": {}, "value": value}], "truncated": False},
            **extra,
        }

    def test_numeric_predicates_are_evaluated_from_measurements(self):
        for operator, expected, verdict in (
            ("gt", 2, "observed"), ("gt", 3, "not_observed"),
            ("lt", 4, "observed"), ("lt", 3, "not_observed"),
            ("eq", 3, "observed"), ("eq", 4, "not_observed"),
        ):
            with self.subTest(operator=operator, expected=expected):
                result = agent.evaluate_prediction(self.entry(), {"operator": operator, "value": expected})
                self.assertEqual(result["verdict"], verdict)
                self.assertEqual(result["value"], 3.0)
                self.assertIn("not its cause", result["reason"])

    def test_expectation_is_validated_before_evidence(self):
        invalid = [None, [], {}, {"operator": "gt"}, {"value": 1},
                   {"operator": "ge", "value": 1}, {"operator": [], "value": 1},
                   {"operator": "gt", "value": 1, "extra": "ignored?"}]
        invalid.extend({"operator": "gt", "value": value}
                       for value in (True, False, "1", None, [], float("nan"), float("inf"), -float("inf"), 10 ** 400))
        for expectation in invalid:
            with self.subTest(expectation=str(expectation)[:100]):
                with self.assertRaises(ValueError):
                    agent.validate_expectation(expectation)
                with self.assertRaises(ValueError):
                    agent.evaluate_prediction(None, expectation)

    def test_validation_returns_normalized_copy(self):
        original = {"operator": "lt", "value": -1}
        result = agent.validate_expectation(original)
        self.assertEqual(result, {"operator": "lt", "value": -1.0})
        self.assertIsInstance(result["value"], float)
        self.assertIsNot(result, original)

    def test_missing_ambiguous_and_nonfinite_measurements_are_inconclusive(self):
        entries = [None, {}, self.entry(kind="observation"), self.entry(tool="logs_sample"),
                   self.entry(tool="metrics_range"), self.entry(measurements=None),
                   self.entry(measurements={"samples": [], "truncated": False}),
                   self.entry(measurements={"samples": [{"value": 3}, {"value": 4}], "truncated": False}),
                   self.entry(measurements={"samples": [{"value": 3}, {"value": None}], "truncated": False}),
                   self.entry(measurements={"samples": [3], "truncated": False}),
                   self.entry(measurements={"samples": [{"value": 3}], "truncated": True}),
                   self.entry(tool="logs_count", arguments={"step": "1h"})]
        entries.extend(self.entry(value) for value in (True, False, None, [], "bad", "NaN", "Infinity", float("nan"), float("inf"), 10 ** 400))
        for entry in entries:
            with self.subTest(entry=str(entry)[:150]):
                result = agent.evaluate_prediction(entry, {"operator": "gt", "value": 0})
                self.assertEqual(result["verdict"], "inconclusive")
                self.assertIsNone(result["value"])

    def test_failed_missing_or_truncated_text_cannot_override_measurements(self):
        for result in (None, "", "  ", "error: timeout", "no data\nquery: example", "no matching lines",
                       "value: 3\n... TRUNCATED at 4000 chars. Narrow the query."):
            with self.subTest(result=result):
                verdict = agent.evaluate_prediction(self.entry(result=result), {"operator": "gt", "value": 0})
                self.assertEqual(verdict["verdict"], "inconclusive")

    def test_truncated_in_a_log_filter_or_metric_label_is_data_not_runner_truncation(self):
        for word in ("truncated", "TRUNCATED"):
            result = f'query: sum(count_over_time({{service="app"}} |= "{word} input"[1h]))\n\ntotal 3'
            verdict = agent.evaluate_prediction(self.entry(3, tool="logs_count", result=result),
                                                {"operator": "gt", "value": 0})
            self.assertEqual(verdict["verdict"], "observed")
            self.assertEqual(verdict["value"], 3)
        entry = self.entry(3, result='query: service_error_count{error="TRUNCATED"}\n\nvalue 3')
        self.assertTrue(agent.checked_evidence("tool:count", {"tool:count": entry}))
        entry["result"] += "\n... TRUNCATED at 30 chars. Narrow the query."
        self.assertFalse(agent.checked_evidence("tool:count", {"tool:count": entry}))

    def test_zero_matching_logs_tests_absence_without_claiming_recovery(self):
        entry = self.entry(0, "logs_count", result="no data (zero matching lines)\nquery: count_over_time(...)")
        for operator, expected, verdict in (("gt", 0, "not_observed"), ("eq", 0, "observed")):
            with self.subTest(operator=operator):
                result = agent.evaluate_prediction(entry, {"operator": operator, "value": expected})
                self.assertEqual(result["verdict"], verdict)
                self.assertEqual(result["value"], 0.0)
                self.assertIn("No matching logs", result["reason"])
                self.assertIn("does not establish service health or recovery", result["reason"])

    def test_generic_no_data_never_becomes_zero_or_a_match(self):
        entries = [self.entry(0, result="no data (zero matching lines)\nquery: service_health"),
                   self.entry(0, "logs_count", result="no data\nquery: counts"),
                   self.entry(1, "logs_count", result="no data (zero matching lines)\nquery: counts")]
        for entry in entries:
            with self.subTest(entry=entry):
                result = agent.evaluate_prediction(entry, {"operator": "eq", "value": 0})
                self.assertEqual(result["verdict"], "inconclusive")

    def test_numeric_string_measurements_are_supported_without_mutation(self):
        entry = self.entry("0.25")
        original = copy.deepcopy(entry)
        result = agent.evaluate_prediction(entry, {"operator": "lt", "value": 0.5})
        self.assertEqual(result["verdict"], "observed")
        self.assertEqual(result["value"], 0.25)
        self.assertEqual(entry, original)


if __name__ == "__main__":
    unittest.main()
