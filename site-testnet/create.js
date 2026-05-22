/* create.js — Create-Futarchy form handler.
 *
 * 2-phase deploy:
 *   1. createFutarchyPart1 — deploys token (0 supply) + InstanceSale (granted
 *      MINTER_ROLE) + ParameterizedArbitration. Registers a slot.
 *   2. createFutarchyPart2(id) — deploys resolver + factory + orchestrator +
 *      spot pool, wires them, finalizes.
 *
 * Both txs run on the same MetaMask session. The page redirects to /?inst=<id>
 * once Part2 confirms so the user lands on the home page with their new
 * futarchy as the active one.
 */

(() => {
  'use strict';

  const REGISTRY_ADDR = '0x18D1f4e57412b48436C7825B9018437C235bBC5C'; // v5
  const ZERO = '0x0000000000000000000000000000000000000000';

  const $$ = (sel) => document.querySelector(sel);
  const escapeHtml = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  const explorerTx = (h) => `https://sepolia.etherscan.io/tx/${h}`;

  function isZeroAddress(a) { return !a || a.toLowerCase() === ZERO; }

  async function getRegistryAbi() {
    if (!window.loadFaoAbi) throw new Error('ABI loader unavailable.');
    return window.loadFaoAbi('FutarchyRegistry');
  }

  function setStatus(html, kind) {
    const el = $$('#create-instance-status');
    if (!el) return;
    el.innerHTML = html;
    el.className = `create-instance-status create-instance-status-${kind || 'info'}`;
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

  function fmtGas(gas) {
    return gas == null ? 'Estimate unavailable until wallet connect' : `${gas.toString()} gas`;
  }

  async function estimatePart1Gas(args) {
    if (!window.activeSigner) return null;
    try {
      const registryAbi = await getRegistryAbi();
      const reg = new ethers.Contract(REGISTRY_ADDR, registryAbi, window.activeSigner);
      return await reg.createFutarchyPart1.estimateGas(...args);
    } catch (_) {
      return null;
    }
  }

  function showCreateConfirm(rows) {
    return new Promise((resolve) => {
      const card = $$('#confirm-card-create');
      const rowsEl = $$('#confirm-card-create-rows');
      const confirm = $$('#confirm-card-create-confirm');
      const cancel = $$('#confirm-card-create-cancel');
      if (!card || !rowsEl || !confirm || !cancel) {
        resolve(true);
        return;
      }
      renderConfirmRows(rowsEl, rows);
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

  async function onSubmit(ev) {
    ev.preventDefault();

    if (isZeroAddress(REGISTRY_ADDR)) {
      setStatus('FutarchyRegistry is not deployed.', 'error');
      return;
    }

    const name = ($$('#ci-name').value || '').trim();
    const symbol = ($$('#ci-symbol').value || '').trim();
    const description = ($$('#ci-description').value || '').trim();
    const priceStr = ($$('#ci-price').value || '').trim();
    const minSoldStr = ($$('#ci-min-sold').value || '').trim();
    const saleDurMin = Number($$('#ci-sale-duration').value || '60');
    const timeoutMin = Number($$('#ci-timeout').value || '120');
    const twapMin = Number($$('#ci-twap').value || '60');
    const baseBondStr = ($$('#ci-bond').value || '').trim();

    if (!name)   { setStatus('Name is required.', 'error'); return; }
    if (!symbol) { setStatus('Symbol is required.', 'error'); return; }
    if (!priceStr) { setStatus('Sale price is required.', 'error'); return; }
    if (!minSoldStr) { setStatus('Min initial sold is required.', 'error'); return; }
    if (!baseBondStr) { setStatus('Base bond is required.', 'error'); return; }
    if (!isFinite(saleDurMin) || saleDurMin <= 0) { setStatus('Sale phase must be > 0 min.', 'error'); return; }
    if (!isFinite(timeoutMin) || timeoutMin <= 0) { setStatus('Timeout must be > 0 min.', 'error'); return; }
    if (!isFinite(twapMin) || twapMin <= 0) { setStatus('TWAP window must be > 0 min.', 'error'); return; }

    let initialPriceWei;
    try { initialPriceWei = ethers.parseEther(priceStr); }
    catch (_) { setStatus(`Invalid price: ${escapeHtml(priceStr)}`, 'error'); return; }
    if (initialPriceWei <= 0n) { setStatus('Sale price must be > 0.', 'error'); return; }

    let minInitialSold;
    try { minInitialSold = BigInt(minSoldStr); }
    catch (_) { setStatus(`Invalid min-sold: ${escapeHtml(minSoldStr)}`, 'error'); return; }
    if (minInitialSold <= 0n) { setStatus('Min initial sold must be > 0.', 'error'); return; }

    let bondWei;
    try { bondWei = ethers.parseEther(baseBondStr); }
    catch (_) { setStatus(`Invalid bond: ${escapeHtml(baseBondStr)}`, 'error'); return; }

    const initialPhaseSec = Math.floor(saleDurMin * 60);
    const timeoutSec = Math.floor(timeoutMin * 60);
    const twapSec = Math.floor(twapMin * 60);
    const part1Args = [
      name, symbol, description,
      initialPriceWei, minInitialSold, BigInt(initialPhaseSec),
      timeoutSec, twapSec, bondWei,
    ];

    const gasEstimate = await estimatePart1Gas(part1Args);
    const ok = await showCreateConfirm([
      { label: 'Action', value: 'Create futarchy in two transactions' },
      { label: 'Name / symbol', value: `${name} / ${symbol}` },
      { label: 'Sale price', value: `${priceStr} ETH per token` },
      { label: 'Min initial sold', value: minInitialSold.toString() },
      { label: 'Initial phase', value: `${initialPhaseSec} seconds` },
      { label: 'Timeout / TWAP', value: `${timeoutSec}s / ${twapSec}s` },
      { label: 'Base bond', value: `${baseBondStr} WETH` },
      { label: 'Part 1 gas estimate', value: fmtGas(gasEstimate) },
    ]);
    if (!ok) {
      setStatus('Create cancelled before wallet confirmation.', 'info');
      return;
    }

    try {
      const signer = await window.connectWallet();
      const registryAbi = await getRegistryAbi();
      const reg = new ethers.Contract(REGISTRY_ADDR, registryAbi, signer);

      // ─── Step 1/2 ──────────────────────────────────────────────────────
      setStatus('Step 1/2: deploying token + sale + arbitration…', 'pending');
      const tx1 = await reg.createFutarchyPart1(...part1Args);
      setStatus(
        `Step 1/2: tx sent <a href="${explorerTx(tx1.hash)}" target="_blank" rel="noopener">${tx1.hash.slice(0, 10)}…</a>. Waiting confirmation…`,
        'pending',
      );
      const rec1 = await tx1.wait();

      // Parse new id from event or fall back to instancesCount - 1.
      let newId;
      const part1Topic = ethers.id(
        'FutarchyPart1Created(uint256,address,string,string,address,address,address)'
      );
      const part1Log = rec1.logs && rec1.logs.find(l =>
        l.address.toLowerCase() === REGISTRY_ADDR.toLowerCase() && l.topics[0] === part1Topic
      );
      if (part1Log) newId = Number(ethers.toBigInt(part1Log.topics[1]));
      else {
        const n = await reg.instancesCount();
        newId = Number(n) - 1;
      }

      // ─── Step 2/2 ──────────────────────────────────────────────────────
      setStatus(`Step 1/2 ✓ id=${newId}. Step 2/2: deploying resolver + factory + orchestrator + spot pool…`, 'pending');
      const tx2 = await reg.createFutarchyPart2(newId, { gasLimit: 16_000_000n });
      setStatus(
        `Step 2/2: tx sent <a href="${explorerTx(tx2.hash)}" target="_blank" rel="noopener">${tx2.hash.slice(0, 10)}…</a>. Waiting confirmation…`,
        'pending',
      );
      await tx2.wait();

      setStatus(`Done! Redirecting to your new futarchy (id ${newId})…`, 'ok');
      setTimeout(() => { window.location.href = `./?inst=${newId}`; }, 1500);
    } catch (err) {
      console.error('[create] failed', err);
      const msg = err?.shortMessage || err?.message || String(err);
      setStatus(`Create failed: ${escapeHtml(msg)}`, 'error');
    }
  }

  function start() {
    const form = $$('#create-instance-form');
    if (form) form.addEventListener('submit', onSubmit);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', start);
  } else {
    start();
  }
})();
