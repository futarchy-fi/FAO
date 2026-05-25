---
canonical: test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::check_INV_ORCH_002_refusesPreInit
scope: Authoritative wiki coverage of current `check_INV_*` symbolic obligations and their boundary with forge `invariant_INV_*` tests.
not-scope: Stateful invariant status lives in [Decidability](decidability.md); E2E journey execution lives in [E2E Journey Map](e2e-journey-map.md).
last-rebuilt: 2026-05-22T17:29:12Z
---
# Symbolic Obligations

The symbolic obligation surface is still the `check_INV_*` set that Halmos targets. It matters because HEAD added several stateful `invariant_INV_*` tests and then aligned the ORCH-002 symbolic harness with the current orchestrator constructor, but those are not automatically Halmos proofs. The canonical mechanism is the symbolic workflow's `halmos --match-test 'check_INV_' --solver-timeout-assertion 30000 --loop 3` command, plus the test files whose function names start with `check_INV_`. `.github/workflows/symbolic.yml@b68c06af35a8d5b8f96234dd4028f23c88c5435d::Run Halmos on check_INV_* proof obligations`, `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::ExposedFAOOfficialProposalOrchestrator`

## Changed Since Last Refresh

The `check_INV_*` list is unchanged from the last wiki refresh, but HEAD adds stateful coverage for ARB-005 and TWAP-001/002 and marks all top-15 invariants TESTED. `audit/specs/INVARIANTS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#pass-status`

This distinction is important: `invariant_INV_TWAP_001_anchorMonotoneWindowFixed` is stateful forge evidence, while `check_INV_TWAP_001_anchorMonotone` remains the Halmos-shaped symbolic obligation. `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_001_anchorMonotoneWindowFixed`, `test/FAOTwapResolver.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_TWAP_001_anchorMonotone`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, `check_INV_ORCH_002_refusesPreInit` still has the same obligation, but its exposed orchestrator constructor now passes the current boolean constructor argument after the resolver. `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::IFAOFutarchyTwapResolver(address(0x1234))`, `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::true`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, `03a1fec` did not add a new `check_INV_*` obligation; it made adapter replaceability an explicit constructor mode and aligned the stateful orchestrator invariant harness to pass `true` for the testnet-mode path. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`, `test/FAOOfficialProposalOrchestrator.invariants.t.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::true`

## Current `check_INV_*` Surface

| File | Obligations |
|---|---|
| `test/GenericFutarchyToken.symbolic.t.sol` | `check_INV_TOKEN_001_supplyTracksHandlerOps`. `test/GenericFutarchyToken.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_TOKEN_001_supplyTracksHandlerOps` |
| `test/InstanceSale.symbolic.t.sol` | `check_INV_SALE_001_initialState`, `check_INV_SALE_001_afterBuy`, `check_INV_SALE_004_initialPhaseFinalizedSticky`. `test/InstanceSale.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_SALE_001_initialState`, `test/InstanceSale.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_SALE_004_initialPhaseFinalizedSticky` |
| `test/FutarchyArbitration.symbolic.t.sol` | `check_INV_ARB_001_idMonotone`, `check_INV_ARB_002_settledMonotone`, `check_INV_ARB_004_matchedBondsCorrespond`, `check_INV_ARB_006_safetyModeBlocksTimeout`. `test/FutarchyArbitration.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_ARB_001_idMonotone`, `test/FutarchyArbitration.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_ARB_006_safetyModeBlocksTimeout` |
| `test/FAOOfficialProposalOrchestrator.symbolic.t.sol` | `check_INV_ORCH_002_refusesPreInit`; the harness constructor is aligned with the current orchestrator signature. `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::check_INV_ORCH_002_refusesPreInit`, `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::true` |
| `test/FAOTwapResolver.symbolic.t.sol` | `check_INV_TWAP_001_anchorMonotone`. `test/FAOTwapResolver.symbolic.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::check_INV_TWAP_001_anchorMonotone` |

## Stateful Tests Added Around The Symbolic Surface

The forge invariant workflow runs `invariant_INV_`, not `check_INV_`; HEAD's new stateful coverage includes ARB-005, TWAP-001, and TWAP-002. `.github/workflows/forge.yml@b68c06af35a8d5b8f96234dd4028f23c88c5435d::forge test (stateful invariants -- 100 runs x 50 depth)`, `test/FutarchyArbitration.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_ARB_005_graduationReachableAtThreshold`, `test/FAOTwapResolver.invariants.t.sol@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_TWAP_002_resolutionWriteCardinality`

The right reading is therefore "all top-15 are TESTED", not "all top-15 are symbolically PROVED." `audit/specs/INVARIANTS.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::all Top-15 rows now have TESTED coverage`

## How This Might Be Wrong

- If new symbolic functions land with a different prefix, the workflow and this page will miss them. `.github/workflows/symbolic.yml@b68c06af35a8d5b8f96234dd4028f23c88c5435d::halmos --match-test 'check_INV_'`
- If Halmos starts targeting `invariant_INV_*`, this page's boundary between symbolic and forge stateful tests must be rewritten. `.github/workflows/forge.yml@b68c06af35a8d5b8f96234dd4028f23c88c5435d::invariant_INV_`
- If the orchestrator constructor changes again, the ORCH-002 exposed harness may compile-stale while the obligation name remains unchanged. `test/FAOOfficialProposalOrchestrator.symbolic.t.sol@2a41f6e6d266e9695a4273779a06825ff7dfd1c2::ExposedFAOOfficialProposalOrchestrator`
- If adapter replaceability becomes symbolic input instead of a fixed harness mode, this page should split ORCH-002 evidence by testnet-mode and mainnet-mode constructors. `src/FAOOfficialProposalOrchestrator.sol@03a1feca3de85f10e40b8680ed9a14f62dc7d2c0::ADAPTER_REPLACEABLE`
- If `DECIDABILITY.md` catches up with the all-TESTED status, this page should link to its revised table instead of warning about stale symbolic rows. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#roadmap-to-fully-decided`
- If counterexample artifacts are added, cite them here with the corresponding `check_INV_*` row. `audit/specs/DECIDABILITY.md@b68c06af35a8d5b8f96234dd4028f23c88c5435d::#counterexample-citation-discipline`

## See Also

- [Decidability](decidability.md)
- [Mutation Resistance](mutation-resistance.md)
- [Security](../30-cross-cutting/security.md)
- [Deployment](../30-cross-cutting/deployment.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - b68c06af35a8d5b8f96234dd4028f23c88c5435d
  - f04b27554031b3c291ef2acb6e9bf11c852c6288
  - 2a41f6e6d266e9695a4273779a06825ff7dfd1c2
  - 03a1feca3de85f10e40b8680ed9a14f62dc7d2c0
- Build pass: 12 (continuous HEAD refresh)
