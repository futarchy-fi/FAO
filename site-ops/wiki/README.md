---
canonical: audit/wiki/_OUTLINE.md@8847265a00f7064cdff1fbeffea572d10e889ff9::#futarchy-wiki-outline-pre-build
scope: Authoritative entry point and navigation graph for the source-cited FAO wiki.
not-scope: Contract-by-contract API detail belongs in [FAO Repo](10-fao-repo/README.md); current deployment manifest flow lives in [Deployment](10-fao-repo/deployment.md).
last-rebuilt: 2026-05-23T03:13:06Z
---
# Futarchy Wiki

This wiki is the source-cited map of the Futarchy.fi FAO repository and the adjacent agents vision abstention. It matters because the current repo now has authored specs for invariants, decidability, mutation resistance, supply-chain posture, operator runbooks, E2E journeys, dashboard operations, executable security posture checks, decoded transaction review, FE-QA artifacts, and read-only UI/contract coupling. The canonical mechanism is still the registry-created futarchy lifecycle, but the wiki's review path now separates protocol behavior, proof obligations, operator state, browser delivery, deploy-mode security, visual/a11y evidence, and deployed-address coupling instead of flattening them into one lifecycle narrative. `audit/wiki/_OUTLINE.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#top-level-structure`, `audit/specs/DECIDABILITY.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#decidability-of-fao-invariants`, `audit/state/RUNBOOK.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#fao-operator-runbook`, `audit/axe/home.json@HEAD::violations`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::screenshots`

## Changed Since R4 Wiki

The prior refreshed wiki at `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6` already covered deployment manifests, deprecations, supply chain, E2E journeys, InstanceSale symbolic checks, and UI hierarchy. `audit/wiki/README.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#page-index`

The first post-outline refresh added wiki navigation for the artifacts that were not in that page graph: `DECIDABILITY.md`, `MUTATIONS.md`, `RUNBOOK.md`, `DEVELOPER.md`, the ops portal scaffold, generated ABI/deployment schema gates, the fork-state E2E journey, wallet-backed F1, and the new forge invariant CI gate. `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#invariant--engine-assignment`, `audit/specs/MUTATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#mutation-classes`, `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#data-flow`, `.github/workflows/forge.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::invariant`

Since the previous wiki refresh at source HEAD `c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7`, HEAD expanded fork-state E2E from home-count mutation to home, sale buy, and proposal YES-bond mutations. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::home page reflects instancesCount after cast-created instance`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::sale page reflects cast buy balance without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::proposals page reflects cast-placed YES bond without wallet signing`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, HEAD added an executable Etherscan verification gate and made `deployments.json::verification_todo` part of the deployment/security review path. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::T5.D2 / Step E`, `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

Since source HEAD `fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd`, HEAD added `audit/agents/worker-ui-polish.md`, a T1 Web3 UX worker plan that belongs under [UI Architecture](30-themes/ui-architecture.md) until concrete `site-testnet/` changes land. `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::#worker--t1-web3-ux-gap-closing`, `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::Goal condition`

Since source HEAD `80a3fa25e322f8af7248b04192a3649854fe9fe0`, the EIP-6963 wallet-provider picker and provider identity chip landed in `site-testnet/shared.js`, and the selector registry gained wallet-provider selectors for future E2E coverage. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::resolveWalletProvider`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::topbar-wallet-identity`, `tests-e2e/SELECTORS.md@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::wallet-provider-picker`

