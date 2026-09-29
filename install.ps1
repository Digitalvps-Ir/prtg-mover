<#
.SYNOPSIS
    Installs or updates PRTG Mover on this computer (the manager) in one step.

.DESCRIPTION
    1. Checks the requirements (Windows, Windows PowerShell 5.1 or newer).
    2. Gets the program files: from the folder this script is in, from -Source (folder or
       zip), or from GitHub (git, GitHub CLI or a plain download, whichever works).
    3. Copies them to -InstallPath. Your data is never touched: config\, data\, backups\
       and installers\ of an existing installation stay as they are.
    4. Unblocks the scripts and tests the installation: every script must parse and the
       dashboard must answer on a free port.
    5. Creates the shortcuts "PRTG Mover" on the desktop and in the start menu.
    6. Optional: prepares this computer for plain WinRM (-TrustedHosts, needs administrator
       rights; Windows asks for them).
    7. Starts the dashboard.

    Run it again at any time to update or repair the installation.

.PARAMETER InstallPath
    Where PRTG Mover is installed. Default: C:\PrtgMover.

.PARAMETER Source
    Folder or zip file with the program files. Default: the folder of this script if it
    contains PRTG Mover, otherwise GitHub.

.PARAMETER Repository
    GitHub repository (owner/name) used for the download.

.PARAMETER Branch
    Branch used for the download. Default: main.

.PARAMETER TrustedHosts
    Servers that are reached over plain WinRM (HTTP). Not needed for the RDP method and
    not needed for WinRM over HTTPS.

.PARAMETER Port
    Port of the dashboard. Default: 8765.

.PARAMETER ShortcutFolder
    Folders for the shortcut. Default: desktop and start menu of the current user.

.PARAMETER NoShortcut
    Do not create shortcuts.

.PARAMETER Autostart
    Start the dashboard when you log on to Windows (shortcut in the Startup folder, minimized,
    without opening the browser). An update keeps it.

.PARAMETER NoAutostart
    Remove the start with Windows again.

.PARAMETER StartupFolder
    Folder for the autostart shortcut. Default: the Startup folder of the current user.

.PARAMETER Local
    PRTG Mover is installed on the PRTG server itself. Adds this computer to the server list
    (connection method "Local"), starts the dashboard with administrator rights at logon
    (scheduled task) and makes the shortcut start it with administrator rights. Needs an
    elevated PowerShell.

.PARAMETER NoStart
    Do not start the dashboard at the end.

.PARAMETER Uninstall
    Removes the shortcuts and the program files. config\, data\, backups\ and installers\
    are kept.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -InstallPath D:\Tools\PrtgMover -TrustedHosts 10.0.0.10,10.0.0.20

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\install.ps1 -Uninstall
#>
[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\PrtgMover',
    [string]$Source,
    [string]$Repository = 'Digitalvps-Ir/prtg-mover',
    [string]$Branch = 'main',
    [string[]]$TrustedHosts = @(),
    [ValidateRange(1, 65535)][int]$Port = 8765,
    [string[]]$ShortcutFolder,
    [switch]$NoShortcut,
    [switch]$Autostart,
    [switch]$NoAutostart,
    [string]$StartupFolder,
    [switch]$Local,
    [switch]$NoStart,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$script:StepNo = 0
$ProgramItems = 'agent', 'cli', 'docs', 'src', 'tools', 'web', 'tests', '.github', 'config\servers.example.json',
    'Start-PrtgMover.ps1', 'Start-PrtgMover.cmd', 'Open-PrtgMover.ps1', 'install.ps1', 'install.cmd', 'VERSION', 'README.md', 'README.fa.md', 'CHANGELOG.md', 'LICENSE', '.gitignore', '.gitattributes'
$RequiredFiles = 'Start-PrtgMover.ps1', 'src\PrtgMover.psm1', 'src\Remote\PrtgMover.Remote.ps1', 'web\index.html', 'web\app.js', 'VERSION'
$DataFolders = 'config', 'data', 'backups', 'installers'

function Write-Step { param([string]$Text) $script:StepNo++; Write-Host ("[{0}] {1}" -f $script:StepNo, $Text) -ForegroundColor Cyan }
function Write-Ok { param([string]$Text) Write-Host "    $Text" -ForegroundColor Green }
function Write-Note { param([string]$Text) Write-Host "    $Text" -ForegroundColor Yellow }
function Write-Info { param([string]$Text) Write-Host "    $Text" }

function Test-ProgramFolder {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path -PathType Container)) { return $false }
    foreach ($f in $RequiredFiles) { if (-not (Test-Path -LiteralPath (Join-Path $Path $f))) { return $false } }
    return $true
}

