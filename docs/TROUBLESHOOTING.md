# Troubleshooting

## Where to look first

| What | Where |
|---|---|
| Everything at once | **Logs & Audit → Download diagnostics**: a zip with all logs, job records, agent logs, test results and an environment report. It contains no passwords. |
| One job, live | **Jobs** → select the job → tick **Show debug** to see the exact error line, stack, agent requests and timings |
| Job log file | `data\jobs\<job-id>.log` and `.json` (the record, including resume checkpoints) |
| Manager / API errors | `data\logs\manager-yyyyMMdd.log` |
| Who did what | `data\logs\audit.log` |
| File copy problems | `data\logs\robocopy\robocopy-<job>-<server>.log` |
| Agent (RDP method) | `data\agent\<server-id>\agent.log`, `heartbeat.json`, `requests\*.abandoned` / `*.orphaned` |

## Resume

If a job fails, is cancelled or is interrupted by a dashboard restart, open the job and press **Resume**:

- A package or a complete copy from the earlier run is reused, so the source is **not** contacted again.
- A partial copy is continued: only files that are missing or changed are transferred.
- Targets that already finished are skipped.
- Server addresses are read from the inventory again, so a changed IP only needs to be updated under *Servers*.

RDP method: if the Remote Desktop session drops while a job runs, the agent keeps running on the server and the job waits up to 30 minutes. Reconnect with the **RDP** button. If the agent window was closed, run the agent command again. The step is repeated automatically.

## Connection problems

| Symptom | Cause / fix |
|---|---|
| `\\tsclient\…` does not exist on the server | The Remote Desktop session was not opened with the dashboard's **RDP** button, or drive access was not allowed in the connection dialog. Close the session and open it with the **RDP** button. |
| `Waiting for the agent…` although the agent runs | The Remote Desktop window was closed. The agent can only reach the manager while the session is connected. Minimizing the window is fine. |
| `Agent … is not elevated` | Start PowerShell on the server with *Run as administrator* before pasting the agent command. |
| `The client cannot connect to the destination…` | WinRM isn't enabled on the server, or a firewall blocks it. Run `tools\Enable-PrtgMoverRemoting.ps1` on the server and check TCP 5985/5986 from the manager with `Test-NetConnection <ip> -Port 5986`. |
| `The SSL certificate is expired` right after enabling WinRM | The manager's clock is behind the server's clock, so the new certificate is not valid yet. The tool waits until it is valid (up to 40 minutes). Sync the Windows clock of the manager to end the wait. |
| `The WinRM client cannot process the request… TrustedHosts` | Plain WinRM (HTTP) to an IP address or to a server outside the domain. Use HTTPS (`-Https`), or on the manager (elevated) run `tools\Setup-Manager.ps1 -TrustedHosts <ip>`. |
| `Access is denied` | Wrong credential, or a local administrator without `LocalAccountTokenFilterPolicy=1` (the enable script sets it). Use the `HOST\user` format. |
| Test shows `admin=False` | The session isn't elevated. Use an administrator account. |
| WinRM port entered as 3389 | 3389 is the RDP port. Put it into *RDP port* and leave the WinRM port at 0. |

## Transfer problems

| Symptom | Cause / fix |
|---|---|
| Slow transfer over WinRM | One WinRM stream is slow by design. Raise *Parallel transfer streams* (up to 8). Turning off *Historic monitoring data* makes the package much smaller. |
| `Chunk failed … retry` in the log | A stream lost its connection. It reconnects and repeats the chunk, up to 4 times. If the job still fails, press **Resume**. |
| `Not enough free space` | The manager needs about 2.2 × the PRTG data, a target about 1.2 ×. The source needs none. |
| `PRTG Configuration.dat … does not match the source` | The file changed or the transfer was incomplete. Press **Resume**: the file is transferred again. |

## After the restore

| Symptom | Cause / fix |
|---|---|
| PRTG shows *No License (System Changed)*, sensors are paused | Expected after a move to new hardware: PRTG binds a license to the system it was activated on. Activate the license on the new server in PRTG (*Setup → License Information*). If the activation fails (for example `HTTP 403`), the server can't use Paessler's activation service: contact Paessler or your reseller for an activation. The license on the old server is not changed by a migration. |
| PRTG answers on the server itself but not from the network | The web server is bound to the old server's address. Run **Test WinRM** and press **Make PRTG reachable** on the Servers page (or `-Action FixBinding` on the command line). New migrations adjust the binding automatically. Also check firewalls in front of the server. |
| `Target PRTG x is OLDER than source y` | Install the source's version (or newer) on the target first, or remove PRTG from the target so that the clone is used. |
| PRTG started but `web interface did not answer` | Check `<datapath>\Logs\core\Core.log` on the target. The first start with a large data folder takes time: raise *Health-check timeout*. Also check that the web server port isn't used by IIS or another service. |
| PRTG does not start after a clone | The target may lack the .NET Framework version of the source (the log shows a warning). Install it and press **Resume**. |
| Sensors are down on the new server only | Monitored devices may only allow the old server's IP (SNMP, WMI, API). Allow the new address there. |
| Notifications arrive twice | Both cores are running. Stop the old one when the new one is verified. |
| VPN appears but won't connect | Saved VPN credentials and certificates can't be migrated (DPAPI). Enter the credentials once on the target; import certificates for IKEv2/SSTP. |

## Dashboard

| Symptom | Cause / fix |
|---|---|
| `Could not listen on http://+:8765/` | `-ListenAll` needs a URL ACL. Run `tools\Setup-Manager.ps1 -DashboardPort 8765` (elevated). |
| `Request from another web site refused` | The request did not come from the dashboard page. Nothing to fix: this protects the manager from pages open in the browser. |
| Scripts are blocked | Run `Get-ChildItem -Recurse *.ps1,*.psm1 \| Unblock-File`, or start with `powershell -ExecutionPolicy Bypass -File …`. |

## Rolling back a target

Only possible when the target had PRTG data before the restore.

```powershell
Stop-Service PRTGProbeService, PRTGCoreService
Rename-Item 'C:\ProgramData\Paessler\PRTG Network Monitor' 'PRTG Network Monitor.failed'
Rename-Item 'C:\ProgramData\Paessler\PRTG Network Monitor.pre-restore-<timestamp>' 'PRTG Network Monitor'
reg import C:\PrtgMover\rollback\<timestamp>\HKLM_SOFTWARE_WOW6432Node_Paessler.reg
Start-Service PRTGCoreService, PRTGProbeService
```

## Stopping the old server after a migration

```powershell
Stop-Service PRTGProbeService, PRTGCoreService
Set-Service PRTGCoreService -StartupType Disabled
Set-Service PRTGProbeService -StartupType Disabled
```

To start it again later:

```powershell
Set-Service PRTGCoreService -StartupType Automatic
Set-Service PRTGProbeService -StartupType Automatic
Start-Service PRTGCoreService, PRTGProbeService
```
