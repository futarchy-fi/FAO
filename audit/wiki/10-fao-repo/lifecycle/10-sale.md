---
canonical: src/InstanceSale.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for per-instance buy, finalize, ragequit, and liquidity-seed behavior.
not-scope: Pool seeding internals are covered in [Spot Liquidity](20-spot-liquidity.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Sale

The sale is the treasury gate for each registry-created futarchy token. It matters because the sale defines initial issuance, the bonding-curve price anchor, ragequit exits, and the handoff from treasury assets into liquidity. The canonical mechanism is `InstanceSale.buy` minting purchased tokens, `_finalizeInitialPhaseIfNeeded` freezing initial net sale, `ragequit` burning tokens for pro-rata treasury assets, and `seedLiquidityManager` minting assets into a manager while adding it to ragequit assets. `src/InstanceSale.sol:21-30`, `src/InstanceSale.sol:147-279`

## Configuration

`InstanceSale` is constructed with token, admin, initial price, minimum initial-phase sold, and initial phase duration; it rejects zero addresses, zero price, zero minimum, and zero duration. `src/InstanceSale.sol:78-98`

The sale starts at construction time with immutable `SALE_START` and `INITIAL_PHASE_END`, unlike the older `FAOSale` which has an admin `startSale()` path. `src/InstanceSale.sol:37-39`, `src/InstanceSale.sol:91-98`, `src/FAOSale.sol:176-183`

## Buy

`buy(numTokens)` rejects zero purchases, finalizes the initial phase if eligible, charges fixed initial price before finalization, and charges the current curve price after finalization. `src/InstanceSale.sol:147-168`, `src/InstanceSale.sol:170-180`

The current price is fixed before finalization and becomes `INITIAL_PRICE_WEI_PER_TOKEN + INITIAL_PRICE_WEI_PER_TOKEN * totalCurveTokensSold / initialNetSale` after finalization. `src/InstanceSale.sol:115-119`

Finalization requires the current time to be at or beyond `INITIAL_PHASE_END` and `initialTokensSold >= MIN_INITIAL_PHASE_SOLD`; it stores `initialNetSale = initialTokensSold` and emits `InitialPhaseFinalized`. `src/InstanceSale.sol:170-180`

## Ragequit

Ragequit uses `effectiveSupply = totalSupply - sale balance`, so sale-held tokens do not dilute exits. `src/InstanceSale.sol:125-143`

`ragequit(numTokens)` pulls the caller's approved token amount, burns it, computes the ETH share as `address(this).balance * burnAmount / effectiveSupply`, transfers ETH, then repeats the same pro-rata calculation for each active ragequit ERC20. `src/InstanceSale.sol:184-226`

The sale token itself cannot be added as a ragequit token, and only the admin can add or remove ragequit ERC20s. `src/InstanceSale.sol:230-243`

## Liquidity Seed

`seedLiquidityManager` is admin-only and non-reentrant; it mints token amount to the manager, forwards native value to `initializeFromSale`, and auto-adds the manager to the ragequit token list if it is not the sale token. `src/InstanceSale.sol:247-279`

This is the bridge between the sale and the fLP path. `SaleSpotSeeder.initializeFromSale` mints fLP to the sale, and sale ragequit then distributes that fLP pro-rata as an ERC20 treasury asset. `src/SaleSpotSeeder.sol:93-106`, `src/SaleSpotSeeder.sol:149-200`

## UI Reads And Writes

The sale page reads price, phase, sold amounts, total raised, ragequit tokens, and quote-ragequit data through a minimal ABI. `site-testnet/sale.js:32-49`, `site-testnet/sale.js:296-334`

Sale buy execution sends `sale.buy(n, { value: cost })`, and ragequit execution approves the sale for `n * 1e18` before calling `sale.ragequit(n)`. `site-testnet/sale.js:729-746`, `site-testnet/sale.js:748-771`

## How This Might Be Wrong

- If `InstanceSale` changes from whole-token `numTokens` to base-unit amounts, every UI and math statement here must be rewritten. `src/InstanceSale.sol:147-168`, `site-testnet/sale.js:729-746`
- If initial finalization becomes callable directly, the "finalizes on buy" framing becomes incomplete. `src/InstanceSale.sol:170-180`
- If sale-held tokens are included in effective supply, ragequit pro-rata math changes materially. `src/InstanceSale.sol:125-143`
- If `seedLiquidityManager` stops auto-adding the manager to ragequit assets, the fLP exit path must be updated. `src/InstanceSale.sol:271-279`

## See Also

- [Create Instance](00-create-instance.md)
- [Spot Liquidity](20-spot-liquidity.md)
- [Invariants](../invariants.md)
- [FAO Repo](../README.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
