# Unit: semantic linter (#252) Phase 3a rule SCAN-REF-001 (REFERENCE / POINTER dereferenced while it may still be 0), no IDE.
#   P  positives: FB VAR REFERENCE read, PROGRAM POINTER := 0 then p^, method-local REFERENCE, __ISVALIDREF(r) AND r (AND
#      evaluates every operand: InfoSys AND_THEN 2528923787), use after an IF __ISVALIDREF block, FUNCTION local pointer
#   N  counter-examples: REF= initial value, unconditional REF= before the use, FB_init / method assignment
#      (assigned-elsewhere), VAR_IN_OUT / VAR_INPUT (caller-provided), IF __ISVALIDREF THEN, IF NOT __ISVALIDREF THEN RETURN,
#      AND_THEN, ELSE of IF NOT __ISVALIDREF, pointer ADR initial value, p := ADR before p^, IF p <> 0, IF p = 0 THEN RETURN,
#      p <> 0 AND_THEN p^, fb.r REF= from another POU (qualified-access), EXTENDS-ed FB (inherited-use), r passed to a call
#      (passed-or-aliased), guard through a BOOL (guard-not-understood), no use at all, shadowing method local
#   X  suppression (inline / profile), unresolved / requiresDisposition; M metadata; D determinism
# Mock basis: tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13); machine impact measured 2026-11-13
# (verification/runtime-semantics-measured.md section 8: page fault, UmRT process crashes afterwards). Every check looks
# at the result object, never at localised PowerShell text.
#   powershell.exe -NoProfile -File tests/Unit/lint-rules-3ref.ps1
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
$RSm = 'SCAN-REF-001'
function Diags($r) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $RSm }) }
function Brief($r) { return ((@($r.data.diagnostics | Where-Object { $_.ruleId -eq $RSm } | ForEach-Object { "$($_.variant)@$($_.objectPath):$($_.section):$($_.line) $($_.severity) b=$($_.blocking) s=$($_.suppressed) [$($_.message)]" }) -join '; ') + " code=$($r.error.code)") }
function SkipText($r) { return ((@($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq $RSm } | ForEach-Object { "$($_.objectPath)=$($_.reason)" })) -join ',') }
function Unres($r) { return , @($r.data.unresolved | Where-Object { $_.ruleId -eq $RSm }) }
function NoSm($r) { return ((Diags $r).Count -eq 0) }

$root = Join-Path $env:TEMP ("tcauto-unit-lint3ref-{0}" -f [guid]::NewGuid().ToString('N'))
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
function V($r) { return @((Diags $r) | ForEach-Object { $_.variant }) -join ',' }

# ================================================================ P  positives
$r = Fb "    refI : REFERENCE TO INT;`n    n : INT;" "n := refI;"
$d = Diags $r
Check 'P1 FB VAR REFERENCE read without REF= / guard -> one warning reference-unassigned, in unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'reference-unassigned' -and $d[0].severity -eq 'warning' -and -not $d[0].blocking -and $d[0].line -eq 1 -and $d[0].objectPath -eq 'FB_T' -and (Unres $r).Count -eq 1 -and $r.data.requiresDisposition -and $r.success) (Brief $r)
$r = Prg "    pI : POINTER TO INT := 0;`n    n : INT;" "n := pI^;"
Check 'P2 PROGRAM POINTER := 0 then pI^ -> pointer-unassigned' ((V $r) -eq 'pointer-unassigned') (Brief $r)
$r = Fb "    n : INT;" "M_Do();" (Method 'M_Do' "METHOD M_Do`nVAR`n    r : REFERENCE TO INT;`nEND_VAR`n" "n := r + 1;")
$d = Diags $r
Check 'P3 method-local REFERENCE read -> finding in the method' ($d.Count -eq 1 -and $d[0].objectPath -eq 'FB_T.M_Do') (Brief $r)
$r = Fb "    r : REFERENCE TO INT;`n    b : BOOL;" "IF __ISVALIDREF(r) AND r > 0 THEN`n    b := TRUE;`nEND_IF"
Check 'P4 __ISVALIDREF(r) AND r > 0 (AND evaluates every operand) -> finding' ((V $r) -eq 'reference-unassigned') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "IF __ISVALIDREF(r) THEN`n    n := r;`nEND_IF`nn := r + 1;"
$d = Diags $r
Check 'P5 use after the guarded IF block -> finding at line 4' ($d.Count -eq 1 -and $d[0].line -eq 4) ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Pou $fx 'F_Get' "FUNCTION F_Get : INT`nVAR`n    p : POINTER TO INT;`nEND_VAR`n" "F_Get := p^;"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'P6 FUNCTION local POINTER (no initial value) p^ -> pointer-unassigned' ((V $r) -eq 'pointer-unassigned') (Brief $r)
$r = Fb "    r : REFERENCE TO INT;" "r := 5;"
Check 'P7 write through an unassigned REFERENCE -> finding' ((V $r) -eq 'reference-unassigned') (Brief $r)

