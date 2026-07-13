"""Explicit post-build Anvil race and capped 10-instance pre-broadcast drill."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence

from .indexer import Indexer, JsonRpc


ROOT = Path(__file__).resolve().parents[2]
FIXTURE_PATH = Path(__file__).with_name("ten-instance-prebroadcast-v1.json")
START_NEXT = "0xd2b8360a"


class DrillError(ValueError):
    pass


def _run(command: Sequence[str], env: Optional[Dict[str, str]] = None) -> str:
    result = subprocess.run(command, cwd=ROOT, env=env, text=True, capture_output=True)
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


class _MinedHeadRpc(JsonRpc):
    """Anvil gate adapter: every scripted transaction is mined before reconciliation."""

    def finalized_block(self) -> Dict[str, Any]:
        return self.block("latest")


def _sha256(path: Path) -> str:
    return "0x" + hashlib.sha256(path.read_bytes()).hexdigest()


def _keccak256(path: Path) -> str:
    result = subprocess.run(
        ["cast", "keccak", "0x" + path.read_bytes().hex()],
        cwd=ROOT,
        text=True,
        capture_output=True,
    )
    value = result.stdout.strip().lower()
    if result.returncode or not re.fullmatch(r"0x[0-9a-f]{64}", value):
        raise DrillError("cannot hash pinned artifact %s" % path.relative_to(ROOT))
    return value


def _solidity_hashes(path: Path) -> Dict[str, str]:
    source = path.read_text(encoding="utf-8")
    values = {
        name: value.lower()
        for name, value in re.findall(
            r"constant\s+([A-Z0-9_]+)\s*=\s*\n?\s*(0x[0-9a-fA-F]{64})", source
        )
    }
    if not values:
        raise DrillError("generated artifact hashes are unavailable")
    return values


def _artifact_evidence() -> Dict[str, Any]:
    economic_path = ROOT / "src/generated/EconomicDeploymentCodeHashes.sol"
    flm_path = ROOT / "src/generated/FlmCodeHashes.sol"
    economic_manifest_path = ROOT / "metadata/economic-core-code-hashes.json"
    flm_manifest_path = ROOT / "metadata/sepolia-flm-code-hashes.json"
    economic_dir = ROOT / "metadata/economic-creation-code"
    flm_dir = ROOT / "metadata/flm-creation-code"
    economic_manifest = json.loads(economic_manifest_path.read_text(encoding="utf-8"))
    flm_manifest = json.loads(flm_manifest_path.read_text(encoding="utf-8"))
    economic_generated = _solidity_hashes(economic_path)
    flm_generated = _solidity_hashes(flm_path)
    economic_files = (
        ("ARBITRATION", "arbitration.bin"),
        ("VAULT", "vault.bin"),
        ("RELEASE_STRATEGY", "release_strategy.bin"),
        ("ZERO_VOTING", "zero_voting.bin"),
        ("ECON_GATEWAY", "econ_gateway.bin"),
        ("ECON_EVALUATOR", "econ_evaluator.bin"),
        ("RECEIPT", "receipt.bin"),
        ("REGISTRAR", "registrar.bin"),
        ("PROPOSAL_IMPLEMENTATION", "proposal_implementation.bin"),
        ("STACK_DEPLOYER", "stack_deployer.bin"),
    )
    flm_files = (
        ("RELAY", "relay.bin"),
        ("ADAPTER", "adapter.bin"),
        ("GUARD", "guard.bin"),
        ("ROUTER", "router.bin"),
        ("MANAGER", "manager.bin"),
    )

    def verify(
        manifest: Dict[str, Any],
        generated: Dict[str, str],
        directory: Path,
        files: Sequence[Sequence[str]],
    ) -> Dict[str, str]:
        contracts = manifest.get("contracts")
        if not isinstance(contracts, dict):
            raise DrillError("artifact manifest has no contracts")
        hashes = {}
        for name, filename in files:
            entry = contracts.get(name)
            path = directory / filename
            expected = entry.get("baseCreationCodeKeccak256") if isinstance(entry, dict) else None
            if (
                not isinstance(expected, str)
                or _keccak256(path) != expected.lower()
                or (name in generated and generated[name] != expected.lower())
                or entry.get("baseCreationCodeBytes") != len(path.read_bytes())
            ):
                raise DrillError("pinned artifact evidence diverged for %s" % name)
            hashes[name] = expected.lower()
        return hashes

    economic_hashes = verify(
        economic_manifest, economic_generated, economic_dir, economic_files
    )
    flm_hashes = verify(flm_manifest, flm_generated, flm_dir, flm_files)
    return {
        "economic": {
            "generatedSolSha256": _sha256(economic_path),
            "manifestSha256": _sha256(economic_manifest_path),
            "compiler": economic_manifest["compiler"],
            "keccak256": economic_hashes,
            "blobsSha256": {
                name: _sha256(economic_dir / filename) for name, filename in economic_files
            },
        },
        "flm": {
            "generatedSolSha256": _sha256(flm_path),
            "manifestSha256": _sha256(flm_manifest_path),
            "compiler": flm_manifest["compiler"],
            "submoduleSha": flm_manifest["flmSubmoduleSha"],
            "keccak256": flm_hashes,
            "blobsSha256": {
                name: _sha256(flm_dir / filename) for name, filename in flm_files
            },
        },
    }


def _resource_evidence(
    rpc: JsonRpc, first_block: int, last_block: int, elapsed_ms: int
) -> Dict[str, Any]:
    gas_used = 0
    transactions = 0
    max_transaction_gas = 0
    for number in range(first_block, last_block + 1):
        block = rpc.block(number)
        for tx_hash in block.get("transactions", []):
            receipt = rpc._request("eth_getTransactionReceipt", [tx_hash])
            if not isinstance(receipt, dict) or int(receipt.get("status", "0x0"), 16) != 1:
                raise DrillError("economic deployment contains a failed transaction")
            used = int(receipt["gasUsed"], 16)
            gas_used += used
            max_transaction_gas = max(max_transaction_gas, used)
            transactions += 1
    first = rpc.block(first_block)
    last = rpc.block(last_block)
    return {
        "transactions": transactions,
        "gasUsed": gas_used,
        "maxTransactionGasUsed": max_transaction_gas,
        "blocks": last_block - first_block + 1,
        "chainTimeSeconds": int(last["timestamp"], 16) - int(first["timestamp"], 16),
        "wallClockMs": elapsed_ms,
    }


def _validate_economic_report(report: Dict[str, Any], receipt_hash: str) -> None:
    instances = report.get("instances")
    if not isinstance(instances, list) or len(instances) != 10:
        raise DrillError("economic reconciliation did not discover 10 instances")
    unique_fields = ("receipt", "coreHash", "space", "arbitration", "evaluator")
    for field in unique_fields:
        if len({instance.get(field) for instance in instances}) != 10:
            raise DrillError("economic instances do not have 10 unique %s values" % field)
    managers = {
        instance.get("flm", {}).get("manager")
        for instance in instances
        if isinstance(instance.get("flm"), dict)
    }
    if len(managers) != 10 or None in managers:
        raise DrillError("economic instances do not have 10 unique manager values")
    for instance in instances:
        proposals = instance.get("proposals")
        flm = instance.get("flm")
        hydrated = instance.get("hydrated")
        active = instance.get("activeEvaluationProposalId")
        if (
            not isinstance(proposals, list)
            or len(proposals) != 1
            or not isinstance(flm, dict)
            or not isinstance(hydrated, dict)
            or active in (None, "0")
        ):
            raise DrillError("economic instance is not fully reconciled")
        proposal = proposals[0]
        if (
            proposal.get("proposalId") != active
            or proposal.get("state") != "EVALUATING"
            or proposal.get("payloadSource") != "gateway.transferProposed"
            or not isinstance(proposal.get("evaluationPayload"), str)
            or instance.get("queue") != []
            or hydrated.get("activeProposalId") != active
            or hydrated.get("evaluatorMarket") is not None
            or hydrated.get("registrarCodeHash") != receipt_hash
            or flm.get("mode") != "spot"
            or flm.get("activeProposalId") != "0"
        ):
            raise DrillError("economic singleton or artifact postcondition failed")


def _economic_10(rpc: _MinedHeadRpc, rpc_url: str, accounts: List[str]) -> Dict[str, Any]:
    if not rpc_url.startswith("http://127.0.0.1:") or rpc.chain_id() != 31_337:
        raise DrillError("economic drill only broadcasts to loopback Anvil chain 31337")
    artifacts = _artifact_evidence()
    start = rpc.block("latest")
    started = time.monotonic()
    env = dict(os.environ, WINDTUNNEL_SENDER=accounts[0])
    _run(
        [
            "forge",
            "script",
            "script/WindtunnelTenEconomic.s.sol:WindtunnelTenEconomic",
            "--rpc-url",
            rpc_url,
            "--broadcast",
            "--unlocked",
            "--sender",
            accounts[0],
            "--slow",
            "--skip-simulation",
            "--non-interactive",
        ],
        env=env,
    )
    elapsed_ms = round((time.monotonic() - started) * 1000)
    end = rpc.block("latest")
    first_block = int(start["number"], 16) + 1
    last_block = int(end["number"], 16)

    staged_topic = next(
        item["topic0"]
        for item in json.loads(
            (Path(__file__).with_name("event-schema-v2.json")).read_text(encoding="utf-8")
        )["events"]
        if item["id"] == "registrar.genesisStaged"
    )
    staged = rpc._request(
        "eth_getLogs",
        [{"fromBlock": hex(first_block), "toBlock": hex(last_block), "topics": [staged_topic]}],
    )
    if not isinstance(staged, list) or len(staged) != 10:
        raise DrillError("economic script did not emit 10 GenesisStaged receipts")
    registrars = {str(log["address"]).lower() for log in staged}
    if len(registrars) != 1:
        raise DrillError("economic receipts were not staged by one registrar")
    registrar = next(iter(registrars))
    start_block = min(int(log["blockNumber"], 16) for log in staged)

    with tempfile.TemporaryDirectory(prefix="fao-windtunnel-") as directory:
        with Indexer(Path(directory) / "economic.sqlite") as indexer:
            report = indexer.sync(rpc, start_block, [registrar])
            replayed = indexer.replay()
            if replayed != indexer.report_bytes():
                raise DrillError("economic replay is not byte-stable")
            index_evidence = indexer.evidence()
    receipt_hash = artifacts["economic"]["keccak256"]["RECEIPT"]
    _validate_economic_report(report, receipt_hash)
    resources = _resource_evidence(rpc, first_block, last_block, elapsed_ms)
    summary = {
        "instances": 10,
        "activeEvaluations": 10,
        "evaluationsPerInstance": 1,
        "flmSpotMode": 10,
        "publicBroadcasts": 0,
    }
    deterministic = {
        "registrar": registrar,
        "startBlock": start_block,
        "endBlock": last_block,
        "artifacts": artifacts,
        "resources": {key: value for key, value in resources.items() if key != "wallClockMs"},
        "reportSha256": index_evidence["reportSha256"],
        "summary": summary,
    }
    return {
        "v": 1,
        "kind": "fao.windtunnel.full-economic-reconciliation",
        "success": True,
        "broadcast": "loopback-anvil-only",
        "chainId": rpc.chain_id(),
        "registrar": registrar,
        "startBlock": start_block,
        "endBlock": last_block,
        "artifacts": artifacts,
        "resources": resources,
        "index": index_evidence,
        "deterministicSha256": "0x" + hashlib.sha256(_canonical(deterministic)).hexdigest(),
        "summary": summary,
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
            "--host",
            "127.0.0.1",
            "--chain-id",
            "31337",
            "--gas-limit",
            "60000000",
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
        rpc = _MinedHeadRpc(rpc_url)
        for _ in range(100):
            if process.poll() is not None:
                raise DrillError("fresh Anvil process exited before accepting RPC")
            try:
                accounts = [value.lower() for value in rpc._request("eth_accounts", [])]
                break
            except Exception:
                time.sleep(0.05)
        else:
            raise DrillError("Anvil did not start")
        latest = rpc.block("latest")
        nonce = int(rpc._request("eth_getTransactionCount", [accounts[0], "latest"]), 16)
        if int(latest["number"], 16) != 0 or nonce != 0:
            raise DrillError("drill requires a fresh Anvil state")
        rpc._request("anvil_setBlockTimestampInterval", [1])
        if mode == "economic-10":
            return _economic_10(rpc, rpc_url, accounts)
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
    parser.add_argument("mode", choices=("race", "prebroadcast-10", "economic-10"))
    parser.add_argument("--port", type=int, default=18545)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args(argv)
    try:
        evidence = run(args.mode, args.port)
    except (DrillError, OSError, ValueError, json.JSONDecodeError) as exc:
        if args.output:
            args.output.write_bytes(
                _canonical(
                    {
                        "v": 1,
                        "kind": "fao.windtunnel.drill-failure",
                        "success": False,
                        "mode": args.mode,
                        "error": str(exc),
                    }
                )
            )
        raise
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
