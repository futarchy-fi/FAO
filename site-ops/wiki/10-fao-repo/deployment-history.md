---
canonical: docs/sepolia-deployment-v0.md@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative historical record for deployment evidence cited by this wiki pass.
not-scope: Live on-chain freshness checks are outside this wiki; use explorers or deployment scripts.
last-rebuilt: 2026-05-22T14:05:04Z
---
# Deployment History

Deployment history in this repo is evidence, not a live oracle. It matters because addresses, gas costs, and superseded versions explain why later registry and site code look the way they do. The canonical historical record for this pass is the Sepolia deployment document dated 2026-05-20, which lists shared dependencies, FAO v0 stack addresses, v1 superseded contracts, smoke promote, and first resolve. `docs/sepolia-deployment-v0.md:1-40`, `docs/sepolia-deployment-v0.md:57-119`

## Sepolia V0 Stack

The deployment document records Sepolia chain ID `11155111`, deployer `0x693E3FB46Bb36eE43C702FE94f9463df0691b43d`, and external WETH, ConditionalTokens, Wrapped1155Factory, and UniV3 factory addresses. `docs/sepolia-deployment-v0.md:1-17`

The same document records FAOToken, FAO/WETH spot pool, proposal implementation, resolver, factory, orchestrator, arbitration, CtfRouter, settlement oracle, and evaluator addresses for the FAO v0 stack. `docs/sepolia-deployment-v0.md:18-31`

Verification commands in the document checked resolver-to-orchestrator wiring, factory-to-resolver wiring, arbitration WETH, and arbitration evaluator. `docs/sepolia-deployment-v0.md:41-55`

## V1 To V2 Orchestrator Evidence

The deployment document marks a v1 resolver, factory, and orchestrator as superseded because observation cardinality 1000 ran out of gas. `docs/sepolia-deployment-v0.md:33-40`

The handoff document gives the operational cause: the first orchestrator's observation cardinality of 1000 required about 20M gas per pool for `increaseObservationCardinalityNext`, exceeded the attempted smoke-test gas limit, and the redeploy lowered the default to 100. `docs/PHASE5-HANDOFF.md:113-125`

The first live promote after the redeploy is recorded at tx `0xc42260d31afe320e1b522a64207c87c75da92401830cdecc22d4d4559f30928a`, block `10883925`, and gas `15_588_347`. `docs/sepolia-deployment-v0.md:57-70`

The first live resolve is recorded at tx `0x78e8426435f881b7837d8804c1b420818fd833a3e3f39ceba70a06677fb21c1e`, block `10885916`, gas `165_295`, and outcome `accepted = false`. `docs/sepolia-deployment-v0.md:89-119`

## Registry V3 To V5 Evidence

`DeployFutarchyRegistryV3` documents a registry version whose Part1 creates token, sale, and arbitration with no initial mint, using Sepolia WETH, CTF, Wrapped1155Factory, UniV3 factory, fee tier 500, and observation cardinality 30. `script/DeployFutarchyRegistryV3.s.sol:13-22`, `script/DeployFutarchyRegistryV3.s.sol:23-50`

The current `DeployFutarchyRegistry` script deploys or reuses a proposal implementation, deploys both registry sub-deployers, and deploys `FutarchyRegistry` with default observation cardinality 100. `script/DeployFutarchyRegistry.s.sol:21-35`, `script/DeployFutarchyRegistry.s.sol:45-64`, `script/DeployFutarchyRegistry.s.sol:87-109`

The testnet site tags registry address `0x18D1f4e57412b48436C7825B9018437C235bBC5C` as v5 and notes that v5 dropped `initialSqrtPriceX96` from the instance layout because the contract derives it from the sale price. `site-testnet/shared.js:22-37`, `site-testnet/shared.js:55-74`

## Adapter And Seeder Deployments

`DeployAndSetAdapter` deploys a UniV3 liquidity adapter for a fixed CTF, Wrapped1155Factory, FAO, WETH, and orchestrator, then calls `orchestrator.setAdapter`. `script/DeployAndSetAdapter.s.sol:10-33`

`DeploySaleSpotSeeder` deploys a sale spot seeder for a fixed sale, FAO token, WETH, NPM, spot pool, and fee tier 500. `script/DeploySaleSpotSeeder.s.sol:7-23`

These scripts are historical operator artifacts; this page does not claim the addresses remain current on May 22, 2026 without an explorer check. `audit/rubrics/topic-6-llm-wiki.md:134-159`

## Evidence Packs

The final evidence pack records 161 in-tree tests, 20h and 200h compressed simulations, live Sepolia execution, and fork-loop execution against deployed Sepolia state. `docs/PHASE5-FINAL-EVIDENCE.md:6-31`, `docs/PHASE5-FINAL-EVIDENCE.md:32-68`, `docs/PHASE5-FINAL-EVIDENCE.md:69-126`

The fork-loop results document records 3-cycle and 50-cycle fork runs and a partial 200-cycle run that stopped at cycle 70 because of an RPC-side `eth_call` gas cap, not an asserted EVM limit. `docs/phase5-fork-loop-results.md:7-33`, `docs/phase5-fork-loop-results.md:34-70`, `docs/phase5-fork-loop-results.md:96-118`

## How This Might Be Wrong

- If a new deployment manifest is added after 2026-05-20, this page should treat `docs/sepolia-deployment-v0.md` as historical rather than latest. `docs/sepolia-deployment-v0.md:1-6`
- If the site registry constant changes, the v5 registry line must be regenerated from `site-testnet/shared.js`. `site-testnet/shared.js:22-37`
- If a deployment script is edited without a new manifest, script defaults may not match live chain state. `script/DeployFutarchyRegistry.s.sol:21-35`
- If future evaluators require live `as_of_block` freshness, this page needs explorer or RPC evidence instead of local docs only. `audit/rubrics/topic-6-llm-wiki.md:134-159`

## See Also

- [FAO Repo](README.md)
- [Architecture](architecture.md)
- [Create Instance](lifecycle/00-create-instance.md)
- [Promote](lifecycle/40-promote.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
