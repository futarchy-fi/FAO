# Topic 2 — High-level testing of web3 interfaces + user-flow definitions

> Research dossier feeding the Topic-2 rubric. Scope: end-to-end testing of
> web3 frontends (DEX, DAO, sale, escalation UIs), specifically calibrated
> for `futarchy-fi/FAO`'s `site-testnet/` static multi-page site.
> Adapter-level Solidity tests (`test/UniswapV3LiquidityAdapter.t.sol`,
> `test/InstanceSale.t.sol`, `test/SaleSpotSeeder.t.sol`) are out of scope —
> see Topic 4 for those.

## 0. Executive frame

A web3 frontend test suite is **only useful if it can catch the failure
modes that destroy user funds or lock users out of a protocol they paid
into**. That implies the test pyramid for web3 is inverted relative to
SaaS: integration + E2E tests against a real (forked) chain are
load-bearing, because the bugs that matter live at the contract/UI
seam — stale RPC reads, wrong slippage math, wallet rejection paths,
chain switching, nonce gaps, and reorg/finality issues. Pure DOM unit
tests of presentational components are nearly worthless here; they will
score very low signal-density on the rubric.

The rest of this document operationalizes that frame for FAO.

## 1. High-level testing best practices for web3 frontends

### 1.1 The toolchain you should default to

**Anvil + Playwright + Synpress** is the contemporary baseline for
serious EVM frontend E2E coverage. Components:

| Layer | Tool | What it gives you |
|---|---|---|
| Local chain | **Anvil** (`foundry-rs/foundry`) — `anvil --fork-url $SEPOLIA_RPC --fork-block-number N` | Deterministic fork of production state; instant block mining (`evm_mine`), time travel (`evm_setNextBlockTimestamp`), state snapshots (`evm_snapshot`/`evm_revert`), and `anvil_impersonateAccount` to act as any address (admin, whale, multisig). |
| Browser driver | **Playwright** (`@playwright/test`) | Cross-browser automation, robust auto-waiting, trace viewer, network interception, parallel workers, video on failure. Preferred over Cypress for web3 because Playwright runs in real Chromium with extensions and supports multi-tab (needed for MetaMask popups). |
| Wallet driver | **Synpress** (`Synthetixio/synpress`) | Playwright/Cypress harness that drives the real MetaMask browser extension: `metamask.connectToDapp()`, `metamask.confirmTransaction()`, `metamask.rejectTransaction()`, `metamask.switchNetwork()`, `metamask.importAccount(privateKey)`. Critical for testing rejection paths and chain switching. |
| Chain assertions | **Wagmi-test** / `viem`'s `createTestClient` | Programmatic chain assertions inside the test: read on-chain state after a user action, assert events emitted, assert balance deltas. Lets you avoid asserting only on DOM text. |
| Hosted forks (optional) | **Tenderly Virtual TestNets** or **Tenderly Web3Actions** | Shared persistent forks for staging; Web3Actions can trigger on tx events (e.g. fire a webhook into the test runner when a proposal resolves). Useful when CI workers must share state with a hosted preview deploy. |

**Why Anvil over Hardhat node:** Anvil is ~10× faster to start, has
first-class fork mode with deterministic block hashes, and exposes
`anvil_mine N` for batch mining — important when E2E flows need to wait
out a TWAP window or sale phase.

**Why Synpress over `@web3-onboard/headless` mocks:** mocked wallets
hide an entire class of bugs (rejection handling, chain-switch race
conditions, EIP-1193 event ordering, signature popup UX). The rubric in
Topic 2 explicitly penalizes mocked wallets for the user-facing flows.

### 1.2 The 6-property suite a web3 frontend test must satisfy

Every E2E test you write should satisfy these or be marked as lower-tier:

1. **Real fork, not mock.** Runs against an Anvil fork of Sepolia at a
   pinned block. Mocked contracts are reserved for negative tests
   (forcing a specific revert reason).
2. **Real wallet, not stub provider.** Synpress-driven MetaMask, real
   confirm/reject buttons. Stubbing `window.ethereum` is allowed only
   for the read-only happy path of the home/proposals page.
