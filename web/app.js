/* PRTG Mover dashboard - vanilla JS, no build step. */
(() => {
  'use strict';

  // ------------------------------------------------------------ token
  const store = {
    get(k) { try { return sessionStorage.getItem(k) || localStorage.getItem(k); } catch { return null; } },
    set(k, v) { try { sessionStorage.setItem(k, v); localStorage.setItem(k, v); } catch { /* storage blocked */ } },
  };
  let token = new URLSearchParams(location.search).get('token') || store.get('pm_token') || '';
  if (new URLSearchParams(location.search).has('token')) {
    store.set('pm_token', token);
    history.replaceState(null, '', location.pathname + location.hash);
  }

  // ------------------------------------------------------------ helpers
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmtSize = (b) => { if (!b && b !== 0) return '–'; const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; } return `${b.toFixed(i ? 1 : 0)} ${u[i]}`; };
  const fmtDate = (s) => { if (!s) return '–'; const d = new Date(s); return isNaN(d) ? s : d.toLocaleString(); };
  const ago = (s) => { if (!s) return ''; const m = Math.round((Date.now() - new Date(s)) / 60000); if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`; const h = Math.round(m / 60); return h < 24 ? `${h} h ago` : `${Math.round(h / 24)} d ago`; };
  const arr = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);

  function toast(msg, isErr = false) {
    const el = document.createElement('div');
    el.className = 'toast' + (isErr ? ' err' : '');
    el.textContent = msg;
    $('#toasts').appendChild(el);
    setTimeout(() => el.remove(), isErr ? 7000 : 3500);
  }

  async function api(method, path, body) {
    const opts = { method, headers: { 'X-PM-Token': token } };
    if (body !== undefined) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    const res = await fetch(path, opts);
    if (res.status === 401) { askToken(); throw new Error('Unauthorized'); }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || `HTTP ${res.status}`);
    return data;
  }

  function askToken() {
    const d = $('#tokenDialog');
    if (!d.open) d.showModal();
  }
  $('#tokenForm').addEventListener('submit', () => {
    token = $('#tokenForm').token.value.trim();
    store.set('pm_token', token);
    refreshAll();
  });

  const statusBadge = (s) => {
    const map = { succeeded: 'ok', failed: 'err', running: 'info', queued: '', cancelled: 'warn' };
    return `<span class="badge ${map[s] ?? ''}">${esc(s)}</span>`;
  };

  // ------------------------------------------------------------ state
  const state = { servers: [], backups: [], installers: [], jobs: [], selectedJob: null, logSince: 0, jobTimer: null };

  // ------------------------------------------------------------ navigation
  function show(view) {
    $$('.view').forEach((v) => v.classList.toggle('active', v.id === `view-${view}`));
    $$('nav a').forEach((a) => a.classList.toggle('active', a.dataset.view === view));
    if (view === 'jobs') loadJobs();
  }
  window.addEventListener('hashchange', () => show(location.hash.slice(1) || 'overview'));
  $$('[data-goto]').forEach((b) => b.addEventListener('click', () => { location.hash = b.dataset.goto; }));

  // ------------------------------------------------------------ info / overview
  async function loadInfo() {
    const i = await api('GET', '/api/info');
    $('#version').textContent = `v${i.version}`;
    $('#managerInfo').innerHTML = `Manager: <b>${esc(i.manager)}</b><br>${esc(i.user)}`;
    $('#backupsPath').textContent = `Packages stored on the manager in ${i.backupsPath}`;
  }

  function renderOverview() {
    $('#statServers').textContent = state.servers.length;
    $('#statBackups').textContent = state.backups.length;
    const running = state.jobs.filter((j) => j.status === 'running' || j.status === 'queued').length;
    $('#statRunning').textContent = running;
    const pill = $('#runningPill'); pill.hidden = !running; pill.textContent = running;
    const last = state.jobs[0];
    $('#statLast').innerHTML = last ? statusBadge(last.status) : '–';
    const recent = state.jobs.slice(0, 6);
    $('#recentJobs').innerHTML = recent.length ? recent.map((j) => `
      <div class="item" data-job="${esc(j.id)}"><div style="min-width:0"><div class="t">${esc(j.summary || j.type)}</div>
      <span class="sub-text">${esc(ago(j.created))}</span></div>${statusBadge(j.status)}</div>`).join('')
      : '<div class="empty">No jobs yet.</div>';
    $$('#recentJobs .item').forEach((el) => el.addEventListener('click', () => { location.hash = 'jobs'; selectJob(el.dataset.job); }));
  }

  // ------------------------------------------------------------ servers
  async function loadServers() {
    state.servers = arr(await api('GET', '/api/servers'));
    renderServers(); renderMigrateForm(); renderOverview();
  }

  function renderServers() {
    const tb = $('#serversTable tbody');
    if (!state.servers.length) { tb.innerHTML = '<tr><td colspan="7" class="empty">No servers yet — add the source PRTG server and at least one target.</td></tr>'; return; }
    tb.innerHTML = state.servers.map((s) => {
      const st = s.lastStatus; const info = st && st.info;
      let test = '<span class="badge">never</span>';
      if (st) test = st.ok ? `<span class="badge ok">ok</span><span class="sub-text">${esc(ago(st.checked))}</span>` : `<span class="badge err" title="${esc(st.error)}">failed</span><span class="sub-text">${esc(ago(st.checked))}</span>`;
      let prtg = '–';
      if (info) prtg = info.Prtg && info.Prtg.Installed ? `${esc(info.Prtg.Version)}<span class="sub-text">${esc(info.PrtgDataGB)} GB data · ${esc(info.Prtg.CoreStatus)}</span>` : '<span class="badge warn">not installed</span>';
      const cred = s.hasCredential ? '<span class="badge ok">saved</span>' : '<span class="badge" title="The current Windows identity of the manager is used">Windows identity</span>';
      return `<tr>
        <td><b>${esc(s.name)}</b>${info ? `<span class="sub-text">${esc(info.OS)}</span>` : ''}</td>
        <td class="num">${esc(s.host)}${s.useSsl ? ' <span class="badge info">HTTPS</span>' : ''}</td>
        <td>${esc(s.role)}</td><td>${cred}</td><td>${test}</td><td>${prtg}</td>
        <td><div class="btn-group">
          <button class="btn small" data-act="test" data-id="${esc(s.id)}">Test</button>
          <button class="btn small" data-act="edit" data-id="${esc(s.id)}">Edit</button>
          <button class="btn small danger" data-act="del" data-id="${esc(s.id)}">Delete</button>
        </div></td></tr>`;
    }).join('');
  }

  $('#serversTable').addEventListener('click', async (e) => {
    const b = e.target.closest('button[data-act]'); if (!b) return;
    const s = state.servers.find((x) => x.id === b.dataset.id);
    if (b.dataset.act === 'test') startJob({ type: 'test', serverIds: [s.id] });
    if (b.dataset.act === 'edit') openServerDialog(s);
    if (b.dataset.act === 'del' && confirm(`Delete server "${s.name}" and its saved credential?`)) {
      try { await api('DELETE', `/api/servers/${encodeURIComponent(s.id)}`); toast('Server deleted'); loadServers(); } catch (err) { toast(err.message, true); }
    }
  });
  $('#addServerBtn').addEventListener('click', () => openServerDialog(null));
  $('#testAllBtn').addEventListener('click', () => {
    if (!state.servers.length) return toast('Add a server first', true);
    startJob({ type: 'test', serverIds: state.servers.map((s) => s.id) });
  });

  function openServerDialog(s) {
    const f = $('#serverForm'); f.reset();
    $('#serverDialogTitle').textContent = s ? `Edit ${s.name}` : 'Add server';
    f.id.value = s ? s.id : '';
    if (s) {
      f.name.value = s.name; f.host.value = s.host; f.role.value = s.role || 'both'; f.port.value = s.port || 0;
      f.authentication.value = s.authentication || 'Default'; f.useSsl.checked = !!s.useSsl; f.skipCaCheck.checked = !!s.skipCaCheck; f.notes.value = s.notes || '';
    }
    $('#serverDialog').showModal();
  }
  $('#serverDialog').addEventListener('close', async () => {
    if ($('#serverDialog').returnValue !== 'save') return;
    const f = $('#serverForm');
    const body = {
      id: f.id.value || undefined, name: f.name.value.trim(), host: f.host.value.trim(), role: f.role.value, port: Number(f.port.value) || 0,
      authentication: f.authentication.value, useSsl: f.useSsl.checked, skipCaCheck: f.skipCaCheck.checked, notes: f.notes.value,
      username: f.username.value.trim() || undefined, password: f.password.value || undefined,
    };
    f.password.value = '';
    try { await api('POST', '/api/servers', body); toast('Server saved'); loadServers(); } catch (err) { toast(err.message, true); }
  });

  // ------------------------------------------------------------ migrate form
  function renderMigrateForm() {
    const f = $('#migrateForm');
    const prev = f.sourceId.value;
    const sources = state.servers.filter((s) => s.role !== 'target');
    f.sourceId.innerHTML = sources.length ? sources.map((s) => `<option value="${esc(s.id)}">${esc(s.name)} (${esc(s.host)})</option>`).join('') : '<option value="">— add a server first —</option>';
    if (prev && sources.some((s) => s.id === prev)) f.sourceId.value = prev;
    renderTargets();
  }
  function renderTargets() {
    const f = $('#migrateForm');
    const checked = new Set($$('#targetList input:checked').map((i) => i.value));
    const targets = state.servers.filter((s) => s.role !== 'source' && s.id !== f.sourceId.value);
    $('#targetList').innerHTML = targets.length ? targets.map((s) => `<label class="check"><input type="checkbox" value="${esc(s.id)}" ${checked.has(s.id) ? 'checked' : ''}> ${esc(s.name)} <span class="muted">(${esc(s.host)})</span></label>`).join('')
      : '<div class="empty">No target servers.</div>';
    updateMigrateButton();
  }
  function updateMigrateButton() {
    const n = $$('#targetList input:checked').length;
    $('#runMigrate').textContent = n ? `Migrate to ${n} server${n > 1 ? 's' : ''}` : 'Create backup';
  }
  $('#migrateForm').sourceId.addEventListener('change', renderTargets);
  $('#targetList').addEventListener('change', updateMigrateButton);

  function renderInstallers() {
    const opts = '<option value="">— none (PRTG must already be installed) —</option>' + state.installers.map((i) => `<option>${esc(i.name)}</option>`).join('');
    $$('select[name="InstallerFile"]').forEach((sel) => { const v = sel.value; sel.innerHTML = opts; sel.value = v; });
  }
  async function loadInstallers() { state.installers = arr(await api('GET', '/api/installers')); renderInstallers(); }

  $('#migrateForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const f = e.target;
    if (!f.sourceId.value) return toast('Select a source server', true);
    const targets = $$('#targetList input:checked').map((i) => i.value);
    const options = {
      IncludePrtg: f.IncludePrtg.checked, IncludeHistory: f.IncludeHistory.checked, IncludeVpn: f.IncludeVpn.checked, IncludeDesktop: f.IncludeDesktop.checked,
      ExtraPaths: f.ExtraPaths.value.split(/\r?\n/).map((s) => s.trim()).filter(Boolean),
      StartServices: f.StartServices.checked, HealthTimeoutMinutes: Number(f.HealthTimeoutMinutes.value) || 15, ConnectVpn: f.ConnectVpn.checked,
      AllowDowngrade: f.AllowDowngrade.checked, InstallerFile: f.InstallerFile.value, InstallerArgs: f.InstallerArgs.value,
      RestorePrtg: true, RestoreVpn: true, RestoreDesktop: true, RestoreExtra: true,
    };
    if (targets.length) {
      options.SourceAfter = f.SourceAfter.value;
      const names = targets.map((id) => state.servers.find((s) => s.id === id).name).join(', ');
      const src = state.servers.find((s) => s.id === f.sourceId.value).name;
      if (!confirm(`Migrate ${src} → ${names}?\n\nPRTG will be stopped on the source (${options.SourceAfter}) and the data on each target will be replaced (a rollback copy is kept on the target).`)) return;
      startJob({ type: 'migrate', sourceId: f.sourceId.value, targetIds: targets, options });
    } else {
      options.SourceAfter = 'Restart';
      startJob({ type: 'backup', sourceId: f.sourceId.value, options });
    }
  });

  $('#installerUpload').addEventListener('change', (e) => {
    const file = e.target.files[0]; if (!file) return;
    upload(`/api/installers/upload?name=${encodeURIComponent(file.name)}`, file, (p) => { $('#installerUploadStatus').textContent = `Uploading… ${p}%`; })
      .then(() => { $('#installerUploadStatus').textContent = `${file.name} uploaded`; loadInstallers(); })
      .catch((err) => { $('#installerUploadStatus').textContent = ''; toast(err.message, true); });
    e.target.value = '';
  });

  // ------------------------------------------------------------ backups
  async function loadBackups() { state.backups = arr(await api('GET', '/api/backups')); renderBackups(); renderOverview(); }

  function renderBackups() {
    const tb = $('#backupsTable tbody');
    if (!state.backups.length) { tb.innerHTML = '<tr><td colspan="6" class="empty">No backups yet. Run a backup or migration, or upload a package.</td></tr>'; return; }
    tb.innerHTML = state.backups.map((b) => {
      const m = b.manifest || {};
      const parts = [];
      if (m.prtg && m.prtg.included) parts.push(`<span class="badge info">PRTG ${esc(m.prtg.version || '')}</span>`);
      if (m.vpn && m.vpn.included) parts.push(`<span class="badge">VPN ×${arr(m.vpn.allUsers).length}</span>`);
      if (m.desktop && m.desktop.included) parts.push(`<span class="badge">Desktop ×${arr(m.desktop.users).length}</span>`);
      if (arr(m.extra).length) parts.push(`<span class="badge">Extra ×${arr(m.extra).length}</span>`);
      const dl = `/api/backups/${encodeURIComponent(b.name)}/download?token=${encodeURIComponent(token)}`;
      return `<tr>
        <td><b>${esc(b.name)}</b>${b.sha256 ? `<span class="sub-text" title="SHA256">${esc(b.sha256.slice(0, 16))}…</span>` : ''}</td>
        <td>${esc(b.source || (m.source && m.source.computer) || '–')}</td>
        <td>${parts.join(' ') || '–'}</td>
        <td class="num">${fmtSize(b.size)}</td>
        <td class="num">${esc(fmtDate(b.created))}</td>
        <td><div class="btn-group">
          <a class="btn small" href="${dl}" download>Download</a>
          <button class="btn small" data-act="restore" data-name="${esc(b.name)}">Restore…</button>
          <button class="btn small danger" data-act="del" data-name="${esc(b.name)}">Delete</button>
        </div></td></tr>`;
    }).join('');
  }

  $('#backupsTable').addEventListener('click', async (e) => {
    const b = e.target.closest('button[data-act]'); if (!b) return;
    const name = b.dataset.name;
    if (b.dataset.act === 'del' && confirm(`Delete backup ${name} from the manager?`)) {
      try { await api('DELETE', `/api/backups/${encodeURIComponent(name)}`); toast('Backup deleted'); loadBackups(); } catch (err) { toast(err.message, true); }
    }
    if (b.dataset.act === 'restore') openRestore(name);
  });

  function openRestore(name) {
    const f = $('#restoreForm'); f.reset(); f.dataset.name = name;
    $('#restoreName').textContent = name;
    const targets = state.servers.filter((s) => s.role !== 'source');
    $('#restoreTargets').innerHTML = targets.length ? targets.map((s) => `<label class="check"><input type="checkbox" value="${esc(s.id)}"> ${esc(s.name)} <span class="muted">(${esc(s.host)})</span></label>`).join('') : '<div class="empty">No target servers.</div>';
    renderInstallers();
    $('#restoreDialog').showModal();
  }
  $('#restoreDialog').addEventListener('close', () => {
    if ($('#restoreDialog').returnValue !== 'go') return;
    const f = $('#restoreForm');
    const targets = $$('#restoreTargets input:checked').map((i) => i.value);
    if (!targets.length) return toast('Select at least one target', true);
    startJob({
      type: 'restore', backupName: f.dataset.name, targetIds: targets,
      options: { RestorePrtg: f.RestorePrtg.checked, RestoreVpn: f.RestoreVpn.checked, RestoreDesktop: f.RestoreDesktop.checked, RestoreExtra: f.RestoreExtra.checked, StartServices: f.StartServices.checked, InstallerFile: f.InstallerFile.value },
    });
  });

  function upload(url, file, onProgress) {
    return new Promise((resolve, reject) => {
      const x = new XMLHttpRequest();
      x.open('PUT', url);
      x.setRequestHeader('X-PM-Token', token);
      x.upload.onprogress = (ev) => { if (ev.lengthComputable) onProgress(Math.round((ev.loaded / ev.total) * 100)); };
      x.onload = () => { let d = {}; try { d = JSON.parse(x.responseText); } catch { /* empty */ } x.status < 300 ? resolve(d) : reject(new Error(d.error || `HTTP ${x.status}`)); };
      x.onerror = () => reject(new Error('Upload failed'));
      x.send(file);
    });
  }
  $('#backupUpload').addEventListener('change', (e) => {
    const file = e.target.files[0]; if (!file) return;
    const box = $('#uploadProgress'); box.hidden = false;
    upload(`/api/backups/upload?name=${encodeURIComponent(file.name)}`, file, (p) => { $('i', box).style.width = `${p}%`; $('span', box).textContent = `${file.name} — ${p}%`; })
      .then(() => { toast('Backup uploaded and verified'); loadBackups(); })
      .catch((err) => toast(err.message, true))
      .finally(() => { box.hidden = true; });
    e.target.value = '';
  });

  // ------------------------------------------------------------ jobs
  async function startJob(body) {
    try {
      const r = await api('POST', '/api/jobs', body);
      toast('Job started');
      location.hash = 'jobs';
      await loadJobs();
      selectJob(r.id);
    } catch (err) { toast(err.message, true); }
  }

  async function loadJobs() {
    state.jobs = arr(await api('GET', '/api/jobs'));
    renderJobs(); renderOverview();
  }

  function renderJobs() {
    $('#jobsList').innerHTML = state.jobs.length ? state.jobs.map((j) => `
      <div class="item ${j.id === state.selectedJob ? 'selected' : ''}" data-job="${esc(j.id)}">
        <div style="min-width:0"><div class="t">${esc(j.summary || j.type)}</div><span class="sub-text">${esc(fmtDate(j.created))}</span></div>
        <div style="text-align:right">${statusBadge(j.status)}${j.status === 'running' ? `<div class="progress mini-progress"><i style="width:${j.progress}%"></i></div>` : ''}</div>
      </div>`).join('') : '<div class="empty">No jobs yet.</div>';
  }
  $('#jobsList').addEventListener('click', (e) => { const it = e.target.closest('[data-job]'); if (it) selectJob(it.dataset.job); });

  function selectJob(id) {
    state.selectedJob = id; state.logSince = 0;
    clearTimeout(state.jobTimer);
    $('#jobDetail').innerHTML = '<p class="muted">Loading…</p>';
    renderJobs();
    pollJob(true);
  }

  async function pollJob(first) {
    const id = state.selectedJob; if (!id) return;
    let j;
    try { j = await api('GET', `/api/jobs/${encodeURIComponent(id)}?since=${state.logSince}`); } catch (err) { $('#jobDetail').innerHTML = `<p class="muted">${esc(err.message)}</p>`; return; }
    if (id !== state.selectedJob) return;
    if (first || !$('#jobLog')) {
      $('#jobDetail').innerHTML = `
        <div class="page-head" style="margin:0"><div><h2 style="margin:0">${esc(j.summary || j.type)}</h2><span class="sub-text">${esc(j.id)}</span></div>
        <div class="actions" id="jobActions"></div></div>
        <div class="progress" id="jobProgress"><i></i></div>
        <div class="sub-text" id="jobStep"></div>
        <dl class="kv" id="jobKv"></dl>
        <div id="jobResult"></div>
        <div class="log" id="jobLog"></div>`;
    }
    const pr = $('#jobProgress');
    pr.className = 'progress' + (j.status === 'succeeded' ? ' ok' : j.status === 'failed' ? ' err' : '');
    $('i', pr).style.width = `${j.progress || 0}%`;
    $('#jobStep').textContent = `${j.progress || 0}% · ${j.step || ''}`;
    $('#jobKv').innerHTML = `<dt>Status</dt><dd>${statusBadge(j.status)}</dd><dt>Started</dt><dd>${esc(fmtDate(j.started))}</dd><dt>Finished</dt><dd>${esc(fmtDate(j.finished))}</dd>${j.error ? `<dt>Error</dt><dd style="color:var(--err)">${esc(j.error)}</dd>` : ''}`;
    const active = j.status === 'running' || j.status === 'queued';
    $('#jobActions').innerHTML = (active ? '<button class="btn small danger" id="cancelJob">Cancel</button>' : '')
      + `<a class="btn small" href="/api/jobs/${encodeURIComponent(j.id)}/log?token=${encodeURIComponent(token)}">Download log</a>`;
    const cb = $('#cancelJob');
    if (cb) cb.onclick = async () => { if (confirm('Cancel this job?')) { await api('POST', `/api/jobs/${encodeURIComponent(j.id)}/cancel`); pollJob(); } };
    renderResult(j);

    const log = $('#jobLog');
    const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
    const frag = document.createDocumentFragment();
    arr(j.logs).forEach((l) => {
      const line = document.createElement('div');
      line.className = l.level;
      const t = new Date(l.time);
      line.innerHTML = `<span class="ts">${esc(isNaN(t) ? '' : t.toLocaleTimeString())}</span> [${esc(l.computer)}] ${esc(l.message)}`;
      frag.appendChild(line);
    });
    log.appendChild(frag);
    state.logSince = j.logCount;
    if (atBottom || first) log.scrollTop = log.scrollHeight;

    if (active) state.jobTimer = setTimeout(() => pollJob(), 1500);
    else { loadJobs(); if (j.type !== 'test') { loadBackups(); } else { loadServers(); } }
  }

  function renderResult(j) {
    const el = $('#jobResult'); const r = j.result;
    if (!r || j.type === 'test') { el.innerHTML = ''; return; }
    let html = '';
    if (r.backup) {
      html += `<p style="margin:12px 0 0">Package: <b>${esc(r.backup)}</b> <a class="btn small" href="/api/backups/${encodeURIComponent(r.backup)}/download?token=${encodeURIComponent(token)}">Download</a></p>`;
    }
    const targets = arr(r.targets || (Array.isArray(r) ? r : null));
    if (targets.length) {
      html += '<div class="result-targets">' + targets.map((t) => {
        const rep = t.report || {};
        const b = (v) => `<span class="badge ${v === 'ok' ? 'ok' : v === 'failed' ? 'err' : v === 'skipped' ? '' : 'warn'}">${esc(v || '–')}</span>`;
        return `<div class="rt"><b>${esc(t.target)}</b> ${t.ok ? '<span class="badge ok">OK</span>' : '<span class="badge err">errors</span>'}
          <div class="sub-text">PRTG ${b(rep.Prtg)} · VPN ${b(rep.Vpn)} · Desktop ${b(rep.Desktop)} · Extra ${b(rep.Extra)}</div>
          ${rep.WebUrl ? `<div class="sub-text">Web: ${esc(rep.WebUrl)}</div>` : ''}${t.error ? `<div class="sub-text" style="color:var(--err)">${esc(t.error)}</div>` : ''}</div>`;
      }).join('') + '</div>';
    }
    el.innerHTML = html;
  }

  // ------------------------------------------------------------ boot
  async function refreshAll() {
    try {
      await loadInfo();
      await Promise.all([loadServers(), loadBackups(), loadInstallers(), loadJobs()]);
    } catch (err) { if (err.message !== 'Unauthorized') toast(err.message, true); }
  }
  show(location.hash.slice(1) || 'overview');
  if (!token) askToken(); else refreshAll();
  setInterval(() => { if (token && document.visibilityState === 'visible') loadJobs().catch(() => {}); }, 5000);
})();
