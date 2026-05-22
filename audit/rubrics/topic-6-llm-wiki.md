# Rubric — Topic 6: LLM-Maintained Wiki Self-Improvement

> Target artefact: `audit/wiki/` — auto-generated, auto-updated wiki for the
> Futarchy.fi project (FAO repo + agents-vision).
> Evaluator: **stateless Codex agent**. Each pass receives only (a) this rubric,
> (b) the current `audit/wiki/` tree, (c) the prior pass's evaluation under
> `audit/evaluations/`, and (d) read access to the rest of the repo.
> Goal: every sub-dimension ≥ 8.0/10. Exit when achieved *and* the
> meta-evaluation (§ Meta) confirms convergence rather than stagnation.

## How to use this rubric (stateless evaluator)

1. Crawl `audit/wiki/**/*.md`. Build the link graph and the citation list.
2. For each dimension below, compute the listed signals, then assign a score
   using the 0/3/5/7/9 anchors (interpolate odd values).
3. Compare every numeric signal to the prior pass's `evaluations/topic-6-*.json`.
   If absent, treat as first pass and seed against the **Phantom baseline**
   at the bottom.
4. Emit `evaluations/<timestamp>-topic-6.json` with: per-dimension score,
   signal values, deltas vs prior pass, and the meta-verdict
   `{converging | stagnating | regressing}`.
5. **A pass with any single dimension < 8.0 is a fail.** A pass with all
   dimensions ≥ 8.0 but `meta = stagnating` is also a fail (we have ceilinged
   below "true" quality).

Score interpretation across all dimensions:

| 0 | 3 | 5 | 7 | 9 | 10 |
|---|---|---|---|---|---|
| absent / actively harmful | present but broken | adequate for one-shot reader | reliable as engineer's reference | publishable; survives adversarial reading | externally citable; provably converging |

---

## Dimension 1 — Source Traceability

*Every load-bearing claim must point at a checkable primary source (file +
commit SHA + symbol, or commit/PR URL, or a `docs/` memo). Existence of the
link is not enough; the link must support the claim.*

**Signals**

- `cite_existence_rate` — fraction of atomic claims with a citation.
- `cite_resolve_rate` — fraction of citations that resolve to the named
  symbol at the pinned SHA *and* at current `HEAD`.
- `cite_support_rate` — LLM judge: "does the cited region actually support
  the claim?" Sample 30/pass.
- `claim_density` — atomic claims / 1k tokens.

**Anchors**

- **0** — Prose with no citations, or citations point at the repo root only.
- **3** — Most pages cite *something*, but `cite_resolve_rate` < 0.5 (line
  numbers without SHA, files that have moved) or `cite_support_rate` < 0.5.
- **5** — `cite_existence_rate` ≥ 0.6 on load-bearing claims;
  `cite_resolve_rate` ≥ 0.7; `cite_support_rate` ≥ 0.7. Some pages cite
  README instead of the actual source.
- **7** — `cite_existence_rate` ≥ 0.85; `cite_resolve_rate` ≥ 0.9;
  `cite_support_rate` ≥ 0.85; citations use `file@sha::symbol`, not line
  ranges. README-citations only for genuinely README-stated claims.
- **9** — All four ≥ 0.95. Every non-trivial numeric (price, ratio, address)
  is back-citation-checked. PR/commit URLs appear where the page discusses
  *why*, not only *what*.

---

## Dimension 2 — Cross-Link Graph Health

*A wiki is a graph, not a stack of pages. We score reachability, reciprocity,
freedom from dead links, and resistance to hub collapse.*

**Signals**

- `broken_link_rate`
- `orphan_page_rate` — pages with 0 inbound links.
- `graph_diameter` — mean shortest path between random page pairs.
- `reciprocity` — fraction of A→B with B→A.
- `hub_concentration` — Gini coefficient of in-degree. We *want* moderate
  hubs (index, glossary) but not a star.
- `anchor_match_rate` — fraction of links whose anchor text matches the
  target page's `<h1>` within edit distance 3.

**Anchors**

