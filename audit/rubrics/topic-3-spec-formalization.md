# Rubric — Topic 3: Spec Formalization (for FAO)

> *Purpose: a stateless Codex evaluator scores how "formal-verification ready"
> the `futarchy-fi/FAO` codebase is. The rubric measures spec scaffolding
> only — not the proofs themselves. Each dimension has anchors at 0, 3, 5, 7,
> 9. Dimensions are averaged with equal weight (each contributes 1/N) unless
> a meta-rule below says otherwise. Final score is the arithmetic mean,
> rounded to one decimal place. Anything `>= 8.0` clears the CAO bar.*

## How to score (operating instructions for the evaluator)

For each dimension below:

1. Read the **anchor descriptions** at 0 / 3 / 5 / 7 / 9.
2. Find the highest anchor whose description is fully satisfied by the
   evidence in the repo.
3. If the evidence sits strictly between two anchors, pick the integer
   midpoint (4 / 6 / 8).
4. Cite **at least one file path** as evidence for the score. If you cannot
   cite a file, the score is 0.
5. **No partial credit for promises.** Comments saying "TODO add Certora
   spec" count as 0. Code that exists but is commented out counts as 0.

After scoring all dimensions, list per-dimension scores, compute the mean,
and emit:

```
TOPIC-3 SCORE: <mean to 1dp> / 10.0
DIMENSIONS:
  D1 spec-doc-existence: <x>
  D2 invariant-explicitness: <x>
  D3 pre-postcondition-coverage: <x>
  D4 economic-rule-statability: <x>
  D5 threat-model-formalism: <x>
  D6 traceability: <x>
  D7 verifiability-hooks: <x>
  D8 decidability-readiness: <x>
PASS: <yes if >= 8.0 else no>
```

---

## Dimension D1 — Spec document existence & shape

Is there a dedicated spec artifact separate from NatSpec?

| Score | Anchor |
|-------|--------|
| **0** | No spec doc. Spec lives only in NatSpec comments and `require` strings. |
| **3** | A README or design doc mentions invariants in prose but they have no IDs and are scattered. |
| **5** | A single `SPEC.md` or `INVARIANTS.md` exists; lists at least 5 invariants with IDs but no formal notation. |
| **7** | `audit/specs/INVARIANTS.md` (or equivalent) lists ≥12 invariants, each with: stable ID, source citation (file:line), prose, and pseudo-formal predicate. |
| **9** | All of (7), plus the spec doc is referenced from contract NatSpec via `@spec INV-...` tags, plus a spec-coverage matrix exists (`docs/spec-coverage.md` or similar) mapping each ID to the tool that checks it. |

## Dimension D2 — Invariant explicitness

For state-bearing contracts, how many storage-level invariants are stated as
checkable predicates?

| Score | Anchor |
|-------|--------|
| **0** | No `invariant_*` tests; no SMTChecker; no Certora rules; invariants only implied by code. |
| **3** | A single Foundry invariant file exists (e.g., `test/FutarchyArbitration.invariants.t.sol`) with ≤2 invariants. |
| **5** | Invariant tests cover ≥1 of the core contracts comprehensively (≥4 invariants on `InstanceSale` *or* `FutarchyArbitration`). |
| **7** | Invariant tests exist for ≥3 of the core contracts (`InstanceSale`/`FAOSale`, `FutarchyArbitration`, `FAOTwapResolver`/`FutarchyTWAPOracle`) with conservation + monotonicity + access-control rules each. |
| **9** | All of (7), plus SMTChecker enabled on the math libraries (`libraries/UniV3Math.sol`, ragequit share math) with `solc --model-checker-engine chc` passing in CI. |

## Dimension D3 — Pre/postcondition coverage

For each externally callable state-changing function, is there a stated pre-
and post-condition?

