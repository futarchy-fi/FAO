#!/usr/bin/env python3
"""Run the deterministic local Rehearsal R0 S2 hero and failed twin twice."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import socket
import subprocess
import time
from pathlib import Path
from typing import Any, Sequence
from urllib.parse import urlsplit

try:
    from tools import agent_anvil_drill as drill
    from tools import agent_documents as documents
    from tools import agent_runner as runner
    from tools.rehearsal_r0 import (
        Session,
        _account_commitments,
        _address_word,
        _address,
        _balance,
        _block_transactions,
        _bool,
        _bytes32,
        _calldata,
        _call,
        _canonical,
        _dynamic_bytes,
        _event,
        _failed_transaction_trace,
        _log_digest,
        _receipt_address,
        _runtime_hash,
        _sha256,
        _uint,
        _uint_word,
        _words,
    )
except ModuleNotFoundError:  # Direct script execution.
    import agent_anvil_drill as drill  # type: ignore
    import agent_documents as documents  # type: ignore
    import agent_runner as runner  # type: ignore
    from rehearsal_r0 import (  # type: ignore
        Session,
        _account_commitments,
        _address_word,
        _address,
        _balance,
        _block_transactions,
        _bool,
        _bytes32,
        _calldata,
        _call,
        _canonical,
        _dynamic_bytes,
        _event,
        _failed_transaction_trace,
        _log_digest,
        _receipt_address,
        _runtime_hash,
        _sha256,
        _uint,
        _uint_word,
        _words,
    )


ROOT = Path(__file__).resolve().parents[1]
CHAIN_ID = 31_337
GENESIS_TIMESTAMP = 1_800_000_000
WAD = 10**18
FEE = 500
ZERO_ADDRESS = "0x" + "00" * 20
UINT256_MAX = 2**256 - 1
EXCLUDED_FIELDS = ["port", "processId", "rpcUrl", "wallDurationMs"]
FIXTURE_TAR = ROOT / "tools/fixtures/rehearsal-r0-hostile-site.tar"
FIXTURE_PROVENANCE = ROOT / "tools/fixtures/rehearsal-r0-hostile-site.json"
FIXTURE_SHA256 = "52a71d8a295e8e9147be135fe4ae71be5a63955610f346282eddedff8d9e677b"
FIXTURE_KECCAK = "0x87dbbe9ead61a2ab66cc5a79ee8a075526cee2218f688a5ad8cc98724deea344"
FIXTURE_PROVENANCE_SHA256 = "83bdda046d5af6f3510f9abd75ef3dc66d99b1cbe1e22e6eff0939a482cbe94f"
LOCAL_DEPENDENCIES_TOPIC = (
    "0x6b41b3801d99a0d6124a12b182d87a32f1f1682c33b8ea6fcd2a4ba53edb28e5"
)
SITE_PAYLOAD = (
    "0x0000000000000000000000000000000000000000000000000000000000000020"
    "0000000000000000000000000000000000000000000000000000000000000001"
    "0000000000000000000000000000000000000000000000000000000000000000"
    "87dbbe9ead61a2ab66cc5a79ee8a075526cee2218f688a5ad8cc98724deea344"
    "0000000000000000000000000000000000000000000000000000000000000080"
    "0000000000000000000000000000000000000000000000000000000000000033"
    "7265706f3a2f2f746f6f6c732f66697874757265732f72656865617273616c2d"
    "72302d686f7374696c652d736974652e74617200000000000000000000000000"
)
SITE_URI = "repo://tools/fixtures/rehearsal-r0-hostile-site.tar"
SITE_ARB_HASH = "0x5e0d9f1195b1ad6d7cbbd4fb6bf781492570048a612fe3a997df5155c4aac503"
SALTS = {
    "s1": "0x37edbde02be1f4c103bc170c620e99af3e403c0544c68582f4a6a693686a5afc",
    "s2": "0x9dbb9851187137af8218d61f7da520ec5e3986c786f48bc36178a270c2a3abce",
    "s3": "0x1aae315a025bf2b15329f0b047b1d6364a2b9986dccfb033c6ab6dff91fe7069",
    "medium": "0x71c69b5b475212943cb2d22632300b61f896ed793abea4a6824abd774a779939",
    "overCap": "0x616f3ccfd4e0dbc02382c1b98c6a2cfa2472ead84f735c5146af6b90eba7dbf1",
    "param": "0x2381d06fab721a2ac89660bfa1b5f88e380921d8d974de402bca8e318c1d46cc",
    "critical": "0x9209fd381e40bb5efadf72b812dd7a42c4b6d30abef891db22a748ee84cd14eb",
}

ACTORS = {
    name: "0x100000000000000000000000000000000000%04x" % ordinal
    for ordinal, name in enumerate(
        (
            "deployer",
            "funder1",
            "funder2",
            "funder3",
            "funder4",
            "keeper",
            "lp1",
            "lp2",
            "proposer",
            "yesBidder",
            "recipient",
        ),
        1,
    )
}


class LocalRehearsalError(ValueError):
    pass


def _loopback(url: str) -> str:
    parsed = urlsplit(url)
    if parsed.scheme != "http" or parsed.hostname not in ("127.0.0.1", "::1"):
        raise LocalRehearsalError("transaction RPC must be loopback HTTP")
    return url


def _chain_id(value: int) -> int:
    if value != CHAIN_ID:
        raise LocalRehearsalError("local rehearsal requires chain 31337")
    return value


def _require_unused_port(port: int) -> None:
    if port <= 0 or port > 65_535:
        raise LocalRehearsalError("invalid Anvil port")
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.settimeout(0.1)
        if probe.connect_ex(("127.0.0.1", port)) == 0:
            raise LocalRehearsalError("Anvil port is already in use: %d" % port)


def _clock(t0: int) -> dict[str, int]:
    clock = {
        "deploy": t0,
        "saleClosedProbe": t0 + 24 * 60 * 60,
        "saleSeal": t0 + 24 * 60 * 60 + 1,
        "siteProposal": t0 + 90_000,
        "siteBond": t0 + 90_001,
    }
    clock.update(
        {
            "siteEarlyTimeout": clock["siteBond"] + 259_199,
            "siteSettlement": clock["siteBond"] + 259_200,
            "siteExecute": clock["siteBond"] + 259_201,
            "siteWithdraw": clock["siteBond"] + 259_202,
        }
    )
    clock["treasuryFirstProposal"] = clock["siteWithdraw"] + 1
    clock["treasuryLatestBond"] = clock["treasuryFirstProposal"] + 13
    clock["treasuryFirstSettlement"] = clock["treasuryLatestBond"] + 259_200
    clock.update(
        {
            "treasuryBondWithdraw": clock["treasuryFirstSettlement"] + 7,
            "s1Queue": clock["treasuryFirstSettlement"] + 8,
            "s1DoubleQueue": clock["treasuryFirstSettlement"] + 9,
            "s2Queue": clock["treasuryFirstSettlement"] + 10,
            "s3Queue": clock["treasuryFirstSettlement"] + 11,
            "s1GraceFailure": clock["treasuryFirstSettlement"] + 86_399,
            "s1Execute": clock["treasuryFirstSettlement"] + 86_400,
            "s2Execute": clock["treasuryFirstSettlement"] + 86_401,
            "s3TapFailure": clock["treasuryFirstSettlement"] + 86_402,
            "s3ExpiresAt": clock["treasuryFirstSettlement"] + 691_202,
            "s3ExpireTooEarly": clock["treasuryFirstSettlement"] + 691_202,
            "s3Expire": clock["treasuryFirstSettlement"] + 691_203,
            "s3ExecuteExpired": clock["treasuryFirstSettlement"] + 691_204,
            "ragequit": clock["treasuryFirstSettlement"] + 691_205,
            "flmRedeem": clock["treasuryFirstSettlement"] + 691_206,
        }
    )
    return clock


def _run(command: Sequence[str], *, env: dict[str, str] | None = None) -> str:
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
    if result.returncode:
        raise LocalRehearsalError(
            "command failed: %s\n%s" % (" ".join(command), result.stderr[-3000:])
        )
    return result.stdout.strip()


def _ceil_div(numerator: int, denominator: int) -> int:
    if denominator <= 0:
        raise LocalRehearsalError("division denominator must be positive")
    return (numerator + denominator - 1) // denominator


def _mint(session: Session, token: str, actor: str, amount: int, label: str) -> None:
    before = _balance(session.rpc, token, actor)
    session.send(label, actor, token, _calldata("mint(address,uint256)", actor, amount))
    if _balance(session.rpc, token, actor) - before != amount:
        raise LocalRehearsalError("mock mint did not conserve")


def _approve(
    session: Session, actor: str, token: str, spender: str, amount: int, label: str
) -> None:
    session.send(label, actor, token, _calldata("approve(address,uint256)", spender, amount))
    if _uint(session.rpc, token, "allowance(address,address)", actor, spender) != amount:
        raise LocalRehearsalError("approval did not land")


def _transfer(
    session: Session, token: str, sender: str, recipient: str, amount: int, label: str
) -> None:
    before = _balance(session.rpc, token, recipient)
    session.send(label, sender, token, _calldata("transfer(address,uint256)", recipient, amount))
    if _balance(session.rpc, token, recipient) - before != amount:
        raise LocalRehearsalError("token transfer did not conserve")


def _failure(
    session: Session,
    label: str,
    sender: str,
    target: str,
    data: str,
    expected_return: str,
    protocol_accounts: Sequence[str],
    semantic_snapshot: Any,
    semantic_after: Any,
) -> dict[str, Any]:
    before = _account_commitments(session.rpc, protocol_accounts)
    sent = session.send(label, sender, target, data, expected_status=0)
    if sent["receipt"]["logs"]:
        raise LocalRehearsalError(label + " failed transaction emitted logs")
    trace = _failed_transaction_trace(session.rpc, sent["record"]["hash"])
    if trace["returnValue"] != expected_return.lower():
        raise LocalRehearsalError(
            "%s revert %s != %s" % (label, trace["returnValue"], expected_return.lower())
        )
    after = _account_commitments(session.rpc, protocol_accounts)
    if before != after or semantic_snapshot != semantic_after():
        raise LocalRehearsalError(label + " was not atomic")
    return {
        "gasUsed": sent["record"]["gasUsed"],
        "protocolCommitments": before,
        "returnValue": trace["returnValue"],
        "transaction": sent["record"],
    }


def _send_next(
    session: Session, label: str, sender: str, target: str, data: str, *, value: int = 0
) -> dict[str, Any]:
    """Mine a success at clock+1 without Session's current-block eth_call preflight."""
    transaction = {
        "from": sender,
        "to": target,
        "data": data,
        "value": hex(value),
        "gas": hex(55_000_000),
    }
    session.rpc.request("evm_setNextBlockTimestamp", [session.clock + 1])
    tx_hash = session.rpc.request("eth_sendTransaction", [transaction])
    if not isinstance(tx_hash, str):
        raise LocalRehearsalError("eth_sendTransaction returned no hash")
    receipt = drill._receipt(session.rpc, tx_hash)
    if int(receipt["status"], 16) != 1:
        raise LocalRehearsalError(label + " failed")
    landed = session.rpc.request("eth_getTransactionByHash", [tx_hash])
    block = session.rpc.block(int(receipt["blockNumber"], 16))
    if (
        not isinstance(landed, dict)
        or landed.get("input", "").lower() != data
        or landed.get("from", "").lower() != sender
        or landed.get("to", "").lower() != target
    ):
        raise LocalRehearsalError("landed transaction identity drifted")
    session.clock = int(block["timestamp"], 16)
    record = {
        "blockHash": receipt["blockHash"].lower(),
        "blockNumber": int(receipt["blockNumber"], 16),
        "blockTimestamp": session.clock,
        "from": sender,
        "gasUsed": int(receipt["gasUsed"], 16),
        "hash": tx_hash.lower(),
        "inputKeccak256": documents.keccak256(bytes.fromhex(data[2:])),
        "label": label,
        "logCount": len(receipt["logs"]),
        "logsSha256": _log_digest(receipt["logs"]),
        "nonce": int(landed["nonce"], 16),
        "status": 1,
        "to": target,
        "value": str(value),
    }
    session.transactions.append(record)
    return {"receipt": receipt, "record": record}


