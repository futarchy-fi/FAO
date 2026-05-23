/* FAO v0 — Sepolia testnet bond-escalation UI
 *
 * Adds a "Bond escalation" sub-panel to each proposal card rendered by sepolia.js.
 * Reads + writes FutarchyArbitration (0x9D7692738a4d323338b9007d65d7F79e013B3476).
 *
 * Wires:
 *   - per-card state chip (INACTIVE / YES / NO / QUEUED / EVALUATING / SETTLED)
 *   - YES bond / NO bond display
 *   - "Place YES bond" — opens modal asking for amount in WETH
 *   - "Place NO bond" — matches current YES amount exactly
 *   - "Try graduate" — only visible when bond is large enough to attempt graduation
 *   - "Withdraw refund" banner at the top of proposals section
 *   - Inline ETH→WETH wrap helper when WETH balance is insufficient
 *
 * Wallet pattern delegates to shared.js so EIP-6963 provider selection and
 * topbar wallet identity stay consistent across pages.
 * Polling for state lives here (separate from sepolia.js polling, but synchronized via
 * a MutationObserver on #sep-proposals so we re-inject panels whenever cards re-render).
 *
 * IMPORTANT — stub bridge:
 *   The on-chain arbitration ID is a uint256 chosen at createProposalWithId time.
 *   v0 has no proposal↔arbitration bridge contract yet, so we DERIVE the arbitration
 *   id from the proposal address as BigInt(propAddr). The first person to escalate a
 *   given proposal pays gas to call FutarchyArbitration.createProposalWithId(id, baseX)
 *   on behalf of everyone. A future agent will replace this with a proper on-chain
 *   bridge that records the (proposal address → arbitration id) mapping.
 */

