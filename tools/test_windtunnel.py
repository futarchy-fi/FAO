from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from tools.windtunnel import funding, keeper, schema
from tools.windtunnel.indexer import Indexer, IndexerError


def addr(byte: str) -> str:
    return "0x" + byte * 40


def digest(number: int) -> str:
    return "0x" + ("%064x" % number)


def word(type_: str, value):
    if type_ == "address":
        return bytes(12) + bytes.fromhex(value[2:])
    if type_ == "bytes32":
        return bytes.fromhex(value[2:])
    if type_ == "bool":
        return int(value).to_bytes(32, "big")
    return int(value).to_bytes(32, "big")


EVENTS_BY_ID = {item["id"]: item for item in schema.EVENT_SCHEMA["events"]}


def event_log(block, index, emitter, event_id, values, removed=False):
    spec = EVENTS_BY_ID[event_id]
    topics = [spec["topic0"]]
    data = b""
    for item in spec["inputs"]:
        encoded = word(item["type"], values[item["name"]])
        if item["indexed"]:
            topics.append("0x" + encoded.hex())
        else:
            data += encoded
    return {
        "address": emitter,
        "blockHash": block["hash"],
        "blockNumber": block["number"],
        "transactionHash": digest(int(block["number"], 16) * 100 + index),
        "logIndex": hex(index),
        "topics": topics,
        "data": "0x" + data.hex(),
        "removed": removed,
    }


class FakeRpc:
    def __init__(self, blocks, logs, duplicate=False):
        self.blocks = {int(block["number"], 16): block for block in blocks}
        self.event_logs = logs
        self.duplicate = duplicate

    def chain_id(self):
        return 11155111

    def finalized_block(self):
        return self.blocks[max(self.blocks)]

    def block(self, number):
        return self.blocks[number]

    def logs(self, from_block, to_block, addresses):
        selected = [
            value
            for value in self.event_logs
            if from_block <= int(value["blockNumber"], 16) <= to_block
            and value["address"] in addresses
        ]
        return selected + selected if self.duplicate else selected


REGISTRAR = addr("1")
RECEIPT = addr("2")
VAULT = addr("3")
TOKEN = addr("4")
SPACE = addr("5")
ARBITRATION = addr("6")
EVALUATOR = addr("7")
SPOT = addr("8")
MANAGER = addr("9")
RELAY = addr("a")
ADAPTER = addr("b")
STAGER = addr("c")
BIDDER_YES = addr("d")
BIDDER_NO = addr("e")
MARKET = addr("f")


