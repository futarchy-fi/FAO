---
canonical: tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress
scope: Authoritative cross-cutting summary of FAO operator surface, live ops dashboard, worker-lift evidence, deployment drift, and mainnet-timelock posture.
not-scope: Active contract address mechanics live in [Deployment](../10-fao-repo/deployment.md); security key policy lives in [Security](security.md).
last-rebuilt: 2026-05-23T03:04:18Z
---
# Ops

The ops surface now includes local runbooks, CI gates, a live Cloudflare Pages dashboard, worker-produced verification evidence, FE-QA artifacts, and explicit deployment-drift notes. It matters because operational readiness is no longer only "can a script run"; reviewers need to know which public dashboard, daemon, CI job, wallet journey, visual/a11y/performance artifact, migration sketch, and known-red coupling result is authoritative. The canonical mechanism is `site-ops/` for the public dashboard, `audit/state/RUNBOOK.md` for operator actions, and authored specs/tests/logs/workflows/artifacts for the verification lifts that operations now tracks. `site-ops/README.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#fao-ops-portal`, `audit/state/RUNBOOK.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#fao-operator-runbook`, `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::combined targeted wallet regression passed`, `audit/axe/home.json@HEAD::violations`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`

## Changed Since Last Refresh

The prior wiki refresh at `3fad3cad278325c13a191c472f1be9ba5d15db02` captured `INV-ARB-003` and the initial ops dashboard scaffold, but did not include the later worker commits for Synpress F1, `INV-ARB-004`, `INV-ARB-006`, `INV-ORCH-001`, the timelock sketch, or live ops deployment. `audit/wiki/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#futarchy-wiki`

At the requested target `21f29adc8dd1ac6a0e3f4b5d5ae231022316a309`, the authored invariant pass-status table marks `INV-ARB-003`, `INV-ARB-004`, `INV-ARB-006`, and `INV-ORCH-001` as tested. Later committed refresh points add `INV-ORCH-002`, address-link-tolerant coupling, active `proposal_impl_v5` coupling, a futarchy.ai domain architecture note, the `polsia.futarchy.ai` Render mapping, and fork-driven Playwright state journeys; the current committed source frontier for this refresh is `37603636e5194b202ad5438ce80bf9909aad42c8`. `audit/specs/INVARIANTS.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#pass-status`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`, `deployments.json@f96ced010f19032837e96094c935572a2320230f::proposal_impl_v5`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`, `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, F1 moved from earlier Synpress wiring notes to a committed green wallet-project run on an Anvil fork, with the worker log recording one F1 pass and a targeted `FAOSmokeTest` pass. `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::npm run e2e -- --project=wallet --grep F1 passed`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::Targeted Forge verification passed`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, operations gained executable mainnet security posture checks for adapter lock mode and stale admin revocation, plus fork E2E checks for NO-bond and try-graduate browser reflection. `test/FAOOfficialProposalOrchestrator.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_setAdapter_isOneShotWhenMainnetMode`, `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAORenewableAdminTest`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, worker evidence added passing F2 sale-buy, F3 ragequit, and F6 proposal wallet paths; deployment operations also recorded a real stack-deployer source-vs-deploy drift after `ADAPTER_REPLACEABLE`. `audit/loops/worker-synpress.log@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path now passes`, `audit/loops/worker-synpress.log@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path now passes`, `audit/loops/worker-synpress.log@216b40e5766ac222e2b6e33d92c0a358ad2500c4::F6-create-proposal happy path now passes`, `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::real source-vs-deploy drift`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, operations gained FE-QA automation and frontend observability hooks: Lighthouse CI, screenshot capture, axe read-only scans, sale Etherscan tx-status links, wallet-session idle clearing, and a minimalism audit for type/shadow/gradient/color inventory. `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Run Lighthouse`, `.github/workflows/screenshots.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Capture screenshots`, `tests-e2e/journeys/a11y.read-only.spec.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::zero critical + zero serious`, `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_IDLE_MS`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#gradient-inventory`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, operations gained result artifacts: the combined wallet regression passed all four wallet happy paths, axe JSON outputs record zero violations, and the screenshot manifest records 12 PNG captures plus hashes. `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::4 passed in 2.5m`, `audit/axe/docs.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::sha`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, operations gained three more evidence channels: the dashboard deploy tree now receives HTML/JS/CSS plus `summary.json`, visual snapshots run as their own CI job, and worker axe state is represented by an explicit heartbeat instead of inferred from evaluation rows. `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Dashboard assets`, `site-ops/fao/summary.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`, `.github/workflows/e2e.yml@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::visual-snapshots`, `audit/loops/worker-axe.log@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::heartbeat`

