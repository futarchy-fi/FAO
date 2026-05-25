---
canonical: src/ParameterizedArbitration.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for WETH-bond proposal challenge, graduation, evaluation, and payout flow.
not-scope: TWAP-to-CTF resolution is covered in [Resolve](50-resolve.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Arbitration

Arbitration is FAO's WETH-bond challenge game around proposals. It matters because not every candidate should immediately become final: bonds create cost for activation, opposition, graduation, and queue pressure. The canonical mechanism is `ParameterizedArbitration`, whose constructor supplies WETH, base bond, max queue, and timeout, then whose state machine moves proposals through inactive, YES, NO, queued, evaluating, and settled states. `src/ParameterizedArbitration.sol:10-28`, `src/ParameterizedArbitration.sol:35-77`, `src/ParameterizedArbitration.sol:168-183`

## Parameters

The parameterized contract exists because the older `FutarchyArbitration` hardcoded WETH, `baseX`, `MAX_QUEUE`, and timeout; the registry needs those as constructor-supplied instance knobs. `src/ParameterizedArbitration.sol:10-28`

The constructor rejects zero admin, zero WETH, zero base bond, zero max queue, and zero timeout, then stores owner, WETH, `baseX`, `MAX_QUEUE`, and `TIMEOUT`. `src/ParameterizedArbitration.sol:168-183`

The registry creates arbitration with the instance creator as admin, shared WETH, user-supplied base bond, default max queue of 3, and user-supplied timeout. `src/FutarchyRegistry.sol:166-167`, `src/FutarchyRegistry.sol:231-233`

## Proposal Creation

Anyone can call `createProposal(minActivationBond)` with a nonzero minimum and receive the next auto-incremented proposal ID. `src/ParameterizedArbitration.sol:189-201`

Integrations can call `createProposalWithId(proposalId, minActivationBond)` to use an explicit nonzero ID, as long as it is not already used. `src/ParameterizedArbitration.sol:203-215`

`FAOCreateAndBond` uses the explicit-ID path by deriving the ID from the futarchy proposal address and opening the arbitration slot with `baseX` as the minimum activation bond. `src/FAOCreateAndBond.sol:113-162`

## Bonds And Flips

`placeYesBond` can activate an inactive proposal if the amount meets `minActivationBond`; after a NO state, a YES bond must either meet the current graduation threshold or meet the larger of twice the NO bond and the minimum activation bond. `src/ParameterizedArbitration.sol:221-239`

YES bonds transfer WETH into the contract, refund any replaced YES bond into the replaced bidder's withdrawable balance, set state to YES, update the timestamp, and try graduation when flipping from NO. `src/ParameterizedArbitration.sol:241-258`

`placeNoBond` is only valid from YES state, matches the current YES amount exactly, transfers WETH, refunds any replaced NO bond, sets state to NO, updates timestamp, and increments `totalActiveNoBonds`. `src/ParameterizedArbitration.sol:261-285`

## Timeout Settlement

`finalizeByTimeout` only works for YES or NO states after `lastStateChangeAt + TIMEOUT`. `src/ParameterizedArbitration.sol:291-301`

If the current side is YES and safety mode is active, timeout settlement reverts; if the current side is NO, the proposal's NO bond leaves the active NO aggregate. `src/ParameterizedArbitration.sol:303-309`, `src/ParameterizedArbitration.sol:443-449`

The winner receives the sum of YES and NO bonds through the withdrawable ledger, and the proposal becomes settled. `src/ParameterizedArbitration.sol:311-323`

## Graduation And Evaluation

The graduation threshold is `baseX * 2^queueLen`, and `_tryGraduate` refuses to enqueue when queued-plus-active evaluation count reaches `MAX_QUEUE`. `src/ParameterizedArbitration.sol:330-333`, `src/ParameterizedArbitration.sol:467-485`

`startNextEvaluation` moves the queue head into `EVALUATING` if no other evaluation is active. `src/ParameterizedArbitration.sol:343-361`

Only the configured evaluator can call `resolveActiveEvaluation`, and it settles the active evaluation to the accepted or rejected side. `src/ParameterizedArbitration.sol:363-388`

`FutarchyEvaluator` resolves an active evaluation by reading the bound futarchy proposal's CTF payouts, requiring a strict binary winner, and calling `resolveActiveEvaluation`. `src/FutarchyEvaluator.sol:66-101`

## UI Bridge

The bond UI reads `baseX`, `safetyModeActive`, proposal state, and withdrawable balances, then offers YES, NO, try-graduate, WETH wrap, and withdraw actions. `site-testnet/bonds.js:50-74`, `site-testnet/bonds.js:131-185`, `site-testnet/bonds.js:448-559`

The same UI documents that its proposal-address-derived arbitration ID is a stub bridge until a proper on-chain mapping replaces it. `site-testnet/bonds.js:19-26`

## How This Might Be Wrong

- If a future registry changes `DEFAULT_MAX_QUEUE`, per-instance queue assumptions need refreshing. `src/FutarchyRegistry.sol:166-167`
- If safety mode threshold changes from `baseX`, timeout-settlement risk changes. `src/ParameterizedArbitration.sol:443-449`
- If `FutarchyEvaluator` no longer uses CTF payout denominators, the evaluation section should cite the new evaluator. `src/FutarchyEvaluator.sol:76-101`
- If `bonds.js` moves from stub IDs to `FAOCreateAndBond`, the UI bridge section should be updated. `site-testnet/bonds.js:19-26`, `src/FAOCreateAndBond.sol:113-162`

## See Also

- [Proposal](30-proposal.md)
- [Resolve](50-resolve.md)
- [Invariants](../invariants.md)
- [FAO Repo](../README.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