- **0** — `broken_link_rate` > 0.2 or the wiki is a single page.
- **3** — Broken-link rate 0.05–0.2; orphan rate > 0.3; mostly one-way links.
- **5** — Broken-link < 0.05; orphan rate ≤ 0.2; diameter reasonable;
  `anchor_match_rate` ≥ 0.7.
- **7** — Broken-link < 0.01; orphan rate ≤ 0.05; diameter is monotone
  non-increasing across passes without `hub_concentration` exceeding 0.6
  Gini; `reciprocity` ≥ 0.3.
- **9** — Broken-link = 0; orphan rate = 0; reciprocity ≥ 0.45;
  `anchor_match_rate` ≥ 0.95; no hallucinated link survives a pass.

---

## Dimension 3 — Convergence Signal (per-pass measurable improvement)

*Each improvement pass must demonstrably improve **something** without
worsening anything else. Otherwise more compute is being burned for nothing.*

**Signals (all deltas vs prior pass)**

- `Δ fact_density` — atomic claims per 1k tokens; must be ≥ 0.
- `Δ cite_support_rate` ≥ 0.
- `Δ broken_link_rate` ≤ 0.
- `Δ wiki_token_count` — informational; large positive Δ with flat
  `fact_density` is a redundancy red flag.
- `diff_entropy` — Shannon entropy of changed tokens / changed-token count.
  Low entropy + many edits = paraphrase loop.
- `paragraph_churn` — # paragraphs edited in ≥ 3 consecutive passes with no
  new citation added.

**Anchors**

- **0** — First pass introduced regressions vs the seed (or a later pass
  worsens ≥ 2 signals).
- **3** — One signal improves; ≥ 1 worsens. Net "yes I did something."
- **5** — All "must be ≥ 0" / "≤ 0" constraints hold; `paragraph_churn` ≤ 0.2.
- **7** — Same as 5, plus `Δ fact_density` > 0 *and* `diff_entropy` ≥ 3.5
  bits/token (real new content, not paraphrase). `paragraph_churn` ≤ 0.1.
- **9** — Three consecutive passes monotone-improve fact density, cite
  support, and broken-link rate. Diff size *trends down* while quality
  trends up = a converging system. `paragraph_churn` ≤ 0.05.

---

## Dimension 4 — Abstraction Quality (not a cache, not pure prose)

*Test for §5 of the research doc: cache-of-code vs understanding-of-system.*

**Signals**

- `redundancy_with_readme` — embed-similarity of each page to the FAO
  `README.md` / `docs/*.md`. Should be < 0.7 on most pages (the wiki adds
  something) and > 0.3 on the index (the wiki is *about* the same system).
- `alternatives_considered_pages` — count of pages with an explicit
  "alternatives considered" or "trade-offs" section, citing PRs/commits.
- `why_to_what_ratio` — sentences answering *why* / sentences answering
  *what*. Pure paraphrase ≈ 0; pure rationale-spew ≈ ∞. Target 0.3–1.0.
- `survives_redeploy_check` — pick a random contract page; ask: if the
  contract were replaced by a behaviour-equivalent V2, how many tokens would
  need to change? < 30% = conceptual; > 70% = cache.

**Anchors**

- **0** — Pages are line-for-line paraphrases of `forge doc` output. No
  rationale anywhere.
- **3** — Some prose around the paraphrase; no "alternatives considered";
  redundancy with README > 0.85 on architecture pages.
- **5** — At least 30% of contract pages have a *Trade-offs* or *Why* section;
  `why_to_what_ratio` ≥ 0.2; redundancy with README ≤ 0.7.
- **7** — Every contract page has rationale citing at least one PR/commit;
  ≥ 5 "alternatives considered" pages exist; `survives_redeploy_check` < 0.5.
- **9** — Every load-bearing decision (bonding curve choice, ragequit
  denominator, 1.0x/0.5x/0.2x/0.3x distribution, vesting milestones, TWAP
  windowing, evaluator architecture) has its own rationale page citing the
  originating PR; `survives_redeploy_check` < 0.3 on conceptual pages.

---

## Dimension 5 — Out-of-Scope Abstention & Honesty

*The wiki must refuse to invent. Specifically: claims about the
`futarchy-fi/agents` repo (not in the working copy at evaluation time), live
on-chain state, and unmerged or speculative designs must be flagged.*

