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

$script:PmBackupKeys = 'IncludePrtg', 'IncludeHistory', 'IncludeVpn', 'IncludeDesktop', 'ExtraPaths', 'SourceAfter', 'NoTouch', 'HealthTimeoutMinutes'
$script:PmRestoreKeys = 'RestorePrtg', 'RestoreVpn', 'RestoreDesktop', 'RestoreExtra', 'InstallerArgs', 'AllowDowngrade', 'StartServices', 'HealthTimeoutMinutes', 'ConnectVpn', 'CopyLicense', 'OpenFirewall'

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
        'Web'         { Join-Path $script:PmRoot 'web' }
        'Remote'      { Join-Path $script:PmRoot 'src\Remote\PrtgMover.Remote.ps1' }
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
        [ValidateSet('rdp', 'winrm')][string]$Transport = 'rdp'
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
        token-protected localhost API; it is turned into a SecureString immediately and
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
    <# 'rdp' (agent inside an RDP session, default) or 'winrm' (PowerShell remoting). #>
    param([Parameter(Mandatory)]$Server)
    if ($Server.PSObject.Properties['transport'] -and $Server.transport -eq 'winrm') { return 'winrm' }
    return 'rdp'
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
    $f = Join-Path (Get-PmPath Data) "agent\$ServerId\heartbeat.json"
    if (-not (Test-Path -LiteralPath $f)) { return [pscustomobject]@{ connected = $false } }
    try {
        $hb = [IO.File]::ReadAllText($f) | ConvertFrom-Json
        $age = ((Get-Date).ToUniversalTime() - [datetime]::Parse($hb.time).ToUniversalTime()).TotalSeconds
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
            Add-PmJobLog -Job $Job -Level OK -Message "Agent connected on $($Server.name) ($($st.computer), $($st.user))."
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
    New-PSSession @p
}

function Close-PmSession {
    param($Session)
    if (-not $Session) { return }
    if ($Session.PSObject.Properties['PmAgent']) { return }   # the agent keeps running for the next call
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

function Invoke-PmAgentCall {
    <# File-based RPC with the agent: write a request, tail the JSON-lines response. #>
    param($Session, [string]$Function, [hashtable]$Parameters, $Job, [int]$ProgressBase, [double]$ProgressSpan)
    $id = [guid]::NewGuid().ToString('N')
    $req = Join-Path $Session.Dir "requests\$id.json"
    $resp = Join-Path $Session.Dir "responses\$id.jsonl"
    ConvertTo-Json -InputObject ([ordered]@{ id = $id; fn = $Function; params = $Parameters }) -Depth 8 | Set-Content -LiteralPath "$req.tmp" -Encoding UTF8
    Move-Item -LiteralPath "$req.tmp" -Destination $req -Force

    $box = @{ Result = $null; Error = $null; Done = $false }
    $pos = 0L; $pending = ''
    $lastBeat = Get-Date
    while (-not $box.Done) {
        $fs = $null
        if (Test-Path -LiteralPath $resp) {
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
                if ($line) { Receive-PmRecord -Record ($line | ConvertFrom-Json) -Job $Job -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan -Box $box }
            }
        }
        if ($box.Done) { break }
        $st = Get-PmAgentStatus -ServerId $Session.Server.id
        if ($st.connected) { $lastBeat = Get-Date }
        elseif (((Get-Date) - $lastBeat).TotalSeconds -gt 90) {
            throw "Lost the agent on $($Session.Server.name) (no heartbeat for 90 s) - was the RDP session or the agent window closed?"
        }
        Start-Sleep -Milliseconds 500
    }
    Remove-Item -LiteralPath $resp -Force -ErrorAction SilentlyContinue
    if ($box.Error) { throw $box.Error }
    return $box.Result
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
    Invoke-Command -Session $Session -ScriptBlock $sb -ArgumentList $Function, $Parameters -ErrorAction Stop | ForEach-Object {
        Receive-PmRecord -Record $_ -Job $Job -ProgressBase $ProgressBase -ProgressSpan $ProgressSpan -Box $box
    }
    return $box.Result
}

