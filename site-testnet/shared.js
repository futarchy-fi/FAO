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
  // T5.D1 (architectural coupling): the active deploy lives in
  // `deployments.json` — the single source of truth, also consumed by
  // CI/audit. shared.js fetches it at startup; if the fetch fails, the
  // fallback constant below keeps the UI booting (kept in sync via a
  // CI check). Update the JSON, not the constant.
  const FALLBACK_REGISTRY_ADDR = '0x18D1f4e57412b48436C7825B9018437C235bBC5C';
  let REGISTRY_ADDR = FALLBACK_REGISTRY_ADDR;
  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const STORAGE_KEY = 'faoActiveInstanceId';
  const SEPOLIA_CHAIN_ID = 11155111n;
  const ZERO = '0x0000000000000000000000000000000000000000';
  // Promise that resolves with the parsed deployments.json (or null on
  // failure — in which case FALLBACK_REGISTRY_ADDR keeps the page alive).
  let __deploymentsPromise = null;

  function loadDeployments() {
    if (__deploymentsPromise) return __deploymentsPromise;
    __deploymentsPromise = fetch('./deployments.json', { cache: 'no-cache' })
      .then(r => r.ok ? r.json() : null)
      .then(j => {
        if (j && j.active && j.active.registry) {
          REGISTRY_ADDR = j.active.registry;
          window.faoDeployments = j;
        }
        return j;
      })
      .catch(() => null);
    return __deploymentsPromise;
  }

  // v4 is a clean break: no hardcoded FAO bootstrap, no backwards-compat
  // fallback. Picker reads directly from the registry. If the registry has
  // zero ready instances, the UI shows an empty state.

  const REGISTRY_ABI = [
    'function instancesCount() view returns (uint256)',
    'function instances(uint256 id) view returns (tuple(string name, string symbol, string description, address creator, address token, address sale, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint32 timeout, uint32 twapWindow))',
    'function allInstances() view returns (tuple(string name, string symbol, string description, address creator, address token, address sale, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint32 timeout, uint32 twapWindow)[])',
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
    // v5 FutarchyInstance layout (15 fields). initialSqrtPriceX96 dropped —
    // the contract derives it from sale.INITIAL_PRICE_WEI_PER_TOKEN.
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
          .filter(i => i.sale && !isZero(i.sale))
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
        connectWallet().catch((e) => setTopbarStatus(`Connect failed: ${e?.message || e}`, 'error'));
      });
      // Reflect current state if already connected.
      if (window.connectedWallet) connectBtn.textContent = fmtAddr(window.connectedWallet);
    }
  }

  /// Inline status panel in the topbar (replaces native `alert`). The
  /// `#topbar-status` slot is rendered on every page; updates are
  /// broadcast-announced via `aria-live="polite"` for screen readers.
  function setTopbarStatus(text, kind) {
    const root = document.getElementById('topbar-root');
    if (!root) return;
    let slot = root.querySelector('#topbar-status');
    if (!slot) {
      slot = document.createElement('div');
      slot.id = 'topbar-status';
      slot.setAttribute('role', 'status');
      slot.setAttribute('aria-live', 'polite');
      slot.className = 'topbar-status';
      root.appendChild(slot);
    }
    slot.textContent = text || '';
    slot.dataset.kind = kind || '';
    if (text) {
      // Auto-clear after 6 s unless it's an error (errors persist until next status).
      if (kind !== 'error') {
        clearTimeout(slot._t);
        slot._t = setTimeout(() => { slot.textContent = ''; slot.dataset.kind = ''; }, 6000);
      }
    }
  }
  window.setTopbarStatus = setTopbarStatus;

  // ─── In-page modal helpers (replace native alert/confirm/prompt) ────
  // These are accessible (focus trap, aria-modal, Esc to close, role="dialog")
  // and return Promises so call sites can `await` them.

  function ensureModalHost() {
    let host = document.getElementById('fao-modal-host');
    if (host) return host;
    host = document.createElement('div');
    host.id = 'fao-modal-host';
    document.body.appendChild(host);
    return host;
  }

  function escapeText(s) {
    return String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  }

  function openModal({ title, bodyHTML, footerHTML, onMount }) {
    return new Promise((resolve) => {
      const host = ensureModalHost();
      const backdrop = document.createElement('div');
      backdrop.className = 'fao-modal-backdrop';
      backdrop.setAttribute('role', 'dialog');
      backdrop.setAttribute('aria-modal', 'true');
      backdrop.setAttribute('aria-labelledby', 'fao-modal-title');
      backdrop.innerHTML = `
        <div class="fao-modal-card">
          <div class="fao-modal-head">
            <h3 id="fao-modal-title" class="fao-modal-title">${escapeText(title)}</h3>
            <button class="fao-modal-close" aria-label="Close" data-action="cancel">&times;</button>
          </div>
          <div class="fao-modal-body">${bodyHTML}</div>
          <div class="fao-modal-foot">${footerHTML}</div>
        </div>
      `;
      const close = (result) => {
        document.removeEventListener('keydown', onKey);
        host.removeChild(backdrop);
        resolve(result);
      };
      const onKey = (e) => { if (e.key === 'Escape') close(null); };
      backdrop.addEventListener('click', (e) => {
        if (e.target === backdrop) return close(null);
        const action = e.target.closest('[data-action]')?.dataset.action;
        if (action === 'cancel') close(null);
        else if (action === 'ok') {
          const v = onMount?.getValue?.();
          close(v === undefined ? true : v);
        }
      });
      host.appendChild(backdrop);
      document.addEventListener('keydown', onKey);
      // Initial focus into the first focusable element (input or primary).
      requestAnimationFrame(() => {
        const focusable = backdrop.querySelector('input, button[data-action="ok"]');
        focusable?.focus();
      });
      onMount?.afterMount?.(backdrop, close);
    });
  }

  /// Replacement for `confirm()`. Returns Promise<boolean>.
  function faoConfirm({ title = 'Confirm', message, okLabel = 'Confirm', cancelLabel = 'Cancel' }) {
    const bodyHTML = `<p class="fao-modal-message">${escapeText(message)}</p>`;
    const footerHTML = `
      <button class="btn btn-secondary" data-action="cancel">${escapeText(cancelLabel)}</button>
      <button class="btn btn-primary" data-action="ok">${escapeText(okLabel)}</button>
    `;
    return openModal({ title, bodyHTML, footerHTML });
  }
  window.faoConfirm = faoConfirm;

  /// Replacement for `prompt()`. Returns Promise<string|null>.
  function faoPrompt({ title = 'Input', message, defaultValue = '', placeholder = '', validate }) {
    const bodyHTML = `
      ${message ? `<p class="fao-modal-message">${escapeText(message)}</p>` : ''}
      <input class="fao-modal-input" type="text" value="${escapeText(defaultValue)}"
             placeholder="${escapeText(placeholder)}" aria-label="${escapeText(title)}" />
      <p class="fao-modal-validation" aria-live="polite"></p>
    `;
    const footerHTML = `
      <button class="btn btn-secondary" data-action="cancel">Cancel</button>
      <button class="btn btn-primary" data-action="ok">OK</button>
    `;
    let inputEl;
    return openModal({
      title, bodyHTML, footerHTML,
      onMount: {
        afterMount: (root, close) => {
          inputEl = root.querySelector('.fao-modal-input');
          const valEl = root.querySelector('.fao-modal-validation');
          const okBtn = root.querySelector('[data-action="ok"]');
          inputEl.addEventListener('keydown', (e) => {
            if (e.key === 'Enter') okBtn.click();
          });
          const refresh = () => {
            if (!validate) return;
            const msg = validate(inputEl.value);
            valEl.textContent = msg || '';
            okBtn.disabled = !!msg;
          };
          inputEl.addEventListener('input', refresh);
          refresh();
        },
        getValue: () => inputEl?.value ?? null,
      }
    });
  }
  window.faoPrompt = faoPrompt;

  /// Replacement for `alert()`. Returns Promise<void>.
  function faoAlert({ title = 'Notice', message, kind = 'info' }) {
    const bodyHTML = `<p class="fao-modal-message fao-modal-message-${escapeText(kind)}">${escapeText(message)}</p>`;
    const footerHTML = `<button class="btn btn-primary" data-action="ok">OK</button>`;
    return openModal({ title, bodyHTML, footerHTML });
  }
  window.faoAlert = faoAlert;

  // ─── Instance load ───────────────────────────────────────────────────
  async function loadInstances() {
    // Resolve deployments.json BEFORE first registry read so the address
    // in the JSON wins over the fallback. Always succeeds (either the
    // JSON loads, or the fallback constant stays in effect).
    await loadDeployments();
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

    window.allInstances = list;
    return list;
  }

  // ─── Active-instance selection ────────────────────────────────────────
  function pickInitialActive() {
    const visible = (window.allInstances || []).filter(i => i.sale && !isZero(i.sale));
    const param = getInstParam();
    if (param != null && visible.some(v => v.id === param)) return param;

    let saved = null;
    try { saved = localStorage.getItem(STORAGE_KEY); } catch (_) {}
    const s = saved == null ? null : Number(saved);
    if (s != null && Number.isFinite(s) && visible.some(v => v.id === s)) return s;

    return visible[0]?.id ?? null;
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
      window.allInstances = [];
    }
    const startId = pickInitialActive();
    if (startId != null) setActiveInstance(startId, false);
    else window.activeInstance = null;
    renderTopbar();
    window.dispatchEvent(new CustomEvent('fao:sharedReady'));
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
