# Changelog

## 1.7.0 — 2026-09-29

### Added
- **Installer for the manager**: `install.cmd` (double-click) and `install.ps1`. It checks the computer, copies the program to `C:\PrtgMover` (or `-InstallPath`), unblocks the scripts, tests the installation (every script must be intact and the dashboard must answer), creates the shortcut *PRTG Mover* on the desktop and in the start menu, and starts the dashboard. Administrator rights are not needed.
- Running the installer again updates or repairs the installation. `-Uninstall` removes the program and the shortcuts. The server list, saved credentials, jobs, logs, backup packages and PRTG installers are never touched.
- The installer takes the program from its own folder, from `-Source` (folder or ZIP file) or from GitHub (git, GitHub CLI or a plain download).
- `install.ps1 -TrustedHosts` prepares the manager for plain WinRM and asks for administrator rights for that step only.

### Changed
- **`tools\Enable-PrtgMoverRemoting.ps1`** (WinRM method, run on a server):
  - finds the manager's address itself, from the Remote Desktop session it is run in. Without an address it stops instead of opening the firewall for everyone; `-AllowAnyAddress` has to be given for that.
  - with `-Https` it opens only port 5986 and closes plain WinRM (port 5985) in the firewall, which Windows opens when remoting is enabled. `-KeepPlainWinRM` leaves it open.
  - the certificate is valid from two days before its creation, so a manager whose clock is behind accepts it right away.
  - checks the result (service, port, listener) and prints what to enter in the dashboard.

## 1.6.2 — 2026-09-29

### Changed
- **The dashboard uses no access token.** A token file left by an older version is removed when the dashboard starts.
- **No access protection at all**, as the owner wants: no token and no check of where a request comes from. Every program on the manager, every web page that is open in a browser on the manager and, with `-ListenAll`, everyone who can reach the port can use the dashboard.

