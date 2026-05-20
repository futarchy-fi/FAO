/* FAO v0 testnet — Buy FAO panel
 *
 * Reads the deployed FAOSale contract on Sepolia, displays current sale state
 * (phase, price, raised, your balance / remaining initial-phase capacity), and
 * lets a connected wallet call buy(numTokens) {value: cost}.
 *
 * Uses ethers.js v6 (loaded by index.html before this script).
 *
 * IMPORTANT: After running script/DeployFAOSaleSepolia.s.sol, edit SALE_ADDR
 * below with the new FAOSale address and redeploy this static site.
 */

(() => {
  'use strict';

  // === EDIT-AFTER-DEPLOY ===
  // Set to the FAOSale address printed by DeployFAOSaleSepolia.s.sol.
  // Leave as the zero address before deploy — the UI shows a placeholder.
  const SALE_ADDR = '0x0000000000000000000000000000000000000000';
  // =========================

  const FAO_TOKEN_ADDR = '0x43915f98Ce38116a8C93484Dc8c1ba568Cf13E65';
  const RPC = 'https://sepolia.drpc.org';
  const SEPOLIA_CHAIN_ID = 11155111n;
  const REFRESH_INTERVAL = 30_000;
  const ZERO = '0x0000000000000000000000000000000000000000';

  const SALE_ABI = [
    'function INITIAL_PRICE_WEI_PER_TOKEN() view returns (uint256)',
    'function MIN_INITIAL_PHASE_SOLD() view returns (uint256)',
    'function INITIAL_PHASE_DURATION() view returns (uint256)',
    'function saleStart() view returns (uint256)',
    'function initialPhaseEnd() view returns (uint256)',
    'function initialPhaseFinalized() view returns (bool)',
    'function initialTokensSold() view returns (uint256)',
    'function totalCurveTokensSold() view returns (uint256)',
    'function totalSaleTokens() view returns (uint256)',
    'function totalAmountRaised() view returns (uint256)',
    'function currentPriceWeiPerToken() view returns (uint256)',
    'function buy(uint256 numTokens) payable',
  ];

  const ERC20_ABI = [
    'function balanceOf(address) view returns (uint256)',
    'function decimals() view returns (uint8)',
  ];

  const $$ = (sel, root = document) => root.querySelector(sel);

  const fmtEth = (wei) => `${(+ethers.formatEther(wei)).toFixed(6)} ETH`;
  const fmtFao = (units) => `${(+ethers.formatUnits(units, 18)).toFixed(2)} FAO`;
  const fmtAddr = (a) => (!a || a === ZERO) ? '—' : `${a.slice(0, 6)}…${a.slice(-4)}`;

  function explorerAddr(addr) { return `https://sepolia.etherscan.io/address/${addr}`; }

  async function safe(fn, fallback) { try { return await fn(); } catch (_) { return fallback; } }

  let provider;          // read-only JSON-RPC provider
  let userAddress = null; // currently-connected wallet address

  async function init() {
    provider = new ethers.JsonRpcProvider(RPC);

    if (!SALE_ADDR || SALE_ADDR === ZERO) {
      renderNotDeployed();
      return;
    }

    // Verify the configured address actually has code on Sepolia.
    const code = await safe(() => provider.getCode(SALE_ADDR), '0x');
    if (!code || code === '0x') {
      renderNotDeployed(`Address ${SALE_ADDR} has no code on Sepolia.`);
      return;
    }

    wireControls();
    await refresh();
    setInterval(refresh, REFRESH_INTERVAL);
  }

  function renderNotDeployed(reason) {
    const box = $$('#sale-box');
    if (!box) return;
    box.innerHTML = `
      <p class="sale-empty">
        FAOSale not deployed yet on Sepolia.
        ${reason ? `<br><span class="sale-mono">${reason}</span>` : ''}
      </p>
      <p class="sale-note">
        Run <code>script/DeployFAOSaleSepolia.s.sol</code>, then edit
        <code>SALE_ADDR</code> at the top of <code>site-testnet/sale.js</code>
        with the printed address and redeploy this site.
      </p>
    `;
  }

  function wireControls() {
    const btnConnect = $$('#sale-connect');
    const btnBuy = $$('#sale-buy');
    const input = $$('#sale-input');

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
            params: [{ chainId: '0xaa36a7' }], // 11155111
          });
        } catch (_) {
          alert('Please switch wallet to Sepolia (chainId 11155111).');
          return;
        }
      }
      $$('#sale-connect').textContent = fmtAddr(userAddress);
      await refresh();
    } catch (e) {
      console.error(e);
      alert('Connect failed: ' + (e && e.message ? e.message : e));
    }
  }

  async function onBuy() {
    if (!window.ethereum || !userAddress) {
      alert('Connect a wallet first.');
      return;
    }
    const n = parseInt($$('#sale-input').value, 10);
    if (!Number.isFinite(n) || n <= 0) {
      alert('Enter a positive whole number of FAO.');
      return;
    }

    const browserProvider = new ethers.BrowserProvider(window.ethereum);
    const signer = await browserProvider.getSigner();
    const sale = new ethers.Contract(SALE_ADDR, SALE_ABI, signer);

    // Quote the on-chain price at the latest block.
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
      setTimeout(() => { btn.textContent = 'Buy FAO'; btn.disabled = false; }, 4000);
      await refresh();
    } catch (e) {
      console.error(e);
      btn.textContent = 'Buy FAO';
      btn.disabled = false;
      alert('Buy failed: ' + (e && (e.shortMessage || e.message) ? (e.shortMessage || e.message) : e));
    }
  }

  async function updateCostPreview() {
    const out = $$('#sale-cost');
    const n = parseInt($$('#sale-input').value, 10);
    if (!Number.isFinite(n) || n <= 0) { out.textContent = '—'; return; }

    const sale = new ethers.Contract(SALE_ADDR, SALE_ABI, provider);
    const priceWei = await safe(() => sale.currentPriceWeiPerToken(), 0n);
    if (priceWei === 0n) { out.textContent = '—'; return; }
    out.textContent = fmtEth(priceWei * BigInt(n));
  }

  async function refresh() {
    const sale = new ethers.Contract(SALE_ADDR, SALE_ABI, provider);
    const fao = new ethers.Contract(FAO_TOKEN_ADDR, ERC20_ABI, provider);

    const [
      saleStart, phaseEnd, finalized,
      priceWei, minInitial, initialSold, curveSold, totalRaised,
    ] = await Promise.all([
      safe(() => sale.saleStart(), 0n),
      safe(() => sale.initialPhaseEnd(), 0n),
      safe(() => sale.initialPhaseFinalized(), false),
      safe(() => sale.currentPriceWeiPerToken(), 0n),
      safe(() => sale.MIN_INITIAL_PHASE_SOLD(), 0n),
      safe(() => sale.initialTokensSold(), 0n),
      safe(() => sale.totalCurveTokensSold(), 0n),
      safe(() => sale.totalAmountRaised(), 0n),
    ]);

    // Compute current phase label.
    const nowSec = BigInt(Math.floor(Date.now() / 1000));
    let phase;
    if (saleStart === 0n) phase = 'not started';
    else if (finalized) phase = 'bonding curve';
    else if (nowSec >= phaseEnd) phase = 'initial phase (ended, awaiting next buy to finalize)';
    else phase = 'initial fixed-price phase';

    $$('#sale-addr').innerHTML = `<a href="${explorerAddr(SALE_ADDR)}" target="_blank" rel="noopener">${fmtAddr(SALE_ADDR)}</a>`;
    $$('#sale-phase').textContent = phase;
    $$('#sale-price').textContent = priceWei === 0n ? '—' : `${fmtEth(priceWei)} / FAO`;
    $$('#sale-raised').textContent = fmtEth(totalRaised);
    $$('#sale-initial-sold').textContent =
      `${initialSold.toString()} / ${minInitial.toString()} FAO (cap for initial phase)`;
    $$('#sale-curve-sold').textContent = `${curveSold.toString()} FAO`;
    $$('#sale-phase-end').textContent =
      phaseEnd === 0n ? '—' : new Date(Number(phaseEnd) * 1000).toLocaleString();

    if (userAddress) {
      const [bal, ethBal] = await Promise.all([
        safe(() => fao.balanceOf(userAddress), 0n),
        safe(() => provider.getBalance(userAddress), 0n),
      ]);
      $$('#sale-balance').textContent = fmtFao(bal);
      $$('#sale-eth').textContent = fmtEth(ethBal);

      // Remaining initial-phase capacity (only meaningful pre-finalize).
      if (!finalized && saleStart !== 0n) {
        const rem = minInitial > initialSold ? (minInitial - initialSold) : 0n;
        $$('#sale-remaining').textContent = `${rem.toString()} FAO`;
      } else {
        $$('#sale-remaining').textContent = 'n/a (bonding curve)';
      }
    } else {
      $$('#sale-balance').textContent = '— (connect wallet)';
      $$('#sale-eth').textContent = '—';
      $$('#sale-remaining').textContent = '—';
    }

    await updateCostPreview();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', init);
  } else {
    init();
  }
})();
