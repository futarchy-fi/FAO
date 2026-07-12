#!/usr/bin/env python3
"""Build and project the canonical Sepolia site-release deployment manifest.

Broadcast/event consistency is not source, runtime-bytecode, or wiring proof;
``status: active`` is consumer activation state, not a verification claim.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import tempfile
from pathlib import Path
from typing import Any


CHAIN_ID = 11_155_111
UNISWAP_V3_FACTORY = "0x0227628f3f023bb0b980b67d528571c95c6dac1c"
WETH = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"
FEE_TIER = 500
STABLE_IDENTITY = {
    "schemaVersion": 1,
    "network": "Sepolia",
    "explorer": "https://sepolia.etherscan.io",
    "governedSite": "https://testnet.futarchy.ai",
    "governedRepository": "https://github.com/futarchy-fi/fao-governed-site",
}
POOL_CREATED_TOPIC = (
    "0x783cca1c0412dd0d695e784568c96da2e9c22ff989357a2e8b1d9b2b4e6b7118"
)
SITE_RELEASE_TOPIC = (
    "0x17ab5d9ee422ce0b76cca7cac9a51d4c50293aae40aaada3fb8290d579939603"
)
CREATE_NAMES = {
    "deploymentReceipt": "FAOSepoliaSiteReleaseDeployment",
    "siteToken": "FAOSiteToken",
    "proposalImplementation": "FAOFutarchyProposal",
    "stackDeployer": "FAOSiteStackDeployer",
}
CONTRACT_KEYS = (
    "deploymentReceipt",
    "siteToken",
    "spotPool",
    "proposalImplementation",
    "stackDeployer",
    "space",
    "arbitration",
    "proposalGateway",
    "releaseStrategy",
    "votingStrategy",
    "evaluator",
    "orchestrator",
    "twapResolver",
    "futarchyFactory",
)
MANIFEST_KEYS = {
    "schemaVersion",
    "status",
    "network",
    "chainId",
    "deploymentTransaction",
    "deploymentBlock",
    "deployer",
    "currencyToken",
    "feeTier",
    "contracts",
}


class ManifestError(ValueError):
    pass


def _object_without_duplicates(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ManifestError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=_object_without_duplicates
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise ManifestError(f"cannot read JSON {path}: {exc}") from exc


def _require_dict(value: Any, name: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ManifestError(f"{name} must be an object")
    return value


def _require_list(value: Any, name: str) -> list[Any]:
    if not isinstance(value, list):
        raise ManifestError(f"{name} must be an array")
    return value


def _json_integer(value: Any, name: str) -> int:
    if type(value) is not int:
        raise ManifestError(f"{name} must be an integer")
    return value


def _quantity(value: Any, name: str) -> int:
    if type(value) is int:
        return value
    if isinstance(value, str) and value.startswith("0x") and len(value) > 2:
        try:
            return int(value[2:], 16)
        except ValueError as exc:
            raise ManifestError(f"{name} must be a JSON integer or hex quantity") from exc
    raise ManifestError(f"{name} must be a JSON integer or hex quantity")


def _hex(value: Any, bytes_: int, name: str) -> str:
    if not isinstance(value, str) or len(value) != 2 + bytes_ * 2 or not value.startswith("0x"):
        raise ManifestError(f"{name} must be a {bytes_}-byte 0x hex value")
    try:
        bytes.fromhex(value[2:])
    except ValueError as exc:
        raise ManifestError(f"{name} must be hexadecimal") from exc
    return value.lower()


def _address(value: Any, name: str) -> str:
    address = _hex(value, 20, name)
    if address == "0x" + "00" * 20:
        raise ManifestError(f"{name} cannot be zero")
    return address


def _topic_address(value: Any, name: str) -> str:
    topic = _hex(value, 32, name)
    if topic[2:26] != "0" * 24:
        raise ManifestError(f"{name} is not an encoded address")
    return _address("0x" + topic[-40:], name)


def _data_addresses(data: Any, count: int, name: str) -> list[str]:
    encoded = _hex(data, 32 * count, name)[2:]
    addresses = []
    for index in range(count):
        word = encoded[index * 64 : (index + 1) * 64]
        if word[:24] != "0" * 24:
            raise ManifestError(f"{name}[{index}] is not an encoded address")
        addresses.append(_address("0x" + word[-40:], f"{name}[{index}]"))
    return addresses


def _is_success(receipt: dict[str, Any]) -> bool:
    return _quantity(receipt.get("status"), "receipt.status") == 1


def _receipt_map(broadcast: dict[str, Any]) -> dict[str, dict[str, Any]]:
    receipts: dict[str, dict[str, Any]] = {}
    for index, raw in enumerate(_require_list(broadcast.get("receipts"), "receipts")):
        receipt = _require_dict(raw, f"receipts[{index}]")
        tx_hash = _hex(receipt.get("transactionHash"), 32, f"receipts[{index}].transactionHash")
        if tx_hash in receipts:
            raise ManifestError(f"duplicate receipt for transaction {tx_hash}")
        receipts[tx_hash] = receipt
    return receipts


def _successful_creates(
    broadcast: dict[str, Any], receipts: dict[str, dict[str, Any]]
) -> tuple[dict[str, str], dict[str, dict[str, Any]], str]:
    found: dict[str, list[tuple[str, dict[str, Any], str]]] = {
        key: [] for key in CREATE_NAMES
    }
    deployers: set[str] = set()
    reverse_names = {contract_name: key for key, contract_name in CREATE_NAMES.items()}

    for index, raw in enumerate(_require_list(broadcast.get("transactions"), "transactions")):
        tx = _require_dict(raw, f"transactions[{index}]")
        key = reverse_names.get(tx.get("contractName"))
        if key is None:
            continue
        if tx.get("transactionType") != "CREATE":
            raise ManifestError(f"{CREATE_NAMES[key]} must be a CREATE transaction")
        tx_hash = _hex(tx.get("hash"), 32, f"transactions[{index}].hash")
        receipt = receipts.get(tx_hash)
        if receipt is None:
            raise ManifestError(f"missing receipt for named CREATE {CREATE_NAMES[key]}")
        if not _is_success(receipt):
            raise ManifestError(f"named CREATE failed: {CREATE_NAMES[key]}")
        contract = _address(tx.get("contractAddress"), f"transactions[{index}].contractAddress")
        receipt_contract = receipt.get("contractAddress")
        if receipt_contract is not None and _address(
            receipt_contract, f"receipt {tx_hash}.contractAddress"
        ) != contract:
            raise ManifestError(f"contract address mismatch for {tx_hash}")
        transaction = _require_dict(tx.get("transaction"), f"transactions[{index}].transaction")
        deployer = _address(transaction.get("from"), f"transactions[{index}].transaction.from")
        deployers.add(deployer)
        found[key].append((contract, receipt, tx_hash))

    selected_addresses: dict[str, str] = {}
    selected_receipts: dict[str, dict[str, Any]] = {}
    selected_hashes: dict[str, str] = {}
    for key, matches in found.items():
        if len(matches) != 1:
            raise ManifestError(
                f"expected one successful CREATE for {CREATE_NAMES[key]}, found {len(matches)}"
            )
        selected_addresses[key], selected_receipts[key], selected_hashes[key] = matches[0]
    if len(deployers) != 1:
        raise ManifestError("named CREATEs must have one deployer")
    return selected_addresses, selected_receipts, selected_hashes["deploymentReceipt"]


def _pool_created(
    receipts: dict[str, dict[str, Any]], site_token: str
) -> tuple[str, str, int]:
    matches: list[tuple[str, str, int]] = []
    for receipt in receipts.values():
        if not _is_success(receipt):
            continue
        for raw in _require_list(receipt.get("logs", []), "receipt.logs"):
            log = _require_dict(raw, "receipt.log")
            topics = _require_list(log.get("topics"), "receipt.log.topics")
            if not topics or str(topics[0]).lower() != POOL_CREATED_TOPIC:
                continue
            if len(topics) != 4:
                raise ManifestError("PoolCreated must have four topics")
            token0 = _topic_address(topics[1], "PoolCreated.token0")
            token1 = _topic_address(topics[2], "PoolCreated.token1")
            if site_token not in (token0, token1):
                continue
            if _address(log.get("address"), "PoolCreated.emitter") != UNISWAP_V3_FACTORY:
                raise ManifestError("PoolCreated emitter is not the pinned Sepolia factory")
            currency = token1 if token0 == site_token else token0
            if currency != WETH:
                raise ManifestError("PoolCreated other token is not pinned Sepolia WETH")
            fee_topic = _hex(topics[3], 32, "PoolCreated.fee")
            fee = int(fee_topic, 16)
            if fee != FEE_TIER:
                raise ManifestError(f"PoolCreated fee must be {FEE_TIER}")
            data = _hex(log.get("data"), 64, "PoolCreated.data")[2:]
            pool_word = data[64:]
            if pool_word[:24] != "0" * 24:
                raise ManifestError("PoolCreated.pool is not an encoded address")
            pool = _address("0x" + pool_word[-40:], "PoolCreated.pool")
            matches.append((pool, currency, fee))
    if len(matches) != 1:
        raise ManifestError(
            f"expected one successful PoolCreated for site token, found {len(matches)}"
        )
    return matches[0]


def _site_release_contracts(
    receipt: dict[str, Any], deployment_receipt: str
) -> dict[str, str]:
    matches: list[dict[str, str]] = []
    for raw in _require_list(receipt.get("logs", []), "deployment receipt logs"):
        log = _require_dict(raw, "deployment receipt log")
        topics = _require_list(log.get("topics"), "SiteReleaseStackDeployed.topics")
        if not topics or str(topics[0]).lower() != SITE_RELEASE_TOPIC:
            continue
        if _address(log.get("address"), "SiteReleaseStackDeployed.emitter") != deployment_receipt:
            raise ManifestError("SiteReleaseStackDeployed has an unexpected emitter")
        if len(topics) != 4:
            raise ManifestError("SiteReleaseStackDeployed must have four topics")
        space = _topic_address(topics[1], "SiteReleaseStackDeployed.space")
        arbitration = _topic_address(topics[2], "SiteReleaseStackDeployed.arbitration")
        gateway = _topic_address(topics[3], "SiteReleaseStackDeployed.proposalGateway")
        release, voting, evaluator, orchestrator, resolver, factory = _data_addresses(
            log.get("data"), 6, "SiteReleaseStackDeployed.data"
        )
        matches.append(
            {
                "space": space,
                "arbitration": arbitration,
                "proposalGateway": gateway,
                "releaseStrategy": release,
                "votingStrategy": voting,
                "evaluator": evaluator,
                "orchestrator": orchestrator,
                "twapResolver": resolver,
                "futarchyFactory": factory,
            }
        )
    if len(matches) != 1:
        raise ManifestError(
            f"expected one SiteReleaseStackDeployed event, found {len(matches)}"
        )
    return matches[0]


def manifest_from_broadcast(broadcast: dict[str, Any]) -> dict[str, Any]:
    broadcast = _require_dict(broadcast, "broadcast")
    if _quantity(broadcast.get("chain"), "chain") != CHAIN_ID:
        raise ManifestError(f"broadcast chain must be Sepolia ({CHAIN_ID})")
    pending = _require_list(broadcast.get("pending", []), "pending")
    if pending:
        raise ManifestError("broadcast contains pending transactions")
    receipts = _receipt_map(broadcast)
    creates, create_receipts, deployment_hash = _successful_creates(broadcast, receipts)
    pool, currency, fee = _pool_created(receipts, creates["siteToken"])
    emitted = _site_release_contracts(
        create_receipts["deploymentReceipt"], creates["deploymentReceipt"]
    )
    deployment_block = _quantity(
        create_receipts["deploymentReceipt"].get("blockNumber"), "deployment block"
    )
    if deployment_block < 0:
        raise ManifestError("deployment block cannot be negative")

    contract_values = {**creates, "spotPool": pool, **emitted}
    contracts = {key: contract_values[key] for key in CONTRACT_KEYS}
    if len(set(contracts.values())) != len(contracts):
        raise ManifestError("deployed contract addresses must be unique")
    deploy_tx = next(
        tx
        for tx in _require_list(broadcast["transactions"], "transactions")
        if isinstance(tx, dict) and str(tx.get("hash", "")).lower() == deployment_hash
    )
    deployer = _address(
        _require_dict(deploy_tx.get("transaction"), "deployment transaction").get("from"),
        "deployer",
    )
    return {
        "schemaVersion": 1,
        "status": "active",
        "network": "sepolia",
        "chainId": CHAIN_ID,
        "deploymentTransaction": deployment_hash,
        "deploymentBlock": deployment_block,
        "deployer": deployer,
        "currencyToken": currency,
        "feeTier": fee,
        "contracts": contracts,
    }


def _validate_manifest(raw: Any) -> dict[str, Any]:
    manifest = _require_dict(raw, "manifest")
    if set(manifest) != MANIFEST_KEYS:
        missing = sorted(MANIFEST_KEYS - set(manifest))
        unknown = sorted(set(manifest) - MANIFEST_KEYS)
        raise ManifestError(f"invalid manifest keys; missing={missing}, unknown={unknown}")
    if (
        _json_integer(manifest["schemaVersion"], "schemaVersion") != 1
        or manifest["status"] != "active"
        or manifest["network"] != "sepolia"
        or _json_integer(manifest["chainId"], "chainId") != CHAIN_ID
    ):
        raise ManifestError("manifest identity must be active Sepolia schema version 1")
    _hex(manifest["deploymentTransaction"], 32, "deploymentTransaction")
    if _json_integer(manifest["deploymentBlock"], "deploymentBlock") < 0:
        raise ManifestError("deploymentBlock cannot be negative")
    _address(manifest["deployer"], "deployer")
    if _address(manifest["currencyToken"], "currencyToken") != WETH:
        raise ManifestError("currencyToken must be pinned Sepolia WETH")
    if _json_integer(manifest["feeTier"], "feeTier") != FEE_TIER:
        raise ManifestError(f"feeTier must be {FEE_TIER}")
    contracts = _require_dict(manifest["contracts"], "contracts")
    if tuple(contracts) != CONTRACT_KEYS:
        raise ManifestError("contracts must contain the canonical keys in canonical order")
    normalized = [_address(value, f"contracts.{key}") for key, value in contracts.items()]
    if len(set(normalized)) != len(normalized):
        raise ManifestError("contract addresses must be unique")
    return manifest


def publisher_projection(manifest: dict[str, Any], template: dict[str, Any]) -> dict[str, Any]:
    manifest = _validate_manifest(manifest)
    template = _require_dict(template, "publisher deployment example")
    required = {"chain_id", "strategy_address", "start_block"}
    if not required.issubset(template):
        raise ManifestError("publisher deployment example is missing deployment fields")
    return {
        "chain_id": manifest["chainId"],
        "strategy_address": manifest["contracts"]["releaseStrategy"],
        "start_block": manifest["deploymentBlock"],
        **{key: value for key, value in template.items() if key not in required},
    }


def stable_projection(manifest: dict[str, Any]) -> dict[str, Any]:
    manifest = _validate_manifest(manifest)
    return {
        "schemaVersion": STABLE_IDENTITY["schemaVersion"],
        "status": "active",
        "network": STABLE_IDENTITY["network"],
        "chainId": manifest["chainId"],
        "explorer": STABLE_IDENTITY["explorer"],
        "governedSite": STABLE_IDENTITY["governedSite"],
        "governedRepository": STABLE_IDENTITY["governedRepository"],
        "deploymentTransaction": manifest["deploymentTransaction"],
        "deploymentBlock": manifest["deploymentBlock"],
        "currencyToken": manifest["currencyToken"],
        "contracts": manifest["contracts"],
    }


def _encoded(value: dict[str, Any]) -> bytes:
    return (json.dumps(value, indent=2) + "\n").encode("utf-8")


def _write_or_check(path: Path, value: dict[str, Any], check: bool) -> None:
    expected = _encoded(value)
    if check:
        try:
            actual = path.read_bytes()
        except OSError as exc:
            raise ManifestError(f"cannot check {path}: {exc}") from exc
        if actual != expected:
            raise ManifestError(f"generated file is stale: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(expected)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    from_broadcast = subparsers.add_parser("from-broadcast")
    from_broadcast.add_argument("--broadcast", required=True, type=Path)
    from_broadcast.add_argument(
        "--out", type=Path, default=Path("deployments/sepolia-site-release.json")
    )
    from_broadcast.add_argument("--check", action="store_true")

    project = subparsers.add_parser("project")
    project.add_argument("--manifest", required=True, type=Path)
    project.add_argument(
        "--publisher", required=True, type=Path, help="publisher repository directory"
    )
    project.add_argument(
        "--stable", required=True, type=Path, help="stable-client repository directory"
    )
    project.add_argument("--check", action="store_true")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "from-broadcast":
        manifest = manifest_from_broadcast(load_json(args.broadcast))
        _write_or_check(args.out, manifest, args.check)
    else:
        manifest = _validate_manifest(load_json(args.manifest))
        publisher_template = load_json(args.publisher / "deployment.example.json")
        publisher = publisher_projection(manifest, publisher_template)
        stable = stable_projection(manifest)
        _write_or_check(args.publisher / "deployment.json", publisher, args.check)
        _write_or_check(args.stable / "deployment.json", stable, args.check)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as exc:
        print(f"site_deployment.py: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
