---
canonical: audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::#fao--top-15-invariants
scope: Authoritative wiki summary of the authored FAO invariant catalogue, its 15 stable INV-* IDs, and current test/proof status.
not-scope: Engine-specific decidability lives in [Decidability](../40-verification/decidability.md); attack-vector enumeration lives in [Threat Model](../30-cross-cutting/threat-model.md).
last-rebuilt: 2026-05-22T20:15:22Z
---
# Invariants

The authored invariant spec is the source of truth for FAO's load-bearing safety properties. It matters because reviewers can now navigate stable `INV-*` IDs across source code, Foundry invariants, Halmos checks, mutation classes, and E2E journeys. The canonical mechanism is a 15-entry catalogue where each invariant has a prose statement, machine-checkable predicate, source citation, and `STATED`/`TESTED`/`PROVED` status. `audit/specs/INVARIANTS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#fao--top-15-invariants`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, this page listed all 15 IDs but most arbitration rows were still only stated. `audit/wiki/10-fao-repo/invariants.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#arbitration-ids`

Current invariant source now marks every top-15 row `TESTED`; the `PROVED` column remains empty, so the wiki should treat Foundry invariants and concrete tests as the current safety net rather than proof artifacts. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::#pass-status`, `test/InstanceSale.invariants.t.sol@614383179532f3bdb9462b92bcbe9fb7efb76601::invariant_INV_SALE_001_effectiveSupplyFormula`, `test/FutarchyArbitration.invariants.t.sol@1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9::invariant_INV_ARB_005_graduationReachableAtThreshold`, `test/FAOTwapResolver.invariants.t.sol@f09e558c9dd44a73bccea35017affea265c29fd3::invariant_INV_TWAP_002_resolutionWriteCardinality`

The newest status lift also creates a deliberate split from [Decidability](../40-verification/decidability.md): some IDs are `TESTED` by stateful Foundry properties while the decidability matrix still labels their symbolic proof obligations `undecided-bounded` or `undecided-open`. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-SALE-002`, `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-SALE-002`, `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-ARB-003`

## Token And Sale IDs

| ID | Summary | Current status |
|---|---|---|
| `INV-TOKEN-001` | Total supply changes only through mint and burn event paths. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-TOKEN-001` | `TESTED` by sale-handler accounting and also has a decided Halmos token obligation. `test/InstanceSale.invariants.t.sol@614383179532f3bdb9462b92bcbe9fb7efb76601::invariant_INV_TOKEN_001_supplyTracksHandlerOps`, `test/GenericFutarchyToken.symbolic.t.sol@2f8f182dbfa29c3b3c29624ef6a65c1e82eac06d::check_INV_TOKEN_001_supplyTracksHandlerOps` |
| `INV-SALE-001` | `InstanceSale.effectiveSupply()` equals total token supply minus the sale contract's own balance, floored at zero. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-SALE-001` | `TESTED` by the stateful sale invariant and tagged on `effectiveSupply`. `test/InstanceSale.invariants.t.sol@614383179532f3bdb9462b92bcbe9fb7efb76601::invariant_INV_SALE_001_effectiveSupplyFormula`, `src/InstanceSale.sol@8b0446604eb93a3c1b43d6363e0e78bf97225300::effectiveSupply` |
| `INV-SALE-002` | Successful `ragequit(n)` burns `n * 1e18`, decreases supply, and pays exact pro-rata ETH plus active ragequit ERC20s. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-SALE-002` | `TESTED` by exact pro-rata and ratio invariants plus a multi-token unit test; symbolic decidability still stays bounded rather than proved. `test/InstanceSale.proRata.invariants.t.sol@53b2cf1d237d5a38e4d4bbc1aca8246bc4b6fb88::invariant_INV_SALE_002_ragequitPaysExactlyProRata`, `test/InstanceSale.proRata.invariants.t.sol@53b2cf1d237d5a38e4d4bbc1aca8246bc4b6fb88::invariant_INV_SALE_002_ratioNonIncreasing`, `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-SALE-002` |
| `INV-SALE-003` | `ragequit(n)` reverts for self-ragequit, zero effective supply, or over-claim. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-SALE-003` | `TESTED` by revert-guard unit tests and tagged on `ragequit`. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::test_ragequit_revertsOn*`, `src/InstanceSale.sol@8b0446604eb93a3c1b43d6363e0e78bf97225300::ragequit` |
| `INV-SALE-004` | `initialPhaseFinalized` is monotone and freezes `initialNetSale` at first finalization. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-SALE-004` | `TESTED` by the phase-monotonicity invariant and tagged on `_finalizeInitialPhaseIfNeeded`. `test/InstanceSale.invariants.t.sol@614383179532f3bdb9462b92bcbe9fb7efb76601::invariant_INV_SALE_004_phaseMonotone`, `src/InstanceSale.sol@8b0446604eb93a3c1b43d6363e0e78bf97225300::_finalizeInitialPhaseIfNeeded` |

