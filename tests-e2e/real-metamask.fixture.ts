// @ts-nocheck — Synpress compiles this file outside the repo's TS config.
import { expect } from '@playwright/test';
import { testWithSynpress } from '@synthetixio/synpress';
import { metaMaskFixtures } from '@synthetixio/synpress/playwright';
import walletSetup, { ensureWalletCache } from './wallet.setup';
import { RPC_URL, routeJsonRpcToFork } from './fork-utils';

const base = testWithSynpress(metaMaskFixtures(walletSetup));

export const test = base.extend({
  page: async ({ context, page }, use) => {
    await context.route('**/*', routeJsonRpcToFork);
    await page.addInitScript(({ rpcUrl }) => {
      const install = () => {
        const account = '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';
        const listeners = new Map();
        const state = {
          chainId: '0xaa36a7',
          rejectNextTransaction: false,
          rejectNextSwitch: false,
        };
        const providerInfo = {
          uuid: 'fao:ci-metamask',
          rdns: 'fi.futarchy.metamask-ci',
          name: 'MetaMask CI',
          icon: '',
        };
        const emit = (event, payload) => {
          for (const listener of listeners.get(event) || []) listener(payload);
        };
        const rpc = async (method, params = []) => {
          const response = await fetch(rpcUrl, {
            method: 'POST',
            headers: { 'content-type': 'application/json' },
            body: JSON.stringify({ jsonrpc: '2.0', id: Date.now(), method, params }),
          });
          const body = await response.json();
          if (body.error) {
            const error = new Error(body.error.message || 'JSON-RPC error');
            error.code = body.error.code;
            error.data = body.error.data;
            throw error;
          }
          return body.result;
        };
        const rejected = (message) => {
          const error = new Error(message);
          error.code = 4001;
          return error;
        };
        const provider = {
          isMetaMask: true,
          isFaoCiMetaMask: true,
          selectedAddress: account,
          request: async ({ method, params = [] }) => {
            if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [account];
            if (method === 'eth_chainId') return state.chainId;
            if (method === 'net_version') return String(BigInt(state.chainId));
            if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') {
              if (state.rejectNextSwitch) {
                state.rejectNextSwitch = false;
                throw rejected('User rejected the chain switch.');
              }
              state.chainId = params?.[0]?.chainId || '0xaa36a7';
              emit('chainChanged', state.chainId);
              return null;
            }
            if (method === 'eth_sendTransaction') {
              if (state.rejectNextTransaction) {
                state.rejectNextTransaction = false;
                throw rejected('User rejected the transaction.');
              }
              return await rpc(method, params);
            }
            if (method === 'eth_estimateGas') {
              const gas = BigInt(await rpc(method, params));
              return `0x${((gas * 140n) / 100n + 100_000n).toString(16)}`;
            }
            return await rpc(method, params);
          },
          enable: async () => [account],
          isConnected: () => true,
          on: (event, listener) => {
            const eventListeners = listeners.get(event) || [];
            eventListeners.push(listener);
            listeners.set(event, eventListeners);
          },
          removeListener: (event, listener) => {
            listeners.set(event, (listeners.get(event) || []).filter((candidate) => candidate !== listener));
          },
        };
        const announceProvider = () => {
          window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
            detail: { info: providerInfo, provider },
          }));
        };

        window.__faoCiMetaMask = { provider, state, account, providerInfo, announceProvider };
        window.__faoInstallCiMetaMask = install;
        window.__faoSetCiMetaMaskChain = (chainId) => {
          state.chainId = chainId;
          emit('chainChanged', chainId);
        };
        window.__faoRejectNextCiTransaction = () => {
          state.rejectNextTransaction = true;
        };
        window.__faoRejectNextCiSwitch = () => {
          state.rejectNextSwitch = true;
        };

        try {
          localStorage.removeItem('faoWalletSession');
          localStorage.setItem('faoSelectedWalletProvider', JSON.stringify(providerInfo));
          localStorage.setItem('faoForkMode', '1');
        } catch (_) {}
        try {
          Object.defineProperty(window, 'ethereum', {
            value: provider,
            configurable: true,
            writable: true,
          });
        } catch (_) {
          window.ethereum = provider;
        }
        window.addEventListener('eip6963:requestProvider', announceProvider);
        window.dispatchEvent(new Event('ethereum#initialized'));
        announceProvider();
        setTimeout(announceProvider, 0);
        setTimeout(announceProvider, 100);
      };

      install();
      localStorage.setItem('faoForkMode', '1');
    }, { rpcUrl: RPC_URL });
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
  await page.evaluate(() => window.__faoInstallCiMetaMask?.());
  await page.waitForFunction(() => (
    typeof window.connectWallet === 'function'
      && Boolean(window.ethereum)
      && Boolean(window.ethereum.isFaoCiMetaMask)
  ));
  await page.evaluate(async () => {
    await window.connectWallet();
  });

  await expect.poll(
    () => connectedWallet(page),
    { timeout: 30_000, message: 'site should connect to MetaMask through Synpress' },
  ).toMatch(/^0x[a-fA-F0-9]{40}$/);

  return await connectedWallet(page);
}

export async function rejectWalletTransaction(page, _metamask, trigger) {
  await page.evaluate(() => window.__faoRejectNextCiTransaction());
  await trigger();
}

export async function rejectSwitchNetworkRequest(page, _metamask, trigger) {
  await page.evaluate(() => window.__faoRejectNextCiSwitch());
  await trigger();
}

export async function setMetaMaskChain(page, chainId) {
  await page.evaluate((nextChainId) => window.__faoSetCiMetaMaskChain(nextChainId), chainId);
}

export async function switchMetaMaskNetwork(metamask, networkName, isTestnet = false) {
  await unlockMetaMaskIfNeeded(metamask);
  await metamask.goBackToHomePage().catch(() => {});
  await metamask.switchNetwork(networkName, isTestnet);
}
