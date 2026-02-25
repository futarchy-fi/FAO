const DASHBOARD_CONFIG = {
  rpcUrl: 'https://rpc.gnosischain.com',
  chainLabel: 'Gnosis',
  token: {
    address: '0xb222e2a6e065c2559a74168eeaba298af91b84b9',
  },
  sale: {
    address: '0x460915528ce37ec66a26b98b791db512bc62dc17',
  },
  liquidityManager: {
    // Fill this in after manager is deployed in production.
    address: '',
  },
};

const tokenAbi = [
  'function name() view returns (string)',
  'function symbol() view returns (string)',
  'function decimals() view returns (uint8)',
  'function totalSupply() view returns (uint256)',
];

const saleAbi = [
  'function saleStart() view returns (uint256)',
  'function initialPhaseEndTime() view returns (uint256)',
  'function initialPhaseFinalized() view returns (bool)',
  'function minInitialPhaseSold() view returns (uint256)',
  'function initialTokensSold() view returns (uint256)',
  'function totalCurveTokensSold() view returns (uint256)',
  'function totalAmountRaised() view returns (uint256)',
  'function initialFundsRaised() view returns (uint256)',
  'function totalCurveFundsRaised() view returns (uint256)',
  'function totalSaleTokens() view returns (uint256)',
  'function currentPriceWeiPerToken() view returns (uint256)',
  'function longTargetReachedAt() view returns (uint256)',
];

const liquidityAbi = [
  'function inConditionalMode() view returns (bool)',
  'function spotLiquidity() view returns (uint128)',
  'function conditionalLiquidity() view returns (uint128)',
  'function totalManagedLiquidity() view returns (uint256)',
  'function previewLiquidityMigration() view returns (uint128)',
  'function emergencyExitReady() view returns (bool)',
  'function activeProposalId() view returns (uint256)',
  'function emergencyExitArmedAt() view returns (uint256)',
];

const dom = {
  refreshBtn: document.getElementById('dashboard-refresh'),
  tokenState: document.getElementById('token-state'),
  tokenName: document.getElementById('token-name'),
  tokenSymbol: document.getElementById('token-symbol'),
  tokenDecimals: document.getElementById('token-decimals'),
  tokenSupply: document.getElementById('token-total-supply'),
  tokenUpdated: document.querySelector('#token-updated span'),
  tokenError: document.getElementById('token-error'),

  saleState: document.getElementById('sale-state'),
  salePhase: document.getElementById('sale-phase'),
  salePrice: document.getElementById('sale-price'),
  saleInitialTarget: document.getElementById('sale-initial-target'),
  saleTotalSold: document.getElementById('sale-total-sold'),
  saleTotalRaised: document.getElementById('sale-total-raised'),
  saleLongTarget: document.getElementById('sale-long-target'),
  saleUpdated: document.querySelector('#sale-updated span'),
  saleError: document.getElementById('sale-error'),

  liquidityState: document.getElementById('liquidity-state'),
  liquidityMode: document.getElementById('liquidity-mode'),
  liquiditySpot: document.getElementById('liquidity-spot'),
  liquidityConditional: document.getElementById('liquidity-conditional'),
  liquidityTotal: document.getElementById('liquidity-total'),
  liquidityMigration: document.getElementById('liquidity-migration'),
  liquidityEmergency: document.getElementById('liquidity-emergency'),
  liquiditySource: document.getElementById('liquidity-source'),
  liquidityUpdated: document.querySelector('#liquidity-updated span'),
  liquidityError: document.getElementById('liquidity-error'),
};

function setState(element, state, label) {
  element.classList.remove('state-badge--loading', 'state-badge--ok', 'state-badge--warning', 'state-badge--error');
  element.classList.add(`state-badge--${state}`);
  element.textContent = label;
}

function formatInteger(value) {
  if (value === null || value === undefined) return '—';

  if (typeof value === 'number') {
    return value.toLocaleString('en-US');
  }

  try {
    return new Intl.NumberFormat('en-US').format(value);
  } catch (error) {
    return String(value);
  }
}

function formatTokenAmount(value, decimals) {
  const parsed = ethers.formatUnits(value, decimals);
  const [whole, fraction = ''] = parsed.split('.');
  const trimmedFraction = fraction.slice(0, 4).replace(/0+$/, '');
  const wholeFormatted = new Intl.NumberFormat('en-US').format(BigInt(whole));

  return trimmedFraction ? `${wholeFormatted}.${trimmedFraction} FAO` : `${wholeFormatted} FAO`;
}

