# Changelog

## 2.1.0 — 2026-10-02

Fixes from a review of PRTG Manager running in local mode on the PRTG servers themselves (as SYSTEM, from the task at system start).

### Fixed
- **Cancel during a restore left PRTG stopped, possibly without a data folder.** A cancelled job is stopped without running `catch` blocks, so the rollback never ran. The full restore and the part restores (devices, notifications, triggers) now put the previous state back in a `finally` block once PRTG has been stopped. That covers the data folder, the registry, the configuration and the firewall rule the restore added. The log goes to `<work folder>\rollback\cancelled-restore-<time>.log`, because a cancelled job's output is dropped. The server stays locked for other PRTG jobs until this has finished.
- **A failure before anything was changed left PRTG stopped.** For example, the services did not stop in time, or the data folder could not be set aside. PRTG is now started again. A data folder that could not be renamed is only used as the rollback source when the copy really succeeded; a partial copy now stops the restore before anything is changed.
- **A backup whose service stop failed left the source PRTG stopped.** The stop now runs inside the block that restarts PRTG.
- **VSS snapshots of failed backups stayed on the system drive** and kept growing until the next backup. They are removed immediately.
- **A restore on the PRTG server itself needed two to three times the package size on C:.** The package was unpacked, copied again into the work folder, and the history copied a third time while PRTG was stopped. The unpacked package is now moved into place, with no second copy, and the history files are moved instead of copied. Free space is checked before unpacking, a half-unpacked copy is removed, and the unpacked copy is deleted after a successful restore instead of staying in `data\staging` forever.
- **Wrong free-space estimate for backups.** The estimate was 2.2 × the whole data folder (history, logs and automatic configuration copies included), while the program clone and the desktops were not counted. It now uses what the backup really copies. When the space is too small and the history is large, the message suggests a backup without history.
- **Delete did not free space when the dashboard runs as SYSTEM.** Files went to SYSTEM's Recycle Bin, which administrators cannot see, and an error dialog in session 0 could stop the dashboard. The SYSTEM dashboard now deletes permanently and says so before you confirm. A dashboard run by a person still uses the Recycle Bin (`/api/info` `deleteMode`).
- **Two jobs could stop and change the same PRTG at the same time.** For example, a restore and a license change. Restore, migration, backup, license change, license removal and web binding now take a per-server lock, and a second such job is refused with the running job named.
- **The web binding could be changed on a Source server.** "Fix web binding" now refuses a server with the role Source, like restore and license changes.
- **The dashboard could end on a failed request.** An exception while receiving a request ended the process. It is now logged and the dashboard goes on.
- **The dashboard grew without limit.** Finished jobs are dropped from memory after an hour; their records stay on disk. The job list no longer re-reads every job file every few seconds. Once a day, manager and robocopy logs older than 30 days and job records older than 90 days are deleted (the newest 200 always stay), and the audit log is rotated at 10 MB.
- **The free-space count could fail on a profile this account may not read.** Such a folder now counts as empty.

### Added
- **Watchdog:** the task "PRTG Manager Dashboard" gets a second trigger every 5 minutes. A dashboard that stopped comes back within 5 minutes instead of at the next restart; a running one is left alone.
- **`install.ps1 -Local -Role source|target|both`** sets the role of this computer in the server list. A Source is never restored into, and its license and web binding are never changed.
- **Leftovers on this computer** (Backups page, `GET /api/leftovers`, `POST /api/leftovers/remove`). It lists, with their sizes, unpacked packages, temporary restore stages, rollback copies, previous PRTG data folders (`.pre-restore-*`, `.failed-restore-*`) and VSS snapshots of interrupted backups. Each item can be removed after a confirmation. Only listed items can be removed, and only while no job runs.
- Tests: cancel during a restore (a real stopped pipeline), the restart of PRTG when the data folder cannot be set aside, the backup estimate, the per-server lock, the delete mode, leftovers, housekeeping and the watchdog trigger.


## 2.0.2 — 2026-10-02

### Fixed
- **Setup-All left an old dashboard running after an update.** When exactly one dashboard of the installation was running, Windows PowerShell 5.1 returned it as a single `CimInstance`, and that has no `.Count`. So the VPN Manager step never stopped it. The old VPN Watch backend (started as SYSTEM by its old boot task) kept serving port 8770 with the new web files. The new *VPN Manager Dashboard* task did not start, because the port was taken. Found while installing on Prtg-New. Both lookups are wrapped in `@()` now, and a test runs the lookup against one real process.


## 2.0.1 — 2026-10-02

