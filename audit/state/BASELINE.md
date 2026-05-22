# Baseline scores — Phase 1 self-evaluation (2026-05-22)

These are the **rubric authors' own** self-evaluations of the current `futarchy-fi/FAO` state, captured as a baseline before the Phase 6 improvement loop runs. Phase 5 will re-run independent Codex-backed CAO evaluators against the same rubrics to confirm / dispute these numbers.

| Topic | Dimensions | Min | Mean | Notes |
|---|---|---|---|---|
| 1 — Web3 UX | 6 (D1–D6) | **3.5** | 5.4 | Binds on D2 (wallet — native `alert/confirm/prompt`) and D5 (a11y — no `aria-live`, `outline:none` repeated, native modals) |
| 2 — Interface testing | 7 (D1–D7) | **0.07** | 0.07 | Zero E2E tests; only D7 gets 0.5 for prose journey inventory |
| 3 — Spec formalization | 8 (D1–D8) | **0.0** | 2.5 | D1 = 0 (no `audit/specs/`); D6 = 0 (no spec→impl IDs); other dims 3–5 |
| 4 — SC testing infra | 6 (D1–D6) | **2.5** | 3.9 | Has 244 unit tests + 1 invariant suite; missing fuzz / mutation / symbolic / Slither / coverage gates; 1 failing test on main |
| 5 — Holistic architecture | 6 (D1–D6) | **3.0** | 3.6 | D2 explicitly capped by topic-3 < 3 ∧ topic-4 < 3; deprecation entropy across v3→v4→v5 |
| 6 — LLM wiki | 6 (D1–D6) | **2.5** | 4.0 | Predicted v0; wiki doesn't exist yet |

**Total sub-scores: 39.** **System floor: 0.0** (T3.D1 + T3.D6 + T2 dims). **Mean of mins: 1.9.**

Per the goal directive, **every** sub-score must reach ≥ 8.0. That's a ~6-point lift on average, ~8-point lift on the weakest dimensions.

## Highest-leverage first targets (lowest-score → quickest wins)

| Sub-score | Score | Why it's low | First fix |
|---|---|---|---|
| T3.D1 — Spec doc existence | 0.0 | No spec artifact at all | Create `audit/specs/` with an initial invariants doc derived from `docs/onchain-futarchy-design.md` |
| T3.D6 — Spec ↔ impl traceability | 0.0 | No spec IDs cross-referenced | Number top-15 invariants and link from NatSpec |
| T2.D1 — User-flow coverage | 0.0 | Zero E2E tests | Stand up Anvil + Playwright + Synpress; cover F1 (create instance) end-to-end |
| T2.D3 — Fork realism | 0.0 | No fork-based tests | Same scaffold as T2.D1 |
| T2.D5 — Selector quality | 0.0 | No `data-testid` attrs | Add stable selectors as Playwright lands |
| T1.D2 — Wallet-state | 3.5 | Native `alert/confirm/prompt` x3 in `shared.js`, `bonds.js` | Replace with in-page status panels + `aria-live` |
| T1.D5 — a11y | 3.5 | `outline:none` x3; no `prefers-reduced-motion` | a11y sweep + token file |
| T4.D6 — Tooling diversity | 2.5 | Foundry-only | Add Slither + Halmos in CI (separate jobs) |

## Cross-rubric caps (binding)

- T5.D2 (security posture) capped at 4.0 by `min(T3, T4) < 3` — must lift T3 or T4 before T5.D2 can exceed 4.
- T6 every dim conditional on `audit/wiki/` existing — Phase 3 build precedes its first non-predicted score.

## Phase 6 loop strategy

Priority order = lowest sub-score first, but with two caveats:
1. **Cross-rubric caps:** lifting a capping topic (T3 or T4) unlocks T5 — prioritize the cap.
2. **Foundation-first:** spec → tests → infra → UI polish. Building UI a11y on top of a broken test layer is wasteful.
