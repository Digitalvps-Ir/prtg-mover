<#
    PrtgMover.Remote.ps1
    ---------------------
    Functions executed *on the source / target server* inside a PowerShell remoting
    session opened by the manager. The whole file is shipped with every call, so it
    must stay self-contained (no module imports, no top-level param block) and
    compatible with Windows PowerShell 5.1.

    Every public function streams objects back to the manager:
      PmType = 'log'      -> a log line          (Level, Message)
      PmType = 'progress' -> a progress update   (Percent, Step)
      PmType = 'result'   -> the final result object
#>

$PmCoreService  = 'PRTGCoreService'
$PmProbeService = 'PRTGProbeService'

# Program-directory sub folders that may contain user customisations.
$PmProgramFolders = @(
    'Custom Sensors', 'Notifications', 'lookups\custom', 'devicetemplates',
    'MIB', 'snmplibs', 'cert', 'webroot\mapobjects', 'webroot\mapbackground',
    'webroot\mapicons', 'webroot\custom'
)

# ---------------------------------------------------------------- output helpers

function Write-PmLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP')][string]$Level = 'INFO')
    [pscustomobject]@{ PmType = 'log'; Level = $Level; Message = $Message; Time = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME }
}

function Write-PmProgress {
    param([int]$Percent, [string]$Step)
    [pscustomobject]@{ PmType = 'progress'; Percent = $Percent; Step = $Step; Computer = $env:COMPUTERNAME }
}

function New-PmResult {
    param([hashtable]$Data)
    $Data['PmType'] = 'result'
    [pscustomobject]$Data
}

# ---------------------------------------------------------------- generic helpers

function Invoke-PmRobocopy {
    <# Copies a directory tree. Returns the robocopy exit code (0-7 = success). #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [switch]$Mirror
    )
    if (-not (Test-Path -LiteralPath $Source)) { return -1 }
    $rcArgs = @($Source.TrimEnd('\'), $Destination.TrimEnd('\'), '/COPY:DAT', '/DCOPY:DAT', '/R:2', '/W:2', '/MT:8', '/XJ', '/NP', '/NFL', '/NDL', '/NJH', '/NJS')
    if ($Mirror) { $rcArgs += '/MIR' } else { $rcArgs += '/E' }
    if ($ExcludeDirs.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
    & robocopy.exe @rcArgs | Out-Null
    return $LASTEXITCODE
}

function Test-PmRobocopyOk { param([int]$Code) return ($Code -ge 0 -and $Code -lt 8) }

function Get-PmDirectorySize {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [int64]$sum } else { return 0 }
}

function Get-PmFileEncoding {
    <# Detects the BOM of a text file; files without BOM are treated as ANSI (what RAS writes). #>
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return New-Object Text.UTF8Encoding($true) }
    return [Text.Encoding]::Default
}

function Get-PmUserProfiles {
    <# Real (non-special) local user profiles: name + path. #>
    Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
        ForEach-Object { [pscustomobject]@{ Name = (Split-Path $_.LocalPath -Leaf); Path = $_.LocalPath } }
}

function Initialize-PmTls {
    if (-not ('PmTrustAllPolicy' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class PmTrustAllPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object PmTrustAllPolicy
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
}

# ---------------------------------------------------------------- RAS phonebook (Windows VPN)

function Get-PmPbkEntries {
    <# Parses a rasphone.pbk file into ordered entries: @{ Name; Lines } #>
    param([Parameter(Mandatory)][string]$Path)
    $entries = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) { return , $entries }
    $enc = Get-PmFileEncoding -Path $Path
    $current = $null
    foreach ($line in [IO.File]::ReadAllLines($Path, $enc)) {
        if ($line -match '^\s*\[(.+)\]\s*$') {
            $current = @{ Name = $Matches[1]; Lines = New-Object System.Collections.ArrayList }
            [void]$entries.Add($current)
        }
        if ($current) { [void]$current.Lines.Add($line) }
    }
    return , $entries
}

function Merge-PmPbk {
    <#
        Appends entries from $SourcePath to $TargetPath that do not exist yet
        (matched by entry name, case-insensitive). Existing entries are never touched.
        Returns the names of the added entries.
    #>
    param([Parameter(Mandatory)][string]$SourcePath, [Parameter(Mandatory)][string]$TargetPath)
    $added = New-Object System.Collections.ArrayList
    $src = Get-PmPbkEntries -Path $SourcePath
    if ($src.Count -eq 0) { return [string[]]@() }

    $dir = Split-Path $TargetPath -Parent
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }

    $existing = @{}
    $enc = [Text.Encoding]::Default
    if (Test-Path -LiteralPath $TargetPath) {
        $enc = Get-PmFileEncoding -Path $TargetPath
        foreach ($e in (Get-PmPbkEntries -Path $TargetPath)) { $existing[$e.Name.ToLowerInvariant()] = $true }
        Copy-Item -LiteralPath $TargetPath -Destination ("{0}.pre-restore-{1}" -f $TargetPath, (Get-Date -Format 'yyyyMMdd-HHmmss')) -Force
    }

    $sb = New-Object System.Text.StringBuilder
    foreach ($e in $src) {
        if ($existing.ContainsKey($e.Name.ToLowerInvariant())) { continue }
        [void]$sb.AppendLine('')
        foreach ($l in $e.Lines) { [void]$sb.AppendLine($l) }
        [void]$added.Add($e.Name)
    }
    if ($added.Count -gt 0) {
        if (Test-Path -LiteralPath $TargetPath) { [IO.File]::AppendAllText($TargetPath, $sb.ToString(), $enc) }
        else { [IO.File]::WriteAllText($TargetPath, $sb.ToString().TrimStart(), $enc) }
    }
    return [string[]]$added.ToArray()
}

function Invoke-PmReg {
    <# Runs reg.exe without letting its stderr chatter turn into PowerShell errors. Returns the exit code. #>
    param([Parameter(Mandatory)][ValidateSet('export', 'import')][string]$Verb, [Parameter(Mandatory)][string]$File, [string]$Key)
    $argLine = if ($Verb -eq 'export') { "export `"$Key`" `"$File`" /y" } else { "import `"$File`"" }
    $p = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\reg.exe') -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
    return $p.ExitCode
}

# ---------------------------------------------------------------- PRTG discovery / control

