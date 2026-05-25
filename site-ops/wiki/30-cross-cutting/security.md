---
canonical: audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Mainnet migration executable checklist
scope: Authoritative wiki summary of FAO v0 security posture, adapter-lock mode, renewable-admin sketch, executable multisig migration, timelock sketch, Etherscan gate, and remaining testnet custody risk.
not-scope: Attack-vector enumeration lives in [Threat Model](threat-model.md); deployment and dashboard freshness lives in [Deployment](deployment.md).
last-rebuilt: 2026-05-22T17:29:12Z
---
# Security

The security posture remains testnet-first, but it now has executable migration and verification scaffolding instead of only prose. It matters because a single EOA still controls live testnet privileged surfaces, while mainnet hardening now has a constructor-level adapter lock, a concrete AccessControl migration script, a TimelockController wrapper, a renewable-admin sketch, and an Etherscan verification CI gate to review. The canonical mechanism is: current v0 uses one operator key; Step A sets `ADAPTER_REPLACEABLE=0` for mainnet; Step B migrates AccessControl `DEFAULT_ADMIN_ROLE` targets to a multisig; Step C queues privileged writes through `FAOTimelock`; Step D sketches stale-admin revocation; Step E blocks active unverified contracts unless `verification_todo` records the remediation queue. `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::#1-current-state-testnet-v0`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step A`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step B`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step C`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step D`, `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::Step E`

## Changed Since Last Refresh

The previous security wiki page was pinned to an older spec and described multisig and timelock as planned only. `audit/wiki/30-cross-cutting/security.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#mainnet-migration-plan`

HEAD adds `src/FAOTimelock.sol`, extends `test/FAOTimelock.t.sol` with delayed ownership-transfer coverage, and adds `script/MigrateToMultisig.s.sol` plus `test/MigrateToMultisig.t.sol`. `src/FAOTimelock.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::FAOTimelock`, `test/FAOTimelock.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::test_transferOwnershipRequiresQueuedDelayToPass`, `script/MigrateToMultisig.s.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::MigrateToMultisig`, `test/MigrateToMultisig.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::test_run_dryRunMigratesDefaultAdminForEveryTarget`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, `fb9a1a5` added `scripts/check-etherscan-verified.sh`, wired an `etherscan-verified` static-analysis job, and expanded `SECURITY.md` Step E. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::T5.D2 / Step E`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Etherscan verification gate`, `audit/specs/SECURITY.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Step E`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, `03a1fec` made the security checklist executable in two more places: `FAOOfficialProposalOrchestrator` now has an `ADAPTER_REPLACEABLE` constructor mode, and `FAORenewableAdmin` sketches public stale-admin revocation after a grace period. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::AdapterAlreadySet`, `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::renounceIfStale`

The same commit added executable checks for both branches: `test_setAdapter_isOneShotWhenMainnetMode` covers the mainnet one-shot adapter path, and `FAORenewableAdmin.t.sol` covers fresh-admin rejection, public stale revocation, and renewal extending the deadline. `test/FAOOfficialProposalOrchestrator.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_setAdapter_isOneShotWhenMainnetMode`, `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_renounceIfStaleRejectsFreshAdmin`, `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_adminRenewalExtendsGraceDeadline`

## Current Testnet Custody

The security spec still says the active v5 Sepolia stack uses one EOA operator for registry-created instance admin, `auto_promote.sh`, and deployer roles. `audit/specs/SECURITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::1.1 Admin-key model`

That single-key posture is intentional for testnet velocity, not a mainnet posture. `audit/specs/SECURITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::single point of failure`

The adapter hot-swap exception is now explicit mode selection: `setAdapter` remains replaceable only when `ADAPTER_REPLACEABLE` is true, and mainnet deployments must pass `ADAPTER_REPLACEABLE=0` so a second adapter write reverts with `AdapterAlreadySet`. `audit/specs/SECURITY.md@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::1.3 Replaceable adapter`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::setAdapter`, `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`

## Executable Mainnet Checklist

