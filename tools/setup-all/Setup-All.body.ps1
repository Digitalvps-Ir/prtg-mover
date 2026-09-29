param(
    [string]$Self,
    [string]$PrtgMoverPath = 'C:\PrtgMover',
    [string]$VpnWatchPath = 'C:\VpnWatchDashboard',
    [int]$PrtgMoverPort = 8765,
    [int]$VpnWatchPort = 8770,
    [switch]$SkipPrtgMover,
    [switch]$SkipVpnWatch,
    [switch]$NoAutostart,
    [switch]$NoShortcut,
    [switch]$NoStart,
    [switch]$NoBrowser,
    [string]$ShortcutFolder,
    [string]$StartupFolder
)
# PRTG Mover + VPN Watch: installs or updates both on this Windows computer. Run it again to update.
# Data of an existing installation (servers, saved credentials, backups, logs) is never touched.
$ErrorActionPreference = 'Stop'
$ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$script:No = 0
function Step { param([string]$t) $script:No++; Write-Host ''; Write-Host ("[{0}] {1}" -f $script:No, $t) -ForegroundColor Cyan }
function Ok { param([string]$t) Write-Host "    $t" -ForegroundColor Green }
function Note { param([string]$t) Write-Host "    $t" -ForegroundColor Yellow }
function Test-Admin { (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) }
function Get-FreePort { $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop(); $p }
function Invoke-Script {
    # Runs a script in its own PowerShell and waits for THAT process only. Start-Process -Wait would also
    # wait for everything the script starts, for example a dashboard, and the setup would never go on.
    param([string[]]$Arguments)
    $p = Start-Process -FilePath $ps -ArgumentList $Arguments -PassThru -NoNewWindow
    $null = $p.Handle
    $p.WaitForExit()
    return $p.ExitCode
}
function Start-VpnWatchPanel {
    # opens the panel (starting it first when needed); with -NoBrowser it is only started
    param([bool]$Local)
    $script = if ($NoBrowser) { 'Start-VpnWatch.ps1' } else { 'Open-VpnWatch.ps1' }
    $o = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$VpnWatchPath\$script`"", '-Port', $VpnWatchPort)
    if ($NoBrowser) { $o += '-NoBrowser' }
    if ($Local) { $o += '-Local' }
    Start-Process -FilePath $ps -ArgumentList $o -WindowStyle Hidden -WorkingDirectory $VpnWatchPath
}
function Get-Dashboard {
    # processes that run a dashboard from an installation folder
    param([string]$Folder, [string]$Script)
    $needle = (Join-Path $Folder $Script)
    @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -and $_.CommandLine.IndexOf($needle, [StringComparison]::OrdinalIgnoreCase) -ge 0 })
}

try {
    Write-Host ''
    Write-Host "  PRTG Mover __PM_VERSION__ + VPN Watch __VW_VERSION__ - setup" -ForegroundColor Cyan
    if ($env:OS -ne 'Windows_NT' -or $PSVersionTable.PSVersion -lt [version]'5.1') { throw "Windows with Windows PowerShell 5.1 or newer is needed (found $($PSVersionTable.PSVersion))." }
    $PrtgMoverPath = [IO.Path]::GetFullPath($PrtgMoverPath).TrimEnd('\')
    $VpnWatchPath = [IO.Path]::GetFullPath($VpnWatchPath).TrimEnd('\')
    $admin = Test-Admin

    Step 'Unpacking'
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('setup-all-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    [IO.File]::WriteAllBytes("$tmp\payload.zip", [Convert]::FromBase64String(($Payload -replace '\s', '')))
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory("$tmp\payload.zip", "$tmp\files")
    Ok 'program files unpacked'

    # ------------------------------------------------------------ PRTG Mover
    if (-not $SkipPrtgMover) {
        Step "PRTG Mover -> $PrtgMoverPath"
        $run = Get-Dashboard $PrtgMoverPath 'Start-PrtgMover.ps1'
        foreach ($d in $run) {
            # A dashboard is only stopped when it says itself that no job is running. No answer means: do not touch it.
            $port = if ($d.CommandLine -match '-Port\s+(\d+)') { [int]$Matches[1] } else { 8765 }
            try { $jobs = @(Invoke-RestMethod "http://localhost:$port/api/jobs" -TimeoutSec 15 | ForEach-Object { $_ }) }
            catch { throw "PRTG Mover is running (process $($d.ProcessId)) and does not answer on port $port, so it is not known whether a job is running. Nothing was changed. Close the dashboard yourself and run the setup again." }
            $busy = @($jobs | Where-Object { $_.status -in 'running', 'queued' }).Count
            if ($busy) { throw "PRTG Mover is working on $busy job(s) right now. Nothing was changed. Run the setup again when they are finished." }
            Stop-Process -Id $d.ProcessId -Force -ErrorAction SilentlyContinue
            Ok "the running dashboard on port $port was stopped for the update (no job was running)"
        }
        if ($run.Count) { Start-Sleep -Seconds 1 }
        # PRTG is installed on this computer and the setup has administrator rights: local mode
        $pmLocal = $admin -and -not $NoShortcut -and [bool](Get-Service -Name PRTGCoreService -ErrorAction SilentlyContinue)
        $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$tmp\files\PrtgMover\install.ps1`"", '-Source', "`"$tmp\files\PrtgMover`"", '-InstallPath', "`"$PrtgMoverPath`"", '-Port', $PrtgMoverPort, '-NoStart')
        if ($NoAutostart) { $a += '-NoAutostart' } elseif (-not $pmLocal) { $a += '-Autostart' }
        if ($pmLocal) { $a += '-Local' }
        if ($NoShortcut) { $a += '-NoShortcut' }
        if ($ShortcutFolder) { $a += @('-ShortcutFolder', "`"$ShortcutFolder`"") }
        if ($StartupFolder) { $a += @('-StartupFolder', "`"$StartupFolder`"") }
        $rc = Invoke-Script $a
        if ($rc -ne 0) { throw "The installation of PRTG Mover failed (code $rc). See the message above." }
        if (-not $NoStart) {
            # started here, without waiting for it: the setup has to go on with VPN Watch
            if ($pmLocal -and -not $NoAutostart) {
                # local mode: always through the task, so the dashboard runs under the same account as after a restart
                Start-ScheduledTask -TaskName 'PRTG Mover Dashboard'
                if (-not $NoBrowser) { Start-Process -FilePath $ps -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$PrtgMoverPath\Open-PrtgMover.ps1`"", '-Port', $PrtgMoverPort) }
            } else {
                $d = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$PrtgMoverPath\Start-PrtgMover.ps1`"", '-Port', $PrtgMoverPort)
                if ($NoBrowser) { $d += '-NoBrowser' }
                Start-Process -FilePath $ps -WorkingDirectory $PrtgMoverPath -ArgumentList $d
            }
        }
        if ($pmLocal) { Ok 'local mode: this computer is in the server list, PRTG Mover backs it up without any connection' }
        elseif (Get-Service -Name PRTGCoreService -ErrorAction SilentlyContinue) { Note "PRTG is installed on this computer. To back it up from here, run this setup once with 'Run as administrator'." }
        Ok "PRTG Mover is installed: http://localhost:$PrtgMoverPort/"
    }

    # ------------------------------------------------------------ VPN Watch
    if (-not $SkipVpnWatch) {
        Step "VPN Watch -> $VpnWatchPath"
        $src = "$tmp\files\VpnWatch"
        $run = Get-Dashboard $VpnWatchPath 'Start-VpnWatch.ps1'
        if ($run.Count) { $run | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }; Start-Sleep -Seconds 1; Ok 'the running dashboard was stopped for the update' }
        New-Item -ItemType Directory -Force -Path $VpnWatchPath | Out-Null
        foreach ($item in (Get-ChildItem -LiteralPath $src -Force)) {
            if ($item.Name -in 'config', 'data') { continue }   # never part of the package, never touched
            if ($item.PSIsContainer) {
                & robocopy.exe $item.FullName (Join-Path $VpnWatchPath $item.Name) /MIR /R:2 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
                if ($LASTEXITCODE -ge 8) { throw "Copying '$($item.Name)' failed (robocopy $LASTEXITCODE)." }
            } else { Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $VpnWatchPath $item.Name) -Force }
        }
        $global:LASTEXITCODE = 0
        Get-ChildItem -LiteralPath $VpnWatchPath -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cmd' } | Unblock-File -ErrorAction SilentlyContinue
        foreach ($f in (Get-ChildItem -LiteralPath $VpnWatchPath -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch '\\(data|config)\\' })) {
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
            if ($errors) { throw "Script '$($f.FullName)' is damaged: $($errors[0].Message)" }
        }
        # test: the dashboard must answer on a free port
        $tp = Get-FreePort
        $t = Start-Process -FilePath $ps -PassThru -WindowStyle Hidden -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$VpnWatchPath\Start-VpnWatch.ps1`"", '-Port', $tp, '-NoBrowser')
        try {
            $up = $false; $until = (Get-Date).AddSeconds(45)
            while (-not $up -and (Get-Date) -lt $until) {
                if ($t.HasExited) { throw 'The VPN Watch dashboard stopped right after starting.' }
                try { $up = ((Invoke-WebRequest "http://localhost:$tp/" -UseBasicParsing -TimeoutSec 3).Content -match 'VPN Watch') } catch { Start-Sleep -Milliseconds 500 }
            }
            if (-not $up) { throw 'The VPN Watch dashboard did not answer within 45 seconds.' }
        } finally { if (-not $t.HasExited) { Stop-Process -Id $t.Id -Force -ErrorAction SilentlyContinue } }
        Ok "program files copied and tested (version $(([IO.File]::ReadAllText("$VpnWatchPath\VERSION")).Trim()))"

        if ($NoShortcut) {
            # the shortcut and the start with Windows of VPN Watch are created together by its own installer
            Note 'VPN Watch: no shortcut and no start with Windows (-NoShortcut)'
            if (-not $NoStart) { Start-VpnWatchPanel -Local $false }
        } else {
            $own = 0
            if (Get-Command Get-VpnConnection -ErrorAction SilentlyContinue) {
                try { $own += @(Get-VpnConnection -AllUserConnection -ErrorAction Stop).Count } catch { }
                try { $own += @(Get-VpnConnection -ErrorAction Stop).Count } catch { }
            }
            $isServer = $false
            try { $isServer = ((Get-CimInstance Win32_OperatingSystem).ProductType -ne 1) } catch { }
            $local = ($admin -and ($own -gt 0 -or $isServer))
            if ($local) {
                # a server, or a computer with VPN connections of its own: VPN Watch manages this computer directly
                $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$VpnWatchPath\tools\Install-VpnWatchLocal.ps1`"", '-Port', $VpnWatchPort)
                # -AtBoot: the panel starts with the computer, without logon (VPN Watch 0.6.0 and newer)
                if ($NoAutostart) { $a += '-NoStart' } else { $a += '-AtBoot' }
            } else {
                $a = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$VpnWatchPath\tools\Install-VpnWatchShortcut.ps1`"", '-Port', $VpnWatchPort)
                if ($NoAutostart) { $a += '-NoAutostart' }
            }
            $rc = Invoke-Script $a
            if ($rc -eq 2) { Note 'VPN Watch is installed, but its panel did not answer yet. Open it with the "VPN Watch" shortcut.' }
            elseif ($rc -ne 0) { throw "Shortcut / start with Windows of VPN Watch failed (code $rc). See the message above." }
            if ($local) { Ok "local mode: VPN Watch manages the $own VPN connection(s) of this computer" }
            elseif ($own -gt 0) { Note "This computer has $own VPN connection(s) of its own. To manage them here, run this setup once with 'Run as administrator'." }
            if (-not $NoStart) { Start-VpnWatchPanel -Local $local }
        }
        Ok "VPN Watch is installed: http://localhost:$VpnWatchPort/ (open it with the 'VPN Watch' shortcut)"
    }

    Write-Host ''
    Write-Host '  DONE.' -ForegroundColor Green
    if (-not $SkipPrtgMover) { Write-Host "  PRTG Mover : shortcut 'PRTG Mover'  ($PrtgMoverPath)" }
    if (-not $SkipVpnWatch) { Write-Host "  VPN Watch  : shortcut 'VPN Watch'   ($VpnWatchPath)" }
    Write-Host '  Servers, users and passwords are entered in the dashboards. Run this file again to update.'
    $code = 0
} catch {
    Write-Host ''
    Write-Host "  SETUP FAILED: $($_.Exception.Message)" -ForegroundColor Red
    $code = 1
} finally {
    if ($tmp -and (Test-Path -LiteralPath $tmp)) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}
exit $code
