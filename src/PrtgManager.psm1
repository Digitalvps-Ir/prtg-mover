<#
    PrtgManager.psm1 - manager-side module.

    Runs on the "manager" machine. Opens PowerShell remoting sessions to source and
    target servers, ships src\Remote\PrtgManager.Remote.ps1 with every call, moves the
    backup package through the manager (so the manager always keeps a downloadable
    copy) and tracks everything as jobs that the web dashboard and CLI can follow.
#>

$script:PmRoot = Split-Path $PSScriptRoot -Parent
$script:PmRemoteCode = $null
$script:PmJobs = [hashtable]::Synchronized(@{})
$script:PmJobHandles = [hashtable]::Synchronized(@{})
$script:PmPool = $null

$script:PmBackupKeys = 'IncludePrtg', 'IncludeHistory', 'IncludeDesktop', 'ExtraPaths', 'SourceAfter', 'NoTouch', 'HealthTimeoutMinutes', 'IncludeProgram', 'IncludeLogs', 'IncludeAutoBackups', 'Scope', 'HistoryDays'
$script:PmRestoreKeys = 'RestorePrtg', 'RestoreDesktop', 'RestoreExtra', 'InstallerArgs', 'AllowDowngrade', 'StartServices', 'HealthTimeoutMinutes', 'CopyLicense', 'OpenFirewall', 'MoveFromStage', 'CleanupStage', 'TargetAddress', 'GraphMode', 'AutoRollback'

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
        'Remote'      { Join-Path $PSScriptRoot 'Remote\PrtgManager.Remote.ps1' }   # part of the program, not of the data root
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
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    try { return Import-Clixml -LiteralPath $f -ErrorAction Stop }
    catch {
        # Windows protects a saved password for the account that saved it (DPAPI).
        throw "The saved credential of this server cannot be read by $env:USERDOMAIN\$env:USERNAME: it was saved while PRTG Manager ran under another Windows account. Enter user and password again (Servers > Edit). [$($_.Exception.Message)]"
    }
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
    if ($root -notmatch '^([A-Za-z]):\\?(.*)$') { throw "RDP mode needs PRTG Manager on a local drive (current: $root)." }
    $rest = $Matches[2].TrimEnd('\')
    if ($rest) { return "\\tsclient\$($Matches[1].ToUpper())\$rest" }
    return "\\tsclient\$($Matches[1].ToUpper())"
}

