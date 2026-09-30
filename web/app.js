/* PRTG Manager dashboard - vanilla JS, no build step. */
(() => {
  'use strict';

  // ------------------------------------------------------------ helpers
  const $ = (s, r = document) => r.querySelector(s);
  const $$ = (s, r = document) => [...r.querySelectorAll(s)];
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fmtSize = (b) => { if (!b && b !== 0) return '–'; const u = ['B', 'KB', 'MB', 'GB', 'TB']; let i = 0; while (b >= 1024 && i < u.length - 1) { b /= 1024; i++; } return `${b.toFixed(i ? 1 : 0)} ${u[i]}`; };
  // dates and times always with the digits 0-9 and one fixed order (DigitalVPS UI rule), whatever the browser language
  const p2 = (n) => String(n).padStart(2, '0');
  const fmtTime = (d) => (isNaN(d) ? '' : `${p2(d.getHours())}:${p2(d.getMinutes())}:${p2(d.getSeconds())}`);
  const fmtDate = (s) => { if (!s) return '–'; const d = new Date(s); return isNaN(d) ? s : `${d.getFullYear()}-${p2(d.getMonth() + 1)}-${p2(d.getDate())} ${p2(d.getHours())}:${p2(d.getMinutes())}`; };
  const ago = (s) => { if (!s) return ''; const m = Math.round((Date.now() - new Date(s)) / 60000); if (m < 1) return 'just now'; if (m < 60) return `${m} min ago`; const h = Math.round(m / 60); return h < 24 ? `${h} h ago` : `${Math.round(h / 24)} d ago`; };
  const arr = (v) => (v == null ? [] : Array.isArray(v) ? v : [v]);
  const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
  const TYPE_LABEL = { full: 'Full', graphs: 'History', devices: 'Devices', notifications: 'Notifications', triggers: 'Triggers', license: 'License', files: 'Files', vpn: 'VPN (old)' };

  function toast(msg, isErr = false) {
    const el = document.createElement('div');
    el.className = 'toast' + (isErr ? ' err' : '');
    if (msg instanceof Error) {
      el.textContent = msg.message;
      if (msg.hint) { const h = document.createElement('span'); h.className = 'hint-line'; h.textContent = msg.hint; el.appendChild(h); }
    } else el.textContent = msg;
    $('#toasts').appendChild(el);
    setTimeout(() => el.remove(), isErr ? 9000 : 3500);
  }
  const fail = (err) => toast(err, true);

  // Confirmation in a dialog of the page (not the browser's confirm box): the first line is the question,
  // the rest explains the consequences. opts: ok (button text), danger (red button), type (text the user
  // has to type first - for changes that replace data), title.
  function ask(message, opts = {}) {
    const d = $('#confirmDialog');
    if (!d || typeof d.showModal !== 'function') return Promise.resolve(window.confirm(message));
    const lines = String(message).split('\n');
    $('#cfTitle').textContent = opts.title || lines[0];
    $('#cfBody').textContent = (opts.title ? lines : lines.slice(1)).join('\n').trim();
    const ok = $('#cfOk'); const box = $('#cfTypeBox'); const inp = $('#cfTypeInput');
    ok.textContent = opts.ok || 'Confirm';
    ok.className = `btn ${opts.danger ? 'destructive' : 'primary'}`;
    box.hidden = !opts.type; inp.value = '';
    if (opts.type) { $('#cfTypeWord').textContent = opts.type; ok.disabled = true; inp.oninput = () => { ok.disabled = inp.value.trim() !== opts.type; }; } else { ok.disabled = false; inp.oninput = null; }
    return new Promise((resolve) => {
      d.returnValue = '';
      d.addEventListener('close', () => resolve(d.returnValue === 'ok' && (!opts.type || inp.value.trim() === opts.type)), { once: true });
      d.showModal();
      (opts.type ? inp : (opts.danger ? $('#cfCancel') : ok)).focus();
    });
  }

  // ------------------------------------------------------------ DigitalVPS shell: theme, menu on small screens
  function setTheme(t) {
    const dark = t === 'dark' || (t !== 'light' && window.matchMedia('(prefers-color-scheme: dark)').matches);
    document.documentElement.dataset.theme = dark ? 'dark' : 'light';
    const b = $('#themeBtn'); b.innerHTML = `<svg><use href="#i-${dark ? 'sun' : 'moon'}"/></svg>`;
    b.title = dark ? 'Light mode' : 'Dark mode'; b.setAttribute('aria-label', b.title);
  }
  let savedTheme = ''; try { savedTheme = localStorage.getItem('dv-theme') || ''; } catch (e) { /* no storage */ }
  setTheme(savedTheme);
  $('#themeBtn').addEventListener('click', () => {
    const next = document.documentElement.dataset.theme === 'dark' ? 'light' : 'dark';
    try { localStorage.setItem('dv-theme', next); } catch (e) { /* no storage */ }
    setTheme(next);
  });
  const small = window.matchMedia('(max-width: 900px)');
  const setNav = (open) => { $('#app').classList.toggle('nav-open', open); $('#navOpen').setAttribute('aria-expanded', String(open)); if (open) $('#sidebar nav a.active')?.focus(); };
  const setFold = (folded) => { $('#app').classList.toggle('nav-folded', folded); $$('#sidebar nav a').forEach((a) => { a.title = folded ? a.textContent.trim() : ''; }); };
  try { setFold(localStorage.getItem('dv-nav') === 'folded'); } catch (e) { /* no storage */ }
  // one button: a drawer on small screens, fold / unfold the menu on large ones
  $('#navOpen').addEventListener('click', () => {
    if (small.matches) { setNav(true); return; }
    const folded = !$('#app').classList.contains('nav-folded'); setFold(folded);
    try { localStorage.setItem('dv-nav', folded ? 'folded' : 'open'); } catch (e) { /* no storage */ }
  });
  $('#navClose').addEventListener('click', () => setNav(false));
  $('#navScrim').addEventListener('click', () => setNav(false));
  $$('#sidebar nav a').forEach((a) => a.addEventListener('click', () => setNav(false)));
  document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && $('#app').classList.contains('nav-open')) setNav(false); });

  async function api(method, path, body) {
    const opts = { method, headers: {} };
    if (body !== undefined) { opts.headers['Content-Type'] = 'application/json'; opts.body = JSON.stringify(body); }
    let res;
    try { res = await fetch(path, opts); } catch (e) { const er = new Error(`${method} ${path} failed: the dashboard does not answer (${e.message}).`); er.hint = 'Is PRTG Manager still running? Start it with the "PRTG Manager" shortcut.'; throw er; }
    const data = await res.json().catch(() => ({}));
    if (!res.ok) { const er = new Error(data.error || `${method} ${path} failed with HTTP ${res.status}`); er.hint = data.hint; er.status = res.status; throw er; }
    return data;
  }

  // a button shows that it works and cannot be pressed twice
  async function busy(btn, fn) {
    if (btn) { btn.disabled = true; btn.classList.add('busy'); }
    try { return await fn(); } finally { if (btn) { btn.disabled = false; btn.classList.remove('busy'); } }
  }

  // runs a job in the background without leaving the page; onProgress gets the job each poll
  async function runJobQuiet(body, onProgress) {
    const r = await api('POST', '/api/jobs', body);
    for (;;) {
      const j = await api('GET', `/api/jobs/${encodeURIComponent(r.id)}?since=0`);
      if (onProgress) onProgress(j);
      if (!['running', 'queued'].includes(j.status)) return j;
      await sleep(1200);
    }
  }
  const lastLog = (j) => { const l = arr(j && j.logs).filter((x) => x.level !== 'DEBUG').slice(-1)[0]; return l ? l.message : ''; };

  const statusBadge = (s) => {
    const map = { succeeded: 'ok', failed: 'err', running: 'info', queued: '', cancelled: 'warn', interrupted: 'warn' };
    return `<span class="badge ${map[s] ?? ''}">${esc(s)}</span>`;
  };

  // ------------------------------------------------------------ state
  const state = { servers: [], backups: [], installers: [], jobs: [], ports: {}, selectedJob: null, logSince: 0, jobTimer: null, license: {} };

  // ------------------------------------------------------------ navigation
  function show(view) {
    $$('.view').forEach((v) => v.classList.toggle('active', v.id === `view-${view}`));
    $$('nav a').forEach((a) => { a.classList.toggle('active', a.dataset.view === view); if (a.dataset.view === view) { a.setAttribute('aria-current', 'page'); $('#crumbTitle').textContent = a.textContent.trim().replace(/\s*\d+$/, ''); document.title = `${$('#crumbTitle').textContent} · PRTG Manager`; } else a.removeAttribute('aria-current'); });
    if (view === 'jobs') loadJobs().catch(fail);
    if (view === 'logs') loadLogs();
    if (view === 'backups') loadBackups().catch(fail);
    if (view === 'license') renderLicenseServers();
  }

  // ------------------------------------------------------------ logs & audit
  async function loadLogs() {
    try {
      const [audit, mlog] = await Promise.all([api('GET', '/api/logs/audit'), api('GET', '/api/logs/manager')]);
      const rows = arr(audit);
      $('#auditTable tbody').innerHTML = rows.length ? rows.map((a) => {
        const d = a.data || {};
        const details = Object.keys(d).filter((k) => d[k] !== null && d[k] !== '').map((k) => `${esc(k)}=<b>${esc(Array.isArray(d[k]) ? d[k].join(',') : (typeof d[k] === 'object' ? JSON.stringify(d[k]) : d[k]))}</b>`).join(' · ');
        return `<tr><td class="num">${esc(fmtDate(a.time))}</td><td><span class="badge info">${esc(a.action)}</span></td><td class="wrap">${details}</td><td class="nowrap">${esc(a.user)}</td></tr>`;
      }).join('') : '<tr><td colspan="4" class="empty">No audit entries yet.</td></tr>';
      const box = $('#managerLog');
      box.innerHTML = arr(mlog.lines).map((l) => {
        const cls = /\[ERROR/.test(l) ? 'ERROR' : /\[WARN/.test(l) ? 'WARN' : /\[AUDIT/.test(l) ? 'OK' : '';
        return `<div class="${cls}">${esc(l)}</div>`;
      }).join('') || '<div>Empty.</div>';
      box.scrollTop = box.scrollHeight;
    } catch (err) { fail(err); }
  }
  $('#refreshLogs').addEventListener('click', (e) => busy(e.currentTarget, loadLogs));
  $('#diagBtn2').addEventListener('click', () => { toast('Building diagnostics bundle…'); location.href = '/api/diagnostics'; });

  // ------------------------------------------------------------ servers in the sidebar
  function renderSideAgents() {
    $('#sideAgents').innerHTML = state.servers.length ? '<b style="color:var(--nav-dim);font-weight:600">Servers</b>' + state.servers.map((s) => {
      const on = s.agent && s.agent.connected;
      const tag = s.transport === 'local' ? '<span class="badge ok">this computer</span>'
        : s.transport === 'winrm' ? '<span class="badge info">WinRM</span>'
        : s.transport === 'wireguard' ? '<span class="badge info">WireGuard</span>'
        : s.transport === 'ipip' ? '<span class="badge info">IPIP</span>'
        : on ? `<span class="badge ok">agent ${esc(s.agent.state || 'on')}</span>` : '<span class="badge">agent off</span>';
      return `<div class="row"><span>${esc(s.name)}</span>${tag}</div>`;
    }).join('') : '';
  }
  function serverLine(s) {
    if (!s) return '';
    if (s.transport === 'local') return `<div class="srvline"><span class="badge info">Local</span> this computer · no connection needed${state.info && !state.info.elevated ? ' · <span class="badge err">PRTG Manager is not running as administrator</span>' : ''}</div>`;
    if (s.transport === 'winrm') return `<div class="srvline"><span class="badge info">WinRM</span> ${esc(s.host)}</div>`;
    if (s.transport === 'wireguard') return `<div class="srvline"><span class="badge info">WireGuard</span> ${esc(s.host)} · commands over RDP</div>`;
    if (s.transport === 'ipip') return `<div class="srvline"><span class="badge info">IPIP</span> ${esc(s.host)} · commands over RDP</div>`;
    const on = s.agent && s.agent.connected;
    return `<div class="srvline"><span class="badge info">RDP</span> ${esc(s.host)}:${esc(s.rdpPort || 3389)} · ${on ? `<span class="badge ok">agent connected (${esc(s.agent.computer)})</span>` : '<span class="badge warn">agent not running — press RDP on the Servers page</span>'}</div>`;
  }
  window.addEventListener('hashchange', () => show(location.hash.slice(1) || 'overview'));
  $$('[data-goto]').forEach((b) => b.addEventListener('click', () => { location.hash = b.dataset.goto; }));

  // ------------------------------------------------------------ info / overview
  async function loadInfo() {
    const i = await api('GET', '/api/info');
    state.info = i;
    $('#version').textContent = `v${i.version}`;
    const initials = (s, d) => String(s || '').replace(/[^A-Za-z0-9]/g, '').slice(0, 2).toUpperCase() || d;
    const user = String(i.user || '').split('\\').pop();
    $('#managerInfo').innerHTML = `<span class="avatar" aria-hidden="true">${esc(initials(i.manager, 'PM'))}</span><div><b>${esc(i.manager)}</b><span class="role">Manager computer</span><br>${esc(i.user)}</div>`;
    $('#identityName').textContent = user || 'Manager';
    $('#identityUser').textContent = i.elevated === false ? 'not running as administrator' : `administrator on ${i.manager}`;
    $('#identityAvatar').textContent = initials(user, 'PM');
    $('#backupsPath').textContent = `Packages stored on the manager in ${i.backupsPath}`;
  }

  function renderOverview() {
    $('#statServers').textContent = state.servers.length;
    const src = state.servers.filter((s) => s.role === 'source').length; const tgt = state.servers.filter((s) => s.role === 'target').length;
    const both = state.servers.length - src - tgt;
    $('#statServersNote').textContent = state.servers.length ? [src && `${src} source`, tgt && `${tgt} target`, both && `${both} source & target`].filter(Boolean).join(' · ') : 'none added yet';
    $('#statBackups').textContent = state.backups.length;
    const total = state.backups.reduce((n, b) => n + (Number(b.size) || 0), 0);
    $('#statBackupsNote').textContent = state.backups.length ? `${fmtSize(total)} in total` : 'no packages yet';
    const runningJobs = state.jobs.filter((j) => j.status === 'running' || j.status === 'queued');
    const running = runningJobs.length;
    $('#statRunning').textContent = running;
    $('#statRunningNote').textContent = running ? (runningJobs[0].summary || runningJobs[0].type) : 'nothing is running';
    const pill = $('#runningPill'); pill.hidden = !running; pill.textContent = running;
    const last = state.jobs[0];
    $('#statLast').innerHTML = last ? statusBadge(last.status) : '';
    $('#statLastWhen').textContent = last ? (ago(last.created) || fmtDate(last.created)) : '–';
    $('#statLastNote').textContent = last ? (last.summary || last.type) : 'no jobs yet';
    $('#statLastTone').className = `tone ${last ? ({ succeeded: 'green', failed: 'red', running: 'blue', queued: 'blue', cancelled: 'amber', interrupted: 'amber' }[last.status] || '') : ''}`;
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
    renderServers(); renderMigrateForm(); renderOverview(); renderLicenseServers();
  }

  async function checkPorts(showToast) {
    if (!state.servers.length) return;
    try {
      state.ports = await api('GET', '/api/servers/ports');
      renderServers();
      if (showToast) toast('Ports checked');
    } catch (err) { fail(err); }
  }
  $('#checkPortsBtn').addEventListener('click', (e) => busy(e.currentTarget, () => checkPorts(true)));

  function portBadges(s) {
    const live = state.ports[s.id];
    const last = s.lastStatus && s.lastStatus.ports;
    const one = (label, info, fallbackPort) => {
      if (!info) return `<span class="badge" title="not checked yet">${label} ${fallbackPort}</span>`;
      return `<span class="badge ${info.open ? 'ok' : 'err'}" title="${info.open ? 'reachable' : 'not reachable'} from the manager">${label} ${esc(info.port)}</span>`;
    };
    const rdp = live ? live.rdp : last ? { port: last.rdpPort, open: last.rdp } : null;
    const win = live ? live.winrm : last ? { port: last.winrmPort, open: last.winrm } : null;
    const winDefault = s.port || (s.useSsl ? 5986 : 5985);
    return `<div class="ports">${one('RDP', rdp, s.rdpPort || 3389)}${one('WinRM', win, winDefault)}</div>`;
  }

  function methodResult(label, v) {
    if (v === null || v === undefined) return `<span class="badge" title="not tested yet">${label} –</span>`;
    const ok = typeof v === 'object' ? v.ok : v;
    const when = typeof v === 'object' && v.checked ? ago(v.checked) : '';
    const detail = typeof v === 'object' && v.detail ? v.detail : '';
    return `<span class="badge ${ok ? 'ok' : 'err'}" title="${esc(detail)}${when ? ` · ${esc(when)}` : ''}">${label} ${ok ? '✓' : '✗'}${when ? ` <small>${esc(when)}</small>` : ''}</span>`;
  }

  function licenseBadge(ls) {
    if (!ls || !ls.Known) return '';
    if (ls.NeedsActivation && !ls.Name) return `<span class="badge warn" title="${esc(ls.Edition)} · No license is installed on this server.">license: none</span>`;
    if (ls.NeedsActivation) return `<span class="badge err" title="${esc(ls.Edition)}${ls.LastError ? ` · ${esc(ls.LastError)}` : ''} · The license must be activated for this server.">license: activation needed</span>`;
    return `<span class="badge ok" title="${esc(ls.Edition)} · ${esc(ls.MaxSensors)} sensors">license ok</span>`;
  }

  function renderServers() {
    const tb = $('#serversTable tbody');
    if (!state.servers.length) { tb.innerHTML = '<tr><td colspan="8" class="empty">No servers yet — add the source PRTG server and at least one target.</td></tr>'; return; }
    tb.innerHTML = state.servers.map((s) => {
      const st = s.lastStatus; const info = st && st.info;
      let test = '<span class="badge">never</span>';
      if (st) {
        const m = st.methods || {};
        test = `${st.ok ? '<span class="badge ok" title="at least one connection method works">PASS</span>' : `<span class="badge err" title="${esc(st.error)}">FAIL</span>`}
          <div class="ports" style="margin-top:4px">${s.transport === 'local' ? methodResult('Local', m.local) : methodResult('RDP', m.rdp) + methodResult('WinRM', m.winrm)}</div>`;
      }
      let prtg = '–';
      const endpoints = arr(info && info.Prtg && info.Prtg.ListenEndpoints);
      const localOnly = endpoints.length > 0 && endpoints.every((e) => /^(127\.0\.0\.1|::1):/.test(e));
      if (info) {
        if (info.Prtg && info.Prtg.Installed) {
          const net = localOnly ? '<span class="badge err" title="PRTG only answers on 127.0.0.1">not reachable from network</span>' : '';
          prtg = `${esc(info.Prtg.Version)}<span class="sub-text">${esc(info.PrtgDataGB)} GB data · ${esc(info.Prtg.CoreStatus)}</span><div class="ports" style="margin-top:4px">${licenseBadge(info.PrtgLicenseState)}${net}</div>`;
        } else { prtg = '<span class="badge warn">not installed</span>'; }
      }
      const cred = s.transport === 'local' ? '<span class="badge" title="PRTG Manager works on this computer with its own rights">not needed</span>' : s.hasCredential ? '<span class="badge ok">saved</span>' : '<span class="badge" title="The current Windows identity of the manager is used">Windows identity</span>';
      const method = s.transport === 'local' ? '<span class="badge info">Local</span>'
        : s.transport === 'winrm' ? '<span class="badge info">WinRM</span>'
        : s.transport === 'wireguard' ? '<span class="badge info">WireGuard</span>'
        : s.transport === 'ipip' ? '<span class="badge info">IPIP</span>'
        : '<span class="badge info">RDP</span>';
      const ag = s.agent && s.agent.connected
        ? `<span class="badge ok" title="${esc(s.agent.computer)} · ${esc(s.agent.user)}">agent ${esc(s.agent.state || 'on')}</span>`
        : (s.transport === 'winrm' || s.transport === 'local' ? '' : '<span class="badge" title="Only needed while a job runs">agent off</span>');
      const needsAdmin = s.transport === 'local' && state.info && !state.info.elevated
        ? '<div class="ports" style="margin-top:4px"><span class="badge err" title="Backup and restore of this computer need administrator rights. Close PRTG Manager and start it with Run as administrator.">start PRTG Manager as administrator</span></div>' : '';
      return `<tr>
        <td><b>${esc(s.name)}</b>${info ? `<span class="sub-text">${esc(info.OS)}</span>` : ''}</td>
        <td class="num">${esc(s.host)}${s.useSsl ? ' <span class="badge info">HTTPS</span>' : ''}</td>
        <td>${esc(s.role)}<span class="sub-text">${method} ${ag}</span>${needsAdmin}</td><td>${s.transport === 'local' ? '–' : portBadges(s)}</td><td>${cred}</td><td>${test}</td><td>${prtg}</td>
        <td><div class="btn-group">
          ${s.transport === 'local' ? `<button class="btn small" data-act="test-local" data-id="${esc(s.id)}">Test</button>` : `<button class="btn small" data-act="rdp" data-id="${esc(s.id)}" title="Open Remote Desktop to ${esc(s.host)}:${esc(s.rdpPort || 3389)} and start the agent">RDP</button>
          <button class="btn small" data-act="test-rdp" data-id="${esc(s.id)}">Test RDP</button>
          <button class="btn small" data-act="test-winrm" data-id="${esc(s.id)}">Test WinRM</button>`}
          ${localOnly && s.role !== 'source' && s.transport === 'winrm' ? `<button class="btn small primary" data-act="rebind" data-id="${esc(s.id)}" title="PRTG on this server only answers on 127.0.0.1 because its web server is still bound to the old server's address. This binds it to this server's address and restarts PRTG.">Make PRTG reachable</button>` : ''}
          ${info && info.Prtg && info.Prtg.Installed ? `<button class="btn small" data-act="license" data-id="${esc(s.id)}" title="License state, trial / bought key, backup, restore, removal">License</button>` : ''}
          <button class="btn small" data-act="edit" data-id="${esc(s.id)}">Edit</button>
          <button class="btn small danger" data-act="del" data-id="${esc(s.id)}">Delete</button>
        </div></td></tr>`;
    }).join('');
  }

  async function copyText(text) {
    try { await navigator.clipboard.writeText(text); return true; } catch { return false; }
  }

  $('#serversTable').addEventListener('click', async (e) => {
    const b = e.target.closest('button[data-act]'); if (!b) return;
    const s = state.servers.find((x) => x.id === b.dataset.id);
    if (!s) return fail(new Error('This server is no longer in the list - reload the page.'));
    if (b.dataset.act === 'test-local') startJob({ type: 'test', mode: 'auto', serverIds: [s.id] }, b);
    if (b.dataset.act === 'test-rdp') startJob({ type: 'test', mode: 'rdp', serverIds: [s.id] }, b);
    if (b.dataset.act === 'test-winrm') startJob({ type: 'test', mode: 'winrm', serverIds: [s.id] }, b);
    if (b.dataset.act === 'license') { state.license.serverId = s.id; location.hash = 'license'; }
    if (b.dataset.act === 'rebind' && await ask(`Bind the PRTG web server on "${s.name}" to this server's address (${s.host}) and restart PRTG there?\n\nPRTG is unavailable for about a minute while it restarts.`, { ok: 'Bind and restart PRTG' })) startJob({ type: 'rebind', serverIds: [s.id] }, b);
    if (b.dataset.act === 'rdp') {
      await busy(b, async () => {
        try {
          const r = await api('POST', `/api/servers/${encodeURIComponent(s.id)}/rdp`);
          const copied = await copyText(r.agentCommand);
          $('#agentServer').textContent = `${s.name} (${r.target})`;
          $('#agentCmd').textContent = r.agentCommand;
          $('#agentDialog').showModal();
          toast(copied ? 'Remote Desktop opened — agent command copied to the clipboard' : 'Remote Desktop opened');
        } catch (err) { fail(err); }
      });
    }
    if (b.dataset.act === 'edit') openServerDialog(s);
    if (b.dataset.act === 'del' && await ask(`Delete server "${s.name}" and its saved credential?\n\nOnly the entry in PRTG Manager is removed - nothing changes on the server itself. Backups of this server stay on the manager.`, { ok: 'Delete server', danger: true })) {
      await busy(b, async () => { try { await api('DELETE', `/api/servers/${encodeURIComponent(s.id)}`); toast('Server deleted'); await loadServers(); } catch (err) { fail(err); } });
    }
  });
  $('#copyAgentCmd').addEventListener('click', async () => { toast((await copyText($('#agentCmd').textContent)) ? 'Copied' : 'Copy failed — select the text manually'); });
  $('#addServerBtn').addEventListener('click', () => openServerDialog(null));
  $('#addLocalBtn').addEventListener('click', (e) => busy(e.currentTarget, async () => {
    if (state.servers.some((s) => s.transport === 'local')) return toast('This computer is already in the list');
    try {
      await api('POST', '/api/servers', { name: (state.info && state.info.manager) || 'This computer', host: 'localhost', role: 'both', transport: 'local' });
      toast('This computer was added'); await loadServers();
    } catch (err) { fail(err); }
  }));
  function syncServerForm() {
    const f = $('#serverForm');
    const local = f.transport.value === 'local';
    $$('#serverForm .remote-only').forEach((el) => { el.hidden = local; });
    if (local) f.host.value = 'localhost';
    f.host.readOnly = local;
  }
  $('#serverForm').transport.addEventListener('change', syncServerForm);
  $('#testAllBtn').addEventListener('click', (e) => {
    if (!state.servers.length) return fail(new Error('Add a server first.'));
    startJob({ type: 'test', mode: 'auto', serverIds: state.servers.map((s) => s.id) }, e.currentTarget);
  });

  function openServerDialog(s) {
    const f = $('#serverForm'); f.reset();
    $('#serverDialogTitle').textContent = s ? `Edit ${s.name}` : 'Add server';
    f.id.value = s ? s.id : '';
    f.transport.value = 'rdp';
    if (s) {
      f.name.value = s.name; f.host.value = s.host; f.role.value = s.role || 'both'; f.port.value = s.port || 0; f.rdpPort.value = s.rdpPort || 3389;
      f.transport.value = ['local', 'winrm', 'wireguard', 'ipip'].includes(s.transport) ? s.transport : 'rdp';
      f.authentication.value = s.authentication || 'Default'; f.useSsl.checked = !!s.useSsl; f.skipCaCheck.checked = !!s.skipCaCheck; f.notes.value = s.notes || '';
    }
    syncServerForm();
    $('#serverDialog').showModal();
  }
  $('#serverDialog').addEventListener('close', async () => {
    if ($('#serverDialog').returnValue !== 'save') return;
    const f = $('#serverForm');
    const body = {
      id: f.id.value || undefined, name: f.name.value.trim(), host: f.host.value.trim(), role: f.role.value, port: Number(f.port.value) || 0,
      rdpPort: Number(f.rdpPort.value) || 3389, transport: f.transport.value,
      authentication: f.authentication.value, useSsl: f.useSsl.checked, skipCaCheck: f.skipCaCheck.checked, notes: f.notes.value,
      username: f.username.value.trim() || undefined, password: f.password.value || undefined,
    };
    f.password.value = '';
    try { await api('POST', '/api/servers', body); toast('Server saved'); await loadServers(); checkPorts(false); } catch (err) { fail(err); }
  });

  // ------------------------------------------------------------ backup & migrate form
  const TYPE_HINT = {
    full: 'Everything PRTG needs on a new server. With targets ticked this is a migration.',
    graphs: 'Only the history (graph data). PRTG keeps running.',
    devices: 'Only the device tree. Restore adds missing devices (merge) or also updates existing ones (overwrite).',
    notifications: 'Only notification templates and their schedules.',
    triggers: 'Only the triggers of all objects.',
    license: 'Only the license - always encrypted with a backup password.',
  };
  const backupType = () => ($('#migrateForm').querySelector('input[name="backupType"]:checked') || {}).value || 'full';

  function syncBackupType() {
    const f = $('#migrateForm'); const t = backupType();
    $$('#migrateForm [data-for]').forEach((el) => { el.hidden = el.dataset.for !== t; });
    $('#typeHint').textContent = TYPE_HINT[t] || '';
    const enc = f.Encrypt;
    if (t === 'license') {
      if (!enc.checked) enc.dataset.forced = '1';
      enc.checked = true; enc.disabled = true;
    } else {
      // the tick the License type forced goes away with it; one the user set stays
      if (enc.dataset.forced) { enc.checked = false; delete enc.dataset.forced; }
      enc.disabled = false;
    }
    $('#pwFields').hidden = !enc.checked;
    updateMigrateButton();
  }
  $$('#migrateForm input[name="backupType"]').forEach((r) => r.addEventListener('change', syncBackupType));
  $('#migrateForm').Encrypt.addEventListener('change', syncBackupType);

  function renderMigrateForm() {
    const f = $('#migrateForm');
    const prev = f.sourceId.value;
    const sources = state.servers.filter((s) => s.role !== 'target');
    f.sourceId.innerHTML = sources.length ? sources.map((s) => `<option value="${esc(s.id)}">${esc(s.name)} (${esc(s.host)})</option>`).join('') : '<option value="">— add a server first —</option>';
    if (prev && sources.some((s) => s.id === prev)) f.sourceId.value = prev;
    let line = $('#sourceLine');
    if (!line) { line = document.createElement('div'); line.id = 'sourceLine'; f.sourceId.closest('.field').after(line); }
    line.innerHTML = serverLine(state.servers.find((s) => s.id === f.sourceId.value));
    renderTargets();
    renderSideAgents();
  }
  function renderTargets() {
    const f = $('#migrateForm');
    const checked = new Set($$('#targetList input:checked').map((i) => i.value));
    const targets = state.servers.filter((s) => s.role !== 'source' && s.id !== f.sourceId.value);
    $('#targetList').innerHTML = targets.length ? targets.map((s) => `<label class="check"><input type="checkbox" value="${esc(s.id)}" ${checked.has(s.id) ? 'checked' : ''}> <span><b>${esc(s.name)}</b>${serverLine(s)}</span></label>`).join('')
      : '<div class="empty">No target servers.</div>';
    updateMigrateButton();
  }
  function updateMigrateButton() {
    const t = backupType();
    const n = t === 'full' ? $$('#targetList input:checked').length : 0;
    $('#runMigrate').textContent = n ? `Migrate to ${n} server${n > 1 ? 's' : ''}` : `Create ${TYPE_LABEL[t].toLowerCase()} backup`;
    renderMigrateSummary();
  }

  function renderMigrateSummary() {
    const f = $('#migrateForm');
    const t = backupType();
    const src = state.servers.find((s) => s.id === f.sourceId.value);
    const yes = (on, text) => `<li class="${on ? '' : 'no'}">${on ? '✓' : '✗'} ${text}</li>`;
    const enc = f.Encrypt.checked;
    if (t !== 'full') {
      let html = `<h3>What this backup does</h3><ul><li><b>Source:</b> ${src ? esc(src.name) : '–'} — ${t === 'graphs' ? 'history copied from a VSS snapshot, PRTG keeps running' : 'read from the configuration, nothing is changed or written on the server'}</li>`;
      html += `<li><b>Contents:</b> ${esc(TYPE_HINT[t])}</li>`;
      if (t === 'graphs') html += `<li><b>Days:</b> ${Number(f.HistoryDays.value) > 0 ? `the last ${esc(f.HistoryDays.value)}` : 'all'}</li>`;
      html += `<li><b>Encrypted:</b> ${t === 'license' ? 'yes - the license is encrypted on the server' : enc ? 'yes (AES-256 + HMAC)' : 'no'}</li></ul>`;
      $('#migrateSummary').innerHTML = html; return;
    }
    const targets = $$('#targetList input:checked').map((i) => state.servers.find((s) => s.id === i.value)).filter(Boolean);
    const prtg = f.IncludePrtg.checked;
    const chosen = f.transfer.value;
    const savedModes = [...new Set([src, ...targets].filter(Boolean).map((s) => s.transport).filter((x) => x === 'wireguard' || x === 'ipip'))];
    const transfer = chosen || (savedModes.length === 1 ? savedModes[0] : '');
    const viaTunnel = transfer === 'wireguard' || transfer === 'ipip';
    const tunnelName = transfer === 'ipip' ? 'an IPIP tunnel (10.66.67.0/24)' : 'a WireGuard tunnel (10.66.66.0/24)';
    const pathText = viaTunnel
      ? `sent with WinRM over ${tunnelName} straight to the target's tunnel address — <b>not through this computer</b>`
      : (transfer === 'rdp' ? 'copied through this computer over RDP' : (transfer === 'winrm' ? 'copied through this computer over WinRM' : 'copied with each server\'s saved RDP or WinRM method'));
    $('#transferHint').textContent = viaTunnel
      ? `${transfer === 'ipip' ? 'IPIP' : 'WireGuard'}: WinRM (TCP 5985) runs between the two Windows servers on ${transfer === 'ipip' ? '10.66.67.0/24' : '10.66.66.0/24'}. Commands still use each server's saved RDP or WinRM method. The backup is not stored on this computer.`
      : 'RDP and WinRM copy the files through this computer. WireGuard and IPIP build a tunnel between the two servers and copy only there. This computer sends commands and does not keep the backup.';
    let html = '<h3>What this job will do</h3><ul>';
    html += `<li><b>Source:</b> ${src ? esc(src.name) : '–'} — ${f.NoTouch.checked ? `<b>not touched</b> (PRTG keeps running, ${pathText})` : `PRTG is stopped (${esc(f.SourceAfter.value)}), ${pathText}`}</li>`;
    html += `<li><b>Target(s):</b> ${targets.length ? targets.map((x) => esc(x.name)).join(', ') : '<i>none — backup only</i>'}</li></ul>`;
    html += '<h3>Copied</h3><ul>';
    html += yes(prtg, 'PRTG configuration — all probes, groups, devices, sensors, <b>notifications</b>, <b>triggers</b>, users, schedules, maps, reports');
    html += yes(prtg, 'PRTG registry, SSL certificate, custom sensors, notification scripts, lookups, MIBs, device templates');
    html += yes(prtg && f.IncludeProgram.checked, 'PRTG program files + Windows services (clone, no installer)');
    html += yes(prtg && f.CopyLicense.checked, 'PRTG license key (PRTG asks for a new activation on the new server)');
    html += yes(prtg && f.IncludeHistory.checked, 'Historic monitoring data');
    html += yes(f.IncludeDesktop.checked, 'Desktop files of every user');
    const extra = f.ExtraPaths.value.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    if (extra.length) html += yes(true, `Extra: ${extra.map(esc).join(', ')}`);
    html += yes(enc, 'Package encrypted with the backup password');
    html += '</ul><h3>Not copied</h3><ul>';
    html += `<li class="no">${f.IncludeLogs.checked ? '' : '✗ PRTG log files · '}${f.IncludeAutoBackups.checked ? '' : '✗ old automatic config copies · '}✗ cache &amp; temp files · ✗ Windows VPN connections (use VPN Manager) · ✗ anything else on the disk</li></ul>`;
    if (targets.length) html += `<h3>On the target(s)</h3><ul><li>${f.OpenFirewall.checked ? 'open firewall · ' : ''}${f.StartServices.checked ? 'start PRTG and verify it is fully up' : 'do not start PRTG'} · rollback copy of any existing PRTG data${f.AutoRollback.checked ? ', put back automatically if PRTG does not come up' : ''}</li></ul>`;
    $('#migrateSummary').innerHTML = html;
  }
  $('#migrateForm').sourceId.addEventListener('change', () => { renderMigrateForm(); });
  $('#targetList').addEventListener('change', updateMigrateButton);
  $('#migrateForm').addEventListener('change', renderMigrateSummary);
  $('#migrateForm').addEventListener('input', renderMigrateSummary);

  function renderInstallers() {
    const opts = '<option value="">— none (use the clone) —</option>' + state.installers.map((i) => `<option>${esc(i.name)}</option>`).join('');
    $$('select[name="InstallerFile"]').forEach((sel) => { const v = sel.value; sel.innerHTML = opts; sel.value = v; });
  }
  async function loadInstallers() { state.installers = arr(await api('GET', '/api/installers')); renderInstallers(); }

  function backupSecrets(f) {
    if (!f.Encrypt.checked) return { ok: true, secrets: undefined };
    const pw = f.BackupPassword.value; const pw2 = f.BackupPassword2.value;
    if (pw.length < 8) return { ok: false, error: 'The backup password needs at least 8 characters.' };
    if (pw !== pw2) return { ok: false, error: 'The two passwords are not the same.' };
    return { ok: true, secrets: { password: pw } };
  }

  $('#migrateForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const f = e.target;
    const t = backupType();
    if (!f.sourceId.value) return fail(new Error('Select a source server.'));
    const src = state.servers.find((s) => s.id === f.sourceId.value).name;
    const sec = backupSecrets(f);
    if (!sec.ok) return fail(new Error(sec.error));
    const clearPw = () => { f.BackupPassword.value = ''; f.BackupPassword2.value = ''; };
    if (t === 'graphs') {
      const days = Number(f.HistoryDays.value) || 0;
      if (!(await ask(`Back up the history of ${src}${days ? ` (last ${days} days)` : ''}?\n\nPRTG keeps running - the files are copied from a VSS snapshot.`, { ok: 'Start backup' }))) return;
      startJob({ type: 'backup', sourceId: f.sourceId.value, options: { Scope: 'graphs', HistoryDays: days, NoTouch: true, IncludePrtg: true, IncludeDesktop: false, SourceAfter: 'Restart' }, secrets: sec.secrets }, $('#runMigrate')).then(clearPw);
      return;
    }
    if (t !== 'full') {
      if (!(await ask(`Back up the ${TYPE_LABEL[t].toLowerCase()} of ${src}?\n\nNothing is stopped or written on the server.`, { ok: 'Start backup' }))) return;
      startJob({ type: 'section-backup', sourceId: f.sourceId.value, sectionType: t, secrets: sec.secrets }, $('#runMigrate')).then(clearPw);
      return;
    }
    const targets = $$('#targetList input:checked').map((i) => i.value);
    const options = {
      IncludePrtg: f.IncludePrtg.checked, IncludeHistory: f.IncludeHistory.checked, IncludeDesktop: f.IncludeDesktop.checked,
      ExtraPaths: f.ExtraPaths.value.split(/\r?\n/).map((s) => s.trim()).filter(Boolean),
      NoTouch: f.NoTouch.checked, IncludeProgram: f.IncludeProgram.checked, IncludeLogs: f.IncludeLogs.checked, IncludeAutoBackups: f.IncludeAutoBackups.checked, CopyLicense: f.CopyLicense.checked, OpenFirewall: f.OpenFirewall.checked,
      StartServices: f.StartServices.checked, AutoRollback: f.AutoRollback.checked, HealthTimeoutMinutes: Number(f.HealthTimeoutMinutes.value) || 15, TransferStreams: Number(f.TransferStreams.value) || 4,
      AllowDowngrade: f.AllowDowngrade.checked, InstallerFile: f.InstallerFile.value, InstallerArgs: f.InstallerArgs.value,
      RestorePrtg: true, RestoreDesktop: true, RestoreExtra: true, Scope: 'full',
      transfer: f.transfer.value || undefined,
    };
    const srcText = options.NoTouch ? 'The source is NOT touched (PRTG keeps running, VSS snapshot).' : null;
    if (targets.length) {
      options.SourceAfter = f.SourceAfter.value;
      const names = targets.map((id) => state.servers.find((s) => s.id === id).name).join(', ');
      const srcLine = srcText || `PRTG on the source will be stopped (${options.SourceAfter}).`;
      const lic = options.CopyLicense ? 'The source license IS copied.' : 'The source license is NOT copied (targets keep their own).';
      const path = options.transfer === 'wireguard' ? 'Files go over WinRM from the source to the target tunnel address on 10.66.66.0/24.'
        : options.transfer === 'ipip' ? 'Files go over WinRM from the source to the target tunnel address on 10.66.67.0/24.'
        : options.transfer === 'rdp' ? 'Files are copied through this computer over RDP.' : options.transfer === 'winrm' ? 'Files are copied through this computer over WinRM.' : 'Files are copied with each server\'s saved method.';
      const typeWord = targets.length === 1 ? names : 'MIGRATE';
      if (!(await ask(`Migrate ${src} → ${names}?\n\n${path}\n${srcLine}\n${lic}\nThe PRTG data on each target is replaced (a rollback copy is kept on the target${options.AutoRollback ? ' and put back automatically if PRTG does not come up' : ''}).\n\nPre-flight checks run first — nothing is changed if they fail.`, { ok: 'Migrate and replace', danger: true, type: typeWord }))) return;
      startJob({ type: 'migrate', sourceId: f.sourceId.value, targetIds: targets, options, secrets: sec.secrets }, $('#runMigrate')).then(clearPw);
    } else {
      if (options.transfer === 'wireguard' || options.transfer === 'ipip') return fail(new Error('A tunnel needs a target server. It copies between the two Windows servers and does not store the backup here. Pick a target, or use RDP / WinRM.'));
      options.SourceAfter = 'Restart';
      if (!(await ask(`Back up ${src}?\n\n${srcText || 'PRTG is stopped briefly for a consistent copy, then restarted and verified fully up.'}`, { ok: 'Start backup' }))) return;
      startJob({ type: 'backup', sourceId: f.sourceId.value, options, secrets: sec.secrets }, $('#runMigrate')).then(clearPw);
    }
  });
  $('#migrateForm').NoTouch.addEventListener('change', async (e) => {
    const cb = e.target;
    if (!cb.checked) {
      // stays ticked until the user agrees in the dialog
      cb.checked = true;
      if (await ask('Allow PRTG Manager to STOP PRTG on the source server during the backup?\n\nPRTG on the source is down while the files are copied. With the tick kept, PRTG keeps running and a VSS snapshot is copied instead.', { ok: 'Allow stopping PRTG', danger: true })) {
        cb.checked = false;
        cb.form.dispatchEvent(new Event('change'));   // the summary follows
      }
    }
    $('#sourceAfterBox').classList.toggle('disabled', cb.checked);
  });

  $('#installerUpload').addEventListener('change', (e) => {
    const file = e.target.files[0]; if (!file) return;
    upload(`/api/installers/upload?name=${encodeURIComponent(file.name)}`, file, (p) => { $('#installerUploadStatus').textContent = `Uploading… ${p}%`; })
      .then(() => { $('#installerUploadStatus').textContent = `${file.name} uploaded`; loadInstallers(); })
      .catch((err) => { $('#installerUploadStatus').textContent = ''; fail(err); });
    e.target.value = '';
  });

  // ------------------------------------------------------------ backups
  async function loadBackups() { state.backups = arr(await api('GET', '/api/backups')); renderBackups(); renderOverview(); }
  $('#refreshBackups').addEventListener('click', (e) => busy(e.currentTarget, () => loadBackups().catch(fail)));
  $('#backupFilter').addEventListener('change', renderBackups);

  function contentBadges(b) {
    const m = b.manifest || {}; const c = m.counts || {}; const out = [];
    if (b.type === 'full') {
      if (m.prtg && m.prtg.configStats) out.push(`<span class="sub-text">${esc(m.prtg.configStats)}</span>`);
      if (m.prtg && m.prtg.includeHistory) out.push('<span class="badge">history</span>');
      if (m.desktop && m.desktop.included) out.push(`<span class="badge">desktop ×${arr(m.desktop.users).length}</span>`);
      if (m.vpn && m.vpn.included) out.push('<span class="badge warn" title="This older package also contains Windows VPN connections - restore them in VPN Manager">+ VPN (use VPN Manager)</span>');
    } else if (b.type === 'graphs' && m.graphs) {
      out.push(`<span class="sub-text">${esc(m.graphs.files)} files · ${esc(m.graphs.from || '')}–${esc(m.graphs.to || '')} · ${arr(m.graphs.devices).length} device(s)</span>`);
    } else if (b.type === 'license' && m.license) {
      out.push(`<span class="sub-text">${esc(m.license.edition || '')}${m.license.name ? ` · ${esc(m.license.name)}` : ''}</span>`);
    } else {
      const parts = Object.keys(c).filter((k) => typeof c[k] !== 'object').map((k) => `${k} ${c[k]}`);
      if (parts.length) out.push(`<span class="sub-text">${esc(parts.join(' · '))}</span>`);
    }
    return out.join(' ');
  }

  function renderBackups() {
    const filter = $('#backupFilter').value;
    const list = state.backups.filter((b) => !filter || b.type === filter);
    $('#backupsTable tbody').innerHTML = list.length ? list.map((b) => {
      const dl = `/api/backups/${encodeURIComponent(b.name)}/download`;
      const valid = b.valid === true ? `<span class="badge ok" title="checked ${esc(fmtDate(b.validated))}">valid</span>` : b.valid === false ? `<span class="badge err" title="${esc(arr(b.validationErrors).join(' | '))}">invalid</span>` : '<span class="badge" title="not checked yet - press Validate">not checked</span>';
      const enc = b.encrypted ? '<span class="badge info" title="The whole package is encrypted with its backup password">encrypted</span>' : b.secretsEncrypted ? '<span class="badge info" title="The license key inside is encrypted">key encrypted</span>' : '<span class="badge">not encrypted</span>';
      const ver = `${b.formatVersion ? `format ${esc(b.formatVersion)}` : 'format ?'}${b.prtgVersion ? `<span class="sub-text">PRTG ${esc(b.prtgVersion)}</span>` : ''}${b.appVersion ? `<span class="sub-text">made by ${esc(b.appVersion)}</span>` : ''}`;
      return `<tr>
        <td class="name"><span class="badge info">${esc(TYPE_LABEL[b.type] || b.type)}</span> <b>${esc(b.name)}</b>${contentBadges(b)}${b.sha256 ? `<span class="sub-text" title="SHA-256 of the file">${esc(b.sha256.slice(0, 16))}…</span>` : ''}</td>
        <td class="nowrap">${esc(b.source || '–')}</td>
        <td class="num">${esc(fmtDate(b.created))}<span class="sub-text">${fmtSize(b.size)}</span></td>
        <td class="nowrap">${ver}</td>
        <td><div class="stack"><span title="Encryption">${enc}</span><span title="Validation">${valid}</span></div></td>
        <td class="row-actions"><div class="btn-group">
          <a class="btn small" href="${dl}" download>Download</a>
          <button class="btn small" data-act="validate" data-name="${esc(b.name)}">Validate</button>
          <button class="btn small" data-act="inspect" data-name="${esc(b.name)}">Inspect</button>
          ${['full', 'graphs', 'devices', 'notifications', 'triggers', 'license', 'files'].includes(b.type) ? `<button class="btn small primary" data-act="restore" data-name="${esc(b.name)}">Restore…</button>` : ''}
          <button class="btn small danger" data-act="del" data-name="${esc(b.name)}">Delete</button>
        </div></td></tr>`;
    }).join('') : `<tr><td colspan="6" class="empty">${filter ? 'No backups of this type.' : 'No backups yet. Run a backup or migration, or upload a package.'}</td></tr>`;
  }

  $('#backupsTable').addEventListener('click', async (e) => {
    const b = e.target.closest('button[data-act]'); if (!b) return;
    const name = b.dataset.name; const bk = state.backups.find((x) => x.name === name);
    if (!bk) return fail(new Error('This backup is no longer there - press Refresh.'));
    if (b.dataset.act === 'del') {
      if (!(await ask(`Delete backup ${name}?\n\nIt is moved to the Recycle Bin of this computer (you can restore it from there).`, { ok: 'Move to Recycle Bin', danger: true }))) return;
      await busy(b, async () => { try { await api('DELETE', `/api/backups/${encodeURIComponent(name)}`); toast('Backup moved to the Recycle Bin'); await loadBackups(); } catch (err) { fail(err); } });
    }
    if (b.dataset.act === 'restore') openRestore(bk);
    if (b.dataset.act === 'validate') openValidate(bk);
    if (b.dataset.act === 'inspect') await busy(b, () => openInspect(bk));
  });

  // ---- validate
  let validateTarget = null;
  function openValidate(bk) {
    validateTarget = bk;
    const f = $('#validateForm'); f.reset();
    $('#validateName').textContent = `${bk.name} · ${TYPE_LABEL[bk.type] || bk.type}${bk.encrypted ? ' · encrypted' : ''}`;
    $('#validatePwRow').hidden = !bk.encrypted;
    $('#validateBox').innerHTML = '';
    $('#validateDialog').showModal();
  }
  $('#validateGo').addEventListener('click', (e) => busy(e.currentTarget, async () => {
    const f = $('#validateForm'); const pw = f.Password.value; f.Password.value = '';
    const box = $('#validateBox'); box.innerHTML = '<p class="muted">Validating…</p>';
    try {
      const j = await runJobQuiet({ type: 'validate', backupName: validateTarget.name, secrets: pw ? { password: pw } : undefined }, (x) => { box.innerHTML = `<p class="muted">${esc(lastLog(x) || 'Validating…')}</p>`; });
      const r = j.result || {};
      box.innerHTML = `<p>${r.valid ? '<span class="badge ok">VALID</span>' : '<span class="badge err">INVALID</span>'} ${esc(j.error || '')}</p>
        <div class="table-wrap"><table class="table"><thead><tr><th>Check</th><th>Result</th></tr></thead><tbody>${arr(r.checks).map((c) => `<tr><td>${esc(c.check)}</td><td>${c.ok ? '<span class="badge ok">OK</span>' : '<span class="badge err">FAILED</span>'} ${esc(c.detail)}</td></tr>`).join('')}</tbody></table></div>
        ${arr(r.warnings).length ? `<ul>${arr(r.warnings).map((w) => `<li>${esc(w)}</li>`).join('')}</ul>` : ''}`;
      loadBackups().catch(() => {});
    } catch (err) { box.innerHTML = ''; fail(err); }
  }));

  // ---- inspect
  async function openInspect(bk) {
    try {
      const d = await api('GET', `/api/backups/${encodeURIComponent(bk.name)}/inspect`);
      const m = d.manifest || {};
      const kv = (k, v) => (v === undefined || v === null || v === '' ? '' : `<dt>${esc(k)}</dt><dd>${v}</dd>`);
      const counts = m.counts ? Object.keys(m.counts).filter((k) => typeof m.counts[k] !== 'object').map((k) => `<span class="badge">${esc(k)} ${esc(m.counts[k])}</span>`).join(' ') : '';
      const files = arr(d.files);
      $('#inspectBox').innerHTML = `<dl class="kv">
          ${kv('Name', esc(d.name))}${kv('Type', esc(TYPE_LABEL[d.type] || d.type))}${kv('Size', fmtSize(d.size))}${kv('SHA-256', `<code>${esc(d.sha256 || '–')}</code>`)}
          ${kv('Source', esc(d.source || (m.source && m.source.computer)))}${kv('Source OS', esc(m.source && m.source.os))}${kv('Created', esc(fmtDate(m.createdUtc)))}
          ${kv('Format', esc(`${m.format || m.tool || '?'} version ${m.formatVersion || '?'}`))}${kv('Made by', esc(m.appVersion ? `PRTG Manager ${m.appVersion}` : m.tool === 'prtg-mover' ? 'PRTG Mover (older)' : ''))}
          ${kv('PRTG version', esc(m.prtg && m.prtg.version))}${kv('Components', m.components ? esc(Object.keys(m.components).map((k) => `${k} ${m.components[k]}`).join(' · ')) : '')}
          ${kv('Sections', esc(arr(m.sections).join(', ')))}${kv('Counts', counts)}${kv('Configuration', esc(m.prtg && m.prtg.configStats))}
          ${kv('Encryption', d.encrypted ? 'whole package (AES-256-CBC + HMAC-SHA256)' : (m.encryption && m.encryption.secrets ? `license key encrypted on ${esc(m.encryption.encryptedOn || 'the server')}` : 'none'))}
          ${kv('Validation', d.validation ? `${d.validation.valid ? '<span class="badge ok">valid</span>' : '<span class="badge err">invalid</span>'} ${esc(fmtDate(d.validation.checked))} ${esc(arr(d.validation.errors).join(' | '))}` : 'not checked yet')}
          ${kv('Entries', d.entries != null ? `${esc(d.entries)} (${fmtSize(d.unpackedBytes)} unpacked)` : '')}
          ${kv('Warnings', esc(arr(m.warnings).join(' | ')))}
        </dl>
        ${arr(m.files).length ? `<h3 class="sub-head">Checksums</h3><div class="table-wrap"><table class="table"><thead><tr><th>File</th><th>Size</th><th>SHA-256</th></tr></thead><tbody>${arr(m.files).map((x) => `<tr><td>${esc(x.path)}</td><td class="num">${fmtSize(x.size)}</td><td><code>${esc(String(x.sha256).slice(0, 24))}…</code></td></tr>`).join('')}</tbody></table></div>` : ''}
        ${files.length ? `<h3 class="sub-head">Files ${files.length >= 300 ? '(first 300)' : ''}</h3><div class="preview"><div class="table-wrap"><table class="table"><tbody>${files.map((x) => `<tr><td>${esc(x.path)}</td><td class="num">${fmtSize(x.size)}</td></tr>`).join('')}</tbody></table></div></div>` : ''}`;
      $('#inspectDialog').showModal();
    } catch (err) { fail(err); }
  }

  // ---- restore wizard: options -> preview (mandatory) -> restore
  let restoreTarget = null;
  function restoreGroup(type) { return ['devices', 'notifications', 'triggers'].includes(type) ? 'section' : type === 'files' ? 'full' : type; }
  function openRestore(bk) {
    restoreTarget = bk;
    const f = $('#restoreForm'); f.reset();
    const g = restoreGroup(bk.type);
    $('#restoreTitle').textContent = `Restore ${TYPE_LABEL[bk.type] || bk.type}`;
    $('#restoreName').textContent = `${bk.name} · from ${bk.source || '?'} · ${fmtDate(bk.created)}`;
    const m = bk.manifest || {};
    $('#restoreInfo').innerHTML = `<dt>Contents</dt><dd>${contentBadges(bk) || '–'}</dd><dt>PRTG</dt><dd>${esc(bk.prtgVersion || '–')}</dd>${m.vpn && m.vpn.included ? '<dt>VPN</dt><dd>this package also holds VPN connections — restore them in VPN Manager</dd>' : ''}`;
    $$('#restoreForm [data-rfor]').forEach((el) => { el.hidden = !(el.dataset.rfor === g || (el.dataset.rfor === 'service' && g !== 'license')); });
    const targets = state.servers.filter((s) => s.role !== 'source');
    $('#restoreTargets').innerHTML = targets.length ? targets.map((s) => `<label class="check"><input type="checkbox" value="${esc(s.id)}"> <span><b>${esc(s.name)}</b> <span class="muted">(${esc(s.host)})</span>${serverLine(s)}</span></label>`).join('')
      : '<div class="empty">No target servers. A server marked as "source" is never restored into.</div>';
    const needPw = bk.encrypted || bk.type === 'license';
    $('#restorePwRow').hidden = !needPw;
    $('#restorePwLabel').textContent = bk.type === 'license' ? 'Backup password (decrypts the license on the target server)' : 'Backup password (the package is encrypted)';
    $('#fullConfirmRow').hidden = g !== 'full'; $('#fullConfirm').checked = false;
    renderInstallers();
    resetPreview();
    $('#restoreDialog').showModal();
  }
  function resetPreview(text) {
    state.preview = null;
    $('#restoreGo').disabled = true;
    $('#previewState').textContent = '';
    $('#previewBox').innerHTML = `<p class="muted">${text || 'Press <b>Preview</b> to see exactly what changes on the target. Nothing is changed by the preview.'}</p>`;
  }
  function restoreOptions() {
    const f = $('#restoreForm');
    const radio = (n) => ((f.querySelector(`input[name="${n}"]:checked`) || {}).value);
    return {
      CopyLicense: f.CopyLicense.checked, OpenFirewall: f.OpenFirewall.checked, RestorePrtg: f.RestorePrtg.checked, RestoreDesktop: f.RestoreDesktop.checked, RestoreExtra: f.RestoreExtra.checked,
      StartServices: f.StartServices.checked, InstallerFile: f.InstallerFile.value, AutoRollback: f.AutoRollback.checked, AllowDowngrade: f.AllowDowngrade.checked,
      GraphMode: radio('GraphMode') || 'merge', Mode: radio('Mode') || 'merge', ReIdConflicts: f.ReIdConflicts.checked,
    };
  }
  // any change of target / options invalidates the preview
  $('#restoreForm').addEventListener('change', (e) => { if (e.target.id !== 'fullConfirm' && e.target.name !== 'Password') resetPreview('Options changed - press <b>Preview</b> again.'); else updateRestoreGo(); });
  function updateRestoreGo() {
    const p = state.preview;
    const blocked = !p || p.some((x) => arr(x.preview && x.preview.Blockers).length);
    const needConfirm = restoreGroup(restoreTarget.type) === 'full' && !$('#fullConfirm').checked;
    $('#restoreGo').disabled = blocked || needConfirm;
  }

  function renderPlan(pv) {
    const items = arr(pv.Items);
    const act = (a) => `<span class="badge ${a === 'create' || a === 'create-new-id' ? 'ok' : a === 'update' ? 'warn' : a === 'conflict' ? 'err' : ''}">${esc(a)}</span>`;
    let html = '';
    arr(pv.Blockers).forEach((b) => { html += `<p class="blocker">✗ ${esc(b)}</p>`; });
    if (pv.Counts && pv.Counts.create !== undefined) html += `<div class="counts"><span class="badge ok">create ${esc(pv.Counts.create)}</span><span class="badge warn">update ${esc(pv.Counts.update)}</span><span class="badge">unchanged ${esc(pv.Counts.skip)}</span><span class="badge err">conflicts ${esc(pv.Counts.conflict)}</span></div>`;
    if (pv.Source && pv.Target) html += `<p class="muted">Backup: PRTG ${esc(pv.Source.PrtgVersion)} (format ${esc(pv.Source.ConfigVersion)}) → target: PRTG ${esc(pv.Target.PrtgVersion)} (format ${esc(pv.Target.ConfigVersion)})</p>`;
    if (arr(pv.Warnings).length) html += `<ul>${arr(pv.Warnings).map((w) => `<li>⚠ ${esc(w)}</li>`).join('')}</ul>`;
    if (arr(pv.MissingDependencies).length) html += `<h4>Missing dependencies</h4><ul>${arr(pv.MissingDependencies).map((w) => `<li>${esc(w)}</li>`).join('')}</ul>`;
    const changing = items.filter((i) => (i.Action || '') !== 'skip');
    const skipped = items.length - changing.length;
    if (items.length && items[0].Id !== undefined) {
      html += `<div class="table-wrap"><table class="table"><thead><tr><th>Action</th><th>Object</th><th>Why</th></tr></thead><tbody>${changing.slice(0, 400).map((i) => `<tr><td>${act(i.Action)}</td><td>${esc(i.Type)} <b>${esc(i.Name)}</b> <span class="muted">#${esc(i.Id)}</span></td><td>${esc(i.Reason)}</td></tr>`).join('')}${skipped ? `<tr><td colspan="3" class="muted">${skipped} item(s) stay as they are (already on the target).</td></tr>` : ''}</tbody></table></div>`;
    } else if (items.length) {
      html += `<div class="table-wrap"><table class="table"><thead><tr><th>Action</th><th>Item</th><th>Detail</th></tr></thead><tbody>${items.map((i) => `<tr><td>${act(i.Action)}</td><td>${esc(i.Item)}</td><td>${esc(i.Detail)}</td></tr>`).join('')}</tbody></table></div>`;
    }
    if (pv.Rollback) html += `<p class="muted">Rollback: ${esc(pv.Rollback)}</p>`;
    if (pv.Hint) html += `<p class="muted">${esc(pv.Hint)}</p>`;
    return html || '<p class="muted">Nothing to do.</p>';
  }

  $('#previewBtn').addEventListener('click', (e) => busy(e.currentTarget, async () => {
    const f = $('#restoreForm');
    const targets = $$('#restoreTargets input:checked').map((i) => i.value);
    if (!targets.length) return fail(new Error('Select at least one target server.'));
    const pw = f.Password.value;
    if (!$('#restorePwRow').hidden && !pw) return fail(new Error('Enter the backup password of this package.'));
    // an earlier preview no longer counts while this one runs
    state.preview = null; $('#restoreGo').disabled = true;
    const box = $('#previewBox'); box.innerHTML = '<p class="muted">Reading the target… nothing is changed.</p>';
    $('#previewState').textContent = '(running)';
    try {
      const j = await runJobQuiet({ type: 'restore-preview', backupName: restoreTarget.name, targetIds: targets, options: restoreOptions(), secrets: pw ? { password: pw } : undefined }, (x) => { box.innerHTML = `<p class="muted">${esc(lastLog(x) || 'Working…')}</p>`; });
      if (j.status !== 'succeeded') { resetPreview(`Preview failed: ${esc(j.error || 'see the Jobs page')}`); $('#previewState').textContent = '(failed)'; return; }
      state.preview = arr(j.result);
      box.innerHTML = state.preview.map((r) => `<h4>${esc(r.target)}</h4>${renderPlan(r.preview || {})}`).join('');
      $('#previewState').textContent = `(${fmtTime(new Date())})`;
      updateRestoreGo();
    } catch (err) { resetPreview(); fail(err); }
  }));

  $('#restoreGo').addEventListener('click', async (e) => {
    const btn = e.currentTarget;
    const f = $('#restoreForm');
    const targets = $$('#restoreTargets input:checked').map((i) => i.value);
    const names = targets.map((id) => (state.servers.find((s) => s.id === id) || {}).name).join(', ');
    const g = restoreGroup(restoreTarget.type);
    const what = g === 'full' ? 'The PRTG data on the target is REPLACED' : g === 'license' ? 'The license of the target is REPLACED' : 'PRTG is stopped for a moment and the configuration is changed as shown in the preview';
    // replacing a whole PRTG or a license: the target's name is typed (one target) or the word RESTORE (several)
    const replaces = g === 'full' || g === 'license';
    if (!(await ask(`Restore ${restoreTarget.name} → ${names}?\n\n${what}. A rollback copy is taken first.`, { ok: 'Restore', danger: replaces, type: replaces ? (targets.length === 1 ? names : 'RESTORE') : '' }))) return;
    const pw = f.Password.value; f.Password.value = '';
    $('#restoreDialog').close();
    startJob({ type: 'restore', backupName: restoreTarget.name, targetIds: targets, options: restoreOptions(), secrets: pw ? { password: pw } : undefined }, btn);
  });

  function upload(url, file, onProgress) {
    return new Promise((resolve, reject) => {
      const x = new XMLHttpRequest();
      x.open('PUT', url);
      x.upload.onprogress = (ev) => { if (ev.lengthComputable) onProgress(Math.round((ev.loaded / ev.total) * 100)); };
      x.onload = () => { let d = {}; try { d = JSON.parse(x.responseText); } catch { /* empty */ } if (x.status < 300) resolve(d); else { const er = new Error(d.error || `Upload failed with HTTP ${x.status}`); er.hint = d.hint; reject(er); } };
      x.onerror = () => { const er = new Error('Upload failed: the connection to the dashboard broke.'); reject(er); };
      x.send(file);
    });
  }
  $('#backupUpload').addEventListener('change', (e) => {
    const file = e.target.files[0]; if (!file) return;
    const box = $('#uploadProgress'); box.hidden = false;
    upload(`/api/backups/upload?name=${encodeURIComponent(file.name)}`, file, (p) => { $('i', box).style.width = `${p}%`; $('span', box).textContent = `${file.name} — ${p}%`; })
      .then(() => { toast('Backup uploaded and registered - press Validate to check it'); loadBackups(); })
      .catch(fail)
      .finally(() => { box.hidden = true; });
    e.target.value = '';
  });

  // ------------------------------------------------------------ license page
  function renderLicenseServers() {
    const sel = $('#licServer'); if (!sel) return;
    const keep = state.license.serverId || sel.value;
    sel.innerHTML = state.servers.length ? state.servers.map((s) => `<option value="${esc(s.id)}">${esc(s.name)} (${esc(s.role)})</option>`).join('') : '<option value="">— add a server first —</option>';
    if (keep && state.servers.some((s) => s.id === keep)) sel.value = keep;
    state.license.serverId = sel.value;
    const s = state.servers.find((x) => x.id === sel.value);
    const isSource = s && s.role === 'source';
    ['#licTrial', '#licActivate', '#licRestore', '#licRemove'].forEach((id) => { const b = $(id); b.disabled = !s || isSource; b.title = isSource ? 'This server is marked as source - PRTG Manager never changes its license.' : ''; });
    $('#licBackup').disabled = !s;
    const st = state.license.status && state.license.status[sel.value];
    if (st) renderLicenseStatus(st); else $('#licStatus').innerHTML = `<p class="muted">${s ? `Press <b>Refresh status</b> to read the license of ${esc(s.name)}.` : 'Add a server first.'}</p>`;
  }
  $('#licServer').addEventListener('change', () => { state.license.serverId = $('#licServer').value; renderLicenseServers(); });

  function renderLicenseStatus(r) {
    const st = r.State || {};
    const ok = st.Known && !st.NeedsActivation;
    $('#licStatus').innerHTML = !r.Installed ? '<p><span class="badge warn">PRTG is not installed on this server.</span></p>' : `
      <h2>${esc(r.Computer)} · PRTG ${esc(r.PrtgVersion)}</h2>
      <p>${ok ? '<span class="badge ok">licensed and activated</span>' : st.Known ? (st.Name ? '<span class="badge err">activation needed</span>' : '<span class="badge warn">no license</span>') : '<span class="badge">unknown</span>'} <span class="badge">core ${esc(r.Core)}</span></p>
      <dl class="kv">
        <dt>Edition</dt><dd>${esc(st.Edition || '–')}</dd><dt>Licensed for</dt><dd>${esc(st.Name || '–')}</dd><dt>Sensors</dt><dd>${esc(st.MaxSensors ?? '–')}</dd>
        <dt>Paused by license</dt><dd>${esc(st.PausedByLicense ?? '–')}</dd><dt>Last activation message</dt><dd>${esc(st.LastError || '–')}</dd>
        <dt>License values</dt><dd>${esc(arr(r.ValueNames).join(', ') || 'none')} ${r.HasKey ? '<span class="badge info">key present</span>' : '<span class="badge">no key</span>'}</dd>
        <dt>System id</dt><dd><code>${esc(r.SystemId || '–')}</code> <span class="muted">(fingerprint)</span></dd><dt>Online activation</dt><dd>${r.AutoActivation === 1 ? 'on' : r.AutoActivation === 0 ? 'off' : '–'}</dd>
      </dl>
      <p class="hint">${esc(r.Hint || '')}</p>
      ${arr(r.LogLines).length ? `<details><summary class="muted">License lines of the PRTG log (keys masked)</summary><div class="log" style="height:160px">${arr(r.LogLines).map((l) => `<div>${esc(l)}</div>`).join('')}</div></details>` : ''}`;
  }

  async function refreshLicense(btn) {
    const id = $('#licServer').value; if (!id) return;
    const s = state.servers.find((x) => x.id === id);
    $('#licStatus').innerHTML = `<p class="muted">Reading the license of ${esc(s.name)}… nothing is changed.</p>`;
    await busy(btn, async () => {
      try {
        const j = await runJobQuiet({ type: 'license', action: 'status', serverIds: [id] }, (x) => { $('#licStatus').innerHTML = `<p class="muted">${esc(lastLog(x) || 'Working…')}</p>`; });
        if (j.status !== 'succeeded') { $('#licStatus').innerHTML = `<p class="blocker">License status failed: ${esc(j.error)}</p>`; return; }
        const r = arr(j.result)[0] || {};
        state.license.status = state.license.status || {}; state.license.status[id] = r.status || {};
        renderLicenseStatus(r.status || {});
      } catch (err) { $('#licStatus').innerHTML = ''; fail(err); }
    });
  }
  $('#licRefresh').addEventListener('click', (e) => refreshLicense(e.currentTarget));

  let licKind = 'commercial';
  function openLicenseDialog(kind) {
    const s = state.servers.find((x) => x.id === $('#licServer').value); if (!s) return;
    licKind = kind;
    const f = $('#licenseForm'); f.reset();
    $('#licenseTitle').textContent = kind === 'trial' ? 'Add free trial license' : 'Activate an authorized license';
    $('#licenseWhich').textContent = `${s.name} (${s.host})`;
    $('#licenseHelp').innerHTML = kind === 'trial'
      ? 'Get a trial key from Paessler: register on <a href="https://www.paessler.com/prtg/download" target="_blank" rel="noopener noreferrer">paessler.com/prtg/download</a>. Paessler e-mails the trial license name and key. After the trial PRTG falls back to its free edition by itself.'
      : 'Enter the license name and key of a license you own (site, enterprise or other) exactly as the Paessler shop (<a href="https://shop.paessler.com" target="_blank" rel="noopener noreferrer">shop.paessler.com</a>) shows them. If the key is active on another server, move the activation in the Paessler shop first.';
    $('#licenseDialog').showModal();
  }
  $('#licTrial').addEventListener('click', () => openLicenseDialog('trial'));
  $('#licActivate').addEventListener('click', () => openLicenseDialog('commercial'));
  $('#licenseDialog').addEventListener('close', async () => {
    if ($('#licenseDialog').returnValue !== 'go') return;
    const f = $('#licenseForm');
    const name = f.licenseName.value.trim(); const key = f.licenseKey.value.replace(/\s+/g, '');
    f.licenseKey.value = '';
    if (!name || !key) return fail(new Error('Enter the license name and the license key.'));
    const id = $('#licServer').value; const s = state.servers.find((x) => x.id === id);
    if (!(await ask(`Enter this ${licKind === 'trial' ? 'trial ' : ''}license on ${s.name}?\n\nPRTG is restarted there (about a minute). A copy of the current license is kept on the server. PRTG activates the key itself with Paessler.`, { ok: 'Enter license' }))) return;
    startJob({ type: 'license', action: 'install', serverIds: [id], options: { Kind: licKind, Force: f.force.checked }, secrets: { licenseName: name, licenseKey: key } });
  });
  $('#licBackup').addEventListener('click', () => {
    const s = state.servers.find((x) => x.id === $('#licServer').value); if (!s) return;
    $('#licBackupForm').reset(); $('#licBackupWhich').textContent = `${s.name} (${s.host})`; $('#licBackupDialog').showModal();
  });
  $('#licBackupDialog').addEventListener('close', () => {
    if ($('#licBackupDialog').returnValue !== 'go') return;
    const f = $('#licBackupForm'); const pw = f.pw.value; const pw2 = f.pw2.value; f.pw.value = ''; f.pw2.value = '';
    if (pw.length < 8) return fail(new Error('The backup password needs at least 8 characters.'));
    if (pw !== pw2) return fail(new Error('The two passwords are not the same.'));
    startJob({ type: 'section-backup', sourceId: $('#licServer').value, sectionType: 'license', secrets: { password: pw } });
  });
  $('#licRestore').addEventListener('click', () => {
    const lic = state.backups.filter((b) => b.type === 'license');
    if (!lic.length) return fail(new Error('There is no license backup yet - use "Back up license" first.'));
    $('#backupFilter').value = 'license'; location.hash = 'backups';
    toast('Choose the license backup and press Restore');
  });
  $('#licRemove').addEventListener('click', () => {
    const s = state.servers.find((x) => x.id === $('#licServer').value); if (!s) return;
    $('#licRemoveForm').reset(); $('#licRemoveWhich').textContent = `${s.name} (${s.host})`;
    const inp = $('#licRemoveForm').confirmName; $('#licRemoveGo').disabled = true;
    inp.oninput = () => { $('#licRemoveGo').disabled = inp.value.trim() !== s.name; };
    $('#licRemoveDialog').showModal(); inp.focus();
  });
  $('#licRemoveDialog').addEventListener('close', () => {
    if ($('#licRemoveDialog').returnValue !== 'go') return;
    const s = state.servers.find((x) => x.id === $('#licServer').value); if (!s) return;
    if ($('#licRemoveForm').confirmName.value.trim() !== s.name) return fail(new Error(`Nothing was removed: type the server name "${s.name}" exactly to confirm.`));
    startJob({ type: 'license', action: 'remove', serverIds: [s.id] });
  });

  // ------------------------------------------------------------ jobs
  async function startJob(body, btn) {
    return busy(btn, async () => {
      try {
        const r = await api('POST', '/api/jobs', body);
        toast('Job started');
        location.hash = 'jobs';
        await loadJobs();
        selectJob(r.id);
      } catch (err) { fail(err); }
    });
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
  $('#diagBtn').addEventListener('click', () => {
    toast('Building diagnostics bundle…');
    location.href = '/api/diagnostics';
  });
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
        <div class="stepper" id="jobStepper"></div>
        <div class="progress" id="jobProgress"><i></i></div>
        <div class="sub-text" id="jobStep"></div>
        <dl class="kv" id="jobKv"></dl>
        <div id="jobResult"></div>
        <label class="check" style="margin-top:12px"><input type="checkbox" id="showDebug"> Show debug details (exact error position, stack, agent requests, timings)</label>
        <div class="log hide-debug" id="jobLog"></div>`;
      const sd = $('#showDebug');
      sd.checked = state.showDebug === true;
      $('#jobLog').classList.toggle('hide-debug', !sd.checked);
      sd.onchange = () => { state.showDebug = sd.checked; $('#jobLog').classList.toggle('hide-debug', !sd.checked); };
    }
    const pr = $('#jobProgress');
    pr.className = 'progress' + (j.status === 'succeeded' ? ' ok' : j.status === 'failed' ? ' err' : '');
    $('i', pr).style.width = `${j.progress || 0}%`;
    $('#jobStep').textContent = `${j.progress || 0}% · ${j.step || ''}`;
    $('#jobKv').innerHTML = `<dt>Status</dt><dd>${statusBadge(j.status)}</dd><dt>Started</dt><dd>${esc(fmtDate(j.started))}</dd><dt>Finished</dt><dd>${esc(fmtDate(j.finished))}</dd>${j.error ? `<dt>Error</dt><dd style="color:var(--err)">${esc(j.error)}</dd>` : ''}`;
    const active = j.status === 'running' || j.status === 'queued';
    const cp = j.checkpoint || {};
    const doneTargets = arr(cp.targetsDone).length;
    const resumeTitle = cp.backup ? `Continue: package ${cp.backup} is reused${doneTargets ? `, ${doneTargets} finished target(s) skipped` : ''}. Server IPs are re-read from the inventory.` : 'Run again with the same settings (server IPs are re-read from the inventory). A backup password is not kept - an encrypted job asks for it again.';
    $('#jobActions').innerHTML = (active ? '<button class="btn small danger" id="cancelJob">Cancel</button>' : '')
      + (j.resumable ? `<button class="btn small primary" id="resumeJob" title="${esc(resumeTitle)}">${cp.backup ? 'Resume' : 'Retry'}</button>` : '')
      + `<a class="btn small" href="/api/jobs/${encodeURIComponent(j.id)}/log">Download log</a>`;
    const cb = $('#cancelJob');
    if (cb) cb.onclick = async () => { if (await ask('Cancel this job?\n\nThe running step is stopped. A backup, restore or migration that was cut off can be resumed later from this page.', { ok: 'Cancel job', danger: true })) { try { await api('POST', `/api/jobs/${encodeURIComponent(j.id)}/cancel`); pollJob(); } catch (err) { fail(err); } } };
    const rb = $('#resumeJob');
    if (rb) rb.onclick = async () => {
      if (!(await ask(`${cp.backup ? 'Resume' : 'Retry'} this job?\n\n${resumeTitle}`, { ok: cp.backup ? 'Resume' : 'Retry' }))) return;
      try { const r = await api('POST', `/api/jobs/${encodeURIComponent(j.id)}/resume`); toast('Resumed'); await loadJobs(); selectJob(r.id); } catch (err) { fail(err); }
    };
    renderResult(j);

    const phases = {
      migrate: [['Pre-flight', /Pre-flight checks/], ['Copy from source', /Backup started|RESUME: the package/], ['Package', /Zip written|Encrypting the package|Downloading .* to the manager|RESUME: the package/], ['Restore on target', /Restore started/], ['Start & verify', /Starting PRTG and waiting/]],
      backup: [['Pre-flight', /Pre-flight checks/], ['Copy from source', /Backup started/], ['Package', /Zip written|Package ready/]],
      restore: [['Restore on target', /Restore started|Connecting to target|Connecting to/], ['Start & verify', /Starting PRTG|Waiting for PRTG/]],
    }[j.type];
    if (first) state.phaseIdx = -1;
    if (phases) {
      arr(j.logs).forEach((l) => { phases.forEach((p, i) => { if (i > state.phaseIdx && p[1].test(l.message)) state.phaseIdx = i; }); });
      const done = j.status === 'succeeded';
      const bad = ['failed', 'cancelled', 'interrupted'].includes(j.status);
      $('#jobStepper').innerHTML = phases.map((p, i) => {
        let cls = '';
        if (done || i < state.phaseIdx) cls = 'done';
        else if (i === state.phaseIdx) cls = bad ? 'fail' : 'now';
        return `<div class="st ${cls}">${i + 1}. ${esc(p[0])}</div>`;
      }).join('') + `<div class="st ${done ? 'done' : ''}">✓ Done</div>`;
    } else { $('#jobStepper').innerHTML = ''; }

    const log = $('#jobLog');
    const atBottom = log.scrollHeight - log.scrollTop - log.clientHeight < 40;
    const frag = document.createDocumentFragment();
    arr(j.logs).forEach((l) => {
      const line = document.createElement('div');
      line.className = l.level;
      const t = new Date(l.time);
      line.innerHTML = `<span class="ts">${esc(fmtTime(t))}</span> [${esc(l.computer)}] ${esc(l.message)}`;
      frag.appendChild(line);
    });
    log.appendChild(frag);
    state.logSince = j.logCount;
    if (atBottom || first) log.scrollTop = log.scrollHeight;

    if (active) state.jobTimer = setTimeout(() => pollJob(), 1500);
    else { loadJobs().catch(() => {}); if (j.type === 'test' || j.type === 'license' || j.type === 'unlicense') { loadServers().catch(() => {}); } if (j.type !== 'test') { loadBackups().catch(() => {}); } }
  }

  function renderResult(j) {
    const el = $('#jobResult'); const r = j.result;
    if (!r || j.type === 'test' || j.type === 'restore-preview') { el.innerHTML = ''; return; }
    let html = '';
    const one = Array.isArray(r) ? null : r;
    if (one && one.backup) {
      html += `<p style="margin:12px 0 0">Package: <b>${esc(one.backup)}</b> <a class="btn small" href="/api/backups/${encodeURIComponent(one.backup)}/download">Download</a></p>`;
      if (one.counts) html += `<div class="counts">${Object.keys(one.counts).filter((k) => typeof one.counts[k] !== 'object').map((k) => `<span class="badge">${esc(k)} ${esc(one.counts[k])}</span>`).join('')}</div>`;
    }
    if (j.type === 'validate' && one) html += `<p>${one.valid ? '<span class="badge ok">VALID</span>' : '<span class="badge err">INVALID</span>'} ${esc(arr(one.errors).join(' | '))}</p>`;
    const targets = arr((one && one.targets) || (Array.isArray(r) ? r : null));
    if (targets.length) {
      html += '<div class="result-targets">' + targets.map((t) => {
        const b = (v) => `<span class="badge ${v === 'ok' ? 'ok' : v === 'failed' ? 'err' : v === 'skipped' ? '' : 'warn'}">${esc(v || '–')}</span>`;
        let body = '';
        if (t.report) {
          const rep = t.report;
          body = `<div class="sub-text">PRTG ${b(rep.Prtg)}${rep.Version ? ` ${esc(rep.Version)}` : ''} · License ${rep.License === 'needs-activation' ? '<span class="badge err" title="A PRTG license is bound to the server it was activated on. Activate it for this server (License page).">activation needed</span>' : b(rep.License && String(rep.License).startsWith('active') ? 'ok' : rep.License)} · History ${b(rep.History)} · Desktop ${b(rep.Desktop)} · Extra ${b(rep.Extra)}${rep.RolledBack ? ' · <span class="badge warn">rolled back</span>' : ''}</div>${rep.WebUrl ? `<div class="sub-text">Web: ${esc(rep.WebUrl)}</div>` : ''}`;
        } else if (t.applied) {
          body = `<div class="counts"><span class="badge ok">created ${esc(t.applied.created)}</span><span class="badge warn">updated ${esc(t.applied.updated)}</span><span class="badge">new ids ${esc(t.applied.reIded)}</span><span class="badge">unchanged ${esc(t.applied.skipped)}</span><span class="badge err">conflicts ${esc(t.applied.conflicts)}</span></div>${t.rollback ? `<div class="sub-text">Rollback copy on the server: ${esc(t.rollback)}</div>` : ''}`;
        } else if (t.action || t.type === 'license') {
          const after = t.after || (t.status && t.status.State) || {};
          body = `<div class="sub-text">${t.activated ? '<span class="badge ok">activated</span>' : after.Known ? `<span class="badge warn">${esc(after.Edition)}</span>` : ''} ${esc(t.hint || '')}</div>${t.rollback ? `<div class="sub-text">Copy of the previous license on the server: ${esc(t.rollback)}</div>` : ''}${arr(t.removed).length ? `<div class="sub-text">Removed: ${esc(arr(t.removed).join(', '))}</div>` : ''}`;
        }
        return `<div class="rt"><b>${esc(t.target)}</b> ${t.ok ? '<span class="badge ok">OK</span>' : '<span class="badge err">errors</span>'}${body}${t.error ? `<div class="sub-text" style="color:var(--err)">${esc(t.error)}</div>` : ''}</div>`;
      }).join('') + '</div>';
    }
    el.innerHTML = html;
  }

  // ------------------------------------------------------------ boot
  async function refreshAll() {
    try {
      await loadInfo();
      await Promise.all([loadServers(), loadBackups(), loadInstallers(), loadJobs()]);
      checkPorts(false);
    } catch (err) { fail(err); }
  }
  syncBackupType();
  show(location.hash.slice(1) || 'overview');
  refreshAll();
  setInterval(() => { if (document.visibilityState === 'visible') loadJobs().catch(() => {}); }, 5000);
  setInterval(() => { if (document.visibilityState === 'visible' && !document.querySelector('dialog[open]')) loadServers().catch(() => {}); }, 10000);
})();
