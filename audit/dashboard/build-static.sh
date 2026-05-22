#!/usr/bin/env bash
# Build a self-contained audit/dashboard/static.html with all evaluator
# data inlined as JS — no HTTP server needed; openable via file:// or
# whatever way the user can reach it (e.g. scp to local machine).
#
# Usage: bash audit/dashboard/build-static.sh
# Output: audit/dashboard/static.html

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="$ROOT/audit/dashboard/static.html"
TPL="$ROOT/audit/dashboard/index.html"
CSS="$ROOT/audit/dashboard/dashboard.css"
JS="$ROOT/audit/dashboard/dashboard.js"

# Aggregate all 6 topics' JSONL into a single JS object literal.
DATA=$(python3 - <<EOF
import json, sys, os
topics = []
for i in range(1, 7):
    fp = f"$ROOT/audit/evaluations/topic-{i}-evals.jsonl"
    if not os.path.exists(fp):
        topics.append([])
        continue
    rows = []
    with open(fp) as f:
        for line in f:
            line = line.strip()
            if not line: continue
            try: rows.append(json.loads(line))
            except: pass
    topics.append(rows)
print(json.dumps(topics))
EOF
)

CSS_CONTENT=$(cat "$CSS")
JS_CONTENT=$(cat "$JS")

# Replace fetch() with inline data lookup. The patched JS reads from
# window.__FAO_DATA__ instead of fetching.
JS_PATCHED=$(python3 - <<EOF
import sys
src = open("$JS").read()
patched = src.replace(
    "async function loadTopic(id) {",
    "async function loadTopic(id) { if (window.__FAO_DATA__) return window.__FAO_DATA__[id-1] || []; "
)
print(patched)
EOF
)

cat > "$OUT" <<HTML
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>FAO audit dashboard — Phase 6 score tracker (static snapshot)</title>
  <style>
$CSS_CONTENT
  </style>
  <script src="https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js"></script>
  <script src="https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js"></script>
  <script>window.__FAO_DATA__ = $DATA; window.__FAO_BUILD_TS__ = "$(date -u +%Y-%m-%dT%H:%M:%SZ)";</script>
  <script defer>
$JS_PATCHED
  </script>
</head>
<body>

<header class="hdr">
  <h1>FAO audit dashboard <span style="opacity:0.5;font-size:14px;">(static snapshot)</span></h1>
  <p class="hdr-sub">Self-contained HTML — works via file://. Data baked at build time; rebuild with <code>bash audit/dashboard/build-static.sh</code>.</p>
  <div class="hdr-stats" id="hdr-stats">Loading…</div>
</header>

<section class="section">
  <h2>Overview — latest round per topic</h2>
  <div class="overview-grid" id="overview-grid">Loading…</div>
</section>

<section class="section">
  <h2>Average score per topic over time</h2>
  <p class="section-sub">Mean across all sub-scores in each topic. Dashed line at 8.0 is the convergence target.</p>
  <div class="chart-wrap"><canvas id="min-chart"></canvas></div>
</section>

<section class="section">
  <h2>Per-dimension trend (one chart per topic)</h2>
  <div class="per-topic-grid" id="per-topic-grid">Loading…</div>
</section>

<section class="section">
  <h2>Heatmap — dim × round</h2>
  <p class="section-sub">Each cell colored 0.0 (red) → 5.0 (amber) → 8.0+ (green = target).</p>
  <div id="heatmap-wrap">Loading…</div>
</section>

<section class="section">
  <h2>Recent deltas</h2>
  <table class="delta-table" id="delta-table">
    <thead><tr><th>Topic</th><th>Dimension</th><th>R<sub>n-1</sub></th><th>R<sub>n</sub></th><th>Δ</th><th>Direction</th></tr></thead>
    <tbody><tr><td colspan="6">Loading…</td></tr></tbody>
  </table>
</section>

<footer class="ftr">
  <p>Static snapshot. To refresh, rebuild this file on the workspace: <code>bash audit/dashboard/build-static.sh</code>.</p>
  <p>Source: audit/evaluations/topic-{1..6}-evals.jsonl. Built at <span id="build-ts"></span>.</p>
</footer>
<script>document.getElementById("build-ts").textContent = window.__FAO_BUILD_TS__;</script>

</body>
</html>
HTML

echo "Built: $OUT"
echo "Size: $(wc -c < "$OUT") bytes"
echo ""
echo "To view:"
echo "  Option A (local SCP): scp farol:$OUT ~/Desktop/ && open ~/Desktop/static.html"
echo "  Option B (in workspace, if you can): xdg-open $OUT"
