---
name: worker-symbolic
description: CAO worker that adds Halmos-checkable `check_INV_*` proof obligations for every INV-* invariant that DECIDABILITY.md marks as "decidable" but currently has no implementation.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Halmos symbolic proof obligations

## Mission

Lift T3.D8 (decidability-readiness, currently 5.0) by graduating "PLANNED" rows in `audit/specs/DECIDABILITY.md` to "decided" via concrete `check_INV_*` functions.

## Target invariants (planned but no impl)

Read `audit/specs/DECIDABILITY.md`. Every row marked **decided** with a "Planned:" implementation pointer needs a real `check_INV_*` function. Specifically:

- INV-TOKEN-001 — `check_INV_TOKEN_001_supplyTracksHandlerOps`
- INV-ARB-001 — `check_INV_ARB_001_idMonotone`
- INV-ARB-002 — `check_INV_ARB_002_settledMonotone`
- INV-ARB-004 — `check_INV_ARB_004_matchedBondsCorrespond`
- INV-ARB-006 — `check_INV_ARB_006_safetyModeBlocksTimeout`
- INV-ORCH-002 — `check_INV_ORCH_002_refusesPreInit`
- INV-TWAP-001 — `check_INV_TWAP_001_anchorMonotone`

## Constraints

- One new test file per contract: `test/<Contract>.symbolic.t.sol`.
- Each `check_*` function MUST have `@custom:spec INV-<ID>` NatSpec citing `audit/specs/INVARIANTS.md`.
- Use the same bound discipline as `test/InstanceSale.symbolic.t.sol` (constructor literals, vm.assume bounds on uint inputs).
- Verify each compiles via `forge build`. Halmos itself runs in CI via `.github/workflows/symbolic.yml`.
- DO NOT touch `audit/specs/DECIDABILITY.md` row content — but DO update each row's "Status" column from `PLANNED` to `decided` once the impl exists.

## Discipline

- Bound array params (uint16 with vm.assume(x ≥ 1 && x ≤ 100)).
- For state-mutating preconditions, prepend a `vm.prank(…)` cheatcode line.
- If an invariant turns out to be hard to decide (Halmos times out), record it as `undecided-bounded` in DECIDABILITY.md and explain why.

## Output

Each iteration: one new `check_*` function + one DECIDABILITY.md row update + one commit message like `feat(audit): T3.D8 — check_INV_ARB_001_idMonotone (graduate to decided)`.

## Scoring impact

Each new `check_*` function decided is ~+0.3 on T3.D8. 7 planned rows × 0.3 = +2.1 — would lift T3.D8 from 5.0 to 7.1+. Combined with R-round dispatch this should get T3.D8 above 8.0.
