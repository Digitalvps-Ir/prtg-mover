<div align="center">

# PRTG Manager

**Back up, restore and migrate PRTG Network Monitor servers from one web dashboard: the whole PRTG, or only its history, devices, notifications, triggers or license — always with a preview before anything changes.**

![PowerShell 5.1+](https://img.shields.io/badge/PowerShell-5.1%2B-2563eb)
![Windows Server 2012 R2 – 2025](https://img.shields.io/badge/Windows%20Server-2012%20R2%20%E2%80%93%202025-0078d4)
![No dependencies](https://img.shields.io/badge/dependencies-none-15803d)
![License MIT](https://img.shields.io/badge/license-MIT-lightgrey)

[فارسی / Persian guide](README.fa.md) · [Architecture](docs/ARCHITECTURE.md) · [Troubleshooting](docs/TROUBLESHOOTING.md) · [Changelog](CHANGELOG.md)

</div>

---

PRTG Manager was called **PRTG Mover** up to version 1.9. Windows VPN connections and their routes are no longer part of it: they are backed up, restored and migrated by **VPN Manager** (the former VPN Watch). See [Coming from PRTG Mover](#coming-from-prtg-mover).

## Contents

- [What it does](#what-it-does)
- [Backup types](#backup-types)
- [Restore: preview first, rollback built in](#restore-preview-first-rollback-built-in)
- [License](#license-page)
- [Connection methods](#connection-methods)
- [Installation](#installation)
- [Quick start: migrate a PRTG server](#quick-start-migrate-a-prtg-server)
- [Dashboard](#dashboard)
- [Command line](#command-line)
- [Backup package format (version 2)](#backup-package-format-version-2)
- [Security](#security)
- [Limitations and after-migration checklist](#limitations-and-after-migration-checklist)
- [Coming from PRTG Mover](#coming-from-prtg-mover)
- [Project layout](#project-layout)
- [Development](#development)

## What it does

1. **Checks first.** Every server must answer with administrator rights, have enough disk space, and the PRTG versions must fit. If a check fails, nothing is changed anywhere.
2. **Reads the source without touching it.** PRTG keeps running. Files come from a Windows snapshot (VSS); configuration parts are read from `PRTG Configuration.dat` without writing anything.
3. **Keeps every package on the manager** with metadata, checksums and an optional backup password — ready to validate, inspect, download and restore.
4. **Restores with a preview.** You see exactly what is created, updated, skipped, what conflicts and what is missing, before anything changes.
5. **Proves PRTG works** afterwards (core and probe running, web interface answering, stable 45 s later) — and puts the previous state back automatically when it does not.

Everything runs in plain **Windows PowerShell 5.1**. Nothing is installed on the servers.

## Backup types

| Type | Contents | On the source |
|---|---|---|
| **Full** | PRTG configuration (all objects), data folder with history (optional), program clone and Windows services, registry, license, SSL certificate, customisations (custom sensors, notification scripts, lookups, MIBs, device templates, maps), desktop files and extra paths (optional). With targets ticked this is a migration. | VSS snapshot, PRTG keeps running |
| **History** | `Monitoring Database` — the data PRTG draws graphs and tables from — all of it or the last *N* days, plus the list of devices it belongs to. | VSS snapshot |
| **Devices** | The whole device tree: probes, groups, devices, sensors with all settings, channels and their triggers, hierarchy. | read-only |
| **Notifications** | Notification templates (e-mail, push, SMS, HTTP, program, syslog, SNMP trap, Teams, Slack …) and the schedules they use. | read-only |
| **Triggers** | Every trigger (state, threshold, speed, volume, change) of every probe, group, device and sensor, with the object it belongs to. | read-only |
| **License** | License name, key, activation data and license files — **always encrypted on the server** with a backup password; the key never travels or rests in clear. | read-only |

Only what PRTG needs is packed: no log files, caches (`PRTG Graph Data Cache*`), temp files or old automatic configuration copies unless you ask for them.

Any package can be **encrypted with a backup password** (AES-256-CBC + HMAC-SHA256, key from PBKDF2-SHA256 with 200 000 rounds). A wrong password or a changed file is detected before anything is decrypted or restored.

## Restore: preview first, rollback built in

Every package has **Restore…** on the Backups page. The dialog asks for the target(s) and the options, then **Preview** reads the target (nothing is changed) and shows:

| | Full | History | Devices / Notifications / Triggers | License |
|---|---|---|---|---|
| Items to create / update / skip | configuration, data folder, license, registry, customisations | new files, files already there | every object with its action and reason | current license → the one in the backup |
| Conflicts | — | — | **ID conflicts** (the id belongs to another object on the target), changed triggers | — |
| Blockers / dependencies | older PRTG on the target, disk space, no PRTG and no clone, no admin rights | PRTG missing, devices the target does not have | newer configuration format, missing notifications / schedules / dependencies | password, PRTG missing |

**Restore** is only enabled after a preview without blockers; a full restore additionally needs an explicit confirmation.

Modes for configuration parts:

- **Merge** — only add what is missing; existing objects are never changed (differences are listed as conflicts).
- **Overwrite** — also update existing objects with the saved settings (data, triggers, channels); their children and history stay.
- **New ids for conflicts** — an object whose id is taken by another object on the target is created with a new id (with everything below it; dependencies inside it follow).

**Rollback**:

- *Full restore*: the target's data folder is kept as `<data>.pre-restore-<time>` and its registry is exported. If the restore fails or PRTG does not come up, both are **put back automatically** and PRTG is started again (*Roll back automatically* is on by default). **Cancel** in the middle of a restore does the same: once PRTG has been stopped, the previous data folder, registry and firewall state are put back (log: `<work folder>\rollback\cancelled-restore-<time>.log`). A failure before anything was changed starts PRTG again.
- *Configuration parts*: `PRTG Configuration.dat` is copied to `C:\PrtgMover\rollback\config-<time>` first; the change is written through a temp file that must parse; if PRTG does not come up, the copy is put back.
- *License*: the current license data is saved in `C:\PrtgMover\rollback\license-<time>` first.
- *History*: files that exist are kept (merge) or replaced (overwrite); nothing is deleted; the graph cache is set aside so PRTG recalculates the graphs.

A server with the role **Source** is never restored into. Its license and web binding are never changed either. On a PRTG server with PRTG Manager installed locally, set the role of this computer to **Source** (Servers > Edit, or `install.ps1 -Local -Role source`) - the installer adds it as *both*.

Only one job that stops or changes PRTG (restore, migration, backup, license change, web binding) runs per server at a time; a second one is refused with the running job named.

## License page

| Action | What happens |
|---|---|
| **Refresh status** | Edition, licensed name, sensors, activation state, the last activation message of PRTG, which license values exist (no values shown), system-id fingerprint. |
| **Add free trial license** | Enter the trial name and key Paessler e-mails you after registering on [paessler.com/prtg/download](https://www.paessler.com/prtg/download). |
| **Activate an authorized license** | Enter the name and key of a license you own (site, enterprise …) as shown in the [Paessler shop](https://shop.paessler.com). |
| **Back up license** | Encrypted license backup (see above). |
| **Restore license from backup** | Through the restore dialog, with preview. |
| **Remove license** | Removes license name, key and the activation of that key (and license files); PRTG's own bookkeeping (install date, paused-sensor counter) stays. Needs the server name typed as confirmation. A copy is kept on the server. |

Installing a key works like the *PRTG Administration Tool*: PRTG is stopped, name and key are written, PRTG is started and **PRTG itself activates the key online with Paessler**. PRTG Manager then reads only the log lines written after that start and explains the result (for example *HTTP 403: the key is active on another system — move the activation in the Paessler shop*).

What PRTG Manager deliberately does **not** do: generate, fetch or change license keys, reset trials, bypass or fake an activation. Paessler has no public interface that hands out keys, so "retrieve from the internet" means: you take the key from the Paessler shop or e-mail and PRTG Manager activates it. Offline activation stays in the PRTG web interface (*Setup › License Status*).

## Connection methods

Each server uses one connection method (*Servers → Edit*):

| | **Local** | **RDP (agent)** | **WinRM** |
|---|---|---|---|
| Where PRTG Manager runs | on the PRTG server itself | on a manager computer | on a manager computer |
| Needed on the server | nothing (run as administrator) | Remote Desktop access | PowerShell remoting (`tools\Enable-PrtgManagerRemoting.ps1`) |
| While a job runs | — | the Remote Desktop window stays open | nothing |

All methods run the same payload (`src\Remote\PrtgManager.Remote.ps1`). Changing a license or restoring a configuration part needs *Local* or *WinRM*. For migrations, *How the files move* can also be WireGuard or IPIP (a tunnel between the two servers).

## Installation

Double-click **`install.cmd`**, or:

```powershell
git clone https://github.com/Digitalvps-Ir/prtg-mover.git
cd prtg-mover
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

The installer copies the program to `C:\PrtgManager` (an existing PRTG Mover installation in `C:\PrtgMover` is updated where it is), tests every script and the dashboard, creates the shortcut **PRTG Manager** and starts the dashboard on `http://localhost:8765/`.

| Option | Meaning |
|---|---|
| `-InstallPath <folder>` | Install into another folder. |
| `-Source <folder or zip>` | Install from there instead of the installer's own folder. |
| `-Local` | PRTG Manager on the PRTG server itself (elevated): this computer is added with the connection method *Local* and the dashboard starts with the computer. A watchdog starts it again within 5 minutes if it stops. |
| `-Role both|source|target` | With `-Local`: role of this computer in the server list (default *both*). A *source* is never restored into. |
| `-Autostart` / `-NoAutostart` | Start with Windows on / off. |
| `-TrustedHosts a,b` | Prepare plain WinRM (HTTP) to these servers. |
| `-Port`, `-NoShortcut`, `-NoStart`, `-Uninstall` | Self-explanatory. |

Your data (`config\`, `data\`, `backups\`, `installers\`) is never touched by an update or an uninstall.

**PRTG Manager and VPN Manager in one file:** `tools\Build-SetupAll.ps1 -VpnManagerSource <VPN Manager folder>` builds `Setup-All.cmd`. Double-click it on a Windows computer: it installs or updates both (PRTG Manager in `C:\PrtgManager`, VPN Manager in `C:\VpnManager`; older installations are updated in place), creates the shortcuts, starts both with Windows and tests both dashboards. Options: `-SkipPrtgManager`, `-SkipVpnManager`, `-PrtgManagerPath`, `-VpnManagerPath`, `-NoAutostart` (the old names such as `-PrtgMoverPath` still work).

## Quick start: migrate a PRTG server

1. **Servers → Add server**: the old PRTG server (role *Source*) and the new one (role *Target*).
2. **Test all** — every server should show `PASS`.
3. **Backup & Migrate** → *Full* → tick the target(s) → **Migrate**. The box *What this job will do* lists exactly what is copied.
4. Follow the live log under **Jobs**. Each target ends with `PRTG ok` and its web address — or `rolled back` with the reason.
5. **License** page on the target: PRTG asks Paessler for a new activation there.

## Dashboard

| Page | Purpose |
|---|---|
| **Overview** | Counters and recent jobs. |
| **Servers** | Inventory, connection method, ports, tests, PRTG version, license badge. |
| **Backup & Migrate** | Backup type, options, backup password, migration targets, plain-language summary. |
| **Backups** | Name, type, source, created, size, format and PRTG version, encrypted, valid — **Download, Validate, Inspect, Restore, Delete** (to the Recycle Bin; when the dashboard runs as SYSTEM - the task at system start - it deletes permanently and says so first, because SYSTEM's Recycle Bin is not visible and frees no space). Upload of `.zip` / `.pmenc`. **Leftovers on this computer**: unpacked packages, temporary restore stages, rollback copies, previous PRTG data folders and VSS snapshots of interrupted runs, with sizes and Remove. |
| **License** | Status, trial / authorized key, backup, restore, removal. |
| **Jobs** | Progress, live log, per-target results, Resume / Retry, Cancel, log download. |
| **Logs & Audit** | Audit trail (backups, restores, validations, license changes, deletions) and the manager log. |

Errors say what failed, where, why and what to do, for example *Delete backup failed on PRTG-FULL_X.zip: the file could not be moved to the Recycle Bin (…) — Nothing was deleted.*

## Command line

```powershell
.\cli\Invoke-PrtgManager.ps1 -Action Test -Source 10.0.0.10 -Credential (Get-Credential)
.\cli\Invoke-PrtgManager.ps1 -Action Backup -Source PRTG-OLD -KeepLast 7
.\cli\Invoke-PrtgManager.ps1 -Action Backup -Source PRTG-OLD -Scope Graphs -HistoryDays 30
.\cli\Invoke-PrtgManager.ps1 -Action BackupPart -Part Devices -Source PRTG-OLD
.\cli\Invoke-PrtgManager.ps1 -Action BackupPart -Part License -Source PRTG-OLD -BackupPassword (Read-Host -AsSecureString)
.\cli\Invoke-PrtgManager.ps1 -Action Migrate -Source PRTG-OLD -Target PRTG-NEW1,PRTG-NEW2 -Streams 6
.\cli\Invoke-PrtgManager.ps1 -Action Restore -BackupName PRTG-FULL_OLDSRV_20260928-221500.zip -Target PRTG-NEW1
.\cli\Invoke-PrtgManager.ps1 -Action FixBinding -Target PRTG-NEW1
.\cli\Invoke-PrtgManager.ps1 -Action RemoveLicense -Target PRTG-NEW1
```

Exit codes: `0` success, `1` failure, `2` finished with errors on a target.

## Backup package format (version 2)

`backups\PRTG-<TYPE>_<SOURCE>_<yyyyMMdd-HHmmss>.zip` — or `.pmenc` when encrypted with a backup password — plus `<package>.meta.json` next to it (SHA-256 of the file, the manifest, the last validation).

`manifest.json`:

| Field | Meaning |
|---|---|
| `tool`, `format`, `formatVersion` | `prtg-manager`, `prtg-manager-backup`, `2` (packages of PRTG Mover: `prtg-mover`, `1` — still restorable) |
| `type` | `full`, `graphs`, `devices`, `notifications`, `triggers`, `license` |
| `appVersion`, `createdUtc`, `jobId` | which PRTG Manager made it, when |
| `source` | computer, OS, server name in the inventory |
| `components` | PRTG version, manager version, PowerShell version |
| `sections`, `counts` | what is inside (for example `device=27, sensor=386`) |
| `files` | path, size and SHA-256 of every file of a part package |
| `prtg` | version, configuration format, configuration SHA-256 and statistics, paths, program folders, services |
| `graphs` | days, first and last day, files, bytes, devices (history packages) |
| `license` | value names, edition, activated (never the key) |
| `encryption` | `package` (whole file) / `secrets` (license key), algorithm, key derivation |

Part packages contain `devices.xml`, `notifications.xml`, `triggers.xml` (a `<prtgmanagersection>` with the configuration format and PRTG version) or `license.enc`. Full and history packages contain `prtg\data`, `prtg\graphs`, `prtg\programfull`, `prtg\program`, `prtg\registry`, `prtg\services`, `desktop`, `extra`.

**Validate** checks: the file against its original SHA-256, zip integrity, supported format, every listed file checksum, `PRTG Configuration.dat` against the checksum read on the source, the history file count, and for encrypted packages the password and integrity (HMAC).

## Security

- Server passwords are stored with Windows DPAPI for the current Windows user only; `config\servers.json` holds no secrets.
- Backup passwords and license keys are only used by the running job: they are never written to job records, logs, the audit trail or URLs.
- License backups are encrypted on the PRTG server itself; restore decrypts on the target server. The manager never holds the key in clear.
- The dashboard listens on `localhost` without access protection (no token). Every program on the manager can use it; with `-ListenAll` everyone who reaches the port can. Run it only while you need it.
- Full backups contain the PRTG configuration with PRTG's encrypted device credentials, the license and the SSL private key: use a backup password or store them like a password vault export.
- `backups/`, `data/` and `config/servers.json` are in `.gitignore` — never commit them.

## Limitations and after-migration checklist

- **Two cores at once**: with *Don't touch the source* the old PRTG keeps running until you stop it.
- **License activation** is per system: on a new server PRTG reports *No License (System Changed)* until Paessler activates it there. The source license is never changed.
- **ID conflicts**: restoring devices into a PRTG that was set up independently can collide on object ids; use *New ids for conflicts* (history then does not follow those objects).
- **History restore** only shows up for devices with the same ids as on the source (the source itself or a server restored from a full backup of it).
- **Devices that only allow the old IP**, **remote probes** (core address), **service account** (clones run as LocalSystem), **target version** (equal or newer) — as before.
- **Manager clock**: a WinRM HTTPS certificate looks invalid while the manager's clock is behind; the tool waits until it is valid.

## Coming from PRTG Mover

- The installer and `Setup-All.cmd` update an installation in `C:\PrtgMover` in place; servers, credentials and backups stay. Shortcuts and the start-with-Windows task are renamed to **PRTG Manager**; `Start-PrtgMover.ps1`, `Start-PrtgMover.cmd`, `Open-PrtgMover.ps1`, `tools\Enable-PrtgMoverRemoting.ps1` and `cli\Invoke-PrtgMover.ps1` remain as small forwarders so older shortcuts and tasks keep working.
- Packages of PRTG Mover (format 1) are listed as *Full* and restore as before. Their VPN part is ignored here — import the package in **VPN Manager**. VPN-only packages (`VPN_*.zip`) are not listed in PRTG Manager any more.
- Kept as technical identifiers: the work folder on the servers `C:\PrtgMover` (rollback copies live there), the VSS link prefix `PrtgMoverVss_`, environment variables `PRTGMOVER_*`, the GitHub repository name `prtg-mover`.

## Project layout

```
install.ps1 / .cmd                  installs, updates or removes PRTG Manager
Start-PrtgManager.ps1 / .cmd        dashboard (HttpListener) + REST API
Open-PrtgManager.ps1                opens the running dashboard (or starts it)
cli\Invoke-PrtgManager.ps1          command-line front end
src\PrtgManager.psm1                manager engine: inventory, sessions, transfers, packages, jobs
src\Remote\PrtgManager.Remote.ps1   code executed on the servers (backup, restore, parts, license, encryption)
agent\PrtgManager-Agent.ps1         agent for the RDP connection method
web\                                dashboard UI (vanilla HTML/CSS/JS)
tools\Enable-PrtgManagerRemoting.ps1  WinRM method: run once on every server
tools\Build-SetupAll.ps1            builds Setup-All.cmd (PRTG Manager + VPN Manager in one file)
tests\                              Pester tests
```

## Development

```powershell
Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser -SkipPublisherCheck
Install-Module PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester -Path .\tests -Output Detailed
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

The suite runs the backup, transfer and restore path without any server (connection method *Local* and a local RDP agent), the configuration-part planner and merger on a sample PRTG configuration, encryption, package validation, license handling against a temporary registry key, and the dashboard API. CI (GitHub Actions, `windows-latest`, Windows PowerShell 5.1) parses every script, runs PSScriptAnalyzer and the Pester suite.

## License

[MIT](LICENSE)
