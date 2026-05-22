#!/usr/bin/env node

import fs from "node:fs";
import path from "node:path";

const inputDir = process.argv[2] || ".lighthouseci";
const outputDir = process.argv[3] || "audit/lighthouse";
const configPath = "lighthouserc.json";

const metricSpecs = {
  lcp: {
    auditId: "largest-contentful-paint",
    label: "Largest Contentful Paint",
    unit: "ms",
    max: 2500,
    op: "<="
  },
  inp: {
    auditId: "performance-event-timing:inp",
    label: "Interaction to Next Paint",
    unit: "ms",
    max: 200,
    op: "<="
  },
  cls: {
    auditId: "cumulative-layout-shift",
    label: "Cumulative Layout Shift",
    unit: "unitless",
    max: 0.1,
    op: "<="
  },
  tbt: {
    auditId: "total-blocking-time",
    label: "Total Blocking Time",
    unit: "ms",
    max: 200,
    op: "<="
  },
  fcp: {
    auditId: "first-contentful-paint",
    label: "First Contentful Paint",
    unit: "ms",
    max: 1800,
    op: "<="
  }
};

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

function numericAudit(lhr, auditId) {
  const audit = lhr.audits?.[auditId];
  if (!audit || typeof audit.numericValue !== "number") {
    return null;
  }

  return {
    value: audit.numericValue,
    displayValue: audit.displayValue || null,
    score: typeof audit.score === "number" ? audit.score : null
  };
}

function metricSummary(lhr, spec) {
  const audit = numericAudit(lhr, spec.auditId);
  if (!audit) {
    return {
      value: null,
      displayValue: null,
      score: null,
      budget: spec.max,
      unit: spec.unit,
      pass: false,
      missing: true
    };
  }

  return {
    value: audit.value,
    displayValue: audit.displayValue,
    score: audit.score,
    budget: spec.max,
    unit: spec.unit,
    pass: audit.value <= spec.max
  };
}

function metricSummaryForRuns(entries, spec) {
  const values = entries
    .map((entry) => numericAudit(readJson(entry.jsonPath), spec.auditId))
    .filter(Boolean)
    .sort((a, b) => a.value - b.value);

  if (values.length === 0) {
    return {
      value: null,
      displayValue: null,
      score: null,
      budget: spec.max,
      unit: spec.unit,
      pass: false,
      missing: true
    };
  }

  const median = values[Math.floor(values.length / 2)];
  return {
    value: median.value,
    displayValue: median.displayValue,
    score: median.score,
    budget: spec.max,
    unit: spec.unit,
    pass: median.value <= spec.max
  };
}

function urlForLhr(lhr) {
  return lhr.requestedUrl || lhr.finalDisplayedUrl || lhr.finalUrl;
}

function configuredRunCount() {
  if (!fs.existsSync(configPath)) {
    return Number.POSITIVE_INFINITY;
  }

  try {
    const config = readJson(configPath);
    const runs = Number(config?.ci?.collect?.numberOfRuns);
    return Number.isFinite(runs) && runs > 0 ? runs : Number.POSITIVE_INFINITY;
  } catch (_) {
    return Number.POSITIVE_INFINITY;
  }
}

function manifestEntries() {
  const manifestPath = path.join(inputDir, "manifest.json");
  if (!fs.existsSync(manifestPath)) {
    return [];
  }

  const manifest = readJson(manifestPath);
  if (!Array.isArray(manifest)) {
    return [];
  }

  return manifest.filter((entry) => entry && entry.jsonPath && entry.url);
}