Since source HEAD `b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b`, operations added Pages freshness checks around Lighthouse, an INP measurement script, a summary writer that merges Lighthouse/INP results, and newer dashboard summary inputs from Topic 1/3 evaluator rows. `.github/workflows/lighthouse.yml@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::Wait for deployed Pages assets`, `scripts/check-pages-freshness.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::assets`, `scripts/check-inp.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::PerformanceObserver`, `scripts/lighthouse-summary.mjs@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::writeJson`, `site-ops/fao/summary.json@HEAD::latestRound`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, operations gained a passing local Web Vitals artifact and a coupling assertion that tolerates live-site address rendering choices without weakening href/title address checks. `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `tests-e2e/coupling.read-only.spec.ts@eba3449c9feab3e7154220f68de80ae5501d6dab::expectAddressLink`

Since source HEAD `eba3449c9feab3e7154220f68de80ae5501d6dab`, operations added committed domain routing evidence for `futarchy.ai`, `testnet.fao.futarchy.ai`, `ops.futarchy.ai`, and later `polsia.futarchy.ai`; this is repository-recorded intent, not a live DNS probe. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Active mappings`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::DNS records`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`

The latest operator-visible fork work is split by provenance: committed `3760363` narrows the fork Playwright project, adds Anvil start/stop/reset support, and lets browser scripts use the local fork RPC through `shared.js`; dirty overlays still make F1 use Synpress/MetaMask helpers with JSON-RPC routing to the fork and make the fork CI job start a local static site, pin Sepolia block `10899720`, and upload `/tmp/fao-site-fork.log` on failure. `playwright.config.ts@37603636e5194b202ad5438ce80bf9909aad42c8::name: 'fork'`, `tests-e2e/journeys/fork-state.read-only.spec.ts@37603636e5194b202ad5438ce80bf9909aad42c8::resetAnvilFork`, `scripts/anvil-fork.sh@37603636e5194b202ad5438ce80bf9909aad42c8::ANVIL_FORK_BLOCK_NUMBER`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoRpcUrl`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::routeJsonRpcToFork`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`, `.github/workflows/e2e.yml@HEAD::ANVIL_FORK_BLOCK_NUMBER`, `.github/workflows/e2e.yml@HEAD::fao-site-log-fork`

## Live Ops Portal

The Cloudflare Pages project is `fao-ops`, the build command is none, the build output directory is `site-ops`, and the custom domain is `ops.futarchy.ai`. `site-ops/README.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#cloudflare-pages`

The public portal was reachable during this refresh at `https://ops.futarchy.ai/`; it links the FAO audit dashboard, the FAO testnet site, and the GitHub repo. `https://ops.futarchy.ai/`

The dashboard was reachable at `https://ops.futarchy.ai/fao/`; it identifies itself as the FAO audit dashboard and reads `audit/evaluations/topic-{1..6}-evals.jsonl`-derived data. `https://ops.futarchy.ai/fao/`, `site-ops/README.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#data-flow`

`scripts/sync-ops-dashboard.sh` copies canonical audit JSONL into `site-ops/fao/evaluations/`, and `scripts/check-ops-sync.sh` fails when the copy drifts. `scripts/sync-ops-dashboard.sh@f04b27554031b3c291ef2acb6e9bf11c852c6288::topic in 1 2 3 4 5 6`, `scripts/check-ops-sync.sh@f04b27554031b3c291ef2acb6e9bf11c852c6288::ops dashboard JSONL sync OK`

## Operator Runbook

The runbook names two long-running surfaces plus one scheduled deployment-sync job: `auto_promote.sh`, Phase-5 agent scripts, and `scripts/check-deployments-sync.sh`. `audit/state/RUNBOOK.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#daemons--crons`

