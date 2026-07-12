#!/usr/bin/env python3
"""Build and preflight the immutable Snapshot X / ERC-4824 metadata bundle.

Build:
  python3 tools/fao_metadata.py build --manifest deployments/sepolia-site-release.json \
    --avatar-uri ipfs://CID --out metadata/sepolia-site-release

Pre-broadcast build from a predicted address:
  python3 tools/fao_metadata.py build --release-strategy 0xPREDICTED \
    --avatar-uri ipfs://CID --out metadata/sepolia-site-release

Preflight after pinning (this command never uploads or broadcasts):
  python3 tools/fao_metadata.py preflight --bundle metadata/sepolia-site-release/bundle.json \
    --gateway 'https://ipfs.io/ipfs/{cid}' \
    --gateway 'https://dweb.link/ipfs/{cid}' \
    --avatar-gateway 'https://ipfs.io/ipfs/{cid}'

Pin exact JSON bytes, reject CID drift, then preflight Pineapple's gateway:
  python3 tools/fao_metadata.py pin --bundle metadata/sepolia-site-release/bundle.json \
    --endpoint https://pineapple.fyi/ \
    --avatar-gateway 'https://ipfs.io/ipfs/{cid}'
"""

from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import urllib.error
import urllib.parse
import urllib.request
from functools import lru_cache
from pathlib import Path
from typing import Any


CHAIN_ID = 11_155_111
CONTEXT = "https://www.daostar.org/schemas"
CONTRACTS = {
    "deploymentReceipt": ("Deployment receipt", "Atomic immutable deployment receipt."),
    "siteToken": ("Site token", "Test site market token."),
    "spotPool": ("Spot pool", "Uniswap V3 site-token spot market."),
    "proposalImplementation": (
        "Proposal implementation",
        "Conditional-market proposal implementation.",
    ),
    "stackDeployer": ("Stack deployer", "Immutable proposal-market stack deployer."),
    "space": ("Snapshot X space", "Ownerless no-vote Snapshot X space."),
    "arbitration": (
        "Futarchy arbitration",
        "Futarchy and unchallenged-YES-bond decision engine.",
    ),
    "proposalGateway": (
        "Proposal gateway",
        "Proposal-only Snapshot X authenticator.",
    ),
    "releaseStrategy": (
        "Release strategy",
        "Futarchy-gated site-release execution strategy.",
    ),
    "votingStrategy": (
        "No-vote strategy",
        "Always-zero Snapshot X compatibility voting strategy.",
    ),
    "evaluator": ("Evaluator", "Permissionless market-evaluation pipeline."),
    "orchestrator": (
        "Orchestrator",
        "Official conditional-market proposal orchestrator.",
    ),
    "twapResolver": ("TWAP resolver", "Conditional-market TWAP resolver."),
    "futarchyFactory": ("Futarchy factory", "Conditional-market factory."),
}
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
FILES = (
    "always-zero-voting-strategy.json",
    "vanilla-proposal-validation-strategy.json",
    "space.json",
    "members.json",
    "contracts.json",
    "governance.json",
    "dao.json",
)
CANDIDATE_FILES = tuple(name for name in FILES if name != "contracts.json")
DEPLOYMENT_URIS = {
    "daoURI": "dao.json",
    "spaceMetadataURI": "space.json",
    "votingStrategyMetadataURI": "always-zero-voting-strategy.json",
    "proposalValidationStrategyMetadataURI": "vanilla-proposal-validation-strategy.json",
}
ZERO_STRATEGY = {
    "name": "No voting",
    "description": (
        "Compatibility-only Snapshot X strategy. It always returns zero voting power "
        "and never determines proposal status or execution."
    ),
    "properties": {"symbol": "NO-VOTE", "decimals": 0},
}
PROPOSAL_VALIDATION = {
    "name": "Vanilla proposal validation",
    "description": "Allows any author accepted by the proposal-only authenticator to propose.",
    "properties": {},
}
GOVERNANCE = {
    "@context": CONTEXT,
    "name": "FAO Governed Site (Sepolia) governance",
    "description": (
        "There is no voting. Snapshot X is only the indexed proposal and execution "
        "envelope, and its sole voting strategy always returns zero voting power. A "
        "release is accepted only when the on-chain futarchy evaluation recommends YES "
        "or a YES activation bond remains unchallenged through the arbitration period. "
        "An accepted proposal may replace the entire governed site. Snapshot X votes "
        "never determine proposal status or execution."
    ),
}
HEX_ADDRESS = re.compile(r"0x[0-9a-fA-F]{40}\Z")
HEX_HASH = re.compile(r"0x[0-9a-fA-F]{64}\Z")
BASE58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"