function Find-Tool {
    param([string]$Name, [string[]]$Fallback = @())
    $c = Get-Command $Name -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($c) { return $c.Source }
    foreach ($f in $Fallback) { if (Test-Path -LiteralPath $f) { return $f } }
    return $null
}

function Get-ShortcutFolders {
    if ($ShortcutFolder) { return $ShortcutFolder }
    return @([Environment]::GetFolderPath('Desktop'), (Join-Path ([Environment]::GetFolderPath('Programs')) 'PRTG Mover'))
}

function Test-IsAdmin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-FreePort {
    $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0)
    $l.Start(); $p = $l.LocalEndpoint.Port; $l.Stop()
    return $p
}

function Get-ProgramFromGitHub {
    <# Downloads the program into a temporary folder and returns that folder. #>
    param([string]$Repo, [string]$Ref)
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('prtg-mover-' + [guid]::NewGuid().ToString('N'))
    $tried = @()
    $git = Find-Tool 'git.exe' @("$env:ProgramFiles\Git\cmd\git.exe")
    if ($git) {
        $tried += 'git'
        Write-Info "Downloading with git from https://github.com/$Repo ($Ref)..."
        & $git clone --quiet --depth 1 --branch $Ref "https://github.com/$Repo.git" $tmp 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-ProgramFolder $tmp)) { return $tmp }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $gh = Find-Tool 'gh.exe' @("$env:ProgramFiles\GitHub CLI\gh.exe")
    if ($gh) {
        $tried += 'GitHub CLI'
        Write-Info "Downloading with the GitHub CLI from $Repo ($Ref)..."
        & $gh repo clone $Repo $tmp -- --quiet --depth 1 --branch $Ref 2>$null
        if ($LASTEXITCODE -eq 0 -and (Test-ProgramFolder $tmp)) { return $tmp }
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $tried += 'download'
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = "$tmp.zip"
        Write-Info "Downloading https://github.com/$Repo/archive/refs/heads/$Ref.zip ..."
        Invoke-WebRequest -Uri "https://github.com/$Repo/archive/refs/heads/$Ref.zip" -OutFile $zip -UseBasicParsing
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $tmp)
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        $inner = Get-ChildItem -LiteralPath $tmp -Directory | Select-Object -First 1
        if ($inner -and (Test-ProgramFolder $inner.FullName)) { return $inner.FullName }
    } catch { Write-Info "Plain download failed: $($_.Exception.Message)" }
    throw ("Could not download PRTG Mover from GitHub (tried: {0}). The repository '{1}' is private: sign in first (git or 'gh auth login'), or download the ZIP from GitHub in your browser, extract it and run install.ps1 from that folder." -f ($tried -join ', '), $Repo)
}

function Copy-Program {
    <# Copies the program files. Data folders of an existing installation are never touched. #>
    param([string]$From, [string]$To)
    New-Item -ItemType Directory -Force -Path $To | Out-Null
    foreach ($item in $ProgramItems) {
        $src = Join-Path $From $item
        if (-not (Test-Path -LiteralPath $src)) { continue }
        $dst = Join-Path $To $item
        if (Test-Path -LiteralPath $src -PathType Container) {
            & robocopy.exe $src $dst /MIR /R:2 /W:1 /NP /NFL /NDL /NJH /NJS | Out-Null
            if ($LASTEXITCODE -ge 8) { throw "Copying '$item' failed (robocopy $LASTEXITCODE)." }
        } else {
            New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
            Copy-Item -LiteralPath $src -Destination $dst -Force
        }
    }
    $global:LASTEXITCODE = 0
}

