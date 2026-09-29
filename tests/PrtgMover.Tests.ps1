#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Run: Invoke-Pester -Path .\tests -Output Detailed

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $Root 'src\Remote\PrtgMover.Remote.ps1')
    Import-Module (Join-Path $Root 'src\PrtgMover.psm1') -Force -DisableNameChecking
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("pm-tests-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Work | Out-Null
}

AfterAll {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'RAS phonebook handling' {
    BeforeEach {
        $src = Join-Path $Work 'src.pbk'
        $dst = Join-Path $Work 'dst.pbk'
        Remove-Item $src, $dst -ErrorAction SilentlyContinue
        "[Office VPN]`r`nType=2`r`nPhoneNumber=vpn.example.com`r`n`r`n[Backup Site]`r`nType=2`r`nPhoneNumber=10.0.0.1" | Set-Content $src -Encoding Default
    }

    It 'parses entry names' {
        $names = @(Get-PmPbkEntries -Path $src | ForEach-Object { $_.Name })
        $names | Should -Be @('Office VPN', 'Backup Site')
    }

    It 'returns an empty list for a missing file' {
        # The function returns the list itself (comma operator), so count the list, not a wrapper array.
        (Get-PmPbkEntries -Path (Join-Path $Work 'missing.pbk')).Count | Should -Be 0
    }

    It 'creates the target phonebook when it does not exist' {
        $added = @(Merge-PmPbk -SourcePath $src -TargetPath $dst)
        $added.Count | Should -Be 2
        (Get-Content $dst -Raw) | Should -Match 'PhoneNumber=vpn.example.com'
    }

    It 'only appends entries that are missing and keeps existing ones untouched' {
        "[Backup Site]`r`nType=2`r`nPhoneNumber=KEEP-ME" | Set-Content $dst -Encoding Default
        $added = @(Merge-PmPbk -SourcePath $src -TargetPath $dst)
        $added | Should -Be @('Office VPN')
        $content = Get-Content $dst -Raw
        $content | Should -Match 'KEEP-ME'
        $content | Should -Not -Match 'PhoneNumber=10.0.0.1'
    }

    It 'is idempotent' {
        [void](Merge-PmPbk -SourcePath $src -TargetPath $dst)
        @(Merge-PmPbk -SourcePath $src -TargetPath $dst).Count | Should -Be 0
    }

    It 'keeps a pre-restore copy of an existing phonebook' {
        "[Other]`r`nType=2" | Set-Content $dst -Encoding Default
        [void](Merge-PmPbk -SourcePath $src -TargetPath $dst)
        @(Get-ChildItem $Work -Filter 'dst.pbk.pre-restore-*').Count | Should -BeGreaterThan 0
    }
}

Describe 'PRTG web server binding after a migration' {
    It 'replaces addresses of the source by the address of this server' {
        Get-PmReboundIpList -Current '109.122.248.8,127.0.0.1' -Local @('127.0.0.1', '109.122.248.2', '10.66.66.2') -Own '109.122.248.2' | Should -Be '109.122.248.2,127.0.0.1'
    }
    It 'keeps addresses that exist on this server and always keeps localhost' {
        Get-PmReboundIpList -Current '10.0.0.5' -Local @('10.0.0.5') -Own '10.0.0.5' | Should -Be '10.0.0.5,127.0.0.1'
        Get-PmReboundIpList -Current '1.1.1.1, 2.2.2.2' -Local @('3.3.3.3') -Own '3.3.3.3' | Should -Be '3.3.3.3,127.0.0.1'
    }
    It 'leaves a localhost-only binding alone unless the own address is requested' {
        Get-PmReboundIpList -Current '127.0.0.1' -Local @('127.0.0.1', '109.122.248.2') -Own '109.122.248.2' | Should -Be '127.0.0.1'
        Get-PmReboundIpList -Current '127.0.0.1' -Local @('127.0.0.1', '109.122.248.2') -Own '109.122.248.2' -AddOwn | Should -Be '109.122.248.2,127.0.0.1'
    }
}

Describe 'PRTG license state from the core log' {
    It 'recognises a license that needs activation on a new system' {
        $s = ConvertTo-PmLicenseState -PausedByLicense '386' -LogLines @(
            'Core.log: 2026-09-29 09:31:26.219031 INFO TId    3956 Core> PRTG No License (System Changed) licensed for "name" (<key>) Edt=-100 MaxS=0',
            'CoreWebServer.log: 2026-09-29 09:38:24.052464 INFO TId    2520 CoreWebServer> System has changed. New activation required. (Verify Error, EIdHTTPProtocolException: HTTP/1.1 403 Forbidden)')
        $s.Known | Should -BeTrue
        $s.NeedsActivation | Should -BeTrue
        $s.Edition | Should -Be 'No License (System Changed)'
        $s.MaxSensors | Should -Be 0
        $s.LastError | Should -BeLike '*403 Forbidden*'
        $s.PausedByLicense | Should -Be '386'
    }
    It 'recognises an active license and uses the latest entry' {
        $s = ConvertTo-PmLicenseState -LogLines @(
            'Core.log: 2026 INFO TId 1 Core> PRTG No License (System Changed) licensed for "name" (<key>) Edt=-100 MaxS=0',
            'CoreActivationLog.log: 2026-09-29 06:34:47.205268 INFO TId    1660 CoreActivationLog> PRTG  (Site License) licensed for "name" (<key>) Edt=70 MaxS=99999')
        $s.NeedsActivation | Should -BeFalse
        $s.Edition | Should -Be 'Site License'
        $s.MaxSensors | Should -Be 99999
    }
    It 'reports an unknown state when the log has no license line' {
        (ConvertTo-PmLicenseState -LogLines @('Core.log: nothing relevant')).Known | Should -BeFalse
    }
    It 'never returns a license value, only a fingerprint' {
        Get-PmShortHash 'SECRET-LICENSE-KEY' | Should -Match '^[0-9a-f]{10}$'
    }
}

Describe 'Backup / restore round trip (local, no PRTG)' {
    It 'packages extra paths and restores them to the original location' {
        $extra = Join-Path $Work 'extra-data'
        New-Item -ItemType Directory -Force -Path (Join-Path $extra 'sub') | Out-Null
        'hello' | Set-Content (Join-Path $extra 'sub\a.txt')
        $wr = Join-Path $Work 'wr'

        $out = @(Invoke-PmRemoteBackup -JobId 'rt1' -WorkRoot $wr -IncludePrtg $false -IncludeVpn $false -IncludeDesktop $false -ExtraPaths @($extra))
        $res = $out | Where-Object PmType -eq 'result'
        $res | Should -Not -BeNullOrEmpty
        Test-Path $res.ZipPath | Should -BeTrue
        $res.Sha256 | Should -Be (Get-FileHash $res.ZipPath -Algorithm SHA256).Hash

        $manifest = Read-PmBackupManifest -ZipPath $res.ZipPath
        $manifest.tool | Should -Be 'prtg-mover'
        @($manifest.extra).Count | Should -Be 1

        Remove-Item $extra -Recurse -Force
        $out2 = @(Invoke-PmRemoteRestore -JobId 'rt2' -ZipPath $res.ZipPath -WorkRoot $wr -RestorePrtg $false -RestoreVpn $false -RestoreDesktop $false -RemovePackage $true)
        ($out2 | Where-Object PmType -eq 'result').Report.Extra | Should -Be 'ok'
        Get-Content (Join-Path $extra 'sub\a.txt') | Should -Be 'hello'
        Test-Path $res.ZipPath | Should -BeFalse
    }

    It 'rejects a package whose checksum does not match' {
        $wr = Join-Path $Work 'wr-bad'
        $out = @(Invoke-PmRemoteBackup -JobId 'rt4' -WorkRoot $wr -IncludePrtg $false -IncludeVpn $false -IncludeDesktop $false)
        $zip = ($out | Where-Object PmType -eq 'result').ZipPath
        { Invoke-PmRemoteRestore -JobId 'rt5' -ZipPath $zip -WorkRoot $wr -ExpectedSha256 'BAD' } | Should -Throw '*checksum mismatch*'
    }

    It 'pull mode stages only small items on the source and lists the big folders for the manager' {
        $wr = Join-Path $Work 'wr-pull'
        $x = Join-Path $Work 'pull-extra'
        New-Item -ItemType Directory -Force -Path (Join-Path $x 'Logs'), (Join-Path $x 'keep') | Out-Null
        'a' | Set-Content (Join-Path $x 'keep\a.txt'); 'b' | Set-Content (Join-Path $x 'Logs\b.log'); 'c' | Set-Content (Join-Path $x 'cache.tmp')
        $out = @(Invoke-PmRemoteBackup -JobId 'pull1' -WorkRoot $wr -IncludePrtg $false -IncludeVpn $false -IncludeDesktop $false -PullMode $true)
        $res = $out | Where-Object PmType -eq 'result'
        Test-Path (Join-Path $res.StageDir 'manifest.json') | Should -BeTrue
        $res.ZipPath | Should -BeNullOrEmpty
        # the file list honours excluded folders and file patterns
        $lst = (Get-PmPullList -Source $x -ExcludeDirs @((Join-Path $x 'Logs')) -ExcludeFiles @('*.tmp') | Where-Object PmType -eq 'result')
        @($lst.Files | ForEach-Object { $_.Rel }) | Should -Be @('keep\a.txt')
        # cleanup leaves nothing behind
        [void](Complete-PmRemotePull -StageDir $res.StageDir)
        Test-Path $res.StageDir | Should -BeFalse
    }

    It 'restores from a local stage by moving folders (no second copy) and removes the stage' {
        $wr = Join-Path $Work 'wr-move'
        $x = Join-Path $Work 'move-extra'
        New-Item -ItemType Directory -Force -Path $x | Out-Null
        'moved' | Set-Content (Join-Path $x 'm.txt')
        $out = @(Invoke-PmRemoteBackup -JobId 'mv1' -WorkRoot $wr -IncludePrtg $false -IncludeVpn $false -IncludeDesktop $false -ExtraPaths @($x) -PullMode $true)
        $stage = ($out | Where-Object PmType -eq 'result').StageDir
        Remove-Item $x -Recurse -Force
        $r = @(Invoke-PmRemoteRestore -JobId 'mv2' -StageDir $stage -WorkRoot $wr -RestorePrtg $false -RestoreVpn $false -RestoreDesktop $false -MoveFromStage $true -CleanupStage $true) | Where-Object PmType -eq 'result'
        $r.Report.Extra | Should -Be 'ok'
        Get-Content (Join-Path $x 'm.txt') | Should -Be 'moved'
        Test-Path $stage | Should -BeFalse
    }

    It 'packs and unpacks transfer chunks (remote and manager side, hidden files included)' {
        $src = Join-Path $Work 'chunk-src'
        New-Item -ItemType Directory -Force -Path (Join-Path $src 'sub') | Out-Null
        ('x' * 100000) | Set-Content (Join-Path $src 'sub\big.txt')
        'hidden' | Set-Content (Join-Path $src 'h.dat')
        try { (Get-Item (Join-Path $src 'h.dat')).Attributes = 'Hidden' } catch { }
        $c = (New-PmTransferChunk -Source $src -Files @('sub\big.txt', 'h.dat')) | Where-Object PmType -eq 'result'
        $c.Size | Should -BeLessThan 100000
        $dst = Join-Path $Work 'chunk-dst'
        [void](Expand-PmTransferChunk -ChunkPath $c.Path -Destination $dst)
        Get-Content (Join-Path $dst 'h.dat') | Should -Be 'hidden'
        (Get-Item (Join-Path $dst 'sub\big.txt')).Length | Should -Be (Get-Item (Join-Path $src 'sub\big.txt')).Length
        Test-Path $c.Path | Should -BeFalse
        $lc = Join-Path $Work 'local.zip'
        New-PmLocalChunk -Source $src -Files @('sub\big.txt') -ChunkPath $lc
        Expand-PmLocalChunk -ChunkPath $lc -Destination (Join-Path $Work 'chunk-dst2')
        Test-Path (Join-Path $Work 'chunk-dst2\sub\big.txt') | Should -BeTrue
    }

    It 'emits only log / progress / result records' {
        $out = @(Invoke-PmRemoteBackup -JobId 'rt3' -WorkRoot (Join-Path $Work 'wr3') -IncludePrtg $false -IncludeVpn $false -IncludeDesktop $false)
        @($out | Where-Object { $_.PmType -notin 'log', 'progress', 'result' }).Count | Should -Be 0
    }
}

Describe 'RDP agent transport (end to end, local)' {
    BeforeAll {
        $env:PRTGMOVER_TEST = '1'
        $env:PRTGMOVER_TSCLIENT_ROOT = $Root   # the local "agent" reaches the manager folder directly, not via \\tsclient
        Set-PmRoot -Path $Root   # the agent resolves the manager folder from its own location
        $script:AgentSrv = Set-PmServer -Name 'PESTER-AGENT' -HostName '127.0.0.1' -Transport rdp
        $agentStart = @{
            FilePath = (Get-Process -Id $PID).Path
            PassThru = $true
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $Root 'agent\PrtgMover-Agent.ps1'), '-ServerId', $script:AgentSrv.id, '-AllowNonAdmin')
        }
        # -WindowStyle is Windows PowerShell 5.1 only. PowerShell 7 rejects the parameter.
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $agentStart.WindowStyle = 'Hidden' }
        $script:AgentProc = Start-Process @agentStart
    }
    AfterAll {
        if ($script:AgentProc) { Stop-Process -Id $AgentProc.Id -Force -ErrorAction SilentlyContinue }
        Remove-PmServer -Id $AgentSrv.id
        Remove-Item -LiteralPath (Join-Path $Root "data\agent\$($AgentSrv.id)") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\PRTGMOVER_TEST, Env:\PRTGMOVER_TSCLIENT_ROOT -ErrorAction SilentlyContinue
    }

    It 'backs up through the agent, stores the package on the manager and restores it' {
        $src = Join-Path $Work 'agent-extra'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        'via-agent' | Set-Content (Join-Path $src 'f.txt')
        $job = New-PmJobObject -Type 'backup' -Summary 'pester'
        $bk = Invoke-PmBackupFlow -Server $AgentSrv -Options @{ IncludePrtg = $false; IncludeVpn = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($src); NoTouch = $true } -Job $job
        $file = $bk.Zip
        try {
            Test-Path -LiteralPath $file | Should -BeTrue
            # RDP mode stages directly on the manager
            Test-Path -LiteralPath (Join-Path $bk.StageDir 'manifest.json') | Should -BeTrue
            Remove-Item -LiteralPath $src -Recurse -Force
            $rep = Invoke-PmRestoreFlow -Server $AgentSrv -BackupPath $file -StageDir $bk.StageDir -Options @{ RestorePrtg = $false; RestoreVpn = $false; RestoreDesktop = $false } -Job $job
            $rep.Extra | Should -Be 'ok'
            Get-Content (Join-Path $src 'f.txt') | Should -Be 'via-agent'
            @($job.logs | Where-Object { $_.message -like '*direct staging on the manager*' }).Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath (Join-Path $Root "data\agent\$($AgentSrv.id)\agent.log") | Should -BeTrue
        } finally {
            Remove-PmBackup -Name (Split-Path $file -Leaf)
            Remove-Item -LiteralPath $bk.StageDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'restores from a zip by extracting it on the manager for the agent' {
        $src = Join-Path $Work 'agent-extra2'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        'from-zip' | Set-Content (Join-Path $src 'g.txt')
        $job = New-PmJobObject -Type 'restore' -Summary 'pester'
        $bk = Invoke-PmBackupFlow -Server $AgentSrv -Options @{ IncludePrtg = $false; IncludeVpn = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($src) } -Job $job
        Remove-Item -LiteralPath $bk.StageDir -Recurse -Force
        Remove-Item -LiteralPath $src -Recurse -Force
        try {
            $rep = Invoke-PmRestoreFlow -Server $AgentSrv -BackupPath $bk.Zip -Options @{ RestorePrtg = $false; RestoreVpn = $false; RestoreDesktop = $false } -Job $job
            $rep.Extra | Should -Be 'ok'
            Get-Content (Join-Path $src 'g.txt') | Should -Be 'from-zip'
        } finally {
            Remove-PmBackup -Name (Split-Path $bk.Zip -Leaf)
            Remove-Item -LiteralPath (Join-Path $Root ("data\staging\restore-" + [IO.Path]::GetFileNameWithoutExtension($bk.Zip))) -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Parallel chunked transfer (local transport, same code path as WinRM)' {
    BeforeAll {
        $script:PRoot = Join-Path $Work 'manager-parallel'
        New-Item -ItemType Directory -Force -Path $PRoot | Out-Null
        Set-PmRoot -Path $PRoot
        $env:PRTGMOVER_WORKROOT = Join-Path $Work 'server-workroot'
        $env:PRTGMOVER_RETRY_SECONDS = '0'
        $script:Local = Set-PmServer -Name 'LOCAL' -HostName 'localhost' -Transport local
        $script:PSrc = Join-Path $Work 'par-src'
        New-Item -ItemType Directory -Force -Path (Join-Path $PSrc 'a\b'), (Join-Path $PSrc 'c') | Out-Null
        $rnd = New-Object Random 42
        1..40 | ForEach-Object {
            $bytes = New-Object byte[] (20000 + $rnd.Next(60000)); $rnd.NextBytes($bytes)
            $dir = @('', 'a', 'a\b', 'c')[$_ % 4]
            [IO.File]::WriteAllBytes((Join-Path (Join-Path $PSrc $dir) "f$_.bin"), $bytes)
        }
        $script:HashOf = { param($root) $h = @{}; Get-ChildItem $root -Recurse -File -Force | ForEach-Object { $h[$_.FullName.Substring($root.Length + 1)] = (Get-FileHash $_.FullName).Hash }; $h }
    }
    AfterAll {
        Remove-Item Env:\PRTGMOVER_WORKROOT, Env:\PRTGMOVER_RETRY_SECONDS -ErrorAction SilentlyContinue
    }

    It 'pulls with several streams, keeps timestamps, purges extra files and resumes without re-transferring' {
        $dst = Join-Path $Work 'par-dst'
        New-Item -ItemType Directory -Force -Path $dst | Out-Null
        'junk' | Set-Content (Join-Path $dst 'old-cache.tmp')
        $s = New-PmSession -Server $Local
        $lst = Invoke-PmRemote -Session $s -Function 'Get-PmPullList' -Parameters @{ Source = $PSrc }
        $lst.Count | Should -Be 40
        $job = New-PmJobObject -Type 'backup' -Summary 'par'
        Invoke-PmTransferFiles -Session $s -Direction Pull -RemoteRoot $PSrc -LocalRoot $dst -Files @($lst.Files) -Job $job -Server $Local -Streams 3 -ChunkBytes 200KB -Purge
        @($job.logs | Where-Object { $_.message -like '*parallel streams*' }).Count | Should -Be 1
        Test-Path (Join-Path $dst 'old-cache.tmp') | Should -BeFalse
        $a = & $HashOf $PSrc; $b = & $HashOf $dst
        $b.Count | Should -Be 40
        foreach ($k in $a.Keys) { $b[$k] | Should -Be $a[$k] }
        (Get-Item (Join-Path $dst 'a\b\f2.bin')).LastWriteTimeUtc | Should -Be (Get-Item (Join-Path $PSrc 'a\b\f2.bin')).LastWriteTimeUtc
        # second run: nothing left to do
        $job2 = New-PmJobObject -Type 'backup' -Summary 'par2'
        Invoke-PmTransferFiles -Session $s -Direction Pull -RemoteRoot $PSrc -LocalRoot $dst -Files @($lst.Files) -Job $job2 -Server $Local -Streams 3 -ChunkBytes 200KB
        @($job2.logs | Where-Object { $_.message -like '* 0 file(s), 0.00 GB still to transfer*' }).Count | Should -Be 1
        # no temporary chunks left on either side
        @(Get-ChildItem (Join-Path $PRoot 'data\chunks') -File -ErrorAction SilentlyContinue).Count | Should -Be 0
        @(Get-ChildItem (Join-Path $env:PRTGMOVER_WORKROOT 'chunks') -File -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    It 'pushes with several streams' {
        $remote = Join-Path $Work 'par-remote\stage'
        $s = New-PmSession -Server $Local
        $files = @((Get-PmLocalFileList -Root $PSrc).GetEnumerator() | ForEach-Object { [pscustomobject]@{ Rel = $_.Value.FullName.Substring($PSrc.Length + 1); Size = $_.Value.Length; Time = $_.Value.LastWriteTimeUtc.Ticks } })
        Invoke-PmTransferFiles -Session $s -Direction Push -RemoteRoot $remote -LocalRoot $PSrc -Files $files -Server $Local -Streams 4 -ChunkBytes 300KB
        $a = & $HashOf $PSrc; $b = & $HashOf $remote
        $b.Count | Should -Be 40
        foreach ($k in $a.Keys) { $b[$k] | Should -Be $a[$k] }
    }

    It 'fails the whole transfer when a stream cannot transfer its chunk' {
        $s = New-PmSession -Server $Local
        $lst = Invoke-PmRemote -Session $s -Function 'Get-PmPullList' -Parameters @{ Source = $PSrc }
        $files = @($lst.Files) + [pscustomobject]@{ Rel = 'missing\ghost.bin'; Size = 10; Time = 1 }
        { Invoke-PmTransferFiles -Session $s -Direction Pull -RemoteRoot $PSrc -LocalRoot (Join-Path $Work 'par-fail') -Files $files -Server $Local -Streams 2 -ChunkBytes 200KB } | Should -Throw '*failed 4 times*'
    }

    It 'runs a complete backup and restore through the pull / push / move path' {
        $x = Join-Path $Work 'flow-extra'
        New-Item -ItemType Directory -Force -Path (Join-Path $x 'sub') | Out-Null
        'flow' | Set-Content (Join-Path $x 'sub\f.txt')
        $job = New-PmJobObject -Type 'migrate' -Summary 'flow'
        $opt = @{ IncludePrtg = $false; IncludeVpn = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($x); NoTouch = $true }
        $bk = Invoke-PmBackupFlow -Server $Local -Options $opt -Job $job
        Test-Path $bk.Zip | Should -BeTrue
        Test-PmStageComplete -StageDir $bk.StageDir | Should -BeTrue
        Remove-Item $x -Recurse -Force
        $rep = Invoke-PmRestoreFlow -Server $Local -BackupPath $bk.Zip -StageDir $bk.StageDir -Options @{ RestorePrtg = $false; RestoreVpn = $false; RestoreDesktop = $false } -Job $job
        $rep.Extra | Should -Be 'ok'
        @($rep.Errors).Count | Should -Be 0
        Get-Content (Join-Path $x 'sub\f.txt') | Should -Be 'flow'
        # nothing left behind on the "server"
        @(Get-ChildItem (Join-Path $env:PRTGMOVER_WORKROOT 'restore') -Force -ErrorAction SilentlyContinue).Count | Should -Be 0
    }
}

Describe 'Connectivity tests keep each method separately' {
    BeforeAll {
        $mgr = Join-Path $Work 'manager-tests'
        New-Item -ItemType Directory -Force -Path $mgr | Out-Null
        Set-PmRoot -Path $mgr
        # 127.0.0.1 with ports that are certainly closed
        $script:T = Set-PmServer -Name 'CLOSED' -HostName '127.0.0.1' -RdpPort 1 -Port 2 -Transport rdp
    }

    It 'fails an RDP test on a closed port and records only the RDP result' {
        { Invoke-PmTestFlow -Server (Get-PmServer -Id $T.id) -Mode rdp } | Should -Throw
        $st = Get-Content (Join-Path $mgr "data\status\$($T.id).json") -Raw | ConvertFrom-Json
        $st.methods.rdp.ok | Should -BeFalse
        $st.methods.winrm | Should -BeNullOrEmpty
    }

    It 'keeps the earlier RDP result when WinRM is tested and passes if one method is OK' {
        $sf = Join-Path $mgr "data\status\$($T.id).json"
        $st = Get-Content $sf -Raw | ConvertFrom-Json
        $st.methods.rdp.ok = $true      # simulate: RDP worked earlier
        $st | ConvertTo-Json -Depth 6 | Set-Content $sf
        { Invoke-PmTestFlow -Server (Get-PmServer -Id $T.id) -Mode winrm } | Should -Throw
        $st = Get-Content $sf -Raw | ConvertFrom-Json
        $st.methods.rdp.ok | Should -BeTrue
        $st.methods.winrm.ok | Should -BeFalse
        $st.ok | Should -BeTrue
    }
}

Describe 'Connection method "local": PRTG Mover on the server itself' {
    BeforeAll {
        $script:LocalRoot = Join-Path $Work 'manager-local'
        New-Item -ItemType Directory -Force -Path $LocalRoot | Out-Null
        Set-PmRoot -Path $LocalRoot
        $script:Me = Set-PmServer -Name 'THIS' -HostName 'localhost' -Transport local -Role both
        $script:OldTestFlag = $env:PRTGMOVER_TEST
    }
    AfterAll { $env:PRTGMOVER_TEST = $script:OldTestFlag }

    It 'is stored as a connection method of its own' {
        (Get-PmServer -Id $Me.id).transport | Should -Be 'local'
        Get-PmTransport (Get-PmServer -Id $Me.id) | Should -Be 'local'
    }

    It 'tests this computer without any connection and records the result as "local"' {
        $env:PRTGMOVER_TEST = '1'
        $st = Invoke-PmTestFlow -Server (Get-PmServer -Id $Me.id)
        $st.ok | Should -BeTrue
        $st.methods.local.ok | Should -BeTrue
        $st.info.Computer | Should -Be $env:COMPUTERNAME
        $saved = Get-Content (Join-Path $LocalRoot "data\status\$($Me.id).json") -Raw | ConvertFrom-Json
        $saved.lastMode | Should -Be 'local'
        $saved.methods.local.ok | Should -BeTrue
    }

    It 'fails with a clear message when PRTG Mover has no administrator rights' -Skip:([bool](New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $env:PRTGMOVER_TEST = $null
        { Invoke-PmTestFlow -Server (Get-PmServer -Id $Me.id) } | Should -Throw '*Run as administrator*'
        $saved = Get-Content (Join-Path $LocalRoot "data\status\$($Me.id).json") -Raw | ConvertFrom-Json
        $saved.ok | Should -BeFalse
    }

    It 'backs up this computer into a package without any connection' {
        $env:PRTGMOVER_TEST = '1'
        $x = Join-Path $Work 'local-extra'
        New-Item -ItemType Directory -Force -Path $x | Out-Null
        'local' | Set-Content (Join-Path $x 'l.txt')
        $job = New-PmJobObject -Type 'backup' -Summary 'local backup test'
        $r = Invoke-PmBackupFlow -Server (Get-PmServer -Id $Me.id) -Options @{ IncludePrtg = $false; IncludeVpn = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($x); NoTouch = $true } -Job $job
        Test-Path -LiteralPath $r.Zip | Should -BeTrue
        $r.Zip | Should -BeLike "$LocalRoot\backups\*"
        Test-PmStageComplete -StageDir $r.StageDir | Should -BeTrue
    }
}

Describe 'Resume' {
    BeforeAll {
        $mgr = Join-Path $Work 'manager-resume'
        New-Item -ItemType Directory -Force -Path $mgr | Out-Null
        Set-PmRoot -Path $mgr
    }

    It 'refuses to resume a job without saved parameters and resumes one that has them' {
        $old = New-PmJobObject -Type 'test' -Summary 'old'
        $old.status = 'failed'
        Save-PmJobRecord -Job $old
        { Resume-PmJob -Id $old.id } | Should -Throw '*cannot be resumed*'

        $s = Set-PmServer -Name 'R' -HostName '127.0.0.1' -RdpPort 1 -Port 2
        $j = New-PmJobObject -Type 'test' -Summary 'with params'
        $j.status = 'failed'; $j.params = @{ ServerIds = [string[]]@($s.id); Mode = 'rdp' }
        Save-PmJobRecord -Job $j
        $new = Resume-PmJob -Id $j.id
        $new.resumedFrom | Should -Be $j.id
        $new.summary | Should -BeLike 'Resume of*'
        # wait for the background job to finish
        $deadline = (Get-Date).AddSeconds(30)
        while ($new.status -in 'queued', 'running' -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
        $new.status | Should -Be 'failed'   # closed port -> the test fails, but the job ran
    }

    It 'adopts a completed staging copy from an earlier run in the resume chain' {
        # chain: C (new) -> B (no staging) -> A (complete staging)
        $a = New-PmJobObject -Type 'migrate' -Summary 'A'; $a.status = 'interrupted'; Save-PmJobRecord -Job $a
        $b = New-PmJobObject -Type 'migrate' -Summary 'B'; $b.status = 'interrupted'; $b.resumedFrom = $a.id; Save-PmJobRecord -Job $b
        $stageA = Join-Path $mgr "data\staging\$($a.id)"
        New-Item -ItemType Directory -Force -Path (Join-Path $stageA 'prtg\data') | Out-Null
        'cfg' | Set-Content (Join-Path $stageA 'prtg\data\PRTG Configuration.dat')
        @{ tool = 'prtg-mover'; source = @{ computer = 'OLDSRV' }; stagingBytes = 10; prtg = @{ included = $true } } | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $stageA 'manifest.json')
        $c = New-PmJobObject -Type 'migrate' -Summary 'C'; $c.resumedFrom = $b.id
        # without the completion marker the copy is NOT adopted (it may be partial)
        Use-PmCompletedStage -Job $c -SourceName 'OLD' | Should -BeNullOrEmpty
        Set-PmStageComplete -StageDir $stageA
        $r = Use-PmCompletedStage -Job $c -SourceName 'OLD'
        $r | Should -Not -BeNullOrEmpty
        Test-Path $r.Zip | Should -BeTrue
        $r.StageDir | Should -Be (Join-Path $mgr "data\staging\$($c.id)")
        Test-Path $stageA | Should -BeFalse
        (Read-PmBackupManifest -ZipPath $r.Zip).source.computer | Should -Be 'OLDSRV'
    }

    It 'writes an audit trail and a diagnostics bundle without secrets' {
        Test-Path (Join-Path $mgr 'data\logs\audit.log') | Should -BeTrue
        $zip = New-PmDiagnosticsBundle
        Test-Path $zip | Should -BeTrue
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::OpenRead($zip)
        try {
            @($z.Entries | Where-Object { $_.FullName -match 'cred\.xml|token\.txt' }).Count | Should -Be 0
            @($z.Entries | Where-Object { $_.FullName -eq 'environment.txt' }).Count | Should -Be 1
        } finally { $z.Dispose() }
    }
}

Describe 'Removing the PRTG license from a migrated server' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        $script:LicKey = "HKCU:\Software\PrtgMoverTest-$([guid]::NewGuid().ToString('N'))"
        $script:LicData = Join-Path $Work 'lic-data'
        $env:PRTGMOVER_WORKROOT = Join-Path $Work 'lic-workroot'
    }
    AfterAll {
        Remove-Item -LiteralPath $script:LicKey -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\PRTGMOVER_WORKROOT -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:LicKey -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path "$($script:LicKey)\Server\Core" -Force | Out-Null
        Set-ItemProperty -Path "$($script:LicKey)\Server" -Name LicenseName -Value 'demo'
        Set-ItemProperty -Path "$($script:LicKey)\Server" -Name LicenseKey -Value '000000-AAAAAA-BBBBBB'
        Set-ItemProperty -Path "$($script:LicKey)\Server" -Name LicenseHash -Value 'abc'
        Set-ItemProperty -Path "$($script:LicKey)\Server" -Name SensorCountPausedByLicenseMax -Value '3'
        Set-ItemProperty -Path "$($script:LicKey)\Server\Core" -Name SystemId -Value '{1}'
        Set-ItemProperty -Path "$($script:LicKey)\Server\Core" -Name Datapath -Value $script:LicData
        New-Item -ItemType Directory -Force -Path $script:LicData | Out-Null
        'lic' | Set-Content (Join-Path $script:LicData 'PRTG License.dat')
        'cfg' | Set-Content (Join-Path $script:LicData 'PRTG Configuration.dat')

        Mock Get-PmPrtgInfo { [pscustomobject]@{ Installed = $true; DataPath = $script:LicData; RegistryKeys = @($script:LicKey); ListenPorts = @(); CoreStatus = 'Running' } }
        Mock Get-PmLicenseValues {
            $keys = @(Get-Item -LiteralPath $script:LicKey) + @(Get-ChildItem -LiteralPath $script:LicKey -Recurse)
            foreach ($k in $keys) { foreach ($n in $k.GetValueNames()) { if ($n -match 'licen') { [pscustomobject]@{ Path = $k.PSPath; Name = $n; Kind = $k.GetValueKind($n); Value = $k.GetValue($n) } } } }
        }
        Mock Stop-PmPrtgServices { }
        Mock Invoke-PmReg { 'saved' | Set-Content -LiteralPath $File; 0 }
        Mock Invoke-PmHealthCheck { $Box.Health = [pscustomobject]@{ Healthy = $true; Url = 'https://localhost/ (HTTP 200)'; Message = '' } }
        Mock Get-PmPrtgLicenseState { [pscustomobject]@{ Known = $true; Edition = 'No License (System Changed)'; Name = 'demo'; MaxSensors = 0; NeedsActivation = $true } }
    }

    It 'removes the license values and files, keeps everything else and saves a copy first' {
        $r = @(Remove-PmPrtgLicense) | Where-Object PmType -eq 'result'
        @($r.Removed) | Should -Contain 'LicenseKey'
        @($r.Removed) | Should -Contain 'LicenseName'
        @($r.Removed) | Should -Contain 'PRTG License.dat'
        (Get-Item "$($script:LicKey)\Server").GetValueNames() | Should -BeNullOrEmpty
        (Get-ItemProperty "$($script:LicKey)\Server\Core").SystemId | Should -Be '{1}'
        (Get-ItemProperty "$($script:LicKey)\Server\Core").Datapath | Should -Be $script:LicData
        Test-Path (Join-Path $script:LicData 'PRTG License.dat') | Should -BeFalse
        Test-Path (Join-Path $script:LicData 'PRTG Configuration.dat') | Should -BeTrue
        Test-Path (Join-Path $r.Rollback 'PRTG License.dat') | Should -BeTrue
        @(Get-ChildItem $r.Rollback -Filter '*.reg').Count | Should -Be 1
        $r.Healthy | Should -BeTrue
        Should -Invoke Stop-PmPrtgServices -Times 1 -Exactly
    }

    It 'changes nothing when the copy of the license data cannot be saved' {
        Mock Invoke-PmReg { 1 }
        { Remove-PmPrtgLicense } | Should -Throw '*nothing was removed*'
        (Get-ItemProperty "$($script:LicKey)\Server").LicenseKey | Should -Be '000000-AAAAAA-BBBBBB'
        Should -Invoke Stop-PmPrtgServices -Times 0 -Exactly
    }

    It 'does nothing on a server without license data' {
        Remove-ItemProperty -Path "$($script:LicKey)\Server" -Name LicenseName, LicenseKey, LicenseHash, SensorCountPausedByLicenseMax
        Remove-Item (Join-Path $script:LicData 'PRTG License.dat')
        $r = @(Remove-PmPrtgLicense) | Where-Object PmType -eq 'result'
        @($r.Removed).Count | Should -Be 0
        Should -Invoke Stop-PmPrtgServices -Times 0 -Exactly
    }

    It 'never runs against a source server or over the RDP method' {
        $src = [pscustomobject]@{ id = 'x'; name = 'OLD'; host = '192.0.2.1'; role = 'source'; transport = 'winrm' }
        { Invoke-PmUnlicenseFlow -Server $src } | Should -Throw '*source*'
        $rdp = [pscustomobject]@{ id = 'y'; name = 'NEW'; host = '192.0.2.2'; role = 'target'; transport = 'rdp' }
        { Invoke-PmUnlicenseFlow -Server $rdp } | Should -Throw '*WinRM*'
    }
}

Describe 'Dashboard access (running dashboard)' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        $script:DashData = Join-Path $Work 'dash-data'
        New-Item -ItemType Directory -Force -Path (Join-Path $DashData 'data') | Out-Null
        'old-token-of-an-earlier-version' | Set-Content (Join-Path $DashData 'data\token.txt')
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $script:DashPort = $l.LocalEndpoint.Port; $l.Stop()
        $script:DashProc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $Root 'Start-PrtgMover.ps1'), '-Port', $DashPort, '-NoBrowser', '-Quiet', '-DataRoot', $DashData
        $script:Dash = "http://localhost:$DashPort"
        $deadline = (Get-Date).AddSeconds(40)
        $script:DashPage = $null
        while (-not $script:DashPage -and (Get-Date) -lt $deadline) {
            try { $script:DashPage = (Invoke-WebRequest "$Dash/" -UseBasicParsing -TimeoutSec 3).Content } catch { Start-Sleep -Milliseconds 500 }
        }
        $script:StatusOf = {
            param([string]$Method, [string]$Url, [hashtable]$Headers = @{}, [string]$Body)
            $req = [Net.HttpWebRequest]::Create($Url); $req.Method = $Method; $req.Timeout = 10000
            foreach ($k in $Headers.Keys) { if ($k -eq 'Content-Type') { $req.ContentType = $Headers[$k] } else { $req.Headers.Add($k, $Headers[$k]) } }
            if ($Body) { $b = [Text.Encoding]::UTF8.GetBytes($Body); $req.ContentLength = $b.Length; $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Dispose() }
            try { $r = $req.GetResponse(); $c = [int]$r.StatusCode; $r.Close(); $c } catch [Net.WebException] { if ($_.Exception.Response) { [int]$_.Exception.Response.StatusCode } else { throw } }
        }
    }
    AfterAll {
        if ($script:DashProc) { Stop-Process -Id $script:DashProc.Id -Force -ErrorAction SilentlyContinue }
    }

    It 'opens without a token and removes the token file of an earlier version' {
        $DashPage | Should -Not -BeNullOrEmpty
        $DashPage | Should -Not -Match 'pm-token'
        Test-Path (Join-Path $DashData 'data\token.txt') | Should -BeFalse
        & $StatusOf GET "$Dash/api/info" | Should -Be 200
        & $StatusOf GET "$Dash/api/servers" | Should -Be 200
    }

    It 'serves API requests without any check' {
        & $StatusOf POST "$Dash/api/servers" @{ 'Content-Type' = 'application/json'; 'Origin' = 'http://other.example' } '{"name":"T1","host":"192.0.2.10","role":"target"}' | Should -Be 200
    }

    It 'accepts this computer as a server with the connection method "local"' {
        $r = Invoke-RestMethod -Method Post -Uri "$Dash/api/servers" -ContentType 'application/json' -Body '{"name":"ME","host":"something-else","role":"both","transport":"local","username":"x","password":"y"}'
        $r.transport | Should -Be 'local'
        $r.host | Should -Be 'localhost'
        Test-Path (Join-Path $DashData "data\credentials\$($r.id).cred.xml") | Should -BeFalse
        (Invoke-RestMethod "$Dash/api/info").PSObject.Properties.Name | Should -Contain 'elevated'
    }

    It 'adds this computer with the few fields the button "Add this computer" sends, and tests it' {
        $r = Invoke-RestMethod -Method Post -Uri "$Dash/api/servers" -ContentType 'application/json' -Body '{"name":"ME2","host":"localhost","role":"both","transport":"local"}'
        $r.transport | Should -Be 'local'
        $j = Invoke-RestMethod -Method Post -Uri "$Dash/api/jobs" -ContentType 'application/json' -Body (@{ type = 'test'; mode = 'auto'; serverIds = @($r.id) } | ConvertTo-Json)
        $deadline = (Get-Date).AddSeconds(90)
        do { Start-Sleep -Seconds 1; $st = Invoke-RestMethod "$Dash/api/jobs/$($j.id)" } while ($st.status -in 'queued', 'running' -and (Get-Date) -lt $deadline)
        $st.status | Should -BeIn 'completed', 'failed'
        $text = (@($st.logs | ForEach-Object { $_ }) | ForEach-Object { $_.message }) -join "`n"
        $text | Should -Match 'Local test: (PASS|FAIL)'
        $text | Should -Match ([regex]::Escape($env:COMPUTERNAME))
    }

    It 'a second start on the same port ends without an error and leaves the dashboard running' {
        $out = Join-Path $Work 'second-start.txt'
        $second = Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $Root 'Start-PrtgMover.ps1'), '-Port', $DashPort, '-NoBrowser', '-Quiet', '-DataRoot', (Join-Path $Work 'dash-data-2')
        $null = $second.Handle   # without the handle Windows PowerShell does not report the exit code
        $second.WaitForExit(30000) | Should -BeTrue
        $second.ExitCode | Should -Be 0
        [IO.File]::ReadAllText($out) | Should -Match 'is already running'
        $DashProc.HasExited | Should -BeFalse
        & $StatusOf GET "$Dash/api/info" | Should -Be 200
    }

    It 'two starts at the same moment leave one dashboard running and no error' {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $port = $l.LocalEndpoint.Port; $l.Stop()
        $both = foreach ($n in 1, 2) {
            Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $Root 'Start-PrtgMover.ps1'), '-Port', $port, '-NoBrowser', '-Quiet', '-DataRoot', (Join-Path $Work "dash-race-$n")
        }
        try {
            $both | ForEach-Object { $null = $_.Handle }
            $deadline = (Get-Date).AddSeconds(60)
            while (@($both | Where-Object { $_.HasExited }).Count -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 300 }
            $ended = @($both | Where-Object { $_.HasExited })
            $ended.Count | Should -Be 1
            $ended[0].ExitCode | Should -Be 0
            & $StatusOf GET "http://localhost:$port/api/info" | Should -Be 200
        } finally { $both | Where-Object { -not $_.HasExited } | ForEach-Object { Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue } }
    }

    It 'refuses a port that another program uses' {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start()
        try {
            $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $Root 'Start-PrtgMover.ps1'), '-Port', $l.LocalEndpoint.Port, '-NoBrowser', '-Quiet', '-DataRoot', (Join-Path $Work 'dash-data-3')
            $null = $p.Handle
            $p.WaitForExit(30000) | Should -BeTrue
            $p.ExitCode | Should -Be 1
        } finally { $l.Stop() }
    }
}

