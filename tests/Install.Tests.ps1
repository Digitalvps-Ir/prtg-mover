#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
# Run: Invoke-Pester -Path .\tests -Output Detailed

BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:Work = Join-Path ([IO.Path]::GetTempPath()) ("pm install tests " + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $Work | Out-Null
    # A folder name with a space, as in "C:\Program Files".
    $script:Target = Join-Path $Work 'Prtg Mover'
    $script:Links = Join-Path $Work 'links'
    # The tests never touch the real desktop, start menu or Startup folder.
    $script:Startup = Join-Path $Work 'startup'
    $script:Install = {
        param([string[]]$More = @())
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"",
            '-InstallPath', "`"$Target`"", '-ShortcutFolder', "`"$Links`"", '-StartupFolder', "`"$Startup`"") + $More
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
        foreach ($f in 'Start-PrtgManager.ps1', 'Start-PrtgManager.cmd', 'install.ps1', 'install.cmd', 'VERSION', 'src\PrtgManager.psm1', 'src\Remote\PrtgManager.Remote.ps1',
            'agent\PrtgManager-Agent.ps1', 'web\index.html', 'web\app.js', 'tools\Enable-PrtgManagerRemoting.ps1', 'tools\Setup-Manager.ps1') {
            Test-Path -LiteralPath (Join-Path $Target $f) | Should -BeTrue -Because "$f belongs to the program"
        }
        foreach ($d in 'config', 'data', 'backups', 'installers') { Test-Path -LiteralPath (Join-Path $Target $d) -PathType Container | Should -BeTrue }
        Test-Path -LiteralPath (Join-Path $Links 'PRTG Manager.lnk') | Should -BeTrue
        ([IO.File]::ReadAllText((Join-Path $Target 'VERSION'))).Trim() | Should -Be ([IO.File]::ReadAllText((Join-Path $Root 'VERSION'))).Trim()
    }

    It 'never copies data of the source folder' {
        Test-Path -LiteralPath (Join-Path $Target 'config\servers.json') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Join-Path $Target 'backups') -Force).Count | Should -Be 0
        @(Get-ChildItem -LiteralPath (Join-Path $Target 'data') -Force).Count | Should -Be 0
        Test-Path -LiteralPath (Join-Path $Target '.git') | Should -BeFalse
    }

    It 'the shortcut starts the dashboard of the installed folder' {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Links 'PRTG Manager.lnk'))
        $s.TargetPath | Should -Match 'powershell\.exe$'
        $s.Arguments | Should -BeLike "*$Target\Start-PrtgManager.ps1*"
        $s.Arguments | Should -Match '-Port 8765'
        $s.WorkingDirectory | Should -Be $Target
    }

    It 'does not start with Windows unless that is asked for' {
        Test-Path -LiteralPath (Join-Path $Startup 'PRTG Manager.lnk') | Should -BeFalse
    }

    It 'leaves the start with Windows of another installation alone' {
        New-Item -ItemType Directory -Force -Path $Startup | Out-Null
        $lnk = Join-Path $Startup 'PRTG Manager.lnk'
        $elsewhere = Join-Path $Work 'another installation'
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $s.Arguments = "-File `"$elsewhere\Start-PrtgManager.ps1`" -NoBrowser"; $s.WorkingDirectory = $elsewhere; $s.Save()

        $r = & $Install @('-Source', "`"$Root`"", '-NoStart', '-NoShortcut')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).WorkingDirectory | Should -Be $elsewhere

        $r = & $Install @('-Source', "`"$Root`"", '-NoStart', '-NoShortcut', '-NoAutostart')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'another installation'
        (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).WorkingDirectory | Should -Be $elsewhere
        Remove-Item -LiteralPath $lnk -Force
    }

    It 'starts with Windows with -Autostart, keeps that on an update and removes it with -NoAutostart' {
        $r = & $Install @('-Source', "`"$Root`"", '-NoStart', '-NoShortcut', '-Autostart')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $lnk = Join-Path $Startup 'PRTG Manager.lnk'
        Test-Path -LiteralPath $lnk | Should -BeTrue
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
        $s.Arguments | Should -BeLike "*$Target\Start-PrtgManager.ps1*"
        $s.Arguments | Should -Match '-NoBrowser'
        $s.WindowStyle | Should -Be 7

        $r = & $Install @('-Source', "`"$Root`"", '-NoStart', '-NoShortcut')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        $r.Output | Should -Match 'the dashboard starts when you log on'
        Test-Path -LiteralPath $lnk | Should -BeTrue

        $r = & $Install @('-Source', "`"$Root`"", '-NoStart', '-NoShortcut', '-NoAutostart')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath $lnk | Should -BeFalse
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

    It 'updates an installation made under the earlier name PRTG Mover in place: data kept, old shortcuts replaced' {
        $old = Join-Path $Work 'old name install'
        New-Item -ItemType Directory -Force -Path (Join-Path $old 'src'), (Join-Path $old 'config'), (Join-Path $old 'backups'), $Startup, $Links | Out-Null
        [IO.File]::WriteAllText((Join-Path $old 'Start-PrtgMover.ps1'), '# old dashboard')
        [IO.File]::WriteAllText((Join-Path $old 'src\PrtgMover.psm1'), '# old module')
        [IO.File]::WriteAllText((Join-Path $old 'config\servers.json'), '[{"id":"k","name":"Keep","host":"192.0.2.9","role":"source"}]')
        [IO.File]::WriteAllText((Join-Path $old 'backups\PRTG_OLD_20260101-000000.zip'), 'backup')
        foreach ($lnk in (Join-Path $Links 'PRTG Mover.lnk'), (Join-Path $Startup 'PRTG Mover.lnk')) {
            $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk)
            $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
            $s.Arguments = "-File `"$old\Start-PrtgMover.ps1`" -NoBrowser"; $s.WorkingDirectory = $old; $s.Save()
        }
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"", '-Source', "`"$Root`"", '-InstallPath', "`"$old`"", '-ShortcutFolder', "`"$Links`"", '-StartupFolder', "`"$Startup`"", '-NoStart')
        $out = Join-Path $Work 'install-old.out.txt'
        $pr = Start-Process powershell -ArgumentList $list -Wait -PassThru -WindowStyle Hidden -RedirectStandardOutput $out -RedirectStandardError (Join-Path $Work 'install-old.err.txt')
        $text = [IO.File]::ReadAllText($out)
        $pr.ExitCode | Should -Be 0 -Because $text
        $text | Should -Match 'updated from PRTG Mover'
        Test-Path -LiteralPath (Join-Path $old 'src\PrtgMover.psm1') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $old 'src\PrtgManager.psm1') | Should -BeTrue
        [IO.File]::ReadAllText((Join-Path $old 'Start-PrtgMover.ps1')) | Should -Match 'PRTG Mover is now PRTG Manager'
        [IO.File]::ReadAllText((Join-Path $old 'config\servers.json')) | Should -Match 'Keep'
        Test-Path -LiteralPath (Join-Path $old 'backups\PRTG_OLD_20260101-000000.zip') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Links 'PRTG Mover.lnk') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Links 'PRTG Manager.lnk') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Startup 'PRTG Mover.lnk') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Startup 'PRTG Manager.lnk') | Should -BeTrue -Because 'the old start with Windows is carried over'
        Remove-Item -LiteralPath (Join-Path $Startup 'PRTG Manager.lnk'), (Join-Path $Links 'PRTG Manager.lnk') -Force
    }

    It 'the old script names forward to the new ones' {
        # a port another program holds: the forwarded Start-PrtgManager.ps1 refuses it with exit code 1
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback, 0); $l.Start()
        try { $o = & powershell -NoProfile -ExecutionPolicy Bypass -Command "& '$(Join-Path $Root 'Start-PrtgMover.ps1')' -Port $($l.LocalEndpoint.Port) -NoBrowser; `$LASTEXITCODE" 2>&1 } finally { $l.Stop() }
        ($o | Select-Object -Last 1) | Should -Be '1'
        ($o -join ' ') | Should -Match 'used by another program'
        [IO.File]::ReadAllText((Join-Path $Root 'Start-PrtgMover.cmd')) | Should -Match 'Start-PrtgManager\.cmd'
    }

    It 'installs from a zip file' {
        $stage = Join-Path $Work 'zip\prtg-mover-main'
        New-Item -ItemType Directory -Force -Path $stage | Out-Null
        foreach ($i in 'agent', 'cli', 'src', 'tools', 'web') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination (Join-Path $stage $i) -Recurse }
        foreach ($i in 'Start-PrtgManager.ps1', 'Start-PrtgManager.cmd', 'install.ps1', 'install.cmd', 'VERSION') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination $stage }
        $zip = Join-Path $Work 'prtg-manager-main.zip'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::CreateFromDirectory((Split-Path $stage -Parent), $zip)

        $r = & $Install @('-Source', "`"$zip`"", '-NoStart', '-NoShortcut')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $Target 'web\app.js') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'config\servers.json') | Should -BeTrue
    }

    It 'refuses a source that is not PRTG Manager and leaves the installation alone' {
        $empty = Join-Path $Work 'not-prtg-mover'
        New-Item -ItemType Directory -Force -Path $empty | Out-Null
        $r = & $Install @('-Source', "`"$empty`"", '-NoStart', '-NoShortcut')
        $r.ExitCode | Should -Not -Be 0
        Test-Path -LiteralPath (Join-Path $Target 'Start-PrtgManager.ps1') | Should -BeTrue
    }

    It 'reports a damaged script instead of installing it silently' {
        $bad = Join-Path $Work 'damaged'
        New-Item -ItemType Directory -Force -Path $bad | Out-Null
        foreach ($i in 'src', 'web') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination (Join-Path $bad $i) -Recurse }
        foreach ($i in 'Start-PrtgManager.ps1', 'VERSION') { Copy-Item -LiteralPath (Join-Path $Root $i) -Destination $bad }
        [IO.File]::WriteAllText((Join-Path $bad 'src\broken.ps1'), 'function Broken { if (')
        $other = Join-Path $Work 'damaged target'
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"", '-InstallPath', "`"$other`"", '-Source', "`"$bad`"", '-NoStart', '-NoShortcut', '-StartupFolder', "`"$Startup`"")
        $p = Start-Process powershell -ArgumentList $list -Wait -PassThru -WindowStyle Hidden -RedirectStandardError (Join-Path $Work 'damaged.err.txt') -RedirectStandardOutput (Join-Path $Work 'damaged.out.txt')
        $p.ExitCode | Should -Not -Be 0
        [IO.File]::ReadAllText((Join-Path $Work 'damaged.err.txt')) | Should -Match 'is damaged'
    }

    It 'uninstall removes the program and the shortcuts and keeps the data' {
        New-Item -ItemType Directory -Force -Path $Startup | Out-Null
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path $Startup 'PRTG Manager.lnk'))
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'; $s.WorkingDirectory = $Target; $s.Save()

        $r = & $Install @('-Uninstall')
        $r.ExitCode | Should -Be 0 -Because $r.Output
        Test-Path -LiteralPath (Join-Path $Links 'PRTG Manager.lnk') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $Startup 'PRTG Manager.lnk') | Should -BeFalse
        foreach ($f in 'Start-PrtgManager.ps1', 'src', 'web', 'agent', 'tools', 'VERSION') { Test-Path -LiteralPath (Join-Path $Target $f) | Should -BeFalse -Because "$f is a program file" }
        Test-Path -LiteralPath (Join-Path $Target 'config\servers.json') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'backups\PRTG_TEST_20260101-000000.zip') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $Target 'data\jobs.keep') | Should -BeTrue
    }

    It 'uninstall of a folder without PRTG Manager removes nothing, also not the shortcut of another installation' {
        $other = Join-Path $Work 'something else'
        New-Item -ItemType Directory -Force -Path (Join-Path $other 'src'), $Links | Out-Null
        [IO.File]::WriteAllText((Join-Path $other 'src\mine.txt'), 'x')
        $foreign = Join-Path $Links 'PRTG Manager.lnk'
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($foreign)
        $s.TargetPath = Join-Path $env:SystemRoot 'System32\cmd.exe'; $s.WorkingDirectory = (Join-Path $Work 'another installation'); $s.Save()

        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"", '-InstallPath', "`"$other`"", '-ShortcutFolder', "`"$Links`"", '-StartupFolder', "`"$Startup`"", '-Uninstall')
        $p = Start-Process powershell -ArgumentList $list -Wait -PassThru -WindowStyle Hidden
        $p.ExitCode | Should -Be 0
        Test-Path -LiteralPath (Join-Path $other 'src\mine.txt') | Should -BeTrue
        Test-Path -LiteralPath $foreign | Should -BeTrue
    }
}

