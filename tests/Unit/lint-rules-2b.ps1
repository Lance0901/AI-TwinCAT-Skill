# Unit: semantic linter (#252) Phase 2b rules, no IDE.
#   B  SCAN-FBCALL-001 / 002: read but never called (TON .Q, project FB output, R_TRIG), never referenced (info);
#      counter-examples for every "may be called elsewhere" path: body call, VAR_IN_OUT / ADR / REF= / interface
#      assignment, PRG.fb() from another POU, GVL instance, ARRAY OF FB, method / property of a project FB,
#      derived FB (EXTENDS) calling the inherited instance, STRUCT member, type outside the catalog
#   T  SCAN-TIMER-001 / 002: only in IF / CASE (warning), only in a method / action (info); legal guards: unconditional,
#      IF / ELSE both, CASE every label + ELSE, outer unconditional call, explicit reset, action called every cycle
#   P  SCAN-TIMER-004: PT never set, IN constant FALSE; counter-examples PT in call / inst.PT := / declaration init
#   S  SCAN-TIMER-005: state timer IN := TRUE in one CASE branch without reset; counter-examples reset, IF, variable IN
#   F  corpus review 2026-11-13: B20-B23 FB_init / library base (fb-init skip), T14-T18 member run every cycle via
#      x := M() / IF M() THEN / nested members (AND_THEN / OR_ELSE and calls inside IF still reported)
#   X  suppression (inline / profile), unresolved: warnings in, infos out; M metadata; D determinism
# Mock basis: tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13); the rule expectations follow
# rule-catalog.md; TON semantics measured 2026-11-13 (XAE 4026.22 / UmRT, verification/runtime-semantics-measured.md
# sections 4 / 5). Every check looks at the result object, never at localised PowerShell text.
#   powershell.exe -NoProfile -File tests/Unit/lint-rules-2b.ps1
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
function Diags($r, [string]$Rule) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $Rule }) }
function Brief($r) { return ((@($r.data.diagnostics | ForEach-Object { "$($_.ruleId)/$($_.variant)@$($_.objectPath):$($_.line) $($_.severity) b=$($_.blocking) s=$($_.suppressed)" }) -join '; ') + " code=$($r.error.code)") }
function Skips($r, [string]$Rule) { return , @($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq $Rule }) }
function SkipText($r) { return ((@($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -like 'SCAN-FBCALL*' -or $_.ruleId -like 'SCAN-TIMER*' } | ForEach-Object { "$($_.ruleId)=$($_.reason)" })) -join ',') }
function Unres($r, [string]$Rule) { return , @($r.data.unresolved | Where-Object { $_.ruleId -eq $Rule }) }
$R2b = 'SCAN-FBCALL-001', 'SCAN-FBCALL-002', 'SCAN-TIMER-001', 'SCAN-TIMER-002', 'SCAN-TIMER-004', 'SCAN-TIMER-005'
function None2b($r) { return (@($r.data.diagnostics | Where-Object { $R2b -contains $_.ruleId }).Count -eq 0) }
function Only($r, [string]$Rule) { return (@($r.data.diagnostics | Where-Object { $R2b -contains $_.ruleId }).Count -eq 1 -and (Diags $r $Rule).Count -eq 1) }

$root = Join-Path $env:TEMP ("tcauto-unit-lint2b-{0}" -f [guid]::NewGuid().ToString('N'))
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
function Fb([string]$Vars, [string]$Impl, [string]$Extra = '', [scriptblock]$Before) {
    $fx = New-Fx
    if ($Before) { & $Before $fx }
    Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n$Vars`nEND_VAR`n" $Impl $Extra
    return (Invoke-TcLintProject -PlcProjectPath $fx.Plcproj)
}
$sub = { param($fx) Add-Pou $fx 'FB_Sub' "FUNCTION_BLOCK FB_Sub`nVAR_INPUT`n    bIn : BOOL;`nEND_VAR`nVAR_OUTPUT`n    bOut : BOOL;`nEND_VAR`n" "bOut := bIn;" ((Method 'M_Run' "METHOD M_Run`n" 'bOut := TRUE;') + "`n    <Property Name=`"P_State`" Id=`"$(New-Id)`">`n      <Declaration><![CDATA[PROPERTY P_State : BOOL`n]]></Declaration>`n      <Get Name=`"Get`" Id=`"$(New-Id)`">`n        <Declaration><![CDATA[VAR`nEND_VAR`n]]></Declaration>`n        <Implementation>`n          <ST><![CDATA[P_State := bOut;]]></ST>`n        </Implementation>`n      </Get>`n    </Property>") }

