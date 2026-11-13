# Unit: semantic linter (#252) Phase 3a rules SCAN-FBVAL-001 (FB passed by value and changed in the callee), SCAN-FLOAT-001
# (REAL / LREAL compared with = / <>), SCAN-INTDIV-001 (integer division assigned to REAL / LREAL), no IDE.
#   V  FBVAL: called / member written / method called / TON / FUNCTION input; counter-examples: outputs only read, VAR_IN_OUT,
#      REFERENCE TO / POINTER TO FB, interface, STRUCT, library type (unknown-type only when called / written)
#   F  FLOAT: = non-zero literal / constant, two REAL variables with =; counter-examples: 0.0 / 0 / zero constant, change
#      detection <>, ordering comparisons, integers, unknown operand next to a REAL variable (operand-type-unknown)
#   I  INTDIV: INT / DINT, literals, inside parentheses; counter-examples: INT_TO_REAL operand, REAL operand, integer target,
#      TO_REAL(a / b) (explicit-conversion), STRUCT member operand (operand-type-unknown)
#   X  suppression (inline / profile), disabled rules; M metadata; D determinism
# Mock basis: tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13). Impact: FBVAL InfoSys 12081345291
# (parameters are copied on call); FLOAT / INTDIV inferred (IEC arithmetic, not measured). Every check looks at the result
# object, never at localised PowerShell text.
#   powershell.exe -NoProfile -File tests/Unit/lint-rules-3expr.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
Import-Module $modulePath -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\LintFixture.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 900) { $Detail = $Detail.Substring(0, 900) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function Js($o) { return ($o | ConvertTo-Json -Depth 30 -Compress) }
$RSm = 'SCAN-FLOAT-001'
function Diags($r) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $RSm }) }
function Brief($r) { return ((@($r.data.diagnostics | Where-Object { $_.ruleId -eq $RSm } | ForEach-Object { "$($_.variant)@$($_.objectPath):$($_.section):$($_.line) $($_.severity) b=$($_.blocking) s=$($_.suppressed) [$($_.message)]" }) -join '; ') + " code=$($r.error.code)") }
function SkipText($r) { return ((@($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq $RSm } | ForEach-Object { "$($_.objectPath)=$($_.reason)" })) -join ',') }
function Unres($r) { return , @($r.data.unresolved | Where-Object { $_.ruleId -eq $RSm }) }
function NoSm($r) { return ((Diags $r).Count -eq 0) }

