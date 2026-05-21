#!/usr/bin/env bash
# auto_promote.sh — long-running operator daemon for FAO v0 Sepolia.
#
# Two concurrent loops drive the v0 lifecycle from "queued for eval" all the
# way to "CTF payouts reported":
#
#   1. PROMOTE loop (every 5 min)
#      Polls FutarchyArbitration for proposals in state QUEUED (graduated
#      into the eval queue) and, if any are present, calls
#      FAOOfficialProposalOrchestrator.createOfficialProposalAndMigrate(...)
#      to spin up a brand-new FAOFutarchyProposal + 2 UniV3 pools + bind
#      the resolver atomically.
#
#   2. RESOLVE loop (every 60 s)
#      Walks FAOFutarchyFactory.proposals(i) for every i in [0..marketsCount),
#      and for any proposal whose 2h TWAP window has expired
#      (isReadyToResolve == true) calls FAOTwapResolver.resolve(propAddr).
#
# All txs use `cast send` running inside the Foundry docker image — same
# invocation pattern as script/agents/run_phase5.sh.
#
# ─── KNOWN DESIGN GAP ──────────────────────────────────────────────────────
# The orchestrator's createOfficialProposalAndMigrate(...) builds a NEW
# FAOFutarchyProposal each call — it does NOT take an arbitration
# `proposalId` and therefore does NOT link the promoted proposal to the
# arbitration entry that triggered the promotion. The FutarchyEvaluator
# mapping `futarchyProposalOf[proposalId]` still has to be set by the
# owner separately (`setFutarchyProposal`) before `evaluator.resolve(id)`
# can settle the arbitration.
#
# A dedicated bridge contract is being added on a separate branch (see
# tasks list, item "Daemon: bundle submission via Flashbots multi-builder"
# and the bridge work described in the v0 design doc) that will accept
# `(arbId, marketName, description)` and atomically: (a) promote via the
# orchestrator, (b) call `evaluator.setFutarchyProposal(arbId, proposal)`.
# Until that ships, this daemon treats a non-empty arbitration queue as
# a generic "promote me" signal rather than a per-id link, which is the
# best we can do without owner-key access to the evaluator.
# ───────────────────────────────────────────────────────────────────────────
#
# Required env:
#   PRIVATE_KEY              operator EOA (must hold Sepolia ETH for gas)
#
# Optional env (with defaults):
#   SEPOLIA_RPC              default https://sepolia.drpc.org
#   FUTARCHY_FACTORY         default 0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0
#   ORCHESTRATOR             default 0x7DF66Fd816c09bb534136C5688B55BBA9398d262
#   RESOLVER                 default 0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a
#   ARBITRATION              default 0x9D7692738a4d323338b9007d65d7F79e013B3476
#   ARBITRATION_DEPLOY_BLOCK default 10880000   (lower bound for log scan)
#   PROMOTE_INTERVAL_SEC     default 300        (5 min)
#   RESOLVE_INTERVAL_SEC     default 60         (1 min)
#   LOG_SCAN_CHUNK_BLOCKS    default 5000       (cast logs chunk size)
#   RUN_HOURS                default 24
#   FOUNDRY_IMAGE            default ghcr.io/foundry-rs/foundry:stable
#   GAS_PRICE                default 1100000000 (1.1 gwei, --legacy)
#   PROMOTE_NAME_PREFIX      default "auto"
#
# Stop conditions:
#   - elapsed > RUN_HOURS, OR
#   - file out/auto_promote.stop exists
#
# Outputs:
#   out/auto_promote.log     all actions + cast output
#   out/auto_promote.pid     pid of the daemon (for supervisors)
#
# Usage:
#   chmod +x script/agents/auto_promote.sh
#   ./script/agents/auto_promote.sh > out/auto_promote.console 2>&1 &
#
#   # stop cleanly without killing mid-tx:
#   touch out/auto_promote.stop
#
# This script is intentionally crash-resilient: every cast invocation is
# wrapped so that a failure is logged but does NOT kill the daemon. The
# arbitration state-machine queries (cast call) are idempotent reads, and
# the cast send calls are best-effort — anyone can call resolve(); the
# orchestrator is admin-gated, so promote calls will only succeed when
# the daemon's PRIVATE_KEY corresponds to the ADMIN.
set -uo pipefail

