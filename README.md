<div align="center">

# PRTG Mover

**Back up, migrate and restore a complete PRTG Network Monitor server, including Windows VPN connections and desktop files, from one manager machine with a web dashboard.**

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-2563eb)
![Windows Server 2012 R2 – 2025](https://img.shields.io/badge/Windows%20Server-2012%20R2%20%E2%80%93%202025-0078d4)
![No dependencies](https://img.shields.io/badge/dependencies-none-15803d)
![License MIT](https://img.shields.io/badge/license-MIT-lightgrey)

[فارسی / Persian guide](README.fa.md) · [Architecture](docs/ARCHITECTURE.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Changelog](CHANGELOG.md)

</div>

---

## Contents

- [What it does](#what-it-does)
- [Connection methods: RDP or WinRM](#connection-methods-rdp-or-winrm)
- [Options at a glance](#options-at-a-glance)
- [What gets migrated](#what-gets-migrated)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start: migrate a PRTG server](#quick-start-migrate-a-prtg-server)
- [Dashboard](#dashboard)
- [Command line](#command-line)
- [Backup package format](#backup-package-format)
- [Security](#security)
- [Limitations and after-migration checklist](#limitations-and-after-migration-checklist)
- [Project layout](#project-layout)
- [Development](#development)

## What it does

PRTG Mover moves a PRTG core server to one or more new Windows servers without manual copying:

1. **Checks first.** Every server must be reachable with administrator rights and have enough disk space, and the PRTG versions must fit. If a check fails, nothing is changed anywhere.
2. **Copies from the source without touching it.** PRTG keeps running. The files are read from a Windows snapshot (VSS), so the copy is consistent, and the source needs no free disk space.
3. **Keeps a package on the manager.** Every backup is stored as one `.zip` with a manifest and a SHA-256 checksum, and can be downloaded from the dashboard.
4. **Restores on each target.** If PRTG is missing, the program itself is cloned from the source (no installer). A rollback copy of the target's own data is kept.
5. **Starts PRTG and proves it works.** The job only succeeds when core and probe are running, the web interface answers and everything is still stable 45 seconds later.

Failed or interrupted jobs can be **resumed**: finished steps and files that were already transferred are not repeated.

Everything runs in **plain Windows PowerShell 5.1**. Nothing is installed on the servers.

## Connection methods: RDP or WinRM

Each server uses **one** connection method, chosen in *Servers → Edit → Connection method for the script*:

| | **RDP (agent)**, the default | **WinRM** |
|---|---|---|
| What you need on the server | Nothing: only Remote Desktop access | PowerShell remoting enabled (`tools\Enable-PrtgMoverRemoting.ps1`) |
| Changes on the server | None | WinRM service and firewall rule |
| How it runs | **RDP** opens Remote Desktop with the manager's drive redirected. In an elevated PowerShell you paste one command (it's copied for you), and the **agent** takes its jobs from the dashboard. | Fully automatic from the manager |
| While a job runs | The Remote Desktop window must stay open (minimized is fine) | Nothing to keep open |
| File transfer | Through the redirected drive (`\\tsclient\…`) | Over WinRM in compressed chunks, several streams in parallel, resumable per file |
| Disk space needed on the source | None (staged on the manager) | None (pulled from the snapshot) |
| Best for | Servers you must not reconfigure | Unattended runs, scheduled backups, large data folders |

Both methods run exactly the same payload (`src\Remote\PrtgMover.Remote.ps1`) with the same checks and logs.

On **Backup & Migrate**, *How the files move* can override that for one job:

| Choice | Where the files go |
|---|---|
| Each server's saved method | Through this computer, using RDP or WinRM as saved on the server |
| RDP / WinRM | Through this computer, forcing that method for this job |
| **WireGuard** | Directly between the two Windows servers on `10.66.66.0/24`. The files move over WinRM to the other server's tunnel address (TCP 5985), and a short probe reports MB/s. This computer sends commands only and does not keep the backup. Needs a target. UDP 51820 must be open between the two public addresses. |
| **IPIP** | Same direct copy over WinRM to the tunnel address, on `10.66.67.0/24` (IP protocol 4). Needs a target. Protocol 4 must be open between the two public addresses. |

**Testing**: each server has a **Test RDP** button (RDP port, plus a full system check if the agent is running) and a **Test WinRM** button (WinRM login and a full system check). **Test all** tries both. The results are kept per method, and a server shows **PASS** when at least one method works. The row shows the result of each method.

## Options at a glance

| Option | Default | Effect |
|---|---|---|
| **Don't touch the source** | **on** | PRTG keeps running on the source, and nothing there is stopped, changed or deleted. Files are copied from a **VSS snapshot**. On a system without VSS it falls back to a live copy with a warning. |
| Source after backup | Keep stopped (migrate) / Restart (backup) | Only used when *Don't touch the source* is off: *Keep stopped*, *Stop & disable*, or **Restart & verify fully up**. |
| **Clone the PRTG program** | on | Copies the program folder and the Windows service definitions, so a target without PRTG needs no installer. |
| **Copy source license** | on | Copies the license to the target. When it's off, the target keeps its own license. |
| Historic monitoring data | on | Turn it off for a small, fast package that holds configuration only. |
| PRTG log files | off | Not needed for a migration. |
| Old automatic configuration copies | off | Not needed for a migration. |
| Windows VPN connections | on | All-user and per-user connections. |
| Desktop files | on | Desktops of every user and the Public desktop. |
| Start PRTG and verify | on | Full health check on every target. Services that stop during start-up are started again. |
| Open firewall | on | Adds an inbound rule on the target for the PRTG web ports and remote probes (TCP 23560). |
| Parallel transfer streams | 4 | WinRM only, 1 to 8. When files are pulled from a source, the number is limited by the CPU count of that server. |
| Dial VPN after restore | off | A full-tunnel VPN can cut the connection the manager is using. |
| Allow downgrade | off | Allows restoring onto an older PRTG version (not recommended). |

Cache and temp files (`*.tmp`, `PRTG Graph Data Cache*`, `*.old`, `*.bak`) and `desktop.ini` / `Thumbs.db` are never copied.

**Pre-flight checks** run before anything is changed:

- every server answers over its connection method, with administrator rights
- free disk space: the manager needs about 2.2 × the PRTG data (staging copy and package), each target about 1.2 ×, the source none
- the PRTG version on a target is not older than on the source
- a target without PRTG gets the clone, or an installer is selected

**Integrity checks**:

- The SHA-256 of `PRTG Configuration.dat` is compared between the source, the manager and every target.
- Every transferred chunk is checked (size after transfer, number of files after unpacking).
- The number of devices, sensors, notifications, triggers, users and other objects is counted on the source and again on the target, and both appear in the log.
- A backup without `PRTG Configuration.dat` is rejected, and a staging copy only counts as complete when the transfer finished and the configuration checksum matches.

## What gets migrated

| Area | Details |
|---|---|
| **PRTG configuration: everything** | `PRTG Configuration.dat` holds the whole PRTG object tree: probes, groups, devices, **sensors with all their settings, channels and limits**, **notification templates**, **notification triggers** on every object including inherited ones, **dependencies**, **schedules**, **users and user groups** with their rights, **maps, reports and libraries**, credentials stored in PRTG, **system settings** (SMTP/SMS delivery, core settings) and tags. The file is copied byte for byte. |
| PRTG data folder | Historic monitoring database (optional), tickets, toplists, report PDFs. The path comes from the registry (`Datapath`) and falls back to `%ProgramData%\Paessler\PRTG Network Monitor`. |
| PRTG program | The complete program folder and the two Windows services (core and probe), so the target runs the same version as the source. |
| PRTG registry | `HKLM\SOFTWARE\WOW6432Node\Paessler` and `HKLM\SOFTWARE\Paessler` (license, server and probe settings). |
| PRTG customisations | `Custom Sensors`, `Notifications` (EXE/scripts), `lookups\custom`, `devicetemplates`, `MIB`, `snmplibs`, `cert` (web server SSL certificate), `webroot\map*` / `webroot\custom`. |
| Web server binding | If the web server was bound to specific IP addresses, addresses of the source are replaced by the target's own address. Without this PRTG would only answer on `127.0.0.1`. |
| Windows VPN | All-user phonebook (`%ProgramData%\Microsoft\Network\Connections\Pbk\*.pbk`) and every user's own phonebook. Entries are **merged**: connections that already exist on the target are never overwritten. |
| Desktop files | `Desktop` of every local user profile plus the Public desktop, for example `.bat` files and VPN files. On the target, files go to the same user's desktop, or to `C:\PrtgMover-Restored\Desktop\<user>` if that profile doesn't exist. |
| Extra paths | Any folders or files you list, such as `D:\Scripts`, restored to the same path. |

## How it works

All data travels through the manager. The servers never talk to each other.

```
                 ┌──────────────── Manager (this repo) ────────────────┐
                 │ Start-PrtgMover.ps1 → http://localhost:8765          │
                 │ dashboard, REST API, jobs, logs, backups\*.zip       │
                 └───────────┬──────────────────────────────┬──────────┘
                RDP agent or WinRM                  RDP agent or WinRM
                             │                              │
        ┌────────────────────▼─────────┐      ┌─────────────▼────────────────┐
        │ SOURCE (old PRTG server)     │      │ TARGET(s) (new servers)      │
        │ 1 VSS snapshot, PRTG runs on │      │ 4 clone PRTG if missing      │
        │ 2 manager copies the files   │      │ 5 rollback copy, restore     │
        │ 3 snapshot and temp removed  │      │ 6 start PRTG, verify health  │
        └──────────────────────────────┘      └──────────────────────────────┘
```

The code that runs on the servers (`src\Remote\PrtgMover.Remote.ps1`) is sent with every call, so nothing is installed and nothing can get out of date. See [Architecture](docs/ARCHITECTURE.md) for the details.

## Requirements

| Machine | Requirement |
|---|---|
| **Manager** | Windows 10/11 or Windows Server 2012 R2+, Windows PowerShell 5.1, free disk space of about **2.2 × the PRTG data** during a migration. RDP method: the Remote Desktop client. WinRM method: access to the servers on TCP 5985 or 5986. |
| **Source** | Windows Server 2012 R2 – 2025 with PowerShell 5.1 and an administrator account. No free disk space needed. |
| **Target** | The same, with free disk space of about **1.2 × the PRTG data**. |
| **PRTG** | Only needed on the source. If PRTG is already installed on a target, it must be the same version or newer. |

Tested with PRTG 25.4 on Windows Server 2016 (source) and Windows Server 2022 (target).

## Installation

### 1. Get PRTG Mover on the manager

```powershell
git clone https://github.com/Digitalvps-Ir/prtg-mover.git C:\PrtgMover
cd C:\PrtgMover
```

(Or download the ZIP from GitHub and extract it.)

### 2. Start the dashboard

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-PrtgMover.ps1
```

You can also double-click `Start-PrtgMover.cmd`. Your browser opens `http://localhost:8765/`. The console window shows the live log of every job.

### 3. Choose the connection method

**RDP (default)** needs no preparation. Continue with the quick start.

**WinRM** needs PowerShell remoting on every server. Copy `tools\Enable-PrtgMoverRemoting.ps1` to the server and run it once in an **elevated** PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Enable-PrtgMoverRemoting.ps1 -ManagerAddress <manager-ip> -Https
```

This enables WinRM with an HTTPS listener (self-signed certificate, port 5986), allows remote administration with local administrator accounts, and opens the firewall **only for the manager's IP**. In the dashboard, tick *HTTPS* and *Skip certificate checks* for such a server.

Without `-Https` the script enables plain WinRM on port 5985. The manager then has to trust the server:

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Setup-Manager.ps1 -TrustedHosts 10.0.0.10,10.0.0.20
```

## Quick start: migrate a PRTG server

1. **Servers → Add server**: add the old PRTG server (role *Source*) and the new one (role *Target*), each with its connection method and administrator credential (for example `HOSTNAME\Administrator`).
2. **Test all**: every server should show `PASS`.
3. RDP method only: press **RDP** for each server, log in, and paste the agent command into an elevated PowerShell. Keep the Remote Desktop windows open.
4. **Backup & Migrate**: choose the source and tick the target(s). The box *What this job will do* lists exactly what is copied and what isn't. Press **Migrate**.
5. Follow the live log under **Jobs**. When it finishes, each target shows `PRTG ok` and the address where the web interface answered.
6. Work through the [after-migration checklist](#limitations-and-after-migration-checklist).

A **backup only** run is the same, just without ticking any target.

If a job fails, fix the cause shown in the log and press **Resume**.

## Dashboard

| Page | Purpose |
|---|---|
| **Overview** | Counters, recent jobs and a short summary of the process. |
| **Servers** | Inventory with connection method, RDP and WinRM port, live reachability badges (**Check ports**), agent status, PRTG version and **license state**. Buttons per server: **RDP** (opens Remote Desktop and copies the agent command), **Test RDP**, **Test WinRM**, Edit, Delete. |
| **Backup & Migrate** | One source → any number of targets, with all options and a plain-language summary of the job. |
| **Backups** | The **package store on the manager**. **Download** a package, **restore** it to one or more servers at any time, **upload** a package made elsewhere, or delete it. |
| **Jobs** | Phase stepper, progress, colour-coded live log, per-target result, **Resume / Retry**, Cancel, log download. *Show debug* adds the exact error position, stack and timings. |
| **Logs & Audit** | Audit trail (who did what), the manager log of the day, and **Download diagnostics**: one zip with all logs and an environment report, without passwords. |

**Make PRTG reachable** only appears when the test finds a PRTG that answers on `127.0.0.1` only, because its web server is still bound to another server's address. The button binds it to the server's own address and restarts PRTG there. Migrations do this automatically.

The dashboard listens on `localhost` only. To reach it from another machine on a trusted management network, run `tools\Setup-Manager.ps1 -DashboardPort 8765` once, then `Start-PrtgMover.ps1 -ListenAll`.

## Command line

The same engine is available for scripts and scheduled tasks:

```powershell
# Connectivity test (prompts for a credential)
.\cli\Invoke-PrtgMover.ps1 -Action Test -Source 10.0.0.10 -Credential (Get-Credential)

# Nightly backup of an inventory server, keep the last 7 packages (the source is not touched)
.\cli\Invoke-PrtgMover.ps1 -Action Backup -Source PRTG-OLD -KeepLast 7

# Migration to two servers with 6 parallel streams
.\cli\Invoke-PrtgMover.ps1 -Action Migrate -Source PRTG-OLD -Target PRTG-NEW1,PRTG-NEW2 -Streams 6

# Migration that stops and disables PRTG on the old server
.\cli\Invoke-PrtgMover.ps1 -Action Migrate -Source PRTG-OLD -Target PRTG-NEW -AllowSourceStop -SourceAfter Disable

# Restore an existing package
.\cli\Invoke-PrtgMover.ps1 -Action Restore -BackupName PRTG_OLDSRV_20260928-221500.zip -Target PRTG-NEW1

# Bind the web server of a migrated PRTG to the server's own address
.\cli\Invoke-PrtgMover.ps1 -Action FixBinding -Target PRTG-NEW1
```

Other switches: `-NoPrtg -NoHistory -NoVpn -NoDesktop -ExtraPaths -NoProgramClone -NoLicense -NoFirewall -NoStart -HealthTimeoutMinutes -ConnectVpn -AllowDowngrade -InstallerFile -SkipPreflight`.
Exit codes: `0` success, `1` failure, `2` finished with errors on a target.

Servers that are not in the inventory are addressed by host name and use WinRM.

## Backup package format

`backups\PRTG_<SOURCE>_<yyyyMMdd-HHmmss>.zip`:

```
manifest.json              source, PRTG version and paths, checksums, object counts, VPN names, desktop files
prtg\data\...              PRTG data folder
prtg\programfull\...       complete PRTG program folder (clone)
prtg\services\*.reg        definitions of the PRTG Windows services
prtg\program\<folder>\...  program customisations (Custom Sensors, cert, lookups\custom, ...)
prtg\registry\*.reg        exported Paessler registry keys
vpn\allusers\*.pbk         all-user VPN phonebooks
vpn\users\<user>\*.pbk     per-user VPN phonebooks
vpn\vpn-connections.json   readable list of the VPN connections
desktop\<user>\...         desktop files
extra\<n>\...              extra paths
```

The manager keeps `<package>.zip.meta.json` next to each package (SHA-256 and manifest) for the dashboard. You can open packages with any ZIP tool.

## Security

- **Passwords are never written in plain text.** Credentials saved in the dashboard are encrypted with Windows DPAPI (`Export-Clixml`). Only the same Windows user on the same manager machine can decrypt them. `config\servers.json` holds no secrets.
- **The dashboard listens on `localhost` by default** and does not ask for an access token.
- **Restrict WinRM** to the manager's IP (`-ManagerAddress`), and use **HTTPS (5986)** whenever servers are reached over the internet. When the migration is done, you can remove the firewall rule or disable WinRM again.
- **The RDP agent** only runs while you keep its window open, and it only accepts the functions PRTG Mover needs.
- **Backups contain sensitive data**: the PRTG configuration (including encrypted device credentials), the license and the SSL private key. Store and share them like a password vault export.
- **Logs and the diagnostics bundle** contain no passwords and no token.
- `backups/`, `data/` and `config/servers.json` are in `.gitignore`. **Never commit them.**

## Limitations and after-migration checklist

- **Two cores at once**: with *Don't touch the source* the old PRTG keeps running, so both servers monitor and send notifications until you stop the old one.
- **License activation**: PRTG binds a license to the system it was activated on. The license key is copied, but on the new server PRTG reports *No License (System Changed)* and pauses the sensors until the license is activated there (*Setup → License Information*, or through Paessler if the server can't reach the activation service). PRTG Mover shows this state and the last activation error. It doesn't activate licenses, and it never changes the license on the source.
- **License use**: check with your license terms how many cores may run at the same time, and stop the old core when the new one is verified.
- **Devices that only allow the old IP**: if monitored devices restrict SNMP, WMI or API access to the old server's address, allow the new address there.
- **Remote probes** connect to the core's IP or DNS name. If the new core has a different address, update the DNS record or change the core address on each remote probe (*PRTG Administration Tool → Probe settings*).
- **Saved VPN passwords and machine certificates** are protected by Windows DPAPI and can't be moved. Enter the VPN credentials once on the new server, and import any IKEv2/SSTP certificates.
- **Service account**: cloned services run as LocalSystem. If the source ran PRTG under another account, set it again in `services.msc`.
- **Target version**: it must be equal to or newer than the source. Older is blocked unless you enable *Allow downgrade*.
- **Data drive**: if the source data folder lives on a drive the target doesn't have (for example `D:`), the target's default data path is used and the registry is updated.
- **Rollback**: if a target already had PRTG data, it is kept as `<datapath>.pre-restore-<timestamp>`, and its registry is saved in `C:\PrtgMover\rollback\<timestamp>`.
- **Manager clock**: if the manager's clock is behind, a fresh WinRM HTTPS certificate looks invalid. The tool waits until it becomes valid. Syncing the clock ends the wait.

## Project layout

```
Start-PrtgMover.ps1 / .cmd       dashboard (HttpListener) + REST API
cli\Invoke-PrtgMover.ps1         command-line front end
src\PrtgMover.psm1               manager engine: inventory, credentials, sessions, transfers, jobs
src\Remote\PrtgMover.Remote.ps1  code executed on source / target servers
agent\PrtgMover-Agent.ps1        agent for the RDP connection method
web\                             dashboard UI (vanilla HTML/CSS/JS, no build step)
tools\Enable-PrtgMoverRemoting.ps1   WinRM method: run once on every server
tools\Setup-Manager.ps1          optional manager preparation (TrustedHosts, dashboard on the LAN)
tests\                           Pester 5 tests
docs\                            architecture, troubleshooting
```

Runtime folders created automatically: `backups\`, `installers\`, `data\` (token, credentials, jobs, logs, agent files, staging) and `config\servers.json`.

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

The suite covers the whole backup, transfer and restore path without any server: the `local` connection method runs the payload in the test process, and the RDP agent is started as a local process.

CI (GitHub Actions, `windows-latest`, Windows PowerShell 5.1) parses every script, runs PSScriptAnalyzer and the Pester suite on each pull request and on each push to `main`.

## License

[MIT](LICENSE)
