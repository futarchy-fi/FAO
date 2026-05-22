# Loop 001 — first improvement pass

**Started:** 2026-05-22 (after Phase-5 baseline)
**Coordinator:** claude (this session)
**Worker:** claude-direct (no codex worker for foundation lifts)
**Evaluators:** evaluator-{1..6} via cao+codex

## Lifts applied in this loop

| Lift | Rubric / dimension | Artifact |
|---|---|---|
| INVARIANTS.md | T3.D1 | audit/specs/INVARIANTS.md (15 INV-*, prose + predicates + status table) |
| @custom:spec NatSpec | T3.D6 | 12 NatSpec sites across InstanceSale, FAOOfficialProposalOrchestrator, FAOTwapResolver, FutarchyArbitration, GenericFutarchyToken |
| THREAT-MODEL.md | T3.D5 | audit/specs/THREAT-MODEL.md (A1–A16) |
| SECURITY.md | T5.D2 | audit/specs/SECURITY.md (admin model, mainnet migration plan, runbook) |
| preconditions/InstanceSale.md | T3.D3 | per-function PRE/POST/FRAME/REVERTS |
| InstanceSale.invariants.t.sol | T3.D2 + T4.D1 | 3 stateful Foundry invariants × 5000 runs each |
| [profile.ci] explicit | T4.D5 | foundry.toml |
| [profile.smtchecker] + [profile.halmos] | T3.D7 + T4.D6 | foundry.toml |
| .github/workflows/symbolic.yml | T4.D6 | Halmos + SMTChecker workflow |
| .github/workflows/static-analysis.yml | T4.D6 | Slither workflow |
| deployments.json | T5.D1 + T5.D5 | single source of truth for v5 |
| 21 data-testid attributes | T2.D5 | site-testnet/sale.html, create.html, index.html |
| F1..F10 journey scaffolds | T2.D1 + T2.D7 | tests-e2e/journeys/*.spec.ts |
| package.json + playwright.config.ts | T2.D3 | E2E harness scaffold |
| Modal helpers (faoConfirm/Prompt/Alert) | T1.D2 + T1.D5 | site-testnet/shared.js |
| a11y CSS (outline, focus-visible, prefers-reduced-motion) | T1.D5 | site-testnet/styles.css |
| Failing test fixed | T4.D5 | test/FAOOfficialProposalOrchestrator.t.sol::test_adapter_isReplaceableByAdmin |

## R1 vs R2 (independent codex evaluators)

| Topic | R1 min | R2 min | Δ min | R1 mean | R2 mean | Δ mean | Note |
|---|---|---|---|---|---|---|---|
| 1 — UX | 4.0 | 4.0 | +0.0 | 5.0 | 5.1 | +0.1 | D6 visual hierarchy still binding |
| 2 — Testing | 0.3 | 0.0 | **−0.3** | 1.7 | 1.7 | +0.0 | D4 failure-mode dropped; D5 selector +0.8 |
| 3 — Spec | 3.0 | 3.0 | +0.0 | 4.4 | 5.5 | +1.1 | invariant-explicitness still 3 — needs actual tests of more INV-* |
| 4 — SC infra | 3.2 | pending | — | 4.9 | pending | — | |
| 5 — Holistic | 2.0 | 3.0 | **+1.0** | 2.8 | 3.3 | +0.5 | SECURITY.md confirmed lift |
| 6 — Wiki | 5.0 | 4.0 | **−1.0** | 6.2 | 5.7 | −0.5 | **regression**: wiki didn't update after specs landed |

## Regressions surfaced

The evaluator's regression-detection mechanism caught two real signals:

1. **T6 (wiki) Δ −1.0** — codex flagged that `audit/wiki/10-fao-repo/invariants.md` is the stub it was at pass 0, even though the canonical `audit/specs/INVARIANTS.md` now exists. Convergence-signal dimension drops because no per-pass diff landed in `audit/wiki/`. Followup dispatch sent to the wiki-builder session to refresh.

2. **T2.D4 Δ −0.3** — failure-mode coverage went 0.3 → 0.0. Likely the evaluator was harsher this round (the rubric anchors require fork-realism evidence, which the new journey stubs add structure for but no executable test). Will revisit after Synpress lands.

3. **T6 Mode-Collapse Resistance Δ −0.8** — the codex flagged repetitive opening templates across wiki pages (pass-0 was machine-generated). The freshness dimension penalizes templated openings.

## Next loop targets (lowest binding sub-scores)

| Sub-score | R2 score | Action |
|---|---|---|
| T2.D4 — failure-mode coverage | 0.0 | Needs real Synpress tests of the wallet-rejection / wrong-chain / RPC-5xx paths. Multi-session work. |
| T2.D1 — user-flow coverage breadth | 0.5 | F1..F10 scaffold exists; needs first executable Synpress flow. |
| T2.D2 — test signal density | 0.6 | Real, asserting tests > useless tests; can't grow until F1..F10 land. |
| T2.D3 — fork realism | 0.5 | Anvil --fork-url + chain assertions via viem. |
| T6.D3 — convergence signal | 4.0 | Wiki refresh just dispatched. Re-score on R3. |
| T6.D6 — mode-collapse resistance | 4.4 | Refresh + diversify opening templates. |
| T3.D2 — invariant explicitness | 3.0 | More INV-* should graduate to TESTED (currently only INV-SALE-001 + INV-SALE-004 + INV-TOKEN-001). |
| T5.D2 — security posture | 5.0 | Reapply one-shot setAdapter for mainnet (Step A in SECURITY.md). |

## Time spent (loop 001)

- 6 research subagents (Phase 1): ~7 min real-time (parallel).
- 6 evaluator R1 dispatch + complete: ~6 min real-time.
- 6 evaluator R2 dispatch + complete: ~6 min real-time (4/6 done so far).
- Direct lifts (claude): ongoing across this session.
- Wiki refresh dispatch: just sent.

Total CAO codex sessions to date: 13 (1 wiki-builder + 6 R1 evaluators + 6 R2 evaluators).

## R3 → R4 → R5 (later rounds)

### R3 deltas (after preconditions × 5 + InstanceSale.proRata.invariants.t.sol)

| Topic | R2 min | R3 min | Δ min | Note |
|---|---|---|---|---|
| 1 | 4.0 | 4.7 | +0.7 | D6 lifted by tokens.css landing — still capped because tokens.css was dead-letter until R4 |
| 3 | 3.0 | 4.0 | +1.0 | D8 stays binding; D1 graduated to 8.0 |
| 6 | 4.0 | 6.5 | **+2.5** | wiki refresh successful — convergence + cross-link improvements |

### R4 deltas (after tokens.css unification, deployments.json wiring, btn-primary dedup, DEPRECATIONS.md, JOURNEY-MAP.md, failure-modes.read-only.spec.ts)

| Topic | R3 min | R4 min | Δ min | Highlights |
|---|---|---|---|---|
| 1 | 4.7 | 4.9 | +0.2 | D1 5→6.4 (primary dedup); D6 stayed low because tokens.css landed mid-run |
| 2 | 0.0 | 0.5 | +0.5 | D4 0→3.0 (failure-mode tests); D7 5.0→6.5 (journey map); D5 -0.3 regression |
| 3 | 4.0 | 4.0 | +0.0 | symbolic.t.sol landed after the eval was dispatched — expect R5 lift |
| 4 | 5.0 | 5.0 | +0.0 | R4 not yet landed for T4 at time of writing |
| 5 | 3.0 | 3.0 | +0.0 | D2/D3/D5 +0.2-0.5 each; D1 stays at 3 (deployments.json wiring landed mid-run) |
| 6 | 4.0 | 4.5 | +0.5 | **REGRESSION** on D3 (-2.7), D4 (-1.0), D6 (-1.4) — wiki fell behind repo HEAD |

T6 R4 regression detected: wiki-builder dispatched with a 6-point refresh agenda — DEPRECATIONS, SUPPLY-CHAIN, JOURNEY-MAP, symbolic test, btn-ghost demotion, deployments.json wiring.

### R5 dispatched (in flight) — covers: SUPPLY-CHAIN.md, RUNBOOK.md, InstanceSale.symbolic.t.sol

## Lifts applied since R2 (this session)

| Lift | Rubric / dimension | Artifact |
|---|---|---|
| preconditions/{FAOTwapResolver,InstanceSale,FutarchyArbitration,GenericFutarchyToken,FAOOfficialProposalOrchestrator}.md | T3.D3 | 5 per-contract PRE/POST/FRAME/REVERTS docs |
| InstanceSale.proRata.invariants.t.sol | T3.D2 + T4.D1 | 2 stateful invariants × 5000 calls |
| tokens.css authoritative (styles.css override removed) | T1.D6 | site-testnet/{tokens.css,styles.css} |
| .btn-ghost + .btn-primary dedup (1 per viewport) | T1.D1 | index.html + sale.html + styles.css |
| shared.js fetches deployments.json | T5.D1 | site-testnet/shared.js + scripts/check-deployments-sync.sh + workflow gate |
| DEPRECATIONS.md | T5.D3 | audit/state/DEPRECATIONS.md (DEPR-1..DEPR-8) |
| JOURNEY-MAP.md | T2.D7 | tests-e2e/JOURNEY-MAP.md (F1..F10 + read-only specs) |
| failure-modes.read-only.spec.ts | T2.D4 | 6 read-only tests of the deployments / RPC / empty-state paths |
| InstanceSale.symbolic.t.sol | T3.D8 | 3 Halmos `check_INV_*` proof obligations |
| SUPPLY-CHAIN.md | T5.D6 | audit/specs/SUPPLY-CHAIN.md (layers 0-4 trust boundaries) |
| RUNBOOK.md | T5.D4 | audit/state/RUNBOOK.md (daemons, logs, playbooks, failure modes) |

Total CAO codex sessions to date: 25 (1 wiki-builder + 18 evaluator runs across R1-R5 + 6 dispatched but not yet scored at R5).


## R6 / R7 status

### R6 deltas (post-DECIDABILITY/MUTATIONS/symbolic.yml fix)

| Topic | R5 min | R6 min | Δ min | Highlights |
|---|---|---|---|---|
| 1 | 4.9 | 4.9 | +0.0 | (R6 ran before tokens hex sweep landed) |
| 4 | 3.8 | 4.3 | **+0.5** | Mutation 3.8→4.3 (MUTATIONS.md); layer coverage 7.8→8.1 (symbolic test); tooling 7→7.6; CI gating 5→5.5 |
| 5 | 3.0 | 3.0 | +0.0 | D5 +0.1; D1 still capped at 3 (cross-topic floor) |

### R7 dispatched — covers: hex-color sweep, DEVELOPER.md, package.json scripts

### Cumulative state at end of session 2026-05-22

- **39 sub-scores total** across 6 topics.
- **3 sub-scores ≥ 8.0**: T3.D1 (8.0), T6.D2 (8.6), T4.D1 (8.1).
- **36 sub-scores still below target.**
- Deepest gap: **T2.D3 (fork realism) at 0.5** — blocked on Synpress wiring or fork-driven E2E.
- T4 the closest cluster: 4/6 dims ≥ 7.5; only mutation resistance + fork realism + CI gating below.
- T5 floor-bound by T2.D3 cap (the evaluator explicitly cited inter-topic caps).

### Lifts this session (R2 → R7 in flight)

| # | Lift | Rubric / dim | Commit |
|---|---|---|---|
| 1-5 | preconditions/{InstanceSale,FAOTwapResolver,FutarchyArbitration,GenericFutarchyToken,FAOOfficialProposalOrchestrator}.md | T3.D3 | 1932cea, df93305, c0d2bea, ee8dcf9, be03070 |
| 6 | InstanceSale.proRata.invariants.t.sol | T3.D2 + T4.D1 | 53b2cf1 |
| 7 | tokens.css authoritative + .btn-ghost + .btn-primary dedup | T1.D6 + T1.D1 | b56c8f3 |
| 8 | shared.js + deployments.json sync | T5.D1 | b807dab |
| 9 | DEPRECATIONS.md | T5.D3 | (b807dab subset) |
| 10 | failure-modes.read-only.spec.ts + JOURNEY-MAP.md | T2.D4 + T2.D7 | 94b91d1 |
| 11 | InstanceSale.symbolic.t.sol | T3.D8 | 5e1187e |
| 12 | SUPPLY-CHAIN.md | T5.D6 | 89a6f9f |
| 13 | RUNBOOK.md | T5.D4 | 1b12ea2 |
| 14 | MUTATIONS.md | T4.D3 | 132981b |
| 15 | DECIDABILITY.md + symbolic.yml check_INV_* fix | T3.D8 | 2e444c5 |
| 16 | tokens.css semantic state tokens (#hex sweep -44) | T1.D6 | e253784 |
| 17 | DEVELOPER.md + package.json scripts | T2.D6 | 4d29801 |

### Total CAO codex sessions

29 codex evaluator runs (R1-R7) + 2 wiki-builder dispatches.
