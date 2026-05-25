---
canonical: audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Dimension 5
scope: Authoritative list of known wiki abstentions, missing freshness oracles, and follow-up questions.
not-scope: Page-to-source rebuild ownership lives in [Source Of Truth Map](source-of-truth-map.md); operator procedures live in [Runbook](../50-operations/runbook.md).
last-rebuilt: 2026-05-23T03:04:18Z
---
# Open Questions

This page is the wiki's refusal ledger. It matters because Topic-6 rewards source-cited abstention over confident guesses about external repos, live chain state, DNS, or dirty worktree overlays. The canonical mechanism is a short list of unresolved evidence gaps, each pointing at the page that currently carries the safest sourced statement. `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Dimension 5`

## Current Questions

| ID | Question | Current abstention |
|---|---|---|
| `OQ-AGENTS-001` | Is the separate `futarchy-fi/agents` repo available to document? | No local agents repo or local public-doc snapshot exists in this checkout, so [Agents Vision](../20-agents-vision/README.md) stays a stub. `audit/wiki/_OUTLINE.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::20-agents-vision`, `audit/wiki/20-agents-vision/README.md@HEAD::Out-of-scope abstention` |
| `OQ-DEPLOY-001` | What block proves the active `deployments.json` values are fresh? | The manifest records `generated_at`, `network`, `chain_id`, and active addresses, but it does not record `as_of_block`; deployment pages therefore cite schema/coupling checks and do not claim live-current chain state. `deployments.json@f96ced010f19032837e96094c935572a2320230f::generated_at`, `deployments.json@f96ced010f19032837e96094c935572a2320230f::chain_id`, `audit/wiki/10-fao-repo/deployment.md@HEAD::Manifest Contract` |
| `OQ-DNS-001` | Are the futarchy.ai DNS records live right now? | [Domain Architecture](../50-operations/domain-architecture.md) treats `docs/futarchy-ai-domains.md` as repository-recorded operator intent, including the `polsia.futarchy.ai` Render CNAME, not a resolver probe. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::DNS records`, `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::polsia.futarchy.ai`, `audit/wiki/50-operations/domain-architecture.md@HEAD::Active Names` |
| `OQ-WORKTREE-001` | Which `@HEAD` citations still depend on dirty source overlays? | F1 Synpress/MetaMask routing, fork CI local-site startup/logging, dirty HTML/deployment overlays, and dashboard `summary.json` are intentionally cited as `@HEAD` until those source files are committed; lazy ethers loading and the shared fork RPC bridge are now committed at `3760363`. `tests-e2e/journeys/F1-create-instance.wallet.spec.ts@HEAD::connectWithSynpress`, `.github/workflows/e2e.yml@HEAD::Start testnet static site`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::loadEthers`, `site-testnet/shared.js@37603636e5194b202ad5438ce80bf9909aad42c8::window.faoRpcUrl`, `site-ops/fao/summary.json@HEAD::generatedAt` |
| `OQ-LIVE-001` | Does public Cloudflare availability remain true after the refresh? | The wiki cites repo deploy configuration and refresh-time URL observations, but no continuous uptime probe artifact is committed. `site-ops/README.md@3fad3cad278325c13a191c472f1be9ba5d15db02::#cloudflare-pages`, `audit/wiki/30-cross-cutting/ops.md@HEAD::Live Ops Portal` |

## How This Might Be Wrong

- If a future pass commits a manifest `as_of_block` or block-hash field, `OQ-DEPLOY-001` should move from open question to [Deployment](../10-fao-repo/deployment.md) evidence. `deployments.schema.json@fb9a1a50fdf379b0190874ccefe69ef80ef1c3cd::required`
- If DNS probe artifacts are committed, `OQ-DNS-001` should point at those artifacts instead of the operator note. `docs/futarchy-ai-domains.md@8847265a00f7064cdff1fbeffea572d10e889ff9::Restored 2026-05-22`
- If dirty worktree overlays are committed, `OQ-WORKTREE-001` should be emptied and the affected `@HEAD` citations should be replaced with commit SHAs. `audit/wiki/_meta/how-this-wiki-is-maintained.md@HEAD::@HEAD`
- If `futarchy-fi/agents` is cloned locally, `OQ-AGENTS-001` should close and [Agents Vision](../20-agents-vision/README.md) should become a full page. `audit/wiki/_OUTLINE.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Open questions for user`

## See Also

- [Source Of Truth Map](source-of-truth-map.md)
- [Agents Vision](../20-agents-vision/README.md)
- [Deployment](../10-fao-repo/deployment.md)
- [Domain Architecture](../50-operations/domain-architecture.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 37603636e5194b202ad5438ce80bf9909aad42c8
  - b5b872e39f56f3be19f0a347dba4943b99ff49df
  - f96ced010f19032837e96094c935572a2320230f
  - 8847265a00f7064cdff1fbeffea572d10e889ff9
- Build pass: 18 (continuous HEAD refresh)
