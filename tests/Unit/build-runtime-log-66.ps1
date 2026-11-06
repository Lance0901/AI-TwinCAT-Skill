# Unit: runtime / system log rows (TcUnit / ADSLOGSTR output, 'TCOM Server', 'TwinCAT System') in the Error List are not build errors
# (issue #66), no IDE / runtime needed. The DTE / SolutionContexts / Error List are mocked in the
# module scope; the real Build-TcProject, Get-TcErrorListSummary, Get-TcRuntimeLogKind and
# Set/Clear-TcBuildRequired run (state in a temp TCAUTO_STATE_DIR). Covers:
#   (a) only TcUnit log rows, LastBuildInfo 0 -> success, errorItems empty, rows in runtimeMessages
#   (b) TcUnit log rows + a real C0046 -> BUILD_FAILED, errorItems / codeErrors = the C0046 only
#   (c) a row that cannot be told apart (log prefix AND file / line / code) -> kept as a build row
#       with a note (fail closed); with LastBuildInfo unreadable it still fails the build
#   plus: the #66 shape (only log rows, LastBuildInfo 1) names the log rows in the message, (a2) with
#   LastBuildInfo unreadable is CODE_NOT_VERIFIED / not complete (review #150 F3), system rows, library
#   rows behind the prefix (F4), the summary without -SplitRuntimeLog (F1),
#   warning log rows leave warningItems, Get-TcRuntimeLogKind cases.
#   powershell.exe -NoProfile -File tests/Unit/build-runtime-log-66.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-66-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
# 8.3 TEMP on CI runners (#43): the state keys are long paths
$stateRoot = & $mod { param($p) Get-TcLongPath $p } $stateRoot
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }
$sln = Join-Path $stateRoot 'Demo66\Demo66.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $sln) -Force
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII

# --- Error List rows. Log rows: the form measured in #66 (2026-10-27, VS2022 4026, local UmRT,
# RobustSolutionFrameworkDemo with TcUnit): "'PlcTask' (350): | ...", no project / file / line.
function Row([string]$Sev, [string]$Desc, [string]$File = $null, $Line = $null, [string]$Code = $null, [string]$Project = $null) {
    [PSCustomObject]@{ severity = $Sev; code = $Code; description = $Desc; project = $Project; file = $File; line = $Line; column = $null }
}
function TcUnitRows {
    @(
        (Row 'Error' "'PlcTask' (350): | ==========TESTS FINISHED RUNNING==========")
        (Row 'Error' "'PlcTask' (350): | Test suites: 2")
        (Row 'Error' "'PlcTask' (350): | Tests: 6")
        (Row 'Error' "'PlcTask' (350): | Successful tests: 6")
        (Row 'Error' "'PlcTask' (350): | Failed tests: 0")
        (Row 'Error' "'PlcTask' (350): | Duration: 0.010000")
        (Row 'Error' "'PlcTask' (350): | ======================================")
    )
}
$c0046 = { Row 'Error' "Identifier 'nPr62Undeclared' not defined" 'C:\Demo66\plc\POUs\MAIN.TcPOU' 12 'C0046' 'plc' }

# --- Get-TcRuntimeLogKind
$kindCases = @(
    @{ Name = 'TcUnit row, no file / line / code -> runtime'; Item = (Row 'Error' "'PlcTask' (350): | Successful tests: 6"); Want = 'runtime' }
    @{ Name = 'leading blank, other task / port -> runtime'; Item = (Row 'Warning' "  'Task 2' (351) : ADSLOGSTR hint"); Want = 'runtime' }
    @{ Name = 'line 0 counts as no line -> runtime'; Item = (Row 'Error' "'PlcTask' (350): x" $null 0); Want = 'runtime' }
    @{ Name = 'prefix + file -> ambiguous'; Item = (Row 'Error' "'PlcTask' (350): x" 'C:\p\MAIN.TcPOU'); Want = 'ambiguous' }
    @{ Name = 'prefix + line -> ambiguous'; Item = (Row 'Error' "'PlcTask' (350): x" $null 7); Want = 'ambiguous' }
    @{ Name = 'prefix + compiler code -> ambiguous'; Item = (Row 'Error' "'PlcTask' (350): C0046 x" $null $null 'C0046'); Want = 'ambiguous' }
    @{ Name = 'compiler message -> null'; Item = (& $c0046); Want = $null }
    @{ Name = 'build-summary row without prefix -> null'; Item = (Row 'Error' "Build of project 'plc' failed"); Want = $null }
    @{ Name = 'quoted name without port -> null'; Item = (Row 'Error' "'PlcTask': x"); Want = $null }
    @{ Name = 'null item -> null'; Item = $null; Want = $null }
    # review #150 F2: system rows in the same form are runtime / system log rows too (probe rows)
    @{ Name = 'TCOM Server row -> runtime'; Item = (Row 'Error' "'TCOM Server' (10): NtpType Register ExternalTime failed, HR=98110708"); Want = 'runtime' }
    @{ Name = 'TwinCAT System row with a project -> runtime'; Item = (Row 'Error' "'TwinCAT System' (10000): Error: >> license not found <<" $null $null $null 'plc'); Want = 'runtime' }
    # F7: the brackets do not always hold a number ('TwinCAT Measurement' (time)): not matched
    @{ Name = 'TwinCAT Measurement (22:30:40.881) -> null'; Item = (Row 'Error' "'TwinCAT Measurement' (22:30:40.881): Error creating Archive -> x"); Want = $null }
    # F4: a library message behind the prefix cannot be told apart
    @{ Name = 'prefix + Could not open library -> ambiguous'; Item = (Row 'Error' "'PlcTask' (350): Could not open library 'Tc2_Foo'"); Want = 'ambiguous' }
    @{ Name = 'prefix + has not been installed -> ambiguous'; Item = (Row 'Error' "'plc' (851): Library 'Tc3_Foo' 1.0.0.0 has not been installed"); Want = 'ambiguous' }
)
foreach ($c in $kindCases) {
    $got = & $mod { param($i) Get-TcRuntimeLogKind -Item $i } $c.Item
    Check "kind: $($c.Name)" ($got -eq $c.Want) "want '$($c.Want)', got '$got'"
}