| Score | Anchor |
|-------|--------|
| **0** | Functions have NatSpec but no explicit pre/post predicates. |
| **3** | A handful of functions (≤25%) have `@dev` notes that imply preconditions. |
| **5** | ≥50% of external state-changing functions have NatSpec `@dev` blocks that name a precondition AND a post-state effect. |
| **7** | ≥80% of external state-changing functions have a `@spec` block listing: pre, post, frame (which storage it leaves untouched), and revert conditions. |
| **9** | All external state-changing functions have a `@spec` block AND a corresponding test that asserts the postcondition under fuzzed inputs. |

## Dimension D4 — Economic-rule statability (conservation + monotonicity)

Are the financial invariants — conservation, pro-rata, monotonicity, no
free money — stated formally?

| Score | Anchor |
|-------|--------|
| **0** | No statement of conservation, pro-rata, or monotonicity anywhere. |
| **3** | Code comments mention "pro-rata" or "conservation" informally; no test enforces them. |
| **5** | At least one conservation invariant is enforced by a Foundry test (e.g., the existing `invariant_WETH_conserved_across_actors_and_contract` in `test/FutarchyArbitration.invariants.t.sol`). |
| **7** | Conservation, pro-rata, AND monotonicity each have ≥1 dedicated invariant test. Pro-rata law for ragequit is stated as a predicate with explicit rounding direction documented. |
| **9** | All of (7), plus a Certora CVL rule (or equivalent Halmos symbolic test) proves the pro-rata law symbolically for `ragequit`, AND a monotonicity rule for `nextProposalId` / `queueHead` / `totalCurveTokensSold`. |

## Dimension D5 — Threat-model formalism

Is the adversary stated as a logical predicate (actors, capabilities,
bounds)?

| Score | Anchor |
|-------|--------|
| **0** | No threat model document. |
| **3** | A design doc mentions MEV / front-running / griefing in prose. |
| **5** | `THREAT-MODEL.md` or equivalent lists ≥3 adversary roles (MEV searcher, malicious admin, hostile pool) with what they can do. |
| **7** | `THREAT-MODEL.md` lists all adversary roles, names each defense, AND maps defenses to spec invariant IDs (e.g., "PreCreated defense → INV-ORCH-003"). |
| **9** | All of (7), plus each adversary capability is encoded as a *negative* invariant (something the adversary cannot achieve) that is testable, AND at least one symbolic test (Halmos / hevm `prove_*`) exercises an attacker model. |

## Dimension D6 — Spec ↔ implementation traceability

Can a reviewer go from spec ID to source line and back?

| Score | Anchor |
|-------|--------|
| **0** | No traceability; spec (if any) does not cite files or lines. |
| **3** | Spec doc cites file paths but no line numbers; contracts do not back-reference. |
| **5** | Spec doc cites file:line for each invariant; contracts have at least some `@spec` or `@invariant` tags. |
| **7** | Bidirectional: every spec ID cites a source range, every relevant function/storage var carries a `@spec` tag, AND a CI script verifies the citations resolve. |
| **9** | All of (7), plus the spec-coverage matrix is generated from those tags (single source of truth), AND PR template requires citing affected invariant IDs. |

## Dimension D7 — Verifiability hooks (tooling readiness)

Is the codebase prepared for a verifier to be turned on tomorrow?

| Score | Anchor |
|-------|--------|
| **0** | None of: SMTChecker, Certora, hevm, Halmos, Kontrol configured anywhere. No bounded loops. |
| **3** | Foundry installed and invariant tests run (`forge test` works). Nothing more. |
| **5** | Either: (a) SMTChecker enabled on ≥1 contract via `pragma`/`foundry.toml`, OR (b) a `certora/` directory exists with at least one CVL rule that runs, OR (c) Halmos config is checked in. |
| **7** | At least 2 of {SMTChecker, Certora, Halmos, hevm} are configured and have green runs documented in CI (artifact or log committed). |
| **9** | All of (7), plus loop bounds are annotated (or proven finite by structure) in every dynamically-iterating function (`ragequit` loop over `ragequitTokens`, queue traversal), AND a CI job runs the symbolic tool on every PR. |

