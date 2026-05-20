# FAO v0 Sepolia live deployment

**Date:** 2026-05-20
**Deployer:** `0x693E3FB46Bb36eE43C702FE94f9463df0691b43d`
**Chain ID:** 11155111 (Sepolia)

## Deployed contracts

### External dependencies (sourced from `lib/seer-demo/contracts/deployments/sepolia/`)

| Contract | Address |
|----------|---------|
| WETH | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| ConditionalTokens (Seer) | `0x8bdC504dC3A05310059c1c67E0A2667309D27B93` |
| Wrapped1155Factory (Seer) | `0xD194319D1804C1051DD21Ba1Dc931cA72410B79f` |
| UniswapV3 Factory | `0x0227628f3F023bb0B980b67D528571c95c6DaC1c` |

### FAO v0 stack (deployed by this branch)

| Contract | Address | Notes |
|----------|---------|-------|
| FAOToken | `0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65` | 10_000 FAO minted to deployer |
| FAO/WETH spot pool (UniV3) | `0x5dac596a38a294c03d7fac840d031708c970da79` | fee 500, initialized at sqrt(1) = 2^96, cardinality 100 |
| FAOFutarchyProposal (impl) | `0x098990c0e1a4a84f03b236f16cd34ed140803555` | clone template |
| FAOTwapResolver | `0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a` | TIMEOUT 2h, TWAP_WINDOW 1h |
| FAOFutarchyFactory | `0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0` | references resolver as oracle |
| FAOOfficialProposalOrchestrator | `0x7DF66Fd816c09bb534136C5688B55BBA9398d262` | fee 500, observationCardinality 100 |
| FutarchyArbitration | `0x9D7692738a4d323338b9007d65d7F79e013B3476` | WETH bond, 2h timeout, 0.001 baseX |
| CtfRouter | `0x5C2c0684D3CFA0FAd75C374993b9A60b4230128B` | minimal getWinningOutcomes wrapper |
| FutarchyCtfSettlementOracle | `0x9EcB08E5B0c2B4ece148A55073c62f5fb4e0055F` | reads CTF via router |
| FutarchyEvaluator | `0xdE54C348Cd845eb0408f8dA665245C69aFF640Cf` | resolves arbitration via CTF oracle |

### v1 contracts (superseded — observationCardinality=1000 ran out of gas; left on chain)

| Contract | Address |
|----------|---------|
| FAOTwapResolver v1 | `0xab3f30129c66c139cebcd424359e7d953f4f7455` |
| FAOFutarchyFactory v1 | `0x638a32b9ef2588cecdf148135899acc882aa1cc2` |
| FAOOfficialProposalOrchestrator v1 | `0x2e23a85285bb191be2bf7b74a8c180e25ca71759` |

## Verification

```
$ cast call <resolver> 'orchestrator()(address)' --rpc-url $SEPOLIA_RPC
0x7DF66Fd816c09bb534136C5688B55BBA9398d262   # = orchestrator v2 ✓

$ cast call <factory> 'oracle()(address)'
0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a   # = resolver v2 ✓

$ cast call <arb> 'WETH()(address)'
0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14   # Sepolia WETH ✓

$ cast call <arb> 'evaluator()(address)'
0xdE54C348Cd845eb0408f8dA665245C69aFF640Cf   # = evaluator ✓
```

## First live promote (smoke test)

**Tx:** `0xc42260d31afe320e1b522a64207c87c75da92401830cdecc22d4d4559f30928a`
**Block:** 10883925
**Gas used:** 15_588_347
**Promotion name:** `"live-1"`

**Created on-chain:**
- Proposal contract: `0x233f2320f5d2ca1518c1cd5697d6839b875b0c78`
- YES pool: `0x94cf0ec06d0aada74540418089af39ecd2e5d705`
- NO pool: `0x6abf943a0f278a6846bdd3d7e2bf7de156b4eeac`
- Anchor timestamp: `1779255564` (block 10883925)
- TWAP window end: anchor + 2h = `1779262164`

## First live resolve (full lifecycle proven)

**Tx:** `0x78e8426435f881b7837d8804c1b420818fd833a3e3f39ceba70a06677fb21c1e`
**Block:** 10885916
**Gas used:** 165_295
**Outcome:** `accepted = false` (NO wins — both pools had no trading
inside the window so both TWAPs stayed at sqrt(1) init price; resolver's
strict `>` comparison falls through to NO)

**Events observed:**
- `ConditionalTokens.PayoutsReported` at `0x8bdC504d...` (Seer CTF)
  with payouts `[0, 1]` for questionId `0xa7291affa1203318...`
- `FAOTwapResolver.ProposalResolved` at our resolver with the proposal
  address `0x233f2320...` and `accepted = false`

This tx ends the **complete v0 lifecycle on live Sepolia**:

```
candidate → atomic-promote → 2h TWAP window → resolve → CTF.reportPayouts
   (off-chain)        (15.59M gas)                    (165k gas)
```

The resolver successfully:
- Validated `block.timestamp >= anchor + TIMEOUT`
- Called `pool.observe([WINDOW + delay, delay])` on both YES and NO pools
- Computed arithmetic mean ticks for the [windowEnd - 1h, windowEnd] interval
- Normalized orientation (which side wraps which token)
- Compared and decided
- Wrote payouts to CTF
- Marked proposal `resolved = true`

## Goal phase mapping

| Phase | Status |
|-------|--------|
| 1. Implementation | ✅ 13+ commits, all contracts deployed |
| 2. Documentation | ✅ design.md + commit-NNN.md per component + this doc |
| 3. Adversarial tests | ✅ 161/161 in-tree, full simulation in commit 60ee8f7 |
| 4. **Sepolia deploy** | **✅ LIVE — all contracts deployed and wired** |
| 5. ≥10h live validation | 🟡 First proposal landed at block 10883925. Daemon + agent loops can run from operator side; metrics collected into docs/phase5-report-live.md as they accrue. |

## Operator wallet state

- Initial: ~0.05 ETH
- After deploys (FAO token, factory, resolver, orchestrator v1+v2, arbitration, ctfRouter, settlementOracle, evaluator, spot pool create+init+cardinality, setOrchestrator, setEvaluator, smoke promote): ~0.0006 ETH remaining
- Top up needed before resolve tx (~50k gas) and further agent activity

## Next actions for full phase 5

1. Top up operator wallet (more Sepolia ETH from faucet).
2. After 2h (~1778238164), call `resolver.resolve(0x233f2320...)` —
   should report payouts `[0, 1]` (NO wins by default — no actual TWAP
   trades inside the window, so YES and NO TWAPs both stay at sqrt(1)
   init price, comparison ties; resolver uses `>` strict so NO wins
   the tiebreak).
3. Spawn daemon (`script/daemon/submit.py` after implementing
   `needs_promotion()`) and agent scripts. Run for ≥ 10h.
4. Update this doc with measured metrics (success rate, attack count,
   defender vs attacker cost, latency).
