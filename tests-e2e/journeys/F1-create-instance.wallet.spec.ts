/**
 * F1 — Create a new futarchy instance.
 *
 * Persona: protocol founder, brand-new wallet with 0.05 ETH on Sepolia.
 *
 * Happy path:
 *   1. Land on /create
 *   2. Fill the form (name, symbol, sale price, sale phase, timeout, twap, bond)
 *   3. Click Submit
 *   4. Approve Part 1 in MetaMask
 *   5. Wait for Part 1 confirmation
 *   6. Approve Part 2 in MetaMask
 *   7. Wait for Part 2 confirmation
 *   8. Redirected to /?inst=<id>
 *   9. Assert: rankings table now contains a row for the new instance with
 *      raised=0, mcap=0, phase="initial sale".
 *  10. Assert (on-chain via viem): registry.instancesCount() incremented by 1
 *      and registry.instances(id).sale != 0x0.
 *
 * Failure-mode coverage in sibling tests (later passes):
 *   - User rejects the wallet popup mid-Part-1 → status shows the failure;
 *     no instance is registered.
 *   - User on wrong chain → site triggers a chain switch via
 *     wallet_switchEthereumChain before Part 1 dispatch.
 *   - Anvil RPC returns 500 on tx submit → status shows a retryable error.
 *   - Part 2 fails (e.g. spot pool address collision) → instance is left
 *     PENDING_PART2, "Complete deployment" appears on the chip.
 *   - Reorg post-Part-1 → site detects the missing inclusion and reverts.
 *
 * This file is the F1 scaffold. It will run only once:
 *   - `data-testid` selectors are added to the site (see SELECTORS.md);
 *   - Synpress is wired into the project (see playwright.config.ts:wallet);
 *   - the Anvil fork is provisioned with the funded test wallet.
 *
 * Until then, the test is `test.fixme()` to avoid masking the
 * "no E2E tests" baseline with a passing-via-skip cheat.
 */

// @ts-nocheck — runs only after `npm install`; type-check is opt-in via CI.
import { test, expect } from '@playwright/test';

test.fixme('F1 — Founder creates a new futarchy instance end-to-end', async ({ page }) => {
  // Pre: funded wallet, Sepolia chain.
  // const synpress = await Synpress.connect();
  // await synpress.importAccount(process.env.TEST_PRIVATE_KEY!);
  // await synpress.switchNetwork('Sepolia');

  // 1. Land on /create
  await page.goto('/create');
  await expect(page).toHaveURL(/\/create/);

  // 2. Fill the form.
  await page.getByTestId('create-name').fill('Acme E2E');
  await page.getByTestId('create-symbol').fill('ACME-E2E');
  await page.getByTestId('create-description').fill('E2E test instance.');
  await page.getByTestId('create-price').fill('0.0001');
  await page.getByTestId('create-min-sold').fill('10');
  await page.getByTestId('create-sale-duration').fill('60');
  await page.getByTestId('create-timeout').fill('120');
  await page.getByTestId('create-twap').fill('60');
  await page.getByTestId('create-bond').fill('0.001');

  // 3. Submit. Synpress confirms the MetaMask popup for each tx.
  await page.getByTestId('create-submit').click();
  // await synpress.confirmTransaction(); // Part 1
  await expect(page.getByTestId('create-status')).toContainText(/Step 1\/2/, { timeout: 60_000 });
  // await synpress.confirmTransaction(); // Part 2
  await expect(page.getByTestId('create-status')).toContainText(/Done/, { timeout: 120_000 });

  // 4. Redirect to home, instance visible.
  await page.waitForURL(/\/\?inst=\d+/);
  const url = new URL(page.url());
  const newId = Number(url.searchParams.get('inst'));
  await expect(page.getByTestId(`rankings-row-${newId}`)).toBeVisible();
  await expect(page.getByTestId(`rankings-row-${newId}`)).toContainText(/initial sale/i);

  // 5. On-chain assertion via viem. (Imported in test util once Synpress lands.)
  // const client = createPublicClient({ chain: sepolia, transport: http(process.env.FAO_RPC_URL) });
  // const count = await client.readContract({ address: REGISTRY, abi, functionName: 'instancesCount' });
  // expect(Number(count)).toBeGreaterThan(newId);
  // const inst = await client.readContract({ address: REGISTRY, abi, functionName: 'instances', args: [newId] });
  // expect(inst.sale).not.toBe('0x0000000000000000000000000000000000000000');
});
