# Rubric — Topic 4: Smart-Contract Testing Infrastructure

> Stateless evaluator notes — every check is a command or filesystem inspection runnable from the repo root. Repo path: `/home/kelvin/repos/futarchy-fi/FAO`. Solidity ^0.8.20, Foundry. **Pass threshold per dimension: 8.0 / 10.0.**

This rubric scores the *infrastructure that verifies the code matches the spec*. The spec itself is scored under Topic 3.

---

## How to evaluate

For each of the 6 dimensions:

1. Run the **Commands to run** in the order given.
2. Compare the observed evidence against the **Anchors** (0 / 3 / 5 / 7 / 9).
3. Pick the closest anchor; interpolate within ±1 if the evidence is mixed.
4. Record a **score** (0–10), a one-sentence **rationale**, and the **file paths or commands** that support it.

A passing aggregate is `min(dimension_scores) ≥ 8.0`. Average is recorded but **not** the gate — the worst dimension is the gate.

---

## Dimension 1 — Layer coverage (unit / integration / fuzz / invariant / symbolic / fork)

**What it measures.** How many of the 10 testing-pyramid layers (see `audit/research/topic-4-sc-testing-infra.md` §2) are populated with non-trivial tests.

**Commands to run.**

```bash
# unit + integration test count
grep -rE "function test_|function test[A-Z]" test --include="*.sol" | wc -l
# fuzz tests
grep -rE "function testFuzz_" test --include="*.sol" | wc -l
# invariant tests + handlers
grep -rE "function invariant_|StdInvariant|targetContract\(" test --include="*.sol" | wc -l
# symbolic tests
grep -rE "function (testSym_|prove)" test --include="*.sol" | wc -l
# fork tests
grep -rE "vm\.createSelectFork|vm\.createFork" test --include="*.sol" | wc -l
# echidna / medusa harnesses
find . -name "echidna.yaml" -o -name "medusa.json" -not -path "*/lib/*" -not -path "*/.claude/*"
# certora specs
find . -path "*/certora/specs/*.spec" -not -path "*/lib/*"
```

**Anchors.**

- **0** — Only `forge build` works; no `test/` directory, or only stub tests.
- **3** — Unit tests exist (≥ 1 per contract on average) and they pass. No fuzz, no invariant, no fork, no symbolic.
- **5** — Unit + integration + at least one of {fuzz, invariant, fork} are present. Other advanced layers absent.
- **7** — Four of the five layers {unit, integration, fuzz, invariant, fork} are non-trivially populated. At least 1 invariant test contract exists.
- **9** — All five core layers plus at least one of {symbolic (Halmos/hevm), Echidna/Medusa, Certora/SMTChecker} are present and run in CI.
- **10** — All seven layers (above + chaos/agents + mainnet-shadow / Tenderly Virtual TestNet) wired with metrics emitted to disk.

---

## Dimension 2 — Spec → check traceability

**What it measures.** For each invariant or behavioural claim in the spec (Topic 3 artefact), is there a named, executable test? Can a stateless reviewer cross-reference spec line → test name?

**Commands to run.**

```bash
# spec artefacts produced by Topic 3
ls audit/research/topic-3-*.md audit/rubrics/topic-3-*.md 2>/dev/null
# explicit invariant naming
grep -rE "invariant_[a-zA-Z_]+" test --include="*.sol"
# spec references in test files
grep -rE "@spec|@ref|spec/|SPEC-[0-9]+" test --include="*.sol"
# inline natspec invariants in src
grep -rE "@invariant|@notice Invariant|MUST |must hold" src --include="*.sol"
```

**Anchors.**

- **0** — No spec document referenced from any test. No `@invariant` natspec. Test names are `testFoo1`, `testFoo2`.
- **3** — Tests have descriptive names but no link to a spec. Some invariants implicit in the code's natspec.
- **5** — A design doc lists informal invariants; some tests have matching names but no machine-checkable cross-reference.
- **7** — Spec invariants are enumerated (e.g. `INV-1`, `INV-2`); ≥ 60% have a test with a matching name, comment, or `@spec` tag.
- **9** — ≥ 90% of spec invariants map to a named test; coverage of the mapping is reproducible (a script lists missing/orphan invariants).
- **10** — 100% mapping plus a CI job that fails if a spec invariant has no corresponding test.

