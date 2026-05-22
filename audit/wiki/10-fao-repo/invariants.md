---
canonical: audit/specs/INVARIANTS.md@768d2ab2bdaee37c156955b0fd08732e166ae94d
scope: Authoritative wiki summary of the authored FAO invariant catalogue and its 15 stable INV-* IDs.
not-scope: Attack-vector enumeration lives in [Threat Model](../30-cross-cutting/threat-model.md); security posture lives in [Security](../30-cross-cutting/security.md).
last-rebuilt: 2026-05-22T14:31:28Z
---
# Invariants

The authored invariant spec is now the source of truth for FAO's load-bearing safety properties. It matters because the wiki should point reviewers to stable spec IDs, not re-invent invariant names from code. The canonical mechanism is a 15-entry catalogue where each invariant has a stable `INV-*` ID, prose statement, machine-checkable predicate, implementation citation, and status. `audit/specs/INVARIANTS.md:8-18`

## Spec Role

`audit/specs/INVARIANTS.md` defines the top-15 system invariants and states that pre/postcondition coverage lives under `audit/specs/preconditions/`. `audit/specs/INVARIANTS.md:1-5`, `audit/specs/INVARIANTS.md:8-18`

`audit/specs/preconditions/InstanceSale.md` is the function-level companion for `InstanceSale`; it defines preconditions, postconditions, frame conditions, and explicit revert modes for sale calls. `audit/specs/preconditions/InstanceSale.md:8-17`

The spec also defines the maintenance workflow: invariant updates are authored manually with code changes or proposed by a CAO drift-detection sweep, and implementation/tests/proofs should cite the invariant IDs. `audit/specs/INVARIANTS.md:305-313`, `audit/specs/INVARIANTS.md:339-345`

## Token And Sale IDs

| ID | Summary | Status |
|---|---|---|
| `INV-TOKEN-001` | Token total supply changes only through mint and burn event paths for `FAOToken` and `GenericFutarchyToken`. `audit/specs/INVARIANTS.md:22-36` | Stated, with partial token unit-test coverage. `audit/specs/INVARIANTS.md:315-320` |
| `INV-SALE-001` | `InstanceSale.effectiveSupply()` equals total token supply minus the sale contract's own token balance, floored at zero. `audit/specs/INVARIANTS.md:40-53` | Stated and tested for effective-supply cases. `audit/specs/INVARIANTS.md:315-321` |
| `INV-SALE-002` | Successful `ragequit(n)` burns `n * 1e18`, decreases effective supply and total supply, and pays exact pro-rata ETH plus each active ragequit ERC20. `audit/specs/INVARIANTS.md:57-83` | Stated, with partial ETH-only ragequit coverage. `audit/specs/INVARIANTS.md:315-322` |
| `INV-SALE-003` | `ragequit(n)` reverts for sale self-ragequit, zero effective supply, or burn amount greater than effective supply. `audit/specs/INVARIANTS.md:87-99` | Stated and tested for revert guards. `audit/specs/INVARIANTS.md:315-323` |
| `INV-SALE-004` | `initialPhaseFinalized` is monotone, and `initialNetSale` freezes when the initial phase finalizes. `audit/specs/INVARIANTS.md:103-116` | Stated, with partial coverage. `audit/specs/INVARIANTS.md:315-324` |

`InstanceSale` preconditions refine these invariant summaries: `buy` requires positive whole-token amount and exact ETH after possible finalization, while `ragequit` requires positive amount, non-self caller, positive effective supply, in-range burn amount, and token approval. `audit/specs/preconditions/InstanceSale.md:32-52`

## Arbitration IDs

