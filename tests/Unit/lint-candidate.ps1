# Unit: semantic linter (#252) Phase 2a - Invoke-TcLintCandidate (MCP LintCandidate), no IDE.
#   O  overlay on the disk project: unchanged object = LintProject -Scope Object; replaced POU / Method / Action /
#      accessor / GVL; new object (COMPILE-001 skipped, no GUID / LineIds noise); new member; findings of the candidate
#   B  overlay boundaries -> LINT_INPUT_INVALID (design.md D2): keyword / name mismatch, other kind on disk, missing
#      parent / property, Transition, implementation for DUT / interface method, declaration for an Action, non-ST
#   X  text-only: self-contained -> pass (contextLevel text-only); context needed -> LINT_CONTEXT_REQUIRED (never pass),
#      rules that need no context still run; code order PARSE_FAILED > CONTEXT_REQUIRED > FAILED (design.md D4)
#   N  newSuppressions[] against the disk version of the object (tasks 2.2)
#   R  read-only: no file of the project changes; D  deterministic: two runs, en-US / zh-TW processes byte-identical
# Mock basis: tests/Unit/lib/LintFixture.ps1 (XAE format, observed corpus 2026-11-13). Checks look at the result object
# (success, error.code, data), never at localised PowerShell text; fixture files are written with explicit CRLF bytes.
#   powershell.exe -NoProfile -File tests/Unit/lint-candidate.ps1
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
function Diags($r, [string]$Rule) { return , @($r.data.diagnostics | Where-Object { $_.ruleId -eq $Rule }) }
function Brief($r) { return ((@($r.data.diagnostics | ForEach-Object { "$($_.ruleId)/$($_.variant)@$($_.objectPath):$($_.line) b=$($_.blocking) s=$($_.suppressed)" }) -join '; ') + " code=$($r.error.code) ov=$($r.data.candidate.overlay) msg=$($r.error.message)") }
function DiagKeys($r) { return (@($r.data.diagnostics | ForEach-Object { "$($_.ruleId)|$($_.variant)|$($_.severity)|$($_.blocking)|$($_.file)|$($_.objectPath)|$($_.section)|$($_.line)|$($_.column)|$($_.message)" }) -join "`n") }

