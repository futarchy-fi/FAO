# Topic 1 — Web3 Interface UX, Minimalism, and Front-end Architecture

> Research report supporting the rubric at `audit/rubrics/topic-1-web3-ux.md`.
> Scope: best practices for the kind of small, opinionated finance dApp that
> FAO is — multi-page static site on Cloudflare Pages, ethers-v6 in the
> browser, EVM testnet, no SSR. Citations at the bottom.

---

## 1. State of the art (2025–2026)

Web3 finance UI converged around a small set of patterns over the last two
years. The platforms most often cited as the reference bar are Uniswap (spot
swap), Aave v3 (lend/borrow), Polymarket (prediction markets), Hyperliquid
(perp DEX), CoW Swap (intent-based DEX), Across (cross-chain bridge), and the
Farcaster mini-app surface. Common patterns:

- **One action surface per page.** Uniswap's swap, Aave's supply/borrow,
  Polymarket's bet card — each loads with the primary action visible above
  the fold, with secondary actions (route picker, advanced settings, history)
  collapsed into disclosure controls. Polymarket's product team has stated
  publicly that the homescreen acts as a "clutter-free dashboard" with
  probability percentages displayed prominently and color-coded movements,
  because prediction markets are time-sensitive and "even a few seconds of
  friction can lead to lost engagement or missed trades."
- **Pre-confirm cards (not browser confirms).** CoW Swap, Across and 1inch
  all show an in-page review card that lists exact inputs and outputs
  ("you pay X, you receive ≥ Y, slippage Z%, route via …") and only *then*
  trigger the wallet popup. Browser-native `window.confirm()` / `prompt()`
  are not used by any modern reference dApp — they are inaccessible, can't
  be styled, and don't communicate on-chain semantics.
- **Visible status machine.** Every action has at least four observable
  states: idle → wallet-pending → tx-pending (mining) → confirmed/failed.
  Hyperliquid additionally renders an order-book ack ("filled at $X").
  The status string is read by screen readers (`aria-live="polite"`) on
  better-built dApps.
- **EIP-6963 wallet discovery.** Since October 2023, the recommended way to
  detect installed wallets is the EIP-6963 `eip6963:announceProvider` event,
  not bare `window.ethereum`. Wagmi 2+, RainbowKit, Web3Modal 3+, MetaMask
  SDK, OKX Wallet, Coinbase Wallet, and Crypto.com Wallet all support it.
  Falling back to `window.ethereum` only works for the last-injected wallet
  and silently breaks for users with multiple wallets installed.
- **Intent-based confirmation.** CoW Swap pioneered the pattern of showing
  a *signed intent* preview (EIP-712 typed data, decoded fields) rather than
  raw calldata. Modern wallets (Rabby, MetaMask 2024+, Frame) decode typed
  data natively, but the dApp is still responsible for surfacing the
  semantic summary *before* triggering the wallet, because the wallet
  doesn't know context like "this swap will exceed your daily budget."
