# Unit: semantic linter (#252) Phase 3a rule SCAN-SM-001 (state assigned a value no CASE label handles, CASE without ELSE), no IDE.
#   P  positives: literal 30 vs labels 0 / 10 / 20; enum member Done missing; declaration initial value 5; 25 outside 10..19;
#      a method writing 99; unqualified enum member labels
#   N  counter-examples: ELSE; value inside a range / list label; named constant label; another CASE on the same selector
#      handles it; library / unknown constant label (label-not-evaluable); sel := nNext (value-not-evaluable); VAR_IN_OUT /
#      VAR_INPUT / GVL selector (written-elsewhere); fb.nState := 99 elsewhere (qualified-access); CASE n + 1 OF (no candidate);
#      ADR(nState) (passed-or-aliased); owner EXTENDS-ed (inherited-use); sel := sel + 1
#   X  suppression (inline / profile), unresolved / requiresDisposition; M metadata; D determinism
# Mock basis: tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13); expectations follow rule-catalog.md
# SCAN-SM-001. Every check looks at the result object, never at localised PowerShell text.
#   powershell.exe -NoProfile -File tests/Unit/lint-rules-3sm.ps1
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
$RSm = 'SCAN-SM-001'
function Diags($r) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $RSm }) }
function Brief($r) { return ((@($r.data.diagnostics | Where-Object { $_.ruleId -eq $RSm } | ForEach-Object { "$($_.variant)@$($_.objectPath):$($_.section):$($_.line) $($_.severity) b=$($_.blocking) s=$($_.suppressed) [$($_.message)]" }) -join '; ') + " code=$($r.error.code)") }
function SkipText($r) { return ((@($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq $RSm } | ForEach-Object { "$($_.objectPath)=$($_.reason)" })) -join ',') }
function Unres($r) { return , @($r.data.unresolved | Where-Object { $_.ruleId -eq $RSm }) }
function NoSm($r) { return ((Diags $r).Count -eq 0) }

$root = Join-Path $env:TEMP ("tcauto-unit-lint3sm-{0}" -f [guid]::NewGuid().ToString('N'))
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
$enum = { param($fx) Add-Dut $fx 'E_St' "TYPE E_St :`n(`n    Idle,`n    Run,`n    Done`n);`nEND_TYPE`n" }
$sm3 = "CASE nState OF`n0:`n    nState := 10;`n10:`n    nState := 20;`n20:`n    nState := 0;`nEND_CASE"

