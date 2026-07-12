#!/usr/bin/env python3
"""Regenerate reproducible economic-core creation-code evidence."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import sys
from pathlib import Path
from typing import Any, Callable

try:
    from tools import flm_code_hashes
except ModuleNotFoundError:  # pragma: no cover - direct script execution
    import flm_code_hashes  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
BUILD_ROOT = Path("build-info/economic-core-code-hashes")
BUILD_INFO_PATH = BUILD_ROOT / "build-info"
MANIFEST_PATH = Path("metadata/economic-core-code-hashes.json")

Target = flm_code_hashes.Target
CompiledTarget = flm_code_hashes.CompiledTarget
GenerationError = flm_code_hashes.GenerationError

TARGETS = (
    Target("ARBITRATION", "src/FutarchyArbitration.sol", "FutarchyArbitration"),
    Target("VAULT", "src/GenesisVault.sol", "GenesisVault"),
    Target(
        "RELEASE_STRATEGY",
        "src/SXArbitrationExecutionStrategy.sol",
        "SXArbitrationExecutionStrategy",
    ),
    Target(
        "ZERO_VOTING", "src/AlwaysZeroVotingStrategy.sol", "AlwaysZeroVotingStrategy"
    ),
    Target("ECON_GATEWAY", "src/EconGateway.sol", "EconGateway"),
    Target(
        "ECON_EVALUATOR",
        "src/FAOEconomicEvaluationPipeline.sol",
        "FAOEconomicEvaluationPipeline",
    ),
)


def _build(root: Path) -> None:
    forge = shutil.which("forge")
    if not forge:
        raise GenerationError("Foundry forge is required to compile the economic core")

    build_root = root / BUILD_ROOT
    shutil.rmtree(build_root, ignore_errors=True)
    build_root.mkdir(parents=True)
    flm_code_hashes._run(
        [
            forge,
            "build",
            "--no-cache",
            "--build-info",
            "--out",
            str(BUILD_ROOT / "out"),
            "--build-info-path",
            str(BUILD_INFO_PATH),
            *(target.source for target in TARGETS),
        ],
        root,
    )


def _compiler_bytes(value: Any, label: str) -> bytes:
    if not isinstance(value, str):
        raise GenerationError(f"missing creation bytecode for {label}")
    body = value[2:] if value.startswith("0x") else value
    if not body or len(body) % 2 or not re.fullmatch(r"[0-9a-fA-F]+", body):
        raise GenerationError(f"{label} creation code contains an unresolved placeholder")
    return bytes.fromhex(body)


def _build_info_target(path: Path, target: Target, raw: Any) -> CompiledTarget:
    if not isinstance(raw, dict):
        raise GenerationError(f"invalid build-info contract output for {target.contract} in {path}")
    evm = raw.get("evm")
    bytecode = evm.get("bytecode") if isinstance(evm, dict) else None
    if not isinstance(bytecode, dict) or bytecode.get("linkReferences") != {}:
        raise GenerationError(f"{target.contract} has unresolved creation-code links in {path}")
    code = _compiler_bytes(bytecode.get("object"), target.contract)

    metadata = flm_code_hashes._metadata(raw.get("metadata"), path)
    settings = metadata.get("settings")
    compiler = metadata.get("compiler")
    if not isinstance(settings, dict) or not isinstance(compiler, dict):
        raise GenerationError(f"incomplete compiler evidence for {target.contract} in {path}")
    if settings.get("compilationTarget") != {target.source: target.contract}:
        raise GenerationError(f"wrong compilation target for {target.contract} in {path}")
    normalized_settings = dict(settings)
    normalized_settings.pop("compilationTarget")
    remappings = normalized_settings.get("remappings")
    if isinstance(remappings, list):
        if not all(isinstance(item, str) for item in remappings):
            raise GenerationError(f"invalid compiler remappings for {target.contract} in {path}")
        normalized_settings["remappings"] = [
            item[1:] if item.startswith(":") else item for item in remappings
        ]

    version = compiler.get("version")
    if not isinstance(version, str) or not version:
        raise GenerationError(f"missing solc version for {target.contract} in {path}")
    return CompiledTarget(target, code, version, normalized_settings)


def _read_build_info(root: Path, target: Target) -> CompiledTarget:
    directory = root / BUILD_INFO_PATH
    files = sorted(directory.glob("*.json"))
    if not files:
        raise GenerationError(f"no build-info JSON found under {directory}")

    matches: list[CompiledTarget] = []
    for path in files:
        try:
            value = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise GenerationError(f"cannot read build-info {path}: {exc}") from exc
        output = value.get("output") if isinstance(value, dict) else None
        contracts = output.get("contracts") if isinstance(output, dict) else None
        by_source = contracts.get(target.source) if isinstance(contracts, dict) else None
        raw = by_source.get(target.contract) if isinstance(by_source, dict) else None
        if raw is not None:
            matches.append(_build_info_target(path, target, raw))

    if not matches:
        raise GenerationError(f"no exact build-info output found for {target.contract}")
    identity = (matches[0].code, matches[0].solc_version, matches[0].settings)
    if any((item.code, item.solc_version, item.settings) != identity for item in matches[1:]):
        raise GenerationError(f"ambiguous build-info outputs for {target.contract}")
    return matches[0]


def _read_compiled(root: Path, target: Target) -> CompiledTarget:
    artifact = flm_code_hashes._read_target(root / BUILD_ROOT, target)
    build_info = _read_build_info(root, target)
    if artifact != build_info:
        raise GenerationError(f"artifact/build-info mismatch for {target.contract}")
    return artifact


def _output(
    compiled: tuple[CompiledTarget, ...],
    hash_: Callable[[bytes], str] = flm_code_hashes.keccak256,
) -> bytes:
    version, settings = flm_code_hashes._compiler_context(compiled)
    manifest = {
        "schemaVersion": 1,
        "compiler": {
            "solcVersion": version,
            "solcSettingsKeccak256": hash_(flm_code_hashes._canonical(settings)),
        },
        "contracts": {
            item.target.constant: {
                "source": item.target.source,
                "contract": item.target.contract,
                "baseCreationCodeBytes": len(item.code),
                "baseCreationCodeKeccak256": hash_(item.code),
            }
            for item in compiled
        },
    }
    return json.dumps(manifest, indent=2).encode("utf-8") + b"\n"


def generate(root: Path = ROOT, *, check: bool = False) -> None:
    _build(root)
    compiled = tuple(_read_compiled(root, target) for target in TARGETS)
    flm_code_hashes._write_or_check(root / MANIFEST_PATH, _output(compiled), check)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if committed output is stale")
    args = parser.parse_args(argv)
    try:
        generate(check=args.check)
    except GenerationError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print(
        "economic-core code-hash evidence is current"
        if args.check
        else "generated economic-core code-hash evidence"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
