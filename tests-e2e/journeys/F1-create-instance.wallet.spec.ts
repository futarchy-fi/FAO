/**
 * F1 — Create a new futarchy instance.
 *
 * Persona: protocol founder using a funded MetaMask account on an Anvil
 * Sepolia fork.
 */

// @ts-nocheck — runs only after `npm install`; type-check is opt-in via CI.
import { expect } from '@playwright/test';
import { testWithSynpress } from '@synthetixio/synpress';
import { metaMaskFixtures } from '@synthetixio/synpress/playwright';
import { createPublicClient, defineChain, http, parseAbi } from 'viem';
import walletSetup, { ensureWalletCache } from '../wallet.setup';

const RPC_URL = process.env.FAO_RPC_URL || 'http://127.0.0.1:8545';
const BROWSER_RPC_URL = 'https://ethereum-sepolia.publicnode.com';
const REGISTRY = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
const ZERO = '0x0000000000000000000000000000000000000000';
const ANVIL_ACCOUNT = process.env.ANVIL_ACCOUNT || '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';

const sepoliaFork = defineChain({
  id: 11155111,
  name: 'Sepolia Anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

const registryAbi = parseAbi([
  'function instancesCount() view returns (uint256)',
  'function instances(uint256 id) view returns ((string name, string symbol, string description, address creator, address token, address sale, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint32 timeout, uint32 twapWindow))',
]);

const publicClient = createPublicClient({
  chain: sepoliaFork,
  transport: http(RPC_URL),
});

async function readInstancesCount() {
  return await publicClient.readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'instancesCount',
  });
}

async function readInstance(id) {
  return await publicClient.readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'instances',
    args: [BigInt(id)],
  });
}

function field(page, testId, id) {
  return page.getByTestId(testId).or(page.locator(`#${id}`)).first();
}

function createSubmit(page) {
  return page.getByTestId('create-submit').or(page.getByRole('button', { name: /^create futarchy$/i })).first();
}

function createStatus(page) {
  return page.getByTestId('create-status').or(page.locator('#create-instance-status')).first();
}

async function routeSepoliaRpcToFork(route) {
  const request = route.request();
  const response = await route.fetch({
    url: RPC_URL,
    method: request.method(),
    headers: { 'content-type': request.headers()['content-type'] || 'application/json' },
    postData: request.postData() || undefined,
  });
  await route.fulfill({ response });
}

