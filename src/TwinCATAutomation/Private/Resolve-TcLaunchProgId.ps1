# Which IDE ProgID Connect-TcIde launches when no -ProgId is given (#72), and the guard that
# keeps it from launching a second IDE for a solution whose IDE this session is still starting
# (#136).
#
# --- #72: project build ---
# The version a TwinCAT project was last saved with is stored in the project file (InfoSys
# "Selection of a TwinCAT 3 version before loading a project",
# https://infosys.beckhoff.com/content/1033/tc3_remote_manager/3154642571.html). The page does not
# name the field. Measured (2026-11-06, read-only, this repo's test copies): the root element
# <TcSmProject ... TcVersion="3.1.4026.22"> of C:\Temp\Verify-4026-axis\...\AxisInterface_Type01_Library.tsproj
# and TcVersion="3.1.4024.71" of C:\Temp\Verify-4024-bfh\LangMang260618\BFH_1650.tsproj. Only
# .tsproj is read (the project type the .sln files of this repo reference).
#
# --- #72: which IDE may open which build ---
# InfoSys "System requirements" (https://infosys.beckhoff.com/content/1033/tc3_overview/6162419083.html):
# TcXaeShell = Visual Studio 2017 Shell, TcXaeShell64 = Visual Studio 2022 Shell, TcXaeShell64 only
# starting with build 4026. InfoSys "Managing TwinCAT Remote Manager versions"
# (https://infosys.beckhoff.com/content/1033/tc3_installation/20646415115.html): build 4024 and
# earlier require the integration into the TwinCAT XAE Shell or Visual Studio 2017/2019.
# Measured (2026-11-06, Windows 11, TwinCAT XAE 3.1.4026.22, HKCR ...\CLSID\{clsid}\LocalServer32):
#   TcXaeShell.DTE.15.0   -> C:\Program Files (x86)\Beckhoff\TcXaeShell\Common7\IDE\TcXaeShell.exe (32-bit TcXaeShell)
#   TcXaeShell.DTE.17.0   -> C:\Program Files\Beckhoff\TcXaeShell\Common7\IDE\TcXaeShell.exe (64-bit = TcXaeShell64;
#                            issue #72: ProductVersion 17.0.0.0)
#   VisualStudio.DTE.17.0 -> C:\Program Files\Microsoft Visual Studio\2022\Community\common7\ide\devenv.exe
# and every one of the three install roots holds
#   Common7\IDE\Extensions\Beckhoff Automation GmbH\TwinCAT XAE Base\extension.vsixmanifest
# with Identity Version 3.1.4026.22: that manifest is the evidence that the IDE has the TwinCAT
# XAE integrated and of which build (a VS2022 without it is not a TwinCAT IDE). Older builds the
# XAE can still load are under <TwinCATDir>\3.1\Components\Base\Build_<build> (measured: 4024.59,
# 4024.71, 4026.19, 4026.20, 4026.22; read as the installed Remote Manager versions, an inference
# from the folder contents, not stated by InfoSys).
# Rules (Resolve-TcLaunchProgId):
#   candidates: build >= 4026 -> TcXaeShell.DTE.17.0, then VisualStudio.DTE.17.0 (only with an XAE
#                    Base >= 4026, i.e. the XAE integrated); never the 32-bit shell (#72: a 4026
#                    solution opened in it left a v15 .suo next to the v17 one, highly correlated with
#                    the following 64-bit load hang, measured in #72)
#               build < 4026  -> TcXaeShell.DTE.15.0
#   a candidate is launched only when its XAE Base version EQUALS the project TcVersion (revision
#   included). Any other case (other version, unreadable XAE Base, only a Remote Manager folder of
#   the project build) -> PROGID_REQUIRED; no candidate registered / integrated ->
#   IDE_VERSION_NOT_REGISTERED.
# Known limits: strict revision compare (no Beckhoff compatibility rule between revisions found);
# a 4024 project on a machine whose XAE is 4026 (this repo's dev machine) always needs -ProgId until
# the Remote Manager behaviour of the Automation Interface is measured; a 4026 install whose only
# shell is the 32-bit TcXaeShell gets IDE_VERSION_NOT_REGISTERED for a 4026 project.

