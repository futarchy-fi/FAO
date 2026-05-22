# Rubric — Topic 1: Web3 Interface UX, Minimalism, Front-end Architecture

> Stateless evaluator rubric. The Codex evaluator should read **only**
> the files under `site-testnet/` (HTML / JS / CSS / README), this
> rubric, and the companion research file at
> `audit/research/topic-1-web3-ux.md`. Solidity sources (`src/`), tests
> (`test/`), and CI workflows belong to other topics and MUST be
> ignored when scoring this rubric.
>
> The live site is `https://fao-testnet.pages.dev`. The evaluator
> should *not* fetch live URLs; everything load-bearing is in the
> repo at `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/`.
>
> Output schema (per dimension): `{ dimension, score: 0.0–10.0,
> evidence: [{file, lines, note}], regressions_detected: [...],
> next_step: "..." }`.
>
> Aggregate: **min** across dimensions (the weakest dimension is the
> gate). A target of ≥ 8.0 on every dimension is required to exit the
> CAO loop for this topic.

---

## 0. Scope guardrails

- **In scope:** anything served from `site-testnet/`, plus the live
  Cloudflare Pages deployment that mirrors it.
- **Out of scope:** Solidity contracts in `src/`, contract tests in
  `test/`, agent scaffolding in `audit/`, dashboard apps under `apps/`.
- **Evaluator must distinguish:** "interface UX" (this rubric) from
  "interface tests" (Topic 2). A page that *looks* tested because the
  HTML has stable IDs scores 0 on Topic 2 but still scores on Topic 1.
- **Live site fetches are not required.** Every anchor is decidable
  from the source in the repo at evaluation time.

## 1. Scoring dimensions

Six dimensions, anchored at 0 / 3 / 5 / 7 / 9. Fractional scores
(4.5, 6.5, …) are allowed. Every score above 1 must cite at least
one file path with a line range. If no citation is provided, the
dimension is 0.

---

### D1 — Primary-action surface (one CTA, hierarchy, above-the-fold)

*Does each page lead with exactly one obvious next action, with the
rest of the surface receding into secondary affordances?*

Required: primary CTA in the first viewport (≤ 700 px scroll desktop,
≤ 600 px phone); one `.btn-primary` per page driving the page's chain
action; primary input one tab-stop from the primary button;
buy/sell-style comparisons presented as symmetric columns of equal
weight, not two competing primaries.

Anchors:

- **0** — Multiple competing primary buttons per page; primary CTA
  not in first viewport; no hierarchy between primary and secondary.
- **3** — Most pages have one primary, but at least one page has ≥ 2
  simultaneous `.btn-primary` driving different chain actions; no
  symmetric quote layout.
- **5** — Each page has exactly one canonical primary action;
  symmetric buy/sell layout where applicable; above-the-fold is
  uncluttered on desktop.
- **7** — All of (5), plus primary input is adjacent to the primary
  button (no intermediate scroll); secondary affordances collapsed
  behind `<details>` or a sub-page; quick-amount pills next to the
  amount input.
- **9** — All of (7), plus a documented "one CTA per page" rule
  (style guide / README) AND the page survives a 375 px squint-test
  (primary CTA obvious with fine detail blurred).

Regression detection: any commit that adds a second `.btn-primary`
to a page that previously had one, pushes the primary CTA past the
first viewport, or replaces an inline primary with a modal.

---

### D2 — Wallet-state handling (connect / chain / account / signature)

*Does the dApp handle the full wallet-state machine: disconnected →
discovering → connected → chain-mismatch → account-changed → signing
→ signed?*

Required: read-only data renders without a wallet; wallet discovery
uses EIP-6963 `announceProvider` event (not bare `window.ethereum`);
chain mismatch shown as in-page banner with a button calling
`wallet_switchEthereumChain` (never via `alert` / `confirm`);
`accountsChanged` and `chainChanged` reset signer state; connect
button shows wallet name + truncated address after connect; the
wallet popup never fires before an in-page review.

Anchors:

- **0** — No wallet handling, OR popup fires unprompted on page load,
  OR only `console.error` feedback.