function Get-PmManagerRelative {
    param([Parameter(Mandatory)][string]$LocalPath)
    $root = (Get-PmPath Root).TrimEnd('\') + '\'
    $full = [IO.Path]::GetFullPath($LocalPath)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { throw "$LocalPath is outside the PRTG Mover folder." }
    return $full.Substring($root.Length)
}

function Copy-PmFromServer {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$RemotePath, [Parameter(Mandatory)][string]$LocalPath, $Job)
    if ($Session.PSObject.Properties['PmAgent']) {
        [void](Invoke-PmAgentCall -Session $Session -Function 'Send-PmAgentFile' -Parameters @{ Source = $RemotePath; ManagerRelative = (Get-PmManagerRelative $LocalPath) } -Job $Job)
    } else {
        Copy-Item -FromSession $Session -Path $RemotePath -Destination $LocalPath -Force -ErrorAction Stop
    }
}

function Copy-PmToServer {
    param([Parameter(Mandatory)]$Session, [Parameter(Mandatory)][string]$LocalPath, [Parameter(Mandatory)][string]$RemotePath, $Job)
    if ($Session.PSObject.Properties['PmAgent']) {
        [void](Invoke-PmAgentCall -Session $Session -Function 'Receive-PmAgentFile' -Parameters @{ ManagerRelative = (Get-PmManagerRelative $LocalPath); Destination = $RemotePath } -Job $Job)
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
        return "WinRM port $($Ports.winrmPort) is not reachable. Enable remoting on the server (tools\Enable-PrtgMoverRemoting.ps1, over RDP) and open the firewall for the manager."
    }
    if ($Message -match 'TrustedHosts') { return 'Add the server to TrustedHosts on the manager: tools\Setup-Manager.ps1 -TrustedHosts <ip> (elevated).' }
    if ($Message -match 'Access is denied|access denied') { return 'Credential rejected or not an administrator. Use HOST\Administrator (or .\Administrator) and check LocalAccountTokenFilterPolicy.' }
    if ($Message -match 'WinRM.*service|cannot process the request') { return 'Start the WinRM service on the manager (tools\Setup-Manager.ps1, elevated).' }
    return $null
}

