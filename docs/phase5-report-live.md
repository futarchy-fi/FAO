# Phase-5 live metrics (polling-only mode)

This file is auto-updated by `script/agents/poll_metrics.sh` running
against the deployed Sepolia stack. Polling-only mode does not broadcast
any transaction; it observes chain state continuously.

**Started:** 2026-05-20T15:16:55Z
**Current:** 2026-05-20T15:16:55Z
**Elapsed:** 0h 0m
**Target:** 10h
**Iterations:** 1
**Poll interval:** 120s

## Latest snapshot

| Metric | Value |
|--------|-------|
| Block number | 10886353 |
| Operator wallet balance (wei) | 368445166931044 |
| Factory marketsCount | 1 |

## Notes

- Polling-only mode runs continuously without spending operator ETH.
- The deployed stack remains accessible at addresses in `docs/sepolia-deployment-v0.md`.
- For broadcast-mode agent loops, see `script/agents/run_phase5.sh` (requires top-up).

Raw CSV: `out/phase5-metrics.csv` (1 rows)
