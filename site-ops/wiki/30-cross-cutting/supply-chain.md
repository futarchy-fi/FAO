---
canonical: site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers
scope: Authoritative wiki summary of FAO external dependencies, trust boundaries, compromise effects, and current supply-chain gates.
not-scope: Admin-key and incident-response policy lives in [Security](security.md); deprecated artifact policy lives in [Deprecations](deprecations.md).
last-rebuilt: 2026-05-23T03:13:06Z
---
# Supply Chain

The supply-chain spec turns dependency risk into a layered inventory rather than a grab bag of package names. It matters because FAO's deployed contracts, static site, RPC reads, browser JS, wallet-provider bridge, wallet-session cache, ops dashboard, verification workflows, and Playwright/axe/Lighthouse/screenshot checks fail in different ways when upstreams lie. The canonical mechanism is a concentric trust model plus per-layer update, mitigation, fallback, and verification rules, now backed by executable Etherscan, E2E, a11y JSON, Lighthouse/Web Vitals aggregates, visual snapshot gates, and committed screenshot artifacts. `audit/specs/SUPPLY-CHAIN.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#trust-boundaries-concentric`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::sourceVerificationStatus`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::jobs`, `audit/axe/home.json@HEAD::counts`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::budgets`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::screenshots`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, this page summarized the authored spec but still treated Etherscan verification as only an intended gate and did not include the later ops-dashboard and ABI/deployment sync gates. `audit/wiki/30-cross-cutting/supply-chain.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#verification-boundary`

The static-analysis refresh wires Etherscan verification, deployment schema validation, ABI sync, and ops dashboard sync into CI. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::etherscan-verified`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::deployments-sync`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ops-dashboard-sync`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, the Etherscan gate became executable: the workflow installs `etherscan-api@10.3.0`, passes `ETHERSCAN_API_KEY`, and runs `scripts/check-etherscan-verified.sh`. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Install etherscan-api`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_API_KEY`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Assert active contracts are verified`

Since the previous wiki refresh at source HEAD `b68c06af35a8d5b8f96234dd4028f23c88c5435d`, the new read-only coupling spec added another RPC-consuming path: `SEPOLIA_RPC`, then `FAO_READONLY_RPC_URL`, then `https://ethereum-sepolia.publicnode.com`. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::RPC_URL`

Since source HEAD `c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7`, the fork-state spec added sale and proposal mutation flows while continuing to route the public Sepolia RPC host back to local Anvil for browser reads. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::routePublicRpcToFork`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::sale page reflects cast buy balance without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::proposals page reflects cast-placed YES bond without wallet signing`

Since source HEAD `80a3fa25e322f8af7248b04192a3649854fe9fe0`, wallet-provider selection moved into `shared.js` through EIP-6963 discovery, selected-provider storage, and a provider picker instead of page-local direct provider assumptions. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::EIP6963_ANNOUNCE`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::resolveWalletProvider`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::showWalletProviderPicker`

Since source HEAD `16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea`, the E2E workflow added GitHub Actions dependencies for Playwright browser installation, Foundry toolchain setup, artifact uploads, and a public Sepolia fallback used by fork and wallet jobs. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::Install Playwright browsers`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::foundry-rs/foundry-toolchain@v1`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::https://ethereum-sepolia.publicnode.com`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, ABI resync and F1 wallet-project execution added two supply-chain boundaries: generated ABI JSON must match contract ABIs, and the current F1 path depends on Synpress/MetaMask automation plus browser RPC routing to the fork. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::createOfficialProposalAndMigrate`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, the browser signing surface added decoded review cards before create, proposal, resolve, bond, and graduate wallet confirmations. They reduce blind-signing UX risk but remain delivered by the same static JavaScript supply chain. `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/sepolia.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showConfirmCard`, `site-testnet/bonds.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showBondConfirm`

