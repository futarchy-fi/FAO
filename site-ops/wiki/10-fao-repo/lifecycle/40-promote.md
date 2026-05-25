---
canonical: src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAOOfficialProposalOrchestrator
scope: Authoritative for official proposal promotion and conditional-pool initialization.
not-scope: Candidate proposal creation is covered in [Proposal](30-proposal.md).
last-rebuilt: 2026-05-22T20:15:22Z
---
# Promote

Promotion turns a candidate proposal into the official market whose conditional pools will be resolved. It matters because the attack surface is concentrated here: price anchoring, pre-created pools, observation capacity, liquidity migration, and builder tips all happen in one transaction. The canonical mechanism is `createOfficialProposalAndMigrate`, which reads spot price, creates the proposal, initializes YES and NO pools, binds the resolver, optionally calls the adapter, pays the builder tip, refunds excess ETH, and emits the promotion event. `src/FAOOfficialProposalOrchestrator.sol:25-47`, `src/FAOOfficialProposalOrchestrator.sol:121-178`

## Access And Inputs

Only `ADMIN` can call `createOfficialProposalAndMigrate`, and the call requires `msg.value >= builderTip`. `src/FAOOfficialProposalOrchestrator.sol:78-81`, `src/FAOOfficialProposalOrchestrator.sol:121-127`

The function takes a market name, description, and builder tip; the company and currency tokens are fixed in the orchestrator constructor. `src/FAOOfficialProposalOrchestrator.sol:83-106`, `src/FAOOfficialProposalOrchestrator.sol:115-125`

The current constructor also fixes `ADAPTER_REPLACEABLE`; deployments that set it false make `setAdapter` one-shot after the first nonzero adapter, while testnet deployments can keep a hot-swap escape. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::setAdapter`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step A`

## Atomic Sequence

The orchestrator first reads the spot pool's `sqrtPriceX96` and tick in "currency per company" orientation, and records `anchorTimestamp = block.timestamp`. `src/FAOOfficialProposalOrchestrator.sol:128-130`, `src/FAOOfficialProposalOrchestrator.sol:182-200`

It then sets `proposalId = FACTORY.marketsCount()`, builds `CreateProposalParams`, and calls `FACTORY.createProposal`. `src/FAOOfficialProposalOrchestrator.sol:132-141`

After reading the four wrappers from the proposal, it calls `_maybeCreatePoolAndInit` for YES and NO pools. An existing initialized pool reverts with `PreCreated(pool)`, while a missing or uninitialized pool is initialized at the spot-derived price. `src/FAOOfficialProposalOrchestrator.sol:142-149`, `src/FAOOfficialProposalOrchestrator.sol:204-228`

The orchestrator increases observation cardinality on both conditional pools, binds the resolver with proposal, pools, company token, currency token, and anchor timestamp, then invokes the adapter if one is set. `src/FAOOfficialProposalOrchestrator.sol:150-160`

The builder tip is transferred only after the prior state transitions succeed, and any excess `msg.value` is refunded to the caller. `src/FAOOfficialProposalOrchestrator.sol:162-177`

## Price Orientation

The orchestrator standardizes spot price as "currency per company". If spot pool `token0` is company, it uses the raw Uniswap sqrt price and tick; if `token0` is currency, it inverts sqrt price and negates the tick. `src/FAOOfficialProposalOrchestrator.sol:182-200`

For a conditional pool, `_sqrtForOrderedPair` translates that canonical orientation into the pool's token0/token1 order. `src/FAOOfficialProposalOrchestrator.sol:230-245`

## Liquidity Adapter

The adapter is optional in the orchestrator: if `adapter` is the zero address, promotion still creates and binds pools but skips migration. `src/FAOOfficialProposalOrchestrator.sol:58-60`, `src/FAOOfficialProposalOrchestrator.sol:157-160`

Adapter replacement is not purely an admin-policy claim anymore: when `ADAPTER_REPLACEABLE` is false and an adapter is already set, `setAdapter` reverts with `AdapterAlreadySet`. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::AdapterAlreadySet`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::setAdapter`

The UniV3 adapter uses a stage-approve-promote pattern. Users call `stage(companyAmt, currencyAmt)`, approve the adapter, and the orchestrator-triggered `migrate` pulls staged amounts from `tx.origin`, splits both collaterals in CTF, wraps all four positions, mints full-range liquidity into YES and NO pools, clears staging, and emits `Migrated`. `src/UniswapV3LiquidityAdapter.sol:135-205`

The adapter restricts `migrate` to the wired orchestrator and rejects empty staging. `src/UniswapV3LiquidityAdapter.sol:151-164`

## Threat Rationale

The design document names pool pre-creation, same-block priority outbid, validator self-inclusion, wash trading, bond griefing, queue stuffing, hostile builder censorship, and observation insufficiency as attack vectors. `docs/onchain-futarchy-design.md:63-88`

The commit note for the orchestrator says the atomic promote flow closes the pre-initialized-pool path by reverting if a conditional pool already has nonzero `slot0.sqrtPriceX96`, and it treats failed bundles as no-tip attempts because the tip transfer is at the end. `docs/commit-005-orchestrator.md:20-47`

## How This Might Be Wrong

- If `ADAPTER_REPLACEABLE` changes deployment mode or is removed, the adapter section must be rebuilt from code rather than assuming the current one-shot-versus-hot-swap split. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If builder-tip transfer moves earlier in the transaction, the conditional-payment reasoning becomes wrong. `src/FAOOfficialProposalOrchestrator.sol:162-177`
- If `_maybeCreatePoolAndInit` stops rejecting initialized existing pools, the A1 defense summary must be revised. `src/FAOOfficialProposalOrchestrator.sol:204-228`
- If promotion shifts to `FutarchyOfficialProposalOrchestrator` for Algebra pools, this page should either split or change canonical source. `src/FutarchyOfficialProposalOrchestrator.sol:104-170`

## See Also

- [Proposal](30-proposal.md)
- [Resolve](50-resolve.md)
- [Why Onchain](../../00-what-is-futarchy/why-onchain.md)
- [Deployment History](../deployment-history.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
- Build pass: 18 (continuous HEAD refresh)
