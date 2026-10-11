#!/usr/bin/env python3
"""Offline behavior checks for bounded, evidence-backed log comparisons."""
import json
import time
import unittest
from datetime import timedelta
from unittest.mock import Mock

import test_log_digest as fixtures
from test_log_digest_investigation import message_patterns


agent = fixtures.agent
NOW = fixtures.NOW


class ComparisonTests(unittest.TestCase):
    setUp = fixtures.DigestTests.setUp

    def compare(self, **extra):
        return self.tools.call("compare_logs", dict(selector='{service="app"}', **extra))

    def counts(self, *values):
        self.loki.instant.side_effect = [value if isinstance(value, Exception) else
                                         ([] if value == 0 else [({}, value)]) for value in values]

    def sample(self, messages=("Failed to open database",)):
        self.loki.streams.return_value = [
            ({"vm": "TEST", "service": "app"}, agent.to_ns(NOW - timedelta(seconds=index)),
             {"MESSAGE": message}, "") for index, message in enumerate(messages)
        ]

    def test_schema_guides_one_call_comparison_and_safe_filters(self):
        schema = {item["function"]["name"]: item["function"] for item in self.tools.schema()}
        self.assertIn("compare_logs", schema)
        self.assertIn("at most five read queries", schema["compare_logs"]["description"])
        self.assertEqual(schema["compare_logs"]["parameters"]["required"], ["selector"])
        self.assertFalse(schema["compare_logs"]["parameters"]["additionalProperties"])

    def test_equal_adjacent_windows_and_log_share_separate_volume_from_failure_rate(self):
        # Twice as many matching lines, but four times as many total logs.
        self.counts(40, 20, 400, 100)
        self.sample()
        result = json.loads(self.compare(contains="Failed", end_ago="2h", window="30m"))
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["delta"], 20)
        self.assertEqual(result["rate_ratio"], 2)
        self.assertEqual(result["current"]["matches"]["rate_per_hour"], 80)
        self.assertEqual(result["current"]["log_share"], 0.1)
        self.assertEqual(result["previous"]["log_share"], 0.2)
        self.assertAlmostEqual(result["log_share_delta"], -0.1)
        self.assertEqual(result["ingestion_coverage"], "unknown")
        self.assertIn("not request failure rate", result["interpretation"])
        self.assertEqual(result["previous"]["end_inclusive"], result["current"]["start_exclusive"])
        self.assertEqual(result["previous"]["start_exclusive"], agent.iso(NOW - timedelta(hours=3)))
        calls = self.loki.instant.call_args_list
        self.assertEqual([call.args[1] for call in calls], [
            NOW - timedelta(hours=2), NOW - timedelta(hours=2, minutes=30),
            NOW - timedelta(hours=2), NOW - timedelta(hours=2, minutes=30),
        ])
        self.assertTrue(all("[30m]" in call.args[0] for call in calls))
        self.assertEqual(message_patterns(calls[0].args[0]), ["(?s:.*(?:Failed).*)"])
        self.assertTrue(calls[0].args[0].endswith(" | drop __log_digest_message__[30m]))"))
        self.assertEqual(calls[2].args[0], 'sum (count_over_time({service="app"}[30m]))')

    def test_count_refs_and_checkpointed_children_are_real_evidence(self):
        self.counts(8, 4, 100, 50)
        self.sample()
        self.tools.checkpoint = Mock()
        result = json.loads(self.compare(contains="database"))
        self.assertEqual(len(self.tools.calls), 6)
        self.assertEqual(self.tools.checkpoint.call_count, 6)
        self.assertEqual(self.tools.calls[-1]["tool"], "compare_logs")
        self.assertIsNone(self.tools.calls[-1]["ref"])
        refs = [result[part][kind]["ref"] for part in ("current", "previous")
                for kind in ("matches", "total_logs")] + [result["sample"]["ref"]]
        self.assertEqual(len(set(refs)), 5)
        for ref in refs:
            self.assertIn(ref, self.pack["refs"])
            self.assertEqual(self.pack["refs"][ref]["kind"], "tool_result")
            self.assertIn(self.pack["refs"][ref]["tool"], ("logs_count", "logs_sample"))
        entry = self.pack["refs"][result["current"]["matches"]["ref"]]
        self.assertEqual(entry["measurements"]["samples"], [{"labels": {}, "value": 8}])

    def test_unfiltered_comparison_reuses_matching_counts_for_denominators(self):
        self.counts(3, 2)
        self.sample()
        result = json.loads(self.compare())
        self.assertEqual(result["window_seconds"], 3600)
        self.assertEqual(self.loki.instant.call_count, 2)
        self.assertEqual(len(self.tools.calls), 4)
        for part in ("current", "previous"):
            self.assertEqual(result[part]["matches"]["ref"], result[part]["total_logs"]["ref"])
            self.assertEqual(result[part]["log_share"], 1)

    def test_repeat_comparison_reuses_saved_reads_without_new_evidence(self):
        self.counts(8, 4, 100, 50)
        self.sample()
        first = json.loads(self.compare(contains="database"))
        original_refs = set(self.pack["refs"])
        repeated = json.loads(self.compare(contains="database"))
        self.assertEqual(first, repeated)
        self.assertEqual(self.loki.instant.call_count, 4)
        self.loki.streams.assert_called_once()
        self.assertEqual(len(self.tools.calls), 7)  # One local result plus the previous six calls.
        self.assertEqual(set(self.pack["refs"]), original_refs)

    def test_empty_counts_are_zero_but_zero_denominator_and_ratio_remain_unknown(self):
        self.counts(0, 0)
        result = json.loads(self.compare())
        self.assertEqual(result["status"], "complete")
        self.assertEqual(result["delta"], 0)
        self.assertIsNone(result["rate_ratio"])
        self.assertIn("zero", result["rate_ratio_unavailable"])
        for part in ("current", "previous"):
            self.assertEqual(result[part]["matches"]["count"], 0)
            self.assertIsNone(result[part]["log_share"])
            self.assertIn("no log lines observed", result[part]["log_share_unavailable"])
        self.assertIn("zero matching", result["sample"]["reason"])
        self.loki.streams.assert_not_called()

    def test_rise_from_zero_has_no_invented_finite_multiplier(self):
        self.counts(4, 0, 20, 10)
        self.sample()
        result = json.loads(self.compare(contains="Failed"))
        self.assertEqual(result["delta"], 4)
        self.assertIsNone(result["rate_ratio"])
        self.assertIn("undefined", result["rate_ratio_unavailable"])

    def test_read_failure_does_not_become_zero_or_recovery(self):
        self.counts(agent.QueryError("timeout"), 7, 30, 25)
        result = json.loads(self.compare(contains="Failed"))
        self.assertEqual(result["status"], "partial")
        self.assertIsNone(result["current"]["matches"]["count"])
        self.assertIn("timeout", result["current"]["matches"]["error"])
        self.assertIsNone(result["delta"])
        self.assertIsNone(result["rate_ratio"])
        self.assertIsNone(result["current"]["log_share"])
        self.assertNotIn("ref", result["current"]["matches"])
        self.loki.streams.assert_not_called()

    def test_failed_child_read_retried_while_successful_siblings_are_reused(self):
        self.counts(agent.QueryError("timeout"), 7, 30, 25, 2)
        self.sample()
        first = json.loads(self.compare(contains="Failed"))
        second = json.loads(self.compare(contains="Failed"))
        self.assertEqual(first["status"], "partial")
        self.assertEqual(second["status"], "complete")
        self.assertEqual(second["current"]["matches"]["count"], 2)
        self.assertEqual(second["previous"]["matches"]["ref"], first["previous"]["matches"]["ref"])
        self.assertEqual(self.loki.instant.call_count, 5)

    def test_budget_reserves_enclosing_call_and_keeps_successful_partial_results(self):
        self.cfg["maxToolCalls"] = 3
        self.counts(8, 4)
        result = json.loads(self.compare(contains="Failed"))
        self.assertEqual(len(self.tools.calls), 3)
        self.assertEqual(self.loki.instant.call_count, 2)
        self.loki.streams.assert_not_called()
        self.assertEqual(result["status"], "partial")
        self.assertEqual(result["delta"], 4)
        self.assertEqual(result["rate_ratio"], 2)
        self.assertIsNone(result["current"]["log_share"])
        self.assertIn("allowance", result["sample"]["error"])

    def test_last_call_cannot_run_unaccounted_child_reads(self):
        self.cfg["maxToolCalls"] = 1
        result = json.loads(self.compare(contains="Failed"))
        self.assertEqual(len(self.tools.calls), 1)
        self.assertEqual(result["status"], "partial")
        self.loki.instant.assert_not_called()
        self.loki.streams.assert_not_called()

    def test_query_deadline_stops_later_child_reads(self):
        def query_then_expire(*args):
            self.tools.query_deadline = time.monotonic() - 1
            return [({}, 2)]
        self.loki.instant.side_effect = query_then_expire
        result = json.loads(self.compare(contains="Failed"))
        self.assertEqual(result["current"]["matches"]["count"], 2)
        self.assertIsNone(result["previous"]["matches"]["count"])
        self.assertIn("deadline", result["previous"]["matches"]["error"])
        self.assertEqual(result["status"], "partial")
        self.loki.instant.assert_called_once()
        self.loki.streams.assert_not_called()

    def test_double_window_and_shift_validated_before_any_read(self):
        for arguments in ({"window": "4d"}, {"window": "3d", "end_ago": "2d"},
                          {"window": "0h"}, {"end_ago": "later"}, {"window": 1}):
            with self.subTest(arguments=arguments):
                self.assertTrue(self.compare(**arguments).startswith("error:"))
        self.loki.instant.assert_not_called()
        self.loki.streams.assert_not_called()

    def test_bare_selector_and_safe_filters_checked_before_any_read(self):
        for arguments in (
            {"selector": '{service="app"} |= "Failed"'},
            {"selector": '{service="app"} | json'},
            {"selector": 'sum(count_over_time({service="app"}[1h]))'},
            {"selector": '{service="app"}', "contains": ""},
            {"selector": '{service="app"}', "regex": "x" * 501},
            {"selector": '{service="app"}', "step": "1m"},
        ):
            with self.subTest(arguments=arguments):
                self.assertTrue(self.tools.call("compare_logs", arguments).startswith("error:"))
        self.loki.instant.assert_not_called()

    def test_label_and_filter_metacharacters_remain_literal(self):
        self.counts(0, 0, 3, 3)
        selector = '{service="app} | bizarre",vm=~`A|B`}'
        literal = 'a  b " } |= "oops\n\\'
        pattern = r'(?i)failed\s+"file"'
        result = self.tools.call("compare_logs", {"selector": selector, "contains": literal, "regex": pattern})
        self.assertEqual(json.loads(result)["status"], "complete")
        expression = self.loki.instant.call_args_list[0].args[0]
        self.assertTrue(expression.startswith(f"sum (count_over_time({selector} | label_format "))
        self.assertEqual(message_patterns(expression), [r'(?s:.*(?:a  b " \} \|= "oops' + '\n' + r'\\).*)',
                                                        f"(?s:.*(?:{pattern}).*)"])

    def test_samples_are_bounded_original_messages_and_not_a_count(self):
        self.counts(900, 400)
        messages = [f"Original detail number {index}" for index in range(6)]
        self.sample(messages)
        result = json.loads(self.compare())
        self.assertEqual(result["current"]["matches"]["count"], 900)
        self.assertEqual(self.loki.streams.call_args.args[-2:], (6, "backward"))
        self.assertEqual(len(result["sample"]["latest_lines"]), 6)
        self.assertIn("UTC TEST/app Original detail number 0", result["sample"]["latest_lines"][0])
        self.assertIn("not an event total", self.pack["refs"][result["sample"]["ref"]]["result"])

    def test_quote_heavy_samples_fit_the_actual_json_budget_and_preserve_full_evidence(self):
        self.counts(900, 400, 10000, 10000)
        message = '"' * 400
        self.sample([message] * 6)
        encoded = self.compare(contains="SQLITE")
        self.assertLessEqual(len(encoded), self.tools.max_chars)
        result = json.loads(encoded)
        self.assertEqual(result["current"]["matches"]["count"], 900)
        self.assertEqual(result["previous"]["matches"]["count"], 400)
        self.assertEqual(result["delta"], 500)
        self.assertTrue(result["sample"]["preview_shortened"])
        self.assertIn(message, self.pack["refs"][result["sample"]["ref"]]["result"])
        self.assertLessEqual(len(result["sample"]["latest_lines"]), 6)

    def test_invalid_measurement_and_inconsistent_denominator_not_presented_as_valid_counts(self):
        self.counts(None, 3, 10, 20)
        result = json.loads(self.compare(contains="Failed"))
        self.assertIsNone(result["current"]["matches"]["count"])
        self.assertEqual(result["status"], "partial")
        self.loki.instant.reset_mock()
        self.counts(30, 3, 10, 20)
        self.sample()
        result = json.loads(self.compare(contains="Different"))
        self.assertIsNone(result["current"]["log_share"])
        self.assertIn("inconsistent", result["current"]["log_share_unavailable"])

    def test_daytime_worker_cannot_run_composed_model_investigations(self):
        self.cfg["observationMode"] = True
        self.assertIn("only permits observability", self.compare())
        self.loki.instant.assert_not_called()


if __name__ == "__main__":
    unittest.main()
