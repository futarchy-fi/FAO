# Commit 007: Sepolia deploy script + CtfRouter

## Goal

Provide a single forge script that lays down the full FAO v0 on-chain stack
on Sepolia testnet on top of the Seer-deployed CTF and the canonical
UniswapV3 / Wrapped1155Factory deployments.

## Files

- `src/CtfRouter.sol` — minimal `IFutarchyConditionalRouter` wrapping a Gnosis CTF.
  Only `getWinningOutcomes` is functional (used by `FutarchyCtfSettlementOracle`);
  split/merge/redeem revert with `NotImplemented` (not needed in v0 — the
  resolver writes payouts directly to CTF).
- `script/DeploySepoliaOnchainFutarchy.s.sol` — the deploy script.

## What the script deploys (in order)

1. `FAOFutarchyProposal` implementation (cloneable template for the factory).
2. `FAOTwapResolver` (TIMEOUT, TWAP_WINDOW, CTF).
3. `FAOFutarchyFactory` (proposalImpl, CTF, Wrapped1155Factory, resolver).
4. `FAOOfficialProposalOrchestrator` (admin, factory, UniV3Factory, spotPool,
   FAO, WETH, fee, observationCardinality, resolver).
5. `resolver.setOrchestrator(orchestrator)` — one-shot wiring.
6. `FutarchyArbitration` (self-contained, reads WETH + sets baseX from
   constructor on this branch).
7. `CtfRouter` (CTF).
8. `FutarchyCtfSettlementOracle` (router).
9. `FutarchyEvaluator` (arbitration, CTF, owner).
10. `arb.setEvaluator(evaluator)`.

Output: addresses are printed to console for env capture.

## External dependencies (Sepolia defaults)

| Dep | Address |
|-----|---------|
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| ConditionalTokens (Seer) | `0x8bdC504dC3A05310059c1c67E0A2667309D27B93` |
| UniswapV3 Factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |
| Wrapped1155Factory | `WRAPPED_1155_FACTORY` env var (Seer-deployed; address TBD on Sepolia, override per environment) |
| Spot pool (FAO/WETH) | `SPOT_POOL` env var (pre-created — see Pre-deploy steps) |

## Required env vars

```
PRIVATE_KEY                   deployer EOA
FAO_TOKEN                     pre-deployed FAOToken (use DeployFAO.s.sol first)
WETH                          (default Sepolia WETH)
CTF                           (default Seer Sepolia)
WRAPPED_1155_FACTORY          must be set explicitly
UNIV3_FACTORY                 (default Sepolia canonical)
SPOT_POOL                     pre-created FAO/WETH pool address
FEE_TIER                      (default 500 = 0.05%)
OBSERVATION_CARDINALITY       (default 1000)
TIMEOUT_SECONDS               (default 7200 = 2h)
TWAP_WINDOW_SECONDS           (default 3600 = 1h)
```

## Pre-deploy steps (manual, one-time)

1. **Deploy FAO** — `forge script script/DeployFAO.s.sol --rpc-url $SEPOLIA_RPC
   --broadcast`. Capture the token address.
2. **Find Wrapped1155Factory on Sepolia.** Seer-deployed; address must be
   sourced from their deployment manifest or by reading from a known
   FutarchyFactory deployment. Failing that: `forge create` a new copy from
   `lib/seer-demo/contracts/src/Wrapped1155Factory.sol`.
3. **Create the FAO/WETH UniV3 spot pool.**
   - `UniswapV3Factory.createPool(FAO, WETH, 500)`.
   - `pool.initialize(sqrtPriceX96)` at chosen launch price.
   - `pool.increaseObservationCardinalityNext(1000)`.
   - Add initial liquidity (e.g., via `INonfungiblePositionManager.mint`).
4. **Distribute test FAO** to agent wallets and ad-hoc participants.
5. **Run the deploy script.**
6. Save the printed addresses into env files for the daemon and agents.

## Post-deploy verification (manual)

- `factory.oracle() == resolver`.
- `resolver.orchestrator() == orchestrator`.
- `arb.evaluator() == evaluator`.
- `arb.WETH() == WETH`.
- Try `factory.computeQuestionId("test", "", 0)` from console and check it
  depends on `block.prevrandao`.

## What's NOT in this commit

- The UniswapV3 liquidity adapter contract (orchestrator works without it;
  adapter migration is skipped if `adapter` is unset).
- The off-chain submission daemon (Flashbots multi-builder).
- Agent scripts for phase-5 validation.

These come in commits 008–010.

## Build

`forge build --skip test` — clean. Full non-fork test suite: 159 / 159
passing.

## Why all-in-one script

The orchestrator and resolver have a circular dependency (orchestrator
references resolver in constructor; resolver's `setOrchestrator` is called
after). Doing this in a single script avoids hand-wiring mistakes in
multi-step deployments.
