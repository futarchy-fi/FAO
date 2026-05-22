# Topic 5 — Holistic Best Patterns: Smart Contracts + Interfaces (Security + Maintainability)

This is the *meta* rubric for the CAO loop. It pulls threads from topics 1–4
(UX, end-to-end testing, formal-spec readiness, on-chain test infrastructure)
and asks whether the *aggregate* product — the smart-contract suite, the
interface, the docs, and the operator surface — behaves as one coherent,
maintainable system. The goal is to detect not just whether each layer is
good in isolation but whether the **seams** are clean: SC ↔ UI, code ↔
deploy-artefact, code ↔ docs, repo ↔ operator runbook, repo ↔ third-party
supply chain.

---

## 1. Architectural patterns observed across mature DeFi protocols

### 1.1 Monorepo vs. multirepo

Two stable patterns dominate:

- **Monorepo (Uniswap v3/v4, Aave v3, Maker endgame, Compound v3, Seer,
  RealityETH, futarchy-fi/FAO).** Contracts, scripts, interface(s),
  subgraph/indexer config, and docs live in one repo. Strength: one
  bisectable history; deploy artefacts and the UI commit hash are reviewed
  together; refactors are atomic. Weakness: needs strict directory
  discipline so the UI doesn't end up importing test fixtures or operator
  secrets, and so `lib/` git-submodules don't bloat the cone the UI
  toolchain has to traverse.
- **Multirepo (1inch, Optimism, Arbitrum: protocol vs. interface vs. SDK
  split; older Yearn).** Each layer ships independently. Strength: small
  blast radius per release; UI can be rebuilt without re-auditing Solidity.
  Weakness: cross-repo drift — UI hardcodes an address that the next
  contract release silently invalidates.

Best practice in 2025 is *monorepo with sub-package release pipelines*: a
single git history but separate publish/build channels. Uniswap publishes
`v4-core`, `v4-periphery`, `universal-router`, and `v3-sdk` from one repo;
Aave V3 ships `aave-v3-core`, `aave-v3-periphery`, and the React UI from
distinct packages but reviewable PRs touch all of them at once.

### 1.2 Contracts ↔ frontend coupling and the "ABI-as-product" pattern

The healthiest projects treat the **ABI + deployment manifest** as a first-
class published artefact:

1. CI runs `forge build` (or hardhat compile) and emits an `abi/` directory
   plus a `deployments/<chainId>.json` containing
   `{name, address, deployTx, deployBlock, version, owner, ABI ref}`. Tools:
   Foundry's `forge inspect` and `forge script --json`; Hardhat's
   `hardhat-deploy` plugin (`deployments/`); OpenZeppelin Defender export.
2. The frontend imports the manifest **and** the ABI as *generated* code
   (TypeChain, wagmi-cli, viem `getContract`, abitype). The same JSON is
   what the docs site and the operator daemon read.
3. Hardcoded addresses in `*.js` / `*.tsx` are an anti-pattern. They survive
   only as a last-resort bootstrap before the manifest finishes loading.
4. Version bumps to contracts produce a new manifest entry; the UI's only
   change is bumping a pinned manifest version (often via `package.json` or
   a `deployments.json` checksum). This is what makes "v3 → v4 → v5"
   transitions painless on the UI side.

### 1.3 Deploy-artefact propagation

Mature flow:

```
forge script Deploy.s.sol --broadcast
  → broadcast/<script>/<chainId>/run-latest.json  (foundry artefact)
  → script post-step writes deployments/<chainId>/<name>.json
  → CI commits the manifest update on a release tag
  → UI / docs / daemon read the manifest at build time
  → frontend rebuild auto-deploys via Vercel/Cloudflare Pages
```

The crucial step is the *post-step that promotes the broadcast artefact
into a tracked manifest*. Without it, `broadcast/` is a write-once log
that never feeds the rest of the system, and addresses get retyped into
JS by hand — exactly the failure mode topic 5 is meant to catch.

---

## 2. Security hygiene

### 2.1 Upgradability vs. immutability

The 2020-era "upgrade everything via proxy" school has been displaced by a
*selective immutability* doctrine. Live examples:

- **Uniswap v3/v4, Curve, Liquity v2:** core math is fully immutable; new
  versions ship as new contracts; users opt in by routing.
- **Aave v3, Maker, Lido:** proxied for the manager/governance shell, but
  the math libraries and oracles are immutable.
- **Compound v3 (Comet):** an immutable per-market contract; new markets
  are new deployments.

Pattern: **prefer immutability for math + state, isolate upgradability to
the thinnest possible shell that *can* be paused/migrated by governance,
and require time-locked governance for any address change.**

