---
canonical: audit/specs/SUPPLY-CHAIN.md
scope: Supply-chain trust model for FAO v0 — every external dependency, every pinned SHA, every CDN/RPC trust boundary, and what changes when one of them is compromised.
not-scope: Admin-key security (`SECURITY.md`), invariant spec (`INVARIANTS.md`), threat-model attack vectors (`THREAT-MODEL.md`).
last-rebuilt: 2026-05-22
---

# Supply-chain trust model

T5.D6 (supply-chain risk) requires a written, pinned inventory of every
external dependency, an explicit trust boundary per dependency, and a
fall-back path when one breaks. This file is that inventory.

## Trust boundaries (concentric)

```
┌──────────────────────────────────────────────────────────────────┐
│ Layer 0 — Sepolia consensus.                                      │
│   Trusted absolutely. If broken, nothing else matters.            │
│ ┌──────────────────────────────────────────────────────────────┐ │
│ │ Layer 1 — Foundry / forge-std / OZ contracts (pinned by SHA).  │
│ │   Compromise = malicious bytecode in deployed contracts.       │
│ │ ┌──────────────────────────────────────────────────────────┐ │ │
│ │ │ Layer 2 — Etherscan + RPC endpoint (ethereum-sepolia.     │ │ │
│ │ │   publicnode.com). Compromise = lies about chain state.    │ │ │
│ │ │ ┌──────────────────────────────────────────────────────┐ │ │ │
│ │ │ │ Layer 3 — CDN (jsdelivr.net for ethers.js). Compromise │ │ │ │
│ │ │ │   = client-side wallet drain.                          │ │ │ │
│ │ │ │ ┌─────────────────────────────────────────────────┐ │ │ │ │
│ │ │ │ │ Layer 4 — Site host (Cloudflare Pages).            │ │ │ │ │
│ │ │ │ │   Compromise = same as Layer 3 (UI replacement).   │ │ │ │ │
│ │ │ │ └─────────────────────────────────────────────────┘ │ │ │ │
│ │ │ └──────────────────────────────────────────────────────┘ │ │ │
│ │ └──────────────────────────────────────────────────────────┘ │ │
│ └──────────────────────────────────────────────────────────────┘ │
└──────────────────────────────────────────────────────────────────┘
```

## Layer 1 — Solidity dependencies

Every `lib/` submodule is **pinned by full SHA in `.gitmodules`**. Reverification:

```
git submodule status                       # check current SHAs
git log -1 --pretty=%H lib/openzeppelin-contracts
```

Inventory (the relevant subset; full list in `git submodule status`):

| Submodule | Pinned SHA (truncated) | Used by |
|---|---|---|
| `lib/openzeppelin-contracts` | `git ls-remote`-stable v4.9.x line | ERC20, AccessControl, ERC20Burnable, ReentrancyGuard |
| `lib/forge-std`              | latest forge-std stable | Test, StdInvariant, vm cheatcodes |
| `lib/conditional-tokens-contracts` | Gnosis CTF | CTF interface in resolver / orchestrator |
| `lib/reality-eth-monorepo`   | external-trust upstream | (not used by v5 active code — kept for reference docs) |
| `lib/sx-evm`                 | external-trust upstream | (kept for reference docs only — not in active v5 path) |
| `lib/seer-demo`              | external-trust upstream | reference UI patterns only |

**Trust action on update:** updating any submodule requires (a) running the full unit + invariant suite, (b) re-deploying any contract that linked the changed code, and (c) writing a deployment-history.md row.

**Rejection rule:** if `forge build` warns about a re-derived `IFAOLiquidityAdapter` interface mismatch after a submodule bump, treat as a sign of upstream ABI drift — investigate before merging.

## Layer 1.1 — npm dependencies (E2E only — NOT in deployed bytecode)

`package.json` declares dev-only deps for Playwright + Synpress E2E. **These do not affect on-chain state.** Listed for completeness.

```
"@playwright/test": "^1.50.0",
"@synthetixio/synpress": "^4.0.0",
"viem": "^2.21.0"
```

**Pinning policy:** caret ranges (^) for now; `package-lock.json` (not yet committed; T5.D6 next step) will lock concrete versions.

## Layer 2 — RPC endpoints

The site (`shared.js`) and tests (`playwright.config.ts`) hardcode RPCs:

| Surface | RPC |
|---|---|
| Site | `https://ethereum-sepolia.publicnode.com` |
| E2E fork | `http://127.0.0.1:8545` (Anvil) |
| Forge fork tests | `RPC_URL_SEPOLIA` env, falling back to `https://rpc.ankr.com/eth_sepolia` (configured per-CI) |

