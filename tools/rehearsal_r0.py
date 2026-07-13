#!/usr/bin/env python3
"""Run the fork-only Rehearsal R0 composed FAO/FLM loop twice."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import time
from decimal import Decimal, localcontext
from pathlib import Path
from typing import Any, Sequence
from urllib.parse import urlsplit

try:
    from tools import agent_anvil_drill as drill
    from tools import agent_documents as documents
    from tools import agent_runner as runner
    from tools.windtunnel import anvil_drill as windtunnel
except ModuleNotFoundError:  # Direct script execution.
    import agent_anvil_drill as drill  # type: ignore
    import agent_documents as documents  # type: ignore
    import agent_runner as runner  # type: ignore
    from windtunnel import anvil_drill as windtunnel  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "script/RehearsalR0.s.sol"
CHAIN_ID = 11_155_111
FORK_SELECTED_FROM_HEAD = 11_265_083
FORK_BLOCK = 11_265_000
FORK_BLOCK_HASH = "0xa493de27f3173b07abfc718634acd5bcafbfd7e1d4583ad824b1dee7e7d9cd29"
FORK_TIMESTAMP = 1_783_960_236
FEE = 500
WAD = 10**18
ZERO32 = "0x" + "00" * 32
UNSTABLE_POOL = "0x82cfae81"

DEPENDENCIES = {
    "conditionalTokens": {
        "address": "0x8bdc504dc3a05310059c1c67e0a2667309d27b93",
        "runtimeHash": "0x962883a35da553c2d46562f362ba99f68041dad91de30a143a785b2d169c7e81",
    },
    "positionManager": {
        "address": "0x1238536071e1c677a632429e3655c799b22cda52",
        "runtimeHash": "0x390d49631aefbf890c9415457b4639243ff16092ded43ce8f885fde8a5a34868",
    },
    "swapRouter02": {
        "address": "0x3bfa4769fb09eefc5a80d6e87c3b9c650f7ae48e",
        "runtimeHash": "0xe7f98ee73dfe6d5c96cbf8936920f496b1b82f24326d6a415b4144a2252271de",
    },
    "sxProposalValidation": {
        "address": "0x9a39194f870c410633c170889e9025fba2113c79",
        "runtimeHash": "0xddd4560ead7f2c3de35f37de8d50c43e57f0173ad3eefd20098c3b6e08cba9d8",
    },
    "sxProxyFactory": {
        "address": "0x4b4f7f64be813ccc66aefc3bfce2baa01188631c",
        "runtimeHash": "0x9d58d183bb98c199c270f0f2ba7c0abbda1a119caef4c136e137bbacca8c4035",
    },
    "sxSpaceImplementation": {
        "address": "0xc3031a7d3326e47d49bff9d374d74f364b29ce4d",
        "runtimeHash": "0x4f2f90c70374b7dcd468d351747e9c865efc0d47e606eb6fdaeb2a842c148d81",
    },
    "uniswapV3Factory": {
        "address": "0x0227628f3f023bb0b980b67d528571c95c6dac1c",
        "runtimeHash": "0xacb5afea1f8877239fadd30358add13f2f9d4fb80175402c686d392295224fef",
    },
    "weth": {
        "address": "0xfff9976782d46cc05630d1f6ebab18b2324d6b14",
        "runtimeHash": "0xc864e10689f2da18833652a3b075d43106e87f0f90d95ee64f6f0b33bc026083",
    },
    "wrapped1155Factory": {
        "address": "0xd194319d1804c1051dd21ba1dc931ca72410b79f",
        "runtimeHash": "0x792e0ae192d66bc58541831991b449cd2ba502fe0053507d6c4493d8865371b6",
    },
}
WETH = DEPENDENCIES["weth"]["address"]
CTF = DEPENDENCIES["conditionalTokens"]["address"]
W1155 = DEPENDENCIES["wrapped1155Factory"]["address"]
UNIV3_FACTORY = DEPENDENCIES["uniswapV3Factory"]["address"]
NPM = DEPENDENCIES["positionManager"]["address"]
SWAP_ROUTER = DEPENDENCIES["swapRouter02"]["address"]

ACTORS = {
    name: "0x100000000000000000000000000000000000%04x" % ordinal
    for ordinal, name in enumerate(
        (
            "deployer",
            "funder1",
            "funder2",
            "funder3",
            "funder4",
            "proposer",
            "yesBidder",
            "noBidder",
            "keeper",
            "trader",
            "recipient",
        ),
        1,
    )
}


class RehearsalError(ValueError):
    pass


def _run(command: Sequence[str], *, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
    if result.returncode:
        raise RehearsalError("command failed: %s\n%s" % (" ".join(command), result.stderr[-3000:]))
    return result.stdout.strip()


def _canonical(value: Any) -> bytes:
    return runner.canonical_json(value) + b"\n"


def _sha256(value: Any) -> str:
    return "0x" + hashlib.sha256(_canonical(value)).hexdigest()


def _pin_for_head(head: int) -> int:
    if head < 1_064:
        raise RehearsalError("Sepolia head is too low to pin")
    return ((head - 64) // 1_000) * 1_000


def _provider(url: str) -> str:
    parsed = urlsplit(url)
    if (
        parsed.scheme != "https"
        or not parsed.hostname
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in ("", "/")
        or parsed.query
        or parsed.fragment
    ):
        raise RehearsalError("fork URL must be a credential-free HTTPS origin")
    return url


def _loopback(url: str) -> str:
    parsed = urlsplit(url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "::1"):
        raise RehearsalError("transaction RPC must be loopback HTTP")
    return url


def _preflight(fork_url: str) -> None:
    if _pin_for_head(FORK_SELECTED_FROM_HEAD) != FORK_BLOCK:
        raise RehearsalError("fresh-pin derivation drifted")
    block = json.loads(
        _run(("cast", "block", str(FORK_BLOCK), "--json", "--rpc-url", fork_url))
    )
    if (
        str(block.get("hash", "")).lower() != FORK_BLOCK_HASH
        or int(block.get("timestamp", "0x0"), 16) != FORK_TIMESTAMP
    ):
        raise RehearsalError("pinned Sepolia block identity drifted")
    for dependency in DEPENDENCIES.values():
        code = _run(
            (
                "cast",
                "code",
                dependency["address"],
                "--block",
                str(FORK_BLOCK),
                "--rpc-url",
                fork_url,
            )
        )
        if code == "0x" or documents.keccak256(bytes.fromhex(code[2:])) != dependency["runtimeHash"]:
            raise RehearsalError("pinned dependency runtime drifted: " + dependency["address"])


def _calldata(signature: str, *arguments: Any) -> str:
    return _run(("cast", "calldata", signature, *(str(value) for value in arguments))).lower()


def _words(value: str, count: int | None = None) -> list[bytes]:
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{64})*", value):
        raise RehearsalError("malformed ABI words")
    raw = bytes.fromhex(value[2:])
    if count is not None and len(raw) != 32 * count:
        raise RehearsalError("wrong ABI word count")
    return [raw[index : index + 32] for index in range(0, len(raw), 32)]


def _uint_word(word: bytes) -> int:
    return int.from_bytes(word, "big")


def _signed_word(word: bytes, bits: int) -> int:
    value = _uint_word(word) & ((1 << bits) - 1)
    return value - (1 << bits) if value & (1 << (bits - 1)) else value


def _address_word(word: bytes) -> str:
    if len(word) != 32 or any(word[:12]):
        raise RehearsalError("malformed ABI address")
    return "0x" + word[12:].hex()


def _dynamic_bytes(value: str) -> bytes:
    raw = bytes.fromhex(value[2:])
    if len(raw) < 64:
        raise RehearsalError("malformed dynamic ABI output")
    offset = int.from_bytes(raw[:32], "big")
    if offset + 32 > len(raw):
        raise RehearsalError("dynamic ABI offset is out of range")
    size = int.from_bytes(raw[offset : offset + 32], "big")
    payload = raw[offset + 32 : offset + 32 + size]
    if len(payload) != size:
        raise RehearsalError("dynamic ABI payload is truncated")
    return payload


def _dynamic_int_array(value: str, output_index: int, bits: int) -> list[int]:
    raw = bytes.fromhex(value[2:])
    head = 32 * (output_index + 1)
    if len(raw) < head:
        raise RehearsalError("dynamic array ABI head is truncated")
    offset = int.from_bytes(raw[32 * output_index : head], "big")
    if offset + 32 > len(raw):
        raise RehearsalError("dynamic array ABI offset is out of range")
    size = int.from_bytes(raw[offset : offset + 32], "big")
    end = offset + 32 * (size + 1)
    if end > len(raw):
        raise RehearsalError("dynamic array ABI payload is truncated")
    return [
        _signed_word(raw[offset + 32 * (index + 1) : offset + 32 * (index + 2)], bits)
        for index in range(size)
    ]


def _trunc_div(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise RehearsalError("division denominator must be positive")
    return numerator // denominator if numerator >= 0 else -((-numerator) // denominator)


def _mean_tick(
    rpc: runner.JsonRpc,
    pool: str,
    company_wrapper: str,
    start_ago: int,
    end_ago: int,
    window: int,
) -> int:
    if start_ago <= end_ago or start_ago - end_ago != window:
        raise RehearsalError("TWAP secondsAgos do not describe the exact window")
    result = _call(rpc, pool, "observe(uint32[])", "[%d,%d]" % (start_ago, end_ago))
    cumulatives = _dynamic_int_array(result, 0, 56)
    if len(cumulatives) != 2:
        raise RehearsalError("UniV3 observe returned the wrong cumulative count")
    mean = _trunc_div(cumulatives[1] - cumulatives[0], window)
    return mean if _address(rpc, pool, "token0()") == company_wrapper else -mean


def _call(rpc: runner.JsonRpc, target: str, signature: str, *arguments: Any) -> str:
    return rpc.call({"to": target, "data": _calldata(signature, *arguments)}, "latest")


def _uint(rpc: runner.JsonRpc, target: str, signature: str, *arguments: Any) -> int:
    return _uint_word(_words(_call(rpc, target, signature, *arguments), 1)[0])


def _address(rpc: runner.JsonRpc, target: str, signature: str, *arguments: Any) -> str:
    return _address_word(_words(_call(rpc, target, signature, *arguments), 1)[0])


def _bool(rpc: runner.JsonRpc, target: str, signature: str, *arguments: Any) -> bool:
    value = _uint(rpc, target, signature, *arguments)
    if value not in (0, 1):
        raise RehearsalError("malformed ABI bool")
    return bool(value)


def _bytes32(rpc: runner.JsonRpc, target: str, signature: str, *arguments: Any) -> str:
    return "0x" + _words(_call(rpc, target, signature, *arguments), 1)[0].hex()


def _balance(rpc: runner.JsonRpc, token: str, account: str) -> int:
    return _uint(rpc, token, "balanceOf(address)", account)


def _slot0(rpc: runner.JsonRpc, pool: str) -> dict[str, int]:
    words = _words(_call(rpc, pool, "slot0()"), 7)
    return {
        "feeProtocol": _uint_word(words[5]),
        "observationCardinality": _uint_word(words[3]),
        "observationCardinalityNext": _uint_word(words[4]),
        "observationIndex": _uint_word(words[2]),
        "sqrtPriceX96": _uint_word(words[0]),
        "tick": _signed_word(words[1], 24),
        "unlocked": _uint_word(words[6]),
    }


def _economic_tick(rpc: runner.JsonRpc, pool: str, company: str) -> int:
    raw = _slot0(rpc, pool)["tick"]
    return raw if _address(rpc, pool, "token0()") == company else -raw


def _sqrt_at_tick(tick: int) -> int:
    if tick < -887_272 or tick > 887_272:
        raise RehearsalError("tick is outside UniV3 bounds")
    with localcontext() as context:
        context.prec = 100
        return int((Decimal("1.0001") ** (Decimal(tick) / 2)) * (1 << 96))


def _invert_sqrt_price(sqrt_price_x96: int) -> int:
    if sqrt_price_x96 <= 0:
        raise RehearsalError("cannot invert an empty pool price")
    return (1 << 192) // sqrt_price_x96


def _price_limit(rpc: runner.JsonRpc, pool: str, company: str, economic_move: int) -> int:
    raw_tick = _slot0(rpc, pool)["tick"]
    target = raw_tick + economic_move if _address(rpc, pool, "token0()") == company else raw_tick - economic_move
    return _sqrt_at_tick(target)


def _pool_evidence(rpc: runner.JsonRpc, pool: str) -> dict[str, Any]:
    return {
        "fee": _uint(rpc, pool, "fee()"),
        "liquidity": _uint(rpc, pool, "liquidity()"),
        "slot0": _slot0(rpc, pool),
        "tickSpacing": _uint(rpc, pool, "tickSpacing()"),
        "token0": _address(rpc, pool, "token0()"),
        "token1": _address(rpc, pool, "token1()"),
    }


def _wrapped_outcome(rpc: runner.JsonRpc, proposal: str, index: int) -> tuple[str, bytes]:
    raw = bytes.fromhex(_call(rpc, proposal, "wrappedOutcome(uint256)", index)[2:])
    if len(raw) < 96:
        raise RehearsalError("wrapped outcome is malformed")
    wrapper = _address_word(raw[:32])
    offset = int.from_bytes(raw[32:64], "big")
    size = int.from_bytes(raw[offset : offset + 32], "big")
    data = raw[offset + 32 : offset + 32 + size]
    if len(data) != size:
        raise RehearsalError("wrapped outcome data is truncated")
    return wrapper, data


def _binding(rpc: runner.JsonRpc, resolver: str, proposal: str) -> dict[str, Any]:
    words = _words(_call(rpc, resolver, "bindings(address)", proposal), 8)
    return {
        "yesPool": _address_word(words[0]),
        "noPool": _address_word(words[1]),
        "companyToken": _address_word(words[2]),
        "currencyToken": _address_word(words[3]),
        "questionId": "0x" + words[4].hex(),
        "anchorTimestamp": _uint_word(words[5]),
        "resolved": bool(_uint_word(words[6])),
        "accepted": bool(_uint_word(words[7])),
    }


def _runtime_hash(rpc: runner.JsonRpc, address: str) -> str:
    code = rpc.request("eth_getCode", [address, "latest"])
    if not isinstance(code, str) or code == "0x":
        raise RehearsalError("expected deployed runtime at " + address)
    return documents.keccak256(bytes.fromhex(code[2:]))


def _receipt_address(log: dict[str, Any]) -> str:
    topics = log.get("topics")
    if not isinstance(topics, list) or len(topics) != 4:
        raise RehearsalError("GenesisStaged log is malformed")
    return _address_word(bytes.fromhex(topics[1][2:]))


def _log_digest(logs: Any) -> str:
    if not isinstance(logs, list):
        raise RehearsalError("receipt logs are malformed")
    normalized = [
        {
            "address": str(log["address"]).lower(),
            "data": str(log["data"]).lower(),
            "logIndex": int(log["logIndex"], 16),
            "topics": [str(topic).lower() for topic in log["topics"]],
        }
        for log in logs
    ]
    return _sha256(normalized)


def _block_transactions(rpc: runner.JsonRpc, start: int, end: int) -> list[dict[str, Any]]:
    result = []
    for number in range(start, end + 1):
        block = rpc.request("eth_getBlockByNumber", [hex(number), True])
        if not isinstance(block, dict):
            raise RehearsalError("deployment block disappeared")
        for transaction in block.get("transactions", []):
            receipt = rpc.request("eth_getTransactionReceipt", [transaction["hash"]])
            if not isinstance(receipt, dict) or int(receipt["status"], 16) != 1:
                raise RehearsalError("deployment transaction failed")
            result.append(
                {
                    "blockNumber": number,
                    "blockTimestamp": int(block["timestamp"], 16),
                    "from": transaction["from"].lower(),
                    "gasUsed": int(receipt["gasUsed"], 16),
                    "hash": transaction["hash"].lower(),
                    "inputKeccak256": documents.keccak256(bytes.fromhex(transaction["input"][2:])),
                    "logCount": len(receipt["logs"]),
                    "logsSha256": _log_digest(receipt["logs"]),
                    "nonce": int(transaction["nonce"], 16),
                    "to": transaction.get("to").lower() if transaction.get("to") else None,
                    "value": str(int(transaction["value"], 16)),
                }
            )
    return result


def _burned_npm_position(rpc: runner.JsonRpc, token_id: int) -> dict[str, Any]:
    try:
        _call(rpc, NPM, "ownerOf(uint256)", token_id)
    except runner.RpcCallError as error:
        if not error.data:
            raise RehearsalError("burned NPM position returned no revert data") from error
        return {"ownerOfReverted": True, "tokenId": str(token_id)}
    raise RehearsalError("original conditional NPM position still exists")


def _decode_unstable(data: str) -> dict[str, Any]:
    if not data.startswith(UNSTABLE_POOL) or len(data) != 2 + 8 + 64 * 3:
        raise RehearsalError("UnstablePool revert payload is malformed")
    words = _words("0x" + data[10:], 3)
    return {
        "pool": _address_word(words[0]),
        "currentTick": _signed_word(words[1], 24),
        "meanTick": _signed_word(words[2], 24),
        "selector": data[:10],
    }


def _failed_transaction_trace(rpc: runner.JsonRpc, tx_hash: str) -> dict[str, Any]:
    trace = rpc.request(
        "debug_traceTransaction",
        [
            tx_hash,
            {"disableMemory": True, "disableStack": True, "disableStorage": True},
        ],
    )
    if not isinstance(trace, dict) or trace.get("failed") is not True:
        raise RehearsalError("failed transaction trace is unavailable")
    value = trace.get("returnValue")
    if not isinstance(value, str):
        raise RehearsalError("failed transaction trace has no return value")
    value = value.lower()
    if not value.startswith("0x"):
        value = "0x" + value
    if not re.fullmatch(r"0x(?:[0-9a-f]{2})+", value):
        raise RehearsalError("failed transaction trace return value is malformed")
    return {"failed": True, "returnValue": value}


def _account_commitments(rpc: runner.JsonRpc, addresses: Sequence[str]) -> dict[str, Any]:
    commitments = {}
    for address in sorted(set(addresses)):
        proof = rpc.request("eth_getProof", [address, [], "latest"])
        if not isinstance(proof, dict):
            raise RehearsalError("eth_getProof is unavailable")
        commitments[address] = {
            key: str(proof[key]).lower()
            for key in ("balance", "codeHash", "nonce", "storageHash")
        }
    return commitments


class Session:
    def __init__(self, rpc: runner.JsonRpc) -> None:
        self.rpc = rpc
        self.clock = int(rpc.block("latest")["timestamp"], 16)
        self.transactions: list[dict[str, Any]] = []

    def mine_at(self, timestamp: int) -> None:
        if timestamp <= self.clock:
            raise RehearsalError("clock must move forward")
        self.rpc.request("evm_setNextBlockTimestamp", [timestamp])
        self.rpc.request("evm_mine", [])
        self.clock = timestamp

    def send(
        self,
        label: str,
        sender: str,
        target: str,
        data: str,
        *,
        value: int = 0,
        expected_status: int = 1,
    ) -> dict[str, Any]:
        transaction = {
            "from": sender,
            "to": target,
            "data": data,
            "value": hex(value),
            "gas": hex(55_000_000),
        }
        if expected_status == 1:
            self.rpc.call(transaction, "latest")
        self.rpc.request("evm_setNextBlockTimestamp", [self.clock + 1])
        tx_hash = self.rpc.request("eth_sendTransaction", [transaction])
        if not isinstance(tx_hash, str):
            raise RehearsalError("eth_sendTransaction returned no hash")
        receipt = drill._receipt(self.rpc, tx_hash)
        status = int(receipt["status"], 16)
        if status != expected_status:
            raise RehearsalError("%s status %d != %d" % (label, status, expected_status))
        block = self.rpc.block(int(receipt["blockNumber"], 16))
        landed = self.rpc.request("eth_getTransactionByHash", [tx_hash])
        if (
            not isinstance(landed, dict)
            or landed.get("input", "").lower() != data
            or landed.get("from", "").lower() != sender
            or landed.get("to", "").lower() != target
        ):
            raise RehearsalError("landed transaction identity drifted")
        self.clock = int(block["timestamp"], 16)
        record = {
            "blockHash": receipt["blockHash"].lower(),
            "blockNumber": int(receipt["blockNumber"], 16),
            "blockTimestamp": self.clock,
            "from": sender,
            "gasUsed": int(receipt["gasUsed"], 16),
            "hash": tx_hash.lower(),
            "inputKeccak256": documents.keccak256(bytes.fromhex(data[2:])),
            "label": label,
            "logCount": len(receipt["logs"]),
            "logsSha256": _log_digest(receipt["logs"]),
            "nonce": int(landed["nonce"], 16),
            "status": status,
            "to": target,
            "value": str(value),
        }
        self.transactions.append(record)
        return {"receipt": receipt, "record": record}


def _event(receipt: dict[str, Any], signature: str, address: str | None = None) -> dict[str, Any]:
    topic = documents.keccak256(signature.encode())
    matches = [
        log
        for log in receipt["logs"]
        if log.get("topics", [None])[0].lower() == topic
        and (address is None or log["address"].lower() == address)
    ]
    if len(matches) != 1:
        raise RehearsalError("expected one %s event, got %d" % (signature, len(matches)))
    return matches[0]


def _npm_position(rpc: runner.JsonRpc, token_id: int) -> dict[str, Any]:
    words = _words(_call(rpc, NPM, "positions(uint256)", token_id), 12)
    return {
        "fee": _uint_word(words[4]),
        "liquidity": _uint_word(words[7]),
        "owner": _address(rpc, NPM, "ownerOf(uint256)", token_id),
        "tickLower": _signed_word(words[5], 24),
        "tickUpper": _signed_word(words[6], 24),
        "token0": _address_word(words[2]),
        "token1": _address_word(words[3]),
        "tokenId": str(token_id),
        "tokensOwed0": _uint_word(words[10]),
        "tokensOwed1": _uint_word(words[11]),
    }


def _npm_liquidity_change(
    receipt: dict[str, Any], signature: str, token_id: int
) -> dict[str, int]:
    topic = documents.keccak256(signature.encode())
    matches = [
        log
        for log in receipt["logs"]
        if log["address"].lower() == NPM
        and log.get("topics", [None])[0].lower() == topic
        and len(log["topics"]) == 2
        and int(log["topics"][1], 16) == token_id
    ]
    if len(matches) != 1:
        raise RehearsalError("expected one NPM liquidity event for token %d" % token_id)
    words = _words(matches[0]["data"], 3)
    return {
        "amount0": _uint_word(words[1]),
        "amount1": _uint_word(words[2]),
        "liquidity": _uint_word(words[0]),
    }


def _npm_collect(
    receipt: dict[str, Any], token_id: int, recipient: str
) -> dict[str, int]:
    topic = documents.keccak256("Collect(uint256,address,uint256,uint256)".encode())
    matches = [
        log
        for log in receipt["logs"]
        if log["address"].lower() == NPM
        and log.get("topics", [None])[0].lower() == topic
        and len(log["topics"]) == 2
        and int(log["topics"][1], 16) == token_id
    ]
    if len(matches) != 1:
        raise RehearsalError("expected one NPM collect event for token %d" % token_id)
    words = _words(matches[0]["data"], 3)
    if _address_word(words[0]) != recipient:
        raise RehearsalError("NPM collect recipient drifted")
    return {"amount0": _uint_word(words[1]), "amount1": _uint_word(words[2])}


def _pair_amounts(
    token0: str, token1: str, amount0: int, amount1: int, labels: dict[str, str]
) -> dict[str, int]:
    by_token = {token0: amount0, token1: amount1}
    if set(by_token) != set(labels.values()):
        raise RehearsalError("NPM pair tokens drifted")
    return {label: by_token[token] for label, token in labels.items()}


def _usage_evidence(label: str, used: int, unused: int) -> dict[str, Any]:
    attributable = used + unused
    if attributable <= 0 or unused < 0 or unused * 10_000 > attributable * 50:
        raise RehearsalError("%s failed the 99.5%% asset-use bound" % label)
    return {
        "attributable": str(attributable),
        "minimumUseBps": 9_950,
        "unused": str(unused),
        "used": str(used),
        "usedBpsFloor": used * 10_000 // attributable,
    }


def _migration_event(
    receipt: dict[str, Any], manager: str, signature: str, proposal_id: int
) -> dict[str, int]:
    log = _event(receipt, signature, manager)
    if len(log["topics"]) != 2 or int(log["topics"][1], 16) != proposal_id:
        raise RehearsalError("manager migration event proposal identity drifted")
    words = _words(log["data"], 2)
    return {"first": _uint_word(words[0]), "second": _uint_word(words[1])}


def _approve(session: Session, actor: str, token: str, spender: str, amount: int, label: str) -> None:
    session.send(label, actor, token, _calldata("approve(address,uint256)", spender, amount))
    if _uint(session.rpc, token, "allowance(address,address)", actor, spender) != amount:
        raise RehearsalError("approval did not land")


def _deposit_weth(session: Session, actor: str, amount: int, label: str) -> None:
    before = _balance(session.rpc, WETH, actor)
    session.send(label, actor, WETH, _calldata("deposit()"), value=amount)
    if _balance(session.rpc, WETH, actor) - before != amount:
        raise RehearsalError("WETH deposit did not conserve")


def _collection_token_id(rpc: runner.JsonRpc, collateral: str, condition: str, index: int) -> int:
    collection = _bytes32(rpc, CTF, "getCollectionId(bytes32,bytes32,uint256)", ZERO32, condition, index)
    return _uint(rpc, CTF, "getPositionId(address,bytes32)", collateral, collection)


def _position_id(rpc: runner.JsonRpc, adapter: str, token_a: str, token_b: str) -> int:
    token0, token1 = sorted((token_a, token_b))
    return _uint(rpc, adapter, "getPositionTokenId(address,address)", token0, token1)


def _swap(
    session: Session,
    label: str,
    trader: str,
    token_in: str,
    token_out: str,
    amount_in: int,
    amount_out_minimum: int,
    price_limit: int,
) -> dict[str, int]:
    _approve(session, trader, token_in, SWAP_ROUTER, amount_in, label + ":approve")
    before_in = _balance(session.rpc, token_in, trader)
    before_out = _balance(session.rpc, token_out, trader)
    params = "(%s,%s,%d,%s,%d,%d,%d)" % (
        token_in,
        token_out,
        FEE,
        trader,
        amount_in,
        amount_out_minimum,
        price_limit,
    )
    sent = session.send(
        label,
        trader,
        SWAP_ROUTER,
        _calldata("exactInputSingle((address,address,uint24,address,uint256,uint256,uint160))", params),
    )
    spent = before_in - _balance(session.rpc, token_in, trader)
    received = _balance(session.rpc, token_out, trader) - before_out
    if spent <= 0 or spent > amount_in or received < amount_out_minimum:
        raise RehearsalError("bounded swap did not meet its limits")
    return {"amountInMaximum": amount_in, "amountInActual": spent, "amountOut": received, "gasUsed": sent["record"]["gasUsed"]}


def _stack(rpc: runner.JsonRpc, deployment_start: int, deployment_end: int) -> dict[str, Any]:
    topic = documents.keccak256("GenesisStaged(address,bytes32,bytes32,address)".encode())
    logs = rpc.request(
        "eth_getLogs",
        [{"fromBlock": hex(deployment_start), "toBlock": hex(deployment_end), "topics": [topic]}],
    )
    if not isinstance(logs, list) or len(logs) != 1:
        raise RehearsalError("deployment did not emit exactly one GenesisStaged")
    receipt = _receipt_address(logs[0])
    names = (
        "space",
        "arbitration",
        "vault",
        "companyToken",
        "proposalGateway",
        "evaluator",
        "orchestrator",
        "resolver",
        "futarchyFactory",
        "spotPool",
        "relay",
        "spotAdapter",
        "conditionalAdapter",
        "guard",
        "router",
        "manager",
    )
    addresses = {name: _address(rpc, receipt, name + "()") for name in names}
    if not _bool(rpc, receipt, "coreSealed()") or not _bool(rpc, receipt, "flmSealed()"):
        raise RehearsalError("receipt stages are not sealed")
    if _address(rpc, receipt, "weth()") != WETH or _address(rpc, receipt, "conditionalTokens()") != CTF:
        raise RehearsalError("receipt canonical dependency wiring drifted")
    addresses["receipt"] = receipt
    addresses["registrar"] = logs[0]["address"].lower()
    runtime_hashes = {
        name: _runtime_hash(rpc, address)
        for name, address in addresses.items()
        if name != "spotPool"
    }
    if rpc.request("eth_getCode", [addresses["spotPool"], "latest"]) != "0x":
        raise RehearsalError("predicted spot pool exists before vault finalization")
    return {
        "addresses": addresses,
        "runtimeHashes": runtime_hashes,
        "predictedUndeployed": {"spotPool": addresses["spotPool"]},
        "coreConfigHash": _bytes32(rpc, receipt, "CORE_CONFIG_HASH()"),
        "flmConfigHash": _bytes32(rpc, receipt, "FLM_CONFIG_HASH()"),
    }


def _scenario(rpc: runner.JsonRpc, deployment: list[dict[str, Any]], artifacts: dict[str, Any]) -> dict[str, Any]:
    session = Session(rpc)
    stack = _stack(rpc, FORK_BLOCK + 1, int(rpc.block("latest")["number"], 16))
    a = stack["addresses"]
    vault, manager, company = a["vault"], a["manager"], a["companyToken"]
    executor = _address(rpc, vault, "TREASURY_EXECUTOR()")

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
        actor = ACTORS[actor_name]
        before = _uint(rpc, vault, "reserveAt(uint256)", sold)
        after = _uint(rpc, vault, "reserveAt(uint256)", sold + amount)
        cost = after - before
        _deposit_weth(session, actor, cost, "sale:%d:wrap" % ordinal)
        _approve(session, actor, WETH, vault, cost, "sale:%d:approve" % ordinal)
        sent = session.send(
            "sale:%d:buy" % ordinal,
            actor,
            vault,
            _calldata("buy(uint256,uint256,uint256)", amount, cost, session.clock + 1_000),
        )
        event = _event(sent["receipt"], "Purchased(address,uint256,uint256)", vault)
        event_words = _words(event["data"], 2)
        if _uint_word(event_words[0]) != amount or _uint_word(event_words[1]) != cost:
            raise RehearsalError("purchase event disagrees with reserve path")
        buys.append({"actor": actor_name, "amount": str(amount), "cost": str(cost)})
        sold += amount

    raised = _uint(rpc, vault, "totalRaised()")
    if sold != 60 * WAD or _uint(rpc, vault, "totalSold()") != sold or raised != 24 * WAD // 10:
        raise RehearsalError("hero raise totals drifted")
    if sum(int(item["cost"]) for item in buys[:3]) != _uint(rpc, vault, "reserveAt(uint256)", 24 * WAD):
        raise RehearsalError("split first purchase is not path independent")

    sale_end = _uint(rpc, vault, "SALE_END()")
    session.mine_at(sale_end)
    session.send("sale:seal", ACTORS["keeper"], vault, _calldata("seal()"))
    finalized = session.send("sale:finalize", ACTORS["keeper"], vault, _calldata("finalize()"))
    final_event = _event(finalized["receipt"], "Finalized(uint256,uint256,uint256,uint256,uint256)", vault)
    final_words = [_uint_word(word) for word in _words(final_event["data"], 5)]
    bootstrap_company, bootstrap_collateral, shares = final_words[2:]
    terminal_price = _uint(rpc, vault, "terminalPrice()")
    expected_company = (bootstrap_collateral * WAD + terminal_price - 1) // terminal_price
    if (
        final_words[:2] != [sold, raised]
        or bootstrap_collateral != raised // 2
        or bootstrap_company != expected_company
        or _uint(rpc, vault, "phase()") != 2
        or _balance(rpc, WETH, executor) != raised - bootstrap_collateral
        or _balance(rpc, manager, executor) != shares
        or _balance(rpc, WETH, vault) != 0
        or _balance(rpc, manager, vault) != 0
    ):
        raise RehearsalError("atomic bootstrap reconciliation failed")
    spot_before_history = _uint(rpc, manager, "spotLiquidity()")
    if spot_before_history == 0 or _uint(rpc, manager, "totalSupply()") != shares:
        raise RehearsalError("bootstrap did not create manager liquidity")
    stack["runtimeHashes"]["spotPool"] = _runtime_hash(rpc, a["spotPool"])
    bootstrap_executor_weth = _balance(rpc, WETH, executor)
    bootstrap_executor_shares = _balance(rpc, manager, executor)
    initial_share_supply = _uint(rpc, manager, "totalSupply()")
    spot_nft = _position_id(rpc, a["spotAdapter"], company, WETH)
    spot_position_bootstrap = _npm_position(rpc, spot_nft)
    if (
        spot_nft == 0
        or spot_position_bootstrap["owner"] != a["spotAdapter"]
        or spot_position_bootstrap["liquidity"] != spot_before_history
        or initial_share_supply != shares
    ):
        raise RehearsalError("bootstrap spot NPM/share custody drifted")

    session.mine_at(session.clock + 30 * 60)
    _call(rpc, a["guard"], "assertStablePair(address,address)", company, WETH)

    transfer_salt = documents.keccak256(b"FAO_REHEARSAL_R0_S1_TRANSFER")
    amount = 1
    payload = b"".join(
        (
            bytes.fromhex(documents.keccak256(b"FAO_ECON_TREASURY_TRANSFER_V1")[2:]),
            CHAIN_ID.to_bytes(32, "big"),
            bytes(12) + bytes.fromhex(vault[2:]),
            bytes(12) + bytes.fromhex(WETH[2:]),
            bytes(12) + bytes.fromhex(ACTORS["recipient"][2:]),
            amount.to_bytes(32, "big"),
            bytes.fromhex(transfer_salt[2:]),
        )
    )
    proposal_id = int(documents.keccak256(payload), 16)
    action = "(%s,%s,%d,%s)" % (WETH, ACTORS["recipient"], amount, transfer_salt)
    reported_payload = _dynamic_bytes(_call(rpc, a["proposalGateway"], "transferEvaluationPayload((address,address,uint256,bytes32))", action))
    if reported_payload != payload or _uint(rpc, a["proposalGateway"], "transferProposalId((address,address,uint256,bytes32))", action) != proposal_id:
        raise RehearsalError("typed transfer payload binding drifted")
    session.send("proposal:publish", ACTORS["proposer"], a["proposalGateway"], _calldata("proposeTransfer((address,address,uint256,bytes32))", action))

    _deposit_weth(session, ACTORS["yesBidder"], 102 * WAD, "bond:yes:wrap")
    _deposit_weth(session, ACTORS["noBidder"], 2 * WAD, "bond:no:wrap")
    _approve(session, ACTORS["yesBidder"], WETH, a["arbitration"], 102 * WAD, "bond:yes:approve")
    _approve(session, ACTORS["noBidder"], WETH, a["arbitration"], 2 * WAD, "bond:no:approve")
    session.send("bond:yes:2", ACTORS["yesBidder"], a["arbitration"], _calldata("placeYesBond(uint256,uint256)", proposal_id, 2 * WAD))
    session.send("bond:no:2", ACTORS["noBidder"], a["arbitration"], _calldata("placeNoBond(uint256)", proposal_id))
    session.send("bond:yes:100", ACTORS["yesBidder"], a["arbitration"], _calldata("placeYesBond(uint256,uint256)", proposal_id, 100 * WAD))
    session.send("evaluation:queue-head", ACTORS["keeper"], a["arbitration"], _calldata("startNextEvaluation()"))
    spot_anchor = _pool_evidence(rpc, a["spotPool"])
    started = session.send("evaluation:start-market", ACTORS["keeper"], a["evaluator"], _calldata("startEvaluation(uint256,bytes)", proposal_id, "0x" + payload.hex()))
    proposal = _address(rpc, a["evaluator"], "futarchyProposalOf(uint256)", proposal_id)
    binding = _binding(rpc, a["resolver"], proposal)
    condition = _bytes32(rpc, proposal, "conditionId()")
    question = _bytes32(rpc, proposal, "questionId()")
    wrappers = [_wrapped_outcome(rpc, proposal, index) for index in range(4)]
    yes_company, no_company, yes_currency, no_currency = [item[0] for item in wrappers]
    creation_block = rpc.block(started["record"]["blockNumber"])
    prevrandao = str(creation_block.get("mixHash", "")).lower()
    if not re.fullmatch(r"0x[0-9a-f]{64}", prevrandao):
        raise RehearsalError("creation block prevrandao is unavailable")
    promoted_event = _event(
        started["receipt"],
        "OfficialProposalPromotedAndMigrated(uint256,address,address,bytes32,uint256)",
        a["orchestrator"],
    )
    new_proposal_event = _event(
        started["receipt"],
        "NewProposal(uint256,address,bytes32,bytes32,bytes32)",
        a["futarchyFactory"],
    )
    if len(promoted_event["topics"]) != 4 or len(new_proposal_event["topics"]) != 3:
        raise RehearsalError("official proposal event indexing drifted")
    futarchy_proposal_id = int(promoted_event["topics"][1], 16)
    promoted_words = _words(promoted_event["data"], 2)
    new_words = _words(new_proposal_event["data"], 3)
    market_name = _dynamic_bytes(_call(rpc, proposal, "marketName()")).decode()
    description = _dynamic_bytes(_call(rpc, proposal, "description()")).decode()
    content_hash = documents.keccak256(market_name.encode() + description.encode())
    recomputed_question = documents.keccak256(
        bytes.fromhex(content_hash[2:])
        + bytes.fromhex(a["futarchyFactory"][2:])
        + futarchy_proposal_id.to_bytes(32, "big")
        + bytes.fromhex(prevrandao[2:])
    )
    if (
        int(new_proposal_event["topics"][1], 16) != futarchy_proposal_id
        or _address_word(bytes.fromhex(promoted_event["topics"][2][2:])) != proposal
        or _address_word(bytes.fromhex(new_proposal_event["topics"][2][2:])) != proposal
        or _address_word(bytes.fromhex(promoted_event["topics"][3][2:])) != a["evaluator"]
        or "0x" + promoted_words[0].hex() != prevrandao
        or _uint_word(promoted_words[1]) != 0
        or "0x" + new_words[0].hex() != condition
        or "0x" + new_words[1].hex() != question
        or "0x" + new_words[2].hex() != prevrandao
        or recomputed_question != question
    ):
        raise RehearsalError("proposal question/prevrandao binding drifted")

    observation_cardinality = _uint(rpc, a["orchestrator"], "OBSERVATION_CARDINALITY()")
    if (
        observation_cardinality < 120
        or _address(rpc, a["orchestrator"], "adapter()") != "0x" + "00" * 20
    ):
        raise RehearsalError("orchestrator must create empty official pools without an adapter")
    spot_currency_sqrt = (
        spot_anchor["slot0"]["sqrtPriceX96"]
        if spot_anchor["token0"] == company
        else _invert_sqrt_price(spot_anchor["slot0"]["sqrtPriceX96"])
    )
    official_pools = {}
    for label, company_wrapper, currency_wrapper, pool in (
        ("yes", yes_company, yes_currency, binding["yesPool"]),
        ("no", no_company, no_currency, binding["noPool"]),
    ):
        evidence = _pool_evidence(rpc, pool)
        expected_tokens = sorted((company_wrapper, currency_wrapper))
        expected_sqrt = (
            spot_currency_sqrt
            if company_wrapper < currency_wrapper
            else _invert_sqrt_price(spot_currency_sqrt)
        )
        if (
            [evidence["token0"], evidence["token1"]] != expected_tokens
            or evidence["fee"] != FEE
            or evidence["slot0"]["sqrtPriceX96"] != expected_sqrt
            or evidence["slot0"]["observationCardinalityNext"] != observation_cardinality
            or evidence["liquidity"] != 0
            or _balance(rpc, company_wrapper, pool) != 0
            or _balance(rpc, currency_wrapper, pool) != 0
            or _uint(rpc, company_wrapper, "totalSupply()") != 0
            or _uint(rpc, currency_wrapper, "totalSupply()") != 0
            or _position_id(rpc, a["conditionalAdapter"], company_wrapper, currency_wrapper) != 0
            or _address(
                rpc,
                UNIV3_FACTORY,
                "getPool(address,address,uint24)",
                company_wrapper,
                currency_wrapper,
                FEE,
            )
            != pool
        ):
            raise RehearsalError("official %s pool was not exact and empty before sync" % label)
        official_pools[label] = {
            **evidence,
            "companyWrapper": company_wrapper,
            "currencyWrapper": currency_wrapper,
            "expectedInitialSqrtPriceX96": str(expected_sqrt),
        }
    if (
        binding["questionId"] != question
        or binding["companyToken"] != company
        or binding["currencyToken"] != WETH
        or binding["anchorTimestamp"] != started["record"]["blockTimestamp"]
    ):
        raise RehearsalError("orchestrator-created conditional market wiring failed")

    wrapper_by_label = {
        "noCompany": no_company,
        "noCurrency": no_currency,
        "yesCompany": yes_company,
        "yesCurrency": yes_currency,
    }
    entry_balances_before = {
        label: _balance(rpc, wrapper, manager) for label, wrapper in wrapper_by_label.items()
    }
    if any(entry_balances_before.values()):
        raise RehearsalError("manager had outcome inventory before first migration")
    spot_before = _uint(rpc, manager, "spotLiquidity()")
    spot_position_before_sync = _npm_position(rpc, spot_nft)
    preview = _uint(rpc, manager, "previewLiquidityMigration()")
    migrated = session.send("flm:sync-to-conditional", ACTORS["keeper"], manager, _calldata("sync()"))
    spot_after = _uint(rpc, manager, "spotLiquidity()")
    yes_nft = _position_id(rpc, a["conditionalAdapter"], yes_company, yes_currency)
    no_nft = _position_id(rpc, a["conditionalAdapter"], no_company, no_currency)
    conditional_yes_liquidity = _uint(rpc, manager, "conditionalYesLiquidity()")
    conditional_no_liquidity = _uint(rpc, manager, "conditionalNoLiquidity()")
    migration_event = _migration_event(
        migrated["receipt"],
        manager,
        "LiquidityMigratedToConditional(uint256,uint128,uint256)",
        proposal_id,
    )
    spot_decrease = _npm_liquidity_change(
        migrated["receipt"],
        "DecreaseLiquidity(uint256,uint128,uint256,uint256)",
        spot_nft,
    )
    spot_position_after_sync = _npm_position(rpc, spot_nft)
    conditional_positions = {
        "no": _npm_position(rpc, no_nft),
        "yes": _npm_position(rpc, yes_nft),
    }
    conditional_increases = {
        "no": _npm_liquidity_change(
            migrated["receipt"],
            "IncreaseLiquidity(uint256,uint128,uint256,uint256)",
            no_nft,
        ),
        "yes": _npm_liquidity_change(
            migrated["receipt"],
            "IncreaseLiquidity(uint256,uint128,uint256,uint256)",
            yes_nft,
        ),
    }
    if (
        preview != spot_before * 8_000 // 10_000
        or spot_after != spot_before - preview
        or spot_position_before_sync["owner"] != a["spotAdapter"]
        or spot_position_before_sync["liquidity"] != spot_before
        or spot_position_after_sync["owner"] != a["spotAdapter"]
        or spot_position_after_sync["liquidity"] != spot_after
        or spot_decrease["liquidity"] != preview
        or migration_event != {
            "first": preview,
            "second": conditional_yes_liquidity + conditional_no_liquidity,
        }
        or not _bool(rpc, manager, "inConditionalMode()")
        or _uint(rpc, manager, "activeProposalId()") != proposal_id
        or _address(rpc, manager, "activeProposal()") != proposal
        or _address(rpc, manager, "activeYesCompanyToken()") != yes_company
        or _address(rpc, manager, "activeNoCompanyToken()") != no_company
        or _address(rpc, manager, "activeYesCurrencyToken()") != yes_currency
        or _address(rpc, manager, "activeNoCurrencyToken()") != no_currency
        or conditional_yes_liquidity == 0
        or conditional_no_liquidity == 0
        or yes_nft == 0
        or no_nft == 0
        or no_nft == yes_nft
        or _uint(rpc, manager, "totalSupply()") != initial_share_supply
        or _balance(rpc, manager, executor) != bootstrap_executor_shares
    ):
        raise RehearsalError("permissionless 80% FLM migration failed")

    entry_usage = {}
    for label, pool, company_wrapper, currency_wrapper, liquidity in (
        ("yes", binding["yesPool"], yes_company, yes_currency, conditional_yes_liquidity),
        ("no", binding["noPool"], no_company, no_currency, conditional_no_liquidity),
    ):
        position = conditional_positions[label]
        increase = conditional_increases[label]
        token_labels = {
            label + "Company": company_wrapper,
            label + "Currency": currency_wrapper,
        }
        used = _pair_amounts(
            position["token0"],
            position["token1"],
            increase["amount0"],
            increase["amount1"],
            token_labels,
        )
        if (
            position["owner"] != a["conditionalAdapter"]
            or position["fee"] != FEE
            or position["tickLower"] != -887_270
            or position["tickUpper"] != 887_270
            or position["liquidity"] != liquidity
            or increase["liquidity"] != liquidity
        ):
            raise RehearsalError("conditional NPM position custody/liquidity drifted")
        for suffix, wrapper in (("Company", company_wrapper), ("Currency", currency_wrapper)):
            asset_label = label + suffix
            leftover = _balance(rpc, wrapper, manager)
            if (
                _balance(rpc, wrapper, pool) != used[asset_label]
                or _uint(rpc, wrapper, "totalSupply()") != used[asset_label] + leftover
            ):
                raise RehearsalError("conditional entry asset attribution drifted")
            entry_usage[asset_label] = _usage_evidence(
                "conditional entry " + asset_label, used[asset_label], leftover
            )

    trade_amount = 24 * WAD // 10_000
    _deposit_weth(session, ACTORS["trader"], trade_amount, "trade:wrap")
    _approve(session, ACTORS["trader"], WETH, CTF, trade_amount, "trade:ctf-approve")
    session.send(
        "trade:split-currency",
        ACTORS["trader"],
        CTF,
        _calldata("splitPosition(address,bytes32,bytes32,uint256[],uint256)", WETH, ZERO32, condition, "[1,2]", trade_amount),
    )
    currency_ids = {
        "yes": _collection_token_id(rpc, WETH, condition, 1),
        "no": _collection_token_id(rpc, WETH, condition, 2),
    }
    for label, index, wrapper in (("yes", 0, yes_currency), ("no", 1, no_currency)):
        session.send(
            "trade:wrap-" + label,
            ACTORS["trader"],
            CTF,
            _calldata(
                "safeTransferFrom(address,address,uint256,uint256,bytes)",
                ACTORS["trader"],
                W1155,
                currency_ids[label],
                trade_amount,
                "0x" + wrappers[index + 2][1].hex(),
            ),
        )
        if _balance(rpc, wrapper, ACTORS["trader"]) != trade_amount:
            raise RehearsalError("conditional currency wrapper mint drifted")

    yes_before = _economic_tick(rpc, binding["yesPool"], yes_company)
    no_tick = _economic_tick(rpc, binding["noPool"], no_company)
    trade = _swap(
        session,
        "trade:bounded-yes",
        ACTORS["trader"],
        yes_currency,
        yes_company,
        trade_amount,
        trade_amount * WAD * 95 // terminal_price // 100,
        _price_limit(rpc, binding["yesPool"], yes_company, 50),
    )
    yes_after = _economic_tick(rpc, binding["yesPool"], yes_company)
    if not 25 <= yes_after - yes_before <= 50 or yes_after <= no_tick:
        raise RehearsalError("YES trade did not produce the bounded ~40-tick move")

    timeout = _uint(rpc, a["resolver"], "TIMEOUT()")
    twap_window = _uint(rpc, a["resolver"], "TWAP_WINDOW()")
    if timeout != 7 * 24 * 60 * 60 or twap_window != 24 * 60 * 60:
        raise RehearsalError("resolver timeout/window drifted")
    session.mine_at(binding["anchorTimestamp"] + 6 * 24 * 60 * 60)
    six_day_timestamp = session.clock
    if _bool(rpc, a["resolver"], "isReadyToResolve(address)", proposal):
        raise RehearsalError("resolver became ready before its one-day TWAP window")
    window_end = binding["anchorTimestamp"] + timeout
    session.mine_at(window_end)
    if not _bool(rpc, a["resolver"], "isReadyToResolve(address)", proposal):
        raise RehearsalError("resolver was not ready at the exact window end")
    resolved = session.send("evaluation:resolve", ACTORS["keeper"], a["evaluator"], _calldata("resolve(uint256)", proposal_id))
    end_ago = resolved["record"]["blockTimestamp"] - window_end
    start_ago = end_ago + twap_window
    yes_average = _mean_tick(
        rpc, binding["yesPool"], yes_company, start_ago, end_ago, twap_window
    )
    no_average = _mean_tick(
        rpc, binding["noPool"], no_company, start_ago, end_ago, twap_window
    )
    resolver_event = _event(
        resolved["receipt"],
        "ProposalResolved(address,bool,int24,int24,bytes32)",
        a["resolver"],
    )
    if (
        len(resolver_event["topics"]) != 2
        or _address_word(bytes.fromhex(resolver_event["topics"][1][2:])) != proposal
    ):
        raise RehearsalError("resolver event proposal binding drifted")
    resolver_words = _words(resolver_event["data"], 4)
    event_yes_average = _signed_word(resolver_words[1], 24)
    event_no_average = _signed_word(resolver_words[2], 24)
    resolved_binding = _binding(rpc, a["resolver"], proposal)
    arbitration_words = _words(
        _call(rpc, a["arbitration"], "getProposal(uint256)", proposal_id), 11
    )
    if (
        _uint(rpc, CTF, "payoutDenominator(bytes32)", condition) != 1
        or _uint(rpc, CTF, "payoutNumerators(bytes32,uint256)", condition, 0) != 1
        or _uint(rpc, CTF, "payoutNumerators(bytes32,uint256)", condition, 1) != 0
        or not _bool(rpc, a["arbitration"], "isAccepted(uint256)", proposal_id)
        or not _bool(rpc, a["arbitration"], "isSettled(uint256)", proposal_id)
        or _uint(rpc, a["arbitration"], "activeEvaluationProposalId()") != 0
        or _uint_word(arbitration_words[5]) != 5
        or _uint_word(arbitration_words[7]) != 1
        or _uint_word(arbitration_words[8]) != 1
        or not resolved_binding["resolved"]
        or not resolved_binding["accepted"]
        or _uint_word(resolver_words[0]) != 1
        or event_yes_average != yes_average
        or event_no_average != no_average
        or yes_average <= no_average
        or "0x" + resolver_words[3].hex() != question
    ):
        raise RehearsalError("7-day TWAP did not settle YES")

    shock_funding = WAD // 10
    _deposit_weth(session, ACTORS["trader"], shock_funding, "restore-guard:wrap")
    spot_tick_before = _economic_tick(rpc, a["spotPool"], company)
    shock = _swap(
        session,
        "restore-guard:spot-shock",
        ACTORS["trader"],
        WETH,
        company,
        shock_funding,
        1,
        _price_limit(rpc, a["spotPool"], company, 80),
    )
    spot_tick_after = _economic_tick(rpc, a["spotPool"], company)
    if not 75 <= spot_tick_after - spot_tick_before <= 80:
        raise RehearsalError("spot shock did not reach approximately +80 ticks")

    company_ids = {
        "yes": _collection_token_id(rpc, company, condition, 1),
        "no": _collection_token_id(rpc, company, condition, 2),
    }
    protocol_addresses = [
        *a.values(),
        executor,
        WETH,
        CTF,
        W1155,
        UNIV3_FACTORY,
        NPM,
        SWAP_ROUTER,
        yes_company,
        no_company,
        yes_currency,
        no_currency,
        proposal,
        binding["yesPool"],
        binding["noPool"],
    ]
    before_failed = _account_commitments(rpc, protocol_addresses)
    failed = session.send(
        "restore-guard:expected-revert",
        ACTORS["keeper"],
        manager,
        _calldata("sync()"),
        expected_status=0,
    )
    failed_trace = _failed_transaction_trace(rpc, failed["record"]["hash"])
    unstable = _decode_unstable(failed_trace["returnValue"])
    after_failed = _account_commitments(rpc, protocol_addresses)
    if (
        unstable["pool"] != a["spotPool"]
        or abs(unstable["currentTick"] - unstable["meanTick"]) <= 50
        or failed["receipt"]["logs"]
        or before_failed != after_failed
    ):
        raise RehearsalError("UnstablePool failure was not exact and atomic")

    base_before_restore = {
        "company": _balance(rpc, company, manager),
        "currency": _balance(rpc, WETH, manager),
    }
    shares_before_restore = {
        "executor": _balance(rpc, manager, executor),
        "totalSupply": _uint(rpc, manager, "totalSupply()"),
    }
    session.mine_at(session.clock + 30 * 60)
    restored = session.send("flm:sync-back-to-spot", ACTORS["keeper"], manager, _calldata("sync()"))
    restored_spot_liquidity = _uint(rpc, manager, "spotLiquidity()")
    restored_spot_position = _npm_position(rpc, spot_nft)
    spot_increase = _npm_liquidity_change(
        restored["receipt"],
        "IncreaseLiquidity(uint256,uint128,uint256,uint256)",
        spot_nft,
    )
    return_event = _migration_event(
        restored["receipt"],
        manager,
        "LiquidityMigratedBackToSpot(uint256,uint256,uint128)",
        proposal_id,
    )
    conditional_decreases = {
        "no": _npm_liquidity_change(
            restored["receipt"],
            "DecreaseLiquidity(uint256,uint128,uint256,uint256)",
            no_nft,
        ),
        "yes": _npm_liquidity_change(
            restored["receipt"],
            "DecreaseLiquidity(uint256,uint128,uint256,uint256)",
            yes_nft,
        ),
    }
    conditional_collects = {
        "no": _npm_collect(restored["receipt"], no_nft, manager),
        "yes": _npm_collect(restored["receipt"], yes_nft, manager),
    }
    base_after_restore = {
        "company": _balance(rpc, company, manager),
        "currency": _balance(rpc, WETH, manager),
    }
    return_used = _pair_amounts(
        restored_spot_position["token0"],
        restored_spot_position["token1"],
        spot_increase["amount0"],
        spot_increase["amount1"],
        {"company": company, "currency": WETH},
    )
    winning_recovered = _pair_amounts(
        conditional_positions["yes"]["token0"],
        conditional_positions["yes"]["token1"],
        conditional_collects["yes"]["amount0"],
        conditional_collects["yes"]["amount1"],
        {"company": yes_company, "currency": yes_currency},
    )
    idle_recovery = {
        "company": int(entry_usage["yesCompany"]["unused"]),
        "currency": int(entry_usage["yesCurrency"]["unused"]),
    }
    return_usage = {
        label: _usage_evidence(
            "spot return " + label,
            return_used[label],
            winning_recovered[label] - return_used[label],
        )
        for label in ("company", "currency")
    }
    manager_base_delta = {
        label: base_after_restore[label] - base_before_restore[label]
        for label in ("company", "currency")
    }
    if (
        _bool(rpc, manager, "inConditionalMode()")
        or _uint(rpc, manager, "activeProposalId()") != 0
        or _address(rpc, manager, "activeProposal()") != "0x" + "00" * 20
        or _position_id(rpc, a["conditionalAdapter"], yes_company, yes_currency) != 0
        or _position_id(rpc, a["conditionalAdapter"], no_company, no_currency) != 0
        or _uint(rpc, binding["yesPool"], "liquidity()") != 0
        or _uint(rpc, binding["noPool"], "liquidity()") != 0
        or restored_spot_liquidity == 0
        or _position_id(rpc, a["spotAdapter"], company, WETH) != spot_nft
        or restored_spot_position["owner"] != a["spotAdapter"]
        or restored_spot_position["liquidity"] != restored_spot_liquidity
        or restored_spot_position["fee"] != FEE
        or restored_spot_position["tickLower"] != -887_270
        or restored_spot_position["tickUpper"] != 887_270
        or restored_spot_liquidity != spot_after + spot_increase["liquidity"]
        or return_event != {
            "first": conditional_yes_liquidity + conditional_no_liquidity,
            "second": spot_increase["liquidity"],
        }
        or conditional_decreases["yes"]["liquidity"] != conditional_yes_liquidity
        or conditional_decreases["no"]["liquidity"] != conditional_no_liquidity
        or any(
            manager_base_delta[label]
            != int(return_usage[label]["unused"]) + idle_recovery[label]
            for label in ("company", "currency")
        )
        or _uint(rpc, manager, "totalSupply()") != shares_before_restore["totalSupply"]
        or _balance(rpc, manager, executor) != shares_before_restore["executor"]
        or shares_before_restore
        != {"executor": bootstrap_executor_shares, "totalSupply": initial_share_supply}
    ):
        raise RehearsalError("settled liquidity did not restore to spot")

    burned_positions = {
        "no": _burned_npm_position(rpc, no_nft),
        "yes": _burned_npm_position(rpc, yes_nft),
    }

    residue_accounts = (a["router"], a["conditionalAdapter"])
    wrapper_residue = {
        label: {account: str(_balance(rpc, wrapper, account)) for account in residue_accounts}
        for label, wrapper in {
            "noCompany": no_company,
            "noCurrency": no_currency,
            "yesCompany": yes_company,
            "yesCurrency": yes_currency,
        }.items()
    }
    underlying_residue = {
        account: {
            str(token_id): str(_uint(rpc, CTF, "balanceOf(address,uint256)", account, token_id))
            for token_id in (*company_ids.values(), *currency_ids.values())
        }
        for account in residue_accounts
    }
    base_residue = {
        account: {token: str(_balance(rpc, token, account)) for token in (company, WETH)}
        for account in residue_accounts
    }
    if (
        any(int(value) for balances in wrapper_residue.values() for value in balances.values())
        or any(
            int(value)
            for balances in underlying_residue.values()
            for value in balances.values()
        )
        or any(int(value) for balances in base_residue.values() for value in balances.values())
    ):
        raise RehearsalError(
            "wrapper/router residue remained after restoration: "
            + json.dumps(
                {
                    "base": base_residue,
                    "underlying": underlying_residue,
                    "wrappers": wrapper_residue,
                },
                sort_keys=True,
                separators=(",", ":"),
            )
        )
    manager_outcomes = {
        "noCompany": str(_balance(rpc, no_company, manager)),
        "noCurrency": str(_balance(rpc, no_currency, manager)),
        "yesCompany": str(_balance(rpc, yes_company, manager)),
        "yesCurrency": str(_balance(rpc, yes_currency, manager)),
    }
    expected_losing_residue = trade["amountOut"]
    if (
        int(manager_outcomes["noCompany"]) != expected_losing_residue
        or any(int(manager_outcomes[label]) for label in ("noCurrency", "yesCompany", "yesCurrency"))
    ):
        raise RehearsalError(
            "manager outcome inventory is not the conserved losing NO-company residue: "
            + json.dumps(manager_outcomes, sort_keys=True, separators=(",", ":"))
        )
    trader_outcomes = {
        label: str(_balance(rpc, wrapper, ACTORS["trader"]))
        for label, wrapper in wrapper_by_label.items()
    }
    trader_underlying = {
        str(token_id): str(
            _uint(rpc, CTF, "balanceOf(address,uint256)", ACTORS["trader"], token_id)
        )
        for token_id in (*company_ids.values(), *currency_ids.values())
    }
    if (
        int(trader_outcomes["yesCompany"]) != trade["amountOut"]
        or int(trader_outcomes["yesCurrency"])
        != trade["amountInMaximum"] - trade["amountInActual"]
        or int(trader_outcomes["noCurrency"]) != trade_amount
        or int(trader_outcomes["noCompany"]) != 0
        or any(int(value) for value in trader_underlying.values())
    ):
        raise RehearsalError("trader conditional inventory was not exactly attributable")

    all_transactions = deployment + session.transactions
    return {
        "actorPreconditions": {
            name: {"address": address, "code": "0x", "nonce": "0", "provenance": "house-wallet"}
            for name, address in ACTORS.items()
        },
        "artifacts": artifacts,
        "bootstrap": {
            "bootstrapCollateral": str(bootstrap_collateral),
            "bootstrapCompany": str(bootstrap_company),
            "executorFlmShares": str(bootstrap_executor_shares),
            "executorWeth": str(bootstrap_executor_weth),
            "flmShares": str(shares),
            "spotLiquidity": str(spot_before_history),
            "spotNpmPosition": spot_position_bootstrap,
            "terminalPrice": str(terminal_price),
        },
        "chainId": CHAIN_ID,
        "dependencies": DEPENDENCIES,
        "fork": {
            "blockHash": FORK_BLOCK_HASH,
            "blockNumber": FORK_BLOCK,
            "selectedFromHead": FORK_SELECTED_FROM_HEAD,
            "selectionRule": "finalized-head-minus-64-rounded-down-1000",
            "timestamp": FORK_TIMESTAMP,
        },
        "inputs": {
            "driverSha256": "0x" + hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "scriptSha256": "0x" + hashlib.sha256(SCRIPT.read_bytes()).hexdigest(),
        },
        "migration": {
            "conditionalNoLiquidity": str(conditional_no_liquidity),
            "conditionalPositionNftsBeforeRestore": {"no": str(no_nft), "yes": str(yes_nft)},
            "conditionalPositionsBeforeRestore": conditional_positions,
            "conditionalYesLiquidity": str(conditional_yes_liquidity),
            "entryAssetUse": entry_usage,
            "managerEvent": migration_event,
            "preview80Percent": str(preview),
            "spotLiquidityAfterMigration": str(spot_after),
            "spotLiquidityBeforeMigration": str(spot_before),
            "spotPositionAfterMigration": spot_position_after_sync,
            "spotPositionBeforeMigration": spot_position_before_sync,
        },
        "proposal": {
            "anchorTimestamp": binding["anchorTimestamp"],
            "conditionId": condition,
            "contentHash": content_hash,
            "creationBlockPrevrandao": prevrandao,
            "description": description,
            "futarchyProposalId": str(futarchy_proposal_id),
            "id": str(proposal_id),
            "marketName": market_name,
            "noPool": binding["noPool"],
            "officialPoolsBeforeSync": official_pools,
            "orchestratorAdapter": "0x" + "00" * 20,
            "payloadKeccak256": documents.keccak256(payload),
            "proposal": proposal,
            "questionId": question,
            "questionIdRecomputed": recomputed_question,
            "yesPool": binding["yesPool"],
        },
        "publicBroadcasts": 0,
        "raise": {
            "buys": buys,
            "funder1SplitCost": str(sum(int(item["cost"]) for item in buys[:3])),
            "raised": str(raised),
            "sold": str(sold),
        },
        "resolution": {
            "accepted": True,
            "arbitration": {
                "activeEvaluationProposalId": "0",
                "proposalState": "SETTLED",
            },
            "noPayout": "0",
            "resolverBindingAfter": resolved_binding,
            "resolverEventTicks": {"no": event_no_average, "yes": event_yes_average},
            "resolveGas": resolved["record"]["gasUsed"],
            "resolvedAt": resolved["record"]["blockTimestamp"],
            "sixDayTimestamp": six_day_timestamp,
            "twap": {
                "endAgo": end_ago,
                "noMeanTick": no_average,
                "startAgo": start_ago,
                "timeout": timeout,
                "window": twap_window,
                "windowEnd": window_end,
                "yesMeanTick": yes_average,
            },
            "yesPayout": "1",
        },
        "resources": {
            "blocks": all_transactions[-1]["blockNumber"] - all_transactions[0]["blockNumber"] + 1,
            "gasUsed": sum(item["gasUsed"] for item in all_transactions),
            "transactions": len(all_transactions),
        },
        "restore": {
            "ctfInventoryBoundary": {
                "closureClaimed": False,
                "deferredWholeConditionLedgerStage": "S6",
                "payout": {"denominator": "1", "no": "0", "yes": "1"},
                "traderUnderlying": trader_underlying,
                "traderWrappersOutstanding": trader_outcomes,
            },
            "failedGas": failed["record"]["gasUsed"],
            "failedProtocolStateCommitmentsBefore": before_failed,
            "failedProtocolStateCommitmentsAfter": after_failed,
            "failedTransactionTrace": failed_trace,
            "managerOutcomeInventory": manager_outcomes,
            "managerOutcomeInventoryAttribution": {
                "amount": str(expected_losing_residue),
                "conservedFrom": "trade.amountOut",
                "outcome": "NO",
                "token": no_company,
                "worthAfterPayout": "0",
            },
            "conditionalNpmCollects": conditional_collects,
            "conditionalPoolLiquidityAfter": {"no": "0", "yes": "0"},
            "managerBaseDelta": {
                label: str(amount) for label, amount in manager_base_delta.items()
            },
            "npmPositionsBurned": burned_positions,
            "postAddIdleRecovery": {
                label: str(amount) for label, amount in idle_recovery.items()
            },
            "returnAssetUse": return_usage,
            "returnManagerEvent": return_event,
            "returnWinningRecovered": {
                label: str(amount) for label, amount in winning_recovered.items()
            },
            "restoredAt": restored["record"]["blockTimestamp"],
            "restoredGas": restored["record"]["gasUsed"],
            "restoredSpotPosition": restored_spot_position,
            "residueBase": base_residue,
            "residueUnderlying": underlying_residue,
            "spotShock": {**shock, "tickAfter": spot_tick_after, "tickBefore": spot_tick_before},
            "unstablePool": unstable,
            "wrapperResidue": wrapper_residue,
        },
        "stack": {**stack, "executor": executor},
        "trade": {**trade, "noTick": no_tick, "yesTickAfter": yes_after, "yesTickBefore": yes_before},
        "transactions": all_transactions,
    }


def _run_once(port: int, fork_url: str, artifacts: dict[str, Any]) -> tuple[dict[str, Any], dict[str, Any]]:
    rpc_url = _loopback("http://127.0.0.1:%d" % port)
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
            str(FORK_BLOCK),
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
        rpc = runner.JsonRpc(rpc_url)
        for _ in range(200):
            if process.poll() is not None:
                raise RehearsalError("fresh Anvil fork exited before accepting RPC")
            try:
                if rpc.chain_id() == CHAIN_ID:
                    break
            except runner.RunnerError:
                time.sleep(0.05)
        else:
            raise RehearsalError("fresh Anvil fork did not start")
        pin = rpc.block(FORK_BLOCK)
        if int(rpc.block("latest")["number"], 16) != FORK_BLOCK or pin["hash"].lower() != FORK_BLOCK_HASH:
            raise RehearsalError("Anvil fork is not at the exact pin")
        preconditions = {}
        for name, actor in ACTORS.items():
            nonce = int(rpc.request("eth_getTransactionCount", [actor, "latest"]), 16)
            code = rpc.request("eth_getCode", [actor, "latest"])
            if nonce != 0 or code != "0x":
                raise RehearsalError("fixed actor precondition failed: " + name)
            preconditions[name] = {"nonce": nonce, "code": code}
            rpc.request("anvil_setBalance", [actor, hex(1_000 * WAD)])
        rpc.request("anvil_setBlockTimestampInterval", [1])
        env = dict(os.environ, REHEARSAL_R0_SENDER=ACTORS["deployer"])
        _run(
            (
                "forge",
                "script",
                "script/RehearsalR0.s.sol:RehearsalR0",
                "--rpc-url",
                rpc_url,
                "--broadcast",
                "--unlocked",
                "--sender",
                ACTORS["deployer"],
                "--slow",
                "--skip-simulation",
                "--non-interactive",
            ),
            env=env,
        )
        deployment_end = int(rpc.block("latest")["number"], 16)
        deployment = _block_transactions(rpc, FORK_BLOCK + 1, deployment_end)
        if len(deployment) != 6:
            raise RehearsalError("fork deployment transaction count drifted")
        economic = _scenario(rpc, deployment, artifacts)
        return economic, {
            "port": port,
            "processId": process.pid,
            "providerUrl": fork_url,
            "wallDurationMs": round((time.monotonic() - started) * 1000),
        }
    finally:
        process.terminate()
        process.wait(timeout=5)


def run(port: int, fork_url: str) -> dict[str, Any]:
    for command in ("anvil", "cast", "forge"):
        if shutil.which(command) is None:
            raise RehearsalError(command + " is required")
    fork_url = _provider(fork_url)
    _preflight(fork_url)
    if UNSTABLE_POOL != documents.keccak256(b"UnstablePool(address,int24,int24)")[:10]:
        raise RehearsalError("UnstablePool selector drifted")
    artifacts = windtunnel._artifact_evidence()
    first, first_observation = _run_once(port, fork_url, artifacts)
    second, second_observation = _run_once(port + 1, fork_url, artifacts)
    first_raw = _canonical(first)
    second_raw = _canonical(second)
    if first_raw != second_raw:
        raise RehearsalError(
            "economic projections diverged: %s != %s"
            % (hashlib.sha256(first_raw).hexdigest(), hashlib.sha256(second_raw).hexdigest())
        )
    digest = "0x" + hashlib.sha256(first_raw).hexdigest()
    return {
        "comparison": {
            "economicProjectionSha256": digest,
            "excludedFields": ["port", "processId", "providerUrl", "wallDurationMs"],
            "identical": True,
        },
        "economicProjection": first,
        "kind": "fao.rehearsal.r0-s1",
        "observations": [first_observation, second_observation],
        "publicBroadcasts": 0,
        "v": "1",
    }


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fork-url", default="https://sepolia.drpc.org")
    parser.add_argument("--port", type=int, default=19_655)
    parser.add_argument("--output", type=Path, default=Path("/tmp/fao-rehearsal-r0-s1.json"))
    args = parser.parse_args(argv)
    evidence = run(args.port, args.fork_url)
    args.output.write_bytes(_canonical(evidence))
    print("wrote %s (%s)" % (args.output, evidence["comparison"]["economicProjectionSha256"]))
    print("public broadcasts: 0")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, runner.RunnerError) as error:
        print("error: " + str(error), file=os.sys.stderr)
        raise SystemExit(1)
