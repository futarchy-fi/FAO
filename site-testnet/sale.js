/* FAO v0 testnet — Buy panel (multi-instance aware).
 *
 * Reads `window.activeInstance` (published by registry.js) and renders the
 * active instance's sale: its current price, raised amount, phase, your
 * balance. Lets a connected wallet call `buy(numTokens) {value: cost}`.
 *
 * Supports two on-chain sale shapes:
 *   - FAOSale (the bootstrap FAO sale) — uses `saleStart() / initialPhaseEnd()`
 *     mutable storage and a fixed 1e14 initial price.
 *   - InstanceSale (v3 per-instance sale) — uses `SALE_START() / INITIAL_PHASE_END()`
 *     immutables and a per-deploy initial price.
 *
 * The ABI below lists every selector either contract exposes; each individual
 * `cast call` is wrapped in `safe()` so missing functions don't throw.
 *
 * Uses ethers.js v6 (loaded by index.html before this script).
 */

(() => {
  'use strict';

  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const SEPOLIA_CHAIN_ID = 11155111n;
  const REFRESH_INTERVAL = 30_000;
  const ZERO = '0x0000000000000000000000000000000000000000';

  const SALE_ABI = [
    // common to both
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
    'function totalSaleTokens() view returns (uint256)',
    // InstanceSale (v3) flavour — immutable auto-getters
    'function SALE_START() view returns (uint256)',
    'function INITIAL_PHASE_END() view returns (uint256)',
  ];

  const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function symbol() view returns (string)',
  ];

  const $$ = (sel, root = document) => root.querySelector(sel);

  const fmtEth   = (wei) => `${(+ethers.formatEther(wei)).toFixed(6)} ETH`;
  const fmtToken = (units, sym) => `${(+ethers.formatUnits(units, 18)).toFixed(2)} ${sym}`;
  const fmtAddr  = (a) => (!a || a === ZERO) ? '—' : `${a.slice(0, 6)}…${a.slice(-4)}`;

  function explorerAddr(addr) { return `https://sepolia.etherscan.io/address/${addr}`; }

  async function safe(fn, fallback) { try { return await fn(); } catch (_) { return fallback; } }

  let provider;
  let userAddress = null;
  let refreshTimer = null;

  function currentInstance() {
    return window.activeInstance || null;
  }

  function saleAddress(inst) {
    return inst && inst.sale && inst.sale !== ZERO ? inst.sale : null;
  }

  function tokenAddress(inst) {
    return inst && inst.token && inst.token !== ZERO ? inst.token : null;
  }

  async function init() {
    provider = new ethers.JsonRpcProvider(RPC);

    wireControls();

    // Re-render whenever registry.js publishes a new active instance.
    window.addEventListener('fao:activeInstanceChanged', () => {
      refresh().catch((e) => console.error('[sale] refresh failed', e));
    });

    await refresh();
    refreshTimer = setInterval(() => {
      refresh().catch((e) => console.error('[sale] refresh failed', e));
    }, REFRESH_INTERVAL);
  }

  function renderNoSale(reason) {
    const box = $$('#sale-box');
    if (!box) return;
    box.innerHTML = `
      <p class="sale-empty">No sale attached to this instance.</p>
      ${reason ? `<p class="sale-note"><span class="sale-mono">${reason}</span></p>` : ''}
    `;
  }

  function rebuildSaleBox() {
    // The picker may have replaced #sale-box innerHTML during a "no sale"
    // render. Restore the full markup if any of the named cells are missing.
    if ($$('#sale-buy')) return;
    const box = $$('#sale-box');
    if (!box) return;
    box.innerHTML = `
      <div class="sale-grid">
        <div class="sale-row"><span class="sale-label">Sale contract</span><span class="sale-value" id="sale-addr">…</span></div>
        <div class="sale-row"><span class="sale-label">Token</span><span class="sale-value" id="sale-token">…</span></div>
        <div class="sale-row"><span class="sale-label">Phase</span><span class="sale-value" id="sale-phase">…</span></div>
        <div class="sale-row"><span class="sale-label">Current price</span><span class="sale-value" id="sale-price">…</span></div>
        <div class="sale-row"><span class="sale-label">Total raised</span><span class="sale-value" id="sale-raised">…</span></div>
        <div class="sale-row"><span class="sale-label">Initial-phase sold</span><span class="sale-value" id="sale-initial-sold">…</span></div>
        <div class="sale-row"><span class="sale-label">Bonding-curve sold</span><span class="sale-value" id="sale-curve-sold">…</span></div>
        <div class="sale-row"><span class="sale-label">Initial phase ends</span><span class="sale-value" id="sale-phase-end">…</span></div>
        <div class="sale-row"><span class="sale-label">Your token balance</span><span class="sale-value" id="sale-balance">— (connect wallet)</span></div>
        <div class="sale-row"><span class="sale-label">Your ETH balance</span><span class="sale-value" id="sale-eth">—</span></div>
        <div class="sale-row"><span class="sale-label">Remaining initial-phase capacity</span><span class="sale-value" id="sale-remaining">—</span></div>
      </div>

      <div class="sale-form">
        <button id="sale-connect" class="btn btn-secondary" type="button">Connect wallet</button>
        <label class="sale-input-wrap">
          <span class="sale-input-label">How many tokens to buy</span>
          <input id="sale-input" type="number" min="1" step="1" value="1" />
        </label>
        <div class="sale-cost-line">
          Cost: <span id="sale-cost">—</span>
        </div>
        <button id="sale-buy" class="btn btn-primary" type="button">Buy</button>
      </div>
    `;
    // Re-bind the controls to the freshly-rebuilt elements.
    wireControls();
  }

  function wireControls() {
    const btnConnect = $$('#sale-connect');
    const btnBuy = $$('#sale-buy');
    const input = $$('#sale-input');
    if (!btnConnect || !btnBuy || !input) return;
    btnConnect.addEventListener('click', onConnect);
    btnBuy.addEventListener('click', onBuy);
    input.addEventListener('input', updateCostPreview);
  }

  async function onConnect() {
    if (!window.ethereum) {
      alert('No injected wallet (MetaMask / Rabby) found.');
      return;
    }
    try {
      const accounts = await window.ethereum.request({ method: 'eth_requestAccounts' });
      userAddress = accounts[0];
      const cid = await window.ethereum.request({ method: 'eth_chainId' });
      if (BigInt(cid) !== SEPOLIA_CHAIN_ID) {
        try {
          await window.ethereum.request({
            method: 'wallet_switchEthereumChain',
            params: [{ chainId: '0xaa36a7' }],
          });
        } catch (_) {
          alert('Please switch wallet to Sepolia (chainId 11155111).');
          return;
        }
      }
      const btn = $$('#sale-connect');
      if (btn) btn.textContent = fmtAddr(userAddress);
      await refresh();
    } catch (e) {
      console.error(e);
      alert('Connect failed: ' + (e && e.message ? e.message : e));
    }
  }

  async function onBuy() {
    const inst = currentInstance();
    const sAddr = saleAddress(inst);
    if (!sAddr) { alert('No sale on active instance.'); return; }
    if (!window.ethereum || !userAddress) { alert('Connect a wallet first.'); return; }

    const n = parseInt($$('#sale-input').value, 10);
    if (!Number.isFinite(n) || n <= 0) {
      alert('Enter a positive whole number of tokens.');
      return;
    }

    const browserProvider = new ethers.BrowserProvider(window.ethereum, 'any');
    const signer = await browserProvider.getSigner();
    const sale = new ethers.Contract(sAddr, SALE_ABI, signer);

    const priceWei = await sale.currentPriceWeiPerToken();
    const cost = priceWei * BigInt(n);

    const btn = $$('#sale-buy');
    btn.disabled = true;
    btn.textContent = 'Confirming…';
    try {
      const tx = await sale.buy(n, { value: cost });
      btn.textContent = 'Mining…';
      await tx.wait();
      btn.textContent = 'Bought ✓';
      setTimeout(() => { btn.textContent = 'Buy'; btn.disabled = false; }, 4000);
      await refresh();
    } catch (e) {
      console.error(e);
      btn.textContent = 'Buy';
      btn.disabled = false;
      alert('Buy failed: ' + (e && (e.shortMessage || e.message) ? (e.shortMessage || e.message) : e));
    }
  }

  async function updateCostPreview() {
    const out = $$('#sale-cost');
    if (!out) return;
    const inst = currentInstance();
    const sAddr = saleAddress(inst);
    if (!sAddr) { out.textContent = '—'; return; }
    const n = parseInt($$('#sale-input').value, 10);
    if (!Number.isFinite(n) || n <= 0) { out.textContent = '—'; return; }

    const sale = new ethers.Contract(sAddr, SALE_ABI, provider);
    const priceWei = await safe(() => sale.currentPriceWeiPerToken(), 0n);
    if (priceWei === 0n) { out.textContent = '—'; return; }
    out.textContent = fmtEth(priceWei * BigInt(n));
  }

  async function refresh() {
    const inst = currentInstance();
    const sAddr = saleAddress(inst);
    const tAddr = tokenAddress(inst);

    if (!sAddr) {
      renderNoSale(inst ? `Instance "${inst.name || inst.symbol || inst.id}" has no sale.` : 'No active instance yet.');
      return;
    }

    rebuildSaleBox();

    // Sanity: address has code.
    const code = await safe(() => provider.getCode(sAddr), '0x');
    if (!code || code === '0x') {
      renderNoSale(`Sale address ${sAddr} has no code on Sepolia.`);
      return;
    }

    const sale = new ethers.Contract(sAddr, SALE_ABI, provider);
    const token = tAddr ? new ethers.Contract(tAddr, ERC20_ABI, provider) : null;

    const [
      saleStart, phaseEnd, finalized,
      priceWei, minInitial, initialSold, curveSold, totalRaised,
      tokenSymbol,
    ] = await Promise.all([
      // SALE_START (InstanceSale) → fall back to saleStart() (FAOSale).
      safe(async () => await sale.SALE_START(), null).then(v => v ?? safe(() => sale.saleStart(), 0n)),
      safe(async () => await sale.INITIAL_PHASE_END(), null).then(v => v ?? safe(() => sale.initialPhaseEnd(), 0n)),
      safe(() => sale.initialPhaseFinalized(), false),
      safe(() => sale.currentPriceWeiPerToken(), 0n),
      safe(() => sale.MIN_INITIAL_PHASE_SOLD(), 0n),
      safe(() => sale.initialTokensSold(), 0n),
      safe(() => sale.totalCurveTokensSold(), 0n),
      safe(() => sale.totalAmountRaised(), 0n),
      token ? safe(() => token.symbol(), inst.symbol || 'TKN') : Promise.resolve(inst?.symbol || 'TKN'),
    ]);

    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    const saleStartBn = BigInt(saleStart ?? 0n);
    const phaseEndBn  = BigInt(phaseEnd ?? 0n);
    let phase;
    if (saleStartBn === 0n) phase = 'not started';
    else if (finalized) phase = 'bonding curve';
    else if (nowSec >= phaseEndBn) phase = 'initial phase (ended, awaiting next buy to finalize)';
    else phase = 'initial fixed-price phase';

    const sym = tokenSymbol || inst?.symbol || 'TKN';

    if ($$('#sale-addr'))         $$('#sale-addr').innerHTML  = `<a href="${explorerAddr(sAddr)}" target="_blank" rel="noopener">${fmtAddr(sAddr)}</a>`;
    if ($$('#sale-token'))        $$('#sale-token').innerHTML = tAddr ? `<a href="${explorerAddr(tAddr)}" target="_blank" rel="noopener">${sym}</a>` : sym;
    if ($$('#sale-phase'))        $$('#sale-phase').textContent = phase;
    if ($$('#sale-price'))        $$('#sale-price').textContent = priceWei === 0n ? '—' : `${fmtEth(priceWei)} / ${sym}`;
    if ($$('#sale-raised'))       $$('#sale-raised').textContent = fmtEth(totalRaised);
    if ($$('#sale-initial-sold')) $$('#sale-initial-sold').textContent = `${initialSold.toString()} / ${minInitial.toString()} ${sym} (cap for initial phase)`;
    if ($$('#sale-curve-sold'))   $$('#sale-curve-sold').textContent = `${curveSold.toString()} ${sym}`;
    if ($$('#sale-phase-end'))    $$('#sale-phase-end').textContent = phaseEndBn === 0n ? '—' : new Date(Number(phaseEndBn) * 1000).toLocaleString();

    if (userAddress && token) {
      const [bal, ethBal] = await Promise.all([
        safe(() => token.balanceOf(userAddress), 0n),
        safe(() => provider.getBalance(userAddress), 0n),
      ]);
      if ($$('#sale-balance')) $$('#sale-balance').textContent = fmtToken(bal, sym);
      if ($$('#sale-eth'))     $$('#sale-eth').textContent = fmtEth(ethBal);

      if (!finalized && saleStartBn !== 0n) {
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

    await updateCostPreview();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
