---
canonical: audit/specs/INVARIANTS.md
scope: Enumerated, ID'd, dual-stated invariants for `futarchy-fi/FAO`. Each entry is prose + a one-line predicate referencing concrete source. Pre/postcondition coverage and per-function spec lives in `audit/specs/preconditions/` (one file per contract).
not-scope: Threat model (see `audit/specs/THREAT-MODEL.md`), test implementation (see `test/`).
last-rebuilt: 2026-05-22
---

# FAO — Top-15 Invariants

This document is the **single source of truth** for the system's load-bearing invariants. Every invariant has:

- A **stable ID** (`INV-<MODULE>-<NNN>`).
- A **prose statement** (what must hold, always).
- A **machine-checkable predicate** (Solidity-shaped Foundry/Certora-friendly).
- A **citation** to the implementing code.
- A **status**: `STATED` (this doc only) → `TESTED` (Foundry `invariant_*`) → `PROVED` (Certora / Halmos / Kontrol).

Once an invariant graduates to `TESTED`, the implementing NatSpec MUST cite the ID inline (`@spec INV-...`). Once it's `PROVED`, the proof artifact MUST cite the ID too. This is the spec ↔ implementation traceability check that Topic 3 rubric D6 measures.

---

## INV-TOKEN-001 — Token supply monotonicity (mint and burn only)

**Prose.** `FAOToken.totalSupply` (and `GenericFutarchyToken.totalSupply`) changes only via `mint` (gated by `MINTER_ROLE`) and `burn` (`ERC20Burnable`). No other code path mutates it.

**Predicate.**
```
∀ tx t:
  totalSupply'(t) - totalSupply(t)
    = (Σ minted_in(t)) - (Σ burned_in(t))
```
With `minted_in` summing the `Transfer(0x0, *, value)` events and `burned_in` summing the `Transfer(*, 0x0, value)` events.

**Cite.** `src/FAOToken.sol`, `src/GenericFutarchyToken.sol:32-37` (mint hook), and the inherited OZ `ERC20Burnable` `burn`/`burnFrom`.

**Status:** STATED.

---

## INV-SALE-001 — Effective supply formula

**Prose.** For any `InstanceSale` instance, in every reachable state, `effectiveSupply()` equals `max(0, TOKEN.totalSupply() − TOKEN.balanceOf(address(this)))`. The sale's own token balance is excluded so freshly-minted-for-LP tokens (held briefly inside `seedLiquidityManager`) do not dilute the ETH share of ragequitters.

**Predicate.**
```
let total = TOKEN.totalSupply()
let saleHeld = TOKEN.balanceOf(address(sale))
sale.effectiveSupply() == (total > saleHeld ? total - saleHeld : 0)
```

**Cite.** `src/InstanceSale.sol:125-133`.

**Status:** STATED. Existing read-only assertion target; testable as a Foundry property after a state-mutating handler.

---

## INV-SALE-002 — Ragequit pro-rata payout

**Prose.** For every successful call `sale.ragequit(n)`:

1. `msg.sender` receives exactly `floor(address(sale).balance * n * 1e18 / effectiveSupply)` wei of ETH (donated dust stays in the sale).
2. `effectiveSupply` decreases by `n * 1e18`.
3. `TOKEN.totalSupply` decreases by `n * 1e18`.
4. For every entry `r` in `ragequitTokens[]` with `isRagequitToken[r] == true`, the caller additionally receives `floor(IERC20(r).balanceOf(sale) * n * 1e18 / effectiveSupply)` of `r`.

**Predicate (sketch).**
```
let pre  = snapshot(sale, msg.sender, ragequitTokens)
sale.ragequit(n)
let post = snapshot(sale, msg.sender, ragequitTokens)

ethShare   = floor(pre.ethBalance * n * 1e18 / pre.effectiveSupply)
assert post.msg.sender.eth == pre.msg.sender.eth + ethShare - gasCost
assert post.effectiveSupply == pre.effectiveSupply - n * 1e18
assert post.totalSupply     == pre.totalSupply     - n * 1e18
for r in ragequitTokens where isRagequitToken[r]:
    rShare = floor(IERC20(r).balanceOf(sale_pre) * n * 1e18 / pre.effectiveSupply)
    assert IERC20(r).balanceOf(msg.sender)_post == IERC20(r).balanceOf(msg.sender)_pre + rShare
```

