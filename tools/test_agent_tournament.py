from __future__ import annotations

import copy
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
    def __init__(self, codes: dict[str, bytes], observation_block: int) -> None:
        self.codes = codes
        self.observation_block = observation_block

    def request(self, method: str, params: list[str]) -> str:
        if method != "eth_getCode" or params[1] != hex(self.observation_block):
            raise AssertionError((method, params))
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
        rpc = CodeRpc(value.pop("_codes"), value["observationBlock"])
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

    def test_committed_evidence_semantics_and_table_driven_mutations(self) -> None:
        baseline = json.loads(tournament.EVIDENCE_PATH.read_bytes())
        self.assertEqual(tournament.verify_evidence(), "0x" + hashlib.sha256(tournament.EVIDENCE_PATH.read_bytes()).hexdigest())
        self.assertEqual(
            (len(baseline["attemptLedger"]), len(baseline["anvilStateMutations"]), len(baseline["anvilControls"])),
            (66, 18, 78),
        )

        def delete(name: str):
            return lambda value: value.pop(name)

        def set_value(*path_and_value):
            *path, replacement = path_and_value

            def mutate(value):
                target = value
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = replacement

            return mutate

        def synthetic_payment_proofs(value):
            for proof in value["reconciliation"]["balanceProofs"].values():
                proof.update(
                    {
                        "beforeBlock": "0",
                        "afterBlock": "1",
                        "executorBefore": proof["amount"],
                        "executorAfter": "0",
                        "recipientBefore": "0",
                        "recipientAfter": proof["amount"],
                    }
                )

        def move_both_rejected_snapshots(value):
            for side in ("rejectedRecipientBefore", "rejectedRecipientAfter"):
                value["reconciliation"][side]["B-T2"]["balance"] = "1"

        def offset_all_bond_balances(value):
            bonds = value["reconciliation"]["bonds"]
            for side in ("actorBefore", "actorAfter"):
                for actor, amount in bonds[side].items():
                    bonds[side][actor] = str(int(amount) + 10)

        def forge_recorded_receipt_gas(value):
            attempt = value["attemptLedger"][0]
            attempt["gasUsed"] = "1"
            attempt["receipt"]["gasUsed"] = "1"
            attempt["gasCostWei"] = attempt["effectiveGasPriceWei"]

        def forge_timestamp_and_metric(value):
            attempt = next(item for item in value["attemptLedger"] if item["kind"] == "propose:A-T1")
            attempt["blockTimestamp"] = str(int(attempt["blockTimestamp"]) + 1)
            value["metrics"] = tournament._derived_metrics(
                value,
                {item["id"]: item for item in tournament._expected_documents(tournament._stack_from_evidence(value))[1]},
            )

        mutations = (
            ("empty ledger", lambda value: value["attemptLedger"].clear()),
            ("reversed FIFO", lambda value: value["evaluationFifo"].reverse()),
            ("impossible balance proof", set_value("reconciliation", "balanceProofs", "A-T1", "executorAfter", 1)),
            ("coordinated synthetic payment proofs", synthetic_payment_proofs),
            ("rejected movement", set_value("reconciliation", "rejectedRecipientAfter", "B-T2", "1")),
            ("coordinated rejected movement", move_both_rejected_snapshots),
            ("coordinated bond balance offset", offset_all_bond_balances),
            ("coordinated receipt gas forgery", forge_recorded_receipt_gas),
            ("coordinated timestamp and metric forgery", forge_timestamp_and_metric),
            ("malformed deployment data hash", set_value("attemptLedger", 4, "dataKeccak256", "not-a-hash")),
            ("removed metrics", delete("metrics")),
            (
                "forged repository commit and index",
                lambda value: value["repository"].update({"commit": "0" * 40, "sourceIndexSha256": "0x" + "00" * 32}),
            ),
            ("forged deterministic digest", set_value("deterministicTournamentSha256", "0x" + "00" * 32)),
            ("missing actors", delete("actors")),
            ("missing tasks", delete("tasks")),
            ("missing funding", delete("funding")),
            ("missing round robin", delete("roundRobinTicks")),
            ("grader flip", set_value("submissions", 0, "grader", "verdict", False)),
            ("removed challenge", set_value("submissions", 1, "challenge", None)),
            ("changed route", set_value("submissions", 0, "acceptanceRoute", "evaluated")),
            ("zero runtime hash", set_value("stack", "runtimeCodeKeccak256", "index", "0x" + "00" * 32)),
            ("duplicate gate", lambda value: value["gates"].append(copy.deepcopy(value["gates"][0]))),
            ("empty claims", set_value("claims", {})),
            ("forged count", set_value("counts", "payments", 5)),
            ("forged pin", set_value("pins", "sepoliaForkBlock", "11262000")),
            ("broken parent binding", set_value("submissions", 0, "taskDigest", "0x" + "00" * 32)),
        )
        with tempfile.TemporaryDirectory() as directory:
            for label, mutate in mutations:
                with self.subTest(label=label):
                    value = copy.deepcopy(baseline)
                    mutate(value)
                    if "recordedTranscriptSha256" in value:
                        value["recordedTranscriptSha256"] = tournament._recorded_transcript_sha256(value)
                    if label != "forged deterministic digest":
                        value["deterministicTournamentSha256"] = tournament._deterministic_tournament_sha256(value)
                    path = Path(directory) / (label.replace(" ", "-") + ".json")
                    runner.write_evidence(path, value)
                    with self.assertRaises(tournament.TournamentError):
                        tournament.verify_evidence(path)


if __name__ == "__main__":
    unittest.main()