function Get-PmAgentCommand {
    param([Parameter(Mandatory)]$Server)
    $script = Join-Path (Get-PmTsClientRoot) 'agent\PrtgManager-Agent.ps1'
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
        PRTG Manager is redirected into the session, so the agent can be started from
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
        Executes one function of PrtgManager.Remote.ps1 on the server (WinRM session or RDP
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
    if (-not $inside) { throw "$LocalPath is outside the PRTG Manager folder." }
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
# A package is a zip (or, encrypted with a backup password, a .pmenc file) in backups\ with a sidecar
# <file>.meta.json: source, sha256 of the file, manifest (readable without the password), created,
# encrypted, validation. Types: full, graphs, devices, notifications, triggers, license (+ legacy
# PRTG Mover packages: formatVersion 1, full). VPN-only packages of PRTG Mover belong to VPN Manager
# and are not listed here.

$script:PmPackageTypes = 'full', 'graphs', 'devices', 'notifications', 'triggers', 'license'
$script:PmFormatVersion = 2

function Get-PmAppVersion {
    $f = Join-Path (Split-Path $PSScriptRoot -Parent) 'VERSION'
    if (Test-Path -LiteralPath $f) { return ([IO.File]::ReadAllText($f)).Trim() }
    return 'dev'
}

function Get-PmBackupType {
    <# Type of a package from its manifest: full / graphs / devices / notifications / triggers / license / vpn (old VPN-only) / files. #>
    param($Manifest, [string]$Name)
    if ($Manifest) {
        if ($Manifest.PSObject.Properties['type'] -and [string]$Manifest.type -in $script:PmPackageTypes) { return [string]$Manifest.type }
        if ($Manifest.prtg -and $Manifest.prtg.included) { return 'full' }
        if ($Manifest.PSObject.Properties['vpn'] -and $Manifest.vpn -and $Manifest.vpn.included) { return 'vpn' }
        return 'files'
    }
    if ($Name -like 'VPN_*') { return 'vpn' }
    if ($Name -match '^PRTG-([A-Za-z]+)_') { $t = $Matches[1].ToLowerInvariant(); if ($t -in $script:PmPackageTypes) { return $t } }
    return 'full'
}

function Get-PmBackupKind {
    <# Kept for older callers: 'prtg' (anything with PRTG), 'vpn' (old VPN-only packages), 'files'. #>
    param($Manifest, [string]$Name)
    $t = Get-PmBackupType -Manifest $Manifest -Name $Name
    if ($t -eq 'vpn') { return 'vpn' }
    if ($t -eq 'files') { return 'files' }
    return 'prtg'
}

function Read-PmBackupMeta {
    param([Parameter(Mandatory)][string]$Path)
    $side = "$Path.meta.json"
    if (-not (Test-Path -LiteralPath $side)) { return $null }
    try { return (Get-Content -LiteralPath $side -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { return $null }
}

function Write-PmBackupMeta {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Meta)
    ConvertTo-Json -InputObject $Meta -Depth 10 | Set-Content -LiteralPath "$Path.meta.json" -Encoding UTF8
}

function Get-PmBackups {
    <# PRTG packages on the manager, newest first, with type, source, version, encryption and the last validation. #>
    param([switch]$IncludeVpn)
    $dir = Get-PmPath Backups
    Get-ChildItem -LiteralPath $dir -File | Where-Object { $_.Extension -in '.zip', '.pmenc' } | Sort-Object LastWriteTime -Descending | ForEach-Object {
        $meta = Read-PmBackupMeta -Path $_.FullName
        $m = if ($meta) { $meta.manifest } else { $null }
        $type = Get-PmBackupType -Manifest $m -Name $_.Name
        if ($type -eq 'vpn' -and -not $IncludeVpn) { return }
        $enc = ($_.Extension -eq '.pmenc')
        $val = if ($meta -and $meta.PSObject.Properties['validation']) { $meta.validation } else { $null }
        $prtgVer = if ($m -and $m.prtg -and $m.prtg.version) { [string]$m.prtg.version } elseif ($m -and $m.PSObject.Properties['prtgVersion']) { [string]$m.prtgVersion } else { $null }
        [pscustomobject]@{
            name = $_.Name; type = $type; size = $_.Length; created = $(if ($m -and $m.createdUtc) { [string]$m.createdUtc } else { $_.LastWriteTime.ToString('o') })
            source = $(if ($meta) { $meta.source } elseif ($m) { $m.source.computer } else { $null })
            sha256 = $(if ($meta) { $meta.sha256 } else { $null }); manifest = $m
            formatVersion = $(if ($m -and $m.formatVersion) { [int]$m.formatVersion } else { $null }); appVersion = $(if ($m -and $m.PSObject.Properties['appVersion']) { [string]$m.appVersion } else { $null })
            prtgVersion = $prtgVer; encrypted = $enc; secretsEncrypted = [bool]($m -and $m.PSObject.Properties['encryption'] -and $m.encryption -and $m.encryption.secrets)
            valid = $(if ($val) { [bool]$val.valid } else { $null }); validated = $(if ($val) { [string]$val.checked } else { $null }); validationErrors = $(if ($val) { @($val.errors) } else { @() })
            kind = Get-PmBackupKind -Manifest $m -Name $_.Name
        }
    }
}

function Get-PmBackupFile {
    <# Resolves a backup name to a full path, refusing anything outside the backups folder. #>
    param([Parameter(Mandatory)][string]$Name)
    $leaf = Split-Path $Name -Leaf
    if ($leaf -ne $Name -or $leaf -notmatch '\.(zip|pmenc)$') { throw "Invalid backup name '$Name'." }
    $full = Join-Path (Get-PmPath Backups) $leaf
    if (-not (Test-Path -LiteralPath $full)) { throw "Backup '$Name' not found in $(Get-PmPath Backups)." }
    return $full
}

function Read-PmZipText {
    <# Text of one entry of a zip, or $null. #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)][string]$Entry)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        $e = $zip.Entries | Where-Object { $_.FullName -eq $Entry -or $_.FullName -eq $Entry.Replace('/', '\') -or $_.FullName -eq $Entry.Replace('\', '/') } | Select-Object -First 1
        if (-not $e) { return $null }
        $r = New-Object IO.StreamReader($e.Open(), [Text.Encoding]::UTF8)
        try { return $r.ReadToEnd() } finally { $r.Dispose() }
    } finally { $zip.Dispose() }
}

function Read-PmBackupManifest {
    param([Parameter(Mandatory)][string]$ZipPath)
    if ($ZipPath -like '*.pmenc') { $meta = Read-PmBackupMeta -Path $ZipPath; if ($meta) { return $meta.manifest }; return $null }
    $txt = Read-PmZipText -ZipPath $ZipPath -Entry 'manifest.json'
    if (-not $txt) { return $null }
    return ($txt | ConvertFrom-Json)
}

function Register-PmBackup {
    <# Writes the sidecar metadata used by the dashboard (also used for uploaded backups). #>
    param([Parameter(Mandatory)][string]$ZipPath, [string]$Source, $Manifest)
    if ($ZipPath -like '*.pmenc') {
        if (-not $Manifest) {
            $old = Read-PmBackupMeta -Path $ZipPath
            if ($old) { $Manifest = $old.manifest }
        }
        # an uploaded encrypted package without its sidecar: only the envelope can be checked
        $fs = [IO.File]::OpenRead($ZipPath); try { $head = New-Object byte[] 43; [void]$fs.Read($head, 0, 43) } finally { $fs.Dispose() }
        [void](Read-PmEncHeader -Header $head)
    } elseif (-not $Manifest) {
        $Manifest = Read-PmBackupManifest -ZipPath $ZipPath
        if (-not $Manifest) { throw 'The file is not a PRTG Manager backup (manifest.json missing).' }
        if ($Manifest.tool -notin 'prtg-mover', 'prtg-manager') { throw "The file is not a PRTG Manager backup (tool '$($Manifest.tool)')." }
    }
    if (-not $Source -and $Manifest) { $Source = $Manifest.source.computer }
    Write-PmBackupMeta -Path $ZipPath -Meta ([pscustomobject]@{ source = $Source; sha256 = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash; manifest = $Manifest; encrypted = ($ZipPath -like '*.pmenc'); registered = (Get-Date).ToString('o') })
}

function Get-PmDeleteMode {
    <#
        'recycle' when a person runs the dashboard (their Recycle Bin), 'permanent' when it runs as SYSTEM / without a
        desktop (the task at system start): SYSTEM's Recycle Bin is invisible to the administrators and frees no space,
        and an error dialog there has nobody to answer it and would stop the dashboard.
    #>
    if ($env:PRTGMANAGER_DELETE_MODE -in 'recycle', 'permanent') { return $env:PRTGMANAGER_DELETE_MODE }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if ($id.IsSystem -or -not [Environment]::UserInteractive) { return 'permanent' }
    return 'recycle'
}

function Remove-PmBackup {
    <# Moves a package (and its sidecar) to the Recycle Bin; deletes it for good when the dashboard runs as SYSTEM (see Get-PmDeleteMode). #>
    param([Parameter(Mandatory)][string]$Name)
    $f = Get-PmBackupFile -Name $Name
    $mode = Get-PmDeleteMode
    Add-Type -AssemblyName Microsoft.VisualBasic
    foreach ($x in @($f, "$f.meta.json")) {
        if (-not (Test-Path -LiteralPath $x)) { continue }
        if ($env:PRTGMOVER_TEST -eq '1' -and $env:PRTGMANAGER_RECYCLE -and $mode -eq 'recycle') {
            Move-Item -LiteralPath $x -Destination (Join-Path $env:PRTGMANAGER_RECYCLE (Split-Path $x -Leaf)) -Force
            continue
        }
        if ($mode -eq 'permanent') {
            try { Remove-Item -LiteralPath $x -Force -ErrorAction Stop }
            catch { throw "Delete backup '$Name' failed: $($_.Exception.Message). It was left in place." }
            continue
        }
        try { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($x, [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs, [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin) }
        catch { throw "Delete backup '$Name' failed: the file could not be moved to the Recycle Bin ($($_.Exception.Message)). It was left in place." }
    }
    return $mode
}

function Get-PmZipEntryHash {
    param([Parameter(Mandatory)]$Entry)
    $sha = [Security.Cryptography.SHA256]::Create(); $s = $Entry.Open()
    try { return (-join ($sha.ComputeHash($s) | ForEach-Object { $_.ToString('X2') })) } finally { $s.Dispose(); $sha.Dispose() }
}

function Test-PmBackupPackage {
    <#
        Validates a package: readable, supported format, manifest, checksums (the file against its sidecar,
        every listed file against the manifest, PRTG Configuration.dat against the source) and, for an
        encrypted file, the password (HMAC) when one is given. Stores the result in the sidecar.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; used for the HMAC check only.')]
    param([Parameter(Mandatory)][string]$Name, [string]$Password, $Job)
    $f = Get-PmBackupFile -Name $Name
    $meta = Read-PmBackupMeta -Path $f
    $checks = New-Object System.Collections.ArrayList; $errors = New-Object System.Collections.ArrayList; $warn = New-Object System.Collections.ArrayList
    $add = { param([string]$What, [bool]$Ok, [string]$Detail) [void]$checks.Add([pscustomobject]@{ check = $What; ok = $Ok; detail = $Detail }); if (-not $Ok) { [void]$errors.Add("$What - $Detail") }; Add-PmJobLog -Job $Job -Level $(if ($Ok) { 'OK' } else { 'ERROR' }) -Message "$What : $Detail" }
    Add-PmJobLog -Job $Job -Level STEP -Message "Validating $Name ($([math]::Round((Get-Item -LiteralPath $f).Length / 1MB, 1)) MB)..."
    if ($meta -and $meta.sha256) {
        $h = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash
        & $add 'File checksum (SHA-256)' ($h -eq $meta.sha256) $(if ($h -eq $meta.sha256) { 'identical to the one taken when the package was made' } else { "changed since the package was made (now $($h.Substring(0,16))..., was $($meta.sha256.Substring(0,16))...)" })
    } else { [void]$warn.Add('No sidecar with the original checksum (uploaded file?) - the file checksum cannot be compared.') }
    $m = $null
    if ($f -like '*.pmenc') {
        try {
            $fs = [IO.File]::OpenRead($f); try { $head = New-Object byte[] 43; [void]$fs.Read($head, 0, 43) } finally { $fs.Dispose() }
            $hd = Read-PmEncHeader -Header $head
            & $add 'Encryption header' $true ("AES-256-CBC + HMAC-SHA256, key from PBKDF2-{0} with {1} rounds" -f $(if ($hd.Kdf -eq 1) { 'SHA256' } else { 'SHA1' }), $hd.Iterations)
        } catch { & $add 'Encryption header' $false "$($_.Exception.Message)" }
        if ($Password) {
            try { [void](Test-PmEncryptedFile -Path $f -Password $Password); & $add 'Password and integrity (HMAC)' $true 'the password is right and the file is unchanged' }
            catch { & $add 'Password and integrity (HMAC)' $false "$($_.Exception.Message)" }
        } else { [void]$warn.Add('Encrypted: enter the backup password to check the password and the integrity of the content (HMAC).') }
        if ($meta) { $m = $meta.manifest }
    } else {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = $null
        try { $zip = [IO.Compression.ZipFile]::OpenRead($f); & $add 'Zip archive' $true "$($zip.Entries.Count) entries" }
        catch { & $add 'Zip archive' $false "cannot be opened: $($_.Exception.Message)" }
        if ($zip) {
            try {
                $me = $zip.Entries | Where-Object { $_.FullName -eq 'manifest.json' } | Select-Object -First 1
                if (-not $me) { & $add 'Manifest' $false 'manifest.json is missing' }
                else {
                    $r = New-Object IO.StreamReader($me.Open()); try { $m = $r.ReadToEnd() | ConvertFrom-Json } finally { $r.Dispose() }
                    $fv = [int]$m.formatVersion
                    & $add 'Format' ($m.tool -in 'prtg-mover', 'prtg-manager' -and $fv -ge 1 -and $fv -le $script:PmFormatVersion) ("tool {0}, format version {1}{2}" -f $m.tool, $fv, $(if ($fv -gt $script:PmFormatVersion) { ' - made by a newer PRTG Manager, update this one' } else { '' }))
                    foreach ($fe in @($m.files)) {
                        if (-not $fe) { continue }
                        $e = $zip.Entries | Where-Object { $_.FullName -eq $fe.path -or $_.FullName -eq ([string]$fe.path).Replace('/', '\') } | Select-Object -First 1
                        if (-not $e) { & $add "File $($fe.path)" $false 'missing in the package'; continue }
                        $eh = Get-PmZipEntryHash -Entry $e
                        & $add "File $($fe.path)" ($eh -eq $fe.sha256) $(if ($eh -eq $fe.sha256) { 'checksum OK' } else { 'checksum does not match the manifest' })
                    }
                    if ($m.prtg -and $m.prtg.included -and $m.prtg.configSha256) {
                        $ce = $zip.Entries | Where-Object { $_.FullName -in 'prtg\data\PRTG Configuration.dat', 'prtg/data/PRTG Configuration.dat' } | Select-Object -First 1
                        if (-not $ce) { & $add 'PRTG Configuration.dat' $false 'missing in the package' }
                        else { $ch = Get-PmZipEntryHash -Entry $ce; & $add 'PRTG Configuration.dat' ($ch -eq $m.prtg.configSha256) $(if ($ch -eq $m.prtg.configSha256) { 'identical to the configuration read on the source' } else { 'differs from the configuration read on the source' }) }
                    }
                    if ([string]$m.type -eq 'graphs') {
                        $n = @($zip.Entries | Where-Object { $_.FullName -match '^prtg[\\/]graphs[\\/].+\.\w+$' }).Count
                        & $add 'History files' ($n -eq [int]$m.graphs.files -or -not $m.graphs.files) "$n file(s) in the package, $($m.graphs.files) listed"
                    }
                }
            } finally { $zip.Dispose() }
        }
    }
    $valid = ($errors.Count -eq 0)
    $res = [pscustomobject]@{ name = $Name; valid = $valid; checked = (Get-Date).ToString('o'); checks = @($checks); errors = @($errors); warnings = @($warn); passwordChecked = [bool]$Password; type = (Get-PmBackupType -Manifest $m -Name $Name) }
    if ($meta) { $meta | Add-Member -NotePropertyName validation -NotePropertyValue ([pscustomobject]@{ valid = $valid; checked = $res.checked; errors = @($errors) }) -Force; Write-PmBackupMeta -Path $f -Meta $meta }
    elseif ($m) { Write-PmBackupMeta -Path $f -Meta ([pscustomobject]@{ source = $m.source.computer; sha256 = (Get-FileHash -LiteralPath $f -Algorithm SHA256).Hash; manifest = $m; encrypted = ($f -like '*.pmenc'); validation = [pscustomobject]@{ valid = $valid; checked = $res.checked; errors = @($errors) } }) }
    Write-PmAudit -Action 'backup.validated' -Data @{ name = $Name; valid = $valid; errors = $errors.Count; passwordChecked = [bool]$Password }
    foreach ($w in $warn) { Add-PmJobLog -Job $Job -Level WARN -Message $w }
    Add-PmJobLog -Job $Job -Level $(if ($valid) { 'OK' } else { 'ERROR' }) -Message "Validation of ${Name}: $(if ($valid) { 'VALID' } else { "INVALID ($($errors.Count) problem(s))" })"
    return $res
}

function Get-PmBackupDetails {
    <# Inspect: metadata, manifest, sections, counts, file list (first 300) - no secret values. #>
    param([Parameter(Mandatory)][string]$Name)
    $f = Get-PmBackupFile -Name $Name
    $meta = Read-PmBackupMeta -Path $f
    $m = if ($meta) { $meta.manifest } else { Read-PmBackupManifest -ZipPath $f }
    $files = @(); $count = $null; $bytes = $null
    if ($f -like '*.zip') {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $zip = [IO.Compression.ZipFile]::OpenRead($f)
        try {
            $count = $zip.Entries.Count; $bytes = [int64](($zip.Entries | Measure-Object Length -Sum).Sum)
            $files = @($zip.Entries | Select-Object -First 300 | ForEach-Object { [pscustomobject]@{ path = $_.FullName; size = $_.Length } })
        } finally { $zip.Dispose() }
    }
    [pscustomobject]@{
        name = $Name; type = (Get-PmBackupType -Manifest $m -Name $Name); size = (Get-Item -LiteralPath $f).Length; encrypted = ($f -like '*.pmenc')
        sha256 = $(if ($meta) { $meta.sha256 }); source = $(if ($meta) { $meta.source }); manifest = $m; validation = $(if ($meta -and $meta.PSObject.Properties['validation']) { $meta.validation })
        entries = $count; unpackedBytes = $bytes; files = $files
    }
}

function New-PmManifestV2 {
    <# Common metadata of a PRTG Manager package (format version 2). #>
    param([Parameter(Mandatory)][string]$Type, [Parameter(Mandatory)][string]$Computer, [string]$Os, [string]$Server, [string]$PrtgVersion, [string]$JobId)
    return [ordered]@{
        tool = 'prtg-manager'; format = 'prtg-manager-backup'; formatVersion = $script:PmFormatVersion; type = $Type
        appVersion = (Get-PmAppVersion); jobId = $JobId; createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = [ordered]@{ computer = $Computer; os = $Os; server = $Server }
        components = [ordered]@{ prtg = $PrtgVersion; manager = (Get-PmAppVersion); powershell = $PSVersionTable.PSVersion.ToString() }
        prtg = [ordered]@{ included = $false; version = $PrtgVersion }
        sections = @(); counts = [ordered]@{}; files = @(); encryption = [ordered]@{ package = $false; secrets = $false }; warnings = @()
    }
}

function New-PmZipFromFiles {
    <# Zip with manifest.json + the given files (path -> bytes); fills manifest.files with size + SHA-256. #>
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)][hashtable]$Files)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $list = @()
    foreach ($k in ($Files.Keys | Sort-Object)) {
        $b = [byte[]]$Files[$k]
        $sha = [Security.Cryptography.SHA256]::Create(); try { $h = -join ($sha.ComputeHash($b) | ForEach-Object { $_.ToString('X2') }) } finally { $sha.Dispose() }
        $list += [ordered]@{ path = $k; size = $b.Length; sha256 = $h }
    }
    $Manifest.files = @($list)
    if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($ZipPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        $write = { param([string]$Name, [byte[]]$Bytes) $e = $zip.CreateEntry($Name, [IO.Compression.CompressionLevel]::Optimal); $s = $e.Open(); try { $s.Write($Bytes, 0, $Bytes.Length) } finally { $s.Dispose() } }
        & $write 'manifest.json' ([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Manifest -Depth 10)))
        foreach ($k in ($Files.Keys | Sort-Object)) { & $write $k ([byte[]]$Files[$k]) }
    } finally { $zip.Dispose() }
}

function Complete-PmPackage {
    <# Registers a finished zip; with a password it is encrypted into .pmenc (the plain zip is replaced). Returns the final path. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param([Parameter(Mandatory)][string]$ZipPath, [Parameter(Mandatory)]$Manifest, [string]$Source, [string]$Password, $Job)
    $final = $ZipPath
    if ($Password) {
        Add-PmJobLog -Job $Job -Level STEP -Message 'Encrypting the package with the backup password (AES-256 + HMAC-SHA256)...'
        $enc = [IO.Path]::ChangeExtension($ZipPath, '.pmenc')
        Protect-PmFile -Source $ZipPath -Destination $enc -Password $Password
        $Manifest.encryption = [ordered]@{ package = $true; secrets = [bool]$Manifest.encryption.secrets; algorithm = 'AES-256-CBC + HMAC-SHA256'; kdf = $(if ((Get-PmDefaultKdf).Kdf -eq 1) { 'PBKDF2-SHA256' } else { 'PBKDF2-SHA1' }) }
        Remove-Item -LiteralPath $ZipPath, "$ZipPath.meta.json" -Force -ErrorAction SilentlyContinue
        $final = $enc
    }
    $hash = (Get-FileHash -LiteralPath $final -Algorithm SHA256).Hash
    Write-PmBackupMeta -Path $final -Meta ([pscustomobject]@{ source = $Source; sha256 = $hash; manifest = $Manifest; encrypted = [bool]$Password; created = (Get-Date).ToString('o') })
    Add-PmJobLog -Job $Job -Level OK -Message ("Package ready: {0} ({1:N2} MB, SHA-256 {2}{3})" -f (Split-Path $final -Leaf), ((Get-Item -LiteralPath $final).Length / 1MB), $hash, $(if ($Password) { ', encrypted' } else { '' }))
    Write-PmAudit -Action 'backup.created' -Data @{ job = $(if ($Job) { $Job.id }); package = (Split-Path $final -Leaf); type = [string]$Manifest.type; sha256 = $hash; encrypted = [bool]$Password }
    return $final
}

function Get-PmPlainPackage {
    <# The zip of a package: the file itself, or for .pmenc a decrypted temp copy (Temp = $true, delete it after use). #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param([Parameter(Mandatory)][string]$Path, [string]$Password, $Job)
    if ($Path -notlike '*.pmenc') { return [pscustomobject]@{ Path = $Path; Temp = $false } }
    if (-not $Password) { throw "The package $(Split-Path $Path -Leaf) is encrypted - enter its backup password." }
    $dir = Join-Path (Get-PmPath Data) 'staging'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    $tmp = Join-Path $dir ('decrypted-{0}.zip' -f [IO.Path]::GetFileNameWithoutExtension($Path))
    Add-PmJobLog -Job $Job -Level STEP -Message "Checking the password and decrypting $(Split-Path $Path -Leaf) on the manager..."
    Unprotect-PmFile -Source $Path -Destination $tmp -Password $Password
    Add-PmJobLog -Job $Job -Level OK -Message 'Password OK, package decrypted (the temporary copy is removed after the job).'
    return [pscustomobject]@{ Path = $tmp; Temp = $true }
}

function Remove-PmPlainPackage {
    <#
        Removes what a decrypted package left on the manager: the temporary zip and the folder a restore
        extracted it into (data\staging\restore-<name>). Nothing is removed for a package that was not
        encrypted - its zip is the backup itself.
    #>
    param($Plain)
    if (-not $Plain -or -not $Plain.Temp) { return }
    Remove-Item -LiteralPath $Plain.Path -Force -ErrorAction SilentlyContinue
    $extract = Join-Path (Get-PmPath Data) ('staging\restore-' + [IO.Path]::GetFileNameWithoutExtension($Plain.Path))
    if (Test-Path -LiteralPath $extract) { Remove-Item -LiteralPath $extract -Recurse -Force -ErrorAction SilentlyContinue }
}

function Clear-PmStaleDecrypted {
    <#
        Called when the dashboard starts: a restore of an encrypted package that was cut off (process
        killed, computer restarted) never reached its cleanup, so its decrypted zip and extract stay in
        data\staging. They are removed - unless a command-line restore (cli\Invoke-PrtgManager.ps1) is
        running right now and may still use them. Returns the removed paths.
    #>
    $dir = Join-Path (Get-PmPath Data) 'staging'
    if (-not (Test-Path -LiteralPath $dir)) { return @() }
    $cli = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe' OR Name='pwsh.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -match '(?i)Invoke-Prtg(Manager|Mover)\.ps1' })
    if ($cli.Count) { Write-PmManagerLog -Level INFO -Message 'Decrypted restore copies are kept: a command-line restore is running.' -Source 'dashboard'; return @() }
    $gone = New-Object System.Collections.ArrayList
    foreach ($i in @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'decrypted-*.zip' -or ($_.PSIsContainer -and $_.Name -like 'restore-decrypted-*') })) {
        try { Remove-Item -LiteralPath $i.FullName -Recurse -Force -ErrorAction Stop; [void]$gone.Add($i.FullName) }
        catch { Write-PmManagerLog -Level WARN -Message "Could not remove the decrypted copy $($i.FullName): $($_.Exception.Message)" -Source 'dashboard' }
    }
    if ($gone.Count) { Write-PmManagerLog -Level WARN -Message "Removed $($gone.Count) decrypted package copy/copies left by an interrupted restore: $($gone -join ', ')" -Source 'dashboard' }
    return @($gone)
}

