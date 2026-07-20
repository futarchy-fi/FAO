#!/usr/bin/env python3
"""Reduce synthetic FAO watcher events into provenance and TTFC telemetry.

This entry point is intentionally fixture-only.  It has no RPC, key, signing,
or transaction code; a live adapter belongs to the separately authorized
launch lane.
"""

from __future__ import annotations

import argparse
import json
import math
from copy import deepcopy
from datetime import datetime, timezone
from pathlib import Path


SCHEMA = "fao.house-watcher.v1"
KINDS = {
    "proposal_seen",
    "yes_activated",
    "inspection",
    "challenge_submitted",
    "challenge_confirmed",
    "challenge_observed",
    "settled",
    "adjudicated",
    "run_started",
    "heartbeat",
    "poker_settled",
}
COST_FIELDS = (
    "inference_cost_raw",
    "attention_cost_raw",
    "rpc_cost_raw",
    "quoted_token_cost_raw",
)


def load_json(path: Path):
    return json.loads(path.read_text())


def load_jsonl(path: Path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def _canonicalize(events):
    canonical = {}
    duplicates = replacements = 0
    for event in events:
        if event.get("schema") != SCHEMA:
            raise ValueError(f"unsupported schema: {event.get('schema')!r}")
        if event.get("kind") not in KINDS:
            raise ValueError(f"unsupported event kind: {event.get('kind')!r}")
        event_id = event.get("event_id")
        if not event_id:
            raise ValueError("event_id is required")
        chain = event.get("chain", {})
        if "block_number" not in chain or "event_at" not in chain:
            raise ValueError(f"chain block_number and event_at are required: {event_id}")
        prior = canonical.get(event_id)
        if prior == event:
            duplicates += 1
        elif prior is not None:
            replacements += 1
        canonical[event_id] = deepcopy(event)
    rows = sorted(
        canonical.values(),
        key=lambda event: (
            int(event.get("chain", {}).get("block_number", 0)),
            int(event.get("chain", {}).get("log_index", 0)),
            int(event.get("chain", {}).get("event_at", 0)),
            event["event_id"],
        ),
    )
    return rows, duplicates, replacements


def _address(value):
    return str(value or "").lower()


def actor_class(config, event):
    block = int(event.get("chain", {}).get("block_number", 0))
    bidder = _address(event.get("data", {}).get("bidder") or event.get("provenance", {}).get("actor_address"))
    for epoch in config.get("house_epochs", []):
        start = int(epoch.get("effective_from_block", 0))
        end = epoch.get("effective_to_block")
        if bidder == _address(epoch["address"]) and block >= start and (end is None or block <= int(end)):
            return "house"
    return "external"


def _nearest_rank(values, percentile):
    if not values:
        return None
    ordered = sorted(values)
    return ordered[max(0, math.ceil(percentile * len(ordered)) - 1)]


def _distribution(values, *, stringify=False):
    cooked = [int(value) for value in values]
    result = {
        "count": len(cooked),
        "p50": _nearest_rank(cooked, 0.50),
        "p90": _nearest_rank(cooked, 0.90),
        "p95": _nearest_rank(cooked, 0.95),
    }
    if stringify:
        for key in ("p50", "p90", "p95"):
            if result[key] is not None:
                result[key] = str(result[key])
    return result


def _rate(numerator, denominator):
    return {
        "numerator": numerator,
        "denominator": denominator,
        "rate_bps": None if not denominator else numerator * 10_000 // denominator,
    }


def evaluate_health(config, heartbeat, proposals):
    reasons = []
    if config.get("mode") != "fixture":
        reasons.append("unsupported_mode")
    else:
        reasons.append("fixture_only")
    if not heartbeat:
        return sorted(set(reasons + ["missing_heartbeat"]))

    data = heartbeat.get("data", {})
    manifest = config.get("manifest", {})
    checks = (
        (data.get("observed_chain_id") != manifest.get("chain_id"), "chain_id_mismatch"),
        (_address(data.get("arbitration_address")) != _address(manifest.get("arbitration_address")), "arbitration_address_mismatch"),
        (_address(data.get("runtime_codehash")) != _address(manifest.get("runtime_codehash")), "runtime_codehash_mismatch"),
        (data.get("config_digest") != config.get("config_digest"), "config_digest_mismatch"),
        (data.get("deploy_parity") != "PASS", "deploy_parity_not_pass"),
        (int(data.get("heartbeat_age_s", 10**18)) > int(config.get("max_heartbeat_age_s", 0)), "stale_heartbeat"),
        (int(data.get("finalized_lag_blocks", 10**18)) > int(config.get("max_finalized_lag_blocks", 0)), "excessive_finalized_lag"),
        (int(data.get("signer_balance_raw", 0)) < int(config.get("min_signer_balance_raw", 0)), "insufficient_signer_balance"),
        (int(data.get("signer_allowance_raw", 0)) < int(config.get("min_signer_allowance_raw", 0)), "insufficient_signer_allowance"),
    )
    reasons.extend(reason for failed, reason in checks if failed)
    if any(proposal.get("content_digest_status") != "valid" for proposal in proposals.values()):
        reasons.append("missing_content_digest")
    return sorted(set(reasons))


def _proposal(event, proposals):
    proposal_id = str(event.get("proposal", {}).get("arbitration_id") or "")
    if not proposal_id:
        return None
    return proposals.setdefault(
        proposal_id,
        {
            "arbitration_id": proposal_id,
            "origin": event.get("proposal", {}).get("origin", "unknown"),
            "t_created": None,
            "t_eligible": None,
            "timeout_s": None,
            "content_digest_status": "unknown",
            "chain_id": event.get("chain", {}).get("chain_id"),
            "arbitration_address": event.get("contracts", {}).get("arbitration"),
            "config_digest": event.get("provenance", {}).get("config_digest"),
            "min_activation_bond_raw": None,
            "tier_id": None,
            "first_house_no": None,
            "first_external_no": None,
            "inspections": [],
            "attempts": [],
            "failures": [],
            "settled": None,
            "adjudication": None,
            "event_ids": [],
        },
    )


def _finalize_proposal(proposal, generated_at):
    any_times = [
        ("house", proposal["first_house_no"]),
        ("external", proposal["first_external_no"]),
    ]
    any_times = [(source, value) for source, value in any_times if value is not None]
    source, first_any = min(any_times, key=lambda item: item[1]) if any_times else (None, None)
    deadline = None
    if proposal["t_eligible"] is not None and proposal["timeout_s"] is not None:
        deadline = proposal["t_eligible"] + proposal["timeout_s"]
    settled_at = (proposal["settled"] or {}).get("event_at")
    censor_at = settled_at if settled_at is not None else generated_at
    if deadline is not None:
        censor_at = min(censor_at, deadline)
    exposure = None if proposal["t_eligible"] is None else max(0, censor_at - proposal["t_eligible"])

    def delta(value, base):
        return None if value is None or base is None else value - base

    return {
        "arbitration_id": proposal["arbitration_id"],
        "origin": proposal["origin"],
        "content_digest_status": proposal["content_digest_status"],
        "chain_id": proposal["chain_id"],
        "arbitration_address": proposal["arbitration_address"],
        "config_digest": proposal["config_digest"],
        "min_activation_bond_raw": proposal["min_activation_bond_raw"],
        "tier_id": proposal["tier_id"],
        "t_created": proposal["t_created"],
        "t_eligible": proposal["t_eligible"],
        "deadline": deadline,
        "t_first_house_no": proposal["first_house_no"],
        "t_first_external_no": proposal["first_external_no"],
        "first_any_source": source,
        "ttfc_created_s": {
            "house": delta(proposal["first_house_no"], proposal["t_created"]),
            "external": delta(proposal["first_external_no"], proposal["t_created"]),
            "any": delta(first_any, proposal["t_created"]),
        },
        "ttfc_eligible_s": {
            "house": delta(proposal["first_house_no"], proposal["t_eligible"]),
            "external": delta(proposal["first_external_no"], proposal["t_eligible"]),
            "any": delta(first_any, proposal["t_eligible"]),
        },
        "censored": first_any is None,
        "censor_status": None if first_any is not None else ((proposal["settled"] or {}).get("route") or "live"),
        "eligible_exposure_s": None if first_any is not None else exposure,
        "inspection_count": len(proposal["inspections"]),
        "inspections": [
            {
                "event_id": item["event_id"],
                "event_at": item["event_at"],
                "predicted_quality": item.get("predicted_quality"),
                "cost_complete": all(item.get(field) is not None for field in COST_FIELDS),
            }
            for item in proposal["inspections"]
        ],
        "challenge_failures": proposal["failures"],
        "settled": proposal["settled"],
        "adjudication": proposal["adjudication"],
        "event_ids": proposal["event_ids"],
    }


def build_snapshot(config, events):
    if config.get("mode") != "fixture":
        raise ValueError("house_watcher.py is fixture-only")
    required_config = (
        "generated_at",
        "source_commit",
        "config_digest",
        "house_epochs",
        "manifest",
        "max_heartbeat_age_s",
        "max_finalized_lag_blocks",
        "min_signer_balance_raw",
        "min_signer_allowance_raw",
        "minimum_adjudicated_organic",
    )
    missing_config = [field for field in required_config if field not in config]
    if missing_config:
        raise ValueError(f"missing explicit fixture config: {', '.join(missing_config)}")
    canonical, duplicate_count, replacement_count = _canonicalize(events)
    proposals = {}
    heartbeats = []
    poker_rows = []
    alerts = []

    for event in canonical:
        kind = event.get("kind")
        data = event.get("data", {})
        chain = event.get("chain", {})
        event_at = int(chain.get("event_at", 0))
        if kind in {"run_started", "heartbeat"}:
            heartbeats.append(event)
            continue
        if kind == "poker_settled":
            poker_rows.append(event)
            continue
        proposal = _proposal(event, proposals)
        if proposal is None:
            continue
        proposal["event_ids"].append(event["event_id"])
        proposal["origin"] = event.get("proposal", {}).get("origin", proposal["origin"])

        if kind == "proposal_seen":
            proposal["t_created"] = min(filter(lambda value: value is not None, (proposal["t_created"], event_at))) if proposal["t_created"] is not None else event_at
            proposal["timeout_s"] = int(data["timeout_s"])
            proposal["content_digest_status"] = data.get("content_digest_status", "unknown")
            proposal["chain_id"] = chain.get("chain_id", config["manifest"]["chain_id"])
            proposal["arbitration_address"] = event.get("contracts", {}).get("arbitration", config["manifest"]["arbitration_address"])
            proposal["config_digest"] = event.get("provenance", {}).get("config_digest", config["config_digest"])
            proposal["min_activation_bond_raw"] = data.get("min_activation_bond_raw")
            proposal["tier_id"] = data.get("tier_id")
        elif kind == "yes_activated":
            proposal["t_eligible"] = min(filter(lambda value: value is not None, (proposal["t_eligible"], event_at))) if proposal["t_eligible"] is not None else event_at
        elif kind == "inspection":
            proposal["inspections"].append({"event_id": event["event_id"], "event_at": event_at, **data})
        elif kind == "challenge_observed":
            klass = actor_class(config, event)
            key = "first_house_no" if klass == "house" else "first_external_no"
            proposal[key] = event_at if proposal[key] is None else min(proposal[key], event_at)
        elif kind == "challenge_submitted":
            decision_id = data.get("decision_id")
            if any(attempt.get("decision_id") == decision_id for attempt in proposal["attempts"]):
                alerts.append({"kind": "blind_retry", "arbitration_id": proposal["arbitration_id"], "decision_id": decision_id})
            proposal["attempts"].append(data)
        elif kind == "challenge_confirmed" and data.get("receipt_status") != "success":
            failure = {
                "event_id": event["event_id"],
                "decision_id": data.get("decision_id"),
                "error_class": data.get("error_class", "unknown"),
                "event_at": event_at,
                "retry_allowed": False,
            }
            proposal["failures"].append(failure)
            alerts.append({"kind": "challenge_failure", "arbitration_id": proposal["arbitration_id"], **failure})
        elif kind == "settled":
            proposal["settled"] = {"event_at": event_at, **data}
        elif kind == "adjudicated":
            proposal["adjudication"] = {"event_at": event_at, **data}

    generated_at = int(config["generated_at"])
    rows = [_finalize_proposal(proposal, generated_at) for proposal in proposals.values()]
    rows.sort(key=lambda row: row["arbitration_id"])

    def observed(metric, source, cohort=rows):
        return [row[metric][source] for row in cohort if row[metric][source] is not None]

    def ttfc_cohort(cohort):
        first = [row for row in cohort if row["first_any_source"]]
        censored_rows = [row for row in cohort if row["censored"]]
        return {
            "proposal_count": len(cohort),
            "observed_count": len(first),
            "censored_count": len(censored_rows),
            "censor_rate": _rate(len(censored_rows), len(cohort)),
            "created_s": {source: _distribution(observed("ttfc_created_s", source, cohort)) for source in ("house", "external", "any")},
            "eligible_s": {source: _distribution(observed("ttfc_eligible_s", source, cohort)) for source in ("house", "external", "any")},
            "first_source_counts": {
                "house": sum(row["first_any_source"] == "house" for row in cohort),
                "external": sum(row["first_any_source"] == "external" for row in cohort),
            },
        }

    first_sources = [row["first_any_source"] for row in rows if row["first_any_source"]]
    organic_observed = [row for row in rows if row["origin"] == "organic" and row["first_any_source"]]
    censored = [row for row in rows if row["censored"]]

    complete_costs = []
    organic_costs = []
    incomplete_cost_count = 0
    confusion = {"true_bad": 0, "false_bad": 0, "true_good": 0, "false_good": 0}
    adjudicated = []
    bad_slips = []
    for state, row in zip((proposals[item["arbitration_id"]] for item in rows), rows):
        for inspection in state["inspections"]:
            if all(inspection.get(field) is not None for field in COST_FIELDS):
                total = sum(int(inspection[field]) for field in COST_FIELDS)
                complete_costs.append(total)
                if row["origin"] == "organic":
                    organic_costs.append(total)
            else:
                incomplete_cost_count += 1
        label = (state["adjudication"] or {}).get("label")
        if row["origin"] != "organic" or label not in {"good", "bad"}:
            continue
        prediction = next((item.get("predicted_quality") for item in reversed(state["inspections"]) if item.get("predicted_quality") in {"good", "bad"}), None)
        adjudicated.append(label)
        if prediction:
            if prediction == "bad" and label == "bad":
                confusion["true_bad"] += 1
            elif prediction == "bad":
                confusion["false_bad"] += 1
            elif label == "good":
                confusion["true_good"] += 1
            else:
                confusion["false_good"] += 1
        if label == "bad" and row["censored"] and (row["settled"] or {}).get("route") == "timeout":
            bad_slips.append(row["arbitration_id"])

    poker = []
    knee = {"cheap": "0", "default": "0", "pricey": "50", "prohibitive": "100"}
    for event in poker_rows:
        data = event.get("data", {})
        required = (
            "regime",
            "participation_cost_raw",
            "stake_scale_raw",
            "entrant_count",
            "informed",
            "realized_informed_pnl_raw",
            "efficiency_bps",
            "subsidy_configured_raw",
            "subsidy_paid_raw",
            "funding_source_balance_raw",
        )
        complete = all(data.get(field) is not None for field in required)
        poker.append(
            {
                "event_id": event["event_id"],
                "regime": data.get("regime", "unknown"),
                "complete": complete,
                "knee_a_recommendation": knee.get(data.get("regime"), "UNKNOWN") if complete else "UNKNOWN",
                "funding_source_balance_raw": data.get("funding_source_balance_raw"),
                "realized_informed_pnl_raw": data.get("realized_informed_pnl_raw"),
                "participation_cost_raw": data.get("participation_cost_raw"),
                "stake_scale_raw": data.get("stake_scale_raw"),
                "entrant_count": data.get("entrant_count"),
                "informed": data.get("informed"),
                "efficiency_bps": data.get("efficiency_bps"),
                "subsidy_configured_raw": data.get("subsidy_configured_raw"),
                "subsidy_paid_raw": data.get("subsidy_paid_raw"),
            }
        )

    heartbeat = max(heartbeats, key=lambda item: int(item.get("chain", {}).get("event_at", 0)), default=None)
    health_reasons = evaluate_health(config, heartbeat, proposals)
    sample_min = int(config.get("minimum_adjudicated_organic", 0))
    gate_reasons = list(health_reasons)
    if len(adjudicated) < sample_min:
        gate_reasons.append("insufficient_adjudicated_organic_samples")
    if any(not row["complete"] for row in poker) or not poker:
        gate_reasons.append("missing_poker_regime_or_funding")
    if incomplete_cost_count:
        gate_reasons.append("incomplete_cost_inputs")
    if alerts:
        gate_reasons.append("challenge_failure_or_retry")
    if bad_slips:
        gate_reasons.append("bad_timeout_slip")
    gate_reasons.append("no_authorized_testnet_e2e")

    bad_count = sum(label == "bad" for label in adjudicated)
    correct = confusion["true_bad"] + confusion["true_good"]
    predicted = sum(confusion.values())
    beta = _rate(bad_count, len(adjudicated))
    beta["sample_status"] = "sufficient" if len(adjudicated) >= sample_min else "UNKNOWN"
    classifier_accuracy = _rate(correct, predicted)
    classifier_accuracy["sample_status"] = "sufficient" if len(adjudicated) >= sample_min else "UNKNOWN"
    heartbeat_data = (heartbeat or {}).get("data", {})
    inspection_times = [item["event_at"] for state in proposals.values() for item in state["inspections"]]
    house_challenge_times = [state["first_house_no"] for state in proposals.values() if state["first_house_no"] is not None]
    return {
        "schema": "fao.house-watcher.snapshot.v1",
        "generated_at": datetime.fromtimestamp(generated_at, timezone.utc).isoformat().replace("+00:00", "Z"),
        "mode": "fixture",
        "source": {
            "input_events": len(events),
            "canonical_events": len(canonical),
            "duplicate_events_ignored": duplicate_count,
            "reorg_replacements": replacement_count,
            "checkpoint_rewinds": int(replacement_count > 0),
            "checkpoint_block": heartbeat_data.get("checkpoint_block"),
            "source_commit": config.get("source_commit"),
            "config_digest": config.get("config_digest"),
        },
        "health": {
            "ready": not gate_reasons,
            "signing_enabled": False,
            "reasons": sorted(set(gate_reasons)),
            "heartbeat_event_id": heartbeat.get("event_id") if heartbeat else None,
            "telemetry": {
                "manifest_id": heartbeat_data.get("manifest_id"),
                "run_id": heartbeat_data.get("run_id"),
                "watcher_version": heartbeat_data.get("watcher_version"),
                "classifier_version": heartbeat_data.get("classifier_version"),
                "deploy_parity": heartbeat_data.get("deploy_parity", "UNKNOWN"),
                "heartbeat_age_s": heartbeat_data.get("heartbeat_age_s"),
                "finalized_lag_blocks": heartbeat_data.get("finalized_lag_blocks"),
                "head_block": heartbeat_data.get("head_block"),
                "finalized_block": heartbeat_data.get("finalized_block"),
                "checkpoint_block": heartbeat_data.get("checkpoint_block"),
                "signer_balance_raw": heartbeat_data.get("signer_balance_raw"),
                "signer_allowance_raw": heartbeat_data.get("signer_allowance_raw"),
                "last_successful_inspect_at": max(inspection_times, default=None),
                "last_confirmed_house_challenge_at": max(house_challenge_times, default=None),
            },
        },
        "ttfc": {
            "proposal_count": len(rows),
            "observed_count": len(first_sources),
            "censored_count": len(censored),
            "censor_rate": _rate(len(censored), len(rows)),
            "created_s": {source: _distribution(observed("ttfc_created_s", source)) for source in ("house", "external", "any")},
            "eligible_s": {source: _distribution(observed("ttfc_eligible_s", source)) for source in ("house", "external", "any")},
            "first_source_counts": {"house": first_sources.count("house"), "external": first_sources.count("external")},
            "organic_external_first": sum(row["first_any_source"] == "external" for row in organic_observed),
            "synthetic_external_adoption": 0,
            "by_origin": {
                origin: ttfc_cohort([row for row in rows if row["origin"] == origin])
                for origin in ("organic", "synthetic", "seeded", "unknown")
            },
            "cohort_dimensions": [
                "origin",
                "config_digest",
                "chain_id",
                "arbitration_address",
                "min_activation_bond_raw",
                "tier_id",
            ],
        },
        "economics": {
            "cost_all_raw": _distribution(complete_costs, stringify=True),
            "cost_organic_raw": _distribution(organic_costs, stringify=True),
            "incomplete_cost_count": incomplete_cost_count,
            "beta_bad": beta,
            "classifier_q": {"confusion": confusion, "accuracy": classifier_accuracy},
            "reward_competition_s": _rate(sum(row["first_any_source"] == "external" for row in organic_observed), len(organic_observed)),
            "house_reliance": _rate(sum(row["first_any_source"] == "house" for row in organic_observed), len(organic_observed)),
            "bad_timeout_slips": bad_slips,
        },
        "poker": {"rows": poker, "ready": bool(poker) and all(row["complete"] for row in poker)},
        "alerts": alerts,
        "proposals": rows,
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--events", type=Path, required=True, help="synthetic JSONL fixture")
    parser.add_argument("--config", type=Path, required=True, help="fixture config JSON")
    parser.add_argument("--output", type=Path, help="snapshot path; stdout when omitted")
    args = parser.parse_args(argv)
    snapshot = build_snapshot(load_json(args.config), load_jsonl(args.events))
    text = json.dumps(snapshot, indent=2, sort_keys=True) + "\n"
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text)
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
