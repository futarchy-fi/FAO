---
name: worker-coupling
description: CAO worker that lifts T5.D1 (architectural coupling) by generating TypeScript ABI bindings + schema validation for deployments.json + a coupling-test suite asserting SC ↔ UI ↔ artifact alignment.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Architectural coupling lift

## Mission

Lift T5.D1 (architectural coupling discipline, score 3.0) above 6.0 by introducing code-level evidence — not just docs — that the SC, UI, and deploy artefact stay in sync.

## Three concrete deliverables

### 1. `deployments.schema.json` validator + JSON Schema

- Create or extend `deployments.schema.json` to define the shape of `deployments.json` (`shared`, `active`, `deprecated`, `etherscan_verified`, `verification_todo`, `notes`).
- Add `scripts/validate-deployments.sh` that runs the schema against `deployments.json` using `ajv-cli` (or pure JSON-Schema-via-bash).
- Wire it into `.github/workflows/static-analysis.yml` alongside the existing `check-deployments-sync.sh`.

### 2. TypeScript ABI bindings (for the site)

- Generate `site-testnet/abis/` directory with one `.json` per contract: `FutarchyRegistry.json`, `InstanceSale.json`, `GenericFutarchyToken.json`, etc.
- Source: `forge inspect <Contract> abi --json` into each file.
- Update `site-testnet/shared.js` to load `abis/FutarchyRegistry.json` instead of hardcoding `REGISTRY_ABI` literal.
- Add `scripts/sync-abis.sh` that regenerates the abis from forge output. CI fails if the on-disk JSON differs from the build output.

### 3. Coupling assertion test

- New test: `test/Coupling.t.sol`. For each address in `deployments.json::active`, assert that:
  - The address contains bytecode (`address.code.length > 0`) — verify via fork.
  - The bytecode matches what `forge build` would produce locally (use `cast code` + `keccak256` comparison).
- New Playwright spec: `tests-e2e/coupling.read-only.spec.ts`. Asserts that the `?inst=N` URL on the live site shows the same `token`, `sale`, `arbitration` addresses as `deployments.json` for that instance.

## Constraints

- The schema + validator + ABIs become part of the canonical deploy story — update `audit/state/DEPRECATIONS.md` if you reduce / supersede any pattern.
- Run all unit tests after each change.
- Document the new coupling chain in `audit/wiki/10-fao-repo/deployment.md` (or create if missing).

## Discipline

- If forge can't produce a deterministic bytecode (CREATE2 vs CREATE, libraries with non-pinned addresses), STOP and document why in `audit/state/COUPLING-NOTES.md` — don't fake the assertion.
- Commit incrementally: schema first, then ABIs, then coupling tests.

## Scoring impact

Each deliverable lifts T5.D1 by ~+1.5. Expected end state: T5.D1 = 6.5-7.5.
The schema validator + ABI bindings also lift T5.D5 (maintainability) by ~+1 each.
The bytecode-on-chain coupling test lifts T5.D2 (security posture) by ~+0.5.
