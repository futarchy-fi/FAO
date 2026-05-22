---
canonical: audit/specs/DECIDABILITY.md
scope: Decidability assessment for the FAO invariants — which INV-* are decidable by SMTChecker / Halmos / forge fuzz within budget, which are not, and why.
not-scope: Invariant catalogue (`INVARIANTS.md`), mutation classes (`MUTATIONS.md`), threat model (`THREAT-MODEL.md`).
last-rebuilt: 2026-05-22
---

# Decidability of FAO invariants

T3.D8 (decidability-readiness, score 4.0) measures whether each
invariant has a written assessment of which symbolic / SMT engine can
decide it within a solver budget. This file is that assessment.

## Decision-engine matrix

| Engine | Strength | Weakness | Decides invariants of shape… |
|---|---|---|---|
| **forge fuzz / invariant** | Concrete-input enumeration; trivial setup | Probabilistic only; cannot prove | Stateful properties under unbounded sequences (best-effort) |
| **Halmos** | Symbolic; ranges over all bytecode inputs within `--loop N` | Storage size + dynamic arrays explode the symbolic state | Linear arithmetic; bounded loops; non-dynamic-array storage |
| **solc SMTChecker** | Built-in; Horn-clause backend (z3 / eldarica) | Whole-contract analysis; rejects most loops; slow | Constructor pre/post; pure functions; simple state transitions |
| **Certora** (not yet wired) | Strongest; high-level CVL spec language | Commercial license | Anything writable in CVL |

## Invariant → engine assignment

Each row cites the engine **expected** to decide that invariant within
budget, and what currently exists (E = engine, S = status: `decided`,
`undecided-bounded`, `undecided-open`, `gap`).

| INV-ID | Description | Engine | Status | Implementation |
|---|---|---|---|---|
| INV-TOKEN-001 | `totalSupply` only changes via mint/burn | Halmos | **decided** (within `--loop 3`) | `check_INV_TOKEN_001_supplyTracksHandlerOps` (`test/GenericFutarchyToken.symbolic.t.sol`) |
| INV-SALE-001 | `effectiveSupply == totalSupply − balanceOf(sale)` | Halmos | **decided** | `check_INV_SALE_001_initialState`, `check_INV_SALE_001_afterBuy` (`test/InstanceSale.symbolic.t.sol`) |
| INV-SALE-002 | Ragequit pays exactly `floor(ethBalance × burn / effSupply)` | Halmos | **undecided-bounded** (floor + multiplication overflows the linear-arithmetic fragment for large bounds) | Fuzz: `invariant_INV_SALE_002_ragequitPaysExactlyProRata` × 5000 calls |
| INV-SALE-003 | Per-effective-token ratio non-increasing | Halmos | **undecided-bounded** (same overflow as INV-SALE-002) | Fuzz: `invariant_INV_SALE_002_ratioNonIncreasing` × 5000 calls |
| INV-SALE-004 | `initialPhaseFinalized` once-true-stays-true | Halmos | **decided** | `check_INV_SALE_004_initialPhaseFinalizedSticky` (`test/InstanceSale.symbolic.t.sol`) |
| INV-ARB-001 | `nextProposalId` strictly monotonic | Halmos | **decided** | `check_INV_ARB_001_idMonotone` (`test/FutarchyArbitration.symbolic.t.sol`) |
| INV-ARB-002 | `settled := true` is irreversible | Halmos | **decided** | `check_INV_ARB_002_settledMonotone` (`test/FutarchyArbitration.symbolic.t.sol`) |
| INV-ARB-003 | Bond-treasury conservation | Halmos | **undecided-open** (dynamic loops over `withdrawable[]` mapping; symbolic key) | Fuzz: planned |
| INV-ARB-004 | Strict bond matching | Halmos | **decided** | `check_INV_ARB_004_matchedBondsCorrespond` (`test/FutarchyArbitration.symbolic.t.sol`) |
| INV-ARB-005 | Graduation reachability | Halmos | **undecided-open** (existential — needs Halmos `find` mode) | Reachability prose only |
| INV-ARB-006 | Safety-mode threshold gating | Halmos | **decided** | `check_INV_ARB_006_safetyModeBlocksTimeout` (`test/FutarchyArbitration.symbolic.t.sol`) |
| INV-ORCH-001 | Atomic promote — rollback envelope | SMTChecker | **undecided-bounded** (cross-function dependency; SMTChecker needs `--show-unproved`) | Foundry concrete tests |
| INV-ORCH-002 | Refuse pre-initialized pool | SMTChecker / Halmos | **decided** | Planned `check_INV_ORCH_002_refusesPreInit` |
| INV-TWAP-001 | Resolver anchor monotonicity | Halmos | **decided** | Planned `check_INV_TWAP_001_anchorMonotone` |
| INV-TWAP-002 | TWAP window respects observation cardinality | Halmos | **undecided-bounded** (`observe`-tuple arithmetic outside the linear fragment) | Foundry fork tests |

