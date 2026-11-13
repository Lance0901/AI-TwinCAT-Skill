# Unit: semantic linter (#252) Phase 2a rules, no IDE.
#   L  SCAN-LOOP-001 busy-wait: invariant WHILE / REPEAT conditions (input, FB output, WHILE TRUE); counter-examples:
#      condition written in the body, EXIT, WHILE TRUE + EXIT, FB / method call in the body, call in the condition,
#      REFERENCE alias, pointer write; conditional pragma -> rulesSkipped; inline suppression refused (LINT-SUPPRESS-004)
#   F  SCAN-FOR-001 end value at the counter type's limit: BYTE 255, SINT down to -128, VAR CONSTANT end value,
#      BY 0 (pending), step overflow (warning), EXIT in the body (warning); counter-examples: end below the limit,
#      wider counter type, counter written in the body / end not constant (rulesSkipped)
#   A  SCAN-ARR-001 FOR index outside the array: 0-based loop on ARRAY[1..10], a[i + 1], qualified_only GVL constant
#      bounds, two dimensions, ARRAY OF ARRAY; counter-examples: loop inside the bounds, LOWER_BOUND / UPPER_BOUND,
#      ARRAY[*], IF guard (warning), struct member array (rulesSkipped)
#   C  SAFETY-ARR-001 constant index outside the array (compiler C0049): literal / VAR CONSTANT index; counter-examples
#   V  SAFETY-DIV-001 / 0 (compiler C0374), MOD 0 (not caught), named constant 0, variable divisor (info);
#      counter-examples: IF <> 0, REAL with > 0.0, ELSE of = 0, early RETURN, constant divisors; suppression
#   M  rule metadata (phase 2, TE1200, compilerCatches)
#   D  deterministic: two runs and en-US / zh-TW byte-identical
# Mock basis: tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13). The rule expectations follow
# rule-catalog.md and the InfoSys pages cited in RuleRegistry (LintCore.cs); compiler behaviour C0049 / C0374 / MOD 0
# measured 2026-11-13 (verification/st-syntax-measured.md section 3). Every check looks at the result object, never
# at localised PowerShell text.
#   powershell.exe -NoProfile -File tests/Unit/lint-rules-2a.ps1
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
function Diags($r, [string]$Rule) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $Rule }) }   # ',' keeps a one-element array an array
function Brief($r) { return ((@($r.data.diagnostics | ForEach-Object { "$($_.ruleId)/$($_.variant)@$($_.objectPath):$($_.line) $($_.severity) b=$($_.blocking) s=$($_.suppressed)" }) -join '; ') + " code=$($r.error.code)") }
function Skips($r, [string]$Rule) { return , @($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq $Rule }) }
function Unres($r, [string]$Rule) { return , @($r.data.unresolved | Where-Object { $_.ruleId -eq $Rule }) }

$root = Join-Path $env:TEMP ("tcauto-unit-lint2a-{0}" -f [guid]::NewGuid().ToString('N'))
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
function Add-Gvl($Fx, [string]$Name, [string]$Decl) {
    Write-LintFxFile (Join-Path $Fx.PlcDir "GVLs\$Name.TcGVL") ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <GVL Name=`"$Name`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[$Decl]]></Declaration>`n  </GVL>`n</TcPlcObject>")
    $Fx.Items.Add("GVLs\$Name.TcGVL"); Set-LintFxCompile $Fx $Fx.Items.ToArray()
}
# one function block FB_T with the given VAR lines and body; returns the lint result
function Fb([string]$Vars, [string]$Impl, [scriptblock]$Before) {
    $fx = New-Fx
    if ($Before) { & $Before $fx }
    Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n$Vars`nEND_VAR`n" $Impl
    return (Invoke-TcLintProject -PlcProjectPath $fx.Plcproj)
}

