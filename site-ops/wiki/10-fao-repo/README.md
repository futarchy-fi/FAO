---
canonical: src/FutarchyRegistry.sol@e0cd25b942ca2d98c37aa53e21205b562f4fab68::FutarchyRegistry
scope: Authoritative overview of the FAO repo's contract, site, verification, and operator surfaces.
not-scope: The conceptual futarchy model is covered in [What Is Futarchy](../00-what-is-futarchy/README.md); active address flow is covered in [Deployment](deployment.md).
last-rebuilt: 2026-05-23T03:13:06Z
---
# FAO Repo

The FAO repo is a working on-chain futarchy stack, not only a token sale or a proposal UI. It matters because instance creation, sale accounting, liquidity, conditional markets, TWAP resolution, arbitration, browser delivery, shared wallet-provider selection, decoded transaction review, wallet happy paths, FE-QA artifacts, operator checks, ABI freshness, adapter-lock posture, and UI/contract/deploy coupling now have separate canonical docs. The canonical repo mechanism is `FutarchyRegistry`, which deploys per-instance token, sale, arbitration, resolver, proposal factory, orchestrator, and spot pool while the site and ops pages read manifests, wallet state, E2E/a11y signals, generated ABI bindings, coupling notes, and audit outputs around that on-chain core. `src/FutarchyRegistry.sol@e0cd25b942ca2d98c37aa53e21205b562f4fab68::FutarchyRegistry`, `site-testnet/shared.js@e0cd25b942ca2d98c37aa53e21205b562f4fab68::loadDeployments`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Current HEAD drift: stack deployer`, `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::4 passed in 2.5m`, `audit/axe/home.json@HEAD::violations`

## Changed Since R4 Wiki

The prior repo overview described contracts, site, scripts, and historical deployment evidence, but it still treated deployment constants as a site detail and did not point at the new runbook, developer-cycle doc, ops portal, or verification specs. `audit/wiki/10-fao-repo/README.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#three-surfaces`

The first docs/ops refresh added explicit operator and developer docs, a forge CI workflow, a symbolic workflow, and a static ops portal whose dashboard consumes audit JSONL. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#daemons--crons`, `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cycle-times-measured-2026-05-22`, `.github/workflows/forge.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::Forge tests`, `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#fao-ops-portal`

Since the last wiki refresh at source HEAD `c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7`, the repo expanded the no-wallet fork-state path to prove that `/`, `/sale.html`, and `/proposals.html` reflect cast-created on-chain mutations. `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::Covered fork mutations`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::sale page reflects cast buy balance without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::proposals page reflects cast-placed YES bond without wallet signing`

Since source HEAD `80a3fa25e322f8af7248b04192a3649854fe9fe0`, `site-testnet/shared.js` became the shared wallet-provider owner by adding EIP-6963 discovery, selected-provider persistence, provider identity UI, and `fao:walletChanged` propagation. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::EIP6963_ANNOUNCE`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::WALLET_PROVIDER_STORAGE_KEY`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::fao:walletChanged`

Since source HEAD `16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea`, `.github/workflows/e2e.yml` added CI execution for read-only and fork Playwright projects while leaving wallet/Synpress as opt-in. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::read-only`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::fork`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::wallet`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, the repo resynced orchestrator and stack-deployer ABI JSON, tokenized UI type scale in `styles.css`, aligned the ORCH-002 symbolic harness constructor, and landed a green F1 wallet-project run on Anvil. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::createOfficialProposalAndMigrate`, `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::T1.D6`, `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::true`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, the repo added executable security posture checks (`ADAPTER_REPLACEABLE` plus `FAORenewableAdmin`), expanded fork-state E2E to NO-bond and try-graduate transitions, added decoded review cards before wallet confirmations, and tightened CSS token usage again. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAORenewableAdmin`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--overlay`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, the repo added a known stack-deployer bytecode drift note, a registry-wiring manifest coupling test, wallet F2/F3/F6 happy paths, T1 one-primary/numeric/a11y UI changes, and v2 FE-QA rubrics/workers. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::real source-vs-deploy drift`, `test/Coupling.t.sol@c183c1c461099e69c0c03535c6d08ae87a635853::testFork_activeRegistryWiringMatchesManifest`, `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path`, `tests-e2e/journeys/F3-ragequit.wallet.spec.ts@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path`, `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path`, `site-testnet/styles.css@358b1a14f9927b2eafd7790d094a8432be60a0d9::skip-nav`, `audit/rubrics/v2/topic-1-web3-ux-v2.md@6b8c7252c17c84895a3b28ae771d018bdbb8d31e::tool-emitted evidence`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, the repo added persistent sale transaction links, concrete FE-QA scripts/workflows for axe/Lighthouse/screenshots, sale decision numerics, hardened wallet-session state, and a visual minimalism audit. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::capture:screenshots`, `site-testnet/sale.html@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-strip`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::rememberWalletSession`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#type-scale`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, the repo added F1 deployed-page compatibility, committed axe JSON with zero violations, and screenshot/snapshot artifacts. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@89486c060069f6ee2e61ff75cfb47d5a3314ad56::hasConfirmCard`, `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::combined targeted wallet regression passed`, `audit/axe/contracts.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::counts`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::screenshots`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, the repo added a read-only axe upload in E2E CI, a dedicated visual snapshot CI job, a wallet-provider reconnect spec, decoded review-card fixture evidence, canonical-row filtering and first-paint summary generation for the ops dashboard, a Web Vitals aggregate with current budget status, a worker axe heartbeat, and a refreshed screenshot manifest at current HEAD. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::axe-audit-read-only`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::FAO_ENABLE_VISUAL_SNAPSHOTS`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Reconnected with Mock 6963 Wallet`, `audit/review-cards/T1.D3.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::test`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::summary`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::budgetsPass`, `audit/loops/worker-axe.log@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::heartbeat`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, the repo added performance-stabilizing fallback HTML for the home and sale pages, committed a passing local Web Vitals aggregate, and updated the read-only coupling spec to validate both compact and full visible address text through the same expected href/title address. `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::sale-hero-price`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`

