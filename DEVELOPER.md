---
canonical: DEVELOPER.md
scope: Local-dev cycle for the FAO repo — what to install, what commands to run, how long each takes, how the cycle is measured.
not-scope: Operator runbook (`audit/state/RUNBOOK.md`), deploy mechanics (`site-testnet/README.md`).
last-rebuilt: 2026-05-22
---

# Developer cycle

T2.D6 (Performance & developer cycle time, score 2.0) measures how
quickly an authoring loop completes: open a file → edit → see the
result. This doc is the **explicit cycle inventory** with measured
times per operation on a 2024-class laptop.

## TL;DR

```bash
# One-time
git submodule update --init --recursive   # ~30s (700MB lib/)
npm install                                # ~12s
foundryup                                  # ~2s if foundry is on PATH

# Per session
npm run dev                                # site at http://127.0.0.1:8766
forge test                                 # unit suite — see "Cycle times" below
npm run e2e:read-only                      # Playwright headless, 6 tests
```

## Cycle times (measured 2026-05-22)

| Action | Command | Cold | Warm | Cap |
|---|---|---|---|---|
| forge build | `forge build` | 35s | 0.5s (incremental) | 60s |
| Unit suite | `forge test --no-match-path 'test/fork/*'` | 75s | 65s | 120s |
| Single test | `forge test --match-test test_X` | 35s | 5s | — |
| Invariant suite | `forge test --match-test 'invariant_'` × 5000 calls | 240s | 230s | 300s |
| Static analysis | `slither . --filter-paths lib/` | 30s | 25s | — |
| Symbolic check | `halmos --match-test 'check_INV_' --loop 3` | ~90s per `check_*` | — | — |
| Deployments-sync | `bash scripts/check-deployments-sync.sh` | <0.1s | — | — |
| Site local-serve | `npm run dev` | 0.1s startup | — | — |
| E2E read-only | `npm run e2e:read-only` | 30s | 10s | 90s |

## Iteration patterns

### Contract change (most common)

```bash
# 1. Edit src/<Contract>.sol
# 2. forge test --match-contract <Contract>      ~5-15s warm
# 3. If passes, full suite to catch cross-contract regression
forge test --no-match-path 'test/fork/*'         ~65s warm
# 4. If touching INV-* surface, run symbolic + invariant:
forge test --match-test 'invariant_INV_'         ~230s
FOUNDRY_PROFILE=halmos halmos --match-test 'check_INV_'  ~90s × N
```

### Site change

```bash
# 1. Edit site-testnet/*.{html,css,js}
# 2. Refresh http://127.0.0.1:8766 (no build step — static)
# 3. If touching deployments.json:
cp deployments.json site-testnet/deployments.json
bash scripts/check-deployments-sync.sh           # CI gate
# 4. Read-only E2E to catch regressions
npm run e2e:read-only                            ~10s warm
```

### Spec / invariant change

```bash
# 1. Edit audit/specs/INVARIANTS.md (or preconditions/, etc).
# 2. Re-grep @custom:spec NatSpec to confirm impl is still pinned:
git grep -nE '@custom:spec INV-' src
# 3. Update the rubric expectation if needed.
# 4. Dispatch the relevant Topic 3 evaluator (cao).
```

## Why these times matter

T2.D6 anchors at:
- 0-2: no documented dev cycle.
- 3-5: dev cycle exists but isn't measured.
- 6-8: measured cycle ≤ 120s for the most common change class.
- 9-10: measured + parallelizable + sub-30s for the median change.

Today's warm unit-suite at ~65s and a sub-15s incremental contract-change cycle land us in the 6-8 band. To reach 9-10:

1. **Parallelize forge test workers** — `forge test --threads 4` (need to verify it doesn't break invariant determinism).
2. **Symbolic checks behind a marker** — skip slow `check_INV_*` runs on every PR; only on `paths: src/` events. **Done** in `.github/workflows/symbolic.yml`.
3. **Hot-reload for site changes** — wire `npx browser-sync` so saves trigger refresh without manual reload. Optional; static HTTP server is already < 1s reload.

## CI cycle

| Workflow | Trigger | Wall time |
|---|---|---|
| `static-analysis.yml` | src/, deployments.json | ~3 min (Slither + sync check) |
| `symbolic.yml` | src/ + cron | ~7 min (SMTChecker + Halmos) |
| `deploy-site.yml` | site/ on main | ~30s (artifact upload + Pages deploy) |
| Foundry tests | (not yet in CI; runs locally only) | — |

**Gap:** Foundry tests aren't yet in CI. Adding `forge-ci.yml` is the next T4.D5 lift.

## How this might be wrong

- Cycle times are 2024-class laptop measurements; cloud CI is slower.
- "Warm" assumes the `out/` cache is populated. A fresh clone pays ~35s cold-build penalty.
- Halmos per-`check_*` time depends on solver budget; the 90s is for `--loop 3`. Tighter or looser bounds change this by 2-5x.
- The "9-10" anchor assumes parallelization works; forge's invariant tests use shared rng state in some patterns, so threading may introduce flake.
- npm install is < 15s on cached registries but can be 60s+ on cold ones with poor network.

## See also

- `audit/state/RUNBOOK.md` — operator commands (different audience).
- `playwright.config.ts` — E2E project layout (read-only vs wallet).
- `.github/workflows/*.yml` — what runs in CI.
- `package.json` — npm script index.