function Invoke-PmTestFlow {
    <#
        Mode 'rdp'   : RDP port reachable (+ full system info when the agent is connected)
        Mode 'winrm' : WinRM port reachable + full system info over PowerShell remoting
        Mode 'auto'  : both; the server PASSES when at least one method works.
    #>
    param([Parameter(Mandatory)]$Server, [pscredential]$Credential, $Job, [ValidateSet('auto', 'rdp', 'winrm')][string]$Mode = 'auto')
    Add-PmJobLog -Job $Job -Level STEP -Message "Testing $($Server.name) ($($Server.host)) - mode: $Mode, connection method: $((Get-PmTransport $Server).ToUpper())"
    $ports = Test-PmServerPorts -Server $Server
    $res = [ordered]@{ rdp = $null; winrm = $null; agent = $null }
    $info = $null; $errors = @()

    if ($Mode -in 'auto', 'rdp') {
        $res.rdp = [bool]$ports.rdp
        Add-PmJobLog -Job $Job -Level $(if ($ports.rdp) { 'OK' } else { 'ERROR' }) -Message "RDP   TCP $($ports.rdpPort): $(if ($ports.rdp) { 'reachable - PASS' } else { 'NOT reachable' })"
        if (-not $ports.rdp) { $errors += "RDP port $($ports.rdpPort) not reachable (wrong port, firewall, or RDP disabled)." }
        $agent = Get-PmAgentStatus -ServerId $Server.id
        $res.agent = [bool]$agent.connected
        if ($agent.connected) {
            try {
                $s = New-PmSession -Server ([pscustomobject]@{ id = $Server.id; name = $Server.name; transport = 'rdp' }) -Job $Job
                $info = Invoke-PmRemote -Session $s -Function 'Get-PmSystemInfo' -Job $Job
            } catch { $errors += "Agent: $_" }
        } elseif ($ports.rdp) {
            Add-PmJobLog -Job $Job -Message "Agent not running (only needed while a job runs). To start it: RDP button -> elevated PowerShell -> $(Get-PmAgentCommand $Server)"
        }
    }
    if ($Mode -in 'auto', 'winrm') {
        $res.winrm = $false
        Add-PmJobLog -Job $Job -Level $(if ($ports.winrm) { 'OK' } elseif ($Mode -eq 'winrm') { 'ERROR' } else { 'WARN' }) -Message "WinRM TCP $($ports.winrmPort): $(if ($ports.winrm) { 'reachable' } else { 'NOT reachable' })"
        if ($ports.winrm) {
            $s = $null
            try {
                $s = New-PmSession -Server ([pscustomobject]@{ id = $Server.id; name = $Server.name; host = $Server.host; port = $Server.port; useSsl = $Server.useSsl; skipCaCheck = $Server.skipCaCheck; authentication = $Server.authentication; transport = 'winrm' }) -Credential $Credential -Job $Job
                $info = Invoke-PmRemote -Session $s -Function 'Get-PmSystemInfo' -Job $Job
                $res.winrm = $true
                Add-PmJobLog -Job $Job -Level OK -Message 'WinRM login and remote execution - PASS'
            } catch {
                $msg = "$_"; $errors += "WinRM: $msg"
                Add-PmJobLog -Job $Job -Level $(if ($Mode -eq 'winrm') { 'ERROR' } else { 'WARN' }) -Message "WinRM: $msg"
                $hint = Get-PmConnectHint -Message $msg
                if ($hint) { Add-PmJobLog -Job $Job -Level WARN -Message "Hint: $hint" }
            } finally { if ($s) { Close-PmSession $s } }
        } elseif ($Mode -eq 'winrm') { $errors += (Get-PmConnectHint -Ports $ports) }
    }

    if ($info) {
        $r = $info
        Add-PmJobLog -Job $Job -Level OK -Message ("{0}: {1} | admin={2} | PRTG={3} {4} ({5} GB data, core {6}) | VPN={7} | RDP port on server={8}" -f $r.Computer, $r.OS, $r.IsAdmin,
                $(if ($r.Prtg.Installed) { 'yes' } else { 'no' }), $r.Prtg.Version, $r.PrtgDataGB, $r.Prtg.CoreStatus, @($r.VpnAllUsers).Count, $r.RdpPort) -Computer $r.Computer
        foreach ($d in @($r.Disks)) { Add-PmJobLog -Job $Job -Message ("Disk {0} {1} GB free of {2} GB" -f $d.Drive, $d.FreeGB, $d.SizeGB) -Computer $r.Computer }
        if ($r.Prtg.Installed -and $r.PrtgConfigStats) { Add-PmJobLog -Job $Job -Message "PRTG configuration: $($r.PrtgConfigStats)" -Computer $r.Computer }
        if (-not $r.IsAdmin) { Add-PmJobLog -Job $Job -Level WARN -Message 'Session is NOT elevated - an administrator is required.' }
        if ($r.RdpPort -and [int]$r.RdpPort -ne (Get-PmRdpPort $Server)) { Add-PmJobLog -Job $Job -Level WARN -Message "The server's RDP service listens on port $($r.RdpPort) but the inventory says $(Get-PmRdpPort $Server) - edit the server." }
    }

    # PASS when at least one tested method works.
    $ok = ($res.rdp -eq $true) -or ($res.winrm -eq $true)
    $prev = $null
    $sf = Join-Path (Get-PmPath Status) "$($Server.id).json"
    if (-not $info -and (Test-Path -LiteralPath $sf)) { try { $prev = (Get-Content -LiteralPath $sf -Raw -Encoding UTF8 | ConvertFrom-Json).info } catch { } }
    $status = [pscustomobject]@{
        ok = $ok; checked = (Get-Date).ToString('o'); mode = $Mode; methods = [pscustomobject]$res
        info = $(if ($info) { $info } else { $prev }); error = $(if ($ok) { $null } else { $errors -join ' | ' }); ports = $ports
    }
    $status | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sf -Encoding UTF8
    Add-PmJobLog -Job $Job -Level $(if ($ok) { 'OK' } else { 'ERROR' }) -Message ("{0}: {1}  (RDP={2}, WinRM={3})" -f $Server.name, $(if ($ok) { 'PASS' } else { 'FAIL' }),
            $(if ($null -eq $res.rdp) { 'not tested' } elseif ($res.rdp) { 'ok' } else { 'fail' }), $(if ($null -eq $res.winrm) { 'not tested' } elseif ($res.winrm) { 'ok' } else { 'fail' }))
    if (-not $ok) { throw ($errors -join ' | ') }
    return $status
}
function Invoke-PmPreflight {
    <#
        Runs BEFORE anything is changed on the source: every server must be reachable with
        admin rights, have enough disk space, and the target PRTG version must not be older
        than the source. Throws with the list of problems.
    #>
    param([Parameter(Mandatory)]$Source, [object[]]$Targets = @(), [hashtable]$Credentials, [hashtable]$Options = @{}, $Job)
    Add-PmJobLog -Job $Job -Level STEP -Message 'Pre-flight checks (nothing is changed yet)...'
    $problems = @()
    $info = @{}
    foreach ($srv in @($Source) + @($Targets)) {
        $ports = Test-PmServerPorts -Server $srv
        if ((Get-PmTransport $srv) -eq 'winrm' -and -not $ports.winrm) { $problems += "$($srv.name): $(Get-PmConnectHint -Ports $ports)"; continue }
        $s = $null
        try {
            $s = New-PmSession -Server $srv -Credential (Resolve-PmCredential $srv $Credentials) -Job $Job
            $i = Invoke-PmRemote -Session $s -Function 'Initialize-PmRemoteWorkRoot' -Job $Job
            $info[$srv.id] = $i
            if (-not $i.IsAdmin) { $problems += "$($srv.name): remote session is not elevated (administrator required)." }
            Add-PmJobLog -Job $Job -Level OK -Computer $i.Computer -Message ("{0}: reachable, admin={1}, PRTG={2}, {3:N1} GB free" -f $srv.name, $i.IsAdmin,
                    $(if ($i.Prtg.Installed) { "$($i.Prtg.Version) ($($i.Prtg.CoreStatus))" } else { 'not installed' }), ($i.FreeBytes / 1GB))
        } catch {
            $problems += "$($srv.name): $_"
        } finally { if ($s) { Close-PmSession $s } }
    }
    $src = $info[$Source.id]
    if ($src) {
        $includePrtg = -not ($Options.ContainsKey('IncludePrtg') -and -not $Options.IncludePrtg)
        if ($includePrtg -and -not $src.Prtg.Installed) { $problems += "$($Source.name): PRTG is not installed on the source." }
        $data = [int64]$src.PrtgDataBytes
        if ($data -gt 0 -and $src.FreeBytes -lt ($data * 2)) { $problems += ("{0}: needs ~{1:N1} GB free for staging + package, has {2:N1} GB." -f $Source.name, ($data * 2 / 1GB), ($src.FreeBytes / 1GB)) }
        foreach ($t in $Targets) {
            $ti = $info[$t.id]; if (-not $ti) { continue }
            if ($data -gt 0 -and $ti.FreeBytes -lt ($data * 2.5)) { $problems += ("{0}: needs ~{1:N1} GB free, has {2:N1} GB." -f $t.name, ($data * 2.5 / 1GB), ($ti.FreeBytes / 1GB)) }
            if ($ti.Prtg.Installed -and $src.Prtg.Version) {
                $sv = [version]($src.Prtg.Version -replace '[^\d\.]', ''); $tv = [version]($ti.Prtg.Version -replace '[^\d\.]', '')
                if ($tv -lt $sv -and -not $Options.AllowDowngrade) { $problems += "$($t.name): PRTG $tv is older than source $sv - upgrade the target first." }
            } elseif (-not $ti.Prtg.Installed -and -not $Options.InstallerFile) {
                $problems += "$($t.name): PRTG is not installed and no installer was selected."
            }
        }
    }
    if ($problems.Count) {
        foreach ($p in $problems) { Add-PmJobLog -Job $Job -Level ERROR -Message "Pre-flight: $p" }
        throw "Pre-flight failed ($($problems.Count) problem(s)) - nothing was changed on any server."
    }
    Add-PmJobLog -Job $Job -Level OK -Message 'Pre-flight passed.'
    return $info
}

