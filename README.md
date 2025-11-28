# FAO

Futarchy Autonomous Optimizer smart contracts built with Foundry.

## Contracts

- `FAOToken`: ERC20 with burn support and a configurable `MINTER_ROLE` for controlled supply
  issuance.
- `FAOSale`: ETH sale contract that handles the fixed-price launch phase, a linear bonding curve,
  treasury/incentive/insider mint distribution, and a ragequit mechanism.

Grant the `FAOSale` contract the `MINTER_ROLE` on `FAOToken` before starting the sale so it can
mint distribution tranches on purchases and handle ragequit burns.

## Development

This repository uses Foundry. Install Foundry and fetch dependencies before building or testing:

```bash
foundryup              # install/update Foundry (if not already installed)
forge install          # fetch dependencies (e.g., OpenZeppelin contracts)
forge build
forge test
```

Forge will place build artifacts in `out/` and the dependency tree in `lib/`, both of which are
ignored from version control.