Since source HEAD `16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea`, `.github/workflows/e2e.yml` makes read-only and fork Playwright projects CI jobs while keeping the Synpress wallet project opt-in through manual dispatch. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::read-only`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::fork`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::workflow_dispatch`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, HEAD added four more refresh triggers: ORCH-002 symbolic-harness alignment, generated ABI resync, tokenized UI type scale, and a green F1 wallet-project run on Anvil. `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::check_INV_ORCH_002_refusesPreInit`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`, `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::T1.D6`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, the wiki refresh adds five concrete deltas: executable security posture checks, fork-state NO-bond and try-graduate E2E mutations, decoded transaction review cards, and a tighter semantic CSS-token pass. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAORenewableAdmin`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--overlay`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, the wiki refresh adds six more concrete deltas: known stack-deployer bytecode drift, registry wiring coupling, F2/F3/F6 wallet happy paths, one-primary sale trade action, numeric/address/a11y UI affordances, and v2 FE-QA rubrics/workers. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Current HEAD drift: stack deployer`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::testFork_activeRegistryWiringMatchesManifest`, `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path`, `tests-e2e/journeys/F3-ragequit.wallet.spec.ts@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path`, `site-testnet/styles.css@358b1a14f9927b2eafd7790d094a8432be60a0d9::skip-nav`, `audit/rubrics/v2/topic-1-web3-ux-v2.md@6b8c7252c17c84895a3b28ae771d018bdbb8d31e::tool-emitted evidence`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, the wiki refresh adds five newer deltas: sale transaction statuses keep Etherscan links, FE-QA workflows/scripts landed for axe/Lighthouse/screenshots, sale decision numerics became selector-addressable, wallet sessions gained idle clearing plus EIP-5792 capability detection, and the testnet UI now has a minimalism audit for type/shadow/gradient/color inventory. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::a11y`, `site-testnet/sale.html@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-strip`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_SESSION_STORAGE_KEY`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#shadow-inventory`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, the wiki refresh adds three artifact deltas: F1 compatibility now lets the combined F1/F2/F3/F6 wallet grep pass, axe outputs for public pages are committed with empty violation arrays, and screenshot/snapshot artifacts are committed with hashes and byte counts. `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::4 passed in 2.5m`, `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::bytes`

Since source HEAD `aa5ca7235dc8c3834e5db2edd7bfd3214875b5ed`, the screenshot artifacts were refreshed with Chromium-rendered PNGs and an explicit manifest renderer field. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::playwright-chromium`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::home-desktop.png`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, the wiki refresh adds the newer FE-QA and dashboard boundary: read-only E2E uploads axe artifacts, visual snapshots became a CI job, wallet-provider reconnect and review-card read-only specs landed, Lighthouse writes a Web Vitals budget aggregate, the ops dashboard filters partial/worker JSONL rows and keeps CDN scripts as deferred source tags, the worker axe heartbeat is explicit, and the latest screenshot manifest records local Playwright Chromium captures at `2026-05-22T19:29:50.555Z`. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Upload axe audit`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::restores stored EIP-6963 provider identity without prompting`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::transaction review card has decoded args and controls`, `audit/lighthouse/web-vitals.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::pass`, `audit/dashboard/dashboard.js@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::isCanonicalRow`, `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::DO NOT REMOVE THESE CDN TAGS`, `audit/loops/worker-axe.log@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::heartbeat`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`

Since source HEAD `b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b`, the wiki refresh adds the current Lighthouse/data freshness boundary: worker screenshots heartbeat records no new capture need, read-only visual baselines and axe JSON refreshed, Lighthouse now checks deployed Pages freshness before and after report writing, INP is measured by a Playwright interaction script, `lighthouse-summary.mjs` writes median-run Web Vitals reports, and Topic 1/3 evaluator rows landed as dashboard input. `audit/loops/worker-screenshots.log@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::heartbeat`, `audit/axe/home.json@HEAD::timestamp`, `.github/workflows/lighthouse.yml@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::Wait for deployed Pages assets`, `scripts/check-pages-freshness.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::assets`, `scripts/check-inp.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::PerformanceObserver`, `scripts/lighthouse-summary.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::metricSpecs`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pages`, `audit/evaluations/topic-3-evals.jsonl@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::timestamp`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, the wiki refresh adds two final frontier deltas: testnet first paint is stabilized by HTML fallback rows and sale fallback values while `shared.js` refreshes topbar state in place, and the live coupling spec now accepts either full or compact visible address text as long as href/title still point at the expected registry address. `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::sale-hero-symbol`, `site-testnet/shared.js@239313c31b169d4cc5073e6178aa372ee1e88c98::refreshTopbarState`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`

Since source HEAD `eba3449c9feab3e7154220f68de80ae5501d6dab`, the committed frontier adds an active `proposal_impl_v5` coupling target, a restored futarchy.ai domain architecture note, a `polsia.futarchy.ai` Render mapping, fork-driven Playwright state journeys that use the shared site RPC bridge, and sale buy/ragequit pre-confirm gas-estimate rows. The remaining dirty worktree overlays still change F1 Synpress/MetaMask routing and local fork CI startup/block/log handling. `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::resetAnvilFork`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoRpcUrl`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::Gas estimate (≈)`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `.github/workflows/e2e.yml@HEAD::ANVIL_FORK_BLOCK_NUMBER`

