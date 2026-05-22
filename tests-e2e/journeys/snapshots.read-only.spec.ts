// @ts-nocheck
/**
 * Visual baselines for public, read-only pages.
 * No wallet actions: wallet-dependent flows belong in the wallet snapshot suite.
 */
import { expect, test } from '@playwright/test';

const PAGES = [
  { label: 'home', path: '/', readyTestId: 'rankings-rows' },
  { label: 'sale', path: '/sale.html', readyTestId: 'sale-decision-strip' },
  { label: 'create', path: '/create.html', readyTestId: 'create-submit' },
  { label: 'proposals', path: '/proposals.html', readyTestId: 'create-proposal-name' },
  { label: 'contracts', path: '/contracts.html', readyTestId: 'topbar-connect' },
  { label: 'docs', path: '/docs.html', readyTestId: 'topbar-connect' },
];

const VIEWPORTS = [
  { label: 'desktop', width: 1280, height: 720 },
  { label: 'mobile', width: 390, height: 844 },
];

const DYNAMIC_REGION_SELECTOR = [
  '#active-inst-chip',
  '#rankings-rows',
  '#sep-block',
  '#sep-markets-count',
  '#sep-op-balance',
  '#sep-oracle-ok',
  '#sep-updated',
  '#sale .sale-hero',
  '#sale-decision-wallet',
  '#sale-decision-sold',
  '#sale-decision-liq',
  '#sale-progress-block',
  '#trade-compare-banner',
  '#trade-buy-sale-price',
  '#trade-buy-suffix',
  '#trade-buy-cost',
  '#trade-buy-uni-price',
  '#trade-sell-rq-price',
  '#trade-sell-suffix',
  '#trade-sell-rq-out',
  '#trade-sell-uni-price',
  '.sale-stats-grid',
  '.sale-addr-table',
  '#sep-bonds-mount',
  '#sep-proposals',
].join(', ');

async function tagDynamicRegions(page) {
  await page.locator(DYNAMIC_REGION_SELECTOR).evaluateAll((elements) => {
    for (const element of elements) element.setAttribute('data-dynamic', '');
  });
}

for (const pageDef of PAGES) {
  for (const viewport of VIEWPORTS) {
    test(`${pageDef.label} ${viewport.label} visual baseline`, async ({ page }) => {
      await page.setViewportSize({ width: viewport.width, height: viewport.height });
      await page.goto(pageDef.path, { waitUntil: 'domcontentloaded' });
      await page.waitForLoadState('networkidle');
      await expect(page.getByTestId(pageDef.readyTestId)).toBeVisible();
      await tagDynamicRegions(page);

      await expect(page).toHaveScreenshot(`${pageDef.label}-${viewport.label}.png`, {
        maxDiffPixelRatio: 0.005,
        fullPage: true,
        mask: [page.locator('[data-dynamic]')],
      });
    });
  }
}