---

## Dimension 3 — Mutation resistance (test-suite strength)

**What it measures.** Whether the test suite would actually catch deliberate code changes. Coverage alone is insufficient.

**Commands to run.**

```bash
# is a mutation tool configured?
grep -rE "vertigo|gambit|sumo|mutation" foundry.toml .github/ Makefile 2>/dev/null
ls .vertigorc vertigo.yml 2>/dev/null
# coverage as a (weaker) proxy
forge coverage --ir-minimum --report summary 2>/dev/null | tail -5
# direct invariant: count assertions per test function
grep -c "assertEq\|assertTrue\|assertGt\|assertLt\|assertLe\|assertGe" test/*.sol | sort -t: -k2 -n
```

**Anchors.**

- **0** — Tests exist but most contain ≤ 1 assertion ("smoke tests"). No coverage report obtainable. No mutation tooling.
- **3** — Line coverage ≥ 50% but no mutation testing; many tests assert only "no revert."
- **5** — Line coverage ≥ 75% (with `--ir-minimum`); ≥ 3 assertions per test on average; no mutation tool wired but a coverage gate exists in CI.
- **7** — Coverage ≥ 85%; a mutation tool (Vertigo / Gambit / SuMo) is configured, has been run at least once, and a baseline mutation score is committed.
- **9** — Mutation score ≥ 70% on `src/` (excluding generated/vendored). Mutation testing runs nightly in CI. New surviving mutants block release.
- **10** — Mutation score ≥ 85%; per-file mutation thresholds enforced as PR gates; failing files have explicit waivers.

---

## Dimension 4 — Fork realism

**What it measures.** Whether the suite exercises real upstream protocol state, or lives entirely in mock-land.

**Commands to run.**

```bash
# fork test count and gating pattern
grep -rE "vm\.createSelectFork|vm\.rpcUrl" test --include="*.sol" | wc -l
grep -rE "RUN_.*FORK.*TESTS|envOr.*FORK" test --include="*.sol" | wc -l
# pinned block numbers (non-determinism warning)
grep -rE "createSelectFork\([^,)]+\)" test --include="*.sol"  # no second arg = floating block
# integrated chains
grep -rE "rpcUrl\(\"" test --include="*.sol" | sort -u
# CI fork-test execution
grep -rE "RUN_.*FORK.*TESTS|forge test.*fork" .github/workflows/
# tenderly / virtual testnet
grep -rE "tenderly|virtual.*testnet" docs/ .github/ 2>/dev/null
```

**Anchors.**

- **0** — Zero fork tests. All tests use mocks.
- **3** — One or two fork tests for the most critical boundary contract; not exercised in CI.
- **5** — Fork tests exist for all major external integrations (oracle, AMM, CTF, etc.) but block numbers are not pinned, and CI does not run them.
- **7** — Fork tests cover all boundary contracts, block numbers are pinned, fork tests run in a gated nightly or release CI job.
- **9** — Above plus a Tenderly Virtual TestNet (or equivalent durable hosted fork) is used for staging deploys; deployment script is dry-run on the fork before mainnet broadcast.
- **10** — Above plus mainnet-shadow simulation: every protocol-mutating transaction is `eth_call`'d against a fresh fork pre-broadcast, with the result asserted matches the expected state delta.

---

## Dimension 5 — CI gating & reproducibility

**What it measures.** Whether the test suite is a merge gate, deterministic, and pin-versioned so that "passing CI" means the same thing tomorrow as today.

**Commands to run.**

