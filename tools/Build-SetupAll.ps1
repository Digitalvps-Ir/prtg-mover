<#
.SYNOPSIS
    Builds Setup-All.cmd: ONE file that installs PRTG Manager and VPN Manager on a Windows computer.

.DESCRIPTION
    The file contains both programs (the files that git tracks, no data, no credentials) and
    the setup script. Copy it to a Windows computer and double-click it.

.PARAMETER VpnManagerSource
    Folder of the VPN Manager repository (-VpnWatchSource still works).

.PARAMETER Output
    The file to write. Default: Setup-All.cmd next to the PRTG Manager folder.

.EXAMPLE
    .\tools\Build-SetupAll.ps1 -VpnManagerSource F:\ClaudeCode\Vpn-Watch
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][Alias('VpnWatchSource')][string]$VpnManagerSource,
    [Alias('PrtgMoverSource')][string]$PrtgManagerSource,
    [string]$Output
)
$ErrorActionPreference = 'Stop'
if (-not $PrtgManagerSource) { $PrtgManagerSource = Split-Path $PSScriptRoot -Parent }
$PrtgManagerSource = (Resolve-Path -LiteralPath $PrtgManagerSource).Path.TrimEnd('\')
$VpnManagerSource = (Resolve-Path -LiteralPath $VpnManagerSource).Path.TrimEnd('\')
if (-not $Output) { $Output = Join-Path (Split-Path $PrtgManagerSource -Parent) 'Setup-All.cmd' }

function Get-ProgramFiles {
    <# The files git tracks; without git every file except data, configuration and backups. #>
    param([string]$Folder)
    $git = Get-Command git.exe -ErrorAction SilentlyContinue
    if (-not $git -and (Test-Path "$env:ProgramFiles\Git\cmd\git.exe")) { $git = "$env:ProgramFiles\Git\cmd\git.exe" }
    if ($git -and (Test-Path -LiteralPath (Join-Path $Folder '.git'))) {
        $list = @(& $git -C $Folder ls-files)
        if ($LASTEXITCODE -eq 0 -and $list.Count) { return $list | ForEach-Object { $_ -replace '/', '\' } }
    }
    Get-ChildItem -LiteralPath $Folder -Recurse -File -Force | ForEach-Object { $_.FullName.Substring($Folder.Length + 1) } |
        Where-Object { $_ -notmatch '^(\.git|data|backups|installers)\\' -and $_ -notmatch '^config\\(?!servers\.example\.json$)' }
}

Add-Type -AssemblyName System.IO.Compression.FileSystem
$zipFile = Join-Path ([IO.Path]::GetTempPath()) ('setup-all-' + [guid]::NewGuid().ToString('N') + '.zip')
$zip = [IO.Compression.ZipFile]::Open($zipFile, 'Create')
try {
    foreach ($part in @(@{ Name = 'PrtgManager'; Folder = $PrtgManagerSource }, @{ Name = 'VpnManager'; Folder = $VpnManagerSource })) {
        $files = @(Get-ProgramFiles $part.Folder | Where-Object { $_ -notmatch '^(tests|\.github)\\' -or $part.Name -eq 'PrtgManager' })
        if (-not $files.Count) { throw "No program files found in $($part.Folder)." }
        foreach ($f in $files) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $part.Folder $f), "$($part.Name)/$($f -replace '\\', '/')", 'Optimal') }
        Write-Host ("{0}: {1} files from {2}" -f $part.Name, $files.Count, $part.Folder)
    }
} finally { $zip.Dispose() }

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($zipFile), 'InsertLineBreaks')
[IO.File]::Delete($zipFile)
$pm = ([IO.File]::ReadAllText((Join-Path $PrtgManagerSource 'VERSION'))).Trim()
$vw = ([IO.File]::ReadAllText((Join-Path $VpnManagerSource 'VERSION'))).Trim()
$body = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'setup-all\Setup-All.body.ps1')).Replace('__PM_VERSION__', $pm).Replace('__VM_VERSION__', $vw)
$marker = "`$ErrorActionPreference = 'Stop'"
$at = $body.IndexOf($marker)
if ($at -lt 0) { throw 'Setup-All.body.ps1 has an unexpected layout.' }
$body = $body.Substring(0, $at) + "`$Payload = @'`r`n$b64`r`n'@`r`n" + $body.Substring($at)

# The batch part starts Windows PowerShell on this same file; for PowerShell it is a comment.
$head = @'
<# :
@echo off
setlocal
title PRTG Manager + VPN Manager setup
set "SETUPALL_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$f = '%~f0'; $s = [ScriptBlock]::Create([IO.File]::ReadAllText($f)); Invoke-Expression ('& $s -Self $f ' + $env:SETUPALL_ARGS)"
set "code=%errorlevel%"
echo.
if not defined SETUPALL_NOPAUSE pause
exit /b %code%
#>
'@
$text = (($head + "`r`n" + $body) -replace "`r`n", "`n") -replace "`n", "`r`n"
if ($text -match '[^\x00-\x7F]') { throw 'The setup file must be plain ASCII.' }
[IO.File]::WriteAllText($Output, $text, (New-Object Text.ASCIIEncoding))
Write-Host ("Written: {0} ({1} KB) - PRTG Manager {2} + VPN Manager {3}" -f $Output, [math]::Round((Get-Item -LiteralPath $Output).Length / 1KB), $pm, $vw) -ForegroundColor Green