3. **Asserts on-chain effect, not just DOM.** A "buy" test that only
   checks for a green toast is tautological — assert the buyer's token
   balance increased by the expected amount via `publicClient.readContract`.
4. **Has a defined user persona + journey.** Each test corresponds to a
   named flow ("Buyer purchases tokens during initial sale phase") and a
   persona ("first-time buyer with 1 ETH").
5. **Idempotent + isolated.** Uses `evm_snapshot` before and
   `evm_revert` after, so tests can run in any order without
   cross-contamination.
6. **Selector stability.** Targets `data-testid` or stable
   `role="..."` + accessible-name selectors — never CSS classes,
   ordinals (`:nth-child(3)`), or text fragments that the copywriter
   might tweak.

### 1.3 Wallet test patterns

Three flows that test suites typically *fail to cover* but which break
in production constantly:

- **Wallet locked / re-auth.** User opens the page, MetaMask is locked
  (extension shut down). Site must prompt unlock, not silently fail.
- **Wrong chain.** User is on Ethereum mainnet; site must offer a one-click
  network switch, not just disable the button.
- **User rejects signature.** All `tx.wait()` paths must catch
  `user rejected transaction` (code 4001) and present an actionable
  retry, not a stuck spinner.
- **Pending tx + reload.** User submits a buy, navigates away, comes back.
  Site must reflect the pending state and reconcile after confirmation.
- **Account switched mid-session.** User flips MetaMask account; all
  balances and "your bond" rows must invalidate, not show stale data
  from the previous account.

## 2. Expressing user flows as test scenarios

### 2.1 BDD-style journey definition

Each flow gets one canonical Gherkin spec, which the Playwright spec
implements. Format:

```gherkin
Feature: Initial-phase token purchase
  As a first-time buyer
  I want to purchase tokens at the sale price during the initial phase
  So that I receive ragequit-eligible tokens

  Background:
    Given an Anvil fork of Sepolia at block 7_500_000
    And an instance "ACME" in initial sale phase with 0/10000 sold
    And buyer Alice has 5 ETH and 0 ACME

  Scenario: Buyer purchases 100 tokens via sale
    Given Alice navigates to /sale?inst=42
    When Alice enters "100" into the buy amount input
    And Alice clicks "Buy via sale"
    And Alice confirms in MetaMask
    Then Alice's ACME balance increases by exactly 100e18
    And the sale's totalAmountRaised increases by 100 * salePriceWei
    And the initial-phase progress bar shows "100 / 10000"
    And a success toast links to the tx on Etherscan
```

The Gherkin file lives next to the `.spec.ts` so reviewers see the
intent before they see the code. The journey itself is treated as
documentation; the spec file is the executable contract.

### 2.2 Journey maps: persona × intent × state

A **journey map** is a table that decomposes one user flow into
ordered steps, each with: (a) UI surface, (b) chain interaction,
(c) failure modes, (d) the test that covers it.

Example for "Create new futarchy":

| Step | Persona surface | Chain interaction | Failure modes | Test ID |
|---|---|---|---|---|
| 1 | `/create` page loaded | RPC: `instancesCount()` | RPC 503; registry not deployed | `create-01-load` |
| 2 | Fill name/symbol/desc | none | client-side validation: empty, too long, duplicate symbol | `create-02-validate` |
| 3 | Set sale price, min sold, durations, bond | none | non-numeric, negative, zero | `create-03-numerics` |
| 4 | Connect MetaMask | wallet handshake | wallet locked; wrong chain | `create-04-connect` |
| 5 | Submit Part 1 | tx: `createFutarchyPart1` | user rejects; out-of-gas; revert with reason | `create-05-part1` |
| 6 | Wait for Part 1 confirmation | poll receipt | tx dropped; reorg; slow block | `create-06-confirm1` |
| 7 | Submit Part 2 | tx: `createFutarchyPart2(id)` | revert if Part 1 not finalized; gas limit | `create-07-part2` |
| 8 | Redirect to `?inst=<id>` | RPC: `instances(id)` | redirect happens before chain visible | `create-08-redirect` |

Every row in the journey map maps to either (i) one or more spec files,
or (ii) an explicit "not tested" mark with a rationale. The rubric
rewards full row coverage and penalizes silently missing rows.

