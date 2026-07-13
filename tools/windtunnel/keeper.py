"""Pure one-crank keeper policy and unsigned ABI call construction."""

from __future__ import annotations

import re
from dataclasses import dataclass
from typing import Any, Dict, Optional, Protocol

from .schema import SchemaError, address


MAX_QUEUE = 16
SELECTORS = {
    "finalizeByTimeout": "13d4e9ed",
    "tryGraduate": "5ae34863",
    "startNextEvaluation": "d2b8360a",
    "startEvaluation": "73561afc",
    "resolve": "4f896d4f",
    "sync": "fff6cae9",
    "restoreLiquidity": "adc637be",
}


class KeeperError(ValueError):
    pass


@dataclass(frozen=True)
class Action:
    kind: str
    to: str
    data: str
    proposal_id: Optional[int] = None

    def transaction(self, sender: str, chain_id: Optional[int] = None) -> Dict[str, Any]:
        try:
            from_ = address(sender, "sender")
        except SchemaError as exc:
            raise KeeperError(str(exc)) from exc
        transaction = {
            "from": from_,
            "to": self.to,
            "data": self.data,
            "value": "0x0",
        }
        if chain_id is not None:
            transaction["chainId"] = chain_id
        return transaction


class StaticCaller(Protocol):
    def call(self, transaction: Dict[str, Any], block: str = "latest") -> str:
        ...


class TransactionSender(Protocol):
    """External signer/broadcaster boundary; implementations and secrets stay outside this package."""

    def send(self, unsigned_transaction: Dict[str, Any]) -> str:
        ...


def staticcall(caller: StaticCaller, action: Action, sender: str) -> str:
    return caller.call(action.transaction(sender), "latest")


def _word(number: int) -> bytes:
    if not isinstance(number, int) or number < 0 or number >= 1 << 256:
        raise KeeperError("ABI integer is out of range")
    return number.to_bytes(32, "big")


def _bytes(value: Any, label: str) -> bytes:
    if not isinstance(value, str) or not re.fullmatch(r"0x(?:[0-9a-fA-F]{2})*", value):
        raise KeeperError("%s must be byte hex" % label)
    return bytes.fromhex(value[2:])


def _one_uint(selector: str, value: int) -> str:
    return "0x" + SELECTORS[selector] + _word(value).hex()


def _start_evaluation(proposal_id: int, payload: str) -> str:
    raw = _bytes(payload, "evaluation payload")
    padded = raw + bytes((-len(raw)) % 32)
    encoded = _word(proposal_id) + _word(64) + _word(len(raw)) + padded
    return "0x" + SELECTORS["startEvaluation"] + encoded.hex()


def decide(state: Any) -> Optional[Action]:
    """Return one deterministic permissionless action, or ``None``."""

    if not isinstance(state, dict):
        raise KeeperError("keeper state must be an object")
    try:
        arbitration = address(state["arbitration"], "arbitration")
        evaluator = address(state["evaluator"], "evaluator")
        manager = address(state["manager"], "manager")
        now = int(state["now"])
        timeout = int(state["timeout"])
        base_x = int(state["baseX"])
        active = int(state.get("activeEvaluationProposalId", 0))
        queue = [int(item) for item in state.get("queue", [])]
        proposals = {int(item["proposalId"]): item for item in state.get("proposals", [])}
    except (KeyError, TypeError, ValueError, SchemaError) as exc:
        raise KeeperError("keeper state is incomplete") from exc
    if now < 0 or timeout <= 0 or base_x <= 0 or len(queue) > MAX_QUEUE:
        raise KeeperError("keeper timing or queue facts are invalid")
    if len(queue) != len(set(queue)) or any(proposal_id not in proposals for proposal_id in queue):
        raise KeeperError("queue must contain unique known proposals")
    if queue and proposals[queue[0]].get("state") != "QUEUED":
        raise KeeperError("queue head is not QUEUED")

    flm = state.get("flm", {})
    sync_ready = bool(flm.get("syncReady", False))
    restore_needed = bool(flm.get("restoreNeeded", False))
    emergency = bool(flm.get("emergency", False))

    if active:
        proposal = proposals.get(active)
        if proposal is None or proposal.get("state") != "EVALUATING":
            raise KeeperError("active evaluation does not match proposal state")
        if not proposal.get("futarchyProposal"):
            payload = proposal.get("evaluationPayload")
            if payload is not None:
                return Action(
                    "startEvaluation",
                    evaluator,
                    _start_evaluation(active, payload),
                    active,
                )
        elif sync_ready and not emergency:
            return Action("flmSync", manager, "0x" + SELECTORS["sync"], active)
        elif proposal.get("resolutionReady"):
            return Action("resolve", evaluator, _one_uint("resolve", active), active)
    elif sync_ready and not emergency:
        # Restore the settled conditional market before admitting the next evaluation.
        return Action("flmSync", manager, "0x" + SELECTORS["sync"])

    if not active and queue:
        return Action(
            "startNextEvaluation", arbitration, "0x" + SELECTORS["startNextEvaluation"], queue[0]
        )

    for proposal_id in sorted(proposals):
        proposal = proposals[proposal_id]
        if proposal.get("state") in ("YES", "NO") and not proposal.get("settled", False):
            changed = int(proposal.get("lastStateChangeAt", -1))
            if changed >= 0 and now >= changed + timeout:
                return Action(
                    "finalizeByTimeout",
                    arbitration,
                    _one_uint("finalizeByTimeout", proposal_id),
                    proposal_id,
                )

    occupied = len(queue) + (1 if active else 0)
    if occupied < MAX_QUEUE:
        threshold = base_x * (1 << len(queue))
        for proposal_id in sorted(proposals):
            proposal = proposals[proposal_id]
            if (
                proposal.get("state") == "YES"
                and int(proposal.get("noBondAmount", 0)) > 0
                and int(proposal.get("yesBondAmount", 0)) >= threshold
            ):
                return Action(
                    "tryGraduate",
                    arbitration,
                    _one_uint("tryGraduate", proposal_id),
                    proposal_id,
                )

    if restore_needed and not emergency:
        return Action("flmRestore", manager, "0x" + SELECTORS["restoreLiquidity"])
    return None
