"""Finalized-log SQLite indexer with reorg rewind and deterministic replay."""

from __future__ import annotations

import hashlib
import json
import re
import sqlite3
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple, Union

from .schema import EVENTS, SchemaError, address, canonical_log, decode_event, hex_bytes, quantity


MAX_QUEUE = 16
STATE_NAMES = ("INACTIVE", "YES", "NO", "QUEUED", "EVALUATING", "SETTLED")
TRANSFER_KIND = "0x27e49851e3b79673e847d7c12acc52a3936006b8517243a42df902b3df4e902e"
PARAM_KIND = "0x755dc82832a5b7ea3d4cab445bc2350333d8767db30d0e3ae26bca262bd09df8"
CRITICAL_KIND = "0xecf8eeca4c3b543587a2cd1790f9870174ebb99982cfd26c51b7440d47b6834a"


def _payload_word(value: Any) -> bytes:
    if isinstance(value, int):
        if value < 0 or value >= 1 << 256:
            raise IndexerError("payload integer is out of range")
        return value.to_bytes(32, "big")
    if isinstance(value, str) and len(value) == 42:
        return bytes(12) + bytes.fromhex(address(value, "payload address")[2:])
    return bytes.fromhex(hex_bytes(value, 32, "payload word")[2:])


def _static_payload(*values: Any) -> str:
    return "0x" + b"".join(_payload_word(value) for value in values).hex()


class IndexerError(ValueError):
    pass


class RpcCallError(IndexerError):
    def __init__(self, message: str, data: Optional[str] = None) -> None:
        super().__init__(message)
        self.data = data


class JsonRpc:
    """Small stdlib JSON-RPC adapter; no account or signing support."""

    def __init__(self, url: str) -> None:
        self.url = url
        self._id = 0

    def _request(self, method: str, params: Sequence[Any]) -> Any:
        self._id += 1
        body = json.dumps(
            {"jsonrpc": "2.0", "id": self._id, "method": method, "params": list(params)},
            separators=(",", ":"),
        ).encode("utf-8")
        request = urllib.request.Request(
            self.url, body, {"Content-Type": "application/json"}, method="POST"
        )
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                value = json.loads(response.read().decode("utf-8"))
        except (OSError, UnicodeError, json.JSONDecodeError, urllib.error.URLError) as exc:
            raise IndexerError("JSON-RPC request failed") from exc
        if not isinstance(value, dict) or value.get("id") != self._id:
            raise IndexerError("JSON-RPC response envelope is invalid")
        if value.get("error") is not None:
            error = value["error"]
            data = error.get("data") if isinstance(error, dict) else None
            raise RpcCallError("JSON-RPC %s failed: %s" % (method, error), data)
        return value.get("result")

    def chain_id(self) -> int:
        return quantity(self._request("eth_chainId", []), "eth_chainId")

    def block(self, number: Union[int, str]) -> Dict[str, Any]:
        tag = hex(number) if isinstance(number, int) else number
        value = self._request("eth_getBlockByNumber", [tag, False])
        if not isinstance(value, dict):
            raise IndexerError("block is unavailable: %s" % tag)
        return value

    def finalized_block(self) -> Dict[str, Any]:
        return self.block("finalized")

    def logs(self, from_block: int, to_block: int, addresses: Sequence[str]) -> List[Dict[str, Any]]:
        if from_block > to_block:
            return []
        # ponytail: one finalized range; add provider-specific chunking only when a live RPC needs it.
        value = self._request(
            "eth_getLogs",
            [
                {
                    "fromBlock": hex(from_block),
                    "toBlock": hex(to_block),
                    "address": list(addresses),
                    "topics": [list(EVENTS)],
                }
            ],
        )
        if not isinstance(value, list):
            raise IndexerError("eth_getLogs returned a non-array")
        return value

    def call(self, transaction: Dict[str, Any], block: str = "latest") -> str:
        value = self._request("eth_call", [transaction, block])
        if not isinstance(value, str):
            raise IndexerError("eth_call returned non-hex output")
        return value


SCHEMA = """
CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS registrars (
  chain_id INTEGER NOT NULL, address TEXT NOT NULL,
  PRIMARY KEY (chain_id, address)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS blocks (
  chain_id INTEGER NOT NULL, number INTEGER NOT NULL, hash TEXT NOT NULL UNIQUE,
  parent_hash TEXT NOT NULL, timestamp INTEGER NOT NULL,
  PRIMARY KEY (chain_id, number)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS logs (
  chain_id INTEGER NOT NULL, block_hash TEXT NOT NULL, log_index INTEGER NOT NULL,
  block_number INTEGER NOT NULL, transaction_hash TEXT NOT NULL, address TEXT NOT NULL,
  topics TEXT NOT NULL, data TEXT NOT NULL,
  PRIMARY KEY (chain_id, block_hash, log_index)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS instances (
  chain_id INTEGER NOT NULL, receipt TEXT NOT NULL, registrar TEXT NOT NULL,
  core_hash TEXT NOT NULL, flm_hash TEXT NOT NULL, stager TEXT NOT NULL,
  vault TEXT, company_token TEXT, space TEXT, arbitration TEXT UNIQUE,
  evaluator TEXT UNIQUE, spot_pool TEXT, manager TEXT UNIQUE, relay TEXT, spot_adapter TEXT,
  active_evaluation_proposal_id TEXT NOT NULL DEFAULT '0',
  PRIMARY KEY (chain_id, receipt)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS proposals (
  chain_id INTEGER NOT NULL, arbitration TEXT NOT NULL, proposal_id TEXT NOT NULL,
  creator TEXT NOT NULL, min_activation_bond TEXT NOT NULL, state TEXT NOT NULL,
  last_state_change_at INTEGER NOT NULL, yes_bidder TEXT, yes_bond_amount TEXT NOT NULL DEFAULT '0',
  no_bidder TEXT, no_bond_amount TEXT NOT NULL DEFAULT '0', queue_position INTEGER NOT NULL DEFAULT 0,
  enqueued_block INTEGER, enqueued_log_index INTEGER, settled INTEGER NOT NULL DEFAULT 0,
  accepted INTEGER, futarchy_proposal TEXT, futarchy_proposal_id TEXT, condition_id TEXT,
  payload_kind TEXT, payload_commitment TEXT, evaluation_payload TEXT, payload_source TEXT,
  PRIMARY KEY (chain_id, arbitration, proposal_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS flm_state (
  chain_id INTEGER NOT NULL, manager TEXT NOT NULL, mode TEXT NOT NULL,
  active_proposal_id TEXT NOT NULL, restore_needed INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY (chain_id, manager)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS instance_views (
  chain_id INTEGER NOT NULL, receipt TEXT NOT NULL, block_number INTEGER NOT NULL,
  block_hash TEXT NOT NULL, registrar_code_hash TEXT NOT NULL, proposal_gateway TEXT NOT NULL,
  release_strategy TEXT NOT NULL, timeout TEXT NOT NULL, base_x TEXT NOT NULL,
  max_queue INTEGER NOT NULL, active_proposal_id TEXT NOT NULL, evaluator_market TEXT,
  relay_proposal_id TEXT NOT NULL, relay_proposal TEXT, relay_exists INTEGER NOT NULL,
  relay_settled INTEGER NOT NULL, flm_mode TEXT NOT NULL, flm_active_proposal_id TEXT NOT NULL,
  emergency_armed_at TEXT NOT NULL, emergency_executed INTEGER NOT NULL,
  initialized INTEGER NOT NULL, total_supply TEXT NOT NULL, spot_liquidity TEXT NOT NULL,
  conditional_yes_liquidity TEXT NOT NULL, conditional_no_liquidity TEXT NOT NULL,
  sync_action INTEGER NOT NULL, resolution_ready INTEGER NOT NULL, restore_call_ok INTEGER NOT NULL,
  PRIMARY KEY (chain_id, receipt)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS proposal_views (
  chain_id INTEGER NOT NULL, arbitration TEXT NOT NULL, proposal_id TEXT NOT NULL,
  block_number INTEGER NOT NULL, state TEXT NOT NULL, last_state_change_at INTEGER NOT NULL,
  yes_bidder TEXT, yes_bond_amount TEXT NOT NULL, no_bidder TEXT, no_bond_amount TEXT NOT NULL,
  queue_position INTEGER NOT NULL, settled INTEGER NOT NULL, accepted INTEGER NOT NULL,
  PRIMARY KEY (chain_id, arbitration, proposal_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS attempts (
  attempt_id INTEGER PRIMARY KEY, chain_id INTEGER NOT NULL, action_sha256 TEXT NOT NULL,
  keeper TEXT NOT NULL, phase TEXT NOT NULL, outcome TEXT NOT NULL, classification TEXT NOT NULL,
  action_kind TEXT NOT NULL, target TEXT NOT NULL, data TEXT NOT NULL, proposal_id TEXT,
  tx_hash TEXT, revert_data TEXT, detail TEXT NOT NULL, race_winner_attempt_id INTEGER,
  postcondition_satisfied INTEGER
);
"""


