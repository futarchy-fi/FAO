/**
 * F8 — Place a NO bond to flip a YES proposal.
 *
 * Persona: counter-bonder matching the current YES bond in WETH.
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
  placeNoBondThroughUi,
  placeYesBondThroughUi,
  proposalCard,
} from './wallet-journey-helpers';

test.setTimeout(420_000);

test.beforeAll(async () => {
  await ensureWalletCache();
});

test('F8-place-no-bond happy path', async ({ page, metamask }) => {
  const { id } = await createInstanceThroughUi(page, metamask, 'F8');
  const inst = {
    id,
    ...(await activeInstance(id)),
  };
  expect(inst.arbitration.toLowerCase()).not.toBe(ZERO);

  const { proposalName, proposalId } = await createProposalThroughUi(page, metamask, inst, 'F8');
  await placeYesBondThroughUi(page, metamask, proposalName);

  await expect.poll(async () => unpackArbitrationProposal(await readContract({
    address: inst.arbitration,
    abi: arbitrationAbi,
    functionName: 'getProposal',
    args: [proposalId],
  })), {
    timeout: 60_000,
    message: 'setup YES bond should land before placing NO',
  }).toMatchObject({
    state: 1,
    exists: true,
  });
  const afterYes = unpackArbitrationProposal(await readContract({
    address: inst.arbitration,
    abi: arbitrationAbi,
    functionName: 'getProposal',
    args: [proposalId],
  }));

  await placeNoBondThroughUi(page, metamask, proposalName);

  await expect.poll(async () => unpackArbitrationProposal(await readContract({
    address: inst.arbitration,
    abi: arbitrationAbi,
    functionName: 'getProposal',
    args: [proposalId],
  })), {
    timeout: 60_000,
    message: 'arbitration proposal should move to NO with a matching bond',
  }).toMatchObject({
    state: 2,
    exists: true,
    noBond: {
      amount: afterYes.yesBond.amount,
    },
  });

  const card = proposalCard(page, proposalName);
  await expect(card.locator('.bond-state')).toContainText(/NO/i, { timeout: 30_000 });
  await expect(card.locator('.bond-panel')).toContainText('NO bond');
});

test.fixme('F8-place-no-bond — wallet rejection', async ({ page }) => {
  // The buyer rejects the MetaMask popup. Site shows inline error,
  // does NOT proceed past the pre-confirm card, no chain state mutates.
});

test.fixme('F8-place-no-bond — wrong chain', async ({ page }) => {
  // Wallet is on mainnet. Site triggers wallet_switchEthereumChain before
  // dispatching the tx. If user rejects the switch, status surfaces it.
});

test.fixme('F8-place-no-bond — RPC 5xx during dispatch', async ({ page }) => {
  // The Sepolia RPC returns 500 mid-tx-submit. Site shows a retryable
  // error; no partial state.
});
