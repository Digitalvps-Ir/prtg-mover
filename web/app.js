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
    const map = { succeeded: 'ok', failed: 'err', running: 'info', queued: '', cancelled: 'warn', interrupted: 'warn' };
    return `<span class="badge ${map[s] ?? ''}">${esc(s)}</span>`;
  };

  // ------------------------------------------------------------ state
  const state = { servers: [], backups: [], installers: [], jobs: [], ports: {}, selectedJob: null, logSince: 0, jobTimer: null };

  // ------------------------------------------------------------ navigation
  function show(view) {
    $$('.view').forEach((v) => v.classList.toggle('active', v.id === `view-${view}`));
    $$('nav a').forEach((a) => a.classList.toggle('active', a.dataset.view === view));
    if (view === 'jobs') loadJobs();
    if (view === 'logs') loadLogs();
  }

  // ------------------------------------------------------------ logs & audit
  async function loadLogs() {
    try {
      const [audit, mlog] = await Promise.all([api('GET', '/api/logs/audit'), api('GET', '/api/logs/manager')]);
      const rows = arr(audit);
      $('#auditTable tbody').innerHTML = rows.length ? rows.map((a) => {
        const d = a.data || {};
        const details = Object.keys(d).filter((k) => d[k] !== null && d[k] !== '').map((k) => `${esc(k)}=<b>${esc(Array.isArray(d[k]) ? d[k].join(',') : d[k])}</b>`).join(' · ');
        return `<tr><td class="num">${esc(fmtDate(a.time))}</td><td><span class="badge info">${esc(a.action)}</span></td><td>${details}</td><td>${esc(a.user)}</td></tr>`;
      }).join('') : '<tr><td colspan="4" class="empty">No audit entries yet.</td></tr>';
      const box = $('#managerLog');
      box.innerHTML = arr(mlog.lines).map((l) => {
        const cls = /\[ERROR/.test(l) ? 'ERROR' : /\[WARN/.test(l) ? 'WARN' : /\[AUDIT/.test(l) ? 'OK' : '';
        return `<div class="${cls}">${esc(l)}</div>`;
      }).join('') || '<div>Empty.</div>';
      box.scrollTop = box.scrollHeight;
    } catch (err) { toast(err.message, true); }
  }
  $('#refreshLogs').addEventListener('click', loadLogs);
  $('#diagBtn2').addEventListener('click', () => { toast('Building diagnostics bundle…'); location.href = `/api/diagnostics?token=${encodeURIComponent(token)}`; });

  // ------------------------------------------------------------ agents in the sidebar
  function renderSideAgents() {
    $('#sideAgents').innerHTML = state.servers.length ? '<b style="color:var(--muted)">Servers</b>' + state.servers.map((s) => {
      const on = s.agent && s.agent.connected;
      const tag = s.transport === 'winrm' ? '<span class="badge info">WinRM</span>'
        : s.transport === 'wireguard' ? '<span class="badge info">WireGuard</span>'
        : s.transport === 'ipip' ? '<span class="badge info">IPIP</span>'
        : on ? `<span class="badge ok">agent ${esc(s.agent.state || 'on')}</span>` : '<span class="badge">agent off</span>';
      return `<div class="row"><span>${esc(s.name)}</span>${tag}</div>`;
    }).join('') : '';
  }
  function serverLine(s) {
    if (!s) return '';
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

  async function checkPorts(showToast) {
    if (!state.servers.length) return;
    try {
      state.ports = await api('GET', '/api/servers/ports');
      renderServers();
      if (showToast) toast('Ports checked');
    } catch (err) { toast(err.message, true); }
  }
  $('#checkPortsBtn').addEventListener('click', () => checkPorts(true));

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
    // v = { ok, checked, detail } (new) or true/false (old status files)
    if (v === null || v === undefined) return `<span class="badge" title="not tested yet">${label} –</span>`;
    const ok = typeof v === 'object' ? v.ok : v;
    const when = typeof v === 'object' && v.checked ? ago(v.checked) : '';
    const detail = typeof v === 'object' && v.detail ? v.detail : '';
    return `<span class="badge ${ok ? 'ok' : 'err'}" title="${esc(detail)}${when ? ` · ${esc(when)}` : ''}">${label} ${ok ? '✓' : '✗'}${when ? ` <small>${esc(when)}</small>` : ''}</span>`;
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
          <div class="ports" style="margin-top:4px">${methodResult('RDP', m.rdp)}${methodResult('WinRM', m.winrm)}</div>`;
      }
      let prtg = '–';
      // PRTG answers only on the server itself (127.0.0.1): the web server is still bound to another server's address.
      const endpoints = arr(info && info.Prtg && info.Prtg.ListenEndpoints);
      const localOnly = endpoints.length > 0 && endpoints.every((e) => /^(127\.0\.0\.1|::1):/.test(e));
      if (info) {
        if (info.Prtg && info.Prtg.Installed) {
          const ls = info.PrtgLicenseState;
          let lic = '';
          if (ls && ls.Known) {
            lic = ls.NeedsActivation
              ? `<span class="badge err" title="${esc(ls.Edition)}${ls.LastError ? ` · ${esc(ls.LastError)}` : ''} · A PRTG license is bound to the server it was activated on. Activate it for this server in PRTG: Setup → License Information.">license: activation needed</span>`
              : `<span class="badge ok" title="${esc(ls.Edition)} · ${esc(ls.MaxSensors)} sensors">license ok</span>`;
          }
          const net = localOnly ? '<span class="badge err" title="PRTG only answers on 127.0.0.1">not reachable from network</span>' : '';
          prtg = `${esc(info.Prtg.Version)}<span class="sub-text">${esc(info.PrtgDataGB)} GB data · ${esc(info.Prtg.CoreStatus)}</span><div class="ports" style="margin-top:4px">${lic}${net}</div>`;
        } else { prtg = '<span class="badge warn">not installed</span>'; }
      }
      const cred = s.hasCredential ? '<span class="badge ok">saved</span>' : '<span class="badge" title="The current Windows identity of the manager is used">Windows identity</span>';
      const method = s.transport === 'winrm' ? '<span class="badge info">WinRM</span>'
        : s.transport === 'wireguard' ? '<span class="badge info">WireGuard</span>'
        : s.transport === 'ipip' ? '<span class="badge info">IPIP</span>'
        : '<span class="badge info">RDP</span>';
      const ag = s.agent && s.agent.connected
        ? `<span class="badge ok" title="${esc(s.agent.computer)} · ${esc(s.agent.user)}">agent ${esc(s.agent.state || 'on')}</span>`
        : (s.transport === 'winrm' ? '' : '<span class="badge" title="Only needed while a job runs">agent off</span>');
      return `<tr>
        <td><b>${esc(s.name)}</b>${info ? `<span class="sub-text">${esc(info.OS)}</span>` : ''}</td>
        <td class="num">${esc(s.host)}${s.useSsl ? ' <span class="badge info">HTTPS</span>' : ''}</td>
        <td>${esc(s.role)}<span class="sub-text">${method} ${ag}</span></td><td>${portBadges(s)}</td><td>${cred}</td><td>${test}</td><td>${prtg}</td>
        <td><div class="btn-group">
          <button class="btn small" data-act="rdp" data-id="${esc(s.id)}" title="Open Remote Desktop to ${esc(s.host)}:${esc(s.rdpPort || 3389)} and start the agent">RDP</button>
          <button class="btn small" data-act="test-rdp" data-id="${esc(s.id)}">Test RDP</button>
          <button class="btn small" data-act="test-winrm" data-id="${esc(s.id)}">Test WinRM</button>
          ${localOnly && s.role !== 'source' && s.transport === 'winrm' ? `<button class="btn small primary" data-act="rebind" data-id="${esc(s.id)}" title="PRTG on this server only answers on 127.0.0.1 because its web server is still bound to the old server's address. This binds it to this server's address and restarts PRTG. New migrations do this automatically.">Make PRTG reachable</button>` : ''}
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
    if (b.dataset.act === 'test-rdp') startJob({ type: 'test', mode: 'rdp', serverIds: [s.id] });
    if (b.dataset.act === 'test-winrm') startJob({ type: 'test', mode: 'winrm', serverIds: [s.id] });
    if (b.dataset.act === 'rebind' && confirm(`Bind the PRTG web server on "${s.name}" to this server's address (${s.host}) and restart PRTG there?`)) startJob({ type: 'rebind', serverIds: [s.id] });
    if (b.dataset.act === 'rdp') {
      try {
        const r = await api('POST', `/api/servers/${encodeURIComponent(s.id)}/rdp`);
        const copied = await copyText(r.agentCommand);
        $('#agentServer').textContent = `${s.name} (${r.target})`;
        $('#agentCmd').textContent = r.agentCommand;
        $('#agentDialog').showModal();
        toast(copied ? 'Remote Desktop opened — agent command copied to the clipboard' : 'Remote Desktop opened');
      } catch (err) { toast(err.message, true); }
    }
    if (b.dataset.act === 'edit') openServerDialog(s);
    if (b.dataset.act === 'del' && confirm(`Delete server "${s.name}" and its saved credential?`)) {
      try { await api('DELETE', `/api/servers/${encodeURIComponent(s.id)}`); toast('Server deleted'); loadServers(); } catch (err) { toast(err.message, true); }
    }
  });
  $('#copyAgentCmd').addEventListener('click', async () => { toast((await copyText($('#agentCmd').textContent)) ? 'Copied' : 'Copy failed — select the text manually'); });
  $('#addServerBtn').addEventListener('click', () => openServerDialog(null));
  $('#testAllBtn').addEventListener('click', () => {
    if (!state.servers.length) return toast('Add a server first', true);
    startJob({ type: 'test', mode: 'auto', serverIds: state.servers.map((s) => s.id) });
  });

  function openServerDialog(s) {
    const f = $('#serverForm'); f.reset();
    $('#serverDialogTitle').textContent = s ? `Edit ${s.name}` : 'Add server';
    f.id.value = s ? s.id : '';
    f.transport.value = 'rdp';
    if (s) {
      f.name.value = s.name; f.host.value = s.host; f.role.value = s.role || 'both'; f.port.value = s.port || 0; f.rdpPort.value = s.rdpPort || 3389;
      f.transport.value = ['winrm', 'wireguard', 'ipip'].includes(s.transport) ? s.transport : 'rdp';
      f.authentication.value = s.authentication || 'Default'; f.useSsl.checked = !!s.useSsl; f.skipCaCheck.checked = !!s.skipCaCheck; f.notes.value = s.notes || '';
    }
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
    try { await api('POST', '/api/servers', body); toast('Server saved'); await loadServers(); checkPorts(false); } catch (err) { toast(err.message, true); }
  });

  // ------------------------------------------------------------ migrate form
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
    const n = $$('#targetList input:checked').length;
    $('#runMigrate').textContent = n ? `Migrate to ${n} server${n > 1 ? 's' : ''}` : 'Create backup';
    renderMigrateSummary();
  }

  // Plain-language summary of exactly what the job will do / copy / skip.
  function renderMigrateSummary() {
    const f = $('#migrateForm');
    const src = state.servers.find((s) => s.id === f.sourceId.value);
    const targets = $$('#targetList input:checked').map((i) => state.servers.find((s) => s.id === i.value)).filter(Boolean);
    const yes = (on, text) => `<li class="${on ? '' : 'no'}">${on ? '✓' : '✗'} ${text}</li>`;
    const prtg = f.IncludePrtg.checked;
    const chosen = f.transfer.value;
    const savedModes = [...new Set([src, ...targets].filter(Boolean).map((s) => s.transport).filter((t) => t === 'wireguard' || t === 'ipip'))];
    const transfer = chosen || (savedModes.length === 1 ? savedModes[0] : '');
    const viaTunnel = transfer === 'wireguard' || transfer === 'ipip';
    const tunnelName = transfer === 'ipip' ? 'an IPIP tunnel (10.66.67.0/24)' : 'a WireGuard tunnel (10.66.66.0/24)';
    const pathText = viaTunnel
      ? `sent with WinRM over ${tunnelName} straight to the target's tunnel address — <b>not through this computer</b>`
      : (transfer === 'rdp' ? 'copied through this computer over RDP' : (transfer === 'winrm' ? 'copied through this computer over WinRM' : 'copied with each server\'s saved RDP or WinRM method'));
    $('#transferHint').textContent = viaTunnel
      ? `${transfer === 'ipip' ? 'IPIP' : 'WireGuard'}: WinRM (TCP 5985) runs between the two Windows servers on ${transfer === 'ipip' ? '10.66.67.0/24' : '10.66.66.0/24'}, the same point-to-point path a bandwidth test would use. A short probe reports MB/s before the copy. Commands still use each server's saved RDP or WinRM method. The backup is not stored on this computer.`
      : 'RDP and WinRM copy the files through this computer. WireGuard and IPIP build a tunnel between the two servers and copy only there. This computer sends commands and does not keep the backup.';
    let html = '<h3>What this job will do</h3><ul>';
    html += `<li><b>Source:</b> ${src ? esc(src.name) : '–'} — ${f.NoTouch.checked ? `<b>not touched</b> (PRTG keeps running, ${pathText})` : `PRTG is stopped (${esc(f.SourceAfter.value)}), ${pathText}`}</li>`;
    html += `<li><b>Target(s):</b> ${targets.length ? targets.map((t) => esc(t.name)).join(', ') : '<i>none — backup only</i>'}</li></ul>`;
    html += '<h3>Copied</h3><ul>';
    html += yes(prtg, 'PRTG configuration — all probes, groups, devices, sensors, <b>notifications</b>, <b>triggers</b>, users, schedules, maps, reports');
    html += yes(prtg, 'PRTG registry, SSL certificate, custom sensors, notification scripts, lookups, MIBs, device templates');
    html += yes(prtg && f.IncludeProgram.checked, 'PRTG program files + Windows services (clone, no installer)');
    html += yes(prtg && f.CopyLicense.checked, 'PRTG license key (PRTG asks for a new activation on the new server)');
    html += yes(prtg && f.IncludeHistory.checked, 'Historic monitoring data');
    html += yes(f.IncludeVpn.checked, 'Windows VPN connections');
    html += yes(f.IncludeDesktop.checked, 'Desktop files of every user (.bat, VPN files, …)');
    const extra = f.ExtraPaths.value.split(/\r?\n/).map((s) => s.trim()).filter(Boolean);
    if (extra.length) html += yes(true, `Extra: ${extra.map(esc).join(', ')}`);
    html += '</ul><h3>Not copied</h3><ul>';
    html += `<li class="no">${f.IncludeLogs.checked ? '' : '✗ PRTG log files · '}${f.IncludeAutoBackups.checked ? '' : '✗ old automatic config copies · '}✗ cache &amp; temp files · ✗ anything else on the disk</li></ul>`;
    if (targets.length) html += `<h3>On the target(s)</h3><ul><li>${f.OpenFirewall.checked ? 'open firewall · ' : ''}${f.StartServices.checked ? 'start PRTG and verify it is fully up' : 'do not start PRTG'} · rollback copy of any existing PRTG data</li></ul>`;
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

  $('#migrateForm').addEventListener('submit', (e) => {
    e.preventDefault();
    const f = e.target;
    if (!f.sourceId.value) return toast('Select a source server', true);
    const targets = $$('#targetList input:checked').map((i) => i.value);
    const options = {
      IncludePrtg: f.IncludePrtg.checked, IncludeHistory: f.IncludeHistory.checked, IncludeVpn: f.IncludeVpn.checked, IncludeDesktop: f.IncludeDesktop.checked,
      ExtraPaths: f.ExtraPaths.value.split(/\r?\n/).map((s) => s.trim()).filter(Boolean),
      NoTouch: f.NoTouch.checked, IncludeProgram: f.IncludeProgram.checked, IncludeLogs: f.IncludeLogs.checked, IncludeAutoBackups: f.IncludeAutoBackups.checked, CopyLicense: f.CopyLicense.checked, OpenFirewall: f.OpenFirewall.checked,
      StartServices: f.StartServices.checked, HealthTimeoutMinutes: Number(f.HealthTimeoutMinutes.value) || 15, TransferStreams: Number(f.TransferStreams.value) || 4, ConnectVpn: f.ConnectVpn.checked,
      AllowDowngrade: f.AllowDowngrade.checked, InstallerFile: f.InstallerFile.value, InstallerArgs: f.InstallerArgs.value,
      RestorePrtg: true, RestoreVpn: true, RestoreDesktop: true, RestoreExtra: true,
      transfer: f.transfer.value || undefined,
    };
    const src = state.servers.find((s) => s.id === f.sourceId.value).name;
    const srcText = options.NoTouch ? 'The source is NOT touched (PRTG keeps running, VSS snapshot).' : null;
    if (targets.length) {
      options.SourceAfter = f.SourceAfter.value;
      const names = targets.map((id) => state.servers.find((s) => s.id === id).name).join(', ');
      const srcLine = srcText || `PRTG on the source will be stopped (${options.SourceAfter}).`;
      const lic = options.CopyLicense ? 'The source license IS copied.' : 'The source license is NOT copied (targets keep their own).';
      const path = options.transfer === 'wireguard'
        ? 'Files go over WinRM from the source to the target tunnel address on 10.66.66.0/24. Nothing is copied to this computer.'
        : (options.transfer === 'ipip'
          ? 'Files go over WinRM from the source to the target tunnel address on 10.66.67.0/24. Nothing is copied to this computer.'
          : (options.transfer === 'rdp' ? 'Files are copied through this computer over RDP.' : (options.transfer === 'winrm' ? 'Files are copied through this computer over WinRM.' : 'Files are copied with each server\'s saved method.')));
      if (!confirm(`Migrate ${src} → ${names}?\n\n${path}\n${srcLine}\n${lic}\nThe PRTG data on each target is replaced (a rollback copy is kept on the target).\n\nPre-flight checks run first — nothing is changed if they fail.`)) return;
      startJob({ type: 'migrate', sourceId: f.sourceId.value, targetIds: targets, options });
    } else {
      if (options.transfer === 'wireguard' || options.transfer === 'ipip') return toast('A tunnel needs a target server. It copies between the two Windows servers and does not store the backup here. Pick a target, or use RDP / WinRM.', true);
      options.SourceAfter = 'Restart';
      if (!confirm(`Back up ${src}?\n\n${srcText || 'PRTG is stopped briefly for a consistent copy, then restarted and verified fully up.'}`)) return;
      startJob({ type: 'backup', sourceId: f.sourceId.value, options });
    }
  });
  $('#migrateForm').NoTouch.addEventListener('change', (e) => {
    if (!e.target.checked && !confirm('Allow PRTG Mover to STOP PRTG on the source server during the backup?')) e.target.checked = true;
    $('#sourceAfterBox').classList.toggle('disabled', e.target.checked);
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
      options: { CopyLicense: f.CopyLicense.checked, OpenFirewall: f.OpenFirewall.checked, RestorePrtg: f.RestorePrtg.checked, RestoreVpn: f.RestoreVpn.checked, RestoreDesktop: f.RestoreDesktop.checked, RestoreExtra: f.RestoreExtra.checked, StartServices: f.StartServices.checked, InstallerFile: f.InstallerFile.value },
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
  $('#diagBtn').addEventListener('click', () => {
    toast('Building diagnostics bundle…');
    location.href = `/api/diagnostics?token=${encodeURIComponent(token)}`;
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
    const resumeTitle = cp.backup ? `Continue: package ${cp.backup} is reused${doneTargets ? `, ${doneTargets} finished target(s) skipped` : ''}. Server IPs are re-read from the inventory.` : 'Run again with the same settings (server IPs are re-read from the inventory).';
    $('#jobActions').innerHTML = (active ? '<button class="btn small danger" id="cancelJob">Cancel</button>' : '')
      + (j.resumable ? `<button class="btn small primary" id="resumeJob" title="${esc(resumeTitle)}">${cp.backup ? 'Resume' : 'Retry'}</button>` : '')
      + `<a class="btn small" href="/api/jobs/${encodeURIComponent(j.id)}/log?token=${encodeURIComponent(token)}">Download log</a>`;
    const cb = $('#cancelJob');
    if (cb) cb.onclick = async () => { if (confirm('Cancel this job?')) { await api('POST', `/api/jobs/${encodeURIComponent(j.id)}/cancel`); pollJob(); } };
    const rb = $('#resumeJob');
    if (rb) rb.onclick = async () => {
      if (!confirm(`${resumeTitle}\n\nStart now?`)) return;
      try { const r = await api('POST', `/api/jobs/${encodeURIComponent(j.id)}/resume`); toast('Resumed'); await loadJobs(); selectJob(r.id); } catch (err) { toast(err.message, true); }
    };
    renderResult(j);

    // ---- phase stepper (derived from the log lines)
    const phases = {
      migrate: [['Pre-flight', /Pre-flight checks/], ['Copy from source', /Backup started|RESUME: the package/], ['Package', /Compressing the staged copy|Downloading .* to the manager|RESUME: the package/], ['Restore on target', /Restore started/], ['Start & verify', /Starting PRTG and waiting/]],
      backup: [['Pre-flight', /Pre-flight checks/], ['Copy from source', /Backup started/], ['Package', /Compressing the staged copy|Downloading .* to the manager/]],
      restore: [['Restore on target', /Restore started|Connecting to target/], ['Start & verify', /Starting PRTG and waiting/]],
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
          <div class="sub-text">PRTG ${b(rep.Prtg)}${rep.Version ? ` ${esc(rep.Version)}` : ''} · License ${rep.License === 'needs-activation' ? '<span class="badge err" title="A PRTG license is bound to the server it was activated on. Activate it for this server in PRTG: Setup → License Information.">activation needed</span>' : b(rep.License && rep.License.startsWith('active') ? 'ok' : rep.License)} · VPN ${b(rep.Vpn)} · Desktop ${b(rep.Desktop)} · Extra ${b(rep.Extra)}</div>
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
      checkPorts(false);
    } catch (err) { if (err.message !== 'Unauthorized') toast(err.message, true); }
  }
  show(location.hash.slice(1) || 'overview');
  if (!token) askToken(); else refreshAll();
  setInterval(() => { if (token && document.visibilityState === 'visible') loadJobs().catch(() => {}); }, 5000);
  // agent status / test results change in the background - refresh the server views every 10 s (not while a dialog is open)
  setInterval(() => { if (token && document.visibilityState === 'visible' && !document.querySelector('dialog[open]')) loadServers().catch(() => {}); }, 10000);
})();