When a contract is immutable, the migration story (v3 → v4 → v5) is
explicit redeploy + frontend repoint — which is fine if (a) the old version
is *visibly* marked deprecated everywhere and (b) liquidity migration paths
exist or are explicitly disclaimed.

### 2.2 Admin-key risk

Standard playbook:

- **OZ `AccessControl` with `DEFAULT_ADMIN_ROLE` granted to an OZ
  `TimelockController`** owned by a Safe multisig (e.g. 3-of-5).
- Time-lock delays: 48h is the post-Tornado community norm for high-impact
  actions (treasury withdrawal, role grant, address rotation). 24h for
  parameter tweaks. <1h delays are red flags.
- *No EOA* ever holds `DEFAULT_ADMIN_ROLE` in production.
- Roles are *separated*: `MINTER_ROLE`, `PAUSER_ROLE`, `WITHDRAWER_ROLE`,
  each granted to potentially different multisigs.
- The frontend / etherscan-published "owner" view should match a Safe
  address — anything else (an EOA, a private key file) is documented as a
  testnet-only configuration.

### 2.3 Time-locks and multisig discipline

A Safe multisig without a Timelock is *necessary but not sufficient* — a
3-of-5 can still rug at t=0. The combination Safe → Timelock → contract is
the de-facto standard. Tooling:

- Safe Tx Builder / Safe Wallet UI for the proposer
- OZ Defender / Tenderly for tx simulation
- A public `/governance` page on the docs site listing every pending
  Timelock action with eta + decoded calldata.

### 2.4 Supply chain (npm, foundry libs, CDN)

Risks observed in 2024–2026 supply-chain incidents (event-stream, ua-parser,
Solidity Compiler typo-squats):

- **Foundry `lib/`** is git-submodule based, so each upstream is pinned by
  commit SHA in `.gitmodules` — strictly safer than npm "latest" tags, but
  still requires periodic upgrade discipline and CVE monitoring.
- **OpenZeppelin Contracts** is the de-facto base; mature projects pin a
  specific tag (`v4.9.6`, `v5.0.2`) and `forge update`-with-PR-review
  rather than letting Dependabot autobump.
- **Frontend ethers/viem CDN**: loading `https://cdn.jsdelivr.net/npm/
  ethers@6.13.2/dist/ethers.umd.min.js` without an SRI integrity hash is a
  silent supply-chain attack vector. Either self-host or include
  `integrity="sha384-..."`.
- **Vendored libs** (`reality-eth-monorepo`, `seer-demo`, `sx-evm`,
  `conditional-tokens-contracts`) should have a `VENDORED.md` recording the
  upstream URL, the pinned commit, and the reason for vendoring. This is a
  pattern FAO already partially uses.

---

## 3. Maintainability

### 3.1 Docs ↔ code freshness

Indicators a doc is stale:

- It references a file path or function name that no longer exists
  (`registry.js` after the file was renamed to `shared.js`).
- It pins addresses that no longer match the addresses the running code
  uses (a `vX deployment` doc that lags behind a `vY` redeploy).
- It uses version words ("v2", "v3", "v5") that diverge from each other
  across the same surface (a contracts page saying "v3" while the JS uses
  the "v5" registry).
- Phase trackers / status sections are dated and never re-dated.

Best-practice fix: make docs **generated wherever possible** (TypeDoc,
forge-doc, dockerized doc-build CI) and **dated** elsewhere, with a "last
verified" line per address table.

### 3.2 Deprecation discipline (v2/v3/v4/v5)

When a contract version is superseded:

1. The old deploy is moved into a `legacy/` or `archive/` section of
   `deployments/<chain>/` with `deprecated: true` + `replaced_by:
   <addr>` + `deprecated_at: <ts>` in the manifest.
2. The UI either hides deprecated instances or shows them in a "Legacy"
   panel with a clear migration CTA.
3. The deploy script for the old version is moved to
   `script/legacy/` or annotated `@deprecated` so a new operator doesn't
   accidentally run it.
4. The corresponding test file is either kept passing against the old
   bytecode (locked in `test/legacy/`) or explicitly removed; **never** left
   as `*.t.sol.todo-v3` because that's neither a working test nor an
   archive.
5. Operator scripts (cron, daemons) are repointed in the same PR that
   deploys the new version. The PR description lists every address-change
   call-site.

### 3.3 Backwards-compat strategies

For immutable contracts there are three:

- **Hard cutover** (Uniswap v2 → v3 → v4): old version stays live; UI is
  repointed; LPs migrate manually. Simplest. Risk: liquidity stuck on old
  pools if not signposted.
- **Reader compatibility** (Maker MCD): the new system exposes a thin
  read-shim that mimics the old interface so downstream integrations
  (Etherscan dashboards, Dune queries) keep working.
- **Atomic migration** (Aave v3 migration tool, Compound v3 migrator):
  one-tx user-driven move of position + collateral.

