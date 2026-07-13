"""Frozen v1 event schema and strict static-ABI log decoder."""

from __future__ import annotations

import json
import re
from pathlib import Path
from typing import Any, Dict, List, Tuple


class SchemaError(ValueError):
    pass


SCHEMA_PATH = Path(__file__).with_name("event-schema-v1.json")
EVENT_SCHEMA = json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))
EVENTS = {event["topic0"]: event for event in EVENT_SCHEMA["events"]}


def hex_bytes(value: Any, size: int, label: str) -> str:
    if not isinstance(value, str) or not re.fullmatch(
        "0x[0-9a-fA-F]{%d}" % (size * 2), value
    ):
        raise SchemaError("%s must be %d-byte hex" % (label, size))
    return value.lower()


def address(value: Any, label: str) -> str:
    return hex_bytes(value, 20, label)


def quantity(value: Any, label: str) -> int:
    if isinstance(value, int) and value >= 0:
        return value
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:0|[1-9a-fA-F][0-9a-fA-F]*)", value):
        raise SchemaError("%s must be a canonical nonnegative quantity" % label)
    return int(value, 16)


def canonical_log(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise SchemaError("log must be an object")
    topics = value.get("topics")
    if not isinstance(topics, list) or not topics:
        raise SchemaError("log.topics must be nonempty")
    block_number = quantity(value.get("blockNumber"), "log.blockNumber")
    log_index = quantity(value.get("logIndex"), "log.logIndex")
    data = value.get("data")
    if not isinstance(data, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", data):
        raise SchemaError("log.data must be byte hex")
    removed = value.get("removed", False)
    if not isinstance(removed, bool):
        raise SchemaError("log.removed must be boolean")
    return {
        "address": address(value.get("address"), "log.address"),
        "blockHash": hex_bytes(value.get("blockHash"), 32, "log.blockHash"),
        "blockNumber": block_number,
        "transactionHash": hex_bytes(
            value.get("transactionHash"), 32, "log.transactionHash"
        ),
        "logIndex": log_index,
        "topics": [hex_bytes(topic, 32, "log.topic") for topic in topics],
        "data": data.lower(),
        "removed": removed,
    }


def _decode_word(word: bytes, type_: str, label: str) -> Any:
    if type_ == "address":
        if word[:12] != bytes(12):
            raise SchemaError("%s has nonzero address padding" % label)
        return "0x" + word[12:].hex()
    if type_ == "bytes32":
        return "0x" + word.hex()
    if type_ == "bool":
        number = int.from_bytes(word, "big")
        if number not in (0, 1):
            raise SchemaError("%s is not a bool" % label)
        return bool(number)
    match = re.fullmatch(r"uint(8|32|128|256)", type_)
    if match:
        bits = int(match.group(1))
        number = int.from_bytes(word, "big")
        if number >= 1 << bits:
            raise SchemaError("%s exceeds %s" % (label, type_))
        return number
    raise SchemaError("unsupported static ABI type %s" % type_)


def decode_event(log: Dict[str, Any]) -> Tuple[Dict[str, Any], Dict[str, Any]]:
    topics = log["topics"]
    spec = EVENTS.get(topics[0])
    if spec is None:
        raise SchemaError("unknown event topic")
    indexed = [item for item in spec["inputs"] if item["indexed"]]
    unindexed = [item for item in spec["inputs"] if not item["indexed"]]
    raw_data = bytes.fromhex(log["data"][2:])
    if len(topics) != len(indexed) + 1 or len(raw_data) != 32 * len(unindexed):
        raise SchemaError("%s has wrong topic or data length" % spec["id"])
    decoded = {}
    topic_index = 1
    data_index = 0
    for item in spec["inputs"]:
        if item["indexed"]:
            word = bytes.fromhex(topics[topic_index][2:])
            topic_index += 1
        else:
            word = raw_data[data_index : data_index + 32]
            data_index += 32
        decoded[item["name"]] = _decode_word(word, item["type"], item["name"])
    return spec, decoded