$root = Join-Path $env:TEMP ("tcauto-unit-lint3expr-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$root = & $mod { param($p) Get-TcLongPath $p } $root   # CI %TEMP% is an 8.3 short path
$n = 0
function New-Fx {
    $script:n++
    $fx = New-LintFixture (Join-Path $root ("f{0:D2}" -f $script:n))
    $fx.Items = [System.Collections.Generic.List[string]]::new([string[]]$script:LintFxCompile)
    return $fx
}
function New-Id { return '{' + [guid]::NewGuid().ToString() + '}' }
function Add-Pou($Fx, [string]$Name, [string]$Decl, [string]$Impl, [string]$Extra = '') {
    Write-LintFxFile (Join-Path $Fx.PlcDir "POUs\$Name.TcPOU") (Get-LintFxPou -Name $Name -Id (New-Id) -Decl $Decl -Impl $Impl -Extra $Extra)
    $Fx.Items.Add("POUs\$Name.TcPOU")
    Set-LintFxCompile $Fx $Fx.Items.ToArray()
}
function Method([string]$Name, [string]$Decl, [string]$Impl) {
    return "`n    <Method Name=`"$Name`" Id=`"$(New-Id)`">`n      <Declaration><![CDATA[$Decl]]></Declaration>`n      <Implementation>`n        <ST><![CDATA[$Impl]]></ST>`n      </Implementation>`n    </Method>"
}
function Action([string]$Name, [string]$Impl) {
    return "`n    <Action Name=`"$Name`" Id=`"$(New-Id)`">`n      <Implementation>`n        <ST><![CDATA[$Impl]]></ST>`n      </Implementation>`n    </Action>"
}
function Add-Gvl($Fx, [string]$Name, [string]$Decl) {
    Write-LintFxFile (Join-Path $Fx.PlcDir "GVLs\$Name.TcGVL") ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <GVL Name=`"$Name`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[$Decl]]></Declaration>`n  </GVL>`n</TcPlcObject>")
    $Fx.Items.Add("GVLs\$Name.TcGVL"); Set-LintFxCompile $Fx $Fx.Items.ToArray()
}
function Add-Dut($Fx, [string]$Name, [string]$Decl) {
    Write-LintFxFile (Join-Path $Fx.PlcDir "DUTs\$Name.TcDUT") ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <DUT Name=`"$Name`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[$Decl]]></Declaration>`n  </DUT>`n</TcPlcObject>")
    $Fx.Items.Add("DUTs\$Name.TcDUT"); Set-LintFxCompile $Fx $Fx.Items.ToArray()
}
function Set-Profile($Fx, [string]$Json) {
    $dir = Join-Path ([System.IO.Path]::GetDirectoryName($Fx.Sln)) '.tcauto'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $dir 'lint-profile.json'), $Json, (New-Object System.Text.UTF8Encoding($false)))
}
# FB_T with the given VAR lines, body and extra members; $Before adds other objects first
function Fb([string]$Vars, [string]$Impl, [string]$Extra = '', [scriptblock]$Before, [string]$Blocks = '') {
    $fx = New-Fx
    if ($Before) { & $Before $fx }
    Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T$Blocks`nVAR`n$Vars`nEND_VAR`n" $Impl $Extra
    return (Invoke-TcLintProject -PlcProjectPath $fx.Plcproj)
}
function Prg([string]$Vars, [string]$Impl, [string]$Extra = '', [scriptblock]$Before) {
    $fx = New-Fx
    if ($Before) { & $Before $fx }
    Add-Pou $fx 'MAIN' "PROGRAM MAIN`nVAR`n$Vars`nEND_VAR`n" $Impl $Extra
    return (Invoke-TcLintProject -PlcProjectPath $fx.Plcproj)
}
$R3 = 'SCAN-FBVAL-001', 'SCAN-FLOAT-001', 'SCAN-INTDIV-001'
function D3($r, [string]$Rule) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $Rule }) }
function All3($r) { return , @($r.data.diagnostics | Where-Object { $R3 -contains $_.ruleId }) }
function Brief3($r) { return ((@($r.data.diagnostics | Where-Object { $R3 -contains $_.ruleId } | ForEach-Object { "$($_.ruleId)/$($_.variant)@$($_.objectPath):$($_.section):$($_.line) $($_.severity) b=$($_.blocking) s=$($_.suppressed)" }) -join '; ') + ' | ' + ((@($r.data.coverage.rulesSkipped | Where-Object { $R3 -contains $_.ruleId } | ForEach-Object { "$($_.ruleId)@$($_.objectPath)=$($_.reason)" })) -join ',') + " code=$($r.error.code)") }
function Sk3($r, [string]$Rule) { return ((@($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq $Rule } | ForEach-Object { "$($_.objectPath)=$($_.reason)" })) -join ',') }
function None3($r) { return ((All3 $r).Count -eq 0) }
function NoSkip3($r) { return (@($r.data.coverage.rulesSkipped | Where-Object { $R3 -contains $_.ruleId }).Count -eq 0) }
function Only3($r, [string]$Rule, [string]$Variant) { $a = All3 $r; return ($a.Count -eq 1 -and $a[0].ruleId -eq $Rule -and $a[0].variant -eq $Variant) }
$fbx = { param($fx) Add-Pou $fx 'FB_X' "FUNCTION_BLOCK FB_X`nVAR_INPUT`n    bIn : BOOL;`nEND_VAR`nVAR_OUTPUT`n    bOut : BOOL;`nEND_VAR`n" "bOut := bIn;" (Method 'M_Reset' "METHOD M_Reset`n" "bOut := FALSE;") }
# callee FB_T gets fbIn of the given type in VAR_INPUT
function Callee([string]$Inputs, [string]$Impl, [scriptblock]$Before) {
    $fx = New-Fx
    & $fbx $fx
    if ($Before) { & $Before $fx }
    Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR_INPUT`n$Inputs`nEND_VAR`nVAR`n    b : BOOL;`nEND_VAR`n" $Impl
    return (Invoke-TcLintProject -PlcProjectPath $fx.Plcproj)
}
# PROGRAM with REAL / INT / constants
$pv = "    rA : REAL;`n    rB : REAL;`n    lr : LREAL;`n    nA : INT;`n    nB : DINT;`n    b : BOOL;`n    st : ST_P;`nEND_VAR`nVAR CONSTANT`n    cR : REAL := 2.5;`n    cZ : REAL := 0.0;"
$stp = { param($fx) Add-Dut $fx 'ST_P' "TYPE ST_P :`nSTRUCT`n    r : REAL;`n    n : INT;`nEND_STRUCT`nEND_TYPE`n" }
function P3([string]$Impl) { return (Prg $pv $Impl '' $stp) }