$script:TcKnownIdeProgIds = @('TcXaeShell.DTE.15.0', 'TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')

# Is -ProgId registered (COM class known)? Seam for the unit tests.
function Test-TcProgIdRegistered {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgId)
    $t = try { [Type]::GetTypeFromProgID($ProgId) } catch { $null }
    ($null -ne $t)
}

# Starts a new IDE of -ProgId and returns its DTE (throws when CreateInstance fails). Seam for the
# unit tests (Connect-TcIde never calls [Activator]::CreateInstance itself).
function New-TcIdeInstance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgId)
    $t = [Type]::GetTypeFromProgID($ProgId)
    if ($null -eq $t) { throw "ProgID '$ProgId' is not registered" }
    [Activator]::CreateInstance($t)
}

# Identity Version of a vsixmanifest, or $null.
function Read-TcVsixVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        try {
            while ($reader.Read()) {
                if ($reader.NodeType -eq [System.Xml.XmlNodeType]::Element -and $reader.LocalName -eq 'Identity') {
                    $v = $reader.GetAttribute('Version'); if ([string]::IsNullOrWhiteSpace($v)) { return $null }; return [string]$v
                }
            }
        }
        finally { $reader.Dispose() }
    }
    catch { Write-Verbose "vsixmanifest '$Path' unreadable ($($_.Exception.Message))" }
    $null
}

# Build number (third part) of a '3.1.<build>.<rev>' version, or $null.
function ConvertTo-TcBuildNumber {
    param([AllowNull()][string]$Version)
    if ($null -ne $Version -and $Version -match '^\d+\.\d+\.(\d+)') { return [int]$Matches[1] }
    $null
}

# What the registry and the install folder say about the IDE behind -ProgId (see the file header).
# Returns $null when the ProgID is not registered, else [PSCustomObject]@{ progId; exePath;
# installRoot; xaeVersion; xaeBuild } (xae* $null when the XAE Base manifest is not readable).
# Seam for the unit tests.
function Get-TcProgIdIdeInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ProgId)
    $clsid = try { [string](Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$ProgId\CLSID" -ErrorAction Stop).'(default)' } catch { $null }
    if ([string]::IsNullOrWhiteSpace($clsid)) { return $null }
    $exe = $null
    foreach ($view in 'CLSID', 'WOW6432Node\CLSID') {
        $v = try { [string](Get-ItemProperty -LiteralPath "Registry::HKEY_CLASSES_ROOT\$view\$clsid\LocalServer32" -ErrorAction Stop).'(default)' } catch { $null }
        if (-not [string]::IsNullOrWhiteSpace($v)) { $exe = $v; break }
    }
    $root = $null; $ver = $null
    if ($null -ne $exe) {
        # "C:\...\devenv.exe" /arg  or  C:\...\TcXaeShell.exe
        $exe = if ($exe -match '^\s*"([^"]+)"') { $Matches[1] } elseif ($exe -match '^\s*(\S.*?\.exe)') { $Matches[1] } else { $exe.Trim() }
        try { $root = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $exe)) } catch { $root = $null }   # <root>\Common7\IDE\x.exe
        if ($null -ne $root) {
            $ver = Read-TcVsixVersion -Path (Join-Path $root 'Common7\IDE\Extensions\Beckhoff Automation GmbH\TwinCAT XAE Base\extension.vsixmanifest')
        }
    }
    [PSCustomObject]@{ progId = $ProgId; exePath = $exe; installRoot = $root; xaeVersion = $ver; xaeBuild = (ConvertTo-TcBuildNumber $ver) }
}