# ================================================================ L  SCAN-LOOP-001
$r = Fb "    bIn AT %IX0.0 : BOOL;`n    nCnt : INT;" "nCnt := 0;`nWHILE NOT bIn DO`n    nCnt := nCnt + 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'L1 WHILE NOT bIn (AT %IX) with a body that only counts -> blocking error, LINT_FAILED, message names the input' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].severity -eq 'error' -and $d[0].line -eq 2 -and $d[0].message -like '*%IX0.0*' -and $r.error.code -eq 'LINT_FAILED' -and (Unres $r 'SCAN-LOOP-001').Count -eq 1) (Brief $r)
$r = Fb "    fbT : TON;`n    nX : INT;" "REPEAT`n    nX := 1;`nUNTIL fbT.Q`nEND_REPEAT"
$d = Diags $r 'SCAN-LOOP-001'
Check 'L2 REPEAT ... UNTIL fbT.Q, fbT never called in the loop -> blocking, message names the FB output' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].message -like '*fbT.Q*' -and $d[0].line -eq 1) (Brief $r)
$r = Fb "    n : INT;" "WHILE TRUE DO`nEND_WHILE"
Check 'L3 WHILE TRUE DO END_WHILE (no EXIT) -> blocking' ((Diags $r 'SCAN-LOOP-001').Count -eq 1 -and (Diags $r 'SCAN-LOOP-001')[0].blocking) (Brief $r)
$r = Fb "    i : INT;`n    a : ARRAY[0..9] OF INT;" "i := 0;`nWHILE i < 10 DO`n    a[i] := 0;`n    i := i + 1;`nEND_WHILE"
Check 'L4 counter-example: the body writes the condition variable -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and $r.success) (Brief $r)
$r = Fb "    b : BOOL;`n    n : INT;" "WHILE NOT b DO`n    n := n + 1;`n    IF n > 5 THEN`n        EXIT;`n    END_IF`nEND_WHILE"
Check 'L5 counter-example: body has EXIT -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    n : INT;" "WHILE TRUE DO`n    n := n + 1;`n    IF n > 10 THEN EXIT; END_IF`nEND_WHILE"
Check 'L6 counter-example: WHILE TRUE with EXIT -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    fbT : TON;" "WHILE NOT fbT.Q DO`n    fbT(IN := TRUE, PT := T#1S);`nEND_WHILE"
Check 'L7 counter-example: the body calls the FB whose output is the condition -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    bDone : BOOL;`n    n : INT;`nEND_VAR`n" "WHILE NOT bDone DO`n    THIS^.M_Step();`nEND_WHILE`nREPEAT`n    n := n + 1;`nUNTIL M_Ready()`nEND_REPEAT" (Method 'M_Step' "METHOD M_Step`n" 'bDone := TRUE;')
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'L8 counter-example: method call in the body; call in the UNTIL condition -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    bX : BOOL;`n    refX : REFERENCE TO BOOL;" "refX REF= bX;`nWHILE NOT refX DO`n    bX := TRUE;`nEND_WHILE"
Check 'L9 counter-example: condition is a REFERENCE the body may write through an alias -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    b : BOOL;`n    p : POINTER TO BOOL;" "p := ADR(b);`nWHILE NOT b DO`n    p^ := TRUE;`nEND_WHILE"
Check 'L10 counter-example: pointer write in the body -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    b : BOOL;`n    n : INT;" "{IF defined (LINT_X)}`nn := 1;`n{END_IF}`nWHILE NOT b DO`n    n := n + 1;`nEND_WHILE"
$s = Skips $r 'SCAN-LOOP-001'
Check 'L11 conditional pragma in the section -> not evaluated, rulesSkipped implementation-conditional-pragma, still pass' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and $s.Count -eq 1 -and $s[0].reason -eq 'implementation-conditional-pragma' -and $r.success) ((Brief $r) + ' ' + (Js $s))
$r = Fb "    b : BOOL;`n    n : INT;" "// tcauto-lint-disable-next-line SCAN-LOOP-001: the sensor is simulated in this test`nWHILE NOT b DO`n    n := n + 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'L12 inline suppression of a blocking busy-wait -> LINT-SUPPRESS-004, finding stays blocking' ($d.Count -eq 1 -and -not $d[0].suppressed -and $d[0].blocking -and (Diags $r 'LINT-SUPPRESS-004').Count -eq 1 -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
$r = Fb "    n : INT;" "WHILE FALSE DO`n    n := n + 1;`nEND_WHILE`nREPEAT`n    n := 0;`nUNTIL TRUE`nEND_REPEAT"
Check 'L13 counter-example: WHILE FALSE / REPEAT UNTIL TRUE (constant, loop ends) -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)