### 2.3 Persona library

Define personas once, reuse across flows. A persona is a tuple:

```ts
type Persona = {
  name: string;
  address: `0x${string}`;
  balanceEth: bigint;
  tokenBalances?: Record<Address, bigint>;
  network: 'sepolia' | 'mainnet' | 'wrong';
  walletState: 'locked' | 'unlocked' | 'unconfigured';
};
```

For FAO, the persona library must include at minimum: first-time
visitor (no wallet), wallet-connected reader (read-only), small buyer,
whale buyer, proposal creator, YES bonder, NO bonder, ragequitter,
admin/operator (impersonated via `anvil_impersonateAccount`).

## 3. The web3 test pyramid

```
                                  ┌─────────────────┐
                                  │  Chaos / fuzz   │   <— Topic 4 + cross-page nav
                                  ├─────────────────┤
                                  │   E2E (forks)   │   <— THIS TOPIC's main weight
                                  ├─────────────────┤
                                  │  Integration    │   <— page + signer + RPC
                                  ├─────────────────┤
                                  │   Component     │   <— optional for static HTML
                                  ├─────────────────┤
                                  │     Unit        │   <— low weight for UI
                                  └─────────────────┘
```

- **Unit (low weight, 10%).** Pure-function tests of helpers in
  `shared.js`/`sale.js` (formatters, BPS math, slippage calc, address
  encoding). These should exist for any function with branching logic
  but they are *not* substitutable for E2E coverage.
- **Component (optional, 0–10%).** Because FAO is vanilla HTML + IIFE
  JS (no React/Vue), there is no idiomatic "component" layer. The
  closest equivalents are: rendering the topbar against a faked
  `window.allInstances`, rendering a proposal card against a fixture.
  If you build a component layer at all, do it via JSDOM + Vitest;
  do not introduce a UI framework just to gain component tests.
- **Integration (medium weight, 25%).** Spin up the static site
  (`python3 -m http.server`), point it at Anvil-forked Sepolia, drive
  with Playwright but use a **stubbed wallet** that auto-signs. These
  catch the "page reads correct chain state and dispatches correct
  calldata" bugs without paying the MetaMask UI cost.
- **E2E (high weight, 50%).** Same setup as Integration but with
  Synpress-driven real MetaMask. These are the canonical tests for
  each named user flow.
- **Chaos (medium weight, 15%).** Inject failures: RPC 503, slow
  blocks, reorg via `anvil_setNextBlockBaseFeePerGas` + revert, wallet
  rejected, slippage exceeded. Each chaos test pairs with a happy-path
  E2E and asserts the error UX.

## 4. Anti-patterns to penalize aggressively

These should produce **score reductions** at the rubric stage.

### 4.1 Testing implementation details
- Asserting on `innerHTML` or specific CSS class names.
- Asserting on the order of `Promise.all` resolutions.
- Asserting that a specific RPC method was called *N* times (this locks
  in caching/polling implementation; a refactor that changes from
  polling to subscription breaks tests that aren't measuring user
  outcomes).

### 4.2 Brittle selectors
- `:nth-child(3)`, `.btn-primary`, `text="Buy"` when copy is in flux.
- Relying on element index instead of a semantic attribute.
- Targeting auto-generated IDs (`#radix-1`, `#ember1234`).

### 4.3 Mocking when a fork would do
- Mocking `currentPriceWeiPerToken()` to return `1e18` when the real
  curve math should be tested. This is the #1 cause of "passing tests
  that ship broken curves."
- Mocking the entire `InstanceSale` ABI in JS rather than deploying it
  on Anvil.
- Wrapping `window.ethereum` in a jest mock for buy/sell flows.

### 4.4 Tautological assertions
- `expect(button).toBeVisible()` immediately after clicking it.
- `expect(toast).toContain("Buy")` right after a buy attempt — the
  toast text is what the test itself injected; the assertion proves
  nothing about chain state.
- `expect(amountInput.value).toBe("100")` right after typing "100".
- Comparing a value to itself through an indirection
  (`expect(x).toBe(getX())`).

### 4.5 No-await / no-network tests
- Tests that pass with the network unplugged because they only render
  the static shell.
