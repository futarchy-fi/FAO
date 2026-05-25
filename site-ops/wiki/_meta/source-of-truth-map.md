---
canonical: audit/wiki/_OUTLINE.md@8847265a00f7064cdff1fbeffea572d10e889ff9::#top-level-structure
scope: Authoritative map from wiki pages to the repo files that should trigger their rebuild.
not-scope: Rebuild procedure and changelog rules live in [How This Wiki Is Maintained](how-this-wiki-is-maintained.md).
last-rebuilt: 2026-05-23T03:13:06Z
---
# Source Of Truth Map

This map tells future wiki builders which local file should trigger each page refresh. It matters because HEAD now has canonical authored specs, operational docs, generated deployment checks, E2E journeys, browser coupling tests, and static ops-site artifacts that are not all contract files. The canonical mechanism is page-to-primary-source mapping plus supporting-source triggers for pages whose behavior crosses contract, site, CI, and audit-data boundaries. `audit/wiki/_OUTLINE.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#pre-construction-invariants-from-topic-6-rubric-draft`, `audit/rubrics/topic-6-llm-wiki.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::Dimension 6`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, this map had rows for deprecations, supply chain, E2E journeys, InstanceSale symbolic checks, UI architecture, and deployment manifests, but no rows for decidability, mutation resistance, runbook, developer cycle, ops dashboard, generated ABI bindings, or the forge invariant workflow. `audit/wiki/_meta/source-of-truth-map.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#cross-cutting-and-verification-pages`

Later refreshes kept those rows and added rebuild triggers for executable security posture, fork-state NO/QUEUED journeys, review cards, semantic CSS tokens, FE-QA workflows/artifacts, wallet-session hardening, sale tx-status links, sale decision numerics, and the minimalism audit. `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#invariant--engine-assignment`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--overlay`, `audit/axe/home.json@HEAD::violations`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::screenshots`

Since the previous wiki refresh at source HEAD `c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7`, `tests-e2e/journeys/fork-state.read-only.spec.ts` became the trigger for home, sale, and proposal read-only fork mutation coverage. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::home page reflects instancesCount after cast-created instance`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::sale page reflects cast buy balance without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::proposals page reflects cast-placed YES bond without wallet signing`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, `scripts/check-etherscan-verified.sh`, `.github/workflows/static-analysis.yml`, and `deployments.json::verification_todo` became rebuild triggers for deployment, security, supply-chain, runbook, developer-cycle, and ops-dashboard pages. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::T5.D2 / Step E`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::etherscan-verified`, `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

Since source HEAD `fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd`, `audit/agents/worker-ui-polish.md` became a rebuild trigger for [UI Architecture](../30-themes/ui-architecture.md) because it defines the T1 Web3 UX gap plan without changing `site-testnet/` yet. `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::Target gaps`

Since source HEAD `80a3fa25e322f8af7248b04192a3649854fe9fe0`, wallet-provider ownership moved from a worker plan to `site-testnet/shared.js`, `site-testnet/styles.css`, and `tests-e2e/SELECTORS.md`. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::resolveWalletProvider`, `site-testnet/styles.css@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::.wallet-provider-option`, `tests-e2e/SELECTORS.md@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::wallet-provider-picker`