# Installed TwinCAT build (HKLM ...\Beckhoff\TwinCAT3\System Build) and the Remote Manager builds
# (<TwinCATDir>\3.1\Components\Base\Build_<build>). Seam for the unit tests.
function Get-TcXaeInstallInfo {
    [CmdletBinding()]
    param()
    $build = $null; $rm = @()
    foreach ($k in 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\WOW6432Node\Beckhoff\TwinCAT3', 'Registry::HKEY_LOCAL_MACHINE\SOFTWARE\Beckhoff\TwinCAT3') {
        if ($null -eq $build) { $build = try { [int](Get-ItemProperty -LiteralPath "$k\System" -ErrorAction Stop).Build } catch { $null } }
        if ($rm.Count -eq 0) {
            $dir = try { [string](Get-ItemProperty -LiteralPath $k -ErrorAction Stop).TwinCATDir } catch { $null }
            if (-not [string]::IsNullOrWhiteSpace($dir)) {
                $base = Join-Path $dir '3.1\Components\Base'
                $rm = @(Get-ChildItem -LiteralPath $base -Directory -Filter 'Build_*' -ErrorAction SilentlyContinue | ForEach-Object { $_.Name.Substring(6) })
            }
        }
    }
    [PSCustomObject]@{ installedBuild = $build; remoteManagerBuilds = @($rm) }
}

# TcVersion attribute of the root element of one .tsproj. Returns @{ tcVersion; error } (only the
# root element is read: a .tsproj can be many MB).
function Get-TcTsprojTcVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @{ tcVersion = $null; error = 'file not found' } }
    $reader = $null
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        $null = $reader.MoveToContent()
        if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { return @{ tcVersion = $null; error = 'no root element' } }
        $v = $reader.GetAttribute('TcVersion')
        if ([string]::IsNullOrWhiteSpace($v)) { return @{ tcVersion = $null; error = 'no TcVersion attribute on the root element' } }
        return @{ tcVersion = [string]$v; error = $null }
    }
    catch { return @{ tcVersion = $null; error = "unreadable ($($_.Exception.Message))" } }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

# The .tsproj files a .sln references and their TcVersion.
# Returns [PSCustomObject]@{ solution; tsprojects = @(@{ path; tcVersion; build; error });
#   builds = @(distinct int); visualStudioVersion (from the .sln, evidence only);
#   reason ($null = exactly one build, read from EVERY referenced .tsproj) }
function Get-TcSolutionTcVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionPath)
    $result = [PSCustomObject]@{ solution = $SolutionPath; tsprojects = @(); builds = @(); visualStudioVersion = $null; reason = $null }
    $lines = try { [IO.File]::ReadAllLines($SolutionPath) } catch { $result.reason = "solution unreadable ($($_.Exception.Message))"; return $result }
    $dir = Split-Path -Parent $SolutionPath
    $projects = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*VisualStudioVersion\s*=\s*(\S+)') { $result.visualStudioVersion = $Matches[1]; continue }
        if ($line -match '^\s*Project\("\{[^}]*\}"\)\s*=\s*"[^"]*"\s*,\s*"([^"]+\.tsproj)"') {
            $rel = $Matches[1]
            $full = if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $dir $rel }
            $r = Get-TcTsprojTcVersion -Path $full
            $projects += [PSCustomObject]@{ path = $full; tcVersion = $r.tcVersion; build = (ConvertTo-TcBuildNumber $r.tcVersion); error = $r.error }
        }
    }
    $result.tsprojects = $projects
    $result.builds = @($projects | Where-Object { $null -ne $_.build } | ForEach-Object { [int]$_.build } | Sort-Object -Unique)
    $bad = @($projects | Where-Object { $null -eq $_.build })
    if ($projects.Count -eq 0) { $result.reason = 'the solution references no TwinCAT project (.tsproj)' }
    elseif ($bad.Count -gt 0) { $result.reason = "the TwinCAT version of $($bad.Count) referenced .tsproj file(s) is unknown ($(@($bad | ForEach-Object { "$($_.path): $($_.error)" }) -join '; '))" }
    elseif ($result.builds.Count -gt 1) { $result.reason = "the referenced .tsproj files were saved with different TwinCAT builds ($($result.builds -join ', '))" }
    $result
}

