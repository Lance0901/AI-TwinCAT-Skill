# TwinCAT Package Manager CLI (tcpkg) wrapper for Get-TcPackageInfo / Install-TcPackage (#229).
#
# Sources:
#   InfoSys "Working with the command line" (https://infosys.beckhoff.com/content/1033/tc3_installation/15698626059.html)
#   InfoSys "tcpkg list"    (https://infosys.beckhoff.com/content/1033/tc3_installation/21007205899.html)
#   InfoSys "tcpkg install" (https://infosys.beckhoff.com/content/1033/tc3_installation/21007208203.html):
#     'ID=version' pins the version, -y suppresses the confirmation; most actions need administrator
#     rights and the XAE Shell / Visual Studio may have to be closed during an install.
#   InfoSys "Managing TwinCAT Remote Manager versions" (https://infosys.beckhoff.com/content/1033/tc3_installation/20646415115.html):
#     Remote Manager versions are the package TwinCAT.StandardRM.XAE, several versions side by side.
# Measured 2026-11-12 (Windows 11 zh-TW, TcPkg 2.4.18, read-only list / source list / --help only):
#   - tcpkg is C:\ProgramData\Beckhoff\TcPkg\TcPkg.exe and on PATH; 'tcpkg --version' prints 2.4.18
#   - 'tcpkg list -i --as-json' = JSON array of every installed package (676 entries, ~1.7 MB, ~1.4 s):
#     Id, Version, Source (null when installed), Workload, InstallDate, ...
#   - 'tcpkg list <id> -a --as-json' = JSON array of every feed version (7-9 s, network): Id, Version,
#     Source (feed name, e.g. 'Beckhoff Outdated Feed'), IsPreview; one entry per feed and version
#   - an unknown package id: exit code 144, text 'Error: The package ... was not found' (no JSON)
#   - TwinCAT.StandardRM.XAE 4024.71.2 <-> <TwinCATDir>\3.1\Components\Base\Build_4024.71 (the folder
#     drops the third part); the installed 4024.71.2 is not in the feed any more (feed: 4024.71.5)
#   - 'tcpkg install --help' lists --dry-run; install itself was never run by this module's tests.

$script:TcPkgDefaultPackageIds = @('TwinCAT.Standard.XAE', 'TwinCAT.Standard.XAR', 'TwinCAT.StandardRM.XAE')
# Install-TcPackage only installs the IDE side (XAE / Remote Manager); never the runtime (XAR).
$script:TcPkgInstallablePackageIds = @('TwinCAT.Standard.XAE', 'TwinCAT.StandardRM.XAE')
$script:TcPkgRemoteManagerId = 'TwinCAT.StandardRM.XAE'
# Process names of the IDEs that host the TwinCAT XAE (Get-TcIdeExeName).
$script:TcPkgIdeProcessNames = @('TcXaeShell', 'devenv')
# tcpkg CLI and Package Manager UI (see Get-TcPkgRunningPackageManager)
$script:TcPkgManagerProcessNames = @('TcPkg', 'TwinCAT.Package.Manager.GUI')
$script:TcPkgSignerOrganization = 'Beckhoff Automation GmbH & Co. KG'

# <CommonApplicationData>\Beckhoff\TcPkg\TcPkg.exe (C:\ProgramData\... on this machine) when it
# exists, else $null (measured install location, 2026-11-12). The folder comes from
# [Environment]::GetFolderPath, not from $env:ProgramData, which the calling process can change
# (PR #257 review 2). The only executable Install-TcPackage runs. Seam for the unit tests.
function Get-TcPkgDefaultExecutable {
    [CmdletBinding()]
    param()
    $pd = [Environment]::GetFolderPath([Environment+SpecialFolder]::CommonApplicationData)
    if ([string]::IsNullOrWhiteSpace($pd)) { return $null }
    $default = Join-Path $pd 'Beckhoff\TcPkg\TcPkg.exe'
    if (Test-Path -LiteralPath $default -PathType Leaf) { return $default }
    $null
}

