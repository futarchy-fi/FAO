---
canonical: src/FAOTwapResolver.sol
scope: Per-function PRE/POST/FRAME for FAOTwapResolver — the contract that decides futarchy outcomes by reading the YES vs NO conditional pools' TWAP at the binding-defined window.
not-scope: System-wide invariants (`audit/specs/INVARIANTS.md`), the spot-pool initialization path (lives on the orchestrator / registry).
last-rebuilt: 2026-05-22
---

# Preconditions — `FAOTwapResolver`

The resolver is the single arbiter of every proposal's outcome. Two invariants govern it: `INV-TWAP-001` (window fixity) and `INV-TWAP-002` (resolution determinism). The function-level preconditions below are the call-boundary refinement of those two predicates.

## Constants & immutables

| Slot | Type | Invariant |
|---|---|---|
| `TIMEOUT` | `uint32` | Set in constructor, never mutates. Period from `anchorTimestamp` to the window end. |
| `TWAP_WINDOW` | `uint32` | Set in constructor. `TWAP_WINDOW <= TIMEOUT`. Sub-window over which the TWAP is computed. |
| `CTF` | `IConditionalTokensLike` | Non-zero, set in constructor. Used to report payouts at resolve. |
| `orchestrator` | `address` | Initially zero; set exactly once by `setOrchestrator`. After that, immutable. (Note: storage variable, but conceptually immutable post-Part2.) |

## State-mutating functions

### `setOrchestrator(address newOrchestrator) external`

