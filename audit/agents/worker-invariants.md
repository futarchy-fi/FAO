---
name: worker-invariants
description: CAO worker that adds Foundry stateful invariant tests for the INV-ARB-*, INV-ORCH-*, INV-TWAP-* invariants currently marked STATED in audit/specs/INVARIANTS.md. Lifts T3.D2 (invariant-explicitness).
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Stateful invariant tests for INV-ARB / INV-ORCH / INV-TWAP

## Mission

Lift T3.D2 (invariant-explicitness, score 5.0) and T4.D1 (layer coverage, currently 8.1 — already at target but we want T4.D3 mutation resistance to come up too).

Per `audit/specs/INVARIANTS.md`, INV-SALE-* invariants already have stateful tests via:
- `test/InstanceSale.invariants.t.sol` (3 invariants)
- `test/InstanceSale.proRata.invariants.t.sol` (2 invariants)

The gap is INV-ARB-* (6 invariants), INV-ORCH-* (2 invariants), INV-TWAP-* (2 invariants).

## Target invariants

Read `audit/specs/INVARIANTS.md`. Add stateful tests for:

1. **INV-ARB-001** — `nextProposalId` strictly monotonic (handler: `_initProposal` calls).
2. **INV-ARB-002** — `settled := true` is irreversible (handler: settles, then asserts post-settle state).
3. **INV-ARB-003** — Bond-treasury conservation: `Σ_{p unsettled} (yesBond + noBond) + Σ withdrawable[] == WETH.balanceOf(arbitration)`.
4. **INV-ARB-004** — Strict bond matching (no orphaned credits).
5. **INV-ARB-006** — Safety-mode threshold gating (timeout blocked when Σ noBonds ≥ baseX).
6. **INV-ORCH-001** — Atomic promote rollback envelope (handler: force a phase to revert, assert full rollback).
7. **INV-ORCH-002** — Refuse pre-initialized pool.

## Constraints

- One new test file per contract: `test/<Contract>.invariants.t.sol`.
- Follow the `StdInvariant` + Handler pattern from `test/InstanceSale.invariants.t.sol`.
- Each invariant function MUST start with `invariant_INV_<ID>_<assertion_name>` so forge --match-test finds it AND `@custom:spec INV-<ID>` NatSpec.
- Update `audit/specs/INVARIANTS.md` status table: PROSE → TESTED for each new invariant.
- Run `forge test --match-test 'invariant_'` to verify each new test PASSES under 100 runs × 50 depth (≥ 5000 calls).
- DO NOT mock the contracts under test. Deploy real `FutarchyArbitration` / `FAOOfficialProposalOrchestrator`.

## Output per iteration

1. One new `invariant_INV_*_*` function.
2. INVARIANTS.md status table update.
3. Commit: `feat(audit): T3.D2 + T4.D1 — invariant_INV_<id>_<name> (graduate to TESTED)`.

## Discipline

- The Handler pattern matters: a stateful test that doesn't actually exercise multiple state transitions is useless. The Handler MUST have ≥ 2 distinct `external` entry points (e.g. `placeYesBond`, `placeNoBond`, `finalizeByTimeout`) that the fuzzer can choose between.
- If an invariant fails under the bounded fuzz budget, STOP and report the counterexample — do not weaken the invariant to make the test pass.

## Scoring impact

Each invariant graduated from STATED to TESTED is ~+0.3 on T3.D2. 7 invariants × 0.3 = +2.1 — would lift T3.D2 from 5.0 to 7.1+. Plus T4.D3 mutation resistance gets indirect lift (more tests catch more mutations).