| ID | Summary | Status |
|---|---|---|
| `INV-ARB-001` | `nextProposalId` is monotonically increasing, and existing proposal IDs are initialized only through `_initProposal`. `audit/specs/INVARIANTS.md:120-133` | Stated with partial Foundry invariant coverage. `audit/specs/INVARIANTS.md:315-325` |
| `INV-ARB-002` | A settled proposal remains settled, stays in `SETTLED`, and keeps its `accepted` value immutable. `audit/specs/INVARIANTS.md:137-152` | Stated only. `audit/specs/INVARIANTS.md:315-326` |
| `INV-ARB-003` | Arbitration WETH balance should equal withdrawable refunds plus unsettled YES and NO bonds. `audit/specs/INVARIANTS.md:156-169` | Tested as a weaker `>=` property; spec strengthens it to equality. `audit/specs/INVARIANTS.md:156-169`, `audit/specs/INVARIANTS.md:315-327` |
| `INV-ARB-004` | `placeNoBond` sets NO bond amount exactly to the previous YES bond amount. `audit/specs/INVARIANTS.md:173-185` | Stated only. `audit/specs/INVARIANTS.md:315-328` |
| `INV-ARB-005` | A YES bond at least `baseX * 2^queuedCount` can graduate the proposal regardless of current NO state. `audit/specs/INVARIANTS.md:189-200` | Stated only. `audit/specs/INVARIANTS.md:315-329` |
| `INV-ARB-006` | `safetyModeActive()` is equivalent to aggregate unsettled NO bonds at least `baseX`, and YES timeout finalization reverts while safety mode is active. `audit/specs/INVARIANTS.md:204-216` | Stated only. `audit/specs/INVARIANTS.md:315-330` |

## Orchestrator And TWAP IDs

| ID | Summary | Status |
|---|---|---|
| `INV-ORCH-001` | `createOfficialProposalAndMigrate` is atomic across proposal creation, condition prep, wrapper deploy, pool init, observation warmup, adapter migration, and builder tip. `audit/specs/INVARIANTS.md:220-236` | Stated only. `audit/specs/INVARIANTS.md:315-331` |
| `INV-ORCH-002` | A deterministic pool that already exists and has nonzero `slot0().sqrtPriceX96` must make the orchestrator's pool init path revert. `audit/specs/INVARIANTS.md:240-254` | Stated only. `audit/specs/INVARIANTS.md:315-332` |
| `INV-TWAP-001` | Resolver binding anchor timestamp is written at most once, and resolution always measures `[anchor + TIMEOUT - TWAP_WINDOW, anchor + TIMEOUT]`. `audit/specs/INVARIANTS.md:258-271` | Stated only. `audit/specs/INVARIANTS.md:315-333` |
| `INV-TWAP-002` | `resolve(p)` flips `resolved` exactly once, sets `accepted` in the same resolution, freezes both fields, and rejects re-resolution. `audit/specs/INVARIANTS.md:275-288` | Stated only. `audit/specs/INVARIANTS.md:315-333` |

## Stretch IDs And Traceability

The spec lists stretch invariants for adapter staging, adapter callback authorization, TWAP normalization, CTF conservation, Wrapped1155 1:1 wrapping, and UniV3 tick cumulative monotonicity. They are explicitly post-top-15 stubs, not blocking top-15 entries. `audit/specs/INVARIANTS.md:292-301`

The pass-status table says no top-15 invariant is proved yet, several are only stated, and Phase 6 should finish partial tested entries before adding missing tests. `audit/specs/INVARIANTS.md:315-335`

## How This Might Be Wrong

- If the authored spec renames an `INV-*` ID, this page should preserve old links only if redirects or aliases are added in the spec. `audit/specs/INVARIANTS.md:10-18`
- If precondition files are added for more contracts, this page should link them from the relevant module sections instead of only naming `InstanceSale`. `audit/specs/preconditions/InstanceSale.md:124-129`
- If a stated invariant becomes tested or proved, the status summaries here must track the pass-status table. `audit/specs/INVARIANTS.md:315-335`
- If line-range citations in the authored spec drift, the wiki should re-pin to the new source commit and line ranges. `audit/specs/INVARIANTS.md:352-357`

## See Also

- [Threat Model](../30-cross-cutting/threat-model.md)
- [Security](../30-cross-cutting/security.md)
- [Architecture](architecture.md)
- [Arbitration](lifecycle/60-arbitration.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 768d2ab2bdaee37c156955b0fd08732e166ae94d
- Build pass: 1 (authored spec refresh)
