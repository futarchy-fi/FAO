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
  const WETH = '0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14';
  const UNI_SWAP_URL = 'https://app.uniswap.org/swap';

  // Sepolia Uniswap V3 infra (verified on-chain by deploy script).
  const UNI_SWAP_ROUTER  = '0x3bFA4769FB09eefC5a80d6E87c3B9C650f7Ae48E'; // SwapRouter02
  const UNI_QUOTER       = '0xEd1f6473345F45b75F8179591dd5bA1888cf2FB3'; // QuoterV2
  const UNI_FEE_TIER     = 500; // matches the futarchy's spot pool
  // Slippage tolerance for quoted amounts when sending the swap.
  const UNI_SLIPPAGE_BPS = 50n; // 0.5%

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

  // Uniswap V3 QuoterV2 — same contract app.uniswap.org calls for quotes.
  // `quoteExactInputSingle` is `payable` (non-view) so we always read it via
  // staticCall — the contract internally calls swap on the pool then reverts,
  // bubbling the simulated amountOut back through the revert reason.
  const QUOTER_ABI = [
    'function quoteExactInputSingle((address tokenIn,address tokenOut,uint256 amountIn,uint24 fee,uint160 sqrtPriceLimitX96)) returns (uint256 amountOut,uint160 sqrtPriceX96After,uint32 initializedTicksCrossed,uint256 gasEstimate)',
  ];

  // Uniswap V3 SwapRouter02 — single-hop exactInputSingle + multicall for
  // unwrap on Token→ETH swaps.
  const SWAP_ROUTER_ABI = [
    'function exactInputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountIn,uint256 amountOutMinimum,uint160 sqrtPriceLimitX96)) payable returns (uint256 amountOut)',
    'function exactOutputSingle((address tokenIn,address tokenOut,uint24 fee,address recipient,uint256 amountOut,uint256 amountInMaximum,uint160 sqrtPriceLimitX96)) payable returns (uint256 amountIn)',
    'function unwrapWETH9(uint256 amountMinimum,address recipient) payable',
    'function refundETH() payable',
    'function multicall(bytes[] calldata data) payable returns (bytes[] memory)',
  ];

  // (Router auto-wraps msg.value via WETH9.deposit and auto-unwraps via
  // unwrapWETH9 inside multicall, so we don't need a direct WETH ABI.)

  const $$ = (sel) => document.querySelector(sel);
  const isZero = (a) => !a || a.toLowerCase() === ZERO;
  const fmtEth   = (wei) => `${(+ethers.formatEther(wei)).toFixed(6)} ETH`;
  const fmtEthShort = (wei) => `${(+ethers.formatEther(wei)).toFixed(4)} ETH`;
  const fmtToken = (units, sym) => `${(+ethers.formatUnits(units, 18)).toFixed(2)} ${sym}`;
  const fmtAddr  = (a) => (!a || isZero(a)) ? '—' : `${a.slice(0, 6)}…${a.slice(-4)}`;
  const explorerAddr = (a) => `https://sepolia.etherscan.io/address/${a}`;
  const explorerTx = (h) => `https://sepolia.etherscan.io/tx/${h}`;

  async function safe(fn, fallback) { try { return await fn(); } catch (_) { return fallback; } }

  let provider;
  // Per-refresh cache that the action handlers read so they don't refetch.
  let ctx = {
    inst: null,
    sym: 'TKN',
    salePriceWei: 0n,
    uniBuyPriceWei:  0n,   // ETH cost per 1 token via Uniswap
    uniSellPriceWei: 0n,   // ETH received per 1 token via Uniswap
    poolHasLiquidity: false,
    seederAddr: null,      // first entry of sale.ragequitTokens, if any
    userBalance: 0n,       // token balance of connected wallet
    confirmAction: null,   // 'buy' | 'ragequit' | 'uniBuy' | 'uniSell'
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
    setPrimaryTradeSide('buy');
    if (buyAmt) {
      buyAmt.addEventListener('focus', () => setPrimaryTradeSide('buy'));
      buyAmt.addEventListener('input', () => {
        setPrimaryTradeSide('buy');
        updateBuyCost();
      });
    }
    if (sellAmt) {
      sellAmt.addEventListener('focus', () => setPrimaryTradeSide('sell'));
      sellAmt.addEventListener('input', () => {
        setPrimaryTradeSide('sell');
        updateSellQuote();
      });
    }

    document.querySelectorAll('[data-qb-amt]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (!buyAmt) return;
        setPrimaryTradeSide('buy');
        buyAmt.value = btn.dataset.qbAmt;
        updateBuyCost();
      });
    });
    document.querySelectorAll('[data-qs-pct]').forEach(btn => {
      btn.addEventListener('click', () => {
        if (!sellAmt) return;
        setPrimaryTradeSide('sell');
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
    const uniBuyBtn  = $$('#trade-buy-uni-btn');
    const uniSellBtn = $$('#trade-sell-uni-btn');
    if (buyBtn)     buyBtn.addEventListener('click', () => { setPrimaryTradeSide('buy'); onBuyPreview(); });
    if (sellBtn)    sellBtn.addEventListener('click', () => { setPrimaryTradeSide('sell'); onRagequitPreview(); });
    if (uniBuyBtn)  uniBuyBtn.addEventListener('click', onUniBuyPreview);
    if (uniSellBtn) uniSellBtn.addEventListener('click', onUniSellPreview);

    const cancelBtn = $$('#sale-confirm-cancel');
    const goBtn = $$('#sale-confirm-go');
    if (cancelBtn) cancelBtn.addEventListener('click', closeConfirmCard);
    if (goBtn) goBtn.addEventListener('click', onConfirmExecute);
  }

  function setPrimaryTradeSide(side) {
    const buyBtn = $$('#trade-buy-sale-btn');
    const sellBtn = $$('#trade-sell-rq-btn');
    if (!buyBtn || !sellBtn) return;
    const buyPrimary = side !== 'sell';
    buyBtn.classList.toggle('trade-btn-primary', buyPrimary);
    buyBtn.classList.toggle('trade-btn-secondary', !buyPrimary);
    buyBtn.setAttribute('aria-current', buyPrimary ? 'true' : 'false');
    sellBtn.classList.toggle('trade-btn-primary', !buyPrimary);
    sellBtn.classList.toggle('trade-btn-secondary', buyPrimary);
    sellBtn.setAttribute('aria-current', buyPrimary ? 'false' : 'true');
  }

  function setStatus(text, kind) {
    const el = $$('#sale-buy-status');
    if (!el) return;
    el.textContent = text || '';
    el.className = `sale-buy-status${kind ? ' sale-buy-status-' + kind : ''}`;
  }

  function setTxStatus(text, txHash, kind) {
    const el = $$('#sale-buy-status');
    if (!el) return;
    el.textContent = '';
    el.className = `sale-buy-status${kind ? ' sale-buy-status-' + kind : ''}`;
    el.append(document.createTextNode(`${text} `));
    const link = document.createElement('a');
    link.href = explorerTx(txHash);
    link.target = '_blank';
    link.rel = 'noopener';
    link.textContent = `${txHash.slice(0, 10)}…`;
    el.append(link);
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

  function closeConfirmCard(opts = {}) {
    ctx.confirmAction = null;
    $$('#sale-confirm-card').hidden = true;
    $$('#trade-buy-sale-btn').disabled = false;
    $$('#trade-sell-rq-btn').disabled = false;
    if (!opts.preserveStatus) setStatus('');
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

  // ─── Uniswap V3 quotes ──────────────────────────────────────────────
  // Uses QuoterV2 — the same on-chain quote app.uniswap.org reads. Returns
  // the WETH-out for selling 1 whole token AND the ETH-in for buying 1 whole
  // token. Both quotes account for tick liquidity + the 0.05% fee (we
  // already use fee=500). Pure-view by virtue of staticCall.
  async function getUniSwapQuotes(poolAddr, tokenAddr) {
    const result = {
      priceBuyEthPerToken:  0n, // ETH needed to receive 1 whole token
      priceSellEthPerToken: 0n, // ETH received when selling 1 whole token
      hasLiquidity: false,
    };
    if (!poolAddr || isZero(poolAddr)) return result;

    const pool = new ethers.Contract(poolAddr, POOL_ABI, provider);
    const liq = await safe(() => pool.liquidity(), 0n);
    if (BigInt(liq) === 0n) return result;
    result.hasLiquidity = true;

    const quoter = new ethers.Contract(UNI_QUOTER, QUOTER_ABI, provider);
    const ONE = 10n ** 18n;

    // Sell quote: tokenIn=TOKEN, tokenOut=WETH, amountIn=1e18 → WETH out.
    const sellQuote = await safe(() =>
      quoter.quoteExactInputSingle.staticCall({
        tokenIn: tokenAddr,
        tokenOut: WETH,
        amountIn: ONE,
        fee: UNI_FEE_TIER,
        sqrtPriceLimitX96: 0n,
      }), null);
    if (sellQuote != null) result.priceSellEthPerToken = BigInt(sellQuote[0]);

    // Buy quote: tokenIn=WETH, tokenOut=TOKEN, amountIn=1e18 → TOKEN out.
    // Invert to get ETH-per-token: priceBuy = 1e18 * 1e18 / amountOut.
    const buyQuote = await safe(() =>
      quoter.quoteExactInputSingle.staticCall({
        tokenIn: WETH,
        tokenOut: tokenAddr,
        amountIn: ONE,
        fee: UNI_FEE_TIER,
        sqrtPriceLimitX96: 0n,
      }), null);
    if (buyQuote != null && BigInt(buyQuote[0]) > 0n) {
      result.priceBuyEthPerToken = (ONE * ONE) / BigInt(buyQuote[0]);
    }
    return result;
  }

  // Quote the exact amountOut for a specific size — used by the buy/sell
  // confirm cards. Returns null if the pool can't fill it.
  async function quoteUniswapExactIn(tokenIn, tokenOut, amountIn) {
    if (amountIn === 0n) return null;
    const quoter = new ethers.Contract(UNI_QUOTER, QUOTER_ABI, provider);
    const r = await safe(() =>
      quoter.quoteExactInputSingle.staticCall({
        tokenIn, tokenOut, amountIn,
        fee: UNI_FEE_TIER, sqrtPriceLimitX96: 0n,
      }), null);
    return r == null ? null : BigInt(r[0]);
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

    // Uniswap quotes: separate buy / sell quotes (they differ by 2× the
    // fee + slippage). We display each on its respective column.
    const uniQ = await getUniSwapQuotes(inst.spotPool, inst.token);
    ctx.uniBuyPriceWei  = uniQ.priceBuyEthPerToken;
    ctx.uniSellPriceWei = uniQ.priceSellEthPerToken;
    ctx.poolHasLiquidity = uniQ.hasLiquidity;

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
    // "Thin pool" predicate: a 1-token swap would move the pool price by
    // >5× the sale's reference price. The quoter still returns a number,
    // but it represents extreme slippage rather than the real market.
    const thinBuy  = uniQ.hasLiquidity && uniQ.priceBuyEthPerToken  > ctx.salePriceWei * 5n;
    const thinSell = uniQ.hasLiquidity && uniQ.priceSellEthPerToken * 5n < ctx.salePriceWei;
    if (!uniQ.hasLiquidity) {
      if ($$('#trade-buy-uni-price'))  $$('#trade-buy-uni-price').textContent  = 'no liquidity';
      if ($$('#trade-sell-uni-price')) $$('#trade-sell-uni-price').textContent = 'no liquidity';
    } else {
      if ($$('#trade-buy-uni-price'))  $$('#trade-buy-uni-price').textContent  = thinBuy  ? 'thin pool' : `${fmtEth(uniQ.priceBuyEthPerToken)}/${sym}`;
      if ($$('#trade-sell-uni-price')) $$('#trade-sell-uni-price').textContent = thinSell ? 'thin pool' : `${fmtEth(uniQ.priceSellEthPerToken)}/${sym}`;
    }
    // Disable the inline-swap buttons when the pool has no liquidity OR is
    // too thin to absorb a 1-token trade without absurd slippage.
    if ($$('#trade-buy-uni-btn'))  $$('#trade-buy-uni-btn').disabled  = !uniQ.hasLiquidity || thinBuy;
    if ($$('#trade-sell-uni-btn')) $$('#trade-sell-uni-btn').disabled = !uniQ.hasLiquidity || thinSell;
    // Provide the external Uniswap-UI escape hatch too.
    if ($$('#trade-buy-uni-external'))  $$('#trade-buy-uni-external').href  = `${UNI_SWAP_URL}?inputCurrency=ETH&outputCurrency=${inst.token}&chain=sepolia`;
    if ($$('#trade-sell-uni-external')) $$('#trade-sell-uni-external').href = `${UNI_SWAP_URL}?inputCurrency=${inst.token}&outputCurrency=ETH&chain=sepolia`;

    // Comparison banner ─────────────────────────────────────────────
    renderCompareBanner(salePriceWei, uniQ.priceBuyEthPerToken, uniQ.priceSellEthPerToken, uniQ.hasLiquidity, sym);

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
      el.innerHTML = `<a href="${explorerAddr(addr)}" target="_blank" rel="noopener" title="${addr}">${fmtAddr(addr)}</a>`;
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

  // Banner heuristic: if Uniswap's per-token buy price is more than 5× the
  // sale price (or sell price less than 1/5×), the spot pool is too thin
  // to absorb a 1-token trade — surface that instead of an absurd percent.
  // Same on the sell side. Otherwise show the normal "Uniswap is X% cheaper"
  // line with a hard cap so we never render "201000400% cheaper".
  function renderCompareBanner(salePrice, uniBuyPrice, uniSellPrice, hasLiq, sym) {
    const el = $$('#trade-compare-banner');
    if (!el) return;
    if (!hasLiq || salePrice === 0n || uniBuyPrice === 0n) { el.hidden = true; return; }

    const subline = `<span class="trade-compare-sub">(${sym} sale ${fmtEth(salePrice)} · Uniswap-buy ${fmtEth(uniBuyPrice)} · Uniswap-sell ${fmtEth(uniSellPrice)})</span>`;

    // Thin-pool case: spot pool can't fill a 1-token trade without massive
    // slippage. Skip the per-cent math.
    if (uniBuyPrice > salePrice * 5n || uniSellPrice * 5n < salePrice) {
      el.innerHTML = `<span class="trade-compare-icon">⚠</span> Spot pool is too thin for a 1-${sym} trade — quotes shown reflect heavy slippage. The sale is your reliable buy path; ragequit your reliable sell path. ${subline}`;
      el.hidden = false;
      return;
    }

    const diff = uniBuyPrice > salePrice ? uniBuyPrice - salePrice : salePrice - uniBuyPrice;
    const pctRaw = Number((diff * 10000n) / salePrice) / 100;
    if (pctRaw < 0.5) { el.hidden = true; return; }
    const pct = Math.min(pctRaw, 999.9); // clamp display; thin-pool case above covers >>500%

    const uniCheaper = uniBuyPrice < salePrice;
    const buyTip = uniCheaper
      ? `Buying via Uniswap looks <strong>${pct.toFixed(1)}% cheaper</strong> right now.`
      : `Buying via the sale looks <strong>${pct.toFixed(1)}% cheaper</strong> right now.`;
    el.innerHTML = `<span class="trade-compare-icon">⚠</span> ${buyTip} ${subline}`;
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
      if (ctx.confirmAction === 'buy')            await executeBuy();
      else if (ctx.confirmAction === 'ragequit')  await executeRagequit();
      else if (ctx.confirmAction === 'uniBuy')    await executeUniBuy();
      else if (ctx.confirmAction === 'uniSell')   await executeUniSell();
    } catch (e) {
      console.error(e);
      setStatus(`Failed: ${e?.shortMessage || e?.message || e}`, 'error');
    } finally {
      if (goBtn) goBtn.disabled = false;
      if (cancelBtn) cancelBtn.disabled = false;
    }
  }

  // ─── Uniswap inline swap: Buy (ETH → token) ─────────────────────────
  async function onUniBuyPreview() {
    const inst = ctx.inst;
    if (!ctx.poolHasLiquidity) { setStatus('Spot pool has no liquidity.', 'error'); return; }
    const n = parseInt($$('#trade-buy-amount')?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) { setStatus('Enter a positive whole number.', 'error'); return; }

    try {
      if (!window.activeSigner) { setStatus('Connecting wallet…', 'pending'); await window.connectWallet(); }
      // Quote: how much ETH (= WETH input) do we need to receive n*1e18 tokens?
      // Strategy: estimate `amountIn` via QuoterV2 on tokenOut=n*1e18; if the
      // quoter only supports exactInput we use that and accept a tiny over-pay.
      // Simpler: use the per-token quote scaled by n, with slippage margin.
      const onePerOut = ctx.uniBuyPriceWei; // ETH per whole token
      const expectedIn = onePerOut * BigInt(n);
      const maxIn = (expectedIn * (10000n + UNI_SLIPPAGE_BPS)) / 10000n;

      showConfirmCard('uniBuy', [
        { label: 'Action',         value: 'Buy via Uniswap' },
        { label: 'Buy (target)',   value: `${n} ${ctx.sym}` },
        { label: 'Max ETH in',     value: fmtEth(maxIn) },
        { label: 'Router',         value: UNI_SWAP_ROUTER },
        { label: 'Receive at',     value: window.connectedWallet || '—' },
        { label: 'Slippage',       value: `${Number(UNI_SLIPPAGE_BPS) / 100}%` },
      ]);
      setStatus('Review the summary, then confirm in your wallet.', 'pending');
    } catch (e) {
      console.error(e);
      setStatus(`Uniswap buy preview failed: ${e?.shortMessage || e?.message || e}`, 'error');
    }
  }

  async function executeUniBuy() {
    const inst = ctx.inst;
    const n = parseInt($$('#trade-buy-amount').value, 10);
    const signer = window.activeSigner || (await window.connectWallet());
    const wallet = window.connectedWallet;

    const onePerOut = ctx.uniBuyPriceWei;
    const expectedIn = onePerOut * BigInt(n);
    const maxIn = (expectedIn * (10000n + UNI_SLIPPAGE_BPS)) / 10000n;
    const exactOut = BigInt(n) * 10n ** 18n;

    // SwapRouter02 pattern for "buy exactly N tokens with at most maxIn ETH":
    //   multicall(exactOutputSingle{value: maxIn} + refundETH).
    // The router auto-wraps msg.value to WETH, performs the swap, sends the
    // tokens to `wallet`, and refundETH() returns the unused ETH balance.
    const iface = new ethers.Interface(SWAP_ROUTER_ABI);
    const callSwap = iface.encodeFunctionData('exactOutputSingle', [{
      tokenIn: WETH,
      tokenOut: inst.token,
      fee: UNI_FEE_TIER,
      recipient: wallet,
      amountOut: exactOut,
      amountInMaximum: maxIn,
      sqrtPriceLimitX96: 0n,
    }]);
    const callRefund = iface.encodeFunctionData('refundETH', []);

    setStatus(`Waiting for wallet approval · up to ${fmtEth(maxIn)} for exactly ${n} ${ctx.sym}…`, 'pending');
    const router = new ethers.Contract(UNI_SWAP_ROUTER, SWAP_ROUTER_ABI, signer);
    const tx = await router.multicall([callSwap, callRefund], { value: maxIn });
    setTxStatus('Mining Uniswap buy tx', tx.hash, 'pending');
    await tx.wait();
    setTxStatus(`Bought ${n} ${ctx.sym} via Uniswap; unused ETH refunded`, tx.hash, 'ok');
    closeConfirmCard({ preserveStatus: true });
    await refresh();
  }

  // ─── Uniswap inline swap: Sell (token → ETH via multicall + unwrap) ─
  async function onUniSellPreview() {
    const inst = ctx.inst;
    if (!ctx.poolHasLiquidity) { setStatus('Spot pool has no liquidity.', 'error'); return; }
    const n = parseInt($$('#trade-sell-amount')?.value || '', 10);
    if (!Number.isFinite(n) || n <= 0) { setStatus('Enter a positive whole number.', 'error'); return; }

    try {
      if (!window.activeSigner) { setStatus('Connecting wallet…', 'pending'); await window.connectWallet(); }
      const amountIn = BigInt(n) * 10n ** 18n;
      const expectedOut = await quoteUniswapExactIn(inst.token, WETH, amountIn);
      const minOut = expectedOut == null
        ? 0n
        : (expectedOut * (10000n - UNI_SLIPPAGE_BPS)) / 10000n;

      showConfirmCard('uniSell', [
        { label: 'Action',     value: 'Sell via Uniswap' },
        { label: 'Sell',       value: `${n} ${ctx.sym}` },
        { label: 'Expected',   value: expectedOut == null ? '—' : fmtEth(expectedOut) },
        { label: 'Min ETH out',value: fmtEth(minOut) },
        { label: 'Router',     value: UNI_SWAP_ROUTER },
        { label: 'Receive at', value: window.connectedWallet || '—' },
        { label: 'Slippage',   value: `${Number(UNI_SLIPPAGE_BPS) / 100}%` },
      ]);
      setStatus('Review the summary. We\'ll request token approval, then swap + unwrap.', 'pending');
    } catch (e) {
      console.error(e);
      setStatus(`Uniswap sell preview failed: ${e?.shortMessage || e?.message || e}`, 'error');
    }
  }

  async function executeUniSell() {
    const inst = ctx.inst;
    const n = parseInt($$('#trade-sell-amount').value, 10);
    const signer = window.activeSigner || (await window.connectWallet());
    const wallet = window.connectedWallet;

    const amountIn = BigInt(n) * 10n ** 18n;

    // Approve router to spend our tokens if needed.
    const tokenR = new ethers.Contract(inst.token, ERC20_ABI, provider);
    const allowance = BigInt(await tokenR.allowance(wallet, UNI_SWAP_ROUTER));
    if (allowance < amountIn) {
      setStatus('Approving token spend…', 'pending');
      const tokenSigner = new ethers.Contract(inst.token, ERC20_ABI, signer);
      const txA = await tokenSigner.approve(UNI_SWAP_ROUTER, amountIn);
      await txA.wait();
    }

    const expectedOut = await quoteUniswapExactIn(inst.token, WETH, amountIn);
    const minOut = expectedOut == null ? 0n : (expectedOut * (10000n - UNI_SLIPPAGE_BPS)) / 10000n;

    // multicall: exactInputSingle(tokenIn=TOKEN, tokenOut=WETH, recipient=router)
    //          + unwrapWETH9(minOut, recipient=wallet)
    const router = new ethers.Contract(UNI_SWAP_ROUTER, SWAP_ROUTER_ABI, signer);
    const iface = new ethers.Interface(SWAP_ROUTER_ABI);
    const callSwap = iface.encodeFunctionData('exactInputSingle', [{
      tokenIn: inst.token,
      tokenOut: WETH,
      fee: UNI_FEE_TIER,
      recipient: UNI_SWAP_ROUTER, // router holds the WETH after swap
      amountIn,
      amountOutMinimum: minOut,
      sqrtPriceLimitX96: 0n,
    }]);
    const callUnwrap = iface.encodeFunctionData('unwrapWETH9', [minOut, wallet]);

    setStatus(`Waiting for wallet approval · expect ${expectedOut == null ? '—' : fmtEth(expectedOut)}…`, 'pending');
    const tx = await router.multicall([callSwap, callUnwrap]);
    setTxStatus('Mining Uniswap sell tx', tx.hash, 'pending');
    await tx.wait();
    setTxStatus(`Sold ${n} ${ctx.sym} via Uniswap`, tx.hash, 'ok');
    closeConfirmCard({ preserveStatus: true });
    await refresh();
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
    setTxStatus('Mining sale buy tx', tx.hash, 'pending');
    await tx.wait();
    setTxStatus(`Bought ${n} ${ctx.sym} for ${fmtEthShort(cost)}`, tx.hash, 'ok');
    closeConfirmCard({ preserveStatus: true });
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
    setTxStatus('Mining ragequit tx', txR.hash, 'pending');
    await txR.wait();
    setTxStatus(`Burned ${n} ${ctx.sym}; treasury share sent to your wallet`, txR.hash, 'ok');
    closeConfirmCard({ preserveStatus: true });
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
