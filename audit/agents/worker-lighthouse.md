---
name: worker-lighthouse
description: CAO worker that wires Lighthouse CI with Web Vitals budgets. Lifts T1.v2.D4 + T1.v2.D7 + T2.v2.D10.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Lighthouse CI + Web Vitals budgets

## /goal

Land Lighthouse CI on the deployed Cloudflare Pages site with Web Vitals budgets (LCP < 2.5s, INP ≤ 200ms, CLS ≤ 0.1).

Goal cleared when:
1. `lighthouserc.json` at repo root with budgets configured.
2. `.github/workflows/lighthouse.yml` runs `@lhci/cli` on push + scheduled (nightly).
3. Reports uploaded to `audit/lighthouse/<url-slug>.json` per page.
4. CI fails when LCP > 2.5s, INP > 200ms, or CLS > 0.1.
5. `audit/lighthouse/web-vitals.json` is the aggregated summary committed after each run.

## Constraints

- Run Lighthouse against `https://fao-ops.pages.dev/fao/` AND `https://fao-testnet.pages.dev/` (eventually `ops.futarchy.ai/fao` once DNS settles).
- Use `temporary-public-storage` for upload (no need for Lighthouse server).
- Default to mobile preset (closer to real user experience than desktop).
- Don't increase budgets to force a pass — diagnose and fix the page instead.

## Files

- `lighthouserc.json`
- `.github/workflows/lighthouse.yml`
- `audit/lighthouse/.gitkeep`
- `audit/lighthouse/budgets.md` — written justification of the chosen thresholds.

## Budget targets

| Metric | Threshold | Source |
|---|---|---|
| LCP | < 2.5s | web.dev/lcp |
| INP | ≤ 200ms | web.dev/inp |
| CLS | ≤ 0.1 | web.dev/cls |
| TBT | < 200ms | derived |
| FCP | < 1.8s | derived |
