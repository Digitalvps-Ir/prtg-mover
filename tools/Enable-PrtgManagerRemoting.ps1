<#
.SYNOPSIS
    Prepares a SOURCE or TARGET server for the WinRM connection method of PRTG Manager.
    Run once on every server, in an elevated PowerShell (for example over RDP).
    Not needed for the RDP connection method.

.DESCRIPTION
    - Enables PowerShell remoting (WinRM)
    - Creates an HTTPS listener (port 5986) with a self-signed certificate (-Https)
    - Opens the firewall for WinRM, only for the manager's address
    - Allows remote administration with *local* administrator accounts
    - Raises the WinRM limits that large transfers need
    - Checks the result and prints what to enter in the dashboard

    The script can be run again at any time. It replaces its own firewall rule and its
    own HTTPS listener.

.PARAMETER ManagerAddress
    IP address of the manager. The firewall rule only accepts this address.
    When it is left out, the address is taken from the Remote Desktop session you are
    working in.

.PARAMETER AllowAnyAddress
    Accept WinRM connections from every address. Only use this on a network you trust.

.PARAMETER Https
    Create the HTTPS listener (recommended). In the dashboard tick "HTTPS" and
    "Skip certificate checks" for the server. Plain WinRM (port 5985) is closed in the
    firewall, because Enable-PSRemoting opens it.

.PARAMETER KeepPlainWinRM
    With -Https: leave the firewall rules of Windows for plain WinRM (port 5985) as they are.

.EXAMPLE
    .\Enable-PrtgManagerRemoting.ps1 -Https

.EXAMPLE
    .\Enable-PrtgManagerRemoting.ps1 -ManagerAddress 10.0.0.5 -Https
#>
[CmdletBinding()]
param(
    [string]$ManagerAddress,
    [switch]$AllowAnyAddress,
    [switch]$Https,
    [switch]$KeepPlainWinRM
)
$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw 'Run this script in an elevated (Administrator) PowerShell.' }

Write-Host '[1/6] Who may connect...' -ForegroundColor Cyan
$allowed = @()
if ($AllowAnyAddress) {
    Write-Host '      every address (-AllowAnyAddress)' -ForegroundColor Yellow
} elseif ($ManagerAddress) {
    $allowed = @($ManagerAddress -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    Write-Host "      $($allowed -join ', ')"
} else {
    # The manager is the computer this Remote Desktop session comes from.
    $rdpPort = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).PortNumber
    if (-not $rdpPort) { $rdpPort = 3389 }
    $allowed = @(Get-NetTCPConnection -LocalPort $rdpPort -State Established -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty RemoteAddress -Unique | Where-Object { $_ -notmatch '^(127\.|::1$|0\.0\.0\.0$)' })
    if ($allowed.Count) { Write-Host "      $($allowed -join ', ') (taken from the Remote Desktop session)" }
    else { throw 'The address of the manager could not be found. Pass it with -ManagerAddress <ip>, or use -AllowAnyAddress on a network you trust.' }
}

Write-Host '[2/6] Enabling PowerShell remoting...' -ForegroundColor Cyan
Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
Set-Service WinRM -StartupType Automatic

Write-Host '[3/6] Allowing remote administration with local accounts...' -ForegroundColor Cyan
New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null

Write-Host '[4/6] Raising WinRM limits...' -ForegroundColor Cyan
Set-Item WSMan:\localhost\MaxEnvelopeSizekb 8192
Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 4096
Set-Item WSMan:\localhost\Plugin\Microsoft.PowerShell\Quotas\MaxMemoryPerShellMB 4096 -ErrorAction SilentlyContinue

