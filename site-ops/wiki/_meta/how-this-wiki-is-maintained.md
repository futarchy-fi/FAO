---
canonical: audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::#rubric--topic-6-llm-maintained-wiki-self-improvement
scope: Authoritative for rebuild discipline, citation rules, abstention, and provenance.
not-scope: Per-page canonical ownership lives in [Source Of Truth Map](source-of-truth-map.md).
last-rebuilt: 2026-05-22T20:25:07Z
---
# How This Wiki Is Maintained

This page describes the operating contract for future wiki rebuilds. It matters because a wiki that merely mirrors current code without staleness controls becomes harder to trust after the next deploy. The canonical mechanism is a page-level loop: read primary sources, cite every load-bearing claim, cross-link the result, append a changelog row, and state how the page could become wrong. `audit/rubrics/topic-6-llm-wiki.md:17-27`, `audit/wiki/_OUTLINE.md:48-57`

## Rebuild Inputs

A rebuild starts from the outline and the Topic-6 rubric. The outline fixes the tree and build order; the rubric scores source traceability, cross-link graph health, convergence, abstraction quality, abstention, and freshness. `audit/wiki/_OUTLINE.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::#top-level-structure`, `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Dimension 1`

The primary source set for this pass is local repository material under `src/`, `site-testnet/`, `script/`, and `docs/`. The mission statement for this build requires each listed page to read relevant source files, draft with citations, save the page, and append one changelog JSON line. `audit/wiki/_OUTLINE.md:20-35`, `audit/wiki/_OUTLINE.md:48-57`

## Page Contract

Each full markdown page starts with top matter naming a canonical source, a scope sentence, a not-scope sentence, and an ISO rebuild timestamp. The outline requires source-of-truth backlinks, scope statements, out-of-scope abstention, no orphan claims, and a "How this might be wrong" section. `audit/wiki/_OUTLINE.md:48-57`

Every concrete implementation claim should cite a primary file with commit SHA plus symbol, a commit/PR URL, or a docs memo immediately near the claim. The rubric grades citation existence, citation resolution, and whether the cited region actually supports the claim; line ranges alone are not enough if they point at the wrong symbol. `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Dimension 1`, `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::cite_support_rate`

Each full page ends with provenance naming the builder, the source commit read, and the build pass. A page may cite `@HEAD` only for dirty worktree sources that do not yet have a stable commit; once committed, the page should replace that overlay citation with the resulting SHA. `audit/wiki/_OUTLINE.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::Pre-construction invariants`, `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::freshness_lag`

## Changelog Rows

`audit/wiki/_meta/changelog.jsonl` is append-only for autonomous edits. Each row records the page path, action, timestamp, line count, and citation count so evaluators can detect whether future passes are real updates or paraphrase churn. `audit/rubrics/topic-6-llm-wiki.md:58-82`, `audit/rubrics/topic-6-llm-wiki.md:84-110`

Line counts should be computed from the file as written, not guessed from the draft. Citation counts should count local line-range citations and external URLs because Topic-6 checks both existence and graph quality. `audit/rubrics/topic-6-llm-wiki.md:36-56`, `audit/rubrics/topic-6-llm-wiki.md:58-82`

## Abstention Rule

The wiki should refuse to invent facts about repos, deployments, agents, or live values that are not available in local sources. The rubric explicitly penalizes agents-repo confabulation and live-state confabulation, so dynamic state is either cited as historical evidence or left as a TODO. `audit/rubrics/topic-6-llm-wiki.md:134-159`

For this pass, [Agents Vision](../20-agents-vision/README.md) is a stub because no local `futarchy-fi/agents` repository or public docs are present inside the FAO checkout. The outline says the agents section needs the separate repo and should be skipped or requested if unavailable. `audit/wiki/_OUTLINE.md:31-35`, `audit/wiki/_OUTLINE.md:43-45`

## Freshness Triggers

Regenerate affected pages when a cited source file changes, when a page's canonical source moves, when live deployment docs add a new manifest, or when a future pass adds canonical pages that are better link targets. The rubric's freshness lag and URL stability dimensions expect pages to track source changes without churn or link breakage. `audit/rubrics/topic-6-llm-wiki.md:161-185`

## How This Might Be Wrong

- If future evaluators require machine-parseable YAML front matter, markdown links inside top matter may need quoting or relocation. `audit/wiki/_OUTLINE.md:48-57`
- If changelog semantics change from append-only to rebuild snapshots, `_meta/changelog.jsonl` needs a schema migration. `audit/wiki/_OUTLINE.md:31-35`
- If external agents documentation is later cloned locally, the abstention in this pass becomes stale and should be replaced by source-cited content. `audit/wiki/_OUTLINE.md:43-45`
- If Topic-6 weights change, this page's maintenance contract should be re-read against the new rubric rather than copied forward. `audit/rubrics/topic-6-llm-wiki.md@b5b872e39f56f3be19f0a347dba4943b99ff49df::How to use this rubric`

## See Also

- [Source Of Truth Map](source-of-truth-map.md)
- [Open Questions](open-questions.md)
- [Futarchy Wiki](../README.md)
- [Agents Vision](../20-agents-vision/README.md)

## Provenance
- Built by: cao-wiki-builder (codex)
- Source commits read:
  - 15279877e01f6dea50b96bf056302060e3ab6214
  - b5b872e39f56f3be19f0a347dba4943b99ff49df
- Build pass: 18 (continuous HEAD refresh)