```bash
ls .github/workflows/
cat .github/workflows/test.yml 2>/dev/null
# foundry version pinned?
grep -E "version:|foundry-toolchain@" .github/workflows/test.yml
# profile.ci actually defined?
grep -E "\[profile\.ci\]|FOUNDRY_PROFILE" foundry.toml .github/workflows/test.yml
# fuzz/invariant seed determinism for PRs
grep -E "fuzz|invariant|seed" foundry.toml
# coverage / gas / snapshot gates
grep -rE "forge coverage|forge snapshot|gas-report|codecov" .github/workflows/
# slither / aderyn / static analysis
grep -rE "slither|aderyn" .github/workflows/
```

**Anchors.**

- **0** — No CI for tests. Or CI exists but `forge test` is not run on PRs.
- **3** — CI runs `forge test` on PRs; uses unpinned actions; no profile definition; passing CI means little.
- **5** — CI runs unit/integration tests; Foundry version pinned; `forge fmt --check` runs; one coverage or gas signal is reported (not gated).
- **7** — CI runs the full layered suite (unit + fuzz + invariant + fork-gated); coverage and gas regression are CI gates; Foundry/solc versions pinned; a `[profile.ci]` block exists and tightens fuzz/invariant runs.
- **9** — Above plus: deterministic seeds for PR runs; nightly jobs for Echidna/mutation; static analysis (Slither/Aderyn) is a PR gate; artifacts uploaded for downstream CAO consumption.
- **10** — Above plus: deployment scripts run as a dry-run job in CI; release-tag jobs run mutation testing + symbolic checks before tag is signed.

---

## Dimension 6 — Tooling diversity (single-tool risk)

**What it measures.** Whether the verification stack stands on more than one tool. Foundry-only suites have a *tool* attack surface: a Foundry bug, fuzz-seed pathology, or coverage instrumentation gap silently masks bugs.

**Commands to run.**

```bash
# tools wired (excluding lib/ deps)
grep -rE "echidna|medusa|halmos|certora|kontrol|hevm|smtchecker|model_checker" \
  --include="*.toml" --include="*.yml" --include="*.yaml" --include="*.json" --include="*.sh" \
  . 2>/dev/null | grep -v "^./lib/" | grep -v "^./.claude/"
# static analysis
grep -rE "slither|aderyn|mythril|manticore" .github/ Makefile 2>/dev/null
# differential / equivalence tests
grep -rE "differential|equivalence" test --include="*.sol"
```

**Anchors.**

- **0** — One tool (Foundry) for everything. No static analysis. No symbolic. No formal.
- **3** — Foundry + one static-analysis tool (e.g. Slither in a workflow), nothing else.
- **5** — Foundry + Slither + SMTChecker config in `foundry.toml`. No external fuzzer, no symbolic test.
- **7** — Foundry + Slither + (Echidna OR Medusa OR Halmos) wired and runnable; nightly CI job invokes them.
- **9** — Foundry + Slither + ≥ 2 of {Echidna, Medusa, Halmos, hevm, Certora}. Differential tests exist for the most critical math library.
- **10** — Above plus a formal-verification tool (Certora / Kontrol) with at least one proved spec rule committed.

---

## FAO baseline self-evaluation (2026-05-22)

### Evidence collected

