#!/usr/bin/env python3
"""Run the closed-world Lane 5 P2a three-agent tournament on Anvil."""

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
    from tools import agent_anvil_drill as drill
    from tools import agent_documents as documents
    from tools import agent_runner as runner
except ModuleNotFoundError:  # Direct script execution.
    import agent_anvil_drill as drill  # type: ignore
    import agent_documents as documents  # type: ignore
    import agent_runner as runner  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
EVIDENCE_PATH = ROOT / "metadata/agent-work-p2a-evidence.json"
SEPOLIA_CHAIN_ID = 11_155_111
SEPOLIA_FORK_BLOCK = 11_261_000
SEPOLIA_FORK_HASH = "0xf64a8c502030a1a1d17795b3f41cae9de07eaaa9630fa994ae9f08470d089df9"
SEPOLIA_WETH = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"
SEPOLIA_WETH_RUNTIME_HASH = "0xc864e10689f2da18833652a3b075d43106e87f0f90d95ee64f6f0b33bc026083"
T1_SEED = "FAO_P2A_T1_V1"
ONE_MILLIWETH = 10**15
PAYMENTS = {
    "A-T1": ONE_MILLIWETH,
    "A-T2": 2 * ONE_MILLIWETH,
    "A-T3": 3 * ONE_MILLIWETH,
    "B-T2": 4 * ONE_MILLIWETH,
    "C-T1": 5 * ONE_MILLIWETH,
    "C-T3": 6 * ONE_MILLIWETH,
}
ACTOR_ADDRESSES = {
    name: "0x100000000000000000000000000000000000%04x" % ordinal
    for ordinal, name in enumerate(
        ("steward", "agentA", "agentB", "agentC", "workerA", "workerB", "workerC1", "workerC3"),
        1,
    )
}
EXCLUDED_EVIDENCE = ("metadata/agent-work-p2a-evidence.json", "metadata/agent-work-p2a-evidence.json.sha256")


class TournamentError(ValueError):
    pass


class LatestRpc(runner.JsonRpc):
    """The evidence explicitly models Anvil latest, never upstream finality."""

    def finalized_block(self) -> dict[str, Any]:
        return self.block("latest")


def _run(command: Sequence[str]) -> str:
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise TournamentError("command failed: %s\n%s" % (" ".join(command), result.stderr[-3000:]))
    return result.stdout.strip()


def _quantity(value: Any) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)", value):
        raise TournamentError("invalid RPC quantity")
    return int(value, 16)


def _salt(label: str) -> str:
    if not label.startswith("p2a:"):
        raise TournamentError("P2a salts must use the p2a: namespace")
    return documents.keccak256(label.encode())


def _artifact(value: Any) -> bytes:
    return runner.canonical_json(value)


def t1_inputs() -> list[dict[str, Any]]:
    result = []
    for index in range(8):
        material = hashlib.sha256((T1_SEED + ":" + str(index)).encode()).hexdigest()
        result.append(
            {
                "index": str(index),
                "nested": {"marker": "line\n%d" % index, "parity": "even" if index % 2 == 0 else "odd"},
                "payload": material,
                "seed": T1_SEED,
            }
        )
    return result


def build_t1_artifact() -> bytes:
    vectors = [
        {
            "digest": documents.document_digest(documents.canonicalize(value)),
            "index": str(index),
            "input": value,
        }
        for index, value in enumerate(t1_inputs())
    ]
    return _artifact({"kind": "fao.agentwork.p2a.t1", "seed": T1_SEED, "v": "1", "vectors": vectors})


def grade_t1(blob: bytes) -> bool:
    try:
        return blob == build_t1_artifact()
    except (TypeError, ValueError):
        return False


def build_t2_artifact(stack: dict[str, Any]) -> bytes:
    return _artifact(
        {
            "chainId": str(stack["chainId"]),
            "forkBlock": str(stack["forkBlock"]),
            "forkBlockHash": stack["forkBlockHash"],
            "kind": "fao.agentwork.p2a.t2",
            "observationBlock": str(stack["observationBlock"]),
            "runtimeCodeKeccak256": stack["runtimeCodeKeccak256"],
            "stack": {name: stack[name] for name in ("index", "gateway", "arbitration", "vault", "executor")},
            "v": "1",
        }
    )


def grade_t2(blob: bytes, rpc: runner.JsonRpc, stack: dict[str, Any]) -> bool:
    try:
        value = json.loads(blob)
        if blob != _artifact(value) or blob != build_t2_artifact(stack):
            return False
        block = hex(int(value["observationBlock"]))
        return all(
            documents.keccak256(bytes.fromhex(rpc.request("eth_getCode", [address, block])[2:]))
            == value["runtimeCodeKeccak256"][name]
            for name, address in value["stack"].items()
        )
    except (KeyError, TypeError, ValueError, json.JSONDecodeError):
        return False


