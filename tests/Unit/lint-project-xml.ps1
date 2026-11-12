# Unit: semantic linter (#252 Phase 1a) PROJECT-* / LINT-* rules on a synthetic project (no IDE).
# Fixture: tests/Unit/lib/LintFixture.ps1 (XAE file format as observed in the 4024 / 4026 corpus,
# research/tc-xml-schema-observed.md, 2026-11-13). Each case breaks ONE thing in a fresh copy and
# checks that exactly the expected rule ids fire (no extra finding), the verdict / error code and
# whether the finding blocks. blockable follows the IDE measurement of tasks 1a.7 (PR #276 table,
# verification/xae-corrupt-file-behavior.md, 2026-11-13); variants not measured keep blockableBasis =
# pending-measurement. The Property / .TcIO fixture shapes are the files XAE generated (xae-generated-xml.md).
#   powershell.exe -NoProfile -File tests/Unit/lint-project-xml.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\LintFixture.ps1')
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-lintxml-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$root = & (Get-Module TwinCATAutomation) { param($p) Get-TcLongPath $p } $root   # CI %TEMP% is an 8.3 short path (RUNNER~1); the engine reports long paths
$n = 0
function New-Case { $script:n++; return (New-LintFixture (Join-Path $root ("c{0:D2}" -f $script:n))) }
function Ids($r) { return @($r.data.diagnostics | ForEach-Object { $_.ruleId } | Sort-Object -Unique) }
function Diag($r, [string]$Rule) { return @($r.data.diagnostics | Where-Object { $_.ruleId -eq $Rule }) }

# Runs one mutation; $Expect = exact set of rule ids; $Code = expected error code ('' = success).
function Test-Case([string]$Name, [scriptblock]$Mutate, [string[]]$Expect, [string]$Code = 'LINT_FAILED', [scriptblock]$More = $null, [string[]]$LintArgs = @()) {
    $fx = New-Case
    & $Mutate $fx
    $r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
    $ids = Ids $r
    $want = @($Expect | Sort-Object -Unique)
    Check "$Name rules" ((($ids -join ',') -eq ($want -join ','))) ("got [{0}] want [{1}] {2}" -f ($ids -join ','), ($want -join ','), (($r.data.diagnostics | ForEach-Object { "$($_.ruleId)@$($_.objectPath):$($_.line) $($_.message)" }) -join ' | '))
    $gotCode = if ($r.success) { '' } else { $r.error.code }
    Check "$Name code" ($gotCode -eq $Code) "got '$gotCode' want '$Code' verdict=$($r.data.verdict)"
    if ($null -ne $More) { & $More $r $fx }

}

# ---------------------------------------------------------------- pristine (XAE format) = zero findings
$fx0 = New-Case
$r0 = Invoke-TcLintProject -PlcProjectPath $fx0.Plcproj
Check 'pristine (XAE format incl. Property and .TcIO): success, no diagnostics' ($r0.success -and @($r0.data.diagnostics).Count -eq 0 -and $r0.data.verdict -eq 'pass') (($r0.data.diagnostics | ForEach-Object { "$($_.ruleId) $($_.objectPath) $($_.message)" }) -join ' | ')
Check 'pristine: 6 objects analysed, solution + tsproj found, nothing skipped' ($r0.data.coverage.objectsAnalyzed -eq 6 -and $r0.data.source.solutionPath -eq $fx0.Sln -and @($r0.data.source.tsprojPaths)[0] -eq $fx0.Tsproj -and @($r0.data.coverage.rulesNotRun).Count -eq 0 -and @($r0.data.coverage.notAnalyzed).Count -eq 0) ($r0.data.coverage | ConvertTo-Json -Compress -Depth 4)

# blockable decided by the IDE measurement (PR #276 table, 2026-11-13): no blockableBasis any more
$hard = { param($r, $rule) $d = @(Diag $r $rule); Check "$rule blocking (measured, no pending basis)" ($d.Count -gt 0 -and @($d | Where-Object { -not $_.blocking -or $null -ne $_.blockableBasis }).Count -eq 0) ($d | ConvertTo-Json -Compress -Depth 3) }
$soft = { param($r, $rule) $d = @(Diag $r $rule); Check "$rule not blocking" ($d.Count -gt 0 -and @($d | Where-Object { $_.blocking }).Count -eq 0) ($d | ConvertTo-Json -Compress -Depth 3) }
$pending = { param($r, $rule) $d = @(Diag $r $rule); Check "$rule still pending (not measured)" ($d.Count -gt 0 -and @($d | Where-Object { $_.blockableBasis -ne 'pending-measurement' -or -not $_.blocking }).Count -eq 0) ($d | ConvertTo-Json -Compress -Depth 3) }

