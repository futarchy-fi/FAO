from __future__ import annotations

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from tools import agent_documents as documents
from tools import agent_runner as runner


def address(byte: str) -> str:
    return "0x" + byte * 40


def digest(number: int) -> str:
    return "0x" + number.to_bytes(32, "big").hex()


INDEX = address("1")
GATEWAY = address("2")
ARBITRATION = address("3")
VAULT = address("4")
EXECUTOR = address("5")
BOND = address("6")
WORKER = address("7")
RECIPIENT = address("8")
ASSET = address("9")
AUTOMATION = "0x693e3fb46bb36ee43c702fe94f9463df0691b43d"


def config() -> dict:
    task = {
        "v": "1",
        "kind": "fao.task",
        "chainId": "31337",
        "vault": VAULT,
        "title": "Deterministic task",
        "spec": "Return the exact artifact digest.",
        "salt": digest(101),
    }
    task_digest = documents.document_digest(documents.build_task(task))
    receipt = {
        "v": "1",
        "kind": "fao.receipt",
        "chainId": "31337",
        "vault": VAULT,
        "task": task_digest,
        "worker": WORKER,
        "artifacts": [{"digest": digest(102), "uri": "https://example.test/artifact"}],
        "summary": "Exact result",
        "salt": digest(103),
    }
    receipt_digest = documents.document_digest(documents.build_receipt(receipt))
    payment = {
        "v": "1",
        "kind": "fao.payment",
        "chainId": "31337",
        "vault": VAULT,
        "asset": ASSET,
        "recipient": RECIPIENT,
        "amount": "10",
        "task": task_digest,
        "receipt": receipt_digest,
        "salt": digest(104),
    }
    return {
        "chainId": 31337,
        "fromBlock": 1,
        "index": INDEX,
        "gateway": GATEWAY,
        "arbitration": ARBITRATION,
        "vault": VAULT,
        "executor": EXECUTOR,
        "automation": AUTOMATION,
        "documents": {"task": task, "receipt": receipt, "payment": payment},
        "caps": {"paymentAmount": "10", "bondAmount": "2", "transactionValue": "0"},
    }


def event_data(*values: object) -> str:
    words = []
    for value in values:
        if isinstance(value, bool):
            words.append(int(value).to_bytes(32, "big"))
        elif isinstance(value, int):
            words.append(value.to_bytes(32, "big"))
        elif isinstance(value, str) and len(value) == 42:
            words.append(bytes(12) + bytes.fromhex(value[2:]))
        elif isinstance(value, str) and len(value) == 66:
            words.append(bytes.fromhex(value[2:]))
        else:
            raise AssertionError(value)
    return "0x" + b"".join(words).hex()


def log(address_: str, topic0: str, topics: list[str], data: str, ordinal: int) -> dict:
    return {
        "address": address_,
        "blockHash": digest(1000 + ordinal),
        "blockNumber": ordinal,
        "transactionHash": digest(2000 + ordinal),
        "logIndex": 0,
        "topics": [topic0, *topics],
        "data": data,
        "removed": False,
    }


def published(name: str, cfg: dict, ordinal: int, document: bytes | None = None) -> dict:
    item = documents.prepare_publication(name, cfg["documents"][name])
    raw = item["document"] if document is None else document
    size = len(raw)
    data = (
        bytes(12)
        + bytes.fromhex(AUTOMATION[2:])
        + (64).to_bytes(32, "big")
        + size.to_bytes(32, "big")
        + raw
        + bytes((-size) % 32)
    )
    return log(
        INDEX,
        documents.PUBLISHED_TOPIC,
        [item["kind"], item["parentDigest"], documents.document_digest(raw)],
        "0x" + data.hex(),
        ordinal,
    )


def action_facts(cfg: dict) -> tuple[dict[str, str], str, str]:
    raw = documents.build_payment(cfg["documents"]["payment"])
    action = documents.payment_transfer_action(raw)
    action_hash = documents.validate_payment_binding(raw, cfg["chainId"], cfg["vault"], action)
    return action, action_hash, action_hash


