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

# --- Error List rows. Log rows: no project / file / line (#66, 2026-10-27, VS2022 4026, local UmRT,
# RobustSolutionFrameworkDemo with TcUnit).
function Row([string]$Sev, [string]$Desc, [string]$File = $null, $Line = $null, [string]$Code = $null, [string]$Project = $null) {
    [PSCustomObject]@{ severity = $Sev; code = $Code; description = $Desc; project = $Project; file = $File; line = $Line; column = $null }
}
# Real rows, verbatim (實測 2026-11-06, VS2022 4026 zh-TW UI + local UmRT, PR #150 head c35694b, same
# project; C:\Temp\verify-reports\pr150-c35694b.md appendix, GetBuildErrors IncludeMessages=true): every
# row carries a "<timestamp> | " prefix. The fixture before this fix had no prefix (written from the
# issue text), so the unit tests passed while the real machine failed (review #150, real-machine F1).
function TcUnitRows {
    @(
        (Row 'Error' "11/6/2026 9:11:28 AM 520 ms | 'PlcTask' (350): | Test suites: 1")
        (Row 'Error' "11/6/2026 9:11:28 AM 580 ms | 'PlcTask' (350): | Failed tests: 0")
        (Row 'Error' "11/6/2026 9:11:28 AM 560 ms | 'PlcTask' (350): | Successful tests: 6")
        (Row 'Error' "11/6/2026 9:11:28 AM 500 ms | 'PlcTask' (350): | ==========TESTS FINISHED RUNNING==========")
        (Row 'Error' "11/6/2026 9:11:28 AM 600 ms | 'PlcTask' (350): | Duration: 3.6307284")
        (Row 'Error' "11/6/2026 9:11:28 AM 540 ms | 'PlcTask' (350): | Tests: 6")
        (Row 'Error' "11/6/2026 9:11:28 AM 620 ms | 'PlcTask' (350): | ======================================")
    )
}
# the two warnings of the same run (verbatim): a PLC runtime row and the XAE build-summary row
$warnPersist = { Row 'Warning' "11/6/2026 9:11:24 AM 204 ms | 'Port_851' (851): Persistent data of symbol 'GVL_HMI.setCombiTaper' not restored. Symbol not found. 29 further symbols also not restored." }
$warnXaeFailed = { Row 'Warning' "11/6/2026 9:12:34 AM 453 ms | 'TwinCAT XAE': Project 'Untitled1' build for platform 'TwinCAT OS (x64)' failed." }
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
    # real rows of the appendix (verbatim; the System Manager row has machine / user / IP masked)
    @{ Name = 'real Port_851 warning -> runtime'; Item = (& $warnPersist); Want = 'runtime' }
    @{ Name = "real 'TwinCAT XAE' build-summary warning (no (n)) -> null, kept as a build row"; Item = (& $warnXaeFailed); Want = $null }
    @{ Name = "real 'TwinCAT Analytics Workbench' (date in brackets, line 0) -> null"; Item = (Row 'Message' "'TwinCAT Analytics Workbench' (11/6/2026 9:08:16 AM): Unable to initialize ToolBox Service. First usage may take some loading time." $null 0); Want = $null }
    @{ Name = 'real License Server message -> runtime'; Item = (Row 'Message' "11/6/2026 9:11:10 AM 418 ms | 'License Server' (30): license validation status is Valid(3)"); Want = 'runtime' }
    @{ Name = 'real TcOsSys message -> runtime'; Item = (Row 'Message' "11/6/2026 9:11:18 AM 977 ms | 'TcOsSys' (50): TwinCAT System Start: AdsState: 5 NumProc: 16"); Want = 'runtime' }
    @{ Name = 'real TwinCAT System message -> runtime'; Item = (Row 'Message' "11/6/2026 9:11:19 AM 147 ms | 'TwinCAT System' (10000): Initializing TwinCAT Server TcMcGst.exe."); Want = 'runtime' }
    @{ Name = 'real System Manager message (masked) -> runtime'; Item = (Row 'Message' "11/6/2026 9:11:17 AM 322 ms | 'System Manager' (38812): Activate configuration performed from 'HOST' (0.0.0.0.1.1) by 'HOST\user'"); Want = 'runtime' }
    @{ Name = 'real C0046 (Logout, seq 112) -> null'; Item = (Row 'Error' "Identifier 'nPr150Undeclared' not defined" 'MAIN.TcPOU (Impl)' 6 'C0046' 'Untitled1'); Want = $null }
    # timestamp prefix (#150 real machine): the en-US row is 實測, the zh-TW form is 推論 (not measured)
    @{ Name = 'en-US timestamp prefix (measured row) -> runtime'; Item = (Row 'Error' "11/6/2026 9:11:28 AM 520 ms | 'PlcTask' (350): | Successful tests: 6"); Want = 'runtime' }
    @{ Name = 'zh-TW timestamp prefix (inferred) -> runtime'; Item = (Row 'Error' "2026/11/6 上午 09:11:28 520 毫秒 | 'PlcTask' (350): | Successful tests: 6"); Want = 'runtime' }
    @{ Name = 'timestamp prefix + system row -> runtime'; Item = (Row 'Error' "11/6/2026 9:11:30 AM 3 ms | 'TCOM Server' (10): NtpType Register ExternalTime failed"); Want = 'runtime' }
    @{ Name = 'timestamp prefix + file -> ambiguous'; Item = (Row 'Error' "11/6/2026 9:11:28 AM 520 ms | 'PlcTask' (350): x" 'C:\p\MAIN.TcPOU' 4); Want = 'ambiguous' }
    @{ Name = 'timestamp prefix + Measurement (time in brackets) -> null'; Item = (Row 'Error' "11/6/2026 9:11:28 AM 520 ms | 'TwinCAT Measurement' (22:30:40.881): Error creating Archive"); Want = $null }
    # the prefix must hold a digit and no quote / pipe: compiler-like texts with ' | ' do not match
    @{ Name = 'quoted name before the first pipe -> null'; Item = (Row 'Error' "Identifier 'a' | 'PlcTask' (350): x"); Want = $null }
    @{ Name = 'prefix without a digit -> null'; Item = (Row 'Error' "Unexpected token | 'PlcTask' (350): x"); Want = $null }
    @{ Name = 'two pipes before the quote -> null'; Item = (Row 'Error' "12 | 34 | 'PlcTask' (350): x"); Want = $null }
    # n2: the prefix is bounded (40 non-digits before the first digit, 60 after): a long one does not match
    @{ Name = 'prefix longer than the bound -> null'; Item = (Row 'Error' ("1" + ("x" * 70) + " | 'PlcTask' (350): x")); Want = $null }
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
        if ($null -ne $script:UtCoverage) { return @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = @($script:UtCoverage | ForEach-Object { $_.PSObject.Copy() }) } }
        @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = @(
            [PSCustomObject]@{ name = 'plc'; uniqueName = 'Demo66\plc\plc.plcproj'; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $true; status = 'pending' }
        ) }
    }
    function script:Get-TcPlcProjectList { param($SysManager) if ($null -ne $script:UtPlcList) { return @($script:UtPlcList) }; @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851; disabled = $false; projectFile = $null }) }
    # #188: login state of a built PLC project; $script:UtLoginState = $true | $false | $null (unknown)
    # $script:UtLoginByPlc: per PLC name, overrides UtLoginState; a string 'IDE_*' is thrown (like the helper's rethrow)
    $script:UtLoginState = $null
    $script:UtLoginByPlc = @{}
    $script:UtLoginCalls = 0
    $script:UtLoginPlcs = [System.Collections.Generic.List[string]]::new()
    function script:Get-TcPlcLoginState {
        param($SysManager, $Plc)
        $script:UtLoginCalls++
        $script:UtLoginPlcs.Add([string]$Plc.name)
        $v = if ($script:UtLoginByPlc.ContainsKey([string]$Plc.name)) { $script:UtLoginByPlc[[string]$Plc.name] } else { $script:UtLoginState }
        if ($v -is [string] -and $v -like 'IDE_*') { throw "${v}: unit" }
        [PSCustomObject]@{ plc = [string]$Plc.name; loggedIn = $v; source = $(if ($null -eq $v) { $null } else { 'IsLoggedIn' }); error = $(if ($null -eq $v) { 'unit: not readable' } else { $null }) }
    }
    # optional overrides for the multi-PLC cases (#188 review): $null = the single 'plc' project above
    $script:UtCoverage = $null
    $script:UtPlcList = $null
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
function Set-Login($State, [hashtable]$ByPlc = @{}) { & $mod { param($v, $b) $script:UtLoginState = $v; $script:UtLoginByPlc = $b; $script:UtLoginCalls = 0; $script:UtLoginPlcs.Clear() } $State $ByPlc }
function Get-LoginPlcs { & $mod { @($script:UtLoginPlcs) } }
function Get-LoginCalls { & $mod { $script:UtLoginCalls } }
function Reset-State {
    Set-Login $null
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
Check '(a) the 7 log rows are in runtimeMessages, category runtime' (@($d.runtimeMessages).Count -eq 7 -and @($d.runtimeMessages | Where-Object { $_.category -ne 'runtime' }).Count -eq 0 -and @($d.runtimeMessages | Where-Object { $_.description -match 'Successful tests: 6' }).Count -eq 1) (J $d.runtimeMessages)
Check '(a) no runtimeMessageNote, no warningCodes' ($null -eq $d.PSObject.Properties['runtimeMessageNote'] -and $null -eq $d.PSObject.Properties['warningCodes']) (J $d)
Check '(a/O13) plcOnlineSuspected present and false on a success' ($null -ne $d.PSObject.Properties['plcOnlineSuspected'] -and $d.plcOnlineSuspected -eq $false) (J $d)
Check '(a/#188) plcLoginState / plcOnlineEvidence present and null on a success, login state not read' ($null -ne $d.PSObject.Properties['plcLoginState'] -and $null -eq $d.plcLoginState -and $null -ne $d.PSObject.Properties['plcOnlineEvidence'] -and $null -eq $d.plcOnlineEvidence -and (Get-LoginCalls) -eq 0) (J $d)

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
Check '(b2) BUILD_FAILED, errorItems empty' (-not $r.success -and $r.error.code -eq 'BUILD_FAILED' -and @($d.errorItems).Count -eq 0) (J $r)
Check '(b2) project status unknown (no build row names it)' (@($d.projects)[0].status -eq 'unknown') (J $d.projects)
# O9 (實測 2026-11-06): PLC logged in -> XAE did not compile; the message must not read "0 code error(s)"
Check '(b2/O9) plcOnlineSuspected, the usual summary kept and the O9 sentence appended, names the log rows' ($d.plcOnlineSuspected -eq $true -and $r.error.message -match '^Build failed: 0 code error\(s\) \(1 project\(s\) failed; no code error listed in the Error List\)' -and $r.error.message -match 'XAE listed no compiler error row at all: the PLC is probably logged in, so XAE probably did not compile' -and $r.error.message -match '7 runtime / system log row' -and $r.error.message -notmatch 'Successful tests') $r.error.message
Check '(b2/O9) hint: probably logged in, Exit-TcPlcOnline then Build-TcProject (cmdlet names once each, the MCP server rewrites them)' ($r.error.hint -match 'probably logged in \(runtime-log' -and $r.error.hint -match 'Log out with Exit-TcPlcOnline, then run Build-TcProject again' -and $r.error.hint -notmatch 'PlcLogout|BuildProject') $r.error.hint
Check '(b2/#188) login state unknown -> evidence runtime-log, plcLoginState has the plc entry' ($d.plcOnlineEvidence -eq 'runtime-log' -and @($d.plcLoginState).Count -eq 1 -and $d.plcLoginState[0].plc -eq 'plc' -and $null -eq $d.plcLoginState[0].loggedIn) (J $d)
Check '(b2/O12) plcOnlineSuspected -> codeVerified null (XAE did not compile, the clean Error List proves nothing)' ($null -eq $d.codeVerified -and $null -ne $d.PSObject.Properties['codeVerified']) (J $d)
Check '(b2/O9) BUILD_REQUIRED still recorded' ($null -ne $d.buildRequired) (J $d)

# --- O9 shape of the real run: 7 TcUnit errors + the Port_851 warning + the 'TwinCAT XAE' failed warning, LastBuildInfo 2
Reset-State
Set-Scenario (TcUnitRows) @((& $warnPersist), (& $warnXaeFailed)) 2
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'O9 real shape: BUILD_FAILED, plcOnlineSuspected, failedProjects 2, PLC_ONLINE hint' ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and $d.plcOnlineSuspected -eq $true -and $d.failedProjects -eq 2 -and $r.error.message -match '2 project\(s\) failed' -and $r.error.hint -match 'Exit-TcPlcOnline') (J $r)
Check "O9 real shape: 8 runtimeMessages (7 errors + Port_851), the 'TwinCAT XAE' row stays in warningItems, not in codeWarnings" (@($d.runtimeMessages).Count -eq 8 -and @($d.warningItems).Count -eq 1 -and $d.warningItems[0].description -match "'TwinCAT XAE'" -and @($d.codeWarnings).Count -eq 0) (J $d)

