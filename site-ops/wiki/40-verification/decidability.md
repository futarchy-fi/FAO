---
canonical: audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#decidability-of-fao-invariants
scope: Authoritative wiki summary of the per-INV decision-engine matrix, current TESTED status, and known DECIDABILITY.md drift.
not-scope: Security migration lives in [Security](../30-cross-cutting/security.md); E2E journey coverage lives in [E2E Journey Map](e2e-journey-map.md).
last-rebuilt: 2026-05-22T17:29:12Z
---
# Decidability

The decidability spec says which engine should decide each `INV-*` within budget, but HEAD's implementation evidence is now fresher than parts of that spec. It matters because all top-15 invariants are now `TESTED` in `INVARIANTS.md`, while several rows in `DECIDABILITY.md` still call newer stateful invariants planned, open, or bounded. The canonical distinction is: `check_INV_*` remains the Halmos/SMT proof-obligation surface, while `invariant_INV_*` is the forge stateful invariant surface. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#invariant--engine-assignment`, `audit/specs/INVARIANTS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#pass-status`

## Changed Since Last Refresh

At the prior wiki refresh, `INV-ARB-005`, `INV-TWAP-001`, and `INV-TWAP-002` were not yet represented as current stateful invariant lifts. `audit/wiki/40-verification/decidability.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#per-inv-assignment`

HEAD adds `invariant_INV_ARB_005_graduationReachableAtThreshold`, `invariant_INV_TWAP_001_anchorMonotoneWindowFixed`, and `invariant_INV_TWAP_002_resolutionWriteCardinality`, then updates the invariant pass-status table so every top-15 row is `TESTED`. `test/FutarchyArbitration.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_ARB_005_graduationReachableAtThreshold`, `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_001_anchorMonotoneWindowFixed`, `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_002_resolutionWriteCardinality`, `audit/specs/INVARIANTS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::all Top-15 rows now have TESTED coverage`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, the executable security-posture commit added mainnet-mode adapter unit coverage and a renewable-admin unit suite, but it did not change the `DECIDABILITY.md` engine assignment or add a new `check_INV_*` row. `test/FAOOfficialProposalOrchestrator.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::test_setAdapter_isOneShotWhenMainnetMode`, `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAORenewableAdminTest`, `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#decision-engine-matrix`

## Engine Matrix

`DECIDABILITY.md` still defines four engines: forge fuzz/invariant, Halmos, solc SMTChecker, and Certora. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#decision-engine-matrix`

The symbolic workflow still runs SMTChecker and Halmos, and Halmos still targets `check_INV_` with `--solver-timeout-assertion 30000 --loop 3`. `.github/workflows/symbolic.yml@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Run Halmos on check_INV_* proof obligations`

## Current Status By Surface

| Surface | Current evidence |
|---|---|
| Halmos `check_INV_*` | Token, sale, arbitration, orchestrator pre-init, and TWAP anchor checks exist as `check_INV_*` functions. `test/GenericFutarchyToken.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_TOKEN_001_supplyTracksHandlerOps`, `test/FAOTwapResolver.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_TWAP_001_anchorMonotone` |
| Forge stateful invariants | All 15 top-level invariant rows have `TESTED` entries, including ARB-005 and TWAP-001/002. `audit/specs/INVARIANTS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#pass-status` |
| Known stale decidability rows | `DECIDABILITY.md` still says `INV-ARB-005` is reachability prose only and `INV-TWAP-002` is bounded/fork-test only. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::INV-ARB-005`, `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::INV-TWAP-002` |

## Bounded Surfaces

The spec still calls out two unbounded symbolic surfaces: the dynamic ragequit-token loop and `_queuedCount` over proposals. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#bounded-surfaces`

That warning remains valid even though stateful invariants improved, because TESTED by forge invariant is not the same as PROVED by a symbolic engine. `audit/specs/INVARIANTS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::PROVED column is a v0.1 goal`

## How This Might Be Wrong

- This page intentionally treats `INVARIANTS.md` and tests as fresher than `DECIDABILITY.md`; if the decidability spec is updated, rebuild the stale-row warning. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#roadmap-to-fully-decided`
- If new `check_INV_*` functions land, this page must update the Halmos surface rather than only the stateful invariant surface. `.github/workflows/symbolic.yml@b68c06af35a8d5b8f96234dd4028f23c88c5435d::halmos --match-test 'check_INV_'`
- If dynamic loops gain hard code-level caps, the bounded-surface section should cite source code instead of only `DECIDABILITY.md`. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Known unbounded surfaces`
- If Certora is wired, this page should add workflow and artifact citations. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Certora`
- If security posture checks become `INV-*` obligations, this page should add engine rows instead of treating them as unit-level evidence. `test/FAORenewableAdmin.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::FAORenewableAdminTest`

## See Also

- [Symbolic Obligations](halmos-instance-sale.md)
- [Mutation Resistance](mutation-resistance.md)
- [Security](../30-cross-cutting/security.md)
- [Deployment](../30-cross-cutting/deployment.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - b68c06af35a8d5b8f96234dd4028f23c88c5435d
  - f04b27554031b3c291ef2acb6e9bf11c852c6288
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
- Build pass: 12 (continuous HEAD refresh)
