# Troubleshooting

## Where to look first

| What | Where |
|---|---|
| Everything at once | **Jobs → Download diagnostics**: a zip with all logs, job records, agent logs, test results and an environment report. It contains no passwords. |
| One job, live | **Jobs** → select the job → tick **Show debug** to see the exact error line, stack, agent requests and timings |
| Job log file | `data\jobs\<job-id>.log` and `.json` (the record, including resume checkpoints) |
| Manager / API errors | `data\logs\manager-yyyyMMdd.log` |
| Who did what | `data\logs\audit.log` |
| File copy problems | `data\logs\robocopy\robocopy-<job>-<server>.log` |
| Agent (RDP mode) | `data\agent\<server-id>\agent.log`, `heartbeat.json`, `requests\*.abandoned` / `*.orphaned` |

## Resume

If a migration fails or is cancelled, open the job and press **Resume**:
- The package that was already built is reused, so the source is **not** contacted again.
- Targets that already finished are skipped.
- Server addresses are read from the inventory again, so a changed IP only needs to be updated under *Servers*.

If the RDP session drops while a job runs, the job waits up to 30 minutes for the agent to come back. Reconnect with the **RDP** button and run the agent command again, and the step is repeated automatically.

| Symptom | Cause / fix |
|---|---|
| `The client cannot connect to the destination…` | WinRM isn't enabled on the server, or the firewall blocks it. Run `tools\Enable-PrtgMoverRemoting.ps1` on the server and check TCP 5985/5986 from the manager with `Test-NetConnection <ip> -Port 5985`. |
| `The WinRM client cannot process the request… TrustedHosts` | You're addressing the server by IP, or it's outside the domain. On the manager (elevated), run `tools\Setup-Manager.ps1 -TrustedHosts <ip>`. |
| `Access is denied` | Wrong credential, or a non-builtin local admin without `LocalAccountTokenFilterPolicy=1` (the enable script sets it). Use the `HOST\user` format. |
| Test shows `admin=False` | The session isn't elevated. Use an administrator account (see the row above). |
| Very slow transfer | `Copy-Item` over WinRM is limited by latency. Exclude historic data (untick *Historic monitoring data*) for a quicker first migration, or run the manager close to the servers. |
| `Target PRTG x is OLDER than source y` | Install the source's version (or newer) on the target, or upload the correct installer. |
| PRTG started but `web interface did not answer` | Check `<datapath>\Logs\core\Core.log` on the target. The first start after an upgrade can take a long time; raise *Health-check timeout*. Also check that the web server port isn't used by IIS or another service. |
| VPN appears but won't connect | Saved VPN credentials and certificates can't be migrated (DPAPI). Enter the credentials once on the target; import certificates for IKEv2/SSTP. |
| Dashboard: `Could not listen on http://+:8765/` | `-ListenAll` needs a URL ACL. Run `tools\Setup-Manager.ps1 -DashboardPort 8765` (elevated). |
| Scripts are blocked | Run `Get-ChildItem -Recurse *.ps1,*.psm1 \| Unblock-File`, or start with `powershell -ExecutionPolicy Bypass -File …`. |

## Rolling back a target

```powershell
Stop-Service PRTGProbeService, PRTGCoreService
Rename-Item 'C:\ProgramData\Paessler\PRTG Network Monitor' 'PRTG Network Monitor.failed'
Rename-Item 'C:\ProgramData\Paessler\PRTG Network Monitor.pre-restore-<timestamp>' 'PRTG Network Monitor'
reg import C:\PrtgMover\rollback\<timestamp>\HKLM_SOFTWARE_WOW6432Node_Paessler.reg
Start-Service PRTGCoreService, PRTGProbeService
```

## Re-enabling the old source server

```powershell
Set-Service PRTGCoreService, PRTGProbeService -StartupType Automatic
Start-Service PRTGCoreService, PRTGProbeService
```
