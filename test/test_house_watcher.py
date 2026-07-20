import json
import subprocess
import sys
import tempfile
import unittest
from copy import deepcopy
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))

from scripts.house_watcher import build_snapshot, evaluate_health, load_json, load_jsonl


FIXTURES = ROOT / "test" / "fixtures" / "house-watcher"


class HouseWatcherAcceptanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.config = load_json(FIXTURES / "config.json")
        cls.events = load_jsonl(FIXTURES / "events-v1.jsonl")
        cls.snapshot = build_snapshot(cls.config, cls.events)
        cls.proposals = {row["arbitration_id"]: row for row in cls.snapshot["proposals"]}

    def test_oyw6_ttfc_provenance_and_censoring(self):
        a = self.proposals["A"]
        self.assertEqual(a["ttfc_created_s"], {"house": 40, "external": None, "any": 40})
        self.assertEqual(a["ttfc_eligible_s"], {"house": 30, "external": None, "any": 30})
        self.assertEqual(a["first_any_source"], "house")

        b = self.proposals["B"]
        self.assertEqual(b["ttfc_created_s"], {"house": 30, "external": 25, "any": 25})
        self.assertEqual(b["ttfc_eligible_s"], {"house": 20, "external": 15, "any": 15})
        self.assertEqual(b["first_any_source"], "external")

        c = self.proposals["C"]
        self.assertTrue(c["censored"])
        self.assertEqual(c["censor_status"], "timeout")
        self.assertEqual(c["eligible_exposure_s"], 600)
        self.assertEqual(self.snapshot["ttfc"]["created_s"]["any"]["count"], 2)
        self.assertEqual(self.snapshot["ttfc"]["synthetic_external_adoption"], 0)

    def test_replay_reorg_and_idempotency(self):
        source = self.snapshot["source"]
        self.assertEqual(source["duplicate_events_ignored"], 1)
        self.assertEqual(source["reorg_replacements"], 1)
        self.assertEqual(self.proposals["B"]["t_first_external_no"], 2025)
        self.assertEqual(self.proposals["B"]["t_first_house_no"], 2030)
        self.assertEqual(len(self.proposals["B"]["event_ids"]), len(set(self.proposals["B"]["event_ids"])))

        canonical = {}
        for event in self.events:
            canonical[event["event_id"]] = event
        clean = build_snapshot(self.config, list(canonical.values()))
        for field in ("health", "ttfc", "economics", "poker", "alerts", "proposals"):
            self.assertEqual(clean[field], self.snapshot[field])

    def test_economics_classifier_and_synthetic_isolation(self):
        economics = self.snapshot["economics"]
        self.assertEqual(economics["cost_all_raw"]["count"], 2)
        self.assertEqual(economics["cost_organic_raw"]["count"], 1)
        self.assertEqual(economics["incomplete_cost_count"], 1)
        self.assertEqual(economics["beta_bad"]["rate_bps"], 10_000)
        self.assertEqual(economics["beta_bad"]["sample_status"], "sufficient")
        self.assertEqual(
            economics["classifier_q"]["confusion"],
            {"true_bad": 1, "false_bad": 0, "true_good": 0, "false_good": 1},
        )
        self.assertEqual(economics["bad_timeout_slips"], ["C"])
        self.assertEqual(economics["reward_competition_s"]["rate_bps"], 10_000)

    def test_failure_is_visible_without_blind_retry(self):
        self.assertEqual([alert["kind"] for alert in self.snapshot["alerts"]], ["challenge_failure"])
        self.assertEqual(self.proposals["D"]["challenge_failures"][0]["error_class"], "fixture_state_changed")
        self.assertFalse(self.proposals["D"]["challenge_failures"][0]["retry_allowed"])
        self.assertIn("challenge_failure_or_retry", self.snapshot["health"]["reasons"])

    def test_poker_knee_and_missing_funding_block(self):
        knees = {row["regime"]: row["knee_a_recommendation"] for row in self.snapshot["poker"]["rows"]}
        self.assertEqual(knees, {"cheap": "0", "default": "0", "pricey": "50", "prohibitive": "100", "unknown": "UNKNOWN"})
        self.assertFalse(self.snapshot["poker"]["ready"])
        self.assertFalse(self.snapshot["health"]["ready"])
        self.assertFalse(self.snapshot["health"]["signing_enabled"])
        self.assertIn("fixture_only", self.snapshot["health"]["reasons"])
        self.assertIn("no_authorized_testnet_e2e", self.snapshot["health"]["reasons"])
        self.assertIn("missing_poker_regime_or_funding", self.snapshot["health"]["reasons"])
        self.assertEqual(self.snapshot["health"]["telemetry"]["run_id"], "fixture-run-1")
        self.assertEqual(self.snapshot["health"]["telemetry"]["deploy_parity"], "PASS")
        self.assertEqual(self.snapshot["ttfc"]["by_origin"]["synthetic"]["proposal_count"], 1)
        self.assertEqual(self.snapshot["ttfc"]["by_origin"]["organic"]["proposal_count"], 3)

    def test_health_mismatches_fail_closed(self):
        heartbeat = next(event for event in self.events if event["kind"] == "heartbeat")
        broken = deepcopy(heartbeat)
        broken["data"].update(
            {
                "observed_chain_id": 1,
                "arbitration_address": "0xwrong",
                "runtime_codehash": "0xwrong",
                "config_digest": "wrong",
                "deploy_parity": "FAIL",
                "heartbeat_age_s": 61,
                "finalized_lag_blocks": 6,
                "signer_balance_raw": "99",
                "signer_allowance_raw": "99",
            }
        )
        reasons = evaluate_health(self.config, broken, {"x": {"content_digest_status": "unknown"}})
        for reason in (
            "chain_id_mismatch",
            "arbitration_address_mismatch",
            "runtime_codehash_mismatch",
            "config_digest_mismatch",
            "deploy_parity_not_pass",
            "stale_heartbeat",
            "excessive_finalized_lag",
            "insufficient_signer_balance",
            "insufficient_signer_allowance",
            "missing_content_digest",
        ):
            self.assertIn(reason, reasons)

    def test_cli_matches_reducer_and_rejects_non_fixture_mode(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "snapshot.json"
            subprocess.run(
                [
                    sys.executable,
                    str(ROOT / "scripts" / "house_watcher.py"),
                    "--events",
                    str(FIXTURES / "events-v1.jsonl"),
                    "--config",
                    str(FIXTURES / "config.json"),
                    "--output",
                    str(output),
                ],
                check=True,
            )
            self.assertEqual(json.loads(output.read_text()), self.snapshot)

        live_config = deepcopy(self.config)
        live_config["mode"] = "live"
        with self.assertRaisesRegex(ValueError, "fixture-only"):
            build_snapshot(live_config, self.events)

    def test_committed_dashboard_snapshots_match_fixture(self):
        for path in (
            ROOT / "audit" / "dashboard" / "telemetry" / "house-watcher-v1.json",
            ROOT / "site-ops" / "fao" / "telemetry" / "house-watcher-v1.json",
        ):
            self.assertEqual(json.loads(path.read_text()), self.snapshot)


if __name__ == "__main__":
    unittest.main()
