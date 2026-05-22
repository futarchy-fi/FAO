# Topic 2 — Rubric: High-level interface testing + user flows

> Stateless evaluator rubric. The Codex evaluator should read **only** the
> files cited below plus anything inside `site-testnet/`, `test-e2e/`
> (if it exists), `cypress/`, `playwright*`, and `.github/workflows/`.
> Solidity tests under `test/` belong to Topic 4 and MUST be ignored
> when scoring this rubric.
>
> Output schema (per dimension): `{ dimension, score: 0.0–10.0,
> evidence: [{file, lines, note}], penalties_applied: [...],
> next_step: "..." }`.
>
> Aggregate: arithmetic mean of all dimensions. Target ≥ 8.0 per
> dimension AND ≥ 8.0 aggregate to exit the CAO loop.

## 0. Scope guardrails

- **In scope:** anything driving the browser interface in
  `site-testnet/` (Playwright, Cypress, Synpress, Vitest+JSDOM,
  Stryker, etc.), plus CI wiring that invokes them.
- **Out of scope:** `test/*.t.sol`, `test/fork/*.t.sol`,
  `test/integration/*.t.sol`, all of `src/`, all of `script/`.
- **Evaluator must distinguish:** "test of the interface" vs. "test of
  a contract that the interface happens to call." The latter does
  *not* count toward this rubric.

## 1. Scoring dimensions

Each dimension is 0–10 with five behavioral anchors. Scores may be
fractional (e.g. 4.5). The evaluator must cite specific file paths
and line ranges for every score above 1.

---

### D1 — User-flow coverage breadth

*How many of the rubric's named user flows have at least one
end-to-end test that drives the real UI and asserts on chain state?*

- **0** — Zero E2E tests exist that drive the testnet site. (Solidity
  tests do not count.)
- **3** — 1–2 named flows covered, happy path only, may use mocked
  chain.
- **5** — 3–4 named flows covered against a real fork; remaining flows
  documented as TODO.
- **7** — 6–7 named flows covered; each has at least one happy-path
  spec; high-priority flows have failure-mode coverage.
- **9** — All 10 named flows in §3 covered with happy path + ≥ 1
  failure mode each; cross-flow journeys (e.g. create → buy → bond)
  exist.

Special floor: if any of P0 flows (Create instance, Buy via sale, Place
YES bond) lack coverage, cap the dimension at 5 regardless of other
coverage.

---

### D2 — Test signal density (% non-useless tests)

*Of all tests in the interface suite, what fraction provide unique,
non-tautological signal?*

Classifier: a test counts as "useful" iff (a) it asserts on
post-action chain state OR computed UI output that depends on chain
state, AND (b) it is not subsumed by another test's mutation-killset.
A test is "useless" iff it matches ≥ 1 anti-pattern in §4.

- **0** — No tests, OR ≥ 50% of tests match an anti-pattern.
- **3** — 30–50% useful tests; many `expect(button).toBeVisible()`
  smoke checks; no chain assertions.
- **5** — 50–70% useful; the paying flows assert on balance deltas;
  duplicate coverage on read-only flows.
- **7** — 70–85% useful; mutation testing run at least once; clear
  removal of tautologies in code review.
- **9** — ≥ 85% useful; Stryker.js mutation score ≥ 70% on
  high-value files (`sale.js`, `bonds.js`); duplicate-coverage scan
  in CI.

Hard rule: if the suite has ≤ 5 tests total, this dimension is capped
at 5 — a tiny suite cannot demonstrate density.

---

### D3 — Realism (fork vs mock)

*How close are the tests to the production environment?*

- **0** — Tests don't touch a chain at all, OR no tests exist.
- **3** — Tests use `jest.mock` / `vi.mock` stubs of `window.ethereum`
  and contract ABIs. No chain.
- **5** — Tests run against a non-forked Anvil with hand-deployed
  fixtures. Wallet is stubbed (`@web3-onboard/headless` or similar).
- **7** — Tests run against an Anvil **fork** of Sepolia at a pinned
  block. Wallet is stubbed but signer addresses match real personas.
- **9** — Anvil fork + Synpress-driven real MetaMask extension for
  paying flows; stub wallet allowed only for read-only flows; CI runs
  on schedule against a fresh fork.

Hard rule: if any flow involving funds (buy, sell, bond, ragequit) is
mocked rather than fork-driven, that flow contributes 0 to the
dimension's average.

