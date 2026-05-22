# FAO v0 testnet site (`testnet.fao.futarchy.ai`)

Standalone static site for the Sepolia v0 deployment.

## Files

- `index.html` / `sale.html` / `proposals.html` / `create.html` /
  `contracts.html` / `docs.html` — page templates. Each page declares its
  identity via `<body data-page="…">`.
- `shared.js` — topbar, wallet, active-instance state. Fetches
  `deployments.json` at startup. Source of truth: this file binds the
  per-page scripts via custom events (`fao:walletChanged`,
  `fao:activeInstanceChanged`).
- `sale.js` / `home.js` / `bonds.js` / `sepolia.js` — per-page scripts.
- `tokens.css` — design tokens (colors, spacing, type-scale, motion).
- `styles.css` — component CSS. Consumes `tokens.css`; does NOT
  re-declare `:root`.
- `deployments.json` — **copy** of `../deployments.json`. CI
  (`scripts/check-deployments-sync.sh`) rejects drift.
- `CNAME` — `testnet.fao.futarchy.ai`.

## After deploying a new `FutarchyRegistry`

The active registry address is read at runtime from `deployments.json` —
the single source of truth, also consumed by audit/CI. Update **the
JSON, not a hardcoded constant**:

1. Edit `deployments.json` at repo root — set `active.registry` to the
   new address.
2. `cp deployments.json site-testnet/deployments.json` (keeps the
   page-served copy in sync). CI guard:
   `bash scripts/check-deployments-sync.sh`.
3. Commit both files. Cloudflare Pages redeploys; `shared.js` fetches
   the JSON on every page load and binds `REGISTRY_ADDR` from it.

`shared.js` retains a `FALLBACK_REGISTRY_ADDR` constant so the UI keeps
booting if the fetch is blocked (dev `file://` mode, network failure).
Keep it in sync — the sync script verifies both copies match the same
authoritative JSON.

No other code changes are required — `sale.js`, `proposals.js`, and
`bonds.js` read per-instance addresses from `window.activeInstance`,
populated by `shared.js` after a successful `instances()` read.

## Run locally

```
cd site-testnet && python3 -m http.server 8766
```

Open <http://127.0.0.1:8766/>.

## Deploy options

GitHub Pages allows only one Pages site per repo (already used by
`site/` → `fao.futarchy.ai`). For the testnet subdomain choose one:

### Option A: Cloudflare Pages (recommended, no extra repo)

1. Cloudflare dashboard → Pages → Create project → Connect to
   `futarchy-fi/FAO`.
2. Build output directory: `site-testnet`.
3. No build command (static).
4. Add custom domain: `testnet.fao.futarchy.ai`.
5. DNS: in the futarchy.ai zone, create CNAME `testnet` →
   `<project>.pages.dev` (Cloudflare auto-provisions a TLS cert).

Pushes to `main` trigger redeploy automatically.

### Option B: Vercel / Netlify

Same flow, point the project at `site-testnet/`. Set the custom
domain to `testnet.fao.futarchy.ai`. DNS CNAME to the host's
provided target.

### Option C: Separate GitHub Pages repo

1. Create `futarchy-fi/FAO-testnet` (or any name).
2. Copy `site-testnet/` contents to repo root.
3. Enable Pages with custom domain `testnet.fao.futarchy.ai`.
4. DNS CNAME `testnet` → `futarchy-fi.github.io`.
5. Sync via a GitHub Action that mirrors `site-testnet/` on `main`.

### Option D: Reverse-proxy from main site

In `fao.futarchy.ai`'s host, add a route rewriting `/testnet/*` →
`site-testnet/*`. Then CNAME `testnet.fao.futarchy.ai` →
`fao.futarchy.ai` and use Cloudflare Worker / Pages routing to map
the subdomain to the `/testnet/` path. Most complex.

## Recommended: Option A.

It keeps the testnet site in the same repo (clean code-review story),
auto-deploys on every push to `main`, and the DNS is a single CNAME.
