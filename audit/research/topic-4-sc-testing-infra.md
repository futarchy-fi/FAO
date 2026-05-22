# Topic 4 — Smart-Contract Testing Infrastructure & Formal Verification

> Scope: tools, layers, processes, and CI/CD that take a Solidity codebase from "compiles" to "we can stake money on it." Topic 3 covers *what* the spec says; Topic 4 covers *how we prove the code matches it*.

---

## 1. The modern Solidity testing stack (2024–2026)

The post-Foundry generation of teams converges on a small, layered toolchain. Each tool answers a different question.

### 1.1 Concrete execution: Foundry (`forge test`)

- **Unit / integration**: `forge test`. Native EVM execution in Rust, ~10–100× faster than Hardhat. Default for every serious Solidity team since 2023.
- **Property-based fuzzing**: `function testFuzz_xxx(uint256 a, address b)` — Foundry generates random inputs, replays counter-examples. Config under `[fuzz]` in `foundry.toml` (`runs`, `max_test_rejects`, `seed`, `dictionary_weight`, `include_storage`).
- **Stateful invariant testing**: `function invariant_xxx()` + a `targetContract` / `targetSelector` handler. Foundry calls handler functions in random orders/depths and asserts invariants after each call. Config under `[invariant]` (`runs`, `depth`, `fail_on_revert`, `call_override`).
- **Coverage**: `forge coverage --report lcov` → genhtml or codecov upload. `--ir-minimum` is required when `via_ir = true` (otherwise the instrumentation breaks the optimizer).
- **Gas snapshots**: `forge snapshot --diff` for regression gates. Pairs with `forge test --gas-report` for per-function tables.
- **Forking**: `vm.createSelectFork(rpcUrl, blockNumber)` for mainnet/L2 forks. Anvil `--fork-url <rpc> --fork-block-number <n>` for local-node forks.
- **Cheatcodes for adversarial scenarios**: `vm.etch`, `vm.store`, `vm.mockCall`, `vm.expectRevert`, `vm.expectEmit`, `vm.prank`, `vm.warp`, `vm.roll`, `vm.broadcast`.

### 1.2 Coverage-guided fuzzers

- **Echidna** (Trail of Bits, Haskell). Property tests written in Solidity (`echidna_*`). Supports two campaigns: *property mode* (boolean returns) and *assertion mode* (Solidity `assert`). Coverage-guided via byte-level branch tracking. Strong at exposing arithmetic and access-control bugs but slow on large state spaces. Configured via `echidna.yaml`.
- **Medusa** (Trail of Bits, Go). Spiritual successor to Echidna. Parallel workers, JSON corpus, better integration with modern Foundry projects, can ingest Foundry tests directly. Faster than Echidna for most workloads; documentation and ecosystem maturity still trail.
- Both consume the same Solidity property syntax and can share corpus seeds with Foundry invariant suites via shrinking-friendly fixture exports.

### 1.3 Symbolic execution

- **Halmos** (a16z crypto, Python). Re-runs Foundry tests symbolically: any `testSym_foo(uint256 x)` is interpreted as "prove `∀ x` the assertion holds." Backed by Z3/cvc5. Trivial integration with existing Foundry tests; weak on loops and unbounded state.
- **hevm symbolic** (Ethereum Foundation, Haskell). The original symbolic EVM. Backed by SMTLib solvers. Supports equivalence checking between two bytecode artifacts (`hevm equivalence`) — invaluable when refactoring or porting.
- **Kontrol** (Runtime Verification, K-framework). Formal-verification grade. Heavier setup but proves theorems vs. providing counter-examples. Used by Optimism, Lido, Uniswap V4.

### 1.4 Formal verification & solver-backed checks