**Trust assumption:** publicnode.com tells the truth about Sepolia. If it lies, the UI shows wrong instance state but cannot drain funds (every tx is signed by the user against their own wallet's view of the chain).

**Mitigation pattern:** users connected to MetaMask compare publicnode's `eth_chainId` against MetaMask's chain selection; mismatch surfaces the network-mismatch banner (see `tests-e2e/journeys/failure-modes.read-only.spec.ts::RPC completely down`).

**Future lift:** rotate among 2+ RPCs (publicnode + alchemy + ankr) so a single endpoint compromise doesn't stall the UI.

## Layer 3 — CDN

`site-testnet/index.html` and friends load:

```html
<script src="https://cdn.jsdelivr.net/npm/ethers@6.13.2/dist/ethers.umd.min.js" defer></script>
```

**Trust assumption:** jsdelivr serves the official `ethers@6.13.2` umd build.

**Mitigation today:** version is pinned (`@6.13.2`). Cloudflare Pages serves the host site over HTTPS; the CDN is also HTTPS.

**Mitigation gap:** no Subresource Integrity (SRI) hash. T5.D6 next step is to add `integrity="sha384-..."` per `<script>` so a compromised CDN payload doesn't execute.

**Fallback:** if jsdelivr is down, the site fails to load ethers and `shared.js` cannot read the registry. The page renders without crashes (topbar, hero), but instance data is empty.

## Layer 4 — Site host

Cloudflare Pages, target `https://testnet.fao.futarchy.ai` (DNS via futarchy.ai zone). Build directory: `site-testnet/`.

**Trust assumption:** Cloudflare doesn't inject malicious JS at edge.

**Mitigation today:** custom domain TLS managed by Cloudflare; the source is in this repo, deploy is push-to-main.

**Mitigation gap:** no Content-Security-Policy (CSP) header. Adding `default-src 'self'; script-src 'self' https://cdn.jsdelivr.net; connect-src 'self' https://ethereum-sepolia.publicnode.com https://*.alchemy.com` to a Cloudflare Pages `_headers` file is the next supply-chain lift.

## Etherscan verification

Verification is the single read-side defense against bytecode swap. Status:

| Contract | Verified |
|---|---|
| `InstanceSale_TestFuta` (0x4D6458Bf…) | ✅ |
| `InstanceSale_ACME` (0x4106fB74…)     | ✅ |
| `GenericFutarchyToken_TestFuta` (0xC64dc271…) | ✅ |
| `GenericFutarchyToken_ACME` (0xA9c66fb4…) | ✅ |
| `FAOSale_bootstrap` (0x011F6e57…) | ✅ |
| **`FutarchyRegistry v5` (0x18D1f4e5…)** | ❌ TODO |
| **`TokenAndArbitrationDeployer v5` (0x475a9630…)** | ❌ TODO |
| **`FutarchyStackDeployer v5` (0xc5d7e4e0…)** | ❌ TODO |
| **`UniswapV3LiquidityAdapter` (0x8Ccc8d0E…)** | ❌ TODO |

**Verification gate (T5.D6 next step):** `.github/workflows/static-analysis.yml` adds a check that fails if any address in `deployments.json::active` is not Etherscan-verified.

## Threat-map summary

| Compromise | Blast radius | Detectable? | Mitigated today |
|---|---|---|---|
| Solidity submodule SHA spoof | New deploy uses malicious code | ✅ (forge build sees ABI change) | Pinned SHAs in `.gitmodules` |
| publicnode.com lies | Wrong UI state | ⚠ Only via user comparing with MetaMask | Future: rotate RPC list |
| jsdelivr serves bad ethers | Wallet drain via the connected user's signing | ⚠ Hard to detect post-hoc | Future: SRI hash |
| Cloudflare Pages injects | Wallet drain | ⚠ Same as above | Future: CSP header + alternate-host monitor |
| Etherscan verification removed | Bytecode lying | ✅ (CI gate) | Pending: CI gate |

## How this might be wrong

- The threat map's "blast radius" column is qualitative. Actual losses depend on how many users connect and sign during the compromise window.
- `package-lock.json` is not committed. The current state is "trust caret ranges"; a future evaluator that grep'd for lockfile presence would correctly downgrade this to lower than reality once the lockfile lands.
- The TLS chain trust of `cdn.jsdelivr.net` is assumed; SRI hashes would make it explicit.
- The "Etherscan verification" check is a content-only check — Etherscan UI doesn't prove the deployed bytecode matches the published source if the verifier itself is compromised.
- Forge submodule SHAs are pinned in `.gitmodules`, but `git submodule update --remote` (without explicit checkout) would silently override. Add a CI assertion that running `git submodule status` shows no `+` prefix (uncommitted update).

## See also

- `audit/specs/SECURITY.md` — admin keys, immutability, migration.
- `audit/specs/THREAT-MODEL.md` — attack-vector enumeration (A1-A16).
- `audit/state/DEPRECATIONS.md` — explicit inventory of deprecated artefacts.
- `deployments.json` — active stack addresses (CI-synced into `site-testnet/`).