## Arbitration IDs

| ID | Summary | Current status |
|---|---|---|
| `INV-ARB-001` | `nextProposalId` is monotone and auto-created IDs below it exist. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ARB-001` | `TESTED` by the stateful monotonicity invariant; Halmos also has `check_INV_ARB_001_idMonotone`. `test/FutarchyArbitration.invariants.t.sol@1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9::invariant_INV_ARB_001_nextProposalIdMonotonic`, `test/FutarchyArbitration.symbolic.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::check_INV_ARB_001_idMonotone` |
| `INV-ARB-002` | A settled proposal remains settled, stays in `SETTLED`, and keeps `accepted` immutable. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ARB-002` | `TESTED` by the stateful irreversibility invariant; Halmos also has `check_INV_ARB_002_settledMonotone`. `test/FutarchyArbitration.invariants.t.sol@1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9::invariant_INV_ARB_002_settledIrreversible`, `test/FutarchyArbitration.symbolic.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::check_INV_ARB_002_settledMonotone` |
| `INV-ARB-003` | Arbitration WETH balance equals withdrawable refunds plus all unsettled YES and NO bonds. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ARB-003` | `TESTED` by bond-treasury conservation; `DECIDABILITY.md` still treats symbolic proof as open because dynamic mappings are hard for the engine. `test/FutarchyArbitration.invariants.t.sol@1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9::invariant_INV_ARB_003_bondTreasuryConserved`, `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-ARB-003` |
| `INV-ARB-004` | `placeNoBond` sets NO bond amount exactly to the previous YES bond amount. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ARB-004` | `TESTED` by strict NO-bond matching; Halmos also has `check_INV_ARB_004_matchedBondsCorrespond`. `test/FutarchyArbitration.invariants.t.sol@1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9::invariant_INV_ARB_004_strictNoBondMatching`, `test/FutarchyArbitration.symbolic.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::check_INV_ARB_004_matchedBondsCorrespond` |
| `INV-ARB-005` | A YES bond at least `baseX * 2^queuedCount` can graduate the proposal regardless of NO state. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ARB-005` | `TESTED` by graduation-reachability checks; symbolic decidability remains open because the claim is existential. `test/FutarchyArbitration.invariants.t.sol@1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9::invariant_INV_ARB_005_graduationReachableAtThreshold`, `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-ARB-005` |
| `INV-ARB-006` | `safetyModeActive()` is equivalent to active NO-state bond amount at least `baseX`, and timeout finalization reverts for timed-out YES-state proposals while safety mode is active. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ARB-006` | `TESTED` by safety-mode threshold gating; Halmos also has `check_INV_ARB_006_safetyModeBlocksTimeout`. `test/FutarchyArbitration.invariants.t.sol@1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9::invariant_INV_ARB_006_safetyModeThresholdGating`, `test/FutarchyArbitration.symbolic.t.sol@3fad3cad278325c13a191c472f1be9ba5d15db02::check_INV_ARB_006_safetyModeBlocksTimeout` |

## Orchestrator And TWAP IDs