function lhrFilesFromManifest(entries) {
  return entries.map((entry) => {
    const jsonPath = path.isAbsolute(entry.jsonPath)
      ? entry.jsonPath
      : path.resolve(inputDir, entry.jsonPath.replace(/^\.lighthouseci\//, ""));
    return {
      url: entry.url,
      jsonPath,
      isRepresentativeRun: Boolean(entry.isRepresentativeRun),
      fetchTime: fs.existsSync(jsonPath) ? readJson(jsonPath).fetchTime : null
    };
  });
}

function lhrFilesFromDirectory() {
  if (!fs.existsSync(inputDir)) {
    throw new Error(`Lighthouse CI output directory not found: ${inputDir}`);
  }

  return fs.readdirSync(inputDir)
    .filter((name) => name.endsWith(".json") && name !== "manifest.json")
    .map((name) => path.join(inputDir, name))
    .map((jsonPath) => {
      const lhr = readJson(jsonPath);
      return {
        url: urlForLhr(lhr),
        jsonPath,
        isRepresentativeRun: false,
        fetchTime: lhr.fetchTime || null
      };
    })
    .filter((entry) => entry.url);
}

function medianRun(entries) {
  const sortable = entries
    .map((entry) => {
      const lhr = readJson(entry.jsonPath);
      const lcp = numericAudit(lhr, metricSpecs.lcp.auditId)?.value;
      return { entry, lcp: typeof lcp === "number" ? lcp : Number.POSITIVE_INFINITY };
    })
    .sort((a, b) => a.lcp - b.lcp);

  return sortable[Math.floor(sortable.length / 2)].entry;
}

function chooseRepresentative(entries) {
  return entries.find((entry) => entry.isRepresentativeRun) || medianRun(entries);
}

function latestEntries(entries, count) {
  return [...entries]
    .sort((a, b) => String(a.fetchTime || "").localeCompare(String(b.fetchTime || "")))
    .slice(-count);
}

function categoryScore(lhr, categoryId) {
  const score = lhr.categories?.[categoryId]?.score;
  return typeof score === "number" ? score : null;
}

function readInpResults() {
  const inpPath = path.join(outputDir, "inp.json");
  if (!fs.existsSync(inpPath)) {
    return new Map();
  }

  const inp = readJson(inpPath);
  if (!Array.isArray(inp.pages)) {
    return new Map();
  }

  return new Map(inp.pages.map((page) => [page.slug, page]));
}

fs.mkdirSync(outputDir, { recursive: true });

const entries = manifestEntries();
const files = entries.length > 0 ? lhrFilesFromManifest(entries) : lhrFilesFromDirectory();
const byUrl = new Map();
const inpResults = readInpResults();
const runCount = configuredRunCount();

for (const file of files) {
  if (!fs.existsSync(file.jsonPath)) {
    throw new Error(`Lighthouse CI JSON report not found: ${file.jsonPath}`);
  }

  const url = file.url;
  const group = byUrl.get(url) || [];
  group.push(file);
  byUrl.set(url, group);
}

if (byUrl.size === 0) {
  throw new Error(`No Lighthouse CI JSON reports found in ${inputDir}`);
}

const pages = [];
for (const [url, allUrlEntries] of [...byUrl.entries()].sort(([a], [b]) => a.localeCompare(b))) {
  const urlEntries = latestEntries(allUrlEntries, runCount);
  const representative = chooseRepresentative(urlEntries);
  const lhr = readJson(representative.jsonPath);
  const slug = slugForUrl(url);
  const reportPath = path.join(outputDir, `${slug}.json`);
  const metrics = Object.fromEntries(
    Object.entries(metricSpecs).map(([key, spec]) => [key, metricSummaryForRuns(urlEntries, spec)])
  );
  const inpResult = inpResults.get(slug);
  if (inpResult) {
    metrics.inp = {
      value: inpResult.value,
      displayValue: inpResult.displayValue,
      score: null,
      budget: metricSpecs.inp.max,
      unit: metricSpecs.inp.unit,
      pass: inpResult.pass,
      source: "performance-event-timing",
      interactions: inpResult.interactions,
      missing: typeof inpResult.value !== "number"
    };
  }

  writeJson(reportPath, lhr);

  pages.push({
    url,
    slug,
    report: reportPath,
    runs: urlEntries.length,
    representativeRun: path.relative(process.cwd(), representative.jsonPath),
    budgetsPass: Object.values(metrics).every((metric) => metric.pass),
    metrics,
    categories: {
      performance: categoryScore(lhr, "performance"),
      accessibility: categoryScore(lhr, "accessibility"),
      bestPractices: categoryScore(lhr, "best-practices"),
      seo: categoryScore(lhr, "seo")
    }
  });
}

const summary = {
  generatedAt: new Date().toISOString(),
  source: "lighthouse-ci",
  mode: "mobile",
  inputDir,
  budgets: Object.fromEntries(
    Object.entries(metricSpecs).map(([key, spec]) => [
      key,
      {
        auditId: spec.auditId,
        label: spec.label,
        max: spec.max,
        op: spec.op,
        unit: spec.unit
      }
    ])
  ),
  pass: pages.every((page) => page.budgetsPass),
  pages
};

writeJson(path.join(outputDir, "web-vitals.json"), summary);

console.log(`Wrote ${pages.length} Lighthouse page report(s) to ${outputDir}`);
console.log(`Web Vitals budget status: ${summary.pass ? "pass" : "fail"}`);
