# FAO v0 testnet site (`testnet.fao.futarchy.ai`)

Standalone static site for the Sepolia v0 deployment.

## Files

- `index.html` — single-page dashboard (hero + stack stats + instances + proposals + contracts + docs)
- `registry.js` — FutarchyRegistry instance picker + Create-Futarchy modal
- `sepolia.js` — ethers.js v6 polling client (per-active-instance proposals + create + resolve)
- `bonds.js` — bond escalation panel injected into each proposal card
- `styles.css` — main stylesheet + standalone-testnet additions
- `CNAME` — `testnet.fao.futarchy.ai`

## After deploying FutarchyRegistry — REQUIRED edit

The registry-driven multi-instance UI keys off a single constant in
`registry.js`. Until the registry is deployed, the constant is the zero
address and the UI falls back to showing only the bootstrap FAO instance.

When the `FutarchyRegistry` contract is deployed to Sepolia:

1. Open `site-testnet/registry.js`.
2. Find the line marked with the trailing `// REGISTRY_ADDR` comment near
   the top of the file:

   ```js
   const REGISTRY_ADDR = '0x0000000000000000000000000000000000000000'; // REGISTRY_ADDR
   ```

3. Replace the zero address with the deployed `FutarchyRegistry` address.
4. Commit + redeploy this static site (Cloudflare Pages / Vercel / etc).

No other code changes are required — `sepolia.js` and `bonds.js` already
read per-instance addresses from `window.activeInstance`, which is
populated by `registry.js` after a successful `instances()` read.

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