Since source HEAD `16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea`, `.github/workflows/e2e.yml` became a rebuild trigger for [E2E Journey Map](../40-verification/e2e-journey-map.md) and [Developer Cycle](../50-operations/developer-cycle.md). `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::read-only`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::fork`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::wallet`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, symbolic harnesses, ABI JSON, UI type scale, and wallet-project evidence became rebuild triggers: `test/FAOOfficialProposalOrchestrator.symbolic.t.sol`, `site-testnet/abis/*.json`, `site-testnet/styles.css`, `site-testnet/home.js`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts`, `tests-e2e/wallet.setup.ts`, and `audit/loops/worker-synpress.log`. `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::check_INV_ORCH_002_refusesPreInit`, `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::createOfficialProposalAndMigrate`, `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::T1.D6`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, security posture checks, fork-state NO/QUEUED mutations, transaction review cards, and semantic CSS token cleanup became rebuild triggers for security, deployment, ops, supply-chain, UI, E2E, mutation-resistance, and developer-cycle pages. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAORenewableAdmin`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--overlay`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, coupling drift/wiring, wallet F2/F3/F6 happy paths, one-primary/numeric/a11y UI work, and v2 FE-QA rubrics/workers became rebuild triggers for deployment, ops, supply-chain, UI, E2E, developer-cycle, and wiki navigation pages. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Current HEAD drift: stack deployer`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::testFork_activeRegistryWiringMatchesManifest`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path`, `site-testnet/styles.css@358b1a14f9927b2eafd7790d094a8432be60a0d9::skip-nav`, `audit/rubrics/v2/topic-1-web3-ux-v2.md@6b8c7252c17c84895a3b28ae771d018bdbb8d31e::tool-emitted evidence`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, page rebuild triggers changed again: sale tx-status links affect UI and supply-chain pages, the committed FE-QA stack affects supply-chain/E2E/developer-cycle/ops/UI pages, sale decision numerics affect UI/E2E pages, wallet-session state affects UI/supply-chain pages, and `minimalism-audit.md` affects UI navigation and source maps. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::lighthouse`, `tests-e2e/SELECTORS.md@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-strip`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_IDLE_MS`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#literal-color-inventory`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, artifact files became first-class rebuild triggers: `audit/loops/worker-synpress.log` for the combined wallet regression, `audit/axe/*.json` for a11y outputs, and `audit/screenshots/manifest.json` plus `tests-e2e/__snapshots__` for visual evidence. `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::4 passed in 2.5m`, `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::counts`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::generatedAt`

Since source HEAD `aa5ca7235dc8c3834e5db2edd7bfd3214875b5ed`, screenshot manifests should be treated as renderer-specific because the current manifest records `playwright-chromium`. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::renderer`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, page rebuild triggers expanded again: read-only E2E owns axe artifact upload, the visual snapshot job owns screenshot-baseline regression, `wallet-provider.read-only.spec.ts` owns reconnect behavior, `confirm-cards.read-only.spec.ts` plus `audit/review-cards/T1.D3.json` own decoded review-card evidence, `web-vitals.json` owns Lighthouse budget status, dashboard source owns canonical-row filtering and deferred CDN tags, the ops sync script owns asset plus summary sync, and the current screenshot manifest owns the latest PNG hashes. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Upload axe audit`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::topbar-wallet-capabilities`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::showReviewCard`, `audit/review-cards/T1.D3.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::decodedRows`, `audit/lighthouse/web-vitals.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::budgets`, `audit/dashboard/dashboard.js@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::MIN_CANONICAL_DIMS`, `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::script defer`, `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::summary.json`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::sha256`

Since source HEAD `b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b`, Lighthouse/reporting sources became first-class rebuild triggers: `check-pages-freshness.mjs` validates deployed Pages assets against checkout files, `check-inp.mjs` records interaction timing, `lighthouse-summary.mjs` merges median Lighthouse runs with INP results, `web-vitals.json` tracks current page budgets, and new evaluator rows update dashboard inputs without changing protocol docs. `scripts/check-pages-freshness.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::assets`, `scripts/check-inp.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::budgetMs`, `scripts/lighthouse-summary.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::readInpResults`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `audit/evaluations/topic-1-evals.jsonl@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::lighthouse`, `audit/evaluations/topic-3-evals.jsonl@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::topic`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, testnet first-paint HTML, `shared.js` topbar refresh, the committed Web Vitals aggregate, and the address-link-tolerant coupling helper became rebuild triggers for UI architecture, E2E journey, deployment coupling, developer cycle, and root navigation. `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::trade-buy-sale-price`, `site-testnet/shared.js@239313c31b169d4cc5073e6178aa372ee1e88c98::refreshTopbarState`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`

Since source HEAD `eba3449c9feab3e7154220f68de80ae5501d6dab`, committed sources added `proposal_impl_v5` as an active coupling target, restored the futarchy.ai domain architecture note, added `polsia.futarchy.ai` as a Render-backed DNS row, committed fork-driven Playwright state journeys plus the shared site RPC bridge, and added sale buy/ragequit pre-confirm gas-estimate rows. The remaining dirty worktree overlay adds rebuild triggers that should be treated as fresher than committed HEAD: F1's provider path is Synpress/MetaMask with JSON-RPC routing to the fork, and the fork CI job starts a local site, pins block `10899720`, and uploads its site log. `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::resetAnvilFork`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`

## Meta And Concept Pages