- Tests that don't wait for a tx receipt before asserting balance.

### 4.6 Coverage theater
- Adding a `beforeEach` that visits every page just to lift the
  "lines covered" number, without any meaningful assertions.
- One giant "smoke" test that clicks every button but asserts on none.

### 4.7 Snapshot dependence
- DOM snapshots that turn every copy change into a 50-line diff and a
  rubber-stamp re-snapshot. Snapshots are acceptable only for stable
  artifacts (e.g. parsed calldata).

### 4.8 Shared mutable state
- Tests that share an Anvil instance without snapshot/revert and pass
  only in a particular order. Detect via running with
  `--shard 1/N --shuffle`.

## 5. Measuring test quality

The rubric must use signals that resist Goodhart's-Law gaming. Use the
combination below, not any single one.

### 5.1 Mutation testing (the gold standard)

Run **Stryker.js** (`@stryker-mutator/core`) over `site-testnet/*.js`.
Stryker mutates the source (flip `>` to `<`, change `+` to `-`, swap
`true`/`false`, drop conditionals) and runs the test suite for each
mutant. A **mutation score** = `% of mutants killed`. Web3 frontends
should target ≥ 70%; FAO's bonds math, slippage math, and curve
formatters are the priority files.

Stryker is the source of truth for "does my test suite actually
exercise this code?" — line coverage cannot answer that.

### 5.2 Meaningful coverage

Line coverage (`c8`/`nyc`) is *necessary but not sufficient*. Require:
- **Branch coverage ≥ 80%** on JS files that handle tx submission.
- **Function coverage ≥ 90%** on exported helpers.
- **Per-flow coverage**: every user flow listed in the inventory must
  have at least one E2E spec that exercises it end-to-end.

Never report a single global coverage number without the per-flow
breakdown; an 85% global with 0% on the bonds flow is a fail.

### 5.3 Flake rate (CI signal)

Tests that fail intermittently are negative-value: they train teams to
ignore CI. Track:
- **Flake rate per spec** over the last 50 runs.
- Auto-quarantine any spec with > 2% flake until fixed; do not let it
  degrade trust.

### 5.4 Selector-stability score

Static analysis of spec files: count selectors by category. Award
points for `data-testid`/`role`/`aria-label`; deduct for CSS classes,
`nth-child`, or unanchored text.

### 5.5 Real-vs-mock ratio

For each user flow, classify the test as `fork-real-wallet`,
`fork-stub-wallet`, `mock-chain-real-wallet`, or `pure-mock`. A healthy
suite is dominated by `fork-real-wallet` for paying flows (buy, bond,
create) and may use `fork-stub-wallet` for read-only.

## 6. Detecting useless tests

A test is **useless** if removing it would not reduce the suite's
ability to catch real defects. Operational detection:

1. **Mutation co-kill analysis.** If test A and test B kill the exact
   same set of mutants, B is a duplicate. Flag for removal.
2. **No-fail-history.** A test that has never failed *and* whose
   coverage is subsumed by another test is a candidate for deletion.
3. **Tautology lint.** Static checks for patterns from §4.4: assertion
   directly on the value just written, equality between two
   expressions that both reference the same DOM node, expectations
   that match the literal default state.
4. **Disabled-network probe.** Run the suite with the chain RPC
   firewalled. Any E2E test that still passes is by definition not
   testing chain interaction — flag it.
5. **Selector-only assertions.** A test whose only `expect` is on
   visibility/existence with no behavioural follow-up. These exist
   only to bump coverage.
6. **Stub-detected reads.** A test that asserts on a number which is
   then revealed (via instrumentation) to come from a stub the test
   itself installed. The test is asserting against its own fixture.

The rubric in Topic 2 codifies these into the "signal density"
dimension.

## 7. Specific guidance for the FAO testnet site

Given the site is vanilla HTML + ethers.js v6 IIFEs (no framework, no
build step — see `site-testnet/index.html` line 8–10 for the script
tags), the recommended stack is:

