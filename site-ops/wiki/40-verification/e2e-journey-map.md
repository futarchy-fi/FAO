---
canonical: tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress
scope: Authoritative wiki coverage of executable E2E journeys, fork-state local/CI cycle, wallet F1/F2/F3/F6 paths, a11y scans, and read-only UI/contract coupling.
not-scope: Selector contracts live in `tests-e2e/SELECTORS.md`; deployment coupling inventory lives in [Deployment](../30-cross-cutting/deployment.md).
last-rebuilt: 2026-05-23T03:04:18Z
---
# E2E Journey Map

The E2E surface now has seven distinct signals: Synpress/MetaMask wallet-project journeys, fork-backed state mutation, read-only UI/contract address coupling, committed a11y scan artifacts, visual snapshot baselines, wallet-provider reconnect proof, and decoded review-card proof. It matters because Topic-6 convergence should distinguish browser rendering, chain-state realism, deployed-manifest alignment, a11y regressions, visual drift, reconnect state, pre-confirm UI, and which proof actually blocks PRs. The canonical mechanism is `tests-e2e/JOURNEY-MAP.md` for journey intent, `playwright.config.ts` for project routing, wallet specs for F1/F2/F3/F6 happy paths, `fork-state.read-only.spec.ts` for home/sale/YES/NO/QUEUED no-wallet fork mutations, read-only specs for a11y/reconnect/review-cards/visual snapshots, and workflows for CI execution. `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#journeys`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::restores stored EIP-6963 provider identity without prompting`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::transaction review card has decoded args and controls`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual baseline`, `audit/axe/home.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::violations`

## Changed Since Last Refresh

The prior refresh was pinned to `c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7`; since then, `1b1c3e0` added the sale cast-buy UI assertion, `0eba1d1` added the proposal YES-bond UI assertion, and `e0cd25b` expanded the journey map to name all covered fork mutations. `tests-e2e/journeys/fork-state.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::home page reflects instancesCount after cast-created instance`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::sale page reflects cast buy balance without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::proposals page reflects cast-placed YES bond without wallet signing`, `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::Covered fork mutations`

`JOURNEY-MAP.md` now says the fork-state read-only spec starts or uses Anvil on `8545`, reads chain state through viem, mutates the fork with `cast send`, and reloads `/`, `/sale.html`, and `/proposals.html` to prove browser state follows the fork without a wallet. `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::tests-e2e/journeys/fork-state.read-only.spec.ts`

Since source HEAD `16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea`, `.github/workflows/e2e.yml` runs the read-only project on `https://fao-testnet.pages.dev`, runs the fork project with Foundry tools and a Sepolia RPC fallback, and gates the Synpress wallet project behind `workflow_dispatch` plus `include-wallet`. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::Run read-only project`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::Run fork project`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::include-wallet`

Since source HEAD `80a3fa25e322f8af7248b04192a3649854fe9fe0`, the selector registry added topbar wallet identity, chain-switch, provider-picker, and provider-option selectors, so future wallet E2E assertions can target the shared provider UI directly. `tests-e2e/SELECTORS.md@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::topbar-wallet-identity`, `tests-e2e/SELECTORS.md@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::wallet-provider-picker`, `tests-e2e/SELECTORS.md@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::wallet-provider-option-<rdns-or-id>`

At source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, F1 first became a green Synpress wallet project by injecting an Anvil EIP-1193 provider, routing public Sepolia RPC traffic to local Anvil, submitting create through the site, and verifying `instancesCount()` plus the new sale address; the current worktree overlay later replaces that injected-provider step with Synpress/MetaMask connection helpers. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::routeSepoliaRpcToFork`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::injectAnvilWallet`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::registry.instancesCount() should increment after F1 create`

