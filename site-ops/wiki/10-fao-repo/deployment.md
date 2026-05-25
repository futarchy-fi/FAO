---
canonical: deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5
scope: Authoritative wiki coverage of active deployment manifests, generated ABI bindings, ops Pages deployment, and the timelock deployment boundary.
not-scope: Historical deploy evidence lives in [Deployment History](deployment-history.md); operator process lives in [Ops](../30-cross-cutting/ops.md).
last-rebuilt: 2026-05-23T03:13:06Z
---
# Deployment

Deployment state flows through manifests, schema checks, generated browser ABI files, Etherscan verification gates, deploy-script security modes, coupling checks, E2E deployment-path checks, and static Pages deploys. It matters because active contract addresses, browser bindings, ops dashboards, adapter mutability, source-verification queues, bytecode drift, and future timelock addresses have different freshness rules. The canonical mechanism for the testnet site is still `shared.js::loadDeployments()`: fetch `./deployments.json`, use `active.registry` when present, and fall back only if the fetch fails; deploy scripts carry the Sepolia-versus-mainnet `ADAPTER_REPLACEABLE` posture, while coupling notes currently record active stack-deployer bytecode drift. `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::active`, `site-testnet/shared.js@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::loadDeployments`, `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Current HEAD drift: stack deployer`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::testFork_activeRegistryWiringMatchesManifest`

## Changed Since Last Refresh

The prior wiki refresh at `3fad3cad278325c13a191c472f1be9ba5d15db02` covered schema validation, deployment sync, generated ABI JSON, and `window.loadFaoAbi`. `audit/wiki/10-fao-repo/deployment.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#deployment`

The requested target `21f29adc8dd1ac6a0e3f4b5d5ae231022316a309` is an ancestor of this refresh lineage; `f04b27554031b3c291ef2acb6e9bf11c852c6288` added the extra `INV-ORCH-002` invariant commit after `21f29adc`, while this page was refreshed through committed source `5a3953405c6017b990b4b3add843dff77c5f6f86`. `audit/specs/INVARIANTS.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#pass-status`, `test/FAOOfficialProposalOrchestrator.invariants.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::invariant_INV_ORCH_002_refusesPreInitializedPool`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`

The deployment-relevant changes since that refresh are: F1 now exercises create-instance against an Anvil fork, the ops portal is deployed through Cloudflare Pages project `fao-ops`, `FAOTimelock` sketches the future mainnet timelock address that is not yet in `deployments.json::active`, and ABI JSON was regenerated for two browser-used contracts. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::F1`, `site-ops/README.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#cloudflare-pages`, `src/FAOTimelock.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::FAOTimelock`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, `fb9a1a5` added the Etherscan verification gate, updated root and site deployment manifests, and made `verification_todo` the active source-verification queue for unverified v5 contracts. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verificationTodo`, `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`, `site-testnet/deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, `site-testnet/abis/FAOOfficialProposalOrchestrator.json` and `site-testnet/abis/FutarchyStackDeployer.json` were resynced, so deployment freshness now includes those generated ABI bindings as current HEAD artifacts. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::setAdapter`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::constructor`

