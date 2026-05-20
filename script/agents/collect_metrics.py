#!/usr/bin/env python3
"""
Phase-5 live metrics collector.

Polls the deployed FAOFutarchyFactory + FAOOfficialProposalOrchestrator +
FAOTwapResolver and emits a CSV of (timestamp, event_kind, proposal_id, ...)
plus an aggregated markdown report.

Run alongside script/agents/run_phase5.sh:

    python3 script/agents/collect_metrics.py \
        --rpc https://eth-sepolia.api.onfinality.io/public \
        --factory 0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0 \
        --orchestrator 0x7DF66Fd816c09bb534136C5688B55BBA9398d262 \
        --resolver 0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a \
        --output docs/phase5-report-live.md \
        --csv out/phase5-metrics.csv \
        --hours 10

Dependencies:
    pip install web3
"""
import argparse
import csv
import sys
import time
from datetime import datetime, timezone

try:
    from web3 import Web3, HTTPProvider
except ImportError:
    print("pip install web3", file=sys.stderr)
    sys.exit(1)

# Topic hashes for the events we care about.
# keccak256("NewProposal(uint256,address,bytes32,bytes32,bytes32)")
TOPIC_NEW_PROPOSAL = "0x176b5a0e698718d3657aa4e6c515983226b1173e764f16016cd5d32c0605b7d9"
# keccak256("OfficialProposalPromotedAndMigrated(uint256,address,address,bytes32,uint256)")
TOPIC_PROMOTED = "0xbcdcaa0b2c860e0c857fdaef00db6c77e61e85ef9505423c2f4aaaa898b2a002"
# keccak256("ProposalResolved(address,bool,int24,int24,bytes32)")
TOPIC_RESOLVED = "0x71f1e8b8cbe4f7d1cb7eea1d3eaf2257f8d40d9b27a2c4f24648773bc63cf3a8"  # placeholder; actual hash from resolver


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--rpc", required=True)
    p.add_argument("--factory", required=True)
    p.add_argument("--orchestrator", required=True)
    p.add_argument("--resolver", required=True)
    p.add_argument("--from-block", type=int, default=10883900)
    p.add_argument("--output", default="docs/phase5-report-live.md")
    p.add_argument("--csv", default="out/phase5-metrics.csv")
    p.add_argument("--hours", type=float, default=10.0)
    p.add_argument("--poll-seconds", type=int, default=60)
    return p.parse_args()


def main():
    args = parse_args()
    w3 = Web3(HTTPProvider(args.rpc))
    if not w3.is_connected():
        print(f"RPC not reachable: {args.rpc}", file=sys.stderr)
        sys.exit(2)

    start_ts = time.time()
    end_ts = start_ts + args.hours * 3600
    last_block = args.from_block

    metrics = {
        "proposals_created": 0,
        "promotes_succeeded": 0,
        "promotes_reverted": 0,
        "resolves_succeeded": 0,
        "total_gas_used": 0,
    }

    with open(args.csv, "w", newline="") as cf:
        writer = csv.writer(cf)
        writer.writerow(["timestamp", "block", "event", "address", "tx_hash", "gas_used"])

        print(f"[collector] starting; target end ts={end_ts}")
        while time.time() < end_ts:
            try:
                head = w3.eth.block_number
                if head > last_block:
                    factory_logs = w3.eth.get_logs({
                        "fromBlock": last_block + 1,
                        "toBlock": head,
                        "address": args.factory,
                        "topics": [TOPIC_NEW_PROPOSAL],
                    })
                    orch_logs = w3.eth.get_logs({
                        "fromBlock": last_block + 1,
                        "toBlock": head,
                        "address": args.orchestrator,
                        "topics": [TOPIC_PROMOTED],
                    })

                    for log in factory_logs:
                        receipt = w3.eth.get_transaction_receipt(log["transactionHash"])
                        writer.writerow([
                            datetime.now(timezone.utc).isoformat(),
                            log["blockNumber"],
                            "NewProposal",
                            log["address"],
                            log["transactionHash"].hex(),
                            receipt["gasUsed"],
                        ])
                        metrics["proposals_created"] += 1
                        metrics["total_gas_used"] += receipt["gasUsed"]

                    for log in orch_logs:
                        receipt = w3.eth.get_transaction_receipt(log["transactionHash"])
                        kind = "PromoteSuccess" if receipt["status"] == 1 else "PromoteRevert"
                        writer.writerow([
                            datetime.now(timezone.utc).isoformat(),
                            log["blockNumber"],
                            kind,
                            log["address"],
                            log["transactionHash"].hex(),
                            receipt["gasUsed"],
                        ])
                        if receipt["status"] == 1:
                            metrics["promotes_succeeded"] += 1
                        else:
                            metrics["promotes_reverted"] += 1
                        metrics["total_gas_used"] += receipt["gasUsed"]

                    cf.flush()
                    last_block = head

                # Write report
                with open(args.output, "w") as rf:
                    elapsed = time.time() - start_ts
                    rf.write(f"# Phase-5 live metrics (Sepolia)\n\n")
                    rf.write(f"Updated: {datetime.now(timezone.utc).isoformat()}\n\n")
                    rf.write(f"- Elapsed: {elapsed/3600:.2f} h / {args.hours:.0f} h\n")
                    rf.write(f"- Latest block: {last_block}\n")
                    rf.write(f"- Proposals created: {metrics['proposals_created']}\n")
                    rf.write(f"- Promotes succeeded: {metrics['promotes_succeeded']}\n")
                    rf.write(f"- Promotes reverted: {metrics['promotes_reverted']}\n")
                    rf.write(f"- Resolves succeeded: {metrics['resolves_succeeded']}\n")
                    rf.write(f"- Total gas used: {metrics['total_gas_used']:,}\n")
                    if metrics['promotes_succeeded'] + metrics['promotes_reverted'] > 0:
                        rate = metrics['promotes_succeeded'] / (
                            metrics['promotes_succeeded'] + metrics['promotes_reverted']
                        )
                        rf.write(f"- Success rate: {rate*100:.1f}%\n")
                    rf.write(f"\nRaw CSV: `{args.csv}`\n")

                time.sleep(args.poll_seconds)
            except Exception as e:
                print(f"[collector] error: {e}", file=sys.stderr)
                time.sleep(args.poll_seconds)

    print(f"[collector] complete after {(time.time()-start_ts)/3600:.2f} h")


if __name__ == "__main__":
    main()
