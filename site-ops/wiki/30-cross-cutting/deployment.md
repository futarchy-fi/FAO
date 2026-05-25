---
canonical: deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5
scope: Authoritative cross-cutting summary of deployment coupling, live ops dashboard delivery, dashboard data fetches, and manifest/bytecode checks.
not-scope: Testnet-site registry runtime details live in [FAO Deployment](../10-fao-repo/deployment.md); admin-key hardening lives in [Security](security.md).
last-rebuilt: 2026-05-23T02:52:44Z
---
# Deployment

Cross-cutting deployment now covers five coupling layers: manifest-to-site reads, fork bytecode checks, browser-published instance addresses, deploy-script security modes, and Etherscan source-verification status. It matters because a deployment can have correct registry wiring but still present stale UI addresses, select the wrong adapter mutability mode, carry source-vs-deploy bytecode drift, or remain unverified for wallet/source review. The canonical mechanism is `deployments.json` for the registry and verification queue, `site-ops/fao/evaluations/*.jsonl` for dashboard evidence, `ADAPTER_REPLACEABLE` for Sepolia-versus-mainnet deployment posture, and executable checks for browser coupling, registry manifest wiring, bytecode drift, plus Etherscan source status. `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::active`, `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`, `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::testFork_activeRegistryWiringMatchesManifest`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Current HEAD drift: stack deployer`

## Changed Since Last Refresh

The previous refresh at source HEAD `b68c06af35a8d5b8f96234dd4028f23c88c5435d` covered Cloudflare Pages delivery and fork-side bytecode checks but had no browser-level contract/UI coupling spec. `site-ops/fao/dashboard.js@b68c06af35a8d5b8f96234dd4028f23c88c5435d::loadTopic`, `test/Coupling.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Coupling`

HEAD adds `tests-e2e/coupling.read-only.spec.ts`, which reads `deployments.json`, opens `/sale?inst=N`, and asserts `window.activeInstance` plus sale address-table DOM values match the registry instance. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::DEPLOYMENTS_PATH`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::page.goto`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::window.activeInstance`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, `fb9a1a5` added the Etherscan verification gate and synchronized the root and site deployment manifests with the same active `verification_todo` queue. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verificationTodo`, `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`, `site-testnet/deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, deployment posture gained an explicit adapter mutability flag: `DeployFutarchyRegistry.s.sol` reads `ADAPTER_REPLACEABLE`, `FutarchyStackDeployer` stores it, and the orchestrator receives it in the constructor. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FutarchyRegistryDeployers.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::constructor(bool adapterReplaceable)`, `src/FutarchyRegistryDeployers.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, coupling evidence split into a known-red bytecode drift note and a new green wiring assertion: `COUPLING-NOTES.md` records that `active.futarchy_stack_deployer` still points at pre-`ADAPTER_REPLACEABLE` Sepolia bytecode, while `testFork_activeRegistryWiringMatchesManifest` asserts the active registry's dependency addresses match the manifest. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::pre-ADAPTER_REPLACEABLE deployer`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::local normalized hash`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::on-chain normalized hash`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::testFork_activeRegistryWiringMatchesManifest`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, no deployment manifest, bytecode-coupling, or Pages deploy source changed; the newer HEAD delta is UI/FE-QA-only through sale tx links, a11y/Lighthouse/screenshot workflows, wallet-session state, the minimalism audit, committed axe JSON, and committed screenshot artifacts. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Lighthouse CI`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_SESSION_STORAGE_KEY`, `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::screenshots`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, cross-cutting deployment changed in the ops-dashboard layer rather than contract manifests: `sync-ops-dashboard.sh` now copies HTML/JS/CSS assets and emits `summary.json`, `auto-sync-ops.sh` includes dashboard assets in its redeploy hash, and the dashboard HTML keeps Chart.js CDN tags as deferred scripts. `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Dashboard assets`, `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::summary.json`, `scripts/auto-sync-ops.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::HASH`, `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::defer`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, deployment coupling became less brittle about live address rendering without lowering the address check: `expectAddressLink` extracts the href address, accepts compact or full visible text, and checks `title` when present. `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::hrefAddress`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::title address`