---

### D4 — Failure-mode coverage

*How thoroughly does the suite exercise the unhappy paths a real user
hits?*

Failure axes to cover (count each): wallet locked, wallet not
installed, user rejects tx, wrong chain, insufficient ETH, insufficient
token balance, RPC 5xx / timeout, tx reverts with reason, tx
under-priced / replaced, slippage exceeded, sale phase ended mid-flow,
account switched mid-flow, page reloaded mid-tx.

- **0** — None of the failure axes have tests.
- **3** — 1–3 axes covered (typically just user-rejects).
- **5** — 4–6 axes covered; covered axes have one happy + one sad spec.
- **7** — 7–10 axes covered; each high-value flow has at least 3
  failure-mode specs.
- **9** — 11–13 axes covered; chaos directory exists; specs include
  reorg/replace-by-fee and account-switched-mid-tx.

---

### D5 — Selector & maintainability quality

*Are selectors stable, and is the suite resistant to copy/CSS changes?*

Static analysis of the spec files. Categorize every selector:
- **Stable**: `data-testid`, `role="..."` + `name`, semantic
  `getByLabel`.
- **Acceptable**: `#some-id` *when* the id is documented as test-stable.
- **Brittle**: `:nth-child(N)`, `.some-css-class`, `text=...` on
  user-facing copy, unanchored XPath.

- **0** — No tests, OR every selector is brittle.
- **3** — < 30% stable; CSS class selectors throughout; tests break on
  any copy change.
- **5** — 30–60% stable; some `data-testid` but inconsistent; flake
  rate > 5%.
- **7** — 60–85% stable; canonical `data-testid` map in
  `helpers/selectors.ts`; flake rate ≤ 2%.
- **9** — ≥ 85% stable; no `nth-child` or class selectors; CI publishes
  flake-rate report; lint rule blocks brittle selectors in PRs.

---

### D6 — Performance & developer cycle time

*Can a developer run the suite locally without context-switching, and
does CI complete in reasonable time?*

- **0** — No suite, OR no documented way to run it.
- **3** — Suite exists but takes > 30 min OR requires manual setup of
  Sepolia RPC keys + MetaMask seed.
- **5** — Documented `npm test:e2e`; runs in 10–30 min locally; CI
  runs on push but is non-blocking.
- **7** — Runs in < 10 min locally with one command; parallelized to
  ≤ 5 min in CI; traces uploaded as CI artifacts on failure.
- **9** — Runs in < 5 min locally via cached Anvil fork; < 3 min in CI
  with sharding; pre-commit hook runs the smoke subset; traces +
  video + RPC log artifacts on every failure.

---

### D7 — Specification & journey-map fidelity

*Does each test trace back to a written user-journey definition?*

- **0** — No journey definitions exist; tests are ad hoc.
- **3** — A README lists flows but specs don't reference them.
- **5** — Each spec file names the flow it covers in a header
  comment; journey map exists but is partial.
- **7** — All flows from §3 have a Gherkin or markdown journey map;
  every spec links back to a journey-map row; persona library exists.
- **9** — Journey maps are version-controlled, reviewed alongside
  specs, machine-checked (a CI step asserts every journey-map row has
  ≥ 1 spec or an explicit "not tested" marker with rationale).

---

## 2. Worked self-evaluation of current `futarchy-fi/FAO`

Snapshot reference: HEAD on branch `workspace` as of evaluation date
**2026-05-22**.

### Evidence sweep

| Probe | Result |
|---|---|
| Existence of `test-e2e/`, `e2e/`, `playwright.config.*`, `cypress/`, `synpress.config.*` at repo root or under `site-testnet/` | **None.** `ls /home/kelvin/repos/futarchy-fi/FAO/site-testnet/` returns only HTML/JS/CSS/README/CNAME; no test directory exists at the repo root. |
| `package.json` anywhere | **Absent.** Repo has no Node project; site is pure static + CDN-loaded ethers v6. |
| CI test wiring for the interface | **None.** `.github/workflows/test.yml` runs only `forge fmt --check`, `forge build`, `forge test`. |
| `data-testid` attributes in HTML | **Zero.** `grep -c 'data-testid' site-testnet/*.html` would return 0. Selectors would have to use `id="..."` (49 in `sale.html`, 13 in `create.html`, etc.). |
| Journey maps / Gherkin specs | **None.** `audit/research/` and `site-testnet/README.md` describe flows narratively but no executable spec exists. |
| Solidity tests covering interface? | **Out of scope.** `test/UniswapV3LiquidityAdapter.t.sol`, `test/InstanceSale.t.sol`, `test/SaleSpotSeeder.t.sol` test contracts, not the UI. They do **not** count toward this rubric. |

