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

function Get-PmWorkRoot {
    <# Folder for PRTG Mover's own temporary files on this server. #>
    if ($env:PRTGMOVER_WORKROOT) { return $env:PRTGMOVER_WORKROOT.TrimEnd('\').TrimEnd('/') }
    if ($env:SystemDrive) { return (Join-Path $env:SystemDrive 'PrtgMover') }
    # PowerShell 7 on Linux has no SystemDrive. Keep the same folder name under temp.
    return (Join-Path ([IO.Path]::GetTempPath()) 'PrtgMover')
}

function Get-PmComputerName {
    if ($env:COMPUTERNAME) { return [string]$env:COMPUTERNAME }
    $n = [Environment]::MachineName
    if ($n) { return [string]$n }
    return 'localhost'
}

function Test-PmIsAdmin {
    <# True when the process is elevated. False on platforms without a Windows identity. #>
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-PmCurrentUserName {
    try { return [string][Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { return "$env:USERDOMAIN\$env:USERNAME" }
}

function Get-PmOsCaption {
    <# Windows caption when CIM exists; otherwise the runtime OS description. #>
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            if ($os.Caption) { return [string]$os.Caption }
        } catch { }
    }
    return [Environment]::OSVersion.VersionString
}

function Get-PmLogicalDisk {
    <#
        Free space for a path. On Windows this is the Win32_LogicalDisk for the drive letter.
        Without CIM (PowerShell 7 on Linux) it uses the .NET volume that contains the path.
    #>
    param([string]$Path)
    $qualifier = ''
    if ($Path) {
        try { $qualifier = [string](Split-Path -Path $Path -Qualifier -ErrorAction Stop) } catch { $qualifier = '' }
    }
    if (-not $qualifier -and $env:SystemDrive) { $qualifier = $env:SystemDrive }
    if ($qualifier -and (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) {
        try {
            $disk = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $qualifier) -ErrorAction Stop
            if ($disk) { return $disk }
        } catch { }
    }
    $probe = $Path
    if (-not $probe) { $probe = (Get-Location).Path }
    try { $probe = [IO.Path]::GetFullPath($probe) } catch { }
    $match = $null
    foreach ($d in [IO.DriveInfo]::GetDrives()) {
        if (-not $d.IsReady) { continue }
        if ($probe.StartsWith($d.Name, [StringComparison]::OrdinalIgnoreCase)) {
            if (-not $match -or $d.Name.Length -gt $match.Name.Length) { $match = $d }
        }
    }
    if (-not $match) {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ($d.IsReady -and ($d.Name -eq '/' -or $d.Name -eq '\')) { $match = $d; break }
        }
    }
    if (-not $match) { return $null }
    return [pscustomobject]@{ DeviceID = $match.Name; FreeSpace = [int64]$match.AvailableFreeSpace; Size = [int64]$match.TotalSize }
}

# ---------------------------------------------------------------- output helpers

function Write-PmLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP', 'DEBUG')][string]$Level = 'INFO')
    [pscustomobject]@{ PmType = 'log'; Level = $Level; Message = $Message; Time = (Get-Date).ToString('o'); Computer = (Get-PmComputerName) }
}

function Format-PmError {
    <# One-line error with the exact script position - used in logs so a failure can be located immediately. #>
    param($ErrorRecord)
    $pos = ''
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber) {
        $pos = " [line $($ErrorRecord.InvocationInfo.ScriptLineNumber): $($ErrorRecord.InvocationInfo.Line.Trim())]"
    }
    return "$($ErrorRecord.Exception.GetType().Name): $($ErrorRecord.Exception.Message)$pos"
}

function Write-PmErrorDetail {
    <# Emits the full error (type, message, position, stack) as DEBUG log records. #>
    param($ErrorRecord, [string]$Context)
    Write-PmLog "$Context failed: $(Format-PmError $ErrorRecord)" 'DEBUG'
    if ($ErrorRecord.ScriptStackTrace) { Write-PmLog "Stack: $($ErrorRecord.ScriptStackTrace -replace '\r?\n', ' <- ')" 'DEBUG' }
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) { Write-PmLog "Inner: $($inner.GetType().Name): $($inner.Message)" 'DEBUG'; $inner = $inner.InnerException }
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
        [string[]]$ExcludeFiles = @(),
        [switch]$Mirror
    )
    if (-not (Test-Path -LiteralPath $Source)) { return -1 }
    if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
        # Same copy, used when robocopy is not installed (PowerShell 7 on Linux).
        try {
            Copy-PmTreeFallback -Source $Source -Destination $Destination -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
            $global:PmLastRobocopy = "copy `"$Source`" -> `"$Destination`" (robocopy not installed)"
            return 1
        } catch {
            $global:PmLastRobocopy = "copy `"$Source`" -> `"$Destination`" failed: $($_.Exception.Message)"
            return 8
        }
    }
    # Redirected RDP drives (\\tsclient) do not support all directory attributes.
    $dcopy = if ($Destination.StartsWith('\\') -or $Source.StartsWith('\\')) { '/DCOPY:T' } else { '/DCOPY:DAT' }
    $rcArgs = @($Source.TrimEnd('\'), $Destination.TrimEnd('\'), '/COPY:DAT', $dcopy, '/R:2', '/W:2', '/MT:8', '/XJ', '/NP', '/NFL', '/NDL')
    if ($Mirror) { $rcArgs += '/MIR' } else { $rcArgs += '/E' }
    if ($ExcludeDirs.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    # Full robocopy log (summary + every error) for troubleshooting.
    if ($global:PmRobocopyLog) { $rcArgs += "/LOG+:$global:PmRobocopyLog" }
    & robocopy.exe @rcArgs | Out-Null
    $code = $LASTEXITCODE
    $global:PmLastRobocopy = "robocopy `"$Source`" -> `"$Destination`" exit $code"
    return $code
}

function Get-PmRobocopyErrors {
    <# Last error lines of the robocopy log (for error messages). #>
    if (-not $global:PmRobocopyLog -or -not (Test-Path -LiteralPath $global:PmRobocopyLog)) { return '' }
    $lines = @(Get-Content -LiteralPath $global:PmRobocopyLog -Tail 400 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'ERROR|Access is denied|cannot|failed' } | Select-Object -Last 5)
    return ($lines -join ' | ')
}

function Copy-PmTreeFallback {
    <# Directory copy used only when robocopy.exe is absent. Honours the same exclude lists. #>
    param([string]$Source, [string]$Destination, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @())
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $blocked = @($ExcludeDirs | Where-Object { $_ } | ForEach-Object { $_.Replace('/', '\').TrimEnd('\') })
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
        $norm = $item.FullName.Replace('/', '\')
        if ($item.PSIsContainer) {
            $skip = $false
            foreach ($b in $blocked) {
                if ($norm.Equals($b, [StringComparison]::OrdinalIgnoreCase) -or $norm.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
            if ($skip) { continue }
            Copy-PmTreeFallback -Source $item.FullName -Destination (Join-Path $Destination $item.Name) -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
        } else {
            $skipFile = $false
            foreach ($pat in @($ExcludeFiles)) { if ($pat -and $item.Name -like $pat) { $skipFile = $true; break } }
            if ($skipFile) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Force
        }
    }
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
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return @() }
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
    $sp = @{ FilePath = (Join-Path $env:SystemRoot 'System32\reg.exe'); ArgumentList = $argLine; Wait = $true; PassThru = $true }
    # -WindowStyle exists on Windows PowerShell 5.1. PowerShell 7 rejects it.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $sp.WindowStyle = 'Hidden' }
    $p = Start-Process @sp
    return $p.ExitCode
}

# ---------------------------------------------------------------- PRTG discovery / control

function Get-PmLocalIPv4 {
    <# IPv4 addresses of this machine (loopback included, link-local excluded). Works without the NetTCPIP module. #>
    $list = @()
    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        try { $list = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { [string]$_.IPAddress }) } catch { $list = @() }
    }
    if (-not $list.Count) {
        try {
            foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                foreach ($a in $nic.GetIPProperties().UnicastAddresses) {
                    if ($a.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { $list += $a.Address.ToString() }
                }
            }
        } catch { }
    }
    return @($list | Where-Object { $_ -and $_ -notlike '169.254.*' } | Select-Object -Unique)
}

function Get-PmPrtgInfo {
    $info = [ordered]@{
        Installed = $false; Version = $null; ProgramPath = $null; DataPath = $null
        RegistryKeys = @(); CoreStatus = $null; ProbeStatus = $null; ListenPorts = @(); ListenEndpoints = @(); LocalAddresses = @()
    }
    $svc = $null
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$PmCoreService'" -ErrorAction SilentlyContinue
    }
    if ($svc) {
        $info.Installed = $true
        $exe = $svc.PathName
        if ($exe -match '^"([^"]+)"') { $exe = $Matches[1] } elseif ($exe -match '^(.+?\.exe)') { $exe = $Matches[1] }
        $info.ProgramPath = Split-Path $exe -Parent
        # PRTG 64-bit installs run the core from "<install dir>\64 bit\PRTG Server.exe" -
        # customisations (Custom Sensors, Notifications, lookups, cert...) live in the install dir itself.
        if ((Split-Path $info.ProgramPath -Leaf) -eq '64 bit') { $info.ProgramPath = Split-Path $info.ProgramPath -Parent }
        if (Test-Path -LiteralPath $exe) { $info.Version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion }
        $info.CoreStatus = [string]$svc.State
    }
    $probe = $null
    if (Get-Command Get-Service -ErrorAction SilentlyContinue) {
        $probe = Get-Service -Name $PmProbeService -ErrorAction SilentlyContinue
    }
    if ($probe) { $info.ProbeStatus = [string]$probe.Status }

    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Paessler', 'HKLM:\SOFTWARE\Paessler') {
        if (Test-Path $k) { $info.RegistryKeys += $k }
    }
    $dp = $null
    foreach ($core in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Core', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Core') {
        if (-not $dp -and (Test-Path $core)) { $dp = (Get-ItemProperty -Path $core -ErrorAction SilentlyContinue).Datapath }
    }
    if (-not $dp -and $env:ProgramData) { $dp = Join-Path $env:ProgramData 'Paessler\PRTG Network Monitor' }
    $info.DataPath = if ($dp) { $dp.TrimEnd('\').TrimEnd('/') } else { $null }

    $proc = Get-Process -Name 'PRTG Server' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $listen = @()
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) { $listen = @(Get-NetTCPConnection -State Listen -OwningProcess $proc.Id -ErrorAction SilentlyContinue) }
        $info.ListenPorts = @($listen | Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
        # address:port pairs show whether the web server is bound to all addresses or only to specific ones
        $info.ListenEndpoints = @($listen | Sort-Object LocalPort, LocalAddress | ForEach-Object { '{0}:{1}' -f $_.LocalAddress, $_.LocalPort } | Select-Object -Unique)
    }
    $info.LocalAddresses = @(Get-PmLocalIPv4 | Where-Object { $_ -notlike '127.*' })
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

function Clear-PmStaleSnapshots {
    <#
        Removes VSS snapshots that PRTG Mover itself created in an earlier, interrupted run
        (recognised by their C:\PrtgMoverVss_* link). Other snapshots are never touched.
    #>
    $removed = 0
    foreach ($link in (Get-ChildItem -LiteralPath ($env:SystemDrive + '\') -Filter 'PrtgMoverVss_*' -Force -ErrorAction SilentlyContinue)) {
        try {
            $target = [string]($link.Target | Select-Object -First 1)
            if ($target) {
                $dev = $target.TrimEnd('\')
                foreach ($sc in @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
                    if ($sc.DeviceObject -and $dev.EndsWith(($sc.DeviceObject -replace '^\\\\\?\\', ''), [StringComparison]::OrdinalIgnoreCase)) { $sc.Delete() }
                }
            }
            cmd.exe /c "rmdir `"$($link.FullName)`"" | Out-Null
            $removed++
        } catch { Write-PmLog "Could not remove stale snapshot link $($link.FullName): $($_.Exception.Message)" 'WARN' }
    }
    if ($removed) { Write-PmLog "Removed $removed snapshot(s) left behind by interrupted runs." 'OK' }
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

function Get-PmShortHash {
    <# First 10 hex digits of the SHA-256 of a text: lets two servers be compared without showing the value. #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10) } finally { $sha.Dispose() }
}

function Get-PmPrtgLicenseReport {
    <#
        READ-ONLY. What is known about the PRTG license on this server, without showing the key:
          - the license related registry values as fingerprints (compare source and target)
          - the system id fingerprint (PRTG licenses are activated per system id)
          - the latest license / activation lines of the core log, with keys masked
    #>
    param([int]$Days = 4, [int]$MaxLines = 40)
    $prtg = Get-PmPrtgInfo
    $report = [ordered]@{ Installed = $prtg.Installed; Values = @(); SystemId = ''; AutoActivation = $null; LogFile = $null; LogLines = @() }
    if (-not $prtg.Installed) { return [pscustomobject]$report }
    $report.Values = @(Get-PmLicenseValues | ForEach-Object {
            $v = if ($_.Value -is [byte[]]) { [Convert]::ToBase64String($_.Value) } else { [string]$_.Value }
            '{0}={1}' -f $_.Name, $(if ($v) { "#$(Get-PmShortHash $v) ($($v.Length) chars)" } else { '<empty>' })
        })
    foreach ($core in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Core', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Core') {
        if (-not (Test-Path $core)) { continue }
        $p = Get-ItemProperty -Path $core -ErrorAction SilentlyContinue
        if ($p.SystemId) { $report.SystemId = "#$(Get-PmShortHash ([string]$p.SystemId))" }
        if ($null -ne $p.AutoActivation) { $report.AutoActivation = [int]$p.AutoActivation }
        break
    }
    $logDir = Join-Path $prtg.DataPath 'Logs'
    if (Test-Path -LiteralPath $logDir) {
        $since = (Get-Date).AddDays(-$Days)
        $files = @(Get-ChildItem -LiteralPath $logDir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since -and ($_.Name -match 'core' -or $_.DirectoryName -match '\\core$') } | Sort-Object LastWriteTime)
        $hits = New-Object System.Collections.ArrayList
        foreach ($lf in $files) {
            try {
                $fs = New-Object IO.FileStream($lf.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                # only the last 20 MB of a log are read
                if ($fs.Length -gt 20MB) { [void]$fs.Seek(-20MB, [IO.SeekOrigin]::End) }
                $sr = New-Object IO.StreamReader($fs)
                try {
                    while (-not $sr.EndOfStream) {
                        $line = $sr.ReadLine()
                        if ($line -match '(?i)licen|activat|edition|system ?id|trial|freeware|subscription|maintenance|sensor limit|exceed') { [void]$hits.Add(("{0}: {1}" -f $lf.Name, $line)) }
                    }
                } finally { $sr.Dispose(); $fs.Dispose() }
                $report.LogFile = $lf.FullName
            } catch { }
        }
        $report.LogLines = @($hits | Select-Object -Last $MaxLines | ForEach-Object {
                $l = $_ -replace '[0-9A-Za-z]{6}(-[0-9A-Za-z]{6}){3,}', '<key>' -replace '(?i)SYSTEMID-[0-9A-Z-]+', 'SYSTEMID-<masked>'
                if ($l.Length -gt 260) { $l.Substring(0, 260) + ' ...' } else { $l }
            })
    }
    return [pscustomobject]$report
}

function ConvertTo-PmLicenseState {
    <#
        Turns the license lines of the PRTG core log into a short state:
        Edition, Name, MaxSensors, NeedsActivation, LastError. Pure function (testable).
    #>
    param([string[]]$LogLines = @(), [string]$PausedByLicense)
    $state = [ordered]@{ Known = $false; Edition = $null; Name = $null; MaxSensors = $null; NeedsActivation = $false; LastError = $null; PausedByLicense = $PausedByLicense }
    $lic = @($LogLines | Where-Object { $_ -match 'licensed for "' } | Select-Object -Last 1)
    if ($lic.Count -and $lic[0] -match '>\s*PRTG\s+(?<edition>.*?)\s*licensed for "(?<name>[^"]*)".*?Edt=(?<edt>-?\d+)\s+MaxS=(?<max>\d+)') {
        $edition = $Matches.edition.Trim(); $name = $Matches.name; $edt = [int]$Matches.edt; $max = [int]$Matches.max
        if ($edition -match '^\((?<inner>[^()]*)\)$') { $edition = $Matches.inner }
        $state.Known = $true
        $state.Edition = $edition
        $state.Name = $name
        $state.MaxSensors = $max
        $state.NeedsActivation = ($edition -match '(?i)no license|system changed' -or $edt -lt 0 -or $max -eq 0)
    }
    $err = @($LogLines | Where-Object { $_ -match '(?i)activation done .*error|new activation required|activation failed' } | Select-Object -Last 1)
    if ($err.Count) { $state.LastError = ($err[0] -replace '^.*?>\s*', '').Trim() }
    return [pscustomobject]$state
}

function Get-PmPrtgLicenseState {
    <# READ-ONLY. Short license state of the PRTG on this server (from the registry and the core log). #>
    $rep = Get-PmPrtgLicenseReport -Days 3 -MaxLines 400
    $paused = $null
    $pv = @(Get-PmLicenseValues | Where-Object { $_.Name -eq 'SensorCountPausedByLicenseMax' } | Select-Object -First 1)
    if ($pv.Count) { $paused = [string]$pv[0].Value }
    return (ConvertTo-PmLicenseState -LogLines @($rep.LogLines) -PausedByLicense $paused)
}

function Get-PmLicenseFiles {
    param([string]$DataPath)
    if (-not (Test-Path -LiteralPath $DataPath)) { return @() }
    @(Get-ChildItem -LiteralPath $DataPath -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'licen' })
}

# ---------------------------------------------------------------- web server binding

function Get-PmReboundIpList {
    <# "a,b" -> the same list with addresses that do not exist locally replaced by $Own; 127.0.0.1 is always kept. #>
    param([string]$Current, [string[]]$Local = @(), [string]$Own, [switch]$AddOwn)
    $new = @()
    foreach ($ip in ($Current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($ip -eq '127.0.0.1' -or $Local -contains $ip) { $new += $ip } elseif ($Own) { $new += $Own }
    }
    # -AddOwn: PRTG itself drops addresses it cannot bind at start-up, leaving only 127.0.0.1.
    if ($AddOwn -and $Own -and -not @($new | Where-Object { $_ -ne '127.0.0.1' }).Count) { $new = @($Own) + $new }
    if ($new -notcontains '127.0.0.1') { $new += '127.0.0.1' }
    return (@($new | Select-Object -Unique) -join ',')
}

function Set-PmPrtgWebBinding {
    <#
        The PRTG web server can be bound to specific IP addresses (registry: Server\Webserver,
        UseIPs = owioSpecIPs, IPs = "a,b"). After a migration those are the SOURCE's addresses;
        PRTG then only listens on 127.0.0.1. Addresses that do not exist on this server are
        replaced by this server's own address. Nothing is changed when every address exists.
    #>
    param([string]$TargetAddress, [bool]$AddOwn = $false, [bool]$CheckOnly = $false)
    $local = @(Get-PmLocalIPv4)
    $own = if ($TargetAddress -and $local -contains $TargetAddress) { $TargetAddress }
    else { $local | Where-Object { $_ -ne '127.0.0.1' -and $_ -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } | Select-Object -First 1 }
    if (-not $own) { $own = $local | Where-Object { $_ -ne '127.0.0.1' } | Select-Object -First 1 }
    $changed = $false; $before = $null; $after = $null
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Webserver', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Webserver') {
        if (-not (Test-Path $key)) { continue }
        $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($p.UseIPs -ne 'owioSpecIPs' -or -not $p.IPs) { continue }
        $before = [string]$p.IPs
        $after = Get-PmReboundIpList -Current $before -Local $local -Own $own -AddOwn:$AddOwn
        if ($after -ne $before) { if (-not $CheckOnly) { Set-ItemProperty -Path $key -Name 'IPs' -Value $after }; $changed = $true }
    }
    if ($CheckOnly) { return [pscustomobject]@{ PmType = 'binding'; Changed = $changed; Before = $before; After = $after } }
    if ($changed) { Write-PmLog "PRTG web server binding changed from '$before' to '$after' (addresses of this server)." 'OK' }
    elseif ($before) { Write-PmLog "PRTG web server binding is valid for this server ($before)." 'OK' }
    else { Write-PmLog 'PRTG web server listens on all addresses (no specific binding).' 'OK' }
    [pscustomobject]@{ PmType = 'binding'; Changed = $changed; Before = $before; After = $after }
}

function Repair-PmPrtgBinding {
    <# Fixes the web server binding of an already migrated PRTG, restarts it and verifies it is fully up. #>
    param([string]$TargetAddress, [int]$HealthTimeoutMinutes = 15)
    $ErrorActionPreference = 'Stop'
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server.' }
    Write-PmLog "PRTG currently listens on: $(@($prtg.ListenEndpoints) -join ', ')"
    Write-PmProgress 10 'Adjusting web server binding'
    $bx = @{ B = (Set-PmPrtgWebBinding -TargetAddress $TargetAddress -AddOwn $true -CheckOnly $true) }
    $health = $null
    if (-not $bx.B.Changed) { Write-PmLog "PRTG web server binding needs no change ($($bx.B.Before))." 'OK' }
    if ($bx.B.Changed) {
        # Order matters: the core writes its settings back to the registry when it stops,
        # so the binding must be changed while PRTG is stopped.
        Write-PmProgress 20 'Stopping PRTG'
        Write-PmLog 'Stopping PRTG (the binding can only be changed while the core is stopped)...' 'STEP'
        Stop-PmPrtgServices
        Write-PmProgress 40 'Adjusting web server binding'
        Set-PmPrtgWebBinding -TargetAddress $TargetAddress -AddOwn $true | ForEach-Object { if ($_.PmType -eq 'binding') { $bx.B = $_ } else { $_ } }
        Write-PmProgress 50 'Starting PRTG'
        $box = @{}
        Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
        $health = $box.Health
        if (-not $health.Healthy) { throw "PRTG did not come up completely after the restart ($($health.Message))." }
    }
    $after = Get-PmPrtgInfo
    $outside = @($after.ListenEndpoints | Where-Object { $_ -notmatch '^(127\.0\.0\.1|::1):' })
    $reg = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Webserver' -ErrorAction SilentlyContinue)
    Write-PmLog "Registry after start: UseIPs=$($reg.UseIPs) IPs=$($reg.IPs) Ports=$($reg.Ports)" 'DEBUG'
    if ($outside.Count) { Write-PmLog "PRTG now listens on: $(@($after.ListenEndpoints) -join ', ')" 'OK' }
    else { Write-PmLog "PRTG still only listens on this server itself: $(@($after.ListenEndpoints) -join ', ') (registry IPs=$($reg.IPs)). Set the web server IP in the PRTG Administration Tool on the server." 'ERROR' }
    Write-PmProgress 100 'Done'
    New-PmResult @{ Changed = $bx.B.Changed; Before = $bx.B.Before; After = $bx.B.After; ListenEndpoints = @($after.ListenEndpoints); Core = $after.CoreStatus; Probe = $after.ProbeStatus }
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
    $osCaption = Get-PmOsCaption
    $osVersion = [Environment]::OSVersion.Version.ToString()
    $isAdmin = Test-PmIsAdmin
    $userName = Get-PmCurrentUserName
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try { $osVersion = [string](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Version } catch { }
    }
    $vpn = @()
    try { $vpn = @(Get-VpnConnection -AllUserConnection -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Server = $_.ServerAddress; Type = [string]$_.TunnelType; Status = [string]$_.ConnectionStatus } }) } catch { }
    $prtg = Get-PmPrtgInfo
    $dataSize = 0; $stats = $null
    if ($prtg.Installed) {
        $dataSize = Get-PmDirectorySize -Path $prtg.DataPath
        $stats = Get-PmPrtgConfigStats -Path (Join-Path $prtg.DataPath 'PRTG Configuration.dat')
    }
    $disks = @()
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ Drive = $_.DeviceID; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) } })
    } else {
        $disks = @(Get-PmLogicalDisk -Path (Get-PmWorkRoot) | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{ Drive = $_.DeviceID; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) } })
    }

    New-PmResult @{
        Computer     = $env:COMPUTERNAME
        OS           = $osCaption
        OSVersion    = $osVersion
        IsAdmin      = $isAdmin
        User         = $userName
        Prtg         = $prtg
        PrtgDataGB   = [math]::Round($dataSize / 1GB, 2)
        PrtgConfigStats = $stats
        PrtgLicense  = $(if ($prtg.Installed) { try { Get-PmPrtgLicenseReport } catch { [pscustomobject]@{ Error = "$($_.Exception.Message)" } } })
        PrtgLicenseState = $(if ($prtg.Installed) { try { Get-PmPrtgLicenseState } catch { $null } })
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
        [int]$HealthTimeoutMinutes = 15,
        [bool]$IncludeProgram = $true,
        [bool]$IncludeLogs = $false,
        [bool]$IncludeAutoBackups = $false,
        # Stage directly into this folder (e.g. the manager's disk via \\tsclient) and skip zipping on the source.
        [string]$StageDir,
        [string]$LogDir,
        # WinRM pull mode: big folders are NOT copied here - the manager pulls them straight from the snapshot.
        [bool]$PullMode = $false
    )
    $ErrorActionPreference = 'Stop'
    $sourceHealth = $null
    $pullItems = @()
    if (-not $WorkRoot) { $WorkRoot = Get-PmWorkRoot }
    $direct = [bool]$StageDir
    $stage = if ($direct) { $StageDir } else { Join-Path $WorkRoot "staging\$JobId" }
    $outDir = Join-Path $WorkRoot 'out'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    if (-not $direct) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    if ($LogDir) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; $global:PmRobocopyLog = Join-Path $LogDir "robocopy-$JobId-$env:COMPUTERNAME.log" } else { $global:PmRobocopyLog = $null }
    Write-PmLog "Mode: $(if ($direct) { 'direct staging on the manager (no disk space used on this server)' } else { 'local staging + zip' }). Robocopy log: $(if ($global:PmRobocopyLog) { $global:PmRobocopyLog } else { 'off' })" 'DEBUG'

    $manifest = [ordered]@{
        tool = 'prtg-mover'; formatVersion = 1; jobId = $JobId
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = [ordered]@{ computer = $env:COMPUTERNAME; os = (Get-PmOsCaption) }
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
            Clear-PmStaleSnapshots
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
                if ($PullMode) {
                    # Freeze the stopped state so the services can be restarted before the manager has pulled everything.
                    try {
                        $shadow = New-PmShadowCopy -Path $prtg.DataPath
                        $dataSource = Join-Path $shadow.Link $prtg.DataPath.Substring($shadow.Volume.Length)
                        Write-PmLog 'VSS snapshot of the stopped state created.' 'OK'
                    } catch { Write-PmLog "VSS snapshot not available ($($_.Exception.Message)) - PRTG must stay stopped until the pull is finished." 'WARN'; $SourceAfter = 'KeepStopped' }
                }
            }

            try {
                Write-PmProgress 20 'PRTG: copying data folder'
                # Only what PRTG needs: no log files, caches, temp files or old automatic config copies (unless asked).
                $exclude = @()
                if (-not $IncludeHistory) { $exclude += (Join-Path $dataSource 'Monitoring Database') }
                if (-not $IncludeLogs) { $exclude += (Join-Path $dataSource 'Logs') }
                if (-not $IncludeAutoBackups) { $exclude += (Join-Path $dataSource 'Configuration Auto-Backups') }
                $excludeFiles = @('*.tmp', 'PRTG Graph Data Cache*', '*.old', '*.bak')
                $skipped = @()
                foreach ($x in $exclude) {
                    if (Test-Path -LiteralPath $x) { $skipped += ('{0} ({1:N2} GB)' -f (Split-Path $x -Leaf), ((Get-PmDirectorySize $x) / 1GB)) }
                }
                Write-PmLog "Copying only what PRTG needs. Skipped: $(if ($skipped) { $skipped -join ', ' } else { 'nothing' }) + temp/cache files ($($excludeFiles -join ', '))." 'INFO'
                if ($PullMode) {
                    $pullItems += [pscustomobject]@{ Source = $dataSource; Target = 'prtg\data'; ExcludeDirs = @($exclude); ExcludeFiles = @($excludeFiles) }
                    $cfg = Join-Path $dataSource 'PRTG Configuration.dat'
                } else {
                    $code = Invoke-PmRobocopy -Source $dataSource -Destination (Join-Path $stage 'prtg\data') -ExcludeDirs $exclude -ExcludeFiles $excludeFiles -Mirror
                    if (-not (Test-PmRobocopyOk $code)) { throw "robocopy of PRTG data failed with exit code $code. $(Get-PmRobocopyErrors)" }
                    $cfg = Join-Path $stage 'prtg\data\PRTG Configuration.dat'
                }
                if (-not (Test-Path -LiteralPath $cfg)) { throw "'PRTG Configuration.dat' is missing from the copied data folder - aborting (backup would be unusable)." }
                $cfgInfo = Get-Item -LiteralPath $cfg
                $cfgHash = (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash
                $cfgStats = Get-PmPrtgConfigStats -Path $cfg
                Write-PmLog "Configuration content (all rules, notifications, triggers, users... are inside this file): $cfgStats" 'OK'
                if ($PullMode) { Write-PmLog ("Data folder prepared for pulling by the manager. PRTG Configuration.dat: {0:N1} MB, saved {1}." -f ($cfgInfo.Length / 1MB), $cfgInfo.LastWriteTime) 'OK' }
                else { Write-PmLog ("Data folder copied ({0:N2} GB). PRTG Configuration.dat: {1:N1} MB, saved {2}." -f ((Get-PmDirectorySize (Join-Path $stage 'prtg\data')) / 1GB), ($cfgInfo.Length / 1MB), $cfgInfo.LastWriteTime) 'OK' }

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

                # ---- full program clone: lets a target without PRTG run it without any installer
                $programCloned = $false; $services = @()
                if ($IncludeProgram) {
                    Write-PmProgress 38 'PRTG: cloning program files and services'
                    $progSource = $prtg.ProgramPath
                    if ($shadow -and $prtg.ProgramPath.StartsWith($shadow.Volume, [StringComparison]::OrdinalIgnoreCase)) {
                        $progSource = Join-Path $shadow.Link $prtg.ProgramPath.Substring($shadow.Volume.Length)
                    }
                    if ($PullMode) {
                        $pullItems += [pscustomobject]@{ Source = $progSource; Target = 'prtg\programfull'; ExcludeDirs = @(); ExcludeFiles = @() }
                        $programCloned = $true
                        Write-PmLog ("Complete PRTG program folder ({0:N0} MB) prepared for pulling - the target needs no installer." -f ((Get-PmDirectorySize $progSource) / 1MB)) 'OK'
                    } elseif (Test-PmRobocopyOk ($code = Invoke-PmRobocopy -Source $progSource -Destination (Join-Path $stage 'prtg\programfull'))) {
                        $programCloned = $true
                        Write-PmLog ("Complete PRTG program folder cloned ({0:N0} MB) - the target needs no installer." -f ((Get-PmDirectorySize (Join-Path $stage 'prtg\programfull')) / 1MB)) 'OK'
                    } else { Write-PmLog "Program folder clone failed (robocopy $code) - the target will need the PRTG installer." 'WARN' }
                    $svcDir = Join-Path $stage 'prtg\services'
                    New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
                    foreach ($n in $PmCoreService, $PmProbeService) {
                        $w = $null
                        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                            $w = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
                        }
                        if (-not $w) { continue }
                        [void](Invoke-PmReg -Verb export -Key "HKLM\SYSTEM\CurrentControlSet\Services\$n" -File (Join-Path $svcDir "$n.reg"))
                        $services += [ordered]@{ name = $w.Name; displayName = $w.DisplayName; pathName = $w.PathName; startMode = $w.StartMode; startName = $w.StartName; description = $w.Description }
                    }
                    Write-PmLog "Service definitions saved: $(@($services | ForEach-Object { $_.name }) -join ', ')" 'OK'
                }
                $netRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release

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
                    programCloned = $programCloned; services = $services; netFrameworkRelease = $netRelease
                    consistency = $(if ($NoTouch) { if ($shadow) { 'vss-snapshot' } else { 'live-copy' } } else { 'services-stopped' })
                }
            } finally {
                if ($shadow -and $PullMode) { Write-PmLog 'VSS snapshot kept until the manager has pulled the data (removed afterwards).' 'DEBUG' }
                elseif ($shadow) { Remove-PmShadowCopy -Shadow $shadow; Write-PmLog 'VSS snapshot removed.' }
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
        foreach ($u in $manifest.desktop.users) {
            $files = @(Get-ChildItem -LiteralPath (Join-Path $deskStage $u) -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })
            if (-not $files.Count) { continue }
            $special = @($files | Where-Object { $_.Extension -in '.bat', '.cmd', '.ps1', '.pbk', '.ovpn', '.conf', '.rdp', '.vbs' } | ForEach-Object { $_.Name })
            Write-PmLog ("Desktop {0}: {1} file(s), {2:N1} MB{3}" -f $u, $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $(if ($special.Count) { " - scripts/VPN: $($special -join ', ')" } else { '' })) 'INFO'
        }
        $manifest.desktop.files = @(Get-ChildItem -LiteralPath $deskStage -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $_.FullName.Substring($deskStage.Length + 1) } | Select-Object -First 500)
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
    Write-PmProgress 70 'Packaging: writing manifest'
    $manifest.stagingBytes = Get-PmDirectorySize $stage
    foreach ($pi in $pullItems) { $manifest.stagingBytes += [int64](@((Get-PmPullList -Source $pi.Source -ExcludeDirs $pi.ExcludeDirs -ExcludeFiles $pi.ExcludeFiles -Raw) | Measure-Object -Property Size -Sum).Sum) }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $stage 'manifest.json') -Encoding UTF8
    if ($PullMode) {
        Write-PmLog ("Ready for the manager to pull {0:N2} GB (small items staged locally: {1:N1} MB)." -f ($manifest.stagingBytes / 1GB), ((Get-PmDirectorySize $stage) / 1MB)) 'OK'
        Write-PmProgress 80 'Ready to pull'
        return (New-PmResult @{ StageDir = $stage; PullItems = @($pullItems); ShadowId = $(if ($shadow) { $shadow.Id }); ShadowLink = $(if ($shadow) { $shadow.Link }); Manifest = ($manifest | ConvertTo-Json -Depth 8); SourceHealth = $sourceHealth })
    }
    if ($direct) {
        Write-PmLog ("Staging complete on the manager ({0:N2} GB). The manager builds the package." -f ($manifest.stagingBytes / 1GB)) 'OK'
        Write-PmProgress 80 'Staging done'
        return (New-PmResult @{ StageDir = $stage; Manifest = ($manifest | ConvertTo-Json -Depth 8); SourceHealth = $sourceHealth })
    }
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
        [string]$ZipPath,
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
        [string]$ExpectedSha256,
        # Read the extracted package directly from this folder (e.g. the manager via \\tsclient) instead of a zip.
        [string]$StageDir,
        [string]$LogDir,
        # The staged package is local on this server: move folders into place instead of copying (saves disk space).
        [bool]$MoveFromStage = $false,
        [bool]$CleanupStage = $false,
        # Address of this server as the manager knows it (used for the PRTG web server binding).
        [string]$TargetAddress
    )
    $ErrorActionPreference = 'Stop'
    if (-not $WorkRoot) { $WorkRoot = Get-PmWorkRoot }
    $direct = [bool]$StageDir
    $stage = if ($direct) { $StageDir } else { Join-Path $WorkRoot "restore\$JobId" }
    if ($LogDir) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; $global:PmRobocopyLog = Join-Path $LogDir "robocopy-$JobId-$env:COMPUTERNAME.log" } else { $global:PmRobocopyLog = $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $report = [ordered]@{ Computer = $env:COMPUTERNAME; Prtg = 'skipped'; License = 'skipped'; Vpn = 'skipped'; Desktop = 'skipped'; Extra = 'skipped'; WebUrl = $null; Version = $null; Errors = @() }

    Write-PmLog "Restore started on $env:COMPUTERNAME" 'STEP'

    # ---- integrity + disk space pre-checks
    if ($direct) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage 'manifest.json'))) { throw "Staged package not found at $stage" }
        $manifest = Get-Content -LiteralPath (Join-Path $stage 'manifest.json') -Raw | ConvertFrom-Json
        $need = [int64]$manifest.stagingBytes
        $drive = if ($env:SystemDrive) { Get-PmLogicalDisk -Path ($env:SystemDrive + '\') } else { Get-PmLogicalDisk -Path $stage }
        # Local stage + move: the data already occupies the disk, only a margin is needed.
        $required = if ($MoveFromStage) { [int64]1GB } else { [int64]($need * 1.1 + 1GB) }
        if ($drive -and $drive.FreeSpace -lt $required) { throw ("Not enough free space on {0}: {1:N1} GB free, {2:N1} GB required." -f $drive.DeviceID, ($drive.FreeSpace / 1GB), ($required / 1GB)) }
        if ($drive) { Write-PmLog ("Reading the staged package from {0}. Disk space OK: {1:N1} GB free, ~{2:N1} GB needed." -f $stage, ($drive.FreeSpace / 1GB), ($required / 1GB)) 'OK' }
        else { Write-PmLog "Reading the staged package from $stage. Disk free space could not be read." 'WARN' }
    }
    if (-not $direct -and $ExpectedSha256) {
        Write-PmProgress 2 'Verifying package checksum'
        $h = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
        if ($h -ne $ExpectedSha256) { throw "Package checksum mismatch on target (expected $ExpectedSha256, got $h) - transfer corrupted." }
        Write-PmLog 'Package SHA-256 verified on target.' 'OK'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not $direct) {
    $need = 0
    $zr = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { foreach ($e in $zr.Entries) { $need += $e.Length } } finally { $zr.Dispose() }
    $drive = Get-PmLogicalDisk -Path $WorkRoot
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
    }
    Write-PmLog "Package from $($manifest.source.computer) created $($manifest.createdUtc)" 'OK'

    # ---- PRTG
    if ($RestorePrtg -and $manifest.prtg.included) {
        try {
            Write-PmProgress 15 'PRTG: checking installation'
            $prtg = Get-PmPrtgInfo
            $cloneDir = Join-Path $stage 'prtg\programfull'
            if (-not $prtg.Installed -and -not $InstallerPath -and $manifest.prtg.programCloned -and (Test-Path -LiteralPath $cloneDir)) {
                # ---- clone install: same program files + same Windows services as the source
                $progPath = [string]$manifest.prtg.programPath
                $q = Split-Path $progPath -Qualifier -ErrorAction SilentlyContinue
                if (-not $q -or -not (Test-Path "$q\")) { $progPath = Join-Path ${env:ProgramFiles(x86)} 'PRTG Network Monitor' }
                Write-PmLog "PRTG is not installed here - installing the CLONED program files from the source to $progPath (no installer needed)..." 'STEP'
                if ($MoveFromStage -and -not (Test-Path -LiteralPath $progPath) -and ((Split-Path $cloneDir -Qualifier) -eq (Split-Path $progPath -Qualifier))) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $progPath -Parent) | Out-Null
                    Move-Item -LiteralPath $cloneDir -Destination $progPath
                    $code = 0
                } else { $code = Invoke-PmRobocopy -Source $cloneDir -Destination $progPath }
                if (-not (Test-PmRobocopyOk $code)) { throw "Copying the PRTG program files failed (robocopy $code)." }
                $srcNet = [int]$manifest.prtg.netFrameworkRelease
                $dstNet = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
                if ($srcNet -and $dstNet -lt $srcNet) { Write-PmLog ".NET Framework on target (release $dstNet) is older than on the source ($srcNet). If PRTG does not start, install the same .NET Framework version." 'WARN' }
                foreach ($svc in @($manifest.prtg.services)) {
                    $bin = ([string]$svc.pathName).Replace([string]$manifest.prtg.programPath, $progPath)
                    if (Get-Service -Name $svc.name -ErrorAction SilentlyContinue) { & sc.exe delete $svc.name | Out-Null; Start-Sleep -Seconds 2 }
                    $np = @{ Name = $svc.name; BinaryPathName = $bin; DisplayName = $svc.displayName; StartupType = 'Automatic' }
                    if ($svc.description) { $np.Description = $svc.description }
                    New-Service @np | Out-Null
                    $regFile = Join-Path $stage "prtg\services\$($svc.name).reg"
                    if ($bin -eq $svc.pathName -and (Test-Path -LiteralPath $regFile)) { [void](Invoke-PmReg -Verb import -File $regFile) }   # recovery options etc.
                    if ($svc.startName -and $svc.startName -ne 'LocalSystem') { Write-PmLog "Service $($svc.name) ran as '$($svc.startName)' on the source - it now runs as LocalSystem; change it in services.msc if required." 'WARN' }
                    Write-PmLog "Service created: $($svc.name) -> $bin" 'OK'
                }
                $prtg = Get-PmPrtgInfo
                if (-not $prtg.Installed) { throw 'PRTG services could not be created from the clone.' }
                Write-PmLog "PRTG $($prtg.Version) cloned from the source and registered." 'OK'
            }
            if (-not $prtg.Installed) {
                if (-not $InstallerPath) { throw 'PRTG is not installed on this server, the package has no program clone and no installer was supplied. Upload the installer in the dashboard and run the restore again.' }
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
            $srcData = Join-Path $stage 'prtg\data'
            if ($MoveFromStage -and -not (Test-Path -LiteralPath $dataPath) -and ((Split-Path $srcData -Qualifier) -eq (Split-Path $dataPath -Qualifier))) {
                # Same volume: move instead of copy - no second copy of the data on the target disk.
                New-Item -ItemType Directory -Force -Path (Split-Path $dataPath -Parent) | Out-Null
                Move-Item -LiteralPath $srcData -Destination $dataPath
                $code = 0
                Write-PmLog 'Data folder moved into place (no extra disk space used).' 'OK'
            } else {
                $code = Invoke-PmRobocopy -Source $srcData -Destination $dataPath -Mirror
            }
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

            # ---- web server binding: the source's IP addresses do not exist here
            Set-PmPrtgWebBinding -TargetAddress $TargetAddress | Where-Object { $_.PmType -ne 'binding' }

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
                    try {
                        $ls = Get-PmPrtgLicenseState
                        if ($ls.Known -and $ls.NeedsActivation) {
                            $report.License = 'needs-activation'
                            Write-PmLog "LICENSE: PRTG on this server reports '$($ls.Edition)'. A PRTG license is bound to the system it was activated on, so it must be activated again for this server (PRTG > Setup > License Information). Until then PRTG pauses the sensors. The license on the source server is not affected by this." 'WARN'
                            if ($ls.LastError) { Write-PmLog "LICENSE: last activation attempt: $($ls.LastError)" 'WARN' }
                        } elseif ($ls.Known) {
                            $report.License = "active ($($ls.Edition), $($ls.MaxSensors) sensors)"
                            Write-PmLog "LICENSE: $($ls.Edition), $($ls.MaxSensors) sensors - active on this server." 'OK'
                        }
                    } catch { Write-PmLog "License state could not be read: $($_.Exception.Message)" 'DEBUG' }
                    Write-PmLog "PRTG $($health.Version) is fully UP on $env:COMPUTERNAME : $($health.Url) (core $($health.Core), probe $($health.Probe))" 'OK'
                    $ep = @((Get-PmPrtgInfo).ListenEndpoints)
                    $outside = @($ep | Where-Object { $_ -notmatch '^(127\.0\.0\.1|::1):' })
                    if ($outside.Count) { Write-PmLog "PRTG listens on: $($ep -join ', ')" 'OK' }
                    else { Write-PmLog "PRTG only listens on this server itself ($($ep -join ', ')) - it is not reachable from the network. Check the web server IP setting in the PRTG Administration Tool." 'WARN' }
                } else {
                    $report.Prtg = 'unhealthy'
                    $report.Errors += "PRTG did not come up completely within $HealthTimeoutMinutes min ($($health.Message))."
                    Write-PmLog "PRTG did NOT come up completely ($($health.Message)). See '$dataPath\Logs\core' on the target. Rollback data: $dataPath.pre-restore-$stamp" 'ERROR'
                }
            } else { $report.Prtg = 'restored-not-started' }
        } catch {
            $report.Prtg = 'failed'; $report.Errors += "PRTG: $_"
            Write-PmLog "PRTG restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'PRTG restore'
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
        } catch { $report.Vpn = 'failed'; $report.Errors += "VPN: $_"; Write-PmLog "VPN restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'VPN restore' }
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
        } catch { $report.Desktop = 'failed'; $report.Errors += "Desktop: $_"; Write-PmLog "Desktop restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'Desktop restore' }
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
        } catch { $report.Extra = 'failed'; $report.Errors += "Extra: $_"; Write-PmLog "Extra restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'Extra restore' }
    }

    if (-not $direct -or $CleanupStage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($RemovePackage -and $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
    Write-PmProgress 100 'Restore finished'
    Write-PmLog "Restore finished on $env:COMPUTERNAME" 'STEP'
    New-PmResult @{ Report = [pscustomobject]$report }
}

function Get-PmPullList {
    <#
        Files below $Source (relative path, size, last write) without the excluded folders /
        file patterns. Used by the manager to pull or push file by file and to resume: only
        missing or changed files are transferred again.
    #>
    param([Parameter(Mandatory)][string]$Source, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @(), [switch]$Raw)
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Source) {
        $root = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\').TrimEnd('/')
        $xd = @($ExcludeDirs | Where-Object { $_ } | ForEach-Object { $_.Replace('/', '\').TrimEnd('\') + '\' })
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $full = $f.FullName.Replace('/', '\')
            if (@($xd | Where-Object { $full.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
            if (@($ExcludeFiles | Where-Object { $f.Name -like $_ }).Count) { continue }
            if ($f.Name -in 'desktop.ini', 'Thumbs.db') { continue }   # Windows shell junk
            $relRoot = $root.Replace('/', '\')
            [void]$list.Add([pscustomobject]@{ Rel = $full.Substring($relRoot.Length + 1); Size = $f.Length; Time = $f.LastWriteTimeUtc.Ticks })
        }
    }
    if ($Raw) { return $list }
    New-PmResult @{ Root = $Source; Files = @($list); Count = $list.Count; Bytes = [int64](($list | Measure-Object -Property Size -Sum).Sum) }
}

function New-PmTransferChunk {
    <#
        Packs a batch of files (relative to $Source) into one compressed zip so the manager can
        transfer many files - compressed - in a single copy. PRTG data compresses ~4-5x.
        Reads through .NET, so hidden/system files work too. The chunk is temporary.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string[]]$Files, [string]$ChunkPath)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (-not $ChunkPath) { $ChunkPath = Join-Path (Get-PmWorkRoot) ("chunks\{0}.zip" -f [guid]::NewGuid().ToString('N')) }
    # Never compete with a running PRTG for CPU: remoting host processes run below normal priority.
    if ($Host.Name -eq 'ServerRemoteHost') { try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { } }
    New-Item -ItemType Directory -Force -Path (Split-Path $ChunkPath -Parent) | Out-Null
    if (Test-Path -LiteralPath $ChunkPath) { Remove-Item -LiteralPath $ChunkPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($ChunkPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($rel in $Files) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $Source $rel), $rel.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
    New-PmResult @{ Path = $ChunkPath; Size = (Get-Item -LiteralPath $ChunkPath).Length; Count = $Files.Count }
}

function Expand-PmTransferChunk {
    <# Unpacks a chunk into $Destination (overwriting) and deletes the chunk. #>
    param([Parameter(Mandatory)][string]$ChunkPath, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $n = 0
    $zip = [IO.Compression.ZipFile]::OpenRead($ChunkPath)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            $target = Join-Path $Destination ($e.FullName.Replace('/', '\'))
            $dir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $n++
        }
    } finally { $zip.Dispose() }
    Remove-Item -LiteralPath $ChunkPath -Force -ErrorAction SilentlyContinue
    New-PmResult @{ Count = $n }
}

function Remove-PmTransferChunk {
    param([Parameter(Mandatory)][string]$ChunkPath)
    Remove-Item -LiteralPath $ChunkPath -Force -ErrorAction SilentlyContinue
    New-PmResult @{ Removed = $ChunkPath }
}

function Get-PmHostFacts {
    New-PmResult @{ Cores = [Environment]::ProcessorCount; Computer = $env:COMPUTERNAME }
}

function Clear-PmRemoteStages {
    <# Removes PRTG Mover's own temporary restore folders / chunks of earlier (cancelled) runs, except $Keep. #>
    param([string]$Keep)
    $root = Join-Path (Get-PmWorkRoot) 'restore'
    $removed = @()
    foreach ($d in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
        if ($Keep -and $d.FullName -eq $Keep.TrimEnd('\')) { continue }
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed += $d.Name
    }
    if ($removed.Count) { Write-PmLog "Removed leftovers of earlier runs: $($removed -join ', ')" 'INFO' }
    New-PmResult @{ Removed = $removed }
}

function New-PmRemoteDirectories {
    param([Parameter(Mandatory)][string]$Root, [string[]]$Relative = @())
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    foreach ($r in $Relative) { if ($r) { New-Item -ItemType Directory -Force -Path (Join-Path $Root $r) | Out-Null } }
    New-PmResult @{ Created = $Relative.Count }
}

function Complete-PmRemotePull {
    <# Source cleanup after the manager pulled everything: remove the VSS snapshot and the small local staging folder. #>
    param([string]$StageDir, [string]$ShadowId, [string]$ShadowLink)
    if ($ShadowId) { Remove-PmShadowCopy -Shadow ([pscustomobject]@{ Id = $ShadowId; Link = $ShadowLink }); Write-PmLog 'VSS snapshot removed.' 'OK' }
    if ($StageDir -and (Test-Path -LiteralPath $StageDir)) { Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue }
    $root = Get-PmWorkRoot
    $chunks = Join-Path $root 'chunks'
    if (Test-Path -LiteralPath $chunks) { Remove-Item -LiteralPath $chunks -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($d in (Join-Path $root 'staging'), (Join-Path $root 'out'), $root) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
    }
    Write-PmLog 'Temporary files removed from the source - nothing left behind.' 'OK'
    New-PmResult @{ Done = $true }
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
    if (-not $WorkRoot) { $WorkRoot = Get-PmWorkRoot }
    New-Item -ItemType Directory -Force -Path (Join-Path $WorkRoot 'in') | Out-Null
    $drive = Get-PmLogicalDisk -Path $WorkRoot
    $prtg = Get-PmPrtgInfo
    $dataBytes = 0
    if ($prtg.Installed) { $dataBytes = Get-PmDirectorySize -Path $prtg.DataPath }
    New-PmResult @{
        WorkRoot = $WorkRoot; Inbox = (Join-Path $WorkRoot 'in'); Prtg = $prtg; Computer = $env:COMPUTERNAME
        FreeBytes = $(if ($drive) { [int64]$drive.FreeSpace } else { [int64]0 }); PrtgDataBytes = [int64]$dataBytes
        IsAdmin = (Test-PmIsAdmin)
    }
}
