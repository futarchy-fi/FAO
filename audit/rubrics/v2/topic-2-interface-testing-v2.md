---
canonical: audit/rubrics/v2/topic-2-interface-testing-v2.md
version: 2
supersedes: audit/rubrics/topic-2-interface-testing.md
scope: Interface-testing rubric — measurable via tools (axe-core, Lighthouse, Playwright snapshot + trace) where possible. Adds 3 dimensions for the layered FE QA stack the v1 rubric was missing.
last-rebuilt: 2026-05-22
---

# Topic 2 — Interface testing (v2)

v1 had 7 dimensions and was structurally unable to detect visual / a11y / performance regressions. v2 adds 3 layered dimensions (visual snapshot, axe-core, Lighthouse CI) for a total of 10. The layered FE QA stack:

```
1. DOM + interaction assertions    (D1, D2 — existing)
2. Visual snapshot testing         (D8 — NEW)
3. Accessibility scans (axe-core)  (D9 — NEW)
4. Performance budgets (Lighthouse)(D10 — NEW)
5. Multimodal LLM judging          (cross-cuts; see T1.v2.D6)
```

## Dimensions

### D1 — User-flow coverage breadth (existing)

| Score | Anchor |
|---|---|
| 0–2 | < 2 journeys with executable wallet tests. |
| 3–5 | 3–5 journeys executable. |
| 6–7 | 6–8 journeys executable. |
| 8–10 | All 10 F1–F10 journeys execute against an Anvil fork; ≥ 80% pass in CI. |

### D2 — Test signal density (existing — refined)

| Score | Anchor |
|---|---|
| 0–2 | Tests pass with broken UI (no real assertions). |
| 3–5 | Some tests assert DOM but not chain state. |
| 6–7 | Each test asserts both DOM **and** chain state via viem. |
| 8–10 | (6–7) + visual snapshot diff + zero `expect(true)` placeholders. |

### D3 — Realism (existing)

| Score | Anchor |
|---|---|
| 0–2 | All tests mock RPC. |
| 3–5 | Some fork-driven specs. |
| 6–7 | Read-only + fork project both run against Anvil-forked Sepolia. |
| 8–10 | (6–7) + wallet project against forked chain via Synpress. |

### D4 — Failure-mode coverage axes (existing — explicit axis list)

Required axes (each = +1 point above the 0 baseline):

1. Wallet rejection (user clicks Cancel)
2. Wrong chain signing
3. Insufficient funds
4. Transaction revert mid-flight
5. Account switch during pending tx
6. Page reload during pending tx
7. Sale already ended
8. Slippage exceeded
9. RPC down
10. Deployments.json missing/malformed

| Score | Anchor |
|---|---|
| 0–2 | 0–2 axes covered. |
| 3–5 | 3–5 axes covered. |
| 6–7 | 6–8 axes covered. |
| 8–10 | All 10 axes covered, each with a dedicated `*.failure.spec.ts`. |

### D5 — Selector & maintainability (existing)

| Score | Anchor |
|---|---|
| 0–3 | Selectors use `.class` / `:nth-child`. |
| 4–6 | `data-testid` on critical actions. |
| 7–8 | `data-testid` on every interactive element + SELECTORS.md contract. |
| 9–10 | (7–8) + CI lint that fails on selector/HTML mismatch. |

### D6 — Performance & CI integration (existing — sharpened)

| Score | Anchor |
|---|---|
| 0–2 | No e2e job in CI. |
| 3–5 | e2e job exists but read-only only. |
| 6–7 | read-only + fork projects in CI; wallet gated by `workflow_dispatch`. |
| 8–10 | All 3 projects + Playwright artifacts uploaded + median run time tracked. |

### D7 — Journey-map fidelity (existing)

| Score | Anchor |
|---|---|
| 0–3 | Specs exist but no map. |
| 4–6 | Map exists, partial sync. |
| 7–8 | Map enumerates every persona, journey, failure mode. |
| 9–10 | (7–8) + CI guard that fails on spec-list/map divergence. |

### D8 — Visual regression coverage (NEW)

What it measures: how many pages have `toHaveScreenshot()` baselines committed.

| Score | Anchor |
|---|---|
| 0–2 | No visual snapshot tests. |
| 3–5 | 1–2 pages with baselines, no CI gate. |
| 6–7 | All 6 public pages (home, sale, proposals, create, contracts, docs) have baselines with diff threshold ≤ 1.5%. |
| 8 | (6–7) + responsive viewports (mobile, desktop). |
| 9–10 | (8) + light/dark mode baselines + CI fails on any diff above threshold. |

### D9 — Accessibility test coverage (NEW)

What it measures: axe-core integration into Playwright specs + zero violations.

| Score | Anchor |
|---|---|
| 0–2 | No axe-core integration. |
| 3–5 | axe-core wired but only on 1 page. |
| 6–7 | axe scan on every page in the read-only project; violations stored as artifact. |
| 8 | (6–7) + 0 critical/serious violations across all pages. |
| 9–10 | (8) + axe gate is a hard CI failure on regression. |

### D10 — Performance budget enforcement (NEW)

What it measures: Lighthouse CI run on the deployed site + Web Vitals thresholds (LCP / INP / CLS).

| Score | Anchor |
|---|---|
| 0–2 | No Lighthouse. |
| 3–5 | Lighthouse runs but no budgets. |
| 6–7 | Budgets: LCP < 4s, INP < 500ms, CLS < 0.25 on home page. |
| 8 | LCP < 2.5s, INP ≤ 200ms, CLS ≤ 0.1 on home + sale. |
| 9–10 | (8) + CI fails on regression + budgets defined for all 6 pages. |

## How this might be wrong

- D8 baseline drift is real — minor anti-aliasing differences across browsers will flake. Mitigate with `maxDiffPixelRatio: 0.005` + pinned chromium version.
- D9 axe-core occasionally reports false positives (e.g. region role missing on `<header>` in pages without main landmark). The rubric counts critical/serious only.
- D10 Lighthouse on Cloudflare Pages will score well by default; the real value is detecting regressions over time, not the absolute score.