The fork E2E surface also expanded to NO-bond and try-graduate mutations, so CI supply-chain review now has more browser/RPC reflection evidence beyond the earlier home/sale/YES paths. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, the wallet-project supply-chain surface grew through shared fixtures and current F1 MetaMask automation: F2, F3, and F6 retain shared fork helpers while F1 now uses Synpress connection/confirmation helpers over the same local fork RPC boundary. `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path`, `tests-e2e/journeys/F3-ragequit.wallet.spec.ts@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path`, `tests-e2e/wallet.fixture.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::eth_estimateGas`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::metamask.confirmTransaction`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, frontend QA moved from worker intent to committed dependency and workflow edges: `@axe-core/playwright` entered `package.json`, `a11y`, `lighthouse`, and `capture:screenshots` scripts became runnable entry points, Lighthouse and screenshot workflows were added, and screenshot metadata now has a manifest path under `audit/screenshots`. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::@axe-core/playwright`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::capture:screenshots`, `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Run Lighthouse`, `.github/workflows/screenshots.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Capture screenshots`, `audit/screenshots/manifest.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::screenshots`

The same source window expanded the browser signing boundary: sale JS now emits Etherscan transaction links for buy/sell/ragequit status, sale HTML exposes decision-time numerics, and `shared.js` stores a wallet session with idle clearing plus optional EIP-5792 `wallet_sendCalls` support. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::explorerTx`, `site-testnet/sale.html@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-strip`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_SESSION_STORAGE_KEY`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::wallet_sendCalls`

The frontend QA supply chain still includes worker specs for higher-level judging, but the concrete edges to track now are the committed helpers, workflows, and audit output directories. `audit/agents/evaluator-1-multimodal.md@6b8c7252c17c84895a3b28ae771d018bdbb8d31e::vision-model verdict`, `tests-e2e/journeys/a11y.read-only.spec.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::critical`, `scripts/capture-screenshots.sh@6283126ee2e83ddc47966eaea01e40f8f52143ee::audit/screenshots`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, the FE-QA supply-chain boundary now has committed output, not only commands: `audit/axe/*.json` records zero violations for the scanned pages, `audit/screenshots/manifest.json` records the local capture URL plus PNG hashes and byte counts, and `tests-e2e/__snapshots__/` stores the corresponding baseline images. `audit/axe/contracts.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`, `audit/axe/sale.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::minor`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::siteUrl`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::bytes`

Since source HEAD `aa5ca7235dc8c3834e5db2edd7bfd3214875b5ed`, the screenshot supply-chain evidence now identifies its renderer as `playwright-chromium`, which makes the artifact producer explicit. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::renderer`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, the supply-chain boundary expanded in four places: E2E CI uploads axe artifacts and runs local-site visual snapshots, the dashboard keeps Chart.js CDN tags in source HTML instead of relying only on dynamic loading, `sync-ops-dashboard.sh` copies dashboard assets and summary data into the Pages tree, and Lighthouse Web Vitals output records exact mobile budgets and current page checks. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::axe-audit-read-only`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::cdn.jsdelivr.net`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::dashboard assets`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::budgetsPass`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, the browser supply chain added static fallback content to reduce blank first paint, deferred shared data loading behind `afterInitialPaint`, and committed a passing local Web Vitals aggregate. `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::trade-buy-uni-btn`, `site-testnet/shared.js@239313c31b169d4cc5073e6178aa372ee1e88c98::afterInitialPaint`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`

The committed site-RPC refresh centralizes the ethers CDN edge and fork RPC bridge: `shared.js::loadEthers()` appends the versioned jsdelivr script when needed, `window.faoRpcUrl` publishes either public Sepolia or local Anvil, and page scripts select their provider URL through `rpcUrl()`. Dirty F1 still uses Synpress/MetaMask while routing JSON-RPC requests to `FAO_RPC_URL`. `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::ETHERS_SRC`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoRpcUrl`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::rpcUrl`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`

At source HEAD `5a3953405c6017b990b4b3add843dff77c5f6f86`, sale buy/ragequit review cards add a gas-estimate row before wallet signing; the row is still browser-delivered advisory data, and `estimateSaleGas()` falls back to the wallet's own estimate when the page cannot pre-compute it. `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::provider.estimateGas`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::Wallet will estimate before signing`

## Layered Trust Map

