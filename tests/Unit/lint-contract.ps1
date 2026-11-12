# Unit: semantic linter (#252 Phase 1a) result contract (design.md D4 / D5 / D6), no IDE.
#   A  D4 rows: pass with warnings, LINT_FAILED, LINT_PARSE_FAILED, LINT_INCOMPLETE (+ acceptSkips),
#      LINT_PROFILE_INVALID, LINT_BASELINE_INVALID, LINT_INPUT_INVALID, PLC_PROJECT_AMBIGUOUS /
#      PLC_PROJECT_NOT_FOUND (-SolutionPath), LINT_ENGINE_ERROR, LINT_ENGINE_UNAVAILABLE;
#      data.passed absent whenever nothing was analysed
#   B  unresolved[] / requiresDisposition; blocking rules (FailOn, blockable false, profile blocking)
#   C  profile: discovery, overrides[], suppressions, exclude, -RuleProfile default
#   D  read-only (no file content / time changes), deterministic (two runs, write order,
#      en-US vs zh-TW byte-identical), hash namespace (changed .cs -> new engine type)
#   E  performance budget: 200 objects analysed in <= 2 s after the first compile (wall clock:
#      this script is in the serial group of scripts/check.ps1)
# Mock basis: fixture = tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13).
# The LanguageMode / Add-Type / engine-fault seams are module test variables ([推論] for how a
# real AppLocker / antivirus failure looks: only the classification is tested).
#   powershell.exe -NoProfile -File tests/Unit/lint-contract.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
Import-Module $modulePath -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\LintFixture.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function Js($o) { return ($o | ConvertTo-Json -Depth 30 -Compress) }
function HasPassed($r) { return ($null -ne $r.data -and $r.data -is [System.Collections.IDictionary] -and $r.data.Contains('passed')) }

