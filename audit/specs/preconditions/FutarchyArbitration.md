---
canonical: src/FutarchyArbitration.sol
scope: Per-function PRE/POST/FRAME for FutarchyArbitration — the bond-escalation gatekeeper that decides which proposals graduate to promotion.
not-scope: Per-instance arbitration is `ParameterizedArbitration.sol` (same shape, different constructor); this file documents both.
last-rebuilt: 2026-05-22
---

# Preconditions — `FutarchyArbitration`

The arbitration contract orchestrates bond-escalated proposal queueing. Six invariants govern it (`INV-ARB-001` … `INV-ARB-006`); the function-level preconditions below are the call-boundary refinement of those predicates.

## Constants & immutables

| Slot | Type | Invariant |
|---|---|---|
| `WETH` | `address` | non-zero, set in constructor. Used for all bond payments. |
| `baseX` | `uint256` | > 0, set in constructor. Activation-bond base; queue depth `k` requires YES ≥ `baseX × 2^k`. |
| `MAX_QUEUE` | `uint256` | Set in constructor. Cap on simultaneously-queued proposals (default 3). |
| `TIMEOUT` | `uint256` | Set in constructor (in seconds). Time after `state := YES` until `finalizeByTimeout` is callable. |
| `nextProposalId` | `uint256` | Strictly monotonically increasing (`INV-ARB-001`). |
| `proposals[id]` | struct | Append-only: only `_initProposal` writes `exists := true`; state transitions guarded. |
| `withdrawable[addr]` | `uint256` | Accumulator for refundable WETH per address. |

## State-mutating functions

### `placeYesBond(uint256 proposalId, uint256 amount) external`

| | |
|---|---|
| **PRE** | Caller has approved `amount` WETH to this contract. `proposals[proposalId].exists == true`. `state ∈ {NEW, NO}` (cannot bond into SETTLED or YES — flip costs 2× via `placeNoBond` instead). `amount >= minActivationBond(proposalId)` (see INV-ARB-005). If transitioning from NEW: `amount >= baseX × 2^queuedCount()`. |
| **POST** | `yesBond[proposalId] := (msg.sender, amount)`. `state := YES`. WETH transferred from caller to contract. If a previous `noBond` existed, its `amount` is added to `withdrawable[previousNoBonder]`. |
| **FRAME** | `nextProposalId`. Other proposals' state. `baseX`, `MAX_QUEUE`, `TIMEOUT`. |
| **REVERTS** | `ProposalNotFound(proposalId)`. `InvalidState(proposalId, currentState)` if state ∉ {NEW, NO}. `BondTooSmall(amount, required)` if below minimum. WETH transferFrom failure. |
| **EVENTS** | `YesBondPlaced(proposalId, bonder, amount)`. If a NO bonder is refunded: `WithdrawableCredit(prevBonder, amount)`. |
| **Invariants touched** | INV-ARB-003 (treasury conservation), INV-ARB-005 (graduation reachability). |

### `placeNoBond(uint256 proposalId) external`

