<#
.SYNOPSIS
    Prepares the MANAGER machine (the one that runs the dashboard). Run elevated, once.

.DESCRIPTION
    - Starts the WinRM service (the client side of remoting needs it for configuration)
    - Adds the servers to WinRM TrustedHosts (required for IP addresses / workgroup servers)
    - Optionally creates an URL ACL so the dashboard can listen on all interfaces
    - Unblocks the downloaded script files

.PARAMETER TrustedHosts
    Hosts or IPs of the source/target servers, e.g. 10.0.0.10,10.0.0.20 . Use '*' to trust all (not recommended).

.PARAMETER DashboardPort
    When set, reserves http://+:<port>/ for the current user so Start-PrtgMover.ps1 -ListenAll works without admin rights.

.EXAMPLE
    .\tools\Setup-Manager.ps1 -TrustedHosts 10.0.0.10,10.0.0.20
#>
[CmdletBinding()]
param(
    [string[]]$TrustedHosts = @(),
    [int]$DashboardPort = 0
)
$ErrorActionPreference = 'Stop'
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script in an elevated (Administrator) PowerShell.' }

$root = Split-Path $PSScriptRoot -Parent
Write-Host '[1/4] Unblocking script files...' -ForegroundColor Cyan
Get-ChildItem $root -Recurse -File -Include *.ps1, *.psm1 | Unblock-File

Write-Host '[2/4] Starting WinRM service...' -ForegroundColor Cyan
Set-Service WinRM -StartupType Automatic
Start-Service WinRM

Write-Host '[3/4] TrustedHosts...' -ForegroundColor Cyan
if ($TrustedHosts.Count) {
    $current = (Get-Item WSMan:\localhost\Client\TrustedHosts).Value
    $list = @($current -split ',' | Where-Object { $_ }) + $TrustedHosts | ForEach-Object { $_.Trim() } | Select-Object -Unique
    Set-Item WSMan:\localhost\Client\TrustedHosts -Value ($list -join ',') -Force
    Write-Host "      TrustedHosts = $($list -join ',')"
} else { Write-Host '      skipped (no -TrustedHosts given; not needed for domain members addressed by name)' -ForegroundColor DarkGray }

Write-Host '[4/4] Dashboard URL ACL...' -ForegroundColor Cyan
if ($DashboardPort -gt 0) {
    $user = "$env:USERDOMAIN\$env:USERNAME"
    & netsh http add urlacl url="http://+:$DashboardPort/" user="$user" | Out-Null
    New-NetFirewallRule -DisplayName "PRTG Mover dashboard $DashboardPort" -Direction Inbound -Protocol TCP -LocalPort $DashboardPort -Action Allow -Profile Domain, Private | Out-Null
    Write-Host "      http://+:$DashboardPort/ reserved for $user and firewall opened (Domain/Private)."
} else { Write-Host '      skipped (dashboard listens on localhost only)' -ForegroundColor DarkGray }

$ps = (Get-ExecutionPolicy -Scope CurrentUser)
if ($ps -in 'Restricted', 'AllSigned', 'Undefined' -and (Get-ExecutionPolicy) -in 'Restricted', 'AllSigned') {
    Write-Host "Execution policy is '$((Get-ExecutionPolicy))'. Start the dashboard with:" -ForegroundColor Yellow
    Write-Host '   powershell -ExecutionPolicy Bypass -File .\Start-PrtgMover.ps1' -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Manager ready. Start the dashboard with .\Start-PrtgMover.ps1' -ForegroundColor Green
