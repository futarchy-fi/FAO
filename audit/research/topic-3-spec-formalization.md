# Topic 3 — Spec Formalization for FAO (Continuous Auditing & Optimization)

> *Scope: best practices for formalizing specs so the codebase **becomes ready** for
> formal verification (Certora / SMTChecker / hevm / Halmos / Kontrol / TLA+).
> This is the scaffolding work — not the proofs themselves. The output is what an
> engineer would write **before** turning a verification tool on.*

The application under review is `futarchy-fi/FAO` (multi-instance futarchy DAO on
Sepolia). Key surface area:

- `src/FAOToken.sol`, `src/GenericFutarchyToken.sol` — ERC-20 + burnable + role-gated mint.
- `src/FAOSale.sol`, `src/InstanceSale.sol` — bonding-curve sale + pro-rata ragequit.
- `src/FAOOfficialProposalOrchestrator.sol` — atomic promote: create CTF condition,
  deploy/initialize YES & NO Uniswap V3 pools, increase observation cardinality,
  bind resolver, optionally migrate liquidity.
- `src/UniswapV3LiquidityAdapter.sol` — pulls staged collateral from `tx.origin`,
  splits via Gnosis CTF, wraps to ERC-20 via Wrapped1155, mints full-range UniV3.
- `src/FAOTwapResolver.sol`, `src/FutarchyTWAPOracle.sol` — read tick cumulatives,
  decide accepted = (yesAvgTick > noAvgTick [+ threshold]), report payouts to CTF.
- `src/FutarchyArbitration.sol` — bond-escalation game, graduation queue,
  evaluator handoff, pull-payment withdrawals.
- `src/FutarchyEvaluator.sol`, `src/EvaluationPipeline.sol`, `src/CtfRouter.sol` —
  evaluator wiring and CTF settlement glue.

The repo has NatSpec comments throughout, but no separate spec document, no
SMTChecker / Certora / hevm / Halmos / Kontrol setup, and only one invariant test
file (`test/FutarchyArbitration.invariants.t.sol`). This report defines what
"spec scaffolding" should look like for this codebase.

---

## 1. What makes a spec "formal-verification ready"?

A spec is *formal-verification ready* if a tool can mechanically check it against
the implementation without first having to guess what the author meant. In
practice that means each property is:

1. **Stated explicitly**, not implicit in the code. The verifier needs a sentence
   it can parse, not a comment that gestures at intent.
2. **Quantified**. "For all callers" or "for all proposals" or "for all blocks
   `t >= bind + TIMEOUT`". A spec without quantifiers is not yet a spec.
3. **Decidable in the verifier's logic**. SMT solvers handle linear integer
   arithmetic, bit-vectors of fixed width, arrays, and uninterpreted functions.
   Anything outside that is either approximated (e.g., `mulDiv`) or modelled with
   an axiom (e.g., `keccak` is collision-resistant).
4. **Local where possible**. Function-level pre/post-conditions and per-storage
   field invariants compose; "the entire system is solvent" does not (it has to
   be re-proven on every state change).
5. **Testable**. Even before the verifier is wired, the spec should be runnable
   as a Foundry invariant or symbolic harness. If you cannot write a unit test
   that violates the spec on purpose, the spec is probably vacuous.
6. **Traceable to source**. Every spec clause has a function, storage variable,
   or event it constrains, by file path and line. This is what makes review
   tractable.

For Solidity specifically, "verification ready" also means:

- **Bounded loops** or explicit loop-invariant annotations (Certora, Halmos, and
  Kontrol all need a hint when a loop iterates over a dynamic array).
- **No `tx.origin` for authorization** — symbolic engines model it but it
  defeats compositional reasoning. *Note: FAO's `UniswapV3LiquidityAdapter`
  reads from `tx.origin` deliberately to identify the proposer; this is a hot
  spot the spec must address.*
- **Pure / view annotations honored** — these become axioms the verifier trusts.
- **No `delegatecall` from variable targets** (the symbolic state space
  explodes otherwise) — FAO uses clones with fixed implementations, which is
  tractable.
- **No `assembly { ... }` blocks without an explicit semantic model** —
  Solidity SMTChecker silently gives up; Halmos / Kontrol need an EVM trace.

The lift from "NatSpec only" to "verification ready" is mostly about turning
prose into formal sentences and adding the missing universal quantifiers.