The current committed frontier adds `proposal_impl_v5` as an active manifest address, makes coupling check registry `PROPOSAL_IMPL()`, records `polsia.futarchy.ai`, commits fork-state Playwright routing plus shared ethers/RPC loading, and adds gas-estimate rows to sale buy/ragequit pre-confirm cards; dirty worktree overlays still add Synpress/MetaMask F1 helpers over fork-routed JSON-RPC and fork CI local-site startup. `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `test/Coupling.t.sol@f96ced010f19032837e96094c935572a2320230f::PROPOSAL_IMPL`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::Gas estimate (≈)`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`

## Four Surfaces

The contract surface is rooted in `src/`: registry creation, sale mint/ragequit, proposal market creation, official proposal promotion, TWAP resolution, and bond arbitration remain separate modules. `src/FutarchyRegistry.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createFutarchyPart1`, `src/InstanceSale.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::ragequit`, `src/FAOFutarchyFactory.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createProposal`, `src/FAOOfficialProposalOrchestrator.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createOfficialProposalAndMigrate`, `src/FAOTwapResolver.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::resolve`

The site surface is under `site-testnet/`: `shared.js` loads `deployments.json`, loads generated ABI JSON through `window.loadFaoAbi`, lazy-loads ethers when page scripts need it, publishes the active RPC URL, loads registry instances, exposes the active instance to page scripts, owns EIP-6963 provider selection, hardens wallet-session state, and gives create/proposal/bond pages a shared signer through `window.connectWallet()`. `site-testnet/shared.js@3fad3cad278325c13a191c472f1be9ba5d15db02::loadDeployments`, `site-testnet/shared.js@3fad3cad278325c13a191c472f1be9ba5d15db02::loadAbi`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoRpcUrl`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_IDLE_MS`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::connectWallet`

The verification surface is split across authored specs, stateful Foundry invariants, Halmos-shaped `check_INV_*` obligations, mutation catalogues, E2E journeys, axe artifacts, visual snapshots, Lighthouse/Web Vitals outputs, a read-only deployment-coupling spec, a committed F1/F2/F3/F6 wallet-project pass, and the E2E workflow that makes read-only/fork/visual projects CI-visible. `audit/specs/INVARIANTS.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#pass-status`, `audit/specs/DECIDABILITY.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#invariant--engine-assignment`, `tests-e2e/JOURNEY-MAP.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#journeys`, `audit/axe/proposals.json@HEAD::violations`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::toHaveScreenshot`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`

The operator surface is no longer only deployment scripts: `RUNBOOK.md` names two long-running components plus one scheduled deployment-sync job, and `site-ops/` serves a Cloudflare Pages dashboard from copied audit evaluation JSONL. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#daemons--crons`, `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cloudflare-pages`

## Lifecycle Pages

| Step | Page | Primary transition |
|------|------|--------------------|
| 1 | [Create Instance](lifecycle/00-create-instance.md) | Registry Part1 then Part2 deploy per-instance stack. `src/FutarchyRegistry.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createFutarchyPart1` |
| 2 | [Sale](lifecycle/10-sale.md) | Buyers mint tokens and may ragequit for pro-rata treasury assets. `src/InstanceSale.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::buy`, `src/InstanceSale.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::ragequit` |
| 3 | [Spot Liquidity](lifecycle/20-spot-liquidity.md) | Sale admin seeds spot LP and fLP becomes ragequittable. `src/SaleSpotSeeder.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::seedSpot` |
| 4 | [Proposal](lifecycle/30-proposal.md) | Factory creates CTF condition, wrappers, and proposal clone. `src/FAOFutarchyFactory.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createProposal` |
| 5 | [Promote](lifecycle/40-promote.md) | Orchestrator creates conditional pools, binds resolver, migrates liquidity, and tips builder. `src/FAOOfficialProposalOrchestrator.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::createOfficialProposalAndMigrate` |
| 6 | [Resolve](lifecycle/50-resolve.md) | Resolver reads TWAP and reports CTF payouts. `src/FAOTwapResolver.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::resolve` |
| 7 | [Arbitration](lifecycle/60-arbitration.md) | Bonds escalate, graduate, settle, and pay out through withdrawable balances. `src/ParameterizedArbitration.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::ParameterizedArbitration` |