function Test-Installation {
    <# Every script must parse, and the dashboard must answer on a free port. Returns the version. #>
    param([string]$Path)
    # -Include is ignored together with -LiteralPath in Windows PowerShell 5.1, so filter by extension.
    $dataPattern = '^' + [regex]::Escape($Path.TrimEnd('\')) + '\\(data|backups|installers)\\'
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File | Where-Object { $_.Extension -in '.ps1', '.psm1' -and $_.FullName -notmatch $dataPattern })) {
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errors)
        if ($errors) { throw "Script '$($f.FullName)' is damaged: $($errors[0].Message)" }
    }
    $testPort = Get-FreePort
    $testData = Join-Path ([IO.Path]::GetTempPath()) ('prtg-mover-selftest-' + [guid]::NewGuid().ToString('N'))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $p = Start-Process -FilePath $ps -PassThru -WindowStyle Hidden -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Path 'Start-PrtgMover.ps1')`"",
        '-Port', $testPort, '-NoBrowser', '-Quiet', '-DataRoot', "`"$testData`"")
    try {
        $info = $null
        $deadline = (Get-Date).AddSeconds(45)
        while (-not $info -and (Get-Date) -lt $deadline) {
            if ($p.HasExited) { throw "The dashboard stopped right after starting (exit code $($p.ExitCode))." }
            try { $info = Invoke-RestMethod -Uri "http://localhost:$testPort/api/info" -TimeoutSec 3 } catch { Start-Sleep -Milliseconds 500 }
        }
        if (-not $info) { throw 'The dashboard did not answer within 45 seconds.' }
        $page = Invoke-WebRequest -Uri "http://localhost:$testPort/" -UseBasicParsing -TimeoutSec 10
        if ($page.Content -notmatch 'PRTG Mover') { throw 'The dashboard page is not served correctly.' }
        return [string]$info.version
    } finally {
        if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 300
        Remove-Item -LiteralPath $testData -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function New-Shortcuts {
    param([string]$Path)
    $shell = New-Object -ComObject WScript.Shell
    $made = @()
    foreach ($folder in (Get-ShortcutFolders)) {
        New-Item -ItemType Directory -Force -Path $folder | Out-Null
        $lnk = Join-Path $folder 'PRTG Mover.lnk'
        $s = $shell.CreateShortcut($lnk)
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Path 'Start-PrtgMover.ps1')`" -Port $Port"
        if ($Local) {
            # local mode: the dashboard runs from the start of the computer; the shortcut opens it (and starts the task when needed)
            $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Path 'Open-PrtgMover.ps1')`" -Port $Port"
            $s.WindowStyle = 7
        }
        $s.WorkingDirectory = $Path
        $s.Description = 'PRTG Mover dashboard'
        $s.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',109'
        $s.Save()
        if ($Local) {
            # "Run as administrator" of the shortcut: jobs on this computer need administrator rights
            $bytes = [IO.File]::ReadAllBytes($lnk); $bytes[0x15] = $bytes[0x15] -bor 0x20; [IO.File]::WriteAllBytes($lnk, $bytes)
        }
        $made += $lnk
    }
    return $made
}

$LogonTask = 'PRTG Mover Dashboard'

function Test-OwnLogonTask {
    param([string]$Path)
    $t = Get-ScheduledTask -TaskName $LogonTask -ErrorAction SilentlyContinue
    if (-not $t) { return $false }
    return [bool](@($t.Actions | Where-Object { "$($_.Arguments)".IndexOf("$($Path.TrimEnd('\'))\Start-PrtgMover.", [StringComparison]::OrdinalIgnoreCase) -ge 0 }).Count)
}