function Get-PmPackageUser {
    <# The id of a running / queued job that restores or previews this package, or '' - two at once would share its decrypted copy. #>
    param([Parameter(Mandatory)][string]$Name)
    foreach ($j in @($script:PmJobs.Values)) {
        if ($j.status -in 'queued', 'running' -and $j.type -in 'restore', 'restore-preview' -and $j.params -and [string]$j.params.BackupName -eq $Name) { return [string]$j.id }
    }
    return ''
}

# ======================================================================= PRTG parts, license, previews (flows)

function Assert-PmNotSource {
    <# PRTG Manager never changes a server that is marked as source. #>
    param([Parameter(Mandatory)]$Server, [string]$What = 'change')
    if ($Server.PSObject.Properties['role'] -and $Server.role -eq 'source') { throw "$($Server.name) is marked as a source server - PRTG Manager does not $What it. Set its role to 'Target' or 'Source & target' first if you really want this." }
}

function Invoke-PmSectionBackupFlow {
    <# Backup of one part (devices / notifications / triggers / license). Nothing is written on the server. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, [Parameter(Mandatory)][ValidateSet('devices', 'notifications', 'triggers', 'license')][string]$Type, [string]$Password, $Job)
    if ($Type -eq 'license' -and -not $Password) { throw 'A license backup contains the license key: enter a backup password (at least 8 characters) to encrypt it.' }
    if ($Password) { Assert-PmBackupPassword $Password }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to $($Server.name) ($($Server.host)) via $((Get-PmTransport $Server).ToUpper())..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $files = @{}
        if ($Type -eq 'license') {
            $r = Invoke-PmRemote -Session $s -Function 'Backup-PmPrtgLicense' -Parameters @{ Password = $Password } -Job $Job -ProgressBase 10 -ProgressSpan 60
            if (-not $r) { throw 'The server returned no result.' }
            $m = New-PmManifestV2 -Type 'license' -Computer $r.Computer -Server $Server.name -PrtgVersion $r.PrtgVersion -JobId $Job.id
            $m.sections = @('license'); $m.counts = [ordered]@{ values = @($r.ValueNames).Count; files = @($r.FileNames).Count }
            $m.license = [ordered]@{ valueNames = @($r.ValueNames); fileNames = @($r.FileNames); edition = $r.State.Edition; name = $r.State.Name; maxSensors = $r.State.MaxSensors; activated = [bool]($r.State.Known -and -not $r.State.NeedsActivation) }
            $m.encryption = [ordered]@{ package = $false; secrets = $true; algorithm = 'AES-256-CBC + HMAC-SHA256'; encryptedOn = $r.Computer }
            $files['license.enc'] = [Convert]::FromBase64String([string]$r.Envelope)
            $Password = $null   # the key is already encrypted on the server; the package itself stays readable
        } else {
            $r = Invoke-PmRemote -Session $s -Function 'Get-PmPrtgSection' -Parameters @{ Type = $Type } -Job $Job -ProgressBase 10 -ProgressSpan 60
            if (-not $r) { throw 'The server returned no result.' }
            $m = New-PmManifestV2 -Type $Type -Computer $r.Computer -Os $r.Os -Server $Server.name -PrtgVersion $r.PrtgVersion -JobId $Job.id
            $m.sections = @($Type); $m.prtg.configVersion = $r.Header.ConfigVersion; $m.prtg.maxId = $r.Header.Max
            $sum = [ordered]@{}; foreach ($p in $r.Summary.PSObject.Properties) { if ($p.Name -notin 'type', 'prtgVersion', 'configVersion') { $sum[$p.Name] = $p.Value } }
            $m.counts = $sum
            $files["$Type.xml"] = [Text.Encoding]::UTF8.GetBytes((ConvertFrom-PmPackedText ([string]$r.Packed)))
        }
        $zipName = 'PRTG-{0}_{1}_{2}.zip' -f $Type.ToUpperInvariant(), $m.source.computer, (Get-Date -Format 'yyyyMMdd-HHmmss')
        $zip = Join-Path (Get-PmPath Backups) $zipName
        New-PmZipFromFiles -ZipPath $zip -Manifest $m -Files $files
        $final = Complete-PmPackage -ZipPath $zip -Manifest $m -Source $Server.name -Password $Password -Job $Job
        return [pscustomobject]@{ backup = (Split-Path $final -Leaf); type = $Type; counts = $m.counts }
    } finally { Close-PmSession $s }
}