The runbook now includes a mainnet migration playbook for `script/MigrateToMultisig.s.sol`: grant multisig first, then renounce deployer role, and do not pretend immutable-admin or Ownable surfaces are covered by that AccessControl script. `audit/state/RUNBOOK.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::Mainnet migration`

Alerts remain operator-eyes-only, with no Slack or PagerDuty wiring yet. `audit/state/RUNBOOK.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#alerts-operator-eyes-only--no-slackpagerduty-wiring-yet`

## Worker-Lift Evidence

Synpress F1 is now wired as an executable wallet-project path: it builds/uses a wallet cache, connects through MetaMask via Synpress, routes JSON-RPC requests to the local fork, submits the create form, confirms the wallet transaction, and checks the registry state. `tests-e2e/wallet.setup.ts@aba4046dec32448a09daa308d8fea8cb661671be::ensureWalletCache`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::metamask.confirmTransaction`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::registry.instancesCount() should increment after F1 create`

Arbitration operations now have stateful invariants for bond-treasury conservation, strict NO-bond matching, and safety-mode threshold gating. `test/FutarchyArbitration.invariants.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::invariant_INV_ARB_003_bondTreasuryConserved`, `test/FutarchyArbitration.invariants.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::invariant_INV_ARB_004_strictNoBondMatching`, `test/FutarchyArbitration.invariants.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::invariant_INV_ARB_006_safetyModeThresholdGating`

Orchestrator operations now have stateful invariants for atomic rollback and pre-initialized-pool refusal. `test/FAOOfficialProposalOrchestrator.invariants.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::invariant_INV_ORCH_001_atomicRollbackEnvelope`, `test/FAOOfficialProposalOrchestrator.invariants.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::invariant_INV_ORCH_002_refusesPreInitializedPool`

Wallet operations now have happy-path evidence for creating an instance, buying through the sale, ragequitting, and creating a proposal, plus a combined targeted regression that ran those four paths together. `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`, `audit/loops/worker-synpress.log@43074d02be5fb427aed16560aeec0f1f8914d5e5::F2-buy-via-sale happy path now passes`, `audit/loops/worker-synpress.log@d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b::F3-ragequit happy path now passes`, `audit/loops/worker-synpress.log@89486c060069f6ee2e61ff75cfb47d5a3314ad56::Founder creates|F2-buy-via-sale happy path|F3-ragequit happy path|F6-create-proposal happy path`

FE-QA operations now have committed output evidence: a11y scans emit `audit/axe/<label>.json` with empty violation arrays, Lighthouse stores report copies and a `web-vitals.json` aggregate in `audit/lighthouse`, screenshot capture committed refreshed PNGs plus `audit/screenshots/manifest.json`, and visual snapshots gate masked public-page baselines. `audit/axe/home.json@HEAD::"minor": 0`, `.github/workflows/lighthouse.yml@6283126ee2e83ddc47966eaea01e40f8f52143ee::Upload Lighthouse reports`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::sale-desktop.png`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::mask`

## Timelock Posture

`FAOTimelock` is a mainnet-posture wrapper around `TimelockController`, not an active testnet deployment. It sets a one-day mainnet delay, one-hour staging delay, open executor role, and multisig proposer/canceller/admin roles. `src/FAOTimelock.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::FAOTimelock`, `test/FAOTimelock.t.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::test_constructor_usesMainnetDelayAndMultisigRoles`

The security spec says the timelock address should enter a future `deployments.json::active.timelock` only after the Safe/multisig address is chosen. `audit/specs/SECURITY.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::Step C`

The same security spec now includes Step E, where `scripts/check-etherscan-verified.sh` and the static-analysis `etherscan-verified` job enforce active-contract Etherscan source status and `verification_todo` freshness. `audit/specs/SECURITY.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Step E`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::etherscan-verified`

Step A now has a concrete deploy-time operator switch: current Sepolia deployment scripts default `ADAPTER_REPLACEABLE` to `1`, while mainnet deployments must set it to `0` so `setAdapter` becomes one-shot. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step A`

