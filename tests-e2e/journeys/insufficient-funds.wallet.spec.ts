/**
 * T2.D4 axis — insufficient funds.
 *
 * The connected wallet has less ETH than the buy quote requires.
 * The UI should:
 *   1. Show an "insufficient balance" pre-confirm state (or at least a
 *      visible error when the user tries to sign).
 *   2. NOT mutate sale state (totalAmountRaised unchanged).
 *
 * Pattern mirrors wallet-rejection.wallet.spec.ts but instead of rejecting
 * the popup, we set the wallet balance to ~0 via anvil_setBalance before
 * the click and observe how the UI surfaces the failure.
 */

// @ts-nocheck — runs only after npm install.
import {
  connectWithMetaMask,
  ensureWalletCache,
  expect,
  test,
} from '../real-metamask.fixture';
import {
  ANVIL_ACCOUNT,
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

test('insufficient funds — sale buy reveals balance shortfall and does not mutate sale state', async ({ page, metamask }) => {
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `LOW${suffix}`.slice(0, 10);
  const { id, inst } = await createPart1Instance({
    name: `Insufficient Funds ${suffix}`,
    symbol,
    description: 'Insufficient-funds target created by insufficient-funds.wallet.spec.ts.',
  });

  await page.goto(`/sale.html?inst=${id}`);
  await expect(byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount')).toBeVisible({ timeout: 30_000 });
  await expect(page.locator('#sale-hero-symbol')).toContainText(symbol, { timeout: 30_000 });

  await connectWithMetaMask(page, metamask);

  // Drain the connected wallet to 0 ETH via Anvil cheat. The fork
  // started with the Hardhat #0 account funded; we forcibly set it to 0.
  await publicClient.request({
    method: 'anvil_setBalance',
    params: [ANVIL_ACCOUNT, '0x0'],
  });

  // Sanity: balance should now be 0.
  const newBalance = await publicClient.getBalance({ address: ANVIL_ACCOUNT });
  expect(newBalance, 'wallet must be drained for this spec').toBe(0n);

  const before = await readSaleSnapshot(inst.sale);

  await byTestIdOrId(page, 'trade-buy-amount', 'trade-buy-amount').fill('1');
  await byTestIdOrId(page, 'trade-buy-sale-btn', 'trade-buy-sale-btn').click();

  // The pre-confirm card may still open (UI doesn't precompute balance).
  // But pressing confirm with zero balance must surface an error — either
  // via the pre-confirm card itself or the post-tx status node.
  const confirmCard = page.getByTestId('sale-confirm-card').or(page.locator('#sale-confirm-card')).first();
  const status = page.getByTestId('sale-buy-status').or(page.locator('#sale-buy-status')).first();

  await expect(confirmCard).toBeVisible({ timeout: 15_000 });
  await byTestIdOrId(page, 'sale-confirm-go', 'sale-confirm-go').click();

  // The wallet refuses to send (insufficient funds). The UI surfaces some
  // error state — match permissively because the exact copy may vary
  // across browsers / providers / wallet impls.
  await expect(status).toContainText(
    /insufficient|not enough|failed|balance|error|reverted/i,
    { timeout: 60_000 },
  );
  await expect(status).toHaveClass(/sale-buy-status-error|sale-buy-status-warn/);

  // The sale must NOT have mutated.
  await expect.poll(() => publicClient.readContract({
    address: inst.sale,
    abi: saleAbi,
    functionName: 'totalAmountRaised',
  }), {
    timeout: 10_000,
    message: 'insufficient-funds path must not change sale.totalAmountRaised',
  }).toBe(before.totalRaised);
});