# ================================================================ N  counter-examples
$r = Fb "    x : INT;`n    r : REFERENCE TO INT REF= x;`n    n : INT;" "n := r;"
Check 'N1 REF= initial value -> no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    x : INT;`n    r : REFERENCE TO INT;`n    n : INT;" "r REF= x;`nn := r;"
Check 'N2 unconditional REF= before the use in the same section -> no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "n := r;" (Method 'FB_init' "METHOD FB_init : BOOL`nVAR_INPUT`n    bInitRetains : BOOL;`n    bInCopyCode : BOOL;`n    rIn : REFERENCE TO INT;`nEND_VAR`n" "r REF= rIn;")
Check 'N3 FB_init assigns REF= -> no finding, rulesSkipped assigned-elsewhere' ((NoSm $r) -and (SkipText $r) -like '*assigned-elsewhere:r*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "n := r;" (Method 'M_Init' "METHOD M_Init`nVAR_IN_OUT`n    x : INT;`nEND_VAR`n" "r REF= x;")
Check 'N4 method M_Init assigns -> no finding, assigned-elsewhere' ((NoSm $r) -and (SkipText $r) -like '*assigned-elsewhere:r*') ((Brief $r) + ' ' + (SkipText $r))
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR_IN_OUT`n    r : REFERENCE TO INT;`nEND_VAR`nVAR_INPUT`n    r2 : REFERENCE TO INT;`nEND_VAR`nVAR`n    n : INT;`nEND_VAR`n" "n := r + r2;"
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'N5 VAR_IN_OUT / VAR_INPUT REFERENCE -> no finding, rulesSkipped caller-provided (both)' ((NoSm $r) -and (SkipText $r) -like '*caller-provided:r,*' -and (SkipText $r) -like '*caller-provided:r2*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "IF __ISVALIDREF(r) THEN`n    n := r;`nEND_IF"
Check 'N6 IF __ISVALIDREF(r) THEN use -> no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "IF NOT __ISVALIDREF(r) THEN`n    RETURN;`nEND_IF`nn := r;"
Check 'N7 IF NOT __ISVALIDREF(r) THEN RETURN; END_IF before the use -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    b : BOOL;" "b := __ISVALIDREF(r) AND_THEN r > 0;"
Check 'N8 __ISVALIDREF(r) AND_THEN r > 0 -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "IF NOT __ISVALIDREF(r) THEN`n    n := 0;`nELSE`n    n := r;`nEND_IF"
Check 'N9 ELSE branch of IF NOT __ISVALIDREF(r) -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Prg "    x : INT;`n    p : POINTER TO INT := ADR(x);`n    n : INT;" "n := p^;"
Check 'N10 POINTER initial value ADR(x) -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Prg "    x : INT;`n    p : POINTER TO INT;`n    n : INT;" "p := ADR(x);`nn := p^;"
Check 'N11 p := ADR(x) before p^ -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Prg "    p : POINTER TO INT;`n    n : INT;" "IF p <> 0 THEN`n    n := p^;`nEND_IF"
Check 'N12 IF p <> 0 THEN p^ -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Prg "    p : POINTER TO INT;`n    n : INT;" "IF p = 0 THEN`n    RETURN;`nEND_IF`nn := p^;"
Check 'N13 IF p = 0 THEN RETURN before p^ -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Prg "    p : POINTER TO INT;`n    b : BOOL;" "b := p <> 0 AND_THEN p^ = 99;"
Check 'N14 p <> 0 AND_THEN p^ = 99 (InfoSys example) -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "n := r;" '' { param($fx) Add-Pou $fx 'MAIN' "PROGRAM MAIN`nVAR`n    fb : FB_T;`n    x : INT;`nEND_VAR`n" "fb.r REF= x;`nfb();" }
Check 'N15 fb.r REF= x from MAIN -> no finding, qualified-access' ((NoSm $r) -and (SkipText $r) -like '*qualified-access:r*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "n := r;" '' { param($fx) Add-Pou $fx 'FB_D' "FUNCTION_BLOCK FB_D EXTENDS FB_T`nVAR`n    x : INT;`nEND_VAR`n" "r REF= x;`nSUPER^();" }
Check 'N16 FB_T EXTENDS-ed (derived FB may assign) -> no finding, inherited-use' ((NoSm $r) -and (SkipText $r) -like '*inherited-use:r*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    fbX : FB_X;" "fbX(io := r);" '' { param($fx) Add-Pou $fx 'FB_X' "FUNCTION_BLOCK FB_X`nVAR_IN_OUT`n    io : INT;`nEND_VAR`n" "io := 1;" }
Check 'N17 r handed to a call argument -> no finding, passed-or-aliased' ((NoSm $r) -and (SkipText $r) -like '*passed-or-aliased:r*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    bOk : BOOL;`n    n : INT;" "bOk := __ISVALIDREF(r);`nIF bOk THEN`n    n := r;`nEND_IF"
Check 'N18 guard through a BOOL -> no finding, guard-not-understood' ((NoSm $r) -and (SkipText $r) -like '*guard-not-understood:r*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "n := 1;"
Check 'N19 REFERENCE never used -> no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    x : INT;`n    b : BOOL;`n    n : INT;" "IF b THEN`n    r REF= x;`nEND_IF`nn := r;"
Check 'N20 conditional REF= before the use -> no finding, assigned-elsewhere' ((NoSm $r) -and (SkipText $r) -like '*assigned-elsewhere:r*') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "IF __ISVALIDREF(r) THEN`n    IF n > 0 THEN`n        n := r;`n    END_IF`nELSIF n < 0 THEN`n    n := 0;`nEND_IF"
Check 'N21 nested IF inside the guarded branch -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "IF NOT __ISVALIDREF(r) OR n < 0 THEN`n    RETURN;`nEND_IF`nn := r;"
Check 'N22 IF NOT __ISVALIDREF(r) OR n < 0 THEN RETURN -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "n := 1;" (Method 'M_Do' "METHOD M_Do`nVAR`n    r : INT;`nEND_VAR`n" "n := r;")
Check 'N23 method local INT r shadows the FB reference -> no finding' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))

# ================================================================ X  suppression / unresolved
$r = Fb "    r : REFERENCE TO INT;`n    n : INT;" "// tcauto-lint-disable-next-line SCAN-REF-001: r is set by the HMI before start`nn := r;"
$d = Diags $r
Check 'X1 inline suppression -> suppressed, not in unresolved' ($d.Count -eq 1 -and $d[0].suppressed -and (Unres $r).Count -eq 0 -and $r.success) (Brief $r)
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    r : REFERENCE TO INT;`n    n : INT;`nEND_VAR`n" "n := r;"
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"FB_T","ruleId":"SCAN-REF-001","reason":"reviewed: set through a library mechanism"}]}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
$d = Diags $r
Check 'X2 profile suppression -> suppressed, not in unresolved' ($d.Count -eq 1 -and $d[0].suppressed -and (Unres $r).Count -eq 0) (Brief $r)
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"SCAN-REF-001":{"enabled":false}}}'
$r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'X3 rule disabled -> no finding, no skip' ((NoSm $r) -and (SkipText $r) -eq '') ((Brief $r) + ' ' + (SkipText $r))

# ================================================================ M  metadata
$m = @(& $mod { param($i) $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get($i) } $RSm)[0]
Check 'M SCAN-REF-001: phase 3, warning, not blockable, crash, compiler measured no, medium, measured impact, TE1200 SA0039 / SA0145' ($null -ne $m -and $m.Phase -eq '3' -and $m.Severity -eq 'warning' -and $m.Blockable -eq 'false' -and $m.MachineImpact -eq 'crash' -and $m.CompilerCatches -like 'measured:2026-11-13*no*' -and $m.Confidence -eq 'medium' -and $null -eq $m.ImpactBasis -and $m.Te1200 -like '*SA0039*' -and $m.Te1200 -like '*SA0145*' -and $m.Limits.Length -gt 200) "$($m.Phase) $($m.Severity) $($m.Blockable) $($m.MachineImpact) $($m.CompilerCatches) $($m.Confidence) $($m.ImpactBasis) $($m.Te1200)"

# ================================================================ D  determinism
$fx = New-Fx
Add-Pou $fx 'FB_T' "FUNCTION_BLOCK FB_T`nVAR`n    r : REFERENCE TO INT;`n    p : POINTER TO INT;`n    q : REFERENCE TO INT;`n    n : INT;`nEND_VAR`n" "n := r + p^;`nn := q;" (Method 'M_Set' "METHOD M_Set`nVAR_IN_OUT`n    x : INT;`nEND_VAR`n" "q REF= x;")
$outs = foreach ($cul in 'en-US', 'zh-TW', 'en-US') {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $cul; [System.Threading.Thread]::CurrentThread.CurrentUICulture = $cul
    $x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj; $x.data.Remove('newSuppressionsBasisReason'); Js $x
}
$x = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj
Check 'D1 r / p reported, q assigned-elsewhere' ((Diags $x).Count -eq 2 -and (SkipText $x) -like '*assigned-elsewhere:q*') ((Brief $x) + ' ' + (SkipText $x))
Check 'D2 two runs and en-US / zh-TW byte-identical' ($outs[0] -ceq $outs[1] -and $outs[0] -ceq $outs[2]) ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
