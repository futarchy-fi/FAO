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
import walletSetup, { ensureWalletCache, WALLET_NETWORK_NAME } from '../wallet.setup';

const RPC_URL = process.env.FAO_RPC_URL || 'http://127.0.0.1:8545';
const REGISTRY = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
const ZERO = '0x0000000000000000000000000000000000000000';

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

async function addLocalSepoliaNetwork(page, metamask) {
  const addNetwork = page.evaluate(
    async ({ rpcUrl, chainName }) => {
      try {
        await window.ethereum.request({
          method: 'wallet_addEthereumChain',
          params: [{
            chainId: '0xaa36a7',
            chainName,
            nativeCurrency: { name: 'SepoliaETH', symbol: 'SepoliaETH', decimals: 18 },
            rpcUrls: [rpcUrl],
            blockExplorerUrls: ['https://sepolia.etherscan.io/'],
          }],
        });
        return { ok: true };
      } catch (err) {
        return {
          ok: false,
          code: err?.code,
          message: err?.message || String(err),
          data: err?.data,
        };
      }
    },
    { rpcUrl: RPC_URL, chainName: WALLET_NETWORK_NAME },
  );

  const early = await Promise.race([
    addNetwork,
    new Promise((resolve) => setTimeout(() => resolve(null), 2_000)),
  ]);
  if (early?.ok === false) {
    throw new Error(`wallet_addEthereumChain failed: ${JSON.stringify(early)}`);
  }

  const addResult = await Promise.all([
    metamask.approveNewNetwork().catch(() => metamask.approveNewEthereumRPC()),
    addNetwork,
  ]).then(([, result]) => result);
  if (!addResult.ok) {
    throw new Error(`wallet_addEthereumChain failed: ${JSON.stringify(addResult)}`);
  }

  const chainId = await page.evaluate(() => window.ethereum.request({ method: 'eth_chainId' }));
  if (chainId !== '0xaa36a7') {
    await Promise.all([
      metamask.approveSwitchNetwork(),
      page.evaluate(() => window.ethereum.request({
        method: 'wallet_switchEthereumChain',
        params: [{ chainId: '0xaa36a7' }],
      })),
    ]);
  }
}

const base = testWithSynpress(metaMaskFixtures(walletSetup));
const test = base.extend({
  page: async ({ context }, use) => {
    await context.route(/^https:\/\/ethereum-sepolia\.publicnode\.com\/?.*/, routeSepoliaRpcToFork);

    const page = await context.newPage();
    await page.addInitScript(() => {
      localStorage.setItem('faoForkMode', '1');
    });

    await use(page);
    await page.close();
  },
});

test.setTimeout(240_000);

test.beforeAll(async () => {
  await ensureWalletCache();
});

test('F1 — Founder creates a new futarchy instance end-to-end', async ({ page, metamask }) => {
  const beforeCount = await readInstancesCount();
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `E2E${suffix}`.slice(0, 10);

  await page.goto('/create');
  await expect(page).toHaveURL(/\/create/);
  await addLocalSepoliaNetwork(page, metamask);

  await Promise.all([
    metamask.connectToDapp(),
    page.getByRole('button', { name: /^connect$/i }).click(),
  ]);

  await page.getByTestId('create-name').fill(`Acme E2E ${suffix}`);
  await page.getByTestId('create-symbol').fill(symbol);
  await page.getByTestId('create-description').fill('E2E test instance created by Synpress.');
  await page.getByTestId('create-price').fill('0.0001');
  await page.getByTestId('create-min-sold').fill('10');
  await page.getByTestId('create-sale-duration').fill('60');
  await page.getByTestId('create-timeout').fill('120');
  await page.getByTestId('create-twap').fill('60');
  await page.getByTestId('create-bond').fill('0.001');

  const status = page.getByTestId('create-status');
  await page.getByTestId('create-submit').click();

  await expect(status).toContainText(/Step 1\/2/i, { timeout: 15_000 });
  await metamask.confirmTransaction({ gasSetting: 'site' });

  await expect(status).toContainText(/Step 2\/2/i, { timeout: 120_000 });
  await metamask.confirmTransaction({ gasSetting: 'site' });

  await expect(status).toContainText(/Done/i, { timeout: 180_000 });
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