def proposal_logs(cfg: dict, start: int = 4) -> list[dict]:
    action, action_hash, topic = action_facts(cfg)
    return [
        log(
            ARBITRATION,
            runner.TOPICS["proposalCreated"],
            [topic, "0x" + bytes(12).hex() + GATEWAY[2:]],
            event_data(2),
            start,
        ),
        log(
            GATEWAY,
            runner.TOPICS["transferProposed"],
            [topic, "0x" + bytes(12).hex() + AUTOMATION[2:], "0x" + bytes(12).hex() + action["asset"][2:]],
            event_data(action["recipient"], int(action["amount"]), action["salt"]),
            start + 1,
        ),
    ]


def proposal(state: str = "INACTIVE", **changes: object) -> dict:
    value = {
        "minActivationBond": 2,
        "yesBidder": address("0"),
        "yesBondAmount": 0,
        "noBidder": address("0"),
        "noBondAmount": 0,
        "state": state,
        "lastStateChangeAt": 90,
        "settled": False,
        "accepted": False,
        "queuePosition": 0,
        "exists": True,
    }
    value.update(changes)
    return value


def snapshot(cfg: dict, logs: list[dict] | None = None, proposal_: dict | None = None, now: int = 100) -> dict:
    prepared = {
        name: documents.prepare_publication(name, cfg["documents"][name])["documentDigest"]
        for name in ("task", "receipt", "payment")
    }
    return {
        "finalized": {"number": 100, "hash": digest(100), "timestamp": now},
        "logs": [] if logs is None else logs,
        "views": {
            "proposal": proposal_,
            "queued": {"executeAfter": 0, "expiresAt": 0, "executed": False, "expired": False},
            "minimumBond": 2,
            "timeout": 10,
            "bondToken": BOND,
            "allowance": 0,
            "executionSimulationOk": False,
            "balanceProof": None,
        },
        "prepared": prepared,
    }


