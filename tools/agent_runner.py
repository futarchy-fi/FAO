#!/usr/bin/env python3
"""Stateless finalized-state reference runner for FAO agent-work payments."""

from __future__ import annotations

import hashlib
import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Protocol, Sequence

try:
    from tools import agent_documents as documents
except ModuleNotFoundError:  # Direct script execution.
    import agent_documents as documents  # type: ignore


ZERO = "0x" + "00" * 32
UINT256_MAX = (1 << 256) - 1
STATE_NAMES = ("INACTIVE", "YES", "NO", "QUEUED", "EVALUATING", "SETTLED")


class RunnerError(ValueError):
    pass


class RpcCallError(RunnerError):
    def __init__(self, message: str, data: Any = None) -> None:
        super().__init__(message)
        self.data = data


class StaticCaller(Protocol):
    def call(self, transaction: dict[str, Any], block: str) -> str:
        ...


class TransactionSender(Protocol):
    """The only signing/broadcast exit; implementations and keys stay outside this package."""

    def send(self, unsigned_transaction: dict[str, Any]) -> str:
        ...


@dataclass(frozen=True)
class Action:
    kind: str
    to: str
    data: str
    cap_kind: str = "transactionValue"
    cap_amount: int = 0

    def transaction(self, sender: str, chain_id: int) -> dict[str, Any]:
        return {
            "from": _address(sender, "sender"),
            "to": _address(self.to, "action.to"),
            "data": _bytes_hex(self.data, "action.data"),
            "value": "0x0",
            "chainId": hex(chain_id),
        }


