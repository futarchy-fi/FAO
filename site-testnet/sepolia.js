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
 * Deployed addresses sourced from docs/sepolia-deployment-v0.md
 * (chain 11155111, branch arbitration/onchain-futarchy-v0).
 */

(() => {
  'use strict';

  // Public RPC with permissive CORS; drpc.org returns 503 sometimes.
  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const REFRESH_INTERVAL = 30_000;

  const ADDRS = {
    fao:             '0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65',
    weth:            '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14',
    spotPool:        '0x5dac596a38a294c03d7fac840d031708c970da79',
    proposalImpl:    '0x098990c0e1a4a84f03b236f16cd34ed140803555',
    resolver:        '0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a',
    factory:         '0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0',
    orchestrator:    '0x7DF66Fd816c09bb534136C5688B55BBA9398d262',
    arbitration:     '0x9D7692738a4d323338b9007d65d7F79e013B3476',
    ctfRouter:       '0x5C2c0684D3CFA0FAd75C374993b9A60b4230128B',
    ctfOracle:       '0x9EcB08E5B0c2B4ece148A55073c62f5fb4e0055F',
    evaluator:       '0xdE54C348Cd845eb0408f8dA665245C69aFF640Cf',
    ctf:             '0x8bdC504dC3A05310059c1c67E0A2667309D27B93',
    operator:        '0x693E3FB46Bb36eE43C702FE94f9463df0691b43d',
  };

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

  async function init() {
    provider = new ethers.JsonRpcProvider(RPC);
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
    const factory = new ethers.Contract(ADDRS.factory, FACTORY_ABI, provider);
    const resolver = new ethers.Contract(ADDRS.resolver, RESOLVER_ABI, provider);
    const ctf = new ethers.Contract(ADDRS.ctf, CTF_ABI, provider);

    const [blockNumber, marketsCount, opBalance, oracleAddr] = await Promise.all([
      safe(() => provider.getBlockNumber(), 0),
      safe(() => factory.marketsCount(), 0n),
      safe(() => provider.getBalance(ADDRS.operator), 0n),
      safe(() => factory.oracle(), ethers.ZeroAddress),
    ]);

    // Header stats.
    $$('#sep-block').textContent = blockNumber;
    $$('#sep-markets-count').textContent = marketsCount.toString();
    $$('#sep-op-balance').textContent = fmtEth(opBalance);
    $$('#sep-oracle-ok').textContent =
      oracleAddr.toLowerCase() === ADDRS.resolver.toLowerCase() ? '✓ wired' : '✗ mismatch';
    $$('#sep-updated').textContent = new Date().toLocaleTimeString();

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

  // ─── Create Proposal (browser wallet) ─────────────────────────────────

  const FACTORY_WRITE_ABI = [
    'function createProposal((string,string,address,address)) returns (address)',
  ];

  let wallet = null;
  let signer = null;

  async function connectWallet() {
    if (!window.ethereum) {
      setStatus('No injected wallet found. Install MetaMask or use a wallet browser.', 'error');
      return;
    }
    try {
      const browserProvider = new ethers.BrowserProvider(window.ethereum);
      const accounts = await browserProvider.send('eth_requestAccounts', []);
      const network = await browserProvider.getNetwork();
      if (Number(network.chainId) !== 11155111) {
        // Try to switch to Sepolia.
        try {
          await window.ethereum.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: '0xaa36a7' }],
          });
        } catch (switchErr) {
          setStatus('Switch your wallet to Sepolia (chainId 11155111) and reconnect.', 'error');
          return;
        }
      }
      signer = await browserProvider.getSigner();
      wallet = accounts[0];
      const btn = $$('#connect-wallet');
      const submit = $$('#create-submit');
      btn.textContent = `${wallet.slice(0, 6)}…${wallet.slice(-4)}`;
      btn.disabled = true;
      submit.disabled = false;
      submit.textContent = 'Submit proposal';
      setStatus('Wallet connected. Fill in the form and submit.', 'ok');
    } catch (err) {
      console.error('[sepolia] connectWallet failed', err);
      setStatus(`Connection failed: ${err.message || err}`, 'error');
    }
  }

  async function submitProposal() {
    const name = ($$('#create-name').value || '').trim();
    const desc = ($$('#create-desc').value || '').trim();
    if (!name) { setStatus('Name is required.', 'error'); return; }
    if (!signer) { setStatus('Connect wallet first.', 'error'); return; }
    const factory = new ethers.Contract(ADDRS.factory, FACTORY_WRITE_ABI, signer);
    setStatus('Submitting transaction…', 'pending');
    try {
      const params = [name, desc, ADDRS.fao, ADDRS.weth];
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
    const resolver = new ethers.Contract(ADDRS.resolver, RESOLVER_WRITE_ABI, signer);
    const origLabel = btn.textContent;
    btn.disabled = true;
    btn.textContent = 'Resolving…';
    setCardActionStatus(propAddr, 'Submitting resolve transaction…', 'pending');
    try {
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