def _block(value: Any) -> Dict[str, Any]:
    if not isinstance(value, dict):
        raise IndexerError("block must be an object")
    try:
        return {
            "number": quantity(value.get("number"), "block.number"),
            "hash": hex_bytes(value.get("hash"), 32, "block.hash"),
            "parentHash": hex_bytes(value.get("parentHash"), 32, "block.parentHash"),
            "timestamp": quantity(value.get("timestamp"), "block.timestamp"),
        }
    except SchemaError as exc:
        raise IndexerError(str(exc)) from exc


SELECTORS = {
    "registrarCodeHash": "831c4e7b",
    "coreHash": "b1b4fc36",
    "flmHash": "1092769f",
    "coreSealed": "73797f98",
    "flmSealed": "e05abb68",
    "proposalGateway": "04e31dfb",
    "releaseStrategy": "f8fb4b87",
    "timeout": "70dea79a",
    "baseX": "5761c182",
    "maxQueue": "3f7b5e40",
    "activeEvaluation": "833d9770",
    "getProposal": "c7f758a8",
    "futarchyProposalOf": "0964ee77",
    "officialProposalExtended": "0e0e6911",
    "inConditionalMode": "e43f2504",
    "activeProposalId": "a81160c0",
    "emergencyExitArmedAt": "d13fac6e",
    "emergencyExitExecuted": "cde354cc",
    "initialized": "42447a4f",
    "totalSupply": "18160ddd",
    "spotLiquidity": "26e2caf6",
    "conditionalYesLiquidity": "043b300a",
    "conditionalNoLiquidity": "3e61972e",
    "sync": "fff6cae9",
    "restore": "adc637be",
    "resolve": "4f896d4f",
}


def _call_data(selector: str, argument: Optional[int] = None) -> str:
    return "0x" + selector + ("" if argument is None else argument.to_bytes(32, "big").hex())


def _rpc_words(rpc: Any, target: str, data: str, block_number: int) -> List[bytes]:
    raw = rpc.call({"to": target, "data": data}, hex(block_number))
    if not isinstance(raw, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{64})+", raw):
        raise IndexerError("eth_call returned noncanonical static ABI")
    decoded = bytes.fromhex(raw[2:])
    return [decoded[index : index + 32] for index in range(0, len(decoded), 32)]


def _uint_word(words: List[bytes], index: int, label: str) -> int:
    if index >= len(words):
        raise IndexerError("%s output is truncated" % label)
    return int.from_bytes(words[index], "big")


def _bool_word(words: List[bytes], index: int, label: str) -> bool:
    value = _uint_word(words, index, label)
    if value not in (0, 1):
        raise IndexerError("%s is not boolean" % label)
    return bool(value)


def _address_word(words: List[bytes], index: int, label: str, zero_none: bool = False) -> Optional[str]:
    if index >= len(words) or any(words[index][:12]):
        raise IndexerError("%s is not an ABI address" % label)
    value = "0x" + words[index][12:].hex()
    return None if zero_none and value == "0x" + "00" * 20 else value


BENIGN_RACE_ERRORS = {
    "0xbaf3f0f7",  # FutarchyArbitration.InvalidState()
    "0xb46f8394",  # EvaluationAlreadyStarted(uint256)
    "0x52e39725",  # EvaluationNotStarted(uint256)
    "0xb7083f88",  # NoActiveEvaluation()
    "0x0d2725de",  # WrongProposalId(uint256,uint256)
}


def _attempt_classification(outcome: str, revert_data: Optional[str]) -> str:
    if outcome != "revert":
        return outcome
    selector = None
    if isinstance(revert_data, str) and re.fullmatch(r"0x[0-9a-fA-F]{8,}", revert_data):
        selector = revert_data[:10].lower()
    return "race-candidate" if selector in BENIGN_RACE_ERRORS else "fatal-revert"


