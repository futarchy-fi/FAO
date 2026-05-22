---
canonical: docs/onchain-futarchy-design.md@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative consolidated invariant checklist for the first FAO wiki pass.
not-scope: Full threat modeling is deferred to [Threat Model](../30-cross-cutting/threat-model.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Invariants

This page collects the invariants a reviewer should keep in mind while reading the lifecycle pages. It matters because many properties are cross-contract: breaking one contract's assumption can invalidate a later step. The canonical mechanism is that registry deployment, sale accounting, pool promotion, TWAP resolution, and bond arbitration each expose specific one-way or bounded state transitions. `docs/onchain-futarchy-design.md:63-88`, `src/FutarchyRegistry.sol:205-326`, `src/InstanceSale.sol:147-279`, `src/FAOOfficialProposalOrchestrator.sol:121-178`, `src/FAOTwapResolver.sol:117-144`, `src/ParameterizedArbitration.sol:221-485`

## Registry

- A Part1 instance can only be completed if its status is `PENDING_PART2`; Part2 rejects invalid IDs, `READY`, and non-pending states. `src/FutarchyRegistry.sol:264-269`
- Part2 marks resolver, factory, orchestrator, spot pool, and status in storage only after the stack deployer returns and resolver is locked to the orchestrator. `src/FutarchyRegistry.sol:286-310`
- Spot pool initialization price comes from `sale.INITIAL_PRICE_WEI_PER_TOKEN`, not user-supplied sqrt price. `src/FutarchyRegistry.sol:277-284`
- A created spot pool has its observation cardinality increased to `OBSERVATION_CARDINALITY`. `src/FutarchyRegistry.sol:408-431`

## Token And Sale

- Registry-created tokens start with zero supply when deployed with the sale, and the sale receives `MINTER_ROLE`; the deployer renounces its roles after granting admin to the creator. `src/FutarchyRegistryDeployers.sol:41-70`
- `InstanceSale.buy` requires exact ETH for the current price and mints `numTokens * 1e18` to the buyer. `src/InstanceSale.sol:147-168`
- Initial sale finalization freezes `initialNetSale` only when time has passed and minimum initial tokens were sold. `src/InstanceSale.sol:170-180`
- Ragequit excludes the sale's own token balance from effective supply before computing ETH and ERC20 shares. `src/InstanceSale.sol:125-143`, `src/InstanceSale.sol:184-226`
- The sale token cannot be added to `ragequitTokens`, preventing a direct distribution loop of the same token being burned. `src/InstanceSale.sol:230-237`

## Proposal And Promotion

- Proposal question IDs include market content, factory address, proposal index, and `block.prevrandao`. `src/FAOFutarchyFactory.sol:76-87`
- Proposal creation prepares a two-slot CTF condition and deploys exactly four wrapped position entries for two collaterals and two outcomes. `src/FAOFutarchyFactory.sol:101-132`, `src/FAOFutarchyFactory.sol:152-204`
- Promotion rejects an existing conditional pool if it is already initialized. `src/FAOOfficialProposalOrchestrator.sol:204-228`
- Promotion binds resolver before optional adapter migration and before builder-tip transfer. `src/FAOOfficialProposalOrchestrator.sol:150-178`
- The UniV3 adapter clears staged amounts after a successful migration, making each staging entry single-use. `src/UniswapV3LiquidityAdapter.sol:160-205`

## Resolution

- The resolver's orchestrator can be set only once. `src/FAOTwapResolver.sol:83-88`
- A proposal can bind only once because nonzero `anchorTimestamp` causes `AlreadyBound`. `src/FAOTwapResolver.sol:91-115`
- Resolution cannot run before `anchorTimestamp + TIMEOUT`, and a resolved proposal cannot resolve again. `src/FAOTwapResolver.sol:117-125`
- The resolver writes exactly one winning payout numerator in a two-element array. `src/FAOTwapResolver.sol:130-143`

## Arbitration

- YES activation requires at least `minActivationBond`; a NO-to-YES flip requires either the graduation threshold or the larger of twice the NO bond and the activation minimum. `src/ParameterizedArbitration.sol:221-239`
- NO can only match an existing YES amount and cannot originate from inactive state. `src/ParameterizedArbitration.sol:261-285`
- Timeout settlement pays through `withdrawable`, not by pushing WETH to the winner during finalization. `src/ParameterizedArbitration.sol:311-323`, `src/ParameterizedArbitration.sol:408-415`
- Graduation threshold grows as `baseX * 2^queueLen`, and `_tryGraduate` enforces `MAX_QUEUE` across queued plus active evaluation. `src/ParameterizedArbitration.sol:330-333`, `src/ParameterizedArbitration.sol:467-485`
- Evaluator configuration checks that the evaluator reports this arbitration address. `src/ParameterizedArbitration.sol:394-402`

## How This Might Be Wrong

- If any invariant becomes a test-only assumption rather than production code, this page should move the claim to a test reference or remove it. `audit/rubrics/topic-6-llm-wiki.md:36-56`
- If `InstanceSale` is superseded by `FAOSale` for registry-created instances, sale invariants should be split. `src/InstanceSale.sol:21-30`, `src/FAOSale.sol:12-25`
- If a future adapter does not use staged amounts, the single-use migration invariant should be adapter-specific. `src/UniswapV3LiquidityAdapter.sol:94-97`, `src/UniswapV3LiquidityAdapter.sol:201-205`
- If CTF payout semantics change, resolver and evaluator invariants must be re-audited together. `src/FAOTwapResolver.sol:135-143`, `src/FutarchyEvaluator.sol:86-101`

## See Also

- [Architecture](architecture.md)
- [Create Instance](lifecycle/00-create-instance.md)
- [Promote](lifecycle/40-promote.md)
- [Arbitration](lifecycle/60-arbitration.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
