---
canonical: src/FutarchyRegistry.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for creating a new registry-backed futarchy instance.
not-scope: Buying from the resulting sale is covered in [Sale](10-sale.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Create Instance

Instance creation is the registry's two-transaction deployment path for a new futarchy. It matters because public RPC gas-estimation limits shaped the contract interface, so the deploy flow is part of the protocol surface. The canonical mechanism is `createFutarchyPart1` for token, sale, and arbitration, followed by `createFutarchyPart2` for resolver, factory, orchestrator, spot pool, resolver wiring, and `READY` status. `src/FutarchyRegistry.sol:31-49`, `src/FutarchyRegistry.sol:205-326`

## Why Two Parts

The registry NatSpec states that a single transaction deploying all per-instance contracts plus the UniV3 spot pool crossed roughly 18.8M gas and was rejected by RPC gas-estimation caps, so the public API exposes Part1 and Part2. `src/FutarchyRegistry.sol:31-49`

The atomic `createFutarchy(...)` convenience path exists for callers without client-side gas caps, but the current line-level source shown in this pass exposes Part1 and Part2 as the load-bearing flow. `src/FutarchyRegistry.sol:47-49`, `src/FutarchyRegistry.sol:201-326`

## Part1: Reserve The Instance

`createFutarchyPart1` validates non-empty name, non-empty symbol, nonzero timeout, nonzero TWAP window, `twapWindow <= timeout`, and nonzero base bond. `src/FutarchyRegistry.sol:211-222`, `src/FutarchyRegistry.sol:355-366`

Part1 deploys the token and sale through `TOKEN_ARB_DEPLOYER.deployTokenAndSale`, then deploys `ParameterizedArbitration` through `TOKEN_ARB_DEPLOYER.deployArbitration`. `src/FutarchyRegistry.sol:224-233`, `src/FutarchyRegistryDeployers.sol:41-70`, `src/FutarchyRegistryDeployers.sol:31-39`

The pending instance stores metadata, creator, token, sale, arbitration, zero resolver/factory/orchestrator/spotPool, timestamp, `PENDING_PART2`, timeout, and TWAP window. `src/FutarchyRegistry.sol:235-257`

The token-and-sale deployer starts token supply at zero, grants `MINTER_ROLE` to the sale, grants token admin to the creator, and renounces its own roles. `src/FutarchyRegistryDeployers.sol:52-70`

## Part2: Complete The Stack

`createFutarchyPart2` rejects invalid IDs, already-ready instances, and instances not in `PENDING_PART2`. `src/FutarchyRegistry.sol:264-269`

Part2 derives the spot pool initialization price from `sale.INITIAL_PRICE_WEI_PER_TOKEN` rather than accepting caller-provided `sqrtPriceX96`. `src/FutarchyRegistry.sol:277-284`, `src/FutarchyRegistry.sol:368-381`

Part2 creates or initializes the token/WETH spot pool, translating orientation by token ordering and raising observation cardinality to the registry immutable. `src/FutarchyRegistry.sol:408-431`

Part2 deploys resolver, proposal factory, and orchestrator through `STACK_DEPLOYER.deployStack`, then locks the resolver to the orchestrator and marks the instance `READY`. `src/FutarchyRegistry.sol:286-310`, `src/FutarchyRegistryDeployers.sol:87-119`, `src/FAOTwapResolver.sol:83-88`

## Site Flow

The testnet create page uses the same two steps. Its ABI includes `createFutarchyPart1`, `createFutarchyPart2`, `instancesCount`, and `FutarchyPart1Created`; the handler submits Part1, parses the new ID from the event or `instancesCount - 1`, then submits Part2 with a 16,000,000 gas limit and redirects to `./?inst=<id>`. `site-testnet/create.js:1-25`, `site-testnet/create.js:89-130`

## How This Might Be Wrong

- If public RPC gas caps change or the registry bytecode shrinks, the two-part rationale may become historical. `src/FutarchyRegistry.sol:31-49`
- If `FutarchyInstance` gains fields, both Part1 storage and `site-testnet/shared.js` unpacking need regeneration. `src/FutarchyRegistry.sol:67-86`, `site-testnet/shared.js:55-74`
- If `INITIAL_PRICE_WEI_PER_TOKEN` stops existing on the sale, Part2's pool-price derivation will fail. `src/FutarchyRegistry.sol:14-18`, `src/FutarchyRegistry.sol:277-284`
- If `create.js` changes its gas limit or redirect, the site-flow section should be rebuilt. `site-testnet/create.js:120-130`

## See Also

- [Architecture](../architecture.md)
- [Sale](10-sale.md)
- [Deployment History](../deployment-history.md)
- [FAO Repo](../README.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
