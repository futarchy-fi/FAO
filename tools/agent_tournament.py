#!/usr/bin/env python3
"""Run the closed-world Lane 5 P2a three-agent tournament on Anvil."""

from __future__ import annotations

import argparse
import copy
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
SEPOLIA_FORK_TIMESTAMP = 1_783_910_556
SEPOLIA_WETH = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"
SEPOLIA_WETH_RUNTIME_HASH = "0xc864e10689f2da18833652a3b075d43106e87f0f90d95ee64f6f0b33bc026083"
PINNED_FORK_TRANSCRIPT_SHA256 = "0xf044208e85c4b634943439e0ee9673eee8cd41bd0cbb0766e87c9ff821a08292"
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
SUBMISSION_FACTS = (
    ("A-T1", "agentA", "T1", "agentA", "agentA", "t1"),
    ("A-T2", "agentA", "T2", "workerA", "workerA", "t2"),
    ("A-T3", "agentA", "T3", "workerA", "workerA", "t3"),
    ("B-T2", "agentB", "T2", "workerB", "workerB", "t2-wrong"),
    ("C-T1", "agentC", "T1", "workerC1", "workerC1", "t1"),
    ("C-T3", "agentC", "T3", "workerC3", "workerC3", "t3"),
)
EVALUATION_IDS = ("A-T2", "B-T2", "C-T1")
TIMEOUT_IDS = ("A-T1", "A-T3", "C-T3")
PAID_IDS = ("A-T1", "A-T2", "A-T3", "C-T3")
REJECTED_IDS = ("B-T2", "C-T1")
ROUND_ROBIN_IDS = ("A-T1", "B-T2", "C-T1", "A-T2", "C-T3", "A-T3")
ROUND_ROBIN_ACTIONS = ("publish-receipt", "publish-payment", "propose", "place-yes-bond")
BASE_GATE_IDS = (
    "exact-documents-parentage",
    "six-bindings",
    "four-recorded-receipt-log-balance-payments",
    "rejected-no-movement",
    "actor-bond-treasury-conservation",
    "complete-attempt-ledger",
    "zero-public-broadcasts",
)
RUN_GATE_IDS = ("plain-local-rehearsal", "two-clean-pinned-fork-digests")
EXPECTED_CHALLENGES = {
    "A-T1": None,
    "A-T2": "agentB",
    "A-T3": None,
    "B-T2": "agentA",
    "C-T1": "agentA",
    "C-T3": None,
}
EXPECTED_ROUTES = {
    "A-T1": "timeout",
    "A-T2": "evaluated",
    "A-T3": "timeout",
    "B-T2": "evaluated-rejected",
    "C-T1": "evaluated-rejected",
    "C-T3": "timeout",
}
GRADER_POLICY = {
    "authority": "none",
    "challengeRule": "challenge every failed verdict plus the disclosed correct A-T2 rival drill",
    "copyRule": "byte-identical same-task artifact after the first publication is not original",
    "resolverDriver": "steward",
    "resolverInput": "objectiveCorrect AND original",
}
FALSE_CLAIMS = {
    "externalWork": False,
    "demand": False,
    "adoption": False,
    "informationAggregation": False,
    "collusionResistance": False,
    "sustainableSubsidy": False,
    "liveDeployment": False,
    "livePayment": False,
    "cryptographicEphemeralChainAttestation": False,
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
    commit = _run(["git", "rev-parse", "HEAD"])
    return {
        "commit": commit,
        "dirty": dirty,
        "excludedGeneratedPaths": list(EXCLUDED_EVIDENCE),
        "sourceIndexSha256": _source_index_sha256(commit),
    }


def _source_index_sha256(commit: str) -> str:
    lines = _run(["git", "ls-tree", "-r", "--full-tree", commit]).splitlines()
    kept = [line for line in lines if line.split("\t", 1)[-1] not in EXCLUDED_EVIDENCE]
    return "0x" + hashlib.sha256((("\n".join(kept) + "\n") if kept else "").encode()).hexdigest()


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


def _prepare_actors(rpc: runner.JsonRpc, fork: bool, recorder: Recorder) -> None:
    rpc.request("evm_setIntervalMining", [0])
    recorder.controls.append(
        {"after": "0", "before": "1", "method": "evm_setIntervalMining", "purpose": "replace wall-clock interval mining with explicit one-second timestamps"}
    )
    automine_before = rpc.request("anvil_getAutomine", [])
    rpc.request("anvil_setAutomine", [True])
    automine_after = rpc.request("anvil_getAutomine", [])
    recorder.controls.append(
        {"after": automine_after, "before": automine_before, "method": "anvil_setAutomine", "purpose": "mine each normal transaction at its explicit next-block timestamp"}
    )
    if automine_before is not False or automine_after is not True:
        raise TournamentError("Anvil mining controls did not enter deterministic automine mode")
    for address in ACTOR_ADDRESSES.values():
        rpc.request("anvil_impersonateAccount", [address])
        recorder.mutate(
            "impersonation", address, False, True,
            "unlock fixed zero-nonce house actor without storing a private key",
        )
        native_before = _quantity(rpc.request("eth_getBalance", [address, "latest"]))
        native_after_expected = 100 * 10**18
        rpc.request("anvil_setBalance", [address, hex(native_after_expected)])
        native_after = _quantity(rpc.request("eth_getBalance", [address, "latest"]))
        recorder.mutate(
            "native-balance", address, str(native_before), str(native_after),
            "fund disposable Anvil gas only",
        )
        if native_after != native_after_expected:
            raise TournamentError("house actor native balance override failed")
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


def _next_block(
    rpc: runner.JsonRpc,
    recorder: Recorder,
    seconds: int,
    purpose: str,
    transaction_sequences: Sequence[int] = (),
) -> None:
    before = rpc.block("latest")
    timestamp = _quantity(before["timestamp"])
    next_timestamp = timestamp + seconds
    rpc.request("evm_setNextBlockTimestamp", [next_timestamp])
    recorder.controls.append(
        {
            "beforeBlock": str(_quantity(before["number"])),
            "beforeTimestamp": str(timestamp),
            "method": "evm_setNextBlockTimestamp",
            "nextTimestamp": str(next_timestamp),
            "purpose": purpose,
            "transactionSequences": [str(value) for value in transaction_sequences],
        }
    )


def _mine_ready(rpc: runner.JsonRpc, recorder: Recorder, purpose: str) -> None:
    before = rpc.block("latest")
    rpc.request("evm_mine", [])
    after = rpc.block("latest")
    recorder.controls.append(
        {
            "afterBlock": str(_quantity(after["number"])),
            "afterTimestamp": str(_quantity(after["timestamp"])),
            "beforeBlock": str(_quantity(before["number"])),
            "beforeTimestamp": str(_quantity(before["timestamp"])),
            "method": "evm_mine",
            "purpose": purpose,
        }
    )


def _mine(rpc: runner.JsonRpc, recorder: Recorder, seconds: int, purpose: str) -> None:
    _next_block(rpc, recorder, seconds, "set timestamp to " + purpose)
    _mine_ready(rpc, recorder, purpose)


def _deploy(
    contract: str,
    url: str,
    sender: str,
    recorder: Recorder,
    kind: str,
    arguments: Sequence[str] = (),
) -> str:
    _next_block(
        recorder.rpc,
        recorder,
        1,
        "set timestamp for " + kind,
        (len(recorder.attempts) + 1,),
    )
    command = [
        "forge", "create", contract, "--rpc-url", url, "--unlocked", "--from", sender,
        "--broadcast", "--gas-limit", "30000000",
    ]
    if arguments:
        command.extend(("--constructor-args", *arguments))
    output = _run(command)
    address_match = re.search(r"Deployed to:\s*(0x[0-9a-fA-F]{40})", output)
    if address_match is None:
        raise TournamentError("forge create did not report a deployment")
    address = address_match.group(1).lower()
    hash_match = re.search(r"Transaction hash:\s*(0x[0-9a-fA-F]{64})", output, re.IGNORECASE)
    tx_hash = hash_match.group(1).lower() if hash_match else None
    if tx_hash is None:
        block = recorder.rpc.request("eth_getBlockByNumber", ["latest", True])
        matches = [
            tx["hash"] for tx in block.get("transactions", [])
            if tx.get("from", "").lower() == sender.lower() and tx.get("to") is None
        ]
        if len(matches) != 1:
            raise TournamentError("deployment transaction could not be identified")
        tx_hash = matches[0].lower()
    receipt = drill._receipt(recorder.rpc, tx_hash)
    transaction = recorder.rpc.request("eth_getTransactionByHash", [tx_hash])
    if receipt.get("contractAddress", "").lower() != address or not isinstance(transaction, dict):
        raise TournamentError("deployment receipt does not bind the reported contract")
    recorder.record(
        kind, sender, address, transaction.get("input", "0x"), tx_hash, receipt,
        value=_quantity(transaction.get("value", "0x0")),
    )
    return address


def _set_storage(
    rpc: runner.JsonRpc,
    recorder: Recorder,
    target: str,
    slot: str,
    value: str,
    purpose: str,
) -> None:
    before = rpc.request("eth_getStorageAt", [target, slot, "latest"]).lower()
    rpc.request("anvil_setStorageAt", [target, slot, value])
    after = rpc.request("eth_getStorageAt", [target, slot, "latest"]).lower()
    recorder.mutate("storage", target + ":" + slot, before, after, purpose)
    if after != value.lower():
        raise TournamentError("Anvil storage override failed")


def _stack(url: str, rpc: runner.JsonRpc, fork: bool, recorder: Recorder) -> dict[str, Any]:
    steward = ACTOR_ADDRESSES["steward"]
    start = rpc.block("latest")
    start_block = _quantity(start["number"])
    start_timestamp = _quantity(start["timestamp"])
    if fork:
        asset = SEPOLIA_WETH
        for name in ("steward", "agentA", "agentB", "agentC"):
            recorder.send(
                "setup:weth-deposit:" + name, ACTOR_ADDRESSES[name], asset, "0xd0e30db0", value=10**17
            )
    else:
        asset = _deploy(
            "src/FAOSiteToken.sol:FAOSiteToken", url, steward, recorder, "setup:deploy:asset",
            (steward, str(10**24)),
        )
        for name in ("agentA", "agentB", "agentC"):
            recorder.send(
                "setup:token-transfer:" + name, steward, asset,
                drill._token_call("transfer(address,uint256)", ACTOR_ADDRESSES[name], 1000),
            )

    arbitration = _deploy(
        "src/FutarchyArbitration.sol:FutarchyArbitration", url, steward, recorder,
        "setup:deploy:arbitration", (asset, "100", "10"),
    )
    index = _deploy(
        "src/AgentWorkIndex.sol:AgentWorkIndex", url, steward, recorder, "setup:deploy:index"
    )
    now = _quantity(rpc.block("latest")["timestamp"])
    policy = (10**16, 10**16, 12 * ONE_MILLIWETH, 12 * ONE_MILLIWETH)
    config_arg = (
        '("P2a Tournament","P2A",%s,%s,%s,%s,%d,%d,100000000000000000000,10,'
        "1000000000000000000000,1000000000000000000,0,1000,[(%s,%d,%d,%d,%d)])"
        % (asset, steward, arbitration, index, now + 10_000, now + 20_000, asset, *policy)
    )
    vault = _deploy(
        "src/GenesisVault.sol:GenesisVault", url, steward, recorder, "setup:deploy:vault",
        (config_arg, "[]"),
    )
    executor = drill._address_view(rpc, vault, "TREASURY_EXECUTOR()")
    gateway = _deploy(
        "src/EconGateway.sol:EconGateway", url, steward, recorder, "setup:deploy:gateway",
        (index, index, arbitration, vault, "1", "2"),
    )
    recorder.send(
        "setup:set-proposal-gateway", steward, arbitration,
        "0x" + runner._selector("setProposalGateway(address)") + bytes(12).hex() + gateway[2:],
    )
    _set_storage(
        rpc, recorder, vault, "0x1", "0x" + (2).to_bytes(32, "big").hex(),
        "put the disposable vault in the ruled active test phase",
    )
    _set_storage(
        rpc, recorder, arbitration, "0x6",
        "0x" + (bytes(12) + bytes.fromhex(steward[2:])).hex(),
        "bind the disposable house resolver without deploying a new evaluator",
    )
    _mine(rpc, recorder, 1, "commit Anvil storage overrides")
    for name in ("agentA", "agentB", "agentC"):
        recorder.send(
            "setup:approve:" + name, ACTOR_ADDRESSES[name], asset,
            drill._token_call("approve(address,uint256)", arbitration, 1000),
        )
    observation = _quantity(rpc.block("latest")["number"])
    min_activation_bond = drill._uint(rpc, gateway, "treasuryMinActivationBond()")
    contracts = {"index": index, "gateway": gateway, "arbitration": arbitration, "vault": vault, "executor": executor}
    fork_block = SEPOLIA_FORK_BLOCK if fork else start_block
    fork_hash = SEPOLIA_FORK_HASH if fork else rpc.block(fork_block)["hash"].lower()
    return {
        "chainId": rpc.chain_id(),
        "startBlock": start_block,
        "startTimestamp": start_timestamp,
        "forkBlock": fork_block,
        "forkBlockHash": fork_hash,
        "observationBlock": observation,
        "asset": asset,
        "minActivationBond": min_activation_bond,
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
        self.mutations: list[dict[str, Any]] = []
        self.controls: list[dict[str, Any]] = []

    def mutate(self, kind: str, target: str, before: Any, after: Any, purpose: str) -> None:
        self.mutations.append(
            {
                "after": after,
                "before": before,
                "kind": kind,
                "purpose": purpose,
                "sequence": str(len(self.mutations) + 1),
                "target": target,
            }
        )

    def record(
        self,
        kind: str,
        actor: str,
        target: str,
        data: str,
        tx_hash: str,
        receipt: dict[str, Any],
        proposal: str | None = None,
        *,
        value: int = 0,
    ) -> str:
        gas = _quantity(receipt["gasUsed"])
        price = _quantity(receipt.get("effectiveGasPrice", "0x0"))
        block_number = _quantity(receipt["blockNumber"])
        transaction = self.rpc.request("eth_getTransactionByHash", [tx_hash])
        if not isinstance(transaction, dict):
            raise TournamentError("recorded transaction disappeared before evidence capture")
        transaction_view = {
            "blockHash": transaction["blockHash"].lower(),
            "blockNumber": str(_quantity(transaction["blockNumber"])),
            "from": transaction["from"].lower(),
            "gasLimit": str(_quantity(transaction["gas"])),
            "hash": transaction["hash"].lower(),
            "input": transaction["input"].lower(),
            "nonce": str(_quantity(transaction["nonce"])),
            "to": None if transaction.get("to") is None else transaction["to"].lower(),
            "transactionIndex": str(_quantity(transaction["transactionIndex"])),
            "type": str(_quantity(transaction.get("type", "0x0"))),
            "valueWei": str(_quantity(transaction["value"])),
        }
        receipt_logs = [
            {
                "address": log["address"].lower(),
                "blockHash": log["blockHash"].lower(),
                "blockNumber": str(_quantity(log["blockNumber"])),
                "data": log["data"].lower(),
                "logIndex": str(_quantity(log["logIndex"])),
                "removed": bool(log["removed"]),
                "topics": [topic.lower() for topic in log["topics"]],
                "transactionHash": log["transactionHash"].lower(),
                "transactionIndex": str(_quantity(log["transactionIndex"])),
            }
            for log in receipt.get("logs", [])
        ]
        receipt_view = {
            "blockHash": receipt["blockHash"].lower(),
            "blockNumber": str(block_number),
            "contractAddress": None if receipt.get("contractAddress") is None else receipt["contractAddress"].lower(),
            "effectiveGasPriceWei": str(price),
            "gasUsed": str(gas),
            "logs": receipt_logs,
            "status": str(_quantity(receipt["status"])),
            "transactionHash": receipt["transactionHash"].lower(),
            "transactionIndex": str(_quantity(receipt["transactionIndex"])),
        }
        item = {
            "actor": self.roles.get(actor, actor),
            "blockHash": receipt["blockHash"].lower(),
            "blockNumber": str(block_number),
            "blockTimestamp": str(_block_timestamp(self.rpc, block_number)),
            "dataKeccak256": documents.keccak256(bytes.fromhex(data[2:])),
            "effectiveGasPriceWei": str(price),
            "gasCostWei": str(gas * price),
            "gasUsed": str(gas),
            "kind": kind,
            "sequence": str(len(self.attempts) + 1),
            "status": str(_quantity(receipt["status"])),
            "target": target,
            "transactionHash": tx_hash.lower(),
            "transaction": transaction_view,
            "receipt": receipt_view,
            "valueWei": str(value),
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
        value: int = 0,
    ) -> tuple[str, dict[str, Any]]:
        tx = {"from": actor, "to": target, "data": data, "value": hex(value)}
        if force:
            tx["gas"] = hex(25_000_000)
        else:
            self.rpc.call(tx, "latest")
        _next_block(
            self.rpc,
            self,
            1,
            "set timestamp for " + kind,
            (len(self.attempts) + 1,),
        )
        tx_hash = self.rpc.request("eth_sendTransaction", [tx])
        receipt = drill._receipt(self.rpc, tx_hash)
        self.record(kind, actor, target, data, tx_hash, receipt, proposal, value=value)
        return tx_hash.lower(), receipt


class RunnerSender:
    def __init__(self, recorder: Recorder, actor: str, submission: str, proposal: str, operation: str) -> None:
        self.recorder = recorder
        self.actor = actor
        self.submission = submission
        self.proposal = proposal
        self.operation = operation
        self.receipt: dict[str, Any] | None = None

    def send(self, transaction: dict[str, Any]) -> str:
        tx_hash, self.receipt = self.recorder.send(
            self.operation + ":" + self.submission,
            self.actor,
            transaction["to"],
            transaction["data"],
            proposal=self.proposal,
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
    result = []
    for submission, agent, task_id, worker, recipient, blob_name in SUBMISSION_FACTS:
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
        recorder,
        ACTOR_ADDRESSES[submission["agent"]],
        submission["id"],
        submission["proposalId"],
        expected,
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
        "stateView": state_view,
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
    automine_before = rpc.request("anvil_getAutomine", [])
    rpc.request("anvil_setAutomine", [False])
    automine_disabled = rpc.request("anvil_getAutomine", [])
    recorder.controls.append(
        {"after": automine_disabled, "before": automine_before, "method": "anvil_setAutomine", "purpose": "place both A-T3 queue attempts in one FIFO-ordered block"}
    )
    next_sequence = len(recorder.attempts) + 1
    _next_block(
        rpc,
        recorder,
        1,
        "set timestamp for same-block A-T3 queue race",
        (next_sequence, next_sequence + 1),
    )
    hashes = [
        rpc.request("eth_sendTransaction", [{"from": actor, "to": submission["config"]["vault"], "data": data, "value": "0x0", "gas": hex(5_000_000)}])
        for actor in actors
    ]
    _mine_ready(rpc, recorder, "mine same-block A-T3 queue race")
    rpc.request("anvil_setAutomine", [True])
    automine_after = rpc.request("anvil_getAutomine", [])
    recorder.controls.append(
        {"after": automine_after, "before": automine_disabled, "method": "anvil_setAutomine", "purpose": "restore normal deterministic transaction mining after the race"}
    )
    if (automine_before, automine_disabled, automine_after) != (True, False, True):
        raise TournamentError("A-T3 race automine controls drifted")
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
        "blockNumber": str(_quantity(receipts[0]["blockNumber"])),
        "loser": recorder.roles[actors[statuses.index(0)]],
        "loserClassification": "benign-post-state-verified",
        "proposalId": submission["proposalId"],
        "statuses": [str(value) for value in statuses],
        "transactionHashes": [value.lower() for value in hashes],
        "winner": recorder.roles[actors[statuses.index(1)]],
    }


def _balance(rpc: runner.JsonRpc, token: str, account: str, block: int | str = "latest") -> int:
    tag = block if isinstance(block, str) else hex(block)
    return runner._uint_call(rpc, token, runner._call(runner.SELECTORS["balanceOf"], runner._address_word(account)), tag)


def _balance_snapshot(rpc: runner.JsonRpc, token: str, account: str) -> dict[str, str]:
    block = rpc.block("latest")
    number = _quantity(block["number"])
    return {
        "account": account,
        "asset": token,
        "balance": str(_balance(rpc, token, account, number)),
        "blockHash": block["hash"].lower(),
        "blockNumber": str(number),
    }


def _block_timestamp(rpc: runner.JsonRpc, number: str | int) -> int:
    return _quantity(rpc.block(int(number))["timestamp"])


def _attempt(
    kind: str,
    actor: str,
    target: str,
    data: str | None = None,
    *,
    proposal: str | None = None,
    status: str = "1",
    value: int = 0,
) -> dict[str, str]:
    item = {"actor": actor, "kind": kind, "status": status, "target": target, "valueWei": str(value)}
    if data is not None:
        item["dataKeccak256"] = documents.keccak256(bytes.fromhex(data[2:]))
    if proposal is not None:
        item["proposalId"] = proposal
    return item


def _expected_attempts(
    mode: str, stack: dict[str, Any], submissions: list[dict[str, Any]]
) -> list[dict[str, str]]:
    by_id = {item["id"]: item for item in submissions}
    steward = ACTOR_ADDRESSES["steward"]
    result: list[dict[str, str]] = []
    if mode == "sepolia-fork":
        result.extend(
            _attempt("setup:weth-deposit:" + role, role, stack["asset"], "0xd0e30db0", value=10**17)
            for role in ("steward", "agentA", "agentB", "agentC")
        )
    else:
        result.append(_attempt("setup:deploy:asset", "steward", stack["asset"]))
        result.extend(
            _attempt(
                "setup:token-transfer:" + role,
                "steward",
                stack["asset"],
                drill._token_call("transfer(address,uint256)", ACTOR_ADDRESSES[role], 1000),
            )
            for role in ("agentA", "agentB", "agentC")
        )
    result.extend(
        (
            _attempt("setup:deploy:arbitration", "steward", stack["arbitration"]),
            _attempt("setup:deploy:index", "steward", stack["index"]),
            _attempt("setup:deploy:vault", "steward", stack["vault"]),
            _attempt("setup:deploy:gateway", "steward", stack["gateway"]),
            _attempt(
                "setup:set-proposal-gateway",
                "steward",
                stack["arbitration"],
                "0x" + runner._selector("setProposalGateway(address)") + bytes(12).hex() + stack["gateway"][2:],
            ),
        )
    )
    result.extend(
        _attempt(
            "setup:approve:" + role,
            role,
            stack["asset"],
            drill._token_call("approve(address,uint256)", stack["arbitration"], 1000),
        )
        for role in ("agentA", "agentB", "agentC")
    )
    for task_id in ("T1", "T2", "T3"):
        task = next(item["task"] for item in submissions if item["taskId"] == task_id)
        result.append(
            _attempt(
                "publish-task:" + task_id,
                "steward",
                stack["index"],
                documents.prepare_publication("task", task)["calldata"],
            )
        )
    for operation in ROUND_ROBIN_ACTIONS:
        for submission_id in ROUND_ROBIN_IDS:
            submission = by_id[submission_id]
            actor = submission["agent"]
            if operation.startswith("publish-"):
                document_type = operation.removeprefix("publish-")
                data = documents.prepare_publication(document_type, submission[document_type])["calldata"]
                target = stack["index"]
            elif operation == "propose":
                data = _action_data(submission, runner.SELECTORS["propose"])
                target = stack["gateway"]
            else:
                data = _proposal_data(
                    "placeYesBond(uint256,uint256)", submission, int(stack["minActivationBond"])
                )
                target = stack["arbitration"]
            result.append(
                _attempt(operation + ":" + submission_id, actor, target, data, proposal=submission["proposalId"])
            )
    challengers = {"A-T2": "agentB", "B-T2": "agentA", "C-T1": "agentA"}
    for submission_id in EVALUATION_IDS:
        submission = by_id[submission_id]
        result.append(
            _attempt(
                "challenge:" + submission_id,
                challengers[submission_id],
                stack["arbitration"],
                _proposal_data("placeNoBond(uint256)", submission),
                proposal=submission["proposalId"],
            )
        )
    verdicts = {"A-T2": True, "B-T2": False, "C-T1": False}
    for queue_index, submission_id in enumerate(EVALUATION_IDS):
        submission = by_id[submission_id]
        result.append(
            _attempt(
                "graduate:" + submission_id,
                submission["agent"],
                stack["arbitration"],
                _proposal_data("placeYesBond(uint256,uint256)", submission, 100 * (2**queue_index)),
                proposal=submission["proposalId"],
            )
        )
    for submission_id in EVALUATION_IDS:
        submission = by_id[submission_id]
        result.extend(
            (
                _attempt(
                    "evaluation-start:" + submission_id,
                    "steward",
                    stack["arbitration"],
                    "0x" + runner._selector("startNextEvaluation()"),
                    proposal=submission["proposalId"],
                ),
                _attempt(
                    "evaluation-resolve:" + submission_id,
                    "steward",
                    stack["arbitration"],
                    runner._call(
                        runner._selector("resolveActiveEvaluation(bool)"),
                        runner._word(1 if verdicts[submission_id] else 0),
                    ),
                    proposal=submission["proposalId"],
                ),
            )
        )
    for submission_id in TIMEOUT_IDS:
        submission = by_id[submission_id]
        result.append(
            _attempt(
                "timeout:" + submission_id,
                "steward",
                stack["arbitration"],
                _proposal_data("finalizeByTimeout(uint256)", submission),
                proposal=submission["proposalId"],
            )
        )
    for submission_id in ("A-T1", "A-T2", "C-T3"):
        submission = by_id[submission_id]
        result.append(
            _attempt(
                "queue:" + submission_id,
                submission["agent"],
                stack["vault"],
                _action_data(submission, runner.SELECTORS["queue"]),
                proposal=submission["proposalId"],
            )
        )
    a3 = by_id["A-T3"]
    result.extend(
        _attempt(
            "queue-race:A-T3",
            actor,
            stack["vault"],
            _action_data(a3, runner.SELECTORS["queue"]),
            proposal=a3["proposalId"],
            status=status,
        )
        for actor, status in (("agentB", "1"), ("agentC", "0"))
    )
    result.append(
        _attempt(
            "fund-executor:initial",
            "steward",
            stack["asset"],
            drill._token_call("transfer(address,uint256)", stack["executor"], 6 * ONE_MILLIWETH),
        )
    )
    for submission_id in ("A-T1", "A-T2", "A-T3"):
        submission = by_id[submission_id]
        result.append(
            _attempt(
                "execute:" + submission_id,
                submission["agent"],
                stack["vault"],
                _action_data(submission, runner.SELECTORS["execute"]),
                proposal=submission["proposalId"],
            )
        )
    c3 = by_id["C-T3"]
    result.extend(
        (
            _attempt(
                "execute:C-T3:shortfall",
                "steward",
                stack["vault"],
                _action_data(c3, runner.SELECTORS["execute"]),
                proposal=c3["proposalId"],
                status="0",
            ),
            _attempt(
                "fund-executor:topup",
                "steward",
                stack["asset"],
                drill._token_call("transfer(address,uint256)", stack["executor"], 6 * ONE_MILLIWETH),
            ),
            _attempt(
                "execute:C-T3",
                "agentC",
                stack["vault"],
                _action_data(c3, runner.SELECTORS["execute"]),
                proposal=c3["proposalId"],
            ),
        )
    )
    return result


def _attempt_ledger_valid(
    ledger: Any, mode: str, stack: dict[str, Any], submissions: list[dict[str, Any]]
) -> bool:
    expected = _expected_attempts(mode, stack, submissions)
    required = {
        "actor", "blockHash", "blockNumber", "blockTimestamp", "dataKeccak256", "gasCostWei",
        "effectiveGasPriceWei", "gasUsed", "kind", "receipt", "sequence", "status", "target",
        "transaction", "transactionHash", "valueWei",
    }
    if not isinstance(ledger, list) or len(ledger) != len(expected):
        return False
    hashes: set[str] = set()
    last_block = last_timestamp = -1
    block_facts: dict[str, tuple[str, str]] = {}
    block_transaction_counts: dict[str, int] = {}
    actor_nonces = {role: 0 for role in ACTOR_ADDRESSES}
    transaction_fields = {
        "blockHash", "blockNumber", "from", "gasLimit", "hash", "input", "nonce", "to",
        "transactionIndex", "type", "valueWei",
    }
    receipt_fields = {
        "blockHash", "blockNumber", "contractAddress", "effectiveGasPriceWei", "gasUsed", "logs",
        "status", "transactionHash", "transactionIndex",
    }
    log_fields = {
        "address", "blockHash", "blockNumber", "data", "logIndex", "removed", "topics",
        "transactionHash", "transactionIndex",
    }
    for index, (actual, wanted) in enumerate(zip(ledger, expected), 1):
        expected_fields = required | ({"proposalId"} if "proposalId" in wanted else set())
        if not isinstance(actual, dict) or set(actual) != expected_fields or actual["sequence"] != str(index):
            return False
        if any(actual.get(key) != value for key, value in wanted.items()):
            return False
        transaction, receipt = actual["transaction"], actual["receipt"]
        if (
            not isinstance(transaction, dict)
            or set(transaction) != transaction_fields
            or not isinstance(receipt, dict)
            or set(receipt) != receipt_fields
            or not re.fullmatch(r"0x[0-9a-f]{64}", actual["transactionHash"])
            or not re.fullmatch(r"0x[0-9a-f]{64}", actual["dataKeccak256"])
        ):
            return False
        if actual["transactionHash"] in hashes or not re.fullmatch(r"0x[0-9a-f]{64}", actual["blockHash"]):
            return False
        hashes.add(actual["transactionHash"])
        try:
            block = int(actual["blockNumber"])
            timestamp = int(actual["blockTimestamp"])
            gas = int(actual["gasUsed"])
            price = int(actual["effectiveGasPriceWei"])
            cost = int(actual["gasCostWei"])
            value = int(actual["valueWei"])
            gas_limit = int(transaction["gasLimit"])
            nonce = int(transaction["nonce"])
            transaction_index = int(transaction["transactionIndex"])
            int(transaction["type"])
        except (TypeError, ValueError):
            return False
        deploy = actual["kind"].startswith("setup:deploy:")
        expected_to = None if deploy else actual["target"]
        expected_contract = actual["target"] if deploy else None
        if (
            block < last_block
            or timestamp < last_timestamp
            or gas <= 0
            or price < 0
            or cost != gas * price
            or gas_limit < gas
            or nonce != actor_nonces[actual["actor"]]
            or transaction["from"] != ACTOR_ADDRESSES[actual["actor"]]
            or transaction["to"] != expected_to
            or transaction["valueWei"] != str(value)
            or transaction["hash"] != actual["transactionHash"]
            or transaction["blockHash"] != actual["blockHash"]
            or transaction["blockNumber"] != actual["blockNumber"]
            or transaction["input"] == "0x"
            or documents.keccak256(bytes.fromhex(transaction["input"][2:])) != actual["dataKeccak256"]
            or receipt["transactionHash"] != actual["transactionHash"]
            or receipt["blockHash"] != actual["blockHash"]
            or receipt["blockNumber"] != actual["blockNumber"]
            or receipt["transactionIndex"] != transaction["transactionIndex"]
            or receipt["transactionIndex"] != str(transaction_index)
            or receipt["contractAddress"] != expected_contract
            or receipt["effectiveGasPriceWei"] != actual["effectiveGasPriceWei"]
            or receipt["gasUsed"] != actual["gasUsed"]
            or receipt["status"] != actual["status"]
            or not isinstance(receipt["logs"], list)
            or transaction_index != block_transaction_counts.get(actual["blockNumber"], 0)
        ):
            return False
        block_transaction_counts[actual["blockNumber"]] = transaction_index + 1
        actor_nonces[actual["actor"]] += 1
        last_log_index = -1
        for log in receipt["logs"]:
            if not isinstance(log, dict) or set(log) != log_fields:
                return False
            try:
                log_index = int(log["logIndex"])
            except (TypeError, ValueError):
                return False
            if (
                log_index <= last_log_index
                or log["removed"] is not False
                or not re.fullmatch(r"0x[0-9a-f]{40}", log["address"])
                or not re.fullmatch(r"0x(?:[0-9a-f]{2})*", log["data"])
                or not isinstance(log["topics"], list)
                or any(not re.fullmatch(r"0x[0-9a-f]{64}", topic) for topic in log["topics"])
                or log["blockHash"] != actual["blockHash"]
                or log["blockNumber"] != actual["blockNumber"]
                or log["transactionHash"] != actual["transactionHash"]
                or log["transactionIndex"] != transaction["transactionIndex"]
            ):
                return False
            last_log_index = log_index
        fact = (actual["blockHash"], actual["blockTimestamp"])
        if actual["blockNumber"] in block_facts and block_facts[actual["blockNumber"]] != fact:
            return False
        block_facts[actual["blockNumber"]] = fact
        last_block, last_timestamp = block, timestamp
    return True


def _controls_valid(value: dict[str, Any]) -> bool:
    ledger = value.get("attemptLedger")
    stack = value.get("stack", {})
    if not isinstance(ledger, list):
        return False
    try:
        block = int(stack["startBlock"])
        timestamp = int(stack["startTimestamp"])
    except (KeyError, TypeError, ValueError):
        return False
    expected: list[dict[str, Any]] = [
        {"after": "0", "before": "1", "method": "evm_setIntervalMining", "purpose": "replace wall-clock interval mining with explicit one-second timestamps"},
        {"after": True, "before": False, "method": "anvil_setAutomine", "purpose": "mine each normal transaction at its explicit next-block timestamp"},
    ]

    def set_next(seconds: int, purpose: str, sequences: Sequence[int] = ()) -> None:
        nonlocal timestamp
        expected.append(
            {
                "beforeBlock": str(block),
                "beforeTimestamp": str(timestamp),
                "method": "evm_setNextBlockTimestamp",
                "nextTimestamp": str(timestamp + seconds),
                "purpose": purpose,
                "transactionSequences": [str(value) for value in sequences],
            }
        )
        timestamp += seconds

    def mine(seconds: int, purpose: str) -> None:
        nonlocal block
        before_timestamp = timestamp
        set_next(seconds, "set timestamp to " + purpose)
        expected.append(
            {
                "afterBlock": str(block + 1),
                "afterTimestamp": str(timestamp),
                "beforeBlock": str(block),
                "beforeTimestamp": str(before_timestamp),
                "method": "evm_mine",
                "purpose": purpose,
            }
        )
        block += 1

    index = 0
    while index < len(ledger):
        sequence = index + 1
        if sequence == 10:
            mine(1, "commit Anvil storage overrides")
        if sequence == 52:
            mine(11, "advance arbitration timeout")
        if sequence == 60:
            mine(1, "capture consecutive finalized-lineage snapshot")
        if sequence == 61:
            mine(86_400, "advance treasury execution grace")
        attempt = ledger[index]
        if sequence == 58:
            expected.append(
                {"after": False, "before": True, "method": "anvil_setAutomine", "purpose": "place both A-T3 queue attempts in one FIFO-ordered block"}
            )
            set_next(1, "set timestamp for same-block A-T3 queue race", (58, 59))
            expected.append(
                {
                    "afterBlock": str(block + 1),
                    "afterTimestamp": str(timestamp),
                    "beforeBlock": str(block),
                    "beforeTimestamp": str(timestamp - 1),
                    "method": "evm_mine",
                    "purpose": "mine same-block A-T3 queue race",
                }
            )
            block += 1
            expected.append(
                {"after": True, "before": False, "method": "anvil_setAutomine", "purpose": "restore normal deterministic transaction mining after the race"}
            )
            if any(
                item["blockNumber"] != str(block) or item["blockTimestamp"] != str(timestamp)
                for item in ledger[index : index + 2]
            ):
                return False
            index += 2
            continue
        set_next(1, "set timestamp for " + attempt["kind"], (sequence,))
        block += 1
        if attempt["blockNumber"] != str(block) or attempt["blockTimestamp"] != str(timestamp):
            return False
        index += 1
    return value.get("anvilControls") == expected


def _state_mutations_valid(value: dict[str, Any]) -> bool:
    mutations = value.get("anvilStateMutations")
    if not isinstance(mutations, list) or len(mutations) != 18:
        return False
    for index, address in enumerate(ACTOR_ADDRESSES.values()):
        impersonation, native = mutations[index * 2 : index * 2 + 2]
        if impersonation != {
            "after": True,
            "before": False,
            "kind": "impersonation",
            "purpose": "unlock fixed zero-nonce house actor without storing a private key",
            "sequence": str(index * 2 + 1),
            "target": address,
        }:
            return False
        if (
            native.get("kind") != "native-balance"
            or native.get("target") != address
            or native.get("before") != "0"
            or native.get("after") != str(100 * 10**18)
            or native.get("purpose") != "fund disposable Anvil gas only"
            or native.get("sequence") != str(index * 2 + 2)
        ):
            return False
    storage = mutations[-2:]
    expected_storage = (
        (
            value["stack"]["vault"] + ":0x1",
            "0x" + (2).to_bytes(32, "big").hex(),
            "put the disposable vault in the ruled active test phase",
        ),
        (
            value["stack"]["arbitration"] + ":0x6",
            "0x" + (bytes(12) + bytes.fromhex(ACTOR_ADDRESSES["steward"][2:])).hex(),
            "bind the disposable house resolver without deploying a new evaluator",
        ),
    )
    for offset, (item, (target, after, purpose)) in enumerate(zip(storage, expected_storage), 17):
        if (
            item.get("kind") != "storage"
            or item.get("target") != target
            or item.get("after") != after
            or item.get("purpose") != purpose
            or item.get("sequence") != str(offset)
            or item.get("before") != "0x" + "00" * 32
        ):
            return False
    return _controls_valid(value)


def _bound_balance_proof(
    proof: dict[str, Any],
    attempt: dict[str, Any],
    submission: dict[str, Any],
    stack: dict[str, Any],
) -> dict[str, str]:
    proposal_topic = "0x" + int(submission["proposalId"]).to_bytes(32, "big").hex()
    asset_topic = "0x" + bytes(12).hex() + submission["payment"]["asset"][2:]
    recipient_topic = "0x" + bytes(12).hex() + submission["payment"]["recipient"][2:]
    amount_data = "0x" + int(submission["payment"]["amount"]).to_bytes(32, "big").hex()
    logs = [
        log for log in attempt["receipt"]["logs"]
        if log["address"] == stack["vault"]
        and log["topics"] == [runner.TOPICS["executed"], proposal_topic, asset_topic, recipient_topic]
        and log["data"] == amount_data
    ]
    if len(logs) != 1:
        raise TournamentError("paid attempt lacks one exact recorded execution log")
    return {
        "afterBlock": attempt["blockNumber"],
        "amount": submission["payment"]["amount"],
        "asset": submission["payment"]["asset"],
        "beforeBlock": str(int(attempt["blockNumber"]) - 1),
        "executionBlockHash": attempt["blockHash"],
        "executionLogIndex": logs[0]["logIndex"],
        "executionTransactionHash": attempt["transactionHash"],
        "executor": stack["executor"],
        "executorAfter": str(proof["executorAfter"]),
        "executorBefore": str(proof["executorBefore"]),
        "proposalId": submission["proposalId"],
        "recipient": submission["payment"]["recipient"],
        "recipientAfter": str(proof["recipientAfter"]),
        "recipientBefore": str(proof["recipientBefore"]),
    }


def _balance_proofs_valid(
    proofs: Any,
    submissions: dict[str, dict[str, Any]],
    ledger: list[dict[str, Any]],
    stack: dict[str, Any],
) -> bool:
    if not isinstance(proofs, dict) or set(proofs) != set(PAID_IDS):
        return False
    attempts = {item["kind"]: item for item in ledger if item["kind"] != "queue-race:A-T3"}
    for submission_id, proof in proofs.items():
        if not isinstance(proof, dict) or set(proof) != {
            "afterBlock", "amount", "asset", "beforeBlock", "executionBlockHash", "executionLogIndex",
            "executionTransactionHash", "executor", "executorAfter", "executorBefore", "proposalId",
            "recipient", "recipientAfter", "recipientBefore",
        }:
            return False
        submission = submissions[submission_id]
        attempt = attempts.get("execute:" + submission_id)
        if attempt is None:
            return False
        try:
            if proof != _bound_balance_proof(proof, attempt, submission, stack):
                return False
        except TournamentError:
            return False
        try:
            amount = int(submission["payment"]["amount"])
            before_block, after_block = int(proof["beforeBlock"]), int(proof["afterBlock"])
            executor_before, executor_after = int(proof["executorBefore"]), int(proof["executorAfter"])
            recipient_before, recipient_after = int(proof["recipientBefore"]), int(proof["recipientAfter"])
        except (KeyError, TypeError, ValueError):
            return False
        if (
            after_block != before_block + 1
            or proof["amount"] != submission["payment"]["amount"]
            or proof["asset"] != submission["payment"]["asset"]
            or proof["recipient"] != submission["payment"]["recipient"]
            or proof["proposalId"] != submission["proposalId"]
            or proof["executor"] != stack["executor"]
            or executor_before - executor_after != amount
            or recipient_after - recipient_before != amount
            or executor_before + recipient_before != executor_after + recipient_after
        ):
            return False
    return True


def _rejected_reconciliation_valid(
    before: Any,
    after: Any,
    submissions: dict[str, dict[str, Any]],
    ledger: list[dict[str, Any]],
    stack: dict[str, Any],
) -> bool:
    if not isinstance(before, dict) or not isinstance(after, dict) or set(before) != set(REJECTED_IDS) or set(after) != set(REJECTED_IDS):
        return False
    attempts = {item["kind"]: item for item in ledger if item["kind"] != "queue-race:A-T3"}
    before_anchor, after_anchor = attempts["timeout:C-T3"], attempts["execute:C-T3"]
    fields = {"account", "asset", "balance", "blockHash", "blockNumber"}
    for submission_id in REJECTED_IDS:
        recipient = submissions[submission_id]["payment"]["recipient"]
        if (
            set(before[submission_id]) != fields
            or set(after[submission_id]) != fields
            or before[submission_id] != {
                "account": recipient,
                "asset": stack["asset"],
                "balance": "0",
                "blockHash": before_anchor["blockHash"],
                "blockNumber": before_anchor["blockNumber"],
            }
            or after[submission_id] != {
                "account": recipient,
                "asset": stack["asset"],
                "balance": "0",
                "blockHash": after_anchor["blockHash"],
                "blockNumber": after_anchor["blockNumber"],
            }
        ):
            return False
    return True


def _bond_reconciliation_valid(
    bonds: Any,
    submissions: dict[str, dict[str, Any]],
    evaluation_fifo: list[dict[str, Any]],
    min_activation_bond: int,
    mode: str,
) -> bool:
    if not isinstance(bonds, dict) or set(bonds) != {
        "actorBefore", "actorAfter", "arbitrationBalance", "withdrawable"
    }:
        return False
    actors = ("agentA", "agentB", "agentC")
    if any(set(bonds.get(field, {})) != set(actors) for field in ("actorBefore", "actorAfter", "withdrawable")):
        return False
    contributions = {actor: 0 for actor in actors}
    payouts = {actor: 0 for actor in actors}
    for submission in submissions.values():
        contributions[submission["agent"]] += min_activation_bond
    challengers = {"A-T2": "agentB", "B-T2": "agentA", "C-T1": "agentA"}
    for item in evaluation_fifo:
        submission_id = item["submission"]
        submission = submissions[submission_id]
        challenger = challengers[submission_id]
        required = int(item["requiredYesBond"])
        contributions[challenger] += min_activation_bond
        contributions[submission["agent"]] += required
        payouts[submission["agent"]] += min_activation_bond
        winner = submission["agent"] if item["accepted"] else challenger
        payouts[winner] += required + min_activation_bond
    for submission_id in TIMEOUT_IDS:
        payouts[submissions[submission_id]["agent"]] += min_activation_bond
    try:
        before = {actor: int(bonds["actorBefore"][actor]) for actor in actors}
        after = {actor: int(bonds["actorAfter"][actor]) for actor in actors}
        withdrawable = {actor: int(bonds["withdrawable"][actor]) for actor in actors}
        arbitration = int(bonds["arbitrationBalance"])
    except (TypeError, ValueError):
        return False
    return (
        all(before[actor] == (10**17 if mode == "sepolia-fork" else 1000) for actor in actors)
        and all(before[actor] - after[actor] == contributions[actor] for actor in actors)
        and withdrawable == payouts
        and arbitration == sum(contributions.values()) == sum(payouts.values())
    )


def submissions_by_policy(grader: dict[str, dict[str, bool]]) -> tuple[str, ...]:
    """Challenge failed grades plus the disclosed correct A-T2 rival drill."""

    return tuple(
        submission_id
        for submission_id in EVALUATION_IDS
        if not grader[submission_id]["verdict"] or submission_id == "A-T2"
    )


def _run_tournament(
    url: str,
    rpc: runner.JsonRpc,
    stack: dict[str, Any],
    repository: dict[str, Any],
    mode: str,
    recorder: Recorder,
) -> dict[str, Any]:
    correct_t1 = build_t1_artifact()
    correct_t2 = build_t2_artifact(stack)
    wrong_t2_value = json.loads(correct_t2)
    wrong_t2_value["runtimeCodeKeccak256"]["gateway"] = "0x" + "00" * 32
    wrong_t2 = _artifact(wrong_t2_value)
    correct_t3 = build_t3_artifact(stack)
    blobs = {"t1": correct_t1, "t2": correct_t2, "t2-wrong": wrong_t2, "t3": correct_t3}
    submissions = _submission_configs(stack, blobs)
    by_id = {item["id"]: item for item in submissions}
    objective_graders = {
        "T1": lambda blob: grade_t1(blob),
        "T2": lambda blob: grade_t2(blob, rpc, stack),
        "T3": lambda blob: grade_t3(blob, stack),
    }
    seen_artifacts: set[tuple[str, str]] = set()
    grader: dict[str, dict[str, bool]] = {}
    for submission in submissions:
        key = (submission["taskId"], submission["artifactDigest"])
        original = submission["taskId"] != "T1" or key not in seen_artifacts
        seen_artifacts.add(key)
        objective = objective_graders[submission["taskId"]](blobs[submission["artifact"]])
        grader[submission["id"]] = {
            "objectiveCorrect": objective,
            "original": original,
            "verdict": objective and original,
        }
    if [name for name, result in grader.items() if result["verdict"]] != ["A-T1", "A-T2", "A-T3", "C-T3"]:
        raise TournamentError("objective grader/copy-policy matrix drifted: %r" % grader)
    challenge_facts = tuple(
        (submission_id, "agentB" if submission_id == "A-T2" else "agentA")
        for submission_id in submissions_by_policy(grader)
    )
    bond_before = {
        name: _balance(rpc, stack["asset"], ACTOR_ADDRESSES[name])
        for name in ("agentA", "agentB", "agentC")
    }
    task_publications: dict[str, dict[str, Any]] = {}

    for task_id in ("T1", "T2", "T3"):
        task = next(item["task"] for item in submissions if item["taskId"] == task_id)
        publication = documents.prepare_publication("task", task)
        recorder.send(
            "publish-task:" + task_id, ACTOR_ADDRESSES["steward"], stack["index"], publication["calldata"]
        )
        task_publications[task_id] = {
            "digest": publication["documentDigest"], "document": "0x" + publication["document"].hex(),
            "transactionHash": recorder.attempts[-1]["transactionHash"],
        }

    round_robin: list[dict[str, Any]] = []
    restart: list[dict[str, Any]] = []
    order = [by_id[name] for name in ROUND_ROBIN_IDS]
    for expected in ROUND_ROBIN_ACTIONS:
        for submission in order:
            _tick(url, recorder, submission, expected)
            round_robin.append({"action": expected, "agent": submission["agent"], "submission": submission["id"]})
            if submission["id"] == "A-T2":
                restart.append(_state_pin(expected, url, submission))

    for submission_id, challenger in challenge_facts:
        submission = by_id[submission_id]
        recorder.send(
            "challenge:" + submission_id, ACTOR_ADDRESSES[challenger], stack["arbitration"],
            _proposal_data("placeNoBond(uint256)", submission), proposal=submission["proposalId"],
        )
        if submission_id == "A-T2":
            restart.append(_state_pin("challenged", url, submission))

    graduation: dict[str, dict[str, str]] = {}
    for queue_index, submission_id in enumerate(EVALUATION_IDS):
        submission = by_id[submission_id]
        required_yes = drill._uint(rpc, stack["arbitration"], "requiredYes(uint256)", str(queue_index))
        if required_yes != 100 * (2**queue_index):
            raise TournamentError("queried graduation YES threshold drifted")
        recorder.send(
            "graduate:" + submission_id,
            ACTOR_ADDRESSES[submission["agent"]],
            stack["arbitration"],
            _proposal_data("placeYesBond(uint256,uint256)", submission, required_yes),
            proposal=submission["proposalId"],
        )
        proposal = _fresh_state(url, submission)["proposal"]
        if proposal["state"] != "QUEUED" or proposal["queuePosition"] != queue_index + 1:
            raise TournamentError("proposal did not enter the expected non-vacuous FIFO position")
        graduation[submission_id] = {
            "queuePosition": str(proposal["queuePosition"]),
            "requiredYesBond": str(required_yes),
        }
        if submission_id == "A-T2":
            restart.append(_state_pin("graduated", url, submission))

    evaluation_order = []
    for submission_id in EVALUATION_IDS:
        submission = by_id[submission_id]
        if drill._uint(rpc, stack["arbitration"], "activeEvaluationProposalId()") != 0:
            raise TournamentError("evaluation slot was occupied before FIFO dequeue")
        recorder.send(
            "evaluation-start:" + submission_id, ACTOR_ADDRESSES["steward"], stack["arbitration"],
            "0x" + runner._selector("startNextEvaluation()"), proposal=submission["proposalId"],
        )
        active = drill._uint(rpc, stack["arbitration"], "activeEvaluationProposalId()")
        if active != int(submission["proposalId"]):
            raise TournamentError("active evaluation proposal violated FIFO order")
        if submission_id == "A-T2":
            restart.append(_state_pin("evaluating", url, submission))
        recorder.send(
            "evaluation-resolve:" + submission_id, ACTOR_ADDRESSES["steward"], stack["arbitration"],
            runner._call(runner._selector("resolveActiveEvaluation(bool)"), runner._word(1 if grader[submission_id]["verdict"] else 0)),
            proposal=submission["proposalId"],
        )
        if drill._uint(rpc, stack["arbitration"], "activeEvaluationProposalId()") != 0:
            raise TournamentError("evaluation slot did not clear after resolution")
        evaluation_order.append(
            {
                "accepted": grader[submission_id]["verdict"],
                "activeProposalId": str(active),
                **graduation[submission_id],
                "submission": submission_id,
            }
        )
        if submission_id == "A-T2":
            restart.append(_state_pin("evaluated", url, submission))

    _mine(rpc, recorder, 11, "advance arbitration timeout")
    for submission_id in TIMEOUT_IDS:
        submission = by_id[submission_id]
        recorder.send(
            "timeout:" + submission_id, ACTOR_ADDRESSES["steward"], stack["arbitration"],
            _proposal_data("finalizeByTimeout(uint256)", submission), proposal=submission["proposalId"],
        )

    bond_after = {name: _balance(rpc, stack["asset"], ACTOR_ADDRESSES[name]) for name in bond_before}
    arbitration_balance = _balance(rpc, stack["asset"], stack["arbitration"])
    withdrawable = {
        name: drill._uint(rpc, stack["arbitration"], "withdrawable(address)", ACTOR_ADDRESSES[name])
        for name in bond_before
    }
    if sum(bond_before.values()) - sum(bond_after.values()) != arbitration_balance or sum(withdrawable.values()) != arbitration_balance:
        raise TournamentError("bond balances do not conserve exactly")

    rejected_before = {
        submission_id: _balance_snapshot(
            rpc, stack["asset"], by_id[submission_id]["payment"]["recipient"]
        )
        for submission_id in ("B-T2", "C-T1")
    }
    for submission_id in ("A-T1", "A-T2", "C-T3"):
        _tick(url, recorder, by_id[submission_id], "queue")
        if submission_id == "A-T2":
            restart.append(_state_pin("queued", url, by_id[submission_id]))
    race = _race_queue(rpc, recorder, by_id["A-T3"])

    lineage_a = LatestRpc(url).finalized_block()
    _mine(rpc, recorder, 1, "capture consecutive finalized-lineage snapshot")
    lineage_b = LatestRpc(url).finalized_block()
    if lineage_b["parentHash"].lower() != lineage_a["hash"].lower():
        raise TournamentError("consecutive finalized-lineage snapshots are discontinuous")
    lineage = {
        "first": {"hash": lineage_a["hash"].lower(), "number": str(_quantity(lineage_a["number"]))},
        "second": {
            "hash": lineage_b["hash"].lower(),
            "number": str(_quantity(lineage_b["number"])),
            "parentHash": lineage_b["parentHash"].lower(),
        },
        "status": "pass" if lineage_b["parentHash"].lower() == lineage_a["hash"].lower() else "fail",
    }

    executor_before_initial = _balance(rpc, stack["asset"], stack["executor"])
    funder_before = _balance(rpc, stack["asset"], ACTOR_ADDRESSES["steward"])
    if executor_before_initial != 0:
        raise TournamentError("executor was not empty before exact tournament funding")
    initial_funding_tx, _ = recorder.send(
        "fund-executor:initial", ACTOR_ADDRESSES["steward"], stack["asset"],
        drill._token_call("transfer(address,uint256)", stack["executor"], 6 * ONE_MILLIWETH),
    )
    executor_after_initial = _balance(rpc, stack["asset"], stack["executor"])
    if executor_after_initial - executor_before_initial != 6 * ONE_MILLIWETH:
        raise TournamentError("initial executor funding delta drifted")
    _mine(rpc, recorder, 86_400, "advance treasury execution grace")
    balance_proofs: dict[str, Any] = {}
    for submission_id in ("A-T1", "A-T2", "A-T3"):
        _tick(url, recorder, by_id[submission_id], "execute")
        state = _fresh_state(url, by_id[submission_id])
        if state["lifecycle"] != "PAID":
            raise TournamentError(submission_id + " did not reach PAID")
        balance_proofs[submission_id] = _bound_balance_proof(
            state["views"]["balanceProof"], recorder.attempts[-1], by_id[submission_id], stack
        )
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
    short_tx, short_receipt = recorder.send(
        "execute:C-T3:shortfall", ACTOR_ADDRESSES["steward"], stack["vault"],
        _action_data(c3, runner.SELECTORS["execute"]), proposal=c3["proposalId"], force=True,
    )
    after_short = {
        "executor": _balance(rpc, stack["asset"], stack["executor"]),
        "recipient": _balance(rpc, stack["asset"], c3["payment"]["recipient"]),
    }
    if _quantity(short_receipt["status"]) != 0 or before_short != after_short:
        raise TournamentError("C-T3 shortfall was not one atomic revert")
    executor_before_topup = _balance(rpc, stack["asset"], stack["executor"])
    topup_tx, _ = recorder.send(
        "fund-executor:topup", ACTOR_ADDRESSES["steward"], stack["asset"],
        drill._token_call("transfer(address,uint256)", stack["executor"], 6 * ONE_MILLIWETH),
    )
    executor_after_topup = _balance(rpc, stack["asset"], stack["executor"])
    if executor_after_topup - executor_before_topup != 6 * ONE_MILLIWETH:
        raise TournamentError("executor top-up delta drifted")
    _tick(url, recorder, c3, "execute")
    retry_tx = recorder.attempts[-1]["transactionHash"]
    c3_state = _fresh_state(url, c3)
    if c3_state["lifecycle"] != "PAID" or _balance(rpc, stack["asset"], stack["executor"]) != 0:
        raise TournamentError("C-T3 retry did not exactly consume the top-up")
    balance_proofs["C-T3"] = _bound_balance_proof(
        c3_state["views"]["balanceProof"], recorder.attempts[-1], c3, stack
    )
    funder_after = _balance(rpc, stack["asset"], ACTOR_ADDRESSES["steward"])
    if funder_before - funder_after != 12 * ONE_MILLIWETH:
        raise TournamentError("steward funding reconciliation drifted")

    rejected_after = {
        submission_id: _balance_snapshot(
            rpc, stack["asset"], by_id[submission_id]["payment"]["recipient"]
        )
        for submission_id in ("B-T2", "C-T1")
    }
    if any(rejected_before[key]["balance"] != rejected_after[key]["balance"] for key in REJECTED_IDS):
        raise TournamentError("a rejected proposal moved treasury value")
    execution_attempts = [item for item in recorder.attempts if item["kind"].startswith("execute:")]
    paid = [item for item in execution_attempts if item["status"] == "1"]
    proposal_gas = [
        {
            "actor": item["actor"],
            "gasCostWei": item["gasCostWei"],
            "gasUsed": item["gasUsed"],
            "proposalId": item["proposalId"],
            "submission": item["kind"].split(":", 1)[1],
        }
        for item in recorder.attempts if item["kind"].startswith("propose:")
    ]
    if len(execution_attempts) != 5 or len(paid) != 4 or len(proposal_gas) != 6:
        raise TournamentError("proposal/execution attempt matrix counts drifted")

    routes = {}
    for item in submissions:
        route = _fresh_state(url, item)["acceptanceRoute"]
        routes[item["id"]] = route if grader[item["id"]]["verdict"] else route + "-rejected"
    if routes != EXPECTED_ROUTES or dict(challenge_facts) != {
        key: value for key, value in EXPECTED_CHALLENGES.items() if value is not None
    }:
        raise TournamentError("derived on-chain route/challenge policy drifted")
    evidence_submissions = _reported_submissions(submissions, grader)
    reconciliation = {
        "balanceProofs": balance_proofs,
        "bonds": {
            "actorBefore": {key: str(value) for key, value in bond_before.items()},
            "actorAfter": {key: str(value) for key, value in bond_after.items()},
            "arbitrationBalance": str(arbitration_balance),
            "withdrawable": {key: str(value) for key, value in withdrawable.items()},
        },
        "rejectedRecipientBefore": rejected_before,
        "rejectedRecipientAfter": rejected_after,
    }
    funding = {
        "assetProvenance": "canonical-WETH deposit on pinned fork" if mode == "sepolia-fork" else "valueless local FAOSiteToken",
        "executorInitial": {
            "after": str(executor_after_initial),
            "amount": str(executor_after_initial - executor_before_initial),
            "before": str(executor_before_initial),
            "transactionHash": initial_funding_tx,
        },
        "executorTopup": {
            "after": str(executor_after_topup),
            "amount": str(executor_after_topup - executor_before_topup),
            "before": str(executor_before_topup),
            "transactionHash": topup_tx,
        },
        "funder": "steward",
        "funderAfter": str(funder_after),
        "funderBefore": str(funder_before),
        "treasurySpend": str(funder_before - funder_after),
        "executorFinal": str(_balance(rpc, stack["asset"], stack["executor"])),
    }
    evidence = {
        "kind": "fao.agentwork.p2a-evidence",
        "v": "1",
        "repository": repository,
        "mode": mode,
        "finalityModel": "anvil-latest",
        "blockIntervalSeconds": "1",
        "miningClock": "one-second next-block timestamps; wall-clock interval disabled immediately after genesis",
        "pins": {
            "sepoliaForkBlock": str(SEPOLIA_FORK_BLOCK), "sepoliaForkBlockHash": SEPOLIA_FORK_HASH,
            "sepoliaForkTimestamp": str(SEPOLIA_FORK_TIMESTAMP),
            "selectionFinalizedHead": "11261302",
            "selectionRule": "finalized head minus 64, rounded down to a multiple of 1000",
            "canonicalWeth": SEPOLIA_WETH, "canonicalWethRuntimeKeccak256": SEPOLIA_WETH_RUNTIME_HASH,
            "actorNonce": "0",
        },
        "stack": {
            "chainId": str(stack["chainId"]), "forkBlock": str(stack["forkBlock"]),
            "forkBlockHash": stack["forkBlockHash"], "observationBlock": str(stack["observationBlock"]),
            "startBlock": str(stack["startBlock"]),
            "startTimestamp": str(stack["startTimestamp"]),
            "asset": stack["asset"], "minActivationBond": str(stack["minActivationBond"]),
            **{name: stack[name] for name in ("index", "gateway", "arbitration", "vault", "executor")},
            "runtimeCodeKeccak256": stack["runtimeCodeKeccak256"],
        },
        "actors": [
            {
                "address": address, "label": role, "provenance": "house-wallet", "signing": "anvil-impersonated-unlocked",
                "caps": {"nativeWei": str(100 * 10**18), "bondAsset": "1000", "treasuryAuthority": "0"},
                "startingNonce": "0",
            }
            for role, address in ACTOR_ADDRESSES.items()
        ],
        "funding": funding,
        "tasks": task_publications,
        "submissions": evidence_submissions,
        "artifactBlobs": {
            documents.document_digest(blob): "0x" + blob.hex() for blob in blobs.values()
        },
        "graderPolicy": dict(GRADER_POLICY),
        "evaluationFifo": evaluation_order,
        "roundRobinTicks": round_robin,
        "attemptLedger": recorder.attempts,
        "anvilControls": recorder.controls,
        "anvilStateMutations": recorder.mutations,
        "drills": {
            "aT2FreshRunnerRestarts": restart,
            "aT3QueueRace": race,
            "cT3Shortfall": {
                "after": {key: str(value) for key, value in after_short.items()},
                "before": {key: str(value) for key, value in before_short.items()},
                "envelopeDigest": documents.document_digest(documents.build_payment(c3["payment"])),
                "proposalId": c3["proposalId"],
                "retryTransactionHash": retry_tx,
                "sameEnvelopeAndProposal": before_short == after_short,
                "shortfallTransactionHash": short_tx,
                "status": "pass" if _quantity(short_receipt["status"]) == 0 and before_short == after_short else "fail",
            },
            "finalizedLineage": lineage,
        },
        "reconciliation": reconciliation,
        "counts": {},
        "metrics": {},
        "publicBroadcasts": 0,
        "recordedTranscriptSha256": "",
        "observedMetadata": {
            "localPortExcluded": True,
            "processIdExcluded": True,
            "rpcTranscriptAuthentication": "internally cross-checked and source-pinned; not an external cryptographic attestation",
            "wallClockExcluded": True,
        },
        "claims": dict(FALSE_CLAIMS),
    }
    evidence["counts"] = _derived_counts(evidence)
    evidence["metrics"] = _derived_metrics(evidence, by_id)
    evidence["recordedTranscriptSha256"] = _recorded_transcript_sha256(evidence)
    if (
        mode == "sepolia-fork"
        and int(PINNED_FORK_TRANSCRIPT_SHA256, 16) != 0
        and evidence["recordedTranscriptSha256"] != PINNED_FORK_TRANSCRIPT_SHA256
    ):
        raise TournamentError("pinned fork transcript drifted")
    gate_conditions = _base_gate_conditions(evidence, submissions, grader)
    evidence["gates"] = [
        {"id": gate_id, "status": "pass" if gate_conditions[gate_id] else "fail"}
        for gate_id in BASE_GATE_IDS
    ]
    if not all(gate_conditions.values()):
        expected_attempts = _expected_attempts(mode, stack, submissions)
        mismatches = [
            (index + 1, actual, wanted)
            for index, (actual, wanted) in enumerate(zip(recorder.attempts, expected_attempts))
            if any(actual.get(key) != expected for key, expected in wanted.items())
        ]
        raise TournamentError(
            "derived tournament gate failed: %r; bonds=%r; ledger=%d/%d firstMismatch=%r mutations=%r"
            % (
                gate_conditions,
                reconciliation["bonds"],
                len(recorder.attempts),
                len(expected_attempts),
                mismatches[:1],
                _state_mutations_valid(evidence),
            )
        )
    return evidence


def _session(port: int, fork_url: str | None, repository: dict[str, Any]) -> dict[str, Any]:
    process = _start_anvil(port, fork_url)
    try:
        url, rpc = _ready(port)
        recorder = Recorder(rpc, ACTOR_ADDRESSES)
        _prepare_actors(rpc, fork_url is not None, recorder)
        drill.ATTEMPT_LEDGER.clear()
        stack = _stack(url, rpc, fork_url is not None, recorder)
        return _run_tournament(
            url, rpc, stack, repository, "sepolia-fork" if fork_url else "plain-local", recorder
        )
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
    same_digest = first_raw == second_raw
    if not same_digest:
        raise TournamentError(
            "two clean pinned-fork tournaments diverged: %s != %s"
            % (hashlib.sha256(first_raw).hexdigest(), hashlib.sha256(second_raw).hexdigest())
        )
    first["gates"].extend(
        (
            {
                "id": "plain-local-rehearsal",
                "status": "pass" if [gate["id"] for gate in local["gates"]] == list(BASE_GATE_IDS)
                and all(gate["status"] == "pass" for gate in local["gates"])
                else "fail",
            },
            {"id": "two-clean-pinned-fork-digests", "status": "pass" if same_digest else "fail"},
        )
    )
    first["deterministicTournamentSha256"] = "0x" + hashlib.sha256(first_raw).hexdigest()
    return first


def _deterministic_tournament_sha256(value: dict[str, Any]) -> str:
    payload = copy.deepcopy(value)
    payload.pop("deterministicTournamentSha256", None)
    payload["gates"] = [gate for gate in payload.get("gates", []) if gate.get("id") not in RUN_GATE_IDS]
    return "0x" + hashlib.sha256(runner.canonical_json(payload)).hexdigest()


def _recorded_transcript_sha256(value: dict[str, Any]) -> str:
    fields = (
        "stack", "funding", "tasks", "evaluationFifo", "attemptLedger", "anvilControls",
        "anvilStateMutations", "drills", "reconciliation", "counts", "metrics",
    )
    return "0x" + hashlib.sha256(runner.canonical_json({field: value[field] for field in fields})).hexdigest()


def _require(condition: bool, message: str) -> None:
    if not condition:
        raise TournamentError(message)


def _decimal(value: Any, label: str) -> int:
    _require(isinstance(value, str) and re.fullmatch(r"0|[1-9][0-9]*", value) is not None, label + " is not canonical decimal")
    return int(value)


def _stack_from_evidence(value: dict[str, Any]) -> dict[str, Any]:
    stack = value.get("stack")
    expected_fields = {
        "chainId", "startBlock", "startTimestamp", "forkBlock", "forkBlockHash", "observationBlock", "asset",
        "minActivationBond", "index", "gateway", "arbitration", "vault", "executor", "runtimeCodeKeccak256",
    }
    _require(isinstance(stack, dict) and set(stack) == expected_fields, "P2a stack schema drifted")
    addresses = {name: stack[name] for name in ("asset", "index", "gateway", "arbitration", "vault", "executor")}
    _require(
        all(isinstance(address, str) and re.fullmatch(r"0x[0-9a-f]{40}", address) for address in addresses.values())
        and len(set(addresses.values())) == len(addresses),
        "P2a stack addresses are malformed or duplicated",
    )
    runtime = stack["runtimeCodeKeccak256"]
    runtime_names = {"index", "gateway", "arbitration", "vault", "executor"}
    _require(
        isinstance(runtime, dict)
        and set(runtime) == runtime_names
        and all(re.fullmatch(r"0x[0-9a-f]{64}", digest or "") and int(digest, 16) != 0 for digest in runtime.values()),
        "P2a runtime hashes are incomplete, malformed or zero",
    )
    result = dict(stack)
    for field in ("chainId", "startBlock", "startTimestamp", "forkBlock", "observationBlock", "minActivationBond"):
        result[field] = _decimal(stack[field], "stack." + field)
    _require(
        result["chainId"] == SEPOLIA_CHAIN_ID
        and result["startBlock"] == SEPOLIA_FORK_BLOCK
        and result["startTimestamp"] == SEPOLIA_FORK_TIMESTAMP
        and result["forkBlock"] == SEPOLIA_FORK_BLOCK
        and result["forkBlockHash"] == SEPOLIA_FORK_HASH
        and result["asset"] == SEPOLIA_WETH
        and result["minActivationBond"] == 2
        and result["observationBlock"] > result["startBlock"],
        "P2a stack/fork binding drifted",
    )
    return result


def _expected_documents(stack: dict[str, Any]) -> tuple[dict[str, bytes], list[dict[str, Any]], dict[str, dict[str, bool]]]:
    correct_t1 = build_t1_artifact()
    correct_t2 = build_t2_artifact(stack)
    wrong_t2_value = json.loads(correct_t2)
    wrong_t2_value["runtimeCodeKeccak256"]["gateway"] = "0x" + "00" * 32
    correct_t3 = build_t3_artifact(stack)
    blobs = {
        "t1": correct_t1,
        "t2": correct_t2,
        "t2-wrong": _artifact(wrong_t2_value),
        "t3": correct_t3,
    }
    submissions = _submission_configs(stack, blobs)
    graders: dict[str, dict[str, bool]] = {}
    seen_t1: set[str] = set()
    for submission in submissions:
        blob = blobs[submission["artifact"]]
        objective = {
            "T1": grade_t1(blob),
            "T2": blob == correct_t2,
            "T3": grade_t3(blob, stack),
        }[submission["taskId"]]
        original = submission["taskId"] != "T1" or submission["artifactDigest"] not in seen_t1
        if submission["taskId"] == "T1":
            seen_t1.add(submission["artifactDigest"])
        graders[submission["id"]] = {
            "objectiveCorrect": objective,
            "original": original,
            "verdict": objective and original,
        }
    return blobs, submissions, graders


def _reported_submissions(
    configs: list[dict[str, Any]], graders: dict[str, dict[str, bool]]
) -> list[dict[str, Any]]:
    result = []
    for config in configs:
        submission_id = config["id"]
        payment_raw = documents.build_payment(config["payment"])
        receipt_raw = documents.build_receipt(config["receipt"])
        result.append(
            {
                "acceptanceRoute": EXPECTED_ROUTES[submission_id],
                "agent": config["agent"],
                "artifactDigest": config["artifactDigest"],
                "challenge": EXPECTED_CHALLENGES[submission_id],
                "grader": graders[submission_id],
                "id": submission_id,
                "outcome": "paid" if submission_id in PAID_IDS else "rejected",
                "payment": "0x" + payment_raw.hex(),
                "paymentDigest": documents.document_digest(payment_raw),
                "proposalId": config["proposalId"],
                "receipt": "0x" + receipt_raw.hex(),
                "receiptDigest": documents.document_digest(receipt_raw),
                "taskDigest": documents.document_digest(documents.build_task(config["task"])),
                "taskId": config["taskId"],
            }
        )
    return result


def _derived_counts(value: dict[str, Any]) -> dict[str, int]:
    submissions = value["submissions"]
    ledger = value["attemptLedger"]
    yes_transactions = [
        item for item in ledger
        if item["kind"].startswith("place-yes-bond:") or item["kind"].startswith("graduate:")
    ]
    initial_yes = [item for item in yes_transactions if item["kind"].startswith("place-yes-bond:")]
    executions = [item for item in ledger if item["kind"].startswith("execute:")]
    return {
        "agents": len({item["agent"] for item in submissions}),
        "tasks": len(value["tasks"]),
        "receipts": len({item["receiptDigest"] for item in submissions}),
        "paymentEnvelopes": len({item["paymentDigest"] for item in submissions}),
        "proposals": len({item["proposalId"] for item in submissions}),
        "yesBondedProposals": len({item["proposalId"] for item in initial_yes}),
        "yesBondTransactions": len(yes_transactions),
        "graduationYesFlips": len([item for item in yes_transactions if item["kind"].startswith("graduate:")]),
        "noBonds": len([item for item in ledger if item["kind"].startswith("challenge:")]),
        "evaluations": len([item for item in ledger if item["kind"].startswith("evaluation-resolve:")]),
        "timeoutFinalizations": len([item for item in ledger if item["kind"].startswith("timeout:")]),
        "executionAttempts": len(executions),
        "payments": len([item for item in executions if item["status"] == "1"]),
        "atomicShortfallReverts": len([item for item in executions if item["status"] == "0"]),
    }


def _derived_metrics(value: dict[str, Any], submissions: dict[str, dict[str, Any]]) -> dict[str, Any]:
    reported = {item["id"]: item for item in value["submissions"]}
    ledger = value["attemptLedger"]
    quality = {}
    for agent in ("agentA", "agentB", "agentC"):
        results = [item["grader"]["verdict"] for item in reported.values() if item["agent"] == agent]
        quality[agent] = "%d/%d" % (sum(results), len(results))
    paid = [item for item in ledger if item["kind"].startswith("execute:") and item["status"] == "1"]
    proposal_gas = [
        {
            "actor": item["actor"],
            "gasCostWei": item["gasCostWei"],
            "gasUsed": item["gasUsed"],
            "proposalId": item["proposalId"],
            "submission": item["kind"].split(":", 1)[1],
        }
        for item in ledger if item["kind"].startswith("propose:")
    ]
    unique = {item["kind"]: item for item in ledger if item["kind"] != "queue-race:A-T3"}
    latency = {}
    for submission_id, submission in submissions.items():
        end_kind = "execute:" + submission_id if submission_id in PAID_IDS else "evaluation-resolve:" + submission_id
        latency[submission_id] = str(
            int(unique[end_kind]["blockTimestamp"])
            - int(unique["publish-task:" + submission["taskId"]]["blockTimestamp"])
        )
    spend = sum(int(submissions[submission_id]["payment"]["amount"]) for submission_id in PAID_IDS)
    return {
        "artifactQuality": quality,
        "challengeRate": "%d/%d" % (sum(item["challenge"] is not None for item in reported.values()), len(reported)),
        "falsePaymentRate": "%d/%d" % (
            sum(not reported[item["kind"].split(":", 1)[1]]["grader"]["verdict"] for item in paid), len(paid)
        ),
        "proposalGas": proposal_gas,
        "simulatedChainCompletionLatencySeconds": latency,
        "totalTreasurySpend": str(spend),
    }


def _base_gate_conditions(
    value: dict[str, Any], configs: list[dict[str, Any]], graders: dict[str, dict[str, bool]]
) -> dict[str, bool]:
    by_id = {item["id"]: item for item in configs}
    reconciliation = value["reconciliation"]
    return {
        "exact-documents-parentage": value["submissions"] == _reported_submissions(configs, graders),
        "six-bindings": len({item["proposalId"] for item in value["submissions"]}) == len(SUBMISSION_FACTS),
        "four-recorded-receipt-log-balance-payments": _balance_proofs_valid(
            reconciliation["balanceProofs"], by_id, value["attemptLedger"], value["stack"]
        ),
        "rejected-no-movement": _rejected_reconciliation_valid(
            reconciliation["rejectedRecipientBefore"],
            reconciliation["rejectedRecipientAfter"],
            by_id,
            value["attemptLedger"],
            value["stack"],
        ),
        "actor-bond-treasury-conservation": _bond_reconciliation_valid(
            reconciliation["bonds"],
            by_id,
            value["evaluationFifo"],
            int(value["stack"]["minActivationBond"]),
            value["mode"],
        ),
        "complete-attempt-ledger": _attempt_ledger_valid(value["attemptLedger"], value["mode"], value["stack"], configs)
        and _state_mutations_valid(value),
        "zero-public-broadcasts": value["publicBroadcasts"] == 0,
    }


def _verify_repository(repository: Any) -> None:
    _require(
        isinstance(repository, dict)
        and set(repository) == {"commit", "dirty", "excludedGeneratedPaths", "sourceIndexSha256"}
        and repository["dirty"] is False
        and repository["excludedGeneratedPaths"] == list(EXCLUDED_EVIDENCE)
        and re.fullmatch(r"[0-9a-f]{40}", repository["commit"] or "") is not None,
        "P2a source-tree provenance schema drifted",
    )
    source = repository["commit"]
    ancestry = subprocess.run(
        ["git", "merge-base", "--is-ancestor", source, "HEAD"], cwd=ROOT, capture_output=True
    )
    _require(ancestry.returncode == 0, "P2a source commit is not an ancestor of HEAD")
    expected_index = _source_index_sha256(source)
    _require(
        repository["sourceIndexSha256"] == expected_index == _source_index_sha256("HEAD"),
        "P2a source commit/index does not bind the checked-out source tree",
    )
    pathspec = [".", *[":(exclude)" + path for path in EXCLUDED_EVIDENCE]]
    _require(
        not _run(["git", "status", "--porcelain", "--untracked-files=all", "--", *pathspec]),
        "P2a checked-out source tree is dirty outside generated evidence",
    )


def _verify_restarts(drill_value: Any, proposal_id: str, ledger: list[dict[str, Any]]) -> None:
    labels = (
        ("publish-receipt", "RECEIPT_PUBLISHED", False, "publish-receipt:A-T2", None),
        ("publish-payment", "PAYMENT_PUBLISHED", False, "publish-payment:A-T2", None),
        ("propose", "PROPOSED", False, "propose:A-T2", "INACTIVE"),
        ("place-yes-bond", "BONDED", False, "place-yes-bond:A-T2", "YES"),
        ("challenged", "BONDED", False, "challenge:A-T2", "NO"),
        ("graduated", "BONDED", False, "graduate:A-T2", "QUEUED"),
        ("evaluating", "BONDED", False, "evaluation-start:A-T2", "EVALUATING"),
        ("evaluated", "ACCEPTED", True, "evaluation-resolve:A-T2", "SETTLED"),
        ("queued", "QUEUED", True, "queue:A-T2", "SETTLED"),
        ("paid", "PAID", True, "execute:A-T2", "SETTLED"),
    )
    _require(isinstance(drill_value, list) and len(drill_value) == len(labels), "A-T2 restart drill cardinality drifted")
    attempts = {item["kind"]: item for item in ledger if item["kind"] != "queue-race:A-T3"}
    action_hash = "0x" + int(proposal_id).to_bytes(32, "big").hex()
    for item, (label, lifecycle, accepted, attempt_kind, proposal_state) in zip(drill_value, labels):
        state = item.get("stateView")
        attempt = attempts[attempt_kind]
        _require(
            item.get("label") == label
            and item.get("lifecycle") == lifecycle
            and item.get("accepted") is accepted
            and item.get("blockHash") == attempt["blockHash"]
            and item.get("blockNumber") == attempt["blockNumber"]
            and isinstance(state, dict)
            and item.get("stateSha256") == "0x" + hashlib.sha256(runner.canonical_json(state)).hexdigest()
            and state.get("actionHash") == action_hash
            and state.get("lifecycle") == lifecycle
            and state.get("paid") is (label == "paid"),
            "A-T2 restart state pin drifted at " + label,
        )
        proposal = state.get("proposal")
        _require(
            (proposal_state is None and proposal is None)
            or (isinstance(proposal, dict) and proposal.get("state") == proposal_state),
            "A-T2 restart proposal state drifted at " + label,
        )


def _verify_semantics(value: dict[str, Any], *, verify_repository: bool = True) -> None:
    top_fields = {
        "kind", "v", "repository", "mode", "finalityModel", "blockIntervalSeconds", "miningClock",
        "pins", "stack", "actors", "funding", "tasks", "submissions", "artifactBlobs", "graderPolicy",
        "evaluationFifo", "roundRobinTicks", "attemptLedger", "anvilControls", "anvilStateMutations",
        "drills", "reconciliation", "counts", "metrics", "gates", "publicBroadcasts", "observedMetadata",
        "claims", "deterministicTournamentSha256", "recordedTranscriptSha256",
    }
    _require(set(value) == top_fields, "P2a top-level evidence schema drifted")
    _require(value["kind"] == "fao.agentwork.p2a-evidence" and value["v"] == "1", "P2a kind/version drifted")
    _require(
        value["mode"] == "sepolia-fork"
        and value["finalityModel"] == "anvil-latest"
        and value["blockIntervalSeconds"] == "1"
        and value["miningClock"] == "one-second next-block timestamps; wall-clock interval disabled immediately after genesis",
        "P2a mode/finality/mining-clock disclosure drifted",
    )
    _require(
        value["pins"] == {
            "sepoliaForkBlock": str(SEPOLIA_FORK_BLOCK),
            "sepoliaForkBlockHash": SEPOLIA_FORK_HASH,
            "sepoliaForkTimestamp": str(SEPOLIA_FORK_TIMESTAMP),
            "selectionFinalizedHead": "11261302",
            "selectionRule": "finalized head minus 64, rounded down to a multiple of 1000",
            "canonicalWeth": SEPOLIA_WETH,
            "canonicalWethRuntimeKeccak256": SEPOLIA_WETH_RUNTIME_HASH,
            "actorNonce": "0",
        },
        "P2a fork precondition pins drifted",
    )
    if verify_repository:
        _verify_repository(value["repository"])
    stack = _stack_from_evidence(value)
    blobs, expected_configs, graders = _expected_documents(stack)
    expected_blob_map = {documents.document_digest(blob): "0x" + blob.hex() for blob in blobs.values()}
    _require(value["artifactBlobs"] == expected_blob_map, "P2a exact T1/T2/T3 artifact set drifted")
    _require(grade_t1(blobs["t1"]) and grade_t3(blobs["t3"], stack), "P2a objective T1/T3 graders failed")

    by_id = {item["id"]: item for item in expected_configs}
    expected_submissions = _reported_submissions(expected_configs, graders)
    _require(value["submissions"] == expected_submissions, "P2a document, grader, challenge, route or outcome matrix drifted")
    _require(
        value["graderPolicy"] == GRADER_POLICY
        and tuple(item["id"] for item in expected_submissions if item["challenge"] is not None) == submissions_by_policy(graders),
        "P2a disclosed grader/challenge/resolver policy drifted",
    )

    actors = [
        {
            "address": address,
            "label": role,
            "provenance": "house-wallet",
            "signing": "anvil-impersonated-unlocked",
            "caps": {"nativeWei": str(100 * 10**18), "bondAsset": "1000", "treasuryAuthority": "0"},
            "startingNonce": "0",
        }
        for role, address in ACTOR_ADDRESSES.items()
    ]
    _require(value["actors"] == actors, "P2a actor roster, authority or caps drifted")
    expected_round_robin = [
        {"action": action, "agent": by_id[submission_id]["agent"], "submission": submission_id}
        for action in ROUND_ROBIN_ACTIONS for submission_id in ROUND_ROBIN_IDS
    ]
    _require(value["roundRobinTicks"] == expected_round_robin, "P2a fresh-runner round-robin schedule drifted")

    ledger = value["attemptLedger"]
    _require(_attempt_ledger_valid(ledger, value["mode"], stack, expected_configs), "P2a complete attempt ledger drifted")
    _require(_state_mutations_valid(value), "P2a Anvil state-mutation/control disclosure drifted")
    attempts = {item["kind"]: item for item in ledger if item["kind"] != "queue-race:A-T3"}
    expected_tasks = {}
    for task_id in ("T1", "T2", "T3"):
        task = next(item["task"] for item in expected_configs if item["taskId"] == task_id)
        publication = documents.prepare_publication("task", task)
        expected_tasks[task_id] = {
            "digest": publication["documentDigest"],
            "document": "0x" + publication["document"].hex(),
            "transactionHash": attempts["publish-task:" + task_id]["transactionHash"],
        }
    _require(value["tasks"] == expected_tasks, "P2a exact task publication set drifted")

    fifo = value["evaluationFifo"]
    _require(
        fifo == [
            {
                "accepted": graders[submission_id]["verdict"],
                "activeProposalId": by_id[submission_id]["proposalId"],
                "queuePosition": str(index + 1),
                "requiredYesBond": str(100 * (2**index)),
                "submission": submission_id,
            }
            for index, submission_id in enumerate(EVALUATION_IDS)
        ],
        "P2a non-vacuous FIFO positions, thresholds or active IDs drifted",
    )

    reconciliation = value["reconciliation"]
    _require(
        isinstance(reconciliation, dict)
        and set(reconciliation) == {"balanceProofs", "bonds", "rejectedRecipientBefore", "rejectedRecipientAfter"}
        and _balance_proofs_valid(reconciliation["balanceProofs"], by_id, ledger, stack)
        and _bond_reconciliation_valid(
            reconciliation["bonds"], by_id, fifo, stack["minActivationBond"], value["mode"]
        )
        and _rejected_reconciliation_valid(
            reconciliation["rejectedRecipientBefore"],
            reconciliation["rejectedRecipientAfter"],
            by_id,
            ledger,
            stack,
        ),
        "P2a payment/bond/rejected reconciliation drifted",
    )
    funding = value["funding"]
    _require(
        isinstance(funding, dict)
        and set(funding) == {
            "assetProvenance", "executorInitial", "executorTopup", "funder", "funderBefore", "funderAfter", "treasurySpend", "executorFinal"
        }
        and funding["assetProvenance"] == "canonical-WETH deposit on pinned fork"
        and funding["funder"] == "steward"
        and funding["executorInitial"] == {
            "before": "0", "after": str(6 * ONE_MILLIWETH), "amount": str(6 * ONE_MILLIWETH),
            "transactionHash": attempts["fund-executor:initial"]["transactionHash"],
        }
        and funding["executorTopup"] == {
            "before": "0", "after": str(6 * ONE_MILLIWETH), "amount": str(6 * ONE_MILLIWETH),
            "transactionHash": attempts["fund-executor:topup"]["transactionHash"],
        }
        and funding["funderBefore"] == str(10**17)
        and funding["funderAfter"] == str(10**17 - 12 * ONE_MILLIWETH)
        and _decimal(funding["funderBefore"], "funding.funderBefore")
        - _decimal(funding["funderAfter"], "funding.funderAfter") == 12 * ONE_MILLIWETH
        and funding["treasurySpend"] == str(12 * ONE_MILLIWETH)
        and funding["executorFinal"] == "0",
        "P2a exact treasury funding/reconciliation drifted",
    )

    drills = value["drills"]
    _require(isinstance(drills, dict) and set(drills) == {"aT2FreshRunnerRestarts", "aT3QueueRace", "cT3Shortfall", "finalizedLineage"}, "P2a drill schema drifted")
    _verify_restarts(drills["aT2FreshRunnerRestarts"], by_id["A-T2"]["proposalId"], ledger)
    race_attempts = [item for item in ledger if item["kind"] == "queue-race:A-T3"]
    _require(
        drills["aT3QueueRace"] == {
            "blockNumber": race_attempts[0]["blockNumber"],
            "loser": "agentC",
            "loserClassification": "benign-post-state-verified",
            "proposalId": by_id["A-T3"]["proposalId"],
            "statuses": ["1", "0"],
            "transactionHashes": [item["transactionHash"] for item in race_attempts],
            "winner": "agentB",
        }
        and race_attempts[0]["blockHash"] == race_attempts[1]["blockHash"],
        "P2a same-block queue race proof drifted",
    )
    shortfall = drills["cT3Shortfall"]
    short_attempt, retry_attempt = attempts["execute:C-T3:shortfall"], attempts["execute:C-T3"]
    _require(
        isinstance(shortfall, dict)
        and shortfall.get("before") == shortfall.get("after")
        and shortfall.get("before", {}).get("executor") == "0"
        and shortfall.get("envelopeDigest") == expected_submissions[5]["paymentDigest"]
        and shortfall.get("proposalId") == by_id["C-T3"]["proposalId"]
        and shortfall.get("shortfallTransactionHash") == short_attempt["transactionHash"]
        and shortfall.get("retryTransactionHash") == retry_attempt["transactionHash"]
        and shortfall.get("sameEnvelopeAndProposal") is True
        and shortfall.get("status") == "pass"
        and short_attempt["proposalId"] == retry_attempt["proposalId"]
        and short_attempt["dataKeccak256"] == retry_attempt["dataKeccak256"]
        and (short_attempt["status"], retry_attempt["status"]) == ("0", "1"),
        "P2a atomic shortfall/top-up retry proof drifted",
    )
    lineage = drills["finalizedLineage"]
    _require(
        isinstance(lineage, dict)
        and lineage.get("status") == "pass"
        and lineage.get("second", {}).get("parentHash") == lineage.get("first", {}).get("hash")
        and _decimal(lineage["second"]["number"], "lineage.second.number")
        == _decimal(lineage["first"]["number"], "lineage.first.number") + 1
        and all(re.fullmatch(r"0x[0-9a-f]{64}", entry.get("hash", "")) for entry in (lineage["first"], lineage["second"])),
        "P2a finalized-lineage continuity proof drifted",
    )

    _require(value["counts"] == _derived_counts(value), "P2a derived scenario counts drifted")
    _require(value["metrics"] == _derived_metrics(value, by_id), "P2a derived tournament metrics drifted")
    _require(
        value["recordedTranscriptSha256"]
        == _recorded_transcript_sha256(value)
        == PINNED_FORK_TRANSCRIPT_SHA256,
        "P2a recorded fork transcript pin drifted",
    )
    _require(value["publicBroadcasts"] == 0, "P2a public broadcast count drifted")
    _require(
        value["observedMetadata"] == {
            "localPortExcluded": True,
            "processIdExcluded": True,
            "rpcTranscriptAuthentication": "internally cross-checked and source-pinned; not an external cryptographic attestation",
            "wallClockExcluded": True,
        },
        "P2a deterministic exclusion disclosure drifted",
    )
    _require(value["claims"] == FALSE_CLAIMS, "P2a exact false-claim schema drifted")
    gate_conditions = _base_gate_conditions(value, expected_configs, graders)
    _require(all(gate_conditions.values()), "P2a recomputed base gate failed: %r" % gate_conditions)
    gates = value["gates"]
    expected_gates = [
        {"id": gate_id, "status": "pass" if gate_conditions[gate_id] else "fail"}
        for gate_id in BASE_GATE_IDS
    ] + [{"id": gate_id, "status": "pass"} for gate_id in RUN_GATE_IDS]
    _require(
        isinstance(gates, list)
        and [gate.get("id") for gate in gates] == list(BASE_GATE_IDS + RUN_GATE_IDS)
        and len({gate.get("id") for gate in gates}) == len(gates)
        and gates == expected_gates,
        "P2a gate IDs are duplicated, missing, reordered or non-passing",
    )
    _require(
        value["deterministicTournamentSha256"] == _deterministic_tournament_sha256(value),
        "P2a deterministic tournament digest drifted",
    )


def verify_evidence(path: Path = EVIDENCE_PATH) -> str:
    try:
        raw = path.read_bytes()
        value = json.loads(raw)
        digest = "0x" + hashlib.sha256(raw).hexdigest()
        _require(raw == runner.canonical_json(value) + b"\n", "P2a evidence is not canonical sorted-key compact JSON")
        _require(
            path.with_suffix(path.suffix + ".sha256").read_text(encoding="ascii").strip() == digest,
            "P2a exact-byte SHA-256 sidecar drifted",
        )
        _verify_semantics(value)
        return digest
    except TournamentError:
        raise
    except (KeyError, IndexError, TypeError, ValueError, json.JSONDecodeError, OSError) as exc:
        raise TournamentError("P2a semantic evidence validation failed: %s" % exc) from exc


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