# ---------------------------------------------------------------- PROJECT-XML-*
Test-Case 'XML-001 not well-formed' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('</Method>', '') } } @('PROJECT-XML-001') 'LINT_FAILED' {
    param($r)
    $d = @(Diag $r 'PROJECT-XML-001')
    Check 'XML-001 blocking true' ($d.Count -eq 1 -and $d[0].blocking -and $null -eq $d[0].blockableBasis -and $d[0].file -eq 'POUs/FB_A.TcPOU') ($d | ConvertTo-Json -Compress)
    Check 'XML-001 file recorded as notAnalyzed, exception text only in engineDetail' (@($r.data.coverage.notAnalyzed | Where-Object { $_.reason -eq 'xml-not-well-formed' }).Count -eq 1 -and @($r.data.engineDetail).Count -eq 1 -and $d[0].message -notmatch 'Exception') ($r.data.engineDetail -join ' | ')
}
Test-Case 'XML-002 invalid UTF-8' { param($f)
    $b = [System.IO.File]::ReadAllBytes($f.Main); $i = [System.Text.Encoding]::ASCII.GetString($b).IndexOf('set mode'); $b[$i] = 0xC3; $b[$i + 1] = 0x28; [System.IO.File]::WriteAllBytes($f.Main, $b)
} @('PROJECT-XML-002') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-XML-002' }
Test-Case 'XML-002 UTF-16 BOM but encoding="utf-8" (nit): XML-002 only, not also XML-001' { param($f)
    $t = [System.IO.File]::ReadAllText($f.Gvl, [System.Text.Encoding]::UTF8)
    $u = New-Object System.Text.UnicodeEncoding($false, $true)
    [System.IO.File]::WriteAllBytes($f.Gvl, [byte[]]($u.GetPreamble() + $u.GetBytes($t)))
} @('PROJECT-XML-002', 'PROJECT-ENC-001') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-XML-002'); Check 'UTF-16 / utf-8 mismatch: blocking, fixHint says save as UTF-8' ($d[0].blocking -and $d[0].fixHint -match 'UTF-8') ($d | ConvertTo-Json -Compress)
}
Test-Case 'XML-002 no declaration, no BOM, non-ASCII: info only' { param($f) Write-LintFxFile $f.Dut ((Get-LintFxDutText).Replace('<?xml version="1.0" encoding="utf-8"?>' + "`n", '').Replace('Manual := 0,', 'Manual := 0, // 手動')) $false } @('PROJECT-XML-002', 'PROJECT-ENC-001') '' { param($r) & $soft $r 'PROJECT-XML-002' }
Test-Case 'XML-003 code outside CDATA but legal text: warning (XAE reads it, measured C02 / C05)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('<ST><![CDATA[fbA(bStart := GVL_Main.bRun);', '<ST>fbA(bStart := GVL_Main.bRun);<![CDATA[') } } @('PROJECT-XML-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-003'); Check 'XML-003 text-outside-cdata: warning, measured' ($d[0].variant -eq 'text-outside-cdata' -and -not $d[0].blocking -and $d[0].severity -eq 'warning' -and $null -eq $d[0].blockableBasis) ($d | ConvertTo-Json -Compress)
}
Test-Case 'XML-003 split CDATA (]]> in code) is what XAE writes: no finding, code joined' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("// set mode", "s := 'a]]]]><![CDATA[>b'; // set mode") } } @() ''
Test-Case 'B2 XML-003 escaped entity inside CDATA (&lt; written by an XML tool)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('IF fbA.M_Do(nValue := 1) THEN', 'IF fbA.M_Do(nValue := 1) AND 1 &lt; 2 THEN') } } @('PROJECT-XML-003') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-XML-003'); Check 'escaped-entity-in-cdata: error, blocking' ($d[0].variant -eq 'escaped-entity-in-cdata' -and $d[0].blocking -and $d[0].severity -eq 'error' -and $d[0].section -eq 'implementation') ($d | ConvertTo-Json -Compress)
}
Test-Case 'B2 &amp; in a comment or string is code text, not an entity finding' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('// set mode', "// R&amp;D note`r`n    sText := 'a &lt; b';") } } @() ''
Test-Case 'XML-004 missing SpecialFunc: warning (measured C08)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace(' SpecialFunc="None"', '') } } @('PROJECT-XML-004') '' { param($r) & $soft $r 'PROJECT-XML-004' }
Test-Case 'XML-004 missing Implementation' { param($f) Edit-LintFxFile $f.Main { param($t) $t -replace '(?s)    <Implementation>.*?</Implementation>\r\n', '' } } @('PROJECT-XML-004') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-XML-004' }
Test-Case 'XML-004 missing Name attribute' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t.Replace('<GVL Name="GVL_Main" ', '<GVL ') } } @('PROJECT-XML-004') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-XML-004' }
Test-Case 'XML-004 member order is a warning only' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $a = [regex]::Match($t, '(?s)    <Action .*?</Action>\r\n').Value; $m = [regex]::Match($t, '(?s)    <Method .*?</Method>\r\n').Value
        $t.Replace($a + $m, $m + $a) } } @('PROJECT-XML-004') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-004'); Check 'XML-004 order: warning, not blocking' ($d[0].variant -eq 'order' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'XML-004 unobserved ProductVersion downgrades' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('Version="1.1.0.1" ProductVersion="3.1.4026.18"', 'ProductVersion="3.1.4028.1"') } } @('PROJECT-XML-004') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-004'); Check 'XML-004 on 4028 file is a warning + rulesSkipped' ($d[0].severity -eq 'warning' -and -not $d[0].blocking -and @($r.data.coverage.rulesSkipped | Where-Object { $_.reason -eq 'unobserved-product-version' }).Count -eq 1) ($d | ConvertTo-Json -Compress)
}
Test-Case 'should-fix 1: Compile with Condition -> XML-004 unobserved-msbuild' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('<Compile Include="PlcTask.TcTTO">', '<Compile Include="PlcTask.TcTTO" Condition="''$(Configuration)'' == ''Debug''">') } } @('PROJECT-XML-004') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-XML-004'); Check 'unobserved-msbuild blocks (pending)' ($d[0].variant -eq 'unobserved-msbuild' -and $d[0].blocking -and $d[0].blockableBasis -eq 'pending-measurement') ($d | ConvertTo-Json -Compress)
}
Test-Case 'should-fix 1: <Import> in the .plcproj' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('  <ProjectExtensions>', "  <Import Project=`"x.targets`" />`r`n  <ProjectExtensions>") } } @('PROJECT-XML-004') 'LINT_FAILED'
Test-Case 'should-fix 1: wildcard Include' { param($f) Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\*.TcPOU', 'POUs\I_Run.TcIO') } @('PROJECT-XML-004') 'LINT_FAILED'
Test-Case 'should-fix 1: Compile Remove' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('<Compile Include="PlcTask.TcTTO">', '<Compile Remove="POUs\MAIN.TcPOU" />' + "`r`n    " + '<Compile Include="PlcTask.TcTTO">') } } @('PROJECT-XML-004') 'LINT_FAILED'

# ---------------------------------------------------------------- KIND / NAME
Test-Case 'KIND-001 POU element in a .TcDUT: element vs declaration blocks, extension only warns' { param($f) Edit-LintFxFile $f.Dut { param($t) $t.Replace('<DUT ', '<POU SpecialFunc="None" ').Replace('</DUT>', '<Implementation><ST><![CDATA[]]></ST></Implementation></POU>') } } @('PROJECT-KIND-001') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-KIND-001')
    Check 'KIND-001: extension variant warning + declaration-family error' ($d.Count -eq 2 -and @($d | Where-Object { $_.variant -eq 'extension' -and -not $_.blocking }).Count -eq 1 -and @($d | Where-Object { $_.variant -eq 'declaration' -and $_.blocking }).Count -eq 1) ($d | ConvertTo-Json -Compress)
}
Test-Case 'KIND-001 extension only (POU in a .TcDUT file name): warning (measured C13)' { param($f)
    Move-Item $f.Main (Join-Path $f.PlcDir 'POUs\MAIN.TcDUT'); Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'POUs\I_Run.TcIO', 'POUs\MAIN.TcDUT') } @('PROJECT-KIND-001') '' { param($r) & $soft $r 'PROJECT-KIND-001' }
Test-Case 'KIND-001 PROGRAM vs FUNCTION_BLOCK in a POU is not checked (measured C15)' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('FUNCTION_BLOCK FB_A', 'PROGRAM FB_A') } } @() ''
Test-Case 'KIND-001 GVL declared as plain VAR' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t.Replace('VAR_GLOBAL', 'VAR') } } @('PROJECT-KIND-001') 'LINT_FAILED'
Test-Case 'NAME-001 declared name differs' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('PROGRAM MAIN', 'PROGRAM MAIN2') } } @('PROJECT-NAME-001') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-NAME-001' }
Test-Case 'NAME-001 is case-insensitive (no finding)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('PROGRAM MAIN', 'PROGRAM Main') } } @() ''
Test-Case 'NAME-001 method declaration' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('METHOD M_Do : BOOL', 'METHOD M_Run : BOOL') } } @('PROJECT-NAME-001') 'LINT_FAILED'
Test-Case 'NAME-001 property declaration' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('PROPERTY PUBLIC P_State : INT', 'PROPERTY PUBLIC P_Other : INT') } } @('PROJECT-NAME-001') 'LINT_FAILED'
Test-Case 'NAME-002 file name differs (warning)' { param($f)
    Move-Item $f.FbA (Join-Path $f.PlcDir 'POUs\FB_Old.TcPOU'); Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_Old.TcPOU', 'POUs\I_Run.TcIO', 'POUs\MAIN.TcPOU') } @('PROJECT-NAME-002') '' { param($r) & $soft $r 'PROJECT-NAME-002' }

# ---------------------------------------------------------------- GUID
Test-Case 'GUID-001 missing Id: warning (XAE loads and warns)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace(" Id=`"$($script:LintFx.MainId)`"", '') } } @('PROJECT-GUID-001') '' { param($r) & $soft $r 'PROJECT-GUID-001' }
Test-Case 'GUID-002 malformed Id' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace($script:LintFx.FbAMethod, '{bca2ddc8-99fd-474f-8c18-1873e77b9b3}') } } @('PROJECT-GUID-002') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-GUID-002' }
Test-Case 'GUID-003 copied file keeps its Ids: cross-file = warning (XAE renumbers one)' { param($f)
    $copy = Join-Path $f.PlcDir 'POUs\FB_B.TcPOU'
    Write-LintFxFile $copy ((Get-LintFxFbAText).Replace('"FB_A"', '"FB_B"').Replace('FUNCTION_BLOCK FB_A', 'FUNCTION_BLOCK FB_B').Replace('Name="FB_A.', 'Name="FB_B.'))
    Set-LintFxCompile $f ($script:LintFxCompile + 'POUs\FB_B.TcPOU') } @('PROJECT-GUID-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-GUID-003')
    Check 'GUID-003 reported for the 6 Ids (POU, Action, Method, Property, Get, Set) of both files, all cross-file' ($d.Count -eq 12 -and @($d | Where-Object { $_.variant -ne 'cross-file' -or $_.blocking }).Count -eq 0) (($d | ForEach-Object { "$($_.objectPath) $($_.variant)" }) -join ' | ')
}
Test-Case 'GUID-003 two sub-objects of one POU share an Id: blocking (XAE drops the POU)' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace($script:LintFx.FbAMethod, $script:LintFx.FbAProp) } } @('PROJECT-GUID-003') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-GUID-003'); Check 'same-object variant blocking' ($d.Count -eq 2 -and @($d | Where-Object { $_.variant -ne 'same-object' -or -not $_.blocking }).Count -eq 0) ($d | ConvertTo-Json -Compress)
}
Test-Case 'GUID-004 zero Id: info (XAE regenerates it)' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t.Replace($script:LintFx.GvlId, '{00000000-0000-0000-0000-000000000000}') } } @('PROJECT-GUID-004') '' {
    param($r) $d = @(Diag $r 'PROJECT-GUID-004'); Check 'GUID-004 info' ($d[0].severity -eq 'info' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'GUID-005 hand-written Id (warning)' { param($f) Edit-LintFxFile $f.Dut { param($t) $t.Replace($script:LintFx.DutId, '{a1b2c3d4-e5f6-7890-abcd-ef0123456789}') } } @('PROJECT-GUID-005') '' {
    param($r) $d = @(Diag $r 'PROJECT-GUID-005'); Check 'GUID-005 warning, medium, not blocking' ($d[0].severity -eq 'warning' -and $d[0].confidence -eq 'medium' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- SUB / LINEIDS (Property / Interface observed in XAE files, B1)
Test-Case 'SUB-001 method without Declaration' { param($f) Edit-LintFxFile $f.FbA { param($t) $t -replace '(?s)(<Method [^>]*>\r\n)      <Declaration>.*?</Declaration>\r\n', '$1' } } @('PROJECT-SUB-001') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-SUB-001' }
Test-Case 'SUB-001 interface method without Declaration' { param($f) Edit-LintFxFile $f.Itf { param($t) $t -replace '(?s)(<Method [^>]*>\r\n)      <Declaration>.*?</Declaration>\r\n', '$1' } } @('PROJECT-SUB-001') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-SUB-001' }
Test-Case 'SUB-001 property without Get and Set: warning (compiler warns C0373)' { param($f) Edit-LintFxFile $f.FbA { param($t) $t -replace '(?s)      <Get .*?</Set>\r\n', '' -replace '(?s)    <LineIds Name="FB_A\.P_State\.(Get|Set)">.*?</LineIds>\r\n', '' } } @('PROJECT-SUB-001') '' { param($r) & $soft $r 'PROJECT-SUB-001' }
Test-Case 'should-fix 6: ABSTRACT method without Implementation -> not observed, no finding' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('METHOD M_Do : BOOL', 'METHOD ABSTRACT M_Do : BOOL') -replace '(?s)(<Method [^>]*>\r\n      <Declaration>.*?</Declaration>\r\n)      <Implementation>.*?</Implementation>\r\n', '$1' -replace '(?s)    <LineIds Name="FB_A\.M_Do">.*?</LineIds>\r\n', '' } } @() '' {
    param($r) Check 'ABSTRACT method -> rulesNotRun SUB-001 schema-not-observed' (@($r.data.coverage.rulesNotRun | Where-Object { $_.ruleId -eq 'PROJECT-SUB-001' -and $_.objectPath -eq 'FB_A.M_Do' }).Count -eq 1) ($r.data.coverage.rulesNotRun | ConvertTo-Json -Compress)
}
Test-Case 'B1 broken code in a Property Get is checked (LINT-PARSE-002)' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('<ST><![CDATA[P_State := nState;]]></ST>', '<ST><![CDATA[IF nState > 0 THEN P_State := nState;]]></ST>') } } @('LINT-PARSE-002') 'LINT_PARSE_FAILED' {
    param($r) $d = @(Diag $r 'LINT-PARSE-002'); Check 'finding on FB_A.P_State.Get' ($d[0].objectPath -eq 'FB_A.P_State.Get') ($d | ConvertTo-Json -Compress)
}
Test-Case 'B1 Property Set declaration outside CDATA is checked (XML-003)' { param($f) Edit-LintFxFile $f.FbA { param($t) $i = $t.IndexOf('<Set '); $t.Substring(0, $i) + $t.Substring($i).Replace('<Declaration><![CDATA[PUBLIC', '<Declaration>PUBLIC<![CDATA[') } } @('PROJECT-XML-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-003'); Check 'finding on FB_A.P_State.Set' ($d[0].objectPath -eq 'FB_A.P_State.Set') ($d | ConvertTo-Json -Compress)
}
Test-Case 'B1 broken code in a Transition (structure not observed) is still checked' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('    <LineIds Name="FB_A">', "    <Transition Name=`"T_Go`" Id=`"{8f04bada-e03b-49d3-990e-da6b67b3912c}`">`r`n      <Implementation>`r`n        <ST><![CDATA[IF bStart THEN]]></ST>`r`n      </Implementation>`r`n    </Transition>`r`n    <LineIds Name=`"FB_A`">") } } @('LINT-PARSE-002') 'LINT_PARSE_FAILED' {
    param($r) Check 'Transition: XML-004 / SUB-001 in rulesNotRun only' (@($r.data.coverage.rulesNotRun | Where-Object { $_.objectPath -eq 'FB_A.T_Go' }).Count -eq 2) ($r.data.coverage.rulesNotRun | ConvertTo-Json -Compress)
}
Test-Case 'SUB-002 two methods with one name' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $m = [regex]::Match($t, '(?s)    <Method .*?</Method>\r\n').Value
        $t.Replace($m, $m + $m.Replace($script:LintFx.FbAMethod, '{3abfd75b-1e61-4bea-9f5b-12954f0b7f61}').Replace('M_Do"', 'm_do"').Replace('METHOD M_Do', 'METHOD m_do')) } } @('PROJECT-SUB-002') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-SUB-002' }
