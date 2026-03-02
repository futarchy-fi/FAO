# Subgraph Integration Guide

This guide outlines how to integrate the FAO Subgraph to power the **Transaction Log** section of the dashboard.

## 1. GraphQL Endpoint

**Endpoint**: `https://api.studio.thegraph.com/query/1721787/futarchy-subgraph/v0.0.1`

> **Action Required**: Add this URL to `src/config/contracts.js` or `.env` as `NEXT_PUBLIC_SUBGRAPH_URL`.

## 2. Event Entities

Based on the `schema.graphql`, the subgraph indexes two primary events: `PurchaseEvent` and `RagequitEvent`.

### PurchaseEvent Entity
*   `buyer`: Address of the user buying FAO.
*   `numTokens`: Amount of FAO tokens purchased (whole tokens).
*   `costWei`: Amount of xDAI/ETH paid.
*   `timestamp`: Time of transaction.
*   `txHash`: Hash for linking to block explorer.

### RagequitEvent Entity
*   `user`: Address of the user exiting.
*   `faoBurned`: Amount of FAO burned.
*   `ethReturned`: Amount of xDAI/ETH received.

## 3. The Query

Use this GraphQL query to fetch the combined transaction log:

```graphql
query GetRecentActivity {
  purchaseEvents(first: 10, orderBy: timestamp, orderDirection: desc) {
    id
    buyer
    numTokens
    costWei
    timestamp
    txHash
  }
  ragequitEvents(first: 10, orderBy: timestamp, orderDirection: desc) {
    id
    user
    faoBurned
    ethReturned
    timestamp
    txHash
  }
}
```

## 4. Implementation Logic

1.  **Fetch**: Use `request` from `graphql-request` or `urql` to fetch `GetRecentActivity`.
2.  **Merge & Sort**:
    *   Combine `purchaseEvents` and `ragequitEvents` into a single array.
    *   Add a `type` field (`'BUY'` vs `'SELL'`).
    *   Sort the combined array by `timestamp` (descending).
3.  **Display**:
    *   Map the sorted list to your "Transactions" UI rows.
    *   Format `costWei` / `ethReturned` with `formatEther`.
    *   Format `numTokens` / `faoBurned` as integers.

## 5. Deployment Checklist
[ ] Locate Subgraph URL in `fao-subgraph` folder.
[ ] Add URL to project config.
[ ] Create `useRecentTransactions` hook using `tanstack-query` + `graphql-request`.
[ ] Update Dashboard UI to render the list.