| | |
|---|---|
| **PRE** | Caller has approved `2 × yesBond[proposalId].amount` WETH. `proposals[proposalId].exists == true`. `state == YES`. There must be a current YES bond. |
| **POST** | `noBond[proposalId] := (msg.sender, 2 × yesBond.amount)`. `state := NO`. WETH transferred from caller. Previous YES bond's `amount` credited to `withdrawable[previousYesBonder]`. |
| **FRAME** | Same as `placeYesBond`. |
| **REVERTS** | `ProposalNotFound`. `InvalidState` if state ≠ YES. WETH transferFrom failure (caller didn't approve enough). |
| **EVENTS** | `NoBondPlaced(proposalId, bonder, amount)`. `WithdrawableCredit(prevYesBonder, amount)`. |
| **Invariants touched** | INV-ARB-003, INV-ARB-004 (strict matching). |

### `finalizeByTimeout(uint256 proposalId) external`

| | |
|---|---|
| **PRE** | `proposals[proposalId].exists == true`. `state == YES`. `block.timestamp >= lastStateChange + TIMEOUT`. `!safetyModeActive()` (else INV-ARB-006 forbids YES-state finalization). |
| **POST** | `settled := true`. `state := SETTLED`. `accepted := true`. The YES bonder's `yesBond.amount` is credited to their `withdrawable[]`. |
| **FRAME** | Other proposals; constants. |
| **REVERTS** | `ProposalNotFound`. `InvalidState` if state ≠ YES. `TooEarly(deadline)` if block.timestamp < lastStateChange + TIMEOUT. `SafetyModeActive()` if `Σ noBonds ≥ baseX`. |
| **EVENTS** | `Settled(proposalId, accepted=true, by=msg.sender)`. |
| **Invariants touched** | INV-ARB-002 (settlement irreversibility), INV-ARB-006 (safety mode). |

### `tryGraduate(uint256 proposalId) external returns (bool graduated)`

| | |
|---|---|
| **PRE** | `proposals[proposalId].exists == true`. `state == YES`. `yesBond.amount >= baseX × 2^queuedCount()`. |
| **POST** | If graduation conditions met: `state := PROMOTED`. The proposal is now eligible for `FAOOfficialProposalOrchestrator.createOfficialProposalAndMigrate`. Returns `true` iff graduation happened. If conditions not met, returns `false` without state change. |
| **FRAME** | Other proposals; constants. |
| **REVERTS** | `ProposalNotFound`. `InvalidState`. |
| **EVENTS** | If graduated: `Graduated(proposalId, by=msg.sender)`. |
| **Invariants touched** | INV-ARB-005 (graduation reachability). |

### `_initProposal(uint256 proposalId, uint256 minActivationBond) internal`

| | |
|---|---|
| **PRE** | `!proposals[proposalId].exists`. Caller must be `placeYesBond` (the only public path that calls this internal). |
| **POST** | `proposals[proposalId] = (exists=true, state=NEW, settled=false, accepted=false, lastStateChange=block.timestamp, minActivationBond=minActivationBond)`. `nextProposalId := max(nextProposalId, proposalId + 1)`. |
| **FRAME** | Other proposals; all constants; bonds. |
| **REVERTS** | None (private function; preconditions enforced by caller). |
| **EVENTS** | `ProposalInitialized(proposalId, minActivationBond)`. |
| **Invariants touched** | INV-ARB-001 (id monotonicity); this is the only writer of `exists := true`. |

### `withdraw() external`

| | |
|---|---|
| **PRE** | `withdrawable[msg.sender] > 0`. |
| **POST** | Caller receives `withdrawable[msg.sender]` WETH. `withdrawable[msg.sender] := 0`. |
| **FRAME** | All other addresses' withdrawable balances. All proposals. |
| **REVERTS** | `NothingWithdrawable()` if balance is 0. WETH transfer failure. |
| **EVENTS** | `Withdrawn(msg.sender, amount)`. |
| **Invariants touched** | INV-ARB-003 (decreases LHS as caller's balance leaves the contract). |

## View functions

### `safetyModeActive() public view → bool`

Returns `Σ_{p unsettled} noBond[p].amount >= baseX`. The threshold below which the YES-state-timeout path is allowed.

### `_queuedCount() internal view → uint256`

Counts proposals in `{NEW, YES, NO}` (i.e. unsettled). Caps must respect `MAX_QUEUE`.

### `minActivationBond(uint256 proposalId) external view → uint256`

Returns `baseX × 2^queuedCount()` for new proposals; for existing, returns the historical activation bond.

## Modifier

### `onlyOwner`

Used on `setEvaluator` (config) and `pause` (kill-switch). Per `ParameterizedArbitration`, the owner is the futarchy creator.

## Constructor (`FutarchyArbitration` / `ParameterizedArbitration`)

| | |
|---|---|
| **Args** | `(address admin, address weth, uint256 baseBondX, uint256 maxQueue, uint256 timeout)`. |
| **PRE** | `admin != 0 ∧ weth != 0 ∧ baseBondX > 0 ∧ timeout > 0`. |
| **POST** | All immutables set. `nextProposalId == 1` (id 0 sentinel). |
| **REVERTS** | The four require checks. |

## How this might be wrong

- The `_initProposal` "only caller" predicate is informal — Solidity's `internal` doesn't enforce caller identity beyond visibility, so it depends on the contract layout. A future refactor that exposes another internal caller would break INV-ARB-001's "single writer" claim.
- `tryGraduate` is permissionless on purpose so anyone can pay the gas to graduate a ready proposal. That's by design (`INV-ARB-005` says "regardless of who calls").
- The PRE on `placeYesBond` says the caller approved `amount` WETH. The actual transfer reverts if the approval is insufficient — bubbling a WETH-side error, not an arbitration-side one. UI shows the upstream cause.
- `finalizeByTimeout` is documented as failing under safety mode, but the active implementation conflates that with `_queuedCount > 0`. The spec leaves the harder of the two as the binding revert.
- `withdraw` follows the checks-effects-interactions pattern, but inherits the WETH transfer's own reentry surface. Bond-treasury conservation (INV-ARB-003) requires that no balance can be claimed twice; the `withdrawable[msg.sender] := 0` write happens before the external call.
