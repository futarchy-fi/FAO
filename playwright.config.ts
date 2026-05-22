// @ts-check
/**
 * Playwright config for the FAO testnet site.
 *
 * Targets two contexts:
 *   - `read-only` — visits the live deploy, no wallet, no transactions.
 *     Covers UI invariants visible without signing.
 *   - `wallet` — drives MetaMask via Synpress against an Anvil fork of
 *     Sepolia. Required for any test that needs to sign a tx
 *     (buy, ragequit, create-proposal, place-bond, etc).
 *
 * Selectors must use `data-testid` (see `tests-e2e/SELECTORS.md`).
 * Tests that assert on chain state read it via viem's createPublicClient
 * against the same Anvil RPC — never trust only DOM toasts.
 */

import { defineConfig, devices } from '@playwright/test';

const SITE_URL = process.env.FAO_SITE_URL || 'https://fao-testnet.pages.dev';
const RPC_URL  = process.env.FAO_RPC_URL  || 'http://127.0.0.1:8545';   // Anvil fork
const HEADED   = process.env.HEADED === '1';

export default defineConfig({
  testDir: './tests-e2e',
  timeout: 90_000,
  expect: { timeout: 10_000 },
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 2 : 1,
  reporter: process.env.CI ? [['html', { open: 'never' }], ['github']] : [['list'], ['html', { open: 'never' }]],
  use: {
    baseURL: SITE_URL,
    actionTimeout: 15_000,
    navigationTimeout: 30_000,
    screenshot: 'only-on-failure',
    trace: 'retain-on-failure',
    video: 'retain-on-failure',
    headless: !HEADED,
  },
  projects: [
    {
      name: 'read-only',
      use: { ...devices['Desktop Chrome'] },
      testMatch: /.*\.read-only\.spec\.ts/,
    },
    // The `wallet` project is structured so Synpress can be added later
    // without touching every test file. Until Synpress is wired, only the
    // `read-only` project runs.
    {
      name: 'wallet',
      use: { ...devices['Desktop Chrome'] },
      testMatch: /.*\.wallet\.spec\.ts/,
      // grep: /@wallet/,
    },
  ],
  metadata: {
    rubric: 'audit/rubrics/topic-2-interface-testing.md',
    site: SITE_URL,
    rpc: RPC_URL,
  },
});
