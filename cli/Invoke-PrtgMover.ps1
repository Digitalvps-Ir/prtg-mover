<#
.SYNOPSIS
    Command-line front end of PRTG Mover (same engine as the dashboard).

.DESCRIPTION
    Runs a test, backup, restore or full migration directly in the console - useful
    for scheduled backups (Task Scheduler) or when no browser is available.
    Servers are addressed either by inventory name/id (config\servers.json, managed in
    the dashboard) or ad hoc by host name.

.EXAMPLE
    # Connectivity test with an interactive credential prompt
    .\cli\Invoke-PrtgMover.ps1 -Action Test -Source 10.0.0.10 -Credential (Get-Credential)

.EXAMPLE
    # Nightly backup of an inventory server (saved credential), source keeps running
    .\cli\Invoke-PrtgMover.ps1 -Action Backup -Source PRTG-OLD

.EXAMPLE
    # Full migration to two new servers, old server stopped and disabled
    .\cli\Invoke-PrtgMover.ps1 -Action Migrate -Source PRTG-OLD -Target PRTG-NEW1,PRTG-NEW2 -SourceAfter Disable

.EXAMPLE
    # Restore an existing package
    .\cli\Invoke-PrtgMover.ps1 -Action Restore -BackupName PRTG_OLDSRV_20260928-221500.zip -Target PRTG-NEW1

.EXAMPLE
    # A migrated PRTG only answers on 127.0.0.1: bind its web server to the server's own address
    .\cli\Invoke-PrtgMover.ps1 -Action FixBinding -Target PRTG-NEW1
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('Test', 'Backup', 'Restore', 'Migrate', 'FixBinding')][string]$Action,
    [string]$Source,
    [string[]]$Target = @(),
    [string]$BackupName,
    [pscredential]$Credential,
    [switch]$NoPrtg,
    [switch]$NoHistory,
    [switch]$NoVpn,
    [switch]$NoDesktop,
    [string[]]$ExtraPaths = @(),
    [ValidateSet('Restart', 'KeepStopped', 'Disable')][string]$SourceAfter,
    [string]$InstallerFile,
    [switch]$NoStart,
    [int]$HealthTimeoutMinutes = 15,
    [ValidateRange(1, 8)][int]$Streams = 4,
    [switch]$ConnectVpn,
    [switch]$AllowDowngrade,
    [switch]$AllowSourceStop,
    [switch]$NoProgramClone,
    [switch]$NoLicense,
    [switch]$NoFirewall,
    [switch]$SkipPreflight,
    [int]$KeepLast = 0
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src\PrtgMover.psm1') -Force -DisableNameChecking
Set-PmRoot -Path $root

function Resolve-CliServer {
    param([string]$Ref)
    $s = Get-PmServers | Where-Object { $_.id -eq $Ref -or $_.name -eq $Ref -or $_.host -eq $Ref } | Select-Object -First 1
    if ($s) { return $s }
    # ad-hoc server (not in inventory) - default WinRM settings
    return [pscustomobject]@{ id = "adhoc-$Ref"; name = $Ref; host = $Ref; transport = 'winrm'; port = 0; useSsl = $false; skipCaCheck = $false; authentication = 'Default' }
}

function Get-CliCredential { param($Server) if ($Credential) { return $Credential } return Get-PmCredential -ServerId $Server.id }

$options = @{
    IncludePrtg = -not $NoPrtg; IncludeHistory = -not $NoHistory; IncludeVpn = -not $NoVpn; IncludeDesktop = -not $NoDesktop
    ExtraPaths = $ExtraPaths; StartServices = -not $NoStart; HealthTimeoutMinutes = $HealthTimeoutMinutes; TransferStreams = $Streams
    ConnectVpn = [bool]$ConnectVpn; AllowDowngrade = [bool]$AllowDowngrade
    RestorePrtg = -not $NoPrtg; RestoreVpn = -not $NoVpn; RestoreDesktop = -not $NoDesktop; RestoreExtra = $true
    NoTouch = -not $AllowSourceStop; IncludeProgram = -not $NoProgramClone; CopyLicense = -not $NoLicense; OpenFirewall = -not $NoFirewall
}
if ($InstallerFile) { $options.InstallerFile = $InstallerFile }

