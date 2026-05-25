---
canonical: site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers
scope: Authoritative wiki coverage of the FAO testnet UI token system, button hierarchy, sale-page primary-action count, wallet-provider UX, dashboard time-axis UI contract, and remaining T1 UI-polish plan.
not-scope: E2E journey assertions live in [E2E Journey Map](../40-verification/e2e-journey-map.md); deployment data flow lives in [Deployment](../10-fao-repo/deployment.md).
last-rebuilt: 2026-05-23T03:13:06Z
---
# UI Architecture

The UI architecture page tracks visual hierarchy, wallet-provider choice, transaction review, type-scale token use, readable numeric/address surfaces, lazy browser dependency loading, visual QA evidence, and a11y affordances that are easy to regress without changing contract behavior. It matters because duplicate primaries, split token declarations, hard-coded font sizes, wallet ambiguity, missing decoded review cards, hidden transaction status, ordinal chart axes, unstable numerals, and missing status/skip affordances were direct causes of low abstraction and convergence signals. The canonical mechanism is `tokens.css` as token source, `styles.css` as consumer, `shared.js` as the ethers/RPC/topbar loader, one active sale trade primary, isolated transaction-confirm emphasis, tokenized typography, decoded review cards before wallet confirmation, persistent sale transaction links, sale pre-confirm gas estimates, an EIP-6963 provider picker with hardened wallet-session state, tabular/truncated data surfaces, skip/no-JS/status affordances, committed axe/screenshot artifacts, visual snapshot baselines, and dashboard charts that use timestamps as their x-axis. `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--fs-base`, `site-testnet/styles.css@358b1a14f9927b2eafd7790d094a8432be60a0d9::skip-nav`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`, `audit/axe/home.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::violations`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::toHaveScreenshot`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::screenshots`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, this page covered token ownership, `btn-ghost`, and sale primary count, but did not mention the ops/audit dashboard's new time-axis semantics. `audit/wiki/30-themes/ui-architecture.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#sale-page-primary-count`

Current HEAD keeps the token/button rules and changes dashboard charts to pass `{x: new Date(r.timestamp), y: score}` data into Chart.js time scales. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderMinChart`, `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderPerTopicCharts`

Since source HEAD `fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd`, `audit/agents/worker-ui-polish.md` added an explicit T1 worker mission for Web3 UX gap-closing; this is a work plan, not evidence that the UI fixes already landed. `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::Mission`, `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::Goal condition`

Since source HEAD `80a3fa25e322f8af7248b04192a3649854fe9fe0`, T1.D2 landed as code: `shared.js` now discovers EIP-6963 providers, persists the selected provider key, renders a picker and topbar wallet identity chip, and routes page scripts through `window.connectWallet()`. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::EIP6963_ANNOUNCE`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::WALLET_PROVIDER_STORAGE_KEY`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::showWalletProviderPicker`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::topbar-wallet-identity`

Since source HEAD `46903c84a2c8835cd13fb5e2ecfa858df20bea50`, T1.D6 landed as code: `styles.css` now consumes `--fs-*` tokens across body, nav, hero, cards, tables, forms, modals, topbar status, and sale/trade surfaces; `home.js` also replaced inline status colors with token-backed CSS classes. `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::T1.D6`, `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::font-size: var(--fs-3xl)`, `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::.topbar-status`, `site-testnet/home.js@953817cf3c19e2ab87e08af1aee8919541455dd8::dash-value-ok`

Since source HEAD `aba4046dec32448a09daa308d8fea8cb661671be`, T1.D3 landed decoded transaction review cards for create, proposal, resolve, YES/NO bond, and graduate actions; F1 now waits for the create review card and clicks its confirm action. `site-testnet/create.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-create`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/proposals.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-bond`, `site-testnet/sepolia.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showConfirmCard`, `site-testnet/bonds.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showBondConfirm`, `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-create-confirm`

