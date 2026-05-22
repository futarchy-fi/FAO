# Topic 6 — Evaluating a Deep LLM-Maintained Wiki

> Scope: how to evaluate `audit/wiki/` — an auto-generated, auto-updated,
> continuously-improved knowledge base covering the `futarchy-fi/FAO` Solidity +
> frontend codebase and the `futarchy-fi/agents` autonomous-agent vision.
> The central question this rubric answers is **not** "is the wiki good?" but
> rather **"does each additional pass of self-improvement converge, stagnate, or
> regress?"** A wiki the CAO loop *cannot* push past a ceiling is worse than a
> human-written one, because it consumes compute indefinitely while pretending
> progress.

---

## 1. State of the art in LLM-maintained knowledge bases

A short field map. None of these systems solve the convergence problem
end-to-end; the rubric in `audit/rubrics/topic-6-llm-wiki.md` is designed to fill
that gap.

### 1.1 Anthropic Skills (`SKILL.md` model)

- Each skill is a small markdown file with progressive disclosure: a short
  description (always loaded) and a longer body (loaded only on match).
- Skills are *static* once written; updates are by human PR. This avoids the
  drift problems of fully autonomous wikis but does not scale to a system that
  changes per-commit.
- Key lesson: a wiki whose entries are *addressable, single-purpose, and named
  by their trigger conditions* is easier to keep correct than one with
  free-form topical pages. We bias the rubric toward "single concern per page,
  named after the concern."

### 1.2 Cursor docs / `.cursor/rules`

- `cursor.directory` and per-repo `.cursor/rules` files demonstrate a "rule
  cards" idiom: small, targeted, file-glob-scoped guidance.
- These pages have a strong notion of *applicability scope* (which files they
  govern). LLM wikis without an explicit scope tend to bleed authority — a page
  about `FAOSale.sol` ends up making claims about the sale UI because the model
  reaches for a single narrative.

### 1.3 GitBook AI / Mintlify / Notion AI

- Optimized for human-authored docs with LLM-assisted edits, not LLM-authored
  docs with human review. Their evaluation tooling focuses on broken links,
  readability scores, and "smart suggestions" — none of which detect mode
  collapse or hallucinated cross-references.
- Useful primitive: their broken-link checkers prove that a stateless,
  text-pattern evaluator can catch a large class of degradations cheaply.

### 1.4 Deepwiki (Devin, Cognition)

- Auto-generates a wiki per GitHub repo by running an agent over the code,
  produces hierarchical pages with citation back-links to source.
- Their public output exhibits the failure modes this rubric explicitly tests
  for: confident summaries of dead code, citation links pointing at line
  ranges that have since moved, "Overview" pages that paraphrase the README
  with extra adjectives, and duplicated content across "Architecture",
  "System design", and "How it works" pages.
- Lesson: **source traceability is necessary but not sufficient.** Deepwiki
  pages *do* cite source files, yet still contain claims that the cited source
  does not support. Our rubric requires the *content of the citation* to be
  checkable, not just its existence.

### 1.5 Continuously-trained model docs (LangChain, LlamaIndex)

- Their docs sites churn weekly. The failure mode is "API drift without page
  rename": the URL stays `vector_store.md` while the recommended class changes
  three times. Readers and downstream LLMs cache the wrong answer.
- Lesson: stability of *meaning at a URL* matters as much as freshness of
  content. We score "URL/anchor stability across passes" explicitly.

### 1.6 Wikipedia / Wikidata

- Provide the strongest external prior for "what a stable knowledge graph looks
  like": atomic claims, each citation-backed, with talk pages preserving
  alternatives considered.
- We borrow the **"alternatives considered"** convention. A wiki page that does
  not record what was tried-and-rejected is a cache of the current code; a
  wiki page that does is *understanding* (see §5).

---

## 2. Dynamics that cause LLM wikis to converge, stagnate, or collapse

### 2.1 Mode collapse

After ~3–5 self-revision passes, an LLM editor tends to converge on a single
template: the same opening sentence shape ("X is a Y that..."), the same
section headers ("Overview / Architecture / Usage / Notes"), the same
adjective ladder ("robust, modular, extensible"). Two symptoms:

- Cosine similarity of section headers across pages climbs above ~0.8.
- Adjective/noun ratio in non-code prose climbs; verbs in active voice drop.

Detection: track style fingerprints across passes (header n-grams, adjective
density, opening-sentence shape). Sudden homogenization = collapse.

### 2.2 Hallucinated cross-links

The model wants to be helpful and writes `[FutarchyEvaluator](../contracts/FutarchyEvaluator.md)`
because such a link "should" exist. If the page doesn't exist, the link is a
404. If it exists but covers something else (e.g., the *off-chain* evaluator),
the link is worse than 404: it silently misroutes.

Detection: graph crawl. (a) Every link resolves; (b) every link's anchor text
matches the target's `<h1>` within edit distance ε.

### 2.3 Citation rot