$job = New-PmJobObject -Type $Action.ToLower() -Summary "CLI $Action" -Console
$job.status = 'running'; $job.started = (Get-Date).ToString('o')
$exit = 0
try {
    switch ($Action) {
        'Test' {
            foreach ($ref in @($Source) + $Target | Where-Object { $_ }) {
                $srv = Resolve-CliServer $ref
                [void](Invoke-PmTestFlow -Server $srv -Credential (Get-CliCredential $srv) -Job $job)
            }
        }
        'Backup' {
            if (-not $Source) { throw '-Source is required.' }
            $srv = Resolve-CliServer $Source
            $options.SourceAfter = if ($SourceAfter) { $SourceAfter } else { 'Restart' }
            $creds = @{}; if ($Credential) { $creds[$srv.id] = $Credential }
            if (-not $SkipPreflight) { [void](Invoke-PmPreflight -Source $srv -Credentials $creds -Options $options -Job $job) }
            $bk = Invoke-PmBackupFlow -Server $srv -Credential (Get-CliCredential $srv) -Options $options -Job $job
            $file = $bk.Zip
            if ($bk.StageDir) { Remove-Item -LiteralPath $bk.StageDir -Recurse -Force -ErrorAction SilentlyContinue }
            $job.result = [pscustomobject]@{ backup = (Split-Path $file -Leaf) }
            if ($KeepLast -gt 0) {
                # Retention only touches packages of the same source computer (PRTG_<COMPUTER>_<timestamp>.zip).
                $prefix = (Split-Path $file -Leaf) -replace '_\d{8}-\d{6}\.zip$', '_'
                Get-ChildItem (Get-PmPath Backups) -Filter '*.zip' | Where-Object { $_.Name.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) } |
                    Sort-Object LastWriteTime -Descending | Select-Object -Skip $KeepLast | ForEach-Object {
                        Remove-PmBackup -Name $_.Name; Add-PmJobLog -Job $job -Level INFO -Message "Retention: removed $($_.Name)"
                    }
            }
        }
        'Restore' {
            if (-not $BackupName -or -not $Target) { throw '-BackupName and -Target are required.' }
            $file = Get-PmBackupFile -Name $BackupName
            foreach ($ref in $Target) {
                $srv = Resolve-CliServer $ref
                $rep = Invoke-PmRestoreFlow -Server $srv -Credential (Get-CliCredential $srv) -BackupPath $file -Options $options -Job $job
                if (@($rep.Errors).Count) { $exit = 2 }
            }
        }
        'FixBinding' {
            if (-not $Target) { throw '-Target is required.' }
            $job.result = @(foreach ($ref in $Target) { $srv = Resolve-CliServer $ref; Invoke-PmRebindFlow -Server $srv -Credential (Get-CliCredential $srv) -Job $job })
        }
        'Migrate' {
            if (-not $Source -or -not $Target) { throw '-Source and -Target are required.' }
            $srv = Resolve-CliServer $Source
            $options.SourceAfter = if ($SourceAfter) { $SourceAfter } else { 'KeepStopped' }
            $targets = @($Target | ForEach-Object { Resolve-CliServer $_ })
            $creds = @{}; if ($Credential) { foreach ($x in @($srv) + $targets) { $creds[$x.id] = $Credential } }
            if (-not $SkipPreflight) { [void](Invoke-PmPreflight -Source $srv -Targets $targets -Credentials $creds -Options $options -Job $job) }
            $bk = Invoke-PmBackupFlow -Server $srv -Credential (Get-CliCredential $srv) -Options $options -Job $job
            $file = $bk.Zip
            foreach ($ref in $Target) {
                $t = Resolve-CliServer $ref
                $rep = Invoke-PmRestoreFlow -Server $t -Credential (Get-CliCredential $t) -BackupPath $file -StageDir $bk.StageDir -Options $options -Job $job
                if (@($rep.Errors).Count) { $exit = 2 }
            }
            if ($bk.StageDir) { Remove-Item -LiteralPath $bk.StageDir -Recurse -Force -ErrorAction SilentlyContinue }
        }
    }
    $job.status = if ($exit) { 'failed' } else { 'succeeded' }
} catch {
    $job.status = 'failed'; $job.error = "$_"
    Add-PmJobLog -Job $job -Level ERROR -Message "$_"
    $exit = 1
} finally {
    $job.finished = (Get-Date).ToString('o')
    Save-PmJobRecord -Job $job
}
exit $exit
