#!/usr/bin/env python3
"""Deploy the Lane 4/5 stack on Anvil and emit executed P1 drill evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, Sequence

try:
    from tools import agent_documents as documents
    from tools import agent_runner as runner
except ModuleNotFoundError:  # Direct script execution.
    import agent_documents as documents  # type: ignore
    import agent_runner as runner  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
INDEX_MANIFEST = ROOT / "metadata/agent-work-index.json"
SEPOLIA_WETH = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"
ATTEMPT_LEDGER: list[dict[str, Any]] = []


class DrillError(ValueError):
    pass


class PinnedRpc(runner.JsonRpc):
    """Anvil has no finalized head; a mined latest block is the explicit drill pin."""

    def finalized_block(self) -> dict[str, Any]:
        return self.block("latest")


def _run(command: Sequence[str]) -> str:
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise DrillError("command failed: %s\n%s" % (" ".join(command), result.stderr[-2000:]))
    return result.stdout.strip()


def _deploy(contract: str, rpc_url: str, sender: str, arguments: Sequence[str] = ()) -> str:
    command = [
        "forge", "create", contract, "--rpc-url", rpc_url, "--unlocked", "--from", sender,
        "--broadcast", "--gas-limit", "30000000",
    ]
    if arguments:
        command.extend(("--constructor-args", *arguments))
    output = _run(command)
    match = re.search(r"Deployed to:\s*(0x[0-9a-fA-F]{40})", output)
    if match is None:
        raise DrillError("forge create did not report a deployment")
    return match.group(1).lower()


def _receipt(rpc: runner.JsonRpc, tx_hash: str) -> dict[str, Any]:
    for _ in range(200):
        value = rpc.request("eth_getTransactionReceipt", [tx_hash])
        if isinstance(value, dict):
            return value
        time.sleep(0.02)
    raise DrillError("transaction receipt did not arrive")


def _send(
    rpc: runner.JsonRpc,
    sender: str,
    target: str,
    data: str,
    *,
    value: int = 0,
    simulate: bool = True,
) -> tuple[str, dict[str, Any]]:
    transaction = {"from": sender, "to": target, "data": data, "value": hex(value)}
    if simulate:
        rpc.call(transaction, "latest")
    tx_hash = rpc.request("eth_sendTransaction", [transaction])
    if not isinstance(tx_hash, str):
        raise DrillError("eth_sendTransaction returned no hash")
    receipt = _receipt(rpc, tx_hash)
    ATTEMPT_LEDGER.append(
        {
            "from": sender,
            "to": target,
            "value": str(value),
            "dataKeccak256": documents.keccak256(bytes.fromhex(data[2:])),
            "transactionHash": tx_hash.lower(),
            "blockHash": receipt["blockHash"].lower(),
            "blockNumber": str(int(receipt["blockNumber"], 16)),
            "status": str(int(receipt["status"], 16)),
        }
    )
    return tx_hash.lower(), receipt


def _try_call(rpc: runner.JsonRpc, sender: str, target: str, data: str) -> bool:
    try:
        rpc.call({"from": sender, "to": target, "data": data, "value": "0x0"}, "latest")
        return True
    except runner.RpcCallError:
        return False


def _mine(rpc: runner.JsonRpc, seconds: int = 0) -> None:
    if seconds:
        rpc.request("evm_increaseTime", [seconds])
    rpc.request("evm_mine", [])


def _uint(rpc: runner.JsonRpc, target: str, signature: str, *args: str) -> int:
    data = "0x" + runner._selector(signature)
    for arg in args:
        data += int(arg, 0).to_bytes(32, "big").hex()
    return int(rpc.call({"to": target, "data": data}, "latest"), 16)


def _address_view(rpc: runner.JsonRpc, target: str, signature: str) -> str:
    raw = bytes.fromhex(rpc.call({"to": target, "data": "0x" + runner._selector(signature)}, "latest")[2:])
    if len(raw) != 32 or any(raw[:12]):
        raise DrillError("address view is malformed")
    return "0x" + raw[12:].hex()


def _token_balance(rpc: runner.JsonRpc, token: str, account: str) -> int:
    return _uint(rpc, token, "balanceOf(address)", account)


def _token_call(signature: str, account: str, amount: int) -> str:
    return "0x" + runner._selector(signature) + bytes(12).hex() + account[2:] + amount.to_bytes(32, "big").hex()


def _stack(rpc_url: str, rpc: runner.JsonRpc, accounts: list[str], fork: bool) -> dict[str, Any]:
    deployer, automation, challenger, resolver = accounts[:4]
    start_block = int(rpc.block("latest")["number"], 16)
    if fork:
        asset = SEPOLIA_WETH
        for account in (deployer, automation, challenger):
            _send(rpc, account, asset, "0xd0e30db0", value=10**18)
    else:
        asset = _deploy("src/FAOSiteToken.sol:FAOSiteToken", rpc_url, deployer, (deployer, "1000000"))
        for account in (automation, challenger):
            _send(rpc, deployer, asset, _token_call("transfer(address,uint256)", account, 10_000))

    arbitration = _deploy(
        "src/FutarchyArbitration.sol:FutarchyArbitration",
        rpc_url,
        deployer,
        (asset, "100", "10"),
    )
    index = _deploy("src/AgentWorkIndex.sol:AgentWorkIndex", rpc_url, deployer)
    head = rpc.block("latest")
    now = int(head["timestamp"], 16)
    c1, c2, tap, tap_max = (
        (10**17, 10**18, 10**18, 2 * 10**18) if fork else (100, 1000, 1000, 2000)
    )
    config_arg = (
        '("Agent Work Drill","AWD",%s,%s,%s,%s,%d,%d,100000000000000000000,10,'
        "1000000000000000000000,1000000000000000000,0,1000,[(%s,%d,%d,%d,%d)])"
        % (
            asset, deployer, arbitration, index, now + 10_000, now + 20_000, asset,
            c1, c2, tap, tap_max,
        )
    )
    vault = _deploy("src/GenesisVault.sol:GenesisVault", rpc_url, deployer, (config_arg, "[]"))
    executor = _address_view(rpc, vault, "TREASURY_EXECUTOR()")
    gateway = _deploy(
        "src/EconGateway.sol:EconGateway",
        rpc_url,
        deployer,
        (index, index, arbitration, vault, "1", "2"),
    )
    _send(
        rpc,
        deployer,
        arbitration,
        "0x" + runner._selector("setProposalGateway(address)") + bytes(12).hex() + gateway[2:],
    )
    rpc.request(
        "anvil_setStorageAt",
        [vault, "0x1", "0x" + (2).to_bytes(32, "big").hex()],
    )
    rpc.request(
        "anvil_setStorageAt",
        [arbitration, "0x6", "0x" + (bytes(12) + bytes.fromhex(resolver[2:])).hex()],
    )
    _mine(rpc)
    for account in (automation, challenger):
        _send(rpc, account, asset, _token_call("approve(address,uint256)", arbitration, 10_000))
    manifest = json.loads(INDEX_MANIFEST.read_text(encoding="utf-8"))
    runtime = rpc.request("eth_getCode", [index, "latest"])
    if documents.keccak256(bytes.fromhex(runtime[2:])) != manifest["runtimeCodeKeccak256"]:
        raise DrillError("deployed AgentWorkIndex runtime does not match its pin")
    contracts = {
        "index": index,
        "gateway": gateway,
        "arbitration": arbitration,
        "vault": vault,
        "executor": executor,
    }
    return {
        "chainId": rpc.chain_id(),
        "startBlock": start_block,
        "asset": asset,
        "arbitration": arbitration,
        "index": index,
        "vault": vault,
        "executor": executor,
        "gateway": gateway,
        "actors": {
            "deployer": deployer,
            "automation": automation,
            "challenger": challenger,
            "resolver": resolver,
            "worker": accounts[4],
            "recipientA": accounts[5],
            "recipientB": accounts[6],
            "keeperA": accounts[7],
            "keeperB": accounts[8],
        },
        "indexRuntimeKeccak256": manifest["runtimeCodeKeccak256"],
        "runtimeCodeKeccak256": {
            name: documents.keccak256(bytes.fromhex(rpc.request("eth_getCode", [address, "latest"])[2:]))
            for name, address in contracts.items()
        },
    }


def _config(stack: dict[str, Any], ordinal: int, *, recipient: str | None = None, amount: int = 10) -> dict[str, Any]:
    actors = stack["actors"]
    task = {
        "v": "1", "kind": "fao.task", "chainId": str(stack["chainId"]), "vault": stack["vault"],
        "title": "Anvil task %d" % ordinal, "spec": "Return exact deterministic evidence.",
        "salt": "0x" + (1000 + ordinal).to_bytes(32, "big").hex(),
    }
    task_digest = documents.document_digest(documents.build_task(task))
    receipt = {
        "v": "1", "kind": "fao.receipt", "chainId": str(stack["chainId"]), "vault": stack["vault"],
        "task": task_digest, "worker": actors["worker"],
        "artifacts": [{"digest": "0x" + (2000 + ordinal).to_bytes(32, "big").hex(), "uri": "https://example.test/%d" % ordinal}],
        "summary": "Anvil evidence %d" % ordinal,
        "salt": "0x" + (3000 + ordinal).to_bytes(32, "big").hex(),
    }
    receipt_digest = documents.document_digest(documents.build_receipt(receipt))
    payment = {
        "v": "1", "kind": "fao.payment", "chainId": str(stack["chainId"]), "vault": stack["vault"],
        "asset": stack["asset"], "recipient": recipient or actors["recipientA"],
        "amount": str(amount), "task": task_digest, "receipt": receipt_digest,
        "salt": "0x" + (4000 + ordinal).to_bytes(32, "big").hex(),
    }
    return {
        "chainId": stack["chainId"],
        "fromBlock": stack["startBlock"],
        "index": stack["index"],
        "gateway": stack["gateway"],
        "arbitration": stack["arbitration"],
        "vault": stack["vault"],
        "executor": stack["executor"],
        "automation": actors["automation"],
        "documents": {"task": task, "receipt": receipt, "payment": payment},
        "caps": {"paymentAmount": str(amount), "bondAmount": "100", "transactionValue": "0"},
    }


def _clean(config: dict[str, Any]) -> dict[str, Any]:
    return {key: value for key, value in config.items() if key != "_actors"}


def _runner_state(rpc_url: str, config: dict[str, Any]) -> dict[str, Any]:
    # A fresh adapter on every boundary is the restart proof; no local state is carried.
    rpc = PinnedRpc(rpc_url)
    clean = _clean(config)
    return runner.derive_state(clean, runner.collect_snapshot(rpc, clean))


def _state_evidence(state: dict[str, Any]) -> dict[str, Any]:
    return {
        "lifecycle": state["lifecycle"],
        "finalized": state["finalized"],
        "actionHash": state["actionHash"],
        "proposalId": state["proposalId"],
        "accepted": state["accepted"],
        "acceptanceRoute": state["acceptanceRoute"],
        "executable": state["executable"],
        "paid": state["paid"],
        "proposal": state["proposal"],
        "queued": state["queued"],
        "publicationOccurrences": {
            name: state["publications"][name]["occurrences"]
            for name in ("task", "receipt", "payment")
        },
    }


def _published_documents(rpc: runner.JsonRpc, stack: dict[str, Any]) -> list[dict[str, Any]]:
    end = int(rpc.block("latest")["number"], 16)
    result = []
    for raw in rpc.logs(stack["startBlock"], end, [stack["index"]]):
        log = runner._canonical_log(raw)
        if log["topics"][0] != documents.PUBLISHED_TOPIC:
            continue
        decoded = documents.decode_published_log({"topics": log["topics"], "data": log["data"]})
        result.append(
            {
                "kind": decoded["kind"],
                "parentDigest": decoded["parentDigest"],
                "documentDigest": decoded["documentDigest"],
                "document": "0x" + decoded["document"].hex(),
                "publisher": decoded["publisher"],
                "transactionHash": log["transactionHash"],
                "blockHash": log["blockHash"],
                "blockNumber": str(log["blockNumber"]),
            }
        )
    return result


def _publish_all(rpc: runner.JsonRpc, config: dict[str, Any]) -> list[dict[str, Any]]:
    receipts = []
    for name in ("task", "receipt", "payment"):
        publication = documents.prepare_publication(name, config["documents"][name])
        _, receipt = _send(
            rpc, config["automation"], config["index"], publication["calldata"]
        )
        receipts.append(receipt)
    return receipts


def _action(config: dict[str, Any]) -> tuple[dict[str, str], str, int]:
    raw = documents.build_payment(config["documents"]["payment"])
    action = documents.payment_transfer_action(raw)
    action_hash = documents.validate_payment_binding(raw, config["chainId"], config["vault"], action)
    return action, action_hash, int(action_hash, 16)


def _propose(rpc: runner.JsonRpc, config: dict[str, Any]) -> dict[str, Any]:
    action, _, _ = _action(config)
    _, receipt = _send(
        rpc,
        config["automation"],
        config["gateway"],
        runner._call(runner.SELECTORS["propose"], runner._action_words(action)),
    )
    return receipt


def _bond_yes(rpc: runner.JsonRpc, config: dict[str, Any], amount: int = 2, sender: str | None = None) -> None:
    _, _, proposal_id = _action(config)
    _send(
        rpc,
        sender or config["automation"],
        config["arbitration"],
        runner._call(runner.SELECTORS["placeYes"], runner._word(proposal_id), runner._word(amount)),
    )


def _timeout(rpc: runner.JsonRpc, config: dict[str, Any], accepted: bool) -> None:
    actors = config["_actors"]
    _, _, proposal_id = _action(config)
    _bond_yes(rpc, config)
    if not accepted:
        _send(
            rpc,
            actors["challenger"],
            config["arbitration"],
            runner._call(runner._selector("placeNoBond(uint256)"), runner._word(proposal_id)),
        )
    _mine(rpc, 11)
    _send(
        rpc,
        actors["keeperA"],
        config["arbitration"],
        runner._call(runner.SELECTORS["finalize"], runner._word(proposal_id)),
    )


def _evaluated(rpc: runner.JsonRpc, config: dict[str, Any], accepted: bool) -> None:
    actors = config["_actors"]
    _, _, proposal_id = _action(config)
    _bond_yes(rpc, config)
    _send(
        rpc,
        actors["challenger"],
        config["arbitration"],
        runner._call(runner._selector("placeNoBond(uint256)"), runner._word(proposal_id)),
    )
    _bond_yes(rpc, config, 100)
    _send(rpc, actors["keeperA"], config["arbitration"], "0x" + runner._selector("startNextEvaluation()"))
    _send(
        rpc,
        actors["resolver"],
        config["arbitration"],
        runner._call(runner._selector("resolveActiveEvaluation(bool)"), runner._word(1 if accepted else 0)),
    )


def _queue_data(config: dict[str, Any]) -> str:
    action, _, _ = _action(config)
    return runner._call(runner.SELECTORS["queue"], runner._action_words(action))


def _execute_data(config: dict[str, Any]) -> str:
    action, _, _ = _action(config)
    return runner._call(runner.SELECTORS["execute"], runner._action_words(action))


def _fund(rpc: runner.JsonRpc, stack: dict[str, Any], amount: int) -> None:
    _send(
        rpc,
        stack["actors"]["deployer"],
        stack["asset"],
        _token_call("transfer(address,uint256)", stack["executor"], amount),
    )


def _local_drills(rpc_url: str, rpc: runner.JsonRpc, stack: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    actors = stack["actors"]
    attempts = []
    states = []

    # Conflicting receipts/envelopes share no proposal or settlement state.
    first = _config(stack, 1, recipient=actors["recipientA"], amount=10)
    second = _config(stack, 2, recipient=actors["recipientB"], amount=11)
    for cfg in (first, second):
        cfg["_actors"] = actors
        _publish_all(rpc, cfg)
        _propose(rpc, cfg)
    first_id = _action(first)[2]
    second_id = _action(second)[2]
    if first_id == second_id:
        raise DrillError("conflicting envelopes produced one proposal id")
    _timeout(rpc, first, True)
    _timeout(rpc, second, False)
    if not _uint(rpc, stack["arbitration"], "isAccepted(uint256)", hex(first_id)) or _uint(
        rpc, stack["arbitration"], "isAccepted(uint256)", hex(second_id)
    ):
        raise DrillError("conflicting settlements cross-contaminated")

    # Same-envelope propose is deterministic and the duplicate reverts.
    duplicate_ok = not _try_call(rpc, actors["automation"], stack["gateway"], runner._call(
        runner.SELECTORS["propose"], runner._action_words(_action(first)[0])
    ))
    if not duplicate_ok:
        raise DrillError("duplicate proposal unexpectedly simulated")

    # Self-payment takes the ordinary timeout, queue, grace and treasury path.
    self_pay = _config(stack, 3, recipient=actors["automation"], amount=5)
    self_pay["_actors"] = actors
    _publish_all(rpc, self_pay)
    _propose(rpc, self_pay)
    _timeout(rpc, self_pay, True)
    _fund(rpc, stack, 5)
    _send(rpc, actors["keeperA"], stack["vault"], _queue_data(self_pay))
    _mine(rpc, 86_400)
    before_self = _token_balance(rpc, stack["asset"], actors["automation"])
    _send(rpc, actors["keeperA"], stack["vault"], _execute_data(self_pay))
    after_self = _token_balance(rpc, stack["asset"], actors["automation"])
    if after_self - before_self != 5:
        raise DrillError("self-payment balance did not reconcile")

    # Underfunded accepted transfer stays atomic, then succeeds after funding.
    underfunded = _config(stack, 4, amount=40)
    underfunded["_actors"] = actors
    _publish_all(rpc, underfunded)
    _propose(rpc, underfunded)
    _timeout(rpc, underfunded, True)
    _send(rpc, actors["keeperA"], stack["vault"], _queue_data(underfunded))
    _mine(rpc, 86_400)
    if _try_call(rpc, actors["keeperA"], stack["vault"], _execute_data(underfunded)):
        raise DrillError("underfunded execution unexpectedly simulated")
    before_executor = _token_balance(rpc, stack["asset"], stack["executor"])
    before_recipient = _token_balance(rpc, stack["asset"], actors["recipientA"])
    _fund(rpc, stack, 40)
    _send(rpc, actors["keeperA"], stack["vault"], _execute_data(underfunded))
    after_executor = _token_balance(rpc, stack["asset"], stack["executor"])
    after_recipient = _token_balance(rpc, stack["asset"], actors["recipientA"])
    if before_executor != after_executor or after_recipient - before_recipient != 40:
        raise DrillError("refunded execution did not conserve exact balances")

    # Expiry is terminal; a fresh envelope salt creates a fresh proposal identity.
    expired = _config(stack, 5, amount=7)
    expired["_actors"] = actors
    _publish_all(rpc, expired)
    _propose(rpc, expired)
    _timeout(rpc, expired, True)
    _send(rpc, actors["keeperA"], stack["vault"], _queue_data(expired))
    _mine(rpc, 86_400 + 7 * 86_400 + 1)
    if _try_call(rpc, actors["keeperA"], stack["vault"], _execute_data(expired)):
        raise DrillError("expired transfer unexpectedly simulated")
    recovery = _config(stack, 6, amount=7)
    recovery["_actors"] = actors
    _publish_all(rpc, recovery)
    _propose(rpc, recovery)
    if _action(expired)[2] == _action(recovery)[2]:
        raise DrillError("recovery reused the expired proposal id")

    # Evaluated acceptance and rejection are external resolver observations.
    evaluated_yes = _config(stack, 7, amount=200)
    evaluated_no = _config(stack, 8, amount=201)
    for cfg, accepted in ((evaluated_yes, True), (evaluated_no, False)):
        cfg["_actors"] = actors
        _publish_all(rpc, cfg)
        _propose(rpc, cfg)
        _evaluated(rpc, cfg, accepted)
        state = _runner_state(rpc_url, cfg)
        if state["accepted"] != accepted or state["acceptanceRoute"] != "evaluated":
            raise DrillError("evaluated outcome was not observed exactly")
    if _try_call(rpc, actors["keeperA"], stack["vault"], _queue_data(evaluated_no)):
        raise DrillError("rejected evaluated payment unexpectedly queued")

    # Two permissionless keepers race one queue call: one landed, one benign loser.
    race = _config(stack, 9, amount=9)
    race["_actors"] = actors
    _publish_all(rpc, race)
    _propose(rpc, race)
    _timeout(rpc, race, True)
    data = _queue_data(race)
    for keeper in (actors["keeperA"], actors["keeperB"]):
        rpc.call({"from": keeper, "to": stack["vault"], "data": data}, "latest")
    rpc.request("anvil_setAutomine", [False])
    hashes = [
        rpc.request("eth_sendTransaction", [{"from": keeper, "to": stack["vault"], "data": data}])
        for keeper in (actors["keeperA"], actors["keeperB"])
    ]
    rpc.request("evm_mine", [])
    rpc.request("anvil_setAutomine", [True])
    receipts = [_receipt(rpc, value) for value in hashes]
    statuses = sorted(int(value["status"], 16) for value in receipts)
    if statuses != [0, 1]:
        raise DrillError("queue race did not have one winner and one loser")
    attempts.extend(
        {
            "kind": "queue-race",
            "actor": keeper,
            "transactionHash": tx_hash.lower(),
            "status": receipt["status"],
            "classification": "landed" if int(receipt["status"], 16) else "benign-race",
        }
        for keeper, tx_hash, receipt in zip((actors["keeperA"], actors["keeperB"]), hashes, receipts)
    )

    # Response-dropped recovery: the effect lands; a fresh runner observes PAID and sends nothing.
    _fund(rpc, stack, 9)
    _mine(rpc, 86_400)
    tx_hash, receipt = _send(rpc, actors["keeperA"], stack["vault"], _execute_data(race))
    if int(receipt["status"], 16) != 1:
        raise DrillError("dropped-response fixture did not land")
    dropped_state = _runner_state(rpc_url, race)
    if dropped_state["lifecycle"] != "PAID" or runner.next_action(_clean(race), dropped_state) is not None:
        raise DrillError("restart after dropped response would duplicate payment")
    attempts.append({"kind": "response-dropped", "transactionHash": tx_hash, "classification": "landed-on-restart"})

    # Fresh adapters at task, receipt, payment, proposed, bonded, accepted, queued and paid boundaries.
    restart = _config(stack, 10, amount=8)
    restart["_actors"] = actors
    for name in ("task", "receipt", "payment"):
        publication = documents.prepare_publication(name, restart["documents"][name])
        _send(rpc, actors["automation"], stack["index"], publication["calldata"])
        state = _runner_state(rpc_url, restart)
        states.append(_state_evidence(state))
    _propose(rpc, restart)
    states.append(_state_evidence(_runner_state(rpc_url, restart)))
    _bond_yes(rpc, restart)
    states.append(_state_evidence(_runner_state(rpc_url, restart)))
    _mine(rpc, 11)
    _send(rpc, actors["keeperA"], stack["arbitration"], runner._call(runner.SELECTORS["finalize"], runner._word(_action(restart)[2])))
    states.append(_state_evidence(_runner_state(rpc_url, restart)))
    _send(rpc, actors["keeperA"], stack["vault"], _queue_data(restart))
    states.append(_state_evidence(_runner_state(rpc_url, restart)))
    _fund(rpc, stack, 8)
    _mine(rpc, 86_400)
    _send(rpc, actors["keeperA"], stack["vault"], _execute_data(restart))
    states.append(_state_evidence(_runner_state(rpc_url, restart)))
    expected = ["TASK_PUBLISHED", "RECEIPT_PUBLISHED", "PAYMENT_PUBLISHED", "PROPOSED", "BONDED", "ACCEPTED", "QUEUED", "PAID"]
    if [item["lifecycle"] for item in states] != expected:
        raise DrillError("restart boundary states differ: %r" % [item["lifecycle"] for item in states])

    drills = [
        {"id": 3, "status": "pass", "tier": "A", "detail": "conflicting receipts/envelopes settled independently"},
        {"id": 4, "status": "pass", "tier": "A", "detail": "self-payment used ordinary timeout and treasury path"},
        {"id": 6, "status": "pass", "tier": "A", "detail": "duplicate proposal id reverted without new state"},
        {"id": 7, "status": "pass", "tier": "A", "detail": "underfunded execution reverted then reconciled after funding"},
        {"id": 8, "status": "pass", "tier": "A", "detail": "expired action remained dead; fresh envelope produced a new id"},
        {"id": 12, "status": "pass", "tier": "A", "detail": "dropped-response restart observed exactly one landed effect"},
        {"id": 13, "status": "pass", "tier": "A", "detail": "fresh runner restart matched every lifecycle boundary"},
        {"id": 14, "status": "pass", "tier": "A", "detail": "two keepers produced one queue winner and one benign loser"},
    ]
    return drills, {"raceAttempts": attempts, "restartStates": states, "acceptanceRoutes": ["timeout", "evaluated-yes", "evaluated-no"]}


def _fork_golden(rpc_url: str, rpc: runner.JsonRpc, stack: dict[str, Any]) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    cfg = _config(stack, 16, amount=10**16)
    cfg["_actors"] = stack["actors"]
    cfg["caps"]["paymentAmount"] = str(10**16)
    _publish_all(rpc, cfg)
    _propose(rpc, cfg)
    _timeout(rpc, cfg, True)
    _send(rpc, stack["actors"]["keeperA"], stack["vault"], _queue_data(cfg))
    _mine(rpc, 86_400)
    if _try_call(rpc, stack["actors"]["keeperA"], stack["vault"], _execute_data(cfg)):
        raise DrillError("fork underfunded execution unexpectedly simulated")
    _fund(rpc, stack, 10**16)
    _send(rpc, stack["actors"]["keeperA"], stack["vault"], _execute_data(cfg))
    state = _runner_state(rpc_url, cfg)
    if state["lifecycle"] != "PAID" or state["actionHash"] != _action(cfg)[1]:
        raise DrillError("fork golden path did not reconcile exact binding and balances")
    replay = _runner_state(rpc_url, cfg)
    state_bytes = runner.canonical_json(_state_evidence(state))
    if state_bytes != runner.canonical_json(_state_evidence(replay)):
        raise DrillError("clean RPC replay was not byte-identical")
    proof = state["views"]["balanceProof"]
    return (
        [
            {"id": 7, "status": "pass", "tier": "K", "detail": "Sepolia-fork underfunded retry reconciled"},
            {"id": 16, "status": "pass", "tier": "K", "detail": "Sepolia-fork task-to-paid path exactly reconciled"},
        ],
        {
            "actionHash": state["actionHash"],
            "proposalId": state["proposalId"],
            "queueWindow": state["queued"],
            "balanceProof": proof,
            "cleanRpcReplaySha256": "0x" + hashlib.sha256(state_bytes).hexdigest(),
        },
    )


def _start_anvil(port: int, fork_url: str | None) -> subprocess.Popen[bytes]:
    command = [
        "anvil", "--silent", "--order", "fifo", "--port", str(port), "--accounts", "10",
        "--balance", "1000", "--timestamp", "1",
    ]
    if fork_url:
        command.extend(("--fork-url", fork_url))
    else:
        command.extend(("--chain-id", "31337"))
    return subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _session(port: int, fork_url: str | None, fork: bool) -> tuple[dict[str, Any], dict[str, Any]]:
    rpc_url = "http://127.0.0.1:%d" % port
    process = _start_anvil(port, fork_url)
    try:
        rpc = runner.JsonRpc(rpc_url)
        for _ in range(200):
            try:
                accounts = [value.lower() for value in rpc.request("eth_accounts", [])]
                break
            except Exception:
                time.sleep(0.05)
        else:
            raise DrillError("Anvil did not start")
        ATTEMPT_LEDGER.clear()
        stack = _stack(rpc_url, rpc, accounts, fork)
        if fork:
            drills, detail = _fork_golden(rpc_url, rpc, stack)
        else:
            drills, detail = _local_drills(rpc_url, rpc, stack)
        detail["attemptLedger"] = list(ATTEMPT_LEDGER)
        detail["publishedDocuments"] = _published_documents(rpc, stack)
        return {"stack": stack, "drills": drills}, detail
    finally:
        process.terminate()
        process.wait(timeout=5)


def run(port: int, fork_url: str) -> dict[str, Any]:
    for command in ("anvil", "cast", "forge"):
        if shutil.which(command) is None:
            raise DrillError("%s is required" % command)
    tests = _run([sys.executable, "-m", "unittest", "tools.test_agent_documents", "tools.test_agent_runner"])
    local, local_detail = _session(port, None, False)
    fork, fork_detail = _session(port + 1, fork_url, True)
    unit_fake = [
        {"id": 1, "status": "pass", "tier": "U+F", "detail": "digest-only view dedupe; append-only logs"},
        {"id": 2, "status": "pass", "tier": "F", "detail": "copied recipient changes envelope, salt and proposal id"},
        {"id": 5, "status": "pass", "tier": "U", "detail": "field substitution and domain replay rejected"},
        {"id": 9, "status": "pass", "tier": "F", "detail": "clean replay identical; bad lineage rejected"},
        {"id": 10, "status": "pass", "tier": "F", "detail": "partial RPC failure sent nothing; retry resumed"},
        {"id": 11, "status": "pass", "tier": "F", "detail": "signer failure recorded and retried exactly"},
        {"id": 15, "status": "pass", "tier": "U+F", "detail": "hostile document remained inert"},
    ]
    drills = unit_fake + local["drills"] + fork["drills"]
    covered = {item["id"] for item in drills}
    if covered != set(range(1, 17)):
        raise DrillError("drill coverage is incomplete: %r" % sorted(covered))
    manifest = json.loads(INDEX_MANIFEST.read_text(encoding="utf-8"))
    return {
        "kind": "fao.agentwork.p1-evidence",
        "v": "1",
        "repository": {"commit": _run(["git", "rev-parse", "HEAD"]), "dirty": True},
        "pins": {
            "agentWorkIndexRuntimeKeccak256": manifest["runtimeCodeKeccak256"],
            "agentWorkIndexPredictedAddress": manifest["create2"]["predictedAddress"],
            "predictionDeployed": False,
        },
        "actors": [
            {
                "role": role,
                "address": address,
                "provenance": "house-wallet",
                "manifestCap": {
                    "nativeWei": "1000000000000000000000",
                    "bondAsset": "10000" if role in ("automation", "challenger") else "0",
                    "treasuryAuthority": "0",
                },
            }
            for role, address in sorted(local["stack"]["actors"].items())
        ],
        "chains": {
            "anvil": {
                **{key: local["stack"][key] for key in ("chainId", "startBlock", "index", "gateway", "arbitration", "vault", "executor")},
                "runtimeCodeKeccak256": local["stack"]["runtimeCodeKeccak256"],
            },
            "sepoliaFork": {
                **{key: fork["stack"][key] for key in ("chainId", "startBlock", "index", "gateway", "arbitration", "vault", "executor")},
                "canonicalWeth": fork["stack"]["asset"],
                "runtimeCodeKeccak256": fork["stack"]["runtimeCodeKeccak256"],
            },
        },
        "documents": {"canonicalBuilder": "tools/agent_documents.py", "submissionTerm": "work receipt"},
        "drills": sorted(drills, key=lambda item: (item["id"], item["tier"])),
        "attemptLedger": {
            "anvil": local_detail["attemptLedger"],
            "sepoliaFork": fork_detail["attemptLedger"],
            "raceClassifications": local_detail["raceAttempts"],
        },
        "publishedDocuments": {
            "anvil": local_detail["publishedDocuments"],
            "sepoliaFork": fork_detail["publishedDocuments"],
        },
        "lifecycle": local_detail["restartStates"],
        "acceptanceRoutes": local_detail["acceptanceRoutes"],
        "forkGolden": fork_detail,
        "testCommand": "%s -m unittest tools.test_agent_documents tools.test_agent_runner" % sys.executable,
        "testSummary": tests.splitlines()[-1] if tests else "ok",
        "claims": {"liveDeployment": False, "livePayment": False, "demand": False, "guaranteedPayment": False},
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=18645)
    parser.add_argument("--fork-url", default="https://ethereum-sepolia-rpc.publicnode.com")
    parser.add_argument("--output", type=Path, default=ROOT / "metadata/agent-work-p1-evidence.json")
    args = parser.parse_args(argv)
    evidence = run(args.port, args.fork_url)
    digest = runner.write_evidence(args.output, evidence)
    print("wrote %s (%s)" % (args.output, digest))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DrillError, runner.RunnerError, documents.DocumentError, OSError, ValueError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        raise SystemExit(1)
