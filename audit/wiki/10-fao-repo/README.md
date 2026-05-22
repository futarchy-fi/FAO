---
canonical: src/FutarchyRegistry.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative overview of the FAO repo's contract, site, and operator surfaces.
not-scope: The conceptual futarchy model is covered in [What Is Futarchy](../00-what-is-futarchy/README.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# FAO Repo

The FAO repo is a working on-chain futarchy stack, not only a token sale or a proposal UI. It matters because instance creation, sale accounting, liquidity, conditional markets, TWAP resolution, and bond arbitration live in separate modules that compose at runtime. The canonical repo mechanism is the `FutarchyRegistry`, which deploys per-instance token, sale, arbitration, resolver, proposal factory, orchestrator, and spot pool while reusing shared CTF, Wrapped1155Factory, UniV3 factory, proposal implementation, and WETH. `src/FutarchyRegistry.sol:20-52`, `src/FutarchyRegistry.sol:67-86`, `src/FutarchyRegistry.sol:172-199`

## Three Surfaces

The contract surface is rooted in `src/`. The registry creates instances, `InstanceSale` handles buys and ragequit, `FAOFutarchyFactory` creates proposal markets, `FAOOfficialProposalOrchestrator` promotes official proposals, `FAOTwapResolver` resolves them, and `ParameterizedArbitration` handles bonds. `src/FutarchyRegistry.sol:205-326`, `src/InstanceSale.sol:147-279`, `src/FAOFutarchyFactory.sol:94-132`, `src/FAOOfficialProposalOrchestrator.sol:121-178`, `src/FAOTwapResolver.sol:117-144`, `src/ParameterizedArbitration.sol:189-485`

The site surface is under `site-testnet/`. `shared.js` loads all registry instances, picks an active instance, exposes it on `window.activeInstance`, and fires events for page scripts; sale and proposal pages then read active-instance contract addresses rather than hardcoding every per-instance contract. `site-testnet/shared.js:1-17`, `site-testnet/shared.js:176-195`, `site-testnet/shared.js:212-232`, `site-testnet/sale.js:278-442`, `site-testnet/sepolia.js:168-260`

The operator surface is under `script/` and `docs/`. Deployment scripts wire shared infrastructure and per-instance contracts, while daemon and agent scripts document promotion retries, proposal creation, attack attempts, and metrics collection. `script/DeployFutarchyRegistry.s.sol:17-44`, `script/daemon/README.md:1-22`, `script/daemon/submit.py:1-31`, `script/agents/README.md:1-24`

## Lifecycle Pages

Read the implementation as a pipeline:

| Step | Page | Primary transition |
|------|------|--------------------|
| 1 | [Create Instance](lifecycle/00-create-instance.md) | Registry Part1 then Part2 deploy per-instance stack. `src/FutarchyRegistry.sol:205-326` |
| 2 | [Sale](lifecycle/10-sale.md) | Buyers mint tokens and may ragequit for pro-rata treasury assets. `src/InstanceSale.sol:147-226` |
| 3 | [Spot Liquidity](lifecycle/20-spot-liquidity.md) | Sale admin seeds spot LP and fLP becomes ragequittable. `src/InstanceSale.sol:247-279`, `src/SaleSpotSeeder.sol:149-200` |
| 4 | [Proposal](lifecycle/30-proposal.md) | Factory creates CTF condition, wrappers, and proposal clone. `src/FAOFutarchyFactory.sol:101-132` |
| 5 | [Promote](lifecycle/40-promote.md) | Orchestrator creates conditional pools, binds resolver, migrates liquidity, and tips builder. `src/FAOOfficialProposalOrchestrator.sol:121-178` |
| 6 | [Resolve](lifecycle/50-resolve.md) | Resolver reads TWAP and reports CTF payouts. `src/FAOTwapResolver.sol:117-144` |
| 7 | [Arbitration](lifecycle/60-arbitration.md) | Bonds escalate, graduate, settle, and pay out through withdrawable balances. `src/ParameterizedArbitration.sol:221-485` |

## Historical And Live-State Warning

Deployment docs and site constants are historical evidence unless they explicitly say they are current. `docs/sepolia-deployment-v0.md` records a 2026-05-20 Sepolia stack and smoke tests, while `site-testnet/shared.js` points the frontend at a registry address tagged v5. `docs/sepolia-deployment-v0.md:1-31`, `docs/sepolia-deployment-v0.md:57-119`, `site-testnet/shared.js:22-37`

## How This Might Be Wrong

- If the site moves from registry-driven active instances to a backend indexer, the site-surface section will be stale. `site-testnet/shared.js:176-195`
- If `FutarchyRegistryDeployers` starts deploying adapters or liquidity managers too, this overview will understate per-instance deployment. `src/FutarchyRegistryDeployers.sol:87-119`
- If `ParameterizedArbitration` is replaced by a different challenge game, the lifecycle table must point to the new settlement page. `src/ParameterizedArbitration.sol:35-77`
- If future wiki passes add contract pages, this page should become an index instead of carrying contract-level detail. `audit/wiki/_OUTLINE.md:20-22`

## See Also

- [Architecture](architecture.md)
- [Invariants](invariants.md)
- [Deployment History](deployment-history.md)
- [Create Instance](lifecycle/00-create-instance.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