async function injectAnvilWallet(page) {
  await page.addInitScript(({ rpcUrl, account }) => {
    window.__faoInstallAnvilWallet = ({ rpcUrl: nextRpcUrl, account: nextAccount }) => {
      const listeners = new Map();
      const emit = (event, payload) => {
        for (const listener of listeners.get(event) || []) listener(payload);
      };
      const rpc = async (method, params = []) => {
        const response = await fetch(nextRpcUrl, {
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
      const provider = {
        isMetaMask: true,
        selectedAddress: nextAccount,
        chainId: '0xaa36a7',
        request: async ({ method, params = [] }) => {
          if (method === 'eth_requestAccounts' || method === 'eth_accounts') return [nextAccount];
          if (method === 'eth_chainId') return '0xaa36a7';
          if (method === 'net_version') return '11155111';
          if (method === 'wallet_switchEthereumChain' || method === 'wallet_addEthereumChain') {
            emit('chainChanged', '0xaa36a7');
            return null;
          }
          return await rpc(method, params);
        },
        enable: async () => [nextAccount],
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

      try {
        delete window.ethereum;
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
      window.dispatchEvent(new Event('ethereum#initialized'));
      return provider.selectedAddress;
    };

    window.__faoInstallAnvilWallet({ rpcUrl, account });
  }, { rpcUrl: BROWSER_RPC_URL, account: ANVIL_ACCOUNT });
}

async function installAnvilWallet(page) {
  await page.evaluate(({ rpcUrl, account }) => {
    if (typeof window.__faoInstallAnvilWallet !== 'function') {
      throw new Error('Anvil wallet installer was not injected');
    }
    return window.__faoInstallAnvilWallet({ rpcUrl, account });
  }, { rpcUrl: BROWSER_RPC_URL, account: ANVIL_ACCOUNT });
}

const base = testWithSynpress(metaMaskFixtures(walletSetup));
const test = base.extend({
  page: async ({ context }, use) => {
    await context.route(/^https:\/\/ethereum-sepolia\.publicnode\.com\/?.*/, routeSepoliaRpcToFork);

    const page = await context.newPage();
    await page.addInitScript(() => {
      localStorage.setItem('faoForkMode', '1');
    });
    await injectAnvilWallet(page);

    await use(page);
    await page.close();
  },
});

test.setTimeout(240_000);

test.beforeAll(async () => {
  await ensureWalletCache();
});

test('F1 — Founder creates a new futarchy instance end-to-end', async ({ page }) => {
  const beforeCount = await readInstancesCount();
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `E2E${suffix}`.slice(0, 10);

  await page.goto('/create');
  await expect(page).toHaveURL(/\/create/);
  await expect(field(page, 'create-name', 'ci-name')).toBeVisible();
  await installAnvilWallet(page);
  await page.getByRole('button', { name: /^connect$/i }).click();
  await expect.poll(
    () => page.evaluate(() => window.connectedWallet || null),
    { timeout: 15_000, message: 'site should connect to the injected Anvil wallet' },
  ).toBe(ANVIL_ACCOUNT);

  await field(page, 'create-name', 'ci-name').fill(`Acme E2E ${suffix}`);
  await field(page, 'create-symbol', 'ci-symbol').fill(symbol);
  await field(page, 'create-description', 'ci-description').fill('E2E test instance created by Synpress.');
  await field(page, 'create-price', 'ci-price').fill('0.0001');
  await field(page, 'create-min-sold', 'ci-min-sold').fill('10');
  await field(page, 'create-sale-duration', 'ci-sale-duration').fill('60');
  await field(page, 'create-timeout', 'ci-timeout').fill('120');
  await field(page, 'create-twap', 'ci-twap').fill('60');
  await field(page, 'create-bond', 'ci-bond').fill('0.001');

  const status = createStatus(page);
  await createSubmit(page).click();

  const confirmCard = page.getByTestId('confirm-card-create').or(page.locator('#confirm-card-create')).first();
  const hasConfirmCard = await confirmCard
    .waitFor({ state: 'visible', timeout: 5_000 })
    .then(() => true)
    .catch(() => false);
  if (hasConfirmCard) {
    await page
      .getByTestId('confirm-card-create-confirm')
      .or(page.locator('#confirm-card-create-confirm'))
      .first()
      .click();
  }

  await expect.poll(
    async () => {
      if (/\?inst=\d+/.test(page.url())) {
        return 'done';
      }
      return (await status.textContent().catch(() => '')) ?? '';
    },
    { timeout: 120_000, message: 'create flow should progress to mining or redirect' },
  ).toMatch(/Step [12]\/2|Done|done/i);
  await page.waitForURL(/\/\?inst=\d+/, { timeout: 30_000 });

  const url = new URL(page.url());
  const newId = Number(url.searchParams.get('inst'));
  expect(Number.isFinite(newId)).toBe(true);
  expect(BigInt(newId)).toBe(beforeCount);

  await expect.poll(readInstancesCount, {
    timeout: 30_000,
    message: 'registry.instancesCount() should increment after F1 create',
  }).toBe(beforeCount + 1n);

  const instance = await readInstance(newId);
  const sale = (Array.isArray(instance) ? instance[5] : instance.sale).toLowerCase();
  expect(sale).not.toBe(ZERO);

  const row = page.getByTestId(`rankings-row-${newId}`).or(page.locator(`[data-rank-instance-id="${newId}"]`));
  await expect(row).toBeVisible({ timeout: 30_000 });
  await expect(row).toContainText(symbol);
  await expect(row).toContainText(/initial sale/i);
});
