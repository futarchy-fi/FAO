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

async function loadTopic(id) {
  const r = await fetch(`../evaluations/topic-${id}-evals.jsonl`, { cache: 'no-cache' });
  if (!r.ok) return [];
  const txt = await r.text();
  return txt.trim().split('\n').filter(Boolean).map((l) => {
    try { return JSON.parse(l); } catch (_) { return null; }
  }).filter(Boolean);
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
    const cls = min >= TARGET ? 'target' : min < 5 ? 'below5' : 'below8';
    const pips = scores.map(s => `<span class="dim-pip ${s >= TARGET ? 'target' : s < 5 ? 'below5' : 'below8'}" title="${s.toFixed(1)}"></span>`).join('');
    return `<div class="topic-card">
      <div class="topic-card-head">
        <span class="topic-card-num">T${t.id} · ${rounds.length} rounds</span>
        <span class="topic-card-title">${t.label}</span>
      </div>
      <div class="topic-card-min ${cls}">${min.toFixed(1)}</div>
      <div class="topic-card-line">mean ${mean.toFixed(2)} · ${atTarget}/${scores.length} ≥ ${TARGET}</div>
      <div class="topic-card-dims">${pips}</div>
    </div>`;
  }).join('');
}

let minChartInstance = null;
function renderMinChart(allTopicRounds) {
  const ctx = document.getElementById('min-chart');
  const maxRounds = Math.max(...allTopicRounds.map(rs => rs.length));
  const labels = Array.from({ length: maxRounds }, (_, i) => `R${i + 1}`);
  const datasets = [];

  TOPICS.forEach((t, i) => {
    const rounds = allTopicRounds[i];
    const data = rounds.map(r => Math.min(...r.scores.map(s => s.score)));
    datasets.push({
      label: `T${t.id} ${t.label} (min)`,
      data: data.concat(Array(maxRounds - data.length).fill(null)),
      borderColor: t.color,
      backgroundColor: t.color + '20',
      tension: 0.2,
      borderWidth: 2,
    });
  });

  // Target line
  datasets.push({
    label: 'Target (≥8.0)',
    data: Array(maxRounds).fill(TARGET),
    borderColor: '#6fe9a8',
    backgroundColor: 'transparent',
    borderDash: [6, 4],
    borderWidth: 1.5,
    pointRadius: 0,
  });

  if (minChartInstance) minChartInstance.destroy();
  minChartInstance = new Chart(ctx, {
    type: 'line',
    data: { labels, datasets },
    options: {
      responsive: true,
      maintainAspectRatio: false,
      interaction: { mode: 'index', intersect: false },
      scales: {
        y: { min: 0, max: 10, ticks: { stepSize: 2, color: '#8892a4' }, grid: { color: '#1e2230' } },
        x: { ticks: { color: '#8892a4' }, grid: { color: '#1e2230' } },
      },
      plugins: {
        legend: { labels: { color: '#e0e4ec', font: { size: 11 } } },
        tooltip: { mode: 'index' },
      },
    },
  });
}

const perTopicCharts = {};
function renderPerTopicCharts(allTopicRounds) {
  const root = document.getElementById('per-topic-grid');
  root.innerHTML = '';
  TOPICS.forEach((t, i) => {
    const wrap = document.createElement('div');
    wrap.className = 'topic-chart-wrap';
    wrap.innerHTML = `<div class="topic-chart-title">T${t.id} · ${t.label}</div><canvas id="chart-t${t.id}"></canvas>`;
    root.appendChild(wrap);
  });
  TOPICS.forEach((t, i) => {
    const rounds = allTopicRounds[i];
    if (!rounds || rounds.length === 0) return;
    const dimNames = rounds[0].scores.map(s => s.dimension.slice(0, 32));
    const labels = rounds.map((_, r) => `R${r + 1}`);
    const colors = ['#3effb0', '#ffb347', '#7cc0ff', '#c084fc', '#5b8def', '#f59e0b', '#ff8a8a', '#9bb0ff'];
    const datasets = dimNames.map((name, di) => ({
      label: name,
      data: rounds.map(r => r.scores[di]?.score ?? null),
      borderColor: colors[di % colors.length],
      backgroundColor: colors[di % colors.length] + '20',
      tension: 0.2,
      borderWidth: 1.5,
    }));
    datasets.push({
      label: '≥8 target',
      data: Array(rounds.length).fill(TARGET),
      borderColor: '#6fe9a8',
      borderDash: [6, 4],
      borderWidth: 1,
      pointRadius: 0,
    });
    if (perTopicCharts[t.id]) perTopicCharts[t.id].destroy();
    perTopicCharts[t.id] = new Chart(document.getElementById(`chart-t${t.id}`), {
      type: 'line',
      data: { labels, datasets },
      options: {
        responsive: true,
        maintainAspectRatio: false,
        scales: {
          y: { min: 0, max: 10, ticks: { stepSize: 2, color: '#8892a4' }, grid: { color: '#1e2230' } },
          x: { ticks: { color: '#8892a4' }, grid: { color: '#1e2230' } },
        },
        plugins: { legend: { labels: { color: '#e0e4ec', font: { size: 10 }, boxWidth: 12 } } },
      },
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
  const head = `<tr><th class="row-label">Topic.Dim</th>${Array.from({ length: maxRounds }, (_, i) => `<th>R${i + 1}</th>`).join('')}<th>Δ</th></tr>`;
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

async function refresh() {
  try {
    const allTopicRounds = await Promise.all(TOPICS.map(t => loadTopic(t.id)));
    document.getElementById('hdr-stats').innerHTML = statsHeader(allTopicRounds);
    renderOverview(allTopicRounds);
    renderMinChart(allTopicRounds);
    renderPerTopicCharts(allTopicRounds);
    renderHeatmap(allTopicRounds);
    renderDeltaTable(allTopicRounds);
  } catch (e) {
    document.getElementById('hdr-stats').innerHTML = `<span class="hdr-stat-val danger">error: ${e.message}</span>`;
  }
}

document.addEventListener('DOMContentLoaded', () => {
  refresh();
  setInterval(refresh, 30_000);
});
