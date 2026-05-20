# Phase-5 live metrics (polling-only mode)

This file is auto-updated by `script/agents/poll_metrics.sh` running
against the deployed Sepolia stack. Polling-only mode does not broadcast
any transaction; it observes chain state continuously.

**Started:** 2026-05-20T15:16:55Z
**Current:** 2026-05-20T23:52:59Z
**Elapsed:** 8h 36m
**Target:** 10h
**Iterations:** 251
**Poll interval:** 120s

## Latest snapshot

| Metric | Value |
|--------|-------|
| Block number | 10888556 |
| Operator wallet balance (wei) | 27130220892304748 |
| Factory marketsCount | 5 |

## Notes

- Polling-only mode runs continuously without spending operator ETH.
- The deployed stack remains accessible at addresses in `docs/sepolia-deployment-v0.md`.
- For broadcast-mode agent loops, see `script/agents/run_phase5.sh` (requires top-up).

Raw CSV: `out/phase5-metrics.csv` (251 rows)