Committed source `f96ced010f19032837e96094c935572a2320230f` pulls `proposal_impl_v5` into the active coupling surface: the manifest sets the proposal implementation address, the TODO queue names it for Etherscan verification, the fork coupling test checks registry `PROPOSAL_IMPL()` against the manifest, and the bytecode script checks it when non-null. `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `deployments.json@f96ced010f19032837e96094c935572a2320230f::active.proposal_impl_v5 FAOFutarchyProposal v5`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::registry PROPOSAL_IMPL != manifest`, `scripts/check-coupling-bytecode.js@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`

## Live Ops Dashboard

The live dashboard page at `https://fao-ops.pages.dev/fao/` identifies itself as "FAO audit dashboard" and says it reads `audit/evaluations/topic-{1..6}-evals.jsonl`-derived JSONL files with no build step. `https://fao-ops.pages.dev/fao/`

`scripts/auto-sync-ops.sh` watches the concatenated audit evaluation JSONL hash, runs `scripts/sync-ops-dashboard.sh`, and redeploys `site-ops` to Cloudflare Pages when the hash changes. `scripts/auto-sync-ops.sh@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::auto-sync-ops`, `scripts/sync-ops-dashboard.sh@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::synced audit/evaluations`

The deploy workflow deploys `site-ops` to the `fao-ops` Pages project on main-branch changes or manual dispatch. `.github/workflows/deploy-ops.yml@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::pages deploy site-ops`

## Dashboard Semantics

The overview card styles by mean score while still displaying min as secondary context, so convergence claims should cite mean and min separately. `site-ops/fao/dashboard.js@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::renderOverview`

The main trend chart still uses the historical function name `renderMinChart`, but its dataset label and data plot topic mean over time. `site-ops/fao/dashboard.js@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::renderMinChart`

The dashboard fetch path uses `new URL("evaluations/topic-N-evals.jsonl", document.baseURI)`, which keeps JSONL fetches relative to the deployed `/fao/` document. `site-ops/fao/dashboard.js@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::loadTopic`

The current dashboard deploy surface has a small first-paint contract too: `summary.json` is generated from canonical full-evaluator rows and is copied with dashboard assets, while partial worker and multimodal rows are filtered out of the chart data. `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::is_canonical`, `site-ops/fao/summary.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::totalDimensions`, `audit/dashboard/dashboard.js@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::NON_CANONICAL_EVALUATORS`

## Manifest, Bytecode, And Browser Coupling

`audit/state/COUPLING-NOTES.md` says active deployment entries from `deployments.json` are checked against Sepolia fork bytecode for `registry`, `proposal_impl_v5`, `token_arb_deployer`, `futarchy_stack_deployer`, and `uniswap_v3_liquidity_adapter`. `audit/state/COUPLING-NOTES.md@HEAD::#active-bytecode-comparison`

The coupling notes now intentionally exempt only `operator` because it is an EOA; `proposal_impl_v5` is checked when present. `audit/state/COUPLING-NOTES.md@HEAD::One active field is intentionally not contract bytecode`, `scripts/check-coupling-bytecode.js@HEAD::optionalNull`

`test/Coupling.t.sol` is the fork-side assertion entry point, and `scripts/check-coupling-bytecode.js` performs normalized bytecode comparison when FFI is enabled. `test/Coupling.t.sol@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::Coupling`, `scripts/check-coupling-bytecode.js@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::normalize`

