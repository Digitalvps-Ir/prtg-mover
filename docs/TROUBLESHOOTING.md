# Troubleshooting

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
