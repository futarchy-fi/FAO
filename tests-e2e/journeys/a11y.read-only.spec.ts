// @ts-nocheck
/**
 * Accessibility scans (axe-core) for every public page.
 * Lifts T1.v2.D5 (a11y) and T2.v2.D9 (a11y test coverage).
 *
 * Each page emits audit/axe/<label>.json with violation counts.
 * The CI gate fails if any page has critical or serious violations.
 */
import { test, expect } from '@playwright/test';
import * as fs from 'node:fs';
import * as http from 'node:http';
import * as https from 'node:https';
import * as path from 'node:path';
import { runAxeOn } from '../axe-helper';

let axeSiteUrl = process.env.FAO_AXE_SITE_URL || '';
const SITE_ROOT = path.resolve(process.cwd(), 'site-testnet');
const PAGES = [
  { path: '/',          label: 'home' },
  { path: '/sale',      label: 'sale' },
  { path: '/proposals', label: 'proposals' },
  { path: '/create',    label: 'create' },
  { path: '/contracts', label: 'contracts' },
  { path: '/docs',      label: 'docs' },
];

let localServer;

function isLocalUrl(url: string) {
  const { hostname } = new URL(url);
  return hostname === '127.0.0.1' || hostname === 'localhost';
}

async function isReachable(url: string) {
  return await new Promise((resolve) => {
    const client = url.startsWith('https:') ? https : http;
    const req = client.get(url, (res) => {
      res.resume();
      resolve(Boolean(res.statusCode && res.statusCode < 500));
    });
    req.on('error', () => resolve(false));
    req.setTimeout(1_000, () => {
      req.destroy();
      resolve(false);
    });
  });
}

test.beforeAll(async () => {
  if (axeSiteUrl && (!isLocalUrl(axeSiteUrl) || await isReachable(axeSiteUrl))) return;

  const url = axeSiteUrl ? new URL(axeSiteUrl) : new URL('http://127.0.0.1:0');
  localServer = http.createServer((req, res) => {
    const requestUrl = new URL(req.url || '/', axeSiteUrl);
    let requestPath = requestUrl.pathname === '/' ? '/index.html' : requestUrl.pathname;
    if (!path.extname(requestPath)) requestPath = `${requestPath}.html`;

    const filePath = path.resolve(SITE_ROOT, requestPath.replace(/^\/+/, ''));
    if (!filePath.startsWith(`${SITE_ROOT}${path.sep}`)) {
      res.writeHead(403).end('Forbidden');
      return;
    }

    fs.readFile(filePath, (err, body) => {
      if (err) {
        res.writeHead(404, { 'content-type': 'text/plain; charset=utf-8' }).end('Not found');
        return;
      }

      const ext = path.extname(filePath);
      const contentType = {
        '.css': 'text/css; charset=utf-8',
        '.html': 'text/html; charset=utf-8',
        '.js': 'text/javascript; charset=utf-8',
        '.json': 'application/json; charset=utf-8',
        '.svg': 'image/svg+xml',
      }[ext] || 'application/octet-stream';
      res.writeHead(200, { 'content-type': contentType }).end(body);
    });
  });

  await new Promise((resolve, reject) => {
    localServer.once('error', reject);
    localServer.listen(Number(url.port || '80'), url.hostname, resolve);
  });

  const address = localServer.address();
  if (!axeSiteUrl && address && typeof address === 'object') {
    axeSiteUrl = `http://127.0.0.1:${address.port}`;
  }
});

test.afterAll(() => {
  localServer?.close();
});

for (const p of PAGES) {
  test(`axe-core: ${p.label} (${p.path})`, async ({ page }) => {
    await page.goto(new URL(p.path, axeSiteUrl).toString());
    await page.waitForLoadState('networkidle', { timeout: 15_000 }).catch(() => {});

    const r = await runAxeOn(page, p.label);

    const critical = r.violations.filter(v => v.impact === 'critical');
    const serious  = r.violations.filter(v => v.impact === 'serious');

    // CI gate: zero critical + zero serious.
    expect(critical, `Critical a11y violations on ${p.label}: ${critical.map(v => v.id).join(', ')}`).toEqual([]);
    expect(serious, `Serious a11y violations on ${p.label}: ${serious.map(v => v.id).join(', ')}`).toEqual([]);
  });
}
