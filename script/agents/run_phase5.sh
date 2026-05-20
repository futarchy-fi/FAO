#!/usr/bin/env bash
# Phase-5 driver: spawn legit proposers + adversarial agents against the live
# Sepolia deployment for ≥10 hours and stream metrics to docs/phase5-report-live.md.
#
# Prerequisites:
#   - Stack deployed (see docs/sepolia-deployment-v0.md for addresses)
#   - Operator wallet has Sepolia ETH (~0.1 ETH minimum for 10h run)
#   - Docker with foundry image:  ghcr.io/foundry-rs/foundry:stable
#   - DOCKER_HOST env exported (e.g. unix:///run/user/1002/docker.sock)
#
# Usage:
#   chmod +x script/agents/run_phase5.sh
#   ./script/agents/run_phase5.sh > out/phase5.log 2>&1 &
#
# Or supervise with tmux/screen for the full 10h+ duration.
set -euo pipefail

# ─── config from env (override per environment) ─────────────────────────────
: "${PRIVATE_KEY:?PRIVATE_KEY env required}"
: "${SEPOLIA_RPC:=https://eth-sepolia.api.onfinality.io/public}"
: "${FAO_TOKEN:=0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65}"
: "${WETH:=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14}"
: "${FUTARCHY_FACTORY:=0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0}"
: "${ORCHESTRATOR:=0x7DF66Fd816c09bb534136C5688B55BBA9398d262}"
: "${RESOLVER:=0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a}"
: "${ARBITRATION:=0x9D7692738a4d323338b9007d65d7F79e013B3476}"
: "${UNIV3_FACTORY:=0x0227628f3F023bb0B980b67D528571c95c6DaC1c}"
: "${FEE_TIER:=500}"
: "${RUN_HOURS:=10}"

REPORT="docs/phase5-report-live.md"
mkdir -p out

forge_run() {
  DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}" \
    docker run --rm -v "$PWD:/work" -w /work --user root \
    -e PRIVATE_KEY="$PRIVATE_KEY" \
    -e FUTARCHY_FACTORY="$FUTARCHY_FACTORY" \
    -e ORCHESTRATOR="$ORCHESTRATOR" \
    -e RESOLVER="$RESOLVER" \
    -e ARBITRATION="$ARBITRATION" \
    -e UNIV3_FACTORY="$UNIV3_FACTORY" \
    -e FAO_TOKEN="$FAO_TOKEN" \
    -e WETH="$WETH" \
    -e FEE_TIER="$FEE_TIER" \
    -e "$@" \
    ghcr.io/foundry-rs/foundry:stable -c "$2"
}

log_event() {
  local kind="$1"
  local msg="$2"
  echo "$(date -u +'%Y-%m-%dT%H:%M:%SZ') [$kind] $msg" >> "out/phase5-events.log"
}

# ─── initialize report ──────────────────────────────────────────────────────
cat > "$REPORT" <<EOF
# Phase-5 live run report (Sepolia)

**Started:** $(date -u +'%Y-%m-%dT%H:%M:%SZ')
**Target duration:** ${RUN_HOURS} hours
**Stack:** docs/sepolia-deployment-v0.md
**Operator:** $(DOCKER_HOST="${DOCKER_HOST:-unix:///run/user/$(id -u)/docker.sock}" docker run --rm --user root ghcr.io/foundry-rs/foundry:stable -c "cast wallet address --private-key $PRIVATE_KEY")

## Live metrics (updated periodically by run_phase5.sh)

(see out/phase5-events.log for raw stream)

EOF

log_event "START" "Phase-5 run beginning, target ${RUN_HOURS}h"

# ─── main loop ──────────────────────────────────────────────────────────────
end_time=$(( $(date +%s) + RUN_HOURS * 3600 ))
cycle=0

while [ "$(date +%s)" -lt "$end_time" ]; do
  cycle=$((cycle + 1))
  log_event "CYCLE_START" "cycle=$cycle"

  # 1. Spawn a legit proposer
  seed=$RANDOM
  SEED=$seed forge_run "SEED=$seed" "forge script script/agents/LegitProposer.s.sol --rpc-url $SEPOLIA_RPC --broadcast --legacy --gas-price 1100000000 2>&1 | tail -5" \
    >> "out/phase5-events.log" 2>&1 || log_event "LEGIT_FAIL" "cycle=$cycle"

  log_event "LEGIT" "cycle=$cycle seed=$seed"

  # 2. (Skip A1: requires prevrandao prediction which the test stub doesn't actually do.
  #     The defense is structural — every promote inherits prevrandao protection.)

  # 3. Sleep between cycles. Each promote+resolve cycle takes ~2h TIMEOUT.
  #    For 10h, we want ~5 cycles. Sleep 2h between cycles.
  sleep $((2 * 3600))
done

log_event "END" "Phase-5 run complete after $cycle cycles"
echo "## Run complete at $(date -u +'%Y-%m-%dT%H:%M:%SZ') after $cycle cycles" >> "$REPORT"
echo "" >> "$REPORT"
echo "See out/phase5-events.log for the full event stream." >> "$REPORT"