**Cite.** `src/InstanceSale.sol:188-226`.

**Status:** STATED. Unit-tested for the ETH portion in `test/InstanceSale.t.sol::test_ragequit_*`; ERC20 portion needs a multi-token property test.

---

## INV-SALE-003 — Ragequit guards

**Prose.** `ragequit(n)` MUST revert when **any** of the following holds:

- `msg.sender == address(this)` (self-ragequit).
- `effectiveSupply == 0` (nothing to share).
- `n * 1e18 > effectiveSupply` (over-claim).

**Predicate.** Logical disjunction of the three pre-conditions ⇒ revert.

**Cite.** `src/InstanceSale.sol:188-201`.

**Status:** STATED. Unit-tested in `test/InstanceSale.t.sol`.

---

## INV-SALE-004 — Initial-phase monotonicity

**Prose.** `initialPhaseFinalized` is monotone — it transitions exactly once from `false` to `true` and never resets. Once `true`, `initialNetSale` is frozen and `INITIAL_PRICE_WEI_PER_TOKEN` is no longer the active per-token price (bonding-curve takes over).

**Predicate.**
```
∀ t:
  initialPhaseFinalized(t) ⇒ initialPhaseFinalized(t+1)
  initialPhaseFinalized'(t) ∧ ¬initialPhaseFinalized(t) ⇒ initialNetSale'(t) is set and frozen
```

**Cite.** `src/InstanceSale.sol:170-180`, `src/FAOSale.sol:46-56`.

**Status:** STATED.

---

## INV-ARB-001 — Proposal id monotonicity

**Prose.** `FutarchyArbitration.nextProposalId` is strictly monotonically increasing across all writes. For every existing proposal id `p < nextProposalId`, `proposals[p].exists == true`, and the only writer of `proposals[p]` for `exists := true` is the internal `_initProposal`.

**Predicate.**
```
∀ tx t: nextProposalId(t+1) >= nextProposalId(t)
∀ p < nextProposalId: proposals[p].exists == true
write-set of `proposals[p].exists := true` ⊆ { _initProposal }
```

**Cite.** `src/FutarchyArbitration.sol:88, 192-213, 497-507`.

**Status:** TESTED (`test/FutarchyArbitration.invariants.t.sol::invariant_INV_ARB_001_nextProposalIdMonotonic`).

---

## INV-ARB-002 — Settlement irreversibility

**Prose.** For every proposal `p`:
- `proposals[p].state == SETTLED ⇒ proposals[p].settled == true`.
- Once `settled == true`, the state never leaves `SETTLED`.
- `accepted` is immutable after settlement.

**Predicate.**
```
∀ t, ∀ p: state(t,p) == SETTLED ⇒ settled(t,p) == true
∀ t, ∀ p: settled(t,p) ⇒ settled(t+1,p) ∧ state(t+1,p) == SETTLED ∧ accepted(t+1,p) == accepted(t,p)
```

**Cite.** `src/FutarchyArbitration.sol:312-346, 395-419`.

**Status:** TESTED (`test/FutarchyArbitration.invariants.t.sol::invariant_INV_ARB_002_settledIrreversible`).

---

## INV-ARB-003 — Bond-treasury equality (strengthening)

**Prose.** At every block boundary, the arbitration contract's WETH balance equals the sum of (a) all withdrawable refunds, plus (b) all unsettled YES + NO bonds.

**Predicate.**
```
WETH.balanceOf(arbitration)
  == Σ_i withdrawable[i]
   + Σ_{p unsettled} (yesBond[p].amount + noBond[p].amount)
```

**Cite.** `src/FutarchyArbitration.sol` + `test/FutarchyArbitration.invariants.t.sol::invariant_INV_ARB_003_bondTreasuryConserved`.

**Status:** TESTED (`test/FutarchyArbitration.invariants.t.sol::invariant_INV_ARB_003_bondTreasuryConserved`).

---

## INV-ARB-004 — NO-bond strict matching

**Prose.** A call to `placeNoBond` always sets `noBond.amount` to exactly the previous `yesBond.amount` of the same proposal — never more, never less.

**Predicate.**
```
after placeNoBond(p):
  noBond[p].amount == previous yesBond[p].amount
```

**Cite.** `src/FutarchyArbitration.sol:278-303`.

**Status:** TESTED (`test/FutarchyArbitration.invariants.t.sol::invariant_INV_ARB_004_strictNoBondMatching`).