Describe 'Manager module' {
    BeforeAll {
        $mgr = Join-Path $Work 'manager'
        New-Item -ItemType Directory -Force -Path $mgr | Out-Null
        Set-PmRoot -Path $mgr
    }

    It 'stores servers without passwords' {
        $s = Set-PmServer -Name 'OLD' -HostName '10.0.0.10' -Role source
        (Get-PmServer -Id $s.id).host | Should -Be '10.0.0.10'
        (Get-Content (Join-Path $mgr 'config\servers.json') -Raw) | Should -Not -Match 'password'
    }

    It 'updates an existing server in place' {
        $s = Set-PmServer -Name 'NEW' -HostName '10.0.0.20'
        [void](Set-PmServer -Id $s.id -Name 'NEW-RENAMED' -HostName '10.0.0.21')
        @(Get-PmServers | Where-Object id -eq $s.id).Count | Should -Be 1
        (Get-PmServer -Id $s.id).name | Should -Be 'NEW-RENAMED'
    }

    It 'round-trips a DPAPI protected credential' {
        $s = Set-PmServer -Name 'CRED' -HostName 'h'
        Save-PmCredential -ServerId $s.id -Credential (New-PmCredential -UserName 'u' -Password 'p@ss')
        Test-PmCredential -ServerId $s.id | Should -BeTrue
        (Get-PmCredential -ServerId $s.id).GetNetworkCredential().Password | Should -Be 'p@ss'
        Remove-PmServer -Id $s.id
        Test-PmCredential -ServerId $s.id | Should -BeFalse
    }

    It 'stores the RDP port (default 3389) and resolves WinRM ports' {
        $a = Set-PmServer -Name 'RDP-DEFAULT' -HostName '10.0.0.30'
        Get-PmRdpPort (Get-PmServer -Id $a.id) | Should -Be 3389
        $b = Set-PmServer -Name 'RDP-CUSTOM' -HostName '10.0.0.31' -RdpPort 33890 -UseSsl $true
        Get-PmRdpPort (Get-PmServer -Id $b.id) | Should -Be 33890
        Get-PmWinRmPort (Get-PmServer -Id $b.id) | Should -Be 5986
        Get-PmWinRmPort ([pscustomobject]@{ port = 0; useSsl = $false }) | Should -Be 5985
    }

    It 'reports a closed TCP port as unreachable' {
        Test-PmTcpPort -HostName '127.0.0.1' -Port 1 -TimeoutMs 1000 | Should -BeFalse
    }

    It 'rejects path traversal in backup names' {
        { Get-PmBackupFile -Name '..\secret.zip' } | Should -Throw
        { Get-PmBackupFile -Name 'x.txt' } | Should -Throw
    }

    It 'filters option keys when converting to a hashtable' {
        $h = ConvertTo-PmHashtable -InputObject ([pscustomobject]@{ IncludeVpn = $true; Evil = 'x'; ExtraPaths = @('a', 'b') }) -Keys 'IncludeVpn', 'ExtraPaths'
        $h.Keys.Count | Should -Be 2
        $h.ExtraPaths.GetType().Name | Should -Be 'String[]'
    }

    It 'records job logs' {
        $job = New-PmJobObject -Type 'test' -Summary 'unit'
        Add-PmJobLog -Job $job -Level OK -Message 'hello'
        $job.logs.Count | Should -Be 1
        Save-PmJobRecord -Job $job
        (Get-PmJob -Id $job.id).summary | Should -Be 'unit'
    }

    It 'forces RDP or WinRM for one job without changing the saved server' {
        $saved = [pscustomobject]@{ id = 's1'; name = 'S'; host = '10.0.0.9'; transport = 'winrm' }
        (Get-PmJobServer -Server $saved -Options @{ Transfer = 'rdp' }).transport | Should -Be 'rdp'
        $saved.transport | Should -Be 'winrm'
        (Get-PmJobServer -Server $saved -Options @{ Transfer = 'wireguard' }).transport | Should -Be 'winrm'
    }

    It 'stores WireGuard and IPIP as the server connection method' {
        $s = Set-PmServer -Name 'TUN' -HostName '10.0.0.30' -Transport wireguard
        (Get-PmServer -Id $s.id).transport | Should -Be 'wireguard'
        $wg = [pscustomobject]@{ transport = 'wireguard' }
        $ip = [pscustomobject]@{ transport = 'ipip' }
        $rdp = [pscustomobject]@{ transport = 'rdp' }
        Resolve-PmTunnelFromServers -Servers @($wg, $rdp) | Should -Be 'wireguard'
        Resolve-PmTunnelFromServers -Servers @($rdp) | Should -Be ''
        { Resolve-PmTunnelFromServers -Servers @($wg, $ip) } | Should -Throw
    }
}

