#!/usr/bin/env bash
# Capture audit/screenshots/<page>-<viewport>.png for the multimodal
# T1.D6 evaluator. Uses wkhtmltoimage (webkit, no system libs needed)
# instead of Playwright/chromium which requires libnspr4 etc.
#
# 6 pages × 2 viewports = 12 PNGs + manifest.json.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/audit/screenshots"
mkdir -p "$OUT"

URL_BASE="${FAO_SITE_URL:-https://fao-testnet.pages.dev}"
WKHTML=/home/kelvin/.local/bin/wkhtmltoimage

if [[ ! -x "$WKHTML" ]]; then
  echo "wkhtmltoimage not installed at $WKHTML"; exit 1
fi

declare -A PAGES=(
  [home]="/"
  [sale]="/sale"
  [proposals]="/proposals"
  [create]="/create"
  [contracts]="/contracts"
  [docs]="/docs"
)

# desktop + mobile viewports
declare -A VPS=(
  [desktop]="1280:720"
  [mobile]="390:844"
)

MANIFEST="$OUT/manifest.json"
echo '{' > "$MANIFEST"
echo "  \"generatedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"," >> "$MANIFEST"
echo "  \"siteUrl\": \"$URL_BASE\"," >> "$MANIFEST"
echo "  \"screenshots\": [" >> "$MANIFEST"

FIRST=1
for label in "${!PAGES[@]}"; do
  path="${PAGES[$label]}"
  url="$URL_BASE$path"
  for vp in "${!VPS[@]}"; do
    spec="${VPS[$vp]}"
    width="${spec%:*}"; height="${spec#*:}"
    file="$OUT/${label}-${vp}.png"
    echo "[capture] $label @ $vp ($width × $height) — $url"
    if "$WKHTML" --quiet --width "$width" --height "$height" --javascript-delay 3000 \
        --custom-header "User-Agent" "Mozilla/5.0 FAO-multimodal" "$url" "$file" 2>/dev/null; then
      sha=$(sha256sum "$file" | awk '{print $1}')
      bytes=$(stat -c%s "$file")
      [[ $FIRST -eq 1 ]] || echo "," >> "$MANIFEST"
      printf '    {"label":"%s","viewport":"%s","url":"%s","file":"audit/screenshots/%s-%s.png","sha":"%s","bytes":%s}' \
        "$label" "$vp" "$url" "$label" "$vp" "$sha" "$bytes" >> "$MANIFEST"
      FIRST=0
      echo "  -> ${sha:0:12} ($bytes bytes)"
    else
      echo "  [warn] capture failed for $url"
    fi
  done
done
echo "" >> "$MANIFEST"
echo "  ]" >> "$MANIFEST"
echo "}" >> "$MANIFEST"

echo ""
echo "Done. Manifest at $MANIFEST"
ls -la "$OUT"/*.png 2>/dev/null | head -15