The worker log records the execution result: `npm run e2e -- --project=wallet --grep F1` passed one wallet test, skipped four unrelated F10 fixmes, then targeted `FAOSmokeTest` passed through the Foundry binary on PATH. `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::Targeted Forge verification passed`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, the fork project added two proposal-state mutations beyond the earlier YES-bond check: a cast `placeNoBond(uint256)` path that must render a `NO` chip, and a cast `tryGraduate(uint256)` path that must render `QUEUED` plus the queued copy. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`

Those two tests share `createProposalWithYesBond`, which builds a ready instance, creates a factory proposal, bootstraps arbitration with `createProposalWithId`, and places the initial YES bond before the mutation under test. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::createProposalWithYesBond`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::createProposalWithId(uint256,uint256)`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::placeYesBond(uint256,uint256)`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, wallet E2E graduated three more happy paths: F2 buys one token through the sale page and asserts `totalAmountRaised` plus buyer ERC20 balance deltas, F3 buys two tokens then ragequits one and asserts balance/supply/sale-ETH deltas, and F6 creates a proposal then asserts `factory.marketsCount()` plus `proposals(index)`. `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path`, `tests-e2e/journeys/F3-ragequit.wallet.spec.ts@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path`

The shared Anvil wallet fixture now exposes sale and factory ABIs, a `confirmOneTransaction` shim, and a 140% plus 100,000 gas buffer for `eth_estimateGas` to avoid exact-estimate out-of-gas failures in wallet paths. `tests-e2e/wallet.fixture.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::saleAbi`, `tests-e2e/wallet.fixture.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::factoryAbi`, `tests-e2e/wallet.fixture.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::confirmOneTransaction`, `tests-e2e/wallet.fixture.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::eth_estimateGas`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, the E2E-adjacent UI contract added three selector surfaces and one new read-only spec: sale transaction status now has persistent Etherscan links, sale decision numerics are registered in `SELECTORS.md`, the topbar can expose a wallet-capabilities chip, and `a11y.read-only.spec.ts` scans public pages through `runAxeOn`. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `tests-e2e/SELECTORS.md@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-strip`, `tests-e2e/SELECTORS.md@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::topbar-wallet-capabilities`, `tests-e2e/journeys/a11y.read-only.spec.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::runAxeOn`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, F1 stopped assuming a create confirmation card is always present on the deployed page, the combined wallet-targeted regression passed F1/F2/F3/F6, axe artifacts were committed with zero violations, and visual screenshots/snapshots were committed. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@89486c060069f6ee2e61ff75cfb47d5a3314ad56::hasConfirmCard`, `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::4 passed in 2.5m`, `audit/axe/create.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::screenshots`

Since source HEAD `aa5ca7235dc8c3834e5db2edd7bfd3214875b5ed`, screenshot evidence was refreshed with `playwright-chromium`, so the visual artifact provenance now cites the renderer rather than only file hashes. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::playwright-chromium`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, the E2E frontier added current read-only checks and CI plumbing: the read-only job uploads `audit/axe/`, the visual-snapshot job serves `site-testnet` locally and sets `FAO_ENABLE_VISUAL_SNAPSHOTS=1`, the reconnect spec proves stored EIP-6963 identity plus `5792` capability display, the review-card spec proves four decoded-card fixtures, and the latest manifest refresh records 12 local Chromium captures. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Upload axe audit`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Run visual snapshot suite`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::5792`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::CASES`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::screenshots`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, the live-site coupling spec grew `expectAddressLink`: it now checks the Etherscan href for the expected address, accepts either full `0x...` text or compact `0x1234…abcd` text, and still checks the `title` address when present. `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::hrefAddress`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::visible compact address`

The latest committed fork refresh changes no-wallet routing while dirty wallet/CI overlays remain separate: F1 still unlocks/uses MetaMask through Synpress and can route JSON-RPC POSTs to `FAO_RPC_URL`, while `3760363` narrows the fork project to `fork-state.read-only.spec.ts`, sets fork mode in local storage before page load, resolves or resets the Anvil fork block, and can stop a spec-started Anvil process. `.github/workflows/e2e.yml@HEAD::FAO_SITE_URL: http://127.0.0.1:8766`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::unlockMetaMaskIfNeeded`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::localStorage.setItem('faoForkMode'`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::resetAnvilFork`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::stopSpawnedAnvil`