def chain(market=MARKET, fork=0, removed=None):
    blocks = []
    parent = digest(9)
    for number in range(10, 22):
        block_hash = digest(number + fork if number >= 18 else number)
        blocks.append(
            {
                "number": hex(number),
                "hash": block_hash,
                "parentHash": parent,
                "timestamp": hex(number * 10),
            }
        )
        parent = block_hash
    by_number = {int(item["number"], 16): item for item in blocks}
    logs = [
        event_log(
            by_number[10],
            0,
            REGISTRAR,
            "registrar.genesisStaged",
            {"receipt": RECEIPT, "coreHash": digest(100), "flmHash": digest(101), "stager": STAGER},
        ),
        event_log(
            by_number[11],
            0,
            RECEIPT,
            "receipt.coreSealed",
            {
                "vault": VAULT,
                "companyToken": TOKEN,
                "space": SPACE,
                "arbitration": ARBITRATION,
                "evaluator": EVALUATOR,
                "spotPool": SPOT,
            },
        ),
        event_log(
            by_number[12],
            0,
            RECEIPT,
            "receipt.flmSealed",
            {"manager": MANAGER, "relay": RELAY, "spotAdapter": ADAPTER},
        ),
        event_log(
            by_number[13],
            0,
            ARBITRATION,
            "arbitration.proposalCreated",
            {"proposalId": 1, "creator": VAULT, "minActivationBond": 10},
        ),
        event_log(
            by_number[14],
            0,
            ARBITRATION,
            "arbitration.bondPlaced",
            {
                "proposalId": 1,
                "newState": 1,
                "bidder": BIDDER_YES,
                "amount": 10,
                "replacedBidder": addr("0"),
                "replacedAmount": 0,
            },
        ),
        event_log(
            by_number[15],
            0,
            ARBITRATION,
            "arbitration.bondPlaced",
            {
                "proposalId": 1,
                "newState": 2,
                "bidder": BIDDER_NO,
                "amount": 10,
                "replacedBidder": addr("0"),
                "replacedAmount": 0,
            },
        ),
        event_log(
            by_number[16],
            0,
            ARBITRATION,
            "arbitration.bondPlaced",
            {
                "proposalId": 1,
                "newState": 1,
                "bidder": BIDDER_YES,
                "amount": 20,
                "replacedBidder": BIDDER_YES,
                "replacedAmount": 10,
            },
        ),
        event_log(
            by_number[16],
            1,
            ARBITRATION,
            "arbitration.proposalGraduated",
            {"proposalId": 1, "queuePosition": 1, "requiredYesBond": 20, "yesBondAmount": 20},
        ),
        event_log(
            by_number[17],
            0,
            ARBITRATION,
            "arbitration.evaluationStarted",
            {"proposalId": 1},
        ),
        event_log(
            by_number[18],
            0,
            EVALUATOR,
            "evaluator.economicMarketCreated",
            {
                "proposalId": 1,
                "futarchyProposalId": 7,
                "futarchyProposal": market,
                "payloadKind": digest(110),
                "payloadCommitment": digest(111),
            },
        ),
        event_log(
            by_number[19],
            0,
            MANAGER,
            "flm.migratedToConditional",
            {"proposalId": 7, "spotRemoved": 80, "conditionalAdded": 160},
        ),
        event_log(
            by_number[20],
            0,
            ARBITRATION,
            "arbitration.evaluationResolved",
            {"proposalId": 1, "accepted": True, "winner": BIDDER_YES, "payout": 30},
        ),
        event_log(
            by_number[20],
            1,
            EVALUATOR,
            "evaluator.evaluationResolved",
            {
                "proposalId": 1,
                "futarchyProposal": market,
                "conditionId": digest(112),
                "accepted": True,
            },
        ),
        event_log(
            by_number[21],
            0,
            MANAGER,
            "flm.migratedBackToSpot",
            {"proposalId": 7, "conditionalRemoved": 160, "spotAdded": 82},
        ),
    ]
    if removed is not None:
        logs.append(removed(by_number))
    return blocks, logs


class WindtunnelIndexerTest(unittest.TestCase):
    def test_finalized_duplicate_restart_replay_and_reorg_are_deterministic(self):
        blocks, logs = chain()
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "windtunnel.sqlite"
            with Indexer(path) as indexer:
                report = indexer.sync(FakeRpc(blocks, logs, duplicate=True), 10, [REGISTRAR])
                first = indexer.report_bytes()
                self.assertEqual(report["rawCanonicalLogs"], 14)
                self.assertEqual(report["instances"][0]["proposals"][0]["state"], "SETTLED")
                self.assertEqual(report["instances"][0]["flm"]["mode"], "spot")
                self.assertEqual(indexer.replay(), first)
                self.assertEqual(indexer.report_bytes(), first)

            with Indexer(path) as restarted:
                self.assertEqual(restarted.report_bytes(), first)
                self.assertEqual(
                    restarted.sync(FakeRpc(blocks, logs), 10, [REGISTRAR]),
                    json.loads(first),
                )

            new_market = "0x" + "12" * 20

            def removed_old(by_number):
                return event_log(
                    by_number[18],
                    9,
                    EVALUATOR,
                    "evaluator.economicMarketCreated",
                    {
                        "proposalId": 1,
                        "futarchyProposalId": 99,
                        "futarchyProposal": MARKET,
                        "payloadKind": digest(1),
                        "payloadCommitment": digest(2),
                    },
                    removed=True,
                )

            forked_blocks, forked_logs = chain(new_market, fork=1000, removed=removed_old)
            with Indexer(path) as reorged:
                report = reorged.sync(FakeRpc(forked_blocks, forked_logs), 10, [REGISTRAR])
                self.assertEqual(
                    report["instances"][0]["proposals"][0]["futarchyProposal"], new_market
                )
                self.assertEqual(report["rawCanonicalLogs"], 14)
                after = reorged.report_bytes()
                self.assertEqual(reorged.replay(), after)

    def test_noncanonical_lineage_log_is_rejected(self):
        blocks, logs = chain()
        logs[0] = dict(logs[0], blockHash=digest(9999))
        with Indexer(":memory:") as indexer:
            with self.assertRaisesRegex(IndexerError, "lineage"):
                indexer.sync(FakeRpc(blocks, logs), 10, [REGISTRAR])


