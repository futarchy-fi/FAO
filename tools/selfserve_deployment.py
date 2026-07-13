#!/usr/bin/env python3
"""Build the canonical Sepolia self-serve registrar trust-root manifest."""

from __future__ import annotations

import argparse
import copy
import json
import sys
from pathlib import Path
from typing import Any, Callable

try:
    from tools import economic_deployment, flm_code_hashes, site_deployment
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    import economic_deployment  # type: ignore
    import flm_code_hashes  # type: ignore
    import site_deployment  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "deployments/sepolia-selfserve.json"
REGISTRAR_NAME = "FaoGenesisRegistrar"

ManifestError = site_deployment.ManifestError


def _registrar_record(
    broadcast: Any,
    receipt_creation_code: bytes,
    registrar_creation_code: bytes,
    client: Any,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    value = economic_deployment._require_dict(broadcast, "registrar broadcast")
    if economic_deployment._quantity(value.get("chain"), "registrar broadcast.chain") != economic_deployment.CHAIN_ID:
        raise ManifestError(f"registrar broadcast must be Sepolia ({economic_deployment.CHAIN_ID})")
    if economic_deployment._require_list(value.get("pending", []), "registrar broadcast.pending"):
        raise ManifestError("registrar broadcast contains pending transactions")
    transactions = economic_deployment._require_list(
        value.get("transactions"), "registrar broadcast.transactions"
    )
    receipts = site_deployment._receipt_map(value)
    if len(transactions) != 1 or len(receipts) != 1:
        raise ManifestError("registrar broadcast must contain exactly one transaction and receipt")

    outer = economic_deployment._require_dict(transactions[0], "registrar transaction")
    if outer.get("contractName") != REGISTRAR_NAME or outer.get("transactionType") != "CREATE":
        raise ManifestError("registrar broadcast must contain one FaoGenesisRegistrar CREATE")
    tx_hash = economic_deployment._canonical_hash(outer.get("hash"), "registrar transaction hash")
    artifact = economic_deployment._require_dict(
        outer.get("transaction"), "registrar transaction payload"
    )
    sender = economic_deployment._address(artifact.get("from"), "registrar sender")
    nonce = economic_deployment._quantity(artifact.get("nonce"), "registrar nonce")
    if economic_deployment.flm_deployment._live_target(
        artifact.get("to"), "registrar target"
    ) is not None:
        raise ManifestError("registrar transaction must be a top-level CREATE")
    artifact_input = economic_deployment._variable_bytes(
        artifact.get("input"), "registrar transaction input"
    )

    tx = economic_deployment._require_dict(client.transaction(tx_hash), "live registrar transaction")
    receipt = economic_deployment._require_dict(
        client.receipt(tx_hash), "live registrar receipt"
    )
    address = economic_deployment._address(
        outer.get("contractAddress"), "registrar contract address"
    )
    block = economic_deployment._quantity(receipt.get("blockNumber"), "registrar block")
    if (
        economic_deployment._canonical_hash(tx.get("hash"), "live registrar hash") != tx_hash
        or economic_deployment._quantity(tx.get("blockNumber"), "live registrar block") != block
        or economic_deployment._address(tx.get("from"), "live registrar sender") != sender
        or economic_deployment._quantity(tx.get("nonce"), "live registrar nonce") != nonce
        or economic_deployment.flm_deployment._live_target(tx.get("to"), "live registrar target")
        is not None
        or economic_deployment._variable_bytes(tx.get("input"), "live registrar input")
        != artifact_input
        or economic_deployment._canonical_hash(
            receipt.get("transactionHash"), "live registrar receipt hash"
        )
        != tx_hash
        or economic_deployment._address(receipt.get("from"), "live registrar receipt sender")
        != sender
        or economic_deployment.flm_deployment._live_target(
            receipt.get("to"), "live registrar receipt target"
        )
        is not None
        or economic_deployment._address(
            receipt.get("contractAddress"), "live registrar receipt contract"
        )
        != address
        or economic_deployment._quantity(receipt.get("status"), "live registrar status") != 1
    ):
        raise ManifestError("registrar broadcast does not match its live transaction and receipt")

    receipt_hash = economic_deployment._digest(receipt_creation_code, hash_)
    expected_input = registrar_creation_code + bytes.fromhex(receipt_hash[2:])
    if artifact_input != expected_input:
        raise ManifestError("registrar CREATE input does not match canonical compiler evidence")
    if address != economic_deployment._create_address(sender, nonce, hash_):
        raise ManifestError("registrar address does not match its CREATE nonce")
    runtime = client.code(address)
    if not runtime:
        raise ManifestError("registrar has no runtime code")
    if (
        economic_deployment._call_hash(
            client, address, "RECEIPT_CREATION_CODE_HASH()(bytes32)"
        )
        != receipt_hash
    ):
        raise ManifestError("registrar immutable does not pin the canonical receipt")

    return {
        "address": address,
        "source": economic_deployment.REGISTRAR_SOURCE,
        "contract": economic_deployment.REGISTRAR_CONTRACT,
        "transaction": {"hash": tx_hash, "block": block, "nonce": nonce, "from": sender},
        "creationCodeBytes": len(registrar_creation_code),
        "creationCodeKeccak256": economic_deployment._digest(registrar_creation_code, hash_),
        "runtimeCodeBytes": len(runtime),
        "runtimeCodeKeccak256": economic_deployment._digest(runtime, hash_),
    }


def manifest_from_broadcast(
    economic_manifest: Any,
    registrar_broadcast: Any,
    receipt_creation_code: bytes,
    registrar_creation_code: bytes,
    prerequisite_creation_codes: dict[str, bytes],
    client: Any,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    economic = economic_deployment.validate_manifest(economic_manifest, hash_=hash_)
    economic_deployment.verify_rpc(
        economic,
        receipt_creation_code,
        prerequisite_creation_codes,
        client,
        hash_=hash_,
    )
    registrar = _registrar_record(
        registrar_broadcast,
        receipt_creation_code,
        registrar_creation_code,
        client,
        hash_,
    )
    shared = {
        "schemaVersion": 1,
        "network": "sepolia",
        "chainId": economic_deployment.CHAIN_ID,
        "registrar": registrar,
        "prerequisites": copy.deepcopy(economic["prerequisites"]),
    }
    economic_deployment._shared_deployment(
        shared,
        receipt_creation_code,
        registrar_creation_code,
        prerequisite_creation_codes,
        client,
        hash_,
    )
    return shared


def _write(path: Path, manifest: dict[str, Any], check: bool) -> None:
    content = json.dumps(manifest, indent=2).encode("utf-8") + b"\n"
    if check:
        try:
            current = path.read_bytes()
        except OSError as exc:
            raise ManifestError(f"self-serve manifest is missing: {path}") from exc
        if current != content:
            raise ManifestError(f"self-serve manifest is stale: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--economic-manifest", required=True, type=Path)
    parser.add_argument("--registrar-broadcast", required=True, type=Path)
    parser.add_argument("--rpc-url", required=True)
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)

    receipt, registrar, prerequisites = economic_deployment.verified_creation_evidence()
    client = economic_deployment.CastClient(args.rpc_url)
    manifest = manifest_from_broadcast(
        site_deployment.load_json(args.economic_manifest),
        site_deployment.load_json(args.registrar_broadcast),
        receipt,
        registrar,
        prerequisites,
        client,
    )
    _write(args.output, manifest, args.check)
    print("self-serve deployment manifest is current" if args.check else f"wrote {args.output}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ManifestError, OSError, UnicodeError, json.JSONDecodeError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
