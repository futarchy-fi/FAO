---
canonical: audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#deprecations
scope: Authoritative wiki coverage of deprecated FAO registries, scripts, generated artifacts, browser ABI patterns, deployment-manifest rules, and cleanup policy.
not-scope: Active deployment freshness lives in [Deployment](../10-fao-repo/deployment.md); operational key posture lives in [Security](security.md).
last-rebuilt: 2026-05-22T19:44:25Z
---
# Deprecations

Deprecation coverage is the repo's policy ledger for old-but-visible artifacts. It matters because v3, v4, bootstrap contracts, testnet-only hot swaps, generated files, unchecked deployment manifests, and browser ABI literals can all look active unless the wiki names what must be frozen, superseded, removed, or rejected. The canonical mechanism is the `DEPR-*` inventory: each row has a status, source, reason, rule, and cleanup expectation. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#inventory`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, this page summarized `DEPR-1` through `DEPR-8` only. `audit/wiki/30-cross-cutting/deprecations.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#operational-deprecations`

The first deprecations refresh added `DEPR-9` for unvalidated deployment manifests and `DEPR-10` for hand-maintained site registry ABI literals. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-9`, `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-10`

## Status Model

The status vocabulary separates historical evidence from dead code: `KEEP-FROZEN`, `ARCHIVE`, `SUPERSEDED`, `REMOVE-NEXT`, and `DELETED` carry different worker rules. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#status-legend`

The worker discipline asks whether a target is frozen, whether a replacement already exists, and whether a deleted artifact is being reintroduced. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#worker-discipline`

## Inventory Snapshot

| ID | Rule | Wiki reading |
|---|---|---|
| `DEPR-1` | Do not consume v3 contracts from site or daemons. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-1` | v3 remains historical because on-chain instances are user-owned, but it is not active runtime. |
| `DEPR-2` | Do not consume v4 from site or daemons. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-2` | v4 is superseded because v5 derives spot-pool price from sale price. |
| `DEPR-3` | Use `GenericFutarchyToken` and `InstanceSale` instead of bootstrap `FAOToken`/`FAOSale`. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-3` | Bootstrap contracts are archive references, not templates for new instances. |
| `DEPR-4` | Testnet `setAdapter` remains admin-replaceable; mainnet must restore one-shot guard. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-4` | Testnet flexibility is explicitly not a mainnet posture. |
| `DEPR-5` and `DEPR-6` | Deleted local generated artifacts stay deleted. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-5`, `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-6` | Large crash dumps and Wrangler cache files are not repo state. |
| `DEPR-7` and `DEPR-8` | Pre-build wiki outline and Phase-5 event/metric artifacts are frozen historical records. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-7`, `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-8` | Planning artifacts and campaign evidence are retained as read-only provenance. |
| `DEPR-9` | Unvalidated deployment manifests are superseded by schema validation plus root/site sync. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-9` | `deployments.json` changes must pass `validate-deployments.sh` and `check-deployments-sync.sh`. `scripts/validate-deployments.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::Validate deployments`, `scripts/check-deployments-sync.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::deployments.json sync OK` |
| `DEPR-10` | Hand-maintained site registry ABI literals are superseded by generated ABI JSON. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-10` | Site code should load ABI with `window.loadFaoAbi(contractName)`. `site-testnet/shared.js@3fad3cad278325c13a191c472f1be9ba5d15db02::loadAbi` |

## Worker Gate

Before editing deployment scripts, site ABI code, archived contracts, or generated artifacts, workers should read this page and the authored ledger instead of inferring freshness from filenames. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#worker-discipline`

The two new rows move deployment freshness and ABI freshness out of tribal review and into explicit CI/file boundaries. `deployments.schema.json@3fad3cad278325c13a191c472f1be9ba5d15db02::required`, `scripts/sync-abis.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::sync-abis`

## How This Might Be Wrong

- If v5 is superseded by a new registry, this page needs a `DEPR-*` row rather than an implied "latest" claim. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#inventory`
- If schema validation moves from `scripts/validate-deployments.sh` into a different tool, `DEPR-9` should cite the new executable gate. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::DEPR-9`
- If browser ABI generation stops using `forge inspect`, `DEPR-10` should cite the replacement generator and site loader together. `scripts/sync-abis.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::sync-abis`
- If a deleted generated artifact returns, the worker gate should force either deletion or a new `DEPR-*` status. `audit/state/DEPRECATIONS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#worker-discipline`

## See Also

- [Deployment](../10-fao-repo/deployment.md)
- [Deployment History](../10-fao-repo/deployment-history.md)
- [Supply Chain](supply-chain.md)
- [Runbook](../50-operations/runbook.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - 030d258e6d7909b3e724f1a7cc5cd7f4f711178c
  - 89a6f9f710320ae59adb1ac358a8bf8e687f4bf6
- Build pass: 3 (HEAD refresh)