# ─── config ────────────────────────────────────────────────────────────────
: "${PRIVATE_KEY:?PRIVATE_KEY env required}"
: "${SEPOLIA_RPC:=https://sepolia.drpc.org}"
: "${FUTARCHY_FACTORY:=0x208d0760c742a4fb46932811ec843f08752f6ab3}"
: "${ORCHESTRATOR:=0xc17D88Bf0c16c0c2F1dEBd375163Fc538aB5aBF5}"
: "${RESOLVER:=0xC17408966d424A3fc8fAf9F007413FA842bDB479}"
: "${ADAPTER:=0x8Ccc8d0E6cf2685De388Bb2Ef764015268364B5A}"
: "${COMPANY_TOKEN:=0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65}"
: "${CURRENCY_TOKEN:=0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14}"
: "${PROMOTE_LIQUIDITY_WEI:=10000000000000000}"
: "${ARBITRATION:=0x9D7692738a4d323338b9007d65d7F79e013B3476}"
: "${ARBITRATION_DEPLOY_BLOCK:=10880000}"
: "${PROMOTE_INTERVAL_SEC:=300}"
: "${RESOLVE_INTERVAL_SEC:=60}"
: "${LOG_SCAN_CHUNK_BLOCKS:=5000}"
: "${RUN_HOURS:=24}"
: "${FOUNDRY_IMAGE:=ghcr.io/foundry-rs/foundry:stable}"
: "${GAS_PRICE:=4000000000}"
: "${PROMOTE_GAS_LIMIT:=15500000}"
: "${PROMOTE_NAME_PREFIX:=auto}"

mkdir -p out
LOG=out/auto_promote.log
STOP=out/auto_promote.stop
PIDFILE=out/auto_promote.pid

# Single source of timestamps so we can grep the log easily.
ts() { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "$(ts) $*" | tee -a "$LOG"; }

# ─── docker / cast helpers ────────────────────────────────────────────────
# Mirrors the invocation pattern from script/agents/run_phase5.sh: every
# cast/forge call runs inside the foundry docker image so we don't depend
# on a host-side foundry installation. The repo is bind-mounted at /work.

# Resolve a working DOCKER_HOST. The /run/user/$UID/docker.sock path works
# for the rootless-docker setup used on the operator box; falls back to
# the daemon socket if that one is missing.
_docker_host() {
  if [ -n "${DOCKER_HOST:-}" ]; then
    echo "$DOCKER_HOST"
    return
  fi
  if [ -S "/run/user/$(id -u)/docker.sock" ]; then
    echo "unix:///run/user/$(id -u)/docker.sock"
  else
    echo "unix:///var/run/docker.sock"
  fi
}

# Run an arbitrary cast/foundry shell command inside the docker image.
# Stdout is returned; stderr is forwarded to the log so failures are visible.
_in_foundry() {
  local cmd="$1"
  DOCKER_HOST="$(_docker_host)" \
    docker run --rm --user root -v "$PWD:/work" -w /work \
    -e PRIVATE_KEY="$PRIVATE_KEY" \
    -e SEPOLIA_RPC="$SEPOLIA_RPC" \
    "$FOUNDRY_IMAGE" -c "$cmd" 2>>"$LOG"
}

# Wrapper: cast call (read-only). On error returns "" and logs the failure.
# Output is forwarded verbatim (whitespace + newlines preserved) so the
# caller can decode either scalars or tuples. Scalar consumers should
# trim themselves (typical: `... | tr -s '[:space:]' '\n' | head -1`).
cast_call() {
  local out
  if out=$(_in_foundry "cast call $* --rpc-url $SEPOLIA_RPC" 2>/dev/null); then
    echo "$out"
  else
    log "WARN cast_call failed: $*"
    echo ""
  fi
}

