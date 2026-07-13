from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools import agent_documents as documents
from tools import agent_runner as runner
from tools import agent_tournament as tournament


def address(byte: str) -> str:
    return "0x" + byte * 40


class CodeRpc:
    def __init__(self, codes: dict[str, bytes]) -> None:
        self.codes = codes

    def request(self, method: str, params: list[str]) -> str:
        if method != "eth_getCode":
            raise AssertionError(method)
        return "0x" + self.codes[params[0]].hex()


def stack() -> dict:
    contracts = {
        "index": address("1"),
        "gateway": address("2"),
        "arbitration": address("3"),
        "vault": address("4"),
        "executor": address("5"),
    }
    codes = {name: (name + "-runtime").encode() for name in contracts}
    return {
        "chainId": 31337,
        "startBlock": 1,
        "forkBlock": 1,
        "forkBlockHash": "0x" + "aa" * 32,
        "observationBlock": 9,
        "asset": address("9"),
        **contracts,
        "runtimeCodeKeccak256": {name: documents.keccak256(codes[name]) for name in contracts},
        "_codes": {contracts[name]: codes[name] for name in contracts},
    }


class AgentTournamentTest(unittest.TestCase):
    def test_t1_grader_recomputes_all_eight_seed_vectors(self) -> None:
        blob = tournament.build_t1_artifact()
        self.assertTrue(tournament.grade_t1(blob))
        self.assertEqual(len(tournament.t1_inputs()), 8)
        self.assertFalse(tournament.grade_t1(blob + b" "))

    def test_t2_grader_reads_every_runtime_at_the_observation_block(self) -> None:
        value = stack()
        rpc = CodeRpc(value.pop("_codes"))
        blob = tournament.build_t2_artifact(value)
        self.assertTrue(tournament.grade_t2(blob, rpc, value))
        changed = bytearray(blob)
        changed[-2] ^= 1
        self.assertFalse(tournament.grade_t2(bytes(changed), rpc, value))

    def test_t3_grader_accepts_two_records_and_rejects_both_domain_mutants(self) -> None:
        value = stack()
        value.pop("_codes")
        blob = tournament.build_t3_artifact(value)
        self.assertTrue(tournament.grade_t3(blob, value))
        vectors = json.loads(blob)["vectors"]
        self.assertEqual([item["valid"] for item in vectors], [True, True, False, False])

    def test_exact_matrix_has_three_tasks_six_independent_bindings_and_one_copy(self) -> None:
        value = stack()
        value.pop("_codes")
        t1 = tournament.build_t1_artifact()
        blobs = {
            "t1": t1,
            "t2": tournament.build_t2_artifact(value),
            "t2-wrong": b'{"wrong":"t2"}',
            "t3": tournament.build_t3_artifact(value),
        }
        configs = tournament._submission_configs(value, blobs)
        self.assertEqual((len(configs), {item["taskId"] for item in configs}), (6, {"T1", "T2", "T3"}))
        self.assertEqual(len({item["proposalId"] for item in configs}), 6)
        self.assertEqual(configs[0]["artifactDigest"], configs[4]["artifactDigest"])
        self.assertEqual(sum(int(item["payment"]["amount"]) for item in configs if item["id"] in ("A-T1", "A-T2", "A-T3", "C-T3")), 12 * tournament.ONE_MILLIWETH)

    def test_p2a_evidence_bytes_and_sidecar_are_deterministic(self) -> None:
        evidence = {
            "kind": "fao.agentwork.p2a-evidence",
            "v": "1",
            "gates": [{"id": "deterministic", "status": "pass"}],
        }
        with tempfile.TemporaryDirectory() as directory:
            first = Path(directory) / "first.json"
            second = Path(directory) / "second.json"
            first_digest = runner.write_evidence(first, evidence)
            second_digest = runner.write_evidence(second, evidence)
            self.assertEqual(first.read_bytes(), second.read_bytes())
            self.assertEqual(first_digest, second_digest)
            self.assertEqual(first_digest, "0x" + hashlib.sha256(first.read_bytes()).hexdigest())


if __name__ == "__main__":
    unittest.main()
