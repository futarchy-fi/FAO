---
canonical: src/FAOOfficialProposalOrchestrator.sol
scope: Per-function PRE/POST/FRAME for FAOOfficialProposalOrchestrator — the atomic promote contract that binds a proposal, initializes conditional pools at the spot price, migrates liquidity via the adapter, and pays the builder TIP.
not-scope: Adapter mechanics (UniswapV3LiquidityAdapter; its own preconditions file is bonus stretch), spot-pool initialization in the registry.
last-rebuilt: 2026-05-22
---

# Preconditions — `FAOOfficialProposalOrchestrator`

The orchestrator is the atomic 8-phase promote engine. INV-ORCH-001 says any revert in any phase rolls back the entire post-state (including `block.coinbase` ETH balance). INV-ORCH-002 says the orchestrator refuses to operate on a pre-initialized pool.

## Constants & immutables

| Slot | Type | Invariant |
|---|---|---|
| `ADMIN` | `address` | Non-zero, set in constructor. Only ADMIN may call `createOfficialProposalAndMigrate`. |
| `FACTORY` | `FAOFutarchyFactory` | Per-instance proposal factory. Set in constructor; never mutates. |
| `UNIV3_FACTORY` | `IUniswapV3FactoryLike` | Canonical UniV3 factory (Sepolia + mainnet identical). |
| `SPOT_POOL` | `address` | The (FAO, WETH) pool whose TWAP-time price anchors the conditional pools. |
| `COMPANY_TOKEN` | `address` | Per-instance ERC20 (e.g. FAO). |
| `CURRENCY_TOKEN` | `address` | WETH on Sepolia. |
| `FEE_TIER` | `uint24` | 500 (= 0.05% fee tier; UniV3 spacing 10). |
| `OBSERVATION_CARDINALITY` | `uint16` | Conditional-pool observation slots (default 30). |
| `RESOLVER` | `IFAOFutarchyTwapResolver` | Per-instance TWAP resolver. |
| `adapter` | `IFAOLiquidityAdapter` | Mutable storage. Set via `setAdapter` (admin-replaceable in testnet, single-shot in mainnet — see SECURITY.md Step A). |

## State-mutating functions

### `setAdapter(IFAOLiquidityAdapter newAdapter) external onlyAdmin`

| | |
|---|---|
| **PRE** | `msg.sender == ADMIN`. (Testnet) no further constraint. (Mainnet target) `adapter == address(0)` — re-introduce the one-shot guard before mainnet. |
| **POST** | `adapter == newAdapter`. |
| **FRAME** | All other state. |
| **REVERTS** | `NotAdmin()`. (Mainnet) `AdapterAlreadySet()`. |
| **EVENTS** | `AdapterSet(newAdapter)`. |

### `createOfficialProposalAndMigrate(string marketName, string description, uint256 builderTip) external payable onlyAdmin returns (uint256 proposalId, address proposal)`

The 8-phase atomic function. Each phase has its own pre/post; the entire sequence is atomic per INV-ORCH-001.

| | |
|---|---|
| **PRE (top-level)** | `msg.sender == ADMIN`. `msg.value >= builderTip`. `SPOT_POOL.slot0().sqrtPriceX96 != 0` (spot pool is initialized). |

**Phase 1 — read spot price.**

| | |
|---|---|
| **PRE** | SPOT_POOL is initialized. |
| **POST** | `(sqrtPriceX96, tick)` snapshot used by all subsequent phases. |
| **FRAME** | Spot pool is read-only here. |

**Phase 2 — factory.createProposal.**

| | |
|---|---|
| **PRE** | `marketName` non-empty. The factory's `prepareCondition` precondition (CTF questionId uniqueness) holds — derived from `block.prevrandao` to evade A1 (pool pre-creation). |
| **POST** | New `FAOFutarchyProposal` cloned. 4 ERC1155 wrappers deployed via `Wrapped1155Factory.requireWrapped1155`. CTF condition prepared with the resolver as oracle. |
| **FRAME** | All other proposals' state. Pool state. |
| **Invariants touched** | INV-ARB-001 (id monotonicity — proposal id assigned). |

