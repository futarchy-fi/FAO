"""Versioned funding manifest validation and in-memory cap accounting."""

from __future__ import annotations

import re
from typing import Any, Dict, Optional, Tuple

from .schema import SchemaError, address


REQUIRED_ROLES = {"deployer", "proposer", "challenger", "marketMaker", "keeper"}


class FundingError(ValueError):
    pass


def _address(value: Any, label: str) -> str:
    try:
        return address(value, label)
    except SchemaError as exc:
        raise FundingError(str(exc)) from exc


def _record(value: Any, required: set, label: str) -> Dict[str, Any]:
    if not isinstance(value, dict) or set(value) != required:
        raise FundingError("%s has invalid fields" % label)
    return value


def _decimal(value: Any, label: str, positive: bool = False) -> int:
    if not isinstance(value, str) or not re.fullmatch(r"0|[1-9][0-9]*", value):
        raise FundingError("%s must be a canonical decimal string" % label)
    number = int(value)
    if number >= 1 << 256 or (positive and number == 0):
        raise FundingError("%s is out of range" % label)
    return number


def validate_funding_manifest(value: Any) -> Dict[str, Any]:
    raw = _record(
        value,
        {"v", "kind", "chainId", "runId", "runCapWei", "roles", "instances"},
        "manifest",
    )
    if raw["v"] != 1 or raw["kind"] != "fao.windtunnel.funding":
        raise FundingError("unsupported funding manifest version or kind")
    chain_id = _decimal(raw["chainId"], "chainId", True)
    run_cap = _decimal(raw["runCapWei"], "runCapWei", True)
    if not isinstance(raw["runId"], str) or not raw["runId"]:
        raise FundingError("runId must be nonempty")
    if not isinstance(raw["roles"], list) or not raw["roles"]:
        raise FundingError("roles must be nonempty")

    roles = []
    role_names = set()
    role_addresses = set()
    for index, value_ in enumerate(raw["roles"]):
        role = _record(value_, {"role", "address", "ephemeral", "capWei"}, "role")
        name = role["role"]
        if name not in REQUIRED_ROLES or name in role_names:
            raise FundingError("role names must be unique canonical roles")
        account = _address(role["address"], "role.address")
        if account == "0x" + "00" * 20 or account in role_addresses:
            raise FundingError("role addresses must be nonzero and separated")
        if role["ephemeral"] is not True:
            raise FundingError("every funding wallet must be ephemeral")
        cap = _decimal(role["capWei"], "role.capWei", True)
        if cap > run_cap:
            raise FundingError("role cap exceeds run cap")
        roles.append({"role": name, "address": account, "ephemeral": True, "capWei": str(cap)})
        role_names.add(name)
        role_addresses.add(account)
    if role_names != REQUIRED_ROLES:
        raise FundingError("all separated funding roles are required")

    if not isinstance(raw["instances"], list) or not raw["instances"]:
        raise FundingError("instances must be nonempty")
    instances = []
    receipts = set()
    for value_ in raw["instances"]:
        instance = _record(value_, {"receipt", "capWei", "markets"}, "instance")
        receipt = _address(instance["receipt"], "instance.receipt")
        if receipt == "0x" + "00" * 20 or receipt in receipts:
            raise FundingError("instance receipts must be unique and nonzero")
        cap = _decimal(instance["capWei"], "instance.capWei", True)
        if cap > run_cap:
            raise FundingError("instance cap exceeds run cap")
        if not isinstance(instance["markets"], list):
            raise FundingError("instance.markets must be an array")
        markets = []
        proposal_ids = set()
        for market_ in instance["markets"]:
            market = _record(market_, {"proposalId", "capWei"}, "market")
            proposal_id = _decimal(market["proposalId"], "market.proposalId", True)
            market_cap = _decimal(market["capWei"], "market.capWei", True)
            if proposal_id in proposal_ids or market_cap > cap:
                raise FundingError("market ids must be unique and caps cannot exceed instance cap")
            markets.append({"proposalId": str(proposal_id), "capWei": str(market_cap)})
            proposal_ids.add(proposal_id)
        instances.append({"receipt": receipt, "capWei": str(cap), "markets": markets})
        receipts.add(receipt)

    return {
        "v": 1,
        "kind": "fao.windtunnel.funding",
        "chainId": str(chain_id),
        "runId": raw["runId"],
        "runCapWei": str(run_cap),
        "roles": roles,
        "instances": instances,
    }


class FundingBudget:
    """Applies hierarchical caps atomically; it never handles wallets or keys."""

    def __init__(self, manifest: Any) -> None:
        self.manifest = validate_funding_manifest(manifest)
        self.run_spent = 0
        self.role_spent: Dict[str, int] = {}
        self.instance_spent: Dict[str, int] = {}
        self.market_spent: Dict[Tuple[str, str], int] = {}

    def spend(
        self, role: str, receipt: str, amount_wei: int, proposal_id: Optional[str] = None
    ) -> None:
        if not isinstance(amount_wei, int) or amount_wei <= 0:
            raise FundingError("spend amount must be a positive integer")
        receipt = _address(receipt, "receipt")
        role_caps = {item["role"]: int(item["capWei"]) for item in self.manifest["roles"]}
        instance_caps = {
            item["receipt"]: int(item["capWei"]) for item in self.manifest["instances"]
        }
        if role not in role_caps or receipt not in instance_caps:
            raise FundingError("unknown funding scope")
        checks = [
            ("run", self.run_spent, int(self.manifest["runCapWei"])),
            ("role", self.role_spent.get(role, 0), role_caps[role]),
            ("instance", self.instance_spent.get(receipt, 0), instance_caps[receipt]),
        ]
        market_key = None
        if proposal_id is not None:
            proposal = str(_decimal(proposal_id, "proposalId", True))
            market_key = (receipt, proposal)
            market_caps = {
                (item["receipt"], market["proposalId"]): int(market["capWei"])
                for item in self.manifest["instances"]
                for market in item["markets"]
            }
            if market_key not in market_caps:
                raise FundingError("unknown market funding scope")
            checks.append(
                ("market", self.market_spent.get(market_key, 0), market_caps[market_key])
            )
        for label, spent, cap in checks:
            if spent + amount_wei > cap:
                raise FundingError("%s funding cap exhausted" % label)
        self.run_spent += amount_wei
        self.role_spent[role] = self.role_spent.get(role, 0) + amount_wei
        self.instance_spent[receipt] = self.instance_spent.get(receipt, 0) + amount_wei
        if market_key is not None:
            self.market_spent[market_key] = self.market_spent.get(market_key, 0) + amount_wei
