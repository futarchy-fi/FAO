---
canonical: tests-e2e/JOURNEY-MAP.md
scope: Authoritative inventory of the 10 user-journeys (F1-F10), their personas, preconditions, success criteria, observable side effects (DOM + chain), and which spec exercises them.
not-scope: Selector contracts live in `tests-e2e/SELECTORS.md`. Synpress wiring lives in `playwright.config.ts`.
last-rebuilt: 2026-05-22
---

# User-journey map

Each row is one journey. Every journey has a single canonical Playwright
spec under `tests-e2e/journeys/`. T2.D7 (journey-map fidelity) requires
this map to stay synced with the specs — a CI guard greps the spec file
names against this table.

## Personas

| Persona | Description | Wallet? | Primary journeys |
|---|---|---|---|
| **Visitor** | Reads the home page, browses live instances, looks at the contracts page. | No | (read-only specs) |
| **Creator** | Spins up a new futarchy instance via the registry. | Yes | F1 |
| **Buyer** | Acquires an instance's tokens (sale or Uniswap). | Yes | F2, F4 |
| **Seller** | Exits a position (ragequit or Uniswap). | Yes | F3, F5 |
| **Proposer** | Submits a proposal for arbitration. | Yes | F6 |
| **Bonder** | Places YES or NO bond to escalate. | Yes | F7, F8 |
| **Grader** | Calls `tryGraduate` once a proposal is ready. | Yes | F9 |
| **Refunder** | Withdraws bonds owed by `withdrawable[]`. | Yes | F10 |

## Journeys

### F1 — Create instance

- **Persona** — Creator
- **Pre** — Wallet connected, ≥ 0.01 ETH on Sepolia, distinct token name/symbol.
- **Action** — Open `/create`, fill `{name, symbol, description, initialPriceWeiPerToken, minInitialSold, initialPhaseDuration, timeout, twapWindow}`. Click `+ Create new futarchy`. Sign the registry tx.
- **Success DOM** — Toast "Instance created — id #N". Auto-redirect to `/?inst=N`.
- **Success chain** — `FutarchyRegistry.instancesCount()` increased by 1. New `GenericFutarchyToken`, `InstanceSale`, `FAOOfficialProposalOrchestrator`, `FutarchyArbitration`, `FAOFutarchyTwapResolver`, spot UniV3 pool. `Sale.MINTER_ROLE` granted on token.
- **Failure modes** — Wrong chain → network-switch banner. Empty name/symbol → form-level error. ETH < 0.01 → "insufficient ETH for deploy gas" toast.
- **Spec** — `tests-e2e/journeys/F1-create-instance.wallet.spec.ts`.
- **Invariants exercised** — INV-ARB-001 (id monotonicity).

### F2 — Buy via sale

- **Persona** — Buyer
- **Pre** — Active instance has `status == 0` (initial sale). User has ≥ `currentPriceWeiPerToken × amount` ETH.
- **Action** — Open `/sale`, enter amount, click "Buy via sale". Confirm in modal. Sign tx.
- **Success DOM** — "Buy successful" toast. Trade card refreshes with new balance.
- **Success chain** — `Sale.tokensSold += amount`. `Token.balanceOf(user) += amount × 1e18`. ETH transferred. `Sale.totalRaised += amount × currentPriceWeiPerToken`.
- **Failure modes** — Insufficient ETH → revert. Sale already graduated (status != 0) → button hidden, alternate UI shown.
- **Spec** — `tests-e2e/journeys/F2-buy-via-sale.wallet.spec.ts`.
- **Invariants exercised** — INV-SALE-001 (effectiveSupply formula), INV-TOKEN-001 (totalSupply tracks mint).

### F3 — Ragequit

- **Persona** — Seller
- **Pre** — User has positive token balance, sale not in `0` (initial) state.
- **Action** — Toggle to "Sell" → "Ragequit". Enter amount (or 25/50/100% quick). Confirm in modal. Sign approve+ragequit.
- **Success DOM** — "Ragequit complete — received X ETH" toast.
- **Success chain** — ETH received exactly equals `floor(ethBalance_pre × burnAmount / effectiveSupply_pre)`. Token balance decreases. `Sale.lastEffectiveSupply` updates.
- **Failure modes** — Cannot ragequit during initial sale phase. Approve race.
- **Spec** — `tests-e2e/journeys/F3-ragequit.wallet.spec.ts`.
- **Invariants exercised** — INV-SALE-002 (pro-rata pay), INV-SALE-003 (ratio non-increase).

### F4 — Buy via Uniswap

- **Persona** — Buyer
- **Pre** — Spot pool exists, has liquidity.
- **Action** — Open `/sale`, enter amount, click "Buy via Uniswap". Sign swap.
- **Success DOM** — Updated cost shown, swap confirmation toast.
- **Success chain** — UniV3 swap event emitted on the spot pool. ETH-in → token-out per QuoterV2 estimate.
- **Failure modes** — Pool empty/thin → high slippage warning shown. Router not approved → approve+swap path.
- **Spec** — `tests-e2e/journeys/F4-buy-via-uniswap.wallet.spec.ts`.

### F5 — Sell via Uniswap

- **Persona** — Seller
- **Pre** — User has positive token balance + Uniswap allowance.
- **Action** — Toggle to "Sell" → "via Uniswap". Enter amount. Sign swap.
- **Success DOM** — "Sell complete" toast with ETH received.
- **Failure modes** — Same as F4 + token allowance.
- **Spec** — `tests-e2e/journeys/F5-sell-via-uniswap.wallet.spec.ts`.

