<#
    PrtgMover.psm1 - manager-side module.

    Runs on the "manager" machine. Opens PowerShell remoting sessions to source and
    target servers, ships src\Remote\PrtgMover.Remote.ps1 with every call, moves the
    backup package through the manager (so the manager always keeps a downloadable
    copy) and tracks everything as jobs that the web dashboard and CLI can follow.
#>

$script:PmRoot = Split-Path $PSScriptRoot -Parent
$script:PmRemoteCode = $null
$script:PmJobs = [hashtable]::Synchronized(@{})
$script:PmJobHandles = [hashtable]::Synchronized(@{})
$script:PmPool = $null

$script:PmBackupKeys = 'IncludePrtg', 'IncludeHistory', 'IncludeVpn', 'IncludeDesktop', 'ExtraPaths', 'SourceAfter', 'NoTouch', 'HealthTimeoutMinutes', 'IncludeProgram', 'IncludeLogs', 'IncludeAutoBackups'
$script:PmRestoreKeys = 'RestorePrtg', 'RestoreVpn', 'RestoreDesktop', 'RestoreExtra', 'InstallerArgs', 'AllowDowngrade', 'StartServices', 'HealthTimeoutMinutes', 'ConnectVpn', 'CopyLicense', 'OpenFirewall', 'MoveFromStage', 'CleanupStage', 'TargetAddress'

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
    <# Free space for a path. Uses Win32_LogicalDisk on Windows, .NET DriveInfo otherwise. #>
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

# ======================================================================= paths

function Set-PmRoot {
    param([Parameter(Mandatory)][string]$Path)
    $script:PmRoot = (Resolve-Path $Path).Path
}

function Get-PmPath {
    param([ValidateSet('Root', 'Backups', 'Data', 'Credentials', 'Jobs', 'Status', 'Installers', 'Config', 'Web', 'Remote')][string]$Name)
    $p = switch ($Name) {
        'Root'        { $script:PmRoot }
        'Backups'     { Join-Path $script:PmRoot 'backups' }
        'Data'        { Join-Path $script:PmRoot 'data' }
        'Credentials' { Join-Path $script:PmRoot 'data\credentials' }
        'Jobs'        { Join-Path $script:PmRoot 'data\jobs' }
        'Status'      { Join-Path $script:PmRoot 'data\status' }
        'Installers'  { Join-Path $script:PmRoot 'installers' }
        'Config'      { Join-Path $script:PmRoot 'config' }
        'Web'         { Join-Path (Split-Path $PSScriptRoot -Parent) 'web' }   # part of the program, not of the data root
        'Remote'      { Join-Path $PSScriptRoot 'Remote\PrtgMover.Remote.ps1' }   # part of the program, not of the data root
    }
    if ($Name -notin 'Root', 'Remote', 'Web' -and -not (Test-Path -LiteralPath $p)) { New-Item -ItemType Directory -Force -Path $p | Out-Null }
    return $p
}

function ConvertTo-PmHashtable {
    <# Converts PSCustomObject (from ConvertFrom-Json) to a hashtable, optionally keeping only $Keys. #>
    param($InputObject, [string[]]$Keys)
    $h = @{}
    if ($null -eq $InputObject) { return $h }
    if ($InputObject -is [hashtable]) { $src = $InputObject.GetEnumerator() | ForEach-Object { [pscustomobject]@{ Name = $_.Key; Value = $_.Value } } }
    else { $src = $InputObject.PSObject.Properties }
    foreach ($p in $src) {
        if ($Keys -and $p.Name -notin $Keys) { continue }
        $v = $p.Value
        if ($v -is [System.Array] -or $v -is [System.Collections.ArrayList]) { $v = [string[]]@($v) }
        $h[$p.Name] = $v
    }
    return $h
}

# ======================================================================= inventory

function Get-PmServers {
    $file = Join-Path (Get-PmPath Config) 'servers.json'
    if (-not (Test-Path -LiteralPath $file)) { return @() }
    $raw = Get-Content -LiteralPath $file -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    # PS 5.1 emits a JSON array as ONE object - ForEach-Object unrolls it into its elements.
    return @($raw | ConvertFrom-Json | ForEach-Object { $_ })
}

function Get-PmServer {
    param([Parameter(Mandatory)][string]$Id)
    $s = Get-PmServers | Where-Object { $_.id -eq $Id } | Select-Object -First 1
    if (-not $s) { throw "Server '$Id' not found in inventory." }
    return $s
}

function Save-PmServers {
    param([object[]]$Servers)
    $file = Join-Path (Get-PmPath Config) 'servers.json'
    ConvertTo-Json -InputObject @($Servers) -Depth 5 | Set-Content -LiteralPath $file -Encoding UTF8
}

function Set-PmServer {
    <# Adds or updates a server. Never stores passwords (see Save-PmCredential). #>
    param(
        [string]$Id,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$HostName,
        [int]$Port = 0,
        [bool]$UseSsl = $false,
        [bool]$SkipCaCheck = $false,
        [ValidateSet('Default', 'Negotiate', 'Kerberos', 'Basic', 'CredSSP')][string]$Authentication = 'Default',
        [string]$Role = 'both',
        [string]$Notes = '',
        [ValidateRange(1, 65535)][int]$RdpPort = 3389,
        [ValidateSet('rdp', 'winrm', 'wireguard', 'ipip', 'local')][string]$Transport = 'rdp'
    )
    if (-not $Id) { $Id = ([guid]::NewGuid().ToString('N')).Substring(0, 10) }
    $all = @(Get-PmServers | Where-Object { $_.id -ne $Id })
    $srv = [pscustomobject][ordered]@{
        id = $Id; name = $Name; host = $HostName; transport = $Transport; rdpPort = $RdpPort; port = $Port; useSsl = $UseSsl; skipCaCheck = $SkipCaCheck
        authentication = $Authentication; role = $Role; notes = $Notes
    }
    Save-PmServers -Servers ($all + $srv)
    return $srv
}

function Remove-PmServer {
    param([Parameter(Mandatory)][string]$Id)
    Save-PmServers -Servers @(Get-PmServers | Where-Object { $_.id -ne $Id })
    Remove-PmCredential -ServerId $Id
    Remove-Item -LiteralPath (Join-Path (Get-PmPath Status) "$Id.json") -Force -ErrorAction SilentlyContinue
}

# ======================================================================= credentials (DPAPI, current user + machine)

function Save-PmCredential {
    param([Parameter(Mandatory)][string]$ServerId, [Parameter(Mandatory)][pscredential]$Credential)
    $Credential | Export-Clixml -LiteralPath (Join-Path (Get-PmPath Credentials) "$ServerId.cred.xml")
}

function Get-PmCredential {
    param([Parameter(Mandatory)][string]$ServerId)
    $f = Join-Path (Get-PmPath Credentials) "$ServerId.cred.xml"
    if (Test-Path -LiteralPath $f) { return Import-Clixml -LiteralPath $f }
    return $null
}

function Test-PmCredential { param([string]$ServerId) Test-Path -LiteralPath (Join-Path (Get-PmPath Credentials) "$ServerId.cred.xml") }

function Remove-PmCredential {
    param([Parameter(Mandatory)][string]$ServerId)
    Remove-Item -LiteralPath (Join-Path (Get-PmPath Credentials) "$ServerId.cred.xml") -Force -ErrorAction SilentlyContinue
}

function New-PmCredential {
    <#
        Builds a PSCredential from the dashboard form. The password arrives once over the
        localhost API; it is turned into a SecureString immediately and
        only ever persisted DPAPI-encrypted (Save-PmCredential).
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Entry point for the web form; converted to SecureString immediately.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Entry point for the web form; converted to SecureString immediately.')]
    param([Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][string]$Password)
    $secure = New-Object System.Security.SecureString
    foreach ($ch in $Password.ToCharArray()) { $secure.AppendChar($ch) }
    $secure.MakeReadOnly()
    New-Object System.Management.Automation.PSCredential($UserName, $secure)
}

# ======================================================================= network / RDP

function Test-PmTcpPort {
    param([Parameter(Mandatory)][string]$HostName, [Parameter(Mandatory)][int]$Port, [int]$TimeoutMs = 3000)
    $c = New-Object Net.Sockets.TcpClient
    try { return [bool]$c.ConnectAsync($HostName, $Port).Wait($TimeoutMs) } catch { return $false } finally { $c.Dispose() }
}

function Get-PmWinRmPort {
    param([Parameter(Mandatory)]$Server)
    if ([int]$Server.port -gt 0) { return [int]$Server.port }
    if ($Server.useSsl) { return 5986 } else { return 5985 }
}

function Get-PmRdpPort {
    param([Parameter(Mandatory)]$Server)
    if ($Server.PSObject.Properties['rdpPort'] -and [int]$Server.rdpPort -gt 0) { return [int]$Server.rdpPort }
    return 3389
}

function Get-PmTransport {
    <# Command channel: 'rdp' or 'winrm'. A saved WireGuard or IPIP method still sends commands over RDP. #>
    param([Parameter(Mandatory)]$Server)
    if ($Server.PSObject.Properties['transport'] -and $Server.transport -eq 'winrm') { return 'winrm' }
    if ($Server.PSObject.Properties['transport'] -and $Server.transport -eq 'local') { return 'local' }
    return 'rdp'
}

function Resolve-PmTunnelFromServers {
    <# The tunnel saved on the selected servers, when the job did not pick a path itself. #>
    param([object[]]$Servers)
    $modes = @($Servers | ForEach-Object {
            if ($_ -and $_.PSObject.Properties['transport'] -and $_.transport -in 'wireguard', 'ipip') { [string]$_.transport }
        } | Where-Object { $_ } | Select-Object -Unique)
    if ($modes.Count -gt 1) { throw 'The selected servers do not use the same tunnel. Choose WireGuard or IPIP under How the files move for this job.' }
    if ($modes.Count -eq 1) { return [string]$modes[0] }
    return ''
}

function Copy-PmServerTransport {
    <# One job can force RDP or WinRM without changing the saved server. #>
    param($Server, [string]$Transport)
    if (-not $Server -or $Transport -notin 'rdp', 'winrm', 'local') { return $Server }
    $h = [ordered]@{}
    foreach ($p in $Server.PSObject.Properties) { $h[$p.Name] = $p.Value }
    $h['transport'] = $Transport
    return [pscustomobject]$h
}

function Get-PmJobServer {
    param($Server, [hashtable]$Options)
    $t = ''
    if ($Options -and $Options.ContainsKey('Transfer') -and $Options.Transfer) { $t = [string]$Options.Transfer }
    if ($t -in 'rdp', 'winrm') { return Copy-PmServerTransport -Server $Server -Transport $t }
    return $Server
}

function Assert-PmTransferSelection {
    param([string]$Transfer, [string]$JobType, [int]$TargetCount)
    if ([string]::IsNullOrWhiteSpace($Transfer)) { return }
    if ($Transfer -notin 'rdp', 'winrm', 'wireguard', 'ipip') { throw "Unknown transfer '$Transfer'. Use rdp, winrm, wireguard, or ipip." }
    if ($Transfer -in 'wireguard', 'ipip' -and ($JobType -ne 'migrate' -or $TargetCount -lt 1)) {
        throw 'A tunnel copies directly between two Windows servers. Choose a source and a target. RDP and WinRM are what copy through this computer.'
    }
}

function Test-PmServerPorts {
    <# Quick TCP reachability of WinRM and RDP from the manager. #>
    param([Parameter(Mandatory)]$Server)
    $w = Get-PmWinRmPort $Server; $r = Get-PmRdpPort $Server
    [pscustomobject]@{
        winrmPort = $w; winrm = (Test-PmTcpPort -HostName $Server.host -Port $w)
        rdpPort = $r; rdp = (Test-PmTcpPort -HostName $Server.host -Port $r)
        checked = (Get-Date).ToString('o')
    }
}

# ----------------------------------------------------------------------- RDP agent

function Get-PmAgentDir {
    param([Parameter(Mandatory)][string]$ServerId)
    $d = Join-Path (Get-PmPath Data) "agent\$ServerId"
    foreach ($x in $d, (Join-Path $d 'requests'), (Join-Path $d 'responses')) { if (-not (Test-Path -LiteralPath $x)) { New-Item -ItemType Directory -Force -Path $x | Out-Null } }
    return $d
}