# --- not O9: a real compiler row listed (after PlcLogout, seq 112) -> the normal BUILD_FAILED message
Reset-State
Set-Scenario (@(TcUnitRows) + (Row 'Error' "Identifier 'nPr150Undeclared' not defined" 'MAIN.TcPOU (Impl)' 6 'C0046' 'Untitled1') + (Row 'Error' "'nPr150Undeclared' is no valid assignment target" 'MAIN.TcPOU (Impl)' 6 'C0018' 'Untitled1')) @((& $warnXaeFailed)) 1
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'after Logout (C0046 + C0018 listed) -> plcOnlineSuspected false, "2 code error(s)", compile hint' ((-not $r.success) -and $r.data.plcOnlineSuspected -eq $false -and $r.error.message -match '2 code error' -and $r.error.message -match 'C0046' -and $r.error.hint -notmatch 'Exit-TcPlcOnline') (J $r)
# #188: code error rows listed -> the login state is not read, codeVerified unchanged
Set-Login $true
$r = Build-TcProject -WarningAction SilentlyContinue
Check '#188: code error rows listed -> login state not read, plcLoginState null, evidence null, codeVerified true (unchanged)' ((-not $r.success) -and $r.data.plcOnlineSuspected -eq $false -and $null -eq $r.data.plcLoginState -and $null -eq $r.data.plcOnlineEvidence -and $r.data.codeVerified -eq $true -and (Get-LoginCalls) -eq 0) (J $r.data)