## Synpress F1

F1 reads `instancesCount()`, opens `/create`, connects through Synpress/MetaMask, fills the create form through `data-testid` or stable-ID fallbacks, confirms the wallet transaction, waits for `/?inst=N`, checks the registry count increment, reads the new instance, and asserts the sale address is nonzero. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::readInstancesCount`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::metamask.confirmTransaction`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::readInstance`

The path still builds the MetaMask cache, but the current provider boundary is real Synpress wallet automation with fork-routed RPC: `connectWithSynpress` waits for `window.connectWallet`, asks MetaMask to connect if the dapp has not connected yet, and polls for a 20-byte connected wallet. `tests-e2e/wallet.setup.ts@aba4046dec32448a09daa308d8fea8cb661671be::ensureWalletCache`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::window.connectWallet`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::metamask.connectToDapp`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::site should connect to MetaMask through Synpress`

F1 now treats the create review card as optional so the same wallet-project test can run against the deployed create page that may submit directly; it waits for durable progress or redirect rather than a transient step string. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@89486c060069f6ee2e61ff75cfb47d5a3314ad56::confirm-card-create`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@89486c060069f6ee2e61ff75cfb47d5a3314ad56::create flow should progress to mining or redirect`

## Wallet F2/F3/F6

F2 creates or selects a local instance, opens `/sale`, connects the shared wallet fixture, confirms the sale transaction through `sale-confirm-go`, and polls on-chain `totalAmountRaised` plus token `balanceOf`. `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path`, `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::totalAmountRaised`, `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::buyer token balance should increase by the bought token amount`

F3 reuses the same sale path, buys two tokens, calls `quoteRagequit`, confirms ragequit, and polls for token balance, total supply, and sale treasury ETH decreases. `tests-e2e/journeys/F3-ragequit.wallet.spec.ts@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path`, `tests-e2e/journeys/F3-ragequit.wallet.spec.ts@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::quoteRagequit`, `tests-e2e/journeys/F3-ragequit.wallet.spec.ts@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::token totalSupply should decrease by one token after ragequit`

F6 opens `/proposals`, fills the create-proposal form, optionally confirms the review card, then asserts `marketsCount()` increments and `proposals(beforeCount)` is nonzero. `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::confirm-card-proposal`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::marketsCount`

## Fork-State Read-Only

The fork-state read-only journey routes Sepolia JSON-RPC to the local fork, sends `createFutarchyPart1` with `cast`, waits for `instancesCount()` to increment, reloads `/`, and expects the new table row and symbol. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::routePublicRpcToFork`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::castSendCreatePart1`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::home page reflects instancesCount after cast-created instance`

The sale mutation sends `InstanceSale.buy(uint256)` with `cast`, waits for `initialTokensSold()` and the buyer token balance to increment, reloads `/sale.html?inst=N`, and checks `#sale-initial-sold` plus `#sale-balance`. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::sale page reflects cast buy balance without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::readSaleSnapshot`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#sale-balance`

The proposal mutation sends `createFutarchyPart2`, factory `createProposal`, WETH `deposit` and `approve`, `createProposalWithId`, and `placeYesBond`; after reload, the proposal card must show the YES chip, `YES bond`, `0.001 WETH`, and the Anvil address prefix. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::createReadyInstance`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::createFactoryProposal`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::placeYesBond`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::0.001 WETH`

The later proposal mutations extend that same card contract: `placeNoBond(uint256)` must move the card to `NO` and show `NO bond`, while `tryGraduate(uint256)` must move the card to `QUEUED` and show `Queued for evaluation`. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::placeNoBond(uint256)`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposal card should show the cast-updated NO chip after reload`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::tryGraduate(uint256)`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposal card should show the cast-updated QUEUED chip after reload`

The current local cycle is: serve `site-testnet` on port `8766`, run the Playwright `fork` project against only `tests-e2e/journeys/fork-state.read-only.spec.ts`, pin or inherit `ANVIL_FORK_BLOCK_NUMBER`, and let the spec reset or stop the Anvil process it starts. `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#fork-state-local-dev-cycle`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::resetAnvilFork`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::stopSpawnedAnvil`, `scripts/anvil-fork.sh@37603636e5194b202ad5438ce80bf9909aad42c8::Usage: scripts/anvil-fork.sh [--stop]`