class AgentRunnerUnitTest(unittest.TestCase):
    def test_one_action_sequence_keeps_accepted_executable_and_paid_distinct(self) -> None:
        cfg = config()
        logs: list[dict] = []
        state = runner.derive_state(cfg, snapshot(cfg, logs))
        self.assertEqual((state["lifecycle"], runner.next_action(cfg, state).kind), ("IDLE", "publish-task"))
        for index, name in enumerate(("task", "receipt", "payment"), 1):
            logs.append(published(name, cfg, index))
            state = runner.derive_state(cfg, snapshot(cfg, logs))
            expected = {"task": "publish-receipt", "receipt": "publish-payment", "payment": "propose"}[name]
            self.assertEqual(runner.next_action(cfg, state).kind, expected)

        logs += proposal_logs(cfg)
        state = runner.derive_state(cfg, snapshot(cfg, logs, proposal()))
        self.assertEqual((state["lifecycle"], runner.next_action(cfg, state).kind), ("PROPOSED", "approve-bond"))
        ready = snapshot(cfg, logs, proposal())
        ready["views"]["allowance"] = 2
        state = runner.derive_state(cfg, ready)
        self.assertEqual(runner.next_action(cfg, state).kind, "place-yes-bond")

        bonded = proposal("YES", yesBidder=AUTOMATION, yesBondAmount=2)
        state = runner.derive_state(cfg, snapshot(cfg, logs, bonded, 99))
        self.assertEqual((state["lifecycle"], runner.next_action(cfg, state)), ("BONDED", None))
        state = runner.derive_state(cfg, snapshot(cfg, logs, bonded, 100))
        self.assertEqual(runner.next_action(cfg, state).kind, "finalize-timeout")

        _, action_hash, topic = action_facts(cfg)
        logs.append(log(ARBITRATION, runner.TOPICS["finalized"], [topic, "0x" + bytes(12).hex() + AUTOMATION[2:]], event_data(True, 2), 10))
        accepted = proposal("SETTLED", yesBidder=AUTOMATION, yesBondAmount=2, settled=True, accepted=True)
        accepted_state = runner.derive_state(cfg, snapshot(cfg, logs, accepted, 110))
        self.assertEqual((accepted_state["lifecycle"], accepted_state["accepted"], accepted_state["paid"]), ("ACCEPTED", True, False))
        self.assertEqual(runner.next_action(cfg, accepted_state).kind, "queue")

        logs.append(log(VAULT, runner.TOPICS["queued"], [topic, topic], event_data(120, 200), 11))
        queued = snapshot(cfg, logs, accepted, 119)
        queued["views"]["queued"].update(executeAfter=120, expiresAt=200)
        state = runner.derive_state(cfg, queued)
        self.assertEqual((state["lifecycle"], state["executable"]), ("QUEUED", False))
        queued["finalized"]["timestamp"] = 120
        state = runner.derive_state(cfg, queued)
        self.assertEqual((state["lifecycle"], state["shortfall"], runner.next_action(cfg, state)), ("SHORTFALL", True, None))
        queued["views"]["executionSimulationOk"] = True
        state = runner.derive_state(cfg, queued)
        self.assertEqual((state["lifecycle"], runner.next_action(cfg, state).kind), ("EXECUTABLE", "execute"))

        action = state["action"]
        logs.append(log(VAULT, runner.TOPICS["executed"], [topic, "0x" + bytes(12).hex() + action["asset"][2:], "0x" + bytes(12).hex() + action["recipient"][2:]], event_data(10), 12))
        queued["logs"] = logs
        queued["views"]["queued"]["executed"] = True
        queued["views"]["balanceProof"] = {
            "beforeBlock": 11, "afterBlock": 12,
            "executorBefore": 100, "executorAfter": 90,
            "recipientBefore": 5, "recipientAfter": 15,
        }
        state = runner.derive_state(cfg, queued)
        self.assertEqual((state["lifecycle"], state["paid"], runner.next_action(cfg, state)), ("PAID", True, None))

    def test_duplicate_receipt_is_append_only_but_deduplicated_only_in_view(self) -> None:
        cfg = config()
        logs = [published("task", cfg, 1), published("receipt", cfg, 2), published("receipt", cfg, 3)]
        state = runner.derive_state(cfg, snapshot(cfg, logs))
        self.assertEqual(state["publications"]["receipt"]["occurrences"], 2)
        self.assertTrue(state["publications"]["receipt"]["published"])
        self.assertEqual(len(logs), 3)

    def test_copied_work_and_every_binding_substitution_are_independent(self) -> None:
        original = config()
        copied = copy.deepcopy(original)
        copied["documents"]["payment"]["recipient"] = WORKER
        copied["documents"]["payment"]["salt"] = digest(999)
        original_action, original_hash, _ = action_facts(original)
        copied_action, copied_hash, _ = action_facts(copied)
        self.assertNotEqual((original_action["salt"], original_hash), (copied_action["salt"], copied_hash))
        self.assertEqual(action_facts(original)[1], original_hash)

        raw = documents.build_payment(original["documents"]["payment"])
        for field, replacement in (
            ("asset", address("a")), ("recipient", address("b")), ("amount", "11"), ("salt", digest(12))
        ):
            changed = dict(original_action)
            changed[field] = replacement
            with self.assertRaises(documents.DocumentError):
                documents.validate_payment_binding(raw, 31337, VAULT, changed)
        for chain, vault in ((1, VAULT), (31337, address("c"))):
            with self.assertRaises(documents.DocumentError):
                documents.validate_payment_binding(raw, chain, vault, original_action)

    def test_view_log_disagreement_and_nonconserving_payment_fail_closed(self) -> None:
        cfg = config()
        logs = [published(name, cfg, i) for i, name in enumerate(("task", "receipt", "payment"), 1)] + proposal_logs(cfg)
        _, _, topic = action_facts(cfg)
        logs.append(log(ARBITRATION, runner.TOPICS["finalized"], [topic, "0x" + bytes(12).hex() + AUTOMATION[2:]], event_data(False, 2), 10))
        with self.assertRaisesRegex(runner.RunnerError, "disagree"):
            runner.derive_state(cfg, snapshot(cfg, logs, proposal("SETTLED", settled=True, accepted=True)))

    def test_malformed_hostile_index_document_is_inert(self) -> None:
        cfg = config()
        hostile = published("task", cfg, 1, b'{"not":"canonical", "v":"1"}')
        state = runner.derive_state(cfg, snapshot(cfg, [hostile]))
        self.assertEqual(state["lifecycle"], "IDLE")
        self.assertEqual(len(state["hostileDocuments"]), 1)
        self.assertEqual(runner.next_action(cfg, state).kind, "publish-task")

    def test_evidence_is_compact_sorted_and_bound_by_sha256(self) -> None:
        evidence = {"v": "1", "kind": "fao.agentwork.p1-evidence", "drills": [{"id": 1, "status": "pass"}]}
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "evidence.json"
            digest_ = runner.write_evidence(path, evidence)
            raw = path.read_bytes()
            self.assertEqual(raw, runner.canonical_json(evidence) + b"\n")
            self.assertEqual(digest_, "0x" + hashlib.sha256(raw).hexdigest())
            self.assertEqual(path.with_suffix(".json.sha256").read_text().strip(), digest_)


