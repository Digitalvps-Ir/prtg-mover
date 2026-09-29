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

$script:PmBackupKeys = 'IncludePrtg', 'IncludeHistory', 'IncludeVpn', 'IncludeDesktop', 'ExtraPaths', 'SourceAfter', 'NoTouch', 'HealthTimeoutMinutes', 'IncludeProgram'
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
    $f = Join-Path (Get-PmPath Data) "agent\$ServerId\heartbeat.json"
    if (-not (Test-Path -LiteralPath $f)) { return [pscustomobject]@{ connected = $false } }
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
    & $add 'OS' ((Get-CimInstance Win32_OperatingSystem).Caption)
    & $add 'PowerShell' $PSVersionTable.PSVersion
    & $add '.NET release' ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release)
    $admin = (New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    & $add 'Manager elevated' $admin
    & $add 'WinRM service' ((Get-Service WinRM -ErrorAction SilentlyContinue).Status)
    try { & $add 'TrustedHosts' ((Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value) } catch { & $add 'TrustedHosts' "unreadable ($($_.Exception.Message))" }
    & $add 'Root' (Get-PmPath Root)
    $rootDrive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f (Split-Path (Get-PmPath Root) -Qualifier))
    & $add 'Root drive free' ('{0:N1} GB' -f ($rootDrive.FreeSpace / 1GB))
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
            if ((Get-PmTransport $Source) -eq 'rdp') {
                Add-PmJobLog -Job $Job -Level OK -Message ("{0}: RDP mode stages directly on the manager - no free space needed on the source (PRTG data {1:N1} GB)." -f $Source.name, ($data / 1GB))
            } elseif ($data -gt 0 -and $src.FreeBytes -lt ($data * 2)) {
                $problems += ("{0}: needs ~{1:N1} GB free for staging + package, has {2:N1} GB. Switch the server to the RDP connection method (stages on the manager) or free space." -f $Source.name, ($data * 2 / 1GB), ($src.FreeBytes / 1GB))
            }
        }
        # manager: staging copy + zip
        $mgrDrive = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f (Split-Path (Get-PmPath Root) -Qualifier))
        if ($data -gt 0 -and $mgrDrive -and $mgrDrive.FreeSpace -lt ($data * 2.2)) {
            $problems += ("Manager: needs ~{0:N1} GB free on {1} for staging + package, has {2:N1} GB." -f ($data * 2.2 / 1GB), $mgrDrive.DeviceID, ($mgrDrive.FreeSpace / 1GB))
        }
    }
    foreach ($t in $Targets) {
        $ti = $info[$t.id]; if (-not $ti) { continue }
        $factor = if ((Get-PmTransport $t) -eq 'rdp') { 1.2 } else { 2.5 }
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

function Invoke-PmBackupFlow {
    <#
        Returns [pscustomobject]@{ Zip = <package on the manager>; StageDir = <extracted copy on the manager or $null> }.
        RDP (agent) sources copy straight into the manager's disk (no space used on the source);
        the manager then builds the zip. WinRM sources build the zip themselves.
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
        $agent = [bool]$s.PSObject.Properties['PmAgent']
        $stageLocal = $null
        if ($agent) {
            $stageLocal = Join-Path (Get-PmPath Data) "staging\$jobId"
            if (Test-Path -LiteralPath $stageLocal) { Remove-Item -LiteralPath $stageLocal -Recurse -Force }
            New-Item -ItemType Directory -Force -Path $stageLocal | Out-Null
            $params.StageDir = ConvertTo-PmTsClientPath $stageLocal
            $params.LogDir = ConvertTo-PmTsClientPath (Join-Path (Get-PmPath Data) 'logs\robocopy')
            Add-PmJobLog -Job $Job -Level DEBUG -Message "Direct staging: server writes to $($params.StageDir) (= $stageLocal on the manager)"
        }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmRemoteBackup' -Parameters $params -Job $Job -ProgressBase $ProgressBase -ProgressSpan ($ProgressSpan * 0.7)
        if (-not $r) { throw 'Remote backup returned no result.' }
        Add-PmJobLog -Job $Job -Level DEBUG -Message ("Remote backup phase took {0:N0} s" -f $sw.Elapsed.TotalSeconds)
        $manifest = $r.Manifest | ConvertFrom-Json

        if ($agent) {
            Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]($ProgressSpan * 0.75)) -Step 'Building the package on the manager'
            $zipName = 'PRTG_{0}_{1}.zip' -f $manifest.source.computer, (Get-Date -Format 'yyyyMMdd-HHmmss')
            $local = Join-Path (Get-PmPath Backups) $zipName
            Add-PmJobLog -Job $Job -Level STEP -Message ("Compressing the staged copy ({0:N2} GB) into {1} on the manager..." -f ($manifest.stagingBytes / 1GB), $zipName)
            $sw.Restart()
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::CreateFromDirectory($stageLocal, $local, [IO.Compression.CompressionLevel]::Optimal, $false)
            $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            Add-PmJobLog -Job $Job -Level OK -Message ("Package ready: {0} ({1:N1} MB, SHA-256 {2}, {3:N0} s)" -f $zipName, ((Get-Item -LiteralPath $local).Length / 1MB), $hash, $sw.Elapsed.TotalSeconds)
        } else {
            Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]($ProgressSpan * 0.75)) -Step 'Downloading package to manager'
            Add-PmJobLog -Job $Job -Level STEP -Message ("Downloading {0} ({1:N1} MB) to the manager..." -f $r.ZipName, ($r.Size / 1MB))
            $local = Join-Path (Get-PmPath Backups) $r.ZipName
            $sw.Restart()
            Copy-PmFromServer -Session $s -RemotePath $r.ZipPath -LocalPath $local -Job $Job
            $hash = (Get-FileHash -LiteralPath $local -Algorithm SHA256).Hash
            if ($hash -ne $r.Sha256) { throw "Checksum mismatch after download (remote $($r.Sha256), local $hash)." }
            Add-PmJobLog -Job $Job -Level OK -Message ("Backup stored on manager: {0} (SHA-256 verified, {1:N1} MB/s)" -f $local, (($r.Size / 1MB) / [math]::Max(1, $sw.Elapsed.TotalSeconds)))
            [void](Invoke-PmRemote -Session $s -Function 'Remove-PmRemoteFile' -Parameters @{ Path = $r.ZipPath } -Job $Job)
        }
        [pscustomobject]@{ source = $Server.name; sha256 = $hash; manifest = $manifest } |
            ConvertTo-Json -Depth 8 | Set-Content -LiteralPath "$local.meta.json" -Encoding UTF8
        Write-PmAudit -Action 'backup.created' -Data @{ job = $jobId; server = $Server.name; package = (Split-Path $local -Leaf); sha256 = $hash }
        Set-PmJobProgress -Job $Job -Percent ($ProgressBase + [int]$ProgressSpan) -Step 'Backup complete'
        $result = [pscustomobject]@{ Zip = $local; StageDir = $stageLocal }
        if ($r.SourceHealth -and -not $r.SourceHealth.Healthy) {
            throw "Backup saved as $(Split-Path $local -Leaf), but PRTG on the source did NOT come back up completely ($($r.SourceHealth.Message))."
        }
        return $result
    } finally { if ($s) { Close-PmSession $s } }
}