$root = Join-Path $env:TEMP ("tcauto-unit-lintcontract-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$root = & (Get-Module TwinCATAutomation) { param($p) Get-TcLongPath $p } $root   # CI %TEMP% is an 8.3 short path (RUNNER~1); the engine reports long paths
$n = 0
function New-Fx([switch]$Reverse) { $script:n++; return (New-LintFixture (Join-Path $root ("c{0:D2}" -f $script:n)) -ReverseWriteOrder:$Reverse) }
function Set-Profile($Fx, [string]$Json, [string]$Name = 'lint-profile.json') {
    $dir = Join-Path ([System.IO.Path]::GetDirectoryName($Fx.Sln)) '.tcauto'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $p = Join-Path $dir $Name
    [System.IO.File]::WriteAllText($p, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}
function Break-Compile($Fx) { Set-LintFxCompile $Fx ($script:LintFxCompile + 'POUs\FB_Gone.TcPOU') }
function Add-Orphan($Fx) { Write-LintFxFile (Join-Path $Fx.PlcDir 'POUs\FB_Orphan.TcPOU') ((Get-LintFxFbAText).Replace('FB_A', 'FB_Orphan')) }

# ================================================================ A  D4 rows
$fx = New-Fx; Add-Orphan $fx
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A1 warning only -> success, passed, verdict pass' ($r.success -and $r.data.passed -eq $true -and $r.data.verdict -eq 'pass' -and @($r.data.diagnostics).Count -eq 1) (Js $r.data.summary)
Check 'B1 behaviour warning -> unresolved + requiresDisposition, success stays true' ($r.data.requiresDisposition -and @($r.data.unresolved).Count -eq 1 -and @($r.data.unresolved)[0].ruleId -eq 'PROJECT-COMPILE-003') (Js $r.data.unresolved)
Check 'A1 contract fields' ($r.data.contextLevel -eq 'project' -and $r.data.source.ideChecked -eq $false -and $r.data.engine.sourceHash -match '^[0-9a-f]{12}$' -and $r.data.failOn -eq 'error' -and @($r.data.rulesRun).Count -ge 30 -and @($r.data.newSuppressions).Count -eq 0) ((Js $r.data.engine) + ' ' + $r.data.failOn)

$fx = New-Fx; Break-Compile $fx
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A2 blocking -> LINT_FAILED, passed false, hint, diagnostics kept' (-not $r.success -and $r.error.code -eq 'LINT_FAILED' -and (HasPassed $r) -and $r.data.passed -eq $false -and $r.error.hint -and @($r.data.diagnostics).Count -eq 1) (Js $r.error)

$fx = New-Fx
Edit-LintFxFile $fx.Main { param($t) $t.Replace("`r`nEND_IF]]>", ']]>') }
Break-Compile $fx
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A3 parse failure wins over LINT_FAILED (D4 priority), both diagnostics kept' ($r.error.code -eq 'LINT_PARSE_FAILED' -and $r.data.passed -eq $false -and @($r.data.diagnostics | Where-Object { $_.ruleId -eq 'PROJECT-COMPILE-001' }).Count -eq 1) (Js $r.error)

$fx = New-Fx
Edit-LintFxFile $fx.Main { param($t) $t.Replace('<Declaration><![CDATA[PROGRAM MAIN', "<Declaration><![CDATA[{IF defined (X)}`r`nPROGRAM MAIN`r`n{END_IF}") }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A4 default-blocking rule skipped -> LINT_INCOMPLETE, verdict incomplete' ($r.error.code -eq 'LINT_INCOMPLETE' -and $r.data.verdict -eq 'incomplete' -and $r.data.passed -eq $false) (Js $r.data.coverage.blockingRulesSkipped)
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","acceptSkips":[{"ruleId":"PROJECT-KIND-001","objectPath":"MAIN","reason":"simulation define reviewed by owner"},{"ruleId":"PROJECT-NAME-001","objectPath":"MAIN","reason":"simulation define reviewed by owner"}]}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A4 acceptSkips with reason -> pass, listed in acceptedSkips and overrides' ($r.success -and @($r.data.coverage.acceptedSkips).Count -eq 2 -and @($r.data.coverage.blockingRulesSkipped).Count -eq 0 -and @($r.data.profile.overrides | Where-Object { $_.kind -eq 'acceptSkip' }).Count -eq 2 -and $r.data.profile.source -eq 'discovered') (Js $r.data.profile)

# profile invalid: discovered under .tcauto (the .sln directory), never falls back to default
$bad = @(
    @('unknown rule id', '{"schema":"tcauto-lint-profile/1","rules":{"SCAN-NOPE-001":{"enabled":false,"reason":"xxxxxxxxxxxx"}}}'),
    @('not JSON', '{"schema": tcauto'),
    @('unknown field', '{"schema":"tcauto-lint-profile/1","script":"Remove-Item"}'),
    @('wrong schema', '{"schema":"tcauto-lint-profile/2"}'),
    @('exclude without reason', '{"schema":"tcauto-lint-profile/1","exclude":[{"objectPath":"MAIN"}]}'),
    @('reason too short', '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"MAIN","ruleId":"PROJECT-GUID-005","reason":"short"}]}'),
    @('wildcard objectPath', '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"FB_*","ruleId":"PROJECT-GUID-005","reason":"library objects, generated"}]}'),
    @('LINT-PARSE cannot be disabled', '{"schema":"tcauto-lint-profile/1","rules":{"LINT-PARSE-002":{"enabled":false,"reason":"parser too strict for us"}}}'),
    @('weakening without reason', '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-GUID-003":{"blocking":false}}}'),
    @('baseline outside the solution', '{"schema":"tcauto-lint-profile/1","baseline":"..\\..\\Windows\\x.json"}'),
    @('extends unknown profile', '{"schema":"tcauto-lint-profile/1","extends":"robust-solution"}'),
    @('LINT-PARSE cannot be suppressed', '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"MAIN","ruleId":"LINT-PARSE-002","reason":"parser does not know this"}]}'),
    @('maxFileSizeMB out of range', '{"schema":"tcauto-lint-profile/1","maxFileSizeMB":0}'),
    @('regex-like params', '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-GUID-005":{"params":{"pattern":".*"}}}}'))
foreach ($b in $bad) {
    $fx = New-Fx; Break-Compile $fx
    Set-Profile $fx $b[1] | Out-Null
    $r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
    Check "A5 profile invalid ($($b[0])) -> LINT_PROFILE_INVALID, nothing analysed" ($r.error.code -eq 'LINT_PROFILE_INVALID' -and -not (HasPassed $r) -and -not $r.data.Contains('diagnostics') -and $r.error.hint) ("$($r.error.code): $($r.error.message)")
}
$fx = New-Fx
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj -RuleProfile (Join-Path $fx.Root 'nope.json')
Check 'A5 -RuleProfile file missing -> LINT_PROFILE_INVALID' ($r.error.code -eq 'LINT_PROFILE_INVALID' -and -not (HasPassed $r)) $r.error.message

# review must-fix 1 / 2: disabling the one rule that reported a broken file must not give a pass
$fx = New-Fx
Write-LintFxFile $fx.Plcproj '<Foo/>' $false
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-XML-004":{"enabled":false,"reason":"trying to hide the broken project"}}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A10 .plcproj not an MSBuild project + its rule disabled -> LINT_INCOMPLETE, never pass' (-not $r.success -and $r.error.code -eq 'LINT_INCOMPLETE' -and $r.data.passed -eq $false) (Js $r.error)
$fx = New-Fx
Edit-LintFxFile $fx.FbA { param($t) $t.Replace('</Method>', '') }
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-XML-001":{"enabled":false,"reason":"trying to hide the broken file"}}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A10 broken object file + XML-001 disabled -> LINT_INCOMPLETE (5 of 6 analysed)' ($r.error.code -eq 'LINT_INCOMPLETE' -and $r.data.coverage.objectsAnalyzed -eq 5 -and $r.data.coverage.objectsInScope -eq 6) (Js $r.data.coverage)
$fx = New-Fx
Edit-LintFxFile $fx.Gvl { param($t) $t.Replace('<TcPlcObject ', '<Foo ').Replace('</TcPlcObject>', '</Foo>') }
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-XML-004":{"enabled":false,"reason":"trying to hide the broken file"}}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'should-fix 2: root <Foo> + XML-004 disabled -> LINT_INCOMPLETE (not counted as analysed)' ($r.error.code -eq 'LINT_INCOMPLETE' -and $r.data.coverage.objectsAnalyzed -eq 5) (Js $r.data.coverage)
$fx = New-Fx
Edit-LintFxFile $fx.Gvl { param($t) $t -replace '(?s)<TcPlcObject([^>]*)>.*</TcPlcObject>', '<TcPlcObject$1></TcPlcObject>' }
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-XML-004":{"enabled":false,"reason":"trying to hide the broken file"}}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'should-fix 2: empty <TcPlcObject> + XML-004 disabled -> LINT_INCOMPLETE' ($r.error.code -eq 'LINT_INCOMPLETE' -and $r.data.coverage.objectsAnalyzed -eq 5) (Js $r.data.coverage)
$fx = New-Fx
Edit-LintFxFile $fx.Main { param($t) $t.Replace('// set mode', '// ' + ('x' * 1200000)) }
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","maxFileSizeMB":1}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'should-fix 5: file over maxFileSizeMB -> notAnalyzed too-large, LINT_INCOMPLETE' ($r.error.code -eq 'LINT_INCOMPLETE' -and @($r.data.coverage.notAnalyzed | Where-Object { $_.reason -eq 'too-large' }).Count -eq 1) (Js $r.data.coverage)
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj -RuleProfile default
Check 'should-fix 5: the default limit (8 MB) reads a 1.2 MB file' ($r.success) (Js $r.error)
$fx = New-Fx
Edit-LintFxFile $fx.FbA { param($t) $t.Replace('</Method>', '') }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'D4 priority: an unanalysed file explained by its own blocking finding is LINT_FAILED, not LINT_INCOMPLETE' ($r.error.code -eq 'LINT_FAILED') (Js $r.error)
$fx = New-Fx
Set-LintFxCompile $fx @()
Remove-Item -LiteralPath $fx.Main, $fx.FbA, $fx.Dut, $fx.Gvl, $fx.Task
Write-LintFxFile $fx.Tsproj ((Get-LintFxTsprojText) -replace '(?s)<Contexts>.*?</Contexts>', '') $false
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A10 project without any object -> LINT_INCOMPLETE (nothing analysed)' ($r.error.code -eq 'LINT_INCOMPLETE' -and $r.data.coverage.objectsInScope -eq 0) (Js $r)

# baseline
$fx = New-Fx
Set-Profile $fx '{"schema":"tcauto-lint-baseline/1","types":{"E_Mode":{"kind":"ENUM","members":[{"name":"Manual","value":"0"}]}}}' 'lint-baseline.json' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A6 default-location baseline is loaded without a profile' ($r.success -and $r.data.baseline.types -eq 1 -and $r.data.baseline.source -eq 'discovered' -and $r.data.baseline.sha256 -match '^[0-9a-f]{64}$') (Js $r.data.baseline)
Set-Profile $fx '{"schema":"tcauto-lint-baseline/1","types":[]}' 'lint-baseline.json' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A6 broken baseline -> LINT_BASELINE_INVALID, nothing analysed' ($r.error.code -eq 'LINT_BASELINE_INVALID' -and -not (HasPassed $r)) $r.error.message
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","baseline":{"disabled":true,"reason":"no public types in this project"}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A6 baseline disabled by profile with reason -> listed in overrides' ($r.success -and $null -eq $r.data.baseline -and @($r.data.profile.overrides | Where-Object { $_.kind -eq 'baseline-disabled' }).Count -eq 1) (Js $r.data.profile.overrides)
$fx = New-Fx
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","baseline":"lint-baseline-v2.json"}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A6 profile requires a baseline that does not exist -> LINT_BASELINE_INVALID' ($r.error.code -eq 'LINT_BASELINE_INVALID' -and -not (HasPassed $r)) $r.error.message

# input
$fx = New-Fx
$cases = @(
    @('nothing given', @{}),
    @('PLC name without -SolutionPath', @{ PlcProjectPath = 'PLC1' }),
    @('.plcproj missing', @{ PlcProjectPath = (Join-Path $fx.Root 'x.plcproj') }),
    @('-Scope Object without -ObjectPaths', @{ PlcProjectPath = $fx.Plcproj; Scope = 'Object' }),
    @('-ObjectPaths without -Scope Object', @{ PlcProjectPath = $fx.Plcproj; ObjectPaths = @('MAIN') }),
    @('object not in the project', @{ PlcProjectPath = $fx.Plcproj; Scope = 'Object'; ObjectPaths = @('FB_Nope') }),
    @('-SolutionPath not a .sln / .tsproj', @{ SolutionPath = $fx.Plcproj }))
foreach ($c in $cases) {
    $p = $c[1]
    $r = Invoke-TcLintProject @p
    Check "A7 input invalid ($($c[0])) -> LINT_INPUT_INVALID" ($r.error.code -eq 'LINT_INPUT_INVALID' -and -not (HasPassed $r) -and $r.error.hint) "$($r.error.code): $($r.error.message)"
}
Edit-LintFxFile $fx.Main { param($t) $t.Replace($script:LintFx.MainId, '{570194db-04ab-4683-94d1-7e94b2eca65}') }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj -Scope Object -ObjectPaths 'FB_A.M_Do'
Check 'A7 -Scope Object: only that object (MAIN finding out of scope)' ($r.success -and $r.data.coverage.objectsInScope -eq 1 -and @($r.data.diagnostics).Count -eq 0) (Js $r.data.coverage)
Check 'should-fix 4: data.scope says Object, which objects, and how many the project has' ($r.data.scope.scope -eq 'Object' -and (@($r.data.scope.objectPaths) -join ',') -eq 'FB_A.M_Do' -and $r.data.scope.objectsInProject -eq 6 -and $r.data.scope.note -match 'not the whole project') (Js $r.data.scope)
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj -Scope Object -ObjectPaths 'MAIN'
Check 'A7 -Scope Object: MAIN finding in scope' ($r.error.code -eq 'LINT_FAILED' -and @($r.data.diagnostics).Count -eq 1) (Js $r.data.summary)

# -SolutionPath
$fx = New-Fx
$r = Invoke-TcLintProject -SolutionPath $fx.Sln
Check 'A8 -SolutionPath with one PLC -> that PLC' ($r.success -and $r.data.source.plcProjectPath -eq $fx.Plcproj) (Js $r.data.source)
$r = Invoke-TcLintProject -SolutionPath $fx.Tsproj -PlcProjectPath 'plc1'
Check 'A8 -SolutionPath .tsproj + PLC name (case-insensitive) ' ($r.success) (Js $r.error)
Push-Location ([System.IO.Path]::GetDirectoryName($fx.Sln))
try { $r = Invoke-TcLintProject -SolutionPath 'Sol.sln' -PlcProjectPath 'Sol\PLC1\PLC1.plcproj' } finally { Pop-Location }
Check 'A8 relative paths resolve against the PowerShell location (not the .NET current directory)' ($r.success -and $r.data.source.plcProjectPath -eq $fx.Plcproj) (Js $r.error)
Check 'A8 -SolutionPath .tsproj + PLC name (case-insensitive)' ($r.success) (Js $r.error)
$r = Invoke-TcLintProject -SolutionPath $fx.Sln -PlcProjectPath 'PLC9'
Check 'A8 unknown PLC name -> PLC_PROJECT_NOT_FOUND with data.plcProjects' ($r.error.code -eq 'PLC_PROJECT_NOT_FOUND' -and @($r.data.plcProjects).Count -eq 1 -and -not (HasPassed $r)) (Js $r.data)
Edit-LintFxFile $fx.Tsproj { param($t) $t.Replace("`t`t</Plc>", "`t`t`t<Project GUID=`"{722106DD-7639-49F1-8215-188851906D22}`" Name=`"PLC2`" PrjFilePath=`"PLC2\PLC2.plcproj`" />`r`n`t`t</Plc>") }
$r = Invoke-TcLintProject -SolutionPath $fx.Sln
Check 'A8 two PLCs without a name -> PLC_PROJECT_AMBIGUOUS, data.plcProjects lists both' ($r.error.code -eq 'PLC_PROJECT_AMBIGUOUS' -and @($r.data.plcProjects).Count -eq 2 -and -not (HasPassed $r)) (Js $r.data)
$r = Invoke-TcLintProject -SolutionPath $fx.Sln -PlcProjectPath 'PLC2'
Check 'A8 the selected PLC .plcproj does not exist -> PROJECT-TSPROJ-001, LINT_FAILED' ($r.error.code -eq 'LINT_FAILED' -and @($r.data.diagnostics)[0].ruleId -eq 'PROJECT-TSPROJ-001') (Js $r.data.diagnostics)
$r = Invoke-TcLintProject -SolutionPath $fx.Sln -PlcProjectPath 'PLC1'
$fxp = New-Fx
Edit-LintFxFile $fxp.Tsproj { param($t) $t.Replace(' PrjFilePath="PLC1\PLC1.plcproj"', '') }
$rp = Invoke-TcLintProject -SolutionPath $fxp.Sln
Check 'should-fix 3: Plc/Project without PrjFilePath -> LINT_INPUT_INVALID, no exception' ($rp.error.code -eq 'LINT_INPUT_INVALID' -and -not (HasPassed $rp)) (Js $rp.error)
Edit-LintFxFile $fxp.Tsproj { param($t) $t.Replace(' Name="PLC1"', ' Name="PLC1" PrjFilePath="PLC1\PL|C1.plcproj"') }
$rp = Invoke-TcLintProject -SolutionPath $fxp.Sln
Check 'should-fix 3: PrjFilePath with illegal characters -> LINT_INPUT_INVALID, no exception' ($rp.error.code -eq 'LINT_INPUT_INVALID' -and -not (HasPassed $rp)) (Js $rp.error)
Check 'A8 PLC1 selected by name: the other PLC (missing .plcproj) is still reported' ($r.error.code -eq 'LINT_FAILED' -and @($r.data.diagnostics | Where-Object { $_.ruleId -eq 'PROJECT-TSPROJ-001' }).Count -eq 1) (Js $r.data.diagnostics)

# engine
$fx = New-Fx
& $mod { $script:TcLintLanguageModeOverride = 'ConstrainedLanguage' }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
& $mod { $script:TcLintLanguageModeOverride = $null }
Check 'A9 Constrained Language Mode -> LINT_ENGINE_UNAVAILABLE + data.languageMode' ($r.error.code -eq 'LINT_ENGINE_UNAVAILABLE' -and $r.data.languageMode -eq 'ConstrainedLanguage' -and -not (HasPassed $r) -and $r.error.hint) (Js $r)
& $mod { $script:TcLintAddTypeOverride = { param($code) throw 'Access to the path csc.exe is denied.' } }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A9 Add-Type blocked (environment) -> LINT_ENGINE_UNAVAILABLE' ($r.error.code -eq 'LINT_ENGINE_UNAVAILABLE' -and $r.data.engineDetail -match 'denied') (Js $r)
& $mod { $script:TcLintAddTypeOverride = { param($code) throw 'c:\x.cs(12) : error CS1002: ; expected' } }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
& $mod { $script:TcLintAddTypeOverride = $null }
Check 'A9 C# compile error (engine bug) -> LINT_ENGINE_ERROR' ($r.error.code -eq 'LINT_ENGINE_ERROR' -and -not (HasPassed $r)) (Js $r)
& $mod { $script:TcLintTestFault = $true }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
& $mod { $script:TcLintTestFault = $false }
Check 'A9 engine exception -> LINT_ENGINE_ERROR, no partial result, no passed' ($r.error.code -eq 'LINT_ENGINE_ERROR' -and -not (HasPassed $r) -and -not $r.data.Contains('diagnostics') -and $r.data.engineDetail -match 'test fault') (Js $r)
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'A9 engine works again after the seams are cleared' ($r.success) (Js $r.error)

# ================================================================ B  blocking computation
$fx = New-Fx; Add-Orphan $fx
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj -FailOn warning
Check 'B2 -FailOn warning does not make a blockable=false rule blocking (COMPILE-003)' ($r.success -and -not @($r.data.diagnostics)[0].blocking -and $r.data.failOn -eq 'warning') (Js $r.data.diagnostics)
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","failOn":"warning","rules":{"PROJECT-COMPILE-003":{"blocking":true}}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj -FailOn error
$d = @($r.data.diagnostics)[0]
Check 'B3 profile blocking:true on a blockable=false rule -> blocking, blockingSource profile; -FailOn error cannot loosen the profile' ($r.error.code -eq 'LINT_FAILED' -and $d.blocking -and $d.blockingSource -eq 'profile' -and $r.data.failOn -eq 'warning') (Js $d)
$fx = New-Fx; Break-Compile $fx
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-COMPILE-001":{"severity":"warning","reason":"generated files are added by the build server"}}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'B4 severity lowered by profile (with reason) -> not blocking, listed in overrides' ($r.success -and @($r.data.diagnostics)[0].severity -eq 'warning' -and @($r.data.profile.overrides | Where-Object { $_.kind -eq 'rule' -and $_.ruleId -eq 'PROJECT-COMPILE-001' }).Count -eq 1) (Js $r.data.profile.overrides)

# ================================================================ C  profile
$fx = New-Fx; Break-Compile $fx
$pp = Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"PLC1.plcproj","ruleId":"PROJECT-COMPILE-001","reason":"file is generated by the build server"}]}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = @($r.data.diagnostics)[0]
Check 'C1 profile suppression -> finding kept with suppressed=true, not counted, pass' ($r.success -and $d.suppressed -and $d.suppressionReason -like 'file is generated*' -and -not $d.blocking -and $r.data.summary.suppressed -eq 1 -and $r.data.summary.errors -eq 0) (Js $d)
Check 'C1 profile reported: name, source, path, sha256, overrides' ($r.data.profile.source -eq 'discovered' -and $r.data.profile.path -eq $pp -and $r.data.profile.sha256 -match '^[0-9a-f]{64}$' -and @($r.data.profile.overrides)[0].kind -eq 'suppression') (Js $r.data.profile)
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj -RuleProfile default
Check 'C2 -RuleProfile default ignores the discovered profile and says so' ($r.error.code -eq 'LINT_FAILED' -and $r.data.profile.ignoredDiscoveredProfile -eq $pp) (Js $r.data.profile)
$fx = New-Fx
Edit-LintFxFile $fx.Dut { param($t) $t.Replace($script:LintFx.DutId, '{a1b2c3d4-e5f6-7890-abcd-ef0123456789}') }
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-GUID-005":{"enabled":false,"reason":"legacy ids kept on purpose"}}}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'C3 rule disabled with reason -> not run, rulesNotRun, overrides' ($r.success -and @($r.data.diagnostics).Count -eq 0 -and @($r.data.coverage.rulesNotRun | Where-Object { $_.ruleId -eq 'PROJECT-GUID-005' -and $_.reason -eq 'disabled-by-profile' }).Count -eq 1 -and @($r.data.rulesRun) -notcontains 'PROJECT-GUID-005@1') (Js $r.data.coverage.rulesNotRun)
$fx = New-Fx
Edit-LintFxFile $fx.Main { param($t) $t.Replace("`r`nEND_IF]]>", ']]>') }
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","exclude":[{"objectPath":"MAIN","reason":"parser limitation, see issue"}]}' | Out-Null
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'C4 exclude with reason: no LINT-PARSE, coverage.excluded, PROJECT rules still run' ($r.success -and @($r.data.coverage.excluded | Where-Object { $_.objectPath -eq 'MAIN' }).Count -eq 2 -and @($r.data.profile.overrides | Where-Object { $_.kind -eq 'exclude' }).Count -eq 1) (Js $r.data.coverage)