- Test files: 30 under `test/` (8252 LOC total). Test functions: 175 across the tree (244 total tests counted by `forge test --list`, of which 243 currently pass — see notes).
- Layers populated:
  - **Unit + integration**: dense. `test/EvaluationPipeline.t.sol`, `test/InstanceSale.t.sol`, `test/FAOCreateAndBond.t.sol`, `test/FAOFutarchyFactory.t.sol`, `test/FAOOfficialProposalOrchestrator.t.sol`, `test/FAOSmoke.t.sol`, `test/FAOTwapResolver.t.sol`, `test/FutarchyArbitration.t.sol`, `test/FutarchyEvaluator.t.sol`, `test/FutarchyEvaluatorIntegration.t.sol`, `test/FutarchyLiquidityManager.t.sol`, `test/FutarchyOfficialProposalOrchestrator.t.sol`, `test/FutarchyOfficialProposalSource.t.sol`, `test/FutarchyTWAPOracle.t.sol`, `test/GenericFutarchyToken.t.sol`, `test/SaleSpotSeeder.t.sol`, `test/SXArbitrationExecutionStrategy.t.sol`, `test/UniswapV3LiquidityAdapter.t.sol`.
  - **Fuzz**: zero `testFuzz_*` functions. Some `bound()` use exists, but only inside the invariant handler. Foundry's default fuzz runs (256) only apply to functions with input parameters — there are none.
  - **Invariant**: one suite at `test/FutarchyArbitration.invariants.t.sol`. Contains a handler (`FutarchyArbitrationHandler`) and two invariants: `invariant_WETH_conserved_across_actors_and_contract`, `invariant_contract_balance_equals_escrow_plus_withdrawable`. No invariant tests for the other 27 src contracts.
  - **Integration sims**: `test/integration/Phase5Simulation.t.sol`, `test/integration/Phase5ExtendedSimulation.t.sol`. Multi-contract sequences.
  - **Fork**: 8 files under `test/fork/` (e.g. `FutarchyEvaluatorFork.t.sol`, `SXArbitrationExecutionStrategyFork.t.sol`, `FutarchyLiquidityCycleFork.t.sol`, `SwaprAlgebraLiquidityAdapterFork.t.sol`). All gated by `vm.envOr("RUN_GNOSIS_FORK_TESTS", false)`. Block numbers are *not* pinned — they fork from latest, so behaviour is non-deterministic.
  - **Symbolic / formal**: none. No Halmos `testSym_*`, no SMTChecker config in `foundry.toml`, no Certora directory at the repo root, no Kontrol setup.
  - **Mutation**: none.
  - **Static analysis**: none in CI. Slither not configured.
  - **Coverage**: none in CI. `forge coverage` not invoked. `via_ir = true` requires `--ir-minimum` flag — easy to mis-wire.
  - **Gas**: none in CI. `forge snapshot` not invoked. No `.gas-snapshot` committed.
  - **Mocks**: extensive (19 mock contracts under `test/mocks/`).
  - **Adversarial agents**: `script/agents/` contains `AttackBondGrief.s.sol`, `AttackPreCreation.s.sol`, `AttackQueueStuff.s.sol`, `LegitProposer.s.sol`, plus orchestration scripts (`run_phase5.sh`, `auto_promote.sh`, `collect_metrics.py`, `poll_metrics.sh`) and a daemon under `script/daemon/`. These produce metrics CSVs documented in `script/agents/README.md`.
- CI: `.github/workflows/test.yml`:
  - Runs on push / PR / manual.
  - Pins Foundry via `foundry-rs/foundry-toolchain@v1` but **does not pin a version** — silent breakage when Foundry releases.
  - Runs `forge fmt --check`, `forge build --sizes`, `forge test -vvv`.
  - Sets `FOUNDRY_PROFILE: ci` *but there is no `[profile.ci]` block in `foundry.toml`* — silent fallthrough. The CI is effectively running the default profile.
  - No coverage, no gas snapshot, no slither, no mutation, no fork tests (env var defaults to false).
- Test stability: `forge test --no-match-path "test/fork/*"` shows **243 passing, 1 failing** (`test_adapter_cannotBeSetTwice` in `FAOOfficialProposalOrchestrator.t.sol`). The CI workflow has *no* failure suppression, so main is presumably also failing — or the test was broken on the workspace branch and not yet propagated. Either way, the prompt's claim of "57/57 passing" is out of date.

### Scores

