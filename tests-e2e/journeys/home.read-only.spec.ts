/**
 * Read-only smoke tests for the Home page (`/`).
 * No wallet, no transactions — just UI invariants visible to anyone.
 *
 * Counts toward Topic-2 D1 (user-flow coverage) for the "browse / inspect"
 * persona; toward D3 only at the lowest band (these don't exercise chain
 * effect).
 */

// @ts-nocheck — runs only after `npm install`.
import { test, expect } from '@playwright/test';

test.describe('Home page', () => {
  test('renders without console errors and shows the rankings table', async ({ page }) => {
    const errors: string[] = [];
    page.on('pageerror', (e) => errors.push(`pageerror: ${e.message}`));
    page.on('console', (msg) => {
      if (msg.type() === 'error') errors.push(`console: ${msg.text()}`);
    });

    await page.goto('/');
    await expect(page).toHaveTitle(/FAO/i);

    // The rankings table must exist (even if empty).
    await expect(page.locator('table.rankings-table')).toBeVisible();

    // Topbar present + connect CTA reachable by keyboard.
    const connect = page.getByRole('button', { name: /connect/i });
    await expect(connect).toBeVisible();
    await connect.focus();
    await expect(connect).toBeFocused();

    expect(errors, errors.join('\n')).toEqual([]);
  });

  test('filter pills toggle without reloading the page', async ({ page }) => {
    await page.goto('/');
    const allPill = page.getByRole('button', { name: /^All$/ });
    const initialPill = page.getByRole('button', { name: /^Initial sale$/ });
    await expect(allPill).toBeVisible();
    await initialPill.click();
    await expect(initialPill).toHaveClass(/filter-pill-active/);
    await allPill.click();
    await expect(allPill).toHaveClass(/filter-pill-active/);
  });
});
