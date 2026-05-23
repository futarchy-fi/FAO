/**
 * F6 — Create a candidate proposal for an active futarchy instance.
 *
 * Persona: connected wallet submitting through the proposals page.
 */

// @ts-nocheck — runs only after npm install.
import {
  activeInstance,
  confirmOneTransaction,
  connectTopbarWallet,
  ensureWalletCache,
  expect,
  factoryAbi,
  readContract,
  test,
  ZERO,
} from '../wallet.fixture';

const INSTANCE_ID = Number(process.env.FAO_TEST_INSTANCE_ID || '0');

function createField(page, testId, id) {
  return page.getByTestId(testId).or(page.locator(`#${id}`)).first();
}

function createStatus(page) {
  return page.getByTestId('create-status').or(page.locator('#create-instance-status')).first();
}

async function createInstanceThroughUi(page, metamask) {
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `F6${suffix}`.slice(0, 10);

  await page.goto('/create.html');
  await expect(page).toHaveURL(/\/create/);
  await expect(createField(page, 'create-name', 'ci-name')).toBeVisible();

  await connectTopbarWallet(page, metamask);

  await createField(page, 'create-name', 'ci-name').fill(`F6 E2E ${suffix}`);
  await createField(page, 'create-symbol', 'ci-symbol').fill(symbol);
  await createField(page, 'create-description', 'ci-description').fill('Created by F6-create-proposal.wallet.spec.ts against Anvil.');
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

test('F6-create-proposal happy path', async ({ page, metamask }) => {
  const instanceId = process.env.FAO_TEST_INSTANCE_ID == null ? await createInstanceThroughUi(page, metamask) : INSTANCE_ID;
  const inst = await activeInstance(instanceId);
  expect(inst.factory.toLowerCase()).not.toBe(ZERO);

  const beforeCount = await readContract({
    address: inst.factory,
    abi: factoryAbi,
    functionName: 'marketsCount',
  });
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const proposalName = `E2E proposal ${suffix}`;

  await page.goto(`/proposals.html?inst=${instanceId}`);
  await expect(page.locator('#sep-proposals')).toBeVisible({ timeout: 30_000 });
  await expect.poll(
    () => page.evaluate(() => window.activeInstance?.id ?? null),
    { timeout: 30_000, message: 'proposals page should load the newly-created active instance before submitting' },
  ).toBe(instanceId);

  await connectTopbarWallet(page, metamask);
  if (!(await page.locator('#create-submit').isEnabled().catch(() => false))) {
    await page.locator('#connect-wallet').click();
  }
  await expect(page.locator('#create-submit')).toBeEnabled({ timeout: 30_000 });

  await page.locator('#create-name').fill(proposalName);
  await page.locator('#create-desc').fill('Created by F6-create-proposal.wallet.spec.ts against an Anvil Sepolia fork.');

  await page.locator('#create-submit').click();
  const confirmCard = page.getByTestId('confirm-card-proposal').or(page.locator('#confirm-card-proposal')).first();
  await expect(confirmCard).toBeVisible({ timeout: 15_000 });
  await confirmOneTransaction(page, metamask, () => (
    page.getByTestId('confirm-card-proposal-confirm').or(page.locator('#confirm-card-proposal-confirm')).first().click()
  ));

  await expect.poll(() => readContract({
    address: inst.factory,
    abi: factoryAbi,
    functionName: 'marketsCount',
  }), {
    timeout: 30_000,
    message: 'factory.marketsCount() should increment after createProposal',
  }).toBe(beforeCount + 1n);

  const newProposal = await readContract({
    address: inst.factory,
    abi: factoryAbi,
    functionName: 'proposals',
    args: [beforeCount],
  });
  expect(newProposal.toLowerCase()).not.toBe(ZERO);

  await expect(page.locator('#sep-proposals')).toContainText(proposalName, { timeout: 30_000 });
});

test.fixme('F6-create-proposal — wallet rejection', async ({ page }) => {
  // The buyer rejects the MetaMask popup. Site shows inline error,
  // does NOT proceed past the pre-confirm card, no chain state mutates.
});

test.fixme('F6-create-proposal — wrong chain', async ({ page }) => {
  // Wallet is on mainnet. Site triggers wallet_switchEthereumChain before
  // dispatching the tx. If user rejects the switch, status surfaces it.
});

test.fixme('F6-create-proposal — RPC 5xx during dispatch', async ({ page }) => {
  // The Sepolia RPC returns 500 mid-tx-submit. Site shows a retryable
  // error; no partial state.
});
