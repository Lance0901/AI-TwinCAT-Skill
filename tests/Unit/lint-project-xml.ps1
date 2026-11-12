# Unit: semantic linter (#252 Phase 1a) PROJECT-* / LINT-* rules on a synthetic project (no IDE).
# Fixture: tests/Unit/lib/LintFixture.ps1 (XAE file format as observed in the 4024 / 4026 corpus,
# research/tc-xml-schema-observed.md, 2026-11-13). Each case breaks ONE thing in a fresh copy and
# checks that exactly the expected rule ids fire (no extra finding), the verdict / error code and,
# for blockable "pending" rules, blockableBasis = pending-measurement. Whether XAE itself rejects
# these files is NOT tested here (that is the IDE measurement, tasks 1a.7).
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
Check 'pristine: success, no diagnostics' ($r0.success -and @($r0.data.diagnostics).Count -eq 0 -and $r0.data.verdict -eq 'pass') (($r0.data.diagnostics | ForEach-Object { "$($_.ruleId) $($_.message)" }) -join ' | ')
Check 'pristine: 5 objects analysed, solution + tsproj found' ($r0.data.coverage.objectsAnalyzed -eq 5 -and $r0.data.source.solutionPath -eq $fx0.Sln -and @($r0.data.source.tsprojPaths)[0] -eq $fx0.Tsproj) ($r0.data.source | ConvertTo-Json -Compress)

$pending = { param($r, $rule) $d = Diag $r $rule; Check "$rule blockableBasis pending" ($d.Count -gt 0 -and @($d | Where-Object { $_.blockableBasis -ne 'pending-measurement' }).Count -eq 0 -and @($d | Where-Object { -not $_.blocking }).Count -eq 0) ($d | ConvertTo-Json -Compress -Depth 3) }

