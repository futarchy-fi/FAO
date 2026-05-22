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
const PUBLIC_SEPOLIA_RPC = 'https://ethereum-sepolia.publicnode.com';
const REGISTRY = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
const WETH = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';
const FOUNDRY_BIN_DIR = `${homedir()}/.foundry/bin`;
const DEFAULT_CAST_BIN = `${homedir()}/.foundry/bin/cast`;
const DEFAULT_ANVIL_BIN = `${homedir()}/.foundry/bin/anvil`;
const ANVIL_FORK_SCRIPT = path.resolve(process.cwd(), 'scripts/anvil-fork.sh');
const CAST_BIN = process.env.CAST_BIN || (existsSync(DEFAULT_CAST_BIN) ? DEFAULT_CAST_BIN : 'cast');
const ANVIL_BIN = process.env.ANVIL_BIN || (existsSync(DEFAULT_ANVIL_BIN) ? DEFAULT_ANVIL_BIN : 'anvil');
const ANVIL_PRIVATE_KEY = process.env.ANVIL_PRIVATE_KEY
  || '0x2a871d0798f97d79848a013d4936a73bf4cc922c825d33c1cf7073dff6d409c6';
const ANVIL_ADDRESS = process.env.ANVIL_ADDRESS || '0xa0Ee7A142d267C1f36714E4a8F75612F20a79720';

const sepoliaFork = defineChain({
  id: 11155111,
  name: 'Sepolia Anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

const registryAbi = parseAbi([
  'function instancesCount() view returns (uint256)',
  'function instances(uint256) view returns ((string name,string symbol,string description,address creator,address token,address sale,address arbitration,address resolver,address factory,address orchestrator,address spotPool,uint256 createdAt,uint8 status,uint32 timeout,uint32 twapWindow))',
]);

const saleAbi = parseAbi([
  'function currentPriceWeiPerToken() view returns (uint256)',
  'function initialTokensSold() view returns (uint256)',
  'function MIN_INITIAL_PHASE_SOLD() view returns (uint256)',
]);

const tokenAbi = parseAbi([
  'function balanceOf(address) view returns (uint256)',
]);

const factoryAbi = parseAbi([
  'function marketsCount() view returns (uint256)',
  'function proposals(uint256) view returns (address)',
]);

const arbitrationAbi = parseAbi([
  'function baseX() view returns (uint256)',
  'function getProposal(uint256) view returns ((uint256 minActivationBond, (address bidder, uint256 amount) yesBond, (address bidder, uint256 amount) noBond, uint8 state, uint64 lastStateChangeAt, bool settled, bool accepted, uint32 queuePosition, bool exists))',
]);

const publicClient = createPublicClient({
  chain: sepoliaFork,
  transport: http(RPC_URL),
});
const PUBLIC_SEPOLIA_RPC_HOST = new URL(PUBLIC_SEPOLIA_RPC).host;

async function readInstancesCount() {
  return await publicClient.readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'instancesCount',
  });
}

