---
canonical: audit/state/RUNBOOK.md
scope: Operator-surface runbook for FAO v0 — what daemons exist, how to start/stop them, how to read their logs, what's monitored, and what to do when something pages.
not-scope: Smart-contract invariants (`audit/specs/INVARIANTS.md`); security posture (`audit/specs/SECURITY.md`).
last-rebuilt: 2026-05-22
---

# FAO operator runbook

T5.D4 (operator surface readiness) requires a written, executable
runbook covering: every daemon, every cron, every script entry point,
every monitoring touchpoint, and every defined alert action. This file
is that runbook.

## Daemons + crons

The active operator surface is **two** long-running components plus
**one** scheduled job:

### 1. `script/agents/auto_promote.sh` (long-running)

- **Role:** polls the arbitration contract for proposals that have
  graduated (state == PROMOTED) and have not yet been atomically
  promoted by the orchestrator. For each, calls
  `FAOOfficialProposalOrchestrator.createOfficialProposalAndMigrate`
  with a configurable `builderTip`.
- **Inputs:** `OPERATOR_PRIVATE_KEY` env var.
- **Outputs:** `data/agent-promote.log` (append-only).
- **Start:** `nohup bash script/agents/auto_promote.sh > data/agent-promote.log 2>&1 &`
- **Stop:** `pkill -f auto_promote.sh`
- **Heartbeat:** `data/cron-heartbeats/auto_promote` (touched every poll cycle).
- **Health check:** `find data/cron-heartbeats/auto_promote -mmin -5` must return the file. If empty, the daemon has been idle for ≥ 5 minutes.

### 2. `script/agents/LegitProposer.s.sol` + `AttackBondGrief.s.sol` etc. (foundry scripts)

- **Role:** Phase-5 adversarial validation agents — only run during validation campaigns, not in steady-state operation. Documented in `script/agents/README.md`.
- **Start:** `bash script/agents/run_phase5.sh`.
- **Outputs:** `out/phase5-events.log`, `out/phase5-metrics.csv`.

### 3. Cron: `bash scripts/check-deployments-sync.sh` (every PR + push)

- Wired into `.github/workflows/static-analysis.yml`.
- Fails CI when root `deployments.json` and `site-testnet/deployments.json` diverge.

## Monitoring + alerting

### Logs

| Path | Cadence | Schema |
|---|---|---|
| `data/agent-promote.log` | per-poll | `<ISO timestamp> <event=poll|promote|skip|error> <proposalId> <detail>` |
| `out/phase5-events.log` | per-event | `<ISO timestamp> <agent> <event> <txhash>` |
| `out/phase5-metrics.csv` | per-cycle | `cycle,promotes,reverts,bonds_yes,bonds_no,bond_floor` |
| `data/cron-heartbeats/<name>` | per-poll | Empty file; mtime IS the heartbeat |

### Heartbeats

`data/cron-heartbeats/` is the single source of truth for "is daemon X alive?". One file per long-running script; the file's mtime is the latest tick. A heartbeat older than the daemon's poll interval × 2 means the daemon has stopped.

Today three heartbeat files exist (modified during the session):
- `incident_ingest`
- `session_delivery_guard`
- `usage_ingest`

These belong to the **wider workspace** (claws/farol), not directly to FAO. The FAO-specific daemon is `auto_promote.sh`; its heartbeat would land in the same directory under the name `auto_promote` once the daemon is restarted post-merge.

### Alerts (operator-eyes only — no Slack/PagerDuty wiring yet)

- **No heartbeat for ≥ 10 min:** restart the daemon. Investigate root cause via the latest log lines.
- **Slither finding High/Medium in static-analysis CI:** investigate before merging.
- **Deployments sync drift:** `bash scripts/check-deployments-sync.sh` from a clean checkout reproduces the diff.
- **TWAP resolver `tryResolve` repeatedly reverting:** inspect the resolver's bound proposals; likely a TWAP-window setup error.

## Top-of-mind operator playbooks

