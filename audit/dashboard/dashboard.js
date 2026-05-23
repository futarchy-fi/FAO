/*
 * FAO audit dashboard — pure-client rendering of the rubric trend.
 *
 * Reads audit/evaluations/topic-{1..6}-evals.jsonl over fetch (served by a
 * local static http.server, parent path is `../evaluations/...`).
 *
 * No build step. No backend. Refresh every 30s.
 */

const TOPICS = [
  { id: 1, label: 'Web3 UX',           color: '#3effb0' },
  { id: 2, label: 'Interface testing', color: '#ffb347' },
  { id: 3, label: 'Spec formalization', color: '#7cc0ff' },
  { id: 4, label: 'SC test infra',     color: '#c084fc' },
  { id: 5, label: 'Holistic arch',     color: '#5b8def' },
  { id: 6, label: 'Wiki self-improve', color: '#f59e0b' },
];
const TARGET = 8.0;
const CHART_JS_SRC = 'https://cdn.jsdelivr.net/npm/chart.js@4.4.4/dist/chart.umd.min.js';
const CHART_ADAPTER_SRC = 'https://cdn.jsdelivr.net/npm/chartjs-adapter-date-fns@3.0.0/dist/chartjs-adapter-date-fns.bundle.min.js';
let chartLibPromise = null;
let chartsReady = false;
let chartsRequested = false;
let detailsReady = false;
let detailsRequested = false;
let fullLoaded = false;
let fullLoadRequested = false;
let latestTopicRounds = null;

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const script = document.createElement('script');
    script.src = src;
    script.async = true;
    script.onload = resolve;
    script.onerror = () => reject(new Error(`Could not load ${src}`));
    document.head.appendChild(script);
  });
}

async function loadChartLibs() {
  if (window.Chart) return;
  if (!chartLibPromise) {
    chartLibPromise = loadScript(CHART_JS_SRC).then(() => loadScript(CHART_ADAPTER_SRC));
  }
  await chartLibPromise;
}

// Minimum dims a row must have to count as a "canonical" full evaluator
// entry. Partial-dim entries (multimodal: 3 dims; worker self-scores: 1 dim)
// would otherwise pollute the trend chart and mean computation.
//
// Per rubric:
//   T1.v1=6, T1.v2=8, T2.v1=7, T2.v2=10, T3=8, T4=6, T5=6, T6=6
// 5 dims is a permissive floor that filters out 1-3-dim partial rows but
// keeps every real evaluator entry.
const MIN_CANONICAL_DIMS = 5;

// Worker self-scores leak through with evaluator="worker-*". Drop those —
// workers commit code, they don't evaluate. Everything else (codex, multimodal,
// evaluator-1, etc.) counts AS LONG AS the row is full-dim (≥ MIN_CANONICAL_DIMS).
// Originally multimodal was filtered because it only scored 3 dims, but it now
// emits all 8 v2 dims so it qualifies as canonical.
function isCanonicalRow(d) {
  const ev = (d.evaluator || 'codex').toLowerCase();
  if (ev.startsWith('worker-')) return false;
  return (d.scores || []).length >= MIN_CANONICAL_DIMS;
}

async function loadTopic(id) {
  // Pages-relative path: the deployed dashboard lives at /fao/index.html
  // with JSONL files at /fao/evaluations/. The dev-mode local dashboard at
  // audit/dashboard/ also has evaluations at audit/evaluations/ — both
  // resolve via this relative URL when served from /fao/ (or audit/).
  const url = new URL(`evaluations/topic-${id}-evals.jsonl`, document.baseURI).toString();
  const r = await fetch(url, { cache: 'no-cache' });
  if (!r.ok) return [];
  const txt = await r.text();
  const rows = txt.trim().split('\n').filter(Boolean).map((l) => {
    try { return JSON.parse(l); } catch (_) { return null; }
  }).filter(Boolean);
  // Keep ONLY canonical full-evaluator rows for the trend chart.
  // Partial rows (multimodal D5/D6/D8 only, worker self-scores) are
  // dropped — they show a misleading mean.
  return rows.filter(isCanonicalRow);
}

async function loadSummary() {
  const url = new URL('summary.json', document.baseURI).toString();
  const r = await fetch(url, { cache: 'no-cache' });
  if (!r.ok) throw new Error(`Could not load summary (${r.status})`);
  return r.json();
}