The new browser coupling spec validates the UI-facing path: `chain_id` must be Sepolia, `active.registry` must be present, `FAO_COUPLING_INST` must exist, and `window.activeInstance` must publish the same token, sale, and arbitration addresses that the registry returns. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::deployments.chain_id`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::FAO_COUPLING_INST`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::expected`

The deploy-script security mode is not represented in `deployments.json` today: Sepolia defaults to `ADAPTER_REPLACEABLE=1`, while mainnet must use `ADAPTER_REPLACEABLE=0` to restore the one-shot adapter guard. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::vm.envOr("ADAPTER_REPLACEABLE"`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Mainnet deployments must set ADAPTER_REPLACEABLE=0`

`testFork_activeRegistryWiringMatchesManifest` reads `deployments.json` and checks registry `PROPOSAL_IMPL`, `TOKEN_ARB_DEPLOYER`, `STACK_DEPLOYER`, `WETH`, `CTF`, `W1155`, and `UNIV3_FACTORY` against the manifest's active/shared values. `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::TOKEN_ARB_DEPLOYER`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::STACK_DEPLOYER`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::UNIV3_FACTORY`

## Source Verification Gate

The Etherscan gate walks every active manifest address, skips the operator EOA, calls `contract.getsourcecode`, and fails unless verified contracts have non-empty `SourceCode` plus `ContractName`. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::collectActiveAddresses`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::isKnownEoaPath`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::sourceVerificationStatus`

The current remediation queue is explicit in `deployments.json`: active registry, token/arbitration deployer, futarchy stack deployer, UniV3 liquidity adapter, and future v5 per-instance contracts remain in `verification_todo`. `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

## How This Might Be Wrong

- Live URL availability is a refresh-time observation; it does not prove future Cloudflare uptime. `https://fao-ops.pages.dev/fao/`
- The read-only coupling spec defaults to instance `0`; coverage must vary `FAO_COUPLING_INST` to prove later instances. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::FAO_COUPLING_INST`
- The browser coupling spec does not assert resolver, factory, orchestrator, or spot-pool fields. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::registryAbi`
- If active manifest keys change, the coupling notes, fork test, and browser test must rebuild together. `audit/state/COUPLING-NOTES.md@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::registry`
- If Etherscan marks an active address verified but `verification_todo` is not pruned, CI still fails by design. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::staleTodos`
- If deployment manifests start recording adapter mutability, this page should cite the manifest field rather than only the deploy script. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If the stack deployer is redeployed from current source, this page must replace the known-red drift note with the new manifest address and coupling result. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Do not skip or bless this mismatch`
- If the ops dashboard changes from copied static JSONL plus `summary.json` to live API fetches, this page should stop treating dashboard deployment as static file sync. `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::site-ops/fao`
- If `proposal_impl_v5` changes again, all deployment and source-verification pages must rebuild from the final manifest and coupling test together. `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`

## See Also

- [Security](security.md)
- [Ops](ops.md)
- [Supply Chain](supply-chain.md)
- [E2E Journey Map](../40-verification/e2e-journey-map.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd
  - c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7
  - afac9a588d9945eebcce056ece8bd2ca640797f1
  - b68c06af35a8d5b8f96234dd4028f23c88c5435d
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
  - 6173bab17ba15bff91c173f04796ee0c980e3b9e
  - c183c1c461099e69c0c03535c6d08ae87a635853
  - 6766184f046ed7205c8d7d3d3a538229667737c6
  - 6283126ee2e83ddc47966eaea01e40f8f52143ee
  - 3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d
  - 9fd41ee02a1834112f1ff580e9e262bdecd1468b
  - 5e7c0f139380b0b2296d7055b28188feae56ca4e
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - 41e4b529c818dbd56fb35b66a4db45b7081fe0a4
  - fe9abbe3331b70b1600f4a4d28ee39a6bd539fed
  - 1b0c0d7d457cc8468639d288eb14cba0042c801d
  - c8fc913a21c605a9e75069c2852f9da32b72c3e1
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - eba3449c9feab3e7154220f68de80ae5501d6dab
  - f96ced010f19032837e96094c935572a2320230f
  - 8847265a00f7064cdff1fbeffea572d10e889ff9
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:15:22Z.
- Build pass: 18 (continuous HEAD refresh)
