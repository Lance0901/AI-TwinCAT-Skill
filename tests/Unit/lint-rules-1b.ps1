# Unit: semantic linter (#252) Phase 1b rules, no IDE.
#   T  SCAN-TEMPFB-001 (stateful FB declared as a temporary instance): positives per InfoSys case, negatives
#      (VAR_INST, FB VAR, VAR_STAT, POINTER / REFERENCE, inputs, interface, type-only / unknown types,
#      no name-prefix guessing, conditional pragma), PR #274 review 6-5 M_Wait
#   K  PROJECT-TASK-001 / 002 (call graph from .TcTTO PouCall): reachability, unreachable callers, two
#      tasks, task + program, repeated call, FB caller (warning), uncertain sections, no task
#   S  suppression: inline (next-line / line / object), reasons, unknown id, unmatched, blockable rules
#      (LINT-SUPPRESS-004), profile suppressions, data.suppressions[], newSuppressions[] against git HEAD
#      (not a repo / git unavailable -> basis unavailable, all listed)
#   Y  syntax the 4026.22 compiler rejects (measured 2026-11-13): still notAnalyzed + pass, reason says so
#   D  deterministic: two runs and en-US / zh-TW byte-identical with 1b findings
# Mock basis: tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13). Every check looks at
# the result object (success, error.code, data), never at localised PowerShell text; files are written with
# explicit CRLF bytes, so the result does not depend on the checkout's line endings.
#   powershell.exe -NoProfile -File tests/Unit/lint-rules-1b.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
Import-Module $modulePath -Force -WarningAction SilentlyContinue
. (Join-Path $PSScriptRoot 'lib\LintFixture.ps1')
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 700) { $Detail = $Detail.Substring(0, 700) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function Js($o) { return ($o | ConvertTo-Json -Depth 30 -Compress) }
function Diags($r, [string]$Rule) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $Rule }) }   # ',' keeps a one-element array an array
function Brief($r) { return ((@($r.data.diagnostics | ForEach-Object { "$($_.ruleId)/$($_.variant)@$($_.objectPath):$($_.line) b=$($_.blocking) s=$($_.suppressed)" }) -join '; ') + " code=$($r.error.code)") }

$root = Join-Path $env:TEMP ("tcauto-unit-lint1b-{0}" -f [guid]::NewGuid().ToString('N'))
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
# a POU file in POUs\ plus its <Compile> item; $Extra = XML of Method / Action / Property children
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
function Set-MainImpl($Fx, [string]$Impl) {
    Edit-LintFxFile $Fx.Main { param($t) $t.Replace("fbA(bStart := GVL_Main.bRun);`r`nIF fbA.M_Do(nValue := 1) THEN`r`n    eMode := E_Mode.Auto; // set mode`r`nEND_IF", $Impl.Replace("`n", "`r`n")) }
}
function Set-Profile($Fx, [string]$Json) {
    $dir = Join-Path ([System.IO.Path]::GetDirectoryName($Fx.Sln)) '.tcauto'
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
    $p = Join-Path $dir 'lint-profile.json'
    [System.IO.File]::WriteAllText($p, $Json, (New-Object System.Text.UTF8Encoding($false)))
    return $p
}
# second task PlcTask2 (.TcTTO + matching .tsproj context, same priority so TSPROJ-003 stays quiet)
function Add-Task2($Fx, [string]$PouCall) {
    $t = (Get-LintFxTaskText -PouCall $PouCall).Replace("`r`n", "`n").Replace('Name="PlcTask"', 'Name="PlcTask2"').Replace($script:LintFx.TaskId, '{2c1b0e43-6f0e-4b8e-9f43-2d6f2f0f7a11}')
    Write-LintFxFile (Join-Path $Fx.PlcDir 'PlcTask2.TcTTO') $t
    $Fx.Items.Add('PlcTask2.TcTTO')
    Set-LintFxCompile $Fx $Fx.Items.ToArray()
    Edit-LintFxFile $Fx.Tsproj { param($x) $x.Replace("</Context>`r`n`t`t`t`t`t</Contexts>", "</Context>`r`n`t`t`t`t`t`t<Context>`r`n`t`t`t`t`t`t`t<Id>1</Id>`r`n`t`t`t`t`t`t`t<Name>PlcTask2</Name>`r`n`t`t`t`t`t`t`t<Priority>20</Priority>`r`n`t`t`t`t`t`t</Context>`r`n`t`t`t`t`t</Contexts>") }
}
# task PlcTask with several PouCall entries (here-string newlines normalised: independent of the checkout's EOL)
function TaskWith([string[]]$Calls) {
    $t = (Get-LintFxTaskText -PouCall $Calls[0]).Replace("`r`n", "`n")
    $more = ($Calls | Select-Object -Skip 1 | ForEach-Object { "`n    <PouCall>`n      <Name>$_</Name>`n    </PouCall>" }) -join ''
    return $t.Replace("      <Name>$($Calls[0])</Name>`n    </PouCall>", "      <Name>$($Calls[0])</Name>`n    </PouCall>$more")
}
# FB_Caller.M_Call calls PRG_B; MAIN (on the task) declares an FB_Caller instance and calls the method
function Add-Caller($Fx) {
    Add-Pou $Fx 'FB_Caller' "FUNCTION_BLOCK FB_Caller`nVAR`nEND_VAR`n" '' (Method 'M_Call' "METHOD M_Call : BOOL`n" 'PRG_B();')
    Edit-LintFxFile $Fx.Main { param($t) $t.Replace("    fbA : FB_A;`r`n", "    fbA : FB_A;`r`n    fbC : FB_Caller;`r`n").Replace("END_IF]]>", "END_IF`r`nfbC.M_Call();]]>") }
}
function Lint($Fx, [hashtable]$More = @{}) { return (Invoke-TcLintProject -PlcProjectPath $Fx.Plcproj @More) }