### Fixed
Full restore to a server where PRTG is **already installed** (nothing is installed, the data is replaced, the old data folder is kept for the rollback):
- When the source's data path also existed on the target (for example `D:\PRTG Data` on both), the restore wrote there instead of into the data folder the installed PRTG uses. The target's own data folder was not set aside, so the rollback had nothing to put back and two data folders were left. On an installed target the restore now always uses the data folder of the installed PRTG and logs the source path when it differs.
- The `Datapath` registry value was rewritten on every restore, because it was compared with the staging folder instead of the source data path. It is now only changed when the data path really differs.
- A target with PRTG installed but no `Datapath` value in the registry got no data folder. It now falls back to `%ProgramData%\Paessler\PRTG Network Monitor` with a warning.
- The preview's disk check did not match the target's own check. It now blocks below the package size + 2 GB and warns below twice the package size + 1 GB (the space a zip transfer needs). The preview also says that the installed PRTG program is kept and which data folder gets the restored data.
- Eight broken characters (dashes and ellipses saved in the wrong encoding) in this changelog.

### Added
- End-to-end tests for a restore into an installed PRTG: the data goes into the installed data folder, the previous folder is kept as `.pre-restore-<time>`, nothing is installed, and an unhealthy PRTG after the restore gets its previous data back.


## 2.0.0 — 2026-09-30

PRTG Mover is now **PRTG Manager**. Windows VPN connections and routes moved to **VPN Manager** (the former VPN Watch).

### Added
- **Backup types**: *Full* (as before), *History* (graph data of all days or the last N days, from a VSS snapshot), *Devices* (probes, groups, devices, sensors with settings, channels and triggers), *Notifications* (templates and the schedules they use), *Triggers* (every trigger of every object) and *License* (always encrypted on the server). Parts are read from `PRTG Configuration.dat` without writing anything on the server.
- **Restore for every type, always with a preview**: items to create, update, skip, conflicts (including ID conflicts), missing dependencies (notifications, schedules, dependencies, devices of a history package) and blockers (newer configuration format, older PRTG on the target, disk space, no PRTG and no program clone, no administrator rights). Restore is only enabled after a preview without blockers; a full restore needs an explicit confirmation.
- **Restore modes for configuration parts**: merge (only add), overwrite (also update existing objects) and new ids for objects whose id is taken on the target (with everything below them; dependencies inside follow). The highest id of the configuration is raised as needed.
- **Automatic rollback**: a full restore puts the previous data folder and PRTG registry back when it fails or PRTG does not come up; a part restore puts the saved `PRTG Configuration.dat` back; license changes keep a copy of the previous license.
- **License page**: status (edition, name, sensors, activation, last activation message, value names, system-id fingerprint), add a free trial license, activate an authorized license (the key is written like the PRTG Administration Tool does it and PRTG activates it online with Paessler; the result is read from log lines written after that start and explained), license backup and restore, license removal with the server name as confirmation.
- **Backup password**: any package can be encrypted (AES-256-CBC + HMAC-SHA256, PBKDF2-SHA256 200 000 rounds, file `.pmenc`); a wrong password or a changed file is detected before anything is decrypted.
- **Backups page**: one table with type, source, created, size, format and PRTG version, encrypted and valid; actions Download, **Validate** (file checksum, zip, format, every file checksum, configuration checksum, history file count, password/HMAC), **Inspect** (metadata, sections, counts, checksums, file list) and Delete; upload of `.zip` and `.pmenc`.
- **Package format 2**: `manifest.json` with format, type, app version, source, components, sections, counts, per-file SHA-256 and encryption; the sidecar keeps the last validation. Packages of format 1 still restore.
- **Structured errors**: API errors carry `operation`, `component`, `reason`, `code` and a `hint`; the dashboard shows the hint.
- **Audit** of backups, restores, validations, license changes and deletions; passwords and keys never appear in job records, logs or the audit trail.
- **Command line**: `-Scope Graphs -HistoryDays`, `-Action BackupPart -Part Devices|Notifications|Triggers|License`, `-BackupPassword`.

### Changed
- Product name, dashboard, shortcuts, task (*PRTG Manager Dashboard*), scripts (`Start-PrtgManager.ps1`, `Open-PrtgManager.ps1`, `src\PrtgManager.psm1`, …) renamed. The old script names remain as forwarders. The installer updates an installation in `C:\PrtgMover` in place and replaces its own old shortcuts and task; new installations go to `C:\PrtgManager`.
- Package names: `PRTG-FULL_…`, `PRTG-GRAPHS_…`, `PRTG-DEVICES_…`, `PRTG-NOTIFICATIONS_…`, `PRTG-TRIGGERS_…`, `PRTG-LICENSE_…`.
- **Delete** moves a package to the Recycle Bin instead of deleting it.
- **Remove license** removes the license (name, key, activation hash, license files) and leaves PRTG's own bookkeeping (install date, paused-sensor counter) alone.
- A server with the role *Source* is refused as a restore target by the engine too, not only by the dashboard.
- `Setup-All.cmd` installs PRTG Manager and VPN Manager (`-SkipPrtgManager`, `-SkipVpnManager`, `-PrtgManagerPath`, `-VpnManagerPath`; the old parameter names still work).

