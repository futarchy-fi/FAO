# Phase-5 adversarial validation agents

Long-running scripts that exercise the deployed FAO v0 stack under
real load: legitimate proposal flow + adversarial attacks across the
documented threat model (`docs/onchain-futarchy-design.md` §2.3).

## Roles

### Legitimate proposer (`LegitProposer.s.sol`)

Permissionless candidate creation via `FAOFutarchyFactory.createProposal`:

```solidity
FAOFutarchyFactory.CreateProposalParams memory p;
p.marketName = randomString();
p.description = randomDescription();
p.collateralToken1 = FAO;
p.collateralToken2 = WETH;
factory.createProposal(p);
```

Variants: vary marketName length, description, timing (random intervals
between submissions), and (off-chain) bond placement on the resulting
proposals via `FutarchyArbitration.placeYesBond` / `placeNoBond`.

### Adversary A1 (`AttackPreCreation.s.sol`)

Pre-create + initialize the conditional pools at predicted (per-prevrandao)
addresses to force the orchestrator into `PreCreated` reverts. The
prevrandao defense (commit 002) means the adversary cannot pre-compute
correct addresses across blocks; this agent's expected metric is
**0 successful blocks blocked per attempt**.

### Adversary A2 (`AttackPriorityOutbid.s.sol`)

Same-block frontrun: submit a high-priority createPool+initialize tx
targeting the addresses predicted from `block.prevrandao`. Build
locally with `forge script --broadcast --gas-price <high>`. Logs the
cost-per-attempted-block; expected to exceed our `TIP` plus the gas
of two pool initializations.

### Adversary A4 (`AttackTwapWashTrade.s.sol`)

Once conditional pools have liquidity inside the TWAP window, swap back
and forth to move the average tick. Logs cost-to-move-1-tick vs. our
orchestrator-deposited liquidity. Expected: cost scales ≥ √liquidity
(UniV3 concentrated cost), making meaningful manipulation impractical
for any non-trivial liquidity.

### Adversary A5 / A6 (`AttackBondGrief.s.sol`, `AttackQueueStuff.s.sol`)

Bond griefing: flip YES↔NO on the highest-stake live proposal.
Bond doubling rule (`FutarchyArbitration.placeYesBond` requires 2x the
last NO bond) makes each flip exponentially more expensive. Logs total
cost vs. number of timeouts delayed.

Queue stuffing: spam graduation bonds to fill `MAX_QUEUE` slots. Each
graduation bond is `baseX * 2^queueLen` so cost grows exponentially.

## Orchestration

`run_phase5.sh` (TODO) spins up:
- 2 legit proposer agents (`forge script ... --slow`).
- 4 adversary agents (one per A1, A2, A4, A5/A6 grouped).
- Metrics collector (parses event logs from the orchestrator + arbitration,
  writes CSV).

Target run: ≥ 10 hours wall-clock against a freshly deployed Sepolia
stack.

## Metrics emitted

Each agent writes per-attempt records to `out/phase5-metrics.csv`:

```
timestamp, agent, attempt_id, outcome (success/revert), gas_used, tip_eth, block_number
```

Aggregated by the collector at end-of-run into
`docs/phase5-report.md` with:

- Promote success / revert rates by attack vector.
- Defender cost (TIP × success_count).
- Adversary cost (gas × failed_attempts) by attack.
- Resolution latency from promote → settle.
- TWAP-vs-spot divergence at resolution time.

## Status

This README documents the planned agent suite. Implementations land in
commit 008 (Python orchestration script) and commit 009 (forge script
agents).
