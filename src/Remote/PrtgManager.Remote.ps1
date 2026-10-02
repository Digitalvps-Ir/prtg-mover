<#
    PrtgManager.Remote.ps1
    ---------------------
    Functions executed *on the source / target server* inside a PowerShell remoting
    session opened by the manager. The whole file is shipped with every call, so it
    must stay self-contained (no module imports, no top-level param block) and
    compatible with Windows PowerShell 5.1.

    Every public function streams objects back to the manager:
      PmType = 'log'      -> a log line          (Level, Message)
      PmType = 'progress' -> a progress update   (Percent, Step)
      PmType = 'result'   -> the final result object
#>

$PmCoreService  = 'PRTGCoreService'
$PmProbeService = 'PRTGProbeService'

# Program-directory sub folders that may contain user customisations.
$PmProgramFolders = @(
    'Custom Sensors', 'Notifications', 'lookups\custom', 'devicetemplates',
    'MIB', 'snmplibs', 'cert', 'webroot\mapobjects', 'webroot\mapbackground',
    'webroot\mapicons', 'webroot\custom'
)

function Get-PmWorkRoot {
    <# Folder for PRTG Manager's own temporary files on this server. #>
    if ($env:PRTGMOVER_WORKROOT) { return $env:PRTGMOVER_WORKROOT.TrimEnd('\').TrimEnd('/') }
    if ($env:SystemDrive) { return (Join-Path $env:SystemDrive 'PrtgMover') }
    # PowerShell 7 on Linux has no SystemDrive. Keep the same folder name under temp.
    return (Join-Path ([IO.Path]::GetTempPath()) 'PrtgMover')
}

function Get-PmComputerName {
    if ($env:COMPUTERNAME) { return [string]$env:COMPUTERNAME }
    $n = [Environment]::MachineName
    if ($n) { return [string]$n }
    return 'localhost'
}

function Test-PmIsAdmin {
    <# True when the process is elevated. False on platforms without a Windows identity. #>
    try {
        $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
        return [bool]$principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { return $false }
}

function Get-PmCurrentUserName {
    try { return [string][Security.Principal.WindowsIdentity]::GetCurrent().Name } catch { return "$env:USERDOMAIN\$env:USERNAME" }
}

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
    <#
        Free space for a path. On Windows this is the Win32_LogicalDisk for the drive letter.
        Without CIM (PowerShell 7 on Linux) it uses the .NET volume that contains the path.
    #>
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

# ---------------------------------------------------------------- output helpers

function Write-PmLog {
    param([string]$Message, [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'STEP', 'DEBUG')][string]$Level = 'INFO')
    # A cancelled job drops everything it outputs: work done after the cancel (rollback) also goes to this file.
    if ($script:PmLogMirror) { try { [IO.File]::AppendAllText($script:PmLogMirror, ('{0} [{1}] {2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Level, $Message) + "`r`n") } catch { } }
    [pscustomobject]@{ PmType = 'log'; Level = $Level; Message = $Message; Time = (Get-Date).ToString('o'); Computer = (Get-PmComputerName) }
}

function Format-PmError {
    <# One-line error with the exact script position - used in logs so a failure can be located immediately. #>
    param($ErrorRecord)
    $pos = ''
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.ScriptLineNumber) {
        $pos = " [line $($ErrorRecord.InvocationInfo.ScriptLineNumber): $($ErrorRecord.InvocationInfo.Line.Trim())]"
    }
    return "$($ErrorRecord.Exception.GetType().Name): $($ErrorRecord.Exception.Message)$pos"
}

function Write-PmErrorDetail {
    <# Emits the full error (type, message, position, stack) as DEBUG log records. #>
    param($ErrorRecord, [string]$Context)
    Write-PmLog "$Context failed: $(Format-PmError $ErrorRecord)" 'DEBUG'
    if ($ErrorRecord.ScriptStackTrace) { Write-PmLog "Stack: $($ErrorRecord.ScriptStackTrace -replace '\r?\n', ' <- ')" 'DEBUG' }
    $inner = $ErrorRecord.Exception.InnerException
    while ($inner) { Write-PmLog "Inner: $($inner.GetType().Name): $($inner.Message)" 'DEBUG'; $inner = $inner.InnerException }
}

function Write-PmProgress {
    param([int]$Percent, [string]$Step)
    [pscustomobject]@{ PmType = 'progress'; Percent = $Percent; Step = $Step; Computer = $env:COMPUTERNAME }
}

function New-PmResult {
    param([hashtable]$Data)
    $Data['PmType'] = 'result'
    [pscustomobject]$Data
}

# ---------------------------------------------------------------- generic helpers

function Invoke-PmRobocopy {
    <# Copies a directory tree. Returns the robocopy exit code (0-7 = success). #>
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$ExcludeDirs = @(),
        [string[]]$ExcludeFiles = @(),
        [switch]$Mirror
    )
    if (-not (Test-Path -LiteralPath $Source)) { return -1 }
    if (-not (Get-Command robocopy.exe -ErrorAction SilentlyContinue)) {
        # Same copy, used when robocopy is not installed (PowerShell 7 on Linux).
        try {
            Copy-PmTreeFallback -Source $Source -Destination $Destination -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
            $global:PmLastRobocopy = "copy `"$Source`" -> `"$Destination`" (robocopy not installed)"
            return 1
        } catch {
            $global:PmLastRobocopy = "copy `"$Source`" -> `"$Destination`" failed: $($_.Exception.Message)"
            return 8
        }
    }
    # Redirected RDP drives (\\tsclient) do not support all directory attributes.
    $dcopy = if ($Destination.StartsWith('\\') -or $Source.StartsWith('\\')) { '/DCOPY:T' } else { '/DCOPY:DAT' }
    $rcArgs = @($Source.TrimEnd('\'), $Destination.TrimEnd('\'), '/COPY:DAT', $dcopy, '/R:2', '/W:2', '/MT:8', '/XJ', '/NP', '/NFL', '/NDL')
    if ($Mirror) { $rcArgs += '/MIR' } else { $rcArgs += '/E' }
    if ($ExcludeDirs.Count -gt 0) { $rcArgs += '/XD'; $rcArgs += $ExcludeDirs }
    if ($ExcludeFiles.Count -gt 0) { $rcArgs += '/XF'; $rcArgs += $ExcludeFiles }
    # Full robocopy log (summary + every error) for troubleshooting.
    if ($global:PmRobocopyLog) { $rcArgs += "/LOG+:$global:PmRobocopyLog" }
    & robocopy.exe @rcArgs | Out-Null
    $code = $LASTEXITCODE
    $global:PmLastRobocopy = "robocopy `"$Source`" -> `"$Destination`" exit $code"
    return $code
}

function Get-PmRobocopyErrors {
    <# Last error lines of the robocopy log (for error messages). #>
    if (-not $global:PmRobocopyLog -or -not (Test-Path -LiteralPath $global:PmRobocopyLog)) { return '' }
    $lines = @(Get-Content -LiteralPath $global:PmRobocopyLog -Tail 400 -ErrorAction SilentlyContinue | Where-Object { $_ -match 'ERROR|Access is denied|cannot|failed' } | Select-Object -Last 5)
    return ($lines -join ' | ')
}

function Copy-PmTreeFallback {
    <# Directory copy used only when robocopy.exe is absent. Honours the same exclude lists. #>
    param([string]$Source, [string]$Destination, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @())
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $blocked = @($ExcludeDirs | Where-Object { $_ } | ForEach-Object { $_.Replace('/', '\').TrimEnd('\') })
    foreach ($item in @(Get-ChildItem -LiteralPath $Source -Force -ErrorAction SilentlyContinue)) {
        $norm = $item.FullName.Replace('/', '\')
        if ($item.PSIsContainer) {
            $skip = $false
            foreach ($b in $blocked) {
                if ($norm.Equals($b, [StringComparison]::OrdinalIgnoreCase) -or $norm.StartsWith($b + '\', [StringComparison]::OrdinalIgnoreCase)) { $skip = $true; break }
            }
            if ($skip) { continue }
            Copy-PmTreeFallback -Source $item.FullName -Destination (Join-Path $Destination $item.Name) -ExcludeDirs $ExcludeDirs -ExcludeFiles $ExcludeFiles
        } else {
            $skipFile = $false
            foreach ($pat in @($ExcludeFiles)) { if ($pat -and $item.Name -like $pat) { $skipFile = $true; break } }
            if ($skipFile) { continue }
            Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Force
        }
    }
}

function Test-PmRobocopyOk { param([int]$Code) return ($Code -ge 0 -and $Code -lt 8) }

function Get-PmDirectorySize {
    param([string]$Path)
    # a folder this account may not read counts as empty instead of failing the caller
    try { if (-not (Test-Path -LiteralPath $Path -ErrorAction Stop)) { return 0 } } catch { return 0 }
    $sum = (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
    if ($sum) { return [int64]$sum } else { return 0 }
}

function Get-PmFileEncoding {
    <# Detects the BOM of a text file; files without BOM are treated as ANSI (what RAS writes). #>
    param([string]$Path)
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) { return [Text.Encoding]::Unicode }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { return New-Object Text.UTF8Encoding($true) }
    return [Text.Encoding]::Default
}

function Get-PmUserProfiles {
    <# Real (non-special) local user profiles: name + path. #>
    if (-not (Get-Command Get-CimInstance -ErrorAction SilentlyContinue)) { return @() }
    Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue |
        Where-Object { -not $_.Special -and $_.LocalPath -and (Test-Path -LiteralPath $_.LocalPath) } |
        ForEach-Object { [pscustomobject]@{ Name = (Split-Path $_.LocalPath -Leaf); Path = $_.LocalPath } }
}

function Initialize-PmTls {
    if (-not ('PmTrustAllPolicy' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Net;
using System.Security.Cryptography.X509Certificates;
public class PmTrustAllPolicy : ICertificatePolicy {
    public bool CheckValidationResult(ServicePoint sp, X509Certificate cert, WebRequest req, int problem) { return true; }
}
'@
    }
    [Net.ServicePointManager]::CertificatePolicy = New-Object PmTrustAllPolicy
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
}

# ---------------------------------------------------------------- backup encryption (password)
# Envelope (same layout everywhere PRTG Manager encrypts):
#   'PMENC1' | kdf (1 byte: 1 = PBKDF2-SHA256, 2 = PBKDF2-SHA1) | iterations (int32 LE) | salt (16) | IV (16) |
#   AES-256-CBC ciphertext (PKCS7) | HMAC-SHA256 (32 bytes) over everything before it.
# 64 bytes are derived from the password: the first 32 encrypt, the last 32 authenticate.

$PmEncMagic = [byte[]](0x50, 0x4D, 0x45, 0x4E, 0x43, 0x31)
$PmEncHeaderLength = 43   # 6 + 1 + 4 + 16 + 16

function Assert-PmBackupPassword {
    param([string]$Password)
    if (-not $Password -or $Password.Length -lt 8) { throw 'The backup password must have at least 8 characters.' }
}

function Get-PmDefaultKdf {
    <# PBKDF2 with SHA-256 where .NET offers it (4.7.2 and newer), otherwise PBKDF2 with SHA-1 and more rounds. #>
    try {
        $t = New-Object Security.Cryptography.Rfc2898DeriveBytes([byte[]](1, 2, 3, 4, 5, 6, 7, 8), [byte[]](1..16), 1, [Security.Cryptography.HashAlgorithmName]::SHA256)
        $t.Dispose()
        return @{ Kdf = 1; Iterations = 200000 }
    } catch { return @{ Kdf = 2; Iterations = 300000 } }
}

function Get-PmKeyMaterial {
    param([Parameter(Mandatory)][string]$Password, [Parameter(Mandatory)][byte[]]$Salt, [Parameter(Mandatory)][int]$Iterations, [Parameter(Mandatory)][int]$Kdf)
    $pw = [Text.Encoding]::UTF8.GetBytes($Password)
    if ($Kdf -eq 1) { $d = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $Salt, $Iterations, [Security.Cryptography.HashAlgorithmName]::SHA256) }
    elseif ($Kdf -eq 2) { $d = New-Object Security.Cryptography.Rfc2898DeriveBytes($pw, $Salt, $Iterations) }
    else { throw "Unknown key derivation $Kdf in the encrypted file." }
    try {
        $k = $d.GetBytes(64)
        return @{ Enc = [byte[]]$k[0..31]; Mac = [byte[]]$k[32..63] }
    } finally { $d.Dispose() }
}

function New-PmAes {
    param([byte[]]$Key, [byte[]]$IV)
    $aes = [Security.Cryptography.Aes]::Create()
    $aes.KeySize = 256; $aes.Mode = [Security.Cryptography.CipherMode]::CBC; $aes.Padding = [Security.Cryptography.PaddingMode]::PKCS7
    $aes.Key = $Key; $aes.IV = $IV
    return $aes
}

function Test-PmBytesEqual {
    <# Constant-time comparison of two byte arrays. #>
    param([byte[]]$A, [byte[]]$B)
    if ($null -eq $A -or $null -eq $B -or $A.Length -ne $B.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $A.Length; $i++) { $diff = $diff -bor ($A[$i] -bxor $B[$i]) }
    return ($diff -eq 0)
}

function New-PmEncHeader {
    param([int]$Kdf, [int]$Iterations, [byte[]]$Salt, [byte[]]$IV)
    $ms = New-Object IO.MemoryStream
    $ms.Write($PmEncMagic, 0, 6); $ms.WriteByte([byte]$Kdf)
    $it = [BitConverter]::GetBytes([int]$Iterations); $ms.Write($it, 0, 4)
    $ms.Write($Salt, 0, 16); $ms.Write($IV, 0, 16)
    return , $ms.ToArray()
}

function Read-PmEncHeader {
    <# Parses the header of an encrypted blob / file; throws a clear error when it is not one. #>
    param([Parameter(Mandatory)][byte[]]$Header)
    if ($Header.Length -lt $PmEncHeaderLength) { throw 'This is not a PRTG Manager encrypted file (too short).' }
    for ($i = 0; $i -lt 6; $i++) { if ($Header[$i] -ne $PmEncMagic[$i]) { throw 'This is not a PRTG Manager encrypted file (unknown header).' } }
    $kdf = [int]$Header[6]
    $iter = [BitConverter]::ToInt32($Header, 7)
    if ($kdf -notin 1, 2 -or $iter -lt 1000 -or $iter -gt 10000000) { throw 'The header of the encrypted file is damaged.' }
    return @{ Kdf = $kdf; Iterations = $iter; Salt = [byte[]]$Header[11..26]; IV = [byte[]]$Header[27..42] }
}

function Protect-PmBytes {
    <# Encrypts bytes with a password (see the envelope above). #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][byte[]]$Data, [Parameter(Mandatory)][string]$Password)
    Assert-PmBackupPassword $Password
    $k = Get-PmDefaultKdf
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($salt); $rng.GetBytes($iv) } finally { $rng.Dispose() }
    $km = Get-PmKeyMaterial -Password $Password -Salt $salt -Iterations $k.Iterations -Kdf $k.Kdf
    $aes = New-PmAes -Key $km.Enc -IV $iv
    try { $t = $aes.CreateEncryptor(); $ct = $t.TransformFinalBlock($Data, 0, $Data.Length); $t.Dispose() } finally { $aes.Dispose() }
    $head = New-PmEncHeader -Kdf $k.Kdf -Iterations $k.Iterations -Salt $salt -IV $iv
    $body = New-Object byte[] ($head.Length + $ct.Length)
    [Array]::Copy($head, 0, $body, 0, $head.Length); [Array]::Copy($ct, 0, $body, $head.Length, $ct.Length)
    $h = New-Object Security.Cryptography.HMACSHA256(, $km.Mac)
    try { $mac = $h.ComputeHash($body) } finally { $h.Dispose() }
    $out = New-Object byte[] ($body.Length + 32)
    [Array]::Copy($body, 0, $out, 0, $body.Length); [Array]::Copy($mac, 0, $out, $body.Length, 32)
    return , $out
}

function Unprotect-PmBytes {
    <# Decrypts an envelope. A wrong password and a changed file give the same, clear error. #>
    param([Parameter(Mandatory)][byte[]]$Envelope, [Parameter(Mandatory)][string]$Password)
    if ($Envelope.Length -lt ($PmEncHeaderLength + 16 + 32)) { throw 'The encrypted data is too short - the file is damaged.' }
    $hd = Read-PmEncHeader -Header ([byte[]]$Envelope[0..($PmEncHeaderLength - 1)])
    $km = Get-PmKeyMaterial -Password $Password -Salt $hd.Salt -Iterations $hd.Iterations -Kdf $hd.Kdf
    $bodyLen = $Envelope.Length - 32
    $h = New-Object Security.Cryptography.HMACSHA256(, $km.Mac)
    try { $mac = $h.ComputeHash($Envelope, 0, $bodyLen) } finally { $h.Dispose() }
    $stored = New-Object byte[] 32; [Array]::Copy($Envelope, $bodyLen, $stored, 0, 32)
    if (-not (Test-PmBytesEqual $mac $stored)) { throw 'The backup password is wrong or the file was changed (HMAC mismatch).' }
    $aes = New-PmAes -Key $km.Enc -IV $hd.IV
    try { $t = $aes.CreateDecryptor(); $pt = $t.TransformFinalBlock($Envelope, $PmEncHeaderLength, $bodyLen - $PmEncHeaderLength); $t.Dispose() } finally { $aes.Dispose() }
    return , $pt
}

function Protect-PmFile {
    <# Encrypts a file of any size in 1 MB steps into the same envelope format. #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Password)
    Assert-PmBackupPassword $Password
    $k = Get-PmDefaultKdf
    $salt = New-Object byte[] 16; $iv = New-Object byte[] 16
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create(); try { $rng.GetBytes($salt); $rng.GetBytes($iv) } finally { $rng.Dispose() }
    $km = Get-PmKeyMaterial -Password $Password -Salt $salt -Iterations $k.Iterations -Kdf $k.Kdf
    $head = New-PmEncHeader -Kdf $k.Kdf -Iterations $k.Iterations -Salt $salt -IV $iv
    $aes = New-PmAes -Key $km.Enc -IV $iv; $enc = $aes.CreateEncryptor()
    $hmac = New-Object Security.Cryptography.HMACSHA256(, $km.Mac)
    $in = [IO.File]::OpenRead($Source); $out = [IO.File]::Create($Destination)
    try {
        $out.Write($head, 0, $head.Length); [void]$hmac.TransformBlock($head, 0, $head.Length, $null, 0)
        $buf = New-Object byte[] (1MB); $cbuf = New-Object byte[] (1MB + 32)
        while ($true) {
            $n = 0
            while ($n -lt $buf.Length) { $r = $in.Read($buf, $n, $buf.Length - $n); if ($r -le 0) { break }; $n += $r }
            if ($in.Position -ge $in.Length) {
                $last = $enc.TransformFinalBlock($buf, 0, $n)
                $out.Write($last, 0, $last.Length); [void]$hmac.TransformBlock($last, 0, $last.Length, $null, 0)
                break
            }
            $c = $enc.TransformBlock($buf, 0, $n, $cbuf, 0)
            $out.Write($cbuf, 0, $c); [void]$hmac.TransformBlock($cbuf, 0, $c, $null, 0)
        }
        [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
        $out.Write($hmac.Hash, 0, 32)
    } finally { $in.Dispose(); $out.Dispose(); $enc.Dispose(); $aes.Dispose(); $hmac.Dispose() }
}

function Test-PmEncryptedFile {
    <# Checks the password and the integrity of an encrypted file (HMAC) without writing anything. Returns the header facts. #>
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Password)
    $in = [IO.File]::OpenRead($Path)
    try {
        if ($in.Length -lt ($PmEncHeaderLength + 16 + 32)) { throw 'The encrypted file is too short - it is damaged.' }
        $head = New-Object byte[] $PmEncHeaderLength; [void]$in.Read($head, 0, $PmEncHeaderLength)
        $hd = Read-PmEncHeader -Header $head
        $km = Get-PmKeyMaterial -Password $Password -Salt $hd.Salt -Iterations $hd.Iterations -Kdf $hd.Kdf
        $hmac = New-Object Security.Cryptography.HMACSHA256(, $km.Mac)
        try {
            [void]$hmac.TransformBlock($head, 0, $head.Length, $null, 0)
            $left = $in.Length - $PmEncHeaderLength - 32
            $buf = New-Object byte[] (1MB)
            while ($left -gt 0) { $r = $in.Read($buf, 0, [int][math]::Min($buf.Length, $left)); if ($r -le 0) { throw 'Unexpected end of the encrypted file.' }; [void]$hmac.TransformBlock($buf, 0, $r, $null, 0); $left -= $r }
            [void]$hmac.TransformFinalBlock((New-Object byte[] 0), 0, 0)
            $stored = New-Object byte[] 32; [void]$in.Read($stored, 0, 32)
            if (-not (Test-PmBytesEqual $hmac.Hash $stored)) { throw 'The backup password is wrong or the file was changed (HMAC mismatch).' }
        } finally { $hmac.Dispose() }
        return @{ Kdf = $hd.Kdf; Iterations = $hd.Iterations; Key = $km; IV = $hd.IV }
    } finally { $in.Dispose() }
}

function Unprotect-PmFile {
    <# Verifies (HMAC) first, then decrypts a file of any size. Nothing is written when the check fails. #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string]$Destination, [Parameter(Mandatory)][string]$Password)
    $t = Test-PmEncryptedFile -Path $Source -Password $Password
    $aes = New-PmAes -Key $t.Key.Enc -IV $t.IV; $dec = $aes.CreateDecryptor()
    $in = [IO.File]::OpenRead($Source); $out = [IO.File]::Create($Destination)
    try {
        [void]$in.Seek($PmEncHeaderLength, [IO.SeekOrigin]::Begin)
        $left = $in.Length - $PmEncHeaderLength - 32
        $buf = New-Object byte[] (1MB); $pbuf = New-Object byte[] (1MB + 32)
        while ($left -gt 0) {
            $want = [int][math]::Min($buf.Length, $left); $n = 0
            while ($n -lt $want) { $r = $in.Read($buf, $n, $want - $n); if ($r -le 0) { throw 'Unexpected end of the encrypted file.' }; $n += $r }
            $left -= $n
            if ($left -le 0) { $last = $dec.TransformFinalBlock($buf, 0, $n); $out.Write($last, 0, $last.Length) }
            else { $c = $dec.TransformBlock($buf, 0, $n, $pbuf, 0); $out.Write($pbuf, 0, $c) }
        }
    } catch { $out.Dispose(); Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue; throw }
    finally { $in.Dispose(); $out.Dispose(); $dec.Dispose(); $aes.Dispose() }
}

# ---------------------------------------------------------------- PRTG configuration: parts (devices, notifications, triggers)
# PRTG Configuration.dat is one XML file. Objects live in <nodes> elements and have a unique numeric id:
#   root/basenode/nodes/group[@id=0]          the device tree: probenode / group / device / sensor (each with data,
#                                             trigger, channels, history and its own <nodes>)
#   root/basenode/nodes/basenode[@id=-3]      notification templates      [@id=-7] schedules
#   root@max                                  the highest id handed out so far
# Triggers are <trigger> children of tree objects (state / threshold / speed / volume / change, each with an id).
# XmlElement properties can be shadowed by child elements (PowerShell adapter), so LocalName / methods are used.

$PmSectionTypes = 'devices', 'notifications', 'triggers'
$PmTreeObjectTypes = 'probenode', 'group', 'device', 'sensor', 'autodevice'
$PmTriggerRefFields = 'onnotificationid', 'escnotificationid', 'offnotificationid'

function ConvertTo-PmPackedText {
    <# Text -> gzip -> base64 (large XML crosses WinRM in one small object). #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $ms = New-Object IO.MemoryStream
    $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
    $b = [Text.Encoding]::UTF8.GetBytes($Text); $gz.Write($b, 0, $b.Length); $gz.Dispose()
    return [Convert]::ToBase64String($ms.ToArray())
}

function ConvertFrom-PmPackedText {
    param([Parameter(Mandatory)][string]$Packed)
    $in = New-Object IO.MemoryStream(, [Convert]::FromBase64String($Packed))
    $gz = New-Object IO.Compression.GZipStream($in, [IO.Compression.CompressionMode]::Decompress)
    $sr = New-Object IO.StreamReader($gz, [Text.Encoding]::UTF8)
    try { return $sr.ReadToEnd() } finally { $sr.Dispose() }
}
function Read-PmXmlText {
    <# XmlDocument from XML text (no DTDs, no external resources). #>
    param([Parameter(Mandatory)][string]$Text)
    $doc = New-Object Xml.XmlDocument
    $doc.PreserveWhitespace = $true; $doc.XmlResolver = $null
    $doc.LoadXml($Text)
    return , $doc
}

function Read-PmPrtgConfig {
    <# PRTG Configuration.dat as XmlDocument. Opened with FileShare.ReadWrite (PRTG may keep running); retried while PRTG writes it. #>
    param([Parameter(Mandatory)][string]$Path, [int]$Tries = 4)
    if (-not (Test-Path -LiteralPath $Path)) { throw "PRTG Configuration.dat not found: $Path" }
    for ($i = 1; $i -le $Tries; $i++) {
        $fs = $null
        try {
            $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            $doc = New-Object Xml.XmlDocument
            $doc.PreserveWhitespace = $true; $doc.XmlResolver = $null
            $doc.Load($fs)
            return , $doc
        } catch [Xml.XmlException] {
            if ($i -ge $Tries) { throw "PRTG Configuration.dat could not be read as XML after $Tries tries (PRTG may be writing it right now): $($_.Exception.Message)" }
            Start-Sleep -Seconds 5
        } finally { if ($fs) { $fs.Dispose() } }
    }
}

function ConvertTo-PmXmlBytes {
    <# XmlDocument -> UTF-8 bytes (optionally with BOM), whitespace kept as it is. #>
    param([Parameter(Mandatory)]$Doc, [bool]$Bom = $false)
    $ms = New-Object IO.MemoryStream
    $set = New-Object Xml.XmlWriterSettings
    $set.Encoding = New-Object Text.UTF8Encoding($Bom); $set.Indent = $false; $set.NewLineHandling = [Xml.NewLineHandling]::None
    $w = [Xml.XmlWriter]::Create($ms, $set)
    try { $Doc.Save($w) } finally { $w.Dispose() }
    return , $ms.ToArray()
}

function ConvertTo-PmXmlText { param([Parameter(Mandatory)]$Doc) return [Text.Encoding]::UTF8.GetString((ConvertTo-PmXmlBytes -Doc $Doc)) }

function Get-PmConfigHeader {
    <# Format version, PRTG version and highest id of a configuration (or of a saved part of one). #>
    param([Parameter(Mandatory)]$Doc)
    $r = $Doc.DocumentElement
    if ($r.LocalName -eq 'prtgmanagersection') {
        return [pscustomobject]@{ ConfigVersion = [int]('0' + $r.GetAttribute('configversion')); PrtgVersion = $r.GetAttribute('prtgversion'); Max = [int]('0' + $r.GetAttribute('max')); Guid = $r.GetAttribute('configguid') }
    }
    $oct = $r.GetAttribute('oct'); $ver = ''
    if ($oct -match '(\d+\.\d+\.\d+\.\d+)') { $ver = $Matches[1] }
    return [pscustomobject]@{ ConfigVersion = [int]('0' + $r.GetAttribute('version')); PrtgVersion = $ver; Max = [int]('0' + $r.GetAttribute('max')); Guid = $r.GetAttribute('guid') }
}

function Get-PmChildElement { param($Element, [string]$Name) foreach ($c in $Element.ChildNodes) { if ($c.NodeType -eq [Xml.XmlNodeType]::Element -and $c.LocalName -eq $Name) { return $c } }; return $null }

function Get-PmChildElements {
    param($Element)
    if (-not $Element) { return }
    foreach ($c in $Element.ChildNodes) { if ($c.NodeType -eq [Xml.XmlNodeType]::Element) { $c } }
}

function Get-PmObjectName {
    param($Element)
    $d = Get-PmChildElement $Element 'data'
    $n = $null
    if ($d) { $n = Get-PmChildElement $d 'name' }
    if (-not $n) { $n = Get-PmChildElement $Element 'name' }
    if ($n) { return $n.InnerText.Trim() }
    return ''
}

function Get-PmDataValue {
    <# Text of data/<field> of an object, trimmed; '' when missing. #>
    param($Element, [string]$Field)
    $d = Get-PmChildElement $Element 'data'
    if (-not $d) { return '' }
    $f = Get-PmChildElement $d $Field
    if ($f) { return $f.InnerText.Trim() }
    return ''
}

function Get-PmRefId {
    <# The id a reference field points to (its text starts with the id), or 0. #>
    param([string]$Text)
    if ($Text -match '^\s*(-?\d+)') { return [int]$Matches[1] }
    return 0
}

function Get-PmObjectId {
    <# Id of an object element, or $null for anything that is not an object (objects sit directly in <nodes>). #>
    param($Element)
    if (-not $Element -or $Element.NodeType -ne [Xml.XmlNodeType]::Element) { return $null }
    $id = $Element.GetAttribute('id')
    if ($id -eq '' -or -not $Element.ParentNode -or $Element.ParentNode.LocalName -ne 'nodes') { return $null }
    return [int]$id
}

function Get-PmConfigObjectMap {
    <# id -> element for every object of a configuration. #>
    param([Parameter(Mandatory)]$Doc)
    $map = @{}
    foreach ($e in $Doc.SelectNodes('//nodes/*[@id]')) { $map[[int]$e.GetAttribute('id')] = $e }
    return $map
}

function Get-PmConfigTreeRoot { param([Parameter(Mandatory)]$Doc) return $Doc.DocumentElement.SelectSingleNode("basenode/nodes/group[@id='0']") }

function Get-PmConfigContainer {
    <# The <nodes> element of a system folder: -3 notifications, -7 schedules, ... #>
    param([Parameter(Mandatory)]$Doc, [Parameter(Mandatory)][int]$Id)
    $bn = $Doc.DocumentElement.SelectSingleNode("basenode/nodes/basenode[@id='$Id']")
    if (-not $bn) { return $null }
    $n = Get-PmChildElement $bn 'nodes'
    if (-not $n) { $n = $Doc.CreateElement('nodes'); [void]$bn.AppendChild($n) }
    return $n
}

function Get-PmTreeObjects {
    <# Flat list of the device tree below (and including) $Root: Id, Type, Name, ParentId, Element (parents before children). #>
    param([Parameter(Mandatory)]$Root, [int]$ParentId = -1)
    $out = New-Object System.Collections.ArrayList
    $stack = New-Object System.Collections.Stack
    $stack.Push(@($Root, $ParentId))
    while ($stack.Count) {
        $pair = $stack.Pop(); $el = $pair[0]
        $id = [int]$el.GetAttribute('id')
        [void]$out.Add([pscustomobject]@{ Id = $id; Type = $el.LocalName; Name = (Get-PmObjectName $el); ParentId = [int]$pair[1]; Element = $el })
        $kids = Get-PmChildElement $el 'nodes'
        if ($kids) {
            $list = @(Get-PmChildElements $kids | Where-Object { $_.LocalName -in $PmTreeObjectTypes -and $_.GetAttribute('id') -ne '' })
            for ($i = $list.Count - 1; $i -ge 0; $i--) { $stack.Push(@($list[$i], $id)) }
        }
    }
    return $out
}

function New-PmSectionDocument {
    param([string]$Type, $Header)
    $out = New-Object Xml.XmlDocument
    $out.PreserveWhitespace = $true
    [void]$out.AppendChild($out.CreateXmlDeclaration('1.0', 'UTF-8', $null))
    $root = $out.CreateElement('prtgmanagersection'); [void]$out.AppendChild($root)
    $root.SetAttribute('type', $Type); $root.SetAttribute('format', '1')
    $root.SetAttribute('configversion', [string]$Header.ConfigVersion); $root.SetAttribute('prtgversion', [string]$Header.PrtgVersion)
    $root.SetAttribute('max', [string]$Header.Max); $root.SetAttribute('created', (Get-Date).ToUniversalTime().ToString('o'))
    if ($Header.Guid) { $root.SetAttribute('configguid', [string]$Header.Guid) }
    return , $out
}

function Export-PmConfigSection {
    <#
        One part of a PRTG configuration as its own XML document:
          devices       - the whole device tree (probes, groups, devices, sensors with their settings, triggers, channels)
          notifications - notification templates + all schedules (templates refer to schedules)
          triggers      - the triggers of every tree object, with the object's id, type and name
    #>
    param([Parameter(Mandatory)]$Doc, [Parameter(Mandatory)][ValidateSet('devices', 'notifications', 'triggers')][string]$Type)
    $out = New-PmSectionDocument -Type $Type -Header (Get-PmConfigHeader $Doc)
    $root = $out.DocumentElement
    switch ($Type) {
        'devices' {
            $tree = Get-PmConfigTreeRoot $Doc
            if (-not $tree) { throw 'The device tree (root group 0) was not found in PRTG Configuration.dat.' }
            $t = $out.CreateElement('tree'); [void]$root.AppendChild($t)
            [void]$t.AppendChild($out.ImportNode($tree, $true))
        }
        'notifications' {
            $n = $out.CreateElement('notifications'); [void]$root.AppendChild($n)
            $c = Get-PmConfigContainer -Doc $Doc -Id -3
            if ($c) { foreach ($x in (Get-PmChildElements $c)) { [void]$n.AppendChild($out.ImportNode($x, $true)) } }
            $s = $out.CreateElement('schedules'); [void]$root.AppendChild($s)
            $c = Get-PmConfigContainer -Doc $Doc -Id -7
            if ($c) { foreach ($x in (Get-PmChildElements $c)) { [void]$s.AppendChild($out.ImportNode($x, $true)) } }
        }
        'triggers' {
            $t = $out.CreateElement('triggers'); [void]$root.AppendChild($t)
            $tree = Get-PmConfigTreeRoot $Doc
            if ($tree) {
                foreach ($o in (Get-PmTreeObjects -Root $tree)) {
                    $tr = Get-PmChildElement $o.Element 'trigger'
                    if (-not $tr -or -not @(Get-PmChildElements $tr).Count) { continue }
                    $w = $out.CreateElement('object')
                    $w.SetAttribute('id', [string]$o.Id); $w.SetAttribute('type', $o.Type); $w.SetAttribute('name', $o.Name)
                    [void]$w.AppendChild($out.ImportNode($tr, $true))
                    [void]$t.AppendChild($w)
                }
            }
        }
    }
    return , $out
}

function Get-PmSectionSummary {
    <# Counts of a saved part: probes / groups / devices / sensors / triggers / notifications / schedules. #>
    param([Parameter(Mandatory)]$Section)
    $r = $Section.DocumentElement
    $c = [ordered]@{ type = $r.GetAttribute('type'); prtgVersion = $r.GetAttribute('prtgversion'); configVersion = $r.GetAttribute('configversion') }
    switch ($c.type) {
        'devices' {
            $treeRoot = @(Get-PmChildElements (Get-PmChildElement $r 'tree'))[0]
            $objs = @(); if ($treeRoot) { $objs = @(Get-PmTreeObjects -Root $treeRoot) }
            foreach ($t in 'probenode', 'group', 'device', 'sensor') { $c[$t] = @($objs | Where-Object { $_.Type -eq $t }).Count }
            $c.triggers = @($objs | ForEach-Object { Get-PmChildElements (Get-PmChildElement $_.Element 'trigger') } | Where-Object { $_ }).Count
        }
        'notifications' {
            $c.notifications = @(Get-PmChildElements (Get-PmChildElement $r 'notifications')).Count
            $c.schedules = @(Get-PmChildElements (Get-PmChildElement $r 'schedules')).Count
        }
        'triggers' {
            $objs = @(Get-PmChildElements (Get-PmChildElement $r 'triggers'))
            $c.objects = $objs.Count
            $c.triggers = @($objs | ForEach-Object { Get-PmChildElements (Get-PmChildElement $_ 'trigger') } | Where-Object { $_ }).Count
            $kinds = @{}
            foreach ($o in $objs) { foreach ($i in (Get-PmChildElements (Get-PmChildElement $o 'trigger'))) { $kinds[$i.LocalName] = 1 + [int]$kinds[$i.LocalName] } }
            $c.kinds = ($kinds.Keys | Sort-Object | ForEach-Object { "$_=$($kinds[$_])" }) -join ', '
        }
    }
    return [pscustomobject]$c
}

function Get-PmTriggerRefs {
    <# Notification ids used by the trigger items below an element (0 / negative = none). #>
    param($TriggerElement)
    $ids = @()
    foreach ($it in (Get-PmChildElements $TriggerElement)) {
        foreach ($f in $PmTriggerRefFields) { $v = Get-PmRefId (Get-PmDataValue $it $f); if ($v -gt 0) { $ids += $v } }
    }
    return @($ids | Select-Object -Unique)
}

function Get-PmSettingsXml {
    <#
        The settings of an object for comparison: data, trigger and channels (history and children excluded).
        Values PRTG stores encrypted (<cell crypt="...">: passwords, SNMP communities, comments) are masked:
        PRTG encrypts them again with fresh randomness on every save, so the same value never looks the same.
    #>
    param($Element)
    $sb = New-Object Text.StringBuilder
    foreach ($n in 'data', 'trigger', 'channels', 'notifies') {
        $e = Get-PmChildElement $Element $n
        if ($e) { [void]$sb.Append((ConvertTo-PmComparableXml $e.OuterXml)) }
    }
    return $sb.ToString()
}

# Fields PRTG keeps up to date by itself (timestamps, tree state in the web interface): not settings.
$PmVolatileFields = 'location_last_updated', 'lastdiscovery', 'treestate'

function ConvertTo-PmComparableXml {
    <#
        XML text in one canonical form for comparisons: encrypted cells masked, fields PRTG updates by itself
        left out, <x></x> written as <x />, whitespace collapsed. Two texts that mean the same compare equal.
    #>
    param([string]$Xml)
    $x = $Xml -replace '(<cell[^>]*\bcrypt="[^"]*"[^>]*>)[^<]*(</cell>)', '$1*$2'
    foreach ($v in $PmVolatileFields) { $x = [regex]::Replace($x, "<$v\b[^>]*?(?:/>|>.*?</$v>)", '', [Text.RegularExpressions.RegexOptions]::Singleline) }
    $x = $x -replace '>\s+<', '><'
    $x = $x -replace '<([\w\.:-]+)((?:\s[^<>]*?)?)\s*></\1>', '<$1$2 />'
    $x = $x -replace '\s*/>', ' />'
    return ($x -replace '\s+', ' ').Trim()
}

function New-PmPlanItem {
    param([int]$Id, [string]$Type, [string]$Name, [int]$ParentId, [string]$Action, [string]$Reason, [string]$Kind = 'object')
    return [pscustomobject][ordered]@{ Id = $Id; Type = $Type; Name = $Name; ParentId = $ParentId; Action = $Action; Reason = $Reason; Kind = $Kind; NewId = $null }
}

function Get-PmSectionRestorePlan {
    <#
        PURE. What restoring a saved part into a configuration would do - nothing is changed.
          Mode merge     : create what is missing, never change what exists (differences are conflicts)
          Mode overwrite : create what is missing, update existing objects with the saved settings
          ReIdConflicts  : objects whose id is taken by another object on the target are created with new ids
        Returns Type, Mode, Blockers, Warnings, Items (Action create | update | skip | conflict | create-new-id)
        and MissingDependencies.
    #>
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Section, [ValidateSet('merge', 'overwrite')][string]$Mode = 'merge', [bool]$ReIdConflicts = $false)
    $sr = $Section.DocumentElement
    if ($sr.LocalName -ne 'prtgmanagersection') { throw 'This is not a saved part of a PRTG configuration.' }
    $type = $sr.GetAttribute('type')
    if ($type -notin $PmSectionTypes) { throw "Unknown part type '$type'." }
    $th = Get-PmConfigHeader $Target; $sh = Get-PmConfigHeader $Section
    $plan = [ordered]@{ Type = $type; Mode = $Mode; ReIdConflicts = $ReIdConflicts; Blockers = @(); Warnings = @(); Items = New-Object System.Collections.ArrayList; MissingDependencies = @()
        Source = [ordered]@{ PrtgVersion = $sh.PrtgVersion; ConfigVersion = $sh.ConfigVersion }; Target = [ordered]@{ PrtgVersion = $th.PrtgVersion; ConfigVersion = $th.ConfigVersion } }
    if ($sh.ConfigVersion -gt $th.ConfigVersion) {
        $plan.Blockers += "The backup was made with a newer PRTG (configuration format $($sh.ConfigVersion), PRTG $($sh.PrtgVersion)) than the target has (format $($th.ConfigVersion), PRTG $($th.PrtgVersion)). Update PRTG on the target to $($sh.PrtgVersion) or newer first."
    } elseif ($sh.PrtgVersion -and $th.PrtgVersion -and $sh.PrtgVersion -ne $th.PrtgVersion) {
        $plan.Warnings += "The backup comes from PRTG $($sh.PrtgVersion), the target runs PRTG $($th.PrtgVersion). PRTG converts older settings when it starts."
    }
    if ($sh.Guid -and $th.Guid -and $sh.Guid -ne $th.Guid) {
        $plan.Warnings += 'The backup comes from another PRTG installation. PRTG stores passwords, SNMP communities and comments encrypted with a key of its own installation: in restored objects they may not be readable on the target - enter those credentials again there after the restore.'
    }
    $map = Get-PmConfigObjectMap $Target
    $created = @{}   # id -> $true for objects this plan creates (keeps their id)
    $pendingDeps = New-Object System.Collections.ArrayList
    $depNotes = @{}
    $noteDep = {
        param([string]$Key, [string]$Text)
        if (-not $depNotes.ContainsKey($Key)) { $depNotes[$Key] = $Text }
    }
    $checkRefs = {
        param($El, [string]$What)
        foreach ($nid in (Get-PmTriggerRefs (Get-PmChildElement $El 'trigger'))) {
            $t = $map[[int]$nid]
            if (-not $t -or $t.LocalName -ne 'notification') { & $noteDep "notification:$nid" "Notification template $nid (used by the triggers of $What) is not on the target - restore Notifications too, or the trigger sends nothing." }
        }
        $sid = Get-PmRefId (Get-PmDataValue $El 'schedule')
        if ($sid -gt 0) { $t = $map[[int]$sid]; if (-not $t -or $t.LocalName -ne 'schedule') { & $noteDep "schedule:$sid" "Schedule $sid (used by $What) is not on the target - restore Notifications (they include the schedules)." } }
        # checked after the whole plan: the dependency can be an object this plan creates later (e.g. its own sensor)
        $did = Get-PmRefId (Get-PmDataValue $El 'dependency')
        if ($did -gt 0) { [void]$pendingDeps.Add(@{ Id = [int]$did; What = $What }) }
    }

    switch ($type) {
        'devices' {
            $treeRoot = @(Get-PmChildElements (Get-PmChildElement $sr 'tree'))[0]
            if (-not $treeRoot) { throw 'The saved device tree is empty.' }
            $state = @{}   # id -> action of the saved objects (to decide about their children)
            foreach ($o in (Get-PmTreeObjects -Root $treeRoot)) {
                $what = "$($o.Type) '$($o.Name)' ($($o.Id))"
                $pAction = if ($o.ParentId -ge 0) { $state[$o.ParentId] } else { 'root' }
                if ($pAction -eq 'create-new-id' -or $pAction -eq 'inside-new-id') {
                    $state[$o.Id] = 'inside-new-id'; $created[[int]$o.Id] = $true
                    [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'create-new-id' -Reason 'comes with its parent, which gets a new id'))
                    & $checkRefs $o.Element $what; continue
                }
                if ($pAction -in 'conflict', 'skipped-parent') {
                    $state[$o.Id] = 'skipped-parent'
                    [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'skip' -Reason "its parent ($($o.ParentId)) is not restored"))
                    continue
                }
                $t = $map[[int]$o.Id]
                if (-not $t) {
                    $pExists = ($o.ParentId -lt 0) -or $map.ContainsKey([int]$o.ParentId) -or $created.ContainsKey([int]$o.ParentId)
                    if (-not $pExists) {
                        $state[$o.Id] = 'skipped-parent'
                        [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'skip' -Reason "its parent ($($o.ParentId)) is not on the target"))
                        continue
                    }
                    $state[$o.Id] = 'create'; $created[[int]$o.Id] = $true
                    [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'create' -Reason 'not on the target'))
                    & $checkRefs $o.Element $what; continue
                }
                $tName = Get-PmObjectName $t
                if ($t.LocalName -ne $o.Type -or ($tName -ne $o.Name -and $Mode -eq 'merge')) {
                    $why = if ($t.LocalName -ne $o.Type) { "id $($o.Id) is a $($t.LocalName) '$tName' on the target" } else { "id $($o.Id) is named '$tName' on the target" }
                    if ($ReIdConflicts -and $o.ParentId -ge 0) {
                        $state[$o.Id] = 'create-new-id'; $created[[int]$o.Id] = $true
                        [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'create-new-id' -Reason "$why - created with a new id (its history does not follow)"))
                        & $checkRefs $o.Element $what
                    } else {
                        $state[$o.Id] = 'conflict'
                        [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'conflict' -Reason "$why (ID conflict)"))
                    }
                    continue
                }
                $tParent = if ($t.ParentNode -and $t.ParentNode.ParentNode) { Get-PmObjectId $t.ParentNode.ParentNode } else { $null }
                $moved = ($o.ParentId -ge 0 -and $null -ne $tParent -and [int]$tParent -ne $o.ParentId)
                $same = ((Get-PmSettingsXml $t) -eq (Get-PmSettingsXml $o.Element))
                if ($Mode -eq 'merge' -or $same) {
                    $state[$o.Id] = 'skip'
                    $why = if ($same) { 'identical on the target' } else { 'already on the target (merge keeps it)' }
                    if ($moved) { $why += "; it is in another place on the target (parent $tParent)" }
                    [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'skip' -Reason $why))
                    continue
                }
                $state[$o.Id] = 'update'
                [void]$plan.Items.Add((New-PmPlanItem -Id $o.Id -Type $o.Type -Name $o.Name -ParentId $o.ParentId -Action 'update' -Reason $(if ($moved) { "settings differ; stays where it is on the target (parent $tParent)" } else { 'settings differ' })))
                & $checkRefs $o.Element $what
            }
        }
        'notifications' {
            $schedById = @{}
            foreach ($s in (Get-PmChildElements (Get-PmChildElement $sr 'schedules'))) { $schedById[[int]$s.GetAttribute('id')] = $s }
            $needSched = @{}
            foreach ($n in (Get-PmChildElements (Get-PmChildElement $sr 'notifications'))) {
                $id = [int]$n.GetAttribute('id'); $name = Get-PmObjectName $n
                $t = $map[$id]
                $sid = Get-PmRefId (Get-PmDataValue $n 'schedule')
                $act = $null
                if (-not $t) { $act = 'create'; $why = 'not on the target' }
                elseif ($t.LocalName -ne 'notification' -or ((Get-PmObjectName $t) -ne $name -and $Mode -eq 'merge')) {
                    $why = if ($t.LocalName -ne 'notification') { "id $id is a $($t.LocalName) on the target" } else { "id $id is named '$(Get-PmObjectName $t)' on the target" }
                    if ($ReIdConflicts) { $act = 'create-new-id'; $why += ' - created with a new id (triggers on the target keep pointing at the old one)' } else { $act = 'conflict'; $why += ' (ID conflict)' }
                } elseif ((Get-PmSettingsXml $t) -eq (Get-PmSettingsXml $n)) { $act = 'skip'; $why = 'identical on the target' }
                elseif ($Mode -eq 'merge') { $act = 'skip'; $why = 'already on the target (merge keeps it)' }
                else { $act = 'update'; $why = 'settings differ' }
                [void]$plan.Items.Add((New-PmPlanItem -Id $id -Type 'notification' -Name $name -ParentId -3 -Action $act -Reason $why))
                if ($act -in 'create', 'update', 'create-new-id' -and $sid -gt 0) { $needSched[$sid] = $name }
            }
            foreach ($sid in $needSched.Keys) {
                $t = $map[[int]$sid]
                if ($t -and $t.LocalName -eq 'schedule') { continue }
                if ($schedById.ContainsKey([int]$sid) -and -not $t) {
                    [void]$plan.Items.Add((New-PmPlanItem -Id $sid -Type 'schedule' -Name (Get-PmObjectName $schedById[[int]$sid]) -ParentId -7 -Action 'create' -Reason "used by notification '$($needSched[$sid])'" -Kind 'schedule'))
                } else { & $noteDep "schedule:$sid" "Schedule $sid (used by notification '$($needSched[$sid])') is not on the target and not in the backup." }
            }
        }
        'triggers' {
            foreach ($w in (Get-PmChildElements (Get-PmChildElement $sr 'triggers'))) {
                $oid = [int]$w.GetAttribute('id'); $otype = $w.GetAttribute('type'); $oname = $w.GetAttribute('name')
                $what = "$otype '$oname' ($oid)"
                $t = $map[$oid]
                $items = @(Get-PmChildElements (Get-PmChildElement $w 'trigger'))
                if (-not $t -or $t.LocalName -ne $otype) {
                    $why = if ($t) { "id $oid is a $($t.LocalName) on the target" } else { 'the object is not on the target' }
                    foreach ($i in $items) { [void]$plan.Items.Add((New-PmPlanItem -Id ([int]$i.GetAttribute('id')) -Type "$($i.LocalName) trigger" -Name $what -ParentId $oid -Action 'skip' -Reason $why -Kind 'trigger')) }
                    continue
                }
                $tt = Get-PmChildElement $t 'trigger'
                foreach ($i in $items) {
                    $iid = $i.GetAttribute('id')
                    $have = $null
                    if ($tt) { foreach ($x in (Get-PmChildElements $tt)) { if ($x.LocalName -eq $i.LocalName -and $x.GetAttribute('id') -eq $iid) { $have = $x; break } } }
                    if (-not $have) { $act = 'create'; $why = 'not on the target' }
                    elseif ((ConvertTo-PmComparableXml $have.OuterXml) -eq (ConvertTo-PmComparableXml $i.OuterXml)) { $act = 'skip'; $why = 'identical on the target' }
                    elseif ($Mode -eq 'merge') { $act = 'conflict'; $why = 'the target has a different trigger with this id (merge keeps it)' }
                    else { $act = 'update'; $why = 'settings differ' }
                    [void]$plan.Items.Add((New-PmPlanItem -Id ([int]$iid) -Type "$($i.LocalName) trigger" -Name $what -ParentId $oid -Action $act -Reason $why -Kind 'trigger'))
                    if ($act -in 'create', 'update') {
                        foreach ($f in $PmTriggerRefFields) {
                            $nid = Get-PmRefId (Get-PmDataValue $i $f)
                            if ($nid -gt 0) { $tn = $map[[int]$nid]; if (-not $tn -or $tn.LocalName -ne 'notification') { & $noteDep "notification:$nid" "Notification template $nid (used by a trigger of $what) is not on the target - restore Notifications too." } }
                        }
                    }
                }
            }
        }
    }
    foreach ($d in $pendingDeps) {
        if (-not $map.ContainsKey($d.Id) -and -not $created.ContainsKey($d.Id)) { & $noteDep "dependency:$($d.Id)" "Object $($d.Id) (the dependency of $($d.What)) is not on the target and not in the backup - PRTG removes the dependency." }
    }
    $plan.MissingDependencies = @($depNotes.Keys | Sort-Object | ForEach-Object { $depNotes[$_] })
    $items = @($plan.Items)
    $plan.Counts = [ordered]@{
        create = @($items | Where-Object { $_.Action -in 'create', 'create-new-id' }).Count; update = @($items | Where-Object Action -eq 'update').Count
        skip = @($items | Where-Object Action -eq 'skip').Count; conflict = @($items | Where-Object Action -eq 'conflict').Count
    }
    $plan.Items = $items
    return [pscustomobject]$plan
}

function Copy-PmSettings {
    <# Replaces data / trigger / channels / notifies of a target object with the saved ones (history and children stay). #>
    param($TargetElement, $SourceElement)
    $doc = $TargetElement.OwnerDocument
    foreach ($n in 'data', 'trigger', 'channels', 'notifies') {
        $src = Get-PmChildElement $SourceElement $n
        if (-not $src) { continue }
        $new = $doc.ImportNode($src, $true)
        $old = Get-PmChildElement $TargetElement $n
        if ($old) { [void]$TargetElement.ReplaceChild($new, $old) } else { [void]$TargetElement.PrependChild($new) }
    }
}

function Invoke-PmSectionMerge {
    <#
        Applies a restore plan to a configuration document in memory (the caller saves it).
        Returns counts and the id map of objects that got new ids.
    #>
    param([Parameter(Mandatory)]$Target, [Parameter(Mandatory)]$Section, [Parameter(Mandatory)]$Plan)
    $sr = $Section.DocumentElement
    $map = Get-PmConfigObjectMap $Target
    $max = [int]('0' + $Target.DocumentElement.GetAttribute('max'))
    foreach ($k in $map.Keys) { if ($k -gt $max) { $max = $k } }
    $done = [ordered]@{ created = 0; updated = 0; reIded = 0; skipped = 0; conflicts = 0 }
    $idMap = @{}
    $byId = @{}; foreach ($i in @($Plan.Items)) { $byId["$($i.Kind):$($i.Id):$($i.ParentId):$($i.Type)"] = $i }
    $getNodes = {
        param($Element)
        $n = Get-PmChildElement $Element 'nodes'
        if (-not $n) { $n = $Target.CreateElement('nodes'); [void]$Element.AppendChild($n) }
        return $n
    }
    switch ($Plan.Type) {
        'devices' {
            $treeRoot = @(Get-PmChildElements (Get-PmChildElement $sr 'tree'))[0]
            foreach ($o in (Get-PmTreeObjects -Root $treeRoot)) {
                $it = $byId["object:$($o.Id):$($o.ParentId):$($o.Type)"]
                if (-not $it) { continue }
                switch ($it.Action) {
                    'create' {
                        $parent = $map[[int]$o.ParentId]
                        if (-not $parent) { throw "Restore stopped: the parent $($o.ParentId) of $($o.Type) '$($o.Name)' does not exist." }
                        $new = $Target.ImportNode($o.Element, $true)
                        $kids = Get-PmChildElement $new 'nodes'
                        if ($kids) { foreach ($c in @(Get-PmChildElements $kids)) { [void]$kids.RemoveChild($c) } }
                        [void](& $getNodes $parent).AppendChild($new)
                        $map[[int]$o.Id] = $new; $done.created++
                    }
                    'update' { Copy-PmSettings -TargetElement $map[[int]$o.Id] -SourceElement $o.Element; $done.updated++ }
                    'create-new-id' {
                        $parentItem = @($Plan.Items | Where-Object { $_.Kind -eq 'object' -and $_.Id -eq $o.ParentId }) | Select-Object -First 1
                        if ($parentItem -and $parentItem.Action -eq 'create-new-id') { continue }   # came along with its parent
                        $parent = $map[[int]$o.ParentId]
                        if (-not $parent) { throw "Restore stopped: the parent $($o.ParentId) of $($o.Type) '$($o.Name)' does not exist." }
                        $new = $Target.ImportNode($o.Element, $true)
                        foreach ($e in @($new.SelectNodes('descendant-or-self::*[@id]'))) {
                            if ($e -ne $new -and (-not $e.ParentNode -or $e.ParentNode.LocalName -ne 'nodes')) { continue }
                            $old = [int]$e.GetAttribute('id'); $max++
                            $e.SetAttribute('id', [string]$max); $idMap[$old] = $max; $done.reIded++
                        }
                        foreach ($d in @($new.SelectNodes('descendant-or-self::data/dependency'))) {
                            $ref = Get-PmRefId $d.InnerText
                            if ($idMap.ContainsKey($ref)) { $d.InnerText = [string]$idMap[$ref] }
                        }
                        [void](& $getNodes $parent).AppendChild($new)
                    }
                    'skip' { $done.skipped++ }
                    'conflict' { $done.conflicts++ }
                }
            }
        }
        'notifications' {
            $nc = Get-PmConfigContainer -Doc $Target -Id -3
            $sc = Get-PmConfigContainer -Doc $Target -Id -7
            if (-not $nc -or -not $sc) { throw 'The target configuration has no notification / schedule folder.' }
            $src = @{}; foreach ($n in (Get-PmChildElements (Get-PmChildElement $sr 'notifications'))) { $src[[int]$n.GetAttribute('id')] = $n }
            $srcS = @{}; foreach ($n in (Get-PmChildElements (Get-PmChildElement $sr 'schedules'))) { $srcS[[int]$n.GetAttribute('id')] = $n }
            foreach ($it in @($Plan.Items | Where-Object Kind -eq 'schedule')) {
                if ($it.Action -ne 'create') { continue }
                $new = $Target.ImportNode($srcS[[int]$it.Id], $true); [void]$sc.AppendChild($new); $map[[int]$it.Id] = $new; $done.created++
            }
            foreach ($it in @($Plan.Items | Where-Object Kind -eq 'object')) {
                $s = $src[[int]$it.Id]
                switch ($it.Action) {
                    'create' { $new = $Target.ImportNode($s, $true); [void]$nc.AppendChild($new); $map[[int]$it.Id] = $new; $done.created++ }
                    'update' { Copy-PmSettings -TargetElement $map[[int]$it.Id] -SourceElement $s; $done.updated++ }
                    'create-new-id' { $new = $Target.ImportNode($s, $true); $max++; $idMap[[int]$it.Id] = $max; $new.SetAttribute('id', [string]$max); [void]$nc.AppendChild($new); $done.reIded++ }
                    'skip' { $done.skipped++ }
                    'conflict' { $done.conflicts++ }
                }
            }
        }
        'triggers' {
            $src = @{}; foreach ($w in (Get-PmChildElements (Get-PmChildElement $sr 'triggers'))) { $src[[int]$w.GetAttribute('id')] = $w }
            foreach ($it in @($Plan.Items)) {
                if ($it.Action -eq 'skip') { $done.skipped++; continue }
                if ($it.Action -eq 'conflict') { $done.conflicts++; continue }
                $obj = $map[[int]$it.ParentId]; $w = $src[[int]$it.ParentId]
                $kind = ($it.Type -split ' ')[0]
                $item = $null
                foreach ($x in (Get-PmChildElements (Get-PmChildElement $w 'trigger'))) { if ($x.LocalName -eq $kind -and [int]$x.GetAttribute('id') -eq $it.Id) { $item = $x; break } }
                if (-not $obj -or -not $item) { continue }
                $tt = Get-PmChildElement $obj 'trigger'
                if (-not $tt) { $tt = $Target.CreateElement('trigger'); [void]$obj.PrependChild($tt) }
                $new = $Target.ImportNode($item, $true)
                if ($it.Action -eq 'update') {
                    foreach ($x in (Get-PmChildElements $tt)) { if ($x.LocalName -eq $kind -and [int]$x.GetAttribute('id') -eq $it.Id) { [void]$tt.ReplaceChild($new, $x); break } }
                    $done.updated++
                } else { [void]$tt.AppendChild($new); $done.created++ }
            }
        }
    }
    $highest = $max
    foreach ($k in (Get-PmConfigObjectMap $Target).Keys) { if ($k -gt $highest) { $highest = $k } }
    if ($highest -gt [int]('0' + $Target.DocumentElement.GetAttribute('max'))) { $Target.DocumentElement.SetAttribute('max', [string]$highest) }
    return [pscustomobject]@{ Counts = [pscustomobject]$done; IdMap = $idMap; Max = $highest }
}

function Invoke-PmReg {
    <# Runs reg.exe without letting its stderr chatter turn into PowerShell errors. Returns the exit code. #>
    param([Parameter(Mandatory)][ValidateSet('export', 'import')][string]$Verb, [Parameter(Mandatory)][string]$File, [string]$Key)
    $argLine = if ($Verb -eq 'export') { "export `"$Key`" `"$File`" /y" } else { "import `"$File`"" }
    $sp = @{ FilePath = (Join-Path $env:SystemRoot 'System32\reg.exe'); ArgumentList = $argLine; Wait = $true; PassThru = $true }
    # -WindowStyle exists on Windows PowerShell 5.1. PowerShell 7 rejects it.
    if ($PSVersionTable.PSEdition -eq 'Desktop') { $sp.WindowStyle = 'Hidden' }
    $p = Start-Process @sp
    return $p.ExitCode
}

# ---------------------------------------------------------------- PRTG discovery / control

function Get-PmLocalIPv4 {
    <# IPv4 addresses of this machine (loopback included, link-local excluded). Works without the NetTCPIP module. #>
    $list = @()
    if (Get-Command Get-NetIPAddress -ErrorAction SilentlyContinue) {
        try { $list = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | ForEach-Object { [string]$_.IPAddress }) } catch { $list = @() }
    }
    if (-not $list.Count) {
        try {
            foreach ($nic in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
                foreach ($a in $nic.GetIPProperties().UnicastAddresses) {
                    if ($a.Address.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { $list += $a.Address.ToString() }
                }
            }
        } catch { }
    }
    return @($list | Where-Object { $_ -and $_ -notlike '169.254.*' } | Select-Object -Unique)
}

function Get-PmPrtgInfo {
    $info = [ordered]@{
        Installed = $false; Version = $null; ProgramPath = $null; DataPath = $null
        RegistryKeys = @(); CoreStatus = $null; ProbeStatus = $null; ListenPorts = @(); ListenEndpoints = @(); LocalAddresses = @()
    }
    $svc = $null
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $svc = Get-CimInstance Win32_Service -Filter "Name='$PmCoreService'" -ErrorAction SilentlyContinue
    }
    if ($svc) {
        $info.Installed = $true
        $exe = $svc.PathName
        if ($exe -match '^"([^"]+)"') { $exe = $Matches[1] } elseif ($exe -match '^(.+?\.exe)') { $exe = $Matches[1] }
        $info.ProgramPath = Split-Path $exe -Parent
        # PRTG 64-bit installs run the core from "<install dir>\64 bit\PRTG Server.exe" -
        # customisations (Custom Sensors, Notifications, lookups, cert...) live in the install dir itself.
        if ((Split-Path $info.ProgramPath -Leaf) -eq '64 bit') { $info.ProgramPath = Split-Path $info.ProgramPath -Parent }
        if (Test-Path -LiteralPath $exe) { $info.Version = (Get-Item -LiteralPath $exe).VersionInfo.FileVersion }
        $info.CoreStatus = [string]$svc.State
    }
    $probe = $null
    if (Get-Command Get-Service -ErrorAction SilentlyContinue) {
        $probe = Get-Service -Name $PmProbeService -ErrorAction SilentlyContinue
    }
    if ($probe) { $info.ProbeStatus = [string]$probe.Status }

    foreach ($k in 'HKLM:\SOFTWARE\WOW6432Node\Paessler', 'HKLM:\SOFTWARE\Paessler') {
        if (Test-Path $k) { $info.RegistryKeys += $k }
    }
    $dp = $null
    foreach ($core in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Core', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Core') {
        if (-not $dp -and (Test-Path $core)) { $dp = (Get-ItemProperty -Path $core -ErrorAction SilentlyContinue).Datapath }
    }
    if (-not $dp -and $env:ProgramData) { $dp = Join-Path $env:ProgramData 'Paessler\PRTG Network Monitor' }
    $info.DataPath = if ($dp) { $dp.TrimEnd('\').TrimEnd('/') } else { $null }

    $proc = Get-Process -Name 'PRTG Server' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($proc) {
        $listen = @()
        if (Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue) { $listen = @(Get-NetTCPConnection -State Listen -OwningProcess $proc.Id -ErrorAction SilentlyContinue) }
        $info.ListenPorts = @($listen | Select-Object -ExpandProperty LocalPort -Unique | Sort-Object)
        # address:port pairs show whether the web server is bound to all addresses or only to specific ones
        $info.ListenEndpoints = @($listen | Sort-Object LocalPort, LocalAddress | ForEach-Object { '{0}:{1}' -f $_.LocalAddress, $_.LocalPort } | Select-Object -Unique)
    }
    $info.LocalAddresses = @(Get-PmLocalIPv4 | Where-Object { $_ -notlike '127.*' })
    return [pscustomobject]$info
}

function Stop-PmPrtgServices {
    param([int]$TimeoutMinutes = 15)
    foreach ($name in $PmProbeService, $PmCoreService) {
        $s = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($s -and $s.Status -ne 'Stopped') {
            Stop-Service -Name $name -Force -ErrorAction Stop
            $s.WaitForStatus('Stopped', [TimeSpan]::FromMinutes($TimeoutMinutes))
        }
    }
    # The core writes the configuration on shutdown; make sure the process is really gone.
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Process -Name 'PRTG Server', 'PRTG Probe' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Seconds 2 }
}

function Start-PmPrtgServices {
    foreach ($name in $PmCoreService, $PmProbeService) {
        if (Get-Service -Name $name -ErrorAction SilentlyContinue) {
            Set-Service -Name $name -StartupType Automatic
            Start-Service -Name $name -ErrorAction Stop
        }
    }
}

function Test-PmPrtgWeb {
    <# Returns the first URL that answers with any HTTP response, or $null. #>
    param([int[]]$Ports)
    Initialize-PmTls
    $candidates = @()
    foreach ($p in $Ports) { $candidates += "https://localhost:$p/"; $candidates += "http://localhost:$p/" }
    foreach ($url in $candidates) {
        try {
            $r = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 10 -ErrorAction Stop
            return "$url (HTTP $($r.StatusCode))"
        } catch [System.Net.WebException] {
            if ($_.Exception.Response) { return "$url (HTTP $([int]$_.Exception.Response.StatusCode))" }
        } catch { }
    }
    return $null
}

function Wait-PmPrtgHealthy {
    <#
        Brings PRTG fully up and proves it: both services Running, the core answering
        HTTP(S), and everything still running after a stability window. A service that
        stops/crashes during start-up is restarted (up to $MaxRestarts times).
        Emits log records; the last object is PmType='health'.
    #>
    param([int]$TimeoutMinutes = 15, [int[]]$PreferredPorts = @(), [int]$StableSeconds = 45, [int]$MaxRestarts = 2)
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    $restarts = 0; $url = $null; $healthy = $false; $msg = ''
    foreach ($n in $PmCoreService, $PmProbeService) {
        if (Get-Service -Name $n -ErrorAction SilentlyContinue) { Set-Service -Name $n -StartupType Automatic }
    }
    while ((Get-Date) -lt $deadline -and -not $healthy) {
        foreach ($n in $PmCoreService, $PmProbeService) {
            $s = Get-Service -Name $n -ErrorAction SilentlyContinue
            if ($s -and $s.Status -eq 'Stopped') {
                if ($restarts -ge ($MaxRestarts + 2)) { continue }   # +2: the initial starts
                $restarts++
                Write-PmLog "Starting service $n (attempt $restarts)..."
                try { Start-Service -Name $n -ErrorAction Stop } catch { Write-PmLog "Start-Service $n failed: $($_.Exception.Message)" 'WARN' }
            }
        }
        Start-Sleep -Seconds 10
        $info = Get-PmPrtgInfo
        if ($info.CoreStatus -ne 'Running' -or ($info.ProbeStatus -and $info.ProbeStatus -ne 'Running')) { $msg = "core=$($info.CoreStatus) probe=$($info.ProbeStatus)"; continue }
        $ports = @($info.ListenPorts) + @($PreferredPorts) + @(443, 80, 8443, 8080) | Where-Object { $_ } | Select-Object -Unique
        $url = Test-PmPrtgWeb -Ports $ports
        if (-not $url) { $msg = 'services running, web interface not answering yet'; continue }
        Write-PmLog "Web interface answers at $url - verifying stability for $StableSeconds s..."
        Start-Sleep -Seconds $StableSeconds
        $info = Get-PmPrtgInfo
        if ($info.CoreStatus -eq 'Running' -and (-not $info.ProbeStatus -or $info.ProbeStatus -eq 'Running') -and (Test-PmPrtgWeb -Ports $ports)) { $healthy = $true }
        else { $msg = "became unstable (core=$($info.CoreStatus) probe=$($info.ProbeStatus))"; Write-PmLog "PRTG $msg - retrying." 'WARN' }
    }
    $final = Get-PmPrtgInfo
    [pscustomobject]@{ PmType = 'health'; Healthy = $healthy; Url = $url; Core = $final.CoreStatus; Probe = $final.ProbeStatus; Message = $msg; Version = $final.Version }
}

function Invoke-PmHealthCheck {
    <# Runs Wait-PmPrtgHealthy, forwarding its logs, and returns the health object via $Box.Health. #>
    param([hashtable]$Box, [int]$TimeoutMinutes = 15, [int[]]$PreferredPorts = @())
    Wait-PmPrtgHealthy -TimeoutMinutes $TimeoutMinutes -PreferredPorts $PreferredPorts | ForEach-Object {
        if ($_.PmType -eq 'health') { $Box.Health = $_ } else { $_ }
    }
}

# ---------------------------------------------------------------- configuration statistics

function Get-PmPrtgConfigStats {
    <#
        Streams PRTG Configuration.dat (XML) and counts the main object types. Used to show
        what is being moved (devices, sensors, notification templates, triggers, users,
        schedules, maps, reports, libraries) and to compare source and target.
        Read-only, opened with FileShare.ReadWrite so a running PRTG is not disturbed.
    #>
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    $names = [ordered]@{ probenode = 'probes'; group = 'groups'; device = 'devices'; sensor = 'sensors'; notification = 'notifications'; trigger = 'triggers'
        user = 'users'; usergroup = 'user groups'; schedule = 'schedules'; map = 'maps'; report = 'reports'; library = 'libraries'; dependency = 'dependencies' }
    $count = @{}
    foreach ($k in $names.Keys) { $count[$k] = 0 }
    $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $settings = New-Object Xml.XmlReaderSettings
        $settings.DtdProcessing = [Xml.DtdProcessing]::Ignore
        $settings.IgnoreComments = $true; $settings.IgnoreWhitespace = $true
        $reader = [Xml.XmlReader]::Create($fs, $settings)
        try {
            while ($reader.Read()) {
                if ($reader.NodeType -ne [Xml.XmlNodeType]::Element) { continue }
                $n = $reader.LocalName.ToLowerInvariant()
                if ($count.ContainsKey($n)) { $count[$n]++ }
                elseif ($n -like '*trigger' -and $n -ne 'triggers') { $count['trigger']++ }
            }
        } finally { $reader.Dispose() }
    } catch { return "unreadable ($($_.Exception.Message))" } finally { $fs.Dispose() }
    return (($names.Keys | Where-Object { $count[$_] -gt 0 } | ForEach-Object { "$($names[$_])=$($count[$_])" }) -join ', ')
}

# ---------------------------------------------------------------- VSS snapshots (no-touch backups)

function New-PmShadowCopy {
    <# Creates a VSS snapshot of the volume holding $Path and links it to a folder. Server OS only. #>
    param([Parameter(Mandatory)][string]$Path)
    $volume = (Split-Path $Path -Qualifier) + '\'
    $r = (Get-WmiObject -List Win32_ShadowCopy).Create($volume, 'ClientAccessible')
    if ($r.ReturnValue -ne 0) { throw "VSS snapshot of $volume failed (code $($r.ReturnValue))." }
    $sc = Get-WmiObject Win32_ShadowCopy -Filter "ID='$($r.ShadowID)'"
    $link = Join-Path $env:SystemDrive ('PrtgMoverVss_' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    cmd.exe /c "mklink /d `"$link`" `"$($sc.DeviceObject)\`"" | Out-Null
    if (-not (Test-Path -LiteralPath $link)) { $sc.Delete(); throw 'Could not mount the VSS snapshot.' }
    [pscustomobject]@{ Id = $sc.ID; Link = $link; Volume = $volume }
}

function Clear-PmStaleSnapshots {
    <#
        Removes VSS snapshots that PRTG Manager itself created in an earlier, interrupted run
        (recognised by their C:\PrtgMoverVss_* link). Other snapshots are never touched.
    #>
    $removed = 0
    foreach ($link in (Get-ChildItem -LiteralPath ($env:SystemDrive + '\') -Filter 'PrtgMoverVss_*' -Force -ErrorAction SilentlyContinue)) {
        try {
            $target = [string]($link.Target | Select-Object -First 1)
            if ($target) {
                $dev = $target.TrimEnd('\')
                foreach ($sc in @(Get-WmiObject Win32_ShadowCopy -ErrorAction SilentlyContinue)) {
                    if ($sc.DeviceObject -and $dev.EndsWith(($sc.DeviceObject -replace '^\\\\\?\\', ''), [StringComparison]::OrdinalIgnoreCase)) { $sc.Delete() }
                }
            }
            cmd.exe /c "rmdir `"$($link.FullName)`"" | Out-Null
            $removed++
        } catch { Write-PmLog "Could not remove stale snapshot link $($link.FullName): $($_.Exception.Message)" 'WARN' }
    }
    if ($removed) { Write-PmLog "Removed $removed snapshot(s) left behind by interrupted runs." 'OK' }
}

function Remove-PmShadowCopy {
    param($Shadow)
    if (-not $Shadow) { return }
    cmd.exe /c "rmdir `"$($Shadow.Link)`"" | Out-Null
    $sc = Get-WmiObject Win32_ShadowCopy -Filter "ID='$($Shadow.Id)'"
    if ($sc) { $sc.Delete() }
}

# ---------------------------------------------------------------- PRTG license

function Get-PmLicenseValues {
    <# All registry values below the Paessler keys whose name contains "licen" (name, path, kind, value). #>
    $out = @()
    foreach ($root in 'HKLM:\SOFTWARE\WOW6432Node\Paessler', 'HKLM:\SOFTWARE\Paessler') {
        if (-not (Test-Path $root)) { continue }
        $keys = @(Get-Item -LiteralPath $root) + @(Get-ChildItem -LiteralPath $root -Recurse -ErrorAction SilentlyContinue)
        foreach ($k in $keys) {
            foreach ($name in $k.GetValueNames()) {
                if ($name -match 'licen') {
                    $out += [pscustomobject]@{ Path = $k.PSPath; Name = $name; Kind = $k.GetValueKind($name); Value = $k.GetValue($name, $null, 'DoNotExpandEnvironmentNames') }
                }
            }
        }
    }
    return $out
}

function Get-PmShortHash {
    <# First 10 hex digits of the SHA-256 of a text: lets two servers be compared without showing the value. #>
    param([string]$Text)
    if (-not $Text) { return '' }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { return (-join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Text)) | ForEach-Object { $_.ToString('x2') })).Substring(0, 10) } finally { $sha.Dispose() }
}

function Get-PmPrtgLicenseReport {
    <#
        READ-ONLY. What is known about the PRTG license on this server, without showing the key:
          - the license related registry values as fingerprints (compare source and target)
          - the system id fingerprint (PRTG licenses are activated per system id)
          - the latest license / activation lines of the core log, with keys masked
    #>
    param([int]$Days = 4, [int]$MaxLines = 40)
    $prtg = Get-PmPrtgInfo
    $report = [ordered]@{ Installed = $prtg.Installed; Values = @(); SystemId = ''; AutoActivation = $null; LogFile = $null; LogLines = @() }
    if (-not $prtg.Installed) { return [pscustomobject]$report }
    $report.Values = @(Get-PmLicenseValues | ForEach-Object {
            $v = if ($_.Value -is [byte[]]) { [Convert]::ToBase64String($_.Value) } else { [string]$_.Value }
            '{0}={1}' -f $_.Name, $(if ($v) { "#$(Get-PmShortHash $v) ($($v.Length) chars)" } else { '<empty>' })
        })
    foreach ($core in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Core', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Core') {
        if (-not (Test-Path $core)) { continue }
        $p = Get-ItemProperty -Path $core -ErrorAction SilentlyContinue
        if ($p.SystemId) { $report.SystemId = "#$(Get-PmShortHash ([string]$p.SystemId))" }
        if ($null -ne $p.AutoActivation) { $report.AutoActivation = [int]$p.AutoActivation }
        break
    }
    $logDir = Join-Path $prtg.DataPath 'Logs'
    if (Test-Path -LiteralPath $logDir) {
        $since = (Get-Date).AddDays(-$Days)
        $files = @(Get-ChildItem -LiteralPath $logDir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since -and ($_.Name -match 'core' -or $_.DirectoryName -match '\\core$') } | Sort-Object LastWriteTime)
        $hits = New-Object System.Collections.ArrayList
        foreach ($lf in $files) {
            try {
                $fs = New-Object IO.FileStream($lf.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
                # only the last 20 MB of a log are read
                if ($fs.Length -gt 20MB) { [void]$fs.Seek(-20MB, [IO.SeekOrigin]::End) }
                $sr = New-Object IO.StreamReader($fs)
                try {
                    while (-not $sr.EndOfStream) {
                        $line = $sr.ReadLine()
                        if ($line -match '(?i)licen|activat|edition|system ?id|trial|freeware|subscription|maintenance|sensor limit|exceed') { [void]$hits.Add(("{0}: {1}" -f $lf.Name, $line)) }
                    }
                } finally { $sr.Dispose(); $fs.Dispose() }
                $report.LogFile = $lf.FullName
            } catch { }
        }
        $report.LogLines = @($hits | Select-Object -Last $MaxLines | ForEach-Object {
                $l = $_ -replace '[0-9A-Za-z]{6}(-[0-9A-Za-z]{6}){3,}', '<key>' -replace '(?i)SYSTEMID-[0-9A-Z-]+', 'SYSTEMID-<masked>'
                if ($l.Length -gt 260) { $l.Substring(0, 260) + ' ...' } else { $l }
            })
    }
    return [pscustomobject]$report
}

function ConvertTo-PmLicenseState {
    <#
        Turns the license lines of the PRTG core log into a short state:
        Edition, Name, MaxSensors, NeedsActivation, LastError. Pure function (testable).
    #>
    param([string[]]$LogLines = @(), [string]$PausedByLicense)
    $state = [ordered]@{ Known = $false; Edition = $null; Name = $null; MaxSensors = $null; NeedsActivation = $false; LastError = $null; PausedByLicense = $PausedByLicense }
    $lic = @($LogLines | Where-Object { $_ -match 'licensed for "' } | Select-Object -Last 1)
    if ($lic.Count -and $lic[0] -match '>\s*PRTG\s+(?<edition>.*?)\s*licensed for "(?<name>[^"]*)".*?Edt=(?<edt>-?\d+)\s+MaxS=(?<max>\d+)') {
        $edition = $Matches.edition.Trim(); $name = $Matches.name; $edt = [int]$Matches.edt; $max = [int]$Matches.max
        if ($edition -match '^\((?<inner>[^()]*)\)$') { $edition = $Matches.inner }
        $state.Known = $true
        $state.Edition = $edition
        $state.Name = $name
        $state.MaxSensors = $max
        $state.NeedsActivation = ($edition -match '(?i)no license|system changed' -or $edt -lt 0 -or $max -eq 0)
    }
    $err = @($LogLines | Where-Object { $_ -match '(?i)activation done .*error|new activation required|activation failed' } | Select-Object -Last 1)
    if ($err.Count) { $state.LastError = ($err[0] -replace '^.*?>\s*', '').Trim() }
    return [pscustomobject]$state
}

function Get-PmPrtgLicenseState {
    <# READ-ONLY. Short license state of the PRTG on this server (from the registry and the core log). #>
    $rep = Get-PmPrtgLicenseReport -Days 3 -MaxLines 400
    $paused = $null
    $pv = @(Get-PmLicenseValues | Where-Object { $_.Name -eq 'SensorCountPausedByLicenseMax' } | Select-Object -First 1)
    if ($pv.Count) { $paused = [string]$pv[0].Value }
    return (ConvertTo-PmLicenseState -LogLines @($rep.LogLines) -PausedByLicense $paused)
}

function Remove-PmPrtgLicense {
    <#
        Removes the PRTG license from THIS server: license name, key and the activation hash of
        that key in the registry, and license files in the data folder. PRTG is stopped first,
        because the core writes its settings back when it stops. A copy of what is removed is
        kept in <work root>\rollback\license-<timestamp>.
        Nothing else is changed: system id, configuration and monitoring data stay as they are.
    #>
    param([int]$HealthTimeoutMinutes = 10, [bool]$StartServices = $true)
    $ErrorActionPreference = 'Stop'
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server.' }
    $describe = { param($s) if ($s -and $s.Known) { "$($s.Edition), licensed for `"$($s.Name)`", $($s.MaxSensors) sensors" } else { 'no license line in the core log' } }
    $before = Get-PmPrtgLicenseState
    Write-PmLog "License before: $(& $describe $before)"
    $values = @(Get-PmLicenseValues | Where-Object { $_.Name -in $PmLicenseOwnValues })
    $files = @(Get-PmLicenseFiles -DataPath $prtg.DataPath)
    if (-not $values.Count -and -not $files.Count) {
        Write-PmLog 'There is no license on this server (no license name, key or activation) - nothing to remove.' 'OK'
        return (New-PmResult @{ Removed = @(); Rollback = $null; Before = $before; After = $before; Healthy = $null; WebUrl = $null; Core = $prtg.CoreStatus })
    }

    Write-PmProgress 10 'Saving a copy of the license data'
    $keep = Join-Path (Get-PmWorkRoot) ('rollback\license-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $keep | Out-Null
    foreach ($k in @($prtg.RegistryKeys)) {
        $native = $k -replace '^HKLM:\\', 'HKLM\'
        if ((Invoke-PmReg -Verb export -Key $native -File (Join-Path $keep (($native -replace '[\\: ]', '_') + '.reg'))) -ne 0) { throw "Could not save a copy of $native - nothing was removed." }
    }
    foreach ($f in $files) { Copy-Item -LiteralPath $f.FullName -Destination $keep -Force }
    Write-PmLog "Copy of the license data (to undo this): $keep" 'OK'

    Write-PmProgress 25 'Stopping PRTG'
    Write-PmLog 'Stopping PRTG (license data can only be removed while the core is stopped)...' 'STEP'
    Stop-PmPrtgServices
    Write-PmProgress 45 'Removing license data'
    $removed = @()
    foreach ($v in @(Get-PmLicenseValues | Where-Object { $_.Name -in $PmLicenseOwnValues })) {
        Remove-ItemProperty -LiteralPath $v.Path -Name $v.Name -ErrorAction Stop
        $removed += $v.Name
    }
    foreach ($f in @(Get-PmLicenseFiles -DataPath $prtg.DataPath)) { Remove-Item -LiteralPath $f.FullName -Force -ErrorAction Stop; $removed += $f.Name }
    $left = @(Get-PmLicenseValues | Where-Object { $_.Name -in $PmLicenseOwnValues } | ForEach-Object { $_.Name })
    if ($left.Count) { throw "These license values could not be removed: $($left -join ', ')" }
    Write-PmLog "Removed: $(@($removed | Select-Object -Unique) -join ', ')" 'OK'

    $health = $null
    if ($StartServices) {
        Write-PmProgress 60 'Starting PRTG'
        Write-PmLog 'Starting PRTG without a license...' 'STEP'
        $box = @{}
        Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
        $health = $box.Health
        if ($health.Healthy) { Write-PmLog "PRTG is running: $($health.Url). Enter a license in PRTG under Setup > License Information." 'OK' }
        else { Write-PmLog "PRTG did not come up completely without a license ($($health.Message)). Enter a license with the PRTG Administration Tool on the server, or restore the copy in $keep." 'WARN' }
    }
    $after = Get-PmPrtgLicenseState
    $back = @(Get-PmLicenseValues | Where-Object { $_.Name -in 'LicenseKey', 'LicenseName' -and [string]$_.Value } | ForEach-Object { $_.Name })
    if ($back.Count) { Write-PmLog "PRTG wrote these values again while starting: $($back -join ', ')" 'WARN' }
    Write-PmLog "License after: $(& $describe $after)"
    Write-PmProgress 100 'Done'
    New-PmResult @{
        Removed = @($removed | Select-Object -Unique); Rollback = $keep; Before = $before; After = $after; WrittenAgain = $back
        Healthy = $(if ($health) { [bool]$health.Healthy }); WebUrl = $(if ($health) { $health.Url }); Core = (Get-PmPrtgInfo).CoreStatus
    }
}

# The license itself: what the PRTG Administration Tool writes and PRTG's activation of that key. PRTG's own
# bookkeeping (LicenseInstalled = first install date, SensorCountPausedByLicenseMax) is not part of it and is
# never removed - removing the install date could look like resetting a trial.
$PmLicenseOwnValues = 'LicenseName', 'LicenseKey', 'LicenseHash'

function Get-PmLicenseFiles {
    param([string]$DataPath)
    if (-not (Test-Path -LiteralPath $DataPath)) { return @() }
    @(Get-ChildItem -LiteralPath $DataPath -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'licen' })
}

# ---------------------------------------------------------------- web server binding

function Get-PmReboundIpList {
    <# "a,b" -> the same list with addresses that do not exist locally replaced by $Own; 127.0.0.1 is always kept. #>
    param([string]$Current, [string[]]$Local = @(), [string]$Own, [switch]$AddOwn)
    $new = @()
    foreach ($ip in ($Current -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        if ($ip -eq '127.0.0.1' -or $Local -contains $ip) { $new += $ip } elseif ($Own) { $new += $Own }
    }
    # -AddOwn: PRTG itself drops addresses it cannot bind at start-up, leaving only 127.0.0.1.
    if ($AddOwn -and $Own -and -not @($new | Where-Object { $_ -ne '127.0.0.1' }).Count) { $new = @($Own) + $new }
    if ($new -notcontains '127.0.0.1') { $new += '127.0.0.1' }
    return (@($new | Select-Object -Unique) -join ',')
}

function Set-PmPrtgWebBinding {
    <#
        The PRTG web server can be bound to specific IP addresses (registry: Server\Webserver,
        UseIPs = owioSpecIPs, IPs = "a,b"). After a migration those are the SOURCE's addresses;
        PRTG then only listens on 127.0.0.1. Addresses that do not exist on this server are
        replaced by this server's own address. Nothing is changed when every address exists.
    #>
    param([string]$TargetAddress, [bool]$AddOwn = $false, [bool]$CheckOnly = $false)
    $local = @(Get-PmLocalIPv4)
    $own = if ($TargetAddress -and $local -contains $TargetAddress) { $TargetAddress }
    else { $local | Where-Object { $_ -ne '127.0.0.1' -and $_ -notmatch '^(10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)' } | Select-Object -First 1 }
    if (-not $own) { $own = $local | Where-Object { $_ -ne '127.0.0.1' } | Select-Object -First 1 }
    $changed = $false; $before = $null; $after = $null
    foreach ($key in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Webserver', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Webserver') {
        if (-not (Test-Path $key)) { continue }
        $p = Get-ItemProperty -Path $key -ErrorAction SilentlyContinue
        if ($p.UseIPs -ne 'owioSpecIPs' -or -not $p.IPs) { continue }
        $before = [string]$p.IPs
        $after = Get-PmReboundIpList -Current $before -Local $local -Own $own -AddOwn:$AddOwn
        if ($after -ne $before) { if (-not $CheckOnly) { Set-ItemProperty -Path $key -Name 'IPs' -Value $after }; $changed = $true }
    }
    if ($CheckOnly) { return [pscustomobject]@{ PmType = 'binding'; Changed = $changed; Before = $before; After = $after } }
    if ($changed) { Write-PmLog "PRTG web server binding changed from '$before' to '$after' (addresses of this server)." 'OK' }
    elseif ($before) { Write-PmLog "PRTG web server binding is valid for this server ($before)." 'OK' }
    else { Write-PmLog 'PRTG web server listens on all addresses (no specific binding).' 'OK' }
    [pscustomobject]@{ PmType = 'binding'; Changed = $changed; Before = $before; After = $after }
}

function Repair-PmPrtgBinding {
    <# Fixes the web server binding of an already migrated PRTG, restarts it and verifies it is fully up. #>
    param([string]$TargetAddress, [int]$HealthTimeoutMinutes = 15)
    $ErrorActionPreference = 'Stop'
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server.' }
    Write-PmLog "PRTG currently listens on: $(@($prtg.ListenEndpoints) -join ', ')"
    Write-PmProgress 10 'Adjusting web server binding'
    $bx = @{ B = (Set-PmPrtgWebBinding -TargetAddress $TargetAddress -AddOwn $true -CheckOnly $true) }
    $health = $null
    if (-not $bx.B.Changed) { Write-PmLog "PRTG web server binding needs no change ($($bx.B.Before))." 'OK' }
    if ($bx.B.Changed) {
        # Order matters: the core writes its settings back to the registry when it stops,
        # so the binding must be changed while PRTG is stopped.
        Write-PmProgress 20 'Stopping PRTG'
        Write-PmLog 'Stopping PRTG (the binding can only be changed while the core is stopped)...' 'STEP'
        Stop-PmPrtgServices
        Write-PmProgress 40 'Adjusting web server binding'
        Set-PmPrtgWebBinding -TargetAddress $TargetAddress -AddOwn $true | ForEach-Object { if ($_.PmType -eq 'binding') { $bx.B = $_ } else { $_ } }
        Write-PmProgress 50 'Starting PRTG'
        $box = @{}
        Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
        $health = $box.Health
        if (-not $health.Healthy) { throw "PRTG did not come up completely after the restart ($($health.Message))." }
    }
    $after = Get-PmPrtgInfo
    $outside = @($after.ListenEndpoints | Where-Object { $_ -notmatch '^(127\.0\.0\.1|::1):' })
    $reg = (Get-ItemProperty -Path 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Webserver' -ErrorAction SilentlyContinue)
    Write-PmLog "Registry after start: UseIPs=$($reg.UseIPs) IPs=$($reg.IPs) Ports=$($reg.Ports)" 'DEBUG'
    if ($outside.Count) { Write-PmLog "PRTG now listens on: $(@($after.ListenEndpoints) -join ', ')" 'OK' }
    else { Write-PmLog "PRTG still only listens on this server itself: $(@($after.ListenEndpoints) -join ', ') (registry IPs=$($reg.IPs)). Set the web server IP in the PRTG Administration Tool on the server." 'ERROR' }
    Write-PmProgress 100 'Done'
    New-PmResult @{ Changed = $bx.B.Changed; Before = $bx.B.Before; After = $bx.B.After; ListenEndpoints = @($after.ListenEndpoints); Core = $after.CoreStatus; Probe = $after.ProbeStatus }
}

# ---------------------------------------------------------------- firewall

function Set-PmPrtgFirewall {
    <# Opens inbound TCP for the PRTG web ports and the remote-probe port (23560). #>
    param([int[]]$Ports)
    $ports = @($Ports) + 23560 | Where-Object { $_ } | Select-Object -Unique | Sort-Object
    $name = 'PRTG Manager - PRTG Core (web + probes)'
    Get-NetFirewallRule -DisplayName $name -ErrorAction SilentlyContinue | Remove-NetFirewallRule
    New-NetFirewallRule -DisplayName $name -Direction Inbound -Protocol TCP -LocalPort $ports -Action Allow -Profile Any | Out-Null
    return $ports
}

# ---------------------------------------------------------------- system info (Test)

function Get-PmSystemInfo {
    $osCaption = Get-PmOsCaption
    $osVersion = [Environment]::OSVersion.Version.ToString()
    $isAdmin = Test-PmIsAdmin
    $userName = Get-PmCurrentUserName
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        try { $osVersion = [string](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).Version } catch { }
    }
    $prtg = Get-PmPrtgInfo
    $dataSize = 0; $stats = $null
    if ($prtg.Installed) {
        $dataSize = Get-PmDirectorySize -Path $prtg.DataPath
        $stats = Get-PmPrtgConfigStats -Path (Join-Path $prtg.DataPath 'PRTG Configuration.dat')
    }
    $disks = @()
    if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
        $disks = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' -ErrorAction SilentlyContinue | ForEach-Object {
                [pscustomobject]@{ Drive = $_.DeviceID; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) } })
    } else {
        $disks = @(Get-PmLogicalDisk -Path (Get-PmWorkRoot) | Where-Object { $_ } | ForEach-Object {
                [pscustomobject]@{ Drive = $_.DeviceID; SizeGB = [math]::Round($_.Size / 1GB, 1); FreeGB = [math]::Round($_.FreeSpace / 1GB, 1) } })
    }

    New-PmResult @{
        Computer     = $env:COMPUTERNAME
        OS           = $osCaption
        OSVersion    = $osVersion
        IsAdmin      = $isAdmin
        User         = $userName
        Prtg         = $prtg
        PrtgDataGB   = [math]::Round($dataSize / 1GB, 2)
        PrtgConfigStats = $stats
        PrtgLicense  = $(if ($prtg.Installed) { try { Get-PmPrtgLicenseReport } catch { [pscustomobject]@{ Error = "$($_.Exception.Message)" } } })
        PrtgLicenseState = $(if ($prtg.Installed) { try { Get-PmPrtgLicenseState } catch { $null } })
        Profiles     = @(Get-PmUserProfiles | Select-Object -ExpandProperty Name)
        Disks        = $disks
        SystemDrive  = $env:SystemDrive
        RdpPort      = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' -ErrorAction SilentlyContinue).PortNumber
        PSVersion    = $PSVersionTable.PSVersion.ToString()
    }
}

# ---------------------------------------------------------------- configuration parts: backup and restore on a server

function Get-PmPrtgConfigPath {
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found).' }
    return (Join-Path $prtg.DataPath 'PRTG Configuration.dat')
}

function Get-PmPrtgSection {
    <#
        READ-ONLY. One part of the PRTG configuration of this server (devices, notifications or triggers)
        as XML text. PRTG keeps running; nothing is written on this server.
    #>
    param([Parameter(Mandatory)][ValidateSet('devices', 'notifications', 'triggers')][string]$Type)
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found).' }
    $cfg = Join-Path $prtg.DataPath 'PRTG Configuration.dat'
    Write-PmLog "Reading $cfg - PRTG keeps running, nothing on this server is changed." 'STEP'
    $doc = Read-PmPrtgConfig -Path $cfg
    $sec = Export-PmConfigSection -Doc $doc -Type $Type
    $sum = Get-PmSectionSummary -Section $sec
    $text = ConvertTo-PmXmlText -Doc $sec
    Write-PmLog ("Part '{0}' read: {1}" -f $Type, (($sum.PSObject.Properties | Where-Object { $_.Name -notin 'type' } | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ', ')) 'OK'
    New-PmResult @{ Type = $Type; Packed = (ConvertTo-PmPackedText $text); Summary = $sum; Header = (Get-PmConfigHeader $doc); PrtgVersion = $prtg.Version; Computer = $env:COMPUTERNAME; Os = (Get-PmOsCaption) }
}

function Save-PmPrtgConfig {
    <# Writes a configuration document over PRTG Configuration.dat (same BOM as before), via a temp file that is parsed again first. #>
    param([Parameter(Mandatory)]$Doc, [Parameter(Mandatory)][string]$Path)
    $orig = [IO.File]::ReadAllBytes($Path)
    $bom = ($orig.Length -ge 3 -and $orig[0] -eq 0xEF -and $orig[1] -eq 0xBB -and $orig[2] -eq 0xBF)
    $tmp = "$Path.pm-new"
    [IO.File]::WriteAllBytes($tmp, (ConvertTo-PmXmlBytes -Doc $Doc -Bom $bom))
    [void](Read-PmPrtgConfig -Path $tmp -Tries 1)   # must parse, or nothing is replaced
    Copy-Item -LiteralPath $tmp -Destination $Path -Force
    Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
}

function Get-PmSectionRestorePreview {
    <# READ-ONLY. What restoring a saved part would do on this server. #>
    param([Parameter(Mandatory)][string]$Packed, [ValidateSet('merge', 'overwrite')][string]$Mode = 'merge', [bool]$ReIdConflicts = $false)
    $cfg = Get-PmPrtgConfigPath
    $target = Read-PmPrtgConfig -Path $cfg
    $section = Read-PmXmlText -Text (ConvertFrom-PmPackedText $Packed)
    $plan = Get-PmSectionRestorePlan -Target $target -Section $section -Mode $Mode -ReIdConflicts $ReIdConflicts
    Write-PmLog ("Preview ({0}, {1}): {2} to create, {3} to update, {4} unchanged, {5} conflict(s), {6} missing dependenc(ies)." -f $plan.Type, $Mode, $plan.Counts.create, $plan.Counts.update, $plan.Counts.skip, $plan.Counts.conflict, @($plan.MissingDependencies).Count) 'OK'
    New-PmResult @{ Plan = $plan; Prtg = (Get-PmPrtgInfo) }
}

function Invoke-PmSectionRestore {
    <#
        Restores a saved part (devices, notifications or triggers) into the PRTG of this server:
          1. plan against the current configuration (blockers stop here, nothing changed)
          2. rollback copy of PRTG Configuration.dat into <work root>\rollback\config-<time>
          3. PRTG stopped (the core writes its configuration when it stops), plan made again on that state
          4. merge in memory, written via a temp file that must parse, then PRTG started and checked
          5. PRTG does not come up -> the rollback copy is put back and PRTG started again
    #>
    param(
        [Parameter(Mandatory)][string]$Packed, [ValidateSet('merge', 'overwrite')][string]$Mode = 'merge', [bool]$ReIdConflicts = $false,
        [bool]$StartServices = $true, [int]$HealthTimeoutMinutes = 15, [bool]$AllowConflicts = $true
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmIsAdmin)) { throw 'Restoring into PRTG needs administrator rights on this server.' }
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found).' }
    $cfg = Join-Path $prtg.DataPath 'PRTG Configuration.dat'
    $section = Read-PmXmlText -Text (ConvertFrom-PmPackedText $Packed)
    Write-PmProgress 5 'Planning'
    $plan = Get-PmSectionRestorePlan -Target (Read-PmPrtgConfig -Path $cfg) -Section $section -Mode $Mode -ReIdConflicts $ReIdConflicts
    if (@($plan.Blockers).Count) { throw "Nothing was changed: $(@($plan.Blockers) -join ' ')" }
    if (-not $AllowConflicts -and $plan.Counts.conflict) { throw "Nothing was changed: $($plan.Counts.conflict) conflict(s) - see the preview." }
    if (-not ($plan.Counts.create + $plan.Counts.update)) {
        Write-PmLog "Nothing to restore: every item is already on this server or in conflict ($($plan.Counts.skip) unchanged, $($plan.Counts.conflict) conflict(s)). PRTG was not stopped." 'OK'
        return (New-PmResult @{ Plan = $plan; Applied = $null; Rollback = $null; Healthy = $null; RolledBack = $false; Changed = $false })
    }
    Write-PmProgress 15 'Saving a rollback copy'
    $rb = Join-Path (Get-PmWorkRoot) ('rollback\config-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $rb | Out-Null
    $wasRunning = ($prtg.CoreStatus -eq 'Running')
    Write-PmLog "Stopping PRTG (the configuration can only be changed while the core is stopped)..." 'STEP'
    Write-PmProgress 25 'Stopping PRTG'
    $applied = $null; $health = $null; $rolledBack = $false; $err = $null; $settled = $false; $copied = $false
    try {
        Stop-PmPrtgServices
        Copy-Item -LiteralPath $cfg -Destination (Join-Path $rb 'PRTG Configuration.dat') -Force
        $copied = $true
        Write-PmLog "Rollback copy: $rb\PRTG Configuration.dat" 'OK'
        Write-PmProgress 40 'Merging'
        $target = Read-PmPrtgConfig -Path $cfg
        $plan = Get-PmSectionRestorePlan -Target $target -Section $section -Mode $Mode -ReIdConflicts $ReIdConflicts
        if (@($plan.Blockers).Count) { throw (@($plan.Blockers) -join ' ') }
        $applied = Invoke-PmSectionMerge -Target $target -Section $section -Plan $plan
        Save-PmPrtgConfig -Doc $target -Path $cfg
        Write-PmLog ("Configuration written: {0} created, {1} updated, {2} with new ids, {3} unchanged, {4} conflict(s) left as they are." -f $applied.Counts.created, $applied.Counts.updated, $applied.Counts.reIded, $applied.Counts.skipped, $applied.Counts.conflicts) 'OK'
        Write-PmLog "Configuration now: $(Get-PmPrtgConfigStats -Path $cfg)" 'INFO'
        if ($StartServices -or $wasRunning) {
            Write-PmProgress 60 'Starting PRTG'
            $box = @{}
            Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
            $health = $box.Health
            if (-not $health.Healthy) { throw "PRTG did not come up completely with the restored configuration ($($health.Message))." }
            Write-PmLog "PRTG is up with the restored configuration: $($health.Url)" 'OK'
        }
        $settled = $true
    } catch {
        $err = "$($_.Exception.Message)"
        Write-PmLog "Restore failed: $err - putting the rollback copy back." 'ERROR'
        try {
            Stop-PmPrtgServices
            if ($copied) { Copy-Item -LiteralPath (Join-Path $rb 'PRTG Configuration.dat') -Destination $cfg -Force; $rolledBack = $true }
            if ($wasRunning) {
                $box = @{}; Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts); $health = $box.Health
                Write-PmLog "Rolled back. PRTG is $(if ($health.Healthy) { "up again with the previous configuration: $($health.Url)" } else { "NOT up ($($health.Message)) - check the core log" })." $(if ($health.Healthy) { 'WARN' } else { 'ERROR' })
            } else { Write-PmLog 'Rolled back (PRTG was stopped before and stays stopped).' 'WARN' }
        } catch { Write-PmLog "Rollback failed too: $($_.Exception.Message). The previous configuration is in $rb." 'ERROR' }
        $settled = $true
    } finally {
        if (-not $settled) {
            # cancelled while PRTG was stopped: the previous configuration goes back and PRTG is started again
            $script:PmLogMirror = Join-Path $rb 'cancelled.log'
            try {
                Write-PmLog 'The restore was cancelled while PRTG was stopped - putting the previous configuration back.' 'WARN' | Out-Null
                Stop-PmPrtgServices
                if ($copied) { Copy-Item -LiteralPath (Join-Path $rb 'PRTG Configuration.dat') -Destination $cfg -Force }
                if ($wasRunning) { Start-PmPrtgServices }
                Write-PmLog "Previous configuration is back$(if ($wasRunning) { ', PRTG started' })." 'OK' | Out-Null
            } catch { Write-PmLog "Putting the previous configuration back failed: $($_.Exception.Message). It is in $rb." 'ERROR' | Out-Null }
            finally { $script:PmLogMirror = $null }
        }
    }
    Write-PmProgress 100 'Done'
    New-PmResult @{ Plan = $plan; Applied = $(if ($applied) { $applied.Counts }); Rollback = $rb; Healthy = $(if ($health) { [bool]$health.Healthy }); WebUrl = $(if ($health) { $health.Url }); RolledBack = $rolledBack; Error = $err; Changed = (-not $rolledBack -and -not $err) }
}

# ---------------------------------------------------------------- history (graph data)

function Get-PmGraphFiles {
    <# Files of Monitoring Database below $Root: relative path, day, device id, size. Days older than $Days are left out (0 = all). #>
    param([Parameter(Mandatory)][string]$Root, [int]$Days = 0)
    if (-not (Test-Path -LiteralPath $Root)) { return }
    $from = if ($Days -gt 0) { (Get-Date).Date.AddDays(-$Days).ToString('yyyyMMdd') } else { '00000000' }
    $base = (Get-Item -LiteralPath $Root).FullName.TrimEnd('\')
    foreach ($f in (Get-ChildItem -LiteralPath $Root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $rel = $f.FullName.Substring($base.Length + 1)
        $day = ''; if ($rel -match '^(\d{8})\\') { $day = $Matches[1] }
        if ($day -and $day -lt $from) { continue }
        $dev = 0; if ($f.Name -match '^Device (\d+)\.') { $dev = [int]$Matches[1] }
        [pscustomobject]@{ Rel = $rel; Day = $day; Device = $dev; Size = $f.Length }
    }
}

function Get-PmGraphDayFolders {
    <# Day folders older than $Days (to exclude from a history backup). #>
    param([Parameter(Mandatory)][string]$Root, [int]$Days)
    if ($Days -le 0 -or -not (Test-Path -LiteralPath $Root)) { return }
    $from = (Get-Date).Date.AddDays(-$Days).ToString('yyyyMMdd')
    Get-ChildItem -LiteralPath $Root -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match '^\d{8}$' -and $_.Name -lt $from } | ForEach-Object { $_.FullName }
}

function Get-PmGraphRestorePlan {
    <#
        PURE. What restoring history files would do: files that are new, that exist already (kept in merge,
        replaced in overwrite) and files of devices the target configuration does not have (their history
        would not be shown). $TargetFiles = relative paths already on the target; $TargetDevices = device ids.
    #>
    param([object[]]$Files, [string[]]$TargetFiles = @(), [int[]]$TargetDevices = @(), [ValidateSet('merge', 'overwrite')][string]$Mode = 'merge')
    $have = @{}; foreach ($t in @($TargetFiles)) { if ($t) { $have[$t.ToLowerInvariant()] = $true } }
    $devs = @{}; foreach ($d in @($TargetDevices)) { $devs[[int]$d] = $true }
    $new = 0; $exist = 0; $newBytes = [int64]0; $unknown = @{}
    foreach ($f in @($Files)) {
        if (-not $f) { continue }
        if ($have.ContainsKey(([string]$f.Rel).ToLowerInvariant())) { $exist++ } else { $new++; $newBytes += [int64]$f.Size }
        if ([int]$f.Device -gt 0 -and -not $devs.ContainsKey([int]$f.Device)) { $unknown[[int]$f.Device] = 1 + [int]$unknown[[int]$f.Device] }
    }
    $warn = @()
    if ($unknown.Count) { $warn += "History of $($unknown.Count) device(s) that are not in the target configuration ($((@($unknown.Keys | Sort-Object) | Select-Object -First 15) -join ', ')): PRTG does not show it until devices with these ids exist (restore Devices first)." }
    [pscustomobject]@{
        Mode = $Mode; Files = @($Files).Count; New = $new; Existing = $exist; NewBytes = $newBytes
        Replace = $(if ($Mode -eq 'overwrite') { $exist } else { 0 }); Keep = $(if ($Mode -eq 'merge') { $exist } else { 0 })
        UnknownDevices = @($unknown.Keys | Sort-Object); Warnings = $warn
    }
}

function Get-PmGraphTargetFacts {
    <# READ-ONLY. History files and device ids of this server (for the graph restore preview). #>
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found).' }
    $root = Join-Path $prtg.DataPath 'Monitoring Database'
    $files = @(Get-PmGraphFiles -Root $root | ForEach-Object { $_.Rel })
    $devices = @()
    try { $doc = Read-PmPrtgConfig -Path (Join-Path $prtg.DataPath 'PRTG Configuration.dat'); $devices = @($doc.SelectNodes('//nodes/*[@id][self::device or self::autodevice or self::probenode]') | ForEach-Object { [int]$_.GetAttribute('id') }) } catch { Write-PmLog "Device ids could not be read: $($_.Exception.Message)" 'WARN' }
    New-PmResult @{ Files = $files; Devices = $devices; Prtg = $prtg }
}

function Restore-PmGraphData {
    <#
        Copies history files of a package into Monitoring Database of this server with PRTG stopped:
        merge keeps files that exist, overwrite replaces them. The graph cache is moved aside so PRTG
        recalculates the graphs from the data. Nothing is deleted.
    #>
    param([Parameter(Mandatory)][string]$StageGraphs, [ValidateSet('merge', 'overwrite')][string]$Mode = 'merge', [bool]$StartServices = $true, [int]$HealthTimeoutMinutes = 15,
        # the stage is a disposable local copy: move the files (no extra disk space) instead of copying them
        [bool]$Move = $false)
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found).' }
    $dest = Join-Path $prtg.DataPath 'Monitoring Database'
    $files = @(Get-PmGraphFiles -Root $StageGraphs)
    $plan = Get-PmGraphRestorePlan -Files $files -TargetFiles @(Get-PmGraphFiles -Root $dest | ForEach-Object { $_.Rel }) -Mode $Mode
    Write-PmLog ("History: {0} file(s) in the package, {1} new, {2} already on this server ({3})." -f $plan.Files, $plan.New, $plan.Existing, $(if ($Mode -eq 'overwrite') { 'replaced' } else { 'kept' })) 'INFO'
    foreach ($w in $plan.Warnings) { Write-PmLog $w 'WARN' }
    if (($Mode -eq 'merge' -and -not $plan.New) -or -not $plan.Files) {
        Write-PmLog 'Nothing to copy - every history file of the package is already on this server. PRTG was not stopped.' 'OK'
        return [pscustomobject]@{ PmType = 'graphs'; Copied = 0; Replaced = 0; Failed = 0; Plan = $plan; Healthy = $true; WebUrl = $null }
    }
    $wasRunning = ($prtg.CoreStatus -eq 'Running')
    Write-PmLog 'Stopping PRTG (history files are only written while the core is stopped)...' 'STEP'
    Stop-PmPrtgServices
    $copied = 0; $replaced = 0; $failed = 0
    try {
        foreach ($f in $files) {
            $to = Join-Path $dest $f.Rel
            $exists = Test-Path -LiteralPath $to
            if ($exists -and $Mode -eq 'merge') { continue }
            try {
                $dir = Split-Path $to -Parent
                if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                if ($Move) { if ($exists) { Remove-Item -LiteralPath $to -Force }; Move-Item -LiteralPath (Join-Path $StageGraphs $f.Rel) -Destination $to }
                else { Copy-Item -LiteralPath (Join-Path $StageGraphs $f.Rel) -Destination $to -Force }
                if ($exists) { $replaced++ } else { $copied++ }
            } catch { $failed++; if ($failed -le 5) { Write-PmLog "Could not copy $($f.Rel): $($_.Exception.Message)" 'WARN' } }
        }
        $cache = @(Get-ChildItem -LiteralPath $prtg.DataPath -Filter 'PRTG Graph Data Cache*' -File -ErrorAction SilentlyContinue)
        foreach ($c in $cache) { Rename-Item -LiteralPath $c.FullName -NewName ('{0}.pre-restore-{1}' -f $c.Name, (Get-Date -Format 'yyyyMMdd-HHmmss')) -ErrorAction SilentlyContinue }
        if ($cache.Count) { Write-PmLog 'Graph cache moved aside - PRTG recalculates the graphs from the history on start (may take a while).' 'INFO' }
    } finally {
        $health = $null
        if ($StartServices -or $wasRunning) {
            $box = @{}; Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts); $health = $box.Health
        }
    }
    Write-PmLog ("History restored: {0} new, {1} replaced, {2} failed. PRTG {3}." -f $copied, $replaced, $failed, $(if ($health) { if ($health.Healthy) { "is up: $($health.Url)" } else { "did NOT come up ($($health.Message))" } } else { 'left stopped' })) $(if ($failed -or ($health -and -not $health.Healthy)) { 'WARN' } else { 'OK' })
    return [pscustomobject]@{ PmType = 'graphs'; Copied = $copied; Replaced = $replaced; Failed = $failed; Plan = $plan; Healthy = $(if ($health) { [bool]$health.Healthy }); WebUrl = $(if ($health) { $health.Url }) }
}

# ---------------------------------------------------------------- license: status, backup, install, restore

$PmLicenseKeyPath = 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server'

function Get-PmLicenseHint {
    <# A plain explanation and what to do, from the license state / last activation line. #>
    param($State)
    if (-not $State -or -not $State.Known) { return 'PRTG wrote no license line yet. It writes one when the core starts; check again in a minute.' }
    $e = [string]$State.LastError
    if ($e -match '403') { return "Paessler's activation server refused this activation (HTTP 403). The key is already activated on another system, blocked or expired. Move the activation in the Paessler shop (Activation Center) or ask Paessler / your reseller to reset it; then try again." }
    if ($e -match '(?i)timeout|could not connect|unable to connect|resolve|proxy') { return 'PRTG could not reach the Paessler activation server. Allow HTTPS to the internet (or set the proxy in PRTG), or activate offline in the PRTG web interface: Setup > License Status > Offline activation.' }
    if ($e -match '(?i)invalid|wrong|not valid') { return 'The license name or key was not accepted. Enter both exactly as shown in the Paessler shop (the name is case sensitive).' }
    if ($State.NeedsActivation -and -not $State.Name) { return 'No license is installed. Enter a license (trial or bought) here or in PRTG: Setup > License Information.' }
    if ($State.NeedsActivation) { return 'The license must be activated for this server. PRTG does it online by itself (AutoActivation); without internet use the offline activation in Setup > License Status.' }
    return "Licensed: $($State.Edition), $($State.MaxSensors) sensors."
}

function Get-PmPrtgLicenseStatus {
    <# READ-ONLY. License state of the PRTG on this server - without the key. #>
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { return (New-PmResult @{ Installed = $false; Computer = $env:COMPUTERNAME }) }
    $rep = Get-PmPrtgLicenseReport -Days 3 -MaxLines 400
    $vals = @(Get-PmLicenseValues)
    $state = Get-PmPrtgLicenseState
    New-PmResult @{
        Installed = $true; Computer = $env:COMPUTERNAME; PrtgVersion = $prtg.Version; Core = $prtg.CoreStatus; State = $state; Hint = (Get-PmLicenseHint $state)
        ValueNames = @($vals | ForEach-Object { $_.Name } | Select-Object -Unique); HasKey = [bool]@($vals | Where-Object { $_.Name -eq 'LicenseKey' -and [string]$_.Value }).Count
        HasName = [bool]@($vals | Where-Object { $_.Name -eq 'LicenseName' -and [string]$_.Value }).Count
        Fingerprints = @($rep.Values); SystemId = $rep.SystemId; AutoActivation = $rep.AutoActivation; LogLines = @($rep.LogLines | Select-Object -Last 12)
    }
}

function Backup-PmPrtgLicense {
    <#
        READ-ONLY. The license values (registry) and license files of this PRTG, encrypted HERE with the backup
        password - the key never leaves this server in clear.
    #>
    param([Parameter(Mandatory)][string]$Password)
    Assert-PmBackupPassword $Password
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found).' }
    $vals = @(Get-PmLicenseValues)
    if (-not $vals.Count) { throw 'There is no license data on this server to back up.' }
    $rec = [ordered]@{
        format = 'prtg-license/1'; computer = $env:COMPUTERNAME; created = (Get-Date).ToUniversalTime().ToString('o'); prtgVersion = $prtg.Version
        values = @($vals | ForEach-Object {
                $v = $_.Value
                $kind = [string]$_.Kind
                [ordered]@{ path = ([string]$_.Path -replace '^Microsoft\.PowerShell\.Core\\Registry::', ''); name = $_.Name; kind = $kind; value = $(if ($v -is [byte[]]) { [Convert]::ToBase64String($v) } elseif ($v -is [array]) { @($v | ForEach-Object { [string]$_ }) } else { [string]$v }) }
            })
        files = @(Get-PmLicenseFiles -DataPath $prtg.DataPath | ForEach-Object { [ordered]@{ name = $_.Name; data = [Convert]::ToBase64String([IO.File]::ReadAllBytes($_.FullName)) } })
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $rec -Depth 5 -Compress))
    $blob = Protect-PmBytes -Data $bytes -Password $Password
    $state = Get-PmPrtgLicenseState
    Write-PmLog ("License backed up (encrypted on this server): {0} value(s){1}." -f $vals.Count, $(if (@($rec.files).Count) { ", $(@($rec.files).Count) file(s)" } else { '' })) 'OK'
    New-PmResult @{ Envelope = [Convert]::ToBase64String($blob); ValueNames = @($vals | ForEach-Object { $_.Name }); FileNames = @($rec.files | ForEach-Object { $_.name }); State = $state; PrtgVersion = $prtg.Version; Computer = $env:COMPUTERNAME }
}

function Save-PmLicenseRollback {
    <# Copy of the current license data (registry keys + files) before it is changed. Returns the folder. #>
    param($Prtg)
    $keep = Join-Path (Get-PmWorkRoot) ('rollback\license-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $keep | Out-Null
    foreach ($k in @($Prtg.RegistryKeys)) {
        $native = $k -replace '^HKLM:\\', 'HKLM\'
        if ((Invoke-PmReg -Verb export -Key $native -File (Join-Path $keep (($native -replace '[\\: ]', '_') + '.reg'))) -ne 0) { throw "Could not save a copy of $native - nothing was changed." }
    }
    foreach ($f in @(Get-PmLicenseFiles -DataPath $Prtg.DataPath)) { Copy-Item -LiteralPath $f.FullName -Destination $keep -Force }
    return $keep
}

function Get-PmCoreLogMark {
    <# Current length of every core log file: lines written after this mark are "new". #>
    $prtg = Get-PmPrtgInfo
    $m = @{}
    $dir = Join-Path ([string]$prtg.DataPath) 'Logs'
    if ($prtg.DataPath -and (Test-Path -LiteralPath $dir)) {
        foreach ($lf in (Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'core' -or $_.DirectoryName -match '\\core$' })) { $m[$lf.FullName] = [int64]$lf.Length }
    }
    return $m
}

function Get-PmCoreLogLinesSince {
    <# License / activation lines the core wrote after $Mark (keys masked). #>
    param([hashtable]$Mark = @{})
    $prtg = Get-PmPrtgInfo
    $dir = Join-Path ([string]$prtg.DataPath) 'Logs'
    $out = New-Object System.Collections.ArrayList
    if (-not $prtg.DataPath -or -not (Test-Path -LiteralPath $dir)) { return }
    foreach ($lf in (Get-ChildItem -LiteralPath $dir -Recurse -File -Filter '*.log' -ErrorAction SilentlyContinue | Where-Object { $_.Name -match 'core' -or $_.DirectoryName -match '\\core$' })) {
        $from = [int64]0; if ($Mark.ContainsKey($lf.FullName)) { $from = [int64]$Mark[$lf.FullName] }
        if ($lf.Length -le $from) { continue }
        try {
            $fs = New-Object IO.FileStream($lf.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
            [void]$fs.Seek($from, [IO.SeekOrigin]::Begin)
            $sr = New-Object IO.StreamReader($fs)
            try { while (-not $sr.EndOfStream) { $l = $sr.ReadLine(); if ($l -match '(?i)licen|activat|edition|trial|freeware') { [void]$out.Add(($l -replace '[0-9A-Za-z]{6}(-[0-9A-Za-z]{6}){3,}', '<key>' -replace '[A-Za-z0-9+/=-]{32,}', '<masked>')) } } }
            finally { $sr.Dispose(); $fs.Dispose() }
        } catch { }
    }
    return $out
}

function Wait-PmLicenseLine {
    <# After a start: waits (up to $Seconds) for the license line the core writes after $Mark, then returns the state (Fresh = from this start). #>
    param([hashtable]$Mark = @{}, [int]$Seconds = 150)
    $deadline = (Get-Date).AddSeconds($Seconds)
    do {
        $lines = @(Get-PmCoreLogLinesSince -Mark $Mark)
        $st = ConvertTo-PmLicenseState -LogLines $lines
        if ($st.Known) { $st | Add-Member -NotePropertyName Fresh -NotePropertyValue $true -Force; return $st }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    $st = Get-PmPrtgLicenseState
    $st | Add-Member -NotePropertyName Fresh -NotePropertyValue $false -Force
    return $st
}

function Install-PmPrtgLicense {
    <#
        Puts a license into the PRTG of this server the way the PRTG Administration Tool does it: license
        name and key in the registry (HKLM\...\PRTG Network Monitor\Server), with PRTG stopped. PRTG then
        activates it itself with Paessler when it starts - nothing here bypasses or fakes the activation.
          - LicenseName + LicenseKey : a trial or bought key the owner got from Paessler
          - Envelope + Password      : a license backup made by PRTG Manager (restores every saved value)
        A copy of the current license data is kept in <work root>\rollback\license-<time>.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'The backup password decrypts on this server only; it is never stored or logged.')]
    param(
        [string]$LicenseName, [string]$LicenseKey, [ValidateSet('trial', 'commercial', 'restore')][string]$Kind = 'commercial',
        [string]$Envelope, [string]$Password, [int]$HealthTimeoutMinutes = 15, [bool]$Force = $false,
        # where PRTG keeps name and key (only changed by tests)
        [string]$LicenseKeyPath = $PmLicenseKeyPath
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmIsAdmin)) { throw 'Changing the PRTG license needs administrator rights on this server.' }
    $prtg = Get-PmPrtgInfo
    if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found).' }
    $values = @(); $files = @()
    if ($Envelope) {
        if (-not $Password) { throw 'The license backup is encrypted - enter its password.' }
        $rec = [Text.Encoding]::UTF8.GetString((Unprotect-PmBytes -Envelope ([Convert]::FromBase64String($Envelope)) -Password $Password)) | ConvertFrom-Json
        if ($rec.format -ne 'prtg-license/1') { throw "Unknown license backup format '$($rec.format)'." }
        $values = @($rec.values | ForEach-Object { $_ }); $files = @($rec.files | ForEach-Object { $_ })
        $Kind = 'restore'
        Write-PmLog "License backup of $($rec.computer) ($($rec.created)) decrypted on this server: $($values.Count) value(s)." 'OK'
        if ($rec.computer -and $rec.computer -ne $env:COMPUTERNAME) { Write-PmLog "The backup comes from $($rec.computer). A PRTG license is activated per system - on this server PRTG asks Paessler for a new activation." 'WARN' }
    } else {
        $LicenseName = ([string]$LicenseName).Trim(); $LicenseKey = ([string]$LicenseKey).Trim()
        if (-not $LicenseName -or -not $LicenseKey) { throw 'Enter the license name and the license key exactly as Paessler sent them.' }
        if ($LicenseKey.Length -lt 20 -or $LicenseKey -notmatch '^[A-Za-z0-9\-+/=]+$') { throw 'This does not look like a PRTG license key (letters, digits and dashes, usually several groups). Copy it again from the Paessler e-mail or shop.' }
    }
    $before = Get-PmPrtgLicenseState
    if (-not $Force -and $before.Known -and -not $before.NeedsActivation -and $Kind -ne 'restore') {
        throw "PRTG on this server already runs with an active license ($($before.Edition), $($before.MaxSensors) sensors). Remove it first or confirm replacing it."
    }
    Write-PmProgress 10 'Saving a copy of the current license'
    $keep = Save-PmLicenseRollback -Prtg $prtg
    Write-PmLog "Copy of the current license data (to undo this): $keep" 'OK'
    Write-PmProgress 25 'Stopping PRTG'
    Write-PmLog 'Stopping PRTG (license values are only read by the core when it starts)...' 'STEP'
    $mark = Get-PmCoreLogMark
    Stop-PmPrtgServices
    try {
        if ($values.Count) {
            foreach ($v in @(Get-PmLicenseValues)) { Remove-ItemProperty -LiteralPath $v.Path -Name $v.Name -ErrorAction SilentlyContinue }
            foreach ($v in $values) {
                $path = 'Registry::' + [string]$v.path
                if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                $val = switch ([string]$v.kind) { 'Binary' { [Convert]::FromBase64String([string]$v.value) } 'DWord' { [int]$v.value } 'QWord' { [long]$v.value } 'MultiString' { [string[]]@($v.value) } default { [string]$v.value } }
                New-ItemProperty -LiteralPath $path -Name ([string]$v.name) -Value $val -PropertyType ([string]$v.kind) -Force | Out-Null
            }
            foreach ($f in $files) { [IO.File]::WriteAllBytes((Join-Path $prtg.DataPath ([IO.Path]::GetFileName([string]$f.name))), [Convert]::FromBase64String([string]$f.data)) }
            Write-PmLog "License values restored: $(@($values | ForEach-Object { $_.name }) -join ', ')" 'OK'
        } else {
            # a new key: the activation data of the old one is dropped so PRTG activates the new key
            if (-not (Test-Path $LicenseKeyPath)) { New-Item -Path $LicenseKeyPath -Force | Out-Null }
            foreach ($n in 'LicenseHash', 'SensorCountPausedByLicenseMax') { Remove-ItemProperty -LiteralPath $LicenseKeyPath -Name $n -ErrorAction SilentlyContinue }
            New-ItemProperty -LiteralPath $LicenseKeyPath -Name 'LicenseName' -Value $LicenseName -PropertyType String -Force | Out-Null
            New-ItemProperty -LiteralPath $LicenseKeyPath -Name 'LicenseKey' -Value $LicenseKey -PropertyType String -Force | Out-Null
            Write-PmLog "$(if ($Kind -eq 'trial') { 'Trial license' } else { 'License' }) '$LicenseName' written (key #$(Get-PmShortHash $LicenseKey), $($LicenseKey.Length) characters)." 'OK'
        }
    } catch {
        Write-PmLog "Writing the license failed: $($_.Exception.Message) - restoring the copy." 'ERROR'
        foreach ($r in (Get-ChildItem -LiteralPath $keep -Filter '*.reg' -File)) { [void](Invoke-PmReg -Verb import -File $r.FullName) }
        $box = @{}; Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
        throw
    }
    Write-PmProgress 50 'Starting PRTG'
    $box = @{}
    Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
    $health = $box.Health
    Write-PmProgress 80 'Waiting for the activation result'
    Write-PmLog 'Waiting for PRTG to report the license (it activates online with Paessler)...' 'STEP'
    $after = Wait-PmLicenseLine -Mark $mark -Seconds 150
    $hint = Get-PmLicenseHint $after
    $ok = [bool]($after.Known -and -not $after.NeedsActivation)
    Write-PmLog ("License now: {0}. {1}" -f $(if ($after.Known) { "$($after.Edition), $($after.MaxSensors) sensors$(if ($after.NeedsActivation) { ', NOT activated' })" } else { 'no license line yet' }), $hint) $(if ($ok) { 'OK' } else { 'WARN' })
    if ($after.LastError) { Write-PmLog "Last activation message of PRTG: $($after.LastError)" 'WARN' }
    Write-PmProgress 100 'Done'
    New-PmResult @{ Kind = $Kind; Before = $before; After = $after; Activated = $ok; Hint = $hint; Rollback = $keep; Healthy = [bool]$health.Healthy; WebUrl = $health.Url; Core = (Get-PmPrtgInfo).CoreStatus }
}

# ---------------------------------------------------------------- full restore preview

function Get-PmRestoreTargetFacts {
    <# READ-ONLY. What the full-restore preview needs to know about this server. #>
    $prtg = Get-PmPrtgInfo
    $stats = $null; $dataBytes = [int64]0; $lic = $null
    if ($prtg.Installed) {
        $stats = Get-PmPrtgConfigStats -Path (Join-Path $prtg.DataPath 'PRTG Configuration.dat')
        $dataBytes = Get-PmDirectorySize -Path $prtg.DataPath
        try { $lic = Get-PmPrtgLicenseState } catch { }
    }
    $drive = Get-PmLogicalDisk -Path $(if ($prtg.DataPath) { $prtg.DataPath } else { $env:SystemDrive + '\' })
    New-PmResult @{
        Computer = $env:COMPUTERNAME; Os = (Get-PmOsCaption); IsAdmin = (Test-PmIsAdmin); Prtg = $prtg; ConfigStats = $stats; DataBytes = $dataBytes
        FreeBytes = $(if ($drive) { [int64]$drive.FreeSpace }); License = $lic
        NetRelease = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
    }
}

# ---------------------------------------------------------------- BACKUP (runs on source)

function Invoke-PmRemoteBackup {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$WorkRoot,
        [bool]$IncludePrtg = $true,
        [bool]$IncludeHistory = $true,
        [bool]$IncludeDesktop = $true,
        [string[]]$ExtraPaths = @(),
        [ValidateSet('Restart', 'KeepStopped', 'Disable')][string]$SourceAfter = 'Restart',
        [bool]$NoTouch = $false,
        [int]$HealthTimeoutMinutes = 15,
        [bool]$IncludeProgram = $true,
        [bool]$IncludeLogs = $false,
        [bool]$IncludeAutoBackups = $false,
        # full = PRTG with configuration, program, registry, license, history; graphs = only the history (Monitoring Database)
        [ValidateSet('full', 'graphs')][string]$Scope = 'full',
        # graphs: only the last N days of history (0 = all)
        [int]$HistoryDays = 0,
        # Stage directly into this folder (e.g. the manager's disk via \\tsclient) and skip zipping on the source.
        [string]$StageDir,
        [string]$LogDir,
        # WinRM pull mode: big folders are NOT copied here - the manager pulls them straight from the snapshot.
        [bool]$PullMode = $false,
        # Kept so an older caller can still ask for a direct stage. Tunnel jobs no longer use it.
        [bool]$TunnelCopy = $false
    )
    $ErrorActionPreference = 'Stop'
    $sourceHealth = $null
    $pullItems = @()
    if (-not $WorkRoot) { $WorkRoot = Get-PmWorkRoot }
    $direct = [bool]$StageDir
    $stage = if ($direct) { $StageDir } else { Join-Path $WorkRoot "staging\$JobId" }
    $outDir = Join-Path $WorkRoot 'out'
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    if (-not $direct) { New-Item -ItemType Directory -Force -Path $outDir | Out-Null }
    if ($LogDir) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; $global:PmRobocopyLog = Join-Path $LogDir "robocopy-$JobId-$env:COMPUTERNAME.log" } else { $global:PmRobocopyLog = $null }
    $modeText = if ($TunnelCopy) { 'direct copy to the other server over the tunnel (this manager is not in the path)' } elseif ($direct) { 'direct staging on the manager (no disk space used on this server)' } else { 'local staging + zip' }
    Write-PmLog "Mode: $modeText. Robocopy log: $(if ($global:PmRobocopyLog) { $global:PmRobocopyLog } else { 'off' })" 'DEBUG'

    $manifest = [ordered]@{
        tool = 'prtg-manager'; format = 'prtg-manager-backup'; formatVersion = 2; type = $Scope; jobId = $JobId
        createdUtc = (Get-Date).ToUniversalTime().ToString('o')
        source = [ordered]@{ computer = $env:COMPUTERNAME; os = (Get-PmOsCaption) }
        prtg = [ordered]@{ included = $false }
        desktop = [ordered]@{ included = $false; users = @() }
        extra = @()
        warnings = @()
    }

    Write-PmLog "Backup started on $env:COMPUTERNAME (staging: $stage)" 'STEP'
    $shadow = $null

    # ---- history only (graph data): PRTG keeps running, copied from a VSS snapshot
    if ($Scope -eq 'graphs') {
        $IncludeDesktop = $false; $ExtraPaths = @()
        Write-PmProgress 5 'History: discovering installation'
        $prtg = Get-PmPrtgInfo
        if (-not $prtg.Installed) { throw 'PRTG is not installed on this server (service PRTGCoreService not found) - there is no history to back up.' }
        Write-PmLog "PRTG $($prtg.Version) found. History folder: $(Join-Path $prtg.DataPath 'Monitoring Database'). PRTG keeps running, nothing is stopped or changed." 'STEP'
        Clear-PmStaleSnapshots
        $dataSource = $prtg.DataPath
        try {
            $shadow = New-PmShadowCopy -Path $prtg.DataPath
            $dataSource = Join-Path $shadow.Link $prtg.DataPath.Substring($shadow.Volume.Length)
            Write-PmLog "Consistent VSS snapshot of $($shadow.Volume) created - copying from the snapshot." 'OK'
        } catch {
            Write-PmLog "VSS snapshot not available ($($_.Exception.Message)) - copying live files (the file of today may be incomplete)." 'WARN'
            $manifest.warnings += 'History backup without VSS snapshot (live copy)'
        }
        try {
            $mdb = Join-Path $dataSource 'Monitoring Database'
            if (-not (Test-Path -LiteralPath $mdb)) { throw "This PRTG has no history folder ($mdb)." }
            $excl = @(Get-PmGraphDayFolders -Root $mdb -Days $HistoryDays)
            $gfiles = @(Get-PmGraphFiles -Root $mdb -Days $HistoryDays)
            $gbytes = [int64](($gfiles | Measure-Object -Property Size -Sum).Sum)
            $days = @($gfiles | Where-Object { $_.Day } | ForEach-Object { $_.Day } | Sort-Object -Unique)
            # which devices the history belongs to (id + name), so a restore can check the target has them
            $index = @()
            try {
                $cdoc = Read-PmPrtgConfig -Path (Join-Path $dataSource 'PRTG Configuration.dat')
                $index = @($cdoc.SelectNodes('//nodes/*[@id][self::device or self::autodevice or self::probenode]') | ForEach-Object { [ordered]@{ id = [int]$_.GetAttribute('id'); name = (Get-PmObjectName $_) } })
                $manifest.prtg = [ordered]@{ included = $false; version = $prtg.Version; configVersion = (Get-PmConfigHeader $cdoc).ConfigVersion; dataPath = $prtg.DataPath }
            } catch { Write-PmLog "Device names could not be read from the configuration: $($_.Exception.Message)" 'WARN'; $manifest.prtg = [ordered]@{ included = $false; version = $prtg.Version; dataPath = $prtg.DataPath } }
            New-Item -ItemType Directory -Force -Path (Join-Path $stage 'prtg') | Out-Null
            ConvertTo-Json -InputObject @($index) -Depth 3 | Set-Content -LiteralPath (Join-Path $stage 'prtg\graphs-index.json') -Encoding UTF8
            if ($PullMode) {
                $pullItems += [pscustomobject]@{ Source = $mdb; Target = 'prtg\graphs'; ExcludeDirs = @($excl); ExcludeFiles = @('*.tmp') }
            } else {
                $code = Invoke-PmRobocopy -Source $mdb -Destination (Join-Path $stage 'prtg\graphs') -ExcludeDirs $excl -ExcludeFiles @('*.tmp')
                if (-not (Test-PmRobocopyOk $code)) { throw "robocopy of the history failed with exit code $code. $(Get-PmRobocopyErrors)" }
            }
            $manifest.graphs = [ordered]@{
                included = $true; days = $HistoryDays; from = $(if ($days.Count) { $days[0] } else { $null }); to = $(if ($days.Count) { $days[-1] } else { $null })
                files = $gfiles.Count; bytes = $gbytes; devices = @($gfiles | Where-Object { $_.Device -gt 0 } | ForEach-Object { $_.Device } | Sort-Object -Unique)
            }
            Write-PmLog ("History: {0} file(s), {1:N2} GB, {2} day(s){3}, {4} device(s)." -f $gfiles.Count, ($gbytes / 1GB), $days.Count, $(if ($days.Count) { " ($($days[0]) - $($days[-1]))" } else { '' }), @($manifest.graphs.devices).Count) 'OK'
        } finally {
            if ($shadow -and -not $PullMode) { Remove-PmShadowCopy -Shadow $shadow; Write-PmLog 'VSS snapshot removed.'; $shadow = $null }
        }
    }

    # ---- PRTG
    if ($IncludePrtg -and $Scope -eq 'full') {
        Write-PmProgress 5 'PRTG: discovering installation'
        $prtg = Get-PmPrtgInfo
        if (-not $prtg.Installed) {
            Write-PmLog 'PRTG core service not found - skipping PRTG backup.' 'WARN'
            $manifest.warnings += 'PRTG not installed on source'
        } else {
            Write-PmLog "PRTG $($prtg.Version) found. Program: $($prtg.ProgramPath) | Data: $($prtg.DataPath)"
            $wasRunning = ($prtg.CoreStatus -eq 'Running')
            Clear-PmStaleSnapshots
            $shadow = $null
            $dataSource = $prtg.DataPath
            $prtgOk = $false   # the snapshot is only kept for the manager's pull when this part succeeded
            # the stop is inside the try: a stop that fails half-way still ends in the restart of the finally
            try {
            if ($NoTouch) {
                Write-PmLog 'NO-TOUCH mode: PRTG keeps running on the source, nothing is stopped, changed or deleted.' 'STEP'
                try {
                    $shadow = New-PmShadowCopy -Path $prtg.DataPath
                    $dataSource = Join-Path $shadow.Link $prtg.DataPath.Substring($shadow.Volume.Length)
                    Write-PmLog "Consistent VSS snapshot of $($shadow.Volume) created - copying from the snapshot." 'OK'
                } catch {
                    Write-PmLog "VSS snapshot not available ($($_.Exception.Message)) - copying live files. PRTG saves its configuration periodically; files locked at this moment are skipped." 'WARN'
                    $manifest.warnings += 'No-touch backup without VSS snapshot (live copy)'
                }
            } else {
                Write-PmProgress 10 'PRTG: stopping services'
                Write-PmLog 'Stopping PRTG services (the core flushes its configuration to disk)...' 'STEP'
                Stop-PmPrtgServices
                Write-PmLog 'PRTG services stopped.' 'OK'
                if ($PullMode) {
                    # Freeze the stopped state so the services can be restarted before the manager has pulled everything.
                    try {
                        $shadow = New-PmShadowCopy -Path $prtg.DataPath
                        $dataSource = Join-Path $shadow.Link $prtg.DataPath.Substring($shadow.Volume.Length)
                        Write-PmLog 'VSS snapshot of the stopped state created.' 'OK'
                    } catch { Write-PmLog "VSS snapshot not available ($($_.Exception.Message)) - PRTG must stay stopped until the pull is finished." 'WARN'; $SourceAfter = 'KeepStopped' }
                }
            }

                Write-PmProgress 20 'PRTG: copying data folder'
                # Only what PRTG needs: no log files, caches, temp files or old automatic config copies (unless asked).
                $exclude = @()
                if (-not $IncludeHistory) { $exclude += (Join-Path $dataSource 'Monitoring Database') }
                if (-not $IncludeLogs) { $exclude += (Join-Path $dataSource 'Logs') }
                if (-not $IncludeAutoBackups) { $exclude += (Join-Path $dataSource 'Configuration Auto-Backups') }
                $excludeFiles = @('*.tmp', 'PRTG Graph Data Cache*', '*.old', '*.bak')
                $skipped = @()
                foreach ($x in $exclude) {
                    if (Test-Path -LiteralPath $x) { $skipped += ('{0} ({1:N2} GB)' -f (Split-Path $x -Leaf), ((Get-PmDirectorySize $x) / 1GB)) }
                }
                Write-PmLog "Copying only what PRTG needs. Skipped: $(if ($skipped) { $skipped -join ', ' } else { 'nothing' }) + temp/cache files ($($excludeFiles -join ', '))." 'INFO'
                if ($PullMode) {
                    $pullItems += [pscustomobject]@{ Source = $dataSource; Target = 'prtg\data'; ExcludeDirs = @($exclude); ExcludeFiles = @($excludeFiles) }
                    $cfg = Join-Path $dataSource 'PRTG Configuration.dat'
                } else {
                    $code = Invoke-PmRobocopy -Source $dataSource -Destination (Join-Path $stage 'prtg\data') -ExcludeDirs $exclude -ExcludeFiles $excludeFiles -Mirror
                    if (-not (Test-PmRobocopyOk $code)) { throw "robocopy of PRTG data failed with exit code $code. $(Get-PmRobocopyErrors)" }
                    $cfg = Join-Path $stage 'prtg\data\PRTG Configuration.dat'
                }
                if (-not (Test-Path -LiteralPath $cfg)) { throw "'PRTG Configuration.dat' is missing from the copied data folder - aborting (backup would be unusable)." }
                $cfgInfo = Get-Item -LiteralPath $cfg
                $cfgHash = (Get-FileHash -LiteralPath $cfg -Algorithm SHA256).Hash
                $cfgStats = Get-PmPrtgConfigStats -Path $cfg
                Write-PmLog "Configuration content (all rules, notifications, triggers, users... are inside this file): $cfgStats" 'OK'
                if ($PullMode) { Write-PmLog ("Data folder prepared for pulling by the manager. PRTG Configuration.dat: {0:N1} MB, saved {1}." -f ($cfgInfo.Length / 1MB), $cfgInfo.LastWriteTime) 'OK' }
                else { Write-PmLog ("Data folder copied ({0:N2} GB). PRTG Configuration.dat: {1:N1} MB, saved {2}." -f ((Get-PmDirectorySize (Join-Path $stage 'prtg\data')) / 1GB), ($cfgInfo.Length / 1MB), $cfgInfo.LastWriteTime) 'OK' }

                Write-PmProgress 35 'PRTG: copying customisations'
                $copiedFolders = @()
                foreach ($f in $PmProgramFolders) {
                    $srcF = Join-Path $prtg.ProgramPath $f
                    if (Test-Path -LiteralPath $srcF) {
                        $code = Invoke-PmRobocopy -Source $srcF -Destination (Join-Path $stage "prtg\program\$f")
                        if (Test-PmRobocopyOk $code) { $copiedFolders += $f } else { Write-PmLog "Could not copy '$f' (robocopy $code)" 'WARN' }
                    }
                }
                Write-PmLog "Program customisation folders: $($copiedFolders -join ', ')" 'OK'

                # ---- full program clone: lets a target without PRTG run it without any installer
                $programCloned = $false; $services = @()
                if ($IncludeProgram) {
                    Write-PmProgress 38 'PRTG: cloning program files and services'
                    $progSource = $prtg.ProgramPath
                    if ($shadow -and $prtg.ProgramPath.StartsWith($shadow.Volume, [StringComparison]::OrdinalIgnoreCase)) {
                        $progSource = Join-Path $shadow.Link $prtg.ProgramPath.Substring($shadow.Volume.Length)
                    }
                    if ($PullMode) {
                        $pullItems += [pscustomobject]@{ Source = $progSource; Target = 'prtg\programfull'; ExcludeDirs = @(); ExcludeFiles = @() }
                        $programCloned = $true
                        Write-PmLog ("Complete PRTG program folder ({0:N0} MB) prepared for pulling - the target needs no installer." -f ((Get-PmDirectorySize $progSource) / 1MB)) 'OK'
                    } elseif (Test-PmRobocopyOk ($code = Invoke-PmRobocopy -Source $progSource -Destination (Join-Path $stage 'prtg\programfull'))) {
                        $programCloned = $true
                        Write-PmLog ("Complete PRTG program folder cloned ({0:N0} MB) - the target needs no installer." -f ((Get-PmDirectorySize (Join-Path $stage 'prtg\programfull')) / 1MB)) 'OK'
                    } else { Write-PmLog "Program folder clone failed (robocopy $code) - the target will need the PRTG installer." 'WARN' }
                    $svcDir = Join-Path $stage 'prtg\services'
                    New-Item -ItemType Directory -Force -Path $svcDir | Out-Null
                    foreach ($n in $PmCoreService, $PmProbeService) {
                        $w = $null
                        if (Get-Command Get-CimInstance -ErrorAction SilentlyContinue) {
                            $w = Get-CimInstance Win32_Service -Filter "Name='$n'" -ErrorAction SilentlyContinue
                        }
                        if (-not $w) { continue }
                        [void](Invoke-PmReg -Verb export -Key "HKLM\SYSTEM\CurrentControlSet\Services\$n" -File (Join-Path $svcDir "$n.reg"))
                        $services += [ordered]@{ name = $w.Name; displayName = $w.DisplayName; pathName = $w.PathName; startMode = $w.StartMode; startName = $w.StartName; description = $w.Description }
                    }
                    Write-PmLog "Service definitions saved: $(@($services | ForEach-Object { $_.name }) -join ', ')" 'OK'
                }
                $netRelease = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release

                Write-PmProgress 40 'PRTG: exporting registry'
                $regDir = Join-Path $stage 'prtg\registry'
                New-Item -ItemType Directory -Force -Path $regDir | Out-Null
                $regFiles = @()
                foreach ($k in $prtg.RegistryKeys) {
                    $native = $k -replace '^HKLM:\\', 'HKLM\'
                    $file = Join-Path $regDir (($native -replace '[\\: ]', '_') + '.reg')
                    if ((Invoke-PmReg -Verb export -Key $native -File $file) -eq 0) { $regFiles += (Split-Path $file -Leaf) } else { Write-PmLog "reg export failed for $native" 'WARN' }
                }
                Write-PmLog "Registry exported: $($regFiles -join ', ')" 'OK'

                $licNames = @(Get-PmLicenseValues | ForEach-Object { $_.Name } | Select-Object -Unique)
                $licFiles = @(Get-PmLicenseFiles -DataPath $prtg.DataPath | ForEach-Object { $_.Name })
                Write-PmLog ("License information found: {0} registry value(s){1}." -f $licNames.Count, $(if ($licFiles.Count) { ", files: $($licFiles -join ', ')" } else { '' }))

                $manifest.prtg = [ordered]@{
                    included = $true; version = $prtg.Version; dataPath = $prtg.DataPath; programPath = $prtg.ProgramPath
                    includeHistory = $IncludeHistory; programFolders = $copiedFolders; registryFiles = $regFiles
                    listenPorts = $prtg.ListenPorts; configSha256 = $cfgHash; configSize = $cfgInfo.Length; configStats = $cfgStats
                    licenseValueNames = $licNames; licenseFiles = $licFiles
                    programCloned = $programCloned; services = $services; netFrameworkRelease = $netRelease
                    consistency = $(if ($NoTouch) { if ($shadow) { 'vss-snapshot' } else { 'live-copy' } } else { 'services-stopped' })
                }
                $prtgOk = $true
            } finally {
                if ($shadow -and $PullMode -and $prtgOk) { Write-PmLog 'VSS snapshot kept until the manager has pulled the data (removed afterwards).' 'DEBUG' }
                elseif ($shadow) {
                    # also after a failure: a snapshot left behind keeps growing on the system drive
                    try { Remove-PmShadowCopy -Shadow $shadow; Write-PmLog 'VSS snapshot removed.' } catch { Write-PmLog "VSS snapshot could not be removed: $($_.Exception.Message)" 'WARN' }
                    $shadow = $null
                }
                if ($NoTouch) {
                    Write-PmLog 'Source untouched - PRTG kept running the whole time.' 'OK'
                } else {
                    switch ($SourceAfter) {
                        'Restart' {
                            if (-not $wasRunning) {
                                Write-PmLog 'PRTG was not running before the backup - leaving it stopped.' 'WARN'
                            } else {
                                Write-PmProgress 72 'PRTG: restarting source and verifying health'
                                Write-PmLog 'Starting PRTG on the source and waiting until it is FULLY up (services + web interface + stability)...' 'STEP'
                                $box = @{}
                                Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($prtg.ListenPorts)
                                $sourceHealth = $box.Health
                                if ($sourceHealth.Healthy) { Write-PmLog "Source PRTG is fully up again: $($sourceHealth.Url)" 'OK' }
                                else { Write-PmLog "Source PRTG did NOT come back up correctly ($($sourceHealth.Message)). Check the core log on the source!" 'ERROR' }
                            }
                        }
                        'KeepStopped' { Write-PmLog 'Source PRTG services left STOPPED (migration mode).' 'WARN' }
                        'Disable' {
                            foreach ($n in $PmCoreService, $PmProbeService) { Set-Service -Name $n -StartupType Disabled -ErrorAction SilentlyContinue }
                            Write-PmLog 'Source PRTG services STOPPED and DISABLED (migration mode).' 'WARN'
                        }
                    }
                }
            }
        }
    }

    # ---- Desktop files
    if ($IncludeDesktop) {
        Write-PmProgress 60 'Desktop: copying user desktops'
        $deskStage = Join-Path $stage 'desktop'
        $sources = @()
        foreach ($prof in (Get-PmUserProfiles)) { $sources += [pscustomobject]@{ Name = $prof.Name; Path = (Join-Path $prof.Path 'Desktop') } }
        $sources += [pscustomobject]@{ Name = 'Public'; Path = (Join-Path $env:PUBLIC 'Desktop') }
        foreach ($s in $sources) {
            if (-not (Test-Path -LiteralPath $s.Path)) { continue }
            if (-not (Get-ChildItem -LiteralPath $s.Path -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })) { continue }
            $code = Invoke-PmRobocopy -Source $s.Path -Destination (Join-Path $deskStage $s.Name)
            if (Test-PmRobocopyOk $code) { $manifest.desktop.users += $s.Name } else { Write-PmLog "Desktop copy failed for $($s.Name) (robocopy $code)" 'WARN' }
        }
        $manifest.desktop.included = $true
        Write-PmLog "Desktop files copied for: $($manifest.desktop.users -join ', ')" 'OK'
        foreach ($u in $manifest.desktop.users) {
            $files = @(Get-ChildItem -LiteralPath (Join-Path $deskStage $u) -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' })
            if (-not $files.Count) { continue }
            $special = @($files | Where-Object { $_.Extension -in '.bat', '.cmd', '.ps1', '.pbk', '.ovpn', '.conf', '.rdp', '.vbs' } | ForEach-Object { $_.Name })
            Write-PmLog ("Desktop {0}: {1} file(s), {2:N1} MB{3}" -f $u, $files.Count, (($files | Measure-Object Length -Sum).Sum / 1MB), $(if ($special.Count) { " - scripts/VPN: $($special -join ', ')" } else { '' })) 'INFO'
        }
        $manifest.desktop.files = @(Get-ChildItem -LiteralPath $deskStage -Recurse -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $_.FullName.Substring($deskStage.Length + 1) } | Select-Object -First 500)
    }

    # ---- Extra paths
    $i = 0
    foreach ($p in $ExtraPaths) {
        if ([string]::IsNullOrWhiteSpace($p)) { continue }
        $i++
        $dst = Join-Path $stage "extra\$i"
        if (Test-Path -LiteralPath $p -PathType Container) {
            $code = Invoke-PmRobocopy -Source $p -Destination $dst
            if (Test-PmRobocopyOk $code) { $manifest.extra += [ordered]@{ index = $i; path = $p; kind = 'dir' } }
        } elseif (Test-Path -LiteralPath $p -PathType Leaf) {
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            Copy-Item -LiteralPath $p -Destination $dst -Force
            $manifest.extra += [ordered]@{ index = $i; path = $p; kind = 'file' }
        } else {
            Write-PmLog "Extra path not found: $p" 'WARN'
            continue
        }
        Write-PmLog "Extra path included: $p" 'OK'
    }

    # ---- Manifest + archive
    Write-PmProgress 70 'Packaging: writing manifest'
    $manifest.stagingBytes = Get-PmDirectorySize $stage
    foreach ($pi in $pullItems) { $manifest.stagingBytes += [int64](@((Get-PmPullList -Source $pi.Source -ExcludeDirs $pi.ExcludeDirs -ExcludeFiles $pi.ExcludeFiles -Raw) | Measure-Object -Property Size -Sum).Sum) }
    $manifest | ConvertTo-Json -Depth 8 | Set-Content -Path (Join-Path $stage 'manifest.json') -Encoding UTF8
    if ($PullMode) {
        Write-PmLog ("Ready for the manager to pull {0:N2} GB (small items staged locally: {1:N1} MB)." -f ($manifest.stagingBytes / 1GB), ((Get-PmDirectorySize $stage) / 1MB)) 'OK'
        Write-PmProgress 80 'Ready to pull'
        return (New-PmResult @{ StageDir = $stage; PullItems = @($pullItems); ShadowId = $(if ($shadow) { $shadow.Id }); ShadowLink = $(if ($shadow) { $shadow.Link }); Manifest = ($manifest | ConvertTo-Json -Depth 8); SourceHealth = $sourceHealth })
    }
    if ($direct) {
        if ($TunnelCopy) { Write-PmLog ("Copy complete on the other server ({0:N2} GB). Nothing was stored on the manager." -f ($manifest.stagingBytes / 1GB)) 'OK' }
        else { Write-PmLog ("Staging complete on the manager ({0:N2} GB). The manager builds the package." -f ($manifest.stagingBytes / 1GB)) 'OK' }
        Write-PmProgress 80 'Staging done'
        return (New-PmResult @{ StageDir = $stage; Manifest = ($manifest | ConvertTo-Json -Depth 8); SourceHealth = $sourceHealth; TunnelCopy = [bool]$TunnelCopy })
    }
    $zipName = 'PRTG-{2}_{0}_{1}.zip' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmmss'), $Scope.ToUpperInvariant()
    $zipPath = Join-Path $outDir $zipName
    Write-PmLog "Compressing to $zipPath ..." 'STEP'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
    Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue
    $zip = Get-Item -LiteralPath $zipPath
    $hash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
    Write-PmLog ("Package ready: {0} ({1:N2} MB, SHA256 {2})" -f $zipName, ($zip.Length / 1MB), $hash) 'OK'
    Write-PmProgress 80 'Packaging done'

    New-PmResult @{
        ZipPath = $zipPath; ZipName = $zipName; Size = $zip.Length; Sha256 = $hash; Manifest = ($manifest | ConvertTo-Json -Depth 8)
        SourceHealth = $sourceHealth
    }
}

# ---------------------------------------------------------------- RESTORE (runs on target)

function Undo-PmPrtgRestore {
    <#
        Puts PRTG back to the state before a failed full restore: the previous data folder (renamed
        back) and the PRTG registry keys (cleared and imported from the copy taken before the restore).
        The restored data folder is kept as <data>.failed-restore-<time>. Nothing is deleted.
    #>
    param([Parameter(Mandatory)][string]$DataPath, [Parameter(Mandatory)][string]$OldPath, [Parameter(Mandatory)][string]$RegBackup, [string]$Stamp, [int]$HealthTimeoutMinutes = 15, [int[]]$Ports = @(),
        # firewall rule the restore created (it did not exist before) - removed again
        [string]$FirewallRule)
    Write-PmLog 'ROLLBACK: putting the previous PRTG data folder and registry back...' 'STEP'
    if ($FirewallRule -and (Get-Command Remove-NetFirewallRule -ErrorAction SilentlyContinue)) {
        Get-NetFirewallRule -DisplayName $FirewallRule -ErrorAction SilentlyContinue | Remove-NetFirewallRule -ErrorAction SilentlyContinue
        Write-PmLog "Firewall rule '$FirewallRule' that the restore had added was removed again." 'OK'
    }
    Stop-PmPrtgServices
    if (-not (Test-Path -LiteralPath $OldPath)) { throw "The previous data folder $OldPath is gone - cannot roll back." }
    if (Test-Path -LiteralPath $DataPath) { Rename-Item -LiteralPath $DataPath -NewName ('{0}.failed-restore-{1}' -f (Split-Path $DataPath -Leaf), $Stamp) }
    Rename-Item -LiteralPath $OldPath -NewName (Split-Path $DataPath -Leaf)
    Write-PmLog "Previous data folder is back in $DataPath (the restored one is kept as $DataPath.failed-restore-$Stamp)." 'OK'
    $regs = @(Get-ChildItem -LiteralPath $RegBackup -Filter '*.reg' -File -ErrorAction SilentlyContinue)
    if ($regs.Count) {
        # reg import only adds and overwrites; the keys are cleared first so values the restore added go away too
        foreach ($k in 'HKLM\SOFTWARE\WOW6432Node\Paessler', 'HKLM\SOFTWARE\Paessler') {
            if (Test-Path ('Registry::' + $k)) { & reg.exe delete $k /f 2>&1 | Out-Null }
        }
        $bad = @($regs | Where-Object { (Invoke-PmReg -Verb import -File $_.FullName) -ne 0 } | ForEach-Object { $_.Name })
        if ($bad.Count) { Write-PmLog "Registry copy could not be imported: $($bad -join ', ') (files in $RegBackup)." 'ERROR' } else { Write-PmLog "Previous PRTG registry imported from $RegBackup." 'OK' }
    }
    $box = @{}
    Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts $Ports
    $h = $box.Health
    Write-PmLog "ROLLBACK done - PRTG $(if ($h.Healthy) { "is up again with the previous data: $($h.Url)" } else { "did NOT come up ($($h.Message))" })." $(if ($h.Healthy) { 'WARN' } else { 'ERROR' })
    [pscustomobject]@{ PmType = 'undo'; Healthy = [bool]$h.Healthy; Url = $h.Url }
}


function Invoke-PmRemoteRestore {
    param(
        [Parameter(Mandatory)][string]$JobId,
        [string]$ZipPath,
        [string]$WorkRoot,
        [bool]$RestorePrtg = $true,
        [bool]$RestoreDesktop = $true,
        [bool]$RestoreExtra = $true,
        [string]$InstallerPath,
        [string]$InstallerArgs = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART',
        [bool]$AllowDowngrade = $false,
        [bool]$StartServices = $true,
        [int]$HealthTimeoutMinutes = 15,
        [bool]$RemovePackage = $true,
        # history packages: merge keeps files that exist on the target, overwrite replaces them
        [ValidateSet('merge', 'overwrite')][string]$GraphMode = 'merge',
        # full restore: put the previous PRTG back automatically when the restored one does not come up
        [bool]$AutoRollback = $true,
        [bool]$CopyLicense = $true,
        [bool]$OpenFirewall = $true,
        [string]$ExpectedSha256,
        # Read the extracted package directly from this folder (e.g. the manager via \\tsclient) instead of a zip.
        [string]$StageDir,
        [string]$LogDir,
        # The staged package is local on this server: move folders into place instead of copying (saves disk space).
        [bool]$MoveFromStage = $false,
        [bool]$CleanupStage = $false,
        # Address of this server as the manager knows it (used for the PRTG web server binding).
        [string]$TargetAddress
    )
    $ErrorActionPreference = 'Stop'
    if (-not $WorkRoot) { $WorkRoot = Get-PmWorkRoot }
    $direct = [bool]$StageDir
    $stage = if ($direct) { $StageDir } else { Join-Path $WorkRoot "restore\$JobId" }
    if ($LogDir) { New-Item -ItemType Directory -Force -Path $LogDir | Out-Null; $global:PmRobocopyLog = Join-Path $LogDir "robocopy-$JobId-$env:COMPUTERNAME.log" } else { $global:PmRobocopyLog = $null }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $report = [ordered]@{ Computer = $env:COMPUTERNAME; Prtg = 'skipped'; License = 'skipped'; History = 'skipped'; Desktop = 'skipped'; Extra = 'skipped'; WebUrl = $null; Version = $null; RolledBack = $false; Errors = @() }

    Write-PmLog "Restore started on $env:COMPUTERNAME" 'STEP'

    # ---- integrity + disk space pre-checks
    if ($direct) {
        if (-not (Test-Path -LiteralPath (Join-Path $stage 'manifest.json'))) { throw "Staged package not found at $stage" }
        $manifest = Get-Content -LiteralPath (Join-Path $stage 'manifest.json') -Raw | ConvertFrom-Json
        $need = [int64]$manifest.stagingBytes
        $drive = if ($env:SystemDrive) { Get-PmLogicalDisk -Path ($env:SystemDrive + '\') } else { Get-PmLogicalDisk -Path $stage }
        # Local stage + move: the data already occupies the disk, only a margin is needed.
        $required = if ($MoveFromStage) { [int64]1GB } else { [int64]($need * 1.1 + 1GB) }
        if ($drive -and $drive.FreeSpace -lt $required) { throw ("Not enough free space on {0}: {1:N1} GB free, {2:N1} GB required." -f $drive.DeviceID, ($drive.FreeSpace / 1GB), ($required / 1GB)) }
        if ($drive) { Write-PmLog ("Reading the staged package from {0}. Disk space OK: {1:N1} GB free, ~{2:N1} GB needed." -f $stage, ($drive.FreeSpace / 1GB), ($required / 1GB)) 'OK' }
        else { Write-PmLog "Reading the staged package from $stage. Disk free space could not be read." 'WARN' }
    }
    if (-not $direct -and $ExpectedSha256) {
        Write-PmProgress 2 'Verifying package checksum'
        $h = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
        if ($h -ne $ExpectedSha256) { throw "Package checksum mismatch on target (expected $ExpectedSha256, got $h) - transfer corrupted." }
        Write-PmLog 'Package SHA-256 verified on target.' 'OK'
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not $direct) {
    $need = 0
    $zr = [IO.Compression.ZipFile]::OpenRead($ZipPath)
    try { foreach ($e in $zr.Entries) { $need += $e.Length } } finally { $zr.Dispose() }
    $drive = Get-PmLogicalDisk -Path $WorkRoot
    $required = [int64]($need * 2 + 1GB)   # extracted staging + restored data + margin
    if ($drive -and $drive.FreeSpace -lt $required) {
        throw ("Not enough free space on {0}: {1:N1} GB free, {2:N1} GB required." -f $drive.DeviceID, ($drive.FreeSpace / 1GB), ($required / 1GB))
    }
    if ($drive) { Write-PmLog ("Disk space OK: {0:N1} GB free, ~{1:N1} GB needed." -f ($drive.FreeSpace / 1GB), ($required / 1GB)) 'OK' }

    Write-PmProgress 5 'Extracting package'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
    New-Item -ItemType Directory -Force -Path $stage | Out-Null
    [IO.Compression.ZipFile]::ExtractToDirectory($ZipPath, $stage)
    $manifest = Get-Content -LiteralPath (Join-Path $stage 'manifest.json') -Raw | ConvertFrom-Json
    }
    Write-PmLog "Package from $($manifest.source.computer) created $($manifest.createdUtc)" 'OK'
    if ($manifest.PSObject.Properties['vpn'] -and $manifest.vpn -and $manifest.vpn.included) {
        Write-PmLog 'This older package also holds Windows VPN connections. PRTG Manager restores only PRTG - import the package in VPN Manager (Backups > Import) to restore the VPN part.' 'WARN'
    }

    # ---- history only (graph data)
    if ($RestorePrtg -and [string]$manifest.type -eq 'graphs') {
        try {
            $prtgNow = Get-PmPrtgInfo
            if (-not $prtgNow.Installed) { throw 'PRTG is not installed on this server - restore a full backup first.' }
            if ($manifest.prtg.version -and $prtgNow.Version) {
                $srcV = [version]($manifest.prtg.version -replace '[^\d\.]', ''); $dstV = [version]($prtgNow.Version -replace '[^\d\.]', '')
                if ($dstV -lt $srcV -and -not $AllowDowngrade) { throw "PRTG on this server ($dstV) is older than the one of the backup ($srcV) - update PRTG first (or allow downgrade)." }
            }
            Write-PmProgress 30 'History: copying'
            $gbox = @{}
            Restore-PmGraphData -StageGraphs (Join-Path $stage 'prtg\graphs') -Mode $GraphMode -StartServices $StartServices -HealthTimeoutMinutes $HealthTimeoutMinutes -Move $MoveFromStage | ForEach-Object { if ($_.PmType -eq 'graphs') { $gbox.R = $_ } else { $_ } }
            $g = $gbox.R
            $report.History = "restored ($($g.Copied) new, $($g.Replaced) replaced, $($g.Failed) failed)"
            $report.Prtg = if ($null -eq $g.Healthy) { 'not-started' } elseif ($g.Healthy) { 'ok' } else { 'unhealthy' }
            $report.WebUrl = $g.WebUrl
            if ($g.Failed) { $report.Errors += "History: $($g.Failed) file(s) could not be copied." }
            if ($g.Healthy -eq $false) { $report.Errors += 'PRTG did not come up completely after the history restore.' }
        } catch {
            $report.History = 'failed'; $report.Errors += "History: $_"
            Write-PmLog "History restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'History restore'
        }
    }

    # ---- PRTG
    if ($RestorePrtg -and $manifest.prtg.included) {
        # $settled: the restore reached an end state (done, rolled back or failed and handled). A cancelled job is
        # stopped without running catch blocks - the finally below then puts the previous state back.
        $undo = $null; $stopped = $false; $settled = $false; $prtgWasRunning = $false
        try {
            Write-PmProgress 15 'PRTG: checking installation'
            $prtg = Get-PmPrtgInfo
            $wasInstalled = [bool]$prtg.Installed   # PRTG already on this server: nothing is installed, its own data folder is used
            $cloneDir = Join-Path $stage 'prtg\programfull'
            if (-not $prtg.Installed -and -not $InstallerPath -and $manifest.prtg.programCloned -and (Test-Path -LiteralPath $cloneDir)) {
                # ---- clone install: same program files + same Windows services as the source
                $progPath = [string]$manifest.prtg.programPath
                $q = Split-Path $progPath -Qualifier -ErrorAction SilentlyContinue
                if (-not $q -or -not (Test-Path "$q\")) { $progPath = Join-Path ${env:ProgramFiles(x86)} 'PRTG Network Monitor' }
                Write-PmLog "PRTG is not installed here - installing the CLONED program files from the source to $progPath (no installer needed)..." 'STEP'
                if ($MoveFromStage -and -not (Test-Path -LiteralPath $progPath) -and ((Split-Path $cloneDir -Qualifier) -eq (Split-Path $progPath -Qualifier))) {
                    New-Item -ItemType Directory -Force -Path (Split-Path $progPath -Parent) | Out-Null
                    Move-Item -LiteralPath $cloneDir -Destination $progPath
                    $code = 0
                } else { $code = Invoke-PmRobocopy -Source $cloneDir -Destination $progPath }
                if (-not (Test-PmRobocopyOk $code)) { throw "Copying the PRTG program files failed (robocopy $code)." }
                $srcNet = [int]$manifest.prtg.netFrameworkRelease
                $dstNet = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full' -ErrorAction SilentlyContinue).Release
                if ($srcNet -and $dstNet -lt $srcNet) { Write-PmLog ".NET Framework on target (release $dstNet) is older than on the source ($srcNet). If PRTG does not start, install the same .NET Framework version." 'WARN' }
                foreach ($svc in @($manifest.prtg.services)) {
                    $bin = ([string]$svc.pathName).Replace([string]$manifest.prtg.programPath, $progPath)
                    if (Get-Service -Name $svc.name -ErrorAction SilentlyContinue) { & sc.exe delete $svc.name | Out-Null; Start-Sleep -Seconds 2 }
                    $np = @{ Name = $svc.name; BinaryPathName = $bin; DisplayName = $svc.displayName; StartupType = 'Automatic' }
                    if ($svc.description) { $np.Description = $svc.description }
                    New-Service @np | Out-Null
                    $regFile = Join-Path $stage "prtg\services\$($svc.name).reg"
                    if ($bin -eq $svc.pathName -and (Test-Path -LiteralPath $regFile)) { [void](Invoke-PmReg -Verb import -File $regFile) }   # recovery options etc.
                    if ($svc.startName -and $svc.startName -ne 'LocalSystem') { Write-PmLog "Service $($svc.name) ran as '$($svc.startName)' on the source - it now runs as LocalSystem; change it in services.msc if required." 'WARN' }
                    Write-PmLog "Service created: $($svc.name) -> $bin" 'OK'
                }
                $prtg = Get-PmPrtgInfo
                if (-not $prtg.Installed) { throw 'PRTG services could not be created from the clone.' }
                Write-PmLog "PRTG $($prtg.Version) cloned from the source and registered." 'OK'
            }
            if (-not $prtg.Installed) {
                if (-not $InstallerPath) { throw 'PRTG is not installed on this server, the package has no program clone and no installer was supplied. Upload the installer in the dashboard and run the restore again.' }
                $exe = $InstallerPath
                if ($InstallerPath -like '*.zip') {
                    $instDir = Join-Path $WorkRoot "installer\$JobId"
                    [IO.Compression.ZipFile]::ExtractToDirectory($InstallerPath, $instDir)
                    $exe = (Get-ChildItem -LiteralPath $instDir -Filter '*.exe' -Recurse | Select-Object -First 1).FullName
                }
                Write-PmLog "Installing PRTG silently: $exe $InstallerArgs (this can take 10+ minutes)" 'STEP'
                $proc = Start-Process -FilePath $exe -ArgumentList $InstallerArgs -Wait -PassThru
                if ($proc.ExitCode -ne 0) { throw "PRTG installer exited with code $($proc.ExitCode)" }
                $prtg = Get-PmPrtgInfo
                if (-not $prtg.Installed) { throw 'PRTG installer finished but PRTGCoreService is still missing.' }
                Write-PmLog "PRTG $($prtg.Version) installed." 'OK'
            }

            if ($manifest.prtg.version -and $prtg.Version) {
                $srcV = [version]($manifest.prtg.version -replace '[^\d\.]', '')
                $dstV = [version]($prtg.Version -replace '[^\d\.]', '')
                if ($dstV -lt $srcV) {
                    $msg = "Target PRTG $dstV is OLDER than source $srcV - PRTG cannot open a newer configuration."
                    if (-not $AllowDowngrade) { throw "$msg Upgrade the target first (or enable 'Allow downgrade')." }
                    Write-PmLog $msg 'WARN'
                } elseif ($dstV -gt $srcV) {
                    Write-PmLog "Target PRTG $dstV is newer than source $srcV - configuration will be upgraded on first start." 'WARN'
                } else { Write-PmLog "PRTG versions match ($dstV)." 'OK' }
            }

            # Remember the target's own license before anything is overwritten.
            $targetLicValues = @(Get-PmLicenseValues)
            $licKeep = Join-Path $WorkRoot "license-keep\$stamp"
            $targetLicFiles = @(Get-PmLicenseFiles -DataPath $prtg.DataPath)
            if ($targetLicFiles.Count) {
                New-Item -ItemType Directory -Force -Path $licKeep | Out-Null
                $targetLicFiles | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $licKeep -Force }
            }

            Write-PmProgress 25 'PRTG: stopping target services'
            $prtgWasRunning = ([string]$prtg.CoreStatus -eq 'Running')
            $stopped = $true   # set before the stop: a stop that fails half-way still has to be undone
            Stop-PmPrtgServices
            Write-PmLog 'Target PRTG services stopped.' 'OK'

            # Data path. PRTG was already installed here: its own data folder takes the restored data, so the
            # current folder is set aside and the rollback can put it back (a different path from the source
            # would leave the target's data where it is and make the rollback impossible).
            # A new installation keeps the source path when that drive exists here, otherwise the default.
            $srcDataPath = ([string]$manifest.prtg.dataPath).TrimEnd('\')
            $dataPath = ([string]$prtg.DataPath).TrimEnd('\')
            if ($wasInstalled) {
                Write-PmLog "PRTG $($prtg.Version) is already installed here - nothing is installed; the restored data goes into its data folder $dataPath (the current one is kept for the rollback)." 'OK'
                if ($srcDataPath -and $srcDataPath -ine $dataPath) { Write-PmLog "The source kept its data in $srcDataPath - here PRTG keeps using $dataPath." 'INFO' }
            } elseif ($srcDataPath) {
                $qual = Split-Path $srcDataPath -Qualifier -ErrorAction SilentlyContinue
                if ($qual -and (Test-Path "$qual\")) { $dataPath = $srcDataPath }
                else { Write-PmLog "Drive $qual does not exist on target - using $dataPath instead." 'WARN' }
            }
            if (-not $dataPath) {
                # the registry of this PRTG names no data folder: PRTG's default
                $dataPath = Join-Path $env:ProgramData 'Paessler\PRTG Network Monitor'
                Write-PmLog "PRTG names no data folder in the registry here - using the default $dataPath." 'WARN'
            }

            Write-PmProgress 35 'PRTG: backing up current target state'
            $regBackup = Join-Path $WorkRoot "rollback\$stamp"
            New-Item -ItemType Directory -Force -Path $regBackup | Out-Null
            foreach ($k in $prtg.RegistryKeys) {
                $native = $k -replace '^HKLM:\\', 'HKLM\'
                [void](Invoke-PmReg -Verb export -Key $native -File (Join-Path $regBackup (($native -replace '[\\: ]', '_') + '.reg')))
            }
            $old = $null
            $fwRule = 'PRTG Manager - PRTG Core (web + probes)'
            $fwExisted = [bool](Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) -and [bool](Get-NetFirewallRule -DisplayName $fwRule -ErrorAction SilentlyContinue)
            if (Test-Path -LiteralPath $dataPath) {
                $old = "$dataPath.pre-restore-$stamp"
                try { Rename-Item -LiteralPath $dataPath -NewName (Split-Path $old -Leaf); Write-PmLog "Existing data folder kept as $old" }
                catch {
                    # a partial copy must never become the rollback source: then nothing is changed and the restore stops here
                    $rc = Invoke-PmRobocopy -Source $dataPath -Destination $old
                    if (-not (Test-PmRobocopyOk $rc)) { throw "The current data folder could not be set aside (rename failed: $($_.Exception.Message); copy failed: robocopy $rc). Nothing was restored." }
                    Write-PmLog "Existing data folder copied to $old" 'OK'
                }
            }
            Write-PmLog "Rollback copy of registry: $regBackup" 'OK'
            # from here on a failure can be undone: the previous data folder and registry are kept
            if ($old -and (Test-Path -LiteralPath $old)) { $undo = @{ DataPath = $dataPath; Old = $old; Reg = $regBackup; Ports = @($prtg.ListenPorts); FirewallRule = $(if ($fwExisted) { '' } else { $fwRule }) } }

            Write-PmProgress 45 'PRTG: restoring data folder'
            $stageData = Join-Path $stage 'prtg\data'
            if ($MoveFromStage -and -not (Test-Path -LiteralPath $dataPath) -and ((Split-Path $stageData -Qualifier) -eq (Split-Path $dataPath -Qualifier))) {
                # Same volume: move instead of copy - no second copy of the data on the target disk.
                New-Item -ItemType Directory -Force -Path (Split-Path $dataPath -Parent) | Out-Null
                Move-Item -LiteralPath $stageData -Destination $dataPath
                $code = 0
                Write-PmLog 'Data folder moved into place (no extra disk space used).' 'OK'
            } else {
                $code = Invoke-PmRobocopy -Source $stageData -Destination $dataPath -Mirror
            }
            if (-not (Test-PmRobocopyOk $code)) { throw "robocopy restore of data failed ($code)" }
            if ($manifest.prtg.configSha256) {
                $h = (Get-FileHash -LiteralPath (Join-Path $dataPath 'PRTG Configuration.dat') -Algorithm SHA256).Hash
                if ($h -ne $manifest.prtg.configSha256) { throw 'PRTG Configuration.dat on target does not match the source (checksum) - aborting.' }
                Write-PmLog 'PRTG Configuration.dat verified (SHA-256 identical to source).' 'OK'
                if ($manifest.prtg.configStats) {
                    $tStats = Get-PmPrtgConfigStats -Path (Join-Path $dataPath 'PRTG Configuration.dat')
                    Write-PmLog "Configuration on target: $tStats" $(if ($tStats -eq $manifest.prtg.configStats) { 'OK' } else { 'WARN' })
                }
            }
            Write-PmLog "Data folder restored to $dataPath" 'OK'

            Write-PmProgress 55 'PRTG: importing registry'
            foreach ($rf in @($manifest.prtg.registryFiles)) {
                $file = Join-Path $stage "prtg\registry\$rf"
                if (Test-Path -LiteralPath $file) {
                    if ((Invoke-PmReg -Verb import -File $file) -eq 0) { Write-PmLog "Registry imported: $rf" 'OK' } else { Write-PmLog "reg import failed: $rf" 'WARN' }
                }
            }
            # the imported registry names the SOURCE's data folder: point it to the one used here
            if ($dataPath -ine $srcDataPath) {
                foreach ($core in 'HKLM:\SOFTWARE\WOW6432Node\Paessler\PRTG Network Monitor\Server\Core', 'HKLM:\SOFTWARE\Paessler\PRTG Network Monitor\Server\Core') {
                    if (Test-Path $core) { Set-ItemProperty -Path $core -Name 'Datapath' -Value ($dataPath + '\') }
                }
                Write-PmLog "Registry Datapath adjusted to $dataPath" 'OK'
            }

            # ---- web server binding: the source's IP addresses do not exist here
            Set-PmPrtgWebBinding -TargetAddress $TargetAddress | Where-Object { $_.PmType -ne 'binding' }

            # ---- license
            if ($CopyLicense) {
                $report.License = 'copied-from-source'
                Write-PmLog ("Source license copied to target ({0} registry value(s){1})." -f @($manifest.prtg.licenseValueNames).Count, $(if (@($manifest.prtg.licenseFiles).Count) { ", files: $(@($manifest.prtg.licenseFiles) -join ', ')" } else { '' })) 'OK'
                Write-PmLog 'Remember: a PRTG license may only be active on ONE core - keep the source stopped.' 'WARN'
            } else {
                foreach ($v in @(Get-PmLicenseValues)) { Remove-ItemProperty -LiteralPath $v.Path -Name $v.Name -ErrorAction SilentlyContinue }
                foreach ($v in $targetLicValues) {
                    if (-not (Test-Path -LiteralPath $v.Path)) { New-Item -Path $v.Path -Force | Out-Null }
                    New-ItemProperty -LiteralPath $v.Path -Name $v.Name -Value $v.Value -PropertyType ([string]$v.Kind) -Force | Out-Null
                }
                Get-PmLicenseFiles -DataPath $dataPath | Remove-Item -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $licKeep) { Get-ChildItem -LiteralPath $licKeep -File | Copy-Item -Destination $dataPath -Force }
                $report.License = if ($targetLicValues.Count -or $targetLicFiles.Count) { 'kept-target-license' } else { 'none (enter a license on the target)' }
                Write-PmLog ("Source license NOT copied - target keeps its own license ({0} value(s) restored)." -f $targetLicValues.Count) 'OK'
            }

            Write-PmProgress 60 'PRTG: restoring customisations'
            $progStage = Join-Path $stage 'prtg\program'
            foreach ($f in @($manifest.prtg.programFolders)) {
                $code = Invoke-PmRobocopy -Source (Join-Path $progStage $f) -Destination (Join-Path $prtg.ProgramPath $f)
                if (-not (Test-PmRobocopyOk $code)) { Write-PmLog "Could not restore '$f' ($code)" 'WARN' }
            }
            Write-PmLog "Customisation folders restored: $(@($manifest.prtg.programFolders) -join ', ')" 'OK'

            if ($OpenFirewall) {
                $opened = Set-PmPrtgFirewall -Ports @($manifest.prtg.listenPorts)
                Write-PmLog "Firewall opened for PRTG (TCP $($opened -join ', '))." 'OK'
            }

            if ($StartServices) {
                Write-PmProgress 70 'PRTG: starting and verifying'
                Write-PmLog 'Starting PRTG and waiting until it is FULLY up (core + probe running, web interface answering, stable)...' 'STEP'
                $box = @{}
                Invoke-PmHealthCheck -Box $box -TimeoutMinutes $HealthTimeoutMinutes -PreferredPorts @($manifest.prtg.listenPorts)
                $health = $box.Health
                $report.Version = $health.Version
                if ($health.Healthy) {
                    $report.WebUrl = $health.Url
                    $report.Prtg = 'ok'
                    try {
                        $ls = Get-PmPrtgLicenseState
                        if ($ls.Known -and $ls.NeedsActivation) {
                            $report.License = 'needs-activation'
                            Write-PmLog "LICENSE: PRTG on this server reports '$($ls.Edition)'. A PRTG license is bound to the system it was activated on, so it must be activated again for this server (PRTG > Setup > License Information). Until then PRTG pauses the sensors. The license on the source server is not affected by this." 'WARN'
                            if ($ls.LastError) { Write-PmLog "LICENSE: last activation attempt: $($ls.LastError)" 'WARN' }
                        } elseif ($ls.Known) {
                            $report.License = "active ($($ls.Edition), $($ls.MaxSensors) sensors)"
                            Write-PmLog "LICENSE: $($ls.Edition), $($ls.MaxSensors) sensors - active on this server." 'OK'
                        }
                    } catch { Write-PmLog "License state could not be read: $($_.Exception.Message)" 'DEBUG' }
                    Write-PmLog "PRTG $($health.Version) is fully UP on $env:COMPUTERNAME : $($health.Url) (core $($health.Core), probe $($health.Probe))" 'OK'
                    $ep = @((Get-PmPrtgInfo).ListenEndpoints)
                    $outside = @($ep | Where-Object { $_ -notmatch '^(127\.0\.0\.1|::1):' })
                    if ($outside.Count) { Write-PmLog "PRTG listens on: $($ep -join ', ')" 'OK' }
                    else { Write-PmLog "PRTG only listens on this server itself ($($ep -join ', ')) - it is not reachable from the network. Check the web server IP setting in the PRTG Administration Tool." 'WARN' }
                    $settled = $true
                } else {
                    $report.Prtg = 'unhealthy'
                    $report.Errors += "PRTG did not come up completely within $HealthTimeoutMinutes min ($($health.Message))."
                    Write-PmLog "PRTG did NOT come up completely ($($health.Message)). See '$dataPath\Logs\core' on the target. Rollback data: $dataPath.pre-restore-$stamp" 'ERROR'
                    if ($AutoRollback -and $undo) {
                        $ubox = @{}
                        Undo-PmPrtgRestore -DataPath $undo.DataPath -OldPath $undo.Old -RegBackup $undo.Reg -Stamp $stamp -HealthTimeoutMinutes $HealthTimeoutMinutes -Ports $undo.Ports -FirewallRule $undo.FirewallRule | ForEach-Object { if ($_.PmType -eq 'undo') { $ubox.R = $_ } else { $_ } }
                        $report.RolledBack = $true; $report.Prtg = if ($ubox.R -and $ubox.R.Healthy) { 'rolled-back' } else { 'rolled-back-unhealthy' }
                    }
                    $settled = $true
                }
            } else { $report.Prtg = 'restored-not-started'; $settled = $true }
        } catch {
            $report.Prtg = 'failed'; $report.Errors += "PRTG: $_"
            Write-PmLog "PRTG restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'PRTG restore'
            if ($AutoRollback -and $undo) {
                try {
                    $ubox = @{}
                    Undo-PmPrtgRestore -DataPath $undo.DataPath -OldPath $undo.Old -RegBackup $undo.Reg -Stamp $stamp -HealthTimeoutMinutes $HealthTimeoutMinutes -Ports $undo.Ports -FirewallRule $undo.FirewallRule | ForEach-Object { if ($_.PmType -eq 'undo') { $ubox.R = $_ } else { $_ } }
                    $report.RolledBack = $true; $report.Prtg = if ($ubox.R -and $ubox.R.Healthy) { 'rolled-back' } else { 'rolled-back-unhealthy' }
                } catch { Write-PmLog "Rollback failed: $($_.Exception.Message). The previous data is in $($undo.Old), the registry copy in $($undo.Reg)." 'ERROR' }
            } elseif ($stopped -and -not $undo -and $prtgWasRunning) {
                # failed before anything of PRTG was changed (e.g. setting the data folder aside): PRTG must not stay down
                try { Start-PmPrtgServices; Write-PmLog 'Nothing of PRTG had been changed yet - PRTG was started again.' 'WARN' }
                catch { Write-PmLog "PRTG could not be started again: $($_.Exception.Message). Start the services PRTGCoreService and PRTGProbeService." 'ERROR' }
            }
            $settled = $true
        } finally {
            if ($stopped -and -not $settled) {
                # Cancelled after PRTG was stopped (catch blocks do not run on a cancel). Output is dropped now, so the
                # log goes to a file next to the rollback data as well.
                $script:PmLogMirror = Join-Path $WorkRoot "rollback\cancelled-restore-$stamp.log"
                try {
                    New-Item -ItemType Directory -Force -Path (Split-Path $script:PmLogMirror -Parent) | Out-Null
                    Write-PmLog 'The restore was cancelled after PRTG had been stopped - putting the previous state back.' 'WARN' | Out-Null
                    if ($undo) {
                        Undo-PmPrtgRestore -DataPath $undo.DataPath -OldPath $undo.Old -RegBackup $undo.Reg -Stamp $stamp -HealthTimeoutMinutes $HealthTimeoutMinutes -Ports $undo.Ports -FirewallRule $undo.FirewallRule | Out-Null
                    } elseif ($prtgWasRunning) {
                        Start-PmPrtgServices
                        Write-PmLog 'Nothing of PRTG had been changed yet - PRTG was started again.' 'OK' | Out-Null
                    }
                } catch { Write-PmLog "Putting the previous state back failed: $($_.Exception.Message). Previous data: $(if ($undo) { $undo.Old } else { $dataPath }), registry copy: $(if ($undo) { $undo.Reg })." 'ERROR' | Out-Null }
                finally { $script:PmLogMirror = $null }
            }
        }
    }

    # ---- Desktop
    if ($RestoreDesktop -and $manifest.desktop.included) {
        Write-PmProgress 94 'Desktop: restoring files'
        try {
            $profiles = @{}
            foreach ($p in (Get-PmUserProfiles)) { $profiles[$p.Name.ToLowerInvariant()] = $p.Path }
            foreach ($uDir in (Get-ChildItem -LiteralPath (Join-Path $stage 'desktop') -Directory -ErrorAction SilentlyContinue)) {
                if ($uDir.Name -eq 'Public') { $dst = Join-Path $env:PUBLIC 'Desktop' }
                elseif ($profiles.ContainsKey($uDir.Name.ToLowerInvariant())) { $dst = Join-Path $profiles[$uDir.Name.ToLowerInvariant()] 'Desktop' }
                else {
                    $dst = Join-Path $env:SystemDrive "PrtgMover-Restored\Desktop\$($uDir.Name)"
                    Write-PmLog "User '$($uDir.Name)' has no profile on target - desktop restored to $dst" 'WARN'
                }
                $code = Invoke-PmRobocopy -Source $uDir.FullName -Destination $dst
                if (Test-PmRobocopyOk $code) { Write-PmLog "Desktop restored: $($uDir.Name) -> $dst" 'OK' } else { Write-PmLog "Desktop restore failed for $($uDir.Name) ($code)" 'WARN' }
            }
            $report.Desktop = 'ok'
        } catch { $report.Desktop = 'failed'; $report.Errors += "Desktop: $_"; Write-PmLog "Desktop restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'Desktop restore' }
    }

    # ---- Extra
    if ($RestoreExtra -and @($manifest.extra).Count -gt 0) {
        try {
            foreach ($e in @($manifest.extra)) {
                $src = Join-Path $stage "extra\$($e.index)"
                if ($e.kind -eq 'file') {
                    $parent = Split-Path $e.path -Parent
                    New-Item -ItemType Directory -Force -Path $parent | Out-Null
                    Copy-Item -LiteralPath (Join-Path $src (Split-Path $e.path -Leaf)) -Destination $e.path -Force
                } else { Invoke-PmRobocopy -Source $src -Destination $e.path | Out-Null }
                Write-PmLog "Extra restored: $($e.path)" 'OK'
            }
            $report.Extra = 'ok'
        } catch { $report.Extra = 'failed'; $report.Errors += "Extra: $_"; Write-PmLog "Extra restore failed: $(Format-PmError $_)" 'ERROR'; Write-PmErrorDetail $_ 'Extra restore' }
    }

    if (-not $direct -or $CleanupStage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    if ($RemovePackage -and $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force -ErrorAction SilentlyContinue }
    Write-PmProgress 100 'Restore finished'
    Write-PmLog "Restore finished on $env:COMPUTERNAME" 'STEP'
    New-PmResult @{ Report = [pscustomobject]$report }
}

function Get-PmPullList {
    <#
        Files below $Source (relative path, size, last write) without the excluded folders /
        file patterns. Used by the manager to pull or push file by file and to resume: only
        missing or changed files are transferred again.
    #>
    param([Parameter(Mandatory)][string]$Source, [string[]]$ExcludeDirs = @(), [string[]]$ExcludeFiles = @(), [switch]$Raw)
    $list = New-Object System.Collections.ArrayList
    if (Test-Path -LiteralPath $Source) {
        $root = (Get-Item -LiteralPath $Source).FullName.TrimEnd('\').TrimEnd('/')
        $xd = @($ExcludeDirs | Where-Object { $_ } | ForEach-Object { $_.Replace('/', '\').TrimEnd('\') + '\' })
        foreach ($f in (Get-ChildItem -LiteralPath $root -Recurse -File -Force -ErrorAction SilentlyContinue)) {
            $full = $f.FullName.Replace('/', '\')
            if (@($xd | Where-Object { $full.StartsWith($_, [StringComparison]::OrdinalIgnoreCase) }).Count) { continue }
            if (@($ExcludeFiles | Where-Object { $f.Name -like $_ }).Count) { continue }
            if ($f.Name -in 'desktop.ini', 'Thumbs.db') { continue }   # Windows shell junk
            $relRoot = $root.Replace('/', '\')
            [void]$list.Add([pscustomobject]@{ Rel = $full.Substring($relRoot.Length + 1); Size = $f.Length; Time = $f.LastWriteTimeUtc.Ticks })
        }
    }
    if ($Raw) { return $list }
    New-PmResult @{ Root = $Source; Files = @($list); Count = $list.Count; Bytes = [int64](($list | Measure-Object -Property Size -Sum).Sum) }
}

function New-PmTransferChunk {
    <#
        Packs a batch of files (relative to $Source) into one compressed zip so the manager can
        transfer many files - compressed - in a single copy. PRTG data compresses ~4-5x.
        Reads through .NET, so hidden/system files work too. The chunk is temporary.
    #>
    param([Parameter(Mandatory)][string]$Source, [Parameter(Mandatory)][string[]]$Files, [string]$ChunkPath)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    if (-not $ChunkPath) { $ChunkPath = Join-Path (Get-PmWorkRoot) ("chunks\{0}.zip" -f [guid]::NewGuid().ToString('N')) }
    # Never compete with a running PRTG for CPU: remoting host processes run below normal priority.
    if ($Host.Name -eq 'ServerRemoteHost') { try { [Diagnostics.Process]::GetCurrentProcess().PriorityClass = 'BelowNormal' } catch { } }
    New-Item -ItemType Directory -Force -Path (Split-Path $ChunkPath -Parent) | Out-Null
    if (Test-Path -LiteralPath $ChunkPath) { Remove-Item -LiteralPath $ChunkPath -Force }
    $zip = [IO.Compression.ZipFile]::Open($ChunkPath, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($rel in $Files) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $Source $rel), $rel.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
    New-PmResult @{ Path = $ChunkPath; Size = (Get-Item -LiteralPath $ChunkPath).Length; Count = $Files.Count }
}

function Expand-PmTransferChunk {
    <# Unpacks a chunk into $Destination (overwriting) and deletes the chunk. #>
    param([Parameter(Mandatory)][string]$ChunkPath, [Parameter(Mandatory)][string]$Destination)
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $n = 0
    $zip = [IO.Compression.ZipFile]::OpenRead($ChunkPath)
    try {
        foreach ($e in $zip.Entries) {
            if (-not $e.Name) { continue }
            $target = Join-Path $Destination ($e.FullName.Replace('/', '\'))
            $dir = Split-Path $target -Parent
            if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
            $n++
        }
    } finally { $zip.Dispose() }
    Remove-Item -LiteralPath $ChunkPath -Force -ErrorAction SilentlyContinue
    New-PmResult @{ Count = $n }
}

function Remove-PmTransferChunk {
    param([Parameter(Mandatory)][string]$ChunkPath)
    Remove-Item -LiteralPath $ChunkPath -Force -ErrorAction SilentlyContinue
    New-PmResult @{ Removed = $ChunkPath }
}

function Get-PmHostFacts {
    New-PmResult @{ Cores = [Environment]::ProcessorCount; Computer = $env:COMPUTERNAME }
}

function Clear-PmRemoteStages {
    <# Removes PRTG Manager's own temporary restore folders / chunks of earlier (cancelled) runs, except $Keep. #>
    param([string]$Keep)
    $root = Join-Path (Get-PmWorkRoot) 'restore'
    $removed = @()
    foreach ($d in (Get-ChildItem -LiteralPath $root -Force -ErrorAction SilentlyContinue)) {
        if ($Keep -and $d.FullName -eq $Keep.TrimEnd('\')) { continue }
        Remove-Item -LiteralPath $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        $removed += $d.Name
    }
    if ($removed.Count) { Write-PmLog "Removed leftovers of earlier runs: $($removed -join ', ')" 'INFO' }
    New-PmResult @{ Removed = $removed }
}

function New-PmRemoteDirectories {
    param([Parameter(Mandatory)][string]$Root, [string[]]$Relative = @())
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    foreach ($r in $Relative) { if ($r) { New-Item -ItemType Directory -Force -Path (Join-Path $Root $r) | Out-Null } }
    New-PmResult @{ Created = $Relative.Count }
}

function Complete-PmRemotePull {
    <# Source cleanup after the manager pulled everything: remove the VSS snapshot and the small local staging folder. #>
    param([string]$StageDir, [string]$ShadowId, [string]$ShadowLink)
    if ($ShadowId) { Remove-PmShadowCopy -Shadow ([pscustomobject]@{ Id = $ShadowId; Link = $ShadowLink }); Write-PmLog 'VSS snapshot removed.' 'OK' }
    if ($StageDir -and (Test-Path -LiteralPath $StageDir)) { Remove-Item -LiteralPath $StageDir -Recurse -Force -ErrorAction SilentlyContinue }
    $root = Get-PmWorkRoot
    $chunks = Join-Path $root 'chunks'
    if (Test-Path -LiteralPath $chunks) { Remove-Item -LiteralPath $chunks -Recurse -Force -ErrorAction SilentlyContinue }
    foreach ($d in (Join-Path $root 'staging'), (Join-Path $root 'out'), $root) {
        if ((Test-Path -LiteralPath $d) -and -not (Get-ChildItem -LiteralPath $d -Force -ErrorAction SilentlyContinue)) { Remove-Item -LiteralPath $d -Force -ErrorAction SilentlyContinue }
    }
    Write-PmLog 'Temporary files removed from the source - nothing left behind.' 'OK'
    New-PmResult @{ Done = $true }
}

function Remove-PmRemoteFile {
    param([Parameter(Mandatory)][string]$Path)
    Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    # Leave no trace: remove the (now empty) PrtgMover work folders again.
    $dir = Split-Path $Path -Parent
    while ($dir -and (Split-Path $dir -Leaf) -in 'out', 'staging', 'PrtgMover' -and (Test-Path -LiteralPath $dir)) {
        if (Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -notin 'staging', 'out' -or (Get-ChildItem -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue) }) { break }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        $dir = Split-Path $dir -Parent
    }
    New-PmResult @{ Removed = $Path }
}

function Get-PmDataBreakdown {
    <# READ-ONLY. Size of a PRTG data folder in one pass: total and the parts a backup can leave out. #>
    param([Parameter(Mandatory)][string]$Path)
    $r = [ordered]@{ Total = [int64]0; History = [int64]0; Logs = [int64]0; AutoBackups = [int64]0 }
    if (-not (Test-Path -LiteralPath $Path)) { return [pscustomobject]$r }
    $base = (Get-Item -LiteralPath $Path).FullName.TrimEnd('\') + '\'
    foreach ($f in (Get-ChildItem -LiteralPath $Path -Recurse -File -Force -ErrorAction SilentlyContinue)) {
        $r.Total += $f.Length
        $top = $f.FullName.Substring($base.Length).Split('\')[0]
        switch ($top) { 'Monitoring Database' { $r.History += $f.Length } 'Logs' { $r.Logs += $f.Length } 'Configuration Auto-Backups' { $r.AutoBackups += $f.Length } }
    }
    [pscustomobject]$r
}

function Initialize-PmRemoteWorkRoot {
    param([string]$WorkRoot)
    if (-not $WorkRoot) { $WorkRoot = Get-PmWorkRoot }
    New-Item -ItemType Directory -Force -Path (Join-Path $WorkRoot 'in') | Out-Null
    $drive = Get-PmLogicalDisk -Path $WorkRoot
    $prtg = Get-PmPrtgInfo
    $parts = [pscustomobject]@{ Total = [int64]0; History = [int64]0; Logs = [int64]0; AutoBackups = [int64]0 }
    $programBytes = [int64]0; $desktopBytes = [int64]0
    if ($prtg.Installed) {
        $parts = Get-PmDataBreakdown -Path $prtg.DataPath
        if ($prtg.ProgramPath) { $programBytes = [int64](Get-PmDirectorySize -Path $prtg.ProgramPath) }
    }
    foreach ($p in @(Get-PmUserProfiles) + @([pscustomobject]@{ Path = $env:PUBLIC })) { if ($p.Path) { $desktopBytes += [int64](Get-PmDirectorySize -Path (Join-Path $p.Path 'Desktop')) } }
    New-PmResult @{
        WorkRoot = $WorkRoot; Inbox = (Join-Path $WorkRoot 'in'); Prtg = $prtg; Computer = $env:COMPUTERNAME
        FreeBytes = $(if ($drive) { [int64]$drive.FreeSpace } else { [int64]0 }); PrtgDataBytes = [int64]$parts.Total
        # parts a backup can leave out or adds: used for the free-space estimate of a backup
        PrtgHistoryBytes = [int64]$parts.History; PrtgLogsBytes = [int64]$parts.Logs; PrtgAutoBackupBytes = [int64]$parts.AutoBackups
        PrtgProgramBytes = $programBytes; DesktopBytes = $desktopBytes
        IsAdmin = (Test-PmIsAdmin)
    }
}

# ---------------------------------------------------------------- tunnels (WireGuard now, IPIP uses the same address plan)

function Test-PmIPv4Address {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    $parsed = $null
    if (-not [Net.IPAddress]::TryParse($Value, [ref]$parsed)) { return $false }
    if ($parsed.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    return $Value -match '^(?:[0-9]{1,3}\.){3}[0-9]{1,3}$'
}

function Test-PmTunnelHost {
    <# A single host on the PRTG Mover tunnel network (never a default route). #>
    param([string]$Ip)
    if (-not (Test-PmIPv4Address $Ip)) { return $false }
    if ($Ip -notmatch '^10\.66\.66\.(\d+)$') { return $false }
    $n = [int]$Matches[1]
    return ($n -ge 1 -and $n -le 254)
}

function Get-PmTunnelAddresses {
    <# WireGuard uses 10.66.66.0/24. IPIP uses 10.66.67.0/24. Source is always .1. Split tunnel only. #>
    param(
        [Parameter(Mandatory)][int]$TargetCount,
        [ValidateSet('wireguard', 'ipip')][string]$Kind = 'wireguard'
    )
    if ($TargetCount -lt 1 -or $TargetCount -gt 250) { throw 'A tunnel needs between 1 and 250 target servers.' }
    $octet = if ($Kind -eq 'ipip') { 67 } else { 66 }
    $targets = New-Object System.Collections.Generic.List[string]
    foreach ($n in (2..($TargetCount + 1))) { $targets.Add("10.66.$octet.$n") }
    [pscustomobject]@{
        Source = "10.66.$octet.1"; Targets = $targets; Prefix = 24
        Port = $(if ($Kind -eq 'wireguard') { 51820 } else { 0 })
        Network = "10.66.$octet.0/24"; Kind = $Kind
    }
}

function Test-PmIpipHost {
    param([string]$Ip)
    if (-not (Test-PmIPv4Address $Ip)) { return $false }
    if ($Ip -notmatch '^10\.66\.67\.(\d+)$') { return $false }
    $n = [int]$Matches[1]
    return ($n -ge 1 -and $n -le 254)
}

function Test-PmTunnelShare {
    <# Admin share on either tunnel network, never a public address. #>
    param([string]$RemoteName)
    return [bool]($RemoteName -match '^\\\\10\.66\.6[67]\.\d+\\[^\\]+$')
}

function New-PmWireGuardConfigText {
    <#
        Split tunnel: AllowedIPs is only the other server's tunnel address (/32).
        A full tunnel (0.0.0.0/0) is refused - it would replace the server's default route.
    #>
    param(
        [Parameter(Mandatory)][string]$PrivateKey,
        [Parameter(Mandatory)][string]$Address,
        [Parameter(Mandatory)][int]$ListenPort,
        [Parameter(Mandatory)][object[]]$Peers
    )
    if ($Address -notmatch '^(10\.66\.66\.\d+)/24$') { throw "Tunnel address '$Address' must be 10.66.66.x/24." }
    if (-not (Test-PmTunnelHost $Matches[1])) { throw "Tunnel address '$Address' is outside 10.66.66.1-254." }
    if ($ListenPort -lt 1 -or $ListenPort -gt 65535) { throw "Listen port $ListenPort is not valid." }
    if (@($Peers).Count -lt 1) { throw 'A WireGuard config needs the other server as a peer.' }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.AppendLine('[Interface]')
    [void]$sb.AppendLine("PrivateKey = $PrivateKey")
    [void]$sb.AppendLine("Address = $Address")
    [void]$sb.AppendLine("ListenPort = $ListenPort")
    [void]$sb.AppendLine('')
    foreach ($p in @($Peers)) {
        $pub = [string]$p.PublicKey
        $tip = [string]$p.TunnelIp
        $eip = [string]$p.PublicIp
        if ([string]::IsNullOrWhiteSpace($pub)) { throw 'WireGuard peer is missing a public key.' }
        if (-not (Test-PmTunnelHost $tip)) { throw "Refusing peer '$tip'. AllowedIPs must be that server's tunnel address only, never 0.0.0.0/0." }
        if ([string]::IsNullOrWhiteSpace($eip) -or $eip -notmatch '^[A-Za-z0-9\.\-]+$') { throw 'WireGuard peer endpoint is missing.' }
        if ($eip -eq '0.0.0.0') { throw 'Refusing a full tunnel. The endpoint must be the other server.' }
        [void]$sb.AppendLine('[Peer]')
        [void]$sb.AppendLine("PublicKey = $pub")
        [void]$sb.AppendLine("AllowedIPs = $tip/32")
        [void]$sb.AppendLine("Endpoint = ${eip}:${ListenPort}")
        [void]$sb.AppendLine('PersistentKeepalive = 25')
        [void]$sb.AppendLine('')
    }
    $text = $sb.ToString().Trim() + "`r`n"
    if (-not (Test-PmTunnelConfigSafe $text)) { throw 'Refusing a WireGuard config that would change the default route.' }
    return $text
}

function Test-PmTunnelConfigSafe {
    param([string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }
    if ($Text -match '(?i)(^|[^\d])0\.0\.0\.0/0([^0-9]|$)') { return $false }
    if ($Text -match '::/0') { return $false }
    return $Text -match 'AllowedIPs = 10\.66\.66\.\d+/32'
}

function Hide-PmTunnelSecret {
    <# Drops WireGuard 'private key' lines before anything is logged or returned. #>
    param([string]$Text)
    if (-not $Text) { return '' }
    return (($Text -split "`r?`n") | Where-Object { $_ -notmatch '(?i)private\s*key' }) -join "`n"
}

function Get-PmWireGuardKeyDir { return 'C:\ProgramData\PrtgMover\wireguard' }

function Install-PmWireGuard {
    <# Installs the signed WireGuard MSI if needed and returns only the public key. #>
    $ErrorActionPreference = 'Stop'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'WireGuard needs 64-bit Windows.' }
    $wg = 'C:\Program Files\WireGuard\wg.exe'
    if (-not (Test-Path -LiteralPath $wg)) {
        Write-PmLog 'Installing WireGuard (split tunnel only; the default route is not changed).' 'STEP'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $msi = Join-Path $env:TEMP 'wireguard-amd64-1.1.msi'
        $url = 'https://download.wireguard.com/windows-client/wireguard-amd64-1.1.msi'
        $expected = '6DAA5D37A9E2950DFB8C48B95AB8E562CB2BAD1C785D020F38F97BEA4C6A5566'
        $ProgressPreference = 'SilentlyContinue'
        (New-Object System.Net.WebClient).DownloadFile($url, $msi)
        $hash = (Get-FileHash -LiteralPath $msi -Algorithm SHA256).Hash
        if ($hash -ne $expected) { Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue; throw "WireGuard installer hash mismatch ($hash)." }
        $p = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList @('/i', $msi, '/qn', '/norestart', 'DO_NOT_LAUNCH=1') -Wait -PassThru
        Remove-Item -LiteralPath $msi -Force -ErrorAction SilentlyContinue
        if ($p.ExitCode -ne 0 -and $p.ExitCode -ne 3010) { throw "WireGuard install failed (msiexec $($p.ExitCode))." }
        if (-not (Test-Path -LiteralPath $wg)) { throw 'WireGuard installed but wg.exe is missing.' }
        Write-PmLog 'WireGuard installed.' 'OK'
    } else {
        Write-PmLog 'WireGuard is already installed.' 'OK'
    }
    $keyDir = Get-PmWireGuardKeyDir
    New-Item -ItemType Directory -Force -Path $keyDir | Out-Null
    $privFile = Join-Path $keyDir 'private.key'
    if (-not (Test-Path -LiteralPath $privFile)) {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $wg
        $psi.Arguments = 'genkey'
        $psi.RedirectStandardOutput = $true
        $psi.RedirectStandardError = $true
        $psi.UseShellExecute = $false
        $proc = [Diagnostics.Process]::Start($psi)
        $priv = $proc.StandardOutput.ReadToEnd().Trim()
        $genErr = $proc.StandardError.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0 -or $priv.Length -lt 40) { throw "WireGuard key generation failed. $genErr" }
        [IO.File]::WriteAllText($privFile, $priv)
        & icacls.exe $privFile /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
    }
    $priv = [IO.File]::ReadAllText($privFile).Trim()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $wg
    $psi.Arguments = 'pubkey'
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $proc = [Diagnostics.Process]::Start($psi)
    $proc.StandardInput.Write($priv)
    $proc.StandardInput.Close()
    $pub = $proc.StandardOutput.ReadToEnd().Trim()
    $pubErr = $proc.StandardError.ReadToEnd()
    $proc.WaitForExit()
    if ($proc.ExitCode -ne 0 -or $pub.Length -lt 40) { throw "WireGuard public key failed. $pubErr" }
    New-PmResult @{ PublicKey = $pub; Computer = $env:COMPUTERNAME; Installed = $true }
}

function Enable-PmWireGuardEndpoint {
    param(
        [Parameter(Mandatory)][string]$Address,
        [int]$ListenPort = 51820,
        [Parameter(Mandatory)][object[]]$Peers
    )
    $ErrorActionPreference = 'Stop'
    $privFile = Join-Path (Get-PmWireGuardKeyDir) 'private.key'
    if (-not (Test-Path -LiteralPath $privFile)) { throw 'WireGuard private key is missing. Install WireGuard on this server first.' }
    $priv = [IO.File]::ReadAllText($privFile).Trim()
    $text = New-PmWireGuardConfigText -PrivateKey $priv -Address $Address -ListenPort $ListenPort -Peers $Peers
    $hopBefore = ''
    $before = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    if ($before.Count) { $hopBefore = [string]$before[0].NextHop }

    $keyDir = Get-PmWireGuardKeyDir
    $conf = Join-Path $keyDir 'prtg.conf'
    $utf8 = New-Object System.Text.UTF8Encoding $false
    [IO.File]::WriteAllText($conf, $text, $utf8)
    & icacls.exe $conf /inheritance:r /grant:r 'SYSTEM:(F)' 'Administrators:(F)' | Out-Null
    & icacls.exe $keyDir /inheritance:r /grant:r 'SYSTEM:(OI)(CI)(F)' 'Administrators:(OI)(CI)(F)' | Out-Null

    $peerIps = @($Peers | ForEach-Object { [string]$_.PublicIp } | Where-Object { $_ })
    foreach ($name in @('PrtgMover-WireGuard', 'PrtgMover-Tunnel-ICMP', 'PrtgMover-Tunnel-SMB')) {
        if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name }
    }
    New-NetFirewallRule -Name 'PrtgMover-WireGuard' -DisplayName 'PRTG Mover WireGuard' -Enabled True -Direction Inbound -Action Allow -Protocol UDP -LocalPort $ListenPort -RemoteAddress $peerIps -Profile Any | Out-Null
    New-NetFirewallRule -Name 'PrtgMover-Tunnel-ICMP' -DisplayName 'PRTG Mover tunnel ICMP' -Enabled True -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -RemoteAddress '10.66.66.0/24' -Profile Any | Out-Null

    $ui = 'C:\Program Files\WireGuard\wireguard.exe'
    if (Get-Service -Name 'WireGuardTunnel$prtg' -ErrorAction SilentlyContinue) {
        $rm = Start-Process -FilePath $ui -ArgumentList @('/uninstalltunnelservice', 'prtg') -Wait -PassThru -WindowStyle Hidden
        if ($rm.ExitCode -ne 0) { throw "Could not update the WireGuard tunnel (exit $($rm.ExitCode))." }
        Start-Sleep -Seconds 2
    }
    $p = Start-Process -FilePath $ui -ArgumentList @('/installtunnelservice', $conf) -Wait -PassThru -WindowStyle Hidden
    if ($p.ExitCode -ne 0) { throw "WireGuard tunnel did not start (exit $($p.ExitCode))." }
    Start-Sleep -Seconds 2
    $after = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    $hopAfter = if ($after.Count) { [string]$after[0].NextHop } else { '' }
    if ($hopBefore -and $hopAfter -and $hopBefore -ne $hopAfter) {
        Start-Process -FilePath $ui -ArgumentList @('/uninstalltunnelservice', 'prtg') -Wait -WindowStyle Hidden | Out-Null
        throw "WireGuard changed the default gateway from $hopBefore to $hopAfter. The tunnel was removed."
    }
    $svc = Get-Service -Name 'WireGuardTunnel$prtg' -ErrorAction SilentlyContinue
    Write-PmLog "WireGuard is up on $Address (UDP $ListenPort, only the other server). Default gateway is still $hopAfter." 'OK'
    New-PmResult @{ Computer = $env:COMPUTERNAME; Address = $Address; Port = $ListenPort; Service = $(if ($svc) { [string]$svc.Status } else { 'missing' }); Gateway = $hopAfter }
}

function Test-PmWireGuardLink {
    param([Parameter(Mandatory)][string]$PeerTunnelIp)
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmTunnelHost $PeerTunnelIp)) { throw "Refusing to probe '$PeerTunnelIp'." }
    $raw = @(& 'C:\Program Files\WireGuard\wg.exe' show prtg 2>&1 | ForEach-Object { "$_" })
    $safe = Hide-PmTunnelSecret ($raw -join "`n")
    $handshake = $safe -match 'latest handshake'
    & ping.exe -n 2 -w 1000 $PeerTunnelIp | Out-Null
    $pingOk = ($LASTEXITCODE -eq 0)
    if ($pingOk) { Write-PmLog "Tunnel reachability: $PeerTunnelIp answers ($(if ($handshake) { 'handshake ok' } else { 'ping ok' }))." 'OK' }
    else { Write-PmLog "Tunnel reachability: $PeerTunnelIp did not answer ping." 'WARN' }
    New-PmResult @{ Peer = $PeerTunnelIp; PingOk = [bool]$pingOk; Handshake = [bool]$handshake }
}

function Connect-PmUncShare {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Passed once over the already-authenticated remoting session so the source can sign in to the target admin share. Never logged.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Required by WNetAddConnection2 for the tunnel file copy.')]
    param(
        [Parameter(Mandatory)][string]$RemoteName,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmTunnelShare $RemoteName)) { throw 'The file share must be on the tunnel network (10.66.66.x or 10.66.67.x), not a public address.' }
    if (-not ('PmNetUse' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public class PmNetUse {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct NETRESOURCE {
        public int dwScope;
        public int dwType;
        public int dwDisplayType;
        public int dwUsage;
        public string lpLocalName;
        public string lpRemoteName;
        public string lpComment;
        public string lpProvider;
    }
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetAddConnection2(ref NETRESOURCE nr, string password, string username, int flags);
    [DllImport("mpr.dll", CharSet = CharSet.Unicode)]
    public static extern int WNetCancelConnection2(string name, int flags, bool force);
}
'@
    }
    $nr = New-Object PmNetUse+NETRESOURCE
    $nr.dwType = 1
    $nr.lpRemoteName = $RemoteName
    [void][PmNetUse]::WNetCancelConnection2($RemoteName, 0, $true)
    $code = [PmNetUse]::WNetAddConnection2([ref]$nr, $Password, $UserName, 0)
    if ($code -ne 0) { throw "Could not sign in to $RemoteName (Windows error $code)." }
    Write-PmLog "Signed in to $RemoteName for the tunnel copy." 'OK'
    New-PmResult @{ RemoteName = $RemoteName; Ok = $true }
}

function Disconnect-PmUncShare {
    param([Parameter(Mandatory)][string]$RemoteName)
    if ('PmNetUse' -as [type]) { [void][PmNetUse]::WNetCancelConnection2($RemoteName, 0, $true) }
    New-PmResult @{ RemoteName = $RemoteName; Ok = $true }
}

function Test-PmTunnelPeer {
    <# WinRM on the tunnel may only dial 10.66.66.x or 10.66.67.x. #>
    param([string]$Ip)
    return ((Test-PmTunnelHost $Ip) -or (Test-PmIpipHost $Ip))
}

function Enable-PmTunnelWinRm {
    <#
        WinRM listens for the other server. TCP 5985 is allowed only from the tunnel
        network, never from the public address. Same point-to-point shape as a
        bandwidth test aimed at the tunnel address.
    #>
    param([Parameter(Mandatory)][string]$TunnelNetwork)
    if ($TunnelNetwork -notin @('10.66.66.0/24', '10.66.67.0/24')) {
        throw "WinRM on the tunnel only accepts 10.66.66.0/24 or 10.66.67.0/24, not '$TunnelNetwork'."
    }
    $ErrorActionPreference = 'Stop'
    Enable-PSRemoting -Force -SkipNetworkProfileCheck | Out-Null
    Set-Service WinRM -StartupType Automatic
    Start-Service WinRM
    New-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -Name LocalAccountTokenFilterPolicy -Value 1 -PropertyType DWord -Force | Out-Null
    Set-Item WSMan:\localhost\MaxEnvelopeSizekb 8192
    Set-Item WSMan:\localhost\Shell\MaxMemoryPerShellMB 4096
    $name = 'PrtgMover-Tunnel-WinRM'
    if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name }
    New-NetFirewallRule -Name $name -DisplayName 'PRTG Mover tunnel WinRM' -Enabled True -Direction Inbound -Action Allow -Protocol TCP -LocalPort 5985 -RemoteAddress $TunnelNetwork -Profile Any | Out-Null
    Write-PmLog "WinRM TCP 5985 is open only from $TunnelNetwork (not from the public address)." 'OK'
    New-PmResult @{ Port = 5985; Network = $TunnelNetwork }
}

function Open-PmTunnelWinRmSession {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Passed once over the already-authenticated command channel so this server can sign in to the peer over the tunnel. Never logged.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'The peer is a tunnel address. The password is turned into a PSCredential and is not logged.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText', '', Justification = 'The peer password arrives once on the command channel and is wrapped only to build a PSCredential. It is not logged or stored.')]
    param(
        [Parameter(Mandatory)][string]$PeerTunnelIp,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password
    )
    if (-not (Test-PmTunnelPeer $PeerTunnelIp)) { throw "Refusing WinRM to '$PeerTunnelIp'. The session must use the tunnel address (10.66.66.x or 10.66.67.x)." }
    $item = Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction SilentlyContinue
    $cur = if ($item) { [string]$item.Value } else { '' }
    $parts = @($cur -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ -and $_ -ne '*' })
    if ($parts -notcontains $PeerTunnelIp) {
        $parts += $PeerTunnelIp
        Set-Item -Path WSMan:\localhost\Client\TrustedHosts -Value ($parts -join ',') -Force
    }
    $secure = ConvertTo-SecureString $Password -AsPlainText -Force
    $cred = New-Object System.Management.Automation.PSCredential($UserName, $secure)
    $opt = New-PSSessionOption -OpenTimeout 60000 -OperationTimeout 14400000 -IdleTimeout 14400000
    New-PSSession -ComputerName $PeerTunnelIp -Port 5985 -Credential $cred -Authentication Negotiate -SessionOption $opt -ErrorAction Stop
}