class FakeRpc:
    def __init__(self, *, broken_lineage: bool = False, fail_call: int | None = None) -> None:
        self.broken_lineage = broken_lineage
        self.fail_call = fail_call
        self.calls = 0

    def chain_id(self) -> int:
        return 31337

    def finalized_block(self) -> dict:
        return self.block(3)

    def block(self, number: int | str) -> dict:
        number = int(number)
        parent = digest(700 + number - 1)
        if self.broken_lineage and number == 3:
            parent = digest(999)
        return {"number": hex(number), "hash": digest(700 + number), "parentHash": parent, "timestamp": hex(100 + number)}

    def logs(self, start: int, end: int, addresses: list[str]) -> list[dict]:
        return []

    def call(self, transaction: dict, block: str) -> str:
        self.calls += 1
        if self.fail_call == self.calls:
            raise runner.RunnerError("partial RPC failure")
        selector = transaction["data"][2:10]
        if selector == runner.SELECTORS["getProposal"]:
            raise runner.RpcCallError("expected revert", runner.PROPOSAL_NOT_FOUND)
        if selector == runner.SELECTORS["execute"]:
            raise runner.RpcCallError("expected revert")
        if selector == runner.SELECTORS["queuedActions"]:
            return "0x" + bytes(128).hex()
        if selector in (runner.SELECTORS["minBond"], runner.SELECTORS["timeout"]):
            return "0x" + (2 if selector == runner.SELECTORS["minBond"] else 10).to_bytes(32, "big").hex()
        if selector == runner.SELECTORS["bondToken"]:
            return "0x" + (bytes(12) + bytes.fromhex(BOND[2:])).hex()
        if selector == runner.SELECTORS["allowance"]:
            return "0x" + bytes(32).hex()
        return "0x"

    def balance(self, address_: str, block: int) -> int:
        return 0


class Caller:
    def call(self, transaction: dict, block: str) -> str:
        return "0x"


class Sender:
    def __init__(self, fail: bool = False) -> None:
        self.fail = fail
        self.sent: list[dict] = []

    def send(self, transaction: dict) -> str:
        self.sent.append(transaction)
        if self.fail:
            raise RuntimeError("signer unavailable")
        return digest(len(self.sent))


class AgentRunnerFakeRpcTest(unittest.TestCase):
    def test_finalized_lineage_replay_is_identical_and_bad_lineage_fails_closed(self) -> None:
        cfg = config()
        first = runner.collect_snapshot(FakeRpc(), cfg)
        second = runner.collect_snapshot(FakeRpc(), cfg)
        self.assertEqual(runner.canonical_json(first), runner.canonical_json(second))
        with self.assertRaisesRegex(runner.RunnerError, "lineage"):
            runner.collect_snapshot(FakeRpc(broken_lineage=True), cfg)

    def test_partial_rpc_failure_aborts_before_send_then_resumes(self) -> None:
        cfg = config()
        sender = Sender()
        with self.assertRaisesRegex(runner.RunnerError, "partial RPC"):
            runner.tick(cfg, FakeRpc(fail_call=3), Caller(), sender)
        self.assertEqual(sender.sent, [])
        result = runner.tick(cfg, FakeRpc(), Caller(), sender)
        self.assertEqual((result["action"], len(sender.sent)), ("publish-task", 1))

    def test_signer_failure_records_attempt_and_stateless_retry_is_exact(self) -> None:
        cfg = config()
        failed = runner.tick(cfg, FakeRpc(), Caller(), Sender(fail=True))
        self.assertEqual(failed["attempts"][0]["outcome"], "signer-failed")
        sender = Sender()
        retried = runner.tick(cfg, FakeRpc(), Caller(), sender)
        self.assertEqual(retried["attempts"][0]["outcome"], "submitted")
        self.assertEqual(failed["attempts"][0]["transaction"], retried["attempts"][0]["transaction"])


if __name__ == "__main__":
    unittest.main()