Step A is no longer only a prose TODO: the deploy script reads `ADAPTER_REPLACEABLE` with a default of `1` for Sepolia ergonomics, `FutarchyStackDeployer` stores that flag, and the orchestrator constructor receives it. Mainnet operators must override that default to `0`. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::vm.envOr("ADAPTER_REPLACEABLE"`, `src/FutarchyRegistryDeployers.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `src/FutarchyRegistryDeployers.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::constructor(bool adapterReplaceable)`

Step D is executable as a sketch, not retrofitted into current v5 contracts: `FAORenewableAdmin` tracks `defaultAdminRenewedAt`, lets a default admin call `renewDefaultAdmin()`, and lets any caller revoke a stale default admin through `renounceIfStale(account)`. `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::defaultAdminRenewedAt`, `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::renewDefaultAdmin`, `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::renounceIfStale`

## Multisig Migration

`MigrateToMultisig` reads `PRIVATE_KEY`, `MULTISIG`, and `PER_INSTANCE_ACCESS_CONTROL_CONTRACTS`; for each target it checks deployer admin, grants the multisig, verifies the grant, renounces deployer admin, and verifies the deployer lost admin. `script/MigrateToMultisig.s.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::run`, `script/MigrateToMultisig.s.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::_migrate`

The migration script explicitly does not cover immutable-admin or Ownable surfaces in the current v5 stack; those remain Step B work for a later registry or constructor revision. `script/MigrateToMultisig.s.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::TODO step B`, `audit/specs/SECURITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Step B`

The runbook requires a fork dry-run before broadcast and tells operators to review the trace for grant-before-renounce ordering. `audit/state/RUNBOOK.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Mainnet migration`

## Timelock Sketch

`FAOTimelock` is a wrapper around OpenZeppelin `TimelockController` with `MIN_DELAY_MAINNET = 1 days`, `MIN_DELAY_STAGING = 1 hours`, one multisig proposer/canceller/admin, and open executor role. `src/FAOTimelock.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::MIN_DELAY_MAINNET`, `src/FAOTimelock.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::_openExecutors`

The tests cover constructor roles, zero-multisig rejection, below-min-delay rejection, delayed execution, and queued Ownable2Step ownership transfer. `test/FAOTimelock.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::test_constructor_usesMainnetDelayAndMultisigRoles`, `test/FAOTimelock.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::test_scheduleRejectsDelayBelowMainnetMinimum`, `test/FAOTimelock.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::test_transferOwnershipRequiresQueuedDelayToPass`

The security spec says the deployed timelock address belongs in a future `deployments.json::active.timelock` entry only after Step B chooses the Safe or multisig address. `audit/specs/SECURITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Step C`

## Etherscan Verification Gate

`scripts/check-etherscan-verified.sh` reads `deployments.json::active`, recursively collects active addresses, skips known operator EOA paths, and requires `ETHERSCAN_API_KEY` or `ETHERSCAN_TOKEN`. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::collectActiveAddresses`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::isKnownEoaPath`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_API_KEY`

The gate treats an Etherscan response as verified only when `SourceCode` and `ContractName` are non-empty and the ABI is not `Contract source code not verified`. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::sourceVerificationStatus`

`verification_todo` is enforced both ways: unverified active contracts must have a todo entry, verified active contracts must not remain in the todo queue, and any todo that still references an active address keeps the gate red. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::missingTodos`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::staleTodos`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::activeTodos`

The static-analysis job installs `etherscan-api@10.3.0` with scripts disabled, passes `secrets.ETHERSCAN_API_KEY`, and runs the gate as a separate `etherscan-verified` job. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Install etherscan-api`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Assert active contracts are verified`

## Residual Risk

The testnet still has no global pause, no emergency exit for non-listed ERC20s, unverified v5 contracts, and operator-key exposure through shell environment usage; the unverified v5 contracts are now an explicit `verification_todo` queue rather than an undocumented gap. `audit/specs/SECURITY.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#5-known-limitations-residual-risk`, `deployments.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::verification_todo`

Mainnet security is therefore a migration path, not a completed state: AccessControl targets have a migration script, but immutable-admin and Ownable surfaces still need constructor or ownership-flow changes. `audit/specs/SECURITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Step B`

## How This Might Be Wrong

- If a Safe address is selected and `deployments.json::active.timelock` lands, this page should cite the manifest and deployment transaction rather than only the sketch. `src/FAOTimelock.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::deployments.json::active.timelock`
- If immutable-admin contracts gain rotation paths, the Step B limitation should be replaced with implemented code citations. `script/MigrateToMultisig.s.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::TODO step B`
- If deploy scripts change the `ADAPTER_REPLACEABLE` default, this page's Sepolia/mainnet mode distinction must be rebuilt from scripts and tests together. `script/DeployFutarchyRegistry.s.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If the next registry/admin surface actually inherits `FAORenewableAdmin`, this page should move Step D from sketch to active admin control. `src/FAORenewableAdmin.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::TODO step D`
- If `MIN_DELAY_MAINNET` changes, both the security spec and timelock tests must be rebuilt together. `src/FAOTimelock.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::MIN_DELAY_MAINNET`
- If v5 verification gates begin passing for every active contract, the residual-risk list should move verification from TODO to evidence. `audit/specs/SECURITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::2.1 Etherscan-verified contracts`
- If Etherscan changes `getsourcecode` response shape, the gate logic and this page's pass/fail summary must rebuild together. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::fetchSourceCode`

## See Also

- [Deployment](deployment.md)
- [Ops](ops.md)
- [Threat Model](threat-model.md)
- [Decidability](../40-verification/decidability.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd
  - b68c06af35a8d5b8f96234dd4028f23c88c5435d
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
  - f04b27554031b3c291ef2acb6e9bf11c852c6288
- Build pass: 12 (continuous HEAD refresh)
