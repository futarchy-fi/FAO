/**
 * Fork-state read-only journey.
 *
 * No wallet UI is involved. The test mutates a live Anvil Sepolia fork with
 * `cast send`, then verifies the browser reflects the fork state after reload.
 */

// @ts-nocheck — runs only after `npm install`.
import { expect, test } from '@playwright/test';
import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { createPublicClient, defineChain, http, parseAbi } from 'viem';

const RPC_URL = process.env.FAO_RPC_URL || 'http://127.0.0.1:8545';
const REGISTRY = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
const DEFAULT_CAST_BIN = `${homedir()}/.foundry/bin/cast`;
const CAST_BIN = process.env.CAST_BIN || (existsSync(DEFAULT_CAST_BIN) ? DEFAULT_CAST_BIN : 'cast');
const ANVIL_PRIVATE_KEY = process.env.ANVIL_PRIVATE_KEY
  || '0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80';

const sepoliaFork = defineChain({
  id: 11155111,
  name: 'Sepolia Anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

const registryAbi = parseAbi([
  'function instancesCount() view returns (uint256)',
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

function castSendCreatePart1({ name, symbol, description }) {
  const args = [
    'send',
    REGISTRY,
    'createFutarchyPart1(string,string,string,uint256,uint256,uint256,uint32,uint32,uint256)',
    name,
    symbol,
    description,
    '100000000000000',   // 0.0001 ETH initial price
    '10',                // min initial phase sold, whole-token units
    '3600',              // initial sale duration, seconds
    '7200',              // arbitration timeout, seconds
    '3600',              // TWAP window, seconds
    '1000000000000000',  // 0.001 WETH base bond
    '--rpc-url',
    RPC_URL,
    '--private-key',
    ANVIL_PRIVATE_KEY,
    '--gas-limit',
    '6000000',
  ];

  try {
    execFileSync(CAST_BIN, args, {
      encoding: 'utf8',
      stdio: 'pipe',
      timeout: 120_000,
    });
  } catch (error) {
    const stdout = error.stdout ? `\nstdout:\n${error.stdout}` : '';
    const stderr = error.stderr ? `\nstderr:\n${error.stderr}` : '';
    throw new Error(`cast send createFutarchyPart1 failed.${stdout}${stderr}`);
  }
}

test.describe('fork state — read-only UI over cast mutations', () => {
  test('home page reflects instancesCount after cast-created instance', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'fork', 'fork-state specs require the Playwright fork project');

    await page.route(/^https:\/\/ethereum-sepolia\.publicnode\.com\/?.*/, routeSepoliaRpcToFork);

    await expect.poll(async () => Number(await publicClient.getBlockNumber()), {
      timeout: 10_000,
      message: 'Anvil fork must already be running on http://127.0.0.1:8545',
    }).toBeGreaterThan(0);

    await page.goto('/');

    const beforeCount = await readInstancesCount();
    const expectedBeforeRows = Number(beforeCount);
    const rows = page.getByTestId('rankings-rows').locator('[data-rank-instance-id]');

    await expect.poll(() => rows.count(), {
      timeout: 30_000,
      message: 'home table should match registry.instancesCount() before mutation',
    }).toBe(expectedBeforeRows);

    const newId = beforeCount;
    const suffix = newId.toString().padStart(3, '0').slice(-6);
    const symbol = `FRK${suffix}`.slice(0, 10);

    castSendCreatePart1({
      name: `Fork State ${suffix}`,
      symbol,
      description: 'Created by fork-state.read-only.spec.ts via cast send.',
    });

    await expect.poll(readInstancesCount, {
      timeout: 30_000,
      message: 'registry.instancesCount() should increment after cast send',
    }).toBe(beforeCount + 1n);

    await page.reload({ waitUntil: 'domcontentloaded' });

    await expect.poll(() => rows.count(), {
      timeout: 30_000,
      message: 'home table should show the cast-created instance after reload',
    }).toBe(expectedBeforeRows + 1);

    const newRow = page.getByTestId('rankings-rows').locator(`[data-rank-instance-id="${newId}"]`);
    await expect(newRow).toBeVisible();
    await expect(newRow).toContainText(symbol);
  });
});