function Get-PmTsClientRoot {
    <# The manager folder as seen from inside an RDP session with drive redirection: \\tsclient\F\path #>
    # Tests / special setups: the agent sees the manager folder under another path.
    if ($env:PRTGMOVER_TSCLIENT_ROOT) { return $env:PRTGMOVER_TSCLIENT_ROOT.TrimEnd('\') }
    $root = Get-PmPath Root
    if ($root -notmatch '^([A-Za-z]):\\?(.*)$') { throw "RDP mode needs PRTG Mover on a local drive (current: $root)." }
    $rest = $Matches[2].TrimEnd('\')
    if ($rest) { return "\\tsclient\$($Matches[1].ToUpper())\$rest" }
    return "\\tsclient\$($Matches[1].ToUpper())"
}

function Get-PmAgentCommand {
    param([Parameter(Mandatory)]$Server)
    $script = Join-Path (Get-PmTsClientRoot) 'agent\PrtgMover-Agent.ps1'
    return "powershell -NoProfile -ExecutionPolicy Bypass -File `"$script`" -ServerId $($Server.id)"
}

function Get-PmAgentStatus {
    <# Heartbeat of the agent (fresh = written in the last 30 s). #>
    param([Parameter(Mandatory)][string]$ServerId)
    # heartbeat.json, or heartbeat.json.tmp when a redirected drive refused the rename - use the newer one.
    $dir = Join-Path (Get-PmPath Data) "agent\$ServerId"
    $f = Get-ChildItem -LiteralPath $dir -Filter 'heartbeat.json*' -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1 -ExpandProperty FullName
    if (-not $f) { return [pscustomobject]@{ connected = $false } }
    try {
        # The agent rewrites the file every 5 s - retry until a complete JSON document is read.
        $hb = $null
        for ($i = 0; $i -lt 10 -and -not ($hb -and $hb.computer); $i++) {
            try { $hb = [IO.File]::ReadAllText($f) | ConvertFrom-Json } catch { $hb = $null }
            if (-not ($hb -and $hb.computer)) { Start-Sleep -Milliseconds 150 }
        }
        if (-not ($hb -and $hb.computer)) { return [pscustomobject]@{ connected = $false; unreadable = $true } }
        # Age from the manager's own file timestamp - the server clock may be skewed.
        $age = ((Get-Date).ToUniversalTime() - (Get-Item -LiteralPath $f).LastWriteTimeUtc).TotalSeconds
        [pscustomobject]@{ connected = ($age -lt 30); ageSeconds = [int]$age; computer = $hb.computer; user = $hb.user; isAdmin = $hb.isAdmin; state = $hb.state; task = $hb.task; version = $hb.version }
    } catch { [pscustomobject]@{ connected = $false } }
}

function Start-PmRdp {
    <#
        Opens Remote Desktop to the server from the manager (mstsc). The drive holding
        PRTG Mover is redirected into the session, so the agent can be started from
        \\tsclient\... . The password is never written; Windows asks for it.
    #>
    param([Parameter(Mandatory)]$Server)
    $user = $null
    $cred = Get-PmCredential -ServerId $Server.id
    if ($cred) { $user = $cred.UserName }
    $dir = Join-Path (Get-PmPath Data) 'rdp'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $file = Join-Path $dir "$($Server.id).rdp"
    $drive = (Split-Path (Get-PmPath Root) -Qualifier) + '\'
    $lines = @(
        "full address:s:$($Server.host):$(Get-PmRdpPort $Server)"
        'prompt for credentials:i:1'
        'authentication level:i:2'
        'screen mode id:i:1'
        'desktopwidth:i:1600'
        'desktopheight:i:900'
        'redirectclipboard:i:1'
        "drivestoredirect:s:$drive;"
        # keep the session (and the redirected drive) alive through short network drops
        'autoreconnection enabled:i:1'
        'autoreconnect max retries:i:200'
        'networkautodetect:i:1'
        'bandwidthautodetect:i:1'
        'connection type:i:7'
    )
    if ($user) { $lines += "username:s:$user" }
    Set-Content -LiteralPath $file -Value $lines -Encoding Unicode
    Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\mstsc.exe') -ArgumentList "`"$file`""
    return $file
}

function Wait-PmAgent {
    param([Parameter(Mandatory)]$Server, $Job, [int]$TimeoutMinutes = 45)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $next = Get-Date
    while ($true) {
        $st = Get-PmAgentStatus -ServerId $Server.id
        if ($st.connected) {
            if (-not $st.isAdmin -and $env:PRTGMOVER_TEST -ne '1') { throw "Agent on $($Server.name) is not elevated - start PowerShell with 'Run as Administrator'." }
            Add-PmJobLog -Job $Job -Level OK -Message "Agent connected on $($Server.name) ($($st.computer), $($st.user), agent v$($st.version))."
            $mv = ''; $vf = Join-Path (Get-PmPath Root) 'VERSION'; if (Test-Path $vf) { $mv = ([IO.File]::ReadAllText($vf)).Trim() }
            if ($mv -and $st.version -and $st.version -ne $mv) {
                Add-PmJobLog -Job $Job -Level WARN -Message "The agent on $($Server.name) is v$($st.version), the manager is v$mv. The payload is reloaded automatically, but restart the agent window (close it and run the command again) to get all agent fixes."
            }
            return $st
        }
        if ((Get-Date) -ge $deadline) { throw "The agent on $($Server.name) did not connect within $TimeoutMinutes minutes." }
        if ((Get-Date) -ge $next) {
            Add-PmJobLog -Job $Job -Level WARN -Message "Waiting for the agent on $($Server.name): click 'RDP' in the dashboard, log in, open PowerShell as Administrator and run:  $(Get-PmAgentCommand $Server)"
            Set-PmJobProgress -Job $Job -Percent $(if ($Job) { $Job.progress } else { 0 }) -Step "Waiting for agent on $($Server.name)"
            $next = (Get-Date).AddMinutes(2)
        }
        Start-Sleep -Seconds 2
    }
}

# ======================================================================= sessions (WinRM or RDP agent)

function New-PmSession {
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, $Job)
    if ((Get-PmTransport $Server) -eq 'local') { return [pscustomobject]@{ PmLocal = $true; Server = $Server } }
    if ((Get-PmTransport $Server) -eq 'rdp') {
        $st = Wait-PmAgent -Server $Server -Job $Job
        return [pscustomobject]@{ PmAgent = $true; Server = $Server; Dir = (Get-PmAgentDir -ServerId $Server.id); Computer = $st.computer }
    }
    $optParams = @{ OperationTimeout = 14400000; IdleTimeout = 14400000; OpenTimeout = 60000 }
    if ($Server.skipCaCheck) { $optParams.SkipCACheck = $true; $optParams.SkipCNCheck = $true; $optParams.SkipRevocationCheck = $true }
    $p = @{ ComputerName = $Server.host; SessionOption = (New-PSSessionOption @optParams); ErrorAction = 'Stop' }
    if ([int]$Server.port -gt 0) { $p.Port = [int]$Server.port }
    if ($Server.useSsl) { $p.UseSSL = $true }
    if ($Server.authentication -and $Server.authentication -ne 'Default') { $p.Authentication = $Server.authentication }
    if ($Credential) { $p.Credential = $Credential }
    # A fresh self-signed certificate looks "expired" (not yet valid) when this manager's clock is
    # behind the server's. Wait until it becomes valid instead of failing (sync the clock to skip the wait).
    $deadline = (Get-Date).AddMinutes(40); $warned = $false
    while ($true) {
        try { return (New-PSSession @p) }
        catch {
            if ($_.Exception.Message -notmatch 'certificate.*(expired|not yet valid)|SSL certificate is expired' -or (Get-Date) -gt $deadline) { throw }
            if (-not $warned) {
                $skew = ''
                try { $d = [datetime]::Parse((Invoke-WebRequest 'https://github.com' -Method Head -UseBasicParsing -TimeoutSec 10).Headers['Date']).ToUniversalTime(); $skew = ' (this manager is {0:N0} min behind the internet time)' -f ((((Get-Date).ToUniversalTime() - $d).TotalMinutes) * -1) } catch { }
                Add-PmJobLog -Job $Job -Level WARN -Message "The HTTPS certificate of $($Server.name) is not valid yet from this manager's point of view - the manager clock is behind$skew. Waiting until it becomes valid (up to 40 min). Syncing the Windows clock ends the wait immediately."
                $warned = $true
            }
            Start-Sleep -Seconds 30
        }
    }
}

function Close-PmSession {
    param($Session)
    if (-not $Session) { return }
    if ($Session.PSObject.Properties['PmAgent']) { return }   # the agent keeps running for the next call
    if ($Session.PSObject.Properties['PmLocal']) { return }
    Remove-PSSession $Session -ErrorAction SilentlyContinue
}

function Get-PmRemoteCode {
    if (-not $script:PmRemoteCode) { $script:PmRemoteCode = Get-Content -LiteralPath (Get-PmPath Remote) -Raw -Encoding UTF8 }
    return $script:PmRemoteCode
}

function Receive-PmRecord {
    <# Dispatches one streamed record (log / progress / result / error) into the job. #>
    param($Record, $Job, [int]$ProgressBase, [double]$ProgressSpan, [hashtable]$Box)
    switch ($Record.PmType) {
        'log'      { Add-PmJobLog -Job $Job -Level $Record.Level -Message $Record.Message -Computer $Record.Computer }
        'progress' { if ($ProgressSpan -gt 0) { Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]($Record.Percent * $ProgressSpan / 100)) -Step "$($Record.Computer): $($Record.Step)" } }
        'result'   { $Box.Result = $Record }
        'error'    { $Box.Error = $Record.Message }
        'done'     { $Box.Done = $true }
    }
}

function Invoke-PmAgentCallOnce {
    <# One request/response round trip. Returns @{ Lost = $true } when the agent disappears. #>
    param($Session, [string]$Function, [hashtable]$Parameters, $Job, [int]$ProgressBase, [double]$ProgressSpan)
    $id = [guid]::NewGuid().ToString('N')
    $req = Join-Path $Session.Dir "requests\$id.json"
    $resp = Join-Path $Session.Dir "responses\$id.jsonl"
    ConvertTo-Json -InputObject ([ordered]@{ id = $id; fn = $Function; params = $Parameters }) -Depth 8 | Set-Content -LiteralPath "$req.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$req.tmp" -Destination $req -Force
    Add-PmJobLog -Job $Job -Level DEBUG -Message "Agent request $id -> $($Session.Server.name): $Function"

    $box = @{ Result = $null; Error = $null; Done = $false; Lost = $false }
    $pos = 0L; $pending = ''
    $lastBeat = Get-Date
    $picked = $false
    while (-not $box.Done) {
        $fs = $null
        if (Test-Path -LiteralPath $resp) {
            $picked = $true
            try { $fs = New-Object IO.FileStream($resp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite) } catch { $fs = $null }
        }
        if ($fs) {
            try {
                if ($fs.Length -gt $pos) {
                    [void]$fs.Seek($pos, 'Begin')
                    $buf = New-Object byte[] ($fs.Length - $pos)
                    $read = $fs.Read($buf, 0, $buf.Length)
                    $pos += $read
                    $pending += [Text.Encoding]::UTF8.GetString($buf, 0, $read)
                }
            } finally { $fs.Dispose() }
            while ($pending.Contains("`n")) {
                $i = $pending.IndexOf("`n")
                $line = $pending.Substring(0, $i).Trim([char]0xFEFF, "`r", ' ')
                $pending = $pending.Substring($i + 1)
                if ($line) {
                    try { Receive-PmRecord -Record ($line | ConvertFrom-Json) -Job $Job -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan -Box $box }
                    catch { Add-PmJobLog -Job $Job -Level DEBUG -Message "Unreadable agent line ignored: $($line.Substring(0, [Math]::Min(200, $line.Length)))" }
                }
            }
        }
        if ($box.Done) { break }
        $st = Get-PmAgentStatus -ServerId $Session.Server.id
        if ($st.connected) { $lastBeat = Get-Date }
        elseif (((Get-Date) - $lastBeat).TotalSeconds -gt 90) {
            # Do not let a new agent execute this request later - park it.
            foreach ($x in $req, "$req.working") { if (Test-Path -LiteralPath $x) { Move-Item -LiteralPath $x -Destination "$req.abandoned" -Force -ErrorAction SilentlyContinue } }
            Add-PmJobLog -Job $Job -Level DEBUG -Message "Agent request $id abandoned (picked up: $picked, last heartbeat $([int]((Get-Date) - $lastBeat).TotalSeconds) s ago)"
            return @{ Lost = $true }
        }
        Start-Sleep -Milliseconds 500
    }
    Remove-Item -LiteralPath $resp -Force -ErrorAction SilentlyContinue
    return $box
}

function Invoke-PmAgentCall {
    <#
        File-based RPC with the agent. If the agent disappears (RDP session dropped, window
        closed, server IP changed) the call waits up to 30 minutes for an agent to come back
        on that server and then sends the request again (up to 3 times). The steps are
        idempotent (backup re-stages, restore re-applies), so a repeat is safe.
    #>
    param($Session, [string]$Function, [hashtable]$Parameters, $Job, [int]$ProgressBase, [double]$ProgressSpan)
    for ($attempt = 1; $attempt -le 4; $attempt++) {
        $box = Invoke-PmAgentCallOnce -Session $Session -Function $Function -Parameters $Parameters -Job $Job -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan
        if (-not $box.Lost) {
            if ($box.Error) { throw "[$($Session.Server.name)] $($box.Error)" }
            return $box.Result
        }
        if ($attempt -eq 4) { break }
        Add-PmJobLog -Job $Job -Level WARN -Message "Lost the agent on $($Session.Server.name) during '$Function' (RDP session dropped or agent window closed). Waiting up to 30 min for it to come back - reconnect with the RDP button and run the agent command again. The step will be repeated automatically (attempt $($attempt + 1) of 4)."
        [void](Wait-PmAgent -Server $Session.Server -Job $Job -TimeoutMinutes 30)
    }
    throw "The agent on $($Session.Server.name) was lost repeatedly during '$Function'. Press RESUME when the RDP session is stable."
}
function Invoke-PmRemote {
    <#
        Executes one function of PrtgMover.Remote.ps1 on the server (WinRM session or RDP
        agent), streaming its log / progress records into $Job. Returns the 'result' record.
    #>
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Function,
        [hashtable]$Parameters = @{},
        $Job,
        [int]$ProgressBase = 0,
        [double]$ProgressSpan = 0
    )
    if ($Session.PSObject.Properties['PmAgent']) {
        return Invoke-PmAgentCall -Session $Session -Function $Function -Parameters $Parameters -Job $Job -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan
    }
    $code = "param(`$PmFn, `$PmParams)`r`n" + (Get-PmRemoteCode) + "`r`n& `$PmFn @PmParams`r`n"
    $sb = [scriptblock]::Create($code)
    $box = @{ Result = $null; Error = $null; Done = $false }
    if ($Session.PSObject.Properties['PmLocal']) {
        & $sb $Function $Parameters | ForEach-Object { Receive-PmRecord -Record $_ -Job $Job -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan -Box $box }
        return $box.Result
    }
    Invoke-Command -Session $Session -ScriptBlock $sb -ArgumentList $Function, $Parameters -ErrorAction Stop | ForEach-Object {
        Receive-PmRecord -Record $_ -Job $Job -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan -Box $box
    }
    return $box.Result
}

function Get-PmManagerRelative {
    param([Parameter(Mandatory)][string]$LocalPath)
    $root = (Get-PmPath Root).TrimEnd('\').TrimEnd('/').Replace('/', '\')
    $full = [IO.Path]::GetFullPath($LocalPath).TrimEnd('\').TrimEnd('/').Replace('/', '\')
    $inside = $full.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or $full.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)
    if (-not $inside) { throw "$LocalPath is outside the PRTG Mover folder." }
    return $full.Substring($root.Length).TrimStart('\')
}

function Copy-PmFromServer {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$RemotePath, [Parameter(Mandatory)][string]$LocalPath, $Job)
    if ($Session.PSObject.Properties['PmAgent']) {
        [void](Invoke-PmAgentCall -Session $Session -Function 'Send-PmAgentFile' -Parameters @{ Source = $RemotePath; ManagerRelative = (Get-PmManagerRelative $LocalPath) } -Job $Job)
    } elseif ($Session.PSObject.Properties['PmLocal']) {
        Copy-Item -LiteralPath $RemotePath -Destination $LocalPath -Force -ErrorAction Stop
    } else {
        Copy-Item -FromSession $Session -Path $RemotePath -Destination $LocalPath -Force -ErrorAction Stop
    }
}

function Copy-PmToServer {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$LocalPath, [Parameter(Mandatory)][string]$RemotePath, $Job)
    if ($Session.PSObject.Properties['PmAgent']) {
        [void](Invoke-PmAgentCall -Session $Session -Function 'Receive-PmAgentFile' -Parameters @{ ManagerRelative = (Get-PmManagerRelative $LocalPath); Destination = $RemotePath } -Job $Job)
    } elseif ($Session.PSObject.Properties['PmLocal']) {
        Copy-Item -LiteralPath $LocalPath -Destination $RemotePath -Force -ErrorAction Stop
    } else {
        Copy-Item -ToSession $Session -Path $LocalPath -Destination $RemotePath -Force -ErrorAction Stop
    }
}

function Resolve-PmCredential {
    param([Parameter(Mandatory)]$Server, [hashtable]$OneTime)
    if ($OneTime -and $OneTime.ContainsKey($Server.id) -and $OneTime[$Server.id]) { return $OneTime[$Server.id] }
    return Get-PmCredential -ServerId $Server.id   # $null -> current Windows identity (domain / Kerberos)
}

# ======================================================================= backups catalogue

function Get-PmBackups {
    $dir = Get-PmPath Backups
    Get-ChildItem -LiteralPath $dir -Filter '*.zip' -File | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $meta = $null
        $side = "$($_.FullName).meta.json"
        if (Test-Path -LiteralPath $side) { $meta = Get-Content -LiteralPath $side -Raw -Encoding UTF8 | ConvertFrom-Json }
        [pscustomobject]@{
            name     = $_.Name
            size     = $_.Length
            created  = $_.LastWriteTime.ToString('o')
            source   = if ($meta) { $meta.source } else { $null }
            sha256   = if ($meta) { $meta.sha256 } else { $null }
            manifest = if ($meta) { $meta.manifest } else { $null }
        }
    }
}

function Get-PmBackupFile {
    <# Resolves a backup name to a full path, refusing anything outside the backups folder. #>
    param([Parameter(Mandatory)][string]$Name)
    $leaf = Split-Path $Name -Leaf
    if ($leaf -ne $Name -or $leaf -notmatch '\.zip$') { throw "Invalid backup name '$Name'." }
    $full = Join-Path (Get-PmPath Backups) $leaf
    if (-not (Test-Path -LiteralPath $full)) { throw "Backup '$Name' not found." }
    return $full
}

