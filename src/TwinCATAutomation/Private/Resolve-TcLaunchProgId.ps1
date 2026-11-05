# Which IDE ProgID Connect-TcIde launches when no -ProgId is given (#72), and the guard that
# keeps it from launching a second IDE for a solution whose IDE this session is still starting
# (#136).
#
# #72: the version a TwinCAT project was last saved with is stored in the project file
# (InfoSys "Selection of a TwinCAT 3 version before loading a project",
# https://infosys.beckhoff.com/content/1033/tc3_remote_manager/3154642571.html). The page does not
# name the field; measured (2026-11-06, read-only, this repo's test copies): the root element
# <TcSmProject ... TcVersion="3.1.4026.22"> of C:\Temp\Verify-4026-axis\...\AxisInterface_Type01_Library.tsproj
# and TcVersion="3.1.4024.71" of C:\Temp\Verify-4024-bfh\LangMang260618\BFH_1650.tsproj.
# Build -> IDE: TcXaeShell is the Visual Studio 2017 shell, TcXaeShell64 the Visual Studio 2022
# shell, available starting with build 4026 (InfoSys "System requirements",
# https://infosys.beckhoff.com/content/1033/tc3_overview/6162419083.html). So
#   build < 4026  -> TcXaeShell.DTE.15.0 (32-bit TcXaeShell)
#   build >= 4026 -> TcXaeShell.DTE.17.0 (TcXaeShell64), else VisualStudio.DTE.17.0 (VS2022)
# Known limit: a 4026 install whose only shell is the 32-bit TcXaeShell (also ProgID 15.0) is not
# recognised as such; the caller gets IDE_VERSION_NOT_REGISTERED and passes -ProgId.

$script:TcKnownIdeProgIds = @('TcXaeShell.DTE.15.0', 'TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')

function Get-TcIdeProgIdsForBuild {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Build)
    if ($Build -ge 4026) { return @('TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0') }
    @('TcXaeShell.DTE.15.0')
}

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

# TcVersion attribute of the root element of one .tsproj, or $null. Reads only the root element
# (a .tsproj can be many MB).
function Get-TcTsprojTcVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $reader = $null
    try {
        $settings = New-Object System.Xml.XmlReaderSettings
        $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
        $settings.XmlResolver = $null
        $reader = [System.Xml.XmlReader]::Create($Path, $settings)
        $null = $reader.MoveToContent()
        if ($reader.NodeType -ne [System.Xml.XmlNodeType]::Element) { return $null }
        $v = $reader.GetAttribute('TcVersion')
        if ([string]::IsNullOrWhiteSpace($v)) { return $null }
        return [string]$v
    }
    catch { Write-Verbose "TcVersion of '$Path' unreadable ($($_.Exception.Message))"; return $null }
    finally { if ($null -ne $reader) { $reader.Dispose() } }
}

# The TwinCAT projects (.tsproj / .tspproj) a .sln references and their TcVersion.
# Returns [PSCustomObject]@{ tsprojects = @(@{ path; tcVersion; build }); builds = @(distinct int);
#   visualStudioVersion (from the .sln, evidence only); reason ($null or why nothing was found) }
function Get-TcSolutionTcVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionPath)
    $result = [PSCustomObject]@{ solution = $SolutionPath; tsprojects = @(); builds = @(); visualStudioVersion = $null; reason = $null }
    $lines = try { [IO.File]::ReadAllLines($SolutionPath) } catch { $result.reason = "solution unreadable ($($_.Exception.Message))"; return $result }
    $dir = Split-Path -Parent $SolutionPath
    $projects = @()
    foreach ($line in $lines) {
        if ($line -match '^\s*VisualStudioVersion\s*=\s*(\S+)') { $result.visualStudioVersion = $Matches[1]; continue }
        if ($line -match '^\s*Project\("\{[^}]*\}"\)\s*=\s*"[^"]*"\s*,\s*"([^"]+\.tsp?proj)"') {
            $rel = $Matches[1]
            $full = if ([IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $dir $rel }
            $ver = if (Test-Path -LiteralPath $full -PathType Leaf) { Get-TcTsprojTcVersion -Path $full } else { $null }
            $build = $null
            if ($null -ne $ver -and $ver -match '^\d+\.\d+\.(\d+)') { $build = [int]$Matches[1] }
            $projects += [PSCustomObject]@{ path = $full; tcVersion = $ver; build = $build }
        }
    }
    $result.tsprojects = $projects
    $result.builds = @($projects | Where-Object { $null -ne $_.build } | ForEach-Object { [int]$_.build } | Sort-Object -Unique)
    if ($projects.Count -eq 0) { $result.reason = 'the solution references no TwinCAT project (.tsproj)' }
    elseif ($result.builds.Count -eq 0) { $result.reason = 'no TcVersion attribute readable in the referenced .tsproj file(s)' }
    elseif ($result.builds.Count -gt 1) { $result.reason = "the referenced .tsproj files were saved with different TwinCAT builds ($($result.builds -join ', '))" }
    $result
}