async function loadAllTopicRounds() {
  return Promise.all(TOPICS.map(t => loadTopic(t.id)));
}

function summaryToTopicRounds(summary) {
  return TOPICS.map((topic, i) => {
    const item = summary.topics?.find(t => t.id === topic.id) || summary.topics?.[i];
    const last = {
      timestamp: item?.timestamp || summary.generatedAt,
      scores: item?.scores || [],
    };
    const rounds = Math.max(1, Number(item?.rounds || summary.latestRound || 1));
    const arr = Array.from({ length: rounds }, () => null);
    arr[arr.length - 1] = last;
    return arr;
  });
}

function scoreColorClass(s) {
  return `s-${Math.min(10, Math.max(0, Math.round(s)))}`;
}

function statsHeader(allTopicRounds) {
  const lastPerTopic = allTopicRounds.map(rs => rs[rs.length - 1]).filter(Boolean);
  if (lastPerTopic.length === 0) return 'no data';
  const allScores = lastPerTopic.flatMap(r => r.scores.map(s => s.score));
  const atTarget = allScores.filter(s => s >= TARGET).length;
  const min = Math.min(...allScores);
  const mean = allScores.reduce((a, b) => a + b, 0) / allScores.length;
  return `
    <span><span class="hdr-stat-label">Total dims:</span><span class="hdr-stat-val">${allScores.length}</span></span>
    <span><span class="hdr-stat-label">At target (≥${TARGET}):</span><span class="hdr-stat-val target">${atTarget}/${allScores.length}</span></span>
    <span><span class="hdr-stat-label">Min:</span><span class="hdr-stat-val ${min < 5 ? 'danger' : min < 8 ? 'warn' : 'target'}">${min.toFixed(1)}</span></span>
    <span><span class="hdr-stat-label">Mean:</span><span class="hdr-stat-val ${mean < 5 ? 'danger' : mean < 8 ? 'warn' : 'target'}">${mean.toFixed(2)}</span></span>
    <span><span class="hdr-stat-label">Latest round:</span><span class="hdr-stat-val">${Math.max(...allTopicRounds.map(rs => rs.length))}</span></span>
    <span><span class="hdr-stat-label">Last update:</span><span class="hdr-stat-val">${new Date().toLocaleTimeString()}</span></span>
  `;
}

function renderOverview(allTopicRounds) {
  const root = document.getElementById('overview-grid');
  root.setAttribute('aria-busy', 'false');
  root.innerHTML = TOPICS.map((t, i) => {
    const rounds = allTopicRounds[i];
    if (!rounds || rounds.length === 0) {
      return `<div class="topic-card"><div class="topic-card-head"><span class="topic-card-num">T${t.id}</span><span class="topic-card-title">${t.label}</span></div><div class="topic-card-line">no data</div></div>`;
    }
    const last = rounds[rounds.length - 1];
    const scores = last.scores.map(s => s.score);
    const min = Math.min(...scores);
    const mean = scores.reduce((a, b) => a + b, 0) / scores.length;
    const atTarget = scores.filter(s => s >= TARGET).length;
    const cls = mean >= TARGET ? 'target' : mean < 5 ? 'below5' : 'below8';
    const pips = scores.map(s => `<span class="dim-pip ${s >= TARGET ? 'target' : s < 5 ? 'below5' : 'below8'}" title="${s.toFixed(1)}"></span>`).join('');
    return `<div class="topic-card">
      <div class="topic-card-head">
        <span class="topic-card-num">T${t.id} · ${rounds.length} rounds</span>
        <span class="topic-card-title">${t.label}</span>
      </div>
      <div class="topic-card-min ${cls}">${mean.toFixed(2)}</div>
      <div class="topic-card-line">mean · min ${min.toFixed(1)} · ${atTarget}/${scores.length} ≥ ${TARGET}</div>
      <div class="topic-card-dims">${pips}</div>
    </div>`;
  }).join('');
}

// Format an ISO timestamp into a short human label for the x-axis.
function fmtTs(ts) {
  if (!ts) return '';
  const d = new Date(ts);
  if (isNaN(d.getTime())) return ts.slice(0, 16);
  // "May 22 12:39" for compact display
  return d.toLocaleString('en-US', { month: 'short', day: 'numeric', hour: '2-digit', minute: '2-digit', hour12: false });
}

