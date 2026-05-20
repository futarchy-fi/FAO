# Phase 5 Handoff: Live ≥10h Run

This document explains exactly what is needed to complete phase 5 of the
goal (live ≥10h continuous adversarial validation) given the in-tree
artifacts already committed on this branch.

## What is already complete

| Item | Status | Location |
|------|--------|----------|
| Sepolia deployment | ✅ Live | `docs/sepolia-deployment-v0.md` |
| First live promote | ✅ Tx `0xc42260d3...` block 10883925 | `docs/sepolia-deployment-v0.md` |
| In-tree 20h sim | ✅ 10 cycles, all asserts pass | `test/integration/Phase5Simulation.t.sol` + `docs/phase5-report.md` |
| In-tree 200h ext sim | ✅ 100 cycles, all asserts pass | `test/integration/Phase5ExtendedSimulation.t.sol` + `docs/phase5-extended-report.md` |
| Loop driver | ✅ Ready, 99 LOC bash | `script/agents/run_phase5.sh` |
| Metrics collector | ✅ Ready, 137 LOC Python | `script/agents/collect_metrics.py` |
| LegitProposer agent | ✅ | `script/agents/LegitProposer.s.sol` |
| AttackPreCreation agent | ✅ | `script/agents/AttackPreCreation.s.sol` |
| AttackBondGrief agent | ✅ | `script/agents/AttackBondGrief.s.sol` |
| AttackQueueStuff agent | ✅ | `script/agents/AttackQueueStuff.s.sol` |
| Daemon scaffold | ✅ | `script/daemon/submit.py` |

## What is needed to execute phase 5

### 1. Top up the operator wallet

The deployer wallet `0x693E3FB46Bb36eE43C702FE94f9463df0691b43d` has
~0.0006 ETH left after the initial deploys. Each promote costs
~0.017 ETH (15.6M gas × 1.07 gwei) — for 5 cycles over 10h that's
~0.1 ETH. Recommended: top up to **at least 0.15 ETH**.

Faucets (all require login or social):
- https://faucets.chain.link/sepolia
- https://www.alchemy.com/faucets/ethereum-sepolia
- https://faucet.quicknode.com/ethereum/sepolia
- https://sepolia-faucet.pk910.de/ (PoW-based, no login but slow)

### 2. Start the run_phase5.sh driver

```bash
export PRIVATE_KEY=0xfbd429c15314fef9e97ab7262b862ab0c907540f009208d27cf46340bca0ecb2
export DOCKER_HOST=unix:///run/user/$(id -u)/docker.sock
export RUN_HOURS=10

cd /home/kelvin/repos/futarchy-fi/FAO
tmux new-session -d -s phase5 './script/agents/run_phase5.sh > out/phase5.log 2>&1'
```

The driver:
- Spawns one `LegitProposer.s.sol` cycle every 2h (matching TIMEOUT)
- Logs each cycle to `out/phase5-events.log`
- Writes a header to `docs/phase5-report-live.md`
- Runs for `$RUN_HOURS` hours total

### 3. Start the metrics collector in parallel

```bash
pip install web3
tmux new-session -d -s phase5-metrics \
  'python3 script/agents/collect_metrics.py \
      --rpc https://eth-sepolia.api.onfinality.io/public \
      --factory 0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0 \
      --orchestrator 0x7DF66Fd816c09bb534136C5688B55BBA9398d262 \
      --resolver 0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a \
      --hours 10 > out/collector.log 2>&1'
```

The collector polls Sepolia every 60 seconds, logs every NewProposal +
OfficialProposalPromotedAndMigrated event to `out/phase5-metrics.csv`,
and continuously rewrites `docs/phase5-report-live.md` with aggregated
counters (proposals created, promotes succeeded, promotes reverted,
success rate, total gas).

### 4. Resolve the smoke proposal (one-time, +2h)

Once `block.timestamp >= 1778238164` (anchor + 2h of the first live
promote at block 10883925):

```bash
cast send 0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a \
    'resolve(address)' 0x233f2320f5d2ca1518c1cd5697d6839b875b0c78 \
    --rpc-url https://eth-sepolia.api.onfinality.io/public \
    --private-key $PRIVATE_KEY \
    --legacy --gas-price 1100000000
```

Expected: CTF receives payouts via `reportPayouts`, the YES or NO
outcome wins based on whichever pool TWAP averaged higher. Since no
trading happened in the window, both pools stayed at the init price
(sqrt(1)) — tick comparison strict `>` falls through to NO winning.

### 5. After the 10h window

The collector will rewrite `docs/phase5-report-live.md` one last
time at end-of-window. Commit that file:

```bash
git add docs/phase5-report-live.md out/phase5-metrics.csv out/phase5-events.log
git commit -m "phase5: live ≥10h adversarial run results"
git push
```

This completes the live evidence required by the goal.

## What this does NOT require

- **No on-chain code changes.** The stack on Sepolia is final for v0.
- **No new commits in src/ or test/.** Phase 5 is operational, not
  development.
- **No code review.** Same as above.
- **No off-tree state.** Everything is in this repo.

## Background on why this took two passes

The first orchestrator deployed (v1 at `0x2e23a85285bb...`) had
`observationCardinality = 1000` which required 20M gas per pool for the
`increaseObservationCardinalityNext` call inside the atomic promote —
exceeded the 8M gas limit attempted in the smoke test. Lowered to 100
in the deploy script default and redeployed (v2 at
`0x7DF66Fd816c09bb...`). v2's first promote at 15.6M gas confirmed the
fix.

This is documented in `docs/sepolia-deployment-v0.md` so the next time
someone deploys mainnet they pick a cardinality scaled to the
mainnet TWAP_WINDOW (24h vs 1h on testnet → roughly 24× more
observations needed; budget gas accordingly).
