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
#   Q  second independent review of PR #284: catalog-FB call in a busy-wait (B1), call-in-body / call-in-condition skips,
#      fb-wait-loop (S1), notes per condition kind (S4 / N1), guard through a variable computed from the counter (B2),
#      AND / OR are no guard but AND_THEN / OR_ELSE / SEL are (S5), DIV message (N4), certain step overflow blocks (N5)
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
Check 'L7 the body calls the TON whose output is the condition -> fb-wait-loop warning (second review S1)' ((Diags $r 'SCAN-LOOP-001').Count -eq 1 -and (Diags $r 'SCAN-LOOP-001')[0].variant -eq 'fb-wait-loop' -and -not (Diags $r 'SCAN-LOOP-001')[0].blocking) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    bDone : BOOL;`n    n : INT;`nEND_VAR`n" "WHILE NOT bDone DO`n    THIS^.M_Step();`nEND_WHILE`nREPEAT`n    n := n + 1;`nUNTIL M_Ready()`nEND_REPEAT" (Method 'M_Step' "METHOD M_Step`n" 'bDone := TRUE;')
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$s = @(Skips $r 'SCAN-LOOP-001' | ForEach-Object { $_.reason })
Check 'L8 counter-example: method call in the body; call in the UNTIL condition -> no finding, both in rulesSkipped' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and $s -contains 'call-in-body' -and $s -contains 'call-in-condition') ((Brief $r) + ' ' + ($s -join ','))
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
Check 'F10 BYTE 0 TO 254 BY 4 (252 + 4 wraps) -> variant step-overflow, blocking (second review N5)' ($d.Count -eq 1 -and $d[0].variant -eq 'step-overflow' -and $d[0].blocking) (Brief $r)
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

