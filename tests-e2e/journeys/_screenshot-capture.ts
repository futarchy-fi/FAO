#!/usr/bin/env node
'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { chromium } = require('@playwright/test');

const ROOT = path.resolve(__dirname, '..', '..');
const OUT_DIR = path.resolve(process.env.FAO_SCREENSHOT_DIR || path.join(ROOT, 'audit', 'screenshots'));
const BASE_URL = normalizeBaseUrl(process.env.FAO_SITE_URL || 'https://fao-testnet.pages.dev/');
const SETTLE_MS = Number(process.env.FAO_SCREENSHOT_SETTLE_MS || 1500);
const BASE_HOSTNAME = new URL(BASE_URL).hostname;
const IS_LOCAL_STATIC_SERVER = BASE_HOSTNAME === '127.0.0.1' || BASE_HOSTNAME === 'localhost';

const PAGES = [
  { label: 'home', path: '/', testId: 'rankings-rows' },
  { label: 'sale', path: '/sale', testId: 'sale-decision-strip' },
  { label: 'proposals', path: '/proposals', testId: 'create-proposal-name' },
  { label: 'create', path: '/create', testId: 'create-name' },
  { label: 'contracts', path: '/contracts', testId: 'skip-nav' },
  { label: 'docs', path: '/docs', testId: 'skip-nav' },
];

const VIEWPORTS = [
  { name: 'desktop', width: 1280, height: 720 },
  { name: 'mobile', width: 390, height: 844 },
];

const DYNAMIC_SELECTORS = [
  '#rankings-rows .rank-num',
  '#sep-block',
  '#sep-markets-count',
  '#sep-op-balance',
  '#sep-updated',
  '#sale-hero-price',
  '#sale-decision-wallet',
  '#sale-decision-sold',
  '#sale-decision-liq',
  '#sale-progress-text',
  '#sale-progress-foot',
  '#trade-buy-sale-price',
  '#trade-sell-rq-price',
  '#trade-buy-uni-price',
  '#trade-sell-uni-price',
  '#trade-buy-cost',
  '#trade-sell-rq-out',
  '#sale-raised',
  '#sale-initial-sold',
  '#sale-curve-sold',
  '#sale-phase-end',
  '#sale-balance',
  '#sale-flp-balance',
  '#sale-eth',
  '#sale-pool-liq',
];

function normalizeBaseUrl(raw) {
  const url = new URL(raw);
  if (!url.pathname.endsWith('/')) url.pathname += '/';
  return url.toString();
}

function pageUrl(pagePath) {
  let relative = pagePath.replace(/^\/+/, '');
  if (IS_LOCAL_STATIC_SERVER && relative && !relative.endsWith('.html')) {
    relative = `${relative}.html`;
  }
  return relative ? new URL(relative, BASE_URL).toString() : BASE_URL;
}

function relPath(absPath) {
  return path.relative(ROOT, absPath).split(path.sep).join('/');
}

function prependLocalBrowserLibs() {
  const candidates = [
    path.join(ROOT, '.pw-libs', 'usr', 'lib', 'x86_64-linux-gnu'),
    path.join(ROOT, '.pw-libs', 'lib', 'x86_64-linux-gnu'),
  ].filter((dir) => fs.existsSync(dir));
  if (!candidates.length) return;
  process.env.LD_LIBRARY_PATH = [
    ...candidates,
    process.env.LD_LIBRARY_PATH || '',
  ].filter(Boolean).join(':');
}

async function installDynamicMask(page) {
  await page.addStyleTag({
    content: `
      [data-dynamic]:not(:has([data-dynamic])) {
        background: #17202c !important;
        border-color: #17202c !important;
        color: transparent !important;
        text-shadow: none !important;
      }
      [data-dynamic]:not(:has([data-dynamic])) * {
        color: transparent !important;
        text-shadow: none !important;
        visibility: hidden !important;
      }
    `,
  });

  await page.evaluate((selectors) => {
    const mark = () => {
      document.querySelectorAll(selectors.join(',')).forEach((node) => {
        node.setAttribute('data-dynamic', '');
      });
    };
    mark();
    const observer = new MutationObserver(mark);
    observer.observe(document.body, { childList: true, subtree: true });
    window.__faoScreenshotMaskObserver = observer;
  }, DYNAMIC_SELECTORS);
}

async function waitForReady(page, pageDef) {
  await page.waitForFunction(() => document.readyState === 'complete', null, { timeout: 45_000 });
  await page.getByTestId(pageDef.testId).waitFor({ state: 'attached', timeout: 30_000 });
  await page.waitForLoadState('networkidle', { timeout: 5_000 }).catch(() => {});
}

async function captureOne(browser, pageDef, viewport) {
  const url = pageUrl(pageDef.path);
  const fileName = `${pageDef.label}-${viewport.name}.png`;
  const filePath = path.join(OUT_DIR, fileName);
  const context = await browser.newContext({
    colorScheme: 'dark',
    deviceScaleFactor: 1,
    reducedMotion: 'reduce',
    viewport: { width: viewport.width, height: viewport.height },
  });
  const page = await context.newPage();
  page.setDefaultTimeout(30_000);

  try {
    console.log(`[capture] ${pageDef.label} ${viewport.name} ${viewport.width}x${viewport.height} ${url}`);
    await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 45_000 });
    await waitForReady(page, pageDef);
    await page.waitForTimeout(SETTLE_MS);
    await installDynamicMask(page);
    await page.waitForTimeout(250);
    await page.screenshot({
      animations: 'disabled',
      caret: 'hide',
      fullPage: false,
      path: filePath,
      scale: 'css',
    });

    const bytes = fs.statSync(filePath).size;
    const sha256 = crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
    const capturedAt = new Date().toISOString();
    console.log(`[ok] ${fileName} ${sha256.slice(0, 12)} ${bytes} bytes`);
    return {
      page: pageDef.label,
      viewport: viewport.name,
      width: viewport.width,
      height: viewport.height,
      sourceUrl: url,
      capturedAt,
      file: relPath(filePath),
      sha256,
      bytes,
    };
  } finally {
    await context.close();
  }
}

async function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });
  prependLocalBrowserLibs();

  const runStartedAt = new Date().toISOString();
  const screenshots = [];
  const browser = await chromium.launch({ headless: true });
  try {
    for (const pageDef of PAGES) {
      for (const viewport of VIEWPORTS) {
        screenshots.push(await captureOne(browser, pageDef, viewport));
      }
    }
  } finally {
    await browser.close();
  }

  const expected = PAGES.length * VIEWPORTS.length;
  if (screenshots.length !== expected) {
    throw new Error(`expected ${expected} screenshots, captured ${screenshots.length}`);
  }

  const manifest = {
    generatedAt: new Date().toISOString(),
    runStartedAt,
    tool: 'Playwright Chromium',
    baseUrl: BASE_URL,
    pages: PAGES.map((pageDef) => ({
      page: pageDef.label,
      path: pageDef.path,
      sourceUrl: pageUrl(pageDef.path),
      waitForTestId: pageDef.testId,
    })),
    viewports: VIEWPORTS,
    screenshots,
  };

  const manifestPath = path.join(OUT_DIR, 'manifest.json');
  fs.writeFileSync(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
  console.log(`[manifest] ${relPath(manifestPath)} (${screenshots.length} screenshots)`);
}

main().catch((error) => {
  console.error(error && error.stack ? error.stack : error);
  process.exitCode = 1;
});