---

## INV-ARB-005 — Graduation reachability

**Prose.** For any state with `_queuedCount() == k`, a YES-bond amount of at least `baseX * 2^k` graduates the proposal regardless of the current NO-bond state.

**Predicate.**
```
_queuedCount() == k ∧ yesBond[p].amount >= baseX * (2 ^ k) ⇒ canGraduate(p) == true
```

**Cite.** `src/FutarchyArbitration.sol:227-271, 355-358`.

**Status:** STATED.

---

## INV-ARB-006 — Safety-mode equivalence

**Prose.** `safetyModeActive()` returns true iff the sum of active NO-state bond amounts is at least `baseX`. When safety mode is active, `finalizeByTimeout` MUST revert for any timed-out YES-state proposal.

**Predicate.**
```
safetyModeActive() == ( Σ_{p.state == NO} noBond[p].amount >= baseX )
safetyModeActive() ∧ state(p) == YES ∧ timedOut(p) ⇒ finalizeByTimeout(p) reverts
```

**Cite.** `src/FutarchyArbitration.sol:312-346, 481-491`.

**Status:** TESTED (`test/FutarchyArbitration.invariants.t.sol::invariant_INV_ARB_006_safetyModeThresholdGating`).

---

## INV-ORCH-001 — Atomic promote-with-migrate

**Prose.** `FAOOfficialProposalOrchestrator.createOfficialProposalAndMigrate` is atomic across all phases (proposal creation, condition prep, wrapper deploy, pool create/init, observation cardinality warm, adapter migration, builder TIP). Any revert in any phase ⇒ entire post-state equals pre-state, including `block.coinbase` balance.

**Predicate.**
```
let pre  = chain snapshot before tx
tx createOfficialProposalAndMigrate(...)
if any internal call reverts:
   chain state == pre   (including block.coinbase ETH balance)
else:
   all 8 phases' postconditions hold simultaneously
```

**Cite.** `src/FAOOfficialProposalOrchestrator.sol:121-178`.

**Status:** STATED.

---

## INV-ORCH-002 — Pre-init pool defense

**Prose.** At the start of `_maybeCreatePoolAndInit`, if a pool already exists at the deterministic CREATE2 address and `slot0().sqrtPriceX96 != 0`, the call MUST revert (`SpotPoolAlreadyExists`). The orchestrator never operates on an attacker-initialized pool.

**Predicate.**
```
∀ proposal p:
  let pool = UNIV3_FACTORY.getPool(token, WETH, FEE_TIER)
  pool != 0 ∧ IUniswapV3Pool(pool).slot0().sqrtPriceX96 != 0
    ⇒ _maybeCreatePoolAndInit(...) reverts with SpotPoolAlreadyExists
```

