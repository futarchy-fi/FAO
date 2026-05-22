---
canonical: audit/wiki/_OUTLINE.md@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative map from wiki pages to the repo files they should be rebuilt from.
not-scope: Rebuild procedure and changelog rules live in [How This Wiki Is Maintained](how-this-wiki-is-maintained.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Source Of Truth Map

This page maps every page in the first wiki pass to the local files that should control future rebuilds. It matters because many FAO concepts are implemented across contracts, scripts, docs, and site files rather than one module. The canonical mechanism is that a page has one top-matter canonical source but may cite several supporting sources when a lifecycle spans contracts. `audit/wiki/_OUTLINE.md:20-35`, `audit/wiki/_OUTLINE.md:48-57`

## Meta And Concept Pages

| Page | Canonical source | Supporting sources |
|------|------------------|--------------------|
| [Futarchy Wiki](../README.md) | `audit/wiki/_OUTLINE.md:1-46` | `src/FutarchyRegistry.sol:205-326`, `src/FAOTwapResolver.sol:117-144` |
| [How This Wiki Is Maintained](how-this-wiki-is-maintained.md) | `audit/rubrics/topic-6-llm-wiki.md:17-185` | `audit/wiki/_OUTLINE.md:48-57` |
| [Source Of Truth Map](source-of-truth-map.md) | `audit/wiki/_OUTLINE.md:20-35` | all files cited in this table |
| [What Is Futarchy](../00-what-is-futarchy/README.md) | `docs/onchain-futarchy-design.md:9-34` | `src/FAOTwapResolver.sol:117-144`, `src/FutarchyArbitration.sol:13-31` |
| [Prior Art](../00-what-is-futarchy/prior-art.md) | `docs/onchain-futarchy-design.md:507-514` | `docs/commit-002-fao-factory.md:3-16`, `docs/commit-006-twap-resolver.md:3-9` |
| [Why Onchain](../00-what-is-futarchy/why-onchain.md) | `docs/onchain-futarchy-design.md:9-34` | `docs/onchain-futarchy-design.md:63-116`, `docs/onchain-futarchy-design.md:283-381` |

The concept pages are deliberately local-source-limited: they explain how this repository frames futarchy and name external prior art only where local docs name it. `docs/onchain-futarchy-design.md:507-514`

## FAO Repo Pages

| Page | Canonical source | Supporting sources |
|------|------------------|--------------------|
| [FAO Repo](../10-fao-repo/README.md) | `src/FutarchyRegistry.sol:20-52` | `site-testnet/shared.js:1-17`, `script/daemon/README.md:1-22` |
| [Architecture](../10-fao-repo/architecture.md) | `src/FutarchyRegistry.sol:67-86` | `src/FutarchyRegistryDeployers.sol:41-119`, `site-testnet/sepolia.js:11-23`, `script/daemon/submit.py:1-27` |
| [Create Instance](../10-fao-repo/lifecycle/00-create-instance.md) | `src/FutarchyRegistry.sol:205-326` | `site-testnet/create.js:1-25`, `src/FutarchyRegistryDeployers.sol:41-119` |
| [Sale](../10-fao-repo/lifecycle/10-sale.md) | `src/InstanceSale.sol:21-30` | `src/InstanceSale.sol:147-279`, `site-testnet/sale.js:32-49` |
| [Spot Liquidity](../10-fao-repo/lifecycle/20-spot-liquidity.md) | `src/SaleSpotSeeder.sol:93-106` | `src/InstanceSale.sol:247-279`, `src/FutarchyLiquidityManager.sol:203-326` |
| [Proposal](../10-fao-repo/lifecycle/30-proposal.md) | `src/FAOFutarchyFactory.sol:94-132` | `src/FAOFutarchyProposal.sol:38-94`, `src/FAOCreateAndBond.sol:113-162` |
| [Promote](../10-fao-repo/lifecycle/40-promote.md) | `src/FAOOfficialProposalOrchestrator.sol:121-178` | `src/UniswapV3LiquidityAdapter.sol:135-205`, `docs/commit-005-orchestrator.md:20-47` |
| [Resolve](../10-fao-repo/lifecycle/50-resolve.md) | `src/FAOTwapResolver.sol:117-144` | `docs/commit-006-twap-resolver.md:39-59`, `site-testnet/sepolia.js:374-422` |
| [Arbitration](../10-fao-repo/lifecycle/60-arbitration.md) | `src/ParameterizedArbitration.sol:35-183` | `src/ParameterizedArbitration.sol:189-485`, `src/FutarchyEvaluator.sol:66-101` |
| [Invariants](../10-fao-repo/invariants.md) | `docs/onchain-futarchy-design.md:63-88` | `src/FutarchyRegistry.sol:355-431`, `src/InstanceSale.sol:125-143`, `src/FAOTwapResolver.sol:83-144` |
| [Deployment History](../10-fao-repo/deployment-history.md) | `docs/sepolia-deployment-v0.md:1-31` | `docs/PHASE5-HANDOFF.md:113-125`, `script/DeployFutarchyRegistryV3.s.sol:13-22`, `site-testnet/shared.js:22-37` |
| [Glossary](../10-fao-repo/glossary.md) | `audit/wiki/_OUTLINE.md:20-35` | future pass |

Pages whose behavior spans multiple contracts should keep their top-matter canonical on the file that owns the primary state transition, then cite dependent modules inline. `audit/rubrics/topic-6-llm-wiki.md:36-56`

## Deferred Pages

| Page | Canonical source | Reason deferred |
|------|------------------|-----------------|
| [Agents Vision](../20-agents-vision/README.md) | `audit/wiki/_OUTLINE.md:31-35` | The outline says this area depends on the separate `futarchy-fi/agents` repo. `audit/wiki/_OUTLINE.md:43-45` |
| [Threat Model](../30-cross-cutting/threat-model.md) | `docs/onchain-futarchy-design.md:37-88` | The first pass writes a stub because full cross-cutting coverage belongs after lifecycle pages. `audit/wiki/_OUTLINE.md:34-35` |

## How This Might Be Wrong

- If a future page becomes more contract-specific, its canonical source should move from a design doc to the contract that owns the state. `audit/rubrics/topic-6-llm-wiki.md:36-56`
- If `FutarchyLiquidityManager` replaces `SaleSpotSeeder` in the live path, the spot-liquidity canonical file should change. `src/SaleSpotSeeder.sol:93-106`, `src/FutarchyLiquidityManager.sol:27-30`
- If site code stops using `site-testnet/shared.js` as the active-instance source, site citations in repo pages should be refreshed. `site-testnet/shared.js:1-17`, `site-testnet/shared.js:176-195`
- If the agents repo is cloned into the workspace, [Agents Vision](../20-agents-vision/README.md) should stop being an abstention stub. `audit/wiki/_OUTLINE.md:43-45`

## See Also

- [How This Wiki Is Maintained](how-this-wiki-is-maintained.md)
- [Futarchy Wiki](../README.md)
- [Architecture](../10-fao-repo/architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
