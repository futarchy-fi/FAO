/* sale.js — Buy panel (multi-instance + revamped layout).
 *
 * Renders the active instance's sale: hero strip with token identity, big
 * current-price, phase badge, optional initial-phase progress bar, a focused
 * buy module with quick-buy chips, and the stat grid beside it. Contract
 * addresses live behind a collapsed <details> block at the bottom.
 *
 * Buy flow: if the user isn't connected, `window.connectWallet()` (shared.js)
 * is triggered automatically as the first step of the buy. No more
 * "Connect wallet first" friction prompt.
 */

(() => {
  'use strict';

  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const REFRESH_INTERVAL = 30_000;
  const ZERO = '0x0000000000000000000000000000000000000000';

  const SALE_ABI = [
    'function INITIAL_PRICE_WEI_PER_TOKEN() view returns (uint256)',
    'function MIN_INITIAL_PHASE_SOLD() view returns (uint256)',
    'function INITIAL_PHASE_DURATION() view returns (uint256)',
    'function initialPhaseFinalized() view returns (bool)',
    'function initialTokensSold() view returns (uint256)',
    'function totalCurveTokensSold() view returns (uint256)',
    'function totalAmountRaised() view returns (uint256)',
    'function currentPriceWeiPerToken() view returns (uint256)',
    'function buy(uint256 numTokens) payable',
    // FAOSale flavour
    'function saleStart() view returns (uint256)',
    'function initialPhaseEnd() view returns (uint256)',
    // InstanceSale (v3) flavour
    'function SALE_START() view returns (uint256)',
    'function INITIAL_PHASE_END() view returns (uint256)',
  ];

  const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function symbol() view returns (string)',
    'function name() view returns (string)',
  ];

  const $$ = (sel) => document.querySelector(sel);
  const isZero = (a) => !a || a.toLowerCase() === ZERO;
  const fmtEth   = (wei) => `${(+ethers.formatEther(wei)).toFixed(6)} ETH`;
  const fmtEthShort = (wei) => `${(+ethers.formatEther(wei)).toFixed(4)} ETH`;
  const fmtToken = (units, sym) => `${(+ethers.formatUnits(units, 18)).toFixed(2)} ${sym}`;
  const fmtAddr  = (a) => (!a || isZero(a)) ? '—' : `${a.slice(0, 6)}…${a.slice(-4)}`;
  const explorerAddr = (a) => `https://sepolia.etherscan.io/address/${a}`;

  async function safe(fn, fallback) { try { return await fn(); } catch (_) { return fallback; } }

  let provider;

  function currentInstance() { return window.activeInstance || null; }
  function saleAddress(inst) { return inst && inst.sale && !isZero(inst.sale) ? inst.sale : null; }
  function tokenAddress(inst) { return inst && inst.token && !isZero(inst.token) ? inst.token : null; }

  // ─── Boot ────────────────────────────────────────────────────────────
  async function init() {
    provider = new ethers.JsonRpcProvider(RPC);

    wireControls();

    window.addEventListener('fao:activeInstanceChanged', () => {
      refresh().catch((e) => console.error('[sale] refresh failed', e));
    });
    window.addEventListener('fao:walletChanged', () => {
      refresh().catch((e) => console.error('[sale] refresh failed', e));
    });

    if (!window.activeInstance) {
      await new Promise((resolve) => {
        window.addEventListener('fao:sharedReady', resolve, { once: true });
      });
    }

    await refresh();
    setInterval(() => {
      refresh().catch((e) => console.error('[sale] refresh failed', e));
    }, REFRESH_INTERVAL);
  }

  // ─── Controls ────────────────────────────────────────────────────────
  function wireControls() {
    const buyBtn = $$('#sale-buy');
    const input = $$('#sale-input');
    if (buyBtn) buyBtn.addEventListener('click', onBuyPreview);
    if (input) input.addEventListener('input', updateCostPreview);

    document.querySelectorAll('[data-quick-buy]').forEach(btn => {
      btn.addEventListener('click', () => {
        const v = btn.dataset.quickBuy;
        if (!v || !input) return;
        input.value = v;
        updateCostPreview();
      });
    });

    const cancelBtn = $$('#sale-confirm-cancel');
    const goBtn = $$('#sale-confirm-go');
    if (cancelBtn) cancelBtn.addEventListener('click', closeConfirmCard);
    if (goBtn) goBtn.addEventListener('click', onBuyExecute);
  }

  function showConfirmCard() {
    const card = $$('#sale-confirm-card');
    const btn = $$('#sale-buy');
    if (card) card.hidden = false;
    if (btn) btn.hidden = true;
  }
  function closeConfirmCard() {
    const card = $$('#sale-confirm-card');
    const btn = $$('#sale-buy');
    if (card) card.hidden = true;
    if (btn) btn.hidden = false;
    setBuyStatus('');
  }

  function setBuyStatus(text, kind) {
    const el = $$('#sale-buy-status');
    if (!el) return;
    el.textContent = text || '';
    el.className = `sale-buy-status${kind ? ' sale-buy-status-' + kind : ''}`;
  }

  // ─── Phase helpers ───────────────────────────────────────────────────
  function salePhaseBadge(phase) {
    switch (phase) {
      case 'initial-sale':   return { label: 'initial sale',  cls: 'badge-initial' };
      case 'phase-ended':    return { label: 'initial sale',  cls: 'badge-ended' };
      case 'bonding-curve':  return { label: 'bonding curve', cls: 'badge-curve' };
      case 'not-started':    return { label: 'not started',   cls: 'badge-pending' };
      default:               return { label: '—',             cls: 'badge-unknown' };
    }
  }

  function derivePhase({ saleStart, phaseEnd, finalized, now }) {
    if (saleStart === 0n)         return 'not-started';
    if (finalized === true)       return 'bonding-curve';
    if (phaseEnd && now >= phaseEnd) return 'phase-ended';
    return 'initial-sale';
  }

  // ─── Buy flow (two-stage) ────────────────────────────────────────────
  //
  // Stage 1 (onBuyPreview): user clicks Buy. We connect the wallet if not
  // already connected, quote the cost, and render an in-app preview card
  // so the user can sanity-check what's about to happen BEFORE MetaMask's
  // opaque hex popup. The actual tx is NOT sent yet.
  //
  // Stage 2 (onBuyExecute): user clicks "Confirm in wallet →" inside the
  // preview card. We send the tx and the wallet asks for final approval.
  async function onBuyPreview() {
    const inst = currentInstance();
    const sAddr = saleAddress(inst);
    if (!sAddr) { setBuyStatus('No sale on the active instance.', 'error'); return; }

    const input = $$('#sale-input');
    const n = parseInt(input?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) {
      setBuyStatus('Enter a positive whole number of tokens.', 'error');
      return;
    }

    try {
      // Auto-connect wallet on first Buy click; receive-address only known
      // once the wallet is connected.
      if (!window.activeSigner) {
        setBuyStatus('Connecting wallet…', 'pending');
        await window.connectWallet();
      }

      // Quote the current price at the latest block.
      const saleR = new ethers.Contract(sAddr, SALE_ABI, provider);
      const priceWei = await saleR.currentPriceWeiPerToken();
      const cost = priceWei * BigInt(n);

      const sym = $$('#sale-input-suffix')?.textContent || 'TKN';
      const recv = window.connectedWallet || '0x…';
      if ($$('#sale-confirm-buy'))  $$('#sale-confirm-buy').textContent  = `${n} ${sym}`;
      if ($$('#sale-confirm-pay'))  $$('#sale-confirm-pay').textContent  = `${(+ethers.formatEther(cost)).toFixed(6)} ETH`;
      if ($$('#sale-confirm-sale')) $$('#sale-confirm-sale').textContent = sAddr;
      if ($$('#sale-confirm-recv')) $$('#sale-confirm-recv').textContent = recv;

      showConfirmCard();
      setBuyStatus('Review the summary above, then confirm in your wallet.', 'pending');
    } catch (e) {
      console.error(e);
      setBuyStatus(`Connect failed: ${e?.shortMessage || e?.message || e}`, 'error');
    }
  }

  async function onBuyExecute() {
    const inst = currentInstance();
    const sAddr = saleAddress(inst);
    if (!sAddr) { setBuyStatus('No sale on the active instance.', 'error'); return; }

    const input = $$('#sale-input');
    const n = parseInt(input?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) {
      setBuyStatus('Enter a positive whole number of tokens.', 'error');
      closeConfirmCard();
      return;
    }

    const goBtn = $$('#sale-confirm-go');
    const cancelBtn = $$('#sale-confirm-cancel');
    if (goBtn) goBtn.disabled = true;
    if (cancelBtn) cancelBtn.disabled = true;

    try {
      const signer = window.activeSigner || (await window.connectWallet());
      const saleR = new ethers.Contract(sAddr, SALE_ABI, provider);
      const priceWei = await saleR.currentPriceWeiPerToken();
      const cost = priceWei * BigInt(n);

      setBuyStatus(`Waiting for wallet approval · ${fmtEth(cost)}…`, 'pending');
      const sale = new ethers.Contract(sAddr, SALE_ABI, signer);
      const tx = await sale.buy(n, { value: cost });
      setBuyStatus('Mining…', 'pending');
      await tx.wait();
      setBuyStatus(`Bought ${n} tokens for ${fmtEthShort(cost)} ✓`, 'ok');
      closeConfirmCard();
      await refresh();
    } catch (e) {
      console.error(e);
      const msg = e?.shortMessage || e?.message || String(e);
      setBuyStatus(`Buy failed: ${msg}`, 'error');
    } finally {
      if (goBtn) goBtn.disabled = false;
      if (cancelBtn) cancelBtn.disabled = false;
    }
  }

  async function updateCostPreview() {
    const inst = currentInstance();
    const sAddr = saleAddress(inst);
    const costEl = $$('#sale-cost');
    if (!costEl) return;
    if (!sAddr) { costEl.textContent = '—'; return; }

    const n = parseInt($$('#sale-input')?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) { costEl.textContent = '—'; return; }

    const sale = new ethers.Contract(sAddr, SALE_ABI, provider);
    const priceWei = await safe(() => sale.currentPriceWeiPerToken(), 0n);
    if (priceWei === 0n) { costEl.textContent = '—'; return; }
    costEl.textContent = fmtEth(priceWei * BigInt(n));
  }

  // ─── Hero / stats render ─────────────────────────────────────────────
  function renderNoSale(reason) {
    const root = $$('.sale-page');
    if (!root) return;
    root.innerHTML = `
      <div class="sale-empty-card">
        <h2>No sale on this futarchy.</h2>
        <p>${reason || 'The active instance does not have an attached InstanceSale.'}</p>
        <p><a class="btn btn-primary" href="./">← Browse other futarchies</a></p>
      </div>
    `;
  }

  async function refresh() {
    const inst = currentInstance();
    const sAddr = saleAddress(inst);
    const tAddr = tokenAddress(inst);

    if (!sAddr) {
      renderNoSale(inst ? `"${inst.name || inst.symbol || inst.id}" has no sale (this is a legacy v2 instance or a pending Part2).` : 'No active instance.');
      return;
    }

    const code = await safe(() => provider.getCode(sAddr), '0x');
    if (!code || code === '0x') {
      renderNoSale(`Sale address ${sAddr} has no code on Sepolia.`);
      return;
    }

    const sale = new ethers.Contract(sAddr, SALE_ABI, provider);
    const token = tAddr ? new ethers.Contract(tAddr, ERC20_ABI, provider) : null;

    const [
      saleStartImm, saleStartMut, phaseEndImm, phaseEndMut,
      finalized, priceWei, minInitial, initialSold, curveSold, totalRaised,
      tokenSymbol, tokenNameRead,
    ] = await Promise.all([
      safe(() => sale.SALE_START(), null),
      safe(() => sale.saleStart(), null),
      safe(() => sale.INITIAL_PHASE_END(), null),
      safe(() => sale.initialPhaseEnd(), null),
      safe(() => sale.initialPhaseFinalized(), false),
      safe(() => sale.currentPriceWeiPerToken(), 0n),
      safe(() => sale.MIN_INITIAL_PHASE_SOLD(), 0n),
      safe(() => sale.initialTokensSold(), 0n),
      safe(() => sale.totalCurveTokensSold(), 0n),
      safe(() => sale.totalAmountRaised(), 0n),
      token ? safe(() => token.symbol(), inst.symbol || 'TKN') : Promise.resolve(inst?.symbol || 'TKN'),
      token ? safe(() => token.name(), inst.name || '') : Promise.resolve(inst?.name || ''),
    ]);

    const saleStart = saleStartImm != null ? BigInt(saleStartImm) : (saleStartMut != null ? BigInt(saleStartMut) : 0n);
    const phaseEnd  = phaseEndImm  != null ? BigInt(phaseEndImm)  : (phaseEndMut  != null ? BigInt(phaseEndMut)  : 0n);
    const now = BigInt(Math.floor(Date.now() / 1000));
    const phase = derivePhase({ saleStart, phaseEnd, finalized, now });
    const badge = salePhaseBadge(phase);
    const sym = tokenSymbol || inst?.symbol || 'TKN';
    const tokenName = tokenNameRead || inst?.name || '';
    const description = (inst?.description || '').trim();

    // ─── Hero ────────────────────────────────────────────────────────
    if ($$('#sale-hero-symbol')) $$('#sale-hero-symbol').textContent = sym;
    if ($$('#sale-hero-name'))   $$('#sale-hero-name').textContent = tokenName || sym;
    if ($$('#sale-hero-desc'))   $$('#sale-hero-desc').textContent = description || ' ';
    const pb = $$('#sale-phase-badge');
    if (pb) {
      pb.textContent = badge.label;
      pb.className = `phase-badge ${badge.cls}`;
    }
    const addrLink = $$('#sale-hero-addr');
    if (addrLink) {
      addrLink.href = explorerAddr(sAddr);
      addrLink.textContent = `sale ${fmtAddr(sAddr)}`;
    }
    if ($$('#sale-hero-price')) {
      $$('#sale-hero-price').textContent = priceWei === 0n ? '—' : `${(+ethers.formatEther(priceWei)).toFixed(6)} ETH`;
    }
    if ($$('#sale-hero-price-sub')) {
      $$('#sale-hero-price-sub').textContent = `per ${sym}`;
    }
    if ($$('#sale-input-suffix')) $$('#sale-input-suffix').textContent = sym;

    // ─── Progress bar (initial phase only) ──────────────────────────
    const block = $$('#sale-progress-block');
    if (block) {
      const showProgress = !finalized && minInitial && minInitial > 0n;
      block.hidden = !showProgress;
      if (showProgress) {
        const pct = Number((initialSold * 10000n) / minInitial) / 100; // 2 decimals
        const fill = $$('#sale-progress-fill');
        if (fill) fill.style.width = `${Math.min(100, Math.max(0, pct))}%`;
        const text = $$('#sale-progress-text');
        if (text) text.textContent = `${initialSold.toString()} / ${minInitial.toString()} ${sym}`;
        const foot = $$('#sale-progress-foot');
        if (foot) {
          const endTs = Number(phaseEnd);
          if (endTs > 0) {
            const endDate = new Date(endTs * 1000);
            const expired = Date.now() > endDate.getTime();
            foot.textContent = expired
              ? `Window ended ${endDate.toLocaleString()} · awaiting next buy to finalize`
              : `Ends ${endDate.toLocaleString()}`;
          } else foot.textContent = '';
        }
      }
    }

    // ─── Stats grid ──────────────────────────────────────────────────
    if ($$('#sale-raised'))       $$('#sale-raised').textContent = fmtEthShort(totalRaised);
    if ($$('#sale-initial-sold')) $$('#sale-initial-sold').textContent = `${initialSold.toString()} / ${minInitial.toString()} ${sym}`;
    if ($$('#sale-curve-sold'))   $$('#sale-curve-sold').textContent = `${curveSold.toString()} ${sym}`;
    if ($$('#sale-phase-end'))    $$('#sale-phase-end').textContent = phaseEnd === 0n ? '—' : new Date(Number(phaseEnd) * 1000).toLocaleString();

    // ─── Your position ───────────────────────────────────────────────
    const wallet = window.connectedWallet;
    if (wallet && token) {
      const [bal, ethBal] = await Promise.all([
        safe(() => token.balanceOf(wallet), 0n),
        safe(() => provider.getBalance(wallet), 0n),
      ]);
      if ($$('#sale-balance')) $$('#sale-balance').textContent = fmtToken(bal, sym);
      if ($$('#sale-eth'))     $$('#sale-eth').textContent = fmtEthShort(ethBal);
      if (!finalized && saleStart !== 0n) {
        const remaining = minInitial > initialSold ? (minInitial - initialSold) : 0n;
        if ($$('#sale-remaining')) $$('#sale-remaining').textContent = `${remaining.toString()} ${sym}`;
      } else {
        if ($$('#sale-remaining')) $$('#sale-remaining').textContent = 'n/a (bonding curve)';
      }
    } else {
      if ($$('#sale-balance'))   $$('#sale-balance').textContent = '— (connect wallet)';
      if ($$('#sale-eth'))       $$('#sale-eth').textContent = '—';
      if ($$('#sale-remaining')) $$('#sale-remaining').textContent = '—';
    }

    // ─── Contract addresses (footer) ─────────────────────────────────
    const fillAddr = (id, addr) => {
      const el = document.getElementById(id);
      if (!el) return;
      if (!addr || isZero(addr)) { el.textContent = '—'; return; }
      el.innerHTML = `<a href="${explorerAddr(addr)}" target="_blank" rel="noopener">${addr}</a>`;
    };
    fillAddr('sale-addr-table-sale', sAddr);
    fillAddr('sale-addr-table-token', tAddr);
    fillAddr('sale-addr-table-pool', inst?.spotPool);

    await updateCostPreview();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
