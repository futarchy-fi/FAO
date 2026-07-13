"""Finalized-log SQLite indexer with reorg rewind and deterministic replay."""

from __future__ import annotations

import hashlib
import json
import sqlite3
import urllib.error
import urllib.request
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Set, Tuple, Union

from .schema import EVENTS, SchemaError, address, canonical_log, decode_event, hex_bytes, quantity


MAX_QUEUE = 16
STATE_NAMES = ("INACTIVE", "YES", "NO", "QUEUED", "EVALUATING", "SETTLED")


class IndexerError(ValueError):
    pass


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
            raise IndexerError("JSON-RPC %s failed: %s" % (method, value["error"]))
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
  payload_kind TEXT, payload_commitment TEXT,
  PRIMARY KEY (chain_id, arbitration, proposal_id)
) WITHOUT ROWID;
CREATE TABLE IF NOT EXISTS flm_state (
  chain_id INTEGER NOT NULL, manager TEXT NOT NULL, mode TEXT NOT NULL,
  active_proposal_id TEXT NOT NULL,
  PRIMARY KEY (chain_id, manager)
) WITHOUT ROWID;
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


class Indexer:
    def __init__(self, path: Union[str, Path]) -> None:
        self.path = str(path)
        self.db = sqlite3.connect(self.path)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA foreign_keys = ON")
        self.db.executescript(SCHEMA)
        version = self._meta("schemaVersion")
        if version not in (None, "1"):
            raise IndexerError("unsupported index schema")
        self._set_meta("schemaVersion", "1")
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
                else:
                    raise IndexerError("event address discovery did not converge")

                self._set_meta("cursorNumber", final["number"])
                self._set_meta("cursorHash", final["hash"])
            return self.report()
        except sqlite3.IntegrityError as exc:
            raise IndexerError("derived state violates uniqueness") from exc

    def replay(self) -> bytes:
        chain = self._meta("chainId")
        if chain is None:
            raise IndexerError("database is not bound to a chain")
        with self.db:
            self._replay(int(chain))
        return self.report_bytes()

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

    def _role_instance(self, chain_id: int, emitter: str, role: str) -> Optional[sqlite3.Row]:
        if role == "registrar":
            return self.db.execute(
                "SELECT NULL AS receipt WHERE EXISTS(SELECT 1 FROM registrars "
                "WHERE chain_id=? AND address=?)",
                (chain_id, emitter),
            ).fetchone()
        column = {"receipt": "receipt", "arbitration": "arbitration", "evaluator": "evaluator", "manager": "manager"}[role]
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
                    if proposal["state"] != "EVALUATING" or instance["active_evaluation_proposal_id"] != str(event["proposalId"]):
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
                    "UPDATE flm_state SET mode='conditional',active_proposal_id=? "
                    "WHERE chain_id=? AND manager=?",
                    (str(event["proposalId"]), chain_id, emitter),
                )
                return
            if event_id == "flm.migratedBackToSpot":
                if flm["mode"] != "conditional" or flm["active_proposal_id"] != str(event["proposalId"]):
                    raise IndexerError("FLM restore does not match its active proposal")
                self.db.execute(
                    "UPDATE flm_state SET mode='spot',active_proposal_id='0' "
                    "WHERE chain_id=? AND manager=?",
                    (chain_id, emitter),
                )
                return
        raise IndexerError("unhandled schema event %s" % event_id)

    def report(self) -> Dict[str, Any]:
        chain = self._meta("chainId")
        if chain is None:
            return {"schemaVersion": 1, "chainId": None, "cursor": None, "instances": []}
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
            if row["manager"] is not None:
                flm_row = self.db.execute(
                    "SELECT mode,active_proposal_id FROM flm_state WHERE chain_id=? AND manager=?",
                    (chain_id, row["manager"]),
                ).fetchone()
                flm = {
                    "manager": row["manager"],
                    "relay": row["relay"],
                    "spotAdapter": row["spot_adapter"],
                    "mode": flm_row["mode"],
                    "activeProposalId": flm_row["active_proposal_id"],
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
                }
            )
        cursor_number = self._meta("cursorNumber")
        return {
            "schemaVersion": 1,
            "chainId": chain_id,
            "cursor": None
            if cursor_number is None
            else {"number": int(cursor_number), "hash": self._meta("cursorHash")},
            "rawCanonicalLogs": self.db.execute(
                "SELECT COUNT(*) FROM logs WHERE chain_id=?", (chain_id,)
            ).fetchone()[0],
            "instances": instances,
        }

    def report_bytes(self) -> bytes:
        return json.dumps(self.report(), sort_keys=True, separators=(",", ":")).encode("utf-8") + b"\n"

    def evidence(self) -> Dict[str, Any]:
        report = self.report_bytes()
        return {
            "schemaVersion": 1,
            "kind": "fao.windtunnel.index-report",
            "reportSha256": "0x" + hashlib.sha256(report).hexdigest(),
            "report": json.loads(report),
        }