- **Batch transactions (EIP-5792 `wallet_sendCalls`).** Farcaster's mini-app
  SDK and the latest MetaMask now let dApps batch "approve + swap" into a
  single user confirmation. Reference dApps that haven't migrated yet still
  show two clearly numbered prompts ("Step 1 of 2: approving USDC, Step 2
  of 2: swapping").
- **External verification anchors.** Every contract address on the page is
  a link to a block explorer (Etherscan, Blockscout). Token symbols are
  short-circuit clickable to the token's explorer page. CoW Swap and Aave
  go further: token logos load from a trusted token list (TokenLists,
  CoinGecko) with the contract address surfaced on hover as a verification
  cue against impersonation tokens.

## 2. Minimalist design principles for finance dApps

The minimalism that works for finance is not pure subtraction — it is
*Tufte-style high data density with zero chartjunk*. Edward Tufte's framing
(data-ink ratio, chartjunk, small multiples) maps directly onto a trading
panel: every pixel of ink should either show a number the user trades on,
or label a number, or delimit two unrelated numbers. Decoration is the
enemy. Concrete rules that the reference dApps follow:

1. **Numerals are tabular.** Prices, amounts, percentages, balances all use
   `font-variant-numeric: tabular-nums` so digits align column-wise. This is
   a one-line CSS win that ~doubles the perceived legibility of a price
   ladder.
2. **One typeface for currency, one for prose.** Monospace (or tabular sans)
   for numbers; humanist sans for instructions. Mixing the two inside a row
   destroys scanability.
3. **Color encodes state, not decoration.** Two semantic colors (success
   green, danger red) plus one accent. Phase / status badges are pill
   shapes with high-contrast background tint + matching foreground. Hover
   styles do not introduce new colors.
4. **Whitespace as the only chrome.** Borders are 1px, dim. Cards do not
   carry shadow unless they are floating (modal, dropdown). A trading
   surface with three shadow levels reads as a slot machine.
5. **Disclosure for the long tail.** Stats nobody needs at decision time
   (raw contract addresses, internal IDs, ABI minutiae) go behind a
   `<details>` element or a sub-page. Don't dump them on the primary
   page just because they're cheap to render.
6. **Truncate addresses, but make full address copyable.** `0x18D1…BC5C`
   is the canonical short form; clicking should open the explorer and
   right-clicking should expose copy-full. Never show full addresses inline
   on small screens — they break the grid.
7. **Quote symmetry.** Buy and Sell columns should mirror each other:
   matching widths, matching primary-button color, matching status string
   position. Polymarket's Yes/No buttons, Uniswap's input/output rows,
   Hyperliquid's bid/ask ladders all enforce this.

## 3. Static site vs SPA vs hybrid trade-offs

Web3 finance front-ends have, on the whole, drifted away from heavy SPAs
toward static or hybrid deployments — driven by three pressures unique to
the space:

| Axis | Static (multi-page HTML + vanilla JS) | SPA (React + bundler) | Hybrid (SSR/SSG, e.g. Next.js) |
|---|---|---|---|
| **Verifiability / supply-chain risk** | Highest. The shipped artefact is small, human-readable, and easy to diff vs. the repo. No webpack/vite/turbopack opacity. | Lowest. A 2 MB minified bundle is effectively unverifiable. Front-end hijack attacks (DNS or CDN compromise) are the dominant attack surface — NIST IR 8475 calls the front-end "the weakest link" in the web3 stack. | Middle. SSG output is auditable, but the runtime adds React hydration. |
| **First-paint latency** | <500 ms typical on Cloudflare Pages. | 2–4 s for a cold cache. | 800 ms–1.5 s. |
| **No-JS fallback** | Possible (read-only). | None. | Possible (read-only with SSR). |
| **Multi-page navigation** | Native browser. Works with browser back/forward, sharable URLs, no client-side router bugs. | Client-side router; can break Cmd-click, back button. | Native. |
| **Author velocity for complex flows** | Lower for ≥5 distinct flows; per-page JS gets repetitive. | Higher — component reuse. | Higher. |
| **Bundle size on testnet sites** | <50 kB total (ethers UMD is the bulk). | 300 kB–2 MB. | 200 kB–800 kB. |

The current consensus for *single-purpose* finance UIs (a swap, a bond, a
sale) is **static with progressive enhancement** — load read-only data
from RPC into a pre-rendered HTML skeleton, and only require JS for wallet
actions. CoW Swap's widget is shipped as a static iframe target for
exactly this reason. Larger product surfaces (Uniswap app, Aave app) stay
SPA because the action surface count justifies the cost.

For FAO, a Cloudflare Pages static deployment of separate HTML pages is
the right choice — see §6 for why.

## 4. Wallet-connect flows

The reference flow in 2026, in order of how a user experiences it:

1. **Pre-connect state**: the page is fully usable in read-only mode.
   Prices, balances (where on-chain only), proposals, charts all render
   *without* a wallet. The Connect button is visible but secondary; the
   primary CTA next to it is read-only ("View live proposals", "Browse
   markets").
2. **EIP-6963 discovery**: on Connect click, the dApp enumerates announced
   providers, dedupes by `uuid`, and shows a wallet picker. If only one
   provider exists, it can auto-select. If `window.ethereum` is the only
   handle available, fall through to it — but log a warning so power users
   on multi-wallet setups can switch via the wallet's "Set as default" UI.
3. **Chain-mismatch handling**: if the active chain ID doesn't match the
   site's chain, do not bail with an alert. Instead, surface an in-page
   banner: "Switch to Sepolia (chainId 11155111)" with a primary button
   that calls `wallet_switchEthereumChain`. If the chain isn't added to the
   wallet, call `wallet_addEthereumChain`.
4. **Pre-action review card**: before any transaction, show an in-page
   review summary with the exact decoded fields and an explicit Confirm
   button. The Confirm button is what triggers the wallet popup, not the
   primary action button. This avoids the "I clicked Swap and a popup
   appeared with hex that didn't look like what I expected" footgun.
5. **Tx-pending state**: after the wallet popup is confirmed, the page
   shows an explorer-linked pending state (`tx sent: 0xabc… waiting
   confirmation`). The primary action button is disabled. The status
   element is `aria-live="polite"`.
6. **Confirmed / failed state**: on receipt, the page renders a
   confirmation row with the resulting on-chain state ("Bought 10 ACME for
   0.001 ETH ✓") and refreshes the underlying data. On failure, the error
   message is the wallet's `shortMessage` (ethers-v6 surfaces this), not
   the full stack trace.
7. **Account / chain change**: wallet `accountsChanged` and `chainChanged`
   events reset the signer, the displayed wallet address, and any cached
   per-wallet state.

Anti-patterns documented in the UX literature: a confirmation `alert()`
or `confirm()`; an unkeyed loading spinner with no text; a "transaction
submitted" toast that disappears before the user can copy the tx hash; a
wallet popup that fires before any in-page confirmation; copy that uses
the word "sign" without distinguishing gas-paying transactions from
gas-free EIP-712 signatures.

## 5. Error / pending / confirmed states

The 4-state model (idle → pending → confirmed → failed) is the de-facto
minimum. The reference platforms layer extra states on top:

- **Wallet-prompt vs tx-mining.** "Waiting for wallet approval" and
  "Mining…" are distinct states with distinct UI; conflating them confuses
  users about whether they need to click their wallet again.
- **Approval needed.** ERC-20 trade flows show a separate "Approving X
  spend" pending state before the actual swap. Aave and CoW Swap label
  this clearly. EIP-5792 batching collapses this into one prompt where
  the wallet supports it.
- **Quote stale.** Uniswap and CoW Swap blank out the cost row and
  re-quote when an input changes. Showing an out-of-date quote in the
  cost field while a new one is being fetched is a footgun (user clicks
  Buy expecting old quote, gets new one).
- **Thin pool / no liquidity.** A quoter that returns a number from an
  empty pool reads as a legitimate price. Reference dApps detect this and
  show "no liquidity" / "thin pool — large slippage" instead of an
  arbitrary number. Uniswap's frontend caps the displayed slippage at
  99.99% and renders a red banner.
- **State-machine visibility.** For long-running flows (auctions,
  TWAP-windowed proposals), the phase is rendered as a badge that maps
  observable on-chain state to a small enum (initial sale / bonding
  curve / phase ended / not started). Polymarket's market cards use the
  same pattern (open / closed / resolved).

Status colors converged on green = success, amber = pending, red = error,
gray = disabled / no state. Status strings should be:

- specific ("Approving USDC spend on Sale 0x011F…5678" not "Loading…")
- linkable to the explorer where applicable
- preserved across re-renders (don't blow away the success message just
  because a 30 s background refresh ran)
- `aria-live="polite"` so screen readers announce them

## 6. Accessibility (a11y) standards for finance UIs

WCAG 2.2 AA is the operative target (W3C published WCAG 2.2 in October
2023; finance regulations in the EU, UK, US increasingly cite it). The
2.2 additions that hit finance dApps hardest:

- **2.4.11 Focus Not Obscured (Minimum)** — sticky topbars and modal
  overlays must not hide the focused element. Many web3 dApps fail this
  because they use sticky topbars + `scroll-into-view` that lands the
  focused row under the topbar.
- **2.5.7 Dragging Movements** — any drag interaction (e.g., a slippage
  slider) must have a non-drag alternative (text input, +/- buttons).
- **2.5.8 Target Size (Minimum)** — interactive targets must be ≥24×24
  CSS pixels. Address-truncate buttons, sort arrows, close-X icons
  frequently fail this. Reference dApps now use ≥32×32 in the action
  surface and ≥24×24 elsewhere.
- **3.3.8 Accessible Authentication** — wallet connection counts as
  authentication; the flow must not require remembering or transcribing
  anything. EIP-6963 wallet picker is fine; a "type your wallet address
  here" flow is not.

Color contrast: text/icon contrast ≥4.5:1 for normal, ≥3:1 for large or
non-text. Focus indicator contrast ≥3:1 vs both focused and unfocused
states. Dark-mode trading UIs often fail focus contrast because the focus
ring uses the same color as the accent and disappears against the accent
button.

Other rules that apply specifically to web3 finance:

- Form fields have explicit `<label>` elements (not placeholder-only).
- Status messages live in `aria-live` regions.
- Animations respect `prefers-reduced-motion`. Pulsing live-dot
  indicators must collapse to a static dot under reduced motion.
- Browser-native `alert()`, `confirm()`, `prompt()` are inaccessible
  (no aria semantics, can't be styled to indicate destructive vs
  non-destructive action, can't be screen-reader navigated). They must
  not appear in a finance flow.
- Keyboard navigability for the whole action surface. Connect button,
  amount input, quick-amount pills, and primary action are all
  tab-reachable in document order.
- Tabular numerals (`font-variant-numeric: tabular-nums`) — a small
  perceptual accessibility win for users with low vision.

## 7. Responsive / mobile patterns

Mobile usage in DeFi went from rounding error to plurality between 2022
and 2025 (Polymarket reports >50% of trades from mobile during peak event
windows). Patterns:

- **Single-column collapse.** Trade grids collapse to a single column at
  ~760 px. Buy stays above Sell (most trade flows are buy-first).
- **Touch targets ≥44×44.** Apple HIG / WCAG-amplified. Quick-amount
  pills, primary action buttons, sort arrows all sized accordingly.
- **Hide-but-don't-remove secondary affordances.** Stats grids collapse
  from 2-up to 1-up. Address tables go inside `<details>`. The topbar
  collapses links to a hamburger only when there are ≥5 links *and* the
  viewport is <600 px.
- **Sticky CTA on mobile.** On long forms (e.g., FAO's Create page) the
  primary action button is sticky-bottom on mobile so it's always
  reachable. Cancel goes secondary.
- **No hover-only affordances.** Tooltips, hover-to-reveal addresses,
  hover-to-show-actions all break on touch. Either render the affordance
  inline or trigger it on tap with a visible toggle.
- **WalletConnect for mobile wallets.** Mobile browsers don't typically
  have injected wallets. Production dApps support WalletConnect (or
  Reown AppKit) so users can scan a QR code from a mobile wallet on the
  same device or a different one.
- **In-app browser quirks.** MetaMask Mobile and Coinbase Wallet have
  in-app browsers that inject `window.ethereum` but quirk the
  `eth_chainId` return type, the QR fallback, and the deep-link return.
  Reference dApps test these explicitly.

## 8. Implications for FAO

FAO's current architecture (static multi-page on Cloudflare Pages,
ethers-v6 UMD, vanilla JS, dark theme, monospace numerals) is *aligned*
with the verifiability and minimalism principles above. The gaps are
specific and fixable:

1. **Wallet discovery uses bare `window.ethereum`.** No EIP-6963. Users
   with multiple wallets installed get the wrong one.
2. **`alert()` on connect failure** (shared.js:169) and **`confirm()` /
   `prompt()` in bonds.js** (bonds.js:436, 465). All three are
   accessibility regressions and inconsistent with the otherwise styled
   pre-confirm card on the sale page.
3. **No `prefers-reduced-motion` guards.** The `pulse-dot` animation runs
   for users who have requested reduced motion.
4. **No `aria-live` on status strings.** `#sale-buy-status`,
   `#create-status`, `#create-instance-status` all change text
   dynamically without screen-reader announcement.
5. **Focus indicators are inconsistent.** `outline: none` on
   `.sale-form input:focus` (styles.css:1192) and reliance on
   `outline: 1px solid var(--accent)` elsewhere — the accent color does
   not meet 3:1 contrast against the elevated card background in all
   contexts.
6. **No no-JS fallback messaging.** Pages render an HTML skeleton with
   "Loading…" text that never resolves if JS is disabled or
   ethers.umd.min.js fails to load.
7. **Connect button doesn't show wallet provider name** after connect —
   it shortens the address but doesn't identify which wallet is
   connected, which is the standard reference-dApp pattern.

These items map directly to the dimension anchors in the rubric.

---

## Sources

- [WCAG 2.2 — W3C Recommendation](https://www.w3.org/TR/WCAG22/)
- [WCAG for Finance — webability.io](https://www.webability.io/blog/wcag-for-finance-ensuring-accessibility-in-the-digital-banking-age)
- [WebAIM: Contrast and Color Accessibility](https://webaim.org/articles/contrast/)
- [prefers-reduced-motion — MDN](https://developer.mozilla.org/en-US/docs/Web/CSS/Reference/At-rules/@media/prefers-reduced-motion)
- [Designing accessible animation — Pope Tech](https://blog.pope.tech/2025/12/08/design-accessible-animation-and-movement/)
- [EIP-6963 — How to Implement (MetaMask)](https://metamask.io/news/how-to-implement-eip-6963-support-in-your-web3-dapp)
- [EIP-6963 — Connecting to dapps (MetaMask Help Center)](https://support.metamask.io/more-web3/dapps/connecting-to-dapps-with-eip-6963-multi-wallet-discovery)
- [EIP-6963 — OKX Wallet explainer](https://web3.okx.com/learn/eip-6963-delivering-better-web3-ux-with-multi-injected-provider-discovery)
- [EIP-5792 batched calls — Farcaster Mini Apps changelog](https://miniapps.farcaster.xyz/docs/sdk/changelog)
- [Farcaster Mini Apps — wallet integration](https://miniapps.farcaster.xyz/docs/guides/wallets)
- [CoW Swap docs — Market orders / swap flow](https://docs.cow.fi/cow-protocol/tutorials/cow-swap/swap)
- [CoW Swap — Widget docs (slippage configuration)](https://docs.cow.fi/cow-protocol/tutorials/widget)
- [Designing Wallet Experiences — UXCentury](https://medium.com/uxcentury/designing-wallet-experiences-reducing-friction-in-web3-onboarding-0fa52bedea79)
- [Building Polymarket's mobile app — Lazer case study](https://www.lazertechnologies.com/case-studies/polymarket)
- [Polymarket Mobile App Design — Finextra](https://www.finextra.com/blogposting/31216/polymarket-mobile-app-design-uiux-features-that-drive-engagement-amp-trust)
- [Uniswap v4 — official site](https://v4.uniswap.org/)
- [Uniswap v4 — design kit (Figma)](https://www.figma.com/community/file/1334811795504110095/uniswap-v4-pools-official-open-source-product-design-kit)
- [Aave v3 — app](https://app.aave.com/)
- [Hyperliquid — app](https://app.hyperliquid.xyz/trade/AAVE)
- [Security Best Practices in Web3 Frontend — StatusNeo](https://statusneo.com/security-best-practices-in-web3-frontend-development/)
- [NIST IR 8475 — Security Perspective on Web3](https://nvlpubs.nist.gov/nistpubs/ir/2025/NIST.IR.8475.pdf)
- [Cloudflare Pages — docs overview](https://developers.cloudflare.com/pages/framework-guides/deploy-anything/)
- [Static vs SSR vs SPA — Hygraph](https://hygraph.com/blog/difference-spa-ssg-ssr)
- [Static vs SPA tradeoffs — Smashing Magazine](https://www.smashingmagazine.com/2020/07/differences-static-generated-sites-server-side-rendered-apps/)
- [Edward Tufte's data principles — GeeksforGeeks summary](https://www.geeksforgeeks.org/data-visualization/mastering-tuftes-data-visualization-principles/)
- [Tufte's principles — DamienG notes](https://damieng.com/blog/2015/08/05/notes-on-edward-tuftes-presenting-data-and-information/)
- [Data viz best practices for finance — visbanking.com](https://visbanking.com/data-visualization-best-practices)
- [Intents-First UX Patterns — Thinking Loop](https://medium.com/@ThinkingLoop/10-intents-first-ux-patterns-that-make-web3-feel-easy-e875fd4a289f)
- [Web3 Mobile + WalletConnect — Medium](https://medium.com/@ancilartech/web3-on-mobile-bridging-the-gap-with-walletconnect-and-in-app-browsers-3c86cba2f942)