function Read-PmSectionPackage {
    <# Type + packed XML (or the license envelope) of a part package. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param([Parameter(Mandatory)][string]$Path, [string]$Password, $Job)
    $plain = Get-PmPlainPackage -Path $Path -Password $Password -Job $Job
    try {
        $m = Read-PmBackupManifest -ZipPath $plain.Path
        $type = Get-PmBackupType -Manifest $m -Name (Split-Path $Path -Leaf)
        if ($type -eq 'license') {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $zip = [IO.Compression.ZipFile]::OpenRead($plain.Path)
            try { $e = $zip.Entries | Where-Object { $_.FullName -eq 'license.enc' } | Select-Object -First 1; if (-not $e) { throw 'license.enc is missing in the package.' }; $ms = New-Object IO.MemoryStream; $st = $e.Open(); try { $st.CopyTo($ms) } finally { $st.Dispose() }; $env64 = [Convert]::ToBase64String($ms.ToArray()) } finally { $zip.Dispose() }
            return [pscustomobject]@{ Type = $type; Manifest = $m; Envelope = $env64; Packed = $null }
        }
        if ($type -notin 'devices', 'notifications', 'triggers') { throw "This is a '$type' package - use the restore of full / history packages for it." }
        $xml = Read-PmZipText -ZipPath $plain.Path -Entry "$type.xml"
        if (-not $xml) { throw "$type.xml is missing in the package." }
        return [pscustomobject]@{ Type = $type; Manifest = $m; Envelope = $null; Packed = (ConvertTo-PmPackedText $xml) }
    } finally { if ($plain.Temp) { Remove-Item -LiteralPath $plain.Path -Force -ErrorAction SilentlyContinue } }
}

function Invoke-PmSectionRestoreFlow {
    <# Restores a part package (devices / notifications / triggers / license) into one server. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, [Parameter(Mandatory)][string]$Path, [hashtable]$Options = @{}, [string]$Password, $Job)
    Assert-PmNotSource -Server $Server -What 'restore into'
    if ((Get-PmTransport $Server) -eq 'rdp') { throw "$($Server.name): restoring a part needs the WinRM or Local connection method." }
    $pkg = Read-PmSectionPackage -Path $Path -Password $Password -Job $Job
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to $($Server.name) ($($Server.host)) via $((Get-PmTransport $Server).ToUpper())..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $hm = if ([int]$Options.HealthTimeoutMinutes -gt 0) { [int]$Options.HealthTimeoutMinutes } else { 15 }
        if ($pkg.Type -eq 'license') {
            if (-not $Password) { throw 'The license in this package is encrypted - enter the backup password.' }
            $r = Invoke-PmRemote -Session $s -Function 'Install-PmPrtgLicense' -Parameters @{ Envelope = $pkg.Envelope; Password = $Password; HealthTimeoutMinutes = $hm; Force = $true } -Job $Job -ProgressBase 5 -ProgressSpan 90
            Write-PmAudit -Action 'prtg.license.restored' -Data @{ server = $Server.name; package = (Split-Path $Path -Leaf); activated = [bool]$r.Activated; rollback = $r.Rollback }
            return [pscustomobject]@{ target = $Server.name; ok = [bool]$r.Healthy; type = 'license'; activated = [bool]$r.Activated; hint = $r.Hint; after = $r.After; rollback = $r.Rollback }
        }
        $mode = if ([string]$Options.Mode -eq 'overwrite') { 'overwrite' } else { 'merge' }
        $p = @{ Packed = $pkg.Packed; Mode = $mode; ReIdConflicts = [bool]$Options.ReIdConflicts; StartServices = $(if ($null -ne $Options.StartServices) { [bool]$Options.StartServices } else { $true }); HealthTimeoutMinutes = $hm }
        $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmSectionRestore' -Parameters $p -Job $Job -ProgressBase 5 -ProgressSpan 90
        if (-not $r) { throw 'The server returned no result.' }
        Write-PmAudit -Action 'prtg.section.restored' -Data @{ server = $Server.name; package = (Split-Path $Path -Leaf); type = $pkg.Type; mode = $mode; changed = [bool]$r.Changed; rolledBack = [bool]$r.RolledBack; created = $(if ($r.Applied) { $r.Applied.created }); updated = $(if ($r.Applied) { $r.Applied.updated }) }
        if ($r.RolledBack) { throw "Restore of $($pkg.Type) on $($Server.name) failed and was rolled back: $($r.Error)" }
        if ($r.Error) { throw "Restore of $($pkg.Type) on $($Server.name) failed: $($r.Error)" }
        return [pscustomobject]@{ target = $Server.name; ok = $true; type = $pkg.Type; changed = [bool]$r.Changed; applied = $r.Applied; plan = $r.Plan.Counts; rollback = $r.Rollback; web = $r.WebUrl }
    } finally { Close-PmSession $s }
}

function Get-PmFullRestorePreview {
    <# PURE. Preview of a full restore from the package manifest and the facts of the target. #>
    param([Parameter(Mandatory)]$Manifest, [Parameter(Mandatory)]$Facts, [hashtable]$Options = @{}, [int64]$PackageBytes = 0)
    $items = New-Object System.Collections.ArrayList; $blockers = @(); $warn = @(); $deps = @()
    $p = $Manifest.prtg
    $tp = $Facts.Prtg
    if ($tp.Installed) {
        # PRTG is already installed: nothing is installed, the program and its services stay; only the data, registry and customisations are replaced
        [void]$items.Add([pscustomobject]@{ Action = 'skip'; Item = 'PRTG program'; Detail = "PRTG $($tp.Version) is already installed - it is kept, nothing is installed$(if ($p.programCloned) { ' (the program clone in the package is not used)' })" })
        [void]$items.Add([pscustomobject]@{ Action = 'update'; Item = 'PRTG configuration'; Detail = "replaced: target has $($Facts.ConfigStats); backup has $($p.configStats)" })
        $dp = if ($tp.DataPath) { [string]$tp.DataPath } else { '<data>' }
        [void]$items.Add([pscustomobject]@{ Action = 'update'; Item = 'PRTG data folder'; Detail = ("{0} gets the restored data; the current one ({1:N2} GB) is kept as {0}.pre-restore-<time> for the rollback$(if ($p.dataPath -and ([string]$p.dataPath).TrimEnd('\') -ine $dp) { " (the source used $($p.dataPath))" })" -f $dp, ($Facts.DataBytes / 1GB)) })
    } else {
        [void]$items.Add([pscustomobject]@{ Action = 'create'; Item = 'PRTG'; Detail = $(if ($p.programCloned) { 'installed from the program clone in the package (no installer)' } elseif ($Options.InstallerFile) { "installed with $($Options.InstallerFile)" } else { 'NOT installed here and the package has no program clone' }) })
        if (-not $p.programCloned -and -not $Options.InstallerFile) { $blockers += 'PRTG is not installed on the target, the package has no program clone and no installer was chosen.' }
    }
    [void]$items.Add([pscustomobject]@{ Action = $(if ($p.includeHistory) { 'create' } else { 'skip' }); Item = 'History (graphs)'; Detail = $(if ($p.includeHistory) { 'included' } else { 'not in this package' }) })
    [void]$items.Add([pscustomobject]@{ Action = $(if ($Options.CopyLicense -ne $false) { 'update' } else { 'skip' }); Item = 'License'; Detail = $(if ($Options.CopyLicense -ne $false) { 'the source license is copied - PRTG asks Paessler for a new activation on this server' } else { "the target keeps its own license$(if ($Facts.License -and $Facts.License.Known) { " ($($Facts.License.Edition))" })" }) })
    [void]$items.Add([pscustomobject]@{ Action = 'update'; Item = 'Registry, customisations'; Detail = "registry of PRTG, $(@($p.programFolders).Count) customisation folder(s)" })
    if ($p.version -and $tp.Version) {
        $sv = [version]($p.version -replace '[^\d\.]', ''); $tv = [version]($tp.Version -replace '[^\d\.]', '')
        if ($tv -lt $sv) { if ($Options.AllowDowngrade) { $warn += "Target PRTG $tv is older than the backup ($sv) - allowed by 'Allow downgrade', PRTG may not start." } else { $blockers += "Target PRTG $tv is older than the backup ($sv). Update PRTG on the target first." } }
        elseif ($tv -gt $sv) { $warn += "Target PRTG $tv is newer than the backup ($sv) - PRTG converts the configuration when it starts." }
    }
    # the same rule as the restore on the target: the extracted package + the restored data + 1 GB (the current data folder is kept beside it)
    $need = [int64]$Manifest.stagingBytes; if (-not $need) { $need = $PackageBytes }
    $required = [int64](2 * $need + 1GB)
    if ($Facts.FreeBytes -and $Facts.FreeBytes -lt ($need + 2GB)) { $blockers += ("Not enough free space on the target: {0:N1} GB free, at least {1:N1} GB needed." -f ($Facts.FreeBytes / 1GB), (($need + 2GB) / 1GB)) }
    elseif ($Facts.FreeBytes -and $Facts.FreeBytes -lt $required) { $warn += ("Free space on the target is tight: {0:N1} GB free. A package sent as a zip is unpacked there and then copied into place - that needs about {1:N1} GB and the restore stops before changing anything if it is not there. The current data folder is kept beside the restored one for the rollback." -f ($Facts.FreeBytes / 1GB), ($required / 1GB)) }
    if ([int]$p.netFrameworkRelease -and [int]$Facts.NetRelease -and [int]$Facts.NetRelease -lt [int]$p.netFrameworkRelease) { $deps += ".NET Framework on the target (release $($Facts.NetRelease)) is older than on the source ($($p.netFrameworkRelease)); install the same version if PRTG does not start." }
    if (-not $Facts.IsAdmin) { $blockers += 'The connection to the target has no administrator rights.' }
    return [pscustomobject]@{ Type = 'full'; Items = @($items); Blockers = $blockers; Warnings = $warn; MissingDependencies = $deps; Target = [pscustomobject]@{ Computer = $Facts.Computer; PrtgVersion = $tp.Version; Installed = [bool]$tp.Installed; ConfigStats = $Facts.ConfigStats; FreeBytes = $Facts.FreeBytes }; Rollback = 'automatic: the previous data folder and registry are put back when the restored PRTG does not come up' }
}