A `src/FAOSale.sol#L120` citation becomes wrong as soon as someone reformats
the file. The wiki claims to be source-traced but actually points at unrelated
code.

Detection: pin citations to *commit SHA + symbol name* (e.g.,
`FAOSale.sol@<sha>::_finalizeInitialPhase`) rather than line numbers, and
re-resolve symbols at evaluation time. Citation passes only if the symbol
exists at the pinned SHA *and* in the current `HEAD`.

### 2.4 Redundancy explosion

Each self-improvement pass adds a "clarifying sentence" to several pages.
Across N passes, the wiki grows ~linearly in words while information content
saturates. We measure **fact density** = (atomic verifiable claims) / (tokens)
and require it to be non-decreasing pass-to-pass.

### 2.5 Abstraction drift

Early passes describe `FAOSale` as "a contract that sells FAO for ETH." Later
passes, trying to sound deeper, generalize to "a market-making primitive for
bonded asset issuance." The generalization may be true but loses the specific
ETH price and the 1.0x/0.5x/0.2x/0.3x distribution. We score for the *presence
of load-bearing specifics*, not only for narrative quality.

### 2.6 Loss of "considered and rejected" knowledge

The first build of the wiki records what the code does. By pass 10 it has
expanded with rationale, but if the model never has access to *commit
messages, PR discussions, and rejected designs*, that rationale is
confabulated. Detection: every "we chose X over Y" claim must cite a commit,
PR, or `docs/` design memo. Otherwise, abstain.

### 2.7 Self-amplifying error

If pass N produces a small factual error and pass N+1 uses pass N as input,
the error becomes part of the model's prior for the topic and is reinforced.
This is the wiki analogue of model-collapse-on-synthetic-data. The defense:
each pass must re-read the *primary sources* (code, commits, on-chain
deployments) and not the previous wiki text, for at least the load-bearing
sections.

---

## 3. Self-improvement signals to encode

Numerical, stateless, computable by a Codex evaluator:

| Signal | How to compute | What it tells us |
|---|---|---|
| **Per-revision diff size** | `git diff --stat` between wiki snapshots | Sustained large diffs after pass ~5 = churn, not improvement |
| **Diff entropy** | Shannon entropy of changed tokens vs prior pass | Low entropy with many edits = paraphrase loop |
| **Fact density** | atomic claims / 1k tokens (LLM extracts claims, regex backstop on numbers/addresses/symbols) | Should rise then plateau, never fall |
| **Broken-link rate** | crawl all `[..](..)` and `#anchor`s | Must trend to 0 |
| **Cross-link graph diameter** | mean shortest path between pages | Should fall pass-to-pass (better navigability) without collapsing to a star (over-centralization) |
| **Cross-link reciprocity** | fraction of links A→B with a back-reference from B | Healthy wiki ≥ 0.4; pure tree = 0 |
| **Citation pass rate** | fraction of `src/...@<sha>::<symbol>` citations that resolve in current `HEAD` | Source-of-truth agreement |
| **Source-of-truth agreement** | LLM judge re-derives claim from cited source; agree/disagree | Distinguishes "cites source" from "supported by source" |
| **Out-of-scope abstention** | rate at which the wiki says "not covered here" or "see <repo>/<file>" instead of confabulating | Honesty signal |
| **Style fingerprint stability** | Jaccard of top-50 bigrams of section headers vs pass N-2 | High stability + flat fact density = mode collapse |
| **Per-page churn-without-improvement** | same paragraph edited in ≥ 3 consecutive passes, no new linked source | Paraphrase loop indicator |
| **URL/anchor stability** | fraction of `<h1>`/`<h2>` slugs preserved pass-to-pass | Downstream cacheability |

Convergence = these signals all stabilize within tight bands and the
score-per-dimension is ≥ 8.0. Stagnation = signals stable but score < 8.0.
Regression = at least one signal worsens across two passes.

---

## 4. Test patterns: "is this wiki getting better?"

### 4.1 Forced regressions

Before each pass, randomly mutate the wiki: delete a paragraph, swap two
function names, downgrade a citation SHA. The evaluator must catch the
regression and the next pass must repair it. A wiki that doesn't notice the
mutation has no useful gradient.

### 4.2 A/B reading comprehension

