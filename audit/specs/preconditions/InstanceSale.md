---
canonical: src/InstanceSale.sol
scope: Per-function preconditions, postconditions, frame conditions for InstanceSale. One row per external/public function; one section per state-mutating function.
not-scope: System-wide invariants (see `audit/specs/INVARIANTS.md`), threat enumeration (see `audit/specs/THREAT-MODEL.md`).
last-rebuilt: 2026-05-22
---

# Preconditions — `InstanceSale`

This is the function-level companion to `audit/specs/INVARIANTS.md`. Where invariants describe global properties, preconditions describe *what must be true at the call boundary* and postconditions *what is guaranteed to be true after the call returns*. Together they're the verification spec for the contract.

Notation:
- **PRE** — caller responsibility.
- **POST** — contract guarantee on successful return.
- **FRAME** — what the contract promises NOT to change.
- **REVERTS** — explicit failure modes (with error selector or `require` string).

## Constants & immutables

| Slot | Type | Invariant |
|---|---|---|
| `TOKEN` | `IMintableERC20` | non-zero, set in constructor, never mutates. |
| `ADMIN` | `address` | non-zero, set in constructor, never mutates. |
| `INITIAL_PRICE_WEI_PER_TOKEN` | `uint256` | > 0, set in constructor, never mutates. |
| `MIN_INITIAL_PHASE_SOLD` | `uint256` | > 0, set in constructor, never mutates. |
| `INITIAL_PHASE_DURATION` | `uint256` | > 0, set in constructor, never mutates. |
| `SALE_START` | `uint256` | == `block.timestamp` at construction, never mutates. |
| `INITIAL_PHASE_END` | `uint256` | == `SALE_START + INITIAL_PHASE_DURATION`, never mutates. |

## State-mutating functions

### `buy(uint256 numTokens) external payable nonReentrant`

| | |
|---|---|
| **PRE** | `numTokens > 0`. `msg.value` exactly equals `numTokens * currentPriceWeiPerToken()` evaluated AFTER `_finalizeInitialPhaseIfNeeded`. |
| **POST** | Either (a) `initialTokensSold += numTokens ∧ initialFundsRaised += numTokens * INITIAL_PRICE_WEI_PER_TOKEN` (initial phase), OR (b) `totalCurveTokensSold += numTokens ∧ totalCurveFundsRaised += numTokens * priceWeiPerToken` (bonding curve). In both cases `TOKEN.totalSupply` and `TOKEN.balanceOf(msg.sender)` increase by `numTokens * 1e18`. |
| **FRAME** | `INITIAL_PRICE_WEI_PER_TOKEN`, `MIN_INITIAL_PHASE_SOLD`, `INITIAL_PHASE_DURATION`, `SALE_START`, `INITIAL_PHASE_END`, `ADMIN`, `ragequitTokens[]`, `isRagequitToken[]` — unchanged. Other holders' balances unchanged. |
| **REVERTS** | `ZeroNumTokens()` if `numTokens == 0`. `IncorrectEth()` if `msg.value != costWei`. Reverts via inherited `nonReentrant` on reentry. |
| **EVENTS** | `Purchase(msg.sender, numTokens, costWei)`. If finalize triggered: `InitialPhaseFinalized(initialNetSale, initialFundsRaised)`. |
| **Invariants touched** | INV-TOKEN-001 (mint path), INV-SALE-001 (effectiveSupply still holds), INV-SALE-004 (monotone finalize). |

### `ragequit(uint256 numTokens) external nonReentrant`