# --- not O9 (review #150 round 3 M1): log rows left from an earlier online session + a code row
# without a file (C0077, category other) -> the C0077 is the cause, no Logout hint
Reset-State
Set-Scenario (@(TcUnitRows) + (Row 'Error' 'Unknown type: FB_Gone' $null $null 'C0077')) @((& $warnXaeFailed)) 1
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'M1: left-over log rows + C0077 without file -> plcOnlineSuspected false, message lists C0077, compile hint' ((-not $r.success) -and $r.data.plcOnlineSuspected -eq $false -and $r.error.message -match 'C0077 Unknown type: FB_Gone' -and $r.error.message -notmatch 'probably logged in' -and $r.error.hint -notmatch 'Exit-TcPlcOnline' -and $r.data.codeVerified -ne $null) (J $r)
# an XAE error row without a code (no file) + left-over log rows -> not O9 either
Reset-State
Set-Scenario (@(TcUnitRows) + (Row 'Error' "Error writing file 'C:\Demo66\_Boot\x.bin'")) @() 1
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'M1: left-over log rows + XAE error without code -> plcOnlineSuspected false, the error row in the message' ((-not $r.success) -and $r.data.plcOnlineSuspected -eq $false -and $r.error.message -match 'Error writing file' -and $r.error.hint -notmatch 'Exit-TcPlcOnline') (J $r)