# ================================================================ D  read-only, deterministic, hash namespace
function Get-Snapshot([string]$Dir) { return (@(Get-ChildItem -LiteralPath $Dir -Recurse -File | Sort-Object FullName | ForEach-Object { "$($_.FullName)|$($_.Length)|$($_.LastWriteTimeUtc.Ticks)|$((Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash)" }) -join "`n") }
$fx = New-Fx; Break-Compile $fx; Add-Orphan $fx
$before = Get-Snapshot $fx.Root
$r1 = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$after = Get-Snapshot $fx.Root
Check 'D1 lint changes no file (content, size, time)' ($before -ceq $after -and @(Get-ChildItem -LiteralPath $fx.Root -Recurse -File).Count -eq @($before -split "`n").Count) 'snapshot differs'
$r2 = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'D2 two runs byte-identical' ((Js $r1) -ceq (Js $r2)) 'differs'
$fxR = New-Fx -Reverse; Break-Compile $fxR; Add-Orphan $fxR
$r3 = Invoke-TcLintProject -PlcProjectPath $fxR.Plcproj
Check 'D3 file write order does not change the output' ((Js $r1).Replace(($fx.Root -replace '\\', '\\'), 'ROOT') -ceq (Js $r3).Replace(($fxR.Root -replace '\\', '\\'), 'ROOT')) 'differs'

