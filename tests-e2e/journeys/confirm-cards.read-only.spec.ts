// @ts-nocheck
import { expect, test } from '@playwright/test';

const CASES = [
  {
    action: 'create',
    path: '/create.html',
    title: 'Review futarchy deployment',
    rows: [
      ['Action', 'Deploy futarchy instance'],
      ['Token', 'PriceTest / PRX'],
      ['Base bond', '0.001 WETH'],
      ['Gas estimate', '412000 gas'],
    ],
  },
  {
    action: 'proposal',
    path: '/proposals.html',
    title: 'Review proposal creation',
    rows: [
      ['Action', 'Create proposal'],
      ['Title', 'Should FAO run the review-card test?'],
      ['Bond', '0.001 WETH'],
      ['Gas estimate', '186000 gas'],
    ],
  },
  {
    action: 'resolve',
    path: '/proposals.html',
    title: 'Review proposal resolution',
    rows: [
      ['Action', 'Resolve proposal'],
      ['Proposal', 'Should FAO run the review-card test?'],
      ['Resolver', 'FAOTwapResolver'],
      ['Gas estimate', '98000 gas'],
    ],
  },
  {
    action: 'bond',
    path: '/proposals.html',
    title: 'Review bond transaction',
    rows: [
      ['Action', 'Place YES bond'],
      ['Proposal', 'Should FAO run the review-card test?'],
      ['WETH amount', '0.002 WETH'],
      ['Gas estimate', '144000 gas'],
    ],
  },
];

async function showReviewCard(page, action, rows) {
  await page.evaluate(({ action, rows }) => {
    const card = document.querySelector(`#confirm-card-${action}`);
    const rowsEl = document.querySelector(`#confirm-card-${action}-rows`);
    if (!card || !rowsEl) throw new Error(`Missing confirm card for ${action}`);
    rowsEl.innerHTML = rows.map(([label, value]) => `
      <div class="sale-confirm-row">
        <span>${label}</span>
        <strong>${value}</strong>
      </div>
    `).join('');
    card.hidden = false;
    card.setAttribute('data-review-fixture', 'true');
  }, { action, rows });
}

for (const c of CASES) {
  test(`${c.action} transaction review card has decoded args and controls`, async ({ page }) => {
    await page.goto(c.path, { waitUntil: 'domcontentloaded' });
    await page.waitForLoadState('networkidle');
    await showReviewCard(page, c.action, c.rows);

    const card = page.getByTestId(`confirm-card-${c.action}`);
    await expect(card).toBeVisible();
    await expect(card).toContainText(c.title);
    await expect(card.locator('.sale-confirm-row')).toHaveCount(c.rows.length);
    for (const [label, value] of c.rows) {
      await expect(card).toContainText(label);
      await expect(card).toContainText(value);
    }
    await expect(page.getByTestId(`confirm-card-${c.action}-cancel`)).toBeVisible();
    await expect(page.getByTestId(`confirm-card-${c.action}-confirm`)).toBeVisible();
  });
}