At source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, F1's deployment-path evidence first routed public Sepolia RPC to local Anvil, injected an Anvil wallet provider, submitted the create form, and verified the registry count plus sale address on the fork; the current worktree overlay later switches the provider step to Synpress/MetaMask helpers while keeping fork-routed RPC. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::routeSepoliaRpcToFork`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::installAnvilWallet`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::readInstance`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, `DeployFutarchyRegistry.s.sol` gained an `ADAPTER_REPLACEABLE` environment switch that defaults to Sepolia hot-swap mode and must be set to `0` for mainnet, while `FutarchyStackDeployer` forwards the mode into each orchestrator constructor. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::vm.envOr("ADAPTER_REPLACEABLE"`, `src/FutarchyRegistryDeployers.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::constructor(bool adapterReplaceable)`, `src/FutarchyRegistryDeployers.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, deployment coupling gained a concrete drift note and a registry-wiring fork test. The drift note says `active.futarchy_stack_deployer` still matches pre-`ADAPTER_REPLACEABLE` Sepolia runtime, while `testFork_activeRegistryWiringMatchesManifest` checks registry dependencies against active/shared manifest fields. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::pre-ADAPTER_REPLACEABLE deployer`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Do not skip or bless this mismatch`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::testFork_activeRegistryWiringMatchesManifest`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, deployment-manifest sources did not change, but deployment-adjacent evidence did: the ops dashboard sync now copies dashboard assets and writes `summary.json`, auto-sync hashes dashboard assets as well as JSONL, and the deployed dashboard keeps CDN scripts in the HTML with `defer`. `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::dashboard assets`, `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::summary.json`, `scripts/auto-sync-ops.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::audit/dashboard/index.html`, `site-ops/fao/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::script defer`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, the deployment page's browser-coupling source changed again: the live-site spec now validates sale/token links through `expectAddressLink`, so compact address text and full address text are both valid if the link href and optional title match the registry-returned address. `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::visible full address`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::visible compact address`

Committed source `f96ced010f19032837e96094c935572a2320230f` changes the active manifest contract: `proposal_impl_v5` is now `0xF9ed9a3ff5A2ab89C6E01A0D959D03Ce7a845cD0`, `verification_todo` names it as `FAOFutarchyProposal v5`, the Solidity coupling test asserts registry `PROPOSAL_IMPL()` equals the manifest field, and the bytecode script treats it as an optional-null key that is checked when present. `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `deployments.json@f96ced010f19032837e96094c935572a2320230f::active.proposal_impl_v5 FAOFutarchyProposal v5`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`, `scripts/check-coupling-bytecode.js@f96ced010f19032837e96094c935572a2320230f::optionalNull`

## Manifest Contract

The manifest records `version`, `network`, `chain_id`, shared dependency addresses, active stack addresses, deprecated addresses, verified addresses, verification TODOs, and notes. `deployments.schema.json` is the executable shape for those keys, including required `shared`, `active`, `etherscan_verified`, `verification_todo`, and `notes` entries. `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::$schema`, `deployments.schema.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::required`

`DEPR-9` makes unvalidated deployment manifests obsolete: manifest changes must pass schema validation and root/site sync. `audit/state/DEPRECATIONS.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::DEPR-9`, `scripts/validate-deployments.sh@f04b27554031b3c291ef2acb6e9bf11c852c6288::Validate deployments`, `scripts/check-deployments-sync.sh@f04b27554031b3c291ef2acb6e9bf11c852c6288::deployments.json sync OK`

The active deployment values currently include registry, token/arbitration deployer, futarchy stack deployer, proposal implementation, UniV3 liquidity adapter, and operator address; in committed source, the proposal implementation is no longer null. `deployments.json@f96ced010f19032837e96094c935572a2320230f::active`, `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`

The current `verification_todo` queue names active registry, token/arbitration deployer, futarchy stack deployer, UniV3 liquidity adapter, and future v5 per-instance contracts. `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

The manifest does not yet record whether active orchestrators were deployed in replaceable-adapter mode; that mode is currently inferred from deploy script inputs and orchestrator constructor arguments. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::AdapterReplaceable`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::constructor`

The manifest also still points at a stack deployer whose on-chain normalized runtime hash differs from the current local normalized hash after `ADAPTER_REPLACEABLE`; this is recorded as real source-vs-deploy drift, not a nondeterministic artifact issue. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::local normalized hash`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::on-chain normalized hash`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::real source-vs-deploy drift`

The current coupling note also rejects the older broadcast registry as a shortcut: its instance tuple no longer decodes with the current registry ABI, so replacing the active V3 registry with that address would trade bytecode drift for ABI drift. `audit/state/COUPLING-NOTES.md@HEAD::run-latest.json`, `audit/state/COUPLING-NOTES.md@HEAD::registry ABI mismatch`, `audit/state/COUPLING-NOTES.md@HEAD::Keep the active V3 registry`

## Site Runtime Flow

`shared.js` fetches `./deployments.json` with `cache: 'no-cache'`, writes `window.faoDeployments` when the JSON has `active.registry`, and catches failures by returning `null`. `site-testnet/shared.js@f04b27554031b3c291ef2acb6e9bf11c852c6288::loadDeployments`

`shared.js` exposes `window.loadFaoAbi(contractName)`, which fetches `./abis/<Contract>.json` and caches the parsed ABI. `DEPR-10` declares the old hand-maintained registry ABI literal superseded by generated ABI JSON, and HEAD's resync includes orchestrator and stack-deployer ABI files. `site-testnet/shared.js@f04b27554031b3c291ef2acb6e9bf11c852c6288::loadAbi`, `audit/state/DEPRECATIONS.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::DEPR-10`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`

F1 uses the current deployment path as an executable browser check: it reads `instancesCount()`, routes browser Sepolia JSON-RPC to the local fork, creates through `/create`, waits for `/?inst=N`, verifies the registry count increments, reads the new instance, and asserts its sale address is nonzero. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::readInstancesCount`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::routeSepoliaRpcToFork`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::readInstance`

## Ops Pages Deployment

The ops portal is a separate Cloudflare Pages deployment: project `fao-ops`, output directory `site-ops`, custom domain `ops.futarchy.ai`. `site-ops/README.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#cloudflare-pages`

The deploy workflow syncs audit dashboard data, then runs `wrangler pages deploy site-ops --project-name=fao-ops --branch=main`. `.github/workflows/deploy-ops.yml@f04b27554031b3c291ef2acb6e9bf11c852c6288::Deploy ops portal to Cloudflare Pages`

The live ops portal and dashboard were reachable during this refresh at `https://ops.futarchy.ai/` and `https://ops.futarchy.ai/fao/`; the dashboard page identifies itself as "FAO audit dashboard" and says it refreshes every 30 seconds. `https://ops.futarchy.ai/`, `https://ops.futarchy.ai/fao/`

