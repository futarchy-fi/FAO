---
name: worker-axe
description: CAO worker that wires @axe-core/playwright into the read-only test suite. Lifts T1.D5 + T2.D9 by emitting axe-core violations as a CI artifact and gating regressions.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — axe-core a11y wiring

## /goal

Land axe-core scans for every page in the read-only Playwright project. Each page's violations are stored as `audit/axe/<page>.json` after every test run. CI fails on `critical` or `serious` violations. Update T1.v2.D5 and T2.v2.D9 evidence.

Goal cleared when:
1. `@axe-core/playwright` is in package.json devDependencies.
2. A shared helper `tests-e2e/axe-helper.ts` exists with `runAxeOn(page, label)`.
3. Each of 6 public pages (home, sale, proposals, create, contracts, docs) has an axe test calling that helper.
4. `audit/axe/<page>.json` files are committed (placeholder OK initially) and updated on every CI run.
5. `.github/workflows/e2e.yml` uploads `audit/axe/` as an artifact.
6. The CI step fails if any axe-core violation has `impact === 'critical'` or `'serious'`.

## Constraints

- Don't touch site-testnet/ unless to add missing landmarks (`<main>`, `<header>`, `<nav>`) — those are legitimate a11y fixes.
- Use `data-testid` instead of class selectors in any new selector.
- Commit incrementally: helper first, then 1 page at a time.
- Verify locally: `npx playwright test --project=read-only --grep axe` should succeed for committed pages and produce JSON output.

## Files to create/edit

- `package.json` — add `"@axe-core/playwright": "^4.10.0"` to devDependencies.
- `tests-e2e/axe-helper.ts` — `runAxeOn(page, label) → writes audit/axe/<label>.json`.
- `tests-e2e/journeys/a11y.read-only.spec.ts` — one test per page calling the helper.
- `.github/workflows/e2e.yml` — add `audit/axe/` to artifact upload.
- `audit/axe/.gitkeep` — directory marker.
