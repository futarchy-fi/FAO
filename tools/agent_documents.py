#!/usr/bin/env python3
"""Build and verify canonical FAO agent-work documents and index messages."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Callable

try:
    from tools.flm_code_hashes import keccak256
except ModuleNotFoundError:  # Direct script execution.
    from flm_code_hashes import keccak256  # type: ignore


ZERO_DIGEST = "0x" + "00" * 32
TASK_KIND = "0xa87c1f2bd1ee275d3f44c021b929709db51ad8a945c2c34a0857974e28595821"
RECEIPT_KIND = "0xe2c91b1ce0f47a0ac033aec054b0ce8dd8a0ca22e4812f61776ed60835734da1"
PAYMENT_KIND = "0x8161a6637134aa32b72dafb5032097de770b8555713c2415d800ea5af322c7bd"
TRANSFER_KIND = "0x27e49851e3b79673e847d7c12acc52a3936006b8517243a42df902b3df4e902e"
PUBLISH_SELECTOR = "52bf8ff2"
PUBLISHED_TOPIC = "0x9b8065b31fd378509bae92224c8f432ce836e42765fe48ed19a4c94713cc24a4"
UINT256_MAX = (1 << 256) - 1


class DocumentError(ValueError):
    pass


def _raw_bytes(value: Any, label: str = "document") -> bytes:
    if isinstance(value, bytes):
        return value
    if isinstance(value, bytearray):
        return bytes(value)
    if isinstance(value, memoryview):
        return value.tobytes()
    if isinstance(value, str):
        try:
            return value.encode("utf-8")
        except UnicodeEncodeError as exc:
            raise DocumentError(f"{label} must be valid UTF-8") from exc
    raise DocumentError(f"{label} must be bytes or text")


def _escape(value: str) -> str:
    output = ['"']
    for character in value:
        codepoint = ord(character)
        if character == '"':
            output.append('\\"')
        elif character == "\\":
            output.append("\\\\")
        elif codepoint < 0x20:
            output.append(f"\\u{codepoint:04x}")
        else:
            output.append(character)
    output.append('"')
    return "".join(output)


def _canonical_text(value: Any) -> str:
    if isinstance(value, str):
        return _escape(value)
    if isinstance(value, list):
        return "[" + ",".join(_canonical_text(item) for item in value) + "]"
    if isinstance(value, dict):
        if any(not isinstance(key, str) for key in value):
            raise DocumentError("document keys must be strings")
        return "{" + ",".join(
            _escape(key) + ":" + _canonical_text(value[key]) for key in sorted(value)
        ) + "}"
    raise DocumentError("every scalar leaf must be a JSON string")


def canonicalize(value: Any) -> bytes:
    if not isinstance(value, dict):
        raise DocumentError("document must be a top-level object")
    try:
        return _canonical_text(value).encode("utf-8")
    except UnicodeEncodeError as exc:
        raise DocumentError("document must not contain unpaired Unicode surrogates") from exc


def parse_canonical(value: Any) -> dict[str, Any]:
    raw = _raw_bytes(value)
    try:
        text = raw.decode("utf-8")
        document = json.loads(text)
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise DocumentError("document is not valid UTF-8 JSON") from exc
    if not isinstance(document, dict) or canonicalize(document) != raw:
        raise DocumentError("document bytes are not canonical")
    return document


def document_digest(value: Any, hash_: Callable[[bytes], str] = keccak256) -> str:
    return hash_(_raw_bytes(value))


def _record(value: Any, required: set[str], optional: set[str], label: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise DocumentError(f"{label} must be an object")
    keys = set(value)
    if not required <= keys or keys - required - optional:
        raise DocumentError(f"{label} has invalid fields")
    return value


def _text(value: Any, label: str, *, nonempty: bool = False, max_bytes: int | None = None) -> str:
    if not isinstance(value, str):
        raise DocumentError(f"{label} must be a string")
    try:
        size = len(value.encode("utf-8"))
    except UnicodeEncodeError as exc:
        raise DocumentError(f"{label} must be valid UTF-8") from exc
    if nonempty and size == 0:
        raise DocumentError(f"{label} cannot be empty")
    if max_bytes is not None and size > max_bytes:
        raise DocumentError(f"{label} exceeds {max_bytes} UTF-8 bytes")
    return value


def _decimal(value: Any, label: str, *, positive: bool = False) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"0|[1-9][0-9]*", value):
        raise DocumentError(f"{label} must be an unsigned canonical decimal string")
    number = int(value)
    if number > UINT256_MAX or (positive and number == 0):
        raise DocumentError(f"{label} must fit uint256" + (" and be positive" if positive else ""))
    return value


def _hex(value: Any, size: int, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(rf"0x[0-9a-fA-F]{{{size * 2}}}", value):
        raise DocumentError(f"{label} must be {size}-byte 0x hex")
    return value.lower()


def _address(value: Any, label: str, *, allow_zero: bool = False) -> str:
    address = _hex(value, 20, label)
    if not allow_zero and address == "0x" + "00" * 20:
        raise DocumentError(f"{label} cannot be zero")
    return address


def _digest(value: Any, label: str) -> str:
    return _hex(value, 32, label)


def _input(value: Any) -> dict[str, Any]:
    return parse_canonical(value) if isinstance(value, (bytes, bytearray, memoryview, str)) else value


def _validated(value: Any, normalized: dict[str, Any]) -> dict[str, Any]:
    if isinstance(value, (bytes, bytearray, memoryview, str)) and canonicalize(normalized) != _raw_bytes(value):
        raise DocumentError("document values are not in canonical schema form")
    return normalized


def validate_task(value: Any) -> dict[str, Any]:
    raw = _record(
        _input(value),
        {"v", "kind", "chainId", "vault", "title", "salt"},
        {"spec", "specDigest", "specUri", "deadline", "reward"},
        "task",
    )
    inline = "spec" in raw
    external = "specDigest" in raw or "specUri" in raw
    if inline == external or (external and not {"specDigest", "specUri"} <= set(raw)):
        raise DocumentError("task requires exactly spec or specDigest plus specUri")
    if raw["v"] != "1" or raw["kind"] != "fao.task":
        raise DocumentError("task version or kind is invalid")
    task: dict[str, Any] = {
        "v": "1",
        "kind": "fao.task",
        "chainId": _decimal(raw["chainId"], "task.chainId", positive=True),
        "vault": _address(raw["vault"], "task.vault"),
        "title": _text(raw["title"], "task.title", nonempty=True),
        "salt": _digest(raw["salt"], "task.salt"),
    }
    if inline:
        task["spec"] = _text(raw["spec"], "task.spec", nonempty=True)
    else:
        task["specDigest"] = _digest(raw["specDigest"], "task.specDigest")
        task["specUri"] = _text(raw["specUri"], "task.specUri", nonempty=True, max_bytes=256)
    if "deadline" in raw:
        task["deadline"] = _decimal(raw["deadline"], "task.deadline")
    if "reward" in raw:
        reward = _record(raw["reward"], {"asset", "amount"}, set(), "task.reward")
        task["reward"] = {
            "asset": _address(reward["asset"], "task.reward.asset", allow_zero=True),
            "amount": _decimal(reward["amount"], "task.reward.amount", positive=True),
        }
    return _validated(value, task)


def validate_receipt(value: Any) -> dict[str, Any]:
    raw = _record(
        _input(value),
        {"v", "kind", "chainId", "vault", "task", "worker", "artifacts", "summary", "salt"},
        set(),
        "receipt",
    )
    if raw["v"] != "1" or raw["kind"] != "fao.receipt":
        raise DocumentError("receipt version or kind is invalid")
    if not isinstance(raw["artifacts"], list) or not raw["artifacts"]:
        raise DocumentError("receipt.artifacts must be a nonempty array")
    artifacts = []
    for index, value_ in enumerate(raw["artifacts"]):
        artifact = _record(value_, {"digest", "uri"}, {"note"}, f"receipt.artifacts[{index}]")
        normalized = {
            "digest": _digest(artifact["digest"], f"receipt.artifacts[{index}].digest"),
            "uri": _text(
                artifact["uri"], f"receipt.artifacts[{index}].uri", nonempty=True, max_bytes=256
            ),
        }
        if "note" in artifact:
            normalized["note"] = _text(artifact["note"], f"receipt.artifacts[{index}].note")
        artifacts.append(normalized)
    return _validated(value, {
        "v": "1",
        "kind": "fao.receipt",
        "chainId": _decimal(raw["chainId"], "receipt.chainId", positive=True),
        "vault": _address(raw["vault"], "receipt.vault"),
        "task": _digest(raw["task"], "receipt.task"),
        "worker": _address(raw["worker"], "receipt.worker"),
        "artifacts": artifacts,
        "summary": _text(raw["summary"], "receipt.summary", nonempty=True),
        "salt": _digest(raw["salt"], "receipt.salt"),
    })


def validate_payment(value: Any) -> dict[str, Any]:
    raw = _record(
        _input(value),
        {"v", "kind", "chainId", "vault", "asset", "recipient", "amount", "task", "receipt", "salt"},
        {"note"},
        "payment",
    )
    if raw["v"] != "1" or raw["kind"] != "fao.payment":
        raise DocumentError("payment version or kind is invalid")
    payment = {
        "v": "1",
        "kind": "fao.payment",
        "chainId": _decimal(raw["chainId"], "payment.chainId", positive=True),
        "vault": _address(raw["vault"], "payment.vault"),
        "asset": _address(raw["asset"], "payment.asset", allow_zero=True),
        "recipient": _address(raw["recipient"], "payment.recipient"),
        "amount": _decimal(raw["amount"], "payment.amount", positive=True),
        "task": _digest(raw["task"], "payment.task"),
        "receipt": _digest(raw["receipt"], "payment.receipt"),
        "salt": _digest(raw["salt"], "payment.salt"),
    }
    if "note" in raw:
        payment["note"] = _text(raw["note"], "payment.note")
    return _validated(value, payment)


def build_task(value: Any) -> bytes:
    return canonicalize(validate_task(value))


def build_receipt(value: Any) -> bytes:
    return canonicalize(validate_receipt(value))


def build_payment(value: Any) -> bytes:
    return canonicalize(validate_payment(value))


def _word(value: int) -> bytes:
    if value < 0 or value > UINT256_MAX:
        raise DocumentError("ABI integer does not fit uint256")
    return value.to_bytes(32, "big")


def _hex_bytes(value: Any, size: int, label: str) -> bytes:
    return bytes.fromhex(_hex(value, size, label)[2:])


def _address_word(value: Any, label: str, *, allow_zero: bool = False) -> bytes:
    return b"\x00" * 12 + bytes.fromhex(_address(value, label, allow_zero=allow_zero)[2:])


def payment_transfer_action(value: Any, hash_: Callable[[bytes], str] = keccak256) -> dict[str, str]:
    payment = validate_payment(value)
    document = build_payment(payment)
    return {
        "asset": payment["asset"],
        "recipient": payment["recipient"],
        "amount": payment["amount"],
        "salt": document_digest(document, hash_),
    }


def transfer_evaluation_payload(chain_id: Any, vault: Any, action: Any) -> bytes:
    action = _record(action, {"asset", "recipient", "amount", "salt"}, set(), "TransferAction")
    return b"".join(
        (
            _hex_bytes(TRANSFER_KIND, 32, "transfer kind"),
            _word(int(_decimal(str(chain_id), "chainId", positive=True))),
            _address_word(vault, "vault"),
            _address_word(action["asset"], "TransferAction.asset", allow_zero=True),
            _address_word(action["recipient"], "TransferAction.recipient"),
            _word(int(_decimal(str(action["amount"]), "TransferAction.amount", positive=True))),
            _hex_bytes(action["salt"], 32, "TransferAction.salt"),
        )
    )


def transfer_hash(
    chain_id: Any,
    vault: Any,
    action: Any,
    hash_: Callable[[bytes], str] = keccak256,
) -> str:
    return hash_(transfer_evaluation_payload(chain_id, vault, action))


def validate_payment_binding(
    value: Any,
    chain_id: Any,
    vault: Any,
    action: Any,
    hash_: Callable[[bytes], str] = keccak256,
) -> str:
    payment = validate_payment(value)
    expected = payment_transfer_action(payment, hash_)
    normalized_action = {
        "asset": _address(action.get("asset"), "TransferAction.asset", allow_zero=True),
        "recipient": _address(action.get("recipient"), "TransferAction.recipient"),
        "amount": _decimal(str(action.get("amount")), "TransferAction.amount", positive=True),
        "salt": _digest(action.get("salt"), "TransferAction.salt"),
    }
    if payment["chainId"] != _decimal(str(chain_id), "chainId", positive=True):
        raise DocumentError("payment chainId does not match")
    if payment["vault"] != _address(vault, "vault"):
        raise DocumentError("payment vault does not match")
    if normalized_action != expected:
        raise DocumentError("payment does not bind the exact TransferAction")
    return transfer_hash(chain_id, vault, normalized_action, hash_)


def publish_calldata(kind: Any, parent_digest: Any, document: Any) -> str:
    raw = _raw_bytes(document)
    if not raw:
        raise DocumentError("document cannot be empty")
    padding = (-len(raw)) % 32
    encoded = b"".join(
        (
            _hex_bytes(kind, 32, "kind"),
            _hex_bytes(parent_digest, 32, "parentDigest"),
            _word(96),
            _word(len(raw)),
            raw,
            b"\x00" * padding,
        )
    )
    return "0x" + PUBLISH_SELECTOR + encoded.hex()


def prepare_publication(schema: str, value: Any) -> dict[str, Any]:
    try:
        validate, build, kind = {
            "task": (validate_task, build_task, TASK_KIND),
            "receipt": (validate_receipt, build_receipt, RECEIPT_KIND),
            "payment": (validate_payment, build_payment, PAYMENT_KIND),
        }[schema]
    except KeyError as exc:
        raise DocumentError("schema must be task, receipt, or payment") from exc
    normalized = validate(value)
    document = build(normalized)
    parent = ZERO_DIGEST if schema == "task" else normalized["task" if schema == "receipt" else "receipt"]
    return {
        "kind": kind,
        "parentDigest": parent,
        "documentDigest": document_digest(document),
        "document": document,
        "calldata": publish_calldata(kind, parent, document),
    }


def decode_published_log(log: Any) -> dict[str, Any]:
    log = _record(log, {"topics", "data"}, {"address"}, "Published log")
    topics = log["topics"]
    if not isinstance(topics, list) or len(topics) != 4 or _digest(topics[0], "event topic") != PUBLISHED_TOPIC:
        raise DocumentError("Published log topics are invalid")
    data = _hex_bytes_variable(log["data"], "Published log data")
    if len(data) < 96 or len(data) % 32 or data[:12] != b"\x00" * 12 or int.from_bytes(data[32:64], "big") != 64:
        raise DocumentError("Published log data are invalid")
    size = int.from_bytes(data[64:96], "big")
    padded = (size + 31) // 32 * 32
    if len(data) != 96 + padded or any(data[96 + size :]):
        raise DocumentError("Published log document encoding is invalid")
    document = data[96 : 96 + size]
    digest = _digest(topics[3], "documentDigest")
    if not document or document_digest(document) != digest:
        raise DocumentError("Published log document digest is invalid")
    return {
        "kind": _digest(topics[1], "kind"),
        "parentDigest": _digest(topics[2], "parentDigest"),
        "documentDigest": digest,
        "publisher": "0x" + data[12:32].hex(),
        "document": document,
    }


def _hex_bytes_variable(value: Any, label: str) -> bytes:
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", value):
        raise DocumentError(f"{label} must be even-length 0x hex")
    return bytes.fromhex(value[2:])


VALIDATORS = {"task": validate_task, "receipt": validate_receipt, "payment": validate_payment}


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("schema", choices=tuple(VALIDATORS))
    parser.add_argument("path", nargs="?", default="-", help="JSON file or - for stdin")
    parser.add_argument("--digest", action="store_true", help="print Keccak-256 instead of JSON")
    args = parser.parse_args(argv)
    try:
        raw = sys.stdin.buffer.read() if args.path == "-" else Path(args.path).read_bytes()
        value = json.loads(raw)
        document = canonicalize(VALIDATORS[args.schema](value))
        output = document_digest(document) + "\n" if args.digest else document.decode() + "\n"
    except (OSError, json.JSONDecodeError, DocumentError) as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1
    sys.stdout.write(output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
