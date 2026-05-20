# FAO v0: On-Chain Futarchy Design

Status: design / pre-implementation
Branch: `arbitration/onchain-futarchy-v0`
Target deploy: Sepolia testnet → Ethereum mainnet

---

## 1. Problem and Scope

FAO (Futarchy Arbitration Organization) v0 implements **100% on-chain futarchy
governance**: every proposal is decided by a market mechanism whose outcome is
read directly from EVM state, with no human oracle, no community veto, and no
voting.

Existing Seer-style futarchy stacks rely on **Reality.eth** as the oracle that
settles the Conditional Tokens Framework (CTF) condition. v0 explicitly removes
that dependency. The settlement signal is computed from **UniV3 TWAP of the
conditional pools** and written to the CTF via a custom resolver contract.

Scope of v0 (this branch):

- Cheap, permissionless proposal creation.
- Bond-escalation arbitration game (existing `FutarchyArbitration.sol`).
- Atomic, MEV-resistant proposal promotion (the focus of this document).
- TWAP-based settlement reporting to the CTF.
- Sepolia testnet deployment on top of CTF/Reality already deployed by Seer.
- Stress-test phase with adversarial agents (≥10h continuous run).
- Mainnet-ready code from day one (testnet fast-mode = same code, different
  constants, separate branch for visibility).

Out of scope for v0: cross-chain, gasless UX, full UI, governance of
governance, treasury operations beyond market settlement.

---

## 2. Threat Model

### 2.1 Asset under attack

The promotion step of a proposal initializes **two conditional pools**
(YES_company/YES_currency and NO_company/NO_currency) on canonical UniV3, with
prices anchored to the spot pool (FAO/WETH). Those pools' TWAP over a fixed
post-promote window is the final settlement signal.

### 2.2 Attacker capabilities

We assume the adversary can:

- Submit arbitrary transactions to the public mempool.
- Submit private bundles to MEV-Boost builders.
- Pay arbitrary gas/priority fees.
- Spin up validators (within their stake fraction).
- Run keepers/bots that pre-compute deterministic CREATE2 addresses.
- Maintain attacks across many blocks for sustained periods.

We do **not** assume:

- Control of >50% of validators / builders.
- Ability to predict `block.prevrandao` of future blocks they do not propose.
- Ability to replicate `msg.sender` of the orchestrator.

### 2.3 Concrete attack vectors considered

| # | Vector | Mechanism |
|---|--------|-----------|
| A1 | **Pool pre-creation** | Adversary calls `UniswapV3Factory.createPool(t0, t1, fee)` + `pool.initialize(badPrice)` at CREATE2-deterministic address before our promote. Our promote sees pre-initialized pool, can't re-init, manipulated TWAP. |
| A2 | **Same-block priority outbid** | Adversary submits high-priority pre-create tx in same block as our promote. Builder ranks adversary first, our bundle reverts. |
| A3 | **Validator self-inclusion** | Adversary is the slot proposer; inserts their own pre-create tx at index 0 of the block. |
| A4 | **Wash trading inside TWAP window** | Adversary trades against own liquidity in conditional pools during the TWAP window to push the average. |
| A5 | **Bond griefing** | Adversary repeatedly flips bond on a target proposal to delay timeout settlement. |
| A6 | **Queue stuffing** | Adversary fills the graduation queue with throwaway proposals to delay legitimate ones. |
| A7 | **Hostile builder censorship** | Adversary controls a builder that drops our bundles. |
| A8 | **TWAP observation insufficiency** | Pool's `observationCardinalityNext` too low → `observe()` reverts. |

### 2.4 Mitigation summary (full rationale in §4)

