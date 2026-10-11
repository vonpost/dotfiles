#!/usr/bin/env python3
"""Offline regression checks for persistent investigation memory."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest
from datetime import datetime, timedelta, timezone


SOURCE = Path(os.environ.get("LOG_DIGEST_AGENT", Path(__file__).parents[2] / "lib/log-digest-agent.py"))
spec = importlib.util.spec_from_file_location("log_digest_notebook", SOURCE)
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
NOW = datetime(2026, 10, 1, 1, 30, tzinfo=timezone.utc)


class NotebookTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.cfg = {"stateDir": self.temp.name}
        self.refs = {"query:current": {"result": "a measured current observation"}}
        self.book = agent.Followups(self.cfg, NOW)

    def proposal(self, **changes):
        proposal = dict(question="Why did the scheduled digest fail?", vm="LOKI",
                        service="logDigest", hypothesis="The request timed out",
                        next_check="Check the next completed scheduled run",
                        refs=["query:current"])
        proposal.update(changes)
        return proposal

    def test_same_question_reuses_identity_despite_label_and_punctuation_drift(self):
        self.book.update(self.proposal(), self.refs, "first")
        task_id = self.book.tasks[0]["id"]
        result = self.book.update(self.proposal(
            question="  WHY did  the scheduled digest fail. ", vm="", service="logdigest",
        ), self.refs, "second")
        self.assertEqual(len(self.book.tasks), 1)
        self.assertEqual(self.book.tasks[0]["id"], task_id)
        self.assertEqual(self.book.tasks[0]["vm"], "LOKI")
        self.assertEqual(self.book.tasks[0]["service"], "logDigest")
        self.assertEqual(self.book.tasks[0]["question"], self.proposal()["question"])
        self.assertEqual(self.book.tasks[0]["attempts"], 1)
        self.assertIn("preserved its original VM/service", result)

    def test_same_question_on_different_hosts_or_services_keeps_separate_tasks(self):
        self.book.update(self.proposal(), self.refs, "first")
        original = copy.deepcopy(self.book.tasks[0])
        self.book.update(self.proposal(vm="NIKKI", status="resolved", outcome="NIKKI run succeeded"),
                         self.refs, "second")
        self.book.update(self.proposal(service="llama-server"), self.refs, "third")
        self.assertEqual(len(self.book.tasks), 3)
        self.assertEqual(len({task["id"] for task in self.book.tasks}), 3)
        self.assertEqual(self.book.tasks[0], original)
        self.assertEqual(len(self.book.unique_tasks()), 3)
        self.assertEqual(len(self.book.due()), 2)
        rendered = self.book.render()
        for task in self.book.tasks:
            self.assertIn(task["id"], rendered)

    def test_missing_scope_rejects_ambiguous_question_without_changing_tasks(self):
        self.book.update(self.proposal(), self.refs, "first")
        self.book.update(self.proposal(vm="NIKKI"), self.refs, "first")
        original = copy.deepcopy(self.book.tasks)
        persisted = Path(self.book.path).read_text()
        with self.assertRaisesRegex(ValueError, "ambiguous.*task id"):
            self.book.update(self.proposal(vm="", status="resolved", outcome="A run succeeded"),
                             self.refs, "second")
        self.assertEqual(self.book.tasks, original)
        self.assertEqual(Path(self.book.path).read_text(), persisted)

    def test_unambiguous_scope_enrichment_prevents_later_cross_host_merge(self):
        self.book.update(self.proposal(vm=""), self.refs, "first")
        original_id = self.book.tasks[0]["id"]
        self.book.update(self.proposal(vm="LOKI"), self.refs, "second")
        self.assertEqual(self.book.tasks[0]["id"], original_id)
        self.assertEqual(self.book.tasks[0]["vm"], "LOKI")
        self.book.update(self.proposal(vm="NIKKI"), self.refs, "third")
        self.assertEqual(len(self.book.tasks), 2)
        self.assertEqual(len(self.book.unique_tasks()), 2)

    def test_legacy_missing_scope_cannot_hide_two_distinct_hosts(self):
        self.book.update(self.proposal(), self.refs, "first")
        self.book.update(self.proposal(vm="NIKKI"), self.refs, "first")
        generic = copy.deepcopy(self.book.tasks[0])
        generic.update(id="task:legacy-generic", vm="", status="resolved",
                       outcome="An unspecified run succeeded", updated_at=agent.iso(NOW + timedelta(hours=1)))
        self.book.tasks.append(generic)
        self.assertEqual(len(self.book.unique_tasks()), 3)
        self.assertEqual(len(self.book.due()), 2)
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            self.book.update(self.proposal(vm=""), self.refs, "second")
        self.book.update(self.proposal(vm="NIKKI", status="resolved", outcome="NIKKI success verified"),
                         self.refs, "second")
        self.assertEqual(self.book.tasks[0]["status"], "open")
        self.assertEqual(self.book.tasks[1]["status"], "resolved")

    def test_question_normalization_preserves_meaningful_operators(self):
        self.book.update(self.proposal(question="Why is HTTP != 200?"), self.refs, "first")
        self.book.update(self.proposal(question="Why is HTTP = 200?"), self.refs, "first")
        self.assertEqual(len(self.book.tasks), 2)

    def test_explicit_task_id_cannot_be_repurposed(self):
        self.book.update(self.proposal(), self.refs, "first")
        original = copy.deepcopy(self.book.tasks)
        persisted = Path(self.book.path).read_text()
        for field, value in (("question", "Why did Grafana authentication fail?"),
                             ("vm", "NIKKI"), ("service", "grafana")):
            with self.subTest(field=field):
                with self.assertRaisesRegex(ValueError, "cannot change task"):
                    self.book.update(self.proposal(id=original[0]["id"], **{field: value}),
                                     self.refs, "second")
                self.assertEqual(self.book.tasks, original)
                self.assertEqual(Path(self.book.path).read_text(), persisted)

    def test_explicit_identity_accepts_cosmetic_changes_without_overwriting_identity(self):
        self.book.update(self.proposal(), self.refs, "first")
        task_id = self.book.tasks[0]["id"]
        self.book.update(self.proposal(id=task_id, question="Why did the scheduled digest fail.",
                                      vm="loki", service="logdigest"), self.refs, "second")
        self.assertEqual(self.book.tasks[0]["question"], self.proposal()["question"])
        self.assertEqual(self.book.tasks[0]["vm"], "LOKI")

    def test_repeated_blocker_does_not_reopen_or_refresh_report_membership(self):
        for status in ("needs_human", "resolved"):
            with self.subTest(status=status):
                self.book.update(self.proposal(status=status, outcome="Waiting for an operator"),
                                 self.refs, "first")
                original = copy.deepcopy(self.book.tasks)
                persisted = Path(self.book.path).read_text()
                result = self.book.update(self.proposal(), self.refs, "second")
                self.assertIn("unchanged", result)
                self.assertEqual(self.book.tasks, original)
                self.assertEqual(Path(self.book.path).read_text(), persisted)
                self.assertEqual(self.book.due(), [])

    def test_changed_blocker_can_record_new_evidence_without_reopening(self):
        self.book.update(self.proposal(status="needs_human", outcome="Access denied"), self.refs, "first")
        self.book.update(self.proposal(outcome="Access denied by a confirmed expired credential"),
                         self.refs, "second")
        self.assertEqual(self.book.tasks[0]["status"], "needs_human")
        self.assertEqual(self.book.tasks[0]["last_run"], "second")
        self.book.update(self.proposal(status="open", outcome="Access restored; checking recovery"),
                         self.refs, "third")
        self.assertEqual(len(self.book.due()), 1)

    def test_legacy_duplicate_resolution_suppresses_old_open_copy_without_deleting_history(self):
        self.book.update(self.proposal(), self.refs, "first")
        duplicate = copy.deepcopy(self.book.tasks[0])
        duplicate.update(id="task:legacy-alias", vm="", service="logdigest", status="resolved",
                         outcome="Scheduled run completed successfully", question="WHY did the scheduled digest fail.",
                         updated_at=agent.iso(NOW + timedelta(hours=1)))
        self.book.tasks.append(duplicate)
        self.book.save()
        loaded = agent.Followups(self.cfg, NOW + timedelta(hours=2))
        self.assertEqual(len(loaded.tasks), 2)
        self.assertEqual(loaded.due(), [])
        rendered = loaded.render()
        self.assertIn("task:legacy-alias", rendered)
        self.assertNotIn(self.book.tasks[0]["id"], rendered)
        self.assertIn("Scheduled run completed successfully", rendered)
        self.assertEqual(len(json.loads(Path(self.book.path).read_text())["tasks"]), 2)

    def test_render_is_bounded_prioritizes_due_work_and_omits_evidence_snapshots(self):
        self.cfg["followupsPerSession"] = 24
        for index in range(24):
            self.book.update(self.proposal(
                question=f"Question {index}: " + "q" * 270,
                next_check="n" * 500, hypothesis="h" * 500,
                priority="high" if index == 23 else "normal",
            ), self.refs, "first")
        rendered = self.book.render()
        self.assertLessEqual(len(rendered), self.book.PROMPT_MAX_CHARS)
        self.assertIn("Question 23:", rendered)
        self.assertLess(rendered.index("Question 23:"), rendered.index("Question 0:"))
        self.assertNotIn("query:current", rendered)
        self.assertNotIn("a measured current observation", rendered)
        self.assertIn("other tasks omitted", rendered)

    def test_render_contains_only_compact_recent_blocked_and_resolved_context(self):
        self.book.update(self.proposal(), self.refs, "first")
        for index in range(12):
            self.book.update(self.proposal(
                question=f"Previously checked issue {index}?",
                status="needs_human" if index % 2 else "resolved",
                outcome="o" * 500, next_check="UNNEEDED NEXT CHECK " * 20,
            ), self.refs, "first")
        rendered = self.book.render()
        self.assertIn(self.proposal()["question"], rendered)
        self.assertEqual(rendered.count("Previously checked issue"), 4)
        self.assertNotIn("UNNEEDED NEXT CHECK", rendered)
        self.assertNotIn("o" * 500, rendered)
        self.assertIn('"resolved": 6', rendered)
        self.assertIn('"needs_human": 6', rendered)


if __name__ == "__main__":
    unittest.main()
