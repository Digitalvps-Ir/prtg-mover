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
    if ($env:PRTGMOVER_WORKROOT) { return $env:PRTGMOVER_WORKROOT.TrimEnd('\') }
    return (Join-Path $env:SystemDrive 'PrtgMover')
}

# ---------------------------------------------------------------- output helpers

function Write-PmLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP', 'DEBUG')][string]$Level = 'INFO')
    [pscustomobject]@{ PmType = 'log'; Level = $Level; Message = $Message; Time = (Get-Date).ToString('o'); Computer = $env:COMPUTERNAME }
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
        # PRTG 64-bit installs run the core from "<install dir>\64 bit\PRTG Server.exe" -
        # customisations (Custom Sensors, Notifications, lookups, cert...) live in the install dir itself.
        if ((Split-Path $info.ProgramPath -Leaf) -eq '64 bit') { $info.ProgramPath = Split-Path $info.ProgramPath -Parent }
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
        [int]$HealthTimeoutMinutes = 15,
        [bool]$IncludeProgram = $true,
        [bool]$IncludeLogs = $false,
        [bool]$IncludeAutoBackups = $false,
        # Stage directly into this folder (e.g. the manager's disk via \\tsclient) and skip zipping on the source.
        [string]$StageDir,
        [string]$LogDir,
        # WinRM pull mode: big folders are NOT copied here - the manager pulls them straight from the snapshot.
        [bool]$PullMode = $false,
        # StageDir is the other server (UNC over a tunnel). Nothing is written on the manager.
        [bool]$TunnelCopy = $false
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
    $modeText = if ($TunnelCopy) { 'direct copy to the other server over the tunnel (this manager is not in the path)' } elseif ($direct) { 'direct staging on the manager (no disk space used on this server)' } else { 'local staging + zip' }
    Write-PmLog "Mode: $modeText. Robocopy log: $(if ($global:PmRobocopyLog) { $global:PmRobocopyLog } else { 'off' })" 'DEBUG'

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
                        $w = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
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
        if ($TunnelCopy) { Write-PmLog ("Copy complete on the other server ({0:N2} GB). Nothing was stored on the manager." -f ($manifest.stagingBytes / 1GB)) 'OK' }
        else { Write-PmLog ("Staging complete on the manager ({0:N2} GB). The manager builds the package." -f ($manifest.stagingBytes / 1GB)) 'OK' }
        Write-PmProgress 80 'Staging done'
        return (New-PmResult @{ StageDir = $stage; Manifest = ($manifest | ConvertTo-Json -Depth 8); SourceHealth = $sourceHealth; TunnelCopy = [bool]$TunnelCopy })
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
        [bool]$CleanupStage = $false
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
        $drive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive)
        # Local stage + move: the data already occupies the disk, only a margin is needed.
        $required = if ($MoveFromStage) { [int64]1GB } else { [int64]($need * 1.1 + 1GB) }
        if ($drive -and $drive.FreeSpace -lt $required) { throw ("Not enough free space on {0}: {1:N1} GB free, {2:N1} GB required." -f $drive.DeviceID, ($drive.FreeSpace / 1GB), ($required / 1GB)) }
        Write-PmLog ("Reading the staged package from {0}. Disk space OK: {1:N1} GB free, ~{2:N1} GB needed." -f $stage, ($drive.FreeSpace / 1GB), ($required / 1GB)) 'OK'
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
        $root = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\')
        $xd = @($ExcludeDirs | Where-Object { $_ } | ForEach-Object { $_.TrimEnd('\') + '\' })
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $full = $f.FullName
            if (@($xd | Where-Object { $full.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
            if (@($ExcludeFiles | Where-Object { $f.Name -like $_ }).Count) { continue }
            if ($f.Name -in 'desktop.ini', 'Thumbs.db') { continue }   # Windows shell junk
            [void]$list.Add([pscustomobject]@{ Rel = $full.Substring($root.Length + 1); Size = $f.Length; Time = $f.LastWriteTimeUtc.Ticks })
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

# ---------------------------------------------------------------- tunnels (WireGuard now, IPIP uses the same address plan)

function Test-PmIPv4Address {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    return $Value -match '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$'
}

function Test-PmTunnelHost {
    <# A single host on the PRTG Mover tunnel network (never a default route). #>
    param([string]$Ip)
    if (-not (Test-PmIPv4Address $Ip)) { return $false }
    if ($Ip -notmatch '^10\.66\.66\.(\d+)$') { return $false }
    $n = [int]$Matches[1]
    return ($n -ge 1 -and $n -le 254)
}

function Get-PmTunnelAddresses {
    <# WireGuard uses 10.66.66.0/24. IPIP uses 10.66.67.0/24. Source is always .1. Split tunnel only. #>
    param(
        [Parameter(Mandatory)][int]$TargetCount,
        [ValidateSet('wireguard', 'ipip')][string]$Kind = 'wireguard'
    )
    if ($TargetCount -lt 1 -or $TargetCount -gt 250) { throw 'A tunnel needs between 1 and 250 target servers.' }
    $octet = if ($Kind -eq 'ipip') { 67 } else { 66 }
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($n in (2..($TargetCount + 1))) { $targets.Add("10.66.$octet.$n") }
    [pscustomobject]@{
        Source = "10.66.$octet.1"; Targets = $targets; Prefix = 24
        Port = $(if ($Kind -eq 'wireguard') { 51820 } else { 0 })
        Network = "10.66.$octet.0/24"; Kind = $Kind
    }
}

function Test-PmIpipHost {
    param([string]$Ip)
    if (-not (Test-PmIPv4Address $Ip)) { return $false }
    if ($Ip -notmatch '^10\.66\.67\.(\d+)$') { return $false }
    $n = [int]$Matches[1]
    return ($n -ge 1 -and $n -le 254)
}

function Test-PmTunnelShare {
    <# Admin share on either tunnel network, never a public address. #>
    param([string]$RemoteName)
    return [bool]($RemoteName -match '^\\\\10\.66\.6[67]\.\d+\\[^\\]+$')
}

function New-PmWireGuardConfigText {
    <#
        Split tunnel: AllowedIPs is only the other server's tunnel address (/32).
        A full tunnel (0.0.0.0/0) is refused - it would replace the server's default route.
    #>
    param(
        [Parameter(Mandatory)][string]$PrivateKey,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$ListenPort,
        [Parameter(Mandatory)][object[]]$Peers
    )
    if ($Address -notmatch '^(10\.66\.66\.\d+)/24$') { throw "Tunnel address '$Address' must be 10.66.66.x/24." }
    if (-not (Test-PmTunnelHost $Matches[1])) { throw "Tunnel address '$Address' is outside 10.66.66.1-254." }
    if ($ListenPort -lt 1 -or $ListenPort -gt 65535) { throw "Listen port $ListenPort is not valid." }
    if (@($Peers).Count -lt 1) { throw 'A WireGuard config needs the other server as a peer.' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('[Interface]')
    [void]$sb.AppendLine("PrivateKey = $PrivateKey")
    [void]$sb.AppendLine("Address = $Address")
    [void]$sb.AppendLine("ListenPort = $ListenPort")
    [void]$sb.AppendLine('')
    foreach ($p in @($Peers)) {
        $pub = [string]$p.PublicKey
        $tip = [string]$p.TunnelIp
        $eip = [string]$p.PublicIp
        if ([string]::IsNullOrWhiteSpace($pub)) { throw 'WireGuard peer is missing a public key.' }
        if (-not (Test-PmTunnelHost $tip)) { throw "Refusing peer '$tip'. AllowedIPs must be that server's tunnel address only, never 0.0.0.0/0." }
        if ([string]::IsNullOrWhiteSpace($eip) -or $eip -notmatch '^[A-Za-z0-9\.\-]+$') { throw 'WireGuard peer endpoint is missing.' }
        if ($eip -eq '0.0.0.0') { throw 'Refusing a full tunnel. The endpoint must be the other server.' }
        [void]$sb.AppendLine('[Peer]')
        [void]$sb.AppendLine("PublicKey = $pub")
        [void]$sb.AppendLine("AllowedIPs = $tip/32")
        [void]$sb.AppendLine("Endpoint = ${eip}:${ListenPort}")
        [void]$sb.AppendLine('PersistentKeepalive = 25')
        [void]$sb.AppendLine('')
    }
    $text = $sb.ToString().Trim() + "`r`n"
    if (-not (Test-PmTunnelConfigSafe $text)) { throw 'Refusing a WireGuard config that would change the default route.' }
    return $text
}

function Test-PmTunnelConfigSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)(^|[^\d])0\.0\.0\.0/0([^0-9]|$)') { return $false }
    if ($Text -match '::/0') { return $false }
    return $Text -match 'AllowedIPs = 10\.66\.66\.\d+/32'
}

function Hide-PmTunnelSecret {
    <# Drops WireGuard 'private key' lines before anything is logged or returned. #>
    param([string]$Text)
    if (-not $Text) { return '' }
    return (($Text -split "`r?`n") | Where-Object { $_ -notmatch '(?i)private\s*key' }) -join "`n"
}

function Get-PmWireGuardKeyDir { return 'C:\ProgramData\PrtgMover\wireguard' }

function Install-PmWireGuard {
    <# Installs the signed WireGuard MSI if needed and returns only the public key. #>
    $ErrorActionPreference = 'Stop'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'WireGuard needs 64-bit Windows.' }
    $wg = 'C:\Program Files\WireGuard\wg.exe'
    if (-not (Test-Path -LiteralPath $wg)) {
        Write-PmLog 'Installing WireGuard (split tunnel only; the default route is not changed).' 'STEP'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $msi = Join-Path $env:TEMP 'wireguard-amd64-1.1.msi'
        $url = 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.msi'
        $expected = '6DAA5D37A9E2950DFB8C48B95AB8E562CB2BAD1C785D020F38F97BEA4C6A5566'
        $ProgressPreference = 'SilentlyContinue'
        (New-Object System.Net.WebClient).DownloadFile($url, $msi)
        $hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
        if ($hash -ne $expected) { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue; throw "WireGuard installer hash mismatch ($hash)." }
        $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/i', $msi, '/qn', '/norestart', 'DO_NOT_LAUNCH=1') -Wait -PassThru
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "WireGuard install failed (msiexec $($p.ExitCode))." }
        if (-not (Test-Path -LiteralPath $wg)) { throw 'WireGuard installed but wg.exe is missing.' }
        Write-PmLog 'WireGuard installed.' 'OK'
    } else {
        Write-PmLog 'WireGuard is already installed.' 'OK'
    }
    $keyDir = Get-PmWireGuardKeyDir
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    $privFile = Join-Path $keyDir 'private.key'
    if (-not (Test-Path -LiteralPath $privFile)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $wg
        $psi.Arguments = 'genkey'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi)
        $priv = $proc.StandardOutput.ReadToEnd().Trim()
        $genErr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0 -or $priv.Length -lt 40) { throw "WireGuard key generation failed. $genErr" }
        [IO.File]::WriteAllText($privFile, $priv)
        & icacls.exe $privFile /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
    }
    $priv = [IO.File]::ReadAllText($privFile).Trim()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wg
    $psi.Arguments = 'pubkey'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($priv)
    $proc.StandardInput.Close()
    $pub = $proc.StandardOutput.ReadToEnd().Trim()
    $pubErr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0 -or $pub.Length -lt 40) { throw "WireGuard public key failed. $pubErr" }
    New-PmResult @{ PublicKey = $pub; Computer = $env:COMPUTERNAME; Installed = $true }
}

