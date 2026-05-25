---
canonical: site-ops/fao/summary.json@HEAD::generatedAt
scope: Authoritative wiki summary of the static ops portal, dashboard data flow, deploy workflow, sync gate, and time-axis dashboard change.
not-scope: Testnet site UI hierarchy lives in [UI Architecture](../30-themes/ui-architecture.md); operator incident response lives in [Runbook](runbook.md).
last-rebuilt: 2026-05-23T02:52:44Z
---
# Ops Dashboard

The ops dashboard is a static Cloudflare Pages surface for viewing audit evaluation data over time. It matters because rubric convergence is now inspectable through a deployed operations portal instead of only local JSONL files, and partial worker/multimodal rows no longer pollute canonical trends. The canonical mechanism is copying `audit/evaluations/topic-{1..6}-evals.jsonl` plus dashboard assets into `site-ops/fao/`, generating `summary.json` for first paint, filtering canonical full-evaluator rows in `dashboard.js`, and deploying `site-ops/` to the `fao-ops` Pages project. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#data-flow`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::summary.json`, `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::MIN_CANONICAL_DIMS`, `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cloudflare-pages`

## Changed Since R4 Wiki

At `89a6f9f710320ae59adb1ac358a8bf8e687f4bf6`, the wiki had no operations section, no `site-ops/` coverage, and no dashboard time-axis note. `audit/wiki/README.md@89a6f9f710320ae59adb1ac358a8bf8e687f4bf6::#page-index`

The ops portal refresh added the portal scaffold, a deploy workflow, sync/check scripts, dashboard JSONL copies, and Chart.js time-axis rendering. `site-ops/index.html@3fad3cad278325c13a191c472f1be9ba5d15db02::ops.futarchy.ai`, `.github/workflows/deploy-ops.yml@3fad3cad278325c13a191c472f1be9ba5d15db02::Deploy ops portal to Cloudflare Pages`, `scripts/sync-ops-dashboard.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::synced audit/evaluations`, `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderMinChart`

Since source HEAD `58f0020b75ca8b8a652597ef7bcdf67b8a6648af`, the dashboard contract changed in three ways: source HTML keeps Chart.js and its date adapter as deferred CDN scripts, `dashboard.js` filters out worker and multimodal partial rows before trends, and sync now copies dashboard HTML/JS/CSS plus `summary.json` into the deploy tree. `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::DO NOT REMOVE THESE CDN TAGS`, `audit/dashboard/dashboard.js@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::NON_CANONICAL_EVALUATORS`, `scripts/sync-ops-dashboard.sh@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::Dashboard assets`, `site-ops/fao/summary.json@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::latestRound`

Since source HEAD `b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b`, dashboard freshness moved again: the sync script still copies source assets and now the worktree `summary.json` reflects Topic 1/3 evaluator rows through round 42, while the current dashboard source keeps summary-first rendering plus lazy full JSONL loading. `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::summary.json`, `site-ops/fao/summary.json@HEAD::latestRound`, `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::loadSummary`, `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::fullLoadRequested`

The current worktree summary records `generatedAt=2026-05-22T19:36:58Z`, `totalDimensions=41`, `atTarget=14`, and `latestRound=42`, so the dashboard first paint has fresher aggregate state than the last committed wiki refresh. `site-ops/fao/summary.json@HEAD::generatedAt`, `site-ops/fao/summary.json@HEAD::totalDimensions`, `site-ops/fao/summary.json@HEAD::atTarget`, `site-ops/fao/summary.json@HEAD::latestRound`

## Static Portal Contract

The Pages project is named `fao-ops`, the build command is none, the output directory is `site-ops`, and the custom domain is `ops.futarchy.ai`. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cloudflare-pages`

The current domain note records `ops.futarchy.ai` as a Cloudflare Pages CNAME to `fao-ops.pages.dev`; it also records `polsia.futarchy.ai` as a Render-backed exception outside the ops portal. This page treats those rows as repository-recorded routing intent, not as a live DNS probe. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::ops.futarchy.ai`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::DNS records`

The portal homepage links to the FAO audit dashboard, the testnet site, and the GitHub repo, and embeds the dashboard iframe with a 30-second refresh. `site-ops/index.html@3fad3cad278325c13a191c472f1be9ba5d15db02::Available views`, `site-ops/index.html@3fad3cad278325c13a191c472f1be9ba5d15db02::portalRefresh`

## Data Flow And CI

`scripts/sync-ops-dashboard.sh` copies topic 1 through 6 JSONL files from `audit/evaluations/` into `site-ops/fao/evaluations/`, copies dashboard HTML/JS/CSS from `audit/dashboard/`, and writes `site-ops/fao/summary.json`. `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::topic in 1 2 3 4 5 6`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::dashboard assets`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::summary`

`scripts/check-ops-sync.sh` diffs each source/destination pair and prints `ops dashboard JSONL sync OK` when the copy is current. `scripts/check-ops-sync.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::ops dashboard JSONL sync OK`

The static-analysis workflow runs the ops dashboard sync check alongside deployment sync, Etherscan verification, and Slither; the deploy workflow runs the sync script before `wrangler pages deploy site-ops --project-name=fao-ops --branch=main`. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ops-dashboard-sync`, `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::etherscan-verified`, `.github/workflows/deploy-ops.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::pages deploy site-ops`

