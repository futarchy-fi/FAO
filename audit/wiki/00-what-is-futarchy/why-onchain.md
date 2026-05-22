---
canonical: docs/onchain-futarchy-design.md@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for why FAO v0 pushes proposal creation, promotion, and resolution on-chain.
not-scope: Contract wiring details are covered in [Architecture](../10-fao-repo/architecture.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Why Onchain

FAO v0 chooses on-chain futarchy so the settlement path can be inspected, replayed, and challenged with EVM state rather than off-chain discretion. It matters because pool pre-creation, wash trading, bond griefing, and observation failures are protocol threats, not just UX problems. The canonical mechanism is to make proposal addresses unpredictable until execution, initialize conditional pools atomically, anchor a TWAP window, and report the winning outcome directly to CTF. `docs/onchain-futarchy-design.md:37-88`, `docs/onchain-futarchy-design.md:137-208`, `src/FAOTwapResolver.sol:117-144`

## Verifiable Settlement

The design states that FAO v0 removes Reality.eth and computes settlement from UniV3 TWAP of conditional pools. `docs/onchain-futarchy-design.md:16-19`

The resolver implements that design by accepting only bound proposals, enforcing `anchorTimestamp + TIMEOUT`, computing average ticks from `pool.observe`, and calling `CTF.reportPayouts`. `src/FAOTwapResolver.sol:117-144`, `src/FAOTwapResolver.sol:162-198`

The result is not hidden in a daemon: the resolver stores `resolved` and `accepted` in its binding and emits the ticks used for the decision. `src/FAOTwapResolver.sol:37-49`, `src/FAOTwapResolver.sol:68-74`, `src/FAOTwapResolver.sol:132-143`

## MEV-Resistant Promotion

The design's first concrete attack is pool pre-creation: an adversary initializes a deterministic conditional pool at a bad price before promote. `docs/onchain-futarchy-design.md:63-75`

FAO reduces pre-creation by deriving `questionId` from `block.prevrandao`, factory address, and proposal index, then creating wrappers and pools inside the promote path. `src/FAOFutarchyFactory.sol:76-87`, `src/FAOOfficialProposalOrchestrator.sol:132-160`

The orchestrator still defends the final edge case: if a conditional pool already exists and is initialized, `_maybeCreatePoolAndInit` reverts with `PreCreated(pool)`. `src/FAOOfficialProposalOrchestrator.sol:204-228`

## Conditional Builder Payment

The design uses a builder tip as an asymmetric cost mechanism: the promote transaction pays `block.coinbase` only after the promotion succeeds, so a reverted bundle does not reach the tip transfer. `docs/onchain-futarchy-design.md:304-331`

The orchestrator code follows that order by paying `builderTip` after factory creation, pool setup, resolver binding, optional adapter migration, and refund logic. `src/FAOOfficialProposalOrchestrator.sol:121-178`

## Costly Delay, Not Silent Failure

Bond griefing and queue stuffing are modeled in the threat table, and their mitigations depend on exponential bond growth and queue caps rather than trust in an operator. `docs/onchain-futarchy-design.md:71-87`

The arbitration code makes those mitigations concrete: `placeYesBond` requires activation or flip thresholds, `placeNoBond` matches the current YES amount, `requiredYes(queueLen)` multiplies `baseX` by `2^queueLen`, and `_tryGraduate` rejects a full queue. `src/ParameterizedArbitration.sol:221-285`, `src/ParameterizedArbitration.sol:330-333`, `src/ParameterizedArbitration.sol:467-485`

## Trade-Offs

On-chain promotion is gas-heavy. The registry NatSpec says a single transaction deploying all per-instance contracts plus a spot pool crossed roughly 18.8M gas, so the registry exposes a two-phase creation path to fit public RPC estimate caps. `src/FutarchyRegistry.sol:31-49`

TWAP settlement is also dependent on observation capacity. The design identifies insufficient observation slots as A8, the orchestrator increases observation cardinality at promote time, and the resolver assumes adequate observations. `docs/onchain-futarchy-design.md:74-87`, `src/FAOOfficialProposalOrchestrator.sol:150-155`, `docs/commit-006-twap-resolver.md:99-107`

## How This Might Be Wrong

- If a future version uses an off-chain oracle again, the "verifiable settlement" section must be narrowed to historical FAO v0. `docs/onchain-futarchy-design.md:16-19`
- If `block.prevrandao` is removed from `computeQuestionId`, the pre-creation defense summary becomes false. `src/FAOFutarchyFactory.sol:76-87`
- If the builder tip is moved before migration or resolver binding, the cost-asymmetry explanation changes. `src/FAOOfficialProposalOrchestrator.sol:154-178`
- If a future AMM does not expose UniV3-style observation buffers, the A8 explanation needs a new failure mode. `docs/onchain-futarchy-design.md:74-87`

## See Also

- [What Is Futarchy](README.md)
- [Prior Art](prior-art.md)
- [Promote](../10-fao-repo/lifecycle/40-promote.md)
- [Invariants](../10-fao-repo/invariants.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