$root = Join-Path $env:TEMP ("tcauto-unit-lintcand-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$root = & $mod { param($p) Get-TcLongPath $p } $root   # CI %TEMP% is an 8.3 short path
$fx = New-LintFixture (Join-Path $root 'f')
$Plc = $fx.Plcproj
function Cand([hashtable]$A) { return (Invoke-TcLintCandidate @A) }
function Hashes {
    $h = [ordered]@{}
    foreach ($f in (Get-ChildItem -LiteralPath $fx.Root -Recurse -File | Sort-Object FullName)) { $h[$f.FullName] = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash + ':' + $f.LastWriteTimeUtc.Ticks }
    return (Js $h)
}
$before = Hashes
$mainDecl = "PROGRAM MAIN`r`nVAR`r`n    fbA : FB_A;`r`n    eMode : E_Mode;`r`n    sText : STRING(80) := 'it`$'s (* not a comment *)';`r`nEND_VAR`r`n"
$mainImpl = "fbA(bStart := GVL_Main.bRun);`r`nIF fbA.M_Do(nValue := 1) THEN`r`n    eMode := E_Mode.Auto; // set mode`r`nEND_IF"
$fbaDecl = "FUNCTION_BLOCK FB_A`r`nVAR_INPUT`r`n    bStart : BOOL;`r`nEND_VAR`r`nVAR`r`n    tonDelay : TON;`r`n    nState : INT;`r`nEND_VAR`r`n"
$fbaImpl = "(* main body *)`r`ntonDelay(IN := bStart, PT := T#2S);`r`nIF tonDelay.Q THEN`r`n    nState := 1;`r`nEND_IF"

# ================================================================ O  overlay
$p = Invoke-TcLintProject -PlcProjectPath $Plc -Scope Object -ObjectPaths MAIN
$r = Cand @{ ObjectKind = 'Program'; ObjectName = 'MAIN'; Declaration = $mainDecl; Implementation = $mainImpl; PlcProjectPath = $Plc }
Check 'O1 unchanged MAIN laid over the project = LintProject -Scope Object MAIN (diagnostics, verdict)' ($r.success -and $r.data.candidate.overlay -eq 'replaced' -and $r.data.contextLevel -eq 'project' -and (DiagKeys $r) -ceq (DiagKeys $p) -and $r.data.verdict -eq $p.data.verdict -and $r.data.source.kind -eq 'candidate-overlay') ((Brief $r) + ' / ' + (Brief $p))
Check 'O1 candidate file / objectPath reported' ($r.data.candidate.file -eq 'POUs/MAIN.TcPOU' -and $r.data.candidate.objectPath -eq 'MAIN' -and $r.data.candidate.objectKind -eq 'Program') (Js $r.data.candidate)

$p = Invoke-TcLintProject -PlcProjectPath $Plc -Scope Object -ObjectPaths FB_A
$r = Cand @{ ObjectKind = 'FunctionBlock'; ObjectName = 'FB_A'; Declaration = $fbaDecl; Implementation = $fbaImpl; PlcProjectPath = $Plc }
Check 'O2 unchanged FB_A (with LineIds, members) = LintProject -Scope Object FB_A' ($r.success -and (DiagKeys $r) -ceq (DiagKeys $p)) ((Brief $r) + ' / ' + (Brief $p))

$r = Cand @{ ObjectKind = 'Method'; ObjectName = 'FB_A.M_Do'; Declaration = "METHOD M_Do : BOOL`r`nVAR`r`n    tonWait : TON;`r`nEND_VAR`r`n"; Implementation = "tonWait(IN := TRUE, PT := T#1S);`r`nM_Do := tonWait.Q;"; PlcProjectPath = $Plc }
$d = Diags $r 'SCAN-TEMPFB-001'
Check 'O3 replaced method with TON in METHOD VAR -> SCAN-TEMPFB-001 blocking on FB_A.M_Do, LINT_FAILED' ($d.Count -eq 1 -and $d[0].objectPath -eq 'FB_A.M_Do' -and $d[0].blocking -and $d[0].line -eq 3 -and $r.error.code -eq 'LINT_FAILED' -and $r.data.passed -eq $false -and $r.data.candidate.overlay -eq 'replaced') (Brief $r)
Check 'O3 changed line count of the candidate section: no PROJECT-LINEIDS-001 (XAE rewrites LineIds when it writes)' ((Diags $r 'PROJECT-LINEIDS-001').Count -eq 0) (Brief $r)

$r = Cand @{ ObjectKind = 'Method'; ObjectName = 'FB_A.M_New'; Declaration = "METHOD M_New : INT`r`nVAR_INPUT`r`n    n : INT;`r`nEND_VAR`r`n"; Implementation = "M_New := n * 2;"; PlcProjectPath = $Plc }
Check 'O4 new method FB_A.M_New -> added, pass, no GUID-001 / LINEIDS-001 / XML-004 for the in-memory member' ($r.success -and $r.data.candidate.overlay -eq 'added' -and @($r.data.diagnostics | Where-Object { $_.ruleId -match '^PROJECT-(GUID|LINEIDS|XML)' }).Count -eq 0) (Brief $r)

$r = Cand @{ ObjectKind = 'FunctionBlock'; ObjectName = 'FB_New'; Declaration = "FUNCTION_BLOCK FB_New`r`nVAR`r`n    n : INT;`r`nEND_VAR`r`n"; Implementation = "n := n + 1;"; PlcProjectPath = $Plc }
$sk = @($r.data.coverage.rulesSkipped | Where-Object { $_.ruleId -eq 'PROJECT-COMPILE-001' -and $_.reason -eq 'candidate-not-in-project' })
Check 'O5 new FB -> added, pass, COMPILE-001 skipped (candidate-not-in-project), no PROJECT-* finding' ($r.success -and $r.data.candidate.overlay -eq 'added' -and $sk.Count -eq 1 -and @($r.data.diagnostics | Where-Object { $_.ruleId -like 'PROJECT-*' }).Count -eq 0 -and $r.data.candidate.file -eq 'FB_New.TcPOU') (Brief $r)
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_Wait'; Declaration = "FUNCTION F_Wait : BOOL`r`nVAR`r`n    t : TON;`r`nEND_VAR`r`n"; Implementation = "t(IN := TRUE, PT := T#1S);`r`nF_Wait := t.Q;"; PlcProjectPath = $Plc }
Check 'O6 new FUNCTION with TON in VAR -> SCAN-TEMPFB-001 blocking (rules run on a new object)' ((Diags $r 'SCAN-TEMPFB-001').Count -eq 1 -and $r.error.code -eq 'LINT_FAILED') (Brief $r)

$r = Cand @{ ObjectKind = 'Action'; ObjectName = 'FB_A.A_Reset'; Declaration = ''; Implementation = "nState := 0;`r`ntonDelay(IN := FALSE);"; PlcProjectPath = $Plc }
Check 'O7 replaced Action (no declaration) -> pass, replaced' ($r.success -and $r.data.candidate.overlay -eq 'replaced') (Brief $r)
$r = Cand @{ ObjectKind = 'Property'; ObjectName = 'FB_A.P_State.Get'; Declaration = "PUBLIC`r`nVAR`r`nEND_VAR"; Implementation = "P_State := nState + 1;"; PlcProjectPath = $Plc }
Check 'O8 replaced property accessor FB_A.P_State.Get -> pass, replaced' ($r.success -and $r.data.candidate.overlay -eq 'replaced' -and $r.data.candidate.objectPath -eq 'FB_A.P_State.Get') (Brief $r)
$r = Cand @{ ObjectKind = 'GVL'; ObjectName = 'GVL_Main'; Declaration = "{attribute 'qualified_only'}`r`nVAR_GLOBAL`r`n    bRun : BOOL;`r`n    nCount : INT;`r`nEND_VAR"; PlcProjectPath = $Plc }
Check 'O9 replaced GVL -> pass' ($r.success -and $r.data.candidate.overlay -eq 'replaced') (Brief $r)
$r = Cand @{ ObjectKind = 'Program'; ObjectName = 'MAIN'; Declaration = $mainDecl; Implementation = "IF fbA.nState > 0 THEN`r`n    eMode := E_Mode.Auto;`r`n"; PlcProjectPath = $Plc }
Check 'O10 candidate with an unclosed IF -> LINT_PARSE_FAILED' ($r.error.code -eq 'LINT_PARSE_FAILED' -and (Diags $r 'LINT-PARSE-002').Count -eq 1 -and $r.data.passed -eq $false) (Brief $r)

# ================================================================ B  boundaries
$cases = @(
    @{ n = 'B1 keyword differs from ObjectKind'; a = @{ ObjectKind = 'Program'; ObjectName = 'P_X'; Declaration = "FUNCTION_BLOCK P_X`r`nVAR`r`nEND_VAR"; Implementation = '' } },
    @{ n = 'B2 declared name differs from ObjectName'; a = @{ ObjectKind = 'FunctionBlock'; ObjectName = 'FB_A'; Declaration = "FUNCTION_BLOCK FB_B`r`nVAR`r`nEND_VAR"; Implementation = '' } },
    @{ n = 'B3 same name is a PROGRAM on disk'; a = @{ ObjectKind = 'FunctionBlock'; ObjectName = 'MAIN'; Declaration = "FUNCTION_BLOCK MAIN`r`nVAR`r`nEND_VAR"; Implementation = '' } },
    @{ n = 'B4 same name is a DUT on disk'; a = @{ ObjectKind = 'GVL'; ObjectName = 'E_Mode'; Declaration = "VAR_GLOBAL`r`nEND_VAR" } },
    @{ n = 'B5 parent of a method missing'; a = @{ ObjectKind = 'Method'; ObjectName = 'FB_None.M_X'; Declaration = "METHOD M_X : BOOL"; Implementation = '' } },
    @{ n = 'B6 member exists as an Action'; a = @{ ObjectKind = 'Method'; ObjectName = 'FB_A.A_Reset'; Declaration = "METHOD A_Reset : BOOL"; Implementation = '' } },
    @{ n = 'B7 accessor of a missing property'; a = @{ ObjectKind = 'Property'; ObjectName = 'FB_A.P_None.Get'; Declaration = ''; Implementation = 'P_None := 1;' } },
    @{ n = 'B8 Transition'; a = @{ ObjectKind = 'Transition'; ObjectName = 'FB_A.T_1'; Declaration = ''; Implementation = 'T_1 := TRUE;' } },
    @{ n = 'B9 implementation for a DUT'; a = @{ ObjectKind = 'DUT'; ObjectName = 'E_Mode'; Declaration = "TYPE E_Mode : (A, B); END_TYPE"; Implementation = 'x := 1;' } },
    @{ n = 'B10 implementation for an interface method'; a = @{ ObjectKind = 'Method'; ObjectName = 'I_Run.M_Run'; Declaration = "METHOD M_Run : BOOL"; Implementation = 'M_Run := TRUE;' } },
    @{ n = 'B11 declaration for an Action'; a = @{ ObjectKind = 'Action'; ObjectName = 'FB_A.A_Reset'; Declaration = "VAR`r`nEND_VAR"; Implementation = 'nState := 0;' } },
    @{ n = 'B12 implementation is not ST'; a = @{ ObjectKind = 'Program'; ObjectName = 'MAIN'; Declaration = $mainDecl; Implementation = '<CFC><XmlArchive /></CFC>' } },
    @{ n = 'B13 Method name without parent'; a = @{ ObjectKind = 'Method'; ObjectName = 'M_Alone'; Declaration = "METHOD M_Alone : BOOL"; Implementation = '' } },
    @{ n = 'B14 property declaration with an implementation'; a = @{ ObjectKind = 'Property'; ObjectName = 'FB_A.P_State'; Declaration = "PROPERTY PUBLIC P_State : INT"; Implementation = 'P_State := 1;' } },
    @{ n = 'B15 Action of an interface'; a = @{ ObjectKind = 'Action'; ObjectName = 'I_Run.A_X'; Declaration = ''; Implementation = 'x := 1;' } }
)
foreach ($c in $cases) {
    $a = $c.a; $a.PlcProjectPath = $Plc
    $r = Cand $a
    Check "$($c.n) -> LINT_INPUT_INVALID, no data.passed" ($r.success -eq $false -and $r.error.code -eq 'LINT_INPUT_INVALID' -and $null -eq $r.data.passed -and $r.error.hint) (Brief $r)
}
$r = Cand @{ ObjectKind = 'Program'; ObjectName = 'MAIN'; Declaration = $mainDecl; Implementation = $mainImpl; PlcProjectPath = 'PLC1' }
Check 'B16 PLC name instead of a .plcproj path -> LINT_INPUT_INVALID (needs the IDE, not in this version)' ($r.error.code -eq 'LINT_INPUT_INVALID') (Brief $r)
$r = Cand @{ ObjectKind = 'Program'; ObjectName = ''; Declaration = $mainDecl }
Check 'B17 no ObjectName -> LINT_INPUT_INVALID' ($r.error.code -eq 'LINT_INPUT_INVALID') (Brief $r)

# ================================================================ X  text-only
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_Scale'; Declaration = "FUNCTION F_Scale : REAL`r`nVAR_INPUT`r`n    nRaw : INT;`r`n    aGain : ARRAY[1..2] OF REAL;`r`nEND_VAR`r`n"; Implementation = "F_Scale := LIMIT(0.0, INT_TO_REAL(nRaw) * aGain[1], 100.0);" }
Check 'X1 self-contained FUNCTION text-only -> pass, contextLevel text-only, contextRequired empty' ($r.success -and $r.data.contextLevel -eq 'text-only' -and $r.data.candidate.overlay -eq 'text-only' -and @($r.data.candidate.contextRequired).Count -eq 0 -and $r.data.source.kind -eq 'candidate-text-only' -and $r.data.profile.name -eq 'default') (Brief $r)
$r = Cand @{ ObjectKind = 'FunctionBlock'; ObjectName = 'FB_T'; Declaration = "FUNCTION_BLOCK FB_T`r`nVAR`r`n    ton1 : TON;`r`nEND_VAR`r`n"; Implementation = "ton1(IN := TRUE, PT := T#1S);" }
Check 'X2 FB with a catalog type (TON) text-only -> pass' ($r.success) (Brief $r)
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_G'; Declaration = "FUNCTION F_G : BOOL`r`nVAR_INPUT`r`n    st : ST_Data;`r`nEND_VAR`r`n"; Implementation = "F_G := GVL_Main.bRun AND st.bOk;" }
Check 'X3 unknown type and GVL reference text-only -> LINT_CONTEXT_REQUIRED, no pass' ($r.error.code -eq 'LINT_CONTEXT_REQUIRED' -and $r.data.passed -eq $false -and $r.data.verdict -eq 'incomplete' -and (@($r.data.candidate.contextRequired) -contains 'type:ST_Data') -and (@($r.data.candidate.contextRequired) -contains 'identifier:GVL_Main')) (Brief $r)
$r = Cand @{ ObjectKind = 'FunctionBlock'; ObjectName = 'FB_E'; Declaration = "FUNCTION_BLOCK FB_E EXTENDS FB_Base IMPLEMENTS I_Run`r`nVAR`r`nEND_VAR`r`n"; Implementation = '' }
Check 'X4 EXTENDS / IMPLEMENTS text-only -> LINT_CONTEXT_REQUIRED (extends / implements listed)' ($r.error.code -eq 'LINT_CONTEXT_REQUIRED' -and (@($r.data.candidate.contextRequired) -contains 'extends:FB_Base') -and (@($r.data.candidate.contextRequired) -contains 'implements:I_Run')) (Brief $r)
$r = Cand @{ ObjectKind = 'Method'; ObjectName = 'FB_X.M_Wait'; Declaration = "METHOD M_Wait : BOOL`r`nVAR`r`n    t : TON;`r`nEND_VAR`r`n"; Implementation = "t(IN := TRUE, PT := T#1S);`r`nM_Wait := t.Q;" }
Check 'X5 Method text-only -> LINT_CONTEXT_REQUIRED (over LINT_FAILED, D4 order), the context-free finding is still listed' ($r.error.code -eq 'LINT_CONTEXT_REQUIRED' -and (@($r.data.candidate.contextRequired) -contains 'object-kind:Method') -and (Diags $r 'SCAN-TEMPFB-001').Count -eq 1) (Brief $r)
$r = Cand @{ ObjectKind = 'Property'; ObjectName = 'FB_X.P_V'; Declaration = "PROPERTY P_V : INT" }
Check 'X6 Property text-only -> LINT_CONTEXT_REQUIRED, no pass' ($r.error.code -eq 'LINT_CONTEXT_REQUIRED' -and $r.data.passed -eq $false) (Brief $r)
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_P'; Declaration = "FUNCTION F_P : BOOL`r`nVAR_INPUT`r`n    x : BOOL;`r`nEND_VAR`r`n"; Implementation = "IF x THEN`r`n    F_P := TRUE;`r`n" }
Check 'X7 text-only parse error -> LINT_PARSE_FAILED (over CONTEXT_REQUIRED)' ($r.error.code -eq 'LINT_PARSE_FAILED') (Brief $r)
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_C'; Declaration = "FUNCTION F_C : INT`r`nVAR_INPUT`r`n    a : ARRAY[1..cMax] OF INT;`r`nEND_VAR`r`n"; Implementation = "F_C := a[1];" }
Check 'X8 array bound from an undeclared constant text-only -> LINT_CONTEXT_REQUIRED (identifier:cMax)' ($r.error.code -eq 'LINT_CONTEXT_REQUIRED' -and (@($r.data.candidate.contextRequired) -contains 'identifier:cMax')) (Brief $r)
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_K'; Declaration = "FUNCTION F_K : INT`r`nVAR CONSTANT`r`n    cMax : INT := 3;`r`nEND_VAR`r`nVAR`r`n    a : ARRAY[1..cMax] OF INT;`r`nEND_VAR`r`n"; Implementation = "F_K := a[1] + SIZEOF(a);" }
Check 'X9 array bound from a local CONSTANT text-only -> pass' ($r.success) (Brief $r)

# ================================================================ N  newSuppressions vs disk
$mDecl = "METHOD M_Do : BOOL`r`nVAR_INPUT`r`n    nValue : INT;`r`nEND_VAR`r`nVAR`r`n    // tcauto-lint-disable-next-line SCAN-TEMPFB-001: edge memory is not needed across calls here`r`n    rt : R_TRIG;`r`nEND_VAR`r`n"
$r = Cand @{ ObjectKind = 'Method'; ObjectName = 'FB_A.M_Do'; Declaration = $mDecl; Implementation = "rt(CLK := nValue > 0);`r`nM_Do := rt.Q;"; PlcProjectPath = $Plc }
$ns = @($r.data.newSuppressions)
Check 'N1 inline suppression in the candidate, not on disk -> newSuppressions lists it, requiresDisposition (new-suppressions)' ($r.success -and $ns.Count -eq 1 -and $ns[0].objectPath -eq 'FB_A.M_Do' -and $r.data.newSuppressionsBasis -eq 'candidate-vs-disk' -and $r.data.requiresDisposition -and (@($r.data.dispositionReasons) -contains 'new-suppressions') -and (Diags $r 'SCAN-TEMPFB-001')[0].suppressed) (Brief $r)
$fx2 = New-LintFixture (Join-Path $root 'g')
Edit-LintFxFile $fx2.FbA { param($t) $t.Replace("METHOD M_Do : BOOL`r`nVAR_INPUT`r`n    nValue : INT;`r`nEND_VAR`r`n", $mDecl) }
$r = Cand @{ ObjectKind = 'Method'; ObjectName = 'FB_A.M_Do'; Declaration = $mDecl; Implementation = "rt(CLK := nValue > 0);`r`nM_Do := rt.Q;"; PlcProjectPath = $fx2.Plcproj }
Check 'N2 the same suppression already on disk -> newSuppressions empty' ($r.success -and @($r.data.newSuppressions).Count -eq 0 -and @($r.data.suppressions).Count -ge 1) (Brief $r)
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_S'; Declaration = "FUNCTION F_S : BOOL`r`nVAR`r`n    // tcauto-lint-disable-next-line SCAN-TEMPFB-001: edge memory is not needed across calls here`r`n    rt : R_TRIG;`r`nEND_VAR`r`n"; Implementation = "rt(CLK := TRUE);`r`nF_S := rt.Q;" }
Check 'N3 text-only: every inline suppression is new (basis candidate-text-only)' (@($r.data.newSuppressions).Count -eq 1 -and $r.data.newSuppressionsBasis -eq 'candidate-text-only' -and $r.data.requiresDisposition) (Brief $r)
$r = Cand @{ ObjectKind = 'Method'; ObjectName = 'FB_A.M_Do'; Declaration = "METHOD M_Do : BOOL`r`nVAR`r`n    // tcauto-lint-disable-next-line SCAN-TEMPFB-001: timer restarts on every call by design`r`n    t : TON;`r`nEND_VAR`r`n"; Implementation = "t(IN := TRUE, PT := T#1S);`r`nM_Do := t.Q;"; PlcProjectPath = $Plc }
Check 'N4 inline suppression of a blocking finding (TON) is refused (LINT-SUPPRESS-004), still LINT_FAILED' ($r.error.code -eq 'LINT_FAILED' -and (Diags $r 'LINT-SUPPRESS-004').Count -eq 1) (Brief $r)

# ================================================================ C  cross-object (PR #284 review S1)
$fx3 = New-LintFixture (Join-Path $root 'h')
$gvlK = "<?xml version=`"1.0`" encoding=`"utf-8`"?>`n<TcPlcObject Version=`"1.1.0.1`" ProductVersion=`"3.1.4026.18`">`n  <GVL Name=`"GVL_K`" Id=`"{6b0f3f43-2a6e-4d55-9a3e-5f1d2c7b9e01}`">`n    <Declaration><![CDATA[{attribute 'qualified_only'}`nVAR_GLOBAL CONSTANT`n    cDiv : DINT := 5;`nEND_VAR]]></Declaration>`n  </GVL>`n</TcPlcObject>"
Write-LintFxFile (Join-Path $fx3.PlcDir 'GVLs\GVL_K.TcGVL') $gvlK
Write-LintFxFile (Join-Path $fx3.PlcDir 'POUs\FB_U.TcPOU') (Get-LintFxPou -Name 'FB_U' -Id '{8e2c4d10-5b7a-4f3e-9c21-7d4e6a1b3f52}' -Decl "FUNCTION_BLOCK FB_U`nVAR`n    x : DINT;`nEND_VAR`n" -Impl "x := x MOD GVL_K.cDiv;")
Set-LintFxCompile $fx3 (@($script:LintFxCompile) + @('GVLs\GVL_K.TcGVL', 'POUs\FB_U.TcPOU'))
$r = Cand @{ ObjectKind = 'GVL'; ObjectName = 'GVL_K'; Declaration = "{attribute 'qualified_only'}`r`nVAR_GLOBAL CONSTANT`r`n    cDiv : DINT := 5;`r`nEND_VAR"; PlcProjectPath = $fx3.Plcproj }
Check 'C1 unchanged GVL: crossObject checked, no new finding in other objects, pass' ($r.success -and $r.data.crossObject.checked -and @($r.data.crossObject.newFindings).Count -eq 0) (Brief $r)
$r = Cand @{ ObjectKind = 'GVL'; ObjectName = 'GVL_K'; Declaration = "{attribute 'qualified_only'}`r`nVAR_GLOBAL CONSTANT`r`n    cDiv : DINT := 0;`r`nEND_VAR"; PlcProjectPath = $fx3.Plcproj }
$nf = @($r.data.crossObject.newFindings)
Check 'C2 GVL constant set to 0 makes MOD 0 in FB_U: candidate fails (LINT_FAILED), crossObject lists it, requiresDisposition' ($r.error.code -eq 'LINT_FAILED' -and $r.data.passed -eq $false -and $nf.Count -eq 1 -and $nf[0].ruleId -eq 'SAFETY-DIV-001' -and $nf[0].objectPath -eq 'FB_U' -and $r.data.crossObject.blocking -eq 1 -and (@($r.data.dispositionReasons) -contains 'cross-object-findings')) ((Brief $r) + ' cross=' + (Js $r.data.crossObject))
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_X'; Declaration = "FUNCTION F_X : INT`r`nVAR_INPUT`r`n    n : INT;`r`nEND_VAR`r`n"; Implementation = 'F_X := n;' }
Check 'C3 text-only: crossObject not checked (reason text-only)' ($r.data.crossObject.checked -eq $false -and $r.data.crossObject.reason -eq 'text-only') (Js $r.data.crossObject)