function Enable-PmWireGuardEndpoint {
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$ListenPort = 51820,
        [Parameter(Mandatory)][object[]]$Peers
    )
    $ErrorActionPreference = 'Stop'
    $privFile = Join-Path (Get-PmWireGuardKeyDir) 'private.key'
    if (-not (Test-Path -LiteralPath $privFile)) { throw 'WireGuard private key is missing. Install WireGuard on this server first.' }
    $priv = [IO.File]::ReadAllText($privFile).Trim()
    $text = New-PmWireGuardConfigText -PrivateKey $priv -Address $Address -ListenPort $ListenPort -Peers $Peers
    $hopBefore = ''
    $before = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    if ($before.Count) { $hopBefore = [string]$before[0].NextHop }

    $keyDir = Get-PmWireGuardKeyDir
    $conf = Join-Path $keyDir 'prtg.conf'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($conf, $text, $utf8)
    & icacls.exe $conf /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
    & icacls.exe $keyDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)(F)' 'Administrators:(OI)(CI)(F)' | Out-Null

    $peerIps = @($Peers | ForEach-Object { [string]$_.PublicIp } | Where-Object { $_ })
    foreach ($name in @('PrtgMover-WireGuard', 'PrtgMover-Tunnel-ICMP', 'PrtgMover-Tunnel-SMB')) {
        if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name }
    }
    New-NetFirewallRule -Name 'PrtgMover-WireGuard' -DisplayName 'PRTG Mover WireGuard' -Enabled True -Direction Inbound -Action Allow -Protocol UDP -LocalPort $ListenPort -RemoteAddress $peerIps -Profile Any | Out-Null
    New-NetFirewallRule -Name 'PrtgMover-Tunnel-ICMP' -DisplayName 'PRTG Mover tunnel ICMP' -Enabled True -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -RemoteAddress '10.66.66.0/24' -Profile Any | Out-Null
    New-NetFirewallRule -Name 'PrtgMover-Tunnel-SMB' -DisplayName 'PRTG Mover tunnel SMB' -Enabled True -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress '10.66.66.0/24' -Profile Any | Out-Null

    $ui = 'C:\Program Files\WireGuard\wireguard.exe'
    if (Get-Service -Name 'WireGuardTunnel$prtg' -ErrorAction SilentlyContinue) {
        $rm = Start-Process -FilePath $ui -ArgumentList @('/uninstalltunnelservice', 'prtg') -Wait -PassThru -WindowStyle Hidden
        if ($rm.ExitCode -ne 0) { throw "Could not update the WireGuard tunnel (exit $($rm.ExitCode))." }
        Start-Sleep -Seconds 2
    }
    $p = Start-Process -FilePath $ui -ArgumentList @('/installtunnelservice', $conf) -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw "WireGuard tunnel did not start (exit $($p.ExitCode))." }
    Start-Sleep -Seconds 2
    $after = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    $hopAfter = if ($after.Count) { [string]$after[0].NextHop } else { '' }
    if ($hopBefore -and $hopAfter -and $hopBefore -ne $hopAfter) {
        Start-Process -FilePath $ui -ArgumentList @('/uninstalltunnelservice', 'prtg') -Wait -WindowStyle Hidden | Out-Null
        throw "WireGuard changed the default gateway from $hopBefore to $hopAfter. The tunnel was removed."
    }
    $svc = Get-Service -Name 'WireGuardTunnel$prtg' -ErrorAction SilentlyContinue
    Write-PmLog "WireGuard is up on $Address (UDP $ListenPort, only the other server). Default gateway is still $hopAfter." 'OK'
    New-PmResult @{ Computer = $env:COMPUTERNAME; Address = $Address; Port = $ListenPort; Service = $(if ($svc) { [string]$svc.Status } else { 'missing' }); Gateway = $hopAfter }
}

