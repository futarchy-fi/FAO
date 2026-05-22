#!/usr/bin/env bash
# T5.D1 — assert that site-testnet/deployments.json is identical to the
# canonical deployments.json at repo root. CI runs this in static-analysis;
# diverging deploys would silently mis-render the UI.
set -euo pipefail
ROOT_FILE="$(cd "$(dirname "$0")/.." && pwd)/deployments.json"
SITE_FILE="$(cd "$(dirname "$0")/.." && pwd)/site-testnet/deployments.json"
if ! diff -q "$ROOT_FILE" "$SITE_FILE" > /dev/null; then
  echo "::error::deployments.json (root) and site-testnet/deployments.json diverged."
  echo "Run: cp deployments.json site-testnet/deployments.json   (then commit)"
  diff "$ROOT_FILE" "$SITE_FILE" || true
  exit 1
fi
echo "[ok] deployments.json sync OK"