# Trim a scalar value: strip CR/LF and outer whitespace.
trim() { tr -d '\r' | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' ; }

# Wrapper: cast logs (event scan). Echoes raw output; on error returns "".
cast_logs() {
  if ! _in_foundry "cast logs $* --rpc-url $SEPOLIA_RPC" 2>/dev/null; then
    log "WARN cast_logs failed: $*"
    echo ""
  fi
}

# Wrapper: cast send (mutating). Logs success/failure but never aborts.
# Optional extra cast flags can be appended via CAST_EXTRA env (e.g.
# "--gas-limit 15500000"). Read once per call so callers can scope it.
cast_send() {
  local label="$1"; shift
  local extra="${CAST_EXTRA:-}"
  log "SEND[$label] $*"
  if _in_foundry "cast send $* --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY --legacy --gas-price $GAS_PRICE $extra" >>"$LOG" 2>&1; then
    log "SEND[$label] OK"
    return 0
  else
    log "SEND[$label] FAILED (see preceding lines)"
    return 1
  fi
}

# ─── arbitration helpers ───────────────────────────────────────────────────

# Enum ProposalState: INACTIVE=0, YES=1, NO=2, QUEUED=3, EVALUATING=4, SETTLED=5
STATE_QUEUED=3

# Discover proposal ids by scanning ProposalGraduated(uint256,uint32,uint256,uint256)
# from ARBITRATION_DEPLOY_BLOCK to latest, in chunks (drpc/publicnode reject
# > ~10k-block windows). Echoes one id per line, deduped.
discover_graduated_ids() {
  local latest from to chunk="$LOG_SCAN_CHUNK_BLOCKS"
  latest=$(_in_foundry "cast block-number --rpc-url $SEPOLIA_RPC" 2>/dev/null | tr -d '\r\n ' || echo "")
  if [ -z "$latest" ]; then
    log "WARN discover_graduated_ids: could not fetch latest block; skipping scan"
    return 0
  fi

  from=$ARBITRATION_DEPLOY_BLOCK
  while [ "$from" -le "$latest" ]; do
    to=$((from + chunk - 1))
    if [ "$to" -gt "$latest" ]; then to=$latest; fi
    # ProposalGraduated indexed signature:
    #   ProposalGraduated(uint256 indexed proposalId, uint32 indexed queuePosition,
    #                     uint256 requiredYesBond, uint256 yesBondAmount)
    # cast logs accepts the human-readable form; topic0 (event sig) is added
    # automatically, and the two indexed args become topics[1] and topics[2].
    local raw
    raw=$(cast_logs --from-block "$from" --to-block "$to" --address "$ARBITRATION" \
      "'ProposalGraduated(uint256,uint32,uint256,uint256)'")
    # Parse strategy (portable, no gawk-only features):
    #   1. awk range pattern /topics/,/]/  isolates the topics block of every
    #      event record (works for both multi-line "topics: [\n  0x..\n]" and
    #      single-line "topics: [0x..,0x..,0x..]" cast formats).
    #   2. grep -oE '0x[0-9a-fA-F]{64}' pulls out one topic per line.
    #   3. Each event has 3 topics: topic0 (sig), topic1 (proposalId),
    #      topic2 (queuePosition). We want every 2nd-of-3 line.
    #   4. Convert the resulting 0x-hex to decimal in bash and dedupe.
    local hex_lines
    hex_lines=$(echo "$raw" \
      | awk '/topics/,/]/' \
      | grep -oE '0x[0-9a-fA-F]{64}' \
      | awk 'NR%3==2')   # 2nd, 5th, 8th, ... = proposalId of each event
    local hex stripped id_dec
    while IFS= read -r hex; do
      [ -z "$hex" ] && continue
      stripped="${hex#0x}"
      stripped=$(echo "$stripped" | sed 's/^0*//')
      [ -z "$stripped" ] && stripped="0"
      id_dec=$((16#$stripped))
      echo "$id_dec"
    done <<<"$hex_lines" | sort -un
    from=$((to + 1))
  done
}

# Read getProposal(uint256) and echo just the state field (uint8).
# The Proposal struct return is encoded as a tuple. Cast accepts the nested
# tuple signature directly:
#   Proposal = (uint256 minActivationBond,
#               Bond yesBond,  // (address bidder, uint256 amount)
#               Bond noBond,   // (address bidder, uint256 amount)
#               uint8 state,
#               uint64 lastStateChangeAt,
#               bool settled,
#               bool accepted,
#               uint32 queuePosition,
#               bool exists)
# Order of tokens in cast's stdout (one per line for tuples):
#   1: minActivationBond
#   2: yesBond as "(addr, amount)"
#   3: noBond  as "(addr, amount)"
#   4: state  ← THIS
#   5: lastStateChangeAt
#   ...
proposal_state() {
  local pid="$1"
  local raw
  raw=$(cast_call "$ARBITRATION 'getProposal(uint256)((uint256,(address,uint256),(address,uint256),uint8,uint64,bool,bool,uint32,bool))' $pid")
  if [ -z "$raw" ]; then
    echo "-1"; return
  fi
  # Extract the 4th top-level field (state). The two preceding tuples
  # (yesBond, noBond) are printed like "(0x..., 123)". Strip all parens
  # and commas, split on whitespace, and pick the 6th flat token:
  #   1: minActivationBond
  #   2: yesBond.bidder
  #   3: yesBond.amount
  #   4: noBond.bidder
  #   5: noBond.amount
  #   6: STATE  ← THIS
  echo "$raw" | tr -d '()' | tr ',' '\n' | tr -s '[:space:]' '\n' | awk 'NF' | awk 'NR==6 {print; exit}'
}

# Count proposals currently queued (state == QUEUED) given an id list on stdin.
count_queued() {
  local count=0 pid st
  while IFS= read -r pid; do
    [ -z "$pid" ] && continue
    st=$(proposal_state "$pid")
    if [ "$st" = "$STATE_QUEUED" ]; then
      count=$((count + 1))
    fi
  done
  echo "$count"
}

# ─── promote loop ──────────────────────────────────────────────────────────
# Strategy: scan arbitration ProposalGraduated logs, count currently-QUEUED
# proposals, and if >= 1, fire one orchestrator call. The orchestrator is
# admin-gated and admin-key-only, so we expect this to succeed iff the
# operator's PRIVATE_KEY is the orchestrator ADMIN. If it isn't, the call
# reverts NotAdmin() and we just log + retry next tick.
do_promote_tick() {
  local ids queued
  ids=$(discover_graduated_ids || true)
  queued=$(echo "$ids" | count_queued)
  log "PROMOTE_TICK ids=$(echo "$ids" | tr '\n' ',' | sed 's/,$//') queued=$queued"

  if [ "${queued:-0}" -lt 1 ]; then
    return 0
  fi

  local nonce name desc
  nonce=$(date -u +'%Y%m%d-%H%M%S')
  name="${PROMOTE_NAME_PREFIX}-${nonce}"
  desc="Auto-promoted by auto_promote.sh (queued=${queued}) at $(ts). See script comments for design-gap context."

  # Adapter migration pipeline (three sequential txs, atomic on the promote):
  #   1. adapter.stage(amt, amt)                — records this operator's pull amounts
  #   2. companyToken.approve(adapter, amt)     — allowance for splitPosition source
  #   3. currencyToken.approve(adapter, amt)
  #   4. orchestrator.createOfficialProposalAndMigrate(name, desc, 0)
  #      → factory.createProposal → init YES/NO pools → adapter.migrate
  #
  # If any prep tx fails we still attempt the promote; the orchestrator will
  # revert NothingStaged / ERC20TransferFailed and the daemon logs the error.
  if [ -n "${ADAPTER:-}" ] && [ "$ADAPTER" != "0x0000000000000000000000000000000000000000" ]; then
    cast_send "stage" "$ADAPTER \
      'stage(uint256,uint256)' \
      $PROMOTE_LIQUIDITY_WEI $PROMOTE_LIQUIDITY_WEI"
    cast_send "approveCompany" "$COMPANY_TOKEN \
      'approve(address,uint256)' \
      $ADAPTER $PROMOTE_LIQUIDITY_WEI"
    cast_send "approveCurrency" "$CURRENCY_TOKEN \
      'approve(address,uint256)' \
      $ADAPTER $PROMOTE_LIQUIDITY_WEI"
  fi

  # createOfficialProposalAndMigrate(string,string,uint256) — builderTip=0.
  # Pass an explicit gas-limit so the RPC's eth_estimateGas cap doesn't
  # block the tx; we use OBS_CARDINALITY=30 in the orchestrator so the
  # whole atomic flow fits comfortably under 16.7M gas.
  CAST_EXTRA="--gas-limit $PROMOTE_GAS_LIMIT" \
    cast_send "promote" "$ORCHESTRATOR \
      'createOfficialProposalAndMigrate(string,string,uint256)' \
      \"$name\" \"$desc\" 0"
}

# ─── resolve loop ──────────────────────────────────────────────────────────
# Walk FAOFutarchyFactory.proposals(i) for every i in [0..marketsCount) and
# call resolver.resolve(propAddr) for any proposal where isReadyToResolve()
# returns true and bindings(propAddr).resolved is false.
do_resolve_tick() {
  local count
  count=$(cast_call "$FUTARCHY_FACTORY 'marketsCount()(uint256)'" | trim)
  if [ -z "$count" ] || ! [[ "$count" =~ ^[0-9]+$ ]]; then
    log "RESOLVE_TICK skip (marketsCount fetch failed: '$count')"
    return 0
  fi
  log "RESOLVE_TICK marketsCount=$count"

  local i=0 propAddr ready binding resolved
  while [ "$i" -lt "$count" ]; do
    propAddr=$(cast_call "$FUTARCHY_FACTORY 'proposals(uint256)(address)' $i" | trim)
    if [ -z "$propAddr" ] || [ "$propAddr" = "0x0000000000000000000000000000000000000000" ]; then
      i=$((i + 1)); continue
    fi
    # bindings() returns 8-tuple of leaf types; cast prints one value per line.
    # Field order (1-indexed): yesPool, noPool, companyToken, currencyToken,
    # questionId, anchorTimestamp, RESOLVED, accepted.
    binding=$(cast_call "$RESOLVER 'bindings(address)(address,address,address,address,bytes32,uint48,bool,bool)' $propAddr")
    if [ -z "$binding" ]; then
      i=$((i + 1)); continue
    fi
    resolved=$(echo "$binding" | tr -s '[:space:]' '\n' | awk 'NF' | awk 'NR==7 {print; exit}')
    if [ "$resolved" = "true" ]; then
      i=$((i + 1)); continue
    fi
    ready=$(cast_call "$RESOLVER 'isReadyToResolve(address)(bool)' $propAddr" | trim)
    if [ "$ready" = "true" ]; then
      cast_send "resolve" "$RESOLVER 'resolve(address)' $propAddr"
    fi
    i=$((i + 1))
  done
}

# ─── main supervisor ───────────────────────────────────────────────────────

cleanup() {
  log "STOP daemon exiting (pid=$$)"
  rm -f "$PIDFILE"
  exit 0
}
trap cleanup INT TERM

echo $$ > "$PIDFILE"

end_time=$(( $(date +%s) + RUN_HOURS * 3600 ))
last_promote=0
last_resolve=0
log "START auto_promote.sh pid=$$ RUN_HOURS=$RUN_HOURS PROMOTE_INTERVAL=${PROMOTE_INTERVAL_SEC}s RESOLVE_INTERVAL=${RESOLVE_INTERVAL_SEC}s"
log "START rpc=$SEPOLIA_RPC factory=$FUTARCHY_FACTORY orchestrator=$ORCHESTRATOR resolver=$RESOLVER arbitration=$ARBITRATION"

# Quick connectivity sanity-check (logs but doesn't block startup).
operator_addr=$(_in_foundry "cast wallet address --private-key $PRIVATE_KEY" 2>/dev/null | tr -d '\r\n ')
log "START operator=$operator_addr"

while true; do
  if [ -f "$STOP" ]; then
    log "STOP $STOP detected — exiting gracefully"
    cleanup
  fi

  now=$(date +%s)
  if [ "$now" -ge "$end_time" ]; then
    log "STOP RUN_HOURS=$RUN_HOURS elapsed — exiting"
    cleanup
  fi

  # Resolve loop fires first (cheaper, more frequent).
  if [ $((now - last_resolve)) -ge "$RESOLVE_INTERVAL_SEC" ]; then
    do_resolve_tick || log "WARN do_resolve_tick errored (non-fatal)"
    last_resolve=$(date +%s)
  fi

  if [ $((now - last_promote)) -ge "$PROMOTE_INTERVAL_SEC" ]; then
    do_promote_tick || log "WARN do_promote_tick errored (non-fatal)"
    last_promote=$(date +%s)
  fi

  # Sleep just long enough to keep the cheaper loop responsive.
  sleep 10
done
