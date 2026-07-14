# Futarchy Autonomous Optimizer (FAO)

The [agent-work v1 specification](docs/agent-work-v1.md) defines the ownerless publication index,
canonical task/receipt/payment documents, and their exact binding to typed treasury transfers.
Its P1 reference agent recomputes finalized state on every tick and keeps signing behind an
injected boundary; `python3 tools/agent_anvil_drill.py` regenerates the 16-drill evidence matrix.

The [wind-tunnel P0 control plane](docs/windtunnel-p0.md) indexes finalized multi-instance state,
replays reorgs deterministically, and prepares at most one unsigned permissionless keeper crank.

Lane 5 P2a adds a closed-world three-agent tournament with no new contracts, stored keys, or
public broadcasts. CI rehearses it on plain Anvil; the sealed evidence is regenerated from one
plain-local run plus two byte-identical runs at pinned Sepolia block 11,261,000:

```bash
python3 tools/agent_tournament.py
```

The tournament proves exact document binding, restart/race handling, and treasury accounting. It
does not claim external work quality, demand, adoption, information aggregation, collusion
resistance, or a sustainable subsidy.
All six proposals receive an initial YES bond; the three challenged proposals then receive one
graduation YES flip each, so the evidence reports six YES-bonded proposals, nine YES-bond
transactions, and three graduation flips. Its complete ledger also includes the 12 stack-setup
transactions and separately discloses every account, native-balance, and storage override.
It also records every transaction/receipt/log and every timestamp/manual-mine control. That
source-pinned Anvil transcript is internally cross-checked evidence, not an externally
authenticated chain attestation.

## Rehearsal R0 S1 composed loop

The fork-only S1 harness deploys one receipt genesis, raises and bootstraps it, creates an
official futarchy market, migrates the FLM, settles a bounded YES trade by TWAP/CTF, proves one
atomic guard rejection, and restores to spot. It pins Sepolia block `11265000`, hash
`0xa493de27f3173b07abfc718634acd5bcafbfd7e1d4583ad824b1dee7e7d9cd29`, and rechecks every
canonical dependency runtime before running two fresh loopback-only Anvil forks:

```bash
python3 tools/rehearsal_r0.py \
  --fork-url https://sepolia.drpc.org \
  --output /tmp/fao-rehearsal-r0-s1.json
```

The committed [S1 evidence](metadata/rehearsal-r0-s1-evidence.json) has byte-identical economic
projections with digest
`0x4f0454c029d5b2a77a56bbf37360eee9ebeadae6efb04b68322774aefc884e9d`; its file checksum is
recorded in [the sidecar](metadata/rehearsal-r0-s1-evidence.json.sha256). This is source-pinned fork
evidence with zero public broadcasts, not a public-chain deployment or external attestation. It
proves the G2 composed-loop slice only: trader outcome inventory remains explicitly outstanding,
while whole-run conservation, replay verifier/tamper checks, and G4–G7 evidence remain deferred to
R0 S6.

## Rehearsal R0 S2 local hero slice

S2 composes a successful 60 FAO genesis and a refundable failed twin on two fresh local Anvil
chains. It proves permissionless spot deposits and redemption, a no-vote Snapshot X site release
selected by an unchallenged YES timeout, bounded treasury transfers with atomic failure evidence,
and a 25% holder ragequit followed by FLM redemption. Both runs pin chain `31337` and genesis time
`1800000000`; their complete 119-transaction projections are byte-identical.

```bash
python3 tools/rehearsal_r0_local.py \
  --output /tmp/fao-rehearsal-r0-s2-local.json

python3 tools/rehearsal_r0_local.py \
  --check \
  --output metadata/rehearsal-r0-s2-evidence.json
```

