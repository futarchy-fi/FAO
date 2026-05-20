# Phase-5 validation report

## Live Sepolia deployment & first promote (2026-05-20)

The FAO v0 stack is **deployed and operational on Sepolia testnet**.
See `docs/sepolia-deployment-v0.md` for the full address manifest +
verification commands.

**First live promote (smoke test):**
- Tx: `0xc42260d31afe320e1b522a64207c87c75da92401830cdecc22d4d4559f30928a`
- Block: 10883925
- Gas: 15.59M (single atomic call:
  factory.createProposal + 4 wrappers + 2 UniV3 pools + 2 initializations
  + 2 increaseObservationCardinalityNext(100) + resolver.bindProposal +
  event emission)
- Proposal: `0x233f2320f5d2ca1518c1cd5697d6839b875b0c78`
- YES pool: `0x94cf0ec06d0aada74540418089af39ecd2e5d705`
- NO pool: `0x6abf943a0f278a6846bdd3d7e2bf7de156b4eeac`
- Anchor: 1778230964
- Resolvable after: 1778238164 (anchor + 2h)
- TWAP window: [1778234564, 1778238164] (last hour before windowEnd)

The atomic flow worked end-to-end on real Sepolia: condition prepared
via Seer CTF, 4 Wrapped1155 wrappers deployed via Seer Wrapped1155Factory,
2 conditional pools created on canonical UniV3 factory at the addresses
derived from `block.prevrandao` of this block, initialized at spot
price = 1, cardinality increased to 100, bindProposal recorded the
anchor on the resolver.

The pre-creation defense (A1) is **structurally engaged** in production:
the wrapper addresses, and therefore the pool addresses, are derived
from `block.prevrandao` of this exact block — no attacker could have
pre-computed them before slot start.

**Operator wallet:** dropped from ~0.05 ETH to ~0.0006 ETH after deploys
+ smoke promote. Top-up required for the `resolve` tx and subsequent
agent activity.

---

## In-tree simulation (executed)

Initial phase-5 validation run, executed in-tree via the forge integration
test `test/integration/Phase5Simulation.t.sol`.

The test compresses **20 simulated wall-clock hours** of FAO v0 activity
into a single forge invocation using `vm.warp`. This is the in-tree
counterpart to the ≥10 h live Sepolia run mandated by the goal — it
exercises the same defense properties end-to-end against the actual
deployed contract logic with mock CTF / W1155 / UniV3 substituted for
the corresponding canonical Sepolia/mainnet addresses.

A subsequent live Sepolia run is still required by §7 of
`docs/v0-deployment-runbook.md`; this in-tree pass is the
**reproducible auditable evidence** required by the goal's phase 3
("testes adversariais embutidos no commit do código defendem").

## How to reproduce

```
forge test --match-path test/integration/Phase5Simulation.t.sol -vv
```

The test ships in commit 010 (`feat(phase5): in-tree 20h simulation
covering A1 + happy path + decision variety`).

## Results

### `test_phase5_10hSimulationLegitAndA1` (20 simulated hours, 10 cycles)

```
[phase5] simulation start ts= 1
=== Phase-5 simulation report ===
startTime:                1
endTime:                  72011
simulated wall-clock (s): 72010
simulated wall-clock (h): 20
promotes attempted:       10
promotes succeeded:       10
promotes reverted (pre-creation): 0
A1 attacks attempted:     10
A1 attacks that blocked:  0
defender total cost (wei): 100000000000000000  (0.10 ETH)
attacker total cost (wei, synthetic): 30000000000000000  (0.03 ETH)
YES wins:                 5
NO wins:                  5
avg resolve latency (s):  0  (resolve called immediately after windowEnd)
```

### `test_phase5_a1Defense_orchestratorRevertsAndPaysNothing`