# ---------------------------------------------------------------- PROJECT-XML-*
Test-Case 'XML-001 not well-formed' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('</Method>', '') } } @('PROJECT-XML-001') 'LINT_FAILED' {
    param($r)
    $d = @(Diag $r 'PROJECT-XML-001')
    Check 'XML-001 blocking true (no pending basis)' ($d.Count -eq 1 -and $d[0].blocking -and $null -eq $d[0].blockableBasis -and $d[0].file -eq 'POUs/FB_A.TcPOU') ($d | ConvertTo-Json -Compress)
    Check 'XML-001 file recorded as notAnalyzed, exception text only in engineDetail' (@($r.data.coverage.notAnalyzed | Where-Object { $_.reason -eq 'xml-not-well-formed' }).Count -eq 1 -and @($r.data.engineDetail).Count -eq 1 -and $d[0].message -notmatch 'Exception') ($r.data.engineDetail -join ' | ')
}
Test-Case 'XML-002 invalid UTF-8' { param($f)
    $b = [System.IO.File]::ReadAllBytes($f.Main); $i = [System.Text.Encoding]::ASCII.GetString($b).IndexOf('set mode'); $b[$i] = 0xC3; $b[$i + 1] = 0x28; [System.IO.File]::WriteAllBytes($f.Main, $b)
} @('PROJECT-XML-002') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-XML-002' }
Test-Case 'XML-003 code outside CDATA' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('<ST><![CDATA[fbA(bStart := GVL_Main.bRun);', '<ST>fbA(bStart := GVL_Main.bRun);<![CDATA[') } } @('PROJECT-XML-003') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-XML-003'); Check 'XML-003 text-outside-cdata is blockable true' ($d[0].variant -eq 'text-outside-cdata' -and $d[0].blocking -and $null -eq $d[0].blockableBasis) ($d | ConvertTo-Json -Compress)
}
Test-Case 'XML-003 split CDATA (]]> in code)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("// set mode", "// set ]]]]><![CDATA[> mode") } } @('PROJECT-XML-003') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-XML-003'); Check 'XML-003 multiple-cdata is pending' ($d[0].variant -eq 'multiple-cdata' -and $d[0].blockableBasis -eq 'pending-measurement') ($d | ConvertTo-Json -Compress)
}
Test-Case 'XML-004 missing SpecialFunc' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace(' SpecialFunc="None"', '') } } @('PROJECT-XML-004') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-XML-004' }
Test-Case 'XML-004 missing Implementation' { param($f) Edit-LintFxFile $f.Main { param($t) $t -replace '(?s)    <Implementation>.*?</Implementation>\r\n', '' } } @('PROJECT-XML-004')
Test-Case 'XML-004 member order is a warning only' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $a = [regex]::Match($t, '(?s)    <Action .*?</Action>\r\n').Value; $m = [regex]::Match($t, '(?s)    <Method .*?</Method>\r\n').Value
        $t.Replace($a + $m, $m + $a) } } @('PROJECT-XML-004') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-004'); Check 'XML-004 order: warning, not blocking' ($d[0].variant -eq 'order' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'XML-004 unobserved ProductVersion downgrades' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace(' SpecialFunc="None"', '').Replace('3.1.4026.18', '3.1.4028.1') } } @('PROJECT-XML-004') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-004'); Check 'XML-004 on 4028 file is a warning + rulesSkipped' ($d[0].severity -eq 'warning' -and -not $d[0].blocking -and @($r.data.coverage.rulesSkipped | Where-Object { $_.reason -eq 'unobserved-product-version' }).Count -eq 1) ($d | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- KIND / NAME
Test-Case 'KIND-001 POU element in a .TcDUT' { param($f) Edit-LintFxFile $f.Dut { param($t) $t.Replace('<DUT ', '<POU SpecialFunc="None" ').Replace('</DUT>', '<Implementation><ST><![CDATA[]]></ST></Implementation></POU>') } } @('PROJECT-KIND-001') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-KIND-001' }
Test-Case 'KIND-001 declaration keyword vs object' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t.Replace('VAR_GLOBAL', 'VAR') } } @('PROJECT-KIND-001')
Test-Case 'NAME-001 declared name differs' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('PROGRAM MAIN', 'PROGRAM MAIN2') } } @('PROJECT-NAME-001') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-NAME-001' }
Test-Case 'NAME-001 is case-insensitive (no finding)' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('PROGRAM MAIN', 'PROGRAM Main') } } @() ''
Test-Case 'NAME-001 method declaration' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('METHOD M_Do : BOOL', 'METHOD M_Run : BOOL') } } @('PROJECT-NAME-001')
Test-Case 'NAME-002 file name differs (warning)' { param($f)
    Move-Item $f.FbA (Join-Path $f.PlcDir 'POUs\FB_Old.TcPOU'); Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_Old.TcPOU', 'POUs\MAIN.TcPOU') } @('PROJECT-NAME-002') '' {
    param($r) $d = @(Diag $r 'PROJECT-NAME-002'); Check 'NAME-002 not blocking' (-not $d[0].blocking -and $d[0].severity -eq 'warning') ($d | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- GUID
Test-Case 'GUID-001 missing Id' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace(" Id=`"$($script:LintFx.MainId)`"", '') } } @('PROJECT-GUID-001') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-GUID-001' }
Test-Case 'GUID-002 malformed Id' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace($script:LintFx.FbAMethod, '{bca2ddc8-99fd-474f-8c18-1873e77b9b3}') } } @('PROJECT-GUID-002')
Test-Case 'GUID-003 copied file keeps its Ids' { param($f)
    $copy = Join-Path $f.PlcDir 'POUs\FB_B.TcPOU'
    Write-LintFxFile $copy ((Get-LintFxFbAText).Replace('"FB_A"', '"FB_B"').Replace('FUNCTION_BLOCK FB_A', 'FUNCTION_BLOCK FB_B').Replace('Name="FB_A.', 'Name="FB_B.'))
    Set-LintFxCompile $f ($script:LintFxCompile + 'POUs\FB_B.TcPOU') } @('PROJECT-GUID-003') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-GUID-003')
    Check 'GUID-003 reported for the POU, Action and Method of both files' ($d.Count -eq 6) (($d | ForEach-Object { "$($_.objectPath) $($_.evidence)" }) -join ' | ')
    & $pending $r 'PROJECT-GUID-003'
}
Test-Case 'GUID-004 zero Id' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t.Replace($script:LintFx.GvlId, '{00000000-0000-0000-0000-000000000000}') } } @('PROJECT-GUID-004')
Test-Case 'GUID-005 hand-written Id (warning)' { param($f) Edit-LintFxFile $f.Dut { param($t) $t.Replace($script:LintFx.DutId, '{a1b2c3d4-e5f6-7890-abcd-ef0123456789}') } } @('PROJECT-GUID-005') '' {
    param($r) $d = @(Diag $r 'PROJECT-GUID-005'); Check 'GUID-005 warning, medium, not blocking' ($d[0].severity -eq 'warning' -and $d[0].confidence -eq 'medium' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- SUB / LINEIDS
Test-Case 'SUB-001 method without Declaration' { param($f) Edit-LintFxFile $f.FbA { param($t) $t -replace '(?s)(<Method [^>]*>\r\n)      <Declaration>.*?</Declaration>\r\n', '$1' } } @('PROJECT-SUB-001') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-SUB-001' }
Test-Case 'SUB-002 two methods with one name' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $m = [regex]::Match($t, '(?s)    <Method .*?</Method>\r\n').Value
        $t.Replace($m, $m + $m.Replace($script:LintFx.FbAMethod, '{3abfd75b-1e61-4bea-9f5b-12954f0b7f61}').Replace('M_Do"', 'm_do"').Replace('METHOD M_Do', 'METHOD m_do')) } } @('PROJECT-SUB-002')
Test-Case 'LINEIDS-001 count differs (info)' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace('<LineId Id="3" Count="3" />', '<LineId Id="3" Count="4" />') } } @('PROJECT-LINEIDS-001') '' {
    param($r) $d = @(Diag $r 'PROJECT-LINEIDS-001'); Check 'LINEIDS-001 info, not blocking' ($d[0].severity -eq 'info' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'LINEIDS-001 member added without LineIds' { param($f) Edit-LintFxFile $f.FbA { param($t) $t -replace '(?s)    <LineIds Name="FB_A.M_Do">.*?</LineIds>\r\n', '' } } @('PROJECT-LINEIDS-001') ''

# ---------------------------------------------------------------- COMPILE
Test-Case 'COMPILE-001 missing file' { param($f) Set-LintFxCompile $f ($script:LintFxCompile + 'POUs\FB_Gone.TcPOU') } @('PROJECT-COMPILE-001') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-COMPILE-001' }
Test-Case 'COMPILE-002 duplicate (normalised path)' { param($f) Set-LintFxCompile $f ($script:LintFxCompile + '.\POUs\MAIN.TcPOU') } @('PROJECT-COMPILE-002')
Test-Case 'COMPILE-003 object file not compiled (warning)' { param($f) Write-LintFxFile (Join-Path $f.PlcDir 'POUs\FB_Orphan.TcPOU') ((Get-LintFxFbAText).Replace('FB_A', 'FB_Orphan')) } @('PROJECT-COMPILE-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-COMPILE-003')
    Check 'COMPILE-003 warning, not blocking, unresolved (behavior)' ($d[0].severity -eq 'warning' -and -not $d[0].blocking -and @($r.data.unresolved).Count -eq 1 -and $r.data.requiresDisposition) ($r.data.unresolved | ConvertTo-Json -Compress)
}
Test-Case 'COMPILE-004 SubType' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace("<Compile Include=`"PlcTask.TcTTO`">`r`n      <SubType>Code</SubType>", "<Compile Include=`"PlcTask.TcTTO`">`r`n      <SubType>Content</SubType>") } } @('PROJECT-COMPILE-004')
Test-Case 'COMPILE-005 directory without Folder item (info)' { param($f)
    New-Item -ItemType Directory -Path (Join-Path $f.PlcDir 'Extra') | Out-Null; Move-Item $f.Gvl (Join-Path $f.PlcDir 'Extra\GVL_Main.TcGVL')
    Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'Extra\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'POUs\MAIN.TcPOU') } @('PROJECT-COMPILE-005') ''
Test-Case 'COMPILE-006 case differs from disk' { param($f) Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'pous\Main.TcPOU') } @('PROJECT-COMPILE-006') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-COMPILE-006' }
Test-Case 'COMPILE-006 only a directory differs in case (warning)' { param($f) Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'pous\MAIN.TcPOU') } @('PROJECT-COMPILE-006') '' {
    param($r) $d = @(Diag $r 'PROJECT-COMPILE-006'); Check 'COMPILE-006 directory-case: warning, not blocking' ($d[0].variant -eq 'directory-case' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'COMPILE-006 % not escaped' { param($f)
    Move-Item $f.Gvl (Join-Path $f.PlcDir 'GVLs\GVL_Main%41.TcGVL')
    Set-LintFxCompile $f @('DUTs\E_Mode.TcDUT', 'GVLs\GVL_Main%41.TcGVL', 'PlcTask.TcTTO', 'POUs\FB_A.TcPOU', 'POUs\MAIN.TcPOU') } @('PROJECT-COMPILE-006', 'PROJECT-NAME-002')

# ---------------------------------------------------------------- LIB / TSPROJ
Test-Case 'LIB-001 placeholder without DefaultResolution' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t -replace '\s*<DefaultResolution>Tc2_Standard[^<]*</DefaultResolution>', '' } } @('PROJECT-LIB-001') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-LIB-001' }
Test-Case 'TSPROJ-001 PrjFilePath wrong' { param($f) Write-LintFxFile $f.Tsproj (Get-LintFxTsprojText -PrjFilePath 'PLC1\PLC2.plcproj') $false } @('PROJECT-TSPROJ-001') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-TSPROJ-001' }
Test-Case 'TSPROJ-002 GUID differs' { param($f) Write-LintFxFile $f.Plcproj (Get-LintFxPlcprojText $script:LintFxCompile -Guid '{a497c097-793a-4804-aa80-6a57816cc79c}') $false } @('PROJECT-TSPROJ-002') 'LINT_FAILED' {
    param($r) $d = @(Diag $r 'PROJECT-TSPROJ-002'); Check 'TSPROJ-002 for the .tsproj and the .sln' ($d.Count -eq 2) (($d | ForEach-Object { "$($_.file): $($_.message)" }) -join ' | ')
}
Test-Case 'TSPROJ-002 upper / lower case GUID is the same (no finding)' { param($f) Write-LintFxFile $f.Tsproj (Get-LintFxTsprojText -Guid $script:LintFx.PlcGuid) $false } @() ''
Test-Case 'TSPROJ-003 PouCall names no POU' { param($f) Write-LintFxFile $f.Task (Get-LintFxTaskText -PouCall 'MAIN_X') } @('PROJECT-TSPROJ-003') 'LINT_FAILED' { param($r) & $pending $r 'PROJECT-TSPROJ-003' }
Test-Case 'TSPROJ-003 PouCall names a FUNCTION_BLOCK' { param($f) Write-LintFxFile $f.Task (Get-LintFxTaskText -PouCall 'FB_A') } @('PROJECT-TSPROJ-003')
Test-Case 'TSPROJ-003 task context missing' { param($f) Write-LintFxFile $f.Tsproj (Get-LintFxTsprojText -ContextName 'OtherTask') $false } @('PROJECT-TSPROJ-003')
Test-Case 'XML-004 task without PouCall is a warning only' { param($f) Edit-LintFxFile $f.Task { param($t) $t -replace '(?s)    <PouCall>.*?</PouCall>\r\n', '' } } @('PROJECT-XML-004') '' {
    param($r) $d = @(Diag $r 'PROJECT-XML-004'); Check 'missing PouCall: warning, not blocking' ($d[0].variant -eq 'missing-pou-call' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'GVL starting with VAR_CONFIG is not a KIND finding' { param($f) Edit-LintFxFile $f.Gvl { param($t) $t.Replace('{attribute ''qualified_only''}' + "`r`n" + 'VAR_GLOBAL', "VAR_CONFIG`r`n    MAIN.fbA.bStart AT %IX0.0 : BOOL;`r`nEND_VAR`r`nVAR_GLOBAL") } } @() ''
Test-Case 'PLC as independent project file (.xti): TSPROJ rules skipped -> incomplete, not a finding' { param($f) Edit-LintFxFile $f.Tsproj { param($t) $t.Replace('PrjFilePath="PLC1\PLC1.plcproj"', 'File="PLC1.xti"') } } @() 'LINT_INCOMPLETE' {
    param($r) Check 'independent file -> blockingRulesSkipped TSPROJ-001..003' (@($r.data.coverage.blockingRulesSkipped | Where-Object { $_.reason -eq 'independent-project-file-not-observed' }).Count -eq 3) ($r.data.coverage | ConvertTo-Json -Compress -Depth 4)
}
Test-Case 'TSPROJ-003 priority differs (warning)' { param($f) Write-LintFxFile $f.Task (Get-LintFxTaskText -Priority '21') } @('PROJECT-TSPROJ-003') '' {
    param($r) $d = @(Diag $r 'PROJECT-TSPROJ-003'); Check 'TSPROJ-003 priority: warning, not blocking' ($d[0].variant -eq 'priority-mismatch' -and -not $d[0].blocking) ($d | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- ENC
Test-Case 'ENC-001 LF line ends, no BOM (info)' { param($f) Write-LintFxFile $f.Dut (Get-LintFxDutText) $false "`n" } @('PROJECT-ENC-001') '' {
    param($r) $d = @(Diag $r 'PROJECT-ENC-001'); Check 'ENC-001 info, mentions BOM and LF' ($d[0].severity -eq 'info' -and $d[0].message -match 'byte order mark' -and $d[0].message -match 'LF-only') $d[0].message
}
Test-Case 'ENC-001 mixed line ends' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("set mode`r`n", "set mode`n") } } @('PROJECT-ENC-001') ''

# ---------------------------------------------------------------- LINT-PARSE / LINT-XML
Test-Case 'LINT-PARSE-002 missing END_IF' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("`r`nEND_IF]]>", ']]>') } } @('LINT-PARSE-002') 'LINT_PARSE_FAILED' {
    param($r) $d = @(Diag $r 'LINT-PARSE-002'); Check 'LINT-PARSE-002 points at the open IF in MAIN' ($d[0].objectPath -eq 'MAIN' -and $d[0].section -eq 'implementation' -and $d[0].line -eq 2 -and $d[0].blocking) ($d | ConvertTo-Json -Compress)
}
Test-Case 'LINT-PARSE-003 VAR without END_VAR' { param($f) Edit-LintFxFile $f.FbA { param($t) $t.Replace("    nState : INT;`r`nEND_VAR", "    nState : INT;") } } @('LINT-PARSE-003') 'LINT_PARSE_FAILED'
Test-Case 'LINT-PARSE-001 unterminated string' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('eMode := E_Mode.Auto;', "eMode := 'open;") } } @('LINT-PARSE-001') 'LINT_PARSE_FAILED'
Test-Case 'parse failure keeps the other findings' { param($f)
    Edit-LintFxFile $f.Main { param($t) $t.Replace("`r`nEND_IF]]>", ']]>') }
    Edit-LintFxFile $f.Gvl { param($t) $t.Replace($script:LintFx.GvlId, '{00000000-0000-0000-0000-000000000000}') } } @('LINT-PARSE-002', 'PROJECT-GUID-004') 'LINT_PARSE_FAILED'