- **Certora Prover** (Certora). CVL spec language; the prover translates CVL rules + Solidity into SMT and proves or finds a counter-example. Industry standard for top-tier protocols (Aave, Compound, MakerDAO, Lido, Uniswap V3/V4, OpenZeppelin). Commercial; recently rolled out a free academic tier.
- **SMTChecker** (built into solc). Free, no setup. Enabled in `foundry.toml`:
  ```toml
  [profile.default.model_checker]
  contracts = { "src/MyContract.sol" = ["MyContract"] }
  engine = "chc"
  timeout = 60000
  targets = ["assert", "underflow", "overflow", "divByZero", "outOfBounds", "popEmptyArray"]
  show_unproved = true
  ```
  Verifies user-written `assert(...)` statements and arithmetic/array safety. Weak on inheritance, external calls, and complex storage; strong on pure-function arithmetic. Worth enabling on any leaf math library (e.g. `UniV3Math.sol`).
- **Solidity Coverage** model checking via `solc --model-checker-*`: same engine as SMTChecker, runs standalone.

### 1.5 Mutation testing

- **Vertigo-rs** (Joran Honig, Trail of Bits successor). Rust rewrite of Vertigo. Generates mutants (e.g. `>` → `>=`, `+` → `-`, delete `require`) and re-runs the Foundry suite. A "surviving mutant" = a test gap. Output: per-file mutation score = killed / total mutants.
- **SuMo** (academic, Polimi). Higher mutant variety, slower. Less commonly used in production today.
- **Gambit** (Certora). Lightweight, integrates with `certora-cli`; designed for CVL specs but works on Solidity bytecode.
- **necessary discipline**: mutation testing converts coverage from a vanity metric into a meaningful one. 100% line coverage with 30% mutation score = useless tests.

### 1.6 Static analysis (testing-adjacent, not a substitute)

- **Slither** (Trail of Bits). 80+ detectors. Run on every PR. Cheap.
- **Aderyn** (Cyfrin, Rust). Newer, faster, better-formatted output. Increasingly the default.
- **4naly3er** (Picodes). Gas-optimization checks; useful for snapshot gates.
- **Mythril** / **Manticore**: symbolic, but largely superseded by Halmos/hevm for modern Solidity.

### 1.7 Differential & equivalence testing

- **hevm equivalence**: prove two bytecodes are observationally equivalent.
- **Foundry differential tests**: deploy two implementations, fuzz both, assert outputs match. Standard for replacing legacy contracts (e.g. an `via_ir` rewrite of a hot-path library).
- **`forge bind`** + property tests in Rust: catch ABI drift.

---

## 2. The layered testing pyramid

A protocol-grade test repo is *not* a flat list of `*.t.sol` files. It's a stack where each layer catches what cheaper layers miss.

| Layer | Tool | Question answered | Cost | Catches |
|---|---|---|---|---|
| 1. Unit | `forge test` | "Does this function do what its docstring says?" | Cheap, fast | Logic errors, off-by-one, wrong storage slot |
| 2. Integration | `forge test` w/ mocks | "Do these contracts compose correctly?" | Cheap | Interface mismatches, event wiring, role/permission glue |
| 3. Property / fuzz | `forge test --match-test testFuzz_*` | "Does property P hold over the input space?" | Medium | Bad assumptions, edge cases at boundaries |
| 4. Stateful invariant | `forge test --match-contract *Invariant*` | "Does invariant I hold across any sequence of calls?" | Medium | Reentrancy, state corruption, conservation violations |
| 5. Coverage-guided fuzz | Echidna / Medusa | "Will a smart fuzzer find a sequence that breaks I?" | Medium | What Foundry's random fuzzer misses — coverage gaps |
| 6. Symbolic | Halmos / hevm | "Does P hold for **all** inputs in this bounded region?" | High setup, low marginal | Adversarial inputs no random search will find |
| 7. Formal proof | Certora / Kontrol / SMTChecker | "Is the theorem **provably** true under the spec?" | Highest | Whole classes of bugs ruled out |
| 8. Fork tests | `forge test` w/ `vm.createSelectFork` | "Does it work against real-world state?" | Medium | Integration drift, mainnet quirks, oracle stalls |
| 9. Chaos / adversarial | scripts + Tenderly / Anvil | "Does it survive multi-actor adversarial scenarios?" | High | Economic / MEV / griefing attacks |
| 10. Mainnet shadow | Tenderly Virtual TestNets, Flashbots simulation | "Does this transaction succeed against current mainnet state?" | High | Last-mile drift; pre-deployment safety net |