# Picks the ProgID to launch. Returns [PSCustomObject]@{ progId; selectedBy ('explicit' |
# 'tsproj-version' | 'only-one-registered'); registered; evidence; errorCode; errorMessage }.
# errorCode set = nothing may be launched: TWINCAT_NOT_FOUND (nothing registered),
# IDE_VERSION_NOT_REGISTERED (the project's build is known, none of its IDEs is registered),
# PROGID_REQUIRED (build not determinable and more than one IDE registered). Never guesses.
function Resolve-TcLaunchProgId {
    [CmdletBinding()]
    param([string]$ProgId, [string]$SolutionPath)
    $out = [PSCustomObject]@{ progId = $null; selectedBy = $null; registered = @(); evidence = $null; errorCode = $null; errorMessage = $null }
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
    $why = 'no -SolutionPath (no project to read the TwinCAT version from)'
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        $ev = Get-TcSolutionTcVersion -SolutionPath $SolutionPath
        $out.evidence = $ev
        if ($null -eq $ev.reason) {
            $build = [int]$ev.builds[0]
            $wanted = @(Get-TcIdeProgIdsForBuild -Build $build)
            $pick = @($wanted | Where-Object { $out.registered -contains $_ }) | Select-Object -First 1
            if ($null -ne $pick) { $out.progId = $pick; $out.selectedBy = 'tsproj-version'; return $out }
            $out.errorCode = 'IDE_VERSION_NOT_REGISTERED'
            $out.errorMessage = "The solution's TwinCAT project was saved with build $build (TcVersion $(@($ev.tsprojects | Where-Object { $_.build -eq $build })[0].tcVersion)), which needs $($wanted -join ' or '); none of them is registered (registered: $($out.registered -join ', ')). No IDE was launched; pass -ProgId to choose one."
            return $out
        }
        $why = $ev.reason
    }
    if ($out.registered.Count -eq 1) { $out.progId = $out.registered[0]; $out.selectedBy = 'only-one-registered'; return $out }
    $out.errorCode = 'PROGID_REQUIRED'
    $out.errorMessage = "Cannot tell which IDE to launch: $why, and $($out.registered.Count) IDE ProgIDs are registered ($($out.registered -join ', ')). No IDE was launched; pass -ProgId."
    $out
}

# --- #136: the IDE this session launched for a solution ---
# Add-TcLaunchedIde -Solution remembers, per process (pid + start time), the solution an IDE was
# launched for. Find-TcSessionLaunchedIde returns that IDE while the same process is alive, so
# Connect-TcIde waits for / attaches to it instead of launching a second IDE for the same .sln
# (a cold VS2022 start answered MODAL_SCAN_INCOMPLETE, the retry launched another VS2022).
function Find-TcSessionLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Solution)
    if ($null -eq $script:TcLaunchedIdeSolutions -or $script:TcLaunchedIdeSolutions.Count -eq 0) { return $null }
    foreach ($key in @($script:TcLaunchedIdeSolutions.Keys)) {
        if (-not [string]::Equals([string]$script:TcLaunchedIdeSolutions[$key], $Solution, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $procId = [int](($key -split '\|')[0])
        if ((Get-TcIdeProcessKey -ProcessId $procId) -ne $key) { $script:TcLaunchedIdeSolutions.Remove($key); continue }   # gone / pid recycled
        return [PSCustomObject]@{ ProcessId = $procId; Key = $key; StartTime = (($key -split '\|', 2)[1]) }
    }
    $null
}

function Clear-TcSessionLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Key)
    if ($null -ne $script:TcLaunchedIdeSolutions) { $script:TcLaunchedIdeSolutions.Remove($Key) }
}

# Polls the ROT for the DTE of process -ProcessId until it answers Version + Solution (500 ms,
# max -TimeoutSec). Returns [PSCustomObject]@{ state ('ready' | 'other-solution' | 'busy' |
# 'unreadable' | 'not-in-rot' | 'gone'); entry (ROT entry or $null); solution; waitedSec }.
$script:TcLaunchPendingWaitSec = 60
function Wait-TcSessionLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)][string]$Key, [Parameter(Mandatory)][string]$Solution, [int]$TimeoutSec = $script:TcLaunchPendingWaitSec)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $state = 'not-in-rot'; $entry = $null; $sol = $null
    while ($true) {
        if ((Get-TcIdeProcessKey -ProcessId $ProcessId) -ne $Key) { $state = 'gone'; $entry = $null; break }
        $entry = @(Get-AllComObjects -IncludeDisplayName | Where-Object { $null -ne $_ -and $null -ne $_['Object'] -and [int]$_['ProcessId'] -eq $ProcessId }) | Select-Object -First 1
        if ($null -eq $entry) { $state = 'not-in-rot' }
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
                $state = if ($norm -eq '' -or [string]::Equals($norm, $Solution, [StringComparison]::OrdinalIgnoreCase)) { 'ready' } else { 'other-solution' }
            }
            catch {
                $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
                $state = if ($null -ne $mapped -and $mapped.Code -eq 'IDE_BUSY') { 'busy' } else { 'unreadable' }
            }
        }
        if ($state -in 'ready', 'other-solution') { break }
        if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
        Start-Sleep -Milliseconds 500
    }
    [PSCustomObject]@{ state = $state; entry = $entry; solution = $sol; waitedSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
}
