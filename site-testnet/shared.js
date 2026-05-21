/* shared.js — multi-page glue for the FAO testnet site.
 *
 * Responsibilities (one source of truth across all pages):
 *   1. Inject the global topbar into `#topbar-root` (title, nav links,
 *      active-instance switcher chip, connect-wallet button).
 *   2. Load all `FutarchyRegistry` instances from Sepolia.
 *   3. Determine the active instance from `?inst=<id>` URL param (overrides
 *      localStorage) or `localStorage.faoActiveInstanceId` (fallback).
 *   4. Publish `window.activeInstance` + `window.allInstances` and fire
 *      `fao:activeInstanceChanged` on every change. Per-page scripts
 *      (sale.js, sepolia.js, bonds.js) listen and re-render.
 *   5. Manage wallet connection. Stores the signer at `window.activeSigner`
 *      and the address at `window.connectedWallet`. Fires `fao:walletChanged`.
 *
 * Page-specific scripts must `defer` AFTER shared.js so they can read window
 * state on their own DOMContentLoaded; alternatively, listen to the events.
 */

(() => {
  'use strict';

  // ─── Config ──────────────────────────────────────────────────────────
  const REGISTRY_ADDR = '0x45F1F8Bb80539cddFfB945dBe4C53A65d98296C0'; // v3
  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const STORAGE_KEY = 'faoActiveInstanceId';
  const SEPOLIA_CHAIN_ID = 11155111n;
  const ZERO = '0x0000000000000000000000000000000000000000';

  // FAO bootstrap, hardcoded so the page renders even pre-registry-load.
  const BOOTSTRAP_INSTANCE = {
    id: 0,
    name: 'FAO',
    symbol: 'FAO',
    description: 'Bootstrap futarchy instance for the FAO v0 testnet stack.',
    creator: '0x693E3FB46Bb36eE43C702FE94f9463df0691b43d',
    token: '0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65',
    sale: '0x011F6e57DEfEca4d5Ea633DAf6Dc0e3c5DF45678',
    arbitration: '0x9D7692738a4d323338b9007d65d7F79e013B3476',
    resolver: '0xC17408966d424A3fc8fAf9F007413FA842bDB479',
    factory: '0x208d0760c742a4fb46932811ec843f08752f6ab3',
    orchestrator: '0xc17D88Bf0c16c0c2F1dEBd375163Fc538aB5aBF5',
    adapter: '0x8Ccc8d0E6cf2685De388Bb2Ef764015268364B5A',
    spotPool: '0x5dac596a38a294c03d7fac840d031708c970da79',
    createdAt: 0,
    status: 2,
    bootstrap: true,
  };

  const REGISTRY_ABI = [
    'function instancesCount() view returns (uint256)',
    'function instances(uint256 id) view returns (tuple(string name, string symbol, string description, address creator, address token, address sale, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint160 initialSqrtPriceX96, uint32 timeout, uint32 twapWindow))',
    'function allInstances() view returns (tuple(string name, string symbol, string description, address creator, address token, address sale, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint160 initialSqrtPriceX96, uint32 timeout, uint32 twapWindow)[])',
  ];

  // ─── Utilities ───────────────────────────────────────────────────────
  const $$ = (sel, root = document) => root.querySelector(sel);

  const isZero = (a) => !a || a.toLowerCase() === ZERO;
  const fmtAddr = (a) => (!a || isZero(a)) ? '—' : `${a.slice(0, 6)}…${a.slice(-4)}`;
  const escapeHtml = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));

  async function safe(fn, fallback) { try { return await fn(); } catch (_) { return fallback; } }

  function getInstParam() {
    const m = new URLSearchParams(window.location.search).get('inst');
    if (m == null) return null;
    const n = Number(m);
    return Number.isFinite(n) ? n : null;
  }

  function unpackInstance(id, raw) {
    return {
      id,
      name:         raw.name         ?? raw[0],
      symbol:       raw.symbol       ?? raw[1],
      description:  raw.description  ?? raw[2],
      creator:      raw.creator      ?? raw[3],
      token:        raw.token        ?? raw[4],
      sale:         raw.sale         ?? raw[5],
      arbitration:  raw.arbitration  ?? raw[6],
      resolver:     raw.resolver     ?? raw[7],
      factory:      raw.factory      ?? raw[8],
      orchestrator: raw.orchestrator ?? raw[9],
      spotPool:     raw.spotPool     ?? raw[10],
      createdAt:    Number(raw.createdAt ?? raw[11] ?? 0),
      status:       Number(raw.status ?? raw[12] ?? 2),
      bootstrap:    false,
    };
  }

  // ─── Topbar markup ───────────────────────────────────────────────────
  // The active page is highlighted via data-page on <body>. Inject the
  // markup into #topbar-root if present.
  function renderTopbar() {
    const root = document.getElementById('topbar-root');
    if (!root) return;

    const pageKey = (document.body.dataset.page || '').toLowerCase();
    const activeId = window.__activeInstanceId;
    const inst = (window.allInstances || []).find(x => x.id === activeId);
    const symbol = inst ? inst.symbol : '—';

    // Cloudflare Pages serves clean URLs (strips .html automatically). Link
    // to them directly so internal navigation skips the 308 redirect.
    const links = [
      { key: 'home',      label: 'Home',       href: instUrl('./') },
      { key: 'sale',      label: 'Buy',        href: instUrl('sale') },
      { key: 'proposals', label: 'Proposals',  href: instUrl('proposals') },
      { key: 'create',    label: 'Create',     href: 'create' },
      { key: 'contracts', label: 'Contracts',  href: 'contracts' },
      { key: 'docs',      label: 'Docs',       href: 'docs' },
    ];

    root.innerHTML = `
      <nav class="topbar">
        <div class="topbar-inner">
          <a class="topbar-logo" href="${instUrl('./')}">
            <span class="topbar-brand">FAO</span>
            <span class="env-badge">testnet</span>
          </a>
          <ul class="topbar-links">
            ${links.map(l => `
              <li><a href="${l.href}" class="${pageKey === l.key ? 'topbar-link-active' : ''}">${l.label}</a></li>
            `).join('')}
          </ul>

          <div class="topbar-tools">
            <div class="active-inst-chip" id="active-inst-chip" role="button" tabindex="0" aria-haspopup="listbox">
              <span class="active-inst-label">Active:</span>
              <strong class="active-inst-symbol" id="active-inst-symbol">${escapeHtml(symbol)}</strong>
              <span class="active-inst-caret">▾</span>
              <div class="active-inst-menu" id="active-inst-menu" role="listbox" hidden></div>
            </div>
            <button class="btn btn-secondary topbar-connect" id="topbar-connect" type="button">Connect</button>
          </div>
        </div>
      </nav>
    `;

    wireTopbar();
  }

  // Build a URL preserving the active instance id as ?inst=.
  function instUrl(page) {
    const id = window.__activeInstanceId;
    if (id == null) return page;
    return `${page}?inst=${id}`;
  }

  function wireTopbar() {
    const chip = $$('#active-inst-chip');
    const menu = $$('#active-inst-menu');
    const connectBtn = $$('#topbar-connect');

    if (chip && menu) {
      const open = () => {
        menu.innerHTML = (window.allInstances || [])
          .filter(i => i.bootstrap || (i.sale && !isZero(i.sale)))
          .map(i => `
            <div class="active-inst-menu-row" data-switch-inst="${i.id}">
              <strong>${escapeHtml(i.symbol)}</strong>
              <span>${escapeHtml(i.name)}</span>
            </div>
          `).join('') || '<div class="active-inst-menu-empty">No instances yet.</div>';
        menu.hidden = false;
      };
      const close = () => { menu.hidden = true; };
      chip.addEventListener('click', (e) => {
        e.stopPropagation();
        if (menu.hidden) open(); else close();
      });
      document.addEventListener('click', close);
      menu.addEventListener('click', (e) => {
        const row = e.target.closest('[data-switch-inst]');
        if (!row) return;
        const id = Number(row.dataset.switchInst);
        if (Number.isFinite(id)) setActiveInstance(id, true);
        close();
      });
    }

    if (connectBtn) {
      connectBtn.addEventListener('click', () => {
        connectWallet().catch((e) => alert('Connect failed: ' + (e?.message || e)));
      });
      // Reflect current state if already connected.
      if (window.connectedWallet) connectBtn.textContent = fmtAddr(window.connectedWallet);
    }
  }

  // ─── Instance load ───────────────────────────────────────────────────
  async function loadInstances() {
    const provider = new ethers.JsonRpcProvider(RPC);
    const reg = new ethers.Contract(REGISTRY_ADDR, REGISTRY_ABI, provider);
    let list = [];
    try {
      const all = await reg.allInstances();
      list = all.map((raw, i) => unpackInstance(i, raw));
    } catch (_) {
      const n = await safe(() => reg.instancesCount(), 0n);
      const count = Number(n);
      const idxs = Array.from({ length: count }, (_, i) => i);
      list = (await Promise.all(idxs.map(async (i) => {
        const raw = await safe(() => reg.instances(i), null);
        return raw ? unpackInstance(i, raw) : null;
      }))).filter(Boolean);
    }

    // The bootstrap FAO is NOT in the v3 registry — we inject it at id=-1 so
    // it shows up everywhere but never collides with on-chain ids.
    const all = [{ ...BOOTSTRAP_INSTANCE, id: -1 }, ...list];
    window.allInstances = all;
    return all;
  }

  // ─── Active-instance selection ────────────────────────────────────────
  function pickInitialActive() {
    const visible = (window.allInstances || []).filter(i => i.bootstrap || (i.sale && !isZero(i.sale)));
    const param = getInstParam();
    if (param != null && visible.some(v => v.id === param)) return param;

    let saved = null;
    try { saved = localStorage.getItem(STORAGE_KEY); } catch (_) {}
    const s = saved == null ? null : Number(saved);
    if (s != null && Number.isFinite(s) && visible.some(v => v.id === s)) return s;

    return visible[0]?.id ?? -1;
  }

  function setActiveInstance(id, rewriteUrl = false) {
    window.__activeInstanceId = id;
    const inst = (window.allInstances || []).find(x => x.id === id) || null;
    window.activeInstance = inst;
    try { localStorage.setItem(STORAGE_KEY, String(id)); } catch (_) {}

    // Reflect in URL when the user explicitly switches (so the link to the
    // current page is shareable). Skip on initial load to avoid spamming
    // history with redundant entries.
    if (rewriteUrl) {
      const u = new URL(window.location.href);
      u.searchParams.set('inst', String(id));
      window.history.replaceState({}, '', u.toString());
    }

    // Update topbar chip in place.
    const sym = $$('#active-inst-symbol');
    if (sym) sym.textContent = inst?.symbol ?? '—';

    window.dispatchEvent(new CustomEvent('fao:activeInstanceChanged', { detail: { id, inst } }));
  }
  window.setActiveInstance = setActiveInstance;

  // ─── Wallet ──────────────────────────────────────────────────────────
  async function connectWallet() {
    if (!window.ethereum) throw new Error('No injected wallet (MetaMask / Rabby).');
    const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
    const cid = await window.ethereum.request({ method: 'eth_chainId' });
    if (BigInt(cid) !== SEPOLIA_CHAIN_ID) {
      try {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: '0xaa36a7' }],
        });
      } catch (_) {
        throw new Error('Switch to Sepolia (chainId 11155111).');
      }
    }
    const browserProvider = new ethers.BrowserProvider(window.ethereum, 'any');
    const signer = await browserProvider.getSigner();
    window.connectedWallet = accounts[0];
    window.activeSigner = signer;
    const connectBtn = $$('#topbar-connect');
    if (connectBtn) connectBtn.textContent = fmtAddr(window.connectedWallet);
    window.dispatchEvent(new CustomEvent('fao:walletChanged', { detail: { wallet: accounts[0], signer } }));
    return signer;
  }
  window.connectWallet = connectWallet;

  // Reset wallet state when the user switches chains or accounts.
  if (window.ethereum && !window.__faoChainHookInstalled) {
    window.__faoChainHookInstalled = true;
    const reset = () => {
      window.activeSigner = undefined;
      window.connectedWallet = undefined;
      const btn = $$('#topbar-connect');
      if (btn) btn.textContent = 'Connect';
      window.dispatchEvent(new CustomEvent('fao:walletChanged', { detail: { wallet: null, signer: null } }));
    };
    window.ethereum.on?.('chainChanged', reset);
    window.ethereum.on?.('accountsChanged', reset);
  }

  // ─── Boot ────────────────────────────────────────────────────────────
  async function boot() {
    try {
      await loadInstances();
    } catch (e) {
      console.error('[shared] loadInstances failed', e);
      window.allInstances = [{ ...BOOTSTRAP_INSTANCE, id: -1 }];
    }
    const startId = pickInitialActive();
    setActiveInstance(startId, false);
    renderTopbar();
    window.dispatchEvent(new CustomEvent('fao:sharedReady'));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