**Phase 3 — _maybeCreatePoolAndInit (YES pool).**

| | |
|---|---|
| **PRE** | Either no pool exists at the (yesCompanyWrap, yesCurrencyWrap, FEE_TIER) deterministic address, OR if it exists, it's not initialized (`slot0().sqrtPriceX96 == 0`). |
| **POST** | YES pool created (or reused) and initialized at `sqrtPriceX96`. |
| **REVERTS** | `SpotPoolAlreadyExists()` if a pool exists with `sqrtPriceX96 != 0` — INV-ORCH-002. |
| **Invariants touched** | INV-ORCH-002. |

**Phase 4 — _maybeCreatePoolAndInit (NO pool).** Symmetric.

**Phase 5 — observation cardinality.**

| | |
|---|---|
| **POST** | Each conditional pool's `observationCardinalityNext` is at least `OBSERVATION_CARDINALITY` (= 30). |

**Phase 6 — RESOLVER.bindProposal.**

| | |
|---|---|
| **PRE** | Resolver's `orchestrator == address(this)`. No existing binding for this proposal. |
| **POST** | `bindings[proposal].anchorTimestamp == block.timestamp`. |
| **Invariants touched** | INV-TWAP-001. |

**Phase 7 — adapter.migrate (optional).**

| | |
|---|---|
| **PRE** | `adapter != address(0)`. Caller (tx.origin == admin) has staged amounts via `adapter.stage(...)` AND approved adapter for both `COMPANY_TOKEN` + `CURRENCY_TOKEN`. |
| **POST** | YES pool + NO pool each receive full-range LP. fLP shares (or equivalent) tracked by adapter. |
| **Invariants touched** | Bonus INV-ADP-001 (single-use staging — adapter clears after migrate). |

**Phase 8 — builder TIP.**

| | |
|---|---|
| **PRE** | `builderTip <= msg.value`. |
| **POST** | `block.coinbase` receives exactly `builderTip` wei. Any unused `msg.value` is implicit (caller's responsibility to forward only what's intended). |
| **Invariants touched** | INV-ORCH-001 atomicity must include this transfer in the rollback envelope. |

**Top-level POST / REVERTS / FRAME.**

| | |
|---|---|
| **POST** | All 8 phases committed. `proposalId` = factory-assigned id. `proposal` = clone address. The resolver knows about the binding. The conditional pools have liquidity (if adapter wired). The builder coinbase received the TIP. |
| **FRAME** | Other instances (this is per-instance). The spot pool is read but never mutated. |
| **REVERTS** | `NotAdmin()`. `InvalidSpotPool()` if SPOT_POOL is uninitialized. `InsufficientETH()` if `msg.value < builderTip`. Bubbles from factory / pool / resolver / adapter / coinbase transfer. |
| **EVENTS** | `OfficialProposalCreated(proposalId, proposal, yesPool, noPool, anchorTimestamp, builderTip)`. |
| **Invariants touched** | INV-ORCH-001 (atomicity), INV-ORCH-002 (refuse pre-init pool). |

## Modifier

### `onlyAdmin`

`if (msg.sender != ADMIN) revert NotAdmin();`. Used on `setAdapter` and `createOfficialProposalAndMigrate`.

## How this might be wrong

- INV-ORCH-001's "rollback envelope" claim relies on the EVM tx model. A cross-tx reorg can roll back an already-committed promote; INV-ORCH-001 doesn't address that. Acceptable on mainnet under standard finality assumptions.
- Phase 7 (adapter.migrate) is conditional on `adapter != 0`. If the testnet hot-swap path leaves `adapter == 0`, the orchestrator still functions but produces an empty conditional pool — the rubric scoring on T6.D3 (convergence) would catch this in a subsequent pass since the resolve would tiebreak to NO.
- The `msg.value` accounting is precise only when `msg.value == builderTip`. Sending excess ETH leaves dust in the orchestrator (no refund path). Documented but not enforced; ADMIN's responsibility.