# Picks the ProgID to launch. Returns [PSCustomObject]@{ progId; selectedBy ('explicit' |
# 'tsproj-version' | 'only-one-registered'); registered; evidence; ide (Get-TcProgIdIdeInfo of the
# considered ProgIDs); errorCode; errorMessage }. errorCode set = nothing may be launched:
# TWINCAT_NOT_FOUND (nothing registered), IDE_VERSION_NOT_REGISTERED (the project's build is known,
# no registered IDE is confirmed for it), PROGID_REQUIRED (build not determinable, or not decidable
# which IDE is meant). Never guesses.
function Resolve-TcLaunchProgId {
    [CmdletBinding()]
    param([string]$ProgId, [string]$SolutionPath)
    $out = [PSCustomObject]@{ progId = $null; selectedBy = $null; registered = @(); evidence = $null; ide = @(); errorCode = $null; errorMessage = $null }
    if (-not [string]::IsNullOrWhiteSpace($ProgId)) {
        $out.registered = @($ProgId | Where-Object { Test-TcProgIdRegistered -ProgId $_ })
        if ($out.registered.Count -eq 0) {
            $out.errorCode = 'TWINCAT_NOT_FOUND'
            $out.errorMessage = "TwinCAT 3 XAE is not installed. None of the ProgIDs are registered: $ProgId. Install TwinCAT 3 XAE from https://www.beckhoff.com/twincat3/ or pass -ProgId."
            return $out
        }
        $out.progId = $ProgId; $out.selectedBy = 'explicit'
        return $out
    }
    $out.registered = @($script:TcKnownIdeProgIds | Where-Object { Test-TcProgIdRegistered -ProgId $_ })
    if ($out.registered.Count -eq 0) {
        $out.errorCode = 'TWINCAT_NOT_FOUND'
        $out.errorMessage = "TwinCAT 3 XAE is not installed. None of the ProgIDs are registered: $($script:TcKnownIdeProgIds -join ', '). Install TwinCAT 3 XAE from https://www.beckhoff.com/twincat3/ or pass -ProgId."
        return $out
    }
    $required = { param($why) $out.errorCode = 'PROGID_REQUIRED'; $out.errorMessage = "Cannot tell which IDE to launch: $why. Registered: $($out.registered -join ', '). No IDE was launched; pass -ProgId."; $out }
    if ([string]::IsNullOrWhiteSpace($SolutionPath)) {
        if ($out.registered.Count -eq 1) { $out.progId = $out.registered[0]; $out.selectedBy = 'only-one-registered'; return $out }
        return (& $required 'no -SolutionPath (no project to read the TwinCAT version from) and several IDEs are registered')
    }
    $ev = Get-TcSolutionTcVersion -SolutionPath $SolutionPath
    $out.evidence = $ev
    if ($null -ne $ev.reason) {
        # a solution without any .tsproj has nothing to contradict the only registered IDE;
        # an unreadable / conflicting version never falls back to it (m1)
        if ($ev.tsprojects.Count -eq 0 -and $out.registered.Count -eq 1) { $out.progId = $out.registered[0]; $out.selectedBy = 'only-one-registered'; return $out }
        return (& $required $ev.reason)
    }
    $build = [int]$ev.builds[0]
    # m-a: the full version (revision included) must match; 3.1.4024.59 != 3.1.4024.71. No
    # Beckhoff rule was found that makes another revision of the same build compatible (the
    # Remote Manager page only says a pinned project is OFFERED the latest revision of its
    # release), so the comparison is strict.
    $tcvs = @($ev.tsprojects | ForEach-Object { [string]$_.tcVersion } | Sort-Object -Unique)
    if ($tcvs.Count -gt 1) { return (& $required "the referenced .tsproj files were saved with different TwinCAT versions ($($tcvs -join ', '))") }
    $tcv = $tcvs[0]
    $infos = @($out.registered | ForEach-Object { Get-TcProgIdIdeInfo -ProgId $_ } | Where-Object { $null -ne $_ })
    $out.ide = $infos
    $info = { param($p) @($infos | Where-Object { $_.progId -eq $p }) | Select-Object -First 1 }
    $xaeList = (@($infos | ForEach-Object { "$($_.progId)=$(if ($_.xaeVersion) { $_.xaeVersion } else { 'unknown' })" }) -join ', ')
    # #147 M3-b: an XAE of another version is NOT accepted, not even with a Remote Manager folder
    # of the project build: whether the Automation Interface loads the project with that Remote
    # Manager is not measured yet.
    $untested = 'XAE build differs from the project build; whether the Automation Interface loads the project with the Remote Manager of that build is not measured yet'
    $wanted = if ($build -ge 4026) { @('TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0') } else { @('TcXaeShell.DTE.15.0') }
    $present = @($wanted | ForEach-Object { & $info $_ } | Where-Object { $null -ne $_ })
    if ($build -ge 4026) { $present = @($present | Where-Object { $null -ne $_.xaeBuild -and $_.xaeBuild -ge 4026 }) }   # VS2022 only with the XAE integrated
    if ($present.Count -eq 0) {
        $out.errorCode = 'IDE_VERSION_NOT_REGISTERED'
        $out.errorMessage = "The solution's TwinCAT project was saved with TcVersion $tcv, which needs $($wanted -join ' or ')$(if ($build -ge 4026) { ' with the TwinCAT XAE >= 4026 integrated' }); none is registered / confirmed (registered: $($out.registered -join ', '); XAE Base: $xaeList). No IDE was launched; pass -ProgId to choose one."
        return $out
    }
    $exact = @($present | Where-Object { [string]$_.xaeVersion -eq $tcv }) | Select-Object -First 1
    if ($null -ne $exact) { $out.progId = $exact.progId; $out.selectedBy = 'tsproj-version'; return $out }
    $inst = Get-TcXaeInstallInfo
    $out.evidence | Add-Member -NotePropertyName 'xaeInstall' -NotePropertyValue $inst -Force
    $unknown = @($present | Where-Object { [string]::IsNullOrWhiteSpace($_.xaeVersion) })
    $detail = if ($unknown.Count -eq $present.Count) { "the XAE version of $(@($present | ForEach-Object { $_.progId }) -join ' / ') is not readable" } else { $untested }
    return (& $required "the project was saved with TcVersion $tcv, but no IDE has exactly that XAE ($xaeList; Remote Manager builds: $(if ($inst.remoteManagerBuilds.Count) { $inst.remoteManagerBuilds -join ', ' } else { 'none' })): $detail")
}