function formatWei(value) {
  const parsed = ethers.formatEther(value);
  const [whole, fraction = ''] = parsed.split('.');
  const trimmedFraction = fraction.slice(0, 6).replace(/0+$/, '');
  const wholeFormatted = new Intl.NumberFormat('en-US').format(BigInt(whole));

  return trimmedFraction
    ? `${wholeFormatted}.${trimmedFraction} xDAI`
    : `${wholeFormatted} xDAI`;
}

function formatTime(unixTs) {
  if (!unixTs || BigInt(unixTs) === 0n) return '—';
  const date = new Date(Number(unixTs) * 1000);
  return date.toLocaleString();
}

function setSourceUpdated(element, block) {
  if (!element || !block) {
    element.textContent = 'source unavailable';
    return;
  }

  element.textContent = `block ${block.number} on ${DASHBOARD_CONFIG.chainLabel} at ${new Date(Number(block.timestamp) * 1000).toLocaleString()}`;
}

function setError(errorElement, panelState, message) {
  errorElement.textContent = message;
  setState(panelState, 'error', 'Error');
}

function clearError(errorElement, panelState, message) {
  errorElement.textContent = '';
  if (message) setState(panelState, 'ok', message);
}

async function loadTokenStatus(provider, block) {
  clearError(dom.tokenError, dom.tokenState, 'Loading');
  setState(dom.tokenState, 'loading', 'Loading');

  const token = new ethers.Contract(DASHBOARD_CONFIG.token.address, tokenAbi, provider);

  try {
    const [name, symbol, decimals, totalSupply] = await Promise.all([
      token.name({ blockTag: block.number }),
      token.symbol({ blockTag: block.number }),
      token.decimals({ blockTag: block.number }),
      token.totalSupply({ blockTag: block.number }),
    ]);

    dom.tokenName.textContent = name;
    dom.tokenSymbol.textContent = symbol;
    dom.tokenDecimals.textContent = String(decimals);
    dom.tokenSupply.textContent = formatTokenAmount(totalSupply, decimals);

    setSourceUpdated(dom.tokenUpdated, block);
    setState(dom.tokenState, 'ok', 'Updated');
    clearError(dom.tokenError, dom.tokenState, 'Updated');
  } catch (error) {
    setError(dom.tokenError, dom.tokenState, `Could not load token metrics: ${error.message}`);
  }
}

function resolveSalePhase(saleStart, phaseEnd, finalized, nowTs) {
  if (saleStart === 0n) {
    return 'Not started';
  }

  if (finalized) {
    return 'Bonding curve';
  }

  if (nowTs < Number(phaseEnd)) {
    return 'Initial fixed-price phase';
  }

  return 'Waiting for finalization';
}

async function loadSaleStatus(provider, block) {
  clearError(dom.saleError, dom.saleState, 'Loading');
  setState(dom.saleState, 'loading', 'Loading');

  const sale = new ethers.Contract(DASHBOARD_CONFIG.sale.address, saleAbi, provider);

  try {
    const [
      saleStart,
      phaseEnd,
      finalized,
      minTarget,
      initialSold,
      curveSold,
      totalRaised,
      initialRaised,
      curveRaised,
      totalSaleTokens,
      priceWei,
      longTargetReachedAt,
    ] = await Promise.all([
      sale.saleStart({ blockTag: block.number }),
      sale.initialPhaseEndTime({ blockTag: block.number }),
      sale.initialPhaseFinalized({ blockTag: block.number }),
      sale.minInitialPhaseSold({ blockTag: block.number }),
      sale.initialTokensSold({ blockTag: block.number }),
      sale.totalCurveTokensSold({ blockTag: block.number }),
      sale.totalAmountRaised({ blockTag: block.number }),
      sale.initialFundsRaised({ blockTag: block.number }),
      sale.totalCurveFundsRaised({ blockTag: block.number }),
      sale.totalSaleTokens({ blockTag: block.number }),
      sale.currentPriceWeiPerToken({ blockTag: block.number }),
      sale.longTargetReachedAt({ blockTag: block.number }),
    ]);

    const nowTs = Number(block.timestamp);

    dom.salePhase.textContent = resolveSalePhase(saleStart, phaseEnd, finalized, nowTs);
    dom.salePrice.textContent = `${formatWei(priceWei)} / FAO`;
    dom.saleInitialTarget.textContent = `${formatInteger(initialSold)} / ${formatInteger(minTarget)} FAO`;
    dom.saleTotalSold.textContent = `${formatInteger(curveSold + initialSold)} / ${formatInteger(totalSaleTokens)} FAO`;
    dom.saleTotalRaised.textContent = `${formatWei(initialRaised)} (initial), ${formatWei(curveRaised)} (curve), ${formatWei(totalRaised)} total`;
    dom.saleLongTarget.textContent = longTargetReachedAt === 0n ? 'not reached yet' : formatTime(longTargetReachedAt);

    setSourceUpdated(dom.saleUpdated, block);
    setState(dom.saleState, 'ok', 'Updated');
    clearError(dom.saleError, dom.saleState, 'Updated');
  } catch (error) {
    setError(dom.saleError, dom.saleState, `Could not load sale metrics: ${error.message}`);
  }
}