# ================================================================ B  SCAN-FBCALL-001 / 002
$r = Fb "    fbT : TON;`n    bQ : BOOL;" "bQ := fbT.Q;"
$d = Diags $r 'SCAN-FBCALL-001'
Check 'B1 TON .Q read, never called -> FBCALL-001 warning at the declaration, not blocking, in unresolved' ((Only $r 'SCAN-FBCALL-001') -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and $d[0].section -eq 'declaration' -and $d[0].line -eq 3 -and (Unres $r 'SCAN-FBCALL-001').Count -eq 1 -and $r.success -and $r.data.requiresDisposition) (Brief $r)
$r = Fb "    fbS : FB_Sub;`n    b : BOOL;" "fbS.bIn := TRUE;`nb := fbS.bOut;" '' $sub
Check 'B2 project FB: input written, output read, never called -> FBCALL-001' (Only $r 'SCAN-FBCALL-001') (Brief $r)
$r = Fb "    rt : R_TRIG;`n    b : BOOL;" "rt.CLK := b;`nIF rt.Q THEN b := FALSE; END_IF"
Check 'B3 R_TRIG CLK written, Q read, never called -> FBCALL-001' (Only $r 'SCAN-FBCALL-001') (Brief $r)
$r = Fb "    fbUnused : TON;`n    n : INT;" "n := 1;"
$d = Diags $r 'SCAN-FBCALL-002'
Check 'B4 TON never referenced -> FBCALL-002 info, not in unresolved' ((Only $r 'SCAN-FBCALL-002') -and $d[0].severity -eq 'info' -and (Unres $r 'SCAN-FBCALL-002').Count -eq 0 -and -not $r.data.requiresDisposition) (Brief $r)
$r = Fb "    fbT : TON;`n    bQ : BOOL;" "fbT(IN := TRUE, PT := T#1S);`nbQ := fbT.Q;"
Check 'B5 counter-example: body call -> no finding' (None2b $r) (Brief $r)
$r = Fb "    fbT : TON;`n    bQ : BOOL;" "F_Use(t := fbT);`nbQ := fbT.Q;" '' { param($fx) Add-Pou $fx 'F_Use' "FUNCTION F_Use : BOOL`nVAR_IN_OUT`n    t : TON;`nEND_VAR`n" "t(IN := TRUE, PT := T#1S);" }
Check 'B6 counter-example: passed to VAR_IN_OUT -> no finding, rulesSkipped passed-or-aliased' ((None2b $r) -and (SkipText $r) -like '*SCAN-FBCALL-001=passed-or-aliased:fbT*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbT : TON;`n    p : POINTER TO TON;`n    bQ : BOOL;" "p := ADR(fbT);`nbQ := fbT.Q;"
Check 'B7 counter-example: ADR(fbT) -> no finding (skipped)' ((None2b $r) -and (SkipText $r) -like '*passed-or-aliased:fbT*') (Brief $r)
$r = Fb "    fbT : TON;`n    rT : REFERENCE TO TON;`n    bQ : BOOL;" "rT REF= fbT;`nbQ := fbT.Q;"
Check 'B8 counter-example: REF= alias -> no finding (skipped)' ((None2b $r) -and (SkipText $r) -like '*passed-or-aliased:fbT*') (Brief $r)
$r = Fb "    fbS : FB_Sub;`n    itf : I_Run;`n    b : BOOL;" "itf := fbS;`nb := fbS.bOut;" '' $sub
Check 'B9 counter-example: interface variable assignment -> no finding (skipped)' ((None2b $r) -and (SkipText $r) -like '*passed-or-aliased:fbS*') (Brief $r)
$fx = New-Fx
Add-Pou $fx 'PRG_A' "PROGRAM PRG_A`nVAR`n    fbT : TON;`n    bQ : BOOL;`nEND_VAR`n" "bQ := fbT.Q;"
Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`nEND_VAR`n" "PRG_A.fbT(IN := TRUE, PT := T#1S);"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'B10 counter-example: PRG_A.fbT() called from another program -> no finding, qualified-access' ((None2b $r) -and (SkipText $r) -like '*qualified-access:fbT*') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Gvl $fx 'GVL_T' "VAR_GLOBAL`n    gT : TON;`nEND_VAR`n"
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    b : BOOL;`nEND_VAR`n" "b := GVL_T.gT.Q;"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'B11 counter-example: GVL instance read without call -> not a candidate, no finding' (None2b $r) (Brief $r)
$r = Fb "    arT : ARRAY[0..3] OF TON;`n    b : BOOL;" "b := arT[0].Q;"
Check 'B12 counter-example: ARRAY OF TON -> no finding, array-instance' ((None2b $r) -and (SkipText $r) -like '*array-instance:arT*') (Brief $r)
$r = Fb "    fbS : FB_Sub;`n    b : BOOL;" "fbS.M_Run();`nb := fbS.bOut;" '' $sub
Check 'B13 counter-example: method call of a project FB -> no finding' (None2b $r) (Brief $r)
$r = Fb "    fbS : FB_Sub;`n    b : BOOL;" "b := fbS.P_State;" '' $sub
Check 'B14 counter-example: property read of a project FB (accessor runs) -> no finding' (None2b $r) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_Base' "FUNCTION_BLOCK FB_Base`nVAR`n    fbT : TON;`n    bQ : BOOL;`nEND_VAR`n" "bQ := fbT.Q;"
Add-Pou $fx 'FB_Der' "FUNCTION_BLOCK FB_Der EXTENDS FB_Base`nVAR`nEND_VAR`n" "fbT(IN := TRUE, PT := T#1S);`nSUPER^();"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'B15 counter-example: derived FB calls the inherited instance without SUPER^ -> no finding, inherited-use' ((None2b $r) -and (SkipText $r) -like '*inherited-use:fbT*') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Dut $fx 'ST_Hold' "TYPE ST_Hold :`nSTRUCT`n    tmr : TON;`nEND_STRUCT`nEND_TYPE`n"
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    st : ST_Hold;`n    b : BOOL;`nEND_VAR`n" "b := st.tmr.Q;"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'B16 counter-example: TON as STRUCT member -> no finding' (None2b $r) (Brief $r)
$r = Fb "    fbL : FB_LibThing;`n    b : BOOL;" "b := fbL.bDone;"
Check 'B17 counter-example: type outside catalog and project -> no finding, rulesSkipped unknown-type' ((None2b $r) -and (SkipText $r) -like '*unknown-type:FB_LibThing:fbL*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbT : TON;`n    b : BOOL;" "b := fbT.Q;" (Method 'M_X' "METHOD M_X`nVAR`n    fbT : INT;`nEND_VAR`n" 'fbT := 1;')
Check 'B18 counter-example: method local with the same name -> no finding, shadowed-name' ((None2b $r) -and (SkipText $r) -like '*shadowed-name:fbT*') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    fbT : TON;`n    b : BOOL;`nEND_VAR`n" "b := fbT.Q;"
Add-Pou $fx 'PRG_X' "PROGRAM PRG_X`nVAR`n    o : FB_T;`nEND_VAR`n" "o();`no.fbT(IN := TRUE, PT := T#1S);"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'B19 counter-example: o.fbT() from the owner instance outside -> no finding (qualified-access)' ((None2b $r) -and (SkipText $r) -like '*qualified-access:fbT*') ((Brief $r) + ' ' + (SkipText $r))
# corpus review 2026-11-13 (worker F): FB_init / FB_exit run without any reference, so the instance is not dead
$fbi = { param($fx) Add-Pou $fx 'FB_Reg' "FUNCTION_BLOCK FB_Reg`nVAR`n    n : INT;`nEND_VAR`n" 'n := n + 1;' (Method 'FB_init' "METHOD FB_init : BOOL`nVAR_INPUT`n    bInitRetains : BOOL;`n    bInCopyCode : BOOL;`n    nId : INT;`nEND_VAR`n" 'n := nId;') }
$r = Fb "    fbReg : FB_Reg(nId := 3);" "" '' $fbi
Check 'B20 counter-example: FB_Reg(nId := 3) with FB_init, never referenced -> no FBCALL-002, rulesSkipped fb-init' ((None2b $r) -and (SkipText $r) -like '*SCAN-FBCALL-002=fb-init:fbReg*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbReg : FB_Reg;" "" '' $fbi
Check 'B21 counter-example: FB with FB_init, no arguments, never referenced -> no FBCALL-002' (None2b $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbL : FB_LibThing(3);" "" '' $null
Check 'B22 counter-example: FB_init arguments on a type outside the project -> no finding' (None2b $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbD : FB_Der;" "" '' { param($fx) Add-Pou $fx 'FB_Der' "FUNCTION_BLOCK FB_Der EXTENDS FB_LibBase`nVAR`n    n : INT;`nEND_VAR`n" 'n := 1;' }
Check 'B23 counter-example: project FB extending a library base (FB_init unknown), never referenced -> no FBCALL-002 (corpus: Main.fbWheelThreadCal)' ((None2b $r) -and (SkipText $r) -like '*SCAN-FBCALL-002=fb-init:fbD*') ((Brief $r) + ' ' + (SkipText $r))

# ================================================================ T  SCAN-TIMER-001 / 002
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    ton1(IN := b, PT := T#1S);`nEND_IF"
$d = Diags $r 'SCAN-TIMER-001'
Check 'T1 TON only inside IF -> TIMER-001 warning at the call, in unresolved' ((Only $r 'SCAN-TIMER-001') -and $d[0].line -eq 2 -and $d[0].severity -eq 'warning' -and (Unres $r 'SCAN-TIMER-001').Count -eq 1) (Brief $r)
$r = Fb "    rt : R_TRIG;`n    b, c : BOOL;" "IF b THEN`n    rt(CLK := c);`nEND_IF"
Check 'T2 R_TRIG only inside IF -> TIMER-001' (Only $r 'SCAN-TIMER-001') (Brief $r)
$r = Fb "    ton1 : TON;`n    n : INT;`n    b : BOOL;" "CASE n OF`n1:`n    ton1(IN := b, PT := T#1S);`n2:`n    n := 0;`nEND_CASE"
Check 'T3 TON in one CASE label with a variable IN -> TIMER-001 (not 005)' (Only $r 'SCAN-TIMER-001') (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "ton1(IN := b, PT := T#1S);"
Check 'T4 counter-example: unconditional call -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    ton1(IN := TRUE, PT := T#1S);`nELSE`n    ton1(IN := FALSE, PT := T#1S);`nEND_IF"
Check 'T5 counter-example: IF / ELSE both call -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    n : INT;`n    b : BOOL;" "CASE n OF`n1:`n    IF b THEN ton1(IN := b, PT := T#1S); ELSE ton1(IN := FALSE, PT := T#1S); END_IF`n2, 3:`n    ton1(IN := b, PT := T#2S);`nELSE`n    ton1(IN := FALSE, PT := T#1S);`nEND_CASE"
Check 'T6 counter-example: every CASE label (nested IF / ELSE) and ELSE call -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "ton1(IN := b, PT := T#1S);`nIF b THEN`n    ton1(IN := FALSE);`nEND_IF"
Check 'T7 counter-example: outer unconditional call plus one in IF -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b, c : BOOL;" "IF b THEN`n    ton1(IN := c, PT := T#1S);`nELSIF c THEN`n    ton1(IN := FALSE);`nEND_IF"
Check 'T8 counter-example: explicit reset call IN := FALSE -> no finding, rulesSkipped explicit-reset' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-001=explicit-reset:ton1*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    ton1 : TON;`n    b : BOOL;" "A_Cyc();" (Action 'A_Cyc' 'ton1(IN := b, PT := T#1S);')
Check 'T9 counter-example: call in an action the body calls unconditionally -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "b := ton1.Q;" (Method 'M_Wait' "METHOD M_Wait : BOOL`n" 'ton1(IN := TRUE, PT := T#2S);')
$d = Diags $r 'SCAN-TIMER-002'
Check 'T10 TON only in a method -> TIMER-002 info, not in unresolved' ((Only $r 'SCAN-TIMER-002') -and $d[0].severity -eq 'info' -and $d[0].objectPath -eq 'FB_T.M_Wait' -and (Unres $r 'SCAN-TIMER-002').Count -eq 0) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    A_Cyc();`nEND_IF" (Action 'A_Cyc' 'ton1(IN := b, PT := T#1S);')
Check 'T11 TON only in an action the body calls (only there) under IF -> TIMER-001 at that call (rev289 SF3; was TIMER-002 info)' (Only $r 'SCAN-TIMER-001') (Brief $r)
$r = Fb "    rt : F_TRIG;`n    b : BOOL;" "M_Edge();" (Method 'M_Edge' "METHOD M_Edge`n" 'rt(CLK := b);')
Check 'T12 counter-example: method called unconditionally by the body -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    i : INT;`n    b : BOOL;" "FOR i := 0 TO 3 DO`n    IF b THEN ton1(IN := b, PT := T#1S); END_IF`nEND_FOR"
Check 'T13 call in a loop -> not evaluated (call-in-loop)' ((None2b $r) -and (SkipText $r) -like '*call-in-loop:ton1*') (Brief $r)
# corpus review 2026-11-13 (worker F): a method whose return value the body uses still runs every cycle
$mw = Method 'M_Wait' "METHOD M_Wait : BOOL`n" "ton1(IN := TRUE, PT := T#2S);`nM_Wait := ton1.Q;"
$r = Fb "    ton1 : TON;`n    b : BOOL;" "b := M_Wait();" $mw
Check 'T14 counter-example: b := M_Wait() unconditional, the method calls the TON -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF M_Wait() THEN`n    b := TRUE;`nEND_IF" $mw
Check 'T15 counter-example: IF M_Wait() THEN (condition evaluated every cycle) -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "M_Outer();" ((Method 'M_Outer' "METHOD M_Outer`n" 'M_Inner();') + (Method 'M_Inner' "METHOD M_Inner`n" 'ton1(IN := b, PT := T#2S);'))
Check 'T16 counter-example: body -> M_Outer -> M_Inner, all unconditional -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b AND_THEN M_Wait() THEN`n    b := FALSE;`nEND_IF" $mw
Check 'T17 IF b AND_THEN M_Wait() (short-circuit) -> TIMER-002 stays' (Only $r 'SCAN-TIMER-002') (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    b := M_Wait();`nEND_IF" $mw
Check 'T18 b := M_Wait() inside IF (only caller) -> not every cycle; judged at that call -> TIMER-001 (rev289 SF3; was TIMER-002)' (Only $r 'SCAN-TIMER-001') (Brief $r)

# ================================================================ P  SCAN-TIMER-004
$r = Fb "    ton1 : TON;`n    b : BOOL;" "ton1(IN := b);"
$d = Diags $r 'SCAN-TIMER-004'
Check 'P1 TON without PT anywhere -> TIMER-004 pt-unset warning, in unresolved' ((Only $r 'SCAN-TIMER-004') -and $d[0].variant -eq 'pt-unset' -and (Unres $r 'SCAN-TIMER-004').Count -eq 1) (Brief $r)
$r = Fb "    tof1 : TOF;`n    b : BOOL;" "tof1(IN := b);`nb := tof1.Q;"
Check 'P2 TOF without PT -> pt-unset' ((Only $r 'SCAN-TIMER-004') -and (Diags $r 'SCAN-TIMER-004')[0].variant -eq 'pt-unset') (Brief $r)
$r = Fb "    ton1 : TON;" "ton1(IN := FALSE, PT := T#1S);"
Check 'P3 IN := FALSE in every call -> in-constant' ((Only $r 'SCAN-TIMER-004') -and (Diags $r 'SCAN-TIMER-004')[0].variant -eq 'in-constant') (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "ton1.PT := T#3S;`nton1(IN := b);"
Check 'P4 counter-example: ton1.PT := T#3S -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON := (PT := T#3S);`n    b : BOOL;" "ton1(IN := b);"
Check 'P5 counter-example: PT in the declaration initialiser -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;" "ton1(IN := TRUE, PT := T#5S);"
Check 'P6 counter-example: IN := TRUE start-up delay -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "ton1(b, T#1S);"
Check 'P7 positional arguments -> not evaluated (positional-arguments)' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-004=positional-arguments:ton1*') ((Brief $r) + ' ' + (SkipText $r))

# ================================================================ S  SCAN-TIMER-005
$st = "    tonWait : TON;`n    eState : INT;"
$r = Fb $st "CASE eState OF`n0:`n    eState := 10;`n10:`n    tonWait(IN := TRUE, PT := T#2S);`n    IF tonWait.Q THEN eState := 20; END_IF`n20:`n    eState := 0;`nEND_CASE"
$d = Diags $r 'SCAN-TIMER-005'
Check 'S1 state timer IN := TRUE in one CASE branch, never reset -> TIMER-005 only (no 001), in unresolved' ((Only $r 'SCAN-TIMER-005') -and $d[0].line -eq 5 -and (Unres $r 'SCAN-TIMER-005').Count -eq 1) (Brief $r)
$r = Fb $st "CASE eState OF`n10:`n    tonWait(IN := TRUE, PT := T#2S);`n    IF tonWait.Q THEN eState := 20; END_IF`n20:`n    tonWait(IN := TRUE, PT := T#5S);`n    IF tonWait.Q THEN eState := 0; END_IF`nEND_CASE"
Check 'S2 one timer in two CASE branches, IN := TRUE, never reset -> TIMER-005' (Only $r 'SCAN-TIMER-005') (Brief $r)
$r = Fb "    tonWait : LTON;`n    eState : INT;" "CASE eState OF`n10:`n    tonWait(IN := TRUE, PT := LTIME#2S);`n    IF tonWait.Q THEN eState := 20; END_IF`nEND_CASE"
Check 'S3 LTON state timer -> TIMER-005' (Only $r 'SCAN-TIMER-005') (Brief $r)
$r = Fb $st "CASE eState OF`n10:`n    tonWait(IN := TRUE, PT := T#2S);`n    IF tonWait.Q THEN`n        tonWait(IN := FALSE);`n        eState := 20;`n    END_IF`nEND_CASE"
Check 'S4 counter-example: tonWait(IN := FALSE) before leaving -> no finding' (None2b $r) (Brief $r)
$r = Fb $st "CASE eState OF`n10:`n    tonWait(IN := TRUE, PT := T#2S);`n    IF tonWait.Q THEN eState := 20; END_IF`nEND_CASE`nIF eState <> 10 THEN tonWait.IN := FALSE; END_IF"
Check 'S5 tonWait.IN := FALSE outside without a following call (IN never sampled FALSE) -> TIMER-005 stays' (Only $r 'SCAN-TIMER-005') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb $st "CASE eState OF`n10:`n    tonWait(IN := TRUE, PT := T#2S);`n    IF tonWait.Q THEN eState := 20; END_IF`nEND_CASE`nIF eState <> 10 THEN`n    tonWait.IN := FALSE;`n    tonWait();`nEND_IF"
Check 'S5b counter-example: tonWait.IN := FALSE; tonWait(); (call samples FALSE) -> no TIMER-005' ((Diags $r 'SCAN-TIMER-005').Count -eq 0) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb $st "tonWait(IN := eState = 10, PT := T#2S);`nCASE eState OF`n10:`n    IF tonWait.Q THEN eState := 20; END_IF`nEND_CASE"
Check 'S6 counter-example: timer called every cycle with IN := eState = 10 -> no finding' (None2b $r) (Brief $r)
$r = Fb $st "IF eState = 10 THEN`n    tonWait(IN := TRUE, PT := T#2S);`nEND_IF"
Check 'S7 IN := TRUE under IF (not CASE) -> TIMER-001, not 005' (Only $r 'SCAN-TIMER-001') (Brief $r)

# ================================================================ R  review round 1 (PR #289)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN ton1(IN := b, PT := T#1S); END_IF`nton1.IN := FALSE;"
Check 'R1 TIMER-001: ton1.IN := FALSE without a following call is no reset -> TIMER-001' (Only $r 'SCAN-TIMER-001') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN ton1(IN := b, PT := T#1S); END_IF`nton1.IN := FALSE;`nton1();"
Check 'R1b counter-example: ton1.IN := FALSE; ton1(); -> no TIMER-001' ((Diags $r 'SCAN-TIMER-001').Count -eq 0) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    {IF defined(X)}`n    nX : INT;`n    {END_IF}`n    ton1 : TON;`n    b : BOOL;" "ton1(IN := b);`nb := F_Use(t := ton1);" '' { param($fx) Add-Pou $fx 'F_Use' "FUNCTION F_Use : BOOL`nVAR_IN_OUT`n    t : TON;`nEND_VAR`n" "F_Use := t.Q;" }
$ids = @($r.data.coverage.rulesSkipped | Where-Object { $_.reason -like '*:ton1' } | ForEach-Object { $_.ruleId } | Sort-Object -Unique) -join ','
Check 'R2 common reason recorded for every applicable rule (FBCALL-001 / 002, TIMER-001 / 002 / 004 / 005)' ((None2b $r) -and $ids -eq 'SCAN-FBCALL-001,SCAN-FBCALL-002,SCAN-TIMER-001,SCAN-TIMER-002,SCAN-TIMER-004,SCAN-TIMER-005') ($ids + ' | ' + (SkipText $r))
$r = Fb "    rt : R_TRIG;`n    b : BOOL;" "rt(CLK := b);`nb := F_Use(t := rt);" '' { param($fx) Add-Pou $fx 'F_Use' "FUNCTION F_Use : BOOL`nVAR_IN_OUT`n    t : R_TRIG;`nEND_VAR`n" "F_Use := t.Q;" }
$ids = @($r.data.coverage.rulesSkipped | Where-Object { $_.reason -like '*:rt' } | ForEach-Object { $_.ruleId } | Sort-Object -Unique) -join ','
Check 'R2b R_TRIG: common reason for FBCALL-001 / 002, TIMER-001 / 002 only (004 / 005 do not apply)' ($ids -eq 'SCAN-FBCALL-001,SCAN-FBCALL-002,SCAN-TIMER-001,SCAN-TIMER-002') $ids
$r = Fb "    t1 : TON := (IN := FALSE);`n    b : BOOL;" "t1(IN := b);"
Check 'R3 initialiser without PT -> TIMER-004 pt-unset' ((Only $r 'SCAN-TIMER-004') -and (Diags $r 'SCAN-TIMER-004')[0].variant -eq 'pt-unset') (Brief $r)
$r = Fb "    t1 : TON := (IN := FALSE, PT := T#2S);`n    b : BOOL;" "t1(IN := b);"
Check 'R3b counter-example: initialiser with PT -> no finding' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;" "ton1(IN := FALSE, PT := T#1S);"
Check 'R4 TIMER-004 in-constant confidence medium' ((Diags $r 'SCAN-TIMER-004')[0].confidence -eq 'medium') (Brief $r)
$r = Fb "    fbT : TON;`n    bQ : BOOL;" "bQ := fbT.Q;"
Check 'R5 FBCALL-001 diagnostic carries impactBasis inferred' ((Diags $r 'SCAN-FBCALL-001')[0].impactBasis -eq 'inferred') (Brief $r)
# per-diagnostic impactBasis (rule-catalog: inferred machine consequence; TON is measured)
$r = Fb "    rt : R_TRIG;`n    b, c : BOOL;" "IF b THEN`n    rt(CLK := c);`nEND_IF"
Check 'R5b R_TRIG TIMER-001 carries impactBasis inferred' ((Diags $r 'SCAN-TIMER-001')[0].impactBasis -eq 'inferred') (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    ton1(IN := b, PT := T#1S);`nEND_IF"
$d = Diags $r 'SCAN-TIMER-001'
Check 'R5c TON TIMER-001 has no impactBasis (measured)' ($d.Count -eq 1 -and $null -eq $d[0].impactBasis) (Brief $r)
$r = Fb "    tof1 : TOF;`n    b : BOOL;" "tof1(IN := b);`nb := tof1.Q;"
Check 'R5d TOF pt-unset carries impactBasis inferred' ((Diags $r 'SCAN-TIMER-004')[0].impactBasis -eq 'inferred') (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "ton1(IN := b);"
$d = Diags $r 'SCAN-TIMER-004'
Check 'R5e TON pt-unset has no impactBasis (measured)' ($d.Count -eq 1 -and $null -eq $d[0].impactBasis) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    A_T();`nELSE`n    A_T();`nEND_IF" (Action 'A_T' 'ton1(IN := b, PT := T#1S);')
Check 'R6 counter-example: IF ... ELSE both call the action -> no TIMER-002' (None2b $r) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;`n    n : INT;" "CASE n OF`n1:`n    A_T();`nELSE`n    A_T();`nEND_CASE" (Action 'A_T' 'ton1(IN := b, PT := T#1S);')
Check 'R6b counter-example: CASE label + ELSE both call the action -> no TIMER-002' (None2b $r) (Brief $r)

# ================================================================ K  PR #289 independent review (rev289)
# B1: project FB extending a library base: own VAR_INPUT / VAR_OUTPUT accessed -> no call; unknown member -> skip, never silent
$fbw = { param($fx) Add-Pou $fx 'FB_W' "FUNCTION_BLOCK FB_W EXTENDS FB_ActionBasic`nVAR_INPUT`n    bIn : BOOL;`nEND_VAR`nVAR_OUTPUT`n    bDone : BOOL;`nEND_VAR`n" "bDone := bIn;" }
$r = Fb "    fbW : FB_W;`n    b : BOOL;" "b := fbW.bDone;" '' $fbw
$d = Diags $r 'SCAN-FBCALL-001'
Check 'K-LB1 library base, own output read, never called -> FBCALL-001' ((Only $r 'SCAN-FBCALL-001') -and (Unres $r 'SCAN-FBCALL-001').Count -eq 1) ((Brief $r) + ' ' + (SkipText $r))
Check 'K-N2 FBCALL-001 message names the implementation section of the line it quotes' ($d.Count -eq 1 -and $d[0].message -like '*FB_T implementation line 1*') "$($d[0].message)"
$r = Fb "    fbW : FB_W;`n    b : BOOL;" "fbW.bIn := TRUE;`nIF fbW.bDone THEN b := TRUE; END_IF" '' $fbw
Check 'K-LB3 library base, own input written + output read, never called -> FBCALL-001' (Only $r 'SCAN-FBCALL-001') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbW : FB_W;`n    b : BOOL;" "b := fbW.bDone;`nb := fbW.SomeLibProp;" '' $fbw
Check 'K-LB4 library base, member not declared in the project chain -> no finding, rulesSkipped library-base-members-unknown' ((None2b $r) -and (SkipText $r) -like '*SCAN-FBCALL-001=library-base-members-unknown:fbW*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbW : FB_W;`n    b : BOOL;" "fbW.M_LibMethod();`nb := fbW.bDone;" '' $fbw
Check 'K-LB5 library base, method call -> no finding (code of the instance runs)' (None2b $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    fbW : FB_W;" "" '' $fbw
Check 'K-LB6 library base, never referenced -> still rulesSkipped fb-init (B23 unchanged)' ((None2b $r) -and (SkipText $r) -like '*SCAN-FBCALL-002=fb-init:fbW*') ((Brief $r) + ' ' + (SkipText $r))
# SF1: only inst.IN := FALSE is a reset; inst.IN := TRUE; inst(); is a call with IN := TRUE
$r = Fb "    tmr : TON;`n    n : INT;" "CASE n OF`n0:`n    tmr.IN := TRUE;`n    tmr.PT := T#1S;`n    tmr();`n    IF tmr.Q THEN n := 1; END_IF`n1:`n    n := 0;`nEND_CASE"
Check 'K-U01 tmr.IN := TRUE; tmr(); in one CASE branch -> TIMER-005' (Only $r 'SCAN-TIMER-005') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    bStart, b : BOOL;" "IF bStart THEN`n    tmr.IN := b;`n    tmr.PT := T#1S;`n    tmr();`nEND_IF"
Check 'K-U02 tmr.IN := b; tmr(); inside IF -> TIMER-001 (not a reset)' (Only $r 'SCAN-TIMER-001') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    n : INT;" "CASE n OF`n0:`n    tmr(IN := TRUE, PT := T#1S);`n1:`n    tmr.IN := FALSE;`n    tmr();`nEND_CASE"
Check 'K-U03 counter-example: tmr.IN := FALSE; tmr(); is still a reset -> no finding, explicit-reset' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-001=explicit-reset:tmr*') ((Brief $r) + ' ' + (SkipText $r))
# SF2: PT / IN handed out by address or reference -> may be written there: not reported, recorded
$r = Fb "    tmr : TON;`n    p : POINTER TO TIME;`n    b : BOOL;" "p := ADR(tmr.PT);`np^ := T#1S;`ntmr(IN := b);"
Check 'K-P21 ADR(tmr.PT) -> no pt-unset, rulesSkipped pt-passed-or-aliased' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-004=pt-passed-or-aliased:tmr*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    t : TIME := T#1S;`n    b : BOOL;" "MEMCPY(ADR(tmr.PT), ADR(t), SIZEOF(t));`ntmr(IN := b);"
Check 'K-P22 MEMCPY(ADR(tmr.PT), ...) -> no pt-unset, pt-passed-or-aliased' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-004=pt-passed-or-aliased:tmr*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    b : BOOL;" "F_Set(t := tmr.PT);`ntmr(IN := b);" '' { param($fx) Add-Pou $fx 'F_Set' "FUNCTION F_Set : BOOL`nVAR_IN_OUT`n    t : TIME;`nEND_VAR`n" "t := T#1S;" }
Check 'K-P23 F_Set(t := tmr.PT) (VAR_IN_OUT) -> no pt-unset, pt-passed-or-aliased' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-004=pt-passed-or-aliased:tmr*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    n : INT;`n    p : POINTER TO BOOL;" "p := ADR(tmr.IN);`nCASE n OF`n1:`n    tmr(IN := TRUE, PT := T#1S);`nEND_CASE"
Check 'K-P24 ADR(tmr.IN) -> no TIMER-005, rulesSkipped in-passed-or-aliased' ((Diags $r 'SCAN-TIMER-005').Count -eq 0 -and (SkipText $r) -like '*SCAN-TIMER-005=in-passed-or-aliased:tmr*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    p : POINTER TO BOOL;" "p := ADR(tmr.IN);`ntmr(IN := FALSE, PT := T#1S);"
Check 'K-P25 ADR(tmr.IN) -> no in-constant, rulesSkipped in-passed-or-aliased' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-004=in-passed-or-aliased:tmr*') ((Brief $r) + ' ' + (SkipText $r))
# SF3: action / method called only at one place of the body, inside a CASE branch / IF -> judged at that place
$r = Fb "    tmr : TON;`n    n : INT;" "CASE n OF`n10:`n    A_Wait();`n20:`n    n := 0;`nEND_CASE" (Action 'A_Wait' "tmr(IN := TRUE, PT := T#2S);`nIF tmr.Q THEN n := 20; END_IF")
$d = Diags $r 'SCAN-TIMER-005'
Check 'K-U09 state timer in an action called in one CASE branch -> TIMER-005 at the action call' ((Only $r 'SCAN-TIMER-005') -and $d[0].objectPath -eq 'FB_T' -and $d[0].line -eq 3 -and (Unres $r 'SCAN-TIMER-005').Count -eq 1) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    b : BOOL;" "IF b THEN`n    A_Wait();`nEND_IF" (Action 'A_Wait' "tmr(IN := b, PT := T#2S);")
Check 'K-U10 timer in an action called inside IF -> TIMER-001' (Only $r 'SCAN-TIMER-001') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    b : BOOL;" "IF b THEN`n    M_Wait();`nEND_IF" (Method 'M_Wait' "METHOD M_Wait`n" "tmr(IN := b, PT := T#2S);")
Check 'K-U11 timer in a method called inside IF (no other caller) -> TIMER-001' (Only $r 'SCAN-TIMER-001') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    tmr : TON;`n    n : INT;`nEND_VAR`n" "CASE n OF`n10:`n    A_Wait();`nEND_CASE" (Action 'A_Wait' "tmr(IN := TRUE, PT := T#2S);")
Add-Pou $fx 'MAIN' "PROGRAM MAIN`nVAR`n    fb : FB_T;`nEND_VAR`n" "fb();`nfb.A_Wait();"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'K-U12 action also called from outside (fb.A_Wait()) -> TIMER-002 info, rulesSkipped member-called-elsewhere' ((Only $r 'SCAN-TIMER-002') -and (SkipText $r) -like '*SCAN-TIMER-005=member-called-elsewhere:tmr*') ((Brief $r) + ' ' + (SkipText $r))
# Nit 6: '.tmr' of something whose type is certainly not the owner is not an access to the owner's tmr
$fx = New-Fx
Add-Dut $fx 'ST_Hold' "TYPE ST_Hold :`nSTRUCT`n    tmr : TON;`nEND_STRUCT`nEND_TYPE`n"
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    tmr : TON;`n    b : BOOL;`nEND_VAR`n" "b := tmr.Q;"
Add-Pou $fx 'PRG_X' "PROGRAM PRG_X`nVAR`n    st : ST_Hold;`n    o : FB_T;`nEND_VAR`n" "o();`nst.tmr(IN := TRUE, PT := T#1S);"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'K-Q1 st.tmr (st : ST_Hold) elsewhere does not hide FB_T.tmr -> FBCALL-001' ((Diags $r 'SCAN-FBCALL-001').Count -eq 1 -and (Diags $r 'SCAN-FBCALL-001')[0].objectPath -eq 'FB_T') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    tmr : TON;`n    b : BOOL;`nEND_VAR`n" "b := tmr.Q;"
Add-Pou $fx 'FB_D' "FUNCTION_BLOCK FB_D EXTENDS FB_T`nVAR`nEND_VAR`n" "SUPER^();"
Add-Pou $fx 'PRG_X' "PROGRAM PRG_X`nVAR`n    d : FB_D;`n    p : POINTER TO FB_T;`nEND_VAR`n" "d();`np^.tmr(IN := TRUE, PT := T#1S);"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'K-Q2 counter-example: p^.tmr (qualifier not resolvable) -> still qualified-access / inherited-use, no finding' ((None2b $r) -and ((SkipText $r) -like '*:tmr*')) ((Brief $r) + ' ' + (SkipText $r))
# Nit 1: constant IF condition
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF TRUE THEN`n    ton1(IN := b, PT := T#1S);`nEND_IF"
Check 'K-C1 IF TRUE THEN tmr() -> no TIMER-001 (always runs)' (None2b $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF 1 = 1 THEN`n    ton1(IN := b, PT := T#1S);`nEND_IF"
Check 'K-C2 IF 1 = 1 THEN tmr() -> no TIMER-001' (None2b $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF FALSE THEN`n    ton1(IN := b, PT := T#1S);`nEND_IF"
Check 'K-C3 IF FALSE THEN tmr() -> no TIMER-001, rulesSkipped constant-false-condition' ((Diags $r 'SCAN-TIMER-001').Count -eq 0 -and (SkipText $r) -like '*SCAN-TIMER-001=constant-false-condition:ton1*') ((Brief $r) + ' ' + (SkipText $r))
# Nit 3 / Nit 4: messages
$r = Fb "    ton1 : TON;`n    b : BOOL;" "b := P_X;" ("`n    <Property Name=`"P_X`" Id=`"$(New-Id)`">`n      <Declaration><![CDATA[PROPERTY P_X : BOOL`n]]></Declaration>`n      <Get Name=`"Get`" Id=`"$(New-Id)`">`n        <Declaration><![CDATA[VAR`nEND_VAR`n]]></Declaration>`n        <Implementation>`n          <ST><![CDATA[ton1(IN := b, PT := T#1S);`nP_X := ton1.Q;]]></ST>`n        </Implementation>`n      </Get>`n    </Property>")
$d = Diags $r 'SCAN-TIMER-002'
Check 'K-N3 TIMER-002 in a property accessor says property accessor' ($d.Count -eq 1 -and $d[0].message -like '*property accessor*' -and $d[0].message -notlike '*method / action*') ((Brief $r) + " $($d[0].message)")
$r = Fb "    tof1 : TOF;`n    b : BOOL;" "IF b THEN`n    tof1(IN := b, PT := T#1S);`nEND_IF"
$d = Diags $r 'SCAN-TIMER-001'
Check 'K-N4 TIMER-001 on TOF does not claim a TON measurement' ($d.Count -eq 1 -and $d[0].message -notlike '*a TON keeps*' -and $d[0].message -like '*inferred*') "$($d[0].message)"
# Nit 5: library types that are certainly not FBs are not listed as unknown-type
$r = Fb "    s : T_MaxString;`n    e : MC_Direction;`n    fbL : FB_LibThing;" "s := '';"
$st = SkipText $r
Check 'K-N5 unknown-type lists FB_LibThing but not T_MaxString / MC_Direction' ($st -like '*unknown-type:FB_LibThing:fbL*' -and $st -notlike '*T_MaxString*' -and $st -notlike '*MC_Direction*') $st
# Round 3 (review of PR #289 rev3): no naming-convention inference. A library FB called ST_LibFb / E_LibFb is still unknown-type
$r = Fb "    fbX : ST_LibFb;`n    fbY : E_LibFb;`n    b : BOOL;" "b := fbX.bDone;`nb := fbY.bDone;"
$st = SkipText $r
Check 'K-R1 library type ST_LibFb / E_LibFb (not in project) -> rulesSkipped unknown-type, no finding' ((None2b $r) -and $st -like '*unknown-type:ST_LibFb:fbX*' -and $st -like '*unknown-type:E_LibFb:fbY*') ((Brief $r) + ' ' + $st)
$r = Fb "    d : ST_Data;`n    b : BOOL;" "b := d.x;" '' { param($fx) Add-Dut $fx 'ST_Data' "TYPE ST_Data :`nSTRUCT`n    x : BOOL;`nEND_STRUCT`nEND_TYPE`n" }
Check 'K-R2 project DUT ST_Data (struct) -> not recorded' ((None2b $r) -and (SkipText $r) -notlike '*ST_Data*') ((Brief $r) + ' ' + (SkipText $r))

# Round 3 nit B: a project FUNCTION / FB parameter that is VAR_INPUT (by value) cannot write inst.PT / inst.IN back
$rd = { param($fx) Add-Pou $fx 'F_Rd' "FUNCTION F_Rd : BOOL`nVAR_INPUT`n    t : TIME;`nEND_VAR`n" "F_Rd := TRUE;" }
$rdIo = { param($fx) Add-Pou $fx 'F_Rd' "FUNCTION F_Rd : BOOL`nVAR_IN_OUT`n    t : TIME;`nEND_VAR`n" "F_Rd := TRUE;" }
$rdB = { param($fx) Add-Pou $fx 'F_RdB' "FUNCTION F_RdB : BOOL`nVAR_INPUT`n    b : BOOL;`nEND_VAR`n" "F_RdB := b;" }
$r = Fb "    tmr : TON;`n    b : BOOL;" "b := F_Rd(tmr.PT);`ntmr(IN := b);" '' $rd
Check 'K-R3 F_Rd(tmr.PT), formal VAR_INPUT (positional) -> pt-unset still reported' (Only $r 'SCAN-TIMER-004') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    b : BOOL;" "b := F_Rd(t := tmr.PT);`ntmr(IN := b);" '' $rd
Check 'K-R3b F_Rd(t := tmr.PT), formal VAR_INPUT (named) -> pt-unset still reported' (Only $r 'SCAN-TIMER-004') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    b : BOOL;" "b := F_Rd(tmr.PT);`ntmr(IN := b);" '' $rdIo
Check 'K-R4 F_Rd(tmr.PT), formal VAR_IN_OUT -> pt-passed-or-aliased' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-004=pt-passed-or-aliased:tmr*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    b : BOOL;" "b := F_Nope(tmr.PT);`ntmr(IN := b);"
Check 'K-R5 unknown callee F_Nope(tmr.PT) -> pt-passed-or-aliased' ((None2b $r) -and (SkipText $r) -like '*SCAN-TIMER-004=pt-passed-or-aliased:tmr*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    tmr : TON;`n    b : BOOL;" "b := F_RdB(tmr.IN);`ntmr(IN := FALSE, PT := T#1S);" '' $rdB
Check 'K-R6 F_RdB(tmr.IN), formal VAR_INPUT -> in-constant still reported' (Only $r 'SCAN-TIMER-004') ((Brief $r) + ' ' + (SkipText $r))
# Round 3 nit C: several call sites inside the body is not "called elsewhere"
$r = Fb "    tmr : TON;`n    n : INT;" "CASE n OF`n10:`n    A_Wait();`n20:`n    A_Wait();`nEND_CASE" (Action 'A_Wait' "tmr(IN := TRUE, PT := T#2S);")
Check 'K-R7 action called at two body sites -> reason member-called-at-several-sites, not -elsewhere' ((SkipText $r) -like '*SCAN-TIMER-005=member-called-at-several-sites:tmr*' -and (SkipText $r) -notlike '*member-called-elsewhere*') ((Brief $r) + ' ' + (SkipText $r))
# Round 3 nit D: constant folding as SCAN-LOOP-001 does
$r = Fb "    ton1 : TON;`n    b, bStart : BOOL;" "IF TRUE OR bStart THEN`n    ton1(IN := b, PT := T#1S);`nEND_IF"
Check 'K-R8 IF TRUE OR bStart THEN tmr() -> always runs, no TIMER-001' (None2b $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    ton1 : TON;`n    b, bStart : BOOL;" "IF FALSE AND bStart THEN`n    ton1(IN := b, PT := T#1S);`nEND_IF"
Check 'K-R9 IF FALSE AND bStart THEN tmr() -> constant-false-condition' ((Diags $r 'SCAN-TIMER-001').Count -eq 0 -and (SkipText $r) -like '*SCAN-TIMER-001=constant-false-condition:ton1*') ((Brief $r) + ' ' + (SkipText $r))

# ================================================================ X  suppression
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    // tcauto-lint-disable-next-line SCAN-TIMER-001: updated only in this mode on purpose`n    ton1(IN := b, PT := T#1S);`nEND_IF"
$d = Diags $r 'SCAN-TIMER-001'
Check 'X1 inline suppression of TIMER-001 -> suppressed, not in unresolved' ($d.Count -eq 1 -and $d[0].suppressed -and (Unres $r 'SCAN-TIMER-001').Count -eq 0 -and $r.success) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    fbT : TON;`n    bQ : BOOL;`nEND_VAR`n" "bQ := fbT.Q;"
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"FB_T","ruleId":"SCAN-FBCALL-001","reason":"reviewed: output read for diagnostics only"}]}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = Diags $r 'SCAN-FBCALL-001'
Check 'X2 profile suppression of FBCALL-001 -> suppressed, not in unresolved, listed in suppressions[]' ($d.Count -eq 1 -and $d[0].suppressed -and (Unres $r 'SCAN-FBCALL-001').Count -eq 0 -and @($r.data.suppressions | Where-Object { $_.source -eq 'profile' -and $_.matched -eq 1 }).Count -eq 1) (Brief $r)
$r = Fb "    ton1 : TON;`n    b : BOOL;" "IF b THEN`n    // tcauto-lint-disable-next-line SCAN-TIMER-001`n    ton1(IN := b, PT := T#1S);`nEND_IF"
Check 'X3 inline suppression without a reason -> not applied (LINT-SUPPRESS-001), finding stays' (-not (Diags $r 'SCAN-TIMER-001')[0].suppressed -and (Diags $r 'LINT-SUPPRESS-001').Count -eq 1) (Brief $r)

# ================================================================ M  metadata
foreach ($id in $R2b) {
    $m = @(& $mod { param($i) $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get($i) } $id)[0]
    Check "M $id registered, phase 2, not blockable, limits written" ($null -ne $m -and $m.Phase -eq '2' -and $m.Blockable -eq 'false' -and $m.Limits.Length -gt 200) "$($m.Phase) $($m.Blockable) $($m.Severity)"
}
$sev = @($R2b | ForEach-Object { $i = $_; @(& $mod { param($i) $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get($i) } $i)[0].Severity }) -join ','
Check 'M severities follow rule-catalog: 001 warning, 002 info, TIMER-001 warning, 002 info, 004 / 005 warning' ($sev -eq 'warning,info,warning,info,warning,warning') $sev

# ================================================================ D  determinism
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    fbA : TON;`n    fbU : TON;`n    ton1 : TON;`n    ton2 : TON;`n    tonW : TON;`n    eState : INT;`n    b : BOOL;`nEND_VAR`n" "b := fbA.Q;`nIF b THEN ton1(IN := b, PT := T#1S); END_IF`nton2(IN := b);`nCASE eState OF`n1:`n    tonW(IN := TRUE, PT := T#1S);`nEND_CASE" (Method 'M_W' "METHOD M_W`nVAR_INPUT`n    r : R_TRIG;`nEND_VAR`n" 'b := TRUE;')
$outs = foreach ($cul in 'en-US', 'zh-TW', 'en-US') {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $cul; [System.Threading.Thread]::CurrentThread.CurrentUICulture = $cul
    $x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj; $x.data.Remove('newSuppressionsBasisReason'); Js $x
}
$x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'D1 FBCALL-001 / 002, TIMER-001 / 004 / 005 fire on one FB' (@('SCAN-FBCALL-001', 'SCAN-FBCALL-002', 'SCAN-TIMER-001', 'SCAN-TIMER-004', 'SCAN-TIMER-005' | Where-Object { (Diags $x $_).Count -eq 1 }).Count -eq 5) (Brief $x)
Check 'D2 two runs and en-US / zh-TW byte-identical' ($outs[0] -ceq $outs[1] -and $outs[0] -ceq $outs[2]) ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