- **3** — Connect via `window.ethereum` only; no EIP-6963; chain /
  account event listeners not wired; at least one `alert` /
  `confirm` / `prompt` in the wallet flow.
- **5** — `eth_requestAccounts` connect; `wallet_switchEthereumChain`
  with a fallback; `accountsChanged` / `chainChanged` reset signer.
  Browser-native modals still present in non-primary flows.
- **7** — All of (5), plus EIP-6963 with a multi-wallet picker;
  chain mismatch as in-page banner; zero `confirm` / `prompt` in the
  codebase; connect button identifies the provider.
- **9** — All of (7), plus an idle-disconnect timer, a cross-tab
  `storage`-event re-render guard, AND EIP-5792 `wallet_sendCalls`
  batching where supported.

Regression detection: any new `alert(` / `confirm(` / `prompt(` in
`site-testnet/*.js`; removal of the `accountsChanged` /
`chainChanged` listeners; a wallet popup that fires without a prior
`showConfirmCard()` call.

---

### D3 — Pre-confirm / pending / success / error affordances

*For every chain-mutating action, does the UI render four canonical
states (idle → reviewing → wallet-pending → mining → confirmed/failed)
with no browser-native modals?*

Required: every chain-write triggers an in-page review card with
decoded inputs (token, amount, slippage, recipient) *before* the
wallet popup; "wallet approval" vs "mining" are distinct status
strings; tx hash linked to `sepolia.etherscan.io` and survives the
next refresh tick; errors surface `e.shortMessage` (ethers-v6) and
re-enable the button; status element is `aria-live="polite"`.

Anchors:

- **0** — Wallet popup fires directly; no in-page review; failures
  silent or `console.error` only.
- **3** — Review summary on some flows; others jump straight to the
  wallet popup; pending state is "Loading…" with no tx-hash link;
  errors fall through to `window.alert`.
- **5** — One canonical pre-confirm card shared across buy /
  ragequit; status string with tx-hash link; two flows still use
  `confirm` / `prompt` for inputs.
- **7** — Every chain-write routes through an in-page review card;
  zero `confirm` / `prompt` in the codebase; "wallet pending" vs
  "mining" distinguished; status element has `aria-live="polite"`;
  success state persists across a background refresh.
