from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import economic_code_hashes


def fake_keccak(value: bytes) -> str:
    return "0x" + hashlib.sha256(value).hexdigest()


class EconomicCodeHashesTest(unittest.TestCase):
    def build_info(
        self,
        root: Path,
        target: economic_code_hashes.Target,
        *,
        name: str = "build.json",
        code: str = "0x6000",
        links: object | None = None,
    ) -> Path:
        path = root / economic_code_hashes.BUILD_INFO_PATH / name
        path.parent.mkdir(parents=True, exist_ok=True)
        value = {
            "output": {
                "contracts": {
                    target.source: {
                        target.contract: {
                            "metadata": {
                                "compiler": {"version": "0.8.20"},
                                "settings": {
                                    "compilationTarget": {
                                        target.source: target.contract
                                    },
                                    "optimizer": {"enabled": True, "runs": 200},
                                    "remappings": [":forge-std/=lib/forge-std/src/"],
                                    "viaIR": True,
                                },
                            },
                            "evm": {
                                "bytecode": {
                                    "object": code,
                                    "linkReferences": {} if links is None else links,
                                }
                            },
                        }
                    }
                }
            }
        }
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_build_isolated_fresh_foundry_evidence(self) -> None:
        with tempfile.TemporaryDirectory() as directory, mock.patch.object(
            economic_code_hashes.shutil, "which", return_value="/forge"
        ), mock.patch.object(economic_code_hashes.flm_code_hashes, "_run") as run:
            root = Path(directory)
            stale = root / economic_code_hashes.BUILD_ROOT / "stale"
            stale.parent.mkdir(parents=True)
            stale.write_text("stale", encoding="utf-8")

            economic_code_hashes._build(root)

        self.assertFalse(stale.exists())
        command = run.call_args.args[0]
        self.assertEqual(command[:4], ["/forge", "build", "--no-cache", "--build-info"])
        self.assertIn(str(economic_code_hashes.BUILD_ROOT / "out"), command)
        self.assertIn(str(economic_code_hashes.BUILD_INFO_PATH), command)
        self.assertEqual(
            command[-len(economic_code_hashes.COMPILER_TARGETS) :],
            [target.source for target in economic_code_hashes.COMPILER_TARGETS],
        )

    def test_build_info_requires_exact_unlinked_unambiguous_output(self) -> None:
        target = economic_code_hashes.TARGETS[0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with self.assertRaisesRegex(economic_code_hashes.GenerationError, "no build-info"):
                economic_code_hashes._read_build_info(root, target)

            self.build_info(root, target)
            compiled = economic_code_hashes._read_build_info(root, target)
            self.assertEqual(compiled.code, b"\x60\x00")
            self.assertEqual(
                compiled.settings["remappings"], ["forge-std/=lib/forge-std/src/"]
            )

            self.build_info(root, target, name="other.json", code="0x6001")
            with self.assertRaisesRegex(economic_code_hashes.GenerationError, "ambiguous"):
                economic_code_hashes._read_build_info(root, target)

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            self.build_info(root, target, links={"Library.sol": {}})
            with self.assertRaisesRegex(economic_code_hashes.GenerationError, "unresolved"):
                economic_code_hashes._read_build_info(root, target)

    def test_artifact_must_exactly_match_build_info(self) -> None:
        target = economic_code_hashes.TARGETS[0]
        compiled = economic_code_hashes.CompiledTarget(
            target, b"artifact", "0.8.20", {"viaIR": True}
        )
        changed = economic_code_hashes.CompiledTarget(
            target, b"different", "0.8.20", {"viaIR": True}
        )
        with mock.patch.object(
            economic_code_hashes.flm_code_hashes, "_read_target", return_value=compiled
        ), mock.patch.object(economic_code_hashes, "_read_build_info", return_value=changed):
            with self.assertRaisesRegex(economic_code_hashes.GenerationError, "mismatch"):
                economic_code_hashes._read_compiled(Path("/repo"), target)

    def test_manifest_is_deterministic_and_rejects_mixed_contexts(self) -> None:
        settings = {"optimizer": {"enabled": True, "runs": 200}, "viaIR": True}
        compiled = tuple(
            economic_code_hashes.CompiledTarget(
                target, bytes([index]), "0.8.20", settings
            )
            for index, target in enumerate(economic_code_hashes.TARGETS, start=1)
        )
        first = economic_code_hashes._output(compiled, fake_keccak)
        self.assertEqual(first, economic_code_hashes._output(compiled, fake_keccak))
        manifest = json.loads(first)
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(tuple(manifest["contracts"]), tuple(t.constant for t in economic_code_hashes.TARGETS))
        self.assertEqual(
            tuple(target.constant for target in economic_code_hashes.DEPLOYMENT_TARGETS),
            ("RECEIPT", "REGISTRAR", "PROPOSAL_IMPLEMENTATION", "STACK_DEPLOYER"),
        )
        for item in compiled:
            evidence = manifest["contracts"][item.target.constant]
            self.assertEqual(evidence["baseCreationCodeBytes"], len(item.code))
            self.assertEqual(evidence["baseCreationCodeKeccak256"], fake_keccak(item.code))

        mixed = (*compiled[:-1], economic_code_hashes.CompiledTarget(
            compiled[-1].target, compiled[-1].code, "0.8.21", settings
        ))
        with self.assertRaisesRegex(economic_code_hashes.GenerationError, "one solc/settings"):
            economic_code_hashes._output(mixed, fake_keccak)

        solidity = economic_code_hashes._solidity(compiled, fake_keccak).decode()
        for target in economic_code_hashes.DEPLOYMENT_TARGETS:
            self.assertIn(f"constant {target.constant}", solidity)
            self.assertIn(fake_keccak(compiled[economic_code_hashes.TARGETS.index(target)].code), solidity)
            self.assertEqual(
                economic_code_hashes.deployment_blob(target),
                economic_code_hashes.BLOB_DIR / f"{target.constant.lower()}.bin",
            )

        executor = economic_code_hashes.CompiledTarget(
            economic_code_hashes.EXECUTOR_RUNTIME_TARGET,
            b"creation",
            "0.8.20",
            settings,
        )
        runtime = b"\x60" + bytes(32) + b"\x00"
        evidence = json.loads(
            economic_code_hashes._executor_runtime_output(
                executor, runtime, ((1, 32),), fake_keccak
            )
        )
        self.assertEqual(evidence["deployedRuntime"]["template"], "0x" + runtime.hex())
        self.assertEqual(
            evidence["deployedRuntime"]["immutableReferences"],
            [{"start": 1, "length": 32}],
        )
        self.assertEqual(
            evidence["compiler"]["solcSettingsKeccak256"],
            fake_keccak(economic_code_hashes.flm_code_hashes._canonical(settings)),
        )

    def test_browser_bundle_is_exact_and_rejects_stale_flm_blobs(self) -> None:
        settings = {"optimizer": {"enabled": True, "runs": 200}, "viaIR": True}
        compiled = tuple(
            economic_code_hashes.CompiledTarget(
                target, bytes([index]), "0.8.20", settings
            )
            for index, target in enumerate(economic_code_hashes.TARGETS, start=1)
        )
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            contracts = {}
            for index, target in enumerate(
                economic_code_hashes.flm_code_hashes.TARGETS, start=101
            ):
                code = bytes([index])
                path = root / target.blob
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(code)
                contracts[target.constant] = {
                    "baseCreationCodeBytes": len(code),
                    "baseCreationCodeKeccak256": fake_keccak(code),
                }
            manifest_path = root / economic_code_hashes.flm_code_hashes.MANIFEST_PATH
            manifest_path.parent.mkdir(parents=True, exist_ok=True)
            manifest_path.write_text(
                json.dumps({"schemaVersion": 2, "contracts": contracts}) + "\n",
                encoding="utf-8",
            )

            raw = economic_code_hashes._browser_bundle(root, compiled, fake_keccak)
            bundle = json.loads(raw)
            self.assertEqual(bundle["schemaVersion"], 1)
            self.assertEqual(
                tuple(bundle["creationCodes"]["core"]),
                tuple(target.constant for target in economic_code_hashes.CORE_TARGETS),
            )
            self.assertEqual(
                tuple(bundle["creationCodes"]["flm"]),
                tuple(
                    target.constant
                    for target in economic_code_hashes.flm_code_hashes.TARGETS
                ),
            )
            self.assertEqual(
                bundle["creationCodes"]["receipt"],
                "0x" + compiled[len(economic_code_hashes.CORE_TARGETS)].code.hex(),
            )
            self.assertEqual(
                bundle["codeHashes"]["receipt"],
                fake_keccak(compiled[len(economic_code_hashes.CORE_TARGETS)].code),
            )
            for section in ("core", "flm"):
                for key, code in bundle["creationCodes"][section].items():
                    self.assertEqual(
                        bundle["codeHashes"][section][key],
                        fake_keccak(bytes.fromhex(code[2:])),
                    )

            first_flm = economic_code_hashes.flm_code_hashes.TARGETS[0]
            (root / first_flm.blob).write_bytes(b"changed")
            with self.assertRaisesRegex(
                economic_code_hashes.GenerationError, "length mismatch"
            ):
                economic_code_hashes._browser_bundle(root, compiled, fake_keccak)


if __name__ == "__main__":
    unittest.main()
