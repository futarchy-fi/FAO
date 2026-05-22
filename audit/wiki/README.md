---
canonical: audit/wiki/_OUTLINE.md@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative entry point for this first wiki pass and its navigation graph.
not-scope: Contract-by-contract API detail belongs in [FAO Repo](10-fao-repo/README.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Futarchy Wiki

This wiki is the first source-cited map of the Futarchy.fi FAO repository and the adjacent agents vision. It matters because the repo mixes contract mechanisms, testnet UI, deployment scripts, and operator notes that are hard to read as one lifecycle. The canonical mechanism in this pass is a registry-created futarchy instance whose sale funds a token, whose proposal factory creates conditional markets, whose orchestrator initializes pools, and whose resolver reports the winning TWAP outcome to CTF. `audit/wiki/_OUTLINE.md:1-35`, `src/FutarchyRegistry.sol:205-326`, `src/InstanceSale.sol:147-279`, `src/FAOFutarchyFactory.sol:94-132`, `src/FAOOfficialProposalOrchestrator.sol:121-178`, `src/FAOTwapResolver.sol:117-144`

## Reading Order

Start with [What Is Futarchy](00-what-is-futarchy/README.md) if you need the decision model before the code. Read [FAO Repo](10-fao-repo/README.md) next if you are auditing implementation responsibilities, then follow the lifecycle pages from [Create Instance](10-fao-repo/lifecycle/00-create-instance.md) through [Arbitration](10-fao-repo/lifecycle/60-arbitration.md). The outline defines this first pass as `_meta`, `00-what-is-futarchy`, and the load-bearing FAO lifecycle before deeper per-contract pages. `audit/wiki/_OUTLINE.md:37-46`

## Page Index

| Area | Pages |
|------|-------|
| Meta | [How This Wiki Is Maintained](_meta/how-this-wiki-is-maintained.md), [Source Of Truth Map](_meta/source-of-truth-map.md) |
| Concept | [What Is Futarchy](00-what-is-futarchy/README.md), [Prior Art](00-what-is-futarchy/prior-art.md), [Why Onchain](00-what-is-futarchy/why-onchain.md) |
| FAO repo | [FAO Repo](10-fao-repo/README.md), [Architecture](10-fao-repo/architecture.md), [Invariants](10-fao-repo/invariants.md), [Deployment History](10-fao-repo/deployment-history.md), [Glossary](10-fao-repo/glossary.md) |
| Lifecycle | [Create Instance](10-fao-repo/lifecycle/00-create-instance.md), [Sale](10-fao-repo/lifecycle/10-sale.md), [Spot Liquidity](10-fao-repo/lifecycle/20-spot-liquidity.md), [Proposal](10-fao-repo/lifecycle/30-proposal.md), [Promote](10-fao-repo/lifecycle/40-promote.md), [Resolve](10-fao-repo/lifecycle/50-resolve.md), [Arbitration](10-fao-repo/lifecycle/60-arbitration.md) |
| Deferred | [Agents Vision](20-agents-vision/README.md), [Threat Model](30-cross-cutting/threat-model.md) |

The index includes only files created in this pass; the outline lists future per-contract, site, operator, and cross-cutting pages that are not written here. `audit/wiki/_OUTLINE.md:20-35`, `audit/wiki/_OUTLINE.md:43-45`

## What Is Stable Here

The contract lifecycle is anchored to local source lines rather than live chain state. Registry creation uses `createFutarchyPart1` to deploy token, sale, and arbitration, then `createFutarchyPart2` to deploy resolver, proposal factory, orchestrator, and spot pool. `src/FutarchyRegistry.sol:205-257`, `src/FutarchyRegistry.sol:259-326`

The site is treated as a client of the contracts, not as the canonical protocol. Its shared registry address, active-instance selection, and wallet state live in `site-testnet/shared.js`, while page-specific scripts read sale, proposal, and arbitration contracts from the active instance. `site-testnet/shared.js:22-37`, `site-testnet/shared.js:176-195`, `site-testnet/sepolia.js:11-23`, `site-testnet/sale.js:278-442`

Deployment pages record evidence that may be stale. The live Sepolia manifest states dates, addresses, gas, and smoke-test results, while the site points at a later registry address called v5 in code comments. `docs/sepolia-deployment-v0.md:1-31`, `docs/sepolia-deployment-v0.md:57-119`, `site-testnet/shared.js:22-37`

## Maintenance Contract

Every full page pins a canonical source in top matter, cites load-bearing claims with line ranges, names likely staleness modes, links to sibling pages, and records provenance. This mirrors the Topic-6 rubric's source traceability, graph health, abstention, and freshness dimensions. `audit/rubrics/topic-6-llm-wiki.md:17-27`, `audit/rubrics/topic-6-llm-wiki.md:36-56`, `audit/rubrics/topic-6-llm-wiki.md:134-159`, `audit/rubrics/topic-6-llm-wiki.md:161-185`

## How This Might Be Wrong

- If `audit/wiki/_OUTLINE.md` changes its build order or target pages, this README's navigation may stop matching the intended scope. `audit/wiki/_OUTLINE.md:37-46`
- If `FutarchyRegistry.FutarchyInstance` changes fields, the lifecycle summary and site-active-instance assumptions can stale together. `src/FutarchyRegistry.sol:67-86`, `site-testnet/shared.js:55-74`
- If a later pass creates per-contract pages, this README should link to those pages rather than overloading lifecycle pages. `audit/wiki/_OUTLINE.md:20-22`
- If live deployments are superseded again, the deployment-history links should remain historical rather than pretending to be current state. `docs/sepolia-deployment-v0.md:33-40`, `site-testnet/shared.js:22-37`

## See Also

- [How This Wiki Is Maintained](_meta/how-this-wiki-is-maintained.md)
- [Source Of Truth Map](_meta/source-of-truth-map.md)
- [FAO Repo](10-fao-repo/README.md)
- [Architecture](10-fao-repo/architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
