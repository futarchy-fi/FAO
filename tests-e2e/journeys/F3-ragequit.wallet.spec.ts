/**
 * F3 — Ragequit tokens from an active instance sale.
 *
 * Persona: holder who first buys through the sale, then burns one token for
 * the sale treasury share.
 */

// @ts-nocheck — runs only after npm install.
import {
  activeInstance,
  confirmOneTransaction,
  connectTopbarWallet,
  ensureWalletCache,
  erc20Abi,
  expect,
  publicClient,
  readContract,
  saleAbi,
  test,
} from '../wallet.fixture';

const INSTANCE_ID = Number(process.env.FAO_TEST_INSTANCE_ID || '0');
const TOKEN_UNIT = 10n ** 18n;

function byTestIdOrId(page, testId, id) {
  return page.getByTestId(testId).or(page.locator(`#${id}`)).first();
}

function createField(page, testId, id) {
  return page.getByTestId(testId).or(page.locator(`#${id}`)).first();
}

function createStatus(page) {
  return page.getByTestId('create-status').or(page.locator('#create-instance-status')).first();
}

async function createInstanceThroughUi(page, metamask) {
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `F3${suffix}`.slice(0, 10);

  await page.goto('/create');
  await expect(page).toHaveURL(/\/create/);
  await expect(createField(page, 'create-name', 'ci-name')).toBeVisible();

  await connectTopbarWallet(page, metamask);

  await createField(page, 'create-name', 'ci-name').fill(`F3 E2E ${suffix}`);
  await createField(page, 'create-symbol', 'ci-symbol').fill(symbol);
  await createField(page, 'create-description', 'ci-description').fill('Created by F3-ragequit.wallet.spec.ts against Anvil.');
  await createField(page, 'create-price', 'ci-price').fill('0.0001');
  await createField(page, 'create-min-sold', 'ci-min-sold').fill('10');
  await createField(page, 'create-sale-duration', 'ci-sale-duration').fill('60');
  await createField(page, 'create-timeout', 'ci-timeout').fill('120');
  await createField(page, 'create-twap', 'ci-twap').fill('60');
  await createField(page, 'create-bond', 'ci-bond').fill('0.001');

  const status = createStatus(page);
  await page.getByTestId('create-submit').or(page.getByRole('button', { name: /^create futarchy$/i })).first().click();
  await expect(status).toContainText(/Step 1\/2/i, { timeout: 15_000 });
  await expect(status).toContainText(/Step 2\/2/i, { timeout: 120_000 });
  await expect(status).toContainText(/Done/i, { timeout: 180_000 });
  await page.waitForURL(/\/\?inst=\d+/, { timeout: 30_000 });

  const id = Number(new URL(page.url()).searchParams.get('inst'));
  expect(Number.isFinite(id)).toBe(true);
  return id;
}

test.setTimeout(360_000);

test.beforeAll(async () => {
  await ensureWalletCache();
});

async function buyTokens(page, metamask, inst, holder, amount) {
  const beforeBalance = await readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [holder],
  });

  await byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount').fill(String(amount));
  await byTestIdOrId(page, 'trade-buy-sale-btn', 'trade-buy-sale-btn').click();
  await expect(page.getByTestId('sale-confirm-card').or(page.locator('#sale-confirm-card')).first()).toBeVisible();
  await confirmOneTransaction(page, metamask, () => byTestIdOrId(page, 'sale-confirm-go', 'sale-confirm-go').click());

  await expect.poll(() => readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [holder],
  }), {
    timeout: 30_000,
    message: `holder token balance should increase by ${amount} whole tokens`,
  }).toBe(beforeBalance + BigInt(amount) * TOKEN_UNIT);
}

test('F3-ragequit happy path', async ({ page, metamask }) => {
  const instanceId = process.env.FAO_TEST_INSTANCE_ID == null ? await createInstanceThroughUi(page, metamask) : INSTANCE_ID;
  const inst = await activeInstance(instanceId);

  await page.goto(`/sale?inst=${instanceId}`);
  await expect(page.locator('#sale-hero-symbol')).toContainText(inst.symbol, { timeout: 30_000 });

  const wallet = await connectTopbarWallet(page, metamask);
  const holder = wallet.toLowerCase();

  await buyTokens(page, metamask, inst, holder, 2);

  const burnWholeTokens = 1n;
  const burnAmount = burnWholeTokens * TOKEN_UNIT;
  const beforeBalance = await readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [holder],
  });
  expect(beforeBalance).toBeGreaterThanOrEqual(burnAmount);

  const beforeSupply = await readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'totalSupply',
  });
  const beforeSaleEth = await publicClient.getBalance({ address: inst.sale });
  const quote = await readContract({
    address: inst.sale,
    abi: saleAbi,
    functionName: 'quoteRagequit',
    args: [burnWholeTokens],
  });
  expect(quote).toBeGreaterThan(0n);

  await byTestIdOrId(page, 'trade-sell-amount', 'trade-sell-amount').fill(String(burnWholeTokens));
  await byTestIdOrId(page, 'trade-sell-rq-btn', 'trade-sell-rq-btn').click();
  await expect(page.getByTestId('sale-confirm-card').or(page.locator('#sale-confirm-card')).first()).toBeVisible();
  await confirmOneTransaction(page, metamask, () => byTestIdOrId(page, 'sale-confirm-go', 'sale-confirm-go').click());

  await expect.poll(() => readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [holder],
  }), {
    timeout: 30_000,
    message: 'holder token balance should decrease by one token after ragequit',
  }).toBe(beforeBalance - burnAmount);

  await expect.poll(() => readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'totalSupply',
  }), {
    timeout: 30_000,
    message: 'token totalSupply should decrease by one token after ragequit',
  }).toBe(beforeSupply - burnAmount);

  await expect.poll(() => publicClient.getBalance({ address: inst.sale }), {
    timeout: 30_000,
    message: 'sale treasury ETH should decrease by the quoted ragequit amount',
  }).toBe(beforeSaleEth - quote);
});

test.fixme('F3-ragequit — wallet rejection', async ({ page }) => {
  // The buyer rejects the MetaMask popup. Site shows inline error,
  // does NOT proceed past the pre-confirm card, no chain state mutates.
});

test.fixme('F3-ragequit — wrong chain', async ({ page }) => {
  // Wallet is on mainnet. Site triggers wallet_switchEthereumChain before
  // dispatching the tx. If user rejects the switch, status surfaces it.
});

test.fixme('F3-ragequit — RPC 5xx during dispatch', async ({ page }) => {
  // The Sepolia RPC returns 500 mid-tx-submit. Site shows a retryable
  // error; no partial state.
});
