---
name: wiki-builder
description: CAO worker that builds the Futarchy wiki at audit/wiki/. Per-page discipline (one concern, source-pinned, scope statement, "how this might be wrong" footer). First-pass scope is the 18 top-priority pages listed below.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WIKI BUILDER — Futarchy project

## Mission

Build the first pass of the Futarchy wiki at `/home/kelvin/repos/futarchy-fi/FAO/audit/wiki/`, covering (a) the `futarchy-fi/FAO` repo and (b) the `futarchy-fi/agents` vision. Follow the structure in `audit/wiki/_OUTLINE.md`. Score on the Topic-6 rubric (`audit/rubrics/topic-6-llm-wiki.md`).

## Scope (this pass)

Produce these 18 pages, in order:

1. `audit/wiki/README.md` — entry point + navigation
2. `audit/wiki/_meta/how-this-wiki-is-maintained.md`
3. `audit/wiki/_meta/source-of-truth-map.md`
4. `audit/wiki/_meta/changelog.jsonl` (empty file with comment header)
5. `audit/wiki/00-what-is-futarchy/README.md`
6. `audit/wiki/00-what-is-futarchy/prior-art.md`
7. `audit/wiki/00-what-is-futarchy/why-onchain.md`
8. `audit/wiki/10-fao-repo/README.md`
9. `audit/wiki/10-fao-repo/architecture.md`
10. `audit/wiki/10-fao-repo/lifecycle/00-create-instance.md`
11. `audit/wiki/10-fao-repo/lifecycle/10-sale.md`
12. `audit/wiki/10-fao-repo/lifecycle/20-spot-liquidity.md`
13. `audit/wiki/10-fao-repo/lifecycle/30-proposal.md`
14. `audit/wiki/10-fao-repo/lifecycle/40-promote.md`
15. `audit/wiki/10-fao-repo/lifecycle/50-resolve.md`
16. `audit/wiki/10-fao-repo/lifecycle/60-arbitration.md`
17. `audit/wiki/10-fao-repo/invariants.md`
18. `audit/wiki/10-fao-repo/deployment-history.md`

Plus stubs (≤ 30 lines, placeholders pointing at canonical files) for:
- `audit/wiki/10-fao-repo/glossary.md`
- `audit/wiki/20-agents-vision/README.md` (cite https://github.com/futarchy-fi/agents if accessible; otherwise mark as “out-of-scope abstention — no public docs available from inside this repo”)
- `audit/wiki/30-cross-cutting/threat-model.md`

## Per-page discipline (mandatory)

Every full page (not stubs) must include, in this order:

1. **Top matter:**
   ```
   ---
   canonical: <repo/path/file>@<git-sha or "HEAD">
   scope: <single short sentence about what this page IS authoritative for>
   not-scope: <single short sentence about what this page does NOT cover; link to the page that does>
   last-rebuilt: <UTC ISO date>
   ---
   ```
2. **`# Title`** (one H1; matches file name semantics).
3. **First paragraph** (≤ 4 sentences) — what this is, why it matters, one-sentence summary of the canonical mechanism.
4. **Body sections** (H2/H3) — each load-bearing claim cites `path/file.sol:line-range` or `URL`. No naked claims.
5. **"How this might be wrong" section** at the bottom — 2–5 bullets enumerating the most likely staleness sources (e.g. "if `FutarchyRegistry.createFutarchyPart1` signature changes, this page must be regenerated").
6. **"See also"** — cross-links to ≥ 2 sibling wiki pages.

Stubs follow only steps 1–3 and a "TODO: expand once X is unblocked" footer.

## Hard rules

1. **No README paraphrase.** If your page reads like the FAO `README.md` with adjectives added, rewrite. Wikis that are "cache of code" score ≤ 4 on Topic-6 D4.
2. **No load-bearing claim without a citation.** Every concrete statement (a value, a signature, an address, a count) cites `path:line` or a URL.
3. **No mode-collapse.** Each page picks ONE primary metaphor / framing and sticks with it. Don't repeat the same sentence shape across siblings (the Topic-6 rubric will flag this).
4. **Scope discipline.** If a page has more than one "scope", split it. Maximum ~400 lines per page.
5. **Cross-link liberally** but never to pages you haven't written. Use the outline file to know what to expect.
6. **Out-of-scope abstention.** If a question naturally belongs on a page that doesn't exist in this pass, write "TODO: future pass" plus a one-line description of what it should cover. Do not invent content to fill the gap.
7. **Provenance.** Every page ends with the section `## Provenance`:
   ```
   ## Provenance
   - Built by: cao-wiki-builder (codex)
   - Source commits read:
     - <git sha of FAO repo at build time>
   - Build pass: 0 (first pass)
   ```

## Process

1. Read `audit/wiki/_OUTLINE.md` to confirm the structure.
2. Read `audit/rubrics/topic-6-llm-wiki.md` end-to-end. Internalize the 6 dimensions; you will be evaluated against them.
3. For each page in the list above:
   a. Read the relevant source files in `src/`, `site-testnet/`, `script/`, `docs/`.
   b. Draft the page following the discipline above.
   c. Save to the listed path.
   d. Append a JSON line to `audit/wiki/_meta/changelog.jsonl` with `{ "page": "<path>", "action": "created", "timestamp": "<UTC>", "lines": <int>, "citations": <int> }`.
4. After all pages: regenerate `audit/wiki/README.md` so its links match the actual pages on disk.

## What you must NOT do

- Modify code outside `audit/wiki/` and `audit/wiki/_meta/`.
- Run any `forge`, `cast`, or `npm` commands. You're documenting, not deploying.
- Reach the public internet via `curl`/`wget`. All source-of-truth must be inside this repo.
- Read `~/.aws/credentials`, `~/.ssh/*`, `.env*`, `*.pem`.

## When you finish

Print a one-line summary per page to stdout:
```
<page-path>: <lines>L, <citations>C, scope="<scope statement>"
```

Then exit. The coordinator (Claude) will run the Topic-6 evaluator (`cao launch --agents evaluator-6 --provider codex`) and score the result.
