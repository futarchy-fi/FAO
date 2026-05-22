---
canonical: audit/specs/THREAT-MODEL.md
scope: Authoritative threat model for FAO v0. Assets, attacker capabilities, vectors, mitigations, residual risk, mapping to invariants and tests.
not-scope: Per-function preconditions (see `audit/specs/preconditions/`), economic-game-theory analysis (see `audit/research/topic-3-spec-formalization.md`).
last-rebuilt: 2026-05-22
---

# FAO Threat Model

This document subsumes and supersedes `docs/onchain-futarchy-design.md` §2. Every attack vector is numbered (`A<N>`), mapped to a mitigation (with an invariant ID where applicable), and given a residual-risk note.

## 1. Assets under attack

| Asset | Why it matters |
|---|---|
| **Promote-time atomicity** | A successful promote initializes the conditional YES/NO pools and binds them to the proposal in one tx. If any step can be MEV-attacked or front-run, the conditional pools are no longer the orchestrator's. |
| **TWAP integrity** | Final settlement signal is the conditional-pools' TWAP over a fixed post-promote window. Any party that can dominate trades during that window dominates outcomes. |
| **Sale treasury solvency** | `InstanceSale.ragequit` must always return a fair pro-rata share of treasury. If `effectiveSupply` is gameable, ragequit becomes unfair (early ragequitters can grab more than their share). |
| **Bond escalation correctness** | Bond doubling is the only economic deterrent against frivolous proposals. A bug here makes the system grief-friendly. |
| **Adapter staging** | The UniswapV3LiquidityAdapter's `stagedFor[tx.origin]` pattern is single-use; any replay or cross-tx leakage is catastrophic. |

## 2. Attacker capabilities

**Granted:**
- Submit arbitrary public-mempool transactions; arbitrary priority fees.
- Submit private bundles to MEV-Boost builders.
- Spin up validators within their stake fraction.
- Run keepers / bots that pre-compute CREATE2-deterministic addresses.
- Maintain attacks for sustained periods across many blocks.
- See on-chain state up to the previous block.

**NOT granted:**
- Control of > 50% of validators / builders.
- Predict `block.prevrandao` of future blocks they do not themselves propose.
- Impersonate `msg.sender` of the orchestrator.

## 3. Attack vectors & mitigations