function Invoke-PmBackupFlow {
    param(
        [Parameter(Mandatory)]$Server, [pscredential]$Credential, [hashtable]$Options = @{}, $Job,
        [int]$ProgressBase = 0, [double]$ProgressSpan = 100
    )
    $jobId = if ($Job -and $Job.id) { $Job.id } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to source $($Server.name) ($($Server.host))..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $params = ConvertTo-PmHashtable -InputObject $Options -Keys $script:PmBackupKeys
        $params.JobId = $jobId
        $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmRemoteBackup' -Parameters $params -Job $Job -ProgressBase $ProgressBase -ProgressSpan ($ProgressSpan * 0.8)
        if (-not $r) { throw 'Remote backup returned no result.' }

        Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]($ProgressSpan * 0.82)) -Step 'Downloading package to manager'
        Add-PmJobLog -Job $Job -Level STEP -Message ("Downloading {0} ({1:N1} MB) to the manager..." -f $r.ZipName, ($r.Size / 1MB))
        $local = Join-Path (Get-PmPath Backups) $r.ZipName
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Copy-PmFromServer -Session $s -RemotePath $r.ZipPath -LocalPath $local -Job $Job
        $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
        if ($hash -ne $r.Sha256) { throw "Checksum mismatch after download (remote $($r.Sha256), local $hash)." }
        Add-PmJobLog -Job $Job -Level OK -Message ("Backup stored on manager: {0} (SHA-256 verified, {1:N1} MB/s)" -f $local, (($r.Size / 1MB) / [math]::Max(1, $sw.Elapsed.TotalSeconds)))
        [pscustomobject]@{ source = $Server.name; sha256 = $hash; manifest = ($r.Manifest | ConvertFrom-Json) } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$local.meta.json" -Encoding UTF8
        [void](Invoke-PmRemote -Session $s -Function 'Remove-PmRemoteFile' -Parameters @{ Path = $r.ZipPath } -Job $Job)
        Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]$ProgressSpan) -Step 'Backup complete'
        if ($r.SourceHealth -and -not $r.SourceHealth.Healthy) {
            throw "Backup saved as $($r.ZipName), but PRTG on the source did NOT come back up completely ($($r.SourceHealth.Message))."
        }
        return $local
    } finally { if ($s) { Close-PmSession $s } }
}

