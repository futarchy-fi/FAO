---
canonical: src/FAOTwapResolver.sol@15279877e01f6dea50b96bf056302060e3ab6214
scope: Authoritative for TWAP-based proposal resolution and CTF payout reporting.
not-scope: Bond-evaluation settlement is covered in [Arbitration](60-arbitration.md).
last-rebuilt: 2026-05-22T14:05:04Z
---
# Resolve

Resolution is the point where market prices become an on-chain CTF result. It matters because proposal acceptance is not final until the resolver reports binary payouts to Conditional Tokens. The canonical mechanism is `FAOTwapResolver.resolve`, which checks binding and timeout, computes normalized YES and NO average ticks over the TWAP window, stores the decision, reports `[1,0]` or `[0,1]` payouts, and emits the ticks used. `src/FAOTwapResolver.sol:117-144`

## Binding Before Resolution

The resolver constructor rejects invalid timing where the TWAP window is zero or longer than timeout. `src/FAOTwapResolver.sol:76-81`

`setOrchestrator` is one-shot: once `orchestrator` is nonzero, another call reverts. `src/FAOTwapResolver.sol:83-88`

Only the orchestrator can call `bindProposal`, and a proposal can bind only once because an existing `anchorTimestamp` causes `AlreadyBound`. `src/FAOTwapResolver.sol:90-115`

The binding stores YES pool, NO pool, company token, currency token, question ID read from the proposal, anchor timestamp, and resolution flags. `src/FAOTwapResolver.sol:37-49`, `src/FAOTwapResolver.sol:102-114`

## Timeout And Window

`resolve` computes `windowEnd = anchorTimestamp + TIMEOUT` and reverts with `TooEarly` if the current timestamp is before that end. `src/FAOTwapResolver.sol:117-125`

`windowEndOf` and `isReadyToResolve` expose the same timing rule for UIs and keepers. `src/FAOTwapResolver.sol:148-158`

The resolver reads observations for `[windowEnd - TWAP_WINDOW, windowEnd]` by calculating `secondsAgos` relative to the current block timestamp. `src/FAOTwapResolver.sol:162-190`

## Tick Normalization

The resolver identifies YES and NO company wrappers by reading `wrappedOutcome(0)` and `wrappedOutcome(1)` from the proposal. `src/FAOTwapResolver.sol:126-128`, `src/FAOTwapResolver.sol:200-206`

For each pool, the arithmetic mean tick is normalized so "currency per company" has the same sign across pool token orderings; if pool `token0` is the company wrapper, the tick is returned as-is, otherwise it is negated. `src/FAOTwapResolver.sol:171-198`

The decision rule is strict `yesAvgTick > noAvgTick`, so equal averages resolve to NO. `src/FAOTwapResolver.sol:126-141`

## Reporting To CTF

The resolver writes `resolved = true` and `accepted = accepted` before reporting payouts, then reports a two-element payout array to CTF: index 0 for accepted, index 1 for rejected. `src/FAOTwapResolver.sol:130-143`

The proposal contract exposes a convenience `resolve()` that simply calls `oracle.resolve(address(this))`, but the resolver can also be called directly. `src/FAOFutarchyProposal.sol:90-94`

## UI And Live Evidence

The proposals UI reads resolver bindings, `windowEndOf`, `isReadyToResolve`, and CTF payout numerators/denominator to render status. `site-testnet/sepolia.js:84-99`, `site-testnet/sepolia.js:217-260`

When a proposal is ready, the UI's resolve button calls `resolver.resolve(propAddr)` with the connected wallet. `site-testnet/sepolia.js:374-422`

The Sepolia deployment notes record a live resolve transaction where CTF payouts were reported and `accepted = false` after equal TWAPs fell through to NO. `docs/sepolia-deployment-v0.md:89-119`

## How This Might Be Wrong

- If outcome indexing changes in the factory or proposal, resolver YES/NO wrapper lookup could be stale. `src/FAOFutarchyFactory.sol:152-169`, `src/FAOTwapResolver.sol:200-206`
- If the decision rule adds a threshold or tie-breaker, the strict comparison summary becomes wrong. `src/FAOTwapResolver.sol:126-141`
- If CTF payout indices change, the `[1,0]` and `[0,1]` explanation must be rebuilt. `src/FAOTwapResolver.sol:135-141`
- If the UI switches to an indexer, the direct resolver reads in this page will no longer describe the frontend. `site-testnet/sepolia.js:217-260`

## See Also

- [Promote](40-promote.md)
- [Proposal](30-proposal.md)
- [Arbitration](60-arbitration.md)
- [What Is Futarchy](../../00-what-is-futarchy/README.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
- Build pass: 0 (first pass)
