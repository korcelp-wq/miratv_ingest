const $ = (id) => document.getElementById(id);
const badgeClass = (s) => String(s || 'unknown').toLowerCase().replace(/[^a-z0-9]+/g, '_');

function setText(id, value) { $(id).textContent = value ?? '—'; }

function statusRow(cells, status) {
  const div = document.createElement('div');
  div.className = 'row';
  cells.forEach((cell, idx) => {
    const c = document.createElement('div');
    if (idx === 1) c.innerHTML = `<span class="badge ${badgeClass(cell)}">${cell ?? '—'}</span>`;
    else c.textContent = cell ?? '—';
    div.appendChild(c);
  });
  return div;
}

function renderTable(el, rows, empty = 'No rows yet') {
  el.innerHTML = '';
  if (!rows || rows.length === 0) {
    const d = document.createElement('div');
    d.className = 'muted';
    d.textContent = empty;
    el.appendChild(d);
    return;
  }
  rows.forEach(r => el.appendChild(r));
}

async function loadStatus() {
  try {
    const res = await fetch('/api/status', { cache: 'no-store' });
    const data = await res.json();
    setText('lastUpdated', `Updated ${data.generated_at}`);

    const hb = data.heartbeat || {};
    const hbState = hb.state || 'UNKNOWN';
    setText('heartbeatState', hbState);
    setText('heartbeatDetails', hb.path || '—');
    setText('lastBeat', hb.heartbeat || '—');
    setText('beatAge', hb.age_seconds == null ? '—' : `${hb.age_seconds}s`);
    setText('ruleCount', hb.rule_count ?? '—');
    setText('lastAction', hb.last_action || '—');
    const heart = $('heartIcon');
    heart.className = `heart ${badgeClass(hbState)}`;

    const ollama = data.ollama || {};
    setText('ollamaState', ollama.state || '—');
    setText('ollamaMs', ollama.response_ms == null ? '—' : `${ollama.response_ms} ms`);
    setText('ollamaModel', ollama.active_model || '—');
    setText('ollamaModels', (ollama.models || []).join(', ') || ollama.message || '—');

    const serviceRows = (data.services || []).map(s => statusRow([s.name, s.state, s.count ? `${s.count} proc` : '0 proc', s.pid ? `PID ${s.pid}` : '—']));
    renderTable($('servicesTable'), serviceRows, 'No service state available');

    const cviRows = (data.cvi || []).map(c => statusRow([c.name || c.procedure, c.state, c.row_count == null ? '— rows' : `${c.row_count} rows`, c.response_ms == null ? c.message : `${c.response_ms} ms`]));
    renderTable($('cviTable'), cviRows, 'No CVI checks configured');

    const errorRows = (data.error_rates || []).map(e => {
      const div = document.createElement('div');
      div.className = 'row';
      div.innerHTML = `<div>${e.system}</div><div>${e.last_hour}/hr</div><div>${e.today} today</div>`;
      return div;
    });
    renderTable($('errorRates'), errorRows, 'No error rates available');

    const log = $('logFeed');
    log.innerHTML = '';
    (data.recent_log || []).slice(-80).reverse().forEach(l => {
      const div = document.createElement('div');
      div.className = `log-line ${l.category || 'INFO'}`;
      div.textContent = l.line;
      log.appendChild(div);
    });
  } catch (err) {
    setText('lastUpdated', `Dashboard error: ${err.message}`);
  }
}

$('askButton').addEventListener('click', async () => {
  const prompt = $('askInput').value.trim();
  if (!prompt) return;
  $('askOutput').textContent = 'Thinking...';
  try {
    const res = await fetch('/api/ask', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ prompt })
    });
    const data = await res.json();
    $('askOutput').textContent = `[${data.source || 'dashboard'}]\n${data.answer || data.error || JSON.stringify(data, null, 2)}`;
  } catch (err) {
    $('askOutput').textContent = err.message;
  }
});

loadStatus();
setInterval(loadStatus, 5000);