function Test-PmWireGuardLink {
    param([Parameter(Mandatory)][string]$PeerTunnelIp)
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmTunnelHost $PeerTunnelIp)) { throw "Refusing to probe '$PeerTunnelIp'." }
    $raw = @(& 'C:\Program Files\WireGuard\wg.exe' show prtg 2>&1 | ForEach-Object { "$_" })
    $safe = Hide-PmTunnelSecret ($raw -join "`n")
    $handshake = $safe -match 'latest handshake'
    & ping.exe -n 2 -w 1000 $PeerTunnelIp | Out-Null
    $pingOk = ($LASTEXITCODE -eq 0)
    if ($pingOk) { Write-PmLog "Tunnel reachability: $PeerTunnelIp answers ($(if ($handshake) { 'handshake ok' } else { 'ping ok' }))." 'OK' }
    else { Write-PmLog "Tunnel reachability: $PeerTunnelIp did not answer ping." 'WARN' }
    New-PmResult @{ Peer = $PeerTunnelIp; PingOk = [bool]$pingOk; Handshake = [bool]$handshake }
}

function Connect-PmUncShare {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Passed once over the already-authenticated remoting session so the source can sign in to the target admin share. Never logged.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Required by WNetAddConnection2 for the tunnel file copy.')]
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmTunnelShare $RemoteName)) { throw 'The file share must be on the tunnel network (10.66.66.x or 10.66.67.x), not a public address.' }
    if (-not ('PmNetUse' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PmNetUse {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NETRESOURCE {
        public int dwScope;
        public int dwType;
        public int dwDisplayType;
        public int dwUsage;
        public string lpLocalName;
        public string lpRemoteName;
        public string lpComment;
        public string lpProvider;
    }
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetAddConnection2(ref NETRESOURCE nr, string password, string username, int flags);
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetCancelConnection2(string name, int flags, bool force);
}
'@
    }
    $nr = New-Object PmNetUse+NETRESOURCE
    $nr.dwType = 1
    $nr.lpRemoteName = $RemoteName
    [void][PmNetUse]::WNetCancelConnection2($RemoteName, 0, $true)
    $code = [PmNetUse]::WNetAddConnection2([ref]$nr, $Password, $UserName, 0)
    if ($code -ne 0) { throw "Could not sign in to $RemoteName (Windows error $code)." }
    Write-PmLog "Signed in to $RemoteName for the tunnel copy." 'OK'
    New-PmResult @{ RemoteName = $RemoteName; Ok = $true }
}