function Invoke-PmRestoreFlow {
    param(
        [Parameter(Mandatory)]$Server, [pscredential]$Credential, [Parameter(Mandatory)][string]$BackupPath,
        [hashtable]$Options = @{}, $Job, [int]$ProgressBase = 0, [double]$ProgressSpan = 100
    )
    $jobId = if ($Job -and $Job.id) { $Job.id } else { Get-Date -Format 'yyyyMMdd-HHmmss' }
    Add-PmJobLog -Job $Job -Level STEP -Message "Connecting to target $($Server.name) ($($Server.host))..."
    $s = New-PmSession -Server $Server -Credential $Credential -Job $Job
    try {
        $init = Invoke-PmRemote -Session $s -Function 'Initialize-PmRemoteWorkRoot' -Job $Job
        $params = ConvertTo-PmHashtable -InputObject $Options -Keys $script:PmRestoreKeys
        $params.JobId = $jobId

        $size = (Get-Item -LiteralPath $BackupPath).Length
        if ($init.FreeBytes -and $init.FreeBytes -lt ($size * 3)) {
            throw ("Not enough free space on target: {0:N1} GB free, ~{1:N1} GB needed." -f ($init.FreeBytes / 1GB), ($size * 3 / 1GB))
        }

        if (-not $init.Prtg.Installed -and $Options.InstallerFile) {
            $inst = Join-Path (Get-PmPath Installers) (Split-Path $Options.InstallerFile -Leaf)
            if (-not (Test-Path -LiteralPath $inst)) { throw "Installer '$($Options.InstallerFile)' not found in installers folder." }
            Add-PmJobLog -Job $Job -Level STEP -Message "PRTG not installed on target - uploading installer $(Split-Path $inst -Leaf)..."
            $remoteInst = Join-Path $init.Inbox (Split-Path $inst -Leaf)
            Copy-PmToServer -Session $s -LocalPath $inst -RemotePath $remoteInst -Job $Job
            $params.InstallerPath = $remoteInst
        }

        # Expected checksum: sidecar metadata, otherwise computed now.
        $sha = $null
        $meta = "$BackupPath.meta.json"
        if (Test-Path -LiteralPath $meta) { try { $sha = (Get-Content -LiteralPath $meta -Raw -Encoding UTF8 | ConvertFrom-Json).sha256 } catch { } }
        if (-not $sha) { $sha = (Get-FileHash -LiteralPath $BackupPath -Algorithm SHA256).Hash }
        $params.ExpectedSha256 = $sha

        Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]($ProgressSpan * 0.05)) -Step "$($Server.name): uploading package"
        Add-PmJobLog -Job $Job -Level STEP -Message ("Uploading package to target ({0:N1} MB)..." -f ($size / 1MB))
        $remoteZip = Join-Path $init.Inbox (Split-Path $BackupPath -Leaf)
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Copy-PmToServer -Session $s -LocalPath $BackupPath -RemotePath $remoteZip -Job $Job
        Add-PmJobLog -Job $Job -Level OK -Message ("Package uploaded ({0:N1} MB/s)." -f (($size / 1MB) / [math]::Max(1, $sw.Elapsed.TotalSeconds)))
        $params.ZipPath = $remoteZip

        $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmRemoteRestore' -Parameters $params -Job $Job `
            -ProgressBase ($ProgressBase + [int]($ProgressSpan * 0.2)) -ProgressSpan ($ProgressSpan * 0.8)
        if (-not $r) { throw 'Remote restore returned no result.' }
        return $r.Report
    } finally { if ($s) { Close-PmSession $s } }
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
        })
}

