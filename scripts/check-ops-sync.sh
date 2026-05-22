#!/usr/bin/env bash
# Assert the ops Pages dashboard has the current canonical audit JSONL data.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/audit/evaluations"
DEST_DIR="$ROOT/site-ops/fao/evaluations"
status=0

for topic in 1 2 3 4 5 6; do
  src="$SRC_DIR/topic-${topic}-evals.jsonl"
  dest="$DEST_DIR/topic-${topic}-evals.jsonl"

  if ! diff -q "$src" "$dest" > /dev/null; then
    echo "::error::ops dashboard JSONL is out of sync for topic ${topic}."
    echo "Run: bash scripts/sync-ops-dashboard.sh   (then commit site-ops/fao/evaluations/)"
    diff -u "$src" "$dest" || true
    status=1
  fi
done

if [[ "$status" -ne 0 ]]; then
  exit "$status"
fi

echo "[ok] ops dashboard JSONL sync OK"