| | |
|---|---|
| **PRE** | `numTokens > 0`. `msg.sender != address(this)`. `effectiveSupply() > 0`. `numTokens * 1e18 <= effectiveSupply()`. Caller has approved `numTokens * 1e18` of `TOKEN` to this contract. |
| **POST** | `TOKEN.balanceOf(msg.sender) -= numTokens * 1e18`. `TOKEN.totalSupply -= numTokens * 1e18`. `msg.sender` receives exactly `floor(address(this).balance_pre * burnAmount / effectiveSupply_pre)` wei of ETH. For every `r` in `ragequitTokens[]` with `isRagequitToken[r]`, `IERC20(r).balanceOf(msg.sender) += floor(IERC20(r).balanceOf(sale)_pre * burnAmount / effectiveSupply_pre)`. |
| **FRAME** | `INITIAL_PRICE_WEI_PER_TOKEN` ∧ constants. `ragequitTokens[]` order + length. `isRagequitToken` mapping. `ADMIN`. |
| **REVERTS** | `ZeroNumTokens()` if `numTokens == 0`. `CannotRagequitSelf()` if `msg.sender == address(this)`. `NothingToReturn()` if `effectiveSupply() == 0`. `"burn > effectiveSupply"` if `numTokens * 1e18 > effectiveSupply()`. `"transferFrom failed"` if the user's approval is insufficient. `EthTransferFailed()` if the ETH send fails. `"rq erc20 transfer failed"` if any ragequit-token transfer fails. |
| **EVENTS** | `Ragequit(msg.sender, burnAmount, ethShare)`. |
| **Invariants touched** | INV-SALE-002 (pro-rata payout), INV-SALE-003 (guards), INV-TOKEN-001 (burn path). |

### `addRagequitToken(address erc20) external onlyAdmin`

| | |
|---|---|
| **PRE** | `msg.sender == ADMIN`. `erc20 != address(0)`. `erc20 != address(TOKEN)`. `!isRagequitToken[erc20]`. |
| **POST** | `ragequitTokens.length += 1`. `ragequitTokens[ragequitTokens.length - 1] == erc20`. `isRagequitToken[erc20] == true`. |
| **FRAME** | All token balances. All other entries of `isRagequitToken`. Existing array entries (no reordering). |
| **REVERTS** | `NotAdmin()`. `ZeroAddr()`. `CannotAddSaleToken()`. `AlreadyOnList()`. |
| **EVENTS** | `RagequitTokenAdded(erc20)`. |

### `removeRagequitToken(address erc20) external onlyAdmin`

| | |
|---|---|
| **PRE** | `msg.sender == ADMIN`. `isRagequitToken[erc20] == true`. |
| **POST** | `isRagequitToken[erc20] == false`. (Note: the entry in `ragequitTokens[]` is intentionally not removed — ragequit loop treats it as a no-op.) |
| **FRAME** | All token balances. `ragequitTokens[]` length + order. All other entries of `isRagequitToken`. |
| **REVERTS** | `NotAdmin()`. `NotOnList()`. |
| **EVENTS** | `RagequitTokenRemoved(erc20)`. |

### `seedLiquidityManager(address manager, uint256 tokenAmount, uint256 nativeAmount, bytes calldata spotAddData) external onlyAdmin nonReentrant`