function Disconnect-PmUncShare {
    param([Parameter(Mandatory)][string]$RemoteName)
    if ('PmNetUse' -as [type]) { [void][PmNetUse]::WNetCancelConnection2($RemoteName, 0, $true) }
    New-PmResult @{ RemoteName = $RemoteName; Ok = $true }
}

function Test-PmTunnelPing {
    param([Parameter(Mandatory)][string]$PeerTunnelIp)
    $ErrorActionPreference = 'Stop'
    $onTunnel = (Test-PmTunnelHost $PeerTunnelIp) -or (Test-PmIpipHost $PeerTunnelIp)
    if (-not $onTunnel) { throw "Refusing to probe '$PeerTunnelIp'." }
    & ping.exe -n 2 -w 1000 $PeerTunnelIp | Out-Null
    $pingOk = ($LASTEXITCODE -eq 0)
    if ($pingOk) { Write-PmLog "Tunnel reachability: $PeerTunnelIp answers." 'OK' }
    else { Write-PmLog "Tunnel reachability: $PeerTunnelIp did not answer ping." 'WARN' }
    New-PmResult @{ Peer = $PeerTunnelIp; PingOk = [bool]$pingOk }
}

function Get-PmOutboundAddress {
    param([Parameter(Mandatory)][string]$Peer)
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        $client.Connect($Peer, 9)
        return [string]$client.Client.LocalEndPoint.Address
    } finally { $client.Dispose() }
}

