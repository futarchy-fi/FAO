---
canonical: src/SaleSpotSeeder.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for sale-funded spot liquidity, fLP issuance, and fLP redemption.
not-scope: Proposal conditional-pool migration is covered in [Promote](40-promote.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Spot Liquidity

Spot liquidity is the bridge from sale treasury assets to a tradable token/WETH pool and a ragequittable LP claim. It matters because price discovery, Uniswap swap routes, and pro-rata exits depend on the sale turning treasury assets into LP exposure. The canonical mechanism in this pass is `InstanceSale.seedLiquidityManager` calling `SaleSpotSeeder.initializeFromSale`, which mints full-range UniV3 liquidity and issues fLP ERC20 shares back to the sale. `src/InstanceSale.sol:247-279`, `src/SaleSpotSeeder.sol:93-106`, `src/SaleSpotSeeder.sol:149-200`

## Sale Handoff

The sale admin calls `seedLiquidityManager(manager, tokenAmount, nativeAmount, spotAddData)`. The sale mints token amount to the manager, calls `initializeFromSale` with forwarded native value, and adds the manager to `ragequitTokens` so its ERC20 balance can flow through ragequit. `src/InstanceSale.sol:247-279`

This handoff treats the manager as an `IFutarchyLiquidityManager`, so `SaleSpotSeeder` and the more complex `FutarchyLiquidityManager` can both satisfy the hook shape. `src/InstanceSale.sol:5-6`, `src/SaleSpotSeeder.sol:4-6`, `src/FutarchyLiquidityManager.sol:203-226`

## SaleSpotSeeder Path

`SaleSpotSeeder` is an ERC20 named `Futarchy LP` with symbol `fLP`; it stores sale, admin, FAO token, WETH, NPM, spot pool, and fee tier as immutable configuration. `src/SaleSpotSeeder.sol:93-143`

Only the sale can call `initializeFromSale`. The seeder wraps native ETH into WETH, approves the nonfungible position manager, creates a full-range position on first seed, increases the same position on later seeds, and mints fLP to the sale equal to liquidity minted. `src/SaleSpotSeeder.sol:149-200`

The seeder's tick bounds are full range constants `-887270` and `887270`, matching the contract's v2 fLP design. `src/SaleSpotSeeder.sol:115-118`

## Ragequit And Redeem

Because the sale receives fLP and auto-adds the seeder to ragequit assets, a user who ragequits can receive a pro-rata fLP share alongside ETH and other ERC20 treasury assets. `src/InstanceSale.sol:211-226`, `src/InstanceSale.sol:271-279`, `src/SaleSpotSeeder.sol:195-200`

An fLP holder can call `redeem(fLPAmount)` to burn fLP, remove a pro-rata slice of the seeder-owned UniV3 position, and collect token0/token1 proceeds to the caller. `src/SaleSpotSeeder.sol:202-247`

`quoteRedeem` returns the liquidity slice for a proposed fLP amount without using pool price; it reads current NPM position liquidity and total fLP supply. `src/SaleSpotSeeder.sol:249-259`

## UI Surface

The sale page treats the first sale `ragequitTokens` entry as the seeder by convention and renders fLP balance when a wallet is connected. `site-testnet/sale.js:323-328`, `site-testnet/sale.js:406-418`

The same page quotes Uniswap V3 buy and sell prices from the active instance's spot pool, disables inline swaps when the pool has no liquidity or is too thin, and keeps sale/ragequit as the reliable fallback paths. `site-testnet/sale.js:217-263`, `site-testnet/sale.js:374-399`, `site-testnet/sale.js:451-482`

## More Complex Manager Path

`FutarchyLiquidityManager` is a separate fLP manager that can keep liquidity in spot mode, migrate 80% to conditional markets when an official proposal is live, migrate back after settlement and price alignment, and support emergency exit. `src/FutarchyLiquidityManager.sol:27-30`, `src/FutarchyLiquidityManager.sol:294-326`, `src/FutarchyLiquidityManager.sol:460-590`

This page does not make `FutarchyLiquidityManager` the canonical sale seeder because `SaleSpotSeeder` is the direct fLP seeder described by its own contract and deploy script. `src/SaleSpotSeeder.sol:93-106`, `script/DeploySaleSpotSeeder.s.sol:7-23`

## How This Might Be Wrong

- If the first ragequit token stops being the seeder by convention, the UI section should be rewritten. `site-testnet/sale.js:323-328`
- If the live path moves to `FutarchyLiquidityManager`, this page's canonical source should change. `src/FutarchyLiquidityManager.sol:203-326`
- If `SaleSpotSeeder` adds concentrated ranges, the full-range tick explanation becomes stale. `src/SaleSpotSeeder.sol:115-118`
- If fLP is no longer minted to the sale, ragequit will not distribute it through sale treasury accounting. `src/SaleSpotSeeder.sol:195-200`, `src/InstanceSale.sol:211-226`

## See Also

- [Sale](10-sale.md)
- [Promote](40-promote.md)
- [Invariants](../invariants.md)
- [Architecture](../architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
