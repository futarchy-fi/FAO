/* sale.js — Trade panel: Buy + Sell with 4 paths and price comparison.
 *
 * Buy paths:
 *   - via sale (`InstanceSale.buy`)
 *   - via Uniswap (external link to app.uniswap.org/swap)
 * Sell paths:
 *   - via ragequit (`InstanceSale.ragequit`)
 *   - via Uniswap (external link)
 *
 * Sale-side actions show a pre-confirm card with the parsed summary before
 * triggering MetaMask. Uniswap actions open a new tab with the swap
 * pre-configured. A comparison banner appears when the price gap between
 * sale and Uniswap on the active side is non-trivial.
 */

(() => {
  'use strict';

  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const REFRESH_INTERVAL = 30_000;
  const ZERO = '0x0000000000000000000000000000000000000000';
  const UNI_SWAP_URL = 'https://app.uniswap.org/swap';

  const SALE_ABI = [
    'function INITIAL_PRICE_WEI_PER_TOKEN() view returns (uint256)',
    'function MIN_INITIAL_PHASE_SOLD() view returns (uint256)',
    'function INITIAL_PHASE_DURATION() view returns (uint256)',
    'function initialPhaseFinalized() view returns (bool)',
    'function initialTokensSold() view returns (uint256)',
    'function totalCurveTokensSold() view returns (uint256)',
    'function totalAmountRaised() view returns (uint256)',
    'function currentPriceWeiPerToken() view returns (uint256)',
    'function SALE_START() view returns (uint256)',
    'function INITIAL_PHASE_END() view returns (uint256)',
    'function effectiveSupply() view returns (uint256)',
    'function quoteRagequit(uint256 numTokens) view returns (uint256)',
    'function ragequitTokens(uint256) view returns (address)',
    'function ragequitTokensLength() view returns (uint256)',
    'function buy(uint256 numTokens) payable',
    'function ragequit(uint256 numTokens)',
  ];
  const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function symbol() view returns (string)',
    'function name() view returns (string)',
    'function approve(address,uint256) returns (bool)',
    'function allowance(address,address) view returns (uint256)',
  ];
  const POOL_ABI = [
    'function token0() view returns (address)',
    'function token1() view returns (address)',
    'function slot0() view returns (uint160,int24,uint16,uint16,uint16,uint8,bool)',
    'function liquidity() view returns (uint128)',
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
  // Per-refresh cache that the action handlers read so they don't refetch.
  let ctx = {
    inst: null,
    sym: 'TKN',
    salePriceWei: 0n,
    uniPriceWei: 0n,       // 0n if pool has no liquidity
    poolHasLiquidity: false,
    seederAddr: null,      // first entry of sale.ragequitTokens, if any
    userBalance: 0n,       // token balance of connected wallet
    confirmAction: null,   // 'buy' | 'ragequit'
  };

  // ─── Boot ────────────────────────────────────────────────────────────
  async function init() {
    provider = new ethers.JsonRpcProvider(RPC);
    wireControls();

    window.addEventListener('fao:activeInstanceChanged', () => { refresh().catch(console.error); });
    window.addEventListener('fao:walletChanged',          () => { refresh().catch(console.error); });

    if (!window.activeInstance) {
      await new Promise((resolve) => window.addEventListener('fao:sharedReady', resolve, { once: true }));
    }
    await refresh();
    setInterval(() => refresh().catch(console.error), REFRESH_INTERVAL);
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', init);
  else init();

  // ─── Controls ────────────────────────────────────────────────────────
  function wireControls() {
    const buyAmt   = $$('#trade-buy-amount');
    const sellAmt  = $$('#trade-sell-amount');
    if (buyAmt)   buyAmt.addEventListener('input', updateBuyCost);
    if (sellAmt)  sellAmt.addEventListener('input', updateSellQuote);

    document.querySelectorAll('[data-qb-amt]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (!buyAmt) return;
        buyAmt.value = btn.dataset.qbAmt;
        updateBuyCost();
      });
    });
    document.querySelectorAll('[data-qs-pct]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (!sellAmt) return;
        const pct = Number(btn.dataset.qsPct);
        // % of the user's token balance (whole-tokens).
        const wholeTokens = Number(ethers.formatUnits(ctx.userBalance, 18));
        const n = Math.max(1, Math.floor(wholeTokens * pct / 100));
        sellAmt.value = String(n);
        updateSellQuote();
      });
    });

    const buyBtn  = $$('#trade-buy-sale-btn');
    const sellBtn = $$('#trade-sell-rq-btn');
    if (buyBtn)  buyBtn.addEventListener('click', onBuyPreview);
    if (sellBtn) sellBtn.addEventListener('click', onRagequitPreview);

    const cancelBtn = $$('#sale-confirm-cancel');
    const goBtn = $$('#sale-confirm-go');
    if (cancelBtn) cancelBtn.addEventListener('click', closeConfirmCard);
    if (goBtn) goBtn.addEventListener('click', onConfirmExecute);
  }

  function setStatus(text, kind) {
    const el = $$('#sale-buy-status');
    if (!el) return;
    el.textContent = text || '';
    el.className = `sale-buy-status${kind ? ' sale-buy-status-' + kind : ''}`;
  }

  function showConfirmCard(action, rows) {
    ctx.confirmAction = action;
    const head = $$('#sale-confirm-head');
    const rowsEl = $$('#sale-confirm-rows');
    if (head) head.textContent = action === 'ragequit'
      ? 'Ragequit summary — burn tokens, receive treasury share:'
      : 'You\'re about to:';
    if (rowsEl) {
      rowsEl.innerHTML = rows.map(r =>
        `<div class="sale-confirm-row"><span>${r.label}</span><strong>${r.value}</strong></div>`
      ).join('');
    }
    $$('#sale-confirm-card').hidden = false;
    $$('#trade-buy-sale-btn').disabled = true;
    $$('#trade-sell-rq-btn').disabled = true;
  }

  function closeConfirmCard() {
    ctx.confirmAction = null;
    $$('#sale-confirm-card').hidden = true;
    $$('#trade-buy-sale-btn').disabled = false;
    $$('#trade-sell-rq-btn').disabled = false;
    setStatus('');
  }

  // ─── Phase helpers ───────────────────────────────────────────────────
  function salePhaseBadge(phase) {
    switch (phase) {
      case 'initial-sale':  return { label: 'initial sale',  cls: 'badge-initial' };
      case 'phase-ended':   return { label: 'initial sale',  cls: 'badge-ended' };
      case 'bonding-curve': return { label: 'bonding curve', cls: 'badge-curve' };
      case 'not-started':   return { label: 'not started',   cls: 'badge-pending' };
      default:              return { label: '—',             cls: 'badge-unknown' };
    }
  }
  function derivePhase({ saleStart, phaseEnd, finalized, now }) {
    if (saleStart === 0n)         return 'not-started';
    if (finalized === true)       return 'bonding-curve';
    if (phaseEnd && now >= phaseEnd) return 'phase-ended';
    return 'initial-sale';
  }

  // ─── Uniswap spot price ──────────────────────────────────────────────
  // Reads pool.slot0().sqrtPriceX96 and returns "wei of WETH per 1 whole token".
  async function getUniSpotPriceWei(poolAddr, tokenAddr) {
    if (!poolAddr || isZero(poolAddr)) return { priceWei: 0n, hasLiquidity: false };
    const pool = new ethers.Contract(poolAddr, POOL_ABI, provider);
    const [t0, slot0, liq] = await Promise.all([
      safe(() => pool.token0(), null),
      safe(() => pool.slot0(), null),
      safe(() => pool.liquidity(), null),
    ]);
    if (t0 == null || slot0 == null) return { priceWei: 0n, hasLiquidity: false };
    const sqrtBN = BigInt(slot0[0]);
    if (sqrtBN === 0n) return { priceWei: 0n, hasLiquidity: false };
    const Q192 = 1n << 192n;
    const ratio = sqrtBN * sqrtBN; // Q192 fixed-point, token1/token0
    const faoIsT0 = t0.toLowerCase() === tokenAddr.toLowerCase();
    const ONE = 10n ** 18n;
    // wei of WETH per 1 whole token (1e18 units).
    const priceWei = faoIsT0 ? (ratio * ONE) / Q192 : (Q192 * ONE) / ratio;
    return { priceWei, hasLiquidity: liq != null && BigInt(liq) > 0n };
  }

  // ─── Refresh + render ────────────────────────────────────────────────
  async function refresh() {
    const inst = window.activeInstance;
    ctx.inst = inst;
    if (!inst || !inst.sale || isZero(inst.sale)) {
      renderNoSale(inst ? `"${inst.name || inst.symbol || inst.id}" has no sale.` : 'No active instance.');
      return;
    }

    const code = await safe(() => provider.getCode(inst.sale), '0x');
    if (!code || code === '0x') {
      renderNoSale(`Sale ${inst.sale} has no code on Sepolia.`);
      return;
    }

    const sale  = new ethers.Contract(inst.sale, SALE_ABI, provider);
    const token = new ethers.Contract(inst.token, ERC20_ABI, provider);

    const [
      saleStartImm, phaseEndImm,
      finalized, salePriceWei, minInitial, initialSold, curveSold, totalRaised,
      tokenSymbol, tokenName,
      rqCount,
    ] = await Promise.all([
      safe(() => sale.SALE_START(), 0n),
      safe(() => sale.INITIAL_PHASE_END(), 0n),
      safe(() => sale.initialPhaseFinalized(), false),
      safe(() => sale.currentPriceWeiPerToken(), 0n),
      safe(() => sale.MIN_INITIAL_PHASE_SOLD(), 0n),
      safe(() => sale.initialTokensSold(), 0n),
      safe(() => sale.totalCurveTokensSold(), 0n),
      safe(() => sale.totalAmountRaised(), 0n),
      safe(() => token.symbol(), inst.symbol || 'TKN'),
      safe(() => token.name(), inst.name || ''),
      safe(() => sale.ragequitTokensLength(), 0n),
    ]);

    const saleStart = BigInt(saleStartImm);
    const phaseEnd  = BigInt(phaseEndImm);
    const now = BigInt(Math.floor(Date.now() / 1000));
    const phase = derivePhase({ saleStart, phaseEnd, finalized, now });
    const sym = tokenSymbol;
    ctx.sym = sym;
    ctx.salePriceWei = BigInt(salePriceWei);

    // Seeder (= first ragequit-list entry, by convention).
    const seederAddr = Number(rqCount) > 0
      ? await safe(() => sale.ragequitTokens(0), null)
      : null;
    ctx.seederAddr = seederAddr;

    // Uniswap spot price.
    const { priceWei: uniPriceWei, hasLiquidity } = await getUniSpotPriceWei(inst.spotPool, inst.token);
    ctx.uniPriceWei = uniPriceWei;
    ctx.poolHasLiquidity = hasLiquidity;

    // Hero ───────────────────────────────────────────────────────────
    if ($$('#sale-hero-symbol')) $$('#sale-hero-symbol').textContent = sym;
    if ($$('#sale-hero-name'))   $$('#sale-hero-name').textContent = tokenName || sym;
    if ($$('#sale-hero-desc'))   $$('#sale-hero-desc').textContent = (inst.description || '').trim() || ' ';
    const pb = $$('#sale-phase-badge');
    if (pb) {
      const b = salePhaseBadge(phase);
      pb.textContent = b.label;
      pb.className = `phase-badge ${b.cls}`;
    }
    const heroLink = $$('#sale-hero-addr');
    if (heroLink) {
      heroLink.href = explorerAddr(inst.sale);
      heroLink.textContent = `sale ${fmtAddr(inst.sale)}`;
    }
    if ($$('#sale-hero-price'))     $$('#sale-hero-price').textContent     = salePriceWei === 0n ? '—' : fmtEth(salePriceWei);
    if ($$('#sale-hero-price-sub')) $$('#sale-hero-price-sub').textContent = `per ${sym}`;
    if ($$('#trade-buy-suffix'))    $$('#trade-buy-suffix').textContent    = sym;
    if ($$('#trade-sell-suffix'))   $$('#trade-sell-suffix').textContent   = sym;

    // Progress bar ──────────────────────────────────────────────────
    const block = $$('#sale-progress-block');
    if (block) {
      const show = !finalized && minInitial && BigInt(minInitial) > 0n;
      block.hidden = !show;
      if (show) {
        const pct = Number((BigInt(initialSold) * 10000n) / BigInt(minInitial)) / 100;
        if ($$('#sale-progress-fill')) $$('#sale-progress-fill').style.width = `${Math.min(100, Math.max(0, pct))}%`;
        if ($$('#sale-progress-text')) $$('#sale-progress-text').textContent = `${initialSold.toString()} / ${minInitial.toString()} ${sym}`;
        const endTs = Number(phaseEnd);
        const expired = endTs > 0 && Date.now() > endTs * 1000;
        if ($$('#sale-progress-foot')) $$('#sale-progress-foot').textContent =
          endTs === 0 ? '' :
          expired ? `Window ended ${new Date(endTs * 1000).toLocaleString()} · awaiting next buy to finalize` :
                    `Ends ${new Date(endTs * 1000).toLocaleString()}`;
      }
    }

    // Trade-grid prices + Uniswap links ─────────────────────────────
    if ($$('#trade-buy-sale-price')) $$('#trade-buy-sale-price').textContent = `${fmtEth(salePriceWei)}/${sym}`;
    if ($$('#trade-sell-rq-price'))  $$('#trade-sell-rq-price').textContent  = (await ragequitPerTokenLabel(sale, sym));
    if (hasLiquidity) {
      if ($$('#trade-buy-uni-price'))  $$('#trade-buy-uni-price').textContent  = `${fmtEth(uniPriceWei)}/${sym}`;
      if ($$('#trade-sell-uni-price')) $$('#trade-sell-uni-price').textContent = `${fmtEth(uniPriceWei)}/${sym}`;
    } else {
      if ($$('#trade-buy-uni-price'))  $$('#trade-buy-uni-price').textContent  = 'no liquidity';
      if ($$('#trade-sell-uni-price')) $$('#trade-sell-uni-price').textContent = 'no liquidity';
    }
    // Uniswap links: ETH ↔ token on Sepolia.
    if ($$('#trade-buy-uni-btn'))  $$('#trade-buy-uni-btn').href  = `${UNI_SWAP_URL}?inputCurrency=ETH&outputCurrency=${inst.token}&chain=sepolia`;
    if ($$('#trade-sell-uni-btn')) $$('#trade-sell-uni-btn').href = `${UNI_SWAP_URL}?inputCurrency=${inst.token}&outputCurrency=ETH&chain=sepolia`;

    // Comparison banner ─────────────────────────────────────────────
    renderCompareBanner(salePriceWei, uniPriceWei, hasLiquidity, sym);

    // Stats + addresses ─────────────────────────────────────────────
    if ($$('#sale-raised'))       $$('#sale-raised').textContent       = fmtEthShort(totalRaised);
    if ($$('#sale-initial-sold')) $$('#sale-initial-sold').textContent = `${initialSold.toString()} / ${minInitial.toString()} ${sym}`;
    if ($$('#sale-curve-sold'))   $$('#sale-curve-sold').textContent   = `${curveSold.toString()} ${sym}`;
    if ($$('#sale-phase-end'))    $$('#sale-phase-end').textContent    = phaseEnd === 0n ? '—' : new Date(Number(phaseEnd) * 1000).toLocaleString();

    const wallet = window.connectedWallet;
    if (wallet) {
      const [bal, ethBal, flpBal] = await Promise.all([
        safe(() => token.balanceOf(wallet), 0n),
        safe(() => provider.getBalance(wallet), 0n),
        seederAddr ? safe(() => new ethers.Contract(seederAddr, ERC20_ABI, provider).balanceOf(wallet), 0n) : Promise.resolve(0n),
      ]);
      ctx.userBalance = BigInt(bal);
      if ($$('#sale-balance')) $$('#sale-balance').textContent = fmtToken(bal, sym);
      if ($$('#sale-eth'))     $$('#sale-eth').textContent     = fmtEthShort(ethBal);
      if ($$('#sale-flp-balance')) $$('#sale-flp-balance').textContent =
        seederAddr ? `${(+ethers.formatUnits(flpBal, 18)).toFixed(6)} fLP` : 'n/a';
    } else {
      ctx.userBalance = 0n;
      if ($$('#sale-balance'))     $$('#sale-balance').textContent     = '— (connect wallet)';
      if ($$('#sale-eth'))         $$('#sale-eth').textContent         = '—';
      if ($$('#sale-flp-balance')) $$('#sale-flp-balance').textContent = '—';
    }
    if ($$('#sale-pool-liq')) {
      const liq = await safe(() => new ethers.Contract(inst.spotPool, POOL_ABI, provider).liquidity(), 0n);
      $$('#sale-pool-liq').textContent = BigInt(liq) === 0n ? 'empty' : BigInt(liq).toString();
    }

    const fillAddr = (id, addr) => {
      const el = document.getElementById(id);
      if (!el) return;
      if (!addr || isZero(addr)) { el.textContent = '—'; return; }
      el.innerHTML = `<a href="${explorerAddr(addr)}" target="_blank" rel="noopener">${addr}</a>`;
    };
    fillAddr('sale-addr-table-sale',   inst.sale);
    fillAddr('sale-addr-table-token',  inst.token);
    fillAddr('sale-addr-table-pool',   inst.spotPool);
    fillAddr('sale-addr-table-seeder', seederAddr);

    updateBuyCost();
    updateSellQuote();
  }

  async function ragequitPerTokenLabel(sale, sym) {
    // Quote for 1 whole token so the per-token rate is comparable to the
    // sale's currentPrice.
    const q = await safe(() => sale.quoteRagequit(1), 0n);
    return q === 0n ? '— (treasury empty)' : `${fmtEth(q)}/${sym}`;
  }

  function renderCompareBanner(salePrice, uniPrice, hasLiq, sym) {
    const el = $$('#trade-compare-banner');
    if (!el) return;
    if (!hasLiq || uniPrice === 0n || salePrice === 0n) { el.hidden = true; return; }

    // Buy side: cheaper of (sale, uniswap) is better.
    // Sell side: ragequit_per_token vs uniswap.
    // Show both: which is cheaper to buy on, and which pays more to sell on.
    const diff = uniPrice > salePrice ? uniPrice - salePrice : salePrice - uniPrice;
    const pct = Number((diff * 10000n) / salePrice) / 100;
    if (pct < 0.5) { el.hidden = true; return; }

    const uniCheaper = uniPrice < salePrice;
    const buyTip  = uniCheaper
      ? `Buying via Uniswap looks <strong>${pct.toFixed(1)}% cheaper</strong> than the sale right now.`
      : `Buying via the sale looks <strong>${pct.toFixed(1)}% cheaper</strong> than Uniswap right now.`;
    el.innerHTML = `<span class="trade-compare-icon">⚠</span> ${buyTip} <span class="trade-compare-sub">(${sym} sale ${fmtEth(salePrice)} · Uniswap ${fmtEth(uniPrice)})</span>`;
    el.hidden = false;
  }

  async function updateBuyCost() {
    const out = $$('#trade-buy-cost');
    if (!out) return;
    const n = parseInt($$('#trade-buy-amount')?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0 || ctx.salePriceWei === 0n) {
      out.textContent = '—'; return;
    }
    out.textContent = fmtEth(ctx.salePriceWei * BigInt(n));
  }

  async function updateSellQuote() {
    const out = $$('#trade-sell-rq-out');
    if (!out || !ctx.inst) return;
    const n = parseInt($$('#trade-sell-amount')?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) { out.textContent = '—'; return; }
    const sale = new ethers.Contract(ctx.inst.sale, SALE_ABI, provider);
    const q = await safe(() => sale.quoteRagequit(n), 0n);
    out.textContent = q === 0n ? '— (treasury empty)' : fmtEth(q);
  }

  // ─── Buy (sale) flow ────────────────────────────────────────────────
  async function onBuyPreview() {
    const inst = ctx.inst;
    if (!inst || !inst.sale) { setStatus('No sale on active instance.', 'error'); return; }

    const n = parseInt($$('#trade-buy-amount')?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) { setStatus('Enter a positive whole number.', 'error'); return; }

    try {
      if (!window.activeSigner) { setStatus('Connecting wallet…', 'pending'); await window.connectWallet(); }

      const sale = new ethers.Contract(inst.sale, SALE_ABI, provider);
      const priceWei = await sale.currentPriceWeiPerToken();
      const cost = BigInt(priceWei) * BigInt(n);

      showConfirmCard('buy', [
        { label: 'Action', value: 'Buy via sale' },
        { label: 'Buy',    value: `${n} ${ctx.sym}` },
        { label: 'Pay',    value: fmtEth(cost) },
        { label: 'Sale',   value: inst.sale },
        { label: 'Receive at', value: window.connectedWallet || '—' },
      ]);
      setStatus('Review the summary, then confirm in your wallet.', 'pending');
    } catch (e) {
      console.error(e);
      setStatus(`Buy preview failed: ${e?.shortMessage || e?.message || e}`, 'error');
    }
  }

  // ─── Ragequit flow ──────────────────────────────────────────────────
  async function onRagequitPreview() {
    const inst = ctx.inst;
    if (!inst || !inst.sale) { setStatus('No sale on active instance.', 'error'); return; }

    const n = parseInt($$('#trade-sell-amount')?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) { setStatus('Enter a positive whole number.', 'error'); return; }

    try {
      if (!window.activeSigner) { setStatus('Connecting wallet…', 'pending'); await window.connectWallet(); }

      const sale = new ethers.Contract(inst.sale, SALE_ABI, provider);
      const ethOut = await sale.quoteRagequit(n);

      showConfirmCard('ragequit', [
        { label: 'Action',  value: 'Ragequit' },
        { label: 'Burn',    value: `${n} ${ctx.sym}` },
        { label: 'You get', value: fmtEth(ethOut) },
        { label: 'Plus',    value: 'pro-rata fLP and any treasury ERC20s' },
        { label: 'Sale',    value: inst.sale },
        { label: 'To',      value: window.connectedWallet || '—' },
      ]);
      setStatus('Review the summary. We\'ll request token approval, then ragequit.', 'pending');
    } catch (e) {
      console.error(e);
      setStatus(`Ragequit preview failed: ${e?.shortMessage || e?.message || e}`, 'error');
    }
  }

  // ─── Confirm execute (dispatch by action) ───────────────────────────
  async function onConfirmExecute() {
    if (!ctx.confirmAction) return;
    const goBtn = $$('#sale-confirm-go');
    const cancelBtn = $$('#sale-confirm-cancel');
    if (goBtn) goBtn.disabled = true;
    if (cancelBtn) cancelBtn.disabled = true;

    try {
      if (ctx.confirmAction === 'buy')           await executeBuy();
      else if (ctx.confirmAction === 'ragequit') await executeRagequit();
    } catch (e) {
      console.error(e);
      setStatus(`Failed: ${e?.shortMessage || e?.message || e}`, 'error');
    } finally {
      if (goBtn) goBtn.disabled = false;
      if (cancelBtn) cancelBtn.disabled = false;
    }
  }

  async function executeBuy() {
    const inst = ctx.inst;
    const n = parseInt($$('#trade-buy-amount').value, 10);
    const signer = window.activeSigner || (await window.connectWallet());

    const saleR = new ethers.Contract(inst.sale, SALE_ABI, provider);
    const priceWei = await saleR.currentPriceWeiPerToken();
    const cost = BigInt(priceWei) * BigInt(n);

    setStatus(`Waiting for wallet approval · ${fmtEth(cost)}…`, 'pending');
    const sale = new ethers.Contract(inst.sale, SALE_ABI, signer);
    const tx = await sale.buy(n, { value: cost });
    setStatus('Mining…', 'pending');
    await tx.wait();
    setStatus(`Bought ${n} ${ctx.sym} for ${fmtEthShort(cost)} ✓`, 'ok');
    closeConfirmCard();
    await refresh();
  }

  async function executeRagequit() {
    const inst = ctx.inst;
    const n = parseInt($$('#trade-sell-amount').value, 10);
    const signer = window.activeSigner || (await window.connectWallet());
    const wallet = window.connectedWallet;

    const burnAmount = BigInt(n) * 10n ** 18n;
    const tokenR = new ethers.Contract(inst.token, ERC20_ABI, provider);
    const allowance = BigInt(await tokenR.allowance(wallet, inst.sale));
    if (allowance < burnAmount) {
      setStatus('Approving token spend…', 'pending');
      const tokenSigner = new ethers.Contract(inst.token, ERC20_ABI, signer);
      const txA = await tokenSigner.approve(inst.sale, burnAmount);
      await txA.wait();
    }

    setStatus(`Burning ${n} ${ctx.sym}…`, 'pending');
    const sale = new ethers.Contract(inst.sale, SALE_ABI, signer);
    const txR = await sale.ragequit(n);
    await txR.wait();
    setStatus(`Burned ${n} ${ctx.sym}; treasury share sent to your wallet ✓`, 'ok');
    closeConfirmCard();
    await refresh();
  }

  // ─── Empty state ────────────────────────────────────────────────────
  function renderNoSale(reason) {
    const root = $$('.sale-page');
    if (!root) return;
    root.innerHTML = `
      <div class="sale-empty-card">
        <h2>No sale on this futarchy.</h2>
        <p>${reason}</p>
        <p><a class="btn btn-primary" href="./">← Browse futarchies</a></p>
      </div>
    `;
  }
})();