function Get-PmPrtgInfo {
    $info = [ordered]@{
        Installed = $false; Version = $null; ProgramPath = $null; DataPath = $null
        RegistryKeys = @(); CoreStatus = $null; ProbeStatus = $null; ListenPorts = @()
    }
    $svc = Get-CimInstance Win32_Service -Filter "Name='$PmCoreService'" -ErrorAction SilentlyContinue
    if ($svc) {
        $info.Installed = $true
        $exe = $svc.PathName
        if ($exe -match '^"([^"]+)"') { $exe = $Matches[1] } elseif ($exe -match '^(.+?\.exe)') { $exe = $Matches[1] }
        $info.ProgramPath = Split-Path $exe -Parent
        if (Test-Path -LiteralPath $exe) { $info.Version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion }
        $info.CoreStatus = [string]$svc.State
    }
    $probe = Get-Service -Name $PmProbeService -ErrorAction SilentlyContinue
    if ($probe) { $info.ProbeStatus = [string]$probe.Status }

    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Paessler', 'HKLM:\SOFTWARE\Paessler') {
        if (Test-Path $k) { $info.RegistryKeys += $k }
    }
    $dp = $null
    foreach ($core in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Core', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Core') {
        if (-not $dp -and (Test-Path $core)) { $dp = (Get-ItemProperty -Path $core -ErrorAction SilentlyContinue).Datapath }
    }
    if (-not $dp) { $dp = Join-Path $env:ProgramData 'Paessler\PRTG Network Monitor' }
    $info.DataPath = $dp.TrimEnd('\')

    $proc = Get-Process -Name 'PRTG Server' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $info.ListenPorts = @(Get-NetTCPConnection -State Listen -OwningProcess $proc.Id -ErrorAction SilentlyContinue |
                Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
    }
    return [pscustomobject]$info
}

function Stop-PmPrtgServices {
    param([int]$TimeoutMinutes = 15)
    foreach ($name in $PmProbeService, $PmCoreService) {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Stopped') {
            Stop-Service -Name $name -Force -ErrorAction Stop
            $s.WaitForStatus('Stopped', [TimeSpan]::FromMinutes($TimeoutMinutes))
        }
    }
    # The core writes the configuration on shutdown; make sure the process is really gone.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Process -Name 'PRTG Server', 'PRTG Probe' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
}

function Start-PmPrtgServices {
    foreach ($name in $PmCoreService, $PmProbeService) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            Set-Service -Name $name -StartupType Automatic
            Start-Service -Name $name -ErrorAction Stop
        }
    }
}

function Test-PmPrtgWeb {
    <# Returns the first URL that answers with any HTTP response, or $null. #>
    param([int[]]$Ports)
    Initialize-PmTls
    $candidates = @()
    foreach ($p in $Ports) { $candidates += "https://localhost:$p/"; $candidates += "http://localhost:$p/" }
    foreach ($url in $candidates) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            return "$url (HTTP $($r.StatusCode))"
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { return "$url (HTTP $([int]$_.Exception.Response.StatusCode))" }
        } catch { }
    }
    return $null
}

function Wait-PmPrtgHealthy {
    <#
        Brings PRTG fully up and proves it: both services Running, the core answering
        HTTP(S), and everything still running after a stability window. A service that
        stops/crashes during start-up is restarted (up to $MaxRestarts times).
        Emits log records; the last object is PmType='health'.
    #>
    param([int]$TimeoutMinutes = 15, [int[]]$PreferredPorts = @(), [int]$StableSeconds = 45, [int]$MaxRestarts = 2)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $restarts = 0; $url = $null; $healthy = $false; $msg = ''
    foreach ($n in $PmCoreService, $PmProbeService) {
        if (Get-Service -Name $n -ErrorAction SilentlyContinue) { Set-Service -Name $n -StartupType Automatic }
    }
    while ((Get-Date) -lt $deadline -and -not $healthy) {
        foreach ($n in $PmCoreService, $PmProbeService) {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq 'Stopped') {
                if ($restarts -ge ($MaxRestarts + 2)) { continue }   # +2: the initial starts
                $restarts++
                Write-PmLog "Starting service $n (attempt $restarts)..."
                try { Start-Service -Name $n -ErrorAction Stop } catch { Write-PmLog "Start-Service $n failed: $($_.Exception.Message)" 'WARN' }
            }
        }
        Start-Sleep -Seconds 10
        $info = Get-PmPrtgInfo
        if ($info.CoreStatus -ne 'Running' -or ($info.ProbeStatus -and $info.ProbeStatus -ne 'Running')) { $msg = "core=$($info.CoreStatus) probe=$($info.ProbeStatus)"; continue }
        $ports = @($info.ListenPorts) + @($PreferredPorts) + @(443, 80, 8443, 8080) | Where-Object { $_ } | Select-Object -Unique
        $url = Test-PmPrtgWeb -Ports $ports
        if (-not $url) { $msg = 'services running, web interface not answering yet'; continue }
        Write-PmLog "Web interface answers at $url - verifying stability for $StableSeconds s..."
        Start-Sleep -Seconds $StableSeconds
        $info = Get-PmPrtgInfo
        if ($info.CoreStatus -eq 'Running' -and (-not $info.ProbeStatus -or $info.ProbeStatus -eq 'Running') -and (Test-PmPrtgWeb -Ports $ports)) { $healthy = $true }
        else { $msg = "became unstable (core=$($info.CoreStatus) probe=$($info.ProbeStatus))"; Write-PmLog "PRTG $msg - retrying." 'WARN' }
    }
    $final = Get-PmPrtgInfo
    [pscustomobject]@{ PmType = 'health'; Healthy = $healthy; Url = $url; Core = $final.CoreStatus; Probe = $final.ProbeStatus; Message = $msg; Version = $final.Version }
}

function Invoke-PmHealthCheck {
    <# Runs Wait-PmPrtgHealthy, forwarding its logs, and returns the health object via $Box.Health. #>
    param([hashtable]$Box, [int]$TimeoutMinutes = 15, [int[]]$PreferredPorts = @())
    Wait-PmPrtgHealthy -TimeoutMinutes $TimeoutMinutes -PreferredPorts $PreferredPorts | ForEach-Object {
        if ($_.PmType -eq 'health') { $Box.Health = $_ } else { $_ }
    }
}

# ---------------------------------------------------------------- configuration statistics

