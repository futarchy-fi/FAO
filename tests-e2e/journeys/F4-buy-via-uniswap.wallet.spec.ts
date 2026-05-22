/**
 * F4-buy-via-uniswap scaffold — see audit/rubrics/topic-2-interface-testing.md.
 *
 * Buy tokens by clicking the Uniswap inline-swap button. Persona: experienced trader. Asserts ETH balance delta + token balance via viem readContract.
 *
 * Currently `test.fixme()` until Synpress is wired into the project. Once
 * wired, the body asserts both the DOM result AND on-chain effect via
 * viem's createPublicClient.
 */
// @ts-nocheck — runs only after npm install.
import { test, expect } from '@playwright/test';

test.fixme('F4-buy-via-uniswap happy path', async ({ page }) => {
  await page.goto('/');
  // TODO: implement happy path per the description above.
});

test.fixme('F4-buy-via-uniswap — wallet rejection', async ({ page }) => {
  // The buyer rejects the MetaMask popup. Site shows inline error,
  // does NOT proceed past the pre-confirm card, no chain state mutates.
});

test.fixme('F4-buy-via-uniswap — wrong chain', async ({ page }) => {
  // Wallet is on mainnet. Site triggers wallet_switchEthereumChain before
  // dispatching the tx. If user rejects the switch, status surfaces it.
});

test.fixme('F4-buy-via-uniswap — RPC 5xx during dispatch', async ({ page }) => {
  // The Sepolia RPC returns 500 mid-tx-submit. Site shows a retryable
  // error; no partial state.
});
