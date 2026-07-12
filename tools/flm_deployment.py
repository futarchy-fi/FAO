#!/usr/bin/env python3
"""Build, combine, and verify the canonical Sepolia FLM deployment manifest."""

from __future__ import annotations

import argparse
import copy
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable

try:
    from tools import flm_code_hashes, site_deployment
except ModuleNotFoundError:  # Direct `python tools/flm_deployment.py` execution.
    import flm_code_hashes  # type: ignore
    import site_deployment  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
DEFAULT_BUILD_INFO = ROOT / "build-info/flm-deployment"
CHAIN_ID = 11_155_111
FEE_TIER = 500
MIN_CARDINALITY_NEXT = 120
TICK_LOWER = -887_270
TICK_UPPER = 887_270
DEAD = "0x000000000000000000000000000000000000dead"
FORBIDDEN_OPERATOR = "0x693e3fb46bb36ee43c702fe94f9463df0691b43d"

WETH = "0xfff9976782d46cc05630d1f6ebab18b2324d6b14"
CTF = "0x8bdc504dc3a05310059c1c67e0a2667309d27b93"
WRAPPED_1155_FACTORY = "0xd194319d1804c1051dd21ba1dc931ca72410b79f"
UNIV3_FACTORY = "0x0227628f3f023bb0b980b67d528571c95c6dac1c"
POSITION_MANAGER = "0x1238536071e1c677a632429e3655c799b22cda52"

PINNED_CODEHASHES = {
    "weth": "0xc864e10689f2da18833652a3b075d43106e87f0f90d95ee64f6f0b33bc026083",
    "conditionalTokens": "0x962883a35da553c2d46562f362ba99f68041dad91de30a143a785b2d169c7e81",
    "wrapped1155Factory": "0x792e0ae192d66bc58541831991b449cd2ba502fe0053507d6c4493d8865371b6",
    "univ3Factory": "0xacb5afea1f8877239fadd30358add13f2f9d4fb80175402c686d392295224fef",
    "positionManager": "0x390d49631aefbf890c9415457b4639243ff16092ded43ce8f885fde8a5a34868",
}

CARDINALITY_SELECTOR = "32148f67"
DEPLOY_AND_BIND_SELECTOR = "7b6d16f9"
BUNDLE_SEALED_TOPIC = "0x8d16d565278547f58823f72e6ea353af64c88a3d9826334b9d39157ac8b0271d"

ManifestError = site_deployment.ManifestError
_address = site_deployment._address
_data_addresses = site_deployment._data_addresses
_hex = site_deployment._hex
_is_success = site_deployment._is_success
_json_integer = site_deployment._json_integer
_quantity = site_deployment._quantity
_receipt_map = site_deployment._receipt_map
_require_dict = site_deployment._require_dict
_require_list = site_deployment._require_list
_topic_address = site_deployment._topic_address


@dataclass(frozen=True)
class Target:
    key: str
    source: str
    contract: str


RECEIPT_TARGET = Target(
    "RECEIPT", "src/SepoliaFlmBundleDeployment.sol", "SepoliaFlmBundleDeployment"
)
CODE_TARGETS = (
    Target("RELAY", "src/FAOFlmProposalSourceRelay.sol", "FAOFlmProposalSourceRelay"),
    Target(
        "ADAPTER",
        "lib/futarchy-liquidity-manager/src/adapters/UniswapV3LiquidityAdapter.sol",
        "UniswapV3LiquidityAdapter",
    ),
    Target(
        "GUARD",
        "lib/futarchy-liquidity-manager/src/oracles/UniV3PoolStabilityGuard.sol",
        "UniV3PoolStabilityGuard",
    ),
    Target(
        "ROUTER",
        "lib/futarchy-liquidity-manager/src/routers/FutarchyConditionalRouter.sol",
        "FutarchyConditionalRouter",
    ),
    Target(
        "MANAGER",
        "lib/futarchy-liquidity-manager/src/core/FutarchyLiquidityManager.sol",
        "FutarchyLiquidityManager",
    ),
)
TARGET_BY_KEY = {target.key: target for target in CODE_TARGETS}
ALL_TARGETS = (RECEIPT_TARGET, *CODE_TARGETS)

CHILDREN = (
    ("relay", 1, "RELAY"),
    ("spotAdapter", 2, "ADAPTER"),
    ("conditionalAdapter", 3, "ADAPTER"),
    ("guard", 4, "GUARD"),
    ("router", 5, "ROUTER"),
    ("manager", 6, "MANAGER"),
)
CONTRACT_KEYS = ("receipt", *(name for name, _, _ in CHILDREN))
DEPENDENCY_KEYS = (
    "weth",
    "conditionalTokens",
    "wrapped1155Factory",
    "univ3Factory",
    "positionManager",
    "companyToken",
    "spotPool",
    "arbitration",
    "pipeline",
    "orchestrator",
    "resolver",
    "futarchyFactory",
)


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def _variable_bytes(value: Any, name: str) -> bytes:
    if not isinstance(value, str) or not value.startswith("0x") or len(value) % 2:
        raise ManifestError(f"{name} must be even-length 0x hex bytes")
    try:
        return bytes.fromhex(value[2:])
    except ValueError as exc:
        raise ManifestError(f"{name} must be hexadecimal") from exc


def _compiler_bytes(value: Any, name: str) -> bytes:
    if not isinstance(value, str):
        raise ManifestError(f"{name} must be compiler hex bytes")
    body = value[2:] if value.startswith("0x") else value
    if not body or len(body) % 2 or not re.fullmatch(r"[0-9a-fA-F]+", body):
        raise ManifestError(f"{name} contains empty or unresolved compiler bytes")
    return bytes.fromhex(body)


def _digest(value: bytes, hash_: Callable[[bytes], str]) -> str:
    return _hex(hash_(value), 32, "Keccak-256 digest")


def _word(data: bytes, offset: int, name: str) -> bytes:
    value = data[offset : offset + 32]
    if len(value) != 32:
        raise ManifestError(f"{name} is truncated")
    return value


def _word_uint(data: bytes, offset: int, name: str) -> int:
    return int.from_bytes(_word(data, offset, name), "big")


def _word_address(data: bytes, offset: int, name: str) -> str:
    value = _word(data, offset, name)
    if value[:12] != bytes(12):
        raise ManifestError(f"{name} is not an ABI-encoded address")
    return _address("0x" + value[12:].hex(), name)


def _create_address(receipt: str, nonce: int, hash_: Callable[[bytes], str]) -> str:
    if nonce < 1 or nonce > 0x7F:
        raise ManifestError("CREATE nonce is outside the supported canonical range")
    sender = bytes.fromhex(_address(receipt, "receipt")[2:])
    digest = _digest(b"\xd6\x94" + sender + bytes([nonce]), hash_)
    return "0x" + digest[-40:]


def _walk(value: Any):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk(child)


@dataclass(frozen=True)
class Immutable:
    name: str
    type_string: str
    locations: tuple[tuple[int, int], ...]


@dataclass(frozen=True)
class CompiledContract:
    target: Target
    creation: bytes
    runtime_template: bytes
    immutables: tuple[Immutable, ...]
    compiler_version: str
    settings: dict[str, Any]

    def identity(self) -> tuple[Any, ...]:
        return (
            self.creation,
            self.runtime_template,
            self.immutables,
            self.compiler_version,
            _canonical(self.settings),
        )