---

## 2. Industry approaches (and where each fits FAO)

| Tool / Language | Spec language | What it proves | Best fit for FAO |
|---|---|---|---|
| **Solidity SMTChecker** | `assert`, `require`, `function-state-vars` model | Per-function reachability of `assert`, bounded loop unrolling | Cheap first pass: prove `effectiveSupply()` non-negativity, ragequit math no-overflow. Free, ships with `solc`. |
| **Certora Prover (CVL)** | CVL — rules, invariants, ghost variables, hooks | Multi-contract invariants, monotonicity, balance conservation, parametric rules over storage | Best fit for FAO's economic invariants (ragequit pro-rata, supply conservation, bond escalation). Industry standard at Aave / Compound / MakerDAO / Lido. |
| **hevm symbolic** | Solidity + `prove_` test prefixes | SMT-bounded symbolic execution, equivalence checks, branch coverage | Good for proving `_arithmeticMeanTick`, `_invertSqrtPriceX96`, `UniV3Math.getLiquidityForAmounts` are overflow-safe across all inputs. |
| **Halmos** | Foundry-style Solidity tests | Symbolic fuzzing with SMT; treats `uint256` args as symbolic | Drop-in over existing Foundry suite. Great for the orchestrator's 8-phase atomic promote — provide one symbolic input and assert post-conditions. |
| **Kontrol** | K-framework + Foundry harness | Functional correctness against K's EVM semantics | Heavy. Reserve for the *atomic promote* sequence and `UniswapV3LiquidityAdapter.uniswapV3MintCallback` callback authorization. |
| **Foundry invariants** | `invariant_*` tests with a `handler` contract | Random-walk fuzz with assertion oracle | Pure scaffolding. Every formal invariant should *also* be expressible here so it runs every CI cycle. Already exists for `FutarchyArbitration`. |
| **Dafny** | Pre/post + `requires` / `ensures` | Whole-program proof with auto-induction | Not idiomatic for Solidity. Use only for off-chain logic (e.g., a Python keeper or TLA+-style state-machine model). |
| **TLA+ / PlusCal** | TLA — temporal modal logic of action | Liveness, safety, refinement, fairness assumptions | Use for the *lifecycle* model: bond escalation state machine, TWAP-window timing, queue advancement. TLA+ is good at "every proposal eventually settles." |
| **K-framework / KEVM** | Reachability logic | Bytecode-level correctness against EVM | Heaviest; used by RV / Certora for high-value proofs. Not first-pass material for FAO. |

The pragmatic stack for FAO is:

1. **NatSpec → structured spec doc** (a single `audit/specs/INVARIANTS.md`).
2. **Foundry `invariant_*` tests** — one per item in the spec doc, so the spec is
   continuously exercised in fuzzing.
3. **SMTChecker** turned on for the leaf math contracts (`UniV3Math.sol`,
   ragequit share computation).
4. **Certora CVL** spec for the cross-contract invariants (supply conservation,
   solvency, monotonicity of `totalCurveTokensSold`).
