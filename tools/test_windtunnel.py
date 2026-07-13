from __future__ import annotations

import copy
import json
import tempfile
import unittest
from pathlib import Path

from tools.windtunnel import funding, keeper, schema
from tools.windtunnel.indexer import Indexer, IndexerError, RpcCallError, SELECTORS


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
GATEWAY = "0x" + "12" * 20
RELEASE = "0x" + "13" * 20


def chain(market=MARKET, fork=0, removed=None, proposal_id=1, include_gateway=False):
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
            {"proposalId": proposal_id, "creator": VAULT, "minActivationBond": 10},
        ),
        event_log(
            by_number[14],
            0,
            ARBITRATION,
            "arbitration.bondPlaced",
            {
                "proposalId": proposal_id,
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
                "proposalId": proposal_id,
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
                "proposalId": proposal_id,
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
            {"proposalId": proposal_id, "queuePosition": 1, "requiredYesBond": 20, "yesBondAmount": 20},
        ),
        event_log(
            by_number[17],
            0,
            ARBITRATION,
            "arbitration.evaluationStarted",
            {"proposalId": proposal_id},
        ),
        event_log(
            by_number[18],
            0,
            EVALUATOR,
            "evaluator.economicMarketCreated",
            {
                "proposalId": proposal_id,
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
            {"proposalId": proposal_id, "accepted": True, "winner": BIDDER_YES, "payout": 30},
        ),
        event_log(
            by_number[20],
            1,
            EVALUATOR,
            "evaluator.evaluationResolved",
            {
                "proposalId": proposal_id,
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
    if include_gateway:
        logs.insert(
            4,
            event_log(
                by_number[13],
                1,
                GATEWAY,
                "gateway.transferProposed",
                {
                    "proposalId": proposal_id,
                    "proposer": BIDDER_YES,
                    "asset": TOKEN,
                    "recipient": "0x" + "ab" * 20,
                    "amount": 10,
                    "salt": digest(123),
                },
            ),
        )
    if removed is not None:
        logs.append(removed(by_number))
    return blocks, logs


def abi_words(*values):
    return "0x" + b"".join(
        word("address", value)
        if isinstance(value, str) and len(value) == 42
        else word("bytes32", value)
        if isinstance(value, str)
        else int(value).to_bytes(32, "big")
        for value in values
    ).hex()


class HydratedFakeRpc(FakeRpc):
    def __init__(self, blocks, logs, active):
        super().__init__(blocks, logs)
        self.active = active

    def call(self, transaction, block="latest"):
        target = transaction["to"]
        data = transaction["data"]
        selector = data[2:10]
        if target == REGISTRAR:
            return abi_words(digest(999))
        if target == RECEIPT:
            values = {
                SELECTORS["coreHash"]: digest(100),
                SELECTORS["flmHash"]: digest(101),
                SELECTORS["coreSealed"]: 1,
                SELECTORS["flmSealed"]: 1,
                SELECTORS["proposalGateway"]: GATEWAY,
                SELECTORS["releaseStrategy"]: RELEASE,
            }
            return abi_words(values[selector])
        if target == ARBITRATION:
            if selector == SELECTORS["getProposal"]:
                return abi_words(
                    10,
                    BIDDER_YES,
                    20,
                    BIDDER_NO,
                    10,
                    4,
                    170,
                    0,
                    0,
                    1,
                    1,
                )
            values = {
                SELECTORS["timeout"]: 10,
                SELECTORS["baseX"]: 20,
                SELECTORS["maxQueue"]: 16,
                SELECTORS["activeEvaluation"]: self.active,
            }
            return abi_words(values[selector])
        if target == EVALUATOR:
            return abi_words(addr("0"))
        if target == RELAY:
            return abi_words(*([0] * 13))
        if target == MANAGER:
            values = {
                SELECTORS["inConditionalMode"]: 0,
                SELECTORS["activeProposalId"]: 0,
                SELECTORS["emergencyExitArmedAt"]: 0,
                SELECTORS["emergencyExitExecuted"]: 0,
                SELECTORS["initialized"]: 1,
                SELECTORS["totalSupply"]: 100,
                SELECTORS["spotLiquidity"]: 10,
                SELECTORS["conditionalYesLiquidity"]: 0,
                SELECTORS["conditionalNoLiquidity"]: 0,
                SELECTORS["sync"]: 0,
            }
            return abi_words(values[selector])
        return "0x"


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

    def test_hydrated_keeper_uses_only_event_committed_payload_and_persists_race(self):
        proposal_id = int(
            "d8c898acea826f42be384cdbcbdf67bf76f78e8f3bfd013adbdfa5125bd043b7", 16
        )
        blocks, logs = chain(proposal_id=proposal_id, include_gateway=True)
        blocks = [block for block in blocks if int(block["number"], 16) <= 17]
        logs = [log for log in logs if int(log["blockNumber"], 16) <= 17]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "hydrated.sqlite"
            with Indexer(path) as indexer:
                indexer.sync(HydratedFakeRpc(blocks, logs, proposal_id), 10, [REGISTRAR])
                state = indexer.keeper_state(RECEIPT)
                action = indexer.next_action(RECEIPT)
                self.assertEqual(action.kind, "startEvaluation")
                self.assertEqual(
                    state["proposals"][0]["evaluationPayload"],
                    "0x"
                    + "27e49851e3b79673e847d7c12acc52a3936006b8517243a42df902b3df4e902e"
                    + ("%064x" % 11155111)
                    + "00" * 12
                    + VAULT[2:]
                    + "00" * 12
                    + TOKEN[2:]
                    + "00" * 12
                    + ("ab" * 20)
                    + ("%064x" % 10)
                    + ("%064x" % 123),
                )

                simulated = indexer.staticcall_action(
                    HydratedFakeRpc(blocks, logs, proposal_id), action, addr("1")
                )
                self.assertEqual(simulated["classification"], "ok")
                indexer.record_attempt(action, addr("1"), "send", "submitted")
                indexer.record_attempt(action, addr("2"), "send", "submitted")

                winner = indexer.record_attempt(
                    action,
                    addr("1"),
                    "receipt",
                    "landed",
                    tx_hash=digest(700),
                )
                loser = indexer.record_attempt(
                    action,
                    addr("2"),
                    "receipt",
                    "revert",
                    revert_data="0xbaf3f0f7",
                    tx_hash=digest(701),
                )
                self.assertEqual(loser["classification"], "race-candidate")
                loser = indexer.classify_race(
                    winner["attempt_id"], loser["attempt_id"], postcondition_satisfied=True
                )
                self.assertEqual(loser["classification"], "benign-race")

                manifest = funding_manifest()
                budget = funding.FundingBudget(manifest)
                budget.spend("keeper", RECEIPT, 30, "1")
                with self.assertRaises(funding.FundingError):
                    budget.spend("keeper", RECEIPT, 1, "1")
                indexer.record_attempt(
                    action, addr("5"), "funding", "refused", detail="market funding cap exhausted"
                )
                before = indexer.report_bytes()
                self.assertEqual(indexer.replay(), before)

            with Indexer(path) as restarted:
                self.assertEqual(restarted.report_bytes(), before)
                attempts = restarted.report()["attempts"]
                self.assertEqual(
                    [item["classification"] for item in attempts],
                    ["ok", "submitted", "submitted", "landed", "benign-race", "refused"],
                )


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

    def test_space_event_decoder_recovers_exact_committed_dynamic_payload(self):
        metadata = b"ipfs"
        payload = bytes.fromhex("123456")
        head = [
            word("uint256", 9),
            word("address", BIDDER_YES),
            word("address", BIDDER_YES),
            word("uint256", 1),
            word("address", RELEASE),
            word("uint256", 2),
            word("uint256", 3),
            word("uint256", 0),
            word("bytes32", digest(555)),
            word("uint256", 1),
            word("uint256", 12 * 32),
            word("uint256", 14 * 32),
        ]
        dynamic = (
            word("uint256", len(metadata))
            + metadata
            + bytes(28)
            + word("uint256", len(payload))
            + payload
            + bytes(29)
        )
        spec, decoded = schema.decode_event(
            {
                "topics": [EVENTS_BY_ID["space.proposalCreated"]["topic0"]],
                "data": "0x" + (b"".join(head) + dynamic).hex(),
            }
        )
        self.assertEqual(spec["id"], "space.proposalCreated")
        self.assertEqual(decoded["executionStrategy"], RELEASE)
        self.assertEqual(decoded["evaluationPayload"], "0x123456")
        self.assertEqual(decoded["arbitrationId"], 555)


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