### Scores

| Dim | Score | Justification | Next step to raise |
|---|---:|---|---|
| D1 — User-flow coverage breadth | **0.0** | Zero E2E tests; none of the 10 named flows in §3 are exercised against the UI. | Land one Playwright spec for `Buy via sale` against an Anvil fork at a pinned Sepolia block. |
| D2 — Signal density | **0.0** | No tests to classify. | After D1 lands, ensure the spec asserts on the buyer's on-chain token balance, not on the toast. |
| D3 — Realism | **0.0** | No chain harness, no Anvil setup, no MetaMask harness. | Add `test-e2e/fixtures/anvil.ts` that boots `anvil --fork-url $SEPOLIA_RPC --fork-block-number <pin>`. |
| D4 — Failure-mode coverage | **0.0** | No happy-path tests exist, let alone unhappy. | Once one happy-path is green, add `chaos/wallet-rejected.spec.ts`. |
| D5 — Selector & maintainability | **0.0** | No spec files exist. HTML uses `id="..."` heavily (workable) but no `data-testid` yet (`grep -c 'id="' site-testnet/sale.html` = 49). | Add `data-testid` to every interactive element in `sale.html`, `create.html`, `proposals.html`, `index.html`. |
| D6 — Performance & cycle time | **0.0** | No `npm test`, no CI job, no local runner. | Add a `test-e2e/` directory with `npx playwright test` runnable; wire into `.github/workflows/test.yml`. |
| D7 — Spec & journey-map fidelity | **0.5** | Narrative journey descriptions exist in `audit/research/topic-2-interface-testing.md` and `site-testnet/README.md`, but no executable links between specs and journey map. Awarding 0.5 for the prose-level inventory. | Convert the §3 inventory into per-flow Gherkin files under `test-e2e/journeys/*.feature`. |

**Aggregate (mean):** **0.07 / 10**.

This is the correct baseline. The site has zero interface tests today;
any incremental movement above 0 represents real progress.

---

## 3. User-flow inventory (≥ 8 flows required by the topic; 10 listed)

The Codex evaluator MUST score against this canonical inventory. Each
flow has a priority and the rubric dimensions it most directly feeds.

| # | Flow ID | Title | Priority | Page surfaces | Chain calls (read/write) | Why it matters |
|---|---|---|---:|---|---|---|
| F1 | `create-instance` | Create new futarchy instance (Part 1 + Part 2) | **P0** | `create.html`, `create.js` | W: `createFutarchyPart1`, `createFutarchyPart2`; R: `instancesCount`, `instances(id)`, `FutarchyPart1Created` event | Anyone can deploy a futarchy — broken create = no growth. Two-tx flow with redirect; high failure surface. |
| F2 | `buy-via-sale` | Buy tokens via `InstanceSale.buy` during initial or curve phase | **P0** | `sale.html`, `sale.js` | W: `buy(numTokens) payable`; R: `currentPriceWeiPerToken`, `initialPhaseFinalized`, `totalAmountRaised`, `effectiveSupply` | Primary user funding path; price math + ETH-to-token conversion = high bug surface. |
| F3 | `ragequit` | Exit at sale-derived price via `ragequit(numTokens)` | **P1** | `sale.html`, `sale.js` | W: `ragequit(uint256)`; R: `quoteRagequit`, `balanceOf` | User-protection mechanic; if the UI miscomputes refund it destroys trust. |
| F4 | `buy-via-uniswap-inline` | Buy via the SwapRouter02 multicall inline (no leaving site) | **P1** | `sale.html`, `sale.js` | W: `exactInputSingle` + `multicall`; R: QuoterV2 `quoteExactInputSingle` (staticCall), pool `slot0`/`liquidity` | Slippage math, fee tier, WETH wrap/unwrap, multicall encoding. High failure surface. |
| F5 | `sell-via-uniswap-inline` | Sell tokens to ETH via Uniswap with auto-unwrap | **P1** | `sale.html`, `sale.js` | W: `approve` then `exactInputSingle` + `unwrapWETH9` via multicall | Token→ETH path; approval UX; unwrap correctness. |
| F6 | `create-proposal` | Permissionless proposal creation (`FAOFutarchyFactory.createProposal`) | **P0** | `proposals.html`, `sepolia.js` | W: `createProposal(name, desc, ...)`; R: `marketsCount`, `proposals(i)`, per-proposal `marketName`/`description`/`questionId`/`conditionId` | Core governance entry; gating step before bonds. |
| F7 | `place-yes-bond` | Place YES bond on a proposal via `FutarchyArbitration.placeYesBond` | **P0** | `proposals.html`, `bonds.js` | W: `placeYesBond(proposalId, amount)`, plus `WETH.deposit` (wrap helper) and `WETH.approve` if needed; R: `getProposal`, `baseX`, `requiredYes`, `withdrawable` | Money-on-the-line; arbitration-id derivation from proposal address is a known stub (see `bonds.js:23`); needs strict UI assertions. |
| F8 | `place-no-bond` | Place NO bond matching the current YES exactly | **P1** | `proposals.html`, `bonds.js` | W: `placeNoBond(proposalId)`; R: `getProposal.yesBond.amount`, `withdrawable` | Reactive flow; amount auto-derived from on-chain YES bond. |
| F9 | `try-graduate` | Try to graduate a proposal from QUEUED to EVALUATING | **P1** | `proposals.html`, `bonds.js` | W: `tryGraduate(proposalId)` (`staticCall` first for feasibility); R: `getProposal.state` | State-machine transition; user pays gas for a feasibility-conditioned action. |
| F10 | `withdraw-refund` | Withdraw the user's accumulated refund balance | **P1** | `proposals.html`, `bonds.js` | W: `withdraw()`; R: `withdrawable(address)` | Easiest flow to silently break (zero-balance UI states, double-spend prevention). |