## Dimension D8 — Decidability readiness

Are the constructs that defeat verifiers (unbounded loops, `tx.origin` auth,
`delegatecall` with variable targets, unmodeled assembly) either avoided or
explicitly modeled?

| Score | Anchor |
|-------|--------|
| **0** | Multiple decidability-hostile patterns present (unbounded loops + `tx.origin` auth + raw assembly) with no documentation. |
| **3** | Patterns are present but mentioned in NatSpec (e.g., `UniswapV3LiquidityAdapter` documents `tx.origin` usage). |
| **5** | All unbounded-iteration sites have an upper-bound invariant (e.g., `ragequitTokens.length <= MAX_RAGEQUIT_TOKENS`), and `tx.origin` reads are isolated to one contract and documented. |
| **7** | Loops are bounded by a stated constant; assembly blocks are either absent or accompanied by a semantic-model comment; `delegatecall` targets are immutable; `tx.origin` reads carry a justification AND a unit test that demonstrates the property they preserve. |
| **9** | All of (7), plus a dedicated `audit/specs/DECIDABILITY.md` enumerates every concession from formal verification and the mitigation. |

---

## Worked self-evaluation of current FAO

Date of evaluation: 2026-05-22 (workspace branch).
Source tree: `/home/kelvin/repos/futarchy-fi/FAO/src/`.

### Stated (in-source or in-tests) invariants

| Invariant (informal) | Where it lives | Evidence |
|---|---|---|
| WETH `totalSupply` conserved across actors + arbitration contract | Foundry invariant test | `/home/kelvin/repos/futarchy-fi/FAO/test/FutarchyArbitration.invariants.t.sol` lines 156-166 (`invariant_WETH_conserved_across_actors_and_contract`) |
| Contract WETH balance ≥ total withdrawable | Foundry invariant test | Same file, lines 170-183 (`invariant_contract_balance_equals_escrow_plus_withdrawable`) |
| `effectiveSupply == totalSupply - sale.balance` | NatSpec only | `/home/kelvin/repos/futarchy-fi/FAO/src/InstanceSale.sol` lines 125-133 |
| Pro-rata ETH share = `(ethBalance * burnAmount) / effectiveSupply` | Inline in code (not stated as a property) | `/home/kelvin/repos/futarchy-fi/FAO/src/InstanceSale.sol` lines 204-209 |
| `burnAmount <= effectiveSupply` | `require` string | `/home/kelvin/repos/futarchy-fi/FAO/src/InstanceSale.sol` line 195 |
| Sale cannot ragequit itself | Custom error | `/home/kelvin/repos/futarchy-fi/FAO/src/InstanceSale.sol` line 190 |
| Sale token cannot be added to ragequit list | Custom error | `/home/kelvin/repos/futarchy-fi/FAO/src/InstanceSale.sol` lines 230-237 |
| Orchestrator refuses pre-initialized conditional pools (PreCreated defense) | Custom error + check | `/home/kelvin/repos/futarchy-fi/FAO/src/FAOOfficialProposalOrchestrator.sol` lines 220-228 |
| `TWAP_WINDOW <= TIMEOUT` (constructor-time) | Constructor revert | `/home/kelvin/repos/futarchy-fi/FAO/src/FAOTwapResolver.sol` line 77 |
| `twapWindow <= tradingPeriod` (constructor + setter) | Constructor + setter revert | `/home/kelvin/repos/futarchy-fi/FAO/src/FutarchyTWAPOracle.sol` lines 120-122, 241-243 |
| Resolver TWAP window is fixed at bind time | NatSpec + code path | `/home/kelvin/repos/futarchy-fi/FAO/src/FAOTwapResolver.sol` lines 162-198 |
| `nextProposalId` strictly increasing | Implicit (increment only) | `/home/kelvin/repos/futarchy-fi/FAO/src/FutarchyArbitration.sol` lines 192-197 |
| `queueHead` only advances forward | Implicit (single `+= 1` site) | `/home/kelvin/repos/futarchy-fi/FAO/src/FutarchyArbitration.sol` line 380 |
| Adapter migrate is gated to ORCHESTRATOR | `if msg.sender !=` check | `/home/kelvin/repos/futarchy-fi/FAO/src/UniswapV3LiquidityAdapter.sol` line 158 |
| Adapter mint callback checks pool integrity | Explicit revert | `/home/kelvin/repos/futarchy-fi/FAO/src/UniswapV3LiquidityAdapter.sol` lines 220-221 |
| Single-use staging in adapter (cleared on success) | `delete stagedFor[tx.origin]` | `/home/kelvin/repos/futarchy-fi/FAO/src/UniswapV3LiquidityAdapter.sol` line 202 |
| TWAP gas-griefing protection | Explicit `gasleft()` check | `/home/kelvin/repos/futarchy-fi/FAO/src/FutarchyTWAPOracle.sol` lines 295-298 |