# ================================================================ F  SCAN-FOR-001
$r = Fb "    i : BYTE;`n    n : INT;" "FOR i := 0 TO 255 DO`n    n := n + 1;`nEND_FOR"
$d = Diags $r 'SCAN-FOR-001'
Check 'F1 i : BYTE; FOR i := 0 TO 255 -> blocking error (compiler only warns C0266), in unresolved' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].severity -eq 'error' -and $null -eq $d[0].variant -and (Unres $r 'SCAN-FOR-001').Count -eq 1 -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
$r = Fb "    k : SINT;`n    n : INT;" "FOR k := 10 TO -128 BY -1 DO`n    n := n + 1;`nEND_FOR"
Check 'F2 k : SINT; FOR k := 10 TO -128 BY -1 -> blocking (lower bound)' ((Diags $r 'SCAN-FOR-001').Count -eq 1 -and (Diags $r 'SCAN-FOR-001')[0].blocking) (Brief $r)
$r = Fb "    i : USINT;`n    n : INT;`nEND_VAR`nVAR CONSTANT`n    cLast : USINT := 16#FF;" "FOR i := 0 TO cLast DO`n    n := n + 1;`nEND_FOR"
Check 'F3 end value is a VAR CONSTANT 16#FF on a USINT counter -> blocking' ((Diags $r 'SCAN-FOR-001').Count -eq 1 -and (Diags $r 'SCAN-FOR-001')[0].blocking) (Brief $r)
$r = Fb "    i : BYTE;`n    n : INT;" "FOR i := 0 TO 254 DO`n    n := n + 1;`nEND_FOR"
Check 'F4 counter-example: BYTE 0 TO 254 -> no finding' ((Diags $r 'SCAN-FOR-001').Count -eq 0 -and $r.success) (Brief $r)
$r = Fb "    i : INT;`n    n : INT;" "FOR i := 0 TO 255 DO`n    n := n + 1;`nEND_FOR"
Check 'F5 counter-example: INT counter 0 TO 255 (upper bound of INT is higher) -> no finding' ((Diags $r 'SCAN-FOR-001').Count -eq 0) (Brief $r)
$r = Fb "    i : BYTE;`n    b : BOOL;" "FOR i := 0 TO 255 DO`n    IF b THEN`n        EXIT;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-FOR-001'
Check 'F6 EXIT in the body -> variant exit-in-body, warning, not blocking, still unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'exit-in-body' -and -not $d[0].blocking -and $d[0].severity -eq 'warning' -and $r.success -and (Unres $r 'SCAN-FOR-001').Count -eq 1) (Brief $r)
$r = Fb "    i : INT;`n    n : INT;" "FOR i := 0 TO 10 BY 0 DO`n    n := n + 1;`nEND_FOR"
$d = Diags $r 'SCAN-FOR-001'
Check 'F7 BY 0 -> variant by-zero, pending (blockableBasis pending-measurement), blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'by-zero' -and $d[0].blockableBasis -eq 'pending-measurement' -and $d[0].blocking) (Brief $r)
$r = Fb "    i : BYTE;`n    n : INT;" "FOR i := 0 TO 255 DO`n    i := i + 1;`nEND_FOR"
Check 'F8 counter written in the body -> not evaluated, rulesSkipped counter-written-in-body' ((Diags $r 'SCAN-FOR-001').Count -eq 0 -and @(Skips $r 'SCAN-FOR-001' | Where-Object { $_.reason -eq 'counter-written-in-body:i' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-FOR-001')))
$r = Fb "    i : BYTE;`n    nEnd : BYTE;`n    n : INT;" "FOR i := 0 TO nEnd DO`n    n := n + 1;`nEND_FOR"
Check 'F9 end value is a variable -> not evaluated, rulesSkipped end-not-constant' ((Diags $r 'SCAN-FOR-001').Count -eq 0 -and @(Skips $r 'SCAN-FOR-001' | Where-Object { $_.reason -eq 'end-not-constant' }).Count -eq 1) (Brief $r)
$r = Fb "    i : BYTE;`n    n : INT;" "FOR i := 0 TO 254 BY 4 DO`n    n := n + 1;`nEND_FOR"
$d = Diags $r 'SCAN-FOR-001'
Check 'F10 BYTE 0 TO 254 BY 4 (252 + 4 wraps) -> variant step-overflow, warning, not blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'step-overflow' -and -not $d[0].blocking) (Brief $r)
$r = Fb "    i : BYTE;`n    n : INT;" "// tcauto-lint-disable-next-line SCAN-FOR-001: we really want all 256 values here`nFOR i := 0 TO 255 DO`n    n := n + 1;`nEND_FOR"
Check 'F11 inline suppression of the blocking overflow -> refused (LINT-SUPPRESS-004)' ((Diags $r 'SCAN-FOR-001')[0].blocking -and (Diags $r 'LINT-SUPPRESS-004').Count -eq 1) (Brief $r)

# ================================================================ A  SCAN-ARR-001
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;" "FOR i := 0 TO 9 DO`n    a[i] := 0;`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'A1 ARRAY[1..10], FOR i := 0 TO 9 (0-based habit) -> blocking error at the access' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].line -eq 2 -and $d[0].column -eq 5 -and $d[0].message -like '*runs 0..9, declared 1..10*' -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
$r = Fb "    a : ARRAY[0..9] OF INT;`n    i : INT;" "FOR i := 0 TO 9 DO`n    a[i] := a[i + 1];`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'A2 a[i + 1] with i 0..9 on ARRAY[0..9] -> one finding (a[i] is fine)' ($d.Count -eq 1 -and $d[0].message -like '*runs 1..10*') (Brief $r)
$gvl = { param($fx) Add-Gvl $fx 'GVL_Const' "{attribute 'qualified_only'}`nVAR_GLOBAL CONSTANT`n    cN : INT := 10;`nEND_VAR`n" }
$r = Fb "    aBuf : ARRAY[0..GVL_Const.cN - 1] OF INT;`n    i : INT;" "FOR i := 0 TO GVL_Const.cN DO`n    aBuf[i] := 0;`nEND_FOR" $gvl
$d = Diags $r 'SCAN-ARR-001'
Check 'A3 bounds and loop from a qualified_only GVL constant (0..cN - 1 vs 0 TO cN) -> blocking' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].message -like '*runs 0..10, declared 0..9*') (Brief $r)
$r = Fb "    m : ARRAY[1..3, 1..4] OF INT;`n    i : INT;" "FOR i := 1 TO 4 DO`n    m[i, 1] := m[1, i];`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'A4 two dimensions: m[i, 1] leaves dimension 1 (1..3), m[1, i] is fine -> one finding' ($d.Count -eq 1 -and $d[0].message -like '*dimension 1*') (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;" "FOR i := 1 TO 10 DO`n    a[i] := i;`nEND_FOR"
Check 'A5 counter-example: loop inside the bounds -> no finding' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and $r.success) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'F_Sum' "FUNCTION F_Sum : INT`nVAR_IN_OUT`n    aIo : ARRAY[*] OF INT;`nEND_VAR`nVAR`n    i : DINT;`nEND_VAR`n" "FOR i := LOWER_BOUND(aIo, 1) TO UPPER_BOUND(aIo, 1) DO`n    F_Sum := F_Sum + aIo[i];`nEND_FOR`nFOR i := 0 TO 9 DO`n    aIo[i] := 0;`nEND_FOR"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$s = @(Skips $r 'SCAN-ARR-001' | ForEach-Object { $_.reason })
Check 'A6 counter-example: LOWER_BOUND / UPPER_BOUND loop and ARRAY[*] -> no finding, rulesSkipped loop-bounds-not-constant + variable-length-array' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and $s -contains 'loop-bounds-not-constant' -and $s -contains 'variable-length-array' -and $r.success) ((Brief $r) + ' ' + ($s -join ','))
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;" "FOR i := 0 TO 10 DO`n    IF i >= 1 THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'A7 access inside IF i >= 1 (guard) -> variant guarded, warning, not blocking, unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking -and $r.success -and (Unres $r 'SCAN-ARR-001').Count -eq 1) (Brief $r)
$dut = { param($fx) Write-LintFxFile (Join-Path $fx.PlcDir 'DUTs\ST_Buf.TcDUT') ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <DUT Name=`"ST_Buf`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[TYPE ST_Buf :`nSTRUCT`n    a : ARRAY[1..10] OF INT;`nEND_STRUCT`nEND_TYPE`n]]></Declaration>`n  </DUT>`n</TcPlcObject>"); $fx.Items.Add('DUTs\ST_Buf.TcDUT'); Set-LintFxCompile $fx $fx.Items.ToArray() }
$r = Fb "    st : ST_Buf;`n    i : INT;" "FOR i := 0 TO 9 DO`n    st.a[i] := 0;`nEND_FOR" $dut
Check 'A8 array of a struct member -> not evaluated (no guessing), rulesSkipped array-unknown:member' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and @(Skips $r 'SCAN-ARR-001' | Where-Object { $_.reason -eq 'array-unknown:member' }).Count -eq 1) (Brief $r)
$r = Fb "    aa : ARRAY[1..2] OF ARRAY[1..3] OF INT;`n    i : INT;" "FOR i := 0 TO 1 DO`n    aa[i][1] := 0;`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'A9 ARRAY OF ARRAY: first level evaluated (0 outside 1..2)' ($d.Count -eq 1) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;" "FOR i := 0 TO 9 DO`n    a[i] := 0;`n    i := i + 1;`nEND_FOR"
Check 'A10 counter written in the body -> no SCAN-ARR finding, rulesSkipped counter-written-in-body' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and @(Skips $r 'SCAN-ARR-001' | Where-Object { $_.reason -like 'counter-written-in-body*' }).Count -eq 1) (Brief $r)

