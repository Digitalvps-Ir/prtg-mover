#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Run: Invoke-Pester -Path .\tests -Output Detailed

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("pm install tests " + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Work | Out-Null
    # A folder name with a space, as in "C:\Program Files".
    $script:Target = Join-Path $Work 'Prtg Mover'
    $script:Links = Join-Path $Work 'links'
    $script:Install = {
        param([string[]]$More = @())
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"",
            '-InstallPath', "`"$Target`"", '-ShortcutFolder', "`"$Links`"") + $More
        $out = Join-Path $Work 'install.out.txt'
        $p = Start-Process powershell -ArgumentList $list -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError (Join-Path $Work 'install.err.txt')
        [pscustomobject]@{ ExitCode = $p.ExitCode; Output = [string][IO.File]::ReadAllText($out) }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

Describe 'Installer' -Skip:($env:OS -ne 'Windows_NT') {
    It 'installs into a new folder, tests the installation and creates the shortcut' {
        $r = & $Install @('-Source', "`"$Root`"", '-NoStart')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'the dashboard answers'
        foreach ($f in 'Start-PrtgMover.ps1', 'Start-PrtgMover.cmd', 'install.ps1', 'install.cmd', 'VERSION', 'src\PrtgMover.psm1', 'src\Remote\PrtgMover.Remote.ps1',
            'agent\PrtgMover-Agent.ps1', 'web\index.html', 'web\app.js', 'tools\Enable-PrtgMoverRemoting.ps1', 'tools\Setup-Manager.ps1') {
            Test-Path -LiteralPath (Join-Path $Target $f) | Should -BeTrue -Because "$f belongs to the program"
        }
        foreach ($d in 'config', 'data', 'backups', 'installers') { Test-Path -LiteralPath (Join-Path $Target $d) -PathType Container | Should -BeTrue }
        Test-Path -LiteralPath (Join-Path $Links 'PRTG Mover.lnk') | Should -BeTrue
        ([IO.File]::ReadAllText((Join-Path $Target 'VERSION'))).Trim() | Should -Be ([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim()
    }

    It 'never copies data of the source folder' {
        Test-Path -LiteralPath (Join-Path $Target 'config\servers.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $Target 'backups') -Force).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $Target 'data') -Force).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $Target '.git') | Should -BeFalse
    }

    It 'the shortcut starts the dashboard of the installed folder' {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Links 'PRTG Mover.lnk'))
        $s.TargetPath | Should -Match 'powershell\.exe$'
        $s.Arguments | Should -BeLike "*$Target\Start-PrtgMover.ps1*"
        $s.Arguments | Should -Match '-Port 8765'
        $s.WorkingDirectory | Should -Be $Target
    }

    It 'an update keeps the server list and the backups and repairs the program' {
        $servers = '[{"id":"abc","name":"Keep me","host":"192.0.2.10","role":"source"}]'
        [IO.File]::WriteAllText((Join-Path $Target 'config\servers.json'), $servers)
        [IO.File]::WriteAllText((Join-Path $Target 'backups\PRTG_TEST_20260101-000000.zip'), 'backup')
        [IO.File]::WriteAllText((Join-Path $Target 'data\jobs.keep'), 'job')
        Remove-Item -LiteralPath (Join-Path $Target 'web\app.js') -Force
        [IO.File]::WriteAllText((Join-Path $Target 'VERSION'), '0.0.1')
        [IO.File]::WriteAllText((Join-Path $Target 'src\leftover-of-an-old-version.ps1'), '# old')

        $r = & $Install @('-Source', "`"$Root`"", '-NoStart', '-NoShortcut')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'your data was kept: server list, backups'
        $r.Output | Should -Match 'was 0\.0\.1'
        [IO.File]::ReadAllText((Join-Path $Target 'config\servers.json')) | Should -Be $servers
        [IO.File]::ReadAllText((Join-Path $Target 'backups\PRTG_TEST_20260101-000000.zip')) | Should -Be 'backup'
        Test-Path -LiteralPath (Join-Path $Target 'data\jobs.keep') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'web\app.js') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'src\leftover-of-an-old-version.ps1') | Should -BeFalse
    }

    It 'installs from a zip file' {
        $stage = Join-Path $Work 'zip\prtg-mover-main'
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        foreach ($i in 'agent', 'cli', 'src', 'tools', 'web') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination (Join-Path $stage $i) -Recurse }
        foreach ($i in 'Start-PrtgMover.ps1', 'Start-PrtgMover.cmd', 'install.ps1', 'install.cmd', 'VERSION') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination $stage }
        $zip = Join-Path $Work 'prtg-mover-main.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $stage -Parent), $zip)

        $r = & $Install @('-Source', "`"$zip`"", '-NoStart', '-NoShortcut')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $Target 'web\app.js') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'config\servers.json') | Should -BeTrue
    }

    It 'refuses a source that is not PRTG Mover and leaves the installation alone' {
        $empty = Join-Path $Work 'not-prtg-mover'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        $r = & $Install @('-Source', "`"$empty`"", '-NoStart', '-NoShortcut')
        $r.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $Target 'Start-PrtgMover.ps1') | Should -BeTrue
    }

    It 'reports a damaged script instead of installing it silently' {
        $bad = Join-Path $Work 'damaged'
        New-Item -ItemType Directory -Force -Path $bad | Out-Null
        foreach ($i in 'src', 'web') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination (Join-Path $bad $i) -Recurse }
        foreach ($i in 'Start-PrtgMover.ps1', 'VERSION') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination $bad }
        [IO.File]::WriteAllText((Join-Path $bad 'src\broken.ps1'), 'function Broken { if (')
        $other = Join-Path $Work 'damaged target'
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"", '-InstallPath', "`"$other`"", '-Source', "`"$bad`"", '-NoStart', '-NoShortcut')
        $p = Start-Process powershell -ArgumentList $list -Wait -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Work 'damaged.err.txt') -RedirectStandardOutput (Join-Path $Work 'damaged.out.txt')
        $p.ExitCode | Should -Not -Be 0
        [IO.File]::ReadAllText((Join-Path $Work 'damaged.err.txt')) | Should -Match 'is damaged'
    }

    It 'uninstall removes the program and the shortcut and keeps the data' {
        $r = & $Install @('-Uninstall')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $Links 'PRTG Mover.lnk') | Should -BeFalse
        foreach ($f in 'Start-PrtgMover.ps1', 'src', 'web', 'agent', 'tools', 'VERSION') { Test-Path -LiteralPath (Join-Path $Target $f) | Should -BeFalse -Because "$f is a program file" }
        Test-Path -LiteralPath (Join-Path $Target 'config\servers.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'backups\PRTG_TEST_20260101-000000.zip') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'data\jobs.keep') | Should -BeTrue
    }

    It 'uninstall of a folder without PRTG Mover removes nothing' {
        $other = Join-Path $Work 'something else'
        New-Item -ItemType Directory -Force -Path (Join-Path $other 'src') | Out-Null
        [IO.File]::WriteAllText((Join-Path $other 'src\mine.txt'), 'x')
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"", '-InstallPath', "`"$other`"", '-ShortcutFolder', "`"$Links`"", '-Uninstall')
        $p = Start-Process powershell -ArgumentList $list -Wait -PassThru -WindowStyle Hidden
        $p.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $other 'src\mine.txt') | Should -BeTrue
    }
}

Describe 'Server preparation script for WinRM' {
    BeforeAll {
        $script:Enable = Get-Command (Join-Path $Root 'tools\Enable-PrtgMoverRemoting.ps1')
        $script:EnableText = [IO.File]::ReadAllText((Join-Path $Root 'tools\Enable-PrtgMoverRemoting.ps1'))
    }

    It 'has the documented parameters' {
        foreach ($n in 'ManagerAddress', 'AllowAnyAddress', 'Https', 'KeepPlainWinRM') { $Enable.Parameters.Keys | Should -Contain $n }
    }

    It 'never opens the firewall for every address unless that is asked for' {
        $EnableText | Should -Match 'could not be found\. Pass it with -ManagerAddress'
        $EnableText | Should -Match "if \(\`$allowed\.Count\) \{ \`$fw\.RemoteAddress = \`$allowed \}"
    }

    It 'creates a certificate that is already valid for a manager whose clock is behind' {
        $EnableText | Should -Match '-NotBefore \(Get-Date\)\.AddDays\(-2\)'
    }
}
