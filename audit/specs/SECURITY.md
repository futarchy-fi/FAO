---
canonical: audit/specs/SECURITY.md
scope: Security posture for FAO v0: admin-key model, upgradability, timelock plan, multisig migration path, incident response, key-rotation runbook.
not-scope: Smart-contract correctness (see `audit/specs/INVARIANTS.md`) and attack-vector enumeration (see `audit/specs/THREAT-MODEL.md`).
last-rebuilt: 2026-05-22
---

# FAO — Security posture

This document defines the security model for FAO v0 (Sepolia testnet) and the migration path to a mainnet-grade posture. It is the canonical source for Topic 5 D2 (security posture, admin keys, immutability, timelocks).

## 1. Current state (testnet v0)

### 1.1 Admin-key model

**Single EOA operator:** `0x693E3FB46Bb36eE43C702FE94f9463df0691b43d` holds privileged roles on every contract in the active v5 stack. The same key:

- Is the **registry-deployed instance creator** (admin of every per-instance contract: `InstanceSale.ADMIN`, `ParameterizedArbitration.admin`, `GenericFutarchyToken` DEFAULT_ADMIN_ROLE, `FAOOfficialProposalOrchestrator.ADMIN`, `FAOTwapResolver.orchestrator` source).
- Is the **operator** that runs `script/agents/auto_promote.sh` to dispatch promotes.
- Is the **deployer** of the registry + deployers + adapter + seeders.

This is the **single point of failure** for the testnet. It is intentional — testnet velocity favors a single key. Mainnet target moves every admin role to a multisig + timelock.

### 1.2 Upgradability

**All contracts are immutable.** No proxy, no UUPS, no Diamond. The only "upgrade" path is to redeploy a new contract and route traffic to it.

In-flight redeployments captured in `audit/wiki/10-fao-repo/deployment-history.md` (registry v3 → v4 → v5). Each rev deprecates the previous one; older instances stay on the older registry forever.

### 1.3 Replaceable adapter (exception)

`FAOOfficialProposalOrchestrator.setAdapter(...)` is admin-replaceable (was one-shot until commit `d315e57`). This is a deliberate testnet hot-swap path for adapter bugs. **Mainnet must restore the one-shot guard** before launch.

Tracked: PR-TODO #SEC-01 (mainnet hardening) — see §5.

### 1.4 Per-instance permissions table

| Contract | Admin / privileged role | Holder | Notes |
|---|---|---|---|
| `FutarchyRegistry` (v5) | none | n/a | permissionless `createFutarchyPart1/2` |
| `TokenAndArbitrationDeployer` | none | n/a | stateless sub-factory |
| `FutarchyStackDeployer` | none | n/a | stateless sub-factory |
| `GenericFutarchyToken` (per inst) | `DEFAULT_ADMIN_ROLE`, `MINTER_ROLE` | creator (= operator on every v5 inst today) | mint gated by MINTER_ROLE; sale holds MINTER_ROLE post-Part1 |
| `InstanceSale` (per inst) | `ADMIN` | creator | `addRagequitToken`, `removeRagequitToken`, `seedLiquidityManager` |
| `ParameterizedArbitration` (per inst) | `owner` | creator | tunes baseX, maxQueue, timeout |
| `FAOOfficialProposalOrchestrator` (per inst) | `ADMIN` | creator | `setAdapter`, `createOfficialProposalAndMigrate` |
| `FAOTwapResolver` (per inst) | one-shot `setOrchestrator` | (called by registry at Part2) | immutable after Part2 |
| `FAOFutarchyFactory` (per inst) | none | n/a | permissionless `createProposal` |
| `SaleSpotSeeder` (per inst) | `ADMIN` | creator | `sweepLP`, `redeem` |
| `UniswapV3LiquidityAdapter` | `ORCHESTRATOR` | wired to per-inst orchestrator | only orchestrator can call `migrate` |

## 2. Verification surface