function Get-PmPrtgConfigStats {
    <#
        Streams PRTG Configuration.dat (XML) and counts the main object types. Used to show
        what is being moved (devices, sensors, notification templates, triggers, users,
        schedules, maps, reports, libraries) and to compare source and target.
        Read-only, opened with FileShare.ReadWrite so a running PRTG is not disturbed.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $names = [ordered]@{ probenode = 'probes'; group = 'groups'; device = 'devices'; sensor = 'sensors'; notification = 'notifications'; trigger = 'triggers'
        user = 'users'; usergroup = 'user groups'; schedule = 'schedules'; map = 'maps'; report = 'reports'; library = 'libraries'; dependency = 'dependencies' }
    $count = @{}
    foreach ($k in $names.Keys) { $count[$k] = 0 }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
        $settings.IgnoreComments = $true; $settings.IgnoreWhitespace = $true
        $reader = [Xml.XmlReader]::Create($fs, $settings)
        try {
            while ($reader.Read()) {
                if ($reader.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
                $n = $reader.LocalName.ToLowerInvariant()
                if ($count.ContainsKey($n)) { $count[$n]++ }
                elseif ($n -like '*trigger' -and $n -ne 'triggers') { $count['trigger']++ }
            }
        } finally { $reader.Dispose() }
    } catch { return "unreadable ($($_.Exception.Message))" } finally { $fs.Dispose() }
    return (($names.Keys | Where-Object { $count[$_] -gt 0 } | ForEach-Object { "$($names[$_])=$($count[$_])" }) -join ', ')
}

# ---------------------------------------------------------------- VSS snapshots (no-touch backups)