function Read-PmBackupManifest {
    param([Parameter(Mandatory)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq 'manifest.json' } | Select-Object -First 1
        if (-not $entry) { return $null }
        $reader = New-Object IO.StreamReader($entry.Open())
        try { return ($reader.ReadToEnd() | ConvertFrom-Json) } finally { $reader.Dispose() }
    } finally { $zip.Dispose() }
}

function Register-PmBackup {
    <# Writes the sidecar metadata used by the dashboard (also used for uploaded backups). #>
    param([Parameter(Mandatory)][string]$ZipPath, [string]$Source)
    $manifest = Read-PmBackupManifest -ZipPath $ZipPath
    if (-not $manifest) { throw 'The file is not a PRTG Mover backup (manifest.json missing).' }
    if (-not $Source) { $Source = $manifest.source.computer }
    [pscustomobject]@{
        source   = $Source
        sha256   = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
        manifest = $manifest
    } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$ZipPath.meta.json" -Encoding UTF8
}

function Remove-PmBackup {
    param([Parameter(Mandatory)][string]$Name)
    $f = Get-PmBackupFile -Name $Name
    Remove-Item -LiteralPath $f, "$f.meta.json" -Force -ErrorAction SilentlyContinue
}

# ======================================================================= flows

function Get-PmConnectHint {
    param([string]$Message, $Ports)
    if ($Ports -and -not $Ports.winrm) {
        return "WinRM port $($Ports.winrmPort) is not reachable. Use the RDP connection method, or enable remoting on the server (tools\Enable-PrtgMoverRemoting.ps1) and open the firewall for the manager."
    }
    if ($Message -match 'TrustedHosts') { return 'The manager must trust this IP for WinRM: run tools\Setup-Manager.ps1 -TrustedHosts <ip> in an elevated PowerShell on the manager (or use the RDP connection method).' }
    if ($Message -match 'Access is denied|access denied') { return 'Credential rejected or not an administrator. Use HOST\Administrator (or .\Administrator) and check LocalAccountTokenFilterPolicy.' }
    if ($Message -match 'WinRM.*service|cannot process the request') { return 'Start the WinRM service on the manager (tools\Setup-Manager.ps1, elevated).' }
    return $null
}

# ======================================================================= diagnostics / audit logging

function Write-PmManagerLog {
    <# Daily manager log (data\logs\manager-yyyyMMdd.log): API calls, errors with stack traces, job warnings. #>
    param([string]$Level = 'INFO', [Parameter(Mandatory)][string]$Message, [string]$Source = 'manager')
    try {
        $dir = Join-Path (Get-PmPath Data) 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $line = '{0} [{1,-5}] {2}: {3}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff'), $Level, $Source, $Message
        $file = Join-Path $dir ('manager-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
        for ($i = 0; $i -lt 10; $i++) { try { [IO.File]::AppendAllText($file, $line + "`r`n", [Text.Encoding]::UTF8); break } catch { Start-Sleep -Milliseconds 30 } }
    } catch { }
}

function Write-PmAudit {
    <# Audit trail (data\logs\audit.log, JSON lines): who changed what and when. Never contains passwords. #>
    param([Parameter(Mandatory)][string]$Action, [hashtable]$Data = @{})
    try {
        $dir = Join-Path (Get-PmPath Data) 'logs'
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
        $rec = [ordered]@{ time = (Get-Date).ToString('o'); user = "$env:USERDOMAIN\$env:USERNAME"; action = $Action; data = $Data }
        [IO.File]::AppendAllText((Join-Path $dir 'audit.log'), (ConvertTo-Json -InputObject $rec -Compress -Depth 5) + "`r`n", [Text.Encoding]::UTF8)
        Write-PmManagerLog -Level 'AUDIT' -Message "$Action $(ConvertTo-Json -InputObject $Data -Compress -Depth 4)"
    } catch { }
}

function Format-PmManagerError {
    param($ErrorRecord)
    $pos = ''
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber) {
        $pos = " [{0}:{1}]" -f (Split-Path $ErrorRecord.InvocationInfo.ScriptName -Leaf), $ErrorRecord.InvocationInfo.ScriptLineNumber
    }
    return "$($ErrorRecord.Exception.Message)$pos"
}

function Add-PmJobError {
    <# Logs a failure with its exact position and stack (DEBUG) into the job and the manager log. #>
    param($Job, $ErrorRecord, [string]$Context)
    Add-PmJobLog -Job $Job -Level ERROR -Message "$Context$(Format-PmManagerError $ErrorRecord)"
    if ($ErrorRecord.ScriptStackTrace) { Add-PmJobLog -Job $Job -Level DEBUG -Message "Stack: $($ErrorRecord.ScriptStackTrace -replace '\r?\n', ' <- ')" }
}

