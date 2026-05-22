# Baseline scores

## Independent baseline (Phase 5, codex evaluators)

Captured 2026-05-22 from `audit/evaluations/topic-{1..6}-evals.jsonl`. Each topic's min is the binding sub-score — that's the one Phase 6 must lift.

| Topic | Min | Mean | Weakest dimension | Notes |
|---|---|---|---|---|
| 1 — Web3 UX | **4.0** | 5.0 | D6 — Visual hierarchy + minimalism | D2 wallet & D5 a11y already lifted by foundation pass |
| 2 — Interface testing | **0.3** | 1.7 | D4 — Failure-mode coverage | Zero real E2E tests; Playwright scaffold only |
| 3 — Spec formalization | **3.0** | 4.4 | D2 — Invariant explicitness | INVARIANTS.md exists; just lifted by invariant tests |
| 4 — SC testing infra | **3.2** | 4.9 | D6 — Tooling diversity | Foundry + Slither only; needs Halmos / Echidna / Vertigo |
| 5 — Holistic | **2.0** | 2.8 | D2 — Security posture | Single key + no timelock + v3/v4 deprecation entropy |
| 6 — LLM wiki | **5.0** | 6.2 | D3 — Convergence signal | First pass; needs subsequent passes to demonstrate convergence |

**System floor: 0.3.** **Mean of mins: 2.92.**

## Lift target

Every sub-score → ≥ 8.0.
- Worst-case lift: 7.7 points (T2.D4: 0.3 → 8.0).
- Mean lift required: ~5.1 points.

## Phase-1 (rubric self-eval) vs Phase-5 (independent codex)

The Phase-1 self-evaluations were the rubric authors' own estimates. The Phase-5 codex evaluators corroborate the overall shape but score consistently higher (the foundation lifts I applied between Phase 1 and Phase 5 are visible in the numbers).

| Topic | Phase-1 min | Phase-5 min | Δ |
|---|---|---|---|
| 1 | 3.5 | 4.0 | +0.5 (a11y lift, modal helpers) |
| 2 | 0.07 | 0.3 | +0.23 (Playwright scaffold + SELECTORS.md) |
| 3 | 0.0 | 3.0 | +3.0 (INVARIANTS.md + @custom:spec NatSpec) |
| 4 | 2.5 | 3.2 | +0.7 (Slither workflow + ci profile) |
| 5 | 3.0 | 2.0 | −1.0 (foundation lifts surfaced more issues the codex evaluator caught) |
| 6 | predicted 2.5 | 5.0 | +2.5 (wiki actually exists now) |

T5 going DOWN is interesting: the codex evaluator was harsher about the deprecation entropy (v3/v4 broadcast files still in tree, UI hardcoded addresses) than the rubric author was. Worth investigating in the loop — could be a regression-detection signal.

## Phase 6 strategy

Priority queue (lowest sub-score first, with cross-rubric caps):

1. **T2.D4 (0.3)** — failure-mode coverage. Needs Synpress + chain-state assertions.
2. **T2.D1 (0.5)** — user-flow coverage breadth.
3. **T2.D3 (0.5)** — fork realism.
4. **T2.D2 (0.6)** — test signal density.
5. **T5.D2 (2.0)** — security posture (capped by T3 + T4).
6. **T2.D6 (2.0)** — performance / cycle time.
7. **T5.D3 (2.8)** — deprecation hygiene.
8. **T3.D2 (3.0)** — invariant explicitness (already partly lifted).
9. **T3.D3 (3.0)** — pre/postcondition coverage.
10. **T5.D1 (3.0)** — architectural coupling.

T2 dominates. Realistic next session focus: dedicate one full pass to T2 (Playwright + Synpress + 5+ real journey tests with chain-state assertions). That should lift T2 min from 0.3 → 5-6.
