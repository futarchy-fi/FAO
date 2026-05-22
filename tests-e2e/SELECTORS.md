# Selector conventions for `tests-e2e/`

Every interactive element the test suite touches MUST be addressable by a stable selector. This file is the single source of truth.

## Rules

1. **Prefer `data-testid`** on elements that exist for test addressability. Naming: `data-testid="<page>-<concern>-<sub>"`, kebab-case (e.g. `data-testid="sale-buy-amount-input"`).
2. **Use `role` + accessible name** when the element is already semantic (`getByRole('button', { name: /buy via sale/i })`). This gives a11y testing for free.
3. **Avoid** CSS-class selectors (the class can be refactored without a notice), text fragments alone (copy can shift), and `:nth-child` (DOM order shifts).
4. **One purpose per testid.** If a selector is reused for two different actions, split.

## Canonical testid registry

These are the **required** testids the source must expose. The site is currently missing many of these — adding them is part of the Topic-2 D5 lift.

### Global

| Testid | Element |
|---|---|
| `skip-nav` | Skip-to-main-content link |
| `no-js-notice` | No-JavaScript fallback notice |

### Home (`/`)

| Testid | Element |
|---|---|
| `topbar-connect` | "Connect" button in topbar |
| `topbar-active-chip` | Active-instance chip in topbar |
| `topbar-wallet-identity` | Selected wallet provider identity chip |
| `topbar-status` | Inline status banner in topbar |
| `topbar-switch-sepolia` | Chain-mismatch action button |
| `wallet-provider-picker` | EIP-6963 provider picker dialog body |
| `wallet-provider-option-<rdns-or-id>` | Provider option button in wallet picker |
| `rankings-table` | The "Active futarchies" table |
| `rankings-row-<id>` | Per-row clickable on the rankings table |
| `rank-action-buy-<id>` | "Buy →" pill per row |
| `rank-action-proposals-<id>` | "Proposals" pill per row |
| `rank-filter-all` / `rank-filter-initial-sale` / `rank-filter-bonding-curve` | Filter pills |

### Create (`/create`)

| Testid | Element |
|---|---|
| `create-name` / `create-symbol` / `create-description` | Form fields |
| `create-price` / `create-min-sold` / `create-sale-duration` | Sale params |
| `create-timeout` / `create-twap` / `create-bond` | Resolver/bond params |
| `create-submit` | Submit button |
| `create-status` | Inline status line |
| `confirm-card-create` | Create-futarchy decoded transaction review card |
| `confirm-card-create-confirm` / `confirm-card-create-cancel` | Create-futarchy review actions |

### Buy (`/sale`)

| Testid | Element |
|---|---|
| `sale-hero-symbol` / `sale-hero-name` / `sale-hero-price` | Hero strip values |
| `sale-phase-badge` | The colored phase badge |
| `sale-decision-strip` | Compact decision-time numeric strip |
| `sale-decision-wallet` / `sale-decision-sold` / `sale-decision-liq` | Wallet capacity, sale progress, and spot liquidity values |
| `trade-buy-amount` | Buy amount input |
| `trade-buy-quick-<n>` | Quick-buy chips (1/10/100/1000) |
| `trade-buy-cost` | Cost preview value |
| `trade-buy-sale-btn` | "Buy via sale" CTA |
| `trade-buy-uni-btn` | "Buy via Uniswap" inline-swap CTA |
| `trade-buy-uni-external` | External Uniswap link |
| `trade-sell-amount` / `trade-sell-quick-<pct>` / `trade-sell-rq-out` | Sell side |
| `trade-sell-rq-btn` / `trade-sell-uni-btn` | Sell CTAs |
| `sale-confirm-card` | Pre-confirm card |
| `sale-confirm-go` / `sale-confirm-cancel` | Pre-confirm actions |
| `sale-buy-status` | Inline status line |

### Proposals (`/proposals`)

| Testid | Element |
|---|---|
| `sep-proposals` | Proposal list container |
| `sep-proposal-card-<id>` | Per-proposal card |
| `bond-place-yes-<id>` / `bond-place-no-<id>` / `bond-graduate-<id>` | Bond actions |
| `create-proposal-name` / `create-proposal-desc` / `create-proposal-submit` | Create-proposal form |
| `confirm-card-proposal` | Create-proposal decoded transaction review card |
| `confirm-card-resolve` | Resolve-proposal decoded transaction review card |
| `confirm-card-bond` | YES/NO/graduate bond decoded transaction review card |
| `confirm-card-proposal-confirm` / `confirm-card-proposal-cancel` | Create-proposal review actions |
| `confirm-card-resolve-confirm` / `confirm-card-resolve-cancel` | Resolve-proposal review actions |
| `confirm-card-bond-confirm` / `confirm-card-bond-cancel` | Bond review actions |

## Adding new testids

When you add a new interactive element to the site, also add its testid here. Otherwise tests for it cannot be deterministic. CI should fail any PR that introduces a new clickable / typeable element without a testid (future lint).
