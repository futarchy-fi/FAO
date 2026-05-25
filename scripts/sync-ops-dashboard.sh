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

# 3. Lightweight first-paint summary. The browser uses this small file for the
# initial viewport, then lazy-loads full JSONL only when trend/detail sections
# are reached.
python3 - <<PY
import json
import pathlib

root = pathlib.Path("$ROOT")
src_eval = root / "audit" / "evaluations"
out = root / "site-ops" / "fao" / "summary.json"
labels = [
    "Web3 UX",
    "Interface testing",
    "Spec formalization",
    "SC test infra",
    "Holistic arch",
    "Wiki self-improve",
]
target = 8.0

def is_canonical(row):
    ev = str(row.get("evaluator") or "codex").lower()
    if ev.startswith("worker-") or ev == "multimodal":
        return False
    return len(row.get("scores") or []) >= 5

topics = []
for topic_id, label in enumerate(labels, start=1):
    rows = []
    with (src_eval / f"topic-{topic_id}-evals.jsonl").open() as fh:
        for line in fh:
            line = line.strip()
            if not line:
                continue
            try:
                row = json.loads(line)
            except json.JSONDecodeError:
                continue
            if is_canonical(row):
                rows.append(row)

    last = rows[-1] if rows else {"timestamp": None, "scores": []}
    scores = [float(item["score"]) for item in last.get("scores", [])]
    topics.append({
        "id": topic_id,
        "label": label,
        "rounds": len(rows),
        "timestamp": last.get("timestamp"),
        "min": min(scores) if scores else None,
        "mean": (sum(scores) / len(scores)) if scores else None,
        "atTarget": sum(1 for score in scores if score >= target),
        "total": len(scores),
        "scores": [
            {"dimension": item.get("dimension", ""), "score": item.get("score")}
            for item in last.get("scores", [])
        ],
    })

all_scores = [
    float(item["score"])
    for topic in topics
    for item in topic["scores"]
    if item.get("score") is not None
]
generated_at = max((topic["timestamp"] for topic in topics if topic["timestamp"]), default=None)
summary = {
    "generatedAt": generated_at,
    "target": target,
    "totalDimensions": len(all_scores),
    "atTarget": sum(1 for score in all_scores if score >= target),
    "min": min(all_scores) if all_scores else None,
    "mean": (sum(all_scores) / len(all_scores)) if all_scores else None,
    "latestRound": max((topic["rounds"] for topic in topics), default=0),
    "topics": topics,
}
out.write_text(json.dumps(summary, indent=2, ensure_ascii=True) + "\n")
PY

echo "[ok] synced JSONL + dashboard assets (index.html, dashboard.{js,css}, summary.json) into site-ops/fao/"

# 3. Wiki — mirror audit/wiki/ into site-ops/wiki/ so ops.futarchy.ai/wiki/ stays fresh.
SRC_WIKI="$ROOT/audit/wiki"
DST_WIKI="$ROOT/site-ops/wiki"
if [[ -d "$SRC_WIKI" ]]; then
  mkdir -p "$DST_WIKI"
  # Sync — preserve site-ops/wiki/index.html (our renderer wrapper) by name.
  rsync -a --exclude='index.html' --delete "$SRC_WIKI/" "$DST_WIKI/" 2>/dev/null || cp -r "$SRC_WIKI/"* "$DST_WIKI/" 2>/dev/null
fi
echo "[ok] wiki synced audit/wiki → site-ops/wiki"