function Install-PmIpip {
    <# Downloads the official Wintun build and compiles the IPIP tunnel program. #>
    param([Parameter(Mandatory)][string]$Code)
    $ErrorActionPreference = 'Stop'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'IPIP needs 64-bit Windows.' }
    if ($Code -notmatch 'class IpipTunnel') { throw 'IPIP source was not sent by the manager.' }
    $dir = 'C:\ProgramData\PrtgMover\ipip'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zipHash = '07C256185D6EE3652E09FA55C0B673E2624B565E02C4B9091C79CA7D2F24EF51'
    $dllHash = 'E5DA8447DC2C320EDC0FC52FA01885C103DE8C118481F683643CACC3220DAFCE'
    $dll = Join-Path $dir 'wintun.dll'
    if (-not (Test-Path -LiteralPath $dll) -or (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $dllHash) {
        Write-PmLog 'Downloading Wintun for the IPIP tunnel.' 'STEP'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $env:TEMP 'wintun-0.14.1.zip'
        $ProgressPreference = 'SilentlyContinue'
        (New-Object System.Net.WebClient).DownloadFile('https://www.wintun.net/builds/wintun-0.14.1.zip', $zip)
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $zipHash) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            throw 'Wintun download hash mismatch.'
        }
        $unpack = Join-Path $env:TEMP 'wintun-unpack'
        if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
        Copy-Item -LiteralPath (Join-Path $unpack 'wintun\bin\amd64\wintun.dll') -Destination $dll -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $dllHash) { throw 'wintun.dll hash mismatch.' }
        Write-PmLog 'Wintun is in place.' 'OK'
    }
    $cs = Join-Path $dir 'IpipTunnel.cs'
    $exe = Join-Path $dir 'IpipTunnel.exe'
    [IO.File]::WriteAllText($cs, $Code)
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw 'The .NET Framework compiler (csc.exe) is missing on this server.' }
    Get-Process -Name 'IpipTunnel' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $build = Start-Process -FilePath $csc -ArgumentList @('/nologo', '/platform:x64', '/optimize+', "/out:$exe", $cs) -Wait -PassThru -RedirectStandardOutput (Join-Path $dir 'build.out') -RedirectStandardError (Join-Path $dir 'build.err')
    if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        $err = ''
        if (Test-Path -LiteralPath (Join-Path $dir 'build.err')) { $err = (Get-Content -LiteralPath (Join-Path $dir 'build.err') -Raw -ErrorAction SilentlyContinue) }
        throw "IPIP program did not compile. $err"
    }
    Write-PmLog 'IPIP tunnel program is compiled.' 'OK'
    New-PmResult @{ Installed = $true; Computer = $env:COMPUTERNAME }
}