Describe 'WireGuard tunnel config' {
    It 'gives the source .1 and each target the next address' {
        $one = Get-PmTunnelAddresses -TargetCount 1
        $one.Source | Should -Be '10.66.66.1'
        @($one.Targets) | Should -Be @('10.66.66.2')
        $two = Get-PmTunnelAddresses -TargetCount 2
        @($two.Targets) | Should -Be @('10.66.66.2', '10.66.66.3')
    }

    It 'builds a split tunnel and refuses a default route' {
        $text = New-PmWireGuardConfigText -PrivateKey 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa=' -Address '10.66.66.1/24' -ListenPort 51820 -Peers @(
            [pscustomobject]@{ PublicKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb='; TunnelIp = '10.66.66.2'; PublicIp = '203.0.113.8' }
        )
        $text | Should -Match 'AllowedIPs = 10.66.66.2/32'
        $text | Should -Match 'Endpoint = 203.0.113.8:51820'
        $text | Should -Match 'ListenPort = 51820'
        Test-PmTunnelConfigSafe $text | Should -BeTrue
        { New-PmWireGuardConfigText -PrivateKey 'k' -Address '10.66.66.1/24' -ListenPort 51820 -Peers @([pscustomobject]@{ PublicKey = 'p'; TunnelIp = '0.0.0.0'; PublicIp = '203.0.113.8' }) } | Should -Throw
        { New-PmWireGuardConfigText -PrivateKey 'k' -Address '0.0.0.0/0' -ListenPort 51820 -Peers @([pscustomobject]@{ PublicKey = 'p'; TunnelIp = '10.66.66.2'; PublicIp = '203.0.113.8' }) } | Should -Throw
        Test-PmTunnelConfigSafe "AllowedIPs = 0.0.0.0/0" | Should -BeFalse
    }

    It 'strips private keys before a status line can be logged' {
        $safe = Hide-PmTunnelSecret "interface: prtg`n  private key: SECRET`n  public key: OK`n"
        $safe | Should -Not -Match 'SECRET'
        $safe | Should -Match 'public key: OK'
    }

    It 'rejects WireGuard when there is no second server' {
        { Assert-PmTransferSelection -Transfer 'wireguard' -JobType 'backup' -TargetCount 0 } | Should -Throw
        { Assert-PmTransferSelection -Transfer 'wireguard' -JobType 'migrate' -TargetCount 0 } | Should -Throw
        { Assert-PmTransferSelection -Transfer 'wireguard' -JobType 'migrate' -TargetCount 1 } | Should -Not -Throw
        { Assert-PmTransferSelection -Transfer 'rdp' -JobType 'backup' -TargetCount 0 } | Should -Not -Throw
        { Assert-PmTransferSelection -Transfer 'nope' -JobType 'migrate' -TargetCount 1 } | Should -Throw
    }

    It 'only allows the tunnel file share on 10.66.66.x' {
        { Connect-PmUncShare -RemoteName '\\203.0.113.8\C$' -UserName '.\Administrator' -Password 'x' } | Should -Throw
    }

    It 'keeps IPIP on its own network and still refuses a public share' {
        $a = Get-PmTunnelAddresses -TargetCount 2 -Kind ipip
        $a.Source | Should -Be '10.66.67.1'
        $a.Network | Should -Be '10.66.67.0/24'
        @($a.Targets) | Should -Be @('10.66.67.2', '10.66.67.3')
        (Get-PmTunnelAddresses -TargetCount 1).Network | Should -Be '10.66.66.0/24'
        Test-PmIpipHost '10.66.67.2' | Should -BeTrue
        Test-PmIpipHost '10.66.66.2' | Should -BeFalse
        Test-PmTunnelShare '\\10.66.67.2\C$' | Should -BeTrue
        Test-PmTunnelShare '\\10.66.66.1\C$' | Should -BeTrue
        Test-PmTunnelShare '\\203.0.113.8\C$' | Should -BeFalse
        { Assert-PmTransferSelection -Transfer 'ipip' -JobType 'backup' -TargetCount 0 } | Should -Throw
        { Assert-PmTransferSelection -Transfer 'ipip' -JobType 'migrate' -TargetCount 1 } | Should -Not -Throw
    }

    It 'only allows WinRM to a tunnel address' {
        Test-PmTunnelPeer '10.66.66.2' | Should -BeTrue
        Test-PmTunnelPeer '10.66.67.1' | Should -BeTrue
        Test-PmTunnelPeer '203.0.113.8' | Should -BeFalse
        Test-PmTunnelPeer '0.0.0.0' | Should -BeFalse
        { Enable-PmTunnelWinRm -TunnelNetwork '0.0.0.0/0' } | Should -Throw
        { Enable-PmTunnelWinRm -TunnelNetwork '203.0.113.0/24' } | Should -Throw
        { Measure-PmTunnelWinRm -PeerTunnelIp '203.0.113.8' -UserName '.\Administrator' -Password 'x' } | Should -Throw
        { Send-PmTunnelWinRmCopy -PeerTunnelIp '10.66.66.2' -UserName '.\Administrator' -Password 'x' -Destination 'D:\data' } | Should -Throw
        { Send-PmTunnelWinRmCopy -PeerTunnelIp '203.0.113.8' -UserName '.\Administrator' -Password 'x' -Destination 'C:\PrtgMover\tunnel\job' } | Should -Throw
    }
}

