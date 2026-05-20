# Commit 006: FAOTwapResolver (UniV3 TWAP → CTF)

## Goal

Replace Reality.eth as the oracle that reports outcomes to the
Conditional Tokens Framework. The resolver reads TWAP from the two
conditional UniV3 pools, decides which outcome won, and calls
`CTF.reportPayouts(...)` directly.

## Contracts

- `src/FAOTwapResolver.sol` — the resolver.
- `test/FAOTwapResolver.t.sol` — full adversarial + happy path suite
  (12/12 passing).

## Wiring

The resolver is referenced as `oracle` in `FAOFutarchyFactory`, so the
CTF condition it prepares accepts payouts from this address. The
`FAOOfficialProposalOrchestrator` calls `resolver.bindProposal(...)`
inside its atomic promote flow.

```
+-------------+   bindProposal   +---------------+
| Orchestrator| ---------------> | FAOTwapResolver|
+-------------+                  +---------------+
                                        |
                                        | resolve(proposal)
                                        |   reads pool.observe()
                                        v
                                 +---------------+
                                 |  CTF.reportPay |
                                 +---------------+
```

`setOrchestrator` is one-shot — once set, no other address can bind
proposals.

## Resolution flow (commented in code)

For each proposal:
1. `bindProposal(...)` stores `(yesPool, noPool, companyToken,
   currencyToken, questionId, anchorTimestamp)`.
2. After `anchorTimestamp + TIMEOUT` elapses, anyone calls
   `resolve(proposal)`.
3. For each pool, read tick cumulatives at
   `[windowEnd - TWAP_WINDOW, windowEnd]` via `pool.observe(secondsAgos)`,
   compute the arithmetic mean tick.
4. Normalize each pool's tick so that "currency per company" → positive.
   The wrapper that wraps the company (FAO) token is identified by
   reading `FAOFutarchyProposal.wrappedOutcome(0)` / `wrappedOutcome(1)`
   (YES_company / NO_company respectively). If the pool's `token0` is
   the company wrapper, the tick is already in the correct orientation;
   otherwise it is negated.
5. `accepted = yesAvgTick > noAvgTick`.
6. `CTF.reportPayouts(questionId, accepted ? [1, 0] : [0, 1])`.

The decision is locked in storage (`resolved = true`, `accepted = ...`)
and the function reverts on subsequent calls.

## Adversarial / robustness tests

| Test | What it asserts |
|------|------------------|
| `test_setOrchestrator_oneShot` | Orchestrator can only be set once. |
| `test_bindProposal_revertsForNonOrchestrator` | Only orchestrator can bind. |
| `test_bindProposal_revertsOnDoubleBind` | A proposal can only be bound once. |
| `test_resolve_revertsBeforeWindowEnd` | TooEarly revert before anchor + TIMEOUT. |
| `test_resolve_allowedExactlyAtWindowEnd` | Resolution at exact windowEnd succeeds. |
| `test_decision_yesGreaterThanNo_accepts` | Higher YES TWAP → CTF payouts [1, 0]. |
| `test_decision_yesLessThanNo_rejects` | Higher NO TWAP → CTF payouts [0, 1]. |
| `test_orientation_invertedPoolTickIsNegated` | If pool's token0 is the currency wrapper, raw tick is negated before comparison — covers both orderings of YES/NO wrappers post-CREATE2. |
| `test_resolve_revertsIfAlreadyResolved` | Idempotency: double resolution rejected. |
| `test_resolve_revertsIfNotBound` | Unbound proposal cannot be resolved. |
| `test_windowEndOf_reportsAnchorPlusTimeout` | View consistent with config. |
| `test_isReadyToResolve_falseBefore_trueAfter` | Helper view tracks state. |

## TIMEOUT / TWAP_WINDOW configuration

| Network | TIMEOUT | TWAP_WINDOW |
|---------|---------|-------------|
| Sepolia (this branch) | 2 h | 1 h |
| Mainnet target | 72 h | 24 h |

Both are constructor immutables. The branch-as-config pattern keeps
the values audit-visible.

## Threat coverage

| Vector | Handled by |
|--------|-----------|
| A4 (wash trading inside window) | Orchestrator-deposited dominant liquidity makes cost-to-move TWAP scale with √liquidity. Long window dilutes single-block manipulation. |
| Resolution race | `resolved` flag + idempotent storage. |
| Premature resolve | `TooEarly` revert. |
| Unauthorized bind | `NotOrchestrator` revert. |
| Reporting wrong questionId | questionId is captured at bind time from `FAOFutarchyProposal.questionId()`; the resolver does not accept it as an argument from the caller of `resolve()`. |
| Orientation bug | Both YES and NO pools are normalized via the company-wrapper-as-token0 check. The test `test_orientation_invertedPoolTickIsNegated` covers the inverted ordering. |

## Not in this commit

- Real UniV3 pool observations from a fork — the mocks here program a
  constant tick. Mainnet/Sepolia fork tests with actual `UniswapV3Pool`
  observe() come in the integration phase.
- Liquidity adapter (commit 007).
- Cardinality monitoring (the orchestrator calls
  `increaseObservationCardinalityNext` at promote time; the resolver
  assumes adequate cardinality and reverts via UniV3 if not).