| Layer | Source quote | Failure interpretation |
|---|---|---|
| Sepolia consensus | "Trusted absolutely. If broken, nothing else matters." `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#trust-boundaries-concentric` | The repo does not hedge base-chain consensus failure. |
| Solidity dependencies | "malicious bytecode in deployed contracts." `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#trust-boundaries-concentric` | Submodule compromise is deploy-time critical. |
| RPC and Etherscan | "lies about chain state." `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#trust-boundaries-concentric` | Read-path compromise can mis-render UI or verification state without automatically signing user transactions. |
| CDN and host | "client-side wallet drain" and "UI replacement." `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#trust-boundaries-concentric` | Browser-delivered JS is a signing-surface risk, not just availability risk. |
| Ops dashboard copy | `site-ops/fao/evaluations/topic-{1..6}-evals.jsonl` is copied from canonical audit outputs. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#data-flow` | Stale dashboard data is an operations-observability risk, not a contract-risk event. `scripts/check-ops-sync.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::ops dashboard JSONL sync OK` |

## Dependency Rules

Solidity dependencies are supposed to be pinned by full SHA in `.gitmodules`, and any submodule update requires the full unit plus invariant suite, redeployment of contracts linked to changed code, and a deployment-history row. `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#layer-1-solidity-dependencies`

The npm surface is explicitly E2E-only in the authored spec: `@playwright/test`, `@synthetixio/synpress`, and `viem` do not affect deployed bytecode. `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Layer 1.1`

The RPC surface has a public Sepolia endpoint for the site, a local Anvil endpoint for fork E2E, and a read-only coupling fallback to `ethereum-sepolia.publicnode.com`. `audit/specs/SUPPLY-CHAIN.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#layer-2-rpc-endpoints`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::routePublicRpcToFork`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::https://ethereum-sepolia.publicnode.com`

The CI RPC surface now also appears in `.github/workflows/e2e.yml`: fork and wallet jobs use `secrets.SEPOLIA_RPC` if present and otherwise fall back to the publicnode URL, the fork job pins block `10899720`, and browser scripts can select the local Anvil RPC through `faoForkMode`. `.github/workflows/e2e.yml@HEAD::SEPOLIA_RPC`, `.github/workflows/e2e.yml@HEAD::ANVIL_FORK_BLOCK_NUMBER`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::faoForkMode`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::FORK_RPC`

