#!/usr/bin/env python3
"""Regenerate the sealed FLM loader's base creation-code hashes."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Callable


ROOT = Path(__file__).resolve().parents[1]
FLM_PATH = Path("lib/futarchy-liquidity-manager")
MANIFEST_PATH = Path("metadata/sepolia-flm-code-hashes.json")
SOLIDITY_PATH = Path("src/generated/FlmCodeHashes.sol")
BLOB_DIR = Path("metadata/flm-creation-code")
LOADER_SCRIPT = "script/DeploySepoliaFlmBundle.s.sol"


@dataclass(frozen=True)
class Target:
    constant: str
    source: str
    contract: str

    @property
    def artifact(self) -> Path:
        return Path("out") / Path(self.source).name / f"{self.contract}.json"

    @property
    def blob(self) -> Path:
        return BLOB_DIR / f"{self.constant.lower()}.bin"


TARGETS = (
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
RECEIPT_TARGET = Target(
    "RECEIPT", "src/SepoliaFlmBundleDeployment.sol", "SepoliaFlmBundleDeployment"
)


@dataclass(frozen=True)
class CompiledTarget:
    target: Target
    code: bytes
    solc_version: str
    settings: dict[str, Any]


class GenerationError(ValueError):
    pass


def _run(command: list[str], root: Path, *, input_: str | None = None) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=root,
            input=input_,
            text=True,
            capture_output=input_ is not None,
            check=True,
        )
    except (OSError, subprocess.CalledProcessError) as exc:
        detail = getattr(exc, "stderr", "") or str(exc)
        raise GenerationError(f"command failed: {' '.join(command)}: {detail.strip()}") from exc
    return result.stdout.strip() if input_ is not None else ""


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode("utf-8")


def keccak256(value: bytes) -> str:
    cast = shutil.which("cast")
    if not cast:
        raise GenerationError("Foundry cast is required for Ethereum Keccak-256")
    digest = _run([cast, "keccak"], ROOT, input_="0x" + value.hex())
    if not re.fullmatch(r"0x[0-9a-f]{64}", digest):
        raise GenerationError(f"cast returned an invalid Keccak-256 digest: {digest!r}")
    return digest


def _submodule_sha(root: Path) -> str:
    status = _run(
        ["git", "-C", str(root / FLM_PATH), "status", "--porcelain", "--untracked-files=all"],
        root,
        input_="",
    )
    if status:
        raise GenerationError(f"{FLM_PATH} must be clean before hashing")

    head = _run(["git", "-C", str(root / FLM_PATH), "rev-parse", "HEAD"], root, input_="")
    indexed = _run(["git", "ls-files", "--stage", "--", str(FLM_PATH)], root, input_="")
    fields = indexed.split()
    if len(fields) != 4 or fields[0] != "160000" or not re.fullmatch(r"[0-9a-f]{40}", head):
        raise GenerationError(f"{FLM_PATH} is not a pinned git submodule")
    if fields[1] != head:
        raise GenerationError(f"{FLM_PATH} HEAD {head} does not match pinned gitlink {fields[1]}")
    return head


def _build(root: Path, *sources: str) -> None:
    forge = shutil.which("forge")
    if not forge:
        raise GenerationError("Foundry forge is required to compile the sealed FLM targets")
    _run(
        [
            forge,
            "build",
            "--no-cache",
            "--build-info",
            *sources,
        ],
        root,
    )


def _metadata(value: Any, path: Path) -> dict[str, Any]:
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except json.JSONDecodeError as exc:
            raise GenerationError(f"invalid compiler metadata in {path}") from exc
    if not isinstance(value, dict):
        raise GenerationError(f"missing compiler metadata in {path}")
    return value


def _read_target(root: Path, target: Target) -> CompiledTarget:
    path = root / target.artifact
    try:
        artifact = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise GenerationError(f"cannot read Foundry artifact {path}: {exc}") from exc

    metadata = _metadata(artifact.get("metadata"), path)
    settings = metadata.get("settings")
    compiler = metadata.get("compiler")
    if not isinstance(settings, dict) or not isinstance(compiler, dict):
        raise GenerationError(f"incomplete compiler evidence in {path}")
    expected_target = {target.source: target.contract}
    if settings.get("compilationTarget") != expected_target:
        raise GenerationError(f"stale or colliding artifact {path}; expected {expected_target}")
    normalized_settings = dict(settings)
    normalized_settings.pop("compilationTarget")

    bytecode = artifact.get("bytecode")
    if not isinstance(bytecode, dict) or bytecode.get("linkReferences") != {}:
        raise GenerationError(f"{target.contract} has unresolved creation-code links")
    raw = bytecode.get("object")
    if not isinstance(raw, str) or not raw.startswith("0x"):
        raise GenerationError(f"missing creation bytecode for {target.contract}")
    body = raw[2:]
    if not body or len(body) % 2 or not re.fullmatch(r"[0-9a-fA-F]+", body):
        raise GenerationError(f"{target.contract} creation code contains an unresolved placeholder")

    version = compiler.get("version")
    if not isinstance(version, str) or not version:
        raise GenerationError(f"missing solc version in {path}")
    return CompiledTarget(target, bytes.fromhex(body), version, normalized_settings)


def _outputs(
    compiled: tuple[CompiledTarget, ...],
    receipt: CompiledTarget,
    flm_sha: str,
    hash_: Callable[[bytes], str] = keccak256,
) -> tuple[bytes, bytes]:
    version, common_settings = _compiler_context((*compiled, receipt))
    fingerprint = hash_(_canonical({"solcVersion": version, "settings": common_settings}))
    hashes = {item.target.constant: hash_(item.code) for item in compiled}
    manifest = {
        "schemaVersion": 2,
        "flmSubmoduleSha": flm_sha,
        "compiler": {
            "solcVersion": version,
            "solcSettingsKeccak256": fingerprint,
        },
        "receipt": {
            "source": RECEIPT_TARGET.source,
            "contract": RECEIPT_TARGET.contract,
            "creationCodeBytes": len(receipt.code),
            "creationCodeKeccak256": hash_(receipt.code),
        },
        "contracts": {
            item.target.constant: {
                "source": item.target.source,
                "contract": item.target.contract,
                "baseCreationCodePath": item.target.blob.as_posix(),
                "baseCreationCodeBytes": len(item.code),
                "baseCreationCodeKeccak256": hashes[item.target.constant],
            }
            for item in compiled
        },
    }
    return (
        json.dumps(manifest, indent=2).encode("utf-8") + b"\n",
        _solidity(compiled, hash_),
    )


def _compiler_context(compiled: tuple[CompiledTarget, ...]) -> tuple[str, dict[str, Any]]:
    versions = {item.solc_version for item in compiled}
    settings = {_canonical(item.settings) for item in compiled}
    if len(versions) != 1 or len(settings) != 1:
        raise GenerationError("sealed FLM targets were not built with one solc/settings context")
    return versions.pop(), json.loads(settings.pop())


def _solidity(
    compiled: tuple[CompiledTarget, ...],
    hash_: Callable[[bytes], str] = keccak256,
) -> bytes:
    hashes = {item.target.constant: hash_(item.code) for item in compiled}
    return "\n".join(
        [
            "// SPDX-License-Identifier: MIT",
            "pragma solidity 0.8.20;",
            "",
            "// Generated by tools/flm_code_hashes.py. Do not edit.",
            "library FlmCodeHashes {",
            *(
                line
                for target in TARGETS
                for line in (
                    f"    bytes32 internal constant {target.constant} =",
                    f"        {hashes[target.constant]};",
                )
            ),
            "}",
            "",
        ]
    ).encode("utf-8")


def _write_or_check(path: Path, content: bytes, check: bool) -> None:
    if check:
        try:
            current = path.read_bytes()
        except OSError as exc:
            raise GenerationError(f"generated file is missing: {path}") from exc
        if current != content:
            raise GenerationError(f"generated file is stale: {path}")
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(content)


def generate(root: Path = ROOT, *, check: bool = False) -> None:
    flm_sha = _submodule_sha(root)
    _build(root, *(target.source for target in TARGETS))
    compiled = tuple(_read_target(root, target) for target in TARGETS)
    _compiler_context(compiled)
    prospective_solidity = _solidity(compiled)
    _write_or_check(root / SOLIDITY_PATH, prospective_solidity, check)

    _build(root, LOADER_SCRIPT)
    receipt = _read_target(root, RECEIPT_TARGET)
    manifest, solidity = _outputs(compiled, receipt, flm_sha)
    if solidity != prospective_solidity:
        raise GenerationError("generated Solidity changed between compiler contexts")
    _write_or_check(root / MANIFEST_PATH, manifest, check)
    for item in compiled:
        _write_or_check(root / item.target.blob, item.code, check)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if committed output is stale")
    args = parser.parse_args(argv)
    try:
        generate(check=args.check)
    except GenerationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print("FLM code-hash evidence is current" if args.check else "generated FLM code-hash evidence")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
