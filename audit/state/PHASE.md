# Phase tracker

## Naming
Originally created as `cao/` for "Continuous Auditing & Optimization" — collided with Kelvin's actual CAO (CLI Agent Orchestrator binary at `~/.local/bin/cao`). Renamed to `audit/` on 2026-05-22 after Phase 1 completed. Internal `cao/` path references inside markdown files were ripple-replaced with `audit/`.

## CAO usage (Phase 4+)
- Each evaluator and worker is a CAO agent profile under `~/.aws/cli-agent-orchestrator/agent-store/` (we'll author them in `audit/agents/` and `cao install` them).
- Launched via `cao launch --agents <profile> --provider codex --headless` (creates tmux session `cao-<name>`).
- Profiles reference `${VAR}` from `~/.aws/cli-agent-orchestrator/.env`.

## Phase plan

| # | Phase | Output | Status |
|---|---|---|---|
| 1 | Research × 6 (parallel Claude-Code Agent subagents) | `research/topic-1..6.md` + `rubrics/topic-1..6.md` | **done** ✓ |
| 2 | Rubric review + cross-link + dir rename → `audit/` + baseline summary | `audit/state/BASELINE.md`, ripple fix | **done** ✓ |
| 3 | Wiki build (Futarchy + futarchy-fi/FAO + futarchy-fi/agents vision) | `audit/wiki/` populated, scoreable on T6 | in progress |
| 4 | Define 6 evaluator agent profiles (CAO + codex) | `audit/agents/evaluator-{1..6}.md` installable | in progress (in parallel with phase 3) |
| 5 | Baseline scoring run (launches 6 CAO codex sessions) | `audit/evaluations/baseline-*.jsonl` (independent re-score; should match BASELINE.md within ±1.0) | pending |
| 6 | Improvement loop | CAO worker sessions (codex) propose changes; CAO evaluator sessions re-score; Claude orchestrates + applies. Recorded in `audit/loops/`. Exit when all 39 sub-scores ≥ 8.0. | pending |

## Total sub-scores: **39** (T1:6 + T2:7 + T3:8 + T4:6 + T5:6 + T6:6)

## Baseline summary

- **System floor:** 0.0 (T3.D1 spec-doc-existence, T3.D6 spec↔impl-traceability, T2.D1–D6 most dims)
- **Mean of mins:** 1.9
- **Goal:** ≥ 8.0 across all 39

See `audit/state/BASELINE.md` for the per-dimension table + first-fix priorities.

## History
- 2026-05-22 — Goal received; scaffold initialized as `cao/`.
- 2026-05-22 — Confused with Kelvin's CAO orchestrator; corrected; planned rename.
- 2026-05-22 — 6 research subagents launched (in-process Claude-Code).
- 2026-05-22 — 4 agents completed cleanly (T2, T3, T4, T6).
- 2026-05-22 — T1 + T5 agents hit API-overload mid-rubric (research files survived); re-launched rubric-only follow-ups.
- 2026-05-22 — T5 re-launch completed (baseline 3.0/10 min).
- 2026-05-22 — T1 re-launch completed (baseline 3.5/10 min).
- 2026-05-22 — Phase 1 done; rubrics cross-checked (orthogonal); `cao/` → `audit/` rename + ripple fix; baseline summary written.
- 2026-05-22 — Phase 3 + 4 launched in parallel.
