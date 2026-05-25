---
canonical: tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing
scope: Authoritative wiki summary of mutation-resistance status, stale mutation-catalog gaps, new invariant tests, and fork-state mutations that close prior classes.
not-scope: Per-engine decidability lives in [Decidability](decidability.md); security migration lives in [Security](../30-cross-cutting/security.md).
last-rebuilt: 2026-05-22T17:29:12Z
---
# Mutation Resistance

The mutation catalog is still the authored T4.D3 checklist, but HEAD's tests now close several gaps that the catalog still lists as open. It matters because mutation readiness should follow executable tests when specs lag. The canonical mechanism remains `MUTATIONS.md` for mutation classes, while current `invariant_INV_*` tests are the fresher evidence for reachability, timing, matching, and state-write bugs. `audit/specs/MUTATIONS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#mutation-classes`, `audit/specs/INVARIANTS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#pass-status`

## Changed Since Last Refresh

The previous wiki page treated `INV-ARB-005` graduation reachability as a catalog gap. `audit/wiki/40-verification/mutation-resistance.md@f04b27554031b3c291ef2acb6e9bf11c852c6288::#catalog-summary`

HEAD adds `invariant_INV_ARB_005_graduationReachableAtThreshold`, `invariant_INV_TWAP_001_anchorMonotoneWindowFixed`, and `invariant_INV_TWAP_002_resolutionWriteCardinality`; `INVARIANTS.md` now says all top-15 rows are TESTED. `test/FutarchyArbitration.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_ARB_005_graduationReachableAtThreshold`, `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_001_anchorMonotoneWindowFixed`, `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_002_resolutionWriteCardinality`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, fork-state E2E added mutation-style UI checks for a cast `placeNoBond(uint256)` and a cast `tryGraduate(uint256)`. These are not mutation-runner outputs, but they make two previously easy-to-miss state transitions executable in the browser reflection path. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposals page reflects cast-placed NO bond without wallet signing`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::proposals page reflects cast try-graduate without wallet signing`

## Catalog Baseline

`MUTATIONS.md` still lists 14 mutation classes with 7 verified-caught and 7 verified-gap rows. `audit/specs/MUTATIONS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#summary`

The catalog's "Tool wiring left" section still says a mutation workflow is missing, so this page should not claim automated mutation testing is running. `audit/specs/MUTATIONS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Tool wiring left`

## Gap Rows Now Likely Stale

The graduation-reachability gap is stale because `invariant_INV_ARB_005_graduationReachableAtThreshold` now asserts threshold YES graduation and queued threshold constraints. `audit/specs/MUTATIONS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_graduationReachable`, `test/FutarchyArbitration.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_ARB_005_graduationReachableAtThreshold`

The TWAP write-cardinality and anchor/window mutation classes are not explicitly cataloged in `MUTATIONS.md`, but HEAD now has stateful tests that would catch anchor mutation, window mutation, re-resolution, and payout-report count drift. `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_001_anchorMonotoneWindowFixed`, `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_002_resolutionWriteCardinality`

The orchestrator rollback and pre-init pool invariants also raise mutation resistance around promote leakage and attacker-initialized pool acceptance. `test/FAOOfficialProposalOrchestrator.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_ORCH_001_atomicRollbackEnvelope`, `test/FAOOfficialProposalOrchestrator.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_ORCH_002_refusesPreInitializedPool`

The fork-state NO-bond test catches a UI/reflection mutant where `placeNoBond` changes chain state but `/proposals.html` keeps showing the setup YES state after reload. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::placeNoBond(uint256)`, `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::proposal card should show the cast-updated NO chip after reload`

The fork-state graduate test catches a UI/reflection mutant where `tryGraduate` reaches arbitration state `3` but the proposal card does not render `QUEUED` and `Queued for evaluation`. `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::tryGraduate(uint256)`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::arbitration proposal should move to QUEUED after cast tryGraduate`, `tests-e2e/journeys/fork-state.read-only.spec.ts@c17ef8b51560710c4fca17d9fb667e5e0f816e7f::Queued for evaluation`

## How This Might Be Wrong

- The catalog itself has not been regenerated, so "gap now stale" is a wiki inference from tests, not an authored mutation-spec row. `audit/specs/MUTATIONS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#how-this-might-be-wrong`
- A real mutation runner could still find surviving mutants even where an invariant looks targeted. `audit/specs/MUTATIONS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#mutation-tool-readiness`
- If mutation workflow lands, this page should cite workflow output rather than only reasoning from invariant names. `audit/specs/MUTATIONS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Tool wiring left`
- If `MUTATIONS.md` adds TWAP-specific rows, the inferred TWAP section should become a direct table summary. `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::FAOTwapResolverInvariantTest`
- The fork-state mutation checks prove UI reflection after real cast transactions, not that a Solidity mutation runner killed a mutant. `tests-e2e/journeys/fork-state.read-only.spec.ts@6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00::fork state`

## See Also

- [Decidability](decidability.md)
- [Symbolic Obligations](halmos-instance-sale.md)
- [E2E Journey Map](e2e-journey-map.md)
- [Security](../30-cross-cutting/security.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - b68c06af35a8d5b8f96234dd4028f23c88c5435d
  - f04b27554031b3c291ef2acb6e9bf11c852c6288
  - 6bf0e1d61be0c7f40b9d0d77b8964a5f46caea00
  - c17ef8b51560710c4fca17d9fb667e5e0f816e7f
- Build pass: 12 (continuous HEAD refresh)