Describe 'Server preparation script for WinRM' {
    BeforeAll {
        $script:Enable = Get-Command (Join-Path $Root 'tools\Enable-PrtgManagerRemoting.ps1')
        $script:EnableText = [IO.File]::ReadAllText((Join-Path $Root 'tools\Enable-PrtgManagerRemoting.ps1'))
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

Describe 'Setup-All: one file for PRTG Manager and VPN Manager' -Skip:($env:OS -ne 'Windows_NT') {
    BeforeAll {
        # a stand-in for the VPN Manager repository (it is a separate, private repository)
        $script:FakeVw = Join-Path $Work 'vpn-manager-source'
        New-Item -ItemType Directory -Force -Path (Join-Path $FakeVw 'tools'), (Join-Path $FakeVw 'data') | Out-Null
        [IO.File]::WriteAllText((Join-Path $FakeVw 'VERSION'), '9.9.9')
        [IO.File]::WriteAllText((Join-Path $FakeVw 'Start-VpnManager.ps1'), 'param([int]$Port) "stand-in"')
        [IO.File]::WriteAllText((Join-Path $FakeVw 'data\token.txt'), 'must never be packed')
        $script:SetupFile = Join-Path $Work 'Setup-All.cmd'
        $script:Build = Start-Process powershell -Wait -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File',
            "`"$(Join-Path $Root 'tools\Build-SetupAll.ps1')`"", '-VpnManagerSource', "`"$FakeVw`"", '-Output', "`"$SetupFile`""
    }

    It 'builds one plain ASCII file that starts as a batch file' {
        $Build.ExitCode | Should -Be 0
        $bytes = [IO.File]::ReadAllBytes($SetupFile)
        $bytes.Length | Should -BeGreaterThan 100000
        @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        [Text.Encoding]::ASCII.GetString($bytes, 0, 4) | Should -Be '<# :'
    }

    It 'installs PRTG Manager from that file, also into a folder with a space' {
        $target = Join-Path $Work 'from one file\Prtg Mover'
        $old = $env:SETUPALL_NOPAUSE; $env:SETUPALL_NOPAUSE = '1'
        try {
            $out = & cmd.exe /c "`"$SetupFile`" -SkipVpnManager -PrtgManagerPath `"$target`" -NoShortcut -NoStart -NoAutostart -StartupFolder `"$Startup`"" 2>&1 | ForEach-Object { "$_" }
            $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        } finally { $env:SETUPALL_NOPAUSE = $old }
        ($out -join "`n") | Should -Match 'DONE'
        Test-Path -LiteralPath (Join-Path $target 'Start-PrtgManager.ps1') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $target 'config\servers.json') | Should -BeFalse
    }

    It 'still takes the parameter names of the earlier version (PRTG Mover / VPN Watch)' {
        $target = Join-Path $Work 'old parameter names'
        $old = $env:SETUPALL_NOPAUSE; $env:SETUPALL_NOPAUSE = '1'
        try {
            $out = & cmd.exe /c "`"$SetupFile`" -SkipVpnWatch -PrtgMoverPath `"$target`" -NoShortcut -NoStart -NoAutostart -StartupFolder `"$Startup`"" 2>&1 | ForEach-Object { "$_" }
            $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
        } finally { $env:SETUPALL_NOPAUSE = $old }
        Test-Path -LiteralPath (Join-Path $target 'Start-PrtgManager.ps1') | Should -BeTrue
    }

    It 'reports a failed installation with an exit code' {
        $old = $env:SETUPALL_NOPAUSE; $env:SETUPALL_NOPAUSE = '1'
        try {
            # the stand-in is no dashboard, so the test of VPN Manager has to fail
            $out = & cmd.exe /c "`"$SetupFile`" -SkipPrtgManager -VpnManagerPath `"$(Join-Path $Work 'vw target')`" -NoShortcut -NoStart" 2>&1 | ForEach-Object { "$_" }
            $LASTEXITCODE | Should -Be 1
        } finally { $env:SETUPALL_NOPAUSE = $old }
        ($out -join "`n") | Should -Match 'SETUP FAILED'
        Test-Path -LiteralPath (Join-Path $Work 'vw target\data\token.txt') | Should -BeFalse
    }
}

Describe 'Setup-All never stops a dashboard it cannot ask' {
    It 'stops a running dashboard only after it answered that no job is running' {
        $body = [IO.File]::ReadAllText((Join-Path $Root 'tools\setup-all\Setup-All.body.ps1'))
        $guard = $body.Substring($body.IndexOf('foreach ($d in $run)'))
        $guard = $guard.Substring(0, $guard.IndexOf('Stop-Process'))
        $guard | Should -Match 'catch \{ throw'
        $guard.Contains('$d.CommandLine -match') | Should -BeTrue -Because 'the port is taken from the running process'
        $guard | Should -Match 'if \(\$busy\) \{ throw'
    }

    It 'finds and counts ONE running dashboard (a single CimInstance has no .Count in Windows PowerShell 5.1)' -Skip:($env:OS -ne 'Windows_NT') {
        # Prtg-New 2026-10-02: the old VPN Watch dashboard kept running after the update, because $run.Count was empty
        $body = [IO.File]::ReadAllText((Join-Path $Root 'tools\setup-all\Setup-All.body.ps1'))
        ([regex]::Matches($body, '\$run = @\(Get-Dashboard ')).Count | Should -Be 2
        $fn = $body.Substring($body.IndexOf('function Get-Dashboard')); $fn = $fn.Substring(0, $fn.IndexOf("`n}") + 2)
        . ([ScriptBlock]::Create($fn))
        $folder = Join-Path $Work 'dash probe'
        $p = Start-Process powershell -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', "Start-Sleep 60 # $folder\Start-VpnWatch.ps1"
        try {
            Start-Sleep -Milliseconds 800
            $run = @(Get-Dashboard $folder 'Start-VpnManager.ps1', 'Start-VpnWatch.ps1')
            $run.Count | Should -Be 1
            $run[0].ProcessId | Should -Be $p.Id
        } finally { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    }
}

Describe 'Installer option -Local (PRTG Manager on the PRTG server itself)' -Skip:($env:OS -ne 'Windows_NT') {
    It 'refuses local mode without administrator rights and changes nothing' -Skip:([bool](New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        $target = Join-Path $Work 'local mode target'
        $err = Join-Path $Work 'local.err.txt'
        $list = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$(Join-Path $Root 'install.ps1')`"", '-InstallPath', "`"$target`"", '-Source', "`"$Root`"",
            '-ShortcutFolder', "`"$Links`"", '-StartupFolder', "`"$Startup`"", '-NoStart', '-NoShortcut', '-Local')
        $p = Start-Process powershell -ArgumentList $list -Wait -PassThru -WindowStyle Hidden -RedirectStandardError $err -RedirectStandardOutput (Join-Path $Work 'local.out.txt')
        $p.ExitCode | Should -Not -Be 0
        [IO.File]::ReadAllText($err) | Should -Match 'needs administrator rights'
        Test-Path -LiteralPath $target | Should -BeFalse
    }

    It 'has the functions for the server entry, the logon task and the shortcut with administrator rights' {
        $text = [IO.File]::ReadAllText((Join-Path $Root 'install.ps1'))
        $text.Contains("Set-PmServer -Name `$env:COMPUTERNAME -HostName 'localhost' -Role 'both' -Transport 'local'") | Should -BeTrue
        $text.Contains('-RunLevel Highest') | Should -BeTrue
        $text.Contains('$bytes[0x15] -bor 0x20') | Should -BeTrue
    }
}

Describe 'Upgrade path and command line (review findings)' {
    It 'keeps C:\PrtgMover as the default folder also after it was updated to PRTG Manager' {
        $txt = [IO.File]::ReadAllText((Join-Path $Root 'install.ps1'))
        $txt | Should -Match "Test-OldProgramFolder 'C:\\PrtgMover'\) -or \(Test-ProgramFolder 'C:\\PrtgMover'\)"
        $body = [IO.File]::ReadAllText((Join-Path $Root 'tools\setup-all\Setup-All.body.ps1'))
        $body | Should -Match "C:\\PrtgMover\\Start-PrtgManager\.ps1"
        $body | Should -Match "C:\\VpnWatchDashboard\\Start-VpnManager\.ps1"
    }
    It 'the command line decrypts encrypted packages, restores parts and never restores into a source' {
        $cli = [IO.File]::ReadAllText((Join-Path $Root 'cli\Invoke-PrtgManager.ps1'))
        $restore = $cli.Substring($cli.IndexOf("'Restore' {")); $restore = $restore.Substring(0, $restore.IndexOf("'RemoveLicense' {"))
        $restore | Should -Match 'Assert-PmNotSource'
        $restore | Should -Match 'Get-PmPlainPackage'
        $restore | Should -Match 'Invoke-PmSectionRestoreFlow'
        $cli.Substring($cli.IndexOf("'Migrate' {")) | Should -Match 'Assert-PmNotSource'
    }
    It 'retention finds packages of the same type and source, encrypted or not' {
        $prefix = 'PRTG-FULL_SRV_20260101-000000.pmenc' -replace '_\d{8}-\d{6}\.(zip|pmenc)$', '_'
        $prefix | Should -Be 'PRTG-FULL_SRV_'
        [IO.File]::ReadAllText((Join-Path $Root 'cli\Invoke-PrtgManager.ps1')) | Should -Match ([regex]::Escape("-replace '_\d{8}-\d{6}\.(zip|pmenc)$', '_'"))
    }
    It 'removes the decrypted zip and its restore extract after a restore, and never a package that was not encrypted' {
        Import-Module (Join-Path $Root 'src\PrtgManager.psm1') -Force -DisableNameChecking
        $mgr = Join-Path $Work 'plain-mgr'; New-Item -ItemType Directory -Force -Path $mgr | Out-Null
        Set-PmRoot -Path $mgr
        $stage = Join-Path (Get-PmPath Data) 'staging'
        New-Item -ItemType Directory -Force -Path (Join-Path $stage 'restore-decrypted-PRTG-FULL_SRV_20260101-000000\PRTG') | Out-Null
        $zip = Join-Path $stage 'decrypted-PRTG-FULL_SRV_20260101-000000.zip'; Set-Content -LiteralPath $zip -Value 'x'
        Set-Content -LiteralPath (Join-Path $stage 'restore-decrypted-PRTG-FULL_SRV_20260101-000000\PRTG\PRTG Configuration.dat') -Value '<config/>'
        Remove-PmPlainPackage ([pscustomobject]@{ Path = $zip; Temp = $true })
        Test-Path -LiteralPath $zip | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $stage 'restore-decrypted-PRTG-FULL_SRV_20260101-000000') | Should -BeFalse
        $plainZip = Join-Path $Work 'PRTG-FULL_SRV_20260101-000000.zip'; Set-Content -LiteralPath $plainZip -Value 'x'
        Remove-PmPlainPackage ([pscustomobject]@{ Path = $plainZip; Temp = $false })
        Test-Path -LiteralPath $plainZip | Should -BeTrue
        $cli = [IO.File]::ReadAllText((Join-Path $Root 'cli\Invoke-PrtgManager.ps1'))
        $cli | Should -Match 'finally \{ Remove-PmPlainPackage \$plain \}'
        [IO.File]::ReadAllText((Join-Path $Root 'src\PrtgManager.psm1')) | Should -Match 'finally \{ Remove-PmPlainPackage \$plain \}'
    }
    It 'the dashboard follows the DigitalVPS UI: shared theme, local font, own confirmation dialog, fixed date digits' {
        $web = Join-Path $Root 'web'
        foreach ($f in 'dv-theme.css', 'style.css', 'Vazirmatn.woff2', 'Vazirmatn-OFL.txt') { Test-Path -LiteralPath (Join-Path $web $f) | Should -BeTrue -Because "$f is part of the UI" }
        $html = [IO.File]::ReadAllText((Join-Path $web 'index.html'))
        $html | Should -Match 'href="dv-theme\.css"'
        $html | Should -Match 'id="confirmDialog"'
        $js = [IO.File]::ReadAllText((Join-Path $web 'app.js'))
        # every confirmation goes through the page's dialog (the browser box only as a fallback inside ask())
        ([regex]::Matches($js, '(?<![\w.])confirm\(')).Count | Should -Be 0
        $js | Should -Not -Match 'toLocale(Date|Time)?String\('
        [IO.File]::ReadAllText((Join-Path $web 'Vazirmatn-OFL.txt')) | Should -Match 'SIL Open Font License'
        # the font is sent as bytes with its own type (the text path would corrupt it)
        $srv = [IO.File]::ReadAllText((Join-Path $Root 'Start-PrtgManager.ps1'))
        $srv | Should -Match "'\.woff2' = 'font/woff2'"
        $srv | Should -Match 'ReadAllBytes\(\$file\)'
    }
    It 'runs one restore per package at a time and removes decrypted copies left by an interrupted restore' {
        Import-Module (Join-Path $Root 'src\PrtgManager.psm1') -Force -DisableNameChecking
        $mgr = Join-Path $Work 'stale-mgr'; New-Item -ItemType Directory -Force -Path $mgr | Out-Null
        Set-PmRoot -Path $mgr
        $stage = Join-Path (Get-PmPath Data) 'staging'
        New-Item -ItemType Directory -Force -Path (Join-Path $stage 'restore-decrypted-PRTG-FULL_X\PRTG') | Out-Null
        Set-Content -LiteralPath (Join-Path $stage 'decrypted-PRTG-FULL_X.zip') -Value 'x'
        New-Item -ItemType Directory -Force -Path (Join-Path $stage 'job-123') | Out-Null
        @(Clear-PmStaleDecrypted).Count | Should -Be 2
        Test-Path -LiteralPath (Join-Path $stage 'job-123') | Should -BeTrue -Because 'only decrypted copies are removed'
        & (Get-Module PrtgManager) { $script:PmJobs['j1'] = @{ id = 'j1'; type = 'restore'; status = 'running'; params = @{ BackupName = 'PRTG-FULL_X.pmenc' } } }
        try {
            Get-PmPackageUser -Name 'PRTG-FULL_X.pmenc' | Should -Be 'j1'
            { Start-PmJob -Type 'restore-preview' -Params @{ BackupName = 'PRTG-FULL_X.pmenc' } -Summary 'test' } | Should -Throw '*used by job j1*'
        } finally { & (Get-Module PrtgManager) { $script:PmJobs.Remove('j1') } }
        Get-PmPackageUser -Name 'PRTG-FULL_X.pmenc' | Should -Be ''
    }
    It 'a part restore that reports ok = false fails the command line and the dashboard job' {
        $cli = [IO.File]::ReadAllText((Join-Path $Root 'cli\Invoke-PrtgManager.ps1'))
        $restore = $cli.Substring($cli.IndexOf("'Restore' {")); $restore = $restore.Substring(0, $restore.IndexOf("'RemoveLicense' {"))
        $restore | Should -Match 'if \(-not \$r\.ok\) \{ \$exit = 2'
        $psm = [IO.File]::ReadAllText((Join-Path $Root 'src\PrtgManager.psm1'))
        $psm | Should -Match 'if \(\$r\.ok\) \{ Set-PmCheckpoint -Job \$Job -TargetDone \$id \}\s+else \{ \$failed\+\+'
    }
}