For FAO-style instance-registry contracts, the cleanest cutover is
*registry-versioned* — each new registry knows the previous registry's
address and can return a merged view, so the UI only needs one
"`currentRegistry`" pointer. The `FutarchyRegistry` design moves in that
direction by versioning the struct layout but doesn't expose
predecessor-cross-reads.

---

## 4. Operator surface

A futarchy stack has an *unusually rich* operator surface because the
mechanism includes off-chain daemons (promote daemon, resolve daemon,
metric collectors). What "good" looks like:

- **Keys**: operator EOAs hold gas-only, no admin role. Admin role lives
  on a Safe + Timelock. Operator key rotation procedure is a one-page
  runbook with a `cast` command.
- **Automation**: every daemon has (a) a single env-var config file with
  documented defaults, (b) crash-resilient retry, (c) idempotent reads,
  (d) a non-zero exit code on any unhandled failure so a supervisor
  (systemd, k8s, simple cron) can restart it, (e) `--dry-run` mode.
- **Monitoring**: heartbeat metric (last successful loop iteration ts)
  emitted to a file *and* a public endpoint; Prometheus or Grafana Cloud
  scrape; on-chain `lastSeen` events let any observer see the daemon is
  alive without ingress to the operator network.
- **Alerting**: balance below threshold, last successful resolve > N
  hours, bond escalation in queue > N items, gas-price > N gwei — each
  with a documented response (top up, manual intervention, page).
- **Runbooks**: under `docs/operations/`, one file per recurring task
  (deploy a new instance, rotate operator key, pause sale, respond to
  paused chain). Each runbook ends with a "test plan" so the runbook
  itself is exercised regularly.

The FAO repo today has the *shape* of this — `script/agents/` includes
`auto_promote.sh`, `run_phase5.sh`, `collect_metrics.py`, `poll_metrics.sh`,
and the design notes in `docs/onchain-futarchy-design.md` §3.4 plus
`script/daemon/submit.py` — but the address constants drift between
header comments and runtime defaults (see §6 below), there is no
heartbeat metric, no key-rotation runbook, and no alerting wiring.

---

## 5. SC ↔ UI handoff: the gold standard

A mature DeFi project's SC ↔ UI seam looks like this:

1. **Single source of truth for addresses.** A canonical
   `deployments/<chain>.json` lives in the repo, generated by the deploy
   script, version-bumped per release, and read by:
   - the UI (at build time or fetch time)
   - the docs site (a table generated from the same JSON)
   - the operator daemon (env vars derived from JSON)
   - Etherscan verification scripts.
2. **Generated ABI types.** `typechain` / `wagmi-cli` / `viem getContract`
   produces typed bindings at build time. No hand-edited `const ABI = [...]`
   arrays. This is what catches "did you rename a function" before the UI
   even loads.
3. **Env-driven configuration.** The frontend reads
   `NEXT_PUBLIC_REGISTRY_ADDR` (or equivalent) at build time; toggling a
   network is one env-var change in CI, not a code edit.
4. **Chain-aware UI.** The UI explicitly knows which chain it's pointed at,
   shows a banner when the user is on the wrong chain, and refuses writes
   when mismatched. Read paths fall back to an unauthenticated RPC if the
   wallet provider isn't ready.
5. **Pre-confirmation simulation.** Before MetaMask popup, the UI simulates
   the tx (`eth_call` with state) and displays the decoded effect — the
   pattern FAO already implements in `site-testnet/sale.js`
   (pre-confirmation card).

The anti-patterns: addresses scattered across 6 JS files in plain string
literals; ABI fragments copy-pasted with subtly different signatures (e.g.
one file says `function instances(uint256) returns (tuple(name,
symbol,...))` and another says the same tuple with a different field
order); the docs page listing a different version of the registry than
the JS uses.

---

## 6. Entropy detectors

The CAO evaluator needs *cheap, deterministic* checks for entropy. Useful
heuristics:

- **Address-set diff**: `grep -ohE '0x[a-fA-F0-9]{40}' site/ docs/ script/`
  collapsed to a set per directory. An address that lives in JS but not in
  docs/contracts.html, or vice versa, is drift. (In FAO today: v5 registry
  `0x18D1f4e57412b48436C7825B9018437C235bBC5C` lives in
  `site-testnet/shared.js`, but `site-testnet/contracts.html` displays
  "FutarchyRegistry (v3)" `0x45F1F8Bb80539cddFfB945dBe4C53A65d98296C0`.)
- **Version-word inventory**: `grep -ohE '\bv[0-9]\b'` across `src/`,
  `docs/`, `site*/`, `script/`. Histogram by directory. If any directory's
  modal version differs from another's, drift.
