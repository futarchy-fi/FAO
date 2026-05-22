#!/usr/bin/env bash
# T5.D2 / Step E - assert active deployment contracts have verified source.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOYMENTS_FILE="${1:-$ROOT_DIR/deployments.json}"

node - "$DEPLOYMENTS_FILE" <<'NODE'
const fs = require("fs");

const deploymentsFile = process.argv[2];
const deployments = JSON.parse(fs.readFileSync(deploymentsFile, "utf8"));
const active = deployments.active || {};
const verificationTodo = deployments.verification_todo || [];

const ADDRESS_RE = /^0x[0-9a-fA-F]{40}$/;
const FULL_ADDRESS_RE = /0x[0-9a-fA-F]{40}/g;
const SHORT_ADDRESS_RE = /0x([0-9a-fA-F]{4,})(?:\u2026|\.\.\.)([0-9a-fA-F]{4,})/g;

function collectActiveAddresses(value, path = []) {
  if (typeof value === "string" && ADDRESS_RE.test(value)) {
    return [{ path: path.join("."), address: value }];
  }
  if (!value || typeof value !== "object") {
    return [];
  }
  return Object.entries(value).flatMap(([key, nested]) => collectActiveAddresses(nested, path.concat(key)));
}

function todoMatchesAddress(todo, address) {
  const normalized = address.toLowerCase();
  const fullMatches = todo.match(FULL_ADDRESS_RE) || [];
  if (fullMatches.some((match) => match.toLowerCase() === normalized)) {
    return true;
  }

  SHORT_ADDRESS_RE.lastIndex = 0;
  for (let match = SHORT_ADDRESS_RE.exec(todo); match !== null; match = SHORT_ADDRESS_RE.exec(todo)) {
    const prefix = `0x${match[1]}`.toLowerCase();
    const suffix = match[2].toLowerCase();
    if (normalized.startsWith(prefix) && normalized.endsWith(suffix)) {
      return true;
    }
  }
  return false;
}

function isKnownEoaPath(path) {
  return /(^|\.)operator$/i.test(path);
}

const apiKey = process.env.ETHERSCAN_API_KEY || process.env.ETHERSCAN_TOKEN || "";
if (!apiKey) {
  console.error("::error::ETHERSCAN_API_KEY is required to verify active contracts on Etherscan");
  process.exit(1);
}

let etherscan;
try {
  etherscan = require("etherscan-api");
} catch (error) {
  console.error("::error::Missing npm package: etherscan-api");
  console.error("Install it locally with: npm install --no-save etherscan-api@10.3.0");
  process.exit(1);
}

const network = process.env.ETHERSCAN_NETWORK || deployments.network || "homestead";
const timeoutMs = Number(process.env.ETHERSCAN_TIMEOUT_MS || 15000);
const maxAttempts = Number(process.env.ETHERSCAN_MAX_ATTEMPTS || 3);
const api = etherscan.init(apiKey, network, timeoutMs);

const activeAddresses = collectActiveAddresses(active);
if (activeAddresses.length === 0) {
  console.error(`::error file=${deploymentsFile}::deployments.json::active has no active addresses`);
  process.exit(1);
}

function sameAddress(left, right) {
  return left.toLowerCase() === right.toLowerCase();
}

function sourceVerificationStatus(source) {
  if (!source || typeof source !== "object") {
    return { verified: false, reason: "missing getsourcecode result" };
  }

  const sourceCode = typeof source.SourceCode === "string" ? source.SourceCode.trim() : "";
  const contractName = typeof source.ContractName === "string" ? source.ContractName.trim() : "";
  const abi = typeof source.ABI === "string" ? source.ABI : "";

  if (abi === "Contract source code not verified") {
    return { verified: false, reason: "Etherscan reports source code not verified" };
  }
  if (!sourceCode) {
    return { verified: false, reason: "empty SourceCode in Etherscan response" };
  }
  if (!contractName) {
    return { verified: false, reason: "empty ContractName in Etherscan response" };
  }

  return { verified: true, contractName };
}

function activeTodoMatches(activeItem) {
  return verificationTodo.filter(
    (todo) => typeof todo === "string" && todoMatchesAddress(todo, activeItem.address),
  );
}