# ================================================================ Q  second independent review of PR #284 (B1 B2 S1 S4 S5 N1 N4 N5)
# B1 a call in the body no longer hides a busy-wait: catalog FBs / IEC functions that do not get a condition variable cannot change it
$r = Fb "    bDone : BOOL;`n    rt : R_TRIG;`n    n : INT;" "WHILE NOT bDone DO`n    rt(CLK := TRUE);`n    n := n + 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'QB1a WHILE NOT bDone, body only calls the catalog FB rt (R_TRIG) -> blocking' ($d.Count -eq 1 -and $d[0].blocking -and $null -eq $d[0].variant -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
$r = Fb "    bIn AT %IX0.0 : BOOL;`n    tonX : TON;" "WHILE NOT bIn DO`n    tonX(IN := TRUE, PT := T#1S);`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'QB1b WHILE NOT bIn (AT %IX), body calls TON tonX -> blocking, message cites the task cycle order (InfoSys 6828869003)' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].message -like '*6828869003*') (Brief $r)
$fn = { param($fx) Add-Pou $fx 'F_Other' "FUNCTION F_Other : BOOL`n" 'F_Other := TRUE;' }
$r = Fb "    b : BOOL;`n    n : INT;" "WHILE NOT b DO`n    F_Other();`n    n := n + 1;`nEND_WHILE" $fn
Check 'QB1c project function in the body -> not blocking, rulesSkipped call-in-body (not silent)' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and $r.success -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    b : BOOL;`n    rt : R_TRIG;" "WHILE NOT b DO`n    rt(CLK := b);`nEND_WHILE"
# issue #286 N5: an input (:=) of a Tc2_Standard stateful FB is VAR_INPUT (by value, no VAR_IN_OUT; InfoSys CTUD 74402059 and the
# TypeCatalog.json source pages): the call cannot write the variable -> the busy-wait is reported (was call-in-body)
Check 'QB1d / I-N5a condition variable given only to an input of R_TRIG -> blocking busy-wait, no call-in-body' ((Diags $r 'SCAN-LOOP-001').Count -eq 1 -and (Diags $r 'SCAN-LOOP-001')[0].blocking -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 0) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    b : BOOL;`n    fbT : TON;" "WHILE NOT b DO`n    fbT(IN := NOT b AND TRUE, PT := T#10MS);`nEND_WHILE"
Check 'I-N5b condition variable in an input expression of TON -> blocking busy-wait' ((Diags $r 'SCAN-LOOP-001').Count -eq 1 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 0) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    b : BOOL;`n    mc : MC_MoveAbsolute;`n    ax : AXIS_REF;" "WHILE NOT b DO`n    mc(Axis := ax, Execute := b);`nEND_WHILE"
Check 'I-N5c condition variable given to a Tc2_MC2 FB (parameter directions not in the catalog, Axis is VAR_IN_OUT) -> still call-in-body' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    b : BOOL;`n    rt : R_TRIG;`n    p : POINTER TO BOOL;" "WHILE NOT b DO`n    rt(CLK := b);`n    p := ADR(b);`nEND_WHILE"
Check 'I-N5d input of R_TRIG plus ADR(b) in the body -> still call-in-body' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    b : BOOL;`n    p : POINTER TO BOOL;`n    rt : R_TRIG;" "WHILE NOT b DO`n    p := ADR(b);`n    rt(CLK := TRUE);`nEND_WHILE"
Check 'QB1e ADR(condition variable) in the body -> not blocking, rulesSkipped call-in-body' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    b : BOOL;`n    rt : R_TRIG;" "WHILE NOT b DO`n    rt(CLK := TRUE, Q => b);`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'QB1f / R3-S1b the condition is fed only by the catalog FB it calls (Q => b) -> fb-wait-loop warning (review 3: was silent)' ($d.Count -eq 1 -and $d[0].variant -eq 'fb-wait-loop' -and -not $d[0].blocking) (Brief $r)
# review 3 S1a / S1h: the condition is written from the FB output in the body
$r = Fb "    bDone : BOOL;`n    ton1 : TON;" "WHILE NOT bDone DO`n    ton1(IN := TRUE, PT := T#1S);`n    bDone := ton1.Q;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'R3S1a bDone := ton1.Q in the body -> fb-wait-loop warning' ($d.Count -eq 1 -and $d[0].variant -eq 'fb-wait-loop' -and -not $d[0].blocking -and (Unres $r 'SCAN-LOOP-001').Count -eq 1) (Brief $r)
$r = Fb "    bDone : BOOL;`n    ton1 : TON;" "WHILE NOT bDone DO`n    ton1(IN := TRUE, PT := T#1S);`n    IF ton1.Q THEN`n        bDone := TRUE;`n    END_IF`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'R3S1h IF ton1.Q THEN bDone := TRUE -> fb-wait-loop warning' ($d.Count -eq 1 -and $d[0].variant -eq 'fb-wait-loop') (Brief $r)
$r = Fb "    bDone : BOOL;`n    ton1 : TON;`n    n : INT;" "WHILE NOT bDone DO`n    ton1(IN := TRUE, PT := T#1S);`n    n := n + 1;`n    bDone := n > 10;`nEND_WHILE"
Check 'R3S1 counter-example: the condition is written from a counter -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$fn2 = { param($fx) Add-Pou $fx 'F_Ready' "FUNCTION F_Ready : BOOL`n" 'F_Ready := TRUE;' }
$r = Fb "    n : INT;" "WHILE NOT F_Ready() DO`n    n := n + 1;`nEND_WHILE" $fn2
Check 'QB1g call in the condition -> no finding, rulesSkipped call-in-condition' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-condition' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    bIn : BOOL;`n    rt : R_TRIG;`n    r : REFERENCE TO BOOL;" "WHILE NOT bIn DO`n    r REF= bIn;`n    rt(CLK := TRUE);`nEND_WHILE"
Check 'QB1h REF= on the condition variable with a catalog call -> not blocking, recorded in rulesSkipped' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and (Skips $r 'SCAN-LOOP-001').Count -ge 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
# S1 waiting for a function block inside one cycle
$r = Fb "    mc : MC_MoveAbsolute;`n    ax : AXIS_REF;" "WHILE NOT mc.Done DO`n    mc(Axis := ax, Execute := TRUE, Position := 10.0);`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'QS1a WHILE NOT mc.Done DO mc(...) (MC_MoveAbsolute) -> variant fb-wait-loop, warning, not blocking, unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'fb-wait-loop' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and $r.success -and $r.data.requiresDisposition -and (Unres $r 'SCAN-LOOP-001').Count -eq 1) (Brief $r)
$fbp = { param($fx) Add-Pou $fx 'FB_P' "FUNCTION_BLOCK FB_P`nVAR_OUTPUT`n    bDone : BOOL;`nEND_VAR`n" 'bDone := TRUE;' }
$r = Fb "    fbP : FB_P;" "WHILE NOT fbP.bDone DO`n    fbP();`nEND_WHILE" $fbp
Check 'QS1b project FB called in the loop that waits for its output -> no finding, rulesSkipped call-in-body' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    fbT : TON;`n    pX : POINTER TO TON;" "WHILE NOT fbT.Q DO`n    fbT(IN := TRUE, PT := T#1S);`n    pX^.Q := FALSE;`nEND_WHILE"
Check 'QS1c fb-wait-loop with a pointer write in the body -> not reported, rulesSkipped pointer-write' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'pointer-write' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
$r = Fb "    fbT : TON;" "WHILE NOT fbT.Q DO`n    fbT(IN := TRUE, PT := T#1S);`n    fbT.M_X();`nEND_WHILE"
Check 'QS1d a member call on the waited instance (fbT.M_X()) -> not reported, rulesSkipped call-in-body' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and @(Skips $r 'SCAN-LOOP-001' | Where-Object { $_.reason -eq 'call-in-body' }).Count -eq 1) ((Brief $r) + ' ' + (Js (Skips $r 'SCAN-LOOP-001')))
# N1 the note follows the kind of the condition
$gv = { param($fx) Add-Gvl $fx 'GVL_X' "VAR_GLOBAL`n    nRun : INT;`nEND_VAR`n" }
$r = Fb "    n : INT;" "WHILE GVL_X.nRun = 0 DO`n    n := n + 1;`nEND_WHILE" $gv
$d = Diags $r 'SCAN-LOOP-001'
Check 'QN1 GVL variable in the condition -> blocking, message does not call it a function block output' ($d.Count -eq 1 -and $d[0].message -notlike '*function block*' -and $d[0].message -notlike '*input*') (Brief $r)
$r = Fb "    fbT : TON;`n    nX : INT;" "WHILE NOT fbT.Q DO`n    nX := 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'QN1b FB output, FB not called -> message says the block is not called in the loop' ($d.Count -eq 1 -and $d[0].message -like '*function block*fbT*') (Brief $r)
# B2 guard through a variable computed from the counter
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    b : BOOL;" "FOR i := 0 TO 10 DO`n    b := i > 0;`n    IF b THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'QB2a b := i > 0; IF b THEN a[i] -> variant guarded, warning, not blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking -and $r.success) (Brief $r)
$dutG = { param($fx) Write-LintFxFile (Join-Path $fx.PlcDir 'DUTs\ST_G.TcDUT') ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <DUT Name=`"ST_G`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[TYPE ST_G :`nSTRUCT`n    bOk : BOOL;`nEND_STRUCT`nEND_TYPE`n]]></Declaration>`n  </DUT>`n</TcPlcObject>"); $fx.Items.Add('DUTs\ST_G.TcDUT'); Set-LintFxCompile $fx $fx.Items.ToArray() }
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    st : ST_G;" "FOR i := 0 TO 10 DO`n    st.bOk := i > 0;`n    IF st.bOk THEN`n        a[i] := 0;`n    END_IF`nEND_FOR" $dutG
$d = Diags $r 'SCAN-ARR-001'
Check 'R3B2e guard through a structure member computed from i (st.bOk := i > 0) -> not blocking' (@($d | Where-Object { $_.blocking }).Count -eq 0) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    b : BOOL;`n    bEn : BOOL;" "FOR i := 0 TO 10 DO`n    b := i > 0;`n    b := bEn;`n    IF b THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R3B2b the guard variable is overwritten unconditionally from an unrelated value -> blocking again' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    b : BOOL;`n    bEn : BOOL;" "FOR i := 0 TO 10 DO`n    b := i > 0;`n    IF bEn THEN`n        b := FALSE;`n    END_IF`n    IF b THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R3B2b counter-example: a conditional overwrite keeps the guard -> not blocking' (@($d | Where-Object { $_.blocking }).Count -eq 0) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    bOk : BOOL;" "FOR i := 0 TO 10 DO`n    bOk := FALSE;`n    IF i > 0 THEN`n        bOk := TRUE;`n    END_IF`n    IF bOk THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R4B2i guard flag set inside IF i > 0 (control dependence) -> not blocking' (@($d | Where-Object { $_.blocking }).Count -eq 0) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    b : BOOL;" "FOR i := 0 TO 10 DO`n    CASE i OF`n        0: b := FALSE;`n    ELSE`n        b := TRUE;`n    END_CASE`n    IF b THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R4B2q guard flag set in CASE i OF -> not blocking' (@($d | Where-Object { $_.blocking }).Count -eq 0) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    b : BOOL;`n    x : INT;" "FOR i := 0 TO 10 DO`n    IF x > 0 THEN`n        b := TRUE;`n    END_IF`n    IF b THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R4B2 counter-example: flag set under a condition unrelated to i -> still blocking' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
$r = Fb "    bDone : BOOL;`n    ton1 : TON;`n    n : INT;" "WHILE NOT bDone DO`n    ton1(IN := TRUE, PT := T#1S);`n    IF ton1.Q THEN`n        n := 1;`n    ELSE`n        bDone := TRUE;`n    END_IF`nEND_WHILE"
Check 'R4nit1 write in the ELSE branch of IF ton1.Q -> no fb-wait-loop' (@(Diags $r 'SCAN-LOOP-001' | Where-Object { $_.variant -eq 'fb-wait-loop' }).Count -eq 0) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    k : INT;`n    b : BOOL;" "FOR i := 0 TO 10 DO`n    k := i * 2;`n    b := k > 1;`n    CASE b OF`n    TRUE: a[i] := 0;`n    END_CASE`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'QB2b transitive (k := i * 2; b := k > 1; CASE b) -> guarded, not blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    x : INT;" "FOR i := 0 TO 10 DO`n    x := 5;`n    IF x > 0 THEN`n        a[i] := 0;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'QB2c IF x > 0 with x not computed from i -> still blocking' ($d.Count -eq 1 -and $d[0].blocking -and $null -eq $d[0].variant) (Brief $r)
$r = Fb "    a : ARRAY[1..10] OF INT;`n    i : INT;`n    b : BOOL;" "FOR i := 0 TO 10 DO`n    IF b THEN`n        a[i] := 0;`n    END_IF`n    b := i > 0;`nEND_FOR"
Check 'QB2d b computed from i only after the access -> still blocking' ((Diags $r 'SCAN-ARR-001').Count -eq 1 -and (Diags $r 'SCAN-ARR-001')[0].blocking) (Brief $r)
# S5 AND / OR evaluate every operand (InfoSys AND_THEN 2528923787)
$r = Fb "    x : INT;`n    d : INT;`n    b : BOOL;" "IF d <> 0 AND x / d > 3 THEN`n    b := TRUE;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'QS5a IF d <> 0 AND x / d > 3 -> unchecked-variable-divisor (AND does not short-circuit)' ($d.Count -eq 1 -and $d[0].variant -eq 'unchecked-variable-divisor') (Brief $r)
$r = Fb "    d : DINT;`n    x : DINT;`n    b : BOOL;`n    y : DINT;" "IF d <> 0 OR_ELSE x / d > 3 THEN`n    b := TRUE;`nEND_IF`ny := SEL(d <> 0, x / d, 0);"
Check 'R3S5e/f wrong direction: d <> 0 OR_ELSE x / d; SEL(d <> 0, x / d (IN0), 0) -> two findings' ((Diags $r 'SAFETY-DIV-001').Count -eq 2) (Brief $r)
$r = Fb "    d : DINT;`n    x : DINT;`n    b : BOOL;`n    y : DINT;" "IF d = 0 OR_ELSE x / d > 3 THEN`n    b := TRUE;`nEND_IF`ny := SEL(d <> 0, 0, x / d);`nIF d <> 0 AND_THEN x / d > 1 THEN`n    b := FALSE;`nEND_IF"
Check 'R3S5 counter-examples: d = 0 OR_ELSE x / d; SEL(d <> 0, 0, x / d (IN1)); d <> 0 AND_THEN -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : INT;`n    d : INT;`n    b : BOOL;" "b := d <> 0 AND x / d > 3;`nb := d = 0 OR x / d > 3;"
Check 'QS5b same statement with AND / OR -> two findings' ((Diags $r 'SAFETY-DIV-001').Count -eq 2) (Brief $r)
$r = Fb "    x : INT;`n    d : INT;`n    b : BOOL;" "b := d = 0 OR_ELSE x / d > 3;`nx := SEL(d = 0, x / d, 0);`nIF d <> 0 THEN`n    IF x / d > 3 AND b THEN`n        b := FALSE;`n    END_IF`nEND_IF"
Check 'QS5c counter-examples: OR_ELSE, SEL, nested IF -> no finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 0) (Brief $r)
$r = Fb "    x : INT;`n    d : INT;" "WHILE d <> 0 AND x / d > 1 DO`n    d := d - 1;`nEND_WHILE"
Check 'QS5d WHILE d <> 0 AND x / d -> finding' ((Diags $r 'SAFETY-DIV-001').Count -eq 1) (Brief $r)
# N4 DIV message cites the permitted types
$r = Fb "    x : INT;" "x := x / 0;"
$d = Diags $r 'SAFETY-DIV-001'
Check 'QN4 constant-zero-div message: InfoSys DIV lists REAL / LREAL, not "not described"' ($d.Count -eq 1 -and $d[0].message -like '*REAL*LREAL*' -and $d[0].message -notlike '*not described*') (Brief $r)
# N5 a step that jumps over the type limit overflows for certain (FOR 2528280971: incremented after each pass, checked before)
$r = Fb "    i : BYTE;`n    n : INT;" "FOR i := 0 TO 254 BY 2 DO`n    n := n + 1;`nEND_FOR"
$d = Diags $r 'SCAN-FOR-001'
Check 'QN5a BYTE 0 TO 254 BY 2 -> step-overflow, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'step-overflow' -and $d[0].blocking -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
$r = Fb "    i : BYTE;`n    n : INT;" "FOR i := 0 TO 253 BY 2 DO`n    n := n + 1;`nEND_FOR`nFOR i := 0 TO 254 BY 3 DO`n    n := n + 1;`nEND_FOR"
Check 'QN5b counter-examples 0 TO 253 BY 2, 0 TO 254 BY 3 -> no finding' ((Diags $r 'SCAN-FOR-001').Count -eq 0) (Brief $r)
$r = Fb "    i : BYTE;`n    b : BOOL;" "FOR i := 0 TO 254 BY 2 DO`n    IF b THEN EXIT; END_IF`nEND_FOR"
$d = Diags $r 'SCAN-FOR-001'
Check 'QN5c step-overflow with EXIT -> warning, not blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'step-overflow,exit-in-body' -and -not $d[0].blocking) (Brief $r)

# ================================================================ I  issue #286 (fifth review of PR #284: should-fix S1-S9, nits)
function SkipR($r, [string]$Rule) { return @(Skips $r $Rule | ForEach-Object { $_.reason }) }
# S1 bit access writes the variable
$r = Fb "    nW : WORD;" "WHILE nW = 0 DO`n    nW.3 := TRUE;`nEND_WHILE"
Check 'I-S1a WHILE nW = 0 DO nW.3 := TRUE -> the bit write writes nW, no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and $r.success) (Brief $r)
$r = Fb "    nW : WORD;`n    n : INT;" "WHILE nW = 0 DO`n    n.3 := TRUE;`nEND_WHILE"
Check 'I-S1b positive control: bit write of another variable -> still blocking' ((Diags $r 'SCAN-LOOP-001').Count -eq 1 -and (Diags $r 'SCAN-LOOP-001')[0].blocking) (Brief $r)
# S3 small non-zero reals are not 0
$r = Fb "    x : LREAL;`n    y : LREAL;`nEND_VAR`nVAR CONSTANT`n    cEps : LREAL := 1E-30;`n    cS : LREAL := 1E-15 * 1E-15;" "x := y / cEps;`nx := y / 1.0E-30;`nx := y / 1.5E-29;`nx := y / cS;"
Check 'I-S3 / 1E-30 (constant, literal, 1.5E-29, 1E-15 * 1E-15) -> not a division by 0' (@((Diags $r 'SAFETY-DIV-001') | ForEach-Object { $_ } | Where-Object { $_.variant -like 'constant-zero*' }).Count -eq 0 -and $r.success) (Brief $r)
# S4 named constant 0 under a test of the constant
$r = Fb "    x : INT;`n    y : INT;`nEND_VAR`nVAR CONSTANT`n    cFilt : INT := 0;" "IF cFilt <> 0 THEN`n    x := y / cFilt;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'I-S4 IF cFilt <> 0 THEN y / cFilt (cFilt = 0) -> warning guarded-constant-zero, not blocking, pass' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded-constant-zero' -and -not $d[0].blocking -and $d[0].severity -eq 'warning' -and $r.success) (Brief $r)
# S5 SCAN-ARR-001 guards in the same expression follow the short-circuit rules
$r = Fb "    a : ARRAY[0..9] OF INT;`n    i : INT;`n    n : INT;" "FOR i := 0 TO 10 DO`n    n := n + SEL(i <= 9, 0, a[i]);`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'I-S5a SEL(i <= 9, 0, a[i]) -> guarded warning, not blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking -and $r.success) (Brief $r)
$r = Fb "    a : ARRAY[0..9] OF INT;`n    i : INT;`n    b : BOOL;" "FOR i := 0 TO 10 DO`n    b := i <= 9 AND_THEN a[i] > 0;`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'I-S5b b := i <= 9 AND_THEN a[i] > 0 -> guarded warning, not blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking) (Brief $r)
$r = Fb "    a : ARRAY[0..9] OF INT;`n    i : INT;`n    b : BOOL;" "FOR i := 0 TO 10 DO`n    IF i <= 9 AND a[i] > 0 THEN`n        b := TRUE;`n    END_IF`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'I-S5c IF i <= 9 AND a[i] > 0 (AND evaluates every operand, reads a[10]) -> blocking' ($d.Count -eq 1 -and $d[0].blocking -and $null -eq $d[0].variant) (Brief $r)
# S7 a formal parameter with the counter's name is not a write of the counter
$fbc = { param($fx) Add-Pou $fx 'FB_C' "FUNCTION_BLOCK FB_C`nVAR_INPUT`n    nIndex : INT;`nEND_VAR`n" 'nIndex := nIndex;' }
$r = Fb "    a : ARRAY[0..9] OF INT;`n    nIndex : INT;`n    fbC : FB_C;" "FOR nIndex := 0 TO 10 DO`n    fbC(nIndex := nIndex);`n    a[nIndex] := 0;`nEND_FOR" $fbc
Check 'I-S7a fbC(nIndex := nIndex) in FOR nIndex -> SCAN-ARR-001 blocking, no counter-written-in-body' ((Diags $r 'SCAN-ARR-001').Count -eq 1 -and (Diags $r 'SCAN-ARR-001')[0].blocking -and @(SkipR $r 'SCAN-ARR-001' | Where-Object { $_ -like 'counter-written*' }).Count -eq 0) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-ARR-001') -join ','))
$fbc2 = { param($fx) Add-Pou $fx 'FB_C' "FUNCTION_BLOCK FB_C`nVAR_INPUT`n    nIndex : BYTE;`nEND_VAR`n" 'nIndex := nIndex;' }
$r = Fb "    nIndex : BYTE;`n    fbC : FB_C;" "FOR nIndex := 0 TO 255 DO`n    fbC(nIndex := nIndex);`nEND_FOR" $fbc2
Check 'I-S7b BYTE 0 TO 255 with fbC(nIndex := nIndex) -> SCAN-FOR-001 blocking' ((Diags $r 'SCAN-FOR-001').Count -eq 1 -and (Diags $r 'SCAN-FOR-001')[0].blocking) (Brief $r)
# S9 write through a REFERENCE member of a structure
$dutR = { param($fx) Write-LintFxFile (Join-Path $fx.PlcDir 'DUTs\ST_R.TcDUT') ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <DUT Name=`"ST_R`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[TYPE ST_R :`nSTRUCT`n    r : REFERENCE TO BOOL;`nEND_STRUCT`nEND_TYPE`n]]></Declaration>`n  </DUT>`n</TcPlcObject>"); $fx.Items.Add('DUTs\ST_R.TcDUT'); Set-LintFxCompile $fx $fx.Items.ToArray() }
$r = Fb "    b : BOOL;`n    st : ST_R;" "st.r REF= b;`nWHILE NOT b DO`n    st.r := TRUE;`nEND_WHILE" $dutR
Check 'I-S9 st.r := TRUE with ST_R.r : REFERENCE TO BOOL -> no finding, rulesSkipped possible-alias' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and (SkipR $r 'SCAN-LOOP-001') -contains 'possible-alias') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
# S2 the condition is written only from values that do not change in the loop (owner decision in #286)
$r = Fb "    bSensor : BOOL;`n    bIn AT %IX0.0 : BOOL;" "bSensor := bIn;`nWHILE NOT bSensor DO`n    bSensor := bIn;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'I-S2a bSensor := bIn (AT %IX) in the body -> invariant-input-write warning (InfoSys order not stated: not verified), in unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-input-write' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and (Unres $r 'SCAN-LOOP-001').Count -eq 1 -and $r.data.requiresDisposition -and $d[0].message -like '*6828869003*') (Brief $r)
$r = Fb "    bBusy : BOOL;`n    fbT : TON;" "WHILE NOT bBusy DO`n    bBusy := fbT.Q;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'I-S2b bBusy := fbT.Q, fbT not called in the loop -> invariant-write, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-write' -and $d[0].blocking -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
$gvIo = { param($fx) Add-Gvl $fx 'GVL_Io' "VAR_GLOBAL`n    bStart AT %IX1.0 : BOOL;`nEND_VAR`n" }
$r = Fb "    bOk : BOOL;" "WHILE NOT bOk DO`n    bOk := GVL_Io.bStart;`nEND_WHILE" $gvIo
$d = Diags $r 'SCAN-LOOP-001'
Check 'I-S2c bOk := GVL_Io.bStart (AT %I in a GVL) -> invariant-input-write warning' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-input-write' -and -not $d[0].blocking) (Brief $r)
$r = Fb "    bDone : BOOL;`n    bOther : BOOL;`n    n : INT;`nEND_VAR`nVAR CONSTANT`n    cOn : BOOL := FALSE;" "WHILE NOT bDone DO`n    n := n + 1;`n    bDone := cOn OR bOther;`n    IF bOther THEN`n        bDone := TRUE;`n    END_IF`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'I-S2d constant / unwritten variable / literal under an invariant IF -> invariant-write, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-write' -and $d[0].blocking) (Brief $r)
# S2 counter-examples: no finding
$r = Fb "    bFound : BOOL;`n    i : INT;`n    arr : ARRAY[0..9] OF INT;`n    nKey : INT;" "i := 0;`nWHILE NOT bFound DO`n    bFound := arr[i] = nKey;`n    i := i + 1;`nEND_WHILE"
Check 'I-S2e counter-example: search loop bFound := arr[i] = nKey; i := i + 1 -> no SCAN-LOOP finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    bDone : BOOL;`n    x : INT;" "WHILE NOT bDone DO`n    bDone := x > 5;`n    x := x + 1;`nEND_WHILE"
Check 'I-S2f counter-example: source written in the loop -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) (Brief $r)
$r = Fb "    bDone : BOOL;`n    bX : BOOL;`n    ton1 : TON;" "WHILE NOT bDone DO`n    ton1(IN := TRUE, PT := T#1S);`n    bDone := ton1.Q AND bX;`nEND_WHILE"
Check 'I-S2g counter-example: source is the output of a block the loop calls -> no invariant finding' (@((Diags $r 'SCAN-LOOP-001') | ForEach-Object { $_ } | Where-Object { $_.variant -like 'invariant*' }).Count -eq 0) (Brief $r)
$fnR = { param($fx) Add-Pou $fx 'F_Ready' "FUNCTION F_Ready : BOOL`n" 'F_Ready := TRUE;' }
$r = Fb "    bDone : BOOL;" "WHILE NOT bDone DO`n    bDone := F_Ready();`nEND_WHILE" $fnR
Check 'I-S2h counter-example: source is a function result -> no finding, rulesSkipped' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and (SkipR $r 'SCAN-LOOP-001').Count -ge 1) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
$r = Fb "    bDone : BOOL;`n    bX : BOOL;`n    refB : REFERENCE TO BOOL;" "refB REF= bX;`nWHILE NOT bDone DO`n    bDone := refB;`nEND_WHILE"
Check 'I-S2i counter-example: source through a REFERENCE -> no finding, rulesSkipped possible-alias' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and (SkipR $r 'SCAN-LOOP-001') -contains 'possible-alias') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
$r = Fb "    bDone : BOOL;`n    bX : BOOL;`n    pB : POINTER TO BOOL;" "WHILE NOT bDone DO`n    bDone := pB^;`nEND_WHILE"
Check 'I-S2j counter-example: source through a POINTER -> no finding, rulesSkipped possible-alias' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and (SkipR $r 'SCAN-LOOP-001') -contains 'possible-alias') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
# PR #289 review 1 (worker G): guard direction for S4 / S5, GVL source for S2, source written in the loop
$cfv = "    x : REAL;`n    y : REAL;`nEND_VAR`nVAR CONSTANT`n    cF : REAL := 0.0;"
$r = Fb $cfv "IF cF = 0 THEN`n    y := x / cF;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'R1a IF cF = 0 THEN y / cF (the test does not exclude 0) -> constant-zero-div blocking' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].variant -ne 'guarded-constant-zero') (Brief $r)
$r = Fb $cfv "IF cF = 0 THEN`n    y := 0;`nELSE`n    y := x / cF;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'R1b ELSE of IF cF = 0 -> guarded-constant-zero warning' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded-constant-zero' -and -not $d[0].blocking) (Brief $r)
$r = Fb $cfv "IF NOT (cF = 0) THEN`n    y := x / cF;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'R1c IF NOT (cF = 0) THEN -> guarded-constant-zero warning' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded-constant-zero' -and -not $d[0].blocking) (Brief $r)
$r = Fb $cfv "IF cF > 0 THEN`n    y := x / cF;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'R1d IF cF > 0 THEN -> guarded-constant-zero warning' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded-constant-zero' -and -not $d[0].blocking) (Brief $r)
$r = Fb $cfv "IF 0 <> cF THEN`n    y := x / cF;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'R1e IF 0 <> cF (constant on the right) -> not proven, stays blocking' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
$r = Fb $cfv "IF cF <> 0 AND x > 1 THEN`n    y := x / cF;`nEND_IF`nIF cF = 0 OR x > 1 THEN`n    y := x / cF;`nEND_IF"
$d = Diags $r 'SAFETY-DIV-001'
Check 'R1f cF <> 0 AND x -> warning; cF = 0 OR x -> blocking' ($d.Count -eq 2 -and -not $d[0].blocking -and $d[1].blocking) (Brief $r)
$av = "    a : ARRAY[0..9] OF INT;`n    i : INT;`n    k : INT;`n    b : BOOL;"
$r = Fb $av "FOR i := 0 TO 10 DO`n    k := SEL(i > 9, 0, a[i]);`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R2a SEL(i > 9, 0, a[i]): i = 10 selects a[i] -> blocking' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
$r = Fb $av "FOR i := 0 TO 10 DO`n    k := SEL(i > 9, a[i], 0);`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R2b SEL(i > 9, a[i], 0): i = 10 selects 0 -> guarded warning' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking) (Brief $r)
$r = Fb $av "FOR i := 0 TO 10 DO`n    b := i <= 9 OR_ELSE a[i] > 0;`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R2c i <= 9 OR_ELSE a[i]: i = 10 evaluates a[i] -> blocking' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
$r = Fb $av "FOR i := 0 TO 10 DO`n    b := i > 9 OR_ELSE a[i] > 0;`nEND_FOR"
$d = Diags $r 'SCAN-ARR-001'
Check 'R2d i > 9 OR_ELSE a[i]: i = 10 stops at the left operand -> guarded warning' ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking) (Brief $r)
$av2 = "    a : ARRAY[0..9] OF INT;`n    i : INT;`n    k : INT;`n    bS : BOOL;`n    bF : BOOL;"
foreach ($c in @(
    @('R2e', 'bF := i <= 9 AND_THEN bS OR_ELSE a[i] > 0;'),
    @('R2f', 'bF := (i <= 9 AND_THEN bS) OR_ELSE a[i] > 0;'),
    @('R2g', 'bF := i <= 9 AND_THEN bS OR a[i] > 0;'),
    @('R2h', 'bF := i <= 9 AND_THEN bS XOR a[i] > 0;'),
    @('R2i', 'IF i <= 9 AND_THEN bS OR_ELSE a[i] > 0 THEN k := 1; END_IF'))) {
    $r = Fb $av2 "FOR i := 0 TO 10 DO`n    $($c[1])`nEND_FOR"
    $d = Diags $r 'SCAN-ARR-001'
    Check "$($c[0]) $($c[1]): a[i] is not in the right operand of the short-circuit -> blocking" ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
}
foreach ($c in @(
    @('R2j', 'k := SEL(i <= 9, 0, a[i]);'),
    @('R2k', 'bF := i <= 9 AND_THEN a[i] > 0;'),
    @('R2l', 'bF := i > 9 OR_ELSE a[i] > 0;'),
    @('R2m', 'bF := (i <= 9) AND_THEN (a[i] > 0);'),
    @('R2n', 'bF := bS AND_THEN i <= 9 AND_THEN a[i] > 0;'))) {
    $r = Fb $av2 "FOR i := 0 TO 10 DO`n    $($c[1])`nEND_FOR"
    $d = Diags $r 'SCAN-ARR-001'
    Check "$($c[0]) $($c[1]) -> guarded warning" ($d.Count -eq 1 -and $d[0].variant -eq 'guarded' -and -not $d[0].blocking) (Brief $r)
}
$gvD = { param($fx) Add-Gvl $fx 'GVL_T' "VAR_GLOBAL`n    gDone : BOOL;`nEND_VAR`nVAR_GLOBAL CONSTANT`n    cDone : BOOL := FALSE;`nEND_VAR`n" }
$r = Fb "    bS : BOOL;" "WHILE NOT bS DO`n    bS := GVL_T.gDone;`nEND_WHILE" $gvD
$d = Diags $r 'SCAN-LOOP-001'
Check 'R3a bS := GVL_T.gDone (VAR_GLOBAL) -> invariant-global-write warning, in unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-global-write' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and (Unres $r 'SCAN-LOOP-001').Count -eq 1 -and $r.data.requiresDisposition) (Brief $r)
$r = Fb "    bS : BOOL;`n    bL : BOOL;" "WHILE NOT bS DO`n    bS := GVL_T.cDone OR bL;`nEND_WHILE" $gvD
$d = Diags $r 'SCAN-LOOP-001'
Check 'R3b bS := GVL_T.cDone OR bL (VAR_GLOBAL CONSTANT is not a global-write source) -> invariant-write blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-write' -and $d[0].blocking) (Brief $r)
$r = Fb "    bS : BOOL;`n    bL : BOOL;" "WHILE NOT bS DO`n    bS := bL;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'R3c bS := bL (local, never written) -> invariant-write blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-write' -and $d[0].blocking) (Brief $r)
$r = Fb "    bS : BOOL;" "WHILE NOT GVL_T.gDone DO`n    bS := TRUE;`nEND_WHILE" $gvD
$d = Diags $r 'SCAN-LOOP-001'
Check 'R3d WHILE NOT GVL_T.gDone never written (master behaviour) -> still blocking' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
$r = Fb "    bS : BOOL;`n    bX : BOOL;`n    bIn AT %I* : BOOL;" "WHILE NOT bS DO`n    bS := bX;`n    bX := bIn;`nEND_WHILE"
Check 'R4 bS := bX; bX := bIn -> not silent: rulesSkipped source-written-in-loop:bX' ((Diags $r 'SCAN-LOOP-001').Count -ge 1 -or (SkipR $r 'SCAN-LOOP-001') -contains 'source-written-in-loop:bX') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
# S8 constant conditions, FOR start not constant, divisions in declarations
$r = Fb "    n : INT;" "WHILE 1 = 1 DO`n    n := n + 1;`nEND_WHILE`nWHILE NOT FALSE DO`n    n := n + 1;`nEND_WHILE"
Check 'I-S8a WHILE 1 = 1 / WHILE NOT FALSE without EXIT -> two blocking findings' ((Diags $r 'SCAN-LOOP-001').Count -eq 2 -and (Diags $r 'SCAN-LOOP-001')[0].blocking -and (Diags $r 'SCAN-LOOP-001')[1].blocking) (Brief $r)
$r = Fb "    n : INT;`n    a : INT;" "WHILE a = a DO`n    n := n + 1;`nEND_WHILE`nWHILE 1 = 2 DO`n    n := n + 1;`nEND_WHILE"
Check 'I-S8a2 counter-example: WHILE 1 = 2 -> no finding' (@((Diags $r 'SCAN-LOOP-001') | ForEach-Object { $_ } | Where-Object { $_.message -like '*1 = 2*' }).Count -eq 0) (Brief $r)
$r = Fb "    i : BYTE;`n    nStart : BYTE;`n    n : INT;" "FOR i := nStart TO 254 BY 2 DO`n    n := n + 1;`nEND_FOR"
Check 'I-S8b FOR i := nStart TO 254 BY 2 (BYTE) -> rulesSkipped step-overflow-start-not-constant' ((Diags $r 'SCAN-FOR-001').Count -eq 0 -and (SkipR $r 'SCAN-FOR-001') -contains 'step-overflow-start-not-constant') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-FOR-001') -join ','))
$r = Fb "    x : INT := 7 MOD 0;`n    y : LREAL := 1.0 / 3.0;" "x := 1;"
Check 'I-S8c MOD 0 in an initial value -> rulesSkipped declaration-initial-value-division (1.0 / 3.0 is evaluated, no record)' (@(SkipR $r 'SAFETY-DIV-001' | Where-Object { $_ -eq 'declaration-initial-value-division' }).Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SAFETY-DIV-001') -join ','))
# nits
$r = Fb "    fPos : LREAL;`n    fTarget : LREAL;`n    n : INT;" "WHILE ABS(fPos - fTarget) > 0.1 DO`n    n := n + 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'I-N1 WHILE ABS(fPos - fTarget) > 0.1 -> evaluated (blocking), not name-unresolved' ($d.Count -eq 1 -and $d[0].blocking -and (SkipR $r 'SCAN-LOOP-001') -notcontains 'name-unresolved') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
$r = Fb "    eMode : E_Mode;`n    n : INT;" "WHILE eMode <> E_Mode.Auto DO`n    n := n + 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'I-N2 busy-wait message names eMode only, not the enum type / member' ($d.Count -eq 1 -and $d[0].message -like '*writes eMode and*' -and $d[0].message -notlike '*writes*E_MODE*' -and $d[0].message -notlike '*AUTO,*') (Brief $r)
$dutA = { param($fx) Write-LintFxFile (Join-Path $fx.PlcDir 'DUTs\T_Arr.TcDUT') ("<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <DUT Name=`"T_Arr`" Id=`"$(New-Id)`">`n    <Declaration><![CDATA[TYPE T_Arr : ARRAY[1..10] OF INT;`nEND_TYPE`n]]></Declaration>`n  </DUT>`n</TcPlcObject>"); $fx.Items.Add('DUTs\T_Arr.TcDUT'); Set-LintFxCompile $fx $fx.Items.ToArray() }
$r = Fb "    a : T_Arr;" "a[11] := 0;" $dutA
Check 'I-N5 constant index on an alias array type -> rulesSkipped (not silent)' ((Diags $r 'SAFETY-ARR-001').Count -eq 0 -and (SkipR $r 'SAFETY-ARR-001').Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SAFETY-ARR-001') -join ','))

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

# ================================================================ W  PR #289 independent review (SF4, SF5, nit 7, nit 8)
# SF4: an unresolved unqualified name in the condition, not written and not passed in the body -> warning, not a skip
$r = Fb "    n : INT;" "WHILE NOT gLibFlag DO`n    n := n + 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'W-SF4a G1 WHILE NOT gLibFlag (unresolved) -> unresolved-condition-name warning, in unresolved, requiresDisposition' ($d.Count -eq 1 -and $d[0].variant -eq 'unresolved-condition-name' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and (Unres $r 'SCAN-LOOP-001').Count -eq 1 -and $r.data.requiresDisposition -and $r.success) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
$r = Fb "    n : INT;" "WHILE NOT gLibFlag DO`n    gLibFlag := TRUE;`nEND_WHILE"
Check 'W-SF4b the body writes the unresolved name -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
$fbP = { param($fx) Add-Pou $fx 'FB_P' "FUNCTION_BLOCK FB_P`nVAR`n    n : INT;`nEND_VAR`n" 'n := n + 1;' }
$r = Fb "    fbP : FB_P;" "WHILE NOT gLibFlag DO`n    fbP();`nEND_WHILE" $fbP
Check 'W-SF4c a project FB call in the body -> no finding, rulesSkipped call-in-body' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and (SkipR $r 'SCAN-LOOP-001') -contains 'call-in-body') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
$r = Fb "    n : INT;`n    bX : BOOL;" "WHILE NOT gLibFlag AND NOT bX DO`n    bX := n > 3;`n    n := n + 1;`nEND_WHILE"
Check 'W-SF4d another condition variable is written in the body -> no finding' ((Diags $r 'SCAN-LOOP-001').Count -eq 0) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
# SF5: the counter given to a VAR_IN_OUT / output of a call may be written by the callee
$io = { param($fx) Add-Pou $fx 'FB_IO' "FUNCTION_BLOCK FB_IO`nVAR_IN_OUT`n    io : INT;`nEND_VAR`n" 'io := 0;' }
$io2 = { param($fx) Add-Pou $fx 'FB_IO' "FUNCTION_BLOCK FB_IO`nVAR_IN_OUT`n    nIndex : INT;`nEND_VAR`n" 'nIndex := 0;' }
$r = Fb "    nIndex : INT;`n    a : ARRAY[0..9] OF INT;`n    fbC : FB_IO;" "FOR nIndex := 0 TO 10 DO`n    fbC(nIndex := nIndex);`n    a[nIndex] := 0;`nEND_FOR" $io2
Check 'W-SF5a fbC(nIndex := nIndex), formal VAR_IN_OUT -> no SCAN-ARR-001, rulesSkipped counter-written-in-body' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and @(SkipR $r 'SCAN-ARR-001' | Where-Object { $_ -like 'counter-written-in-body*' }).Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-ARR-001') -join ','))
$r = Fb "    nIndex : INT;`n    a : ARRAY[0..9] OF INT;`n    fbC : FB_IO;" "FOR nIndex := 0 TO 10 DO`n    fbC(io := nIndex);`n    a[nIndex] := 0;`nEND_FOR" $io
Check 'W-SF5b V1 fbC(io := nIndex), formal VAR_IN_OUT -> no SCAN-ARR-001, counter-written-in-body' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and @(SkipR $r 'SCAN-ARR-001' | Where-Object { $_ -like 'counter-written-in-body*' }).Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-ARR-001') -join ','))
$ioB = { param($fx) Add-Pou $fx 'FB_IOB' "FUNCTION_BLOCK FB_IOB`nVAR_IN_OUT`n    io : BYTE;`nEND_VAR`n" 'io := 0;' }
$r = Fb "    i : BYTE;`n    fbC : FB_IOB;" "FOR i := 0 TO 255 DO`n    fbC(io := i);`nEND_FOR" $ioB
Check 'W-SF5c BYTE 0 TO 255 with fbC(io := i) VAR_IN_OUT -> no SCAN-FOR-001, counter-written-in-body' ((Diags $r 'SCAN-FOR-001').Count -eq 0 -and @(SkipR $r 'SCAN-FOR-001' | Where-Object { $_ -like 'counter-written-in-body*' }).Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-FOR-001') -join ','))
$out = { param($fx) Add-Pou $fx 'FB_O' "FUNCTION_BLOCK FB_O`nVAR_OUTPUT`n    nOut : INT;`nEND_VAR`n" 'nOut := 0;' }
$r = Fb "    nIndex : INT;`n    a : ARRAY[0..9] OF INT;`n    fbC : FB_O;" "FOR nIndex := 0 TO 10 DO`n    fbC(nOut => nIndex);`n    a[nIndex] := 0;`nEND_FOR" $out
Check 'W-SF5d fbC(nOut => nIndex) -> counter written, no SCAN-ARR-001' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and @(SkipR $r 'SCAN-ARR-001' | Where-Object { $_ -like 'counter-written-in-body*' }).Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-ARR-001') -join ','))
$r = Fb "    nIndex : INT;`n    a : ARRAY[0..9] OF INT;`n    fbL : FB_NotInProject;" "FOR nIndex := 0 TO 10 DO`n    fbL(nIndex := nIndex);`n    a[nIndex] := 0;`nEND_FOR"
Check 'W-SF5e library / unknown FB, direction of the formal unknown -> no SCAN-ARR-001, counter-written-in-body' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and @(SkipR $r 'SCAN-ARR-001' | Where-Object { $_ -like 'counter-written-in-body*' }).Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-ARR-001') -join ','))
$r = Fb "    nIndex : INT;`n    a : ARRAY[0..9] OF INT;`n    ctu1 : CTU;" "FOR nIndex := 0 TO 10 DO`n    ctu1(CU := TRUE, PV := nIndex);`n    a[nIndex] := 0;`nEND_FOR"
Check 'W-SF5f Tc2_Standard CTU (no VAR_IN_OUT) PV := nIndex -> not a write, SCAN-ARR-001 blocking' ((Diags $r 'SCAN-ARR-001').Count -eq 1 -and (Diags $r 'SCAN-ARR-001')[0].blocking) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-ARR-001') -join ','))
$fnIo = { param($fx) Add-Pou $fx 'F_Io' "FUNCTION F_Io : BOOL`nVAR_IN_OUT`n    io : INT;`nEND_VAR`n" 'io := 0; F_Io := TRUE;' }
$r = Fb "    nIndex : INT;`n    a : ARRAY[0..9] OF INT;`n    b : BOOL;" "FOR nIndex := 0 TO 10 DO`n    b := F_Io(io := nIndex);`n    a[nIndex] := 0;`nEND_FOR" $fnIo
Check 'W-SF5g FUNCTION F_Io(io := nIndex) VAR_IN_OUT -> counter-written-in-body' ((Diags $r 'SCAN-ARR-001').Count -eq 0 -and @(SkipR $r 'SCAN-ARR-001' | Where-Object { $_ -like 'counter-written-in-body*' }).Count -eq 1) ((Brief $r) + ' ' + ((SkipR $r 'SCAN-ARR-001') -join ','))
# nit 7: sources another task / ADS may write (PROGRAM VAR, FB VAR_INPUT) -> warning like a GVL source; FB VAR / method local stay blocking
$fx = New-Fx
Add-Pou $fx 'MAIN' "PROGRAM MAIN`nVAR`n    bHmiStart : BOOL;`n    bOk : BOOL;`nEND_VAR`n" "WHILE NOT bOk DO`n    bOk := bHmiStart;`nEND_WHILE"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = Diags $r 'SCAN-LOOP-001'
Check 'W-N7a source = PROGRAM VAR (HMI may write MAIN.bHmiStart over ADS) -> invariant-external-write warning, in unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-external-write' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and (Unres $r 'SCAN-LOOP-001').Count -eq 1 -and $r.success) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR_INPUT`n    bStart : BOOL;`nEND_VAR`nVAR`n    bOk : BOOL;`nEND_VAR`n" "WHILE NOT bOk DO`n    bOk := bStart;`nEND_WHILE"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = Diags $r 'SCAN-LOOP-001'
Check 'W-N7b source = FB VAR_INPUT -> invariant-external-write warning' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-external-write' -and -not $d[0].blocking -and $r.success) (Brief $r)
$r = Fb "    bOk : BOOL;`n    bInt : BOOL;" "WHILE NOT bOk DO`n    bOk := bInt;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'W-N7c source = FB internal VAR -> invariant-write blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-write' -and $d[0].blocking) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    n : INT;`nEND_VAR`n" 'n := 1;' (Method 'M_Wait' "METHOD M_Wait : BOOL`nVAR_INPUT`n    bIn : BOOL;`nEND_VAR`nVAR`n    bOk : BOOL;`nEND_VAR`n" "WHILE NOT bOk DO`n    bOk := bIn;`nEND_WHILE")
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = Diags $r 'SCAN-LOOP-001'
Check 'W-N7d source = method VAR_INPUT (a value of the call) -> invariant-write blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'invariant-write' -and $d[0].blocking) (Brief $r)
# nit 8: a bit index given by a constant writes the variable; WHILE TRUE OR b says the condition is always TRUE
$r = Fb "    nW : WORD;`nEND_VAR`nVAR CONSTANT`n    cBit : INT := 3;" "WHILE nW = 0 DO`n    nW.cBit := TRUE;`nEND_WHILE"
Check 'W-N8a nW.cBit := TRUE (constant bit index) -> writes nW, no finding, no member-type-unknown' ((Diags $r 'SCAN-LOOP-001').Count -eq 0 -and ((SkipR $r 'SCAN-LOOP-001') -join ',') -eq '') ((Brief $r) + ' ' + ((SkipR $r 'SCAN-LOOP-001') -join ','))
$r = Fb "    b : BOOL;`n    n : INT;" "WHILE TRUE OR b DO`n    n := n + 1;`nEND_WHILE"
$d = Diags $r 'SCAN-LOOP-001'
Check 'W-N8b WHILE TRUE OR b -> blocking, message says the condition is always TRUE' ($d.Count -eq 1 -and $d[0].blocking -and $d[0].message -like '*always TRUE*') (Brief $r)
Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
