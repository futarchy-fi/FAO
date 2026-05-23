// @ts-nocheck — Playwright transpiles this file after npm install.
import { execFileSync, spawn } from 'node:child_process';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
import path from 'node:path';
import { expect } from '@playwright/test';
import { createPublicClient, defineChain, http, parseAbi } from 'viem';

export const RPC_URL = process.env.FAO_RPC_URL || 'http://127.0.0.1:8545';
export const PUBLIC_SEPOLIA_RPC = 'https://ethereum-sepolia.publicnode.com';
export const SEPOLIA_FORK_RPC = process.env.SEPOLIA_RPC || PUBLIC_SEPOLIA_RPC;
export const REGISTRY = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
export const WETH = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';
export const FOUNDRY_BIN_DIR = `${homedir()}/.foundry/bin`;
export const DEFAULT_CAST_BIN = `${FOUNDRY_BIN_DIR}/cast`;
export const DEFAULT_ANVIL_BIN = `${FOUNDRY_BIN_DIR}/anvil`;
export const ANVIL_FORK_SCRIPT = path.resolve(process.cwd(), 'scripts/anvil-fork.sh');
export const CAST_BIN = process.env.CAST_BIN || (existsSync(DEFAULT_CAST_BIN) ? DEFAULT_CAST_BIN : 'cast');
export const ANVIL_BIN = process.env.ANVIL_BIN || (existsSync(DEFAULT_ANVIL_BIN) ? DEFAULT_ANVIL_BIN : 'anvil');
export const ANVIL_PRIVATE_KEY = process.env.ANVIL_PRIVATE_KEY
  || '0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6';
export const ANVIL_ADDRESS = process.env.ANVIL_ADDRESS || '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720';

let anvilProcess = null;
let startedAnvilWithScript = false;
let forkBlockNumber = process.env.ANVIL_FORK_BLOCK_NUMBER
  || process.env.FORK_BLOCK_NUMBER
  || '';

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

export const sourceClient = createPublicClient({
  chain: sepoliaFork,
  transport: http(SEPOLIA_FORK_RPC),
});

export const registryAbi = parseAbi([
  'function instancesCount() view returns (uint256)',
  'function instances(uint256) view returns ((string name,string symbol,string description,address creator,address token,address sale,address arbitration,address resolver,address factory,address orchestrator,address spotPool,uint256 createdAt,uint8 status,uint32 timeout,uint32 twapWindow))',
]);

export const saleAbi = parseAbi([
  'function currentPriceWeiPerToken() view returns (uint256)',
  'function initialPhaseFinalized() view returns (bool)',
  'function initialTokensSold() view returns (uint256)',
  'function MIN_INITIAL_PHASE_SOLD() view returns (uint256)',
  'function totalAmountRaised() view returns (uint256)',
  'function buy(uint256 numTokens) payable',
]);

export async function readInstancesCount() {
  return await publicClient.readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'instancesCount',
  });
}

export async function readInstance(id) {
  const inst = await publicClient.readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'instances',
    args: [id],
  });

  return {
    name: inst.name ?? inst[0],
    symbol: inst.symbol ?? inst[1],
    description: inst.description ?? inst[2],
    creator: inst.creator ?? inst[3],
    token: inst.token ?? inst[4],
    sale: inst.sale ?? inst[5],
    arbitration: inst.arbitration ?? inst[6],
    resolver: inst.resolver ?? inst[7],
    factory: inst.factory ?? inst[8],
    orchestrator: inst.orchestrator ?? inst[9],
    spotPool: inst.spotPool ?? inst[10],
    createdAt: inst.createdAt ?? inst[11],
    status: Number(inst.status ?? inst[12]),
  };
}

export async function readSaleSnapshot(saleAddress) {
  const [priceWei, finalized, initialSold, minInitialSold, totalRaised] = await Promise.all([
    publicClient.readContract({
      address: saleAddress,
      abi: saleAbi,
      functionName: 'currentPriceWeiPerToken',
    }),
    publicClient.readContract({
      address: saleAddress,
      abi: saleAbi,
      functionName: 'initialPhaseFinalized',
    }),
    publicClient.readContract({
      address: saleAddress,
      abi: saleAbi,
      functionName: 'initialTokensSold',
    }),
    publicClient.readContract({
      address: saleAddress,
      abi: saleAbi,
      functionName: 'MIN_INITIAL_PHASE_SOLD',
    }),
    publicClient.readContract({
      address: saleAddress,
      abi: saleAbi,
      functionName: 'totalAmountRaised',
    }),
  ]);

  return { priceWei, finalized, initialSold, minInitialSold, totalRaised };
}

async function canReadForkBlock() {
  try {
    await publicClient.getBlockNumber();
    return true;
  } catch (_) {
    return false;
  }
}

async function resolveForkBlockNumber() {
  if (forkBlockNumber) return forkBlockNumber;
  forkBlockNumber = (await sourceClient.getBlockNumber()).toString();
  return forkBlockNumber;
}

function startAnvilFork(blockNumber) {
  const env = {
    ...process.env,
    ANVIL_FORK_BLOCK_NUMBER: blockNumber,
    FORK_BLOCK_NUMBER: blockNumber,
    SEPOLIA_RPC: SEPOLIA_FORK_RPC,
    PATH: `${FOUNDRY_BIN_DIR}:${process.env.PATH || ''}`,
  };

  if (existsSync(ANVIL_FORK_SCRIPT)) {
    execFileSync('bash', [ANVIL_FORK_SCRIPT], {
      encoding: 'utf8',
      stdio: 'pipe',
      timeout: 30_000,
      env,
    });
    startedAnvilWithScript = true;
    return;
  }

  anvilProcess = spawn(
    ANVIL_BIN,
    ['--fork-url', SEPOLIA_FORK_RPC, '--port', '8545', '--fork-block-number', blockNumber],
    { stdio: 'ignore', env },
  );
}

