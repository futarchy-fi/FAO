from __future__ import annotations

import copy
import json
import unittest
from pathlib import Path

from tools import agent_documents as agent


FIXTURE = json.loads(
    (Path(__file__).parent / "fixtures/agent-document-golden.json").read_text(encoding="utf-8")
)


def raw(value: str) -> bytes:
    return bytes.fromhex(value[2:])


def published_data(publisher: str, document: bytes) -> str:
    padding = (-len(document)) % 32
    return "0x" + (
        b"\x00" * 12
        + bytes.fromhex(publisher[2:])
        + (64).to_bytes(32, "big")
        + len(document).to_bytes(32, "big")
        + document
        + b"\x00" * padding
    ).hex()


class AgentDocumentsTest(unittest.TestCase):
    def test_kind_preimages_and_cross_language_golden_documents(self) -> None:
        self.assertEqual(agent.keccak256(b"FAO_AGENT_TASK_V1"), FIXTURE["kinds"]["task"])
        self.assertEqual(agent.keccak256(b"FAO_AGENT_RECEIPT_V1"), FIXTURE["kinds"]["receipt"])
        self.assertEqual(agent.keccak256(b"FAO_AGENT_PAYMENT_V1"), FIXTURE["kinds"]["payment"])
        for name, builder in (
            ("task", agent.build_task),
            ("receipt", agent.build_receipt),
            ("payment", agent.build_payment),
        ):
            document = builder(FIXTURE[name]["input"])
            self.assertEqual(document, raw(FIXTURE[name]["canonicalHex"]))
            self.assertEqual(agent.document_digest(document), FIXTURE[name]["digest"])

    def test_exact_canonical_rules_cover_unicode_controls_and_omissions(self) -> None:
        self.assertEqual(
            agent.canonicalize(FIXTURE["unicodeKeyOrder"]["value"]),
            raw(FIXTURE["unicodeKeyOrder"]["canonicalHex"]),
        )
        task = agent.validate_task(FIXTURE["task"]["input"])
        self.assertEqual(task["vault"], "0x" + "aa" * 20)
        self.assertNotIn("deadline", task)
        self.assertNotIn("reward", task)
        self.assertIn(b"\\u000a", agent.build_task(task))
        with self.assertRaisesRegex(agent.DocumentError, "surrogates|UTF-8"):
            agent.canonicalize({"value": "\ud800"})
        with self.assertRaisesRegex(agent.DocumentError, "scalar leaf"):
            agent.canonicalize({"amount": 1})

    def test_noncanonical_raw_bytes_still_have_one_raw_digest(self) -> None:
        document = raw(FIXTURE["nonCanonical"]["hex"])
        self.assertEqual(agent.document_digest(document), FIXTURE["nonCanonical"]["rawDigest"])
        with self.assertRaisesRegex(agent.DocumentError, "canonical"):
            agent.validate_task(document)

    def test_payment_binds_exact_transfer_domain_and_max_uint256(self) -> None:
        payment = FIXTURE["payment"]
        action = agent.payment_transfer_action(raw(payment["canonicalHex"]))
        self.assertEqual(action, payment["transferAction"])
        self.assertEqual(
            "0x" + agent.transfer_evaluation_payload(
                payment["input"]["chainId"], payment["input"]["vault"], action
            ).hex(),
            payment["transferEvaluationPayload"],
        )
        self.assertEqual(
            agent.validate_payment_binding(
                raw(payment["canonicalHex"]),
                payment["input"]["chainId"],
                payment["input"]["vault"],
                action,
            ),
            payment["actionHash"],
        )
        self.assertEqual(str(int(payment["actionHash"], 16)), payment["proposalId"])

        for field, replacement in (
            ("asset", "0x" + "11" * 20),
            ("recipient", "0x" + "22" * 20),
            ("amount", "1"),
            ("salt", "0x" + "33" * 32),
        ):
            changed = dict(action)
            changed[field] = replacement
            with self.assertRaisesRegex(agent.DocumentError, "exact TransferAction"):
                agent.validate_payment_binding(
                    raw(payment["canonicalHex"]), "11155111", payment["input"]["vault"], changed
                )
        with self.assertRaisesRegex(agent.DocumentError, "chainId"):
            agent.validate_payment_binding(
                raw(payment["canonicalHex"]), "1", payment["input"]["vault"], action
            )
        with self.assertRaisesRegex(agent.DocumentError, "vault"):
            agent.validate_payment_binding(
                raw(payment["canonicalHex"]), "11155111", "0x" + "11" * 20, action
            )

    def test_schema_validation_rejects_non_strings_unknowns_and_overflow(self) -> None:
        external = copy.deepcopy(FIXTURE["task"]["input"])
        external.pop("spec")
        external.update(
            {
                "specDigest": "0x" + "56" * 32,
                "specUri": "https://example.test/spec",
                "deadline": "1760000000",
                "reward": {"asset": "0x" + "00" * 20, "amount": "1"},
            }
        )
        self.assertEqual(agent.validate_task(external)["reward"]["amount"], "1")
        for field, value in (("chainId", "01"), ("amount", str(1 << 256))):
            changed = copy.deepcopy(FIXTURE["payment"]["input"])
            changed[field] = value
            with self.assertRaises(agent.DocumentError):
                agent.validate_payment(changed)
        changed = copy.deepcopy(FIXTURE["task"]["input"])
        changed["unknown"] = "value"
        with self.assertRaisesRegex(agent.DocumentError, "invalid fields"):
            agent.validate_task(changed)

    def test_publish_calldata_and_log_decoder_are_exact(self) -> None:
        document = raw(FIXTURE["receipt"]["canonicalHex"])
        publication = agent.prepare_publication("receipt", FIXTURE["receipt"]["input"])
        self.assertEqual(publication["kind"], agent.RECEIPT_KIND)
        self.assertEqual(publication["parentDigest"], FIXTURE["receipt"]["parentDigest"])
        self.assertEqual(publication["documentDigest"], FIXTURE["receipt"]["digest"])
        calldata = agent.publish_calldata(
            agent.RECEIPT_KIND, FIXTURE["receipt"]["parentDigest"], document
        )
        self.assertTrue(calldata.startswith("0x52bf8ff2"))
        self.assertEqual(int(calldata[2 + 8 + 128 : 2 + 8 + 192], 16), 96)

        publisher = "0x" + "69" * 20
        log = {
            "topics": [
                agent.PUBLISHED_TOPIC,
                agent.RECEIPT_KIND,
                FIXTURE["receipt"]["parentDigest"],
                FIXTURE["receipt"]["digest"],
            ],
            "data": published_data(publisher, document),
        }
        decoded = agent.decode_published_log(log)
        self.assertEqual(decoded["publisher"], publisher)
        self.assertEqual(decoded["document"], document)
        self.assertEqual(decoded["documentDigest"], FIXTURE["receipt"]["digest"])

        log["topics"][-1] = "0x" + "00" * 32
        with self.assertRaisesRegex(agent.DocumentError, "digest"):
            agent.decode_published_log(log)


if __name__ == "__main__":
    unittest.main()
