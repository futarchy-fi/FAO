---
name: worker-screenshots
description: CAO worker that maintains a fresh set of page screenshots under audit/screenshots/ for the multimodal T1.D6 evaluator to read.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Screenshot snapshot capture

## /goal

Maintain `audit/screenshots/<page>-<viewport>.png` for every public page and viewport. Used as input to the multimodal T1 evaluator (which reads them via its Read tool to judge visual hierarchy).

Goal cleared when:
1. `scripts/capture-screenshots.sh` exists. Runs Playwright + writes to `audit/screenshots/`.
2. The script covers 6 pages × 2 viewports (desktop 1280x720, mobile 390x844) = 12 PNGs.
3. PNGs are committed (small ~50–150 KB each — Cloudflare-served pages, dark theme).
4. `.github/workflows/screenshots.yml` runs the capture on push to site-testnet/** and commits the new PNGs.
5. `audit/screenshots/manifest.json` lists every PNG with its source URL + capture timestamp + SHA.

## Constraints

- Use headless chromium from Playwright.
- Wait for `document.readyState === 'complete'` AND a known data-testid present.
- Mask dynamic numeric cells (`[data-dynamic]`) with solid color so screenshots are stable.
- Run with `FAO_SITE_URL=https://fao-ops.pages.dev/fao/` and `https://fao-testnet.pages.dev/` and the audit dashboard.

## Files

- `scripts/capture-screenshots.sh`
- `tests-e2e/journeys/_screenshot-capture.ts` (Playwright helper invoked by the script)
- `audit/screenshots/` (12 PNGs + manifest.json)
- `.github/workflows/screenshots.yml`