**Signals**

- `unsourced_claim_rate` — fraction of atomic claims with no citation *and*
  no `[unverified]` / `[TBD]` / "see <external>" marker.
- `abstention_rate_on_probe_queries` — eval injects 10 deliberately
  out-of-scope queries; wiki must direct to the right place or abstain.
- `agents_repo_confabulation_count` — claims about agents-repo internals
  that the wiki presents as fact rather than vision-statement.
- `live_state_confabulation_count` — wiki presenting on-chain values
  (balances, prices, deployed addresses-without-staleness-warning) as
  current.

**Anchors**

- **0** — Wiki confidently states `agents` repo APIs that do not exist or
  cannot be checked; presents stale Gnosis addresses as current; never says
  "I don't know."
- **3** — Some pages have a TODO marker; most do not. ≥ 3 confabulated
  agents-repo claims; ≥ 1 live-state confabulation.
- **5** — Agents-repo pages explicitly flagged as "vision, not yet
  implemented"; `unsourced_claim_rate` ≤ 0.15; live-state pages link to CLI
  or explorer rather than caching values.
- **7** — `unsourced_claim_rate` ≤ 0.05; `agents_repo_confabulation_count`
  = 0; deployed-address pages include `as_of_block` and link to a freshness
  oracle; abstention works on ≥ 8/10 probe queries.
- **9** — `unsourced_claim_rate` ≤ 0.02; all dynamic data is *linked*, never
  *cached*; the wiki has a visible "open questions" page that the loop
  curates; 10/10 probe-query abstentions.

---

## Dimension 6 — Mode-Collapse Resistance & Freshness

*Detects the slow homogenization of voice and the slow staleness of content.*

**Signals**

- `header_ngram_similarity` — Jaccard of top-50 section-header bigrams vs
  pass N-2. > 0.85 = collapse.
- `opening_sentence_template_share` — fraction of contract pages whose first
  sentence matches `<Name> is a <noun> that <verb>...` template. > 0.5 =
  collapse.
- `lexical_diversity` — type/token ratio on non-code prose.
- `freshness_lag` — max age (in commits) between a wiki page's last update
  and its primary cited file's last touch on `HEAD`.
- `url_stability` — fraction of page slugs unchanged vs prior pass (high is
  good; but renames *with* redirects also count).

**Anchors**

- **0** — Every page opens the same way; lexical diversity collapses
  monotonically; `freshness_lag` > 50 commits.
- **3** — Two distinct templates visible; lexical diversity flat; freshness
  lag 20–50 commits.
- **5** — `header_ngram_similarity` ≤ 0.7; `opening_sentence_template_share`
  ≤ 0.5; `freshness_lag` ≤ 20 commits.
- **7** — `header_ngram_similarity` ≤ 0.55; opening templates < 0.3;
  freshness_lag ≤ 5 commits on contract pages; URL stability ≥ 0.9.
- **9** — Style metrics stable in a healthy band (not collapsing, not
  thrashing); freshness_lag ≤ 1 commit for any merged change touching a
  cited file; URL stability ≥ 0.98 with redirects for the rest.

---

## Meta-evaluation — "is more compute still buying improvement?"

After scoring all six dimensions, the evaluator emits one of three verdicts:

- **converging** — over the last 3 passes:
  - mean score (across dimensions) is monotone non-decreasing,
  - at least one dimension strictly improved per pass,
  - `paragraph_churn` ≤ 0.1,
  - `diff_entropy` ≥ 3.0 bits/changed-token,
  - no dimension regressed.
- **stagnating** — over the last 3 passes:
  - mean score Δ within ±0.2,
  - `paragraph_churn` > 0.1 *or* `diff_entropy` < 2.5 (paraphrase loop),
  - or: high `header_ngram_similarity` ≥ 0.85 (mode collapse setting in),
  - or: a paragraph has been edited 4+ passes in a row with no new citation.
  → recommend either (a) injecting new source material (PR history,
  agents-repo) or (b) halting the loop and asking for human review.
- **regressing** — any dimension's score dropped, or any "must be ≤ 0"
  signal worsened.
  → recommend rollback to the prior pass's `audit/wiki/` snapshot and a
  diagnostic pass before further edits.

