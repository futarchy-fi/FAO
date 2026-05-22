---
canonical: docs/onchain-futarchy-design.md@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for the local repo's stated prior-art lineage and fork points.
not-scope: A comprehensive external history of futarchy is a future pass outside [FAO Repo](../10-fao-repo/README.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Prior Art

This page records the prior art that the FAO repo itself names or forks from. It matters because FAO v0 is easier to audit when the inherited pieces and deliberate departures are separated. The canonical local story is: Hanson supplies the futarchy idea, Seer supplies a CTF-and-wrapper market lineage, and FAO replaces Reality.eth settlement with an on-chain TWAP resolver. `docs/onchain-futarchy-design.md:507-514`, `docs/commit-002-fao-factory.md:3-16`, `docs/commit-006-twap-resolver.md:3-9`

## Local Prior-Art Boundary

The local design's references name Robin Hanson, Seer, Gnosis Conditional Tokens Framework, Uniswap V3, EIP-4399, and Flashbots. This pass treats those names as local lineage markers, not as a full bibliography, because the build scope says local repo sources are the source of truth. `docs/onchain-futarchy-design.md:507-514`, `audit/wiki/_OUTLINE.md:13-17`

The outline requests a prior-art page from "Hanson 2007 to Augur to Polymarket to Seer", but the local design file only gives detailed implementation rationale for Seer, CTF, Uniswap, prevrandao, and Flashbots. This pass therefore abstains from unsourced claims about Augur and Polymarket internals. `audit/wiki/_OUTLINE.md:13-17`, `docs/onchain-futarchy-design.md:507-514`

## Seer Fork Point

FAO v0 replaces Seer's `FutarchyFactory` and `FutarchyProposal` with FAO-owned versions that drop Reality.eth, derive `questionId` from `block.prevrandao`, and accept a generic oracle interface. `docs/commit-002-fao-factory.md:3-16`

The factory implementation matches that claim by computing `questionId` from market content, factory address, proposal index, and `block.prevrandao`, then using CTF to prepare a binary condition. `src/FAOFutarchyFactory.sol:76-92`, `src/FAOFutarchyFactory.sol:101-109`, `src/FAOFutarchyFactory.sol:144-150`

The proposal implementation is slim: it stores proposal metadata, condition identifiers, collateral tokens, wrapper addresses, and an oracle, then lets anyone call `resolve()` through that oracle. `src/FAOFutarchyProposal.sol:17-35`, `src/FAOFutarchyProposal.sol:38-94`

## Reality.eth Removal

The local design says existing Seer-style stacks use Reality.eth as the CTF oracle and FAO v0 removes that dependency. `docs/onchain-futarchy-design.md:16-19`

The resolver implementation supports the departure: it reads pool observations, decides the accepted side, and calls `CTF.reportPayouts` directly with `[1, 0]` or `[0, 1]`. `src/FAOTwapResolver.sol:117-144`

The commit note for the resolver states the same goal as a component-level change: replace Reality.eth with a UniV3 TWAP-to-CTF resolver. `docs/commit-006-twap-resolver.md:3-9`

## Canonical Infrastructure Choice

The design says FAO v0 keeps canonical UniV3 and canonical Wrapped1155Factory rather than forking the AMM. `docs/onchain-futarchy-design.md:333-347`

The deployment notes reflect that choice on Sepolia by listing Seer CTF, Seer Wrapped1155Factory, and the canonical UniswapV3 factory as external dependencies. `docs/sepolia-deployment-v0.md:7-17`

## Prior Art Still Missing

This page does not describe Augur, Polymarket, Hanson primary texts, EIP-4399 semantics, or Flashbots bundle APIs beyond what local repo docs say. A future pass should add external primary citations before making detailed claims about those systems. `docs/onchain-futarchy-design.md:507-514`, `audit/rubrics/topic-6-llm-wiki.md:134-159`

## How This Might Be Wrong

- If external primary references are later added to `docs/`, this page should stop abstaining on Augur and Polymarket detail. `audit/wiki/_OUTLINE.md:13-17`
- If the repo re-imports Seer or Reality.eth, the "Reality removal" section must be rebuilt from the new factory and resolver sources. `docs/commit-002-fao-factory.md:3-16`
- If `FAOFutarchyFactory.computeQuestionId` changes its hash inputs, the fork-point summary must change. `src/FAOFutarchyFactory.sol:76-87`
- If deployments move away from canonical UniV3 or Wrapped1155Factory, the infrastructure lineage becomes historical rather than active. `docs/onchain-futarchy-design.md:333-347`

## See Also

- [What Is Futarchy](README.md)
- [Why Onchain](why-onchain.md)
- [Proposal](../10-fao-repo/lifecycle/30-proposal.md)
- [Resolve](../10-fao-repo/lifecycle/50-resolve.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
