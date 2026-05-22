---
name: worker-security
description: CAO worker that lifts T5.D2 (security posture) via concrete code lifts — Etherscan verification CI gate, timelock plan written into a deployable contract sketch, multisig migration runbook.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Security posture lift

## Mission

Lift T5.D2 (security posture, score 3.2) above 6.0 by going beyond `audit/specs/SECURITY.md` prose to **executable artifacts** — CI gates, contract sketches, deploy scripts that enforce the mainnet posture.

## Three concrete deliverables

### 1. Etherscan verification CI gate

- Add `scripts/check-etherscan-verified.sh` that uses `etherscan-api` to assert every address in `deployments.json::active` is verified.
- Wire into `.github/workflows/static-analysis.yml`.
- Reads `deployments.json::verification_todo` — if non-empty AND the address is `active`, fail.

### 2. Timelock contract sketch

- New file: `src/FAOTimelock.sol`. Minimal OpenZeppelin TimelockController wrapper sized for the mainnet posture.
- Constants documented inline: `MIN_DELAY = 1 days` (mainnet target), `MIN_DELAY = 1 hours` (staging).
- Companion test: `test/FAOTimelock.t.sol` — assert delay enforcement.
- Document in `audit/specs/SECURITY.md` Step C update — the timelock contract address goes into a future `deployments.json::active.timelock`.

### 3. Multisig migration runbook (executable steps)

- New file: `script/MigrateToMultisig.s.sol` — Foundry script that, given a multisig address, calls `grantRole(DEFAULT_ADMIN_ROLE, multisig)` then `renounceRole(DEFAULT_ADMIN_ROLE, deployer)` on every per-instance contract.
- Documented in `audit/state/RUNBOOK.md` under a new "Mainnet migration" section.
- Dry-run test in `test/MigrateToMultisig.t.sol`.

## Constraints

- Don't deploy anything to mainnet. All work is local + testnet.
- The timelock sketch can be `// TODO: deploy on mainnet` — what matters is the spec is now *code*, not just prose.
- Run full unit suite after each change.

## Discipline

- If you find that one of the SECURITY.md "Step A/B/C/D/E" items isn't yet implementable (e.g. multisig address not chosen), leave a `// pragma: TODO step A` placeholder in the code with a NatSpec pointer to the SECURITY.md section. Don't invent fake constants.

## Scoring impact

Each deliverable lifts T5.D2 by ~+1.0. Expected: T5.D2 = 3.2 → 6.2+.
The migration script + timelock test also lift T4.D3 (mutation resistance) by ~+0.5.