## Reading Order

Start with [What Is Futarchy](00-what-is-futarchy/README.md), then [FAO Repo](10-fao-repo/README.md) and the lifecycle pages for contract behavior. Use [Deployment](10-fao-repo/deployment.md), [Deprecations](30-cross-cutting/deprecations.md), and [Supply Chain](30-cross-cutting/supply-chain.md) before treating any address, ABI, script, package, CDN, or hosted site as active. `deployments.schema.json@3fad3cad278325c13a191c472f1be9ba5d15db02::required`, `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-9`, `audit/specs/SUPPLY-CHAIN.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#trust-boundaries-concentric`

For verification, read [Invariants](10-fao-repo/invariants.md) first, then [Decidability](40-verification/decidability.md), [Symbolic Obligations](40-verification/halmos-instance-sale.md), [Mutation Resistance](40-verification/mutation-resistance.md), and [E2E Journey Map](40-verification/e2e-journey-map.md). `audit/specs/INVARIANTS.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#pass-status`, `audit/specs/DECIDABILITY.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#decision-engine-matrix`, `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#journeys`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::E2E (Playwright)`

For operations, read [Runbook](50-operations/runbook.md), [Developer Cycle](50-operations/developer-cycle.md), [Ops Dashboard](50-operations/ops-dashboard.md), and [Domain Architecture](50-operations/domain-architecture.md). `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#daemons--crons`, `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cycle-times-measured-2026-05-22`, `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cloudflare-pages`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Active mappings`

## Page Index

| Area | Pages |
|------|-------|
| Meta | [Futarchy Wiki — Outline (pre-build)](_OUTLINE.md), [How This Wiki Is Maintained](_meta/how-this-wiki-is-maintained.md), [Source Of Truth Map](_meta/source-of-truth-map.md), [Open Questions](_meta/open-questions.md) |
| Concept | [What Is Futarchy](00-what-is-futarchy/README.md), [Prior Art](00-what-is-futarchy/prior-art.md), [Why Onchain](00-what-is-futarchy/why-onchain.md) |
| FAO repo | [FAO Repo](10-fao-repo/README.md), [Architecture](10-fao-repo/architecture.md), [Deployment](10-fao-repo/deployment.md), [Deployment History](10-fao-repo/deployment-history.md), [Invariants](10-fao-repo/invariants.md), [Glossary](10-fao-repo/glossary.md) |
| Lifecycle | [Create Instance](10-fao-repo/lifecycle/00-create-instance.md), [Sale](10-fao-repo/lifecycle/10-sale.md), [Spot Liquidity](10-fao-repo/lifecycle/20-spot-liquidity.md), [Proposal](10-fao-repo/lifecycle/30-proposal.md), [Promote](10-fao-repo/lifecycle/40-promote.md), [Resolve](10-fao-repo/lifecycle/50-resolve.md), [Arbitration](10-fao-repo/lifecycle/60-arbitration.md) |
| Cross-cutting | [Security](30-cross-cutting/security.md), [Threat Model](30-cross-cutting/threat-model.md), [Deployment](30-cross-cutting/deployment.md), [Ops](30-cross-cutting/ops.md), [Deprecations](30-cross-cutting/deprecations.md), [Supply Chain](30-cross-cutting/supply-chain.md) |
| Verification | [E2E Journey Map](40-verification/e2e-journey-map.md), [Symbolic Obligations](40-verification/halmos-instance-sale.md), [Decidability](40-verification/decidability.md), [Mutation Resistance](40-verification/mutation-resistance.md) |
| UI | [UI Architecture](30-themes/ui-architecture.md) |
| Operations | [Runbook](50-operations/runbook.md), [Developer Cycle](50-operations/developer-cycle.md), [Ops Dashboard](50-operations/ops-dashboard.md), [Domain Architecture](50-operations/domain-architecture.md) |
| Deferred | [Agents Vision](20-agents-vision/README.md) |

## Stable Anchors

