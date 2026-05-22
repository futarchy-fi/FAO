---
canonical: src/FutarchyRegistry.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative architectural map of FAO contracts, site, and operator wiring.
not-scope: Per-step execution details live in the [Lifecycle](lifecycle/00-create-instance.md) pages.
last-rebuilt: 2026-05-22T14:05:04Z
---
# Architecture

FAO architecture is easiest to read as three planes: deployment, market execution, and observation. It matters because a user-facing action often crosses all three planes, such as creating an instance in the site, deploying contracts through the registry, then rendering the resulting addresses back in the UI. The canonical mechanism is a registry-owned deployment spine plus per-instance contracts that share external CTF, Wrapped1155Factory, UniV3, and WETH infrastructure. `src/FutarchyRegistry.sol:20-52`, `site-testnet/create.js:1-25`, `site-testnet/shared.js:176-195`

## Deployment Plane

`FutarchyRegistry` keeps shared dependencies immutable: proposal implementation, CTF, Wrapped1155Factory, UniV3 factory, WETH, fee tier, observation cardinality, and two sub-deployers. `src/FutarchyRegistry.sol:93-103`, `src/FutarchyRegistry.sol:172-199`

The split deployers keep bytecode outside the registry. `TokenAndArbitrationDeployer` can deploy a generic token, an arbitration instance, or a token plus sale, while `FutarchyStackDeployer` deploys resolver, proposal factory, and orchestrator. `src/FutarchyRegistryDeployers.sol:15-23`, `src/FutarchyRegistryDeployers.sol:41-70`, `src/FutarchyRegistryDeployers.sol:73-119`

Each registered instance stores user-facing metadata, creator, per-instance contract addresses, creation timestamp, lifecycle status, timeout, and TWAP window. `src/FutarchyRegistry.sol:67-86`

## Market Execution Plane

Sale execution begins with `InstanceSale.buy`, which mints whole-token purchases at a fixed initial price until finalization, then prices curve purchases from `INITIAL_PRICE_WEI_PER_TOKEN` and `initialNetSale`. `src/InstanceSale.sol:115-119`, `src/InstanceSale.sol:147-168`, `src/InstanceSale.sol:170-180`

Ragequit execution burns the caller's token balance after `transferFrom`, pays a pro-rata ETH share, and loops through whitelisted ERC20 ragequit assets. `src/InstanceSale.sol:125-143`, `src/InstanceSale.sol:184-226`

Proposal execution starts in `FAOFutarchyFactory.createProposal`, which computes a question ID, prepares a CTF condition, deploys wrapped outcome tokens, clones the proposal implementation, initializes it, and stores the proposal. `src/FAOFutarchyFactory.sol:94-132`

Promotion execution is admin-gated in `FAOOfficialProposalOrchestrator`, reads spot price, creates a proposal, initializes YES and NO pools, raises observation cardinality, binds the resolver, optionally calls the adapter, pays the builder tip, refunds excess ETH, and emits an event. `src/FAOOfficialProposalOrchestrator.sol:78-81`, `src/FAOOfficialProposalOrchestrator.sol:121-178`

## Observation Plane

The resolver observes conditional pools only after a proposal is bound by the orchestrator. `setOrchestrator` is one-shot, `bindProposal` is restricted to the orchestrator, and each proposal can bind only once. `src/FAOTwapResolver.sol:83-115`

Resolution reads TWAP observations over the configured window, normalizes each tick to "currency per company" orientation, compares YES and NO, writes binary payouts to CTF, and stores the accepted flag. `src/FAOTwapResolver.sol:117-144`, `src/FAOTwapResolver.sol:162-198`

The testnet site observes the same state. `sepolia.js` reads factory proposals, resolver bindings, CTF payouts, and readiness to resolve, then renders candidate, TWAP-window, ready, or resolved status. `site-testnet/sepolia.js:168-260`, `site-testnet/sepolia.js:262-288`

## Operator Plane

The deployment script for the registry wires default Sepolia WETH, CTF, Wrapped1155Factory, UniV3 factory, fee tier, observation cardinality, and proposal implementation before deploying the registry. `script/DeployFutarchyRegistry.s.sol:21-35`, `script/DeployFutarchyRegistry.s.sol:45-64`, `script/DeployFutarchyRegistry.s.sol:87-109`

The promote daemon scaffold is designed to build a `createOfficialProposalAndMigrate` transaction with `msg.value = TIP` and submit it as a Flashbots bundle targeting the next block. `script/daemon/submit.py:1-31`, `script/daemon/submit.py:87-107`, `script/daemon/submit.py:125-166`

The agent README defines legitimate proposer and adversarial roles for phase-5 validation; it describes proposal creation, pool pre-creation attempts, same-block outbid attempts, wash trading, bond griefing, and queue stuffing. `script/agents/README.md:7-59`

## How This Might Be Wrong

- If deployers gain state or permission checks, the "stateless deployer" interpretation should be removed. `src/FutarchyRegistryDeployers.sol:15-23`, `src/FutarchyRegistryDeployers.sol:73-79`
- If `FAOOfficialProposalOrchestrator` stops being the live promotion path, this page must distinguish it from `FutarchyOfficialProposalOrchestrator`. `src/FAOOfficialProposalOrchestrator.sol:25-47`, `src/FutarchyOfficialProposalOrchestrator.sol:32-35`
- If `site-testnet/shared.js` is replaced by an indexer, the observation-plane UI mapping should cite the new source. `site-testnet/shared.js:176-195`
- If daemon code graduates from scaffold to production multi-builder fan-out, operator claims should cite the implementation rather than the README intent. `script/daemon/submit.py:25-27`

## See Also

- [FAO Repo](README.md)
- [Create Instance](lifecycle/00-create-instance.md)
- [Promote](lifecycle/40-promote.md)
- [Resolve](lifecycle/50-resolve.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