# en-US vs zh-TW in separate processes (a broken XML file puts a .NET exception text into engineDetail)
$fxC = New-Fx; Break-Compile $fxC
Edit-LintFxFile $fxC.FbA { param($t) $t.Replace('</Method>', '') }
Edit-LintFxFile $fxC.Main { param($t) $t.Replace('// set mode', '// 設定模式') }
$helper = Join-Path $root 'culture-run.ps1'
@'
param([string]$Module, [string]$Plcproj, [string]$Culture, [string]$Out)
[System.Threading.Thread]::CurrentThread.CurrentCulture = $Culture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $Culture
Import-Module $Module -Force -WarningAction SilentlyContinue
$r = Invoke-TcLintProject -PlcProjectPath $Plcproj
$j = $r | ConvertTo-Json -Depth 30 -Compress
[System.IO.File]::WriteAllText($Out, ([System.Threading.Thread]::CurrentThread.CurrentUICulture.Name + "`n" + $j), (New-Object System.Text.UTF8Encoding($false)))
'@ | Set-Content -LiteralPath $helper -Encoding ASCII
$outs = @{}
foreach ($cul in 'en-US', 'zh-TW') {
    $o = Join-Path $root "culture-$cul.json"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Module (Resolve-Path $modulePath).ProviderPath -Plcproj $fxC.Plcproj -Culture $cul -Out $o | Out-Null
    $outs[$cul] = if (Test-Path $o) { [System.IO.File]::ReadAllText($o) } else { '' }
}
$en = $outs['en-US'] -split "`n", 2; $zh = $outs['zh-TW'] -split "`n", 2
Check 'D4 culture really differed in the two processes' ($en[0] -eq 'en-US' -and $zh[0] -eq 'zh-TW') "$($en[0]) / $($zh[0])"
Check 'D4 en-US and zh-TW output byte-identical (incl. engineDetail)' ($en.Count -eq 2 -and $en[1].Length -gt 100 -and $en[1] -ceq $zh[1] -and $en[1] -match 'engineDetail') ("en: $($en[1].Length) zh: $($zh[1].Length)")