- **Path references that don't exist**: parse every backticked path in
  `*.md` files; for each, check it exists on disk. (FAO:
  `site-testnet/README.md` describes a `registry.js` file that was renamed
  to `shared.js`.)
- **TODO/FIXME/`.todo` files**: count and locate. A `.t.sol.todo-v3` file
  is both "test exists" and "test broken" — guaranteed drift.
- **Dead deploy scripts**: scripts in `script/` whose script name encodes
  a version (e.g. `DeployFutarchyRegistryV3.s.sol`) when a newer version is
  in use; their `broadcast/` dirs are write-once and never read again.
- **Hand-written ABI fragments**: count `const .*_ABI = \[` literals in
  JS; any > 0 is a candidate for code-generation.
- **Header-vs-code defaults**: in shell scripts, every env-var default
  listed in the header comment must equal the corresponding `:` default
  in the body. (FAO: `script/agents/auto_promote.sh` header lists
  `FUTARCHY_FACTORY default 0xc315...` but the body defaults to
  `0x208d...`.)
- **Last commit touch per file vs. last commit touch of the file it
  references**: a docs file last touched two months before the contract
  it references was redeployed is suspect.

These should be cheap enough to run on every CAO pass without breaking
the loop budget.

---

## 7. How this rubric integrates topics 1–4

| Topic | What it scores | Holistic dependency captured in topic 5 |
|---|---|---|
| 1 | Interface UX / minimalism / architecture | If UX is < 5, holistic "maintainability" is capped (a beautiful UI on stale contracts is still drift) |
| 2 | Interface testing + user flows | If E2E coverage is < 5, holistic "deprecation hygiene" is capped (no tests = no proof old paths still work) |
| 3 | Formal-spec readiness | If spec readiness is < 5, holistic "security posture" is capped (no spec = no contract-of-contract for upgrades) |
| 4 | SC testing infra + formal verification | If SC test coverage is < 5, holistic "security posture" is capped (no fuzz/invariants = no defense-in-depth) |

The rubric file (`topic-5-holistic-architecture.md` in `rubrics/`) makes
these dependencies explicit per-dimension. The evaluator is required to
read topics 1–4 scores from the latest evaluation and apply the caps before
emitting topic-5 scores.

---

## Sources

- Uniswap Labs, `Uniswap-v3-core` and `v4-core` repos (monorepo + ABI-as-
  product layout): https://github.com/Uniswap/v3-core, https://github.com/
  Uniswap/v4-core
- Aave V3, `aave-v3-core` and `aave-v3-deploy` (deploy-artefact propagation
  + sub-package releases): https://github.com/aave/aave-v3-core
- OpenZeppelin Contracts, `AccessControl` + `TimelockController` (admin-key
  + time-lock norms): https://docs.openzeppelin.com/contracts/5.x/access-
  control
- OpenZeppelin Defender, "Transaction Proposal + Timelock" pattern docs:
  https://docs.openzeppelin.com/defender/
- Foundry Book, `forge script` broadcast artefact + remappings:
  https://book.getfoundry.sh/forge/scripts and `.gitmodules` discipline.
- Trail of Bits, *Building Secure Smart Contracts* (multisig + time-lock
  norms, supply-chain hygiene): https://github.com/trailofbits/building-
  secure-contracts
- Samczsun + Spearbit, post-Tornado-Cash governance hygiene write-ups
  (48h time-lock norm).
- Curve Finance, `curve-contract` immutability + redeploy migration
  pattern: https://github.com/curvefi
- Lido, `core` repo + governance-portal-template (public Timelock queue
  pattern): https://github.com/lidofinance
- 1inch, separate `1inch-contract` vs. `1inch-app` repos as a multirepo
  case study.
- TypeChain & wagmi-cli docs (generated ABI bindings): https://wagmi.sh/
  cli/getting-started
- abitype docs (typed ABI inference): https://abitype.dev
- Safe (Gnosis) developer docs, "Safe + Timelock" pattern:
  https://docs.safe.global
- SubResource Integrity spec (SRI hashing for CDN assets):
  https://www.w3.org/TR/SRI/
- Tenderly Web3 Gateway + simulation API (pre-confirmation simulation).
- `futarchy-fi/FAO` repo, especially:
  - `src/FutarchyRegistry.sol` (v5 with derived `sqrtPriceX96`)
  - `src/FAOSale.sol` (AccessControl + Timelock pattern)
  - `script/agents/auto_promote.sh` (operator daemon)
  - `script/daemon/submit.py` (Flashbots-multi-builder daemon scaffold)
  - `docs/sepolia-deployment-v0.md` (address manifest as markdown)
  - `docs/onchain-futarchy-design.md` (threat model)
  - `site-testnet/shared.js` (registry address as JS constant)
  - `site-testnet/contracts.html` (the rendered contract page that diverges
    from the JS).