Since source HEAD `5c672c5540af07df5b6ab368e8ff606fc23649b6`, T1.D6 tightened token usage again: `tokens.css` added semantic background, overlay, neutral, warning, border, and card-shadow tokens, while `styles.css` replaced hard-coded translucent colors/shadows and reduced section/hero display sizes to `--fs-xl`. `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--bg-alt`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--overlay`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--shadow-card`, `site-testnet/styles.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::background: var(--overlay)`, `site-testnet/styles.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::box-shadow: var(--shadow-card)`, `site-testnet/styles.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::.hero-title`

Since source HEAD `671ad3b54c68d83ba1c96974c2cf133877f1321e`, T1.D1/T1.D4/T1.D5 landed in code: sale trade buttons now keep one primary side through `setPrimaryTradeSide`, review-card confirm buttons use `tx-confirm-primary` instead of global `btn-primary`, numeric and address surfaces use tabular/truncated presentation, and every public site page has skip navigation plus a no-JS notice. `site-testnet/sale.js@6b365d1f9fc57a6a6c43c4f8e2618b8155ff089d::setPrimaryTradeSide`, `site-testnet/sale.html@6b365d1f9fc57a6a6c43c4f8e2618b8155ff089d::aria-current`, `site-testnet/styles.css@b596f7fe09ab8b07901aca035223a85be0ffe611::tx-confirm-primary`, `site-testnet/styles.css@8744da8b1441501b5767d5c9d1abb11d05a8d843::font-variant-numeric: tabular-nums`, `site-testnet/sale.js@8744da8b1441501b5767d5c9d1abb11d05a8d843::fmtAddr(addr)`, `site-testnet/styles.css@358b1a14f9927b2eafd7790d094a8432be60a0d9::skip-nav`, `site-testnet/create.html@358b1a14f9927b2eafd7790d094a8432be60a0d9::no-js-notice`

Since source HEAD `216b40e5766ac222e2b6e33d92c0a358ad2500c4`, UI evidence moved past worker plans: sale status links persist Etherscan tx URLs after confirmation cards close, the sale page exposes decision-time wallet/sold/liquidity numerics, `shared.js` records wallet-session state with idle clearing and EIP-5792 capability detection, FE-QA has committed axe/Lighthouse/screenshot scripts and workflows, and `minimalism-audit.md` records the type, shadow, gradient, and literal-color inventory. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::closeConfirmCard({ preserveStatus: true })`, `site-testnet/sale.html@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-strip`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::WALLET_IDLE_MS`, `tests-e2e/axe-helper.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::runAxeOn`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#literal-color-inventory`

The audit rubric surface changed earlier too: Topic 1 v2 requires tool-emitted evidence for visual hierarchy, performance, a11y, and snapshot regression, and the new committed FE-QA stack now gives those workers concrete entry points instead of only prose tasks. `audit/rubrics/v2/topic-1-web3-ux-v2.md@6b8c7252c17c84895a3b28ae771d018bdbb8d31e::requires tool-emitted evidence`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::capture:screenshots`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::a11y`, `package.json@6283126ee2e83ddc47966eaea01e40f8f52143ee::lighthouse`

Since source HEAD `9fd41ee02a1834112f1ff580e9e262bdecd1468b`, FE-QA produced artifacts instead of only entry points: six axe JSON files show empty `violations` and zero critical/serious/moderate/minor counts, the screenshot manifest lists 12 desktop/mobile PNG captures, and Playwright snapshot baselines landed under `tests-e2e/__snapshots__`. `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`, `audit/axe/sale.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::critical`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::home-desktop.png`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::sale-mobile.png`