function New-PmDiagnosticsBundle {
    <#
        Collects everything needed to analyse a problem into one zip (no passwords, no token):
        manager/audit logs, recent job records + logs, agent logs + heartbeats, robocopy logs,
        server inventory, last test results and an environment report.
    #>
    $diagDir = Join-Path (Get-PmPath Data) 'diag'
    if (-not (Test-Path -LiteralPath $diagDir)) { New-Item -ItemType Directory -Force -Path $diagDir | Out-Null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $tmp = Join-Path $diagDir "diag-$stamp"
    New-Item -ItemType Directory -Force -Path $tmp | Out-Null
    $data = Get-PmPath Data
    $copy = {
        param($From, $To)
        if (Test-Path -LiteralPath $From) { New-Item -ItemType Directory -Force -Path (Split-Path $To -Parent) | Out-Null; Copy-Item -LiteralPath $From -Destination $To -Recurse -Force -ErrorAction SilentlyContinue }
    }
    & $copy (Join-Path $data 'logs') (Join-Path $tmp 'logs')
    & $copy (Join-Path $data 'status') (Join-Path $tmp 'status')
    & $copy (Join-Path (Get-PmPath Config) 'servers.json') (Join-Path $tmp 'config\servers.json')
    $jobs = Join-Path $tmp 'jobs'; New-Item -ItemType Directory -Force -Path $jobs | Out-Null
    Get-ChildItem -LiteralPath (Get-PmPath Jobs) -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 60 | Copy-Item -Destination $jobs -Force
    foreach ($a in (Get-ChildItem -LiteralPath (Join-Path $data 'agent') -Directory -ErrorAction SilentlyContinue)) {
        $dst = Join-Path $tmp "agent\$($a.Name)"; New-Item -ItemType Directory -Force -Path $dst | Out-Null
        Get-ChildItem -LiteralPath $a.FullName -File -ErrorAction SilentlyContinue | Copy-Item -Destination $dst -Force
        Get-ChildItem -LiteralPath (Join-Path $a.FullName 'requests') -File -ErrorAction SilentlyContinue | Copy-Item -Destination (New-Item -ItemType Directory -Force -Path (Join-Path $dst 'requests')).FullName -Force
    }
    $env = New-Object System.Text.StringBuilder
    $add = { param($k, $v) [void]$env.AppendLine(('{0,-26}: {1}' -f $k, $v)) }
    & $add 'Created' (Get-Date).ToString('o')
    & $add 'PRTG Mover version' ((Get-Content (Join-Path (Get-PmPath Root) 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1))
    & $add 'Manager' "$env:COMPUTERNAME ($env:USERDOMAIN\$env:USERNAME)"
    & $add 'OS' (Get-PmOsCaption)
    & $add 'PowerShell' $PSVersionTable.PSVersion
    & $add '.NET release' ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release)
    $admin = $false
    try {
        $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $admin = $false }
    & $add 'Manager elevated' $admin
    $winrm = $null
    if (Get-Command Get-Service -ErrorAction SilentlyContinue) { $winrm = (Get-Service WinRM -ErrorAction SilentlyContinue).Status }
    & $add 'WinRM service' $winrm
    try { & $add 'TrustedHosts' ((Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value) } catch { & $add 'TrustedHosts' "unreadable ($($_.Exception.Message))" }
    & $add 'Root' (Get-PmPath Root)
    $rootDrive = Get-PmLogicalDisk -Path (Get-PmPath Root)
    $rootFree = if ($rootDrive) { '{0:N1} GB' -f ($rootDrive.FreeSpace / 1GB) } else { 'unknown' }
    & $add 'Root drive free' $rootFree
    [void]$env.AppendLine('')
    [void]$env.AppendLine('Servers:')
    foreach ($s in (Get-PmServers)) {
        $p = Test-PmServerPorts -Server $s
        $a = Get-PmAgentStatus -ServerId $s.id
        [void]$env.AppendLine(('  {0,-14} {1,-16} method={2,-5} RDP:{3}={4} WinRM:{5}={6} credential={7} agent={8} {9}' -f $s.name, $s.host, (Get-PmTransport $s), $p.rdpPort, $p.rdp, $p.winrmPort, $p.winrm, (Test-PmCredential $s.id), $a.connected, $(if ($a.connected) { "($($a.computer), $($a.state), age $($a.ageSeconds)s)" } else { '' })))
    }
    [IO.File]::WriteAllText((Join-Path $tmp 'environment.txt'), $env.ToString(), [Text.Encoding]::UTF8)
    $zip = Join-Path $diagDir "prtg-mover-diagnostics-$stamp.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($tmp, $zip)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $diagDir -Filter '*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-PmAudit -Action 'diagnostics.created' -Data @{ file = (Split-Path $zip -Leaf) }
    return $zip
}

# ======================================================================= tests

function Invoke-PmTestFlow {
    <#
        Mode 'rdp'   : RDP port reachable (+ full system info when the agent is connected and idle)
        Mode 'winrm' : WinRM port reachable + login + full system info over PowerShell remoting
        Mode 'auto'  : both.
        Each method's result is stored separately (with its own time), so testing one never
        erases the other. A server PASSES when at least one method is OK.
    #>
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, $Job, [ValidateSet('auto', 'rdp', 'winrm')][string]$Mode = 'auto')
    Add-PmJobLog -Job $Job -Level STEP -Message "Testing $($Server.name) ($($Server.host)) - test: $($Mode.ToUpper()), connection method used by jobs: $((Get-PmTransport $Server).ToUpper())"
    $now = (Get-Date).ToString('o')
    $ports = Test-PmServerPorts -Server $Server
    Add-PmJobLog -Job $Job -Level DEBUG -Message "TCP probe from manager: RDP $($ports.rdpPort)=$($ports.rdp), WinRM $($ports.winrmPort)=$($ports.winrm)"
    $tested = @{}
    $info = $null

    if ($Mode -in 'auto', 'rdp') {
        $detail = if ($ports.rdp) { "RDP port $($ports.rdpPort) reachable" } else { "RDP port $($ports.rdpPort) NOT reachable from the manager (wrong port, firewall, RDP disabled or server offline)" }
        Add-PmJobLog -Job $Job -Level $(if ($ports.rdp) { 'OK' } else { 'ERROR' }) -Message "RDP test: $(if ($ports.rdp) { 'PASS' } else { 'FAIL' }) - $detail"
        $agent = Get-PmAgentStatus -ServerId $Server.id
        if ($agent.connected -and $agent.state -eq 'busy') {
            Add-PmJobLog -Job $Job -Message "Agent is connected but busy with '$($agent.task)' - system check skipped (no need to wait)."
        } elseif ($agent.connected) {
            try {
                $s = New-PmSession -Server ([pscustomobject]@{ id = $Server.id; name = $Server.name; transport = 'rdp' }) -Job $Job
                $info = Invoke-PmRemote -Session $s -Function 'Get-PmSystemInfo' -Job $Job
                $detail += "; agent OK on $($agent.computer)"
            } catch { Add-PmJobError -Job $Job -ErrorRecord $_ -Context 'Agent system check: ' }
        } elseif ($ports.rdp) {
            Add-PmJobLog -Job $Job -Message "Agent not running - it is only needed while a job runs (RDP button -> elevated PowerShell -> $(Get-PmAgentCommand $Server))."
        }
        $tested.rdp = [ordered]@{ ok = [bool]$ports.rdp; checked = $now; detail = $detail }
    }

    if ($Mode -in 'auto', 'winrm') {
        $ok = $false; $detail = ''
        if (-not $ports.winrm) {
            $detail = "WinRM port $($ports.winrmPort) NOT reachable from the manager"
        } else {
            $s = $null
            try {
                $s = New-PmSession -Server ([pscustomobject]@{ id = $Server.id; name = $Server.name; host = $Server.host; port = $Server.port; useSsl = $Server.useSsl; skipCaCheck = $Server.skipCaCheck; authentication = $Server.authentication; transport = 'winrm' }) -Credential $Credential -Job $Job
                $winfo = Invoke-PmRemote -Session $s -Function 'Get-PmSystemInfo' -Job $Job
                if (-not $info) { $info = $winfo }
                $ok = $true; $detail = 'WinRM login and remote execution OK'
            } catch {
                $msg = Format-PmManagerError $_
                $hint = Get-PmConnectHint -Message $msg
                $detail = "port reachable but login failed: $msg"
                if ($hint) { $detail += " | Fix: $hint" }
                Add-PmJobLog -Job $Job -Level DEBUG -Message "WinRM exception: $($_.Exception.GetType().FullName): $($_.Exception.Message)"
            } finally { if ($s) { Close-PmSession $s } }
        }
        Add-PmJobLog -Job $Job -Level $(if ($ok) { 'OK' } else { 'ERROR' }) -Message "WinRM test: $(if ($ok) { 'PASS' } else { 'FAIL' }) - $detail"
        $tested.winrm = [ordered]@{ ok = $ok; checked = $now; detail = $detail }
    }

    if ($info) {
        $r = $info
        Add-PmJobLog -Job $Job -Level OK -Message ("{0}: {1} | admin={2} | PRTG={3} {4} ({5} GB data, core {6}) | VPN={7} | RDP port on server={8}" -f $r.Computer, $r.OS, $r.IsAdmin,
                $(if ($r.Prtg.Installed) { 'yes' } else { 'no' }), $r.Prtg.Version, $r.PrtgDataGB, $r.Prtg.CoreStatus, @($r.VpnAllUsers).Count, $r.RdpPort) -Computer $r.Computer
        foreach ($d in @($r.Disks)) { Add-PmJobLog -Job $Job -Message ("Disk {0} {1} GB free of {2} GB" -f $d.Drive, $d.FreeGB, $d.SizeGB) -Computer $r.Computer }
        if ($r.Prtg.Installed -and $r.PrtgConfigStats) { Add-PmJobLog -Job $Job -Message "PRTG configuration: $($r.PrtgConfigStats)" -Computer $r.Computer }
        if ($r.Prtg.Installed -and $r.PrtgLicense) {
            $lic = $r.PrtgLicense
            if ($lic.Error) { Add-PmJobLog -Job $Job -Level WARN -Message "License report failed: $($lic.Error)" -Computer $r.Computer }
            else {
                $ls = $r.PrtgLicenseState
                if ($ls -and $ls.Known -and $ls.NeedsActivation -and -not [string]$ls.Name) {
                    Add-PmJobLog -Job $Job -Level WARN -Computer $r.Computer -Message "PRTG license: none installed ('$($ls.Edition)'). Enter a license in PRTG (Setup > License Information). Sensors paused by the license: $($ls.PausedByLicense)."
                } elseif ($ls -and $ls.Known -and $ls.NeedsActivation) {
                    Add-PmJobLog -Job $Job -Level WARN -Computer $r.Computer -Message "PRTG license: '$($ls.Edition)' - the license must be activated for this server (PRTG > Setup > License Information). Sensors paused by the license: $($ls.PausedByLicense)."
                    if ($ls.LastError) { Add-PmJobLog -Job $Job -Level WARN -Computer $r.Computer -Message "PRTG license: last activation attempt: $($ls.LastError)" }
                } elseif ($ls -and $ls.Known) {
                    Add-PmJobLog -Job $Job -Level OK -Computer $r.Computer -Message "PRTG license: $($ls.Edition), $($ls.MaxSensors) sensors, active. Sensors paused by the license: $($ls.PausedByLicense)."
                } else {
                    Add-PmJobLog -Job $Job -Computer $r.Computer -Message 'PRTG license: no license lines in the core log of the last days (the core was not restarted recently).'
                }
                Add-PmJobLog -Job $Job -Level DEBUG -Message "License (fingerprints only): $(@($lic.Values) -join '; ') | system id $($lic.SystemId) | auto activation $($lic.AutoActivation)" -Computer $r.Computer
                foreach ($l in @($lic.LogLines)) { Add-PmJobLog -Job $Job -Level DEBUG -Message "License log: $l" -Computer $r.Computer }
            }
        }
        if ($r.Prtg.Installed) { Add-PmJobLog -Job $Job -Message "PRTG listens on: $(if (@($r.Prtg.ListenEndpoints).Count) { @($r.Prtg.ListenEndpoints) -join ', ' } else { 'nothing (core not running)' }) | server addresses: $(@($r.Prtg.LocalAddresses) -join ', ')" -Computer $r.Computer }
        if (-not $r.IsAdmin) { Add-PmJobLog -Job $Job -Level WARN -Message 'Session is NOT elevated - an administrator is required.' }
        if ($r.RdpPort -and [int]$r.RdpPort -ne (Get-PmRdpPort $Server)) { Add-PmJobLog -Job $Job -Level WARN -Message "The server's RDP service listens on port $($r.RdpPort) but the inventory says $(Get-PmRdpPort $Server) - edit the server." }
    }

    # Merge with the previous result of the method that was NOT tested now.
    $sf = Join-Path (Get-PmPath Status) "$($Server.id).json"
    $prev = $null
    if (Test-Path -LiteralPath $sf) { try { $prev = Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
    $methods = [ordered]@{ rdp = $null; winrm = $null }
    foreach ($m in 'rdp', 'winrm') {
        if ($tested.ContainsKey($m)) { $methods[$m] = $tested[$m] }
        elseif ($prev -and $prev.methods -and $prev.methods.$m -and $prev.methods.$m.PSObject.Properties['ok']) { $methods[$m] = $prev.methods.$m }
    }
    $overall = [bool](($methods.rdp -and $methods.rdp.ok) -or ($methods.winrm -and $methods.winrm.ok))
    $testedOk = [bool](@($tested.Values | Where-Object { $_.ok }).Count -gt 0)
    $status = [pscustomobject]@{
        ok = $overall; checked = $now; lastMode = $Mode; methods = [pscustomobject]$methods
        info = $(if ($info) { $info } elseif ($prev) { $prev.info } else { $null })
        error = $(if ($testedOk) { $null } else { (@($tested.Values | ForEach-Object { $_.detail }) -join ' | ') }); ports = $ports
    }
    $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sf -Encoding UTF8
    $fmt = { param($x) if (-not $x) { 'not tested yet' } elseif ($x.ok) { "OK ($(([datetime]$x.checked).ToString('HH:mm')))" } else { "FAIL ($(([datetime]$x.checked).ToString('HH:mm')))" } }
    Add-PmJobLog -Job $Job -Level $(if ($testedOk) { 'OK' } else { 'ERROR' }) -Message ("{0}: this test {1}. Server status: {2}  (RDP {3}, WinRM {4})" -f $Server.name,
            $(if ($testedOk) { 'PASSED' } else { 'FAILED' }), $(if ($overall) { 'PASS' } else { 'FAIL' }), (& $fmt $methods.rdp), (& $fmt $methods.winrm))
    if (-not $testedOk) { throw (@($tested.Values | ForEach-Object { $_.detail }) -join ' | ') }
    return $status
}

# ======================================================================= pre-flight

function Invoke-PmPreflight {
    <#
        Runs BEFORE anything is changed: every server must be reachable with admin rights and
        have enough disk space, and the target PRTG version must not be older than the source.
        $Source may be $null (resume: the package already exists; pass -DataBytes instead).
    #>
    param($Source, [object[]]$Targets = @(), [hashtable]$Credentials, [hashtable]$Options = @{}, $Job, [int64]$DataBytes = 0, [string]$SourceVersion)
    Add-PmJobLog -Job $Job -Level STEP -Message 'Pre-flight checks (nothing is changed yet)...'
    $problems = @()
    $info = @{}
    foreach ($srv in @(@($Source) + @($Targets) | Where-Object { $_ })) {
        $ports = Test-PmServerPorts -Server $srv
        $method = Get-PmTransport $srv
        Add-PmJobLog -Job $Job -Level DEBUG -Message "$($srv.name) ($($srv.host)): method=$method RDP $($ports.rdpPort)=$($ports.rdp) WinRM $($ports.winrmPort)=$($ports.winrm)"
        if ($method -eq 'winrm' -and -not $ports.winrm) { $problems += "$($srv.name): $(Get-PmConnectHint -Ports $ports)"; continue }
        $s = $null
        try {
            $s = New-PmSession -Server $srv -Credential (Resolve-PmCredential $srv $Credentials) -Job $Job
            $i = Invoke-PmRemote -Session $s -Function 'Initialize-PmRemoteWorkRoot' -Job $Job
            $info[$srv.id] = $i
            if (-not $i.IsAdmin -and $env:PRTGMOVER_TEST -ne '1') { $problems += "$($srv.name): remote session is not elevated (administrator required)." }
            Add-PmJobLog -Job $Job -Level OK -Computer $i.Computer -Message ("{0}: reachable via {1}, admin={2}, PRTG={3}, {4:N1} GB free" -f $srv.name, $method.ToUpper(), $i.IsAdmin,
                    $(if ($i.Prtg.Installed) { "$($i.Prtg.Version) ($($i.Prtg.CoreStatus))" } else { 'not installed' }), ($i.FreeBytes / 1GB))
        } catch {
            $problems += "$($srv.name): $(Format-PmManagerError $_)"
            Add-PmJobError -Job $Job -ErrorRecord $_ -Context "$($srv.name) pre-flight: "
        } finally { if ($s) { Close-PmSession $s } }
    }

    $data = $DataBytes
    $srcVersion = $SourceVersion
    if ($Source) {
        $src = $info[$Source.id]
        if ($src) {
            $includePrtg = -not ($Options.ContainsKey('IncludePrtg') -and -not $Options.IncludePrtg)
            if ($includePrtg -and -not $src.Prtg.Installed) { $problems += "$($Source.name): PRTG is not installed on the source." }
            $data = [int64]$src.PrtgDataBytes
            $srcVersion = $src.Prtg.Version
            $viaTunnel = [string]$Options.Transfer -in 'wireguard', 'ipip'
            if ($viaTunnel) {
                Add-PmJobLog -Job $Job -Level OK -Message ("{0}: tunnel mode - WinRM goes from the source to the target's tunnel address. This computer is not in the data path (PRTG data {1:N1} GB)." -f $Source.name, ($data / 1GB))
            } elseif ((Get-PmTransport $Source) -eq 'rdp') {
                Add-PmJobLog -Job $Job -Level OK -Message ("{0}: RDP mode stages directly on the manager - no free space needed on the source (PRTG data {1:N1} GB)." -f $Source.name, ($data / 1GB))
            } else {
                Add-PmJobLog -Job $Job -Level OK -Message ("{0}: WinRM mode - the manager pulls the files from a snapshot, no free space needed on the source (PRTG data {1:N1} GB)." -f $Source.name, ($data / 1GB))
            }
        }
        # manager: staging copy + zip. A tunnel never stores the package here.
        $viaTunnel = [string]$Options.Transfer -in 'wireguard', 'ipip'
        if (-not $viaTunnel) {
            $mgrDrive = Get-PmLogicalDisk -Path (Get-PmPath Root)
            if ($data -gt 0 -and $mgrDrive -and $mgrDrive.FreeSpace -lt ($data * 2.2)) {
                $problems += ("Manager: needs ~{0:N1} GB free on {1} for staging + package, has {2:N1} GB." -f ($data * 2.2 / 1GB), $mgrDrive.DeviceID, ($mgrDrive.FreeSpace / 1GB))
            }
        }
    }
    foreach ($t in $Targets) {
        $ti = $info[$t.id]; if (-not $ti) { continue }
        $factor = 1.2   # both methods: staged package + move (no second copy)
        if ($data -gt 0 -and $ti.FreeBytes -lt ($data * $factor)) { $problems += ("{0}: needs ~{1:N1} GB free, has {2:N1} GB." -f $t.name, ($data * $factor / 1GB), ($ti.FreeBytes / 1GB)) }
        if ($ti.Prtg.Installed -and $srcVersion) {
            $sv = [version]($srcVersion -replace '[^\d\.]', ''); $tv = [version]($ti.Prtg.Version -replace '[^\d\.]', '')
            if ($tv -lt $sv -and -not $Options.AllowDowngrade) { $problems += "$($t.name): PRTG $tv is older than source $sv - upgrade the target first." }
        } elseif (-not $ti.Prtg.Installed -and -not $Options.InstallerFile) {
            if ($Options.ContainsKey('IncludeProgram') -and -not $Options.IncludeProgram) { $problems += "$($t.name): PRTG is not installed, program cloning is off and no installer was selected." }
            else { Add-PmJobLog -Job $Job -Level INFO -Message "$($t.name): PRTG not installed - it will be CLONED from the source (program files + services, no installer)." }
        }
    }
    if ($problems.Count) {
        foreach ($p in $problems) { Add-PmJobLog -Job $Job -Level ERROR -Message "Pre-flight: $p" }
        throw "Pre-flight failed ($($problems.Count) problem(s)) - nothing was changed on any server."
    }
    Add-PmJobLog -Job $Job -Level OK -Message 'Pre-flight passed.'
    return $info
}

# ======================================================================= backup / restore

function ConvertTo-PmTsClientPath {
    <# F:\...\PrtgMover\data\staging\x  ->  \\tsclient\F\...\PrtgMover\data\staging\x #>
    param([Parameter(Mandatory)][string]$LocalPath)
    return (Join-Path (Get-PmTsClientRoot) (Get-PmManagerRelative $LocalPath))
}

function Test-PmStageComplete {
    <#
        A staging copy is complete ONLY when the transfer finished (marker written afterwards)
        AND PRTG Configuration.dat matches the checksum recorded on the source.
    #>
    param([Parameter(Mandatory)][string]$StageDir)
    $marker = Join-Path $StageDir '.staging-complete'
    $man = Join-Path $StageDir 'manifest.json'
    if (-not (Test-Path -LiteralPath $marker) -or -not (Test-Path -LiteralPath $man)) { return $false }
    try {
        $m = Get-Content -LiteralPath $man -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($m.prtg.included -and $m.prtg.configSha256) {
            $cfg = Join-Path $StageDir 'prtg\data\PRTG Configuration.dat'
            if (-not (Test-Path -LiteralPath $cfg)) { return $false }
            if ((Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash -ne $m.prtg.configSha256) { return $false }
        }
        return $true
    } catch { return $false }
}

function Set-PmStageComplete {
    param([Parameter(Mandatory)][string]$StageDir)
    Set-Content -LiteralPath (Join-Path $StageDir '.staging-complete') -Value (Get-Date).ToString('o') -Encoding ASCII
}

function Find-PmResumeStage {
    <#
        Walks the resume chain (job -> resumedFrom -> ...) and returns the newest staging copy
        left by an earlier run: @{ Path; JobId; Complete = manifest.json present }.
    #>
    param($Job)
    $id = if ($Job) { $Job.resumedFrom } else { $null }
    $seen = @{}
    while ($id -and -not $seen.ContainsKey($id)) {
        $seen[$id] = $true
        $p = Join-Path (Get-PmPath Data) "staging\$id"
        if (Test-Path -LiteralPath $p) {
            return [pscustomobject]@{ Path = $p; JobId = $id; Complete = (Test-PmStageComplete -StageDir $p) }
        }
        $rec = Join-Path (Get-PmPath Jobs) "$id.json"
        $id = $null
        if (Test-Path -LiteralPath $rec) { try { $id = (Get-Content -LiteralPath $rec -Raw -Encoding UTF8 | ConvertFrom-Json).resumedFrom } catch { } }
    }
    return $null
}

function New-PmPackageFromStage {
    <# Builds backups\PRTG_<computer>_<ts>.zip (+ .meta.json) from a complete staging folder on the manager. #>
    param([Parameter(Mandatory)][string]$StageDir, $Job, [string]$SourceName)
    $manifest = Get-Content -LiteralPath (Join-Path $StageDir 'manifest.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $zipName = 'PRTG_{0}_{1}.zip' -f $manifest.source.computer, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $local = Join-Path (Get-PmPath Backups) $zipName
    Add-PmJobLog -Job $Job -Level STEP -Message ("Compressing the staged copy ({0:N2} GB) into {1} on the manager..." -f ($manifest.stagingBytes / 1GB), $zipName)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($StageDir, $local, [IO.Compression.CompressionLevel]::Optimal, $false)
    $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
    Add-PmJobLog -Job $Job -Level OK -Message ("Package ready: {0} ({1:N1} MB, SHA-256 {2}, {3:N0} s)" -f $zipName, ((Get-Item -LiteralPath $local).Length / 1MB), $hash, $sw.Elapsed.TotalSeconds)
    if (-not $SourceName) { $SourceName = $manifest.source.computer }
    [pscustomobject]@{ source = $SourceName; sha256 = $hash; manifest = $manifest } | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$local.meta.json" -Encoding UTF8
    Write-PmAudit -Action 'backup.created' -Data @{ job = $(if ($Job) { $Job.id }); package = $zipName; sha256 = $hash }
    return $local
}

function Use-PmCompletedStage {
    <#
        Resume helper: if an earlier run of this job chain already finished copying from the
        source (staging with manifest.json), adopt it - the source is not contacted again.
        Returns @{ Zip; StageDir } or $null.
    #>
    param($Job, [string]$SourceName)
    $rs = Find-PmResumeStage -Job $Job
    if (-not $rs -or -not $rs.Complete) { return $null }
    $dest = Join-Path (Get-PmPath Data) "staging\$($Job.id)"
    Move-Item -LiteralPath $rs.Path -Destination $dest
    Add-PmJobLog -Job $Job -Level OK -Message "RESUME: the copy made by job $($rs.JobId) is complete - adopting it, the source is not contacted again."
    $zip = New-PmPackageFromStage -StageDir $dest -Job $Job -SourceName $SourceName
    return [pscustomobject]@{ Zip = $zip; StageDir = $dest }
}

function Get-PmLocalFileList {
    <# Local counterpart of Get-PmPullList: files below $Root with relative path, size, last write. #>
    param([Parameter(Mandatory)][string]$Root)
    $out = @{}
    if (-not (Test-Path -LiteralPath $Root)) { return $out }
    $r = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\').TrimEnd('/')
    foreach ($f in (Get-ChildItem -LiteralPath $r -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        if ($f.Name -in 'desktop.ini', 'Thumbs.db') { continue }   # Windows shell junk
        $rel = $f.FullName.Substring($r.Length + 1).Replace('/', '\').ToLowerInvariant()
        $out[$rel] = $f
    }
    return $out
}

function New-PmLocalChunk {
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string[]]$Files, [Parameter(Mandatory)][string]$ChunkPath)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $ChunkPath) { Remove-Item -LiteralPath $ChunkPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($ChunkPath, [IO.Compression.ZipArchiveMode]::Create)
    try { foreach ($rel in $Files) { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $Source $rel), $rel.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal) } }
    finally { $zip.Dispose() }
}

function Expand-PmLocalChunk {
    param([Parameter(Mandatory)][string]$ChunkPath, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ChunkPath)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            $target = Join-Path $Destination ($e.FullName.Replace('/', '\'))
            $dir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
        }
    } finally { $zip.Dispose() }
}

function Invoke-PmTransferBatch {
    <#
        ONE attempt to transfer one batch of files as a compressed chunk. Throws on failure
        (temporary chunks are removed on both sides). Returns the number of bytes on the wire.
    #>
    param(
        [Parameter(Mandatory)]$Session, [Parameter(Mandatory)][ValidateSet('Pull', 'Push')][string]$Direction,
        [Parameter(Mandatory)][string]$RemoteRoot, [Parameter(Mandatory)][string]$LocalRoot,
        [Parameter(Mandatory)][object[]]$Batch, $Job
    )
    $rels = [string[]]@($Batch | ForEach-Object { [string]$_.Rel })
    $chunkDir = Join-Path (Get-PmPath Data) 'chunks'
    if (-not (Test-Path -LiteralPath $chunkDir)) { New-Item -ItemType Directory -Force -Path $chunkDir | Out-Null }
    $localChunk = Join-Path $chunkDir ('{0}.zip' -f [guid]::NewGuid().ToString('N'))
    $remoteChunk = $null
    try {
        if ($Direction -eq 'Pull') {
            $c = Invoke-PmRemote -Session $Session -Function 'New-PmTransferChunk' -Parameters @{ Source = $RemoteRoot; Files = $rels } -Job $Job
            $remoteChunk = [string]$c.Path
            Copy-PmFromServer -Session $Session -RemotePath $remoteChunk -LocalPath $localChunk -Job $Job
            if ((Get-Item -LiteralPath $localChunk).Length -ne [int64]$c.Size) { throw "Chunk size mismatch after transfer (remote $($c.Size), local $((Get-Item -LiteralPath $localChunk).Length))." }
            [void](Invoke-PmRemote -Session $Session -Function 'Remove-PmTransferChunk' -Parameters @{ ChunkPath = $remoteChunk } -Job $Job)
            $remoteChunk = $null
            if (-not (Test-Path -LiteralPath $LocalRoot)) { New-Item -ItemType Directory -Force -Path $LocalRoot | Out-Null }
            Expand-PmLocalChunk -ChunkPath $localChunk -Destination $LocalRoot
            foreach ($f in $Batch) { try { (Get-Item -LiteralPath (Join-Path $LocalRoot ([string]$f.Rel)) -Force).LastWriteTimeUtc = [datetime]::new([int64]$f.Time, [DateTimeKind]::Utc) } catch { } }
        } else {
            New-PmLocalChunk -Source $LocalRoot -Files $rels -ChunkPath $localChunk
            $remoteChunk = Join-Path (Split-Path $RemoteRoot -Parent) ('chunk-{0}.zip' -f [guid]::NewGuid().ToString('N'))
            Copy-PmToServer -Session $Session -LocalPath $localChunk -RemotePath $remoteChunk -Job $Job
            $x = Invoke-PmRemote -Session $Session -Function 'Expand-PmTransferChunk' -Parameters @{ ChunkPath = $remoteChunk; Destination = $RemoteRoot } -Job $Job
            $remoteChunk = $null
            if ([int]$x.Count -ne $rels.Count) { throw "The target unpacked $($x.Count) of $($rels.Count) files." }
        }
        return [int64](Get-Item -LiteralPath $localChunk).Length
    } catch {
        if ($remoteChunk) { try { [void](Invoke-PmRemote -Session $Session -Function 'Remove-PmTransferChunk' -Parameters @{ ChunkPath = $remoteChunk } -Job $Job) } catch { } }
        throw
    } finally { Remove-Item -LiteralPath $localChunk -Force -ErrorAction SilentlyContinue }
}

# Worker of the parallel transfer: own runspace, own session, takes batches from a shared queue.
$script:PmTransferWorker = {
    param($ModulePath, $Root, $Server, $Credential, $Job, $Direction, $RemoteRoot, $LocalRoot, $Queue, $State, $WorkerId, $BatchCount)
    $s = $null
    try {
        Import-Module $ModulePath -Force -DisableNameChecking
        Set-PmRoot -Path $Root
        $batch = $null
        while (-not $State.Failed -and $Queue.TryDequeue([ref]$batch)) {
            $list = @($batch)
            $bytes = [int64](($list | Measure-Object -Property Size -Sum).Sum)
            $wire = [int64]0
            for ($try = 1; ; $try++) {
                try {
                    $broken = ($s -is [System.Management.Automation.Runspaces.PSSession] -and $s.State -ne 'Opened')
                    if (-not $s -or $broken) {
                        if ($s) { Close-PmSession $s }
                        $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
                    }
                    $wire = Invoke-PmTransferBatch -Session $s -Direction $Direction -RemoteRoot $RemoteRoot -LocalRoot $LocalRoot -Batch $list -Job $Job
                    break
                } catch {
                    if ($State.Failed) { return }
                    if ($try -ge 4) { throw "Stream $WorkerId`: chunk with $($list.Count) file(s) (first: $($list[0].Rel)) failed 4 times: $($_.Exception.Message)" }
                    Add-PmJobLog -Job $Job -Level WARN -Message "Stream $WorkerId`: chunk failed ($($_.Exception.Message)) - retry $($try + 1)/4"
                    Start-Sleep -Seconds ($(if ($env:PRTGMOVER_RETRY_SECONDS) { [int]$env:PRTGMOVER_RETRY_SECONDS } else { 10 }) * $try)
                }
            }
            [Threading.Monitor]::Enter($State.SyncRoot)
            try { $State.DoneBytes += $bytes; $State.Wire += $wire; $State.Files += $list.Count; $State.Batches += 1 }
            finally { [Threading.Monitor]::Exit($State.SyncRoot) }
        }
    } catch {
        [Threading.Monitor]::Enter($State.SyncRoot)
        try { $State.Failed = $true; if (-not $State.Error) { $State.Error = "$($_.Exception.Message)" } }
        finally { [Threading.Monitor]::Exit($State.SyncRoot) }
    } finally { if ($s) { Close-PmSession $s } }
}

function Invoke-PmTransferFiles {
    <#
        Resumable, compressed, parallel transfer.
          -Direction Pull : RemoteRoot -> LocalRoot (files: remote list)
          -Direction Push : LocalRoot  -> RemoteRoot (files: local list)
        Files are packed into compressed chunks (~256 MB of data each) on the sending side,
        copied in one piece and unpacked on the receiving side. With -Server and -Streams > 1
        several chunks travel at the same time, each over its own connection.
        Files that already exist with the same size (pull: and timestamp) are skipped, so an
        interrupted transfer continues where it stopped. -Purge (pull) removes local files
        that are not part of the list, so nothing superfluous ends up in the package.
    #>
    param(
        [Parameter(Mandatory)]$Session, [Parameter(Mandatory)][ValidateSet('Pull', 'Push')][string]$Direction,
        [Parameter(Mandatory)][string]$RemoteRoot, [Parameter(Mandatory)][string]$LocalRoot,
        [object[]]$Files = @(), $Job, [string]$Label = 'files', [int]$ProgressBase = 0, [double]$ProgressSpan = 0,
        [int64]$ChunkBytes = 256MB, [int]$ChunkFiles = 3000,
        $Server, [pscredential]$Credential, [int]$Streams = 1, [switch]$Purge
    )
    $existing = @{}
    if ($Direction -eq 'Pull') {
        $existing = Get-PmLocalFileList -Root $LocalRoot
        if ($Purge -and $existing.Count) {
            $wanted = @{}
            foreach ($f in $Files) { $wanted[([string]$f.Rel).ToLowerInvariant()] = $true }
            $extra = @($existing.Keys | Where-Object { -not $wanted.ContainsKey($_) })
            foreach ($k in $extra) { Remove-Item -LiteralPath $existing[$k].FullName -Force -ErrorAction SilentlyContinue; $existing.Remove($k) }
            if ($extra.Count) { Add-PmJobLog -Job $Job -Message "$Label`: removed $($extra.Count) local file(s) that are not part of the transfer (logs, cache, temp files of earlier runs)." }
        }
    } else {
        $rl = Invoke-PmRemote -Session $Session -Function 'Get-PmPullList' -Parameters @{ Source = $RemoteRoot } -Job $Job
        foreach ($f in @($rl.Files)) { $existing[([string]$f.Rel).ToLowerInvariant()] = $f }
        [void](Invoke-PmRemote -Session $Session -Function 'New-PmRemoteDirectories' -Parameters @{ Root = $RemoteRoot } -Job $Job)
    }
    $total = [int64](($Files | Measure-Object -Property Size -Sum).Sum)
    $todo = @($Files | Where-Object {
            $e = $existing[([string]$_.Rel).ToLowerInvariant()]
            if (-not $e) { return $true }
            $eSize = if ($e.PSObject.Properties['Length']) { $e.Length } else { $e.Size }
            if ([int64]$eSize -ne [int64]$_.Size) { return $true }
            if ($Direction -eq 'Pull' -and $e.LastWriteTimeUtc.Ticks -ne [int64]$_.Time) { return $true }
            return $false
        })
    $todoBytes = [int64](($todo | Measure-Object -Property Size -Sum).Sum)
    Add-PmJobLog -Job $Job -Level STEP -Message ("{0} {1}: {2} file(s), {3:N2} GB in total - {4} file(s), {5:N2} GB still to transfer{6}." -f $Direction, $Label, @($Files).Count, ($total / 1GB), $todo.Count, ($todoBytes / 1GB), $(if ($todo.Count -lt @($Files).Count) { ' (resuming - the rest is already there)' } else { '' }))
    if (-not $todo.Count) { return }

    # batches
    $batches = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList; $curBytes = [int64]0
    foreach ($f in $todo) {
        if ($cur.Count -and (($curBytes + [int64]$f.Size) -gt $ChunkBytes -or $cur.Count -ge $ChunkFiles)) { [void]$batches.Add($cur); $cur = New-Object System.Collections.ArrayList; $curBytes = 0 }
        [void]$cur.Add($f); $curBytes += [int64]$f.Size
    }
    if ($cur.Count) { [void]$batches.Add($cur) }

    $state = [hashtable]::Synchronized(@{ DoneBytes = [int64]0; Wire = [int64]0; Files = 0; Batches = 0; Failed = $false; Error = $null })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $report = {
        # Reporting must never be able to abort a transfer.
        trap { Add-PmJobLog -Job $Job -Level DEBUG -Message "Progress report failed (ignored): $($_.Exception.Message)"; continue }
        $pct = if ($todoBytes) { [int](100 * $state.DoneBytes / $todoBytes) } else { 100 }
        $rate = ($state.DoneBytes / 1MB) / [math]::Max(1, $sw.Elapsed.TotalSeconds)
        $eta = if ($rate -gt 0) { [TimeSpan]::FromSeconds((($todoBytes - $state.DoneBytes) / 1MB) / $rate) } else { [TimeSpan]::Zero }
        Add-PmJobLog -Job $Job -Message ("{0} {1}: {2}% ({3:N2} / {4:N2} GB, {5} files, chunk {6}/{7}) - {8:N1} MB/s effective, {9:N1}x compression, about {10:hh\:mm\:ss} left" -f $Direction, $Label, $pct, ($state.DoneBytes / 1GB), ($todoBytes / 1GB), $state.Files, $state.Batches, $batches.Count, $rate, ($state.DoneBytes / [math]::Max([double]1, [double]$state.Wire)), $eta)
        if ($ProgressSpan -gt 0) { Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]($ProgressSpan * $pct / 100)) -Step ("{0} {1}: {2}%" -f $Direction, $Label, $pct) }
    }

    $agent = [bool]$Session.PSObject.Properties['PmAgent']
    $n = [math]::Min([math]::Max(1, $Streams), $batches.Count)
    if ($n -gt 1 -and $Server -and -not $agent) {
        # ---------------- parallel: n workers, each with its own connection
        if ($Direction -eq 'Pull') {
            try {
                $facts = Invoke-PmRemote -Session $Session -Function 'Get-PmHostFacts' -Job $Job
                $cap = [math]::Max(2, [int]$facts.Cores * 2)     # sender compresses: stay gentle on a running PRTG
                if ($n -gt $cap) { $n = $cap }
            } catch { }
        }
        Add-PmJobLog -Job $Job -Level STEP -Message "$Direction $Label`: using $n parallel streams ($($batches.Count) chunks)."
        $queue = New-Object 'System.Collections.Concurrent.ConcurrentQueue[object]'
        foreach ($b in $batches) { $queue.Enqueue($b) }
        $pool = [runspacefactory]::CreateRunspacePool(1, $n); $pool.Open()
        $workers = @()
        try {
            for ($i = 1; $i -le $n; $i++) {
                $ps = [powershell]::Create(); $ps.RunspacePool = $pool
                [void]$ps.AddScript($script:PmTransferWorker.ToString()).AddArgument((Join-Path $PSScriptRoot 'PrtgMover.psm1')).AddArgument((Get-PmPath Root)).AddArgument($Server).AddArgument($Credential).AddArgument($Job).AddArgument($Direction).AddArgument($RemoteRoot).AddArgument($LocalRoot).AddArgument($queue).AddArgument($state).AddArgument($i).AddArgument($batches.Count)
                $workers += @{ PS = $ps; Async = $ps.BeginInvoke() }
            }
            $lastLog = [Diagnostics.Stopwatch]::StartNew(); $lastBatches = 0
            while (@($workers | Where-Object { -not $_.Async.IsCompleted }).Count) {
                Start-Sleep -Milliseconds 1000
                if ($lastLog.Elapsed.TotalSeconds -ge 30 -and $state.Batches -ne $lastBatches) { & $report; $lastLog.Restart(); $lastBatches = $state.Batches }
            }
        } finally {
            # cancel / error: stop the streams that are still running
            $state.Failed = ($state.Failed -or @($workers | Where-Object { -not $_.Async.IsCompleted }).Count -gt 0)
            foreach ($w in $workers) { if (-not $w.Async.IsCompleted) { try { [void]$w.PS.BeginStop($null, $null) } catch { } } }
            $deadline = (Get-Date).AddSeconds(30)
            while (@($workers | Where-Object { -not $_.Async.IsCompleted }).Count -and (Get-Date) -lt $deadline) { [Threading.Thread]::Sleep(300) }
            foreach ($w in $workers) { try { $w.PS.Dispose() } catch { } }
            try { $pool.Dispose() } catch { }
        }
        if ($state.Failed) { throw $(if ($state.Error) { $state.Error } else { 'The parallel transfer was interrupted.' }) }
        & $report
    } else {
        # ---------------- sequential (single stream / RDP agent)
        $b = 0
        foreach ($batch in $batches) {
            $b++
            $list = @($batch)
            for ($try = 1; ; $try++) {
                try { $wire = Invoke-PmTransferBatch -Session $Session -Direction $Direction -RemoteRoot $RemoteRoot -LocalRoot $LocalRoot -Batch $list -Job $Job; break }
                catch {
                    if ($try -ge 3) { throw "Transfer of chunk $b/$($batches.Count) ($($list.Count) files, first: $($list[0].Rel)) failed 3 times: $($_.Exception.Message)" }
                    Add-PmJobLog -Job $Job -Level WARN -Message "Chunk $b/$($batches.Count) failed ($($_.Exception.Message)) - retry $($try + 1)/3"
                    Start-Sleep -Seconds ($(if ($env:PRTGMOVER_RETRY_SECONDS) { [int]$env:PRTGMOVER_RETRY_SECONDS } else { 10 }) * $try)
                }
            }
            $state.DoneBytes += [int64](($list | Measure-Object -Property Size -Sum).Sum); $state.Wire += $wire; $state.Files += $list.Count; $state.Batches += 1
            & $report
        }
    }
    Add-PmJobLog -Job $Job -Level OK -Message ("{0} {1} complete: {2:N2} GB of data in {3:hh\:mm\:ss} ({4:N2} GB on the wire, {5:N1} MB/s effective)." -f $Direction, $Label, ($state.DoneBytes / 1GB), $sw.Elapsed, ($state.Wire / 1GB), (($state.DoneBytes / 1MB) / [math]::Max(1, $sw.Elapsed.TotalSeconds)))
}

function Invoke-PmBackupFlow {
    <#
        Returns [pscustomobject]@{ Zip = <package on the manager>; StageDir = <extracted copy on the manager> }.
          RDP (agent) : the server copies straight onto the manager's disk via \\tsclient.
          WinRM       : the manager pulls the files from the VSS snapshot over WinRM, file by file (resumable).
        In both cases the source needs no free disk space and the manager builds the zip.
    #>
    param(
        [Parameter(Mandatory)]$Server, [pscredential]$Credential, [hashtable]$Options = @{}, $Job,
        [int]$ProgressBase = 0, [double]$ProgressSpan = 100
    )
    $jobId = if ($Job -and $Job.id) { $Job.id } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to source $($Server.name) ($($Server.host)) via $((Get-PmTransport $Server).ToUpper())..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $params = ConvertTo-PmHashtable -InputObject $Options -Keys $script:PmBackupKeys
        $params.JobId = $jobId
        $streams = if ([int]$Options.TransferStreams -gt 0) { [math]::Min(8, [int]$Options.TransferStreams) } else { 4 }
        $chunkBytes = if ([int]$Options.TransferChunkMB -gt 0) { [int64]$Options.TransferChunkMB * 1MB } else { [int64]256MB }
        $agent = [bool]$s.PSObject.Properties['PmAgent']
        $stageLocal = Join-Path (Get-PmPath Data) "staging\$jobId"
        # Resume: continue the partial copy of an interrupted run instead of starting from zero.
        $prev = Find-PmResumeStage -Job $Job
        if ($prev -and -not (Test-Path -LiteralPath $stageLocal)) {
            Move-Item -LiteralPath $prev.Path -Destination $stageLocal
            Add-PmJobLog -Job $Job -Level OK -Message ("Reusing the partial copy of {0} ({1:N2} GB already transferred) - only the rest is copied." -f $prev.JobId, ((Get-ChildItem -LiteralPath $stageLocal -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum / 1GB))
        }
        New-Item -ItemType Directory -Force -Path $stageLocal | Out-Null
        if ($agent) {
            $params.StageDir = ConvertTo-PmTsClientPath $stageLocal
            $params.LogDir = ConvertTo-PmTsClientPath (Join-Path (Get-PmPath Data) 'logs\robocopy')
            Add-PmJobLog -Job $Job -Level DEBUG -Message "Direct staging: server writes to $($params.StageDir) (= $stageLocal on the manager)"
        } else {
            $params.PullMode = $true
            Add-PmJobLog -Job $Job -Level DEBUG -Message "Pull mode: the manager pulls the files over WinRM into $stageLocal"
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmRemoteBackup' -Parameters $params -Job $Job -ProgressBase $ProgressBase -ProgressSpan ($ProgressSpan * 0.1)
        if (-not $r) { throw 'Remote backup returned no result.' }
        Add-PmJobLog -Job $Job -Level DEBUG -Message ("Remote backup phase took {0:N0} s" -f $sw.Elapsed.TotalSeconds)
        $manifest = $r.Manifest | ConvertFrom-Json

        if (-not $agent) {
            try {
                # small items staged on the source (registry, services, VPN, desktops, extra, manifest)
                $small = Invoke-PmRemote -Session $s -Function 'Get-PmPullList' -Parameters @{ Source = $r.StageDir } -Job $Job
                Invoke-PmTransferFiles -Session $s -Direction Pull -RemoteRoot $r.StageDir -LocalRoot $stageLocal -Files @($small.Files) -Job $Job -Label 'registry/VPN/desktop/manifest'
                $span = $ProgressSpan * 0.6; $i = 0; $items = @($r.PullItems)
                foreach ($pi in $items) {
                    $lst = Invoke-PmRemote -Session $s -Function 'Get-PmPullList' -Parameters @{ Source = $pi.Source; ExcludeDirs = [string[]]@($pi.ExcludeDirs); ExcludeFiles = [string[]]@($pi.ExcludeFiles) } -Job $Job
                    Invoke-PmTransferFiles -Session $s -Direction Pull -RemoteRoot $pi.Source -LocalRoot (Join-Path $stageLocal $pi.Target) -Files @($lst.Files) -Job $Job -Label $pi.Target `
                        -Server $Server -Credential $Credential -Streams $streams -ChunkBytes $chunkBytes -Purge `
                        -ProgressBase ($ProgressBase + [int]($ProgressSpan * 0.1) + [int]($span * $i / [math]::Max(1, $items.Count))) -ProgressSpan ($span / [math]::Max(1, $items.Count))
                    $i++
                }
            } finally {
                try { [void](Invoke-PmRemote -Session $s -Function 'Complete-PmRemotePull' -Parameters @{ StageDir = $r.StageDir; ShadowId = [string]$r.ShadowId; ShadowLink = [string]$r.ShadowLink } -Job $Job) }
                catch { Add-PmJobError -Job $Job -ErrorRecord $_ -Context 'Source cleanup: ' }
            }
            # the pulled configuration must be byte-identical to the one read on the source
            if ($manifest.prtg.configSha256) {
                $h = (Get-FileHash -LiteralPath (Join-Path $stageLocal 'prtg\data\PRTG Configuration.dat') -Algorithm SHA256).Hash
                if ($h -ne $manifest.prtg.configSha256) { throw 'PRTG Configuration.dat pulled to the manager does not match the source (checksum) - run Resume.' }
                Add-PmJobLog -Job $Job -Level OK -Message 'PRTG Configuration.dat verified on the manager (SHA-256 identical to the source).'
            }
        }

        # Only now is the copy known to be whole - mark it (Resume may adopt it later).
        if ($manifest.prtg.included -and $manifest.prtg.configSha256 -and $agent) {
            $h = (Get-FileHash -LiteralPath (Join-Path $stageLocal 'prtg\data\PRTG Configuration.dat') -Algorithm SHA256).Hash
            if ($h -ne $manifest.prtg.configSha256) { throw 'PRTG Configuration.dat staged on the manager does not match the source (checksum) - run Resume.' }
        }
        Set-PmStageComplete -StageDir $stageLocal
        Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]($ProgressSpan * 0.75)) -Step 'Building the package on the manager'
        $local = New-PmPackageFromStage -StageDir $stageLocal -Job $Job -SourceName $Server.name
        Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]$ProgressSpan) -Step 'Backup complete'
        $result = [pscustomobject]@{ Zip = $local; StageDir = $stageLocal }
        if ($r.SourceHealth -and -not $r.SourceHealth.Healthy) {
            throw "Backup saved as $(Split-Path $local -Leaf), but PRTG on the source did NOT come back up completely ($($r.SourceHealth.Message))."
        }
        return $result
    } finally { if ($s) { Close-PmSession $s } }
}

