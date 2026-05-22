#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";
import { chromium } from "playwright";

const configPath = process.argv[2] || "lighthouserc.json";
const outputDir = process.argv[3] || "audit/lighthouse";
const budgetMs = 200;
const viewport = { width: 390, height: 844 };

function readJson(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

function writeJson(filePath, value) {
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function slugForUrl(urlValue) {
  const parsed = new URL(urlValue);
  const pathname = parsed.pathname.replace(/\/$/, "");
  const base = `${parsed.hostname}${pathname}`;
  return base
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "");
}

function urlsFromConfig(filePath) {
  const config = readJson(filePath);
  const urls = config?.ci?.collect?.url;
  if (!Array.isArray(urls) || urls.length === 0) {
    throw new Error(`No ci.collect.url entries found in ${filePath}`);
  }

  return urls;
}

async function installInpObserver(page) {
  await page.addInitScript(() => {
    const interactions = new Map();

    function recordInteraction(entry) {
      const fallbackId = `${entry.entryType}:${entry.name}:${entry.startTime}`;
      const id = entry.interactionId || fallbackId;
      const current = interactions.get(id);
      if (current && current.duration >= entry.duration) {
        return;
      }

      interactions.set(id, {
        id,
        name: entry.name,
        entryType: entry.entryType,
        startTime: entry.startTime,
        duration: entry.duration,
        processingStart: entry.processingStart ?? null,
        processingEnd: entry.processingEnd ?? null
      });
    }

    window.__faoInpSupported = Boolean(window.PerformanceObserver);
    window.__faoInpError = null;
    window.__faoInpSnapshot = () => {
      const sorted = [...interactions.values()].sort((a, b) => b.duration - a.duration);
      return {
        value: sorted.length > 0 ? sorted[0].duration : null,
        interactions: sorted.length,
        worstInteractions: sorted.slice(0, 10)
      };
    };

    try {
      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          if (entry.interactionId || entry.entryType === "first-input") {
            recordInteraction(entry);
          }
        }
      }).observe({ type: "event", buffered: true, durationThreshold: 16 });

      new PerformanceObserver((list) => {
        for (const entry of list.getEntries()) {
          recordInteraction(entry);
        }
      }).observe({ type: "first-input", buffered: true });
    } catch (error) {
      window.__faoInpError = error instanceof Error ? error.message : String(error);
    }
  });
}

async function visibleClickTargets(page) {
  return page.locator([
    "button:not([disabled])",
    "[role='button']:not([aria-disabled='true'])",
    "input:not([type='hidden']):not([disabled])",
    "select:not([disabled])",
    "summary"
  ].join(",")).evaluateAll((nodes) => {
    return nodes
      .map((node, index) => {
        const rect = node.getBoundingClientRect();
        const style = window.getComputedStyle(node);
        const label = node.getAttribute("aria-label") || node.textContent || node.getAttribute("name") || node.id || node.tagName;
        return {
          index,
          label: label.trim().replace(/\s+/g, " ").slice(0, 80),
          x: rect.left + rect.width / 2,
          y: rect.top + rect.height / 2,
          width: rect.width,
          height: rect.height,
          visible: rect.width > 0 &&
            rect.height > 0 &&
            rect.bottom > 0 &&
            rect.right > 0 &&
            rect.top < window.innerHeight &&
            rect.left < window.innerWidth &&
            style.visibility !== "hidden" &&
            style.display !== "none" &&
            style.pointerEvents !== "none"
        };
      })
      .filter((target) => target.visible)
      .slice(0, 4);
  });
}

async function exercisePage(page, url) {
  await page.goto(url, { waitUntil: "domcontentloaded", timeout: 60000 });
  await page.waitForLoadState("networkidle", { timeout: 15000 }).catch(() => {});
  await page.waitForTimeout(500);

  await page.mouse.click(viewport.width / 2, Math.min(320, viewport.height / 2));
  await page.waitForTimeout(250);

  const targets = await visibleClickTargets(page);
  const clicked = [];
  for (const target of targets) {
    await page.mouse.click(target.x, target.y);
    clicked.push(target.label || `target-${target.index}`);
    await page.waitForTimeout(250);
  }

  await page.keyboard.press("Tab");
  await page.waitForTimeout(150);
  await page.keyboard.press("Escape");
  await page.waitForTimeout(500);

  return clicked;
}

async function measureUrl(browser, url) {
  const context = await browser.newContext({
    viewport,
    deviceScaleFactor: 3,
    isMobile: true,
    hasTouch: true
  });
  const page = await context.newPage();
  await installInpObserver(page);

  let clicked = [];
  let error = null;
  try {
    clicked = await exercisePage(page, url);
  } catch (caught) {
    error = caught instanceof Error ? caught.message : String(caught);
  }

  const snapshot = await page.evaluate(() => {
    return {
      supported: window.__faoInpSupported,
      observerError: window.__faoInpError,
      result: window.__faoInpSnapshot ? window.__faoInpSnapshot() : null
    };
  }).catch((caught) => ({
    supported: false,
    observerError: caught instanceof Error ? caught.message : String(caught),
    result: null
  }));

  await context.close();

  const value = snapshot.result?.value ?? null;
  return {
    url,
    slug: slugForUrl(url),
    value,
    displayValue: typeof value === "number" ? `${Math.round(value)} ms` : null,
    budget: budgetMs,
    unit: "ms",
    pass: typeof value === "number" && value <= budgetMs,
    interactions: snapshot.result?.interactions ?? 0,
    clicked,
    worstInteractions: snapshot.result?.worstInteractions ?? [],
    supported: Boolean(snapshot.supported),
    observerError: snapshot.observerError,
    pageError: error
  };
}

fs.mkdirSync(outputDir, { recursive: true });

const urls = urlsFromConfig(configPath);
const launchOptions = {
  headless: true,
  args: ["--no-sandbox"]
};

if (process.env.CHROME_PATH) {
  launchOptions.executablePath = process.env.CHROME_PATH;
}

const browser = await chromium.launch(launchOptions);
const pages = [];

try {
  for (const url of urls) {
    pages.push(await measureUrl(browser, url));
  }
} finally {
  await browser.close();
}

const summary = {
  generatedAt: new Date().toISOString(),
  source: "performance-event-timing",
  budget: {
    metric: "inp",
    max: budgetMs,
    op: "<=",
    unit: "ms"
  },
  pass: pages.every((page) => page.pass),
  pages
};

writeJson(path.join(outputDir, "inp.json"), summary);

for (const page of pages) {
  const status = page.pass ? "PASS" : "FAIL";
  console.log(`${status} ${page.url} INP=${page.displayValue ?? "missing"} interactions=${page.interactions}`);
}

if (!summary.pass) {
  process.exitCode = 1;
}