The committed [S2 evidence](metadata/rehearsal-r0-s2-evidence.json) has economic projection digest
`0xb0bfe88d5a5c2ab559dd8bde3b8b7b62ebe2e55d445f9c82c8f72e65c55c299c`; its file checksum is in
[the sidecar](metadata/rehearsal-r0-s2-evidence.json.sha256). The canonical predicted hero pool is
provisioned only on local Anvil with the runtime of a same-run mock template before economics. The
failed twin receives no pool code. This evidence makes no real-AMM, fork-equivalence, external
attestation, demand, or public-deployment claim, and it performs zero public broadcasts.

## Rehearsal R0 S3 fork-only agent composition

S3 composes the sealed six-submission P2a agent matrix with the exact S1 Sepolia stack. Three
receipt-bound evaluations run serially through real conditional pools, the FLM, bounded trades,
7-day/1-day TWAP resolution, CTF settlement, and full spot restoration: one resolves YES and two
resolve NO. The other three proposals settle by timeout. The transcript reconciles hero-scale
bonds, four exact vault payments, the executor tap, rejected-payment failures, and treasury
balances without public broadcasts or contract-storage overrides.

```bash
python3 tools/rehearsal_r0_agents.py \
  --fork-url https://sepolia.drpc.org \
  --output metadata/rehearsal-r0-s3-evidence.json

python3 tools/rehearsal_r0_agents.py \
  --check \
  --output metadata/rehearsal-r0-s3-evidence.json
```

Generation requires two fresh byte-identical forks at the S1 pin; `--single-run` is diagnostic and
cannot produce sealable evidence. Verification is bytes-only and offline. S3 does not claim that
the agents performed external work, that users demand the work or markets, that the subsidy is
sustainable, or that any transaction was deployed or paid on a public chain. The C-T3 shortfall is
not replayed here; its sealed P2a drill remains the evidence for that separate failure mode.