### Added
- `Start-PrtgMover.ps1 -DataRoot <folder>` keeps `config\`, `data\`, `backups\` and `installers\` outside the program folder.
- Response headers `X-Frame-Options: DENY` and `Referrer-Policy: no-referrer`.

## 1.6.1 — 2026-09-29

### Added
- **Remove license** for a migrated server (Servers page, job type `unlicense`, command line `-Action RemoveLicense -Target <server>`). PRTG is stopped, license name, key, hash and license files are removed, and PRTG is started again. A copy of the removed data is kept on the server in `C:\PrtgMover\rollback\license-<timestamp>`. System id, configuration and monitoring data are not changed.
- A source server is always refused: the license of the original installation is never touched.
- A server with no license name is shown as **license: none**, separate from a license that still needs activation.

## 1.6.0 — 2026-09-29

### Added
- **Transfer path** on Backup & Migrate, before the job starts: keep each server's saved method, force **RDP**, force **WinRM**, or **WireGuard**.
- **WireGuard** copies straight from the source Windows server to the target Windows server on `10.66.66.0/24`. This computer only sends commands (over the saved RDP or WinRM method) and does not store the backup. The tunnel is split: it does not replace the servers' default route. UDP 51820 is limited to the peer.
- **IPIP** (protocol 4) does the same on its own network, `10.66.67.0/24`, using Wintun. IP protocol 4 must be allowed between the two public addresses. It does not replace the default route.
- **WinRM on the tunnel.** After the tunnel is up, the source opens WinRM to the target's tunnel address (`10.66.66.x:5985` or `10.66.67.x:5985`) and sends the files there. A 32 MB probe reports MB/s first, the same point-to-point shape as a bandwidth test. TCP 5985 is allowed only from the tunnel network, not from the public address.

## 1.5.3 — 2026-09-29

### Added
- **License state.** The server test and the restore read the license state from the PRTG core log (read-only) and show it: edition, sensor limit, sensors paused by the license, and the last activation error. License values are never shown, only fingerprints at debug level.
- Servers page: badges *license ok* / *license: activation needed* and *not reachable from network*.

### Changed
- A restore no longer reports the license as fine just because the key was copied. PRTG binds a license to the system it was activated on, so the target reports *activation needed* until the license is activated there.
- **Make PRTG reachable** (formerly *Fix PRTG IP*) is only shown for a server whose PRTG answers on `127.0.0.1` only. New migrations adjust the web server binding automatically.

## 1.5.2 — 2026-09-29

### Added
- Command line: `-Action FixBinding -Target <server>` binds the web server of a migrated PRTG to the server's own address.

### Changed
- README (English and Persian), architecture and troubleshooting guides rewritten for the current behaviour: connection methods, source untouched by default, program clone, compressed parallel transfer, resume, logs and audit.
- The addresses of a server are read without Windows-only cmdlets when those are missing, so the test suite keeps working under PowerShell 7.

## 1.5.1 — 2026-09-29

### Fixed
- After a migration PRTG only answered on `127.0.0.1`, because the web server was still bound to the source's IP address. Restore now binds it to the target's own address.
- **Fix PRTG IP** (job type `rebind`) repairs a server that was already migrated. The binding is changed while PRTG is stopped, because the core writes its settings back when it stops.
- The connectivity test shows the addresses PRTG listens on, and restore warns when PRTG is only reachable locally.
- A 32-bit overflow in the progress line stopped a transfer after 2 GB on the wire. Progress reporting can no longer stop a transfer.

## 1.5.0 — 2026-09-29

### Added
- **WinRM transfer without disk space on the source**: the manager pulls the files straight from the VSS snapshot. The target receives the staged files and **moves** them into place, so it needs no second copy of the data.
- **Compressed chunks**: files travel as compressed chunks of about 256 MB of data (PRTG data compresses roughly 7x).
- **Parallel streams**: several chunks travel at once, each over its own connection (default 4, `TransferStreams` in the dashboard, `-Streams` in the CLI). Streams reconnect after a broken session and retry a chunk up to 4 times.
- Transfers are resumable per file, and every chunk is verified (size after transfer, file count after unpacking).
- Snapshots left behind by interrupted runs are removed before a new one is created. Other snapshots are never touched.
- Chunk compression on servers runs below normal priority, so a running PRTG keeps its CPU.
- The manager waits for a WinRM HTTPS certificate that is not valid yet because the manager's clock is behind.

### Fixed
- A partial staging copy was treated as complete on Resume. A copy now counts as complete only after the transfer finished and `PRTG Configuration.dat` matches the source checksum.
- Hidden and system files could not be transferred over WinRM. `desktop.ini` and `Thumbs.db` are skipped.
- Pulling removes local files that are not part of the transfer (logs, cache and temp files of earlier runs).

## 1.4.0 — 2026-09-29

### Added
- **Logs & Audit page**: audit trail table, the day's manager log, and diagnostics download.
- Migrate page:
  - a plain-language **What this job will do** summary (copied, not copied, what happens on the targets)
  - each server's connection method and agent status
- Job view: a **phase stepper** (Pre-flight → Copy from source → Package → Restore → Start & verify → Done).
- Sidebar: live agent status of every server.
- The dashboard console echoes every job's progress, so one console shows everything.
- The agent keeps running when the RDP window is closed and continues automatically after reconnecting. RDP files enable auto-reconnect.
- The desktop copy report lists scripts and VPN files (.bat, .cmd, .ps1, .pbk, .ovpn, .rdp).

### Changed
- Only what PRTG needs is copied by default: PRTG log files, cache/temp files and old automatic configuration copies are skipped. They are optional in the UI.
- Resume reuses the partial staging copy of an interrupted run.

### Fixed
- PRTG 64-bit installs: the program folder is the install dir, not its `64 bit` subfolder.
- The dashboard hung on the manager-log endpoint (Get-Content NoteProperties).
- Jobs interrupted by a dashboard restart become resumable.

## 1.3.0 — 2026-09-29

### Added
- **Direct staging for RDP-mode servers.**
  - The source copies straight onto the manager's disk (VSS snapshot → `\\tsclient`), and the manager builds the zip. The source needs **no free disk space**.
  - RDP-mode targets read the extracted package directly from the manager (no zip copy, no extraction on the target). They only need about the size of the data.
- **Resume / Retry** for failed or cancelled jobs:
  - The package that was already built and targets that already finished are skipped.
  - Server addresses are re-read from the inventory, so a changed IP is used automatically.
  - Checkpoints are saved after every milestone.
- **Automatic reconnect**: if an RDP session or agent window drops mid-job, the job waits up to 30 minutes for the agent to come back and repeats the step (up to 3 times).
- **Audit and diagnostics.**
  - `data\logs\manager-yyyyMMdd.log`: API calls, errors with file, line and stack, job warnings.
  - `data\logs\audit.log`: server, credential, job, backup and RDP actions (no secrets).
  - `data\logs\robocopy\*.log`: complete robocopy logs; errors are quoted in the job log.
  - `data\agent\<id>\agent.log`: every agent request with parameters, duration and errors with stack.
  - A DEBUG level in job logs (exact line, stack, timings, agent requests) with a *Show debug* toggle.
  - **Download diagnostics**: one zip with all of the above plus an environment report (no passwords or token).
- The agent reloads a newer payload automatically, and the manager warns when an agent runs an older version.

### Fixed
- Connectivity tests: **Test RDP** and **Test WinRM** results are stored separately with their own time, and one no longer erases the other. The server shows **PASS** when at least one method works, and each badge shows its detail.
- A test no longer waits behind a busy agent.
- The agent heartbeat uses the manager's clock, so servers with a skewed clock are handled correctly.
- Disk space checks match the connection method (the source needs nothing in RDP mode, and the manager is checked instead).

## 1.2.0 — 2026-09-29

### Added
- **Full PRTG clone**: the complete program folder and the Windows service definitions (with recovery options) are packaged. A target **without PRTG needs no installer**: files are copied, the services are created and the .NET version is checked. An uploaded installer is still used if you select one.
- **RDP connection method (agent)**, now the default. It needs no WinRM and makes no configuration change on the server:
  - The dashboard opens Remote Desktop with the manager's drive redirected. A one-line command (copied to the clipboard) starts `agent\PrtgMover-Agent.ps1` in an elevated PowerShell.
  - The agent runs the same payload and talks to the manager over files in the redirected drive (requests, streamed JSON-lines responses, heartbeat from a background thread).
  - Packages and installers travel over `\\tsclient`.
- A **connection method** is chosen per server: RDP or WinRM.
- Separate **Test RDP** and **Test WinRM** buttons. **Test all** checks both, and a server **PASSES** when at least one method works; the per-method results are shown.
- Agent status badge (on/off, busy).
- **PRTG configuration statistics**: probes, groups, devices, sensors, notifications, triggers, users, schedules, maps, reports, libraries and dependencies are counted on the source and on the target and logged.

### Changed
- **Don't touch the source** is now the **default** in the dashboard, the engine and the CLI. Stopping the source needs explicit consent (confirmation in the UI, `-AllowSourceStop` in the CLI).
- Temporary work folders on the source are removed after the transfer.

## 1.1.0 — 2026-09-29

### Added
- **RDP** on the Servers page:
  - per-server RDP port (default 3389, editable)
  - live RDP/WinRM reachability badges and a **Check ports** button
  - an **RDP** button that opens Remote Desktop from the manager (the password is never written to disk)
  - the test warns when the server's real RDP port differs from the inventory
- **Don't touch the source** (no-touch mode): PRTG keeps running, and nothing on the source is stopped, changed or deleted. Data is copied from a consistent **VSS snapshot**, with a live-copy fallback.
- **Copy source license** option. When it's off, the target keeps its own license values and files.
- **Restart & verify fully up**: after a restart the tool waits until core and probe are Running, the web interface answers, and everything is still stable 45 s later. Crashed services are restarted automatically, and the job fails if PRTG doesn't come up completely. Targets use the same health check.
- **Pre-flight checks** before anything is changed:
  - reachability and administrator rights on every server
  - enough disk space on source and targets
  - target PRTG version not older than the source
  - an installer is selected when PRTG is missing on a target
- Integrity checks:
  - package SHA-256 re-verified on each target
  - `PRTG Configuration.dat` SHA-256 compared between source and target
  - backup aborts if `PRTG Configuration.dat` is missing
- Firewall rule on targets for the PRTG web ports and remote probes (TCP 23560).
- Transfer speed shown in the log, and connection hints for common WinRM errors.
- CLI: `-NoTouch -NoLicense -NoFirewall -SkipPreflight`.

### Fixed
- The WinRM port can no longer be set to the RDP port by mistake.

## 1.0.0 — 2026-09-28

### Added
- Web dashboard (`Start-PrtgMover.ps1`) with servers, backup & migrate, backups (download / upload / restore) and live jobs.
- Full PRTG migration: data folder, registry, SSL certificate, custom sensors, notifications, lookups, MIBs, device templates, map objects.
- Windows VPN (RAS phonebook) export and non-destructive merge on the target.
- Desktop files of all user profiles and the Public desktop.
- Extra file and folder paths.
- Silent PRTG installation on targets without PRTG, version check, rollback copy, automatic start and web health check.
- One source to many targets in a single job.
- DPAPI-encrypted credential store and a token-protected dashboard.
- CLI (`cli/Invoke-PrtgMover.ps1`) with retention for scheduled backups.
- Server preparation scripts for the manager and for servers.
- Pester 5 test suite and GitHub Actions CI.