| # | Dimension | Score | Rationale |
|---|---|---|---|
| 1 | Layer coverage | **5.5** | Unit, integration, invariant (1 file), fork (8 files, gated) present. Fuzz layer is essentially empty (`bound()` inside handler does not count). Symbolic, mutation, Echidna/Medusa all absent. Adversarial agents add a partial Layer 9 but emit no metrics on test runs. |
| 2 | Spec → check traceability | **3.5** | No `audit/research/topic-3-*.md` exists yet; no `@invariant` natspec; no `@spec` tags in tests. The 2 invariants in `FutarchyArbitration.invariants.t.sol` are well-named but not cross-referenced to any spec doc. `docs/onchain-futarchy-design.md` lists informal invariants in prose, not enumerated. |
| 3 | Mutation resistance | **3.5** | No mutation tool wired. Coverage tool not run in CI. Tests are assertion-rich (137 `vm.expectRevert/expectEmit` calls across 57 unit test files counted earlier) so the suite is probably mid-tier strong, but no objective measure exists. |
| 4 | Fork realism | **5.0** | Fork suite exists for all major boundary contracts (CTF, Swapr/Algebra, evaluator, SX execution strategy). Gated correctly with `RUN_GNOSIS_FORK_TESTS`. Two material gaps: (a) block numbers are not pinned (`vm.createSelectFork(vm.rpcUrl("gnosis"))` only — non-deterministic), (b) fork tests do not run in CI (no env var set, no nightly job). No Tenderly Virtual TestNet wiring. |
| 5 | CI gating & reproducibility | **3.5** | CI exists and runs the basic suite, but: Foundry version unpinned, `[profile.ci]` missing despite `FOUNDRY_PROFILE: ci`, no coverage/gas/mutation gates, no Slither, no nightly jobs, no determinism for fuzz/invariant seeds, no artifact upload, and there is currently a **failing test on workspace** (`test_adapter_cannotBeSetTwice`) that the workflow does not appear to catch — implying either the workflow isn't running on workspace or it's recently broken. |
| 6 | Tooling diversity | **2.5** | Foundry only. No Slither, no SMTChecker, no Halmos, no Echidna, no Certora, no Kontrol, no Vertigo, no differential tests. The single-tool risk is real for a protocol stack that includes economic-mechanism design. |
| **min** | — | **2.5** | gate dimension: Tooling diversity. |
| **average** | — | **3.9** | |

**Aggregate baseline: 2.5 / 10** (worst dimension). Average across the six is **3.9**.

This is *not* a "moderate" score — the prompt's framing was optimistic. The repo has solid unit-and-mock-based testing, a brave start on invariants, a real fork suite, and credible adversarial agents. But the gates that turn "we have tests" into "we have verified the implementation against a spec" — mutation testing, coverage gates, gas gates, static analysis, symbolic / formal verification, deterministic CI, version pinning, and Tenderly/shadow staging — are *all* missing.

---

## Top-10 testing-infra improvements (ordered by ROI)