Test-Case 'LINEIDS-001 count differs (info)' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('<LineId Id="3" Count="3" />', '<LineId Id="3" Count="4" />') } } @('PROJECT-LINEIDS-001') '' {
    param($r) $d = @(Diag $r 'PROJECT-LINEIDS-001'); Check 'LINEIDS-001 info, not blocking' ($d[0].severity -eq 'info' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'LINEIDS-001 member added without LineIds' { param($f) Edit-LintFxFile $f.FbA { param($t) $t -replace '(?s)    <LineIds Name="FB_A.M_Do">.*?</LineIds>\r\n', '' } } @('PROJECT-LINEIDS-001') ''

# ---------------------------------------------------------------- COMPILE
Test-Case 'COMPILE-001 missing file' { param($f) Set-LintFxCompile $f ($script:LintFxCompile + 'POUs\FB_Gone.TcPOU') } @('PROJECT-COMPILE-001') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-COMPILE-001' }
Test-Case 'COMPILE-002 duplicate (normalised path): warning' { param($f) Set-LintFxCompile $f ($script:LintFxCompile + '.\POUs\MAIN.TcPOU') } @('PROJECT-COMPILE-002') '' { param($r) & $soft $r 'PROJECT-COMPILE-002' }
Test-Case 'COMPILE-003 object file not compiled (warning)' { param($f) Write-LintFxFile (Join-Path $f.PlcDir 'POUs\FB_Orphan.TcPOU') ((Get-LintFxFbAText).Replace('FB_A', 'FB_Orphan')) } @('PROJECT-COMPILE-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-COMPILE-003')
    Check 'COMPILE-003 warning, not blocking, unresolved (behavior)' ($d[0].severity -eq 'warning' -and -not $d[0].blocking -and @($r.data.unresolved).Count -eq 1 -and $r.data.requiresDisposition) ($r.data.unresolved | ConvertTo-Json -Compress)
}
Test-Case 'COMPILE-004 SubType: warning' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace("<Compile Include=`"PlcTask.TcTTO`">`r`n      <SubType>Code</SubType>", "<Compile Include=`"PlcTask.TcTTO`">`r`n      <SubType>Content</SubType>") } } @('PROJECT-COMPILE-004') '' { param($r) & $soft $r 'PROJECT-COMPILE-004' }
Test-Case 'COMPILE-005 directory without Folder item (info)' { param($f)
    New-Item -ItemType Directory -Path (Join-Path $f.PlcDir 'Extra') | Out-Null; Move-Item $f.Gvl (Join-Path $f.PlcDir 'Extra\GVL_Main.TcGVL')
    Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'Extra\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'POUs\I_Run.TcIO', 'POUs\MAIN.TcPOU') } @('PROJECT-COMPILE-005') ''
Test-Case 'COMPILE-006 case differs from disk: warning' { param($f) Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'POUs\I_Run.TcIO', 'pous\Main.TcPOU') } @('PROJECT-COMPILE-006') '' { param($r) & $soft $r 'PROJECT-COMPILE-006' }
Test-Case 'COMPILE-006 % not escaped: warning' { param($f)
    Move-Item $f.Gvl (Join-Path $f.PlcDir 'GVLs\GVL_Main%41.TcGVL')
    Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main%41.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'POUs\I_Run.TcIO', 'POUs\MAIN.TcPOU') } @('PROJECT-COMPILE-006', 'PROJECT-NAME-002') ''
Test-Case 'nit: Compile Include outside the project -> outside-project, the file is not read' { param($f)
    Write-LintFxFile (Join-Path $f.Root 'Outside\FB_Out.TcPOU') 'this is <not xml'
    Set-LintFxCompile $f ($script:LintFxCompile + '..\..\..\Outside\FB_Out.TcPOU') } @('PROJECT-COMPILE-006') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-COMPILE-006'); Check 'outside-project variant, pending' ($d[0].variant -eq 'outside-project' -and $d[0].blockableBasis -eq 'pending-measurement') ($d | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- LIB / TSPROJ
Test-Case 'LIB-001 placeholder without DefaultResolution: warning' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t -replace '\s*<DefaultResolution>Tc2_Standard[^<]*</DefaultResolution>', '' } } @('PROJECT-LIB-001') '' { param($r) & $soft $r 'PROJECT-LIB-001' }
Test-Case 'LIB-001 placeholder without Namespace: not reported (XAE wrote such a reference in the 4024 corpus)' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t -replace '\s*<Namespace>Tc2_Standard</Namespace>', '' } } @() ''
Test-Case 'TSPROJ-001 PrjFilePath wrong' { param($f) Write-LintFxFile $f.Tsproj (Get-LintFxTsprojText -PrjFilePath 'PLC1\PLC2.plcproj') $false } @('PROJECT-TSPROJ-001') 'LINT_FAILED' { param($r) & $hard $r 'PROJECT-TSPROJ-001' }
Test-Case 'TSPROJ-002 GUID differs: warning (XAE writes the .tsproj value back)' { param($f) Write-LintFxFile $f.Plcproj (Get-LintFxPlcprojText $script:LintFxCompile -Guid '{a497c097-793a-4804-aa80-6a57816cc79d}') $false } @('PROJECT-TSPROJ-002') '' {
    param($r) $d = @(Diag $r 'PROJECT-TSPROJ-002'); Check 'TSPROJ-002 for the .tsproj and the .sln, not blocking' ($d.Count -eq 2 -and @($d | Where-Object { $_.blocking }).Count -eq 0) (($d | ForEach-Object { "$($_.file): $($_.message)" }) -join ' | ')
}
Test-Case 'TSPROJ-002 upper / lower case GUID is the same (no finding)' { param($f) Write-LintFxFile $f.Tsproj (Get-LintFxTsprojText -Guid $script:LintFx.PlcGuid) $false } @() ''
Test-Case 'TSPROJ-003 PouCall names no POU: warning, compiler catches it (not unresolved)' { param($f) Write-LintFxFile $f.Task (Get-LintFxTaskText -PouCall 'MAIN_X') } @('PROJECT-TSPROJ-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-TSPROJ-003'); Check 'PouCall: not blocking, not in unresolved' (-not $d[0].blocking -and @($r.data.unresolved).Count -eq 0) ($d | ConvertTo-Json -Compress)
}
Test-Case 'TSPROJ-003 PouCall names a FUNCTION_BLOCK' { param($f) Write-LintFxFile $f.Task (Get-LintFxTaskText -PouCall 'FB_A') } @('PROJECT-TSPROJ-003') ''
Test-Case 'TSPROJ-003 task context missing (still pending)' { param($f) Write-LintFxFile $f.Tsproj (Get-LintFxTsprojText -ContextName 'OtherTask') $false } @('PROJECT-TSPROJ-003') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-TSPROJ-003' }
Test-Case 'XML-004 task without PouCall is a warning only' { param($f) Edit-LintFxFile $f.Task { param($t) $t -replace '(?s)    <PouCall>.*?</PouCall>\r\n', '' } } @('PROJECT-XML-004') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-004'); Check 'missing PouCall: warning, not blocking' ($d[0].variant -eq 'missing-pou-call' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'GVL starting with VAR_CONFIG is not a KIND finding' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t.Replace('{attribute ''qualified_only''}' + "`r`n" + 'VAR_GLOBAL', "VAR_CONFIG`r`n    MAIN.fbA.bStart AT %IX0.0 : BOOL;`r`nEND_VAR`r`nVAR_GLOBAL") } } @() ''
Test-Case 'nit: GVL with only an attribute (no VAR_GLOBAL): warning, not blocking' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t -replace '(?s)VAR_GLOBAL.*?END_VAR', '' } } @('PROJECT-KIND-001') '' {
    param($r) $d = @(Diag $r 'PROJECT-KIND-001'); Check 'empty-gvl variant warning' ($d[0].variant -eq 'empty-gvl' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'PLC as independent project file (.xti): TSPROJ rules skipped -> incomplete, not a finding' { param($f) Edit-LintFxFile $f.Tsproj { param($t) $t.Replace('PrjFilePath="PLC1\PLC1.plcproj"', 'File="PLC1.xti"') } } @() 'LINT_INCOMPLETE' {
    param($r) Check 'independent file -> TSPROJ-001 (blocking rule) in blockingRulesSkipped, 002 / 003 in rulesSkipped' (@($r.data.coverage.blockingRulesSkipped | Where-Object { $_.reason -eq 'independent-project-file-not-observed' }).Count -ge 1 -and (@($r.data.coverage.blockingRulesSkipped) + @($r.data.coverage.rulesSkipped) | Where-Object { $_.reason -eq 'independent-project-file-not-observed' }).Count -eq 3) ($r.data.coverage | ConvertTo-Json -Compress -Depth 4)
}
Test-Case 'should-fix 9: stand-alone PLC project (.sln references the .plcproj, no .tsproj) -> TSPROJ in rulesSkipped, pass' { param($f)
    Remove-Item -LiteralPath $f.Tsproj
    Edit-LintFxFile $f.Sln { param($t) $t.Replace('"Sol\Sol.tsproj"', '"Sol\PLC1\PLC1.plcproj"') } } @() '' {
    param($r) Check 'standalone-plc-project in rulesSkipped for TSPROJ-001..003' (@($r.data.coverage.rulesSkipped | Where-Object { $_.reason -eq 'standalone-plc-project' }).Count -eq 3) ($r.data.coverage | ConvertTo-Json -Compress -Depth 4)
}
Test-Case 'TSPROJ-003 priority differs (warning)' { param($f) Write-LintFxFile $f.Task (Get-LintFxTaskText -Priority '21') } @('PROJECT-TSPROJ-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-TSPROJ-003'); Check 'TSPROJ-003 priority: warning, not blocking' ($d[0].variant -eq 'priority-mismatch' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- ENC
Test-Case 'ENC-001 LF line ends, no BOM (info)' { param($f) Write-LintFxFile $f.Dut (Get-LintFxDutText) $false "`n" } @('PROJECT-ENC-001') '' {
    param($r) $d = @(Diag $r 'PROJECT-ENC-001'); Check 'ENC-001 info, mentions BOM and LF, no claim about who wrote it' ($d[0].severity -eq 'info' -and $d[0].message -match 'byte order mark' -and $d[0].message -match 'LF-only' -and $d[0].message -notmatch 'written outside') $d[0].message
}
Test-Case 'ENC-001 mixed line ends' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("set mode`r`n", "set mode`n") } } @('PROJECT-ENC-001') ''

# ---------------------------------------------------------------- LINT-PARSE / LINT-XML / unknown characters (B2)
Test-Case 'LINT-PARSE-002 missing END_IF' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("`r`nEND_IF]]>", ']]>') } } @('LINT-PARSE-002') 'LINT_PARSE_FAILED' {
    param($r) $d = @(Diag $r 'LINT-PARSE-002'); Check 'LINT-PARSE-002 points at the open IF in MAIN' ($d[0].objectPath -eq 'MAIN' -and $d[0].section -eq 'implementation' -and $d[0].line -eq 2 -and $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'LINT-PARSE-003 VAR without END_VAR' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace("    nState : INT;`r`nEND_VAR", "    nState : INT;") } } @('LINT-PARSE-003') 'LINT_PARSE_FAILED'
