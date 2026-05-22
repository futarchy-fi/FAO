// @ts-nocheck
import { expect, test } from '@playwright/test';

const WALLET = '0x1111111111111111111111111111111111111111';
const INFO = {
  uuid: 'mock-eip6963-provider',
  rdns: 'dev.fao.mockwallet',
  name: 'Mock 6963 Wallet',
  icon: '',
};

test('restores stored EIP-6963 provider identity without prompting', async ({ page }) => {
  await page.addInitScript(({ wallet, info }) => {
    localStorage.setItem('faoSelectedWalletProvider', JSON.stringify({
      uuid: info.uuid,
      rdns: info.rdns,
      name: info.name,
    }));
    localStorage.setItem('faoWalletSession', JSON.stringify({
      wallet,
      provider: {
        uuid: info.uuid,
        rdns: info.rdns,
        name: info.name,
      },
      updatedAt: Date.now(),
    }));

    const provider = {
      async request({ method }) {
        if (method === 'eth_accounts') return [wallet];
        if (method === 'eth_requestAccounts') return [wallet];
        if (method === 'eth_chainId') return '0xaa36a7';
        if (method === 'wallet_getCapabilities') {
          return { '0xaa36a7': { atomicBatch: { supported: true } } };
        }
        throw Object.assign(new Error(`Unsupported mock wallet method: ${method}`), { code: -32601 });
      },
      on() {},
      removeListener() {},
    };

    const announce = () => {
      window.dispatchEvent(new CustomEvent('eip6963:announceProvider', {
        detail: { info, provider },
      }));
    };
    window.addEventListener('eip6963:requestProvider', announce);
    queueMicrotask(announce);
  }, { wallet: WALLET, info: INFO });

  await page.goto('/', { waitUntil: 'domcontentloaded' });
  await page.waitForLoadState('networkidle');

  const chip = page.getByTestId('topbar-wallet-identity');
  await expect(chip).toBeVisible();
  await expect(chip).toContainText(INFO.name);
  await expect(chip).toContainText(INFO.rdns);
  await expect(chip).toContainText('0x1111…1111');
  await expect(page.getByTestId('topbar-wallet-capabilities')).toContainText('5792');
  await expect(page.getByTestId('topbar-status')).toContainText('Reconnected with Mock 6963 Wallet');
});