Describe 'Routes of a VPN connection (format vpn-routes/1)' {
    It 'converts prefix lengths and masks' {
        ConvertTo-PmIPv4Mask 24 | Should -Be '255.255.255.0'
        ConvertTo-PmIPv4Mask 32 | Should -Be '255.255.255.255'
        ConvertTo-PmIPv4Mask 0 | Should -Be '0.0.0.0'
        ConvertTo-PmPrefixLength '255.255.255.0' | Should -Be 24
        ConvertTo-PmPrefixLength '255.255.255.255' | Should -Be 32
    }

    It 'knows whether a gateway lies inside a network' {
        Test-PmAddressInPrefix -Address '192.168.25.1' -Prefix '192.168.25.0/24' | Should -BeTrue
        Test-PmAddressInPrefix -Address '192.168.26.1' -Prefix '192.168.25.0/24' | Should -BeFalse
        Test-PmAddressInPrefix -Address '10.0.0.2' -Prefix '10.0.0.2/32' | Should -BeTrue
        Test-PmAddressInPrefix -Address 'not-an-address' -Prefix '10.0.0.0/8' | Should -BeFalse
    }

    It 'writes a backup in the shared format, also for a VPN that does not exist or is not connected' {
        $b = Get-PmVpnRouteBackup -Name 'no-such-vpn-for-the-test'
        $b.format | Should -Be 'vpn-routes/1'
        $b.vpn | Should -Be 'no-such-vpn-for-the-test'
        $b.computer | Should -Be $env:COMPUTERNAME
        $b.tunnelIp | Should -BeNullOrEmpty
        @($b.liveRoutes).Count | Should -Be 0
        $json = ConvertTo-Json -InputObject $b -Depth 5 | ConvertFrom-Json
        foreach ($k in 'format', 'computer', 'vpn', 'created', 'tunnelIp', 'connectionRoutes', 'liveRoutes', 'persistentRoutes') { $json.PSObject.Properties.Name | Should -Contain $k }
        [datetimeoffset]::Parse($json.created) | Should -Not -BeNullOrEmpty
    }

    It 'leaves routes alone that are already there and reports a connection that does not exist' {
        Mock Get-PmPersistentRoutes { @([ordered]@{ prefix = '192.168.91.0/24'; mask = '255.255.255.0'; gateway = '10.0.0.2'; metric = 1 }) }
        Mock Write-PmLog { }
        $backup = [pscustomobject]@{ vpn = 'no-such-vpn-for-the-test'; connectionRoutes = @([pscustomobject]@{ prefix = '8.8.8.8/32'; metric = 1 })
            persistentRoutes = @([pscustomobject]@{ prefix = '192.168.91.0/24'; mask = '255.255.255.0'; gateway = '10.0.0.2'; metric = 1 }) }
        $r = Restore-PmVpnRoutes -Backup $backup
        $r.kept | Should -Be 1
        $r.added | Should -Be 0
        $r.failed | Should -Be 1
    }
}

