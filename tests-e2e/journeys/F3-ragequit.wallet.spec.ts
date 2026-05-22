/**
 * F3-ragequit scaffold — see audit/rubrics/topic-2-interface-testing.md.
 *
 * Burn N tokens via InstanceSale.ragequit, receive pro-rata ETH and any fLP. Persona: existing holder with 50 tokens. Asserts treasury delta + token totalSupply decrement.
 *
 * Currently `test.fixme()` until Synpress is wired into the project. Once
 * wired, the body asserts both the DOM result AND on-chain effect via
 * viem's createPublicClient.
 */
// @ts-nocheck — runs only after npm install.
import { test, expect } from '@playwright/test';

test.fixme('F3-ragequit happy path', async ({ page }) => {
  await page.goto('/');
  // TODO: implement happy path per the description above.
});

test.fixme('F3-ragequit — wallet rejection', async ({ page }) => {
  // The buyer rejects the MetaMask popup. Site shows inline error,
  // does NOT proceed past the pre-confirm card, no chain state mutates.
});

test.fixme('F3-ragequit — wrong chain', async ({ page }) => {
  // Wallet is on mainnet. Site triggers wallet_switchEthereumChain before
  // dispatching the tx. If user rejects the switch, status surfaces it.
});

test.fixme('F3-ragequit — RPC 5xx during dispatch', async ({ page }) => {
  // The Sepolia RPC returns 500 mid-tx-submit. Site shows a retryable
  // error; no partial state.
});
