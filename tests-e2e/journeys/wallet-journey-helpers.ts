// @ts-nocheck — wallet specs run after npm install; CI type-check is separate.
import {
  confirmOneTransaction,
  connectTopbarWallet,
  expect,
  factoryAbi,
  readContract,
} from '../wallet.fixture';

function field(page, testId, id) {
  return page.getByTestId(testId).or(page.locator(`#${id}`)).first();
}

function createStatus(page) {
  return page.getByTestId('create-status').or(page.locator('#create-instance-status')).first();
}

export async function createInstanceThroughUi(page, metamask, label) {
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const symbol = `${label}${suffix}`.slice(0, 10);

  await page.goto('/create.html');
  await expect(page).toHaveURL(/\/create/);
  await expect(field(page, 'create-name', 'ci-name')).toBeVisible();

  await connectTopbarWallet(page, metamask);

  await field(page, 'create-name', 'ci-name').fill(`${label} E2E ${suffix}`);
  await field(page, 'create-symbol', 'ci-symbol').fill(symbol);
  await field(page, 'create-description', 'ci-description').fill(`Created by ${label} wallet journey against Anvil.`);
  await field(page, 'create-price', 'ci-price').fill('0.0001');
  await field(page, 'create-min-sold', 'ci-min-sold').fill('10');
  await field(page, 'create-sale-duration', 'ci-sale-duration').fill('60');
  await field(page, 'create-timeout', 'ci-timeout').fill('120');
  await field(page, 'create-twap', 'ci-twap').fill('60');
  await field(page, 'create-bond', 'ci-bond').fill('0.001');

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
  return { id, symbol };
}

export async function waitForActiveInstance(page, instanceId) {
  await expect.poll(
    () => page.evaluate(() => window.activeInstance?.id ?? null),
    { timeout: 30_000, message: `page should load active instance ${instanceId}` },
  ).toBe(instanceId);
}

export async function createProposalThroughUi(page, metamask, inst, label) {
  const beforeCount = await readContract({
    address: inst.factory,
    abi: factoryAbi,
    functionName: 'marketsCount',
  });
  const suffix = Date.now().toString(36).slice(-6).toUpperCase();
  const proposalName = `${label} proposal ${suffix}`;

  await page.goto(`/proposals.html?inst=${inst.id}`);
  await expect(page.locator('#sep-proposals')).toBeVisible({ timeout: 30_000 });
  await waitForActiveInstance(page, inst.id);

  await connectTopbarWallet(page, metamask);
  await expect(page.locator('#create-submit')).toBeEnabled({ timeout: 30_000 });

  await page.locator('#create-name').fill(proposalName);
  await page.locator('#create-desc').fill(`Created by ${label} wallet journey against an Anvil Sepolia fork.`);
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

  const proposal = await readContract({
    address: inst.factory,
    abi: factoryAbi,
    functionName: 'proposals',
    args: [beforeCount],
  });
  await expect(page.locator('#sep-proposals')).toContainText(proposalName, { timeout: 30_000 });
  return { proposalName, proposal, proposalId: BigInt(proposal) };
}

export function proposalCard(page, proposalName) {
  return page.locator('#sep-proposals .sep-card', { hasText: proposalName }).first();
}

async function clickOkModal(page, titlePattern) {
  const modal = page.locator('.fao-modal-backdrop', { hasText: titlePattern }).last();
  await expect(modal).toBeVisible({ timeout: 15_000 });
  await modal.locator('button[data-action="ok"]').click();
}

async function confirmBond(page, metamask) {
  await expect(page.getByTestId('confirm-card-bond').or(page.locator('#confirm-card-bond')).first()).toBeVisible({ timeout: 15_000 });
  await confirmOneTransaction(page, metamask, () => (
    page.getByTestId('confirm-card-bond-confirm').or(page.locator('#confirm-card-bond-confirm')).first().click()
  ));
}

export async function placeYesBondThroughUi(page, metamask, proposalName) {
  const card = proposalCard(page, proposalName);
  await expect(card.locator('.bond-panel')).toBeVisible({ timeout: 30_000 });
  await card.locator('button[data-action="yes"]').click();
  await clickOkModal(page, /YES bond/i);
  await confirmBond(page, metamask);

  const wrapPrompt = page.locator('.fao-modal-backdrop', { hasText: /Wrap ETH/i }).last();
  if (await wrapPrompt.waitFor({ state: 'visible', timeout: 10_000 }).then(() => true).catch(() => false)) {
    await wrapPrompt.locator('button[data-action="ok"]').click();
  }
}

export async function placeNoBondThroughUi(page, metamask, proposalName) {
  const card = proposalCard(page, proposalName);
  await expect(card.locator('.bond-panel')).toBeVisible({ timeout: 30_000 });
  await expect(card.locator('button[data-action="no"]')).toBeEnabled({ timeout: 30_000 });
  await card.locator('button[data-action="no"]').click();
  await confirmBond(page, metamask);

  const wrapPrompt = page.locator('.fao-modal-backdrop', { hasText: /Wrap ETH/i }).last();
  if (await wrapPrompt.waitFor({ state: 'visible', timeout: 10_000 }).then(() => true).catch(() => false)) {
    await wrapPrompt.locator('button[data-action="ok"]').click();
  }
}