| # | Vector | Mechanism | Mitigation | Mitigation invariants | Residual risk |
|---|---|---|---|---|---|
| **A1** | Pool pre-creation | Adversary calls `UniV3Factory.createPool(t0, t1, fee)` + `pool.initialize(badPrice)` at the CREATE2-deterministic address before the orchestrator's promote. The orchestrator's promote sees a pre-initialized pool, cannot re-initialize, and the conditional TWAP is now adversary-controlled. | `questionId = keccak256(name, desc, address(this), proposals.length, block.prevrandao)` — addresses become unpredictable across blocks that the adversary does not propose. `_maybeCreatePoolAndInit` reverts with `SpotPoolAlreadyExists` if a pool is pre-initialized. | **INV-ORCH-002** | Adversary slot-proposer (see A3). |
| **A2** | Same-block priority outbid | Adversary submits a high-priority `pool.initialize` tx in the same block as our promote. Builder ranks adversary first; our bundle reverts. | Bundle ends with `block.coinbase.transfer(TIP)`; rational builder picks `max(TIP, attacker priority)`. Defender can raise TIP arbitrarily; attacker's per-block cost grows linearly. | (none — economic) | Defender's TIP budget. |
| **A3** | Validator self-inclusion | Adversary is the slot proposer; inserts their pre-create tx at index 0 of the block, before our bundle. | Cannot prevent in EVM. Bounded by adversary's validator stake fraction × cost per attempt (~0.04 ETH proposer reward + opportunity cost of priority position). | (none — protocol-level) | Linear in stake share. |
| **A4** | TWAP wash trading | Adversary trades against own conditional-pool liquidity during the TWAP window to bias the average. | Orchestrator-deposited liquidity dilutes wash trades; cost-to-move-TWAP scales with √liquidity. TWAP window length and anchor are chosen so cost > expected proposal payoff. | **INV-TWAP-001**, **INV-TWAP-002** | Adversary with √liquidity-scaled budget. |
| **A5** | Bond griefing | Adversary flips YES↔NO bond on a target proposal to delay timeout settlement indefinitely. | Bond doubling: each NO bond must be exactly `2× current YES`; each YES counter must beat `2× current NO`. Each flip is exponentially more expensive. | **INV-ARB-004**, **INV-ARB-005** | Attacker bankroll. |
| **A6** | Queue stuffing | Adversary fills the graduation queue with throwaway proposals to delay legitimate ones. | `MAX_QUEUE = 3` cap. `tryGraduate` drainage; activation bond required. | **INV-ARB-005** | Attacker pays activation bond per stuffed slot. |
| **A7** | Hostile builder censorship | Adversary controls (or pays) a builder that drops our promote bundles. | Multi-builder submission: Flashbots, BloXroute, Titan, Beaver, Rsync. ≥ 1 honest builder suffices for the orchestrator's tx to land. | (off-chain, daemon-side) | Multi-builder collusion (rare). |
| **A8** | TWAP observation insufficiency | Conditional pool's `observationCardinalityNext` is too low for the TWAP window → `pool.observe(secondsAgos)` reverts at resolve. | Orchestrator calls `pool.increaseObservationCardinalityNext(N)` during promote, with `N` sized for the TWAP window (currently `30` on v5). | **INV-TWAP-001** | Setting too low ⇒ stuck resolve; setting too high ⇒ wasted gas. Operator responsibility. |
| **A9** | Ragequit dilution | Adversary mints tokens to the sale (donation) to inflate `totalSupply` without increasing `effectiveSupply`, hoping to gain a larger ragequit share. | `effectiveSupply()` subtracts the sale's own balance — donated tokens are excluded. The donation is permanently locked in the sale. | **INV-SALE-001**, **INV-SALE-002** | Donor loses tokens (intended). |
| **A10** | Adapter staging replay | Two consecutive promotes could re-use the same staged amount if the adapter doesn't clear staging on use. | Adapter's `stagedFor[tx.origin]` is deleted at the end of `migrate`; subsequent calls require a fresh `stage(...)`. | (Bonus invariant: INV-ADP-001 — stub) | None observed. |
| **A11** | Adapter callback spoofing | Hostile contract impersonates UniV3 pool callback to drain adapter. | Adapter validates `msg.sender == cb.pool` in `uniswapV3MintCallback` before transferring tokens. | (Bonus invariant: INV-ADP-002 — stub) | Pool contract compromise (out-of-scope). |
| **A12** | Reentrancy via callback / receiver hooks | An ERC1155 / ERC721 / ERC20 callback re-enters the sale's `ragequit` or `buy`. | `nonReentrant` modifier on `buy`, `ragequit`, `seedLiquidityManager`. ERC1155 receiver hooks return the magic value but do nothing else. | **INV-SALE-002** (depends on guard) | Future custom ragequit-token with adversarial transfer hook. |
| **A13** | Front-end / RPC hijack | Adversary modifies the deployed site to send to a fake contract address. | Out-of-scope (TLS / wallet trust). Mitigation: ABI-as-product approach + Etherscan verification (Topic 5 D6). | (off-chain) | Site mirror / phishing. |
| **A14** | Operator key compromise | Single-key operator on testnet. | Documented limitation. Mainnet target: multisig + timelock (Topic 5 D2 lift TODO). | (Topic 5 D2 lift) | High during testnet; planned. |
| **A15** | Cross-instance fLP donation grief | Send fLP from instance A's seeder into instance B's sale to add it to instance B's ragequit list (admin call). | `addRagequitToken` is admin-only; donations cannot register themselves. | **INV-SALE-...** (covered by access control) | Admin error. |
| **A16** | Wrong-chain user signature | User signs a tx on mainnet thinking they're on Sepolia. | UI auto-switches chain via `wallet_switchEthereumChain` before constructing the BrowserProvider; rejects sign if chain mismatch. | (UI; Topic 1 D2) | User confirms despite warning. |

