#!/usr/bin/env bash
# Copy the canonical audit JSONL outputs + dashboard assets into the ops
# Pages deploy tree. CI gate (scripts/check-ops-sync.sh) verifies parity.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 1. JSONL evaluation files
SRC_EVAL="$ROOT/audit/evaluations"
DST_EVAL="$ROOT/site-ops/fao/evaluations"
mkdir -p "$DST_EVAL"
for topic in 1 2 3 4 5 6; do
  src="$SRC_EVAL/topic-${topic}-evals.jsonl"
  dest="$DST_EVAL/topic-${topic}-evals.jsonl"
  if [[ ! -f "$src" ]]; then
    echo "::error::missing audit evaluation file: $src" >&2
    exit 1
  fi
  cp "$src" "$dest"
done

# 2. Dashboard assets (HTML / JS / CSS) — keep deployed in sync with source.
# Required because the source HTML evolves (CDN tags, etc.) and a stale
# copy under site-ops/fao/ silently breaks the dashboard.
SRC_ASSETS="$ROOT/audit/dashboard"
DST_ASSETS="$ROOT/site-ops/fao"
for f in index.html dashboard.js dashboard.css; do
  if [[ -f "$SRC_ASSETS/$f" ]]; then
    cp "$SRC_ASSETS/$f" "$DST_ASSETS/$f"
  fi
done

echo "[ok] synced JSONL + dashboard assets (index.html, dashboard.{js,css}) into site-ops/fao/"
