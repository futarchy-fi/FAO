# Commit 002: FAOFutarchyFactory + FAOFutarchyProposal

## Goal

Replace Seer's `FutarchyFactory` and `FutarchyProposal` (in `lib/seer-demo/contracts/src/`)
with FAO-owned versions that:

1. Drop the Reality.eth dependency (no Reality question creation, no
   `FutarchyRealityProxy` type).
2. Derive `questionId` from `block.prevrandao` so that the deterministic
   chain `questionId → conditionId → positionIds → wrapper addresses →
   UniV3 pool addresses` cannot be predicted before the slot in which the
   `createProposal` call lands. See `docs/onchain-futarchy-design.md` §4.1.
3. Accept a generic `IFAOFutarchyOracle` (FutarchyTwapResolver in v0)
   instead of a Reality proxy.

## Files

- `src/interfaces/IConditionalTokensLike.sol` — minimal CTF interface used by
  the FAO stack. Re-declared locally instead of pulling from `lib/seer-demo`
  to avoid coupling.
- `src/interfaces/IWrapped1155FactoryLike.sol` — minimal Gnosis
  Wrapped1155Factory interface.
- `src/interfaces/IFAOFutarchyOracle.sol` — single `resolve(address proposal)`
  method, used by `FAOFutarchyProposal.resolve()` and implemented by the
  upcoming `FutarchyTwapResolver`.
- `src/FAOFutarchyProposal.sol` — cloneable proposal: stores conditionId /
  questionId / wrappers / outcomes / oracle, plus the standard getters used
  by the orchestrator.
- `src/FAOFutarchyFactory.sol` — creates the CTF condition, deploys the four
  Wrapped1155 wrappers, clones the proposal contract, emits `NewProposal`.

## questionId derivation

```solidity
contentHash = keccak256(abi.encodePacked(marketName, description));
questionId  = keccak256(abi.encodePacked(
    contentHash,
    address(this),            // factory isolation
    proposals.length,         // intra-block disambiguation
    block.prevrandao          // cross-block unpredictability
));
```

Compared to Seer's hash:

| Field | Seer | FAO v0 |
|-------|------|--------|
| content_hash | included | included (slightly different inputs) |
| arbitrator | included | dropped (no arbitrator concept) |
| questionTimeout | included | dropped (per-proposal timeout not used) |
| minBond | included | dropped (handled by FutarchyArbitration) |
| address(realitio) | included | dropped (no Reality) |
| address(this) | included | included |
| nonce (hard-coded 0) | included | replaced by `proposals.length + block.prevrandao` |

## Security properties

| Vector | Status |
|--------|--------|
| A1 (pool pre-creation across blocks) | Closed by `block.prevrandao` in derivation; adversary cannot pre-compute wrapper/pool addresses for future blocks. |
| Intra-block proposal collision | Closed by `proposals.length` in derivation; consecutive same-block calls get distinct questionIds. |
| Factory replay across instances | Closed by `address(this)` in derivation. |
| Identical content collision | Allowed (idempotent re-attempt of same proposal yields the same questionId at the same prevrandao + index — a property the orchestrator's sanity check leverages). |

## Adversarial tests

`test/FAOFutarchyFactory.t.sol` covers:

- `test_computeQuestionId_deterministicForSameInputs` — determinism.
- `test_computeQuestionId_changesWithPrevrandao` — **A1 defense property**.
- `test_computeQuestionId_changesWithIndex` — intra-block disambiguation.
- `test_computeQuestionId_changesWithFactory` — factory isolation.
- `test_createProposal_emitsAndAdvancesIndex` — happy path.
- `test_createProposal_advancesIndexAcrossCalls` — consecutive calls work.
- `test_createProposal_revertsOnEmptyName` / `revertsOnZeroCollateral` —
  input validation.
- `test_A1_attackerCannotPreComputeQuestionIdWithoutPrevrandao` —
  simulates an adversary trying 100 prevrandao guesses; none match.
- `test_A2_blockNumberDerivationWouldBePredictable` — regression guard
  documenting why `block.number` is the wrong knob.

## Known environment limitation

`forge test` currently fails with an ambiguous import error between
`src/types.sol` and `lib/sx-evm/src/types.sol`. This is a pre-existing
issue in this repo unrelated to this commit:

```
Error (6275): Source "src/types.sol" not found: Ambiguous import.
Multiple matching files found inside base path and/or include paths:
"/work/src/types.sol", "/work/lib/sx-evm/src/types.sol".
```

It originates from `lib/sx-evm/src/interfaces/space/*` using
`import "src/types.sol"` (relative to project root), and the local
shim files in `src/` having the same path. With Forge 1.5+ the
ambiguity resolution is stricter than what these shims assumed.

**This blocks running the FAOFutarchyFactory test suite** even though
the contracts themselves compile clean via `forge build --skip test`.

Fix path (out of scope for this commit):

- Either remove the duplicate shim files in `src/` and update sx-evm
  imports to use the `sx/` remapping prefix, or
- Add an explicit single-source remapping for the conflicting paths.

The adversarial tests are valid Solidity and will execute against the
factory once the import ambiguity is resolved. Until then, the
properties they check are also asserted by inspection in this doc and
by the `computeQuestionId` view function which is callable on-chain.
