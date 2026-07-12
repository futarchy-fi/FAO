#!/usr/bin/env python3
"""Validate and verify a staged Sepolia economic-genesis deployment manifest."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import Any, Callable

try:
    from tools import economic_code_hashes, flm_code_hashes, flm_deployment, site_deployment
except ModuleNotFoundError:  # Direct `python tools/economic_deployment.py` execution.
    import economic_code_hashes  # type: ignore
    import flm_code_hashes  # type: ignore
    import flm_deployment  # type: ignore
    import site_deployment  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
CHAIN_ID = flm_deployment.CHAIN_ID
FEE_TIER = flm_deployment.FEE_TIER
OBSERVATION_CARDINALITY = flm_deployment.MIN_CARDINALITY_NEXT
DEAD = flm_deployment.DEAD
ZERO = "0x" + "00" * 20
POOL_INIT_CODE_HASH = (
    "0xe34f199b19b2b4f47f68442619d555527d244f78a3297ea89325f843f87b8b54"
)
DEPLOY_CORE_SELECTOR = "67658a72"
DEPLOY_FLM_SELECTOR = "88b5e784"
FINALIZE_SELECTOR = "4bb278f3"
RECEIPT_SOURCE = "src/FaoGenesisDeployment.sol"
RECEIPT_CONTRACT = "FaoGenesisDeployment"
SX_PINS = {
    "proxyFactory": (
        "0x4b4f7f64be813ccc66aefc3bfce2baa01188631c",
        "0x9d58d183bb98c199c270f0f2ba7c0abbda1a119caef4c136e137bbacca8c4035",
    ),
    "spaceImplementation": (
        "0xc3031a7d3326e47d49bff9d374d74f364b29ce4d",
        "0x4f2f90c70374b7dcd468d351747e9c865efc0d47e606eb6fdaeb2a842c148d81",
    ),
    "proposalValidationStrategy": (
        "0x9a39194f870c410633c170889e9025fba2113c79",
        "0xddd4560ead7f2c3de35f37de8d50c43e57f0173ad3eefd20098c3b6e08cba9d8",
    ),
}
PREREQUISITES = {
    "proposalImplementation": (
        "src/FAOFutarchyProposal.sol",
        "FAOFutarchyProposal",
        b"",
    ),
    "stackDeployer": (
        "src/FAOSiteStackDeployer.sol",
        "FAOSiteStackDeployer",
        bytes(32),
    ),
}

CORE_BLOBS = (
    "ARBITRATION",
    "VAULT",
    "RELEASE_STRATEGY",
    "ZERO_VOTING",
    "ECON_GATEWAY",
    "ECON_EVALUATOR",
)
FLM_BLOBS = ("RELAY", "ADAPTER", "GUARD", "ROUTER", "MANAGER")
CORE_CHILDREN = (
    ("arbitration", 1),
    ("vault", 2),
    ("releaseStrategy", 3),
    ("votingStrategy", 4),
    ("proposalGateway", 5),
    ("evaluator", 6),
)
FLM_CHILDREN = (
    ("relay", 7),
    ("spotAdapter", 8),
    ("conditionalAdapter", 9),
    ("guard", 10),
    ("router", 11),
    ("manager", 12),
)
DEPENDENCY_KEYS = (
    "proxyFactory",
    "spaceImplementation",
    "proposalValidationStrategy",
    "stackDeployer",
    "proposalImplementation",
    "weth",
    "conditionalTokens",
    "wrapped1155Factory",
    "uniswapV3Factory",
    "positionManager",
)
CORE_DEPENDENCY_KEYS = DEPENDENCY_KEYS[:-1]
CORE_CONFIG_KEYS = (
    *CORE_DEPENDENCY_KEYS,
    "graduationThreshold",
    "arbitrationTimeout",
    "siteMinActivationBond",
    "treasuryMinActivationBond",
    "twapTimeout",
    "twapWindow",
    "spaceSaltNonce",
    "daoURI",
    "metadataURI",
    "votingStrategyMetadataURI",
    "proposalValidationStrategyMetadataURI",
    "tokenName",
    "tokenSymbol",
    "saleEnd",
    "bootstrapDeadline",
    "saleCap",
    "minimumRaise",
    "tokenMaxSupply",
    "initialPrice",
    "slope",
    "bootstrapBps",
)
GRANT_KEYS = ("beneficiary", "start", "duration", "amount")
FLM_CONFIG_KEYS = ("positionManager",)
CONTRACT_KEYS = (
    "space",
    "arbitration",
    "vault",
    "companyToken",
    "proposalGateway",
    "releaseStrategy",
    "votingStrategy",
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
    "vestingWallets",
)
MANIFEST_KEYS = {
    "schemaVersion",
    "status",
    "network",
    "chainId",
    "transactions",
    "receipt",
    "prerequisites",
    "coreConfig",
    "grants",
    "flmConfig",
    "feeTier",
    "poolInitCodeHash",
    "observationCardinality",
    "contracts",
    "codeBlobs",
    "finalization",
}

ManifestError = site_deployment.ManifestError
_address = site_deployment._address
_hex = site_deployment._hex
_json_integer = site_deployment._json_integer
_quantity = site_deployment._quantity
_require_dict = site_deployment._require_dict
_require_list = site_deployment._require_list
_variable_bytes = flm_deployment._variable_bytes
_word_uint = flm_deployment._word_uint


def _expect_keys(value: dict[str, Any], expected: tuple[str, ...] | set[str], name: str) -> None:
    if set(value) != set(expected):
        raise ManifestError(f"{name} has invalid keys")


def _canonical_address(value: Any, name: str) -> str:
    normalized = _address(value, name)
    if value != normalized:
        raise ManifestError(f"{name} must be canonical lowercase hex")
    return normalized


def _canonical_hash(value: Any, name: str) -> str:
    normalized = _hex(value, 32, name)
    if value != normalized:
        raise ManifestError(f"{name} must be canonical lowercase hex")
    return normalized


def _canonical_blob_hashes() -> tuple[
    dict[str, str], dict[str, str], dict[str, dict[str, int | str]]
]:
    core = _require_dict(
        site_deployment.load_json(ROOT / economic_code_hashes.MANIFEST_PATH),
        "economic core code evidence",
    )
    if set(core) != {"schemaVersion", "compiler", "contracts"} or core.get("schemaVersion") != 1:
        raise ManifestError("economic core code evidence must be schema version 1")
    compiler = _require_dict(core.get("compiler"), "economic core compiler evidence")
    _expect_keys(compiler, ("solcVersion", "solcSettingsKeccak256"), "economic core compiler")
    if not isinstance(compiler["solcVersion"], str) or not compiler["solcVersion"]:
        raise ManifestError("economic core compiler version is missing")
    _canonical_hash(compiler["solcSettingsKeccak256"], "economic core compiler settings")
    core_contracts = _require_dict(core.get("contracts"), "economic code contracts")
    if tuple(core_contracts) != tuple(target.constant for target in economic_code_hashes.TARGETS):
        raise ManifestError("economic code evidence is not canonical")
    all_evidence: dict[str, dict[str, int | str]] = {}
    for target in economic_code_hashes.TARGETS:
        item = _require_dict(core_contracts[target.constant], f"economic code {target.constant}")
        _expect_keys(
            item,
            (
                "source",
                "contract",
                "baseCreationCodeBytes",
                "baseCreationCodeKeccak256",
            ),
            f"economic code {target.constant}",
        )
        byte_length = _json_integer(
            item["baseCreationCodeBytes"],
            f"economic code {target.constant} byte length",
        )
        if (
            item["source"] != target.source
            or item["contract"] != target.contract
            or byte_length <= 0
        ):
            raise ManifestError(f"economic code {target.constant} compiler identity is invalid")
        all_evidence[target.constant] = {
            "bytes": byte_length,
            "hash": _canonical_hash(
                item["baseCreationCodeKeccak256"], f"economic code {target.constant} hash"
            ),
        }
    core_hashes = {key: str(all_evidence[key]["hash"]) for key in CORE_BLOBS}

    flm = flm_deployment._validate_code_evidence(
        site_deployment.load_json(ROOT / flm_code_hashes.MANIFEST_PATH)
    )
    flm_hashes = {
        key: flm["contracts"][key]["baseCreationCodeKeccak256"] for key in FLM_BLOBS
    }
    deployment_evidence = {
        "receipt": all_evidence["RECEIPT"],
        "proposalImplementation": all_evidence["PROPOSAL_IMPLEMENTATION"],
        "stackDeployer": all_evidence["STACK_DEPLOYER"],
    }
    return core_hashes, flm_hashes, deployment_evidence


def _transaction(value: Any, name: str) -> dict[str, Any]:
    tx = _require_dict(value, name)
    _expect_keys(tx, ("hash", "block", "nonce", "from"), name)
    _canonical_hash(tx["hash"], f"{name}.hash")
    if _json_integer(tx["block"], f"{name}.block") < 0:
        raise ManifestError(f"{name}.block cannot be negative")
    _uint(tx["nonce"], 64, f"{name}.nonce")
    _canonical_address(tx["from"], f"{name}.from")
    return tx


def _prerequisite(value: Any, name: str, key: str) -> dict[str, Any]:
    item = _require_dict(value, name)
    _expect_keys(
        item,
        (
            "address",
            "source",
            "contract",
            "transaction",
            "creationCodeBytes",
            "creationCodeKeccak256",
            "runtimeCodeBytes",
            "runtimeCodeKeccak256",
        ),
        name,
    )
    source, contract, _ = PREREQUISITES[key]
    _canonical_address(item["address"], f"{name}.address")
    if item["source"] != source or item["contract"] != contract:
        raise ManifestError(f"{name} has the wrong compiler identity")
    _transaction(item["transaction"], f"{name}.transaction")
    if _json_integer(item["creationCodeBytes"], f"{name}.creationCodeBytes") <= 0:
        raise ManifestError(f"{name} creation code cannot be empty")
    if _json_integer(item["runtimeCodeBytes"], f"{name}.runtimeCodeBytes") <= 0:
        raise ManifestError(f"{name} runtime code cannot be empty")
    _canonical_hash(item["creationCodeKeccak256"], f"{name}.creationCodeKeccak256")
    _canonical_hash(item["runtimeCodeKeccak256"], f"{name}.runtimeCodeKeccak256")
    return item


def _dependency(value: Any, name: str) -> dict[str, str]:
    dependency = _require_dict(value, name)
    _expect_keys(dependency, ("target", "runtimeCodeKeccak256"), name)
    _canonical_address(dependency["target"], f"{name}.target")
    _canonical_hash(dependency["runtimeCodeKeccak256"], f"{name}.runtimeCodeKeccak256")
    return dependency


def _uint(value: Any, bits: int, name: str) -> int:
    number = _json_integer(value, name)
    if number < 0 or number >= 1 << bits:
        raise ManifestError(f"{name} is outside uint{bits}")
    return number


def _word(value: int) -> bytes:
    return value.to_bytes(32, "big")


def _address_word(value: str) -> bytes:
    return bytes(12) + bytes.fromhex(value[2:])


def _dynamic_bytes(value: bytes) -> bytes:
    return _word(len(value)) + value + bytes((-len(value)) % 32)


def _encode_core_config(config: dict[str, Any]) -> bytes:
    head: list[bytes | str] = []
    for key in CORE_DEPENDENCY_KEYS:
        dependency = config[key]
        head.extend(
            (
                _address_word(dependency["target"]),
                bytes.fromhex(dependency["runtimeCodeKeccak256"][2:]),
            )
        )
    for key in (
        "graduationThreshold",
        "arbitrationTimeout",
        "siteMinActivationBond",
        "treasuryMinActivationBond",
        "twapTimeout",
        "twapWindow",
        "spaceSaltNonce",
    ):
        head.append(_word(config[key]))
    head.extend(
        (
            config["daoURI"],
            config["metadataURI"],
            config["votingStrategyMetadataURI"],
            config["proposalValidationStrategyMetadataURI"],
            config["tokenName"],
            config["tokenSymbol"],
        )
    )
    for key in (
        "saleEnd",
        "bootstrapDeadline",
        "saleCap",
        "minimumRaise",
        "tokenMaxSupply",
        "initialPrice",
        "slope",
        "bootstrapBps",
    ):
        head.append(_word(config[key]))

    head_bytes = len(head) * 32
    tail = bytearray()
    encoded_head = bytearray()
    for value in head:
        if isinstance(value, str):
            encoded_head.extend(_word(head_bytes + len(tail)))
            tail.extend(_dynamic_bytes(value.encode("utf-8")))
        else:
            encoded_head.extend(value)
    return bytes(encoded_head + tail)


def _encode_grants(grants: list[dict[str, Any]]) -> bytes:
    encoded = bytearray(_word(len(grants)))
    for grant in grants:
        encoded.extend(_address_word(grant["beneficiary"]))
        encoded.extend(_word(grant["start"]))
        encoded.extend(_word(grant["duration"]))
        encoded.extend(_word(grant["amount"]))
    return bytes(encoded)


def _encode_bytes_array(values: tuple[bytes, ...]) -> bytes:
    offsets = bytearray()
    body = bytearray()
    cursor = len(values) * 32
    for value in values:
        offsets.extend(_word(cursor))
        encoded = _dynamic_bytes(value)
        body.extend(encoded)
        cursor += len(encoded)
    return _word(len(values)) + offsets + body


def _encode_dynamic_arguments(values: tuple[bytes, ...]) -> bytes:
    head = bytearray()
    body = bytearray()
    cursor = len(values) * 32
    for value in values:
        head.extend(_word(cursor))
        body.extend(value)
        cursor += len(value)
    return bytes(head + body)


def _encode_core_commitment(config: dict[str, Any], grants: list[dict[str, Any]]) -> bytes:
    return _encode_dynamic_arguments((_encode_core_config(config), _encode_grants(grants)))


def _encode_flm_config(config: dict[str, Any]) -> bytes:
    dependency = config["positionManager"]
    return _address_word(dependency["target"]) + bytes.fromhex(
        dependency["runtimeCodeKeccak256"][2:]
    )


def _encode_deploy_core(
    config: dict[str, Any], grants: list[dict[str, Any]], codes: tuple[bytes, ...]
) -> bytes:
    return bytes.fromhex(DEPLOY_CORE_SELECTOR) + _encode_dynamic_arguments(
        (_encode_core_config(config), _encode_grants(grants), _encode_bytes_array(codes))
    )


def _encode_deploy_flm(config: dict[str, Any], codes: tuple[bytes, ...]) -> bytes:
    encoded_config = _encode_flm_config(config)
    return (
        bytes.fromhex(DEPLOY_FLM_SELECTOR)
        + encoded_config
        + _word(len(encoded_config) + 32)
        + _encode_bytes_array(codes)
    )


def _decode_address_word(value: bytes, offset: int, name: str) -> str:
    if offset < 0 or offset + 32 > len(value) or any(value[offset : offset + 12]):
        raise ManifestError(f"{name} is not an encoded address")
    return "0x" + value[offset + 12 : offset + 32].hex()


def _decode_hash_word(value: bytes, offset: int, name: str) -> str:
    if offset < 0 or offset + 32 > len(value):
        raise ManifestError(f"{name} is truncated")
    return "0x" + value[offset : offset + 32].hex()


def _decode_string(value: bytes, head_offset: int, name: str) -> str:
    start = _word_uint(value, head_offset, f"{name} offset")
    if start % 32 or start + 32 > len(value):
        raise ManifestError(f"{name} offset is malformed")
    length = _word_uint(value, start, f"{name} length")
    content_start = start + 32
    content_end = content_start + length
    padded_end = content_start + ((length + 31) // 32) * 32
    if padded_end > len(value) or any(value[content_end:padded_end]):
        raise ManifestError(f"{name} is truncated or has nonzero padding")
    try:
        return value[content_start:content_end].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ManifestError(f"{name} is not UTF-8") from exc


def _decode_core_config(value: bytes) -> dict[str, Any]:
    if len(value) < 39 * 32 or len(value) % 32:
        raise ManifestError("encoded CoreConfig is malformed")
    config: dict[str, Any] = {}
    word = 0
    for key in CORE_DEPENDENCY_KEYS:
        config[key] = {
            "target": _decode_address_word(value, word * 32, f"CoreConfig.{key}.target"),
            "runtimeCodeKeccak256": _decode_hash_word(
                value, (word + 1) * 32, f"CoreConfig.{key}.codehash"
            ),
        }
        word += 2
    for key in (
        "graduationThreshold",
        "arbitrationTimeout",
        "siteMinActivationBond",
        "treasuryMinActivationBond",
        "twapTimeout",
        "twapWindow",
        "spaceSaltNonce",
    ):
        config[key] = _word_uint(value, word * 32, f"CoreConfig.{key}")
        word += 1
    for key in (
        "daoURI",
        "metadataURI",
        "votingStrategyMetadataURI",
        "proposalValidationStrategyMetadataURI",
        "tokenName",
        "tokenSymbol",
    ):
        config[key] = _decode_string(value, word * 32, f"CoreConfig.{key}")
        word += 1
    for key in (
        "saleEnd",
        "bootstrapDeadline",
        "saleCap",
        "minimumRaise",
        "tokenMaxSupply",
        "initialPrice",
        "slope",
        "bootstrapBps",
    ):
        config[key] = _word_uint(value, word * 32, f"CoreConfig.{key}")
        word += 1
    if _encode_core_config(config) != value:
        raise ManifestError("CoreConfig ABI encoding is not canonical")
    return config


def _decode_grants(value: bytes) -> list[dict[str, Any]]:
    count = _word_uint(value, 0, "GrantConfig[] length")
    if len(value) != 32 + count * 128:
        raise ManifestError("GrantConfig[] ABI encoding is malformed")
    grants = []
    for index in range(count):
        offset = 32 + index * 128
        grants.append(
            {
                "beneficiary": _decode_address_word(
                    value, offset, f"GrantConfig[{index}].beneficiary"
                ),
                "start": _word_uint(value, offset + 32, f"GrantConfig[{index}].start"),
                "duration": _word_uint(value, offset + 64, f"GrantConfig[{index}].duration"),
                "amount": _word_uint(value, offset + 96, f"GrantConfig[{index}].amount"),
            }
        )
    return grants


def _decode_deploy_core(calldata: bytes) -> tuple[dict[str, Any], list[dict[str, Any]], tuple[bytes, ...]]:
    if len(calldata) < 4 + 96 or calldata[:4].hex() != DEPLOY_CORE_SELECTOR:
        raise ManifestError("broadcast deployCore calldata has the wrong selector")
    args = calldata[4:]
    offsets = [_word_uint(args, index * 32, f"deployCore argument {index} offset") for index in range(3)]
    if offsets[0] != 96 or any(offset % 32 for offset in offsets) or offsets != sorted(offsets):
        raise ManifestError("deployCore dynamic argument offsets are not canonical")
    if offsets[2] >= len(args):
        raise ManifestError("deployCore dynamic arguments are truncated")
    config = _decode_core_config(args[offsets[0] : offsets[1]])
    grants = _decode_grants(args[offsets[1] : offsets[2]])
    codes = _decode_bytes_array_argument(calldata, 64, len(CORE_BLOBS))
    if _encode_deploy_core(config, grants, codes) != calldata:
        raise ManifestError("deployCore calldata is not canonical")
    return config, grants, codes


def _decode_deploy_flm(calldata: bytes) -> tuple[dict[str, Any], tuple[bytes, ...]]:
    if len(calldata) < 4 + 96 or calldata[:4].hex() != DEPLOY_FLM_SELECTOR:
        raise ManifestError("broadcast deployFlm calldata has the wrong selector")
    args = calldata[4:]
    config = {
        "positionManager": {
            "target": _decode_address_word(args, 0, "FlmConfig.positionManager.target"),
            "runtimeCodeKeccak256": _decode_hash_word(
                args, 32, "FlmConfig.positionManager.codehash"
            ),
        }
    }
    codes = _decode_bytes_array_argument(calldata, 64, len(FLM_BLOBS))
    if _encode_deploy_flm(config, codes) != calldata:
        raise ManifestError("deployFlm calldata is not canonical")
    return config, codes


def _validate_config_preimages(manifest: dict[str, Any]) -> tuple[dict[str, Any], list[dict[str, Any]], dict[str, Any]]:
    core = _require_dict(manifest["coreConfig"], "coreConfig")
    if tuple(core) != CORE_CONFIG_KEYS:
        raise ManifestError("coreConfig is not in canonical Solidity field order")
    for key in CORE_DEPENDENCY_KEYS:
        _dependency(core[key], f"coreConfig.{key}")
    uint256_keys = (
        "graduationThreshold",
        "arbitrationTimeout",
        "siteMinActivationBond",
        "treasuryMinActivationBond",
        "spaceSaltNonce",
        "saleCap",
        "minimumRaise",
        "tokenMaxSupply",
        "initialPrice",
        "slope",
    )
    for key in uint256_keys:
        _uint(core[key], 256, f"coreConfig.{key}")
    for key in ("twapTimeout", "twapWindow"):
        _uint(core[key], 32, f"coreConfig.{key}")
    for key in ("saleEnd", "bootstrapDeadline"):
        _uint(core[key], 64, f"coreConfig.{key}")
    _uint(core["bootstrapBps"], 16, "coreConfig.bootstrapBps")
    for key in (
        "daoURI",
        "metadataURI",
        "votingStrategyMetadataURI",
        "proposalValidationStrategyMetadataURI",
        "tokenName",
        "tokenSymbol",
    ):
        if not isinstance(core[key], str):
            raise ManifestError(f"coreConfig.{key} must be a string")

    raw_grants = _require_list(manifest["grants"], "grants")
    if len(raw_grants) > 32:
        raise ManifestError("grants exceeds the vault maximum")
    grants = []
    for index, raw in enumerate(raw_grants):
        grant = _require_dict(raw, f"grants[{index}]")
        if tuple(grant) != GRANT_KEYS:
            raise ManifestError(f"grants[{index}] is not in canonical Solidity field order")
        _canonical_address(grant["beneficiary"], f"grants[{index}].beneficiary")
        _uint(grant["start"], 64, f"grants[{index}].start")
        _uint(grant["duration"], 64, f"grants[{index}].duration")
        _uint(grant["amount"], 256, f"grants[{index}].amount")
        grants.append(grant)

    flm = _require_dict(manifest["flmConfig"], "flmConfig")
    if tuple(flm) != FLM_CONFIG_KEYS:
        raise ManifestError("flmConfig is not in canonical Solidity field order")
    _dependency(flm["positionManager"], "flmConfig.positionManager")
    return core, grants, flm


def _dependencies(manifest: dict[str, Any]) -> dict[str, dict[str, str]]:
    return {
        **{key: manifest["coreConfig"][key] for key in CORE_DEPENDENCY_KEYS},
        "positionManager": manifest["flmConfig"]["positionManager"],
    }


def validate_manifest(
    raw: Any, *, hash_: Callable[[bytes], str] = flm_code_hashes.keccak256
) -> dict[str, Any]:
    manifest = _require_dict(raw, "economic deployment manifest")
    _expect_keys(manifest, MANIFEST_KEYS, "economic deployment manifest")
    if (
        _json_integer(manifest["schemaVersion"], "schemaVersion") != 1
        or manifest["network"] != "sepolia"
        or _json_integer(manifest["chainId"], "chainId") != CHAIN_ID
        or manifest["status"] not in {"sealed", "live"}
    ):
        raise ManifestError("manifest must be sealed/live Sepolia schema version 1")
    expected_core, expected_flm, canonical_creations = _canonical_blob_hashes()

    transactions = _require_dict(manifest["transactions"], "transactions")
    _expect_keys(transactions, ("receiptCreate", "deployCore", "deployFlm"), "transactions")
    ordered_transactions = [
        _transaction(transactions[name], f"transactions.{name}")
        for name in ("receiptCreate", "deployCore", "deployFlm")
    ]
    if len({item["hash"] for item in ordered_transactions}) != 3:
        raise ManifestError("staged transaction hashes must be unique")
    if [item["block"] for item in ordered_transactions] != sorted(
        item["block"] for item in ordered_transactions
    ):
        raise ManifestError("staged transaction blocks are out of order")

    receipt = _require_dict(manifest["receipt"], "receipt")
    _expect_keys(
        receipt,
        (
            "address",
            "source",
            "contract",
            "createNonce",
            "creationCodeBytes",
            "creationCodeKeccak256",
            "coreConfigHash",
            "flmConfigHash",
        ),
        "receipt",
    )
    receipt_address = _canonical_address(receipt["address"], "receipt.address")
    if receipt["source"] != RECEIPT_SOURCE or receipt["contract"] != RECEIPT_CONTRACT:
        raise ManifestError("receipt has the wrong compiler identity")
    create_nonce = _json_integer(receipt["createNonce"], "receipt.createNonce")
    if create_nonce < 0 or create_nonce >= 1 << 64:
        raise ManifestError("receipt.createNonce is outside the Ethereum account nonce range")
    if create_nonce != ordered_transactions[0]["nonce"]:
        raise ManifestError("receipt CREATE nonce is inconsistent")
    if _json_integer(receipt["creationCodeBytes"], "receipt.creationCodeBytes") <= 0:
        raise ManifestError("receipt creation code cannot be empty")
    for key in ("creationCodeKeccak256", "coreConfigHash", "flmConfigHash"):
        _canonical_hash(receipt[key], f"receipt.{key}")
    if receipt["coreConfigHash"] == "0x" + "00" * 32 or receipt["flmConfigHash"] == "0x" + "00" * 32:
        raise ManifestError("receipt config commitments cannot be zero")
    if (
        receipt["creationCodeBytes"] != canonical_creations["receipt"]["bytes"]
        or receipt["creationCodeKeccak256"] != canonical_creations["receipt"]["hash"]
    ):
        raise ManifestError("receipt creation code does not match canonical compiler evidence")

    core_config, grants, flm_config = _validate_config_preimages(manifest)
    dependencies = _dependencies(manifest)
    expected_core_hash = _digest(_encode_core_commitment(core_config, grants), hash_)
    expected_flm_hash = _digest(_encode_flm_config(flm_config), hash_)
    if receipt["coreConfigHash"] != expected_core_hash:
        raise ManifestError("receipt.coreConfigHash does not commit the disclosed coreConfig/grants")
    if receipt["flmConfigHash"] != expected_flm_hash:
        raise ManifestError("receipt.flmConfigHash does not commit the disclosed flmConfig")
    pinned_targets = {
        **SX_PINS,
        "weth": (flm_deployment.WETH, flm_deployment.PINNED_CODEHASHES["weth"]),
        "conditionalTokens": (
            flm_deployment.CTF,
            flm_deployment.PINNED_CODEHASHES["conditionalTokens"],
        ),
        "wrapped1155Factory": (
            flm_deployment.WRAPPED_1155_FACTORY,
            flm_deployment.PINNED_CODEHASHES["wrapped1155Factory"],
        ),
        "uniswapV3Factory": (
            flm_deployment.UNIV3_FACTORY,
            flm_deployment.PINNED_CODEHASHES["univ3Factory"],
        ),
        "positionManager": (
            flm_deployment.POSITION_MANAGER,
            flm_deployment.PINNED_CODEHASHES["positionManager"],
        ),
    }
    for key, (target, codehash) in pinned_targets.items():
        if dependencies[key]["target"] != target:
            raise ManifestError(f"configured {key} is not the pinned Sepolia deployment")
        if dependencies[key]["runtimeCodeKeccak256"] != codehash:
            raise ManifestError(f"configured {key} does not use the pinned runtime code hash")

    prerequisites = _require_dict(manifest["prerequisites"], "prerequisites")
    if tuple(prerequisites) != tuple(PREREQUISITES):
        raise ManifestError("prerequisites are not in canonical order")
    prerequisite_transactions = []
    for key in PREREQUISITES:
        item = _prerequisite(prerequisites[key], f"prerequisites.{key}", key)
        dependency = dependencies[key]
        if (
            item["address"] != dependency["target"]
            or item["runtimeCodeKeccak256"] != dependency["runtimeCodeKeccak256"]
        ):
            raise ManifestError(f"prerequisites.{key} does not bind its CoreConfig dependency")
        if (
            item["creationCodeBytes"] != canonical_creations[key]["bytes"]
            or item["creationCodeKeccak256"] != canonical_creations[key]["hash"]
        ):
            raise ManifestError(f"prerequisites.{key} does not match canonical compiler evidence")
        prerequisite_transactions.append(item["transaction"])
    all_transactions = [*prerequisite_transactions, *ordered_transactions]
    if len({item["hash"] for item in all_transactions}) != len(all_transactions):
        raise ManifestError("deployment and prerequisite transaction hashes must be unique")
    if any(item["block"] > ordered_transactions[0]["block"] for item in prerequisite_transactions):
        raise ManifestError("prerequisite CREATE transaction postdates the receipt CREATE")
    if _json_integer(manifest["feeTier"], "feeTier") != FEE_TIER:
        raise ManifestError(f"feeTier must be {FEE_TIER}")
    if _canonical_hash(manifest["poolInitCodeHash"], "poolInitCodeHash") != POOL_INIT_CODE_HASH:
        raise ManifestError("poolInitCodeHash is not canonical Uniswap V3")
    if (
        _json_integer(manifest["observationCardinality"], "observationCardinality")
        != OBSERVATION_CARDINALITY
    ):
        raise ManifestError("observationCardinality is not canonical")

    contracts = _require_dict(manifest["contracts"], "contracts")
    if tuple(contracts) != CONTRACT_KEYS:
        raise ManifestError("contracts are not in canonical order")
    addresses = []
    for key in CONTRACT_KEYS[:-1]:
        addresses.append(_canonical_address(contracts[key], f"contracts.{key}"))
    wallets = _require_list(contracts["vestingWallets"], "contracts.vestingWallets")
    if len(wallets) != len(grants):
        raise ManifestError("vestingWallets length does not match the disclosed grants")
    addresses.extend(
        _canonical_address(value, f"contracts.vestingWallets[{index}]")
        for index, value in enumerate(wallets)
    )
    addresses.append(receipt_address)
    if len(set(addresses)) != len(addresses):
        raise ManifestError("receipt and deployed contract addresses must be unique")

    code_blobs = _require_dict(manifest["codeBlobs"], "codeBlobs")
    _expect_keys(code_blobs, ("core", "flm"), "codeBlobs")
    for section_name, keys, expected in (
        ("core", CORE_BLOBS, expected_core),
        ("flm", FLM_BLOBS, expected_flm),
    ):
        section = _require_dict(code_blobs[section_name], f"codeBlobs.{section_name}")
        if tuple(section) != keys:
            raise ManifestError(f"codeBlobs.{section_name} is not in canonical order")
        for key in keys:
            if _canonical_hash(section[key], f"codeBlobs.{section_name}.{key}") != expected[key]:
                raise ManifestError(f"codeBlobs.{section_name}.{key} is not canonical")

    finalization = manifest["finalization"]
    if manifest["status"] == "sealed":
        if finalization is not None:
            raise ManifestError("a sealed manifest cannot contain finalization evidence")
    else:
        finalization = _transaction(finalization, "finalization")
        if finalization["hash"] in {item["hash"] for item in all_transactions}:
            raise ManifestError("finalization transaction hash must be unique")
        if finalization["block"] < ordered_transactions[-1]["block"]:
            raise ManifestError("finalization predates staged deployment")
    return manifest


def _digest(value: bytes, hash_: Callable[[bytes], str]) -> str:
    return _canonical_hash(hash_(value), "Keccak-256 digest")


def _create_address(sender: str, nonce: int, hash_: Callable[[bytes], str]) -> str:
    if nonce < 0 or nonce >= 1 << 64:
        raise ManifestError("CREATE nonce is outside the Ethereum account nonce range")
    encoded_nonce = b"\x80" if nonce == 0 else nonce.to_bytes((nonce.bit_length() + 7) // 8, "big")
    if nonce >= 0x80:
        encoded_nonce = bytes([0x80 + len(encoded_nonce)]) + encoded_nonce
    payload = b"\x94" + bytes.fromhex(_address(sender, "CREATE sender")[2:]) + encoded_nonce
    digest = _digest(bytes([0xC0 + len(payload)]) + payload, hash_)
    return "0x" + digest[-40:]


def _pool_address(factory: str, token_a: str, token_b: str, hash_: Callable[[bytes], str]) -> str:
    token0, token1 = sorted((token_a, token_b))
    salt = bytes.fromhex(
        _digest(
            bytes(12) + bytes.fromhex(token0[2:])
            + bytes(12) + bytes.fromhex(token1[2:])
            + FEE_TIER.to_bytes(32, "big"),
            hash_,
        )[2:]
    )
    digest = _digest(
        b"\xff"
        + bytes.fromhex(factory[2:])
        + salt
        + bytes.fromhex(POOL_INIT_CODE_HASH[2:]),
        hash_,
    )
    return "0x" + digest[-40:]


def _decode_bytes_array_argument(calldata: bytes, head_offset: int, expected: int) -> tuple[bytes, ...]:
    if len(calldata) < 4 or (len(calldata) - 4) % 32:
        raise ManifestError("staged call calldata is malformed")
    args = calldata[4:]
    array_start = _word_uint(args, head_offset, "bytes[] offset")
    if array_start % 32 or array_start + 32 > len(args):
        raise ManifestError("bytes[] offset is malformed")
    count = _word_uint(args, array_start, "bytes[] length")
    if count != expected:
        raise ManifestError(f"staged call must contain {expected} code blobs")
    base = array_start + 32
    cursor = count * 32
    values = []
    for index in range(count):
        offset = _word_uint(args, base + index * 32, f"bytes[{index}] offset")
        if offset != cursor:
            raise ManifestError("bytes[] uses non-canonical offsets")
        position = base + offset
        length = _word_uint(args, position, f"bytes[{index}] length")
        start = position + 32
        end = start + length
        padded_end = start + ((length + 31) // 32) * 32
        if padded_end > len(args) or any(args[end:padded_end]):
            raise ManifestError(f"bytes[{index}] is truncated or has nonzero padding")
        values.append(args[start:end])
        cursor = padded_end - base
    if base + cursor != len(args):
        raise ManifestError("staged bytes[] has trailing bytes")
    return tuple(values)


class CastClient(flm_deployment.CastClient):
    def call(self, address: str, signature: str, *args: str) -> str:
        return self._run("call", address, signature, *args)


def _call(client: Any, address: str, signature: str, *args: str) -> str:
    return client.call(address, signature, *args)


def _call_address(client: Any, address: str, signature: str, *args: str) -> str:
    return _hex(
        _call(client, address, signature, *args).split()[0],
        20,
        f"{address}.{signature}",
    )


def _call_hash(client: Any, address: str, signature: str, *args: str) -> str:
    return _hex(_call(client, address, signature, *args).split()[0], 32, f"{address}.{signature}")


def _call_int(client: Any, address: str, signature: str, *args: str) -> int:
    raw = _call(client, address, signature, *args).split()[0]
    try:
        return int(raw, 0)
    except ValueError as exc:
        raise ManifestError(f"{address}.{signature} returned a non-integer") from exc


def _call_bool(client: Any, address: str, signature: str, *args: str) -> bool:
    raw = _call(client, address, signature, *args).strip().lower()
    if raw not in {"true", "false"}:
        raise ManifestError(f"{address}.{signature} returned a non-bool")
    return raw == "true"


def _live_transaction(
    client: Any,
    value: dict[str, Any],
    target: str | None,
    name: str,
    created: str | None = None,
) -> bytes:
    tx_hash = value["hash"]
    tx = _require_dict(client.transaction(tx_hash), f"live {name} transaction")
    receipt = _require_dict(client.receipt(tx_hash), f"live {name} receipt")
    if (
        _hex(tx.get("hash"), 32, f"live {name}.hash") != tx_hash
        or _hex(receipt.get("transactionHash"), 32, f"live {name}.receipt hash") != tx_hash
        or _quantity(tx.get("blockNumber"), f"live {name}.block") != value["block"]
        or _quantity(receipt.get("blockNumber"), f"live {name}.receipt block") != value["block"]
        or _quantity(tx.get("nonce"), f"live {name}.nonce") != value["nonce"]
        or _address(tx.get("from"), f"live {name}.from") != value["from"]
        or _address(receipt.get("from"), f"live {name}.receipt from") != value["from"]
        or flm_deployment._live_target(tx.get("to"), f"live {name}.to") != target
        or flm_deployment._live_target(receipt.get("to"), f"live {name}.receipt to") != target
        or _quantity(receipt.get("status"), f"live {name}.status") != 1
    ):
        raise ManifestError(f"live {name} transaction evidence does not match the manifest")
    contract = flm_deployment._live_target(
        receipt.get("contractAddress"), f"live {name}.contractAddress"
    )
    if contract != created:
        raise ManifestError(f"live {name} contract address is inconsistent")
    return _variable_bytes(tx.get("input"), f"live {name}.input")


def _broadcast_records(broadcast: Any, client: Any) -> list[dict[str, Any]]:
    broadcast = _require_dict(broadcast, "economic genesis broadcast")
    if _quantity(broadcast.get("chain"), "broadcast.chain") != CHAIN_ID:
        raise ManifestError(f"broadcast chain must be Sepolia ({CHAIN_ID})")
    if _require_list(broadcast.get("pending", []), "broadcast.pending"):
        raise ManifestError("broadcast contains pending transactions")
    transactions = _require_list(broadcast.get("transactions"), "broadcast.transactions")
    if len(transactions) != 5:
        raise ManifestError("economic genesis broadcast must contain exactly five transactions")
    receipts = site_deployment._receipt_map(broadcast)
    if len(receipts) != 5:
        raise ManifestError("economic genesis broadcast must contain exactly five receipts")
    declared_hashes = [
        _hex(
            _require_dict(raw, f"broadcast.transactions[{index}]").get("hash"),
            32,
            f"broadcast.transactions[{index}].hash",
        )
        for index, raw in enumerate(transactions)
    ]
    if len(set(declared_hashes)) != 5 or set(declared_hashes) != set(receipts):
        raise ManifestError("broadcast transaction/receipt hashes are incomplete or duplicated")

    expected = ("CREATE", "CREATE", "CREATE", "CALL", "CALL")
    records = []
    used_hashes: set[str] = set()
    for index, (raw, transaction_type) in enumerate(zip(transactions, expected)):
        outer = _require_dict(raw, f"broadcast.transactions[{index}]")
        if outer.get("transactionType") != transaction_type:
            raise ManifestError(f"broadcast transaction {index} has the wrong staged identity")
        artifact_tx = _require_dict(
            outer.get("transaction"), f"broadcast.transactions[{index}].transaction"
        )
        artifact_sender = _address(
            artifact_tx.get("from"), f"broadcast transaction {index} sender"
        )
        artifact_nonce = _quantity(
            artifact_tx.get("nonce"), f"broadcast transaction {index} nonce"
        )
        artifact_target = flm_deployment._live_target(
            artifact_tx.get("to"), f"broadcast transaction {index} target"
        )
        artifact_input = _variable_bytes(
            artifact_tx.get("input"), f"broadcast transaction {index} input"
        )
        matches = []
        for candidate in declared_hashes:
            if candidate in used_hashes:
                continue
            live = _require_dict(client.transaction(candidate), f"live broadcast transaction {candidate}")
            if (
                _hex(live.get("hash"), 32, f"live broadcast transaction {candidate}.hash")
                == candidate
                and _address(live.get("from"), f"live broadcast transaction {candidate}.from")
                == artifact_sender
                and _quantity(live.get("nonce"), f"live broadcast transaction {candidate}.nonce")
                == artifact_nonce
                and flm_deployment._live_target(
                    live.get("to"), f"live broadcast transaction {candidate}.to"
                )
                == artifact_target
                and _variable_bytes(
                    live.get("input"), f"live broadcast transaction {candidate}.input"
                )
                == artifact_input
            ):
                matches.append(candidate)
        if len(matches) != 1:
            raise ManifestError(
                f"broadcast transaction {index} does not match exactly one live transaction"
            )
        tx_hash = matches[0]
        used_hashes.add(tx_hash)
        receipt = receipts.get(tx_hash)
        if receipt is None or not site_deployment._is_success(receipt):
            raise ManifestError(f"broadcast transaction {index} has no successful receipt")
        sender = artifact_sender
        nonce = artifact_nonce
        block = _quantity(receipt.get("blockNumber"), f"broadcast transaction {index} block")
        target = artifact_target
        created = flm_deployment._live_target(
            receipt.get("contractAddress"), f"broadcast transaction {index} created contract"
        )
        declared_contract = flm_deployment._live_target(
            outer.get("contractAddress"), f"broadcast transaction {index} declared contract"
        )
        if (
            _address(receipt.get("from"), f"broadcast transaction {index} receipt sender") != sender
            or flm_deployment._live_target(
                receipt.get("to"), f"broadcast transaction {index} receipt target"
            )
            != target
        ):
            raise ManifestError(f"broadcast transaction {index} receipt provenance is inconsistent")
        is_create = transaction_type == "CREATE"
        if (is_create and (target is not None or created is None or declared_contract != created)) or (
            not is_create
            and (target is None or created is not None or declared_contract != target)
        ):
            raise ManifestError(f"broadcast transaction {index} CREATE/CALL provenance is inconsistent")
        records.append(
            {
                "evidence": {"hash": tx_hash, "block": block, "nonce": nonce, "from": sender},
                "input": artifact_input,
                "target": target,
                "created": created,
            }
        )
    senders = {record["evidence"]["from"] for record in records}
    nonces = [record["evidence"]["nonce"] for record in records]
    blocks = [record["evidence"]["block"] for record in records]
    if len(senders) != 1 or nonces != list(range(nonces[0], nonces[0] + 5)):
        raise ManifestError("broadcast must use one deployer and five consecutive nonces")
    if blocks != sorted(blocks):
        raise ManifestError("broadcast transaction blocks are out of order")
    if records[3]["target"] != records[2]["created"] or records[4]["target"] != records[2]["created"]:
        raise ManifestError("staged calls do not target the created receipt")
    if records[3]["input"][:4].hex() != DEPLOY_CORE_SELECTOR or records[4]["input"][:4].hex() != DEPLOY_FLM_SELECTOR:
        raise ManifestError("staged receipt calls are out of order")
    return records


def manifest_from_broadcast(
    broadcast: Any,
    receipt_creation_code: bytes,
    prerequisite_creation_codes: dict[str, bytes],
    client: Any,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    records = _broadcast_records(broadcast, client)
    proposal, stack, receipt_create, deploy_core, deploy_flm = records
    receipt_address = receipt_create["created"]
    if receipt_address != _create_address(
        receipt_create["evidence"]["from"], receipt_create["evidence"]["nonce"], hash_
    ):
        raise ManifestError("broadcast receipt address does not match its CREATE nonce")

    if set(prerequisite_creation_codes) != set(PREREQUISITES):
        raise ManifestError("broadcast prerequisite compiler evidence is incomplete")
    prerequisite_records = {
        "proposalImplementation": proposal,
        "stackDeployer": stack,
    }
    prerequisites = {}
    for key, record in prerequisite_records.items():
        source, contract, constructor_args = PREREQUISITES[key]
        creation = prerequisite_creation_codes[key]
        if record["input"] != creation + constructor_args or record["created"] != _create_address(
            record["evidence"]["from"], record["evidence"]["nonce"], hash_
        ):
            raise ManifestError(f"broadcast prerequisite {key} does not match compiler evidence")
        runtime = client.code(record["created"])
        if not runtime:
            raise ManifestError(f"broadcast prerequisite {key} has no runtime code")
        prerequisites[key] = {
            "address": record["created"],
            "source": source,
            "contract": contract,
            "transaction": record["evidence"],
            "creationCodeBytes": len(creation),
            "creationCodeKeccak256": _digest(creation, hash_),
            "runtimeCodeBytes": len(runtime),
            "runtimeCodeKeccak256": _digest(runtime, hash_),
        }

    expected_receipt_input_bytes = len(receipt_creation_code) + 64
    if len(receipt_create["input"]) != expected_receipt_input_bytes or not receipt_create[
        "input"
    ].startswith(receipt_creation_code):
        raise ManifestError("broadcast receipt CREATE does not match compiler evidence")
    commitment = receipt_create["input"][-64:]
    core_config_hash = "0x" + commitment[:32].hex()
    flm_config_hash = "0x" + commitment[32:].hex()

    core_config, grants, core_codes = _decode_deploy_core(deploy_core["input"])
    flm_config, flm_codes = _decode_deploy_flm(deploy_flm["input"])
    getter_keys = CONTRACT_KEYS[:-1]
    contracts = {
        key: _call_address(client, receipt_address, f"{key}()(address)") for key in getter_keys
    }
    contracts["vestingWallets"] = [
        _create_address(contracts["vault"], index, hash_)
        for index in range(1, len(grants) + 1)
    ]

    core_hashes = {
        key: _digest(code, hash_) for key, code in zip(CORE_BLOBS, core_codes)
    }
    flm_hashes = {key: _digest(code, hash_) for key, code in zip(FLM_BLOBS, flm_codes)}
    manifest = {
        "schemaVersion": 1,
        "status": "sealed",
        "network": "sepolia",
        "chainId": CHAIN_ID,
        "transactions": {
            "receiptCreate": receipt_create["evidence"],
            "deployCore": deploy_core["evidence"],
            "deployFlm": deploy_flm["evidence"],
        },
        "receipt": {
            "address": receipt_address,
            "source": RECEIPT_SOURCE,
            "contract": RECEIPT_CONTRACT,
            "createNonce": receipt_create["evidence"]["nonce"],
            "creationCodeBytes": len(receipt_creation_code),
            "creationCodeKeccak256": _digest(receipt_creation_code, hash_),
            "coreConfigHash": core_config_hash,
            "flmConfigHash": flm_config_hash,
        },
        "prerequisites": prerequisites,
        "coreConfig": core_config,
        "grants": grants,
        "flmConfig": flm_config,
        "feeTier": FEE_TIER,
        "poolInitCodeHash": POOL_INIT_CODE_HASH,
        "observationCardinality": OBSERVATION_CARDINALITY,
        "contracts": contracts,
        "codeBlobs": {"core": core_hashes, "flm": flm_hashes},
        "finalization": None,
    }
    verify_rpc(
        manifest,
        receipt_creation_code,
        prerequisite_creation_codes,
        client,
        hash_=hash_,
    )
    return manifest


def finalization_hash_from_broadcast(broadcast: Any, vault: str, client: Any) -> str:
    broadcast = _require_dict(broadcast, "economic operation broadcast")
    if _quantity(broadcast.get("chain"), "operation broadcast.chain") != CHAIN_ID:
        raise ManifestError(f"operation broadcast chain must be Sepolia ({CHAIN_ID})")
    if _require_list(broadcast.get("pending", []), "operation broadcast.pending"):
        raise ManifestError("operation broadcast contains pending transactions")
    transactions = _require_list(
        broadcast.get("transactions"), "operation broadcast.transactions"
    )
    candidates = [
        _hex(
            _require_dict(raw, f"operation transaction {index}").get("hash"),
            32,
            f"operation transaction {index}.hash",
        )
        for index, raw in enumerate(transactions)
    ]
    if len(set(candidates)) != len(candidates):
        raise ManifestError("operation broadcast hashes are duplicated")
    finalizations = []
    for index, raw in enumerate(transactions):
        outer = _require_dict(raw, f"operation transaction {index}")
        tx = _require_dict(outer.get("transaction"), f"operation transaction {index}.transaction")
        input_ = _variable_bytes(tx.get("input"), f"operation transaction {index}.input")
        target = flm_deployment._live_target(
            tx.get("to"), f"operation transaction {index}.target"
        )
        if target == vault and input_.hex() == FINALIZE_SELECTOR:
            finalizations.append(tx)
    if len(finalizations) != 1:
        raise ManifestError("operation broadcast must contain exactly one GenesisVault.finalize()")

    expected = finalizations[0]
    sender = _address(expected.get("from"), "operation finalization sender")
    nonce = _quantity(expected.get("nonce"), "operation finalization nonce")
    matches = []
    for candidate in candidates:
        live = _require_dict(client.transaction(candidate), f"live operation transaction {candidate}")
        if (
            _address(live.get("from"), f"live operation transaction {candidate}.from") == sender
            and _quantity(live.get("nonce"), f"live operation transaction {candidate}.nonce") == nonce
            and flm_deployment._live_target(
                live.get("to"), f"live operation transaction {candidate}.to"
            )
            == vault
            and _variable_bytes(
                live.get("input"), f"live operation transaction {candidate}.input"
            ).hex()
            == FINALIZE_SELECTOR
        ):
            matches.append(candidate)
    if len(matches) != 1:
        raise ManifestError("operation finalization does not match exactly one live transaction")
    return matches[0]


def promote_live(
    raw: Any,
    finalization_hash: str,
    receipt_creation_code: bytes,
    prerequisite_creation_codes: dict[str, bytes],
    client: Any,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    manifest = validate_manifest(raw, hash_=hash_)
    if manifest["status"] != "sealed":
        raise ManifestError("only a sealed economic manifest can be promoted to LIVE")
    tx_hash = _canonical_hash(finalization_hash, "finalization hash")
    tx = _require_dict(client.transaction(tx_hash), "live finalization transaction")
    receipt = _require_dict(client.receipt(tx_hash), "live finalization receipt")
    evidence = {
        "hash": tx_hash,
        "block": _quantity(receipt.get("blockNumber"), "finalization block"),
        "nonce": _quantity(tx.get("nonce"), "finalization nonce"),
        "from": _address(tx.get("from"), "finalization sender"),
    }
    live = {**manifest, "status": "live", "finalization": evidence}
    verify_rpc(
        live,
        receipt_creation_code,
        prerequisite_creation_codes,
        client,
        hash_=hash_,
    )
    return live


def _verify_prerequisites(
    manifest: dict[str, Any],
    client: Any,
    creation_codes: dict[str, bytes],
    hash_: Callable[[bytes], str],
) -> None:
    if set(creation_codes) != set(PREREQUISITES):
        raise ManifestError("local prerequisite compiler evidence is incomplete")
    for key, (_, _, constructor_args) in PREREQUISITES.items():
        item = manifest["prerequisites"][key]
        transaction = item["transaction"]
        code = creation_codes[key]
        if (
            len(code) != item["creationCodeBytes"]
            or _digest(code, hash_) != item["creationCodeKeccak256"]
        ):
            raise ManifestError(f"local compiler creation code mismatch for {key}")
        if item["address"] != _create_address(transaction["from"], transaction["nonce"], hash_):
            raise ManifestError(f"prerequisites.{key} has the wrong CREATE address")
        live_input = _live_transaction(
            client,
            transaction,
            None,
            f"prerequisite {key}",
            item["address"],
        )
        if live_input != code + constructor_args:
            raise ManifestError(f"prerequisites.{key} CREATE input mismatches compiler evidence")
        runtime = client.code(item["address"])
        if (
            len(runtime) != item["runtimeCodeBytes"]
            or _digest(runtime, hash_) != item["runtimeCodeKeccak256"]
        ):
            raise ManifestError(f"prerequisites.{key} runtime evidence mismatch")


def _verify_transactions(
    manifest: dict[str, Any], client: Any, receipt_creation_code: bytes, hash_: Callable[[bytes], str]
) -> None:
    transactions = manifest["transactions"]
    receipt = manifest["receipt"]
    receipt_address = receipt["address"]

    create_input = _live_transaction(
        client,
        transactions["receiptCreate"],
        None,
        "receiptCreate",
        receipt_address,
    )
    live_receipt = client.receipt(transactions["receiptCreate"]["hash"])
    if _address(live_receipt.get("contractAddress"), "receipt contract") != receipt_address:
        raise ManifestError("receipt CREATE address does not match the manifest")
    if receipt_address != _create_address(
        transactions["receiptCreate"]["from"], receipt["createNonce"], hash_
    ):
        raise ManifestError("receipt address is not the declared deployer CREATE nonce")
    if (
        len(receipt_creation_code) != receipt["creationCodeBytes"]
        or _digest(receipt_creation_code, hash_) != receipt["creationCodeKeccak256"]
    ):
        raise ManifestError("receipt compiler creation code does not match the manifest")
    expected_create = receipt_creation_code + bytes.fromhex(
        receipt["coreConfigHash"][2:] + receipt["flmConfigHash"][2:]
    )
    if create_input != expected_create:
        raise ManifestError("receipt CREATE input does not bind the declared config commitments")

    core_input = _live_transaction(client, transactions["deployCore"], receipt_address, "deployCore")
    flm_input = _live_transaction(client, transactions["deployFlm"], receipt_address, "deployFlm")
    if core_input[:4].hex() != DEPLOY_CORE_SELECTOR:
        raise ManifestError("deployCore has the wrong selector")
    if flm_input[:4].hex() != DEPLOY_FLM_SELECTOR:
        raise ManifestError("deployFlm has the wrong selector")
    core_codes = _decode_bytes_array_argument(core_input, 64, len(CORE_BLOBS))
    flm_codes = _decode_bytes_array_argument(flm_input, 64, len(FLM_BLOBS))
    for codes, keys, expected, name in (
        (core_codes, CORE_BLOBS, manifest["codeBlobs"]["core"], "core"),
        (flm_codes, FLM_BLOBS, manifest["codeBlobs"]["flm"], "flm"),
    ):
        for index, (code, key) in enumerate(zip(codes, keys)):
            if not code or _digest(code, hash_) != expected[key]:
                raise ManifestError(f"{name} code blob {index} ({key}) is not canonical")
    if core_input != _encode_deploy_core(manifest["coreConfig"], manifest["grants"], core_codes):
        raise ManifestError("deployCore calldata does not match the disclosed config/grants")
    if flm_input != _encode_deploy_flm(manifest["flmConfig"], flm_codes):
        raise ManifestError("deployFlm calldata does not match the disclosed config")

    if manifest["finalization"] is not None:
        finalize_input = _live_transaction(
            client, manifest["finalization"], manifest["contracts"]["vault"], "finalization"
        )
        if finalize_input.hex() != FINALIZE_SELECTOR:
            raise ManifestError("finalization transaction is not GenesisVault.finalize()")


def _verify_addresses(manifest: dict[str, Any], client: Any, hash_: Callable[[bytes], str]) -> None:
    receipt = manifest["receipt"]["address"]
    contracts = manifest["contracts"]
    dependencies = _dependencies(manifest)
    for name, nonce in (*CORE_CHILDREN, *FLM_CHILDREN):
        if contracts[name] != _create_address(receipt, nonce, hash_):
            raise ManifestError(f"contracts.{name} is not receipt CREATE nonce {nonce}")
    vault = contracts["vault"]
    for index, wallet in enumerate(contracts["vestingWallets"], start=1):
        if wallet != _create_address(vault, index, hash_):
            raise ManifestError(f"vesting wallet is not vault CREATE nonce {index}")
    if contracts["companyToken"] != _create_address(
        vault, len(contracts["vestingWallets"]) + 1, hash_
    ):
        raise ManifestError("company token is not the vault CREATE after grant wallets")

    salt = _digest(
        bytes.fromhex(receipt[2:])
        + manifest["coreConfig"]["spaceSaltNonce"].to_bytes(32, "big"),
        hash_,
    )
    predicted_space = _call_address(
        client,
        dependencies["proxyFactory"]["target"],
        "predictProxyAddress(address,bytes32)(address)",
        dependencies["spaceImplementation"]["target"],
        salt,
    )
    if predicted_space != contracts["space"]:
        raise ManifestError("Snapshot X Space does not match its factory prediction")

    pool = _pool_address(
        dependencies["uniswapV3Factory"]["target"],
        contracts["companyToken"],
        dependencies["weth"]["target"],
        hash_,
    )
    if pool != contracts["spotPool"]:
        raise ManifestError("spotPool is not the canonical fee-500 Uniswap V3 prediction")


def _verify_code_and_wiring(manifest: dict[str, Any], client: Any, hash_: Callable[[bytes], str]) -> None:
    receipt = manifest["receipt"]["address"]
    c = manifest["contracts"]
    dependencies = _dependencies(manifest)
    d = {key: item["target"] for key, item in dependencies.items()}

    if not client.code(receipt):
        raise ManifestError("receipt has no deployed code")
    for key, dependency in dependencies.items():
        code = client.code(dependency["target"])
        if not code or _digest(code, hash_) != dependency["runtimeCodeKeccak256"]:
            raise ManifestError(f"dependency runtime mismatch for {key}")
    for key in CONTRACT_KEYS[:-1]:
        if key != "spotPool" and not client.code(c[key]):
            raise ManifestError(f"contracts.{key} has no deployed code")
    for index, wallet in enumerate(c["vestingWallets"]):
        if not client.code(wallet):
            raise ManifestError(f"vesting wallet {index} has no deployed code")

    if not _call_bool(client, receipt, "coreSealed()(bool)") or not _call_bool(
        client, receipt, "flmSealed()(bool)"
    ):
        raise ManifestError("receipt is not fully sealed")
    if _call_hash(client, receipt, "CORE_CONFIG_HASH()(bytes32)") != manifest["receipt"]["coreConfigHash"]:
        raise ManifestError("receipt CORE_CONFIG_HASH mismatch")
    if _call_hash(client, receipt, "FLM_CONFIG_HASH()(bytes32)") != manifest["receipt"]["flmConfigHash"]:
        raise ManifestError("receipt FLM_CONFIG_HASH mismatch")
    if (
        _call_hash(client, receipt, "uniswapV3FactoryCodehash()(bytes32)")
        != dependencies["uniswapV3Factory"]["runtimeCodeKeccak256"]
    ):
        raise ManifestError("receipt Uniswap V3 factory code-hash mismatch")

    receipt_addresses = {
        "space": c["space"],
        "arbitration": c["arbitration"],
        "vault": c["vault"],
        "companyToken": c["companyToken"],
        "proposalGateway": c["proposalGateway"],
        "releaseStrategy": c["releaseStrategy"],
        "votingStrategy": c["votingStrategy"],
        "evaluator": c["evaluator"],
        "orchestrator": c["orchestrator"],
        "resolver": c["resolver"],
        "futarchyFactory": c["futarchyFactory"],
        "weth": d["weth"],
        "conditionalTokens": d["conditionalTokens"],
        "wrapped1155Factory": d["wrapped1155Factory"],
        "uniswapV3Factory": d["uniswapV3Factory"],
        "spotPool": c["spotPool"],
        "relay": c["relay"],
        "spotAdapter": c["spotAdapter"],
        "conditionalAdapter": c["conditionalAdapter"],
        "guard": c["guard"],
        "router": c["router"],
        "manager": c["manager"],
    }
    for signature, expected in receipt_addresses.items():
        if _call_address(client, receipt, f"{signature}()(address)") != expected:
            raise ManifestError(f"receipt public wiring mismatch: {signature}")

    address_calls = (
        (c["space"], "owner()(address)", ZERO),
        (c["arbitration"], "owner()(address)", ZERO),
        (c["arbitration"], "pendingOwner()(address)", ZERO),
        (c["arbitration"], "proposalGateway()(address)", c["proposalGateway"]),
        (c["arbitration"], "evaluator()(address)", c["evaluator"]),
        (c["companyToken"], "vault()(address)", c["vault"]),
        (c["vault"], "WETH()(address)", d["weth"]),
        (c["vault"], "COMPANY_TOKEN()(address)", c["companyToken"]),
        (c["vault"], "ASSEMBLER()(address)", receipt),
        (c["vault"], "ARBITRATION()(address)", c["arbitration"]),
        (c["vault"], "BOOTSTRAP_HOOK()(address)", receipt),
        (c["vault"], "manager()(address)", c["manager"]),
        (c["proposalGateway"], "space()(address)", c["space"]),
        (c["proposalGateway"], "executionStrategy()(address)", c["releaseStrategy"]),
        (c["proposalGateway"], "arbitration()(address)", c["arbitration"]),
        (c["proposalGateway"], "vault()(address)", c["vault"]),
        (c["releaseStrategy"], "space()(address)", c["space"]),
        (c["releaseStrategy"], "arbitration()(address)", c["arbitration"]),
        (c["evaluator"], "arbitrationContract()(address)", c["arbitration"]),
        (c["evaluator"], "vault()(address)", c["vault"]),
        (c["evaluator"], "orchestrator()(address)", c["orchestrator"]),
        (c["evaluator"], "resolver()(address)", c["resolver"]),
        (c["evaluator"], "conditionalTokens()(address)", d["conditionalTokens"]),
        (c["resolver"], "CTF()(address)", d["conditionalTokens"]),
        (c["resolver"], "orchestrator()(address)", c["orchestrator"]),
        (c["futarchyFactory"], "conditionalTokens()(address)", d["conditionalTokens"]),
        (c["futarchyFactory"], "wrapped1155Factory()(address)", d["wrapped1155Factory"]),
        (c["futarchyFactory"], "oracle()(address)", c["resolver"]),
        (c["futarchyFactory"], "proposalImpl()(address)", d["proposalImplementation"]),
        (c["orchestrator"], "ADMIN()(address)", c["evaluator"]),
        (c["orchestrator"], "FACTORY()(address)", c["futarchyFactory"]),
        (c["orchestrator"], "UNIV3_FACTORY()(address)", d["uniswapV3Factory"]),
        (c["orchestrator"], "SPOT_POOL()(address)", c["spotPool"]),
        (c["orchestrator"], "COMPANY_TOKEN()(address)", c["companyToken"]),
        (c["orchestrator"], "CURRENCY_TOKEN()(address)", d["weth"]),
        (c["orchestrator"], "RESOLVER()(address)", c["resolver"]),
        (c["relay"], "MANAGER()(address)", c["manager"]),
        (c["relay"], "ARBITRATION()(address)", c["arbitration"]),
        (c["relay"], "PIPELINE()(address)", c["evaluator"]),
        (c["relay"], "UNIV3_FACTORY()(address)", d["uniswapV3Factory"]),
        (c["relay"], "CTF()(address)", d["conditionalTokens"]),
        (c["relay"], "COMPANY_TOKEN()(address)", c["companyToken"]),
        (c["relay"], "CURRENCY_TOKEN()(address)", d["weth"]),
        (c["spotAdapter"], "MANAGER()(address)", c["manager"]),
        (c["conditionalAdapter"], "MANAGER()(address)", c["manager"]),
        (c["spotAdapter"], "POSITION_MANAGER()(address)", d["positionManager"]),
        (c["conditionalAdapter"], "POSITION_MANAGER()(address)", d["positionManager"]),
        (c["guard"], "FACTORY()(address)", d["uniswapV3Factory"]),
        (c["router"], "CONDITIONAL_TOKENS()(address)", d["conditionalTokens"]),
        (c["router"], "WRAPPED_1155_FACTORY()(address)", d["wrapped1155Factory"]),
        (c["manager"], "owner()(address)", DEAD),
        (c["manager"], "pendingOwner()(address)", ZERO),
        (c["manager"], "BOOTSTRAP_RECIPIENT()(address)", c["vault"]),
        (c["manager"], "OFFICIAL_PROPOSER()(address)", c["relay"]),
        (c["manager"], "PROPOSAL_SOURCE()(address)", c["relay"]),
        (c["manager"], "SPOT_ADAPTER()(address)", c["spotAdapter"]),
        (c["manager"], "CONDITIONAL_ADAPTER()(address)", c["conditionalAdapter"]),
        (c["manager"], "CONDITIONAL_ROUTER()(address)", c["router"]),
        (c["manager"], "POOL_STABILITY_GUARD()(address)", c["guard"]),
        (c["manager"], "COMPANY_TOKEN()(address)", c["companyToken"]),
        (c["manager"], "WRAPPED_NATIVE()(address)", d["weth"]),
    )
    for target, signature, expected in address_calls:
        if _call_address(client, target, signature) != expected:
            raise ManifestError(f"public wiring mismatch: {target}.{signature}")

    if _call_address(
        client, c["space"], "votingStrategies(uint8)(address,bytes)", "0"
    ) != c["votingStrategy"]:
        raise ManifestError("Snapshot X voting strategy mismatch")
    if _call_address(
        client, c["space"], "proposalValidationStrategy()(address,bytes)"
    ) != d["proposalValidationStrategy"]:
        raise ManifestError("Snapshot X proposal validation strategy mismatch")
    if _call_int(client, c["space"], "authenticators(address)(uint256)", c["proposalGateway"]) != 1:
        raise ManifestError("Snapshot X gateway is not the sole configured authenticator")
    if _call_int(client, c["space"], "activeVotingStrategies()(uint256)") != 1:
        raise ManifestError("Snapshot X must have exactly one inert voting strategy")
    if _call_int(
        client,
        c["votingStrategy"],
        "getVotingPower(uint32,address,bytes,bytes)(uint256)",
        "0",
        DEAD,
        "0x",
        "0x",
    ) != 0:
        raise ManifestError("Snapshot X voting power is reachable")
    if _call_int(client, c["vault"], "grantCount()(uint256)") != len(c["vestingWallets"]):
        raise ManifestError("vault grant count mismatch")
    for index, wallet in enumerate(c["vestingWallets"]):
        if _call_address(
            client,
            c["vault"],
            "grants(uint256)(address,uint64,uint64,uint256)",
            str(index),
        ) != wallet:
            raise ManifestError(f"vault grant wallet {index} mismatch")

    int_calls = (
        (receipt, "FEE_TIER()(uint24)", FEE_TIER),
        (receipt, "OBSERVATION_CARDINALITY()(uint16)", OBSERVATION_CARDINALITY),
        (c["orchestrator"], "FEE_TIER()(uint24)", FEE_TIER),
        (c["orchestrator"], "OBSERVATION_CARDINALITY()(uint16)", OBSERVATION_CARDINALITY),
        (c["relay"], "FEE_TIER()(uint24)", FEE_TIER),
        (c["guard"], "FEE()(uint24)", FEE_TIER),
        (c["spotAdapter"], "DEFAULT_TICK_LOWER()(int24)", flm_deployment.TICK_LOWER),
        (c["spotAdapter"], "DEFAULT_TICK_UPPER()(int24)", flm_deployment.TICK_UPPER),
        (c["conditionalAdapter"], "DEFAULT_TICK_LOWER()(int24)", flm_deployment.TICK_LOWER),
        (c["conditionalAdapter"], "DEFAULT_TICK_UPPER()(int24)", flm_deployment.TICK_UPPER),
    )
    for target, signature, expected in int_calls:
        if _call_int(client, target, signature) != expected:
            raise ManifestError(f"numeric wiring mismatch: {target}.{signature}")
    if _call_bool(client, c["orchestrator"], "ADAPTER_REPLACEABLE()(bool)"):
        raise ManifestError("economic orchestrator adapter authority is replaceable")
    if _call_bool(client, d["stackDeployer"], "ADAPTER_REPLACEABLE()(bool)"):
        raise ManifestError("stack deployer was not created with fixed adapters")

    core_getters = {
        "ARBITRATION": "ARBITRATION_CODE_HASH()(bytes32)",
        "VAULT": "VAULT_CODE_HASH()(bytes32)",
        "RELEASE_STRATEGY": "RELEASE_STRATEGY_CODE_HASH()(bytes32)",
        "ZERO_VOTING": "ZERO_VOTING_CODE_HASH()(bytes32)",
        "ECON_GATEWAY": "ECON_GATEWAY_CODE_HASH()(bytes32)",
        "ECON_EVALUATOR": "ECON_EVALUATOR_CODE_HASH()(bytes32)",
    }
    for key, signature in core_getters.items():
        if _call_hash(client, receipt, signature) != manifest["codeBlobs"]["core"][key]:
            raise ManifestError(f"receipt core code-hash getter mismatch: {key}")


def _verify_finalization(manifest: dict[str, Any], client: Any) -> None:
    c = manifest["contracts"]
    d = {key: item["target"] for key, item in _dependencies(manifest).items()}
    live = manifest["status"] == "live"
    initialized = _call_bool(client, c["manager"], "initializedFromBootstrap()(bool)")
    if not live:
        supply = _call_int(client, c["manager"], "totalSupply()(uint256)")
        if initialized or supply != 0:
            raise ManifestError("sealed manager already contains finalization state")
        return

    if _call_int(client, c["vault"], "phase()(uint8)") != 2:
        raise ManifestError("live vault is not in LIVE phase")
    if not initialized:
        raise ManifestError("live manager was not initialized from bootstrap")
    if not _call_bool(client, c["companyToken"], "mintingFinished()(bool)"):
        raise ManifestError("FAO token minting is not finished")

    if not client.code(c["spotPool"]):
        raise ManifestError("canonical spot pool has no deployed code")

    factory_pool = _call_address(
        client,
        d["uniswapV3Factory"],
        "getPool(address,address,uint24)(address)",
        c["companyToken"],
        d["weth"],
        str(FEE_TIER),
    )
    if factory_pool != c["spotPool"]:
        raise ManifestError("factory does not map the canonical fee-500 spot pool")
    token0, token1 = sorted((c["companyToken"], d["weth"]))
    if (
        _call_address(client, c["spotPool"], "token0()(address)") != token0
        or _call_address(client, c["spotPool"], "token1()(address)") != token1
        or _call_int(client, c["spotPool"], "fee()(uint24)") != FEE_TIER
    ):
        raise ManifestError("live spot pool identity mismatch")


def verify_rpc(
    raw: Any,
    receipt_creation_code: bytes,
    prerequisite_creation_codes: dict[str, bytes],
    client: Any,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> None:
    manifest = validate_manifest(raw, hash_=hash_)
    if client.chain_id() != CHAIN_ID:
        raise ManifestError(f"RPC chain must be Sepolia ({CHAIN_ID})")
    _verify_prerequisites(manifest, client, prerequisite_creation_codes, hash_)
    _verify_transactions(manifest, client, receipt_creation_code, hash_)
    _verify_addresses(manifest, client, hash_)
    _verify_code_and_wiring(manifest, client, hash_)
    _verify_finalization(manifest, client)


def verified_creation_evidence() -> tuple[bytes, dict[str, bytes]]:
    flm_deployment._require_clean_tracked_root(ROOT)
    try:
        compiled = economic_code_hashes.generate(check=True)
    except economic_code_hashes.GenerationError as exc:
        raise ManifestError(f"cannot reproduce economic compiler evidence: {exc}") from exc
    by_key = {item.target.constant: item.code for item in compiled}
    return by_key["RECEIPT"], {
        "proposalImplementation": by_key["PROPOSAL_IMPLEMENTATION"],
        "stackDeployer": by_key["STACK_DEPLOYER"],
    }


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest", type=Path)
    source.add_argument("--from-broadcast", type=Path)
    parser.add_argument("--rpc-url")
    parser.add_argument("--operation-broadcast", type=Path)
    parser.add_argument("--out", type=Path, default=ROOT / "deployments/sepolia-economic-genesis.json")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--schema-only", action="store_true")
    args = parser.parse_args(argv)
    if args.from_broadcast:
        if args.schema_only or args.operation_broadcast or not args.rpc_url:
            raise ManifestError("--from-broadcast requires --rpc-url and cannot be schema-only")
        receipt_creation, prerequisite_creation = verified_creation_evidence()
        manifest = manifest_from_broadcast(
            site_deployment.load_json(args.from_broadcast),
            receipt_creation,
            prerequisite_creation,
            CastClient(args.rpc_url),
        )
        site_deployment._write_or_check(args.out, manifest, args.check)
        return 0

    manifest = site_deployment.load_json(args.manifest)
    validate_manifest(manifest)
    if args.operation_broadcast:
        if args.schema_only or not args.rpc_url:
            raise ManifestError("--operation-broadcast requires --rpc-url and cannot be schema-only")
        receipt_creation, prerequisite_creation = verified_creation_evidence()
        client = CastClient(args.rpc_url)
        finalization_hash = finalization_hash_from_broadcast(
            site_deployment.load_json(args.operation_broadcast),
            manifest["contracts"]["vault"],
            client,
        )
        live = promote_live(
            manifest,
            finalization_hash,
            receipt_creation,
            prerequisite_creation,
            client,
        )
        site_deployment._write_or_check(args.out, live, args.check)
        return 0
    if args.schema_only:
        return 0
    if not args.rpc_url:
        raise ManifestError("--rpc-url is required unless --schema-only is used")
    receipt_creation, prerequisite_creation = verified_creation_evidence()
    verify_rpc(
        manifest,
        receipt_creation,
        prerequisite_creation,
        CastClient(args.rpc_url),
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as exc:
        print(f"economic_deployment.py: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