# --- #188 (實測 2026-11-08, 4026 VS2022 + local UmRT): no runtime rows, no error row, only the 'TwinCAT XAE'
# ... failed warning (with its timestamp prefix), LastBuildInfo 2. The real row, verbatim:
$warn188 = { Row 'Warning' "11/8/2026 4:30:08 AM 186 ms | 'TwinCAT XAE': Project 'AxisInterface' build for platform 'TwinCAT OS (x64)' failed." }
# login state read as NOT logged in -> not suspected, but codeVerified null (a failed build without any error row proves nothing)
Reset-State
Set-Scenario @() @((& $warn188)) 2
Set-Login $false
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '#188 not logged in: BUILD_FAILED, plcOnlineSuspected false, evidence null, message "no code error listed"' ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and $d.plcOnlineSuspected -eq $false -and $null -eq $d.plcOnlineEvidence -and $r.error.message -match 'no code error listed' -and $r.error.message -match 'plc=false') (J $r)
Check '#188 not logged in: codeVerified null (not true), key present' ($null -eq $d.codeVerified -and $null -ne $d.PSObject.Properties['codeVerified']) (J $d)
Check '#188 not logged in: plcLoginState = one entry plc / false, compile hint, login state read once' (@($d.plcLoginState).Count -eq 1 -and $d.plcLoginState[0].plc -eq 'plc' -and $d.plcLoginState[0].loggedIn -eq $false -and $r.error.hint -notmatch 'Exit-TcPlcOnline' -and (Get-LoginCalls) -eq 1) (J $d.plcLoginState)
# login state unknown -> not suspected (no runtime rows), codeVerified null
Reset-State
Set-Scenario @() @((& $warn188)) 2
$r = Build-TcProject -WarningAction SilentlyContinue
Check '#188 login state unknown, no runtime rows: plcOnlineSuspected false, codeVerified null, plc=unknown in the message' ((-not $r.success) -and $r.data.plcOnlineSuspected -eq $false -and $null -eq $r.data.codeVerified -and $null -eq $r.data.plcOnlineEvidence -and $r.error.message -match 'plc=unknown' -and @($r.data.plcLoginState).Count -eq 1) (J $r)
# login state read as logged in -> suspected, evidence login-state, PLC_ONLINE hint
Reset-State
Set-Scenario @() @((& $warn188)) 2
Set-Login $true
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '#188 logged in: plcOnlineSuspected true, evidence login-state, codeVerified null' ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and $d.plcOnlineSuspected -eq $true -and $d.plcOnlineEvidence -eq 'login-state' -and $null -eq $d.codeVerified) (J $d)
Check '#188 logged in: hint is BUILD_FAILED_PLC_ONLINE (Exit-TcPlcOnline then Build-TcProject), message names the logged-in PLC' ($r.error.hint -eq (& $mod { Get-TcErrorHint -Code 'BUILD_FAILED_PLC_ONLINE' }) -and $r.error.hint -match 'Exit-TcPlcOnline' -and $r.error.message -match '^Build failed: 0 code error\(s\) \(2 project\(s\) failed; no code error listed in the Error List\)' -and $r.error.message -match 'PLC project\(s\) plc are logged in') $r.error.message
Check '#188 logged in: BUILD_REQUIRED recorded' ($null -ne $d.buildRequired) (J $d)
# logged in AND runtime rows -> the login state wins as evidence
Reset-State
Set-Scenario (TcUnitRows) @((& $warn188)) 2
Set-Login $true
$r = Build-TcProject -WarningAction SilentlyContinue
Check '#188 logged in + runtime rows: evidence login-state' ($r.data.plcOnlineSuspected -eq $true -and $r.data.plcOnlineEvidence -eq 'login-state') (J $r.data)
# read back as NOT logged in + runtime rows: the runtime-log evidence still holds (#188 review: a false read
# while logged in was never measured - IsLoggedIn never read back a bool on 4026 VS2022, 4024 logged in not
# measured - so it is not trusted to drop the Logout hint; fail closed). The false read is only reported.
Reset-State
Set-Scenario (TcUnitRows) @((& $warn188)) 2
Set-Login $false
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '#188 not logged in + runtime rows: runtime-log still holds (suspected, evidence runtime-log, PLC_ONLINE hint, codeVerified null)' ((-not $r.success) -and $r.error.code -eq 'BUILD_FAILED' -and $d.plcOnlineSuspected -eq $true -and $d.plcOnlineEvidence -eq 'runtime-log' -and $null -eq $d.codeVerified -and $r.error.hint -eq (& $mod { Get-TcErrorHint -Code 'BUILD_FAILED_PLC_ONLINE' })) (J $r)
Check '#188 not logged in + runtime rows: message names plc=false next to "probably logged in"' ($r.error.message -match 'plc=false' -and $r.error.message -match 'probably logged in' -and $r.error.message -match '7 runtime / system log row') $r.error.message
# login state unknown + runtime rows: the runtime-log rule still applies (covered by b2 too)
Reset-State
Set-Scenario (TcUnitRows) @((& $warn188)) 2
$r = Build-TcProject -WarningAction SilentlyContinue
Check '#188 login unknown + runtime rows: evidence runtime-log' ($r.data.plcOnlineSuspected -eq $true -and $r.data.plcOnlineEvidence -eq 'runtime-log') (J $r.data)

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

