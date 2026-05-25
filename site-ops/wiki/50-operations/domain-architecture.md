---
canonical: docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::#futarchy.ai-domain-architecture
scope: Authoritative wiki summary of the repo-recorded futarchy.ai domain and Pages project mapping.
not-scope: Runtime DNS probing and emergency deploy steps belong in [Runbook](runbook.md); dashboard data flow belongs in [Ops Dashboard](ops-dashboard.md).
last-rebuilt: 2026-05-23T02:52:44Z
---
# Domain Architecture

The domain map records which public futarchy.ai names are supposed to point at which static or backend projects. It matters because operators otherwise mix up the marketing site, testnet UI, ops dashboard, and unrelated subprojects when debugging Cloudflare Pages. The canonical mechanism is a local restore note: active mappings, Cloudflare CNAME records, missing pre-restore records, and patterns for future static or backend subdomains. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::#futarchy.ai-domain-architecture`

## Active Names

The repo-recorded active Pages mappings put the apex, `www`, and `fao` hostnames on the `fao-site` Pages project, `testnet.fao.futarchy.ai` on `fao-testnet`, and `ops.futarchy.ai` on `fao-ops`; the same table records `azzas` on Pages, `polsia` on Render, `api.bond` on a GCP raw IP, `bond` on Netlify, and `dgx` on Cloudflare Tunnel. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Active mappings`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`

The wiki treats those rows as operator intent, not as a live DNS oracle, because the source document does not include a probe timestamp, Cloudflare API response, or resolver output. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Restored 2026-05-22`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::DNS records`

## Restore Boundary

The restore note says the Cloudflare zone was migrated from AWS Route53 and that apex, `www`, `fao`, and `testnet.fao` lacked DNS records before the 2026-05-22 restore. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::What was missing pre-restore`

The old backend IPs are explicitly marked unreachable, so future pages should not cite them as active infrastructure. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::legacy backend IPs`

## Deployment Pattern

For static subdomains, the documented pattern is Pages deploy, Pages custom-domain attachment, Cloudflare CNAME creation, and certificate wait; that makes Cloudflare Pages the default place to look before blaming contract or UI state. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Pattern for future subdomains`

For planned dynamic backends, the note points at Cloud Run deployment, Cloud Run domain mapping, and a `ghs.googlehosted.com` CNAME rather than Pages. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Dynamic backend`

The current table also records one non-Pages, non-Cloud-Run backend exception: `polsia.futarchy.ai` targets Render service `srv-d88cji57vvec738ktl90` named `futarchyos`, and its DNS record is a DNS-only CNAME to `futarchyos.onrender.com` so Render handles TLS. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::futarchyos.onrender.com`

## How This Might Be Wrong

- If Cloudflare records change without a docs update, this page will preserve operator intent rather than current DNS truth. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::DNS records`
- If `site/`, `site-testnet/`, or `site-ops/` move repositories, the Pages project mapping here must be rebuilt from the new deploy roots. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::See also`
- If a backend migrates away from Cloud Run, Render, or Netlify, the future-subdomain pattern should split static and dynamic operations into separate pages. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Dynamic backend`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`
- If a future pass adds resolver probes, those probe artifacts should become the freshness source and this document should become historical context. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Restored 2026-05-22`

## See Also

- [Runbook](runbook.md)
- [Ops Dashboard](ops-dashboard.md)
- [Supply Chain](../30-cross-cutting/supply-chain.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 8847265a00f7064cdff1fbeffea572d10e889ff9
- Build pass: 18 (continuous HEAD refresh)