5. **TLA+ model** of the futarchy lifecycle for liveness ("every promoted
   proposal eventually resolves").
6. **Halmos** to keep the bar low and exercise everything in CI.

---

## 3. How comparable DeFi protocols document invariants

### Aave V3

- Maintains a Certora `certora/` directory with `.spec` files per contract.
- Public invariants doc lists conservation rules (`scaledBalance * index ==
  underlying`), monotonicity (interest indices are non-decreasing), and
  liquidation pre/post (`healthFactor < 1 → liquidatable`).
- Each spec rule cites the storage slot it constrains.

### Compound V3 ("Comet")

- One Certora project per asset, with shared `shared/Invariants.spec`.
- Documents the "totalSupply equals sum of balances" invariant explicitly
  ("Σ balanceOf[i] == totalSupply").
- Uses *ghost variables* to track aggregate quantities the contract does not
  store (sum of borrows, sum of supply).

### MakerDAO (DSS)

- The original gold standard. Their `Vat.sol` invariants are written as
  mathematical equations in the comments:
  - `sum(art_i) == debt`
  - `sum(ink_i) == gem_total`
  - `Vat.debt == Vat.dai + Vat.sin`
- These predate Certora's modern CVL but mapped 1:1 once the Certora work
  started. The lesson: write invariants as equations in source, not prose.

### Uniswap V4

- Documents *hook safety* invariants — every external entry point declares
  which storage slots it touches and which it preserves.
- Uses Foundry invariant tests + Certora rules for "liquidity is never
  destroyed except via `burn`."
- TWAP integrity is stated as "the tick cumulative is monotonically non-
  decreasing over time per pool" — directly relevant to FAO.

### EigenLayer

- Publishes a `docs/threat-model.md` and a `specs/` folder.
- Each rule has an ID (e.g., `INV-DEPOSIT-001`) so PRs cite which invariants
  they touch.
- Slashing invariants are written as: "If `Slasher.canSlash(s,o,t)` then
  `s.stake.balance >= o.amount`" — a literal predicate.

### Common pattern (the bar FAO should clear)

Across all five protocols:

1. A **dedicated specs directory**, not buried in NatSpec.
2. Each invariant has a **stable ID**.
3. Each invariant is **dual-stated**: prose explanation + machine-checkable
   form (CVL, Solidity assertion, or both).
4. **Threat model** is a separate document that explicitly names actors,
   capabilities, and bounds (e.g., "MEV searcher can reorder within a block
   but cannot front-run the orchestrator promote because it's admin-gated").
5. **Spec-to-code traceability** is enforced — every contract has a
   `// @spec INV-...` comment pointing back at the invariant.

---

## 4. The gap between NatSpec and a formal spec

NatSpec, even good NatSpec, is *informative* — it tells a reader what a function
does. A formal spec is *prescriptive* — it states a logical property that must
hold for *all* executions. The differences:

| Aspect | NatSpec | Formal spec |
|---|---|---|
| Audience | Humans (devs, auditors) | Verifier + humans |
| Quantification | Implicit | Explicit (`forall` / `exists`) |
| Scope | Per-function | Per-contract + per-system |
| State references | Variable names | Pre/post state pairs (`s`, `s'`) |
| Failure mode | "should not happen" | `assert` / counterexample |
| Composability | Each comment stands alone | Invariants compose under transitions |
| Maintenance | Drift silently | CI fails when violated |

A concrete example from `InstanceSale.sol`:

> **NatSpec** says: *"Token supply that participates in ragequit. The sale's
> own balance is excluded so freshly-minted-for-LP tokens don't dilute the
> per-token ETH share."*

That is a description. The **formal-spec** version is:

```
invariant SALE-EFF-001:
  effectiveSupply() == TOKEN.totalSupply() - TOKEN.balanceOf(address(this))
  /\ effectiveSupply() <= TOKEN.totalSupply()
  /\ (TOKEN.totalSupply() < TOKEN.balanceOf(address(this)))
       ==> effectiveSupply() == 0
```

Three properties, each independently checkable, each falsifiable. That is the
gap to close.

---

## 5. Economic-invariant patterns

DeFi invariants cluster into a small number of recurring patterns. A
formal spec is largely an exercise in identifying *which* pattern applies and
naming the witness variable.

### 5.1 Conservation laws

`Σ in == Σ out + Σ retained`. Tokens, ETH, and conditional positions all obey
conservation modulo explicit mint/burn. The Certora idiom is a ghost variable
that tracks the sum, plus an invariant `ghost_sum == storage_sum`.

For FAO: `Σ withdrawable[i] + Σ active_bonds <= WETH.balanceOf(arbitration)`
(see `FutarchyArbitration.invariants.t.sol` for the existing partial form).

### 5.2 Monotonicity

A value can only move in one direction. Examples:

- `totalSupply` is monotonic between burns (and decreases only inside `burn`).
- `nextProposalId` is strictly increasing.
- `queueHead` only advances forward.
- `tickCumulative` (Uniswap pool oracle observations) is monotonic in time per
  pool.

State the monotonicity as a relation between consecutive states `s` and `s'`.

### 5.3 No-free-money (zero-sum / pro-rata)

For every wei in, exactly one party can take it out. For ragequit, this is
exactly the pro-rata law:

```
forall caller: ethShare = floor(ethBalance * burnAmount / effectiveSupply)
              /\ ragequit(caller, n) refunds ethShare ETH
              /\ effectiveSupply' = effectiveSupply - burnAmount
              /\ TOKEN.totalSupply' = TOKEN.totalSupply - burnAmount
```

Two subtleties to spec explicitly:

1. **Rounding direction**. Integer division rounds down; the leftover wei is
   "donated" to remaining holders. State this — it is not a bug but it must be
   acknowledged.
2. **Self-ragequit**. `InstanceSale` already rejects `msg.sender ==
   address(this)`; the spec should state `forall n: !ragequit(self, n)`.

### 5.4 Fairness

Two flavors:

- *Pro-rata fairness*: identical positions yield identical payouts (the
  ragequit law above).
- *First-come-first-served*: in the bond escalation, a YES bidder cannot have
  their bond evicted without a strict-doubling NO bond or by being graduated.
  This is a `placeNoBond` precondition.

### 5.5 Access control as a logical predicate

State each gated function as:

```
forall caller, args: f(caller, args) succeeds ⇒ predicate(caller)
```

For FAO: `setAdapter ⇒ caller == ADMIN`. The Certora CVL form is one rule per
gated function — these are some of the easiest properties to verify.

### 5.6 Timelock / window monotonicity

Several FAO functions are time-gated:

- `_finalizeInitialPhaseIfNeeded` requires `block.timestamp >= INITIAL_PHASE_END`.
- `FAOTwapResolver.resolve` requires `block.timestamp >= anchor + TIMEOUT`.
- `FutarchyArbitration.finalizeByTimeout` requires `block.timestamp >=
  lastStateChangeAt + TIMEOUT`.

State: "once the window opens, it stays open" (no time-travel) and "the
function reverts deterministically before the window."

---

## 6. What is uniquely critical for prediction-market / futarchy systems

Prediction markets stitch together pieces that each have well-studied
invariants individually, but combine in non-obvious ways. The FAO-specific
hot spots:

### 6.1 Resolution determinism

For any pair (proposal, time `t >= bind + TIMEOUT`), `resolve(proposal)` must
return a deterministic accepted/rejected with no path-dependence.

Concretely: two honest replays of the resolve transaction at different block
heights *after* `windowEnd` must produce the same `accepted` bit. The TWAP
window is fixed: `[anchor + TIMEOUT - TWAP_WINDOW, anchor + TIMEOUT]`.

Sources of nondeterminism the spec must rule out:

- Block-time drift inside the resolver (FAO reads `block.timestamp` only for
  the `>= windowEnd` check, which is monotone — good).
- Pool observation cardinality being too small to cover the window (mitigated
  by `OBSERVATION_CARDINALITY` immutable, but the spec should state
  `cardinality >= TWAP_WINDOW / minBlockSpacing`).
- Pool re-initialization between bind and resolve (mitigated by
  `_maybeCreatePoolAndInit` reverting on `PreCreated`; spec should state
  `forall pool ∈ {yesPool, noPool}: pool.slot0().sqrtPriceX96 is constant
  between bind and resolve except for swaps`).

### 6.2 No double-spend across condition wraps

Gnosis CTF + Wrapped1155 means each unit of underlying collateral is
"split" into a YES-position and a NO-position. The spec must state:

```
forall collateral C, condition K:
  totalCollateralLocked(C, K) == supply(YES_C) == supply(NO_C)
```

i.e., the merge operation always restores the original. Wrapped1155 wrapping
is 1:1 — state that explicitly:

```
forall ERC1155 id: Wrapped1155.totalSupply(id) == CTF.balanceOf(W1155, id)
```

This invariant is *the* security property of the conditional-tokens layer
and FAO depends on it transitively. The spec should reference this as an
**assumed** (vendored) invariant of Gnosis CTF and `Wrapped1155Factory`.

### 6.3 TWAP integrity

Three sub-properties:

1. **Window fixity**: the measurement window `[deadline - TWAP_WINDOW,
   deadline]` is computed from `anchorTimestamp` (a `uint48` set once at
   bind) and never moves.
2. **Cardinality sufficiency**: the pool's observation buffer covers the
   window. State as a precondition on `bindProposal`.
3. **Orientation correctness**: ticks are normalized to "currency per
   company" — the FAO resolver flips sign if `token0 != companyWrapper`. The
   spec must state `arithmeticMeanTick(p, base) ==
   (token0(p)==base ? +avg : -avg)` and the test must cover both orderings.

### 6.4 Sale-treasury solvency

```
forall caller, n <= TOKEN.balanceOf(caller) / 1e18:
  ragequit(caller, n) → (caller receives ethShare AND
                         sale's ETH balance decreases by exactly ethShare)
  ∧ ethShare == (ethBalanceBefore * burnAmount) / effectiveSupplyBefore
  ∧ ethBalanceAfter == ethBalanceBefore - ethShare
```

Plus the *aggregate solvency invariant*:

```
At all times: address(sale).balance >= 0  (trivially true in Solidity)
              ∧  pro-rata math is monotonic: ethShare/burnAmount is the same
                 for every concurrent caller within one transaction.
```

The subtle case is `seedLiquidityManager` mid-sale: ETH leaves the sale, the
manager mints fLP back. The spec must state that the *exchange* preserves
invariant value:

```
ethOutflow + fLPMintedToSale_valued_in_eth == invariant_neutral
```

This is harder to state without a valuation function. The pragmatic spec is
weaker: "after seedLiquidityManager, the sale's `ragequitTokens` list
contains the manager, and a subsequent ragequit returns both pro-rata ETH
and pro-rata fLP."

### 6.5 MEV-resistance of the atomic promote

The orchestrator's `createOfficialProposalAndMigrate` is a single
transaction. Spec:

```
forall promoter, mev_searcher:
  if the tx succeeds, then for all 8 phases, every step occurred in order
  AND no external contract observed an intermediate state
  (no other tx can interleave because Solidity is single-threaded per tx)
  AND on any revert, the entire state — including the builder tip — rolls back.
```

The "PreCreated" defense (refusing to operate on a pre-initialized pool) is
exactly the spec clause:

```
forall yesPool, noPool: at the start of migrate(),
  (yesPool == 0 ∨ slot0(yesPool).sqrtPriceX96 == 0)
  ∧ (noPool == 0 ∨ slot0(noPool).sqrtPriceX96 == 0)
```

### 6.6 Bond-escalation game-theoretic invariants

`FutarchyArbitration` has three properties that *should* be theorems:

1. **Strict doubling per flip**: a NO bond is always exactly the previous YES
   amount; a NO→YES flip requires `amount >= 2 * noBond.amount` *or*
   `amount >= requiredYes(queueLen)`.
2. **Reachable graduation**: any honest YES bidder can graduate by depositing
   `requiredYes(queueLen)` directly, regardless of the current NO bond size
   (already stated in code as a comment — promote to a formal spec).
3. **Settlement uniqueness**: a proposal transitions to `SETTLED` exactly
   once and never leaves; `accepted` is set at the same time and is
   immutable thereafter.

The existing `invariant_WETH_conserved_across_actors_and_contract` covers (a
weak form of) global conservation. The other two need explicit invariant
tests.

### 6.7 Insider-vesting fairness

`InsiderVesting` (referenced but not read in this report) holds 0.3 FAO per
1.0 FAO sold. The spec must state:

```
forall t, insider:
  cumulativeVestedTo(insider, t) <= cumulativeAllocation(insider)
   * vestingCurve(t - startTime)
```

— a monotone schedule that can never pay out more than the allocation.

---

## 7. The spec scaffolding deliverable

Producing the scaffolding is mostly mechanical once the patterns are named.
The concrete artifacts FAO needs, in order:

1. **`audit/specs/INVARIANTS.md`** — numbered list of invariants with IDs,
   source citations, prose, and pseudo-formal form.
2. **`audit/specs/THREAT-MODEL.md`** — actors, capabilities, trust boundaries.
3. **NatSpec `@invariant` and `@spec` tags** on every contract pointing to
   the IDs in (1).
4. **`test/invariants/*.t.sol`** — one Foundry invariant test per ID, even
   if shallow.
5. **`certora/`** — CVL spec stubs (initially `// TODO` rules, but the
   skeleton exists).
6. **`docs/spec-coverage.md`** — a matrix of `[ID × Tool]` showing which
   invariants are checked by which tool, and the gaps.
7. **CI gate**: `forge test --match-path 'test/invariants/*'` runs on every
   PR.

The point is: *the spec is the contract*. The code is one
implementation; the spec is the bar.

---

## 8. Anti-patterns to avoid

1. **Invariants written in prose only**. If the spec is not in a form a
   computer can read, it is just commentary. Pair every prose invariant with
   a Foundry assertion.
2. **`require` strings as the spec**. `require(amount > 0, "zero")` tells
   the user *what* failed, not what would have to be true to avoid failure.
   The spec should sit above the `require`.
3. **Conflating tests and specs**. A test exercises one path; a spec
   constrains all paths. Foundry invariant tests are the bridge — same
   syntax, different intent.
4. **Spec drift**. Specs that aren't part of CI rot in weeks. The fix is to
   either turn them into invariant tests *or* delete them.
5. **Verifying the trivially true**. Don't write `invariant_totalSupply_is_uint256()`
   — the type system already proves that. Write the properties that *would*
   fail if you mis-coded the logic.
6. **Forgetting external assumptions**. FAO depends on Gnosis CTF, UniV3,
   and Wrapped1155 invariants. State these as *assumed* axioms in the spec
   so the verifier (and the reviewer) knows what is taken on trust.
7. **Vacuous quantifiers**. `forall x: P(x) ∨ ¬P(x)` is true and useless.
   When in doubt, derive the spec by writing the most aggressive attacker
   first and then negating it.

---

## 9. Recommended path for FAO (week-by-week)

| Week | Deliverable | Tool |
|---|---|---|
| 1 | `audit/specs/INVARIANTS.md` with top-15 invariants (see rubric) | Markdown |
| 1 | `audit/specs/THREAT-MODEL.md` (actors, capabilities) | Markdown |
| 2 | Foundry invariant tests for INV-001..INV-005 (token, supply, ragequit) | Foundry |
| 2 | SMTChecker on `libraries/UniV3Math.sol`, `_invertSqrtPriceX96` | solc |
| 3 | Foundry invariant tests INV-006..INV-010 (orchestrator, resolver) | Foundry |
| 3 | Halmos run over `placeYesBond`/`placeNoBond` (symbolic amount) | Halmos |
| 4 | TLA+ model of the bond-escalation state machine | TLA+ |
| 4 | First Certora CVL stub for `InstanceSale` (supply + balance) | Certora |
| 5 | CVL spec for `FutarchyArbitration` graduation & queue | Certora |
| 6 | Spec-coverage matrix; CI gate `forge test --match-path invariants` | CI |

The total scaffolding lift is ~6 person-weeks. Verification proofs themselves
are out of scope here.

---

## Sources

- Solidity SMTChecker documentation — <https://docs.soliditylang.org/en/latest/smtchecker.html>
- Certora Verification Language (CVL) reference — <https://docs.certora.com/en/latest/docs/cvl/index.html>
- hevm (formerly dapphub) — <https://github.com/ethereum/hevm>
- Halmos — <https://github.com/a16z/halmos>
- Kontrol (Runtime Verification) — <https://github.com/runtimeverification/kontrol>
- TLA+ Examples (Lamport) — <https://lamport.azurewebsites.net/tla/tla.html>
- K-framework / KEVM — <https://github.com/runtimeverification/evm-semantics>
- Foundry invariant testing — <https://book.getfoundry.sh/forge/invariant-testing>
- Aave V3 Certora specs — <https://github.com/aave/aave-v3-core/tree/master/certora>
- Compound V3 ("Comet") Certora specs — <https://github.com/compound-finance/comet/tree/main/certora>
- MakerDAO DSS Vat invariants — <https://docs.makerdao.com/smart-contract-modules/core-module/vat-detailed-documentation>
- Uniswap V4 invariant tests — <https://github.com/Uniswap/v4-core/tree/main/test/invariants>
- EigenLayer specs — <https://github.com/Layr-Labs/eigenlayer-contracts/tree/main/docs>
- Gnosis Conditional Tokens Framework — <https://docs.gnosis.io/conditionaltokens/>
- Robin Hanson, "Shall We Vote on Values, But Bet on Beliefs?" (2003) — futarchy mechanism design
- FAO source tree — `/home/kelvin/repos/futarchy-fi/FAO/src/`
- FAO existing invariant test — `/home/kelvin/repos/futarchy-fi/FAO/test/FutarchyArbitration.invariants.t.sol`
- FAO onchain design notes — `/home/kelvin/repos/futarchy-fi/FAO/docs/onchain-futarchy-design.md`