function onVisible(targets, callback, fallbackDelay = 4000) {
  const visibleTargets = targets.filter(Boolean);
  if ('IntersectionObserver' in window && visibleTargets.length) {
    const observer = new IntersectionObserver((entries) => {
      if (!entries.some(entry => entry.isIntersecting)) return;
      observer.disconnect();
      callback();
    }, { rootMargin: '160px 0px' });
    visibleTargets.forEach(target => observer.observe(target));
  } else {
    setTimeout(callback, fallbackDelay);
  }
}

let minChartInstance = null;
function renderMinChart(allTopicRounds) {
  if (!window.Chart) return;
  const ctx = document.getElementById('min-chart');
  // Time-axis: one (timestamp, mean) point per evaluator R-round per topic.
  // Mean is the average sub-score for that topic at that timestamp.
  const datasets = [];

  TOPICS.forEach((t, i) => {
    const rounds = allTopicRounds[i];
    const data = rounds.map(r => {
      const scores = r.scores.map(s => s.score);
      const mean = scores.reduce((a, b) => a + b, 0) / scores.length;
      return { x: new Date(r.timestamp), y: mean };
    }).filter(p => !isNaN(p.x.getTime()));
    datasets.push({
      label: `T${t.id} ${t.label} (mean)`,
      data,
      borderColor: t.color,
      backgroundColor: t.color + '20',
      tension: 0.2,
      borderWidth: 2,
    });
  });

  // Target line spans full time range.
  const allTimes = datasets.flatMap(ds => ds.data.map(p => p.x.getTime()));
  const tMin = allTimes.length ? new Date(Math.min(...allTimes)) : new Date();
  const tMax = allTimes.length ? new Date(Math.max(...allTimes)) : new Date();
  datasets.push({
    label: 'Target (≥8.0)',
    data: [{ x: tMin, y: TARGET }, { x: tMax, y: TARGET }],
    borderColor: '#6fe9a8',
    backgroundColor: 'transparent',
    borderDash: [6, 4],
    borderWidth: 1.5,
    pointRadius: 0,
  });

  if (minChartInstance) minChartInstance.destroy();
  minChartInstance = new Chart(ctx, {
    type: 'line',
    data: { datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'nearest', axis: 'x', intersect: false },
      scales: {
        y: { min: 0, max: 10, ticks: { stepSize: 2, color: '#8892a4' }, grid: { color: '#1e2230' } },
        x: {
          type: 'time',
          time: { tooltipFormat: 'MMM d HH:mm', displayFormats: { hour: 'MMM d HH:mm', minute: 'HH:mm', second: 'HH:mm:ss' } },
          ticks: { color: '#8892a4', maxRotation: 0, autoSkip: true, maxTicksLimit: 8, source: 'auto' },
          grid: { color: '#1e2230' },
        },
      },
      plugins: {
        legend: { labels: { color: '#e0e4ec', font: { size: 11 } } },
        tooltip: { mode: 'nearest', intersect: false },
      },
    },
  });
}