### Removed
- VPN connections, VPN routes and VPN-only backups (`IncludeVpn`, `RestoreVpn`, `RestoreRoutes`, `ConnectVpn`, the VPN section of the Backups page). Use VPN Manager; it imports old PRTG Mover packages.

### Fixed
- A dependency of a restored object on another object restored in the same run (for example a device that depends on its own sensor) is no longer reported as missing.
## 1.9.1 — 2026-09-29

### Fixed
- `install.ps1 -Local` finds out whose the saved credentials are by reading one, not by looking at the task. After an uninstall or `-NoAutostart` a later installation in local mode no longer starts the dashboard under the wrong account.
- A restore puts the routes of a connection back where the connection is now: the connection of a user without a profile is in the phonebook for all users after a restore, and its routes are bound there.

## 1.9.0 — 2026-09-29

### Added
- **Connection method "Local (this computer)".** PRTG Mover can be installed on the PRTG server itself and back up or restore that server without any connection: no RDP, no WinRM, no credential. On the Servers page: **Add this computer**, or *Local* as the connection method. The test of such a server passes when PRTG Mover has administrator rights; without them the dashboard says so on the server row.
- `install.ps1 -Local` (needs an elevated PowerShell): adds this computer to the server list and registers the scheduled task *PRTG Mover Dashboard*, which starts the dashboard **when the computer starts, without anybody logging on**. It runs as SYSTEM, always the same account, so what is saved in the dashboard stays readable after every restart. The shortcut opens the running dashboard and starts the task when it is not running (`Open-PrtgMover.ps1`). The RDP button needs a desktop and is not available in a dashboard started this way; WinRM and Local work.
- **Backups of VPN connections and their routes.** Every backup that contains VPN connections now also contains, per connection, the routes bound to the connection, the live routes on its interface and the persistent routes that point into it (`vpn\routes\routes-<vpn>.json`, format `vpn-routes/1`, the same format VPN Watch uses). A restore puts missing routes back and removes nothing (*Routes of the VPN connections* in the restore dialog).
- **Backups page with two sections, PRTG and VPN.** *PRTG* lists the full backups. *VPN* lists backups of VPN connections and routes only, with the number of bound, live and persistent routes per connection; **Back up VPN and routes** makes one for the chosen server. Such a package is named `VPN_<computer>_<time>.zip`.
- `Setup-All.cmd` chooses local mode by itself when it runs as administrator on a computer where PRTG is installed, and sets VPN Watch up in local mode on a server.
- `/api/info` reports `elevated`.

### Fixed
- **`Setup-All.cmd` stopped after PRTG Mover and never installed VPN Watch.** The setup waited for the installer and for everything the installer had started, which included the dashboard that keeps running. It now waits for the installer only and starts the dashboards itself.

## 1.8.0 — 2026-09-29

### Added
- **One file that installs everything**: `tools\Build-SetupAll.ps1 -VpnWatchSource <folder>` builds `Setup-All.cmd`. The file contains PRTG Mover and VPN Watch (program files only, no servers, no credentials) and installs or updates both with a double-click: PRTG Mover to `C:\PrtgMover`, VPN Watch to `C:\VpnWatchDashboard`, shortcuts, start with Windows, and a test of both dashboards. A running PRTG Mover is only stopped for an update when no job is running.
- On a computer that has VPN connections of its own, and when the file is run as administrator, VPN Watch is set up in local mode and manages those connections directly.

## 1.7.1 — 2026-09-29

### Fixed
- **Starting the dashboard a second time** (for example with the shortcut while it is already running) opened a window that reported an error and nothing else happened. Now the running dashboard is opened in the browser and the second start ends without an error.
- A port that is used by another program is reported as such, with the hint to choose another port.
- `Start-PrtgMover.cmd` only waits for a key when the start failed.

### Added
- `install.ps1 -Autostart` starts the dashboard when you log on to Windows (shortcut in the Startup folder, minimized, without opening the browser). An update keeps it, `-NoAutostart` switches it off, `-Uninstall` removes it.
- `/api/info` names the product, so a running dashboard can be recognised.

### Changed
- `install.ps1 -Uninstall` only removes shortcuts that belong to the installation it removes. A shortcut that starts PRTG Mover from another folder is left alone.

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