class JsonRpc:
    """Small read-only stdlib JSON-RPC adapter; it cannot sign transactions."""

    def __init__(self, url: str) -> None:
        self.url = url
        self._id = 0

    def request(self, method: str, params: Sequence[Any]) -> Any:
        self._id += 1
        raw = json.dumps(
            {"jsonrpc": "2.0", "id": self._id, "method": method, "params": list(params)},
            separators=(",", ":"),
        ).encode()
        request = urllib.request.Request(
            self.url, raw, {"Content-Type": "application/json"}, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                value = json.loads(response.read().decode())
        except (OSError, UnicodeError, json.JSONDecodeError, urllib.error.URLError) as exc:
            raise RunnerError("JSON-RPC request failed") from exc
        if not isinstance(value, dict) or value.get("id") != self._id:
            raise RunnerError("JSON-RPC response envelope is invalid")
        if value.get("error") is not None:
            error = value["error"]
            data = error.get("data") if isinstance(error, dict) else None
            raise RpcCallError(f"JSON-RPC {method} failed: {error}", data)
        return value.get("result")

    def chain_id(self) -> int:
        return _quantity(self.request("eth_chainId", []), "eth_chainId")

    def block(self, number: int | str) -> dict[str, Any]:
        tag = hex(number) if isinstance(number, int) else number
        value = self.request("eth_getBlockByNumber", [tag, False])
        if not isinstance(value, dict):
            raise RunnerError(f"block is unavailable: {tag}")
        return value

    def finalized_block(self) -> dict[str, Any]:
        return self.block("finalized")

    def logs(self, start: int, end: int, addresses: list[str]) -> list[dict[str, Any]]:
        value = self.request(
            "eth_getLogs",
            [{"fromBlock": hex(start), "toBlock": hex(end), "address": addresses}],
        )
        if not isinstance(value, list):
            raise RunnerError("eth_getLogs returned a non-array")
        return value

    def call(self, transaction: dict[str, Any], block: str) -> str:
        value = self.request("eth_call", [transaction, block])
        return _bytes_hex(value, "eth_call result")

    def balance(self, address: str, block: int) -> int:
        return _quantity(
            self.request("eth_getBalance", [_address(address, "balance address"), hex(block)]),
            "eth_getBalance",
        )


def _selector(signature: str) -> str:
    return documents.keccak256(signature.encode())[2:10]


SELECTORS = {
    "approve": _selector("approve(address,uint256)"),
    "allowance": _selector("allowance(address,address)"),
    "balanceOf": _selector("balanceOf(address)"),
    "bondToken": _selector("bondToken()"),
    "execute": _selector("executeTreasuryTransfer((address,address,uint256,bytes32))"),
    "finalize": _selector("finalizeByTimeout(uint256)"),
    "getProposal": _selector("getProposal(uint256)"),
    "minBond": _selector("treasuryMinActivationBond()"),
    "placeYes": _selector("placeYesBond(uint256,uint256)"),
    "propose": _selector("proposeTransfer((address,address,uint256,bytes32))"),
    "queue": _selector("queueTreasuryTransfer((address,address,uint256,bytes32))"),
    "queuedActions": _selector("queuedActions(bytes32)"),
    "timeout": _selector("timeout()"),
}
PROPOSAL_NOT_FOUND = "0x" + _selector("ProposalNotFound()")

TOPICS = {
    name: documents.keccak256(signature.encode())
    for name, signature in {
        "proposalCreated": "ProposalCreated(uint256,address,uint256)",
        "transferProposed": "TransferProposed(uint256,address,address,address,uint256,bytes32)",
        "finalized": "FinalizedByTimeout(uint256,bool,address,uint256)",
        "resolved": "EvaluationResolved(uint256,bool,address,uint256)",
        "queued": "TreasuryTransferQueued(bytes32,uint256,uint256,uint256)",
        "executed": "TreasuryTransferExecuted(bytes32,address,address,uint256)",
    }.items()
}


def _hex(value: Any, size: int, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(f"0x[0-9a-fA-F]{{{size * 2}}}", value):
        raise RunnerError(f"{label} must be {size}-byte hex")
    return value.lower()


def _address(value: Any, label: str, *, allow_zero: bool = False) -> str:
    result = _hex(value, 20, label)
    if not allow_zero and result == "0x" + "00" * 20:
        raise RunnerError(f"{label} cannot be zero")
    return result


def _bytes_hex(value: Any, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", value):
        raise RunnerError(f"{label} must be byte hex")
    return value.lower()


def _quantity(value: Any, label: str) -> int:
    if isinstance(value, int) and 0 <= value <= UINT256_MAX:
        return value
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)", value):
        raise RunnerError(f"{label} must be a canonical nonnegative quantity")
    return int(value, 16)


def _decimal(value: Any, label: str) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0|[1-9][0-9]*", value):
        raise RunnerError(f"{label} must be a canonical decimal string")
    result = int(value)
    if result > UINT256_MAX:
        raise RunnerError(f"{label} exceeds uint256")
    return result


def _word(number: int) -> bytes:
    if not isinstance(number, int) or number < 0 or number > UINT256_MAX:
        raise RunnerError("ABI word is out of range")
    return number.to_bytes(32, "big")


def _address_word(address: str, *, allow_zero: bool = False) -> bytes:
    return bytes(12) + bytes.fromhex(_address(address, "ABI address", allow_zero=allow_zero)[2:])


def _action_words(action: dict[str, str]) -> bytes:
    return b"".join(
        (
            _address_word(action["asset"], allow_zero=True),
            _address_word(action["recipient"]),
            _word(_decimal(action["amount"], "action.amount")),
            bytes.fromhex(_hex(action["salt"], 32, "action.salt")[2:]),
        )
    )


def _call(selector: str, *words: bytes) -> str:
    return "0x" + selector + b"".join(words).hex()


def _words(value: str, count: int | None = None) -> list[bytes]:
    raw = bytes.fromhex(_bytes_hex(value, "ABI output")[2:])
    if len(raw) % 32 or (count is not None and len(raw) != count * 32):
        raise RunnerError("ABI output has the wrong length")
    return [raw[index : index + 32] for index in range(0, len(raw), 32)]


def _uint_call(caller: StaticCaller, to: str, data: str, block: str) -> int:
    return int.from_bytes(_words(caller.call({"to": to, "data": data}, block), 1)[0], "big")


def _address_call(caller: StaticCaller, to: str, data: str, block: str) -> str:
    word = _words(caller.call({"to": to, "data": data}, block), 1)[0]
    if any(word[:12]):
        raise RunnerError("ABI address has nonzero padding")
    return _address("0x" + word[12:].hex(), "ABI address")


def _canonical_log(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RunnerError("log must be an object")
    topics = value.get("topics")
    if not isinstance(topics, list) or not topics:
        raise RunnerError("log topics are missing")
    removed = value.get("removed", False)
    if not isinstance(removed, bool):
        raise RunnerError("log.removed must be boolean")
    return {
        "address": _address(value.get("address"), "log.address"),
        "blockHash": _hex(value.get("blockHash"), 32, "log.blockHash"),
        "blockNumber": _quantity(value.get("blockNumber"), "log.blockNumber"),
        "transactionHash": _hex(value.get("transactionHash"), 32, "log.transactionHash"),
        "logIndex": _quantity(value.get("logIndex"), "log.logIndex"),
        "topics": [_hex(topic, 32, "log.topic") for topic in topics],
        "data": _bytes_hex(value.get("data"), "log.data"),
        "removed": removed,
    }


def _config(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise RunnerError("config must be an object")
    required = {
        "chainId", "fromBlock", "index", "gateway", "arbitration", "vault", "executor",
        "automation", "documents", "caps",
    }
    if set(value) != required:
        raise RunnerError("config fields are invalid")
    docs = value["documents"]
    caps = value["caps"]
    if not isinstance(docs, dict) or set(docs) != {"task", "receipt", "payment"}:
        raise RunnerError("config.documents fields are invalid")
    if not isinstance(caps, dict) or set(caps) != {"paymentAmount", "bondAmount", "transactionValue"}:
        raise RunnerError("config.caps fields are invalid")
    if (
        not isinstance(value["chainId"], int) or isinstance(value["chainId"], bool)
        or not isinstance(value["fromBlock"], int) or isinstance(value["fromBlock"], bool)
    ):
        raise RunnerError("config chain and start block must be integers")
    normalized = {
        "chainId": value["chainId"],
        "fromBlock": value["fromBlock"],
        **{
            key: _address(value[key], f"config.{key}")
            for key in ("index", "gateway", "arbitration", "vault", "executor", "automation")
        },
        "documents": {
            "task": documents.build_task(docs["task"]),
            "receipt": documents.build_receipt(docs["receipt"]),
            "payment": documents.build_payment(docs["payment"]),
        },
        "caps": {key: _decimal(str(caps[key]), f"config.caps.{key}") for key in caps},
    }
    if normalized["chainId"] <= 0 or normalized["fromBlock"] < 0:
        raise RunnerError("config chain or start block is invalid")
    payment = documents.validate_payment(normalized["documents"]["payment"])
    if payment["chainId"] != str(normalized["chainId"]) or payment["vault"] != normalized["vault"]:
        raise RunnerError("payment domain does not match config")
    return normalized


def _prepared(config: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        name: documents.prepare_publication(name, config["documents"][name])
        for name in ("task", "receipt", "payment")
    }


def _proposal_view(raw: str) -> dict[str, Any]:
    words = _words(raw, 11)
    state = int.from_bytes(words[5], "big")
    booleans = [int.from_bytes(words[index], "big") for index in (7, 8, 10)]
    if (
        state >= len(STATE_NAMES) or any(value not in (0, 1) for value in booleans)
        or any(words[index][:12] != bytes(12) for index in (1, 3))
    ):
        raise RunnerError("proposal view is invalid")
    return {
        "minActivationBond": int.from_bytes(words[0], "big"),
        "yesBidder": "0x" + words[1][12:].hex(),
        "yesBondAmount": int.from_bytes(words[2], "big"),
        "noBidder": "0x" + words[3][12:].hex(),
        "noBondAmount": int.from_bytes(words[4], "big"),
        "state": STATE_NAMES[state],
        "lastStateChangeAt": int.from_bytes(words[6], "big"),
        "settled": bool(booleans[0]),
        "accepted": bool(booleans[1]),
        "queuePosition": int.from_bytes(words[9], "big"),
        "exists": bool(booleans[2]),
    }


def _balance(caller: JsonRpc, asset: str, account: str, block: int) -> int:
    if asset == "0x" + "00" * 20:
        return caller.balance(account, block)
    return _uint_call(
        caller,
        asset,
        _call(SELECTORS["balanceOf"], _address_word(account)),
        hex(block),
    )


def _revert_data(value: Any) -> str | None:
    while isinstance(value, dict):
        value = value.get("data")
    return value.lower() if isinstance(value, str) and re.fullmatch(r"0x[0-9a-fA-F]*", value) else None


def collect_snapshot(rpc: JsonRpc, config_value: Any) -> dict[str, Any]:
    """Read one complete finalized snapshot or fail before any signer call."""

    config = _config(config_value)
    if rpc.chain_id() != config["chainId"]:
        raise RunnerError("RPC chainId does not match config")
    final_raw = rpc.finalized_block()
    final = {
        "number": _quantity(final_raw.get("number"), "finalized.number"),
        "hash": _hex(final_raw.get("hash"), 32, "finalized.hash"),
        "timestamp": _quantity(final_raw.get("timestamp"), "finalized.timestamp"),
    }
    if final["number"] < config["fromBlock"]:
        raise RunnerError("finalized head precedes config.fromBlock")

    # ponytail: a single short lineage walk; add chunking only when a real deployment needs it.
    lineage: dict[int, str] = {}
    previous: str | None = None
    for number in range(config["fromBlock"], final["number"] + 1):
        raw = final_raw if number == final["number"] else rpc.block(number)
        block_hash = _hex(raw.get("hash"), 32, "block.hash")
        parent = _hex(raw.get("parentHash"), 32, "block.parentHash")
        if previous is not None and parent != previous:
            raise RunnerError("finalized block lineage is discontinuous")
        lineage[number] = block_hash
        previous = block_hash

    watched = [config[key] for key in ("index", "gateway", "arbitration", "vault")]
    logs = []
    for raw in rpc.logs(config["fromBlock"], final["number"], watched):
        log = _canonical_log(raw)
        if log["removed"]:
            continue
        if lineage.get(log["blockNumber"]) != log["blockHash"]:
            raise RunnerError("log is not on the finalized lineage")
        logs.append(log)
    logs.sort(key=lambda item: (item["blockNumber"], item["logIndex"]))
    if len({(item["blockHash"], item["logIndex"]) for item in logs}) != len(logs):
        raise RunnerError("duplicate finalized log position")

    block = hex(final["number"])
    prepared = _prepared(config)
    payment = documents.validate_payment(config["documents"]["payment"])
    action = documents.payment_transfer_action(config["documents"]["payment"])
    proposal_id = int(documents.validate_payment_binding(
        config["documents"]["payment"], config["chainId"], config["vault"], action
    ), 16)
    proposal_data = _call(SELECTORS["getProposal"], _word(proposal_id))
    try:
        proposal = _proposal_view(rpc.call({"to": config["arbitration"], "data": proposal_data}, block))
    except RpcCallError as exc:
        if _revert_data(exc.data) != PROPOSAL_NOT_FOUND:
            raise
        proposal = None
    queued_words = _words(
        rpc.call(
            {"to": config["vault"], "data": _call(SELECTORS["queuedActions"], _word(proposal_id))},
            block,
        ),
        4,
    )
    queued = {
        "executeAfter": int.from_bytes(queued_words[0], "big"),
        "expiresAt": int.from_bytes(queued_words[1], "big"),
        "executed": bool(int.from_bytes(queued_words[2], "big")),
        "expired": bool(int.from_bytes(queued_words[3], "big")),
    }
    if any(int.from_bytes(word, "big") not in (0, 1) for word in queued_words[2:]):
        raise RunnerError("queued action booleans are invalid")
    min_bond = _uint_call(rpc, config["gateway"], "0x" + SELECTORS["minBond"], block)
    timeout = _uint_call(rpc, config["arbitration"], "0x" + SELECTORS["timeout"], block)
    bond_token = _address_call(rpc, config["arbitration"], "0x" + SELECTORS["bondToken"], block)
    allowance = _uint_call(
        rpc,
        bond_token,
        _call(
            SELECTORS["allowance"],
            _address_word(config["automation"]),
            _address_word(config["arbitration"]),
        ),
        block,
    )
    execute_tx = {
        "from": config["automation"],
        "to": config["vault"],
        "data": _call(SELECTORS["execute"], _action_words(action)),
        "value": "0x0",
    }
    try:
        rpc.call(execute_tx, block)
        execution_ok = True
    except RpcCallError:
        execution_ok = False

    executed_logs = [
        log
        for log in logs
        if log["address"] == config["vault"]
        and log["topics"][0] == TOPICS["executed"]
        and len(log["topics"]) == 4
        and log["topics"][1] == "0x" + proposal_id.to_bytes(32, "big").hex()
    ]
    balance_proof = None
    if executed_logs:
        if len(executed_logs) != 1 or executed_logs[0]["blockNumber"] == 0:
            raise RunnerError("payment execution log cardinality is invalid")
        paid_block = executed_logs[0]["blockNumber"]
        balance_proof = {
            "beforeBlock": paid_block - 1,
            "afterBlock": paid_block,
            "executorBefore": _balance(rpc, payment["asset"], config["executor"], paid_block - 1),
            "executorAfter": _balance(rpc, payment["asset"], config["executor"], paid_block),
            "recipientBefore": _balance(rpc, payment["asset"], payment["recipient"], paid_block - 1),
            "recipientAfter": _balance(rpc, payment["asset"], payment["recipient"], paid_block),
        }
    return {
        "finalized": final,
        "logs": logs,
        "views": {
            "proposal": proposal,
            "queued": queued,
            "minimumBond": min_bond,
            "timeout": timeout,
            "bondToken": bond_token,
            "allowance": allowance,
            "executionSimulationOk": execution_ok,
            "balanceProof": balance_proof,
        },
        "prepared": {name: prepared[name]["documentDigest"] for name in prepared},
    }


def _event_words(log: dict[str, Any], count: int) -> list[bytes]:
    return _words(log["data"], count)


def derive_state(config_value: Any, snapshot: Any) -> dict[str, Any]:
    """Purely derive one lifecycle view from exact finalized logs and pinned views."""

    config = _config(config_value)
    if not isinstance(snapshot, dict) or set(snapshot) != {"finalized", "logs", "views", "prepared"}:
        raise RunnerError("snapshot fields are invalid")
    final = snapshot["finalized"]
    if not isinstance(final, dict) or set(final) != {"number", "hash", "timestamp"}:
        raise RunnerError("finalized block fields are invalid")
    final = {
        "number": _quantity(final["number"], "finalized.number"),
        "hash": _hex(final["hash"], 32, "finalized.hash"),
        "timestamp": _quantity(final["timestamp"], "finalized.timestamp"),
    }
    now = final["timestamp"]
    raw_logs = snapshot["logs"]
    views = snapshot["views"]
    if not isinstance(raw_logs, list) or not isinstance(views, dict):
        raise RunnerError("snapshot logs or views are invalid")
    logs = [_canonical_log(value) for value in raw_logs]
    if logs != sorted(logs, key=lambda item: (item["blockNumber"], item["logIndex"])):
        raise RunnerError("snapshot logs are not canonically ordered")
    if len({(item["blockHash"], item["logIndex"]) for item in logs}) != len(logs):
        raise RunnerError("snapshot has a duplicate log position")

    prepared = _prepared(config)
    payment = documents.validate_payment(config["documents"]["payment"])
    receipt = documents.validate_receipt(config["documents"]["receipt"])
    if receipt["task"] != prepared["task"]["documentDigest"]:
        raise RunnerError("receipt is not parented to the configured task")
    if payment["task"] != receipt["task"] or payment["receipt"] != prepared["receipt"]["documentDigest"]:
        raise RunnerError("payment lineage does not match the configured receipt")
    action = documents.payment_transfer_action(config["documents"]["payment"])
    action_hash = documents.validate_payment_binding(
        config["documents"]["payment"], config["chainId"], config["vault"], action
    )
    proposal_id = int(action_hash, 16)
    action_topic = "0x" + proposal_id.to_bytes(32, "big").hex()

    publications: dict[str, dict[str, Any]] = {}
    hostile = []
    decoded_logs = []
    schemas = {
        documents.TASK_KIND: "task",
        documents.RECEIPT_KIND: "receipt",
        documents.PAYMENT_KIND: "payment",
    }
    for log in logs:
        if log["address"] != config["index"] or log["topics"][0] != documents.PUBLISHED_TOPIC:
            continue
        try:
            decoded = documents.decode_published_log({"topics": log["topics"], "data": log["data"]})
            validator = documents.VALIDATORS.get(schemas.get(decoded["kind"], ""))
            if validator is not None:
                validator(decoded["document"])
            decoded_logs.append((log, decoded))
        except documents.DocumentError as exc:
            hostile.append({"transactionHash": log["transactionHash"], "reason": str(exc)})
    for name in ("task", "receipt", "payment"):
        expected = prepared[name]
        matches = []
        for log, decoded in decoded_logs:
            if (
                decoded["kind"] == expected["kind"]
                and decoded["parentDigest"] == expected["parentDigest"]
                and decoded["documentDigest"] == expected["documentDigest"]
                and decoded["document"] == expected["document"]
            ):
                matches.append(log)
        publications[name] = {
            "published": bool(matches),
            "occurrences": len(matches),
            "digest": expected["documentDigest"],
            "firstLog": None if not matches else matches[0],
        }

    proposal = views.get("proposal")
    proposal_created = [
        log for log in logs
        if log["address"] == config["arbitration"] and log["topics"][0] == TOPICS["proposalCreated"]
        and len(log["topics"]) == 3 and log["topics"][1] == action_topic
    ]
    transfer_proposed = [
        log for log in logs
        if log["address"] == config["gateway"] and log["topics"][0] == TOPICS["transferProposed"]
        and len(log["topics"]) == 4 and log["topics"][1] == action_topic
    ]
    proposed = proposal is not None
    if proposed and (len(proposal_created) != 1 or len(transfer_proposed) != 1):
        raise RunnerError("proposal view lacks exact creation and transfer logs")
    if not proposed and (proposal_created or transfer_proposed):
        raise RunnerError("proposal logs disagree with proposal view")
    if transfer_proposed:
        words = _event_words(transfer_proposed[0], 3)
        logged_recipient = "0x" + words[0][12:].hex()
        if (
            transfer_proposed[0]["topics"][3] != "0x" + bytes(12).hex() + action["asset"][2:]
            or logged_recipient != action["recipient"]
            or int.from_bytes(words[1], "big") != int(action["amount"])
            or "0x" + words[2].hex() != action["salt"]
        ):
            raise RunnerError("TransferProposed does not match payment binding")
    if proposal_created:
        created = proposal_created[0]
        if (
            created["topics"][2] != "0x" + bytes(12).hex() + config["gateway"][2:]
            or int.from_bytes(_event_words(created, 1)[0], "big")
            != int(views["minimumBond"])
        ):
            raise RunnerError("ProposalCreated does not match the gateway bond binding")

    settlement = [
        log for log in logs
        if log["address"] == config["arbitration"]
        and log["topics"][0] in (TOPICS["finalized"], TOPICS["resolved"])
        and len(log["topics"]) == 3 and log["topics"][1] == action_topic
    ]
    accepted = rejected = False
    acceptance_route = None
    if proposal is not None and proposal["settled"]:
        if len(settlement) != 1:
            raise RunnerError("settled proposal lacks one matching finalized arbitration log")
        accepted_word = int.from_bytes(_event_words(settlement[0], 2)[0], "big")
        if accepted_word not in (0, 1) or bool(accepted_word) != bool(proposal["accepted"]):
            raise RunnerError("accepted view and finalized arbitration log disagree")
        accepted = bool(accepted_word)
        rejected = not accepted
        acceptance_route = "timeout" if settlement[0]["topics"][0] == TOPICS["finalized"] else "evaluated"
    elif settlement:
        raise RunnerError("finalized arbitration log disagrees with proposal view")

    queued = views.get("queued")
    if not isinstance(queued, dict):
        raise RunnerError("queued view is missing")
    queue_logs = [
        log for log in logs
        if log["address"] == config["vault"] and log["topics"][0] == TOPICS["queued"]
        and len(log["topics"]) == 3 and log["topics"][1] == action_topic
        and log["topics"][2] == action_topic
    ]
    is_queued = int(queued["executeAfter"]) != 0
    if is_queued:
        if len(queue_logs) != 1:
            raise RunnerError("queued view lacks one matching queue log")
        queue_words = _event_words(queue_logs[0], 2)
        if [int.from_bytes(word, "big") for word in queue_words] != [
            int(queued["executeAfter"]), int(queued["expiresAt"])
        ]:
            raise RunnerError("queue event and view disagree")
    elif queue_logs:
        raise RunnerError("queue log disagrees with queued view")

    execution_logs = [
        log for log in logs
        if log["address"] == config["vault"] and log["topics"][0] == TOPICS["executed"]
        and len(log["topics"]) == 4 and log["topics"][1] == action_topic
    ]
    paid = bool(queued.get("executed", False))
    if paid:
        if len(execution_logs) != 1:
            raise RunnerError("executed view lacks one matching treasury log")
        event = execution_logs[0]
        if (
            event["topics"][2] != "0x" + bytes(12).hex() + action["asset"][2:]
            or event["topics"][3] != "0x" + bytes(12).hex() + action["recipient"][2:]
            or int.from_bytes(_event_words(event, 1)[0], "big") != int(action["amount"])
        ):
            raise RunnerError("treasury execution log does not match exact action")
        proof = views.get("balanceProof")
        amount = int(action["amount"])
        if not isinstance(proof, dict) or (
            int(proof["executorBefore"]) - int(proof["executorAfter"]) != amount
            or int(proof["recipientAfter"]) - int(proof["recipientBefore"]) != amount
            or int(proof["executorBefore"]) + int(proof["recipientBefore"])
            != int(proof["executorAfter"]) + int(proof["recipientAfter"])
        ):
            raise RunnerError("paid balance deltas do not conserve the exact transfer")
    elif execution_logs:
        raise RunnerError("treasury execution log disagrees with executed view")

    expired = bool(queued.get("expired", False)) or (
        is_queued and now > int(queued["expiresAt"]) and not paid
    )
    executable = (
        accepted and is_queued and not paid and not expired
        and now >= int(queued["executeAfter"]) and bool(views.get("executionSimulationOk"))
    )
    shortfall = (
        accepted and is_queued and not paid and not expired
        and now >= int(queued["executeAfter"]) and not bool(views.get("executionSimulationOk"))
    )

    if paid:
        lifecycle = "PAID"
    elif expired:
        lifecycle = "EXPIRED"
    elif executable:
        lifecycle = "EXECUTABLE"
    elif shortfall:
        lifecycle = "SHORTFALL"
    elif accepted and is_queued:
        lifecycle = "QUEUED"
    elif accepted:
        lifecycle = "ACCEPTED"
    elif rejected:
        lifecycle = "REJECTED"
    elif proposal and proposal["state"] in ("YES", "NO", "QUEUED", "EVALUATING", "SETTLED"):
        lifecycle = "BONDED" if proposal["yesBondAmount"] else "PROPOSED"
    elif proposed:
        lifecycle = "PROPOSED"
    elif publications["payment"]["published"]:
        lifecycle = "PAYMENT_PUBLISHED"
    elif publications["receipt"]["published"]:
        lifecycle = "RECEIPT_PUBLISHED"
    elif publications["task"]["published"]:
        lifecycle = "TASK_PUBLISHED"
    else:
        lifecycle = "IDLE"

    return {
        "lifecycle": lifecycle,
        "finalized": final,
        "publications": publications,
        "hostileDocuments": hostile,
        "action": action,
        "actionHash": action_hash,
        "proposalId": str(proposal_id),
        "proposal": proposal,
        "accepted": accepted,
        "rejected": rejected,
        "acceptanceRoute": acceptance_route,
        "queued": queued,
        "executable": executable,
        "shortfall": shortfall,
        "paid": paid,
        "views": views,
    }


def next_action(config_value: Any, state: Any) -> Action | None:
    """Choose at most one deterministic transaction from a fully derived state."""

    config = _config(config_value)
    if not isinstance(state, dict):
        raise RunnerError("state must be an object")
    prepared = _prepared(config)
    for name in ("task", "receipt", "payment"):
        if not state["publications"][name]["published"]:
            item = prepared[name]
            return Action(f"publish-{name}", config["index"], item["calldata"])

    action = state["action"]
    proposal_id = int(state["proposalId"])
    if state["proposal"] is None:
        return Action(
            "propose",
            config["gateway"],
            _call(SELECTORS["propose"], _action_words(action)),
        )
    proposal = state["proposal"]
    if proposal["settled"]:
        if not proposal["accepted"]:
            return None
        if not state["queued"]["executeAfter"]:
            return Action("queue", config["vault"], _call(SELECTORS["queue"], _action_words(action)))
        if state["executable"]:
            return Action(
                "execute",
                config["vault"],
                _call(SELECTORS["execute"], _action_words(action)),
                "paymentAmount",
                int(action["amount"]),
            )
        return None

    min_bond = int(state["views"]["minimumBond"])
    if proposal["state"] == "INACTIVE":
        if int(state["views"]["allowance"]) < min_bond:
            return Action(
                "approve-bond",
                state["views"]["bondToken"],
                _call(SELECTORS["approve"], _address_word(config["arbitration"]), _word(min_bond)),
                "bondAmount",
                min_bond,
            )
        return Action(
            "place-yes-bond",
            config["arbitration"],
            _call(SELECTORS["placeYes"], _word(proposal_id), _word(min_bond)),
            "bondAmount",
            min_bond,
        )
    if proposal["state"] == "YES" and int(state["finalized"]["timestamp"]) >= (
        int(proposal["lastStateChangeAt"]) + int(state["views"]["timeout"])
    ):
        return Action("finalize-timeout", config["arbitration"], _call(SELECTORS["finalize"], _word(proposal_id)))
    # QUEUED/EVALUATING outcomes belong to the resolver; this runner only observes them.
    return None


def _check_cap(config: dict[str, Any], action: Action) -> None:
    if action.cap_kind not in config["caps"] or action.cap_amount > config["caps"][action.cap_kind]:
        raise RunnerError(f"{action.cap_kind} cap exhausted")


def tick(
    config_value: Any,
    rpc: JsonRpc,
    caller: StaticCaller,
    sender: TransactionSender,
) -> dict[str, Any]:
    """Re-derive, simulate, cap-check and send no more than one unsigned transaction."""

    config = _config(config_value)
    snapshot = collect_snapshot(rpc, config_value)
    state = derive_state(config_value, snapshot)
    action = next_action(config_value, state)
    if action is None:
        return {"state": state, "action": None, "attempts": []}
    transaction = action.transaction(config["automation"], config["chainId"])
    attempt = {"kind": action.kind, "transaction": transaction, "simulation": "pending", "outcome": "not-sent"}
    try:
        result = caller.call(transaction, hex(int(state["finalized"]["number"])))
        _bytes_hex(result, "simulation result")
        attempt["simulation"] = "ok"
    except Exception as exc:
        attempt.update(simulation="failed", error=str(exc))
        return {"state": state, "action": action.kind, "attempts": [attempt]}
    try:
        _check_cap(config, action)
    except RunnerError as exc:
        attempt.update(outcome="cap-refused", error=str(exc))
        return {"state": state, "action": action.kind, "attempts": [attempt]}
    try:
        attempt["transactionHash"] = _hex(sender.send(transaction), 32, "transaction hash")
        attempt["outcome"] = "submitted"
    except Exception as exc:
        attempt.update(outcome="signer-failed", error=str(exc))
    return {"state": state, "action": action.kind, "attempts": [attempt]}


def canonical_json(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def write_evidence(path: Path, evidence: Any) -> str:
    if not isinstance(evidence, dict) or evidence.get("kind") != "fao.agentwork.p1-evidence" or evidence.get("v") != "1":
        raise RunnerError("P1 evidence kind or version is invalid")
    drills = evidence.get("drills")
    if not isinstance(drills, list) or not drills or any(item.get("status") != "pass" for item in drills):
        raise RunnerError("evidence may contain only drills that actually passed")
    raw = canonical_json(evidence) + b"\n"
    digest = "0x" + hashlib.sha256(raw).hexdigest()
    path.write_bytes(raw)
    path.with_suffix(path.suffix + ".sha256").write_text(digest + "\n", encoding="ascii")
    return digest