def _t3_payments(stack: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    base = {
        "v": "1",
        "kind": "fao.payment",
        "chainId": str(stack["chainId"]),
        "vault": stack["vault"],
        "asset": stack["asset"],
        "recipient": ACTOR_ADDRESSES["workerA"],
        "amount": "17",
        "task": _salt("p2a:t3:vector-task"),
        "receipt": _salt("p2a:t3:vector-receipt"),
        "salt": _salt("p2a:t3:valid-1"),
    }
    second = dict(base, recipient=ACTOR_ADDRESSES["workerC3"], amount="19", salt=_salt("p2a:t3:valid-2"))
    cross_chain = dict(base, chainId=str(stack["chainId"] + 1), salt=_salt("p2a:t3:cross-chain"))
    cross_vault = dict(base, vault="0x2000000000000000000000000000000000000001", salt=_salt("p2a:t3:cross-vault"))
    return [("valid-1", base), ("valid-2", second), ("cross-chain", cross_chain), ("cross-vault", cross_vault)]


def build_t3_artifact(stack: dict[str, Any]) -> bytes:
    vectors = []
    for label, payment in _t3_payments(stack):
        raw = documents.build_payment(payment)
        action = documents.payment_transfer_action(raw)
        valid = payment["chainId"] == str(stack["chainId"]) and payment["vault"] == stack["vault"]
        proposal = documents.transfer_hash(payment["chainId"], payment["vault"], action)
        vectors.append(
            {
                "envelope": "0x" + raw.hex(),
                "label": label,
                "proposalId": str(int(proposal, 16)),
                "salt": action["salt"],
                "valid": valid,
            }
        )
    return _artifact({"kind": "fao.agentwork.p2a.t3", "v": "1", "vectors": vectors})


def grade_t3(blob: bytes, stack: dict[str, Any]) -> bool:
    try:
        value = json.loads(blob)
        if blob != _artifact(value) or blob != build_t3_artifact(stack):
            return False
        for vector in value["vectors"]:
            raw = bytes.fromhex(vector["envelope"][2:])
            payment = documents.validate_payment(raw)
            action = documents.payment_transfer_action(raw)
            valid = True
            try:
                documents.validate_payment_binding(raw, stack["chainId"], stack["vault"], action)
            except documents.DocumentError:
                valid = False
            if valid != vector["valid"]:
                return False
            proposal = documents.transfer_hash(payment["chainId"], payment["vault"], action)
            if vector["salt"] != action["salt"] or vector["proposalId"] != str(int(proposal, 16)):
                return False
        return True
    except (KeyError, TypeError, ValueError, json.JSONDecodeError, documents.DocumentError):
        return False


def _repository_provenance(allow_dirty: bool) -> dict[str, Any]:
    pathspec = [".", *[":(exclude)" + value for value in EXCLUDED_EVIDENCE]]
    status = _run(["git", "status", "--porcelain", "--untracked-files=all", "--", *pathspec])
    dirty = bool(status)
    if dirty and not allow_dirty:
        raise TournamentError("source tree is dirty outside the two generated P2a evidence outputs")
    index = _run(["git", "ls-files", "-s", "--", *pathspec]).encode()
    return {
        "commit": _run(["git", "rev-parse", "HEAD"]),
        "dirty": dirty,
        "excludedGeneratedPaths": list(EXCLUDED_EVIDENCE),
        "sourceIndexSha256": "0x" + hashlib.sha256(index).hexdigest(),
    }


def _start_anvil(port: int, fork_url: str | None) -> subprocess.Popen[bytes]:
    command = [
        "anvil", "--silent", "--order", "fifo", "--port", str(port), "--accounts", "1",
        "--balance", "0", "--block-time", "1", "--gas-limit", "30000000",
    ]
    if fork_url:
        command.extend(("--fork-url", fork_url, "--fork-block-number", str(SEPOLIA_FORK_BLOCK)))
    else:
        command.extend(("--chain-id", "31337", "--timestamp", "1"))
    return subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def _ready(port: int) -> tuple[str, runner.JsonRpc]:
    url = "http://127.0.0.1:%d" % port
    rpc = runner.JsonRpc(url)
    for _ in range(300):
        try:
            rpc.chain_id()
            return url, rpc
        except Exception:
            time.sleep(0.05)
    raise TournamentError("Anvil did not start")


def _prepare_actors(rpc: runner.JsonRpc, fork: bool) -> None:
    for address in ACTOR_ADDRESSES.values():
        rpc.request("anvil_impersonateAccount", [address])
        rpc.request("anvil_setBalance", [address, hex(100 * 10**18)])
        nonce = _quantity(rpc.request("eth_getTransactionCount", [address, "latest"]))
        if nonce != 0:
            raise TournamentError("house actor nonce is nonzero at the pinned genesis")
    if fork:
        block = rpc.block(SEPOLIA_FORK_BLOCK)
        if block["hash"].lower() != SEPOLIA_FORK_HASH:
            raise TournamentError("Sepolia fork block hash drifted")
        runtime = rpc.request("eth_getCode", [SEPOLIA_WETH, hex(SEPOLIA_FORK_BLOCK)])
        if documents.keccak256(bytes.fromhex(runtime[2:])) != SEPOLIA_WETH_RUNTIME_HASH:
            raise TournamentError("canonical Sepolia WETH runtime hash drifted")


def _stack(url: str, rpc: runner.JsonRpc, fork: bool) -> dict[str, Any]:
    steward = ACTOR_ADDRESSES["steward"]
    start_block = _quantity(rpc.block("latest")["number"])
    if fork:
        asset = SEPOLIA_WETH
        for name in ("steward", "agentA", "agentB", "agentC"):
            drill._send(rpc, ACTOR_ADDRESSES[name], asset, "0xd0e30db0", value=10**17)
    else:
        asset = drill._deploy("src/FAOSiteToken.sol:FAOSiteToken", url, steward, (steward, str(10**24)))
        for name in ("agentA", "agentB", "agentC"):
            drill._send(rpc, steward, asset, drill._token_call("transfer(address,uint256)", ACTOR_ADDRESSES[name], 1000))

    arbitration = drill._deploy("src/FutarchyArbitration.sol:FutarchyArbitration", url, steward, (asset, "100", "10"))
    index = drill._deploy("src/AgentWorkIndex.sol:AgentWorkIndex", url, steward)
    now = _quantity(rpc.block("latest")["timestamp"])
    policy = (10**16, 10**16, 12 * ONE_MILLIWETH, 12 * ONE_MILLIWETH)
    config_arg = (
        '("P2a Tournament","P2A",%s,%s,%s,%s,%d,%d,100000000000000000000,10,'
        "1000000000000000000000,1000000000000000000,0,1000,[(%s,%d,%d,%d,%d)])"
        % (asset, steward, arbitration, index, now + 10_000, now + 20_000, asset, *policy)
    )
    vault = drill._deploy("src/GenesisVault.sol:GenesisVault", url, steward, (config_arg, "[]"))
    executor = drill._address_view(rpc, vault, "TREASURY_EXECUTOR()")
    gateway = drill._deploy(
        "src/EconGateway.sol:EconGateway", url, steward, (index, index, arbitration, vault, "1", "2")
    )
    drill._send(
        rpc, steward, arbitration,
        "0x" + runner._selector("setProposalGateway(address)") + bytes(12).hex() + gateway[2:],
    )
    rpc.request("anvil_setStorageAt", [vault, "0x1", "0x" + (2).to_bytes(32, "big").hex()])
    rpc.request(
        "anvil_setStorageAt",
        [arbitration, "0x6", "0x" + (bytes(12) + bytes.fromhex(steward[2:])).hex()],
    )
    drill._mine(rpc)
    for name in ("agentA", "agentB", "agentC"):
        drill._send(
            rpc, ACTOR_ADDRESSES[name], asset,
            drill._token_call("approve(address,uint256)", arbitration, 1000),
        )
    observation = _quantity(rpc.block("latest")["number"])
    contracts = {"index": index, "gateway": gateway, "arbitration": arbitration, "vault": vault, "executor": executor}
    fork_block = SEPOLIA_FORK_BLOCK if fork else start_block
    fork_hash = SEPOLIA_FORK_HASH if fork else rpc.block(fork_block)["hash"].lower()
    return {
        "chainId": rpc.chain_id(),
        "startBlock": start_block,
        "forkBlock": fork_block,
        "forkBlockHash": fork_hash,
        "observationBlock": observation,
        "asset": asset,
        **contracts,
        "runtimeCodeKeccak256": {
            name: documents.keccak256(bytes.fromhex(rpc.request("eth_getCode", [address, hex(observation)])[2:]))
            for name, address in contracts.items()
        },
    }


class Recorder:
    def __init__(self, rpc: runner.JsonRpc, roles: dict[str, str]) -> None:
        self.rpc = rpc
        self.roles = {address: role for role, address in roles.items()}
        self.attempts: list[dict[str, Any]] = []

    def record(self, kind: str, actor: str, target: str, data: str, tx_hash: str, receipt: dict[str, Any], proposal: str | None = None) -> str:
        gas = _quantity(receipt["gasUsed"])
        price = _quantity(receipt.get("effectiveGasPrice", "0x0"))
        item = {
            "actor": self.roles.get(actor, actor),
            "blockNumber": str(_quantity(receipt["blockNumber"])),
            "dataKeccak256": documents.keccak256(bytes.fromhex(data[2:])),
            "gasCostWei": str(gas * price),
            "gasUsed": str(gas),
            "kind": kind,
            "sequence": str(len(self.attempts) + 1),
            "status": str(_quantity(receipt["status"])),
            "target": target,
            "transactionHash": tx_hash.lower(),
        }
        if proposal is not None:
            item["proposalId"] = proposal
        self.attempts.append(item)
        return tx_hash.lower()

    def send(
        self,
        kind: str,
        actor: str,
        target: str,
        data: str,
        *,
        proposal: str | None = None,
        force: bool = False,
    ) -> tuple[str, dict[str, Any]]:
        tx = {"from": actor, "to": target, "data": data, "value": "0x0"}
        if force:
            tx["gas"] = hex(25_000_000)
        else:
            self.rpc.call(tx, "latest")
        tx_hash = self.rpc.request("eth_sendTransaction", [tx])
        receipt = drill._receipt(self.rpc, tx_hash)
        self.record(kind, actor, target, data, tx_hash, receipt, proposal)
        return tx_hash.lower(), receipt


class RunnerSender:
    def __init__(self, recorder: Recorder, actor: str, submission: str, proposal: str) -> None:
        self.recorder = recorder
        self.actor = actor
        self.submission = submission
        self.proposal = proposal
        self.receipt: dict[str, Any] | None = None

    def send(self, transaction: dict[str, Any]) -> str:
        tx_hash, self.receipt = self.recorder.send(
            "runner:" + self.submission, self.actor, transaction["to"], transaction["data"], proposal=self.proposal
        )
        return tx_hash


def _task(stack: dict[str, Any], task_id: str) -> dict[str, Any]:
    descriptions = {
        "T1": "Return the eight exact seed-derived canonicalization-vector digests.",
        "T2": "Return exact pinned stack identity and runtime-code hashes.",
        "T3": "Return exact valid and domain-mutant transfer-binding vectors.",
    }
    return {
        "v": "1", "kind": "fao.task", "chainId": str(stack["chainId"]), "vault": stack["vault"],
        "title": "P2a " + task_id, "spec": descriptions[task_id], "salt": _salt("p2a:task:" + task_id.lower()),
    }


def _submission_configs(stack: dict[str, Any], blobs: dict[str, bytes]) -> list[dict[str, Any]]:
    tasks = {name: _task(stack, name) for name in ("T1", "T2", "T3")}
    facts = [
        ("A-T1", "agentA", "T1", "agentA", "agentA", "t1"),
        ("A-T2", "agentA", "T2", "workerA", "workerA", "t2"),
        ("A-T3", "agentA", "T3", "workerA", "workerA", "t3"),
        ("B-T2", "agentB", "T2", "workerB", "workerB", "t2-wrong"),
        ("C-T1", "agentC", "T1", "workerC1", "workerC1", "t1"),
        ("C-T3", "agentC", "T3", "workerC3", "workerC3", "t3"),
    ]
    result = []
    for submission, agent, task_id, worker, recipient, blob_name in facts:
        task = tasks[task_id]
        task_digest = documents.document_digest(documents.build_task(task))
        blob = blobs[blob_name]
        artifact_digest = documents.document_digest(blob)
        receipt = {
            "v": "1", "kind": "fao.receipt", "chainId": str(stack["chainId"]), "vault": stack["vault"],
            "task": task_digest, "worker": ACTOR_ADDRESSES[worker],
            "artifacts": [{"digest": artifact_digest, "uri": "evidence:blob/" + artifact_digest}],
            "summary": "P2a exact artifact " + submission,
            "salt": _salt("p2a:receipt:" + submission.lower()),
        }
        receipt_digest = documents.document_digest(documents.build_receipt(receipt))
        payment = {
            "v": "1", "kind": "fao.payment", "chainId": str(stack["chainId"]), "vault": stack["vault"],
            "asset": stack["asset"], "recipient": ACTOR_ADDRESSES[recipient], "amount": str(PAYMENTS[submission]),
            "task": task_digest, "receipt": receipt_digest, "salt": _salt("p2a:payment:" + submission.lower()),
        }
        action = documents.payment_transfer_action(documents.build_payment(payment))
        proposal = documents.validate_payment_binding(
            documents.build_payment(payment), stack["chainId"], stack["vault"], action
        )
        result.append(
            {
                "id": submission,
                "agent": agent,
                "taskId": task_id,
                "artifact": blob_name,
                "artifactDigest": artifact_digest,
                "task": task,
                "receipt": receipt,
                "payment": payment,
                "action": action,
                "proposalId": str(int(proposal, 16)),
                "config": {
                    "chainId": stack["chainId"], "fromBlock": stack["startBlock"], "index": stack["index"],
                    "gateway": stack["gateway"], "arbitration": stack["arbitration"], "vault": stack["vault"],
                    "executor": stack["executor"], "automation": ACTOR_ADDRESSES[agent],
                    "documents": {"task": task, "receipt": receipt, "payment": payment},
                    "caps": {"paymentAmount": str(PAYMENTS[submission]), "bondAmount": "100", "transactionValue": "0"},
                },
            }
        )
    return result


def _fresh_state(url: str, submission: dict[str, Any]) -> dict[str, Any]:
    rpc = LatestRpc(url)
    cfg = submission["config"]
    return runner.derive_state(cfg, runner.collect_snapshot(rpc, cfg))


def _tick(url: str, recorder: Recorder, submission: dict[str, Any], expected: str) -> dict[str, Any]:
    sender = RunnerSender(
        recorder, ACTOR_ADDRESSES[submission["agent"]], submission["id"], submission["proposalId"]
    )
    result = runner.tick(submission["config"], LatestRpc(url), LatestRpc(url), sender)
    if result["action"] != expected or result["attempts"][0]["outcome"] != "submitted":
        raise TournamentError("%s expected %s, got %r" % (submission["id"], expected, result))
    return result


def _state_pin(label: str, url: str, submission: dict[str, Any]) -> dict[str, Any]:
    state = _fresh_state(url, submission)
    state_view = {
        "actionHash": state["actionHash"], "lifecycle": state["lifecycle"], "proposal": state["proposal"],
        "queued": state["queued"], "paid": state["paid"],
    }
    return {
        "accepted": state["accepted"],
        "blockHash": state["finalized"]["hash"],
        "blockNumber": str(state["finalized"]["number"]),
        "label": label,
        "lifecycle": state["lifecycle"],
        "stateSha256": "0x" + hashlib.sha256(runner.canonical_json(state_view)).hexdigest(),
    }


def _action_data(submission: dict[str, Any], selector: str) -> str:
    return runner._call(selector, runner._action_words(submission["action"]))


def _proposal_data(signature: str, submission: dict[str, Any], amount: int | None = None) -> str:
    words = [runner._word(int(submission["proposalId"]))]
    if amount is not None:
        words.append(runner._word(amount))
    return runner._call(runner._selector(signature), *words)


def _race_queue(rpc: runner.JsonRpc, recorder: Recorder, submission: dict[str, Any]) -> dict[str, Any]:
    data = _action_data(submission, runner.SELECTORS["queue"])
    actors = (ACTOR_ADDRESSES["agentB"], ACTOR_ADDRESSES["agentC"])
    for actor in actors:
        rpc.call({"from": actor, "to": submission["config"]["vault"], "data": data, "value": "0x0"}, "latest")
    hashes = [
        rpc.request("eth_sendTransaction", [{"from": actor, "to": submission["config"]["vault"], "data": data, "value": "0x0", "gas": hex(5_000_000)}])
        for actor in actors
    ]
    receipts = [drill._receipt(rpc, tx_hash) for tx_hash in hashes]
    for actor, tx_hash, receipt in zip(actors, hashes, receipts):
        recorder.record("queue-race:A-T3", actor, submission["config"]["vault"], data, tx_hash, receipt, submission["proposalId"])
    statuses = [_quantity(receipt["status"]) for receipt in receipts]
    if sorted(statuses) != [0, 1]:
        raise TournamentError("A-T3 queue race did not produce one winner and one benign loser")
    state = _fresh_state(rpc.url, submission)
    if not state["queued"]["executeAfter"] or runner.next_action(submission["config"], state) is not None:
        raise TournamentError("queue race loser did not observe the landed post-state")
    return {
        "loser": recorder.roles[actors[statuses.index(0)]],
        "loserClassification": "benign-post-state-verified",
        "statuses": [str(value) for value in statuses],
        "winner": recorder.roles[actors[statuses.index(1)]],
    }


def _balance(rpc: runner.JsonRpc, token: str, account: str, block: int | str = "latest") -> int:
    tag = block if isinstance(block, str) else hex(block)
    return runner._uint_call(rpc, token, runner._call(runner.SELECTORS["balanceOf"], runner._address_word(account)), tag)


def _block_timestamp(rpc: runner.JsonRpc, number: str | int) -> int:
    return _quantity(rpc.block(int(number))["timestamp"])


def _run_tournament(url: str, rpc: runner.JsonRpc, stack: dict[str, Any], repository: dict[str, Any], mode: str) -> dict[str, Any]:
    correct_t1 = build_t1_artifact()
    correct_t2 = build_t2_artifact(stack)
    wrong_t2_value = json.loads(correct_t2)
    wrong_t2_value["runtimeCodeKeccak256"]["gateway"] = "0x" + "00" * 32
    wrong_t2 = _artifact(wrong_t2_value)
    correct_t3 = build_t3_artifact(stack)
    blobs = {"t1": correct_t1, "t2": correct_t2, "t2-wrong": wrong_t2, "t3": correct_t3}
    submissions = _submission_configs(stack, blobs)
    by_id = {item["id"]: item for item in submissions}
    recorder = Recorder(rpc, ACTOR_ADDRESSES)
    task_publications: dict[str, dict[str, Any]] = {}
    start_times: dict[str, int] = {}

    for task_id in ("T1", "T2", "T3"):
        task = next(item["task"] for item in submissions if item["taskId"] == task_id)
        publication = documents.prepare_publication("task", task)
        _, receipt = recorder.send(
            "publish-task:" + task_id, ACTOR_ADDRESSES["steward"], stack["index"], publication["calldata"]
        )
        block = _quantity(receipt["blockNumber"])
        start_times[task_id] = _block_timestamp(rpc, block)
        task_publications[task_id] = {
            "digest": publication["documentDigest"], "document": "0x" + publication["document"].hex(),
            "transactionHash": recorder.attempts[-1]["transactionHash"],
        }

    round_robin: list[dict[str, Any]] = []
    restart: list[dict[str, Any]] = []
    order = [by_id[name] for name in ("A-T1", "B-T2", "C-T1", "A-T2", "C-T3", "A-T3")]
    for expected in ("publish-receipt", "publish-payment", "propose", "place-yes-bond"):
        for submission in order:
            _tick(url, recorder, submission, expected)
            round_robin.append({"action": expected, "agent": submission["agent"], "submission": submission["id"]})
            if submission["id"] == "A-T2":
                restart.append(_state_pin(expected, url, submission))

    challenge_facts = (("A-T2", "agentB"), ("B-T2", "agentA"), ("C-T1", "agentA"))
    for submission_id, challenger in challenge_facts:
        submission = by_id[submission_id]
        recorder.send(
            "challenge:" + submission_id, ACTOR_ADDRESSES[challenger], stack["arbitration"],
            _proposal_data("placeNoBond(uint256)", submission), proposal=submission["proposalId"],
        )
        if submission_id == "A-T2":
            restart.append(_state_pin("challenged", url, submission))

    grader = {
        "A-T1": {"objectiveCorrect": grade_t1(correct_t1), "original": True, "verdict": True},
        "A-T2": {"objectiveCorrect": grade_t2(correct_t2, rpc, stack), "original": True, "verdict": True},
        "A-T3": {"objectiveCorrect": grade_t3(correct_t3, stack), "original": True, "verdict": True},
        "B-T2": {"objectiveCorrect": grade_t2(wrong_t2, rpc, stack), "original": True, "verdict": False},
        "C-T1": {"objectiveCorrect": grade_t1(correct_t1), "original": False, "verdict": False},
        "C-T3": {"objectiveCorrect": grade_t3(correct_t3, stack), "original": True, "verdict": True},
    }
    if any(not grader[name]["objectiveCorrect"] for name in ("A-T1", "A-T2", "A-T3", "C-T1", "C-T3")):
        raise TournamentError("an honest artifact failed objective recomputation")
    if grader["B-T2"]["objectiveCorrect"] or correct_t1 != blobs[by_id["C-T1"]["artifact"]]:
        raise TournamentError("wrong/copy fixtures are invalid")

    evaluation_order = []
    settlement_times: dict[str, int] = {}
    for submission_id in ("A-T2", "B-T2", "C-T1"):
        submission = by_id[submission_id]
        recorder.send(
            "graduate:" + submission_id, ACTOR_ADDRESSES[submission["agent"]], stack["arbitration"],
            _proposal_data("placeYesBond(uint256,uint256)", submission, 100), proposal=submission["proposalId"],
        )
        if submission_id == "A-T2":
            restart.append(_state_pin("graduated", url, submission))
        recorder.send(
            "evaluation-start:" + submission_id, ACTOR_ADDRESSES["steward"], stack["arbitration"],
            "0x" + runner._selector("startNextEvaluation()"), proposal=submission["proposalId"],
        )
        if submission_id == "A-T2":
            restart.append(_state_pin("evaluating", url, submission))
        _, receipt = recorder.send(
            "evaluation-resolve:" + submission_id, ACTOR_ADDRESSES["steward"], stack["arbitration"],
            runner._call(runner._selector("resolveActiveEvaluation(bool)"), runner._word(1 if grader[submission_id]["verdict"] else 0)),
            proposal=submission["proposalId"],
        )
        settlement_times[submission_id] = _block_timestamp(rpc, _quantity(receipt["blockNumber"]))
        evaluation_order.append({"accepted": grader[submission_id]["verdict"], "submission": submission_id})
        if submission_id == "A-T2":
            restart.append(_state_pin("evaluated", url, submission))

    drill._mine(rpc, 11)
    for submission_id in ("A-T1", "A-T3", "C-T3"):
        submission = by_id[submission_id]
        _, receipt = recorder.send(
            "timeout:" + submission_id, ACTOR_ADDRESSES["steward"], stack["arbitration"],
            _proposal_data("finalizeByTimeout(uint256)", submission), proposal=submission["proposalId"],
        )
        settlement_times[submission_id] = _block_timestamp(rpc, _quantity(receipt["blockNumber"]))

    bond_before = {name: 10**17 if mode == "sepolia-fork" else 1000 for name in ("agentA", "agentB", "agentC")}
    bond_after = {name: _balance(rpc, stack["asset"], ACTOR_ADDRESSES[name]) for name in bond_before}
    arbitration_balance = _balance(rpc, stack["asset"], stack["arbitration"])
    withdrawable = {
        name: drill._uint(rpc, stack["arbitration"], "withdrawable(address)", ACTOR_ADDRESSES[name])
        for name in bond_before
    }
    if sum(bond_before.values()) - sum(bond_after.values()) != arbitration_balance or sum(withdrawable.values()) != arbitration_balance:
        raise TournamentError("bond balances do not conserve exactly")

    rejected_before = {
        submission_id: _balance(rpc, stack["asset"], by_id[submission_id]["payment"]["recipient"])
        for submission_id in ("B-T2", "C-T1")
    }
    for submission_id in ("A-T1", "A-T2", "C-T3"):
        _tick(url, recorder, by_id[submission_id], "queue")
        if submission_id == "A-T2":
            restart.append(_state_pin("queued", url, by_id[submission_id]))
    race = _race_queue(rpc, recorder, by_id["A-T3"])

    lineage_a = LatestRpc(url).finalized_block()
    drill._mine(rpc)
    lineage_b = LatestRpc(url).finalized_block()
    if lineage_b["parentHash"].lower() != lineage_a["hash"].lower():
        raise TournamentError("consecutive finalized-lineage snapshots are discontinuous")
    lineage = {
        "first": {"hash": lineage_a["hash"].lower(), "number": str(_quantity(lineage_a["number"]))},
        "second": {"hash": lineage_b["hash"].lower(), "number": str(_quantity(lineage_b["number"]))},
        "status": "pass",
    }

    if _balance(rpc, stack["asset"], stack["executor"]) != 0:
        raise TournamentError("executor was not empty before exact tournament funding")
    recorder.send(
        "fund-executor:initial", ACTOR_ADDRESSES["steward"], stack["asset"],
        drill._token_call("transfer(address,uint256)", stack["executor"], 6 * ONE_MILLIWETH),
    )
    drill._mine(rpc, 86_400)
    balance_proofs: dict[str, Any] = {}
    completion: dict[str, int] = {}
    for submission_id in ("A-T1", "A-T2", "A-T3"):
        _tick(url, recorder, by_id[submission_id], "execute")
        state = _fresh_state(url, by_id[submission_id])
        if state["lifecycle"] != "PAID":
            raise TournamentError(submission_id + " did not reach PAID")
        balance_proofs[submission_id] = state["views"]["balanceProof"]
        completion[submission_id] = _block_timestamp(rpc, state["finalized"]["number"])
        if submission_id == "A-T2":
            restart.append(_state_pin("paid", url, by_id[submission_id]))

    c3 = by_id["C-T3"]
    short_state = _fresh_state(url, c3)
    if short_state["lifecycle"] != "SHORTFALL":
        raise TournamentError("C-T3 did not expose the intended funding shortfall")
    before_short = {
        "executor": _balance(rpc, stack["asset"], stack["executor"]),
        "recipient": _balance(rpc, stack["asset"], c3["payment"]["recipient"]),
    }
    _, short_receipt = recorder.send(
        "execute:C-T3:shortfall", ACTOR_ADDRESSES["steward"], stack["vault"],
        _action_data(c3, runner.SELECTORS["execute"]), proposal=c3["proposalId"], force=True,
    )
    after_short = {
        "executor": _balance(rpc, stack["asset"], stack["executor"]),
        "recipient": _balance(rpc, stack["asset"], c3["payment"]["recipient"]),
    }
    if _quantity(short_receipt["status"]) != 0 or before_short != after_short:
        raise TournamentError("C-T3 shortfall was not one atomic revert")
    recorder.send(
        "fund-executor:topup", ACTOR_ADDRESSES["steward"], stack["asset"],
        drill._token_call("transfer(address,uint256)", stack["executor"], 6 * ONE_MILLIWETH),
    )
    _tick(url, recorder, c3, "execute")
    c3_state = _fresh_state(url, c3)
    if c3_state["lifecycle"] != "PAID" or _balance(rpc, stack["asset"], stack["executor"]) != 0:
        raise TournamentError("C-T3 retry did not exactly consume the top-up")
    balance_proofs["C-T3"] = c3_state["views"]["balanceProof"]
    completion["C-T3"] = _block_timestamp(rpc, c3_state["finalized"]["number"])

    rejected_after = {
        submission_id: _balance(rpc, stack["asset"], by_id[submission_id]["payment"]["recipient"])
        for submission_id in ("B-T2", "C-T1")
    }
    if rejected_before != rejected_after:
        raise TournamentError("a rejected proposal moved treasury value")
    for submission_id in ("B-T2", "C-T1"):
        completion[submission_id] = settlement_times[submission_id]

    execution_attempts = [
        item for item in recorder.attempts
        if item["kind"] in ("runner:A-T1", "runner:A-T2", "runner:A-T3", "runner:C-T3")
        and item["dataKeccak256"] in {
            documents.keccak256(bytes.fromhex(_action_data(by_id[name], runner.SELECTORS["execute"])[2:]))
            for name in ("A-T1", "A-T2", "A-T3", "C-T3")
        }
    ] + [item for item in recorder.attempts if item["kind"] == "execute:C-T3:shortfall"]
    paid = [item for item in execution_attempts if item["status"] == "1"]
    propose_selector = runner.SELECTORS["propose"]
    propose_hashes = {
        submission["id"]: documents.keccak256(bytes.fromhex(
            runner._call(propose_selector, runner._action_words(submission["action"]))[2:]
        ))
        for submission in submissions
    }
    proposal_gas = [
        {"actor": item["actor"], "gasCostWei": item["gasCostWei"], "gasUsed": item["gasUsed"], "proposalId": item["proposalId"], "submission": submission_id}
        for submission_id, calldata_hash in propose_hashes.items()
        for item in recorder.attempts
        if item["dataKeccak256"] == calldata_hash
    ]
    if len(execution_attempts) != 5 or len(paid) != 4 or len(proposal_gas) != 6:
        raise TournamentError("proposal/execution attempt matrix counts drifted")

    routes = {
        item["id"]: (_fresh_state(url, item)["acceptanceRoute"] if grader[item["id"]]["verdict"] else "evaluated-rejected")
        for item in submissions
    }
    ends = {
        item["id"]: completion.get(item["id"], _block_timestamp(rpc, _fresh_state(url, item)["finalized"]["number"]))
        for item in submissions
    }
    evidence_submissions = []
    for item in submissions:
        submission_id = item["id"]
        evidence_submissions.append(
            {
                "acceptanceRoute": routes[submission_id],
                "agent": item["agent"],
                "artifactDigest": item["artifactDigest"],
                "challenge": next((challenger for candidate, challenger in challenge_facts if candidate == submission_id), None),
                "grader": grader[submission_id],
                "id": submission_id,
                "outcome": "paid" if submission_id in ("A-T1", "A-T2", "A-T3", "C-T3") else "rejected",
                "payment": "0x" + documents.build_payment(item["payment"]).hex(),
                "paymentDigest": documents.document_digest(documents.build_payment(item["payment"])),
                "proposalId": item["proposalId"],
                "receipt": "0x" + documents.build_receipt(item["receipt"]).hex(),
                "receiptDigest": documents.document_digest(documents.build_receipt(item["receipt"])),
                "taskDigest": documents.document_digest(documents.build_task(item["task"])),
            }
        )

    counts = {
        "agents": 3, "tasks": 3, "receipts": 6, "paymentEnvelopes": 6, "proposals": 6,
        "yesBondedProposals": 6, "noBonds": 3, "evaluations": 3, "timeoutFinalizations": 3,
        "executionAttempts": 5, "payments": 4, "atomicShortfallReverts": 1,
    }
    if counts != {
        "agents": 3, "tasks": 3, "receipts": 6, "paymentEnvelopes": 6, "proposals": 6,
        "yesBondedProposals": 6, "noBonds": 3, "evaluations": 3, "timeoutFinalizations": 3,
        "executionAttempts": 5, "payments": 4, "atomicShortfallReverts": 1,
    }:
        raise TournamentError("scenario matrix drifted")

    return {
        "kind": "fao.agentwork.p2a-evidence",
        "v": "1",
        "repository": repository,
        "mode": mode,
        "finalityModel": "anvil-latest",
        "blockIntervalSeconds": "1",
        "pins": {
            "sepoliaForkBlock": str(SEPOLIA_FORK_BLOCK), "sepoliaForkBlockHash": SEPOLIA_FORK_HASH,
            "selectionFinalizedHead": "11261302",
            "selectionRule": "finalized head minus 64, rounded down to a multiple of 1000",
            "canonicalWeth": SEPOLIA_WETH, "canonicalWethRuntimeKeccak256": SEPOLIA_WETH_RUNTIME_HASH,
            "actorNonce": "0",
        },
        "stack": {
            "chainId": str(stack["chainId"]), "forkBlock": str(stack["forkBlock"]),
            "forkBlockHash": stack["forkBlockHash"], "observationBlock": str(stack["observationBlock"]),
            "asset": stack["asset"], **{name: stack[name] for name in ("index", "gateway", "arbitration", "vault", "executor")},
            "runtimeCodeKeccak256": stack["runtimeCodeKeccak256"],
        },
        "actors": [
            {
                "address": address, "label": role, "provenance": "house-wallet", "signing": "anvil-impersonated-unlocked",
                "caps": {"nativeWei": str(100 * 10**18), "bondAsset": "1000", "treasuryAuthority": "0"},
            }
            for role, address in ACTOR_ADDRESSES.items()
        ],
        "funding": {
            "assetProvenance": "canonical-WETH deposit on pinned fork" if mode == "sepolia-fork" else "valueless local FAOSiteToken",
            "executorInitial": str(6 * ONE_MILLIWETH), "executorTopup": str(6 * ONE_MILLIWETH),
            "treasurySpend": str(12 * ONE_MILLIWETH), "executorFinal": "0",
        },
        "tasks": task_publications,
        "submissions": evidence_submissions,
        "artifactBlobs": {
            documents.document_digest(blob): "0x" + blob.hex() for blob in blobs.values()
        },
        "graderPolicy": {
            "authority": "none", "resolverDriver": "steward", "copyRule": "byte-identical A-T1 copy is rejected",
        },
        "evaluationFifo": evaluation_order,
        "roundRobinTicks": round_robin,
        "attemptLedger": recorder.attempts,
        "drills": {
            "aT2FreshRunnerRestarts": restart,
            "aT3QueueRace": race,
            "cT3Shortfall": {"before": before_short, "after": after_short, "sameEnvelopeAndProposal": True, "status": "pass"},
            "finalizedLineage": lineage,
        },
        "reconciliation": {
            "balanceProofs": balance_proofs,
            "bonds": {"actorBefore": bond_before, "actorAfter": bond_after, "arbitrationBalance": str(arbitration_balance), "withdrawable": withdrawable},
            "rejectedRecipientBefore": rejected_before, "rejectedRecipientAfter": rejected_after,
        },
        "counts": counts,
        "metrics": {
            "artifactQuality": {"agentA": "3/3", "agentB": "0/1", "agentC": "1/2"},
            "challengeRate": "3/6", "falsePaymentRate": "0/4",
            "proposalGas": proposal_gas,
            "simulatedChainCompletionLatencySeconds": {
                item["id"]: str(ends[item["id"]] - start_times[item["taskId"]]) for item in submissions
            },
            "totalTreasurySpend": str(12 * ONE_MILLIWETH),
        },
        "gates": [
            {"id": "exact-documents-parentage", "status": "pass"},
            {"id": "six-bindings", "status": "pass"},
            {"id": "four-log-balance-payments", "status": "pass"},
            {"id": "rejected-no-movement", "status": "pass"},
            {"id": "actor-bond-treasury-conservation", "status": "pass"},
            {"id": "complete-attempt-ledger", "status": "pass"},
            {"id": "zero-public-broadcasts", "status": "pass"},
        ],
        "publicBroadcasts": 0,
        "observedMetadata": {"wallClockExcluded": True, "localPortExcluded": True, "processIdExcluded": True},
        "claims": {
            "externalWork": False, "demand": False, "adoption": False, "informationAggregation": False,
            "collusionResistance": False, "sustainableSubsidy": False, "liveDeployment": False, "livePayment": False,
        },
    }


def _session(port: int, fork_url: str | None, repository: dict[str, Any]) -> dict[str, Any]:
    process = _start_anvil(port, fork_url)
    try:
        url, rpc = _ready(port)
        _prepare_actors(rpc, fork_url is not None)
        drill.ATTEMPT_LEDGER.clear()
        stack = _stack(url, rpc, fork_url is not None)
        return _run_tournament(url, rpc, stack, repository, "sepolia-fork" if fork_url else "plain-local")
    finally:
        process.terminate()
        process.wait(timeout=5)


def run(port: int, fork_url: str, *, local_only: bool = False, allow_dirty: bool = False) -> dict[str, Any]:
    for command in ("anvil", "forge"):
        if shutil.which(command) is None:
            raise TournamentError(command + " is required")
    repository = _repository_provenance(allow_dirty)
    local = _session(port, None, repository)
    if local_only:
        return local
    first = _session(port + 1, fork_url, repository)
    second = _session(port + 2, fork_url, repository)
    first_raw = runner.canonical_json(first)
    second_raw = runner.canonical_json(second)
    if first_raw != second_raw:
        raise TournamentError(
            "two clean pinned-fork tournaments diverged: %s != %s"
            % (hashlib.sha256(first_raw).hexdigest(), hashlib.sha256(second_raw).hexdigest())
        )
    first["gates"].extend(
        (
            {"id": "plain-local-rehearsal", "status": "pass"},
            {"id": "two-clean-pinned-fork-digests", "status": "pass"},
        )
    )
    first["deterministicTournamentSha256"] = "0x" + hashlib.sha256(first_raw).hexdigest()
    return first


def verify_evidence(path: Path = EVIDENCE_PATH) -> str:
    raw = path.read_bytes()
    value = json.loads(raw)
    digest = "0x" + hashlib.sha256(raw).hexdigest()
    if raw != runner.canonical_json(value) + b"\n":
        raise TournamentError("P2a evidence is not canonical sorted-key compact JSON")
    if path.with_suffix(path.suffix + ".sha256").read_text(encoding="ascii").strip() != digest:
        raise TournamentError("P2a exact-byte SHA-256 sidecar drifted")
    if value.get("kind") != "fao.agentwork.p2a-evidence" or value.get("v") != "1":
        raise TournamentError("P2a evidence kind/version drifted")
    if value.get("mode") != "sepolia-fork" or value.get("finalityModel") != "anvil-latest":
        raise TournamentError("P2a evidence chain/finality model drifted")
    repository = value.get("repository", {})
    if repository.get("dirty") is not False or repository.get("excludedGeneratedPaths") != list(EXCLUDED_EVIDENCE):
        raise TournamentError("P2a source-tree provenance is not clean and explicit")
    pins = value.get("pins", {})
    if (
        pins.get("sepoliaForkBlock") != str(SEPOLIA_FORK_BLOCK)
        or pins.get("sepoliaForkBlockHash") != SEPOLIA_FORK_HASH
        or pins.get("canonicalWethRuntimeKeccak256") != SEPOLIA_WETH_RUNTIME_HASH
        or pins.get("actorNonce") != "0"
    ):
        raise TournamentError("P2a fork precondition pins drifted")
    blobs = value.get("artifactBlobs")
    if not isinstance(blobs, dict) or not blobs:
        raise TournamentError("P2a artifact blobs are missing")
    for artifact_digest, encoded in blobs.items():
        blob = bytes.fromhex(encoded[2:])
        if documents.document_digest(blob) != artifact_digest:
            raise TournamentError("P2a artifact blob digest drifted")

    stack = value["stack"]
    proposals = set()
    paid_total = 0
    submissions = value.get("submissions")
    if not isinstance(submissions, list) or len(submissions) != 6:
        raise TournamentError("P2a submission cardinality drifted")
    for submission in submissions:
        receipt_raw = bytes.fromhex(submission["receipt"][2:])
        payment_raw = bytes.fromhex(submission["payment"][2:])
        receipt = documents.validate_receipt(receipt_raw)
        payment = documents.validate_payment(payment_raw)
        if (
            documents.document_digest(receipt_raw) != submission["receiptDigest"]
            or documents.document_digest(payment_raw) != submission["paymentDigest"]
            or receipt["task"] != submission["taskDigest"]
            or payment["task"] != submission["taskDigest"]
            or payment["receipt"] != submission["receiptDigest"]
            or len(receipt["artifacts"]) != 1
            or receipt["artifacts"][0]["digest"] != submission["artifactDigest"]
            or receipt["artifacts"][0]["uri"] != "evidence:blob/" + submission["artifactDigest"]
            or submission["artifactDigest"] not in blobs
        ):
            raise TournamentError("P2a document parentage or artifact binding drifted")
        action = documents.payment_transfer_action(payment_raw)
        proposal = documents.validate_payment_binding(payment_raw, stack["chainId"], stack["vault"], action)
        proposal_id = str(int(proposal, 16))
        if proposal_id != submission["proposalId"] or proposal_id in proposals:
            raise TournamentError("P2a proposal binding is duplicated or invalid")
        proposals.add(proposal_id)
        if submission["outcome"] == "paid":
            paid_total += int(payment["amount"])
    if paid_total != 12 * ONE_MILLIWETH:
        raise TournamentError("P2a paid envelope total drifted")

    expected_counts = {
        "agents": 3, "tasks": 3, "receipts": 6, "paymentEnvelopes": 6, "proposals": 6,
        "yesBondedProposals": 6, "noBonds": 3, "evaluations": 3, "timeoutFinalizations": 3,
        "executionAttempts": 5, "payments": 4, "atomicShortfallReverts": 1,
    }
    if value.get("counts") != expected_counts or value.get("publicBroadcasts") != 0:
        raise TournamentError("P2a exact scenario counts drifted")
    gates = value.get("gates")
    if not isinstance(gates, list) or len(gates) != 9 or any(gate.get("status") != "pass" for gate in gates):
        raise TournamentError("P2a evidence contains a non-passing gate")
    if any(value.get("claims", {}).values()):
        raise TournamentError("P2a evidence overclaims its closed-world result")
    return digest


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=19645)
    parser.add_argument("--fork-url", default="https://sepolia.drpc.org")
    parser.add_argument("--local-only", action="store_true")
    parser.add_argument("--allow-dirty", action="store_true")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--output", type=Path, default=EVIDENCE_PATH)
    args = parser.parse_args(argv)
    if args.check:
        print("verified %s (%s)" % (args.output, verify_evidence(args.output)))
        return 0
    started = time.monotonic()
    evidence = run(args.port, args.fork_url, local_only=args.local_only, allow_dirty=args.allow_dirty)
    digest = runner.write_evidence(args.output, evidence)
    print("wrote %s (%s)" % (args.output, digest))
    print("observed wall time %.3fs (excluded from deterministic evidence)" % (time.monotonic() - started))
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (TournamentError, drill.DrillError, runner.RunnerError, documents.DocumentError, OSError, ValueError) as exc:
        print("error: %s" % exc, file=sys.stderr)
        raise SystemExit(1)