# --- #136: the IDE this session launched for a solution ---
# Register-TcSessionLaunch remembers, per solution, the IDE launched for it: its DTE object (an
# RCW this module holds), ProgID and - only when it is CONFIRMED (ROT entry with the identical COM
# object, or the DTE's own main window) - pid + start time. Find-TcSessionLaunchedIde returns it
# while it is alive, so Connect-TcIde waits for / attaches to it instead of launching a second IDE
# for the same .sln. A pid that could only be guessed from the start time is never recorded: the
# record stays 'unconfirmed' until the ROT shows the identical DTE object.
# #149: also persisted (TcLaunchRecordStore.ps1, launched-ides.json), so a new PowerShell / MCP
# bridge / ReloadModule finds it again: a confirmed record by pid + start time + image name, an
# unconfirmed one (no DTE object to compare across processes) only blocks a second launch.

function Test-TcSameComObject {
    [CmdletBinding()]
    param([AllowNull()][object]$A, [AllowNull()][object]$B)
    if ($null -eq $A -or $null -eq $B) { return $false }
    if ([object]::ReferenceEquals($A, $B)) { return $true }
    $ba = $A.PSObject.BaseObject; $bb = $B.PSObject.BaseObject
    if (-not ($ba -is [System.__ComObject] -and $bb -is [System.__ComObject])) { return $false }
    if ([object]::ReferenceEquals($ba, $bb)) { return $true }
    $pa = [IntPtr]::Zero; $pb = [IntPtr]::Zero
    try {
        $pa = [System.Runtime.InteropServices.Marshal]::GetIUnknownForObject($ba)
        $pb = [System.Runtime.InteropServices.Marshal]::GetIUnknownForObject($bb)
        return ($pa -eq $pb)
    }
    catch { return $false }
    finally {
        if ($pa -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pa) }
        if ($pb -ne [IntPtr]::Zero) { [void][System.Runtime.InteropServices.Marshal]::Release($pb) }
    }
}