$fbDecl = "FUNCTION_BLOCK {0}`nVAR`n    nX : INT;`nEND_VAR`n"
function Add-FbM($Fx, [string]$Name, [string]$MethodDecl, [string]$MethodImpl = 'nX := 1;') {
    Add-Pou $Fx $Name ($fbDecl -f $Name) '' (Method 'M_Wait' $MethodDecl $MethodImpl)
}

# ================================================================ T  SCAN-TEMPFB-001
# PR #274 second review 6-5: METHOD M_Wait VAR ton : TON; END_VAR ton(IN:=TRUE, PT:=T#2S);
$fx = New-Fx; Add-FbM $fx 'FB_Wait' "METHOD M_Wait : BOOL`nVAR`n    ton : TON;`nEND_VAR`n" "ton(IN := TRUE, PT := T#2S);`nM_Wait := ton.Q;"
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'T1 review 6-5 M_Wait: TON in METHOD VAR -> blocking error, LINT_FAILED' ($d.Count -eq 1 -and $d[0].variant -eq 'method-var' -and $d[0].blocking -and $d[0].severity -eq 'error' -and $d[0].objectPath -eq 'FB_Wait.M_Wait' -and $d[0].section -eq 'declaration' -and $d[0].line -eq 3 -and $r.error.code -eq 'LINT_FAILED' -and $r.data.passed -eq $false) (Brief $r)
Check 'T1 unresolved lists it (behavior, compiler does not catch)' (@($r.data.unresolved | Where-Object { $_.ruleId -eq 'SCAN-TEMPFB-001' }).Count -eq 1) (Js $r.data.unresolved)

$fx = New-Fx; Add-Pou $fx 'F_Edge' "FUNCTION F_Edge : BOOL`nVAR_INPUT`n    bIn : BOOL;`nEND_VAR`nVAR`n    rt : R_TRIG;`nEND_VAR`n" "rt(CLK := bIn);`nF_Edge := rt.Q;"
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'T2 R_TRIG in FUNCTION VAR -> function-var, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'function-var' -and $d[0].blocking -and $d[0].objectPath -eq 'F_Edge') (Brief $r)

$fx = New-Fx; Add-Pou $fx 'FB_Cnt' "FUNCTION_BLOCK FB_Cnt`nVAR_TEMP`n    ctu1 : CTU;`nEND_VAR`n" "ctu1(CU := TRUE, PV := 10);"
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'T3 CTU in FB VAR_TEMP -> var-temp, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'var-temp' -and $d[0].blocking) (Brief $r)

$fx = New-Fx
Edit-LintFxFile $fx.Main { param($t) $t.Replace("    sText : STRING(80) := 'it`$'s (* not a comment *)';`r`nEND_VAR", "    sText : STRING(80) := 'it`$'s (* not a comment *)';`r`nEND_VAR`r`nVAR_TEMP`r`n    tonT : TON;`r`nEND_VAR") }
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'T4 TON in PROGRAM VAR_TEMP -> var-temp, blocking (InfoSys 12050023819: VAR_TEMP instances reinitialized each cycle)' ($d.Count -eq 1 -and $d[0].variant -eq 'var-temp' -and $d[0].blocking -and $d[0].objectPath -eq 'MAIN') (Brief $r)

$fx = New-Fx; Add-FbM $fx 'FB_Arr' "METHOD M_Wait : BOOL`nVAR`n    aTon : ARRAY[1..2] OF TON;`n    q : Tc2_Standard.F_TRIG;`nEND_VAR`n"
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'T5 ARRAY OF TON and qualified Tc2_Standard.F_TRIG in METHOD VAR -> 2 findings' ($d.Count -eq 2 -and @($d | Where-Object { $_.blocking }).Count -eq 2) (Brief $r)

$fx = New-Fx; Add-FbM $fx 'FB_UsesA' "METHOD M_Wait : BOOL`nVAR`n    fbTmp : FB_A;`nEND_VAR`n"
$r = Lint $fx
Check 'T6 project FB in METHOD VAR without profile -> no finding (not known as stateful)' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 0 -and $r.success) (Brief $r)
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","typeCatalog":{"stateful":["FB_A"]}}' | Out-Null
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'T6 profile typeCatalog.stateful FB_A -> reported, blocking' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)

$fx = New-Fx
Edit-LintFxFile $fx.FbA { param($t) $t.Replace("<Get Name=`"Get`" Id=`"$($script:LintFx.FbAGet)`">`r`n        <Declaration><![CDATA[PUBLIC`r`nVAR`r`nEND_VAR]]>", "<Get Name=`"Get`" Id=`"$($script:LintFx.FbAGet)`">`r`n        <Declaration><![CDATA[PUBLIC`r`nVAR`r`n    tp1 : TP;`r`nEND_VAR]]>") }
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'T7 TP in Property Get VAR -> warning accessor-var (no InfoSys source), not blocking, unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'accessor-var' -and -not $d[0].blocking -and $d[0].severity -eq 'warning' -and $r.success -and $r.data.requiresDisposition) (Brief $r)

$fx = New-Fx; Add-FbM $fx 'FB_Inst' "METHOD M_Wait : BOOL`nVAR_INST`n    ton : TON;`nEND_VAR`n"
$r = Lint $fx
Check 'T8 counter-example: METHOD VAR_INST TON -> no finding' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 0 -and $r.success) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'FB_Stat' "FUNCTION_BLOCK FB_Stat`nVAR_STAT`n    ton : TON;`nEND_VAR`nVAR`n    rt : R_TRIG;`nEND_VAR`n" 'ton(IN := TRUE, PT := T#1S); rt(CLK := ton.Q);'
$r = Lint $fx
Check 'T9 counter-example: FB VAR / VAR_STAT TON, R_TRIG -> no finding' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 0 -and $r.success) (Brief $r)

$fx = New-Fx; Add-FbM $fx 'FB_Ptr' "METHOD M_Wait : BOOL`nVAR_INPUT`n    tIn : TON;`nEND_VAR`nVAR_IN_OUT`n    tIo : TON;`nEND_VAR`nVAR`n    pT : POINTER TO TON;`n    rT : REFERENCE TO TON;`n    ton : INT;`nEND_VAR`n"
$r = Lint $fx
Check 'T10 counter-example: POINTER TO / REFERENCE TO / VAR_INPUT / VAR_IN_OUT TON, variable named ton : INT -> no finding' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 0 -and $r.success) (Brief $r)