## Timelock Boundary

`FAOTimelock` is an executable mainnet-posture sketch around OpenZeppelin `TimelockController`, with `MIN_DELAY_MAINNET = 1 days`, `MIN_DELAY_STAGING = 1 hours`, and a TODO to record a future address in `deployments.json::active.timelock`. `src/FAOTimelock.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::FAOTimelock`

The test suite checks the constructor delay, multisig roles, zero-multisig rejection, insufficient-delay rejection, and delayed execution path. `test/FAOTimelock.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::FAOTimelockTest`

The security spec says the deployed timelock address belongs in a future manifest entry only after Step B chooses the Safe or multisig address, so this page must not imply a live timelock deployment today. `audit/specs/SECURITY.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::Step C`

## Sync And CI

The static-analysis workflow runs schema validation, root/site sync, ABI sync, ops-dashboard sync, Etherscan verification, and Slither as separate jobs. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::deployments-sync`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ops-dashboard-sync`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::etherscan-verified`

The Etherscan job installs `etherscan-api@10.3.0`, passes `ETHERSCAN_API_KEY`, and fails when active contract source is unverified, missing from `verification_todo`, or still listed after verification. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Install etherscan-api`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_API_KEY`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::missingTodos`

`scripts/sync-abis.sh --check` regenerates `site-testnet/abis/*.json` from `forge inspect <Contract> abi --json` and diffs the committed output. `scripts/sync-abis.sh@f04b27554031b3c291ef2acb6e9bf11c852c6288::sync-abis`

The latest ABI resync proves the generated files, not a deployed source-verification result: the orchestrator ABI now includes `createOfficialProposalAndMigrate` and `setAdapter`, and the stack deployer ABI includes `deployStack`. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::createOfficialProposalAndMigrate`, `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::setAdapter`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`

## How This Might Be Wrong

- If `deployments.json::active.timelock` lands, this page must move `FAOTimelock` from future boundary to active deployment inventory. `src/FAOTimelock.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::deployments.json::active.timelock`
- If `ops.futarchy.ai` changes project or domain, the Pages section must rebuild from `site-ops/README.md` and `deploy-ops.yml`. `site-ops/README.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::fao-ops`
- If invariant status changes after `aba4046`, invariant-status references in this deployment page may be fresher in [Ops](../30-cross-cutting/ops.md) or [Invariants](invariants.md). `audit/specs/INVARIANTS.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#pass-status`
- If live Pages verification fails later, local repo citations still prove deploy configuration, not public availability. `https://ops.futarchy.ai/fao/`
- If Etherscan API credentials are unavailable in CI, the verification job fails before proving source status. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_API_KEY`
- If ABI generation changes after `887a22e`, this page must cite the newly generated JSON files rather than only `scripts/sync-abis.sh`. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::constructor`
- If deployment manifests add an adapter-mutability field, the deployment posture section should cite that field instead of only the script and constructor. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If the stack deployer is redeployed from current source, remove the drift warning and cite the replacement manifest address. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::redeploy the active registry/deployer set`
- If ops dashboard sync stops copying source HTML/JS/CSS into `site-ops/fao`, deployment freshness should stop treating dashboard code and dashboard data as one deploy surface. `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::index.html dashboard.js dashboard.css`
- If `proposal_impl_v5` changes again, re-run schema/sync/coupling checks before treating the address as stable deployment evidence. `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`

## See Also

- [Ops](../30-cross-cutting/ops.md)
- [Deployment History](deployment-history.md)
- [Deprecations](../30-cross-cutting/deprecations.md)
- [Supply Chain](../30-cross-cutting/supply-chain.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 5a3953405c6017b990b4b3add843dff77c5f6f86
  - 9e83d3dded5ea385ff6004dc71b2a1fed53f1fa3
  - fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd
  - f04b27554031b3c291ef2acb6e9bf11c852c6288
  - 21f29adc8dd1ac6a0e3f4b5d5ae231022316a309
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - 887a22ec35edc2e739f5ad10fb203a2d9beb14f8
  - aba4046dec32448a09daa308d8fea8cb661671be
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
  - 6173bab17ba15bff91c173f04796ee0c980e3b9e
  - c183c1c461099e69c0c03535c6d08ae87a635853
  - 216b40e5766ac222e2b6e33d92c0a358ad2500c4
  - 9fd41ee02a1834112f1ff580e9e262bdecd1468b
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - 41e4b529c818dbd56fb35b66a4db45b7081fe0a4
  - 1b0c0d7d457cc8468639d288eb14cba0042c801d
  - c8fc913a21c605a9e75069c2852f9da32b72c3e1
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - eba3449c9feab3e7154220f68de80ae5501d6dab
  - f96ced010f19032837e96094c935572a2320230f
  - 8847265a00f7064cdff1fbeffea572d10e889ff9
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:15:22Z.
- Build pass: 18 (continuous HEAD refresh)