The auto-sync daemon hashes evaluation JSONL plus dashboard HTML/JS/CSS before syncing and redeploying, so a dashboard code change can trigger the same Pages refresh path as an evaluator-row change. `scripts/auto-sync-ops.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::cat audit/evaluations`, `scripts/auto-sync-ops.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::syncing + redeploying`

## Time-Axis Change

The dashboard loader reads `../evaluations/topic-${id}-evals.jsonl`, so the same code works when served from `site-ops/fao/`. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::loadTopic`, `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#data-flow`

`renderMinChart` and `renderPerTopicCharts` now build datasets with `x: new Date(r.timestamp)` and configure `x.type = 'time'`, while heatmap headers use formatted timestamps. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderMinChart`, `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderPerTopicCharts`, `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderHeatmap`

The current first-paint path can render from `summary.json`, then lazy-load full JSONL only when chart/detail sections are requested. `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::loadSummary`, `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::summaryToTopicRounds`, `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::fullLoadRequested`

## How This Might Be Wrong

- If `site-ops/fao/dashboard.js` diverges from `audit/dashboard/dashboard.js`, this page should cite both copies and the sync rule that keeps data, not code, aligned. `site-ops/fao/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::renderMinChart`
- If Cloudflare project name or custom domain changes, this page must rebuild from `site-ops/README.md` and `deploy-ops.yml`. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::fao-ops`
- If the dashboard fetches live audit data instead of copied JSONL, the data-flow section should stop describing a static copy. `scripts/sync-ops-dashboard.sh@3fad3cad278325c13a191c472f1be9ba5d15db02::cp "$src" "$dest"`
- If the chart library changes, the time-axis claim must be rebuilt from the new renderer. `audit/dashboard/dashboard.js@3fad3cad278325c13a191c472f1be9ba5d15db02::type: 'time'`
- If static analysis splits ops-dashboard sync into another workflow, this page should stop citing `static-analysis.yml` for dashboard freshness. `.github/workflows/static-analysis.yml@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::ops-dashboard-sync`
- If worker or multimodal rows should become first-class trend rows, `isCanonicalRow` and `summary.json` generation must change together. `audit/dashboard/dashboard.js@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::isCanonicalRow`, `scripts/sync-ops-dashboard.sh@5e532972f18bafdcd8f6d2c48bf314db0da24a6c::is_canonical`
- If CDN scripts are removed from HTML again, the page must cite the new loading mechanism because current comments say lazy-loading races on slow networks. `audit/dashboard/index.html@b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b::lazy-load races`
- If the current `summary.json` overlay is committed, replace the `@HEAD` summary citations with the resulting commit SHA and rerun the dashboard sync check. `site-ops/fao/summary.json@HEAD::generatedAt`

## See Also

- [Runbook](runbook.md)
- [Developer Cycle](developer-cycle.md)
- [Domain Architecture](domain-architecture.md)
- [UI Architecture](../30-themes/ui-architecture.md)
- [Supply Chain](../30-cross-cutting/supply-chain.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd
  - 3fad3cad278325c13a191c472f1be9ba5d15db02
  - 030d258e6d7909b3e724f1a7cc5cd7f4f711178c
  - 89a6f9f710320ae59adb1ac358a8bf8e687f4bf6
  - 41e4b529c818dbd56fb35b66a4db45b7081fe0a4
  - fe9abbe3331b70b1600f4a4d28ee39a6bd539fed
  - 1b0c0d7d457cc8468639d288eb14cba0042c801d
  - c8fc913a21c605a9e75069c2852f9da32b72c3e1
  - b6a8586f0a8b1dad8e5625dc1c90b9f97ef46b4b
  - 5e532972f18bafdcd8f6d2c48bf314db0da24a6c
  - 8847265a00f7064cdff1fbeffea572d10e889ff9
- Uncommitted source overlays read: yes, current worktree at 2026-05-22T20:15:22Z.
- Build pass: 18 (continuous HEAD refresh)