function Enable-PmIpipEndpoint {
    param(
        [Parameter(Mandatory)][string]$LocalTunnel,
        [Parameter(Mandatory)][object[]]$Peers
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmIpipHost $LocalTunnel)) { throw "IPIP address '$LocalTunnel' must be 10.66.67.1-254." }
    $dir = 'C:\ProgramData\PrtgMover\ipip'
    $exe = Join-Path $dir 'IpipTunnel.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'IPIP is not installed on this server yet.' }
    $peerIps = @()
    $lines = New-Object System.Collections.Generic.List[string]
    $firstPeer = $null
    foreach ($p in @($Peers)) {
        $tip = [string]$p.TunnelIp
        $eip = [string]$p.PublicIp
        if (-not (Test-PmIpipHost $tip)) { throw "Refusing IPIP peer '$tip'. The tunnel only carries 10.66.67.0/24." }
        if (-not (Test-PmIPv4Address $eip)) {
            $resolved = @([Net.Dns]::GetHostAddresses($eip) | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1)
            if ($resolved) { $eip = [string]$resolved[0] }
        }
        if (-not (Test-PmIPv4Address $eip)) { throw "IPIP peer endpoint '$($p.PublicIp)' must be an IPv4 address." }
        if (-not $firstPeer) { $firstPeer = $eip }
        $peerIps += $eip
        $lines.Add("peer=$tip,$eip")
    }
    if (-not $firstPeer) { throw 'IPIP needs the other server as a peer.' }
    $localPublic = Get-PmOutboundAddress -Peer $firstPeer
    $cfg = Join-Path $dir 'tunnel.txt'
    $text = "localTunnel=$LocalTunnel`r`nlocalPublic=$localPublic`r`n" + ($lines -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($cfg, $text)

    $hopBefore = ''
    $before = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    if ($before.Count) { $hopBefore = [string]$before[0].NextHop }

    foreach ($name in @('PrtgMover-IPIP', 'PrtgMover-IPIP-ICMP', 'PrtgMover-IPIP-SMB')) {
        if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name }
    }
    New-NetFirewallRule -Name 'PrtgMover-IPIP' -DisplayName 'PRTG Mover IPIP' -Enabled True -Direction Inbound -Action Allow -Protocol 4 -RemoteAddress $peerIps -Profile Any | Out-Null
    New-NetFirewallRule -Name 'PrtgMover-IPIP-ICMP' -DisplayName 'PRTG Mover IPIP ICMP' -Enabled True -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -RemoteAddress '10.66.67.0/24' -Profile Any | Out-Null
    New-NetFirewallRule -Name 'PrtgMover-IPIP-SMB' -DisplayName 'PRTG Mover IPIP SMB' -Enabled True -Direction Inbound -Action Allow -Protocol TCP -LocalPort 445 -RemoteAddress '10.66.67.0/24' -Profile Any | Out-Null

    $task = 'PRTG Mover IPIP'
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Get-Process -Name 'IpipTunnel' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $action = New-ScheduledTaskAction -Execute $exe -Argument "`"$cfg`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    $ready = Join-Path $dir 'ready.txt'
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $ready)) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path -LiteralPath $ready)) {
        $tail = ''
        $log = Join-Path $dir 'tunnel.log'
        if (Test-Path -LiteralPath $log) { $tail = (Get-Content -LiteralPath $log -Tail 15 -ErrorAction SilentlyContinue) -join ' | ' }
        throw "IPIP tunnel did not start. $tail"
    }
    Start-Sleep -Seconds 1
    $after = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    $hopAfter = if ($after.Count) { [string]$after[0].NextHop } else { '' }
    if ($hopBefore -and $hopAfter -and $hopBefore -ne $hopAfter) {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Get-Process -Name 'IpipTunnel' -ErrorAction SilentlyContinue | Stop-Process -Force
        throw "IPIP changed the default gateway from $hopBefore to $hopAfter. The tunnel was stopped."
    }
    Write-PmLog "IPIP is up on $LocalTunnel via $localPublic (protocol 4, only the other server). Default gateway is still $hopAfter." 'OK'
    New-PmResult @{ Computer = $env:COMPUTERNAME; Address = $LocalTunnel; Public = $localPublic; Gateway = $hopAfter }
}
