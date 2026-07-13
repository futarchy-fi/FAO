#!/usr/bin/env python3
"""Generate the standalone AgentWorkIndex CREATE2 and bytecode evidence."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Any

try:
    from tools.flm_code_hashes import keccak256
except ModuleNotFoundError:  # Direct script execution.
    from flm_code_hashes import keccak256  # type: ignore


ROOT = Path(__file__).resolve().parents[1]
SOURCE = "src/AgentWorkIndex.sol"
CONTRACT = "AgentWorkIndex"
ARTIFACT = Path("out/AgentWorkIndex.sol/AgentWorkIndex.json")
MANIFEST = Path("metadata/agent-work-index.json")
CREATE2_PROXY = "0x4e59b44847b379578588920ca78fbf26c0b4956c"
SALT_PREIMAGE = "FAO_AGENT_WORK_INDEX_V1"


class EvidenceError(ValueError):
    pass


def _run(command: list[str], root: Path) -> None:
    try:
        subprocess.run(command, cwd=root, check=True)
    except (OSError, subprocess.CalledProcessError) as exc:
        raise EvidenceError(f"command failed: {' '.join(command)}") from exc


def _code(artifact: dict[str, Any], key: str, label: str) -> bytes:
    value = artifact.get(key)
    if not isinstance(value, dict) or value.get("linkReferences") != {}:
        raise EvidenceError(f"{label} has unresolved links")
    raw = value.get("object")
    if not isinstance(raw, str) or not re.fullmatch(r"0x[0-9a-fA-F]+", raw) or len(raw) % 2:
        raise EvidenceError(f"{label} bytecode is missing")
    return bytes.fromhex(raw[2:])


def _compiled(root: Path) -> tuple[bytes, bytes, str, dict[str, Any]]:
    path = root / ARTIFACT
    try:
        artifact = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise EvidenceError(f"cannot read {path}") from exc
    metadata = artifact.get("metadata")
    if isinstance(metadata, str):
        metadata = json.loads(metadata)
    if not isinstance(metadata, dict):
        raise EvidenceError("compiler metadata is missing")
    compiler = metadata.get("compiler")
    settings = metadata.get("settings")
    if not isinstance(compiler, dict) or not isinstance(settings, dict):
        raise EvidenceError("compiler identity is incomplete")
    if settings.get("compilationTarget") != {SOURCE: CONTRACT}:
        raise EvidenceError("artifact compilation target is stale")
    normalized = dict(settings)
    normalized.pop("compilationTarget")
    version = compiler.get("version")
    if not isinstance(version, str) or not version:
        raise EvidenceError("solc version is missing")
    return (
        _code(artifact, "bytecode", "creation"),
        _code(artifact, "deployedBytecode", "runtime"),
        version,
        normalized,
    )


def _canonical(value: Any) -> bytes:
    return json.dumps(value, sort_keys=True, separators=(",", ":")).encode()


def _manifest(
    creation: bytes,
    runtime: bytes,
    solc_version: str,
    settings: dict[str, Any],
) -> bytes:
    salt = bytes.fromhex(keccak256(SALT_PREIMAGE.encode())[2:])
    creation_hash = bytes.fromhex(keccak256(creation)[2:])
    deployer = bytes.fromhex(CREATE2_PROXY[2:])
    predicted = "0x" + keccak256(b"\xff" + deployer + salt + creation_hash)[-40:]
    value = {
        "schemaVersion": 1,
        "source": SOURCE,
        "contract": CONTRACT,
        "compiler": {
            "solcVersion": solc_version,
            "solcSettingsKeccak256": keccak256(_canonical(settings)),
        },
        "creationCodeBytes": len(creation),
        "creationCodeKeccak256": "0x" + creation_hash.hex(),
        "runtimeCodeBytes": len(runtime),
        "runtimeCodeKeccak256": keccak256(runtime),
        "create2": {
            "deployer": CREATE2_PROXY,
            "saltPreimage": SALT_PREIMAGE,
            "salt": "0x" + salt.hex(),
            "predictedAddress": predicted,
        },
        "economicBytecodeIncluded": False,
    }
    return json.dumps(value, indent=2).encode() + b"\n"


def generate(root: Path = ROOT, *, check: bool = False) -> None:
    forge = shutil.which("forge")
    if not forge:
        raise EvidenceError("Foundry forge is required")
    _run([forge, "build", "--no-cache", "--build-info", SOURCE], root)
    creation, runtime, version, settings = _compiled(root)
    content = _manifest(creation, runtime, version, settings)
    path = root / MANIFEST
    if check:
        try:
            current = path.read_bytes()
        except OSError as exc:
            raise EvidenceError(f"generated file is missing: {path}") from exc
        if current != content:
            raise EvidenceError(f"generated file is stale: {path}")
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args(argv)
    try:
        generate(check=args.check)
    except EvidenceError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    print("AgentWorkIndex evidence is current" if args.check else "generated AgentWorkIndex evidence")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