### 2.1 Etherscan-verified contracts

As of 2026-05-22:

| Verified | Address |
|---|---|
| `InstanceSale` (TestFuta v3 + ACME v3) | `0x4D6458Bf…d40B9`, `0x4106fB74…Bf24D` |
| `GenericFutarchyToken` (TestFuta + ACME) | `0xC64dc271…9fcC`, `0xA9c66fb4…3074` |
| `FAOSale` (bootstrap) | `0x011F6e57…5678` |

**Not yet verified (v5 stack — TODO):**

- v5 registry `0x18D1f4e5…BC5C`
- v5 `TokenAndArbitrationDeployer` `0x475a9630…132a`
- v5 `FutarchyStackDeployer` `0xc5d7e4e0…4A46`
- v5 per-instance contracts (auto-deployed by sub-factories)

Verifying v5 contracts is a Phase 6 lift (T5.D6 supply-chain risk + dovetails into T1 wallet UX — verified contracts get decoded method names in MetaMask).

### 2.2 Source-of-truth maps

Live deploy addresses are the *only* source of truth for the active stack. They live in three places that must agree:

1. `site-testnet/shared.js:23` (UI registry address — hardcoded).
2. `audit/wiki/10-fao-repo/deployment-history.md` (human-readable canonical).
3. The on-chain `FutarchyRegistry` (storage).

Drift between these three is a known T5.D5 (maintainability) gap. Phase 6 plan: generate `deployments.json` artefact in CI and have the site read from that instead of hardcoded constants.

## 3. Mainnet migration plan (incrementally lifts T5.D2)

Each step is a discrete PR; landing them in order moves T5.D2 from 2.0 toward 8.0.

### Step A — Reapply one-shot `setAdapter` guard

Reintroduce the `if (adapter != 0) revert AdapterAlreadySet();` check before mainnet. The testnet hot-swap escape is testnet-only.

**Lift:** T5.D2 +0.5.

### Step B — Per-instance multisig path

Add an optional `IMultisigLike admin` arg to `createFutarchyPart1`. When supplied:

- Roles are granted to the multisig instead of `msg.sender`.
- A reasonable default is Safe (`@safe-global/safe-contracts`).
- Existing testnet behavior preserved when arg is `address(0)`.

For existing AccessControl-admin surfaces, `script/MigrateToMultisig.s.sol` is the executable
migration path. It takes `PRIVATE_KEY`, `MULTISIG`, and
`PER_INSTANCE_ACCESS_CONTROL_CONTRACTS`, then calls `grantRole(DEFAULT_ADMIN_ROLE, multisig)`
followed by `renounceRole(DEFAULT_ADMIN_ROLE, deployer)` for each supplied target. Current
immutable-admin and Ownable per-instance contracts are not safely mutable by this script; they
remain Step B work for the next registry/constructor revision.

**Lift:** T5.D2 +1.5 (path exists; mainnet creators can opt in).

### Step C — Timelock on `seedLiquidityManager` + `addRagequitToken` + `setAdapter`

`src/FAOTimelock.sol` is the executable sketch for the mainnet controller: a thin OpenZeppelin `TimelockController` wrapper with `MIN_DELAY_MAINNET = 1 days` for mainnet and `MIN_DELAY_STAGING = 1 hours` for rehearsal deploys. The deployed timelock address goes into a future `deployments.json::active.timelock` entry once Step B chooses the Safe/multisig address.

Wrap each privileged write in a `TimelockController.schedule(...)` queue before mainnet: `seedLiquidityManager`, `addRagequitToken`, and `setAdapter`. Emergency bypass remains unresolved until the multisig policy is chosen; do not invent an override address in the deployment manifest.

**Lift:** T5.D2 +1.0.

### Step D — Renounce-by-default

After a configurable grace period post-deploy, any creator who does NOT actively renew their admin can lose `DEFAULT_ADMIN_ROLE` automatically via a public `renounceIfStale()` function. Forces hot keys to either rotate or relinquish.

