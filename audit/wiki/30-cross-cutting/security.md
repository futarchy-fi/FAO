---
canonical: audit/specs/SECURITY.md@768d2ab2bdaee37c156955b0fd08732e166ae94d
scope: Authoritative wiki summary of FAO v0 security posture, admin-key model, upgradability, verification, migration, and incident response.
not-scope: Attack-vector enumeration lives in [Threat Model](threat-model.md); correctness invariants live in [Invariants](../10-fao-repo/invariants.md).
last-rebuilt: 2026-05-22T14:31:28Z
---
# Security

The authored security spec defines the security posture for FAO v0 and its path toward a mainnet-grade posture. It matters because contract immutability does not remove operational risk: admin keys, adapter replacement, verification, incident response, and key rotation are separate security surfaces. The canonical mechanism is a testnet single-EOA model with immutable contracts, a replaceable adapter exception, an explicit mainnet multisig/timelock plan, and a documented incident-response runbook. `audit/specs/SECURITY.md:8-10`, `audit/specs/SECURITY.md:12-51`, `audit/specs/SECURITY.md:83-119`, `audit/specs/SECURITY.md:121-163`

## Current Testnet Posture

The current v0 testnet posture uses a single EOA operator, `0x693E3FB46Bb36eE43C702FE94f9463df0691b43d`, as privileged holder across active v5 stack roles. `audit/specs/SECURITY.md:14-23`

That same key is described as the registry-deployed instance creator, the operator for `auto_promote.sh`, and the deployer for registry, deployers, adapter, and seeders. `audit/specs/SECURITY.md:16-21`

The spec states this single key is an intentional testnet single point of failure and that mainnet should move every admin role to multisig plus timelock. `audit/specs/SECURITY.md:22-23`

## Immutability And Adapter Exception

The spec says all active contracts are immutable: there are no proxy, UUPS, or Diamond upgrade paths, and upgrades happen by redeploying and routing traffic to new contracts. `audit/specs/SECURITY.md:24-29`

The exception is `FAOOfficialProposalOrchestrator.setAdapter(...)`, which is admin-replaceable for testnet hot-swapping and must regain a one-shot guard before mainnet. `audit/specs/SECURITY.md:30-35`

The permissions table records which components have no admin, creator-held admin, one-shot resolver wiring, or orchestrator-only adapter access. `audit/specs/SECURITY.md:36-51`

## Verification And Source-Of-Truth Drift

As of the authored security spec, some `InstanceSale`, `GenericFutarchyToken`, and bootstrap `FAOSale` contracts are Etherscan-verified, while the v5 registry, deployers, and per-instance contracts are still TODO. `audit/specs/SECURITY.md:52-72`

The spec names three live-address sources that must agree: `site-testnet/shared.js:23`, the wiki deployment history, and on-chain `FutarchyRegistry` storage. `audit/specs/SECURITY.md:73-82`

The planned fix for address drift is to generate a `deployments.json` artifact in CI and have the site read that instead of hardcoded constants. `audit/specs/SECURITY.md:75-82`

## Mainnet Migration Plan

The mainnet hardening path has five ordered steps: reapply one-shot `setAdapter`, add an optional per-instance multisig admin path, timelock `seedLiquidityManager`, `addRagequitToken`, and `setAdapter`, add renounce-by-default behavior after a grace period, and verify v5 contracts in CI. `audit/specs/SECURITY.md:83-119`

The multisig step preserves current testnet behavior when the new admin argument is `address(0)`, while allowing Safe-style ownership when supplied. `audit/specs/SECURITY.md:93-102`

The timelock step proposes a 48-hour default delay over privileged writes, with only a rate-limited multisig override. `audit/specs/SECURITY.md:103-107`

## Incident Response

For a Sepolia operator-key compromise, the runbook says to disable LP migration with `setAdapter(0x0)` on every active orchestrator, stop `auto_promote.sh`, rely on user-keyed ragequit for buyers, redeploy a v6 registry under a new key, and migrate the bootstrap FAO instance. `audit/specs/SECURITY.md:121-133`

The spec states testnet sale-treasury ETH remains at risk because admin can seed an attacker-controlled manager, and it marks that acceptable only for testnet because mainnet needs a timelock. `audit/specs/SECURITY.md:125-133`

For mainnet, multisig plus timelock turns admin compromise into a delayed privileged write, while a separate operator key should sign daemon transactions without holding admin roles. `audit/specs/SECURITY.md:134-138`

## Known Limitations And Rotation

The residual limitations are single key, testnet adapter swappability, unverified v5 contracts, no paused state, no broad emergency exit for non-listed ERC20s, and `PRIVATE_KEY` in the operator shell environment. `audit/specs/SECURITY.md:139-147`

The key-rotation runbook starts with a new wallet and funding, pauses `auto_promote.sh`, notes that several current contracts lack cheap `setAdmin` rotation, updates registry/site/operator/wiki references if the registry changes, drains the old key, and tests a promote-to-resolve cycle before resuming. `audit/specs/SECURITY.md:148-163`

## How This Might Be Wrong

- If multisig integration ships differently than the spec's Step B, this page should be rebuilt from the implemented admin path. `audit/specs/SECURITY.md:93-102`
- If the 48-hour timelock delay changes, the incident-response and migration sections must be updated together. `audit/specs/SECURITY.md:103-107`, `audit/specs/SECURITY.md:171-176`
- If v5 contract verification lands, the verification gap should move from TODO to completed evidence. `audit/specs/SECURITY.md:54-72`
- If contracts gain cheap admin rotation, the key-rotation runbook should stop describing redeploy as the primary path. `audit/specs/SECURITY.md:148-163`
- If operator-key handling moves out of shell env, the residual-risk list should cite the new secret-management source. `audit/specs/SECURITY.md:139-147`

## See Also

- [Threat Model](threat-model.md)
- [Invariants](../10-fao-repo/invariants.md)
- [Deployment History](../10-fao-repo/deployment-history.md)
- [Architecture](../10-fao-repo/architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 768d2ab2bdaee37c156955b0fd08732e166ae94d
- Build pass: 1 (authored spec refresh)