| # | Vector | Mitigation |
|---|--------|------------|
| A1 | Pre-creation | Question ID derives from `block.prevrandao` → addresses unpredictable across blocks → adversary cannot pre-create. |
| A2 | Same-block outbid | Bundle ends with `block.coinbase.transfer(TIP)`; builder picks max(TIP, attacker fee). Defender raises TIP → attacker per-block cost grows linearly. |
| A3 | Validator self-inclusion | Cannot fully prevent in EVM. Cost = 1 proposer reward (~0.04 ETH) + validator stake fraction. Attack rate bounded by adversary stake share. |
| A4 | TWAP wash trading | Sufficient orchestrator-deposited liquidity dilutes wash trades; cost-to-move-TWAP scales with √liquidity. Anchor + window length chosen to absorb noise. |
| A5 | Bond griefing | Bond doubling rule makes each flip exponentially more expensive (existing `FutarchyArbitration`). |
| A6 | Queue stuffing | `MAX_QUEUE` cap forces adversary to keep paying graduation bonds; tryGraduate drainage exists. |
| A7 | Hostile builder | Multi-builder submission (Flashbots, BloXroute, Titan, Beaver, Rsync...). ≥1 honest builder suffices. |
| A8 | Observation slots | Orchestrator calls `pool.increaseObservationCardinalityNext(N)` at promote with N sized for TWAP window. |

### 2.5 Why simpler defenses were rejected

We considered and rejected several mitigations before landing on prevrandao +
conditional TIP + drop-on-revert. Each is documented to prevent rediscovery:

- **Hardcoded zero nonce in questionId (current Seer)**: deterministic, fully
  pre-creatable. Trivial DoS.
- **block.number in questionId**: addresses change per block but `block.number`
  is publicly predictable for any future block. Adversary pre-creates pools in
  past blocks at predicted future-block addresses; sustained cost ~$9/block.
  Linear cost but cheap per block, sustainable.
- **Monotonic nonce-loop with skip**: orchestrator probes nonces in a loop,
  skips pre-created ones. Bounded by `MAX_PROBE` × gas; adversary fills nonces
  cheaply across many blocks until our tx OOGs. Economic DoS scalable to
  ~$0.50/nonce.
- **Wrapped1155Factory data versioning**: derive different wrappers via `data`
  field of `requireWrapped1155`. Same problem as nonce-loop; adversary
  predicts `data` and pre-creates.
- **Atomic arbitrage-then-deposit**: orchestrator swaps to push manipulated
  pool back to spot before depositing. Fails for concentrated liquidity (full-
  range adversary positions make arbitrage cost unbounded).
- **Fork UniV3Factory with onlyOrchestrator access control**: works but loses
  composability with the canonical Uniswap ecosystem. Acceptable for
  conditional pools (no real user need) but unnecessary given the prevrandao
  defense works without forking.
- **Custom AMM (UniV2-style)**: works but adds audit surface; UniV3 canonical
  is preferred for TWAP and liquidity tooling.

---

## 3. Architecture

### 3.1 Components

| Contract | Origin | Role |
|----------|--------|------|
| `FutarchyArbitration` | this repo | Bond-escalation arbitration game, graduation queue. |
| `FutarchyEvaluator` | this repo | Reads CTF payouts after settlement, calls `arbitration.resolveActiveEvaluation`. |
| `FutarchyCtfSettlementOracle` | this repo | Reads CTF `payoutNumerators` to determine if a proposal is settled. |
| `FutarchyOfficialProposalOrchestrator` | this repo (refactored) | Atomic, MEV-resistant promotion of candidate proposals. Creates condition + wrappers + pools + initializes + migrates liquidity + binds resolver. Pays builder TIP at end. |
| `FutarchyOfficialProposalSource` | this repo | SnapshotX integration source. |
| `FutarchyTwapResolver` | this repo (refactored from `FutarchyTWAPOracle.sol`) | Reads UniV3 TWAP at resolution time, reports payouts to CTF. |
| `UniswapV3LiquidityAdapter` | this repo (new) | UniV3 implementation of `IFutarchyLiquidityAdapter`. Mints/burns liquidity via `pool.mint()` direct (no NPM). |
| `FutarchyFactory` (Seer fork) | `lib/seer-demo` (patched) | Creates conditional markets. Patched to derive `questionId` from `block.prevrandao` and drop Reality.eth from the hash. |
| `FutarchyProposal`, `FutarchyRouter` | `lib/seer-demo` | Unmodified Seer contracts. |
| `UniswapV3Factory`, `UniswapV3Pool`, `Wrapped1155Factory` | canonical Sepolia/mainnet | External, untouched. |
| `ConditionalTokens` | canonical Sepolia (Seer-deployed) | External. |