# Path of TcPkg.exe for the read-only Get-TcPackageInfo, or $null: the default location first, then
# PATH, .exe only (no .cmd / .bat). Seam for the unit tests.
function Get-TcPkgExecutable {
    [CmdletBinding()]
    param()
    $default = Get-TcPkgDefaultExecutable
    if ($null -ne $default) { return $default }
    $cmd = Get-Command -Name 'tcpkg.exe' -CommandType Application -ErrorAction SilentlyContinue | Where-Object { [string]$_.Source -like '*.exe' } | Select-Object -First 1
    if ($null -ne $cmd -and -not [string]::IsNullOrWhiteSpace([string]$cmd.Source)) { return [string]$cmd.Source }
    $null
}

# One argument for a Windows command line (CommandLineToArgvW rules).
function ConvertTo-TcPkgArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]' -and $Value -ne '') { return $Value }
    '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

# Runs -Exe with -Arguments, stdout / stderr read asynchronously (list -i writes ~1.7 MB, a
# synchronous read of one stream can dead-lock on the other). After -TimeoutSec the process is
# killed, or with -NoKillOnTimeout left running (install: killing tcpkg would not stop installers it
# may have started - .NET Framework has no Kill(entireProcessTree) - and a half-killed install is
# worse than one that finishes; its pid is returned).
# Returns [PSCustomObject]@{ exitCode ($null on timeout / start failure); stdout; stderr; timedOut;
# killed; processId; startError; elapsedSec; commandLine }. Seam for the unit tests.
function Invoke-TcPkgProcess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe, [string[]]$Arguments = @(), [int]$TimeoutSec = 60, [switch]$NoKillOnTimeout)
    $argLine = (@($Arguments | ForEach-Object { ConvertTo-TcPkgArgument $_ }) -join ' ')
    $out = [PSCustomObject]@{ exitCode = $null; stdout = ''; stderr = ''; timedOut = $false; killed = $false; processId = $null; startError = $null; elapsedSec = 0; commandLine = ("$(ConvertTo-TcPkgArgument $Exe) $argLine").Trim() }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Exe
    $psi.Arguments = $argLine
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.RedirectStandardInput = $true   # tcpkg must never wait for an answer on the console
    $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
    $psi.StandardErrorEncoding = [System.Text.Encoding]::UTF8
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try { $null = $p.Start() }
    catch { $out.startError = $_.Exception.Message; $p.Dispose(); return $out }
    try {
        $out.processId = $p.Id
        $p.StandardInput.Close()
        $so = $p.StandardOutput.ReadToEndAsync()
        $se = $p.StandardError.ReadToEndAsync()
        $ms = [int][math]::Min([double]$TimeoutSec * 1000, [double][int]::MaxValue)
        if (-not $p.WaitForExit($ms)) {
            $out.timedOut = $true
            if ($NoKillOnTimeout) { return $out }   # finally disposes the handle only; the process keeps running
            try { $p.Kill(); $out.killed = $true } catch { Write-Verbose "tcpkg kill failed: $($_.Exception.Message)" }
            $null = $p.WaitForExit(5000)
        }
        else {
            $p.WaitForExit()   # flushes the async readers
            $out.exitCode = $p.ExitCode
        }
        if ($so.Wait(5000)) { $out.stdout = [string]$so.Result }
        if ($se.Wait(5000)) { $out.stderr = [string]$se.Result }
    }
    finally {
        $out.elapsedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        $p.Dispose()
    }
    $out
}

# Last -Lines lines of a text (error details without dumping 1.7 MB into a result).
function Get-TcPkgTextTail {
    param([AllowNull()][string]$Text, [int]$Lines = 15)
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    @(($Text -split "`r?`n") | Where-Object { $_.Trim() -ne '' } | Select-Object -Last $Lines)
}

