---
canonical: docs/onchain-futarchy-design.md@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative plain-English overview of the futarchy mechanism used by FAO.
not-scope: FAO contract architecture is covered in [Architecture](../10-fao-repo/architecture.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# What Is Futarchy

Futarchy is a decision procedure where markets estimate whether a proposed action improves the chosen objective. In this repo's v0 design, the settlement signal is computed from conditional pool TWAPs and written on-chain without a human oracle. The canonical FAO mechanism is binary: compare YES and NO conditional pool prices, accept if YES has the higher normalized average tick, and report that result to CTF. `docs/onchain-futarchy-design.md:9-19`, `src/FAOTwapResolver.sol:117-144`

## Market Signal, Not Vote Count

The local design explicitly scopes FAO v0 as "100% on-chain futarchy governance" where proposals are decided by a market mechanism rather than voting, vetoes, or human oracle settlement. `docs/onchain-futarchy-design.md:11-19`

The decision surface is a pair of conditional markets. At promotion time the orchestrator creates or initializes YES and NO conditional pools; at resolution time the resolver compares their average ticks over a fixed window. `src/FAOOfficialProposalOrchestrator.sol:146-160`, `src/FAOTwapResolver.sol:123-141`

The comparison is intentionally strict: `accepted = yesAvgTick > noAvgTick`, so an exact tie resolves to NO in `FAOTwapResolver`. `src/FAOTwapResolver.sol:126-141`

## Where The Incentive Enters

FAO has two linked incentive layers. The conditional markets price the proposal outcome, while the arbitration contracts require WETH bonds to create, challenge, graduate, and settle proposals. `src/FAOTwapResolver.sol:117-144`, `src/FutarchyArbitration.sol:13-31`, `src/ParameterizedArbitration.sol:221-333`

The sale layer is separate from proposal resolution. A new registry instance launches its own token sale, and the sale can seed a liquidity manager so token holders can later exit through ragequit and receive pro-rata treasury assets. `src/FutarchyRegistry.sol:205-257`, `src/InstanceSale.sol:147-167`, `src/InstanceSale.sol:184-226`, `src/InstanceSale.sol:247-279`

## How FAO Makes It Onchain

The factory creates a CTF condition, deploys four wrapped ERC20 outcome tokens, clones a proposal contract, and records the proposal address. `src/FAOFutarchyFactory.sol:101-132`, `src/FAOFutarchyFactory.sol:180-204`

The orchestrator then reads the spot pool, creates or initializes the two conditional pools at the spot-derived price, binds the resolver, optionally calls a liquidity adapter, pays the builder tip, and emits the promotion event. `src/FAOOfficialProposalOrchestrator.sol:128-178`

The resolver is the CTF oracle for FAO proposals: it records proposal bindings, waits until `anchorTimestamp + TIMEOUT`, reads TWAP observations, writes CTF payouts, and marks the proposal resolved. `src/FAOTwapResolver.sol:91-115`, `src/FAOTwapResolver.sol:117-144`

## What This Page Does Not Claim

This page does not claim that every historical or academic futarchy design uses TWAP, CTF, Uniswap, or WETH bonds. Those are FAO v0 implementation choices documented in the local design and contract sources. `docs/onchain-futarchy-design.md:21-34`, `docs/onchain-futarchy-design.md:407-435`

## How This Might Be Wrong

- If `FAOTwapResolver.resolve` stops using strict `yesAvgTick > noAvgTick`, the summary of the decision rule must change. `src/FAOTwapResolver.sol:126-141`
- If a future version returns to a human oracle or Reality.eth, the "no human oracle" framing becomes stale. `docs/onchain-futarchy-design.md:16-19`
- If conditional pools move away from UniV3-style ticks, the TWAP explanation needs a different primitive. `src/FAOTwapResolver.sol:162-198`
- If arbitration is decoupled from WETH bonds, the incentive-layer summary should point to the new bond token logic. `src/ParameterizedArbitration.sol:65-77`

## See Also

- [Prior Art](prior-art.md)
- [Why Onchain](why-onchain.md)
- [FAO Repo](../10-fao-repo/README.md)
- [Resolve](../10-fao-repo/lifecycle/50-resolve.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