Hold out 10 fixed questions about the FAO codebase (e.g., "how is the 0.0001
ETH/FAO price enforced during the initial phase?", "which contract holds the
ragequit pro-rata denominator?"). Have a fresh model with *only* the wiki
answer them. Compare against the same model with *only* the code. Wiki score
= comprehension accuracy / code-only accuracy. Target ≥ 0.85 for in-scope
questions, ≤ 0.10 hallucination rate for out-of-scope.

### 4.3 Source-traceability rate

For a random sample of 30 atomic claims per pass, an evaluator must locate the
supporting line in the cited file at the cited SHA. Pass rate ≥ 0.9.

### 4.4 Out-of-scope abstention

Inject queries the wiki *should not* answer (e.g., "what's the current FAO
treasury balance on Gnosis?" — that's chain state, not docs). Wiki must route
to the correct external source (CLI, explorer) or abstain. No confabulation.

### 4.5 Roundtrip-from-code

Pick a small module (e.g., `FAOTwapResolver.sol`). Delete its wiki page. Run
one improvement pass. The regenerated page must agree with the prior version
on ≥ 80% of atomic claims and must not introduce new unsupported claims.

### 4.6 Cross-link diameter watchdog

After each pass, compute the graph diameter. If diameter increases without a
corresponding fact-density increase, the wiki has fragmented (new pages
disconnected from the corpus); fail the pass.

---

## 5. Cache-of-code vs understanding-of-system

The hardest distinction this rubric must enforce. Anchors:

**Cache of code (anti-pattern, score 0–3 on Abstraction Quality).**
- Page is a paraphrase of file contents. Deleting the file makes the page
  meaningless. Deleting the page costs nothing — `forge doc` would regenerate
  equivalent prose.
- No reference to commit history, PRs, or design memos in `docs/`.
- No "alternatives considered" section, no trade-off discussion.
- Cross-links are 1:1 with file paths.

**Understanding of system (target, score 7–9).**
- Each page answers *why* and *what was tried instead*, citing commits/PRs.
- Links connect concept to concept (e.g., "ragequit accounting" ↔ "initial
  phase finalization") not file to file.
- Explicit trade-offs: "we chose linear bonding because [commit] X; an
  exponential variant was considered in [PR] Y and rejected because Z."
- Survives a redeploy: if `FAOSale` is replaced by `FAOSaleV2` with the same
  contract, the conceptual pages need only their citation SHAs bumped, not a
  rewrite.
- Has an "open questions" / "known unknowns" page that the loop maintains.

**Operational test.** Ask: *"If we deleted all `src/` and `script/` files and
kept only the wiki, could a competent engineer reconstruct the design
intent?"* If yes, it is understanding. If only the file structure could be
reconstructed, it is a cache.

---

## 6. Specific anticipated failure modes for the *first* CAO-built wiki

(Used to seed the phantom self-evaluation in the rubric.)

1. **README echo.** First pass will paraphrase `README.md` and `docs/*.md` and
   present it as 6–10 "Architecture" pages. Fact density will be high but
   redundancy with the README will be near 1.0.
2. **Agents-vision confabulation.** The `futarchy-fi/agents` repo content is
   not in this working copy; the first pass will fabricate plausible APIs.
   Expect very low source-traceability on agent pages.
3. **Solidity inheritance trees over-explained.** `AccessControl`,
   `ERC20Burnable`, etc., will get their own pages. They should link to
   OpenZeppelin, not be re-explained.
4. **Stale on-chain addresses.** The current README lists "Old Version"
   addresses on Gnosis. The wiki will likely promote them to "Deployments"
   without flagging staleness.
5. **No "rejected designs" content.** First pass has no access to PR
   discussions and will skip or invent trade-offs.
6. **Mode-collapse risk after pass 3.** Once the page template is set, all
   pages will start with "<Contract> is a Solidity contract that..." Expect
   header n-gram similarity > 0.8 by pass 4 unless the rubric pushes against
   it.
7. **Cross-link sparsity early; explosion later.** Pass 1 will have ~1
   link/page. Pass 5 will have ~10 with 30% broken.
8. **Citation rot from pass 2 onward** as the contracts get reformatted by
   `forge fmt`.

These predictions are encoded as the phantom baseline in the rubric.

---

## Sources

- Anthropic. *Claude Skills* announcement & `SKILL.md` reference (2025) —
  https://www.anthropic.com/news/skills and Anthropic docs.
- Cursor. `.cursor/rules` and cursor.directory documentation —
  https://docs.cursor.com/ , https://cursor.directory.
- Cognition Labs / Devin. *Deepwiki* — https://deepwiki.com .
- Mintlify docs — https://mintlify.com/docs .
- GitBook AI — https://docs.gitbook.com/ .
- Shumailov et al., "The Curse of Recursion: Training on Generated Data Makes
  Models Forget," 2024, on model collapse dynamics applicable to recursive
  text generation.
- Bender, Gebru, McMillan-Major, Shmitchell. "On the Dangers of Stochastic
  Parrots," 2021 — relevant to confabulation and citation-without-support.
- Lewis et al., "Retrieval-Augmented Generation," 2020 — retrieval as the
  primary defense against self-amplifying error.
- Wikipedia editorial policy: "Verifiability" and "No original research" —
  https://en.wikipedia.org/wiki/Wikipedia:Verifiability ; the
  alternatives-considered / talk-page convention.
- LangChain & LlamaIndex docs sites — observed churn patterns as live case
  studies of API-drift-without-URL-rename.
- `futarchy-fi/FAO` repository `README.md`, `docs/*.md`, `src/*.sol` (this
  working copy) — primary source for the wiki to be built.
- `futarchy-fi/agents` (out-of-tree at evaluation time) — vision document for
  the agents layer; explicitly flagged as a source-traceability risk in §6.