$fx = New-Fx; Add-FbM $fx 'FB_Mc' "METHOD M_Wait : BOOL`nVAR`n    mcMove : MC_MoveAbsolute;`n    mcX : MC_NotInAnyCatalog;`n    fbX : FB_Somewhere;`nEND_VAR`n"
$r = Lint $fx; $sk = @($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq 'SCAN-TEMPFB-001' })
Check 'T11 no name-prefix guessing: MC_* / unknown types -> no finding, rulesSkipped type-only / unknown-type, pass' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 0 -and $r.success -and @($sk | Where-Object { $_.reason -eq 'type-only:MC_MoveAbsolute' }).Count -eq 1 -and @($sk | Where-Object { $_.reason -eq 'unknown-type:MC_NotInAnyCatalog' }).Count -eq 1 -and @($sk | Where-Object { $_.reason -eq 'unknown-type:FB_Somewhere' }).Count -eq 1) (Js $sk)
Check 'T11 data.typeCatalog reports the versioned catalog' ($r.data.typeCatalog.version -ge 1 -and $r.data.typeCatalog.stateful -ge 13 -and $r.data.typeCatalog.sha256 -match '^[0-9a-f]{64}$') (Js $r.data.typeCatalog)

$fx = New-Fx; Add-FbM $fx 'FB_Cond' "METHOD M_Wait : BOOL`nVAR`n{IF defined (SIM)}`n    ton : TON;`n{END_IF}`nEND_VAR`n"
$r = Lint $fx
Check 'T12 conditional pragma in the declaration -> no finding, rulesSkipped (not a guess)' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 0 -and @($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq 'SCAN-TEMPFB-001' -and $_.objectPath -eq 'FB_Cond.M_Wait' }).Count -eq 1) (Brief $r)

$fx = New-Fx
Edit-LintFxFile $fx.Itf { param($t) $t.Replace("METHOD M_Run : BOOL`r`nVAR_INPUT`r`nEND_VAR", "METHOD M_Run : BOOL`r`nVAR_INPUT`r`n    t : TON;`r`nEND_VAR") }
$r = Lint $fx
Check 'T13 interface method -> no finding' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 0) (Brief $r)

# seeded mutation: the fixture's FB_A.tonDelay (FB VAR, correct) moved into METHOD M_Do VAR
$fx = New-Fx
Edit-LintFxFile $fx.FbA { param($t) $t.Replace("VAR`r`n    tonDelay : TON;`r`n    nState : INT;", "VAR`r`n    nState : INT;").Replace("METHOD M_Do : BOOL`r`nVAR_INPUT`r`n    nValue : INT;`r`nEND_VAR", "METHOD M_Do : BOOL`r`nVAR_INPUT`r`n    nValue : INT;`r`nEND_VAR`r`nVAR`r`n    tonDelay : TON;`r`nEND_VAR") }
$r = Lint $fx
Check 'T14 seeded: TON moved from FB VAR into METHOD VAR -> exactly this finding, nothing else' (@($r.data.diagnostics).Count -eq 1 -and (Diags $r 'SCAN-TEMPFB-001')[0].objectPath -eq 'FB_A.M_Do') (Brief $r)

# ================================================================ K  PROJECT-TASK-001 / 002
$fx = New-Fx; $r = Lint $fx
Check 'K0 pristine fixture: MAIN on the task, called once -> no TASK finding' ((Diags $r 'PROJECT-TASK-001').Count -eq 0 -and (Diags $r 'PROJECT-TASK-002').Count -eq 0 -and @($r.data.diagnostics).Count -eq 0 -and $r.success) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_Orphan' "PROGRAM PRG_Orphan`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-001'
Check 'K1 PROGRAM on no task, called by nobody -> TASK-001 warning, not blocking, unresolved, success' ($d.Count -eq 1 -and $d[0].objectPath -eq 'PRG_Orphan' -and $d[0].section -eq 'declaration' -and $d[0].line -eq 1 -and -not $d[0].blocking -and $d[0].severity -eq 'warning' -and $r.success -and $r.data.requiresDisposition -and @($r.data.unresolved).Count -eq 1) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Set-MainImpl $fx "PRG_B();`nfbA(bStart := GVL_Main.bRun);"
$r = Lint $fx
Check 'K2 PROGRAM called by the task program -> no TASK finding' ((Diags $r 'PROJECT-TASK-001').Count -eq 0 -and (Diags $r 'PROJECT-TASK-002').Count -eq 0 -and $r.success) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;' (Action 'A_Step' 'x := 0;')
Set-MainImpl $fx "PRG_B.A_Step();`nfbA(bStart := GVL_Main.bRun);"
$r = Lint $fx
Check 'K3 only an action of the PROGRAM is called -> reachable, no TASK-001 (rule-catalog: P.ActionX() counts)' ((Diags $r 'PROJECT-TASK-001').Count -eq 0) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Set-MainImpl $fx "IF PRG_B.x > 0 THEN`n    fbA(bStart := GVL_Main.bRun);`nEND_IF"
$r = Lint $fx
Check 'K4 PROGRAM variable only read -> not a call, TASK-001' ((Diags $r 'PROJECT-TASK-001').Count -eq 1) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Add-Caller $fx
$r = Lint $fx
Check 'K5 PROGRAM called from a method of an FB instantiated by the task program -> reachable (no TASK-001); TASK-002 only the fb-or-function-caller warning' ((Diags $r 'PROJECT-TASK-001').Count -eq 0 -and (Diags $r 'PROJECT-TASK-002').Count -eq 1 -and (Diags $r 'PROJECT-TASK-002')[0].variant -eq 'fb-or-function-caller' -and $r.success) (Brief $r)