# ================================================================ X  text-only legal constructs (review nit 2) / not analysed (nit 4)
$r = Cand @{ ObjectKind = 'Function'; ObjectName = 'F_J'; Declaration = "FUNCTION F_J : INT`r`nVAR`r`n    x : INT;`r`nEND_VAR`r`n"; Implementation = "lbl: x := x + 1;`r`nIF x < 3 THEN`r`n    JMP lbl;`r`nEND_IF`r`nF_J := x;" }
Check 'X10 text-only JMP label is not an identifier needing the project -> pass' ($r.success) (Brief $r)
$r = Cand @{ ObjectKind = 'FunctionBlock'; ObjectName = 'FB_T2'; Declaration = "FUNCTION_BLOCK FB_T2`r`nVAR`r`n    n : INT;`r`nEND_VAR`r`n"; Implementation = 'THIS^.n := 1;' }
Check 'X11 text-only THIS^.member -> pass' ($r.success) (Brief $r)
$r = Cand @{ ObjectKind = 'Program'; ObjectName = 'MAIN'; Declaration = $mainDecl; Implementation = "{IF defined(SIM)}`r`nWHILE TRUE DO`r`nEND_WHILE`r`n{END_IF}`r`n" + $mainImpl; PlcProjectPath = $Plc }
Check 'X12 candidate section with a conditional pragma: pass but requiresDisposition (candidate-not-analyzed)' ($r.success -and $r.data.requiresDisposition -and (@($r.data.dispositionReasons) -contains 'candidate-not-analyzed')) (Brief $r)