if ($Https) {
    Write-Host '[5/6] Creating the HTTPS listener (self-signed certificate)...' -ForegroundColor Cyan
    $names = @($env:COMPUTERNAME)
    try { $names += [Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName } catch { }
    $names = @($names | Select-Object -Unique)
    $friendly = 'PRTG Manager WinRM'
    $cert = Get-ChildItem Cert:\LocalMachine\My | Where-Object { $_.FriendlyName -eq $friendly -and $_.NotAfter -gt (Get-Date).AddDays(30) -and $_.NotBefore -lt (Get-Date).AddDays(-1) } | Select-Object -First 1
    if (-not $cert) {
        try {
            # Valid from two days ago: a manager whose clock is behind must not see a certificate "from the future".
            $cert = New-SelfSignedCertificate -DnsName $names -CertStoreLocation Cert:\LocalMachine\My -NotBefore (Get-Date).AddDays(-2) -NotAfter (Get-Date).AddYears(5) -FriendlyName $friendly
        } catch {
            # Windows Server 2012 R2: the cmdlet knows neither -NotBefore nor -NotAfter.
            $cert = New-SelfSignedCertificate -DnsName $names -CertStoreLocation Cert:\LocalMachine\My
            Write-Host '      This Windows version cannot set the validity: the certificate is valid from now on. If the manager reports "certificate expired", its clock is behind - wait a few minutes or correct the clock.' -ForegroundColor Yellow
        }
    }
    Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' } | Remove-Item -Recurse -Force
    New-Item -Path WSMan:\localhost\Listener -Transport HTTPS -Address * -CertificateThumbPrint $cert.Thumbprint -Force | Out-Null
    Write-Host "      HTTPS listener on 5986, certificate $($cert.Thumbprint), valid from $($cert.NotBefore.ToString('yyyy-MM-dd')) to $($cert.NotAfter.ToString('yyyy-MM-dd'))"
} else { Write-Host '[5/6] HTTPS listener skipped (use -Https to create one; recommended).' -ForegroundColor DarkGray }

Write-Host '[6/6] Firewall...' -ForegroundColor Cyan
$ports = @(5985); if ($Https) { $ports = @(5986) }
$ruleName = 'PRTG Manager - WinRM'
Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue | Remove-NetFirewallRule
$fw = @{ DisplayName = $ruleName; Direction = 'Inbound'; Protocol = 'TCP'; LocalPort = $ports; Action = 'Allow'; Profile = 'Any' }
if ($allowed.Count) { $fw.RemoteAddress = $allowed }
New-NetFirewallRule @fw | Out-Null
Write-Host ("      Inbound TCP {0} allowed from {1}" -f ($ports -join ','), $(if ($allowed.Count) { $allowed -join ', ' } else { 'any address' }))
# Enable-PSRemoting opens plain WinRM (5985) for the whole subnet with its own rules. With HTTPS that is not wanted.
if ($Https -and -not $KeepPlainWinRM) {
    Get-NetFirewallRule -Name 'WINRM-HTTP-In-TCP*' -ErrorAction SilentlyContinue | Where-Object { $_.Enabled -eq 'True' } | Disable-NetFirewallRule
    Write-Host '      Plain WinRM (5985) rules of Windows disabled; only HTTPS is reachable.'
}

Restart-Service WinRM

# ---- check the result
$problems = @()
if ((Get-Service WinRM).Status -ne 'Running') { $problems += 'the WinRM service is not running' }
foreach ($p in $ports) {
    # the listener needs a moment after the service restart
    $listening = $false
    for ($i = 0; $i -lt 20 -and -not $listening; $i++) {
        $listening = [bool](Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue)
        if (-not $listening) { Start-Sleep -Milliseconds 500 }
    }
    if (-not $listening) { $problems += "nothing listens on port $p" }
}
if ($Https -and -not (Get-ChildItem WSMan:\localhost\Listener | Where-Object { $_.Keys -contains 'Transport=HTTPS' })) { $problems += 'the HTTPS listener is missing' }

Write-Host ''
if ($problems.Count) {
    Write-Host "NOT ready: $($problems -join '; ')." -ForegroundColor Red
    exit 1
}
Write-Host "Done. $env:COMPUTERNAME is ready for PRTG Manager." -ForegroundColor Green
Write-Host 'Enter this for the server in the dashboard (Servers > Add server):'
Write-Host '   Connection method : WinRM'
if ($Https) { Write-Host '   Transport         : HTTPS (5986) and "Skip certificate checks"' } else { Write-Host '   Transport         : plain (5985); on the manager run tools\Setup-Manager.ps1 -TrustedHosts <this server>' }
Write-Host "   User              : $env:COMPUTERNAME\<administrator>"
Write-Host 'Addresses of this server:'
Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } | ForEach-Object { Write-Host "   $($_.IPAddress)  ($($_.InterfaceAlias))" }
