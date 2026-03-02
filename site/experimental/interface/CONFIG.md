# FAO Interface Configuration

This document outlines the core configuration files and settings for the FAO Interface application.

## 1. Smart Contracts Configuration

**File:** `src/config/contracts.js`

This file is the **Source of Truth** for the application's contract addresses. It exports the addresses used by the frontend hooks and components.

### Current Deployment (Gnosis Chain)
```javascript
export const CONTRACTS = {
    // Gnosis Chain (100)
    FAO_TOKEN: "0x19c85acb4ca0ff6fed5f8d7b376bfbb37a2d67e9",
    FAO_SALE: "0x3f3ab07ad792bb89dff7528d1cef78372b0d8b93",
};

export const CHAIN_ID = 100; // The active Chain ID (Gnosis Chain)
```

### Auto-Update
During deployment using `scripts/deploy_fao.js`, this file is **automatically updated** with the new deployment addresses. You generally do not need to edit this manually unless you are pointing to a specific existing deployment.

## 2. Chain & Provider Configuration

**File:** `src/app/providers.js`

This file configures the `wagmi` and `RainbowKit` providers, determining which blockchains the wallet can connect to.

### Supported Chains
*   **Production**: `gnosis` (Chain ID 100)
*   **Development**: `mainnet`, `sepolia` (optional)

To enable testnets (Sepolia), set the environment variable:
```env
NEXT_PUBLIC_ENABLE_TESTNETS=true
```

## 3. Environment Variables

**File:** `FAO/.env` (and `.env.local` for Next.js)

### Deployment Variables (`FAO/.env`)
Used by the deployment scripts (`scripts/deploy_fao.js` or Foundry).

| Variable | Description | Required |
| :--- | :--- | :--- |
| `RPC_URL` | The RPC endpoint for deployment (e.g., `https://rpc.gnosischain.com`) | Yes |
| `PRIVATE_KEY` | The deployer's wallet private key (starts with `0x`) | Yes |
| `ETHERSCAN_API_KEY` | Key for verifying contracts on Gnosisscan | Optional |

### Frontend Variables (`.env.local`)
Used by the Next.js application.

| Variable | Description | Default |
| :--- | :--- | :--- |
| `NEXT_PUBLIC_ENABLE_TESTNETS` | Set to `true` to enable Sepolia testnet in the wallet selector. | `false` |
| `NEXT_PUBLIC_WALLET_CONNECT_PROJECT_ID` | Project ID for WalletConnect (RainbowKit). | `YOUR_PROJECT_ID` |

## 4. Contract ABIs

**Directory:** `src/abi/`

*   `FAOToken.json`: ABI for the ERC20 token.
*   `FAOSale.json`: ABI for the sale logic.

These files must define the `abi` array. If you modify the Solidity contracts, ensure you update these JSON files with the new ABI to prevent frontend errors.

## 5. Troubleshooting: Buy Transactions

### Issue: "Incorrect ETH sent" Revert
Users previously encountered a transaction failure with the error "Incorrect ETH sent".

**Why it happened:**
The `FAOSale` contract logic strictly deals in **Whole Tokens** (integers). It enforces that the ETH sent must exactly match `numTokens * price`.
*   **Scenario**: A user sends `0.00015 ETH` when the price is `0.0001 ETH`.
*   **Calculated Tokens**: `0.00015 / 0.0001 = 1.5` → Truncated to `1 Token`.
*   **Expected Cost**: `1 Token * 0.0001 Price = 0.0001 ETH`.
*   **Mismatch**: The user sent `0.00015 ETH`, but the contract expected `0.0001 ETH`. The mismatch caused the revert.

**How it was fixed:**
The `BuyPanel.js` component was updated to handle this calculation on the client side *before* sending the transaction:
1.  **Calculate Whole Tokens**: It calculates `floor(userEthInput / currentPrice)`.
2.  **Derive Exact Cost**: It calculates `numWholeTokens * currentPrice`.
3.  **Send Exact Amount**: The transaction now sends explicitly that exact cost (e.g., `0.0001 ETH`), leaving the "dust" (0.00005 ETH) in the user's wallet.

## 6. Troubleshooting: Ragequit Transactions

### Issue: "Insufficient FAO balance" Revert
Users attempting to ragequit encountered a revert with "Insufficient FAO balance", even though they held enough tokens.

**Why it happened:**
This was a **unit mismatch** between the frontend and the contract.
*   **The Contract**: Expects `numTokens` (Count) as the argument for `ragequit(uint256)`. e.g., to burn 1 token, send `1`.
*   **The Frontend**: Was sending the Wei value of the tokens. e.g., to burn 1 token, it sent `1000000000000000000` (1e18).
*   **Result**: The contract tried to burn 1 Quintillion tokens. Since the user only had 1 token, the balance check failed.

**How it was fixed:**
The `RagequitPanel.js` component was updated to treat approval and burning separately:
1.  **Approval (ERC20)**: Still requires Wei (e.g., `1e18`).
2.  **Ragequit (Custom)**: Now calculates `numTokens = rawWei / 1e18` and sends only that count (e.g., `1`) to the contract function.

### Issue: "approveAndCall is not a function"
A simple naming mismatch in `src/hooks/useApproveAndCall.js`. The hook returned `{ execute }` but the component attempted to destructure `{ approveAndCall }`. This was resolved by renaming the export to match the component's expectation.
