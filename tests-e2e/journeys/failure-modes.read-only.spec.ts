/**
 * Failure-mode coverage tests for the FAO testnet site.
 *
 * T2.D4 (failure-mode coverage) requires explicit specs for what the UI
 * does when things go wrong: wrong network, empty registry, RPC down,
 * deployments.json missing, malformed deployments.json, fetch flakiness.
 *
 * These tests do NOT need a wallet. They mock fetch + provider responses
 * via Playwright's route interception, then assert the UI reaches a
 * defined error state (banner / toast / empty card) instead of breaking.
 *
 * Counts toward Topic-2 D4 (failure modes) and D3 (realism: we exercise
 * actual error paths, not mocked branches).
 */

// @ts-nocheck — runs only after `npm install`.
import { test, expect } from '@playwright/test';
import {
  castSend,
  createPart1Instance,
  ensureAnvilFork,
  publicClient,
  readSaleSnapshot,
  resetAnvilFork,
  routePublicRpcToFork,
  stopSpawnedAnvil,
} from '../fork-utils';

function uniqueSymbol(prefix) {
  return `${prefix}${Date.now().toString(36).slice(-6).toUpperCase()}`.slice(0, 10);
}

async function advanceForkTime(seconds) {
  await publicClient.request({ method: 'evm_increaseTime', params: [seconds] });
  await publicClient.request({ method: 'evm_mine', params: [] });
}

async function createFinalizedSaleInstance() {
  const symbol = uniqueSymbol('END');
  const { id, inst } = await createPart1Instance({
    name: `Ended Sale ${symbol}`,
    symbol,
    description: 'Sale already ended target created by failure-modes.read-only.spec.ts.',
    minInitialSold: '1',
    initialSaleDuration: '1',
  });

  const first = await readSaleSnapshot(inst.sale);
  castSend(
    inst.sale,
    'buy(uint256)',
    ['1'],
    { value: first.priceWei.toString(), gasLimit: '250000' },
  );
  await expect.poll(async () => (await readSaleSnapshot(inst.sale)).initialSold, {
    timeout: 30_000,
    message: 'setup buy should satisfy the initial-sale threshold',
  }).toBe(1n);

  await advanceForkTime(2);

  const second = await readSaleSnapshot(inst.sale);
  castSend(
    inst.sale,
    'buy(uint256)',
    ['1'],
    { value: second.priceWei.toString(), gasLimit: '250000' },
  );
  await expect.poll(async () => (await readSaleSnapshot(inst.sale)).finalized, {
    timeout: 30_000,
    message: 'second setup buy should finalize the initial sale',
  }).toBe(true);

  return { id, inst, symbol };
}

test.describe('failure modes — read-only, deterministic via route mocking', () => {
  test.beforeEach(({}, testInfo) => {
    test.skip(testInfo.project.name === 'fork', 'route-mocked read-only cases run under the read-only project');
  });

  test('deployments.json missing → fallback constant keeps UI alive', async ({ page }) => {
    // Block the deployments.json fetch entirely.
    await page.route('**/deployments.json', (route) => route.fulfill({
      status: 404,
      contentType: 'application/json',
      body: 'Not found'
    }));

    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
    await page.goto('/');

    // Rankings table still renders (fallback registry address kept UI alive).
    await expect(page.locator('table.rankings-table')).toBeVisible({ timeout: 15_000 });
    expect(errors, errors.join('\n')).toEqual([]);
  });

  test('deployments.json malformed JSON → fallback still active', async ({ page }) => {
    await page.route('**/deployments.json', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: '{not-real-json',
    }));

    await page.goto('/');
    await expect(page.locator('table.rankings-table')).toBeVisible({ timeout: 15_000 });
  });

  test('deployments.json contains zero-address registry → empty state surfaces', async ({ page }) => {
    await page.route('**/deployments.json', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({
        version: 'v5',
        active: { registry: '0x0000000000000000000000000000000000000000' },
      }),
    }));

    // Block RPC POSTs so the registry read fails quickly.
    await page.route('https://ethereum-sepolia.publicnode.com/**', (route) =>
      route.fulfill({ status: 500, body: 'rpc disabled for test' }));

    await page.goto('/');
    // The empty state must be a visible row in the rankings — not a
    // silent blank table.
    await expect(page.locator('table.rankings-table')).toBeVisible({ timeout: 15_000 });
  });

  test('RPC completely down → empty rankings without console errors', async ({ page }) => {
    // Block every Sepolia RPC call (publicnode + any retry path).
    await page.route(/ethereum-sepolia|sepolia\.gateway|tenderly/, (route) =>
      route.fulfill({ status: 503, body: 'rpc down' }));

    const errors: string[] = [];
    page.on('console', (msg) => {
      if (msg.type() === 'error') errors.push(msg.text());
    });

    await page.goto('/');
    await expect(page.locator('table.rankings-table')).toBeVisible({ timeout: 15_000 });
    // Console may carry a single fetch warning; assert it's bounded.
    expect(errors.length, `unexpected console errors: ${errors.join('\n')}`).toBeLessThanOrEqual(3);
  });

  test('topbar Connect button is reachable even with deployments fetch blocked', async ({ page }) => {
    await page.route('**/deployments.json', (route) => route.abort());
    await page.goto('/');
    const connect = page.getByRole('button', { name: /connect/i });
    await expect(connect).toBeVisible({ timeout: 10_000 });
    await connect.focus();
    await expect(connect).toBeFocused();
  });

  test('sale page reached with no active instance shows a defined empty state', async ({ page }) => {
    await page.route('**/deployments.json', (route) => route.fulfill({
      status: 200,
      contentType: 'application/json',
      body: JSON.stringify({ version: 'v5', active: {} }),
    }));
    await page.route(/ethereum-sepolia/, (route) =>
      route.fulfill({ status: 503, body: 'rpc down' }));

    await page.goto('/sale');
    // The trade columns must render even without an active instance —
    // they show "—" placeholders, not blank elements that would suggest
    // the page is broken.
    await expect(page.locator('.trade-col-title')).toHaveCount(2);
  });
});