Since source HEAD `aa5ca7235dc8c3834e5db2edd7bfd3214875b5ed`, the visual artifacts were refreshed through Playwright Chromium and the PNG byte sizes changed from raw oversized captures to browser-rendered screenshot files. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::renderer`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::bytes`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, UI evidence gained four concrete checks: `wallet-provider.read-only.spec.ts` proves stored EIP-6963 identity and `5792` capability chips restore without prompting, `confirm-cards.read-only.spec.ts` plus `audit/review-cards/T1.D3.json` proves decoded rows and controls for create/proposal/resolve/bond cards, `snapshots.read-only.spec.ts` masks dynamic regions before visual comparison, and `web-vitals.json` records current mobile budget outcomes. `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::topbar-wallet-identity`, `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::topbar-wallet-capabilities`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::confirm-card-${c.action}`, `audit/review-cards/T1.D3.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::decodedRows`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::DYNAMIC_REGION_SELECTOR`, `audit/lighthouse/web-vitals.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::pages`

Since source HEAD `5e532972f18bafdcd8f6d2c48bf314db0da24a6c`, the UI performance contract changed from blank-loading placeholders to meaningful first-paint fallbacks: home renders a default active futarchy row, sale renders token/price/progress/trade defaults, and `shared.js` refreshes topbar links and active-instance chip in place after deferred data loads. `site-testnet/index.html@239313c31b169d4cc5073e6178aa372ee1e88c98::rank-row-active`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::sale-hero-symbol`, `site-testnet/sale.html@239313c31b169d4cc5073e6178aa372ee1e88c98::trade-buy-cost`, `site-testnet/shared.js@239313c31b169d4cc5073e6178aa372ee1e88c98::refreshTopbarState`, `audit/lighthouse/web-vitals.json@239313c31b169d4cc5073e6178aa372ee1e88c98::pass`

At source HEAD `37603636e5194b202ad5438ce80bf9909aad42c8`, the site-RPC refresh leaves `shared.js` as the lazy ethers loader and fork-mode bridge: `loadEthers()` appends the versioned jsdelivr script only when needed, `window.faoRpcUrl`/`window.faoForkMode` publish the active RPC mode, and home, sale, proposal, and bond scripts await `window.loadFaoEthers()` before constructing providers from `rpcUrl()`. Dirty HTML overlays still decide where public pages include `shared.js` and whether page-local ethers tags remain removed. `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::ETHERS_SRC`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoForkMode`, `site-testnet/home.js@37603636e5194b202ad5438ce80bf9909aad42c8::ensureEthers`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::rpcUrl`, `site-testnet/sepolia.js@37603636e5194b202ad5438ce80bf9909aad42c8::rpcUrl`, `site-testnet/bonds.js@37603636e5194b202ad5438ce80bf9909aad42c8::rpcUrl`, `site-testnet/contracts.html@HEAD::shared.js`

At source HEAD `5a3953405c6017b990b4b3add843dff77c5f6f86`, sale buy and ragequit previews add a `Gas estimate (≈)` row before wallet confirmation. `estimateSaleGas()` encodes the sale call, uses `provider.estimateGas()`, and falls back to "Wallet will estimate before signing" when a provider, sale address, or sender is missing. `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::Gas estimate (≈)`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::Wallet will estimate before signing`

## Token Source Of Truth

`tokens.css` states its own role as "Single source of truth for color / spacing / radius / type-scale values." `site-testnet/tokens.css@3fad3cad278325c13a191c472f1be9ba5d15db02::Single source of truth for color`

`styles.css` consumes variables and documents that design tokens live in `tokens.css`; it says not to redeclare `:root` there. `site-testnet/styles.css@3fad3cad278325c13a191c472f1be9ba5d15db02::do NOT re-declare`

Typography is tokenized in the consumer too: body uses `--fs-base`, nav/logo surfaces use `--fs-sm`/`--fs-lg`, current section and hero titles use `--fs-xl`, and compact labels use `--fs-xs`/`--fs-sm`. `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::body`, `site-testnet/styles.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::.section-title`, `site-testnet/styles.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::.hero-title`, `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::.sale-stat-label`

