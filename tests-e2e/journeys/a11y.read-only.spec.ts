// @ts-nocheck
/**
 * Accessibility scans (axe-core) for every public page.
 * Lifts T1.v2.D5 (a11y) and T2.v2.D9 (a11y test coverage).
 *
 * Each page emits audit/axe/<label>.json with violation counts.
 * The CI gate fails if any page has critical or serious violations.
 */
import { test, expect } from '@playwright/test';
import { runAxeOn } from '../axe-helper';

const PAGES = [
  { path: '/',          label: 'home' },
  { path: '/sale',      label: 'sale' },
  { path: '/proposals', label: 'proposals' },
  { path: '/create',    label: 'create' },
  { path: '/contracts', label: 'contracts' },
  { path: '/docs',      label: 'docs' },
];

for (const p of PAGES) {
  test(`axe-core: ${p.label} (${p.path})`, async ({ page }) => {
    await page.goto(p.path);
    await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});

    const r = await runAxeOn(page, p.label);

    const critical = r.violations.filter(v => v.impact === 'critical');
    const serious  = r.violations.filter(v => v.impact === 'serious');

    // CI gate: zero critical + zero serious.
    expect(critical, `Critical a11y violations on ${p.label}: ${critical.map(v => v.id).join(', ')}`).toEqual([]);
    expect(serious, `Serious a11y violations on ${p.label}: ${serious.map(v => v.id).join(', ')}`).toEqual([]);
  });
}
