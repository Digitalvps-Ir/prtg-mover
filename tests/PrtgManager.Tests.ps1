#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Run: Invoke-Pester -Path .\tests -Output Detailed

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $Root 'src\Remote\PrtgManager.Remote.ps1')
    Import-Module (Join-Path $Root 'src\PrtgManager.psm1') -Force -DisableNameChecking
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("pm-tests-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Work | Out-Null
    # data (config, backups, jobs, logs, audit) of the tests lives in the test folder, never in the real manager folder
    New-Item -ItemType Directory -Path (Join-Path $Work 'manager') | Out-Null
    Set-PmRoot -Path (Join-Path $Work 'manager')
}

AfterAll {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
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

        $out = @(Invoke-PmRemoteBackup -JobId 'rt1' -WorkRoot $wr -IncludePrtg $false -IncludeDesktop $false -ExtraPaths @($extra))
        $res = $out | Where-Object PmType -eq 'result'
        $res | Should -Not -BeNullOrEmpty
        Test-Path $res.ZipPath | Should -BeTrue
        $res.Sha256 | Should -Be (Get-FileHash $res.ZipPath -Algorithm SHA256).Hash

        $manifest = Read-PmBackupManifest -ZipPath $res.ZipPath
        $manifest.tool | Should -Be 'prtg-manager'
        $manifest.formatVersion | Should -Be 2
        @($manifest.extra).Count | Should -Be 1

        Remove-Item $extra -Recurse -Force
        $out2 = @(Invoke-PmRemoteRestore -JobId 'rt2' -ZipPath $res.ZipPath -WorkRoot $wr -RestorePrtg $false -RestoreDesktop $false -RemovePackage $true)
        ($out2 | Where-Object PmType -eq 'result').Report.Extra | Should -Be 'ok'
        Get-Content (Join-Path $extra 'sub\a.txt') | Should -Be 'hello'
        Test-Path $res.ZipPath | Should -BeFalse
    }

    It 'rejects a package whose checksum does not match' {
        $wr = Join-Path $Work 'wr-bad'
        $out = @(Invoke-PmRemoteBackup -JobId 'rt4' -WorkRoot $wr -IncludePrtg $false -IncludeDesktop $false)
        $zip = ($out | Where-Object PmType -eq 'result').ZipPath
        { Invoke-PmRemoteRestore -JobId 'rt5' -ZipPath $zip -WorkRoot $wr -ExpectedSha256 'BAD' } | Should -Throw '*checksum mismatch*'
    }

    It 'pull mode stages only small items on the source and lists the big folders for the manager' {
        $wr = Join-Path $Work 'wr-pull'
        $x = Join-Path $Work 'pull-extra'
        New-Item -ItemType Directory -Force -Path (Join-Path $x 'Logs'), (Join-Path $x 'keep') | Out-Null
        'a' | Set-Content (Join-Path $x 'keep\a.txt'); 'b' | Set-Content (Join-Path $x 'Logs\b.log'); 'c' | Set-Content (Join-Path $x 'cache.tmp')
        $out = @(Invoke-PmRemoteBackup -JobId 'pull1' -WorkRoot $wr -IncludePrtg $false -IncludeDesktop $false -PullMode $true)
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
        $out = @(Invoke-PmRemoteBackup -JobId 'mv1' -WorkRoot $wr -IncludePrtg $false -IncludeDesktop $false -ExtraPaths @($x) -PullMode $true)
        $stage = ($out | Where-Object PmType -eq 'result').StageDir
        Remove-Item $x -Recurse -Force
        $r = @(Invoke-PmRemoteRestore -JobId 'mv2' -StageDir $stage -WorkRoot $wr -RestorePrtg $false -RestoreDesktop $false -MoveFromStage $true -CleanupStage $true) | Where-Object PmType -eq 'result'
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
        $out = @(Invoke-PmRemoteBackup -JobId 'rt3' -WorkRoot (Join-Path $Work 'wr3') -IncludePrtg $false -IncludeDesktop $false)
        @($out | Where-Object { $_.PmType -notin 'log', 'progress', 'result' }).Count | Should -Be 0
    }
}