def _position_id(rpc: runner.JsonRpc, adapter: str, token_a: str, token_b: str) -> int:
    token0, token1 = sorted((token_a, token_b))
    return _uint(rpc, adapter, "getPositionTokenId(address,address)", token0, token1)


def _npm_position(rpc: runner.JsonRpc, npm: str, token_id: int) -> dict[str, Any]:
    words = _words(_call(rpc, npm, "positions(uint256)", token_id), 12)
    return {
        "fee": _uint_word(words[4]),
        "liquidity": _uint_word(words[7]),
        "tickLower": int.from_bytes(words[5][-3:], "big", signed=True),
        "tickUpper": int.from_bytes(words[6][-3:], "big", signed=True),
        "token0": _address_word(words[2]),
        "token1": _address_word(words[3]),
        "tokenId": str(token_id),
        "tokensOwed0": _uint_word(words[10]),
        "tokensOwed1": _uint_word(words[11]),
    }


def _managed_base(
    rpc: runner.JsonRpc, manager: str, npm: str, company: str, weth: str
) -> dict[str, int]:
    return {
        "company": _balance(rpc, company, manager) + _balance(rpc, company, npm),
        "weth": _balance(rpc, weth, manager) + _balance(rpc, weth, npm),
    }


def _fixture_evidence() -> dict[str, Any]:
    tar = FIXTURE_TAR.read_bytes()
    provenance_raw = FIXTURE_PROVENANCE.read_bytes()
    provenance = json.loads(provenance_raw)
    sha = hashlib.sha256(tar).hexdigest()
    provenance_sha = hashlib.sha256(provenance_raw).hexdigest()
    keccak = documents.keccak256(tar)
    if (
        len(tar) != 10_240
        or sha != FIXTURE_SHA256
        or keccak != FIXTURE_KECCAK
        or provenance_sha != FIXTURE_PROVENANCE_SHA256
        or provenance.get("archiveSha256") != "0x" + sha
        or provenance.get("artifactDigest") != keccak
        or provenance.get("archiveBytes") != len(tar)
    ):
        raise LocalRehearsalError("hostile site fixture provenance drifted")
    return {
        "bytes": len(tar),
        "keccak256": keccak,
        "provenance": provenance,
        "provenanceSha256": "0x" + provenance_sha,
        "sha256": "0x" + sha,
    }


def _dependency_manifest(
    rpc: runner.JsonRpc, deployment_start: int, deployment_end: int
) -> dict[str, str]:
    logs = rpc.request(
        "eth_getLogs",
        [
            {
                "fromBlock": hex(deployment_start),
                "toBlock": hex(deployment_end),
                "topics": [LOCAL_DEPENDENCIES_TOPIC],
            }
        ],
    )
    if not isinstance(logs, list) or len(logs) != 1:
        raise LocalRehearsalError("deployment did not emit one LocalDependencies event")
    log = logs[0]
    topics = log.get("topics")
    if not isinstance(topics, list) or len(topics) != 4:
        raise LocalRehearsalError("LocalDependencies topics are malformed")
    words = _words(log["data"], 2)
    return {
        "factory": _address_word(bytes.fromhex(topics[2][2:])),
        "positionManager": _address_word(bytes.fromhex(topics[3][2:])),
        "poolTemplate": _address_word(words[0]),
        "registrar": _address_word(words[1]),
        "weth": _address_word(bytes.fromhex(topics[1][2:])),
    }


def _stack_pair(
    rpc: runner.JsonRpc, deployment_start: int, deployment_end: int
) -> tuple[dict[str, Any], dict[str, Any], dict[str, str]]:
    dependencies = _dependency_manifest(rpc, deployment_start, deployment_end)
    topic = documents.keccak256(b"GenesisStaged(address,bytes32,bytes32,address)")
    logs = rpc.request(
        "eth_getLogs",
        [
            {
                "address": dependencies["registrar"],
                "fromBlock": hex(deployment_start),
                "toBlock": hex(deployment_end),
                "topics": [topic],
            }
        ],
    )
    if not isinstance(logs, list) or len(logs) != 2:
        raise LocalRehearsalError("deployment did not emit two GenesisStaged events")
    logs.sort(key=lambda item: (int(item["blockNumber"], 16), int(item["logIndex"], 16)))
    sealed_logs: dict[str, list[dict[str, Any]]] = {}
    for label, signature in (
        (
            "core",
            "CoreSealed(address,address,address,address,address,address)",
        ),
        ("flm", "FlmSealed(address,address,address)"),
    ):
        matches = rpc.request(
            "eth_getLogs",
            [
                {
                    "fromBlock": hex(deployment_start),
                    "toBlock": hex(deployment_end),
                    "topics": [documents.keccak256(signature.encode())],
                }
            ],
        )
        if not isinstance(matches, list) or len(matches) != 2:
            raise LocalRehearsalError("deployment did not emit two %s seal events" % label)
        sealed_logs[label] = matches
    names = (
        "space",
        "arbitration",
        "vault",
        "companyToken",
        "proposalGateway",
        "releaseStrategy",
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
        "votingStrategy",
    )
    stacks = []
    for ordinal, log in enumerate(logs, 1):
        topics = log.get("topics")
        if (
            not isinstance(topics, list)
            or len(topics) != 4
            or _address_word(_words(log["data"], 1)[0]) != ACTORS["deployer"]
        ):
            raise LocalRehearsalError("GenesisStaged event is malformed")
        receipt = _receipt_address(log)
        addresses = {name: _address(rpc, receipt, name + "()") for name in names}
        addresses.update({"receipt": receipt, "registrar": log["address"].lower()})
        core_hash = _bytes32(rpc, receipt, "CORE_CONFIG_HASH()")
        flm_hash = _bytes32(rpc, receipt, "FLM_CONFIG_HASH()")
        core_matches = [item for item in sealed_logs["core"] if item["address"].lower() == receipt]
        flm_matches = [item for item in sealed_logs["flm"] if item["address"].lower() == receipt]
        if len(core_matches) != 1 or len(flm_matches) != 1:
            raise LocalRehearsalError("receipt seal-event emitter drifted")
        core_event = core_matches[0]
        flm_event = flm_matches[0]
        core_words = _words(core_event["data"], 3)
        flm_words = _words(flm_event["data"], 2)
        if (
            addresses["registrar"] != dependencies["registrar"]
            or topics[2].lower() != core_hash
            or topics[3].lower() != flm_hash
            or not _bool(rpc, receipt, "coreSealed()")
            or not _bool(rpc, receipt, "flmSealed()")
            or _address(rpc, receipt, "weth()") != dependencies["weth"]
            or _address(rpc, receipt, "uniswapV3Factory()") != dependencies["factory"]
            or _address(rpc, addresses["spotAdapter"], "POSITION_MANAGER()")
            != dependencies["positionManager"]
            or len(core_event["topics"]) != 4
            or _address_word(bytes.fromhex(core_event["topics"][1][2:])) != addresses["vault"]
            or _address_word(bytes.fromhex(core_event["topics"][2][2:]))
            != addresses["companyToken"]
            or _address_word(bytes.fromhex(core_event["topics"][3][2:])) != addresses["space"]
            or [_address_word(word) for word in core_words]
            != [addresses["arbitration"], addresses["evaluator"], addresses["spotPool"]]
            or len(flm_event["topics"]) != 2
            or _address_word(bytes.fromhex(flm_event["topics"][1][2:])) != addresses["manager"]
            or [_address_word(word) for word in flm_words]
            != [addresses["relay"], addresses["spotAdapter"]]
        ):
            raise LocalRehearsalError("local stack dependency wiring drifted")
        if rpc.request("eth_getCode", [addresses["spotPool"], "latest"]) != "0x":
            raise LocalRehearsalError("predicted spot pool existed before provisioning")
        stacks.append(
            {
                "addresses": addresses,
                "coreConfigHash": core_hash,
                "flmConfigHash": flm_hash,
                "ordinal": ordinal,
                "predictedUndeployed": addresses["spotPool"],
            }
        )
    if stacks[0]["addresses"]["receipt"] == stacks[1]["addresses"]["receipt"]:
        raise LocalRehearsalError("hero and failed twin receipts collided")
    return stacks[0], stacks[1], dependencies


def _install_hero_pool(
    session: Session, hero: dict[str, Any], dependencies: dict[str, str]
) -> dict[str, str]:
    rpc = session.rpc
    a = hero["addresses"]
    pool = a["spotPool"]
    template_code = rpc.request("eth_getCode", [dependencies["poolTemplate"], "latest"])
    if not isinstance(template_code, str) or template_code == "0x":
        raise LocalRehearsalError("local pool template runtime is missing")
    template_hash = documents.keccak256(bytes.fromhex(template_code[2:]))
    if rpc.request("eth_getCode", [pool, "latest"]) != "0x":
        raise LocalRehearsalError("hero pool was not empty before anvil_setCode")
    if rpc.request("anvil_setCode", [pool, template_code]) is not None:
        raise LocalRehearsalError("anvil_setCode returned an unexpected value")
    installed_code = rpc.request("eth_getCode", [pool, "latest"])
    installed_hash = documents.keccak256(bytes.fromhex(installed_code[2:]))
    if installed_code != template_code or installed_hash != template_hash:
        raise LocalRehearsalError("installed pool runtime differs from the same-run template")
    session.send(
        "fixture:configure-hero-pool",
        ACTORS["keeper"],
        pool,
        _calldata(
            "configure(address,address,uint24,uint160,bool)",
            a["companyToken"],
            dependencies["weth"],
            FEE,
            0,
            "false",
        ),
    )
    session.send(
        "fixture:register-hero-pool",
        ACTORS["keeper"],
        dependencies["factory"],
        _calldata(
            "setPool(address,address,uint24,address)",
            a["companyToken"],
            dependencies["weth"],
            FEE,
            pool,
        ),
    )
    if (
        _address(
            rpc,
            dependencies["factory"],
            "getPool(address,address,uint24)",
            a["companyToken"],
            dependencies["weth"],
            FEE,
        )
        != pool
        or _uint(rpc, pool, "fee()") != FEE
    ):
        raise LocalRehearsalError("hero pool fixture did not register")
    return {
        "installedRuntimeHash": installed_hash,
        "target": pool,
        "template": dependencies["poolTemplate"],
        "templateRuntimeHash": template_hash,
    }


def _sale_state(rpc: runner.JsonRpc, vault: str, weth: str) -> dict[str, Any]:
    return {
        "phase": _uint(rpc, vault, "phase()"),
        "raised": str(_uint(rpc, vault, "totalRaised()")),
        "sold": str(_uint(rpc, vault, "totalSold()")),
        "unclaimed": str(_uint(rpc, vault, "totalUnclaimedSold()")),
        "weth": str(_balance(rpc, weth, vault)),
    }


def _buy(
    session: Session,
    vault: str,
    weth: str,
    actor_name: str,
    amount: int,
    sold_before: int,
    label: str,
) -> dict[str, str]:
    actor = ACTORS[actor_name]
    before = _uint(session.rpc, vault, "reserveAt(uint256)", sold_before)
    after = _uint(session.rpc, vault, "reserveAt(uint256)", sold_before + amount)
    cost = after - before
    _mint(session, weth, actor, cost, label + ":mint")
    _approve(session, actor, weth, vault, cost, label + ":approve")
    sent = session.send(
        label + ":buy",
        actor,
        vault,
        _calldata("buy(uint256,uint256,uint256)", amount, cost, session.clock + 10_000),
    )
    event = _event(sent["receipt"], "Purchased(address,uint256,uint256)", vault)
    if (
        len(event["topics"]) != 2
        or _address_word(bytes.fromhex(event["topics"][1][2:])) != actor
        or [_uint_word(word) for word in _words(event["data"], 2)] != [amount, cost]
    ):
        raise LocalRehearsalError(label + " purchase event drifted")
    return {"actor": actor_name, "amount": str(amount), "cost": str(cost)}