# ================================================================ V  SCAN-FBVAL-001
$r = Callee "    fbIn : FB_X;" "fbIn(bIn := TRUE);"
$d = D3 $r 'SCAN-FBVAL-001'
Check 'V1 VAR_INPUT FB called inside the callee -> copy-called warning at the declaration, in unresolved' ((Only3 $r 'SCAN-FBVAL-001' 'copy-called') -and $d[0].section -eq 'declaration' -and $d[0].line -eq 3 -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and $r.data.requiresDisposition) (Brief3 $r)
$r = Callee "    fbIn : FB_X;" "fbIn.bIn := TRUE;"
Check 'V2 member of the copy written -> copy-written' (Only3 $r 'SCAN-FBVAL-001' 'copy-written') (Brief3 $r)
$r = Callee "    fbIn : FB_X;" "fbIn.M_Reset();"
Check 'V3 method of the copy called -> copy-called' (Only3 $r 'SCAN-FBVAL-001' 'copy-called') (Brief3 $r)
$r = Callee "    tIn : TON;" "tIn(IN := TRUE, PT := T#1S);"
Check 'V4 catalog FB (TON) VAR_INPUT called -> copy-called' (Only3 $r 'SCAN-FBVAL-001' 'copy-called') (Brief3 $r)
$fx = New-Fx; & $fbx $fx
Add-Pou $fx 'F_Use' "FUNCTION F_Use : BOOL`nVAR_INPUT`n    fbIn : FB_X;`nEND_VAR`n" "fbIn();`nF_Use := fbIn.bOut;"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'V5 FUNCTION VAR_INPUT FB called -> copy-called' (Only3 $r 'SCAN-FBVAL-001' 'copy-called') (Brief3 $r)
$r = Callee "    fbIn : FB_X;" "b := fbIn.bOut;"
Check 'V6 only an output of the copy read (legal: the copy is the state at call time) -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$fx = New-Fx; & $fbx $fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR_IN_OUT`n    fbIn : FB_X;`nEND_VAR`n" "fbIn(bIn := TRUE);"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'V7 VAR_IN_OUT FB called -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = Callee "    fbIn : REFERENCE TO FB_X;" "IF __ISVALIDREF(fbIn) THEN`n    fbIn(bIn := TRUE);`nEND_IF"
Check 'V8 VAR_INPUT REFERENCE TO FB called -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = Callee "    pIn : POINTER TO FB_X;" "IF pIn <> 0 THEN`n    pIn^(bIn := TRUE);`nEND_IF"
Check 'V9 VAR_INPUT POINTER TO FB -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = Callee "    iIn : I_X;" "iIn.M_Do();" { param($fx) Write-LintFxFile (Join-Path $fx.PlcDir 'POUs\I_X.TcIO') "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <Itf Name=`"I_X`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[INTERFACE I_X`n]]></Declaration>`n  </Itf>`n</TcPlcObject>"; $fx.Items.Add('POUs\I_X.TcIO'); Set-LintFxCompile $fx $fx.Items.ToArray() }
Check 'V10 interface type VAR_INPUT method called -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = Callee "    xIn : FB_Lib;" "xIn(bEnable := TRUE);"
Check 'V11 type outside project and catalog, called -> no finding, rulesSkipped unknown-type' ((None3 $r) -and (Sk3 $r 'SCAN-FBVAL-001') -like '*unknown-type:xIn*') (Brief3 $r)
$r = Callee "    xIn : FB_Lib;" "b := xIn.bOut;"
Check 'V12 unknown type only read -> nothing (no call, no write)' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = Callee "    stIn : ST_P;" "stIn.n := 1;" $stp
Check 'V13 STRUCT VAR_INPUT member written -> nothing (not an FB)' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)