Test-Case 'LINT-PARSE-001 unterminated string' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('eMode := E_Mode.Auto;', "eMode := 'open;") } } @('LINT-PARSE-001') 'LINT_PARSE_FAILED'
Test-Case 'B2 backtick in code -> LINT-PARSE-001' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('eMode := E_Mode.Auto;', 'eMode := ``E_Mode.Auto``;') } } @('LINT-PARSE-001') 'LINT_PARSE_FAILED'
Test-Case 'B2 typographic quote in code -> LINT-PARSE-001' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('eMode := E_Mode.Auto;', ('sText := ' + [char]0x2018 + 'x' + [char]0x2019 + ';')) } } @('LINT-PARSE-001') 'LINT_PARSE_FAILED'
Test-Case 'B2 other unknown character in code -> incomplete, never pass' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('eMode := E_Mode.Auto;', 'eMode := E_Mode.Auto @ 1;') } } @() 'LINT_INCOMPLETE' {
    param($r) Check 'unknown char -> blockingRulesSkipped LINT-PARSE for MAIN' (@($r.data.coverage.blockingRulesSkipped | Where-Object { $_.objectPath -eq 'MAIN' -and $_.reason -like 'unsupported-syntax:char-U+0040*' }).Count -eq 1) ($r.data.coverage | ConvertTo-Json -Compress -Depth 4)
}
Test-Case 'B2 unsupported declaration (missing semicolon) -> incomplete, never pass' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('    nState : INT;', '    nState : INT') } } @() 'LINT_INCOMPLETE'
Test-Case 'parse failure keeps the other findings' { param($f)
    Edit-LintFxFile $f.Main { param($t) $t.Replace("`r`nEND_IF]]>", ']]>') }
    Edit-LintFxFile $f.Gvl { param($t) $t.Replace($script:LintFx.GvlId, '{00000000-0000-0000-0000-000000000000}') } } @('LINT-PARSE-002', 'PROJECT-GUID-004') 'LINT_PARSE_FAILED'