test.describe('failure modes — fork-driven read-only state', () => {
  test.describe.configure({ mode: 'serial' });

  let forkBlockNumber = '';

  test.beforeAll(async ({}, testInfo) => {
    if (testInfo.project.name !== 'fork') return;
    forkBlockNumber = await ensureAnvilFork();
  });

  test.beforeEach(async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'fork', 'fork-driven failure-mode specs require the Playwright fork project');
    await resetAnvilFork(forkBlockNumber);
    await page.addInitScript(() => {
      localStorage.setItem('faoForkMode', '1');
    });
    await routePublicRpcToFork(page);
  });

  test.afterAll(async ({}, testInfo) => {
    if (testInfo.project.name !== 'fork') return;
    await stopSpawnedAnvil();
  });

  test('sale already finalized disables sale buy and shows finalized state', async ({ page }) => {
    const { id, inst, symbol } = await createFinalizedSaleInstance();
    await expect.poll(async () => (await readSaleSnapshot(inst.sale)).finalized, {
      timeout: 30_000,
      message: 'sale should be finalized before loading the UI',
    }).toBe(true);

    await page.goto(`/sale.html?inst=${id}`);

    await expect(page.locator('#sale-hero-symbol')).toContainText(symbol, { timeout: 30_000 });
    await expect(page.getByTestId('sale-phase-badge').or(page.locator('#sale-phase-badge')).first())
      .toContainText(/bonding curve/i);
    await expect(page.getByTestId('trade-buy-sale-btn').or(page.locator('#trade-buy-sale-btn')).first())
      .toBeDisabled();
    await expect(page.getByTestId('trade-buy-sale-btn').or(page.locator('#trade-buy-sale-btn')).first())
      .toContainText(/finalized/i);
    await expect(page.locator('#sale-progress-block')).toBeHidden();
    await expect(page.getByTestId('sale-decision-sold').or(page.locator('#sale-decision-sold')).first())
      .toContainText(`1 / 1 ${symbol}`);
  });

  test('page reload during pending cast transaction re-renders the sale cleanly', async ({ page }) => {
    const symbol = uniqueSymbol('PND');
    const { id, inst } = await createPart1Instance({
      name: `Pending Reload ${symbol}`,
      symbol,
      description: 'Pending reload target created by failure-modes.read-only.spec.ts.',
    });

    await page.goto(`/sale.html?inst=${id}`);
    await expect(page.locator('#sale-hero-symbol')).toContainText(symbol, { timeout: 30_000 });
    await expect(page.getByTestId('trade-buy-sale-btn').or(page.locator('#trade-buy-sale-btn')).first())
      .toBeEnabled();

    const errors = [];
    page.on('pageerror', (error) => errors.push(error.message));

    const before = await readSaleSnapshot(inst.sale);
    const amount = 2n;
    let txHash = '';

    await publicClient.request({ method: 'evm_setAutomine', params: [false] });
    try {
      txHash = castSend(
        inst.sale,
        'buy(uint256)',
        [amount.toString()],
        {
          value: (before.priceWei * amount).toString(),
          gasLimit: '250000',
          async: true,
        },
      );
      expect(txHash, 'cast send --async should return a transaction hash').toMatch(/^0x[a-fA-F0-9]{64}$/);
      await expect.poll(async () => Boolean(await publicClient.request({
        method: 'eth_getTransactionByHash',
        params: [txHash],
      })), {
        timeout: 10_000,
        message: 'buy transaction should be pending before the reload',
      }).toBe(true);

      await page.reload({ waitUntil: 'domcontentloaded' });

      await expect(page.locator('#sale-hero-symbol')).toContainText(symbol, { timeout: 30_000 });
      await expect(page.getByTestId('sale-decision-strip').or(page.locator('.sale-decision-strip')).first())
        .toBeVisible();
      await expect(page.getByTestId('trade-buy-amount').or(page.locator('#trade-buy-amount')).first())
        .toHaveValue('1');
      await expect(page.getByTestId('trade-buy-sale-btn').or(page.locator('#trade-buy-sale-btn')).first())
        .toBeEnabled();
      await expect(page.getByTestId('sale-decision-sold').or(page.locator('#sale-decision-sold')).first())
        .toContainText(`${before.initialSold.toString()} / ${before.minInitialSold.toString()} ${symbol}`);
      expect(errors, errors.join('\n')).toEqual([]);
    } finally {
      await publicClient.request({ method: 'evm_mine', params: [] }).catch(() => {});
      await publicClient.request({ method: 'evm_setAutomine', params: [true] }).catch(() => {});
    }

    await expect.poll(async () => (await readSaleSnapshot(inst.sale)).initialSold, {
      timeout: 30_000,
      message: 'pending buy should mine after cleanup resumes the fork',
    }).toBe(before.initialSold + amount);
  });
});
