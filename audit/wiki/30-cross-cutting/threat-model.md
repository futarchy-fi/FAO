---
canonical: audit/specs/THREAT-MODEL.md@768d2ab2bdaee37c156955b0fd08732e166ae94d
scope: Authoritative wiki summary of FAO v0 assets, attacker capabilities, attack vectors, mitigations, and residual risks.
not-scope: Security administration posture is covered in [Security](security.md); invariant predicates are covered in [Invariants](../10-fao-repo/invariants.md).
last-rebuilt: 2026-05-22T14:31:28Z
---
# Threat Model

The authored threat model is now the canonical source for FAO v0 attack vectors. It matters because the old wiki stub only pointed at a historical design table, while the new spec maps numbered attacks to mitigations, invariant IDs, residual risk, and test coverage. The canonical mechanism is a cross-cutting table of assets, granted and excluded attacker capabilities, A1 through A16 vectors, rejected mitigations, known residual risks, and test mappings. `audit/specs/THREAT-MODEL.md:8-11`, `audit/specs/THREAT-MODEL.md:12-21`, `audit/specs/THREAT-MODEL.md:22-36`, `audit/specs/THREAT-MODEL.md:37-91`

## Assets

The five protected assets are promote-time atomicity, TWAP integrity, sale treasury solvency, bond escalation correctness, and adapter staging. `audit/specs/THREAT-MODEL.md:12-21`

Promote-time atomicity protects the single transaction that initializes conditional YES/NO pools and binds them to the proposal. `audit/specs/THREAT-MODEL.md:14-17`

TWAP integrity protects the fixed post-promote conditional-pool price window that determines final settlement. `audit/specs/THREAT-MODEL.md:17-18`

Sale treasury solvency and bond escalation correctness protect ragequit fairness and the cost of frivolous proposals. `audit/specs/THREAT-MODEL.md:18-20`

Adapter staging protects the `stagedFor[tx.origin]` single-use liquidity migration pattern. `audit/specs/THREAT-MODEL.md:20-21`

## Attacker Capabilities

The model grants public mempool submission, private MEV bundle submission, arbitrary priority fees, validators within the attacker's stake fraction, CREATE2 address pre-computation bots, sustained multi-block attacks, and visibility into previous-block state. `audit/specs/THREAT-MODEL.md:22-31`

The model does not grant majority validator or builder control, prediction of future `block.prevrandao` for slots the attacker does not propose, or orchestrator `msg.sender` impersonation. `audit/specs/THREAT-MODEL.md:32-36`

## Attack Vectors

