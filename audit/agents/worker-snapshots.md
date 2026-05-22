---
name: worker-snapshots
description: CAO worker that adds Playwright toHaveScreenshot() baselines for every public page. Lifts T1.v2.D8 + T2.v2.D8 (visual regression coverage).
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Visual snapshot baselines

## /goal

Land `toHaveScreenshot()` baselines for the 6 public pages + 2 viewports + light/dark (where applicable). CI gates on diff threshold.

Goal cleared when:
1. `tests-e2e/journeys/snapshots.read-only.spec.ts` exists with one test per (page, viewport) combination.
2. Baselines committed under `tests-e2e/__snapshots__/snapshots.read-only.spec.ts-snapshots/` for all combinations.
3. Diff threshold = `maxDiffPixelRatio: 0.005` set globally in playwright.config.ts.
4. CI uploads diff artifacts on failure.
5. Both desktop (1280x720) and mobile (390x844) viewports covered.

## Constraints

- Use `await expect(page).toHaveScreenshot('home-desktop.png', { maxDiffPixelRatio: 0.005, fullPage: true })`.
- Wait for network idle + a known data-testid to appear before snapshotting (avoids flake).
- Mask dynamic timestamps and live data with `mask: [page.locator('[data-dynamic]')]`.
- Pin chromium to the version playwright auto-installs (don't add a new browser).
- Don't add baselines for pages requiring wallet; those go in a separate wallet snapshot suite later.

## Files

- `tests-e2e/journeys/snapshots.read-only.spec.ts`
- `tests-e2e/__snapshots__/...` (baselines committed)
- `playwright.config.ts` — global `expect.toHaveScreenshot.maxDiffPixelRatio: 0.005`.