class MetadataError(ValueError):
    pass


def _unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise MetadataError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _load_json(path: Path) -> Any:
    try:
        return json.loads(
            path.read_text(encoding="utf-8"), object_pairs_hook=_unique_object
        )
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise MetadataError(f"cannot read JSON {path}: {exc}") from exc


def _json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")


def _address(value: Any, name: str) -> str:
    if not isinstance(value, str) or not HEX_ADDRESS.fullmatch(value):
        raise MetadataError(f"{name} must be a 20-byte 0x address")
    if int(value, 16) == 0:
        raise MetadataError(f"{name} cannot be zero")
    return value.lower()


@lru_cache(maxsize=None)
def _checksum_address(value: str) -> str:
    value = _address(value, "address")
    cast = shutil.which("cast")
    if not cast:
        raise MetadataError("Foundry cast is required to checksum Ethereum addresses")
    result = subprocess.run(
        [cast, "to-check-sum-address", value],
        check=False,
        capture_output=True,
        text=True,
    )
    checksum = result.stdout.strip()
    if result.returncode or not HEX_ADDRESS.fullmatch(checksum) or checksum.lower() != value:
        raise MetadataError(f"cast could not checksum address {value}")
    return checksum


def _manifest(raw: Any) -> dict[str, Any]:
    if not isinstance(raw, dict) or set(raw) != MANIFEST_KEYS:
        raise MetadataError("manifest must contain exactly the canonical deployment fields")
    if (
        raw["schemaVersion"] != 1
        or raw["status"] != "active"
        or raw["network"] != "sepolia"
        or raw["chainId"] != CHAIN_ID
    ):
        raise MetadataError("manifest must be an active Sepolia schema version 1 deployment")
    if not isinstance(raw["deploymentTransaction"], str) or not HEX_HASH.fullmatch(
        raw["deploymentTransaction"]
    ):
        raise MetadataError("deploymentTransaction must be a 32-byte 0x hash")
    if (
        isinstance(raw["deploymentBlock"], bool)
        or not isinstance(raw["deploymentBlock"], int)
        or raw["deploymentBlock"] < 0
    ):
        raise MetadataError("deploymentBlock must be a non-negative integer")
    _address(raw["deployer"], "deployer")
    _address(raw["currencyToken"], "currencyToken")
    if (
        isinstance(raw["feeTier"], bool)
        or not isinstance(raw["feeTier"], int)
        or not 0 <= raw["feeTier"] <= 0xFFFFFF
    ):
        raise MetadataError("feeTier must fit uint24")
    contracts = raw["contracts"]
    if not isinstance(contracts, dict) or tuple(contracts) != tuple(CONTRACTS):
        raise MetadataError("contracts must use the complete canonical order")
    for key, value in contracts.items():
        _address(value, f"contracts.{key}")
    return raw


