---
canonical: site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadDeployments
scope: Authoritative wiki coverage of the active deployment manifest flow from `deployments.json` into the testnet site.
not-scope: Historical deploy evidence lives in [Deployment History](deployment-history.md); deprecated deploys live in [Deprecations](../30-cross-cutting/deprecations.md).
last-rebuilt: 2026-05-22T15:06:52Z
---
# Deployment

Deployment state now flows through a manifest instead of a hardcoded site constant. It matters because active addresses, deprecated addresses, verification TODOs, and UI registry reads need one reviewable contract between chain state, CI, and the static site. The canonical mechanism is `shared.js::loadDeployments()`: fetch `./deployments.json`, set `REGISTRY_ADDR` from `active.registry` when present, and fall back to a kept-in-sync constant when the fetch fails. `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadDeployments`

## Changed Since R3

R3's `shared.js` held `REGISTRY_ADDR` as a direct constant: `0x18D1f4e57412b48436C7825B9018437C235bBC5C`. `site-testnet/shared.js@be0307070752d1617c00b200e9c375006edcf5d6::REGISTRY_ADDR`

HEAD keeps the same address as `FALLBACK_REGISTRY_ADDR`, but the active value is mutable at startup because `loadDeployments()` reads `deployments.json` first. `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::FALLBACK_REGISTRY_ADDR`, `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadDeployments`

R3 had no `site-testnet/deployments.json`; HEAD adds both a root manifest and site-served copy, with a CI sync check. `site-testnet/deployments.json@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::active`, `scripts/check-deployments-sync.sh@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::deployments.json sync OK`

## Manifest Contract

The manifest records `version: "v5"`, `network: "sepolia"`, `chain_id: 11155111`, shared dependency addresses, active stack addresses, deprecated addresses, verified addresses, verification TODOs, and notes. `deployments.schema.json` is the executable contract for those keys, including full-address requirements for `shared`, `active`, and `etherscan_verified`, and explicit placeholder allowance only for historical `deprecated` entries. `deployments.json@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::$schema`

The active deployment values include registry, token/arbitration deployer, futarchy stack deployer, optional proposal implementation, UniV3 liquidity adapter, and operator address. `deployments.json@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::active`

The manifest's own note says it "replaces the historical pattern of hardcoded constants in site-testnet/shared.js." `deployments.json@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::notes`

## Site Runtime Flow

`shared.js` fetches `./deployments.json` with `cache: 'no-cache'`, writes `window.faoDeployments` when the JSON has `active.registry`, and catches failures by returning `null`. `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadDeployments`

`shared.js` also exposes `window.loadFaoAbi(contractName)`, which fetches generated JSON from `site-testnet/abis/<Contract>.json`. The registry read path now uses `abis/FutarchyRegistry.json` instead of a hand-maintained `REGISTRY_ABI` literal, so the browser ABI comes from the same `forge inspect` output CI checks.

`loadInstances()` awaits `loadDeployments()` before constructing the `ethers.JsonRpcProvider` and `FutarchyRegistry` contract, so the JSON address wins before the first registry read. `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadInstances`

The read path tries `reg.allInstances()` first and falls back to `instancesCount()` plus indexed `instances(i)` reads if the bulk call fails. `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadInstances`

## Sync And CI

`site-testnet/README.md` tells operators to update the root `deployments.json`, copy it into `site-testnet/deployments.json`, and commit both files after deploying a new registry. `site-testnet/README.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#after-deploying-a-new-futarchyregistry`

`scripts/validate-deployments.sh` validates both the root manifest and the site-served copy against `deployments.schema.json`. The static-analysis workflow runs this before the byte-for-byte sync check, so malformed manifests fail before a stale-but-identical copy can ship.

The sync script diffs the root and site copy and emits `::error::deployments.json (root) and site-testnet/deployments.json diverged.` before exiting nonzero on drift. `scripts/check-deployments-sync.sh@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::deployments.json sync OK`

`scripts/sync-abis.sh` regenerates `site-testnet/abis/*.json` from `forge inspect <Contract> abi --json`. CI runs it with `--check`, which diffs freshly generated ABI JSON against the committed site bindings and fails on drift.

The static-analysis workflow runs the sync job when `deployments.json`, `deployments.schema.json`, the site copy, `site-testnet/abis/**`, either deployment check script, the ABI sync script, or the workflow itself changes. `.github/workflows/static-analysis.yml@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::deployments-sync`

## Boundary With History

This page is current-manifest architecture, not historical evidence. Deployment history still records v0, v1, v2, v3, v4, and v5 reasons and smoke-test evidence; this page records how the current site chooses which registry to read. `audit/wiki/10-fao-repo/deployment-history.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#deployment-history`, `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadDeployments`

The manifest also records deprecated addresses, but deprecation policy lives in the authored deprecation ledger, not in deployment runtime code. `deployments.json@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::deprecated`, `audit/state/DEPRECATIONS.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#inventory`

## How This Might Be Wrong

- If the schema stops matching deployment reality, CI will block manifest updates until `deployments.schema.json` is revised in the same change.
- If `forge inspect` output changes because a contract interface changes, `scripts/sync-abis.sh --check` will force the browser ABI JSON to update in the same commit.
- If the site stops copying the root manifest into `site-testnet/`, the sync model and Cloudflare static-file assumption must change. `scripts/check-deployments-sync.sh@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::deployments.json sync OK`
- If `shared.js` moves to multiple RPCs or multiple registries, this page should split runtime reads from deployment inventory. `site-testnet/shared.js@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::loadInstances`
- If active contract verification becomes enforced in CI, the deployment page should link to [Supply Chain](../30-cross-cutting/supply-chain.md) as the verification gate owner. `audit/specs/SUPPLY-CHAIN.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#etherscan-verification`

## See Also

- [Deployment History](deployment-history.md)
- [Deprecations](../30-cross-cutting/deprecations.md)
- [Supply Chain](../30-cross-cutting/supply-chain.md)
- [UI Architecture](../30-themes/ui-architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 89a6f9f710320ae59adb1ac358a8bf8e687f4bf6
  - be0307070752d1617c00b200e9c375006edcf5d6
- Build pass: 2 (R4 refresh)