# ================================================================ C  SAFETY-ARR-001
$r = Fb "    a : ARRAY[1..10] OF INT;" "a[11] := 0;`na[0] := 1;"
$d = Diags $r 'SAFETY-ARR-001'
Check 'C1 a[11] and a[0] on ARRAY[1..10] -> 2 errors, not blocking (compiler C0049), not unresolved, pass' ($d.Count -eq 2 -and -not $d[0].blocking -and $d[0].severity -eq 'error' -and (Unres $r 'SAFETY-ARR-001').Count -eq 0 -and $r.success) (Brief $r)
$r = Fb "    a : ARRAY[0..cMax] OF INT;`nEND_VAR`nVAR CONSTANT`n    cMax : INT := 4;`n    cIdx : INT := cMax + 1;" "a[cIdx] := 0;"
Check 'C2 constant index from VAR CONSTANT arithmetic (cMax + 1) on ARRAY[0..cMax] -> finding' ((Diags $r 'SAFETY-ARR-001').Count -eq 1) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    n : INT;`n    s : STRING(80);" "a[10] := 0;`na[n] := 1;`ns[1] := 65;"
Check 'C3 counter-examples: index in range, variable index, STRING(80) is not an array -> no finding' ((Diags $r 'SAFETY-ARR-001').Count -eq 0 -and $r.success) (Brief $r)

# ================================================================ V  SAFETY-DIV-001
$r = Fb "    x : INT;" "x := x / 0;"
$d = Diags $r 'SAFETY-DIV-001'
Check 'V1 x / 0 -> constant-zero-div, blocking, compilerCatches yes on the finding, not unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'constant-zero-div' -and $d[0].blocking -and $d[0].compilerCatches -eq 'yes' -and (Unres $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : INT;" "x := x MOD 0;"
$d = Diags $r 'SAFETY-DIV-001'
Check 'V2 x MOD 0 -> constant-zero-mod, blocking, compiler does not catch it -> unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'constant-zero-mod' -and $d[0].blocking -and $null -eq $d[0].compilerCatches -and (Unres $r 'SAFETY-DIV-001').Count -eq 1) (Brief $r)
$r = Fb "    fR : REAL;" "fR := fR / 0.0;"
Check 'V3 fR / 0.0 -> constant-zero-div' ((Diags $r 'SAFETY-DIV-001').Count -eq 1 -and (Diags $r 'SAFETY-DIV-001')[0].variant -eq 'constant-zero-div') (Brief $r)
$r = Fb "    x : INT;`nEND_VAR`nVAR CONSTANT`n    cZero : INT := 0;" "x := x / cZero;"
$d = Diags $r 'SAFETY-DIV-001'
Check 'V4 / named constant 0 -> constant-zero-div, blocking, compilerCatches not claimed (not measured)' ($d.Count -eq 1 -and $d[0].blocking -and $null -eq $d[0].compilerCatches) (Brief $r)
$r = Fb "    x : INT;`n    y : INT;`n    nDiv : INT;" "x := y / nDiv;"
$d = Diags $r 'SAFETY-DIV-001'
Check 'V5 y / nDiv without a test -> unchecked-variable-divisor, info, medium, not blocking, pass, not unresolved (advisory)' ($d.Count -eq 1 -and $d[0].variant -eq 'unchecked-variable-divisor' -and $d[0].severity -eq 'info' -and $d[0].confidence -eq 'medium' -and -not $d[0].blocking -and $r.success -and (Unres $r 'SAFETY-DIV-001').Count -eq 0 -and -not $r.data.requiresDisposition) (Brief $r)
$r = Fb "    x : INT;`n    y : INT;`n    nDiv : INT;" "IF nDiv <> 0 THEN`n    x := y / nDiv;`nEND_IF"
Check 'V6 counter-example: IF nDiv <> 0 -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    fR : REAL;`n    fA : REAL;`n    fDiv : REAL;" "IF fDiv > 0.0 THEN`n    fR := fA / fDiv;`nELSE`n    fR := 0.0;`nEND_IF"
Check 'V7 counter-example: REAL divisor tested > 0.0 -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : INT;`n    y : INT;`n    n : INT;" "IF n = 0 THEN`n    x := 0;`nELSE`n    x := y MOD n;`nEND_IF"
Check 'V8 counter-example: ELSE branch of IF n = 0 -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : INT;`n    y : INT;`n    n : INT;" "IF n = 0 THEN`n    RETURN;`nEND_IF`nx := y / n;"
Check 'V9 counter-example: earlier IF n = 0 THEN RETURN -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : INT;`nEND_VAR`nVAR CONSTANT`n    cTen : INT := 10;" "x := x / 4 + x / cTen + x MOD 16#10;"
Check 'V10 counter-example: non-zero literal / constant divisors -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : INT;`n    y : INT;`n    nDiv : INT;" "// tcauto-lint-disable-next-line SAFETY-DIV-001: nDiv is a recipe value validated to be >= 1`nx := y / nDiv;"
$d = Diags $r 'SAFETY-DIV-001'
Check 'V11 inline suppression of the info variant (not blockable) -> suppressed, listed in newSuppressions' ($d.Count -eq 1 -and $d[0].suppressed -and (Diags $r 'LINT-SUPPRESS-004').Count -eq 0 -and @($r.data.newSuppressions).Count -eq 1) (Brief $r)
$r = Fb "    x : INT;" "// tcauto-lint-disable-next-line SAFETY-DIV-001: the modulo is never reached in practice`nx := x MOD 0;"
Check 'V12 inline suppression of MOD 0 (blocking variant) -> LINT-SUPPRESS-004, finding stays' ((Diags $r 'SAFETY-DIV-001')[0].blocking -and (Diags $r 'LINT-SUPPRESS-004').Count -eq 1) (Brief $r)
$r = Fb "    x : INT;`n    y : INT;`n    n : INT;" "IF n <> 0 AND_THEN y / n > 2 THEN`n    x := 1;`nEND_IF"
Check 'V13 counter-example: test in the same condition before the division (AND_THEN) -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)