# ================================================================ R  read-only
Check 'R1 no file of the project changed (content and write time) after every candidate above' ((Hashes) -ceq $before) ''

# ================================================================ D  deterministic
$a = @{ ObjectKind = 'Method'; ObjectName = 'FB_A.M_Do'; Declaration = $mDecl; Implementation = "rt(CLK := nValue > 0);`r`nM_Do := rt.Q;"; PlcProjectPath = $Plc }
$j1 = Js (Cand $a); $j2 = Js (Cand $a)
Check 'D1 two runs byte-identical' ($j1 -ceq $j2) ''
$helper = Join-Path $root 'cul.ps1'
@'
param([string]$Module, [string]$Plcproj, [string]$Culture, [string]$Out)
[System.Threading.Thread]::CurrentThread.CurrentCulture = $Culture
[System.Threading.Thread]::CurrentThread.CurrentUICulture = $Culture
Import-Module $Module -Force -WarningAction SilentlyContinue
$d = "FUNCTION_BLOCK FB_A`r`nVAR_INPUT`r`n    bStart : BOOL;`r`nEND_VAR`r`nVAR`r`n    tonDelay : TON;`r`n    nState : INT;`r`n    r : REAL;`r`nEND_VAR`r`n"
$r = Invoke-TcLintCandidate -ObjectKind FunctionBlock -ObjectName FB_A -Declaration $d -Implementation "r := 1.5E-3 * 2.0;`r`nIF r > 0.1 THEN`r`n" -PlcProjectPath $Plcproj
$j = $r | ConvertTo-Json -Depth 30 -Compress
[System.IO.File]::WriteAllText($Out, ([System.Threading.Thread]::CurrentThread.CurrentUICulture.Name + "`n" + $j), (New-Object System.Text.UTF8Encoding($false)))
'@ | Set-Content -LiteralPath $helper -Encoding UTF8
$outs = @{}
foreach ($cul in 'en-US', 'zh-TW') {
    $o = Join-Path $root "cul-$cul.json"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $helper -Module (Resolve-Path $modulePath).ProviderPath -Plcproj $Plc -Culture $cul -Out $o | Out-Null
    $outs[$cul] = [System.IO.File]::ReadAllText($o)
}
$en = $outs['en-US'] -split "`n", 2; $zh = $outs['zh-TW'] -split "`n", 2
Check 'D2 culture really differed in the two processes' ($en[0] -eq 'en-US' -and $zh[0] -eq 'zh-TW') "$($en[0]) / $($zh[0])"
Check 'D2 en-US and zh-TW byte-identical (parse failure in the candidate)' ($en[1] -ceq $zh[1] -and $en[1] -match 'LINT_PARSE_FAILED') ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
"lint-candidate: $fail failed"
exit $fail
