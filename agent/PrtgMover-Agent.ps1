<#
.SYNOPSIS
    PRTG Mover agent - the "RDP" connection method (no WinRM needed).

.DESCRIPTION
    Run this INSIDE a Remote Desktop session that was opened from the dashboard (the
    "RDP" button redirects the manager's drive, so this file is reachable as
    \\tsclient\<drive>\...). The agent:
      - talks to the manager only through files in the redirected folder
        (data\agent\<serverId>\requests / responses / heartbeat.json)
      - executes the same payload as WinRM mode (src\Remote\PrtgMover.Remote.ps1)
      - moves backup packages / installers through the redirected drive
    Nothing is installed or configured on the server (no WinRM, no firewall change).
    Close the window (or Ctrl+C) when the job is finished.

.EXAMPLE
    powershell -NoProfile -ExecutionPolicy Bypass -File "\\tsclient\F\PrtgMover\agent\PrtgMover-Agent.ps1" -ServerId 83585c7686
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ServerId,
    [int]$IdleHours = 8,
    # Testing only: allow a non-elevated agent (PRTG operations will fail without admin rights).
    [switch]$AllowNonAdmin
)
$ErrorActionPreference = 'Stop'
$Root = Split-Path $PSScriptRoot -Parent
$Dir = Join-Path $Root "data\agent\$ServerId"
$Req = Join-Path $Dir 'requests'
$Resp = Join-Path $Dir 'responses'
New-Item -ItemType Directory -Force -Path $Req, $Resp | Out-Null

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin -and -not $AllowNonAdmin) {
    Write-Host 'The agent must run in an ELEVATED PowerShell (Run as Administrator).' -ForegroundColor Red
    Read-Host 'Press Enter to close'
    exit 1
}

# Load the payload (same code the WinRM mode ships to the server).
. ([scriptblock]::Create((Get-Content -LiteralPath (Join-Path $Root 'src\Remote\PrtgMover.Remote.ps1') -Raw -Encoding UTF8)))
$version = 'dev'
$vf = Join-Path $Root 'VERSION'; if (Test-Path $vf) { $version = ([IO.File]::ReadAllText($vf)).Trim() }

function Write-Heartbeat {
    param([string]$State = 'idle', [string]$Task = '')
    $hb = [ordered]@{ computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; isAdmin = $isAdmin; pid = $PID; version = $version; state = $State; task = $Task; time = (Get-Date).ToUniversalTime().ToString('o') }
    try { ConvertTo-Json -InputObject $hb -Compress | Set-Content -LiteralPath (Join-Path $Dir 'heartbeat.json') -Encoding UTF8 } catch { }
}

function Resolve-ManagerPath {
    param([string]$Relative)
    if ($Relative -match '\.\.' -or [IO.Path]::IsPathRooted($Relative)) { throw "Invalid manager path '$Relative'." }
    Join-Path $Root $Relative
}

# Heartbeat from a background runspace, so it keeps beating while a long copy/robocopy blocks the main thread.
$hbState = [hashtable]::Synchronized(@{ State = 'idle'; Task = ''; Stop = $false })
$hbPs = [powershell]::Create()
[void]$hbPs.AddScript({
        param($Dir, $Hb, $Admin, $Version, $AgentPid)
        while (-not $Hb.Stop) {
            $o = [ordered]@{ computer = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; isAdmin = $Admin; pid = $AgentPid; version = $Version; state = $Hb.State; task = $Hb.Task; time = (Get-Date).ToUniversalTime().ToString('o') }
            try { ConvertTo-Json -InputObject $o -Compress | Set-Content -LiteralPath (Join-Path $Dir 'heartbeat.json') -Encoding UTF8 } catch { }
            Start-Sleep -Seconds 5
        }
    }).AddArgument($Dir).AddArgument($hbState).AddArgument($isAdmin).AddArgument($version).AddArgument($PID)
$hbAsync = $hbPs.BeginInvoke()
Write-Heartbeat

Clear-Host
Write-Host ''
Write-Host "  PRTG Mover agent $version" -ForegroundColor Cyan
Write-Host "  Server : $env:COMPUTERNAME  (inventory id $ServerId)"
Write-Host "  Manager: $Root"
Write-Host '  Status : connected - waiting for jobs from the dashboard. Keep this window open.' -ForegroundColor Green
Write-Host ''