### Restart `auto_promote.sh`

```bash
pkill -f auto_promote.sh || true
nohup bash script/agents/auto_promote.sh > data/agent-promote.log 2>&1 &
echo "PID: $!"
# Verify heartbeat starts updating
ls -la data/cron-heartbeats/auto_promote 2>/dev/null
```

### Deploy a new contract version

1. Author the change. Update INVARIANTS.md / preconditions/ if invariants shift.
2. `forge build && forge test` locally (all 250+ tests).
3. Update `deployments.json` with the new address(es) and **bump version**.
4. `bash scripts/check-deployments-sync.sh` — this updates `site-testnet/deployments.json`.
5. Commit both. Push to a branch.
6. Open PR. CI runs static-analysis (Slither + deployments-sync), unit tests (CI profile), invariant suite, symbolic check (Halmos workflow).
7. After merge, restart `auto_promote.sh`.
8. Append a row to `audit/wiki/10-fao-repo/deployment-history.md`.

### Reset a stuck proposal

If a proposal is in a transition state but no daemon picked it up:

```bash
# Read the on-chain state for the proposalId
cast call $ARBITRATION_ADDR "proposals(uint256)" $PROPOSAL_ID --rpc-url $RPC

# If state == YES and TIMEOUT elapsed, anyone can call finalizeByTimeout
cast send $ARBITRATION_ADDR "finalizeByTimeout(uint256)" $PROPOSAL_ID \
  --private-key $OPERATOR_PRIVATE_KEY --rpc-url $RPC
```

### Drain `withdrawable[]` for a refunded bonder

```bash
# As the bonder:
cast send $ARBITRATION_ADDR "withdraw()" \
  --private-key $REFUNDED_PRIVATE_KEY --rpc-url $RPC
```

### Reset the testnet

The user has said the testnet is deprecatable. To wipe state:

1. The on-chain registry stays — its instances are immutable.
2. The site can be reset to "empty" by re-deploying a new registry. The site reads `deployments.json::active.registry`; updating the JSON moves the UI to the new registry.
3. `out/phase5-*` and `data/cron-heartbeats/*` are operator artefacts; safe to delete.

## Failure modes for the operator (read before paging)

| Symptom | Most likely cause | First-pass action |
|---|---|---|
| Site shows "no instances" but on-chain has them | RPC down / fetch blocked | `curl https://ethereum-sepolia.publicnode.com` — if non-200, rotate RPC. |
| Buy succeeds but UI shows no balance update | `fao:walletChanged` event not fired | Hard-reload (Cmd-Shift-R). Then file a UI bug. |
| Atomic promote fails with "SpotPoolAlreadyExists" | Some user pre-created a UniV3 pool. | Use a different proposal id (re-deploy via the orchestrator's idempotent path; the orchestrator refuses pre-init pools by design — INV-ORCH-002). |
| `auto_promote.sh` logs `out of gas` | Builder TIP set too high or gas spike | Lower `builderTip` env var in the daemon's start command. |
| Static-analysis CI fails | Slither found a Medium+ | Read SARIF in CI; fix the contract OR file a doc'd exception under `slither.config.json`. |

## How this might be wrong

- Heartbeat thresholds (≥10 min) are conservative for `auto_promote.sh` (typical poll is 30 seconds). A finer-grained alert would page on ≥ 2 × poll_interval.
- The "Reset the testnet" steps assume the on-chain registry is untouched. If you redeploy the registry, every UI link to `?inst=<id>` in old bookmarks now points to the wrong stack.
- No Slack/PagerDuty wiring yet. Today, alerts are operator-eyes-only via tail-following `data/agent-promote.log`. T5.D4 next step is to ship a webhook.
- The `auto_promote.sh` start command assumes a tmux/nohup session; on the production operator host (long-running daemon under systemd?), the unit file would be different.
- The "Drain `withdrawable[]`" playbook assumes the bonder still controls the key. Bonders who lost their key cannot recover their bond — that's a SECURITY.md trade-off, not a runbook gap.