function Get-PmZipGraphFiles {
    <# History files listed in a package (relative path below prtg\graphs, day, device, size). #>
    param([Parameter(Mandatory)][string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try {
        foreach ($e in $zip.Entries) {
            if ($e.FullName -notmatch '^prtg[\\/]graphs[\\/](.+)$' -or -not $e.Name) { continue }
            $rel = $Matches[1].Replace('/', '\')
            $day = ''; if ($rel -match '^(\d{8})\\') { $day = $Matches[1] }
            $dev = 0; if ($e.Name -match '^Device (\d+)\.') { $dev = [int]$Matches[1] }
            [pscustomobject]@{ Rel = $rel; Day = $day; Device = $dev; Size = $e.Length }
        }
    } finally { $zip.Dispose() }
}

function Invoke-PmRestorePreviewFlow {
    <# READ-ONLY on the target: what a restore of this package would do there. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, [Parameter(Mandatory)][string]$Path, [hashtable]$Options = @{}, [string]$Password, $Job)
    $meta = Read-PmBackupMeta -Path $Path
    $m = if ($meta) { $meta.manifest } else { Read-PmBackupManifest -ZipPath $Path }
    $type = Get-PmBackupType -Manifest $m -Name (Split-Path $Path -Leaf)
    $role = if ($Server.PSObject.Properties['role']) { [string]$Server.role } else { 'both' }
    Add-PmJobLog -Job $Job -Level STEP -Message "Preview of $(Split-Path $Path -Leaf) ($type) on $($Server.name) - nothing is changed there."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $out = $null
        switch ($type) {
            { $_ -in 'devices', 'notifications', 'triggers' } {
                $pkg = Read-PmSectionPackage -Path $Path -Password $Password -Job $Job
                $mode = if ([string]$Options.Mode -eq 'overwrite') { 'overwrite' } else { 'merge' }
                $r = Invoke-PmRemote -Session $s -Function 'Get-PmSectionRestorePreview' -Parameters @{ Packed = $pkg.Packed; Mode = $mode; ReIdConflicts = [bool]$Options.ReIdConflicts } -Job $Job
                $out = $r.Plan
            }
            'license' {
                $r = Invoke-PmRemote -Session $s -Function 'Get-PmPrtgLicenseStatus' -Job $Job
                $cur = if ($r.Installed -and $r.State -and $r.State.Known) { "$($r.State.Edition)$(if ($r.State.Name) { " - licensed for '$($r.State.Name)'" })$(if ($r.State.NeedsActivation) { ' (not activated)' })" } else { 'no license information' }
                $items = @([pscustomobject]@{ Action = 'update'; Item = 'License'; Detail = "replaces the current license ($cur) with the one of the backup ($($m.license.edition), made on $($m.source.computer)); a copy of the current one is kept" })
                $warn = @(); if ($m.source.computer -and $m.source.computer -ne $r.Computer) { $warn += "The backup comes from $($m.source.computer). PRTG activates per system: on $($r.Computer) PRTG asks Paessler for a new activation (the key must allow it)." }
                $out = [pscustomobject]@{ Type = 'license'; Items = $items; Blockers = $(if (-not $r.Installed) { @('PRTG is not installed on the target.') } else { @() }); Warnings = $warn; MissingDependencies = @($(if (-not $Password) { 'The backup password is needed to restore the license.' })) | Where-Object { $_ }; Current = $r.State; Hint = $r.Hint }
            }
            'graphs' {
                $plain = Get-PmPlainPackage -Path $Path -Password $Password -Job $Job
                try { $files = @(Get-PmZipGraphFiles -ZipPath $plain.Path) } finally { if ($plain.Temp) { Remove-Item -LiteralPath $plain.Path -Force -ErrorAction SilentlyContinue } }
                $f = Invoke-PmRemote -Session $s -Function 'Get-PmGraphTargetFacts' -Job $Job
                $mode = if ([string]$Options.GraphMode -eq 'overwrite') { 'overwrite' } else { 'merge' }
                $g = Get-PmGraphRestorePlan -Files $files -TargetFiles @($f.Files) -TargetDevices @($f.Devices | ForEach-Object { [int]$_ }) -Mode $mode
                $items = @(
                    [pscustomobject]@{ Action = 'create'; Item = 'History files'; Detail = ("{0} new file(s), {1:N2} GB" -f $g.New, ($g.NewBytes / 1GB)) },
                    [pscustomobject]@{ Action = $(if ($mode -eq 'overwrite') { 'update' } else { 'skip' }); Item = 'History files already on the target'; Detail = "$($g.Existing) file(s) - $(if ($mode -eq 'overwrite') { 'replaced' } else { 'kept' })" }
                )
                $out = [pscustomobject]@{ Type = 'graphs'; Items = $items; Blockers = $(if (-not $f.Prtg.Installed) { @('PRTG is not installed on the target.') } else { @() }); Warnings = @($g.Warnings); MissingDependencies = @(); Counts = $g }
            }
            default {
                $f = Invoke-PmRemote -Session $s -Function 'Get-PmRestoreTargetFacts' -Job $Job
                $out = Get-PmFullRestorePreview -Manifest $m -Facts $f -Options $Options -PackageBytes ((Get-Item -LiteralPath $Path).Length)
            }
        }
        if ($role -eq 'source') { $out.Blockers = @($out.Blockers) + "$($Server.name) is marked as a source server - PRTG Manager does not restore into it." }
        return [pscustomobject]@{ target = $Server.name; package = (Split-Path $Path -Leaf); type = $type; preview = $out }
    } finally { Close-PmSession $s }
}

function Invoke-PmLicenseFlow {
    <# License actions on one server: status (read-only), install (trial / bought key), remove. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'License key typed in the dashboard; sent to the server only.')]
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, [Parameter(Mandatory)][ValidateSet('status', 'install', 'remove')][string]$Action, [hashtable]$Options = @{}, [hashtable]$Secrets = @{}, $Job)
    if ($Action -ne 'status') {
        Assert-PmNotSource -Server $Server -What 'change the license of'
        if ((Get-PmTransport $Server) -eq 'rdp') { throw "$($Server.name): license changes need the WinRM or Local connection method." }
    }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to $($Server.name) ($($Server.host)) via $((Get-PmTransport $Server).ToUpper())..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $hm = if ([int]$Options.HealthTimeoutMinutes -gt 0) { [int]$Options.HealthTimeoutMinutes } else { 15 }
        switch ($Action) {
            'status' {
                $r = Invoke-PmRemote -Session $s -Function 'Get-PmPrtgLicenseStatus' -Job $Job
                if (-not $r.Installed) { Add-PmJobLog -Job $Job -Level WARN -Message "$($Server.name): PRTG is not installed." }
                else { Add-PmJobLog -Job $Job -Level $(if ($r.State.Known -and -not $r.State.NeedsActivation) { 'OK' } else { 'WARN' }) -Message "$($Server.name): $(if ($r.State.Known) { "$($r.State.Edition)$(if ($r.State.Name) { ", licensed for '$($r.State.Name)'" }), $($r.State.MaxSensors) sensors" } else { 'no license line in the core log' }). $($r.Hint)" }
                return [pscustomobject]@{ target = $Server.name; ok = $true; action = 'status'; status = $r }
            }
            'install' {
                $kind = if ([string]$Options.Kind -eq 'trial') { 'trial' } else { 'commercial' }
                $r = Invoke-PmRemote -Session $s -Function 'Install-PmPrtgLicense' -Parameters @{ LicenseName = [string]$Secrets.LicenseName; LicenseKey = [string]$Secrets.LicenseKey; Kind = $kind; HealthTimeoutMinutes = $hm; Force = [bool]$Options.Force } -Job $Job -ProgressBase 5 -ProgressSpan 90
                if (-not $r) { throw 'The server returned no result.' }
                Write-PmAudit -Action 'prtg.license.installed' -Data @{ server = $Server.name; kind = $kind; activated = [bool]$r.Activated; edition = $r.After.Edition; rollback = $r.Rollback }
                return [pscustomobject]@{ target = $Server.name; ok = [bool]$r.Healthy; action = 'install'; kind = $kind; activated = [bool]$r.Activated; hint = $r.Hint; before = $r.Before; after = $r.After; rollback = $r.Rollback; web = $r.WebUrl }
            }
            'remove' {
                $r = Invoke-PmRemote -Session $s -Function 'Remove-PmPrtgLicense' -Parameters @{ HealthTimeoutMinutes = $hm } -Job $Job -ProgressBase 5 -ProgressSpan 85
                if (-not $r) { throw 'The server returned no result.' }
                Write-PmAudit -Action 'prtg.license.removed' -Data @{ server = $Server.name; removed = @($r.Removed); rollback = $r.Rollback; healthy = $r.Healthy }
                $st = Invoke-PmRemote -Session $s -Function 'Get-PmPrtgLicenseStatus' -Job $Job
                Add-PmJobLog -Job $Job -Level OK -Message "License state after the removal: $(if ($st.State.Known) { $st.State.Edition } else { 'no license line yet' }); key present: $([bool]$st.HasKey)."
                return [pscustomobject]@{ target = $Server.name; ok = $true; action = 'remove'; removed = @($r.Removed); rollback = $r.Rollback; before = $r.Before; after = $r.After; status = $st; healthy = $r.Healthy; web = $r.WebUrl }
            }
        }
    } finally { Close-PmSession $s }
}

# ======================================================================= flows