| Page | Canonical source | Rebuild when |
|------|------------------|--------------|
| [Futarchy Wiki](../README.md) | `audit/wiki/_OUTLINE.md@8847265a00f7064cdff1fbeffea572d10e889ff9::#top-level-structure` | Navigation changes, new canonical specs land, page graph changes, wallet journeys graduate, FE-QA artifacts land, dashboard loading changes, domain mappings change, or coupling warnings change. `audit/rubrics/topic-6-llm-wiki.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Dimension 2` |
| [How This Wiki Is Maintained](how-this-wiki-is-maintained.md) | `audit/rubrics/topic-6-llm-wiki.md@3fad3cad278325c13a191c472f1be9ba5d15db02::How to use this rubric` | Topic-6 scoring or changelog discipline changes. `audit/rubrics/topic-6-llm-wiki.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Signals` |
| [Source Of Truth Map](source-of-truth-map.md) | `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#top-level-structure` | Any page gains, loses, or changes canonical source. `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#pre-construction-invariants-from-topic-6-rubric-draft` |
| [Open Questions](open-questions.md) | `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Dimension 5` | Any abstention closes, a new freshness oracle lands, or dirty `@HEAD` citations are committed. `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Out-of-Scope Abstention & Honesty` |
| [What Is Futarchy](../00-what-is-futarchy/README.md) | `docs/onchain-futarchy-design.md@3fad3cad278325c13a191c472f1be9ba5d15db02::FAO v0: On-Chain Futarchy Design` | The local design framing changes. `docs/onchain-futarchy-design.md@3fad3cad278325c13a191c472f1be9ba5d15db02::1. Problem and Scope` |
| [Prior Art](../00-what-is-futarchy/prior-art.md) | `docs/onchain-futarchy-design.md@3fad3cad278325c13a191c472f1be9ba5d15db02::10. References` | Local docs name new prior art. `docs/onchain-futarchy-design.md@3fad3cad278325c13a191c472f1be9ba5d15db02::10. References` |
| [Why Onchain](../00-what-is-futarchy/why-onchain.md) | `docs/onchain-futarchy-design.md@3fad3cad278325c13a191c472f1be9ba5d15db02::1. Problem and Scope` | On-chain rationale or threat assumptions change. `docs/onchain-futarchy-design.md@3fad3cad278325c13a191c472f1be9ba5d15db02::2. Threat Model` |

## FAO Repo Pages

| Page | Canonical source | Supporting sources |
|------|------------------|--------------------|
| [FAO Repo](../10-fao-repo/README.md) | `src/FutarchyRegistry.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::FutarchyRegistry` | `site-testnet/shared.js@3fad3cad278325c13a191c472f1be9ba5d15db02::loadInstances`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::connectWallet`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`, `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#daemons--crons` |
| [Architecture](../10-fao-repo/architecture.md) | `src/FutarchyRegistry.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::FutarchyInstance` | `src/FutarchyRegistryDeployers.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::FutarchyStackDeployer`, `site-testnet/shared.js@3fad3cad278325c13a191c472f1be9ba5d15db02::unpackInstance` |
| [Deployment](../10-fao-repo/deployment.md) | `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5` | `audit/state/COUPLING-NOTES.md@HEAD::Current HEAD drift: stack deployer`, `deployments.schema.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::required`, `scripts/validate-deployments.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Validate deployments`, `src/FutarchyRegistryDeployers.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`, `scripts/check-coupling-bytecode.js@HEAD::proposal_impl_v5` |
| [Deployment History](../10-fao-repo/deployment-history.md) | `docs/sepolia-deployment-v0.md@3fad3cad278325c13a191c472f1be9ba5d15db02::FAO v0 Sepolia live deployment` | `deployments.json@3fad3cad278325c13a191c472f1be9ba5d15db02::deprecated`, `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#inventory` |
| [Invariants](../10-fao-repo/invariants.md) | `audit/specs/INVARIANTS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#fao--top-15-invariants` | `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#invariant--engine-assignment`, `test/FutarchyArbitration.invariants.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::FutarchyArbitrationInvariantTest` |
| [Glossary](../10-fao-repo/glossary.md) | `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#top-level-structure` | Future pass. `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#build-order-phase-3` |

## Lifecycle Pages

