#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs";

const timeoutMs = Number(process.env.PAGES_FRESHNESS_TIMEOUT_MS || 0);
const intervalMs = Number(process.env.PAGES_FRESHNESS_INTERVAL_MS || 15000);

const assets = [
  ["https://fao-ops.pages.dev/fao/", "site-ops/fao/index.html"],
  ["https://fao-ops.pages.dev/fao/dashboard.css", "site-ops/fao/dashboard.css"],
  ["https://fao-ops.pages.dev/fao/dashboard.js", "site-ops/fao/dashboard.js"],
  ["https://fao-ops.pages.dev/fao/summary.json", "site-ops/fao/summary.json"],
  ["https://fao-testnet.pages.dev/", "site-testnet/index.html"],
  ["https://fao-testnet.pages.dev/sale", "site-testnet/sale.html"],
  ["https://fao-testnet.pages.dev/proposals", "site-testnet/proposals.html"],
  ["https://fao-testnet.pages.dev/create", "site-testnet/create.html"],
  ["https://fao-testnet.pages.dev/contracts", "site-testnet/contracts.html"],
  ["https://fao-testnet.pages.dev/shared.js", "site-testnet/shared.js"],
  ["https://fao-testnet.pages.dev/styles.css", "site-testnet/styles.css"]
];

function sha256(value) {
  return crypto.createHash("sha256").update(value).digest("hex").slice(0, 16);
}

function localAsset(filePath) {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Local deploy asset missing: ${filePath}`);
  }

  return fs.readFileSync(filePath, "utf8");
}

async function remoteAsset(url) {
  const freshUrl = new URL(url);
  freshUrl.searchParams.set("__fresh", String(Date.now()));
  const response = await fetch(freshUrl, {
    cache: "no-store",
    headers: {
      "Cache-Control": "no-cache",
      "Pragma": "no-cache"
    }
  });

  if (!response.ok) {
    throw new Error(`${url} returned HTTP ${response.status}`);
  }

  return response.text();
}

async function checkOnce() {
  const mismatches = [];

  for (const [url, filePath] of assets) {
    const local = localAsset(filePath);
    let remote;
    try {
      remote = await remoteAsset(url);
    } catch (error) {
      mismatches.push({
        url,
        filePath,
        error: error instanceof Error ? error.message : String(error)
      });
      continue;
    }

    if (remote !== local) {
      mismatches.push({
        url,
        filePath,
        localBytes: Buffer.byteLength(local),
        remoteBytes: Buffer.byteLength(remote),
        localSha: sha256(local),
        remoteSha: sha256(remote)
      });
    }
  }

  return mismatches;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

const deadline = Date.now() + timeoutMs;
let attempt = 0;
let lastMismatches = [];

do {
  attempt += 1;
  lastMismatches = await checkOnce();
  if (lastMismatches.length === 0) {
    console.log(`All deployed Pages assets match the checkout (${assets.length} checked).`);
    process.exit(0);
  }

  console.log(`Pages freshness check attempt ${attempt}: ${lastMismatches.length} stale asset(s).`);
  if (Date.now() >= deadline) {
    break;
  }
  await sleep(Math.min(intervalMs, Math.max(0, deadline - Date.now())));
} while (Date.now() <= deadline);

for (const mismatch of lastMismatches) {
  const details = mismatch.error
    ? mismatch.error
    : `local ${mismatch.localBytes}B/${mismatch.localSha}, remote ${mismatch.remoteBytes}B/${mismatch.remoteSha}`;
  console.error(`STALE ${mismatch.url} != ${mismatch.filePath}: ${details}`);
}

process.exitCode = 1;
