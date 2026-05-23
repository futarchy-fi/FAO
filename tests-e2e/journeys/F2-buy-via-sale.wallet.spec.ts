/**
 * F2 — Buy tokens from an active instance sale.
 *
 * Persona: buyer using MetaMask on an Anvil Sepolia fork.
 */

// @ts-nocheck — runs only after npm install.
import {
  activeInstance,
  confirmOneTransaction,
  connectTopbarWallet,
  ensureWalletCache,
  erc20Abi,
  expect,
  readContract,
  saleAbi,
  test,
} from '../wallet.fixture';

const INSTANCE_ID = process.env.FAO_TEST_INSTANCE_ID == null ? null : Number(process.env.FAO_TEST_INSTANCE_ID);
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
  const symbol = `F2${suffix}`.slice(0, 10);

  await page.goto('/create.html');
  await expect(page).toHaveURL(/\/create/);
  await expect(createField(page, 'create-name', 'ci-name')).toBeVisible();

  await connectTopbarWallet(page, metamask);

  await createField(page, 'create-name', 'ci-name').fill(`F2 E2E ${suffix}`);
  await createField(page, 'create-symbol', 'ci-symbol').fill(symbol);
  await createField(page, 'create-description', 'ci-description').fill('Created by F2-buy-via-sale.wallet.spec.ts against Anvil.');
  await createField(page, 'create-price', 'ci-price').fill('0.0001');
  await createField(page, 'create-min-sold', 'ci-min-sold').fill('10');
  await createField(page, 'create-sale-duration', 'ci-sale-duration').fill('60');
  await createField(page, 'create-timeout', 'ci-timeout').fill('120');
  await createField(page, 'create-twap', 'ci-twap').fill('60');
  await createField(page, 'create-bond', 'ci-bond').fill('0.001');

  const status = createStatus(page);
  await page.getByTestId('create-submit').or(page.getByRole('button', { name: /^create futarchy$/i })).first().click();
  await expect(page.getByTestId('confirm-card-create').or(page.locator('#confirm-card-create')).first()).toBeVisible();
  await confirmOneTransaction(page, metamask, () => (
    page.getByTestId('confirm-card-create-confirm').or(page.locator('#confirm-card-create-confirm')).first().click()
  ));
  await expect(status).toContainText(/Step 1\/2/i, { timeout: 15_000 });
  await expect(status).toContainText(/Step 2\/2/i, { timeout: 120_000 });
  await expect(status).toContainText(/Done/i, { timeout: 180_000 });
  await page.waitForURL(/\/\?inst=\d+/, { timeout: 30_000 });

  const id = Number(new URL(page.url()).searchParams.get('inst'));
  expect(Number.isFinite(id)).toBe(true);
  return id;
}

test.setTimeout(300_000);

test.beforeAll(async () => {
  await ensureWalletCache();
});

test('F2-buy-via-sale happy path', async ({ page, metamask }) => {
  const instanceId = INSTANCE_ID == null ? await createInstanceThroughUi(page, metamask) : INSTANCE_ID;
  const inst = {
    id: instanceId,
    ...(await activeInstance(instanceId)),
  };

  await page.goto(`/sale.html?inst=${inst.id}`);
  await expect(page.locator('#sale-hero-symbol')).toContainText(inst.symbol, { timeout: 30_000 });

  const wallet = await connectTopbarWallet(page, metamask);
  const buyer = wallet.toLowerCase();

  const beforeRaised = await readContract({
    address: inst.sale,
    abi: saleAbi,
    functionName: 'totalAmountRaised',
  });
  const price = await readContract({
    address: inst.sale,
    abi: saleAbi,
    functionName: 'currentPriceWeiPerToken',
  });
  const beforeBalance = await readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [buyer],
  });

  await byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount').fill('1');
  await byTestIdOrId(page, 'trade-buy-sale-btn', 'trade-buy-sale-btn').click();
  await expect(page.getByTestId('sale-confirm-card').or(page.locator('#sale-confirm-card')).first()).toBeVisible();

  await confirmOneTransaction(page, metamask, () => byTestIdOrId(page, 'sale-confirm-go', 'sale-confirm-go').click());

  await expect.poll(() => readContract({
    address: inst.sale,
    abi: saleAbi,
    functionName: 'totalAmountRaised',
  }), {
    timeout: 30_000,
    message: 'sale.totalAmountRaised() should increase by the buy cost',
  }).toBe(beforeRaised + price);

  await expect.poll(() => readContract({
    address: inst.token,
    abi: erc20Abi,
    functionName: 'balanceOf',
    args: [buyer],
  }), {
    timeout: 30_000,
    message: 'buyer token balance should increase by one whole token',
  }).toBe(beforeBalance + TOKEN_UNIT);

  await expect(page.locator('#sale-balance')).toContainText(/1(\.0+)?\s+/);
});

test.fixme('F2-buy-via-sale — wallet rejection', async ({ page }) => {
  // The buyer rejects the MetaMask popup. Site shows inline error,
  // does NOT proceed past the pre-confirm card, no chain state mutates.
});

test.fixme('F2-buy-via-sale — wrong chain', async ({ page }) => {
  // Wallet is on mainnet. Site triggers wallet_switchEthereumChain before
  // dispatching the tx. If user rejects the switch, status surfaces it.
});

test.fixme('F2-buy-via-sale — RPC 5xx during dispatch', async ({ page }) => {
  // The Sepolia RPC returns 500 mid-tx-submit. Site shows a retryable
  // error; no partial state.
});
