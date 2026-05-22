/**
 * Fork-state read-only journey.
 *
 * No wallet UI is involved. The test mutates a live Anvil Sepolia fork with
 * `cast send`, then verifies the browser reflects the fork state after reload.
 */

// @ts-nocheck — runs only after `npm install`.
import { expect, test } from '@playwright/test';
import { execFileSync, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { createPublicClient, defineChain, http, parseAbi } from 'viem';

const RPC_URL = process.env.FAO_RPC_URL || 'http://127.0.0.1:8545';
const REGISTRY = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
const FOUNDRY_BIN_DIR = `${homedir()}/.foundry/bin`;
const DEFAULT_CAST_BIN = `${homedir()}/.foundry/bin/cast`;
const DEFAULT_ANVIL_BIN = `${homedir()}/.foundry/bin/anvil`;
const ANVIL_FORK_SCRIPT = path.resolve(process.cwd(), 'scripts/anvil-fork.sh');
const CAST_BIN = process.env.CAST_BIN || (existsSync(DEFAULT_CAST_BIN) ? DEFAULT_CAST_BIN : 'cast');
const ANVIL_BIN = process.env.ANVIL_BIN || (existsSync(DEFAULT_ANVIL_BIN) ? DEFAULT_ANVIL_BIN : 'anvil');
const ANVIL_PRIVATE_KEY = process.env.ANVIL_PRIVATE_KEY
  || '0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6';

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

async function canReadForkBlock() {
  try {
    await publicClient.getBlockNumber();
    return true;
  } catch (_) {
    return false;
  }
}

function startAnvilFork() {
  const env = {
    ...process.env,
    PATH: `${FOUNDRY_BIN_DIR}:${process.env.PATH || ''}`,
  };

  if (existsSync(ANVIL_FORK_SCRIPT)) {
    execFileSync('bash', [ANVIL_FORK_SCRIPT], {
      encoding: 'utf8',
      stdio: 'pipe',
      timeout: 30_000,
      env,
    });
    return;
  }

  const args = ['--fork-url', process.env.SEPOLIA_RPC || 'https://ethereum-sepolia.publicnode.com', '--port', '8545'];
  const forkBlock = process.env.ANVIL_FORK_BLOCK_NUMBER || process.env.FORK_BLOCK_NUMBER;
  if (forkBlock) args.push('--fork-block-number', forkBlock);

  const child = spawn(ANVIL_BIN, args, {
    detached: true,
    stdio: 'ignore',
    env,
  });
  child.unref();
}

async function ensureAnvilFork() {
  if (!(await canReadForkBlock())) {
    startAnvilFork();
  }

  await expect.poll(async () => Number(await publicClient.getBlockNumber()), {
    timeout: 30_000,
    message: 'Anvil fork must be running on http://127.0.0.1:8545',
  }).toBeGreaterThan(0);
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
    const status = error.status == null ? '' : `\nstatus: ${error.status}`;
    const signal = error.signal == null ? '' : `\nsignal: ${error.signal}`;
    const stdout = error.stdout ? `\nstdout:\n${error.stdout}` : '';
    const stderr = error.stderr ? `\nstderr:\n${error.stderr}` : '';
    throw new Error(`cast send createFutarchyPart1 failed.${status}${signal}${stdout}${stderr}`);
  }
}

test.describe('fork state — read-only UI over cast mutations', () => {
  test.beforeAll(async ({}, testInfo) => {
    if (testInfo.project.name !== 'fork') return;
    await ensureAnvilFork();
  });

  test('home page reflects instancesCount after cast-created instance', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'fork', 'fork-state specs require the Playwright fork project');

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
