#!/usr/bin/env python3
"""Regression checks for useful output at the read cap and compute accounting."""
import json
from pathlib import Path
import time
import unittest

import test_log_digest as fixtures


agent = fixtures.agent


class BudgetTests(unittest.TestCase):
    setUp = fixtures.DigestTests.setUp

    def test_batched_reads_preserve_a_bounded_note_only_turn(self):
        self.cfg["maxToolCalls"] = 8
        llama = fixtures.FakeLlama([
            fixtures.completion([("metrics_query", {"expr": f"metric_{i}"}) for i in range(8)]),
            fixtures.completion([
                ("note", {"text": "The failed-unit evidence needs follow-up.", "refs": ["unit:test"]}),
                ("metrics_query", {"expr": "must_not_run"}),
                ("done", {}),
            ]),
        ])
        agent.investigate(self.cfg, llama, self.tools, self.budget, "pack")
        self.assertEqual(self.prom.instant.call_count, 4)
        self.assertEqual(len(self.tools.notes), 1)
        self.assertLessEqual(len(self.tools.calls), 8)
        self.assertEqual({tool["function"]["name"] for tool in llama.requests[1][1]["tools"]},
                         {"note", "followup", "done"})
        self.assertEqual(self.tools.investigation_stop_reason, "query_call_limit")
        self.assertEqual(self.budget.requests[-1]["phase"], "investigation_wrapup")
        audit = agent.investigation_audit(self.tools)
        self.assertEqual(audit["backend_query_calls"], 4)
        self.assertEqual(audit["model_tool_actions"], 11)
        self.assertEqual(audit["model_tool_action_errors"], 5)

    def test_composite_children_cannot_spend_reserved_note_slots(self):
        self.cfg["maxToolCalls"] = 8
        llama = fixtures.FakeLlama([
            fixtures.completion([("compare_logs", {"selector": '{service="app"}', "contains": "failed"})]),
            fixtures.completion([("note", {"text": "The comparison is incomplete.", "refs": ["unit:test"]}),
                                 ("done", {})]),
        ])
        agent.investigate(self.cfg, llama, self.tools, self.budget, "pack")
        self.assertEqual(len(self.tools.notes), 1)
        self.assertEqual(len(self.tools.calls), 6)
        self.assertEqual(self.loki.instant.call_count, 3)
        self.assertEqual(self.loki.streams.call_count, 0)
        audit = agent.investigation_audit(self.tools)
        self.assertEqual(audit["backend_query_calls"], 3)
        self.assertEqual(audit["model_tool_actions"], 3)
        self.assertEqual(self.tools.model_tool_actions[0]["recorded_calls"], 4)

    def test_wrapup_still_respects_synthesis_time_reserve(self):
        self.cfg["maxToolCalls"] = 8
        llama = fixtures.FakeLlama([])
        llama.deadline = time.monotonic() + 100
        self.tools.calls = [{"tool": "note", "arguments": {}, "ref": None, "result": "noted"}] * 4
        agent.investigate(self.cfg, llama, self.tools, self.budget, "pack")
        self.assertEqual(llama.requests, [])
        self.assertEqual(self.tools.investigation_stop_reason, "synthesis_wall_reserve")

    def test_success_and_failed_requests_have_distinct_compute_evidence(self):
        response = fixtures.completion(seconds=2)
        response["usage"] = {"prompt_tokens": 50, "completion_tokens": 20,
                             "prompt_tokens_details": {"cached_tokens": 30}}
        response["choices"][0]["finish_reason"] = "length"
        self.budget.record(response, phase="investigation", wall_seconds=3.5, token_cap=20)
        self.budget.record_failure("synthesis", RuntimeError("timeout"), 4.0, 500)
        self.assertEqual(self.budget.spent_seconds, 6)
        measured, estimated = self.budget.requests
        self.assertEqual(measured["finish_reason"], "length")
        self.assertEqual(measured["cached_tokens"], 30)
        self.assertEqual(measured["wall_seconds"], 3.5)
        self.assertFalse(measured["timings_estimated"])
        self.assertTrue(estimated["timings_estimated"])
        self.assertEqual(estimated["status"], "failed")

    def test_trace_keeps_synthesis_retries_and_stop_reason(self):
        llama = fixtures.FakeLlama([
            fixtures.completion([("done", {})]),
            RuntimeError("temporary inference failure"),
            fixtures.completion(content=json.dumps({"headline": "No supported change", "findings": []})),
        ])
        self.assertEqual(fixtures.DigestTests.run_reason(self, llama), 0)
        trace = json.loads(next(Path(self.temp.name).glob("trace-*.json")).read_text())
        self.assertEqual([request["status"] for request in trace["model_requests"]],
                         ["complete", "failed", "complete"])
        self.assertEqual(trace["investigation_audit"]["stop_reason"], "done")


if __name__ == "__main__":
    unittest.main()