The latest token pass adds semantic wrappers for common translucent values, so overlays, warnings, neutral chips, soft surfaces, and card shadows now have named variables instead of repeated literal `rgba(...)` values. `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--warning-soft`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--surface-wash`, `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--neutral-bg`, `site-testnet/styles.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::background: var(--surface-wash)`

## Button Hierarchy

`btn-primary` remains the accent-filled primary CTA, `btn-secondary` remains bordered and transparent, and `btn-ghost` is transparent with muted text and no visible border. `site-testnet/styles.css@3fad3cad278325c13a191c472f1be9ba5d15db02::.btn-primary`, `site-testnet/styles.css@3fad3cad278325c13a191c472f1be9ba5d15db02::.btn-secondary`, `site-testnet/styles.css@3fad3cad278325c13a191c472f1be9ba5d15db02::.btn-ghost`

The sale page's trade buttons use `trade-btn-primary`/`trade-btn-secondary`, and `sale.js::setPrimaryTradeSide` toggles `aria-current` so only buy or sell is visually primary at one time. `site-testnet/styles.css@358b1a14f9927b2eafd7790d094a8432be60a0d9::.trade-btn-primary`, `site-testnet/sale.js@6b365d1f9fc57a6a6c43c4f8e2618b8155ff089d::setPrimaryTradeSide`, `site-testnet/sale.html@6b365d1f9fc57a6a6c43c4f8e2618b8155ff089d::trade-sell-rq-btn`

Review-card confirm buttons are no longer counted as normal page primaries: create, proposal, resolve, bond, and sale confirmation actions use `tx-confirm-primary`. `site-testnet/create.html@b596f7fe09ab8b07901aca035223a85be0ffe611::tx-confirm-primary`, `site-testnet/proposals.html@b596f7fe09ab8b07901aca035223a85be0ffe611::confirm-card-proposal-confirm`, `site-testnet/sale.html@b596f7fe09ab8b07901aca035223a85be0ffe611::sale-confirm-go`

## Sale Decision And Transaction Status

The sale page now has a compact decision strip for the three numbers a buyer needs before choosing a path: wallet capacity, sale progress, and spot liquidity. `site-testnet/sale.html@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-wallet`, `site-testnet/sale.html@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-sold`, `site-testnet/sale.js@b913bd0b7fb28c1e233d034833b8e9eafc62d16c::sale-decision-liq`

Sale transaction status is linkable evidence now: `setTxStatus` appends an Etherscan transaction link, and buy/sell/ragequit flows preserve that status when the confirmation card closes. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::explorerTx`, `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::Mining sale buy tx`, `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::Mining ragequit tx`

## Dashboard Time Axis

The audit dashboard no longer treats rounds as unlabeled ordinal points for its main trend charts; `renderMinChart` builds time-series points from each evaluation timestamp. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderMinChart`

Per-topic charts use the same `{x: Date, y: score}` shape and configure `x.type = 'time'`, so cross-topic trends align by wall time rather than array index. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderPerTopicCharts`

The heatmap headers also format timestamps through `fmtTs()`, making the table's columns comparable to the chart x-axis labels. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::fmtTs`, `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderHeatmap`

## Wallet Provider UX

`shared.js` treats provider choice as first-class UI state: it listens for `eip6963:announceProvider`, requests provider announcements, normalizes provider metadata, stores the selected provider key in `localStorage`, and falls back to legacy injected providers when no EIP-6963 records are found. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::EIP6963_REQUEST`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::normalizeProviderInfo`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::addLegacyProviders`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::rememberWalletProvider`

The picker is test-addressable through `wallet-provider-picker` and `wallet-provider-option-<rdns-or-id>`, while the topbar exposes `topbar-wallet-identity`, `topbar-connect`, and `topbar-switch-sepolia` selectors. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::wallet-provider-picker`, `tests-e2e/SELECTORS.md@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::wallet-provider-option-<rdns-or-id>`, `tests-e2e/SELECTORS.md@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::topbar-switch-sepolia`

`connectWallet()` now resolves the selected provider before requesting accounts, publishes `window.faoSelectedWalletProviderInfo`, dispatches `fao:walletChanged`, and gives page scripts the shared signer. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::connectWallet`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::faoSelectedWalletProviderInfo`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::fao:walletChanged`