# ================================================================ F  SCAN-FLOAT-001
$r = P3 "IF rA = 100.0 THEN`n    b := TRUE;`nEND_IF"
$d = D3 $r 'SCAN-FLOAT-001'
Check 'F1 rA = 100.0 -> constant warning at line 1' ((Only3 $r 'SCAN-FLOAT-001' 'constant') -and $d[0].line -eq 1 -and $d[0].severity -eq 'warning' -and $r.data.requiresDisposition) (Brief3 $r)
$r = P3 "b := lr <> cR;"
Check 'F2 LREAL <> VAR CONSTANT 2.5 -> constant' (Only3 $r 'SCAN-FLOAT-001' 'constant') (Brief3 $r)
$r = P3 "IF rA = -2.5 THEN`n    b := TRUE;`nEND_IF`nWHILE lr <> 1.0E3 DO`n    lr := lr + 0.1;`nEND_WHILE"
Check 'F2b negative literal, exponent literal in WHILE -> two constant findings' ((D3 $r 'SCAN-FLOAT-001').Count -eq 2) (Brief3 $r)
$r = P3 "IF rA = rB THEN`n    b := TRUE;`nEND_IF"
Check 'F3 rA = rB (two REAL variables) -> no finding, rulesSkipped two-variables (division guard / clamp idioms in the corpus)' ((None3 $r) -and (Sk3 $r 'SCAN-FLOAT-001') -like '*two-variables*') (Brief3 $r)
$r = P3 "b := st.r = 1.5;"
Check 'F4 unknown-typed operand = non-zero REAL literal -> constant (the literal makes it a REAL compare)' (Only3 $r 'SCAN-FLOAT-001' 'constant') (Brief3 $r)
$r = P3 "b := rA = 100;"
Check 'F5 REAL = integer literal 100 -> constant' (Only3 $r 'SCAN-FLOAT-001' 'constant') (Brief3 $r)
$r = P3 "b := rA = 0.0;`nb := rA <> 0;`nb := cZ = rA;"
Check 'F6 comparisons with 0.0 / 0 / a zero constant -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = P3 "IF rA <> rB THEN`n    rB := rA;`nEND_IF`nIF rA = rB THEN`n    rB := 0.0;`nELSE`n    rA := 1.0 / (rB - rA);`nEND_IF"
Check 'F7 change detection rA <> rB, division guard rA = rB -> no finding (two-variables skip)' ((None3 $r) -and (Sk3 $r 'SCAN-FLOAT-001') -like '*two-variables*') (Brief3 $r)
$r = P3 "b := rA > 100.0;`nb := rA <= 1.5;"
Check 'F8 ordering comparisons -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = P3 "b := nA = 100;`nb := nB <> nA;"
Check 'F9 integer comparisons -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = P3 "b := rA = st.r;"
Check 'F10 REAL variable = unknown-typed operand -> no finding, rulesSkipped operand-type-unknown' ((None3 $r) -and (Sk3 $r 'SCAN-FLOAT-001') -like '*operand-type-unknown*') (Brief3 $r)
$r = P3 "rA := 1.5;`nb := rA * 2.0 > 3.0;"
Check 'F11 := and arithmetic without = / <> -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)

# ================================================================ I  SCAN-INTDIV-001
$r = P3 "rA := nA / nB;"
$d = D3 $r 'SCAN-INTDIV-001'
Check 'I1 rA := nA / nB (INT / DINT) -> integer-division warning' ((Only3 $r 'SCAN-INTDIV-001' 'integer-division') -and $d[0].line -eq 1 -and $d[0].severity -eq 'warning' -and $r.data.requiresDisposition) (Brief3 $r)
$r = P3 "IF b THEN`n    nA := 1;`nEND_IF`nlr := 1 / 3;"
Check 'I2 lr := 1 / 3 after END_IF without ; (two integer literals) -> integer-division' (Only3 $r 'SCAN-INTDIV-001' 'integer-division') (Brief3 $r)
$r = P3 "rA := (nA / 4) * 2.0 + rB;"
Check 'I3 integer division inside parentheses of a REAL expression -> integer-division' (Only3 $r 'SCAN-INTDIV-001' 'integer-division') (Brief3 $r)
$r = P3 "rA := INT_TO_REAL(nA) / nB;"
Check 'I4 INT_TO_REAL(nA) / nB -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = P3 "rA := nA / 2.0;`nrB := rA / nA;"
Check 'I5 a REAL operand -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = P3 "nA := nA / nB;"
Check 'I6 integer target -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)
$r = P3 "rA := TO_REAL(nA / nB);"
Check 'I7 TO_REAL(nA / nB) (explicit) -> no finding, rulesSkipped explicit-conversion' ((None3 $r) -and (Sk3 $r 'SCAN-INTDIV-001') -like '*explicit-conversion*') (Brief3 $r)
$r = P3 "rA := st.n / nA;"
Check 'I8 STRUCT member operand -> no finding, rulesSkipped operand-type-unknown' ((None3 $r) -and (Sk3 $r 'SCAN-INTDIV-001') -like '*operand-type-unknown*') (Brief3 $r)
$r = P3 "rA := rB / rA;`nnA := DINT_TO_INT(nB / 2);"
Check 'I9 REAL / REAL, integer target of a conversion -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)

