# futarchy.ai domain architecture

Restored 2026-05-22 after the AWS Route53 → Cloudflare migration.

## Active mappings

| Domain | Pages project | Source | Hosted at |
|---|---|---|---|
| `futarchy.ai` (apex) | `fao-site` | `site/` in this repo | Cloudflare Pages |
| `www.futarchy.ai` | `fao-site` | `site/` | Cloudflare Pages |
| `fao.futarchy.ai` | `fao-site` | `site/` | Cloudflare Pages |
| `testnet.fao.futarchy.ai` | `fao-testnet` | (separate deploy — see project) | Cloudflare Pages |
| `ops.futarchy.ai` | `fao-ops` | `site-ops/` (incl. `/fao/` audit dashboard) | Cloudflare Pages |
| `azzas.futarchy.ai` | `azzas-portal` | (separate project) | Cloudflare Pages |
| `polsia.futarchy.ai` | — | (Render service `srv-d88cji57vvec738ktl90` — "futarchyos") | Render |
| `api.bond.futarchy.ai` | — | — | GCP raw IP `34.88.170.88` |
| `bond.futarchy.ai` | — | — | Netlify (`zippy-halva-280c00.netlify.app`) |
| `dgx.futarchy.ai` | — | — | Cloudflare Tunnel |

## DNS records (Cloudflare zone `futarchy.ai`)

All `proxied=true` (Cloudflare CDN in front):

```
futarchy.ai               CNAME → fao-site.pages.dev          (apex CNAME-flattening)
www.futarchy.ai           CNAME → futarchy.ai
fao.futarchy.ai           CNAME → fao-site.pages.dev
testnet.fao.futarchy.ai   CNAME → fao-testnet.pages.dev
ops.futarchy.ai           CNAME → fao-ops.pages.dev
polsia.futarchy.ai        CNAME → futarchyos.onrender.com      (DNS-only — Render handles TLS)
```

## What was missing pre-restore

Before today, these subdomains had **no DNS records**:
- `futarchy.ai` apex
- `www.futarchy.ai`
- `fao.futarchy.ai`
- `testnet.fao.futarchy.ai`

The Cloudflare zone existed but had been migrated from AWS Route53 (zone ID `Z06245071W0416XAM4JIS`) without the original A records being restored. The legacy backend IPs (`56.125.238.240`, `56.125.38.221`) are no longer reachable.

## Pattern for future subdomains

Static site → Cloudflare Pages:
1. Create Pages project (`wrangler pages deploy <dir> --project-name=<name>`)
2. Attach custom domain via API: `POST /accounts/{acct}/pages/projects/{name}/domains` with `{"name":"<sub>.futarchy.ai"}`
3. Add CNAME in zone: `POST /zones/{zone}/dns_records` with `{"type":"CNAME","name":"<sub>","content":"<name>.pages.dev","proxied":true}`
4. Wait ~1–2 min for cert; if `status=pending` persists, delete+re-add the domain attachment

Dynamic backend → GCP Cloud Run (planned):
1. `gcloud run deploy <name> --region us-central1`
2. Pages-Mapping: Cloud Run domain mapping for `<sub>.futarchy.ai`
3. DNS: `CNAME → ghs.googlehosted.com`

## See also

- `audit/state/RUNBOOK.md` — operator runbook for FAO
- `site/`, `site-testnet/`, `site-ops/` — the three Pages roots
- `audit/state/DEPRECATIONS.md` — what's retired and why