| ID | Vector | Mitigation summary |
|---|---|---|
| `A1` | Pool pre-creation before promote. | `questionId` includes `block.prevrandao`, and pre-initialized pools revert under `INV-ORCH-002`. `audit/specs/THREAT-MODEL.md:41-41` |
| `A2` | Same-block priority outbid. | Builder tip at the end of the bundle makes a rational builder compare defender tip against attacker priority fees. `audit/specs/THREAT-MODEL.md:42-42` |
| `A3` | Validator self-inclusion. | Not preventable in EVM; residual risk scales with adversary validator stake and per-attempt cost. `audit/specs/THREAT-MODEL.md:43-43` |
| `A4` | TWAP wash trading. | Orchestrator-deposited liquidity and fixed TWAP windows map to `INV-TWAP-001` and `INV-TWAP-002`. `audit/specs/THREAT-MODEL.md:44-44` |
| `A5` | Bond griefing. | Bond-doubling economics rely on `INV-ARB-004` and `INV-ARB-005`. `audit/specs/THREAT-MODEL.md:45-45` |
| `A6` | Queue stuffing. | `MAX_QUEUE`, activation bond, and `tryGraduate` drainage rely on `INV-ARB-005`. `audit/specs/THREAT-MODEL.md:46-46` |
| `A7` | Hostile builder censorship. | Multi-builder submission needs at least one honest builder; mitigation is off-chain daemon-side. `audit/specs/THREAT-MODEL.md:47-47` |
| `A8` | TWAP observation insufficiency. | Promotion raises observation cardinality, currently `30` on v5, and the risk remains operator-sized. `audit/specs/THREAT-MODEL.md:48-48` |
| `A9` | Ragequit dilution. | `effectiveSupply()` subtracts sale-held balance, mapped to `INV-SALE-001` and `INV-SALE-002`. `audit/specs/THREAT-MODEL.md:49-49` |
| `A10` | Adapter staging replay. | `stagedFor[tx.origin]` is deleted after `migrate`, with future `INV-ADP-001` stubbed. `audit/specs/THREAT-MODEL.md:50-50` |
| `A11` | Adapter callback spoofing. | Adapter checks `msg.sender == cb.pool`, with future `INV-ADP-002` stubbed. `audit/specs/THREAT-MODEL.md:51-51` |
| `A12` | Reentrancy through callbacks or receiver hooks. | `buy`, `ragequit`, and `seedLiquidityManager` are non-reentrant; custom ragequit-token hooks remain residual risk. `audit/specs/THREAT-MODEL.md:52-52` |
| `A13` | Front-end or RPC hijack. | Out-of-scope for contracts; mitigations are wallet trust, ABI-as-product, and contract verification. `audit/specs/THREAT-MODEL.md:53-53` |
| `A14` | Operator key compromise. | Documented as high during testnet; mainnet target is multisig plus timelock. `audit/specs/THREAT-MODEL.md:54-54` |
| `A15` | Cross-instance fLP donation grief. | Ragequit-token registration is admin-only; residual risk is admin error. `audit/specs/THREAT-MODEL.md:55-55` |
| `A16` | Wrong-chain user signature. | UI switches chain before constructing the browser provider; user override remains residual risk. `audit/specs/THREAT-MODEL.md:56-56` |

## Rejected Mitigations

The spec explicitly rejects hardcoded zero nonce, `block.number` question IDs, nonce-loop skipping, Wrapped1155 data versioning, atomic arbitrage-then-deposit, a forked `onlyOrchestrator` UniV3 factory, and a custom AMM. `audit/specs/THREAT-MODEL.md:58-69`

The purpose of listing rejected mitigations is to prevent future contributors from rediscovering options already judged too predictable, gas-griefable, non-composable, or audit-heavy. `audit/specs/THREAT-MODEL.md:58-69`

## Residual Risks And Tests

The remaining known risks are adversarial validator slots, sufficiently funded TWAP wash trading, the single operator key, front-end supply chain risk, and deep reorgs. `audit/specs/THREAT-MODEL.md:70-77`

The current test map covers or plans coverage for A1, A4, A5, A6, A9, A10, A11, and A12; TODO rows are called out as Phase-6 priorities for failure-mode and layer coverage. `audit/specs/THREAT-MODEL.md:78-91`

## How This Might Be Wrong

- If Ethereum's randomness source changes, the A1 prevrandao assumption must be re-evaluated. `audit/specs/THREAT-MODEL.md:100-103`
- If TWAP window length or liquidity assumptions change, the A4 wash-trading cost model no longer follows from this page. `audit/specs/THREAT-MODEL.md:103-104`
- If observation cardinality changes below the v5 value, A8 can reopen. `audit/specs/THREAT-MODEL.md:48-48`, `audit/specs/THREAT-MODEL.md:104-105`
- If adapter routing moves beyond direct UniV3 mint callbacks, A11's pool-address callback check may no longer be sufficient. `audit/specs/THREAT-MODEL.md:51-51`, `audit/specs/THREAT-MODEL.md:105-106`
- If the single-key operator model is hardened, A14 and the residual-risk list should point to [Security](security.md). `audit/specs/THREAT-MODEL.md:54-54`, `audit/specs/THREAT-MODEL.md:70-77`

## See Also

- [Security](security.md)
- [Invariants](../10-fao-repo/invariants.md)
- [Why Onchain](../00-what-is-futarchy/why-onchain.md)
- [Promote](../10-fao-repo/lifecycle/40-promote.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 768d2ab2bdaee37c156955b0fd08732e166ae94d
- Build pass: 1 (authored spec refresh)
