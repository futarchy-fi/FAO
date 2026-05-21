/* FAO v0 — Sepolia testnet FutarchyRegistry UI
 *
 * Lets any visitor:
 *   1. browse every futarchy instance registered on-chain,
 *   2. pick an active instance (selection persists via localStorage),
 *   3. spin up a brand-new futarchy via FutarchyRegistry.createFutarchy().
 *
 * This file is the new "instance picker" layer that sits ABOVE sepolia.js /
 * bonds.js. Those two files now read their per-instance addresses from
 * window.activeInstance, refreshed via window.setActiveInstance(instance).
 *
 * ─── Action required after deploy ─────────────────────────────────────────
 *   The REGISTRY_ADDR constant below is the address of the deployed
 *   FutarchyRegistry contract. It is hard-coded as the zero address until the
 *   registry is deployed. After deploy:
 *
 *     1. Edit `site-testnet/registry.js` line marked  // REGISTRY_ADDR  ↓
 *     2. Replace 0x0000…0000 with the deployed FutarchyRegistry address.
 *     3. Redeploy the static site (Cloudflare Pages / Vercel / etc).
 *
 *   While REGISTRY_ADDR remains the zero address, OR if the registry reports
 *   instancesCount() == 0, the UI falls back to the bootstrap FAO instance
 *   (the contracts already wired into sepolia.js / bonds.js).
 * ──────────────────────────────────────────────────────────────────────────
 */