This repository contains the smart contracts for the Futarchy Autonomous Optimizer token (FAO) and its sale mechanics. The codebase is implemented with [Foundry](https://book.getfoundry.sh/) and relies on OpenZeppelin libraries for security-reviewed primitives.

## Contracts

### `FAOToken`
- ERC20 token with burn support and AccessControl-based minting.
- Token name: **Futarchy Autonomous Optimizer**
- Symbol: **FAO**
- The deployer supplies an admin address that can manage the `MINTER_ROLE`.

### `FAOSale`
A sale, treasury, and ragequit contract that manages ETH-for-FAO purchases and redemptions.

Key behavior:
- **Sale phases**
  - Starts with an admin-triggered two-week initial phase at a fixed price of 0.0001 ETH per FAO (whole token units).
  - Once the initial phase is finalized, pricing follows a **linear bonding curve** based on initial net sales.
- **Token distribution per sale**
  - 1.0x FAO to the buyer.
  - 0.5x FAO to the contract treasury.
  - 0.2x FAO to the configured incentive contract (optional).
  - 0.3x FAO to the insider vesting contract (optional).
- **Ragequit**
  - Users can burn FAO to redeem a pro-rata share of the contract's ETH balance and any configured ERC20 "ragequit" tokens.
  - Ragequits during the initial phase reduce the initial sale/tally to keep accounting accurate.
- **Administration**
  - Uses OpenZeppelin `AccessControl`; intended to be governed by a `TimelockController`.
  - Admin functions include starting the sale, configuring incentive/insider addresses, managing ragequit token lists, and withdrawing ETH/ERC20 (excluding FAO).

The FAO tokens minted to the contract itself, as well as the tokens minted to the incentive contract, and the insider vesting contract, are not counted in the ragequit pro-rata denominator. This, coupled with the intended usage of an OpenZeppelin TimelockController, ensures that buyers can withdraw the totality of funds during the timelock window, before any admin transaction is executed.

### `InsiderVesting`

The InsiderVesting contract implements FAO insider vesting tied to objective, on-chain price milestones rather than time alone.

Key mechanics:

- 10 tranches, each representing 10% of all FAO ever received by the contract.

- Each tranche unlocks linearly over 365 days, but only while the market demonstrates price support at or above that tranche’s milestone.

- Price verification is entirely on-chain via 0.1 ETH bonds posted at fixed price levels (2×, 4×, …, 1024× the initial FAO sale price, starting at 0.0002 ETH/FAO).

- A tranche becomes active when a bond exists at its price or any higher level.

- Vesting uses the FAO total as of the previous poke(), preventing “back-vesting” when new tokens arrive.

- Only one bond per level; “dust” bonds automatically deactivate.

- Beneficiary-controlled: the beneficiary can self-update its address and can rescue non-FAO ERC-20s or ETH at any time.

- Designed to receive FAO automatically from the sale contract (no deposit function).

This mechanism ensures insiders vest only when the market shows real willingness to buy FAO at increasing price levels, creating a transparent, manipulation-resistant vesting schedule aligned with long-term value creation.

### `FutarchyLiquidityManager`
- ERC20 share token (`fLP`) that holds and routes FAO + wrapped native liquidity.
- Seeded by `FAOSale`; when seeded, `FAOSale` automatically adds `fLP` as a ragequit token.
- Supports permissionless deposits and share minting, pro-rata redemption, and migration between spot/conditional venues.
- Conditional migration path uses futarchy router `splitPosition/mergePositions/redeemPositions` to route liquidity through YES/NO wrapped outcome pools.
- Includes owner-gated emergency controls with enforced exit delay.

### `FutarchyOfficialProposalSource`
- Owner-managed source of a single official proposal at a time.
- Supports either manual settlement flagging or optional external settlement oracle.
- Resolves YES/NO pool addresses through an Algebra factory on Gnosis.

### `SwaprAlgebraLiquidityAdapter`
- Adapter for Swapr V3 (Algebra) full-range liquidity positions.
- Manages one position per ordered token pair.
- Supports optional pool create+initialize on first mint (`sqrtPriceX96`) while preserving legacy add params encoding.


## Development

The project uses Foundry. Install it via the upstream instructions if you don't already have `forge` available.

### Build
```bash
forge build
```

### Test
```bash
forge test
```

Gnosis fork check for proposal token wiring (`FAO -> YES_FAO/NO_FAO`):
```bash
RUN_GNOSIS_FORK_TESTS=true \
TEST_FAO_PROPOSAL=0x81829a8ee62D306e3fD9D5b79D02C7624437BE37 \
TEST_FAO_TOKEN=0x9494C281a02c9ae5f72b224B514793ad2DD8cA17 \
forge test --match-contract FutarchyProposalWiringForkTest
```

### Format
```bash
forge fmt
```

### Gas snapshots
```bash
forge snapshot
```

## Sepolia Site Release

Set the deployment wallet, Sepolia RPC, and the four canonical `ipfs://` metadata URIs, then run:

```bash
script/deploy-fao-sepolia.sh
```

This is the canonical dry run. It forces one coherent Foundry build and validates the generated
`run-latest.json`. Add `--broadcast` only after reviewing that artifact:

```bash
script/deploy-fao-sepolia.sh --broadcast
```

## Sepolia Economic Genesis

The economic-genesis wrapper loads the four pinned metadata URIs from
`metadata/sepolia-site-release/bundle.json`. Its canonical defaults expect deployer
`0x693E3FB46Bb36eE43C702FE94f9463df0691b43d` at pending nonce `185`; before invoking Foundry it
derives the receipt and release-strategy addresses and rejects any metadata or nonce drift.

```bash
SEPOLIA_RPC_URL=https://... PRIVATE_KEY=0x... \
  script/deploy-fao-economic-sepolia.sh --broadcast
```

Override `ECONOMIC_METADATA_BUNDLE`, `EXPECTED_DEPLOYER`, and `EXPECTED_DEPLOYER_NONCE` together
for a different deployment. The bundle must describe the release strategy derived from that
deployer and nonce.

Economic deployment manifests use schema v4. Both broadcast and finalized-chain reconstruction
pin the exact live runtime hashes of the vault, proposal gateway, arbitration, and treasury
executor; RPC verification rejects any substituted authority contract before trusting its views.
Schema v4 keeps integer fields as JSON numbers. Browser clients must not recompute full core or FLM
config preimages through ordinary `JSON.parse`, which loses integers above 2^53; they instead root
disclosed hashes in canonical registrar/receipt provenance and verify finalized wiring plus the v4
runtime hashes. The Python verifier remains the lossless full-preimage verifier.

## Gnosis Liquidity Stack Deploy

Deploy `FutarchyOfficialProposalSource`, two Swapr adapters (spot/conditional), and `FutarchyLiquidityManager`:

```bash
PRIVATE_KEY=0x... \
SALE_ADDRESS=0x... \
FAO_TOKEN_ADDRESS=0x... \
OFFICIAL_PROPOSER=0x... \
forge script script/DeployLiquidityStackGnosis.s.sol:DeployLiquidityStackGnosis \
  --rpc-url gnosis --broadcast
```

Optional env vars:
- `STACK_OWNER` (defaults to deployer; use timelock in production)
- `WRAPPED_NATIVE` (default WXDAI)
- `SWAPR_POSITION_MANAGER` (default Gnosis Swapr NFPM)
- `ALGEBRA_FACTORY` (default Gnosis Swapr Algebra factory)
- `FUTARCHY_ROUTER` (default Gnosis futarchy router)
- `DEFAULT_TICK_LOWER` / `DEFAULT_TICK_UPPER` (defaults to full range)

## CLI Usage

The repository includes an interactive CLI (`cli.sh`) for interacting with deployed contracts on Gnosis Chain.

### Prerequisites
- Foundry (`cast` command available)
- `jq`
- `bc`

### Running the CLI
```bash
chmod +x cli.sh
./cli.sh
```

### Deployed Contracts (Old Version, Gnosis Chain)
| Contract | Address |
|----------|---------|
| FAO Token | `0xb222e2a6E065c2559a74168eeAbA298af91b84B9` |
| FAO Sale | `0x460915528ce37EC66A26b98b791Db512BC62DC17` |

### Menu Options

**View Functions (read-only):**
| Option | Description |
|--------|-------------|
| 1 | Sale Info - Shows sale timing, current price, tokens sold, funds raised |
| 2 | Token Info - Name, symbol, total supply |
| 3 | Contract Balances - xDAI and FAO held by sale contract |
| 4 | Check User Balance - Query any address for xDAI, FAO, and allowance |
| 5 | Calculate Buy Cost - Estimate cost for purchasing tokens |

**Write Functions (require private key):**
| Option | Description |
|--------|-------------|
| 6 | Buy Tokens - Purchase FAO with xDAI |
| 7 | Approve FAO for Ragequit - Set token approval for burning |
| 8 | Ragequit - Burn FAO to receive pro-rata xDAI and ERC20s |

**Admin Functions:**
| Option | Description |
|--------|-------------|
| 9 | Admin Menu - Set incentive/insider contracts, manage ragequit tokens, withdraw ETH, rescue ERC20s |

### Environment Variables

For write operations, you can set `PRIVATE_KEY` in your environment to avoid being prompted:
```bash
export PRIVATE_KEY=0x...
./cli.sh
```

If not set, the CLI will prompt for your private key when needed.

## Repository layout
- `src/FAOToken.sol`: FAO ERC20 implementation with minting controls and burn support.
- `src/FAOSale.sol`: Sale/treasury/ragequit logic with bonding curve pricing and distribution.
- `script/`: Deployment and scripting utilities (if present).
- `test/`: Foundry tests.

## Status
The repository currently focuses on the FAO token and sale contracts described above.

## Site (static UI)

A minimal, static UI for fao.eth lives in [`/site`](site). Open `site/index.html` directly or serve the directory with any static file server to view the stubbed sale and ragequit controls along with contract addresses and quick-start docs.