# The ROT entry whose object IS -Dte (no DTE call is made), or $null.
function Find-TcRotEntryForDte {
    [CmdletBinding()]
    param([AllowNull()][object]$Dte)
    if ($null -eq $Dte) { return $null }
    foreach ($e in @(Get-AllComObjects -IncludeDisplayName)) {
        if ($null -eq $e) { continue }
        if (Test-TcSameComObject -A $e['Object'] -B $Dte) { return $e }
    }
    $null
}

function Register-TcSessionLaunch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Solution, [Parameter(Mandatory)][string]$ProgId, [AllowNull()][object]$Dte, [int]$ProcessId = 0, [AllowNull()][object]$LaunchTime, [string]$LaunchId, [switch]$Restored)
    if ($null -eq $script:TcLaunchedIdeSolutions) { $script:TcLaunchedIdeSolutions = @{} }
    $key = if ($ProcessId -gt 0) { Get-TcIdeProcessKey -ProcessId $ProcessId } else { $null }
    if ([string]::IsNullOrWhiteSpace($LaunchId)) { $LaunchId = [guid]::NewGuid().ToString('N') }
    $rec = [PSCustomObject]@{
        solution = $Solution; progId = $ProgId; dte = $Dte; launchTime = $LaunchTime
        processId = $(if ($null -ne $key) { $ProcessId } else { 0 }); processKey = $key
        launchId = $LaunchId; restored = [bool]$Restored; guessedRecord = $null; otherSession = $null
    }
    $script:TcLaunchedIdeSolutions[$Solution.ToLowerInvariant()] = $rec
    $rec
}

function Clear-TcSessionLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Solution)
    if ($null -ne $script:TcLaunchedIdeSolutions) { $script:TcLaunchedIdeSolutions.Remove($Solution.ToLowerInvariant()) }
    # #149: the persisted record too (a confirmed one keeps its ownership, without the solution)
    $null = Clear-TcLaunchRecordSolution -Solution $Solution
}

# Disconnect-TcIde -ForgetPendingLaunch (#147 m-b): drops every launch record whose pid is NOT
# confirmed (pid-unconfirmed), so the next Connect-TcIde for that solution may launch again. The
# IDE itself is not touched (it is not known to be ours). Returns @{ Dropped; Failure }: the
# module records and (#149) the persisted unconfirmed records (one entry per launch); Failure =
# why the file could not be updated, or $null.
function Clear-TcUnconfirmedLaunches {
    [CmdletBinding()]
    param()
    $dropped = @()
    if ($null -ne $script:TcLaunchedIdeSolutions) {
        foreach ($k in @($script:TcLaunchedIdeSolutions.Keys)) {
            $r = $script:TcLaunchedIdeSolutions[$k]
            if ($null -ne $r.processKey) { continue }
            $dropped += [PSCustomObject]@{ solution = $r.solution; progId = $r.progId; launchTime = $(if ($null -ne $r.launchTime) { ([DateTime]$r.launchTime).ToUniversalTime().ToString('o') } else { $null }); launchId = $r.launchId; processId = 0; persisted = $false }
            $script:TcLaunchedIdeSolutions.Remove($k)
        }
    }
    $file = Clear-TcUnconfirmedLaunchRecords
    foreach ($d in @($file.Dropped)) {
        $same = @($dropped | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.launchId) -and [string]$_.launchId -eq [string]$d.launchId })
        if ($same.Count -gt 0) { $same[0].persisted = $true; $same[0].processId = $d.processId } else { $dropped += $d }
    }
    @{ Dropped = @($dropped); Kept = @($file.Kept); Failure = $file.Failure }
}