## Bounded surfaces

Symbolic engines need finite state. The FAO suite uses the following
bounds when running under `FOUNDRY_PROFILE=halmos`:

- Loop unroll: `--loop 3` (sufficient for most fuzz-equivalent properties).
- Array bound: handlers cap dynamic arrays at 5-10 elements (e.g.
  `ProRataHandler.buyers` is 5 in the proRata invariant suite).
- Phase bound: each test exercises buy → ragequit transitions at most
  10 deep, well within solver budget.

**Known unbounded surfaces** (Halmos will time out):
- The `ragequit-token loop` inside `InstanceSale.ragequit` iterates over
  the dynamic `ragequitListedTokens` array. Halmos cannot bound this
  symbolically; the per-token loop body must be unrolled manually for
  fixed bounds (e.g. token list size ≤ 3).
- `_queuedCount` iterates over all proposals; for symbolic analysis we
  bound `nextProposalId` to ≤ 6.

## Counterexample-citation discipline

Every `check_INV_*` function MUST have a corresponding line in this
file. Halmos failures get a counterexample dump; the dump is committed
under `audit/counterexamples/INV-*-<sha>.txt` so the evaluator can
verify the engine actually ran (not just the assertion was written).

Today no counterexamples are committed (all current `check_INV_*`
functions pass under default budget); the directory exists in
`audit/counterexamples/` (currently empty — `.gitkeep`).

## Roadmap to "fully decided"

To bring T3.D8 above 8.0 the suite needs:

1. **`check_INV_*` for every invariant where the table above says
   "decided"** — today only 4/15. Each is a 20-line write.
2. **Bounded-loop variants** for the 4 "undecided-bounded" invariants
   — write versions with `--ragequitListedTokens.length <= 1`
   constraint and let Halmos decide that case.
3. **Counterexample-archive directory** wired into the symbolic.yml
   workflow so regressions land as committed evidence.
4. **Certora spec** (optional) for the 2 "undecided-open" invariants
   that involve genuine existential / reachability questions
   (INV-ARB-005 in particular).

## How this might be wrong

- "Decided within budget" is an empirical claim — solvers don't always
  finish in the same time on the same input. The matrix should be
  regenerated whenever the solver-timeout-assertion is changed.
- INV-SALE-002's "undecided-bounded" status is from the
  multiplication-by-symbolic-input pattern. With Halmos' `bv-add` and
  `--smt-div` enabled it may actually decide; needs an empirical run.
- INV-TWAP-002's "outside linear fragment" claim is based on UniV3's
  `observe` tuple arithmetic; Halmos may or may not handle this
  depending on how the UniV3 contracts are inlined.

## See also

- `audit/specs/INVARIANTS.md` — the 15 INV-* under test.
- `test/InstanceSale.symbolic.t.sol` — current `check_INV_*` surface.
- `.github/workflows/symbolic.yml` — Halmos + SMTChecker CI driver.
- `foundry.toml` `[profile.halmos]` — solver settings.
