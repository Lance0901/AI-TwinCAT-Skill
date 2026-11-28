# Unit: Build-TcProject decides success from the Error List; with the COM source a COM list is accepted only with an
# end summary of THIS build's output pane (review #332 M1). Behaviour tests: the real Build-TcProject, Get-TcErrorListSummary,
# Get-TcBuildErrors and Get-TcErrorListViaCom run; only the IDE (DTE, build pane), the C# reader result and the UIA scan are mocked.
#   S  failedProjects = $null (LastBuildInfo unreadable), pane unreadable, COM 0 rows, UIA cannot read -> NOT success (BUILD_STATUS_UNKNOWN)
#   T  the same with a pane that has 'Build complete -- 0 errors' -> COM accepted, success
#   U  summary says 2 errors, COM read 1 -> rejected (fallbackReason), UIA cannot read -> BUILD_STATUS_UNKNOWN
#   V  no summary, UIA reads a clean list -> success through UIA, errorListFallbackReason build-summary-missing
#   W  Clean-TcProject / Save-TcArchive / New-TcBootProject never ask for COM (-Source UIA)
#   powershell.exe -NoProfile -File tests/Unit/build-errorlist-com-m1-332.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-m1-332-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$stateRoot = & $mod { param($p) Get-TcLongPath $p } $stateRoot
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$sln = Join-Path $stateRoot 'DemoM1\DemoM1.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $sln) -Force
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII
$global:ReadCalls = 0
$global:UiaCalls = 0
$global:LbiThrows = $true
$global:PaneRead = $null
$global:ComRead = $null
$global:UiaResult = $null
& $mod {
    param($s)
    $script:TcSolutionPath = $s
    $script:TcIdeProcessId = $PID
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [PSCustomObject]@{ Mock = $true } }
    function script:Find-TcIdeModalDialog { $null }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT OS (x64)'; platformSource = 'ActiveConfig' } }
    function script:Get-TcBuildCoverage {
        @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = @(
            [PSCustomObject]@{ name = 'plc'; uniqueName = 'DemoM1\plc\plc.plcproj'; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $true; status = 'pending' }
        ) }
    }
    function script:Get-TcPlcProjectList { @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851; disabled = $false; projectFile = $null }) }
    function script:Get-TcBuildOutputPane { [CmdletBinding()] param($Dte) $global:PaneRead }
    function script:Invoke-TcComRetry {
        param([int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec, [scriptblock]$ScriptBlock)
        if ($OperationName -eq 'LastBuildInfo' -and $global:LbiThrows) { throw 'unit: LastBuildInfo not readable' }
        & $ScriptBlock
    }
    function script:Initialize-TcErrorListComTypes { [CmdletBinding()] param([int]$IdeProcessId) [PSCustomObject]@{ ok = $true; reason = $null } }
    function script:Read-TcErrorListCom { [CmdletBinding()] param([int]$MaxMs, [int]$CapMs, [bool]$FetchWarnings = $true, [bool]$FetchMessages = $true, [bool]$ReadLevel = $true) $global:ReadCalls++; $global:ComRead }
    function script:Initialize-TcUiaScanTypes { [CmdletBinding()] param([int]$TimeoutSec) $true }
    function script:Invoke-TcUiaScan {
        [CmdletBinding()] param([scriptblock]$Script, [object[]]$Arguments, [int]$TimeoutSec, [ref]$TimedOut, [ref]$ErrorOut)
        $global:UiaCalls++
        $global:UiaResult
    }
} $sln
function Set-Dte {
    $sb = [PSCustomObject]@{ Polls = 0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Build -Value { param($wait) $this.Polls = 0 }
    $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { $this.Polls++; if ($this.Polls -le 1) { 2 } else { 3 } }
    $sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { 0 }
    $dte = [PSCustomObject]@{ Version = '17.0'; Solution = [PSCustomObject]@{ SolutionBuild = $sb } }
    $dte | Add-Member -MemberType ScriptMethod -Name ExecuteCommand -Value { param($c) }
    & $mod { param($d) $script:TcDte = $d; $script:TcBuildRequiredLocal = @{}; $script:TcErrorListScanBusy = $false; $script:TcUiaCleanupMayBeRunning = $false } $dte
}
function Row([string]$Desc, [string]$File = 'C:\p\Main.TcPOU (Impl)', [int]$Line = 45) {
    [PSCustomObject]@{ Level = 2; Description = $Desc; FileName = $File; Line = $Line; Column = 1; Project = 'A\B\plc.plcproj' }
}
function Set-Com([hashtable]$o) {
    $d = @{ ok = $true; reason = ''; error = ''; caption = 'Error List'; allCount = 0; flagsRestored = $true; flagsChanged = $true; flagsBefore = @($true, $true, $true); ms = 3
        errors = @(); warnings = @(); messages = @() }
    foreach ($k in $o.Keys) { $d[$k] = $o[$k] }
    # the counts of the isolated reads (the C# reader reports them; the rows alone were enough before it fetched only what is asked for)
    if (-not $d.ContainsKey('errorCount')) { $d['errorCount'] = @($d.errors).Count }
    if (-not $d.ContainsKey('warningCount')) { $d['warningCount'] = @($d.warnings).Count }
    if (-not $d.ContainsKey('messageCount')) { $d['messageCount'] = @($d.messages).Count }
    $global:ComRead = [PSCustomObject]$d
}
function Set-Uia([int]$Errors, [bool]$Found = $true) {
    $global:UiaResult = if (-not $Found) { [PSCustomObject]@{ Found = $false; Rows = @(); Truncated = $false; ToggleUsed = $false; Notes = @('no Error List window (unit)'); Headers = @(); Counts = $null } }
    else {
        [PSCustomObject]@{
            Found = $true; Rows = @(); Truncated = $false; ToggleUsed = $true; Notes = @(); Headers = @()
            Counts = [PSCustomObject]@{ errors = $Errors; warnings = 0; messages = 0 }
            Scope = [PSCustomObject]@{ before = 'Entire Solution'; after = 'Entire Solution'; entire = $true; switched = $false }
            CountsTotalForm = $true }
    }
}
function Run-Build {
    $global:ReadCalls = 0; $global:UiaCalls = 0
    Build-TcProject -WarningAction SilentlyContinue
}

try {
    Set-Dte
    # --- S: the review's scenario: failedProjects $null, pane unreadable, COM 0 rows (a filtered list looks like this)
    $global:LbiThrows = $true
    $global:PaneRead = [PSCustomObject]@{ status = 'unreadable'; name = $null; guid = $null; index = $null; matchedBy = $null; text = ''; panes = @(); error = 'unit: pane unreadable' }
    Set-Com @{ allCount = 0 }
    Set-Uia 0 -Found $false
    $r = Run-Build
    Check 'S1 failedProjects $null + pane unreadable + COM 0 rows + UIA cannot read: NOT success' (-not $r.success) (J $r.error)
    Check 'S1 the result is BUILD_STATUS_UNKNOWN, buildSucceeded $null, not "built"' ($r.error.code -eq 'BUILD_STATUS_UNKNOWN' -and $null -eq $r.data.buildSucceeded -and $r.data.completeBuild -ne $true) (J $r.data)
    Check 'S1 COM was not even read (no summary, so no Show* flag was touched); no UIA scan either (UIA fallback off by default, PR #332 round 3)' ($global:ReadCalls -eq 0 -and $global:UiaCalls -eq 0 -and $r.data.errorListError -eq 'ERRORLIST_UNVERIFIED') "reads=$global:ReadCalls uia=$global:UiaCalls el=$($r.data.errorListError)"
    Check 'S1 the reason is kept: errorListFallbackReason build-summary-missing' ([string]$r.data.errorListFallbackReason -match '^build-summary-missing') (J $r.data.errorListFallbackReason)

    # --- S2: pane readable but without a summary line (unknown UI language / aborted build): same
    $global:PaneRead = [PSCustomObject]@{ status = 'read'; name = 'Build'; guid = '{1BD8A850-02D1-11D1-BEE7-00A0C913D1F8}'; index = 1; matchedBy = 'guid'; text = "Generate code...`r`nsomething"; panes = @(); error = $null }
    $r = Run-Build
    Check 'S2 pane without an end summary: COM 0 rows not accepted, BUILD_STATUS_UNKNOWN' (-not $r.success -and $r.error.code -eq 'BUILD_STATUS_UNKNOWN' -and $global:ReadCalls -eq 0) (J $r.error)

    # --- T: the same list with the PLC compiler summary 'Build complete -- 0 errors' -> accepted
    $global:PaneRead = [PSCustomObject]@{ status = 'read'; name = 'Build'; guid = '{1BD8A850-02D1-11D1-BEE7-00A0C913D1F8}'; index = 1; matchedBy = 'guid'; text = "Generate code...`r`nBuild complete -- 0 errors, 0 warnings : ready for download"; panes = @(); error = $null }
    $r = Run-Build
    Check 'T1 summary "Build complete -- 0 errors" + COM 0 rows (Entire Solution): accepted, success, source COM' ($r.success -and $r.data.errorListSource -eq 'ErrorList(COM)' -and $r.data.buildSucceeded -eq $true -and $global:ReadCalls -eq 1 -and $global:UiaCalls -eq 0) (J $r.data.errorListSource)

    # --- U: summary says 2 errors, the (filtered) COM list shows 1 -> rejected, UIA cannot read
    $global:PaneRead = [PSCustomObject]@{ status = 'read'; name = 'Build'; guid = '{1BD8A850-02D1-11D1-BEE7-00A0C913D1F8}'; index = 1; matchedBy = 'guid'; text = "C:\p\Main.TcPOU(209) : error: C0046: Identifier 'a' not defined`r`nC:\p\Main.TcPOU(210) : error: C0046: Identifier 'b' not defined`r`nBuild complete -- 2 errors, 0 warnings"; panes = @(); error = $null }
    Set-Com @{ allCount = 1; errors = @((Row "Identifier 'a' not defined")) }
    $r = Run-Build
    Check 'U1 summary 2 errors, COM list (filtered) has 1: rejected, UIA cannot read -> not success' (-not $r.success -and $r.error.code -eq 'BUILD_STATUS_UNKNOWN' -and [string]$r.data.errorListFallbackReason -match '^fewer-errors-than-build-summary') ("$($r.error.code) $($r.data.errorListFallbackReason)")
    Set-Com @{ allCount = 2; errors = @((Row "Identifier 'a' not defined"), (Row "Identifier 'b' not defined" 'C:\p\Main.TcPOU (Impl)' 46)) }
    $r = Run-Build
    Check 'U2 summary 2 errors, COM has both rows (file + text match the pane): accepted as a failed build, errors counted' (-not $r.success -and $r.error.code -eq 'BUILD_FAILED' -and $r.data.errorListSource -eq 'ErrorList(COM)' -and @($r.data.codeErrors).Count -eq 2) ("$($r.error.code) $($r.data.errorListSource) n=$(@($r.data.codeErrors).Count)")
    Set-Com @{ allCount = 2; errors = @((Row "Identifier 'a' not defined"), (Row 'Could not open library X' 'C:\p\plc.Library Manager' 0)) }
    $r = Run-Build
    Check 'U3 pane error line "b" has no row, only a Library Manager row besides "a": rejected (build-pane-error-not-in-list), not LIBRARY_UNRESOLVED' ([string]$r.data.errorListFallbackReason -match '^build-pane-error-not-in-list' -and $r.error.code -ne 'LIBRARY_UNRESOLVED') ("$($r.error.code) $($r.data.errorListFallbackReason)")

    # --- V: no summary; a UIA scan would read a complete clean list, but the UIA fallback is off by default (it took the foreground,
    # PR #332 round 3): not success, no UIA scan, the reason kept
    $global:PaneRead = [PSCustomObject]@{ status = 'unreadable'; name = $null; guid = $null; index = $null; matchedBy = $null; text = ''; panes = @(); error = 'unit' }
    Set-Com @{ allCount = 0 }
    Set-Uia 0
    $uiaBefore = $global:UiaCalls
    $r = Run-Build
    Check 'V1 no summary: not success (BUILD_STATUS_UNKNOWN), errorListError ERRORLIST_UNVERIFIED, no UIA scan, errorListFallbackReason build-summary-missing' (-not $r.success -and $r.error.code -eq 'BUILD_STATUS_UNKNOWN' -and $r.data.errorListError -eq 'ERRORLIST_UNVERIFIED' -and $global:UiaCalls -eq $uiaBefore -and [string]$r.data.errorListFallbackReason -match '^build-summary-missing') ("$($r.error.code) $($r.data.errorListError) $($r.data.errorListFallbackReason) uia=$($global:UiaCalls)")

    # --- W: callers without a build pane never ask for COM
    $seen = & $mod {
        $script:SeenSource = @{}
        function script:Get-TcBuildErrors { [CmdletBinding()] param([switch]$IncludeWarnings, [switch]$IncludeMessages, [int]$TimeoutSec = 30, [switch]$ExpectErrors, [string]$BuildPaneText, [switch]$RequireBuildSummary, [ValidateSet('COM', 'Auto', 'UIA')][string]$Source = 'Auto')
            $global:SeenSource = $Source
            [PSCustomObject]@{ success = $true; error = $null; data = [PSCustomObject]@{ counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }; errors = @(); warnings = @(); truncated = $false; source = 'ErrorList(UIA)' } } }
        $null = Get-TcErrorListSummary -Source UIA
        $global:SeenSource
    }
    Check 'W1 Get-TcErrorListSummary -Source UIA passes -Source UIA on (Save-TcArchive / New-TcBootProject)' ($seen -eq 'UIA') "$seen"
    $pub = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public'
    $arch = [IO.File]::ReadAllText((Join-Path $pub 'Save-TcArchive.ps1'))
    $boot = [IO.File]::ReadAllText((Join-Path $pub 'New-TcBootProject.ps1'))
    $clear = [IO.File]::ReadAllText((Join-Path $pub 'Clear-TcProject.ps1'))
    Check 'W2 Save-TcArchive reads before and after with -Source UIA and keeps the code in its row key' (([regex]::Matches($arch, 'Get-TcErrorListSummary -Source UIA')).Count -eq 2 -and $arch -match '\$rowKey\s*=\s*\{\s*param\(\$i\)\s*"\$\(\[string\]\$i\.code\)\|') ''
    Check 'W3 New-TcBootProject and Clear-TcProject read with -Source UIA' ($boot -match 'Get-TcErrorListSummary -Source UIA' -and $clear -match 'Get-TcBuildErrors\s+-TimeoutSec\s+\$script:TcBuildErrorListTimeoutSec\s+-Source UIA') ''
}
finally {
    Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit [Math]::Min($fail, 255)
