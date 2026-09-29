<div align="center">

# PRTG Mover

**Back up, migrate and restore a complete PRTG Network Monitor server, including Windows VPN connections and desktop files, from one manager machine with a web dashboard.**

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-2563eb)
![Windows Server 2012 R2 – 2025](https://img.shields.io/badge/Windows%20Server-2012%20R2%20%E2%80%93%202025-0078d4)
![No dependencies](https://img.shields.io/badge/dependencies-none-15803d)
![License MIT](https://img.shields.io/badge/license-MIT-lightgrey)

[فارسی / Persian guide](README.fa.md) · [Architecture](docs/ARCHITECTURE.md) · [Troubleshooting](docs/TROUBLESHOOTING.md)

</div>

---

## Contents

- [What it does](#what-it-does)
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

1. **Stops PRTG** on the source cleanly, so the core writes its configuration to disk.
2. **Packages** the PRTG data folder, registry, SSL certificate, custom sensors, lookups, MIBs, device templates, map objects, **Windows VPN connections**, **desktop files of all users** and any extra paths you add into a single `.zip`, with a manifest and a SHA-256 checksum.
3. **Downloads** the package to the manager. Every backup stays there and can be **downloaded from the dashboard**.
4. **Restores** it on each target. If PRTG is missing it installs it silently, keeps a rollback copy of the target's own data and registry, restores everything, and **starts PRTG automatically**.
5. **Verifies** that the PRTG web interface answers on every target before the job is marked successful.

Everything runs in **plain Windows PowerShell 5.1**. You don't need to install anything on the servers except enabling WinRM.

## Connection methods: RDP or WinRM

Each server uses **one** connection method, chosen in *Servers → Edit → Connection method for the script*:

| | **RDP (agent)**, the default | **WinRM** |
|---|---|---|
| What you need on the server | Nothing: only Remote Desktop access | PowerShell remoting enabled (`tools\Enable-PrtgMoverRemoting.ps1`) |
| Changes on the server | None | WinRM service and firewall rule |
| How it runs | **RDP** opens Remote Desktop with the manager's drive redirected. In an elevated PowerShell you paste one command (it's copied for you), and the **agent** takes its jobs from the dashboard. | Fully automatic from the manager |
| File transfer | Through the redirected drive (`\\tsclient\…`) | Through the WinRM session |
| Best for | Servers you must not reconfigure, and internet-facing servers without WinRM | Many servers, and unattended or scheduled backups |

Both methods run exactly the same payload (`src\Remote\PrtgMover.Remote.ps1`) with the same checks and logs.

**Testing**: each server has a **Test RDP** button (RDP port, plus a full system check if the agent is running) and a **Test WinRM** button (WinRM login and a full system check). **Test all** tries both, and a server shows **PASS** when at least one method works. The row shows the result of each method (RDP ✓/✗, WinRM ✓/✗).

## Options at a glance

| Option | Default | Effect |
|---|---|---|
| **Don't touch the source** | **on** | PRTG keeps running on the source, and nothing there is stopped, changed or deleted. The data folder is copied from a **VSS snapshot** so the copy is consistent. On a workstation OS without VSS it falls back to a live copy with a warning. |
| **Source after backup** | Keep stopped (migrate) / Restart (backup) | *Keep stopped*, *Stop & disable*, or **Restart & verify fully up**. With the last one the job waits until core and probe are Running, the web UI answers, and everything is still stable 45 s later, and it fails otherwise. |
| **Copy source license** | on | Copies the license (registry values and license files) to the target. When it's off, the target keeps its own license. |
| Historic monitoring data | on | Leave it off for a much smaller, faster package that holds configuration only. |
| Start PRTG and verify | on | Same full health check on every target: services, web interface and stability. Stopped services are restarted automatically. |
| Open firewall | on | Adds an inbound rule on the target for the PRTG web ports and remote probes (TCP 23560). |
| Allow downgrade | off | Allows restoring onto an older PRTG version (not recommended). |

**Pre-flight checks** run before anything is changed. They cover WinRM reachability, administrator rights, free disk space on the source (2× data) and targets (2.5× data), PRTG versions, and whether an installer is selected. If any check fails, nothing is touched on any server.

**Integrity checks**:
- The package's SHA-256 is checked on the manager and again on every target.
- The SHA-256 of `PRTG Configuration.dat` is compared between source and target.
- A backup without `PRTG Configuration.dat` is rejected.

## What gets migrated

| Area | Details |
|---|---|
| **PRTG configuration: everything** | `PRTG Configuration.dat` holds the whole PRTG object tree: probes, groups, devices, **sensors with all their settings, channels and limits**, **notification templates**, **notification triggers** (state, threshold, speed, volume, change) on every object including inherited ones, **dependencies**, **schedules**, **users and user groups** with their rights, **maps, reports and libraries**, credentials stored in PRTG, **system settings** (SMTP/SMS delivery, cluster, core settings) and tags. The file is copied byte for byte and SHA-256 verified. The tool also counts devices, sensors, notifications, triggers, users and so on on the source and again on the target, and shows both counts in the log. |
| PRTG data folder | Historic monitoring database (optional), logs, tickets, toplists, report PDFs, configuration auto-backups. The path comes from the registry (`Datapath`) and falls back to `%ProgramData%\Paessler\PRTG Network Monitor`. |
| PRTG registry | `HKLM\SOFTWARE\WOW6432Node\Paessler` and `HKLM\SOFTWARE\Paessler` (license key, server and probe settings, encryption settings). |
| PRTG program customisations | `Custom Sensors`, `Notifications` (EXE/scripts), `lookups\custom`, `devicetemplates`, `MIB`, `snmplibs`, `cert` (web server SSL certificate), `webroot\map*` / `webroot\custom`. |
| Windows VPN | All-user phonebook (`%ProgramData%\Microsoft\Network\Connections\Pbk\*.pbk`) and every user's own phonebook. Entries are **merged**: connections that already exist on the target are never overwritten. |
| Desktop files | `Desktop` of every local user profile plus the Public desktop. On the target, files go to the same user's desktop, or to `C:\PrtgMover-Restored\Desktop\<user>` if that profile doesn't exist. |
| Extra paths | Any folders or files you list, such as `D:\Scripts`, restored to the same path. |

## How it works

```
          ┌───────────────────────── Manager (this repo) ─────────────────────────┐
          │  Start-PrtgMover.ps1  →  http://localhost:8765  (dashboard + REST API)  │
          │  src\PrtgMover.psm1   →  jobs, sessions, credentials (DPAPI), backups   │
          └───────────────┬───────────────────────────────────────┬────────────────┘
               WinRM 5985/5986 (PowerShell remoting)      WinRM 5985/5986
                          │                                        │
          ┌───────────────▼──────────────┐         ┌───────────────▼──────────────┐
          │ SOURCE  (old PRTG server)    │         │ TARGET(s) (new servers)      │
          │ 1 stop PRTG                  │  .zip   │ 4 install PRTG if missing    │
          │ 2 copy data/registry/VPN/... │ ──────► │ 5 rollback copy, restore     │
          │ 3 zip + SHA-256              │ via mgr │ 6 start PRTG, wait for web UI│
          └──────────────────────────────┘         └──────────────────────────────┘
```

The code that runs on the servers (`src\Remote\PrtgMover.Remote.ps1`) is sent with every call. Nothing is installed on the servers, and there's no agent to keep up to date.

## Requirements

| Machine | Requirement |
|---|---|
| **Manager** | Windows 10/11 or Windows Server 2012 R2+, Windows PowerShell 5.1, network access to the servers on TCP 5985 (or 5986), enough free disk space for the backups. |
| **Source / target** | Windows Server 2012 R2 – 2025 with PowerShell 5.1, WinRM enabled (see below), an administrator account, and free disk space of about **2 × the PRTG data folder** (staging + zip). |
| **PRTG** | Only needed on the source. When the target has no PRTG, the **program itself is cloned** from the source (program files and Windows services, same version), so no installer is needed. If PRTG is already on the target, it must be the same version or newer. |

## Installation

### 1. Get PRTG Mover on the manager

```powershell
git clone https://github.com/Digitalvps-Ir/prtg-mover.git C:\PrtgMover
cd C:\PrtgMover
```

(Or download the ZIP from GitHub and extract it.)

### 2. Prepare every source and target server (once)

Connect with RDP, copy `tools\Enable-PrtgMoverRemoting.ps1` over, and run it in an **elevated** PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File .\Enable-PrtgMoverRemoting.ps1 -ManagerAddress <manager-ip>
```

This enables WinRM, allows remote administration with local admin accounts (`LocalAccountTokenFilterPolicy`), raises the WinRM limits and opens the firewall **only for the manager's IP**. If the servers are reached over the internet, use HTTPS as well:

```powershell
powershell -ExecutionPolicy Bypass -File .\Enable-PrtgMoverRemoting.ps1 -ManagerAddress <manager-ip> -Https
```

### 3. Prepare the manager (once, elevated)

```powershell
powershell -ExecutionPolicy Bypass -File .\tools\Setup-Manager.ps1 -TrustedHosts 10.0.0.10,10.0.0.20
```

This adds the servers to WinRM *TrustedHosts*, which you need when you address servers by IP or they aren't in the same domain. It also unblocks the downloaded scripts.

### 4. Start the dashboard

```powershell
powershell -ExecutionPolicy Bypass -File .\Start-PrtgMover.ps1
```

You can also double-click `Start-PrtgMover.cmd`. Your browser opens `http://localhost:8765/?token=…`. The token is stored in `data\token.txt`.

## Quick start: migrate a PRTG server

1. **Servers → Add server**: add the old PRTG server (role *Source*) and the new one (role *Target*), each with its administrator credential (for example `HOSTNAME\Administrator`).
2. **Test all**: every server should show `ok`, and the source should show its PRTG version and data size.
3. *(Only if PRTG isn't installed on the target yet.)* **Backup & Migrate → Upload installer**: upload the PRTG installer of the **same version** as the source (the *PRTG Network Monitor* setup `.exe` or the `.zip` from Paessler).
4. **Backup & Migrate**: choose the source, tick the target(s), keep *Source after backup = Keep stopped*, and press **Migrate**.
5. Follow the live log under **Jobs**. When it finishes, each target shows `PRTG ok` and the URL where the web interface answered.
6. Work through the [after-migration checklist](#limitations-and-after-migration-checklist).

A **backup only** run is the same, just without ticking any target. The source is restarted right after the backup.

## Dashboard

| Page | Purpose |
|---|---|
| **Overview** | Counters, recent jobs and a short summary of the process. |
| **Servers** | Inventory with **RDP port** (default 3389, editable) and WinRM port, live **RDP / WinRM reachability** badges (**Check ports**), an **RDP** button that opens Remote Desktop from the manager, a connectivity test (OS, admin rights, PRTG version and data size, VPNs, disks, the server's real RDP port) and credentials. |
| **Backup & Migrate** | One source → any number of targets. Choose what to include, what happens to the source afterwards, the installer and the health-check timeout. |
| **Backups** | The **package store on the manager**. Every backup or migration first creates a package (`.zip` with PRTG, VPN, desktops and a manifest), and it's kept here. From this page you can **download** a package (an offline copy of your PRTG), **restore** it to one or more servers at any time (for example to roll back, or to build another server later), **upload** a package made elsewhere, or delete it. |
| **Jobs** | Live progress bar, step and colour-coded log for every job, per-target result, cancel, and full log download. |

The dashboard listens on `localhost` only. To reach it from another machine on a trusted management network, run `tools\Setup-Manager.ps1 -DashboardPort 8765` once, then `Start-PrtgMover.ps1 -ListenAll`.

## Command line

The same engine is available for scripts and scheduled tasks:

```powershell
# Connectivity test (prompts for a credential)
.\cli\Invoke-PrtgMover.ps1 -Action Test -Source 10.0.0.10 -Credential (Get-Credential)

# Nightly backup of an inventory server, keep the last 7 packages
.\cli\Invoke-PrtgMover.ps1 -Action Backup -Source PRTG-OLD -KeepLast 7

# Migration to two servers; old server stopped and disabled
.\cli\Invoke-PrtgMover.ps1 -Action Migrate -Source PRTG-OLD -Target PRTG-NEW1,PRTG-NEW2 -SourceAfter Disable

# Restore an existing package, installing PRTG from installers\ if needed
.\cli\Invoke-PrtgMover.ps1 -Action Restore -BackupName PRTG_OLDSRV_20260928-221500.zip -Target PRTG-NEW1 -InstallerFile PRTG_Installer.exe
```

```powershell
# Backup: the source is NOT touched (default, VSS snapshot)
.\cli\Invoke-PrtgMover.ps1 -Action Backup -Source PRTG-OLD                   # default: source untouched

# Migrate without copying the license (the target keeps its own)
.\cli\Invoke-PrtgMover.ps1 -Action Migrate -Source PRTG-OLD -Target PRTG-NEW -NoLicense
```

Other switches: `-NoPrtg -NoHistory -NoVpn -NoDesktop -ExtraPaths -NoStart -HealthTimeoutMinutes -ConnectVpn -AllowDowngrade -AllowSourceStop -NoLicense -NoFirewall -SkipPreflight`.
Exit codes: `0` success, `1` failure, `2` finished with errors on a target.

## Backup package format

`backups\PRTG_<SOURCE>_<yyyyMMdd-HHmmss>.zip`:

```
manifest.json              source, PRTG version and paths, VPN names, desktop users, extra paths
prtg\data\...              PRTG data folder
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
- **The dashboard needs a token**, and it listens on `localhost` by default.
- **Restrict WinRM** to the manager's IP (`-ManagerAddress`), and use **HTTPS (5986)** whenever servers are reached over the internet.
- **Backups contain sensitive data**: the PRTG configuration (including encrypted device credentials), the license key and the SSL private key. Store and share them like a password vault export.
- `backups/`, `data/` and `config/servers.json` are in `.gitignore`. **Never commit them.**

## Limitations and after-migration checklist

- **License**: a PRTG license may only run on one core at a time. Keep the old core stopped (the default for a migration). If PRTG asks for it, re-activate the license on the new server.
- **Remote probes** connect to the core's IP or DNS name. If the new core has a different address, update the DNS record or change the core address on each remote probe (*PRTG Administration Tool → Probe settings*).
- **Saved VPN passwords and machine certificates** are protected by Windows DPAPI and can't be moved. Enter the VPN credentials once on the new server, and import any IKEv2/SSTP certificates.
- **Target version**: it must be equal to or newer than the source. Older is blocked unless you enable *Allow downgrade*.
- **Data drive**: if the source data folder lives on a drive the target doesn't have (for example `D:`), the target's default data path is used and the registry is updated.
- **Rollback**: each target keeps its previous data folder as `<datapath>.pre-restore-<timestamp>` and its registry in `C:\PrtgMover\rollback\<timestamp>`.
- **"Dial VPN after restore"** is off by default. A full-tunnel VPN can cut the WinRM connection the manager is using.

## Project layout

```
Start-PrtgMover.ps1 / .cmd     dashboard (HttpListener) + REST API
cli\Invoke-PrtgMover.ps1       command-line front end
src\PrtgMover.psm1             manager engine: inventory, credentials, sessions, jobs, flows
src\Remote\PrtgMover.Remote.ps1  code executed on source / target servers
web\                           dashboard UI (vanilla HTML/CSS/JS, no build step)
tools\Enable-PrtgMoverRemoting.ps1   run once on every server
tools\Setup-Manager.ps1        run once on the manager
tests\                         Pester 5 tests
docs\                          architecture, troubleshooting
```

Runtime folders created automatically: `backups\`, `installers\`, `data\` (token, credentials, job logs, status) and `config\servers.json`.

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

CI (GitHub Actions, `windows-latest`, Windows PowerShell 5.1) parses every script, runs PSScriptAnalyzer and the Pester suite on each push and pull request.

## License

[MIT](LICENSE)