# Runs one 'tcpkg list ... --as-json' and parses it. Returns [PSCustomObject]@{ ok; items (parsed
# array); errorCode ($null | 'TCPKG_TIMEOUT' | 'TCPKG_LIST_FAILED'); message; run (the process
# result without stdout) }.
function Invoke-TcPkgList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$Arguments, [int]$TimeoutSec = 60)
    $r = Invoke-TcPkgProcess -Exe $Exe -Arguments $Arguments -TimeoutSec $TimeoutSec
    $run = [PSCustomObject]@{ commandLine = $r.commandLine; exitCode = $r.exitCode; timedOut = $r.timedOut; elapsedSec = $r.elapsedSec; stderrTail = @(Get-TcPkgTextTail $r.stderr); stdoutTail = @() }
    $res = [PSCustomObject]@{ ok = $false; items = @(); errorCode = $null; message = $null; run = $run }
    if ($null -ne $r.startError) { $res.errorCode = 'TCPKG_LIST_FAILED'; $res.message = "tcpkg could not be started ($($r.startError)): $($r.commandLine)"; return $res }
    if ($r.timedOut) { $res.errorCode = 'TCPKG_TIMEOUT'; $res.message = "tcpkg did not finish within $TimeoutSec s and was stopped: $($r.commandLine)"; return $res }
    if ($r.exitCode -ne 0) {
        $run.stdoutTail = @(Get-TcPkgTextTail $r.stdout)
        $res.errorCode = 'TCPKG_LIST_FAILED'; $res.message = "tcpkg exited with code $($r.exitCode): $($r.commandLine)"; return $res
    }
    $text = ([string]$r.stdout).Trim()
    $parsed = $null
    try {
        if (-not $text.StartsWith('[')) { throw 'the output is not a JSON array' }
        $parsed = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    }
    catch {
        $run.stdoutTail = @(Get-TcPkgTextTail $r.stdout 5)
        $res.errorCode = 'TCPKG_LIST_FAILED'; $res.message = "tcpkg output is not the expected JSON ($($_.Exception.Message)): $($r.commandLine)"; return $res
    }
    $res.items = @($parsed | Where-Object { $null -ne $_ })
    $res.ok = $true
    $res
}

# Build_<a>.<b> folder name of a package version '<a>.<b>.<c>' (measured mapping, see header), or $null.
function ConvertTo-TcPkgBuildFolderName {
    param([AllowNull()][string]$Version)
    if ($null -ne $Version -and $Version -match '^(\d+)\.(\d+)(?:\.\d+)*$') { return "Build_$($Matches[1]).$($Matches[2])" }
    $null
}

# Is this PowerShell running elevated (administrator token)? Seam for the unit tests.
function Test-TcIsElevated {
    [CmdletBinding()]
    param()
    try {
        $id = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        return ([System.Security.Principal.WindowsPrincipal]::new($id)).IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch { return $false }
}

# Processes named -Name (without .exe): @{ processId; name; path; title }. THROWS when the process
# list cannot be read (Install-TcPackage turns that into a blocker: fail closed); no match = @().
function Get-TcPkgProcessByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]]$Name)
    $list = foreach ($n in $Name) { [System.Diagnostics.Process]::GetProcessesByName($n) }
    @($list | Where-Object { $null -ne $_ } | Sort-Object Id | ForEach-Object {
            $path = $null; try { $path = $_.MainModule.FileName } catch { $path = $null }   # other user / elevated: not readable, not an error
            $title = $null; try { $title = $_.MainWindowTitle } catch { $title = $null }
            [PSCustomObject]@{ processId = $_.Id; name = $_.ProcessName; path = $path; title = $title }
        })
}

# Running IDE processes that host the XAE (TcXaeShell / devenv). Throws when the list cannot be read.
# Seam for the unit tests.
function Get-TcPkgRunningIde {
    [CmdletBinding()]
    param()
    @(Get-TcPkgProcessByName -Name $script:TcPkgIdeProcessNames)
}