F1 adds another browser-test RPC layer: the test routes JSON-RPC POSTs back to `FAO_RPC_URL`, sets `faoForkMode` before loading the page, and then uses the Synpress MetaMask fixture for connection and transaction confirmation. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::localStorage.setItem('faoForkMode'`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::metamask.confirmTransaction`

The shared wallet fixture extends that same boundary to F2/F3/F6 by centralizing wallet cache setup, active instance reads, `confirmOneTransaction`, sale/factory ABIs, and gas-estimate buffering. `tests-e2e/wallet.fixture.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::ensureWalletCache`, `tests-e2e/wallet.fixture.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::activeInstance`, `tests-e2e/wallet.fixture.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::confirmOneTransaction`, `tests-e2e/wallet.fixture.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::eth_estimateGas`

Wallet session persistence is now another browser-local trust boundary: `shared.js` stores the connected account/provider metadata, resets it on disconnect or storage events, clears it after the idle timer, and exposes a batched-call helper only when the selected wallet reports EIP-5792 support. `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::rememberWalletSession`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::clearWalletSessionStorage`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::handleWalletStorageEvent`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::sendWalletCalls`

## Browser Delivery And Verification Gates

The site still loads `ethers@6.13.2` from jsdelivr, but the committed loader centralizes that CDN edge in `shared.js::loadEthers()`; the loader pins the versioned URL but still does not provide SRI. `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#layer-3-cdn`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::ETHERS_SRC`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`

`scripts/check-etherscan-verified.sh` is now a CI job, so the verification boundary is no longer only a TODO in the spec. The script fails on missing API credentials, missing `etherscan-api`, empty `SourceCode`, empty `ContractName`, unverified active contracts missing from `verification_todo`, stale todos for verified contracts, and any todo that still references active addresses. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_API_KEY`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::sourceVerificationStatus`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::missingTodos`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::activeTodos`

Generated ABI sync and deployment schema validation reduce two browser supply-chain risks: stale ABI JSON and malformed address manifests. `scripts/sync-abis.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::sync-abis`, `scripts/validate-deployments.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::Validate deployments`

The newest ABI resync means supply-chain review should treat `site-testnet/abis/FAOOfficialProposalOrchestrator.json` and `site-testnet/abis/FutarchyStackDeployer.json` as current generated artifacts, not hand-written browser code. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::constructor`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::constructor`

The current manifest lists active v5 registry, deployers, UniV3 liquidity adapter, and future per-instance contracts in `verification_todo`, which means CI treats them as known unverified work rather than silent supply-chain drift. `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

The browser signing surface now includes a provider-choice modal and topbar identity chip; those controls are a supply-chain boundary because compromised browser JS can still present or switch wallet-provider context before asking a wallet to sign. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::wallet-provider-picker`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::topbar-wallet-identity`

The signing surface now also includes review cards that render the intended action, addresses or ids, amounts, approval notes, and gas estimates before invoking the wallet path. A compromised static site can still lie in those cards, so they are a user-review mitigation, not a cryptographic supply-chain boundary. `site-testnet/create.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-create`, `site-testnet/proposals.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-proposal`, `site-testnet/proposals.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-resolve`, `site-testnet/proposals.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-bond`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::Gas estimate (≈)`

The sale status surface now persists Etherscan transaction links after the review card closes, which improves user observability but also makes the static-site JS responsible for constructing the explorer URL honestly. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::explorerTx`, `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::closeConfirmCard({ preserveStatus: true })`

Tooling supply chain now covers a11y and visual artifacts: `runAxeOn` writes page-specific JSON under `audit/axe`, the a11y read-only spec rejects critical/serious violations, Lighthouse CI writes reports under `audit/lighthouse`, and screenshot capture records hashes and byte counts in `audit/screenshots/manifest.json`. `tests-e2e/axe-helper.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::audit/axe`, `tests-e2e/journeys/a11y.read-only.spec.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::Serious a11y violations`, `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::audit/lighthouse`, `.github/workflows/screenshots.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::sha`

Current axe outputs are clear for home, sale, proposals, create, contracts, and docs; that is a supply-chain fact about the worktree artifact set, not a guarantee about future hosted HTML. `audit/axe/home.json@HEAD::"critical": 0`, `audit/axe/proposals.json@HEAD::"serious": 0`, `audit/axe/docs.json@HEAD::violations`

The current Web Vitals aggregate is also a supply-chain artifact: it is produced from Lighthouse reports and an INP interaction check, and the committed `239313c` copy identifies itself as a local post-change run with a true `pass` field. `audit/lighthouse/budgets.md@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::scripts/check-inp.mjs`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::source`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::fao-testnet-pages-dev`

## How This Might Be Wrong

- If a committed lockfile lands, the npm pinning section should stop treating package resolution as a remaining gap. `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#how-this-might-be-wrong`
- If SRI hashes are added to all CDN scripts, browser-delivery risk should move from mitigation gap to enforced property. `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#layer-3-cdn`
- If `_headers` adds CSP, the Cloudflare Pages section should cite that file instead of only the spec's next step. `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#layer-4-site-host`
- If ops dashboard JSONL becomes live-fetched from the audit source instead of copied into `site-ops/`, the supply-chain boundary should move from static copy to API trust. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#data-flow`
- If the coupling spec stops using the publicnode fallback or adds multiple RPC providers, the RPC surface summary should be rebuilt from that spec. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::RPC_URL`
- If fork-state browser routing stops intercepting the public Sepolia host, this page should stop treating the browser and viem reads as same-fork evidence. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::PUBLIC_SEPOLIA_RPC_HOST`
- If Etherscan API rate limits or response schema changes, the verification gate may fail for infrastructure reasons instead of source-truth reasons. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::fetchSourceCode`
- If the E2E workflow pins browser, action, or Foundry versions differently, this page should refresh the CI supply-chain surface. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::actions/setup-node@v4`
- If wallet-provider UI starts using a third-party picker package, the browser signing boundary should include that dependency. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::showWalletProviderPicker`
- If F1 stops using the current Synpress/MetaMask helper or its route-all-JSON-RPC hook, the wallet-project supply-chain boundary should be rebuilt from the new provider mechanism. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`
- If review cards are moved behind wallet popups, sourced from a package, or stop showing sale gas estimates before signing, their supply-chain role should be rebuilt. `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`
- If FE-QA artifacts are regenerated, this page should cite the new `audit/axe` JSON, Web Vitals aggregate, and screenshot manifest rather than carrying forward the current outputs. `audit/axe/home.json@HEAD::timestamp`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::generatedAt`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`
- If wallet-session storage changes key names, idle duration, or capability probing, rebuild the browser signing boundary from `shared.js`. `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_IDLE_MS`
- If explorer URLs stop targeting Sepolia Etherscan or become configurable, rebuild the transaction-status boundary from `sale.js`. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::https://sepolia.etherscan.io/tx`
- If dashboard CDN tags, visual snapshot masking, or Web Vitals budgets change, rebuild this page from those current files before claiming supply-chain gates are stable. `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::DO NOT REMOVE THESE CDN TAGS`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::DYNAMIC_REGION_SELECTOR`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::budgets`
- If the lazy ethers loader/fork-mode bridge changes again, rebuild this page from `shared.js`, the page scripts, and any dirty HTML that controls page-local CDN tags. `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/contracts.html@HEAD::shared.js`

## See Also

- [Security](security.md)
- [Threat Model](threat-model.md)
- [Cross-Cutting Deployment](deployment.md)
- [Deployment](../10-fao-repo/deployment.md)
- [Ops Dashboard](../50-operations/ops-dashboard.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 5a3953405c6017b990b4b3add843dff77c5f6f86
  - 37603636e5194b202ad5438ce80bf9909aad42c8
  - fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd
  - e0cd25b942ca2d98c37aa53e21205b562f4fab68
  - 0eba1d137b452019c4af2d2ecc143d7d0237287d
  - 1b1c3e0eec7f1e4a343eb0af0c9f949a6dec6e58
  - c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7
  - afac9a588d9945eebcce056ece8bd2ca640797f1
  - b68c06af35a8d5b8f96234dd4028f23c88c5435d
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - 030d258e6d7909b3e724f1a7cc5cd7f4f711178c
  - 89a6f9f710320ae59adb1ac358a8bf8e687f4bf6
  - 16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea
  - 46903c84a2c8835cd13fb5e2ecfa858df20bea50
  - 887a22ec35edc2e739f5ad10fb203a2d9beb14f8
  - aba4046dec32448a09daa308d8fea8cb661671be
  - 5c672c5540af07df5b6ab368e8ff606fc23649b6
  - 6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00
  - c17ef8b51560710c4fca17d9fb667e5e0f816e7f
  - 43074d02be5fb427aed16560aeec0f1f8914d5e5
  - d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b
  - 216b40e5766ac222e2b6e33d92c0a358ad2500c4
  - 6b8c7252c17c84895a3b28ae771d018bdbb8d31e
  - 6766184f046ed7205c8d7d3d3a538229667737c6
  - 6283126ee2e83ddc47966eaea01e40f8f52143ee
  - b913bd0b7fb28c1e233d034833b8e9eafc62d16c
  - 3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d
  - 5e7c0f139380b0b2296d7055b28188feae56ca4e
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - c8f7371de72ca6f054d221ff5a80386ab555bfac
  - cd5e73e73b21c0ac73bf80e8cac4c9dc31edfab0
  - 1b0c0d7d457cc8468639d288eb14cba0042c801d
  - 4b4c04664009807658ca64722d3aea1fbfb401d0
  - c8fc913a21c605a9e75069c2852f9da32b72c3e1
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - 5e532972f18bafdcd8f6d2c48bf314db0da24a6c
  - 239313c31b169d4cc5073e6178aa372ee1e88c98
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:03:52Z.
- Build pass: 17 (continuous HEAD refresh)