function Get-PmConnectHint {
    param([string]$Message, $Ports)
    if ($Ports -and -not $Ports.winrm) {
        return "WinRM port $($Ports.winrmPort) is not reachable. Use the RDP connection method, or enable remoting on the server (tools\Enable-PrtgManagerRemoting.ps1) and open the firewall for the manager."
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

function Invoke-PmHousekeeping {
    <#
        Keeps the long-running dashboard small: manager and robocopy logs older than $LogDays are deleted, job records
        older than $JobDays (the newest $KeepJobs always stay), and the audit log is rotated at 10 MB (3 old copies).
        Backups, credentials and the server list are never touched.
    #>
    param([int]$LogDays = 30, [int]$JobDays = 90, [int]$KeepJobs = 200)
    $removed = 0
    $logs = Join-Path (Get-PmPath Data) 'logs'
    $old = (Get-Date).AddDays(-$LogDays)
    foreach ($f in @(Get-ChildItem -LiteralPath $logs -Filter 'manager-*.log' -File -ErrorAction SilentlyContinue) + @(Get-ChildItem -LiteralPath (Join-Path $logs 'robocopy') -File -ErrorAction SilentlyContinue)) {
        if ($f.LastWriteTime -lt $old) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $removed++ }
    }
    $jobs = @(Get-ChildItem -LiteralPath (Get-PmPath Jobs) -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending)
    $jold = (Get-Date).AddDays(-$JobDays)
    foreach ($f in @($jobs | Select-Object -Skip $KeepJobs)) {
        if ($f.LastWriteTime -lt $jold -and -not $script:PmJobs.ContainsKey($f.BaseName)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction SilentlyContinue; $removed++ }
    }
    $audit = Join-Path $logs 'audit.log'
    if ((Test-Path -LiteralPath $audit) -and (Get-Item -LiteralPath $audit).Length -gt 10MB) {
        for ($i = 3; $i -ge 1; $i--) {
            $from = if ($i -eq 1) { $audit } else { "$audit.$($i - 1)" }
            if (Test-Path -LiteralPath $from) { Move-Item -LiteralPath $from -Destination "$audit.$i" -Force }
        }
    }
    Clear-PmFinishedJobs
    $script:PmLastHousekeeping = Get-Date
    if ($removed) { Write-PmManagerLog -Message "Housekeeping: $removed old log / job file(s) removed." -Source 'dashboard' }
    return $removed
}

function Get-PmLeftovers {
    <#
        READ-ONLY. What restores, backups and cancelled runs left on THIS computer, with sizes:
        unpacked packages (data\staging), the work folder (temporary restore stages, transfer chunks, rollback copies,
        kept licenses), the work folder of the earlier name (C:\PrtgMover), previous PRTG data folders kept by a restore
        (<data>.pre-restore-* / .failed-restore-*) and VSS snapshots left by an interrupted backup (C:\PrtgMoverVss_*).
    #>
    $items = New-Object Collections.Generic.List[object]
    $add = {
        param([string]$Kind, [string]$Path, [string]$Note)
        if (-not (Test-Path -LiteralPath $Path)) { return }
        $it = Get-Item -LiteralPath $Path -Force
        $size = if ($it.PSIsContainer) { [int64](Get-PmDirectorySize -Path $Path) } else { [int64]$it.Length }
        $items.Add([pscustomobject]@{ kind = $Kind; path = $it.FullName; bytes = $size; changed = $it.LastWriteTime.ToString('o'); note = $Note })
    }
    foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path (Get-PmPath Data) 'staging') -Force -ErrorAction SilentlyContinue)) { & $add 'unpacked package' $d.FullName 'Temporary copy for a restore or backup - not needed when no job is running.' }
    $work = Get-PmWorkRoot
    $legacy = if ($env:SystemDrive) { Join-Path $env:SystemDrive 'PrtgMover' } else { $null }
    foreach ($w in @($work, $legacy) | Where-Object { $_ } | Select-Object -Unique) {
        $isOld = ($w -ne $work) -and -not (Test-Path -LiteralPath (Join-Path $w 'Start-PrtgMover.ps1')) -and -not (Test-Path -LiteralPath (Join-Path $w 'Start-PrtgManager.ps1'))
        if ($w -ne $work -and -not $isOld) { continue }   # an installation of the earlier name is not a leftover
        foreach ($sub in 'restore', 'chunks', 'staging', 'out', 'in', 'installer') {
            foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $w $sub) -Force -ErrorAction SilentlyContinue)) { & $add 'temporary' $d.FullName 'Temporary restore stage / transfer file.' }
        }
        foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $w 'rollback') -Force -ErrorAction SilentlyContinue)) { & $add 'rollback copy' $d.FullName 'Registry / configuration copy taken before a restore or license change - keep it until the result is confirmed.' }
        foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $w 'license-keep') -Force -ErrorAction SilentlyContinue)) { & $add 'rollback copy' $d.FullName 'License files of this server kept during a restore.' }
    }
    $prtg = $null; try { $prtg = Get-PmPrtgInfo } catch { }
    if ($prtg -and $prtg.Installed -and $prtg.DataPath) {
        $dp = ([string]$prtg.DataPath).TrimEnd('\'); $parent = Split-Path $dp -Parent; $leaf = Split-Path $dp -Leaf
        foreach ($d in @(Get-ChildItem -LiteralPath $parent -Directory -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "$leaf.pre-restore-*" -or $_.Name -like "$leaf.failed-restore-*" })) {
            & $add 'previous PRTG data' $d.FullName $(if ($d.Name -like '*.pre-restore-*') { 'The PRTG data folder before a restore - the rollback of that restore needs it. Remove it only when the restored PRTG is fine.' } else { 'Data of a restore that was rolled back.' })
        }
    }
    if ($env:SystemDrive) { foreach ($l in @(Get-ChildItem -LiteralPath ($env:SystemDrive + '\') -Filter 'PrtgMoverVss_*' -Force -ErrorAction SilentlyContinue)) { $items.Add([pscustomobject]@{ kind = 'snapshot'; path = $l.FullName; bytes = [int64]0; changed = $l.LastWriteTime.ToString('o'); note = 'VSS snapshot left by an interrupted backup - it grows on the system drive while it exists.' }) } }
    return $items.ToArray()
}

function Remove-PmLeftover {
    <# Removes ONE item listed by Get-PmLeftovers (for good). Refused while a job is running. #>
    param([Parameter(Mandatory)][string]$Path)
    $busy = @($script:PmJobs.Values | Where-Object { $_.status -in 'queued', 'running' })
    if ($busy.Count) { throw "Job $($busy[0].id) is running - remove leftovers when no job runs." }
    $item = @(Get-PmLeftovers | Where-Object { $_.path -ieq $Path.TrimEnd('\') })[0]
    if (-not $item) { throw "'$Path' is not a leftover of PRTG Manager on this computer." }
    if ($item.kind -eq 'snapshot') { Clear-PmStaleSnapshots | Out-Null }
    else { Remove-Item -LiteralPath $item.path -Recurse -Force -ErrorAction Stop }
    Write-PmAudit -Action 'leftover.removed' -Data @{ path = $item.path; kind = $item.kind; bytes = $item.bytes }
    return $item
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
    & $add 'PRTG Manager version' ((Get-Content (Join-Path (Get-PmPath Root) 'VERSION') -ErrorAction SilentlyContinue | Select-Object -First 1))
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
    $zip = Join-Path $diagDir "prtg-manager-diagnostics-$stamp.zip"
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($tmp, $zip)
    Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $diagDir -Filter '*.zip' | Sort-Object LastWriteTime -Descending | Select-Object -Skip 5 | Remove-Item -Force -ErrorAction SilentlyContinue
    Write-PmAudit -Action 'diagnostics.created' -Data @{ file = (Split-Path $zip -Leaf) }
    return $zip
}

# ======================================================================= tests

function Test-PmElevated {
    try { return [bool](New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { return $false }
}

function Invoke-PmLocalTestFlow {
    <#
        Connection method 'local': PRTG Manager is installed on the server itself. Nothing is
        connected; the check runs in this process. It passes when PRTG Manager has administrator
        rights, because backup (snapshot, registry) and restore (services) need them.
    #>
    param([Parameter(Mandatory)]$Server, $Job)
    Add-PmJobLog -Job $Job -Level STEP -Message "Testing $($Server.name) - this computer ($env:COMPUTERNAME), connection method LOCAL"
    $now = (Get-Date).ToString('o')
    $info = $null; $ok = $false; $detail = ''
    try {
        $s = New-PmSession -Server $Server -Job $Job
        $info = Invoke-PmRemote -Session $s -Function 'Get-PmSystemInfo' -Job $Job
        $ok = [bool]$info.IsAdmin -or $env:PRTGMOVER_TEST -eq '1'
        $detail = if ($ok) { 'this computer, administrator rights OK' } else { 'PRTG Manager is NOT running as administrator. Close it and start it with "Run as administrator" (the installer option -Local sets this up).' }
    } catch {
        $detail = Format-PmManagerError $_
        Add-PmJobError -Job $Job -ErrorRecord $_ -Context 'Local system check: '
    }
    Add-PmJobLog -Job $Job -Level $(if ($ok) { 'OK' } else { 'ERROR' }) -Message "Local test: $(if ($ok) { 'PASS' } else { 'FAIL' }) - $detail"
    if ($info) {
        Add-PmJobLog -Job $Job -Level OK -Computer $info.Computer -Message ("{0}: {1} | admin={2} | PRTG={3} {4} ({5} GB data, core {6})" -f $info.Computer, $info.OS, $info.IsAdmin,
                $(if ($info.Prtg.Installed) { 'yes' } else { 'no' }), $info.Prtg.Version, $info.PrtgDataGB, $info.Prtg.CoreStatus)
        foreach ($d in @($info.Disks)) { Add-PmJobLog -Job $Job -Message ("Disk {0} {1} GB free of {2} GB" -f $d.Drive, $d.FreeGB, $d.SizeGB) -Computer $info.Computer }
        if ($info.Prtg.Installed -and $info.PrtgConfigStats) { Add-PmJobLog -Job $Job -Message "PRTG configuration: $($info.PrtgConfigStats)" -Computer $info.Computer }
    }
    $status = [pscustomobject]@{
        ok = $ok; checked = $now; lastMode = 'local'
        methods = [pscustomobject][ordered]@{ rdp = $null; winrm = $null; local = [ordered]@{ ok = $ok; checked = $now; detail = $detail } }
        info = $info; error = $(if ($ok) { $null } else { $detail }); ports = $null
    }
    $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath (Join-Path (Get-PmPath Status) "$($Server.id).json") -Encoding UTF8
    if (-not $ok) { throw $detail }
    return $status
}

function Invoke-PmTestFlow {
    <#
        Mode 'rdp'   : RDP port reachable (+ full system info when the agent is connected and idle)
        Mode 'winrm' : WinRM port reachable + login + full system info over PowerShell remoting
        Mode 'auto'  : both.
        Each method's result is stored separately (with its own time), so testing one never
        erases the other. A server PASSES when at least one method is OK.
    #>
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, $Job, [ValidateSet('auto', 'rdp', 'winrm')][string]$Mode = 'auto')
    if ((Get-PmTransport $Server) -eq 'local') { return Invoke-PmLocalTestFlow -Server $Server -Job $Job }
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
        Add-PmJobLog -Job $Job -Level OK -Message ("{0}: {1} | admin={2} | PRTG={3} {4} ({5} GB data, core {6}) | RDP port on server={7}" -f $r.Computer, $r.OS, $r.IsAdmin,
                $(if ($r.Prtg.Installed) { 'yes' } else { 'no' }), $r.Prtg.Version, $r.PrtgDataGB, $r.Prtg.CoreStatus, $r.RdpPort) -Computer $r.Computer
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

function Get-PmBackupEstimate {
    <#
        PURE. Bytes a full backup copies, from the source facts (Initialize-PmRemoteWorkRoot) and the backup
        options with the defaults of Invoke-PmRemoteBackup: history yes, logs no, automatic config copies no,
        program clone yes, desktops yes. Older facts without the parts fall back to the whole data folder.
    #>
    param([Parameter(Mandatory)]$Facts, [hashtable]$Options = @{})
    $opt = { param($k, $d) if ($Options.ContainsKey($k)) { [bool]$Options[$k] } else { $d } }
    $total = [int64]$Facts.PrtgDataBytes
    if (-not $Facts.PSObject.Properties['PrtgHistoryBytes']) { return $total }
    if ([string]$Options.Scope -eq 'graphs') { return [int64]$Facts.PrtgHistoryBytes }
    $b = $total
    if (-not (& $opt 'IncludeHistory' $true)) { $b -= [int64]$Facts.PrtgHistoryBytes }
    if (-not (& $opt 'IncludeLogs' $false)) { $b -= [int64]$Facts.PrtgLogsBytes }
    if (-not (& $opt 'IncludeAutoBackups' $false)) { $b -= [int64]$Facts.PrtgAutoBackupBytes }
    if (& $opt 'IncludeProgram' $true) { $b += [int64]$Facts.PrtgProgramBytes }
    if (& $opt 'IncludeDesktop' $true) { $b += [int64]$Facts.DesktopBytes }
    if ($b -lt 0) { return [int64]0 }
    return [int64]$b
}

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
        $method = Get-PmTransport $srv
        $ports = if ($method -eq 'local') { [pscustomobject]@{ rdpPort = 0; rdp = $false; winrmPort = 0; winrm = $false } } else { Test-PmServerPorts -Server $srv }
        Add-PmJobLog -Job $Job -Level DEBUG -Message "$($srv.name) ($($srv.host)): method=$method RDP $($ports.rdpPort)=$($ports.rdp) WinRM $($ports.winrmPort)=$($ports.winrm)"
        if ($method -eq 'winrm' -and -not $ports.winrm) { $problems += "$($srv.name): $(Get-PmConnectHint -Ports $ports)"; continue }
        $s = $null
        try {
            $s = New-PmSession -Server $srv -Credential (Resolve-PmCredential $srv $Credentials) -Job $Job
            $i = Invoke-PmRemote -Session $s -Function 'Initialize-PmRemoteWorkRoot' -Job $Job
            $info[$srv.id] = $i
            if (-not $i.IsAdmin -and $env:PRTGMOVER_TEST -ne '1') {
                $problems += if ($method -eq 'local') { "$($srv.name): PRTG Manager is not running as administrator. Close it and start it with 'Run as administrator'." } else { "$($srv.name): remote session is not elevated (administrator required)." }
            }
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
            # what this backup really copies (history, logs, program clone and desktops as selected), not the whole data folder
            $data = Get-PmBackupEstimate -Facts $src -Options $Options
            if ($src.PSObject.Properties['PrtgHistoryBytes']) {
                Add-PmJobLog -Job $Job -Level DEBUG -Message ("{0}: data folder {1:N2} GB (history {2:N2} GB, logs {3:N2} GB, automatic copies {4:N2} GB), program {5:N2} GB, desktops {6:N2} GB -> this backup copies ~{7:N2} GB." -f $Source.name,
                        ($src.PrtgDataBytes / 1GB), ($src.PrtgHistoryBytes / 1GB), ($src.PrtgLogsBytes / 1GB), ($src.PrtgAutoBackupBytes / 1GB), ($src.PrtgProgramBytes / 1GB), ($src.DesktopBytes / 1GB), ($data / 1GB))
            }
            $srcVersion = $src.Prtg.Version
            $viaTunnel = [string]$Options.Transfer -in 'wireguard', 'ipip'
            if ($viaTunnel) {
                Add-PmJobLog -Job $Job -Level OK -Message ("{0}: tunnel mode - WinRM goes from the source to the target's tunnel address. This computer is not in the data path (PRTG data {1:N1} GB)." -f $Source.name, ($data / 1GB))
            } elseif ((Get-PmTransport $Source) -eq 'local') {
                Add-PmJobLog -Job $Job -Level OK -Message ("{0}: local mode - the files are read from a snapshot on this computer, nothing goes over the network (PRTG data {1:N1} GB)." -f $Source.name, ($data / 1GB))
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
                $hint = if ($Source -and $info[$Source.id] -and $info[$Source.id].PSObject.Properties['PrtgHistoryBytes'] -and [int64]$info[$Source.id].PrtgHistoryBytes -gt 1GB -and -not ($Options.ContainsKey('IncludeHistory') -and -not $Options.IncludeHistory)) {
                    (' The history alone is {0:N1} GB - a backup without history (and a separate History backup of the last days) needs much less.' -f ([int64]$info[$Source.id].PrtgHistoryBytes / 1GB))
                } else { '' }
                $problems += ("Manager: needs ~{0:N1} GB free on {1} for staging + package, has {2:N1} GB.{3}" -f ($data * 2.2 / 1GB), $mgrDrive.DeviceID, ($mgrDrive.FreeSpace / 1GB), $hint)
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
    <#
        Builds backups\PRTG-FULL_<computer>_<ts>.zip (PRTG-GRAPHS_ for history only, FILES_ without PRTG) and its
        .meta.json from a complete staging folder on the manager; with a password it is encrypted into .pmenc.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param([Parameter(Mandatory)][string]$StageDir, $Job, [string]$SourceName, [string]$Password)
    $mf = Join-Path $StageDir 'manifest.json'
    $manifest = Get-Content -LiteralPath $mf -Raw -Encoding UTF8 | ConvertFrom-Json
    # metadata the server does not know: this manager's version and the server's name in the inventory
    foreach ($kv in @(@('appVersion', (Get-PmAppVersion)), @('sourceServer', $SourceName))) { $manifest | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force }
    if (-not $manifest.PSObject.Properties['type']) { $manifest | Add-Member -NotePropertyName type -NotePropertyValue (Get-PmBackupType -Manifest $manifest) -Force }
    if (-not $manifest.PSObject.Properties['encryption']) { $manifest | Add-Member -NotePropertyName encryption -NotePropertyValue ([pscustomobject]@{ package = [bool]$Password; secrets = $false }) -Force }
    [IO.File]::WriteAllText($mf, (ConvertTo-Json -InputObject $manifest -Depth 10), (New-Object Text.UTF8Encoding($false)))
    $prefix = switch (Get-PmBackupType -Manifest $manifest) { 'graphs' { 'PRTG-GRAPHS' } 'files' { 'FILES' } 'vpn' { 'VPN' } default { 'PRTG-FULL' } }
    $zipName = '{0}_{1}_{2}.zip' -f $prefix, $manifest.source.computer, (Get-Date -Format 'yyyyMMdd-HHmmss')
    $local = Join-Path (Get-PmPath Backups) $zipName
    Add-PmJobLog -Job $Job -Level STEP -Message ("Compressing the staged copy ({0:N2} GB) into {1} on the manager..." -f ($manifest.stagingBytes / 1GB), $zipName)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($StageDir, $local, [IO.Compression.CompressionLevel]::Optimal, $false)
    Add-PmJobLog -Job $Job -Level DEBUG -Message ("Zip written in {0:N0} s" -f $sw.Elapsed.TotalSeconds)
    if (-not $SourceName) { $SourceName = $manifest.source.computer }
    return (Complete-PmPackage -ZipPath $local -Manifest $manifest -Source $SourceName -Password $Password -Job $Job)
}

function Use-PmCompletedStage {
    <#
        Resume helper: if an earlier run of this job chain already finished copying from the
        source (staging with manifest.json), adopt it - the source is not contacted again.
        Returns @{ Zip; StageDir } or $null.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param($Job, [string]$SourceName, [string]$Password)
    $rs = Find-PmResumeStage -Job $Job
    if (-not $rs -or -not $rs.Complete) { return $null }
    $dest = Join-Path (Get-PmPath Data) "staging\$($Job.id)"
    Move-Item -LiteralPath $rs.Path -Destination $dest
    Add-PmJobLog -Job $Job -Level OK -Message "RESUME: the copy made by job $($rs.JobId) is complete - adopting it, the source is not contacted again."
    $zip = New-PmPackageFromStage -StageDir $dest -Job $Job -SourceName $SourceName -Password $Password
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
                [void]$ps.AddScript($script:PmTransferWorker.ToString()).AddArgument((Join-Path $PSScriptRoot 'PrtgManager.psm1')).AddArgument((Get-PmPath Root)).AddArgument($Server).AddArgument($Credential).AddArgument($Job).AddArgument($Direction).AddArgument($RemoteRoot).AddArgument($LocalRoot).AddArgument($queue).AddArgument($state).AddArgument($i).AddArgument($batches.Count)
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
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Backup password from the dashboard; never stored.')]
    param(
        [Parameter(Mandatory)]$Server, [pscredential]$Credential, [hashtable]$Options = @{}, $Job,
        [int]$ProgressBase = 0, [double]$ProgressSpan = 100, [string]$Password
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
                Invoke-PmTransferFiles -Session $s -Direction Pull -RemoteRoot $r.StageDir -LocalRoot $stageLocal -Files @($small.Files) -Job $Job -Label 'registry/desktop/manifest'
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
        $local = New-PmPackageFromStage -StageDir $stageLocal -Job $Job -SourceName $Server.name -Password $Password
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
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    # enough room for the unpacked package? (a disk that runs full half-way leaves a broken copy behind)
    $need = [int64]0; $zr = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { foreach ($e in $zr.Entries) { $need += $e.Length } } finally { $zr.Dispose() }
    $drive = Get-PmLogicalDisk -Path (Get-PmPath Data)
    if ($drive -and $drive.FreeSpace -lt ($need + 1GB)) {
        throw ("Not enough free space on {0} to unpack {1}: {2:N1} GB free, {3:N1} GB needed (package {4:N1} GB + 1 GB)." -f $drive.DeviceID, (Split-Path $ZipPath -Leaf), ($drive.FreeSpace / 1GB), (($need + 1GB) / 1GB), ($need / 1GB))
    }
    Add-PmJobLog -Job $Job -Level STEP -Message ("Extracting {0} ({1:N2} GB) on the manager..." -f (Split-Path $ZipPath -Leaf), ($need / 1GB))
    try { [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $dir) }
    catch { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue; throw }
    Set-PmStageComplete -StageDir $dir
    return $dir
}

function Remove-PmExtractedStage {
    <# Removes the unpacked copy of a package (data\staging\restore-<name>) after the restore that used it. #>
    param([Parameter(Mandatory)][string]$ZipPath)
    $dir = Join-Path (Get-PmPath Data) ("staging\restore-" + [IO.Path]::GetFileNameWithoutExtension($ZipPath))
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
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
        # only a copy unpacked for this restore is used up; a staging copy handed in (migration) may serve more targets
        $isLocal = [bool]$s.PSObject.Properties['PmLocal'] -and ($stageLocal -ne $StageDir)
        if ($isLocal) {
            # PRTG is on this computer: the restore reads the unpacked package where it is and MOVES the data into
            # place - no second copy on the same disk. The unpacked copy is used up and removed afterwards.
            $params.StageDir = $stageLocal
            $params.MoveFromStage = $true
            $params.CleanupStage = $false
            Add-PmJobLog -Job $Job -Level OK -Message "Local restore: the unpacked package in $stageLocal is moved into place (no second copy on this disk)."
        } elseif ($agent) {
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

        try {
            $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmRemoteRestore' -Parameters $params -Job $Job `
                -ProgressBase ($ProgressBase + [int]($ProgressSpan * 0.62)) -ProgressSpan ($ProgressSpan * 0.38)
        } finally {
            # a local restore moved the data out of the unpacked copy: it is incomplete now and must never be reused
            if ($isLocal -and $stageLocal -and (Test-Path -LiteralPath $stageLocal)) {
                Remove-Item -LiteralPath $stageLocal -Recurse -Force -ErrorAction SilentlyContinue
                Add-PmJobLog -Job $Job -Level DEBUG -Message "Unpacked copy removed: $stageLocal"
            }
        }
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
    Assert-PmNotSource -Server $Server -What 'change the web binding of'
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
    # passwords / license keys typed in the dashboard: used by this run only, never written to the job record or the log
    $secrets = if ($Params.Secrets) { $Params.Secrets } else { @{} }
    $pw = [string]$secrets.Password
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
                if ([string]$options.Scope -eq 'graphs') {
                    # history only: never stops PRTG, no program / registry / license / desktop
                    $options.NoTouch = $true; $options.IncludePrtg = $true; $options.IncludeDesktop = $false; $options.ExtraPaths = [string[]]@()
                    Add-PmJobLog -Job $Job -Level STEP -Message ("History backup (graph data) of {0}: {1}. PRTG keeps running." -f $srv.name, $(if ([int]$options.HistoryDays -gt 0) { "the last $([int]$options.HistoryDays) day(s)" } else { 'all days' }))
                }
                if ($pw) { Assert-PmBackupPassword $pw }
                [void](Invoke-PmPreflight -Source $srv -Credentials $creds -Options $options -Job $Job)
                $b = Use-PmCompletedStage -Job $Job -SourceName $srv.name -Password $pw
                if (-not $b) { $b = Invoke-PmBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Options $options -Job $Job -Password $pw }
                Set-PmCheckpoint -Job $Job -Backup (Split-Path $b.Zip -Leaf)
                if ($b.StageDir) { Remove-Item -LiteralPath $b.StageDir -Recurse -Force -ErrorAction SilentlyContinue }
                $Job.result = [pscustomobject]@{ backup = (Split-Path $b.Zip -Leaf) }
            }
            'section-backup' {
                # one part of PRTG: devices / notifications / triggers / license (nothing is written on the server)
                $srv = Get-PmServer -Id $Params.SourceId
                $r = Invoke-PmSectionBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Type ([string]$Params.SectionType) -Password $pw -Job $Job
                $Job.result = $r
            }
            'restore' {
                $file = Get-PmBackupFile -Name $Params.BackupName
                $meta = Read-PmBackupMeta -Path $file
                $ptype = Get-PmBackupType -Manifest $(if ($meta) { $meta.manifest } else { Read-PmBackupManifest -ZipPath $file }) -Name $Params.BackupName
                $targets = @($Params.TargetIds | Where-Object { -not ($resume -and @($resume.targetsDone) -contains $_) })
                if ($resume) { Add-PmJobLog -Job $Job -Level STEP -Message "Resuming: $(@($resume.targetsDone).Count) target(s) already done, $($targets.Count) remaining." }
                if ($ptype -in 'devices', 'notifications', 'triggers', 'license') {
                    $results = @(); $failed = 0
                    foreach ($id in $targets) {
                        $srv = Get-PmServer -Id $id
                        try {
                            $r = Invoke-PmSectionRestoreFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Path $file -Options $options -Password $pw -Job $Job
                            $results += $r
                            # a license restore that leaves PRTG unhealthy reports ok = $false without throwing
                            if ($r.ok) { Set-PmCheckpoint -Job $Job -TargetDone $id }
                            else { $failed++; Add-PmJobLog -Job $Job -Level ERROR -Message "$($srv.name): the $($r.type) was restored, but PRTG did not come back healthy$(if ($r.hint) { " - $($r.hint)" })" }
                        } catch { $failed++; Add-PmJobError -Job $Job -ErrorRecord $_ -Context "$($srv.name): "; $results += [pscustomobject]@{ target = $srv.name; ok = $false; error = "$_" } }
                    }
                    $Job.result = $results
                    if ($failed) { throw "$failed of $($targets.Count) target(s) reported errors." }
                } else {
                    $plain = Get-PmPlainPackage -Path $file -Password $pw -Job $Job
                    try {
                        $Job.result = Invoke-PmMultiRestore -File $plain.Path -TargetIds $targets -Options $options -Credentials $creds -Job $Job -Base 0 -Span 100
                        # every target done: the unpacked copy is not needed for a Resume any more (it is kept after a failure)
                        Remove-PmExtractedStage -ZipPath $plain.Path
                    }
                    finally { Remove-PmPlainPackage $plain }
                }
            }
            'restore-preview' {
                $file = Get-PmBackupFile -Name $Params.BackupName
                $results = @()
                foreach ($id in @($Params.TargetIds)) {
                    $srv = Get-PmServer -Id $id
                    $results += Invoke-PmRestorePreviewFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Path $file -Options $options -Password $pw -Job $Job
                }
                $Job.result = $results
            }
            'license' {
                $results = @()
                foreach ($id in @($Params.ServerIds)) {
                    $srv = Get-PmServer -Id $id
                    $results += Invoke-PmLicenseFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Action ([string]$Params.Action) -Options $options -Secrets $secrets -Job $Job
                    if ([string]$Params.Action -ne 'status') {
                        try { [void](Invoke-PmTestFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Job $Job -Mode $(if ((Get-PmTransport $srv) -eq 'winrm') { 'winrm' } else { 'auto' })) } catch { Add-PmJobLog -Job $Job -Level WARN -Message "Status refresh failed: $($_.Exception.Message)" }
                    }
                }
                $Job.result = $results
            }
            'validate' {
                $r = Test-PmBackupPackage -Name ([string]$Params.BackupName) -Password $pw -Job $Job
                $Job.result = $r
                if (-not $r.valid) { throw "The package is not valid: $(@($r.errors) -join '; ')" }
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
                        if ($pw) {
                            # the migration restores from the plain staging copy; the package kept on the manager is encrypted
                            $enc = Complete-PmPackage -ZipPath $b.Zip -Manifest ((Read-PmBackupMeta -Path $b.Zip).manifest) -Source $srv.name -Password $pw -Job $Job
                            $b = [pscustomobject]@{ Zip = $enc; StageDir = $b.StageDir }
                        }
                        $file = $b.Zip; $stage = $b.StageDir
                        Set-PmCheckpoint -Job $Job -Backup (Split-Path $file -Leaf) -StageDir $stage
                    }
                }
                if ([string]$options.Transfer -notin 'wireguard', 'ipip') {
                    if ($file -like '*.pmenc' -and -not $stage) { throw 'The package of this migration is encrypted and its staging copy is gone - restore it from the Backups page with its password.' }
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
            Assert-PmNotSource -Server $srv -What 'restore into'
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

function Get-PmJobLockIds {
    <#
        PURE. Servers whose PRTG a job may stop or change: two such jobs must never run on the same server at once
        (both would stop/start PRTG and write its configuration and registry). A backup can stop the source.
    #>
    param([Parameter(Mandatory)][string]$Type, [hashtable]$Params = @{})
    $ids = switch ($Type) {
        'restore' { @($Params.TargetIds) }
        'migrate' { @($Params.SourceId) + @($Params.TargetIds) }
        'backup' { @($Params.SourceId) }
        'license' { if ([string]$Params.Action -ne 'status') { @($Params.ServerIds) } }
        'unlicense' { @($Params.ServerIds) }
        'rebind' { @($Params.ServerIds) }
        default { @() }
    }
    return @(@($ids) | Where-Object { $_ } | ForEach-Object { [string]$_ } | Select-Object -Unique)
}

function Start-PmJob {
    <# Queues a job on the background runspace pool (used by the dashboard). #>
    param([Parameter(Mandatory)][string]$Type, [hashtable]$Params = @{}, [string]$Summary)
    # one restore / preview per package at a time: both would decrypt into and clean up the same staging copy
    if ($Type -in 'restore', 'restore-preview' -and $Params.BackupName) {
        $busy = Get-PmPackageUser -Name ([string]$Params.BackupName)
        if ($busy) { throw "The package $($Params.BackupName) is used by job $busy right now - wait until it has finished." }
    }
    # one job that stops / changes PRTG per server at a time
    $lock = @(Get-PmJobLockIds -Type $Type -Params $Params)
    if ($lock.Count) {
        foreach ($other in @($script:PmJobs.Values)) {
            if (-not $other.lockIds) { continue }
            # a cancelled restore keeps the lock while its runspace still puts the previous state back
            $h = $script:PmJobHandles[$other.id]
            $alive = $other.status -in 'queued', 'running' -or ($h -and $h.Async -and -not $h.Async.IsCompleted)
            if (-not $alive) { continue }
            $both = @($lock | Where-Object { @($other.lockIds) -contains $_ })
            if ($both.Count) {
                $n = @($both | ForEach-Object { $id = $_; $s = Get-PmServers | Where-Object { $_.id -eq $id } | Select-Object -First 1; if ($s) { $s.name } else { $id } }) -join ', '
                throw "Job $($other.id) ($($other.summary)) is changing PRTG on $n right now - wait until it has finished."
            }
        }
    }
    if (-not $script:PmPool) {
        $script:PmPool = [runspacefactory]::CreateRunspacePool(1, 4)
        $script:PmPool.Open()
    }
    $job = New-PmJobObject -Type $Type -Summary $Summary
    $job.lockIds = $lock
    # Keep the parameters (without one-time credentials) so the job can be resumed/retried later.
    $saved = @{}
    foreach ($k in $Params.Keys) { if ($k -notin 'Credentials', 'Resume', 'Secrets') { $saved[$k] = $Params[$k] } }
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
        }).AddArgument((Join-Path $PSScriptRoot 'PrtgManager.psm1')).AddArgument($script:PmRoot).AddArgument($job).AddArgument($Type).AddArgument($Params)
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
        if ($job.type -in 'restore', 'migrate') {
            Add-PmJobLog -Job $job -Level WARN -Message 'A restore that had already stopped PRTG puts the previous state back on its own (log: <PRTG Manager work folder>\rollback\cancelled-restore-*.log on the target). The server stays locked for other PRTG jobs until that has finished.'
        }
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

function Clear-PmFinishedJobs {
    <#
        Frees the memory of jobs that finished more than $Minutes ago: their PowerShell instance is disposed and they are
        dropped from memory (the job record on disk stays, Get-PmJob reads it from there).
    #>
    param([int]$Minutes = 60)
    $limit = (Get-Date).AddMinutes(-$Minutes)
    foreach ($id in @($script:PmJobHandles.Keys)) {
        $h = $script:PmJobHandles[$id]; $j = $script:PmJobs[$id]
        if (-not $h -or -not $h.Async -or -not $h.Async.IsCompleted) { continue }
        if ($j -and ($j.status -in 'queued', 'running' -or -not $j.finished -or [datetime]$j.finished -gt $limit)) { continue }
        try { $h.PowerShell.Dispose() } catch { }
        $script:PmJobHandles.Remove($id); $script:PmJobs.Remove($id)
    }
}

function Get-PmJobs {
    <# In-memory jobs plus finished jobs persisted on disk (newest first, without logs). #>
    Clear-PmFinishedJobs
    $list = @{}
    if (-not $script:PmJobListCache) { $script:PmJobListCache = @{} }
    foreach ($f in (Get-ChildItem -LiteralPath (Get-PmPath Jobs) -Filter '*.json' -File -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 100)) {
        # a record is parsed again only when it changed (the dashboard asks for this list every few seconds)
        $c = $script:PmJobListCache[$f.FullName]
        if ($c -and $c.Time -eq $f.LastWriteTimeUtc.Ticks -and $c.Size -eq $f.Length) { $list[$c.Job.id] = $c.Job; continue }
        try {
            $j = Get-Content -LiteralPath $f.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            $s = [pscustomobject]@{ id = $j.id; type = $j.type; summary = $j.summary; status = $j.status; progress = $j.progress; step = $j.step; created = $j.created; finished = $j.finished; error = $j.error }
            $script:PmJobListCache[$f.FullName] = @{ Time = $f.LastWriteTimeUtc.Ticks; Size = $f.Length; Job = $s }
            $list[$j.id] = $s
        } catch { }
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
        resumable = [bool]($j.params -and $j.status -in 'failed', 'cancelled', 'interrupted' -and $j.type -in 'backup', 'restore', 'migrate', 'section-backup', 'validate')
        logCount = $logs.Count; logs = @($logs | Select-Object -Skip $Since)
    }
}

function Get-PmInstallers {
    Get-ChildItem -LiteralPath (Get-PmPath Installers) -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.zip' } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; size = $_.Length; created = $_.LastWriteTime.ToString('o') } }
}

# Pure tunnel helpers live in the remote script and are also used on the manager to plan addresses.
. (Join-Path $PSScriptRoot 'Remote\PrtgManager.Remote.ps1')

Export-ModuleMember -Function *-Pm*
