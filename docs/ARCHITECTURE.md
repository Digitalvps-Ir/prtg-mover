# Architecture

## Components

| Component | File | Runs on | Responsibility |
|---|---|---|---|
| Dashboard / API | `Start-PrtgMover.ps1` | manager | `System.Net.HttpListener` on `localhost:8765`, token auth, static UI, REST API, streaming uploads and downloads on a separate runspace pool |
| Engine | `src/PrtgMover.psm1` | manager | server inventory, DPAPI credentials, sessions for every connection method, file transfers, backup / restore / migrate flows, job runner (runspace pool), logs and audit trail |
| Payload | `src/Remote/PrtgMover.Remote.ps1` | source / target | PRTG discovery, VSS snapshots, registry export and import, program clone, web server binding, VPN phonebook merge, health check |
| RDP agent | `agent/PrtgMover-Agent.ps1` | source / target | runs the payload inside a Remote Desktop session and talks to the manager through the redirected drive |
| UI | `web/` | browser | vanilla HTML/CSS/JS, polls the API |
| CLI | `cli/Invoke-PrtgMover.ps1` | manager | same flows, console output, exit codes |

## Connection methods

A *session* hides how the manager reaches a server. Every flow works with every method.

| Method | Session | Remote call | File copy |
|---|---|---|---|
| `winrm` | `PSSession` (HTTP 5985 or HTTPS 5986) | `Invoke-Command` with the payload and the function name | compressed chunks over `Copy-Item -FromSession / -ToSession` |
| `rdp` | agent heartbeat in `data\agent\<id>` | request file in `requests\`, streamed JSON lines in `responses\` | the server reads and writes the manager's disk through `\\tsclient` |
| `local` | none | the payload runs in the manager's own process | plain file copy |

`local` is used by the test suite and for a PRTG that runs on the manager itself.

### Payload calls

For every call the manager builds one script:

```
param($PmFn, $PmParams)
<contents of PrtgMover.Remote.ps1>
& $PmFn @PmParams
```

The payload functions **stream** objects back:

- `PmType='log'`: appended to the job log as it arrives (live in the dashboard)
- `PmType='progress'`: mapped into the job's overall percentage
- `PmType='result'`: the return value

Because the payload travels with every call, the servers never need a module install, and the manager and the server code can't get out of sync. The agent reloads the payload when the file on the manager changes.

## Data flow of a migration

All data goes through the manager. The servers never connect to each other.

```
manager                          source                            target
  │ pre-flight: connect, admin rights, versions, disk space (all servers)
  │ Invoke-PmRemoteBackup ───────►│ remove stale snapshots of earlier runs
  │                               │ VSS snapshot (PRTG keeps running)
  │                               │ stage small items: registry, services,
  │                               │   VPN phonebooks, desktops, manifest
  │ ◄── file lists ───────────────│
  │ pull data + program folder ◄──│ read from the snapshot
  │ Complete-PmRemotePull ───────►│ snapshot and temp files removed
  │ verify PRTG Configuration.dat (SHA-256), mark staging complete
  │ build backups\PRTG_<HOST>_<ts>.zip
  │ push staged files ─────────────────────────────────────────────►│
  │ Invoke-PmRemoteRestore ────────────────────────────────────────►│ clone PRTG if missing
  │                                                                 │ version check, stop services
  │                                                                 │ rollback copy, move data into place
  │                                                                 │ verify configuration, import registry
  │                                                                 │ adjust data path and web binding
  │                                                                 │ license, customisations, firewall
  │ ◄── log / progress / report ────────────────────────────────────│ start PRTG, health check
  │                                                                 │ VPN merge, desktops, extra paths
```

With the RDP method the pull and push steps are replaced by direct reads and writes on the manager's staging folder through `\\tsclient`.

## File transfer over WinRM

`Invoke-PmTransferFiles` moves a list of files (relative path, size, timestamp) in one direction.

1. **Compare.** Files that already exist on the receiving side with the same size (and timestamp when pulling) are skipped. This is what makes a transfer resumable.
2. **Batch.** The remaining files are grouped into batches of about 256 MB of data or 3000 files.
3. **Transfer.** Each batch is packed into a compressed chunk on the sending side, copied in one piece, checked (size, file count) and unpacked on the receiving side. The chunk is deleted on both sides.
4. **Parallel streams.** With more than one stream, workers in their own runspaces take batches from a shared queue. Every worker has its own connection, reconnects when the session breaks, and retries a batch up to 4 times.
5. **Purge.** When pulling, local files that are not part of the list are removed, so leftovers of earlier runs never end up in a package.

## Resume

Every job record stores its parameters (without one-time credentials) and a checkpoint: the package that was built, the staging folder and the targets that finished.

- A staging folder only counts as complete when the transfer finished (marker file) **and** `PRTG Configuration.dat` matches the checksum from the source.
- **Resume** starts a new job that reuses a complete staging copy or package without contacting the source again, continues a partial copy, and skips finished targets.
- Server addresses are read from the inventory when the job runs, so a changed IP is picked up.
- Jobs that were running when the dashboard stopped are marked *interrupted* and can be resumed.

## Storage on the manager

| Path | Content |
|---|---|
| `config\servers.json` | inventory (no secrets) |
| `data\credentials\<id>.cred.xml` | DPAPI-encrypted `PSCredential` |
| `data\status\<id>.json` | last test result per connection method |
| `data\jobs\` | job records (with checkpoints) and job logs |
| `data\logs\` | manager log per day, audit trail, robocopy logs |
| `data\agent\<id>\` | agent heartbeat, requests, responses, agent log |
| `data\staging\<job>\` | staging copy during a migration (removed afterwards) |
| `data\chunks\` | transfer chunks (temporary) |
| `data\token.txt` | dashboard token |
| `backups\*.zip` + `*.meta.json` | packages and their metadata |
| `installers\` | uploaded PRTG installers |

## Temporary files on the servers

| Path | Content | Removed |
|---|---|---|
| `C:\PrtgMover\staging\<job>` (source, WinRM) | registry export, VPN phonebooks, desktops, manifest | after the pull |
| `C:\PrtgMover\chunks` | transfer chunks | after every chunk |
| `C:\PrtgMoverVss_*` (source) | link to the VSS snapshot | after the pull, or at the start of the next run |
| `C:\PrtgMover\restore\<package>` (target, WinRM) | pushed files | after the restore |
| `C:\PrtgMover\rollback\<timestamp>` (target) | registry before the restore | kept |
