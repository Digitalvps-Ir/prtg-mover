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
        (Get-Item (Join-Path $src 'h.dat')).Attributes = 'Hidden'
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
        $script:AgentProc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $Root 'agent\PrtgMover-Agent.ps1'), '-ServerId', $AgentSrv.id, '-AllowNonAdmin'
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
}
