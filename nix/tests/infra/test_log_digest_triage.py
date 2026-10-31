"""Event-time triage: prioritize new evidence without treating quiet hours as health."""
import unittest
from datetime import timedelta

import test_log_digest as fixtures

agent = fixtures.agent
NOW = fixtures.NOW


class TriageTests(unittest.TestCase):
    def signature(self, ref, vm="SOTO", service="jellyfin", hours=10, **extra):
        return dict(ref=ref, vm=vm, service=service, severity="error", today=8,
                    last_seen=agent.iso(NOW - timedelta(hours=hours)), **extra)

    def test_event_time_sample_includes_daytime_failure_instead_of_quiet_last_hour(self):
        pack = {"generated_at": agent.iso(NOW),
                "new_signatures": [self.signature("sig:daytime")]}
        lead, = agent.investigation_leads(pack)
        query = lead["sample_query"]
        end = NOW - timedelta(seconds=agent.duration_seconds(query["end_ago"]))
        event = NOW - timedelta(hours=10)
        self.assertLess(end - timedelta(hours=1), event)
        self.assertGreaterEqual(end, event)
        self.assertEqual(query["selector"], '{vm="SOTO",service="jellyfin"}')

    def test_sample_includes_earliest_event_in_the_collectors_hourly_interval(self):
        pack = {"generated_at": agent.iso(NOW),
                "new_signatures": [self.signature("sig:early")]}
        lead, = agent.investigation_leads(pack)
        query = lead["sample_query"]
        end = NOW - timedelta(seconds=agent.duration_seconds(query["end_ago"]))
        start = end - timedelta(seconds=agent.duration_seconds(query["window"]))
        captured = NOW - timedelta(hours=10)
        self.assertLessEqual(start, captured - timedelta(hours=1))
        self.assertGreaterEqual(end, captured)
        self.assertEqual(lead["last_captured_utc"], agent.iso(captured))

    def test_previously_covered_event_does_not_displace_an_unreviewed_service(self):
        pack = {"generated_at": agent.iso(NOW), "new_signatures": [
            self.signature("sig:old"), self.signature("sig:fresh", vm="UCHI", service="prowlarr")],
            "report_history": [{"last_reported": agent.iso(NOW - timedelta(hours=3)),
                                "anchors": ["sig:old"]}]}
        self.assertEqual([lead["ref"] for lead in agent.investigation_leads(pack)], ["sig:fresh"])
        pack["new_signatures"][0]["last_seen"] = agent.iso(NOW - timedelta(hours=1))
        self.assertEqual(len(agent.investigation_leads(pack)), 2)
        self.assertEqual(len(pack["new_signatures"]), 2)  # No evidence discarded.

    def test_one_service_cannot_take_every_shortlist_slot(self):
        pack = {"generated_at": agent.iso(NOW), "new_signatures": [
            self.signature("sig:one"), self.signature("sig:two"),
            self.signature("sig:three", vm="UCHI", service="prowlarr"),
            self.signature("sig:four", vm="NIKKI", service="grafana"),
            self.signature("sig:five", vm="DARE", service="unbound")]}
        leads = agent.investigation_leads(pack)
        self.assertEqual(len(leads), 3)
        self.assertEqual(len({(lead["vm"], lead["service"]) for lead in leads}), 3)

    def test_unknown_future_and_stale_times_do_not_produce_misleading_queries(self):
        rows = [self.signature("sig:future", hours=-1), self.signature("sig:stale", hours=25)]
        unknown = self.signature("sig:unknown")
        unknown["last_seen"] = None
        rows.append(unknown)
        pack = {"generated_at": agent.iso(NOW), "new_signatures": rows}
        self.assertEqual(agent.investigation_leads(pack), [])


if __name__ == "__main__":
    unittest.main()
