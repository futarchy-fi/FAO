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

## Repository layout
- `src/FAOToken.sol`: FAO ERC20 implementation with minting controls and burn support.
- `src/FAOSale.sol`: Sale/treasury/ragequit logic with bonding curve pricing and distribution.
- `script/`: Deployment and scripting utilities (if present).
- `test/`: Foundry tests.

## Status
The repository currently focuses on the FAO token and sale contracts described above. There is no frontend included in this project.