Describe 'Full restore into a server where PRTG is already installed (simulated installation)' {
    BeforeAll {
        # a "PRTG" that is installed in a test folder: its services, registry, firewall and health check are mocked
        function New-InstalledCase([string]$Name) {
            $root = Join-Path $Work "installed-$Name"
            $tgt = Join-Path $root 'target-data'
            New-Item -ItemType Directory -Force -Path (Join-Path $tgt 'Monitoring Database'), (Join-Path $root 'stage\prtg\data'), (Join-Path $root 'wr') | Out-Null
            'OLD CONFIG' | Set-Content (Join-Path $tgt 'PRTG Configuration.dat')
            'old history' | Set-Content (Join-Path $tgt 'Monitoring Database\old.dat')
            $cfg = Join-Path $root 'stage\prtg\data\PRTG Configuration.dat'
            'NEW CONFIG FROM THE SOURCE' | Set-Content $cfg
            $man = [ordered]@{ type = 'full'; createdUtc = '2026-10-01T00:00:00Z'; stagingBytes = 1024; source = @{ computer = 'SRC' }
                prtg = [ordered]@{ included = $true; version = '25.4.114.1032'; dataPath = (Join-Path $root 'source-data-path'); configSha256 = (Get-FileHash $cfg -Algorithm SHA256).Hash; registryFiles = @(); programFolders = @(); listenPorts = @(443); programCloned = $true; licenseValueNames = @() } }
            ConvertTo-Json $man -Depth 5 | Set-Content (Join-Path $root 'stage\manifest.json')
            [pscustomobject]@{ Root = $root; Target = $tgt; Stage = (Join-Path $root 'stage'); WorkRoot = (Join-Path $root 'wr'); SourcePath = (Join-Path $root 'source-data-path') }
        }
        function Register-InstalledMocks([string]$TargetData) {
            $script:InstTarget = $TargetData
            Mock Get-PmPrtgInfo { [pscustomobject]@{ Installed = $true; Version = '25.4.114.1032'; DataPath = $script:InstTarget; ProgramPath = (Join-Path $Work 'no-program'); RegistryKeys = @(); ListenPorts = @(443); ListenEndpoints = @('10.0.0.5:443') } }
            Mock Stop-PmPrtgServices { }
            Mock Invoke-PmReg { 0 }
            Mock Set-PmPrtgWebBinding { }
            Mock Set-PmPrtgFirewall { @(443) }
            Mock Get-PmLicenseValues { @() }
            Mock Get-PmPrtgLicenseState { [pscustomobject]@{ Known = $false } }
            Mock New-Service { throw 'nothing may be installed: PRTG is installed already' }
        }
    }

    It 'installs nothing, restores into the installed PRTG data folder (not the source path) and keeps the old one for the rollback' {
        $c = New-InstalledCase 'ok'
        Register-InstalledMocks $c.Target
        Mock Invoke-PmHealthCheck { $Box.Health = [pscustomobject]@{ Healthy = $true; Url = 'https://10.0.0.5/'; Version = '25.4.114.1032'; Core = 'Running'; Probe = 'Running'; Message = '' } }
        $out = @(Invoke-PmRemoteRestore -JobId 'inst1' -StageDir $c.Stage -WorkRoot $c.WorkRoot -RestoreDesktop $false -RestoreExtra $false -CopyLicense $false)
        $r = ($out | Where-Object PmType -eq 'result').Report
        $r.Prtg | Should -Be 'ok'
        @($r.Errors).Count | Should -Be 0
        Get-Content (Join-Path $c.Target 'PRTG Configuration.dat') | Should -Be 'NEW CONFIG FROM THE SOURCE'
        Test-Path $c.SourcePath | Should -BeFalse -Because 'PRTG is installed here: its own data folder is used, not the source path'
        $kept = @(Get-ChildItem $c.Root -Directory | Where-Object Name -like 'target-data.pre-restore-*')
        $kept.Count | Should -Be 1
        Get-Content (Join-Path $kept[0].FullName 'PRTG Configuration.dat') | Should -Be 'OLD CONFIG'
        Should -Invoke New-Service -Times 0 -Exactly
        @($out | Where-Object { $_.PmType -eq 'log' -and $_.Message -like '*already installed here - nothing is installed*' }).Count | Should -Be 1
    }

    It 'puts the previous data back when the restored PRTG does not come up' {
        $c = New-InstalledCase 'rollback'
        Register-InstalledMocks $c.Target
        $script:HealthCalls = 0
        Mock Invoke-PmHealthCheck { $script:HealthCalls++; $Box.Health = [pscustomobject]@{ Healthy = ($script:HealthCalls -gt 1); Url = 'https://10.0.0.5/'; Version = '25.4.114.1032'; Core = 'Running'; Probe = 'Running'; Message = 'web interface does not answer' } }
        $out = @(Invoke-PmRemoteRestore -JobId 'inst2' -StageDir $c.Stage -WorkRoot $c.WorkRoot -RestoreDesktop $false -RestoreExtra $false -CopyLicense $false -AutoRollback $true)
        $r = ($out | Where-Object PmType -eq 'result').Report
        $r.RolledBack | Should -BeTrue
        $r.Prtg | Should -Be 'rolled-back'
        Get-Content (Join-Path $c.Target 'PRTG Configuration.dat') | Should -Be 'OLD CONFIG'
        Test-Path (Join-Path $c.Target 'Monitoring Database\old.dat') | Should -BeTrue
        @(Get-ChildItem $c.Root -Directory | Where-Object Name -like 'target-data.failed-restore-*').Count | Should -Be 1   # the restored data is kept, not deleted
    }

    It 'the preview says nothing is installed, names the data folder and warns when the space is tight' {
        $man = [pscustomobject]@{ stagingBytes = 10GB; prtg = [pscustomobject]@{ version = '25.4.114.1032'; programCloned = $true; configStats = 'devices=27'; dataPath = 'D:\PRTG Data'; programFolders = @() } }
        $facts = [pscustomobject]@{ Computer = 'NEW'; IsAdmin = $true; ConfigStats = 'devices=20'; DataBytes = 5GB; FreeBytes = 15GB; NetRelease = 0; License = $null
            Prtg = [pscustomobject]@{ Installed = $true; Version = '25.4.114.1032'; DataPath = 'C:\ProgramData\Paessler\PRTG Network Monitor' } }
        $p = Get-PmFullRestorePreview -Manifest $man -Facts $facts
        @($p.Blockers).Count | Should -Be 0
        ($p.Items | Where-Object Item -eq 'PRTG program').Detail | Should -Match 'already installed - it is kept, nothing is installed'
        ($p.Items | Where-Object Item -eq 'PRTG data folder').Detail | Should -Match ([regex]::Escape('C:\ProgramData\Paessler\PRTG Network Monitor gets the restored data'))
        ($p.Items | Where-Object Item -eq 'PRTG data folder').Detail | Should -Match ([regex]::Escape('the source used D:\PRTG Data'))
        @($p.Warnings | Where-Object { $_ -like 'Free space on the target is tight*' }).Count | Should -Be 1
        $facts.FreeBytes = 11GB
        @((Get-PmFullRestorePreview -Manifest $man -Facts $facts).Blockers | Where-Object { $_ -like 'Not enough free space*' }).Count | Should -Be 1
    }
}

