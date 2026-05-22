// @ts-nocheck — Synpress compiles this file outside the repo's TS config.
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, writeFileSync } from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { transformSync } from 'esbuild';
import { defineWalletSetup } from '@synthetixio/synpress';
import { MetaMask } from '@synthetixio/synpress/playwright';

export const WALLET_NETWORK_NAME = process.env.SYNPRESS_NETWORK_NAME || 'Anvil Sepolia';

const WALLET_PASSWORD = process.env.SYNPRESS_WALLET_PASSWORD || 'SynpressTest123!';
const SEED_PHRASE = process.env.SYNPRESS_SEED_PHRASE || 'test test test test test test test test test test test junk';
const RPC_URL = process.env.FAO_RPC_URL || 'http://127.0.0.1:8545';
const SETUP_SOURCE_PATH = path.join(process.cwd(), 'tests-e2e', 'wallet.setup.ts');

function setupSourceVersion() {
  return createHash('sha256').update(readFileSync(SETUP_SOURCE_PATH, 'utf8')).digest('hex');
}

function sourceWalletSetupHash() {
  const sourceCode = readFileSync(SETUP_SOURCE_PATH, 'utf8');
  const match = sourceCode.match(
    /defineWalletSetup\s*\([^,]*,\s*(async\s*\([^)]*\)\s*=>\s*{(?:[^{}]*|{(?:[^{}]*|{[^{}]*})*})*})\s*\)/,
  );
  if (!match?.[1]) throw new Error('Could not find defineWalletSetup callback');
  const { code } = transformSync(match[1], {
    format: 'esm',
    minifyWhitespace: true,
    target: 'es2022',
    drop: ['console', 'debugger'],
    loader: 'ts',
    logLevel: 'silent',
    platform: 'node',
  });
  return createHash('shake256', { outputLength: 10 }).update(code).digest('hex');
}

const walletSetup = defineWalletSetup(WALLET_PASSWORD, async (context, walletPage) => {
  const metamask = new MetaMask(context, walletPage, WALLET_PASSWORD);
  const extensionBase = walletPage.url().match(/^chrome-extension:\/\/[^/]+/)?.[0];
  if (!extensionBase) throw new Error(`Could not derive MetaMask extension URL from ${walletPage.url()}`);

  await metamask.importWallet(SEED_PHRASE);
  await walletPage.getByTestId('onboarding-complete-done').click({ timeout: 10_000 }).catch(() => {});
  await walletPage.goto(`${extensionBase}/home.html`);
  await walletPage.waitForLoadState('domcontentloaded');
  const locked = await walletPage.getByTestId('unlock-password').waitFor({ state: 'visible', timeout: 10_000 })
    .then(() => true)
    .catch(() => false);
  if (locked) {
    await metamask.unlock();
  }
  await walletPage.getByTestId('onboarding-complete-done').click({ timeout: 10_000 }).catch(() => {});

  if (process.env.TEST_PRIVATE_KEY) {
    await metamask.importWalletFromPrivateKey(process.env.TEST_PRIVATE_KEY);
  }
});
walletSetup.hash = sourceWalletSetupHash();

export async function ensureWalletCache() {
  const cachePath = path.join(process.cwd(), '.cache-synpress', walletSetup.hash);
  const markerPath = path.join(cachePath, '.setup-complete');
  const sourceVersion = setupSourceVersion();
  const markerVersion = existsSync(markerPath) ? readFileSync(markerPath, 'utf8').trim() : '';
  const force = process.env.SYNPRESS_REBUILD_CACHE === '1' || markerVersion !== sourceVersion;
  const cacheReady = existsSync(markerPath) && markerVersion === sourceVersion;
  if (!force && cacheReady) return;

  const cliPath = path.join(process.cwd(), 'node_modules', '@synthetixio', 'synpress', 'dist', 'cli.js');
  const args = [cliPath, 'tests-e2e'];
  if (process.env.HEADLESS === 'true' || process.env.HEADED !== '1') args.push('--headless');
  if (force) args.push('--force');

  const result = spawnSync(process.execPath, args, {
    cwd: process.cwd(),
    env: {
      ...process.env,
      FAO_RPC_URL: RPC_URL,
      HEADLESS: process.env.HEADLESS || (process.env.HEADED === '1' ? '' : 'true'),
    },
    stdio: 'inherit',
  });

  if (result.status !== 0) {
    throw new Error(`Synpress wallet cache build failed with exit code ${result.status}`);
  }

  writeFileSync(markerPath, `${sourceVersion}\n`);
}

export default walletSetup;
