# Architecture

## Components

| Component | File | Runs on | Responsibility |
|---|---|---|---|
| Dashboard / API | `Start-PrtgMover.ps1` | manager | `System.Net.HttpListener` on `localhost:8765`, token auth, static UI, REST API, streaming uploads and downloads on a separate runspace pool |
| Engine | `src/PrtgMover.psm1` | manager | server inventory, DPAPI credentials, WinRM sessions, backup/restore/migrate flows, job runner (runspace pool, up to 4 parallel jobs), job logs |
| Remote payload | `src/Remote/PrtgMover.Remote.ps1` | source / target | PRTG discovery, service control, robocopy, registry export/import, RAS phonebook merge, zip packaging, health check |
| UI | `web/` | browser | vanilla HTML/CSS/JS, polls the API |
| CLI | `cli/Invoke-PrtgMover.ps1` | manager | same flows, console output, exit codes |

## Remote execution model

For every remote call the manager builds one script block:

```
param($PmFn, $PmParams)
<contents of PrtgMover.Remote.ps1>
& $PmFn @PmParams
```

It runs this with `Invoke-Command -Session`. The remote functions **stream** objects back through the pipeline:

- `PmType='log'`: appended to the job log as it arrives (live in the dashboard)
- `PmType='progress'`: mapped into the job's overall percentage
- `PmType='result'`: the return value

Because the payload travels with every call, the servers never need an agent or a module install, and the manager and remote code can't get out of sync.

## Data flow of a migration

```
manager                         source                              target
  │  New-PSSession ───────────────►│
  │  Invoke-PmRemoteBackup ───────►│ stop PRTG (wait for process exit)
  │  ◄──── log / progress ─────────│ robocopy data, program folders
  │                                │ reg export Paessler keys
  │                                │ copy *.pbk, desktops, extra paths
  │                                │ manifest.json → ZipFile.CreateFromDirectory
  │  Copy-Item -FromSession ◄──────│ PRTG_<HOST>_<ts>.zip  (SHA-256 verified)
  │  Remove-PmRemoteFile ─────────►│
  │  New-PSSession ─────────────────────────────────────────────────►│
  │  Initialize-PmRemoteWorkRoot ───────────────────────────────────►│ C:\PrtgMover\in
  │  Copy-Item -ToSession (installer if PRTG missing, package) ─────►│
  │  Invoke-PmRemoteRestore ────────────────────────────────────────►│ install PRTG (optional)
  │                                                                  │ version check
  │                                                                  │ stop PRTG, rollback copy
  │                                                                  │ robocopy /MIR data, reg import
  │                                                                  │ restore program folders
  │                                                                  │ merge *.pbk, desktops, extra
  │  ◄──── log / progress / report ──────────────────────────────────│ start PRTG, poll web UI
```

## Job model

A job is a synchronized hashtable (`id, type, status, progress, step, logs, result, error`) that is shared between the HTTP thread and the runspace running the job. When a job finishes it is saved to `data\jobs\<id>.json`, and the plain-text log is appended continuously to `data\jobs\<id>.log`.

## Storage on the manager

| Path | Content |
|---|---|
| `config\servers.json` | inventory (no secrets) |
| `data\credentials\<id>.cred.xml` | DPAPI-encrypted `PSCredential` |
| `data\status\<id>.json` | last connectivity test |
| `data\jobs\` | job records and logs |
| `data\token.txt` | dashboard token |
| `backups\*.zip` + `*.meta.json` | packages and their metadata |
| `installers\` | uploaded PRTG installers |