# --- #188 review: several PLC projects
function CovEntry([string]$Name, [string]$Unique, [bool]$ShouldBuild = $true) {
    [PSCustomObject]@{ name = $Name; uniqueName = $Unique; configuration = 'Release'; platform = 'TwinCAT OS (x64)'; shouldBuild = $ShouldBuild; status = $(if ($ShouldBuild) { 'pending' } else { 'skipped' }) }
}
function PlcNode([string]$Name, [bool]$Disabled = $false, [string]$ProjectFile = $null) {
    [PSCustomObject]@{ name = $Name; nodePath = "TIPC^$Name"; projectPath = "TIPC^$Name^$Name Project"; adsPort = 851; disabled = $Disabled; projectFile = $ProjectFile }
}
function Set-Plcs($Coverage, $PlcList) { & $mod { param($c, $l) $script:UtCoverage = $c; $script:UtPlcList = $l } $Coverage $PlcList }

# one logged in, one not, one unknown -> login-state, three entries
Reset-State
Set-Plcs @((CovEntry 'plcA' 'Demo66\plcA\plcA.plcproj'), (CovEntry 'plcB' 'Demo66\plcB\plcB.plcproj'), (CovEntry 'plcC' 'Demo66\plcC\plcC.plcproj')) @((PlcNode 'plcA'), (PlcNode 'plcB'), (PlcNode 'plcC'))
Set-Scenario @() @((& $warn188)) 2
Set-Login $null @{ plcA = $false; plcB = $true }
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'multi-PLC: one logged in -> login-state, plcLoginState 3 entries (false / true / null), message names plcB only' ($d.plcOnlineEvidence -eq 'login-state' -and $d.plcOnlineSuspected -eq $true -and @($d.plcLoginState).Count -eq 3 -and $d.plcLoginState[0].loggedIn -eq $false -and $d.plcLoginState[1].loggedIn -eq $true -and $null -eq $d.plcLoginState[2].loggedIn -and $r.error.message -match 'PLC project\(s\) plcB are logged in') (J $d.plcLoginState)

