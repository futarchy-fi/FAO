# Futarchy Wiki — Outline (pre-build)

This is the **skeleton**. Each page will be filled by a CAO worker
during Phase 3, then iteratively improved by the evaluator-6 loop in
Phase 6. The outline is captured here so the structure can be reviewed
before content generation starts.

## Top-level structure

```
wiki/
├── README.md                        # entry point + navigation
├── 00-what-is-futarchy/
│   ├── README.md                    # plain-English overview
│   ├── prior-art.md                 # Hanson 2007 → Augur → Polymarket → Seer
│   └── why-onchain.md
├── 10-fao-repo/                     # futarchy-fi/FAO (this repo)
│   ├── README.md
│   ├── architecture.md              # contracts ↔ site ↔ operator
│   ├── lifecycle/
│   │   ├── 00-create-instance.md    # FutarchyRegistry.createFutarchyPart1+2
│   │   ├── 10-sale.md               # InstanceSale: buy/finalize/ragequit
│   │   ├── 20-spot-liquidity.md     # SaleSpotSeeder + fLP + redeem
│   │   ├── 30-proposal.md           # FAOFutarchyFactory.createProposal
│   │   ├── 40-promote.md            # Orchestrator + UniswapV3LiquidityAdapter
│   │   ├── 50-resolve.md            # FAOTwapResolver
│   │   └── 60-arbitration.md        # ParameterizedArbitration bonds
│   ├── contracts/                   # one MD per Solidity file: purpose, invariants, callers
│   ├── site/                        # one MD per page in site-testnet/
│   ├── operator/                    # script/agents/ daemons
│   ├── invariants.md                # consolidated, linkable to Topic-3 rubric
│   ├── deployment-history.md        # v3 → v4 → v5, what changed, what broke
│   └── glossary.md
├── 20-agents-vision/                # futarchy-fi/agents (separate repo, autonomous-agent layer)
│   ├── README.md
│   ├── what-agents-do.md            # propose, bond, trade, ragequit, resolve
│   ├── trust-boundary.md            # what's on-chain enforced vs agent-policy
│   ├── economic-model.md            # who pays whom for what work
│   └── integration-with-fao.md
├── 30-cross-cutting/
│   ├── threat-model.md
│   ├── known-issues.md              # auto-maintained from issues + commits
│   └── deprecated/                  # v3/v4 instances + why they were superseded
└── _meta/
    ├── how-this-wiki-is-maintained.md     # the CAO loop, provenance per page
    ├── source-of-truth-map.md             # page → canonical file/branch/commit
    └── changelog.jsonl                    # one row per autonomous edit
```

## Pre-construction invariants (from Topic-6 rubric draft)

Every page must satisfy:

1. **Source-of-truth back-link** at top: `Canonical: <repo/path/file@sha>`.
2. **Scope statement** at top: "This page is the authoritative description of `X`. It is NOT the place to explain `Y`."
3. **Out-of-scope abstention** in body: if the page can't answer a Q, say so and link to where it could.
4. **No orphan claims**: every load-bearing statement cites a file:line, commit, or URL.
5. **A "How this might be wrong" section** at the bottom — listing the ways the page is most likely to be stale.

## What the wiki must NOT be

- A README paraphrase.
- A summary that omits the failure modes / rejected alternatives / history.
- A monolith — pages > ~400 lines must be split.
- A snapshot — every page tracks its source canonical revision; on re-build, pages whose source changed must regenerate.

## Build order (Phase 3)

1. `_meta/` first (defines maintenance discipline).
2. `00-what-is-futarchy/` (entry-point context).
3. `10-fao-repo/architecture.md` + `lifecycle/` (load-bearing).
4. `10-fao-repo/contracts/` and `site/` (per-file).
5. `20-agents-vision/` (needs futarchy-fi/agents repo read — get user to clone or skip).
6. `30-cross-cutting/`.

## Open questions for user (resolve before Phase 3)

1. Should the wiki live in this repo (`audit/wiki/` after rename) or in its own repo?
2. Is `futarchy-fi/agents` available to clone locally, or should we work from public-facing docs / vision statements only?
3. Should the wiki be deployed somewhere (its own Cloudflare Pages site)?