The create, proposal, and bond surfaces delegate wallet acquisition to the shared flow instead of independently reaching for `window.ethereum`. `site-testnet/create.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::window.connectWallet`, `site-testnet/sepolia.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::connectWallet`, `site-testnet/bonds.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::ensureSigner`

Wallet state now expires and advertises capabilities: `shared.js` stores a session record, clears it on explicit reset, arms a 30-minute idle timer, listens for cross-tab storage changes, detects EIP-5792 support, exposes `window.sendWalletCalls`, and renders a `5792` topbar indicator when available. `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::rememberWalletSession`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::clearWalletSessionStorage`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::armWalletIdleTimer`, `site-testnet/shared.js@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::wallet_sendCalls`, `tests-e2e/SELECTORS.md@3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d::topbar-wallet-capabilities`

## Transaction Review Cards

Create flow review happens before wallet acquisition: `create.js` builds Part1 arguments, attempts a gas estimate only if `window.activeSigner` exists, renders action/name/sale/min/phase/timeout/bond/gas rows, and exits before wallet confirmation when the user cancels. `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::part1Args`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::estimatePart1Gas`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::Create cancelled before wallet confirmation`

Proposal and resolve flow review is centralized in `sepolia.js::showConfirmCard`, with separate DOM cards for `proposal` and `resolve`. `site-testnet/proposals.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-proposal`, `site-testnet/proposals.html@5c672c5540af07df5b6ab368e8ff606fc23649b6::confirm-card-resolve`, `site-testnet/sepolia.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showConfirmCard`

Bond flow review is centralized in `bonds.js::showBondConfirm`, and it covers YES, NO, and graduate actions with proposal address, arbitration id, WETH amount or current YES bond, and gas estimate rows. `site-testnet/bonds.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::Confirm YES bond`, `site-testnet/bonds.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::Confirm NO bond`, `site-testnet/bonds.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::Confirm graduate`

Sale buy/ragequit review now computes gas estimates before the confirm button invokes wallet signing, so the review-card pattern covers both instance creation and sale exit/entry flows. `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::formatGasEstimate`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::sale.buy`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::sale.ragequit`

## Readability And A11y

Numeric scanability now has CSS support across dashboard values, rank cells, sale stats, trade amounts, review-card rows, and related data surfaces through `font-variant-numeric: tabular-nums`. `site-testnet/styles.css@8744da8b1441501b5767d5c9d1abb11d05a8d843::font-variant-numeric: tabular-nums`, `site-testnet/styles.css@8744da8b1441501b5767d5c9d1abb11d05a8d843::.rank-cell-num`, `site-testnet/styles.css@8744da8b1441501b5767d5c9d1abb11d05a8d843::.trade-amount`

Address display now keeps full addresses in links or titles while visible text uses `fmtAddr`, which reduces overflow without dropping explorer access. `site-testnet/contracts.html@8744da8b1441501b5767d5c9d1abb11d05a8d843::0x45F1…96C0`, `site-testnet/sale.js@8744da8b1441501b5767d5c9d1abb11d05a8d843::title="${addr}"`, `site-testnet/sale.js@8744da8b1441501b5767d5c9d1abb11d05a8d843::fmtAddr(addr)`

A11y affordances now cover public pages and live status surfaces: pages add `skip-nav`, `main#main`, and `no-js-notice`, while create, sale, proposal, resolve, and bond status nodes use polite live regions. `site-testnet/index.html@358b1a14f9927b2eafd7790d094a8432be60a0d9::skip-nav`, `site-testnet/sale.html@358b1a14f9927b2eafd7790d094a8432be60a0d9::aria-live="polite"`, `site-testnet/bonds.js@358b1a14f9927b2eafd7790d094a8432be60a0d9::role="status"`, `tests-e2e/SELECTORS.md@358b1a14f9927b2eafd7790d094a8432be60a0d9::no-js-notice`