# Running tcpkg CLI (TcPkg) and Package Manager UI processes. The UI name is the exe the start-menu
# shortcut 'TwinCAT Package Manager' points to (C:\ProgramData\Beckhoff\TcPkgUi\Gui\
# TwinCAT.Package.Manager.GUI.exe, read 2026-11-12); a running UI process was not observed (not
# measured). Throws when the list cannot be read. Seam for the unit tests.
function Get-TcPkgRunningPackageManager {
    [CmdletBinding()]
    param()
    @(Get-TcPkgProcessByName -Name $script:TcPkgManagerProcessNames)
}

# One DER TLV at -Offset of -Bytes: @{ tag; start (content offset); length; next }. Throws on a
# truncated / unsupported encoding (callers fail closed).
function Read-TcDerTlv {
    param([byte[]]$Bytes, [int]$Offset, [int]$Limit)
    if ($Offset + 2 -gt $Limit) { throw 'DER: truncated header' }
    $tag = [int]$Bytes[$Offset]; $l = [int]$Bytes[$Offset + 1]; $pos = $Offset + 2
    if ($l -ge 0x80) {
        $n = $l -band 0x7F
        if ($n -lt 1 -or $n -gt 3 -or $pos + $n -gt $Limit) { throw 'DER: unsupported length' }
        $l = 0
        for ($i = 0; $i -lt $n; $i++) { $l = ($l -shl 8) -bor [int]$Bytes[$pos + $i] }
        $pos += $n
    }
    if ($pos + $l -gt $Limit) { throw 'DER: truncated content' }
    @{ tag = $tag; start = $pos; length = $l; next = $pos + $l }
}

# Values of every organizationName (OID 2.5.4.10) attribute of a DER-encoded X.500 Name, read RDN by
# RDN from the encoding (not from a display string, so a quoted CN / OU that contains ', O=...' is
# never taken for an O attribute; .NET Framework has no RDN enumeration API). Throws on malformed DER.
function Get-TcX500OrganizationName {
    param([Parameter(Mandatory)][byte[]]$RawData)
    $b = $RawData
    $name = Read-TcDerTlv -Bytes $b -Offset 0 -Limit $b.Length
    if ($name.tag -ne 0x30 -or $name.next -ne $b.Length) { throw 'DER: not a Name SEQUENCE' }
    $values = @()
    $p = $name.start
    while ($p -lt $name.next) {
        $set = Read-TcDerTlv -Bytes $b -Offset $p -Limit $name.next
        if ($set.tag -ne 0x31) { throw 'DER: RDN is not a SET' }
        $q = $set.start
        while ($q -lt $set.next) {
            $atv = Read-TcDerTlv -Bytes $b -Offset $q -Limit $set.next
            if ($atv.tag -ne 0x30) { throw 'DER: attribute is not a SEQUENCE' }
            $oid = Read-TcDerTlv -Bytes $b -Offset $atv.start -Limit $atv.next
            if ($oid.tag -ne 0x06) { throw 'DER: attribute type is not an OID' }
            $val = Read-TcDerTlv -Bytes $b -Offset $oid.next -Limit $atv.next
            if ($oid.length -eq 3 -and $b[$oid.start] -eq 0x55 -and $b[$oid.start + 1] -eq 0x04 -and $b[$oid.start + 2] -eq 0x0A) {
                $enc = switch ($val.tag) {
                    0x0C { [System.Text.Encoding]::UTF8 }              # UTF8String
                    0x13 { [System.Text.Encoding]::ASCII }             # PrintableString
                    0x16 { [System.Text.Encoding]::ASCII }             # IA5String
                    0x14 { [System.Text.Encoding]::GetEncoding(28591) } # TeletexString (read as Latin-1)
                    0x1E { [System.Text.Encoding]::BigEndianUnicode }  # BMPString
                    default { $null }
                }
                # an O attribute in an unknown string type still counts (as a non-matching value)
                $values += $(if ($null -ne $enc) { $enc.GetString($b, $val.start, $val.length) } else { "<tag 0x$('{0:X2}' -f $val.tag)>" })
            }
            $q = $atv.next
        }
        $p = $set.next
    }
    , @($values)
}

