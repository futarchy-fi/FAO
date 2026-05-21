# UniswapV3LiquidityAdapter

Status: v0 production (no longer a stub).
File: `src/UniswapV3LiquidityAdapter.sol`.
Math: `src/libraries/UniV3Math.sol` (inlined slices of Uniswap v3 core/periphery).
Tests: `test/UniswapV3LiquidityAdapter.t.sol` (12 cases).
Deploy: `script/DeployUniswapV3LiquidityAdapter.s.sol`.

## Why this exists

`FAOOfficialProposalOrchestrator.createOfficialProposalAndMigrate` creates the
condition, the 4 outcome wrappers, the 2 conditional UniV3 pools, initializes
each to spot, then calls `adapter.migrate(...)`. The earlier stub adapter only
emitted an event, so every conditional pool launched with zero liquidity and
every resolve tiebroke to NO. This adapter actually mints liquidity into both
the YES and NO pools inside the same atomic tx so price discovery can happen
during the TWAP window. See design doc §4.5 ("Orchestrator deposits dominant
liquidity at promote time").

## The user-facing flow

`migrate()` is called by the orchestrator inside the user's `promote` tx.
The adapter does not hold collateral and the orchestrator does not pass amounts,
so we use a **stage → approve → promote** pattern:

```
   user                      adapter                     orchestrator
   ----                      -------                     ------------
1. stage(c, w)  ─────────────▶  stagedFor[user] = (c, w)
2. fao.approve(adapter, c)
3. weth.approve(adapter, w)
4. createOfficialProposalAndMigrate(...) ─────────────────────▶
                                                              migrate(p, yes, no, spot, sqrt)
                            ◀─────────────────────────────────
                            pulls c FAO + w WETH from tx.origin
                            splits, wraps, mints liquidity
                            deletes stagedFor[user]
```

`stage` is single-use per (user, promote) — re-staging overwrites; a successful
migrate clears it. The pull uses `tx.origin` so the adapter doesn't care which
contract the orchestrator was invoked through.

## What `migrate()` actually does

1. Looks up `(companyAmt, currencyAmt)` from `stagedFor[tx.origin]`. Reverts
   if zero.
2. `transferFrom(tx.origin, adapter, companyAmt)` on COMPANY.
3. `transferFrom(tx.origin, adapter, currencyAmt)` on CURRENCY.
4. `approve(CTF, ∞)` on both collaterals (idempotent — only the first call costs
   storage).
5. `CTF.splitPosition(COMPANY, 0, conditionId, [1, 2], companyAmt)` —
   adapter now holds `companyAmt` ERC1155 of YES-position and `companyAmt`
   ERC1155 of NO-position.
6. Same for CURRENCY.
7. For each of the 4 ERC1155 balances, `CTF.safeTransferFrom(adapter, wrapper,
   tokenId, amount, tokenData)`. The wrapper implements `onERC1155Received` and
   mints `amount` of the ERC20 wrapped token 1:1 to the adapter (per
   Wrapped1155Factory semantics).
8. For each conditional pool, compute the full-range tick bounds clamped to
   `tickSpacing(fee=500) = 10`, derive liquidity via
   `UniV3Math.getLiquidityForAmounts(...)`, and call
   `pool.mint(adapter, tickLower, tickUpper, liquidity, callbackData)`.
9. `uniswapV3MintCallback(amount0Owed, amount1Owed, data)` is invoked by the
   pool. The adapter verifies `msg.sender == cb.pool` and transfers the owed
   amounts to the pool.
10. `delete stagedFor[tx.origin]`.
11. Emit `Migrated(proposal, yesPool, noPool, companyAmt, currencyAmt)`.

Total gas observed in unit tests: **~821 k** per `migrate()` call (with
fully-mocked CTF + pools). Real CTF + Wrapped1155 + UniV3 mainnet-bytecode will
be higher; we expect ~2-3 M but it must fit comfortably under a 30 M block.

## Why pull-from-tx.origin?

Alternative designs considered and rejected for v0:

- **Pre-fund the adapter**: caller transfers tokens to the adapter ahead of time.
  Rejected because any unrelated caller could then promote and consume that
  liquidity, creating a griefing vector.
- **Pull-from-caller (msg.sender)**: the orchestrator is `msg.sender` to the
  adapter. Would require the orchestrator to hold tokens too, which would mean
  another approval round-trip and a non-trivial change to the orchestrator's
  signature.
- **Encode amounts inside the orchestrator's `createOfficialProposalAndMigrate`
  call**: cleanest API, but the orchestrator's interface is shared by all
  liquidity adapters (Algebra, etc.) and amount semantics differ per AMM.
- **`pendingMigration[proposal]` mapping keyed by proposal address**: the
  proposal address is only known *after* the factory call inside the same atomic
  tx, so the user cannot stage by proposal address. We'd have to predict the
  clone address with `Clones.predictDeterministicAddress`, which couples staging
  to the factory's internal salt scheme.
- **`pendingMigration[tx.origin]` (chosen)**: simple, single-use, no
  orchestrator changes. User stages right before the promote tx and a
  successful promote clears the stage. Trade-off: a user can only have one
  promote in flight at a time, which is fine for v0 single-operator usage.

## Liquidity math (full range, v0)

Tick bounds:
- `tickLower = floor(MIN_TICK / tickSpacing) * tickSpacing`
- `tickUpper = floor(MAX_TICK / tickSpacing) * tickSpacing`

For fee tier 500 (the only tier we use in v0), `tickSpacing = 10` so:
- `tickLower = -887270`
- `tickUpper = 887270`

Liquidity is derived from staged amounts and the pool's current `sqrtPriceX96`
(which equals the spot price at promote time — the orchestrator just initialized
the conditional pool at the spot) via the canonical
`LiquidityAmounts.getLiquidityForAmounts` formula:

```
if sqrtPrice <= sqrtLower → liquidity = amount0 * sqrtLower*sqrtUpper / (sqrtUpper - sqrtLower)
elif sqrtPrice >= sqrtUpper → liquidity = amount1 / (sqrtUpper - sqrtLower)
else → liquidity = min(L0_from_amount0_inRange, L1_from_amount1_inRange)
```

Full-range is dilutive — the same staked liquidity supports a much wider price
range than a tight band around spot, so a wash-trade has to push price further
to manipulate TWAP. The trade-off is lower capital efficiency. For v0 this is
fine; concentrated ranges (e.g. ±20% around spot) are a follow-up.

## Why inlined math?

The full `@uniswap/v3-periphery` package pulls in `@uniswap/v3-core` plus a v0.7
Solidity OpenZeppelin set that conflicts with our pinned v4.x stack from sx-evm.
`UniV3Math.sol` is ~200 LoC, all of it verbatim from upstream (just re-typed
for Solidity 0.8 `unchecked` semantics) and well-known. The unit tests for the
adapter implicitly exercise `getLiquidityForAmounts` and `getSqrtRatioAtTick`
on every mint, and the constants (`MIN_TICK`, `MAX_TICK`, `MIN_SQRT_RATIO`,
`MAX_SQRT_RATIO`) are immutables anyone can re-derive.

## Wiring the adapter

Operator steps to wire the adapter to a deployed orchestrator:

```bash
# 1. Deploy.
forge script script/DeployUniswapV3LiquidityAdapter.s.sol \
  --rpc-url $SEPOLIA_RPC \
  --broadcast --legacy --gas-price 1100000000 -vvvv
# → prints UNISWAPV3_LIQUIDITY_ADAPTER=0x...

# 2. Wire (one-shot, immutable).
cast send $ORCHESTRATOR "setAdapter(address)" $UNISWAPV3_LIQUIDITY_ADAPTER \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
```

Then before each promote, the user (the orchestrator's admin) runs:

```bash
COMPANY_AMT=1000000000000000000000  # 1000 FAO
CURRENCY_AMT=5000000000000000000    # 5 WETH

cast send $UNISWAPV3_LIQUIDITY_ADAPTER "stage(uint256,uint256)" \
  $COMPANY_AMT $CURRENCY_AMT \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY

cast send $FAO  "approve(address,uint256)" $UNISWAPV3_LIQUIDITY_ADAPTER $COMPANY_AMT  ...
cast send $WETH "approve(address,uint256)" $UNISWAPV3_LIQUIDITY_ADAPTER $CURRENCY_AMT ...

cast send $ORCHESTRATOR "createOfficialProposalAndMigrate(string,string,uint256)" \
  '"my proposal"' '"description"' $TIP --value $TIP ...
```

`script/agents/auto_promote.sh` (the daemon) should be updated to include the
`stage` + 2 approves before the promote in each cycle.

## Multi-instance registry note

Each `FAOOfficialProposalOrchestrator` instance (one per registry-deployed
futarchy instance) needs its own adapter, because `migrate()` checks
`msg.sender == ORCHESTRATOR` and `ORCHESTRATOR` is immutable on the adapter.

Future work: `FutarchyRegistryDeployers` could deploy a per-instance adapter
alongside each orchestrator and call `orchestrator.setAdapter(addr)` in the same
transaction. For v0 this is a manual operator step.

## Limitations / known gaps

- **Full range only.** Concentrated ranges would lift the capital-efficiency
  ceiling but require running off-chain math to choose tick bounds.
- **Hardcoded fee tier in `_tickSpacingFor`.** The function knows the four
  canonical UniV3 fee tiers; arbitrary fees revert. Fine for v0 (we always use
  fee 500), but worth re-visiting if the orchestrator ever supports multiple
  tiers per pair.
- **No slippage protection.** `pool.mint` is deterministic on the current spot
  price, which the same orchestrator tx just initialized. There's no in-tx
  external trade that could move it, so slippage protection adds gas with no
  realistic mitigation.
- **No `unstage` / refund** for tokens approved but not migrated. The user can
  simply call `stage(0, 0)` (rejected — `ZeroAmount`) or set allowance to 0 to
  prevent accidental future pulls. A successful migrate clears state.
- **`approve(CTF, ∞)`** on COMPANY and CURRENCY is set once and reused across
  promotes. For real-world hardening we'd reset-to-zero between calls; this is
  fine for FAO and WETH (both well-behaved).
