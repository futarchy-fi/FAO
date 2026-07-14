#!/usr/bin/env python3
"""Run the fork-only Rehearsal R0 S3 agent matrix twice."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Sequence

try:
    from tools import agent_documents as documents
    from tools import agent_runner as runner
    from tools import agent_tournament as tournament
    from tools import rehearsal_r0 as s1
    from tools.windtunnel import anvil_drill as windtunnel
except ModuleNotFoundError:  # Direct script execution.
    import agent_documents as documents  # type: ignore
    import agent_runner as runner  # type: ignore
    import agent_tournament as tournament  # type: ignore
    import rehearsal_r0 as s1  # type: ignore
    from windtunnel import anvil_drill as windtunnel  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "script/RehearsalR0.s.sol"
EVIDENCE_PATH = ROOT / "metadata/rehearsal-r0-s3-evidence.json"
S1_EVIDENCE_PATH = ROOT / "metadata/rehearsal-r0-s1-evidence.json"
P2A_EVIDENCE_PATH = ROOT / "metadata/agent-work-p2a-evidence.json"
WAD = 10**18
ZERO_ADDRESS = "0x" + "00" * 20
ZERO32 = "0x" + "00" * 32
EXCLUDED_FIELDS = ("port", "processId", "providerUrl", "wallDurationMs")

NON_AGENT_ACTORS = {
    name: "0x200000000000000000000000000000000000%04x" % ordinal
    for ordinal, name in enumerate(("funder1", "funder2", "funder3", "funder4", "keeper", "trader"), 1)
}
ACTORS = {**tournament.ACTOR_ADDRESSES, **NON_AGENT_ACTORS}
CONTRIBUTIONS = {"agentA": 110 * WAD, "agentB": 204 * WAD, "agentC": 404 * WAD}
EXPECTED_WITHDRAWABLE = {"agentA": 712 * WAD, "agentB": 2 * WAD, "agentC": 4 * WAD}
INVALID_STATE = "0xbaf3f0f7"
ARBITRATION_NOT_ACCEPTED = "0xf7d18d68"
ABSOLUTE_CLOCK_OFFSETS = (
    ("deployment-complete", 6),
    ("index-deployed", 7),
    ("sale-sealed", 86_401),
    ("timeout-settlement-boundary", 347_435),
    ("timeout-first-execution", 433_841),
    ("A-T2:anchor", 433_845),
    ("A-T2:window-end", 1_038_645),
    ("A-T2:resolved", 1_038_646),
    ("A-T2:restored", 1_040_448),
    ("B-T2:anchor", 1_125_049),
    ("B-T2:window-end", 1_729_849),
    ("B-T2:resolved", 1_729_850),
    ("B-T2:restored", 1_731_652),
    ("C-T1:anchor", 1_731_654),
    ("C-T1:window-end", 2_336_454),
    ("C-T1:resolved", 2_336_455),
    ("C-T1:restored", 2_338_257),
)
CLOCK_CHECKPOINT_OFFSETS = {
    "deployment-complete": 6,
    "index-deployed": 7,
    "sale-pre-mine": 25,
    "sale-sealed": 86_401,
    "timeout-settlement-pre-mine": 88_241,
    "timeout-settlement-boundary": 347_435,
    "timeout-execution-pre-mine": 347_441,
    "timeout-first-execution": 433_841,
    "A-T2:anchor": 433_845,
    "A-T2:pre-6d": 433_854,
    "A-T2:post-6d": 952_245,
    "A-T2:window-end": 1_038_645,
    "A-T2:resolved": 1_038_646,
    "A-T2:pre-restore": 1_038_647,
    "A-T2:restored": 1_040_448,
    "A-T2:pre-payment": 1_040_448,
    "B-T2:anchor": 1_125_049,
    "B-T2:pre-6d": 1_125_057,
    "B-T2:post-6d": 1_643_449,
    "B-T2:window-end": 1_729_849,
    "B-T2:resolved": 1_729_850,
    "B-T2:pre-restore": 1_729_851,
    "B-T2:restored": 1_731_652,
    "C-T1:anchor": 1_731_654,
    "C-T1:pre-6d": 1_731_662,
    "C-T1:post-6d": 2_250_054,
    "C-T1:window-end": 2_336_454,
    "C-T1:resolved": 2_336_455,
    "C-T1:pre-restore": 2_336_456,
    "C-T1:restored": 2_338_257,
}

_KECCAK_ROTATION = (
    0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39, 41, 45, 15, 21, 8,
    18, 2, 61, 56, 14,
)
_KECCAK_ROUND_CONSTANTS = (
    0x0000000000000001, 0x0000000000008082, 0x800000000000808A, 0x8000000080008000,
    0x000000000000808B, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
    0x000000000000008A, 0x0000000000000088, 0x0000000080008009, 0x000000008000000A,
    0x000000008000808B, 0x800000000000008B, 0x8000000000008089, 0x8000000000008003,
    0x8000000000008002, 0x8000000000000080, 0x000000000000800A, 0x800000008000000A,
    0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008,
)


class AgentsError(s1.RehearsalError):
    pass


class LatestRpc(runner.JsonRpc):
    """The evidence models deterministic Anvil latest, never upstream finality."""

    def finalized_block(self) -> dict[str, Any]:
        return self.block("latest")


class RunnerSender:
    def __init__(self, session: s1.Session, submission: dict[str, Any], expected: str) -> None:
        self.session = session
        self.submission = submission
        self.expected = expected
        self.landed: dict[str, Any] | None = None

    def send(self, transaction: dict[str, Any]) -> str:
        actor = tournament.ACTOR_ADDRESSES[self.submission["agent"]]
        if transaction.get("from", "").lower() != actor:
            raise AgentsError("runner sender identity drifted")
        self.landed = self.session.send(
            "runner:%s:%s" % (self.expected, self.submission["id"]),
            actor,
            transaction["to"],
            transaction["data"],
        )
        return self.landed["record"]["hash"]


def _absolute_clock_stages() -> list[dict[str, int | str]]:
    return [
        {"stage": stage, "timestamp": s1.FORK_TIMESTAMP + offset}
        for stage, offset in ABSOLUTE_CLOCK_OFFSETS
    ]


def _clock_checkpoint(session: s1.Session, label: str) -> None:
    expected = s1.FORK_TIMESTAMP + CLOCK_CHECKPOINT_OFFSETS[label]
    if session.clock != expected:
        raise AgentsError("S3 clock checkpoint %s drifted: %d != %d" % (label, session.clock, expected))


def _keccak256(value: bytes) -> str:
    """Small stdlib-only Ethereum Keccak-256 for the offline verifier."""
    mask = (1 << 64) - 1
    padded = bytearray(value)
    padded.append(1)
    padded.extend(b"\0" * ((-len(padded)) % 136))
    padded[-1] |= 0x80
    state = [0] * 25
    for offset in range(0, len(padded), 136):
        for lane in range(17):
            state[lane] ^= int.from_bytes(padded[offset + lane * 8 : offset + lane * 8 + 8], "little")
        for constant in _KECCAK_ROUND_CONSTANTS:
            columns = [state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20] for x in range(5)]
            for x in range(5):
                delta = columns[(x - 1) % 5] ^ ((columns[(x + 1) % 5] << 1) | (columns[(x + 1) % 5] >> 63)) & mask
                for y in range(5):
                    state[x + 5 * y] ^= delta
            rotated = [0] * 25
            for x in range(5):
                for y in range(5):
                    lane = state[x + 5 * y]
                    shift = _KECCAK_ROTATION[x + 5 * y]
                    rotated[y + 5 * ((2 * x + 3 * y) % 5)] = ((lane << shift) | (lane >> ((64 - shift) % 64))) & mask
            for x in range(5):
                for y in range(5):
                    state[x + 5 * y] = rotated[x + 5 * y] ^ ((~rotated[(x + 1) % 5 + 5 * y]) & rotated[(x + 2) % 5 + 5 * y])
            state[0] ^= constant
    return "0x" + b"".join(lane.to_bytes(8, "little") for lane in state)[:32].hex()


def _install_offline_keccak() -> None:
    documents.keccak256 = _keccak256
    for function in (
        documents.document_digest,
        documents.payment_transfer_action,
        documents.transfer_hash,
        documents.validate_payment_binding,
    ):
        function.__defaults__ = (_keccak256,)


def _tick(
    rpc: LatestRpc, session: s1.Session, submission: dict[str, Any], expected: str
) -> dict[str, Any]:
    sender = RunnerSender(session, submission, expected)
    result = runner.tick(submission["config"], rpc, rpc, sender)
    attempts = result.get("attempts")
    if (
        result.get("action") != expected
        or not isinstance(attempts, list)
        or len(attempts) != 1
        or attempts[0].get("outcome") != "submitted"
    ):
        raise AgentsError("%s expected %s, got %r" % (submission["id"], expected, result))
    if sender.landed is None:
        raise AgentsError("runner reported a submission without a landed transaction")
    result["landed"] = sender.landed
    return result


def _state(rpc: LatestRpc, submission: dict[str, Any]) -> dict[str, Any]:
    return runner.derive_state(
        submission["config"], runner.collect_snapshot(rpc, submission["config"])
    )


def _record_existing(
    rpc: LatestRpc, session: s1.Session, label: str, tx_hash: str, *, contract: str | None = None
) -> dict[str, Any]:
    receipt = rpc.request("eth_getTransactionReceipt", [tx_hash])
    transaction = rpc.request("eth_getTransactionByHash", [tx_hash])
    if not isinstance(receipt, dict) or not isinstance(transaction, dict):
        raise AgentsError(label + " transaction disappeared")
    if int(receipt["status"], 16) != 1:
        raise AgentsError(label + " transaction failed")
    if contract is not None and receipt.get("contractAddress", "").lower() != contract:
        raise AgentsError(label + " contract address drifted")
    block = rpc.block(int(receipt["blockNumber"], 16))
    session.clock = int(block["timestamp"], 16)
    record = {
        "blockHash": receipt["blockHash"].lower(),
        "blockNumber": int(receipt["blockNumber"], 16),
        "blockTimestamp": session.clock,
        "from": transaction["from"].lower(),
        "gasUsed": int(receipt["gasUsed"], 16),
        "hash": tx_hash.lower(),
        "inputKeccak256": documents.keccak256(bytes.fromhex(transaction["input"][2:])),
        "label": label,
        "logCount": len(receipt["logs"]),
        "logsSha256": s1._log_digest(receipt["logs"]),
        "nonce": int(transaction["nonce"], 16),
        "status": 1,
        "to": transaction.get("to").lower() if transaction.get("to") else None,
        "value": str(int(transaction["value"], 16)),
    }
    session.transactions.append(record)
    return {"receipt": receipt, "record": record}


def _deploy_index(rpc: LatestRpc, session: s1.Session, rpc_url: str) -> str:
    rpc.request("evm_setNextBlockTimestamp", [session.clock + 1])
    output = s1._run(
        (
            "forge",
            "create",
            "src/AgentWorkIndex.sol:AgentWorkIndex",
            "--rpc-url",
            rpc_url,
            "--unlocked",
            "--from",
            tournament.ACTOR_ADDRESSES["steward"],
            "--broadcast",
            "--gas-limit",
            "30000000",
        )
    )
    address_match = re.search(r"Deployed to:\s*(0x[0-9a-fA-F]{40})", output)
    hash_match = re.search(r"Transaction hash:\s*(0x[0-9a-fA-F]{64})", output, re.I)
    if address_match is None:
        raise AgentsError("forge create did not report AgentWorkIndex address")
    address = address_match.group(1).lower()
    if hash_match is None:
        block = rpc.request("eth_getBlockByNumber", ["latest", True])
        matches = [
            tx["hash"]
            for tx in block.get("transactions", [])
            if tx.get("from", "").lower() == tournament.ACTOR_ADDRESSES["steward"]
            and tx.get("to") is None
        ]
        if len(matches) != 1:
            raise AgentsError("AgentWorkIndex deployment transaction is ambiguous")
        tx_hash = matches[0].lower()
    else:
        tx_hash = hash_match.group(1).lower()
    _record_existing(rpc, session, "index:deploy", tx_hash, contract=address)
    if s1._runtime_hash(rpc, address) == "0x" + "00" * 32:
        raise AgentsError("AgentWorkIndex runtime is empty")
    return address


def _sealed_s1() -> dict[str, Any]:
    raw = S1_EVIDENCE_PATH.read_bytes()
    value = json.loads(raw)
    sidecar = S1_EVIDENCE_PATH.with_suffix(S1_EVIDENCE_PATH.suffix + ".sha256").read_text().strip()
    if (
        value.get("kind") != "fao.rehearsal.r0-s1"
        or value.get("v") != "1"
        or raw != s1._canonical(value)
        or sidecar != "0x" + hashlib.sha256(raw).hexdigest()
    ):
        raise AgentsError("sealed S1 evidence sidecar drifted")
    return value


def _sealed_p2a() -> dict[str, Any]:
    raw = P2A_EVIDENCE_PATH.read_bytes()
    value = json.loads(raw)
    sidecar = P2A_EVIDENCE_PATH.with_suffix(P2A_EVIDENCE_PATH.suffix + ".sha256").read_text().strip()
    submissions = value.get("submissions", [])
    expected_ids = [item[0] for item in tournament.SUBMISSION_FACTS]
    if (
        value.get("kind") != "fao.agentwork.p2a-evidence"
        or value.get("v") != "1"
        or raw != s1._canonical(value)
        or sidecar != "0x" + hashlib.sha256(raw).hexdigest()
        or [item.get("id") for item in submissions] != expected_ids
        or len({item.get("proposalId") for item in submissions}) != len(expected_ids)
        or any(
            not isinstance(item.get("proposalId"), str)
            or re.fullmatch(r"[1-9][0-9]*", item["proposalId"]) is None
            for item in submissions
        )
    ):
        raise AgentsError("sealed P2a evidence identity drifted")
    return value


def _p2a_proposal_bindings(value: dict[str, Any] | None = None) -> list[dict[str, str]]:
    value = _sealed_p2a() if value is None else value
    return sorted(
        ({"id": item["id"], "proposalId": item["proposalId"]} for item in value["submissions"]),
        key=lambda item: item["id"],
    )


def _p2a_proposal_bindings_sha256(value: dict[str, Any] | None = None) -> str:
    return "0x" + hashlib.sha256(s1._canonical(_p2a_proposal_bindings(value))).hexdigest()


def _hero_genesis(
    rpc: LatestRpc, session: s1.Session, stack: dict[str, Any]
) -> dict[str, Any]:
    a = stack["addresses"]
    vault, manager, company = a["vault"], a["manager"], a["companyToken"]
    executor = s1._address(rpc, vault, "TREASURY_EXECUTOR()")
    buys = []
    sold = 0
    purchase_plan = (
        ("funder1", 8 * WAD),
        ("funder1", 8 * WAD),
        ("funder1", 8 * WAD),
        ("funder2", 18 * WAD),
        ("funder3", 12 * WAD),
        ("funder4", 6 * WAD),
    )
    for ordinal, (actor_name, amount) in enumerate(purchase_plan, 1):
        actor = NON_AGENT_ACTORS[actor_name]
        before = s1._uint(rpc, vault, "reserveAt(uint256)", sold)
        after = s1._uint(rpc, vault, "reserveAt(uint256)", sold + amount)
        cost = after - before
        s1._deposit_weth(session, actor, cost, "sale:%d:wrap" % ordinal)
        s1._approve(session, actor, s1.WETH, vault, cost, "sale:%d:approve" % ordinal)
        sent = session.send(
            "sale:%d:buy" % ordinal,
            actor,
            vault,
            s1._calldata("buy(uint256,uint256,uint256)", amount, cost, session.clock + 1_000),
        )
        event = s1._event(sent["receipt"], "Purchased(address,uint256,uint256)", vault)
        words = s1._words(event["data"], 2)
        if [s1._uint_word(word) for word in words] != [amount, cost]:
            raise AgentsError("purchase event disagrees with reserve path")
        buys.append({"actor": actor_name, "amount": str(amount), "cost": str(cost)})
        sold += amount

    raised = s1._uint(rpc, vault, "totalRaised()")
    if sold != 60 * WAD or s1._uint(rpc, vault, "totalSold()") != sold or raised != 24 * WAD // 10:
        raise AgentsError("hero raise totals drifted")
    if sum(int(item["cost"]) for item in buys[:3]) != s1._uint(rpc, vault, "reserveAt(uint256)", 24 * WAD):
        raise AgentsError("split first purchase is not path independent")

    _clock_checkpoint(session, "sale-pre-mine")
    sale_end = s1._uint(rpc, vault, "SALE_END()")
    session.mine_at(sale_end)
    session.send("sale:seal", NON_AGENT_ACTORS["keeper"], vault, s1._calldata("seal()"))
    _clock_checkpoint(session, "sale-sealed")
    finalized = session.send(
        "sale:finalize", NON_AGENT_ACTORS["keeper"], vault, s1._calldata("finalize()")
    )
    final_event = s1._event(
        finalized["receipt"], "Finalized(uint256,uint256,uint256,uint256,uint256)", vault
    )
    final_words = [s1._uint_word(word) for word in s1._words(final_event["data"], 5)]
    bootstrap_company, bootstrap_collateral, shares = final_words[2:]
    terminal_price = s1._uint(rpc, vault, "terminalPrice()")
    expected_company = (bootstrap_collateral * WAD + terminal_price - 1) // terminal_price
    if (
        final_words[:2] != [sold, raised]
        or bootstrap_collateral != raised // 2
        or bootstrap_company != expected_company
        or s1._uint(rpc, vault, "phase()") != 2
        or s1._balance(rpc, s1.WETH, executor) != raised - bootstrap_collateral
        or s1._balance(rpc, manager, executor) != shares
        or s1._balance(rpc, s1.WETH, vault) != 0
        or s1._balance(rpc, manager, vault) != 0
    ):
        raise AgentsError("atomic bootstrap reconciliation failed")
    spot_liquidity = s1._uint(rpc, manager, "spotLiquidity()")
    spot_nft = s1._position_id(rpc, a["spotAdapter"], company, s1.WETH)
    spot_position = s1._npm_position(rpc, spot_nft)
    if (
        spot_liquidity == 0
        or s1._uint(rpc, manager, "totalSupply()") != shares
        or spot_position["owner"] != a["spotAdapter"]
        or spot_position["liquidity"] != spot_liquidity
    ):
        raise AgentsError("bootstrap spot custody drifted")
    stack["runtimeHashes"]["spotPool"] = s1._runtime_hash(rpc, a["spotPool"])
    stack["executor"] = executor
    bootstrap = {
        "bootstrapCollateral": str(bootstrap_collateral),
        "bootstrapCompany": str(bootstrap_company),
        "executorFlmShares": str(s1._balance(rpc, manager, executor)),
        "executorWeth": str(s1._balance(rpc, s1.WETH, executor)),
        "flmShares": str(shares),
        "spotLiquidity": str(spot_liquidity),
        "spotNpmPosition": spot_position,
        "terminalPrice": str(terminal_price),
    }
    sealed = _sealed_s1()["economicProjection"]
    if stack != sealed["stack"] or bootstrap != sealed["bootstrap"]:
        raise AgentsError("S3 hero is not byte-identical to the sealed S1 stack/bootstrap")
    if {"buys": buys, "funder1SplitCost": str(sum(int(item["cost"]) for item in buys[:3])), "raised": str(raised), "sold": str(sold)} != sealed["raise"]:
        raise AgentsError("S3 hero raise is not semantically identical to sealed S1")
    session.mine_at(session.clock + 30 * 60)
    s1._call(rpc, a["guard"], "assertStablePair(address,address)", company, s1.WETH)
    return {
        "bootstrap": bootstrap,
        "executor": executor,
        "raise": sealed["raise"],
        "spotNft": spot_nft,
        "terminalPrice": terminal_price,
    }


def _agent_stack(
    rpc: LatestRpc, stack: dict[str, Any], index: str, observation_block: int
) -> dict[str, Any]:
    a = stack["addresses"]
    executor = stack["executor"]
    contracts = {
        "index": index,
        "gateway": a["proposalGateway"],
        "arbitration": a["arbitration"],
        "vault": a["vault"],
        "executor": executor,
    }
    return {
        "chainId": s1.CHAIN_ID,
        "forkBlock": s1.FORK_BLOCK,
        "forkBlockHash": s1.FORK_BLOCK_HASH,
        "observationBlock": observation_block,
        "startBlock": s1.FORK_BLOCK + 1,
        "startTimestamp": s1.FORK_TIMESTAMP,
        "asset": s1.WETH,
        "minActivationBond": 2 * WAD,
        **contracts,
        "runtimeCodeKeccak256": {
            name: s1._runtime_hash(rpc, address) for name, address in contracts.items()
        },
    }


def _matrix(
    rpc: LatestRpc, stack: dict[str, Any]
) -> tuple[dict[str, bytes], list[dict[str, Any]], dict[str, dict[str, bool]]]:
    correct_t1 = tournament.build_t1_artifact()
    correct_t2 = tournament.build_t2_artifact(stack)
    wrong_t2_value = json.loads(correct_t2)
    wrong_t2_value["runtimeCodeKeccak256"]["gateway"] = "0x" + "00" * 32
    correct_t3 = tournament.build_t3_artifact(stack)
    blobs = {
        "t1": correct_t1,
        "t2": correct_t2,
        "t2-wrong": runner.canonical_json(wrong_t2_value),
        "t3": correct_t3,
    }
    submissions = tournament._submission_configs(stack, blobs)
    for submission in submissions:
        submission["config"]["caps"]["bondAmount"] = str(2 * WAD)
    graders: dict[str, dict[str, bool]] = {}
    seen: set[tuple[str, str]] = set()
    for submission in submissions:
        blob = blobs[submission["artifact"]]
        key = (submission["taskId"], submission["artifactDigest"])
        original = submission["taskId"] != "T1" or key not in seen
        seen.add(key)
        objective = {
            "T1": tournament.grade_t1(blob),
            "T2": tournament.grade_t2(blob, rpc, stack),
            "T3": tournament.grade_t3(blob, stack),
        }[submission["taskId"]]
        graders[submission["id"]] = {
            "objectiveCorrect": objective,
            "original": original,
            "verdict": objective and original,
        }
    if [name for name, grade in graders.items() if grade["verdict"]] != ["A-T1", "A-T2", "A-T3", "C-T3"]:
        raise AgentsError("P2a grader/copy matrix drifted")
    if tournament.submissions_by_policy(graders) != tournament.EVALUATION_IDS:
        raise AgentsError("P2a challenge policy drifted")
    return blobs, submissions, graders


def _publish_tasks(
    session: s1.Session, index: str, submissions: list[dict[str, Any]]
) -> dict[str, Any]:
    published = {}
    for task_id in ("T1", "T2", "T3"):
        task = next(item["task"] for item in submissions if item["taskId"] == task_id)
        publication = documents.prepare_publication("task", task)
        sent = session.send(
            "index:task:" + task_id,
            tournament.ACTOR_ADDRESSES["steward"],
            index,
            publication["calldata"],
        )
        published[task_id] = {
            "digest": publication["documentDigest"],
            "document": "0x" + publication["document"].hex(),
            "transactionHash": sent["record"]["hash"],
        }
    return published


def _state_pin(rpc: LatestRpc, label: str, submission: dict[str, Any]) -> dict[str, Any]:
    state = _state(rpc, submission)
    view = {
        "actionHash": state["actionHash"],
        "lifecycle": state["lifecycle"],
        "proposal": state["proposal"],
        "queued": state["queued"],
        "paid": state["paid"],
    }
    return {
        "accepted": state["accepted"],
        "blockHash": state["finalized"]["hash"],
        "blockNumber": str(state["finalized"]["number"]),
        "label": label,
        "lifecycle": state["lifecycle"],
        "stateSha256": "0x" + hashlib.sha256(runner.canonical_json(view)).hexdigest(),
        "stateView": view,
    }


def _prepare_agents(
    rpc: LatestRpc,
    session: s1.Session,
    stack: dict[str, Any],
    submissions: list[dict[str, Any]],
    graders: dict[str, dict[str, bool]],
) -> dict[str, Any]:
    a = stack["addresses"]
    by_id = {item["id"]: item for item in submissions}
    p2a_ids = {item["proposalId"] for item in _sealed_p2a()["submissions"]}
    hero_ids = {item["proposalId"] for item in submissions}
    if len(hero_ids) != 6 or hero_ids & p2a_ids:
        raise AgentsError("hero proposal IDs are not six cross-stack-disjoint bindings")

    bond_before = {}
    for name, amount in CONTRIBUTIONS.items():
        actor = tournament.ACTOR_ADDRESSES[name]
        s1._deposit_weth(session, actor, amount, "bond:%s:wrap" % name)
        s1._approve(session, actor, s1.WETH, a["arbitration"], amount, "bond:%s:approve" % name)
        bond_before[name] = s1._balance(rpc, s1.WETH, actor)
    tasks = _publish_tasks(session, stack["index"], submissions)

    round_robin = []
    restart = []
    for expected in tournament.ROUND_ROBIN_ACTIONS:
        for submission_id in tournament.ROUND_ROBIN_IDS:
            submission = by_id[submission_id]
            _tick(rpc, session, submission, expected)
            round_robin.append(
                {"action": expected, "agent": submission["agent"], "submission": submission_id}
            )
            if submission_id == "A-T2":
                restart.append(_state_pin(rpc, expected, submission))

    challenge_facts = {
        submission_id: challenger
        for submission_id, challenger in tournament.EXPECTED_CHALLENGES.items()
        if challenger is not None
    }
    for submission_id in tournament.EVALUATION_IDS:
        challenger = challenge_facts[submission_id]
        submission = by_id[submission_id]
        session.send(
            "challenge:" + submission_id,
            tournament.ACTOR_ADDRESSES[challenger],
            a["arbitration"],
            s1._calldata("placeNoBond(uint256)", submission["proposalId"]),
        )
        if submission_id == "A-T2":
            restart.append(_state_pin(rpc, "challenged", submission))

    graduation = {}
    for queue_index, submission_id in enumerate(tournament.EVALUATION_IDS):
        required = s1._uint(rpc, a["arbitration"], "requiredYes(uint256)", queue_index)
        if required != 100 * WAD * (2**queue_index):
            raise AgentsError("hero graduation threshold drifted")
        submission = by_id[submission_id]
        session.send(
            "graduate:" + submission_id,
            tournament.ACTOR_ADDRESSES[submission["agent"]],
            a["arbitration"],
            s1._calldata("placeYesBond(uint256,uint256)", submission["proposalId"], required),
        )
        state = _state(rpc, submission)
        if state["proposal"]["state"] != "QUEUED" or state["proposal"]["queuePosition"] != queue_index + 1:
            raise AgentsError("hero proposal violated the three-position FIFO")
        graduation[submission_id] = {
            "queuePosition": str(queue_index + 1),
            "requiredYesBond": str(required),
        }
        if submission_id == "A-T2":
            restart.append(_state_pin(rpc, "graduated", submission))

    if any(s1._balance(rpc, s1.WETH, tournament.ACTOR_ADDRESSES[name]) for name in CONTRIBUTIONS):
        raise AgentsError("exact hero bond contributions were not fully escrowed")
    escrow = s1._balance(rpc, s1.WETH, a["arbitration"])
    if escrow != sum(CONTRIBUTIONS.values()):
        raise AgentsError("hero arbitration escrow does not equal 718 WETH")
    return {
        "bondBefore": {name: str(value) for name, value in bond_before.items()},
        "byId": by_id,
        "challengeFacts": challenge_facts,
        "crossStackProposalIds": {
            "hero": sorted(hero_ids),
            "p2a": sorted(p2a_ids),
            "intersection": [],
        },
        "escrowAfterGraduation": str(escrow),
        "graduation": graduation,
        "restartPins": restart,
        "roundRobinTicks": round_robin,
        "tasks": tasks,
        "graders": graders,
    }


def _market_start(
    rpc: LatestRpc,
    session: s1.Session,
    stack: dict[str, Any],
    submission: dict[str, Any],
    *, probe_active: bool,
) -> dict[str, Any]:
    a = stack["addresses"]
    proposal_id = int(submission["proposalId"])
    session.send(
        "evaluation:dequeue:" + submission["id"],
        NON_AGENT_ACTORS["keeper"],
        a["arbitration"],
        s1._calldata("startNextEvaluation()"),
    )
    if s1._uint(rpc, a["arbitration"], "activeEvaluationProposalId()") != proposal_id:
        raise AgentsError("active evaluation violated the P2a FIFO")
    action = "(%s,%s,%s,%s)" % (
        submission["action"]["asset"],
        submission["action"]["recipient"],
        submission["action"]["amount"],
        submission["action"]["salt"],
    )
    payload = s1._dynamic_bytes(
        s1._call(
            rpc,
            a["proposalGateway"],
            "transferEvaluationPayload((address,address,uint256,bytes32))",
            action,
        )
    )
    if int(documents.keccak256(payload), 16) != proposal_id:
        raise AgentsError("agent payment payload does not bind its proposal ID")
    spot_anchor = s1._pool_evidence(rpc, a["spotPool"])
    started = session.send(
        "evaluation:start-market:" + submission["id"],
        NON_AGENT_ACTORS["keeper"],
        a["evaluator"],
        s1._calldata("startEvaluation(uint256,bytes)", proposal_id, "0x" + payload.hex()),
    )
    _clock_checkpoint(session, submission["id"] + ":anchor")
    proposal = s1._address(rpc, a["evaluator"], "futarchyProposalOf(uint256)", proposal_id)
    binding = s1._binding(rpc, a["resolver"], proposal)
    condition = s1._bytes32(rpc, proposal, "conditionId()")
    question = s1._bytes32(rpc, proposal, "questionId()")
    wrappers = [s1._wrapped_outcome(rpc, proposal, index) for index in range(4)]
    yes_company, no_company, yes_currency, no_currency = [item[0] for item in wrappers]

    observation_cardinality = s1._uint(rpc, a["orchestrator"], "OBSERVATION_CARDINALITY()")
    if observation_cardinality < 120 or s1._address(rpc, a["orchestrator"], "adapter()") != ZERO_ADDRESS:
        raise AgentsError("production orchestrator pool policy drifted")
    spot_currency_sqrt = (
        spot_anchor["slot0"]["sqrtPriceX96"]
        if spot_anchor["token0"] == a["companyToken"]
        else s1._invert_sqrt_price(spot_anchor["slot0"]["sqrtPriceX96"])
    )
    pools = {}
    for label, company_wrapper, currency_wrapper, pool in (
        ("yes", yes_company, yes_currency, binding["yesPool"]),
        ("no", no_company, no_currency, binding["noPool"]),
    ):
        evidence = s1._pool_evidence(rpc, pool)
        expected_tokens = sorted((company_wrapper, currency_wrapper))
        expected_sqrt = (
            spot_currency_sqrt
            if company_wrapper < currency_wrapper
            else s1._invert_sqrt_price(spot_currency_sqrt)
        )
        empty = {
            "companyPoolBalance": s1._balance(rpc, company_wrapper, pool),
            "companyTotalSupply": s1._uint(rpc, company_wrapper, "totalSupply()"),
            "currencyPoolBalance": s1._balance(rpc, currency_wrapper, pool),
            "currencyTotalSupply": s1._uint(rpc, currency_wrapper, "totalSupply()"),
            "factoryPool": s1._address(
                rpc,
                s1.UNIV3_FACTORY,
                "getPool(address,address,uint24)",
                company_wrapper,
                currency_wrapper,
                s1.FEE,
            ),
        }
        if (
            [evidence["token0"], evidence["token1"]] != expected_tokens
            or evidence["fee"] != s1.FEE
            or evidence["slot0"]["sqrtPriceX96"] != expected_sqrt
            or evidence["slot0"]["observationCardinalityNext"] != observation_cardinality
            or evidence["liquidity"] != 0
            or any(empty[key] for key in empty if key != "factoryPool")
            or s1._position_id(rpc, a["conditionalAdapter"], company_wrapper, currency_wrapper) != 0
            or empty["factoryPool"] != pool
        ):
            raise AgentsError("official %s pool was not exact and empty" % label)
        pools[label] = {
            **evidence,
            "companyWrapper": company_wrapper,
            "currencyWrapper": currency_wrapper,
            "expectedInitialSqrtPriceX96": str(expected_sqrt),
            **{
                key: str(value) if isinstance(value, int) else value
                for key, value in empty.items()
            },
        }
    if (
        binding["questionId"] != question
        or binding["companyToken"] != a["companyToken"]
        or binding["currencyToken"] != s1.WETH
        or binding["anchorTimestamp"] != started["record"]["blockTimestamp"]
    ):
        raise AgentsError("production evaluator/orchestrator binding drifted")

    evaluation_pin = _state_pin(rpc, "evaluating", submission) if submission["id"] == "A-T2" else None
    active_probe = None
    if probe_active:
        before = s1._account_commitments(rpc, [a["arbitration"]])
        failed = session.send(
            "negative:active-evaluation",
            NON_AGENT_ACTORS["keeper"],
            a["arbitration"],
            s1._calldata("startNextEvaluation()"),
            expected_status=0,
        )
        trace = s1._failed_transaction_trace(rpc, failed["record"]["hash"])
        after = s1._account_commitments(rpc, [a["arbitration"]])
        if trace["returnValue"] != INVALID_STATE or failed["receipt"]["logs"] or before != after:
            raise AgentsError("active-evaluation InvalidState probe was not exact and atomic")
        active_probe = {"after": after, "before": before, "trace": trace}

    return {
        "activeProbe": active_probe,
        "anchorTimestamp": binding["anchorTimestamp"],
        "binding": binding,
        "conditionId": condition,
        "evaluationPin": evaluation_pin,
        "officialPoolsBeforeSync": pools,
        "payloadKeccak256": documents.keccak256(payload),
        "proposal": proposal,
        "proposalId": str(proposal_id),
        "questionId": question,
        "spotAnchor": spot_anchor,
        "wrappers": {
            "noCompany": no_company,
            "noCurrency": no_currency,
            "yesCompany": yes_company,
            "yesCurrency": yes_currency,
        },
        "wrapperData": {"yesCurrency": wrappers[2][1], "noCurrency": wrappers[3][1]},
    }


def _migrate_and_trade(
    rpc: LatestRpc,
    session: s1.Session,
    stack: dict[str, Any],
    market: dict[str, Any],
    submission_id: str,
    accepted: bool,
    terminal_price: int,
    executor_shares: int,
) -> dict[str, Any]:
    a = stack["addresses"]
    manager = a["manager"]
    company = a["companyToken"]
    proposal_id = int(market["proposalId"])
    wrappers = market["wrappers"]
    entry_before = {
        label: s1._balance(rpc, wrapper, manager) for label, wrapper in wrappers.items()
    }
    if any(entry_before.values()):
        raise AgentsError("manager had current-condition inventory before migration")
    spot_before = s1._uint(rpc, manager, "spotLiquidity()")
    spot_nft = s1._position_id(rpc, a["spotAdapter"], company, s1.WETH)
    spot_position_before = s1._npm_position(rpc, spot_nft)
    preview = s1._uint(rpc, manager, "previewLiquidityMigration()")
    migrated = session.send(
        "flm:sync-to-conditional:" + submission_id,
        NON_AGENT_ACTORS["keeper"],
        manager,
        s1._calldata("sync()"),
    )
    spot_after = s1._uint(rpc, manager, "spotLiquidity()")
    yes_nft = s1._position_id(
        rpc, a["conditionalAdapter"], wrappers["yesCompany"], wrappers["yesCurrency"]
    )
    no_nft = s1._position_id(
        rpc, a["conditionalAdapter"], wrappers["noCompany"], wrappers["noCurrency"]
    )
    liquidities = {
        "yes": s1._uint(rpc, manager, "conditionalYesLiquidity()"),
        "no": s1._uint(rpc, manager, "conditionalNoLiquidity()"),
    }
    migration_event = s1._migration_event(
        migrated["receipt"],
        manager,
        "LiquidityMigratedToConditional(uint256,uint128,uint256)",
        proposal_id,
    )
    spot_decrease = s1._npm_liquidity_change(
        migrated["receipt"], "DecreaseLiquidity(uint256,uint128,uint256,uint256)", spot_nft
    )
    spot_position_after = s1._npm_position(rpc, spot_nft)
    positions = {"yes": s1._npm_position(rpc, yes_nft), "no": s1._npm_position(rpc, no_nft)}
    increases = {
        label: s1._npm_liquidity_change(
            migrated["receipt"],
            "IncreaseLiquidity(uint256,uint128,uint256,uint256)",
            token_id,
        )
        for label, token_id in (("yes", yes_nft), ("no", no_nft))
    }
    if (
        preview != spot_before * 8_000 // 10_000
        or spot_after != spot_before - preview
        or spot_position_before["owner"] != a["spotAdapter"]
        or spot_position_before["liquidity"] != spot_before
        or spot_position_after["owner"] != a["spotAdapter"]
        or spot_position_after["liquidity"] != spot_after
        or spot_decrease["liquidity"] != preview
        or migration_event != {"first": preview, "second": sum(liquidities.values())}
        or not s1._bool(rpc, manager, "inConditionalMode()")
        or s1._uint(rpc, manager, "activeProposalId()") != proposal_id
        or s1._address(rpc, manager, "activeProposal()") != market["proposal"]
        or s1._address(rpc, manager, "activeYesCompanyToken()") != wrappers["yesCompany"]
        or s1._address(rpc, manager, "activeNoCompanyToken()") != wrappers["noCompany"]
        or s1._address(rpc, manager, "activeYesCurrencyToken()") != wrappers["yesCurrency"]
        or s1._address(rpc, manager, "activeNoCurrencyToken()") != wrappers["noCurrency"]
        or min(liquidities.values()) <= 0
        or s1._balance(rpc, manager, stack["executor"]) != executor_shares
    ):
        raise AgentsError("permissionless 80% hero FLM migration failed")

    entry_usage = {}
    for label, pool, company_wrapper, currency_wrapper in (
        (
            "yes",
            market["binding"]["yesPool"],
            wrappers["yesCompany"],
            wrappers["yesCurrency"],
        ),
        (
            "no",
            market["binding"]["noPool"],
            wrappers["noCompany"],
            wrappers["noCurrency"],
        ),
    ):
        position = positions[label]
        increase = increases[label]
        used = s1._pair_amounts(
            position["token0"],
            position["token1"],
            increase["amount0"],
            increase["amount1"],
            {label + "Company": company_wrapper, label + "Currency": currency_wrapper},
        )
        if (
            position["owner"] != a["conditionalAdapter"]
            or position["fee"] != s1.FEE
            or position["liquidity"] != liquidities[label]
            or increase["liquidity"] != liquidities[label]
            or position["tickLower"] != -887_270
            or position["tickUpper"] != 887_270
        ):
            raise AgentsError("conditional NPM custody/liquidity drifted")
        for suffix, wrapper in (("Company", company_wrapper), ("Currency", currency_wrapper)):
            asset_label = label + suffix
            leftover = s1._balance(rpc, wrapper, manager)
            if (
                s1._balance(rpc, wrapper, pool) != used[asset_label]
                or s1._uint(rpc, wrapper, "totalSupply()") != used[asset_label] + leftover
            ):
                raise AgentsError("conditional entry asset attribution drifted")
            entry_usage[asset_label] = s1._usage_evidence(
                "conditional entry " + asset_label, used[asset_label], leftover
            )

    trade_amount = 24 * WAD // 10_000
    trader = NON_AGENT_ACTORS["trader"]
    s1._deposit_weth(session, trader, trade_amount, "trade:%s:wrap" % submission_id)
    s1._approve(
        session, trader, s1.WETH, s1.CTF, trade_amount, "trade:%s:ctf-approve" % submission_id
    )
    session.send(
        "trade:%s:split-currency" % submission_id,
        trader,
        s1.CTF,
        s1._calldata(
            "splitPosition(address,bytes32,bytes32,uint256[],uint256)",
            s1.WETH,
            ZERO32,
            market["conditionId"],
            "[1,2]",
            trade_amount,
        ),
    )
    currency_ids = {
        "yes": s1._collection_token_id(rpc, s1.WETH, market["conditionId"], 1),
        "no": s1._collection_token_id(rpc, s1.WETH, market["conditionId"], 2),
    }
    for label in ("yes", "no"):
        wrapper = wrappers[label + "Currency"]
        session.send(
            "trade:%s:wrap-%s" % (submission_id, label),
            trader,
            s1.CTF,
            s1._calldata(
                "safeTransferFrom(address,address,uint256,uint256,bytes)",
                trader,
                s1.W1155,
                currency_ids[label],
                trade_amount,
                "0x" + market["wrapperData"][label + "Currency"].hex(),
            ),
        )
        if s1._balance(rpc, wrapper, trader) != trade_amount:
            raise AgentsError("conditional currency wrapper mint drifted")

    winner = "yes" if accepted else "no"
    loser = "no" if accepted else "yes"
    winning_pool = market["binding"][winner + "Pool"]
    winning_company = wrappers[winner + "Company"]
    winning_currency = wrappers[winner + "Currency"]
    winner_before = s1._economic_tick(rpc, winning_pool, winning_company)
    loser_tick = s1._economic_tick(
        rpc, market["binding"][loser + "Pool"], wrappers[loser + "Company"]
    )
    trade = s1._swap(
        session,
        "trade:%s:bounded-%s" % (submission_id, winner),
        trader,
        winning_currency,
        winning_company,
        trade_amount,
        trade_amount * WAD * 95 // terminal_price // 100,
        s1._price_limit(rpc, winning_pool, winning_company, 50),
    )
    winner_after = s1._economic_tick(rpc, winning_pool, winning_company)
    if not 25 <= winner_after - winner_before <= 50 or winner_after <= loser_tick:
        raise AgentsError("bounded %s trade did not create a strict verdict" % winner.upper())

    return {
        "currencyPositionIds": {key: str(value) for key, value in currency_ids.items()},
        "entryAssetUse": entry_usage,
        "entryManagerEvent": migration_event,
        "liquidity": {key: str(value) for key, value in liquidities.items()},
        "npmIds": {"yes": yes_nft, "no": no_nft, "spot": spot_nft},
        "positions": positions,
        "spotAfter": str(spot_after),
        "spotBefore": str(spot_before),
        "trade": {
            **trade,
            "amount": str(trade_amount),
            "loserTick": loser_tick,
            "winner": winner,
            "winnerTickAfter": winner_after,
            "winnerTickBefore": winner_before,
        },
    }


def _tap_event(receipt: dict[str, Any], vault: str) -> dict[str, int | str]:
    event = s1._event(receipt, "TapSpent(address,uint256,uint256,uint256,uint256)", vault)
    if len(event["topics"]) != 2:
        raise AgentsError("TapSpent indexing drifted")
    words = s1._words(event["data"], 4)
    return {
        "amount": s1._uint_word(words[0]),
        "asset": s1._address_word(bytes.fromhex(event["topics"][1][2:])),
        "budget": s1._uint_word(words[2]),
        "spent": s1._uint_word(words[1]),
        "windowStart": s1._uint_word(words[3]),
    }


def _execution_event(receipt: dict[str, Any], vault: str) -> dict[str, int | str]:
    event = s1._event(
        receipt, "TreasuryTransferExecuted(bytes32,address,address,uint256)", vault
    )
    if len(event["topics"]) != 4:
        raise AgentsError("TreasuryTransferExecuted indexing drifted")
    return {
        "actionHash": event["topics"][1].lower(),
        "amount": s1._uint_word(s1._words(event["data"], 1)[0]),
        "asset": s1._address_word(bytes.fromhex(event["topics"][2][2:])),
        "recipient": s1._address_word(bytes.fromhex(event["topics"][3][2:])),
    }


def _resolve_restore_and_route(
    rpc: LatestRpc,
    session: s1.Session,
    stack: dict[str, Any],
    submission: dict[str, Any],
    market: dict[str, Any],
    migration: dict[str, Any],
    *,
    accepted: bool,
    executor_shares: int,
) -> dict[str, Any]:
    a = stack["addresses"]
    manager, company = a["manager"], a["companyToken"]
    proposal_id = int(submission["proposalId"])
    timeout = s1._uint(rpc, a["resolver"], "TIMEOUT()")
    twap_window = s1._uint(rpc, a["resolver"], "TWAP_WINDOW()")
    if timeout != 7 * 24 * 60 * 60 or twap_window != 24 * 60 * 60:
        raise AgentsError("production resolver timeout/window drifted")
    _clock_checkpoint(session, submission["id"] + ":pre-6d")
    session.mine_at(market["anchorTimestamp"] + 6 * 24 * 60 * 60)
    _clock_checkpoint(session, submission["id"] + ":post-6d")
    if s1._bool(rpc, a["resolver"], "isReadyToResolve(address)", market["proposal"]):
        raise AgentsError("resolver became ready before the last-day TWAP window")
    window_end = market["anchorTimestamp"] + timeout
    session.mine_at(window_end)
    _clock_checkpoint(session, submission["id"] + ":window-end")
    if not s1._bool(rpc, a["resolver"], "isReadyToResolve(address)", market["proposal"]):
        raise AgentsError("resolver was not ready at its exact window end")
    resolved = session.send(
        "evaluation:resolve:" + submission["id"],
        NON_AGENT_ACTORS["keeper"],
        a["evaluator"],
        s1._calldata("resolve(uint256)", proposal_id),
    )
    _clock_checkpoint(session, submission["id"] + ":resolved")
    end_ago = resolved["record"]["blockTimestamp"] - window_end
    start_ago = end_ago + twap_window
    yes_average = s1._mean_tick(
        rpc,
        market["binding"]["yesPool"],
        market["wrappers"]["yesCompany"],
        start_ago,
        end_ago,
        twap_window,
    )
    no_average = s1._mean_tick(
        rpc,
        market["binding"]["noPool"],
        market["wrappers"]["noCompany"],
        start_ago,
        end_ago,
        twap_window,
    )
    payout = {
        "yes": s1._uint(rpc, s1.CTF, "payoutNumerators(bytes32,uint256)", market["conditionId"], 0),
        "no": s1._uint(rpc, s1.CTF, "payoutNumerators(bytes32,uint256)", market["conditionId"], 1),
        "denominator": s1._uint(rpc, s1.CTF, "payoutDenominator(bytes32)", market["conditionId"]),
    }
    arbitration_words = s1._words(
        s1._call(rpc, a["arbitration"], "getProposal(uint256)", proposal_id), 11
    )
    resolved_binding = s1._binding(rpc, a["resolver"], market["proposal"])
    expected_payout = {"yes": 1 if accepted else 0, "no": 0 if accepted else 1, "denominator": 1}
    if (
        payout != expected_payout
        or s1._bool(rpc, a["arbitration"], "isAccepted(uint256)", proposal_id) != accepted
        or not s1._bool(rpc, a["arbitration"], "isSettled(uint256)", proposal_id)
        or s1._uint(rpc, a["arbitration"], "activeEvaluationProposalId()") != 0
        or s1._uint_word(arbitration_words[5]) != 5
        or bool(s1._uint_word(arbitration_words[7])) is not True
        or bool(s1._uint_word(arbitration_words[8])) != accepted
        or not resolved_binding["resolved"]
        or resolved_binding["accepted"] != accepted
        or not (yes_average > no_average if accepted else no_average > yes_average)
    ):
        raise AgentsError("7-day production TWAP verdict drifted")
    runner_resolution = _state(rpc, submission)
    if (
        runner_resolution.get("acceptanceRoute") != "evaluated"
        or runner_resolution.get("accepted") is not accepted
    ):
        raise AgentsError("runner did not derive the evaluated acceptance route")

    route = None
    queued = None
    negative = None
    state_pins = []
    if submission["id"] == "A-T2":
        state_pins.append(_state_pin(rpc, "evaluated", submission))
    if accepted:
        queued_tick = _tick(rpc, session, submission, "queue")
        queued = _state(rpc, submission)["queued"]
        if not queued["executeAfter"] or queued_tick["landed"]["record"]["status"] != 1:
            raise AgentsError("evaluated payment did not queue promptly")
        if submission["id"] == "A-T2":
            state_pins.append(_state_pin(rpc, "queued", submission))
        route = "evaluated"
    else:
        recipient = submission["payment"]["recipient"]
        recipient_before = s1._balance(rpc, s1.WETH, recipient)
        before = s1._account_commitments(rpc, [a["vault"]])
        action = "(%s,%s,%s,%s)" % (
            submission["action"]["asset"],
            submission["action"]["recipient"],
            submission["action"]["amount"],
            submission["action"]["salt"],
        )
        failed = session.send(
            "negative:queue-rejected:" + submission["id"],
            NON_AGENT_ACTORS["keeper"],
            a["vault"],
            s1._calldata("queueTreasuryTransfer((address,address,uint256,bytes32))", action),
            expected_status=0,
        )
        trace = s1._failed_transaction_trace(rpc, failed["record"]["hash"])
        after = s1._account_commitments(rpc, [a["vault"]])
        recipient_after = s1._balance(rpc, s1.WETH, recipient)
        if (
            trace["returnValue"] != ARBITRATION_NOT_ACCEPTED
            or failed["receipt"]["logs"]
            or before != after
            or recipient_before != 0
            or recipient_after != 0
        ):
            raise AgentsError("rejected queue probe was not exact and atomic")
        negative = {
            "after": after,
            "before": before,
            "recipient": recipient,
            "recipientAfter": str(recipient_after),
            "recipientBefore": str(recipient_before),
            "trace": trace,
        }
        route = "evaluated-rejected"

    wrappers = market["wrappers"]
    winner = "yes" if accepted else "no"
    loser = "no" if accepted else "yes"
    base_before = {
        "company": s1._balance(rpc, company, manager),
        "currency": s1._balance(rpc, s1.WETH, manager),
    }
    shares_before = {
        "executor": s1._balance(rpc, manager, stack["executor"]),
        "totalSupply": s1._uint(rpc, manager, "totalSupply()"),
    }
    _clock_checkpoint(session, submission["id"] + ":pre-restore")
    session.mine_at(session.clock + 30 * 60)
    restored = session.send(
        "flm:sync-back-to-spot:" + submission["id"],
        NON_AGENT_ACTORS["keeper"],
        manager,
        s1._calldata("sync()"),
    )
    _clock_checkpoint(session, submission["id"] + ":restored")
    spot_nft = migration["npmIds"]["spot"]
    yes_nft = migration["npmIds"]["yes"]
    no_nft = migration["npmIds"]["no"]
    restored_spot_liquidity = s1._uint(rpc, manager, "spotLiquidity()")
    restored_spot_position = s1._npm_position(rpc, spot_nft)
    spot_increase = s1._npm_liquidity_change(
        restored["receipt"], "IncreaseLiquidity(uint256,uint128,uint256,uint256)", spot_nft
    )
    return_event = s1._migration_event(
        restored["receipt"],
        manager,
        "LiquidityMigratedBackToSpot(uint256,uint256,uint128)",
        proposal_id,
    )
    decreases = {
        label: s1._npm_liquidity_change(
            restored["receipt"],
            "DecreaseLiquidity(uint256,uint128,uint256,uint256)",
            token_id,
        )
        for label, token_id in (("yes", yes_nft), ("no", no_nft))
    }
    collects = {
        label: s1._npm_collect(restored["receipt"], token_id, manager)
        for label, token_id in (("yes", yes_nft), ("no", no_nft))
    }
    base_after = {
        "company": s1._balance(rpc, company, manager),
        "currency": s1._balance(rpc, s1.WETH, manager),
    }
    return_used = s1._pair_amounts(
        restored_spot_position["token0"],
        restored_spot_position["token1"],
        spot_increase["amount0"],
        spot_increase["amount1"],
        {"company": company, "currency": s1.WETH},
    )
    winning_position = migration["positions"][winner]
    winning_recovered = s1._pair_amounts(
        winning_position["token0"],
        winning_position["token1"],
        collects[winner]["amount0"],
        collects[winner]["amount1"],
        {"company": wrappers[winner + "Company"], "currency": wrappers[winner + "Currency"]},
    )
    idle_recovery = {
        "company": int(migration["entryAssetUse"][winner + "Company"]["unused"]),
        "currency": int(migration["entryAssetUse"][winner + "Currency"]["unused"]),
    }
    return_usage = {
        label: s1._usage_evidence(
            "spot return " + label,
            return_used[label],
            winning_recovered[label] - return_used[label],
        )
        for label in ("company", "currency")
    }
    base_delta = {label: base_after[label] - base_before[label] for label in base_before}
    liquidities = {label: int(value) for label, value in migration["liquidity"].items()}
    if (
        s1._bool(rpc, manager, "inConditionalMode()")
        or s1._uint(rpc, manager, "activeProposalId()") != 0
        or s1._address(rpc, manager, "activeProposal()") != ZERO_ADDRESS
        or s1._position_id(rpc, a["conditionalAdapter"], wrappers["yesCompany"], wrappers["yesCurrency"]) != 0
        or s1._position_id(rpc, a["conditionalAdapter"], wrappers["noCompany"], wrappers["noCurrency"]) != 0
        or s1._uint(rpc, market["binding"]["yesPool"], "liquidity()") != 0
        or s1._uint(rpc, market["binding"]["noPool"], "liquidity()") != 0
        or s1._uint(rpc, manager, "conditionalYesLiquidity()") != 0
        or s1._uint(rpc, manager, "conditionalNoLiquidity()") != 0
        or restored_spot_liquidity == 0
        or s1._position_id(rpc, a["spotAdapter"], company, s1.WETH) != spot_nft
        or restored_spot_position["owner"] != a["spotAdapter"]
        or restored_spot_position["liquidity"] != restored_spot_liquidity
        or restored_spot_position["fee"] != s1.FEE
        or restored_spot_position["tickLower"] != -887_270
        or restored_spot_position["tickUpper"] != 887_270
        or restored_spot_liquidity != int(migration["spotAfter"]) + spot_increase["liquidity"]
        or return_event != {"first": sum(liquidities.values()), "second": spot_increase["liquidity"]}
        or decreases["yes"]["liquidity"] != liquidities["yes"]
        or decreases["no"]["liquidity"] != liquidities["no"]
        or any(
            base_delta[label] != int(return_usage[label]["unused"]) + idle_recovery[label]
            for label in ("company", "currency")
        )
        or shares_before["totalSupply"] != s1._uint(rpc, manager, "totalSupply()")
        or shares_before["totalSupply"] != executor_shares
        or shares_before["executor"] != executor_shares
        or s1._balance(rpc, manager, stack["executor"]) != executor_shares
    ):
        raise AgentsError("serial settled liquidity did not restore exactly to spot")

    burned = {"yes": s1._burned_npm_position(rpc, yes_nft), "no": s1._burned_npm_position(rpc, no_nft)}
    residue_accounts = (a["router"], a["conditionalAdapter"])
    company_ids = {
        "yes": s1._collection_token_id(rpc, company, market["conditionId"], 1),
        "no": s1._collection_token_id(rpc, company, market["conditionId"], 2),
    }
    currency_ids = {key: int(value) for key, value in migration["currencyPositionIds"].items()}
    underlying_residue = {
        account: {
            str(token_id): str(s1._uint(rpc, s1.CTF, "balanceOf(address,uint256)", account, token_id))
            for token_id in (*company_ids.values(), *currency_ids.values())
        }
        for account in residue_accounts
    }
    for account in residue_accounts:
        if any(s1._balance(rpc, token, account) for token in (company, s1.WETH, *wrappers.values())):
            raise AgentsError("router/adapter base or wrapper residue remained")
    if any(int(value) for balances in underlying_residue.values() for value in balances.values()):
        raise AgentsError("router/adapter underlying CTF residue remained")
    manager_outcomes = {
        label: s1._balance(rpc, wrapper, manager) for label, wrapper in wrappers.items()
    }
    collected_company = {
        label: s1._pair_amounts(
            migration["positions"][label]["token0"],
            migration["positions"][label]["token1"],
            collects[label]["amount0"],
            collects[label]["amount1"],
            {
                "company": wrappers[label + "Company"],
                "currency": wrappers[label + "Currency"],
            },
        )["company"]
        for label in ("yes", "no")
    }
    attributable_company = {
        label: collected_company[label]
        + int(migration["entryAssetUse"][label + "Company"]["unused"])
        for label in ("yes", "no")
    }
    expected_losing = attributable_company[loser] - attributable_company[winner]
    rounding_vs_trade = expected_losing - migration["trade"]["amountOut"]
    if expected_losing <= 0 or abs(rounding_vs_trade) > 1:
        raise AgentsError("winning trade did not create positive losing-company residue")
    if (
        manager_outcomes[loser + "Company"] != expected_losing
        or any(
            amount
            for label, amount in manager_outcomes.items()
            if label != loser + "Company"
        )
    ):
        raise AgentsError(
            "current-condition losing residue was not exactly attributable: "
            + json.dumps(
                {"expected": str(expected_losing), "loser": loser, "observed": manager_outcomes},
                sort_keys=True,
                separators=(",", ":"),
            )
        )

    trader = NON_AGENT_ACTORS["trader"]
    trader_wrappers = {
        label: s1._balance(rpc, wrapper, trader) for label, wrapper in wrappers.items()
    }
    trader_underlying = {
        str(token_id): s1._uint(rpc, s1.CTF, "balanceOf(address,uint256)", trader, token_id)
        for token_id in (*company_ids.values(), *currency_ids.values())
    }
    if (
        trader_wrappers[winner + "Company"] != migration["trade"]["amountOut"]
        or trader_wrappers[winner + "Currency"]
        != int(migration["trade"]["amount"]) - migration["trade"]["amountInActual"]
        or trader_wrappers[loser + "Currency"] != int(migration["trade"]["amount"])
        or trader_wrappers[loser + "Company"] != 0
        or any(trader_underlying.values())
    ):
        raise AgentsError("trader current-condition inventory was not exactly attributable")

    payment = None
    if accepted:
        _clock_checkpoint(session, submission["id"] + ":pre-payment")
        execute_after = int(queued["executeAfter"])
        if session.clock < execute_after:
            session.mine_at(execute_after)
        before_executor = s1._balance(rpc, s1.WETH, stack["executor"])
        recipient = submission["payment"]["recipient"]
        before_recipient = s1._balance(rpc, s1.WETH, recipient)
        executed = _tick(rpc, session, submission, "execute")
        amount = int(submission["payment"]["amount"])
        after_executor = s1._balance(rpc, s1.WETH, stack["executor"])
        after_recipient = s1._balance(rpc, s1.WETH, recipient)
        tap_topic = documents.keccak256(b"TapSpent(address,uint256,uint256,uint256,uint256)")
        tap_logs = [
            log
            for log in executed["landed"]["receipt"]["logs"]
            if log.get("topics", [None])[0].lower() == tap_topic
        ]
        execution_event = _execution_event(executed["landed"]["receipt"], a["vault"])
        if (
            tap_logs
            or execution_event
            != {
                "actionHash": "0x" + proposal_id.to_bytes(32, "big").hex(),
                "amount": amount,
                "asset": s1.WETH,
                "recipient": recipient,
            }
            or before_executor - after_executor != amount
            or after_recipient - before_recipient != amount
            or _state(rpc, submission)["lifecycle"] != "PAID"
        ):
            raise AgentsError("evaluated payment was not exact and tap-exempt")
        payment = {
            "amount": str(amount),
            "executorAfter": str(after_executor),
            "executorBefore": str(before_executor),
            "recipientAfter": str(after_recipient),
            "recipientBefore": str(before_recipient),
            "transferEvent": {
                key: str(value) if isinstance(value, int) else value
                for key, value in execution_event.items()
            },
            "tapSpentLogs": 0,
            "transactionHash": executed["landed"]["record"]["hash"],
        }
        if submission["id"] == "A-T2":
            state_pins.append(_state_pin(rpc, "paid", submission))

    return {
        "accepted": accepted,
        "burnedNpmPositions": burned,
        "managerCurrentConditionOutcomes": {key: str(value) for key, value in manager_outcomes.items()},
        "managerLosingResidue": {
            "amount": str(expected_losing),
            "attributableCompanyBeforeRecovery": {
                key: str(value) for key, value in attributable_company.items()
            },
            "outcome": loser.upper(),
            "roundingVsTraderOutput": str(rounding_vs_trade),
            "token": wrappers[loser + "Company"],
        },
        "negativeQueue": negative,
        "payment": payment,
        "payout": {key: str(value) for key, value in payout.items()},
        "proposalId": str(proposal_id),
        "resolvedAt": resolved["record"]["blockTimestamp"],
        "restore": {
            "baseDelta": {key: str(value) for key, value in base_delta.items()},
            "entryIdleRecovery": {key: str(value) for key, value in idle_recovery.items()},
            "returnAssetUse": return_usage,
            "restoredAt": restored["record"]["blockTimestamp"],
            "spotLiquidity": str(restored_spot_liquidity),
            "spotPosition": restored_spot_position,
            "traderUnderlying": {key: str(value) for key, value in trader_underlying.items()},
            "traderWrappers": {key: str(value) for key, value in trader_wrappers.items()},
            "underlyingResidue": underlying_residue,
        },
        "route": route,
        "runnerAcceptanceRoute": runner_resolution["acceptanceRoute"],
        "statePins": state_pins,
        "twap": {
            "endAgo": end_ago,
            "noMeanTick": no_average,
            "startAgo": start_ago,
            "timeout": timeout,
            "window": twap_window,
            "windowEnd": window_end,
            "yesMeanTick": yes_average,
        },
    }


def _timeout_segment(
    rpc: LatestRpc,
    session: s1.Session,
    stack: dict[str, Any],
    by_id: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    a = stack["addresses"]
    timeout = s1._uint(rpc, a["arbitration"], "timeout()")
    if timeout != 3 * 24 * 60 * 60:
        raise AgentsError("hero arbitration timeout drifted")
    states = {submission_id: _state(rpc, by_id[submission_id]) for submission_id in tournament.TIMEOUT_IDS}
    settle_at = max(int(state["proposal"]["lastStateChangeAt"]) + timeout for state in states.values())
    _clock_checkpoint(session, "timeout-settlement-pre-mine")
    session.mine_at(settle_at)
    _clock_checkpoint(session, "timeout-settlement-boundary")
    for submission_id in tournament.TIMEOUT_IDS:
        _tick(rpc, session, by_id[submission_id], "finalize-timeout")
        state = _state(rpc, by_id[submission_id])
        if not state["accepted"] or state["acceptanceRoute"] != "timeout":
            raise AgentsError("timeout route did not accept " + submission_id)
        _tick(rpc, session, by_id[submission_id], "queue")
    queued = {submission_id: _state(rpc, by_id[submission_id])["queued"] for submission_id in tournament.TIMEOUT_IDS}
    execute_at = max(int(item["executeAfter"]) for item in queued.values())
    _clock_checkpoint(session, "timeout-execution-pre-mine")
    session.mine_at(execute_at)

    expected_spent = 0
    window_start = None
    payments = {}
    for submission_id in tournament.TIMEOUT_IDS:
        submission = by_id[submission_id]
        amount = int(submission["payment"]["amount"])
        recipient = submission["payment"]["recipient"]
        executor_before = s1._balance(rpc, s1.WETH, stack["executor"])
        recipient_before = s1._balance(rpc, s1.WETH, recipient)
        executed = _tick(rpc, session, submission, "execute")
        if submission_id == tournament.TIMEOUT_IDS[0]:
            _clock_checkpoint(session, "timeout-first-execution")
        tap = _tap_event(executed["landed"]["receipt"], a["vault"])
        execution_event = _execution_event(executed["landed"]["receipt"], a["vault"])
        expected_spent += amount
        if window_start is None:
            window_start = int(tap["windowStart"])
        executor_after = s1._balance(rpc, s1.WETH, stack["executor"])
        recipient_after = s1._balance(rpc, s1.WETH, recipient)
        if (
            tap != {
                "amount": amount,
                "asset": s1.WETH,
                "budget": 2 * WAD // 10,
                "spent": expected_spent,
                "windowStart": window_start,
            }
            or execution_event
            != {
                "actionHash": "0x" + int(submission["proposalId"]).to_bytes(32, "big").hex(),
                "amount": amount,
                "asset": s1.WETH,
                "recipient": recipient,
            }
            or executor_before - executor_after != amount
            or recipient_after - recipient_before != amount
            or _state(rpc, submission)["lifecycle"] != "PAID"
        ):
            raise AgentsError("timeout payment/tap reconciliation drifted for " + submission_id)
        payments[submission_id] = {
            "amount": str(amount),
            "executorAfter": str(executor_after),
            "executorBefore": str(executor_before),
            "recipient": recipient,
            "recipientAfter": str(recipient_after),
            "recipientBefore": str(recipient_before),
            "tap": {key: str(value) if isinstance(value, int) else value for key, value in tap.items()},
            "transferEvent": {
                key: str(value) if isinstance(value, int) else value
                for key, value in execution_event.items()
            },
            "transactionHash": executed["landed"]["record"]["hash"],
        }
    tap_words = s1._words(s1._call(rpc, a["vault"], "tapStates(address)", s1.WETH), 2)
    tap_state = {"windowStart": s1._uint_word(tap_words[0]), "spent": s1._uint_word(tap_words[1])}
    if tap_state != {"windowStart": window_start, "spent": 10 * 10**15}:
        raise AgentsError("timeout tap state did not end at 0.010 WETH")
    return {
        "budget": str(2 * WAD // 10),
        "compositionBoundary": {
            "availableAfterLaterTransferSegment": str(40 * 10**15),
            "executedInS3": False,
            "laterTransferSegment": str(150 * 10**15),
            "stage": "S6",
        },
        "payments": payments,
        "remaining": str(190 * 10**15),
        "settledAtOrAfter": settle_at,
        "spent": str(tap_state["spent"]),
        "windowStart": tap_state["windowStart"],
    }


def _reported_submissions(
    submissions: list[dict[str, Any]], graders: dict[str, dict[str, bool]]
) -> list[dict[str, Any]]:
    result = []
    for submission in submissions:
        submission_id = submission["id"]
        payment = documents.build_payment(submission["payment"])
        receipt = documents.build_receipt(submission["receipt"])
        result.append(
            {
                "acceptanceRoute": tournament.EXPECTED_ROUTES[submission_id],
                "agent": submission["agent"],
                "amount": str(tournament.PAYMENTS[submission_id]),
                "artifactDigest": submission["artifactDigest"],
                "challenge": tournament.EXPECTED_CHALLENGES[submission_id],
                "grader": graders[submission_id],
                "id": submission_id,
                "outcome": "paid" if submission_id in tournament.PAID_IDS else "rejected",
                "payment": "0x" + payment.hex(),
                "paymentDigest": documents.document_digest(payment),
                "proposalId": submission["proposalId"],
                "receipt": "0x" + receipt.hex(),
                "receiptDigest": documents.document_digest(receipt),
                "taskDigest": documents.document_digest(documents.build_task(submission["task"])),
                "taskId": submission["taskId"],
            }
        )
    return result


def _scenario(
    rpc: LatestRpc,
    rpc_url: str,
    deployment: list[dict[str, Any]],
    stack: dict[str, Any],
    artifacts: dict[str, Any],
) -> dict[str, Any]:
    session = s1.Session(rpc)
    _clock_checkpoint(session, "deployment-complete")
    index = _deploy_index(rpc, session, rpc_url)
    _clock_checkpoint(session, "index-deployed")
    hero = _hero_genesis(rpc, session, stack)
    agent_stack = _agent_stack(rpc, stack, index, int(rpc.block("latest")["number"], 16))
    blobs, submissions, graders = _matrix(rpc, agent_stack)
    agent_setup = _prepare_agents(rpc, session, {**stack, "index": index}, submissions, graders)
    by_id = agent_setup.pop("byId")
    timeout = _timeout_segment(rpc, session, stack, by_id)

    cycles = []
    losing_residues: dict[str, dict[str, Any]] = {}
    for cycle_index, submission_id in enumerate(tournament.EVALUATION_IDS):
        accepted = graders[submission_id]["verdict"]
        submission = by_id[submission_id]
        market = _market_start(
            rpc,
            session,
            stack,
            submission,
            probe_active=cycle_index == 0,
        )
        if submission_id == "A-T2":
            agent_setup["restartPins"].append(market.pop("evaluationPin"))
        else:
            market.pop("evaluationPin")
        migration = _migrate_and_trade(
            rpc,
            session,
            stack,
            market,
            submission_id,
            accepted,
            hero["terminalPrice"],
            int(hero["bootstrap"]["executorFlmShares"]),
        )
        result = _resolve_restore_and_route(
            rpc,
            session,
            stack,
            submission,
            market,
            migration,
            accepted=accepted,
            executor_shares=int(hero["bootstrap"]["executorFlmShares"]),
        )
        agent_setup["restartPins"].extend(result.pop("statePins"))
        residue = result["managerLosingResidue"]
        losing_residues[submission_id] = residue
        for old_id, old in losing_residues.items():
            if s1._balance(rpc, old["token"], stack["addresses"]["manager"]) != int(old["amount"]):
                raise AgentsError("serial cycle changed prior losing residue " + old_id)
        cycles.append(
            {
                "market": {
                    key: value
                    for key, value in market.items()
                    if key not in ("wrapperData", "activeProbe")
                },
                "activeEvaluationNegative": market["activeProbe"],
                "migration": migration,
                "result": result,
                "submission": submission_id,
            }
        )

    a = stack["addresses"]
    withdrawable = {
        name: s1._uint(rpc, a["arbitration"], "withdrawable(address)", tournament.ACTOR_ADDRESSES[name])
        for name in CONTRIBUTIONS
    }
    escrow = s1._balance(rpc, s1.WETH, a["arbitration"])
    if withdrawable != EXPECTED_WITHDRAWABLE or escrow != 718 * WAD or sum(withdrawable.values()) != escrow:
        raise AgentsError("hero bond payout/escrow conservation drifted")
    executor_final = s1._balance(rpc, s1.WETH, stack["executor"])
    if executor_final != 1_188 * 10**15:
        raise AgentsError("four agent payments did not leave the executor at 1.188 WETH")
    recipients = {
        "agentA": s1._balance(rpc, s1.WETH, tournament.ACTOR_ADDRESSES["agentA"]),
        "workerA": s1._balance(rpc, s1.WETH, tournament.ACTOR_ADDRESSES["workerA"]),
        "workerB": s1._balance(rpc, s1.WETH, tournament.ACTOR_ADDRESSES["workerB"]),
        "workerC1": s1._balance(rpc, s1.WETH, tournament.ACTOR_ADDRESSES["workerC1"]),
        "workerC3": s1._balance(rpc, s1.WETH, tournament.ACTOR_ADDRESSES["workerC3"]),
    }
    expected_recipients = {
        "agentA": 1 * 10**15,
        "workerA": 5 * 10**15,
        "workerB": 0,
        "workerC1": 0,
        "workerC3": 6 * 10**15,
    }
    if recipients != expected_recipients:
        raise AgentsError("agent payment recipient ledger drifted")
    tap_words = s1._words(s1._call(rpc, a["vault"], "tapStates(address)", s1.WETH), 2)
    if s1._uint_word(tap_words[1]) != 10 * 10**15:
        raise AgentsError("evaluated cycles changed the timeout tap ledger")
    if [cycle["result"]["route"] for cycle in cycles] != ["evaluated", "evaluated-rejected", "evaluated-rejected"]:
        raise AgentsError("serial evaluation route matrix drifted")

    all_transactions = deployment + session.transactions
    reported = _reported_submissions(submissions, graders)
    quality = {}
    for name in ("agentA", "agentB", "agentC"):
        verdicts = [item["grader"]["verdict"] for item in reported if item["agent"] == name]
        quality[name] = "%d/%d" % (sum(verdicts), len(verdicts))
    if quality != {"agentA": "3/3", "agentB": "0/1", "agentC": "1/2"}:
        raise AgentsError("agent quality matrix drifted")
    transaction_times = [item["blockTimestamp"] for item in all_transactions]
    if any(right <= left for left, right in zip(transaction_times, transaction_times[1:])):
        raise AgentsError("economic transaction timestamps are not strictly monotonic")
    labeled_times = {
        item.get("label"): item["blockTimestamp"]
        for item in all_transactions
        if item.get("label")
    }
    transactions_by_label = {
        item.get("label"): item for item in all_transactions if item.get("label")
    }
    proposal_gas = []
    for submission_id in tournament.ROUND_ROBIN_IDS:
        record = transactions_by_label["runner:propose:" + submission_id]
        receipt = rpc.request("eth_getTransactionReceipt", [record["hash"]])
        if not isinstance(receipt, dict):
            raise AgentsError("proposal receipt disappeared")
        gas_price = int(receipt["effectiveGasPrice"], 16)
        record["effectiveGasPriceWei"] = str(gas_price)
        submission = next(item for item in submissions if item["id"] == submission_id)
        proposal_gas.append(
            {
                "actor": submission["agent"],
                "gasCostWei": str(record["gasUsed"] * gas_price),
                "gasUsed": str(record["gasUsed"]),
                "proposalId": submission["proposalId"],
                "submission": submission_id,
            }
        )
    completion_latency = {}
    for submission in submissions:
        submission_id = submission["id"]
        start = labeled_times["index:task:" + submission["taskId"]]
        end_label = (
            "runner:execute:" + submission_id
            if submission_id in tournament.PAID_IDS
            else "evaluation:resolve:" + submission_id
        )
        completion_latency[submission_id] = str(labeled_times[end_label] - start)
        if int(completion_latency[submission_id]) <= 0:
            raise AgentsError("simulated completion latency was not positive")
    clock_stages = [
        {"stage": "deployment-complete", "timestamp": deployment[-1]["blockTimestamp"]},
        {"stage": "index-deployed", "timestamp": labeled_times["index:deploy"]},
        {"stage": "sale-sealed", "timestamp": labeled_times["sale:seal"]},
        {"stage": "timeout-settlement-boundary", "timestamp": timeout["settledAtOrAfter"]},
        {"stage": "timeout-first-execution", "timestamp": timeout["windowStart"]},
    ]
    for cycle in cycles:
        prefix = cycle["submission"]
        clock_stages.extend(
            (
                {"stage": prefix + ":anchor", "timestamp": cycle["market"]["anchorTimestamp"]},
                {"stage": prefix + ":window-end", "timestamp": cycle["result"]["twap"]["windowEnd"]},
                {"stage": prefix + ":resolved", "timestamp": cycle["result"]["resolvedAt"]},
                {"stage": prefix + ":restored", "timestamp": cycle["result"]["restore"]["restoredAt"]},
            )
        )
    if clock_stages != _absolute_clock_stages():
        raise AgentsError("named S3 clock stages drifted from the precomputed absolute ledger")
    return {
        "actorPreconditions": {
            name: {
                "address": address,
                "code": "0x",
                "nativeBalance": "0",
                "nonce": "0",
                "provenance": "house-wallet",
            }
            for name, address in ACTORS.items()
        },
        "agentStack": agent_stack,
        "anvilStateMutations": [
            {
                "after": str(2_000 * WAD),
                "before": "0",
                "kind": "native-balance",
                "purpose": "fund disposable Anvil gas and canonical WETH deposits",
                "target": address,
            }
            for address in ACTORS.values()
        ]
        + [
            {
                "after": True,
                "before": False,
                "kind": "impersonation-mode",
                "purpose": "unlock fixed zero-nonce house actors without stored keys",
                "target": "anvil --auto-impersonate",
            }
        ],
        "artifactBlobs": {
            documents.document_digest(blob): "0x" + blob.hex() for blob in blobs.values()
        },
        "artifacts": artifacts,
        "bondLedger": {
            "contributions": {key: str(value) for key, value in CONTRIBUTIONS.items()},
            "escrow": str(escrow),
            "withdrawable": {key: str(value) for key, value in withdrawable.items()},
        },
        "chainId": s1.CHAIN_ID,
        "claims": {
            "externalWork": False,
            "demand": False,
            "liveDeployment": False,
            "livePayment": False,
            "shortfallOnHero": False,
            "wholeConditionClosure": False,
        },
        "clock": {"discipline": "absolute-precomputed", "stages": clock_stages},
        "continuity": {
            "s1EvidenceSha256": "0x" + hashlib.sha256(S1_EVIDENCE_PATH.read_bytes()).hexdigest(),
            "stackAndBootstrapExact": True,
        },
        "cycles": cycles,
        "fork": {
            "blockHash": s1.FORK_BLOCK_HASH,
            "blockNumber": s1.FORK_BLOCK,
            "selectedFromHead": s1.FORK_SELECTED_FROM_HEAD,
            "selectionRule": "finalized-head-minus-64-rounded-down-1000",
            "timestamp": s1.FORK_TIMESTAMP,
        },
        "graderPolicy": {
            "heroResolution": {
                "authority": "receipt-bound-production-market-pipeline",
                "houseTradeTarget": "objectiveCorrect AND original",
                "resolverInput": "strict 7-day/1-day TWAP inequality",
            },
            "sealedP2aArtifactPolicyReference": tournament.GRADER_POLICY,
        },
        "hero": hero,
        "index": {
            "address": index,
            "authority": "none",
            "runtimeHash": s1._runtime_hash(rpc, index),
        },
        "inputs": {
            "driverSha256": "0x" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "scriptSha256": "0x" + hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
            "tournamentModuleSha256": "0x"
            + hashlib.sha256((ROOT / "tools/agent_tournament.py").read_bytes()).hexdigest(),
            "p2aProposalBindingsSha256": _p2a_proposal_bindings_sha256(),
        },
        "matrix": {
            **agent_setup,
            "metrics": {
                "artifactQuality": quality,
                "challengeRate": "3/6",
                "falsePaymentRate": "0/4",
                "proposalGas": proposal_gas,
                "simulatedChainCompletionLatencySeconds": completion_latency,
                "totalTreasurySpend": str(12 * 10**15),
            },
            "submissions": reported,
        },
        "publicBroadcasts": 0,
        "resources": {
            "blocks": all_transactions[-1]["blockNumber"] - all_transactions[0]["blockNumber"] + 1,
            "failedTransactions": sum(item.get("status") == 0 for item in all_transactions),
            "gasUsed": sum(item["gasUsed"] for item in all_transactions),
            "transactions": len(all_transactions),
        },
        "shortfallDrill": {
            "status": "not-replayed-in-s3",
            "coverage": [
                "metadata/agent-work-p2a-evidence.json:drills.cT3Shortfall",
                "Rehearsal-R0-S6:critical-drain-S5-shortfall",
            ],
        },
        "stack": stack,
        "tapLedger": timeout,
        "treasury": {
            "executorFinal": str(executor_final),
            "executorInitial": hero["bootstrap"]["executorWeth"],
            "recipients": {key: str(value) for key, value in recipients.items()},
            "spent": str(12 * 10**15),
        },
        "transactions": all_transactions,
    }


def _run_once(
    port: int, fork_url: str, artifacts: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, Any]]:
    rpc_url = s1._loopback("http://127.0.0.1:%d" % port)
    started = time.monotonic()
    process = subprocess.Popen(
        (
            "anvil",
            "--silent",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--fork-url",
            fork_url,
            "--fork-block-number",
            str(s1.FORK_BLOCK),
            "--fork-retry-backoff",
            "1000",
            "--retries",
            "10",
            "--timeout",
            "120000",
            "--auto-impersonate",
            "--gas-limit",
            "60000000",
            "--accounts",
            "1",
            "--balance",
            "0",
        ),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        rpc = LatestRpc(rpc_url)
        for _ in range(200):
            if process.poll() is not None:
                raise AgentsError("fresh Anvil fork exited before accepting RPC")
            try:
                if rpc.chain_id() == s1.CHAIN_ID:
                    break
            except runner.RunnerError:
                time.sleep(0.05)
        else:
            raise AgentsError("fresh Anvil fork did not start")
        pin = rpc.block(s1.FORK_BLOCK)
        if int(rpc.block("latest")["number"], 16) != s1.FORK_BLOCK or pin["hash"].lower() != s1.FORK_BLOCK_HASH:
            raise AgentsError("Anvil fork is not at the exact S1 pin")
        if len(ACTORS) != len(set(ACTORS.values())) or tournament.ACTOR_ADDRESSES["steward"] != "0x1000000000000000000000000000000000000001":
            raise AgentsError("S3 actor namespaces overlap or deployer identity drifted")
        for name, actor in ACTORS.items():
            nonce = int(rpc.request("eth_getTransactionCount", [actor, "latest"]), 16)
            code = rpc.request("eth_getCode", [actor, "latest"])
            native = int(rpc.request("eth_getBalance", [actor, "latest"]), 16)
            if nonce != 0 or code != "0x" or native != 0:
                raise AgentsError("fixed actor precondition failed: " + name)
            rpc.request("anvil_setBalance", [actor, hex(2_000 * WAD)])
        rpc.request("anvil_setBlockTimestampInterval", [1])
        env = dict(os.environ, REHEARSAL_R0_SENDER=tournament.ACTOR_ADDRESSES["steward"])
        s1._run(
            (
                "forge",
                "script",
                "script/RehearsalR0.s.sol:RehearsalR0",
                "--rpc-url",
                rpc_url,
                "--broadcast",
                "--unlocked",
                "--sender",
                tournament.ACTOR_ADDRESSES["steward"],
                "--slow",
                "--skip-simulation",
                "--non-interactive",
            ),
            env=env,
        )
        deployment_end = int(rpc.block("latest")["number"], 16)
        deployment = s1._block_transactions(rpc, s1.FORK_BLOCK + 1, deployment_end)
        if len(deployment) != 6:
            raise AgentsError("sealed fork deployment transaction count drifted")
        stack = s1._stack(rpc, s1.FORK_BLOCK + 1, deployment_end)
        economic = _scenario(rpc, rpc_url, deployment, stack, artifacts)
        return economic, {
            "port": port,
            "processId": process.pid,
            "providerUrl": fork_url,
            "wallDurationMs": round((time.monotonic() - started) * 1000),
        }
    finally:
        process.terminate()
        process.wait(timeout=5)


def run(port: int, fork_url: str, *, single_run: bool = False) -> dict[str, Any]:
    for command in ("anvil", "cast", "forge"):
        if shutil.which(command) is None:
            raise AgentsError(command + " is required")
    fork_url = s1._provider(fork_url)
    s1._preflight(fork_url)
    artifacts = windtunnel._artifact_evidence()
    first, first_observation = _run_once(port, fork_url, artifacts)
    observations = [first_observation]
    if single_run:
        identical = False
    else:
        second, second_observation = _run_once(port + 1, fork_url, artifacts)
        observations.append(second_observation)
        first_raw = s1._canonical(first)
        second_raw = s1._canonical(second)
        if first_raw != second_raw:
            raise AgentsError(
                "S3 economic projections diverged: %s != %s"
                % (hashlib.sha256(first_raw).hexdigest(), hashlib.sha256(second_raw).hexdigest())
            )
        identical = True
    digest = "0x" + hashlib.sha256(s1._canonical(first)).hexdigest()
    comparison = {
        "economicProjectionSha256": digest,
        "excludedFields": list(EXCLUDED_FIELDS),
        "identical": identical,
    }
    return {
        "comparison": comparison,
        "economicProjection": first,
        "kind": "fao.rehearsal.r0-s3-evidence",
        "observations": observations,
        "publicBroadcasts": 0,
        "v": "1",
    }


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise AgentsError(message)


def _decimal(value: Any, label: str) -> int:
    _require(
        isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]*", value) is not None,
        label + " is not canonical decimal",
    )
    return int(value)


def _integer(value: Any, label: str) -> int:
    _require(isinstance(value, int) and not isinstance(value, bool), label + " is not an integer")
    return value


def _file_sha256(path: Path) -> str:
    return "0x" + hashlib.sha256(path.read_bytes()).hexdigest()


def _offline_matrix(
    stack: dict[str, Any],
) -> tuple[dict[str, bytes], list[dict[str, Any]], dict[str, dict[str, bool]]]:
    correct_t2 = tournament.build_t2_artifact(stack)
    wrong_t2 = json.loads(correct_t2)
    wrong_t2["runtimeCodeKeccak256"]["gateway"] = ZERO32
    blobs = {
        "t1": tournament.build_t1_artifact(),
        "t2": correct_t2,
        "t2-wrong": runner.canonical_json(wrong_t2),
        "t3": tournament.build_t3_artifact(stack),
    }
    submissions = tournament._submission_configs(stack, blobs)
    for submission in submissions:
        submission["config"]["caps"]["bondAmount"] = str(2 * WAD)
    graders = {
        submission["id"]: {
            "objectiveCorrect": submission["id"] != "B-T2",
            "original": submission["id"] != "C-T1",
            "verdict": submission["id"] not in ("B-T2", "C-T1"),
        }
        for submission in submissions
    }
    return blobs, submissions, graders


def _verify_agent_matrix(projection: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, dict[str, Any]]]:
    matrix = projection["matrix"]
    _require(
        isinstance(matrix, dict)
        and set(matrix)
        == {
            "bondBefore",
            "challengeFacts",
            "crossStackProposalIds",
            "escrowAfterGraduation",
            "graders",
            "graduation",
            "metrics",
            "restartPins",
            "roundRobinTicks",
            "submissions",
            "tasks",
        },
        "S3 matrix schema drifted",
    )
    blobs, submissions, graders = _offline_matrix(projection["agentStack"])
    by_id = {item["id"]: item for item in submissions}
    reported = _reported_submissions(submissions, graders)
    _require(matrix["submissions"] == reported, "S3 exact submission/document matrix drifted")
    _require(
        projection["artifactBlobs"]
        == {documents.document_digest(blob): "0x" + blob.hex() for blob in blobs.values()},
        "S3 exact offline artifact set drifted",
    )
    expected_ticks = [
        {"action": action, "agent": by_id[submission_id]["agent"], "submission": submission_id}
        for action in tournament.ROUND_ROBIN_ACTIONS
        for submission_id in tournament.ROUND_ROBIN_IDS
    ]
    _require(
        matrix["graders"] == graders
        and matrix["roundRobinTicks"] == expected_ticks
        and matrix["challengeFacts"]
        == {
            submission_id: challenger
            for submission_id, challenger in tournament.EXPECTED_CHALLENGES.items()
            if challenger is not None
        },
        "S3 grader/challenge/round-robin matrix drifted",
    )
    expected_graduation = {
        submission_id: {
            "queuePosition": str(index + 1),
            "requiredYesBond": str(100 * WAD * (2**index)),
        }
        for index, submission_id in enumerate(tournament.EVALUATION_IDS)
    }
    p2a_ids = sorted(item["proposalId"] for item in _p2a_proposal_bindings())
    hero_ids = sorted(item["proposalId"] for item in submissions)
    _require(
        matrix["bondBefore"] == {name: str(amount) for name, amount in CONTRIBUTIONS.items()}
        and matrix["escrowAfterGraduation"] == str(sum(CONTRIBUTIONS.values()))
        and matrix["graduation"] == expected_graduation
        and matrix["crossStackProposalIds"]
        == {"hero": hero_ids, "p2a": p2a_ids, "intersection": []}
        and not set(hero_ids) & set(p2a_ids),
        "S3 bond graduation or cross-stack proposal binding drifted",
    )
    expected_tasks = {}
    for task_id in ("T1", "T2", "T3"):
        task = next(item["task"] for item in submissions if item["taskId"] == task_id)
        publication = documents.prepare_publication("task", task)
        actual = matrix["tasks"].get(task_id)
        _require(
            isinstance(actual, dict)
            and set(actual) == {"digest", "document", "transactionHash"}
            and re.fullmatch(r"0x[0-9a-f]{64}", actual["transactionHash"] or "") is not None,
            "S3 task publication schema drifted",
        )
        expected_tasks[task_id] = {
            "digest": publication["documentDigest"],
            "document": "0x" + publication["document"].hex(),
            "transactionHash": actual["transactionHash"],
        }
    _require(matrix["tasks"] == expected_tasks, "S3 exact task publications drifted")

    restart_facts = (
        ("publish-receipt", "RECEIPT_PUBLISHED", False, "runner:publish-receipt:A-T2", None),
        ("publish-payment", "PAYMENT_PUBLISHED", False, "runner:publish-payment:A-T2", None),
        ("propose", "PROPOSED", False, "runner:propose:A-T2", "INACTIVE"),
        ("place-yes-bond", "BONDED", False, "runner:place-yes-bond:A-T2", "YES"),
        ("challenged", "BONDED", False, "challenge:A-T2", "NO"),
        ("graduated", "BONDED", False, "graduate:A-T2", "QUEUED"),
        ("evaluating", "BONDED", False, "evaluation:start-market:A-T2", "EVALUATING"),
        ("evaluated", "ACCEPTED", True, "evaluation:resolve:A-T2", "SETTLED"),
        ("queued", "QUEUED", True, "runner:queue:A-T2", "SETTLED"),
        ("paid", "PAID", True, "runner:execute:A-T2", "SETTLED"),
    )
    pins = matrix["restartPins"]
    _require(
        isinstance(pins, list)
        and [item.get("label") for item in pins] == [item[0] for item in restart_facts],
        "S3 A-T2 restart pin sequence drifted",
    )
    action_hash = "0x" + int(by_id["A-T2"]["proposalId"]).to_bytes(32, "big").hex()
    for pin, (label, lifecycle, accepted, transaction_label, proposal_state) in zip(pins, restart_facts):
        state = pin.get("stateView")
        transaction = _transaction_by_label(projection, transaction_label)
        proposal = state.get("proposal") if isinstance(state, dict) else None
        _require(
            isinstance(state, dict)
            and state.get("actionHash") == action_hash
            and state.get("lifecycle") == lifecycle
            and state.get("paid") is (label == "paid")
            and pin.get("lifecycle") == lifecycle
            and pin.get("accepted") is accepted
            and pin.get("blockHash") == transaction.get("blockHash")
            and pin.get("blockNumber") == str(transaction.get("blockNumber"))
            and pin.get("stateSha256")
            == "0x" + hashlib.sha256(runner.canonical_json(state)).hexdigest(),
            "S3 A-T2 restart lifecycle/state digest drifted at " + label,
        )
        _require(
            (proposal_state is None and proposal is None)
            or (isinstance(proposal, dict) and proposal.get("state") == proposal_state),
            "S3 A-T2 restart proposal state drifted at " + label,
        )
    return submissions, by_id


def _verify_payment(
    payment: Any,
    *,
    amount: int,
    proposal_id: str,
    recipient: str,
    tapped: bool,
    transaction: dict[str, Any],
) -> None:
    _require(isinstance(payment, dict), "S3 payment proof is missing")
    before_executor = _decimal(payment["executorBefore"], "payment.executorBefore")
    after_executor = _decimal(payment["executorAfter"], "payment.executorAfter")
    before_recipient = _decimal(payment["recipientBefore"], "payment.recipientBefore")
    after_recipient = _decimal(payment["recipientAfter"], "payment.recipientAfter")
    event = payment["transferEvent"]
    _require(
        _decimal(payment["amount"], "payment.amount") == amount
        and before_executor - after_executor == amount
        and after_recipient - before_recipient == amount
        and event
        == {
            "actionHash": "0x" + int(proposal_id).to_bytes(32, "big").hex(),
            "amount": str(amount),
            "asset": s1.WETH,
            "recipient": recipient,
        }
        and payment["transactionHash"] == transaction.get("hash")
        and transaction.get("status") == 1,
        "S3 payment log/balance reconciliation drifted",
    )
    if tapped:
        _require(payment.get("recipient") == recipient, "S3 tapped recipient drifted")
    else:
        _require(payment.get("tapSpentLogs") == 0, "S3 evaluated payment consumed tap budget")


def _all_decimal_zero(value: Any) -> bool:
    if isinstance(value, dict):
        return all(_all_decimal_zero(item) for item in value.values())
    return isinstance(value, str) and value == "0"


def _transaction_by_label(projection: dict[str, Any], label: str) -> dict[str, Any]:
    matches = [item for item in projection["transactions"] if item.get("label") == label]
    _require(len(matches) == 1, "S3 transaction label is missing or duplicated: " + label)
    return matches[0]


def _verify_cycles(
    projection: dict[str, Any], by_id: dict[str, dict[str, Any]]
) -> None:
    cycles = projection["cycles"]
    _require(
        isinstance(cycles, list)
        and [cycle.get("submission") for cycle in cycles] == list(tournament.EVALUATION_IDS),
        "S3 serial evaluation cycle order drifted",
    )
    for index, cycle in enumerate(cycles):
        submission_id = tournament.EVALUATION_IDS[index]
        submission = by_id[submission_id]
        accepted = submission_id == "A-T2"
        _require(
            set(cycle) == {"activeEvaluationNegative", "market", "migration", "result", "submission"},
            "S3 cycle schema drifted for " + submission_id,
        )
        market, migration, result = cycle["market"], cycle["migration"], cycle["result"]
        _require(
            market["proposalId"] == submission["proposalId"]
            and _integer(market["anchorTimestamp"], "market.anchorTimestamp") > 0,
            "S3 market/proposal binding drifted for " + submission_id,
        )
        for label in ("yes", "no"):
            official = market["officialPoolsBeforeSync"][label]
            company_wrapper = market["wrappers"][label + "Company"]
            currency_wrapper = market["wrappers"][label + "Currency"]
            pool = market["binding"][label + "Pool"]
            _require(
                official["companyWrapper"] == company_wrapper
                and official["currencyWrapper"] == currency_wrapper
                and [official["token0"], official["token1"]]
                == sorted((company_wrapper, currency_wrapper))
                and official["fee"] == s1.FEE
                and official["liquidity"] == 0
                and official["slot0"]["sqrtPriceX96"]
                == int(official["expectedInitialSqrtPriceX96"])
                and official["slot0"]["observationCardinalityNext"] >= 120
                and official["factoryPool"] == pool
                and all(
                    official[key] == "0"
                    for key in (
                        "companyPoolBalance",
                        "companyTotalSupply",
                        "currencyPoolBalance",
                        "currencyTotalSupply",
                    )
                ),
                "S3 exact empty official pool evidence drifted for %s/%s" % (submission_id, label),
            )
        probe = cycle["activeEvaluationNegative"]
        if index == 0:
            _require(
                isinstance(probe, dict)
                and probe.get("before") == probe.get("after")
                and probe.get("trace", {}).get("returnValue") == INVALID_STATE,
                "S3 active-evaluation atomic negative probe drifted",
            )
        else:
            _require(probe is None, "S3 active-evaluation probe repeated")

        spot_before = _decimal(migration["spotBefore"], "migration.spotBefore")
        spot_after = _decimal(migration["spotAfter"], "migration.spotAfter")
        liquidities = migration["liquidity"]
        trade = migration["trade"]
        winner = "yes" if accepted else "no"
        loser = "no" if accepted else "yes"
        winner_before = _integer(trade["winnerTickBefore"], "trade.winnerTickBefore")
        winner_after = _integer(trade["winnerTickAfter"], "trade.winnerTickAfter")
        loser_tick = _integer(trade["loserTick"], "trade.loserTick")
        _require(
            spot_after == spot_before - spot_before * 8_000 // 10_000
            and all(_decimal(liquidities[label], "migration.liquidity." + label) > 0 for label in ("yes", "no"))
            and _decimal(trade["amount"], "trade.amount") == 24 * WAD // 10_000
            and _integer(trade["amountOut"], "trade.amountOut") > 0
            and trade["winner"] == winner
            and 25 <= winner_after - winner_before <= 50
            and winner_after > loser_tick,
            "S3 80% migration or bounded verdict trade drifted for " + submission_id,
        )

        twap = result["twap"]
        yes_tick = _integer(twap["yesMeanTick"], "twap.yesMeanTick")
        no_tick = _integer(twap["noMeanTick"], "twap.noMeanTick")
        timeout = _integer(twap["timeout"], "twap.timeout")
        window = _integer(twap["window"], "twap.window")
        _require(
            result["accepted"] is accepted
            and result["proposalId"] == submission["proposalId"]
            and result["route"] == tournament.EXPECTED_ROUTES[submission_id]
            and result["runnerAcceptanceRoute"] == "evaluated"
            and result["payout"]
            == {"yes": "1" if accepted else "0", "no": "0" if accepted else "1", "denominator": "1"}
            and timeout == 7 * 24 * 60 * 60
            and window == 24 * 60 * 60
            and twap["windowEnd"] == market["anchorTimestamp"] + timeout
            and twap["startAgo"] - twap["endAgo"] == window
            and result["resolvedAt"] >= twap["windowEnd"]
            and (yes_tick > no_tick if accepted else no_tick > yes_tick),
            "S3 strict production TWAP outcome drifted for " + submission_id,
        )
        if accepted:
            _require(result["negativeQueue"] is None, "S3 accepted route has a rejection proof")
            _verify_payment(
                result["payment"],
                amount=tournament.PAYMENTS[submission_id],
                proposal_id=submission["proposalId"],
                recipient=submission["payment"]["recipient"],
                tapped=False,
                transaction=_transaction_by_label(projection, "runner:execute:" + submission_id),
            )
        else:
            negative = result["negativeQueue"]
            _require(
                result["payment"] is None
                and isinstance(negative, dict)
                and negative.get("before") == negative.get("after")
                and negative.get("recipient") == submission["payment"]["recipient"]
                and negative.get("recipientBefore") == "0"
                and negative.get("recipientAfter") == "0"
                and negative.get("trace", {}).get("returnValue") == ARBITRATION_NOT_ACCEPTED,
                "S3 rejected queue atomicity drifted for " + submission_id,
            )

        residue = result["managerLosingResidue"]
        residue_amount = _decimal(residue["amount"], "managerLosingResidue.amount")
        rounding = int(residue["roundingVsTraderOutput"])
        outcomes = result["managerCurrentConditionOutcomes"]
        expected_outcome = loser + "Company"
        _require(
            residue["outcome"] == loser.upper()
            and residue_amount > 0
            and residue_amount - trade["amountOut"] == rounding
            and abs(rounding) <= 1
            and _decimal(outcomes[expected_outcome], "manager outcome") == residue_amount
            and all(value == "0" for key, value in outcomes.items() if key != expected_outcome),
            "S3 attributable losing residue drifted for " + submission_id,
        )
        burned = result["burnedNpmPositions"]
        _require(
            all(
                burned[label]
                == {"ownerOfReverted": True, "tokenId": str(migration["npmIds"][label])}
                for label in ("yes", "no")
            )
            and result["restore"]["restoredAt"] > result["resolvedAt"]
            and _all_decimal_zero(result["restore"]["underlyingResidue"])
            and _all_decimal_zero(result["restore"]["traderUnderlying"]),
            "S3 conditional-position burn/restore residue drifted for " + submission_id,
        )


def _verify_ledgers(projection: dict[str, Any], by_id: dict[str, dict[str, Any]]) -> None:
    bond = projection["bondLedger"]
    _require(
        bond
        == {
            "contributions": {name: str(amount) for name, amount in CONTRIBUTIONS.items()},
            "escrow": str(718 * WAD),
            "withdrawable": {name: str(amount) for name, amount in EXPECTED_WITHDRAWABLE.items()},
        }
        and sum(_decimal(value, "withdrawable") for value in bond["withdrawable"].values())
        == _decimal(bond["escrow"], "bond.escrow"),
        "S3 bond conservation drifted",
    )
    tap = projection["tapLedger"]
    _require(
        set(tap)
        == {
            "budget",
            "compositionBoundary",
            "payments",
            "remaining",
            "settledAtOrAfter",
            "spent",
            "windowStart",
        }
        and tap["budget"] == str(200 * 10**15)
        and tap["spent"] == str(10 * 10**15)
        and tap["remaining"] == str(190 * 10**15)
        and tap["compositionBoundary"]
        == {
            "availableAfterLaterTransferSegment": str(40 * 10**15),
            "executedInS3": False,
            "laterTransferSegment": str(150 * 10**15),
            "stage": "S6",
        },
        "S3 tap ledger totals or S6 boundary drifted",
    )
    cumulative = 0
    executor_before = 1_200 * 10**15
    recipient_befores = {"A-T1": 0, "A-T3": 0, "C-T3": 0}
    for submission_id in tournament.TIMEOUT_IDS:
        payment = tap["payments"][submission_id]
        amount = tournament.PAYMENTS[submission_id]
        cumulative += amount
        _verify_payment(
            payment,
            amount=amount,
            proposal_id=by_id[submission_id]["proposalId"],
            recipient=by_id[submission_id]["payment"]["recipient"],
            tapped=True,
            transaction=_transaction_by_label(projection, "runner:execute:" + submission_id),
        )
        _require(
            payment["tap"]
            == {
                "amount": str(amount),
                "asset": s1.WETH,
                "budget": tap["budget"],
                "spent": str(cumulative),
                "windowStart": str(tap["windowStart"]),
            },
            "S3 cumulative timeout tap proof drifted for " + submission_id,
        )
        _require(
            payment["executorBefore"] == str(executor_before)
            and payment["executorAfter"] == str(executor_before - amount)
            and payment["recipientBefore"] == str(recipient_befores[submission_id])
            and payment["recipientAfter"] == str(recipient_befores[submission_id] + amount),
            "S3 chained timeout balance proof drifted for " + submission_id,
        )
        executor_before -= amount
    evaluated = projection["cycles"][0]["result"]["payment"]
    _require(
        executor_before == 1_190 * 10**15
        and evaluated["executorBefore"] == str(executor_before)
        and evaluated["executorAfter"] == str(executor_before - tournament.PAYMENTS["A-T2"])
        and evaluated["recipientBefore"] == str(tournament.PAYMENTS["A-T3"])
        and evaluated["recipientAfter"]
        == str(tournament.PAYMENTS["A-T3"] + tournament.PAYMENTS["A-T2"]),
        "S3 timeout-to-evaluated balance chain drifted",
    )
    treasury = projection["treasury"]
    _require(
        treasury
        == {
            "executorFinal": str(1_188 * 10**15),
            "executorInitial": str(1_200 * 10**15),
            "recipients": {
                "agentA": str(1 * 10**15),
                "workerA": str(5 * 10**15),
                "workerB": "0",
                "workerC1": "0",
                "workerC3": str(6 * 10**15),
            },
            "spent": str(12 * 10**15),
        },
        "S3 treasury/recipient conservation drifted",
    )


def _verify_resources_and_clock(projection: dict[str, Any], by_id: dict[str, dict[str, Any]]) -> None:
    transactions = projection["transactions"]
    resources = projection["resources"]
    _require(isinstance(transactions, list) and transactions, "S3 transaction ledger is empty")
    failed_labels = [item.get("label") for item in transactions if item.get("status") == 0]
    _require(
        resources
        == {
            "blocks": transactions[-1]["blockNumber"] - transactions[0]["blockNumber"] + 1,
            "failedTransactions": sum(item.get("status") == 0 for item in transactions),
            "gasUsed": sum(item["gasUsed"] for item in transactions),
            "transactions": len(transactions),
        }
        and resources["transactions"] == 116
        and resources["blocks"] == 130
        and resources["failedTransactions"] == 3
        and failed_labels
        == [
            "negative:active-evaluation",
            "negative:queue-rejected:B-T2",
            "negative:queue-rejected:C-T1",
        ]
        and all(
            right["blockTimestamp"] > left["blockTimestamp"]
            for left, right in zip(transactions, transactions[1:])
        ),
        "S3 resource totals or transaction clock drifted",
    )
    labeled = {item.get("label"): item for item in transactions if item.get("label")}
    _require(len(labeled) == sum(bool(item.get("label")) for item in transactions), "S3 transaction labels repeat")
    metrics = projection["matrix"]["metrics"]
    _require(
        set(metrics)
        == {
            "artifactQuality",
            "challengeRate",
            "falsePaymentRate",
            "proposalGas",
            "simulatedChainCompletionLatencySeconds",
            "totalTreasurySpend",
        }
        and metrics["artifactQuality"] == {"agentA": "3/3", "agentB": "0/1", "agentC": "1/2"}
        and metrics["challengeRate"] == "3/6"
        and metrics["falsePaymentRate"] == "0/4"
        and metrics["totalTreasurySpend"] == str(12 * 10**15),
        "S3 derived metric summary drifted",
    )
    proposal_gas = metrics["proposalGas"]
    _require(
        isinstance(proposal_gas, list)
        and [item.get("submission") for item in proposal_gas] == list(tournament.ROUND_ROBIN_IDS),
        "S3 proposal gas rows drifted",
    )
    for row in proposal_gas:
        submission = by_id[row["submission"]]
        record = labeled["runner:propose:" + row["submission"]]
        _require(
            row["actor"] == submission["agent"]
            and row["proposalId"] == submission["proposalId"]
            and _decimal(row["gasUsed"], "proposalGas.gasUsed") == record["gasUsed"]
            and _decimal(record["effectiveGasPriceWei"], "transaction.effectiveGasPriceWei") > 0
            and _decimal(row["gasCostWei"], "proposalGas.gasCostWei")
            == record["gasUsed"] * int(record["effectiveGasPriceWei"]),
            "S3 proposal gas binding drifted for " + row["submission"],
        )
    expected_latency = {}
    for submission_id, submission in by_id.items():
        end_label = (
            "runner:execute:" + submission_id
            if submission_id in tournament.PAID_IDS
            else "evaluation:resolve:" + submission_id
        )
        expected_latency[submission_id] = str(
            labeled[end_label]["blockTimestamp"]
            - labeled["index:task:" + submission["taskId"]]["blockTimestamp"]
        )
    _require(
        metrics["simulatedChainCompletionLatencySeconds"] == expected_latency
        and all(int(value) > 0 for value in expected_latency.values()),
        "S3 simulated completion latencies drifted",
    )

    observed_stages = [
        {"stage": "deployment-complete", "timestamp": transactions[5]["blockTimestamp"]},
        {"stage": "index-deployed", "timestamp": labeled["index:deploy"]["blockTimestamp"]},
        {"stage": "sale-sealed", "timestamp": labeled["sale:seal"]["blockTimestamp"]},
        {
            "stage": "timeout-settlement-boundary",
            "timestamp": projection["tapLedger"]["settledAtOrAfter"],
        },
        {"stage": "timeout-first-execution", "timestamp": projection["tapLedger"]["windowStart"]},
    ]
    for cycle in projection["cycles"]:
        submission_id = cycle["submission"]
        observed_stages.extend(
            (
                {"stage": submission_id + ":anchor", "timestamp": cycle["market"]["anchorTimestamp"]},
                {
                    "stage": submission_id + ":window-end",
                    "timestamp": cycle["result"]["twap"]["windowEnd"],
                },
                {"stage": submission_id + ":resolved", "timestamp": cycle["result"]["resolvedAt"]},
                {
                    "stage": submission_id + ":restored",
                    "timestamp": cycle["result"]["restore"]["restoredAt"],
                },
            )
        )
    clock = projection["clock"]
    _require(
        isinstance(clock, dict)
        and set(clock) == {"discipline", "stages"}
        and clock["discipline"] == "absolute-precomputed"
        and clock["stages"] == observed_stages == _absolute_clock_stages(),
        "S3 named absolute clock drifted",
    )


def _verify_projection(projection: Any) -> None:
    fields = {
        "actorPreconditions",
        "agentStack",
        "anvilStateMutations",
        "artifactBlobs",
        "artifacts",
        "bondLedger",
        "chainId",
        "claims",
        "clock",
        "continuity",
        "cycles",
        "fork",
        "graderPolicy",
        "hero",
        "index",
        "inputs",
        "matrix",
        "publicBroadcasts",
        "resources",
        "shortfallDrill",
        "stack",
        "tapLedger",
        "transactions",
        "treasury",
    }
    _require(isinstance(projection, dict) and set(projection) == fields, "S3 projection schema drifted")
    sealed_s1 = _sealed_s1()["economicProjection"]
    _require(
        projection["chainId"] == s1.CHAIN_ID
        and projection["fork"]
        == {
            "blockHash": s1.FORK_BLOCK_HASH,
            "blockNumber": s1.FORK_BLOCK,
            "selectedFromHead": s1.FORK_SELECTED_FROM_HEAD,
            "selectionRule": "finalized-head-minus-64-rounded-down-1000",
            "timestamp": s1.FORK_TIMESTAMP,
        }
        and projection["stack"] == sealed_s1["stack"]
        and projection["artifacts"] == sealed_s1["artifacts"]
        and projection["continuity"]
        == {"s1EvidenceSha256": _file_sha256(S1_EVIDENCE_PATH), "stackAndBootstrapExact": True},
        "S3 sealed S1 fork/stack/artifact continuity drifted",
    )
    hero = projection["hero"]
    _require(
        hero["bootstrap"] == sealed_s1["bootstrap"]
        and hero["raise"] == sealed_s1["raise"]
        and hero["executor"] == sealed_s1["stack"]["executor"]
        and hero["terminalPrice"] == int(sealed_s1["bootstrap"]["terminalPrice"])
        and str(hero["spotNft"]) == sealed_s1["bootstrap"]["spotNpmPosition"]["tokenId"],
        "S3 hero genesis continuity drifted",
    )
    _require(
        projection["inputs"]
        == {
            "driverSha256": _file_sha256(Path(__file__)),
            "p2aProposalBindingsSha256": _p2a_proposal_bindings_sha256(),
            "scriptSha256": _file_sha256(SCRIPT),
            "tournamentModuleSha256": _file_sha256(ROOT / "tools/agent_tournament.py"),
        },
        "S3 local input binding drifted",
    )
    a = sealed_s1["stack"]["addresses"]
    agent_stack = projection["agentStack"]
    _require(
        isinstance(agent_stack, dict)
        and set(agent_stack)
        == {
            "arbitration",
            "asset",
            "chainId",
            "executor",
            "forkBlock",
            "forkBlockHash",
            "gateway",
            "index",
            "minActivationBond",
            "observationBlock",
            "runtimeCodeKeccak256",
            "startBlock",
            "startTimestamp",
            "vault",
        }
        and agent_stack["chainId"] == s1.CHAIN_ID
        and agent_stack["forkBlock"] == s1.FORK_BLOCK
        and agent_stack["forkBlockHash"] == s1.FORK_BLOCK_HASH
        and agent_stack["startBlock"] == s1.FORK_BLOCK + 1
        and agent_stack["startTimestamp"] == s1.FORK_TIMESTAMP
        and agent_stack["asset"] == s1.WETH
        and agent_stack["minActivationBond"] == 2 * WAD
        and agent_stack["gateway"] == a["proposalGateway"]
        and agent_stack["arbitration"] == a["arbitration"]
        and agent_stack["vault"] == a["vault"]
        and agent_stack["executor"] == sealed_s1["stack"]["executor"]
        and agent_stack["observationBlock"] > agent_stack["startBlock"],
        "S3 agent-stack binding drifted",
    )
    runtime = agent_stack["runtimeCodeKeccak256"]
    _require(
        set(runtime) == {"index", "gateway", "arbitration", "vault", "executor"}
        and runtime["gateway"] == sealed_s1["stack"]["runtimeHashes"]["proposalGateway"]
        and runtime["arbitration"] == sealed_s1["stack"]["runtimeHashes"]["arbitration"]
        and runtime["vault"] == sealed_s1["stack"]["runtimeHashes"]["vault"]
        and all(re.fullmatch(r"0x[0-9a-f]{64}", value or "") and int(value, 16) for value in runtime.values())
        and projection["index"]
        == {"address": agent_stack["index"], "authority": "none", "runtimeHash": runtime["index"]},
        "S3 runtime/index binding drifted",
    )
    expected_preconditions = {
        name: {
            "address": address,
            "code": "0x",
            "nativeBalance": "0",
            "nonce": "0",
            "provenance": "house-wallet",
        }
        for name, address in ACTORS.items()
    }
    expected_mutations = [
        {
            "after": str(2_000 * WAD),
            "before": "0",
            "kind": "native-balance",
            "purpose": "fund disposable Anvil gas and canonical WETH deposits",
            "target": address,
        }
        for address in ACTORS.values()
    ] + [
        {
            "after": True,
            "before": False,
            "kind": "impersonation-mode",
            "purpose": "unlock fixed zero-nonce house actors without stored keys",
            "target": "anvil --auto-impersonate",
        }
    ]
    _require(
        projection["actorPreconditions"] == expected_preconditions
        and projection["anvilStateMutations"] == expected_mutations,
        "S3 actor preconditions or Anvil mutation disclosure drifted",
    )
    _require(
        projection["claims"]
        == {
            "externalWork": False,
            "demand": False,
            "liveDeployment": False,
            "livePayment": False,
            "shortfallOnHero": False,
            "wholeConditionClosure": False,
        }
        and projection["graderPolicy"]
        == {
            "heroResolution": {
                "authority": "receipt-bound-production-market-pipeline",
                "houseTradeTarget": "objectiveCorrect AND original",
                "resolverInput": "strict 7-day/1-day TWAP inequality",
            },
            "sealedP2aArtifactPolicyReference": tournament.GRADER_POLICY,
        }
        and projection["shortfallDrill"]
        == {
            "status": "not-replayed-in-s3",
            "coverage": [
                "metadata/agent-work-p2a-evidence.json:drills.cT3Shortfall",
                "Rehearsal-R0-S6:critical-drain-S5-shortfall",
            ],
        }
        and projection["publicBroadcasts"] == 0,
        "S3 claim/policy/shortfall disclosure drifted",
    )
    submissions, by_id = _verify_agent_matrix(projection)
    _require(len(submissions) == 6, "S3 submission cardinality drifted")
    _verify_cycles(projection, by_id)
    _verify_ledgers(projection, by_id)
    _verify_resources_and_clock(projection, by_id)


def _contains_excluded_key(value: Any) -> bool:
    if isinstance(value, dict):
        return any(key in EXCLUDED_FIELDS or _contains_excluded_key(item) for key, item in value.items())
    if isinstance(value, list):
        return any(_contains_excluded_key(item) for item in value)
    return False


def _verify_evidence_value(value: Any) -> None:
    _install_offline_keccak()
    _require(
        isinstance(value, dict)
        and set(value)
        == {"comparison", "economicProjection", "kind", "observations", "publicBroadcasts", "v"},
        "S3 outer evidence schema drifted",
    )
    _require(
        value["kind"] == "fao.rehearsal.r0-s3-evidence"
        and value["v"] == "1"
        and value["publicBroadcasts"] == 0,
        "S3 kind/version/broadcast count drifted",
    )
    projection = value["economicProjection"]
    comparison = value["comparison"]
    _require(
        comparison
        == {
            "economicProjectionSha256": "0x" + hashlib.sha256(s1._canonical(projection)).hexdigest(),
            "excludedFields": list(EXCLUDED_FIELDS),
            "identical": True,
        }
        and not _contains_excluded_key(projection),
        "S3 projection digest, identity, or exclusion boundary drifted",
    )
    observations = value["observations"]
    _require(
        isinstance(observations, list)
        and len(observations) == 2
        and all(isinstance(item, dict) and set(item) == set(EXCLUDED_FIELDS) for item in observations)
        and all(
            isinstance(item["port"], int)
            and item["port"] > 0
            and isinstance(item["processId"], int)
            and item["processId"] > 0
            and isinstance(item["providerUrl"], str)
            and bool(item["providerUrl"])
            and isinstance(item["wallDurationMs"], int)
            and item["wallDurationMs"] > 0
            for item in observations
        )
        and observations[1]["port"] == observations[0]["port"] + 1
        and observations[0]["processId"] != observations[1]["processId"]
        and observations[0]["providerUrl"] == observations[1]["providerUrl"],
        "S3 requires two well-formed fresh-fork observations",
    )
    _verify_projection(projection)


def write_evidence(path: Path, evidence: dict[str, Any]) -> str:
    """Seal a dual-run S3 artifact; debug single-runs deliberately cannot pass."""
    _verify_evidence_value(evidence)
    raw = s1._canonical(evidence)
    digest = "0x" + hashlib.sha256(raw).hexdigest()
    path.write_bytes(raw)
    path.with_suffix(path.suffix + ".sha256").write_text(digest + "\n", encoding="ascii")
    return digest


def verify_evidence(path: Path = EVIDENCE_PATH) -> str:
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
        digest = "0x" + hashlib.sha256(raw).hexdigest()
        _require(raw == s1._canonical(value), "S3 evidence is not canonical sorted-key compact JSON")
        _require(
            path.with_suffix(path.suffix + ".sha256").read_text(encoding="ascii").strip()
            == digest,
            "S3 exact-byte SHA-256 sidecar drifted",
        )
        _verify_evidence_value(value)
        return digest
    except AgentsError:
        raise
    except (
        AttributeError,
        KeyError,
        IndexError,
        StopIteration,
        TypeError,
        ValueError,
        json.JSONDecodeError,
        OSError,
    ) as error:
        raise AgentsError("S3 semantic evidence validation failed: %s" % error) from error


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fork-url", default="https://sepolia.drpc.org")
    parser.add_argument("--port", type=int, default=19_675)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--single-run", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args(argv)
    output = args.output or (EVIDENCE_PATH if args.check else Path("/tmp/fao-rehearsal-r0-s3.json"))
    if args.check:
        print("verified %s (%s)" % (output, verify_evidence(output)))
        return 0
    evidence = run(args.port, args.fork_url, single_run=args.single_run)
    if args.single_run:
        output.write_bytes(s1._canonical(evidence))
        print("wrote non-sealable single-run debug artifact %s" % output)
    else:
        print("wrote %s (%s)" % (output, write_evidence(output, evidence)))
    print("public broadcasts: 0")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, runner.RunnerError) as error:
        print("error: " + str(error), file=os.sys.stderr)
        raise SystemExit(1)