```
/site-testnet/                  ← unchanged production code
/test-e2e/
  ├─ playwright.config.ts        ← reporters, baseURL, retries=0
  ├─ fixtures/
  │   ├─ anvil.ts                ← starts/stops fork, snapshots
  │   ├─ wallet.ts               ← Synpress wallet helper
  │   └─ personas.ts             ← named personas
  ├─ journeys/
  │   ├─ 01-create-instance.spec.ts
  │   ├─ 02-buy-via-sale.spec.ts
  │   ├─ 03-ragequit.spec.ts
  │   ├─ 04-buy-via-uniswap.spec.ts
  │   ├─ 05-create-proposal.spec.ts
  │   ├─ 06-place-yes-bond.spec.ts
  │   ├─ 07-place-no-bond.spec.ts
  │   ├─ 08-try-graduate.spec.ts
  │   ├─ 09-withdraw-refund.spec.ts
  │   └─ 10-resolve-proposal.spec.ts
  ├─ chaos/
  │   ├─ rpc-503.spec.ts
  │   ├─ wallet-rejected.spec.ts
  │   ├─ wrong-chain.spec.ts
  │   ├─ account-switched.spec.ts
  │   └─ reorg.spec.ts
  └─ helpers/
      ├─ chain.ts                ← read on-chain state
      └─ selectors.ts            ← canonical data-testid map
```

Pre-requisite refactor in production code: add `data-testid` to every
interactive element in the six HTML pages. The current HTML uses `id`
attributes generously (49 in `sale.html`, 13 in `create.html` per
`grep -c 'id="'`) which is workable, but a parallel `data-testid` is
preferred so test selectors don't piggyback on ARIA/styling concerns.

CI integration: extend `.github/workflows/test.yml` with a second job
`e2e` that runs after the existing `check` job. Use Anvil from the
existing Foundry toolchain — no extra installs required at the chain
layer.

## 8. Calibration notes for the rubric

When the evaluator scores the FAO testnet suite, it should:

- Score the **interface tests only** (i.e., things under
  `site-testnet/` or any future `test-e2e/`). Solidity tests in
  `test/` belong to Topic 4.
- Treat "no tests" as a literal zero, not a "missing data" abstention.
  Today FAO has zero interface tests — the baseline will be in the
  0–1 range across every dimension. That's the correct signal.
- Reward incremental progress: a single, real, fork-driven Playwright
  test of the `buy via sale` flow should move "User-flow coverage" from
  0 to 1, "Realism" from 0 to 4, and "Signal density" from N/A to 7.
- Penalize regressions hard: if a future loop swaps a real-fork test
  for a mock, the realism score must drop.

## Sources

- Foundry Book — Anvil reference (`anvil --fork-url`, `evm_snapshot`,
  `evm_revert`, `anvil_impersonateAccount`):
  https://book.getfoundry.sh/anvil/
- Playwright docs — best practices, test isolation, network
  interception: https://playwright.dev/docs/best-practices
- Synpress (Synthetixio) — Playwright + Cypress harness for MetaMask:
  https://github.com/Synthetixio/synpress
- Wagmi `viem` test client (`createTestClient`):
  https://viem.sh/docs/clients/test
- Tenderly Virtual TestNets + Web3Actions:
  https://docs.tenderly.co/virtual-testnets, https://docs.tenderly.co/web3-actions
- Stryker.js mutation testing for JavaScript:
  https://stryker-mutator.io/docs/stryker-js/introduction/
- Kent C. Dodds — "Testing Implementation Details" (anti-pattern
  catalogue applicable to web3 too):
  https://kentcdodds.com/blog/testing-implementation-details
- Cucumber / Gherkin language reference for BDD journey specs:
  https://cucumber.io/docs/gherkin/
- WAI-ARIA accessible-name selectors (basis for stable selectors):
  https://www.w3.org/TR/wai-aria/
- ethers.js v6 docs (the FAO site's chain client):
  https://docs.ethers.org/v6/
- FAO testnet site source: `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/`
  (entry points: `index.html`, `sale.html`, `proposals.html`,
  `create.html`; logic: `shared.js`, `sale.js`, `sepolia.js`,
  `bonds.js`, `create.js`, `home.js`).
- FAO CI workflow (Foundry only today):
  `/home/kelvin/repos/futarchy-fi/FAO/.github/workflows/test.yml`.
