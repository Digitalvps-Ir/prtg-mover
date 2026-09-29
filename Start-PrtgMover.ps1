<#
.SYNOPSIS
    Starts the PRTG Mover web dashboard on the manager machine.

.DESCRIPTION
    Self-hosted HTTP dashboard (System.Net.HttpListener, no external dependencies) to
    manage servers, run connectivity tests, back up / migrate / restore PRTG servers,
    and download or upload backup packages.

    The dashboard listens on localhost and uses no access token. Requests that come from
    other web sites are refused. With -ListenAll everyone who can reach the port can use
    the dashboard.

.PARAMETER Port
    TCP port of the dashboard. Default 8765.

.PARAMETER ListenAll
    Listen on all interfaces instead of localhost only. Requires an URL ACL
    (tools\Setup-Manager.ps1 -DashboardPort <port> creates it). Traffic is plain HTTP,
    so only use it on a trusted management network.

.PARAMETER NoBrowser
    Do not open the browser automatically.

.PARAMETER NewToken
    Kept so older start commands still run. The dashboard uses no token.

.EXAMPLE
    .\Start-PrtgMover.ps1
.EXAMPLE
    .\Start-PrtgMover.ps1 -Port 9000 -NoBrowser
#>
[CmdletBinding()]
param(
    [int]$Port = 8765,
    [switch]$ListenAll,
    [switch]$NoBrowser,
    [switch]$NewToken,
    [switch]$Quiet,
    # Folder for config\, data\, backups\ and installers\. Default: the program folder.
    [string]$DataRoot
)

$ErrorActionPreference = 'Stop'
$Root = $PSScriptRoot
# Echo live job logs into this console (use -Quiet to turn it off).
if (-not $Quiet) { $env:PRTGMOVER_ECHO = '1' }
Import-Module (Join-Path $Root 'src\PrtgMover.psm1') -Force -DisableNameChecking
if ($DataRoot) { New-Item -ItemType Directory -Force -Path $DataRoot | Out-Null; Set-PmRoot -Path $DataRoot } else { Set-PmRoot -Path $Root }
$DataRootPath = Get-PmPath Root
# [string] + Trim() strips the provider NoteProperties Get-Content attaches (ConvertTo-Json would walk them).
$Version = 'dev'
$versionFile = Join-Path $Root 'VERSION'
if (Test-Path $versionFile) { $Version = ([IO.File]::ReadAllText($versionFile)).Trim() }

# The dashboard uses no access token. Remove a token left by an older version.
Remove-Item -LiteralPath (Join-Path (Get-PmPath Data) 'token.txt') -Force -ErrorAction SilentlyContinue

# ------------------------------------------------------------------ helpers
function Send-PmResponse {
    param($Ctx, [int]$Status = 200, [string]$Body = '', [string]$ContentType = 'application/json; charset=utf-8')
    $res = $Ctx.Response
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Body)
        $res.StatusCode = $Status
        $res.ContentType = $ContentType
        $res.Headers['Cache-Control'] = 'no-store'
        $res.Headers['X-Content-Type-Options'] = 'nosniff'
        $res.Headers['X-Frame-Options'] = 'DENY'
        $res.Headers['Referrer-Policy'] = 'no-referrer'
        $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally { $res.Close() }
}

function Send-PmJson {
    param($Ctx, $Object, [int]$Status = 200)
    Send-PmResponse -Ctx $Ctx -Status $Status -Body (ConvertTo-Json -InputObject $Object -Depth 12 -Compress)
}

function Read-PmBody {
    param($Ctx)
    $reader = New-Object IO.StreamReader($Ctx.Request.InputStream, [Text.Encoding]::UTF8)
    try { $txt = $reader.ReadToEnd() } finally { $reader.Dispose() }
    if ([string]::IsNullOrWhiteSpace($txt)) { return [pscustomobject]@{} }
    return $txt | ConvertFrom-Json
}