`minimalism-audit.md` makes visual restraint auditable: rendered font sizes are limited to six tokens, ordinary surfaces avoid stacked elevation, gradients are disallowed in `styles.css`, and literal colors belong in `tokens.css`. `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#type-scale`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#shadow-inventory`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#gradient-inventory`, `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#literal-color-inventory`

The committed visual evidence now pairs that audit with screenshots: each public page has desktop and mobile files, and the manifest records URL, file path, SHA-256, and byte count for each capture. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::generatedAt`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::contracts-mobile.png`, `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::bytes`

The current screenshot manifest is local-rendered at `http://127.0.0.1:8772/`, records six public pages and two viewports, and includes 12 PNG hashes under `audit/screenshots/`. `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::baseUrl`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::viewports`, `audit/screenshots/manifest.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::sha256`

## T1 Worker Gap Plan

The original UI-polish worker's listed gaps now have implementation evidence: EIP-6963 provider discovery, decoded review cards, type-scale/token cleanup, single-primary trade action, tabular/address display, skip-nav plus `aria-live`, tx-status links, sale decision numerics, wallet-session hardening, and an FE-QA stack. `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::Target gaps`, `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::providerIdentityHTML`, `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`, `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::setTxStatus`, `tests-e2e/axe-helper.ts@6283126ee2e83ddc47966eaea01e40f8f52143ee::runAxeOn`

The worker constraints require keeping `site-testnet/` self-contained, avoiding new build steps, using `data-testid` selectors, and updating `tests-e2e/SELECTORS.md` whenever new test IDs are added. `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::Constraints`

The goal condition is stricter than a single patch: the latest Topic-1 JSONL line must show every dimension at least `8.0`, and that must persist for two consecutive R-rounds. `audit/agents/worker-ui-polish.md@80a3fa25e322f8af7248b04192a3649854fe9fe0::Goal condition`

## How This Might Be Wrong

- If another page reintroduces a `:root` block in `styles.css`, token ownership is no longer unified. `site-testnet/styles.css@3fad3cad278325c13a191c472f1be9ba5d15db02::do NOT re-declare`
- If hard-coded font sizes return outside token definitions, T1.D6 should be treated as regressed even if colors remain tokenized. `site-testnet/styles.css@953817cf3c19e2ab87e08af1aee8919541455dd8::font-size: var(--fs-base)`
- If `sale.html` adds another `btn-primary` outside the hidden confirm card, the primary-count claim must be rebuilt. `site-testnet/sale.html@3fad3cad278325c13a191c472f1be9ba5d15db02::id="sale-confirm-go"`
- If the ops dashboard copies diverge from `audit/dashboard/dashboard.js`, this page should cite the deployed `site-ops/fao/dashboard.js` copy too. `scripts/check-ops-sync.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::ops dashboard JSONL sync OK`
- If Chart.js time adapter wiring changes, the time-axis claim should be verified against the actual browser bundle, not only the source function. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::type: 'time'`
- If future wallet commits change provider persistence, the selected-provider and topbar-identity claims should rebuild from `shared.js`. `site-testnet/shared.js@16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea::WALLET_PROVIDER_STORAGE_KEY`
- If review cards move after wallet popup invocation, this page should stop claiming they are a pre-confirmation review surface. `site-testnet/create.js@5c672c5540af07df5b6ab368e8ff606fc23649b6::showCreateConfirm`
- If future CSS introduces hard-coded overlays or shadows again, the token-usage section should be rebuilt from `tokens.css` and `styles.css` together. `site-testnet/tokens.css@671ad3b54c68d83ba1c96974c2cf133877f1321e::--overlay`
- If sale status links or pre-confirm gas rows change, the transaction-status and review-card sections should be rebuilt from `sale.js`. `site-testnet/sale.js@6766184f046ed7205c8d7d3d3a538229667737c6::preserveStatus`, `site-testnet/sale.js@5a3953405c6017b990b4b3add843dff77c5f6f86::estimateSaleGas`
- If axe outputs gain violations, this page should stop describing the current a11y artifact set as clear. `audit/axe/home.json@5e7c0f139380b0b2296d7055b28188feae56ca4e::violations`
- If screenshots are regenerated, this page should cite the new manifest SHA/byte rows rather than the `58f0020` capture set. `audit/screenshots/manifest.json@58f0020b75ca8b8a652597ef7bcdf67b8a6648af::sha`
- If the minimalism audit changes allowed font-size, shadow, gradient, or literal-color inventories, this page should rebuild from `site-testnet/minimalism-audit.md`. `site-testnet/minimalism-audit.md@9fd41ee02a1834112f1ff580e9e262bdecd1468b::#gradient-inventory`
- If reconnect chips, review-card fixtures, or visual masks change, this page should rebuild from those read-only specs before treating screenshots as meaningful UI evidence. `tests-e2e/journeys/wallet-provider.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Reconnected with Mock 6963 Wallet`, `tests-e2e/journeys/confirm-cards.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::rows.length`, `tests-e2e/journeys/snapshots.read-only.spec.ts@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::mask`
- If the lazy ethers loader or fork-mode RPC bridge changes again, rebuild UI and supply-chain pages from the committed loader plus page scripts. `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoRpcUrl`