# Is the signer the organisation Beckhoff Automation GmbH & Co. KG: exactly one O (organizationName)
# attribute, equal (case-sensitive) to that name? -Subject: an X500DistinguishedName (the signer
# certificate's SubjectName) or a subject string (parsed by .NET; unparseable = $false).
# Measured 2026-11-12: TcPkg.exe 2.4.18 is signed by 'CN=Beckhoff Automation GmbH & Co. KG,
# O=Beckhoff Automation GmbH & Co. KG, L=Verl, S=Nordrhein-Westfalen, C=DE', issuer 'CN=DigiCert
# Trusted G4 Code Signing RSA4096 SHA384 2021 CA1, O="DigiCert, Inc.", C=US', status Valid. The
# issuer is reported, not pinned: status Valid already requires a chain to a trusted root, and a
# pinned CA would refuse the next Beckhoff certificate from another CA.
function Test-TcPkgSignerSubject {
    param([AllowNull()][object]$Subject)
    try {
        $dn = if ($Subject -is [System.Security.Cryptography.X509Certificates.X500DistinguishedName]) { $Subject }
        elseif ([string]::IsNullOrWhiteSpace([string]$Subject)) { return $false }
        else { New-Object System.Security.Cryptography.X509Certificates.X500DistinguishedName -ArgumentList ([string]$Subject) }
        $o = @(Get-TcX500OrganizationName -RawData $dn.RawData)
        return ($o.Count -eq 1 -and [string]::Equals([string]$o[0], $script:TcPkgSignerOrganization, [StringComparison]::Ordinal))
    }
    catch { return $false }
}

# Authenticode signature of -Path: [PSCustomObject]@{ ok (Valid and signed by Beckhoff); status;
# subject; error }. May throw (caller fails closed). Seam for the unit tests.
function Test-TcPkgSignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $sig = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction Stop
    $cert = $sig.SignerCertificate
    $subject = if ($null -ne $cert) { [string]$cert.Subject } else { $null }
    $status = [string]$sig.Status
    $signerOk = ($null -ne $cert -and (Test-TcPkgSignerSubject $cert.SubjectName))
    [PSCustomObject]@{ ok = ($status -eq 'Valid' -and $signerOk); status = $status; subject = $subject; issuer = $(if ($null -ne $cert) { [string]$cert.Issuer } else { $null }); error = $(if ($status -ne 'Valid') { [string]$sig.StatusMessage } elseif (-not $signerOk) { 'the signer is not O=' + $script:TcPkgSignerOrganization } else { $null }) }
}

# --- PR #257 review: one-time plan tokens (consent) ---
# Install-TcPackage without -Approved stores the plan it showed: token -> @{ command; fingerprint;
# expiresUtc }. -Approved must present the token: unknown / used / expired / other command / other
# state = TCPKG_PLAN_REQUIRED. Kept in this module instance only (one MCP bridge process); a bridge
# restart or ReloadModule drops every token.
$script:TcPkgPlans = @{}
$script:TcPkgPlanTtlSec = 600

function New-TcPkgPlanToken {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Command, [Parameter(Mandatory)][string]$Fingerprint)
    if ($null -eq $script:TcPkgPlans) { $script:TcPkgPlans = @{} }
    # PR #257 review 2: expiry on the monotonic Stopwatch counter (a wall-clock change does not extend
    # or shorten it); expiresUtc is for display only
    $tick = [System.Diagnostics.Stopwatch]::GetTimestamp()
    foreach ($k in @($script:TcPkgPlans.Keys)) { if ($script:TcPkgPlans[$k].expiresTick -lt $tick) { $script:TcPkgPlans.Remove($k) } }
    $token = [guid]::NewGuid().ToString('N')
    $expTick = $tick + [long]($script:TcPkgPlanTtlSec * [System.Diagnostics.Stopwatch]::Frequency)
    $exp = [DateTime]::UtcNow.AddSeconds($script:TcPkgPlanTtlSec)
    $script:TcPkgPlans[$token] = [PSCustomObject]@{ command = $Command; fingerprint = $Fingerprint; expiresTick = $expTick; expiresUtc = $exp }
    [PSCustomObject]@{ token = $token; expiresUtc = $exp }
}