class Indexer:
    def __init__(self, path: Union[str, Path]) -> None:
        self.path = str(path)
        self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript(SCHEMA)
        version = self._meta("schemaVersion")
        if version not in (None, "1", "2"):
            raise IndexerError("unsupported index schema")
        if version == "1":
            self.db.execute("ALTER TABLE proposals ADD COLUMN evaluation_payload TEXT")
            self.db.execute("ALTER TABLE proposals ADD COLUMN payload_source TEXT")
            self.db.execute(
                "ALTER TABLE flm_state ADD COLUMN restore_needed INTEGER NOT NULL DEFAULT 0"
            )
        self._set_meta("schemaVersion", "2")
        self.db.commit()

    def close(self) -> None:
        self.db.close()

    def __enter__(self) -> "Indexer":
        return self

    def __exit__(self, *args: Any) -> None:
        self.close()

    def _meta(self, key: str) -> Optional[str]:
        row = self.db.execute("SELECT value FROM meta WHERE key = ?", (key,)).fetchone()
        return None if row is None else str(row[0])

    def _set_meta(self, key: str, value: Any) -> None:
        self.db.execute(
            "INSERT INTO meta(key,value) VALUES(?,?) "
            "ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            (key, str(value)),
        )

    def _bind(self, chain_id: int, start_block: int, registrars: Iterable[str]) -> None:
        if chain_id <= 0 or start_block < 0:
            raise IndexerError("chain id and start block are invalid")
        current_chain = self._meta("chainId")
        current_start = self._meta("startBlock")
        if current_chain not in (None, str(chain_id)) or current_start not in (
            None,
            str(start_block),
        ):
            raise IndexerError("database chain or start block does not match")
        self._set_meta("chainId", chain_id)
        self._set_meta("startBlock", start_block)
        for value in registrars:
            try:
                registrar = address(value, "registrar")
            except SchemaError as exc:
                raise IndexerError(str(exc)) from exc
            self.db.execute(
                "INSERT OR IGNORE INTO registrars(chain_id,address) VALUES(?,?)",
                (chain_id, registrar),
            )
        if self.db.execute(
            "SELECT COUNT(*) FROM registrars WHERE chain_id=?", (chain_id,)
        ).fetchone()[0] == 0:
            raise IndexerError("at least one registrar is required")

    def _hydrate(self, rpc: Any, chain_id: int, block: Dict[str, Any]) -> None:
        if not hasattr(rpc, "call"):
            return
        for instance in self.db.execute(
            "SELECT * FROM instances WHERE chain_id=? ORDER BY receipt", (chain_id,)
        ).fetchall():
            if any(instance[key] is None for key in ("arbitration", "evaluator", "manager", "relay")):
                continue
            registrar_hash = "0x" + _rpc_words(
                rpc,
                instance["registrar"],
                _call_data(SELECTORS["registrarCodeHash"]),
                block["number"],
            )[0].hex()
            core_hash = "0x" + _rpc_words(
                rpc, instance["receipt"], _call_data(SELECTORS["coreHash"]), block["number"]
            )[0].hex()
            flm_hash = "0x" + _rpc_words(
                rpc, instance["receipt"], _call_data(SELECTORS["flmHash"]), block["number"]
            )[0].hex()
            core_sealed = _bool_word(
                _rpc_words(
                    rpc,
                    instance["receipt"],
                    _call_data(SELECTORS["coreSealed"]),
                    block["number"],
                ),
                0,
                "coreSealed",
            )
            flm_sealed = _bool_word(
                _rpc_words(
                    rpc,
                    instance["receipt"],
                    _call_data(SELECTORS["flmSealed"]),
                    block["number"],
                ),
                0,
                "flmSealed",
            )
            if core_hash != instance["core_hash"] or flm_hash != instance["flm_hash"]:
                raise IndexerError("receipt config getters disagree with GenesisStaged")
            if not core_sealed or not flm_sealed or registrar_hash == "0x" + "00" * 32:
                raise IndexerError("sealed instance views are incomplete")
            gateway = _address_word(
                _rpc_words(
                    rpc,
                    instance["receipt"],
                    _call_data(SELECTORS["proposalGateway"]),
                    block["number"],
                ),
                0,
                "proposalGateway",
            )
            release_strategy = _address_word(
                _rpc_words(
                    rpc,
                    instance["receipt"],
                    _call_data(SELECTORS["releaseStrategy"]),
                    block["number"],
                ),
                0,
                "releaseStrategy",
            )

            arbitration = instance["arbitration"]
            timeout = _uint_word(
                _rpc_words(rpc, arbitration, _call_data(SELECTORS["timeout"]), block["number"]),
                0,
                "timeout",
            )
            base_x = _uint_word(
                _rpc_words(rpc, arbitration, _call_data(SELECTORS["baseX"]), block["number"]),
                0,
                "baseX",
            )
            max_queue = _uint_word(
                _rpc_words(rpc, arbitration, _call_data(SELECTORS["maxQueue"]), block["number"]),
                0,
                "MAX_QUEUE",
            )
            active = _uint_word(
                _rpc_words(
                    rpc, arbitration, _call_data(SELECTORS["activeEvaluation"]), block["number"]
                ),
                0,
                "activeEvaluationProposalId",
            )
            if max_queue != MAX_QUEUE:
                raise IndexerError("arbitration MAX_QUEUE view is not canonical")

            self.db.execute(
                "DELETE FROM proposal_views WHERE chain_id=? AND arbitration=?",
                (chain_id, arbitration),
            )
            for proposal in self.db.execute(
                "SELECT proposal_id FROM proposals WHERE chain_id=? AND arbitration=?",
                (chain_id, arbitration),
            ).fetchall():
                proposal_id = int(proposal[0])
                words = _rpc_words(
                    rpc,
                    arbitration,
                    _call_data(SELECTORS["getProposal"], proposal_id),
                    block["number"],
                )
                if len(words) != 11 or not _bool_word(words, 10, "proposal.exists"):
                    raise IndexerError("getProposal returned an invalid static tuple")
                state = _uint_word(words, 5, "proposal.state")
                if state >= len(STATE_NAMES):
                    raise IndexerError("getProposal returned an invalid state")
                self.db.execute(
                    "INSERT INTO proposal_views(chain_id,arbitration,proposal_id,block_number,state,"
                    "last_state_change_at,yes_bidder,yes_bond_amount,no_bidder,no_bond_amount,"
                    "queue_position,settled,accepted) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
                    (
                        chain_id,
                        arbitration,
                        str(proposal_id),
                        block["number"],
                        STATE_NAMES[state],
                        _uint_word(words, 6, "proposal.lastStateChangeAt"),
                        _address_word(words, 1, "proposal.yesBidder", True),
                        str(_uint_word(words, 2, "proposal.yesAmount")),
                        _address_word(words, 3, "proposal.noBidder", True),
                        str(_uint_word(words, 4, "proposal.noAmount")),
                        _uint_word(words, 9, "proposal.queuePosition"),
                        int(_bool_word(words, 7, "proposal.settled")),
                        int(_bool_word(words, 8, "proposal.accepted")),
                    ),
                )

            evaluator_market = None
            resolution_ready = False
            if active:
                evaluator_market = _address_word(
                    _rpc_words(
                        rpc,
                        instance["evaluator"],
                        _call_data(SELECTORS["futarchyProposalOf"], active),
                        block["number"],
                    ),
                    0,
                    "futarchyProposalOf",
                    True,
                )
                if evaluator_market is not None:
                    try:
                        _rpc_words(
                            rpc,
                            instance["evaluator"],
                            _call_data(SELECTORS["resolve"], active),
                            block["number"],
                        )
                        resolution_ready = True
                    except RpcCallError:
                        pass

            relay = _rpc_words(
                rpc,
                instance["relay"],
                _call_data(SELECTORS["officialProposalExtended"]),
                block["number"],
            )
            if len(relay) != 13:
                raise IndexerError("officialProposalExtended returned an invalid tuple")
            relay_id = _uint_word(relay, 0, "relay.proposalId")
            relay_proposal = _address_word(relay, 1, "relay.proposal", True)
            relay_exists = _bool_word(relay, 3, "relay.exists")
            relay_settled = _bool_word(relay, 4, "relay.settled")

            manager = instance["manager"]
            flm_mode = _bool_word(
                _rpc_words(
                    rpc, manager, _call_data(SELECTORS["inConditionalMode"]), block["number"]
                ),
                0,
                "inConditionalMode",
            )
            flm_active = _uint_word(
                _rpc_words(
                    rpc, manager, _call_data(SELECTORS["activeProposalId"]), block["number"]
                ),
                0,
                "FLM activeProposalId",
            )
            flm_row = self.db.execute(
                "SELECT mode,active_proposal_id,restore_needed FROM flm_state "
                "WHERE chain_id=? AND manager=?",
                (chain_id, manager),
            ).fetchone()
            expected_mode = "conditional" if flm_mode else "spot"
            emergency_armed = _uint_word(
                _rpc_words(
                    rpc,
                    manager,
                    _call_data(SELECTORS["emergencyExitArmedAt"]),
                    block["number"],
                ),
                0,
                "emergencyExitArmedAt",
            )
            emergency_executed = _bool_word(
                _rpc_words(
                    rpc,
                    manager,
                    _call_data(SELECTORS["emergencyExitExecuted"]),
                    block["number"],
                ),
                0,
                "emergencyExitExecuted",
            )
            initialized = _bool_word(
                _rpc_words(
                    rpc, manager, _call_data(SELECTORS["initialized"]), block["number"]
                ),
                0,
                "initializedFromBootstrap",
            )
            totals = []
            for name in (
                "totalSupply",
                "spotLiquidity",
                "conditionalYesLiquidity",
                "conditionalNoLiquidity",
            ):
                totals.append(
                    _uint_word(
                        _rpc_words(rpc, manager, _call_data(SELECTORS[name]), block["number"]),
                        0,
                        name,
                    )
                )
            sync_action = -1
            try:
                sync_action = _uint_word(
                    _rpc_words(rpc, manager, _call_data(SELECTORS["sync"]), block["number"]),
                    0,
                    "sync action",
                )
                if sync_action not in (0, 1, 2):
                    raise IndexerError("sync returned an invalid action")
            except RpcCallError:
                pass
            restore_ok = False
            if flm_row["restore_needed"]:
                try:
                    result = rpc.call(
                        {"to": manager, "data": _call_data(SELECTORS["restore"])},
                        hex(block["number"]),
                    )
                    restore_ok = isinstance(result, str) and result.lower() == "0x"
                except RpcCallError:
                    pass

            self.db.execute(
                "INSERT OR REPLACE INTO instance_views VALUES("
                + ",".join("?" for _ in range(28))
                + ")",
                (
                    chain_id,
                    instance["receipt"],
                    block["number"],
                    block["hash"],
                    registrar_hash,
                    gateway,
                    release_strategy,
                    str(timeout),
                    str(base_x),
                    max_queue,
                    str(active),
                    evaluator_market,
                    str(relay_id),
                    relay_proposal,
                    int(relay_exists),
                    int(relay_settled),
                    expected_mode,
                    str(flm_active),
                    str(emergency_armed),
                    int(emergency_executed),
                    int(initialized),
                    str(totals[0]),
                    str(totals[1]),
                    str(totals[2]),
                    str(totals[3]),
                    sync_action,
                    int(resolution_ready),
                    int(restore_ok),
                ),
            )

    def _lca(self, rpc: Any, chain_id: int, start: int, remote_final: int) -> int:
        row = self.db.execute(
            "SELECT MAX(number) FROM blocks WHERE chain_id=?", (chain_id,)
        ).fetchone()
        cursor = row[0]
        if cursor is None:
            return start - 1
        candidate = min(int(cursor), remote_final)
        while candidate >= start:
            local = self.db.execute(
                "SELECT hash FROM blocks WHERE chain_id=? AND number=?", (chain_id, candidate)
            ).fetchone()
            remote = _block(rpc.block(candidate))
            if local is not None and local[0] == remote["hash"]:
                return candidate
            candidate -= 1
        return start - 1

    def _watched(self, chain_id: int) -> Set[str]:
        watched = {
            row[0]
            for row in self.db.execute(
                "SELECT address FROM registrars WHERE chain_id=?", (chain_id,)
            )
        }
        for row in self.db.execute(
            "SELECT receipt,arbitration,evaluator,manager FROM instances WHERE chain_id=?",
            (chain_id,),
        ):
            watched.update(value for value in row if value is not None)
        watched.update(
            row[0]
            for row in self.db.execute(
                "SELECT proposal_gateway FROM instance_views WHERE chain_id=?", (chain_id,)
            )
        )
        return watched

    def sync(
        self, rpc: Any, start_block: int, registrars: Iterable[str]
    ) -> Dict[str, Any]:
        chain_id = int(rpc.chain_id())
        final = _block(rpc.finalized_block())
        if final["number"] < start_block:
            raise IndexerError("finalized head precedes start block")
        try:
            with self.db:
                self._bind(chain_id, start_block, registrars)
                lca = self._lca(rpc, chain_id, start_block, final["number"])
                self.db.execute(
                    "DELETE FROM logs WHERE chain_id=? AND block_number>?", (chain_id, lca)
                )
                self.db.execute(
                    "DELETE FROM blocks WHERE chain_id=? AND number>?", (chain_id, lca)
                )
                previous = self.db.execute(
                    "SELECT hash FROM blocks WHERE chain_id=? AND number=?", (chain_id, lca)
                ).fetchone()
                previous_hash = None if previous is None else previous[0]
                for number in range(lca + 1, final["number"] + 1):
                    current = final if number == final["number"] else _block(rpc.block(number))
                    if current["number"] != number:
                        raise IndexerError("RPC returned the wrong block number")
                    if previous_hash is not None and current["parentHash"] != previous_hash:
                        raise IndexerError("finalized block lineage is discontinuous")
                    self.db.execute(
                        "INSERT INTO blocks(chain_id,number,hash,parent_hash,timestamp) "
                        "VALUES(?,?,?,?,?)",
                        (
                            chain_id,
                            number,
                            current["hash"],
                            current["parentHash"],
                            current["timestamp"],
                        ),
                    )
                    previous_hash = current["hash"]

                self._replay(chain_id)
                self._hydrate(rpc, chain_id, final)
                seen_watchers: Set[str] = set()
                for _ in range(8):
                    watched = self._watched(chain_id)
                    if watched == seen_watchers:
                        break
                    seen_watchers = watched
                    for raw in rpc.logs(lca + 1, final["number"], sorted(watched)):
                        try:
                            log = canonical_log(raw)
                        except SchemaError as exc:
                            raise IndexerError(str(exc)) from exc
                        if log["removed"]:
                            continue
                        block_row = self.db.execute(
                            "SELECT hash FROM blocks WHERE chain_id=? AND number=?",
                            (chain_id, log["blockNumber"]),
                        ).fetchone()
                        if block_row is None or block_row[0] != log["blockHash"]:
                            raise IndexerError("log is not on the indexed finalized lineage")
                        encoded_topics = json.dumps(log["topics"], separators=(",", ":"))
                        existing = self.db.execute(
                            "SELECT transaction_hash,address,topics,data,block_number FROM logs "
                            "WHERE chain_id=? AND block_hash=? AND log_index=?",
                            (chain_id, log["blockHash"], log["logIndex"]),
                        ).fetchone()
                        values = (
                            log["transactionHash"],
                            log["address"],
                            encoded_topics,
                            log["data"],
                            log["blockNumber"],
                        )
                        if existing is not None and tuple(existing) != values:
                            raise IndexerError("duplicate canonical log key has different bytes")
                        self.db.execute(
                            "INSERT OR IGNORE INTO logs(chain_id,block_hash,log_index,block_number,"
                            "transaction_hash,address,topics,data) VALUES(?,?,?,?,?,?,?,?)",
                            (
                                chain_id,
                                log["blockHash"],
                                log["logIndex"],
                                log["blockNumber"],
                                log["transactionHash"],
                                log["address"],
                                encoded_topics,
                                log["data"],
                            ),
                        )
                    self._replay(chain_id)
                    self._hydrate(rpc, chain_id, final)
                else:
                    raise IndexerError("event address discovery did not converge")

                self._validate_view_alignment(chain_id)
                self._set_meta("cursorNumber", final["number"])
                self._set_meta("cursorHash", final["hash"])
            return self.report()
        except sqlite3.IntegrityError as exc:
            raise IndexerError("derived state violates uniqueness") from exc

    def _validate_view_alignment(self, chain_id: int) -> None:
        for row in self.db.execute(
            "SELECT i.active_evaluation_proposal_id,v.active_proposal_id,f.mode,"
            "f.active_proposal_id AS flm_event_id,v.flm_mode,v.flm_active_proposal_id "
            "FROM instances i JOIN instance_views v ON v.chain_id=i.chain_id AND v.receipt=i.receipt "
            "JOIN flm_state f ON f.chain_id=i.chain_id AND f.manager=i.manager WHERE i.chain_id=?",
            (chain_id,),
        ):
            if (
                row["active_evaluation_proposal_id"] != row["active_proposal_id"]
                or row["mode"] != row["flm_mode"]
                or row["flm_event_id"] != row["flm_active_proposal_id"]
            ):
                raise IndexerError("finalized contract views disagree with replayed event state")

    def replay(self) -> bytes:
        chain = self._meta("chainId")
        if chain is None:
            raise IndexerError("database is not bound to a chain")
        with self.db:
            self._replay(int(chain))
        return self.report_bytes()

    def keeper_state(self, receipt: str) -> Dict[str, Any]:
        chain = self._meta("chainId")
        if chain is None:
            raise IndexerError("database is not bound to a chain")
        chain_id = int(chain)
        try:
            receipt = address(receipt, "receipt")
        except SchemaError as exc:
            raise IndexerError(str(exc)) from exc
        instance = self.db.execute(
            "SELECT i.*,v.* FROM instances i JOIN instance_views v "
            "ON v.chain_id=i.chain_id AND v.receipt=i.receipt "
            "WHERE i.chain_id=? AND i.receipt=?",
            (chain_id, receipt),
        ).fetchone()
        if instance is None:
            raise IndexerError("instance has no finalized hydrated view")
        proposals = []
        rows = self.db.execute(
            "SELECT p.*,v.state AS view_state,v.last_state_change_at AS view_changed,"
            "v.yes_bond_amount AS view_yes,v.no_bond_amount AS view_no,v.settled AS view_settled "
            "FROM proposals p JOIN proposal_views v ON v.chain_id=p.chain_id "
            "AND v.arbitration=p.arbitration AND v.proposal_id=p.proposal_id "
            "WHERE p.chain_id=? AND p.arbitration=?",
            (chain_id, instance["arbitration"]),
        ).fetchall()
        rows.sort(key=lambda row: int(row["proposal_id"]))
        for proposal in rows:
            proposals.append(
                {
                    "proposalId": int(proposal["proposal_id"]),
                    "state": proposal["view_state"],
                    "lastStateChangeAt": proposal["view_changed"],
                    "yesBondAmount": int(proposal["view_yes"]),
                    "noBondAmount": int(proposal["view_no"]),
                    "settled": bool(proposal["view_settled"]),
                    "futarchyProposal": proposal["futarchy_proposal"],
                    "evaluationPayload": proposal["evaluation_payload"],
                    "payloadSource": proposal["payload_source"],
                    "resolutionReady": bool(instance["resolution_ready"])
                    and proposal["proposal_id"] == instance["active_proposal_id"],
                }
            )
        queued = sorted(
            (row for row in rows if row["view_state"] == "QUEUED"),
            key=lambda row: (row["enqueued_block"], row["enqueued_log_index"]),
        )
        block_row = self.db.execute(
            "SELECT timestamp FROM blocks WHERE chain_id=? AND number=?",
            (chain_id, instance["block_number"]),
        ).fetchone()
        if block_row is None:
            raise IndexerError("hydrated view block is not canonical")
        flm = self.db.execute(
            "SELECT restore_needed FROM flm_state WHERE chain_id=? AND manager=?",
            (chain_id, instance["manager"]),
        ).fetchone()
        emergency = bool(int(instance["emergency_armed_at"])) or bool(
            instance["emergency_executed"]
        )
        return {
            "arbitration": instance["arbitration"],
            "evaluator": instance["evaluator"],
            "manager": instance["manager"],
            "now": block_row[0],
            "timeout": int(instance["timeout"]),
            "baseX": int(instance["base_x"]),
            "activeEvaluationProposalId": int(instance["active_proposal_id"]),
            "queue": [int(row["proposal_id"]) for row in queued],
            "proposals": proposals,
            "flm": {
                "syncReady": instance["sync_action"] in (1, 2),
                "restoreNeeded": bool(flm[0]) and bool(instance["restore_call_ok"]),
                "emergency": emergency,
            },
        }

    def next_action(self, receipt: str) -> Any:
        from .keeper import decide

        return decide(self.keeper_state(receipt))

    def record_attempt(
        self,
        action: Any,
        keeper: str,
        phase: str,
        outcome: str,
        *,
        revert_data: Optional[str] = None,
        tx_hash: Optional[str] = None,
        detail: str = "",
    ) -> Dict[str, Any]:
        chain = self._meta("chainId")
        if chain is None:
            raise IndexerError("database is not bound to a chain")
        if phase not in ("staticcall", "send", "receipt", "funding"):
            raise IndexerError("attempt phase is invalid")
        if outcome not in ("ok", "revert", "submitted", "landed", "refused"):
            raise IndexerError("attempt outcome is invalid")
        try:
            keeper = address(keeper, "keeper")
            target = address(action.to, "action target")
        except (AttributeError, SchemaError) as exc:
            raise IndexerError("attempt action or keeper is invalid") from exc
        if (
            not isinstance(action.kind, str)
            or not action.kind
            or len(action.kind) > 64
            or not isinstance(action.data, str)
            or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", action.data)
        ):
            raise IndexerError("attempt action fields are invalid")
        if not isinstance(detail, str) or len(detail.encode("utf-8")) > 512:
            raise IndexerError("attempt detail exceeds 512 UTF-8 bytes")
        if tx_hash is not None:
            try:
                tx_hash = hex_bytes(tx_hash, 32, "transaction hash")
            except SchemaError as exc:
                raise IndexerError(str(exc)) from exc
        if revert_data is not None and (
            not isinstance(revert_data, str)
            or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", revert_data)
        ):
            raise IndexerError("revert data must be byte hex")
        classification = _attempt_classification(outcome, revert_data)
        canonical = json.dumps(
            {
                "kind": action.kind,
                "to": target,
                "data": action.data,
                "proposalId": action.proposal_id,
            },
            sort_keys=True,
            separators=(",", ":"),
        ).encode("utf-8")
        fingerprint = "0x" + hashlib.sha256(canonical).hexdigest()
        with self.db:
            attempt_id = self.db.execute("SELECT COALESCE(MAX(attempt_id),0)+1 FROM attempts").fetchone()[0]
            self.db.execute(
                "INSERT INTO attempts VALUES(" + ",".join("?" for _ in range(16)) + ")",
                (
                    attempt_id,
                    int(chain),
                    fingerprint,
                    keeper,
                    phase,
                    outcome,
                    classification,
                    action.kind,
                    target,
                    action.data,
                    None if action.proposal_id is None else str(action.proposal_id),
                    tx_hash,
                    None if revert_data is None else revert_data.lower(),
                    detail,
                    None,
                    None,
                ),
            )
            if phase == "receipt" and outcome == "landed" and action.kind == "flmRestore":
                self.db.execute(
                    "UPDATE flm_state SET restore_needed=0 WHERE chain_id=? AND manager=?",
                    (int(chain), target),
                )
        return dict(self.db.execute("SELECT * FROM attempts WHERE attempt_id=?", (attempt_id,)).fetchone())

    def staticcall_action(self, rpc: Any, action: Any, keeper: str) -> Dict[str, Any]:
        cursor = self._meta("cursorNumber")
        if cursor is None:
            raise IndexerError("database has no finalized cursor")
        try:
            keeper = address(keeper, "keeper")
        except SchemaError as exc:
            raise IndexerError(str(exc)) from exc
        transaction = {"from": keeper, "to": action.to, "data": action.data, "value": "0x0"}
        try:
            result = rpc.call(transaction, hex(int(cursor)))
            return self.record_attempt(
                action, keeper, "staticcall", "ok", detail="return=" + str(result)[:256]
            )
        except RpcCallError as exc:
            return self.record_attempt(
                action,
                keeper,
                "staticcall",
                "revert",
                revert_data=exc.data,
                detail=str(exc)[:512],
            )

    def classify_race(
        self, winner_attempt_id: int, loser_attempt_id: int, postcondition_satisfied: bool
    ) -> Dict[str, Any]:
        winner = self.db.execute(
            "SELECT * FROM attempts WHERE attempt_id=?", (winner_attempt_id,)
        ).fetchone()
        loser = self.db.execute(
            "SELECT * FROM attempts WHERE attempt_id=?", (loser_attempt_id,)
        ).fetchone()
        if (
            winner is None
            or loser is None
            or winner["action_sha256"] != loser["action_sha256"]
            or winner["outcome"] != "landed"
            or loser["outcome"] != "revert"
            or not postcondition_satisfied
        ):
            raise IndexerError("benign race requires one matching winner and satisfied post-state")
        with self.db:
            self.db.execute(
                "UPDATE attempts SET classification='benign-race',race_winner_attempt_id=?,"
                "postcondition_satisfied=1 WHERE attempt_id=?",
                (winner_attempt_id, loser_attempt_id),
            )
        return dict(
            self.db.execute(
                "SELECT * FROM attempts WHERE attempt_id=?", (loser_attempt_id,)
            ).fetchone()
        )

    def _replay(self, chain_id: int) -> None:
        # ponytail: full replay is the safest P0; checkpoint only after load tiers show it is needed.
        self.db.execute("DELETE FROM flm_state WHERE chain_id=?", (chain_id,))
        self.db.execute("DELETE FROM proposals WHERE chain_id=?", (chain_id,))
        self.db.execute("DELETE FROM instances WHERE chain_id=?", (chain_id,))
        rows = self.db.execute(
            "SELECT l.*,b.timestamp FROM logs l JOIN blocks b "
            "ON b.chain_id=l.chain_id AND b.hash=l.block_hash "
            "WHERE l.chain_id=? ORDER BY l.block_number,l.log_index",
            (chain_id,),
        )
        for row in rows:
            log = {
                "address": row["address"],
                "blockHash": row["block_hash"],
                "blockNumber": row["block_number"],
                "transactionHash": row["transaction_hash"],
                "logIndex": row["log_index"],
                "topics": json.loads(row["topics"]),
                "data": row["data"],
            }
            try:
                spec, event = decode_event(log)
            except SchemaError as exc:
                if str(exc) == "unknown event topic":
                    continue
                raise IndexerError(str(exc)) from exc
            self._apply(chain_id, row["timestamp"], log, spec["id"], spec["emitterRole"], event)
        self.db.execute(
            "DELETE FROM instance_views WHERE chain_id=? AND receipt NOT IN "
            "(SELECT receipt FROM instances WHERE chain_id=?)",
            (chain_id, chain_id),
        )

    def _role_instance(self, chain_id: int, emitter: str, role: str) -> Optional[sqlite3.Row]:
        if role == "registrar":
            return self.db.execute(
                "SELECT NULL AS receipt WHERE EXISTS(SELECT 1 FROM registrars "
                "WHERE chain_id=? AND address=?)",
                (chain_id, emitter),
            ).fetchone()
        if role == "gateway":
            return self.db.execute(
                "SELECT i.* FROM instances i JOIN instance_views v "
                "ON v.chain_id=i.chain_id AND v.receipt=i.receipt "
                "WHERE i.chain_id=? AND v.proposal_gateway=?",
                (chain_id, emitter),
            ).fetchone()
        column = {
            "receipt": "receipt",
            "space": "space",
            "arbitration": "arbitration",
            "evaluator": "evaluator",
            "manager": "manager",
        }[role]
        return self.db.execute(
            "SELECT * FROM instances WHERE chain_id=? AND %s=?" % column,
            (chain_id, emitter),
        ).fetchone()

    def _proposal(self, chain_id: int, arbitration: str, proposal_id: int) -> sqlite3.Row:
        row = self.db.execute(
            "SELECT * FROM proposals WHERE chain_id=? AND arbitration=? AND proposal_id=?",
            (chain_id, arbitration, str(proposal_id)),
        ).fetchone()
        if row is None:
            raise IndexerError("proposal event precedes ProposalCreated")
        return row

    def _apply(
        self,
        chain_id: int,
        timestamp: int,
        log: Dict[str, Any],
        event_id: str,
        role: str,
        event: Dict[str, Any],
    ) -> None:
        emitter = log["address"]
        instance = self._role_instance(chain_id, emitter, role)
        if instance is None:
            raise IndexerError("%s was emitted by the wrong role" % event_id)

        if event_id == "registrar.genesisStaged":
            self.db.execute(
                "INSERT INTO instances(chain_id,receipt,registrar,core_hash,flm_hash,stager) "
                "VALUES(?,?,?,?,?,?)",
                (
                    chain_id,
                    event["receipt"],
                    emitter,
                    event["coreHash"],
                    event["flmHash"],
                    event["stager"],
                ),
            )
            return
        if event_id == "receipt.coreSealed":
            if instance["arbitration"] is not None:
                raise IndexerError("CoreSealed repeated")
            self.db.execute(
                "UPDATE instances SET vault=?,company_token=?,space=?,arbitration=?,evaluator=?,spot_pool=? "
                "WHERE chain_id=? AND receipt=?",
                (
                    event["vault"],
                    event["companyToken"],
                    event["space"],
                    event["arbitration"],
                    event["evaluator"],
                    event["spotPool"],
                    chain_id,
                    emitter,
                ),
            )
            return
        if event_id == "receipt.flmSealed":
            if instance["arbitration"] is None or instance["manager"] is not None:
                raise IndexerError("FlmSealed is out of order")
            self.db.execute(
                "UPDATE instances SET manager=?,relay=?,spot_adapter=? WHERE chain_id=? AND receipt=?",
                (event["manager"], event["relay"], event["spotAdapter"], chain_id, emitter),
            )
            self.db.execute(
                "INSERT INTO flm_state(chain_id,manager,mode,active_proposal_id) VALUES(?,?,?,?)",
                (chain_id, event["manager"], "spot", "0"),
            )
            return

        if role == "arbitration":
            arbitration = emitter
            if event_id == "arbitration.proposalCreated":
                self.db.execute(
                    "INSERT INTO proposals(chain_id,arbitration,proposal_id,creator,"
                    "min_activation_bond,state,last_state_change_at) VALUES(?,?,?,?,?,?,?)",
                    (
                        chain_id,
                        arbitration,
                        str(event["proposalId"]),
                        event["creator"],
                        str(event["minActivationBond"]),
                        "INACTIVE",
                        timestamp,
                    ),
                )
                return
            proposal = self._proposal(chain_id, arbitration, event["proposalId"])
            if event_id == "arbitration.bondPlaced":
                if event["newState"] not in (1, 2):
                    raise IndexerError("BondPlaced state must be YES or NO")
                side = "yes" if event["newState"] == 1 else "no"
                self.db.execute(
                    "UPDATE proposals SET state=?,last_state_change_at=?,%s_bidder=?,%s_bond_amount=? "
                    "WHERE chain_id=? AND arbitration=? AND proposal_id=?" % (side, side),
                    (
                        STATE_NAMES[event["newState"]],
                        timestamp,
                        event["bidder"],
                        str(event["amount"]),
                        chain_id,
                        arbitration,
                        str(event["proposalId"]),
                    ),
                )
                return
            if event_id == "arbitration.proposalGraduated":
                queued = self.db.execute(
                    "SELECT COUNT(*) FROM proposals WHERE chain_id=? AND arbitration=? AND state='QUEUED'",
                    (chain_id, arbitration),
                ).fetchone()[0]
                active = int(instance["active_evaluation_proposal_id"] != "0")
                if proposal["state"] != "YES" or queued + active >= MAX_QUEUE:
                    raise IndexerError("graduation violates MAX_QUEUE or proposal state")
                if event["queuePosition"] != queued + 1:
                    raise IndexerError("graduation queuePosition is not FIFO-relative")
                self.db.execute(
                    "UPDATE proposals SET state='QUEUED',queue_position=?,enqueued_block=?,"
                    "enqueued_log_index=? WHERE chain_id=? AND arbitration=? AND proposal_id=?",
                    (
                        event["queuePosition"],
                        log["blockNumber"],
                        log["logIndex"],
                        chain_id,
                        arbitration,
                        str(event["proposalId"]),
                    ),
                )
                return
            if event_id == "arbitration.evaluationStarted":
                head = self.db.execute(
                    "SELECT proposal_id FROM proposals WHERE chain_id=? AND arbitration=? "
                    "AND state='QUEUED' ORDER BY enqueued_block,enqueued_log_index LIMIT 1",
                    (chain_id, arbitration),
                ).fetchone()
                if (
                    instance["active_evaluation_proposal_id"] != "0"
                    or proposal["state"] != "QUEUED"
                    or head is None
                    or head[0] != str(event["proposalId"])
                ):
                    raise IndexerError("EvaluationStarted violates FIFO or singleton evaluation")
                self.db.execute(
                    "UPDATE proposals SET state='EVALUATING',last_state_change_at=? WHERE chain_id=? "
                    "AND arbitration=? AND proposal_id=?",
                    (timestamp, chain_id, arbitration, str(event["proposalId"])),
                )
                self.db.execute(
                    "UPDATE instances SET active_evaluation_proposal_id=? WHERE chain_id=? AND arbitration=?",
                    (str(event["proposalId"]), chain_id, arbitration),
                )
                return
            if event_id in (
                "arbitration.evaluationResolved",
                "arbitration.finalizedByTimeout",
            ):
                if event_id.endswith("evaluationResolved"):
                    if (
                        proposal["state"] != "EVALUATING"
                        or instance["active_evaluation_proposal_id"] != str(event["proposalId"])
                    ):
                        raise IndexerError("evaluation resolution does not match active proposal")
                    self.db.execute(
                        "UPDATE instances SET active_evaluation_proposal_id='0' "
                        "WHERE chain_id=? AND arbitration=?",
                        (chain_id, arbitration),
                    )
                elif proposal["state"] not in ("YES", "NO"):
                    raise IndexerError("timeout resolution has invalid proposal state")
                self.db.execute(
                    "UPDATE proposals SET state='SETTLED',last_state_change_at=?,settled=1,accepted=? "
                    "WHERE chain_id=? AND arbitration=? AND proposal_id=?",
                    (
                        timestamp,
                        int(event["accepted"]),
                        chain_id,
                        arbitration,
                        str(event["proposalId"]),
                    ),
                )
                return

        if role == "gateway":
            proposal = self._proposal(chain_id, instance["arbitration"], event["proposalId"])
            if event_id == "gateway.transferProposed":
                payload = _static_payload(
                    TRANSFER_KIND,
                    chain_id,
                    instance["vault"],
                    event["asset"],
                    event["recipient"],
                    event["amount"],
                    event["salt"],
                )
            elif event_id == "gateway.paramProposed":
                payload = _static_payload(
                    PARAM_KIND,
                    chain_id,
                    instance["vault"],
                    event["key"],
                    event["asset"],
                    event["value"],
                    event["salt"],
                )
            else:
                if event["round"] not in (1, 2):
                    raise IndexerError("critical round is not canonical")
                payload = _static_payload(
                    CRITICAL_KIND,
                    chain_id,
                    instance["vault"],
                    event["target"],
                    event["value"],
                    event["dataHash"],
                    event["salt"],
                    event["round"],
                )
            self._bind_payload(chain_id, proposal, payload, event_id)
            return

        if role == "space":
            proposal = self._proposal(chain_id, instance["arbitration"], event["arbitrationId"])
            view = self.db.execute(
                "SELECT release_strategy FROM instance_views WHERE chain_id=? AND receipt=?",
                (chain_id, instance["receipt"]),
            ).fetchone()
            if view is None or view[0] != event["executionStrategy"]:
                raise IndexerError("site payload does not use the sealed release strategy")
            self._bind_payload(
                chain_id, proposal, event["evaluationPayload"], "space.proposalCreated"
            )
            return

        if role == "evaluator":
            proposal = self._proposal(chain_id, instance["arbitration"], event["proposalId"])
            if event_id in (
                "evaluator.economicMarketCreated",
                "evaluator.siteMarketCreated",
            ):
                if proposal["state"] != "EVALUATING" or proposal["futarchy_proposal"] is not None:
                    raise IndexerError("market creation does not match active evaluation")
                self.db.execute(
                    "UPDATE proposals SET futarchy_proposal=?,futarchy_proposal_id=?,payload_kind=?,"
                    "payload_commitment=? WHERE chain_id=? AND arbitration=? AND proposal_id=?",
                    (
                        event["futarchyProposal"],
                        str(event["futarchyProposalId"]),
                        event.get("payloadKind"),
                        event.get("payloadCommitment", event.get("artifactDigest")),
                        chain_id,
                        instance["arbitration"],
                        str(event["proposalId"]),
                    ),
                )
                return
            if event_id == "evaluator.evaluationResolved":
                if proposal["futarchy_proposal"] != event["futarchyProposal"] or not proposal["settled"]:
                    raise IndexerError("evaluator resolution is not bound to the settled market")
                self.db.execute(
                    "UPDATE proposals SET condition_id=?,accepted=? WHERE chain_id=? AND arbitration=? "
                    "AND proposal_id=?",
                    (
                        event["conditionId"],
                        int(event["accepted"]),
                        chain_id,
                        instance["arbitration"],
                        str(event["proposalId"]),
                    ),
                )
                return

        if role == "manager":
            flm = self.db.execute(
                "SELECT * FROM flm_state WHERE chain_id=? AND manager=?", (chain_id, emitter)
            ).fetchone()
            if event_id == "flm.migratedToConditional":
                if flm["mode"] != "spot":
                    raise IndexerError("FLM is already conditional")
                self.db.execute(
                    "UPDATE flm_state SET mode='conditional',active_proposal_id=?,restore_needed=0 "
                    "WHERE chain_id=? AND manager=?",
                    (str(event["proposalId"]), chain_id, emitter),
                )
                return
            if event_id == "flm.restoreDeferred":
                self.db.execute(
                    "UPDATE flm_state SET restore_needed=1 WHERE chain_id=? AND manager=?",
                    (chain_id, emitter),
                )
                return
            if event_id == "flm.migratedBackToSpot":
                if flm["mode"] != "conditional" or flm["active_proposal_id"] != str(event["proposalId"]):
                    raise IndexerError("FLM restore does not match its active proposal")
                self.db.execute(
                    "UPDATE flm_state SET mode='spot',active_proposal_id='0',restore_needed=0 "
                    "WHERE chain_id=? AND manager=?",
                    (chain_id, emitter),
                )
                return
        raise IndexerError("unhandled schema event %s" % event_id)

    def _bind_payload(
        self, chain_id: int, proposal: sqlite3.Row, payload: str, source: str
    ) -> None:
        existing = proposal["evaluation_payload"]
        if existing is not None and existing != payload:
            raise IndexerError("proposal has conflicting committed payload events")
        self.db.execute(
            "UPDATE proposals SET evaluation_payload=?,payload_source=? WHERE chain_id=? "
            "AND arbitration=? AND proposal_id=?",
            (
                payload,
                source,
                chain_id,
                proposal["arbitration"],
                proposal["proposal_id"],
            ),
        )

    def report(self) -> Dict[str, Any]:
        chain = self._meta("chainId")
        if chain is None:
            return {"schemaVersion": 2, "chainId": None, "cursor": None, "instances": []}
        chain_id = int(chain)
        instances = []
        for row in self.db.execute(
            "SELECT * FROM instances WHERE chain_id=? ORDER BY receipt", (chain_id,)
        ):
            proposals = []
            if row["arbitration"] is not None:
                proposal_rows = list(
                    self.db.execute(
                        "SELECT * FROM proposals WHERE chain_id=? AND arbitration=?",
                        (chain_id, row["arbitration"]),
                    )
                )
                proposal_rows.sort(key=lambda item: int(item["proposal_id"]))
                for proposal in proposal_rows:
                    proposals.append(
                        {
                            "proposalId": proposal["proposal_id"],
                            "creator": proposal["creator"],
                            "minActivationBond": proposal["min_activation_bond"],
                            "state": proposal["state"],
                            "lastStateChangeAt": proposal["last_state_change_at"],
                            "yesBidder": proposal["yes_bidder"],
                            "yesBondAmount": proposal["yes_bond_amount"],
                            "noBidder": proposal["no_bidder"],
                            "noBondAmount": proposal["no_bond_amount"],
                            "queuePosition": proposal["queue_position"],
                            "settled": bool(proposal["settled"]),
                            "accepted": None
                            if proposal["accepted"] is None
                            else bool(proposal["accepted"]),
                            "futarchyProposal": proposal["futarchy_proposal"],
                            "futarchyProposalId": proposal["futarchy_proposal_id"],
                            "conditionId": proposal["condition_id"],
                            "payloadKind": proposal["payload_kind"],
                            "payloadCommitment": proposal["payload_commitment"],
                            "evaluationPayload": proposal["evaluation_payload"],
                            "payloadSource": proposal["payload_source"],
                        }
                    )
                queued = sorted(
                    (item for item in proposal_rows if item["state"] == "QUEUED"),
                    key=lambda item: (item["enqueued_block"], item["enqueued_log_index"]),
                )
                queue = [item["proposal_id"] for item in queued]
            else:
                queue = []
            flm = None
            hydrated = self.db.execute(
                "SELECT * FROM instance_views WHERE chain_id=? AND receipt=?",
                (chain_id, row["receipt"]),
            ).fetchone()
            if row["manager"] is not None:
                flm_row = self.db.execute(
                    "SELECT mode,active_proposal_id,restore_needed FROM flm_state "
                    "WHERE chain_id=? AND manager=?",
                    (chain_id, row["manager"]),
                ).fetchone()
                flm = {
                    "manager": row["manager"],
                    "relay": row["relay"],
                    "spotAdapter": row["spot_adapter"],
                    "mode": flm_row["mode"],
                    "activeProposalId": flm_row["active_proposal_id"],
                    "restoreNeeded": bool(flm_row["restore_needed"]),
                }
            instances.append(
                {
                    "receipt": row["receipt"],
                    "registrar": row["registrar"],
                    "coreHash": row["core_hash"],
                    "flmHash": row["flm_hash"],
                    "stager": row["stager"],
                    "vault": row["vault"],
                    "companyToken": row["company_token"],
                    "space": row["space"],
                    "arbitration": row["arbitration"],
                    "evaluator": row["evaluator"],
                    "spotPool": row["spot_pool"],
                    "activeEvaluationProposalId": row["active_evaluation_proposal_id"],
                    "queue": queue,
                    "queueCapacity": MAX_QUEUE,
                    "proposals": proposals,
                    "flm": flm,
                    "hydrated": None
                    if hydrated is None
                    else {
                        "blockNumber": hydrated["block_number"],
                        "blockHash": hydrated["block_hash"],
                        "registrarCodeHash": hydrated["registrar_code_hash"],
                        "proposalGateway": hydrated["proposal_gateway"],
                        "releaseStrategy": hydrated["release_strategy"],
                        "timeout": hydrated["timeout"],
                        "baseX": hydrated["base_x"],
                        "maxQueue": hydrated["max_queue"],
                        "activeProposalId": hydrated["active_proposal_id"],
                        "evaluatorMarket": hydrated["evaluator_market"],
                        "relayProposalId": hydrated["relay_proposal_id"],
                        "relayProposal": hydrated["relay_proposal"],
                        "relayExists": bool(hydrated["relay_exists"]),
                        "relaySettled": bool(hydrated["relay_settled"]),
                        "syncAction": hydrated["sync_action"],
                        "resolutionReady": bool(hydrated["resolution_ready"]),
                        "restoreCallOk": bool(hydrated["restore_call_ok"]),
                    },
                }
            )
        cursor_number = self._meta("cursorNumber")
        return {
            "schemaVersion": 2,
            "chainId": chain_id,
            "cursor": None
            if cursor_number is None
            else {"number": int(cursor_number), "hash": self._meta("cursorHash")},
            "rawCanonicalLogs": self.db.execute(
                "SELECT COUNT(*) FROM logs WHERE chain_id=?", (chain_id,)
            ).fetchone()[0],
            "instances": instances,
            "attempts": [dict(row) for row in self.db.execute("SELECT * FROM attempts ORDER BY attempt_id")],
        }

    def report_bytes(self) -> bytes:
        return json.dumps(self.report(), sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"

    def evidence(self) -> Dict[str, Any]:
        report = self.report_bytes()
        return {
            "schemaVersion": 2,
            "kind": "fao.windtunnel.index-report",
            "reportSha256": "0x" + hashlib.sha256(report).hexdigest(),
            "report": json.loads(report),
        }