Test-Case 'conditional pragma: not analysed, never a parse failure' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('IF fbA.M_Do(nValue := 1) THEN', "{IF defined (SIMULATION)}`r`nIF bSim THEN`r`n{ELSE}`r`nIF fbA.M_Do(nValue := 1) THEN`r`n{END_IF}") } } @() '' {
    param($r) Check 'conditional pragma -> notAnalyzed conditional-pragma' (@($r.data.coverage.notAnalyzed | Where-Object { $_.objectPath -eq 'MAIN' -and $_.reason -eq 'conditional-pragma' }).Count -eq 1) ($r.data.coverage.notAnalyzed | ConvertTo-Json -Compress)
}
Test-Case 'conditional pragma before the header -> KIND / NAME skipped -> incomplete' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace('<Declaration><![CDATA[PROGRAM MAIN', "<Declaration><![CDATA[{IF defined (X)}`r`nPROGRAM MAIN`r`n{END_IF}") } } @() 'LINT_INCOMPLETE' {
    param($r) $s = @($r.data.coverage.blockingRulesSkipped | ForEach-Object { $_.ruleId } | Sort-Object)
    Check 'blockingRulesSkipped KIND-001 + NAME-001 for MAIN' (($s -join ',') -eq 'PROJECT-KIND-001,PROJECT-NAME-001' -and -not $r.data.passed) ($r.data.coverage.blockingRulesSkipped | ConvertTo-Json -Compress)
}
Test-Case 'LINT-XML-002 two ST elements' { param($f) Edit-LintFxFile $f.Main { param($t) $t.Replace("END_IF]]></ST>", "END_IF]]></ST>`r`n      <ST><![CDATA[x := 1;]]></ST>") } } @('LINT-XML-002') '' {
    param($r) $d = @(Diag $r 'LINT-XML-002'); Check 'LINT-XML-002 lineUnreliable' ($d[0].lineUnreliable -eq $true) ($d | ConvertTo-Json -Compress)
}
Test-Case 'CFC action: notAnalyzed language:CFC, PROJECT rules still run' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $t.Replace("<ST><![CDATA[nState := 0;]]></ST>", "<CFC PageOriented=`"true`">`r`n          <XmlArchive>`r`n            <Data><o xml:space=`"preserve`" t=`"CFC`" /></Data>`r`n          </XmlArchive>`r`n        </CFC>").Replace("    <LineIds Name=`"FB_A.A_Reset`">`r`n      <LineId Id=`"1`" Count=`"0`" />`r`n    </LineIds>`r`n", '').Replace($script:LintFx.FbAAction, '{00000000-0000-0000-0000-000000000000}') } } @('PROJECT-GUID-004') 'LINT_FAILED' {
    param($r) Check 'CFC -> notAnalyzed language:CFC (not incomplete)' (@($r.data.coverage.notAnalyzed | Where-Object { $_.objectPath -eq 'FB_A.A_Reset' -and $_.reason -eq 'language:CFC' }).Count -eq 1) ($r.data.coverage | ConvertTo-Json -Compress -Depth 4)
}
Test-Case 'Property: schema not observed -> rulesNotRun, Id still checked' { param($f) Edit-LintFxFile $f.FbA { param($t)
        $t.Replace('    <LineIds Name="FB_A">', "    <Property Name=`"P_State`" Id=`"$($script:LintFx.MainId)`">`r`n      <Declaration><![CDATA[PROPERTY P_State : INT]]></Declaration>`r`n      <Get Name=`"Get`" Id=`"{334ad498-c5df-4f59-9c38-e012e9fadc49}`">`r`n        <Declaration><![CDATA[VAR`r`nEND_VAR]]></Declaration>`r`n        <Implementation>`r`n          <ST><![CDATA[P_State := nState;]]></ST>`r`n        </Implementation>`r`n      </Get>`r`n    </Property>`r`n    <LineIds Name=`"FB_A`">") } } @('PROJECT-GUID-003') 'LINT_FAILED' {
    param($r) Check 'Property -> rulesNotRun schema-not-observed' (@($r.data.coverage.rulesNotRun | Where-Object { $_.objectPath -eq 'FB_A.P_State' -and $_.reason -eq 'schema-not-observed' }).Count -eq 2) ($r.data.coverage.rulesNotRun | ConvertTo-Json -Compress)
}

# ---------------------------------------------------------------- the .plcproj itself
Test-Case '.plcproj not well-formed -> LINT_PARSE_FAILED' { param($f) Edit-LintFxFile $f.Plcproj { param($t) $t.Replace('</ProjectGuid>', '</ProjectGuidX>') } } @('PROJECT-XML-001') 'LINT_PARSE_FAILED'
Test-Case 'XXE / DTD in a .TcPOU is refused, never resolved' { param($f)
    $secret = Join-Path $f.Root 'secret.txt'; Set-Content -LiteralPath $secret -Value 'TOPSECRET' -Encoding ASCII
    Edit-LintFxFile $f.Main { param($t) $t.Replace("<?xml version=`"1.0`" encoding=`"utf-8`"?>", "<?xml version=`"1.0`" encoding=`"utf-8`"?>`r`n<!DOCTYPE TcPlcObject [ <!ENTITY x SYSTEM `"file:///$($secret.Replace('\','/'))`"> ]>").Replace('// set mode', '// &x;') } } @('PROJECT-XML-001') 'LINT_FAILED' {
    param($r) Check 'XXE: the entity text never appears in the output' ((($r | ConvertTo-Json -Depth 20) -notmatch 'TOPSECRET')) 'secret leaked'
}

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