$fx = New-Fx; Add-Task2 $fx 'MAIN'
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K6 same PROGRAM on two tasks -> TASK-002 two-tasks, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'two-tasks' -and $d[0].blocking -and $d[0].objectPath -eq 'MAIN' -and $r.error.code -eq 'LINT_FAILED' -and (Diags $r 'PROJECT-TSPROJ-003').Count -eq 0) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Add-Pou $fx 'PRG_C' "PROGRAM PRG_C`nVAR`nEND_VAR`n" 'PRG_B();'
Set-MainImpl $fx "PRG_B();`nPRG_C();"
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K7 PROGRAM called unconditionally by two programs that both run every cycle -> TASK-002 two-programs, blocking' ($d.Count -eq 1 -and $d[0].objectPath -eq 'PRG_B' -and $d[0].variant -eq 'two-programs' -and $d[0].blocking) (Brief $r)
$prgC = Join-Path $fx.PlcDir 'POUs\PRG_C.TcPOU'
Edit-LintFxFile $prgC { param($t) $t.Replace('<ST><![CDATA[PRG_B();]]>', "<ST><![CDATA[IF GVL_Main.bRun THEN`r`n    PRG_B();`r`nEND_IF]]>") }
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K7b second caller calls it only inside IF -> possible-double-call warning, not blocking (not certain), unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'possible-double-call' -and -not $d[0].blocking -and $r.success -and $r.data.requiresDisposition) (Brief $r)
Edit-LintFxFile $prgC { param($t) $t.Replace("<ST><![CDATA[IF GVL_Main.bRun THEN`r`n    PRG_B();`r`nEND_IF]]>", '<ST><![CDATA[PRG_B();]]>') }
Edit-LintFxFile $fx.Main { param($t) $t.Replace("PRG_B();`r`nPRG_C();", "IF GVL_Main.bRun THEN`r`n    PRG_C();`r`nEND_IF`r`nPRG_B();") }
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K7c the second caller program itself runs only conditionally -> possible-double-call warning, not blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'possible-double-call' -and -not $d[0].blocking) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Write-LintFxFile $fx.Task (TaskWith @('MAIN', 'PRG_B'))
Set-MainImpl $fx "PRG_B();`nfbA(bStart := GVL_Main.bRun);"
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K8 PROGRAM on the task and called by the task program -> task-and-program, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'task-and-program' -and $d[0].blocking) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Set-MainImpl $fx "PRG_B();`nfbA(bStart := GVL_Main.bRun);`nPRG_B();"
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K9 two unconditional calls in one program body -> repeated-call, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'repeated-call' -and $d[0].blocking) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Set-MainImpl $fx "IF GVL_Main.bRun THEN`n    PRG_B();`nELSE`n    PRG_B();`nEND_IF`nfbA(bStart := GVL_Main.bRun);"
$r = Lint $fx
Check 'K10 counter-example: IF / ELSE branches each call once -> no TASK-002' ((Diags $r 'PROJECT-TASK-002').Count -eq 0 -and $r.success) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Set-MainImpl $fx "PRG_B();`nfbA(bStart := GVL_Main.bRun);"
Add-Caller $fx
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K11 called by the task program and by an FB method -> warning fb-or-function-caller, not blocking, unresolved' ($d.Count -eq 1 -and $d[0].variant -eq 'fb-or-function-caller' -and -not $d[0].blocking -and $d[0].severity -eq 'warning' -and $r.success -and $r.data.requiresDisposition) (Brief $r)

# axis TestCam analogue: an unreachable program calls the task program -> only TASK-001, no TASK-002
$fx = New-Fx; Add-Pou $fx 'TestCam' "PROGRAM TestCam`nVAR`nEND_VAR`n" "CASE GVL_Main.nStep OF`n1: MAIN();`nEND_CASE"
$r = Lint $fx
Check 'K12 unreachable caller (axis TestCam) -> TASK-001 on it, no TASK-002 on MAIN' ((Diags $r 'PROJECT-TASK-001').Count -eq 1 -and (Diags $r 'PROJECT-TASK-002').Count -eq 0) (Brief $r)
Write-LintFxFile $fx.Task (TaskWith @('MAIN', 'TestCam'))
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'K12 variant: TestCam put on the task (calls MAIN inside CASE) -> TASK-002 possible-double-call on MAIN, TASK-001 gone' ((Diags $r 'PROJECT-TASK-001').Count -eq 0 -and $d.Count -eq 1 -and $d[0].objectPath -eq 'MAIN' -and $d[0].variant -eq 'possible-double-call' -and -not $d[0].blocking) (Brief $r)

