# Changelog

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