Lifecycle pages are anchored to source code and authored specs rather than live chain state. `src/FutarchyRegistry.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createFutarchyPart1`, `src/FutarchyRegistry.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createFutarchyPart2`, `audit/specs/INVARIANTS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#fao--top-15-invariants`

Dynamic deployment data is linked through `deployments.json`, `deployments.schema.json`, generated ABI JSON, `shared.js::loadDeployments()`, the read-only coupling spec, and the Etherscan verification gate. Stale historical addresses stay in [Deployment History](10-fao-repo/deployment-history.md) or [Deprecations](30-cross-cutting/deprecations.md). `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::active`, `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`, `site-testnet/shared.js@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::loadDeployments`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::sourceVerificationStatus`

Wallet interaction is now linked through shared provider selection rather than page-local `window.ethereum` assumptions: `shared.js` owns EIP-6963 discovery, selected-provider persistence, topbar wallet identity, and `fao:walletChanged`. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::EIP6963_ANNOUNCE`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::WALLET_PROVIDER_STORAGE_KEY`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::fao:walletChanged`

The F1 wallet-project evidence remains fork-scoped rather than live-Sepolia signing proof: the current worktree uses Synpress/MetaMask helpers and routes browser JSON-RPC to the local fork before asserting registry state. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::registry.instancesCount() should increment after F1 create`

Transaction review is now part of wallet interaction: create, proposal, resolve, and bond/graduate flows render local review cards before wallet confirmation, with selectors listed in the E2E registry. `site-testnet/create.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-create`, `site-testnet/proposals.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-bond`, `tests-e2e/SELECTORS.md@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-bond`

Wallet-path evidence now covers create, sale buy, ragequit, and proposal create happy paths; the wallet project is still opt-in, not a normal PR gate. `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`, `audit/loops/worker-synpress.log@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path now passes`, `audit/loops/worker-synpress.log@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path now passes`, `audit/loops/worker-synpress.log@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path now passes`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::include-wallet`

Frontend evidence now has concrete artifacts and gates: axe scans write `audit/axe/<label>.json` and are uploaded by the read-only E2E job, Lighthouse stores reports and aggregates Web Vitals budget status, screenshot capture records hashes, visual snapshots compare masked baselines, and `minimalism-audit.md` constrains CSS visual vocabulary. `audit/axe/sale.json@HEAD::counts`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Upload axe audit`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::budgets`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::sha256`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::maxDiffPixelRatio`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#gradient-inventory`

## How This Might Be Wrong

- If the separate agents repo becomes locally available, [Agents Vision](20-agents-vision/README.md) should stop being an abstention page. `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#open-questions-for-user-resolve-before-phase-3`
- If `DECIDABILITY.md` is updated after the `INV-ARB-003` stateful invariant graduation, the verification pages should remove the current drift warning. `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::INV-ARB-003`
- If live deployment values change without manifest updates, this README must keep pointing to [Deployment](10-fao-repo/deployment.md) and [Cross-Cutting Deployment](30-cross-cutting/deployment.md) rather than caching the new address here. `site-testnet/shared.js@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::loadDeployments`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::REGISTRY`
- If `site-ops/` is moved into a separate repo or the futarchy.ai DNS map changes outside the repo, [Ops Dashboard](50-operations/ops-dashboard.md) and [Domain Architecture](50-operations/domain-architecture.md) should be rebuilt together. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cloudflare-pages`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::DNS records`
- If Synpress becomes a normal PR gate, [E2E Journey Map](40-verification/e2e-journey-map.md) should stop describing wallet coverage as manual-only. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::include-wallet`
- If F1 leaves the current Synpress/MetaMask path or stops routing JSON-RPC to the fork, the E2E and ops pages should rebuild their wallet-boundary language. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`
- If `ADAPTER_REPLACEABLE` becomes manifest state rather than deploy-script input, navigation should point deployment readers at the manifest field. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If the known stack-deployer drift is resolved, navigation should stop treating coupling as a current warning and point to the new manifest/deployment evidence. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::redeploy the active registry/deployer set`
- If FE-QA workflows start producing different committed artifact paths, navigation should point UI and verification readers at the new artifact owners. `tests-e2e/axe-helper.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::OUT_DIR`
- If wallet session or EIP-5792 support changes, wallet UX references should rebuild from `shared.js`. `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::detectWalletCapabilities`
- If the FE-QA artifact paths or dashboard CDN-loading contract change again, root navigation must rebuild from the workflow, dashboard, and manifest sources together. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::defer`, `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::loadSummary`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::baseUrl`