& $mod {
    param($s)
    $script:TcSolutionPath = $s
    $script:UtErrors = @()
    $script:UtWarnings = @()
    $script:UtLastBuildInfo = 0
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [PSCustomObject]@{ Mock = $true } }
    function script:Find-TcIdeModalDialog { $null }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT OS (x64)'; platformSource = 'ActiveConfig' } }
    function script:Get-TcBuildCoverage {
        @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = @(
            [PSCustomObject]@{ name = 'plc'; uniqueName = 'Demo66\plc\plc.plcproj'; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $true; status = 'pending' }
        ) }
    }
    function script:Get-TcPlcProjectList { param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851; disabled = $false; projectFile = $null }) }
    function script:Get-TcBuildErrors {
        [CmdletBinding()]
        param([switch]$IncludeWarnings, [int]$TimeoutSec = 30)
        # fresh copies per call: Get-TcErrorListSummary adds category / note to the rows
        $e = @($script:UtErrors | ForEach-Object { $_.PSObject.Copy() })
        $w = @($script:UtWarnings | ForEach-Object { $_.PSObject.Copy() })
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            counts = [PSCustomObject]@{ errors = $e.Count; warnings = $w.Count; messages = 0 }; errors = $e; warnings = $w
        })
    }
    $sb = [PSCustomObject]@{ Mock = $true; Polls = 0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Build -Value { param($wait) $this.Polls = 0 }
    $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { $this.Polls++; if ($this.Polls -le 1) { 2 } else { 3 } }
    $sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { $script:UtLastBuildInfo }
    # an exception in a ScriptProperty getter is swallowed (reads $null -> [int] 0), so an unreadable
    # LastBuildInfo is thrown from the retry wrapper, like a failed COM read
    function script:Invoke-TcComRetry {
        param([int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec, [scriptblock]$ScriptBlock)
        if ($OperationName -eq 'LastBuildInfo' -and $null -eq $script:UtLastBuildInfo) { throw 'unit: LastBuildInfo not readable' }
        & $ScriptBlock
    }
    $script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = $sb }; ToolWindows = $null }
} $sln

function Set-Scenario($Errors, $Warnings, $LastBuildInfo) {
    & $mod { param($e, $w, $l) $script:UtErrors = @($e); $script:UtWarnings = @($w); $script:UtLastBuildInfo = $l } $Errors $Warnings $LastBuildInfo
}
function Reset-State {
    & $mod { $script:TcBuildRequiredLocal = @{} }
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue
}

# --- (a) only TcUnit log rows (PLC logged in, tests ran), the build itself succeeded
Reset-State
Set-Scenario (TcUnitRows) @() 0
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(a) success, completeBuild true, codeVerified true' ($r.success -and $d.buildSucceeded -eq $true -and $d.completeBuild -eq $true -and $d.codeVerified -eq $true) (J $r)
Check '(a) errorItems / codeErrors empty, errors 0' (@($d.errorItems).Count -eq 0 -and @($d.codeErrors).Count -eq 0 -and $d.errors -eq 0) (J $d.errorItems)
Check '(a) the 7 log rows are in runtimeMessages, category runtime' (@($d.runtimeMessages).Count -eq 7 -and @($d.runtimeMessages | Where-Object { $_.category -ne 'runtime' }).Count -eq 0 -and $d.runtimeMessages[3].description -match 'Successful tests: 6') (J $d.runtimeMessages)
Check '(a) no runtimeMessageNote, no warningCodes' ($null -eq $d.PSObject.Properties['runtimeMessageNote'] -and $null -eq $d.PSObject.Properties['warningCodes']) (J $d)

