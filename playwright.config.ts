// @ts-check
/**
 * Playwright config for the FAO testnet site.
 *
 * Targets three contexts:
 *   - `read-only` — visits the live deploy, no wallet, no transactions.
 *     Covers UI invariants visible without signing.
 *   - `fork` — runs read-only specs against a local Anvil fork by seeding
 *     localStorage.faoForkMode before navigation.
 *   - `wallet` — drives MetaMask via Synpress against an Anvil fork of
 *     Sepolia. Required for any test that needs to sign a tx
 *     (buy, ragequit, create-proposal, place-bond, etc).
 *
 * Selectors must use `data-testid` (see `tests-e2e/SELECTORS.md`).
 * Tests that assert on chain state read it via viem's createPublicClient
 * against the same Anvil RPC — never trust only DOM toasts.
 */

import { existsSync } from 'node:fs';
import path from 'node:path';
import { defineConfig, devices } from '@playwright/test';

const SITE_URL = process.env.FAO_SITE_URL || 'https://fao-testnet.pages.dev';
const RPC_URL  = process.env.FAO_RPC_URL  || 'http://127.0.0.1:8545';   // Anvil fork
const HEADED   = process.env.HEADED === '1';
if (!process.env.FAO_RPC_URL) process.env.FAO_RPC_URL = RPC_URL;
if (!HEADED && !process.env.HEADLESS) process.env.HEADLESS = 'true';
const LOCAL_BROWSER_LIBS = [
  path.join(process.cwd(), '.pw-libs', 'usr', 'lib', 'x86_64-linux-gnu'),
  path.join(process.cwd(), '.pw-libs', 'lib', 'x86_64-linux-gnu'),
].filter(existsSync);
if (LOCAL_BROWSER_LIBS.length) {
  process.env.LD_LIBRARY_PATH = [...LOCAL_BROWSER_LIBS, process.env.LD_LIBRARY_PATH || ''].filter(Boolean).join(':');
}
const SITE_ORIGIN = new URL(SITE_URL).origin;
const FORK_STORAGE_STATE = {
  cookies: [],
  origins: [{
    origin: SITE_ORIGIN,
    localStorage: [{ name: 'faoForkMode', value: '1' }],
  }],
};

export default defineConfig({
  testDir: './tests-e2e',
  timeout: 90_000,
  expect: {
    timeout: 10_000,
    toHaveScreenshot: {
      maxDiffPixelRatio: 0.005,
      pathTemplate: '{testDir}/__snapshots__/{testFileName}-snapshots/{arg}{ext}',
    },
  },
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
    {
      name: 'fork',
      use: {
        ...devices['Desktop Chrome'],
        storageState: FORK_STORAGE_STATE,
      },
      testMatch: /.*fork-state\.read-only\.spec\.ts/,
    },
    {
      name: 'wallet',
      use: {
        ...devices['Desktop Chrome'],
        storageState: FORK_STORAGE_STATE,
      },
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
