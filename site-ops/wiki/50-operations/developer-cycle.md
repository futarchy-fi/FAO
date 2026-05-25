---
canonical: .github/workflows/e2e.yml@HEAD::Start testnet static site
scope: Authoritative wiki summary of FAO local developer-loop commands, measured cycle times, and CI cycle changes.
not-scope: Live operations and incident playbooks live in [Runbook](runbook.md); E2E journey semantics live in [E2E Journey Map](../40-verification/e2e-journey-map.md).
last-rebuilt: 2026-05-23T03:04:18Z
---
# Developer Cycle

The developer-cycle doc is the measured loop inventory for building, testing, serving, and verifying FAO changes. It matters because local and CI feedback times are now explicit evidence, not guesses, and the E2E loop now has read-only/fork/visual CI, a combined green F1/F2/F3/F6 wallet-project regression, and separate FE-QA commands/artifacts for a11y, screenshots, review cards, wallet reconnect, and Lighthouse. The canonical mechanism is a table of cold/warm timings plus iteration patterns for contracts, site changes, spec/invariant changes, Playwright read-only/fork/wallet/visual projects, and workflows that decide which loops block PRs. `DEVELOPER.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#cycle-times-measured-2026-05-22`, `DEVELOPER.md@e0cd25b942ca2d98c37aa53e21205b562f4fab68::#iteration-patterns`, `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::combined targeted wallet regression passed`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, the wiki had no developer-cycle page and no row for `DEVELOPER.md`. `audit/wiki/_meta/source-of-truth-map.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#cross-cutting-and-verification-pages`

The first developer-cycle refresh added `DEVELOPER.md` and a forge CI workflow, so the doc's "Foundry tests not yet in CI" row is stale relative to `.github/workflows/forge.yml`. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#ci-cycle`, `.github/workflows/forge.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::Forge tests`

Since the previous wiki refresh at source HEAD `c1a01f9bfb2290ea4952f0131e1885fc3d5a41f7`, the fork project grew from one home mutation to three mutation flows: home instance creation, sale buy, and proposal YES bond. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::home page reflects instancesCount after cast-created instance`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::sale page reflects cast buy balance without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::proposals page reflects cast-placed YES bond without wallet signing`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, static analysis added an Etherscan verification job that installs `etherscan-api@10.3.0` and runs `scripts/check-etherscan-verified.sh` with `ETHERSCAN_API_KEY`. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Etherscan verification gate`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Install etherscan-api`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_API_KEY`

Since source HEAD `16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea`, the new E2E workflow runs `read-only` and `fork` jobs in CI and keeps the `wallet` Synpress job behind manual `workflow_dispatch` input. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::read-only`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::fork`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::include-wallet`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, the wallet project has a committed F1 pass record: `npm run e2e -- --project=wallet --grep F1` passed one wallet test, and a targeted `FAOSmokeTest` Forge run passed after the broader run hit environment/termination issues. `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::plain npm test failed`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::Targeted Forge verification passed`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, the fork project grew by two more proposal-state loops: cast `placeNoBond(uint256)` and cast `tryGraduate(uint256)`, each with a reload assertion against `/proposals.html`. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`

The same source window added executable security-posture unit loops for adapter one-shot mode and renewable-admin stale revocation. `test/FAOOfficialProposalOrchestrator.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_setAdapter_isOneShotWhenMainnetMode`, `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_anyoneCanRenounceStaleDefaultAdmin`, `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_adminRenewalExtendsGraceDeadline`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, wallet-project local evidence expanded from F1 to F2, F3, and F6. The worker log records one passing targeted wallet command for each path and a targeted `FAOSmokeTest` pass after each commit. `audit/loops/worker-synpress.log@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path now passes`, `audit/loops/worker-synpress.log@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path now passes`, `audit/loops/worker-synpress.log@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path now passes`, `audit/loops/worker-synpress.log@216b40e5766ac222e2b6e33d92c0a358ad2500c4::Targeted Forge verification for F6 commit passed`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, site iteration gained explicit FE-QA loops: `npm run a11y` runs the axe Playwright spec, `npm run lighthouse` runs LHCI, and `npm run capture:screenshots` captures desktop/mobile screenshots plus a manifest. These are commands to schedule or inspect, not commands run by this wiki refresh. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::a11y`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::lighthouse`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::capture:screenshots`, `scripts/capture-screenshots.sh@6283126ee2e83ddc47966eaea01e40f8f52143ee::audit/screenshots`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, developer-loop evidence got two stronger artifacts: the wallet loop passed a combined F1/F2/F3/F6 grep in 2.5 minutes after F1 compatibility fixes, and FE-QA output files were committed for axe and screenshots. `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::4 passed in 2.5m`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@89486c060069f6ee2e61ff75cfb47d5a3314ad56::hasConfirmCard`, `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::counts`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::generatedAt`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, the developer cycle added a CI visual-snapshot job, a read-only axe artifact upload, a wallet-provider reconnect spec, a decoded review-card spec/evidence file, a Lighthouse Web Vitals aggregate, dashboard row filtering for canonical evaluator rows, and a worker axe heartbeat. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Upload axe audit`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::restores stored EIP-6963 provider identity without prompting`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::transaction review card has decoded args and controls`, `audit/review-cards/T1.D3.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`, `audit/lighthouse/web-vitals.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`, `audit/dashboard/dashboard.js@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::isCanonicalRow`, `audit/loops/worker-axe.log@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::heartbeat`

