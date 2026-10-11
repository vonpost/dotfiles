#!/usr/bin/env python3
"""Offline checks for investigation grounding and reliable query boundaries."""
import json
from pathlib import Path
import re
import unittest
from datetime import timedelta

import test_log_digest as fixtures


agent = fixtures.agent
NOW = fixtures.NOW


def message_patterns(expression):
    """Read the actual JSON-quoted RE2 patterns sent to Loki (no backend emulation)."""
    return [json.JSONDecoder().raw_decode(part)[0]
            for part in expression.split(" | __log_digest_message__=~")[1:]]


class InvestigationTests(unittest.TestCase):
    setUp = fixtures.DigestTests.setUp

    def test_observer_uses_the_same_safe_filter_quoting(self):
        query = {"tool": "logs_count", "arguments": {
            "selector": '{vm={{vm}},service="app"}', "regex": r"endpoint\\.example|failed",
            "window": "15m",
        }}
        rendered = agent.observation_query(query, self.cfg, NOW, {"vm": 'host"name'})
        result = self.tools.call(rendered["tool"], rendered["arguments"])
        self.assertFalse(result.startswith("error:"), result)
        expression = self.loki.instant.call_args.args[0]
        self.assertIn('vm="host\\"name"', expression)
        self.assertEqual(message_patterns(expression), [f"(?s:.*(?:{query['arguments']['regex']}).*)"])

    def test_synthesis_retry_reduces_the_failed_output_scope(self):
        llama = fixtures.FakeLlama([
            fixtures.completion(content='{"headline":"cut off"'),
            fixtures.completion(content='{"headline":"No new issues","findings":[]}'),
        ])
        result = agent.synthesize(self.cfg, llama, self.tools, self.budget, [], "pack")
        self.assertEqual(result["findings"], [])
        retry = llama.requests[-1][0][-1]["content"]
        self.assertIn("at most ONE", retry)
        self.assertIn("finish_reason=", retry)

    def test_literal_filter_is_one_quoted_string_even_with_injected_query_syntax(self):
        selector = '{vm="SOTO",service="jellyfin"}'
        literal = '"} | json | line_format "{{.secret}}" |~ "\\\\\n@ offset 999d [100d]'
        result = self.tools.call("logs_sample", {"selector": selector, "contains": literal})
        self.assertFalse(result.startswith("error:"), result)
        expression = self.loki.streams.call_args.args[0]
        self.assertTrue(expression.startswith(selector + " | label_format "))
        # A parser consumes the entire filter as one literal; the attempted
        # pipeline and duration operators never become LogQL syntax.
        pattern = message_patterns(expression)[0]
        self.assertIsNotNone(re.fullmatch(pattern, literal))
        self.assertIsNone(re.fullmatch(pattern, literal.replace("{{.secret}}", "secret")))
        self.assertEqual(expression.count(" | line_format "), 0)

    def test_regex_backslashes_quotes_and_unicode_reach_backend_unchanged(self):
        selector = '{service="grafana"}'
        pattern = r'(?i)token\s+"not found"|C:\\cache\\|réessayer'
        result = self.tools.call("logs_count", {"selector": selector, "regex": pattern, "window": "1h"})
        self.assertFalse(result.startswith("error:"), result)
        expression = self.loki.instant.call_args.args[0]
        self.assertTrue(expression.startswith(f"sum (count_over_time({selector} | label_format "))
        self.assertTrue(expression.endswith(" | drop __log_digest_message__[1h]))"))
        self.assertEqual(message_patterns(expression), [f"(?s:.*(?:{pattern}).*)"])

    def test_literal_and_regex_filters_compose_without_losing_significant_spaces(self):
        selector = '{service="jellyfin"}'
        result = self.tools.call("logs_sample", {"selector": selector, "contains": "a  b", "regex": r'error\s+5'})
        self.assertFalse(result.startswith("error:"), result)
        expression = self.loki.streams.call_args.args[0]
        self.assertEqual(message_patterns(expression), [r"(?s:.*(?:a  b).*)", r"(?s:.*(?:error\s+5).*)"])

    def test_structured_message_filter_uses_guarded_fallback_and_preserves_raw_envelopes(self):
        result = self.tools.call("logs_sample", {"selector": '{service="app"}', "contains": "429"})
        self.assertFalse(result.startswith("error:"), result)
        expression = self.loki.streams.call_args.args[0]
        template = json.JSONDecoder().raw_decode(expression.split(" | label_format __log_digest_message__=", 1)[1])[0]
        self.assertIn("fromJson $raw", template)
        self.assertIn('and (hasPrefix "{" (trim $raw)) $p', template)
        self.assertIn("or $p.MESSAGE $p.message $p.msg $raw", template)
        self.assertIn("{{ else }}{{ $raw }}", template)
        self.assertNotIn("line_format", expression)
        self.assertNotIn("drop __error__", expression)
        self.assertTrue(expression.endswith(" | drop __log_digest_message__"))

    def test_existing_explicit_pipeline_is_preserved_without_structured_filters(self):
        selector = '{service="app"} |= "raw  metadata" | json | __error__=""'
        result = self.tools.call("logs_sample", {"selector": selector})
        self.assertFalse(result.startswith("error:"), result)
        self.assertEqual(self.loki.streams.call_args.args[0], selector)

    def test_structured_message_filter_follows_an_existing_explicit_pipeline(self):
        selector = '{service="app"} |= "raw  metadata" | json | __error__=""'
        result = self.tools.call("logs_sample", {"selector": selector, "contains": "failed"})
        self.assertFalse(result.startswith("error:"), result)
        expression = self.loki.streams.call_args.args[0]
        self.assertTrue(expression.startswith(selector + " | label_format "))
        self.assertEqual(message_patterns(expression), ["(?s:.*(?:failed).*)"])

    def test_literal_re2_escaping_keeps_whitespace_and_punctuation_literal(self):
        literal = '\\.+*?()|[]{}^$ #&-~\n\t"'
        self.tools.call("logs_sample", {"selector": '{service="app"}', "contains": literal})
        expression = self.loki.streams.call_args.args[0]
        pattern = message_patterns(expression)[0]
        expected = '(?s:.*(?:\\\\\\.\\+\\*\\?\\(\\)\\|\\[\\]\\{\\}\\^\\$ #&-~\n\t").*)'
        self.assertEqual(pattern, expected)
        self.assertIsNotNone(re.fullmatch(pattern, "before\n" + literal + "\nafter"))

    def test_generated_template_does_not_consume_the_authored_expression_budget(self):
        selector = '{service="' + 'a' * 1650 + '"}'
        result = self.tools.call("logs_sample", {"selector": selector, "contains": "b" * 200})
        self.assertFalse(result.startswith("error:"), result)
        self.assertGreater(len(self.loki.streams.call_args.args[0]), 2000)
        self.loki.streams.reset_mock()
        result = self.tools.call("logs_sample", {"selector": selector, "contains": "b" * 400})
        self.assertTrue(result.startswith("error:"), result)
        self.loki.streams.assert_not_called()

    def test_invalid_structured_filters_fail_before_querying(self):
        for field in ("contains", "regex"):
            for value in ("", "x" * 501, ["error"], None):
                with self.subTest(field=field, value_type=type(value).__name__):
                    result = self.tools.call("logs_sample", {"selector": '{service="jellyfin"}', field: value})
                    self.assertTrue(result.startswith("error:"), result)
        self.loki.streams.assert_not_called()

    def test_repeated_query_points_to_original_evidence_without_querying_again(self):
        arguments = {"selector": '{service="jellyfin"}', "contains": "SQLite Error 5"}
        self.tools.call("logs_count", arguments)
        original_ref = self.tools.calls[-1]["ref"]
        repeated = self.tools.call("logs_count", dict(arguments))
        self.assertTrue(repeated.startswith("error:"), repeated)
        self.assertIn(original_ref, repeated)
        self.assertIsNone(self.tools.calls[-1]["ref"])
        self.loki.instant.assert_called_once()
        self.assertIn(original_ref, self.pack["refs"])

    def test_failed_query_can_be_retried_then_duplicate_points_to_successful_retry(self):
        self.loki.instant.side_effect = [agent.QueryError("temporary timeout"), [({}, 2)]]
        arguments = {"selector": '{service="jellyfin"}', "contains": "SQLite Error 5"}
        self.assertTrue(self.tools.call("logs_count", arguments).startswith("error:"))
        success = self.tools.call("logs_count", arguments)
        successful_ref = self.tools.calls[-1]["ref"]
        self.assertIn(successful_ref, success)
        self.assertIn(successful_ref, self.tools.call("logs_count", arguments))
        self.assertEqual(self.loki.instant.call_count, 2)

    def test_assistant_prose_without_a_tool_call_is_not_promoted_to_a_grounded_note(self):
        llama = fixtures.FakeLlama([fixtures.completion(content="Confirmed: the entire fleet is down.")])
        transcript = agent.investigate(self.cfg, llama, self.tools, self.budget, "pack")
        self.assertEqual(self.tools.notes, [])
        self.assertEqual(self.tools.calls, [])
        self.assertIn("the entire fleet is down", transcript[-1]["content"])
        self.prom.instant.assert_not_called()
        self.loki.instant.assert_not_called()

    def test_sample_distinguishes_returned_lines_from_total_and_marks_utc_timestamp(self):
        self.loki.streams.return_value = [
            ({"vm": "SOTO", "service": "jellyfin"}, agent.to_ns(NOW),
             {"MESSAGE": "[03:30:00] Error creating trickplay images"}, ""),
        ]
        result = self.tools.call("logs_sample", {"selector": '{service="jellyfin"}', "limit": 12})
        self.assertIn("SAMPLE: latest 1 lines, limit=12", result)
        self.assertIn("not an event total", result)
        self.assertIn("Use logs_count", result)
        self.assertIn("09-07 01:30:00 UTC SOTO/jellyfin", result)
        self.assertIn("[03:30:00]", result)

    def test_notes_require_nonempty_known_evidence_refs(self):
        for refs in (None, [], ["missing:ref"], ["unit:test", "missing:ref"]):
            with self.subTest(refs=refs):
                result = self.tools.call("note", {"text": "Confirmed outage", "refs": refs})
                self.assertTrue(result.startswith("error:"), result)
                self.assertEqual(self.tools.notes, [])
        self.assertEqual(self.tools.call("note", {"text": "A failed unit needs investigation",
                                                  "refs": ["unit:test"]}), "noted")
        self.assertEqual(self.tools.notes[0]["refs"], ["unit:test"])

    def test_reason_loads_recent_successful_report_history_even_if_latest_failed(self):
        previous = {
            "generated_at": agent.iso(NOW - timedelta(hours=3)), "state": "notable",
            "findings": [{"title": "Repeated indexer failures", "what": "Optional searches were affected",
                          "severity": "warning", "status": "unknown", "issue_id": "issue:existing",
                          "refs": ["sig:previous"]}],
        }
        stale = {
            "generated_at": agent.iso(NOW - timedelta(days=9)), "state": "notable",
            "findings": [{"title": "Expired historical claim", "refs": ["sig:stale"]}],
        }
        agent.write_json(str(Path(self.temp.name) / "digest-2026-09-06T223000000000Z.json"), previous)
        agent.write_json(str(Path(self.temp.name) / "digest-2026-08-29T013000000000Z.json"), stale)
        agent.write_json(str(Path(self.temp.name) / "digest-latest.json"), {"state": "failed"})
        # A previous history embedded in the hourly pack must be refreshed for
        # this run, since a successful digest may postdate pack collection.
        self.pack["report_history"] = [{"title": "Stale cached pack history"}]
        llama = fixtures.FakeLlama([
            fixtures.completion([("done", {})]),
            fixtures.completion(content=json.dumps({"headline": "No change", "findings": []})),
        ])
        self.assertEqual(fixtures.DigestTests.run_reason(self, llama), 0)
        prompt = llama.requests[0][0][1]["content"]
        self.assertIn("PREVIOUS REPORTS", prompt)
        self.assertIn("NOT current evidence", prompt)
        self.assertIn("issue:existing", prompt)
        self.assertIn("Repeated indexer failures", prompt)
        self.assertNotIn("Expired historical claim", prompt)
        self.assertNotIn("Stale cached pack history", prompt)
        stored_pack = agent.read_json(str(next(Path(self.temp.name).glob("evidence-*.json"))))
        self.assertEqual(stored_pack["report_history"][0]["issue_id"], "issue:existing")
        self.assertNotIn("sig:previous", stored_pack["refs"])


if __name__ == "__main__":
    unittest.main()