| Page | Canonical source |
|------|------------------|
| [Create Instance](../10-fao-repo/lifecycle/00-create-instance.md) | `src/FutarchyRegistry.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createFutarchyPart1` |
| [Sale](../10-fao-repo/lifecycle/10-sale.md) | `src/InstanceSale.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::InstanceSale` |
| [Spot Liquidity](../10-fao-repo/lifecycle/20-spot-liquidity.md) | `src/SaleSpotSeeder.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::SaleSpotSeeder` |
| [Proposal](../10-fao-repo/lifecycle/30-proposal.md) | `src/FAOFutarchyFactory.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createProposal` |
| [Promote](../10-fao-repo/lifecycle/40-promote.md) | `src/FAOOfficialProposalOrchestrator.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createOfficialProposalAndMigrate` |
| [Resolve](../10-fao-repo/lifecycle/50-resolve.md) | `src/FAOTwapResolver.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::resolve` |
| [Arbitration](../10-fao-repo/lifecycle/60-arbitration.md) | `src/ParameterizedArbitration.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::ParameterizedArbitration` |

## Cross-Cutting, Verification, UI, And Operations Pages

| Page | Canonical source | Supporting sources |
|------|------------------|--------------------|
| [Security](../30-cross-cutting/security.md) | `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Mainnet migration executable checklist` | `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::T5.D2 / Step E`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::renounceIfStale` |
| [Threat Model](../30-cross-cutting/threat-model.md) | `audit/specs/THREAT-MODEL.md@3fad3cad278325c13a191c472f1be9ba5d15db02::FAO Threat Model` | `audit/specs/INVARIANTS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#fao--top-15-invariants` |
| [Cross-Cutting Deployment](../30-cross-cutting/deployment.md) | `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5` | `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::sourceVerificationStatus`, `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`, `audit/state/COUPLING-NOTES.md@HEAD::registry ABI mismatch` |
| [Deprecations](../30-cross-cutting/deprecations.md) | `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#deprecations` | `deployments.schema.json@3fad3cad278325c13a191c472f1be9ba5d15db02::required`, `scripts/sync-abis.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::sync-abis` |
| [Ops](../30-cross-cutting/ops.md) | `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::summary.json` | `site-ops/README.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#fao-ops-portal`, `audit/state/RUNBOOK.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#fao-operator-runbook`, `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::4 passed in 2.5m`, `audit/loops/worker-axe.log@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::heartbeat`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt` |
| [Supply Chain](../30-cross-cutting/supply-chain.md) | `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::budgets` | `audit/specs/SUPPLY-CHAIN.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#supply-chain-trust-model`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Upload axe audit`, `.github/workflows/screenshots.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Capture screenshots`, `site-testnet/shared.js@239313c31b169d4cc5073e6178aa372ee1e88c98::refreshTopbarState`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::screenshots` |
| [E2E Journey Map](../40-verification/e2e-journey-map.md) | `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress` | `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#user-journey-map`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::ENV_FORK_BLOCK_NUMBER`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `scripts/anvil-fork.sh@37603636e5194b202ad5438ce80bf9909aad42c8::ANVIL_FORK_BLOCK_NUMBER`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::restores stored EIP-6963 provider identity without prompting`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::CASES`, `audit/axe/home.json@HEAD::violations` |
| [Symbolic Obligations](../40-verification/halmos-instance-sale.md) | `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::check_INV_ORCH_002_refusesPreInit` | `test/InstanceSale.symbolic.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::InstanceSaleSymbolic`, `test/FutarchyArbitration.symbolic.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::FutarchyArbitrationSymbolic`, `.github/workflows/symbolic.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::halmos` |
| [Decidability](../40-verification/decidability.md) | `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#decidability-of-fao-invariants` | `.github/workflows/symbolic.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::Run Halmos on check_INV_* proof obligations`, `foundry.toml@3fad3cad278325c13a191c472f1be9ba5d15db02::profile.halmos` |
| [Mutation Resistance](../40-verification/mutation-resistance.md) | `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing` | `audit/specs/MUTATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#mutation-resistance`, `test/FutarchyArbitration.invariants.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::invariant_INV_ARB_004_strictNoBondMatching`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::placeNoBond(uint256)` |
| [UI Architecture](../30-themes/ui-architecture.md) | `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers` | `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoRpcUrl`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`, `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::sale-hero-symbol`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::topbar-wallet-identity`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass` |
| [Runbook](../50-operations/runbook.md) | `audit/state/RUNBOOK.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#fao-operator-runbook` | `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::etherscan-verified` |
| [Developer Cycle](../50-operations/developer-cycle.md) | `.github/workflows/e2e.yml@HEAD::Start testnet static site` | `DEVELOPER.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#developer-cycle`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::resetAnvilFork`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `scripts/anvil-fork.sh@37603636e5194b202ad5438ce80bf9909aad42c8::Usage: scripts/anvil-fork.sh [--stop]`, `.github/workflows/lighthouse.yml@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::Run Lighthouse`, `scripts/check-inp.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::PerformanceObserver`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass` |
| [Ops Dashboard](../50-operations/ops-dashboard.md) | `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::isCanonicalRow` | `site-ops/README.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#fao-ops-portal`, `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::DO NOT REMOVE THESE CDN TAGS`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::dashboard assets`, `site-ops/fao/summary.json@HEAD::generatedAt` |
| [Domain Architecture](../50-operations/domain-architecture.md) | `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::#futarchy.ai-domain-architecture` | `site-ops/README.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#cloudflare-pages`, `audit/state/RUNBOOK.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#fao-operator-runbook` |