class BuildCatalog:
    """Strictly selects compiler output and AST evidence from Foundry build-info."""

    def __init__(self, path: Path):
        files = [path] if path.is_file() else sorted(path.rglob("*.json"))
        if not files:
            raise ManifestError(f"no build-info JSON found under {path}")
        self.contracts: dict[str, list[CompiledContract]] = {
            target.key: [] for target in ALL_TARGETS
        }
        for file in files:
            self._read(file)

    def _read(self, path: Path) -> None:
        try:
            value = site_deployment.load_json(path)
        except ManifestError as exc:
            raise ManifestError(f"cannot read build-info {path}: {exc}") from exc
        value = _require_dict(value, f"build-info {path}")
        output = value.get("output")
        if not isinstance(output, dict) or not isinstance(output.get("contracts"), dict):
            return

        contracts = output["contracts"]
        present = [
            target
            for target in ALL_TARGETS
            if isinstance(contracts.get(target.source), dict)
            and isinstance(contracts[target.source].get(target.contract), dict)
        ]
        if not present:
            return

        declarations: dict[int, tuple[str, str]] = {}
        sources = _require_dict(output.get("sources"), f"{path}.output.sources")
        for source in sources.values():
            if not isinstance(source, dict) or not isinstance(source.get("ast"), dict):
                continue
            for node in _walk(source["ast"]):
                if (
                    node.get("nodeType") != "VariableDeclaration"
                    or node.get("mutability") != "immutable"
                ):
                    continue
                identifier = node.get("id")
                name = node.get("name")
                type_descriptions = node.get("typeDescriptions")
                type_string = (
                    type_descriptions.get("typeString")
                    if isinstance(type_descriptions, dict)
                    else None
                )
                if (
                    type(identifier) is not int
                    or not isinstance(name, str)
                    or not isinstance(type_string, str)
                ):
                    raise ManifestError(f"incomplete immutable AST declaration in {path}")
                previous = declarations.get(identifier)
                if previous is not None and previous != (name, type_string):
                    raise ManifestError(f"conflicting AST id {identifier} in {path}")
                declarations[identifier] = (name, type_string)

        for target in present:
            raw = contracts[target.source][target.contract]
            self.contracts[target.key].append(
                self._compiled(path, target, raw, declarations)
            )

    @staticmethod
    def _compiled(
        path: Path,
        target: Target,
        raw: dict[str, Any],
        declarations: dict[int, tuple[str, str]],
    ) -> CompiledContract:
        evm = _require_dict(raw.get("evm"), f"{path}:{target.contract}.evm")
        bytecode = _require_dict(evm.get("bytecode"), f"{target.contract}.bytecode")
        deployed = _require_dict(
            evm.get("deployedBytecode"), f"{target.contract}.deployedBytecode"
        )
        if bytecode.get("linkReferences") != {} or deployed.get("linkReferences") != {}:
            raise ManifestError(f"{target.contract} contains unresolved library links")
        creation = _compiler_bytes(bytecode.get("object"), f"{target.contract}.creation")
        runtime = _compiler_bytes(deployed.get("object"), f"{target.contract}.runtime")
        if not creation or not runtime:
            raise ManifestError(f"{target.contract} compiler bytecode is empty")

        refs = _require_dict(
            deployed.get("immutableReferences"), f"{target.contract}.immutableReferences"
        )
        immutables = []
        occupied: set[int] = set()
        for raw_id, raw_locations in refs.items():
            try:
                identifier = int(raw_id)
            except (TypeError, ValueError) as exc:
                raise ManifestError(f"invalid immutable AST id {raw_id!r}") from exc
            declaration = declarations.get(identifier)
            if declaration is None:
                raise ManifestError(
                    f"immutable AST id {identifier} for {target.contract} is missing"
                )
            locations = []
            raw_location_list = _require_list(
                raw_locations, f"immutableReferences.{identifier}"
            )
            if not raw_location_list:
                raise ManifestError(f"immutable {identifier} has no runtime locations")
            for index, raw_location in enumerate(raw_location_list):
                location = _require_dict(raw_location, f"immutable {identifier}[{index}]")
                start = _json_integer(location.get("start"), "immutable start")
                length = _json_integer(location.get("length"), "immutable length")
                if length != 32 or start < 0 or start + length > len(runtime):
                    raise ManifestError(f"invalid immutable location for {target.contract}")
                if runtime[start : start + length] != bytes(length):
                    raise ManifestError(
                        f"immutable template for {target.contract} is not zero-filled"
                    )
                for offset in range(start, start + length):
                    if offset in occupied:
                        raise ManifestError(f"overlapping immutable locations in {target.contract}")
                    occupied.add(offset)
                locations.append((start, length))
            immutables.append(Immutable(*declaration, tuple(locations)))

        metadata = raw.get("metadata")
        if isinstance(metadata, str):
            try:
                metadata = json.loads(
                    metadata,
                    object_pairs_hook=site_deployment._object_without_duplicates,
                )
            except json.JSONDecodeError as exc:
                raise ManifestError(f"invalid compiler metadata for {target.contract}") from exc
        metadata = _require_dict(metadata, f"{target.contract}.metadata")
        compiler = _require_dict(metadata.get("compiler"), f"{target.contract}.compiler")
        settings = copy.deepcopy(
            _require_dict(metadata.get("settings"), f"{target.contract}.settings")
        )
        if settings.pop("compilationTarget", None) != {target.source: target.contract}:
            raise ManifestError(f"wrong compilation target for {target.contract}")
        remappings = settings.get("remappings")
        if isinstance(remappings, list):
            if not all(isinstance(item, str) for item in remappings):
                raise ManifestError(f"invalid compiler remappings for {target.contract}")
            # Foundry's raw compiler metadata prefixes context-free remappings with ':'.
            # Its canonical artifact metadata (used by flm_code_hashes.py) removes it.
            settings["remappings"] = [
                item[1:] if item.startswith(":") else item for item in remappings
            ]
        version = compiler.get("version")
        if not isinstance(version, str) or not version:
            raise ManifestError(f"missing compiler version for {target.contract}")
        return CompiledContract(
            target,
            creation,
            runtime,
            tuple(sorted(immutables, key=lambda item: item.name)),
            version,
            settings,
        )

    def _unique(self, matches: list[CompiledContract], name: str) -> CompiledContract:
        if not matches:
            raise ManifestError(f"no exact build-info output found for {name}")
        first = matches[0]
        if any(item.identity() != first.identity() for item in matches[1:]):
            raise ManifestError(f"ambiguous build-info outputs for {name}")
        return first

    def exact(self, target: Target, creation: bytes) -> CompiledContract:
        return self._unique(
            [item for item in self.contracts[target.key] if item.creation == creation],
            target.contract,
        )

    def creation_prefix(
        self, target: Target, transaction_input: bytes, suffix_bytes: int
    ) -> CompiledContract:
        return self._unique(
            [
                item
                for item in self.contracts[target.key]
                if len(transaction_input) == len(item.creation) + suffix_bytes
                and transaction_input.startswith(item.creation)
            ],
            target.contract,
        )


def _validate_code_evidence(value: Any) -> dict[str, Any]:
    evidence = _require_dict(value, "FLM code evidence")
    if set(evidence) != {
        "schemaVersion",
        "flmSubmoduleSha",
        "compiler",
        "receipt",
        "contracts",
    }:
        raise ManifestError("invalid FLM code-evidence keys")
    if _json_integer(evidence["schemaVersion"], "codeEvidence.schemaVersion") != 2:
        raise ManifestError("FLM code evidence must be schema version 2")
    sha = evidence["flmSubmoduleSha"]
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ManifestError("flmSubmoduleSha must be a lowercase git SHA")
    compiler = _require_dict(evidence["compiler"], "codeEvidence.compiler")
    if set(compiler) != {"solcVersion", "solcSettingsKeccak256"}:
        raise ManifestError("invalid compiler evidence")
    if not isinstance(compiler["solcVersion"], str) or not compiler["solcVersion"]:
        raise ManifestError("missing solcVersion")
    settings_hash = _hex(
        compiler["solcSettingsKeccak256"], 32, "solcSettingsKeccak256"
    )
    if compiler["solcSettingsKeccak256"] != settings_hash:
        raise ManifestError("solcSettingsKeccak256 must be canonical lowercase hex")
    receipt = _require_dict(evidence["receipt"], "codeEvidence.receipt")
    if set(receipt) != {
        "source",
        "contract",
        "creationCodeBytes",
        "creationCodeKeccak256",
    }:
        raise ManifestError("invalid receipt code evidence")
    if (
        receipt["source"] != RECEIPT_TARGET.source
        or receipt["contract"] != RECEIPT_TARGET.contract
        or _json_integer(receipt["creationCodeBytes"], "receipt.creationCodeBytes") <= 0
    ):
        raise ManifestError("wrong receipt compiler target or empty creation code")
    receipt_hash = _hex(
        receipt["creationCodeKeccak256"], 32, "receipt.creationCodeKeccak256"
    )
    if receipt["creationCodeKeccak256"] != receipt_hash:
        raise ManifestError("receipt creationCodeKeccak256 must be canonical lowercase hex")
    contracts = _require_dict(evidence["contracts"], "codeEvidence.contracts")
    if tuple(contracts) != tuple(target.key for target in CODE_TARGETS):
        raise ManifestError("code evidence contracts are not canonical")
    for target in CODE_TARGETS:
        item = _require_dict(contracts[target.key], f"codeEvidence.{target.key}")
        if set(item) != {
            "source",
            "contract",
            "baseCreationCodePath",
            "baseCreationCodeBytes",
            "baseCreationCodeKeccak256",
        }:
            raise ManifestError(f"invalid code evidence for {target.key}")
        if item["source"] != target.source or item["contract"] != target.contract:
            raise ManifestError(f"wrong compiler target for {target.key}")
        expected_path = f"metadata/flm-creation-code/{target.key.lower()}.bin"
        if item["baseCreationCodePath"] != expected_path:
            raise ManifestError(f"wrong base creation-code path for {target.key}")
        if _json_integer(item["baseCreationCodeBytes"], "baseCreationCodeBytes") <= 0:
            raise ManifestError(f"empty base creation code for {target.key}")
        base_hash = _hex(
            item["baseCreationCodeKeccak256"], 32, "baseCreationCodeKeccak256"
        )
        if item["baseCreationCodeKeccak256"] != base_hash:
            raise ManifestError(
                f"baseCreationCodeKeccak256 for {target.key} must be canonical lowercase hex"
            )
    return evidence


