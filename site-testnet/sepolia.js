/* FAO v0 — Sepolia testnet dashboard
 *
 * Polls the deployed FAO v0 stack on Sepolia and renders:
 *   - global stats (marketsCount, wallet, latest block)
 *   - per-proposal cards: name, description, questionId, conditionId,
 *     resolver binding state (yesPool, noPool, anchor, resolved, accepted),
 *     CTF payouts.
 *
 * Uses ethers.js v6 (loaded by index.html).
 *
 * Multi-instance refactor (FutarchyRegistry era):
 *   Per-instance addresses (factory, resolver, orchestrator, arbitration,
 *   token, spotPool) come from `window.activeInstance`, populated by
 *   registry.js. Shared infra addresses (CTF, evaluator, ctfRouter, ctfOracle,
 *   WETH, proposal impl, operator) stay in SHARED_ADDRS — same across all
 *   instances on a given chain.
 *
 *   When registry.js fires the `fao:activeInstanceChanged` event we clear
 *   the visible list and re-poll against the new instance.
 *
 * Deployed addresses originally sourced from docs/sepolia-deployment-v0.md
 * (chain 11155111, branch arbitration/onchain-futarchy-v0).
 */

(() => {
  'use strict';

  // Public RPC with permissive CORS; drpc.org returns 503 sometimes.
  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const REFRESH_INTERVAL = 30_000;

  // Shared infra — identical for every futarchy instance on Sepolia.
  const SHARED_ADDRS = {
    weth:            '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
    proposalImpl:    '0x098990c0e1a4a84f03b236f16cd34ed140803555',
    ctfRouter:       '0x5C2c0684D3CFA0FAd75C374993b9A60b4230128B',
    ctfOracle:       '0x9EcB08E5B0c2B4ece148A55073c62f5fb4e0055F',
    evaluator:       '0xdE54C348Cd845eb0408f8dA665245C69aFF640Cf',
    ctf:             '0x8bdC504dC3A05310059c1c67E0A2667309D27B93',
    operator:        '0x693E3FB46Bb36eE43C702FE94f9463df0691b43d',
  };

  // Hardcoded FAO bootstrap — used until window.activeInstance is populated
  // (registry.js initializes after this file's DOMContentLoaded handler runs).
  const BOOTSTRAP_INSTANCE = {
    id: 0,
    name: 'FAO',
    symbol: 'FAO',
    token:        '0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65',
    spotPool:     '0x5dac596a38a294c03d7fac840d031708c970da79',
    resolver:     '0xC17408966d424A3fc8fAf9F007413FA842bDB479',
    factory:      '0x208d0760c742a4fb46932811ec843f08752f6ab3',
    orchestrator: '0xc17D88Bf0c16c0c2F1dEBd375163Fc538aB5aBF5',
    adapter:      '0x8Ccc8d0E6cf2685De388Bb2Ef764015268364B5A',
    arbitration:  '0x9D7692738a4d323338b9007d65d7F79e013B3476',
  };

  /** Return the active futarchy instance, falling back to bootstrap if registry.js
   *  hasn't published one yet. */
  function activeInstance() {
    return (typeof window !== 'undefined' && window.activeInstance)
      ? window.activeInstance
      : BOOTSTRAP_INSTANCE;
  }

  /** Backwards-compatible alias used internally for the FAO token address.
   *  Returns the active instance's token (used by createProposal as the
   *  "company" side of the conditional pool). */
  function instanceToken() { return activeInstance().token; }

  const FACTORY_ABI = [
    'function marketsCount() view returns (uint256)',
    'function proposals(uint256) view returns (address)',
    'function oracle() view returns (address)',
  ];

  const PROPOSAL_ABI = [
    'function marketName() view returns (string)',
    'function description() view returns (string)',
    'function questionId() view returns (bytes32)',
    'function conditionId() view returns (bytes32)',
  ];

  const RESOLVER_ABI = [
    'function bindings(address) view returns (address yesPool, address noPool, address companyToken, address currencyToken, bytes32 questionId, uint48 anchorTimestamp, bool resolved, bool accepted)',
    'function isReadyToResolve(address) view returns (bool)',
    'function windowEndOf(address) view returns (uint256)',
    'function TIMEOUT() view returns (uint32)',
    'function TWAP_WINDOW() view returns (uint32)',
  ];

  const RESOLVER_WRITE_ABI = [
    'function resolve(address proposal)',
  ];

  const CTF_ABI = [
    'function payoutNumerators(bytes32, uint256) view returns (uint256)',
    'function payoutDenominator(bytes32) view returns (uint256)',
  ];

  function $$(sel, root = document) { return root.querySelector(sel); }

  function fmtAddr(a) {
    if (!a || a === ethers.ZeroAddress) return '—';
    return `${a.slice(0, 6)}…${a.slice(-4)}`;
  }
  function fmtEth(wei) {
    return ethers.formatEther(wei).slice(0, 9) + ' ETH';
  }
  function fmtTimestamp(secs) {
    if (!secs || secs === 0n) return '—';
    return new Date(Number(secs) * 1000).toLocaleString();
  }

  function explorerAddr(addr){ return `https://sepolia.etherscan.io/address/${addr}`; }

  async function safe(fn, fallback) {
    try { return await fn(); } catch (_) { return fallback; }
  }

  let provider;

  /** Clear the proposals list — used when switching futarchy instances so the
   *  old instance's cards don't briefly remain visible. */
  function clearList() {
    const container = $$('#sep-proposals');
    if (container) container.innerHTML = '<p class="sep-empty">Loading…</p>';
    const stats = ['sep-markets-count', 'sep-oracle-ok'];
    for (const id of stats) {
      const el = $$('#' + id);
      if (el) el.textContent = '…';
    }
  }

  async function init() {
    provider = new ethers.JsonRpcProvider(RPC);

    // Listen for instance switches from shared.js. Clear + refresh.
    window.addEventListener('fao:activeInstanceChanged', () => {
      clearList();
      Promise.resolve().then(refresh);
    });

    // shared.js boots asynchronously — wait for it before the first refresh
    // so window.activeInstance is set.
    if (!window.activeInstance) {
      await new Promise((resolve) => {
        window.addEventListener('fao:sharedReady', resolve, { once: true });
      });
    }

    await refresh();
    setInterval(refresh, REFRESH_INTERVAL);
  }

  async function refresh() {
    try {
      await refreshOnce();
    } catch (err) {
      console.error('[sepolia] refresh failed', err);
      const container = $$('#sep-proposals');
      if (container) {
        container.innerHTML = `<p class="sep-empty">Error loading proposals: ${escapeHtml(String(err && err.message || err))}. Check console.</p>`;
      }
    }
  }

  async function refreshOnce() {
    const inst = activeInstance();
    if (!inst || !inst.factory) {
      throw new Error('No active futarchy instance — registry.js failed to publish one.');
    }
    const factory = new ethers.Contract(inst.factory, FACTORY_ABI, provider);
    const resolver = new ethers.Contract(inst.resolver, RESOLVER_ABI, provider);
    const ctf = new ethers.Contract(SHARED_ADDRS.ctf, CTF_ABI, provider);

    const [blockNumber, marketsCount, opBalance, oracleAddr] = await Promise.all([
      safe(() => provider.getBlockNumber(), 0),
      safe(() => factory.marketsCount(), 0n),
      safe(() => provider.getBalance(SHARED_ADDRS.operator), 0n),
      safe(() => factory.oracle(), ethers.ZeroAddress),
    ]);

    // Header stats. Only the Home page renders these slots — guard against
    // missing nodes so the proposals page doesn't NPE.
    if ($$('#sep-block'))         $$('#sep-block').textContent = blockNumber;
    if ($$('#sep-markets-count')) $$('#sep-markets-count').textContent = marketsCount.toString();
    if ($$('#sep-op-balance'))    $$('#sep-op-balance').textContent = fmtEth(opBalance);
    if ($$('#sep-oracle-ok')) {
      $$('#sep-oracle-ok').textContent =
        oracleAddr.toLowerCase() === (inst.resolver || '').toLowerCase() ? '✓ wired' : '✗ mismatch';
    }
    if ($$('#sep-updated'))       $$('#sep-updated').textContent = new Date().toLocaleTimeString();

    // Per-proposal cards.
    const container = $$('#sep-proposals');
    const n = Number(marketsCount);
    if (n === 0) {
      container.innerHTML = '<p class="sep-empty">No proposals yet.</p>';
      return;
    }

    // Fetch all proposals in parallel.
    const idxs = Array.from({ length: n }, (_, i) => i);
    const cards = await Promise.all(idxs.map(async (i) => {
      const propAddr = await safe(() => factory.proposals(i), ethers.ZeroAddress);
      if (propAddr === ethers.ZeroAddress) return null;

      const p = new ethers.Contract(propAddr, PROPOSAL_ABI, provider);
      const [name, desc, qId, cId] = await Promise.all([
        safe(() => p.marketName(), '(unknown)'),
        safe(() => p.description(), ''),
        safe(() => p.questionId(), ethers.ZeroHash),
        safe(() => p.conditionId(), ethers.ZeroHash),
      ]);

      // Resolver binding (may be unbound for candidate-only proposals from LegitProposer).
      const binding = await safe(() => resolver.bindings(propAddr), null);

      let yesPool = ethers.ZeroAddress;
      let noPool = ethers.ZeroAddress;
      let anchorTs = 0n;
      let resolved = false;
      let accepted = false;
      let windowEnd = 0n;
      let readyToResolve = false;
      if (binding && binding[0] !== ethers.ZeroAddress) {
        yesPool = binding[0];
        noPool = binding[1];
        anchorTs = binding[5];
        resolved = binding[6];
        accepted = binding[7];
        windowEnd = await safe(() => resolver.windowEndOf(propAddr), 0n);
        readyToResolve = await safe(() => resolver.isReadyToResolve(propAddr), false);
      }

      // Payouts (only present if CTF.reportPayouts has been called).
      const yesNum = await safe(() => ctf.payoutNumerators(cId, 0), 0n);
      const noNum = await safe(() => ctf.payoutNumerators(cId, 1), 0n);
      const denom = await safe(() => ctf.payoutDenominator(cId), 0n);

      let status;
      if (resolved) {
        status = accepted ? 'resolved · YES' : 'resolved · NO';
      } else if (binding && binding[0] !== ethers.ZeroAddress) {
        status = readyToResolve ? 'ready to resolve' : 'in TWAP window';
      } else {
        status = 'candidate (unpromoted)';
      }

      return {
        i, propAddr, name, desc, qId, cId,
        yesPool, noPool, anchorTs, windowEnd,
        resolved, accepted, readyToResolve, status,
        yesNum: yesNum.toString(), noNum: noNum.toString(), denom: denom.toString(),
      };
    }));

    container.innerHTML = cards.filter(Boolean).reverse().map(renderCard).join('');
  }

  function renderCard(c) {
    const resolveBtn = c.readyToResolve && !c.resolved
      ? `<div class="sep-card-actions"><button class="bond-action-btn resolve-btn" data-prop="${c.propAddr}">Resolve now</button><span class="sep-card-action-status" data-prop-status="${c.propAddr}"></span></div>`
      : '';
    return `
      <div class="sep-card">
        <div class="sep-card-head">
          <span class="sep-card-idx">#${c.i}</span>
          <span class="sep-card-status sep-status-${c.resolved ? 'done' : c.readyToResolve ? 'ready' : 'live'}">${c.status}</span>
        </div>
        <h3 class="sep-card-title"><a href="${explorerAddr(c.propAddr)}" target="_blank" rel="noopener">${escapeHtml(c.name)}</a></h3>
        ${c.desc ? `<p class="sep-card-desc">${escapeHtml(c.desc)}</p>` : ''}
        <div class="sep-card-grid">
          <div><span>Proposal</span><a href="${explorerAddr(c.propAddr)}" target="_blank" rel="noopener">${fmtAddr(c.propAddr)}</a></div>
          <div><span>conditionId</span><span class="sep-mono">${c.cId.slice(0,10)}…</span></div>
          ${c.yesPool !== ethers.ZeroAddress ? `
          <div><span>YES pool</span><a href="${explorerAddr(c.yesPool)}" target="_blank" rel="noopener">${fmtAddr(c.yesPool)}</a></div>
          <div><span>NO pool</span><a href="${explorerAddr(c.noPool)}" target="_blank" rel="noopener">${fmtAddr(c.noPool)}</a></div>
          <div><span>Anchor</span><span>${fmtTimestamp(c.anchorTs)}</span></div>
          <div><span>Window end</span><span>${fmtTimestamp(c.windowEnd)}</span></div>` : ''}
          ${c.denom !== '0' ? `
          <div><span>CTF payouts</span><span class="sep-mono">[${c.yesNum}, ${c.noNum}] / ${c.denom}</span></div>` : ''}
        </div>
        ${resolveBtn}
      </div>
    `;
  }

  function escapeHtml(s) {
    if (typeof s !== 'string') return '';
    return s.replace(/[&<>"']/g, ch => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[ch]));
  }

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

  function showConfirmCard(action, rows) {
    return new Promise((resolve) => {
      const card = $$(`#confirm-card-${action}`);
      const rowsEl = $$(`#confirm-card-${action}-rows`);
      const confirm = $$(`#confirm-card-${action}-confirm`);
      const cancel = $$(`#confirm-card-${action}-cancel`);
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

  // ─── Create Proposal (browser wallet) ─────────────────────────────────

  const FACTORY_WRITE_ABI = [
    'function createProposal((string,string,address,address)) returns (address)',
  ];

  let wallet = null;
  let signer = null;

  async function connectWallet() {
    try {
      signer = window.activeSigner || await window.connectWallet();
      wallet = window.connectedWallet || await signer.getAddress();
      const btn = $$('#connect-wallet');
      const submit = $$('#create-submit');
      if (btn) {
        btn.textContent = fmtAddr(wallet);
        btn.disabled = true;
      }
      if (submit) {
        submit.disabled = false;
        submit.textContent = 'Submit proposal';
      }
      setStatus('Wallet connected. Fill in the form and submit.', 'ok');
    } catch (err) {
      console.error('[sepolia] connectWallet failed', err);
      setStatus(`Connection failed: ${err.message || err}`, 'error');
    }
  }

  window.addEventListener('fao:walletChanged', (ev) => {
    signer = ev.detail?.signer || null;
    wallet = ev.detail?.wallet || null;
    const btn = $$('#connect-wallet');
    const submit = $$('#create-submit');
    if (wallet && signer) {
      if (btn) {
        btn.textContent = fmtAddr(wallet);
        btn.disabled = true;
      }
      if (submit) {
        submit.disabled = false;
        submit.textContent = 'Submit proposal';
      }
    } else {
      if (btn) {
        btn.textContent = 'Connect wallet';
        btn.disabled = false;
      }
      if (submit) {
        submit.disabled = true;
        submit.textContent = 'Submit (connect wallet first)';
      }
    }
  });

  async function submitProposal() {
    const name = ($$('#create-name').value || '').trim();
    const desc = ($$('#create-desc').value || '').trim();
    if (!name) { setStatus('Name is required.', 'error'); return; }
    if (!signer) { setStatus('Connect wallet first.', 'error'); return; }
    const inst = activeInstance();
    if (!inst || !inst.factory) { setStatus('No active futarchy instance selected.', 'error'); return; }
    const factory = new ethers.Contract(inst.factory, FACTORY_WRITE_ABI, signer);
    try {
      const params = [name, desc, instanceToken(), SHARED_ADDRS.weth];
      const gasEstimate = await safe(() => factory.createProposal.estimateGas(params), null);
      const ok = await showConfirmCard('proposal', [
        { label: 'Action', value: 'Create proposal' },
        { label: 'Title', value: name },
        { label: 'Description', value: desc || '—' },
        { label: 'Company token', value: fmtAddr(instanceToken()) },
        { label: 'Bond currency', value: fmtAddr(SHARED_ADDRS.weth) },
        { label: 'Gas estimate', value: fmtGas(gasEstimate) },
      ]);
      if (!ok) {
        setStatus('Proposal cancelled before wallet confirmation.', 'info');
        return;
      }
      setStatus('Submitting transaction…', 'pending');
      const tx = await factory.createProposal(params);
      setStatus(`Tx sent: <a href="https://sepolia.etherscan.io/tx/${tx.hash}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>. Waiting confirmation…`, 'pending');
      const rec = await tx.wait();
      setStatus(`✓ Confirmed in block ${rec.blockNumber}. Refreshing list…`, 'ok');
      // Force a refresh.
      await refresh();
    } catch (err) {
      console.error('[sepolia] submitProposal failed', err);
      setStatus(`Failed: ${err.shortMessage || err.message || err}`, 'error');
    }
  }

  function setStatus(html, kind) {
    const el = $$('#create-status');
    if (!el) return;
    el.innerHTML = html;
    el.className = `create-status create-status-${kind || 'info'}`;
  }

  // ─── Resolve proposal (browser wallet) ───────────────────────────────
  // The TwapResolver.resolve(address) call is permissionless once the
  // 2h TIMEOUT has expired. We wire a delegated click handler so the
  // button works on cards that are re-rendered after a poll refresh.

  function setCardActionStatus(propAddr, html, kind) {
    const el = document.querySelector(`[data-prop-status="${propAddr}"]`);
    if (!el) return;
    el.innerHTML = html;
    el.className = `sep-card-action-status sep-card-action-status-${kind || 'info'}`;
  }

  async function resolveProposal(propAddr, btn) {
    if (!signer) {
      // Try to connect first; connectWallet() updates the top-of-page status.
      await connectWallet();
      if (!signer) {
        setCardActionStatus(propAddr, 'Connect wallet first.', 'error');
        return;
      }
    }
    const inst = activeInstance();
    if (!inst || !inst.resolver) {
      setCardActionStatus(propAddr, 'No active futarchy instance selected.', 'error');
      return;
    }
    const resolver = new ethers.Contract(inst.resolver, RESOLVER_WRITE_ABI, signer);
    const origLabel = btn.textContent;
    try {
      const gasEstimate = await safe(() => resolver.resolve.estimateGas(propAddr), null);
      const ok = await showConfirmCard('resolve', [
        { label: 'Action', value: 'Resolve proposal' },
        { label: 'Proposal', value: fmtAddr(propAddr) },
        { label: 'Resolver', value: fmtAddr(inst.resolver) },
        { label: 'Gas estimate', value: fmtGas(gasEstimate) },
      ]);
      if (!ok) {
        setCardActionStatus(propAddr, 'Resolve cancelled before wallet confirmation.', 'info');
        return;
      }
      btn.disabled = true;
      btn.textContent = 'Resolving…';
      setCardActionStatus(propAddr, 'Submitting resolve transaction…', 'pending');
      const tx = await resolver.resolve(propAddr);
      setCardActionStatus(
        propAddr,
        `Tx sent: <a href="https://sepolia.etherscan.io/tx/${tx.hash}" target="_blank" rel="noopener">${tx.hash.slice(0,10)}…</a>. Waiting confirmation…`,
        'pending',
      );
      const rec = await tx.wait();
      setCardActionStatus(propAddr, `Confirmed in block ${rec.blockNumber}. Refreshing…`, 'ok');
      await refresh();
    } catch (err) {
      console.error('[sepolia] resolveProposal failed', err);
      const msg = err && (err.shortMessage || err.message) || String(err);
      setCardActionStatus(propAddr, `Failed: ${escapeHtml(msg)}`, 'error');
      btn.disabled = false;
      btn.textContent = origLabel;
    }
  }

  function wireCreateUI() {
    const btn = $$('#connect-wallet');
    const submit = $$('#create-submit');
    if (btn) btn.addEventListener('click', connectWallet);
    if (submit) submit.addEventListener('click', submitProposal);

    // Delegated click handler for resolve buttons (cards are re-rendered every poll).
    document.addEventListener('click', (ev) => {
      const target = ev.target;
      if (!(target instanceof HTMLElement)) return;
      if (!target.classList.contains('resolve-btn')) return;
      const propAddr = target.getAttribute('data-prop');
      if (!propAddr) return;
      ev.preventDefault();
      resolveProposal(propAddr, target);
    });
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { init(); wireCreateUI(); });
  } else {
    init();
    wireCreateUI();
  }
})();
