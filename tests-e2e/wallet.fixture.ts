// @ts-nocheck — Playwright loads this in the wallet project after npm install.
import { expect } from '@playwright/test';
import { testWithSynpress } from '@synthetixio/synpress';
import { metaMaskFixtures } from '@synthetixio/synpress/playwright';
import { createPublicClient, defineChain, http, parseAbi } from 'viem';
import walletSetup, { ensureWalletCache } from './wallet.setup';

export const RPC_URL = process.env.FAO_RPC_URL || 'http://127.0.0.1:8545';
const BROWSER_RPC_URL = 'https://ethereum-sepolia.publicnode.com';
export const REGISTRY = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
export const ZERO = '0x0000000000000000000000000000000000000000';
export const ANVIL_ACCOUNT = process.env.ANVIL_ACCOUNT || '0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266';

export const sepoliaFork = defineChain({
  id: 11155111,
  name: 'Sepolia Anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

export const publicClient = createPublicClient({
  chain: sepoliaFork,
  transport: http(RPC_URL),
});

export const registryAbi = parseAbi([
  'function instancesCount() view returns (uint256)',
  'function instances(uint256 id) view returns ((string name, string symbol, string description, address creator, address token, address sale, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint32 timeout, uint32 twapWindow))',
]);

export const saleAbi = parseAbi([
  'function currentPriceWeiPerToken() view returns (uint256)',
  'function totalAmountRaised() view returns (uint256)',
  'function totalSaleTokens() view returns (uint256)',
  'function quoteRagequit(uint256 numTokens) view returns (uint256)',
  'function buy(uint256 numTokens) payable',
  'function ragequit(uint256 numTokens)',
]);

export const erc20Abi = parseAbi([
  'function balanceOf(address account) view returns (uint256)',
  'function totalSupply() view returns (uint256)',
  'function allowance(address owner, address spender) view returns (uint256)',
]);

export const factoryAbi = parseAbi([
  'function marketsCount() view returns (uint256)',
  'function proposals(uint256 id) view returns (address)',
]);

async function routeJsonRpcToFork(route) {
  const request = route.request();
  const postData = request.postData();
  if (request.method() !== 'POST' || !postData) {
    await route.continue();
    return;
  }

  let body;
  try {
    body = JSON.parse(postData);
  } catch {
    await route.continue();
    return;
  }

  const payloads = Array.isArray(body) ? body : [body];
  if (!payloads.some((payload) => payload?.jsonrpc === '2.0' && typeof payload.method === 'string')) {
    await route.continue();
    return;
  }

  const response = await route.fetch({
    url: RPC_URL,
    method: request.method(),
    headers: { 'content-type': request.headers()['content-type'] || 'application/json' },
    postData,
  });
  await route.fulfill({ response });
}

const base = testWithSynpress(metaMaskFixtures(walletSetup));

export const test = base.extend({
  page: async ({ context }, use) => {
    await context.route('**/*', routeJsonRpcToFork);

    const page = await context.newPage();
    await page.addInitScript(() => {
      localStorage.setItem('faoForkMode', '1');
    });
    await injectAnvilWallet(page);

    await use(page);
    await page.close();
  },
});

export { expect, ensureWalletCache };

export function readContract({ address, abi, functionName, args = [] }) {
  return publicClient.readContract({ address, abi, functionName, args });
}

export async function readInstance(id = 0) {
  return await readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'instances',
    args: [BigInt(id)],
  });
}

export function unpackInstance(instance) {
  return {
    name: instance.name ?? instance[0],
    symbol: instance.symbol ?? instance[1],
    description: instance.description ?? instance[2],
    creator: instance.creator ?? instance[3],
    token: instance.token ?? instance[4],
    sale: instance.sale ?? instance[5],
    arbitration: instance.arbitration ?? instance[6],
    resolver: instance.resolver ?? instance[7],
    factory: instance.factory ?? instance[8],
    orchestrator: instance.orchestrator ?? instance[9],
    spotPool: instance.spotPool ?? instance[10],
  };
}

export async function activeInstance(id = 0) {
  return unpackInstance(await readInstance(id));
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

export async function installAnvilWallet(page) {
  await page.evaluate(({ rpcUrl, account }) => {
    if (typeof window.__faoInstallAnvilWallet !== 'function') {
      throw new Error('Anvil wallet installer was not injected');
    }
    return window.__faoInstallAnvilWallet({ rpcUrl, account });
  }, { rpcUrl: BROWSER_RPC_URL, account: ANVIL_ACCOUNT });
}

export async function connectWalletWithButton(page, _metamask, connectButton) {
  await expect(connectButton).toBeVisible({ timeout: 30_000 });

  await installAnvilWallet(page);
  await connectButton.click();
  await expect.poll(
    () => page.evaluate(() => window.connectedWallet || null),
    { timeout: 30_000, message: 'site should expose connected wallet after Anvil provider connect' },
  ).toBe(ANVIL_ACCOUNT);

  return await page.evaluate(() => window.connectedWallet);
}

export async function connectTopbarWallet(page, metamask) {
  const connectButton = page.getByTestId('topbar-connect').or(page.getByRole('button', { name: /^connect/i })).first();
  return await connectWalletWithButton(page, metamask, connectButton);
}

export async function confirmOneTransaction(_page, _metamask, trigger) {
  await trigger();
}