export async function resetAnvilFork(blockNumber = forkBlockNumber) {
  const resolvedBlock = blockNumber || await resolveForkBlockNumber();
  await publicClient.request({
    method: 'anvil_reset',
    params: [{
      forking: {
        jsonRpcUrl: SEPOLIA_FORK_RPC,
        blockNumber: Number(resolvedBlock),
      },
    }],
  });

  await expect.poll(async () => Number(await readInstancesCount()), {
    timeout: 30_000,
    message: `Anvil fork should reset to Sepolia block ${resolvedBlock}`,
  }).toBeGreaterThanOrEqual(0);
}

export async function ensureAnvilFork() {
  const blockNumber = await resolveForkBlockNumber();
  if (!(await canReadForkBlock())) startAnvilFork(blockNumber);

  await expect.poll(async () => {
    try {
      return Number(await publicClient.getBlockNumber());
    } catch (_) {
      return 0;
    }
  }, {
    timeout: 30_000,
    message: 'Anvil fork must be running on http://127.0.0.1:8545',
  }).toBeGreaterThan(0);

  await resetAnvilFork(blockNumber);
  return blockNumber;
}

export async function stopSpawnedAnvil() {
  if (startedAnvilWithScript) {
    startedAnvilWithScript = false;
    if (existsSync(ANVIL_FORK_SCRIPT)) {
      execFileSync('bash', [ANVIL_FORK_SCRIPT, '--stop'], {
        encoding: 'utf8',
        stdio: 'pipe',
        timeout: 30_000,
        env: {
          ...process.env,
          PATH: `${FOUNDRY_BIN_DIR}:${process.env.PATH || ''}`,
        },
      });
    }
  }

  if (!anvilProcess) return;
  const child = anvilProcess;
  anvilProcess = null;
  if (child.exitCode != null || child.signalCode != null) return;
  await new Promise((resolve) => {
    const done = () => resolve();
    child.once('exit', done);
    child.kill('SIGTERM');
    setTimeout(() => {
      if (child.exitCode == null && child.signalCode == null) child.kill('SIGKILL');
      resolve();
    }, 5_000).unref();
  });
}

export function runCast(args, description, timeout = 120_000) {
  try {
    return execFileSync(CAST_BIN, args, {
      encoding: 'utf8',
      stdio: 'pipe',
      timeout,
      env: {
        ...process.env,
        PATH: `${FOUNDRY_BIN_DIR}:${process.env.PATH || ''}`,
      },
    });
  } catch (error) {
    const status = error.status == null ? '' : `\nstatus: ${error.status}`;
    const signal = error.signal == null ? '' : `\nsignal: ${error.signal}`;
    const stdout = error.stdout ? `\nstdout:\n${error.stdout}` : '';
    const stderr = error.stderr ? `\nstderr:\n${error.stderr}` : '';
    throw new Error(`${description} failed.${status}${signal}${stdout}${stderr}`);
  }
}

export function castSend(contract, signature, signatureArgs, { gasLimit = '6000000', value, async = false } = {}) {
  const args = [
    'send',
  ];
  if (async) args.push('--async');
  args.push(
    contract,
    signature,
    ...signatureArgs,
    '--rpc-url',
    RPC_URL,
    '--private-key',
    ANVIL_PRIVATE_KEY,
    '--gas-limit',
    gasLimit,
  );
  if (value != null) args.push('--value', String(value));

  const out = runCast(args, `cast send ${signature}`);
  return async ? out.trim().split(/\s+/).find((part) => /^0x[a-fA-F0-9]{64}$/.test(part)) : out;
}

export function castSendCreatePart1({
  name,
  symbol,
  description,
  initialPriceWei = '100000000000000',
  minInitialSold = '10',
  initialSaleDuration = '3600',
  timeout = '7200',
  twapWindow = '3600',
  baseBondWei = '1000000000000000',
}) {
  castSend(
    REGISTRY,
    'createFutarchyPart1(string,string,string,uint256,uint256,uint256,uint32,uint32,uint256)',
    [
      name,
      symbol,
      description,
      initialPriceWei,
      minInitialSold,
      initialSaleDuration,
      timeout,
      twapWindow,
      baseBondWei,
    ],
    { gasLimit: '6000000' },
  );
}

export async function createPart1Instance(params) {
  const id = await readInstancesCount();
  castSendCreatePart1(params);

  await expect.poll(readInstancesCount, {
    timeout: 30_000,
    message: 'registry.instancesCount() should increment after cast send',
  }).toBe(id + 1n);

  return { id, inst: await readInstance(id) };
}

export async function routeJsonRpcToFork(route) {
  const request = route.request();
  const postData = request.postData();
  if (request.method() !== 'POST' || !postData) {
    await route.continue();
    return;
  }

  let body;
  try {
    body = JSON.parse(postData);
  } catch (_) {
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

export async function routePublicRpcToFork(page) {
  const host = new URL(PUBLIC_SEPOLIA_RPC).host;
  const corsHeaders = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'POST, OPTIONS',
    'access-control-allow-headers': 'content-type',
  };

  await page.route(`**://${host}/**`, async (route, request) => {
    if (request.method() === 'OPTIONS') {
      await route.fulfill({ status: 204, headers: corsHeaders, body: '' });
      return;
    }

    const response = await fetch(RPC_URL, {
      method: 'POST',
      headers: { 'content-type': 'application/json' },
      body: request.postData() || '',
    });
    const body = await response.text();

    await route.fulfill({
      status: response.status,
      headers: {
        ...corsHeaders,
        'content-type': response.headers.get('content-type') || 'application/json',
      },
      body,
    });
  });
}