**Lift:** T5.D2 +0.5.

### Step E — Etherscan verification CI gate

Verify v5 contracts on Etherscan in CI for every deploy. Already authored in commit history; just needs the workflow.

**Lift:** T5.D6 +1.0 (supply chain), T1.D2 +0.3 (decoded methods in wallet).

## 4. Incident response

### 4.1 Today (testnet)

If the operator key is compromised on Sepolia:

1. Operator immediately calls `setAdapter(0x0)` on every active orchestrator (disables LP migration).
2. Operator pauses `auto_promote.sh` (no daemon dispatches).
3. Sale buyers can still `ragequit` for ETH — that path is gated by the user's own key, not admin.
4. Operator drafts a new key, redeploys the registry as v6, and migrates the bootstrap FAO instance.

Impact: testnet ETH at risk = operator's wallet balance (~0.3 ETH at writing). Sale-treasury ETH is at risk because admin can `seedLiquidityManager` to an attacker-controlled "manager" that just drains. This is acceptable for testnet; mainnet must add a timelock.

### 4.2 Mainnet (future)

- Multisig + timelock means admin compromise gives the attacker a one-day latency window before any privileged write lands. Window is intended to be enough to detect + override once the mainnet multisig policy exists.
- A separate "operator" key signs daemon txs but holds no admin roles; rotating it doesn't require any contract change.

## 5. Known limitations (residual risk)

- **Single key:** see §1.1.
- **Adapter swappable on testnet:** see §1.3 + Step A.
- **v5 contracts not Etherscan-verified:** see §2.1 + Step E.
- **No paused state:** no `Pausable` modifier on any active sale or arbitration. A bug in `ragequit` cannot be stopped without a redeploy.
- **No emergency exit:** ragequit returns pro-rata ETH only; if treasury holds non-ragequit-listed ERC20s by mistake, they're stuck until the admin lists them.
- **Operator key in shell env:** `script/agents/auto_promote.sh` reads `$PRIVATE_KEY` from the environment. A compromise of the operator's shell history is equivalent to a key compromise.

## 6. Key-rotation runbook

When (not if) we rotate the operator key on testnet:

1. **Pre:** `cast wallet new` → record new address. Fund it from a separate transfer.
2. **Pause:** stop `auto_promote.sh` (`touch out/auto_promote.stop`).
3. **For each contract holding the old key as ADMIN:**
   - `InstanceSale`: there is no `setAdmin`. Migrate by deploying a new instance OR rebuild the registry. (Testnet behavior; mainnet will have multisig and key-rotation will be a multisig operation.)
   - `ParameterizedArbitration`: same.
   - `FAOOfficialProposalOrchestrator`: same.
4. **Update:**
   - `site-testnet/shared.js:23` if the registry changes.
   - `script/agents/auto_promote.sh` env (`PRIVATE_KEY`).
   - `audit/wiki/10-fao-repo/deployment-history.md`.
5. **Drain old key:** transfer remaining ETH to the new address.
6. **Test:** run a full promote → resolve cycle on the new key before resuming the daemon.

## See also

- `audit/specs/THREAT-MODEL.md` — what we defend against.
- `audit/specs/INVARIANTS.md` — what we promise.
- `audit/rubrics/topic-5-holistic-architecture.md` — the rubric this doc scores against (D2).

## How this might be wrong

- Step B's multisig integration is theoretical until a Safe is actually wired into the registry. Mainnet may need different ergonomics.
- Step C's one-day delay is an executable target, not an empirically validated governance parameter. The right value still depends on the off-chain governance loop, which doesn't exist yet.
- The incident-response section assumes the operator notices the compromise. There's no automated detection — that's part of Topic 5 D4 (operator surface readiness).
- The runbook for testnet rotation is currently destructive (redeploy registry). Future passes should add an `acceptAdmin` flow per contract to make rotation cheap.
