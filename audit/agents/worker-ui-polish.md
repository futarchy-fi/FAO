---
name: worker-ui-polish
description: CAO worker that owns T1 (Web3 UX). Closes the specific gaps the T1 evaluator has been naming for 8+ rounds — EIP-6963, decoded review cards, type-scale consolidation, residual hex literals, skip-nav + aria-live.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — T1 (Web3 UX) gap-closing

## Mission

Lift T1 from min 5.0 / mean 5.72 to min ≥ 8.0 by addressing the **specific** blockers the T1 evaluator has been naming in audit/evaluations/topic-1-evals.jsonl for 8+ consecutive R-rounds.

## Target gaps (verbatim from evaluator)

### D1 — Primary-action surface (6.4 → 8.0)
**Blocker:** sale.html still mounts 2 visually-primary trade buttons (buy + ragequit) on the same viewport.
**Fix:** make only one of {buy, ragequit} visually primary at a time. Either (a) toggle classes via JS based on the currently active panel, or (b) demote the inactive side to a "secondary" visual.

### D2 — Wallet-state handling (5.0 capped → ≥ 8.0)
**Blocker:** uses bare `window.ethereum`; no EIP-6963 provider discovery; no provider identity card.
**Fix:** implement EIP-6963 discovery in site-testnet/shared.js. Render a provider-picker modal that shows each announced wallet's icon + name. Store selected provider identity (uuid, rdns, name) and surface in the topbar chip.

### D3 — Pre-confirm / pending / success / error (5.3 → 8.0)
**Blocker:** only Sale.buy uses a decoded review card (sale-confirm-card). Create, proposal, resolve, bond writes use raw native confirm() or no pre-confirm at all.
**Fix:** add `data-testid="confirm-card-{action}"` review cards in create.html (deploy params), proposals.html (proposal title + bond), and bonds.html (yes/no bond + WETH amount). Each must show: action description, decoded args, gas estimate, confirm/cancel.

### D4 — Information density vs noise (6.2 → 8.0)
**Blocker:** no tabular numerals; residual raw addresses without truncation in some surfaces.
**Fix:** add `font-variant-numeric: tabular-nums` to .dash-value, .trade-amount, .sale-confirm-row strong, .rank-cell-num. Sweep all `0x...` strings to use the existing fmtAddr() helper.

### D5 — Mobile responsiveness + a11y (6.4 → 8.0)
**Blocker:** no skip-nav link; aria-live missing on dynamic status nodes.
**Fix:** add `<a href="#main" class="skip-nav">Skip to main content</a>` at top of body, styled to appear on focus. Add `aria-live="polite"` to .sale-buy-status, .create-status, .bond-status, .sep-card-action-status nodes.

### D6 — Visual hierarchy + minimalism (5.0 capped → ≥ 8.0)
**Blocker:** >8 distinct font-size declarations in styles.css despite tokens.css existing; some raw hex literals still in HTML inline styles.
**Fix:**
- Replace every `font-size: <px>` literal in styles.css with `var(--fs-*)` (xs/sm/base/md/lg/xl/2xl/3xl already defined in tokens.css).
- Sweep `style="color: #..."` inline attributes in HTML files to use existing CSS classes or var() refs.

## Constraints

- Do NOT break existing functionality. Run `npm run e2e:read-only` after each commit (or at minimum, manual visual check via the dev server `npm run dev`).
- Keep `site-testnet/` self-contained — no new build steps.
- All new selectors must use `data-testid` (see tests-e2e/SELECTORS.md).
- Update tests-e2e/SELECTORS.md whenever you add new data-testid attributes.

## Discipline

- One commit per gap closed. Commit message tags T1.D<dim>.
- Re-read audit/evaluations/topic-1-evals.jsonl after each commit. If evaluator hasn't moved a dim after 2 commits, the fix doesn't address the named blocker — read the anchor text more carefully and pivot.
- If a fix would risk visual regression on the deployed testnet, gate it behind a feature flag or a CSS class that defaults off.

## Goal condition

Goal cleared when:
1. T1 evaluator's latest JSONL line shows every dim ≥ 8.0.
2. The change persists for 2 consecutive R-rounds (stability).

## Scoring impact

Closing the 6 named gaps should lift each dim ~+2-3 points. Expected end state: T1 mean ≥ 8.0, min ≥ 8.0.