## Current-State Warning

Historical deployment docs are evidence, not the current address oracle; active address reads come from `deployments.json` through `loadDeployments()`, active ABI reads come from generated `site-testnet/abis/*.json` through `loadFaoAbi()`, and the read-only coupling spec now checks the browser-published active instance against registry data. `docs/sepolia-deployment-v0.md@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::FAO v0 Sepolia live deployment`, `site-testnet/shared.js@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::loadDeployments`, `site-testnet/shared.js@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::loadAbi`, `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::readInstance`

Generated ABI freshness is also repo state: current `site-testnet/abis/FAOOfficialProposalOrchestrator.json` includes `createOfficialProposalAndMigrate`/`setAdapter`, and `site-testnet/abis/FutarchyStackDeployer.json` includes `deployStack`. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::setAdapter`, `site-testnet/abis/FutarchyStackDeployer.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::deployStack`

## How This Might Be Wrong

- If the site moves from registry-driven active instances to a backend indexer, the site-surface section will be stale. `site-testnet/shared.js@3fad3cad278325c13a191c472f1be9ba5d15db02::loadInstances`
- If wallet-provider selection moves out of `shared.js`, the site-surface boundary should be rebuilt from the new provider owner. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::resolveWalletProvider`
- If ABI JSON is regenerated again, deployment and repo pages should cite the generated files at the new commit. `site-testnet/abis/FAOOfficialProposalOrchestrator.json@887a22ec35edc2e739f5ad10fb203a2d9beb14f8::constructor`
- If `RUNBOOK.md` adds real PagerDuty or Slack alerting, this page's operator summary should stop calling alerts operator-eyes-only. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#alerts-operator-eyes-only--no-slackpagerduty-wiring-yet`
- If `DECIDABILITY.md` catches up with the post-`030d` `INV-ARB-003` invariant graduation, the verification pages should remove their drift note. `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::INV-ARB-003`
- If future wiki passes add contract pages, this page should become a thinner index. `audit/wiki/_OUTLINE.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#top-level-structure`
- If the coupling spec starts checking resolver, orchestrator, factory, or spot-pool fields, this page should stop describing it as token/sale/arbitration-only. `tests-e2e/coupling.read-only.spec.ts@c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7::expected`
- If mainnet deployment posture stops being controlled by `ADAPTER_REPLACEABLE`, the overview should move the security-mode summary to the new source. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If the active stack deployer is redeployed, the repo overview should stop listing current coupling drift as a warning. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::Do not skip or bless this mismatch`
- If FE-QA scripts or workflows move out of the root package, the verification surface should rebuild from the new command owner. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::a11y`
- If the minimalism audit diverges from `styles.css`, the site-surface summary should cite CSS again instead of the audit doc. `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::Scope`
- If the visual snapshot job or ops dashboard summary loader changes, this overview should rebuild from E2E workflow and dashboard sources rather than only the artifact directories. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::summaryToTopicRounds`
- If the current dirty worktree overlay is committed, replace `@HEAD` citations for F1 and fork CI local-site changes with the resulting commit SHA. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`

## See Also

- [Architecture](architecture.md)
- [Invariants](invariants.md)
- [Deployment](deployment.md)
- [Cross-Cutting Deployment](../30-cross-cutting/deployment.md)
- [Runbook](../50-operations/runbook.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 5a3953405c6017b990b4b3add843dff77c5f6f86
  - 37603636e5194b202ad5438ce80bf9909aad42c8
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
  - cd5e73e73b21c0ac73bf80e8cac4c9dc31edfab0
  - fe9abbe3331b70b1600f4a4d28ee39a6bd539fed
  - 806c9c5aa7b5b74e1c25c8872a339e8c56457a5c
  - ed51e829b6cc888379043d9af02cc20e4e00eafb
  - 1b0c0d7d457cc8468639d288eb14cba0042c801d
  - 4b4c04664009807658ca64722d3aea1fbfb401d0
  - a2dc1a002e1a4cf164b2abab803835a7dd619b7d
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - 5e532972f18bafdcd8f6d2c48bf314db0da24a6c
  - 239313c31b169d4cc5073e6178aa372ee1e88c98
  - eba3449c9feab3e7154220f68de80ae5501d6dab
  - f96ced010f19032837e96094c935572a2320230f
  - 8847265a00f7064cdff1fbeffea572d10e889ff9
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:15:22Z.
- Build pass: 18 (continuous HEAD refresh)
