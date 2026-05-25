---
canonical: src/FAOFutarchyFactory.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for creating candidate futarchy proposal markets.
not-scope: Official promotion and liquidity migration are covered in [Promote](40-promote.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Proposal

A proposal is the candidate market object that later can be promoted into official conditional pools. It matters because the factory determines the CTF condition, wrapped outcome tokens, proposal clone, and question ID that every downstream component reads. The canonical mechanism is `FAOFutarchyFactory.createProposal`, which computes a prevrandao-derived question ID, prepares a binary CTF condition, deploys four wrapped ERC20 positions, clones `FAOFutarchyProposal`, initializes it, and stores it in `proposals`. `src/FAOFutarchyFactory.sol:76-132`

## Inputs

`CreateProposalParams` contains market name, description, and two collateral tokens, typically company token and WETH. `src/FAOFutarchyFactory.sol:30-35`, `src/FAOOfficialProposalOrchestrator.sol:134-140`

`createProposal` rejects empty market names and zero collateral token addresses. `src/FAOFutarchyFactory.sol:94-100`

The testnet proposal UI submits name, description, active instance token, and shared WETH to `factory.createProposal`. `site-testnet/sepolia.js:297-360`

## Question And Condition

The question ID is `keccak256(contentHash, address(this), proposalIndex, block.prevrandao)`, where content hash is derived from market name and description. `src/FAOFutarchyFactory.sol:76-87`

The condition ID is computed through CTF with the factory's oracle and two outcome slots. `src/FAOFutarchyFactory.sol:89-92`, `src/FAOFutarchyFactory.sol:144-150`

The local design and commit note explain why prevrandao is used: it prevents pre-computing the condition-to-wrapper-to-pool address chain before the slot where `createProposal` lands. `docs/commit-002-fao-factory.md:3-16`, `docs/onchain-futarchy-design.md:285-303`

## Wrapped Outcomes

The factory names four outcomes and four ERC20 wrappers: YES and NO for each collateral token. `src/FAOFutarchyFactory.sol:152-169`

For each of the four positions, `_deployERC20Positions` computes the collection ID and position ID, encodes wrapper metadata, and calls `Wrapped1155Factory.requireWrapped1155`. `src/FAOFutarchyFactory.sol:180-204`

The proposal clone exposes `wrappedOutcome(index)` so the orchestrator, resolver, adapter, and UI can discover wrapper addresses from the proposal. `src/FAOFutarchyProposal.sol:82-94`, `src/FAOOfficialProposalOrchestrator.sol:142-148`, `src/UniswapV3LiquidityAdapter.sol:183-195`, `site-testnet/sepolia.js:217-235`

## Arbitration Bridge

`FAOCreateAndBond` is a helper that folds factory proposal creation and arbitration proposal creation into one transaction. It derives `proposalId = uint256(uint160(futarchyProposal))`, creates an arbitration slot with `baseX` as the minimum activation bond, records the mapping, and emits `BondedProposalCreated`. `src/FAOCreateAndBond.sol:7-38`, `src/FAOCreateAndBond.sol:113-162`

The current `bonds.js` page still documents a stub bridge path in the browser: it derives the arbitration ID from the proposal address and lets the first escalator call `createProposalWithId`. `site-testnet/bonds.js:19-26`, `site-testnet/bonds.js:120-127`, `site-testnet/bonds.js:387-404`

## How This Might Be Wrong

- If `computeQuestionId` adds or removes hash inputs, the prevrandao lineage and address unpredictability claim must be rebuilt. `src/FAOFutarchyFactory.sol:76-87`
- If wrapped outcome indexing changes, promotion, resolver orientation, adapter wrapping, and UI payout displays may all stale together. `src/FAOFutarchyFactory.sol:152-204`, `src/FAOTwapResolver.sol:200-206`
- If the browser stub bridge is replaced by `FAOCreateAndBond`, the arbitration bridge section should cite the site change. `site-testnet/bonds.js:19-26`
- If factory `createProposal` becomes permissioned, the proposal creation overview must remove "candidate UI as any wallet" assumptions. `src/FAOFutarchyFactory.sol:94-132`

## See Also

- [Promote](40-promote.md)
- [Resolve](50-resolve.md)
- [Arbitration](60-arbitration.md)
- [Prior Art](../../00-what-is-futarchy/prior-art.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