### 3.2 Atomic promote flow

The full promotion happens in **one transaction**:

```
                  ┌─────────────────────────────────────────────────────────┐
                  │  Orchestrator.createOfficialProposalAndMigrate()        │
                  │  (sent via Flashbots bundle, multi-builder)              │
                  └─────────────────────────────────────────────────────────┘
                                            │
                                            ▼
                                  rand = block.prevrandao
                                            │
        ┌───────────────────────────────────┼───────────────────────────────────┐
        ▼                                   ▼                                   ▼
  Compute deterministic                Read spot price             Set anchor
  addresses for THIS block:            of FAO/WETH UniV3            t_promote = block.timestamp
   - questionId(rand)                  pool (canonical)
   - conditionId
   - 4 wrappers
   - 2 conditional pools
        │
        ▼
  Sanity check:
   for pool in [yesPool, noPool]:
       if pool.slot0.sqrtPriceX96 != 0  ──► revert PreCreated()
   for wrapper in [w0, w1, w2, w3]:
       if wrapper deployed and ERC20.totalSupply > 0 ──► revert
        │
        ▼
  FutarchyFactory.createProposal(rand)
   → creates CTF condition with questionId(rand) and our TwapResolver as oracle
        │
        ▼
  For each outcome i ∈ {0,1,2,3}:
       Wrapped1155Factory.requireWrapped1155(...)
        │
        ▼
  For pool in [(w_YES_co, w_YES_cur), (w_NO_co, w_NO_cur)]:
       UniswapV3Factory.createPool(token0, token1, FEE)
       pool.initialize(sqrtPriceX96_spot)
       pool.increaseObservationCardinalityNext(N_observations)
        │
        ▼
  UniswapV3LiquidityAdapter:
       mint conditional tokens from CTF
       wrap into the four ERC20 wrappers
       pool.mint(...) into both conditional pools
        │
        ▼
  twapResolver.bindProposal(
       proposalId, conditionId, yesPool, noPool, t_promote
  )
        │
        ▼
  proposalSource.setOfficialProposalFromOfficialProposer(proposalId, proposal)
        │
        ▼
  if msg.value > 0:
       block.coinbase.transfer(TIP)   ◄── conditional payment to builder
                                          (only reached on full success)
        │
        ▼
  emit OfficialProposalPromotedAndMigrated(...)
                                            │
                                            ▼
                            (committed to chain by builder)
```

Reverts at any point cause the entire transaction (including the TIP
transfer) to revert. The Flashbots bundle is then dropped — no on-chain
footprint, no fees paid.

### 3.3 Resolution flow

```
  At t_promote + TIMEOUT (= 2h on testnet, 72h mainnet target):
      Anyone (e.g., evaluator daemon) calls twapResolver.resolve(proposalId)
                                  │
                                  ▼
                  fetch (yesPool, noPool, t_promote) from bind storage
                                  │
                                  ▼
        windowStart = t_promote + TIMEOUT - TWAP_WINDOW (default 1h)
        windowEnd   = t_promote + TIMEOUT
                                  │
                                  ▼
        revert if block.timestamp < windowEnd
                                  │
                                  ▼
   secondsAgos = [windowEnd - block.timestamp + TWAP_WINDOW,
                   windowEnd - block.timestamp]
   (yesPool.observe(secondsAgos), noPool.observe(secondsAgos))
                                  │
                                  ▼
        yesAvgTick = (cumYes[1] - cumYes[0]) / TWAP_WINDOW
        noAvgTick  = (cumNo[1]  - cumNo[0])  / TWAP_WINDOW
                                  │
                                  ▼
        normalize tick orientation to "currency per company"
                                  │
                                  ▼
        decision: accepted = (yesAvgTick > noAvgTick)
                                  │
                                  ▼
        conditionalTokens.reportPayouts(
            questionId(proposalId),
            accepted ? [1, 0] : [0, 1]
        )
                                  │
                                  ▼
        FutarchyCtfSettlementOracle.isSettled(proposalId) → true
                                  │
                                  ▼
        anyone calls FutarchyEvaluator.evaluate(proposalId)
                                  │
                                  ▼
        evaluator.resolveActiveEvaluation(proposalId, accepted)
                                  │
                                  ▼
        FutarchyArbitration moves to RESOLVED state
        payouts distributed via pull-payment ledger
```