Describe 'RDP agent transport (end to end, local)' {
    BeforeAll {
        $env:PRTGMOVER_TEST = '1'
        # The agent resolves the manager folder from its own location. It runs from a copy of the program in the
        # test folder, so the test never adds a server to, or writes packages / logs into, the real manager folder.
        $script:AgentRoot = Join-Path $Work 'agent-manager'
        New-Item -ItemType Directory -Force -Path $AgentRoot | Out-Null
        foreach ($part in 'src', 'agent', 'VERSION') { Copy-Item -LiteralPath (Join-Path $Root $part) -Destination $AgentRoot -Recurse -Force }
        $env:PRTGMOVER_TSCLIENT_ROOT = $AgentRoot   # the local "agent" reaches the manager folder directly, not via \\tsclient
        Set-PmRoot -Path $AgentRoot
        $script:AgentSrv = Set-PmServer -Name 'PESTER-AGENT' -HostName '127.0.0.1' -Transport rdp
        $agentStart = @{
            FilePath = (Get-Process -Id $PID).Path
            PassThru = $true
            ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $AgentRoot 'agent\PrtgManager-Agent.ps1'), '-ServerId', $script:AgentSrv.id, '-AllowNonAdmin')
        }
        # -WindowStyle is Windows PowerShell 5.1 only. PowerShell 7 rejects the parameter.
        if ($PSVersionTable.PSEdition -eq 'Desktop') { $agentStart.WindowStyle = 'Hidden' }
        $script:AgentProc = Start-Process @agentStart
    }
    AfterAll {
        if ($script:AgentProc) { Stop-Process -Id $AgentProc.Id -Force -ErrorAction SilentlyContinue }
        Remove-PmServer -Id $AgentSrv.id
        Remove-Item -LiteralPath (Join-Path $AgentRoot "data\agent\$($AgentSrv.id)") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\PRTGMOVER_TEST, Env:\PRTGMOVER_TSCLIENT_ROOT -ErrorAction SilentlyContinue
    }

    It 'backs up through the agent, stores the package on the manager and restores it' {
        $src = Join-Path $Work 'agent-extra'
        New-Item -ItemType Directory -Force -Path $src | Out-Null
        'via-agent' | Set-Content (Join-Path $src 'f.txt')
        $job = New-PmJobObject -Type 'backup' -Summary 'pester'
        $bk = Invoke-PmBackupFlow -Server $AgentSrv -Options @{ IncludePrtg = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($src); NoTouch = $true } -Job $job
        $file = $bk.Zip
        try {
            Test-Path -LiteralPath $file | Should -BeTrue
            # RDP mode stages directly on the manager
            Test-Path -LiteralPath (Join-Path $bk.StageDir 'manifest.json') | Should -BeTrue
            Remove-Item -LiteralPath $src -Recurse -Force
            $rep = Invoke-PmRestoreFlow -Server $AgentSrv -BackupPath $file -StageDir $bk.StageDir -Options @{ RestorePrtg = $false; RestoreDesktop = $false } -Job $job
            $rep.Extra | Should -Be 'ok'
            Get-Content (Join-Path $src 'f.txt') | Should -Be 'via-agent'
            @($job.logs | Where-Object { $_.message -like '*direct staging on the manager*' }).Count | Should -BeGreaterThan 0
            Test-Path -LiteralPath (Join-Path $AgentRoot "data\agent\$($AgentSrv.id)\agent.log") | Should -BeTrue
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
        $bk = Invoke-PmBackupFlow -Server $AgentSrv -Options @{ IncludePrtg = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($src) } -Job $job
        Remove-Item -LiteralPath $bk.StageDir -Recurse -Force
        Remove-Item -LiteralPath $src -Recurse -Force
        try {
            $rep = Invoke-PmRestoreFlow -Server $AgentSrv -BackupPath $bk.Zip -Options @{ RestorePrtg = $false; RestoreDesktop = $false } -Job $job
            $rep.Extra | Should -Be 'ok'
            Get-Content (Join-Path $src 'g.txt') | Should -Be 'from-zip'
        } finally {
            Remove-PmBackup -Name (Split-Path $bk.Zip -Leaf)
            Remove-Item -LiteralPath (Join-Path $AgentRoot ("data\staging\restore-" + [IO.Path]::GetFileNameWithoutExtension($bk.Zip))) -Recurse -Force -ErrorAction SilentlyContinue
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
        $opt = @{ IncludePrtg = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($x); NoTouch = $true }
        $bk = Invoke-PmBackupFlow -Server $Local -Options $opt -Job $job
        Test-Path $bk.Zip | Should -BeTrue
        Test-PmStageComplete -StageDir $bk.StageDir | Should -BeTrue
        Remove-Item $x -Recurse -Force
        $rep = Invoke-PmRestoreFlow -Server $Local -BackupPath $bk.Zip -StageDir $bk.StageDir -Options @{ RestorePrtg = $false; RestoreDesktop = $false } -Job $job
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

Describe 'Connection method "local": PRTG Manager on the server itself' {
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

    It 'fails with a clear message when PRTG Manager has no administrator rights' -Skip:([bool](New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
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
        $r = Invoke-PmBackupFlow -Server (Get-PmServer -Id $Me.id) -Options @{ IncludePrtg = $false; IncludeDesktop = $false; ExtraPaths = [string[]]@($x); NoTouch = $true } -Job $job
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
        @((Get-Item "$($script:LicKey)\Server").GetValueNames()) | Should -Be @('SensorCountPausedByLicenseMax') -Because "PRTG's own bookkeeping is not part of the license"
        @($r.Removed) | Should -Not -Contain 'SensorCountPausedByLicenseMax'
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
            (Join-Path $Root 'Start-PrtgManager.ps1'), '-Port', $DashPort, '-NoBrowser', '-Quiet', '-DataRoot', $DashData
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
        # with administrator rights the test of this computer succeeds, without them it fails with a clear message
        $st.status | Should -BeIn 'succeeded', 'failed'
        $text = (@($st.logs | ForEach-Object { $_ }) | ForEach-Object { $_.message }) -join "`n"
        $text | Should -Match 'Local test: (PASS|FAIL)'
        $text | Should -Match ([regex]::Escape($env:COMPUTERNAME))
    }

    It 'a second start on the same port ends without an error and leaves the dashboard running' {
        $out = Join-Path $Work 'second-start.txt'
        $second = Start-Process powershell -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            (Join-Path $Root 'Start-PrtgManager.ps1'), '-Port', $DashPort, '-NoBrowser', '-Quiet', '-DataRoot', (Join-Path $Work 'dash-data-2')
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
                (Join-Path $Root 'Start-PrtgManager.ps1'), '-Port', $port, '-NoBrowser', '-Quiet', '-DataRoot', (Join-Path $Work "dash-race-$n")
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
                (Join-Path $Root 'Start-PrtgManager.ps1'), '-Port', $l.LocalEndpoint.Port, '-NoBrowser', '-Quiet', '-DataRoot', (Join-Path $Work 'dash-data-3')
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

Describe 'Credentials of the manager' {
    It 'reads a credential of another Windows account as a clear error, not as a missing password' {
        $root = Join-Path $Work 'manager-foreign-credential'
        New-Item -ItemType Directory -Force -Path $root | Out-Null
        Set-PmRoot -Path $root
        $srv = Set-PmServer -Name 'REMOTE' -HostName '192.0.2.20' -Transport winrm
        # a credential file whose protected part this account cannot decrypt
        $good = Join-Path $root 'good.xml'
        (New-PmCredential -UserName 'u' -Password 'p') | Export-Clixml -LiteralPath $good
        $xml = [IO.File]::ReadAllText($good) -replace '(<SS N="Password">)[0-9a-f]{40}', '${1}0000000000000000000000000000000000000000'
        [IO.File]::WriteAllText((Join-Path (Get-PmPath Credentials) "$($srv.id).cred.xml"), $xml)
        { Get-PmCredential -ServerId $srv.id } | Should -Throw '*another Windows account*'
    }
}

Describe 'Backup password encryption' {
    It 'round-trips bytes and says clearly when the password is wrong or the data was changed' {
        $data = [Text.Encoding]::UTF8.GetBytes('license key and friends ' * 20)
        $env1 = Protect-PmBytes -Data $data -Password 'correct horse'
        [Text.Encoding]::ASCII.GetString($env1, 0, 6) | Should -Be 'PMENC1'
        [Text.Encoding]::UTF8.GetString((Unprotect-PmBytes -Envelope $env1 -Password 'correct horse')) | Should -Be ([Text.Encoding]::UTF8.GetString($data))
        { Unprotect-PmBytes -Envelope $env1 -Password 'wrong password' } | Should -Throw '*password is wrong or the file was changed*'
        $env1[50] = $env1[50] -bxor 1
        { Unprotect-PmBytes -Envelope $env1 -Password 'correct horse' } | Should -Throw '*HMAC mismatch*'
    }
    It 'refuses a password shorter than 8 characters' {
        { Protect-PmBytes -Data ([byte[]](1, 2, 3)) -Password 'short' } | Should -Throw '*at least 8 characters*'
    }
    It 'encrypts and decrypts files of any size and writes nothing with a wrong password' {
        $f = Join-Path $Work 'enc.bin'; $b = New-Object byte[] (2MB + 77); (New-Object Random 7).NextBytes($b); [IO.File]::WriteAllBytes($f, $b)
        Protect-PmFile -Source $f -Destination "$f.pmenc" -Password 'correct horse'
        [void](Test-PmEncryptedFile -Path "$f.pmenc" -Password 'correct horse')
        Unprotect-PmFile -Source "$f.pmenc" -Destination "$f.out" -Password 'correct horse'
        (Get-FileHash "$f.out").Hash | Should -Be (Get-FileHash $f).Hash
        { Unprotect-PmFile -Source "$f.pmenc" -Destination "$f.bad" -Password 'wrong password' } | Should -Throw '*HMAC mismatch*'
        Test-Path "$f.bad" | Should -BeFalse
    }
    It 'packs large XML into a small object for WinRM and back' {
        $x = '<a>' + ('<b id="1">text</b>' * 5000) + '</a>'
        $p = ConvertTo-PmPackedText $x
        $p.Length | Should -BeLessThan ($x.Length / 10)
        ConvertFrom-PmPackedText $p | Should -Be $x
    }
}

Describe 'PRTG configuration parts (devices, notifications, triggers)' {
    BeforeAll {
        $script:CfgXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<root version="30" oct="PRTG Network Monitor 25.4.114.1032 x64" max="700" guid="{11111111-2222-3333-4444-555555555555}">
  <basenode id="-99"><data><name>root</name></data><nodes>
    <group id="0"><data><name>Root</name></data><trigger><state id="1"><data><onnotificationid>300</onnotificationid><latency>60</latency></data></state></trigger><nodes>
      <probenode id="1"><data><name>Local Probe</name></data><nodes>
        <group id="10"><data><name>Servers</name></data><nodes>
          <device id="40"><data><name>Web</name><schedule>-1</schedule><dependency></dependency><interval>60</interval><windowsloginpassword><flags/><cell crypt="PRTGv2">AAAAencrypted1111</cell></windowsloginpassword></data><nodes>
            <sensor id="41"><data><name>Ping</name></data><channels><channel id="0"/></channels><trigger><threshold id="1"><data><onnotificationid>301</onnotificationid></data></threshold></trigger></sensor>
            <sensor id="42"><data><name>HTTP</name><dependency>41</dependency></data></sensor>
          </nodes></device>
          <device id="50"><data><name>DB</name><dependency>41</dependency></data><nodes><sensor id="51"><data><name>Ping</name></data></sensor></nodes></device>
        </nodes></group>
      </nodes></probenode>
    </nodes></group>
    <basenode id="-3"><data><name>Notifications</name></data><nodes>
      <notification id="300"><data><name>Mail admin</name><schedule>600</schedule></data><notifies><email id="0"/></notifies></notification>
      <notification id="301"><data><name>Push</name><schedule>-1</schedule></data></notification>
    </nodes></basenode>
    <basenode id="-7"><data><name>Schedules</name></data><nodes><schedule id="600"><data><name>Weekdays</name></data></schedule></nodes></basenode>
  </nodes></basenode>
</root>
'@
        $script:NewTarget = { Read-PmXmlText $script:CfgXml }
        $script:Part = { param([string]$Type) Read-PmXmlText (ConvertTo-PmXmlText (Export-PmConfigSection -Doc (& $script:NewTarget) -Type $Type)) }
        $script:Drop = { param($Doc, [string]$XPath) $n = $Doc.SelectSingleNode($XPath); [void]$n.ParentNode.RemoveChild($n) }
        $script:DupIds = { param($Doc) $seen = @{}; $d = 0; foreach ($e in $Doc.SelectNodes('//nodes/*[@id]')) { $i = $e.GetAttribute('id'); if ($seen.ContainsKey($i)) { $d++ } else { $seen[$i] = 1 } }; $d }
    }

    It 'exports each part with its counts, format and PRTG version' {
        $d = Get-PmSectionSummary (& $Part 'devices')
        $d.probenode | Should -Be 1; $d.group | Should -Be 2; $d.device | Should -Be 2; $d.sensor | Should -Be 3; $d.triggers | Should -Be 2
        $d.prtgVersion | Should -Be '25.4.114.1032'; $d.configVersion | Should -Be '30'
        $n = Get-PmSectionSummary (& $Part 'notifications'); $n.notifications | Should -Be 2; $n.schedules | Should -Be 1
        $t = Get-PmSectionSummary (& $Part 'triggers'); $t.objects | Should -Be 2; $t.triggers | Should -Be 2; $t.kinds | Should -Be 'state=1, threshold=1'
    }

    It 'plans nothing for a target that already has everything' {
        foreach ($type in 'devices', 'notifications', 'triggers') {
            $p = Get-PmSectionRestorePlan -Target (& $NewTarget) -Section (& $Part $type)
            $p.Counts.create + $p.Counts.update + $p.Counts.conflict | Should -Be 0
            @($p.Blockers).Count | Should -Be 0
        }
    }

    It 'creates a missing device with its sensors under the same group and the same ids' {
        $t = & $NewTarget; & $Drop $t "//device[@id='40']"
        $p = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices')
        $p.Counts.create | Should -Be 3
        @($p.MissingDependencies).Count | Should -Be 0   # 42 and 50 depend on 41, which this restore creates
        $r = Invoke-PmSectionMerge -Target $t -Section (& $Part 'devices') -Plan $p
        $r.Counts.created | Should -Be 3
        $dev = $t.SelectSingleNode("//group[@id='10']/nodes/device[@id='40']")
        $dev | Should -Not -BeNullOrEmpty
        @($dev.SelectNodes('nodes/sensor')).Count | Should -Be 2
        (Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices')).Counts.create | Should -Be 0
    }

    It 'reports a dependency that is neither on the target nor in the backup' {
        $sec = & $Part 'devices'
        $sec.SelectSingleNode("//device[@id='50']/data/dependency").InnerText = '999'
        $t = & $NewTarget; & $Drop $t "//device[@id='50']"
        $p = Get-PmSectionRestorePlan -Target $t -Section $sec
        @($p.MissingDependencies) -join ' ' | Should -Match 'Object 999'
    }

    It 'treats an id used by another object as a conflict, and re-ids the object with its children on request' {
        $t = & $NewTarget
        $t.SelectSingleNode("//device[@id='40']/data/name").InnerText = 'Something else'
        $p = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices') -Mode merge
        $p.Counts.conflict | Should -Be 1
        (@($p.Items | Where-Object { $_.Id -eq 41 })[0]).Action | Should -Be 'skip'
        $p2 = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices') -Mode merge -ReIdConflicts $true
        @($p2.Items | Where-Object Action -eq 'create-new-id').Count | Should -Be 3
        $r = Invoke-PmSectionMerge -Target $t -Section (& $Part 'devices') -Plan $p2
        $r.Counts.reIded | Should -Be 3
        & $DupIds $t | Should -Be 0
        [int]$t.DocumentElement.GetAttribute('max') | Should -Be 703
        # the dependency inside the moved subtree follows the new ids
        $new41 = $r.IdMap[41]; $new42 = $r.IdMap[42]
        $t.SelectSingleNode("//sensor[@id='$new42']/data/dependency").InnerText | Should -Be ([string]$new41)
    }

    It 'keeps existing objects in merge mode and updates their settings in overwrite mode' {
        $t = & $NewTarget
        $t.SelectSingleNode("//device[@id='40']/data/interval").InnerText = '300'
        (Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices') -Mode merge).Counts.update | Should -Be 0
        $p = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices') -Mode overwrite
        $p.Counts.update | Should -Be 1
        [void](Invoke-PmSectionMerge -Target $t -Section (& $Part 'devices') -Plan $p)
        $t.SelectSingleNode("//device[@id='40']/data/interval").InnerText | Should -Be '60'
        @($t.SelectNodes("//device[@id='40']/nodes/sensor")).Count | Should -Be 2
    }

    It 'does not count values PRTG re-encrypted on a save as a change' {
        $t = & $NewTarget
        $t.SelectSingleNode("//device[@id='40']/data/windowsloginpassword/cell").InnerText = 'BBBBreencrypted222'
        # a timestamp PRTG keeps up to date by itself is no setting either
        $ts = $t.CreateElement('location_last_updated'); $ts.InnerText = '46294.5'; [void]$t.SelectSingleNode("//device[@id='40']/data").AppendChild($ts)
        (Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices') -Mode overwrite).Counts.update | Should -Be 0
    }

    It 'warns that encrypted values may not be readable when the backup comes from another PRTG installation' {
        $t = & $NewTarget; $t.DocumentElement.SetAttribute('guid', '{99999999-0000-0000-0000-000000000000}')
        $p = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'devices')
        (@($p.Warnings) -join ' ') | Should -Match 'another PRTG installation'
        @((Get-PmSectionRestorePlan -Target (& $NewTarget) -Section (& $Part 'devices')).Warnings).Count | Should -Be 0
    }

    It 'blocks a backup made with a newer configuration format' {
        $sec = & $Part 'devices'; $sec.DocumentElement.SetAttribute('configversion', '31')
        $p = Get-PmSectionRestorePlan -Target (& $NewTarget) -Section $sec
        @($p.Blockers).Count | Should -Be 1
        $p.Blockers[0] | Should -Match 'newer PRTG'
    }

    It 'restores a notification together with the schedule it uses' {
        $t = & $NewTarget; & $Drop $t "//notification[@id='300']"; & $Drop $t "//schedule[@id='600']"
        $p = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'notifications')
        @($p.Items | Where-Object Action -eq 'create' | ForEach-Object { "$($_.Type) $($_.Id)" }) | Sort-Object | Should -Be @('notification 300', 'schedule 600')
        [void](Invoke-PmSectionMerge -Target $t -Section (& $Part 'notifications') -Plan $p)
        $t.SelectSingleNode("//basenode[@id='-3']/nodes/notification[@id='300']") | Should -Not -BeNullOrEmpty
        $t.SelectSingleNode("//basenode[@id='-7']/nodes/schedule[@id='600']") | Should -Not -BeNullOrEmpty
    }

    It 'adds missing triggers, treats a changed one as a conflict in merge and updates it in overwrite' {
        $t = & $NewTarget; & $Drop $t "//sensor[@id='41']/trigger/threshold"
        $t.SelectSingleNode("//group[@id='0']/trigger/state/data/latency").InnerText = '999'
        $p = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'triggers') -Mode merge
        $p.Counts.create | Should -Be 1; $p.Counts.conflict | Should -Be 1
        $p2 = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'triggers') -Mode overwrite
        [void](Invoke-PmSectionMerge -Target $t -Section (& $Part 'triggers') -Plan $p2)
        $t.SelectSingleNode("//sensor[@id='41']/trigger/threshold") | Should -Not -BeNullOrEmpty
        $t.SelectSingleNode("//group[@id='0']/trigger/state/data/latency").InnerText | Should -Be '60'
    }

    It 'names a notification a restored trigger needs when the target does not have it' {
        $t = & $NewTarget; & $Drop $t "//notification[@id='301']"; & $Drop $t "//sensor[@id='41']/trigger/threshold"
        $p = Get-PmSectionRestorePlan -Target $t -Section (& $Part 'triggers')
        @($p.MissingDependencies) -join ' ' | Should -Match 'Notification template 301'
    }

    It 'writes the configuration with its byte order mark, via a file that must parse' {
        $f = Join-Path $Work 'PRTG Configuration.dat'
        [IO.File]::WriteAllText($f, $CfgXml, (New-Object Text.UTF8Encoding($true)))
        $d = Read-PmPrtgConfig -Path $f
        $d.SelectSingleNode("//device[@id='40']/data/name").InnerText = 'Web 2'
        Save-PmPrtgConfig -Doc $d -Path $f
        ([IO.File]::ReadAllBytes($f))[0..2] | Should -Be @(0xEF, 0xBB, 0xBF)
        (Read-PmPrtgConfig -Path $f).SelectSingleNode("//device[@id='40']/data/name").InnerText | Should -Be 'Web 2'
        Test-Path "$f.pm-new" | Should -BeFalse
    }
}

Describe 'History (graph data)' {
    It 'lists history files by day and device and leaves out old days on request' {
        $root = Join-Path $Work 'mdb'
        $today = (Get-Date).ToString('yyyyMMdd')
        foreach ($d in '20000101', $today) { New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null; 'x' | Set-Content (Join-Path $root "$d\Device 40.prd"); 'y' | Set-Content (Join-Path $root "$d\Device 99.prd") }
        @(Get-PmGraphFiles -Root $root).Count | Should -Be 4
        $recent = @(Get-PmGraphFiles -Root $root -Days 7)
        $recent.Count | Should -Be 2
        @($recent | ForEach-Object { $_.Device } | Sort-Object) | Should -Be @(40, 99)
        @(Get-PmGraphDayFolders -Root $root -Days 7) | Should -Be @((Join-Path $root '20000101'))
    }
    It 'plans new and existing files and warns about devices the target does not have' {
        $files = @([pscustomobject]@{ Rel = '20260101\Device 40.prd'; Device = 40; Size = 10 }, [pscustomobject]@{ Rel = '20260101\Device 99.prd'; Device = 99; Size = 20 })
        $m = Get-PmGraphRestorePlan -Files $files -TargetFiles @('20260101\device 40.prd') -TargetDevices @(40) -Mode merge
        $m.New | Should -Be 1; $m.Existing | Should -Be 1; $m.Keep | Should -Be 1; $m.Replace | Should -Be 0; $m.NewBytes | Should -Be 20
        @($m.UnknownDevices) | Should -Be @(99)
        $m.Warnings[0] | Should -Match 'not in the target configuration'
        (Get-PmGraphRestorePlan -Files $files -TargetFiles @('20260101\Device 40.prd') -TargetDevices @(40, 99) -Mode overwrite).Replace | Should -Be 1
    }
}

Describe 'Backup catalogue (types, versions, encryption, validation)' {
    BeforeAll {
        $script:Cat = Join-Path $Work 'catalogue'
        New-Item -ItemType Directory -Force -Path $Cat | Out-Null
        Set-PmRoot -Path $Cat
        $script:NewPart = {
            param([string]$Type = 'devices', [string]$Password)
            $m = New-PmManifestV2 -Type $Type -Computer 'SRC1' -Os 'Windows Server' -Server 'Prtg-Old' -PrtgVersion '25.4.114.1032' -JobId 'test'
            $m.sections = @($Type); $m.counts = [ordered]@{ device = 2; sensor = 3 }
            $zip = Join-Path (Get-PmPath Backups) ("PRTG-{0}_SRC1_{1}.zip" -f $Type.ToUpperInvariant(), [guid]::NewGuid().ToString('N').Substring(0, 8))
            New-PmZipFromFiles -ZipPath $zip -Manifest $m -Files @{ "$Type.xml" = [Text.Encoding]::UTF8.GetBytes('<prtgmanagersection type="devices" configversion="30" prtgversion="25.4.114.1032"><tree/></prtgmanagersection>') }
            Complete-PmPackage -ZipPath $zip -Manifest $m -Source 'Prtg-Old' -Password $Password
        }
    }

    It 'lists a part package with its type, format version, versions and checksum, and validates it' {
        $f = & $NewPart 'devices'
        $b = @(Get-PmBackups) | Where-Object { $_.name -eq (Split-Path $f -Leaf) }
        $b.type | Should -Be 'devices'; $b.formatVersion | Should -Be 2; $b.prtgVersion | Should -Be '25.4.114.1032'; $b.encrypted | Should -BeFalse
        $b.sha256 | Should -Be (Get-FileHash $f).Hash
        $v = Test-PmBackupPackage -Name (Split-Path $f -Leaf)
        $v.valid | Should -BeTrue
        @($v.checks | Where-Object { $_.check -like 'File devices.xml' -and $_.ok }).Count | Should -Be 1
        (@(Get-PmBackups) | Where-Object { $_.name -eq (Split-Path $f -Leaf) }).valid | Should -BeTrue
    }

    It 'finds a changed file inside a package' {
        $f = & $NewPart 'triggers'
        Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
        $z = [IO.Compression.ZipFile]::Open($f, [IO.Compression.ZipArchiveMode]::Update)
        try { $e = $z.GetEntry('triggers.xml'); $s = $e.Open(); $s.SetLength(0); $b = [Text.Encoding]::UTF8.GetBytes('<changed/>'); $s.Write($b, 0, $b.Length); $s.Dispose() } finally { $z.Dispose() }
        $v = Test-PmBackupPackage -Name (Split-Path $f -Leaf)
        $v.valid | Should -BeFalse
        ($v.errors -join ' ') | Should -Match 'checksum does not match|changed since'
    }

    It 'encrypts a package on request and checks the password during validation' {
        $f = & $NewPart 'notifications' 'backup-pass-1'
        $f | Should -BeLike '*.pmenc'
        Test-Path ([IO.Path]::ChangeExtension($f, '.zip')) | Should -BeFalse
        $b = @(Get-PmBackups) | Where-Object { $_.name -eq (Split-Path $f -Leaf) }
        $b.encrypted | Should -BeTrue; $b.type | Should -Be 'notifications'
        (Test-PmBackupPackage -Name (Split-Path $f -Leaf)).valid | Should -BeTrue
        (Test-PmBackupPackage -Name (Split-Path $f -Leaf) -Password 'backup-pass-1').valid | Should -BeTrue
        $bad = Test-PmBackupPackage -Name (Split-Path $f -Leaf) -Password 'not the password'
        $bad.valid | Should -BeFalse
        ($bad.errors -join ' ') | Should -Match 'password is wrong'
        $pkg = Read-PmSectionPackage -Path $f -Password 'backup-pass-1'
        $pkg.Type | Should -Be 'notifications'
        ConvertFrom-PmPackedText $pkg.Packed | Should -Match 'prtgmanagersection'
        @(Get-ChildItem (Join-Path $Cat 'data\staging') -Filter 'decrypted-*' -ErrorAction SilentlyContinue).Count | Should -Be 0
        { Read-PmSectionPackage -Path $f } | Should -Throw '*encrypted*password*'
    }

    It 'inspects a package without any secret and knows old package names and formats' {
        $f = & $NewPart 'devices'
        $d = Get-PmBackupDetails -Name (Split-Path $f -Leaf)
        $d.type | Should -Be 'devices'; $d.manifest.formatVersion | Should -Be 2; $d.entries | Should -Be 2
        @($d.files | ForEach-Object { $_.path }) | Should -Contain 'devices.xml'
        Get-PmBackupType -Manifest ([pscustomobject]@{ tool = 'prtg-mover'; formatVersion = 1; prtg = [pscustomobject]@{ included = $true } }) | Should -Be 'full'
        Get-PmBackupType -Manifest $null -Name 'PRTG-GRAPHS_S_20260101-000000.zip' | Should -Be 'graphs'
        Get-PmBackupType -Manifest $null -Name 'VPN_S_20260101-000000.zip' | Should -Be 'vpn'
    }

    It 'does not list VPN-only packages of PRTG Mover (they belong to VPN Manager)' {
        $zip = Join-Path (Get-PmPath Backups) 'VPN_SRC1_20260101-000000.zip'
        $m = [ordered]@{ tool = 'prtg-mover'; formatVersion = 1; source = @{ computer = 'SRC1' }; prtg = @{ included = $false }; vpn = @{ included = $true } }
        New-PmZipFromFiles -ZipPath $zip -Manifest $m -Files @{ 'vpn/x.txt' = [byte[]](1) }
        Register-PmBackup -ZipPath $zip
        @(Get-PmBackups | Where-Object { $_.name -eq 'VPN_SRC1_20260101-000000.zip' }).Count | Should -Be 0
        @(Get-PmBackups -IncludeVpn | Where-Object { $_.name -eq 'VPN_SRC1_20260101-000000.zip' }).Count | Should -Be 1
    }

    It 'moves a deleted package to the Recycle Bin instead of deleting it' {
        $f = & $NewPart 'devices'
        $bin = Join-Path $Work 'recycle'; New-Item -ItemType Directory -Force -Path $bin | Out-Null
        $old = $env:PRTGMOVER_TEST; $env:PRTGMOVER_TEST = '1'; $env:PRTGMANAGER_RECYCLE = $bin
        try { Remove-PmBackup -Name (Split-Path $f -Leaf) } finally { $env:PRTGMOVER_TEST = $old; Remove-Item Env:\PRTGMANAGER_RECYCLE }
        Test-Path $f | Should -BeFalse
        Test-Path (Join-Path $bin (Split-Path $f -Leaf)) | Should -BeTrue
        Test-Path (Join-Path $bin ((Split-Path $f -Leaf) + '.meta.json')) | Should -BeTrue
    }

    It 'keeps passwords out of job records, job logs and the audit trail' {
        $f = & $NewPart 'devices' 'Very-Secret-Pw-42'
        $job = Start-PmJob -Type 'validate' -Params @{ BackupName = (Split-Path $f -Leaf); Secrets = @{ Password = 'Very-Secret-Pw-42' } } -Summary 'validate test'
        $deadline = (Get-Date).AddSeconds(60)
        do { Start-Sleep -Milliseconds 300; $j = Get-PmJob -Id $job.id } while ($j.status -in 'queued', 'running' -and (Get-Date) -lt $deadline)
        $j.status | Should -Be 'succeeded'
        $j.result.valid | Should -BeTrue
        $j.result.passwordChecked | Should -BeTrue
        foreach ($file in @(Get-ChildItem (Get-PmPath Jobs) -File) + @(Get-ChildItem (Join-Path (Get-PmPath Data) 'logs') -File -Recurse)) {
            [IO.File]::ReadAllText($file.FullName) | Should -Not -Match 'Very-Secret-Pw-42'
        }
        $j.resumable | Should -BeFalse
    }
}

Describe 'Restore preview of a full package' {
    BeforeAll {
        $script:Man = [pscustomobject]@{ stagingBytes = 5GB; prtg = [pscustomobject]@{ included = $true; version = '25.4.114.1032'; configStats = 'devices=27'; includeHistory = $true; programCloned = $true; programFolders = @('cert'); netFrameworkRelease = 528049 } }
        $script:Facts = { param([string]$Version = '25.4.114.1032', [bool]$Installed = $true, [int64]$Free = 100GB) [pscustomobject]@{ Computer = 'NEW'; IsAdmin = $true; Prtg = [pscustomobject]@{ Installed = $Installed; Version = $Version }; ConfigStats = 'devices=3'; DataBytes = 1GB; FreeBytes = $Free; NetRelease = 528049; License = $null } }
    }
    It 'shows what is replaced and how it is rolled back' {
        $p = Get-PmFullRestorePreview -Manifest $Man -Facts (& $Facts)
        @($p.Blockers).Count | Should -Be 0
        @($p.Items | ForEach-Object { $_.Item }) | Should -Contain 'PRTG configuration'
        $p.Rollback | Should -Match 'automatic'
    }
    It 'blocks an older target, too little disk space and a target without PRTG and without program clone' {
        (Get-PmFullRestorePreview -Manifest $Man -Facts (& $Facts '24.1.0.1')).Blockers[0] | Should -Match 'older than the backup'
        (Get-PmFullRestorePreview -Manifest $Man -Facts (& $Facts '24.1.0.1') -Options @{ AllowDowngrade = $true }).Warnings[0] | Should -Match 'older'
        (Get-PmFullRestorePreview -Manifest $Man -Facts (& $Facts -Free 1GB)).Blockers[0] | Should -Match 'Not enough free space'
        $noClone = [pscustomobject]@{ stagingBytes = 1; prtg = [pscustomobject]@{ included = $true; version = '25.4.114.1032'; programCloned = $false; programFolders = @() } }
        (Get-PmFullRestorePreview -Manifest $noClone -Facts (& $Facts -Installed $false)).Blockers[0] | Should -Match 'not installed on the target'
    }
    It 'never restores into a server marked as source' {
        { Assert-PmNotSource -Server ([pscustomobject]@{ name = 'OLD'; role = 'source' }) -What 'restore into' } | Should -Throw '*marked as a source*'
        { Assert-PmNotSource -Server ([pscustomobject]@{ name = 'NEW'; role = 'target' }) } | Should -Not -Throw
        { Invoke-PmSectionRestoreFlow -Server ([pscustomobject]@{ id = 's'; name = 'OLD'; role = 'source'; transport = 'winrm'; host = '192.0.2.1' }) -Path 'x.zip' } | Should -Throw '*marked as a source*'
    }
}

Describe 'PRTG license: install, backup, restore' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        $script:LicKey2 = "HKCU:\Software\PrtgManagerLicTest-$([guid]::NewGuid().ToString('N'))"
        $script:LicData2 = Join-Path $Work 'lic2-data'
        $env:PRTGMOVER_WORKROOT = Join-Path $Work 'lic2-workroot'
    }
    AfterAll {
        Remove-Item -LiteralPath $script:LicKey2 -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item Env:\PRTGMOVER_WORKROOT -ErrorAction SilentlyContinue
    }
    BeforeEach {
        Remove-Item -LiteralPath $script:LicKey2 -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path "$($script:LicKey2)\Server\Core" -Force | Out-Null
        Set-ItemProperty -Path "$($script:LicKey2)\Server" -Name LicenseHash -Value 'old-activation'
        Set-ItemProperty -Path "$($script:LicKey2)\Server" -Name LicenseInstalled -Value ([byte[]](1, 2, 3)) -Type Binary
        New-Item -ItemType Directory -Force -Path $script:LicData2 | Out-Null
        Mock Test-PmIsAdmin { $true }
        Mock Get-PmPrtgInfo { [pscustomobject]@{ Installed = $true; DataPath = $script:LicData2; RegistryKeys = @($script:LicKey2); ListenPorts = @(); CoreStatus = 'Running'; Version = '25.4.114.1032' } }
        Mock Get-PmLicenseValues {
            $keys = @(Get-Item -LiteralPath $script:LicKey2) + @(Get-ChildItem -LiteralPath $script:LicKey2 -Recurse)
            foreach ($k in $keys) { foreach ($n in $k.GetValueNames()) { if ($n -match 'licen') { [pscustomobject]@{ Path = $k.PSPath; Name = $n; Kind = $k.GetValueKind($n); Value = $k.GetValue($n) } } } }
        }
        Mock Stop-PmPrtgServices { }
        Mock Invoke-PmReg { 'saved' | Set-Content -LiteralPath $File; 0 }
        Mock Invoke-PmHealthCheck { $Box.Health = [pscustomobject]@{ Healthy = $true; Url = 'https://localhost/ (HTTP 200)'; Message = '' } }
        Mock Get-PmPrtgLicenseState { [pscustomobject]@{ Known = $true; Edition = 'No License (Invalid)'; Name = ''; MaxSensors = 0; NeedsActivation = $true } }
        Mock Get-PmCoreLogMark { @{} }
        Mock Wait-PmLicenseLine { [pscustomobject]@{ Known = $true; Edition = 'Trial'; Name = 'Test Org'; MaxSensors = 1000; NeedsActivation = $false; LastError = $null; Fresh = $true } }
        Mock Get-PmPrtgLicenseReport { [pscustomobject]@{ Values = @(); SystemId = ''; AutoActivation = 1; LogLines = @() } }
    }

    It 'explains what to do for the usual activation results' {
        Get-PmLicenseHint ([pscustomobject]@{ Known = $true; NeedsActivation = $true; Name = 'x'; LastError = 'HTTP/1.1 403 Forbidden' }) | Should -Match 'refused this activation'
        Get-PmLicenseHint ([pscustomobject]@{ Known = $true; NeedsActivation = $true; Name = ''; LastError = $null }) | Should -Match 'No license is installed'
        Get-PmLicenseHint ([pscustomobject]@{ Known = $true; NeedsActivation = $true; Name = 'x'; LastError = 'could not connect to host' }) | Should -Match 'offline'
        Get-PmLicenseHint ([pscustomobject]@{ Known = $true; NeedsActivation = $false; Edition = 'Site License'; MaxSensors = 9 }) | Should -Match 'Licensed'
    }

    It 'writes name and key like the PRTG Administration Tool, drops the old activation and keeps a copy' {
        $r = @(Install-PmPrtgLicense -LicenseName 'Test Org' -LicenseKey 'AAAAAA-BBBBBB-CCCCCC-DDDDDD-EEEEEE' -Kind trial -LicenseKeyPath "$($script:LicKey2)\Server") | Where-Object PmType -eq 'result'
        $p = Get-ItemProperty "$($script:LicKey2)\Server"
        $p.LicenseName | Should -Be 'Test Org'
        $p.LicenseKey | Should -Be 'AAAAAA-BBBBBB-CCCCCC-DDDDDD-EEEEEE'
        $p.PSObject.Properties.Name | Should -Not -Contain 'LicenseHash'
        $r.Activated | Should -BeTrue
        Test-Path $r.Rollback | Should -BeTrue
        ($r | ConvertTo-Json -Depth 6) | Should -Not -Match 'BBBBBB-CCCCCC'
        Should -Invoke Stop-PmPrtgServices -Times 1 -Exactly
    }

    It 'refuses a key that cannot be one, an active license without confirmation, and a non-administrator - before changing anything' {
        { Install-PmPrtgLicense -LicenseName 'x' -LicenseKey 'short' } | Should -Throw '*does not look like a PRTG license key*'
        Mock Get-PmPrtgLicenseState { [pscustomobject]@{ Known = $true; Edition = 'Site License'; Name = 'x'; MaxSensors = 500; NeedsActivation = $false } }
        { Install-PmPrtgLicense -LicenseName 'x' -LicenseKey 'AAAAAA-BBBBBB-CCCCCC-DDDDDD' } | Should -Throw '*already runs with an active license*'
        Mock Test-PmIsAdmin { $false }
        { Install-PmPrtgLicense -LicenseName 'x' -LicenseKey 'AAAAAA-BBBBBB-CCCCCC-DDDDDD' } | Should -Throw '*administrator rights*'
        Should -Invoke Stop-PmPrtgServices -Times 0 -Exactly
        (Get-ItemProperty "$($script:LicKey2)\Server").LicenseHash | Should -Be 'old-activation'
    }

    It 'backs the license up encrypted on the server and restores every value from it' {
        Set-ItemProperty -Path "$($script:LicKey2)\Server" -Name LicenseName -Value 'Site Org'
        Set-ItemProperty -Path "$($script:LicKey2)\Server" -Name LicenseKey -Value 'KEYKEY-KEYKEY-KEYKEY-KEYKEY'
        $b = @(Backup-PmPrtgLicense -Password 'lic-backup-pw') | Where-Object PmType -eq 'result'
        ($b | ConvertTo-Json -Depth 6) | Should -Not -Match 'KEYKEY'
        @($b.ValueNames) | Should -Contain 'LicenseKey'
        Remove-ItemProperty -Path "$($script:LicKey2)\Server" -Name LicenseName, LicenseKey, LicenseHash
        { Install-PmPrtgLicense -Envelope $b.Envelope -Password 'wrong-password' } | Should -Throw '*password is wrong*'
        $r = @(Install-PmPrtgLicense -Envelope $b.Envelope -Password 'lic-backup-pw') | Where-Object PmType -eq 'result'
        $r.Kind | Should -Be 'restore'
        $p = Get-ItemProperty "$($script:LicKey2)\Server"
        $p.LicenseKey | Should -Be 'KEYKEY-KEYKEY-KEYKEY-KEYKEY'
        $p.LicenseHash | Should -Be 'old-activation'
        [byte[]]$p.LicenseInstalled | Should -Be @(1, 2, 3)
    }
}

Describe 'Dashboard API for backups (running dashboard)' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        $script:ApiData = Join-Path $Work 'api-data'
        New-Item -ItemType Directory -Force -Path $ApiData | Out-Null
        Set-PmRoot -Path $ApiData
        $m = New-PmManifestV2 -Type 'devices' -Computer 'SRC9' -Server 'S9' -PrtgVersion '25.4.114.1032' -JobId 'api'
        $script:ApiZip = Join-Path (Get-PmPath Backups) 'PRTG-DEVICES_SRC9_20260101-000000.zip'
        New-PmZipFromFiles -ZipPath $ApiZip -Manifest $m -Files @{ 'devices.xml' = [Text.Encoding]::UTF8.GetBytes('<prtgmanagersection type="devices"/>') }
        [void](Complete-PmPackage -ZipPath $ApiZip -Manifest $m -Source 'S9')
        $script:ApiBin = Join-Path $Work 'api-recycle'; New-Item -ItemType Directory -Force -Path $ApiBin | Out-Null
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start(); $script:ApiPort = $l.LocalEndpoint.Port; $l.Stop()
        $oldT = $env:PRTGMOVER_TEST; $env:PRTGMOVER_TEST = '1'; $env:PRTGMANAGER_RECYCLE = $ApiBin
        try {
            $script:ApiProc = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
                (Join-Path $Root 'Start-PrtgManager.ps1'), '-Port', $ApiPort, '-NoBrowser', '-Quiet', '-DataRoot', $ApiData
        } finally { $env:PRTGMOVER_TEST = $oldT; Remove-Item Env:\PRTGMANAGER_RECYCLE }
        $script:Api = "http://localhost:$ApiPort"
        $deadline = (Get-Date).AddSeconds(40); $ok = $false
        while (-not $ok -and (Get-Date) -lt $deadline) { try { [void](Invoke-RestMethod "$Api/api/info" -TimeoutSec 3); $ok = $true } catch { Start-Sleep -Milliseconds 500 } }
        $script:ErrorOf = {
            param([string]$Method, [string]$Url, [string]$Body)
            $req = [Net.HttpWebRequest]::Create($Url); $req.Method = $Method; $req.Timeout = 15000
            if ($Body) { $req.ContentType = 'application/json'; $b = [Text.Encoding]::UTF8.GetBytes($Body); $req.ContentLength = $b.Length; $s = $req.GetRequestStream(); $s.Write($b, 0, $b.Length); $s.Dispose() }
            try { $r = $req.GetResponse() } catch [Net.WebException] { $r = $_.Exception.Response }
            $sr = New-Object IO.StreamReader($r.GetResponseStream()); $txt = $sr.ReadToEnd(); $r.Close()
            [pscustomobject]@{ Status = [int]$r.StatusCode; Body = ($txt | ConvertFrom-Json) }
        }
    }
    AfterAll { if ($script:ApiProc) { Stop-Process -Id $script:ApiProc.Id -Force -ErrorAction SilentlyContinue } }

    It 'lists packages with type and version and inspects one' {
        $i = Invoke-RestMethod "$Api/api/info"
        $i.product | Should -Be 'PRTG Manager'; $i.formatVersion | Should -Be 2
        $list = @(Invoke-RestMethod "$Api/api/backups" | ForEach-Object { $_ })
        $b = $list | Where-Object name -eq 'PRTG-DEVICES_SRC9_20260101-000000.zip'
        $b.type | Should -Be 'devices'; $b.formatVersion | Should -Be 2
        (Invoke-RestMethod "$Api/api/backups/PRTG-DEVICES_SRC9_20260101-000000.zip/inspect").entries | Should -Be 2
    }

    It 'answers errors with operation, component, reason and a hint' {
        $e = & $ErrorOf GET "$Api/api/backups/NOPE.zip/inspect"
        $e.Status | Should -Be 404
        $e.Body.operation | Should -Be 'Inspect backup'
        $e.Body.component | Should -Be 'NOPE.zip'
        $e.Body.reason | Should -Match 'not found'
        $e.Body.hint | Should -Not -BeNullOrEmpty
        $e.Body.error | Should -Match '^Inspect backup failed on NOPE.zip: '
        $e2 = & $ErrorOf POST "$Api/api/jobs" '{"type":"section-backup","sourceId":"x","sectionType":"license"}'
        $e2.Status | Should -Be 400
        $e2.Body.reason | Should -Match 'backup password'
        $e3 = & $ErrorOf POST "$Api/api/jobs" '{"type":"no-such-job"}'
        $e3.Body.reason | Should -Match "unknown job type"
    }

    It 'validates a package as a job and deletes it into the Recycle Bin' {
        $j = Invoke-RestMethod -Method Post -Uri "$Api/api/jobs" -ContentType 'application/json' -Body '{"type":"validate","backupName":"PRTG-DEVICES_SRC9_20260101-000000.zip"}'
        $deadline = (Get-Date).AddSeconds(60)
        do { Start-Sleep -Milliseconds 400; $st = Invoke-RestMethod "$Api/api/jobs/$($j.id)" } while ($st.status -in 'queued', 'running' -and (Get-Date) -lt $deadline)
        $st.status | Should -Be 'succeeded'
        $st.result.valid | Should -BeTrue
        (Invoke-RestMethod -Method Delete -Uri "$Api/api/backups/PRTG-DEVICES_SRC9_20260101-000000.zip").recycled | Should -BeTrue
        Test-Path $ApiZip | Should -BeFalse
        Test-Path (Join-Path $ApiBin 'PRTG-DEVICES_SRC9_20260101-000000.zip') | Should -BeTrue
    }
}
