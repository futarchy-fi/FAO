# Commit 005: FAOOfficialProposalOrchestrator (atomic + sanity check + TIP)

## Goal

Implement the core MEV-resistant proposal promotion flow described in
`docs/onchain-futarchy-design.md` §3.2.

## What this commit ships

- `src/interfaces/IUniswapV3FactoryLike.sol` — `getPool` / `createPool`.
- `src/interfaces/IUniswapV3PoolLike.sol` — `slot0`, `initialize`,
  `observe`, `increaseObservationCardinalityNext`, `mint`.
- `src/interfaces/IFAOFutarchyOracle.sol` — adds
  `IFAOFutarchyTwapResolver` extension with `bindProposal(...)`.
- `src/FAOOfficialProposalOrchestrator.sol` — the atomic orchestrator.
- `test/FAOOfficialProposalOrchestrator.t.sol` — full adversarial
  suite with mocks for CTF, Wrapped1155Factory, UniV3 Factory/Pool,
  resolver, and a noop liquidity adapter.

## Atomic flow (single tx)

1. Read spot price + tick from canonical UniV3 FAO/WETH pool (`SPOT_POOL`).
2. Record `anchorTimestamp = block.timestamp`.
3. Call `FAOFutarchyFactory.createProposal(...)`. This creates the CTF
   condition + 4 Wrapped1155 outcome tokens. The factory's questionId
   derives from `block.prevrandao`, so the pool addresses we will use
   are unpredictable from any prior block (closes A1 — see commit 002).
4. Read the 4 wrapper addresses from the resulting proposal.
5. For each of the 2 conditional pools (YES_co/YES_cur, NO_co/NO_cur):
   - `getPool` to check for pre-existence.
   - If exists AND `slot0.sqrtPriceX96 != 0` → `revert PreCreated(pool)`.
   - Else `createPool` + `initialize` at spot price.
6. `increaseObservationCardinalityNext(N)` on both pools so TWAP `observe()`
   has enough observation slots over the resolution window.
7. `RESOLVER.bindProposal(...)` registers the proposal, pool addresses,
   and anchor timestamp.
8. If an adapter is wired: `adapter.migrate(...)` moves spot → conditional
   liquidity.
9. If `builderTip > 0`: `block.coinbase.transfer(builderTip)` —
   conditional payment to the block builder.
10. Refund any excess `msg.value` to `msg.sender`.
11. Emit `OfficialProposalPromotedAndMigrated`.

A revert at any step rolls back the whole tx (including the TIP transfer).
Combined with Flashbots' default bundle drop-on-revert, the defender pays
$0 per failed attempt and only `gas + TIP` once on eventual success.

## Adversarial tests (7/7 passing)

| Test | Defense vector | What it asserts |
|------|----------------|------------------|
| `test_happyPath_createsCondtionPoolsAndBinds` | — | Promotion succeeds end-to-end; resolver receives correct bind; both pools initialized. |
| `test_A1_revertsIfConditionalPoolPreInitialized` | **A1** | Pre-creating a pool at the predicted YES address with hostile price causes the orchestrator to revert with `PreCreated(pool)`. This is the last-line defense after the prevrandao questionId derivation (commit 002). |
| `test_TIP_paidToCoinbaseOnSuccess` | TIP economics | `block.coinbase.transfer(TIP)` lands when the full flow succeeds. |
| `test_TIP_notPaidOnRevert` | TIP economics | On revert (A1 pre-creation), no TIP reaches the coinbase. This is the property that makes failed attempts cost $0 to the defender under Flashbots' drop-on-revert default. |
| `test_adapter_isInvokedWhenSet` | wiring | Liquidity adapter is called within the atomic flow when set. |
| `test_adapter_cannotBeSetTwice` | wiring safety | One-shot adapter wiring. |
| `test_onlyAdminCanCreateOfficialProposal` | access | Non-admin caller reverts with `NotAdmin`. |

## Why this is mainnet-ready, not a testnet-only shim

- Uses canonical UniV3 Factory and canonical Wrapped1155Factory — no
  forks, no custom AMM (see design doc §4.3).
- The TIP mechanism is generic block-coinbase payment, supported on
  every EVM since the merge.
- The prevrandao defense applies post-merge mainnet identically to Sepolia.
- Constants (FEE_TIER, OBSERVATION_CARDINALITY) are constructor params,
  so the same bytecode handles both testnet and mainnet.

## via_ir build flag

`createOfficialProposalAndMigrate` has enough locals + memory to trigger
"stack too deep" with the legacy codegen. `foundry.toml` now sets
`via_ir = true` for the default profile. All existing tests still pass
(147/147 non-fork).

## What this commit does NOT include

- The real liquidity adapter (it's an interface with a noop mock here).
  See commit 006 (UniswapV3LiquidityAdapter).
- The real TWAP resolver implementation — bind storage only. The actual
  `observe()` + payout logic comes in commit 007 (refactor of
  `FutarchyTWAPOracle.sol` for UniV3 + CTF).
- Off-chain Flashbots multi-builder submission daemon. Commit 008.