async function readInstance(id) {
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

async function readSaleSnapshot(saleAddress) {
  const [priceWei, initialSold, minInitialSold] = await Promise.all([
    publicClient.readContract({
      address: saleAddress,
      abi: saleAbi,
      functionName: 'currentPriceWeiPerToken',
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
  ]);

  return { priceWei, initialSold, minInitialSold };
}

async function readTokenBalance(tokenAddress, account) {
  return await publicClient.readContract({
    address: tokenAddress,
    abi: tokenAbi,
    functionName: 'balanceOf',
    args: [account],
  });
}

async function readFactoryMarketsCount(factoryAddress) {
  return await publicClient.readContract({
    address: factoryAddress,
    abi: factoryAbi,
    functionName: 'marketsCount',
  });
}

async function readFactoryProposal(factoryAddress, index) {
  return await publicClient.readContract({
    address: factoryAddress,
    abi: factoryAbi,
    functionName: 'proposals',
    args: [index],
  });
}

async function readArbitrationBaseX(arbitrationAddress) {
  return await publicClient.readContract({
    address: arbitrationAddress,
    abi: arbitrationAbi,
    functionName: 'baseX',
  });
}

async function readArbitrationProposal(arbitrationAddress, proposalId) {
  const p = await publicClient.readContract({
    address: arbitrationAddress,
    abi: arbitrationAbi,
    functionName: 'getProposal',
    args: [proposalId],
  });

  return {
    minActivationBond: p.minActivationBond ?? p[0],
    yesBond: {
      bidder: p.yesBond?.bidder ?? p[1]?.bidder ?? p[1]?.[0],
      amount: p.yesBond?.amount ?? p[1]?.amount ?? p[1]?.[1],
    },
    noBond: {
      bidder: p.noBond?.bidder ?? p[2]?.bidder ?? p[2]?.[0],
      amount: p.noBond?.amount ?? p[2]?.amount ?? p[2]?.[1],
    },
    state: Number(p.state ?? p[3]),
    exists: p.exists ?? p[8],
  };
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

function runCast(args, description, timeout = 120_000) {
  try {
    execFileSync(CAST_BIN, args, {
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

function castSend(contract, signature, signatureArgs, { gasLimit = '6000000', value } = {}) {
  const args = [
    'send',
    contract,
    signature,
    ...signatureArgs,
    '--rpc-url',
    RPC_URL,
    '--private-key',
    ANVIL_PRIVATE_KEY,
    '--gas-limit',
    gasLimit,
  ];
  if (value != null) args.push('--value', String(value));

  runCast(args, `cast send ${signature}`);
}

function castSendCreatePart1({ name, symbol, description }) {
  castSend(
    REGISTRY,
    'createFutarchyPart1(string,string,string,uint256,uint256,uint256,uint32,uint32,uint256)',
    [
      name,
      symbol,
      description,
      '100000000000000',   // 0.0001 ETH initial price
      '10',                // min initial phase sold, whole-token units
      '3600',              // initial sale duration, seconds
      '7200',              // arbitration timeout, seconds
      '3600',              // TWAP window, seconds
      '1000000000000000',  // 0.001 WETH base bond
    ],
    { gasLimit: '6000000' },
  );
}

async function createPart1Instance({ name, symbol, description }) {
  const id = await readInstancesCount();

  castSendCreatePart1({ name, symbol, description });

  await expect.poll(readInstancesCount, {
    timeout: 30_000,
    message: 'registry.instancesCount() should increment after cast send',
  }).toBe(id + 1n);

  return { id, inst: await readInstance(id) };
}

async function createReadyInstance({ name, symbol, description }) {
  const created = await createPart1Instance({ name, symbol, description });

  castSend(
    REGISTRY,
    'createFutarchyPart2(uint256)',
    [created.id.toString()],
    { gasLimit: '15000000' },
  );

  await expect.poll(async () => (await readInstance(created.id)).status, {
    timeout: 60_000,
    message: 'registry instance should become READY after cast createFutarchyPart2',
  }).toBe(2);

  return { id: created.id, inst: await readInstance(created.id) };
}

async function createFactoryProposal(inst, { name, description }) {
  const index = await readFactoryMarketsCount(inst.factory);
  const tupleArg = `(${name},${description},${inst.token},${WETH})`;

  castSend(
    inst.factory,
    'createProposal((string,string,address,address))',
    [tupleArg],
    { gasLimit: '6000000' },
  );

  await expect.poll(() => readFactoryMarketsCount(inst.factory), {
    timeout: 30_000,
    message: 'factory.marketsCount() should increment after cast createProposal',
  }).toBe(index + 1n);

  return { index, proposal: await readFactoryProposal(inst.factory, index) };
}

function castDepositWeth(amount) {
  castSend(WETH, 'deposit()', [], { value: amount.toString(), gasLimit: '100000' });
}

function castApproveWeth(spender, amount) {
  castSend(WETH, 'approve(address,uint256)', [spender, amount.toString()], { gasLimit: '100000' });
}

async function createProposalWithYesBond({ instanceLabel, symbolPrefix, proposalLabel }) {
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `${symbolPrefix}${suffix}`.slice(0, 10);
  const { id, inst } = await createReadyInstance({
    name: `Fork ${instanceLabel} ${suffix}`,
    symbol,
    description: 'Proposal and bond mutation target for fork-state.read-only.spec.ts.',
  });
  const proposalName = `Fork ${proposalLabel} ${suffix}`;
  const { proposal } = await createFactoryProposal(inst, {
    name: proposalName,
    description: 'Cast-created proposal for a read-only fork-state bond assertion.',
  });
  const proposalId = BigInt(proposal);
  const baseX = await readArbitrationBaseX(inst.arbitration);

  castDepositWeth(baseX);
  castApproveWeth(inst.arbitration, baseX);
  castSend(
    inst.arbitration,
    'createProposalWithId(uint256,uint256)',
    [proposal, baseX.toString()],
    { gasLimit: '200000' },
  );
  castSend(
    inst.arbitration,
    'placeYesBond(uint256,uint256)',
    [proposal, baseX.toString()],
    { gasLimit: '250000' },
  );

  await expect.poll(async () => {
    const p = await readArbitrationProposal(inst.arbitration, proposalId);
    return `${p.state}:${p.yesBond.amount}`;
  }, {
    timeout: 30_000,
    message: 'arbitration proposal should move to YES with the cast bond amount',
  }).toBe(`1:${baseX}`);

  return { id, inst, proposalName, proposal, proposalId, baseX };
}

async function routePublicRpcToFork(page) {
  const corsHeaders = {
    'access-control-allow-origin': '*',
    'access-control-allow-methods': 'POST, OPTIONS',
    'access-control-allow-headers': 'content-type',
  };

  await page.route(`**://${PUBLIC_SEPOLIA_RPC_HOST}/**`, async (route, request) => {
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

test.describe('fork state — read-only UI over cast mutations', () => {
  test.describe.configure({ mode: 'serial' });

  test.beforeAll(async ({}, testInfo) => {
    if (testInfo.project.name !== 'fork') return;
    await ensureAnvilFork();
  });

  test.beforeEach(async ({ page }) => {
    await routePublicRpcToFork(page);
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

    await createPart1Instance({
      name: `Fork State ${suffix}`,
      symbol,
      description: 'Created by fork-state.read-only.spec.ts via cast send.',
    });

    await page.reload({ waitUntil: 'domcontentloaded' });

    await expect.poll(() => rows.count(), {
      timeout: 30_000,
      message: 'home table should show the cast-created instance after reload',
    }).toBe(expectedBeforeRows + 1);

    const newRow = page.getByTestId('rankings-rows').locator(`[data-rank-instance-id="${newId}"]`);
    await expect(newRow).toBeVisible();
    await expect(newRow).toContainText(symbol);
  });

  test('sale page reflects cast buy balance without wallet signing', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'fork', 'fork-state specs require the Playwright fork project');

    await page.addInitScript((connectedWallet) => {
      window.connectedWallet = connectedWallet;
    }, ANVIL_ADDRESS);

    const suffix = Date.now().toString(36).slice(-6).toUpperCase();
    const symbol = `BUY${suffix}`.slice(0, 10);
    const { id, inst } = await createPart1Instance({
      name: `Fork Buy ${suffix}`,
      symbol,
      description: 'Sale mutation target for fork-state.read-only.spec.ts.',
    });

    await page.goto(`/sale.html?inst=${id}`);
    await expect(page.getByTestId('trade-buy-amount')).toBeVisible({ timeout: 30_000 });

    const before = await readSaleSnapshot(inst.sale);
    const beforeBalance = await readTokenBalance(inst.token, ANVIL_ADDRESS);
    const amount = 3n;
    const costWei = before.priceWei * amount;

    castSend(
      inst.sale,
      'buy(uint256)',
      [amount.toString()],
      { value: costWei.toString(), gasLimit: '250000' },
    );

    await expect.poll(async () => (await readSaleSnapshot(inst.sale)).initialSold, {
      timeout: 30_000,
      message: 'sale.initialTokensSold() should increment after cast buy',
    }).toBe(before.initialSold + amount);
    await expect.poll(() => readTokenBalance(inst.token, ANVIL_ADDRESS), {
      timeout: 30_000,
      message: 'cast buyer token balance should increment',
    }).toBe(beforeBalance + amount * 10n ** 18n);

    await page.reload({ waitUntil: 'domcontentloaded' });
    await expect(page.getByTestId('trade-buy-amount')).toBeVisible({ timeout: 30_000 });

    const expectedSold = `${before.initialSold + amount} / ${before.minInitialSold} ${symbol}`;
    await expect.poll(() => page.locator('#sale-initial-sold').textContent(), {
      timeout: 30_000,
      message: 'sale stats should show cast-updated initialTokensSold',
    }).toBe(expectedSold);
    await expect.poll(() => page.locator('#sale-balance').textContent(), {
      timeout: 30_000,
      message: 'sale balance should show cast buyer token balance',
    }).toContain(`3.00 ${symbol}`);
  });

  test('proposals page reflects cast-placed YES bond without wallet signing', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'fork', 'fork-state specs require the Playwright fork project');

    const suffix = Date.now().toString(36).slice(-6).toUpperCase();
    const symbol = `BND${suffix}`.slice(0, 10);
    const { id, inst } = await createReadyInstance({
      name: `Fork Bond ${suffix}`,
      symbol,
      description: 'Proposal and bond mutation target for fork-state.read-only.spec.ts.',
    });
    const proposalName = `Fork YES ${suffix}`;
    const { proposal } = await createFactoryProposal(inst, {
      name: proposalName,
      description: 'Cast-created proposal for a read-only fork-state bond assertion.',
    });
    const arbitrationProposalId = BigInt(proposal);

    await page.goto(`/proposals.html?inst=${id}`);
    const proposalList = page.locator('#sep-proposals');
    await expect(proposalList).toContainText(proposalName, { timeout: 30_000 });
    const card = proposalList.locator('.sep-card', { hasText: proposalName });
    await expect.poll(() => card.locator('.bond-state').textContent(), {
      timeout: 30_000,
      message: 'proposal card should render the initial arbitration chip',
    }).toBe('INACTIVE');

    const baseX = await readArbitrationBaseX(inst.arbitration);
    castDepositWeth(baseX);
    castApproveWeth(inst.arbitration, baseX);
    castSend(
      inst.arbitration,
      'createProposalWithId(uint256,uint256)',
      [proposal, baseX.toString()],
      { gasLimit: '200000' },
    );
    castSend(
      inst.arbitration,
      'placeYesBond(uint256,uint256)',
      [proposal, baseX.toString()],
      { gasLimit: '250000' },
    );

    await expect.poll(async () => {
      const p = await readArbitrationProposal(inst.arbitration, arbitrationProposalId);
      return `${p.state}:${p.yesBond.amount}`;
    }, {
      timeout: 30_000,
      message: 'arbitration proposal should move to YES with the cast bond amount',
    }).toBe(`1:${baseX}`);

    await page.reload({ waitUntil: 'domcontentloaded' });

    await expect(proposalList).toContainText(proposalName, { timeout: 30_000 });
    await expect.poll(() => card.locator('.bond-state').textContent(), {
      timeout: 30_000,
      message: 'proposal card should show the cast-updated YES chip after reload',
    }).toBe('YES');
    await expect(card.locator('.bond-panel')).toContainText('YES bond');
    await expect(card.locator('.bond-panel')).toContainText('0.001 WETH');
    await expect(card.locator('.bond-panel')).toContainText(ANVIL_ADDRESS.slice(0, 6));
  });

  test('proposals page reflects cast-placed NO bond without wallet signing', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'fork', 'fork-state specs require the Playwright fork project');

    const { id, inst, proposalName, proposal, proposalId, baseX } = await createProposalWithYesBond({
      instanceLabel: 'No Bond',
      symbolPrefix: 'NOB',
      proposalLabel: 'NO',
    });

    await page.goto(`/proposals.html?inst=${id}`);
    const proposalList = page.locator('#sep-proposals');
    await expect(proposalList).toContainText(proposalName, { timeout: 30_000 });
    const card = proposalList.locator('.sep-card', { hasText: proposalName });
    await expect.poll(() => card.locator('.bond-state').textContent(), {
      timeout: 30_000,
      message: 'proposal card should render the setup YES chip before NO mutation',
    }).toBe('YES');

    castDepositWeth(baseX);
    castApproveWeth(inst.arbitration, baseX);
    castSend(
      inst.arbitration,
      'placeNoBond(uint256)',
      [proposal],
      { gasLimit: '250000' },
    );

    await expect.poll(async () => {
      const p = await readArbitrationProposal(inst.arbitration, proposalId);
      return `${p.state}:${p.noBond.amount}`;
    }, {
      timeout: 30_000,
      message: 'arbitration proposal should move to NO with the cast bond amount',
    }).toBe(`2:${baseX}`);

    await page.reload({ waitUntil: 'domcontentloaded' });

    await expect(proposalList).toContainText(proposalName, { timeout: 30_000 });
    await expect.poll(() => card.locator('.bond-state').textContent(), {
      timeout: 30_000,
      message: 'proposal card should show the cast-updated NO chip after reload',
    }).toBe('NO');
    await expect(card.locator('.bond-panel')).toContainText('NO bond');
    await expect(card.locator('.bond-panel')).toContainText('0.001 WETH');
    await expect(card.locator('.bond-panel')).toContainText(ANVIL_ADDRESS.slice(0, 6));
  });

  test('proposals page reflects cast try-graduate without wallet signing', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'fork', 'fork-state specs require the Playwright fork project');

    const { id, inst, proposalName, proposal, proposalId, baseX } = await createProposalWithYesBond({
      instanceLabel: 'Graduate',
      symbolPrefix: 'GRD',
      proposalLabel: 'GRAD',
    });

    await page.goto(`/proposals.html?inst=${id}`);
    const proposalList = page.locator('#sep-proposals');
    await expect(proposalList).toContainText(proposalName, { timeout: 30_000 });
    const card = proposalList.locator('.sep-card', { hasText: proposalName });
    await expect.poll(() => card.locator('.bond-state').textContent(), {
      timeout: 30_000,
      message: 'proposal card should render the setup YES chip before graduation',
    }).toBe('YES');

    castSend(
      inst.arbitration,
      'tryGraduate(uint256)',
      [proposal],
      { gasLimit: '250000' },
    );

    await expect.poll(async () => {
      const p = await readArbitrationProposal(inst.arbitration, proposalId);
      return `${p.state}:${p.yesBond.amount}`;
    }, {
      timeout: 30_000,
      message: 'arbitration proposal should move to QUEUED after cast tryGraduate',
    }).toBe(`3:${baseX}`);

    await page.reload({ waitUntil: 'domcontentloaded' });

    await expect(proposalList).toContainText(proposalName, { timeout: 30_000 });
    await expect.poll(() => card.locator('.bond-state').textContent(), {
      timeout: 30_000,
      message: 'proposal card should show the cast-updated QUEUED chip after reload',
    }).toBe('QUEUED');
    await expect(card.locator('.bond-panel')).toContainText('YES bond');
    await expect(card.locator('.bond-panel')).toContainText('0.001 WETH');
    await expect(card.locator('.bond-panel')).toContainText('Queued for evaluation');
  });
});
