"""Explicit post-build Anvil race and capped 10-instance pre-broadcast drill."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .indexer import JsonRpc


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = Path(__file__).with_name("ten-instance-prebroadcast-v1.json")
START_NEXT = "0xd2b8360a"


class DrillError(ValueError):
    pass


def _run(command: Sequence[str]) -> str:
    result = subprocess.run(command, cwd=ROOT, text=True, capture_output=True)
    if result.returncode:
        raise DrillError("command failed: %s\n%s" % (" ".join(command), result.stderr[-1000:]))
    return result.stdout.strip()


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"


def _deploy(contract: str, rpc_url: str, sender: str, arguments: Sequence[str]) -> str:
    output = _run(
        [
            "forge",
            "create",
            contract,
            "--rpc-url",
            rpc_url,
            "--unlocked",
            "--from",
            sender,
            "--broadcast",
            "--constructor-args",
            *arguments,
        ]
    )
    match = re.search(r"Deployed to:\s*(0x[0-9a-fA-F]{40})", output)
    if match is None:
        raise DrillError("forge create did not report a deployment")
    return match.group(1).lower()


def _send(rpc_url: str, sender: str, target: str, signature: str, *arguments: str) -> None:
    _run(
        [
            "cast",
            "send",
            "--rpc-url",
            rpc_url,
            "--unlocked",
            "--from",
            sender,
            target,
            signature,
            *arguments,
        ]
    )


def _prepare(rpc_url: str, accounts: List[str], instances: int) -> List[str]:
    token = _deploy(
        "src/FAOSiteToken.sol:FAOSiteToken", rpc_url, accounts[0], [accounts[1], "1000"]
    )
    _send(rpc_url, accounts[1], token, "transfer(address,uint256)", accounts[2], "100")
    arbitrations = []
    for _ in range(instances):
        arbitration = _deploy(
            "src/FutarchyArbitration.sol:FutarchyArbitration",
            rpc_url,
            accounts[0],
            [token, "2", "3600"],
        )
        arbitrations.append(arbitration)
        _send(rpc_url, accounts[1], token, "approve(address,uint256)", arbitration, "3")
        _send(rpc_url, accounts[2], token, "approve(address,uint256)", arbitration, "1")
        _send(rpc_url, accounts[0], arbitration, "createProposal(uint256)", "1")
        _send(rpc_url, accounts[1], arbitration, "placeYesBond(uint256,uint256)", "1", "1")
        _send(rpc_url, accounts[2], arbitration, "placeNoBond(uint256)", "1")
        _send(rpc_url, accounts[1], arbitration, "placeYesBond(uint256,uint256)", "1", "2")
    return arbitrations


def _action_digest(chain_id: int, block_hash: str, arbitration: str) -> str:
    value = {
        "chainId": chain_id,
        "blockHash": block_hash,
        "instance": arbitration,
        "kind": "startNextEvaluation",
        "to": arbitration,
        "data": START_NEXT,
        "value": "0x0",
        "proposalId": "1",
    }
    return "0x" + hashlib.sha256(_canonical(value)).hexdigest()


def _wait_receipt(rpc: JsonRpc, tx_hash: str) -> Dict[str, Any]:
    for _ in range(100):
        receipt = rpc._request("eth_getTransactionReceipt", [tx_hash])
        if isinstance(receipt, dict):
            return receipt
        time.sleep(0.05)
    raise DrillError("transaction receipt did not arrive")


def _race(rpc: JsonRpc, rpc_url: str, accounts: List[str], arbitration: str) -> Dict[str, Any]:
    transaction = {"to": arbitration, "data": START_NEXT}
    for keeper in accounts[3:5]:
        rpc.call(dict(transaction, **{"from": keeper}), "latest")
    rpc._request("anvil_setAutomine", [False])
    hashes = []
    for keeper in accounts[3:5]:
        hashes.append(
            _run(
                [
                    "cast",
                    "send",
                    "--async",
                    "--gas-limit",
                    "100000",
                    "--rpc-url",
                    rpc_url,
                    "--unlocked",
                    "--from",
                    keeper,
                    arbitration,
                    "startNextEvaluation()",
                ]
            )
        )
    rpc._request("evm_mine", [])
    receipts = [_wait_receipt(rpc, tx_hash) for tx_hash in hashes]
    statuses = sorted(int(receipt["status"], 16) for receipt in receipts)
    active = int(rpc.call({"to": arbitration, "data": "0x833d9770"}), 16)
    if statuses != [0, 1] or active != 1 or receipts[0]["blockHash"] != receipts[1]["blockHash"]:
        raise DrillError(
            "race mismatch: statuses=%r active=%r blocks=%r"
            % (statuses, active, [receipt["blockHash"] for receipt in receipts])
        )
    return {
        "v": 1,
        "kind": "fao.windtunnel.anvil-race-evidence",
        "chainId": rpc.chain_id(),
        "blockHash": receipts[0]["blockHash"].lower(),
        "arbitration": arbitration,
        "actionSha256": _action_digest(rpc.chain_id(), receipts[0]["blockHash"], arbitration),
        "attempts": [
            {
                "keeper": accounts[index + 3],
                "transactionHash": hashes[index].lower(),
                "status": receipts[index]["status"],
                "classification": "landed"
                if int(receipts[index]["status"], 16) == 1
                else "benign-race",
            }
            for index in range(2)
        ],
        "postcondition": {"activeEvaluationProposalId": "1"},
    }


def _prebroadcast(
    rpc: JsonRpc, accounts: List[str], arbitrations: List[str], fixture: Dict[str, Any]
) -> Dict[str, Any]:
    # Anvil's finalized tag intentionally lags; this pre-broadcast fixture pins the mined head.
    block = rpc.block("latest")
    instances = []
    for ordinal, arbitration in enumerate(arbitrations):
        simulations = []
        for keeper in accounts[3:5]:
            result = rpc.call({"from": keeper, "to": arbitration, "data": START_NEXT}, block["number"])
            simulations.append({"keeper": keeper, "outcome": "ok", "returnData": result})
        instances.append(
            {
                "ordinal": ordinal,
                "arbitration": arbitration,
                "actionSha256": _action_digest(rpc.chain_id(), block["hash"], arbitration),
                "action": {
                    "kind": "startNextEvaluation",
                    "to": arbitration,
                    "data": START_NEXT,
                    "value": "0x0",
                    "proposalId": "1",
                },
                "simulations": simulations,
            }
        )
    return {
        "v": 1,
        "kind": "fao.windtunnel.prebroadcast-evidence",
        "broadcast": False,
        "runId": fixture["runId"],
        "chainId": rpc.chain_id(),
        "fixtureSha256": "0x" + hashlib.sha256(_canonical(fixture)).hexdigest(),
        "block": {"number": block["number"], "hash": block["hash"].lower()},
        "instances": instances,
        "summary": {
            "instances": len(instances),
            "actions": len(instances),
            "simulations": len(instances) * 2,
            "keeperBroadcasts": 0,
        },
    }


def run(mode: str, port: int) -> Dict[str, Any]:
    for command in ("anvil", "cast", "forge"):
        if shutil.which(command) is None:
            raise DrillError("%s is required" % command)
    fixture = json.loads(FIXTURE_PATH.read_text(encoding="utf-8"))
    instances = 1 if mode == "race" else int(fixture["instanceCount"])
    if instances < 1 or instances > 10:
        raise DrillError("drill instance cap is 10")
    rpc_url = "http://127.0.0.1:%d" % port
    process = subprocess.Popen(
        [
            "anvil",
            "--quiet",
            "--order",
            "fifo",
            "--port",
            str(port),
            "--accounts",
            "8",
            "--balance",
            "1000",
            "--timestamp",
            "1",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    try:
        rpc = JsonRpc(rpc_url)
        for _ in range(100):
            try:
                accounts = [value.lower() for value in rpc._request("eth_accounts", [])]
                break
            except Exception:
                time.sleep(0.05)
        else:
            raise DrillError("Anvil did not start")
        rpc._request("anvil_setBlockTimestampInterval", [1])
        arbitrations = _prepare(rpc_url, accounts, instances)
        return (
            _race(rpc, rpc_url, accounts, arbitrations[0])
            if mode == "race"
            else _prebroadcast(rpc, accounts, arbitrations, fixture)
        )
    finally:
        process.terminate()
        process.wait(timeout=5)


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=("race", "prebroadcast-10"))
    parser.add_argument("--port", type=int, default=18545)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    evidence = run(args.mode, args.port)
    raw = _canonical(evidence)
    if args.output:
        args.output.write_bytes(raw)
    else:
        print(raw.decode("utf-8"), end="")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (DrillError, OSError, ValueError, json.JSONDecodeError) as exc:
        print("error: %s" % exc)
        raise SystemExit(1)