# ================================================================ X  suppression / disabled
$r = P3 "// tcauto-lint-disable-next-line SCAN-FLOAT-001: setpoint is copied 1:1 from the HMI value`nb := rA = 100.0;"
$d = D3 $r 'SCAN-FLOAT-001'
Check 'X1 inline suppression -> suppressed, not in unresolved' ($d.Count -eq 1 -and $d[0].suppressed -and @($r.data.unresolved | Where-Object { $R3 -contains $_.ruleId }).Count -eq 0) (Brief3 $r)
$fx = New-Fx
& $stp $fx
Add-Pou $fx 'MAIN' "PROGRAM MAIN`nVAR`n$pv`nEND_VAR`n" "rA := nA / nB;"
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"MAIN","ruleId":"SCAN-INTDIV-001","reason":"reviewed: truncation intended here"}]}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = D3 $r 'SCAN-INTDIV-001'
Check 'X2 profile suppression -> suppressed' ($d.Count -eq 1 -and $d[0].suppressed -and @($r.data.unresolved | Where-Object { $R3 -contains $_.ruleId }).Count -eq 0) (Brief3 $r)
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"SCAN-INTDIV-001":{"enabled":false},"SCAN-FLOAT-001":{"enabled":false},"SCAN-FBVAL-001":{"enabled":false}}}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'X3 rules disabled -> nothing' ((None3 $r) -and (NoSkip3 $r)) (Brief3 $r)

# ================================================================ M  metadata
foreach ($id in $R3) {
    $m = @(& $mod { param($i) $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get($i) } $id)[0]
    Check "M $id phase 3, warning, not blockable, behavior, compiler no, TE1200 Full rule named" ($null -ne $m -and $m.Phase -eq '3' -and $m.Severity -eq 'warning' -and $m.Blockable -eq 'false' -and $m.MachineImpact -eq 'behavior' -and $m.CompilerCatches -eq 'no' -and $m.Te1200 -like '*Full*' -and $m.Limits.Length -gt 200) "$($m.Phase) $($m.Severity) $($m.Blockable) $($m.MachineImpact) $($m.Confidence) $($m.ImpactBasis) $($m.Te1200)"
}

# ================================================================ D  determinism
$fx = New-Fx
& $fbx $fx; & $stp $fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR_INPUT`n    fbIn : FB_X;`nEND_VAR`n" "fbIn();"
Add-Pou $fx 'MAIN' "PROGRAM MAIN`nVAR`n$pv`nEND_VAR`n" "b := rA = 1.5;`nrA := nA / nB;`nb := rA = st.r;"
$outs = foreach ($cul in 'en-US', 'zh-TW', 'en-US') {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $cul; [System.Threading.Thread]::CurrentThread.CurrentUICulture = $cul
    $x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj; $x.data.Remove('newSuppressionsBasisReason'); Js $x
}
$x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'D1 three findings (FBVAL, FLOAT, INTDIV) + one skip' ((All3 $x).Count -eq 3 -and (Sk3 $x 'SCAN-FLOAT-001') -like '*operand-type-unknown*') (Brief3 $x)
Check 'D2 two runs and en-US / zh-TW byte-identical' ($outs[0] -ceq $outs[1] -and $outs[0] -ceq $outs[2]) ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
