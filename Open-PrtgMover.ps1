<#
.SYNOPSIS
    Opens the PRTG Mover dashboard in the browser and starts it first when it is not running.

.DESCRIPTION
    Used by the shortcut of an installation in local mode (PRTG Mover on the PRTG server
    itself). There the dashboard is started by the scheduled task "PRTG Mover Dashboard" when
    the computer starts, so it is up after a restart without anybody logging on. This script
    starts that task when the dashboard does not answer. Without the task it starts the
    dashboard in a window of its own.

.PARAMETER Port
    Port of the dashboard. Default 8765.
#>
[CmdletBinding()]
param([int]$Port = 8765)
$ErrorActionPreference = 'Stop'
$url = "http://localhost:$Port/"
$task = 'PRTG Mover Dashboard'

function Test-Dashboard {
    try { $i = Invoke-RestMethod -Uri "http://localhost:$Port/api/info" -TimeoutSec 3; return ($i.product -eq 'PRTG Mover' -or [bool]$i.PSObject.Properties['backupsPath']) } catch { return $false }
}

if (-not (Test-Dashboard)) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        try { Start-ScheduledTask -TaskName $task }
        catch {
            Write-Host "The task '$task' could not be started: $($_.Exception.Message)" -ForegroundColor Red
            Write-Host 'Open this shortcut with "Run as administrator".'
            Start-Sleep -Seconds 8
            exit 1
        }
    } else {
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $ps -WorkingDirectory $PSScriptRoot -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$(Join-Path $PSScriptRoot 'Start-PrtgMover.ps1')`"", '-Port', $Port, '-NoBrowser')
    }
    $until = (Get-Date).AddSeconds(60)
    while (-not (Test-Dashboard) -and (Get-Date) -lt $until) { Start-Sleep -Milliseconds 700 }
    if (-not (Test-Dashboard)) {
        Write-Host "PRTG Mover did not answer on $url within 60 seconds." -ForegroundColor Red
        Start-Sleep -Seconds 8
        exit 2
    }
}
Start-Process $url
exit 0