| | |
|---|---|
| **PRE** | `orchestrator == address(0)`. (Anyone may call — by convention only the registry's `createFutarchyPart2` does.) |
| **POST** | `orchestrator == newOrchestrator`. |
| **FRAME** | `TIMEOUT`, `TWAP_WINDOW`, `CTF`, `bindings[]`. |
| **REVERTS** | `OrchestratorAlreadySet()` if `orchestrator != address(0)`. |
| **EVENTS** | `OrchestratorSet(newOrchestrator)`. |
| **Invariants touched** | INV-TWAP-001 (anchor-set-once predicate is enforced downstream because only the orchestrator can bind). |

### `bindProposal(address proposal, address yesPool, address noPool, address companyToken, address currencyToken, uint48 anchorTimestamp) external`

| | |
|---|---|
| **PRE** | `msg.sender == orchestrator`. `bindings[proposal].anchorTimestamp == 0` (first bind). Caller guarantees the YES/NO pools have been initialized at the same `sqrtPriceX96`. |
| **POST** | `bindings[proposal] = (yesPool, noPool, companyToken, currencyToken, anchorTimestamp, resolved=false, accepted=false)`. |
| **FRAME** | `orchestrator`, all immutables, other proposals' bindings. |
| **REVERTS** | `NotOrchestrator()`. `AlreadyBound(proposal)` if a prior binding exists. |
| **EVENTS** | `ProposalBound(proposal, yesPool, noPool, anchorTimestamp, questionId)` (queried from the proposal). |
| **Invariants touched** | INV-TWAP-001 (anchorTimestamp written exactly once). |

### `resolve(address proposal) external`

| | |
|---|---|
| **PRE** | `bindings[proposal].anchorTimestamp != 0` (proposal is bound). `bindings[proposal].resolved == false`. `block.timestamp >= bindings[proposal].anchorTimestamp + TIMEOUT` (window has fully elapsed). |
| **POST** | `bindings[proposal].resolved == true`. `bindings[proposal].accepted` is set to the YES↔NO TWAP comparison result. `CTF.reportPayouts(questionId, [yes_pay, no_pay])` has been called, with `[1, 0]` if YES wins, `[0, 1]` if NO wins or tied. Anyone may call (permissionless). |
| **FRAME** | `orchestrator`, immutables, all other proposals' bindings. Pool state. |
| **REVERTS** | `NotBound(proposal)`. `AlreadyResolved(proposal)` if `bindings[proposal].resolved == true`. `TooEarly(proposal, windowEnd)` if `block.timestamp < bindings[proposal].anchorTimestamp + TIMEOUT`. Bubbles a revert from `IUniswapV3Pool.observe(secondsAgos)` if the pool's observation cardinality is insufficient (handled by orchestrator increasing cardinality at promote — see THREAT-MODEL A8). |
| **EVENTS** | `Resolved(proposal, accepted, yesMeanTick, noMeanTick)`. |
| **Invariants touched** | INV-TWAP-002 (resolution determinism — single write of `resolved=true`). |

## View functions

### `windowEndOf(address proposal) external view → uint256`

Returns `bindings[proposal].anchorTimestamp + TIMEOUT`. Pure read; the orchestrator and operator daemons use it to decide when to `resolve`.

### `isReadyToResolve(address proposal) external view → bool`

Returns `bindings[proposal].anchorTimestamp != 0 ∧ !bindings[proposal].resolved ∧ block.timestamp >= windowEndOf(proposal)`. The operator daemon polls this every minute.

### `bindings(address proposal) external view → (yesPool, noPool, companyToken, currencyToken, anchorTimestamp, resolved, accepted)`

Storage accessor. Returns the 7-tuple.

## Internals (`_arithmeticMeanTick`, `_companyWrappers`)

### `_arithmeticMeanTick(address pool, address companyWrapper, uint256 windowEnd) internal view → int24`

| | |
|---|---|
| **PRE** | `pool` is a UniswapV3 pool. `companyWrapper` is either pool.token0() or pool.token1() — used to orient the returned tick (signed for direction). |
| **POST** | Returns `(tickCumulative[windowEnd] - tickCumulative[windowEnd - TWAP_WINDOW]) / TWAP_WINDOW`, with sign flipped if `companyWrapper == pool.token1()` (so a higher returned tick always means "more currency per company"). |
| **REVERTS** | Bubbles `IUniswapV3Pool.observe()` revert if the pool's observation cardinality is insufficient. |
| **Note** | Relies on UniV3's tickCumulative monotonicity (assumed — bonus INV-UNIV3-001). |

### `_companyWrappers(address proposal) internal view → (address yesCo, address noCo)`

Reads the proposal's `wrappedOutcome(0)` and `wrappedOutcome(1)` — the YES/NO company-token wrappers. Used to orient `_arithmeticMeanTick` on each conditional pool.

## Constructor

| | |
|---|---|
| **Args** | `(uint32 timeout, uint32 twapWindow, IConditionalTokensLike ctf)`. |
| **PRE** | `timeout > 0 ∧ twapWindow > 0 ∧ twapWindow <= timeout ∧ ctf != address(0)`. |
| **POST** | All immutables set. `orchestrator == address(0)` (must be set via `setOrchestrator`). |
| **REVERTS** | `InvalidConfig(timeout, twapWindow)`. |

## How this might be wrong

- The PRE on `bindProposal` says "first bind" but the implementation guards via the `AlreadyBound` error using `anchorTimestamp != 0` as the test. If we ever set `anchorTimestamp` to zero deliberately, the guard breaks. Document the convention: zero-anchor is the sentinel.
- The POST of `resolve` says "anyone may call". That's correct for the function, but the operator daemon is the only entity actively trying — if the daemon is down, the function still works but won't be called.
- `_arithmeticMeanTick` returns `int24`, which wraps at ±2^23. UniV3 pool ticks are bounded to ±887272; the difference / divide-by-TWAP_WINDOW stays well within int24 range. A formal proof would have to bound TWAP_WINDOW (testnet uses 3600 — fine).
- The `[1, 0]` vs `[0, 1]` payout convention assumes outcome index 0 is YES; that's set by the factory at `prepareCondition` time. A future change to that ordering breaks the resolver — covered by INV-TWAP-002 as part of the "exactly once + immutable" predicate.
