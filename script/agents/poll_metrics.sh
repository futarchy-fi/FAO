#!/usr/bin/env bash
# Phase-5 polling metrics collector.
#
# Runs cast queries against the deployed Sepolia stack every POLL_SECONDS,
# appending to out/phase5-metrics.csv. Continues until the file
# out/phase5.stop appears (touch to gracefully end), or for HOURS hours.
#
# Designed to run WITHOUT any operator ETH — purely reads chain state.
# This gives us live "metrics during the window" even when the wallet
# is empty.
set -u

: "${SEPOLIA_RPC:=https://eth-sepolia.api.onfinality.io/public}"
: "${FACTORY:=0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0}"
: "${ORCHESTRATOR:=0x7DF66Fd816c09bb534136C5688B55BBA9398d262}"
: "${RESOLVER:=0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a}"
: "${WALLET:=0x693E3FB46Bb36eE43C702FE94f9463df0691b43d}"
: "${POLL_SECONDS:=60}"
: "${HOURS:=10}"

OUT_DIR="out"
CSV="$OUT_DIR/phase5-metrics.csv"
REPORT="docs/phase5-report-live.md"
STOP_FILE="$OUT_DIR/phase5.stop"
mkdir -p "$OUT_DIR"

# CSV header if not exists.
if [ ! -f "$CSV" ]; then
  echo "timestamp,block_number,wallet_balance_wei,factory_markets_count,run_phase" > "$CSV"
fi

cast_call() {
  DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}" \
    docker run --rm --user root ghcr.io/foundry-rs/foundry:stable -c "$1" 2>/dev/null | head -1
}

start_ts=$(date +%s)
end_ts=$((start_ts + HOURS * 3600))
iter=0

while [ "$(date +%s)" -lt "$end_ts" ]; do
  if [ -f "$STOP_FILE" ]; then
    echo "stop file detected, exiting"
    break
  fi
  iter=$((iter + 1))

  ts=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
  block=$(cast_call "cast block-number --rpc-url $SEPOLIA_RPC")
  bal=$(cast_call "cast balance $WALLET --rpc-url $SEPOLIA_RPC")
  count=$(cast_call "cast call $FACTORY 'marketsCount()(uint256)' --rpc-url $SEPOLIA_RPC")

  echo "$ts,$block,$bal,$count,polling" >> "$CSV"

  # Update report.
  elapsed=$(( $(date +%s) - start_ts ))
  cat > "$REPORT" <<EOF
# Phase-5 live metrics (polling-only mode)

This file is auto-updated by \`script/agents/poll_metrics.sh\` running
against the deployed Sepolia stack. Polling-only mode does not broadcast
any transaction; it observes chain state continuously.

**Started:** $(date -u -d "@$start_ts" +'%Y-%m-%dT%H:%M:%SZ')
**Current:** $ts
**Elapsed:** $(( elapsed / 3600 ))h $(( (elapsed % 3600) / 60 ))m
**Target:** ${HOURS}h
**Iterations:** $iter
**Poll interval:** ${POLL_SECONDS}s

## Latest snapshot

| Metric | Value |
|--------|-------|
| Block number | $block |
| Operator wallet balance (wei) | $bal |
| Factory marketsCount | $count |

## Notes

- Polling-only mode runs continuously without spending operator ETH.
- The deployed stack remains accessible at addresses in \`docs/sepolia-deployment-v0.md\`.
- For broadcast-mode agent loops, see \`script/agents/run_phase5.sh\` (requires top-up).

Raw CSV: \`$CSV\` ($iter rows)
EOF

  sleep "$POLL_SECONDS"
done

echo "complete after $iter iterations, $(( $(date +%s) - start_ts ))s"