# --- (a2) the same rows with LastBuildInfo unreadable: decided by the Error List, still success
Reset-State
Set-Scenario (TcUnitRows) @() $null
$r = Build-TcProject -WarningAction SilentlyContinue
Check '(a2) LastBuildInfo unreadable, only log rows -> success decided by ErrorList' ($r.success -and $r.data.decidedBy -eq 'ErrorList' -and @($r.data.errorItems).Count -eq 0 -and @($r.data.runtimeMessages).Count -eq 7) (J $r)
# review #150 F3: the PLC was online and only the Error List decided -> not verified, not complete
Check '(a2) codeVerified null, CODE_NOT_VERIFIED (PLC online), completeBuild false, BUILD_REQUIRED recorded' ($null -eq $r.data.codeVerified -and $r.data.completeBuild -eq $false -and @($r.data.warningCodes) -contains 'CODE_NOT_VERIFIED' -and $r.data.warning -match 'runtime log rows present \(PLC online, or rows left from an earlier online session\) \(#66\)' -and $null -ne $r.data.buildRequired) (J $r.data)

# (a2) end to end (review #150 N3): the recorded BUILD_REQUIRED refuses the next PLC login. The
# Enable-TcConfig refusal from the same state entry is covered by platform-project-mismatch.ps1
# (br-held-enable-blocked) and code-changed-build-required.ps1 (Enter-TcPlcOnline / Send-TcPlcProgram);
# a full Enable-TcConfig mock here would need the whole lifecycle preamble.
$l = Enter-TcPlcOnline -LoginMode Regular
Check '(a2) end to end: Enter-TcPlcOnline after that build -> BUILD_REQUIRED (unverified-build)' ((-not $l.success) -and $l.error.code -eq 'BUILD_REQUIRED' -and $l.error.message -match 'did not prove') (J $l)
# --- (b) TcUnit log rows + a real compiler error
Reset-State
Set-Scenario (@(TcUnitRows) + (& $c0046)) @() 1
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(b) BUILD_FAILED' (-not $r.success -and $r.error.code -eq 'BUILD_FAILED' -and $d.buildSucceeded -eq $false) (J $r.error)
Check '(b) errorItems = codeErrors = the C0046 only, errors 1' (@($d.errorItems).Count -eq 1 -and @($d.codeErrors).Count -eq 1 -and $d.codeErrors[0].code -eq 'C0046' -and $d.errorItems[0].category -eq 'code' -and $d.errors -eq 1) (J $d.errorItems)
Check '(b) message names the C0046, not the TcUnit rows' ($r.error.message -match '1 code error' -and $r.error.message -match 'C0046' -and $r.error.message -match 'MAIN:12' -and $r.error.message -notmatch 'Successful tests') $r.error.message
Check '(b) message says the log rows were left out' ($r.error.message -match '7 runtime / system log row') $r.error.message
Check '(b) runtimeMessages 7, project plc failed' (@($d.runtimeMessages).Count -eq 7 -and @($d.projects)[0].status -eq 'failed') (J $d.projects)
Check '(b) BUILD_REQUIRED recorded' ($null -ne $d.buildRequired) (J $d)

# --- (b2) the #66 shape: only log rows while the build failed (no compiler row listed)
Reset-State
Set-Scenario (TcUnitRows) @() 1
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(b2) BUILD_FAILED, 0 code errors, errorItems empty' (-not $r.success -and $r.error.code -eq 'BUILD_FAILED' -and @($d.errorItems).Count -eq 0 -and $r.error.message -match '0 code error') (J $r)
Check '(b2) message: no code error listed + 7 log rows left out (data.runtimeMessages)' ($r.error.message -match 'no code error listed' -and $r.error.message -match '7 runtime / system log row' -and $r.error.message -match 'data\.runtimeMessages' -and $r.error.message -notmatch 'Successful tests') $r.error.message
Check '(b2) project status unknown (no build row names it)' (@($d.projects)[0].status -eq 'unknown') (J $d.projects)

