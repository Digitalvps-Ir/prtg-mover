<#
.SYNOPSIS
    Prepares a SOURCE or TARGET server so the PRTG Mover manager can reach it.
    Run once on every server, in an elevated PowerShell (e.g. over RDP).

.DESCRIPTION
    - Enables PowerShell remoting (WinRM, HTTP 5985)
    - Opens the firewall for WinRM (optionally only for the manager's IP)
    - Allows remote admin with *local* administrator accounts (LocalAccountTokenFilterPolicy)
    - Raises WinRM limits used for large file transfers
    - Optional: HTTPS listener (5986) with a self-signed certificate

.PARAMETER ManagerAddress
    IP address of the manager. When set, the WinRM firewall rules only accept this address.

.PARAMETER Https
    Also create an HTTPS listener on 5986 with a self-signed certificate
    (use "HTTPS" + "Skip certificate checks" for the server in the dashboard).

.EXAMPLE
    .\Enable-PrtgMoverRemoting.ps1 -ManagerAddress 10.0.0.5

.EXAMPLE
    # One-liner, paste into an elevated PowerShell on the server:
    Enable-PSRemoting -Force -SkipNetworkProfileCheck; Set-ItemProperty HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System LocalAccountTokenFilterPolicy 1 -Type DWord
#>
[CmdletBinding()]
param(
    [string]$ManagerAddress,
    [switch]$Https
)
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script in an elevated (Administrator) PowerShell.' }

Write-Host '[1/5] Enabling PowerShell remoting...' -ForegroundColor Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Service WinRM -StartupType Automatic

Write-Host '[2/5] Allowing remote administration with local accounts...' -ForegroundColor Cyan
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host '[3/5] Raising WinRM limits...' -ForegroundColor Cyan
Set-Item WSMan:\localhost\MaxEnvelopeSizekb 8192
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 4096
Set-Item WSMan:\localhost\Plugin\Microsoft.PowerShell\Quotas\MaxMemoryPerShellMB 4096 -ErrorAction SilentlyContinue

Write-Host '[4/5] Firewall...' -ForegroundColor Cyan
$ports = @(5985); if ($Https) { $ports += 5986 }
$ruleName = 'PRTG Mover - WinRM'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$fw = @{ DisplayName = $ruleName; Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $ports; Action = 'Allow'; Profile = 'Any' }
if ($ManagerAddress) { $fw.RemoteAddress = $ManagerAddress }
New-NetFirewallRule @fw | Out-Null
Write-Host ("      Inbound TCP {0} allowed from {1}" -f ($ports -join ','), $(if ($ManagerAddress) { $ManagerAddress } else { 'any address' }))

if ($Https) {
    Write-Host '[5/5] Creating HTTPS listener (self-signed)...' -ForegroundColor Cyan
    $fqdn = [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
    $cert = New-SelfSignedCertificate -DnsName $fqdn, $env:COMPUTERNAME -CertStoreLocation Cert:\LocalMachine\My -NotAfter (Get-Date).AddYears(5)
    Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
    Write-Host "      HTTPS listener on 5986, certificate $($cert.Thumbprint)"
} else { Write-Host '[5/5] HTTPS listener skipped (use -Https to create one).' -ForegroundColor DarkGray }

Restart-Service WinRM
Write-Host ''
Write-Host "Done. $env:COMPUTERNAME is ready for PRTG Mover." -ForegroundColor Green
Write-Host 'IP addresses of this server:'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { Write-Host "   $($_.IPAddress)  ($($_.InterfaceAlias))" }