def _claim(session: Session, vault: str, company: str, actor_name: str) -> int:
    actor = ACTORS[actor_name]
    expected = _uint(session.rpc, vault, "purchased(address)", actor)
    before = _balance(session.rpc, company, actor)
    sent = session.send(
        "hero:claim:" + actor_name,
        ACTORS["keeper"],
        vault,
        _calldata("claim(address)", actor),
    )
    event = _event(sent["receipt"], "Claimed(address,uint256)", vault)
    if (
        len(event["topics"]) != 2
        or _address_word(bytes.fromhex(event["topics"][1][2:])) != actor
        or _uint_word(_words(event["data"], 1)[0]) != expected
        or _balance(session.rpc, company, actor) - before != expected
    ):
        raise LocalRehearsalError("hero claim drifted for " + actor_name)
    return expected


def _refund(session: Session, vault: str, weth: str, actor_name: str) -> int:
    actor = ACTORS[actor_name]
    expected = _uint(session.rpc, vault, "contribution(address)", actor)
    before = _balance(session.rpc, weth, actor)
    sent = session.send(
        "twin:refund:" + actor_name,
        ACTORS["keeper"],
        vault,
        _calldata("refund(address)", actor),
    )
    event = _event(sent["receipt"], "Refunded(address,uint256)", vault)
    if (
        len(event["topics"]) != 2
        or _address_word(bytes.fromhex(event["topics"][1][2:])) != actor
        or _uint_word(_words(event["data"], 1)[0]) != expected
        or _balance(session.rpc, weth, actor) - before != expected
    ):
        raise LocalRehearsalError("failed twin refund drifted for " + actor_name)
    return expected


def _spot_deposit(
    session: Session,
    manager: str,
    npm: str,
    company: str,
    weth: str,
    source: str,
    actor_name: str,
    collateral: int,
) -> dict[str, str]:
    rpc = session.rpc
    actor = ACTORS[actor_name]
    assets = _managed_base(rpc, manager, npm, company, weth)
    supply = _uint(rpc, manager, "totalSupply()")
    company_input = _ceil_div(assets["company"] * collateral, assets["weth"])
    _transfer(session, company, source, actor, company_input, "spot:%s:company" % actor_name)
    _mint(session, weth, actor, collateral, "spot:%s:weth" % actor_name)
    _approve(session, actor, company, manager, company_input, "spot:%s:approve-company" % actor_name)
    _approve(session, actor, weth, manager, collateral, "spot:%s:approve-weth" % actor_name)
    shares_before = _balance(rpc, manager, actor)
    sent = session.send(
        "spot:%s:deposit" % actor_name,
        actor,
        manager,
        _calldata("depositToSpot(uint256,uint256)", company_input, collateral),
    )
    shares = _balance(rpc, manager, actor) - shares_before
    expected_shares = min(
        company_input * supply // assets["company"], collateral * supply // assets["weth"]
    )
    expected_company_accepted = _ceil_div(expected_shares * assets["company"], supply)
    expected_weth_accepted = _ceil_div(expected_shares * assets["weth"], supply)
    event = _event(sent["receipt"], "SpotDeposited(address,uint256,uint256,uint256)", manager)
    values = [_uint_word(word) for word in _words(event["data"], 3)]
    if (
        len(event["topics"]) != 2
        or _address_word(bytes.fromhex(event["topics"][1][2:])) != actor
        or shares == 0
        or shares != expected_shares
        or values != [expected_company_accepted, expected_weth_accepted, shares]
    ):
        raise LocalRehearsalError("permissionless spot deposit drifted")
    return {
        "acceptedCompany": str(values[0]),
        "acceptedWeth": str(values[1]),
        "actor": actor_name,
        "inputCompany": str(company_input),
        "inputWeth": str(collateral),
        "shares": str(shares),
    }


def _spot_redeem(
    session: Session,
    manager: str,
    npm: str,
    company: str,
    weth: str,
    actor_name: str,
) -> dict[str, str]:
    rpc = session.rpc
    actor = ACTORS[actor_name]
    shares_held = _balance(rpc, manager, actor)
    shares = shares_held // 2
    if shares == 0 or shares == shares_held:
        raise LocalRehearsalError("partial redemption needs a nonzero remainder")
    supply = _uint(rpc, manager, "totalSupply()")
    assets = _managed_base(rpc, manager, npm, company, weth)
    expected_company = assets["company"] * shares // supply
    expected_weth = assets["weth"] * shares // supply
    before_company = _balance(rpc, company, actor)
    before_weth = _balance(rpc, weth, actor)
    sent = session.send(
        "spot:%s:redeem" % actor_name,
        actor,
        manager,
        _calldata("redeem(uint256,address,bool)", shares, actor, "false"),
    )
    event = _event(sent["receipt"], "SharesRedeemed(address,address,uint256,uint256,uint256)", manager)
    values = [_uint_word(word) for word in _words(event["data"], 3)]
    if (
        len(event["topics"]) != 3
        or _address_word(bytes.fromhex(event["topics"][1][2:])) != actor
        or _address_word(bytes.fromhex(event["topics"][2][2:])) != actor
        or values != [shares, expected_company, expected_weth]
        or _balance(rpc, company, actor) - before_company != expected_company
        or _balance(rpc, weth, actor) - before_weth != expected_weth
        or _balance(rpc, manager, actor) != shares_held - shares
    ):
        raise LocalRehearsalError("permissionless spot redemption drifted")
    return {
        "actor": actor_name,
        "companyOut": str(expected_company),
        "remainingShares": str(shares_held - shares),
        "shares": str(shares),
        "wethOut": str(expected_weth),
    }


def _arb_state(rpc: runner.JsonRpc, arbitration: str, proposal_id: int) -> dict[str, Any]:
    words = _words(_call(rpc, arbitration, "getProposal(uint256)", proposal_id), 11)
    return {
        "accepted": bool(_uint_word(words[8])),
        "exists": bool(_uint_word(words[10])),
        "lastStateChangeAt": _uint_word(words[6]),
        "minActivationBond": str(_uint_word(words[0])),
        "noAmount": str(_uint_word(words[4])),
        "noBidder": _address_word(words[3]),
        "queuePosition": _uint_word(words[9]),
        "settled": bool(_uint_word(words[7])),
        "state": _uint_word(words[5]),
        "yesAmount": str(_uint_word(words[2])),
        "yesBidder": _address_word(words[1]),
    }


def _space_state(rpc: runner.JsonRpc, space: str, proposal_id: int) -> dict[str, Any]:
    words = _words(_call(rpc, space, "proposals(uint256)", proposal_id), 8)
    return {
        "activeVotingStrategies": _uint_word(words[7]),
        "author": _address_word(words[0]),
        "executionPayloadHash": "0x" + words[6].hex(),
        "executionStrategy": _address_word(words[2]),
        "finalizationStatus": _uint_word(words[5]),
        "maxEndBlock": _uint_word(words[4]),
        "minEndBlock": _uint_word(words[3]),
        "startBlock": _uint_word(words[1]),
        "status": _uint(rpc, space, "getProposalStatus(uint256)", proposal_id),
    }


def _release_state(rpc: runner.JsonRpc, release_strategy: str) -> dict[str, Any]:
    return {
        "digest": _bytes32(rpc, release_strategy, "releaseDigest()"),
        "nonce": _uint(rpc, release_strategy, "releaseNonce()"),
        "uri": _dynamic_bytes(_call(rpc, release_strategy, "releaseURI()")).decode(),
    }


def _zero_vote_state(
    rpc: runner.JsonRpc, space: str, voting_strategy: str, gateway: str, proposal_id: int
) -> dict[str, Any]:
    strategy_words = _words(_call(rpc, space, "votingStrategies(uint8)", 0))
    if (
        _uint(rpc, space, "activeVotingStrategies()") != 1
        or not strategy_words
        or _address_word(strategy_words[0]) != voting_strategy
        or _uint(rpc, space, "authenticators(address)", gateway) != 1
    ):
        raise LocalRehearsalError("Snapshot X no-vote wiring drifted")
    registries = {}
    for name, actor in ACTORS.items():
        if _uint(rpc, space, "authenticators(address)", actor) != 0:
            raise LocalRehearsalError("fixed actor became a Snapshot X authenticator: " + name)
        registries[name] = _uint(rpc, space, "voteRegistry(uint256,address)", proposal_id, actor)
        if registries[name] != 0:
            raise LocalRehearsalError("vote registry changed without a vote path")
    powers = {
        label: _uint(rpc, space, "votePower(uint256,uint8)", proposal_id, choice)
        for choice, label in enumerate(("against", "for", "abstain"))
    }
    if any(powers.values()):
        raise LocalRehearsalError("Snapshot X accumulated voting power")
    zero = _uint(
        rpc,
        voting_strategy,
        "getVotingPower(uint32,address,bytes,bytes)",
        0,
        ACTORS["yesBidder"],
        "0x",
        "0x",
    )
    if zero != 0:
        raise LocalRehearsalError("AlwaysZeroVotingStrategy returned nonzero power")
    return {
        "activeVotingStrategies": 1,
        "actorVoteRegistries": registries,
        "onlyGatewayAuthenticator": True,
        "strategyPower": zero,
        "votePower": powers,
        "votingStrategy": voting_strategy,
    }


def _site_semantics(
    rpc: runner.JsonRpc,
    addresses: dict[str, str],
    weth: str,
    proposal_id: int,
    arbitration_id: int,
) -> dict[str, Any]:
    return {
        "arbitration": _arb_state(rpc, addresses["arbitration"], arbitration_id),
        "arbitrationWeth": str(_balance(rpc, weth, addresses["arbitration"])),
        "bidderWithdrawable": str(
            _uint(
                rpc,
                addresses["arbitration"],
                "withdrawable(address)",
                ACTORS["yesBidder"],
            )
        ),
        "release": _release_state(rpc, addresses["releaseStrategy"]),
        "space": _space_state(rpc, addresses["space"], proposal_id),
        "votes": _zero_vote_state(
            rpc,
            addresses["space"],
            addresses["votingStrategy"],
            addresses["proposalGateway"],
            proposal_id,
        ),
    }


def _has_topic(receipt: dict[str, Any], topic: str, address: str) -> bool:
    return any(
        log["address"].lower() == address
        and log.get("topics", [""])[0].lower() == topic.lower()
        for log in receipt["logs"]
    )