## Deferred Pages

| Page | Canonical source | Reason deferred |
|------|------------------|-----------------|
| [Agents Vision](../20-agents-vision/README.md) | `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#top-level-structure` | The outline says this area depends on the separate `futarchy-fi/agents` repo. `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#open-questions-for-user-resolve-before-phase-3` |

## How This Might Be Wrong

- If a page's canonical source becomes an authored spec, this map should move the page away from code-only ownership. `audit/specs/INVARIANTS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#how-this-document-is-maintained`
- If `DECIDABILITY.md` is not updated after a test graduates, this map's verification rows may be fresher than the engine matrix. `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::INV-ARB-003`
- If wallet specs are renamed without updating `JOURNEY-MAP.md`, [E2E Journey Map](../40-verification/e2e-journey-map.md) should cite the spec files directly until the map catches up. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::Founder creates`
- If browser coupling moves out of Playwright, [Cross-Cutting Deployment](../30-cross-cutting/deployment.md) should follow the new executable coupling artifact rather than keep citing the old spec. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::deployment coupling - read-only live site`
- If `site-ops/` changes deploy target, project name, or public DNS mapping, [Ops Dashboard](../50-operations/ops-dashboard.md) and [Domain Architecture](../50-operations/domain-architecture.md) must rebuild from the ops README, deploy workflow, and domain note together. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cloudflare-pages`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Active mappings`
- If `.github/workflows/e2e.yml` changes wallet gating or PR triggers, both [E2E Journey Map](../40-verification/e2e-journey-map.md) and [Developer Cycle](../50-operations/developer-cycle.md) should rebuild. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::workflow_dispatch`
- If generated ABI files, wallet logs, or type tokens change again, rebuild pages from those concrete artifacts rather than from older worker-plan prose. `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`
- If transaction review cards or adapter mutability mode move to different files, rebuild the UI, security, and deployment rows from the new concrete artifacts. `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If wallet F2/F3/F6 or the coupling drift note is superseded, rebuild the E2E, developer-cycle, ops, and deployment rows together. `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Current HEAD drift: stack deployer`
- If FE-QA scripts, artifacts, wallet-session state, or sale decision selectors move, rebuild the UI, E2E, supply-chain, ops, and developer-cycle rows together. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::capture:screenshots`, `audit/axe/home.json@HEAD::violations`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_SESSION_STORAGE_KEY`, `tests-e2e/SELECTORS.md@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-strip`
- If dashboard filtering, CDN loading, or visual snapshot gating changes, rebuild the source map before updating reader-facing pages because those sources decide which rows count as canonical evidence. `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::isCanonicalRow`, `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::cdn.jsdelivr.net`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Run visual snapshot suite`
- If dirty worktree overlays are committed, replace `@HEAD` overlay citations with the resulting commit SHA so future evaluators can resolve the exact source blob. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`

## See Also

- [How This Wiki Is Maintained](how-this-wiki-is-maintained.md)
- [Open Questions](open-questions.md)
- [Futarchy Wiki — Outline (pre-build)](../_OUTLINE.md)
- [Futarchy Wiki](../README.md)
- [Deployment](../10-fao-repo/deployment.md)
- [Ops Dashboard](../50-operations/ops-dashboard.md)
- [Domain Architecture](../50-operations/domain-architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 5a3953405c6017b990b4b3add843dff77c5f6f86
  - 9e83d3dded5ea385ff6004dc71b2a1fed53f1fa3
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
