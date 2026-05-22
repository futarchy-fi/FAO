#!/usr/bin/env bash
# T5.D1 — validate the canonical deployment manifest and the site-served copy
# against deployments.schema.json before either file can drift into runtime.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEMA_FILE="$ROOT_DIR/deployments.schema.json"
DEPLOYMENT_FILES=(
  "$ROOT_DIR/deployments.json"
  "$ROOT_DIR/site-testnet/deployments.json"
)

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "::error::missing deployments schema: $SCHEMA_FILE"
  exit 1
fi

if command -v ajv >/dev/null 2>&1; then
  AJV=(ajv)
else
  AJV=(npx --yes ajv-cli@5.0.0)
fi

for deployment_file in "${DEPLOYMENT_FILES[@]}"; do
  if [[ ! -f "$deployment_file" ]]; then
    echo "::error::missing deployment manifest: $deployment_file"
    exit 1
  fi

  "${AJV[@]}" validate --strict=false -s "$SCHEMA_FILE" -d "$deployment_file"
done

echo "[ok] deployments.json schema validation OK"