| ID | Summary | Current status |
|---|---|---|
| `INV-ORCH-001` | `createOfficialProposalAndMigrate` is atomic across all phases and rolls back the whole transaction on any phase failure. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ORCH-001` | `TESTED` by rollback-envelope invariants and tagged on the promoter function; SMTChecker remains bounded rather than proof-complete. `test/FAOOfficialProposalOrchestrator.invariants.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::invariant_INV_ORCH_001_atomicRollbackEnvelope`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::createOfficialProposalAndMigrate`, `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-ORCH-001` |
| `INV-ORCH-002` | A deterministic pool that already exists and has nonzero `slot0().sqrtPriceX96` makes the orchestrator revert with `PreCreated(pool)`. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-ORCH-002` | `TESTED` by pre-initialized-pool refusal and tagged on `_maybeCreatePoolAndInit`. `test/FAOOfficialProposalOrchestrator.invariants.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::invariant_INV_ORCH_002_refusesPreInitializedPool`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::_maybeCreatePoolAndInit` |
| `INV-TWAP-001` | Resolver anchor timestamp is written at most once, and resolution measures the fixed window derived from the binding. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-TWAP-001` | `TESTED` by anchor/window fixity and tagged on `bindProposal`. `test/FAOTwapResolver.invariants.t.sol@f09e558c9dd44a73bccea35017affea265c29fd3::invariant_INV_TWAP_001_anchorMonotoneWindowFixed`, `src/FAOTwapResolver.sol@8b0446604eb93a3c1b43d6363e0e78bf97225300::bindProposal` |
| `INV-TWAP-002` | `resolve(p)` flips `resolved` once, sets `accepted` in the same resolution, freezes both fields, and rejects re-resolution. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::INV-TWAP-002` | `TESTED` by resolution write-cardinality invariants and tagged on `resolve`; observation arithmetic remains bounded in the decidability matrix. `test/FAOTwapResolver.invariants.t.sol@f09e558c9dd44a73bccea35017affea265c29fd3::invariant_INV_TWAP_002_resolutionWriteCardinality`, `src/FAOTwapResolver.sol@8b0446604eb93a3c1b43d6363e0e78bf97225300::resolve`, `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-TWAP-002` |

## Traceability Contract

The spec states that every invariant has a stable ID and that once an invariant graduates to `TESTED`, implementing NatSpec must cite the ID inline. The sale, promoter, and resolver now include `@custom:spec` tags on the core functions touched by this page. `audit/specs/INVARIANTS.md@79fccc682c09c859b06b64d3c39e598ffb6f6b52::#fao--top-15-invariants`, `src/InstanceSale.sol@8b0446604eb93a3c1b43d6363e0e78bf97225300::@custom:spec INV-SALE-002`, `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::@custom:spec INV-ORCH-001`, `src/FAOTwapResolver.sol@8b0446604eb93a3c1b43d6363e0e78bf97225300::@custom:spec INV-TWAP-002`

The CI surface now runs both forge invariant tests and Halmos `check_INV_*` obligations in separate workflows, so `invariant_INV_*` and `check_INV_*` are intentionally different evidence types. `.github/workflows/forge.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::forge test (stateful invariants — 100 runs × 50 depth)`, `.github/workflows/symbolic.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::Run Halmos on check_INV_* proof obligations`

## How This Might Be Wrong

- `DECIDABILITY.md` still records symbolic proof limits for some IDs that are now statefully `TESTED`; this page intentionally separates "tested" from "proved". `audit/specs/DECIDABILITY.md@85b2cd2e8f47f90cf40e11e9a59bc5e93ae88c16::INV-ARB-003`
- If an `INV-*` ID is renamed, this page should preserve old links only if the spec adds aliases. `audit/specs/INVARIANTS.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#how-this-document-is-maintained`
- If more precondition files are added, the relevant module rows should link them rather than leaving `InstanceSale` as the only precondition companion. `audit/specs/preconditions/InstanceSale.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#preconditions-instance-sale`
- If a stated invariant becomes proved, [Decidability](../40-verification/decidability.md) and this page must be updated together. `audit/specs/DECIDABILITY.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#counterexample-citation-discipline`

## See Also

- [Decidability](../40-verification/decidability.md)
- [Symbolic Obligations](../40-verification/halmos-instance-sale.md)
- [Mutation Resistance](../40-verification/mutation-resistance.md)
- [Arbitration](lifecycle/60-arbitration.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - 030d258e6d7909b3e724f1a7cc5cd7f4f711178c
  - 89a6f9f710320ae59adb1ac358a8bf8e687f4bf6
  - 79fccc682c09c859b06b64d3c39e598ffb6f6b52
  - 614383179532f3bdb9462b92bcbe9fb7efb76601
  - 53b2cf1d237d5a38e4d4bbc1aca8246bc4b6fb88
  - 1e123c3021d1b888ae3b02d2c1ca3a2e51c3a5e9
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
  - f09e558c9dd44a73bccea35017affea265c29fd3
- Build pass: 18 (continuous HEAD refresh)