function Measure-PmTunnelWinRm {
    <#
        Sends 32 MB to the peer's tunnel address over WinRM and reports MB/s.
        The bytes take the tunnel path, the same way a point-to-point bandwidth test would.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Used only to open the tunnel WinRM session. Never logged.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Required to sign in to the peer tunnel address.')]
    param(
        [Parameter(Mandatory)][string]$PeerTunnelIp,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmTunnelPeer $PeerTunnelIp)) { throw "Refusing WinRM to '$PeerTunnelIp'. The session must use the tunnel address (10.66.66.x or 10.66.67.x)." }
    $session = Open-PmTunnelWinRmSession -PeerTunnelIp $PeerTunnelIp -UserName $UserName -Password $Password
    $local = Join-Path ([IO.Path]::GetTempPath()) 'prtg-mover-winrm-probe.bin'
    try {
        $remoteDir = 'C:\PrtgMover\tunnel\probe'
        Invoke-Command -Session $session -ScriptBlock { param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null } -ArgumentList $remoteDir
        $remote = Join-Path $remoteDir 'probe.bin'
        $fs = [IO.File]::Open($local, [IO.FileMode]::Create, [IO.FileAccess]::Write)
        try {
            $buf = New-Object byte[] 1048576
            for ($i = 0; $i -lt $buf.Length; $i++) { $buf[$i] = [byte]($i -band 255) }
            for ($n = 0; $n -lt 32; $n++) { $fs.Write($buf, 0, $buf.Length) }
        } finally { $fs.Dispose() }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Copy-Item -ToSession $session -LiteralPath $local -Destination $remote -Force
        $sw.Stop()
        Invoke-Command -Session $session -ScriptBlock { param($p) Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } -ArgumentList $remote
        $rate = 32 / [math]::Max(0.001, $sw.Elapsed.TotalSeconds)
        Write-PmLog ("WinRM {0}:5985  32 MB in {1:N2} s ({2:N1} MB/s). Point to point on the tunnel, the same shape as a bandwidth test." -f $PeerTunnelIp, $sw.Elapsed.TotalSeconds, $rate) 'OK'
        New-PmResult @{ Peer = $PeerTunnelIp; Port = 5985; Megabytes = 32; Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2); MegabytesPerSecond = [math]::Round($rate, 1) }
    } finally {
        Remove-Item -LiteralPath $local -Force -ErrorAction SilentlyContinue
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

function Send-PmTunnelWinRmBatch {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [Parameter(Mandatory)][string[]]$Files
    )
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $chunk = Join-Path ([IO.Path]::GetTempPath()) ('pm-tunnel-{0}.zip' -f [guid]::NewGuid().ToString('N'))
    $remoteChunk = 'C:\PrtgMover\tunnel\chunks\{0}.zip' -f [guid]::NewGuid().ToString('N')
    $zip = [IO.Compression.ZipFile]::Open($chunk, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($rel in $Files) {
            [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, (Join-Path $Source $rel), $rel.Replace('\', '/'), [IO.Compression.CompressionLevel]::Optimal)
        }
    } finally { $zip.Dispose() }
    try {
        Invoke-Command -Session $Session -ScriptBlock { param($p) New-Item -ItemType Directory -Force -Path (Split-Path $p -Parent) | Out-Null } -ArgumentList $remoteChunk
        Copy-Item -ToSession $Session -LiteralPath $chunk -Destination $remoteChunk -Force
        $size = [int64](Get-Item -LiteralPath $chunk).Length
        Invoke-Command -Session $Session -ScriptBlock {
            param($ChunkPath, $Dest)
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $opened = [IO.Compression.ZipFile]::OpenRead($ChunkPath)
            try {
                foreach ($e in $opened.Entries) {
                    if (-not $e.Name) { continue }
                    $target = Join-Path $Dest ($e.FullName.Replace('/', '\'))
                    $dir = Split-Path $target -Parent
                    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($e, $target, $true)
                }
            } finally { $opened.Dispose() }
            Remove-Item -LiteralPath $ChunkPath -Force -ErrorAction SilentlyContinue
        } -ArgumentList $remoteChunk, $Destination
        New-PmResult @{ WireBytes = $size; Count = $Files.Count }
    } finally {
        Remove-Item -LiteralPath $chunk -Force -ErrorAction SilentlyContinue
    }
}

function Send-PmTunnelWinRmCopy {
    <# Pushes the staged files to the other server over WinRM, using only its tunnel address. #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingPlainTextForPassword', '', Justification = 'Used only to open the tunnel WinRM session. Never logged.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingUsernameAndPasswordParams', '', Justification = 'Required to sign in to the peer tunnel address.')]
    param(
        [Parameter(Mandatory)][string]$PeerTunnelIp,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$Password,
        [Parameter(Mandatory)][string]$Destination,
        [string]$StageDir,
        [object[]]$PullItems = @()
    )
    $ErrorActionPreference = 'Stop'
    if ($Destination -notmatch '^C:\\PrtgMover\\tunnel(\\|$)') { throw "Refusing to write WinRM data to '$Destination'." }
    if (-not (Test-PmTunnelPeer $PeerTunnelIp)) { throw "Refusing WinRM to '$PeerTunnelIp'. The session must use the tunnel address (10.66.66.x or 10.66.67.x)." }
    $session = Open-PmTunnelWinRmSession -PeerTunnelIp $PeerTunnelIp -UserName $UserName -Password $Password
    $wire = [int64]0
    $fileCount = 0
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-Command -Session $session -ScriptBlock { param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null } -ArgumentList $Destination
        $roots = New-Object System.Collections.Generic.List[object]
        if ($StageDir -and (Test-Path -LiteralPath $StageDir)) {
            $roots.Add([pscustomobject]@{ Source = $StageDir; Target = ''; ExcludeDirs = @(); ExcludeFiles = @() })
        }
        foreach ($pi in @($PullItems)) {
            $src = [string]$pi.Source
            if (-not $src) { continue }
            $roots.Add([pscustomobject]@{ Source = $src; Target = [string]$pi.Target; ExcludeDirs = @($pi.ExcludeDirs); ExcludeFiles = @($pi.ExcludeFiles) })
        }
        foreach ($root in $roots) {
            $list = @(Get-PmPullList -Source $root.Source -ExcludeDirs @($root.ExcludeDirs) -ExcludeFiles @($root.ExcludeFiles) -Raw)
            $destRoot = if ($root.Target) { Join-Path $Destination $root.Target } else { $Destination }
            Invoke-Command -Session $session -ScriptBlock { param($d) New-Item -ItemType Directory -Force -Path $d | Out-Null } -ArgumentList $destRoot
            $batch = New-Object System.Collections.Generic.List[string]
            $batchBytes = [int64]0
            foreach ($f in $list) {
                $batch.Add([string]$f.Rel)
                $batchBytes += [int64]$f.Size
                if ($batchBytes -ge 256MB) {
                    $sent = Send-PmTunnelWinRmBatch -Session $session -Source $root.Source -Destination $destRoot -Files @($batch)
                    $wire += [int64]$sent.WireBytes
                    $fileCount += [int]$sent.Count
                    $batch.Clear()
                    $batchBytes = 0
                    $rate = ($wire / 1MB) / [math]::Max(0.001, $sw.Elapsed.TotalSeconds)
                    Write-PmLog ("WinRM {0}:5985  {1:N1} MB on the wire so far ({2:N1} MB/s)." -f $PeerTunnelIp, ($wire / 1MB), $rate) 'INFO'
                }
            }
            if ($batch.Count -gt 0) {
                $sent = Send-PmTunnelWinRmBatch -Session $session -Source $root.Source -Destination $destRoot -Files @($batch)
                $wire += [int64]$sent.WireBytes
                $fileCount += [int]$sent.Count
            }
        }
        $sw.Stop()
        $rate = ($wire / 1MB) / [math]::Max(0.001, $sw.Elapsed.TotalSeconds)
        Write-PmLog ("WinRM copy to {0}:5985 finished: {1} file(s), {2:N1} MB on the wire, {3:N1} MB/s." -f $PeerTunnelIp, $fileCount, ($wire / 1MB), $rate) 'OK'
        New-PmResult @{ Files = $fileCount; WireBytes = $wire; MegabytesPerSecond = [math]::Round($rate, 1); Destination = $Destination }
    } finally {
        if ($session) { Remove-PSSession $session -ErrorAction SilentlyContinue }
    }
}

function Test-PmTunnelPing {
    param([Parameter(Mandatory)][string]$PeerTunnelIp)
    $ErrorActionPreference = 'Stop'
    $onTunnel = (Test-PmTunnelHost $PeerTunnelIp) -or (Test-PmIpipHost $PeerTunnelIp)
    if (-not $onTunnel) { throw "Refusing to probe '$PeerTunnelIp'." }
    & ping.exe -n 2 -w 1000 $PeerTunnelIp | Out-Null
    $pingOk = ($LASTEXITCODE -eq 0)
    if ($pingOk) { Write-PmLog "Tunnel reachability: $PeerTunnelIp answers." 'OK' }
    else { Write-PmLog "Tunnel reachability: $PeerTunnelIp did not answer ping." 'WARN' }
    New-PmResult @{ Peer = $PeerTunnelIp; PingOk = [bool]$pingOk }
}

function Get-PmOutboundAddress {
    param([Parameter(Mandatory)][string]$Peer)
    $client = New-Object System.Net.Sockets.UdpClient
    try {
        $client.Connect($Peer, 9)
        return [string]$client.Client.LocalEndPoint.Address
    } finally { $client.Dispose() }
}

function Install-PmIpip {
    <# Downloads the official Wintun build and compiles the IPIP tunnel program. #>
    param([Parameter(Mandatory)][string]$Code)
    $ErrorActionPreference = 'Stop'
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'IPIP needs 64-bit Windows.' }
    if ($Code -notmatch 'class IpipTunnel') { throw 'IPIP source was not sent by the manager.' }
    $dir = 'C:\ProgramData\PrtgMover\ipip'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $zipHash = '07C256185D6EE3652E09FA55C0B673E2624B565E02C4B9091C79CA7D2F24EF51'
    $dllHash = 'E5DA8447DC2C320EDC0FC52FA01885C103DE8C118481F683643CACC3220DAFCE'
    $dll = Join-Path $dir 'wintun.dll'
    if (-not (Test-Path -LiteralPath $dll) -or (Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $dllHash) {
        Write-PmLog 'Downloading Wintun for the IPIP tunnel.' 'STEP'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $zip = Join-Path $env:TEMP 'wintun-0.14.1.zip'
        $ProgressPreference = 'SilentlyContinue'
        (New-Object System.Net.WebClient).DownloadFile('https://www.wintun.net/builds/wintun-0.14.1.zip', $zip)
        if ((Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash -ne $zipHash) {
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
            throw 'Wintun download hash mismatch.'
        }
        $unpack = Join-Path $env:TEMP 'wintun-unpack'
        if (Test-Path -LiteralPath $unpack) { Remove-Item -LiteralPath $unpack -Recurse -Force }
        Expand-Archive -LiteralPath $zip -DestinationPath $unpack -Force
        Copy-Item -LiteralPath (Join-Path $unpack 'wintun\bin\amd64\wintun.dll') -Destination $dll -Force
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        if ((Get-FileHash -LiteralPath $dll -Algorithm SHA256).Hash -ne $dllHash) { throw 'wintun.dll hash mismatch.' }
        Write-PmLog 'Wintun is in place.' 'OK'
    }
    $cs = Join-Path $dir 'IpipTunnel.cs'
    $exe = Join-Path $dir 'IpipTunnel.exe'
    [IO.File]::WriteAllText($cs, $Code)
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    if (-not (Test-Path -LiteralPath $csc)) { throw 'The .NET Framework compiler (csc.exe) is missing on this server.' }
    Get-Process -Name 'IpipTunnel' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 1
    $build = Start-Process -FilePath $csc -ArgumentList @('/nologo', '/platform:x64', '/optimize+', "/out:$exe", $cs) -Wait -PassThru -RedirectStandardOutput (Join-Path $dir 'build.out') -RedirectStandardError (Join-Path $dir 'build.err')
    if ($build.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $exe)) {
        $err = ''
        if (Test-Path -LiteralPath (Join-Path $dir 'build.err')) { $err = (Get-Content -LiteralPath (Join-Path $dir 'build.err') -Raw -ErrorAction SilentlyContinue) }
        throw "IPIP program did not compile. $err"
    }
    Write-PmLog 'IPIP tunnel program is compiled.' 'OK'
    New-PmResult @{ Installed = $true; Computer = $env:COMPUTERNAME }
}

function Enable-PmIpipEndpoint {
    param(
        [Parameter(Mandatory)][string]$LocalTunnel,
        [Parameter(Mandatory)][object[]]$Peers
    )
    $ErrorActionPreference = 'Stop'
    if (-not (Test-PmIpipHost $LocalTunnel)) { throw "IPIP address '$LocalTunnel' must be 10.66.67.1-254." }
    $dir = 'C:\ProgramData\PrtgMover\ipip'
    $exe = Join-Path $dir 'IpipTunnel.exe'
    if (-not (Test-Path -LiteralPath $exe)) { throw 'IPIP is not installed on this server yet.' }
    $peerIps = @()
    $lines = New-Object System.Collections.Generic.List[string]
    $firstPeer = $null
    foreach ($p in @($Peers)) {
        $tip = [string]$p.TunnelIp
        $eip = [string]$p.PublicIp
        if (-not (Test-PmIpipHost $tip)) { throw "Refusing IPIP peer '$tip'. The tunnel only carries 10.66.67.0/24." }
        if (-not (Test-PmIPv4Address $eip)) {
            $resolved = @([Net.Dns]::GetHostAddresses($eip) | Where-Object { $_.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork } | Select-Object -First 1)
            if ($resolved) { $eip = [string]$resolved[0] }
        }
        if (-not (Test-PmIPv4Address $eip)) { throw "IPIP peer endpoint '$($p.PublicIp)' must be an IPv4 address." }
        if (-not $firstPeer) { $firstPeer = $eip }
        $peerIps += $eip
        $lines.Add("peer=$tip,$eip")
    }
    if (-not $firstPeer) { throw 'IPIP needs the other server as a peer.' }
    $localPublic = Get-PmOutboundAddress -Peer $firstPeer
    $cfg = Join-Path $dir 'tunnel.txt'
    $text = "localTunnel=$LocalTunnel`r`nlocalPublic=$localPublic`r`n" + ($lines -join "`r`n") + "`r`n"
    [IO.File]::WriteAllText($cfg, $text)

    $hopBefore = ''
    $before = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    if ($before.Count) { $hopBefore = [string]$before[0].NextHop }

    foreach ($name in @('PrtgMover-IPIP', 'PrtgMover-IPIP-ICMP', 'PrtgMover-IPIP-SMB')) {
        if (Get-NetFirewallRule -Name $name -ErrorAction SilentlyContinue) { Remove-NetFirewallRule -Name $name }
    }
    New-NetFirewallRule -Name 'PrtgMover-IPIP' -DisplayName 'PRTG Mover IPIP' -Enabled True -Direction Inbound -Action Allow -Protocol 4 -RemoteAddress $peerIps -Profile Any | Out-Null
    New-NetFirewallRule -Name 'PrtgMover-IPIP-ICMP' -DisplayName 'PRTG Mover IPIP ICMP' -Enabled True -Direction Inbound -Action Allow -Protocol ICMPv4 -IcmpType 8 -RemoteAddress '10.66.67.0/24' -Profile Any | Out-Null

    $task = 'PRTG Mover IPIP'
    Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
    Get-Process -Name 'IpipTunnel' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    $action = New-ScheduledTaskAction -Execute $exe -Argument "`"$cfg`""
    $trigger = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -RunLevel Highest -LogonType ServiceAccount
    Register-ScheduledTask -TaskName $task -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    Start-ScheduledTask -TaskName $task
    $ready = Join-Path $dir 'ready.txt'
    $deadline = (Get-Date).AddSeconds(40)
    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $ready)) { Start-Sleep -Seconds 1 }
    if (-not (Test-Path -LiteralPath $ready)) {
        $tail = ''
        $log = Join-Path $dir 'tunnel.log'
        if (Test-Path -LiteralPath $log) { $tail = (Get-Content -LiteralPath $log -Tail 15 -ErrorAction SilentlyContinue) -join ' | ' }
        throw "IPIP tunnel did not start. $tail"
    }
    Start-Sleep -Seconds 1
    $after = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Sort-Object RouteMetric, InterfaceMetric)
    $hopAfter = if ($after.Count) { [string]$after[0].NextHop } else { '' }
    if ($hopBefore -and $hopAfter -and $hopBefore -ne $hopAfter) {
        Stop-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        Get-Process -Name 'IpipTunnel' -ErrorAction SilentlyContinue | Stop-Process -Force
        throw "IPIP changed the default gateway from $hopBefore to $hopAfter. The tunnel was stopped."
    }
    Write-PmLog "IPIP is up on $LocalTunnel via $localPublic (protocol 4, only the other server). Default gateway is still $hopAfter." 'OK'
    New-PmResult @{ Computer = $env:COMPUTERNAME; Address = $LocalTunnel; Public = $localPublic; Gateway = $hopAfter }
}