1. **Fix CI today**: define `[profile.ci]` in `foundry.toml` with `fuzz.runs = 1024`, `invariant.runs = 256`, `invariant.depth = 64`, deterministic `seed`. Pin Foundry to a named version in the workflow (`foundry-rs/foundry-toolchain@v1` with `version: nightly-<sha>` or a stable release). Wire `forge coverage --ir-minimum --report lcov` and a 75% coverage gate. *Effort: 1 day. Impact: turns CI from cosmetic to load-bearing.*
2. **Repair the failing test**: `test_adapter_cannotBeSetTwice` in `test/FAOOfficialProposalOrchestrator.t.sol` is currently failing on workspace. Either the test is stale (mark it `vm.skip(true)` with a TODO referencing the issue) or the code regressed (fix it). A failing test on the dev branch erodes signal on every other test.
3. **Add fuzz coverage on every public/external function with parameters**. Today: zero `testFuzz_*`. Target: at least one fuzz wrapper per parameterized external in `FutarchyArbitration`, `FAOCreateAndBond`, `EvaluationPipeline`, `InstanceSale`, `SaleSpotSeeder`, `UniswapV3LiquidityAdapter`, `FAOTwapResolver`. Free signal for a few hours of work.
4. **Expand invariant testing from 1 contract to ≥ 5**. The same handler pattern in `test/FutarchyArbitration.invariants.t.sol` should be applied to `FAOCreateAndBond` (proposal-id uniqueness, mapping consistency), `EvaluationPipeline` (state-machine monotonicity, no double-resolve), `InstanceSale` (token conservation), `UniswapV3LiquidityAdapter` (deposit ↔ withdraw round-trip), and the `FAOFutarchyFactory` ↔ orchestrator combo (queue-length and graduation-threshold invariants).
5. **Pin fork-test block numbers and run them nightly**. Replace `vm.createSelectFork(vm.rpcUrl("gnosis"))` with `vm.createSelectFork(vm.rpcUrl("gnosis"), <pinned_block>)` in all 8 fork test files. Add a nightly GitHub Actions workflow that sets `RUN_GNOSIS_FORK_TESTS=true` and an `RPC_URL_GNOSIS` secret.
6. **Enable Solidity SMTChecker on `src/libraries/UniV3Math.sol`** (and any leaf math library). Add a `[profile.smtchecker]` block in `foundry.toml`; nightly CI runs `FOUNDRY_PROFILE=smtchecker forge build`. Free proof of arithmetic safety for the most-reviewed math.
7. **Wire Slither (and optionally Aderyn) into CI** as a PR gate using `crytic/slither-action@v0.4`. Configure `.slither.json` to suppress known/intentional findings. Adds a low-cost static-analysis layer.
8. **Add Halmos symbolic tests for the core arithmetic** — bond doubling rule, queue-length monotonicity, threshold computation. These are bounded-state properties that Halmos handles well. Effort: ~2 days for a usable initial harness.
9. **Set up an Echidna nightly campaign on `FutarchyArbitration`** for the same conservation and monotonicity properties as the Foundry invariant suite. Echidna's coverage-guided search complements Foundry's purely random exploration. Effort: 2–3 days.
10. **Introduce mutation testing (Vertigo) as a release-time gate** — not per-PR. Commit a baseline mutation report under `audit/evaluations/mutation-<date>.md` so the CAO loop can detect regressions over time. Add a per-file threshold (≥ 70% kill rate) for the most security-sensitive contracts: `FutarchyArbitration`, `EvaluationPipeline`, `FAOCreateAndBond`, `InstanceSale`.

A bonus eleventh, for when the project moves past testnet: **commit one Certora spec** for `FutarchyArbitration` (or the math library) and gate releases on that proof. The setup cost is real but the bug-class elimination justifies it the moment the system holds real funds.

---

## Notes for re-evaluation

- A passing run of this rubric should produce: a per-dimension score, a one-line rationale, the commands used, and the resulting file paths / counts. The evaluator should *not* re-derive the rubric or re-read this file twice.
- Improvements must be re-scored against the same anchors. The min-dimension is the gate: pushing one dimension from 9 to 10 while another stays at 4 does *not* count as progress.
- The 244-test count and 1 failing test should be re-checked on each pass — drift here is a leading indicator.

---

## Sources

- Foundry Book — https://book.getfoundry.sh/
- Foundry invariant testing guide — https://book.getfoundry.sh/forge/invariant-testing
- Foundry coverage (`--ir-minimum`) — https://book.getfoundry.sh/reference/forge/forge-coverage
- Trail of Bits, *Echidna* — https://github.com/crytic/echidna
- Trail of Bits, *Medusa* — https://github.com/crytic/medusa
- a16z crypto, *Halmos* — https://github.com/a16z/halmos
- Ethereum Foundation, *hevm* — https://github.com/ethereum/hevm
- Runtime Verification, *Kontrol* — https://docs.runtimeverification.com/kontrol
- Certora Prover docs — https://docs.certora.com
- Solidity SMTChecker — https://docs.soliditylang.org/en/latest/smtchecker.html
- Trail of Bits, *Slither* — https://github.com/crytic/slither
- Cyfrin, *Aderyn* — https://github.com/Cyfrin/aderyn
- Vertigo-rs (mutation) — https://github.com/RareSkills/vertigo-rs
- Tenderly Virtual TestNets — https://docs.tenderly.co/virtual-testnets
- `audit/research/topic-4-sc-testing-infra.md` (companion research report)
