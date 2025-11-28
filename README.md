# Futarchy Autonomous Optimizer (FAO)

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

### Format
```bash
forge fmt
```

### Gas snapshots
```bash
forge snapshot
```

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

### Deployed Contracts (Gnosis Chain)
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
The repository currently focuses on the FAO token and sale contracts described above. There is no frontend included in this project.