function Add-PmJobLog {
    param($Job, [string]$Level = 'INFO', [string]$Message, [string]$Computer = $env:COMPUTERNAME)
    $entry = [pscustomobject]@{ time = (Get-Date).ToString('o'); level = $Level; computer = $Computer; message = $Message }
    if ($Job) {
        [void]$Job.logs.Add($entry)
        try { Add-Content -LiteralPath (Join-Path (Get-PmPath Jobs) "$($Job.id).log") -Value ("{0} [{1}] {2}: {3}" -f $entry.time, $Level, $Computer, $Message) -Encoding UTF8 } catch { }
    }
    if (-not $Job -or $Job.console) {
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
    $rec = [ordered]@{}
    foreach ($k in 'id', 'type', 'summary', 'status', 'progress', 'step', 'created', 'started', 'finished', 'result', 'error') { $rec[$k] = $Job[$k] }
    $rec.logs = @($Job.logs)
    ConvertTo-Json -InputObject $rec -Depth 10 | Set-Content -LiteralPath (Join-Path (Get-PmPath Jobs) "$($Job.id).json") -Encoding UTF8
}

function Invoke-PmJob {
    <#
        Executes a job synchronously. $Params:
          test    : ServerIds[]
          backup  : SourceId, Options
          restore : BackupName, TargetIds[], Options
          migrate : SourceId, TargetIds[], Options
          Credentials : optional hashtable serverId -> PSCredential (one-time, never stored)
    #>
    param([Parameter(Mandatory)]$Job, [Parameter(Mandatory)][string]$Type, [hashtable]$Params = @{})
    $Job.status = 'running'; $Job.started = (Get-Date).ToString('o')
    $creds = $Params.Credentials
    $options = if ($Params.Options) { ConvertTo-PmHashtable -InputObject $Params.Options } else { @{} }
    # The source is never touched unless the caller explicitly allows it.
    if (-not $options.ContainsKey('NoTouch')) { $options.NoTouch = $true }
    try {
        switch ($Type) {
            'test' {
                $results = @(); $ids = @($Params.ServerIds); $n = 0
                foreach ($id in $ids) {
                    $srv = Get-PmServer -Id $id
                    $mode = if ($Params.Mode) { [string]$Params.Mode } else { 'auto' }
                    try { $results += Invoke-PmTestFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Job $Job -Mode $mode }
                    catch { Add-PmJobLog -Job $Job -Level ERROR -Message "$($srv.name): $_"; $results += [pscustomobject]@{ ok = $false; error = "$_" } }
                    $n++; Set-PmJobProgress -Job $Job -Percent ([int](100 * $n / $ids.Count)) -Step "Tested $n of $($ids.Count)"
                }
                $Job.result = $results
                if (@($results | Where-Object { -not $_.ok }).Count -gt 0) { throw 'One or more servers failed the connectivity test.' }
            }
            'backup' {
                $srv = Get-PmServer -Id $Params.SourceId
                if (-not $options.ContainsKey('SourceAfter')) { $options.SourceAfter = 'Restart' }
                [void](Invoke-PmPreflight -Source $srv -Credentials $creds -Options $options -Job $Job)
                $file = Invoke-PmBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Options $options -Job $Job
                $Job.result = [pscustomobject]@{ backup = (Split-Path $file -Leaf) }
            }
            'restore' {
                $file = Get-PmBackupFile -Name $Params.BackupName
                $Job.result = Invoke-PmMultiRestore -File $file -TargetIds @($Params.TargetIds) -Options $options -Credentials $creds -Job $Job -Base 0 -Span 100
            }
            'migrate' {
                $srv = Get-PmServer -Id $Params.SourceId
                if (-not $options.ContainsKey('SourceAfter')) { $options.SourceAfter = 'KeepStopped' }
                $targets = @($Params.TargetIds | ForEach-Object { Get-PmServer -Id $_ })
                [void](Invoke-PmPreflight -Source $srv -Targets $targets -Credentials $creds -Options $options -Job $Job)
                if ($options.NoTouch) { Add-PmJobLog -Job $Job -Level WARN -Message 'No-touch mode: the source keeps running. Two PRTG cores with the same configuration will now monitor (and alert) in parallel.' }
                $file = Invoke-PmBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Options $options -Job $Job -ProgressBase 0 -ProgressSpan 40
                $reports = Invoke-PmMultiRestore -File $file -TargetIds @($Params.TargetIds) -Options $options -Credentials $creds -Job $Job -Base 40 -Span 60
                $Job.result = [pscustomobject]@{ backup = (Split-Path $file -Leaf); targets = $reports }
            }
            default { throw "Unknown job type '$Type'." }
        }
        $Job.status = 'succeeded'
        Set-PmJobProgress -Job $Job -Percent 100 -Step 'Completed'
        Add-PmJobLog -Job $Job -Level OK -Message "Job $($Job.id) completed successfully."
    } catch {
        $Job.status = 'failed'; $Job.error = "$_"
        Add-PmJobLog -Job $Job -Level ERROR -Message "Job failed: $_"
    } finally {
        $Job.finished = (Get-Date).ToString('o')
        Save-PmJobRecord -Job $Job
    }
}

function Invoke-PmMultiRestore {
    param([string]$File, [string[]]$TargetIds, [hashtable]$Options, [hashtable]$Credentials, $Job, [int]$Base, [int]$Span)
    $reports = @(); $i = 0; $failed = 0
    $slice = $Span / [math]::Max(1, $TargetIds.Count)
    foreach ($id in $TargetIds) {
        $srv = Get-PmServer -Id $id
        try {
            $rep = Invoke-PmRestoreFlow -Server $srv -Credential (Resolve-PmCredential $srv $Credentials) -BackupPath $File -Options $Options -Job $Job `
                -ProgressBase ($Base + [int]($i * $slice)) -ProgressSpan $slice
            $reports += [pscustomobject]@{ target = $srv.name; ok = (@($rep.Errors).Count -eq 0); report = $rep }
            if (@($rep.Errors).Count -gt 0) { $failed++ }
        } catch {
            $failed++
            Add-PmJobLog -Job $Job -Level ERROR -Message "$($srv.name): $_"
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
    $script:PmJobs[$job.id] = $job
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
        Add-PmJobLog -Job $job -Level WARN -Message 'Job cancelled by user (remote operations already started may still finish on the server).'
        Save-PmJobRecord -Job $job
    }
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
        logCount = $logs.Count; logs = @($logs | Select-Object -Skip $Since)
    }
}

function Get-PmInstallers {
    Get-ChildItem -LiteralPath (Get-PmPath Installers) -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.zip' } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; size = $_.Length; created = $_.LastWriteTime.ToString('o') } }
}

Export-ModuleMember -Function *-Pm*