**Cite.** `src/FAOOfficialProposalOrchestrator.sol:204-228`, `src/FutarchyRegistry.sol:_createAndInitSpotPool` (same predicate for the registry's spot pool).

**Status:** STATED.

---

## INV-TWAP-001 — Window fixity

**Prose.** `bindings[p].anchorTimestamp` is set **exactly once** (immutable after the first non-zero write). `resolve(p)` always measures the TWAP over the closed interval `[anchor + TIMEOUT - TWAP_WINDOW, anchor + TIMEOUT]`, regardless of `block.timestamp` at resolve time. The resolution window is a function of the binding, not of when resolve runs.

**Predicate.**
```
∀ p: write-set of `bindings[p].anchorTimestamp := x` for x != 0 has cardinality at most 1
∀ p, ∀ time of resolve(p):
  window_used == [anchor + TIMEOUT - TWAP_WINDOW, anchor + TIMEOUT]
```

**Cite.** `src/FAOTwapResolver.sol:91-115, 162-198`.

**Status:** STATED.

---

## INV-TWAP-002 — Resolution determinism

**Prose.** `resolve(p)` flips `bindings[p].resolved` from false to true exactly once and sets `accepted` in the same storage write. Both fields are immutable thereafter. A re-resolution attempt MUST revert with `AlreadyResolved`.

**Predicate.**
```
∀ p:
  resolved(p, t)' ∧ ¬resolved(p, t) ⇒ accepted(p, t+1) is set and frozen
  resolved(p, t) ⇒ resolve(p) reverts
```

**Cite.** `src/FAOTwapResolver.sol:117-144`, `src/FutarchyTWAPOracle.sol:187-217`.

**Status:** STATED.

---

## Bonus stretch invariants (post top-15)

These are listed in the rubric research as worth stating once the top-15 are in place. Stubs for future passes:

- **INV-ADP-001** — Adapter staging single-use (anti-replay).
- **INV-ADP-002** — Callback authorization (only the UniV3 pool callback can transfer).
- **INV-TWAP-003** — TWAP normalization correctness (sqrtPrice → tick → price).
- **INV-CTF-001** — CTF split / merge conservation (assumed — vendored from Gnosis).
- **INV-W1155-001** — Wrapped1155 1:1 wrap (assumed — vendored).
- **INV-UNIV3-001** — `tickCumulative` monotonicity (assumed — UniV3 invariant).

---

## Spec → impl traceability

The following changes are required to score INV-TRACE on Topic 3 D6:

1. Every NatSpec on the cited line ranges MUST gain a `@spec INV-...` tag pointing at the ID.
2. Every Foundry `invariant_*` test MUST start with `// @spec INV-...` and the test function name SHOULD include the ID suffix (e.g. `invariant_INV_SALE_001_effectiveSupplyFormula`).
3. Every Certora rule MUST set `// rule_id: INV-...` in its frontmatter.

A worker pass in Phase 6 will sweep `src/` and `test/` and attach these tags.

## Pass status

| ID | STATED | TESTED | PROVED |
|---|---|---|---|
| INV-TOKEN-001 | ✓ | partial (token unit tests) | — |
| INV-SALE-001 | ✓ | ✓ (`InstanceSale.t.sol::test_effectiveSupply_*`) | — |
| INV-SALE-002 | ✓ | partial (ETH only — `test_ragequit_ETHOnly`) | — |
| INV-SALE-003 | ✓ | ✓ (`test_ragequit_revertsOn*`) | — |
| INV-SALE-004 | ✓ | partial | — |
| INV-ARB-001 | ✓ | ✓ (`invariant_INV_ARB_001_nextProposalIdMonotonic`) | — |
| INV-ARB-002 | ✓ | ✓ (`invariant_INV_ARB_002_settledIrreversible`) | — |
| INV-ARB-003 | ✓ | ✓ (`invariant_INV_ARB_003_bondTreasuryConserved`) | — |
| INV-ARB-004 | ✓ | ✓ (`invariant_INV_ARB_004_strictNoBondMatching`) | — |
| INV-ARB-005 | ✓ | — | — |
| INV-ARB-006 | ✓ | ✓ (`invariant_INV_ARB_006_safetyModeThresholdGating`) | — |
| INV-ORCH-001 | ✓ | — | — |
| INV-ORCH-002 | ✓ | — | — |
| INV-TWAP-001 | ✓ | — | — |
| INV-TWAP-002 | ✓ | — | — |

**Phase 6 priority:** finish the partial TESTED entries, then add the missing TESTED rows. PROVED column is a v0.1 goal once Certora/Halmos is wired (Topic 4 D2 + D6).

---

## How this document is maintained

This is an authored spec, not a generated one. Updates happen in two ways:

- **Manual:** when a developer makes a code change that breaks or strengthens an invariant, they update this doc in the same PR. PR checklist: "If your change touches a function cited in `audit/specs/INVARIANTS.md`, did you update the cite or the invariant?"
- **CAO sweep:** the Phase 6 spec-formalization worker re-reads source and proposes diffs to this doc (drift detection). Diffs land via PR for human review — never auto-merged.

## See also

- `audit/rubrics/topic-3-spec-formalization.md` — the rubric that grades this doc.
- `audit/research/topic-3-spec-formalization.md` — research backing.
- `test/FutarchyArbitration.invariants.t.sol` — the existing partial implementation.

## How this might be wrong

- The line-range citations are SHA-pinned at write time (HEAD on 2026-05-22). They will drift if the contracts move. A weekly CAO sweep should re-pin.
- INV-ORCH-001's atomicity claim assumes the EVM's standard tx semantics — it does NOT cover cross-tx reorg attacks (mainnet finality assumption).
- INV-TWAP-001 and INV-TWAP-002 inherit from `IUniswapV3Pool.observe()` correctness, which is an external assumption.
- The "bonus" invariants section is intentionally less rigorous; treat as v0.1 work, not a blocking gap.