| | |
|---|---|
| **PRE** | `msg.sender == ADMIN`. `manager != address(0)`. `tokenAmount > 0 ∨ nativeAmount > 0`. `address(this).balance >= nativeAmount`. The deployed code at `manager` implements `IFutarchyLiquidityManager.initializeFromSale(uint256,bytes) payable returns (uint128)` and behaves correctly under reentry guard. |
| **POST** | If `tokenAmount > 0`: `TOKEN.balanceOf(manager) += tokenAmount` (via mint) and `TOKEN.totalSupply += tokenAmount`. `nativeAmount` wei is forwarded to `manager.initializeFromSale`. If `manager` was not previously on the ragequit list, it is appended; `isRagequitToken[manager] = true`. |
| **FRAME** | `INITIAL_PRICE_WEI_PER_TOKEN` ∧ constants. Other addresses' token balances. |
| **REVERTS** | `NotAdmin()`. `ZeroManager()`. `ZeroSeed()`. `InsufficientTreasury()` if `address(this).balance < nativeAmount`. Bubbles a revert from `manager.initializeFromSale` (or from the wrapped `TOKEN.mint` if `manager` isn't approved as a minter — not applicable since this sale holds MINTER_ROLE on the token). |
| **EVENTS** | If newly-added: `RagequitTokenAdded(manager)`. Always: `LiquiditySeeded(manager, tokenAmount, nativeAmount)`. |
| **Invariants touched** | INV-SALE-001 (token balance accounting), bonus INV-SALE-OPSEC (manager registration is admin-gated). |

## View functions (no postconditions; just predicates)

### `effectiveSupply() public view → uint256`

Returns `max(0, TOKEN.totalSupply() - TOKEN.balanceOf(address(this)))`. Pure of side effects. Establishes the denominator of every ragequit-share calculation. Equivalent statement: `INV-SALE-001`.

### `quoteRagequit(uint256 numTokens) external view → uint256 ethReturned`

Returns the same `ethShare` value `ragequit(numTokens)` would pay out, ignoring failure modes (returns 0 if `numTokens == 0` or `effectiveSupply == 0`). Used by the UI for cost-preview cards. UI MUST NOT treat the returned value as a commitment — the actual `ragequit` re-quotes against the live state.

### `currentPriceWeiPerToken() public view → uint256`

Returns `INITIAL_PRICE_WEI_PER_TOKEN` during the initial phase. After finalize:
`INITIAL_PRICE_WEI_PER_TOKEN + (INITIAL_PRICE_WEI_PER_TOKEN * totalCurveTokensSold) / initialNetSale`.
Equivalent to a linear bonding curve with slope `INITIAL_PRICE_WEI_PER_TOKEN / initialNetSale`.

### `totalAmountRaised()`, `totalSaleTokens()`, `bondingCurveSaleTokens()`, `ragequitTokensLength()`

Pure read accessors over storage. Aggregates documented inline; not load-bearing for correctness.

## Modifiers

### `onlyAdmin`

`if (msg.sender != ADMIN) revert NotAdmin();`. Used on `addRagequitToken`, `removeRagequitToken`, `seedLiquidityManager`.

### `nonReentrant`

Inherited from OpenZeppelin's `ReentrancyGuard`. Used on `buy`, `ragequit`, `seedLiquidityManager`. The standard CALLED → ENTERED → CALLED lifecycle. Prevents the ERC1155 / ERC20 receiver-hook reentry class — see THREAT-MODEL A12.

## Constructor

| | |
|---|---|
| **Args** | `(address token, address admin, uint256 initialPriceWeiPerToken, uint256 minInitialPhaseSold, uint256 initialPhaseDuration)`. |
| **PRE** | `token != 0 ∧ admin != 0 ∧ initialPriceWeiPerToken > 0 ∧ minInitialPhaseSold > 0 ∧ initialPhaseDuration > 0`. |
| **POST** | All immutables set. `SALE_START == block.timestamp`. `INITIAL_PHASE_END == block.timestamp + initialPhaseDuration`. All storage initialized to zero/default. |
| **REVERTS** | The five `require` checks. |

## See also

- `src/InstanceSale.sol` — implementation.
- `audit/specs/INVARIANTS.md` — global invariants.
- `audit/specs/THREAT-MODEL.md` — attack-vector mapping.
- `test/InstanceSale.t.sol` + `test/InstanceSale.invariants.t.sol` — verification.

## How this might be wrong

- The "no other holder balances change" frame conditions in `buy` / `ragequit` ignore the fact that custom ERC20 ragequit-tokens with hooks COULD mutate other balances during their `transfer`. Out of scope (admin's responsibility when adding to the ragequit list).
- POST of `removeRagequitToken` is deliberately weak — the array entry stays. This is documented because ragequit's loop treats it as a no-op; a stronger spec would require a swap-and-pop.
- The `seedLiquidityManager` POST is conditional on manager-correctness; the manager interface is duck-typed and the sale cannot enforce it. Failures are observable post-fact via events.
