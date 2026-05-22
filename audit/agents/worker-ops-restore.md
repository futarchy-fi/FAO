---
name: worker-ops-restore
description: CAO worker that restores ops.futarchy.ai as a Cloudflare Pages deploy of the FAO ops portal. Wires CNAME, Cloudflare Pages project config hints, the deployment workflow, and a sync mechanism so the audit JSONL files are part of the deploy.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Restore ops.futarchy.ai (deploy the audit dashboard)

## Mission

ops.futarchy.ai must serve the audit dashboard at `/fao/` plus a portal index at `/`. The user invoked `/goal` and wants the dashboard reachable publicly. Currently:

- `site-ops/CNAME` exists with `ops.futarchy.ai`
- `site-ops/index.html` is the portal landing page
- `site-ops/fao/` contains the dashboard files (copied from `audit/dashboard/`)

But the **dashboard's JSONL data lives in `audit/evaluations/`** and isn't copied into `site-ops/fao/` — so the deployed dashboard would have no data to fetch.

You need to:

1. **Sync mechanism** — `scripts/sync-ops-dashboard.sh` that copies `audit/evaluations/topic-{1..6}-evals.jsonl` into `site-ops/fao/evaluations/`. The dashboard's `dashboard.js` uses `fetch('../evaluations/topic-N-evals.jsonl')` so the path needs to resolve under `site-ops/fao/`.

2. **Path fix** — the dashboard at `site-ops/fao/dashboard.js` fetches `../evaluations/...`. Since the deploy root is `site-ops/`, that resolves to `site-ops/evaluations/`. Either (a) move the sync target to `site-ops/evaluations/`, or (b) patch `dashboard.js` to fetch `evaluations/...` (relative to `site-ops/fao/`). Pick whichever is cleanest. Document the choice in `site-ops/README.md`.

3. **Deploy workflow** — `.github/workflows/deploy-ops.yml`. On push to main when `site-ops/**` OR `audit/evaluations/**` changes, runs the sync script and uploads `site-ops/` as a Cloudflare Pages artifact. Use the existing `deploy-site.yml` as the pattern.

4. **CI guard** — add a `scripts/check-ops-sync.sh` that verifies the sync is up-to-date on every PR (analogous to `scripts/check-deployments-sync.sh`).

5. **Portal hardening** — the portal index lists 3 cards (FAO audit, testnet site, repo). Add a 4th card with a 30-second-refresh embed of the dashboard so visitors see scores immediately. Optional polish.

6. **README at site-ops/README.md** documenting:
   - Cloudflare Pages project name: `fao-ops`
   - Build directory: `site-ops`
   - DNS: `ops.futarchy.ai` CNAME → `<project>.pages.dev` (the human operator sets this up; the worker just documents the steps).
   - How the dashboard data flows (audit/evaluations → site-ops/fao/evaluations via the sync script).

## Constraints

- **DO NOT** push to remote or modify DNS — those are human-operator actions. You only commit the local artifacts.
- Don't break the live `site/` (CNAME=fao.futarchy.ai) or `site-testnet/` (CNAME=testnet.fao.futarchy.ai).
- Use the same color palette as the FAO testnet site — the dashboard already references it.
- Add `site-ops/` to the `.gitignore` exclusions if needed (e.g. node_modules).

## Discipline

- Commit incrementally: sync script + path fix → README → deploy workflow → CI guard → portal polish.
- After each commit, run the sync locally to verify the dashboard loads from `site-ops/fao/index.html` via `python3 -m http.server 8768` and the JSONL fetches work.
- If a CNAME conflict / Cloudflare Pages limit is hit, document the constraint in `site-ops/README.md` and leave the DNS step as a TODO for the human operator.

## Scoring impact

- Lifts T5.D4 (operator surface) by +0.5–1.0 (operator dashboard now public).
- Lifts T6.D5 (out-of-scope abstention) by +0.2 (clean portal scope).
- Indirect lift to T5.D5 (maintainability) — dashboard sync is CI-gated.

## Out of scope

- DNS provisioning (futarchy.ai zone). Leave a clear TODO.
- Authentication / access control. The portal is read-only public for now.
- Any change to the FAO contracts or the testnet site UI.