def _site_stage(
    session: Session, addresses: dict[str, str], weth: str, clock: dict[str, int]
) -> dict[str, Any]:
    rpc = session.rpc
    if documents.keccak256(bytes.fromhex(SITE_PAYLOAD[2:])) != SITE_ARB_HASH:
        raise LocalRehearsalError("hostile site payload identity drifted")
    arbitration_id = int(SITE_ARB_HASH, 16)
    bidder = ACTORS["yesBidder"]
    _mint(session, weth, bidder, 14 * WAD, "site:bond-funds")
    _approve(session, bidder, weth, addresses["arbitration"], UINT256_MAX, "site:bond-approval")
    proposal_id = _uint(rpc, addresses["space"], "nextProposalId()")
    proposal_at = clock["siteProposal"]
    session.mine_at(proposal_at - 1)
    proposed = session.send(
        "site:propose-hostile-release",
        ACTORS["proposer"],
        addresses["proposalGateway"],
        _calldata(
            "propose(string,bytes,bytes)",
            "ipfs://fao-rehearsal-r0-s2-hostile-site",
            SITE_PAYLOAD,
            "0x",
        ),
    )
    if (
        proposed["record"]["blockTimestamp"] != proposal_at
        or _uint(rpc, addresses["space"], "nextProposalId()") != proposal_id + 1
        or not _has_topic(
            proposed["receipt"],
            "0xf8da673e3fac9fbd1c74ccfca5e1de23da9b2d616a790f0aeb2ba3f575c04ff1",
            addresses["space"],
        )
        or not _has_topic(
            proposed["receipt"],
            "0x3417b456fad6209c73445d5efd446d686e75e4560f0f50c13b5a5cde976447b4",
            addresses["arbitration"],
        )
    ):
        raise LocalRehearsalError("hostile site proposal did not bind both systems")
    bond = session.send(
        "site:place-yes-bond",
        bidder,
        addresses["arbitration"],
        _calldata("placeYesBond(uint256,uint256)", arbitration_id, WAD),
    )
    bond_at = bond["record"]["blockTimestamp"]
    if bond_at != clock["siteBond"]:
        raise LocalRehearsalError("site bond timestamp drifted")
    state_after_bond = _site_semantics(rpc, addresses, weth, proposal_id, arbitration_id)
    if (
        state_after_bond["arbitration"]["state"] != 1
        or state_after_bond["arbitration"]["yesAmount"] != str(WAD)
        or state_after_bond["space"]["status"] != 1
    ):
        raise LocalRehearsalError("unchallenged site YES state drifted")
    timeout = _uint(rpc, addresses["arbitration"], "timeout()")
    early_at = clock["siteEarlyTimeout"]
    if early_at != bond_at + timeout - 1:
        raise LocalRehearsalError("site timeout constant drifted")
    session.mine_at(early_at - 1)
    early_failure = _failure(
        session,
        "site:timeout:early",
        ACTORS["keeper"],
        addresses["arbitration"],
        _calldata("finalizeByTimeout(uint256)", arbitration_id),
        _calldata("TimeoutNotReached()"),
        (
            addresses["arbitration"],
            addresses["space"],
            addresses["releaseStrategy"],
            addresses["proposalGateway"],
            weth,
        ),
        state_after_bond,
        lambda: _site_semantics(rpc, addresses, weth, proposal_id, arbitration_id),
    )
    finalized = _send_next(
        session,
        "site:timeout:finalize",
        ACTORS["keeper"],
        addresses["arbitration"],
        _calldata("finalizeByTimeout(uint256)", arbitration_id),
    )
    final_event = _event(
        finalized["receipt"],
        "FinalizedByTimeout(uint256,bool,address,uint256)",
        addresses["arbitration"],
    )
    final_words = _words(final_event["data"], 2)
    if (
        finalized["record"]["blockTimestamp"] != clock["siteSettlement"]
        or clock["siteSettlement"] != bond_at + timeout
        or len(final_event["topics"]) != 3
        or int(final_event["topics"][1], 16) != arbitration_id
        or _address_word(bytes.fromhex(final_event["topics"][2][2:])) != bidder
        or [_uint_word(word) for word in final_words] != [1, WAD]
        or _space_state(rpc, addresses["space"], proposal_id)["status"] != 3
    ):
        raise LocalRehearsalError("site timeout settlement drifted")
    executed = session.send(
        "site:execute-release",
        ACTORS["keeper"],
        addresses["space"],
        _calldata("execute(uint256,bytes)", proposal_id, SITE_PAYLOAD),
    )
    if (
        executed["record"]["blockTimestamp"] != clock["siteExecute"]
        or
        not _has_topic(
            executed["receipt"],
            "0xaffbde70f75832d02e5dbcd327043d2219b0247708b9e4075944c364a402779a",
            addresses["releaseStrategy"],
        )
        or not _has_topic(
            executed["receipt"],
            "0x712ae1383f79ac853f8d882153778e0260ef8f03b504e2866e0593e04d2b291f",
            addresses["space"],
        )
    ):
        raise LocalRehearsalError("hostile site execution events drifted")
    before_withdraw = _balance(rpc, weth, bidder)
    withdrawn = session.send(
        "site:withdraw-bond",
        bidder,
        addresses["arbitration"],
        _calldata("withdraw()"),
    )
    withdraw_event = _event(withdrawn["receipt"], "Withdraw(address,uint256)", addresses["arbitration"])
    if (
        withdrawn["record"]["blockTimestamp"] != clock["siteWithdraw"]
        or
        len(withdraw_event["topics"]) != 2
        or _address_word(bytes.fromhex(withdraw_event["topics"][1][2:])) != bidder
        or _uint_word(_words(withdraw_event["data"], 1)[0]) != WAD
        or _balance(rpc, weth, bidder) - before_withdraw != WAD
        or _uint(rpc, addresses["arbitration"], "withdrawable(address)", bidder) != 0
        or _balance(rpc, weth, addresses["arbitration"]) != 0
    ):
        raise LocalRehearsalError("site bond withdrawal drifted")
    final_state = _site_semantics(rpc, addresses, weth, proposal_id, arbitration_id)
    if (
        final_state["release"]
        != {"digest": FIXTURE_KECCAK, "nonce": 1, "uri": SITE_URI}
        or final_state["space"]["status"] != 4
        or final_state["space"]["finalizationStatus"] != 1
    ):
        raise LocalRehearsalError("hostile site release state drifted")
    vote_topics = {
        documents.keccak256(b"VoteCast(uint256,address,uint8,uint256)"),
        documents.keccak256(b"VoteCastWithMetadata(uint256,address,uint8,uint256,string)"),
    }
    logs = rpc.request(
        "eth_getLogs",
        [
            {
                "address": addresses["space"],
                "fromBlock": hex(proposed["record"]["blockNumber"]),
                "toBlock": hex(executed["record"]["blockNumber"]),
            }
        ],
    )
    if any(log.get("topics", [""])[0].lower() in vote_topics for log in logs):
        raise LocalRehearsalError("Snapshot X emitted a vote event")
    return {
        "arbitrationId": str(arbitration_id),
        "bondAt": bond_at,
        "earlyTimeoutFailure": early_failure,
        "final": final_state,
        "payload": SITE_PAYLOAD,
        "proposalId": proposal_id,
        "releaseExecutedAt": executed["record"]["blockTimestamp"],
        "withdrawnAt": withdrawn["record"]["blockTimestamp"],
        "zeroVoteEvents": True,
    }


def _queued_action(rpc: runner.JsonRpc, vault: str, action_hash: str) -> dict[str, Any]:
    words = _words(_call(rpc, vault, "queuedActions(bytes32)", action_hash), 4)
    return {
        "executeAfter": _uint_word(words[0]),
        "executed": bool(_uint_word(words[2])),
        "expired": bool(_uint_word(words[3])),
        "expiresAt": _uint_word(words[1]),
    }


def _tap_state(rpc: runner.JsonRpc, vault: str, asset: str) -> dict[str, int]:
    words = _words(_call(rpc, vault, "tapStates(address)", asset), 2)
    return {"spent": _uint_word(words[1]), "windowStart": _uint_word(words[0])}


def _treasury_semantics(
    rpc: runner.JsonRpc,
    addresses: dict[str, str],
    weth: str,
    action_hashes: Sequence[str],
    critical_base_hash: str,
) -> dict[str, Any]:
    executor = _address(rpc, addresses["vault"], "TREASURY_EXECUTOR()")
    return {
        "criticalStaging": _call(
            rpc, addresses["vault"], "criticalStagings(bytes32)", critical_base_hash
        ),
        "executorWeth": str(_balance(rpc, weth, executor)),
        "queues": {
            action_hash: _queued_action(rpc, addresses["vault"], action_hash)
            for action_hash in action_hashes
        },
        "recipientWeth": str(_balance(rpc, weth, ACTORS["recipient"])),
        "tap": _tap_state(rpc, addresses["vault"], weth),
    }


def _action_identity(
    rpc: runner.JsonRpc,
    addresses: dict[str, str],
    kind: str,
    tuple_value: str,
) -> tuple[int, str]:
    gateway = addresses["proposalGateway"]
    vault = addresses["vault"]
    if kind == "transfer":
        proposal_id = _uint(
            rpc,
            gateway,
            "transferProposalId((address,address,uint256,bytes32))",
            tuple_value,
        )
        action_hash = _bytes32(
            rpc,
            vault,
            "transferActionHash((address,address,uint256,bytes32))",
            tuple_value,
        )
        payload = _dynamic_bytes(
            _call(
                rpc,
                gateway,
                "transferEvaluationPayload((address,address,uint256,bytes32))",
                tuple_value,
            )
        )
    elif kind == "param":
        proposal_id = _uint(
            rpc,
            gateway,
            "paramProposalId((bytes32,address,uint256,bytes32))",
            tuple_value,
        )
        action_hash = _bytes32(
            rpc,
            vault,
            "paramActionHash((bytes32,address,uint256,bytes32))",
            tuple_value,
        )
        payload = _dynamic_bytes(
            _call(
                rpc,
                gateway,
                "paramEvaluationPayload((bytes32,address,uint256,bytes32))",
                tuple_value,
            )
        )
    elif kind == "critical":
        proposal_id = _uint(
            rpc,
            gateway,
            "criticalProposalId((address,uint256,bytes,bytes32),uint256)",
            tuple_value,
            1,
        )
        action_hash = _bytes32(
            rpc,
            vault,
            "criticalActionBaseHash((address,uint256,bytes,bytes32))",
            tuple_value,
        )
        payload = _dynamic_bytes(
            _call(
                rpc,
                gateway,
                "criticalEvaluationPayload((address,uint256,bytes,bytes32),uint256)",
                tuple_value,
                1,
            )
        )
    else:
        raise LocalRehearsalError("unknown treasury action kind")
    if proposal_id != int(documents.keccak256(payload), 16):
        raise LocalRehearsalError(kind + " proposal payload/hash binding drifted")
    if kind != "critical" and proposal_id != int(action_hash, 16):
        raise LocalRehearsalError(kind + " gateway/vault identity drifted")
    return proposal_id, action_hash