Test-Case 'conditional pragma: not analysed, pass, recorded in rulesSkipped and summary (decision 2026-11-13)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('IF fbA.M_Do(nValue := 1) THEN', "{IF defined (SIMULATION)}`r`nIF bSim THEN`r`n{ELSE}`r`nIF fbA.M_Do(nValue := 1) THEN`r`n{END_IF}") } } @() '' {
    param($r) Check 'conditional pragma -> notAnalyzed + rulesSkipped LINT-PARSE + summary.notAnalyzed' (@($r.data.coverage.notAnalyzed | Where-Object { $_.objectPath -eq 'MAIN' -and $_.reason -eq 'conditional-pragma' }).Count -eq 1 -and @($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -like 'LINT-PARSE-*' -and $_.reason -eq 'conditional-pragma' }).Count -eq 1 -and $r.data.summary.notAnalyzed -eq 1) (($r.data.coverage | ConvertTo-Json -Compress -Depth 4) + ($r.data.summary | ConvertTo-Json -Compress))
}
Test-Case 'conditional pragma before the header -> KIND / NAME skipped -> incomplete' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('<Declaration><![CDATA[PROGRAM MAIN', "<Declaration><![CDATA[{IF defined (X)}`r`nPROGRAM MAIN`r`n{END_IF}") } } @() 'LINT_INCOMPLETE' {
    param($r) $s = @($r.data.coverage.blockingRulesSkipped | ForEach-Object { $_.ruleId } | Sort-Object)
    Check 'blockingRulesSkipped KIND-001 + NAME-001 for MAIN' (($s -join ',') -eq 'PROJECT-KIND-001,PROJECT-NAME-001' -and -not $r.data.passed) ($r.data.coverage.blockingRulesSkipped | ConvertTo-Json -Compress)
}
Test-Case 'LINT-XML-002 two ST elements' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("END_IF]]></ST>", "END_IF]]></ST>`r`n      <ST><![CDATA[x := 1;]]></ST>") } } @('LINT-XML-002') '' {
    param($r) $d = @(Diag $r 'LINT-XML-002'); Check 'LINT-XML-002 lineUnreliable' ($d[0].lineUnreliable -eq $true) ($d | ConvertTo-Json -Compress)
}
Test-Case 'CFC action: notAnalyzed language:CFC, PROJECT rules still run' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $t.Replace("<ST><![CDATA[nState := 0;]]></ST>", "<CFC PageOriented=`"true`">`r`n          <XmlArchive>`r`n            <Data><o xml:space=`"preserve`" t=`"CFC`" /></Data>`r`n          </XmlArchive>`r`n        </CFC>").Replace("    <LineIds Name=`"FB_A.A_Reset`">`r`n      <LineId Id=`"1`" Count=`"0`" />`r`n    </LineIds>`r`n", '').Replace($script:LintFx.FbAAction, '{bca2ddc8-99fd-474f-8c18-1873e77b9b3}') } } @('PROJECT-GUID-002') 'LINT_FAILED' {
    param($r) Check 'CFC -> notAnalyzed language:CFC (not incomplete)' (@($r.data.coverage.notAnalyzed | Where-Object { $_.objectPath -eq 'FB_A.A_Reset' -and $_.reason -eq 'language:CFC' }).Count -eq 1) ($r.data.coverage | ConvertTo-Json -Compress -Depth 4)
}
Test-Case 'SFC action with ObjectProperties (as XAE writes it) is accepted' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $t.Replace("<ST><![CDATA[nState := 0;]]></ST>`r`n      </Implementation>", "<SFC>`r`n          <XmlArchive>`r`n            <Data><o xml:space=`"preserve`" t=`"SFCImplementationObject`" /></Data>`r`n          </XmlArchive>`r`n        </SFC>`r`n      </Implementation>`r`n      <ObjectProperties>`r`n        <XmlArchive>`r`n          <Data><o xml:space=`"preserve`" t=`"SFCProperty`" /></Data>`r`n        </XmlArchive>`r`n      </ObjectProperties>").Replace("    <LineIds Name=`"FB_A.A_Reset`">`r`n      <LineId Id=`"1`" Count=`"0`" />`r`n    </LineIds>`r`n", '') } } @() ''

# ---------------------------------------------------------------- verification reviewer round 2 (R1 - R7), all must not pass
Test-Case 'R1 unknown object element in a .TcPOU: blocking, not counted as analysed' { param($f) Write-LintFxFile $f.Main ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <Foo Name=`"MAIN`" Id=`"$($script:LintFx.MainId)`" />`n</TcPlcObject>") } @('PROJECT-KIND-001', 'PROJECT-XML-004') 'LINT_FAILED' {
    param($r) Check 'R1: object not analysed, no TSPROJ-003 claim about MAIN' ($r.data.coverage.objectsAnalyzed -eq 5 -and @($r.data.coverage.notAnalyzed | Where-Object { $_.reason -eq 'unknown-object-element' }).Count -eq 1 -and @($r.data.diagnostics | Where-Object { $_.ruleId -eq 'PROJECT-TSPROJ-003' }).Count -eq 0) ($r.data.coverage | ConvertTo-Json -Compress -Depth 4)
}
Test-Case 'R2 Transition with ST directly below it is parsed' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('    <LineIds Name="FB_A">', "    <Transition Name=`"T_Go`" Id=`"{8f04bada-e03b-49d3-990e-da6b67b3912c}`">`r`n      <ST><![CDATA[IF bStart THEN]]></ST>`r`n    </Transition>`r`n    <LineIds Name=`"FB_A`">") } } @('LINT-PARSE-002') 'LINT_PARSE_FAILED'
Test-Case 'R2 empty Transition (structure not observed): incomplete' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('    <LineIds Name="FB_A">', "    <Transition Name=`"T_Go`" Id=`"{8f04bada-e03b-49d3-990e-da6b67b3912c}`" />`r`n    <LineIds Name=`"FB_A`">") } } @() 'LINT_INCOMPLETE'
Test-Case 'R3 unknown implementation language element: incomplete' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('<ST><![CDATA[M_Do := nValue > 0;]]></ST>', '<Foo><ST><![CDATA[IF x THEN]]></ST></Foo>') -replace '(?s)    <LineIds Name="FB_A\.M_Do">.*?</LineIds>\r\n', '' } } @() 'LINT_INCOMPLETE'
Test-Case 'R5 Compile Exclude: unobserved-msbuild' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('<Compile Include="POUs\MAIN.TcPOU">', '<Compile Include="POUs\MAIN.TcPOU" Exclude="POUs\MAIN.TcPOU">') } } @('PROJECT-XML-004') 'LINT_FAILED'
Test-Case 'R5 Include with %(metadata): unobserved-msbuild' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('<Compile Include="POUs\MAIN.TcPOU">', '<Compile Include="%(Foo.Bar)">') } } @('PROJECT-XML-004') 'LINT_FAILED'
Test-Case 'R5 Project Sdk attribute: unobserved-msbuild' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('<Project DefaultTargets="Build"', '<Project Sdk="Microsoft.NET.Sdk" DefaultTargets="Build"') } } @('PROJECT-XML-004') 'LINT_FAILED'
Test-Case 'R5 PropertyGroup / SubType with Condition: unobserved-msbuild' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('  <PropertyGroup>', '  <PropertyGroup Condition="false">') } } @('PROJECT-XML-004') 'LINT_FAILED'
Test-Case 'R6 ENUM member value with a missing comma: incomplete' { param($f) Edit-LintFxFile $f.Dut { param($t) $t.Replace('Manual := 0,', 'Manual := 0 Bad,') } } @() 'LINT_INCOMPLETE'
Test-Case 'R6 STRUCT member type broken (missing ; and :): incomplete' { param($f) Write-LintFxFile $f.Dut ((Get-LintFxDutText) -replace '(?s)TYPE E_Mode :.*END_TYPE', "TYPE E_Mode :`nSTRUCT`n    a : INT`n    b BOOL;`nEND_STRUCT`nEND_TYPE") } @() 'LINT_INCOMPLETE'
Test-Case 'R7 U+FEFF inside code: incomplete' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('eMode := E_Mode.Auto;', ('eMode := E_Mode' + [char]0xFEFF + '.Auto;')) } } @() 'LINT_INCOMPLETE'
Test-Case 'nit .tsproj over maxFileSizeMB: incomplete' { param($f)
    Edit-LintFxFile $f.Tsproj { param($t) $t.Replace('<Name>PlcTask</Name>' + "`r`n`t`t`t`t</Task>", '<Name>PlcTask</Name>' + "`r`n`t`t`t`t<!--" + ('x' * 1200000) + "-->`r`n`t`t`t`t</Task>") }
    $dir = Join-Path ([System.IO.Path]::GetDirectoryName($f.Sln)) '.tcauto'; New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'lint-profile.json'), '{"schema":"tcauto-lint-profile/1","maxFileSizeMB":1}') } @() 'LINT_INCOMPLETE'

# ---------------------------------------------------------------- the .plcproj itself, other files
Test-Case '.plcproj not well-formed -> LINT_PARSE_FAILED' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('</ProjectGuid>', '</ProjectGuidX>') } } @('PROJECT-XML-001') 'LINT_PARSE_FAILED'
Test-Case 'XXE / DTD in a .TcPOU is refused, never resolved' { param($f)
    $secret = Join-Path $f.Root 'secret.txt'; Set-Content -LiteralPath $secret -Value 'TOPSECRET' -Encoding ASCII
    Edit-LintFxFile $f.Main { param($t) $t.Replace("<?xml version=`"1.0`" encoding=`"utf-8`"?>", "<?xml version=`"1.0`" encoding=`"utf-8`"?>`r`n<!DOCTYPE TcPlcObject [ <!ENTITY x SYSTEM `"file:///$($secret.Replace('\','/'))`"> ]>").Replace('// set mode', '// &x;') } } @('PROJECT-XML-001') 'LINT_FAILED' {
    param($r) Check 'XXE: the entity text never appears in the output' ((($r | ConvertTo-Json -Depth 20) -notmatch 'TOPSECRET')) 'secret leaked'
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