# Takes the token out of the store (one use, whatever the outcome). Returns @{ ok; reason
# ('missing' | 'unknown' | 'expired' | 'command'); fingerprint }. Install-TcPackage adds 'state' when
# the token is valid but the preconditions differ from the plan.
function Use-TcPkgPlanToken {
    [CmdletBinding()]
    param([AllowNull()][AllowEmptyString()][string]$Token, [Parameter(Mandatory)][string]$Command)
    if ([string]::IsNullOrWhiteSpace($Token)) { return [PSCustomObject]@{ ok = $false; reason = 'missing'; fingerprint = $null } }
    if ($null -eq $script:TcPkgPlans -or -not $script:TcPkgPlans.ContainsKey($Token)) { return [PSCustomObject]@{ ok = $false; reason = 'unknown'; fingerprint = $null } }
    $p = $script:TcPkgPlans[$Token]
    $script:TcPkgPlans.Remove($Token)
    if ([long]$p.expiresTick -lt [System.Diagnostics.Stopwatch]::GetTimestamp()) { return [PSCustomObject]@{ ok = $false; reason = 'expired'; fingerprint = $null } }
    if (-not [string]::Equals([string]$p.command, $Command, [StringComparison]::Ordinal)) { return [PSCustomObject]@{ ok = $false; reason = 'command'; fingerprint = $null } }
    [PSCustomObject]@{ ok = $true; reason = $null; fingerprint = [string]$p.fingerprint }
}

# Installed + feed versions of -PackageId. Returns [PSCustomObject]@{ errorCode; message; exe;
# installed[]; available[]; runs[]; remoteManagerRoot; remoteManagerBuilds }. errorCode $null = every
# tcpkg call succeeded. -NoAvailable skips the feed queries (offline).
function Get-TcPkgState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][string[]]$PackageId, [int]$TimeoutSec = 60, [switch]$NoAvailable)
    $out = [PSCustomObject]@{ errorCode = $null; message = $null; exe = $Exe; installed = @(); installedItems = @(); available = @(); runs = @(); remoteManagerRoot = $null; remoteManagerBuilds = @() }
    $want = @($PackageId | ForEach-Object { $_.ToLowerInvariant() })
    $inst = Invoke-TcPkgList -Exe $Exe -Arguments @('list', '-i', '--as-json') -TimeoutSec $TimeoutSec
    $out.runs += $inst.run
    if (-not $inst.ok) { $out.errorCode = $inst.errorCode; $out.message = $inst.message; return $out }
    $out.installedItems = @($inst.items)
    $installed = @($inst.items | Where-Object { $want -contains ([string]$_.Id).ToLowerInvariant() } | ForEach-Object {
            [PSCustomObject]@{ id = [string]$_.Id; version = [string]$_.Version; installDate = $(if ($null -ne $_.InstallDate) { [string]$_.InstallDate } else { $null }); workload = $_.Workload }
        } | Sort-Object id, { Get-TcPkgVersionKey $_.version })
    $out.installed = $installed
    if (-not $NoAvailable) {
        $avail = @()
        foreach ($id in $PackageId) {
            $l = Invoke-TcPkgList -Exe $Exe -Arguments @('list', $id, '-a', '--as-json') -TimeoutSec $TimeoutSec
            $out.runs += $l.run
            if (-not $l.ok) { $out.errorCode = $l.errorCode; $out.message = $l.message; break }
            $avail += @($l.items | Where-Object { ([string]$_.Id).ToLowerInvariant() -eq $id.ToLowerInvariant() } | ForEach-Object {
                    $iid = [string]$_.Id; $iv = [string]$_.Version
                    [PSCustomObject]@{ id = $iid; version = $iv; source = $(if ($null -ne $_.Source) { [string]$_.Source } else { $null }); isPreview = $(if ($null -ne $_.IsPreview) { [bool]$_.IsPreview } else { $false }); installed = (@($installed | Where-Object { $_.id -eq $iid -and $_.version -eq $iv }).Count -gt 0) }
                })
        }
        $out.available = @($avail | Sort-Object id, { Get-TcPkgVersionKey $_.version }, source)
    }
    $rmRelevant = @($want) -contains $script:TcPkgRemoteManagerId.ToLowerInvariant()
    if ($rmRelevant) {
        $xi = Get-TcXaeInstallInfo
        $out.remoteManagerRoot = $xi.remoteManagerRoot
        $out.remoteManagerBuilds = @($xi.remoteManagerBuilds)
        foreach ($e in @($out.installed) + @($out.available)) {
            if ($e.id -ne $script:TcPkgRemoteManagerId) { continue }
            $folder = ConvertTo-TcPkgBuildFolderName $e.version
            $b = if ($null -ne $folder) { $folder.Substring(6) } else { $null }
            $e | Add-Member -NotePropertyName buildFolder -NotePropertyValue $folder -Force
            $e | Add-Member -NotePropertyName buildFolderPath -NotePropertyValue $(if ($null -ne $folder -and -not [string]::IsNullOrWhiteSpace([string]$xi.remoteManagerRoot)) { Join-Path ([string]$xi.remoteManagerRoot) $folder } else { $null }) -Force
            $e | Add-Member -NotePropertyName buildFolderExists -NotePropertyValue ($null -ne $b -and @($xi.remoteManagerBuilds | Where-Object { [string]$_ -eq $b }).Count -gt 0) -Force
        }
    }
    $out
}

