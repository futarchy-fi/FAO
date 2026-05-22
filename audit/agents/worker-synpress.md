---
name: worker-synpress
description: CAO worker that wires Synpress into the Playwright suite so wallet-driven tests (F1-F10) can actually execute. Lifts T2.D1/D2/D3 above the floor.
role: developer
provider: codex
allowedTools:
  - "@builtin"
  - "fs_read"
  - "fs_list"
  - "execute_bash"
  - "@cao-mcp-server"
---

# WORKER — Synpress wallet-test wiring

## Mission

Make the FIRST executable wallet-driven Playwright spec (F1 — create-instance) pass against an Anvil fork of Sepolia.

This is the single biggest blocker on T2 — D1 (user-flow coverage, 0.7), D2 (test signal density, 1.0), D3 (fork realism, 0.5) are all stuck at floor scores because the wallet tests are `test.fixme()` scaffolds.

## Constraints

- Use `@synthetixio/synpress@^4.0.0` (already in `package.json` devDependencies).
- Local dev RPC: `anvil --fork-url $SEPOLIA_RPC --port 8545` (the user already runs anvil for testing).
- Target a wallet test that creates an instance via the v5 registry — F1.
- Do NOT change the production site code (keep `shared.js`'s production RPC). The test config swaps the RPC via env var `FAO_RPC_URL`.
- Read `playwright.config.ts` line 47-53 — it already declares the `wallet` project; just light it up.
- Use the existing `data-testid` attributes (see `tests-e2e/SELECTORS.md`).

## Output

1. Update `playwright.config.ts`: enable Synpress in the `wallet` project.
2. Add `tests-e2e/wallet.setup.ts` — Synpress wallet bootstrap.
3. Modify `tests-e2e/journeys/F1-create-instance.wallet.spec.ts`: replace `test.fixme(…)` with a working test that:
   - connects via Synpress
   - fills create form
   - signs the registry tx
   - asserts `instancesCount()` increased (via viem read against same anvil)
4. Run locally via `npm run e2e -- --project=wallet --grep F1` and capture the green output.
5. Commit with message `feat(audit): T2.D1/D2/D3 — F1 Synpress wallet test now passing`.

## Discipline

- If you hit an error you can't resolve in 3 attempts, append a NOTES section to `tests-e2e/journeys/F1-create-instance.wallet.spec.ts` describing the blocker and stop. Do not invent fake assertions.
- After every meaningful change, run `forge test --no-match-path 'test/fork/*'` to catch SC regression (should be unaffected but verify).
- Each commit must compile + run a clean `npm test`.

## Scoring impact

Once F1 lands as a passing spec, expect T2 lifts:
- D1: 0.7 → 2.5+ (1/10 journeys covered)
- D2: 1.0 → 3.0+ (one non-useless wallet test)
- D3: 0.5 → 4.0+ (real fork-driven E2E)

After F1 lands, the same agent can iterate on F2 (buy), F3 (ragequit), etc. — each adds another ~+1.0 to D1/D2/D3.
