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
 *   5. Discover injected wallets via EIP-6963, manage the selected provider,
 *      store the signer at `window.activeSigner`, and fire `fao:walletChanged`.
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
  const WALLET_PROVIDER_STORAGE_KEY = 'faoSelectedWalletProvider';
  const SEPOLIA_CHAIN_ID = 11155111n;
  const ZERO = '0x0000000000000000000000000000000000000000';
  const EIP6963_ANNOUNCE = 'eip6963:announceProvider';
  const EIP6963_REQUEST = 'eip6963:requestProvider';
  // Promise that resolves with the parsed deployments.json (or null on
  // failure — in which case FALLBACK_REGISTRY_ADDR keeps the page alive).
  let __deploymentsPromise = null;
  const __abiPromises = new Map();

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

  function loadAbi(contractName) {
    if (__abiPromises.has(contractName)) return __abiPromises.get(contractName);
    const promise = fetch(`./abis/${encodeURIComponent(contractName)}.json`, { cache: 'no-cache' })
      .then(r => {
        if (!r.ok) throw new Error(`Could not load ABI for ${contractName}`);
        return r.json();
      });
    __abiPromises.set(contractName, promise);
    return promise;
  }
  window.loadFaoAbi = loadAbi;

  // v4 is a clean break: no hardcoded FAO bootstrap, no backwards-compat
  // fallback. Picker reads directly from the registry. If the registry has
  // zero ready instances, the UI shows an empty state.

  // ─── Utilities ───────────────────────────────────────────────────────
  const $$ = (sel, root = document) => root.querySelector(sel);

  const isZero = (a) => !a || a.toLowerCase() === ZERO;
  const fmtAddr = (a) => (!a || isZero(a)) ? '—' : `${a.slice(0, 6)}…${a.slice(-4)}`;
  const escapeHtml = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  const escapeAttr = escapeHtml;

  async function safe(fn, fallback) { try { return await fn(); } catch (_) { return fallback; } }

  function slugTestId(s) {
    return String(s || 'wallet').toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'wallet';
  }

  // ─── Wallet provider discovery (EIP-6963) ───────────────────────────
  const walletProviders = new Map();
  const hookedProviders = new WeakSet();
  let selectedProviderRecord = null;

  function normalizeProviderInfo(info = {}, provider) {
    const inferredName = provider?.isMetaMask ? 'MetaMask'
      : provider?.isRabby ? 'Rabby'
      : provider?.isCoinbaseWallet ? 'Coinbase Wallet'
      : provider?.isBraveWallet ? 'Brave Wallet'
      : 'Injected wallet';
    const name = String(info.name || inferredName);
    const rdns = String(info.rdns || (provider?.isMetaMask ? 'io.metamask' : 'legacy.injected'));
    const uuid = String(info.uuid || `legacy:${rdns}:${name}`);
    return { uuid, rdns, name, icon: info.icon || '' };
  }

  function providerKey(info) {
    return info.uuid || `${info.rdns}:${info.name}`;
  }

  function rememberWalletProvider(info) {
    const stored = { uuid: info.uuid || '', rdns: info.rdns || '', name: info.name || '' };
    try { localStorage.setItem(WALLET_PROVIDER_STORAGE_KEY, JSON.stringify(stored)); } catch (_) {}
    window.faoSelectedWalletProviderInfo = stored;
  }

  function readStoredWalletProvider() {
    try {
      const raw = localStorage.getItem(WALLET_PROVIDER_STORAGE_KEY);
      return raw ? JSON.parse(raw) : null;
    } catch (_) {
      return null;
    }
  }

  function addWalletProvider(info, provider) {
    if (!provider || typeof provider.request !== 'function') return null;
    for (const existing of walletProviders.values()) {
      if (existing.provider === provider) return existing;
    }
    const normalized = normalizeProviderInfo(info, provider);
    const key = providerKey(normalized);
    const record = { key, info: normalized, provider };
    walletProviders.set(key, record);
    window.faoWalletProviders = Array.from(walletProviders.values()).map(({ info: i }) => ({
      uuid: i.uuid,
      rdns: i.rdns,
      name: i.name,
      icon: i.icon,
    }));
    return record;
  }

  function addLegacyProviders() {
    const injected = globalThis.ethereum;
    if (!injected) return;
    const providers = Array.isArray(injected.providers) && injected.providers.length
      ? injected.providers
      : [injected];
    for (const provider of providers) {
      addWalletProvider({}, provider);
    }
  }

  function requestWalletProviders() {
    try { window.dispatchEvent(new Event(EIP6963_REQUEST)); } catch (_) {}
    setTimeout(addLegacyProviders, 100);
  }

  function walletRecordMatches(record, stored) {
    if (!record || !stored) return false;
    const info = record.info || {};
    if (stored.uuid && info.uuid === stored.uuid) return true;
    if (stored.rdns && info.rdns === stored.rdns) return true;
    return !!stored.name && info.name === stored.name;
  }

  function providerIdentityHTML(info) {
    const icon = info.icon
      ? `<img class="wallet-provider-icon" src="${escapeAttr(info.icon)}" alt="" />`
      : `<span class="wallet-provider-fallback" aria-hidden="true">${escapeHtml((info.name || '?').slice(0, 1).toUpperCase())}</span>`;
    return `
      ${icon}
      <span class="wallet-provider-copy">
        <strong>${escapeHtml(info.name || 'Injected wallet')}</strong>
        <span>${escapeHtml(info.rdns || 'unknown provider')}</span>
      </span>
    `;
  }

  async function discoverWalletProviders(waitMs = 180) {
    requestWalletProviders();
    await new Promise(resolve => setTimeout(resolve, waitMs));
    addLegacyProviders();
    return Array.from(walletProviders.values());
  }

  async function showWalletProviderPicker(records) {
    if (!records.length) return null;
    const bodyHTML = `
      <div class="wallet-provider-picker" data-testid="wallet-provider-picker">
        ${records.map((record) => `
          <button class="wallet-provider-option"
                  type="button"
                  data-wallet-provider-key="${escapeAttr(record.key)}"
                  data-testid="wallet-provider-option-${escapeAttr(slugTestId(record.info.rdns || record.info.uuid || record.info.name))}">
            ${providerIdentityHTML(record.info)}
          </button>
        `).join('')}
      </div>
    `;
    const footerHTML = `<button class="btn btn-secondary" data-action="cancel">Cancel</button>`;
    return openModal({
      title: 'Choose wallet',
      bodyHTML,
      footerHTML,
      onMount: {
        afterMount: (root, close) => {
          for (const btn of root.querySelectorAll('[data-wallet-provider-key]')) {
            btn.addEventListener('click', () => close(walletProviders.get(btn.dataset.walletProviderKey) || null));
          }
        },
      },
    });
  }

  async function resolveWalletProvider({ forcePicker = false } = {}) {
    const records = await discoverWalletProviders();
    if (!records.length) throw new Error('No injected wallet found. Install MetaMask, Rabby, or another EIP-1193 wallet.');

    if (!forcePicker && selectedProviderRecord && walletProviders.has(selectedProviderRecord.key)) {
      return selectedProviderRecord;
    }

    const stored = readStoredWalletProvider();
    const storedRecord = records.find(record => walletRecordMatches(record, stored));
    if (!forcePicker && storedRecord) {
      selectedProviderRecord = storedRecord;
      rememberWalletProvider(storedRecord.info);
      return storedRecord;
    }

    if (!forcePicker && records.length === 1) {
      selectedProviderRecord = records[0];
      rememberWalletProvider(records[0].info);
      return records[0];
    }

    const picked = await showWalletProviderPicker(records);
    if (!picked) throw new Error('Wallet connection cancelled.');
    selectedProviderRecord = picked;
    rememberWalletProvider(picked.info);
    return picked;
  }

  function resetWalletState() {
    window.activeSigner = undefined;
    window.connectedWallet = undefined;
    const btn = $$('#topbar-connect');
    if (btn) btn.textContent = 'Connect';
    renderProviderChip();
    window.dispatchEvent(new CustomEvent('fao:walletChanged', { detail: { wallet: null, signer: null, provider: selectedProviderRecord?.info || null } }));
  }

  function hookProviderReset(record) {
    const provider = record?.provider;
    if (!provider || hookedProviders.has(provider)) return;
    hookedProviders.add(provider);
    provider.on?.('chainChanged', resetWalletState);
    provider.on?.('accountsChanged', resetWalletState);
  }

  function chainIdToBigInt(value) {
    if (typeof value === 'bigint') return value;
    if (typeof value === 'number') return BigInt(value);
    if (typeof value === 'string') return BigInt(value);
    throw new Error('Wallet returned an invalid chain id.');
  }

  async function switchToSepolia(provider) {
    await provider.request({
      method: 'wallet_switchEthereumChain',
      params: [{ chainId: '0xaa36a7' }],
    });
  }

  function renderChainMismatchAction(provider) {
    setTopbarStatus('Wallet is not on Sepolia.', 'error', {
      label: 'Switch to Sepolia',
      testId: 'topbar-switch-sepolia',
      onClick: async () => {
        try {
          await switchToSepolia(provider);
          setTopbarStatus('Switched to Sepolia. Reconnect wallet.', 'ok');
        } catch (err) {
          setTopbarStatus(`Switch failed: ${err?.message || err}`, 'error');
        }
      },
    });
  }

  window.addEventListener(EIP6963_ANNOUNCE, (event) => {
    const detail = event.detail || {};
    addWalletProvider(detail.info || {}, detail.provider);
  });
  requestWalletProviders();

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
            <div class="active-inst-chip" id="active-inst-chip" data-testid="topbar-active-chip" role="button" tabindex="0" aria-haspopup="listbox">
              <span class="active-inst-label">Active:</span>
              <strong class="active-inst-symbol" id="active-inst-symbol">${escapeHtml(symbol)}</strong>
              <span class="active-inst-caret">▾</span>
              <div class="active-inst-menu" id="active-inst-menu" role="listbox" hidden></div>
            </div>
            <button class="wallet-identity-chip" id="wallet-provider-chip" data-testid="topbar-wallet-identity" type="button" hidden></button>
            <button class="btn btn-secondary topbar-connect" id="topbar-connect" data-testid="topbar-connect" type="button">Connect</button>
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

    const walletChip = $$('#wallet-provider-chip');
    if (walletChip) {
      walletChip.addEventListener('click', () => {
        connectWallet({ forcePicker: true }).catch((e) => setTopbarStatus(`Connect failed: ${e?.message || e}`, 'error'));
      });
    }
    renderProviderChip();
  }

  function renderProviderChip() {
    const chip = $$('#wallet-provider-chip');
    if (!chip) return;
    const info = selectedProviderRecord?.info || window.faoSelectedWalletProviderInfo;
    if (!window.connectedWallet || !info) {
      chip.hidden = true;
      chip.innerHTML = '';
      return;
    }
    chip.hidden = false;
    chip.title = `${info.name || 'Wallet'} (${info.rdns || 'unknown provider'})`;
    chip.innerHTML = `
      ${providerIdentityHTML(info)}
      <span class="wallet-provider-address">${escapeHtml(fmtAddr(window.connectedWallet))}</span>
    `;
  }

  /// Inline status panel in the topbar (replaces native `alert`). The
  /// `#topbar-status` slot is rendered on every page; updates are
  /// broadcast-announced via `aria-live="polite"` for screen readers.
  function setTopbarStatus(text, kind, action) {
    const root = document.getElementById('topbar-root');
    if (!root) return;
    let slot = root.querySelector('#topbar-status');
    if (!slot) {
      slot = document.createElement('div');
      slot.id = 'topbar-status';
      slot.dataset.testid = 'topbar-status';
      slot.setAttribute('role', 'status');
      slot.setAttribute('aria-live', 'polite');
      slot.className = 'topbar-status';
      root.appendChild(slot);
    }
    slot.textContent = '';
    if (text) {
      const message = document.createElement('span');
      message.textContent = text;
      slot.appendChild(message);
    }
    if (text && action) {
      const btn = document.createElement('button');
      btn.type = 'button';
      btn.className = 'topbar-status-action';
      btn.textContent = action.label || 'Resolve';
      if (action.testId) btn.dataset.testid = action.testId;
      btn.addEventListener('click', action.onClick);
      slot.appendChild(btn);
    }
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
    const registryAbi = await loadAbi('FutarchyRegistry');
    const provider = new ethers.JsonRpcProvider(RPC);
    const reg = new ethers.Contract(REGISTRY_ADDR, registryAbi, provider);
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
  async function connectWallet(options = {}) {
    const record = await resolveWalletProvider(options);
    const eip1193Provider = record.provider;
    const accounts = await eip1193Provider.request({ method: 'eth_requestAccounts' });
    const cid = await eip1193Provider.request({ method: 'eth_chainId' });
    if (chainIdToBigInt(cid) !== SEPOLIA_CHAIN_ID) {
      try {
        await switchToSepolia(eip1193Provider);
      } catch (_) {
        renderChainMismatchAction(eip1193Provider);
        throw new Error('Switch to Sepolia (chainId 11155111).');
      }
    }
    const browserProvider = new ethers.BrowserProvider(eip1193Provider, 'any');
    const signer = await browserProvider.getSigner();
    window.connectedWallet = accounts[0] || await signer.getAddress();
    window.activeSigner = signer;
    window.faoSelectedWalletProvider = eip1193Provider;
    window.faoSelectedWalletProviderInfo = {
      uuid: record.info.uuid,
      rdns: record.info.rdns,
      name: record.info.name,
    };
    rememberWalletProvider(record.info);
    hookProviderReset(record);
    const connectBtn = $$('#topbar-connect');
    if (connectBtn) connectBtn.textContent = fmtAddr(window.connectedWallet);
    renderProviderChip();
    setTopbarStatus(`Connected with ${record.info.name}.`, 'ok');
    window.dispatchEvent(new CustomEvent('fao:walletChanged', {
      detail: { wallet: window.connectedWallet, signer, provider: record.info },
    }));
    return signer;
  }
  window.connectWallet = connectWallet;

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