## CI Routing

The E2E workflow triggers on site, tests-e2e, Playwright config, package, Anvil script, and workflow changes; pull requests run it regardless of path filters. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::paths`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::pull_request`

The `read-only` job checks out submodules, installs Node 20 dependencies, installs Chromium, and runs `npm run e2e:read-only -- --reporter=github,html` against `https://fao-testnet.pages.dev`. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::read-only`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::FAO_SITE_URL: https://fao-testnet.pages.dev`

The `fork` job installs Foundry for `anvil` and `cast`, starts the local static site, runs the Playwright `fork` project against `http://127.0.0.1:8766`, and pins the fork block to `10899720`; its upstream Sepolia RPC still comes from the repository secret or the publicnode fallback. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::Install Foundry (anvil, cast)`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`, `.github/workflows/e2e.yml@HEAD::ANVIL_FORK_BLOCK_NUMBER`, `.github/workflows/e2e.yml@HEAD::SEPOLIA_RPC`

The `wallet` job is not a normal PR gate: it runs only on manual dispatch when `include-wallet` is true, starts Anvil in the background, and runs the Playwright `wallet` project with `FAO_RPC_URL=http://127.0.0.1:8545`. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::wallet`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::FAO_RPC_URL`

## A11y And Visual QA

`a11y.read-only.spec.ts` visits the public site pages, calls `runAxeOn(page, label)`, writes the axe result artifact, and fails on any critical or serious violation. `tests-e2e/journeys/a11y.read-only.spec.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::const PAGES`, `tests-e2e/journeys/a11y.read-only.spec.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::Critical a11y violations`, `tests-e2e/axe-helper.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::fs.writeFileSync`

The committed axe outputs currently show empty `violations` arrays and zero counts across the public pages. `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::"critical": 0`, `audit/axe/sale.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::"serious": 0`, `audit/axe/contracts.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`

The visual regression stack now has committed screenshot artifacts: the manifest records 12 page/viewport captures with hashes and byte counts, and matching snapshot PNGs exist under `tests-e2e/__snapshots__`. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::docs-desktop.png`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::create-mobile.png`, `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Upload Lighthouse reports`

The visual snapshot gate is separate from the screenshot-capture artifact: it is skipped unless `FAO_ENABLE_VISUAL_SNAPSHOTS=1`, waits for page-specific ready selectors, tags dynamic DOM regions, and allows at most `0.005` pixel-diff ratio. `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::FAO_ENABLE_VISUAL_SNAPSHOTS`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::readyTestId`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::tagDynamicRegions`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::maxDiffPixelRatio`

Two read-only UI-state probes now complement wallet-project happy paths: the wallet-provider test restores a selected EIP-6963 provider from storage and checks the topbar identity/status/capabilities, while the confirm-card test injects decoded rows and checks cancel plus confirm controls for create, proposal, resolve, and bond. `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::localStorage.setItem`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::topbar-status`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::showReviewCard`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::confirm-card-${c.action}-confirm`

## Read-Only Coupling

The new coupling spec is read-only and gated to the Playwright `read-only` project. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::test.skip(testInfo.project.name !== 'read-only')`

The spec reads `deployments.json`, requires `chain_id == 11155111`, requires `active.registry` to be a 20-byte address, checks that `FAO_COUPLING_INST` exists under `instancesCount()`, and reads that registry instance through viem. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::DEPLOYMENTS_PATH`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::instancesCount`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::readInstance`

After opening `/sale?inst=N`, the browser assertion compares `window.activeInstance.id`, `token`, `sale`, and `arbitration` against the on-chain instance, then checks the sale page token and sale address table cells. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::page.goto`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::window.activeInstance`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::#sale-addr-table-token`

## How This Might Be Wrong