## See Also

- [Source Of Truth Map](_meta/source-of-truth-map.md)
- [Open Questions](_meta/open-questions.md)
- [Deployment](10-fao-repo/deployment.md)
- [Cross-Cutting Deployment](30-cross-cutting/deployment.md)
- [Decidability](40-verification/decidability.md)
- [Ops Dashboard](50-operations/ops-dashboard.md)
- [Domain Architecture](50-operations/domain-architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 5a3953405c6017b990b4b3add843dff77c5f6f86
  - 37603636e5194b202ad5438ce80bf9909aad42c8
  - 80a3fa25e322f8af7248b04192a3649854fe9fe0
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
  - 2a41f6e6d266e9695a4273779a06825ff7dfd1c2
  - 887a22ec35edc2e739f5ad10fb203a2d9beb14f8
  - 953817cf3c19e2ab87e08af1aee8919541455dd8
  - aba4046dec32448a09daa308d8fea8cb661671be
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
  - 6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00
  - c17ef8b51560710c4fca17d9fb667e5e0f816e7f
  - 5c672c5540af07df5b6ab368e8ff606fc23649b6
  - 671ad3b54c68d83ba1c96974c2cf133877f1321e
  - 6173bab17ba15bff91c173f04796ee0c980e3b9e
  - 43074d02be5fb427aed16560aeec0f1f8914d5e5
  - c183c1c461099e69c0c03535c6d08ae87a635853
  - d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b
  - 8744da8b1441501b5767d5c9d1abb11d05a8d843
  - b596f7fe09ab8b07901aca035223a85be0ffe611
  - 6b8c7252c17c84895a3b28ae771d018bdbb8d31e
  - 358b1a14f9927b2eafd7790d094a8432be60a0d9
  - 216b40e5766ac222e2b6e33d92c0a358ad2500c4
  - 6766184f046ed7205c8d7d3d3a538229667737c6
  - 6283126ee2e83ddc47966eaea01e40f8f52143ee
  - b913bd0b7fb28c1e233d034833b8e9eafc62d16c
  - 3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d
  - 9fd41ee02a1834112f1ff580e9e262bdecd1468b
  - 89486c060069f6ee2e61ff75cfb47d5a3314ad56
  - 5e7c0f139380b0b2296d7055b28188feae56ca4e
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - c8f7371de72ca6f054d221ff5a80386ab555bfac
  - a59c725cf0f3c464820b8e6f9607c6a8ae4ea858
  - 19138b05f4c3c9d2b59470b3b9e91fa222f42403
  - 41e4b529c818dbd56fb35b66a4db45b7081fe0a4
  - cd5e73e73b21c0ac73bf80e8cac4c9dc31edfab0
  - fe9abbe3331b70b1600f4a4d28ee39a6bd539fed
  - 806c9c5aa7b5b74e1c25c8872a339e8c56457a5c
  - ed51e829b6cc888379043d9af02cc20e4e00eafb
  - 1b0c0d7d457cc8468639d288eb14cba0042c801d
  - 4b4c04664009807658ca64722d3aea1fbfb401d0
  - a2dc1a002e1a4cf164b2abab803835a7dd619b7d
  - c8fc913a21c605a9e75069c2852f9da32b72c3e1
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - fd6cb47b2fa8b4cb6c9a1825f61935798b402243
  - c990d1d0e3cc034e6a570e62747756553c4498c5
  - e5c20a5c7e688bf4791b5b79948c81afa94e80f6
  - 0ee626377a781ffe7587049d8fda474fcb5f984d
  - e48b24cbb63f6f0f3e5e4ab39b449aa54ce23883
  - 5e532972f18bafdcd8f6d2c48bf314db0da24a6c
  - 239313c31b169d4cc5073e6178aa372ee1e88c98
  - eba3449c9feab3e7154220f68de80ae5501d6dab
  - f96ced010f19032837e96094c935572a2320230f
  - 8847265a00f7064cdff1fbeffea572d10e889ff9
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:15:22Z.
- Build pass: 18 (continuous HEAD refresh)
