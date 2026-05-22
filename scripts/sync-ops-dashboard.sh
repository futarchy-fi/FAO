#!/usr/bin/env bash
# Copy the canonical audit JSONL outputs into the ops Pages deploy tree.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$ROOT/audit/evaluations"
DEST_DIR="$ROOT/site-ops/fao/evaluations"

mkdir -p "$DEST_DIR"

for topic in 1 2 3 4 5 6; do
  src="$SRC_DIR/topic-${topic}-evals.jsonl"
  dest="$DEST_DIR/topic-${topic}-evals.jsonl"

  if [[ ! -f "$src" ]]; then
    echo "::error::missing audit evaluation file: $src" >&2
    exit 1
  fi

  cp "$src" "$dest"
done

echo "[ok] synced audit/evaluations/topic-{1..6}-evals.jsonl to site-ops/fao/evaluations/"