### Missing (NOT stated anywhere as a checkable predicate)

| Missing invariant | Why it matters | Where it would go |
|---|---|---|
| Σ `withdrawable[i]` + Σ active bonds == WETH held by arbitration *as equality* | Current test only proves `>=`, allowing silently-locked funds | `FutarchyArbitration` invariant test |
| `nextProposalId` strict monotonicity | No test catches a regression that resets it | `FutarchyArbitration` invariant test |
| `queueHead <= queue.length` | Catches off-by-one on queue advance | `FutarchyArbitration` invariant test |
| Settled proposals never un-settle | A reentry / replay attack could violate this | `FutarchyArbitration` invariant test |
| Once `accepted` is set, it is immutable | Same | `FutarchyArbitration` invariant test |
| Ragequit pro-rata law (formal) | Underpins the whole sale-treasury solvency claim | `InstanceSale` / `FAOSale` invariant test |
| Self-ragequit impossibility under any path | Currently only `msg.sender == address(this)` guarded | `InstanceSale` invariant test |
| `effectiveSupply == 0 → ragequit reverts` | Edge case explicit | `InstanceSale` invariant test |
| `initialPhaseFinalized` is monotonic (false → true, never back) | Critical for price math invariance | `InstanceSale` / `FAOSale` invariant test |
| Sale ETH balance never increases except via `buy` or `receive` | Solvency floor | `InstanceSale` invariant test |
| Resolver: `bindings[p].anchorTimestamp` is immutable after first set | Window-fixity guarantee | `FAOTwapResolver` invariant test |
| Resolver: `resolved` is monotone false → true | Resolution determinism | `FAOTwapResolver` invariant test |
| Resolver: `accepted` is fixed at the time `resolved` flips | Cannot retroactively change | `FAOTwapResolver` invariant test |
| Orchestrator atomicity: any revert in phases 1–8 reverts the whole tx | Implicit in EVM, but should be explicit spec | `FAOOfficialProposalOrchestrator` invariant test |
| Adapter staging cannot be replayed across promotes | `delete` is in code but no test asserts it | `UniswapV3LiquidityAdapter` invariant test |
| CTF conservation: split-then-merge restores the same amount | Vendored from Gnosis but FAO does not assume it explicitly | `audit/specs/ASSUMPTIONS.md` |
| Wrapped1155 1:1 wrap | Vendored from Gnosis | `audit/specs/ASSUMPTIONS.md` |
| UniV3 tickCumulative monotonicity | Vendored from Uniswap | `audit/specs/ASSUMPTIONS.md` |
| TWAP normalization correctness (sign flip for `token0 != company`) | Resolution correctness | `FAOTwapResolver` symbolic test |
| Bond doubling: `placeNoBond` amount == previous YES amount | Bond-escalation fairness | `FutarchyArbitration` invariant test |
| Graduation always reachable: bond ≥ `requiredYes(queueLen)` always graduates | Liveness | `FutarchyArbitration` invariant test |
| Safety-mode predicate: YES-by-timeout blocked iff `totalActiveNoBonds >= baseX` | Safety against low-liquidity attacks | `FutarchyArbitration` invariant test |