def _base58_decode(value: str) -> bytes:
    number = 0
    try:
        for char in value:
            number = number * 58 + BASE58.index(char)
    except ValueError as exc:
        raise MetadataError("invalid base58 CID") from exc
    body = number.to_bytes((number.bit_length() + 7) // 8, "big")
    return b"\0" * (len(value) - len(value.lstrip("1"))) + body


def _varint(data: bytes, offset: int) -> tuple[int, int]:
    value = shift = 0
    while offset < len(data) and shift <= 63:
        byte = data[offset]
        offset += 1
        value |= (byte & 0x7F) << shift
        if byte < 0x80:
            return value, offset
        shift += 7
    raise MetadataError("invalid CID varint")


def _decode_cid(cid: str) -> tuple[int, bytes]:
    if cid.startswith("Qm") and len(cid) == 46:
        raw = _base58_decode(cid)
        if len(raw) != 34 or raw[:2] != b"\x12\x20":
            raise MetadataError("CIDv0 must use a 32-byte sha2-256 multihash")
        return 0x70, raw[2:]
    if not re.fullmatch(r"b[a-z2-7]+", cid):
        raise MetadataError("CID must be canonical CIDv0 or lowercase base32 CIDv1")
    encoded = cid[1:].upper()
    try:
        raw = base64.b32decode(encoded + "=" * ((-len(encoded)) % 8))
    except ValueError as exc:
        raise MetadataError("invalid base32 CID") from exc
    if "b" + base64.b32encode(raw).decode().lower().rstrip("=") != cid:
        raise MetadataError("CIDv1 is not canonically encoded")
    version, offset = _varint(raw, 0)
    codec, offset = _varint(raw, offset)
    hash_code, offset = _varint(raw, offset)
    digest_length, offset = _varint(raw, offset)
    digest = raw[offset:]
    if version != 1 or hash_code != 0x12 or digest_length != 32 or len(digest) != 32:
        raise MetadataError("CIDv1 must use a 32-byte sha2-256 multihash")
    return codec, digest


def _ipfs_cid(uri: Any, name: str) -> str:
    if not isinstance(uri, str) or not uri.startswith("ipfs://"):
        raise MetadataError(f"{name} must be an ipfs:// URI")
    parsed = urllib.parse.urlsplit(uri)
    if parsed.scheme != "ipfs" or not parsed.netloc or parsed.path or parsed.query or parsed.fragment:
        raise MetadataError(f"{name} must contain one bare immutable CID")
    _decode_cid(parsed.netloc)
    return parsed.netloc


def _raw_uri(data: bytes) -> str:
    raw = b"\x01\x55\x12\x20" + hashlib.sha256(data).digest()
    return "ipfs://b" + base64.b32encode(raw).decode().lower().rstrip("=")


def _space(release: str, avatar: str) -> dict[str, Any]:
    return {
        "name": "FAO Governed Site (Sepolia)",
        "avatar": avatar,
        "description": (
            "No-vote Snapshot X envelope for testnet.futarchy.ai. Site releases are "
            "selected by futarchy or an unchallenged YES bond."
        ),
        "external_url": "https://testnet.futarchy.ai",
        "properties": {
            "voting_power_symbol": "NO-VOTE",
            "cover": "",
            "github": "futarchy-fi",
            "twitter": "",
            "discord": "",
            "farcaster": "",
            "clanker": "",
            "treasuries": [],
            "labels": [
                {
                    "id": "site-release",
                    "name": "Site release",
                    "description": (
                        "A complete release of testnet.futarchy.ai and its governed repository."
                    ),
                    "color": "#6E56CF",
                }
            ],
            "delegations": [],
            "execution_strategies": [release],
            "execution_strategies_types": ["SXArbitrationExecutionStrategy"],
            "execution_destinations": [""],
        },
    }


def _documents_for_release(
    release: str, avatar_uri: str, contracts: dict[str, Any] | None = None
) -> dict[str, bytes]:
    release = _checksum_address(release)
    avatar = f"ipfs://{_ipfs_cid(avatar_uri, 'avatarURI')}"
    members = {"@context": CONTEXT, "type": "DAO", "members": []}
    documents = {
        "always-zero-voting-strategy.json": _json_bytes(ZERO_STRATEGY),
        "vanilla-proposal-validation-strategy.json": _json_bytes(PROPOSAL_VALIDATION),
        "space.json": _json_bytes(_space(release, avatar)),
        "members.json": _json_bytes(members),
    }
    if contracts is not None:
        documents["contracts.json"] = _json_bytes(
            {
                "@context": CONTEXT,
                "contracts": [
                    {
                        "id": f"eip155:{CHAIN_ID}:{_checksum_address(contracts[key])}",
                        "name": name,
                        "description": description,
                    }
                    for key, (name, description) in CONTRACTS.items()
                ],
            }
        )
    documents["governance.json"] = _json_bytes(GOVERNANCE)
    dao = {
        "@context": CONTEXT,
        "type": "DAO",
        "name": "FAO Governed Site (Sepolia)",
        "description": (
            "No-vote Snapshot X envelope governing complete testnet.futarchy.ai releases."
        ),
        "membersURI": _raw_uri(documents["members.json"]),
        "governanceURI": _raw_uri(documents["governance.json"]),
    }
    if contracts is not None:
        dao["contractsURI"] = _raw_uri(documents["contracts.json"])
    documents["dao.json"] = _json_bytes(dao)
    return documents


def _documents(manifest: dict[str, Any], avatar_uri: str) -> dict[str, bytes]:
    contracts = manifest["contracts"]
    return _documents_for_release(contracts["releaseStrategy"], avatar_uri, contracts)


def _validate_documents(documents: dict[str, bytes], avatar_uri: str) -> None:
    if tuple(documents) not in {FILES, CANDIDATE_FILES}:
        raise MetadataError("bundle must contain the canonical metadata files in order")
    try:
        parsed = {
            name: json.loads(documents[name], object_pairs_hook=_unique_object)
            for name in documents
            if name.endswith(".json")
        }
    except (UnicodeError, json.JSONDecodeError) as exc:
        raise MetadataError(f"invalid metadata JSON: {exc}") from exc
    if parsed[FILES[0]] != ZERO_STRATEGY or parsed[FILES[1]] != PROPOSAL_VALIDATION:
        raise MetadataError("strategy metadata does not match the canonical definitions")
    space = parsed["space.json"]
    if not isinstance(space, dict) or set(space) != {
        "name",
        "avatar",
        "description",
        "external_url",
        "properties",
    }:
        raise MetadataError("space metadata fields are not canonical")
    if space["avatar"] != avatar_uri:
        raise MetadataError("space avatar does not match the bundle")
    properties = space["properties"]
    if not isinstance(properties, dict):
        raise MetadataError("space properties are not canonical")
    try:
        execution = properties["execution_strategies"]
        types = properties["execution_strategies_types"]
        destinations = properties["execution_destinations"]
    except KeyError as exc:
        raise MetadataError("space execution arrays are required") from exc
    if (
        not isinstance(execution, list)
        or not isinstance(types, list)
        or not isinstance(destinations, list)
        or len(execution) != 1
        or len(types) != 1
        or len(destinations) != 1
    ):
        raise MetadataError("space execution arrays must each contain one item")
    if types[0] != "SXArbitrationExecutionStrategy" or destinations[0] != "":
        raise MetadataError("space execution type or destination is not canonical")
    if _checksum_address(execution[0]) != execution[0]:
        raise MetadataError("space release strategy must be checksummed")
    members = parsed["members.json"]
    if members != {"@context": CONTEXT, "type": "DAO", "members": []}:
        raise MetadataError("members metadata must be the canonical empty no-vote list")
    release = execution[0]
    if "contracts.json" in parsed:
        contracts = parsed["contracts.json"]
        if (
            not isinstance(contracts, dict)
            or set(contracts) != {"@context", "contracts"}
            or contracts["@context"] != CONTEXT
        ):
            raise MetadataError("contracts metadata fields are not canonical")
        entries = contracts["contracts"]
        if not isinstance(entries, list) or len(entries) != len(CONTRACTS):
            raise MetadataError("contracts metadata must list every canonical contract")
        for entry, (key, (name, description)) in zip(entries, CONTRACTS.items()):
            if not isinstance(entry, dict) or set(entry) != {"id", "name", "description"}:
                raise MetadataError("contract entries must contain id, name and description")
            prefix = f"eip155:{CHAIN_ID}:"
            if not isinstance(entry["id"], str) or not entry["id"].startswith(prefix):
                raise MetadataError("contract ids must be Sepolia CAIP-10 identifiers")
            address = entry["id"][len(prefix) :]
            if _checksum_address(address) != address:
                raise MetadataError("contract ids must use checksummed addresses")
            if entry["name"] != name or entry["description"] != description:
                raise MetadataError(f"contract metadata is not canonical for {key}")
            if key == "releaseStrategy" and execution != [address]:
                raise MetadataError("space execution strategy does not match contracts metadata")
    if space != _space(release, avatar_uri):
        raise MetadataError("space metadata does not match the canonical no-vote definition")
    dao = parsed["dao.json"]
    expected_dao_keys = {
        "@context",
        "type",
        "name",
        "description",
        "membersURI",
        "governanceURI",
    }
    if "contracts.json" in documents:
        expected_dao_keys.add("contractsURI")
    if not isinstance(dao, dict) or set(dao) != expected_dao_keys:
        raise MetadataError("DAO metadata fields are not canonical")
    if dao["@context"] != CONTEXT or dao["type"] != "DAO":
        raise MetadataError("DAO metadata must use the ERC-4824 context and type")
    linked_files = [("membersURI", "members.json"), ("governanceURI", "governance.json")]
    if "contracts.json" in documents:
        linked_files.append(("contractsURI", "contracts.json"))
    for field, file_name in linked_files:
        _ipfs_cid(dao[field], field)
        if dao[field] != _raw_uri(documents[file_name]):
            raise MetadataError(f"{field} does not identify the exact local bytes")
    expected_dao = {
        "@context": CONTEXT,
        "type": "DAO",
        "name": "FAO Governed Site (Sepolia)",
        "description": (
            "No-vote Snapshot X envelope governing complete testnet.futarchy.ai releases."
        ),
        "membersURI": _raw_uri(documents["members.json"]),
        "governanceURI": _raw_uri(documents["governance.json"]),
    }
    if "contracts.json" in documents:
        expected_dao["contractsURI"] = _raw_uri(documents["contracts.json"])
    if dao != expected_dao:
        raise MetadataError("DAO metadata does not match the canonical ERC-4824 definition")
    if parsed["governance.json"] != GOVERNANCE:
        raise MetadataError("governance metadata is not canonical")


def _write_or_check(path: Path, data: bytes, check: bool) -> None:
    if check:
        try:
            if path.read_bytes() != data:
                raise MetadataError(f"generated file is stale: {path}")
        except OSError as exc:
            raise MetadataError(f"cannot check {path}: {exc}") from exc
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(data)
    try:
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def build_bundle(
    manifest: dict[str, Any], avatar_uri: str, out: Path, check: bool = False
) -> dict[str, Any]:
    manifest = _manifest(manifest)
    return _build_bundle(_documents(manifest, avatar_uri), avatar_uri, out, check)


def build_predicted_bundle(
    release_strategy: str, avatar_uri: str, out: Path, check: bool = False
) -> dict[str, Any]:
    _address(release_strategy, "releaseStrategy")
    return _build_bundle(
        _documents_for_release(release_strategy, avatar_uri), avatar_uri, out, check
    )


def _build_bundle(
    documents: dict[str, bytes], avatar_uri: str, out: Path, check: bool
) -> dict[str, Any]:
    avatar_uri = f"ipfs://{_ipfs_cid(avatar_uri, 'avatarURI')}"
    _validate_documents(documents, avatar_uri)
    file_entries = {
        name: {
            "uri": _raw_uri(data),
            "sha256": hashlib.sha256(data).hexdigest(),
            "mediaType": "application/json",
        }
        for name, data in documents.items()
    }
    bundle = {
        "schemaVersion": 1,
        "network": "sepolia",
        "chainId": CHAIN_ID,
        "files": file_entries,
        "deploymentURIs": {
            key: file_entries[file_name]["uri"] for key, file_name in DEPLOYMENT_URIS.items()
        },
        "externalURIs": {"avatar": avatar_uri},
    }
    for name, data in documents.items():
        _write_or_check(out / name, data, check)
    _write_or_check(out / "bundle.json", _json_bytes(bundle), check)
    return bundle


def _bundle(path: Path) -> tuple[dict[str, Any], dict[str, bytes]]:
    bundle = _load_json(path)
    required = {
        "schemaVersion",
        "network",
        "chainId",
        "files",
        "deploymentURIs",
        "externalURIs",
    }
    if (
        not isinstance(bundle, dict)
        or set(bundle) != required
        or bundle["schemaVersion"] != 1
        or bundle["network"] != "sepolia"
        or bundle["chainId"] != CHAIN_ID
    ):
        raise MetadataError("bundle identity or fields are not canonical")
    files = bundle["files"]
    if not isinstance(files, dict) or tuple(files) not in {FILES, CANDIDATE_FILES}:
        raise MetadataError("bundle files are not canonical")
    documents: dict[str, bytes] = {}
    for name, entry in files.items():
        if not isinstance(entry, dict) or set(entry) != {"uri", "sha256", "mediaType"}:
            raise MetadataError(f"bundle entry is invalid: {name}")
        if entry["mediaType"] != "application/json":
            raise MetadataError(f"bundle media type is invalid: {name}")
        cid = _ipfs_cid(entry["uri"], f"files.{name}.uri")
        codec, digest = _decode_cid(cid)
        if codec != 0x55:
            raise MetadataError(f"generated file must use a raw CID: {name}")
        try:
            data = (path.parent / name).read_bytes()
        except OSError as exc:
            raise MetadataError(f"cannot read bundle file {name}: {exc}") from exc
        documents[name] = data
        sha256 = hashlib.sha256(data).digest()
        if digest != sha256 or entry["sha256"] != sha256.hex():
            raise MetadataError(f"local bytes do not match bundle CID/hash: {name}")
    if bundle["deploymentURIs"] != {
        key: files[file_name]["uri"] for key, file_name in DEPLOYMENT_URIS.items()
    }:
        raise MetadataError("deployment URIs do not match their bundle files")
    external = bundle["externalURIs"]
    if not isinstance(external, dict) or set(external) != {"avatar"}:
        raise MetadataError("bundle external URIs are not canonical")
    avatar_uri = f"ipfs://{_ipfs_cid(external['avatar'], 'externalURIs.avatar')}"
    _validate_documents(documents, avatar_uri)
    return bundle, documents


def _gateway_url(gateway: str, cid: str) -> str:
    url = gateway.replace("{cid}", cid) if "{cid}" in gateway else f"{gateway.rstrip('/')}/ipfs/{cid}"
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise MetadataError(f"gateway must be an HTTP(S) URL: {gateway}")
    return url


def _fetch(url: str, timeout: float) -> bytes:
    request = urllib.request.Request(url, headers={"User-Agent": "fao-metadata-preflight/1"})
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            return response.read()
    except (OSError, urllib.error.HTTPError, urllib.error.URLError) as exc:
        raise MetadataError(f"cannot fetch {url}: {exc}") from exc


def _pin_json(endpoint: str, value: Any, request_id: str, timeout: float) -> str:
    parsed = urllib.parse.urlsplit(endpoint)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise MetadataError(f"pin endpoint must be an HTTP(S) URL: {endpoint}")
    request = urllib.request.Request(
        endpoint,
        data=_json_bytes({"jsonrpc": "2.0", "id": request_id, "params": value}),
        headers={
            "Content-Type": "application/json",
            "User-Agent": "fao-metadata-pin/1",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=timeout) as response:
            result = json.loads(response.read(), object_pairs_hook=_unique_object)
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise MetadataError(f"cannot pin {request_id}: {exc}") from exc
    if not isinstance(result, dict) or result.get("jsonrpc") != "2.0" or result.get("id") != request_id:
        raise MetadataError(f"invalid JSON-RPC response while pinning {request_id}")
    if "error" in result:
        raise MetadataError(f"pinning failed for {request_id}: {result['error']}")
    receipt = result.get("result")
    if not isinstance(receipt, dict) or not isinstance(receipt.get("cid"), str):
        raise MetadataError(f"pinning response has no CID for {request_id}")
    return receipt["cid"]


def pin_bundle(
    path: Path,
    endpoint: str,
    gateways: list[str] | None = None,
    avatar_gateways: list[str] | None = None,
    timeout: float = 20,
) -> tuple[int, int]:
    if not avatar_gateways:
        raise MetadataError("at least one avatar gateway is required")
    bundle, documents = _bundle(path)
    parsed_endpoint = urllib.parse.urlsplit(endpoint)
    if parsed_endpoint.scheme not in {"http", "https"} or not parsed_endpoint.netloc:
        raise MetadataError(f"pin endpoint must be an HTTP(S) URL: {endpoint}")
    gateways = gateways or [f"{endpoint.rstrip('/')}/ipfs/{{cid}}"]
    sample_cid = _ipfs_cid(next(iter(bundle["files"].values()))["uri"], "bundle file URI")
    for gateway in gateways:
        _gateway_url(gateway, sample_cid)
    avatar_cid = _ipfs_cid(bundle["externalURIs"]["avatar"], "externalURIs.avatar")
    if _decode_cid(avatar_cid)[0] != 0x55:
        raise MetadataError("avatar must use a raw CID for exact byte verification")
    for gateway in avatar_gateways:
        _gateway_url(gateway, avatar_cid)
    for name, entry in bundle["files"].items():
        try:
            value = json.loads(documents[name], object_pairs_hook=_unique_object)
        except (UnicodeError, json.JSONDecodeError) as exc:
            raise MetadataError(f"cannot pin invalid JSON {name}: {exc}") from exc
        if _json_bytes(value) != documents[name]:
            raise MetadataError(f"JSON is not canonical for Pineapple: {name}")
        expected = _ipfs_cid(entry["uri"], f"files.{name}.uri")
        actual = _pin_json(endpoint, value, name, timeout)
        if actual != expected:
            raise MetadataError(
                f"Pineapple CID mismatch for {name}: expected {expected}, received {actual}"
            )
    checked = preflight_bundle(path, gateways, avatar_gateways, timeout)
    return len(documents), checked


def preflight_bundle(
    path: Path,
    gateways: list[str],
    avatar_gateways: list[str],
    timeout: float = 20,
) -> int:
    if not gateways:
        raise MetadataError("at least one metadata gateway is required")
    if not avatar_gateways:
        raise MetadataError("at least one avatar gateway is required")
    bundle, documents = _bundle(path)
    checked = 0
    for gateway in gateways:
        for name, entry in bundle["files"].items():
            cid = _ipfs_cid(entry["uri"], f"files.{name}.uri")
            url = _gateway_url(gateway, cid)
            if _fetch(url, timeout) != documents[name]:
                raise MetadataError(f"gateway bytes do not match {name}: {url}")
            checked += 1
    avatar_cid = _ipfs_cid(bundle["externalURIs"]["avatar"], "externalURIs.avatar")
    codec, digest = _decode_cid(avatar_cid)
    if codec != 0x55:
        raise MetadataError("avatar must use a raw CID for exact byte verification")
    errors = []
    for gateway in avatar_gateways:
        try:
            avatar = _fetch(_gateway_url(gateway, avatar_cid), timeout)
            if hashlib.sha256(avatar).digest() != digest:
                raise MetadataError(f"gateway avatar does not match its CID: {gateway}")
            checked += 1
            break
        except MetadataError as exc:
            errors.append(str(exc))
    else:
        raise MetadataError(f"avatar failed every configured gateway: {'; '.join(errors)}")
    return checked


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    build = commands.add_parser("build")
    source = build.add_mutually_exclusive_group(required=True)
    source.add_argument("--manifest", type=Path)
    source.add_argument("--release-strategy")
    build.add_argument("--avatar-uri", required=True)
    build.add_argument("--out", type=Path, default=Path("metadata/sepolia-site-release"))
    build.add_argument("--check", action="store_true")
    preflight = commands.add_parser("preflight")
    preflight.add_argument("--bundle", required=True, type=Path)
    preflight.add_argument("--gateway", required=True, action="append")
    preflight.add_argument("--avatar-gateway", required=True, action="append")
    preflight.add_argument("--timeout", type=float, default=20)
    pin = commands.add_parser("pin")
    pin.add_argument("--bundle", required=True, type=Path)
    pin.add_argument("--endpoint", required=True)
    pin.add_argument("--gateway", action="append")
    pin.add_argument("--avatar-gateway", required=True, action="append")
    pin.add_argument("--timeout", type=float, default=20)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    if args.command == "build":
        bundle = (
            build_bundle(_load_json(args.manifest), args.avatar_uri, args.out, args.check)
            if args.manifest
            else build_predicted_bundle(
                args.release_strategy, args.avatar_uri, args.out, args.check
            )
        )
        for key, value in bundle["deploymentURIs"].items():
            print(f"{key}={value}")
    elif args.command == "preflight":
        print(
            f"preflighted {preflight_bundle(args.bundle, args.gateway, args.avatar_gateway, args.timeout)} URI fetches"
        )
    else:
        pinned, checked = pin_bundle(
            args.bundle,
            args.endpoint,
            args.gateway,
            args.avatar_gateway,
            args.timeout,
        )
        print(f"pinned {pinned} JSON files; preflighted {checked} URI fetches")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MetadataError as exc:
        print(f"fao_metadata.py: {exc}", file=sys.stderr)
        raise SystemExit(1) from exc