function Set-LogonTask {
    <#
        Local mode: the dashboard starts when the COMPUTER starts, without anybody logging on, and
        with the rights that backup and restore of this computer need. It runs as SYSTEM, always the
        same account, so credentials saved in the dashboard stay readable after every restart.
    #>
    param([string]$Path)
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $exe -WorkingDirectory $Path -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$(Join-Path $Path 'Start-PrtgMover.ps1')`" -Port $Port -NoBrowser -Quiet"
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)
    Register-ScheduledTask -TaskName $LogonTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the PRTG Mover dashboard when the computer starts (local mode).' -Force | Out-Null
    return "task '$LogonTask': starts with the computer, without logon"
}

function Start-LocalDashboard {
    <# Starts the dashboard through its task and waits until it answers. #>
    Start-ScheduledTask -TaskName $LogonTask
    $until = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $until) {
        try { if ((Invoke-RestMethod -Uri "http://localhost:$Port/api/info" -TimeoutSec 3).product -eq 'PRTG Mover') { return $true } } catch { Start-Sleep -Milliseconds 700 }
    }
    return $false
}

function Add-LocalServer {
    <# Adds this computer to the server list of the installation (connection method "local"), once. #>
    param([string]$Path)
    Import-Module (Join-Path $Path 'src\PrtgMover.psm1') -Force -DisableNameChecking
    Set-PmRoot -Path $Path
    $have = @(Get-PmServers | ForEach-Object { $_ } | Where-Object { $_.transport -eq 'local' })
    if ($have.Count) { return "this computer is already in the server list ('$($have[0].name)')" }
    [void](Set-PmServer -Name $env:COMPUTERNAME -HostName 'localhost' -Role 'both' -Transport 'local')
    return "this computer was added to the server list ('$env:COMPUTERNAME', connection method Local)"
}

function Get-AutostartShortcut {
    $folder = if ($StartupFolder) { $StartupFolder } else { [Environment]::GetFolderPath('Startup') }
    return (Join-Path $folder 'PRTG Mover.lnk')
}

function Set-AutostartShortcut {
    <# The dashboard starts at logon: minimized and without opening the browser. #>
    param([string]$Path)
    $lnk = Get-AutostartShortcut
    New-Item -ItemType Directory -Force -Path (Split-Path $lnk -Parent) | Out-Null
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
    $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $s.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $Path 'Start-PrtgMover.ps1')`" -Port $Port -NoBrowser"
    $s.WorkingDirectory = $Path
    $s.WindowStyle = 7
    $s.Description = 'PRTG Mover dashboard (start with Windows)'
    $s.IconLocation = (Join-Path $env:SystemRoot 'System32\imageres.dll') + ',109'
    $s.Save()
    return $lnk
}