def keeper_state():
    return {
        "arbitration": ARBITRATION,
        "evaluator": EVALUATOR,
        "manager": MANAGER,
        "now": 100,
        "timeout": 10,
        "baseX": 20,
        "activeEvaluationProposalId": 0,
        "queue": [],
        "proposals": [],
        "flm": {"syncReady": False, "restoreNeeded": False, "emergency": False},
    }


class KeeperTest(unittest.TestCase):
    def test_one_action_policy_and_abi_goldens(self):
        state = keeper_state()
        state["proposals"] = [
            {
                "proposalId": 3,
                "state": "YES",
                "lastStateChangeAt": 90,
                "yesBondAmount": 20,
                "noBondAmount": 20,
            }
        ]
        action = keeper.decide(state)
        self.assertEqual(action.kind, "finalizeByTimeout")
        self.assertEqual(action.data, "0x13d4e9ed" + ("%064x" % 3))

        state["activeEvaluationProposalId"] = 3
        state["proposals"][0].update(
            {"state": "EVALUATING", "evaluationPayload": "0x1234", "futarchyProposal": None}
        )
        action = keeper.decide(state)
        expected = (
            "0x73561afc"
            + ("%064x" % 3)
            + ("%064x" % 64)
            + ("%064x" % 2)
            + "1234"
            + "00" * 30
        )
        self.assertEqual(action.data, expected)

    def test_fifo_max_queue_and_two_keeper_race(self):
        self.assertEqual(schema.EVENT_SCHEMA["maxQueue"], 16)
        self.assertEqual(keeper.MAX_QUEUE, 16)
        state = keeper_state()
        state["queue"] = [2, 1]
        state["proposals"] = [
            {"proposalId": 1, "state": "QUEUED"},
            {"proposalId": 2, "state": "QUEUED"},
        ]
        first = keeper.decide(copy.deepcopy(state))
        second = keeper.decide(copy.deepcopy(state))
        self.assertEqual(first, second)
        self.assertEqual(first.proposal_id, 2)

        landed = set()

        def send(action):
            if action.data in landed:
                raise RuntimeError("benign InvalidState race")
            landed.add(action.data)

        send(first)
        with self.assertRaisesRegex(RuntimeError, "benign"):
            send(second)

        state["queue"] = list(range(1, 17))
        state["proposals"] = [
            {"proposalId": value, "state": "QUEUED"} for value in range(1, 17)
        ]
        self.assertEqual(keeper.decide(state).proposal_id, 1)


def funding_manifest():
    return {
        "v": 1,
        "kind": "fao.windtunnel.funding",
        "chainId": "11155111",
        "runId": "unit-run",
        "runCapWei": "100",
        "roles": [
            {"role": role, "address": addr(str(index)), "ephemeral": True, "capWei": "40"}
            for index, role in enumerate(
                ["deployer", "proposer", "challenger", "marketMaker", "keeper"], 1
            )
        ],
        "instances": [
            {"receipt": RECEIPT, "capWei": "60", "markets": [{"proposalId": "1", "capWei": "30"}]}
        ],
    }


class FundingTest(unittest.TestCase):
    def test_role_separation_and_atomic_exhaustion(self):
        manifest = funding.validate_funding_manifest(funding_manifest())
        self.assertTrue(all(item["ephemeral"] for item in manifest["roles"]))
        budget = funding.FundingBudget(manifest)
        budget.spend("keeper", RECEIPT, 30, "1")
        snapshot = (budget.run_spent, dict(budget.role_spent), dict(budget.market_spent))
        with self.assertRaisesRegex(funding.FundingError, "market.*exhausted"):
            budget.spend("keeper", RECEIPT, 1, "1")
        self.assertEqual(snapshot, (budget.run_spent, budget.role_spent, budget.market_spent))

        broken = funding_manifest()
        broken["roles"][1]["address"] = broken["roles"][0]["address"]
        with self.assertRaisesRegex(funding.FundingError, "separated"):
            funding.validate_funding_manifest(broken)


if __name__ == "__main__":
    unittest.main()