function Test-PmAuth {
    <# Returns the decision of Test-PmDashboardRequest for this request. #>
    param($Ctx)
    $req = $Ctx.Request
    Test-PmDashboardRequest -Method $req.HttpMethod -Path $req.Url.AbsolutePath.TrimEnd('/') `
        -Origin $req.Headers['Origin'] -RequestOrigin $req.Url.GetLeftPart([UriPartial]::Authority)
}

function Get-PmServerView {
    foreach ($s in (Get-PmServers)) {
        $status = $null
        $sf = Join-Path (Get-PmPath Status) "$($s.id).json"
        if (Test-Path $sf) { try { $status = Get-Content $sf -Raw -Encoding UTF8 | ConvertFrom-Json } catch { } }
        $s | Add-Member -NotePropertyName hasCredential -NotePropertyValue (Test-PmCredential -ServerId $s.id) -Force
        $s | Add-Member -NotePropertyName lastStatus -NotePropertyValue $status -Force
        $s | Add-Member -NotePropertyName agent -NotePropertyValue (Get-PmAgentStatus -ServerId $s.id) -Force
        $s | Add-Member -NotePropertyName agentCommand -NotePropertyValue (Get-PmAgentCommand -Server $s) -Force
        $s
    }
}

function ConvertTo-PmOneTimeCredentials {
    param($Obj)
    $h = @{}
    if ($null -eq $Obj) { return $h }
    foreach ($p in $Obj.PSObject.Properties) {
        if ($p.Value.username -and $p.Value.password) { $h[$p.Name] = New-PmCredential -UserName $p.Value.username -Password $p.Value.password }
    }
    return $h
}

# Streaming transfers run on their own runspace pool so big files never block the dashboard.
$IoPool = [runspacefactory]::CreateRunspacePool(1, 4); $IoPool.Open()
$IoTasks = New-Object System.Collections.ArrayList

$DownloadScript = {
    param($Ctx, $File, $DownloadName)
    $res = $Ctx.Response
    try {
        $fs = [IO.File]::OpenRead($File)
        try {
            $res.StatusCode = 200
            $res.ContentType = 'application/octet-stream'
            $res.ContentLength64 = $fs.Length
            $res.Headers['Content-Disposition'] = "attachment; filename=`"$DownloadName`""
            $fs.CopyTo($res.OutputStream, 1MB)
        } finally { $fs.Dispose() }
    } catch { } finally { try { $res.Close() } catch { } }
}

$UploadScript = {
    param($Ctx, $Dest, $Kind, $ModulePath, $Root)
    $res = $Ctx.Response
    $status = 200; $body = '{"ok":true}'
    $tmp = "$Dest.uploading"
    try {
        $fs = [IO.File]::Create($tmp)
        try { $Ctx.Request.InputStream.CopyTo($fs, 1MB) } finally { $fs.Dispose() }
        Move-Item -LiteralPath $tmp -Destination $Dest -Force
        if ($Kind -eq 'backup') {
            Import-Module $ModulePath -Force -DisableNameChecking
            Set-PmRoot -Path $Root
            try { Register-PmBackup -ZipPath $Dest }
            catch { Remove-Item -LiteralPath $Dest -Force -ErrorAction SilentlyContinue; throw }
        }
    } catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $status = 400; $body = (@{ error = "$_" } | ConvertTo-Json -Compress)
    }
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
        $res.StatusCode = $status; $res.ContentType = 'application/json; charset=utf-8'; $res.ContentLength64 = $bytes.Length
        $res.OutputStream.Write($bytes, 0, $bytes.Length)
    } finally { $res.Close() }
}

function Start-PmIoTask {
    param([scriptblock]$Script, [object[]]$Arguments)
    $ps = [powershell]::Create(); $ps.RunspacePool = $IoPool
    [void]$ps.AddScript($Script)
    foreach ($a in $Arguments) { [void]$ps.AddArgument($a) }
    [void]$IoTasks.Add(@{ PS = $ps; Async = $ps.BeginInvoke() })
}