# Packages whose installed versions differ between two 'tcpkg list -i' item lists (#229 review M3:
# -y also confirms whatever tcpkg resolves as dependencies). Returns @(@{ id; before[]; after[] }).
function Compare-TcPkgInstalled {
    param([object[]]$Before = @(), [object[]]$After = @())
    $map = @{}
    foreach ($side in @(@{ k = 'before'; items = $Before }, @{ k = 'after'; items = $After })) {
        foreach ($i in @($side.items)) {
            if ($null -eq $i) { continue }
            $id = [string]$i.Id
            if (-not $map.ContainsKey($id)) { $map[$id] = @{ before = @(); after = @() } }
            $map[$id][$side.k] += [string]$i.Version
        }
    }
    @($map.Keys | Sort-Object | ForEach-Object {
            $b = @($map[$_].before | Sort-Object); $a = @($map[$_].after | Sort-Object)
            if (($b -join ',') -ne ($a -join ',')) { [PSCustomObject]@{ id = $_; before = $b; after = $a } }
        })
}

# Sort key of a dotted numeric version (zero-padded parts), so 4024.7 sorts before 4024.10.
function Get-TcPkgVersionKey {
    param([AllowNull()][string]$Version)
    @(([string]$Version) -split '\.' | ForEach-Object { $n = 0; if ([int]::TryParse($_, [ref]$n)) { $n.ToString('D10') } else { $_ } }) -join '.'
}

# #229: -Hint of a launch refusal (Connect-TcIde / Get-TcProjectVersion), plus the Get-TcPackageInfo /
# Install-TcPackage suggestion when Resolve-TcLaunchProgId found only the Remote Manager folder of the
# project version missing (.remoteManagerInstall). Only text: nothing is queried or installed here.
function Get-TcLaunchHint {
    [CmdletBinding()]
    param([AllowNull()][object]$Pick, [AllowNull()][string]$Hint)
    if ($null -eq $Pick -or $null -eq $Pick.PSObject.Properties['remoteManagerInstall'] -or $null -eq $Pick.remoteManagerInstall) { return $Hint }
    $extra = ([string]$script:TcPkgRemoteManagerInstallHint).Replace('<build>', [string]$Pick.remoteManagerInstall.build)
    if ([string]::IsNullOrWhiteSpace($Hint)) { return $extra }
    "$Hint $extra"
}
