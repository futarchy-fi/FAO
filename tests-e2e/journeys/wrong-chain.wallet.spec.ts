/**
 * T2.D4 axis — wrong chain signing.
 *
 * The user has already connected MetaMask, switches it to Ethereum Mainnet,
 * then tries the sale buy path. The page must surface the Sepolia switch
 * banner instead of constructing a transaction on the wrong chain.
 */

// @ts-nocheck — runs only after npm install.
import {
  connectWithMetaMask,
  ensureWalletCache,
  expect,
  rejectSwitchNetworkRequest,
  setMetaMaskChain,
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

test('wrong chain — sale buy shows Sepolia switch banner and does not dispatch', async ({ page, metamask }) => {
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `WRG${suffix}`.slice(0, 10);
  const { id, inst } = await createPart1Instance({
    name: `Wrong Chain ${suffix}`,
    symbol,
    description: 'Wrong-chain target created by wrong-chain.wallet.spec.ts.',
  });

  await page.goto(`/sale.html?inst=${id}`);
  await expect(byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount')).toBeVisible({ timeout: 30_000 });
  await expect(page.locator('#sale-hero-symbol')).toContainText(symbol, { timeout: 30_000 });

  await connectWithMetaMask(page, metamask);
  await setMetaMaskChain(page, '0x1');
  await expect(page.getByTestId('topbar-connect').or(page.getByRole('button', { name: /^connect/i })).first())
    .toContainText(/connect/i, { timeout: 30_000 });

  const before = await readSaleSnapshot(inst.sale);
  const status = page.getByTestId('sale-buy-status').or(page.locator('#sale-buy-status')).first();
  const banner = page.getByTestId('topbar-status').or(page.locator('#topbar-status')).first();
  const switchButton = page.getByTestId('topbar-switch-sepolia').or(page.locator('[data-testid="topbar-switch-sepolia"]')).first();

  await byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount').fill('1');
  await rejectSwitchNetworkRequest(page, metamask, () => byTestIdOrId(page, 'trade-buy-sale-btn', 'trade-buy-sale-btn').click());

  await expect(banner).toContainText(/not on Sepolia/i, { timeout: 30_000 });
  await expect(switchButton).toBeVisible();
  await expect(status).toContainText(/Switch to Sepolia|wrong network|Buy preview failed/i);
  await expect(page.getByTestId('sale-confirm-card').or(page.locator('#sale-confirm-card')).first()).toBeHidden();

  await expect.poll(() => publicClient.readContract({
    address: inst.sale,
    abi: saleAbi,
    functionName: 'totalAmountRaised',
  }), {
    timeout: 10_000,
    message: 'wrong-chain rejection must not submit a sale transaction',
  }).toBe(before.totalRaised);
});