Since source HEAD `b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b`, the Lighthouse loop became more explicit: the workflow waits for deployed Pages assets, runs LHCI, measures INP through Playwright, writes reports through `lighthouse-summary.mjs`, verifies freshness again, and records Topic 1/3 evaluator data for dashboard consumers. `.github/workflows/lighthouse.yml@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::Wait for deployed Pages assets`, `.github/workflows/lighthouse.yml@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::Check INP`, `scripts/check-inp.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::exercisePage`, `scripts/lighthouse-summary.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::writeJson`, `scripts/check-pages-freshness.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::STALE`, `audit/evaluations/topic-1-evals.jsonl@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::lighthouse`, `audit/evaluations/topic-3-evals.jsonl@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::topic`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, the performance loop has concrete local evidence: `site-testnet/index.html` and `sale.html` ship nonblank first-paint placeholders, `shared.js` updates topbar links/chip in place after deferred data load, and `web-vitals.json` records a passing local post-change mobile run. `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::sale-progress-text`, `site-testnet/shared.js@239313c31b169d4cc5073e6178aa372ee1e88c98::afterInitialPaint`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`

The latest committed fork refresh changes the no-wallet developer loop, while dirty workflow/F1 overlays still own CI startup and wallet-provider automation. Fork CI now starts `npm run dev`, waits for `http://127.0.0.1:8766/`, pins block `10899720`, and uploads the local site log from dirty workflow changes; committed `3760363` narrows the fork project to `fork-state.read-only.spec.ts`, adds Anvil start/stop scripting, and lets the spec reset the fork block, while dirty F1 uses Synpress/MetaMask connection helpers instead of a synthetic injected wallet. `.github/workflows/e2e.yml@HEAD::Start testnet static site`, `.github/workflows/e2e.yml@HEAD::ANVIL_FORK_BLOCK_NUMBER`, `.github/workflows/e2e.yml@HEAD::fao-site-log-fork`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::resetAnvilFork`, `scripts/anvil-fork.sh@37603636e5194b202ad5438ce80bf9909aad42c8::ANVIL_FORK_BLOCK_NUMBER`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`

## Measured Loop

The TL;DR commands cover submodules, npm install, Foundry, static site serve, forge tests, and read-only E2E. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#tldr`

Measured times include 35s cold/0.5s warm build, 75s cold/65s warm unit suite, 240s cold/230s warm invariant suite, ~90s per symbolic check, sub-0.1s deployment sync, 0.1s site serve, and 30s cold/10s warm read-only E2E. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cycle-times-measured-2026-05-22`

The contract iteration pattern runs a focused forge test, then the non-fork suite, then invariant and symbolic checks when touching `INV-*` surfaces. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Contract change (most common)`

The site iteration pattern has no build step, but deployment changes require copying `deployments.json` into `site-testnet/deployments.json` and running the sync check. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Site change`

The E2E local loop has two no-wallet paths: `npm run e2e:read-only` runs the Playwright `read-only` project, while the fork project now matches only `fork-state.read-only.spec.ts` and expects a locally served site at port `8766`. `package.json@e0cd25b942ca2d98c37aa53e21205b562f4fab68::e2e:read-only`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::testMatch`, `.github/workflows/e2e.yml@HEAD::FAO_SITE_URL: http://127.0.0.1:8766`

The fork-state project now needs enough local Anvil state to run `createFutarchyPart1`, `InstanceSale.buy`, `createFutarchyPart2`, `FAOFutarchyFactory.createProposal`, WETH `deposit/approve`, arbitration `placeYesBond`, `placeNoBond`, and `tryGraduate`. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::castSendCreatePart1`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::buy(uint256)`, `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::placeYesBond`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::placeNoBond(uint256)`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::tryGraduate(uint256)`

## CI Reality

