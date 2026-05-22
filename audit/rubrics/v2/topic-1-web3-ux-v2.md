---
canonical: audit/rubrics/v2/topic-1-web3-ux-v2.md
version: 2
supersedes: audit/rubrics/topic-1-web3-ux.md
scope: Web3-frontend UX rubric — measurable via tools where possible (axe-core, Lighthouse, Playwright snapshot diff, multimodal screenshot judge). Text-only LLM inspection caps each dim at 6; objective tool output lifts above that.
last-rebuilt: 2026-05-22
---

# Topic 1 — Web3 UX (v2)

v1 scored 6 dimensions by code-text inspection. v2 grades 8 dimensions and **requires tool-emitted evidence** for the dims where text inspection structurally cannot determine quality (visual hierarchy, performance, a11y, snapshot regression).

## Dimensions

### D1 — Primary-action surface (text + screenshot evidence)
What it measures: exactly one visually-primary action per visible viewport.

| Score | Anchor |
|---|---|
| 0–2 | Multiple primary buttons compete; no clear next action. |
| 3–5 | ≤ 2 visually primary buttons per page; some pages have explicit "active" semantics (`aria-current`). |
| 6–7 | Exactly 1 primary visible at a time on every page; `aria-current` used consistently. **Cap if no screenshot evidence available.** |
| 8–10 | (6–7 anchors) + multimodal screenshot judge confirms visual primacy on home, sale, create, proposals, bonds. |

### D2 — Wallet-state + EIP-6963 (text inspection)
What it measures: presence of EIP-6963 provider discovery; provider identity surfaced in UI.

| Score | Anchor |
|---|---|
| 0–3 | Bare `window.ethereum`; no provider name; no multi-wallet support. |
| 4–6 | EIP-6963 announce listener wired but no UI surface. |
| 7–8 | EIP-6963 + provider-picker modal + identity shown in topbar. |
| 9–10 | + per-provider error guidance + persistent reconnect across reloads. |

### D3 — Pre-confirm / pending / success / error (text + interaction test)
What it measures: every write action has a decoded review card before signing.

| Score | Anchor |
|---|---|
| 0–3 | Native `confirm()` or no pre-confirm. |
| 4–6 | ≥ 1 write path uses a decoded review card (e.g. Sale.buy). |
| 7–8 | All write paths (create, buy, ragequit, propose, bond, resolve) use review cards with decoded args + gas estimate. |
| 9–10 | + pending/success/error states each have a dedicated visual (toast, banner) confirmed by snapshot test. |

### D4 — Information density vs noise (text + Lighthouse)
What it measures: tabular numerals on numeric cells; address truncation; Lighthouse "best-practices" score.

| Score | Anchor |
|---|---|
| 0–3 | Raw addresses pasted; numbers non-monospace. |
| 4–6 | `fmtAddr` used; numbers non-tabular. |
| 7–8 | `font-variant-numeric: tabular-nums` on all numeric cells; addresses truncated. **Cap if Lighthouse `best-practices` < 80.** |
| 9–10 | + Lighthouse `best-practices` ≥ 90 on the live deploy. |

### D5 — Accessibility (axe-core test output)
What it measures: axe-core violations count on each page.

| Score | Anchor |
|---|---|
| 0–2 | No axe-core integration; > 10 violations per page. |
| 3–5 | axe-core wired but > 5 violations per page. |
| 6–7 | axe-core passing with ≤ 5 violations across the suite. |
| 8 | 0 critical/serious violations; ≤ 3 minor across the suite. |
| 9–10 | 0 violations on every page + `axe-core/playwright` integrated into CI as a gate. |

### D6 — Visual hierarchy + minimalism (multimodal screenshot judge)
What it measures: judged by a vision-capable LLM looking at rendered screenshots; corroborated by ≤ 8 distinct font-size values in CSS.

| Score | Anchor |
|---|---|
| 0–3 | > 12 distinct `font-size:` declarations across CSS; raw hex literals in HTML inline styles; multimodal judge marks "cluttered". |
| 4–5 | 8–12 distinct font sizes; ad-hoc hex literals reduced; multimodal "acceptable". **Cap if no multimodal judge result attached.** |
| 6–7 | ≤ 8 distinct font sizes; zero raw hex in HTML; multimodal "well-structured". |
| 8–10 | (6–7) + multimodal "clear visual hierarchy on every page" + token system documented as single source of truth. |

### D7 — Performance budget (Lighthouse CI output)
What it measures: LCP / INP / CLS against Web Vitals thresholds.

| Score | Anchor |
|---|---|
| 0–2 | No Lighthouse CI integration. |
| 3–5 | Lighthouse runs but no budget enforcement. |
| 6–7 | Budgets defined: LCP < 4s, INP < 500ms, CLS < 0.25. |
| 8 | LCP < 2.5s **and** INP ≤ 200ms **and** CLS ≤ 0.1 on the home + sale pages. |
| 9–10 | (8 anchors) + budgets enforced as a CI gate (workflow fails on regression). |

### D8 — Visual regression coverage (Playwright snapshot baselines)
What it measures: count of pages with `toHaveScreenshot` baselines + diff threshold gating.

| Score | Anchor |
|---|---|
| 0–2 | No visual snapshot tests. |
| 3–5 | 1–2 pages have baselines but no CI gate. |
| 6–7 | All public pages (home, sale, proposals, create, contracts, docs) have baselines with diff threshold ≤ 0.5%. |
| 8–10 | (6–7) + baselines for both light/dark modes + responsive viewports + the diff is gated in CI. |

## Evidence ledger

For each scoring round, the evaluator must reference:

| Dim | Required artifact |
|---|---|
| D1 | site-testnet HTML (text) + optional screenshot |
| D2 | site-testnet/shared.js text |
| D3 | text inspection of write paths |
| D4 | text + `audit/lighthouse/best-practices.json` |
| D5 | `audit/axe/violations.json` from latest Playwright run |
| D6 | text + `audit/multimodal/T1.D6.json` containing vision-model verdict + screenshot SHAs |
| D7 | `audit/lighthouse/web-vitals.json` |
| D8 | snapshot count from `tests-e2e/**/__snapshots__/` directory |

## How this might be wrong

- D6 (multimodal) requires a vision-capable model. If the evaluator can't access one, D6 is capped at 5 — and the rubric must note this in the score's `anchor_matched` field.
- D7 budgets are conservative; teams shipping pure-static sites should easily clear them.
- D5 leaves "minor" violations out of the gate intentionally — some violations (e.g. region role on `<header>`) are spurious in single-page apps.
