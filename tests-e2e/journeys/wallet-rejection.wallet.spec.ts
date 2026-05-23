/**
 * T2.D4 axis — wallet rejection.
 *
 * The user reaches the sale buy confirmation, rejects the MetaMask
 * transaction popup, and the page surfaces an explicit cancelled state while
 * sale treasury state stays unchanged.
 */

// @ts-nocheck — runs only after npm install.
import {
  connectWithMetaMask,
  ensureWalletCache,
  expect,
  switchMetaMaskNetwork,
  test,
} from '../real-metamask.fixture';
import {
  createPart1Instance,
  publicClient,
  readSaleSnapshot,
  saleAbi,
} from '../fork-utils';

function byTestIdOrId(page, testId, id) {
  return page.getByTestId(testId).or(page.locator(`#${id}`)).first();
}

test.setTimeout(240_000);

test.beforeAll(async () => {
  await ensureWalletCache();
});

test('wallet rejection — sale buy reports tx cancelled and does not mutate sale state', async ({ page, metamask }) => {
  await switchMetaMaskNetwork(metamask, 'Sepolia', true).catch(() => {});

  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `REJ${suffix}`.slice(0, 10);
  const { id, inst } = await createPart1Instance({
    name: `Wallet Reject ${suffix}`,
    symbol,
    description: 'Wallet rejection target created by wallet-rejection.wallet.spec.ts.',
  });

  await page.goto(`/sale.html?inst=${id}`);
  await expect(byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount')).toBeVisible({ timeout: 30_000 });
  await expect(page.locator('#sale-hero-symbol')).toContainText(symbol, { timeout: 30_000 });

  await connectWithMetaMask(page, metamask);

  const before = await readSaleSnapshot(inst.sale);
  const confirmCard = page.getByTestId('sale-confirm-card').or(page.locator('#sale-confirm-card')).first();
  const status = page.getByTestId('sale-buy-status').or(page.locator('#sale-buy-status')).first();

  await byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount').fill('1');
  await byTestIdOrId(page, 'trade-buy-sale-btn', 'trade-buy-sale-btn').click();
  await expect(confirmCard).toBeVisible({ timeout: 15_000 });

  await Promise.all([
    metamask.rejectTransaction(),
    byTestIdOrId(page, 'sale-confirm-go', 'sale-confirm-go').click(),
  ]);

  await expect(status).toContainText(/tx cancelled/i, { timeout: 30_000 });
  await expect(status).toHaveClass(/sale-buy-status-error/);
  await expect(confirmCard).toBeVisible();
  await expect(byTestIdOrId(page, 'sale-confirm-go', 'sale-confirm-go')).toBeEnabled();

  await expect.poll(() => publicClient.readContract({
    address: inst.sale,
    abi: saleAbi,
    functionName: 'totalAmountRaised',
  }), {
    timeout: 10_000,
    message: 'rejected MetaMask transaction must not change sale.totalAmountRaised',
  }).toBe(before.totalRaised);
});