### Per-dimension self-score

| Dimension | Score | Justification (one line) |
|---|---|---|
| D1 spec-doc-existence | **0** | No `audit/specs/INVARIANTS.md` or equivalent; nothing in repo today. |
| D2 invariant-explicitness | **3** | One invariant file (`test/FutarchyArbitration.invariants.t.sol`) with two invariants; nothing for `InstanceSale` / resolver / orchestrator. |
| D3 pre-postcondition-coverage | **3** | NatSpec is thorough on `@notice` and `@dev` but rarely names pre/post predicates explicitly. |
| D4 economic-rule-statability | **3** | "Pro-rata" appears in comments; conservation has a partial (`>=`) test; no monotonicity invariant tests. |
| D5 threat-model-formalism | **3** | `docs/onchain-futarchy-design.md` discusses MEV / PreCreated / griefing in prose but no `THREAT-MODEL.md` and no mapping to spec IDs. |
| D6 traceability | **0** | No spec IDs exist, so no traceability is possible. |
| D7 verifiability-hooks | **3** | Foundry installed, invariant tests run; no SMTChecker, Certora, Halmos, hevm, or Kontrol configured. |
| D8 decidability-readiness | **5** | `tx.origin` usage in `UniswapV3LiquidityAdapter` is documented (lines 55-77); `ragequit`'s loop is bounded only loosely (no explicit `MAX_RAGEQUIT_TOKENS`); assembly is absent; `delegatecall` is to fixed clone targets. |

Arithmetic mean: (0 + 3 + 3 + 3 + 3 + 0 + 3 + 5) / 8 = 20/8 = **2.5 / 10.0**.

**Baseline TOPIC-3 SCORE: 2.5 / 10.0. PASS: no.**

---

## Top-15 invariants the FAO codebase should state explicitly

This is the actionable checklist. Each item is one row in the future
`audit/specs/INVARIANTS.md`.