### F6 — Create proposal

- **Persona** — Proposer
- **Pre** — Wallet has ≥ `minActivationBond()` WETH. Arbitration not paused.
- **Action** — Open `/proposals`. Click "+ Create proposal". Fill marketName/description. Sign YES bond tx.
- **Success DOM** — Proposal card appears with id and YES bond chip.
- **Success chain** — `proposals[id].exists == true`, `state == YES`, `yesBond` recorded. `nextProposalId` increments.
- **Failure modes** — Bond too small → revert. Queue full → "queue full" toast.
- **Spec** — `tests-e2e/journeys/F6-create-proposal.wallet.spec.ts`.
- **Invariants exercised** — INV-ARB-001 (id monotonicity), INV-ARB-005 (graduation reachability).

### F7 — Place YES bond (escalation)

- **Persona** — Bonder
- **Pre** — Proposal in `NEW` or `NO` state, wallet has ≥ required.
- **Action** — Click "Place YES bond" on a proposal card. Sign.
- **Success DOM** — YES bonder chip updates. Previous NO bonder gets withdrawable credit toast.
- **Success chain** — `state := YES`, `yesBond` updated, previous NO bonder credited.
- **Failure modes** — Bond too small, state ≠ {NEW, NO}.
- **Spec** — `tests-e2e/journeys/F7-place-yes-bond.wallet.spec.ts`.

### F8 — Place NO bond (escalation)

- **Persona** — Bonder
- **Pre** — Proposal in `YES` state. Wallet has ≥ 2× YES bond.
- **Action** — Click "Place NO bond". Sign.
- **Success DOM** — NO bonder chip updates. Previous YES bonder credited.
- **Success chain** — `state := NO`, `noBond` updated, previous YES bonder credited.
- **Spec** — `tests-e2e/journeys/F8-place-no-bond.wallet.spec.ts`.

### F9 — Try graduate

- **Persona** — Grader
- **Pre** — Proposal `state == YES`, `yesBond.amount >= baseX × 2^queuedCount()`.
- **Action** — Click "Graduate" on a ready proposal. Sign.
- **Success DOM** — Status pill flips to "PROMOTED". Atomic-promote button appears.
- **Success chain** — `state := PROMOTED`. If admin then runs atomic-promote, conditional pools are created and bound by the orchestrator.
- **Failure modes** — Conditions not met → returns false silently.
- **Spec** — `tests-e2e/journeys/F9-try-graduate.wallet.spec.ts`.

### F10 — Withdraw refund

- **Persona** — Refunder
- **Pre** — `withdrawable[msg.sender] > 0` (e.g. previously displaced YES or NO bonder).
- **Action** — Open `/bonds` (or whichever surface lists refunds). Click "Withdraw".
- **Success DOM** — Toast with claimed amount. List row removed.
- **Success chain** — `withdrawable[msg.sender] := 0`. WETH transferred to caller.
- **Spec** — `tests-e2e/journeys/F10-withdraw-refund.wallet.spec.ts`.

## Read-only specs (no wallet, no journey)

| Spec | Counts toward |
|---|---|
| `tests-e2e/journeys/home.read-only.spec.ts` | D1 partial (browse persona), D7 (journey-map presence). |
| `tests-e2e/journeys/failure-modes.read-only.spec.ts` | D4 (failure modes: missing deployments.json, malformed JSON, zero-address registry, RPC down, blocked deployments fetch, sale-empty-state). |
| `tests-e2e/journeys/fork-state.read-only.spec.ts` | D3 fork realism: starts/uses Anvil on `8545`, reads `instancesCount()` via viem, mutates the fork with `cast send`, reloads `/`, and asserts `data-testid="rankings-rows"` reflects `N + 1`. |

## Fork-state local-dev cycle

The fork-state read-only spec proves the no-wallet path: browser reads come
from `localStorage.faoForkMode=1`, chain assertions read the same fork via
viem, and state mutations happen with `cast send`.

1. Start the local static site:

   ```bash
   cd site-testnet
   python3 -m http.server 8766
   ```

2. Run the fork project from the repo root:

   ```bash
   FAO_SITE_URL=http://127.0.0.1:8766 \
     npx playwright test --project=fork tests-e2e/journeys/fork-state.read-only.spec.ts
   ```

3. Optional deterministic fork pin:

   ```bash
   ANVIL_FORK_BLOCK_NUMBER=<sepolia-block> \
   FAO_SITE_URL=http://127.0.0.1:8766 \
     npx playwright test --project=fork tests-e2e/journeys/fork-state.read-only.spec.ts
   ```

The spec setup ensures Anvil is reachable at `http://127.0.0.1:8545`. If a
previous local run left a dirty txpool, reset it with
`bash scripts/anvil-fork.sh --stop` before rerunning; the next spec run starts a
fresh fork. No wallet or Synpress profile is required.

## How this might be wrong

- Wallet-driven specs (F1-F10) are scaffolded with `test.fixme()` pending Synpress. The journey contract here is the spec; converting `test.fixme()` to `test()` is the D2/D3 lift (test signal density + realism).
- Some invariants are exercised by multiple journeys (e.g. INV-SALE-002 by F3). A future evaluator may want a reverse index (per-invariant → which journey covers it) — not yet built.
- The "Failure modes" column lists what the UI **should** do; the present `failure-modes.read-only.spec.ts` only covers the deployments.json + RPC fault paths. Form-validation + insufficient-balance assertions still need executable coverage.