(() => {
  'use strict';

  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const FORK_RPC = 'http://127.0.0.1:8545';
  const REFRESH_INTERVAL = 30_000;

  // WETH is shared infra across every futarchy instance on Sepolia.
  const WETH_ADDR = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';

  // Bootstrap arbitration address — used until registry.js publishes
  // window.activeInstance.
  const BOOTSTRAP_ARBITRATION = '0x9D7692738a4d323338b9007d65d7F79e013B3476';

  /** Return the arbitration contract address for the currently active futarchy.
   *  Falls back to the bootstrap FAO arbitration until registry.js boots. */
  function arbitrationAddr() {
    const inst = (typeof window !== 'undefined') ? window.activeInstance : null;
    return (inst && inst.arbitration) ? inst.arbitration : BOOTSTRAP_ARBITRATION;
  }

  const STATE_LABELS = ['INACTIVE', 'YES', 'NO', 'QUEUED', 'EVALUATING', 'SETTLED'];

  // Minimal ABI — we only call what we use.
  const ARBITRATION_ABI = [
    'function baseX() view returns (uint256)',
    'function MAX_QUEUE() view returns (uint256)',
    'function queueHead() view returns (uint256)',
    'function activeEvaluationProposalId() view returns (uint256)',
    'function nextProposalId() view returns (uint256)',
    'function safetyModeActive() view returns (bool)',
    'function WETH() view returns (address)',
    'function withdrawable(address) view returns (uint256)',
    'function requiredYes(uint256) view returns (uint256)',
    'function getProposal(uint256) view returns (tuple(uint256 minActivationBond, tuple(address bidder, uint256 amount) yesBond, tuple(address bidder, uint256 amount) noBond, uint8 state, uint64 lastStateChangeAt, bool settled, bool accepted, uint32 queuePosition, bool exists))',
    'function createProposalWithId(uint256 proposalId, uint256 minActivationBond) returns (uint256)',
    'function placeYesBond(uint256 proposalId, uint256 amount)',
    'function placeNoBond(uint256 proposalId)',
    'function tryGraduate(uint256 proposalId)',
    'function withdraw()',
  ];

  const WETH_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function allowance(address owner, address spender) view returns (uint256)',
    'function approve(address spender, uint256 value) returns (bool)',
    'function deposit() payable',
  ];

  // ─── Globals ─────────────────────────────────────────────────────────

  let provider;          // read-only RPC
  let signer;            // wallet signer
  let connectedWallet;   // address

  // Per-proposal cached state: { [propAddrLower]: { arbId, state, yesBond, noBond, gradOk } }
  const proposalState = new Map();
  // Set of proposal addresses currently visible on the page.
  let knownProposalAddrs = new Set();
  // Approximate queue length used for grad threshold. We derive it from totalProposals
  // tracked by us — but the contract uses _queuedCount() which we can't read directly.
  // We use staticCall(tryGraduate) per proposal to test feasibility instead.
  let baseX = 0n;
  let safetyActive = false;

  // ─── Utilities ───────────────────────────────────────────────────────

  function $$(sel, root = document) { return root.querySelector(sel); }
  function $$$(sel, root = document) { return Array.from(root.querySelectorAll(sel)); }

  function fmtAddr(a) {
    if (!a || a === '0x0000000000000000000000000000000000000000') return '—';
    return `${a.slice(0, 6)}…${a.slice(-4)}`;
  }
  function fmtWeth(wei) {
    if (wei === 0n) return '0';
    const s = ethers.formatEther(wei);
    // Strip trailing zeros for readability.
    return s.replace(/\.?0+$/, '') + ' WETH';
  }
  function explorerAddr(addr) { return `https://sepolia.etherscan.io/address/${addr}`; }
  function explorerTx(hash) { return `https://sepolia.etherscan.io/tx/${hash}`; }
  function escapeHtml(s) {
    if (typeof s !== 'string') return '';
    return s.replace(/[&<>"']/g, ch => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[ch]));
  }
  async function safe(fn, fallback) {
    try { return await fn(); } catch (_) { return fallback; }
  }
  function isForkMode() { try { return localStorage.faoForkMode === '1'; } catch (_) { return false; } }
  function rpcUrl() { return window.faoRpcUrl || (isForkMode() ? FORK_RPC : RPC); }
  async function ensureEthers() { if (window.loadFaoEthers) await window.loadFaoEthers(); }

  function fmtGas(gas) {
    return gas == null ? 'Estimate unavailable' : `${gas.toString()} gas`;
  }

  function renderConfirmRows(container, rows) {
    if (!container) return;
    container.innerHTML = rows.map((row) => `
      <div class="sale-confirm-row">
        <span>${escapeHtml(row.label)}</span>
        <strong>${escapeHtml(row.value)}</strong>
      </div>
    `).join('');
  }

  function showBondConfirm(rows, confirmLabel = 'Confirm bond') {
    return new Promise((resolve) => {
      const card = $$('#confirm-card-bond');
      const rowsEl = $$('#confirm-card-bond-rows');
      const confirm = $$('#confirm-card-bond-confirm');
      const cancel = $$('#confirm-card-bond-cancel');
      if (!card || !rowsEl || !confirm || !cancel) {
        resolve(true);
        return;
      }
      renderConfirmRows(rowsEl, rows);
      confirm.textContent = confirmLabel;
      card.hidden = false;
      card.scrollIntoView({ block: 'nearest' });
      const cleanup = (result) => {
        confirm.onclick = null;
        cancel.onclick = null;
        card.hidden = true;
        resolve(result);
      };
      confirm.onclick = () => cleanup(true);
      cancel.onclick = () => cleanup(false);
    });
  }

  /**
   * Derive arbitration uint256 id from a proposal contract address.
   * STUB BRIDGE: see file header. Will be replaced by a real bridge contract.
   */
  function arbIdFor(propAddr) {
    // ethers v6: address (20 bytes) maps cleanly to a uint256 via BigInt(0x…).
    return BigInt(propAddr);
  }

  // ─── Read path ───────────────────────────────────────────────────────

  async function loadGlobals() {
    const arb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, provider);
    baseX = await safe(() => arb.baseX(), 0n);
    safetyActive = await safe(() => arb.safetyModeActive(), false);
  }

  /**
   * Fetch on-chain state for one proposal address.
   * Returns { exists, state, yesBond, noBond, gradOk } or null on RPC error.
   *
   * `gradOk` = true if tryGraduate(arbId) would succeed right now (state == YES and
   * yes amount ≥ requiredYes(currentQueueLen)). Computed via staticCall — that's the
   * cleanest way without a public queueLen accessor on the contract.
   */
  async function loadProposalState(propAddr) {
    const arb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, provider);
    const arbId = arbIdFor(propAddr);

    let p;
    try {
      p = await arb.getProposal(arbId);
    } catch (_) {
      // Most likely: ProposalNotFound — never escalated.
      return {
        exists: false,
        arbId,
        state: 0,
        yesBond: { bidder: ethers.ZeroAddress, amount: 0n },
        noBond:  { bidder: ethers.ZeroAddress, amount: 0n },
        minActivationBond: baseX || 0n,
        gradOk: false,
      };
    }

    let gradOk = false;
    if (Number(p.state) === 1 /* YES */) {
      try {
        await arb.tryGraduate.staticCall(arbId);
        gradOk = true;
      } catch (_) { gradOk = false; }
    }

    return {
      exists: true,
      arbId,
      state: Number(p.state),
      yesBond: { bidder: p.yesBond.bidder, amount: p.yesBond.amount },
      noBond:  { bidder: p.noBond.bidder,  amount: p.noBond.amount  },
      minActivationBond: p.minActivationBond,
      settled: p.settled,
      accepted: p.accepted,
      queuePosition: Number(p.queuePosition),
      gradOk,
    };
  }

  // ─── Render ──────────────────────────────────────────────────────────

  function stateChip(state) {
    const label = STATE_LABELS[state] || 'UNKNOWN';
    return `<span class="bond-state bond-state-${label.toLowerCase()}">${label}</span>`;
  }

  function renderBondLine(label, bond) {
    if (!bond || bond.amount === 0n) {
      return `<div class="bond-row"><span class="bond-label">${label}</span><span class="bond-value">—</span></div>`;
    }
    return `<div class="bond-row">
      <span class="bond-label">${label}</span>
      <span class="bond-value">
        <strong>${escapeHtml(fmtWeth(bond.amount))}</strong>
        by <a href="${explorerAddr(bond.bidder)}" target="_blank" rel="noopener">${fmtAddr(bond.bidder)}</a>
      </span>
    </div>`;
  }

  function renderBondPanel(propAddr, s) {
    const isInactive = !s.exists || s.state === 0;
    const isYes = s.state === 1;
    const isNo  = s.state === 2;
    const isQueued = s.state === 3;
    const isEval   = s.state === 4;
    const isSettled = s.state === 5;

    let actionsHtml = '';
    if (isSettled) {
      actionsHtml = `<p class="bond-note">${s.accepted ? 'Accepted ✓' : 'Rejected ✗'} — proposal settled.</p>`;
    } else if (isEval) {
      actionsHtml = `<p class="bond-note">Under evaluation by the evaluator module.</p>`;
    } else if (isQueued) {
      actionsHtml = `<p class="bond-note">Queued for evaluation (position ${s.queuePosition}).</p>`;
    } else {
      // INACTIVE / YES / NO — escalation game is active.
      const yesEnabled = isInactive || isNo;
      const noEnabled  = isYes && s.yesBond.amount > 0n;
      const yesDisabledNote = isYes ? 'YES is currently leading. Wait for NO to flip first.' : '';
      const noDisabledNote  = !isYes ? 'NO can only match a current YES bond.' : '';

      actionsHtml = `
        <div class="bond-actions">
          <button class="bond-action-btn bond-action-yes"
                  data-action="yes" data-prop="${propAddr}"
                  ${yesEnabled ? '' : 'disabled'}
                  title="${escapeHtml(yesDisabledNote)}">Place YES bond</button>
          <button class="bond-action-btn bond-action-no"
                  data-action="no" data-prop="${propAddr}"
                  ${noEnabled ? '' : 'disabled'}
                  title="${escapeHtml(noDisabledNote)}">Place NO bond (match)</button>
          ${(isYes && s.gradOk) ? `<button class="bond-action-btn bond-action-grad"
                  data-action="grad" data-prop="${propAddr}">Try graduate</button>` : ''}
        </div>
      `;
    }

    const safetyNote = safetyActive && (isYes || isNo)
      ? `<p class="bond-safety">⚠ Safety mode active — YES-by-timeout settlement is currently disabled.</p>`
      : '';

    return `
      <div class="bond-panel" data-prop="${propAddr}">
        <div class="bond-panel-head">
          <span class="bond-panel-title">Bond escalation</span>
          ${stateChip(s.state || 0)}
        </div>
        ${renderBondLine('YES bond', s.yesBond)}
        ${renderBondLine('NO bond', s.noBond)}
        ${actionsHtml}
        ${safetyNote}
        <p class="bond-status" data-prop-status="${propAddr}" role="status" aria-live="polite" aria-atomic="true"></p>
      </div>
    `;
  }

  function renderWithdrawBanner(amount) {
    const mount = $$('#sep-bonds-mount');
    if (!mount) return;
    if (!connectedWallet || amount === 0n) {
      mount.innerHTML = '';
      return;
    }
    mount.innerHTML = `
      <div class="bond-withdraw-banner">
        <span>You have <strong>${escapeHtml(fmtWeth(amount))}</strong> available to withdraw from arbitration.</span>
        <button class="bond-action-btn" id="bond-withdraw-btn">Withdraw refund</button>
      </div>
    `;
    const btn = $$('#bond-withdraw-btn');
    if (btn) btn.addEventListener('click', () => onWithdraw());
  }

  /**
   * Walk the cards rendered by sepolia.js, extract proposal addresses, and inject
   * (or replace) a bond panel inside each card.
   */
  async function injectAllPanels() {
    const cards = $$$('#sep-proposals .sep-card');
    const addrs = [];

    for (const card of cards) {
      // The proposal address shows up in the card title link.
      const link = card.querySelector('.sep-card-title a');
      if (!link) continue;
      const href = link.getAttribute('href') || '';
      const m = href.match(/0x[a-fA-F0-9]{40}/);
      if (!m) continue;
      const propAddr = ethers.getAddress(m[0]);
      addrs.push(propAddr);
      card.dataset.propAddr = propAddr;
    }

    knownProposalAddrs = new Set(addrs.map(a => a.toLowerCase()));

    // Fetch state for all proposals in parallel.
    const results = await Promise.all(addrs.map(async (a) => {
      const s = await loadProposalState(a);
      proposalState.set(a.toLowerCase(), s);
      return { addr: a, s };
    }));

    for (const { addr, s } of results) {
      const card = $$(`#sep-proposals .sep-card[data-prop-addr="${addr}"]`);
      if (!card) continue;
      // Remove existing panel (idempotent re-render).
      const old = card.querySelector('.bond-panel');
      if (old) old.remove();
      card.insertAdjacentHTML('beforeend', renderBondPanel(addr, s));
    }

    wireActionButtons();
    await refreshWithdrawBanner();
  }

  function wireActionButtons() {
    for (const btn of $$$('.bond-action-btn[data-action]')) {
      // Avoid double-wiring.
      if (btn.dataset.wired === '1') continue;
      btn.dataset.wired = '1';
      const action = btn.dataset.action;
      const prop = btn.dataset.prop;
      btn.addEventListener('click', () => {
        if (action === 'yes')  onPlaceYesBond(prop);
        if (action === 'no')   onPlaceNoBond(prop);
        if (action === 'grad') onTryGraduate(prop);
      });
    }
  }

  // ─── Wallet ──────────────────────────────────────────────────────────

  async function ensureSigner() {
    if (signer && connectedWallet) return signer;
    signer = window.activeSigner || await window.connectWallet();
    connectedWallet = window.connectedWallet || await signer.getAddress();
    return signer;
  }

  window.addEventListener('fao:walletChanged', (ev) => {
    signer = ev.detail?.signer || null;
    connectedWallet = ev.detail?.wallet || null;
    if (provider) refreshWithdrawBanner().catch(console.error);
  });

  async function refreshWithdrawBanner() {
    if (!connectedWallet) { renderWithdrawBanner(0n); return; }
    const arb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, provider);
    const owed = await safe(() => arb.withdrawable(connectedWallet), 0n);
    renderWithdrawBanner(owed);
  }

  // ─── Status messaging per card ───────────────────────────────────────

  function setStatus(propAddr, html, kind) {
    const el = $$(`[data-prop-status="${propAddr}"]`);
    if (!el) return;
    el.innerHTML = html;
    el.className = `bond-status bond-status-${kind || 'info'}`;
  }

  // ─── Write path ──────────────────────────────────────────────────────

  /**
   * Ensure the proposal exists in the arbitration contract. Stub-bridge bootstrap:
   * the first escalator pays to call createProposalWithId(arbId, baseX).
   */
  async function ensureProposalCreated(propAddr, signerLocal) {
    const arb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, provider);
    const arbId = arbIdFor(propAddr);
    let exists = true;
    try { await arb.getProposal(arbId); }
    catch (_) { exists = false; }
    if (exists) return;

    setStatus(propAddr, 'Bootstrapping arbitration proposal (first escalator only)…', 'pending');
    const writeArb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, signerLocal);
    const tx = await writeArb.createProposalWithId(arbId, baseX || 1000000000000000n /* 0.001 WETH */);
    setStatus(propAddr, `Bootstrap tx: <a href="${explorerTx(tx.hash)}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>`, 'pending');
    await tx.wait();
  }

  /**
   * Ensure caller has approved arbitration to spend `amount` of WETH; submit approval
   * tx if needed.
   */
  async function ensureWethAllowance(amount, signerLocal, propAddr) {
    const weth = new ethers.Contract(WETH_ADDR, WETH_ABI, signerLocal);
    const allow = await weth.allowance(connectedWallet, arbitrationAddr());
    if (allow >= amount) return;
    setStatus(propAddr, 'Approving WETH spend…', 'pending');
    // Approve a generous amount so subsequent bonds don't re-prompt unnecessarily.
    const tx = await weth.approve(arbitrationAddr(), amount * 4n);
    setStatus(propAddr, `Approve tx: <a href="${explorerTx(tx.hash)}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>`, 'pending');
    await tx.wait();
  }

  /**
   * If WETH balance < needed, prompt the user to wrap ETH into WETH inline.
   * Resolves with true if balance is now sufficient, false if the user cancelled.
   */
  async function ensureWethBalance(needed, signerLocal, propAddr) {
    const weth = new ethers.Contract(WETH_ADDR, WETH_ABI, signerLocal);
    const bal = await weth.balanceOf(connectedWallet);
    if (bal >= needed) return true;

    const shortBy = needed - bal;
    const ethBal = await provider.getBalance(connectedWallet);
    if (ethBal < shortBy) {
      throw new Error(`Insufficient ETH+WETH. Need ${ethers.formatEther(needed)} WETH; have ${ethers.formatEther(bal)} WETH + ${ethers.formatEther(ethBal)} ETH.`);
    }

    const ok = await window.faoConfirm({
      title: 'Wrap ETH → WETH',
      message: `You have ${ethers.formatEther(bal)} WETH but need ${ethers.formatEther(needed)} WETH. Wrap ${ethers.formatEther(shortBy)} ETH → WETH now?`,
      okLabel: 'Wrap',
    });
    if (!ok) return false;

    setStatus(propAddr, `Wrapping ${ethers.formatEther(shortBy)} ETH → WETH…`, 'pending');
    const tx = await weth.deposit({ value: shortBy });
    setStatus(propAddr, `Wrap tx: <a href="${explorerTx(tx.hash)}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>`, 'pending');
    await tx.wait();
    return true;
  }

  // ─── Actions ─────────────────────────────────────────────────────────

  async function onPlaceYesBond(propAddr) {
    try {
      const sig = await ensureSigner();
      let s = await loadProposalState(propAddr);
      proposalState.set(propAddr.toLowerCase(), s);

      const minByActivation = s.minActivationBond || baseX;
      const minByFlip = s.noBond.amount > 0n ? s.noBond.amount * 2n : 0n;
      // baseX is also a safe fallback minimum for the very first bond.
      let minAmount = minByActivation;
      if (minByFlip > minAmount) minAmount = minByFlip;
      if (baseX > minAmount && s.state === 0) minAmount = baseX;

      const defaultEth = ethers.formatEther(minAmount);
      const minDesc = (minByFlip > 0n ? '2× current NO bond' : 'activation minimum');
      const input = await window.faoPrompt({
        title: `YES bond for ${propAddr.slice(0,10)}…`,
        message: `Minimum: ${defaultEth} WETH (${minDesc}). Enter amount in WETH:`,
        defaultValue: defaultEth,
        placeholder: '0.001',
        validate: (raw) => {
          if (!raw || !raw.trim()) return 'Enter a positive WETH amount.';
          let parsed;
          try { parsed = ethers.parseEther(raw.trim()); } catch (_) { return 'Not a valid number.'; }
          if (parsed < minAmount) return `Below minimum ${ethers.formatEther(minAmount)} WETH.`;
          return '';
        },
      });
      if (input == null) { setStatus(propAddr, '', 'info'); return; }

      let amount;
      try { amount = ethers.parseEther(input.trim()); }
      catch (_) { throw new Error(`Invalid amount: ${input}`); }

      if (amount < minAmount) {
        throw new Error(`Amount ${ethers.formatEther(amount)} below minimum ${ethers.formatEther(minAmount)} WETH.`);
      }

      const writeArb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, sig);
      const gasEstimate = s.exists
        ? await safe(() => writeArb.placeYesBond.estimateGas(s.arbId, amount), null)
        : null;
      const ok = await showBondConfirm([
        { label: 'Action', value: 'Place YES bond' },
        { label: 'Proposal', value: fmtAddr(propAddr) },
        { label: 'Arbitration id', value: s.arbId.toString() },
        { label: 'WETH amount', value: fmtWeth(amount) },
        { label: 'Approval', value: 'WETH approval may be required' },
        { label: 'Gas estimate', value: s.exists ? fmtGas(gasEstimate) : 'Bootstrap required before estimate' },
      ], 'Confirm YES bond');
      if (!ok) { setStatus(propAddr, 'Cancelled before wallet confirmation.', 'info'); return; }

      await ensureProposalCreated(propAddr, sig);
      s = await loadProposalState(propAddr);
      proposalState.set(propAddr.toLowerCase(), s);

      const balOk = await ensureWethBalance(amount, sig, propAddr);
      if (!balOk) { setStatus(propAddr, 'Cancelled.', 'info'); return; }
      await ensureWethAllowance(amount, sig, propAddr);

      setStatus(propAddr, 'Submitting YES bond…', 'pending');
      const tx = await writeArb.placeYesBond(s.arbId, amount);
      setStatus(propAddr, `Tx: <a href="${explorerTx(tx.hash)}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>`, 'pending');
      const rec = await tx.wait();
      setStatus(propAddr, `✓ Placed in block ${rec.blockNumber}.`, 'ok');
      await refreshCard(propAddr);
    } catch (err) {
      console.error('[bonds] onPlaceYesBond failed', err);
      setStatus(propAddr, `Failed: ${escapeHtml(err.shortMessage || err.message || String(err))}`, 'error');
    }
  }

  async function onPlaceNoBond(propAddr) {
    try {
      const sig = await ensureSigner();
      const s = await loadProposalState(propAddr);
      proposalState.set(propAddr.toLowerCase(), s);

      if (s.state !== 1) throw new Error('Proposal is not in YES state — cannot place NO bond.');
      const amount = s.yesBond.amount;
      if (amount === 0n) throw new Error('Current YES bond is zero.');

      const writeArb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, sig);
      const gasEstimate = await safe(() => writeArb.placeNoBond.estimateGas(s.arbId), null);
      const ok = await showBondConfirm([
        { label: 'Action', value: 'Place NO bond' },
        { label: 'Proposal', value: fmtAddr(propAddr) },
        { label: 'Arbitration id', value: s.arbId.toString() },
        { label: 'WETH amount', value: fmtWeth(amount) },
        { label: 'Approval', value: 'WETH approval may be required' },
        { label: 'Gas estimate', value: fmtGas(gasEstimate) },
      ], 'Confirm NO bond');
      if (!ok) { setStatus(propAddr, 'Cancelled before wallet confirmation.', 'info'); return; }

      const balOk = await ensureWethBalance(amount, sig, propAddr);
      if (!balOk) { setStatus(propAddr, 'Cancelled.', 'info'); return; }
      await ensureWethAllowance(amount, sig, propAddr);

      setStatus(propAddr, `Matching YES bond (${fmtWeth(amount)})…`, 'pending');
      const tx = await writeArb.placeNoBond(s.arbId);
      setStatus(propAddr, `Tx: <a href="${explorerTx(tx.hash)}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>`, 'pending');
      const rec = await tx.wait();
      setStatus(propAddr, `✓ Matched in block ${rec.blockNumber}.`, 'ok');
      await refreshCard(propAddr);
    } catch (err) {
      console.error('[bonds] onPlaceNoBond failed', err);
      setStatus(propAddr, `Failed: ${escapeHtml(err.shortMessage || err.message || String(err))}`, 'error');
    }
  }

  async function onTryGraduate(propAddr) {
    try {
      const sig = await ensureSigner();
      const s = proposalState.get(propAddr.toLowerCase());
      if (!s) throw new Error('Proposal state not loaded.');

      const writeArb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, sig);
      const gasEstimate = await safe(() => writeArb.tryGraduate.estimateGas(s.arbId), null);
      const ok = await showBondConfirm([
        { label: 'Action', value: 'Try graduate proposal' },
        { label: 'Proposal', value: fmtAddr(propAddr) },
        { label: 'Arbitration id', value: s.arbId.toString() },
        { label: 'Current YES bond', value: fmtWeth(s.yesBond.amount) },
        { label: 'Gas estimate', value: fmtGas(gasEstimate) },
      ], 'Confirm graduate');
      if (!ok) { setStatus(propAddr, 'Cancelled before wallet confirmation.', 'info'); return; }

      setStatus(propAddr, 'Attempting graduation…', 'pending');
      const tx = await writeArb.tryGraduate(s.arbId);
      setStatus(propAddr, `Tx: <a href="${explorerTx(tx.hash)}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>`, 'pending');
      const rec = await tx.wait();
      setStatus(propAddr, `✓ Graduated in block ${rec.blockNumber}.`, 'ok');
      await refreshCard(propAddr);
    } catch (err) {
      console.error('[bonds] onTryGraduate failed', err);
      setStatus(propAddr, `Failed: ${escapeHtml(err.shortMessage || err.message || String(err))}`, 'error');
    }
  }

  async function onWithdraw() {
    try {
      const sig = await ensureSigner();
      const writeArb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, sig);
      const tx = await writeArb.withdraw();
      const mount = $$('#sep-bonds-mount');
      if (mount) mount.innerHTML = `<p class="bond-status bond-status-pending" role="status" aria-live="polite" aria-atomic="true">Withdraw tx: <a href="${explorerTx(tx.hash)}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a></p>`;
      await tx.wait();
      await refreshWithdrawBanner();
    } catch (err) {
      console.error('[bonds] onWithdraw failed', err);
      const mount = $$('#sep-bonds-mount');
      if (mount) mount.innerHTML = `<p class="bond-status bond-status-error" role="status" aria-live="polite" aria-atomic="true">Withdraw failed: ${escapeHtml(err.shortMessage || err.message || String(err))}</p>`;
    }
  }

  async function refreshCard(propAddr) {
    const s = await loadProposalState(propAddr);
    proposalState.set(propAddr.toLowerCase(), s);
    safetyActive = await safe(() => {
      const arb = new ethers.Contract(arbitrationAddr(), ARBITRATION_ABI, provider);
      return arb.safetyModeActive();
    }, safetyActive);

    const card = $$(`#sep-proposals .sep-card[data-prop-addr="${propAddr}"]`);
    if (!card) return;
    const old = card.querySelector('.bond-panel');
    if (old) old.remove();
    card.insertAdjacentHTML('beforeend', renderBondPanel(propAddr, s));
    wireActionButtons();
    await refreshWithdrawBanner();
  }

  // ─── Boot ────────────────────────────────────────────────────────────

  function observeProposalsContainer() {
    const container = $$('#sep-proposals');
    if (!container) return;
    // Re-inject panels whenever sepolia.js rewrites the cards.
    const obs = new MutationObserver(() => {
      // Debounce: avoid hammering RPC on burst mutations.
      clearTimeout(observeProposalsContainer._t);
      observeProposalsContainer._t = setTimeout(() => { injectAllPanels(); }, 100);
    });
    obs.observe(container, { childList: true });
  }

  async function init() {
    await ensureEthers();
    provider = new ethers.JsonRpcProvider(rpcUrl());

    // Wait for shared.js to publish window.activeInstance.
    if (!window.activeInstance) {
      await new Promise((resolve) => {
        window.addEventListener('fao:sharedReady', resolve, { once: true });
      });
    }

    await loadGlobals();
    observeProposalsContainer();
    // Initial pass once sepolia.js has populated cards.
    setTimeout(() => injectAllPanels(), 500);

    // When registry.js switches the active instance, drop cached bond state
    // (the arbitration contract changes), reload globals against the new
    // arbitration address, and re-inject panels for whatever sepolia.js
    // re-renders.
    window.addEventListener('fao:activeInstanceChanged', async () => {
      proposalState.clear();
      const mount = $$('#sep-bonds-mount');
      if (mount) mount.innerHTML = '';
      try {
        await loadGlobals();
        // sepolia.js will replace the cards shortly; the MutationObserver above
        // will re-trigger injectAllPanels. Be defensive and schedule one too.
        setTimeout(() => injectAllPanels(), 600);
      } catch (err) {
        console.error('[bonds] instance change refresh failed', err);
      }
    });

    // Refresh bond-only state on our own cadence (independent of sepolia.js).
    setInterval(async () => {
      await loadGlobals();
      await injectAllPanels();
    }, REFRESH_INTERVAL);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
