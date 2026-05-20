# FAO v0 Sepolia deployment runbook

End-to-end checklist for taking the branch `arbitration/onchain-futarchy-v0`
from a clean checkout to a live Sepolia stack running adversarial agents.

Follows the goal set in `docs/onchain-futarchy-design.md`. References
specific commit numbers from this branch where relevant.

---

## 0. Prerequisites

- Sepolia RPC endpoint (Alchemy / Infura / public node).
- Sepolia ETH on an EOA used as deployer (this branch uses
  `0x693E3FB46Bb36eE43C702FE94f9463df0691b43d`; ≥ 0.05 ETH recommended).
- Docker installed (for foundry runs without GLIBC issues).
- Wrapped1155Factory address on Sepolia. Either:
  - Find a Seer-deployed instance, OR
  - Deploy a fresh copy:
    ```
    DOCKER_HOST=$DOCKER_HOST docker run --rm -v "$PWD:/work" -w /work \
      --user root ghcr.io/foundry-rs/foundry:stable \
      -c "forge create lib/seer-demo/contracts/src/Wrapped1155Factory.sol:Wrapped1155Factory \
          --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY"
    ```

## 1. Deploy FAO token (one-time)

```
forge script script/DeployFAO.s.sol \
  --rpc-url $SEPOLIA_RPC --broadcast -vvv \
  --private-key $PRIVATE_KEY
```

Capture `FAOToken deployed at <0xFAO>` from output. Distribute test FAO
to agent wallets (e.g., 100 FAO each) via `token.mint(addr, amount)`
calls.

## 2. Create FAO/WETH spot pool

Manually via cast or a tiny forge script:

```
# Create pool
cast send $UNIV3_FACTORY \
  "createPool(address,address,uint24)" \
  $FAO_TOKEN $WETH 500 \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY

# Read the pool address (UniV3 emits PoolCreated; cast call getPool also works)
SPOT_POOL=$(cast call $UNIV3_FACTORY \
  "getPool(address,address,uint24)(address)" \
  $FAO_TOKEN $WETH 500 --rpc-url $SEPOLIA_RPC)

# Initialize at price 1:1 (sqrtPrice = 2**96)
cast send $SPOT_POOL "initialize(uint160)" 79228162514264337593543950336 \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY

# Increase cardinality so TWAPs work
cast send $SPOT_POOL "increaseObservationCardinalityNext(uint16)" 1000 \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
```

Then add initial liquidity via `INonfungiblePositionManager.mint(...)`. This
step is omitted here for brevity but required before any conditional
markets are evaluated (otherwise spot price reads in the orchestrator
revert).

## 3. Deploy the FAO v0 stack

```
export PRIVATE_KEY=...
export FAO_TOKEN=0x...
export WRAPPED_1155_FACTORY=0x...
export SPOT_POOL=0x...
# (WETH, CTF, UNIV3_FACTORY, TIMEOUT_SECONDS, etc. all have Sepolia defaults)

forge script script/DeploySepoliaOnchainFutarchy.s.sol \
  --rpc-url $SEPOLIA_RPC --broadcast -vvv
```

Capture:
- `PROPOSAL_IMPL`
- `FUTARCHY_FACTORY`
- `TWAP_RESOLVER`
- `ORCHESTRATOR`
- `ARBITRATION`
- `EVALUATOR`
- `CTF_SETTLEMENT_ORACLE`
- `CTF_ROUTER`

Sanity-check post-deploy:

```
# Resolver knows the orchestrator (one-shot wire)
cast call $TWAP_RESOLVER "orchestrator()(address)" --rpc-url $SEPOLIA_RPC
# Factory uses our resolver as oracle
cast call $FUTARCHY_FACTORY "oracle()(address)" --rpc-url $SEPOLIA_RPC
# Arbitration knows the evaluator
cast call $ARBITRATION "evaluator()(address)" --rpc-url $SEPOLIA_RPC
```

## 4. End-to-end smoke test (manual)

Create a candidate proposal as any address:

```
cast send $FUTARCHY_FACTORY \
  "createProposal((string,string,address,address))" \
  '("test1","first test",'$FAO_TOKEN','$WETH')' \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
```

Promote it via the orchestrator (as ADMIN):

```
cast send $ORCHESTRATOR \
  "createOfficialProposalAndMigrate(string,string,uint256)" \
  "test1" "first test" 0 \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
```

Should emit `OfficialProposalPromotedAndMigrated` event.

After `TIMEOUT_SECONDS` (2h on this branch), call `resolve`:

```
PROPOSAL=$(cast call $FUTARCHY_FACTORY "proposals(uint256)(address)" 0 \
  --rpc-url $SEPOLIA_RPC)
cast send $TWAP_RESOLVER "resolve(address)" $PROPOSAL \
  --rpc-url $SEPOLIA_RPC --private-key $PRIVATE_KEY
```

CTF.payoutNumerators should now be non-zero for one of the two outcomes,
and `FutarchyCtfSettlementOracle.isSettled(proposal)` should return true.

## 5. Off-chain submission daemon (commit 008)

See `script/daemon/README.md`. The daemon submits the orchestrator
promote call via Flashbots Protect Sepolia + multi-builder. For Sepolia
testing, single-builder via Flashbots Sepolia relay is sufficient.

## 6. Phase-5 adversarial validation

See `script/agents/README.md`. Spin up:

- 2 legitimate proposer scripts (forge script `LegitProposer.s.sol`
  with random metadata + intervals).
- 1 each of `AttackPreCreation.s.sol`, `AttackPriorityOutbid.s.sol`,
  `AttackTwapWashTrade.s.sol`, `AttackBondGrief.s.sol`,
  `AttackQueueStuff.s.sol`.
- Metrics collector that parses event logs into
  `docs/phase5-report.md`.

Target: ≥ 10 hours wall-clock running concurrently.

Success criteria:

| Metric | Target |
|--------|--------|
| Successful pre-creation block (A1) | 0 |
| Successful pre-init survives orchestrator check | 0 |
| Promote success rate (no adversary) | ≥ 99% |
| Promote success rate (under adversary) | ≥ 95% across 10h |
| TWAP-vs-spot divergence at resolve | < 5% |
| Bond griefing cost / round | exponential growth confirmed |
| Defender ETH spent total | ≤ 10 × TIP (single eventual landing per proposal) |
| Adversary ETH spent total | logged, expected linear-in-blocks |

Commit `docs/phase5-report.md` at end of run.

## 7. Promotion checklist

Before claiming v0 done:
- [ ] Deploy script runs end-to-end on a fresh Sepolia checkout.
- [ ] Smoke test (step 4) succeeds.
- [ ] Daemon runs without errors for ≥ 1 hour.
- [ ] Each adversary script lands successfully in test (deliberately
      letting them through to verify defense triggers, then disabling).
- [ ] Phase-5 10h+ run completes; metrics committed.
- [ ] No new attack vectors discovered (else: retroactive `.md` doc in
      relevant component commit).