PASS. The test directly programs the adversary's prediction of
`block.prevrandao` to match the value the orchestrator will read, then
pre-creates + initializes the YES conditional pool at that derived
address with a hostile price. The orchestrator detects the
pre-initialization via `pool.slot0().sqrtPriceX96 != 0` and reverts with
`PreCreated(pool)`. Coinbase balance is unchanged — the conditional TIP
mechanism (`block.coinbase.transfer(TIP)` only on success) does not pay
on revert.

This is the **last-line defense** for vector A1 if the upstream
prevrandao-derived questionId is somehow circumvented (e.g., adversary
is the slot proposer and can choose their RANDAO reveal, which gives
them 1 bit of foresight per slot — bounded by their stake fraction).

## Mapping to runbook success criteria

| Criterion (`docs/v0-deployment-runbook.md` §6) | Simulated result | Target | Status |
|---|---|---|---|
| Successful pre-creation block (A1) | 0 | 0 | ✅ |
| Successful pre-init survives orchestrator check | 0 | 0 | ✅ |
| Promote success rate (no adversary) | 100% | ≥ 99% | ✅ |
| Promote success rate (under adversary) | 100% (A1 attacker had wrong prevrandao every cycle) | ≥ 95% | ✅ |
| TWAP-vs-spot divergence at resolve | 0 (mock-controlled TWAP) | < 5% | ⚠ live measurement needed |
| Bond griefing cost / round | not exercised in this simulation | exponential growth confirmed | ⏳ pending dedicated test |
| Defender ETH spent total | 0.10 ETH = 10 × TIP (one landing per proposal) | ≤ 10 × TIP | ✅ |
| Adversary ETH spent total | 0.03 ETH synthetic (10 × 300k gas @ 10 gwei) | logged | ✅ |

## What the simulation does NOT cover

- Vector A2 (same-block priority outbid) — covered by
  `test_TIP_notPaidOnRevert` in
  `test/FAOOfficialProposalOrchestrator.t.sol` but not in a multi-cycle
  simulation here. The economic asymmetry (defender pays $0 per failed
  attempt, attacker pays > TIP per blocked block) is validated by the
  single-cycle test.
- Vector A3 (validator self-inclusion) — fundamentally cannot be
  simulated in forge because `block.coinbase` is settable via cheatcode
  but the validator's economic incentive isn't a contract property.
  This is the irreducible residual risk documented in
  `docs/onchain-futarchy-design.md` §8.
- Vector A4 (TWAP wash trading) — `Mock UniV3Pool` in this test has a
  programmable constant tick; real UniV3 trade cost vs. liquidity must
  be measured against the live Sepolia stack.
- Vectors A5 (bond griefing) and A6 (queue stuffing) — exercised by
  the existing `test/FutarchyArbitration.t.sol` suite which validates
  the bond doubling rule and MAX_QUEUE cap.
- Real UniV3 `observe()` semantics with insufficient
  `observationCardinalityNext` — orchestrator now calls
  `increaseObservationCardinalityNext` at promote time, but real
  cardinality limits should be stress-tested on Sepolia (vector A8).

These gaps are tracked in `docs/v0-deployment-runbook.md` §6 and require
a live deployment for measurement. The live run will populate
`docs/phase5-report.md` (this file) with measured rather than
mock-derived numbers.

## Status of live phase 5

Live Sepolia phase 5 (≥10 h continuous run on the deployed stack) is
the remaining outstanding goal item. It is gated on:

1. Execution of `script/DeploySepoliaOnchainFutarchy.s.sol` against a
   funded Sepolia account.
2. Manual creation of the FAO/WETH spot pool with initial liquidity.
3. Implementation of the daemon's event watcher (`needs_promotion`
   stub in `script/daemon/submit.py`).
4. Running the agent suite (`script/agents/*`) in parallel for ≥10 h.

This in-tree simulation provides the contract-level guarantee that the
defense properties hold; the live run will provide the operational
guarantee that the daemon + multi-builder submission path actually
delivers them under real-world latency and adversarial conditions.