def _pinned_flm_sha(root: Path = ROOT) -> str:
    try:
        return flm_code_hashes._submodule_sha(root)
    except flm_code_hashes.GenerationError as exc:
        raise ManifestError(f"cannot verify pinned FLM submodule: {exc}") from exc


def _require_clean_tracked_root(root: Path = ROOT) -> None:
    try:
        result = subprocess.run(
            ["git", "status", "--porcelain", "--untracked-files=no"],
            cwd=root,
            text=True,
            capture_output=True,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ManifestError("cannot verify the root repository worktree") from exc
    if result.stdout.strip():
        raise ManifestError(
            "tracked root files must be clean before using the operational FLM verifier"
        )


def _require_pinned_evidence(
    manifest: dict[str, Any],
    expected_sha: str,
    canonical_evidence: dict[str, Any],
) -> None:
    manifest = _require_dict(manifest, "manifest")
    section = manifest.get("flm") if manifest.get("schemaVersion") == 2 else manifest
    section = _require_dict(section, "flm")
    evidence = _validate_code_evidence(section.get("codeEvidence"))
    if evidence["flmSubmoduleSha"] != expected_sha:
        raise ManifestError("FLM code evidence does not match the pinned submodule gitlink")
    canonical = _validate_code_evidence(canonical_evidence)
    if evidence != canonical:
        raise ManifestError("FLM code evidence does not match the canonical generated manifest")


def _decode_base_codes(calldata: bytes) -> tuple[bytes, ...]:
    if len(calldata) < 4 or calldata[:4].hex() != DEPLOY_AND_BIND_SELECTOR:
        raise ManifestError("deployAndBind transaction has the wrong selector")
    args = calldata[4:]
    if len(args) < 64 or len(args) % 32:
        raise ManifestError("deployAndBind calldata is malformed")
    if _word_uint(args, 0, "baseCodes offset") != 32:
        raise ManifestError("baseCodes must use canonical ABI offset 32")
    array_start = 32
    count = _word_uint(args, array_start, "baseCodes length")
    if count != len(CODE_TARGETS):
        raise ManifestError(f"deployAndBind must contain {len(CODE_TARGETS)} base codes")
    base = array_start + 32
    cursor = count * 32
    values = []
    for index in range(count):
        offset = _word_uint(args, base + index * 32, f"baseCodes[{index}] offset")
        if offset != cursor:
            raise ManifestError("baseCodes uses non-canonical offsets")
        position = base + offset
        length = _word_uint(args, position, f"baseCodes[{index}] length")
        start = position + 32
        end = start + length
        padded_end = start + ((length + 31) // 32) * 32
        if padded_end > len(args) or any(args[end:padded_end]):
            raise ManifestError(f"baseCodes[{index}] is truncated or has nonzero padding")
        values.append(args[start:end])
        cursor = padded_end - base
    if base + cursor != len(args):
        raise ManifestError("deployAndBind calldata has trailing bytes")
    return tuple(values)


@dataclass(frozen=True)
class Dependency:
    target: str
    codehash: str


def _decode_receipt_config(encoded: bytes) -> tuple[dict[str, Dependency], int, int]:
    if len(encoded) != (len(DEPENDENCY_KEYS) * 2 + 2) * 32:
        raise ManifestError("receipt constructor Config has the wrong encoded length")
    dependencies: dict[str, Dependency] = {}
    for index, key in enumerate(DEPENDENCY_KEYS):
        offset = index * 64
        target = _word_address(encoded, offset, f"Config.{key}.target")
        codehash = "0x" + _word(encoded, offset + 32, f"Config.{key}.codehash").hex()
        if codehash == "0x" + "00" * 32:
            raise ManifestError(f"Config.{key}.codehash cannot be zero")
        dependencies[key] = Dependency(target, codehash)
    bootstrap_offset = len(DEPENDENCY_KEYS) * 64
    company_amount = _word_uint(encoded, bootstrap_offset, "bootstrapCompanyAmount")
    weth_amount = _word_uint(encoded, bootstrap_offset + 32, "bootstrapWethAmount")
    if company_amount == 0 or weth_amount == 0:
        raise ManifestError("bootstrap amounts must be nonzero")
    return dependencies, company_amount, weth_amount


@dataclass(frozen=True)
class Transaction:
    index: int
    type: str
    hash: str
    sender: str
    to: str | None
    input: bytes
    nonce: int
    block: int
    outer: dict[str, Any]
    receipt: dict[str, Any]


def _transactions(broadcast: Any) -> tuple[Transaction, ...]:
    broadcast = _require_dict(broadcast, "broadcast")
    if _quantity(broadcast.get("chain"), "chain") != CHAIN_ID:
        raise ManifestError(f"broadcast chain must be Sepolia ({CHAIN_ID})")
    if _require_list(broadcast.get("pending", []), "pending"):
        raise ManifestError("broadcast contains pending transactions")
    raw_transactions = _require_list(broadcast.get("transactions"), "transactions")
    if len(raw_transactions) != 3:
        raise ManifestError("FLM broadcast must contain exactly three transactions")
    receipts = _receipt_map(broadcast)
    records = []
    hashes = set()
    for index, raw in enumerate(raw_transactions):
        outer = _require_dict(raw, f"transactions[{index}]")
        tx_hash = _hex(outer.get("hash"), 32, f"transactions[{index}].hash")
        if tx_hash in hashes:
            raise ManifestError(f"duplicate transaction {tx_hash}")
        hashes.add(tx_hash)
        receipt = receipts.get(tx_hash)
        if receipt is None:
            raise ManifestError(f"missing receipt for transaction {tx_hash}")
        if not _is_success(receipt):
            raise ManifestError(f"transaction failed: {tx_hash}")
        inner = _require_dict(outer.get("transaction"), f"transactions[{index}].transaction")
        sender = _address(inner.get("from"), f"transactions[{index}].from")
        to_raw = inner.get("to")
        to = None if to_raw in (None, "") else _address(to_raw, f"transactions[{index}].to")
        records.append(
            Transaction(
                index,
                outer.get("transactionType"),
                tx_hash,
                sender,
                to,
                _variable_bytes(inner.get("input"), f"transactions[{index}].input"),
                _quantity(inner.get("nonce"), f"transactions[{index}].nonce"),
                _quantity(receipt.get("blockNumber"), f"receipts[{index}].blockNumber"),
                outer,
                receipt,
            )
        )
        if records[-1].nonce < 0 or records[-1].block < 0:
            raise ManifestError("transaction nonce and block must be nonnegative")
    if set(receipts) != hashes:
        raise ManifestError("broadcast contains an unrelated receipt")
    if (
        records[0].sender != records[1].sender
        or [records[0].nonce, records[1].nonce] != [0, 1]
    ):
        raise ManifestError(
            "cardinality and receipt CREATE must use one fresh key at nonces [0, 1]"
        )
    if [record.block for record in records] != sorted(record.block for record in records):
        raise ManifestError("FLM transaction blocks are out of order")
    return tuple(records)


def _sealed_children(
    records: tuple[Transaction, ...], receipt: str, hash_: Callable[[bytes], str]
) -> dict[str, str]:
    matches: list[dict[str, str]] = []
    for record in records:
        for raw in _require_list(record.receipt.get("logs", []), "receipt.logs"):
            log = _require_dict(raw, "receipt.log")
            topics = _require_list(log.get("topics"), "BundleSealed.topics")
            if not topics or str(topics[0]).lower() != BUNDLE_SEALED_TOPIC:
                continue
            if record.index != 2:
                raise ManifestError("BundleSealed was not emitted by deployAndBind")
            if _address(log.get("address"), "BundleSealed.emitter") != receipt:
                raise ManifestError("BundleSealed has an unexpected emitter")
            if len(topics) != 4:
                raise ManifestError("BundleSealed must have four topics")
            relay = _topic_address(topics[1], "BundleSealed.relay")
            manager = _topic_address(topics[2], "BundleSealed.manager")
            spot = _topic_address(topics[3], "BundleSealed.spotAdapter")
            conditional, guard, router = _data_addresses(
                log.get("data"), 3, "BundleSealed.data"
            )
            matches.append(
                {
                    "relay": relay,
                    "spotAdapter": spot,
                    "conditionalAdapter": conditional,
                    "guard": guard,
                    "router": router,
                    "manager": manager,
                }
            )
    if len(matches) != 1:
        raise ManifestError(f"expected one BundleSealed event, found {len(matches)}")
    children = matches[0]
    if len(set(children.values())) != 6:
        raise ManifestError("BundleSealed child addresses must be unique")
    for name, nonce, _ in CHILDREN:
        expected = _create_address(receipt, nonce, hash_)
        if children[name] != expected:
            raise ManifestError(
                f"BundleSealed {name} is not receipt CREATE nonce {nonce}"
            )
    return children


def _validate_dependencies(
    dependencies: dict[str, Dependency], w0: dict[str, Any]
) -> None:
    contracts = w0["contracts"]
    expected = {
        "weth": WETH,
        "conditionalTokens": CTF,
        "wrapped1155Factory": WRAPPED_1155_FACTORY,
        "univ3Factory": UNIV3_FACTORY,
        "positionManager": POSITION_MANAGER,
        "companyToken": _address(contracts["siteToken"], "W0 siteToken"),
        "spotPool": _address(contracts["spotPool"], "W0 spotPool"),
        "arbitration": _address(contracts["arbitration"], "W0 arbitration"),
        "pipeline": _address(contracts["evaluator"], "W0 evaluator"),
        "orchestrator": _address(contracts["orchestrator"], "W0 orchestrator"),
        "resolver": _address(contracts["twapResolver"], "W0 twapResolver"),
        "futarchyFactory": _address(
            contracts["futarchyFactory"], "W0 futarchyFactory"
        ),
    }
    for key in DEPENDENCY_KEYS:
        if dependencies[key].target != expected[key]:
            raise ManifestError(f"Config.{key} does not match the canonical W0 dependency")
    for key, codehash in PINNED_CODEHASHES.items():
        if dependencies[key].codehash != codehash:
            raise ManifestError(f"Config.{key} does not use the pinned Sepolia codehash")


@dataclass(frozen=True)
class Context:
    receipt: str
    children: dict[str, str]
    dependencies: dict[str, Dependency]
    bootstrap_company: int
    bootstrap_weth: int


def _immutable_values(target: Target, context: Context) -> dict[str, Any]:
    d = context.dependencies
    c = context.children
    if target.key == "RECEIPT":
        return {
            "WETH": d["weth"].target,
            "COMPANY_TOKEN": d["companyToken"].target,
            "CONDITIONAL_TOKENS": d["conditionalTokens"].target,
            "WRAPPED_1155_FACTORY": d["wrapped1155Factory"].target,
            "UNIV3_FACTORY": d["univ3Factory"].target,
            "POSITION_MANAGER": d["positionManager"].target,
            "SPOT_POOL": d["spotPool"].target,
            "ARBITRATION": d["arbitration"].target,
            "PIPELINE": d["pipeline"].target,
            "ORCHESTRATOR": d["orchestrator"].target,
            "RESOLVER": d["resolver"].target,
            "FUTARCHY_FACTORY": d["futarchyFactory"].target,
            "BOOTSTRAP_COMPANY_AMOUNT": context.bootstrap_company,
            "BOOTSTRAP_WETH_AMOUNT": context.bootstrap_weth,
        }
    if target.key == "RELAY":
        return {
            "ARBITRATION": d["arbitration"].target,
            "PIPELINE": d["pipeline"].target,
            "UNIV3_FACTORY": d["univ3Factory"].target,
            "CTF": d["conditionalTokens"].target,
            "FEE_TIER": FEE_TIER,
            "COMPANY_TOKEN": d["companyToken"].target,
            "CURRENCY_TOKEN": d["weth"].target,
            "_bindingAuthority": context.receipt,
        }
    if target.key == "ADAPTER":
        return {
            "POSITION_MANAGER": d["positionManager"].target,
            "DEFAULT_TICK_LOWER": TICK_LOWER,
            "DEFAULT_TICK_UPPER": TICK_UPPER,
            "_bindingAuthority": context.receipt,
        }
    if target.key == "GUARD":
        return {"FACTORY": d["univ3Factory"].target, "FEE": FEE_TIER}
    if target.key == "ROUTER":
        return {
            "CONDITIONAL_TOKENS": d["conditionalTokens"].target,
            "WRAPPED_1155_FACTORY": d["wrapped1155Factory"].target,
        }
    if target.key == "MANAGER":
        company = d["companyToken"].target
        weth = d["weth"].target
        return {
            "COMPANY_TOKEN": company,
            "WRAPPED_NATIVE": weth,
            "BOOTSTRAP_RECIPIENT": context.receipt,
            "OFFICIAL_PROPOSER": c["relay"],
            "PROPOSAL_SOURCE": c["relay"],
            "SPOT_ADAPTER": c["spotAdapter"],
            "CONDITIONAL_ADAPTER": c["conditionalAdapter"],
            "CONDITIONAL_ROUTER": c["router"],
            "POOL_STABILITY_GUARD": c["guard"],
            "TOKEN0": min(company, weth),
            "TOKEN1": max(company, weth),
            "COMPANY_IS_TOKEN0": company < weth,
        }
    raise ManifestError(f"unsupported compiler target {target.key}")


def _encode_immutable(value: Any, type_string: str) -> bytes:
    if type_string == "address" or type_string.startswith("contract "):
        integer = int(_address(value, "immutable address"), 16)
    elif type_string == "bool":
        if type(value) is not bool:
            raise ManifestError("bool immutable has a non-bool value")
        integer = int(value)
    else:
        unsigned = re.fullmatch(r"uint([0-9]+)", type_string)
        signed = re.fullmatch(r"int([0-9]+)", type_string)
        if type(value) is not int:
            raise ManifestError(f"{type_string} immutable has a non-integer value")
        if unsigned:
            bits = int(unsigned.group(1))
            if value < 0 or value >= 1 << bits:
                raise ManifestError(f"value is outside {type_string}")
            integer = value
        elif signed:
            bits = int(signed.group(1))
            if value < -(1 << (bits - 1)) or value >= 1 << (bits - 1):
                raise ManifestError(f"value is outside {type_string}")
            integer = value % (1 << 256)
        else:
            raise ManifestError(f"unsupported immutable type {type_string}")
    return integer.to_bytes(32, "big")


def _patch_runtime(compiled: CompiledContract, values: dict[str, Any]) -> bytes:
    names = {item.name for item in compiled.immutables}
    if len(names) != len(compiled.immutables):
        raise ManifestError(f"duplicate immutable names for {compiled.target.contract}")
    if names != set(values):
        raise ManifestError(
            f"incomplete immutable values for {compiled.target.contract}; "
            f"missing={sorted(names - set(values))}, unknown={sorted(set(values) - names)}"
        )
    runtime = bytearray(compiled.runtime_template)
    for immutable in compiled.immutables:
        encoded = _encode_immutable(values[immutable.name], immutable.type_string)
        for start, length in immutable.locations:
            if length != len(encoded):
                raise ManifestError("immutable patch length mismatch")
            runtime[start : start + length] = encoded
    return bytes(runtime)


def _compiler_matches(
    compiled: CompiledContract,
    evidence: dict[str, Any],
    hash_: Callable[[bytes], str],
) -> None:
    compiler = evidence["compiler"]
    if compiled.compiler_version != compiler["solcVersion"]:
        raise ManifestError(f"wrong solc version for {compiled.target.contract}")
    fingerprint = _digest(
        _canonical(
            {
                "solcVersion": compiled.compiler_version,
                "settings": compiled.settings,
            }
        ),
        hash_,
    )
    if fingerprint != compiler["solcSettingsKeccak256"]:
        raise ManifestError(f"wrong solc settings for {compiled.target.contract}")


def _runtime_contracts(
    catalog: BuildCatalog,
    receipt_compiled: CompiledContract,
    base_codes: tuple[bytes, ...],
    context: Context,
    evidence: dict[str, Any],
    hash_: Callable[[bytes], str],
) -> tuple[dict[str, Any], dict[str, bytes]]:
    receipt_evidence = evidence["receipt"]
    if (
        len(receipt_compiled.creation) != receipt_evidence["creationCodeBytes"]
        or _digest(receipt_compiled.creation, hash_)
        != receipt_evidence["creationCodeKeccak256"]
    ):
        raise ManifestError("receipt CREATE prefix does not match canonical code evidence")
    compiled_by_key = {"RECEIPT": receipt_compiled}
    for target, code in zip(CODE_TARGETS, base_codes):
        item = evidence["contracts"][target.key]
        if len(code) != item["baseCreationCodeBytes"] or _digest(code, hash_) != item[
            "baseCreationCodeKeccak256"
        ]:
            raise ManifestError(f"deployAndBind {target.key} base code does not match evidence")
        compiled_by_key[target.key] = catalog.exact(target, code)
    for compiled in compiled_by_key.values():
        _compiler_matches(compiled, evidence, hash_)

    result: dict[str, Any] = {}
    runtime_bytes: dict[str, bytes] = {}
    receipt_runtime = _patch_runtime(
        receipt_compiled, _immutable_values(RECEIPT_TARGET, context)
    )
    runtime_bytes["receipt"] = receipt_runtime
    result["receipt"] = {
        "address": context.receipt,
        "source": RECEIPT_TARGET.source,
        "contract": RECEIPT_TARGET.contract,
        "creationCodeKeccak256": _digest(receipt_compiled.creation, hash_),
        "runtimeCodeBytes": len(receipt_runtime),
        "runtimeCodeKeccak256": _digest(receipt_runtime, hash_),
    }
    for name, nonce, key in CHILDREN:
        compiled = compiled_by_key[key]
        runtime = _patch_runtime(compiled, _immutable_values(TARGET_BY_KEY[key], context))
        runtime_bytes[name] = runtime
        result[name] = {
            "address": context.children[name],
            "createNonce": nonce,
            "baseCode": key,
            "runtimeCodeBytes": len(runtime),
            "runtimeCodeKeccak256": _digest(runtime, hash_),
        }
    return result, runtime_bytes


def flm_from_broadcast(
    broadcast: Any,
    w0_manifest: Any,
    code_evidence: Any,
    build_info: Path,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    w0 = site_deployment._validate_manifest(w0_manifest)
    evidence = _validate_code_evidence(code_evidence)
    records = _transactions(broadcast)
    cardinality, create, bind = records
    spot_pool = _address(w0["contracts"]["spotPool"], "W0 spotPool")
    if (
        cardinality.type != "CALL"
        or cardinality.to != spot_pool
        or cardinality.input[:4].hex() != CARDINALITY_SELECTOR
        or len(cardinality.input) != 36
    ):
        raise ManifestError("first transaction is not the canonical cardinality call")
    requested_cardinality = _word_uint(cardinality.input, 4, "cardinalityNext")
    if requested_cardinality < MIN_CARDINALITY_NEXT or requested_cardinality > 0xFFFF:
        raise ManifestError("cardinalityNext is outside the canonical range")

    if create.type != "CREATE" or create.outer.get("contractName") != RECEIPT_TARGET.contract:
        raise ManifestError("second transaction is not the FLM receipt CREATE")
    receipt = _address(create.outer.get("contractAddress"), "receipt CREATE address")
    receipt_address = create.receipt.get("contractAddress")
    if receipt_address is None or _address(receipt_address, "receipt.contractAddress") != receipt:
        raise ManifestError("receipt CREATE address mismatch")
    if create.to is not None:
        raise ManifestError("receipt CREATE transaction unexpectedly has a target")
    if receipt != _create_address(create.sender, 1, hash_):
        raise ManifestError("receipt address is not CREATE(fresh deployer, nonce 1)")

    if (
        bind.type != "CALL"
        or bind.to != receipt
        or bind.input[:4].hex() != DEPLOY_AND_BIND_SELECTOR
    ):
        raise ManifestError("third transaction is not receipt.deployAndBind")
    if (
        create.sender == FORBIDDEN_OPERATOR
        or create.sender == _address(w0["deployer"], "W0 deployer")
    ):
        raise ManifestError("FLM deployer is not a fresh permitted key")

    base_codes = _decode_base_codes(bind.input)
    catalog = BuildCatalog(build_info)
    config_bytes = (len(DEPENDENCY_KEYS) * 2 + 2) * 32
    receipt_compiled = catalog.creation_prefix(RECEIPT_TARGET, create.input, config_bytes)
    encoded_config = create.input[len(receipt_compiled.creation) :]
    dependencies, bootstrap_company, bootstrap_weth = _decode_receipt_config(encoded_config)
    _validate_dependencies(dependencies, w0)
    children = _sealed_children(records, receipt, hash_)
    context = Context(
        receipt,
        children,
        dependencies,
        bootstrap_company,
        bootstrap_weth,
    )
    contracts, _ = _runtime_contracts(
        catalog, receipt_compiled, base_codes, context, evidence, hash_
    )
    section = {
        "schemaVersion": 1,
        "status": "sealed",
        "network": "sepolia",
        "chainId": CHAIN_ID,
        "transactions": {
            "cardinality": {
                "hash": cardinality.hash,
                "block": cardinality.block,
                "nonce": cardinality.nonce,
                "from": cardinality.sender,
                "to": cardinality.to,
                "requestedCardinalityNext": requested_cardinality,
            },
            "receiptCreate": {
                "hash": create.hash,
                "block": create.block,
                "nonce": create.nonce,
                "from": create.sender,
                "address": receipt,
            },
            "deployAndBind": {
                "hash": bind.hash,
                "block": bind.block,
                "nonce": bind.nonce,
                "from": bind.sender,
                "to": bind.to,
            },
        },
        "bootstrap": {
            "companyAmount": bootstrap_company,
            "wethAmount": bootstrap_weth,
        },
        "dependencies": {
            key: {
                "target": dependencies[key].target,
                "runtimeCodeKeccak256": dependencies[key].codehash,
            }
            for key in DEPENDENCY_KEYS
        },
        "codeEvidence": copy.deepcopy(evidence),
        "contracts": contracts,
        "roles": {
            "managerOwner": DEAD,
            "bootstrapRecipient": receipt,
            "officialProposer": children["relay"],
            "proposalSource": children["relay"],
            "relayManager": children["manager"],
            "spotAdapterManager": children["manager"],
            "conditionalAdapterManager": children["manager"],
        },
    }
    return _validate_flm(section, hash_)


def _expect_keys(value: dict[str, Any], expected: tuple[str, ...], name: str) -> None:
    if tuple(value) != expected:
        raise ManifestError(f"{name} keys are not canonical")


def _validate_flm(
    raw: Any,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    section = _require_dict(raw, "flm")
    _expect_keys(
        section,
        (
            "schemaVersion",
            "status",
            "network",
            "chainId",
            "transactions",
            "bootstrap",
            "dependencies",
            "codeEvidence",
            "contracts",
            "roles",
        ),
        "flm",
    )
    if (
        _json_integer(section["schemaVersion"], "flm.schemaVersion") != 1
        or section["status"] != "sealed"
        or section["network"] != "sepolia"
        or _json_integer(section["chainId"], "flm.chainId") != CHAIN_ID
    ):
        raise ManifestError("FLM identity must be sealed Sepolia schema version 1")
    transactions = _require_dict(section["transactions"], "flm.transactions")
    _expect_keys(transactions, ("cardinality", "receiptCreate", "deployAndBind"), "transactions")
    cardinality = _require_dict(transactions["cardinality"], "transactions.cardinality")
    _expect_keys(
        cardinality,
        ("hash", "block", "nonce", "from", "to", "requestedCardinalityNext"),
        "cardinality",
    )
    receipt_tx = _require_dict(transactions["receiptCreate"], "transactions.receiptCreate")
    _expect_keys(
        receipt_tx, ("hash", "block", "nonce", "from", "address"), "receiptCreate"
    )
    bind_tx = _require_dict(transactions["deployAndBind"], "transactions.deployAndBind")
    _expect_keys(
        bind_tx, ("hash", "block", "nonce", "from", "to"), "deployAndBind"
    )
    senders = {}
    nonces = {}
    blocks_by_name = {}
    for name, tx in transactions.items():
        if tx["hash"] != _hex(tx["hash"], 32, f"{name}.hash"):
            raise ManifestError(f"{name}.hash is not canonical lowercase hex")
        blocks_by_name[name] = _json_integer(tx["block"], f"{name}.block")
        if blocks_by_name[name] < 0:
            raise ManifestError(f"{name}.block cannot be negative")
        nonces[name] = _json_integer(tx["nonce"], f"{name}.nonce")
        if nonces[name] < 0:
            raise ManifestError(f"{name}.nonce cannot be negative")
        senders[name] = _address(tx["from"], f"{name}.from")
        if tx["from"] != senders[name]:
            raise ManifestError(f"{name}.from is not canonical lowercase hex")
    if len({tx["hash"] for tx in transactions.values()}) != len(transactions):
        raise ManifestError("FLM transaction hashes must be unique")
    if not (
        senders["cardinality"] == senders["receiptCreate"]
        and senders["cardinality"] != FORBIDDEN_OPERATOR
        and nonces["cardinality"] == 0
        and nonces["receiptCreate"] == 1
    ):
        raise ManifestError("cardinality and receipt CREATE lack fresh-key provenance")
    receipt = _address(receipt_tx["address"], "receiptCreate.address")
    if receipt_tx["address"] != receipt:
        raise ManifestError("receiptCreate.address is not canonical lowercase hex")
    if receipt != _create_address(senders["receiptCreate"], 1, hash_):
        raise ManifestError("receipt address is not CREATE(fresh deployer, nonce 1)")
    bind_target = _address(bind_tx["to"], "deployAndBind.to")
    if bind_tx["to"] != bind_target:
        raise ManifestError("deployAndBind.to is not canonical lowercase hex")
    if bind_target != receipt:
        raise ManifestError("deployAndBind target is not the receipt")
    requested_cardinality = _json_integer(
        cardinality["requestedCardinalityNext"], "requestedCardinalityNext"
    )
    if requested_cardinality < MIN_CARDINALITY_NEXT or requested_cardinality > 0xFFFF:
        raise ManifestError("requested cardinality is too small")
    cardinality_target = _address(cardinality["to"], "cardinality.to")
    if cardinality["to"] != cardinality_target:
        raise ManifestError("cardinality.to is not canonical lowercase hex")
    blocks = [blocks_by_name[name] for name in transactions]
    if blocks != sorted(blocks):
        raise ManifestError("FLM transaction blocks are out of order")

    bootstrap = _require_dict(section["bootstrap"], "flm.bootstrap")
    _expect_keys(bootstrap, ("companyAmount", "wethAmount"), "bootstrap")
    if any(_json_integer(value, key) <= 0 for key, value in bootstrap.items()):
        raise ManifestError("bootstrap amounts must be positive")

    dependencies = _require_dict(section["dependencies"], "flm.dependencies")
    _expect_keys(dependencies, DEPENDENCY_KEYS, "dependencies")
    for key, value in dependencies.items():
        item = _require_dict(value, f"dependencies.{key}")
        _expect_keys(item, ("target", "runtimeCodeKeccak256"), f"dependencies.{key}")
        target = _address(item["target"], f"dependencies.{key}.target")
        codehash = _hex(
            item["runtimeCodeKeccak256"],
            32,
            f"dependencies.{key}.runtimeCodeKeccak256",
        )
        if item["target"] != target or item["runtimeCodeKeccak256"] != codehash:
            raise ManifestError(f"dependencies.{key} is not canonical lowercase hex")
    if cardinality_target != dependencies["spotPool"]["target"]:
        raise ManifestError("cardinality transaction does not target dependencies.spotPool")
    pinned_targets = {
        "weth": WETH,
        "conditionalTokens": CTF,
        "wrapped1155Factory": WRAPPED_1155_FACTORY,
        "univ3Factory": UNIV3_FACTORY,
        "positionManager": POSITION_MANAGER,
    }
    for key, target in pinned_targets.items():
        if (
            dependencies[key]["target"] != target
            or dependencies[key]["runtimeCodeKeccak256"] != PINNED_CODEHASHES[key]
        ):
            raise ManifestError(f"dependency {key} is not the pinned Sepolia deployment")

    evidence = _validate_code_evidence(section["codeEvidence"])
    contracts = _require_dict(section["contracts"], "flm.contracts")
    _expect_keys(contracts, CONTRACT_KEYS, "contracts")
    addresses = []
    receipt_contract = _require_dict(contracts["receipt"], "contracts.receipt")
    _expect_keys(
        receipt_contract,
        (
            "address",
            "source",
            "contract",
            "creationCodeKeccak256",
            "runtimeCodeBytes",
            "runtimeCodeKeccak256",
        ),
        "contracts.receipt",
    )
    if (
        receipt_contract["address"] != receipt
        or receipt_contract["source"] != RECEIPT_TARGET.source
        or receipt_contract["contract"] != RECEIPT_TARGET.contract
    ):
        raise ManifestError("receipt compiler identity is inconsistent")
    receipt_creation_hash = _hex(
        receipt_contract["creationCodeKeccak256"], 32, "receipt creation hash"
    )
    if receipt_contract["creationCodeKeccak256"] != receipt_creation_hash:
        raise ManifestError("receipt creation hash is not canonical lowercase hex")
    if receipt_creation_hash != evidence["receipt"]["creationCodeKeccak256"]:
        raise ManifestError("receipt creation hash does not match canonical code evidence")
    if _json_integer(receipt_contract["runtimeCodeBytes"], "receipt runtime bytes") <= 0:
        raise ManifestError("receipt runtime is empty")
    receipt_runtime_hash = _hex(
        receipt_contract["runtimeCodeKeccak256"], 32, "receipt runtime hash"
    )
    if receipt_contract["runtimeCodeKeccak256"] != receipt_runtime_hash:
        raise ManifestError("receipt runtime hash is not canonical lowercase hex")
    addresses.append(receipt)
    children = {}
    for name, nonce, key in CHILDREN:
        item = _require_dict(contracts[name], f"contracts.{name}")
        _expect_keys(
            item,
            ("address", "createNonce", "baseCode", "runtimeCodeBytes", "runtimeCodeKeccak256"),
            f"contracts.{name}",
        )
        address = _address(item["address"], f"contracts.{name}.address")
        if (
            item["address"] != address
            or _json_integer(item["createNonce"], f"contracts.{name}.createNonce") != nonce
            or item["baseCode"] != key
        ):
            raise ManifestError(f"contracts.{name} has the wrong CREATE identity")
        if address != _create_address(receipt, nonce, hash_):
            raise ManifestError(f"contracts.{name} has the wrong predicted address")
        if _json_integer(item["runtimeCodeBytes"], f"contracts.{name}.runtimeCodeBytes") <= 0:
            raise ManifestError(f"contracts.{name} runtime is empty")
        runtime_hash = _hex(
            item["runtimeCodeKeccak256"],
            32,
            f"contracts.{name}.runtimeCodeKeccak256",
        )
        if item["runtimeCodeKeccak256"] != runtime_hash:
            raise ManifestError(f"contracts.{name} runtime hash is not canonical lowercase hex")
        addresses.append(address)
        children[name] = address
    if len(set(addresses)) != len(addresses) or FORBIDDEN_OPERATOR in addresses:
        raise ManifestError("FLM contract addresses must be unique and role-safe")
    roles = _require_dict(section["roles"], "flm.roles")
    expected_roles = {
        "managerOwner": DEAD,
        "bootstrapRecipient": receipt,
        "officialProposer": children["relay"],
        "proposalSource": children["relay"],
        "relayManager": children["manager"],
        "spotAdapterManager": children["manager"],
        "conditionalAdapterManager": children["manager"],
    }
    _expect_keys(roles, tuple(expected_roles), "roles")
    if roles != expected_roles:
        raise ManifestError("FLM role matrix is inconsistent")
    return section


def _dependency_objects(section: dict[str, Any]) -> dict[str, Dependency]:
    return {
        key: Dependency(value["target"], value["runtimeCodeKeccak256"])
        for key, value in section["dependencies"].items()
    }


def combine(
    w0_manifest: Any,
    flm: Any,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    w0 = site_deployment._validate_manifest(w0_manifest)
    section = _validate_flm(flm, hash_)
    _validate_dependencies(_dependency_objects(section), w0)
    if _address(
        section["transactions"]["cardinality"]["to"], "cardinality.to"
    ) != _address(w0["contracts"]["spotPool"], "W0 spotPool"):
        raise ManifestError("cardinality transaction does not target the W0 spot pool")
    if _address(
        section["transactions"]["receiptCreate"]["from"], "receiptCreate.from"
    ) == _address(w0["deployer"], "W0 deployer"):
        raise ManifestError("FLM receipt deployer must differ from the W0 deployer")
    combined = copy.deepcopy(w0)
    combined["schemaVersion"] = 2
    combined["flm"] = copy.deepcopy(section)
    return combined


def _validate_combined(
    raw: Any,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> dict[str, Any]:
    combined = _require_dict(raw, "combined manifest")
    expected = tuple(site_deployment.MANIFEST_KEYS) + ("flm",)
    if (
        set(combined) != set(expected)
        or _json_integer(combined.get("schemaVersion"), "schemaVersion") != 2
    ):
        raise ManifestError("combined manifest must be schema version 2 with one flm section")
    w0 = copy.deepcopy(combined)
    section = w0.pop("flm")
    w0["schemaVersion"] = 1
    site_deployment._validate_manifest(w0)
    _validate_flm(section, hash_)
    _validate_dependencies(_dependency_objects(section), w0)
    if _address(
        section["transactions"]["cardinality"]["to"], "cardinality.to"
    ) != _address(w0["contracts"]["spotPool"], "W0 spotPool"):
        raise ManifestError("cardinality transaction does not target the W0 spot pool")
    if _address(
        section["transactions"]["receiptCreate"]["from"], "receiptCreate.from"
    ) == _address(w0["deployer"], "W0 deployer"):
        raise ManifestError("FLM receipt deployer must differ from the W0 deployer")
    return combined


class CastClient:
    def __init__(self, rpc_url: str, cast_bin: str = "cast"):
        self.rpc_url = rpc_url
        self.cast_bin = shutil.which(cast_bin) or cast_bin

    def _run(self, *args: str) -> str:
        try:
            result = subprocess.run(
                [self.cast_bin, *args, "--rpc-url", self.rpc_url],
                text=True,
                capture_output=True,
                check=True,
            )
        except (OSError, subprocess.CalledProcessError) as exc:
            detail = getattr(exc, "stderr", "") or str(exc)
            raise ManifestError(f"cast command failed: {detail.strip()}") from exc
        return result.stdout.strip()

    def code(self, address: str) -> bytes:
        return _variable_bytes(self._run("code", address), f"code at {address}")

    def call(self, address: str, signature: str) -> str:
        return self._run("call", address, signature)

    def _rpc(self, method: str, *params: str) -> Any:
        raw = self._run("rpc", method, *params)
        try:
            return json.loads(raw, object_pairs_hook=site_deployment._object_without_duplicates)
        except json.JSONDecodeError as exc:
            raise ManifestError(f"cast rpc {method} returned invalid JSON") from exc

    def chain_id(self) -> int:
        return _quantity(self._rpc("eth_chainId"), "RPC chain ID")

    def transaction(self, tx_hash: str) -> dict[str, Any]:
        return _require_dict(
            self._rpc("eth_getTransactionByHash", tx_hash),
            f"RPC transaction {tx_hash}",
        )

    def receipt(self, tx_hash: str) -> dict[str, Any]:
        return _require_dict(
            self._rpc("eth_getTransactionReceipt", tx_hash),
            f"RPC receipt {tx_hash}",
        )


def _call_address(client: Any, address: str, signature: str) -> str:
    return _address(client.call(address, signature).split()[0], f"{address}.{signature}")


def _call_int(client: Any, address: str, signature: str) -> int:
    raw = client.call(address, signature).split()[0]
    try:
        return int(raw, 0)
    except ValueError as exc:
        raise ManifestError(f"{address}.{signature} returned a non-integer") from exc


def _call_bool(client: Any, address: str, signature: str) -> bool:
    value = client.call(address, signature).strip().lower()
    if value not in {"true", "false"}:
        raise ManifestError(f"{address}.{signature} returned a non-bool")
    return value == "true"


def _live_target(value: Any, name: str) -> str | None:
    return None if value in (None, "") else _address(value, name)


def _verify_live_transactions(section: dict[str, Any], client: Any) -> None:
    if client.chain_id() != CHAIN_ID:
        raise ManifestError(f"RPC chain must be Sepolia ({CHAIN_ID})")
    transactions = section["transactions"]
    for name, manifest_tx in transactions.items():
        tx_hash = manifest_tx["hash"]
        live_tx = _require_dict(client.transaction(tx_hash), f"live {name} transaction")
        live_receipt = _require_dict(client.receipt(tx_hash), f"live {name} receipt")
        if (
            _hex(live_tx.get("hash"), 32, f"live {name}.hash") != tx_hash
            or _hex(
                live_receipt.get("transactionHash"),
                32,
                f"live {name}.transactionHash",
            )
            != tx_hash
        ):
            raise ManifestError(f"live {name} transaction hash mismatch")
        if (
            _quantity(live_tx.get("blockNumber"), f"live {name}.blockNumber")
            != manifest_tx["block"]
            or _quantity(
                live_receipt.get("blockNumber"), f"live {name} receipt.blockNumber"
            )
            != manifest_tx["block"]
        ):
            raise ManifestError(f"live {name} block mismatch")
        if _quantity(live_tx.get("nonce"), f"live {name}.nonce") != manifest_tx["nonce"]:
            raise ManifestError(f"live {name} nonce mismatch")
        expected_sender = manifest_tx["from"]
        if (
            _address(live_tx.get("from"), f"live {name}.from") != expected_sender
            or _address(live_receipt.get("from"), f"live {name} receipt.from")
            != expected_sender
        ):
            raise ManifestError(f"live {name} sender mismatch")
        expected_target = None if name == "receiptCreate" else manifest_tx["to"]
        if (
            _live_target(live_tx.get("to"), f"live {name}.to") != expected_target
            or _live_target(live_receipt.get("to"), f"live {name} receipt.to")
            != expected_target
        ):
            raise ManifestError(f"live {name} target mismatch")
        if _quantity(live_receipt.get("status"), f"live {name}.status") != 1:
            raise ManifestError(f"live {name} transaction failed")
        contract_address = _live_target(
            live_receipt.get("contractAddress"), f"live {name}.contractAddress"
        )
        expected_contract = manifest_tx["address"] if name == "receiptCreate" else None
        if contract_address != expected_contract:
            raise ManifestError(f"live {name} receipt contract address mismatch")

    slot0 = client.call(
        transactions["cardinality"]["to"],
        "slot0()(uint160,int24,uint16,uint16,uint16,uint8,bool)",
    )
    lines = [line.strip() for line in slot0.splitlines() if line.strip()]
    if len(lines) != 7:
        raise ManifestError("spot pool slot0 returned a malformed tuple")
    try:
        cardinality_next = int(lines[4].split()[0], 0)
    except (IndexError, ValueError) as exc:
        raise ManifestError("spot pool slot0 returned an invalid cardinalityNext") from exc
    if cardinality_next < transactions["cardinality"]["requestedCardinalityNext"]:
        raise ManifestError("spot pool observationCardinalityNext is below the manifest request")


def _context_from_flm(section: dict[str, Any]) -> Context:
    children = {name: section["contracts"][name]["address"] for name, _, _ in CHILDREN}
    return Context(
        section["contracts"]["receipt"]["address"],
        children,
        _dependency_objects(section),
        section["bootstrap"]["companyAmount"],
        section["bootstrap"]["wethAmount"],
    )


def verify_rpc(
    manifest: Any,
    build_info: Path,
    client: Any,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> None:
    if isinstance(manifest, dict) and manifest.get("schemaVersion") == 2:
        section = _validate_combined(manifest, hash_)["flm"]
    else:
        section = _validate_flm(manifest, hash_)
    _verify_live_transactions(section, client)
    context = _context_from_flm(section)
    catalog = BuildCatalog(build_info)

    # Select compiler outputs using the manifest's creation hashes, then patch every immutable.
    compiled: dict[str, CompiledContract] = {}
    receipt_hash = section["contracts"]["receipt"]["creationCodeKeccak256"]
    compiled["RECEIPT"] = catalog._unique(
        [
            item
            for item in catalog.contracts["RECEIPT"]
            if _digest(item.creation, hash_) == receipt_hash
        ],
        RECEIPT_TARGET.contract,
    )
    for target in CODE_TARGETS:
        expected = section["codeEvidence"]["contracts"][target.key]["baseCreationCodeKeccak256"]
        compiled[target.key] = catalog._unique(
            [
                item
                for item in catalog.contracts[target.key]
                if _digest(item.creation, hash_) == expected
            ],
            target.contract,
        )
        _compiler_matches(compiled[target.key], section["codeEvidence"], hash_)
    _compiler_matches(compiled["RECEIPT"], section["codeEvidence"], hash_)

    expected_runtime = {
        "receipt": _patch_runtime(compiled["RECEIPT"], _immutable_values(RECEIPT_TARGET, context))
    }
    for name, _, key in CHILDREN:
        expected_runtime[name] = _patch_runtime(
            compiled[key], _immutable_values(TARGET_BY_KEY[key], context)
        )
    for name, code in expected_runtime.items():
        entry = section["contracts"][name]
        if (
            len(code) != entry["runtimeCodeBytes"]
            or _digest(code, hash_) != entry["runtimeCodeKeccak256"]
        ):
            raise ManifestError(f"manifest runtime evidence is stale for {name}")
        actual = client.code(entry["address"])
        if actual != code:
            raise ManifestError(
                f"deployed runtime does not match patched compiler output for {name}"
            )
    for key, dependency in context.dependencies.items():
        code = client.code(dependency.target)
        if not code or _digest(code, hash_) != dependency.codehash:
            raise ManifestError(f"dependency runtime mismatch for {key}")

    receipt = context.receipt
    c = context.children
    d = context.dependencies
    if not _call_bool(client, receipt, "isSealed()(bool)"):
        raise ManifestError("receipt is not sealed")
    address_calls = [
        (receipt, "relay()(address)", c["relay"]),
        (receipt, "spotAdapter()(address)", c["spotAdapter"]),
        (receipt, "conditionalAdapter()(address)", c["conditionalAdapter"]),
        (receipt, "guard()(address)", c["guard"]),
        (receipt, "router()(address)", c["router"]),
        (receipt, "manager()(address)", c["manager"]),
        (receipt, "WETH()(address)", d["weth"].target),
        (receipt, "COMPANY_TOKEN()(address)", d["companyToken"].target),
        (receipt, "CONDITIONAL_TOKENS()(address)", d["conditionalTokens"].target),
        (receipt, "WRAPPED_1155_FACTORY()(address)", d["wrapped1155Factory"].target),
        (receipt, "UNIV3_FACTORY()(address)", d["univ3Factory"].target),
        (receipt, "POSITION_MANAGER()(address)", d["positionManager"].target),
        (receipt, "SPOT_POOL()(address)", d["spotPool"].target),
        (receipt, "ARBITRATION()(address)", d["arbitration"].target),
        (receipt, "PIPELINE()(address)", d["pipeline"].target),
        (receipt, "ORCHESTRATOR()(address)", d["orchestrator"].target),
        (receipt, "RESOLVER()(address)", d["resolver"].target),
        (receipt, "FUTARCHY_FACTORY()(address)", d["futarchyFactory"].target),
        (c["relay"], "MANAGER()(address)", c["manager"]),
        (c["relay"], "ARBITRATION()(address)", d["arbitration"].target),
        (c["relay"], "PIPELINE()(address)", d["pipeline"].target),
        (c["relay"], "UNIV3_FACTORY()(address)", d["univ3Factory"].target),
        (c["relay"], "CTF()(address)", d["conditionalTokens"].target),
        (c["relay"], "COMPANY_TOKEN()(address)", d["companyToken"].target),
        (c["relay"], "CURRENCY_TOKEN()(address)", d["weth"].target),
        (c["spotAdapter"], "MANAGER()(address)", c["manager"]),
        (c["conditionalAdapter"], "MANAGER()(address)", c["manager"]),
        (c["spotAdapter"], "POSITION_MANAGER()(address)", d["positionManager"].target),
        (c["conditionalAdapter"], "POSITION_MANAGER()(address)", d["positionManager"].target),
        (c["guard"], "FACTORY()(address)", d["univ3Factory"].target),
        (c["router"], "CONDITIONAL_TOKENS()(address)", d["conditionalTokens"].target),
        (c["router"], "WRAPPED_1155_FACTORY()(address)", d["wrapped1155Factory"].target),
        (c["manager"], "owner()(address)", DEAD),
        (c["manager"], "BOOTSTRAP_RECIPIENT()(address)", receipt),
        (c["manager"], "OFFICIAL_PROPOSER()(address)", c["relay"]),
        (c["manager"], "PROPOSAL_SOURCE()(address)", c["relay"]),
        (c["manager"], "SPOT_ADAPTER()(address)", c["spotAdapter"]),
        (c["manager"], "CONDITIONAL_ADAPTER()(address)", c["conditionalAdapter"]),
        (c["manager"], "CONDITIONAL_ROUTER()(address)", c["router"]),
        (c["manager"], "POOL_STABILITY_GUARD()(address)", c["guard"]),
        (c["manager"], "COMPANY_TOKEN()(address)", d["companyToken"].target),
        (c["manager"], "WRAPPED_NATIVE()(address)", d["weth"].target),
    ]
    for target, signature, expected in address_calls:
        if _call_address(client, target, signature) != expected:
            raise ManifestError(f"role/dependency mismatch: {target}.{signature}")
    int_calls = [
        (receipt, "BOOTSTRAP_COMPANY_AMOUNT()(uint256)", context.bootstrap_company),
        (receipt, "BOOTSTRAP_WETH_AMOUNT()(uint256)", context.bootstrap_weth),
        (c["relay"], "FEE_TIER()(uint24)", FEE_TIER),
        (c["spotAdapter"], "DEFAULT_TICK_LOWER()(int24)", TICK_LOWER),
        (c["spotAdapter"], "DEFAULT_TICK_UPPER()(int24)", TICK_UPPER),
        (c["conditionalAdapter"], "DEFAULT_TICK_LOWER()(int24)", TICK_LOWER),
        (c["conditionalAdapter"], "DEFAULT_TICK_UPPER()(int24)", TICK_UPPER),
        (c["guard"], "FEE()(uint24)", FEE_TIER),
    ]
    for target, signature, expected in int_calls:
        if _call_int(client, target, signature) != expected:
            raise ManifestError(f"numeric wiring mismatch: {target}.{signature}")


def _write_or_check(path: Path, value: dict[str, Any], check: bool) -> None:
    expected = (json.dumps(value, indent=2) + "\n").encode("utf-8")
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


def _run_build_command(command: list[str], root: Path) -> None:
    try:
        subprocess.run(command, cwd=root, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise ManifestError(f"build-evidence command failed: {' '.join(command)}") from exc


def _smoke_build_info(
    root: Path,
    build_info: Path,
    evidence: Any,
    *,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> None:
    """Prove the union can select and fully patch every canonical runtime."""
    evidence = _validate_code_evidence(evidence)
    catalog = BuildCatalog(build_info)
    receipt_compiled = catalog._unique(
        catalog.contracts[RECEIPT_TARGET.key], RECEIPT_TARGET.contract
    )
    receipt_evidence = evidence["receipt"]
    if (
        len(receipt_compiled.creation) != receipt_evidence["creationCodeBytes"]
        or _digest(receipt_compiled.creation, hash_)
        != receipt_evidence["creationCodeKeccak256"]
    ):
        raise ManifestError("canonical receipt creation code is stale")
    _compiler_matches(receipt_compiled, evidence, hash_)

    compiled = {RECEIPT_TARGET.key: receipt_compiled}
    for target in CODE_TARGETS:
        item = evidence["contracts"][target.key]
        path = root / item["baseCreationCodePath"]
        try:
            code = path.read_bytes()
        except OSError as exc:
            raise ManifestError(f"cannot read canonical base creation code {path}: {exc}") from exc
        if (
            len(code) != item["baseCreationCodeBytes"]
            or _digest(code, hash_) != item["baseCreationCodeKeccak256"]
        ):
            raise ManifestError(f"canonical {target.key} base creation code is stale")
        compiled[target.key] = catalog.exact(target, code)
        _compiler_matches(compiled[target.key], evidence, hash_)

    receipt = "0x1000000000000000000000000000000000000001"
    children = {
        name: _create_address(receipt, nonce, hash_) for name, nonce, _ in CHILDREN
    }
    dependencies = {
        key: Dependency(
            f"0x{index + 0x100:040x}",
            f"0x{index + 1:064x}",
        )
        for index, key in enumerate(DEPENDENCY_KEYS)
    }
    context = Context(receipt, children, dependencies, 1, 1)
    _patch_runtime(
        compiled[RECEIPT_TARGET.key], _immutable_values(RECEIPT_TARGET, context)
    )
    for name, _, key in CHILDREN:
        _patch_runtime(compiled[key], _immutable_values(TARGET_BY_KEY[key], context))


def prepare_build_info(
    root: Path = ROOT,
    *,
    runner: Callable[[list[str], Path], None] = _run_build_command,
    python_bin: str = sys.executable,
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> Path:
    """Build a clean, durable union of receipt and canonical FLM compiler evidence."""
    destination = root / "build-info/flm-deployment"
    shutil.rmtree(destination, ignore_errors=True)
    transient = root / "out/build-info"
    shutil.rmtree(transient, ignore_errors=True)
    runner([python_bin, str(root / "tools/flm_code_hashes.py"), "--check"], root)
    files = sorted(transient.rglob("*.json")) if transient.is_dir() else []
    if not files:
        raise ManifestError("FLM evidence build produced no build-info JSON")
    for source in files:
        target = destination / source.relative_to(transient)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, target)

    evidence = site_deployment.load_json(root / "metadata/sepolia-flm-code-hashes.json")
    _smoke_build_info(root, destination, evidence, hash_=hash_)
    return destination


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    subparsers.add_parser("prepare-build-info")

    from_broadcast = subparsers.add_parser("from-broadcast")
    from_broadcast.add_argument("--broadcast", required=True, type=Path)
    from_broadcast.add_argument("--w0", required=True, type=Path)
    from_broadcast.add_argument(
        "--code-hashes", type=Path, default=ROOT / "metadata/sepolia-flm-code-hashes.json"
    )
    from_broadcast.add_argument("--build-info", type=Path, default=DEFAULT_BUILD_INFO)
    from_broadcast.add_argument("--out", type=Path, default=ROOT / "deployments/sepolia-flm.json")
    from_broadcast.add_argument("--check", action="store_true")

    combine_parser = subparsers.add_parser("combine")
    combine_parser.add_argument("--w0", required=True, type=Path)
    combine_parser.add_argument("--flm", required=True, type=Path)
    combine_parser.add_argument("--out", required=True, type=Path)
    combine_parser.add_argument("--check", action="store_true")

    verify = subparsers.add_parser("verify")
    verify.add_argument("--manifest", required=True, type=Path)
    verify.add_argument("--build-info", type=Path, default=DEFAULT_BUILD_INFO)
    verify.add_argument("--rpc-url", required=True)
    verify.add_argument("--cast-bin", default="cast")
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    _require_clean_tracked_root()
    pinned_flm_sha = _pinned_flm_sha()
    canonical_evidence = _validate_code_evidence(
        site_deployment.load_json(ROOT / "metadata/sepolia-flm-code-hashes.json")
    )
    if canonical_evidence["flmSubmoduleSha"] != pinned_flm_sha:
        raise ManifestError("canonical FLM code evidence is stale for the pinned submodule")
    if args.command == "prepare-build-info":
        destination = prepare_build_info()
        print(f"FLM compiler evidence prepared and patched successfully: {destination}")
    elif args.command == "from-broadcast":
        section = flm_from_broadcast(
            site_deployment.load_json(args.broadcast),
            site_deployment.load_json(args.w0),
            site_deployment.load_json(args.code_hashes),
            args.build_info,
        )
        _require_pinned_evidence(section, pinned_flm_sha, canonical_evidence)
        _write_or_check(args.out, section, args.check)
    elif args.command == "combine":
        flm = site_deployment.load_json(args.flm)
        _require_pinned_evidence(flm, pinned_flm_sha, canonical_evidence)
        value = combine(site_deployment.load_json(args.w0), flm)
        _write_or_check(args.out, value, args.check)
    else:
        manifest = site_deployment.load_json(args.manifest)
        _require_pinned_evidence(manifest, pinned_flm_sha, canonical_evidence)
        verify_rpc(
            manifest,
            args.build_info,
            CastClient(args.rpc_url, args.cast_bin),
        )
        print("FLM deployment, code, sealing, and role matrix verified")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except ManifestError as exc:
        print(f"flm_deployment.py: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
