#!/usr/bin/env bash
set -euo pipefail

PID_FILE="${FAO_ANVIL_PID_FILE:-/tmp/fao-anvil.pid}"
LOG_FILE="${FAO_ANVIL_LOG_FILE:-/tmp/fao-anvil.log}"
SEPOLIA_RPC="${SEPOLIA_RPC:-https://ethereum-sepolia.publicnode.com}"
PORT="${ANVIL_PORT:-8545}"
FORK_BLOCK_NUMBER="${ANVIL_FORK_BLOCK_NUMBER:-${FORK_BLOCK_NUMBER:-}}"

usage() {
  cat <<'EOF'
Usage: scripts/anvil-fork.sh [--stop]

Starts an Anvil Sepolia fork in the background on port 8545 by default.

Environment:
  SEPOLIA_RPC               Fork source RPC URL.
  ANVIL_PORT                Local Anvil port. Default: 8545.
  ANVIL_FORK_BLOCK_NUMBER   Optional pinned fork block number.
  FORK_BLOCK_NUMBER         Optional pinned fork block number fallback.
  FAO_ANVIL_PID_FILE        PID file path. Default: /tmp/fao-anvil.pid.
  FAO_ANVIL_LOG_FILE        Log file path. Default: /tmp/fao-anvil.log.
EOF
}

is_running() {
  local pid="${1:-}"
  [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null
}

stop_anvil() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "No Anvil PID file found at $PID_FILE"
    return 0
  fi

  local pid
  pid="$(<"$PID_FILE")"
  if is_running "$pid"; then
    kill "$pid"
    for _ in {1..50}; do
      if ! is_running "$pid"; then
        break
      fi
      sleep 0.1
    done
    if is_running "$pid"; then
      echo "Anvil pid $pid did not stop after SIGTERM"
      exit 1
    fi
    echo "Stopped Anvil fork pid $pid"
  else
    echo "Removing stale Anvil PID file for pid $pid"
  fi

  rm -f "$PID_FILE"
}

start_anvil() {
  if ! command -v anvil >/dev/null 2>&1; then
    echo "anvil not found on PATH. Install Foundry before starting the fork."
    exit 127
  fi

  if [[ -f "$PID_FILE" ]]; then
    local existing_pid
    existing_pid="$(<"$PID_FILE")"
    if is_running "$existing_pid"; then
      echo "Anvil fork already running on port $PORT (pid $existing_pid)"
      return 0
    fi
    rm -f "$PID_FILE"
  fi

  local cmd=(anvil --fork-url "$SEPOLIA_RPC" --port "$PORT")
  if [[ -n "$FORK_BLOCK_NUMBER" ]]; then
    cmd+=(--fork-block-number "$FORK_BLOCK_NUMBER")
  fi

  if command -v setsid >/dev/null 2>&1; then
    nohup setsid "${cmd[@]}" >"$LOG_FILE" 2>&1 </dev/null &
  else
    nohup "${cmd[@]}" >"$LOG_FILE" 2>&1 </dev/null &
  fi
  local pid=$!
  echo "$pid" >"$PID_FILE"

  sleep 1
  if ! is_running "$pid"; then
    rm -f "$PID_FILE"
    echo "Anvil failed to start. See $LOG_FILE for details."
    exit 1
  fi

  echo "Anvil fork started on http://127.0.0.1:$PORT (pid $pid)"
  echo "PID file: $PID_FILE"
  echo "Log file: $LOG_FILE"
}

case "${1:-}" in
  "")
    start_anvil
    ;;
  --stop)
    stop_anvil
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
