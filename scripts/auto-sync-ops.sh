#!/usr/bin/env bash
# Auto-resync + redeploy ops.futarchy.ai/fao whenever audit/evaluations/
# changes. Runs in background; logs to data/auto-sync-ops.log.
#
# Usage:
#   nohup bash scripts/auto-sync-ops.sh > /tmp/auto-sync-ops.log 2>&1 &
#   pkill -f scripts/auto-sync-ops.sh   # stop
#
# Polls every 60s. Triggers a redeploy only when the SHA-256 of the
# concatenated JSONL files changes (so a no-op heartbeat doesn't spam
# Cloudflare with deploys).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

LOG="$ROOT/data/auto-sync-ops.log"
mkdir -p "$(dirname "$LOG")"
echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] auto-sync-ops started" >> "$LOG"

source /home/kelvin/.config/openclaw/secrets.env
export CLOUDFLARE_API_KEY="$CLOUDFLARE_GLOBAL_API_KEY"
export CLOUDFLARE_EMAIL="$CLOUDFLARE_AUTH_EMAIL"
export CLOUDFLARE_ACCOUNT_ID="878924eda0607cab3b6c0c86a9babb3f"

LAST_HASH=""

while true; do
  HASH=$(cat audit/evaluations/topic-{1..6}-evals.jsonl 2>/dev/null | sha256sum | awk '{print $1}')
  if [[ -n "$HASH" && "$HASH" != "$LAST_HASH" ]]; then
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] evaluations changed (hash=${HASH:0:12}); syncing + redeploying" >> "$LOG"
    bash scripts/sync-ops-dashboard.sh >> "$LOG" 2>&1
    npx wrangler pages deploy site-ops --project-name=fao-ops --branch=main --commit-dirty=true >> "$LOG" 2>&1
    LAST_HASH="$HASH"
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] redeploy complete" >> "$LOG"
  fi
  sleep 60
done