# --- (c) a row that cannot be told apart: log prefix AND file + line -> kept, with a note
$amb = { Row 'Error' "'PlcTask' (350): Identifier 'x' not defined" 'C:\Demo66\plc\POUs\MAIN.TcPOU' 5 $null 'plc' }
Reset-State
Set-Scenario (@(TcUnitRows) + (& $amb)) @() 0
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(c) the ambiguous row stays in errorItems / codeErrors with a note' (@($d.errorItems).Count -eq 1 -and @($d.codeErrors).Count -eq 1 -and $d.errorItems[0].category -eq 'code' -and $d.errorItems[0].note -match '#66') (J $d.errorItems)
Check '(c) data.runtimeMessageNote set, the 7 clear log rows in runtimeMessages' ($d.runtimeMessageNote -match '1 Error List row' -and @($d.runtimeMessages).Count -eq 7) (J $d)
Check '(c) the ambiguous row is not in runtimeMessages' (@($d.runtimeMessages | Where-Object { $_.file }).Count -eq 0) (J $d.runtimeMessages)
Check '(c) errors counts it' ($d.errors -eq 1) (J $d.errors)

# --- (c2) the same with LastBuildInfo unreadable: the kept row decides BUILD_FAILED (not hidden)
Reset-State
Set-Scenario (@(TcUnitRows) + (& $amb)) @() $null
$r = Build-TcProject -WarningAction SilentlyContinue
Check '(c2) LastBuildInfo unreadable + ambiguous row with a line -> BUILD_FAILED by ErrorList' (-not $r.success -and $r.error.code -eq 'BUILD_FAILED' -and $r.data.decidedBy -eq 'ErrorList' -and $r.error.message -match "Identifier 'x' not defined") (J $r)

# --- (c3) prefix + compiler code but no file: kept as an error row (category other) with a note
$ambCode = { Row 'Error' "'PlcTask' (350): C0077 unknown type" $null $null 'C0077' }
Reset-State
Set-Scenario (@(& $ambCode)) @() 1
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(c3) prefix + code, no file -> kept in errorItems (other) with note, listed in the message' (@($d.errorItems).Count -eq 1 -and $d.errorItems[0].category -eq 'other' -and $d.errorItems[0].note -match '#66' -and @($d.runtimeMessages).Count -eq 0 -and $r.error.message -match 'C0077') (J $r)

# --- warning log rows leave warningItems
Reset-State
$logWarn = Row 'Warning' "'PlcTask' (350): ADSLOGSTR warning text"
$realWarn = Row 'Warning' "Unused variable 'nTmp'" 'C:\Demo66\plc\POUs\MAIN.TcPOU' 3 'C0373' 'plc'
Set-Scenario @() @($logWarn, $realWarn) 0
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'warnings: log row in runtimeMessages, real warning kept' ($r.success -and @($d.warningItems).Count -eq 1 -and $d.warningItems[0].code -eq 'C0373' -and @($d.codeWarnings).Count -eq 1 -and @($d.runtimeMessages).Count -eq 1 -and $d.runtimeMessages[0].severity -eq 'Warning') (J $d)

# --- Get-TcErrorListSummary directly: shape of runtimeMessages / ambiguousRows
Set-Scenario (@(TcUnitRows) + (& $amb) + (& $c0046)) @() 0
$els = & $mod { Get-TcErrorListSummary -SplitRuntimeLog -TimeoutSec 5 }
Check 'summary: errorItems 2, codeErrors 2, runtimeMessages 7, ambiguousRows 1' (@($els.errorItems).Count -eq 2 -and @($els.codeErrors).Count -eq 2 -and @($els.runtimeMessages).Count -eq 7 -and @($els.ambiguousRows).Count -eq 1 -and $els.errorCount -eq 2) (J $els)

# without -SplitRuntimeLog (Save-TcArchive, New-TcBootProject; review #150 F1) every row stays in errorItems
$els = & $mod { Get-TcErrorListSummary -TimeoutSec 5 }
Check 'summary without -SplitRuntimeLog: all 9 rows in errorItems, runtimeMessages / ambiguousRows empty, no note' (@($els.errorItems).Count -eq 9 -and @($els.runtimeMessages).Count -eq 0 -and @($els.ambiguousRows).Count -eq 0 -and @($els.errorItems | Where-Object { $_.PSObject.Properties['note'] }).Count -eq 0) (J $els.errorItems)

# library prefix row in a build: kept in errorItems with a note (F4), library category unchanged
Reset-State
Set-Scenario @((Row 'Error' "'PlcTask' (350): Could not open library 'Tc2_Foo'")) @() 0
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'F4 build: prefix + library message stays in errorItems (library) with a note -> LIBRARY_UNRESOLVED' ($r.error.code -eq 'LIBRARY_UNRESOLVED' -and @($r.data.errorItems).Count -eq 1 -and $r.data.errorItems[0].category -eq 'library' -and $r.data.errorItems[0].note -match '#66' -and @($r.data.runtimeMessages).Count -eq 0) (J $r)

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
exit [Math]::Min($fail, 255)