# a section the linter cannot read (CFC) mentions the program: TASK-001 cannot be decided
$fx = New-Fx; Add-Pou $fx 'PRG_Orphan' "PROGRAM PRG_Orphan`nVAR`nEND_VAR`n" ''
Edit-LintFxFile $fx.FbA { param($t) $t.Replace("<Action Name=`"A_Reset`" Id=`"$($script:LintFx.FbAAction)`">`r`n      <Implementation>`r`n        <ST><![CDATA[nState := 0;]]></ST>", "<Action Name=`"A_Reset`" Id=`"$($script:LintFx.FbAAction)`">`r`n      <Implementation>`r`n        <CFC><XmlArchive><Data><o><v n=`"Name`">`"PRG_Orphan`"</v></o></Data></XmlArchive></CFC>").Replace("    <LineIds Name=`"FB_A.A_Reset`">`r`n      <LineId Id=`"1`" Count=`"0`" />`r`n    </LineIds>`r`n", '') }
$r = Lint $fx
Check 'K13 CFC section mentions the program -> no TASK-001, rulesSkipped call-graph-incomplete' ((Diags $r 'PROJECT-TASK-001').Count -eq 0 -and @($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq 'PROJECT-TASK-001' -and $_.reason -like 'call-graph-incomplete:*' }).Count -eq 1) (Brief $r)

$fx = New-Fx; Add-Pou $fx 'PRG_Orphan' "PROGRAM PRG_Orphan`nVAR`nEND_VAR`n" ''
$fx.Items.Remove('PlcTask.TcTTO') | Out-Null; Set-LintFxCompile $fx $fx.Items.ToArray(); Remove-Item -LiteralPath $fx.Task
Write-LintFxFile $fx.Tsproj (Get-LintFxTsprojText -ContextName 'PlcTask')
$r = Lint $fx
Check 'K14 project without any task (library) -> TASK rules not run (no-task), no finding' ((Diags $r 'PROJECT-TASK-001').Count -eq 0 -and @($r.data.coverage.rulesNotRun | Where-Object { $_.ruleId -eq 'PROJECT-TASK-001' -and $_.reason -eq 'no-task' }).Count -eq 1) (Brief $r)

# ================================================================ S  suppression
function Orphan($Fx, [string]$DeclPrefix, [string]$Body = 'x := 1;') {
    Add-Pou $Fx 'PRG_Orphan' ($DeclPrefix + "PROGRAM PRG_Orphan`nVAR`n    x : INT;`nEND_VAR`n") $Body
}
$fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: PoC harness kept for manual tests`n"
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-001'
Check 'S1 inline next-line with reason -> suppressed, still listed, not unresolved, requiresDisposition false' ($d.Count -eq 1 -and $d[0].suppressed -and $d[0].suppressionReason -eq 'PoC harness kept for manual tests' -and -not $r.data.requiresDisposition -and $r.data.summary.suppressed -eq 1 -and $r.success) (Brief $r)
$s = @($r.data.suppressions)
Check 'S1 data.suppressions lists it (inline, effective, matched 1)' ($s.Count -eq 1 -and $s[0].source -eq 'inline' -and $s[0].kind -eq 'next-line' -and $s[0].effective -and $s[0].matched -eq 1 -and $s[0].objectPath -eq 'PRG_Orphan') (Js $s)
Check 'S1 not a git repository -> newSuppressionsBasis unavailable and every suppression listed as new' ($r.data.newSuppressionsBasis -eq 'unavailable' -and @($r.data.newSuppressions).Count -eq 1 -and $r.data.newSuppressionsBasisReason) (Js $r.data.newSuppressions)

$fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: short`n"
$r = Lint $fx
Check 'S2 reason under 8 characters -> not effective, LINT-SUPPRESS-001, TASK-001 still unresolved' (-not (Diags $r 'PROJECT-TASK-001')[0].suppressed -and (Diags $r 'LINT-SUPPRESS-001').Count -eq 1 -and $r.data.requiresDisposition) (Brief $r)
$fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001`n"
$r = Lint $fx
Check 'S2 no reason at all -> LINT-SUPPRESS-001' (-not (Diags $r 'PROJECT-TASK-001')[0].suppressed -and (Diags $r 'LINT-SUPPRESS-001').Count -eq 1) (Brief $r)

$fx = New-Fx; Orphan $fx "(* tcauto-lint-disable-object PROJECT-TASK-001: PoC harness kept for manual tests *)`n"
$r = Lint $fx
Check 'S3 disable-object in a block comment before the first VAR -> suppressed' ((Diags $r 'PROJECT-TASK-001')[0].suppressed -and (Diags $r 'LINT-SUPPRESS-001').Count -eq 0) (Brief $r)
$fx = New-Fx; Add-Pou $fx 'PRG_Orphan' "PROGRAM PRG_Orphan`nVAR`n    x : INT; // tcauto-lint-disable-object PROJECT-TASK-001: PoC harness kept for manual tests`nEND_VAR`n" 'x := 1;'
$r = Lint $fx
Check 'S3 disable-object after the first VAR -> not effective, LINT-SUPPRESS-001' (-not (Diags $r 'PROJECT-TASK-001')[0].suppressed -and (Diags $r 'LINT-SUPPRESS-001').Count -eq 1) (Brief $r)
$fx = New-Fx; Add-Pou $fx 'PRG_Orphan' "PROGRAM PRG_Orphan // tcauto-lint-disable-line PROJECT-TASK-001: PoC harness kept for manual tests`nVAR`nEND_VAR`n" ''
$r = Lint $fx
Check 'S4 disable-line on the reported line -> suppressed' ((Diags $r 'PROJECT-TASK-001')[0].suppressed) (Brief $r)

$fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-999: PoC harness kept for manual tests`n"
$r = Lint $fx
Check 'S5 unknown rule id -> LINT-SUPPRESS-002, finding not suppressed' ((Diags $r 'LINT-SUPPRESS-002').Count -eq 1 -and -not (Diags $r 'PROJECT-TASK-001')[0].suppressed) (Brief $r)
$fx = New-Fx; Set-MainImpl $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: nothing to suppress on this line`nfbA(bStart := GVL_Main.bRun);"
$r = Lint $fx
Check 'S6 suppression that matches nothing -> LINT-SUPPRESS-003 info, still pass' ((Diags $r 'LINT-SUPPRESS-003').Count -eq 1 -and (Diags $r 'LINT-SUPPRESS-003')[0].severity -eq 'info' -and $r.success) (Brief $r)

# B3: the checked LLM cannot inline-suppress a blocking rule
$fx = New-Fx; Add-FbM $fx 'FB_Wait' "METHOD M_Wait : BOOL`nVAR`n    // tcauto-lint-disable-next-line SCAN-TEMPFB-001: the timer is only used once per call`n    ton : TON;`nEND_VAR`n"
$r = Lint $fx
Check 'S7 inline on blockable SCAN-TEMPFB-001 -> LINT-SUPPRESS-004, finding still blocking' ((Diags $r 'LINT-SUPPRESS-004').Count -eq 1 -and (Diags $r 'SCAN-TEMPFB-001')[0].blocking -and -not (Diags $r 'SCAN-TEMPFB-001')[0].suppressed -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
$fx = New-Fx; Add-Task2 $fx 'MAIN'
Edit-LintFxFile $fx.Main { param($t) $t.Replace('<Declaration><![CDATA[PROGRAM MAIN', "<Declaration><![CDATA[(* tcauto-lint-disable-object PROJECT-TASK-002: both tasks need the program on purpose *)`r`nPROGRAM MAIN") }
$r = Lint $fx
Check 'S7 inline disable-object on blockable PROJECT-TASK-002 -> LINT-SUPPRESS-004, still LINT_FAILED' ((Diags $r 'LINT-SUPPRESS-004').Count -eq 1 -and (Diags $r 'PROJECT-TASK-002')[0].blocking -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"MAIN","ruleId":"PROJECT-TASK-002","reason":"reviewed: both tasks call MAIN on purpose"}]}' | Out-Null
$r = Lint $fx
Check 'S8 profile suppression of blockable TASK-002 -> suppressed, listed in overrides and suppressions[]' ((Diags $r 'PROJECT-TASK-002')[0].suppressed -and @($r.data.profile.overrides | Where-Object { $_.kind -eq 'suppression' }).Count -eq 1 -and @($r.data.suppressions | Where-Object { $_.source -eq 'profile' -and $_.matched -eq 1 }).Count -eq 1) (Brief $r)

$fx = New-Fx
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"MAIN","ruleId":"PROJECT-TASK-002","reason":"reviewed: both tasks call MAIN on purpose"}]}' | Out-Null
$r = Lint $fx
Check 'S9 profile suppression that matches nothing -> LINT-SUPPRESS-003' ((Diags $r 'LINT-SUPPRESS-003').Count -eq 1 -and $r.success) (Brief $r)

# newSuppressions[] against git HEAD
$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) {
    $fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: PoC harness kept for manual tests`n"
    $sol = [System.IO.Path]::GetDirectoryName($fx.Sln)
    $null = & git -C $sol init -q 2>&1; $null = & git -C $sol add -A 2>&1
    $null = & git -C $sol -c user.name=unit -c user.email=unit@example.invalid -c commit.gpgsign=false commit -q -m base 2>&1
    $r = Lint $fx
    Check 'S10 suppression already in git HEAD -> basis git-head, newSuppressions empty' ($r.data.newSuppressionsBasis -eq 'git-head' -and @($r.data.newSuppressions).Count -eq 0 -and @($r.data.suppressions).Count -eq 1) (Js $r.data.newSuppressions)
    Set-MainImpl $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: added after the commit, nothing here`nfbA(bStart := GVL_Main.bRun);"
    Add-Pou $fx 'PRG_New' "// tcauto-lint-disable-next-line PROJECT-TASK-001: new file, not committed yet`nPROGRAM PRG_New`nVAR`nEND_VAR`n" ''
    Set-Profile $fx '{"schema":"tcauto-lint-profile/1","suppressions":[{"objectPath":"PRG_X","ruleId":"PROJECT-TASK-002","reason":"profile entry added after the commit"}]}' | Out-Null
    $r = Lint $fx; $ns = @($r.data.newSuppressions)
    Check 'S10 new inline in a committed file, inline in an untracked file, new profile entry -> 3 new, the committed one not' ($ns.Count -eq 3 -and @($ns | Where-Object { $_.objectPath -eq 'PRG_Orphan' }).Count -eq 0 -and @($ns | Where-Object { $_.source -eq 'profile' }).Count -eq 1) (Js $ns)
    & $mod { $script:TcLintGitExe = 'git-does-not-exist-tcauto' }
    $r = Lint $fx
    & $mod { $script:TcLintGitExe = $null }
    Check 'S11 git unavailable -> basis unavailable, all suppressions new (fail closed)' ($r.data.newSuppressionsBasis -eq 'unavailable' -and @($r.data.newSuppressions).Count -eq @($r.data.suppressions).Count -and @($r.data.suppressions).Count -eq 4) (Js $r.data.newSuppressionsBasisReason)
}
else { Check 'S10 git available for the newSuppressions tests' $false 'git not found' }