function Get-PmSafeLeaf {
    param([string]$Name, [string[]]$Extensions)
    $leaf = [IO.Path]::GetFileName($Name)
    if (-not $leaf -or $leaf -ne $Name -or $leaf.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw "Invalid file name '$Name'." }
    if ($Extensions -and ([IO.Path]::GetExtension($leaf).ToLower() -notin $Extensions)) { throw "Only $($Extensions -join ', ') files are allowed." }
    return $leaf
}

# ------------------------------------------------------------------ router
function Invoke-PmRoute {
    param($Ctx)
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath.TrimEnd('/')
    if ($path -eq '') { $path = '/' }
    $method = $req.HttpMethod

    # ---- static files
    if ($method -eq 'GET' -and $path -notlike '/api/*') {
        $name = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
        $file = Join-Path (Get-PmPath Web) $name
        if ($name -match '^[\w\-\.]+$' -and (Test-Path -LiteralPath $file -PathType Leaf)) {
            $types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'; '.svg' = 'image/svg+xml' }
            $ct = $types[[IO.Path]::GetExtension($file)]; if (-not $ct) { $ct = 'application/octet-stream' }
            Send-PmResponse -Ctx $Ctx -Body ([IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)) -ContentType $ct
        } else { Send-PmJson $Ctx @{ error = 'Not found' } 404 }
        return
    }

    $auth = Test-PmAuth $Ctx
    if (-not $auth.Allowed) {
        Write-PmManagerLog -Level WARN -Message ("API {0} {1} refused ({2}): {3} | from {4} origin '{5}'" -f $method, $path, $auth.Status, $auth.Reason, $req.RemoteEndPoint, $req.Headers['Origin']) -Source 'api'
        Send-PmJson $Ctx @{ error = $auth.Reason } $auth.Status
        return
    }

    $seg = @($path.Substring(1).Split('/') | ForEach-Object { [uri]::UnescapeDataString($_) })   # api, resource, id, action

    switch -Regex ("$method $path") {
        '^GET /api/info$' {
            Send-PmJson $Ctx @{
                version = $Version; manager = $env:COMPUTERNAME; user = "$env:USERDOMAIN\$env:USERNAME"; root = $DataRootPath
                backupsPath = (Get-PmPath Backups); installersPath = (Get-PmPath Installers)
                servers = @(Get-PmServers).Count; backups = @(Get-PmBackups).Count
            }
            return
        }
        '^GET /api/servers$' { Send-PmJson $Ctx @(Get-PmServerView); return }
        '^POST /api/servers$' {
            $b = Read-PmBody $Ctx
            if (-not $b.name -or -not $b.host) { Send-PmJson $Ctx @{ error = 'name and host are required' } 400; return }
            $auth = if ($b.authentication) { [string]$b.authentication } else { 'Default' }
            $role = if ($b.role) { [string]$b.role } else { 'both' }
            $rdp = if ([int]$b.rdpPort -gt 0) { [int]$b.rdpPort } else { 3389 }
            if ([int]$b.port -gt 0 -and [int]$b.port -eq $rdp) { Send-PmJson $Ctx @{ error = "WinRM port $rdp is the RDP port. Put $rdp in 'RDP port' and leave the WinRM port at 0 (default 5985/5986)." } 400; return }
            $transport = switch ([string]$b.transport) { 'winrm' { 'winrm' } 'wireguard' { 'wireguard' } 'ipip' { 'ipip' } default { 'rdp' } }
            $srv = Set-PmServer -Id ([string]$b.id) -Name $b.name -HostName $b.host -Port ([int]$b.port) -UseSsl ([bool]$b.useSsl) `
                -SkipCaCheck ([bool]$b.skipCaCheck) -Authentication $auth -Role $role -Notes ([string]$b.notes) -RdpPort $rdp -Transport $transport
            if ($b.username -and $b.password) { Save-PmCredential -ServerId $srv.id -Credential (New-PmCredential -UserName $b.username -Password $b.password) }
            Write-PmAudit -Action $(if ($b.id) { 'server.updated' } else { 'server.added' }) -Data @{ id = $srv.id; name = $srv.name; host = $srv.host; transport = $srv.transport; rdpPort = $srv.rdpPort; winrmPort = $srv.port; credentialChanged = [bool]($b.username -and $b.password) }
            Send-PmJson $Ctx $srv
            return
        }
        '^DELETE /api/servers/[^/]+$' { Write-PmAudit -Action 'server.deleted' -Data @{ id = $seg[2] }; Remove-PmServer -Id $seg[2]; Send-PmJson $Ctx @{ ok = $true }; return }
        '^POST /api/servers/[^/]+/credential$' {
            $b = Read-PmBody $Ctx
            if (-not $b.username -or -not $b.password) { Send-PmJson $Ctx @{ error = 'username and password are required' } 400; return }
            [void](Get-PmServer -Id $seg[2])
            Save-PmCredential -ServerId $seg[2] -Credential (New-PmCredential -UserName $b.username -Password $b.password)
            Write-PmAudit -Action 'credential.saved' -Data @{ id = $seg[2]; user = [string]$b.username }
            Send-PmJson $Ctx @{ ok = $true }
            return
        }
        '^DELETE /api/servers/[^/]+/credential$' { Write-PmAudit -Action 'credential.removed' -Data @{ id = $seg[2] }; Remove-PmCredential -ServerId $seg[2]; Send-PmJson $Ctx @{ ok = $true }; return }
        '^POST /api/servers/[^/]+/rdp$' {
            $srv = Get-PmServer -Id $seg[2]
            [void](Start-PmRdp -Server $srv)
            Write-PmAudit -Action 'rdp.opened' -Data @{ id = $srv.id; host = $srv.host; port = (Get-PmRdpPort $srv) }
            [void](Get-PmAgentDir -ServerId $srv.id)
            Send-PmJson $Ctx @{ ok = $true; target = "$($srv.host):$(Get-PmRdpPort $srv)"; agentCommand = (Get-PmAgentCommand -Server $srv) }
            return
        }
        '^GET /api/servers/ports$' {
            # Quick TCP reachability (RDP + WinRM) of every server, checked in parallel.
            $servers = @(Get-PmServers)
            $checks = foreach ($s in $servers) {
                foreach ($kind in 'winrm', 'rdp') {
                    $p = if ($kind -eq 'rdp') { Get-PmRdpPort $s } else { Get-PmWinRmPort $s }
                    $c = New-Object Net.Sockets.TcpClient
                    @{ id = $s.id; kind = $kind; port = $p; client = $c; task = $c.ConnectAsync($s.host, $p) }
                }
            }
            $deadline = (Get-Date).AddSeconds(3)
            foreach ($c in @($checks)) { $left = [int]($deadline - (Get-Date)).TotalMilliseconds; if ($left -gt 0) { try { [void]$c.task.Wait($left) } catch { } } }
            $out = @{}
            foreach ($s in $servers) { $out[$s.id] = @{} }
            foreach ($c in @($checks)) {
                $out[$c.id][$c.kind] = @{ port = $c.port; open = ($c.task.Status -eq 'RanToCompletion') }
                $c.client.Dispose()
            }
            Send-PmJson $Ctx $out
            return
        }

        '^GET /api/backups$' { Send-PmJson $Ctx @(Get-PmBackups); return }
        '^PUT /api/backups/upload$' {
            $leaf = Get-PmSafeLeaf -Name $req.QueryString['name'] -Extensions '.zip'
            $dest = Join-Path (Get-PmPath Backups) $leaf
            if (Test-Path -LiteralPath $dest) { Send-PmJson $Ctx @{ error = 'A backup with this name already exists.' } 409; return }
            Start-PmIoTask -Script $UploadScript -Arguments @($Ctx, $dest, 'backup', (Join-Path $Root 'src\PrtgMover.psm1'), $DataRootPath)
            return
        }
        '^GET /api/backups/[^/]+/download$' {
            $f = Get-PmBackupFile -Name $seg[2]
            Start-PmIoTask -Script $DownloadScript -Arguments @($Ctx, $f, (Split-Path $f -Leaf))
            return
        }
        '^GET /api/backups/[^/]+/manifest$' { Send-PmJson $Ctx (Read-PmBackupManifest -ZipPath (Get-PmBackupFile -Name $seg[2])); return }
        '^DELETE /api/backups/[^/]+$' { Write-PmAudit -Action 'backup.deleted' -Data @{ name = $seg[2] }; Remove-PmBackup -Name $seg[2]; Send-PmJson $Ctx @{ ok = $true }; return }

        '^GET /api/installers$' { Send-PmJson $Ctx @(Get-PmInstallers); return }
        '^PUT /api/installers/upload$' {
            $leaf = Get-PmSafeLeaf -Name $req.QueryString['name'] -Extensions '.exe', '.zip'
            Start-PmIoTask -Script $UploadScript -Arguments @($Ctx, (Join-Path (Get-PmPath Installers) $leaf), 'installer', $null, $DataRootPath)
            return
        }
        '^DELETE /api/installers/[^/]+$' {
            $leaf = Get-PmSafeLeaf -Name $seg[2] -Extensions '.exe', '.zip'
            Remove-Item -LiteralPath (Join-Path (Get-PmPath Installers) $leaf) -Force -ErrorAction SilentlyContinue
            Send-PmJson $Ctx @{ ok = $true }
            return
        }

        '^GET /api/jobs$' { Send-PmJson $Ctx @(Get-PmJobs); return }
        '^POST /api/jobs$' {
            $b = Read-PmBody $Ctx
            $params = @{ Credentials = (ConvertTo-PmOneTimeCredentials $b.credentials); Options = $b.options }
            $names = @{}; foreach ($s in (Get-PmServers)) { $names[$s.id] = $s.name }
            switch ([string]$b.type) {
                'test' {
                    $params.ServerIds = [string[]]@($b.serverIds)
                    $params.Mode = if ($b.mode -in 'rdp', 'winrm') { [string]$b.mode } else { 'auto' }
                    $summary = "Test ($($params.Mode.ToUpper())): " + (($params.ServerIds | ForEach-Object { $names[$_] }) -join ', ')
                }
                'unlicense' {
                    $params.ServerIds = [string[]]@($b.serverIds)
                    $summary = 'Remove PRTG license: ' + (($params.ServerIds | ForEach-Object { $names[$_] }) -join ', ')
                }
                'rebind' {
                    $params.ServerIds = [string[]]@($b.serverIds)
                    $summary = 'Fix PRTG web binding: ' + (($params.ServerIds | ForEach-Object { $names[$_] }) -join ', ')
                }
                'backup' {
                    $params.SourceId = [string]$b.sourceId
                    $summary = "Backup: $($names[$params.SourceId])"
                }
                'restore' {
                    $params.BackupName = [string]$b.backupName; $params.TargetIds = [string[]]@($b.targetIds)
                    $summary = "Restore: $($params.BackupName) -> " + (($params.TargetIds | ForEach-Object { $names[$_] }) -join ', ')
                }
                'migrate' {
                    $params.SourceId = [string]$b.sourceId; $params.TargetIds = [string[]]@($b.targetIds)
                    $summary = "Migrate: $($names[$params.SourceId]) -> " + (($params.TargetIds | ForEach-Object { $names[$_] }) -join ', ')
                }
                default { Send-PmJson $Ctx @{ error = "Unknown job type '$($b.type)'" } 400; return }
            }
            foreach ($id in @($params.SourceId) + @($params.TargetIds) + @($params.ServerIds)) {
                if ($id -and -not $names.ContainsKey($id)) { Send-PmJson $Ctx @{ error = "Unknown server id '$id'" } 400; return }
            }
            if ($b.type -in 'restore', 'migrate' -and @($params.TargetIds).Count -eq 0) { Send-PmJson $Ctx @{ error = 'Select at least one target server.' } 400; return }
            if ($b.type -eq 'migrate' -and $params.TargetIds -contains $params.SourceId) { Send-PmJson $Ctx @{ error = 'Source and target must be different servers.' } 400; return }
            $xfer = ''
            if ($b.options) { $xfer = [string]$b.options.transfer }
            if (-not $xfer -and [string]$b.type -eq 'migrate') {
                $picked = @(Get-PmServer -Id $params.SourceId) + @($params.TargetIds | ForEach-Object { Get-PmServer -Id $_ })
                $xfer = Resolve-PmTunnelFromServers -Servers $picked
                if ($xfer) {
                    if (-not $params.Options) { $params.Options = @{} }
                    $params.Options.transfer = $xfer
                }
            }
            try { Assert-PmTransferSelection -Transfer $xfer -JobType ([string]$b.type) -TargetCount @(@($params.TargetIds) | Where-Object { $_ }).Count }
            catch { Send-PmJson $Ctx @{ error = "$_" } 400; return }
            if ($xfer -eq 'wireguard') { $summary += ' via WireGuard (server to server)' }
            elseif ($xfer -eq 'ipip') { $summary += ' via IPIP (server to server)' }
            elseif ($xfer -in 'rdp', 'winrm') { $summary += " via $($xfer.ToUpper())" }
            $job = Start-PmJob -Type $b.type -Params $params -Summary $summary
            Send-PmJson $Ctx @{ id = $job.id }
            return
        }
        '^GET /api/jobs/[^/]+$' {
            $since = 0; [void][int]::TryParse($req.QueryString['since'], [ref]$since)
            $j = Get-PmJob -Id $seg[2] -Since $since
            if ($j) { Send-PmJson $Ctx $j } else { Send-PmJson $Ctx @{ error = 'Job not found' } 404 }
            return
        }
        '^GET /api/jobs/[^/]+/log$' {
            $f = Join-Path (Get-PmPath Jobs) ((Get-PmSafeLeaf -Name $seg[2]) + '.log')
            if (Test-Path -LiteralPath $f) { Start-PmIoTask -Script $DownloadScript -Arguments @($Ctx, $f, "prtg-mover-$($seg[2]).log") }
            else { Send-PmJson $Ctx @{ error = 'Log not found' } 404 }
            return
        }
        '^POST /api/jobs/[^/]+/cancel$' { Stop-PmJob -Id $seg[2]; Send-PmJson $Ctx @{ ok = $true }; return }
        '^POST /api/jobs/[^/]+/resume$' {
            $job = Resume-PmJob -Id $seg[2]
            Send-PmJson $Ctx @{ id = $job.id }
            return
        }
        '^GET /api/diagnostics$' {
            $zip = New-PmDiagnosticsBundle
            Start-PmIoTask -Script $DownloadScript -Arguments @($Ctx, $zip, (Split-Path $zip -Leaf))
            return
        }
        '^GET /api/logs/audit$' {
            $af = Join-Path (Get-PmPath Data) 'logs\audit.log'
            $items = @()
            if (Test-Path -LiteralPath $af) { $items = @(Get-Content -LiteralPath $af -Tail 200 -Encoding UTF8 | ForEach-Object { try { [string]$_ | ConvertFrom-Json } catch { } }) }
            [array]::Reverse($items)
            Send-PmJson $Ctx @($items)
            return
        }
        '^GET /api/logs/manager$' {
            $lf = Join-Path (Get-PmPath Data) ('logs\manager-{0}.log' -f (Get-Date -Format 'yyyyMMdd'))
            # [string] strips the provider NoteProperties Get-Content attaches (ConvertTo-Json would walk them and hang).
            $lines = @(); if (Test-Path -LiteralPath $lf) { $lines = [string[]]@(Get-Content -LiteralPath $lf -Tail 300 -Encoding UTF8 | ForEach-Object { [string]$_ }) }
            Send-PmJson $Ctx @{ file = $lf; lines = $lines }
            return
        }
    }
    Send-PmJson $Ctx @{ error = "No route for $method $path" } 404
}

# ------------------------------------------------------------------ main loop
$listener = New-Object Net.HttpListener
$prefix = if ($ListenAll) { "http://+:$Port/" } else { "http://localhost:$Port/" }
$listener.Prefixes.Add($prefix)
try { $listener.Start() }
catch {
    Write-Host "Could not listen on $prefix : $($_.Exception.Message)" -ForegroundColor Red
    if ($ListenAll) { Write-Host "Run as administrator: .\tools\Setup-Manager.ps1 -DashboardPort $Port   (creates the URL ACL)" -ForegroundColor Yellow }
    exit 1
}

$url = "http://localhost:$Port/"
Write-Host ''
Write-Host "  PRTG Mover $Version - dashboard running" -ForegroundColor Cyan
Write-Host "  URL   : $url" -ForegroundColor Green
if ($ListenAll) { Write-Host "  LAN   : http://$($env:COMPUTERNAME):$Port/  (plain HTTP, NO access protection - everyone who reaches this port can use the dashboard)" -ForegroundColor Yellow }
Write-Host "  Data  : $DataRootPath"
Write-Host '  Stop  : Ctrl+C'
Write-Host "  Logs  : $(Join-Path (Get-PmPath Data) 'logs')  (manager, audit, robocopy) + data\jobs + data\agent\<id>\agent.log"
Repair-PmInterruptedJobs
Write-PmManagerLog -Message "Dashboard $Version started on $prefix by $env:USERDOMAIN\$env:USERNAME (PID $PID)" -Source 'dashboard'
Write-Host ''
if (-not $NoBrowser) { Start-Process $url }

try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.AsyncWaitHandle.WaitOne(500)) {
            # reap finished transfer tasks
            for ($i = $IoTasks.Count - 1; $i -ge 0; $i--) {
                if ($IoTasks[$i].Async.IsCompleted) { try { $IoTasks[$i].PS.EndInvoke($IoTasks[$i].Async) } catch { }; $IoTasks[$i].PS.Dispose(); $IoTasks.RemoveAt($i) }
            }
        }
        $ctx = $task.GetAwaiter().GetResult()
        $rsw = [Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-PmRoute -Ctx $ctx
            $m = $ctx.Request.HttpMethod
            if ($m -ne 'GET' -or $ctx.Request.Url.AbsolutePath -match 'download|diagnostics') { Write-PmManagerLog -Message ("API {0} {1} -> {2} ({3} ms)" -f $m, $ctx.Request.Url.AbsolutePath, $ctx.Response.StatusCode, $rsw.ElapsedMilliseconds) -Source 'api' }
        }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath) -> $($_.Exception.Message)" -ForegroundColor DarkYellow
            Write-PmManagerLog -Level ERROR -Message ("API {0} {1} failed: {2} | {3}" -f $ctx.Request.HttpMethod, $ctx.Request.Url.AbsolutePath, (Format-PmManagerError $_), ($_.ScriptStackTrace -replace '\r?\n', ' <- ')) -Source 'api'
            try { Send-PmJson $ctx @{ error = $_.Exception.Message } 500 } catch { }
        }
    }
} finally {
    $listener.Stop(); $listener.Close()
    $IoPool.Close()
    Write-Host 'PRTG Mover dashboard stopped.'
}