**Stretch flows (P2, not required for ≥ 8 minimum but reward
coverage):**
- `resolve-proposal` — operator runs auto-promote daemon; the UI must
  reflect resolution state via `FAOTwapResolver`.
- `switch-active-instance` — picks a different instance from the
  rankings table on the home page; verify all per-instance state
  re-renders.
- `connect-wallet` — first-time connect, MetaMask install nudge,
  chain switch to Sepolia.
- `cross-page-navigation` — preserve `?inst=<id>` URL param across
  every internal link.

---

## 4. Anti-patterns to penalize (the "useless test" catalogue)

The evaluator must scan every spec file and flag any of the following.
Each occurrence reduces the relevant dimension score (typically D2).
Six patterns are required by the topic; eight are listed.

### AP1 — Tautological assertion
A test where the expected value equals a value the test itself just set,
with no chain or computation between.

```js
// ANTI-EXAMPLE
await page.fill('#trade-buy-amount', '100');
expect(await page.inputValue('#trade-buy-amount')).toBe('100');  // proves nothing
```

Penalty: −1.0 to D2 per occurrence (cap −5.0).

### AP2 — Toast / DOM-only after chain action
The test triggers a chain-mutating action then asserts only on UI
feedback, never on on-chain effect.

```js
// ANTI-EXAMPLE
await page.click('#trade-buy-sale-btn');
await metamask.confirm();
await expect(page.locator('.toast-success')).toBeVisible();  // didn't check balance
```

Required follow-up: read the buyer's token balance via the public
client and assert the delta. Penalty: −1.5 to D2 + D3 if missing.

### AP3 — Mocked `window.ethereum` for a paying flow
For any flow in F1, F2, F3, F4, F5, F7, F8, F9, F10, mocking
`window.ethereum` instead of driving a real wallet against an Anvil
fork is disallowed.

Penalty: D3 for that flow drops to 0; D2 −1.0.

### AP4 — Mocked contract reads
Using `page.route` to intercept the JSON-RPC endpoint and inject a
specific `eth_call` response. This hides real curve / TWAP / queue
math bugs.

Penalty: D3 −2.0; the test does not count toward D1.

### AP5 — Brittle selectors
Any of: `:nth-child`, raw class selectors (`.btn-primary`),
unanchored text matchers when the copy is unstable (e.g. button
labels), absolute XPath.

Penalty: D5 −0.5 per occurrence.

### AP6 — No-network passthrough
Test passes when the chain RPC is unreachable. Detect by adding a
mandatory CI shard that runs the suite with the Anvil port blocked;
any spec that still passes is by definition not exercising chain
interaction.

Penalty: D2 −2.0 per occurrence; D3 −2.0.

