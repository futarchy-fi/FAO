# Snapshot X arbitration gating: proposal validation strategy (optional)

This repo implements arbitration gating via `SXArbitrationExecutionStrategy`.

## Why an *additional* ProposalValidationStrategy is not strictly necessary

Snapshot X already computes `executionPayloadHash = keccak256(executionStrategy.params)` inside `Space.propose(...)`.
Our execution strategy uses that hash to derive a deterministic arbitration id:

- `arbId := uint256(proposal.executionPayloadHash)`

Then `execute(...)` verifies:
1) payload `arbId` matches the derived `arbId` from the stored proposal, and
2) the external `FutarchyArbitration.isAccepted(arbId)` is true.

So even if a proposer submits malformed params, they cannot execute unless the stored proposal’s payload hash corresponds to an accepted arbitration id.

## Limitation: Snapshot X proposal validation cannot see the execution strategy params

Snapshot X’s `IProposalValidationStrategy.validate(...)` signature is:

```solidity
function validate(address author, bytes calldata params, bytes calldata userParams) external returns (bool);
```

At proposal time, `Space.propose(...)` calls validation **before** it hashes / stores the proposal, and it does **not** provide `executionStrategy.params` to the validation strategy.

That means a validation strategy cannot reliably:
- compute `executionPayloadHash` itself, or
- verify that a user-supplied `arbId` matches the real `executionStrategy.params` used in the proposal,

because the only `bytes` it receives are strategy-configured `params` and user-provided `userParams`.

Any “validation” that relies on the proposer echoing their own payload in `userParams` is not a security gate (it cannot be proven consistent with the actual `executionStrategy.params` passed to `Space.propose`).

## Recommended approach

- Keep arbitration gating in the **execution strategy** (already implemented).
- If we later want stronger *proposal-time* checks, we need either:
  - a Snapshot X upstream change that passes `executionStrategy` (or its params/hash) into proposal validation, or
  - an authenticator layer that performs pre-validation and only calls `Space.propose` when checks pass.