- **9** — All of (7), plus in-page modals for wrap-ETH and approve
  flows; a ChainAck row that reads on-chain post-state ("Bought N
  for X ETH") from the receipt; quote-stale detection that blanks
  the cost row when the input changes mid-quote.

Regression detection: a new chain-write missing `showConfirmCard()`;
loss of `aria-live` on a status element; a tx-hash that fails to
render as `<a>`; an error surfaced as raw `e.message` (no
`shortMessage` fallback).

---

### D4 — Information density vs noise (numbers ≠ adjectives)

*Is the surface dense with numbers a user trades on, and free of
README paraphrase, marketing copy, and chartjunk?*

Required: every visible numeric uses `font-variant-numeric:
tabular-nums`; non-decision-time metadata (raw addresses, internal
IDs) is behind `<details>` or a sub-page; no adjective-stack
(`revolutionary`, `next-gen`, `trustless`) without an adjacent
number; primary numbers in the monospace stack; cost answer reachable
without scrolling past prose.

Anchors:

- **0** — Trading surface more prose than data; single font for
  numbers and prose; no tabular numerals; no collapsed stats.
- **3** — Tabular numerals applied but mixed with marketing prose;
  key facts hidden behind paragraphs; contract addresses inline in
  the primary surface.
- **5** — Tabular numerals on prices and balances; stats grid in
  dt/dd or two-column rows; addresses truncated to `0x18D1…BC5C`;
  long-tail metadata behind `<details>`.
- **7** — All of (5), plus first viewport shows ≥ 3 actionable
  numeric data points (price, balance, phase); prose copy ≤ 1 short
  paragraph per section; every adjective paired with a number;
  disclosed addresses are explorer-linked.
- **9** — All of (7), plus a "no chartjunk" CSS audit: 1 px dim
  borders only, ≤ 2 shadow levels in the stylesheet, no gradients
  in the trade surface, type ramp ≤ 5 sizes total.

Regression detection: a new section heading with no adjacent
numeric value; added prose without added numbers (visible in
`git diff`); removal of `font-variant-numeric: tabular-nums` from
a CSS rule.

---

### D5 — Mobile responsiveness + accessibility (a11y)

*Does the dApp work on a 375 px phone, meet WCAG 2.2 AA contrast
and target-size minimums, and remain operable with keyboard + screen
reader?*

Required: trading grids collapse to one column at ≤ 760 px; tap
targets in the primary surface ≥ 44×44 CSS px (WCAG 2.5.8); text
contrast ≥ 4.5:1 normal, ≥ 3:1 large; focus indicator ≥ 3:1 against
both states; form controls have `<label>` (not placeholder-only);
status elements use `aria-live`; animations respect
`prefers-reduced-motion`; no `alert` / `confirm` / `prompt` in
user-facing flows.

Anchors:

- **0** — No responsive breakpoints; primary surface unusable below
  760 px; no `<label>`; no focus rings; pulse animations run
  unconditionally.
- **3** — One media query collapses the trade grid; tap targets
  < 44 px in places; `outline: none` on at least one input; no
  `prefers-reduced-motion` guard.
- **5** — Responsive breakpoints cover the main page surfaces; most
  inputs use `<label>`; tap targets ≥ 44 px on primary actions;
  focus indicator visible (even if low contrast).
- **7** — All of (5), plus body contrast ≥ 4.5:1 and focus contrast
  ≥ 3:1; status elements have `aria-live="polite"`;
  `@media (prefers-reduced-motion: reduce)` collapses pulse
  animations; zero `alert` / `confirm` / `prompt` in user flows;
  no-JS fallback messaging.
- **9** — All of (7), plus an automated a11y audit (axe-core, Pa11y,
  Lighthouse) committed to CI scoring ≥ 95; documented keyboard-only
  flow for buy + bond; a screen-reader walk-through transcript
  checked into `docs/`.

Regression detection: any new `outline: none` in `styles.css`; any
new `<input>` without adjacent `<label>` or `aria-label`; any new
tap target < 44 px in the action surface; any new `@keyframes`
without a reduced-motion guard.

---

### D6 — Visual hierarchy + minimalism (typography, spacing, restraint)

*Is the visual system disciplined — a small type ramp, a small
palette, consistent spacing, the restraint Tufte calls "data-ink
ratio"?*

Required: type ramp ≤ 6 font-size steps total; palette ≤ 1 accent +
2 semantic (success, danger) + neutrals ramp; primary and secondary
buttons share min-width within a card row; dark theme default; light
theme (if any) maintains contrast budget; spacing on a 4 px or 8 px
grid with values via CSS variables; ≤ 2 shadow levels, none on
non-floating elements.

Anchors:

- **0** — No design system; inline styles in HTML; > 10 font sizes;
  rainbow palette; buttons different shapes per page.
- **3** — One stylesheet but undisciplined: ~8 font sizes; ≥ 4
  accent-style colors; button widths drift; inconsistent spacing.
- **5** — One stylesheet with CSS variables for color + typography;
  ≤ 6 font sizes; one accent + green/red semantics; cards share a
  border radius and padding scale.
- **7** — All of (5), plus tabular numerals on every visible number,
  ≤ 2 shadow levels in the stylesheet, primary + secondary buttons
  share min-width within a row, contrast budget verifiable from the
  variables.
- **9** — All of (7), plus a documented design-token file (CSS
  custom properties as a single block with comments); a light-theme
  parity test (body class toggle, all contrasts still pass); a
  "minimalism audit" diff in `docs/style-system.md` listing every
  shadow / gradient and its rationale.

Regression detection: a new hex literal not bound to a CSS variable;
a new font-size value outside the existing ramp; a new shadow
level; a button-width that differs from its sibling in the same row.

---

## 2. Worked self-evaluation of current `futarchy-fi/FAO` testnet site

Snapshot reference: HEAD on branch `workspace` as of evaluation date
**2026-05-22**. Live URL: `https://fao-testnet.pages.dev`. Source
tree: `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/`.

### Evidence sweep

| Probe | Result |
|---|---|
| Total stylesheet size | `styles.css` is 2014 lines; uses CSS variables for color (`--bg`, `--accent`, `--text-muted`) and typography (`--mono`). |
| Browser-native modals | **Three sites:** `shared.js:169` (`alert('Connect failed: ...')`), `bonds.js:436` (`confirm('Wrap … ETH → WETH now?')`), `bonds.js:465` (`prompt('Place YES bond …')`). |
| EIP-6963 wallet discovery | **Not implemented.** `shared.js:236-258` uses bare `window.ethereum`. |
| `accountsChanged` / `chainChanged` handlers | Present at `shared.js:262-273`. Reset signer to undefined and dispatch `fao:walletChanged`. |
| `aria-live` on status strings | **Absent** on `#sale-buy-status`, `#create-status`, `#create-instance-status`. Only `role="button"` / `role="listbox"` on the active-instance chip (`shared.js:113,117`). |
| `prefers-reduced-motion` guard | **Absent.** `@keyframes pulse-dot` (styles.css:266-274) and `pulse-text` (styles.css:300-303) run unconditionally. |
| `outline: none` occurrences | Three: `styles.css:1193`, `:1694`, `:1947` — all on inputs; replaced with `border-color: var(--accent)` but no separate focus ring. |
| Tabular numerals | Applied at `styles.css:1572, 1695, 1715, 1903, 1948, 1969`. Not universal: ranking-table cells inherit default font. |
| Pre-confirm card | `sale.html:137-144` + `sale.js:175-198` (`showConfirmCard` / `closeConfirmCard` / `onConfirmExecute`). Used for buy / ragequit / Uni buy / Uni sell. |
| Mobile breakpoint | `@media (max-width: 760px) { .trade-grid { grid-template-columns: 1fr; } }` at `styles.css:1869`. Other breakpoints at 720 px, 760 px, 500 px. |
| Tap-target sizing | Primary buttons (`.btn`) at `styles.css:155-163`: `padding: 12px 24px` ≈ 44 px height with 14 px font; quick-amount pills are smaller. |
| `<label>` usage | Form fields on `create.html:29-69` use `<label class="form-label">` wrapping pattern. Trade amount inputs use `<label class="trade-amount-wrap">` wrappers (`sale.html:72-76, 110-114`). |
| Hero CTA | `index.html:23-27` shows 3 buttons (`+ Create new futarchy`, `View live proposals`, `GitHub branch`); two are styled `btn-secondary`, one `btn-primary` — single primary on hero. |
| Sale page primary buttons | `sale.html:81, 90, 120, 129` — *two* `btn-primary` (`#trade-buy-sale-btn`, `#trade-sell-rq-btn`) plus two `btn-secondary` (Uniswap variants). Symmetric Buy/Sell columns; one primary per column. |
| Status string handling | `sale.js:168-173` (`setStatus`) — sets `textContent` + a class; no `aria-live`. Tx hashes rendered as `<a>` to Etherscan (`sepolia.js:356, 409`, `bonds.js:489, 516`). |
| Skeleton loaders | None. Pages display literal "Loading…" text (`sale.html:22, 27, 33` etc.) that never animates. |
| Wallet provider name on connect | Not surfaced. Connect button only shows truncated address (`shared.js:255`). |

### Per-dimension self-score

| Dim | Score | Justification | Next step to raise |
|---|---:|---|---|
| D1 — Primary-action surface | **6.5** | Hero on `index.html:23-27` is uncluttered with one primary; sale page (`sale.html:54-134`) uses symmetric Buy/Sell columns with one primary per column (Buy via sale / Ragequit). `create.html:71-74` has one primary "Create futarchy" with a "Cancel" link. Quick-amount pills (`sale.html:65-71, 104-109`) sit directly above the primary input. Above-the-fold on a 1280×800 desktop fits the hero strip + the trade grid. Gap: there is no documented "one CTA per page" rule, the hero exposes a third "GitHub branch" `btn-secondary` that competes for attention, and the proposals page (`proposals.html:33-41`) puts Connect + Submit at the same visual weight. | Demote the GitHub hero CTA to a footer link; introduce a `audit/specs/style-guide.md` rule; tighten the proposals form so a single primary CTA emerges only after wallet connect. |
| D2 — Wallet-state handling | **3.5** | Connect uses bare `window.ethereum` (`shared.js:237`); no EIP-6963. The chain-switch path exists (`shared.js:240-249`) and `accountsChanged` / `chainChanged` reset the signer (`shared.js:262-273`). But the connect failure path is a `window.alert()` (`shared.js:169`), the WETH-wrap step is a `window.confirm()` (`bonds.js:436`), and the YES-bond amount entry is a `window.prompt()` (`bonds.js:465`). The connect button does not identify the wallet provider after connect (only shows the address — `shared.js:255`). | Add EIP-6963 multi-provider discovery; replace `bonds.js:436,465` and `shared.js:169` with in-page modals (CSS scaffolding already exists at `styles.css:808`); surface provider name on the connect button. |
| D3 — Pre-confirm / pending / success / error | **6.0** | Sale page implements the full state machine: `showConfirmCard` (`sale.js:175-190`) renders parsed inputs before the wallet popup; `setStatus` (`sale.js:168-173`) distinguishes `pending` / `ok` / `error` classes; tx hashes link to Etherscan (`sale.js:608-648`, `sepolia.js:356,409`, `bonds.js:489,516`); errors use `e.shortMessage` (`sale.js:529, 558, 577, 612`). Gaps: bonds.js skips the pre-confirm card entirely and routes the user through `prompt()` then `confirm()`; the status element has no `aria-live`; success state is text-only with no chain-receipt summary; no quote-stale detection — the cost field can lag the input by one debounce tick. | Migrate bonds.js to use the same `showConfirmCard()` pattern from sale.js; add `aria-live="polite"` to `#sale-buy-status`, `#create-status`, `#create-instance-status`; add a quote-stale guard that blanks `#trade-buy-cost` when `#trade-buy-amount` changes. |
| D4 — Information density vs noise | **6.5** | Tabular numerals applied at trade-card prices, amounts, hero price (`styles.css:1572, 1695, 1715, 1903, 1948, 1969`). Sale stats hidden behind `<details>` (`sale.html:149-167`). Contract addresses truncated via `fmtAddr` (`shared.js:43`). Phase derived from on-chain data, not a marketing label (`sale.js:200-215`). Gaps: section subtitles on `index.html:36, 66`, `create.html:18-26`, `proposals.html:19-24` paraphrase code structure as prose ("Calls `FutarchyRegistry.createFutarchyPart1(...)`") — verifiable but not a number; ranking-table cells lack `tabular-nums`; the "v0 stack" section (`index.html:64-108`) is dense but mixes numeric stats (162 / 162 tests, 200 h) with prose-only rows. | Add `font-variant-numeric: tabular-nums` to `.rankings-table td`; replace at least one paraphrase subtitle with the actual number it implies; move the "Calls …" sentences into a `<details>` on the create page. |
| D5 — Mobile + accessibility | **3.5** | Responsive breakpoints exist at 720 px, 760 px, 500 px (`styles.css:484, 1129, 1624, 1745, 1869`). Form inputs use `<label>` (`create.html:29-69`, `sale.html:72-76`). Primary buttons hit ≈ 44 px tap height (`styles.css:155-163`). Active-instance chip uses `role="button"` + `tabindex="0"` (`shared.js:113`). Failures: `outline: none` on three input rules (`styles.css:1193, 1694, 1947`) with only border-color shift as focus signal — sub-3:1 against the elevated card; `aria-live` absent on all status elements; `prefers-reduced-motion` not handled (live pulse dots run on all sessions — `styles.css:266-303`); no automated a11y audit; quick-amount pills (`sale.html:65-70, 104-108`) are likely below 44 px and bond-card buttons in proposals also small; `window.alert/confirm/prompt` failures from D2 carry into D5 because these widgets are inherently inaccessible. | Add a real focus ring (`outline: 2px solid var(--accent); outline-offset: 2px`) on all inputs; wrap all `@keyframes` in `@media (prefers-reduced-motion: no-preference)`; add `aria-live="polite"` to status nodes; replace the three browser-native modals; bump `.sale-quick-btn` to a `min-height: 44px` and likewise for sort arrows in the rankings table; commit a Pa11y or axe-core CI step. |
| D6 — Visual hierarchy + minimalism | **6.5** | CSS uses semantic custom properties (`--bg, --accent, --accent-dim, --text, --text-muted, --text-dim, --mono` — `styles.css:4-17`); single accent (`#3effb0`); dark theme default; ≤ ~6 font sizes in trade cards (11/12/13/14/16/18 px observed); button styles share padding + radius (`styles.css:155-163`); shadow usage is restrained (`--accent-glow` on a `box-shadow` for the live-dot). Gaps: button widths drift in the pre-confirm card vs the trade card (`.sale-confirm-actions .btn { flex: 1 }` — `styles.css:1860`) vs the hero (auto-width); no documented design-token file outside the `:root` block; no light-theme parity; ranking table inherits default styles without explicit token use; magic-number paddings creep in (`padding: 24px`, `16px`, `12px` mixed without a documented scale). | Extract `--space-1` ... `--space-6` tokens; document the type ramp in a comment block; align button min-widths across the confirm card and the hero; add a light-theme token override stub. |

**Aggregate (min across dimensions):** **3.5 / 10.** Median ≈ 6.25.

The min-rule binds on D2 and D5, both pulled down by the same root
cause: three browser-native modal calls (`shared.js:169`,
`bonds.js:436`, `bonds.js:465`) plus the missing `aria-live` /
`prefers-reduced-motion` / `outline` handling. Fixing those four
items is the single largest unblock for this topic.

---

## 3. Anti-patterns to penalize (the "do not count this" catalogue)

The evaluator must NOT award points for the following — they look
like UX work but don't satisfy the rubric.

- **AP1 — Skeleton-loader theatre.** A `.skeleton` that animates
  indefinitely while the page issues no network request. D3 −1.0.
- **AP2 — `aria-label` parroting visible text.** `<button
  aria-label="Buy">Buy</button>` adds zero SR information. Don't
  count the attribute; score the underlying behaviour.
- **AP3 — Mobile breakpoint that hides the primary action.** A
  responsive collapse is fine; also hiding the primary button on
  small viewports is a regression. D5 −2.0.
- **AP4 — Pre-confirm that re-shows wallet calldata.** The card
  must add information the wallet does not natively decode (route,
  slippage, post-state); "you're calling `buy(uint256)`" is calldata
  theatre. D3 −1.0.
- **AP5 — A11y attribute on a hidden element.**
  `aria-live="polite"` on `display: none` never announces. D5 −1.0
  per occurrence.
- **AP6 — Inline style override of a design token.** `<div
  style="color: #ff0000">` defeats the system. D6 −0.5 per
  occurrence (cap −3.0).
- **AP7 — Connect-wallet gate on read-only pages.** Home and
  proposals must render public on-chain reads with no signer. D1
  −1.5.
- **AP8 — Toast that auto-hides before the tx hash is copyable.**
  Success state that disappears in < 5 s costs the user their
  explorer link. D3 −1.0.

---

## 4. Evaluator notes — what NOT to count

- Solidity contract quality (`src/`) — Topic 3 / 4.
- Test coverage for the UI — Topic 2.
- README prose quality — Topic 6.
- Whether ethers v6 vs viem was chosen — both are acceptable;
  only the behaviour matters.
- The size of the JS bundle as long as ethers UMD is the dominant
  weight; the static-site verifiability claim from research §3 is
  satisfied by any deployment without webpack/vite opacity.
- The choice of dark theme as the only theme — research §6 does not
  mandate a light theme; D6 only penalizes if a *broken* light
  theme exists.
- Cosmetic polish (animations, hover states, microcopy charm) that
  is not anchored to a numeric or semantic rubric dimension.
- Whether the testnet site supports WalletConnect; mobile in-app
  wallets are out of scope for v0 (research §7 lists this as a
  future-state pattern, not a baseline).

The evaluator should NOT lower a dimension's score for absence of a
feature unless the feature is explicitly named in an anchor at
≤ the score being awarded. Example: a site at 5 on D5 cannot be
docked for lacking the automated a11y audit that only enters the
anchors at 9.

---

## 5. Codex evaluator runbook (stateless)

For each scoring pass, run this script verbatim:

1. `ls site-testnet/` — confirm the six HTML pages, six JS files
   (`shared.js`, `sale.js`, `bonds.js`, `sepolia.js`, `home.js`,
   `create.js`), and `styles.css` are present. If anything is
   missing, every dimension caps at 3 and you may stop.
2. `grep -nE 'alert\(|confirm\(|prompt\(' site-testnet/*.js` —
   non-zero docks D2 by 1.5 and D5 by 1.0 per occurrence (floor at
   the anchor for "≥ 1 native modal", which is 3).
3. `grep -nE 'aria-live|aria-label|role=' site-testnet/*.html
   site-testnet/*.js` — at least one `aria-live` wired to a status
   element is required to clear D3 score 7.
4. `grep -nE 'prefers-reduced-motion|@keyframes' site-testnet/styles.css`
   — every `@keyframes` must sit under a `prefers-reduced-motion`
   parent media query to clear D5 score 7.
5. `grep -nE 'eip6963|announceProvider' site-testnet/*.js` — zero
   caps D2 at 5.
6. `grep -nE 'font-variant-numeric|tabular-nums' site-testnet/styles.css`
   — < 5 occurrences caps D4 at 5.
7. For each of `sale.html`, `create.html`, `proposals.html`,
   `index.html`: count `class="btn btn-primary"`. ≥ 3 on any page
   caps D1 at 5.
8. `grep -oE 'font-size:[^;]+;' site-testnet/styles.css | sort -u
   | wc -l` — > 8 distinct values caps D6 at 5.
9. Compute D1–D6 with anchors in §1; apply penalties from §3.
10. Aggregate = `min(D1, …, D6)`. Emit JSON per §0 schema.

The evaluator must NOT:

- Open files outside `site-testnet/` (except this rubric and its
  companion research doc).
- Reward TODOs or promises in comments — only realised behaviour
  scores.
- Run a dev server; all evidence is decidable from source.

---

## Sources

- Companion research dossier:
  `/home/kelvin/repos/futarchy-fi/FAO/audit/research/topic-1-web3-ux.md`
- FAO testnet site sources:
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/index.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/sale.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/create.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/proposals.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/contracts.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/docs.html`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/shared.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/sale.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/bonds.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/sepolia.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/create.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/home.js`,
  `/home/kelvin/repos/futarchy-fi/FAO/site-testnet/styles.css`.
- Live deployment under evaluation: <https://fao-testnet.pages.dev>.
- WCAG 2.2 — <https://www.w3.org/TR/WCAG22/>
- EIP-6963 (multi-injected provider discovery) —
  <https://eips.ethereum.org/EIPS/eip-6963>
- EIP-5792 (`wallet_sendCalls`) — <https://eips.ethereum.org/EIPS/eip-5792>
- `prefers-reduced-motion` (MDN) —
  <https://developer.mozilla.org/en-US/docs/Web/CSS/@media/prefers-reduced-motion>
- ethers v6 docs — <https://docs.ethers.org/v6/>
- CoW Swap pre-confirm pattern — <https://docs.cow.fi/cow-protocol/tutorials/cow-swap/swap>
- Polymarket mobile case study — <https://www.lazertechnologies.com/case-studies/polymarket>
- Edward Tufte, *The Visual Display of Quantitative Information*
  (data-ink ratio + chartjunk principles cited throughout §1.D4 /
  §1.D6).