`static-analysis.yml` now includes deployment schema/sync, ABI sync, ops-dashboard sync, Etherscan verification, and Slither. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::jobs`

The Etherscan job is not a local developer timing row yet: it depends on `ETHERSCAN_API_KEY`, queries active deployment addresses, and can fail because `verification_todo` is stale or active contracts remain unverified. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Assert active contracts are verified`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verificationTodo`

`symbolic.yml` runs SMTChecker and Halmos, while `forge.yml` now runs build, unit/integration, and invariant jobs. `.github/workflows/symbolic.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::jobs`, `.github/workflows/forge.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::jobs`

`e2e.yml` adds two automatic Playwright jobs and one opt-in wallet job: read-only uses `npm run e2e:read-only`, fork installs Foundry, starts the local site, and runs `npx playwright test --project=fork`, and wallet starts Anvil before `npx playwright test --project=wallet`. The current F1 source proves the wallet project is back on Synpress/MetaMask automation while still routing JSON-RPC to the local fork. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::Run read-only project`, `.github/workflows/e2e.yml@HEAD::Run fork project`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::Run wallet project`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`

F1 now also includes the create transaction review-card click before the create transaction proceeds, which means local wallet-project failures can come from review UI as well as wallet/provider plumbing. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-create`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-create-confirm`

The wallet loop now has three more focused commands in the worker log: `--grep "F2-buy-via-sale happy path"`, `--grep "F3-ragequit happy path"`, and `--grep "F6-create-proposal happy path"`. `audit/loops/worker-synpress.log@43074d02be5fb427aed16560aeec0f1f8914d5e5::npm run e2e -- --project=wallet --grep "F2-buy-via-sale happy path"`, `audit/loops/worker-synpress.log@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::npm run e2e -- --project=wallet --grep "F3-ragequit happy path"`, `audit/loops/worker-synpress.log@216b40e5766ac222e2b6e33d92c0a358ad2500c4::npm run e2e -- --project=wallet --grep "F6-create-proposal happy path"`

## FE-QA Loops

