#!/usr/bin/env python3
"""Focused unit guards for the fork-only Rehearsal R0 S1 driver."""

from __future__ import annotations

import unittest
from unittest import mock

from tools import rehearsal_r0 as rehearsal


class RehearsalR0Test(unittest.TestCase):
    def test_provider_loopback_and_pin_guards(self) -> None:
        self.assertEqual(
            rehearsal._provider("https://sepolia.drpc.org/"),
            "https://sepolia.drpc.org/",
        )
        for url in (
            "http://sepolia.drpc.org",
            "https://user@sepolia.drpc.org",
            "https://sepolia.drpc.org/secret",
            "https://sepolia.drpc.org/?key=secret",
        ):
            with self.subTest(url=url), self.assertRaises(rehearsal.RehearsalError):
                rehearsal._provider(url)
        self.assertEqual(
            rehearsal._loopback("http://127.0.0.1:19655"),
            "http://127.0.0.1:19655",
        )
        with self.assertRaises(rehearsal.RehearsalError):
            rehearsal._loopback("http://localhost:19655")
        self.assertEqual(
            rehearsal._pin_for_head(rehearsal.FORK_SELECTED_FROM_HEAD),
            rehearsal.FORK_BLOCK,
        )
        with self.assertRaises(rehearsal.RehearsalError):
            rehearsal._pin_for_head(1_063)

    def test_fifty_tick_limit_tracks_economic_orientation(self) -> None:
        rpc = object()
        pool = "0x" + "11" * 20
        company = "0x" + "22" * 20
        with (
            mock.patch.object(rehearsal, "_slot0", return_value={"tick": 100}),
            mock.patch.object(rehearsal, "_address", return_value=company),
        ):
            self.assertEqual(
                rehearsal._price_limit(rpc, pool, company, 50),
                rehearsal._sqrt_at_tick(150),
            )
            self.assertEqual(
                rehearsal._price_limit(rpc, pool, company, -50),
                rehearsal._sqrt_at_tick(50),
            )
        with (
            mock.patch.object(rehearsal, "_slot0", return_value={"tick": 100}),
            mock.patch.object(rehearsal, "_address", return_value="0x" + "33" * 20),
        ):
            self.assertEqual(
                rehearsal._price_limit(rpc, pool, company, 50),
                rehearsal._sqrt_at_tick(50),
            )

    def test_failed_trace_is_bound_to_exact_unstable_payload(self) -> None:
        pool = "0x" + "44" * 20
        words = (
            bytes(12)
            + bytes.fromhex(pool[2:])
            + (-51 % (1 << 256)).to_bytes(32, "big")
            + (-103 % (1 << 256)).to_bytes(32, "big")
        )
        payload = rehearsal.UNSTABLE_POOL + words.hex()

        class Rpc:
            def request(self, method: str, params: list[object]) -> object:
                self.seen = (method, params)
                return {"failed": True, "returnValue": payload[2:]}

        rpc = Rpc()
        trace = rehearsal._failed_transaction_trace(rpc, "0x" + "55" * 32)
        self.assertEqual(trace, {"failed": True, "returnValue": payload})
        self.assertEqual(rpc.seen[0], "debug_traceTransaction")
        self.assertEqual(
            rehearsal._decode_unstable(trace["returnValue"]),
            {
                "currentTick": -51,
                "meanTick": -103,
                "pool": pool,
                "selector": rehearsal.UNSTABLE_POOL,
            },
        )
        with self.assertRaises(rehearsal.RehearsalError):
            rehearsal._decode_unstable("0xdeadbeef" + words.hex())

    def test_asset_use_bound_accepts_exact_fifty_bps_only(self) -> None:
        evidence = rehearsal._usage_evidence("edge", 995, 5)
        self.assertEqual(evidence["usedBpsFloor"], 9_950)
        with self.assertRaises(rehearsal.RehearsalError):
            rehearsal._usage_evidence("over", 994, 6)
        with self.assertRaises(rehearsal.RehearsalError):
            rehearsal._usage_evidence("empty", 0, 0)

    def test_dual_run_rejects_an_economic_mutation(self) -> None:
        runs = [({"amount": "1"}, {}), ({"amount": "2"}, {})]
        with (
            mock.patch.object(rehearsal, "_preflight"),
            mock.patch.object(rehearsal.windtunnel, "_artifact_evidence", return_value={}),
            mock.patch.object(rehearsal, "_run_once", side_effect=runs),
        ):
            with self.assertRaisesRegex(rehearsal.RehearsalError, "economic projections diverged"):
                rehearsal.run(19_655, "https://sepolia.drpc.org")


if __name__ == "__main__":
    unittest.main()