## 4. Rejected mitigations (anti-patterns we considered)

(Subsumes §2.5 of `docs/onchain-futarchy-design.md`. Listed so future contributors don't rediscover.)

- **Hardcoded zero nonce in questionId (Seer's original).** Trivial DoS.
- **`block.number` in questionId.** Publicly predictable; adversary pre-creates pools at predicted future-block addresses; sustained ~$9/block.
- **Monotonic nonce-loop with skip.** Adversary fills nonces cheaply across blocks until orchestrator's tx OOGs.
- **Wrapped1155Factory `data` versioning.** Same problem as nonce-loop.
- **Atomic arbitrage-then-deposit.** Fails for concentrated-liquidity adversary positions; cost unbounded.
- **Fork UniV3Factory with `onlyOrchestrator`.** Loses composability with canonical Uniswap ecosystem.
- **Custom AMM (UniV2-style).** Adds audit surface; UniV3 canonical preferred.

## 5. Residual risks (KNOWN limitations)

1. **Adversarial validator slots (A3).** Cannot prevent in EVM. Cost is linear in adversary stake; we tolerate.
2. **TWAP wash trading with √liquidity-scaled budget (A4).** Defender's job is to keep TWAP-window liquidity > expected proposal payoff. No protocol enforcement.
3. **Single operator key (A14).** Mainnet must move to multisig + timelock.
4. **Front-end supply chain (A13).** Site lives on Cloudflare Pages; mitigations are TLS + manually-pinned contract addresses. A future CSP + SRI pass would help.
5. **Cross-chain reorg.** Mainnet finality is the assumed boundary; deep reorgs can roll back a promote. Acceptable for v0.

## 6. Mapping back to tests

| Vector | Foundry test that exercises the defense (or invariant test) | File |
|---|---|---|
| A1 | `test_promote_revertsOnPreCreatedPool` (TODO) | `test/FAOOfficialProposalOrchestrator.t.sol` |
| A4 | `test_twap_resolver_*` | `test/FAOTwapResolver.t.sol` |
| A5 | `invariant_bondTreasuryConservation` | `test/FutarchyArbitration.invariants.t.sol` |
| A6 | `test_arbitration_maxQueueCap` | `test/FutarchyArbitration.t.sol` |
| A9 | `test_effectiveSupply_excludesSaleBalance` | `test/InstanceSale.t.sol` |
| A10 | `test_stage_clearsAfterMigrate` (TODO) | `test/UniswapV3LiquidityAdapter.t.sol` |
| A11 | `test_callback_rejectsNonPoolCaller` | `test/UniswapV3LiquidityAdapter.t.sol` |
| A12 | `test_ragequit_nonReentrant` (TODO) | `test/InstanceSale.t.sol` |

Rows marked TODO are the immediate Phase-6 priorities for raising T2.D4 (failure-mode coverage) and T4.D1 (layer coverage).

## See also

- `audit/specs/INVARIANTS.md` — formal-shape invariants.
- `audit/rubrics/topic-3-spec-formalization.md` — the rubric this doc is scored against.
- `audit/rubrics/topic-5-holistic-architecture.md` — D2 (security posture) reads this doc.
- `docs/onchain-futarchy-design.md` — historical source (kept for git-blame trail).

## How this might be wrong

- A1 mitigation assumes `block.prevrandao` is unpredictable to non-proposers. If a future fork changes the randomness source, A1 reopens.
- A4 cost-scaling analysis assumes the TWAP is computed over a window long enough to dilute single-block manipulation. Window changes invalidate the analysis.
- A8 observation cardinality `30` was chosen empirically for v5; reducing it later without re-running the analysis would reintroduce A8.
- A11 mitigation depends on the pool address being knowable at callback time — true for direct UniV3 mint, false for hop-based routing (none today).
- Residual risk #1 has no mitigation; risk #3 has a planned mitigation that has not yet shipped.