function responseContext(response) {
  const pieces = [];
  if (response && response.status !== undefined) {
    pieces.push(`status=${response.status}`);
  }
  if (response && response.message) {
    pieces.push(`message=${response.message}`);
  }
  if (response && typeof response.result === "string") {
    pieces.push(`result=${response.result}`);
  }
  return pieces.length > 0 ? pieces.join(" ") : "no status";
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function fetchSourceCode(item) {
  let lastError;

  for (let attempt = 1; attempt <= maxAttempts; attempt++) {
    try {
      const response = await api.contract.getsourcecode(item.address);
      const result = Array.isArray(response && response.result) ? response.result[0] : undefined;
      if (!result || typeof result !== "object") {
        throw new Error(`invalid getsourcecode response: ${responseContext(response)}`);
      }
      return { response, result };
    } catch (error) {
      lastError = error;
      if (attempt < maxAttempts) {
        await sleep(500 * attempt);
      }
    }
  }

  throw lastError;
}

async function main() {
  const apiFailures = [];
  const unverified = [];
  const verified = [];
  const skipped = [];

  for (const item of activeAddresses) {
    if (isKnownEoaPath(item.path)) {
      skipped.push(item);
      continue;
    }

    try {
      const { result } = await fetchSourceCode(item);
      const status = sourceVerificationStatus(result);
      if (!status.verified) {
        unverified.push({ ...item, reason: status.reason });
        continue;
      }
      verified.push({ ...item, contractName: status.contractName });
    } catch (error) {
      apiFailures.push({ ...item, reason: error.message });
      continue;
    }
  }

  for (const item of verified) {
    console.log(`[ok] active.${item.path} ${item.address} verified as ${item.contractName}`);
  }
  for (const item of skipped) {
    console.log(`[skip] active.${item.path} ${item.address} is an operator EOA, not a contract`);
  }
  for (const item of unverified) {
    console.error(`[unverified] active.${item.path} ${item.address}: ${item.reason}`);
  }
  for (const item of apiFailures) {
    console.error(`[error] active.${item.path} ${item.address}: ${item.reason}`);
  }

  const activeTodos = [];
  for (const todo of verificationTodo) {
    if (typeof todo !== "string") {
      continue;
    }
    for (const item of activeAddresses) {
      if (todoMatchesAddress(todo, item.address)) {
        activeTodos.push({ todo, ...item });
      }
    }
  }

  const missingTodos = unverified.filter((item) => activeTodoMatches(item).length === 0);
  const staleTodos = activeTodos.filter((todoItem) =>
    verified.some((verifiedItem) => sameAddress(verifiedItem.address, todoItem.address)),
  );

  if (missingTodos.length > 0) {
    console.error(
      `::error file=${deploymentsFile}::verification_todo is missing ${missingTodos.length} unverified active address(es)`,
    );
    for (const item of missingTodos) {
      console.error(`- active.${item.path} ${item.address}`);
    }
  }

  if (staleTodos.length > 0) {
    console.error(
      `::error file=${deploymentsFile}::verification_todo still lists ${staleTodos.length} verified active address(es)`,
    );
    for (const item of staleTodos) {
      console.error(`- active.${item.path} ${item.address}: ${item.todo}`);
    }
  }

  if (activeTodos.length > 0) {
    console.error(
      `::error file=${deploymentsFile}::verification_todo still references ${activeTodos.length} active address(es)`,
    );
    for (const item of activeTodos) {
      console.error(`- active.${item.path} ${item.address}: ${item.todo}`);
    }
  }

  if (unverified.length > 0) {
    console.error(`::error::${unverified.length} active contract address(es) are not Etherscan-verified`);
    for (const item of unverified) {
      console.error(`- active.${item.path} ${item.address}`);
    }
  }

  if (apiFailures.length > 0) {
    console.error(`::error::${apiFailures.length} active contract address(es) could not be checked`);
  }

  if (
    missingTodos.length > 0 ||
    staleTodos.length > 0 ||
    activeTodos.length > 0 ||
    unverified.length > 0 ||
    apiFailures.length > 0
  ) {
    process.exit(1);
  }
}

main().catch((error) => {
  console.error(`::error::Etherscan verification check failed: ${error.message}`);
  process.exit(1);
});
NODE