# hash namespace: a changed .cs compiles to a new type in the same session (ReloadModule case)
$copy = Join-Path $root 'modcopy'
Copy-Item -LiteralPath (Split-Path (Resolve-Path $modulePath).ProviderPath) -Destination $copy -Recurse
Add-Content -LiteralPath (Join-Path $copy 'Private\Lint\LintCore.cs') -Value '// changed for the hash test'
$hashHelper = Join-Path $root 'hash-run.ps1'
@'
param([string]$Module, [string]$Copy, [string]$Plcproj)
Import-Module $Module -Force -WarningAction SilentlyContinue
$a = Invoke-TcLintProject -PlcProjectPath $Plcproj
Import-Module (Join-Path $Copy 'TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$b = Invoke-TcLintProject -PlcProjectPath $Plcproj
"$($a.success) $($a.data.engine.sourceHash) $($b.success) $($b.data.engine.sourceHash)"
'@ | Set-Content -LiteralPath $hashHelper -Encoding ASCII
$fxH = New-Fx
$h = (& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $hashHelper -Module (Resolve-Path $modulePath).ProviderPath -Copy $copy -Plcproj $fxH.Plcproj) -join ' '
$hp = $h -split ' '
Check 'D5 changed engine source -> new sourceHash, both engines work in one session' ($hp.Count -eq 4 -and $hp[0] -eq 'True' -and $hp[2] -eq 'True' -and $hp[1] -match '^[0-9a-f]{12}$' -and $hp[1] -ne $hp[3]) $h

# ================================================================ E  performance budget (200 objects)
$big = New-Fx
$items = [System.Collections.Generic.List[string]]::new()
foreach ($i in $script:LintFxCompile) { $items.Add($i) }
for ($i = 1; $i -le 194; $i++) {
    $name = 'FB_P{0:D3}' -f $i
    $id = '{' + [guid]::NewGuid().ToString() + '}'
    Write-LintFxFile (Join-Path $big.PlcDir "POUs\$name.TcPOU") (Get-LintFxPou -Name $name -Id $id -Decl "FUNCTION_BLOCK $name`nVAR`n    t : TON;`n    n : INT;`nEND_VAR`n" -Impl ("t(IN := n > 0, PT := T#1S);`nIF t.Q THEN`n    n := 0;`nELSE`n    n := n + 1;`nEND_IF`n" * 20))
    $items.Add("POUs\$name.TcPOU")
}
Set-LintFxCompile $big $items.ToArray()
$null = Invoke-TcLintProject -PlcProjectPath $big.Plcproj
$r = Invoke-TcLintProject -PlcProjectPath $big.Plcproj -IncludeTiming
Check 'E1 200 objects analysed in <= 2 s (engine already compiled)' ($r.data.coverage.objectsInScope -eq 200 -and $r.data.timing.analyzeMs -le 2000 -and -not $r.data.timing.engineCompiled) ("objects=$($r.data.coverage.objectsInScope) analyzeMs=$($r.data.timing.analyzeMs) code=$($r.error.code) $(@($r.data.diagnostics | Select-Object -First 3 | ForEach-Object { $_.message }) -join ' | ')")

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