$r = Fb "    x : LREAL;`n    y : LREAL;`n    fRatio : LREAL := 20.4013;" "x := y / fRatio;"
Check 'V14 counter-example: VAR with a non-zero initial value that no section writes (gear ratio, corpus bfh) -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : LREAL;`n    y : LREAL;`n    fIn : LREAL;`n    fRatio : LREAL := 20.4013;" "fRatio := fIn;`nx := y / fRatio;"
Check 'V15 same variable written in the POU -> reported (info)' ((Diags $r 'SAFETY-DIV-001').Count -eq 1) (Brief $r)

$r = Fb "    x : LREAL;`n    nFull : INT;`n    nZero : INT;`n    fSpan : LREAL;" "IF nFull <> nZero THEN`n    fSpan := TO_LREAL(nFull - nZero);`n    x := 4.0 / fSpan;`nEND_IF"
Check 'V16 counter-example: divisor computed in the branch from the values its condition tests (corpus bfh FB_TensionLoadcell) -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)

# ================================================================ R  independent review (B1 B2 B3 S2 S3 S4 nit1)
# B1 VAR_INPUT CONSTANT / VAR_IN_OUT CONSTANT: the initial value is a default (CFC parameter, read-only reference), not a constant
$fx = New-Fx; Add-Pou $fx 'F_D' "FUNCTION F_D : INT`nVAR_INPUT CONSTANT`n    d : INT := 0;`nEND_VAR`n" 'F_D := 10 / d;'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj; $d = Diags $r 'SAFETY-DIV-001'
Check 'RB1a VAR_INPUT CONSTANT d := 0; 10 / d -> not a constant zero (variable divisor, info), pass' ($d.Count -eq 1 -and $d[0].variant -eq 'unchecked-variable-divisor' -and $r.success) (Brief $r)
$r = Fb "    k : BYTE;`n    n : INT;`nEND_VAR`nVAR_INPUT CONSTANT`n    nMax : BYTE := 255;" "FOR k := 0 TO nMax DO`n    n := n + 1;`nEND_FOR"
Check 'RB1b VAR_INPUT CONSTANT nMax := 255 as FOR end -> no finding, rulesSkipped end-not-constant' ((Diags $r 'SCAN-FOR-001').Count -eq 0 -and $r.success -and @(Skips $r 'SCAN-FOR-001' | Where-Object { $_.reason -eq 'end-not-constant' }).Count -eq 1) (Brief $r)
$r = Fb "    a : ARRAY[0..9] OF INT;`n    k : INT;`nEND_VAR`nVAR_INPUT CONSTANT`n    nHi : INT := 9;" "FOR k := 0 TO nHi + 1 DO`n    a[k] := 0;`nEND_FOR"
Check 'RB1c VAR_INPUT CONSTANT nHi in the loop bound -> no SCAN-ARR finding, rulesSkipped loop-bounds-not-constant' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and $r.success -and @(Skips $r 'SCAN-ARR-001' | Where-Object { $_.reason -eq 'loop-bounds-not-constant' }).Count -eq 1) (Brief $r)
$r = Fb "    a : ARRAY[0..9] OF INT;`n    k : INT;`nEND_VAR`nVAR CONSTANT`n    nHi : INT := 9;" "FOR k := 0 TO nHi + 1 DO`n    a[k] := 0;`nEND_FOR"
Check 'RB1d positive control: the same bound as VAR CONSTANT -> blocking SCAN-ARR-001' ((Diags $r 'SCAN-ARR-001').Count -eq 1 -and (Diags $r 'SCAN-ARR-001')[0].blocking) (Brief $r)
# B2 EXIT / CONTINUE of a nested loop do not leave the outer loop
$r = Fb "    bIn : BOOL;`n    j : INT;" "WHILE NOT bIn DO`n    FOR j := 1 TO 2 DO`n        EXIT;`n    END_FOR`nEND_WHILE"
Check 'RB2a WHILE NOT bIn with EXIT only in a nested FOR -> blocking busy-wait' ((Diags $r 'SCAN-LOOP-001').Count -eq 1 -and (Diags $r 'SCAN-LOOP-001')[0].blocking) (Brief $r)
$r = Fb "    j : INT;" "WHILE TRUE DO`n    FOR j := 1 TO 2 DO`n        EXIT;`n    END_FOR`nEND_WHILE"
Check 'RB2b WHILE TRUE with EXIT only in a nested FOR -> blocking' ((Diags $r 'SCAN-LOOP-001').Count -eq 1) (Brief $r)
$r = Fb "    bIn : BOOL;`n    j : INT;" "WHILE NOT bIn DO`n    FOR j := 1 TO 2 DO`n        RETURN;`n    END_FOR`nEND_WHILE"
Check 'RB2c counter-example: RETURN inside the nested FOR leaves everything -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    i : BYTE;`n    n : INT;" "FOR i := 0 TO 255 DO`n    WHILE n < 3 DO`n        n := n + 1;`n        EXIT;`n    END_WHILE`nEND_FOR"
$d = Diags $r 'SCAN-FOR-001'
Check 'RB2d FOR overflow with EXIT only in a nested WHILE -> blocking error, not exit-in-body' ($d.Count -eq 1 -and $d[0].blocking -and $null -eq $d[0].variant) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    n : INT;" "FOR i := 0 TO 9 DO`n    WHILE n < 3 DO`n        n := n + 1;`n        CONTINUE;`n    END_WHILE`n    a[i] := 0;`nEND_FOR"
Check 'RB2e CONTINUE only in a nested WHILE does not make the FOR access guarded -> blocking SCAN-ARR-001' ((Diags $r 'SCAN-ARR-001').Count -eq 1 -and (Diags $r 'SCAN-ARR-001')[0].blocking) (Brief $r)
# B3 property access is a call (Get / Set code), unresolved member types are not guessed
$fx = New-Fx; Edit-LintFxFile $fx.FbA { param($t) $t.Replace('M_Do := nValue > 0;', "WHILE P_State = 0 DO`r`n    nState := 1;`r`nEND_WHILE`r`nWHILE nState = 0 DO`r`n    P_State := 1;`r`nEND_WHILE") }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'RB3a property P_State read in the condition / written in the body (FB_A.M_Do) -> no finding, rulesSkipped property-access' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and $r.success -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'property-access' -and $_.objectPath -eq 'FB_A.M_Do' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$fx = New-Fx; Edit-LintFxFile $fx.Main { param($t) $t.Replace('fbA(bStart := GVL_Main.bRun);', "WHILE fbA.P_State = 0 DO`r`n    eMode := E_Mode.Auto;`r`nEND_WHILE") }
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'RB3b fbA.P_State (property of the instance type) in the condition -> no finding, rulesSkipped property-access' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'property-access' }).Count -eq 1) (Brief $r)
$r = Fb "    fbX : FB_NotInProject;`n    n : INT;" "WHILE NOT fbX.bDone DO`n    n := 1;`nEND_WHILE"
Check 'RB3c member of a type outside the project and catalog -> no finding, rulesSkipped member-type-unknown' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'member-type-unknown' }).Count -eq 1) (Brief $r)
# S2 compare full member paths / constant indexes
$r = Fb "    st : TON;" "WHILE NOT st.Q DO`n    st.PT := T#1S;`nEND_WHILE"
Check 'RS2a WHILE NOT st.Q, body writes only st.PT (no call) -> blocking' ((Diags $r 'SCAN-LOOP-001').Count -eq 1) (Brief $r)
$r = Fb "    arrB : ARRAY[1..2] OF BOOL;" "WHILE arrB[1] DO`n    arrB[2] := TRUE;`nEND_WHILE"
Check 'RS2b WHILE arrB[1], body writes arrB[2] -> blocking' ((Diags $r 'SCAN-LOOP-001').Count -eq 1) (Brief $r)
$r = Fb "    arrB : ARRAY[1..2] OF BOOL;`n    i : INT;" "WHILE arrB[i] DO`n    arrB[2] := TRUE;`nEND_WHILE"
Check 'RS2c variable index may be the written element -> no finding, rulesSkipped written-element-may-be-the-condition' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'written-element-may-be-the-condition' }).Count -eq 1) (Brief $r)
$r = Fb "    st : TON;" "WHILE NOT st.Q DO`n    st.Q := TRUE;`nEND_WHILE"
Check 'RS2d counter-example: body writes the same member st.Q -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
# S3 IEC standard functions do not change the condition
$r = Fb "    bIn : BOOL;`n    x : INT;" "WHILE NOT bIn DO`n    x := ABS(x);`nEND_WHILE"
Check 'RS3 body only calls ABS -> blocking' ((Diags $r 'SCAN-LOOP-001').Count -eq 1) (Brief $r)
# S4 DIV / MOD function form
$r = Fb "    x : INT;`n    y : INT;" "x := DIV(y, 0);`ny := MOD(x, 0);"
$d = Diags $r 'SAFETY-DIV-001'
Check 'RS4a DIV(y, 0) / MOD(x, 0) -> constant-zero-div / -mod, blocking, compilerCatches not claimed' ($d.Count -eq 2 -and @($d | Where-Object { $_.variant -eq 'constant-zero-div' }).Count -eq 1 -and @($d | Where-Object { $_.variant -eq 'constant-zero-mod' }).Count -eq 1 -and @($d | Where-Object { $null -ne $_.compilerCatches }).Count -eq 0 -and $d[0].blocking) (Brief $r)
$r = Fb "    x : INT;`n    y : INT;`n    n : INT;" "x := DIV(y, n);"
Check 'RS4b DIV(y, n) -> unchecked-variable-divisor (info)' ((Diags $r 'SAFETY-DIV-001').Count -eq 1 -and (Diags $r 'SAFETY-DIV-001')[0].variant -eq 'unchecked-variable-divisor') (Brief $r)
# nit1 compilerCatches yes only for the measured literals 0 / 0.0
$r = Fb "    x : DINT;" "x := x / 16#0;`nx := x / (0);`nx := x / DINT#0;`nx := x / -0;"
$d = Diags $r 'SAFETY-DIV-001'
Check 'RN1 / 16#0, / (0), / DINT#0, / -0 -> constant-zero-div, blocking, no compilerCatches yes' ($d.Count -eq 4 -and @($d | Where-Object { $_.compilerCatches -eq 'yes' }).Count -eq 0 -and @($d | Where-Object { $_.blocking }).Count -eq 4) (Brief $r)

