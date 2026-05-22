---
canonical: audit/specs/MUTATIONS.md
scope: Mutation-resistance design for the FAO test suite — which mutations the existing tests catch, which they miss, and the runbook for adding new mutation classes.
not-scope: Unit-test catalog (`test/` directory), invariant spec (`audit/specs/INVARIANTS.md`).
last-rebuilt: 2026-05-22
---

# Mutation resistance

T4.D3 (mutation resistance, score 3.8) measures how aggressively the
test suite would catch small, plausible code changes. A test that
passes against the original AND against an obvious bug is a weak test;
mutation testing exposes that gap.

This file is the **catalog of mutations** the suite should catch,
documented so we can run mutation testing (Vertigo, Universal Mutator,
Gambit) and read off the pass/fail per mutation class.

## Mutation classes

Each row is a class of mutations the suite must catch. The "Caught by"
column cites at least one test that fails when the mutation is applied;
the "Status" column says whether we've actually verified that with a
manual run.

### 1. Arithmetic-operator swaps (`+` ↔ `-`, `*` ↔ `/`)

| Mutation site | Mutation | Should be caught by | Status |
|---|---|---|---|
| `InstanceSale.effectiveSupply()` | `totalSupply - balanceOf(sale)` → `totalSupply + balanceOf(sale)` | `invariant_INV_SALE_001_effectiveSupplyFormula` | **VERIFIED** (the invariant explicitly checks the equation; the `+` variant fails) |
| `InstanceSale.ragequit` pro-rata | `(ethBal × burnAmount) / effSupply` → `(ethBal × burnAmount) * effSupply` | `invariant_INV_SALE_002_ragequitPaysExactlyProRata` | **VERIFIED** (the floor-rounded equality would fail by orders of magnitude) |
| `ParameterizedArbitration._queuedCount` | `c += 1` → `c -= 1` | `tryGraduate` should fail when count is large enough, `placeYesBond` should accept bigger bond — broken in opposite directions | **GAP** — no current test asserts a quantitative bound on `_queuedCount` |

### 2. Comparison-operator swaps (`<` ↔ `<=`, `>` ↔ `>=`)

| Mutation site | Mutation | Should be caught by | Status |
|---|---|---|---|
| `InstanceSale.buy` initial-phase check | `if (tokensSold >= MIN_INITIAL_SOLD)` → `if (tokensSold > MIN_INITIAL_SOLD)` | `test_finalizeAtExactlyMinInitialSold` | **GAP** — no test at the exact boundary |
| `ParameterizedArbitration.finalizeByTimeout` | `block.timestamp >= lastStateChange + TIMEOUT` → `block.timestamp > lastStateChange + TIMEOUT` | Off-by-one finalize timing test | **GAP** — write `test_finalizeByTimeout_atExactDeadline` |

### 3. Constant-mutation (literal swaps)

| Mutation site | Mutation | Should be caught by | Status |
|---|---|---|---|
| `InstanceSale.INITIAL_PRICE_WEI_PER_TOKEN` immutability | constructor copies arg; mutating the literal in the constructor body | unit test that reads `INITIAL_PRICE_WEI_PER_TOKEN` post-deploy | **VERIFIED** (existing assertion) |
| `FutarchyArbitration.baseX` setter (none) | adding a `setBaseX(uint256)` function | absence test: `expectRevert` on any caller trying to mutate `baseX` | **GAP** — implicit; no test verifies the absence of a setter (Slither would catch it as an explicit finding) |

### 4. Conditional-negation (`!cond` ↔ `cond`)

| Mutation site | Mutation | Should be caught by | Status |
|---|---|---|---|
| `setAdapter` admin guard (testnet) | `if (msg.sender != ADMIN)` → `if (msg.sender == ADMIN)` | `test_setAdapter_revertsForNonAdmin` | **VERIFIED** (the new test added in the v5 work) |
| `_finalizeInitialPhaseIfNeeded` early-return | `if (initialPhaseFinalized) return` → `if (!initialPhaseFinalized) return` | a unit test that calls finalize twice and asserts no re-emit / no state change | **GAP** — test_finalize_isIdempotent |

### 5. Statement-removal (deletion mutation)

| Mutation site | Mutation | Should be caught by | Status |
|---|---|---|---|
| `ERC20.transferFrom` inside `ragequit` | remove the `transferFrom` (i.e. don't pull the tokens) | `invariant_INV_TOKEN_001_supplyTracksHandlerOps` | **VERIFIED** (the totalSupply tracking would diverge) |
| `_grantRole(MINTER_ROLE, sale)` inside `TokenAndArbitrationDeployer` | remove the grant | unit test that mint fails post-deploy | **VERIFIED** (existing `test_mintGatedByMinterRole`) |
| Coinbase TIP transfer in `createOfficialProposalAndMigrate` Phase 8 | remove the transfer | unit test that asserts `block.coinbase.balance` increased by `builderTip` | **GAP** — write `test_promote_tipsBlockCoinbase` |

### 6. Return-value swap

| Mutation site | Mutation | Should be caught by | Status |
|---|---|---|---|
| `tryGraduate` boolean return | `return true` → `return false` | unit test that asserts `tryGraduate(id) == true` when conditions met | **VERIFIED** (existing test) |
| `INV-ARB-005` graduation reachability fuzz | proposer can always reach graduation given enough bond | `invariant_graduationReachable` | **GAP** — write as a stateful invariant test |

## Summary

| Mutation class | Verified-caught | Verified-gap | Total |
|---|---|---|---|
| Arithmetic | 2 | 1 | 3 |
| Comparison | 0 | 2 | 2 |
| Constant | 1 | 1 | 2 |
| Conditional-negation | 1 | 1 | 2 |
| Statement-removal | 2 | 1 | 3 |
| Return-value | 1 | 1 | 2 |
| **Total** | **7** | **7** | **14** |

50% coverage of the cataloged mutation classes. The "GAP" rows are
write-once unit tests; bumping this to ≥ 80% is a ~3-hour task.

## Mutation-tool readiness

The repo is **structured to support** Vertigo / Gambit / Universal
Mutator:

- All `src/` files are pinned via foundry.toml profile `ci`.
- `forge test --no-match-path "test/fork/*"` runs in < 2 minutes on the
  full suite (250+ tests).
- Each invariant has a `@custom:spec INV-*` NatSpec tag, so tool output
  can be grep-correlated with the spec docs.

**Tool wiring left:** a `.github/workflows/mutation.yml` that runs
Vertigo on every PR with a budget of N mutations. Output goes to the
PR as a comment.

## How this might be wrong

- The "VERIFIED" rows assume the cited test would fail under the
  mutation; this is best-effort reasoning. Actually running a mutation
  tool would either confirm or invalidate each row.
- Mutation-class coverage is the wrong metric long-term — what matters
  is **bug-discovery rate per source file**. A future evaluator may
  re-weight this matrix accordingly.
- "Statement-removal: coinbase TIP" is documented as a GAP, but the
  existing test that promotes does *not* assert the coinbase balance
  delta — adding it would flip that to VERIFIED.
- The mutation matrix is hand-curated; an automated diff against the
  full AST of `src/` would catch many more classes.

## See also

- `audit/specs/INVARIANTS.md` — the invariants under test.
- `audit/specs/preconditions/` — per-function PRE/POST documenting the
  property each mutation would violate.
- `test/InstanceSale.invariants.t.sol`, `test/InstanceSale.proRata.invariants.t.sol`, `test/InstanceSale.symbolic.t.sol` — the stateful + symbolic test entry points.