function Test-OwnShortcut {
    <# True when the shortcut starts PRTG Mover from this installation folder. #>
    param([string]$Link, [string]$Path)
    if (-not (Test-Path -LiteralPath $Link)) { return $false }
    $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Link)
    $folder = $Path.TrimEnd('\')
    $ic = [StringComparison]::OrdinalIgnoreCase
    return ("$($s.WorkingDirectory)".TrimEnd('\').Equals($folder, $ic)) -or ("$($s.Arguments)".IndexOf("$folder\Start-PrtgMover.", $ic) -ge 0) -or ("$($s.TargetPath)".StartsWith("$folder\", $ic))
}

function Remove-Shortcuts {
    <# Removes the shortcuts of THIS installation. A shortcut that starts another folder is left alone. #>
    param([string]$Path)
    $removed = @()
    $links = @(Get-AutostartShortcut) + @(Get-ShortcutFolders | ForEach-Object { Join-Path $_ 'PRTG Mover.lnk' })
    foreach ($lnk in $links) {
        if (Test-OwnShortcut -Link $lnk -Path $Path) { Remove-Item -LiteralPath $lnk -Force; $removed += $lnk }
    }
    foreach ($folder in (Get-ShortcutFolders)) {
        if ((Split-Path $folder -Leaf) -eq 'PRTG Mover' -and (Test-Path -LiteralPath $folder) -and -not (Get-ChildItem -LiteralPath $folder -Force)) { Remove-Item -LiteralPath $folder -Force }
    }
    return $removed
}

# ------------------------------------------------------------------ start
Write-Host ''
Write-Host "  PRTG Mover - $(if ($Uninstall) { 'uninstall' } else { 'installation' })" -ForegroundColor Cyan
Write-Host "  Folder: $InstallPath"
Write-Host ''

Write-Step 'Checking this computer'
if ($env:OS -ne 'Windows_NT') { throw 'PRTG Mover needs Windows.' }
if ($PSVersionTable.PSVersion -lt [version]'5.1') { throw "Windows PowerShell 5.1 or newer is needed (found $($PSVersionTable.PSVersion)). Install Windows Management Framework 5.1." }
Write-Ok "Windows PowerShell $($PSVersionTable.PSVersion), user $env:USERDOMAIN\$env:USERNAME$(if (Test-IsAdmin) { ' (administrator)' })"
$InstallPath = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
if ($Local -and -not $Uninstall -and -not (Test-IsAdmin)) { throw 'Local mode (-Local) needs administrator rights: backup and restore of this computer work with snapshots, the registry and services. Start the installation with "Run as administrator".' }

if ($Uninstall) {
    Write-Step 'Removing shortcuts'
    if (Test-OwnLogonTask -Path $InstallPath) { Unregister-ScheduledTask -TaskName $LogonTask -Confirm:$false; Write-Ok "removed the logon task '$LogonTask'" }
    $r = @(Remove-Shortcuts -Path $InstallPath)
    if ($r.Count) { $r | ForEach-Object { Write-Ok "removed $_" } } else { Write-Info 'no shortcuts found' }
    Write-Step 'Removing program files'
    if (-not (Test-ProgramFolder $InstallPath)) { Write-Note "No PRTG Mover installation in $InstallPath - nothing removed."; return }
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" | Where-Object { $_.CommandLine -like "*$InstallPath\Start-PrtgMover.ps1*" })
    if ($running.Count) { throw 'The dashboard is running from this folder. Close its window first.' }
    foreach ($item in $ProgramItems) {
        $t = Join-Path $InstallPath $item
        if ($PSScriptRoot -and $t -eq (Join-Path $PSScriptRoot 'install.ps1')) { continue }   # the running script
        if (Test-Path -LiteralPath $t) { Remove-Item -LiteralPath $t -Recurse -Force }
    }
    $kept = @($DataFolders | Where-Object { Test-Path -LiteralPath (Join-Path $InstallPath $_) })
    Write-Ok 'program files removed'
    if ($kept.Count) { Write-Note "Kept (your data): $($kept -join ', ') in $InstallPath" }
    return
}

Write-Step 'Getting the program files'
$from = $null; $temporary = $null
if ($Source) {
    if (-not (Test-Path -LiteralPath $Source)) { throw "Source '$Source' does not exist." }
    if ((Get-Item -LiteralPath $Source).PSIsContainer) { $from = (Resolve-Path -LiteralPath $Source).Path }
    else {
        $temporary = Join-Path ([IO.Path]::GetTempPath()) ('prtg-mover-' + [guid]::NewGuid().ToString('N'))
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory((Resolve-Path -LiteralPath $Source).Path, $temporary)
        $from = $temporary
        if (-not (Test-ProgramFolder $from)) { $inner = Get-ChildItem -LiteralPath $temporary -Directory | Select-Object -First 1; if ($inner) { $from = $inner.FullName } }
    }
    if (-not (Test-ProgramFolder $from)) { throw "'$Source' does not contain PRTG Mover." }
    Write-Ok "from $Source"
} elseif ($PSScriptRoot -and (Test-ProgramFolder $PSScriptRoot)) {
    $from = $PSScriptRoot.TrimEnd('\')
    Write-Ok "from this folder ($from)"
} else {
    $from = Get-ProgramFromGitHub -Repo $Repository -Ref $Branch
    $temporary = $from
    Write-Ok "downloaded from GitHub ($Repository, $Branch)"
}

try {
    Write-Step 'Installing'
    $before = $null
    $vf = Join-Path $InstallPath 'VERSION'
    if (Test-Path -LiteralPath $vf) { $before = ([IO.File]::ReadAllText($vf)).Trim() }
    $running = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -like "*$InstallPath\Start-PrtgMover.ps1*" -and $_.CommandLine -notlike '*-DataRoot*' })
    if ($from -ne $InstallPath) {
        if ($running.Count) { throw "The dashboard is running from $InstallPath. Close its window (in local mode: stop the task '$LogonTask' in an elevated PowerShell with Stop-ScheduledTask), then run the installation again." }
        Copy-Program -From $from -To $InstallPath
        Write-Ok "program files copied to $InstallPath"
    } else { Write-Ok 'the program is already in this folder - nothing to copy' }
    foreach ($d in $DataFolders) { New-Item -ItemType Directory -Force -Path (Join-Path $InstallPath $d) | Out-Null }
    $kept = @()
    if (Test-Path -LiteralPath (Join-Path $InstallPath 'config\servers.json')) { $kept += 'server list' }
    if (Get-ChildItem -LiteralPath (Join-Path $InstallPath 'backups') -Filter '*.zip' -ErrorAction SilentlyContinue) { $kept += 'backups' }
    if ($kept.Count) { Write-Ok "your data was kept: $($kept -join ', ')" }
    Get-ChildItem -LiteralPath $InstallPath -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.ps1', '.psm1', '.cmd' } | Unblock-File -ErrorAction SilentlyContinue
    Write-Ok 'scripts unblocked'

    Write-Step 'Testing the installation'
    $version = Test-Installation -Path $InstallPath
    Write-Ok "all scripts are intact and the dashboard answers (version $version$(if ($before -and $before -ne $version) { ", was $before" }))"

    Write-Step 'Shortcuts'
    if ($NoShortcut) { Write-Info 'skipped (-NoShortcut)' }
    else { New-Shortcuts -Path $InstallPath | ForEach-Object { Write-Ok $_ } }

    Write-Step 'Start with Windows'
    $auto = Get-AutostartShortcut
    $exists = Test-Path -LiteralPath $auto
    $own = Test-OwnShortcut -Link $auto -Path $InstallPath
    if ($NoAutostart) {
        if (Test-OwnLogonTask -Path $InstallPath) { Unregister-ScheduledTask -TaskName $LogonTask -Confirm:$false; Write-Ok 'logon task removed' }
        if ($own) { Remove-Item -LiteralPath $auto -Force; Write-Ok 'switched off' }
        elseif ($exists) { Write-Note 'another installation of PRTG Mover starts with Windows - left as it is' }
        else { Write-Info 'was not switched on' }
    } elseif ($Local) {
        # with administrator rights: a scheduled task instead of the Startup shortcut
        if ($own) { Remove-Item -LiteralPath $auto -Force }
        Write-Ok "the dashboard comes up by itself after a restart ($(Set-LogonTask -Path $InstallPath))"
    } elseif ($Autostart) {
        if ($exists -and -not $own) { Write-Note 'the start with Windows belonged to another installation - it starts this one now' }
        Write-Ok "the dashboard starts when you log on ($(Set-AutostartShortcut -Path $InstallPath))"
    } elseif ($own) {
        Write-Ok "the dashboard starts when you log on ($(Set-AutostartShortcut -Path $InstallPath))"
    } elseif ($exists) { Write-Info 'another installation of PRTG Mover starts with Windows - left as it is' }
    else { Write-Info 'not switched on (use -Autostart)' }

    Write-Step 'This computer as a server (local mode)'
    if ($Local) { Write-Ok (Add-LocalServer -Path $InstallPath) }
    else { Write-Info 'skipped - use -Local when PRTG Mover is installed on the PRTG server itself' }

    Write-Step 'WinRM on this computer'
    if (-not $TrustedHosts.Count) { Write-Info 'skipped - only needed for servers reached over plain WinRM (HTTP). RDP and WinRM over HTTPS need nothing here.' }
    else {
        $setup = Join-Path $InstallPath 'tools\Setup-Manager.ps1'
        $setupArgs = "-NoProfile -ExecutionPolicy Bypass -File `"$setup`" -TrustedHosts $($TrustedHosts -join ',')"
        if (Test-IsAdmin) {
            & $setup -TrustedHosts $TrustedHosts
            Write-Ok "trusted servers: $($TrustedHosts -join ', ')"
        } else {
            Write-Note 'Administrator rights are needed for this step - Windows asks for them now.'
            try {
                $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $setupArgs -Verb RunAs -Wait -PassThru
                if ($p.ExitCode -eq 0) { Write-Ok "trusted servers: $($TrustedHosts -join ', ')" } else { Write-Note "Setup-Manager ended with code $($p.ExitCode). Run it again in an elevated PowerShell: powershell $setupArgs" }
            } catch { Write-Note "Not done ($($_.Exception.Message)). Run this in an elevated PowerShell: powershell $setupArgs" }
        }
    }

    Write-Step 'Starting the dashboard'
    if ($NoStart) { Write-Info 'skipped (-NoStart)' }
    elseif ($running.Count) { Write-Ok "the dashboard is already running: http://localhost:$Port/" }
    elseif ($Local -and -not $NoAutostart) {
        if (Start-LocalDashboard) { Write-Ok "http://localhost:$Port/ is up (started by the task '$LogonTask')"; Start-Process "http://localhost:$Port/" }
        else { Write-Note "The dashboard did not answer within 60 seconds. Open it with the 'PRTG Mover' shortcut." }
    } else {
        Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -WorkingDirectory $InstallPath -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$(Join-Path $InstallPath 'Start-PrtgMover.ps1')`"", '-Port', $Port)
        Write-Ok "http://localhost:$Port/ opens in your browser"
    }

    Write-Host ''
    Write-Host "  PRTG Mover $version is installed in $InstallPath" -ForegroundColor Green
    Write-Host '  Open it with the "PRTG Mover" shortcut (it opens the running dashboard or starts it). Run install.ps1 again to update.'
    Write-Host ''
} finally {
    if ($temporary -and (Test-Path -LiteralPath $temporary)) { Remove-Item -LiteralPath $temporary -Recurse -Force -ErrorAction SilentlyContinue }
}