$lastWork = Get-Date
try {
    while (((Get-Date) - $lastWork).TotalHours -lt $IdleHours) {
        $next = Get-ChildItem -LiteralPath $Req -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime | Select-Object -First 1
        if (-not $next) { Start-Sleep -Milliseconds 700; continue }

        $working = "$($next.FullName).working"
        try { Move-Item -LiteralPath $next.FullName -Destination $working -ErrorAction Stop } catch { continue }
        $request = Get-Content -LiteralPath $working -Raw -Encoding UTF8 | ConvertFrom-Json
        $out = Join-Path $Resp "$($request.id).jsonl"
        $emit = {
            param($o)
            $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $o -Compress -Depth 12) + "`n")
            for ($try = 0; $try -lt 50; $try++) {
                try {
                    $fs = New-Object IO.FileStream($out, [IO.FileMode]::Append, [IO.FileAccess]::Write, [IO.FileShare]::ReadWrite)
                    try { $fs.Write($bytes, 0, $bytes.Length) } finally { $fs.Dispose() }
                    break
                } catch { Start-Sleep -Milliseconds 100 }
            }
            if ($o.PmType -eq 'log') {
                $c = @{ WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; STEP = 'Cyan' }[[string]$o.Level]; if (-not $c) { $c = 'Gray' }
                Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $o.Message) -ForegroundColor $c
            }
        }
        $params = @{}
        if ($request.params) { foreach ($p in $request.params.PSObject.Properties) { $v = $p.Value; if ($v -is [object[]]) { $v = [string[]]$v }; $params[$p.Name] = $v } }
        $hbState.State = 'busy'; $hbState.Task = $request.fn
        Write-Host ("[{0}] >> {1}" -f (Get-Date -Format 'HH:mm:ss'), $request.fn) -ForegroundColor Cyan
        try {
            switch ($request.fn) {
                'Send-PmAgentFile' {
                    # server -> manager
                    $dst = Resolve-ManagerPath $params.ManagerRelative
                    & $emit (Write-PmLog ("Copying {0} to the manager over RDP ({1:N1} MB)..." -f $params.Source, ((Get-Item -LiteralPath $params.Source).Length / 1MB)) 'STEP')
                    Copy-Item -LiteralPath $params.Source -Destination $dst -Force
                    & $emit (New-PmResult @{ Path = $dst })
                }
                'Receive-PmAgentFile' {
                    # manager -> server
                    $src = Resolve-ManagerPath $params.ManagerRelative
                    New-Item -ItemType Directory -Force -Path (Split-Path $params.Destination -Parent) | Out-Null
                    & $emit (Write-PmLog ("Copying {0} from the manager over RDP ({1:N1} MB)..." -f (Split-Path $src -Leaf), ((Get-Item -LiteralPath $src).Length / 1MB)) 'STEP')
                    Copy-Item -LiteralPath $src -Destination $params.Destination -Force
                    & $emit (New-PmResult @{ Path = $params.Destination; Sha256 = (Get-FileHash -LiteralPath $params.Destination -Algorithm SHA256).Hash })
                }
                default {
                    if ($request.fn -notmatch '^(Get-PmSystemInfo|Initialize-PmRemoteWorkRoot|Invoke-PmRemoteBackup|Invoke-PmRemoteRestore|Remove-PmRemoteFile)$') { throw "Function '$($request.fn)' is not allowed." }
                    & $request.fn @params | ForEach-Object { & $emit $_ }
                }
            }
        } catch {
            & $emit ([pscustomobject]@{ PmType = 'error'; Message = "$($_.Exception.Message)" })
            Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
        } finally {
            & $emit ([pscustomobject]@{ PmType = 'done' })
            Remove-Item -LiteralPath $working -Force -ErrorAction SilentlyContinue
            $hbState.State = 'idle'; $hbState.Task = ''
            $lastWork = Get-Date
        }
    }
    Write-Host "No work for $IdleHours h - agent stopping." -ForegroundColor Yellow
} finally {
    $hbState.Stop = $true
    try { [void]$hbAsync.AsyncWaitHandle.WaitOne(6000); $hbPs.Dispose() } catch { }
    Remove-Item -LiteralPath (Join-Path $Dir 'heartbeat.json') -Force -ErrorAction SilentlyContinue
}
