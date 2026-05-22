/* home.js — rankings table + stack live stats for the Home page. */

(() => {
  'use strict';

  const RPC = 'https://ethereum-sepolia.publicnode.com';
  const REFRESH_INTERVAL = 30_000;
  const ZERO = '0x0000000000000000000000000000000000000000';

  // The Live stats panel reads from whichever instance is currently active.
  // No hardcoded factory/resolver/orchestrator — each instance brings its own
  // and shared.js publishes the addresses on window.activeInstance.
  const OPERATOR = '0x693E3FB46Bb36eE43C702FE94f9463df0691b43d';

  const SALE_ABI = [
    'function totalAmountRaised() view returns (uint256)',
    'function currentPriceWeiPerToken() view returns (uint256)',
    'function initialPhaseFinalized() view returns (bool)',
    'function SALE_START() view returns (uint256)',
    'function INITIAL_PHASE_END() view returns (uint256)',
    'function saleStart() view returns (uint256)',
    'function initialPhaseEnd() view returns (uint256)',
  ];
  const TOKEN_ABI    = ['function totalSupply() view returns (uint256)'];
  const FACTORY_ABI  = ['function marketsCount() view returns (uint256)'];
  const RESOLVER_ABI = ['function orchestrator() view returns (address)'];

  const $$ = (sel, root = document) => root.querySelector(sel);
  const isZero = (a) => !a || a.toLowerCase() === ZERO;
  const escapeHtml = (s) => String(s ?? '').replace(/[&<>"']/g, c => ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;' }[c]));
  const fmtAddr = (a) => (!a || isZero(a)) ? '—' : `${a.slice(0, 6)}…${a.slice(-4)}`;
  async function safe(fn, fallback) { try { return await fn(); } catch (_) { return fallback; } }

  let provider;
  let rankSortKey = 'mcap';
  let rankFilter = 'all';

  // ─── Boot ────────────────────────────────────────────────────────────
  function start() {
    provider = new ethers.JsonRpcProvider(RPC);
    wireRankingsControls();
    refreshAll();
    setInterval(refreshAll, REFRESH_INTERVAL);
    window.addEventListener('fao:activeInstanceChanged', renderRankings);
  }

  if (window.allInstances) start();
  else window.addEventListener('fao:sharedReady', start, { once: true });

  // ─── Rankings ─────────────────────────────────────────────────────────
  async function loadSaleMetrics() {
    const list = window.allInstances || [];
    await Promise.all(list.map(async (inst) => {
      if (!inst.sale || isZero(inst.sale) || !inst.token) {
        inst.raisedWei = inst.mcapWei = inst.priceWei = inst.supplyWei = null;
        inst.salePhase = null;
        return;
      }
      const sale = new ethers.Contract(inst.sale, SALE_ABI, provider);
      const token = new ethers.Contract(inst.token, TOKEN_ABI, provider);
      const [raised, supply, price, finalized, phaseEndImm, phaseEndMut, saleStartImm, saleStartMut] = await Promise.all([
        safe(() => sale.totalAmountRaised(), null),
        safe(() => token.totalSupply(), null),
        safe(() => sale.currentPriceWeiPerToken(), null),
        safe(() => sale.initialPhaseFinalized(), null),
        safe(() => sale.INITIAL_PHASE_END(), null),
        safe(() => sale.initialPhaseEnd(), null),
        safe(() => sale.SALE_START(), null),
        safe(() => sale.saleStart(), null),
      ]);
      inst.raisedWei = raised == null ? null : BigInt(raised);
      inst.supplyWei = supply == null ? null : BigInt(supply);
      inst.priceWei  = price  == null ? null : BigInt(price);
      inst.mcapWei   = (supply != null && price != null) ? (BigInt(supply) * BigInt(price)) / 10n ** 18n : null;

      const phaseEnd  = phaseEndImm  != null ? BigInt(phaseEndImm)  : (phaseEndMut  != null ? BigInt(phaseEndMut)  : 0n);
      const saleStart = saleStartImm != null ? BigInt(saleStartImm) : (saleStartMut != null ? BigInt(saleStartMut) : 0n);
      const now = BigInt(Math.floor(Date.now() / 1000));
      if (saleStart === 0n)         inst.salePhase = 'not-started';
      else if (finalized === true)  inst.salePhase = 'bonding-curve';
      else if (phaseEnd && now >= phaseEnd) inst.salePhase = 'phase-ended';
      else                          inst.salePhase = 'initial-sale';
    }));
  }

  function salePhaseBadge(phase) {
    switch (phase) {
      case 'initial-sale':   return { label: 'initial sale',  cls: 'badge-initial' };
      case 'phase-ended':    return { label: 'initial sale',  cls: 'badge-ended' };
      case 'bonding-curve':  return { label: 'bonding curve', cls: 'badge-curve' };
      case 'not-started':    return { label: 'not started',   cls: 'badge-pending' };
      default:               return null;
    }
  }

  function renderRankings() {
    const tbody = $$('#rankings-rows');
    if (!tbody) return;
    const all = window.allInstances || [];
    let visible = all.filter(i => i.sale && !isZero(i.sale));
    if (rankFilter === 'initial-sale')  visible = visible.filter(i => i.salePhase === 'initial-sale' || i.salePhase === 'phase-ended');
    if (rankFilter === 'bonding-curve') visible = visible.filter(i => i.salePhase === 'bonding-curve');

    if (visible.length === 0) {
      tbody.innerHTML = `<tr><td colspan="7" class="rank-empty">No futarchies match this filter.</td></tr>`;
      return;
    }
    const cmp = (a, b) => {
      const ka = a[rankSortKey === 'mcap' ? 'mcapWei' : 'raisedWei'];
      const kb = b[rankSortKey === 'mcap' ? 'mcapWei' : 'raisedWei'];
      if (ka == null && kb == null) return 0;
      if (ka == null) return 1;
      if (kb == null) return -1;
      return ka > kb ? -1 : ka < kb ? 1 : 0;
    };
    const sorted = [...visible].sort(cmp);
    const activeId = window.__activeInstanceId;

    tbody.innerHTML = sorted.map((inst, i) => {
      const sym = escapeHtml(inst.symbol || '');
      const name = escapeHtml(inst.name || `Instance #${inst.id}`);
      const raised = inst.raisedWei == null ? '—' : (+ethers.formatEther(inst.raisedWei)).toFixed(4);
      const mcap   = inst.mcapWei   == null ? '—' : (+ethers.formatEther(inst.mcapWei)).toFixed(4);
      const b = salePhaseBadge(inst.salePhase);
      const badge = b ? `<span class="phase-badge ${b.cls}">${b.label}</span>` : '<span class="phase-badge badge-unknown">—</span>';
      const activeCls = inst.id === activeId ? ' rank-row-active' : '';
      // Both columns deep-link to the sale page (primary action: buy). The
      // Proposals page is one click away via the topbar.
      const saleHref = `sale?inst=${inst.id}`;
      const propsHref = `proposals?inst=${inst.id}`;
      return `
        <tr class="rank-row${activeCls}" data-rank-instance-id="${inst.id}">
          <td>${i + 1}</td>
          <td><a class="rank-link" href="${saleHref}"><strong>${sym}</strong></a></td>
          <td><a class="rank-link" href="${saleHref}">${name}</a></td>
          <td><a class="rank-link" href="${saleHref}">${badge}</a></td>
          <td class="rank-num">${raised}</td>
          <td class="rank-num">${mcap}</td>
          <td class="rank-actions">
            <a class="rank-action-btn rank-action-buy" href="${saleHref}">Buy →</a>
            <a class="rank-action-btn" href="${propsHref}">Proposals</a>
          </td>
        </tr>`;
    }).join('');
  }

  function wireRankingsControls() {
    document.querySelectorAll('.rank-sort').forEach(th => {
      th.addEventListener('click', () => {
        const key = th.dataset.rankSort;
        if (!key) return;
        rankSortKey = key;
        document.querySelectorAll('.rank-sort').forEach(x => x.classList.toggle('rank-sort-active', x === th));
        renderRankings();
      });
    });
    document.querySelectorAll('[data-rank-filter]').forEach(btn => {
      btn.addEventListener('click', () => {
        rankFilter = btn.dataset.rankFilter;
        document.querySelectorAll('[data-rank-filter]').forEach(x => x.classList.toggle('filter-pill-active', x === btn));
        renderRankings();
      });
    });
    // Row clicks now navigate via <a> — but we still need to record the
    // active instance in localStorage before the navigation happens so the
    // destination page picks it up even before ?inst= is parsed.
    document.addEventListener('click', (ev) => {
      const link = ev.target.closest('a.rank-link, a.rank-action-btn');
      if (!link) return;
      const row = link.closest('[data-rank-instance-id]');
      if (!row) return;
      const id = Number(row.dataset.rankInstanceId);
      if (Number.isFinite(id) && window.setActiveInstance) {
        window.setActiveInstance(id, false);
      }
    });
  }

  // ─── Stack live stats ─────────────────────────────────────────────────
  async function refreshStackStats() {
    const inst = window.activeInstance;
    const [block, markets, opBal, resolverOrch] = await Promise.all([
      safe(() => provider.getBlockNumber(), null),
      inst?.factory
        ? safe(() => new ethers.Contract(inst.factory, FACTORY_ABI, provider).marketsCount(), null)
        : Promise.resolve(null),
      safe(() => provider.getBalance(OPERATOR), null),
      inst?.resolver
        ? safe(() => new ethers.Contract(inst.resolver, RESOLVER_ABI, provider).orchestrator(), null)
        : Promise.resolve(null),
    ]);
    if ($$('#sep-block'))         $$('#sep-block').textContent = block ?? '—';
    if ($$('#sep-markets-count')) $$('#sep-markets-count').textContent = markets == null ? '—' : String(markets);
    if ($$('#sep-op-balance'))    $$('#sep-op-balance').textContent = opBal == null ? '—' : `${(+ethers.formatEther(opBal)).toFixed(4)} ETH`;
    if ($$('#sep-oracle-ok')) {
      if (!inst?.orchestrator || resolverOrch == null) {
        $$('#sep-oracle-ok').textContent = '—';
      } else {
        $$('#sep-oracle-ok').innerHTML = resolverOrch.toLowerCase() === inst.orchestrator.toLowerCase()
          ? '<span class="dash-value-ok">wired ✓</span>'
          : `<span class="dash-value-warn">${fmtAddr(resolverOrch)}</span>`;
      }
    }
    if ($$('#sep-updated'))       $$('#sep-updated').textContent = new Date().toLocaleTimeString();
  }

  async function refreshAll() {
    await loadSaleMetrics();
    renderRankings();
    await refreshStackStats();
  }
})();
