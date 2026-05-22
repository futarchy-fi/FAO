# Phase-5 live metrics (polling-only mode)

This file is auto-updated by `script/agents/poll_metrics.sh` running
against the deployed Sepolia stack. Polling-only mode does not broadcast
any transaction; it observes chain state continuously.

**Started:** 2026-05-20T15:16:55Z
**Current:** 2026-05-21T01:15:34Z
**Elapsed:** 9h 58m
**Target:** 10h
**Iterations:** 291
**Poll interval:** 120s

## Latest snapshot

| Metric | Value |
|--------|-------|
| Block number | 10888920 |
| Operator wallet balance (wei) | 1542029476203143 |
| Factory marketsCount | 6 |

## Notes

- Polling-only mode runs continuously without spending operator ETH.
- The deployed stack remains accessible at addresses in `docs/sepolia-deployment-v0.md`.
- For broadcast-mode agent loops, see `script/agents/run_phase5.sh` (requires top-up).

Raw CSV: `out/phase5-metrics.csv` (291 rows)
## Run complete at 2026-05-21T03:08:13Z after 5 cycles

See out/phase5-events.log for the full event stream.
