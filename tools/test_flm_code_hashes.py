from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

from tools import flm_code_hashes


def fake_keccak(value: bytes) -> str:
    return "0x" + hashlib.sha256(value).hexdigest()


class FlmCodeHashesTest(unittest.TestCase):
    def artifact(self, root: Path, target: flm_code_hashes.Target, **bytecode: object) -> Path:
        path = root / target.artifact
        path.parent.mkdir(parents=True, exist_ok=True)
        value = {
            "metadata": {
                "compiler": {"version": "0.8.20+commit.a1b79de6"},
                "settings": {
                    "compilationTarget": {target.source: target.contract},
                    "optimizer": {"enabled": True, "runs": 200},
                    "viaIR": True,
                    "evmVersion": "shanghai",
                },
            },
            "bytecode": {"object": "0x6000", "linkReferences": {}, **bytecode},
        }
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def test_known_ethereum_keccak_vector(self) -> None:
        self.assertEqual(
            flm_code_hashes.keccak256(b""),
            "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470",
        )

    def test_two_context_builds_are_fresh_and_keep_build_info(self) -> None:
        with mock.patch.object(
            flm_code_hashes.shutil, "which", return_value="/forge"
        ), mock.patch.object(flm_code_hashes, "_run") as run:
            flm_code_hashes._build(
                Path("/repo"), *(target.source for target in flm_code_hashes.TARGETS)
            )
            flm_code_hashes._build(Path("/repo"), flm_code_hashes.LOADER_SCRIPT)

        child_command = run.call_args_list[0].args[0]
        receipt_command = run.call_args_list[1].args[0]
        prefix = ["/forge", "build", "--no-cache", "--build-info"]
        self.assertEqual(child_command[:4], prefix)
        self.assertEqual(
            child_command[4:], [target.source for target in flm_code_hashes.TARGETS]
        )
        self.assertEqual(receipt_command, [*prefix, flm_code_hashes.LOADER_SCRIPT])

    def test_reads_only_exact_unlinked_creation_code(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            target = flm_code_hashes.TARGETS[0]
            self.artifact(root, target)
            self.assertEqual(flm_code_hashes._read_target(root, target).code, b"\x60\x00")

            self.artifact(root, target, linkReferences={"Library.sol": {}})
            with self.assertRaisesRegex(flm_code_hashes.GenerationError, "unresolved"):
                flm_code_hashes._read_target(root, target)

            self.artifact(root, target, object="0x60__$placeholder$__")
            with self.assertRaisesRegex(flm_code_hashes.GenerationError, "placeholder"):
                flm_code_hashes._read_target(root, target)

    def test_outputs_are_deterministic_and_share_one_compiler_context(self) -> None:
        settings = {"optimizer": {"enabled": True, "runs": 200}, "viaIR": True}
        compiled = tuple(
            flm_code_hashes.CompiledTarget(target, bytes([index]), "0.8.20", settings)
            for index, target in enumerate(flm_code_hashes.TARGETS, start=1)
        )
        receipt = flm_code_hashes.CompiledTarget(
            flm_code_hashes.RECEIPT_TARGET, b"receipt", "0.8.20", settings
        )
        manifest_bytes, solidity = flm_code_hashes._outputs(
            compiled, receipt, "ab" * 20, fake_keccak
        )
        manifest = json.loads(manifest_bytes)

        self.assertEqual(manifest["schemaVersion"], 2)
        self.assertEqual(manifest["flmSubmoduleSha"], "ab" * 20)
        self.assertEqual(
            manifest["receipt"],
            {
                "source": flm_code_hashes.RECEIPT_TARGET.source,
                "contract": flm_code_hashes.RECEIPT_TARGET.contract,
                "creationCodeBytes": len(receipt.code),
                "creationCodeKeccak256": fake_keccak(receipt.code),
            },
        )
        self.assertEqual(
            tuple(manifest["contracts"]), tuple(item.target.constant for item in compiled)
        )
        for item in compiled:
            digest = fake_keccak(item.code)
            self.assertEqual(
                manifest["contracts"][item.target.constant]["baseCreationCodeKeccak256"],
                digest,
            )
            self.assertEqual(
                manifest["contracts"][item.target.constant]["baseCreationCodePath"],
                item.target.blob.as_posix(),
            )
            self.assertIn(f"{item.target.constant} =\n        {digest};".encode(), solidity)
        self.assertNotIn(b"RECEIPT", solidity)

        changed = list(compiled)
        changed[-1] = flm_code_hashes.CompiledTarget(
            changed[-1].target, changed[-1].code, "0.8.20", {"viaIR": False}
        )
        with self.assertRaisesRegex(flm_code_hashes.GenerationError, "one solc/settings"):
            flm_code_hashes._outputs(
                tuple(changed), receipt, "ab" * 20, fake_keccak
            )

        changed_receipt = flm_code_hashes.CompiledTarget(
            receipt.target, receipt.code, "0.8.21", settings
        )
        with self.assertRaisesRegex(flm_code_hashes.GenerationError, "one solc/settings"):
            flm_code_hashes._outputs(
                compiled, changed_receipt, "ab" * 20, fake_keccak
            )

    def test_generate_captures_children_before_loader_context_overwrites_artifacts(self) -> None:
        settings = {"viaIR": True}
        compiled = {
            target.constant: flm_code_hashes.CompiledTarget(
                target, target.constant.encode(), "0.8.20", settings
            )
            for target in (*flm_code_hashes.TARGETS, flm_code_hashes.RECEIPT_TARGET)
        }
        events = []

        def build(_root: Path, *sources: str) -> None:
            events.append(("build", sources))

        def read(_root: Path, target: flm_code_hashes.Target):
            events.append(("read", target.constant))
            return compiled[target.constant]

        def write(path: Path, _content: bytes, _check: bool) -> None:
            if path == Path("/repo") / flm_code_hashes.SOLIDITY_PATH:
                events.append(("write", "SOLIDITY"))

        with mock.patch.object(
            flm_code_hashes, "_submodule_sha", return_value="ab" * 20
        ), mock.patch.object(flm_code_hashes, "_build", side_effect=build), mock.patch.object(
            flm_code_hashes, "_read_target", side_effect=read
        ), mock.patch.object(
            flm_code_hashes, "_write_or_check", side_effect=write
        ):
            flm_code_hashes.generate(Path("/repo"))

        self.assertEqual(
            events,
            [
                ("build", tuple(target.source for target in flm_code_hashes.TARGETS)),
                *[("read", target.constant) for target in flm_code_hashes.TARGETS],
                ("write", "SOLIDITY"),
                ("build", (flm_code_hashes.LOADER_SCRIPT,)),
                ("read", "RECEIPT"),
            ],
        )

    def test_check_rejects_stale_solidity_before_building_receipt(self) -> None:
        settings = {"viaIR": True}
        compiled = {
            target.constant: flm_code_hashes.CompiledTarget(
                target, target.constant.encode(), "0.8.20", settings
            )
            for target in flm_code_hashes.TARGETS
        }
        builds = []

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            solidity_path = root / flm_code_hashes.SOLIDITY_PATH
            solidity_path.parent.mkdir(parents=True)
            solidity_path.write_bytes(b"stale")

            with mock.patch.object(
                flm_code_hashes, "_submodule_sha", return_value="ab" * 20
            ), mock.patch.object(
                flm_code_hashes,
                "_build",
                side_effect=lambda _root, *sources: builds.append(sources),
            ), mock.patch.object(
                flm_code_hashes,
                "_read_target",
                side_effect=lambda _root, target: compiled[target.constant],
            ), mock.patch.object(
                flm_code_hashes, "_solidity", return_value=b"current"
            ):
                with self.assertRaisesRegex(flm_code_hashes.GenerationError, "stale"):
                    flm_code_hashes.generate(root, check=True)

        self.assertEqual(
            builds, [tuple(target.source for target in flm_code_hashes.TARGETS)]
        )

    def test_check_rejects_missing_or_stale_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "generated"
            with self.assertRaisesRegex(flm_code_hashes.GenerationError, "missing"):
                flm_code_hashes._write_or_check(path, b"right", True)
            flm_code_hashes._write_or_check(path, b"wrong", False)
            with self.assertRaisesRegex(flm_code_hashes.GenerationError, "stale"):
                flm_code_hashes._write_or_check(path, b"right", True)
            flm_code_hashes._write_or_check(path, b"right", False)
            flm_code_hashes._write_or_check(path, b"right", True)


if __name__ == "__main__":
    unittest.main()