### 3.4 Off-chain orchestration

Promotion needs a small operator daemon:

1. Watch FutarchyFactory for `CandidateProposalCreated` events.
2. Each block:
   - Estimate `block.prevrandao` of next slot? **No — we cannot.** Instead,
     submit a bundle that *reads* `block.prevrandao` at exec time and
     proceeds. We do not need to pre-compute addresses off-chain; we trust the
     on-chain sanity check.
   - Build bundle: orchestrator call + TIP via `msg.value`.
   - Submit to Flashbots, BloXroute, Titan, Beaver, Rsync, etc.
3. If bundle drops (reverts), retry next block.
4. On success, monitor TWAP window; submit `resolve()` after `windowEnd`.

The orchestrator's `createOfficialProposalAndMigrate` is **idempotent in
spirit**: if it executes successfully, the proposal is officially promoted;
if it reverts, no state changes. Multiple parallel bundles racing the same
slot are safe — only one will land.

---

## 4. Key Design Decisions and Rationale

### 4.1 `block.prevrandao` in `questionId` derivation

**Decision:** `questionId = keccak256(content_hash, arbitrator, timeout,
minBond, address(factory), block.prevrandao)`.

**Why:** `block.prevrandao` is set by the proposer's RANDAO reveal at slot
start. A non-proposer adversary cannot predict it before the slot begins,
because predicting it requires the proposer's BLS private key. Therefore the
adversary cannot pre-compute conditional pool addresses for future blocks and
cannot pre-create pools at those addresses.

**Asymmetry created:** the adversary is reduced to same-block attacks (vector
A2 or A3), which are gated by economic competition (see §4.2) or by validator
stake share (A3).

**Trade-off:** `prevrandao` has ~1 bit of proposer manipulation (last-bit
withhold by skipping a slot, costing the proposer their reward ~0.04 ETH).
This is acceptable.

### 4.2 Conditional builder TIP via `block.coinbase.transfer`

**Decision:** orchestrator's final opcode (after all state-changing work
succeeds) is `block.coinbase.transfer(TIP)`. Bundle is submitted with
`msg.value = TIP`.

**Why:** combined with Flashbots' default bundle drop-on-revert policy,
defender pays $0 on every failed attempt and pays only `TIP` once on success.

**Economic asymmetry:**
- Defender: total cost = TIP (one-shot, on success).
- Adversary executing A2 (same-block outbid): must pay
  `(adversary_priority × gas) > TIP` per block sustained. Raising TIP linearly
  raises adversary's per-block cost.
- Adversary executing A1 (past-block pre-creation): impossible if A1 is
  closed by §4.1.

**Concrete numbers** (10 gwei mainnet base fee, ~300k gas per attack
attempt = 2 pools × (create + initialize)):

| TIP | Defender total | Adversary per blocked block |
|-----|----------------|------------------------------|
| 0.01 ETH (~$25) | ~$25 | ≥ ~$34 |
| 0.1 ETH (~$250) | ~$250 | ≥ ~$259 |
| 1 ETH (~$2500) | ~$2509 | ≥ ~$2509 |

Defender total is constant; adversary cost is linear in blocks attacked.
Defender wins by attrition for any finite adversary budget.

### 4.3 Canonical UniV3 + canonical Wrapped1155Factory (no forks)

**Decision:** use canonical UniV3 factory (Sepolia
`0x0227628f3F023bb0B980b67D528571c95c6DaC1c`, mainnet
`0x1F98431c8aD98523631AE4a59f267346ea31F984`) and canonical
Wrapped1155Factory. No forks, no custom AMM.