# skipped and disabled PLC projects are not read and not listed
Reset-State
Set-Plcs @((CovEntry 'plcA' 'Demo66\plcA\plcA.plcproj'), (CovEntry 'plcS' 'Demo66\plcS\plcS.plcproj' $false), (CovEntry 'plcD' 'Demo66\plcD\plcD.plcproj' $false)) @((PlcNode 'plcA'), (PlcNode 'plcS'), (PlcNode 'plcD' $true))
Set-Scenario @() @((& $warn188)) 2
Set-Login $true
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
$st = @($d.projects | ForEach-Object { "$($_.name)=$($_.status)" }) -join ','
Check 'skipped / disabled: statuses unknown / skipped / disabled, only plcA read and listed' ($st -eq 'plcA=unknown,plcS=skipped,plcD=disabled' -and @($d.plcLoginState).Count -eq 1 -and $d.plcLoginState[0].plc -eq 'plcA' -and (@(Get-LoginPlcs) -join ',') -eq 'plcA') "$st | $(J $d.plcLoginState) | calls $((Get-LoginPlcs) -join ',')"

# no one-to-one match (an enabled tree item 'Extra' matches no .plcproj entry) -> no name fallback, every entry null with the match error
Reset-State
Set-Plcs @((CovEntry 'plc' 'Demo66\plc\plc.plcproj'), (CovEntry 'plc2' 'Demo66\plc2\plc2.plcproj')) @((PlcNode 'plc'), (PlcNode 'Extra'))
Set-Scenario @() @((& $warn188)) 2
Set-Login $true
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'ambiguous match: not read (no name fallback), both entries loggedIn null with the match error, not suspected' ((Get-LoginCalls) -eq 0 -and @($d.plcLoginState).Count -eq 2 -and @($d.plcLoginState | Where-Object { $null -ne $_.loggedIn }).Count -eq 0 -and @($d.plcLoginState | Where-Object { $_.error -match 'cannot be matched one to one' -and $_.error -match 'the login state is not read' -and $_.error -match "enabled PLC 'Extra'" }).Count -eq 2 -and $d.plcOnlineSuspected -eq $false -and $null -eq $d.codeVerified) (J $d.plcLoginState)

