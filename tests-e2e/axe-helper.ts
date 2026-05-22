// @ts-nocheck
/**
 * axe-core helper for Playwright specs.
 * Records the latest axe scan per page into audit/axe/<label>.json so the
 * T1.v2.D5 / T2.v2.D9 evaluator has structured evidence.
 *
 * Usage:
 *   import { runAxeOn } from '../axe-helper';
 *   await runAxeOn(page, 'home');
 */
import AxeBuilder from '@axe-core/playwright';
import * as fs from 'fs';
import * as path from 'path';

const OUT_DIR = path.resolve(process.cwd(), 'audit/axe');

export async function runAxeOn(page, label: string) {
  const builder = new AxeBuilder({ page })
    .withTags(['wcag2a', 'wcag2aa', 'wcag21a', 'wcag21aa']);
  const results = await builder.analyze();

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const outPath = path.join(OUT_DIR, `${label}.json`);
  fs.writeFileSync(outPath, JSON.stringify({
    label,
    url: page.url(),
    timestamp: new Date().toISOString(),
    violations: results.violations.map(v => ({
      id: v.id,
      impact: v.impact,
      help: v.help,
      nodes: v.nodes.length,
    })),
    counts: {
      critical: results.violations.filter(v => v.impact === 'critical').length,
      serious:  results.violations.filter(v => v.impact === 'serious').length,
      moderate: results.violations.filter(v => v.impact === 'moderate').length,
      minor:    results.violations.filter(v => v.impact === 'minor').length,
    },
  }, null, 2));

  return results;
}