Step D now has `FAORenewableAdmin` as an executable sketch for future admin surfaces, but existing immutable-admin v5 contracts are not retrofitted by it. `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::renounceIfStale`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step D`

## How This Might Be Wrong

- The live URL checks prove availability at refresh time, not future uptime. `https://ops.futarchy.ai/fao/`
- The user requested `21f29adc8dd1ac6a0e3f4b5d5ae231022316a309` in an earlier refresh, but this page now includes later `f04b275` invariant evidence and `aba4046` F1 evidence explicitly. `audit/specs/INVARIANTS.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::INV-ORCH-002`, `audit/loops/worker-synpress.log@aba4046dec32448a09daa308d8fea8cb661671be::F1 is now executable end-to-end`
- If a real alert route lands, the operator-eyes-only statement should be replaced with the alert destination and escalation rule. `audit/state/RUNBOOK.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#alerts-operator-eyes-only--no-slackpagerduty-wiring-yet`
- If `FAOTimelock` is deployed, this page should cite the manifest entry and deployment transaction rather than the sketch contract alone. `src/FAOTimelock.sol@f04b27554031b3c291ef2acb6e9bf11c852c6288::deployments.json::active.timelock`
- If the Etherscan gate starts passing for every active address, this page should cite verified output instead of the current remediation queue. `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`
- If F1 changes provider mode again, this page should replace the current Synpress/MetaMask boundary with the new wallet-confirmation evidence. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`
- If the operator runbook adds the `ADAPTER_REPLACEABLE=0` mainnet step, this page should cite `RUNBOOK.md` instead of only the security spec and deploy script. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If the active stack deployer is redeployed from current source, this page should remove the known-red coupling drift from the ops warning set. `audit/state/COUPLING-NOTES.md@6173bab17ba15bff91c173f04796ee0c980e3b9e::redeploy the active registry/deployer set`
- If FE-QA artifacts are regenerated or removed, ops should stop citing the current `audit/axe`, `audit/lighthouse`, and screenshot outputs. `audit/axe/home.json@HEAD::timestamp`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::generatedAt`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::generatedAt`
- If the minimalism audit becomes stale relative to CSS, this page should cite `styles.css` and `tokens.css` directly again. `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::Scope`
- If the ops dashboard stops treating full evaluator rows as the only canonical trend input, this page should cite the changed dashboard and sync filters before claiming operator trends are comparable. `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::isCanonicalRow`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::is_canonical`
- If the worker axe heartbeat is replaced by evaluator JSONL again, operations should cite the new row rather than `worker-axe.log`. `audit/loops/worker-axe.log@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::no worker-owned JSONL rows`
- If the current fork-CI and F1 worktree overlays are committed, replace the `@HEAD` citations with the resulting commit SHA before treating them as durable operations provenance. `.github/workflows/e2e.yml@HEAD::ANVIL_FORK_BLOCK_NUMBER`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`

## See Also

- [Deployment](../10-fao-repo/deployment.md)
- [Security](security.md)
- [Supply Chain](supply-chain.md)
- [E2E Journey Map](../40-verification/e2e-journey-map.md)
- [Domain Architecture](../50-operations/domain-architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 37603636e5194b202ad5438ce80bf9909aad42c8
  - fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd
  - f04b27554031b3c291ef2acb6e9bf11c852c6288
  - 21f29adc8dd1ac6a0e3f4b5d5ae231022316a309
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - aba4046dec32448a09daa308d8fea8cb661671be
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
  - 6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00
  - c17ef8b51560710c4fca17d9fb667e5e0f816e7f
  - 43074d02be5fb427aed16560aeec0f1f8914d5e5
  - d1ecb53cf2b761a72af597ec7a9ca5fb691bfb0b
  - 216b40e5766ac222e2b6e33d92c0a358ad2500c4
  - 6173bab17ba15bff91c173f04796ee0c980e3b9e
  - 6766184f046ed7205c8d7d3d3a538229667737c6
  - 6283126ee2e83ddc47966eaea01e40f8f52143ee
  - 3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d
  - 9fd41ee02a1834112f1ff580e9e262bdecd1468b
  - 89486c060069f6ee2e61ff75cfb47d5a3314ad56
  - 5e7c0f139380b0b2296d7055b28188feae56ca4e
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - 41e4b529c818dbd56fb35b66a4db45b7081fe0a4
  - cd5e73e73b21c0ac73bf80e8cac4c9dc31edfab0
  - fe9abbe3331b70b1600f4a4d28ee39a6bd539fed
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
