// @ts-nocheck — Synpress compiles this file outside the repo's TS config.
import { expect } from '@playwright/test';
import { testWithSynpress } from '@synthetixio/synpress';
import { metaMaskFixtures } from '@synthetixio/synpress/playwright';
import walletSetup, { ensureWalletCache } from './wallet.setup';
import { routeJsonRpcToFork } from './fork-utils';

const base = testWithSynpress(metaMaskFixtures(walletSetup));

export const test = base.extend({
  page: async ({ context, page }, use) => {
    await context.route('**/*', routeJsonRpcToFork);
    await page.addInitScript(() => {
      localStorage.setItem('faoForkMode', '1');
    });
    await use(page);
  },
});

export { expect, ensureWalletCache };

async function finishReadyScreen(walletPage) {
  const done = walletPage.getByTestId('onboarding-complete-done');
  if (await done.isVisible({ timeout: 2_000 }).catch(() => false)) {
    await done.click();
  }

  const openWallet = walletPage.getByRole('button', { name: /^open wallet$/i });
  if (await openWallet.isVisible({ timeout: 2_000 }).catch(() => false)) {
    await openWallet.click();
    await walletPage.waitForLoadState('domcontentloaded').catch(() => {});
  }
}

export async function unlockMetaMaskIfNeeded(metamask) {
  const extensionPages = metamask.context.pages()
    .filter((walletPage) => walletPage.url().startsWith('chrome-extension://'));
  const hasUnlockedHome = extensionPages.some((walletPage) => (
    walletPage.url().includes('/home.html') && !walletPage.url().includes('#unlock')
  ));

  if (hasUnlockedHome) {
    for (const walletPage of extensionPages) {
      if (walletPage.url().includes('#unlock')) await walletPage.close().catch(() => {});
    }
    return;
  }

  for (const walletPage of extensionPages) {
    if (!walletPage.url().startsWith('chrome-extension://')) continue;
    await walletPage.waitForLoadState('domcontentloaded').catch(() => {});
    await finishReadyScreen(walletPage);
    const passwordInput = walletPage.getByTestId('unlock-password');
    const needsUnlock = walletPage.url().includes('#unlock')
      || await passwordInput.isVisible({ timeout: 1_000 }).catch(() => false);
    if (!needsUnlock) continue;

    await walletPage.bringToFront();
    await passwordInput.waitFor({ state: 'visible', timeout: 10_000 });
    await passwordInput.fill(metamask.password);
    await walletPage.locator('.loading-overlay').waitFor({ state: 'hidden', timeout: 10_000 }).catch(() => {});
    await walletPage.getByTestId('unlock-submit').click({ timeout: 10_000 }).catch(async () => {
      await walletPage.getByTestId('unlock-submit').click({ force: true });
    });
    await walletPage.getByTestId('unlock-password').waitFor({ state: 'hidden', timeout: 60_000 });
  }
}

async function closeMetaMaskHomePages(metamask) {
  for (const walletPage of metamask.context.pages()) {
    const url = walletPage.url();
    if (url.startsWith('chrome-extension://') && url.includes('/home.html')) {
      await walletPage.close().catch(() => {});
    }
  }
}

async function connectedWallet(page) {
  return await page.evaluate(() => window.connectedWallet || null);
}

function timeoutAfter(ms, message) {
  return new Promise((resolve) => {
    setTimeout(() => resolve({ ok: false, message }), ms);
  });
}

export async function connectWithMetaMask(page, metamask) {
  const connectButton = page.getByTestId('topbar-connect').or(page.getByRole('button', { name: /^connect/i })).first();
  await expect(connectButton).toBeVisible({ timeout: 30_000 });
  await unlockMetaMaskIfNeeded(metamask);
  await closeMetaMaskHomePages(metamask);
  await page.waitForFunction(() => typeof window.connectWallet === 'function' && Boolean(window.ethereum));

  const connectRequest = page.evaluate(async () => {
    try {
      await window.connectWallet();
      return { ok: true, wallet: window.connectedWallet || null };
    } catch (error) {
      return {
        ok: false,
        message: error?.message || String(error),
        connectedWallet: window.connectedWallet || null,
      };
    }
  });

  await page.waitForTimeout(1_000);
  await unlockMetaMaskIfNeeded(metamask);

  let approvalError;
  if (!(await connectedWallet(page))) {
    await metamask.connectToDapp().catch((error) => {
      approvalError = error;
    });
  }
  const connectResult = await Promise.race([
    connectRequest,
    timeoutAfter(5_000, 'window.connectWallet() did not settle after Synpress notification wait'),
  ]);

  if (approvalError && !(await connectedWallet(page))) {
    throw new Error([
      approvalError.message || String(approvalError),
      `Site connect result: ${JSON.stringify(connectResult)}`,
    ].join('\n'));
  }
  expect(connectResult.ok || Boolean(await connectedWallet(page)), `site connectWallet() result: ${JSON.stringify(connectResult)}`).toBe(true);

  await expect.poll(
    () => connectedWallet(page),
    { timeout: 30_000, message: 'site should connect to MetaMask through Synpress' },
  ).toMatch(/^0x[a-fA-F0-9]{40}$/);

  return await connectedWallet(page);
}

export async function switchMetaMaskNetwork(metamask, networkName, isTestnet = false) {
  await unlockMetaMaskIfNeeded(metamask);
  await metamask.goBackToHomePage().catch(() => {});
  await metamask.switchNetwork(networkName, isTestnet);
}