# The launch record of -Solution while that IDE can still be alive, else $null (record dropped).
# An unconfirmed record is confirmed here when the ROT has the identical DTE object (pid from the
# moniker; then Add-TcLaunchedIde makes it owned). It is dropped only when no process of its exe
# started since the launch is running any more.
function Find-TcSessionLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Solution)
    $rec = $null
    if ($null -ne $script:TcLaunchedIdeSolutions) { $rec = $script:TcLaunchedIdeSolutions[$Solution.ToLowerInvariant()] }
    if ($null -eq $rec) {
        # #149: launched by an earlier module instance (bridge restart / ReloadModule)? Only a
        # VALID persisted record counts (pid + start time + image name); an unreadable / corrupt
        # file gives nothing, so it never blocks a launch or makes an IDE owned.
        $p = Find-TcLaunchRecordForSolution -Solution $Solution
        if ($null -eq $p) { return $null }
        $confirmed = Test-TcLaunchRecordConfirmed -Record $p
        $lt = $null; try { $lt = (ConvertTo-TcUtcDate $p.launchedAt).ToLocalTime() } catch { $lt = $null }
        if (-not (Request-TcLaunchRecordOwnership -Record $p)) {
            # #152 M1: launched by another LIVE TcAuto session: it still blocks a second launch for
            # this .sln (#149), but is never attached or owned here, and not cached (that session
            # may end; the next lookup reads the file again)
            Write-Verbose "Launch record of '$Solution' belongs to another TcAuto session (host pid $($p.hostPid)); not owned"
            return [PSCustomObject]@{
                solution = $Solution; progId = [string]$p.progId; dte = $null; launchTime = $lt
                processId = 0; processKey = $null; launchId = [string]$p.launchId; restored = $true
                otherSession = [PSCustomObject]@{ hostPid = $p.hostPid; hostState = (Get-TcLaunchRecordHostState -Record $p); moduleInstanceId = $p.moduleInstanceId; processId = [int]$p.pid; pidSource = [string]$p.pidSource }
                guessedRecord = $null
            }
        }
        $rec = Register-TcSessionLaunch -Solution $Solution -ProgId ([string]$p.progId) -Dte $null -ProcessId $(if ($confirmed) { [int]$p.pid } else { 0 }) -LaunchTime $lt -LaunchId ([string]$p.launchId) -Restored
        if ($confirmed) {
            if ($null -eq $rec.processKey) { Clear-TcSessionLaunchedIde -Solution $Solution; return $null }
            Add-TcLaunchedIde -ProcessId ([int]$p.pid)
        }
        else {
            # m2: no DTE object to compare across processes; expiry is decided by the guessed
            # pid + start time of the file record
            $rec.guessedRecord = $p
        }
        Write-Verbose "Launch record of '$Solution' restored from the state file (pid $($p.pid), $($p.pidSource), module instance $($p.moduleInstanceId))"
        return $rec
    }
    if ($null -ne $rec.guessedRecord) {
        if (-not (Test-TcLaunchRecordValid -Record $rec.guessedRecord)) { Clear-TcSessionLaunchedIde -Solution $Solution; return $null }   # guessed process gone / recycled
        return $rec
    }
    if ($null -ne $rec.processKey) {
        if ((Get-TcIdeProcessKey -ProcessId $rec.processId) -ne $rec.processKey) { Clear-TcSessionLaunchedIde -Solution $Solution; return $null }   # gone / pid recycled
        return $rec
    }
    $e = Find-TcRotEntryForDte -Dte $rec.dte
    if ($null -ne $e -and [int]$e['ProcessId'] -gt 0) {
        $p = [int]$e['ProcessId']
        $rec.processKey = Get-TcIdeProcessKey -ProcessId $p
        if ($null -ne $rec.processKey) {
            $rec.processId = $p; Add-TcLaunchedIde -ProcessId $p
            $null = Save-TcLaunchRecord -LaunchId $rec.launchId -ProcessId $p -PidSource 'rot-identity' -ProgId $rec.progId -Solution $rec.solution -LaunchTime $rec.launchTime
            return $rec
        }
        Clear-TcSessionLaunchedIde -Solution $Solution; return $null
    }
    $since = $null; try { $since = ([DateTime]$rec.launchTime).AddSeconds(-2) } catch { $since = $null }
    $exe = Get-TcIdeExeName -ProgId $rec.progId
    $young = @(Get-Process -Name $exe -ErrorAction SilentlyContinue | Where-Object { $st = $null; try { $st = $_.StartTime } catch { }; ($null -eq $since) -or (($null -ne $st) -and $st -ge $since) })
    if ($young.Count -eq 0) { Clear-TcSessionLaunchedIde -Solution $Solution; return $null }
    $rec
}

