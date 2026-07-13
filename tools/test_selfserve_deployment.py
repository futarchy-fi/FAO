from __future__ import annotations

import hashlib
import unittest
from unittest import mock

from tools import economic_deployment, selfserve_deployment


def fake_keccak(value: bytes) -> str:
    return "0x" + hashlib.sha256(value).hexdigest()


class FakeClient:
    def __init__(self, tx: dict, receipt: dict, runtime: bytes, pinned: str) -> None:
        self.tx = tx
        self.receipt_value = receipt
        self.runtime = runtime
        self.pinned = pinned

    def transaction(self, _: str) -> dict:
        return self.tx

    def receipt(self, _: str) -> dict:
        return self.receipt_value

    def code(self, _: str) -> bytes:
        return self.runtime

    def call(self, _: str, signature: str, *args: str) -> str:
        if signature != "RECEIPT_CREATION_CODE_HASH()(bytes32)" or args:
            raise AssertionError((signature, args))
        return self.pinned


class SelfServeDeploymentTest(unittest.TestCase):
    def fixture(self) -> tuple[dict, FakeClient, bytes, bytes]:
        receipt_code = b"receipt"
        registrar_code = b"registrar"
        sender = "0x" + "11" * 20
        nonce = 7
        address = economic_deployment._create_address(sender, nonce, fake_keccak)
        tx_hash = "0x" + "22" * 32
        block = 99
        input_ = "0x" + (
            registrar_code + bytes.fromhex(fake_keccak(receipt_code)[2:])
        ).hex()
        tx = {
            "hash": tx_hash,
            "blockNumber": hex(block),
            "from": sender,
            "nonce": hex(nonce),
            "to": None,
            "input": input_,
        }
        receipt = {
            "transactionHash": tx_hash,
            "blockNumber": hex(block),
            "from": sender,
            "to": None,
            "contractAddress": address,
            "status": "0x1",
        }
        broadcast = {
            "chain": economic_deployment.CHAIN_ID,
            "pending": [],
            "transactions": [
                {
                    "hash": tx_hash,
                    "contractName": "FaoGenesisRegistrar",
                    "transactionType": "CREATE",
                    "contractAddress": address,
                    "transaction": {
                        "from": sender,
                        "nonce": hex(nonce),
                        "to": None,
                        "input": input_,
                    },
                }
            ],
            "receipts": [receipt],
        }
        return broadcast, FakeClient(tx, receipt, b"runtime", fake_keccak(receipt_code)), receipt_code, registrar_code

    def test_registrar_record_binds_broadcast_live_rpc_and_compiler_code(self) -> None:
        broadcast, client, receipt_code, registrar_code = self.fixture()
        record = selfserve_deployment._registrar_record(
            broadcast, receipt_code, registrar_code, client, fake_keccak
        )
        self.assertEqual(record["address"], broadcast["transactions"][0]["contractAddress"])
        self.assertEqual(record["transaction"]["block"], 99)
        self.assertEqual(record["creationCodeKeccak256"], fake_keccak(registrar_code))
        self.assertEqual(record["runtimeCodeKeccak256"], fake_keccak(b"runtime"))

        broadcast["transactions"][0]["transaction"]["input"] = "0x00"
        client.tx["input"] = "0x00"
        with self.assertRaisesRegex(selfserve_deployment.ManifestError, "compiler evidence"):
            selfserve_deployment._registrar_record(
                broadcast, receipt_code, registrar_code, client, fake_keccak
            )

    def test_manifest_reuses_only_verified_canonical_prerequisites(self) -> None:
        broadcast, client, receipt_code, registrar_code = self.fixture()
        economic = {"prerequisites": {"proposalImplementation": {"address": "a"}}}
        canonical = {"proposalImplementation": b"proposal", "stackDeployer": b"stack"}
        with mock.patch.object(
            economic_deployment, "validate_manifest", return_value=economic
        ) as validate, mock.patch.object(
            economic_deployment, "verify_rpc"
        ) as verify, mock.patch.object(
            economic_deployment, "_shared_deployment"
        ) as shared_validate:
            manifest = selfserve_deployment.manifest_from_broadcast(
                {"raw": True},
                broadcast,
                receipt_code,
                registrar_code,
                canonical,
                client,
                hash_=fake_keccak,
            )
        validate.assert_called_once()
        verify.assert_called_once()
        shared_validate.assert_called_once()
        self.assertEqual(manifest["schemaVersion"], 1)
        self.assertEqual(manifest["prerequisites"], economic["prerequisites"])
        self.assertIsNot(manifest["prerequisites"], economic["prerequisites"])


if __name__ == "__main__":
    unittest.main()