**Why:** §4.1 already closes the pre-creation vector. Forking would lose
composability with the broader Uniswap ecosystem (aggregators, NPM, info
sites) for the FAO/WETH spot pool, which is a real loss.

For conditional pools specifically, the canonical-vs-custom distinction is
neutral (no real user goes to app.uniswap.org for `YES_FAO_PROP123`). But
since canonical works security-wise, no reason to fork.

### 4.4 Anchor TWAP window at `t_promote`

**Decision:** TWAP measurement window is fixed at `[t_promote + TIMEOUT -
TWAP_WINDOW, t_promote + TIMEOUT]`. `t_promote = block.timestamp` at promote
time, recorded in `TwapResolver.bindProposal`.

**Why:**
- Any pre-promote price manipulation (if A1 succeeded) is outside the window,
  irrelevant.
- All proposals get the same TWAP duration regardless of when in the proposal
  lifecycle they are evaluated.
- Resolution is permissionless: anyone can call `resolve()` after
  `windowEnd`.

### 4.5 Orchestrator deposits dominant liquidity

**Decision:** orchestrator deposits 80% of spot liquidity into the
conditional pools at promote time (existing `FutarchyLiquidityManager`
behavior, ported to UniV3).

**Why:** wash-trading attack A4 cost-to-move scales with √liquidity.
Concentrated liquidity in our chosen range (around spot tick) makes TWAP
manipulation prohibitively expensive vs the bond outcomes at stake.

### 4.6 Multi-builder submission

**Decision:** the operator daemon submits bundles to Flashbots, BloXroute,
Titan, Beaver, Rsync, and any other major builders.

**Why:** single-builder submission is vulnerable to that builder being
adversarial (or being the adversary). ≥1 honest builder suffices for the
bundle to land. Major builders are economically motivated to include
high-TIP bundles.

---

## 5. Economic Asymmetry Summary

The full v0 defense relies on these inequalities:

```
defender_total_cost = TIP            (paid once)
adversary_per_block_cost ≥ TIP       (must outbid every blocked block)
attack_blocks_required → ∞           (defender retries forever)

⇒ adversary_total_cost → ∞ unless they stop
⇒ defender eventually wins
```

For an adversary willing to spend $1M on a single proposal:
- At TIP = 0.01 ETH (~$34/block adversary cost), adversary can sustain ~8 days.
- At TIP = 0.1 ETH (~$259/block), adversary can sustain ~1 day.
- At TIP = 1 ETH (~$2509/block), adversary can sustain ~7 hours.

The defender can ratchet TIP in response to sustained attack, forcing higher
adversary cost. Defender's TIP cost is paid only on the eventual success.

---

## 6. Parameters

### 6.1 Testnet (Sepolia, this branch)

| Parameter | Value | Reason |
|-----------|-------|--------|
| `WETH` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` | Sepolia WETH |
| `CTF` | `0x8bdC504dC3A05310059c1c67E0A2667309D27B93` | Sepolia, Seer-deployed |
| `UniV3 Factory` | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` | Sepolia canonical |
| `TIMEOUT` | 2 hours | Fast iteration |
| `TWAP_WINDOW` | 1 hour | Fast iteration |
| `FEE_TIER` | 500 (0.05%) | Standard tier |
| `baseX` | 0.001 ether | Low friction test bonds |
| `MAX_QUEUE` | 3 | Small queue |
| `TIP` | 0.001 ETH initial | Adjust via daemon config |

### 6.2 Mainnet (target)

| Parameter | Value |
|-----------|-------|
| `WETH` | `0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2` |
| `CTF` | TBD (deploy or use existing) |
| `UniV3 Factory` | `0x1F98431c8aD98523631AE4a59f267346ea31F984` |
| `TIMEOUT` | 72 hours |
| `TWAP_WINDOW` | 24 hours |
| `FEE_TIER` | 500 |
| `baseX` | 1 ether |
| `MAX_QUEUE` | 16 |
| `TIP` | 0.05–0.5 ETH (ratchet on attack) |

---

## 7. Implementation Plan (this branch)

