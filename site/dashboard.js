/* FAO Dashboard — On-chain data fetcher (ethers.js v6) */

(() => {
  'use strict';

  const RPC = 'https://rpc.gnosischain.com';
  const REFRESH_INTERVAL = 60_000;

  const ADDRS = {
    token:    '0x9494C281a02c9ae5f72b224B514793ad2DD8cA17',
    sale:     '0x38FF65E8839B581b5ad12383d93206AFcF38D4b2',
    liqMgr:   '0x9D7692738a4d323338b9007d65d7F79e013B3476',
    proposal: '0x638A32b9EF2588CEcDf148135899Acc882aA1CC2',
  };

  /* ── ABI Fragments ── */

  const TOKEN_ABI = [
    'function name() view returns (string)',
    'function symbol() view returns (string)',
    'function decimals() view returns (uint8)',
    'function totalSupply() view returns (uint256)',
    'function balanceOf(address) view returns (uint256)',
  ];

  const SALE_ABI = [
    'function saleStart() view returns (uint256)',
    'function initialPhaseEnd() view returns (uint256)',
    'function initialPhaseFinalized() view returns (bool)',
    'function initialTokensSold() view returns (uint256)',
    'function totalCurveTokensSold() view returns (uint256)',
    'function initialFundsRaised() view returns (uint256)',
    'function totalCurveFundsRaised() view returns (uint256)',
    'function totalAmountRaised() view returns (uint256)',
    'function totalSaleTokens() view returns (uint256)',
    'function currentPriceWeiPerToken() view returns (uint256)',
    'function longTargetReachedAt() view returns (uint256)',
    'function INITIAL_PRICE_WEI_PER_TOKEN() view returns (uint256)',
  ];

  const LIQ_ABI = [
    'function inConditionalMode() view returns (bool)',
    'function spotLiquidity() view returns (uint128)',
    'function conditionalLiquidity() view returns (uint128)',
    'function totalManagedLiquidity() view returns (uint256)',
    'function totalSupply() view returns (uint256)',
    'function activeProposalId() view returns (uint256)',
    'function emergencyExitExecuted() view returns (bool)',
    'function emergencyExitReady() view returns (bool)',
    'function initializedFromSale() view returns (bool)',
  ];

  /* ── Helpers ── */

  function setField(id, value, isError) {
    const el = document.querySelector(`[data-field="${id}"]`);
    if (!el) return;
    el.textContent = value;
    el.classList.remove('loading', 'error');
    if (isError) el.classList.add('error');
  }

  function setLoading(ids) {
    ids.forEach(id => {
      const el = document.querySelector(`[data-field="${id}"]`);
      if (el) {
        el.textContent = '...';
        el.classList.add('loading');
        el.classList.remove('error');
      }
    });
  }

  function formatTokens(raw, decimals) {
    if (decimals == null) decimals = 18;
    const str = ethers.formatUnits(raw, decimals);
    const num = parseFloat(str);
    if (num >= 1_000_000) return (num / 1_000_000).toFixed(2) + 'M';
    if (num >= 1_000) return (num / 1_000).toFixed(2) + 'K';
    return num.toFixed(2);
  }

  function formatEth(raw) {
    const str = ethers.formatEther(raw);
    const num = parseFloat(str);
    if (num >= 1_000) return num.toFixed(2) + ' xDAI';
    if (num >= 1) return num.toFixed(4) + ' xDAI';
    return num.toFixed(6) + ' xDAI';
  }

  function formatPrice(raw) {
    const str = ethers.formatEther(raw);
    const num = parseFloat(str);
    return num.toFixed(6) + ' xDAI';
  }

  function setDotStatus(panelId, stale) {
    const dot = document.querySelector(`#${panelId} .live-dot`);
    if (dot) dot.classList.toggle('stale', !!stale);
  }

  /* ── Provider & Contracts ── */

  let provider, token, sale, liqMgr;
  let lastSuccess = {};

  function init() {
    if (typeof ethers === 'undefined') {
      console.error('ethers.js not loaded');
      return;
    }
    provider = new ethers.JsonRpcProvider(RPC);
    token = new ethers.Contract(ADDRS.token, TOKEN_ABI, provider);
    sale = new ethers.Contract(ADDRS.sale, SALE_ABI, provider);
    liqMgr = new ethers.Contract(ADDRS.liqMgr, LIQ_ABI, provider);
  }

  /* ── Fetchers ── */

  async function fetchToken() {
    const fields = ['token-name', 'token-symbol', 'token-supply', 'token-decimals', 'token-sale-balance', 'token-lp-balance'];
    setLoading(fields);
    try {
      const [name, symbol, decimals, supply, saleBal, lpBal] = await Promise.all([
        token.name(),
        token.symbol(),
        token.decimals(),
        token.totalSupply(),
        token.balanceOf(ADDRS.sale),
        token.balanceOf(ADDRS.liqMgr),
      ]);

      const dec = Number(decimals);
      setField('token-name', name);
      setField('token-symbol', symbol);
      setField('token-decimals', String(dec));
      setField('token-supply', formatTokens(supply, dec) + ' ' + symbol);
      setField('token-sale-balance', formatTokens(saleBal, dec));
      setField('token-lp-balance', formatTokens(lpBal, dec));
      setDotStatus('panel-token', false);
      lastSuccess.token = Date.now();
    } catch (e) {
      console.error('Token fetch error:', e);
      fields.forEach(f => setField(f, lastSuccess.token ? '(stale)' : 'error', true));
      setDotStatus('panel-token', true);
    }
  }

  async function fetchSale() {
    const fields = [
      'sale-phase', 'sale-price', 'sale-initial-sold', 'sale-curve-sold',
      'sale-total-raised', 'sale-initial-raised', 'sale-curve-raised',
      'sale-total-alloc', 'sale-start-price',
    ];
    setLoading(fields);
    try {
      const [
        saleStart, initialEnd, finalized,
        initialSold, curveSold,
        initialRaised, curveRaised, totalRaised,
        totalAlloc, longTarget, initPrice,
      ] = await Promise.all([
        sale.saleStart(),
        sale.initialPhaseEnd(),
        sale.initialPhaseFinalized(),
        sale.initialTokensSold(),
        sale.totalCurveTokensSold(),
        sale.initialFundsRaised(),
        sale.totalCurveFundsRaised(),
        sale.totalAmountRaised(),
        sale.totalSaleTokens(),
        sale.longTargetReachedAt(),
        sale.INITIAL_PRICE_WEI_PER_TOKEN(),
      ]);

      // Determine phase
      let phase;
      const now = Math.floor(Date.now() / 1000);
      const start = Number(saleStart);
      if (start === 0) {
        phase = 'Not Started';
      } else if (!finalized && now < Number(initialEnd)) {
        phase = 'Initial Phase';
      } else if (finalized && Number(longTarget) === 0) {
        phase = 'Bonding Curve';
      } else if (Number(longTarget) > 0) {
        phase = 'Long Target Reached';
      } else {
        phase = 'Initial Phase Ended';
      }

      setField('sale-phase', phase);
      setField('sale-start-price', formatPrice(initPrice));
      setField('sale-initial-sold', formatTokens(initialSold));
      setField('sale-curve-sold', formatTokens(curveSold));
      setField('sale-initial-raised', formatEth(initialRaised));
      setField('sale-curve-raised', formatEth(curveRaised));
      setField('sale-total-raised', formatEth(totalRaised));
      setField('sale-total-alloc', formatTokens(totalAlloc));

      // Current price may revert if sale not started
      try {
        const price = await sale.currentPriceWeiPerToken();
        setField('sale-price', formatPrice(price));
      } catch {
        setField('sale-price', start === 0 ? 'N/A' : 'error', start !== 0);
      }

      setDotStatus('panel-sale', false);
      lastSuccess.sale = Date.now();
    } catch (e) {
      console.error('Sale fetch error:', e);
      fields.forEach(f => setField(f, lastSuccess.sale ? '(stale)' : 'error', true));
      setDotStatus('panel-sale', true);
    }
  }

  async function fetchLiquidity() {
    const fields = [
      'liq-mode', 'liq-initialized', 'liq-spot', 'liq-conditional',
      'liq-total', 'liq-flp-supply', 'liq-proposal-id',
      'liq-emergency', 'liq-emergency-ready',
    ];
    setLoading(fields);
    try {
      const [
        inCond, initialized, spotLiq, condLiq, totalLiq,
        flpSupply, proposalId, emergencyExit, emergencyReady,
      ] = await Promise.all([
        liqMgr.inConditionalMode(),
        liqMgr.initializedFromSale(),
        liqMgr.spotLiquidity(),
        liqMgr.conditionalLiquidity(),
        liqMgr.totalManagedLiquidity(),
        liqMgr.totalSupply(),
        liqMgr.activeProposalId(),
        liqMgr.emergencyExitExecuted(),
        liqMgr.emergencyExitReady(),
      ]);

      setField('liq-mode', inCond ? 'Conditional' : 'Spot');
      setField('liq-initialized', initialized ? 'Yes' : 'No');
      setField('liq-spot', spotLiq.toString());
      setField('liq-conditional', condLiq.toString());
      setField('liq-total', totalLiq.toString());
      setField('liq-flp-supply', formatTokens(flpSupply));
      setField('liq-proposal-id', Number(proposalId) === 0 ? 'None' : '#' + proposalId.toString());
      setField('liq-emergency', emergencyExit ? 'EXECUTED' : 'No');
      setField('liq-emergency-ready', emergencyReady ? 'Ready' : 'Not Armed');

      setDotStatus('panel-liq', false);
      lastSuccess.liq = Date.now();
    } catch (e) {
      console.error('Liquidity fetch error:', e);
      fields.forEach(f => setField(f, lastSuccess.liq ? '(stale)' : 'error', true));
      setDotStatus('panel-liq', true);
    }
  }

  /* ── Refresh Loop ── */

  async function refresh() {
    await Promise.all([fetchToken(), fetchSale(), fetchLiquidity()]);
  }

  function start() {
    init();
    if (!provider) return;
    refresh();
    setInterval(refresh, REFRESH_INTERVAL);
  }

  /* ── Mobile Nav Toggle ── */

  function initNav() {
    const btn = document.querySelector('.nav-hamburger');
    const links = document.querySelector('.nav-links');
    if (btn && links) {
      btn.addEventListener('click', () => links.classList.toggle('open'));
      links.querySelectorAll('a').forEach(a => {
        a.addEventListener('click', () => links.classList.remove('open'));
      });
    }
  }

  /* ── Boot ── */

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', () => { initNav(); start(); });
  } else {
    initNav();
    start();
  }
})();