# ================================================================ P  positives
$r = Fb "    nState : INT;`n    b : BOOL;" "CASE nState OF`n0:`n    nState := 10;`n10:`n    nState := 20;`n20:`n    IF b THEN`n        nState := 30;`n    END_IF`nEND_CASE"
$d = Diags $r
Check 'P1 nState := 30, labels 0 / 10 / 20, no ELSE -> one warning value-not-handled at the assignment, in unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'value-not-handled' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and $d[0].section -eq 'implementation' -and $d[0].line -eq 9 -and $d[0].message -like '*30*' -and (Unres $r).Count -eq 1 -and $r.data.requiresDisposition -and $r.success) (Brief $r)
$r = Fb "    eState : E_St;" "CASE eState OF`nE_St.Idle:`n    eState := E_St.Run;`nE_St.Run:`n    eState := E_St.Done;`nEND_CASE" '' $enum
$d = Diags $r
Check 'P2 enum eState := E_St.Done, CASE has no Done -> one finding naming Done' ($d.Count -eq 1 -and $d[0].line -eq 5 -and $d[0].message -like '*Done*') (Brief $r)
$r = Fb "    nState : INT := 5;" "CASE nState OF`n0:`n    nState := 10;`n10:`n    nState := 0;`nEND_CASE"
$d = Diags $r
Check 'P3 declaration initial value 5, CASE has 0 / 10 -> finding at the declaration' ($d.Count -eq 1 -and $d[0].section -eq 'declaration' -and $d[0].line -eq 3 -and $d[0].message -like '*5*') (Brief $r)
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    nState := 15;`n10..19:`n    nState := 25;`nEND_CASE"
$d = Diags $r
Check 'P4 25 outside 10..19 -> one finding (15 is inside the range, not reported)' ($d.Count -eq 1 -and $d[0].line -eq 5 -and $d[0].message -like '*25*') (Brief $r)
$r = Fb "    nState : INT;" $sm3 (Method 'M_Reset' "METHOD M_Reset`n" "nState := 99;")
$d = Diags $r
Check 'P5 a method writes nState := 99 -> finding in the method' ($d.Count -eq 1 -and $d[0].objectPath -eq 'FB_T.M_Reset' -and $d[0].message -like '*99*') (Brief $r)
$r = Fb "    eState : E_St;" "CASE eState OF`nIdle:`n    eState := Run;`nRun:`n    eState := Done;`nEND_CASE" '' $enum
Check 'P6 unqualified enum member labels / values, Done not handled -> finding' ((Diags $r).Count -eq 1 -and (Diags $r)[0].message -like '*Done*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;`n    n2 : INT;" "$sm3`nCASE n2 OF`n1:`n    n2 := 2;`n2:`n    n2 := 1;`nEND_CASE`nnState := 40;`nn2 := 3;"
Check 'P7 two selectors in one FB, each with a missing value -> two findings' ((Diags $r).Count -eq 2) (Brief $r)

# ================================================================ N  counter-examples
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    nState := 10;`n10:`n    nState := 30;`nELSE`n    nState := 0;`nEND_CASE"
Check 'N1 CASE with ELSE -> no finding' (NoSm $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    nState := 15;`n10..19:`n    nState := 0;`nEND_CASE"
Check 'N2 15 inside 10..19 -> no finding' (NoSm $r) (Brief $r)
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    nState := 30;`n30, 40:`n    nState := 0;`nEND_CASE"
Check 'N3 30 inside list label 30, 40 -> no finding' (NoSm $r) (Brief $r)
$r = Fb "    nState : INT;`nEND_VAR`nVAR CONSTANT`n    cDone : INT := 30;" "CASE nState OF`n0:`n    nState := cDone;`ncDone:`n    nState := 0;`nEND_CASE"
Check 'N4 named constant label cDone (= 30) covers nState := cDone -> no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;" "$sm3`nCASE nState OF`n30:`n    nState := 0;`nEND_CASE`nnState := 30;"
Check 'N5 another CASE on the same selector handles 30 -> no finding' (NoSm $r) (Brief $r)
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    nState := 99;`nTc2_Lib.cStep:`n    nState := 0;`nEND_CASE"
Check 'N6 label is a library constant -> no finding, rulesSkipped label-not-evaluable' ((NoSm $r) -and (SkipText $r) -like '*label-not-evaluable:nState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;`n    nNext : INT;" "CASE nState OF`n0:`n    nState := nNext;`n10:`n    nState := 0;`nEND_CASE"
Check 'N7 nState := nNext -> no finding, rulesSkipped value-not-evaluable' ((NoSm $r) -and (SkipText $r) -like '*value-not-evaluable:nState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;`n    nNext : INT;" "CASE nState OF`n0:`n    nState := nNext;`n10:`n    nState := 77;`nEND_CASE"
Check 'N7b nState := nNext plus nState := 77 -> 77 still reported, value-not-evaluable recorded' ((Diags $r).Count -eq 1 -and (SkipText $r) -like '*value-not-evaluable:nState*') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR_IN_OUT`n    nState : INT;`nEND_VAR`n" "CASE nState OF`n0:`n    nState := 30;`nEND_CASE"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'N8 VAR_IN_OUT selector -> no finding, rulesSkipped written-elsewhere' ((NoSm $r) -and (SkipText $r) -like '*written-elsewhere:nState*') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR_INPUT`n    nState : INT;`nEND_VAR`n" "CASE nState OF`n0:`n    nState := 30;`nEND_CASE"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'N8b VAR_INPUT selector -> no finding, rulesSkipped written-elsewhere' ((NoSm $r) -and (SkipText $r) -like '*written-elsewhere:nState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    b : BOOL;" "CASE GVL_S.nGState OF`n0:`n    GVL_S.nGState := 30;`nEND_CASE`nCASE nGState OF`n0:`n    nGState := 30;`nEND_CASE" '' { param($fx) Add-Gvl $fx 'GVL_S' "VAR_GLOBAL`n    nGState : INT;`nEND_VAR`n" }
Check 'N8c GVL selector -> no finding, rulesSkipped written-elsewhere' ((NoSm $r) -and (SkipText $r) -like '*written-elsewhere:nGState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;" $sm3 '' { param($fx) Add-Pou $fx 'MAIN' "PROGRAM MAIN`nVAR`n    fb : FB_T;`nEND_VAR`n" "fb();`nfb.nState := 99;" }
Check 'N9 fb.nState := 99 from MAIN -> no finding, rulesSkipped qualified-access' ((NoSm $r) -and (SkipText $r) -like '*FB_T=qualified-access:nState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    n : INT;" "CASE n + 1 OF`n1:`n    n := 30;`nEND_CASE"
Check 'N10 CASE n + 1 OF -> not a candidate: no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;`n    p : POINTER TO INT;" "$sm3`np := ADR(nState);`nnState := 30;"
Check 'N11 ADR(nState) -> no finding, rulesSkipped passed-or-aliased' ((NoSm $r) -and (SkipText $r) -like '*passed-or-aliased:nState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;" "$sm3`nnState := 30;" '' { param($fx) Add-Pou $fx 'FB_D' "FUNCTION_BLOCK FB_D EXTENDS FB_T`nVAR`nEND_VAR`n" "nState := 30;" }
Check 'N12 FB_T is EXTENDS-ed -> no finding on FB_T, rulesSkipped inherited-use' ((NoSm $r) -and (SkipText $r) -like '*FB_T=inherited-use:nState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    nState := nState + 10;`n10:`n    nState := 0;`nEND_CASE"
Check 'N13 nState := nState + 10 -> no finding, value-not-evaluable' ((NoSm $r) -and (SkipText $r) -like '*value-not-evaluable:nState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    eState : E_St;" "CASE eState OF`nE_St.Idle:`n    eState := E_St.Run;`nE_St.Run, E_St.Done:`n    eState := E_St.Idle;`nEND_CASE`neState := E_St.Done;" '' $enum
Check 'N14 enum: every assigned member handled -> no finding' (NoSm $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    eState : E_Lib;" "CASE eState OF`nE_Lib.A:`n    eState := E_Lib.B;`nEND_CASE"
Check 'N15 selector of a type outside the project -> no finding, rulesSkipped' ((NoSm $r) -and (SkipText $r) -like '*:eState*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    nState := 10;`n10:`n    nState := 20;`nEND_CASE" (Method 'M_Do' "METHOD M_Do`nVAR`n    nState : INT;`nEND_VAR`n" "nState := 99;")
Check 'N16 method local nState (shadowing) := 99 is not the FB variable -> no finding' (NoSm $r) ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    nState : INT;`n    fbX : FB_X;" "$sm3`nfbX(nOut => nState);" '' { param($fx) Add-Pou $fx 'FB_X' "FUNCTION_BLOCK FB_X`nVAR_OUTPUT`n    nOut : INT;`nEND_VAR`n" "nOut := 1;" }
Check 'N17 fbX(nOut => nState) -> no finding, value-not-evaluable' ((NoSm $r) -and (SkipText $r) -like '*value-not-evaluable:nState*') ((Brief $r) + ' ' + (SkipText $r))

# ================================================================ X  suppression / unresolved
$r = Fb "    nState : INT;" "CASE nState OF`n0:`n    // tcauto-lint-disable-next-line SCAN-SM-001: 30 is a deliberate idle state`n    nState := 30;`nEND_CASE"
$d = Diags $r
Check 'X1 inline suppression -> suppressed, not in unresolved' ($d.Count -eq 1 -and $d[0].suppressed -and (Unres $r).Count -eq 0 -and $r.success) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    nState : INT;`nEND_VAR`n" "CASE nState OF`n0:`n    nState := 30;`nEND_CASE"
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"FB_T","ruleId":"SCAN-SM-001","reason":"reviewed: 30 is idle by design"}]}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = Diags $r
Check 'X2 profile suppression -> suppressed, not in unresolved, listed in suppressions[]' ($d.Count -eq 1 -and $d[0].suppressed -and (Unres $r).Count -eq 0 -and @($r.data.suppressions | Where-Object { $_.source -eq 'profile' -and $_.matched -eq 1 }).Count -eq 1) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    nState : INT;`nEND_VAR`n" "CASE nState OF`n0:`n    nState := 30;`nEND_CASE"
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"SCAN-SM-001":{"enabled":false}}}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'X3 rule disabled in the profile -> no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))

# ================================================================ M  metadata
$m = @(& $mod { param($i) $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get($i) } $RSm)[0]
Check 'M SCAN-SM-001 registered: phase 3, warning, not blockable, behavior, compiler no, high, limits written, TE1200 SA0075 / SA0076' ($null -ne $m -and $m.Phase -eq '3' -and $m.Severity -eq 'warning' -and $m.Blockable -eq 'false' -and $m.MachineImpact -eq 'behavior' -and $m.CompilerCatches -eq 'no' -and $m.Confidence -eq 'high' -and $m.Limits.Length -gt 200 -and $m.Te1200 -like '*SA0075*' -and $m.Te1200 -like '*SA0076*') "$($m.Phase) $($m.Severity) $($m.Blockable) $($m.MachineImpact) $($m.CompilerCatches) $($m.Confidence) $($m.Te1200)"

# ================================================================ D  determinism
$fx = New-Fx
Add-Dut $fx 'E_St' "TYPE E_St :`n(`n    Idle,`n    Run,`n    Done`n);`nEND_TYPE`n"
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    nState : INT := 5;`n    eState : E_St;`n    nNext : INT;`nEND_VAR`n" "CASE nState OF`n0:`n    nState := 30;`n10..19:`n    nState := nNext;`nEND_CASE`nCASE eState OF`nE_St.Idle:`n    eState := E_St.Done;`nEND_CASE"
$outs = foreach ($cul in 'en-US', 'zh-TW', 'en-US') {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $cul; [System.Threading.Thread]::CurrentThread.CurrentUICulture = $cul
    $x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj; $x.data.Remove('newSuppressionsBasisReason'); Js $x
}
$x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'D1 three findings (5, 30, Done) and value-not-evaluable on one FB' ((Diags $x).Count -eq 3 -and (SkipText $x) -like '*value-not-evaluable:nState*') ((Brief $x) + ' ' + (SkipText $x))
Check 'D2 two runs and en-US / zh-TW byte-identical' ($outs[0] -ceq $outs[1] -and $outs[0] -ceq $outs[2]) ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