Commits in order:

1. `feat(arbitration): switch to WETH on Sepolia + fast-mode 2h timeout`
   — already committed.
2. `docs: onchain futarchy design doc` — this file.
3. `feat(factory): derive questionId from block.prevrandao, drop Reality`
   — patch `lib/seer-demo/contracts/src/FutarchyFactory.sol`. Adversarial
   test: verify pre-created pool for predicted addresses (using a fixed
   prevrandao mock) is detected and reverted.
4. `feat(orchestrator): atomic promote with prevrandao sanity check + TIP`
   — refactor `FutarchyOfficialProposalOrchestrator.sol`. Adversarial tests:
   A1, A2, A4 scenarios via forge fork tests.
5. `feat(resolver): TwapResolver for UniV3 + CTF reportPayouts`
   — refactor `FutarchyTWAPOracle.sol` → `FutarchyTwapResolver.sol`.
   Adversarial test: A4 wash trade scenario.
6. `feat(adapter): UniswapV3LiquidityAdapter direct pool.mint`
   — new file.
7. `feat(deploy): DeploySepoliaOnchainFutarchy.s.sol + FAO token launch`
   — new deploy script.
8. `feat(daemon): Flashbots multi-builder submission`
   — off-chain daemon under `script/daemon/`.
9. `feat(agents): adversarial + legitimate proposers`
   — under `script/agents/`, configurable for phase-5 run.
10. `chore: phase-5 launch + 10h+ live validation report`
    — report .md committed after run completes.

Each commit beyond #1 ships its own `.md` covering: what changed, threat
vectors addressed, adversarial test scenarios, and any discovered limits.

---

## 8. Known Limitations and Open Risks

| Risk | Impact | Mitigation status |
|------|--------|-------------------|
| Adversary IS the proposer of our target slot | Can include pre-create at index 0 without paying outbid | Probability = adversary_stake / total_stake; cost = forfeit proposer reward to skip. Not solved; bounded. |
| Very rich adversary sustaining attack | Can delay (not block) for days/weeks | Bounded by their budget; defender retries indefinitely at $0/attempt. Document expected attack budgets per decision value. |
| `observe()` insufficient cardinality | TWAP read reverts | Orchestrator calls `increaseObservationCardinalityNext(N)` at promote with N sized for window. |
| Spot pool (FAO/WETH) manipulation pre-promote | Anchors conditional pools at wrong price | Spot pool TWAP could be used instead of spot — future enhancement. |
| MEV searcher inserting their own conditional pool wrappers | Cannot, because pools deployed via canonical UniV3 factory with `(t0,t1,fee)` determined by our wrappers, and wrappers come from `requireWrapped1155` which is idempotent. Already pre-deployed wrappers are not a problem (empty supply, irrelevant). | Closed. |
| Flashbots Builder being adversary | Single point of failure | Multi-builder submission. |
| Reality.eth migration path | None — we don't use it | Out of scope; v0 explicit. |

---

## 9. Adversarial Validation Plan (Phase 5)

The final phase runs ≥10 continuous hours of:

- N legitimate proposer agents (varying metadata, bond size, timing).
- N adversarial agents executing each of A1–A8 in real attacks.
- Optional human participants via published interface.

Metrics collected (committed in `docs/phase5-report.md`):

- Promote success vs revert rate.
- Defender cost / promote.
- Adversary cost / blocked block, by attack type.
- Resolution latency from promote to settlement.
- TWAP vs spot price divergence at resolution time.
- Attack success count per vector (target: 0 for A1, A2; bounded for A3, A4).
- Any new vector discovered during the run, with retroactive `.md` commit on
  the relevant component.

---

## 10. References

- Robin Hanson, "Futarchy" — original proposal.
- Seer protocol — futarchy stack we fork from (replacing Reality oracle).
- Gnosis Conditional Tokens Framework — settlement primitive.
- Uniswap V3 whitepaper — TWAP via tick cumulatives.
- EIP-4399 — `block.prevrandao` semantics.
- Flashbots docs — `eth_sendBundle`, bundle drop-on-revert behavior.