Skipping a layer is acceptable; what's not acceptable is *not knowing* which layer you skipped.

### 2.1 Where each layer pays off

- **Layers 1–2** are necessary; insufficient for anything past hello-world.
- **Layer 3 (fuzz)** is the *highest-ROI investment* below formal-verification. A Foundry fuzz suite with a few thousand `runs` will catch the majority of arithmetic and boundary bugs that unit tests miss. Cost: minutes of CI per run.
- **Layer 4 (invariant)** is where economic-mechanism protocols (futarchy, AMMs, lending) catch their hardest bugs. Conservation invariants (`sum(balances) == totalSupply`) and monotonicity invariants (`debt ≥ 0`) belong here.
- **Layer 5 (Echidna/Medusa)** pays off when (a) the state space is large enough that Foundry's coin-flip path explorer plateaus, or (b) you need byte-level coverage feedback. Often deployed as a *long-running CI job* (hours, not seconds).
- **Layer 6–7 (symbolic / formal)** is where the bug-class story shifts from "we tested" to "we proved." Cost-justifiable for code holding ≥ low millions of $ or for libraries reused by many contracts.
- **Layer 8 (fork)** is mandatory if you integrate with external protocols. Mocks lie; mainnet state doesn't.
- **Layer 9 (chaos)** is the futarchy-specific edge: multi-agent adversarial loops on a testnet, with metrics collection. Best run as a long-running daemon, not a single `forge test` run.

---

## 3. CI / CD integration

### 3.1 The reference CI matrix

A protocol-grade `.github/workflows/test.yml` runs, on every PR:

1. **`forge fmt --check`** — style gate, ~1 s.
2. **`forge build --sizes`** — fails if any contract exceeds the 24 KB EIP-170 limit.
3. **`forge test --no-match-path 'test/fork/*' -vvv`** — unit/integration/fuzz/invariant on mocks. ~30 s – 5 min.
4. **`forge coverage --ir-minimum --report lcov`** + Codecov upload + a coverage gate (e.g. fail if line coverage drops > 0.5%).
5. **`forge snapshot --check`** — fails if gas regressed beyond a per-test tolerance. The committed `.gas-snapshot` is the regression baseline.
6. **Slither** (`crytic/slither-action@v0.3`). Fail on any new high/medium finding.
7. **Halmos** symbolic checks (if any `testSym_*` tests exist). Often a separate workflow on `pull_request`.
8. **Echidna / Medusa** long-fuzz job — usually a *nightly* workflow, not a PR gate, because runtime is in hours.
9. **Mutation testing** (Vertigo / SuMo) — *nightly* or per-release. PR gate is too slow; release gate forces the team to address falling mutation scores.
10. **Fork tests** — gated behind a secret RPC URL and a `RUN_FORK_TESTS=true` env var (so PRs from forks don't burn the API quota). Run on `push` to main and on a `workflow_dispatch`.

### 3.2 What makes CI usable for evaluators

- **Reproducibility**: pin Foundry version (`foundry-rs/foundry-toolchain@v1` with `version: nightly-<sha>`). Pin solc via `solc_version` in `foundry.toml`.
- **Speed**: cache `forge` builds (`Cargo.lock` + `lib/**/foundry.lock`). Tier work into PR-fast vs nightly-thorough.
- **Determinism**: pin `[fuzz].seed` and `[invariant].seed` for PR runs. Use random seeds for nightly to surface new behaviour.
- **Observability**: upload `forge test --json` to GitHub Actions artifacts. CAO-style evaluators can read these without rerunning the suite.
- **Gates that block merges**: coverage gate, gas snapshot gate, mutation score gate (release-time), Slither high-severity gate.

### 3.3 Toolchain pinning anti-patterns

- Using `foundry-rs/foundry-toolchain@v1` without `version:` → silent breakage when Foundry releases.
- `via_ir = true` + `forge coverage` *without* `--ir-minimum` → instrumentation breaks compilation; tests look "covered" because they don't run.
- `FOUNDRY_PROFILE = ci` env var without a `[profile.ci]` section in `foundry.toml` → silent fallthrough to default profile; the CI thinks it's using stricter settings but isn't. (This is the FAO bug today.)

---

## 4. Testnet vs mainnet-fork parity

### 4.1 What mocks miss

Mocks lie about: gas costs, return-data sizing, callback timing, oracle freshness, MEV ordering, real-token transfer semantics (USDT's missing return value, rebasing tokens, fee-on-transfer), upstream protocol upgrades, and any storage layout you didn't bother to emulate.

A mock-only suite gives ~30–50% confidence in real behaviour. The remainder requires fork testing.

### 4.2 Fork-test tooling

- **Anvil `--fork-url`** — local node forked from a remote RPC. Cached responses make iteration fast. Pin the block: `--fork-block-number`. State persists across runs with `--state` flag.
- **Foundry `vm.createSelectFork(url, block)`** — per-test fork. Combine with `vm.rollFork(block)` for time-of-day testing.
- **Tenderly Virtual TestNets** — hosted, durable, chain-state-sharable. The right tool for staging environments (the team and integrators all see the same state). Supports forks of any EVM chain, with admin RPC for state injection.
- **Tenderly DevNets / state overrides** — for testing "what if this proposal passed" scenarios.

### 4.3 Reference pattern

```solidity
function setUp() public {
    if (!vm.envOr("RUN_FORK_TESTS", false)) return;   // skip locally
    vm.createSelectFork(vm.rpcUrl("mainnet"), 18_500_000);
}
```

Pinning the block is non-negotiable: otherwise the suite is non-deterministic and CI flakes silently.

### 4.4 Mainnet shadow / dry-run

For *deployment* parity, the gold standard today is:

1. Bundle the deployment transactions with `forge script --rpc-url <fork>`.
2. Replay against a Tenderly Virtual TestNet identical to mainnet.
3. Run a smoke-test suite against the Tenderly fork.
4. *Then* `--broadcast` to real mainnet.

For *individual* user transactions, Flashbots `eth_callBundle` + Tenderly simulation give you the same dry-run path.

---

## 5. How top protocols structure their test repos

Lessons taken from public repositories and audit reports (sources at end).

### 5.1 Aave V3 (`aave-v3-core`, `aave-v3-origin`)

- Massive Foundry suite (~hundreds of unit tests) + Certora proofs in `certora/`.
- Property tests for: reserve normalised income monotonicity, share-mint conservation, liquidation health-factor monotonicity.
- Fork tests against every supported L2; gated behind per-network RPC env vars.
- Mutation testing (Gambit) for the core math library.
- Echidna campaigns for the rate strategy contracts.

### 5.2 MakerDAO / Sky Protocol

- Dual-tool ethos: Foundry tests *and* Certora specs for every system contract.
- "End-to-end live testing" — fork mainnet, simulate a governance executive, assert post-conditions.
- Custom fuzzing harnesses (Hevm) for the DSS (Dai Stablecoin System) core.
- `dapp-deps-pin` tooling for reproducible dependency resolution.

### 5.3 Uniswap V3 / V4

- V3: Hardhat-based originally, ported to Foundry. Heavy property-test suite for `TickMath`, `SqrtPriceMath`.
- V4: Kontrol formal-verification spec for hooks and the singleton. Halmos symbolic tests for pool-key uniqueness. Echidna for swap-invariant testing.
- Test repo includes "scenario tests" — long sequences modelling realistic LP/swap workloads.

### 5.4 Yearn V3

- Foundry-based. Strong invariant test suite (every strategy ships with its own `invariant_*` file).
- Mutation testing via Vertigo on the core vault contracts.
- Fork-based "yearn-strategy-template" repo enforces a minimum invariant set for any new strategy.

### 5.5 EigenLayer

- Multi-tool: Foundry, Halmos (symbolic), Certora (formal), Echidna (long-run fuzz).
- Public Certora reports; specs in `certora/specs/`.
- Heavy use of "stake-delegation" invariants (sum of delegated stake = total restaked).
- Audit competitions on Sherlock / Cantina supplement internal testing.

### 5.6 Common patterns

- **`test/` is structured by layer**, not by source file: `test/unit/`, `test/integration/`, `test/invariant/`, `test/fork/`.
- **`certora/`** or `formal/` at the repo root, with `specs/*.spec` and a `Makefile` or `scripts/run.sh` to invoke the prover.
- **`audit/`** or `audits/` with PDFs of every prior audit; helps reviewers understand which bug classes are already closed.
- **Per-PR**: fast layer (forge test + Slither + coverage).
- **Nightly**: heavy layer (Echidna + Certora + mutation testing + long fork sequences).
- **Per-release**: full layer (everything, plus deployment-script dry-run on Tenderly).

---

## 6. ROI: what to invest in, what's overkill

### 6.1 For a testnet-stage futarchy project (FAO today)

| Investment | Cost (eng-days) | ROI tier |
|---|---|---|
| Add a `[profile.ci]` block and pin fuzz/invariant runs | 0.5 | **S** — fixes a silent CI bug today |
| `forge coverage --ir-minimum` with a 70%/85% gate | 1 | **S** — meaningful coverage signal |
| `forge snapshot --check` in CI | 0.5 | **A** — catches gas regressions cheaply |
| Slither in CI | 0.5 | **A** — free bug detector |
| Expand invariant tests to 4–6 contracts (currently only FutarchyArbitration) | 5 | **S** — best signal-to-effort ratio for this protocol class |
| Add a Foundry differential test for `UniV3Math.sol` vs the official Uniswap V3 implementation | 2 | **A** — math library has no external check today |
| Echidna campaign on `FutarchyArbitration` (nightly) | 3 | **A** — economic invariants matter for bond/queue logic |
| Halmos `testSym_*` on the core arithmetic | 2 | **B** — quick wins where state space is bounded |
| SMTChecker on leaf math libraries | 1 | **B** — free, just turn it on |
| Mutation testing (Vertigo) baseline | 2 | **B** — confirms tests are not vacuous |
| Certora spec + prover | 30+ | **C** for testnet; **S** for mainnet |
| Tenderly Virtual TestNet for staging | 1 | **A** — better than Sepolia for parity |
| Mainnet shadow deployment in CI | 5 | **B** for testnet; **S** for mainnet release |

### 6.2 Diminishing returns to know about

- **Multiple symbolic tools in parallel**: Halmos + hevm + Kontrol on the same code is mostly redundant unless solver bugs are a concern.
- **100% line coverage**: a vanity target; aim for ≥ 90% on `src/`, but pair with ≥ 80% mutation score on the same files. Coverage *without* mutation is a lie.
- **Fork tests for every contract**: only the boundary contracts (anything interacting with Uniswap, Algebra, Reality.eth, CTF, WETH on Gnosis) benefit. Internal logic should be on mocks.
- **Adversarial agents that test happy-path behaviour**: the agent suite under `script/agents/` is high-ROI *only* if it produces metrics that detect regressions. Otherwise it's a demo.

### 6.3 The futarchy-specific high-leverage layer

Bond / queue / settlement protocols have a specific set of invariants that *cannot* be expressed cleanly in a unit test but are trivial in an invariant test:

- Conservation: `sum(actor.balanceOf) + contract.balanceOf == initialSupply` (FAO has this — extend to all bond contracts).
- Monotonicity: `withdrawable[a]` never decreases except by an explicit `withdraw` call.
- Queue boundedness: `queueLen() ≤ MAX_QUEUE` after any sequence of `placeYesBond` calls.
- Doubling rule: `requiredYes(n+1) == 2 * requiredYes(n)` over the queue length.
- Evaluation atomicity: exactly one of `{ACCEPTED, REJECTED, EVALUATING, INACTIVE, ESCROW}` is true for any proposal at any time.

These are the **highest-ROI** invariants because they're cheap to write, hard to violate accidentally, and would catch real bugs (the kind that ship in mainnet deployments and end up in post-mortems).

---

## 7. Implications for the CAO rubric

The rubric in `audit/rubrics/topic-4-sc-testing-infra.md` is structured around these dimensions:

1. **Layer coverage** — does the suite span unit → fuzz → invariant → symbolic → fork?
2. **Spec → check traceability** — for each invariant in the spec (Topic 3), is there a named test that checks it?
3. **Mutation resistance** — do the tests actually catch deliberate mutations? (Vertigo score.)
4. **Fork realism** — is real upstream state exercised, or only mocks?
5. **CI gating & reproducibility** — is the suite a merge gate, deterministic, and pin-versioned?
6. **Tooling diversity** — does the project depend on Foundry alone, or layer in coverage-guided fuzz + symbolic + formal?

Topic 4's scoring is independent from Topic 3 (the spec) but consumes it: a perfect Topic-4 score against a non-existent spec means "we wrote a lot of tests for whatever the code happens to do."

---

## Sources

- Foundry Book — https://book.getfoundry.sh/ (fuzz, invariant, coverage, forking, gas, cheatcodes)
- Trail of Bits, *Echidna* — https://github.com/crytic/echidna
- Trail of Bits, *Medusa* — https://github.com/crytic/medusa
- a16z crypto, *Halmos* — https://github.com/a16z/halmos
- Ethereum Foundation, *hevm* — https://github.com/ethereum/hevm
- Runtime Verification, *Kontrol* — https://docs.runtimeverification.com/kontrol
- Certora Prover — https://docs.certora.com
- Solidity SMTChecker — https://docs.soliditylang.org/en/latest/smtchecker.html
- Trail of Bits, *Slither* — https://github.com/crytic/slither
- Cyfrin, *Aderyn* — https://github.com/Cyfrin/aderyn
- Joran Honig, *Vertigo-rs* (mutation testing) — https://github.com/RareSkills/vertigo-rs (and the original Vertigo at https://github.com/JoranHonig/vertigo)
- Certora, *Gambit* (mutation) — https://github.com/Certora/gambit
- Tenderly Virtual TestNets — https://docs.tenderly.co/virtual-testnets
- Aave V3 audit and test repos — https://github.com/aave-dao/aave-v3-origin, https://github.com/aave/aave-v3-core
- MakerDAO / Sky Protocol — https://github.com/makerdao/dss, https://github.com/sky-ecosystem
- Uniswap V4 Certora & Kontrol artifacts — https://github.com/Uniswap/v4-core/tree/main/certora
- Yearn V3 — https://github.com/yearn/tokenized-strategy
- EigenLayer Certora — https://github.com/Layr-Labs/eigenlayer-contracts/tree/main/certora
- OpenZeppelin formal-verification workflow — https://github.com/OpenZeppelin/openzeppelin-contracts/tree/master/certora
- Consensys Diligence, *fuzzing best practices* — https://consensys.io/diligence/blog/2020/11/secureum-bootcamp-solidity-201-quiz-detailed-solutions/ (and the Secureum testing module)
- Trail of Bits, *Building Secure Contracts* — https://github.com/crytic/building-secure-contracts/tree/master/program-analysis
