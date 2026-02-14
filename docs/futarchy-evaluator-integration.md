# FutarchyEvaluator integration (Phase 8) — notes

Goal (T100): implement an `IFutarchyArbitrationEvaluator` that resolves an active `FutarchyArbitration` evaluation using the existing futarchy stack in this repo.

## Current state
- `FutarchyArbitration` supports an external evaluator module via `IFutarchyArbitrationEvaluator`.
- `ManualEvaluator` exists as a centralized owner-controlled evaluator for tests / emergency.

## Desired behavior (high level)
When `FutarchyArbitration` has an `activeEvaluationProposalId`, the evaluator should:
1. Determine the futarchy proposal/market associated with that proposalId (need mapping).
2. Observe resolution outcome (accepted/rejected) via the futarchy system’s canonical oracle (likely Conditional Tokens Framework / official proposal source).
3. Call `FutarchyArbitration.resolveActiveEvaluation(bool accepted)` as the evaluator.

## Missing wiring questions (need to resolve before coding)
1. **Mapping:** How do we map `proposalId` (arbitration) → futarchy proposal identifier/address?
   - Option A: store mapping on `FutarchyArbitration` at create/graduation time.
   - Option B: store mapping in evaluator (requires trusted writes / admin).
2. **Source of truth:** Which contract provides the authoritative “proposal resolved outcome”?
   - Candidates in repo: `FutarchyOfficialProposalSource`, `FutarchyLiquidityManager`.
3. **Timing:** What if futarchy proposal is not resolved yet?
   - Evaluator should revert (no-op) until resolvable.
4. **Safety:** Ensure evaluator cannot be tricked into resolving the wrong `proposalId`.
   - Must bind to a single arbitration contract (`arbitration()` already required).
   - Prefer immutable references to futarchy core contracts.

## Proposed minimal interface shape
A concrete evaluator contract should likely be configured with:
- `address public immutable arbitration;`
- `IFutarchyOfficialProposalSource public immutable proposalSource;` (or equivalent)
- Any resolver/oracle contract references needed.

And implement:
- `function arbitration() external view returns (address)`
- `function resolve(bool accepted) external` **or** `function resolveFromFutarchy(...) external` (name TBD)

## Next concrete steps
1. Locate where the futarchy proposal lifecycle is implemented (contracts + tests).
2. Identify the single read call that yields a boolean outcome (accepted/rejected) + resolved flag.
3. Decide storage location for mapping proposalId → futarchy proposal address/id.
4. Implement `FutarchyEvaluator.sol` and add unit tests mirroring `ManualEvaluator` tests but using the futarchy path.

## Repo scan findings (2026-02-14)
- `IFutarchyOfficialProposalSource` only exposes `{exists, settled}` + tokens/pools; **it does not expose a YES/NO outcome**.
- The only “oracle” hook currently modeled in-repo is `settlementOracle` with interface `isSettled(address proposal) -> bool` (no outcome).
- Fork tests (`test/fork/FutarchyLiquidityCycleFork.t.sol`) interact with real Futarchy proposal contracts on Gnosis via `wrappedOutcome(i)` but likewise do not read outcome; they simulate settlement with `proposalSource.setManualSettled(true)`.

## On-chain interface probing (Gnosis fork default proposal, 2026-02-14)
Using Foundry `cast` against `TEST_FAO_PROPOSAL` default (0x81829a8ee62D306e3fD9D5b79D02C7624437BE37):
- The proposal contract **does expose**:
  - `conditionId() -> bytes32` = `0x0e97e87184e73f5f8a7ffa30fa3f716eaa347051564ff883d8c894d565a89e6b`
  - `questionId() -> bytes32` = `0xb7e4530152c82ddcddcd0118925dbcf4a69ea7e35d2baf77d8882a613cc71e74`
- `wrappedOutcome(0)` returns an ERC20-like wrapper token (e.g. YES_FAO) and a non-empty `bytes` blob that appears to encode human-readable metadata (starts with ASCII `YES_FAO`), not an obvious condition/index tuple.
- The wrapped outcome token contract (0x2F623D42110b2d2ec2EA5379fCc8F38e7E53Dcf5 for YES_FAO) exposes `tokenId() -> uint256`, consistent with being a wrapper around a CTF ERC1155 position id.

### ConditionalTokens (CTF) address check
The canonical ConditionalTokens contract on Gnosis appears to be deployed at:
- `0xCeAfDD6bc0bEf976fdCd1112955828E00543c0Ce`
Calling `payoutDenominator(conditionId)` and `payoutNumerators(conditionId, i)` currently returns 0 for i∈{0,1} (unresolved at time of probe), but the contract bytecode is present and the calls succeed.

### Implication for FutarchyEvaluator
To resolve an arbitration evaluation, the evaluator must obtain an *outcome bit* (accepted/rejected). That outcome is not currently available via any existing in-repo interface, so we need to pick an authoritative outcome source and write a minimal interface for it.

### Candidate outcome sources to wire (proposed)
1. **Proposal contract itself** (preferred if it exposes a canonical result):
   - Add a minimal interface in-repo once we confirm the actual function name(s) on the deployed futarchy proposal contract (e.g., `isResolved()`, `resolvedOutcome()`, `result()`, etc.).
2. **Conditional Tokens Framework (CTF)** via condition payouts (fallback):
   - Use `wrappedOutcome(i)`'s `bytes outcomeData` to recover the underlying conditional-tokens `conditionId` and outcome index, then read `payoutNumerators(conditionId, index)` from the CTF contract.
   - Map payout to boolean: whichever side has nonzero payout is “winner”; define `accepted` accordingly.
   - This requires: (a) confirming encoding inside `wrappedOutcome` bytes, (b) knowing the CTF contract address used by futarchy on the target chain.

### Outcome index mapping confirmation (2026-02-14)
Using `~/.foundry/bin/cast` against Gnosis RPC (`https://rpc.gnosischain.com`) and the default test proposal `0x81829a8e...`:
- `wrappedOutcome(0)` returns bytes starting with ASCII `YES_FAO...`
- `wrappedOutcome(1)` returns bytes starting with ASCII `NO_FAO...`

Evidence (abridged):
- `cast call <proposal> "wrappedOutcome(uint256)(address,bytes)" 0` → `0x5945535f46414f...` (`YES_FAO`)
- `cast call <proposal> "wrappedOutcome(uint256)(address,bytes)" 1` → `0x4e4f5f46414f...` (`NO_FAO`)

Implication:
- For the futarchy proposal implementation used on Gnosis, outcome index 0 corresponds to YES and index 1 to NO (at least for the company-side outcomes).
- This matches the assumption currently used by `src/FutarchyEvaluator.sol` when reading CTF `payoutNumerators(conditionId, index)`.

### Next concrete step
- Confirm, for the same deployed proposal, that `conditionId()` is the condition resolved by CTF and that CTF’s binary payout indices align with YES/NO as above.
  - Once a real proposal is resolved on-chain, re-run `payoutNumerators(conditionId, 0/1)` and verify the winner matches the expected YES/NO side.