- `JOURNEY-MAP.md` still lags F1's executable status; this page cites the committed F1 spec and worker log as fresher evidence for F1 only. `tests-e2e/JOURNEY-MAP.md@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::Wallet-driven specs`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@aba4046dec32448a09daa308d8fea8cb661671be::testWithSynpress`
- The fork-state tests mutate contracts directly with `cast`, so they prove read-only UI reflection and chain realism, not wallet transaction UX. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::No wallet UI is involved`
- The coupling spec checks token, sale, and arbitration addresses, not resolver, orchestrator, factory, or spot-pool fields. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::expected`
- `FAO_COUPLING_INST` defaults to `0`, so coverage can miss a broken later instance unless CI varies that value. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::FAO_COUPLING_INST`
- Wallet CI is explicitly manual-dispatch gated, so read-only/fork PR success is not proof that the F1 wallet project ran in CI. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::workflow_dispatch`
- F1's current worktree path uses Synpress/MetaMask, but that source is not committed yet; once committed, replace the `@HEAD` citations with the resulting SHA before treating it as pinned provenance. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`
- The NO-bond and try-graduate checks reuse a helper that starts from an existing YES bond, so they prove UI reflection for those transitions rather than every arbitration state path. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::createProposalWithYesBond`
- F2/F3/F6 are wallet-project happy paths with fixme placeholders still present for rejection, wrong-chain, and RPC-failure variants. `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::wallet rejection`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::wrong chain`
- The axe artifacts prove zero axe violations in the committed scan output, not keyboard usability or screen-reader task completion. `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`
- Screenshot artifacts prove rendered pixels were captured, not that a human or multimodal evaluator accepted them. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::bytes`
- Visual snapshot success is masked around dynamic regions, so it cannot prove live chain data, balances, or proposal rows are visually unchanged. `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::DYNAMIC_REGION_SELECTOR`
- Reconnect and review-card read-only specs prove DOM contracts under fixtures, not that every wallet signs safely in production. `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Unsupported mock wallet method`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::data-review-fixture`

## See Also

- [Deployment](../30-cross-cutting/deployment.md)
- [FAO Deployment](../10-fao-repo/deployment.md)
- [Developer Cycle](../50-operations/developer-cycle.md)
- [Decidability](decidability.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 37603636e5194b202ad5438ce80bf9909aad42c8
  - e0cd25b942ca2d98c37aa53e21205b562f4fab68
  - 0eba1d137b452019c4af2d2ecc143d7d0237287d
  - 1b1c3e0eec7f1e4a343eb0af0c9f949a6dec6e58
  - c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7
  - afac9a588d9945eebcce056ece8bd2ca640797f1
  - b68c06af35a8d5b8f96234dd4028f23c88c5435d
  - 16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea
  - 46903c84a2c8835cd13fb5e2ecfa858df20bea50
  - aba4046dec32448a09daa308d8fea8cb661671be
  - 6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00
  - c17ef8b51560710c4fca17d9fb667e5e0f816e7f
  - 43074d02be5fb427aed16560aeec0f1f8914d5e5
  - d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b
  - 216b40e5766ac222e2b6e33d92c0a358ad2500c4
  - 6766184f046ed7205c8d7d3d3a538229667737c6
  - 6283126ee2e83ddc47966eaea01e40f8f52143ee
  - b913bd0b7fb28c1e233d034833b8e9eafc62d16c
  - 3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d
  - 89486c060069f6ee2e61ff75cfb47d5a3314ad56
  - 5e7c0f139380b0b2296d7055b28188feae56ca4e
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - c8f7371de72ca6f054d221ff5a80386ab555bfac
  - 19138b05f4c3c9d2b59470b3b9e91fa222f42403
  - cd5e73e73b21c0ac73bf80e8cac4c9dc31edfab0
  - 806c9c5aa7b5b74e1c25c8872a339e8c56457a5c
  - ed51e829b6cc888379043d9af02cc20e4e00eafb
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - eba3449c9feab3e7154220f68de80ae5501d6dab
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:03:52Z.
- Build pass: 17 (continuous HEAD refresh)