(() => {
  'use strict';

  // ─── Configuration ───────────────────────────────────────────────────

  // REGISTRY_ADDR — set this after deploying FutarchyRegistry.sol.
  // Until then it stays as ZeroAddress and the UI falls back to FAO bootstrap.
  const REGISTRY_ADDR = '0x554B437D9D47B071DffFB40933e63052157405CA'; // REGISTRY_ADDR

  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const REFRESH_INTERVAL = 60_000;
  const STORAGE_KEY = 'fao.testnet.activeInstanceId';

  // Bootstrap FAO instance — the contracts already live on Sepolia (id 0 once
  // registry is wired). These are mirrored from sepolia.js / docs/sepolia-
  // deployment-v0.md so the page renders even before registry deploy.
  const BOOTSTRAP_INSTANCE = {
    id: 0,
    name: 'FAO',
    symbol: 'FAO',
    description: 'Bootstrap futarchy instance for the FAO v0 testnet stack.',
    creator: '0x693E3FB46Bb36eE43C702FE94f9463df0691b43d',
    token: '0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65',
    arbitration: '0x9D7692738a4d323338b9007d65d7F79e013B3476',
    resolver: '0x421d2FaDA1c4D84E9EF93A4cB09f7317481Ea91a',
    factory: '0xc3154ec665545342C0E6aa1B81576D8E98d0cCa0',
    orchestrator: '0x7DF66Fd816c09bb534136C5688B55BBA9398d262',
    spotPool: '0x5dac596a38a294c03d7fac840d031708c970da79',
    createdAt: 0,
    status: 2, // STATUS_READY — bootstrap is always fully wired
    bootstrap: true,
  };

  // ─── ABIs ────────────────────────────────────────────────────────────

  // FutarchyRegistry (deployed). Field order matches the FutarchyInstance struct
  // in FutarchyRegistry.sol — the 2-phase patch added status + cached params at
  // the end (status, initialSqrtPriceX96, timeout, twapWindow); unpackInstance()
  // reads them so the picker can render a "pending part2" chip for half-deployed
  // instances.
  //
  // InstanceStatus enum (matches src/FutarchyRegistry.sol):
  //   0 = NONE
  //   1 = PENDING_PART2  (Part1 ran; Part2 not yet)
  //   2 = READY          (both phases complete, fully usable)
  const REGISTRY_ABI = [
    'function instancesCount() view returns (uint256)',
    'function instances(uint256 id) view returns (tuple(string name, string symbol, string description, address creator, address token, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint160 initialSqrtPriceX96, uint32 timeout, uint32 twapWindow))',
    'function allInstances() view returns (tuple(string name, string symbol, string description, address creator, address token, address arbitration, address resolver, address factory, address orchestrator, address spotPool, uint256 createdAt, uint8 status, uint160 initialSqrtPriceX96, uint32 timeout, uint32 twapWindow)[])',
    'function isPendingPart2(uint256 id) view returns (bool)',
    // 2-phase create flow — preferred path for public RPCs with a 16.7M
    // eth_estimateGas cap (MetaMask's default Sepolia endpoint).
    'function createFutarchyPart1(string name, string symbol, string description, uint256 initialTokenSupply, uint160 initialSqrtPriceX96, uint32 timeout, uint32 twapWindow, uint256 baseBondX) returns (uint256)',
    'function createFutarchyPart2(uint256 id)',
    // Legacy atomic create — still works, used by forge scripts or any RPC
    // without a client-side gas cap.
    'function createFutarchy(string name, string symbol, string description, uint256 initialTokenSupply, uint160 initialSqrtPriceX96, uint32 timeout, uint32 twapWindow, uint256 baseBondX) returns (uint256)',
    'event FutarchyPart1Created(uint256 indexed id, address indexed creator, string name, string symbol, address token, address arbitration)',
    'event FutarchyPart2Created(uint256 indexed id, address indexed creator, address resolver, address factory, address orchestrator, address spotPool)',
    'event FutarchyCreated(uint256 indexed id, address indexed creator, string name, string symbol, address token, address arbitration, address resolver, address factory, address orchestrator, address spotPool)',
  ];

  // InstanceStatus enum mirror.
  const STATUS_NONE = 0;
  const STATUS_PENDING_PART2 = 1;
  const STATUS_READY = 2;

  // FAOFutarchyFactory.marketsCount() — used to show "N proposals" on each chip.
  const FACTORY_COUNT_ABI = [
    'function marketsCount() view returns (uint256)',
  ];

  // ─── Globals ─────────────────────────────────────────────────────────

  let provider;          // read-only RPC
  let browserProvider;   // wallet
  let signer;            // wallet signer
  let connectedWallet;   // address

  let instances = [];    // list of instances (with bootstrap or fetched)
  let activeId = null;   // selected instance id

  // ─── Utilities ───────────────────────────────────────────────────────

  function $$(sel, root = document) { return root.querySelector(sel); }

  function isZeroAddress(addr) {
    if (!addr) return true;
    try { return ethers.getAddress(addr) === ethers.ZeroAddress; }
    catch (_) { return true; }
  }

  function fmtAddr(a) {
    if (!a || isZeroAddress(a)) return '—';
    return `${a.slice(0, 6)}…${a.slice(-4)}`;
  }

  function escapeHtml(s) {
    if (typeof s !== 'string') return '';
    return s.replace(/[&<>"']/g, ch => ({
      '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;'
    }[ch]));
  }

  function explorerAddr(addr) { return `https://sepolia.etherscan.io/address/${addr}`; }
  function explorerTx(hash)   { return `https://sepolia.etherscan.io/tx/${hash}`; }

  async function safe(fn, fallback) {
    try { return await fn(); } catch (_) { return fallback; }
  }

  // ─── Price → sqrtPriceX96 ────────────────────────────────────────────
  // UniV3 sqrtPriceX96 = floor(sqrt(price) * 2^96).
  // Here `price` is token1-per-token0 in raw integer units. The form asks the
  // user for "1 ACME = X WETH"; we treat token0 as the company token (18 dec)
  // and token1 as WETH (18 dec), so the raw price equals the human price.
  function priceToSqrtPriceX96(priceFloat) {
    if (!isFinite(priceFloat) || priceFloat <= 0) {
      throw new Error('Initial price must be > 0.');
    }
    // Use string math to avoid float precision loss for small prices.
    // sqrt(price) — use Math.sqrt with enough precision, then scale by 2^96.
    const sqrt = Math.sqrt(priceFloat);
    // Scale by 2^96 using BigInt to keep precision.
    // sqrt is a float; convert to a BigInt fixed-point with 1e18 precision.
    const scaled = BigInt(Math.floor(sqrt * 1e18));
    const Q96 = 1n << 96n;
    return (scaled * Q96) / (10n ** 18n);
  }

  // ─── Instance registry read path ─────────────────────────────────────

  function unpackInstance(id, raw) {
    // raw is the struct returned by registry.instances() — ethers v6 returns
    // it as a Result object indexable by field name OR positional index.
    // Fields 0-10 are the legacy struct; 11-14 are the 2-phase additions.
    const statusRaw = raw.status ?? raw[11];
    return {
      id,
      name:         raw.name         ?? raw[0],
      symbol:       raw.symbol       ?? raw[1],
      description:  raw.description  ?? raw[2],
      creator:      raw.creator      ?? raw[3],
      token:        raw.token        ?? raw[4],
      arbitration:  raw.arbitration  ?? raw[5],
      resolver:     raw.resolver     ?? raw[6],
      factory:      raw.factory      ?? raw[7],
      orchestrator: raw.orchestrator ?? raw[8],
      spotPool:     raw.spotPool     ?? raw[9],
      createdAt:    Number(raw.createdAt ?? raw[10] ?? 0),
      status:       statusRaw == null ? STATUS_READY : Number(statusRaw),
      bootstrap:    false,
    };
  }

  async function loadInstances() {
    // If REGISTRY_ADDR is unset, surface bootstrap only.
    if (isZeroAddress(REGISTRY_ADDR)) {
      instances = [BOOTSTRAP_INSTANCE];
      return;
    }

    const reg = new ethers.Contract(REGISTRY_ADDR, REGISTRY_ABI, provider);
    let list = [];
    try {
      // Prefer allInstances() — single RPC call.
      const all = await reg.allInstances();
      list = all.map((raw, i) => unpackInstance(i, raw));
    } catch (_) {
      // Fall back to per-id reads if allInstances() reverts or isn't present.
      const n = await safe(() => reg.instancesCount(), 0n);
      const count = Number(n);
      if (count > 0) {
        const idxs = Array.from({ length: count }, (_, i) => i);
        list = await Promise.all(idxs.map(async (i) => {
          const raw = await safe(() => reg.instances(i), null);
          return raw ? unpackInstance(i, raw) : null;
        }));
        list = list.filter(Boolean);
      }
    }

    if (list.length === 0) {
      // Empty registry — fall back to bootstrap.
      instances = [BOOTSTRAP_INSTANCE];
    } else {
      instances = list;
    }
  }

  // Optional: per-instance proposal count for the picker chip subtitle.
  async function loadProposalCounts() {
    const counts = await Promise.all(instances.map(async (inst) => {
      if (isZeroAddress(inst.factory)) return null;
      const f = new ethers.Contract(inst.factory, FACTORY_COUNT_ABI, provider);
      return safe(() => f.marketsCount(), null);
    }));
    for (let i = 0; i < instances.length; i++) {
      const c = counts[i];
      instances[i].proposalsCount = c === null || c === undefined ? null : Number(c);
    }
  }

  // ─── Instance selection ──────────────────────────────────────────────

  function restoreActiveId() {
    let saved = null;
    try { saved = localStorage.getItem(STORAGE_KEY); }
    catch (_) { saved = null; }
    const n = saved == null ? null : Number(saved);
    if (n != null && Number.isFinite(n) && instances.some(i => i.id === n)) {
      activeId = n;
    } else {
      activeId = instances[0]?.id ?? 0;
    }
  }

  function persistActiveId() {
    try { localStorage.setItem(STORAGE_KEY, String(activeId)); } catch (_) {}
  }

  function getActive() {
    return instances.find(i => i.id === activeId) || instances[0];
  }

  /**
   * Publish the active instance to window so sepolia.js and bonds.js can read
   * it, then fire a "fao:activeInstanceChanged" event for any consumer that
   * wants to refresh.
   */
  function publishActiveInstance() {
    const inst = getActive();
    window.activeInstance = inst;
    window.dispatchEvent(new CustomEvent('fao:activeInstanceChanged', { detail: inst }));
  }

  /**
   * Public switch — called by clicking a chip OR by external code that wants
   * to force-select an instance.
   */
  function selectInstance(id) {
    if (!instances.some(i => i.id === id)) return;
    activeId = id;
    persistActiveId();
    publishActiveInstance();
    renderPicker();
    updateActiveHeader();
  }

  // Expose for cross-file access. sepolia.js subscribes to the event, but
  // other code can imperatively switch via window.setActiveInstance(id).
  window.setActiveInstance = selectInstance;

  // ─── Picker render ───────────────────────────────────────────────────

  function renderPicker() {
    const mount = $$('#instances-picker');
    if (!mount) return;

    if (instances.length === 0) {
      mount.innerHTML = `<p class="sep-empty">No futarchy instances found.</p>`;
      return;
    }

    mount.innerHTML = instances.map(inst => {
      const isActive = inst.id === activeId;
      const isPending = inst.status === STATUS_PENDING_PART2;
      const subtitle = isPending
        ? 'awaiting part 2 deploy'
        : (inst.proposalsCount === null || inst.proposalsCount === undefined
            ? (inst.bootstrap ? 'bootstrap' : `id #${inst.id}`)
            : `${inst.proposalsCount} proposal${inst.proposalsCount === 1 ? '' : 's'}`);
      const symbol = escapeHtml(inst.symbol || '');
      const name = escapeHtml(inst.name || `Instance #${inst.id}`);

      // Compose status badges. Bootstrap and pending are mutually exclusive
      // (bootstrap is hardcoded to READY).
      let badge = '';
      if (inst.bootstrap) {
        badge = '<span class="instance-chip-badge">bootstrap</span>';
      } else if (isPending) {
        badge = '<span class="instance-chip-badge instance-chip-badge-pending">pending part2</span>';
      }

      // "Complete deployment" button — only shown when this instance is in
      // PENDING_PART2 state. Clicking it fires createFutarchyPart2(id) so
      // anyone (not just the original Part1 caller) can finish a stuck
      // deployment.
      const completeBtn = isPending
        ? `<button class="instance-chip-complete-btn" data-complete-id="${inst.id}" type="button">Complete deployment</button>`
        : '';

      const chipClasses = [
        'instance-chip',
        isActive ? 'instance-chip-active' : '',
        isPending ? 'instance-chip-pending' : '',
      ].filter(Boolean).join(' ');

      return `
        <div class="${chipClasses}" data-instance-id="${inst.id}">
          <button class="instance-chip-body" data-instance-id="${inst.id}" type="button">
            <div class="instance-chip-head">
              <span class="instance-chip-symbol">${symbol}</span>
              ${badge}
            </div>
            <div class="instance-chip-name">${name}</div>
            <div class="instance-chip-sub">${escapeHtml(subtitle)}</div>
          </button>
          ${completeBtn}
        </div>
      `;
    }).join('');

    // Wire selection clicks (on the chip body — outer div wraps the button so
    // the "complete" action button doesn't double-trigger).
    for (const btn of mount.querySelectorAll('.instance-chip-body')) {
      btn.addEventListener('click', () => {
        const id = Number(btn.dataset.instanceId);
        selectInstance(id);
      });
    }
    // Wire complete-deployment buttons.
    for (const btn of mount.querySelectorAll('.instance-chip-complete-btn')) {
      btn.addEventListener('click', async (ev) => {
        ev.preventDefault();
        ev.stopPropagation();
        const id = Number(btn.dataset.completeId);
        await completePendingPart2(id, btn);
      });
    }
  }

  /// Public-facing helper: finalize a PENDING_PART2 instance by firing
  /// `createFutarchyPart2(id)`. Triggered by the "Complete deployment" chip
  /// button. Anyone can call it on chain, so we don't gate on creator.
  async function completePendingPart2(id, btn) {
    if (btn) {
      btn.disabled = true;
      btn.textContent = 'Submitting…';
    }
    try {
      const sig = await ensureSigner();
      const reg = new ethers.Contract(REGISTRY_ADDR, REGISTRY_ABI, sig);
      const tx = await reg.createFutarchyPart2(id);
      if (btn) btn.textContent = `Waiting (tx ${tx.hash.slice(0, 8)}…)`;
      const rec = await tx.wait();
      console.info(`[registry] Part2 for instance #${id} confirmed in block ${rec.blockNumber}`);
      // Reload + reselect the just-completed instance.
      await loadInstances();
      await loadProposalCounts();
      selectInstance(id);
      renderPicker();
      updateActiveHeader();
    } catch (err) {
      console.error(`[registry] createFutarchyPart2(${id}) failed`, err);
      if (btn) {
        btn.disabled = false;
        btn.textContent = 'Retry complete deployment';
        btn.title = err.shortMessage || err.message || String(err);
      }
    }
  }

  function updateActiveHeader() {
    const inst = getActive();
    const el = $$('#instance-active-header');
    if (!el || !inst) return;
    const name = escapeHtml(inst.name || `Instance #${inst.id}`);
    const symbol = escapeHtml(inst.symbol || '');
    const factoryLink = isZeroAddress(inst.factory)
      ? '—'
      : `<a href="${explorerAddr(inst.factory)}" target="_blank" rel="noopener">${fmtAddr(inst.factory)}</a>`;
    el.innerHTML = `
      <span class="instance-active-label">Active instance:</span>
      <strong>${name}</strong>
      <span class="instance-active-symbol">(${symbol})</span>
      <span class="instance-active-sep">·</span>
      <span class="instance-active-factory">factory ${factoryLink}</span>
    `;
  }

  // ─── Create Futarchy modal ───────────────────────────────────────────

  function openCreateModal() {
    const modal = $$('#create-instance-modal');
    if (!modal) return;
    modal.classList.add('open');
    // Reset status.
    const statusEl = $$('#create-instance-status');
    if (statusEl) { statusEl.innerHTML = ''; statusEl.className = 'create-instance-status'; }
  }

  function closeCreateModal() {
    const modal = $$('#create-instance-modal');
    if (!modal) return;
    modal.classList.remove('open');
  }

  function setCreateStatus(html, kind) {
    const el = $$('#create-instance-status');
    if (!el) return;
    el.innerHTML = html;
    el.className = `create-instance-status create-instance-status-${kind || 'info'}`;
  }

  async function ensureSigner() {
    if (signer && connectedWallet) return signer;
    if (!window.ethereum) throw new Error('No injected wallet. Install MetaMask.');
    browserProvider = new ethers.BrowserProvider(window.ethereum);
    const accounts = await browserProvider.send('eth_requestAccounts', []);
    const network = await browserProvider.getNetwork();
    if (Number(network.chainId) !== 11155111) {
      try {
        await window.ethereum.request({
          method: 'wallet_switchEthereumChain',
          params: [{ chainId: '0xaa36a7' }],
        });
      } catch (_) {
        throw new Error('Switch your wallet to Sepolia (chainId 11155111).');
      }
    }
    signer = await browserProvider.getSigner();
    connectedWallet = accounts[0];
    return signer;
  }

  async function onSubmitCreateInstance(ev) {
    ev?.preventDefault?.();

    if (isZeroAddress(REGISTRY_ADDR)) {
      setCreateStatus(
        'FutarchyRegistry is not deployed yet — set REGISTRY_ADDR in <code>site-testnet/registry.js</code> after deploy.',
        'error'
      );
      return;
    }

    const name = ($$('#ci-name').value || '').trim();
    const symbol = ($$('#ci-symbol').value || '').trim();
    const description = ($$('#ci-description').value || '').trim();
    const supplyStr = ($$('#ci-supply').value || '').trim();
    const priceStr = ($$('#ci-price').value || '').trim();
    const timeoutMin = Number($$('#ci-timeout').value || '120');
    const twapMin = Number($$('#ci-twap').value || '60');
    const baseBondStr = ($$('#ci-bond').value || '').trim();

    if (!name)   { setCreateStatus('Name is required.', 'error'); return; }
    if (!symbol) { setCreateStatus('Symbol is required.', 'error'); return; }
    if (!supplyStr) { setCreateStatus('Initial supply is required.', 'error'); return; }
    if (!priceStr)  { setCreateStatus('Initial price is required.', 'error'); return; }
    if (!baseBondStr) { setCreateStatus('Base bond is required.', 'error'); return; }
    if (!isFinite(timeoutMin) || timeoutMin <= 0) { setCreateStatus('Timeout must be > 0 min.', 'error'); return; }
    if (!isFinite(twapMin) || twapMin <= 0) { setCreateStatus('TWAP window must be > 0 min.', 'error'); return; }

    let supplyWei;
    try { supplyWei = ethers.parseUnits(supplyStr, 18); }
    catch (_) { setCreateStatus(`Invalid supply: ${escapeHtml(supplyStr)}`, 'error'); return; }

    let priceFloat;
    try { priceFloat = parseFloat(priceStr); }
    catch (_) { setCreateStatus(`Invalid price: ${escapeHtml(priceStr)}`, 'error'); return; }

    let sqrtPriceX96;
    try { sqrtPriceX96 = priceToSqrtPriceX96(priceFloat); }
    catch (err) { setCreateStatus(`Price conversion failed: ${escapeHtml(err.message)}`, 'error'); return; }

    let bondWei;
    try { bondWei = ethers.parseEther(baseBondStr); }
    catch (_) { setCreateStatus(`Invalid bond: ${escapeHtml(baseBondStr)}`, 'error'); return; }

    const timeoutSec = Math.floor(timeoutMin * 60);
    const twapSec = Math.floor(twapMin * 60);

    // We run the 2-phase flow (Part1 then Part2). The combined atomic
    // `createFutarchy(...)` would also work but trips MetaMask's default
    // Sepolia RPC, which caps `eth_estimateGas` at 16_777_216 (~16.7M)
    // while the full one-shot needs ~18.8M. Splitting keeps each tx well
    // under the cap.
    try {
      const sig = await ensureSigner();
      const reg = new ethers.Contract(REGISTRY_ADDR, REGISTRY_ABI, sig);

      // ─── Step 1/2 ──────────────────────────────────────────────────────
      setCreateStatus('Step 1/2: deploying token + arbitration…', 'pending');
      const tx1 = await reg.createFutarchyPart1(
        name,
        symbol,
        description,
        supplyWei,
        sqrtPriceX96,
        timeoutSec,
        twapSec,
        bondWei,
      );
      setCreateStatus(
        `Step 1/2: tx sent <a href="${explorerTx(tx1.hash)}" target="_blank" rel="noopener">${tx1.hash.slice(0, 10)}…</a>. Waiting confirmation…`,
        'pending',
      );
      const rec1 = await tx1.wait();

      // Parse the new instance id from the FutarchyPart1Created event.
      // Topic[0] = event hash, topic[1] = indexed id, topic[2] = indexed creator.
      // We fall back to reading instancesCount() - 1 if the event is missing
      // (e.g. RPC dropped logs from the receipt) — that's append-only so the
      // most recent id is always the newly-created one for this caller.
      let newId;
      const part1Topic = ethers.id(
        'FutarchyPart1Created(uint256,address,string,string,address,address)'
      );
      const part1Log = rec1.logs && rec1.logs.find(l =>
        l.address.toLowerCase() === REGISTRY_ADDR.toLowerCase() && l.topics[0] === part1Topic
      );
      if (part1Log) {
        newId = Number(BigInt(part1Log.topics[1]));
      } else {
        try {
          const n = await reg.instancesCount();
          newId = Number(n) - 1;
        } catch (_) {
          throw new Error('Part1 succeeded but could not determine new instance id; check tx logs and re-trigger Part2 from the picker.');
        }
      }

      setCreateStatus(
        `✓ Step 1/2 done (block ${rec1.blockNumber}, instance #${newId}). Starting step 2/2…`,
        'pending',
      );

      // ─── Step 2/2 — auto-triggered ─────────────────────────────────────
      const tx2 = await reg.createFutarchyPart2(newId);
      setCreateStatus(
        `Step 2/2: tx sent <a href="${explorerTx(tx2.hash)}" target="_blank" rel="noopener">${tx2.hash.slice(0, 10)}…</a>. Waiting confirmation…`,
        'pending',
      );
      const rec2 = await tx2.wait();
      setCreateStatus(
        `✓ Step 2/2 done (block ${rec2.blockNumber}). Instance #${newId} is READY. Refreshing…`,
        'ok',
      );

      // Refresh + select the new instance.
      await loadInstances();
      await loadProposalCounts();
      selectInstance(newId);
      renderPicker();
      updateActiveHeader();

      setTimeout(() => closeCreateModal(), 1800);
    } catch (err) {
      console.error('[registry] createFutarchy (2-phase) failed', err);
      setCreateStatus(
        `Failed: ${escapeHtml(err.shortMessage || err.message || String(err))}. If Step 1/2 succeeded, you can resume by clicking "Complete deployment" on the chip for the pending instance.`,
        'error',
      );
    }
  }

  function wireCreateModal() {
    const openBtn = $$('#create-instance-open');
    if (openBtn) openBtn.addEventListener('click', openCreateModal);

    const closeBtn = $$('#create-instance-close');
    if (closeBtn) closeBtn.addEventListener('click', closeCreateModal);

    const cancelBtn = $$('#create-instance-cancel');
    if (cancelBtn) cancelBtn.addEventListener('click', closeCreateModal);

    const backdrop = $$('#create-instance-modal');
    if (backdrop) {
      backdrop.addEventListener('click', (ev) => {
        // Only close when clicking the backdrop itself, not children.
        if (ev.target === backdrop) closeCreateModal();
      });
    }

    const form = $$('#create-instance-form');
    if (form) form.addEventListener('submit', onSubmitCreateInstance);

    // Disable the create button if registry isn't deployed — but still let
    // people open the modal to read the helpful explanation.
    if (isZeroAddress(REGISTRY_ADDR)) {
      const note = $$('#create-instance-registry-note');
      if (note) {
        note.innerHTML = `
          <strong>FutarchyRegistry is not deployed yet.</strong>
          Set <code>REGISTRY_ADDR</code> in <code>site-testnet/registry.js</code>
          (line marked <code>// REGISTRY_ADDR</code>) to the deployed address,
          then redeploy this site.
        `;
        note.style.display = 'block';
      }
    }
  }

  // ─── Boot ────────────────────────────────────────────────────────────

  async function init() {
    try {
      provider = new ethers.JsonRpcProvider(RPC);

      await loadInstances();
      // Counts are optional; the picker still renders without them.
      loadProposalCounts().then(() => renderPicker()).catch((e) => console.error('[registry] loadProposalCounts failed', e));

      restoreActiveId();
      publishActiveInstance();
      renderPicker();
      updateActiveHeader();
      wireCreateModal();
    } catch (err) {
      console.error('[registry] init failed:', err);
      const picker = $$('#instances-picker');
      const header = $$('#instance-active-header');
      const msg = err && (err.message || String(err)) || 'unknown error';
      if (picker) {
        picker.innerHTML = `<p class="sep-empty">Registry init failed: ${escapeHtml(msg)}. Check browser console.</p>`;
      }
      if (header) {
        header.innerHTML = `<span class="instance-active-label">Active instance:</span><strong>error</strong>`;
      }
    }

    // Periodic refresh — keeps the picker count up to date and picks up new
    // instances created from other tabs / wallets.
    setInterval(async () => {
      try {
        await loadInstances();
        await loadProposalCounts();
        // If our active id disappeared (shouldn't happen on append-only registry,
        // but be defensive), fall back to instance 0.
        if (!instances.some(i => i.id === activeId)) {
          activeId = instances[0]?.id ?? 0;
          persistActiveId();
          publishActiveInstance();
        }
        renderPicker();
        updateActiveHeader();
      } catch (err) {
        console.error('[registry] refresh failed', err);
      }
    }, REFRESH_INTERVAL);
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
