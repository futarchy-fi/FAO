---
canonical: audit/state/RUNBOOK.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#fao-operator-runbook
scope: Authoritative wiki summary of FAO operator daemons, crons, monitoring, alerts, and first-response playbooks.
not-scope: Developer local-loop commands live in [Developer Cycle](developer-cycle.md); deployment manifest mechanics live in [Deployment](../10-fao-repo/deployment.md).
last-rebuilt: 2026-05-22T19:44:25Z
---
# Runbook

The runbook is the operator-facing contract for live scripts, scheduled checks, logs, monitoring, and first actions when something breaks. It matters because FAO now has an explicit operator surface rather than only ad hoc scripts and deployment notes. The canonical mechanism is two long-running components plus one scheduled job, with logs, heartbeat files, and playbooks for restart, deploy, stuck proposals, refunds, and testnet reset. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#daemons--crons`, `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#top-of-mind-operator-playbooks`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, the wiki had no runbook page and no source-map row for `audit/state/RUNBOOK.md`. `audit/wiki/_meta/source-of-truth-map.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#cross-cutting-and-verification-pages`

The first runbook refresh added the authored runbook and static-analysis jobs for deployment sync, ops dashboard sync, Etherscan verification, and Slither. `audit/state/RUNBOOK.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::#monitoring--alerting`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::jobs`

Since source HEAD `e0cd25b942ca2d98c37aa53e21205b562f4fab68`, the Etherscan job became executable through `scripts/check-etherscan-verified.sh`, `etherscan-api@10.3.0`, and the `ETHERSCAN_API_KEY` secret. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Etherscan verification gate`, `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ETHERSCAN_API_KEY`

## Operator Surface

The runbook names `script/agents/auto_promote.sh` as the long-running daemon that polls arbitration for promoted proposals and calls `FAOOfficialProposalOrchestrator.createOfficialProposalAndMigrate`. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::1-scriptagentsauto_promotesh-long-running`

Phase-5 adversarial validation scripts are the second long-running component category, but they are campaign-only rather than steady-state operation. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::2-scriptagentslegitproposerssol--attackbondgriefssol-etc-foundry-scripts`

The scheduled job in the runbook is `scripts/check-deployments-sync.sh`, and HEAD also adds ops-dashboard sync plus Etherscan verification as CI jobs. `audit/state/RUNBOOK.md@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::3-cron-bash-scriptscheck-deployments-syncsh-every-pr--push`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ops-dashboard-sync`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::etherscan-verified`

## Monitoring And Alerts

The runbook's log table names `data/agent-promote.log`, `out/phase5-events.log`, `out/phase5-metrics.csv`, and `data/cron-heartbeats/<name>`. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#logs`

Heartbeat files are the local liveness mechanism; alerts remain operator-eyes-only with no Slack or PagerDuty wiring yet. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#heartbeats`, `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#alerts-operator-eyes-only--no-slackpagerduty-wiring-yet`

## Playbooks

The restart playbook stops and restarts `auto_promote.sh`, redirects output to `data/agent-promote.log`, and checks the heartbeat file. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Restart auto_promote.sh`

The deploy playbook requires invariant/precondition updates when behavior shifts, root and site manifest updates, deployment sync, CI, daemon restart, and a deployment-history row. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Deploy a new contract version`

The stuck-proposal and withdrawable-drain playbooks cite `finalizeByTimeout` and `withdraw()` actions, while the testnet reset playbook says the site moves by changing `deployments.json::active.registry`. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Reset a stuck proposal`, `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Drain withdrawable`, `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Reset the testnet`

## Failure Modes

The runbook's first-response table covers site/chain mismatch, buy UI stale state, pre-initialized spot pool promotion failure, `auto_promote.sh` gas failures, and static-analysis CI failures. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#failure-modes-for-the-operator-read-before-paging`

## How This Might Be Wrong

- Heartbeat thresholds are documented as conservative; if a real monitor lands, this page should cite its threshold and destination. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#how-this-might-be-wrong`
- The runbook mentions Foundry commands, but this wiki refresh did not execute forge or cast by design. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Deploy a new contract version`
- If `auto_promote.sh` becomes a systemd service, the `nohup` start/stop commands should be replaced. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Restart auto_promote.sh`
- If deploy history moves from wiki to a manifest changelog, the deploy playbook should stop requiring a wiki row. `audit/state/RUNBOOK.md@3fad3cad278325c13a191c472f1be9ba5d15db02::Deploy a new contract version`
- If Etherscan verification becomes operator-run instead of CI-run, this page should add the command and failure triage steps. `scripts/check-etherscan-verified.sh@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::Etherscan verification check failed`

## See Also

- [Developer Cycle](developer-cycle.md)
- [Ops Dashboard](ops-dashboard.md)
- [Deployment](../10-fao-repo/deployment.md)
- [Supply Chain](../30-cross-cutting/supply-chain.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - 030d258e6d7909b3e724f1a7cc5cd7f4f711178c
  - 89a6f9f710320ae59adb1ac358a8bf8e687f4bf6
- Build pass: 8 (continuous HEAD refresh)
