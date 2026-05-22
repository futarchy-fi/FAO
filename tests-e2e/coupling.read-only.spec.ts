/**
 * Read-only SC <-> UI coupling test.
 *
 * deployments.json names the canonical registry. This spec reads the selected
 * instance from that registry, opens the live site with ?inst=N, and asserts
 * the browser-published active instance stayed aligned for the addresses the
 * UI uses to trade and arbitrate.
 */

// @ts-nocheck - runs only after `npm install`.
import { expect, test } from '@playwright/test';
import { readFileSync } from 'node:fs';
import path from 'node:path';
import { createPublicClient, defineChain, getAddress, http, parseAbi } from 'viem';

const RPC_URL = process.env.SEPOLIA_RPC
  || process.env.FAO_READONLY_RPC_URL
  || 'https://ethereum-sepolia.publicnode.com';
const INSTANCE_ID = Number(process.env.FAO_COUPLING_INST || '0');
const DEPLOYMENTS_PATH = path.resolve(process.cwd(), 'deployments.json');

const deployments = JSON.parse(readFileSync(DEPLOYMENTS_PATH, 'utf8'));
const REGISTRY = deployments.active?.registry;

const sepolia = defineChain({
  id: 11155111,
  name: 'Sepolia',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: [RPC_URL] } },
});

const registryAbi = parseAbi([
  'function instancesCount() view returns (uint256)',
  'function instances(uint256 id) view returns ((string name, string symbol, string description, address creator, address token, address sale, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint32 timeout, uint32 twapWindow))',
]);

const publicClient = createPublicClient({
  chain: sepolia,
  transport: http(RPC_URL),
});

function checksum(value) {
  return getAddress(value);
}

function shortAddr(value) {
  return `${value.slice(0, 6)}…${value.slice(-4)}`;
}

async function expectAddressLink(locator, expected) {
  await expect(locator).toHaveCount(1);

  const href = await locator.getAttribute('href');
  const hrefAddress = href?.match(/0x[a-fA-F0-9]{40}/)?.[0];
  expect(checksum(hrefAddress), `link href must point at ${expected}`).toBe(expected);

  const text = (await locator.textContent())?.trim() || '';
  if (/^0x[a-fA-F0-9]{40}$/.test(text)) {
    expect(checksum(text), `visible full address must equal ${expected}`).toBe(expected);
  } else {
    expect(text, `visible compact address must equal ${shortAddr(expected)}`).toBe(shortAddr(expected));
  }

  const title = await locator.getAttribute('title');
  if (title) expect(checksum(title), `title address must equal ${expected}`).toBe(expected);
}

function field(raw, name, index) {
  return raw?.[name] ?? raw?.[index];
}

async function readInstance(id) {
  return await publicClient.readContract({
    address: REGISTRY,
    abi: registryAbi,
    functionName: 'instances',
    args: [BigInt(id)],
  });
}

test.describe('deployment coupling - read-only live site', () => {
  test('the ?inst=N route publishes the registry token, sale, and arbitration addresses', async ({ page }, testInfo) => {
    test.skip(testInfo.project.name !== 'read-only', 'live-site coupling spec runs only in the read-only project');

    expect(deployments.chain_id, 'deployments.json must describe Sepolia').toBe(11155111);
    expect(REGISTRY, 'deployments.json active.registry must be present').toMatch(/^0x[a-fA-F0-9]{40}$/);
    expect(Number.isInteger(INSTANCE_ID) && INSTANCE_ID >= 0, 'FAO_COUPLING_INST must be a non-negative integer').toBe(true);

    const count = await publicClient.readContract({
      address: REGISTRY,
      abi: registryAbi,
      functionName: 'instancesCount',
    });
    expect(INSTANCE_ID, `instance ${INSTANCE_ID} must exist in deployments.json active registry`).toBeLessThan(Number(count));

    const onchain = await readInstance(INSTANCE_ID);
    const expected = {
      id: INSTANCE_ID,
      token: checksum(field(onchain, 'token', 4)),
      sale: checksum(field(onchain, 'sale', 5)),
      arbitration: checksum(field(onchain, 'arbitration', 6)),
    };

    await page.goto(`/sale?inst=${INSTANCE_ID}`);

    const active = await page.evaluate(async (id) => {
      if (window.activeInstance?.id !== id) {
        await new Promise((resolve) => {
          window.addEventListener('fao:sharedReady', resolve, { once: true });
          setTimeout(resolve, 30_000);
        });
      }
      return {
        id: window.activeInstance?.id,
        token: window.activeInstance?.token,
        sale: window.activeInstance?.sale,
        arbitration: window.activeInstance?.arbitration,
      };
    }, INSTANCE_ID);

    expect(active.id).toBe(expected.id);
    expect(checksum(active.token)).toBe(expected.token);
    expect(checksum(active.sale)).toBe(expected.sale);
    expect(checksum(active.arbitration)).toBe(expected.arbitration);

    const tokenLink = page.locator('#sale-addr-table-token a');
    const saleLink = page.locator('#sale-addr-table-sale a');
    await expectAddressLink(tokenLink, expected.token);
    await expectAddressLink(saleLink, expected.sale);
  });
});