Describe 'Backups are listed as PRTG or VPN' {
    It 'tells the kind of a backup from its contents' {
        Get-PmBackupKind -Manifest ([pscustomobject]@{ prtg = [pscustomobject]@{ included = $true }; vpn = [pscustomobject]@{ included = $true } }) | Should -Be 'prtg'
        Get-PmBackupKind -Manifest ([pscustomobject]@{ prtg = [pscustomobject]@{ included = $false }; vpn = [pscustomobject]@{ included = $true } }) | Should -Be 'vpn'
        Get-PmBackupKind -Manifest ([pscustomobject]@{ prtg = [pscustomobject]@{ included = $false }; vpn = [pscustomobject]@{ included = $false } }) | Should -Be 'files'
        Get-PmBackupKind -Manifest $null -Name 'VPN_SERVER_20260101-000000.zip' | Should -Be 'vpn'
        Get-PmBackupKind -Manifest $null -Name 'PRTG_SERVER_20260101-000000.zip' | Should -Be 'prtg'
    }

    It 'makes a VPN backup of this computer with the routes of every connection' {
        $root = Join-Path $Work 'manager-vpn-backup'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Set-PmRoot -Path $root
        $me = Set-PmServer -Name 'THIS' -HostName 'localhost' -Transport local -Role both
        $old = $env:PRTGMOVER_TEST; $env:PRTGMOVER_TEST = '1'
        try {
            $job = New-PmJobObject -Type 'backup' -Summary 'vpn backup test'
            $r = Invoke-PmBackupFlow -Server (Get-PmServer -Id $me.id) -Options @{ IncludePrtg = $false; IncludeVpn = $true; IncludeDesktop = $false; NoTouch = $true } -Job $job
        } finally { $env:PRTGMOVER_TEST = $old }
        (Split-Path $r.Zip -Leaf) | Should -BeLike 'VPN_*'
        $b = @(Get-PmBackups | ForEach-Object { $_ }) | Where-Object { $_.name -eq (Split-Path $r.Zip -Leaf) }
        $b.kind | Should -Be 'vpn'
        $b.manifest.vpn.included | Should -BeTrue
        foreach ($route in @($b.manifest.vpn.routes | Where-Object { $_ })) {
            Test-Path -LiteralPath (Join-Path $r.StageDir "vpn\routes\$($route.file)") | Should -BeTrue
            (Get-Content -LiteralPath (Join-Path $r.StageDir "vpn\routes\$($route.file)") -Raw | ConvertFrom-Json).format | Should -Be 'vpn-routes/1'
        }
    }
}
