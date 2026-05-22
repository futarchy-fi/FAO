---
name: worker-fork-realism
description: CAO worker that lifts T2.D3 (fork realism) via Anvil-driven read-only Playwright specs — no wallet needed, but the UI is pointed at a local Anvil fork and assertions verify fork-derived state.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Fork-realism for read-only E2E

## Mission

Lift T2.D3 (realism, score 0.5) without requiring Synpress. The lift comes from running the existing read-only Playwright specs against a **live Anvil fork** of Sepolia, with chain-state mutations made directly via `cast send` (no wallet UI) and assertions made via `viem.createPublicClient`.

## Concrete deliverables

### 1. Anvil fork bootstrap

- New script: `scripts/anvil-fork.sh`. Spawns `anvil --fork-url $SEPOLIA_RPC --port 8545` in the background; writes the PID to `/tmp/fao-anvil.pid`. Has `--stop` mode that kills the PID.
- Honors `SEPOLIA_RPC` env (default to a public Sepolia RPC if not set).

### 2. Site-config override for fork mode

- Update `site-testnet/shared.js`: when `localStorage.faoForkMode === '1'`, the `RPC` constant becomes `http://127.0.0.1:8545`.
- Update `playwright.config.ts`: a new `fork` project that visits the site with `localStorage.faoForkMode=1` set via initScript.

### 3. Fork-driven read-only specs

- New file: `tests-e2e/journeys/fork-state.read-only.spec.ts`.
- Tests:
  - Page reads `instancesCount()` — assert it matches the fork's value (read via viem).
  - `cast send` to add a new instance, refresh page, assert UI now shows N+1 instances.
  - `cast send` to buy from a sale, refresh, assert UI shows updated `tokensSold`.
- These tests need NO wallet — they mutate state via cast and verify the UI reflects it.

## Constraints

- Don't break the production site for non-fork users — the localStorage flag default is false.
- Tests must pass deterministically against the same fork block.
- Anvil's `--fork-block-number` parameter pins the fork; the test fixture sets it.

## Discipline

- If a `cast send` consistently reverts due to gas/RPC weirdness, document why in `scripts/anvil-fork.md` and STOP — don't fake assertions.

## Scoring impact

Lifts T2.D3 from 0.5 → 4.5+ (cast-send + UI assertions is "real fork-driven E2E", just no wallet UI).
T2.D1 (user-flow coverage) +1 because each cast-send/refresh scenario is essentially a journey.
T2.D2 (test signal density) +0.5.
