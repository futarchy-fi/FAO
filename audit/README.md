# CAO — Continuous Auditing & Optimization

Goal directive (from `/goal`):

1. Deep research → rubric: web3 interface UX / minimalism / architecture
2. Deep research → rubric: high-level interface testing + user flows (quality + completeness + conciseness)
3. Deep research → rubric: formal-spec readiness of futarchy-style apps
4. Deep research → rubric: smart-contract testing infra + formal verification
5. Deep research → rubric: holistic SC + interface patterns (security + maintainability)
6. Deep research → rubric: LLM-wiki self-improvement evaluation
7. Build a futarchy wiki spanning `futarchy-fi/FAO` + the `futarchy-fi/agents` vision
8. Define 6 CAO evaluator subagents (one per dimension; must detect both improvement AND regression)
9. Improvement loop using Codex-backed CAO agents; Claude coordinates + reviews + applies changes; target ≥ 8.0 on every sub-score (≥ 30 sub-scores total).

## Directory layout

| Path | Purpose |
|---|---|
| `research/` | One markdown per topic 1–6: state-of-the-art best-practices write-up + sources. |
| `rubrics/` | One markdown per topic 1–6: the report-card rubric (≥ 5 dimensions × 0–10 scale + criteria per score level + a worked self-evaluation of the current FAO repo / site / etc.). |
| `wiki/` | The auto-maintained Futarchy wiki (covers FAO repo + agents-vision). |
| `evaluations/` | Time-stamped CAO evaluation reports — one row per dimension per pass. |
| `loops/` | Per-loop state: target dimensions, hypothesis, applied changes, before / after scores. |
| `state/` | Coordinator state (which subagents are running, latest scores, queued work). |

## Phase tracker

See `state/PHASE.md` for the current phase / blocker. Every coordinator update should append, not overwrite, so the history is auditable.
