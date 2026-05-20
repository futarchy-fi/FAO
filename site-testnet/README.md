# FAO v0 testnet site (`testnet.fao.futarchy.ai`)

Standalone static site for the Sepolia v0 deployment.

## Files

- `index.html` — single-page dashboard (hero + stack stats + proposals + contracts + docs)
- `sepolia.js` — ethers.js v6 polling client (mirrors `site/sepolia.js`)
- `styles.css` — main stylesheet + standalone-testnet additions
- `CNAME` — `testnet.fao.futarchy.ai`

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