# ================================================================ M  metadata
foreach ($id in 'SCAN-LOOP-001', 'SCAN-FOR-001', 'SCAN-ARR-001', 'SAFETY-ARR-001', 'SAFETY-DIV-001') {
    $m = @(& $mod { param($i) $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get($i) } $id)[0]
    Check "M $id registered, phase 2, limits written" ($null -ne $m -and $m.Phase -eq '2' -and $m.Limits.Length -gt 100 -and $m.MachineImpact -eq 'crash') "$($m.Phase) $($m.Blockable) $($m.CompilerCatches) $($m.Te1200)"
}
$m = @(& $mod { $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get('SAFETY-ARR-001') })[0]
Check 'M SAFETY-ARR-001: blockable false, compilerCatches yes, TE1200 SA0172 (Full)' ($m.Blockable -eq 'false' -and $m.CompilerCatches -eq 'yes' -and $m.Te1200 -like 'SA0172*') ''
$m = @(& $mod { $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get('SCAN-FOR-001') })[0]
Check 'M SCAN-FOR-001: compilerCatches warning (C0266, build succeeds)' ($m.CompilerCatches -eq 'warning' -and $m.Blockable -eq 'true') ''

# ================================================================ D  determinism
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    a : ARRAY[1..10] OF INT;`n    i : BYTE;`n    b : BOOL;`n    n : INT;`nEND_VAR`n" "FOR i := 0 TO 255 DO`n    a[i] := n / i;`nEND_FOR`nWHILE NOT b DO`n    n := n MOD 0;`nEND_WHILE`na[12] := 0;"
$outs = foreach ($cul in 'en-US', 'zh-TW', 'en-US') {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $cul; [System.Threading.Thread]::CurrentThread.CurrentUICulture = $cul
    $x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj; $x.data.Remove('newSuppressionsBasisReason'); Js $x
}
$x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'D1 all five rules fire on one section' (@('SCAN-LOOP-001', 'SCAN-FOR-001', 'SCAN-ARR-001', 'SAFETY-ARR-001', 'SAFETY-DIV-001' | Where-Object { (Diags $x $_).Count -ge 1 }).Count -eq 5) (Brief $x)
Check 'D2 two runs and en-US / zh-TW byte-identical' ($outs[0] -ceq $outs[1] -and $outs[0] -ceq $outs[2]) ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