function Get-PmExtractedStage {
    <# Local extracted copy of a package (used by RDP-agent targets, which read it via \\tsclient). #>
    param([Parameter(Mandatory)][string]$ZipPath, [string]$StageDir, $Job)
    if ($StageDir -and (Test-Path -LiteralPath (Join-Path $StageDir 'manifest.json'))) { return $StageDir }
    $dir = Join-Path (Get-PmPath Data) ("staging\restore-" + [IO.Path]::GetFileNameWithoutExtension($ZipPath))
    if (Test-Path -LiteralPath (Join-Path $dir 'manifest.json')) { return $dir }
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force }
    Add-PmJobLog -Job $Job -Level STEP -Message "Extracting $(Split-Path $ZipPath -Leaf) on the manager for direct reading by the target..."
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $dir)
    return $dir
}

function Invoke-PmRestoreFlow {
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

        if (-not $init.Prtg.Installed -and $Options.InstallerFile) {
            $inst = Join-Path (Get-PmPath Installers) (Split-Path $Options.InstallerFile -Leaf)
            if (-not (Test-Path -LiteralPath $inst)) { throw "Installer '$($Options.InstallerFile)' not found in installers folder." }
            Add-PmJobLog -Job $Job -Level STEP -Message "Uploading installer $(Split-Path $inst -Leaf)..."
            $remoteInst = Join-Path $init.Inbox (Split-Path $inst -Leaf)
            Copy-PmToServer -Session $s -LocalPath $inst -RemotePath $remoteInst -Job $Job
            $params.InstallerPath = $remoteInst
        }

        if ($agent) {
            # The target reads the extracted package straight from the manager - no zip copy, no extraction on the target.
            $stageLocal = Get-PmExtractedStage -ZipPath $BackupPath -StageDir $StageDir -Job $Job
            $params.StageDir = ConvertTo-PmTsClientPath $stageLocal
            $params.LogDir = ConvertTo-PmTsClientPath (Join-Path (Get-PmPath Data) 'logs\robocopy')
            Add-PmJobLog -Job $Job -Level DEBUG -Message "Direct restore: target reads $($params.StageDir)"
        } else {
            $size = (Get-Item -LiteralPath $BackupPath).Length
            if ($init.FreeBytes -and $init.FreeBytes -lt ($size * 3)) {
                throw ("Not enough free space on target: {0:N1} GB free, ~{1:N1} GB needed." -f ($init.FreeBytes / 1GB), ($size * 3 / 1GB))
            }
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
        }

        $r = Invoke-PmRemote -Session $s -Function 'Invoke-PmRemoteRestore' -Parameters $params -Job $Job `
            -ProgressBase ($ProgressBase + [int]($ProgressSpan * 0.2)) -ProgressSpan ($ProgressSpan * 0.8)
        if (-not $r) { throw 'Remote restore returned no result.' }
        Write-PmAudit -Action 'restore.finished' -Data @{ job = $jobId; server = $Server.name; package = (Split-Path $BackupPath -Leaf); prtg = $r.Report.Prtg; errors = @($r.Report.Errors).Count }
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
            'backup' {
                $srv = Get-PmServer -Id $Params.SourceId
                if (-not $options.ContainsKey('SourceAfter')) { $options.SourceAfter = 'Restart' }
                [void](Invoke-PmPreflight -Source $srv -Credentials $creds -Options $options -Job $Job)
                $b = Invoke-PmBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Options $options -Job $Job
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
                $targets = @($targetIds | ForEach-Object { Get-PmServer -Id $_ })
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
                    $srv = Get-PmServer -Id $Params.SourceId
                    [void](Invoke-PmPreflight -Source $srv -Targets $targets -Credentials $creds -Options $options -Job $Job)
                    if ($options.NoTouch) { Add-PmJobLog -Job $Job -Level WARN -Message 'No-touch mode: the source keeps running. Two PRTG cores with the same configuration will monitor (and alert) in parallel until you shut the old one down.' }
                    $b = Invoke-PmBackupFlow -Server $srv -Credential (Resolve-PmCredential $srv $creds) -Options $options -Job $Job -ProgressBase 0 -ProgressSpan 40
                    $file = $b.Zip; $stage = $b.StageDir
                    Set-PmCheckpoint -Job $Job -Backup (Split-Path $file -Leaf) -StageDir $stage
                }
                $reports = Invoke-PmMultiRestore -File $file -StageDir $stage -TargetIds $targetIds -Options $options -Credentials $creds -Job $Job -Base 40 -Span 60
                $Job.result = [pscustomobject]@{ backup = (Split-Path $file -Leaf); targets = $reports }
                if ($stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue; Add-PmJobLog -Job $Job -Level DEBUG -Message "Staging copy removed: $stage" }
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
        $srv = Get-PmServer -Id $id
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
        resumable = [bool]($j.params -and $j.status -in 'failed', 'cancelled')
        logCount = $logs.Count; logs = @($logs | Select-Object -Skip $Since)
    }
}

function Get-PmInstallers {
    Get-ChildItem -LiteralPath (Get-PmPath Installers) -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.exe', '.zip' } |
        ForEach-Object { [pscustomobject]@{ name = $_.Name; size = $_.Length; created = $_.LastWriteTime.ToString('o') } }
}

Export-ModuleMember -Function *-Pm*