async function loadLiquidityStatus(provider, block) {
  clearError(dom.liquidityError, dom.liquidityState, 'Loading');
  setState(dom.liquidityState, 'loading', 'Loading');
  const addr = (DASHBOARD_CONFIG.liquidityManager.address || '').trim();

  if (!addr) {
    dom.liquidityMode.textContent = 'Not configured';
    dom.liquiditySpot.textContent = '—';
    dom.liquidityConditional.textContent = '—';
    dom.liquidityTotal.textContent = '—';
    dom.liquidityMigration.textContent = '—';
    dom.liquidityEmergency.textContent = 'Not configured';
    dom.liquiditySource.textContent = 'Pending deployment/configuration';
    dom.liquidityUpdated.textContent = `as-of ${new Date(Number(block.timestamp) * 1000).toLocaleString()}`;
    setState(dom.liquidityState, 'warning', 'Pending');
    return;
  }

  const manager = new ethers.Contract(addr, liquidityAbi, provider);

  try {
    const [
      inConditionalMode,
      spotLiquidity,
      conditionalLiquidity,
      totalLiquidity,
      migrationPreview,
      emergencyReady,
      activeProposalId,
    ] = await Promise.all([
      manager.inConditionalMode({ blockTag: block.number }),
      manager.spotLiquidity({ blockTag: block.number }),
      manager.conditionalLiquidity({ blockTag: block.number }),
      manager.totalManagedLiquidity({ blockTag: block.number }),
      manager.previewLiquidityMigration({ blockTag: block.number }),
      manager.emergencyExitReady({ blockTag: block.number }),
      manager.activeProposalId({ blockTag: block.number }),
    ]);

    dom.liquidityMode.textContent = inConditionalMode ? 'Conditional mode' : 'Spot mode';
    dom.liquiditySpot.textContent = formatInteger(spotLiquidity);
    dom.liquidityConditional.textContent = formatInteger(conditionalLiquidity);
    dom.liquidityTotal.textContent = formatInteger(totalLiquidity);
    dom.liquidityMigration.textContent = formatInteger(migrationPreview);
    dom.liquidityEmergency.textContent = emergencyReady
      ? `ready (proposalId: ${formatInteger(activeProposalId)})`
      : 'inactive';
    dom.liquiditySource.textContent = `${addr.slice(0, 8)}…${addr.slice(-8)} (fLP)`;

    setSourceUpdated(dom.liquidityUpdated, block);
    setState(dom.liquidityState, 'ok', 'Updated');
    clearError(dom.liquidityError, dom.liquidityState, 'Updated');
  } catch (error) {
    setError(dom.liquidityError, dom.liquidityState, `Could not load liquidity metrics: ${error.message}`);
  }
}

async function loadDashboard() {
  const label = 'Loading dashboard';
  dom.refreshBtn.disabled = true;
  dom.refreshBtn.textContent = `${label}...`;

  try {
    const provider = new ethers.JsonRpcProvider(DASHBOARD_CONFIG.rpcUrl);
    const block = await provider.getBlock('latest');

    await Promise.all([
      loadTokenStatus(provider, block),
      loadSaleStatus(provider, block),
      loadLiquidityStatus(provider, block),
    ]);
  } catch (error) {
    const message = `Global RPC failure: ${error.message}`;
    setError(dom.tokenError, dom.tokenState, message);
    setError(dom.saleError, dom.saleState, message);
    setError(dom.liquidityError, dom.liquidityState, message);
  } finally {
    dom.refreshBtn.disabled = false;
    dom.refreshBtn.textContent = 'Refresh status';
  }
}

if (dom.refreshBtn) {
  dom.refreshBtn.addEventListener('click', loadDashboard);
}

window.addEventListener('DOMContentLoaded', () => {
  loadDashboard();
  setInterval(loadDashboard, 60_000);
});