`npm run a11y` is a focused browser loop around `tests-e2e/journeys/a11y.read-only.spec.ts`; the spec calls `runAxeOn`, writes `audit/axe/<label>.json`, and rejects critical or serious axe violations. The current artifact set records no violations for every scanned page. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::a11y`, `tests-e2e/axe-helper.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::runAxeOn`, `audit/axe/create.json@HEAD::violations`

`npm run lighthouse` delegates to `lhci autorun`, and the Lighthouse workflow copies `.lighthouseci/*.json` into `audit/lighthouse` before uploading reports. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::lhci autorun`, `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Run Lighthouse`, `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::audit/lighthouse`

`npm run capture:screenshots` calls `scripts/capture-screenshots.sh`, which serves or uses the target site, captures named pages at viewport variants, and records file hashes/byte counts in `audit/screenshots/manifest.json`. The committed `58f0020` manifest has 12 screenshot entries. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::capture:screenshots`, `scripts/capture-screenshots.sh@6283126ee2e83ddc47966eaea01e40f8f52143ee::viewport`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::screenshots`

The current visual snapshot CI loop is not the same as screenshot capture: it starts the local static site, runs only `tests-e2e/journeys/snapshots.read-only.spec.ts` under the read-only project, requires `FAO_ENABLE_VISUAL_SNAPSHOTS=1`, and uploads Playwright reports regardless of pass/fail. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Start testnet static site`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Run visual snapshot suite`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::FAO_ENABLE_VISUAL_SNAPSHOTS`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::playwright-report-visual-snapshots`

Lighthouse now has an aggregate: `web-vitals.json` records mobile-mode budgets for LCP, INP, CLS, TBT, and FCP, and the committed `239313c` artifact records a local post-change run with `pass` true. `audit/lighthouse/budgets.md@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::Lighthouse Web Vitals Budgets`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::source`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pages`

The workflow path filter means site, E2E, Playwright config, package, Anvil script, and workflow edits run E2E on push, while pull requests run the workflow independently of that push path list. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::paths`, `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::pull_request`

The developer doc still says Foundry tests are not yet in CI, so this page records the source drift explicitly instead of repeating the stale row as current truth. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Foundry tests`, `.github/workflows/forge.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::forge test (excluding fork)`

## How This Might Be Wrong

- Cycle times are machine-specific and were measured on 2026-05-22; cloud CI may be slower. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#how-this-might-be-wrong`
- The CI section in `DEVELOPER.md` is stale after `forge.yml`; this page should be rebuilt once the doc itself is corrected. `DEVELOPER.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#ci-cycle`
- If `npm run e2e:read-only` grows to include fork-state or wallet specs, the timing table should split read-only, fork, and wallet loops. `playwright.config.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::projects`
- If the fork-state suite keeps adding cast mutations, this page should stop treating its runtime as comparable to the older 30s/10s read-only timing. `tests-e2e/journeys/fork-state.read-only.spec.ts@e0cd25b942ca2d98c37aa53e21205b562f4fab68::test.describe.configure({ mode: 'serial' })`
- If the E2E workflow starts varying `FAO_COUPLING_INST` or `ANVIL_FORK_BLOCK_NUMBER`, this page should document that matrix rather than only the default jobs. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::env`
- If Etherscan verification becomes a local command in `DEVELOPER.md`, this page should add measured cold/warm timing for it rather than only CI semantics. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_MAX_ATTEMPTS`
- If mutation testing gets a workflow, developer cycle should add its expected wall time and trigger conditions. `audit/specs/MUTATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Tool wiring left`
- If the wallet job becomes a normal PR gate, this page should stop describing Synpress as manual-only. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::github.event_name == 'workflow_dispatch'`
- If the F1 wallet path changes again, the developer cycle should split timing and flake notes by provider mode rather than carrying old injected-provider or MetaMask assumptions. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`
- If security-posture tests are added to `DEVELOPER.md` timing tables, this page should cite the measured timing instead of only the test names. `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAORenewableAdminTest`
- If wallet happy paths become normal PR gates, the developer cycle must move them out of "manual wallet project" semantics. `.github/workflows/e2e.yml@46903c84a2c8835cd13fb5e2ecfa858df20bea50::workflow_dispatch`
- If FE-QA commands are folded into the main E2E workflow, the developer cycle should stop listing them as separate optional loops. `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::a11y`
- If Lighthouse budgets or screenshot targets change, this page should cite the changed config or manifest rather than only the command names. `lighthouserc.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::largest-contentful-paint`, `audit/screenshots/manifest.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::generatedAt`
- If the combined F1/F2/F3/F6 wallet regression fails later, this page should cite the newer worker log instead of the `89486c0` pass. `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::combined targeted wallet regression passed`
- If the visual snapshot job is merged into normal read-only E2E, this page should stop counting it as a separate CI loop. `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`
- If the Web Vitals aggregate changes source, URL targets, or budgets, the developer-cycle page must cite the newer `web-vitals.json` before carrying forward the current pass status. `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::budgetsPass`
- If the current fork CI workflow overlay is committed, replace `@HEAD` citations for `Start testnet static site`, `ANVIL_FORK_BLOCK_NUMBER`, and `fao-site-log-fork` with the commit SHA. `.github/workflows/e2e.yml@HEAD::Start testnet static site`, `.github/workflows/e2e.yml@HEAD::fao-site-log-fork`

## See Also

- [Runbook](runbook.md)
- [E2E Journey Map](../40-verification/e2e-journey-map.md)
- [Decidability](../40-verification/decidability.md)
- [Mutation Resistance](../40-verification/mutation-resistance.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
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
  - aba4046dec32448a09daa308d8fea8cb661671be
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
  - 6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00
  - c17ef8b51560710c4fca17d9fb667e5e0f816e7f
  - 5c672c5540af07df5b6ab368e8ff606fc23649b6
  - 43074d02be5fb427aed16560aeec0f1f8914d5e5
  - d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b
  - 216b40e5766ac222e2b6e33d92c0a358ad2500c4
  - 6283126ee2e83ddc47966eaea01e40f8f52143ee
  - 89486c060069f6ee2e61ff75cfb47d5a3314ad56
  - 5e7c0f139380b0b2296d7055b28188feae56ca4e
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - c8f7371de72ca6f054d221ff5a80386ab555bfac
  - cd5e73e73b21c0ac73bf80e8cac4c9dc31edfab0
  - fe9abbe3331b70b1600f4a4d28ee39a6bd539fed
  - 806c9c5aa7b5b74e1c25c8872a339e8c56457a5c
  - ed51e829b6cc888379043d9af02cc20e4e00eafb
  - 4b4c04664009807658ca64722d3aea1fbfb401d0
  - a2dc1a002e1a4cf164b2abab803835a7dd619b7d
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - fd6cb47b2fa8b4cb6c9a1825f61935798b402243
  - c990d1d0e3cc034e6a570e62747756553c4498c5
  - e5c20a5c7e688bf4791b5b79948c81afa94e80f6
  - 0ee626377a781ffe7587049d8fda474fcb5f984d
  - e48b24cbb63f6f0f3e5e4ab39b449aa54ce23883
  - 5e532972f18bafdcd8f6d2c48bf314db0da24a6c
  - 239313c31b169d4cc5073e6178aa372ee1e88c98
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:03:52Z.
- Build pass: 17 (continuous HEAD refresh)
