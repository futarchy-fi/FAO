import copy
import hashlib
import json
import socket
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import agent_documents as documents
from tools import rehearsal_r0_local as local


class RehearsalR0LocalTest(unittest.TestCase):
    def test_loopback_guard(self) -> None:
        self.assertEqual(local._loopback("http://127.0.0.1:19657"), "http://127.0.0.1:19657")
        with self.assertRaisesRegex(local.LocalRehearsalError, "loopback"):
            local._loopback("https://rpc.example")
        self.assertEqual(local._chain_id(31_337), 31_337)
        with self.assertRaisesRegex(local.LocalRehearsalError, "chain 31337"):
            local._chain_id(1)

    def test_prebound_port_is_rejected(self) -> None:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            listener.listen()
            with self.assertRaisesRegex(local.LocalRehearsalError, "already in use"):
                local._require_unused_port(listener.getsockname()[1])

    def test_clock_is_absolute_and_monotonic(self) -> None:
        clock = local._clock(1_800_000_000)
        self.assertEqual(list(clock.values()), sorted(clock.values()))
        self.assertEqual(clock["saleSeal"], clock["saleClosedProbe"] + 1)

    def test_hostile_fixture_and_payload_are_exact(self) -> None:
        fixture = local._fixture_evidence()
        self.assertEqual(fixture["bytes"], 10_240)
        self.assertEqual(fixture["keccak256"], local.FIXTURE_KECCAK)
        self.assertEqual(
            documents.keccak256(bytes.fromhex(local.SITE_PAYLOAD[2:])),
            local.SITE_ARB_HASH,
        )
        self.assertEqual(len(bytes.fromhex(local.SITE_PAYLOAD[2:])), 256)

    def test_dual_run_rejects_an_economic_mutation(self) -> None:
        runs = [({"amount": "1"}, {}), ({"amount": "2"}, {})]
        with mock.patch.object(local, "_run_once", side_effect=runs):
            with self.assertRaisesRegex(local.LocalRehearsalError, "projections diverged"):
                local.run(19_657)

    def test_committed_evidence_and_sidecar_are_sealed(self) -> None:
        evidence_path = local.ROOT / "metadata/rehearsal-r0-s2-evidence.json"
        raw = evidence_path.read_bytes()
        evidence = json.loads(raw)
        local._validate_evidence(evidence)
        self.assertEqual(
            evidence["comparison"]["excludedFieldsNotSerialized"], local.EXCLUDED_FIELDS
        )
        tap_failure = evidence["economicProjection"]["treasury"]["failures"][
            "s3:tap-budget"
        ]["returnValue"]
        self.assertEqual(tap_failure[:10], "0xbf50ae46")
        tap_words = local._words("0x" + tap_failure[10:], 3)
        self.assertEqual(local._uint_word(tap_words[1]), 6 * local.WAD // 100)
        self.assertEqual(local._uint_word(tap_words[2]), 5 * local.WAD // 100)
        self.assertEqual(
            (evidence_path.with_suffix(evidence_path.suffix + ".sha256")).read_text().strip(),
            "0x" + hashlib.sha256(raw).hexdigest(),
        )

        mutations = (
            lambda value: value.__setitem__("publicBroadcasts", 1),
            lambda value: value["economicProjection"]["siteRelease"]["final"]["votes"][
                "votePower"
            ].__setitem__("for", 1),
            lambda value: value["economicProjection"]["fixtureArtifact"].__setitem__(
                "keccak256", "0x" + "00" * 32
            ),
            lambda value: value["economicProjection"]["treasury"]["queues"]["s3"].__setitem__(
                "expired", False
            ),
            lambda value: value["economicProjection"]["clock"].__setitem__("chainId", 1),
            lambda value: value["comparison"].__setitem__("excludedFieldsNotSerialized", []),
            lambda value: value["economicProjection"]["treasury"]["failures"][
                "s3:tap-budget"
            ].__setitem__("returnValue", "0xbf50ae46"),
        )
        for mutate in mutations:
            candidate = copy.deepcopy(evidence)
            mutate(candidate)
            with self.assertRaises(local.LocalRehearsalError):
                local._validate_evidence(candidate)

    def test_check_mode_rejects_stale_output(self) -> None:
        evidence = json.loads(
            (local.ROOT / "metadata/rehearsal-r0-s2-evidence.json").read_bytes()
        )
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "evidence.json"
            output.write_bytes(local._canonical(evidence))
            with mock.patch.object(local, "run", return_value=evidence):
                self.assertEqual(local.main(("--check", "--output", str(output))), 0)
                output.write_text("{}\n")
                with self.assertRaisesRegex(local.LocalRehearsalError, "missing or stale"):
                    local.main(("--check", "--output", str(output)))

    def test_s1_seal_is_untouched(self) -> None:
        expected = {
            "script/RehearsalR0.s.sol": "0bf4bfb04ec6faf5c5670296847a434fd61d569a454adb9fa1177ba075716436",
            "tools/rehearsal_r0.py": "ac3b0911e9e98df7049169c854550cadba8e53c24d495a0bcc6f8620135d9e34",
            "metadata/rehearsal-r0-s1-evidence.json": "8a25b4bc38b6abf9b094392260c8f75fd8aef23bb70350ae8b3ab629ef4aaf12",
            "metadata/rehearsal-r0-s1-evidence.json.sha256": "1b606467cce4b2b1fadbfef11fd68ae078208059ff915fef97bb01b4b850b6fe",
        }
        for relative, digest in expected.items():
            with self.subTest(path=relative):
                self.assertEqual(
                    hashlib.sha256((local.ROOT / relative).read_bytes()).hexdigest(), digest
                )


if __name__ == "__main__":
    unittest.main()