### AP7 — Coverage-theater smoke
A test that visits every page and clicks every button but contains
zero `expect` calls (or only `expect(.).toBeVisible()` calls). These
exist solely to lift line coverage.

Penalty: D2 −2.0 per file; test does not count toward D1.

### AP8 — Mutation-killset duplicates
Two or more tests that, per Stryker.js output, kill the identical set
of mutants. They are redundant; one should be removed.

Penalty: D2 −0.5 per duplicate pair, encouraging deletion.

---

## 5. Required artifacts for a complete suite

A "complete" interface test suite (target ≥ 8.0 aggregate) must
produce these artifacts. The evaluator should check for each.

- `test-e2e/playwright.config.ts` with `retries: 0`, `fullyParallel:
  true`, `reporter: ['list', 'html']`.
- `test-e2e/fixtures/anvil.ts` — boots Anvil with `--fork-url
  $SEPOLIA_RPC --fork-block-number <pin>`, takes a snapshot in
  `beforeAll`, reverts in `afterEach`.
- `test-e2e/fixtures/wallet.ts` — Synpress wallet helper exporting
  `connect(persona)`, `confirmTx()`, `rejectTx()`,
  `switchNetwork(chain)`.
- `test-e2e/fixtures/personas.ts` — at least the 9 personas in
  Topic 2 research §2.3.
- `test-e2e/journeys/*.spec.ts` — one spec per flow F1–F10.
- `test-e2e/chaos/*.spec.ts` — one spec per failure axis in D4.
- `test-e2e/helpers/selectors.ts` — canonical `data-testid` map; any
  selector used outside this file is a lint error.
- `test-e2e/helpers/chain.ts` — viem-based public client helpers for
  reading balances/events.
- `.github/workflows/test.yml` extended with an `e2e` job that runs
  after `check`, with `playwright-report` uploaded as an artifact.
- `stryker.conf.mjs` — mutation testing config targeting
  `site-testnet/*.js`.
- `audit/research/topic-2-interface-testing.md` (already exists) —
  authoritative source for what the suite means.

Failure to produce any of these caps the aggregate at **6.5**.

---

## 6. Codex evaluator runbook (stateless)

The evaluator should follow this script verbatim per scoring pass:

1. `ls site-testnet/ test-e2e/ playwright.config.* cypress/
   synpress.config.* package.json 2>/dev/null` — confirm presence /
   absence of test infra. If nothing exists, every dimension is
   ≤ 1.0 and you may stop with that result.
2. For each existing spec file: classify each `expect` call against
   §4; tally tautologies, toast-only assertions, mocked-wallet uses,
   brittle selectors.
3. For each flow F1–F10: search for at least one spec that imports
   the relevant page or asserts against the relevant contract
   address; mark covered / not covered.
4. Check `.github/workflows/test.yml` for an `e2e`-style job.
5. Run Stryker.js if a config exists; record the mutation score.
6. Compute D1–D7 with the anchors in §1; apply penalties from §4.
7. Emit the JSON-schema report from §0 plus a 50-word delta versus
   the previous scoring pass (if `audit/evaluations/topic-2-*.json`
   exists).

The evaluator must NOT:
- Score Solidity tests under `test/`.
- Reward adapter or contract coverage — that's Topic 4.
- Penalize the absence of a build step; the site is intentionally
  static.
- Apply the anti-patterns from §4 to non-existent code (zero ≠
  brittle).

---

## Sources

- Topic-2 research dossier:
  `/home/kelvin/repos/futarchy-fi/FAO/audit/research/topic-2-interface-testing.md`
- FAO testnet site source files:
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/index.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/sale.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/create.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/proposals.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/contracts.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/docs.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/shared.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/sale.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/sepolia.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/bonds.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/create.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/home.js`.
- FAO CI workflow:
  `/home/kelvin/repos/futarchy-fi/FAO/.github/workflows/test.yml`.
- Foundry / Anvil reference: https://book.getfoundry.sh/anvil/
- Playwright best practices: https://playwright.dev/docs/best-practices
- Synpress: https://github.com/Synthetixio/synpress
- viem test client: https://viem.sh/docs/clients/test
- Stryker.js: https://stryker-mutator.io/docs/stryker-js/introduction/
- Tenderly Virtual TestNets: https://docs.tenderly.co/virtual-testnets
- Gherkin language reference: https://cucumber.io/docs/gherkin/