const perTopicCharts = {};
function renderPerTopicCharts(allTopicRounds) {
  if (!window.Chart) return;
  const root = document.getElementById('per-topic-grid');
  root.innerHTML = '';
  TOPICS.forEach((t) => {
    const wrap = document.createElement('div');
    wrap.className = 'topic-chart-wrap';
    wrap.innerHTML = `<div class="topic-chart-title">T${t.id} · ${t.label}</div><canvas id="chart-t${t.id}" role="img" aria-label="T${t.id} ${t.label} score trend"></canvas>`;
    root.appendChild(wrap);
  });
  TOPICS.forEach((t, i) => {
    const rounds = allTopicRounds[i];
    if (!rounds || rounds.length === 0) return;
    const dimNames = rounds[0].scores.map(s => s.dimension.slice(0, 32));
    const colors = ['#3effb0', '#ffb347', '#7cc0ff', '#c084fc', '#5b8def', '#f59e0b', '#ff8a8a', '#9bb0ff'];
    const datasets = dimNames.map((name, di) => ({
      label: name,
      data: rounds.map(r => ({ x: new Date(r.timestamp), y: r.scores[di]?.score ?? null }))
                  .filter(p => !isNaN(p.x.getTime())),
      borderColor: colors[di % colors.length],
      backgroundColor: colors[di % colors.length] + '20',
      tension: 0.2,
      borderWidth: 1.5,
    }));
    const allTimes = rounds.map(r => new Date(r.timestamp).getTime()).filter(t => !isNaN(t));
    if (allTimes.length) {
      datasets.push({
        label: '≥8 target',
        data: [
          { x: new Date(Math.min(...allTimes)), y: TARGET },
          { x: new Date(Math.max(...allTimes)), y: TARGET },
        ],
        borderColor: '#6fe9a8',
        borderDash: [6, 4],
        borderWidth: 1,
        pointRadius: 0,
      });
    }
    if (perTopicCharts[t.id]) perTopicCharts[t.id].destroy();
    perTopicCharts[t.id] = new Chart(document.getElementById(`chart-t${t.id}`), {
      type: 'line',
      data: { datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        interaction: { mode: 'nearest', axis: 'x', intersect: false },
        scales: {
          y: { min: 0, max: 10, ticks: { stepSize: 2, color: '#8892a4' }, grid: { color: '#1e2230' } },
          x: {
            type: 'time',
            time: { tooltipFormat: 'MMM d HH:mm', displayFormats: { hour: 'MMM d HH:mm', minute: 'HH:mm' } },
            ticks: { color: '#8892a4', maxRotation: 0, autoSkip: true, maxTicksLimit: 5 },
            grid: { color: '#1e2230' },
          },
        },
        plugins: { legend: { labels: { color: '#e0e4ec', font: { size: 10 }, boxWidth: 12 } } },
      },
    });
  });
}

async function renderChartsWhenReady() {
  if (!latestTopicRounds) return;
  await loadChartLibs();
  chartsReady = true;
  renderMinChart(latestTopicRounds);
  renderPerTopicCharts(latestTopicRounds);
}

function queueCharts(allTopicRounds) {
  latestTopicRounds = allTopicRounds;
  if (chartsReady) {
    renderMinChart(allTopicRounds);
    renderPerTopicCharts(allTopicRounds);
    return;
  }
  if (chartsRequested) return;
  chartsRequested = true;

  onVisible([
    document.querySelector('.chart-wrap'),
    document.getElementById('per-topic-grid')
  ], () => {
    renderChartsWhenReady().catch((e) => {
      const min = document.querySelector('.chart-wrap');
      const perTopic = document.getElementById('per-topic-grid');
      if (min) min.textContent = `Chart load failed: ${e.message}`;
      if (perTopic) perTopic.textContent = `Chart load failed: ${e.message}`;
    });
  });
}

function renderHeatmap(allTopicRounds) {
  const root = document.getElementById('heatmap-wrap');
  const rows = [];
  TOPICS.forEach((t, i) => {
    const rounds = allTopicRounds[i];
    if (!rounds || rounds.length === 0) return;
    const dimCount = rounds[rounds.length - 1].scores.length;
    for (let d = 0; d < dimCount; d++) {
      const dimName = rounds[rounds.length - 1].scores[d].dimension;
      const scores = rounds.map(r => r.scores[d]?.score ?? null);
      rows.push({ topicId: t.id, dimIdx: d, dimName, scores });
    }
  });
  const maxRounds = Math.max(...allTopicRounds.map(rs => rs.length));
  // Column headers: short timestamp from the latest topic that has that round.
  // Falls back to the first topic with the round populated.
  const colTs = Array.from({ length: maxRounds }, (_, i) => {
    for (const rs of allTopicRounds) {
      if (rs[i]?.timestamp) return rs[i].timestamp;
    }
    return null;
  });
  const head = `<tr><th class="row-label">Topic.Dim</th>${colTs.map(ts => `<th title="${ts || ''}">${fmtTs(ts)}</th>`).join('')}<th>Δ</th></tr>`;
  const body = rows.map(r => {
    const cells = r.scores.map(s => s == null ? '<td>—</td>' : `<td class="heatmap-cell ${scoreColorClass(s)}">${s.toFixed(1)}</td>`).join('') + Array(maxRounds - r.scores.length).fill('<td>—</td>').join('');
    const first = r.scores[0];
    const last = r.scores[r.scores.length - 1];
    const delta = (first != null && last != null) ? (last - first) : 0;
    const dCls = delta > 0.2 ? 'delta-pos' : delta < -0.2 ? 'delta-neg' : 'delta-zero';
    return `<tr><td class="row-label" title="${r.dimName}">T${r.topicId}.D${r.dimIdx + 1} · ${r.dimName.slice(0, 36)}</td>${cells}<td class="${dCls}">${delta >= 0 ? '+' : ''}${delta.toFixed(1)}</td></tr>`;
  }).join('');
  root.innerHTML = `<table class="heatmap-table"><thead>${head}</thead><tbody>${body}</tbody></table>`;
}