## See Also

- [E2E Journey Map](../40-verification/e2e-journey-map.md)
- [Deployment](../10-fao-repo/deployment.md)
- [Supply Chain](../30-cross-cutting/supply-chain.md)
- [Ops Dashboard](../50-operations/ops-dashboard.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 5a3953405c6017b990b4b3add843dff77c5f6f86
  - 37603636e5194b202ad5438ce80bf9909aad42c8
  - 80a3fa25e322f8af7248b04192a3649854fe9fe0
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - 030d258e6d7909b3e724f1a7cc5cd7f4f711178c
  - 89a6f9f710320ae59adb1ac358a8bf8e687f4bf6
  - 16aa3c4e89ca4b92f4e437046b3f3d2bb3a281ea
  - 953817cf3c19e2ab87e08af1aee8919541455dd8
  - 5c672c5540af07df5b6ab368e8ff606fc23649b6
  - 671ad3b54c68d83ba1c96974c2cf133877f1321e
  - 6b365d1f9fc57a6a6c43c4f8e2618b8155ff089d
  - 8744da8b1441501b5767d5c9d1abb11d05a8d843
  - b596f7fe09ab8b07901aca035223a85be0ffe611
  - 6b8c7252c17c84895a3b28ae771d018bdbb8d31e
  - 358b1a14f9927b2eafd7790d094a8432be60a0d9
  - 6766184f046ed7205c8d7d3d3a538229667737c6
  - 6283126ee2e83ddc47966eaea01e40f8f52143ee
  - b913bd0b7fb28c1e233d034833b8e9eafc62d16c
  - 3d4fffc1735b706ab0c2452ba9e88e33ab6d8a2d
  - 9fd41ee02a1834112f1ff580e9e262bdecd1468b
  - 5e7c0f139380b0b2296d7055b28188feae56ca4e
  - 58f0020b75ca8b8a652597ef7bcdf67b8a6648af
  - cd5e73e73b21c0ac73bf80e8cac4c9dc31edfab0
  - 806c9c5aa7b5b74e1c25c8872a339e8c56457a5c
  - ed51e829b6cc888379043d9af02cc20e4e00eafb
  - 4b4c04664009807658ca64722d3aea1fbfb401d0
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - 239313c31b169d4cc5073e6178aa372ee1e88c98
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:03:52Z.
- Build pass: 17 (continuous HEAD refresh)
