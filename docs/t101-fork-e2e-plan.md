# T101 — Fork tests end-to-end: arbitration → futarchy → CTF → settle → Snapshot X execute

Goal (from Taskmaster): add **fork** tests proving the end-to-end flow:
1) proposal **graduates** into arbitration flow
2) a linked **futarchy proposal** resolves
3) the **CTF** payoutNumerators reflect YES/NO
4) evaluator settles the arbitration proposal
5) Snapshot X proposal can execute **only after** arbitration acceptance

## Current state (as of 2026-02-14)

- `FutarchyArbitration` proposal ids are **sequential** (`createProposal(...)` increments).
- `SXArbitrationExecutionStrategy` derives `arbId` as:

  ```solidity
  arbId := uint256(proposal.executionPayloadHash)
  ```

  and calls `arbitration.isAccepted(arbId)`.

## Key integration mismatch (must be resolved for true E2E)

Because `FutarchyArbitration` uses **sequential ids**, there is currently **no way** for `arbId` (a 256-bit hash) to equal the FutarchyArbitration `proposalId` except by coincidence.

Therefore, a true onchain E2E test where Snapshot X execution is gated by a FutarchyArbitration decision requires **an id-alignment mechanism**.

### Option A (recommended): change FutarchyArbitration id scheme
- Introduce a new proposal id scheme that is **deterministic** from Snapshot X proposal execution payload hash, e.g.
  - `proposalId = uint256(executionPayloadHash)`
- Store proposals in a mapping keyed by that id (already a mapping) and avoid sequential-only ids.
- Pros: simplest conceptual integration with current SX wrapper.
- Cons: changes existing semantics; requires careful handling for iteration/queue.

### Option B: change SX wrapper arbId derivation
- Use an arbId encoding that FutarchyArbitration can produce, e.g. pass sequential `proposalId`.
- But Snapshot X `getProposalStatus(...)` cannot see `payload`, so status-level gating cannot decode an arbId from calldata.
- A workaround would require storing arbId somewhere Snapshot X exposes in `Proposal` struct (e.g. embedded into `executionPayloadHash`), which collapses back to Option A.

## Fork-test implementation plan

### Step 1 — Minimal fork gating test (deploy-only)
- On a Gnosis fork:
  - deploy `Space` + `SXArbitrationExecutionStrategy` wrapper
  - deploy an `arbitration` implementation with an `isAccepted(uint256)` view compatible with the wrapper
  - prove wrapper blocks `space.execute(...)` until `isAccepted(arbId)==true`.

### Step 2 — FutarchyEvaluator fork proof (already started)
- `test/fork/FutarchyEvaluatorFork.t.sol` validates:
  - wrappedOutcome index mapping (0=YES,1=NO)
  - payout numerator invariants when resolved (env-gated)

### Step 3 — True E2E fork test (requires id-alignment fix)
- After implementing an id-alignment mechanism (Option A), write a fork test that:
  - creates an arbitration proposal with id = executionPayloadHash
  - links it to a futarchy proposal address (CTF conditionId)
  - settles arbitration via `FutarchyEvaluator`
  - executes Snapshot X proposal through wrapper successfully

## Env vars
- `RUN_GNOSIS_FORK_TESTS=true`
- optional overrides already used in existing fork tests:
  - `TEST_FAO_PROPOSAL`, `TEST_FAO_TOKEN`, `TEST_COLLATERAL_TOKEN`

## Acceptance notes
- Without an id-alignment change, we can only test wrapper gating with a mock arbitration contract; we cannot test *FutarchyArbitration*→*SnapshotX* gating end-to-end.