function New-PmShadowCopy {
    <# Creates a VSS snapshot of the volume holding $Path and links it to a folder. Server OS only. #>
    param([Parameter(Mandatory)][string]$Path)
    $volume = (Split-Path $Path -Qualifier) + '\'
    $r = (Get-WmiObject -List Win32_ShadowCopy).Create($volume, 'ClientAccessible')
    if ($r.ReturnValue -ne 0) { throw "VSS snapshot of $volume failed (code $($r.ReturnValue))." }
    $sc = Get-WmiObject Win32_ShadowCopy -Filter "ID='$($r.ShadowID)'"
    $link = Join-Path $env:SystemDrive ('PrtgMoverVss_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    cmd.exe /c "mklink /d `"$link`" `"$($sc.DeviceObject)\`"" | Out-Null
    if (-not (Test-Path -LiteralPath $link)) { $sc.Delete(); throw 'Could not mount the VSS snapshot.' }
    [pscustomobject]@{ Id = $sc.ID; Link = $link; Volume = $volume }
}

function Remove-PmShadowCopy {
    param($Shadow)
    if (-not $Shadow) { return }
    cmd.exe /c "rmdir `"$($Shadow.Link)`"" | Out-Null
    $sc = Get-WmiObject Win32_ShadowCopy -Filter "ID='$($Shadow.Id)'"
    if ($sc) { $sc.Delete() }
}

# ---------------------------------------------------------------- PRTG license

function Get-PmLicenseValues {
    <# All registry values below the Paessler keys whose name contains "licen" (name, path, kind, value). #>
    $out = @()
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\Paessler', 'HKLM:\SOFTWARE\Paessler') {
        if (-not (Test-Path $root)) { continue }
        $keys = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue)
        foreach ($k in $keys) {
            foreach ($name in $k.GetValueNames()) {
                if ($name -match 'licen') {
                    $out += [pscustomobject]@{ Path = $k.PSPath; Name = $name; Kind = $k.GetValueKind($name); Value = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames') }
                }
            }
        }
    }
    return $out
}

function Get-PmLicenseFiles {
    param([string]$DataPath)
    if (-not (Test-Path -LiteralPath $DataPath)) { return @() }
    @(Get-ChildItem -LiteralPath $DataPath -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'licen' })
}

# ---------------------------------------------------------------- firewall

function Set-PmPrtgFirewall {
    <# Opens inbound TCP for the PRTG web ports and the remote-probe port (23560). #>
    param([int[]]$Ports)
    $ports = @($Ports) + 23560 | Where-Object { $_ } | Select-Object -Unique | Sort-Object
    $name = 'PRTG Mover - PRTG Core (web + probes)'
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $ports -Action Allow -Profile Any | Out-Null
    return $ports
}

# ---------------------------------------------------------------- system info (Test)

function Get-PmSystemInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    $vpn = @()
    try { $vpn = @(Get-VpnConnection -AllUserConnection -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Server = $_.ServerAddress; Type = [string]$_.TunnelType; Status = [string]$_.ConnectionStatus } }) } catch { }
    $prtg = Get-PmPrtgInfo
    $dataSize = 0; $stats = $null
    if ($prtg.Installed) {
        $dataSize = Get-PmDirectorySize -Path $prtg.DataPath
        $stats = Get-PmPrtgConfigStats -Path (Join-Path $prtg.DataPath 'PRTG Configuration.dat')
    }
    $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | ForEach-Object {
            [pscustomobject]@{ Drive = $_.DeviceID; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) } })

    New-PmResult @{
        Computer     = $env:COMPUTERNAME
        OS           = $os.Caption
        OSVersion    = $os.Version
        IsAdmin      = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        User         = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        Prtg         = $prtg
        PrtgDataGB   = [math]::Round($dataSize / 1GB, 2)
        PrtgConfigStats = $stats
        VpnAllUsers  = $vpn
        Profiles     = @(Get-PmUserProfiles | Select-Object -ExpandProperty Name)
        Disks        = $disks
        SystemDrive  = $env:SystemDrive
        RdpPort      = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).PortNumber
        PSVersion    = $PSVersionTable.PSVersion.ToString()
    }
}

# ---------------------------------------------------------------- BACKUP (runs on source)

function Invoke-PmRemoteBackup {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$WorkRoot,
        [bool]$IncludePrtg = $true,
        [bool]$IncludeHistory = $true,
        [bool]$IncludeVpn = $true,
        [bool]$IncludeDesktop = $true,
        [string[]]$ExtraPaths = @(),
        [ValidateSet('Restart', 'KeepStopped', 'Disable')][string]$SourceAfter = 'Restart',
        [bool]$NoTouch = $false,
        [int]$HealthTimeoutMinutes = 15
    )
    $ErrorActionPreference = 'Stop'
    $sourceHealth = $null
    if (-not $WorkRoot) { $WorkRoot = Join-Path $env:SystemDrive 'PrtgMover' }
    $stage = Join-Path $WorkRoot "staging\$JobId"
    $outDir = Join-Path $WorkRoot 'out'
    New-Item -ItemType Directory -Force -Path $stage, $outDir | Out-Null

    $manifest = [ordered]@{
        tool = 'prtg-mover'; formatVersion = 1; jobId = $JobId
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = [ordered]@{ computer = $env:COMPUTERNAME; os = (Get-CimInstance Win32_OperatingSystem).Caption }
        prtg = [ordered]@{ included = $false }
        vpn = [ordered]@{ included = $false; allUsers = @(); users = @{} }
        desktop = [ordered]@{ included = $false; users = @() }
        extra = @()
        warnings = @()
    }

    Write-PmLog "Backup started on $env:COMPUTERNAME (staging: $stage)" 'STEP'

    # ---- PRTG
    if ($IncludePrtg) {
        Write-PmProgress 5 'PRTG: discovering installation'
        $prtg = Get-PmPrtgInfo
        if (-not $prtg.Installed) {
            Write-PmLog 'PRTG core service not found - skipping PRTG backup.' 'WARN'
            $manifest.warnings += 'PRTG not installed on source'
        } else {
            Write-PmLog "PRTG $($prtg.Version) found. Program: $($prtg.ProgramPath) | Data: $($prtg.DataPath)"
            $wasRunning = ($prtg.CoreStatus -eq 'Running')
            $shadow = $null
            $dataSource = $prtg.DataPath
            if ($NoTouch) {
                Write-PmLog 'NO-TOUCH mode: PRTG keeps running on the source, nothing is stopped, changed or deleted.' 'STEP'
                try {
                    $shadow = New-PmShadowCopy -Path $prtg.DataPath
                    $dataSource = Join-Path $shadow.Link $prtg.DataPath.Substring($shadow.Volume.Length)
                    Write-PmLog "Consistent VSS snapshot of $($shadow.Volume) created - copying from the snapshot." 'OK'
                } catch {
                    Write-PmLog "VSS snapshot not available ($($_.Exception.Message)) - copying live files. PRTG saves its configuration periodically; files locked at this moment are skipped." 'WARN'
                    $manifest.warnings += 'No-touch backup without VSS snapshot (live copy)'
                }
            } else {
                Write-PmProgress 10 'PRTG: stopping services'
                Write-PmLog 'Stopping PRTG services (the core flushes its configuration to disk)...' 'STEP'
                Stop-PmPrtgServices
                Write-PmLog 'PRTG services stopped.' 'OK'
            }

            try {
                Write-PmProgress 20 'PRTG: copying data folder'
                $exclude = @()
                if (-not $IncludeHistory) { $exclude = @((Join-Path $dataSource 'Monitoring Database'), (Join-Path $dataSource 'Logs')) }
                $code = Invoke-PmRobocopy -Source $dataSource -Destination (Join-Path $stage 'prtg\data') -ExcludeDirs $exclude
                if (-not (Test-PmRobocopyOk $code)) { throw "robocopy of PRTG data failed with exit code $code" }
                $cfg = Join-Path $stage 'prtg\data\PRTG Configuration.dat'
                if (-not (Test-Path -LiteralPath $cfg)) { throw "'PRTG Configuration.dat' is missing from the copied data folder - aborting (backup would be unusable)." }
                $cfgInfo = Get-Item -LiteralPath $cfg
                $cfgHash = (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash
                $cfgStats = Get-PmPrtgConfigStats -Path $cfg
                Write-PmLog "Configuration content (all rules, notifications, triggers, users... are inside this file): $cfgStats" 'OK'
                Write-PmLog ("Data folder copied ({0:N2} GB). PRTG Configuration.dat: {1:N1} MB, saved {2}." -f ((Get-PmDirectorySize (Join-Path $stage 'prtg\data')) / 1GB), ($cfgInfo.Length / 1MB), $cfgInfo.LastWriteTime) 'OK'

                Write-PmProgress 35 'PRTG: copying customisations'
                $copiedFolders = @()
                foreach ($f in $PmProgramFolders) {
                    $srcF = Join-Path $prtg.ProgramPath $f
                    if (Test-Path -LiteralPath $srcF) {
                        $code = Invoke-PmRobocopy -Source $srcF -Destination (Join-Path $stage "prtg\program\$f")
                        if (Test-PmRobocopyOk $code) { $copiedFolders += $f } else { Write-PmLog "Could not copy '$f' (robocopy $code)" 'WARN' }
                    }
                }
                Write-PmLog "Program customisation folders: $($copiedFolders -join ', ')" 'OK'

                Write-PmProgress 40 'PRTG: exporting registry'
                $regDir = Join-Path $stage 'prtg\registry'
                New-Item -ItemType Directory -Force -Path $regDir | Out-Null
                $regFiles = @()
                foreach ($k in $prtg.RegistryKeys) {
                    $native = $k -replace '^HKLM:\\', 'HKLM\'
                    $file = Join-Path $regDir (($native -replace '[\\: ]', '_') + '.reg')
                    if ((Invoke-PmReg -Verb export -Key $native -File $file) -eq 0) { $regFiles += (Split-Path $file -Leaf) } else { Write-PmLog "reg export failed for $native" 'WARN' }
                }
                Write-PmLog "Registry exported: $($regFiles -join ', ')" 'OK'

                $licNames = @(Get-PmLicenseValues | ForEach-Object { $_.Name } | Select-Object -Unique)
                $licFiles = @(Get-PmLicenseFiles -DataPath $prtg.DataPath | ForEach-Object { $_.Name })
                Write-PmLog ("License information found: {0} registry value(s){1}." -f $licNames.Count, $(if ($licFiles.Count) { ", files: $($licFiles -join ', ')" } else { '' }))

                $manifest.prtg = [ordered]@{
                    included = $true; version = $prtg.Version; dataPath = $prtg.DataPath; programPath = $prtg.ProgramPath
                    includeHistory = $IncludeHistory; programFolders = $copiedFolders; registryFiles = $regFiles
                    listenPorts = $prtg.ListenPorts; configSha256 = $cfgHash; configSize = $cfgInfo.Length; configStats = $cfgStats
                    licenseValueNames = $licNames; licenseFiles = $licFiles
                    consistency = $(if ($NoTouch) { if ($shadow) { 'vss-snapshot' } else { 'live-copy' } } else { 'services-stopped' })
                }
            } finally {
                if ($shadow) { Remove-PmShadowCopy -Shadow $shadow; Write-PmLog 'VSS snapshot removed.' }
                if ($NoTouch) {
                    Write-PmLog 'Source untouched - PRTG kept running the whole time.' 'OK'
                } else {
                    switch ($SourceAfter) {
                        'Restart' {
                            if (-not $wasRunning) {
                                Write-PmLog 'PRTG was not running before the backup - leaving it stopped.' 'WARN'
                            } else {
                                Write-PmProgress 72 'PRTG: restarting source and verifying health'
                                Write-PmLog 'Starting PRTG on the source and waiting until it is FULLY up (services + web interface + stability)...' 'STEP'
                                $box = @{}
                                Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
                                $sourceHealth = $box.Health
                                if ($sourceHealth.Healthy) { Write-PmLog "Source PRTG is fully up again: $($sourceHealth.Url)" 'OK' }
                                else { Write-PmLog "Source PRTG did NOT come back up correctly ($($sourceHealth.Message)). Check the core log on the source!" 'ERROR' }
                            }
                        }
                        'KeepStopped' { Write-PmLog 'Source PRTG services left STOPPED (migration mode).' 'WARN' }
                        'Disable' {
                            foreach ($n in $PmCoreService, $PmProbeService) { Set-Service -Name $n -StartupType Disabled -ErrorAction SilentlyContinue }
                            Write-PmLog 'Source PRTG services STOPPED and DISABLED (migration mode).' 'WARN'
                        }
                    }
                }
            }
        }
    }

    # ---- Windows VPN (RAS phonebooks)
    if ($IncludeVpn) {
        Write-PmProgress 50 'VPN: exporting Windows VPN connections'
        $allPbkDir = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk'
        $vpnStage = Join-Path $stage 'vpn'
        New-Item -ItemType Directory -Force -Path (Join-Path $vpnStage 'allusers'), (Join-Path $vpnStage 'users') | Out-Null
        foreach ($pbk in (Get-ChildItem -LiteralPath $allPbkDir -Filter '*.pbk' -File -ErrorAction SilentlyContinue)) {
            Copy-Item -LiteralPath $pbk.FullName -Destination (Join-Path $vpnStage 'allusers') -Force
            $manifest.vpn.allUsers += @(Get-PmPbkEntries -Path $pbk.FullName | ForEach-Object { $_.Name })
        }
        foreach ($prof in (Get-PmUserProfiles)) {
            $userPbkDir = Join-Path $prof.Path 'AppData\Roaming\Microsoft\Network\Connections\Pbk'
            $files = @(Get-ChildItem -LiteralPath $userPbkDir -Filter '*.pbk' -File -ErrorAction SilentlyContinue)
            if ($files.Count -gt 0) {
                $dst = Join-Path $vpnStage "users\$($prof.Name)"
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                $names = @()
                foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $dst -Force; $names += @(Get-PmPbkEntries -Path $f.FullName | ForEach-Object { $_.Name }) }
                $manifest.vpn.users[$prof.Name] = $names
            }
        }
        try {
            Get-VpnConnection -AllUserConnection -ErrorAction Stop | Select-Object Name, ServerAddress, TunnelType, AuthenticationMethod, EncryptionLevel, SplitTunneling, RememberCredential |
                ConvertTo-Json -Depth 4 | Set-Content -Path (Join-Path $vpnStage 'vpn-connections.json') -Encoding UTF8
        } catch { }
        $manifest.vpn.included = $true
        $userCount = ($manifest.vpn.users.Values | ForEach-Object { $_ } | Measure-Object).Count
        Write-PmLog "VPN: $($manifest.vpn.allUsers.Count) all-user and $userCount per-user connection(s) exported." 'OK'
        Write-PmLog 'Note: saved VPN passwords / machine certificates are protected by Windows (DPAPI) and are NOT migrated.' 'WARN'
    }

    # ---- Desktop files
    if ($IncludeDesktop) {
        Write-PmProgress 60 'Desktop: copying user desktops'
        $deskStage = Join-Path $stage 'desktop'
        $sources = @()
        foreach ($prof in (Get-PmUserProfiles)) { $sources += [pscustomobject]@{ Name = $prof.Name; Path = (Join-Path $prof.Path 'Desktop') } }
        $sources += [pscustomobject]@{ Name = 'Public'; Path = (Join-Path $env:PUBLIC 'Desktop') }
        foreach ($s in $sources) {
            if (-not (Test-Path -LiteralPath $s.Path)) { continue }
            if (-not (Get-ChildItem -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) { continue }
            $code = Invoke-PmRobocopy -Source $s.Path -Destination (Join-Path $deskStage $s.Name)
            if (Test-PmRobocopyOk $code) { $manifest.desktop.users += $s.Name } else { Write-PmLog "Desktop copy failed for $($s.Name) (robocopy $code)" 'WARN' }
        }
        $manifest.desktop.included = $true
        Write-PmLog "Desktop files copied for: $($manifest.desktop.users -join ', ')" 'OK'
    }

    # ---- Extra paths
    $i = 0
    foreach ($p in $ExtraPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $i++
        $dst = Join-Path $stage "extra\$i"
        if (Test-Path -LiteralPath $p -PathType Container) {
            $code = Invoke-PmRobocopy -Source $p -Destination $dst
            if (Test-PmRobocopyOk $code) { $manifest.extra += [ordered]@{ index = $i; path = $p; kind = 'dir' } }
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item -LiteralPath $p -Destination $dst -Force
            $manifest.extra += [ordered]@{ index = $i; path = $p; kind = 'file' }
        } else {
            Write-PmLog "Extra path not found: $p" 'WARN'
            continue
        }
        Write-PmLog "Extra path included: $p" 'OK'
    }

    # ---- Manifest + archive
    Write-PmProgress 70 'Packaging: compressing backup'
    $manifest.stagingBytes = Get-PmDirectorySize $stage
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $stage 'manifest.json') -Encoding UTF8
    $zipName = 'PRTG_{0}_{1}.zip' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $zipPath = Join-Path $outDir $zipName
    Write-PmLog "Compressing to $zipPath ..." 'STEP'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    $zip = Get-Item -LiteralPath $zipPath
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    Write-PmLog ("Package ready: {0} ({1:N2} MB, SHA256 {2})" -f $zipName, ($zip.Length / 1MB), $hash) 'OK'
    Write-PmProgress 80 'Packaging done'

    New-PmResult @{
        ZipPath = $zipPath; ZipName = $zipName; Size = $zip.Length; Sha256 = $hash; Manifest = ($manifest | ConvertTo-Json -Depth 8)
        SourceHealth = $sourceHealth
    }
}

# ---------------------------------------------------------------- RESTORE (runs on target)

function Invoke-PmRemoteRestore {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [Parameter(Mandatory)][string]$ZipPath,
        [string]$WorkRoot,
        [bool]$RestorePrtg = $true,
        [bool]$RestoreVpn = $true,
        [bool]$RestoreDesktop = $true,
        [bool]$RestoreExtra = $true,
        [string]$InstallerPath,
        [string]$InstallerArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART',
        [bool]$AllowDowngrade = $false,
        [bool]$StartServices = $true,
        [int]$HealthTimeoutMinutes = 15,
        [bool]$ConnectVpn = $false,
        [bool]$RemovePackage = $true,
        [bool]$CopyLicense = $true,
        [bool]$OpenFirewall = $true,
        [string]$ExpectedSha256
    )
    $ErrorActionPreference = 'Stop'
    if (-not $WorkRoot) { $WorkRoot = Join-Path $env:SystemDrive 'PrtgMover' }
    $stage = Join-Path $WorkRoot "restore\$JobId"
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $report = [ordered]@{ Computer = $env:COMPUTERNAME; Prtg = 'skipped'; License = 'skipped'; Vpn = 'skipped'; Desktop = 'skipped'; Extra = 'skipped'; WebUrl = $null; Version = $null; Errors = @() }

    Write-PmLog "Restore started on $env:COMPUTERNAME" 'STEP'

    # ---- integrity + disk space pre-checks
    if ($ExpectedSha256) {
        Write-PmProgress 2 'Verifying package checksum'
        $h = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
        if ($h -ne $ExpectedSha256) { throw "Package checksum mismatch on target (expected $ExpectedSha256, got $h) - transfer corrupted." }
        Write-PmLog 'Package SHA-256 verified on target.' 'OK'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $need = 0
    $zr = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { foreach ($e in $zr.Entries) { $need += $e.Length } } finally { $zr.Dispose() }
    $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f (Split-Path $WorkRoot -Qualifier))
    $required = [int64]($need * 2 + 1GB)   # extracted staging + restored data + margin
    if ($drive -and $drive.FreeSpace -lt $required) {
        throw ("Not enough free space on {0}: {1:N1} GB free, {2:N1} GB required." -f $drive.DeviceID, ($drive.FreeSpace / 1GB), ($required / 1GB))
    }
    if ($drive) { Write-PmLog ("Disk space OK: {0:N1} GB free, ~{1:N1} GB needed." -f ($drive.FreeSpace / 1GB), ($required / 1GB)) 'OK' }

    Write-PmProgress 5 'Extracting package'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $stage)
    $manifest = Get-Content -LiteralPath (Join-Path $stage 'manifest.json') -Raw | ConvertFrom-Json
    Write-PmLog "Package from $($manifest.source.computer) created $($manifest.createdUtc)" 'OK'

    # ---- PRTG
    if ($RestorePrtg -and $manifest.prtg.included) {
        try {
            Write-PmProgress 15 'PRTG: checking installation'
            $prtg = Get-PmPrtgInfo
            if (-not $prtg.Installed) {
                if (-not $InstallerPath) { throw 'PRTG is not installed on this server and no installer was supplied. Install the same PRTG version (or upload the installer in the dashboard) and run the restore again.' }
                $exe = $InstallerPath
                if ($InstallerPath -like '*.zip') {
                    $instDir = Join-Path $WorkRoot "installer\$JobId"
                    [IO.Compression.ZipFile]::ExtractToDirectory($InstallerPath, $instDir)
                    $exe = (Get-ChildItem -LiteralPath $instDir -Filter '*.exe' -Recurse | Select-Object -First 1).FullName
                }
                Write-PmLog "Installing PRTG silently: $exe $InstallerArgs (this can take 10+ minutes)" 'STEP'
                $proc = Start-Process -FilePath $exe -ArgumentList $InstallerArgs -Wait -PassThru
                if ($proc.ExitCode -ne 0) { throw "PRTG installer exited with code $($proc.ExitCode)" }
                $prtg = Get-PmPrtgInfo
                if (-not $prtg.Installed) { throw 'PRTG installer finished but PRTGCoreService is still missing.' }
                Write-PmLog "PRTG $($prtg.Version) installed." 'OK'
            }

            if ($manifest.prtg.version -and $prtg.Version) {
                $srcV = [version]($manifest.prtg.version -replace '[^\d\.]', '')
                $dstV = [version]($prtg.Version -replace '[^\d\.]', '')
                if ($dstV -lt $srcV) {
                    $msg = "Target PRTG $dstV is OLDER than source $srcV - PRTG cannot open a newer configuration."
                    if (-not $AllowDowngrade) { throw "$msg Upgrade the target first (or enable 'Allow downgrade')." }
                    Write-PmLog $msg 'WARN'
                } elseif ($dstV -gt $srcV) {
                    Write-PmLog "Target PRTG $dstV is newer than source $srcV - configuration will be upgraded on first start." 'WARN'
                } else { Write-PmLog "PRTG versions match ($dstV)." 'OK' }
            }

            # Remember the target's own license before anything is overwritten.
            $targetLicValues = @(Get-PmLicenseValues)
            $licKeep = Join-Path $WorkRoot "license-keep\$stamp"
            $targetLicFiles = @(Get-PmLicenseFiles -DataPath $prtg.DataPath)
            if ($targetLicFiles.Count) {
                New-Item -ItemType Directory -Force -Path $licKeep | Out-Null
                $targetLicFiles | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $licKeep -Force }
            }

            Write-PmProgress 25 'PRTG: stopping target services'
            Stop-PmPrtgServices
            Write-PmLog 'Target PRTG services stopped.' 'OK'

            # Data path: keep the source path when the drive exists here, otherwise use the target default.
            $srcData = [string]$manifest.prtg.dataPath
            $dataPath = $prtg.DataPath
            if ($srcData) {
                $qual = Split-Path $srcData -Qualifier -ErrorAction SilentlyContinue
                if ($qual -and (Test-Path "$qual\")) { $dataPath = $srcData }
                else { Write-PmLog "Drive $qual does not exist on target - using $dataPath instead." 'WARN' }
            }

            Write-PmProgress 35 'PRTG: backing up current target state'
            $regBackup = Join-Path $WorkRoot "rollback\$stamp"
            New-Item -ItemType Directory -Force -Path $regBackup | Out-Null
            foreach ($k in $prtg.RegistryKeys) {
                $native = $k -replace '^HKLM:\\', 'HKLM\'
                [void](Invoke-PmReg -Verb export -Key $native -File (Join-Path $regBackup (($native -replace '[\\: ]', '_') + '.reg')))
            }
            if (Test-Path -LiteralPath $dataPath) {
                $old = "$dataPath.pre-restore-$stamp"
                try { Rename-Item -LiteralPath $dataPath -NewName (Split-Path $old -Leaf); Write-PmLog "Existing data folder kept as $old" }
                catch { Invoke-PmRobocopy -Source $dataPath -Destination $old | Out-Null; Write-PmLog "Existing data folder copied to $old" }
            }
            Write-PmLog "Rollback copy of registry: $regBackup" 'OK'

            Write-PmProgress 45 'PRTG: restoring data folder'
            $code = Invoke-PmRobocopy -Source (Join-Path $stage 'prtg\data') -Destination $dataPath -Mirror
            if (-not (Test-PmRobocopyOk $code)) { throw "robocopy restore of data failed ($code)" }
            if ($manifest.prtg.configSha256) {
                $h = (Get-FileHash -LiteralPath (Join-Path $dataPath 'PRTG Configuration.dat') -Algorithm SHA256).Hash
                if ($h -ne $manifest.prtg.configSha256) { throw 'PRTG Configuration.dat on target does not match the source (checksum) - aborting.' }
                Write-PmLog 'PRTG Configuration.dat verified (SHA-256 identical to source).' 'OK'
                if ($manifest.prtg.configStats) {
                    $tStats = Get-PmPrtgConfigStats -Path (Join-Path $dataPath 'PRTG Configuration.dat')
                    Write-PmLog "Configuration on target: $tStats" $(if ($tStats -eq $manifest.prtg.configStats) { 'OK' } else { 'WARN' })
                }
            }
            Write-PmLog "Data folder restored to $dataPath" 'OK'

            Write-PmProgress 55 'PRTG: importing registry'
            foreach ($rf in @($manifest.prtg.registryFiles)) {
                $file = Join-Path $stage "prtg\registry\$rf"
                if (Test-Path -LiteralPath $file) {
                    if ((Invoke-PmReg -Verb import -File $file) -eq 0) { Write-PmLog "Registry imported: $rf" 'OK' } else { Write-PmLog "reg import failed: $rf" 'WARN' }
                }
            }
            if ($dataPath -ne $srcData) {
                foreach ($core in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Core', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Core') {
                    if (Test-Path $core) { Set-ItemProperty -Path $core -Name 'Datapath' -Value ($dataPath + '\') }
                }
                Write-PmLog "Registry Datapath adjusted to $dataPath" 'OK'
            }

            # ---- license
            if ($CopyLicense) {
                $report.License = 'copied-from-source'
                Write-PmLog ("Source license copied to target ({0} registry value(s){1})." -f @($manifest.prtg.licenseValueNames).Count, $(if (@($manifest.prtg.licenseFiles).Count) { ", files: $(@($manifest.prtg.licenseFiles) -join ', ')" } else { '' })) 'OK'
                Write-PmLog 'Remember: a PRTG license may only be active on ONE core - keep the source stopped.' 'WARN'
            } else {
                foreach ($v in @(Get-PmLicenseValues)) { Remove-ItemProperty -LiteralPath $v.Path -Name $v.Name -ErrorAction SilentlyContinue }
                foreach ($v in $targetLicValues) {
                    if (-not (Test-Path -LiteralPath $v.Path)) { New-Item -Path $v.Path -Force | Out-Null }
                    New-ItemProperty -LiteralPath $v.Path -Name $v.Name -Value $v.Value -PropertyType ([string]$v.Kind) -Force | Out-Null
                }
                Get-PmLicenseFiles -DataPath $dataPath | Remove-Item -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $licKeep) { Get-ChildItem -LiteralPath $licKeep -File | Copy-Item -Destination $dataPath -Force }
                $report.License = if ($targetLicValues.Count -or $targetLicFiles.Count) { 'kept-target-license' } else { 'none (enter a license on the target)' }
                Write-PmLog ("Source license NOT copied - target keeps its own license ({0} value(s) restored)." -f $targetLicValues.Count) 'OK'
            }

            Write-PmProgress 60 'PRTG: restoring customisations'
            $progStage = Join-Path $stage 'prtg\program'
            foreach ($f in @($manifest.prtg.programFolders)) {
                $code = Invoke-PmRobocopy -Source (Join-Path $progStage $f) -Destination (Join-Path $prtg.ProgramPath $f)
                if (-not (Test-PmRobocopyOk $code)) { Write-PmLog "Could not restore '$f' ($code)" 'WARN' }
            }
            Write-PmLog "Customisation folders restored: $(@($manifest.prtg.programFolders) -join ', ')" 'OK'

            if ($OpenFirewall) {
                $opened = Set-PmPrtgFirewall -Ports @($manifest.prtg.listenPorts)
                Write-PmLog "Firewall opened for PRTG (TCP $($opened -join ', '))." 'OK'
            }

            if ($StartServices) {
                Write-PmProgress 70 'PRTG: starting and verifying'
                Write-PmLog 'Starting PRTG and waiting until it is FULLY up (core + probe running, web interface answering, stable)...' 'STEP'
                $box = @{}
                Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($manifest.prtg.listenPorts)
                $health = $box.Health
                $report.Version = $health.Version
                if ($health.Healthy) {
                    $report.WebUrl = $health.Url
                    $report.Prtg = 'ok'
                    Write-PmLog "PRTG $($health.Version) is fully UP on $env:COMPUTERNAME : $($health.Url) (core $($health.Core), probe $($health.Probe))" 'OK'
                } else {
                    $report.Prtg = 'unhealthy'
                    $report.Errors += "PRTG did not come up completely within $HealthTimeoutMinutes min ($($health.Message))."
                    Write-PmLog "PRTG did NOT come up completely ($($health.Message)). See '$dataPath\Logs\core' on the target. Rollback data: $dataPath.pre-restore-$stamp" 'ERROR'
                }
            } else { $report.Prtg = 'restored-not-started' }
        } catch {
            $report.Prtg = 'failed'; $report.Errors += "PRTG: $_"
            Write-PmLog "PRTG restore failed: $_" 'ERROR'
        }
    }

    # ---- VPN
    if ($RestoreVpn -and $manifest.vpn.included) {
        Write-PmProgress 90 'VPN: importing connections'
        try {
            $added = @()
            $allDst = Join-Path $env:ProgramData 'Microsoft\Network\Connections\Pbk'
            foreach ($f in (Get-ChildItem -LiteralPath (Join-Path $stage 'vpn\allusers') -Filter '*.pbk' -File -ErrorAction SilentlyContinue)) {
                $added += @(Merge-PmPbk -SourcePath $f.FullName -TargetPath (Join-Path $allDst $f.Name))
            }
            $profiles = @{}
            foreach ($p in (Get-PmUserProfiles)) { $profiles[$p.Name.ToLowerInvariant()] = $p.Path }
            foreach ($uDir in (Get-ChildItem -LiteralPath (Join-Path $stage 'vpn\users') -Directory -ErrorAction SilentlyContinue)) {
                $key = $uDir.Name.ToLowerInvariant()
                foreach ($f in (Get-ChildItem -LiteralPath $uDir.FullName -Filter '*.pbk' -File)) {
                    if ($profiles.ContainsKey($key)) {
                        $added += @(Merge-PmPbk -SourcePath $f.FullName -TargetPath (Join-Path $profiles[$key] "AppData\Roaming\Microsoft\Network\Connections\Pbk\$($f.Name)"))
                    } else {
                        # No such profile on target: publish the per-user connections for all users instead.
                        $added += @(Merge-PmPbk -SourcePath $f.FullName -TargetPath (Join-Path $allDst $f.Name))
                        Write-PmLog "User '$($uDir.Name)' has no profile on target - its VPN connections were added for all users." 'WARN'
                    }
                }
            }
            Write-PmLog "VPN connections added: $(if ($added.Count) { $added -join ', ' } else { 'none (already present)' })" 'OK'
            if ($ConnectVpn) {
                foreach ($name in @($manifest.vpn.allUsers)) {
                    & rasdial.exe $name | Out-Null
                    if ($LASTEXITCODE -eq 0) { Write-PmLog "VPN '$name' connected." 'OK' } else { Write-PmLog "VPN '$name' could not connect (rasdial $LASTEXITCODE) - credentials must be entered once on the target." 'WARN' }
                }
            }
            $report.Vpn = 'ok'
        } catch { $report.Vpn = 'failed'; $report.Errors += "VPN: $_"; Write-PmLog "VPN restore failed: $_" 'ERROR' }
    }

    # ---- Desktop
    if ($RestoreDesktop -and $manifest.desktop.included) {
        Write-PmProgress 94 'Desktop: restoring files'
        try {
            $profiles = @{}
            foreach ($p in (Get-PmUserProfiles)) { $profiles[$p.Name.ToLowerInvariant()] = $p.Path }
            foreach ($uDir in (Get-ChildItem -LiteralPath (Join-Path $stage 'desktop') -Directory -ErrorAction SilentlyContinue)) {
                if ($uDir.Name -eq 'Public') { $dst = Join-Path $env:PUBLIC 'Desktop' }
                elseif ($profiles.ContainsKey($uDir.Name.ToLowerInvariant())) { $dst = Join-Path $profiles[$uDir.Name.ToLowerInvariant()] 'Desktop' }
                else {
                    $dst = Join-Path $env:SystemDrive "PrtgMover-Restored\Desktop\$($uDir.Name)"
                    Write-PmLog "User '$($uDir.Name)' has no profile on target - desktop restored to $dst" 'WARN'
                }
                $code = Invoke-PmRobocopy -Source $uDir.FullName -Destination $dst
                if (Test-PmRobocopyOk $code) { Write-PmLog "Desktop restored: $($uDir.Name) -> $dst" 'OK' } else { Write-PmLog "Desktop restore failed for $($uDir.Name) ($code)" 'WARN' }
            }
            $report.Desktop = 'ok'
        } catch { $report.Desktop = 'failed'; $report.Errors += "Desktop: $_"; Write-PmLog "Desktop restore failed: $_" 'ERROR' }
    }

    # ---- Extra
    if ($RestoreExtra -and @($manifest.extra).Count -gt 0) {
        try {
            foreach ($e in @($manifest.extra)) {
                $src = Join-Path $stage "extra\$($e.index)"
                if ($e.kind -eq 'file') {
                    $parent = Split-Path $e.path -Parent
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                    Copy-Item -LiteralPath (Join-Path $src (Split-Path $e.path -Leaf)) -Destination $e.path -Force
                } else { Invoke-PmRobocopy -Source $src -Destination $e.path | Out-Null }
                Write-PmLog "Extra restored: $($e.path)" 'OK'
            }
            $report.Extra = 'ok'
        } catch { $report.Extra = 'failed'; $report.Errors += "Extra: $_"; Write-PmLog "Extra restore failed: $_" 'ERROR' }
    }

    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    if ($RemovePackage) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
    Write-PmProgress 100 'Restore finished'
    Write-PmLog "Restore finished on $env:COMPUTERNAME" 'STEP'
    New-PmResult @{ Report = [pscustomobject]$report }
}

function Remove-PmRemoteFile {
    param([Parameter(Mandatory)][string]$Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    # Leave no trace: remove the (now empty) PrtgMover work folders again.
    $dir = Split-Path $Path -Parent
    while ($dir -and (Split-Path $dir -Leaf) -in 'out', 'staging', 'PrtgMover' -and (Test-Path -LiteralPath $dir)) {
        if (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'staging', 'out' -or (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) }) { break }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        $dir = Split-Path $dir -Parent
    }
    New-PmResult @{ Removed = $Path }
}

function Initialize-PmRemoteWorkRoot {
    param([string]$WorkRoot)
    if (-not $WorkRoot) { $WorkRoot = Join-Path $env:SystemDrive 'PrtgMover' }
    New-Item -ItemType Directory -Force -Path (Join-Path $WorkRoot 'in') | Out-Null
    $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f (Split-Path $WorkRoot -Qualifier))
    $prtg = Get-PmPrtgInfo
    $dataBytes = 0
    if ($prtg.Installed) { $dataBytes = Get-PmDirectorySize -Path $prtg.DataPath }
    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    New-PmResult @{
        WorkRoot = $WorkRoot; Inbox = (Join-Path $WorkRoot 'in'); Prtg = $prtg; Computer = $env:COMPUTERNAME
        FreeBytes = [int64]$drive.FreeSpace; PrtgDataBytes = [int64]$dataBytes
        IsAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}