function Get-PmExtractedStage {
    <# Local extracted copy of a package (read by RDP targets via \\tsclient, pushed to WinRM targets). #>
    param([Parameter(Mandatory)][string]$ZipPath, [string]$StageDir, $Job)
    if ($StageDir -and (Test-PmStageComplete -StageDir $StageDir)) { return $StageDir }
    $dir = Join-Path (Get-PmPath Data) ("staging\restore-" + [IO.Path]::GetFileNameWithoutExtension($ZipPath))
    if (Test-PmStageComplete -StageDir $dir) { return $dir }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Add-PmJobLog -Job $Job -Level STEP -Message "Extracting $(Split-Path $ZipPath -Leaf) on the manager..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $dir)
    Set-PmStageComplete -StageDir $dir
    return $dir
}

function Invoke-PmRestoreFlow {
    <#
          RDP (agent) : the target reads the staged package straight from the manager (\\tsclient).
          WinRM       : the manager pushes the staged files to the target file by file (resumable),
                        and the target MOVES them into place - it needs no second copy of the data.
    #>
    param(
        [Parameter(Mandatory)]$Server, [pscredential]$Credential, [Parameter(Mandatory)][string]$BackupPath,
        [hashtable]$Options = @{}, $Job, [int]$ProgressBase = 0, [double]$ProgressSpan = 100, [string]$StageDir
    )
    $jobId = if ($Job -and $Job.id) { $Job.id } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to target $($Server.name) ($($Server.host)) via $((Get-PmTransport $Server).ToUpper())..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $agent = [bool]$s.PSObject.Properties['PmAgent']
        $init = Invoke-PmRemote -Session $s -Function 'Initialize-PmRemoteWorkRoot' -Job $Job
        $params = ConvertTo-PmHashtable -InputObject $Options -Keys $script:PmRestoreKeys
        $params.JobId = $jobId
        $params.TargetAddress = [string]$Server.host
        $streams = if ([int]$Options.TransferStreams -gt 0) { [math]::Min(8, [int]$Options.TransferStreams) } else { 4 }
        $chunkBytes = if ([int]$Options.TransferChunkMB -gt 0) { [int64]$Options.TransferChunkMB * 1MB } else { [int64]256MB }

        if (-not $init.Prtg.Installed -and $Options.InstallerFile) {
            $inst = Join-Path (Get-PmPath Installers) (Split-Path $Options.InstallerFile -Leaf)
            if (-not (Test-Path -LiteralPath $inst)) { throw "Installer '$($Options.InstallerFile)' not found in installers folder." }
            Add-PmJobLog -Job $Job -Level STEP -Message "Uploading installer $(Split-Path $inst -Leaf)..."
            $remoteInst = Join-Path $init.Inbox (Split-Path $inst -Leaf)
            Copy-PmToServer -Session $s -LocalPath $inst -RemotePath $remoteInst -Job $Job
            $params.InstallerPath = $remoteInst
        }

        $stageLocal = Get-PmExtractedStage -ZipPath $BackupPath -StageDir $StageDir -Job $Job
        if ($agent) {
            $params.StageDir = ConvertTo-PmTsClientPath $stageLocal
            $params.LogDir = ConvertTo-PmTsClientPath (Join-Path (Get-PmPath Data) 'logs\robocopy')
            Add-PmJobLog -Job $Job -Level DEBUG -Message "Direct restore: target reads $($params.StageDir)"
        } else {
            # Stable folder name per package, so Resume continues the push instead of starting again.
            $remoteStage = Join-Path $init.WorkRoot ('restore\' + [IO.Path]::GetFileNameWithoutExtension($BackupPath))
            [void](Invoke-PmRemote -Session $s -Function 'Clear-PmRemoteStages' -Parameters @{ Keep = $remoteStage } -Job $Job)
            $stageBase = $stageLocal.TrimEnd('\').TrimEnd('/')
            $files = @((Get-PmLocalFileList -Root $stageLocal).GetEnumerator() | ForEach-Object { [pscustomobject]@{ Rel = $_.Value.FullName.Substring($stageBase.Length + 1).Replace('/', '\'); Size = $_.Value.Length; Time = $_.Value.LastWriteTimeUtc.Ticks } })
            $bytes = [int64](($files | Measure-Object -Property Size -Sum).Sum)
            if ($init.FreeBytes -and $init.FreeBytes -lt ($bytes + 2GB)) {
                throw ("Not enough free space on the target: {0:N1} GB free, {1:N1} GB needed." -f ($init.FreeBytes / 1GB), (($bytes + 2GB) / 1GB))
            }
            Invoke-PmTransferFiles -Session $s -Direction Push -RemoteRoot $remoteStage -LocalRoot $stageLocal -Files $files -Job $Job -Label 'package to target' `
                -Server $Server -Credential $Credential -Streams $streams -ChunkBytes $chunkBytes `
                -ProgressBase ($ProgressBase + [int]($ProgressSpan * 0.02)) -ProgressSpan ($ProgressSpan * 0.6)
            $params.StageDir = $remoteStage
            $params.MoveFromStage = $true
            $params.CleanupStage = $true
        }

        $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmRemoteRestore' -Parameters $params -Job $Job `
            -ProgressBase ($ProgressBase + [int]($ProgressSpan * 0.62)) -ProgressSpan ($ProgressSpan * 0.38)
        if (-not $r) { throw 'Remote restore returned no result.' }
        Write-PmAudit -Action 'restore.finished' -Data @{ job = $jobId; server = $Server.name; package = (Split-Path $BackupPath -Leaf); prtg = $r.Report.Prtg; errors = @($r.Report.Errors).Count }
        return $r.Report
    } finally { if ($s) { Close-PmSession $s } }
}

function Invoke-PmUnlicenseFlow {
    <#
        Removes the PRTG license data from a migrated server (target). A source server is
        refused: the license of the original installation is never touched.
    #>
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, $Job, [hashtable]$Options = @{})
    if ($Server.PSObject.Properties['role'] -and $Server.role -eq 'source') { throw "$($Server.name) is a source server - the license of a source is never touched." }
    if ((Get-PmTransport $Server) -eq 'rdp') { throw "$($Server.name): this action needs the WinRM connection method." }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to $($Server.name) ($($Server.host)) via $((Get-PmTransport $Server).ToUpper())..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $p = @{}
        if ([int]$Options.HealthTimeoutMinutes -gt 0) { $p.HealthTimeoutMinutes = [int]$Options.HealthTimeoutMinutes }
        $r = Invoke-PmRemote -Session $s -Function 'Remove-PmPrtgLicense' -Parameters $p -Job $Job -ProgressBase 0 -ProgressSpan 90
        if (-not $r) { throw 'The server returned no result.' }
        Write-PmAudit -Action 'prtg.license.removed' -Data @{ server = $Server.name; removed = @($r.Removed); rollback = $r.Rollback; healthy = $r.Healthy }
        return [pscustomobject]@{ target = $Server.name; ok = $true; removed = @($r.Removed); rollback = $r.Rollback; before = $r.Before; after = $r.After; healthy = $r.Healthy; web = $r.WebUrl; core = $r.Core }
    } finally { Close-PmSession $s }
}

function Invoke-PmRebindFlow {
    <#
        Binds the web server of an already migrated PRTG to the server's own address (it kept
        the source's address and only answers on 127.0.0.1), restarts PRTG and verifies it.
    #>
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, $Job)
    if ((Get-PmTransport $Server) -eq 'rdp') { throw "$($Server.name): this action needs the WinRM connection method." }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to $($Server.name) ($($Server.host)) via $((Get-PmTransport $Server).ToUpper())..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $r = Invoke-PmRemote -Session $s -Function 'Repair-PmPrtgBinding' -Parameters @{ TargetAddress = [string]$Server.host } -Job $Job -ProgressBase 0 -ProgressSpan 100
        Write-PmAudit -Action 'prtg.rebind' -Data @{ server = $Server.name; changed = $r.Changed; before = $r.Before; after = $r.After }
        return [pscustomobject]@{ target = $Server.name; ok = $true; changed = $r.Changed; before = $r.Before; after = $r.After; listens = @($r.ListenEndpoints) }
    } finally { Close-PmSession $s }
}

# ======================================================================= jobs

function New-PmJobObject {
    param([string]$Type, [string]$Summary, [switch]$Console)
    $id = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
    return [hashtable]::Synchronized(@{
            id = $id; type = $Type; summary = $Summary; status = 'queued'; progress = 0; step = 'Queued'
            created = (Get-Date).ToString('o'); started = $null; finished = $null
            logs = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
            result = $null; error = $null; console = [bool]$Console
            params = $null; checkpoint = [hashtable]::Synchronized(@{ backup = $null; stageDir = $null; targetsDone = @() }); resumedFrom = $null
        })
}

function Add-PmJobLog {
    param($Job, [string]$Level = 'INFO', [string]$Message, [string]$Computer = $env:COMPUTERNAME)
    $entry = [pscustomobject]@{ time = (Get-Date).ToString('o'); level = $Level; computer = $Computer; message = $Message }
    if ($Job) {
        [void]$Job.logs.Add($entry)
        try { Add-Content -LiteralPath (Join-Path (Get-PmPath Jobs) "$($Job.id).log") -Value ("{0} [{1}] {2}: {3}" -f $entry.time, $Level, $Computer, $Message) -Encoding UTF8 } catch { }
    }
    if ($Level -in 'WARN', 'ERROR') { Write-PmManagerLog -Level $Level -Message "${Computer}: $Message" -Source $(if ($Job) { "job:$($Job.id)" } else { 'manager' }) }
    # Dashboard console: echo every job's progress live, so one console shows everything.
    if ($Job -and -not $Job.console -and $env:PRTGMOVER_ECHO -eq '1' -and $Level -ne 'DEBUG') {
        try {
            $c = @{ WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; STEP = 'Cyan' }[$Level]; if (-not $c) { $c = 'Gray' }
            [Console]::ForegroundColor = $c
            [Console]::WriteLine(('[{0}] {1,-5} {2,-16} {3}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Computer, $Message))
            [Console]::ResetColor()
        } catch { }
    }
    if ((-not $Job -or $Job.console) -and $Level -ne 'DEBUG') {
        $color = @{ INFO = 'Gray'; WARN = 'Yellow'; ERROR = 'Red'; OK = 'Green'; STEP = 'Cyan' }[$Level]
        if (-not $color) { $color = 'Gray' }
        Write-Host ("[{0}] {1,-5} {2}: {3}" -f (Get-Date -Format 'HH:mm:ss'), $Level, $Computer, $Message) -ForegroundColor $color
    }
}

function Set-PmJobProgress {
    param($Job, [int]$Percent, [string]$Step)
    if (-not $Job) { return }
    $Job.progress = [math]::Max(0, [math]::Min(100, $Percent))
    if ($Step) { $Job.step = $Step }
}

function Save-PmJobRecord {
    param($Job)
    if (-not $Job -or -not $Job.id) { return }
    $rec = [ordered]@{}
    foreach ($k in 'id', 'type', 'summary', 'status', 'progress', 'step', 'created', 'started', 'finished', 'result', 'error', 'params', 'checkpoint', 'resumedFrom') { $rec[$k] = $Job[$k] }
    $rec.logs = @($Job.logs)
    try { ConvertTo-Json -InputObject $rec -Depth 10 | Set-Content -LiteralPath (Join-Path (Get-PmPath Jobs) "$($Job.id).json") -Encoding UTF8 } catch { Write-PmManagerLog -Level ERROR -Message "Could not save job record $($Job.id): $_" }
}

function Set-PmCheckpoint {
    param($Job, [string]$Backup, [string]$StageDir, [string]$TargetDone)
    if (-not $Job) { return }
    if ($Backup) { $Job.checkpoint.backup = $Backup }
    if ($StageDir) { $Job.checkpoint.stageDir = $StageDir }
    if ($TargetDone) { $Job.checkpoint.targetsDone = @(@($Job.checkpoint.targetsDone) + $TargetDone | Select-Object -Unique) }
    Save-PmJobRecord -Job $Job
}

function Invoke-PmDirectTunnelMigrate {
    <#
        Copies source -> target over a tunnel. WinRM (TCP 5985) runs between the
        tunnel addresses, the same point-to-point path a bandwidth test would use.
        This computer opens the command channel and does not receive the files.
    #>
    param(
        [Parameter(Mandatory)]$Source,
        [Parameter(Mandatory)][object[]]$Targets,
        [hashtable]$Options = @{},
        [hashtable]$Credentials,
        $Job
    )
    $kind = [string]$Options.Transfer
    if ($kind -notin 'wireguard', 'ipip') { throw "Tunnel '$kind' is not available." }
    if (@($Targets).Count -lt 1) { throw 'A tunnel needs a target server.' }
    $plan = Get-PmTunnelAddresses -TargetCount @($Targets).Count -Kind $kind
    $label = if ($kind -eq 'ipip') { 'IPIP' } else { 'WireGuard' }
    Add-PmJobLog -Job $Job -Level STEP -Message ("{0}: {1} ({2}) will copy straight to {3}. This computer only sends commands and does not store the backup." -f $label, $Source.name, $plan.Source, (($plan.Targets) -join ', '))
    $srcCred = Resolve-PmCredential $Source $Credentials
    $srcSession = $null
    $opened = @()
    $reports = @()
    try {
        Add-PmJobLog -Job $Job -Level STEP -Message "Command channel to $($Source.name) via $((Get-PmTransport $Source).ToUpper()) (not the file path)..."
        $srcSession = New-PmSession -Server $Source -Credential $srcCred -Job $Job
        $ipipCode = $null
        if ($kind -eq 'ipip') { $ipipCode = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Remote\IpipTunnel.cs')) }
        $srcKey = $null
        if ($kind -eq 'wireguard') {
            $srcKey = Invoke-PmRemote -Session $srcSession -Function 'Install-PmWireGuard' -Job $Job
            if (-not $srcKey.PublicKey) { throw "WireGuard on $($Source.name) did not return a public key." }
        } else {
            [void](Invoke-PmRemote -Session $srcSession -Function 'Install-PmIpip' -Parameters @{ Code = $ipipCode } -Job $Job)
        }
        $tips = @($plan.Targets)
        $i = 0
        foreach ($t in @($Targets)) {
            $tip = [string]$tips[$i]
            $i++
            $tCred = Resolve-PmCredential $t $Credentials
            if (-not $tCred) { throw "$($t.name) needs a saved administrator password so $($Source.name) can sign in over the tunnel." }
            Add-PmJobLog -Job $Job -Level STEP -Message "Command channel to $($t.name) via $((Get-PmTransport $t).ToUpper())..."
            $sess = New-PmSession -Server $t -Credential $tCred -Job $Job
            $pub = $null
            if ($kind -eq 'wireguard') {
                $key = Invoke-PmRemote -Session $sess -Function 'Install-PmWireGuard' -Job $Job
                if (-not $key.PublicKey) { throw "WireGuard on $($t.name) did not return a public key." }
                $pub = [string]$key.PublicKey
            } else {
                [void](Invoke-PmRemote -Session $sess -Function 'Install-PmIpip' -Parameters @{ Code = $ipipCode } -Job $Job)
            }
            $opened += [pscustomobject]@{ Server = $t; Session = $sess; Credential = $tCred; TunnelIp = $tip; PublicKey = $pub }
        }
        if ($kind -eq 'wireguard') {
            $srcPeers = @($opened | ForEach-Object { [pscustomobject]@{ PublicKey = $_.PublicKey; TunnelIp = $_.TunnelIp; PublicIp = [string]$_.Server.host } })
            [void](Invoke-PmRemote -Session $srcSession -Function 'Enable-PmWireGuardEndpoint' -Parameters @{ Address = "$($plan.Source)/24"; ListenPort = $plan.Port; Peers = $srcPeers } -Job $Job)
            foreach ($row in $opened) {
                $peers = @([pscustomobject]@{ PublicKey = [string]$srcKey.PublicKey; TunnelIp = $plan.Source; PublicIp = [string]$Source.host })
                [void](Invoke-PmRemote -Session $row.Session -Function 'Enable-PmWireGuardEndpoint' -Parameters @{ Address = "$($row.TunnelIp)/24"; ListenPort = $plan.Port; Peers = $peers } -Job $Job)
            }
            Add-PmJobLog -Job $Job -Level STEP -Message 'Waiting for the WireGuard handshake...'
            Start-Sleep -Seconds 8
        } else {
            $srcPeers = @($opened | ForEach-Object { [pscustomobject]@{ TunnelIp = $_.TunnelIp; PublicIp = [string]$_.Server.host } })
            [void](Invoke-PmRemote -Session $srcSession -Function 'Enable-PmIpipEndpoint' -Parameters @{ LocalTunnel = $plan.Source; Peers = $srcPeers } -Job $Job)
            foreach ($row in $opened) {
                $peers = @([pscustomobject]@{ TunnelIp = $plan.Source; PublicIp = [string]$Source.host })
                [void](Invoke-PmRemote -Session $row.Session -Function 'Enable-PmIpipEndpoint' -Parameters @{ LocalTunnel = $row.TunnelIp; Peers = $peers } -Job $Job)
            }
            Add-PmJobLog -Job $Job -Level STEP -Message 'Waiting for the IPIP tunnel...'
            Start-Sleep -Seconds 3
        }
        foreach ($row in $opened) {
            $probe = if ($kind -eq 'wireguard') { 'Test-PmWireGuardLink' } else { 'Test-PmTunnelPing' }
            $fromSrc = Invoke-PmRemote -Session $srcSession -Function $probe -Parameters @{ PeerTunnelIp = $row.TunnelIp } -Job $Job
            $fromTgt = Invoke-PmRemote -Session $row.Session -Function $probe -Parameters @{ PeerTunnelIp = $plan.Source } -Job $Job
            if (-not $fromSrc.PingOk -or -not $fromTgt.PingOk) {
                $need = if ($kind -eq 'wireguard') { "UDP $($plan.Port)" } else { 'IP protocol 4' }
                throw "$label between $($Source.name) ($($plan.Source)) and $($row.Server.name) ($($row.TunnelIp)) is not passing traffic. $need must be open between their public addresses."
            }
            Add-PmJobLog -Job $Job -Level OK -Message "Tunnel $($plan.Source) <-> $($row.TunnelIp) is up. The file copy will not touch this computer."
        }
        [void](Invoke-PmRemote -Session $srcSession -Function 'Enable-PmTunnelWinRm' -Parameters @{ TunnelNetwork = [string]$plan.Network } -Job $Job)
        Set-PmJobProgress -Job $Job -Percent 15 -Step "$label tunnel is up"
        $n = 0
        foreach ($row in $opened) {
            $n++
            $localStage = Join-Path (Join-Path 'C:\PrtgMover\tunnel' $Job.id) $row.Server.id
            [void](Invoke-PmRemote -Session $row.Session -Function 'Enable-PmTunnelWinRm' -Parameters @{ TunnelNetwork = [string]$plan.Network } -Job $Job)
            [void](Invoke-PmRemote -Session $row.Session -Function 'New-PmRemoteDirectories' -Parameters @{ Root = $localStage } -Job $Job)
            $peerUser = [string]$row.Credential.UserName
            if ($peerUser -notmatch '\\') { $peerUser = ".\$peerUser" }
            $peerPassword = $row.Credential.GetNetworkCredential().Password
            Add-PmJobLog -Job $Job -Level STEP -Message "WinRM probe $($plan.Source) -> $($row.TunnelIp):5985 (point to point on the tunnel)..."
            [void](Invoke-PmRemote -Session $srcSession -Function 'Measure-PmTunnelWinRm' -Parameters @{
                    PeerTunnelIp = $row.TunnelIp; UserName = $peerUser; Password = $peerPassword
                } -Job $Job)
            $copied = $null
            try {
                $params = ConvertTo-PmHashtable -InputObject $Options -Keys $script:PmBackupKeys
                $params.JobId = [string]$Job.id
                $params.PullMode = $true
                $params.TunnelCopy = $false
                Add-PmJobLog -Job $Job -Level STEP -Message "Reading $($Source.name), then WinRM to $($row.Server.name) at $($row.TunnelIp):5985"
                $copied = Invoke-PmRemote -Session $srcSession -Function 'Invoke-PmRemoteBackup' -Parameters $params -Job $Job -ProgressBase 15 -ProgressSpan 15
                if (-not $copied) { throw "Tunnel copy to $($row.Server.name) returned no result." }
                if ($copied.SourceHealth -and -not $copied.SourceHealth.Healthy) { throw "PRTG on $($Source.name) did not come back up ($($copied.SourceHealth.Message))." }
                $sent = Invoke-PmRemote -Session $srcSession -Function 'Send-PmTunnelWinRmCopy' -Parameters @{
                    PeerTunnelIp = $row.TunnelIp; UserName = $peerUser; Password = $peerPassword
                    Destination = $localStage; StageDir = [string]$copied.StageDir; PullItems = @($copied.PullItems)
                } -Job $Job -ProgressBase 30 -ProgressSpan 20
                if (-not $sent) { throw "WinRM copy to $($row.Server.name) returned no result." }
                $restore = ConvertTo-PmHashtable -InputObject $Options -Keys $script:PmRestoreKeys
                $restore.JobId = [string]$Job.id
                $restore.StageDir = $localStage
                $restore.MoveFromStage = $true
                $restore.CleanupStage = $true
                Add-PmJobLog -Job $Job -Level STEP -Message "Restoring on $($row.Server.name) from the WinRM copy (local disk, not this computer)."
                $rep = Invoke-PmRemote -Session $row.Session -Function 'Invoke-PmRemoteRestore' -Parameters $restore -Job $Job -ProgressBase (50 + ($n - 1) * 20) -ProgressSpan 20
                if (-not $rep) { throw "Restore on $($row.Server.name) returned no result." }
                $ok = (@($rep.Report.Errors).Count -eq 0)
                $reports += [pscustomobject]@{ target = $row.Server.name; ok = $ok; report = $rep.Report; tunnelIp = $row.TunnelIp; winrmMegabytesPerSecond = $sent.MegabytesPerSecond }
                if ($ok) { Set-PmCheckpoint -Job $Job -TargetDone $row.Server.id }
                else { throw "$($row.Server.name) reported errors after the tunnel restore." }
            } finally {
                if ($copied) {
                    try {
                        [void](Invoke-PmRemote -Session $srcSession -Function 'Complete-PmRemotePull' -Parameters @{
                                StageDir = [string]$copied.StageDir; ShadowId = [string]$copied.ShadowId; ShadowLink = [string]$copied.ShadowLink
                            } -Job $Job)
                    } catch { Add-PmJobError -Job $Job -ErrorRecord $_ -Context 'Source cleanup: ' }
                }
            }
        }
        Add-PmJobLog -Job $Job -Level OK -Message "The two servers stay connected on $($plan.Network). This computer did not keep a copy of the backup."
        return [pscustomobject]@{ transfer = $kind; backup = $null; targets = $reports; sourceTunnel = $plan.Source }
    } finally {
        if ($srcSession) { Close-PmSession $srcSession }
        foreach ($row in $opened) { if ($row.Session) { Close-PmSession $row.Session } }
    }
}

function Invoke-PmJob {
    <#
        Executes a job synchronously. $Params:
          test    : ServerIds[], Mode
          backup  : SourceId, Options
          restore : BackupName, TargetIds[], Options
          migrate : SourceId, TargetIds[], Options
          Resume  : checkpoint of a previous run { backup, stageDir, targetsDone[] }
          Credentials : optional hashtable serverId -> PSCredential (one-time, never stored)
        Server addresses are always read fresh from the inventory, so a changed IP is picked
        up by Resume/Retry automatically.
    #>
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$Type, [hashtable]$Params = @{})
    $Job.status = 'running'; $Job.started = (Get-Date).ToString('o')
    $creds = $Params.Credentials
    $options = if ($Params.Options) { ConvertTo-PmHashtable -InputObject $Params.Options } else { @{} }
    # The source is never touched unless the caller explicitly allows it.
    if (-not $options.ContainsKey('NoTouch')) { $options.NoTouch = $true }
    $resume = $Params.Resume
    Write-PmManagerLog -Message "Job $($Job.id) started: $Type $($Job.summary)" -Source "job:$($Job.id)"
    Add-PmJobLog -Job $Job -Level DEBUG -Message ("Job options: " + (($options.GetEnumerator() | Sort-Object Key | ForEach-Object { "$($_.Key)=$($_.Value -join ',')" }) -join '; '))
    try {
        switch ($Type) {
            'test' {
                $results = @(); $ids = @($Params.ServerIds); $n = 0
                foreach ($id in $ids) {
                    $srv = Get-PmServer -Id $id
                    $mode = if ($Params.Mode) { [string]$Params.Mode } else { 'auto' }
                    try { $results += Invoke-PmTestFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Job $Job -Mode $mode }
                    catch { $results += [pscustomobject]@{ ok = $false; error = "$_" } }
                    $n++; Set-PmJobProgress -Job $Job -Percent ([int](100 * $n / $ids.Count)) -Step "Tested $n of $($ids.Count)"
                }
                $Job.result = $results
                if (@($results | Where-Object { -not $_.ok }).Count -gt 0) { throw 'One or more servers failed the test (see the lines above).' }
            }
            'unlicense' {
                # Remove the PRTG license data from migrated servers (never from a source).
                $results = @()
                foreach ($id in @($Params.ServerIds)) {
                    $srv = Get-PmServer -Id $id
                    $results += Invoke-PmUnlicenseFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Job $Job -Options $options
                    # refresh what the dashboard shows for this server
                    try { [void](Invoke-PmTestFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Job $Job -Mode $(if ((Get-PmTransport $srv) -eq 'winrm') { 'winrm' } else { 'auto' })) } catch { Add-PmJobLog -Job $Job -Level WARN -Message "Status refresh failed: $($_.Exception.Message)" }
                }
                $Job.result = $results
            }
            'rebind' {
                # Fix the web server binding of an already migrated PRTG (it kept the source's IP addresses).
                $results = @()
                foreach ($id in @($Params.ServerIds)) {
                    $srv = Get-PmServer -Id $id
                    $results += Invoke-PmRebindFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Job $Job
                }
                $Job.result = $results
            }
            'backup' {
                $srv = Get-PmJobServer -Server (Get-PmServer -Id $Params.SourceId) -Options $options
                if (-not $options.ContainsKey('SourceAfter')) { $options.SourceAfter = 'Restart' }
                [void](Invoke-PmPreflight -Source $srv -Credentials $creds -Options $options -Job $Job)
                $b = Use-PmCompletedStage -Job $Job -SourceName $srv.name
                if (-not $b) { $b = Invoke-PmBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Options $options -Job $Job }
                Set-PmCheckpoint -Job $Job -Backup (Split-Path $b.Zip -Leaf)
                if ($b.StageDir) { Remove-Item -LiteralPath $b.StageDir -Recurse -Force -ErrorAction SilentlyContinue }
                $Job.result = [pscustomobject]@{ backup = (Split-Path $b.Zip -Leaf) }
            }
            'restore' {
                $file = Get-PmBackupFile -Name $Params.BackupName
                $targets = @($Params.TargetIds | Where-Object { -not ($resume -and @($resume.targetsDone) -contains $_) })
                if ($resume) { Add-PmJobLog -Job $Job -Level STEP -Message "Resuming: $(@($resume.targetsDone).Count) target(s) already done, $($targets.Count) remaining." }
                $Job.result = Invoke-PmMultiRestore -File $file -TargetIds $targets -Options $options -Credentials $creds -Job $Job -Base 0 -Span 100
            }
            'migrate' {
                if (-not $options.ContainsKey('SourceAfter')) { $options.SourceAfter = 'KeepStopped' }
                $done = @(); if ($resume) { $done = @($resume.targetsDone) }
                $targetIds = @($Params.TargetIds | Where-Object { $done -notcontains $_ })
                $targets = @($targetIds | ForEach-Object { Get-PmJobServer -Server (Get-PmServer -Id $_) -Options $options })
                $file = $null; $stage = $null
                if ($resume -and $resume.backup -and (Test-Path -LiteralPath (Join-Path (Get-PmPath Backups) $resume.backup))) {
                    $file = Join-Path (Get-PmPath Backups) $resume.backup
                    if ($resume.stageDir -and (Test-Path -LiteralPath (Join-Path $resume.stageDir 'manifest.json'))) { $stage = $resume.stageDir }
                    $man = Read-PmBackupManifest -ZipPath $file
                    Add-PmJobLog -Job $Job -Level STEP -Message "RESUME: the package $($resume.backup) already exists - the source is not contacted again. Remaining target(s): $(@($targets | ForEach-Object { $_.name }) -join ', ')"
                    Set-PmCheckpoint -Job $Job -Backup $resume.backup -StageDir $stage
                    foreach ($d in $done) { Set-PmCheckpoint -Job $Job -TargetDone $d }
                    [void](Invoke-PmPreflight -Source $null -Targets $targets -Credentials $creds -Options $options -Job $Job -DataBytes ([int64]$man.stagingBytes) -SourceVersion $man.prtg.version)
                } else {
                    $srv = Get-PmJobServer -Server (Get-PmServer -Id $Params.SourceId) -Options $options
                    [void](Invoke-PmPreflight -Source $srv -Targets $targets -Credentials $creds -Options $options -Job $Job)
                    if ($options.NoTouch) { Add-PmJobLog -Job $Job -Level WARN -Message 'No-touch mode: the source keeps running. Two PRTG cores with the same configuration will monitor (and alert) in parallel until you shut the old one down.' }
                    if ([string]$options.Transfer -in 'wireguard', 'ipip') {
                        $Job.result = Invoke-PmDirectTunnelMigrate -Source $srv -Targets $targets -Options $options -Credentials $creds -Job $Job
                        $file = $null
                    } else {
                        $b = Use-PmCompletedStage -Job $Job -SourceName $srv.name
                        if (-not $b) { $b = Invoke-PmBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Options $options -Job $Job -ProgressBase 0 -ProgressSpan 40 }
                        $file = $b.Zip; $stage = $b.StageDir
                        Set-PmCheckpoint -Job $Job -Backup (Split-Path $file -Leaf) -StageDir $stage
                    }
                }
                if ([string]$options.Transfer -notin 'wireguard', 'ipip') {
                    $reports = Invoke-PmMultiRestore -File $file -StageDir $stage -TargetIds $targetIds -Options $options -Credentials $creds -Job $Job -Base 40 -Span 60
                    $Job.result = [pscustomobject]@{ backup = (Split-Path $file -Leaf); targets = $reports }
                    if ($stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue; Add-PmJobLog -Job $Job -Level DEBUG -Message "Staging copy removed: $stage" }
                }
            }
            default { throw "Unknown job type '$Type'." }
        }
        $Job.status = 'succeeded'
        Set-PmJobProgress -Job $Job -Percent 100 -Step 'Completed'
        Add-PmJobLog -Job $Job -Level OK -Message "Job $($Job.id) completed successfully."
    } catch {
        $Job.status = 'failed'; $Job.error = "$_"
        Add-PmJobError -Job $Job -ErrorRecord $_ -Context 'Job failed: '
        if ($Type -in 'migrate', 'restore', 'backup') { Add-PmJobLog -Job $Job -Level INFO -Message 'Fix the cause above, then press RESUME - finished steps (package, completed targets) are not repeated and server addresses are re-read from the inventory.' }
    } finally {
        $Job.finished = (Get-Date).ToString('o')
        Save-PmJobRecord -Job $Job
        Write-PmManagerLog -Level $(if ($Job.status -eq 'succeeded') { 'INFO' } else { 'ERROR' }) -Message "Job $($Job.id) $($Job.status). $($Job.error)" -Source "job:$($Job.id)"
    }
}

function Invoke-PmMultiRestore {
    param([string]$File, [string[]]$TargetIds, [hashtable]$Options, [hashtable]$Credentials, $Job, [int]$Base, [int]$Span, [string]$StageDir)
    $reports = @(); $i = 0; $failed = 0
    $slice = $Span / [math]::Max(1, $TargetIds.Count)
    foreach ($id in $TargetIds) {
        $srv = Get-PmJobServer -Server (Get-PmServer -Id $id) -Options $Options
        try {
            $rep = Invoke-PmRestoreFlow -Server $srv -Credential (Resolve-PmCredential $srv $Credentials) -BackupPath $File -StageDir $StageDir -Options $Options -Job $Job `
                -ProgressBase ($Base + [int]($i * $slice)) -ProgressSpan $slice
            $ok = (@($rep.Errors).Count -eq 0)
            $reports += [pscustomobject]@{ target = $srv.name; ok = $ok; report = $rep }
            if ($ok) { Set-PmCheckpoint -Job $Job -TargetDone $id } else { $failed++ }
        } catch {
            $failed++
            Add-PmJobError -Job $Job -ErrorRecord $_ -Context "$($srv.name): "
            $reports += [pscustomobject]@{ target = $srv.name; ok = $false; error = "$_" }
        }
        $i++
    }
    if ($failed -gt 0) { $Job.result = $reports; throw "$failed of $($TargetIds.Count) target(s) reported errors." }
    return $reports
}

function Start-PmJob {
    <# Queues a job on the background runspace pool (used by the dashboard). #>
    param([Parameter(Mandatory)][string]$Type, [hashtable]$Params = @{}, [string]$Summary)
    if (-not $script:PmPool) {
        $script:PmPool = [runspacefactory]::CreateRunspacePool(1, 4)
        $script:PmPool.Open()
    }
    $job = New-PmJobObject -Type $Type -Summary $Summary
    # Keep the parameters (without one-time credentials) so the job can be resumed/retried later.
    $saved = @{}
    foreach ($k in $Params.Keys) { if ($k -notin 'Credentials', 'Resume') { $saved[$k] = $Params[$k] } }
    $job.params = $saved
    if ($Params.ResumedFrom) { $job.resumedFrom = $Params.ResumedFrom }
    $script:PmJobs[$job.id] = $job
    Save-PmJobRecord -Job $job
    Write-PmAudit -Action 'job.started' -Data @{ id = $job.id; type = $Type; summary = $Summary; resumedFrom = $Params.ResumedFrom }
    $ps = [powershell]::Create()
    $ps.RunspacePool = $script:PmPool
    [void]$ps.AddScript({
            param($ModulePath, $Root, $Job, $Type, $Params)
            Import-Module $ModulePath -Force -DisableNameChecking
            Set-PmRoot -Path $Root
            Invoke-PmJob -Job $Job -Type $Type -Params $Params
        }).AddArgument((Join-Path $PSScriptRoot 'PrtgMover.psm1')).AddArgument($script:PmRoot).AddArgument($job).AddArgument($Type).AddArgument($Params)
    $script:PmJobHandles[$job.id] = @{ PowerShell = $ps; Async = $ps.BeginInvoke() }
    return $job
}

function Stop-PmJob {
    param([Parameter(Mandatory)][string]$Id)
    $h = $script:PmJobHandles[$Id]; $job = $script:PmJobs[$Id]
    if ($h -and $job -and $job.status -in 'queued', 'running') {
        $h.PowerShell.BeginStop($null, $null) | Out-Null
        $job.status = 'cancelled'; $job.finished = (Get-Date).ToString('o')
        Write-PmAudit -Action 'job.cancelled' -Data @{ id = $Id }
        Add-PmJobLog -Job $job -Level WARN -Message 'Job cancelled by user (remote operations already started may still finish on the server).'
        Save-PmJobRecord -Job $job
    }
}

function Repair-PmInterruptedJobs {
    <# Called at dashboard start: jobs recorded as running/queued were interrupted by a restart - make them resumable. #>
    foreach ($f in (Get-ChildItem -LiteralPath (Get-PmPath Jobs) -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($j.status -in 'running', 'queued') {
                $j.status = 'interrupted'
                $j.error = 'The dashboard was restarted while this job was running - press Resume to continue.'
                if (-not $j.finished) { $j | Add-Member -NotePropertyName finished -NotePropertyValue ((Get-Date).ToString('o')) -Force }
                ConvertTo-Json -InputObject $j -Depth 10 | Set-Content -LiteralPath $f.FullName -Encoding UTF8
                Write-PmManagerLog -Level WARN -Message "Job $($j.id) marked as interrupted (dashboard restart)." -Source 'dashboard'
            }
        } catch { }
    }
}

function Resume-PmJob {
    <#
        Starts a new job that continues a failed / cancelled one: the package that was
        already built and targets that already finished are skipped. Server addresses are
        re-read from the inventory, so a changed IP is used automatically.
    #>
    param([Parameter(Mandatory)][string]$Id)
    $old = $script:PmJobs[$Id]
    if (-not $old) {
        $f = Join-Path (Get-PmPath Jobs) "$Id.json"
        if (-not (Test-Path -LiteralPath $f)) { throw "Job '$Id' not found." }
        $old = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    if ($old.status -in 'queued', 'running') { throw 'The job is still running.' }
    if (-not $old.params) { throw 'This job was created by an older version and cannot be resumed - start it again from the dashboard.' }
    $p = ConvertTo-PmHashtable -InputObject $old.params
    foreach ($k in 'ServerIds', 'TargetIds') { if ($p.ContainsKey($k)) { $p[$k] = [string[]]@($p[$k]) } }
    $p.ResumedFrom = $old.id
    $cp = $old.checkpoint
    if ($cp -and ($cp.backup -or @($cp.targetsDone).Count)) {
        $p.Resume = [pscustomobject]@{ backup = $cp.backup; stageDir = $cp.stageDir; targetsDone = @($cp.targetsDone) }
    }
    $names = @{}; foreach ($s in (Get-PmServers)) { $names[$s.id] = $s.name }
    $summary = "Resume of $($old.id): " + ($old.summary -replace '^Resume of [^:]+: ', '')
    return Start-PmJob -Type $old.type -Params $p -Summary $summary
}

function Get-PmJobs {
    <# In-memory jobs plus finished jobs persisted on disk (newest first, without logs). #>
    $list = @{}
    foreach ($f in (Get-ChildItem -LiteralPath (Get-PmPath Jobs) -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 100)) {
        try { $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json; $list[$j.id] = $j } catch { }
    }
    foreach ($j in @($script:PmJobs.Values)) { $list[$j.id] = [pscustomobject]$j }
    $list.Values | Sort-Object { $_.created } -Descending | ForEach-Object {
        [pscustomobject]@{ id = $_.id; type = $_.type; summary = $_.summary; status = $_.status; progress = $_.progress; step = $_.step; created = $_.created; finished = $_.finished; error = $_.error }
    }
}

function Get-PmJob {
    param([Parameter(Mandatory)][string]$Id, [int]$Since = 0)
    $j = $script:PmJobs[$Id]
    if (-not $j) {
        $f = Join-Path (Get-PmPath Jobs) "$Id.json"
        if (-not (Test-Path -LiteralPath $f)) { return $null }
        $j = Get-Content -LiteralPath $f -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    $logs = @($j.logs)
    [pscustomobject]@{
        id = $j.id; type = $j.type; summary = $j.summary; status = $j.status; progress = $j.progress; step = $j.step
        created = $j.created; started = $j.started; finished = $j.finished; error = $j.error; result = $j.result
        checkpoint = $j.checkpoint; resumedFrom = $j.resumedFrom
        resumable = [bool]($j.params -and $j.status -in 'failed', 'cancelled', 'interrupted')
        logCount = $logs.Count; logs = @($logs | Select-Object -Skip $Since)
    }
}

function Get-PmInstallers {
    Get-ChildItem -LiteralPath (Get-PmPath Installers) -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.zip' } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; size = $_.Length; created = $_.LastWriteTime.ToString('o') } }
}

# Pure tunnel helpers live in the remote script and are also used on the manager to plan addresses.
. (Join-Path $PSScriptRoot 'Remote\PrtgMover.Remote.ps1')

Export-ModuleMember -Function *-Pm*