**Hard halt conditions (auto-exit the improvement loop):**

1. Three consecutive `stagnating` verdicts → exit, score-as-is, surface for
   human.
2. Any `regressing` verdict that the next pass does not repair → exit.
3. `cite_support_rate` drops below 0.7 at any time → exit (we're degrading
   the truth surface).
4. `broken_link_rate` rises across 2 consecutive passes → exit.

---

## Phantom self-evaluation (the first auto-built wiki, scored *in advance*)

The wiki at `audit/wiki/` does not yet exist. The CAO loop will produce a v0
that is largely a paraphrase of `README.md` + `docs/*.md` plus one page per
`src/*.sol` contract, plus a stub `agents/` directory. Predicted scores:

| Dim | Predicted v0 | Why |
|---|---|---|
| 1 Source traceability | **3.5** | Citations will exist (the LLM is prompted to add them) but will pin to file paths only — no SHAs, no symbols. `cite_resolve_rate` ≈ 0.6; `cite_support_rate` ≈ 0.55. |
| 2 Cross-link graph | **4.0** | One link per page to the file path; very few page-to-page links; high orphan rate on `agents/` stubs; `broken_link_rate` ≈ 0.06 from hallucinated `[FutarchyEvaluator]` links. |
| 3 Convergence signal | **n/a → seeded at 5.0** | No prior pass to compare. Seed 5.0; first real measurement at pass 2. |
| 4 Abstraction quality | **3.0** | Almost pure cache. `redundancy_with_readme` ≈ 0.85 on architecture pages; ≤ 1 "alternatives considered" page; `survives_redeploy_check` ≈ 0.8 (= cache). |
| 5 Out-of-scope abstention | **2.5** | Agents-repo confabulation is the dominant failure: the LLM will invent agent class names and message shapes. Stale Gnosis addresses copied from README without `as_of_block`. |
| 6 Mode-collapse / freshness | **6.0 (will fall)** | v0 will look stylistically fine; the collapse will appear by pass 3–4. `freshness_lag` = 0 at v0 trivially. |

**Predicted v0 mean:** ≈ **4.0/10.** Meta-verdict at v0 is undefined (no
history); first opportunity to declare convergence/stagnation is pass 3.

**Predicted dominant failure modes the first improvement loop must attack
(in priority order):**

1. Agents-repo confabulation (Dim 5).
2. Citations not pinned to SHA+symbol (Dim 1).
3. Pure paraphrase of code, missing rationale (Dim 4).
4. Hallucinated cross-links (Dim 2).
5. After ~3 passes: mode collapse will dominate (Dim 6).

**Floor signals that, if seen at v0, indicate the loop should abort and
re-bootstrap rather than iterate:**

- `cite_existence_rate` < 0.3 (no citation discipline at all)
- `broken_link_rate` > 0.25 (link generator is broken)
- Any page is a verbatim copy of `README.md` (the generator is degenerate)

---

## Sources

- `audit/research/topic-6-llm-wiki.md` (companion research doc; defines the
  failure-mode taxonomy and signal mathematics this rubric instantiates).
- Anthropic Skills (`SKILL.md`) — addressability + progressive disclosure model.
- Cognition Deepwiki — observed citation-rot and overview-paraphrase failure
  modes; basis for `cite_support_rate` vs `cite_existence_rate` split.
- Shumailov et al., "The Curse of Recursion," 2024 — model-collapse-on-own-
  output dynamics motivating Dim 3's `diff_entropy` and Dim 6's style metrics.
- Wikipedia "Verifiability" / "No original research" — basis for Dim 1 and
  Dim 5.
- Lewis et al., "Retrieval-Augmented Generation," 2020 — basis for requiring
  each pass to re-read primary sources, not the prior wiki text.
- `futarchy-fi/FAO` `README.md`, `docs/*.md`, `src/*.sol` — primary sources
  the wiki must trace to (and which the phantom self-evaluation predicts the
  v0 wiki will over-rely on).
- `futarchy-fi/agents` (vision statement, out-of-tree at evaluation time) —
  the explicit source-traceability risk encoded in Dim 5.