| # | ID | Invariant (one line) | Cite |
|---|------|-------------------------|------|
| 1 | **INV-TOKEN-001** | `FAOToken.totalSupply` changes only via `mint` (MINTER_ROLE) and `burn` (ERC20Burnable); no other code path mutates it. | `src/FAOToken.sol`, `src/GenericFutarchyToken.sol` |
| 2 | **INV-SALE-001** | `effectiveSupply() == TOKEN.totalSupply() - TOKEN.balanceOf(address(this))` for all reachable states (with the convention that the difference is 0 when negative). | `src/InstanceSale.sol:125-133` |
| 3 | **INV-SALE-002** | For all `n`, `ragequit(n)` transfers exactly `floor(ethBalance * n*1e18 / effectiveSupply)` wei to `msg.sender`; decreases `effectiveSupply` by `n*1e18`; decreases `TOKEN.totalSupply` by `n*1e18`. (Rounding is floor; donated dust stays in the sale.) | `src/InstanceSale.sol:188-226` |
| 4 | **INV-SALE-003** | `ragequit` reverts when `msg.sender == address(this)` or `effectiveSupply == 0` or `burnAmount > effectiveSupply`. | `src/InstanceSale.sol:188-201` |
| 5 | **INV-SALE-004** | `initialPhaseFinalized` is monotone (false → true, never reset) AND once true, `initialNetSale` is frozen. | `src/InstanceSale.sol:170-180`, `src/FAOSale.sol:46-56` |
| 6 | **INV-ARB-001** | `nextProposalId` is strictly monotonically increasing; for every existing proposal `p`, `proposals[p].exists == true` and the only writer is `_initProposal`. | `src/FutarchyArbitration.sol:88,192-213,497-507` |
| 7 | **INV-ARB-002** | For all proposals, `state == SETTLED ⇒ settled == true` AND once `settled == true` the state never leaves `SETTLED` AND `accepted` is immutable. | `src/FutarchyArbitration.sol:312-346, 395-419` |
| 8 | **INV-ARB-003** | `Σ withdrawable[i] + Σ {yesBond.amount + noBond.amount : unsettled p} == WETH.balanceOf(address(arb))`. (Strengthens the existing `>=` invariant to an equality.) | `src/FutarchyArbitration.sol` + `test/FutarchyArbitration.invariants.t.sol:170-183` |
| 9 | **INV-ARB-004** | `placeNoBond` always sets `noBond.amount == previous yesBond.amount` (strict matching). | `src/FutarchyArbitration.sol:278-303` |
| 10 | **INV-ARB-005** | Graduation reachability: for any state with `_queuedCount() == k`, a YES bond `>= baseX * 2^k` graduates regardless of the current NO bond. | `src/FutarchyArbitration.sol:227-271, 355-358` |
| 11 | **INV-ARB-006** | Safety-mode equivalence: `safetyModeActive() == (totalActiveNoBonds >= baseX)` AND when active, `finalizeByTimeout` reverts for YES-state proposals. | `src/FutarchyArbitration.sol:312-346, 481-491` |
| 12 | **INV-ORCH-001** | `createOfficialProposalAndMigrate` is atomic: either all 8 phases commit, including the builder TIP, or none does. (Encoded as: any revert in any phase ⇒ post-state == pre-state, including `block.coinbase` balance.) | `src/FAOOfficialProposalOrchestrator.sol:121-178` |
| 13 | **INV-ORCH-002** | PreCreated defense: at the start of `_maybeCreatePoolAndInit`, if a pool exists at the deterministic address with `slot0().sqrtPriceX96 != 0`, the call reverts; the orchestrator never operates on an attacker-initialized pool. | `src/FAOOfficialProposalOrchestrator.sol:204-228` |
| 14 | **INV-TWAP-001** | Window fixity: `bindings[p].anchorTimestamp` is set exactly once (immutable after first non-zero write); `resolve(p)` always measures over `[anchor + TIMEOUT - TWAP_WINDOW, anchor + TIMEOUT]` regardless of `block.timestamp`. | `src/FAOTwapResolver.sol:91-115, 162-198` |
| 15 | **INV-TWAP-002** | Resolution determinism: `resolve(p)` flips `resolved` from false to true exactly once and sets `accepted` at the same write; both fields are immutable thereafter. Re-resolution reverts (`AlreadyResolved`). | `src/FAOTwapResolver.sol:117-144`, `src/FutarchyTWAPOracle.sol:187-217` |

(Bonus stretch invariants worth stating once the top-15 are in place: adapter
single-use staging, callback authorization, TWAP normalization correctness,
CTF split-merge conservation (assumed), Wrapped1155 1:1 wrap (assumed), UniV3
`tickCumulative` monotonicity (assumed). See `audit/research/topic-3-spec-formalization.md` §6.)

---

## Sources

- `/home/kelvin/repos/futarchy-fi/FAO/audit/research/topic-3-spec-formalization.md` (companion research doc)
- `/home/kelvin/repos/futarchy-fi/FAO/src/InstanceSale.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/FAOSale.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/FAOOfficialProposalOrchestrator.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/FAOTwapResolver.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/FutarchyTWAPOracle.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/FutarchyArbitration.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/UniswapV3LiquidityAdapter.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/FAOToken.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/GenericFutarchyToken.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/src/FAOFutarchyProposal.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/test/FutarchyArbitration.invariants.t.sol`
- `/home/kelvin/repos/futarchy-fi/FAO/docs/onchain-futarchy-design.md`
- Solidity SMTChecker docs — <https://docs.soliditylang.org/en/latest/smtchecker.html>
- Certora CVL — <https://docs.certora.com/en/latest/docs/cvl/index.html>
- Halmos — <https://github.com/a16z/halmos>
- Foundry invariant testing — <https://book.getfoundry.sh/forge/invariant-testing>
