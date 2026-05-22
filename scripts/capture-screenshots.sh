#!/usr/bin/env bash
# Capture audit/screenshots/<page>-<viewport>.png for the multimodal
# T1.D6 evaluator. Uses headless Playwright Chromium via the helper in
# tests-e2e/journeys/_screenshot-capture.ts.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/audit/screenshots"
HELPER="$ROOT/tests-e2e/journeys/_screenshot-capture.ts"

cd "$ROOT"
mkdir -p "$OUT"

if ! node -e "require.resolve('@playwright/test')" >/dev/null 2>&1; then
  echo "Missing @playwright/test. Run npm install --package-lock=false @playwright/test first." >&2
  exit 1
fi

export FAO_SITE_URL="${FAO_SITE_URL:-https://fao-testnet.pages.dev/}"
export FAO_SCREENSHOT_DIR="${FAO_SCREENSHOT_DIR:-$OUT}"
export FAO_SCREENSHOT_HELPER="$HELPER"

# The helper is intentionally valid CommonJS despite its .ts extension so this
# script works under Node 20 without adding another TypeScript runner.
node -e "require.extensions['.ts'] = require.extensions['.js']; require(process.env.FAO_SCREENSHOT_HELPER);"