# ================================================================ R  counter-examples from the first review (PR #283)
# R1 blocker: a rule the profile made blocking cannot be suppressed inline
$fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: agent says harness only`n"
Set-Profile $fx '{"schema":"tcauto-lint-profile/1","rules":{"PROJECT-TASK-001":{"blocking":true}}}' | Out-Null
$r = Lint $fx
Check 'R1 profile blocking TASK-001 + inline -> LINT-SUPPRESS-004, still LINT_FAILED' ((Diags $r 'LINT-SUPPRESS-004').Count -eq 1 -and -not (Diags $r 'PROJECT-TASK-001')[0].suppressed -and $r.error.code -eq 'LINT_FAILED') (Brief $r)
# R2 non-blocking variants of a blockable rule can be suppressed inline
$fx = New-Fx
Edit-LintFxFile $fx.FbA { param($t) $t.Replace("<Get Name=`"Get`" Id=`"$($script:LintFx.FbAGet)`">`r`n        <Declaration><![CDATA[PUBLIC`r`nVAR`r`nEND_VAR]]>", "<Get Name=`"Get`" Id=`"$($script:LintFx.FbAGet)`">`r`n        <Declaration><![CDATA[PUBLIC`r`nVAR`r`n    // tcauto-lint-disable-next-line SCAN-TEMPFB-001: pulse only evaluated inside this call`r`n    tp1 : TP;`r`nEND_VAR]]>") }
$r = Lint $fx
Check 'R2 accessor-var (warning variant) + inline -> suppressed, no LINT-SUPPRESS-004' ((Diags $r 'SCAN-TEMPFB-001')[0].suppressed -and (Diags $r 'LINT-SUPPRESS-004').Count -eq 0 -and -not $r.data.requiresDisposition) (Brief $r)
# R3 double calls inside one caller that are not mutually exclusive
foreach ($c in @(
        @('action of the caller', "PRG_B();`nA1();", 'PRG_B();'),
        @('IF + unconditional', "IF GVL_Main.bRun THEN`n    PRG_B();`nEND_IF`nPRG_B();", $null),
        @('FOR loop', "FOR nI := 1 TO 2 DO`n    PRG_B();`nEND_FOR", $null),
        @('two calls in one IF branch', "IF GVL_Main.bRun THEN`n    PRG_B();`n    PRG_B();`nEND_IF", $null))) {
    $fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
    Edit-LintFxFile $fx.Main { param($t) $t.Replace("    fbA : FB_A;`r`n", "    fbA : FB_A;`r`n    nI : INT;`r`n") }
    if ($c[2]) { Edit-LintFxFile $fx.Main { param($t) $t.Replace("    </Implementation>`r`n  </POU>", "    </Implementation>" + ((Action 'A1' $c[2]) -replace "`n", "`r`n") + "`r`n  </POU>") } }
    Set-MainImpl $fx $c[1]
    $r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
    Check "R3 $($c[0]) -> TASK-002 possible-double-call warning (must be disposed)" ($d.Count -eq 1 -and $d[0].variant -eq 'possible-double-call' -and $r.data.requiresDisposition) (Brief $r)
}
$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Set-MainImpl $fx "CASE GVL_Main.nStep OF`n1: PRG_B();`n2: PRG_B();`nELSE`n    PRG_B();`nEND_CASE"
$r = Lint $fx
Check 'R3 counter-example: different CASE labels and ELSE -> no TASK-002' ((Diags $r 'PROJECT-TASK-002').Count -eq 0) (Brief $r)
# R4 a conditional pragma in the caller must not hide its other calls
$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := x + 1;'
Write-LintFxFile $fx.Task (TaskWith @('MAIN', 'PRG_B'))
Set-MainImpl $fx "PRG_B();`n{IF defined (SIM)}`nfbA(bStart := TRUE);`n{END_IF}"
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'R4 empty-ish {IF} region in the caller -> still task-and-program, blocking' ($d.Count -eq 1 -and $d[0].variant -eq 'task-and-program' -and $d[0].blocking) (Brief $r)
# R5 a conditional pragma in the declaration must not hide a TON outside it
$fx = New-Fx; Add-FbM $fx 'FB_Wait' "METHOD M_Wait : BOOL`nVAR`n    ton : TON;`nEND_VAR`n{IF defined (NEVER)}`n{END_IF}`n"
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'R5 TON outside the {IF} region of the declaration -> reported, blocking' ($d.Count -eq 1 -and $d[0].blocking) (Brief $r)
# R6 project alias / EXTENDS of a stateful type; other project FB -> coverage
$fx = New-Fx
Write-LintFxFile (Join-Path $fx.PlcDir 'DUTs\T_Timer.TcDUT') ((Get-LintFxDutText).Replace('E_Mode', 'T_Timer').Replace($script:LintFx.DutId, (New-Id)) -replace '(?s)<!\[CDATA\[.*?\]\]>', "<![CDATA[TYPE T_Timer : TON;`r`nEND_TYPE`r`n]]>")
$fx.Items.Add('DUTs\T_Timer.TcDUT'); Set-LintFxCompile $fx $fx.Items.ToArray()
Add-Pou $fx 'FB_MyTon' "FUNCTION_BLOCK FB_MyTon EXTENDS TON`nVAR`nEND_VAR`n" ''
Add-FbM $fx 'FB_Use' "METHOD M_Wait : BOOL`nVAR`n    t1 : T_Timer;`n    t2 : FB_MyTon;`n    t3 : FB_A;`nEND_VAR`n"
$r = Lint $fx; $d = Diags $r 'SCAN-TEMPFB-001'
Check 'R6 alias of TON and FB EXTENDS TON in METHOD VAR -> 2 findings; other project FB -> rulesSkipped project-type' ($d.Count -eq 2 -and @($r.data.coverage.rulesSkipped | Where-Object { $_.reason -eq 'project-type:FB_A' }).Count -eq 1) (Brief $r)
# R7 git that hangs -> unavailable within the deadline
$fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: PoC harness kept for manual tests`n"
$fake = Join-Path $root 'fake-git.cmd'
[System.IO.File]::WriteAllText($fake, "@ping -n 40 127.0.0.1 >nul`r`n", (New-Object System.Text.UTF8Encoding($false)))
& $mod { param($f) $script:TcLintGitExe = $f } $fake
$sw = [System.Diagnostics.Stopwatch]::StartNew(); $r = Lint $fx; $sw.Stop()
& $mod { $script:TcLintGitExe = $null }
Check 'R7 hanging git -> newSuppressionsBasis unavailable, lint returns within ~15 s' ($r.data.newSuppressionsBasis -eq 'unavailable' -and $sw.Elapsed.TotalSeconds -lt 30 -and @($r.data.newSuppressions).Count -eq 1) ("sec=$([int]$sw.Elapsed.TotalSeconds) basis=$($r.data.newSuppressionsBasis)")
# R8 path given in other upper / lower case -> HEAD comparison still works
if ($git) {
    $fx = New-Fx; Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: PoC harness kept for manual tests`n"
    $sol = [System.IO.Path]::GetDirectoryName($fx.Sln)
    $null = & git -C $sol init -q 2>&1; $null = & git -C $sol add -A 2>&1
    $null = & git -C $sol -c user.name=unit -c user.email=unit@example.invalid -c commit.gpgsign=false commit -q -m base 2>&1
    $r = Invoke-TcLintProject -PlcProjectPath $fx.Plcproj.ToUpperInvariant()
    Check 'R8 -PlcProjectPath in upper case -> basis git-head, committed suppression not new' ($r.data.newSuppressionsBasis -eq 'git-head' -and @($r.data.newSuppressions).Count -eq 0) (Js $r.data.newSuppressions)
}
# R9 array bound naming a program is not a call / type reference
$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := 1;'
Edit-LintFxFile $fx.Main { param($t) $t.Replace("    fbA : FB_A;`r`n", "    fbA : FB_A;`r`n    aB : ARRAY[0..PRG_B.x] OF INT;`r`n") }
$r = Lint $fx
Check 'R9 ARRAY[0..PRG_B.x] does not make PRG_B reachable -> TASK-001' ((Diags $r 'PROJECT-TASK-001').Count -eq 1) (Brief $r)
# R10 program called only from a FUNCTION -> warning (how often the function runs is not analysed)
$fx = New-Fx; Add-Pou $fx 'PRG_B' "PROGRAM PRG_B`nVAR`n    x : INT;`nEND_VAR`n" 'x := 1;'
Add-Pou $fx 'F_Call' "FUNCTION F_Call : BOOL`nVAR_INPUT`nEND_VAR`n" 'PRG_B();'
Set-MainImpl $fx "F_Call();`nF_Call();"
$r = Lint $fx; $d = Diags $r 'PROJECT-TASK-002'
Check 'R10 program called from a FUNCTION -> fb-or-function-caller warning' ($d.Count -eq 1 -and $d[0].variant -eq 'fb-or-function-caller' -and -not $d[0].blocking) (Brief $r)

# ================================================================ Y  syntax the compiler rejects
foreach ($c in @(@('**', 'nState := 2 ** 3;', 'power-operator'), @('T#-5S', 'tonDelay(IN := bStart, PT := T#-5S);', 'negative-time-literal'), @('?=', 'nState ?= nState;', 'assignment-attempt'))) {
    $fx = New-Fx
    Edit-LintFxFile $fx.FbA { param($t) $t.Replace('tonDelay(IN := bStart, PT := T#2S);', $c[1]) }
    $r = Lint $fx; $na = @($r.data.coverage.notAnalyzed | Where-Object { $_.objectPath -eq 'FB_A' })
    Check "Y $($c[0]) -> still notAnalyzed and pass; coverage reason names the 4026.22 rejection" ($r.success -and $na.Count -eq 1 -and $na[0].reason -like "unverified-syntax:$($c[2])*4026.22 compiler rejects*") (Js $na)
}
$rule = @(& $mod { $t = (Get-TcLintEngine).Namespace; ("$t.RuleRegistry" -as [type])::Get('LINT-PARSE-002') })[0]
Check 'Y rule metadata (GetLintRule source) names the measured rejections' ($rule.Limits -like '*4026.22 compiler rejected*') $rule.Limits

# ================================================================ D  determinism with 1b findings
$fx = New-Fx; Add-FbM $fx 'FB_Wait' "METHOD M_Wait : BOOL`nVAR`n    ton : TON;`nEND_VAR`n"
Orphan $fx "// tcauto-lint-disable-next-line PROJECT-TASK-001: PoC harness kept for manual tests`n"
$outs = foreach ($cul in 'en-US', 'zh-TW', 'en-US') {
    [System.Threading.Thread]::CurrentThread.CurrentCulture = $cul; [System.Threading.Thread]::CurrentThread.CurrentUICulture = $cul
    $x = Lint $fx; $x.data.Remove('newSuppressionsBasisReason'); Js $x
}
Check 'D1 two runs and en-US / zh-TW byte-identical' ($outs[0] -ceq $outs[1] -and $outs[0] -ceq $outs[2]) ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