# path match leaves an entry without a node: the name fallback must not reuse the node of another entry
$slnDir = Split-Path -Parent $sln
$pfA = Join-Path $slnDir 'a\plc.plcproj'
Reset-State
Set-Plcs @((CovEntry 'plc' 'a\plc.plcproj'), (CovEntry 'plc' 'b\plc.plcproj')) @((PlcNode 'plc' $false $pfA))
Set-Scenario @() @((& $warn188)) 2
Set-Login $true
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'path match + unmatched entry: the PLC is read once, the second entry null (node already matched)' ((Get-LoginCalls) -eq 1 -and @($d.plcLoginState).Count -eq 2 -and $d.plcLoginState[0].loggedIn -eq $true -and $null -eq $d.plcLoginState[1].loggedIn -and $d.plcLoginState[1].error -match 'not already matched' -and $d.plcOnlineEvidence -eq 'login-state') "$(J $d.plcLoginState) | disabledMatchBy $($d.disabledMatchBy)"

# the helper throws IDE_BUSY (rethrown by Get-TcPlcLoginState) -> Build returns IDE_BUSY and records BUILD_REQUIRED
Reset-State
Set-Plcs $null $null
Set-Scenario @() @((& $warn188)) 2
Set-Login 'IDE_BUSY'
$r = Build-TcProject -WarningAction SilentlyContinue
$br = & $mod { Get-TcBuildRequired }
Check 'helper IDE_BUSY -> Build fails with IDE_BUSY, BUILD_REQUIRED recorded' ((-not $r.success) -and $r.error.code -eq 'IDE_BUSY' -and $null -ne $r.data.buildRequired -and $null -ne $br) "$(J $r) | state $(J $br)"
Set-Plcs $null $null

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
exit [Math]::Min($fail, 255)
