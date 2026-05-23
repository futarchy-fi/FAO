/**
 * F7 — Place a YES bond on a proposal.
 *
 * Persona: bonder escalating a candidate proposal through the bond panel.
 */

// @ts-nocheck — runs only after npm install.
import {
  activeInstance,
  arbitrationAbi,
  ensureWalletCache,
  expect,
  readContract,
  test,
  unpackArbitrationProposal,
  ZERO,
} from '../wallet.fixture';
import {
  createInstanceThroughUi,
  createProposalThroughUi,
  placeYesBondThroughUi,
  proposalCard,
} from './wallet-journey-helpers';

test.setTimeout(360_000);

test.beforeAll(async () => {
  await ensureWalletCache();
});

test('F7-place-yes-bond happy path', async ({ page, metamask }) => {
  const { id } = await createInstanceThroughUi(page, metamask, 'F7');
  const inst = {
    id,
    ...(await activeInstance(id)),
  };
  expect(inst.arbitration.toLowerCase()).not.toBe(ZERO);

  const { proposalName, proposal, proposalId } = await createProposalThroughUi(page, metamask, inst, 'F7');
  const baseX = await readContract({
    address: inst.arbitration,
    abi: arbitrationAbi,
    functionName: 'baseX',
  });

  await placeYesBondThroughUi(page, metamask, proposalName);

  await expect.poll(async () => unpackArbitrationProposal(await readContract({
    address: inst.arbitration,
    abi: arbitrationAbi,
    functionName: 'getProposal',
    args: [proposalId],
  })), {
    timeout: 60_000,
    message: 'arbitration proposal should move to YES with the base bond',
  }).toMatchObject({
    state: 1,
    exists: true,
    yesBond: {
      amount: baseX,
    },
  });

  const card = proposalCard(page, proposalName);
  await expect(card.locator('.bond-state')).toContainText(/YES/i, { timeout: 30_000 });
  await expect(card.locator('.bond-panel')).toContainText('YES bond');
  await expect(card.locator('.bond-panel')).toContainText('0.001 WETH');
  await expect(card.locator('.sep-card-title a')).toHaveAttribute('href', new RegExp(proposal.slice(2), 'i'));
});

test.fixme('F7-place-yes-bond — wallet rejection', async ({ page }) => {
  // The buyer rejects the MetaMask popup. Site shows inline error,
  // does NOT proceed past the pre-confirm card, no chain state mutates.
});

test.fixme('F7-place-yes-bond — wrong chain', async ({ page }) => {
  // Wallet is on mainnet. Site triggers wallet_switchEthereumChain before
  // dispatching the tx. If user rejects the switch, status surfaces it.
});

test.fixme('F7-place-yes-bond — RPC 5xx during dispatch', async ({ page }) => {
  // The Sepolia RPC returns 500 mid-tx-submit. Site shows a retryable
  // error; no partial state.
});