# Polls the ROT for the DTE of the launched IDE until it answers Version + Solution (500 ms, max
# -TimeoutSec). Before every DTE read the process is scanned for a modal dialog
# (Find-TcIdeModalDialog -ProcessId): a dialog makes DTE calls block forever, so it is reported
# instead of read; an incomplete scan is not read either (unknown != no dialog, #42). The reads
# themselves are single attempts (Invoke-TcComRetry -MaxRetries 1).
# Returns [PSCustomObject]@{ state ('ready' | 'other-solution' | 'busy' | 'unreadable' |
# 'not-in-rot' | 'pid-unconfirmed' | 'dialog' | 'scan-incomplete' | 'gone'); entry; solution;
# dialog; waitedSec }.
$script:TcLaunchPendingWaitSec = 60
# how long Connect-TcIde looks for the ROT entry of a DTE it just launched (#147 M2)
$script:TcLaunchRotWaitSec = 10
function Wait-TcSessionLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record, [int]$TimeoutSec = $script:TcLaunchPendingWaitSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $state = 'not-in-rot'; $entry = $null; $sol = $null; $dialog = $null
    while ($true) {
        $rec = Find-TcSessionLaunchedIde -Solution $Record.solution
        if ($null -eq $rec) { $state = 'gone'; $entry = $null; break }
        if ($null -eq $rec.processKey) {
            $state = 'pid-unconfirmed'; $entry = $null
            # m2: a record restored from the file has no DTE object: it can never be confirmed here, no wait
            if ($null -eq $rec.dte) { break }
        }
        else {
            $procId = [int]$rec.processId
            $entry = @(Get-AllComObjects -IncludeDisplayName | Where-Object { $null -ne $_ -and $null -ne $_['Object'] -and [int]$_['ProcessId'] -eq $procId }) | Select-Object -First 1
            if ($null -eq $entry) { $state = 'not-in-rot' }
            else {
                $dialog = Find-TcIdeModalDialog -ProcessId $procId
                if (Test-TcModalScanIncomplete $dialog) { $state = 'scan-incomplete' }
                elseif ($null -ne $dialog) { $state = 'dialog'; break }
                else {
                    $obj = $entry['Object']
                    try {
                        $sol = Invoke-TcComRetry -MaxRetries 1 -OperationName 'Read DTE.Version / Solution.FullName (session-launched IDE)' -ScriptBlock {
                            $ver = [string]$obj.Version
                            if ([string]::IsNullOrWhiteSpace($ver)) { throw 'DTE.Version is empty' }
                            $s = $obj.Solution
                            if ($null -ne $s) { [string]$s.FullName } else { '' }
                        }
                        $norm = if ([string]::IsNullOrWhiteSpace($sol)) { '' } else { try { Get-TcLongPath $sol } catch { $sol } }
                        $state = if ($norm -eq '' -or [string]::Equals($norm, $Record.solution, [StringComparison]::OrdinalIgnoreCase)) { 'ready' } else { 'other-solution' }
                    }
                    catch {
                        $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
                        $state = if ($null -ne $mapped -and $mapped.Code -eq 'IDE_BUSY') { 'busy' } else { 'unreadable' }
                    }
                }
            }
        }
        if ($state -in 'ready', 'other-solution') { break }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
        Start-Sleep -Milliseconds 500
    }
    [PSCustomObject]@{ state = $state; entry = $entry; solution = $sol; dialog = $dialog; waitedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}