def _treasury_stage(
    session: Session, addresses: dict[str, str], weth: str, clock: dict[str, int]
) -> dict[str, Any]:
    rpc = session.rpc
    gateway = addresses["proposalGateway"]
    vault = addresses["vault"]
    arbitration = addresses["arbitration"]
    recipient = ACTORS["recipient"]
    key_tap_budget = _bytes32(rpc, vault, "KEY_TAP_BUDGET()")
    transfer_specs = {
        "s1": (8 * WAD // 100, SALTS["s1"]),
        "s2": (7 * WAD // 100, SALTS["s2"]),
        "s3": (6 * WAD // 100, SALTS["s3"]),
        "medium": (WAD // 2, SALTS["medium"]),
        "overCap": (15 * WAD // 10, SALTS["overCap"]),
    }
    actions: dict[str, dict[str, Any]] = {}
    for label, (amount, salt) in transfer_specs.items():
        tuple_value = "(%s,%s,%d,%s)" % (weth, recipient, amount, salt)
        proposal_id, action_hash = _action_identity(
            rpc, addresses, "transfer", tuple_value
        )
        actions[label] = {
            "amount": amount,
            "hash": action_hash,
            "kind": "transfer",
            "proposalId": proposal_id,
            "tuple": tuple_value,
        }
    param_tuple = "(%s,%s,%d,%s)" % (
        key_tap_budget,
        weth,
        3 * WAD // 10,
        SALTS["param"],
    )
    param_id, param_hash = _action_identity(rpc, addresses, "param", param_tuple)
    actions["param"] = {
        "hash": param_hash,
        "kind": "param",
        "proposalId": param_id,
        "tuple": param_tuple,
    }
    critical_data = _calldata("approve(address,uint256)", recipient, 1)
    critical_tuple = "(%s,0,%s,%s)" % (weth, critical_data, SALTS["critical"])
    critical_id, critical_base_hash = _action_identity(
        rpc, addresses, "critical", critical_tuple
    )
    actions["critical"] = {
        "hash": critical_base_hash,
        "kind": "critical",
        "proposalId": critical_id,
        "tuple": critical_tuple,
    }
    ordered = ("s1", "s2", "s3", "medium", "overCap", "param", "critical")
    space_next = _uint(rpc, addresses["space"], "nextProposalId()")
    proposal_records = []
    for label in ordered:
        action = actions[label]
        if action["kind"] == "transfer":
            proposal_data = _calldata(
                "proposeTransfer((address,address,uint256,bytes32))", action["tuple"]
            )
        elif action["kind"] == "param":
            proposal_data = _calldata(
                "proposeParam((bytes32,address,uint256,bytes32))", action["tuple"]
            )
        else:
            proposal_data = _calldata(
                "proposeCriticalRound((address,uint256,bytes,bytes32),uint256)",
                action["tuple"],
                1,
            )
        proposed = session.send(
            "treasury:%s:propose" % label,
            ACTORS["proposer"],
            gateway,
            proposal_data,
        )
        bond = session.send(
            "treasury:%s:bond" % label,
            ACTORS["yesBidder"],
            arbitration,
            _calldata("placeYesBond(uint256,uint256)", action["proposalId"], 2 * WAD),
        )
        proposal = _arb_state(rpc, arbitration, action["proposalId"])
        if (
            proposal["state"] != 1
            or proposal["yesAmount"] != str(2 * WAD)
            or proposal["queuePosition"] != 0
        ):
            raise LocalRehearsalError(label + " timeout proposal state drifted")
        proposal_records.append(
            {
                "bondAt": bond["record"]["blockTimestamp"],
                "hash": action["hash"],
                "kind": action["kind"],
                "label": label,
                "proposalAt": proposed["record"]["blockTimestamp"],
                "proposalId": str(action["proposalId"]),
            }
        )
        if (
            proposed["record"]["blockTimestamp"]
            != clock["treasuryFirstProposal"] + 2 * (len(proposal_records) - 1)
            or bond["record"]["blockTimestamp"]
            != clock["treasuryFirstProposal"] + 2 * (len(proposal_records) - 1) + 1
        ):
            raise LocalRehearsalError(label + " absolute proposal clock drifted")
    if (
        _balance(rpc, weth, ACTORS["yesBidder"]) != 0
        or _uint(rpc, addresses["space"], "nextProposalId()") != space_next
    ):
        raise LocalRehearsalError("timeout treasury proposals escaped their bounded route")

    timeout = _uint(rpc, arbitration, "timeout()")
    first_settlement = clock["treasuryFirstSettlement"]
    if first_settlement != proposal_records[-1]["bondAt"] + timeout:
        raise LocalRehearsalError("treasury settlement clock drifted")
    session.mine_at(first_settlement - 1)
    settlements = []
    for index, label in enumerate(ordered):
        action = actions[label]
        finalized = session.send(
            "treasury:%s:finalize" % label,
            ACTORS["keeper"],
            arbitration,
            _calldata("finalizeByTimeout(uint256)", action["proposalId"]),
        )
        proposal = _arb_state(rpc, arbitration, action["proposalId"])
        if (
            finalized["record"]["blockTimestamp"] != first_settlement + index
            or not proposal["settled"]
            or not proposal["accepted"]
            or proposal["queuePosition"] != 0
            or proposal["lastStateChangeAt"] != first_settlement + index
        ):
            raise LocalRehearsalError(label + " timeout settlement drifted")
        settlements.append({"at": first_settlement + index, "label": label})
    if (
        _uint(rpc, arbitration, "withdrawable(address)", ACTORS["yesBidder"])
        != 14 * WAD
        or _balance(rpc, weth, arbitration) != 14 * WAD
    ):
        raise LocalRehearsalError("treasury timeout payout ledger drifted")
    before_withdraw = _balance(rpc, weth, ACTORS["yesBidder"])
    withdrawn = session.send(
        "treasury:withdraw-bonds",
        ACTORS["yesBidder"],
        arbitration,
        _calldata("withdraw()"),
    )
    if (
        withdrawn["record"]["blockTimestamp"] != clock["treasuryBondWithdraw"]
        or
        _balance(rpc, weth, ACTORS["yesBidder"]) - before_withdraw != 14 * WAD
        or _balance(rpc, weth, arbitration) != 0
    ):
        raise LocalRehearsalError("treasury timeout bond withdrawal drifted")

    transfer_hashes = [actions[label]["hash"] for label in transfer_specs]
    all_hashes = transfer_hashes + [param_hash, critical_base_hash]
    queued_s1 = session.send(
        "treasury:s1:queue",
        ACTORS["keeper"],
        vault,
        _calldata(
            "queueTreasuryTransfer((address,address,uint256,bytes32))", actions["s1"]["tuple"]
        ),
    )
    if not _has_topic(
        queued_s1["receipt"],
        "0x3f7eab0f3467fa03429ef9dd8a7c364d7ced05b7b309062ce6febc4da7b126ce",
        vault,
    ):
        raise LocalRehearsalError("S1 queue event is missing")
    if queued_s1["record"]["blockTimestamp"] != clock["s1Queue"]:
        raise LocalRehearsalError("S1 queue clock drifted")
    snapshot = _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash)
    failures: dict[str, Any] = {}
    protocol_accounts = (vault, arbitration, gateway, weth, _address(rpc, vault, "TREASURY_EXECUTOR()"))
    failures["doubleQueue"] = _failure(
        session,
        "treasury:s1:double-queue",
        ACTORS["keeper"],
        vault,
        _calldata(
            "queueTreasuryTransfer((address,address,uint256,bytes32))", actions["s1"]["tuple"]
        ),
        _calldata("ActionAlreadyQueued()"),
        protocol_accounts,
        snapshot,
        lambda: _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash),
    )
    if failures["doubleQueue"]["transaction"]["blockTimestamp"] != clock["s1DoubleQueue"]:
        raise LocalRehearsalError("S1 double-queue clock drifted")
    for label in ("s2", "s3"):
        queued = session.send(
            "treasury:%s:queue" % label,
            ACTORS["keeper"],
            vault,
            _calldata(
                "queueTreasuryTransfer((address,address,uint256,bytes32))",
                actions[label]["tuple"],
            ),
        )
        expected_at = clock["s2Queue"] if label == "s2" else clock["s3Queue"]
        if queued["record"]["blockTimestamp"] != expected_at:
            raise LocalRehearsalError(label + " queue clock drifted")

    def fail_route(label: str, data: str, expected: str) -> None:
        before = _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash)
        failures[label] = _failure(
            session,
            "treasury:" + label,
            ACTORS["keeper"],
            vault,
            data,
            expected,
            protocol_accounts,
            before,
            lambda: _treasury_semantics(
                rpc, addresses, weth, all_hashes, critical_base_hash
            ),
        )

    fail_route(
        "medium:timeout-route-rejected",
        _calldata(
            "queueTreasuryTransfer((address,address,uint256,bytes32))",
            actions["medium"]["tuple"],
        ),
        _calldata("EvaluatedAcceptanceRequired(uint256)", actions["medium"]["proposalId"]),
    )
    fail_route(
        "over-cap:rejected",
        _calldata(
            "queueTreasuryTransfer((address,address,uint256,bytes32))",
            actions["overCap"]["tuple"],
        ),
        _calldata("TransferAboveCap(address,uint256,uint256)", weth, 15 * WAD // 10, WAD),
    )
    fail_route(
        "param:timeout-route-rejected",
        _calldata(
            "queueTreasuryParam((bytes32,address,uint256,bytes32))", actions["param"]["tuple"]
        ),
        _calldata("EvaluatedAcceptanceRequired(uint256)", actions["param"]["proposalId"]),
    )
    fail_route(
        "critical:timeout-route-rejected",
        _calldata(
            "stageCriticalAction((address,uint256,bytes,bytes32))",
            actions["critical"]["tuple"],
        ),
        _calldata(
            "EvaluatedAcceptanceRequired(uint256)", actions["critical"]["proposalId"]
        ),
    )
    fail_route(
        "medium:expire-unqueued",
        _calldata("expireQueuedAction(bytes32)", actions["medium"]["hash"]),
        _calldata("ActionNotQueued()"),
    )

    q1 = _queued_action(rpc, vault, actions["s1"]["hash"])
    q2 = _queued_action(rpc, vault, actions["s2"]["hash"])
    q3 = _queued_action(rpc, vault, actions["s3"]["hash"])
    if (
        q1["executeAfter"] != first_settlement + 24 * 60 * 60
        or q2["executeAfter"] != q1["executeAfter"] + 1
        or q3["executeAfter"] != q2["executeAfter"] + 1
    ):
        raise LocalRehearsalError("timeout queue grace anchors drifted")
    session.mine_at(q1["executeAfter"] - 2)
    fail_route(
        "s1:grace",
        _calldata(
            "executeTreasuryTransfer((address,address,uint256,bytes32))", actions["s1"]["tuple"]
        ),
        _calldata("ActionInGracePeriod()"),
    )
    recipient_before = _balance(rpc, weth, recipient)
    executor = _address(rpc, vault, "TREASURY_EXECUTOR()")
    executor_before = _balance(rpc, weth, executor)
    executed_s1 = _send_next(
        session,
        "treasury:s1:execute",
        ACTORS["keeper"],
        vault,
        _calldata(
            "executeTreasuryTransfer((address,address,uint256,bytes32))", actions["s1"]["tuple"]
        ),
    )
    executed_s2 = _send_next(
        session,
        "treasury:s2:execute",
        ACTORS["keeper"],
        vault,
        _calldata(
            "executeTreasuryTransfer((address,address,uint256,bytes32))", actions["s2"]["tuple"]
        ),
    )
    if (
        not _has_topic(
            executed_s1["receipt"],
            "0x2dce1a2d95a46d524c37a17e4ab2bb652d315fd512006a558c60369eb1f1bda4",
            vault,
        )
        or not _has_topic(
            executed_s2["receipt"],
            "0x4ed7fe18bf204e6a049491966838b9d7aab0a410669942e47544103ca42d79c1",
            vault,
        )
        or _balance(rpc, weth, recipient) - recipient_before != 15 * WAD // 100
        or executor_before - _balance(rpc, weth, executor) != 15 * WAD // 100
        or _tap_state(rpc, vault, weth)
        != {"spent": 15 * WAD // 100, "windowStart": q1["executeAfter"]}
    ):
        raise LocalRehearsalError("bounded tap executions drifted")
    before_s3 = _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash)
    failures["s3:tap-budget"] = _failure(
        session,
        "treasury:s3:tap-budget",
        ACTORS["keeper"],
        vault,
        _calldata(
            "executeTreasuryTransfer((address,address,uint256,bytes32))", actions["s3"]["tuple"]
        ),
        _calldata(
            "TapBudgetExceeded(address,uint256,uint256)",
            weth,
            6 * WAD // 100,
            5 * WAD // 100,
        ),
        protocol_accounts,
        before_s3,
        lambda: _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash),
    )
    if (
        failures["s1:grace"]["transaction"]["blockTimestamp"]
        != clock["s1GraceFailure"]
        or executed_s1["record"]["blockTimestamp"] != clock["s1Execute"]
        or executed_s2["record"]["blockTimestamp"] != clock["s2Execute"]
        or failures["s3:tap-budget"]["transaction"]["blockTimestamp"]
        != clock["s3TapFailure"]
    ):
        raise LocalRehearsalError("tap execution clock drifted")
    if _queued_action(rpc, vault, actions["s3"]["hash"])["executed"]:
        raise LocalRehearsalError("failed tap spend marked S3 executed")
    session.mine_at(q3["expiresAt"] - 1)
    before_expiry = _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash)
    failures["s3:expire-too-early"] = _failure(
        session,
        "treasury:s3:expire-too-early",
        ACTORS["keeper"],
        vault,
        _calldata("expireQueuedAction(bytes32)", actions["s3"]["hash"]),
        _calldata("TooEarly()"),
        protocol_accounts,
        before_expiry,
        lambda: _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash),
    )
    if (
        q3["expiresAt"] != clock["s3ExpiresAt"]
        or failures["s3:expire-too-early"]["transaction"]["blockTimestamp"]
        != clock["s3ExpireTooEarly"]
    ):
        raise LocalRehearsalError("S3 expiry boundary clock drifted")
    expired = _send_next(
        session,
        "treasury:s3:expire",
        ACTORS["keeper"],
        vault,
        _calldata("expireQueuedAction(bytes32)", actions["s3"]["hash"]),
    )
    if (
        expired["record"]["blockTimestamp"] != clock["s3Expire"]
        or
        not _has_topic(
            expired["receipt"],
            "0x293612179386f9fb762a2a640284ea3c2b946fdac24300fbebdca42e97bc91ed",
            vault,
        )
        or not _queued_action(rpc, vault, actions["s3"]["hash"])["expired"]
    ):
        raise LocalRehearsalError("S3 expiration drifted")
    after_expiry = _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash)
    failures["s3:execute-expired"] = _failure(
        session,
        "treasury:s3:execute-expired",
        ACTORS["keeper"],
        vault,
        _calldata(
            "executeTreasuryTransfer((address,address,uint256,bytes32))", actions["s3"]["tuple"]
        ),
        _calldata("ActionExpired()"),
        protocol_accounts,
        after_expiry,
        lambda: _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash),
    )
    if (
        failures["s3:execute-expired"]["transaction"]["blockTimestamp"]
        != clock["s3ExecuteExpired"]
    ):
        raise LocalRehearsalError("S3 post-expiry clock drifted")
    if (
        _balance(rpc, weth, recipient) != 15 * WAD // 100
        or _balance(rpc, weth, executor) != 105 * WAD // 100
        or _uint(rpc, addresses["space"], "nextProposalId()") != space_next
    ):
        raise LocalRehearsalError("final bounded-treasury ledger drifted")
    return {
        "actions": {
            label: {
                key: str(value) if isinstance(value, int) else value
                for key, value in action.items()
                if key != "tuple"
            }
            for label, action in actions.items()
        },
        "failures": failures,
        "final": _treasury_semantics(rpc, addresses, weth, all_hashes, critical_base_hash),
        "firstSettlementAt": first_settlement,
        "proposals": proposal_records,
        "queueDelaySeconds": {"s1": 8, "s2": 9, "s3": 9},
        "queues": {
            label: _queued_action(rpc, vault, actions[label]["hash"])
            for label in ("s1", "s2", "s3")
        },
        "settlements": settlements,
        "spaceProposalCountUnchanged": True,
        "tapCoverageBoundary": {
            "deferredComposedLedgerStage": "S3-S6",
            "forkComposedExpectedAvailable": str(4 * WAD // 100),
            "localAgentPayments": "0",
            "localExpectedAvailable": str(5 * WAD // 100),
            "reason": "local S2 excludes the 0.01 WETH agent-payment spend present in the fork ledger",
        },
    }


def _ragequit_stage(
    session: Session,
    addresses: dict[str, str],
    weth: str,
    npm: str,
    treasury: dict[str, Any],
    clock: dict[str, int],
) -> dict[str, Any]:
    rpc = session.rpc
    vault = addresses["vault"]
    company = addresses["companyToken"]
    manager = addresses["manager"]
    executor = _address(rpc, vault, "TREASURY_EXECUTOR()")
    h2 = ACTORS["funder2"]
    grant_words = _words(_call(rpc, vault, "grants(uint256)", 0), 4)
    grant = {
        "amount": _uint_word(grant_words[3]),
        "duration": _uint_word(grant_words[2]),
        "start": _uint_word(grant_words[1]),
        "vestingWallet": _address_word(grant_words[0]),
    }
    if grant["start"] != GENESIS_TIMESTAMP or grant["amount"] != 10 * WAD:
        raise LocalRehearsalError("immutable vesting grant drifted")
    t_g = clock["ragequit"]
    if t_g != treasury["queues"]["s3"]["expiresAt"] + 3:
        raise LocalRehearsalError("ragequit expiry anchor drifted")
    if session.clock != t_g - 1:
        raise LocalRehearsalError("ragequit clock ledger drifted")
    elapsed = max(0, min(t_g - grant["start"], grant["duration"]))
    vested = grant["amount"] * elapsed // grant["duration"]
    unvested = grant["amount"] - vested
    effective = (
        _uint(rpc, company, "totalSupply()")
        - _balance(rpc, company, vault)
        + _uint(rpc, vault, "totalUnclaimedSold()")
        - _balance(rpc, company, executor)
        - unvested
    )
    h2_company_before = _balance(rpc, company, h2)
    if h2_company_before != 18 * WAD:
        raise LocalRehearsalError("H2 did not retain its complete hero allocation")
    amount = h2_company_before // 4
    executor_weth_before = _balance(rpc, weth, executor)
    executor_flp_before = _balance(rpc, manager, executor)
    expected_weth = executor_weth_before * amount // effective
    expected_flp = executor_flp_before * amount // effective
    h2_weth_before = _balance(rpc, weth, h2)
    h2_flp_before = _balance(rpc, manager, h2)
    ragequit_before = {
        "companySupply": str(_uint(rpc, company, "totalSupply()")),
        "effectiveSupply": str(effective),
        "executorCompany": str(_balance(rpc, company, executor)),
        "executorFlmShares": str(executor_flp_before),
        "executorWeth": str(executor_weth_before),
        "h2Company": str(h2_company_before),
        "h2FlmShares": str(h2_flp_before),
        "h2Weth": str(h2_weth_before),
        "totalUnclaimedSold": str(_uint(rpc, vault, "totalUnclaimedSold()")),
        "unvestedGrant": str(unvested),
        "vaultCompany": str(_balance(rpc, company, vault)),
    }
    ragequit = session.send(
        "ragequit:h2:quarter",
        h2,
        vault,
        _calldata("ragequit(uint256,address,address[])", amount, h2, "[]"),
    )
    event = _event(ragequit["receipt"], "Ragequit(address,address,uint256,uint256)", vault)
    if (
        ragequit["record"]["blockTimestamp"] != t_g
        or len(event["topics"]) != 3
        or _address_word(bytes.fromhex(event["topics"][1][2:])) != h2
        or _address_word(bytes.fromhex(event["topics"][2][2:])) != h2
        or [_uint_word(word) for word in _words(event["data"], 2)] != [amount, effective]
        or h2_company_before - _balance(rpc, company, h2) != amount
        or _balance(rpc, weth, h2) - h2_weth_before != expected_weth
        or _balance(rpc, manager, h2) - h2_flp_before != expected_flp
        or executor_weth_before - _balance(rpc, weth, executor) != expected_weth
        or executor_flp_before - _balance(rpc, manager, executor) != expected_flp
    ):
        raise LocalRehearsalError("H2 ragequit reconciliation drifted")
    if (
        unvested != 9_587_892_567_224_759_006
        or effective != 77_554_964_575_632_383_852
        or expected_weth != 60_924_533_018_026_619
        or expected_flp != 69_628_037_734_887_565
    ):
        raise LocalRehearsalError("sealed H2 ragequit arithmetic drifted")
    ragequit_after = {
        "companySupply": str(_uint(rpc, company, "totalSupply()")),
        "executorFlmShares": str(_balance(rpc, manager, executor)),
        "executorWeth": str(_balance(rpc, weth, executor)),
        "h2Company": str(_balance(rpc, company, h2)),
        "h2FlmShares": str(_balance(rpc, manager, h2)),
        "h2Weth": str(_balance(rpc, weth, h2)),
    }

    manager_supply = _uint(rpc, manager, "totalSupply()")
    managed = _managed_base(rpc, manager, npm, company, weth)
    company_out = managed["company"] * expected_flp // manager_supply
    weth_out = managed["weth"] * expected_flp // manager_supply
    company_before_redeem = _balance(rpc, company, h2)
    weth_before_redeem = _balance(rpc, weth, h2)
    spot_token_before = _position_id(rpc, addresses["spotAdapter"], company, weth)
    redeem_before = {
        "h2Company": str(company_before_redeem),
        "h2FlmShares": str(_balance(rpc, manager, h2)),
        "h2Weth": str(weth_before_redeem),
        "managedCompany": str(managed["company"]),
        "managedWeth": str(managed["weth"]),
        "managerSupply": str(manager_supply),
        "spotPosition": _npm_position(rpc, npm, spot_token_before),
    }
    redeemed = session.send(
        "ragequit:h2:redeem-flp",
        h2,
        manager,
        _calldata("redeem(uint256,address,bool)", expected_flp, h2, "false"),
    )
    redeem_event = _event(
        redeemed["receipt"],
        "SharesRedeemed(address,address,uint256,uint256,uint256)",
        manager,
    )
    if (
        redeemed["record"]["blockTimestamp"] != clock["flmRedeem"]
        or len(redeem_event["topics"]) != 3
        or _address_word(bytes.fromhex(redeem_event["topics"][1][2:])) != h2
        or _address_word(bytes.fromhex(redeem_event["topics"][2][2:])) != h2
        or [_uint_word(word) for word in _words(redeem_event["data"], 3)]
        != [expected_flp, company_out, weth_out]
        or _balance(rpc, manager, h2) != 0
        or _balance(rpc, company, h2) - company_before_redeem != company_out
        or _balance(rpc, weth, h2) - weth_before_redeem != weth_out
    ):
        raise LocalRehearsalError("H2 FLM redemption reconciliation drifted")
    if (
        _balance(rpc, company, addresses["spotAdapter"]) != 0
        or _balance(rpc, weth, addresses["spotAdapter"]) != 0
        or _balance(rpc, company, addresses["conditionalAdapter"]) != 0
        or _balance(rpc, weth, addresses["conditionalAdapter"]) != 0
        or _bool(rpc, manager, "inConditionalMode()")
    ):
        raise LocalRehearsalError("adapter residue remained after FLM redemption")
    active_token_id = _position_id(rpc, addresses["spotAdapter"], company, weth)
    active_position = _npm_position(rpc, npm, active_token_id)
    nonempty_positions = []
    for token_id in range(1, _uint(rpc, npm, "nextTokenId()")):
        position = _npm_position(rpc, npm, token_id)
        if position["token0"] != ZERO_ADDRESS or position["liquidity"] != 0:
            nonempty_positions.append(position)
    if (
        active_token_id == 0
        or len(nonempty_positions) != 1
        or nonempty_positions[0]["tokenId"] != str(active_token_id)
        or active_position["liquidity"] != _uint(rpc, manager, "spotLiquidity()")
        or _position_id(rpc, addresses["conditionalAdapter"], company, weth) != 0
    ):
        raise LocalRehearsalError("FLM did not restock one canonical spot position")
    redeem_after = {
        "h2Company": str(_balance(rpc, company, h2)),
        "h2FlmShares": str(_balance(rpc, manager, h2)),
        "h2Weth": str(_balance(rpc, weth, h2)),
        "managed": {
            key: str(value)
            for key, value in _managed_base(rpc, manager, npm, company, weth).items()
        },
        "managerSupply": str(_uint(rpc, manager, "totalSupply()")),
        "spotPosition": active_position,
    }
    return {
        "at": t_g,
        "effectiveSupply": str(effective),
        "flmRedeem": {
            "after": redeem_after,
            "before": redeem_before,
            "companyOut": str(company_out),
            "managedBefore": {key: str(value) for key, value in managed.items()},
            "managerSupplyBefore": str(manager_supply),
            "shares": str(expected_flp),
            "spotPositionAfter": active_position,
            "wethOut": str(weth_out),
        },
        "ragequit": {
            "after": ragequit_after,
            "amount": str(amount),
            "before": ragequit_before,
            "flmSharesOut": str(expected_flp),
            "wethOut": str(expected_weth),
        },
        "unvestedGrant": str(unvested),
    }


def _scenario_ad(
    rpc: runner.JsonRpc,
    deployment: list[dict[str, Any]],
    deployment_start: int,
    deployment_end: int,
) -> dict[str, Any]:
    session = Session(rpc)
    hero, twin, dependencies = _stack_pair(rpc, deployment_start, deployment_end)
    h = hero["addresses"]
    t = twin["addresses"]
    weth = dependencies["weth"]
    npm = dependencies["positionManager"]
    clock = _clock(GENESIS_TIMESTAMP)
    fixture_install = _install_hero_pool(session, hero, dependencies)
    fixture_transactions = list(session.transactions)
    session.transactions.clear()
    if rpc.request("eth_getCode", [t["spotPool"], "latest"]) != "0x":
        raise LocalRehearsalError("failed twin pool was provisioned")

    hero_buys = []
    hero_sold = 0
    for ordinal, (actor_name, amount) in enumerate(
        (
            ("funder1", 8 * WAD),
            ("funder1", 8 * WAD),
            ("funder1", 8 * WAD),
            ("funder2", 18 * WAD),
            ("funder3", 12 * WAD),
            ("funder4", 6 * WAD),
        ),
        1,
    ):
        hero_buys.append(
            _buy(
                session,
                h["vault"],
                weth,
                actor_name,
                amount,
                hero_sold,
                "hero:sale:%d" % ordinal,
            )
        )
        hero_sold += amount

    twin_buys = []
    twin_sold = 0
    for ordinal, (actor_name, amount) in enumerate((("lp1", 2 * WAD), ("lp2", 3 * WAD)), 1):
        twin_buys.append(
            _buy(
                session,
                t["vault"],
                weth,
                actor_name,
                amount,
                twin_sold,
                "twin:sale:%d" % ordinal,
            )
        )
        twin_sold += amount

    hero_raised = _uint(rpc, h["vault"], "totalRaised()")
    twin_raised = _uint(rpc, t["vault"], "totalRaised()")
    if (
        hero_sold != 60 * WAD
        or hero_raised != 24 * WAD // 10
        or sum(int(item["cost"]) for item in hero_buys[:3])
        != _uint(rpc, h["vault"], "reserveAt(uint256)", 24 * WAD)
        or twin_sold != 5 * WAD
        or twin_raised != 625 * WAD // 10_000
    ):
        raise LocalRehearsalError("hero/twin reserve paths drifted")

    sale_end = _uint(rpc, h["vault"], "SALE_END()")
    if (
        sale_end != GENESIS_TIMESTAMP + 24 * 60 * 60
        or _uint(rpc, t["vault"], "SALE_END()") != sale_end
    ):
        raise LocalRehearsalError("fixed genesis timestamp did not bind both sales")
    cap_snapshot = _sale_state(rpc, h["vault"], weth)
    sale_cap_exceeded = _failure(
        session,
        "hero:sale:cap-exceeded",
        ACTORS["funder1"],
        h["vault"],
        _calldata(
            "buy(uint256,uint256,uint256)", 41 * WAD, UINT256_MAX, sale_end - 1
        ),
        _calldata("SaleCapExceeded()"),
        (h["vault"], h["companyToken"], h["manager"], weth),
        cap_snapshot,
        lambda: _sale_state(rpc, h["vault"], weth),
    )
    session.mine_at(sale_end - 1)
    sale_snapshot = _sale_state(rpc, h["vault"], weth)
    sale_closed = _failure(
        session,
        "hero:sale:closed",
        ACTORS["funder1"],
        h["vault"],
        _calldata("buy(uint256,uint256,uint256)", WAD, WAD, sale_end + 100),
        _calldata("SaleClosed()"),
        (h["vault"], h["companyToken"], h["manager"], weth),
        sale_snapshot,
        lambda: _sale_state(rpc, h["vault"], weth),
    )
    if session.clock != sale_end:
        raise LocalRehearsalError("SaleClosed probe did not land at the exact boundary")

    session.send("hero:seal", ACTORS["keeper"], h["vault"], _calldata("seal()"))
    finalized = session.send(
        "hero:finalize", ACTORS["keeper"], h["vault"], _calldata("finalize()")
    )
    final_values = [
        _uint_word(word)
        for word in _words(
            _event(
                finalized["receipt"],
                "Finalized(uint256,uint256,uint256,uint256,uint256)",
                h["vault"],
            )["data"],
            5,
        )
    ]
    bootstrap_company, bootstrap_weth, bootstrap_shares = final_values[2:]
    executor = _address(rpc, h["vault"], "TREASURY_EXECUTOR()")
    terminal_price = _uint(rpc, h["vault"], "terminalPrice()")
    expected_company = _ceil_div(
        bootstrap_weth * WAD, terminal_price
    )
    expected_sqrt_price = _uint(
        rpc, h["receipt"], "sqrtPriceX96(uint256)", terminal_price
    )
    expected_cardinality = _uint(rpc, h["receipt"], "OBSERVATION_CARDINALITY()")
    claim_reserve = _balance(rpc, h["companyToken"], h["vault"])
    total_unclaimed = _uint(rpc, h["vault"], "totalUnclaimedSold()")
    grant_amount = _uint_word(_words(_call(rpc, h["vault"], "grants(uint256)", 0), 4)[3])
    spot_nft = _position_id(rpc, h["spotAdapter"], h["companyToken"], weth)
    spot_position = _npm_position(rpc, npm, spot_nft)
    if (
        final_values[:2] != [hero_sold, hero_raised]
        or bootstrap_weth != hero_raised // 2
        or bootstrap_company != expected_company
        or _uint(rpc, h["vault"], "phase()") != 2
        or _balance(rpc, weth, executor) != hero_raised - bootstrap_weth
        or _balance(rpc, h["manager"], executor) != bootstrap_shares
        or _uint(rpc, h["manager"], "totalSupply()") != bootstrap_shares
        or _uint(rpc, h["manager"], "spotLiquidity()") != bootstrap_shares
        or not _bool(rpc, h["manager"], "initializedFromBootstrap()")
        or spot_nft == 0
        or spot_position["liquidity"] != bootstrap_shares
        or _address(rpc, npm, "lastRecipient()") != h["spotAdapter"]
        or _uint(rpc, h["spotPool"], "sqrtPriceX96()") != expected_sqrt_price
        or _uint(rpc, h["spotPool"], "observationCardinalityNext()")
        != expected_cardinality
        or claim_reserve != hero_sold
        or total_unclaimed != hero_sold
        or claim_reserve - total_unclaimed != 0
        or _uint(rpc, h["companyToken"], "totalSupply()")
        != hero_sold + grant_amount + bootstrap_company
        or _balance(rpc, h["companyToken"], npm) != bootstrap_company
        or _balance(rpc, weth, npm) != bootstrap_weth
        or _uint(
            rpc,
            h["companyToken"],
            "allowance(address,address)",
            h["vault"],
            h["manager"],
        )
        != 0
        or _uint(rpc, weth, "allowance(address,address)", h["vault"], h["manager"])
        != 0
        or _balance(rpc, weth, h["vault"]) != 0
        or _balance(rpc, h["manager"], h["vault"]) != 0
    ):
        raise LocalRehearsalError("hero atomic bootstrap reconciliation failed")
    hero["runtimeHashAfterProvision"] = _runtime_hash(rpc, h["spotPool"])

    claims = {
        actor_name: str(_claim(session, h["vault"], h["companyToken"], actor_name))
        for actor_name in ("funder1", "funder2", "funder3", "funder4")
    }
    if claims != {
        "funder1": str(24 * WAD),
        "funder2": str(18 * WAD),
        "funder3": str(12 * WAD),
        "funder4": str(6 * WAD),
    }:
        raise LocalRehearsalError("hero allocation claims drifted")

    supply_before_deposits = _uint(rpc, h["manager"], "totalSupply()")
    deposits = [
        _spot_deposit(
            session,
            h["manager"],
            npm,
            h["companyToken"],
            weth,
            ACTORS["funder1"],
            actor_name,
            2 * WAD // 100,
        )
        for actor_name in ("lp1", "lp2")
    ]
    redemption = _spot_redeem(
        session, h["manager"], npm, h["companyToken"], weth, "lp1"
    )
    active_spot_nft = _position_id(rpc, h["spotAdapter"], h["companyToken"], weth)
    active_spot_position = _npm_position(rpc, npm, active_spot_nft)
    if (
        _bool(rpc, h["manager"], "inConditionalMode()")
        or active_spot_nft == 0
        or active_spot_position["liquidity"] != _uint(rpc, h["manager"], "spotLiquidity()")
        or _balance(rpc, h["manager"], ACTORS["lp1"])
        != int(redemption["remainingShares"])
        or _balance(rpc, h["manager"], ACTORS["lp1"]) == 0
        or _balance(rpc, h["manager"], ACTORS["lp2"]) == 0
        or _uint(rpc, h["manager"], "totalSupply()")
        != supply_before_deposits
        + sum(int(item["shares"]) for item in deposits)
        - int(redemption["shares"])
    ):
        raise LocalRehearsalError("spot-only manager custody drifted")

    twin_snapshot = _sale_state(rpc, t["vault"], weth)
    twin_seal_failure = _failure(
        session,
        "twin:seal:below-minimum",
        ACTORS["keeper"],
        t["vault"],
        _calldata("seal()"),
        _calldata("BootstrapNotReady()"),
        (t["vault"], t["companyToken"], t["manager"], weth),
        twin_snapshot,
        lambda: _sale_state(rpc, t["vault"], weth),
    )
    session.send("twin:fail", ACTORS["keeper"], t["vault"], _calldata("fail()"))
    refunds = {actor: str(_refund(session, t["vault"], weth, actor)) for actor in ("lp1", "lp2")}
    failed_snapshot = _sale_state(rpc, t["vault"], weth)
    twin_accounts = (t["vault"], t["companyToken"], t["manager"], weth)
    twin_double_refund = _failure(
        session,
        "twin:refund:double",
        ACTORS["keeper"],
        t["vault"],
        _calldata("refund(address)", ACTORS["lp1"]),
        _calldata("NothingToClaim()"),
        twin_accounts,
        failed_snapshot,
        lambda: _sale_state(rpc, t["vault"], weth),
    )
    twin_claim = _failure(
        session,
        "twin:claim:invalid-phase",
        ACTORS["keeper"],
        t["vault"],
        _calldata("claim(address)", ACTORS["lp1"]),
        _calldata("InvalidPhase()"),
        twin_accounts,
        failed_snapshot,
        lambda: _sale_state(rpc, t["vault"], weth),
    )
    twin_finalize = _failure(
        session,
        "twin:finalize:invalid-phase",
        ACTORS["keeper"],
        t["vault"],
        _calldata("finalize()"),
        _calldata("InvalidPhase()"),
        twin_accounts,
        failed_snapshot,
        lambda: _sale_state(rpc, t["vault"], weth),
    )
    if (
        refunds != {"lp1": str(22 * WAD // 1_000), "lp2": str(405 * WAD // 10_000)}
        or _uint(rpc, t["vault"], "phase()") != 3
        or _balance(rpc, weth, t["vault"]) != 0
        or _uint(rpc, t["vault"], "purchased(address)", ACTORS["lp1"]) != 0
        or _uint(rpc, t["vault"], "purchased(address)", ACTORS["lp2"]) != 0
        or _uint(rpc, t["vault"], "contribution(address)", ACTORS["lp1"]) != 0
        or _uint(rpc, t["vault"], "contribution(address)", ACTORS["lp2"]) != 0
        or rpc.request("eth_getCode", [t["spotPool"], "latest"]) != "0x"
    ):
        raise LocalRehearsalError("failed twin refund reconciliation drifted")

    site = _site_stage(session, h, weth, clock)
    treasury = _treasury_stage(session, h, weth, clock)
    ragequit = _ragequit_stage(session, h, weth, npm, treasury, clock)
    economic_transactions = session.transactions
    all_transactions = deployment + fixture_transactions + economic_transactions
    return {
        "clock": {
            "chainId": CHAIN_ID,
            "genesisTimestamp": GENESIS_TIMESTAMP,
            "ledger": clock,
            "now": session.clock,
            "saleEnd": sale_end,
        },
        "deployment": {
            "dependencies": dependencies,
            "hero": hero,
            "transactions": deployment,
            "twin": twin,
        },
        "failedTwin": {
            "buys": twin_buys,
            "claimFailure": twin_claim,
            "doubleRefundFailure": twin_double_refund,
            "finalState": failed_snapshot,
            "finalizeFailure": twin_finalize,
            "refunds": refunds,
            "sealFailure": twin_seal_failure,
        },
        "fixtureProvisioning": {
            **fixture_install,
            "boundary": "local-only same-run mock runtime installed before economics",
            "forkEquivalenceClaimed": False,
            "kind": "localMockPoolInstall",
            "realAmmEquivalenceClaimed": False,
            "rpcMethod": "anvil_setCode",
            "transactions": fixture_transactions,
            "twinInstalled": False,
        },
        "hero": {
            "bootstrap": {
                "claimReserve": str(claim_reserve),
                "company": str(bootstrap_company),
                "flmShares": str(bootstrap_shares),
                "position": spot_position,
                "pool": {
                    "observationCardinalityNext": expected_cardinality,
                    "sqrtPriceX96": str(expected_sqrt_price),
                    "terminalPrice": str(terminal_price),
                },
                "totalUnclaimedSold": str(total_unclaimed),
                "unusedSeedBurn": "0",
                "weth": str(bootstrap_weth),
            },
            "buys": hero_buys,
            "claims": claims,
            "saleCapExceededFailure": sale_cap_exceeded,
            "saleClosedFailure": sale_closed,
        },
        "resources": {
            "blocks": all_transactions[-1]["blockNumber"] - all_transactions[0]["blockNumber"] + 1,
            "deploymentTransactions": len(deployment),
            "economicTransactions": len(economic_transactions),
            "fixtureTransactions": len(fixture_transactions),
            "gasUsed": sum(item["gasUsed"] for item in all_transactions),
            "transactions": len(all_transactions),
        },
        "ragequit": ragequit,
        "siteRelease": site,
        "spotLiquidity": {
            "activePosition": active_spot_position,
            "deposits": deposits,
            "redemption": redemption,
        },
        "stack": {"executor": executor, "hero": h, "twin": t},
        "treasury": treasury,
        "transactions": economic_transactions,
    }


def _run_once(port: int) -> tuple[dict[str, Any], dict[str, Any]]:
    _require_unused_port(port)
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
            "--chain-id",
            str(CHAIN_ID),
            "--timestamp",
            str(GENESIS_TIMESTAMP),
            "--auto-impersonate",
            "--gas-limit",
            "100000000",
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
        observed_chain_id = None
        for _ in range(200):
            if process.poll() is not None:
                raise LocalRehearsalError("fresh local Anvil exited before accepting RPC")
            try:
                observed_chain_id = rpc.chain_id()
                break
            except runner.RunnerError:
                time.sleep(0.05)
        else:
            raise LocalRehearsalError("fresh local Anvil did not start")
        _chain_id(observed_chain_id)
        if process.poll() is not None:
            raise LocalRehearsalError("spawned Anvil exited after RPC became reachable")
        genesis = rpc.block("latest")
        if (
            int(genesis["number"], 16) != 0
            or int(genesis["timestamp"], 16) != GENESIS_TIMESTAMP
        ):
            raise LocalRehearsalError("local Anvil genesis identity drifted")
        preconditions = {}
        for name, actor in ACTORS.items():
            nonce = int(rpc.request("eth_getTransactionCount", [actor, "latest"]), 16)
            code = rpc.request("eth_getCode", [actor, "latest"])
            if nonce != 0 or code != "0x":
                raise LocalRehearsalError("fixed actor precondition failed: " + name)
            preconditions[name] = {"code": code, "nonce": nonce}
            rpc.request("anvil_setBalance", [actor, hex(1_000 * WAD)])
        rpc.request("anvil_setBlockTimestampInterval", [1])
        env = dict(os.environ, REHEARSAL_R0_LOCAL_SENDER=ACTORS["deployer"])
        _run(
            (
                "forge",
                "script",
                "script/RehearsalR0Local.s.sol:RehearsalR0Local",
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
        deployment = _block_transactions(rpc, 1, deployment_end)
        if len(deployment) != 19:
            raise LocalRehearsalError("local deployment transaction count drifted")
        economic = _scenario_ad(rpc, deployment, 1, deployment_end)
        economic["actorPreconditions"] = preconditions
        economic["fixtureArtifact"] = _fixture_evidence()
        return economic, {
            "port": port,
            "processId": process.pid,
            "rpcUrl": rpc_url,
            "wallDurationMs": round((time.monotonic() - started) * 1000),
        }
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)


def run(port: int) -> dict[str, Any]:
    for command in ("anvil", "cast", "forge"):
        if shutil.which(command) is None:
            raise LocalRehearsalError(command + " is required")
    if port == 65_535:
        raise LocalRehearsalError("dual run requires port + 1")
    first, _first_observation = _run_once(port)
    second, _second_observation = _run_once(port + 1)
    first_raw = _canonical(first)
    second_raw = _canonical(second)
    if first_raw != second_raw:
        raise LocalRehearsalError(
            "local economic projections diverged: %s != %s"
            % (hashlib.sha256(first_raw).hexdigest(), hashlib.sha256(second_raw).hexdigest())
        )
    digest = "0x" + hashlib.sha256(first_raw).hexdigest()
    evidence = {
        "comparison": {
            "economicProjectionSha256": digest,
            "excludedFieldsNotSerialized": EXCLUDED_FIELDS,
            "identical": True,
        },
        "economicProjection": first,
        "kind": "fao.rehearsal.r0-s2-evidence",
        "observations": [
            {"freshAnvil": True, "ordinal": 1},
            {"freshAnvil": True, "ordinal": 2},
        ],
        "publicBroadcasts": 0,
        "v": "1",
    }
    _validate_evidence(evidence)
    return evidence


def _validate_evidence(evidence: dict[str, Any]) -> None:
    try:
        projection = evidence["economicProjection"]
        transactions = projection["transactions"]
        failed_labels = {
            item["label"] for item in transactions if item.get("status", 1) == 0
        }
        expected_failures = {
            "hero:sale:cap-exceeded",
            "hero:sale:closed",
            "twin:seal:below-minimum",
            "twin:refund:double",
            "twin:claim:invalid-phase",
            "twin:finalize:invalid-phase",
            "site:timeout:early",
            "treasury:s1:double-queue",
            "treasury:medium:timeout-route-rejected",
            "treasury:over-cap:rejected",
            "treasury:param:timeout-route-rejected",
            "treasury:critical:timeout-route-rejected",
            "treasury:medium:expire-unqueued",
            "treasury:s1:grace",
            "treasury:s3:tap-budget",
            "treasury:s3:expire-too-early",
            "treasury:s3:execute-expired",
        }
        hero = projection["hero"]
        site = projection["siteRelease"]
        treasury = projection["treasury"]
        ragequit = projection["ragequit"]
        fixture = projection["fixtureArtifact"]
        if (
            evidence["kind"] != "fao.rehearsal.r0-s2-evidence"
            or evidence["v"] != "1"
            or evidence["publicBroadcasts"] != 0
            or evidence["comparison"]["identical"] is not True
            or evidence["comparison"]["excludedFieldsNotSerialized"] != EXCLUDED_FIELDS
            or len(evidence["observations"]) != 2
            or projection["clock"]["chainId"] != CHAIN_ID
            or projection["clock"]["genesisTimestamp"] != GENESIS_TIMESTAMP
            or projection["resources"]["transactions"] != 119
            or projection["resources"]["economicTransactions"] != 98
            or projection["resources"]["fixtureTransactions"] != 2
            or len(transactions) != 98
            or len(projection["deployment"]["transactions"]) != 19
            or len(projection["fixtureProvisioning"]["transactions"]) != 2
            or failed_labels != expected_failures
            or sum(int(item["amount"]) for item in hero["buys"]) != 60 * WAD
            or sum(int(item["cost"]) for item in hero["buys"]) != 24 * WAD // 10
            or hero["bootstrap"]["company"] != "17142857142857142858"
            or hero["bootstrap"]["weth"] != str(12 * WAD // 10)
            or hero["bootstrap"]["claimReserve"] != str(60 * WAD)
            or hero["bootstrap"]["unusedSeedBurn"] != "0"
            or hero["bootstrap"]["pool"]["observationCardinalityNext"] != 120
            or projection["failedTwin"]["finalState"]["phase"] != 3
            or projection["failedTwin"]["finalState"]["weth"] != "0"
            or projection["fixtureProvisioning"]["installedRuntimeHash"]
            != projection["fixtureProvisioning"]["templateRuntimeHash"]
            or projection["fixtureProvisioning"]["twinInstalled"] is not False
            or projection["fixtureProvisioning"]["kind"] != "localMockPoolInstall"
            or projection["fixtureProvisioning"]["realAmmEquivalenceClaimed"] is not False
            or projection["fixtureProvisioning"]["forkEquivalenceClaimed"] is not False
            or fixture["bytes"] != 10_240
            or fixture["keccak256"] != FIXTURE_KECCAK
            or fixture["sha256"] != "0x" + FIXTURE_SHA256
            or fixture["provenance"]["boundary"]["publicFetches"] != 0
            or fixture["provenance"]["boundary"]["publicDeployments"] != 0
            or site["arbitrationId"] != str(int(SITE_ARB_HASH, 16))
            or site["final"]["release"]
            != {"digest": FIXTURE_KECCAK, "nonce": 1, "uri": SITE_URI}
            or site["zeroVoteEvents"] is not True
            or any(site["final"]["votes"]["votePower"].values())
            or treasury["final"]["tap"]
            != {"spent": 15 * WAD // 100, "windowStart": 1_800_694_817}
            or treasury["final"]["executorWeth"] != str(105 * WAD // 100)
            or treasury["final"]["recipientWeth"] != str(15 * WAD // 100)
            or treasury["queueDelaySeconds"] != {"s1": 8, "s2": 9, "s3": 9}
            or treasury["tapCoverageBoundary"]
            != {
                "deferredComposedLedgerStage": "S3-S6",
                "forkComposedExpectedAvailable": str(4 * WAD // 100),
                "localAgentPayments": "0",
                "localExpectedAvailable": str(5 * WAD // 100),
                "reason": "local S2 excludes the 0.01 WETH agent-payment spend present in the fork ledger",
            }
            or treasury["queues"]["s1"]["executed"] is not True
            or treasury["queues"]["s2"]["executed"] is not True
            or treasury["queues"]["s3"]["expired"] is not True
            or treasury["failures"]["s3:tap-budget"]["returnValue"]
            != _calldata(
                "TapBudgetExceeded(address,uint256,uint256)",
                projection["deployment"]["dependencies"]["weth"],
                6 * WAD // 100,
                5 * WAD // 100,
            )
            or ragequit["effectiveSupply"] != "77554964575632383852"
            or ragequit["unvestedGrant"] != "9587892567224759006"
            or ragequit["ragequit"]["amount"] != str(45 * WAD // 10)
            or ragequit["ragequit"]["wethOut"] != "60924533018026619"
            or ragequit["ragequit"]["flmSharesOut"] != "69628037734887565"
        ):
            raise LocalRehearsalError("S2 evidence semantic invariant failed")
        projection_raw = _canonical(projection)
        if evidence["comparison"]["economicProjectionSha256"] != (
            "0x" + hashlib.sha256(projection_raw).hexdigest()
        ):
            raise LocalRehearsalError("S2 economic projection digest drifted")
    except (KeyError, TypeError, AttributeError) as error:
        raise LocalRehearsalError("S2 evidence shape is malformed") from error


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=19_657)
    parser.add_argument("--output", type=Path, default=Path("/tmp/fao-rehearsal-r0-s2-local.json"))
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    evidence = run(args.port)
    raw = _canonical(evidence)
    if args.check:
        if not args.output.is_file() or args.output.read_bytes() != raw:
            raise LocalRehearsalError("committed S2 evidence is missing or stale")
        print("verified %s" % args.output)
    else:
        args.output.write_bytes(raw)
        print("wrote %s" % args.output)
    print("economic projection: %s" % evidence["comparison"]["economicProjectionSha256"])
    print("public broadcasts: 0")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, ValueError, json.JSONDecodeError, runner.RunnerError) as error:
        print("error: " + str(error), file=os.sys.stderr)
        raise SystemExit(1)