function renderDeltaTable(allTopicRounds) {
  const tbody = document.querySelector('#delta-table tbody');
  const deltas = [];
  TOPICS.forEach((t, i) => {
    const rounds = allTopicRounds[i];
    if (!rounds || rounds.length < 2) return;
    const prev = rounds[rounds.length - 2];
    const curr = rounds[rounds.length - 1];
    curr.scores.forEach((s, di) => {
      const prevS = prev.scores[di]?.score ?? s.score;
      const d = s.score - prevS;
      if (Math.abs(d) >= 0.05) {
        deltas.push({ topic: t.id, dim: s.dimension, prev: prevS, curr: s.score, delta: d });
      }
    });
  });
  deltas.sort((a, b) => Math.abs(b.delta) - Math.abs(a.delta));
  if (deltas.length === 0) {
    tbody.innerHTML = '<tr><td colspan="6">no deltas in the latest round</td></tr>';
    return;
  }
  tbody.innerHTML = deltas.slice(0, 20).map(d => {
    const cls = d.delta > 0 ? 'delta-pos' : 'delta-neg';
    const arrow = d.delta > 0 ? '↑' : '↓';
    return `<tr><td>T${d.topic}</td><td>${d.dim.slice(0, 50)}</td><td>${d.prev.toFixed(1)}</td><td>${d.curr.toFixed(1)}</td><td class="${cls}">${d.delta >= 0 ? '+' : ''}${d.delta.toFixed(2)}</td><td class="${cls}">${arrow}</td></tr>`;
  }).join('');
}

function queueDetails(allTopicRounds) {
  latestTopicRounds = allTopicRounds;
  if (detailsReady) {
    renderHeatmap(allTopicRounds);
    renderDeltaTable(allTopicRounds);
    return;
  }
  if (detailsRequested) return;
  detailsRequested = true;

  onVisible([
    document.getElementById('heatmap-wrap'),
    document.getElementById('delta-table')
  ], () => {
    detailsReady = true;
    if (!latestTopicRounds) return;
    renderHeatmap(latestTopicRounds);
    renderDeltaTable(latestTopicRounds);
  });
}

function renderAll(allTopicRounds) {
  document.getElementById('hdr-stats').innerHTML = statsHeader(allTopicRounds);
  renderOverview(allTopicRounds);
  queueCharts(allTopicRounds);
  queueDetails(allTopicRounds);
}

function queueFullData() {
  if (fullLoadRequested) return;
  fullLoadRequested = true;
  onVisible([
    document.querySelector('.chart-wrap'),
    document.getElementById('per-topic-grid'),
    document.getElementById('heatmap-wrap'),
    document.getElementById('delta-table')
  ], async () => {
    try {
      const allTopicRounds = await loadAllTopicRounds();
      fullLoaded = true;
      renderAll(allTopicRounds);
    } catch (e) {
      document.getElementById('hdr-stats').innerHTML = `<span class="hdr-stat-val danger">error: ${e.message}</span>`;
    }
  });
}

async function refresh() {
  try {
    if (!fullLoaded) {
      try {
        const summary = await loadSummary();
        const summaryRounds = summaryToTopicRounds(summary);
        document.getElementById('hdr-stats').innerHTML = statsHeader(summaryRounds);
        renderOverview(summaryRounds);
        queueFullData();
      } catch (_) {
        const allTopicRounds = await loadAllTopicRounds();
        fullLoaded = true;
        renderAll(allTopicRounds);
      }
      return;
    }

    const allTopicRounds = await loadAllTopicRounds();
    renderAll(allTopicRounds);
  } catch (e) {
    document.getElementById('hdr-stats').innerHTML = `<span class="hdr-stat-val danger">error: ${e.message}</span>`;
  }
}

document.addEventListener('DOMContentLoaded', () => {
  refresh();
  setInterval(refresh, 30_000);
});
