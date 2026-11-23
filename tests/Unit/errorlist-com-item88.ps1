# Unit: Error List read through COM (DTE2 ErrorList.ErrorItems), item 88, re #320 / #329 / #300; review fixes of PR #332.
# No IDE / runtime: the C# reader's result and the UIA scan are MOCKED; the parsing, mapping and fallback decisions
# are the real code. The C# algorithm itself (flags, retry, lag) is driven with a fake source in errorlist-com-reader-332.ps1,
# Build-TcProject end to end in build-errorlist-com-m1-332.ps1.
#   A  caption -> scope kind (entire / partial / unknown), English and zh-TW
#   B  ErrorLevel table per IDE host (DTE 15: High 4 / Medium 2 / Low 1) and the level-vs-flag cross-check
#   C  file / project / item conversion to the UIA form ((Impl) / (Decl) suffix, base name, project name, column $null)
#   D  build pane lines -> code (file + text, line only to choose between equals; no match -> $null), one index for all rows
#   E  Get-TcErrorListComVerdict: every fallback reason, and the accepted cases; pane end summary (ConvertFrom-TcBuildPaneSummary)
#   F  Get-TcErrorListViaCom end to end with a mocked reader (4026 and 4024: isolation, level cross-check, rejects, summary)
#   G  Get-TcBuildErrors: COM accepted (UIA not started) / COM rejected -> UIA with data.fallbackReason / -Source UIA / busy guard first
#   H  Get-TcErrorListSummary hands -ExpectErrors / -BuildPaneText / -RequireBuildSummary / -Source on and exposes the source
#   I  callers: Build / CheckAllObjects pass what the COM cross-check needs
#   J  the C# files only read (no ExecuteCommand, no window state), the window is never created, and they compile when the EnvDTE assemblies exist
#   powershell.exe -NoProfile -File tests/Unit/errorlist-com-item88.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$tcUnit88OwnDir = $false
if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) {
    $env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-88-{0}" -f [guid]::NewGuid().ToString('N'))
    $tcUnit88OwnDir = $true
}
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }
# zh-TW strings (built from code points: this file stays ASCII)
$zhTitle = -join @([char]0x932f, [char]0x8aa4, [char]0x6e05, [char]0x55ae)
$zhProject = -join @([char]0x76ee, [char]0x524d, [char]0x7684, [char]0x5c08, [char]0x6848)
$zhBuild = -join @([char]0x7d44, [char]0x5efa)
$zhSucceeded = -join @([char]0x6210, [char]0x529f, [char]0x6216, [char]0x5df2, [char]0x66f4, [char]0x65b0)
$zhFailed = -join @([char]0x5931, [char]0x6557)
$zhUnit = [string][char]0x500b
$zhComma = [string][char]0xff0c

try {
    # --- A: caption -> scope ---
    $cap = { param($c) & $mod { param($x) ConvertFrom-TcErrorListScopeCaption -Caption $x } $c }
    Check "A1 'Error List' -> entire" ((& $cap 'Error List').kind -eq 'entire') ''
    Check 'A1 zh-TW title -> entire' ((& $cap $zhTitle).kind -eq 'entire') ''
    $p = & $cap "$zhTitle - $zhProject (AxisInterface_Type01_Library)"
    Check 'A2 zh-TW title - current project (X) -> partial, scope text kept' ($p.kind -eq 'partial' -and $p.scope -match 'AxisInterface_Type01_Library') (J $p)
    Check 'A2 Error List - Current Project (BFH_1650) -> partial' ((& $cap 'Error List - Current Project (BFH_1650)').kind -eq 'partial') ''
    Check 'A2 Error List - Open Documents -> partial' ((& $cap 'Error List - Open Documents').kind -eq 'partial') ''
    Check 'A2 Error List - Current Document -> partial' ((& $cap 'Error List - Current Document').kind -eq 'partial') ''
    Check "A3 unknown title (other UI language) -> unknown, never entire" ((& $cap 'Fehlerliste').kind -eq 'unknown') ''
    Check 'A3 empty / null caption -> unknown' ((& $cap '').kind -eq 'unknown' -and (& $cap $null).kind -eq 'unknown') ''

    # --- B: ErrorLevel table (vsBuildErrorLevel Low 1 / Medium 2 / High 4, S8) and the level-vs-flag cross-check (S4) ---
    $lvl = { param($l, $h) & $mod { param($a, $b) ConvertFrom-TcErrorLevel -Level $a -DteMajor $b } $l $h }
    Check 'B1 DTE 15 (4024): 4 (High) -> Error, 2 (Medium) -> Warning, 1 (Low) -> Message' ((& $lvl 4 15) -eq 'Error' -and (& $lvl 2 15) -eq 'Warning' -and (& $lvl 1 15) -eq 'Message') ''
    Check 'B2 DTE 15: a level outside 4 / 2 / 1 -> $null' ($null -eq (& $lvl 3 15) -and $null -eq (& $lvl 0 15)) ''
    Check 'B3 DTE 17 (4026): ErrorLevel 2 is every severity -> $null for every level' ($null -eq (& $lvl 2 17) -and $null -eq (& $lvl 1 17) -and $null -eq (& $lvl 4 17)) ''
    Check 'B3 unknown host -> $null' ($null -eq (& $lvl 4 $null)) ''
    $lr = { param($l) [PSCustomObject]@{ Level = $l } }
    $mm = { param($major, $e, $w, $m) & $mod { param($a, $b, $c, $d) Get-TcErrorLevelMismatchCount -DteMajor $a -ErrorRows $b -WarningRows $c -MessageRows $d } $major $e $w $m }
    Check 'B4 DTE 15: error rows level 4, warning 2, message 1 -> 0 mismatches' ((& $mm 15 @((& $lr 4)) @((& $lr 2), (& $lr 2)) @((& $lr 1))) -eq 0) ''
    Check 'B4 DTE 15: a row read under ShowErrors with level 2 -> 1 mismatch' ((& $mm 15 @((& $lr 4), (& $lr 2)) @() @()) -eq 1) ''
    Check 'B4 DTE 17 (no table): never a mismatch' ((& $mm 17 @((& $lr 2)) @((& $lr 2)) @((& $lr 1))) -eq 0) ''
    Check 'B4 unknown host: never a mismatch' ((& $mm $null @((& $lr 9)) @() @()) -eq 0) ''

    # --- C: conversion ---
    $f = & $mod { ConvertTo-TcErrorListComFile -FileName 'C:\temp\Verify\Main.TcPOU (Impl)' }
    Check 'C1 4026 FileName: base name + (Impl) kept, full path without the suffix' ($f.file -eq 'Main.TcPOU (Impl)' -and $f.filePath -eq 'C:\temp\Verify\Main.TcPOU' -and $f.part -eq 'Impl') (J $f)
    $f = & $mod { ConvertTo-TcErrorListComFile -FileName 'C:\temp\Verify\FB_X.TcPOU@M_Two (Decl)' }
    Check 'C1 method object: FB_X.TcPOU@M_Two (Decl)' ($f.file -eq 'FB_X.TcPOU@M_Two (Decl)') (J $f)
    $f = & $mod { ConvertTo-TcErrorListComFile -FileName 'C:\temp\BFH\MAIN.TcPOU' }
    Check 'C2 4024 FileName has no suffix: base name only' ($f.file -eq 'MAIN.TcPOU' -and $null -eq $f.part) (J $f)
    $f = & $mod { ConvertTo-TcErrorListComFile -FileName '' }
    Check 'C2 empty FileName -> file $null' ($null -eq $f.file -and $null -eq $f.filePath) (J $f)
    Check 'C3 project: plcproj path -> project name' ((& $mod { ConvertTo-TcErrorListComProject -Project 'AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj' }) -eq 'AxisInterface') ''
    Check 'C3 empty project -> $null' ($null -eq (& $mod { ConvertTo-TcErrorListComProject -Project '' })) ''
    $row = [PSCustomObject]@{ Level = 2; Description = "Identifier 'x' not defined"; FileName = 'C:\a\Main.TcPOU (Impl)'; Line = 45; Column = 1; Project = 'P\P\P.plcproj' }
    $it = & $mod { param($r) ConvertTo-TcErrorListComItem -Row $r -Severity 'Error' } $row
    Check 'C4 item: UIA shape, line kept, column $null, code $null' ($it.severity -eq 'Error' -and $it.file -eq 'Main.TcPOU (Impl)' -and $it.line -eq 45 -and $null -eq $it.column -and $null -eq $it.code -and $it.project -eq 'P' -and $it.description -eq "Identifier 'x' not defined") (J $it)

    # --- D: build pane lines -> code ---
    $pane = "Build started`r`nMain.TcPOU(209) : error: C0046: Identifier 'nItem88A' not defined`r`nMain.TcPOU(210) : error: C0018: 'rVelocityCmd' is no valid assignment target`r`nFB_X.TcPOU(12,3): warning C0195: Unused thing`r`nMain.TcPOU(211) : warning: The code 'LT_Read;`r`n========== done"
    $pl = & $mod { param($t) ConvertFrom-TcBuildPaneDiagnostics -Text $t } $pane
    Check 'D1 pane parse: 2 errors + 2 warnings, codes, MSBuild form (line,col) too' (@($pl).Count -eq 4 -and $pl[0].code -eq 'C0046' -and $pl[2].code -eq 'C0195' -and $pl[2].line -eq 12 -and $null -eq $pl[3].code -and $pl[3].severity -eq 'Warning') (J $pl)
    $mk = { param($sev, $file, $line, $desc) [PSCustomObject]@{ severity = $sev; code = $null; description = $desc; project = 'P'; file = $file; line = $line; column = $null } }
    $c = & $mod { param($i, $l) Resolve-TcErrorItemCode -Item $i -PaneLines $l } (& $mk 'Error' 'Main.TcPOU (Impl)' 45 "Identifier 'nItem88A' not defined") $pl
    Check 'D2 code from file + text although the line differs (45 vs 209: Impl-relative vs whole file)' ($c -eq 'C0046') "$c"
    $c = & $mod { param($i, $l) Resolve-TcErrorItemCode -Item $i -PaneLines $l } (& $mk 'Error' 'Main.TcPOU (Impl)' 46 "Some other text") $pl
    Check 'D3 no pane line with that text -> $null (never inferred from the text)' ($null -eq $c) "$c"
    $c = & $mod { param($i, $l) Resolve-TcErrorItemCode -Item $i -PaneLines $l } (& $mk 'Warning' 'Main.TcPOU (Impl)' 211 "The code 'LT_Read;") $pl
    Check 'D4 pane line without a code -> $null' ($null -eq $c) "$c"
    $c = & $mod { param($i, $l) Resolve-TcErrorItemCode -Item $i -PaneLines $l } (& $mk 'Error' 'Other.TcPOU (Impl)' 45 "Identifier 'nItem88A' not defined") $pl
    Check 'D5 same text in another file -> $null' ($null -eq $c) "$c"
    $two = & $mod { ConvertFrom-TcBuildPaneDiagnostics -Text "Main.TcPOU(10) : error: C0046: dup`nMain.TcPOU(20) : error: C0018: dup" }
    $c1 = & $mod { param($i, $l) Resolve-TcErrorItemCode -Item $i -PaneLines $l } (& $mk 'Error' 'Main.TcPOU (Impl)' 10 'dup') $two
    $c2 = & $mod { param($i, $l) Resolve-TcErrorItemCode -Item $i -PaneLines $l } (& $mk 'Error' 'Main.TcPOU (Impl)' 5 'dup') $two
    Check 'D6 two lines with the same text and different codes: the same line number decides, otherwise $null' ($c1 -eq 'C0046' -and $null -eq $c2) "$c1 / $c2"
    $c = & $mod { param($i, $l) Resolve-TcErrorItemCode -Item $i -PaneLines $l } (& $mk 'Error' 'FB_X.TcPOU@M (Impl)' 1 "Identifier 'q' not defined") (& $mod { ConvertFrom-TcBuildPaneDiagnostics -Text "C:\p\FB_X.TcPOU@M(1) : error: C0046: Identifier 'q' not defined" })
    Check 'D7 pane file with full path and @member compares by base name' ($c -eq 'C0046') "$c"
    # S6: with a prebuilt index the answer is the same, and the index is a dictionary keyed once per (severity, file, text)
    $idx = & $mod { param($l) New-TcPaneLineIndex -PaneLines $l } $pl
    $c = & $mod { param($i, $l, $x) Resolve-TcErrorItemCode -Item $i -PaneLines $l -Index $x } (& $mk 'Error' 'Main.TcPOU (Impl)' 45 "Identifier 'nItem88A' not defined") $pl $idx
    Check 'D8 -Index: same code, the index has one key per distinct (severity, file, text)' ($c -eq 'C0046' -and $idx.Count -eq 4 -and $idx -is [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]) "n=$($idx.Count)"
    $big = (1..600 | ForEach-Object { "F$($_ % 40).TcPOU($_) : error: C0046: msg $_" }) -join "`n"
    $bigLines = & $mod { param($t) ConvertFrom-TcBuildPaneDiagnostics -Text $t } $big
    $bigIdx = & $mod { param($l) New-TcPaneLineIndex -PaneLines $l } $bigLines
    $okAll = $true
    foreach ($n in 1..600) {
        $got = & $mod { param($i, $l, $x) Resolve-TcErrorItemCode -Item $i -PaneLines $l -Index $x } (& $mk 'Error' "F$($n % 40).TcPOU (Impl)" $n "msg $n") $null $bigIdx
        if ($got -ne 'C0046') { $okAll = $false; break }
    }
    Check 'D9 600 items resolve through one index (no per-item scan of the pane lines)' ($okAll -and $bigIdx.Count -eq 600) "idx=$($bigIdx.Count)"

    # --- E: pane summary + verdict ---
    $sm = { param($t) & $mod { param($x) ConvertFrom-TcBuildPaneSummary -Text $x } $t }
    $s = & $sm "Generate code...`r`nBuild complete -- 0 errors, 0 warnings : ready for download"
    Check 'E0 PLC summary "Build complete -- 0 errors" -> found, errors 0' ($s.found -and $s.errors -eq 0 -and $null -eq $s.failedProjects) (J $s)
    $s = & $sm "Build complete -- 3 errors, 1 warnings`r`nBuild complete -- 2 errors, 0 warnings"
    Check 'E0 two PLC projects: errors are summed' ($s.found -and $s.errors -eq 5) (J $s)
    $s = & $sm '========== Build: 1 succeeded, 0 failed, 0 up-to-date, 0 skipped =========='
    Check 'E0 MSBuild English summary -> failedProjects 0' ($s.found -and $s.failedProjects -eq 0 -and $null -eq $s.errors) (J $s)
    $zhLine = "========= ${zhBuild}: ${zhSucceeded} 2 ${zhUnit}${zhComma}${zhFailed} 1 ${zhUnit}${zhComma}x 0 ${zhUnit}=========="
    $s = & $sm $zhLine
    Check 'E0 zh-TW MSBuild summary (measured 2026-11-09 form) -> failedProjects 1' ($s.found -and $s.failedProjects -eq 1) (J $s)
    $s = & $sm "Main.TcPOU(1) : error: C0046: x`r`nGenerate code..."
    Check 'E0 compiler lines without an end summary -> not found (a filtered list cannot be ruled out)' (-not $s.found) (J $s)
    Check 'E0 empty / $null text -> not found' (-not (& $sm '').found -and -not (& $sm $null).found) ''

    $com = { param($ok = $true, $caption = 'Error List', $all = 3, $restored = $true, $reason = '', $err = '')
        [PSCustomObject]@{ ok = $ok; reason = $reason; error = $err; caption = $caption; allCount = $all; flagsRestored = $restored } }
    $verdict = { param($c, $e = 1, $lm = 0, $iso = 3, $expect = $false, $paneLines = $null, $items = $null, $req = $false, $summary = $null)
        & $mod { param($c, $e, $lm, $iso, $expect, $pl, $it, $req, $sum) Get-TcErrorListComVerdict -Com $c -ErrorRows $e -LevelMismatchRows $lm -IsolatedTotal $iso -ExpectErrors:$expect -PaneLines $pl -ErrorItems $it -RequireBuildSummary:$req -PaneSummary $sum } $c $e $lm $iso $expect $paneLines $items $req $summary }
    $v = & $verdict (& $com)
    Check 'E1 whole list (Entire Solution, isolation adds up) -> accepted' ($v.accept -and [string]::IsNullOrEmpty($v.reason)) (J $v)
    $v = & $verdict (& $com -ok $false -reason 'timeout')
    Check 'E2 reader failed -> com-read-failed:timeout' (-not $v.accept -and $v.reason -eq 'com-read-failed:timeout') (J $v)
    $v = & $verdict (& $com -ok $false -reason 'com-error' -err 'boom')
    Check 'E2 reader exception text kept' (-not $v.accept -and $v.reason -eq 'com-read-failed:com-error: boom') (J $v)
    $v = & $verdict (& $com -ok $false -reason 'errorlist-create-failed')
    Check 'E2 Error List window did not exist and could not be created (S7) -> reason is exactly errorlist-create-failed' (-not $v.accept -and $v.reason -eq 'errorlist-create-failed') (J $v)
    $v = & $verdict (& $com -ok $false -reason 'com-error' -err 'busy' -restored $false)
    Check 'E2 failed read that could not restore the buttons: carried in the reason and flagsRestored $false (S1)' (-not $v.accept -and $v.reason -match 'could not be set back' -and $v.flagsRestored -eq $false) (J $v)
    $v = & $verdict (& $com -caption "$zhTitle - $zhProject (X)") 0 0 3
    Check 'E3 scope Current Project: 0 error rows is NOT "no errors" -> scope-not-entire' (-not $v.accept -and $v.reason -match '^scope-not-entire') (J $v)
    $v = & $verdict (& $com -caption 'Fehlerliste')
    Check 'E4 caption of an unknown language -> scope-unknown' (-not $v.accept -and $v.reason -match '^scope-unknown') (J $v)
    $v = & $verdict (& $com -all 4) 1 0 3
    Check 'E5 isolated reads (3) do not add up to the all-flags count (4) -> severity-isolation-mismatch' (-not $v.accept -and $v.reason -match '^severity-isolation-mismatch') (J $v)
    $v = & $verdict (& $com -all 3) 1 1 3
    Check 'E6 a row whose ErrorLevel disagrees with its flag (S4) -> error-level-mismatch' (-not $v.accept -and $v.reason -match '^error-level-mismatch') (J $v)
    $v = & $verdict (& $com -all 1) 0 0 1 $true
    Check 'E7 the build failed (ExpectErrors) and the COM list has no error row -> expected-errors-none-read' (-not $v.accept -and $v.reason -match '^expected-errors-none-read') (J $v)
    $v = & $verdict (& $com -all 1) 0 0 1 $false
    Check 'E7 same list without ExpectErrors (clean build) -> accepted: 0 errors is a result' ($v.accept) (J $v)
    $v = & $verdict (& $com -all 0) 0 0 0 $false
    Check 'E8 completely empty list in the Entire Solution scope -> accepted (the caption proves the scope)' ($v.accept) (J $v)
    $paneErr = & $mod { ConvertFrom-TcBuildPaneDiagnostics -Text "A.TcPOU(1) : error: C0046: a`nA.TcPOU(2) : error: C0046: b`nA.TcPOU(3) : error: C0046: c" }
    $v = & $verdict (& $com -all 2) 2 0 2 $true $paneErr
    Check 'E9 fresh build pane lists 3 error lines, COM has 2 error rows -> fewer-errors-than-build-pane' (-not $v.accept -and $v.reason -match '^fewer-errors-than-build-pane') (J $v)
    $itemsAbc = @('a', 'b', 'c' | ForEach-Object { [PSCustomObject]@{ severity = 'Error'; file = 'A.TcPOU (Impl)'; description = $_ } })
    $v = & $verdict (& $com -all 3) 3 0 3 $true $paneErr $itemsAbc
    Check 'E9 3 error lines, 3 error rows with the same file + text -> accepted' ($v.accept) (J $v)
    $itemsAbx = @('a', 'b', 'x' | ForEach-Object { [PSCustomObject]@{ severity = 'Error'; file = 'A.TcPOU (Impl)'; description = $_ } })
    $v = & $verdict (& $com -all 3) 3 0 3 $true $paneErr $itemsAbx
    Check 'E9b 3 rows but one pane error line has no row of that file + text (a Library Manager row in its place) -> build-pane-error-not-in-list' (-not $v.accept -and $v.reason -match '^build-pane-error-not-in-list') (J $v)
    $v = & $verdict (& $com -restored $false)
    Check 'E10 flags could not be put back: accepted, with a note' ($v.accept -and @($v.notes).Count -eq 1) (J $v)
    # M1: callers that decide success
    $sum0 = [PSCustomObject]@{ found = $true; errors = 0; failedProjects = $null; lines = @('Build complete -- 0 errors') }
    $sumNone = [PSCustomObject]@{ found = $false; errors = $null; failedProjects = $null; lines = @() }
    $v = & $verdict (& $com -all 0) 0 0 0 $false $null $null $true $sumNone
    Check 'E11 -RequireBuildSummary, no summary in the pane, COM 0 rows -> build-summary-missing (the review scenario)' (-not $v.accept -and $v.reason -match '^build-summary-missing') (J $v)
    $v = & $verdict (& $com -all 0) 0 0 0 $false $null $null $true $null
    Check 'E11 -RequireBuildSummary without any pane -> build-summary-missing' (-not $v.accept -and $v.reason -match '^build-summary-missing') (J $v)
    $v = & $verdict (& $com -all 0) 0 0 0 $false $null $null $true $sum0
    Check 'E12 summary "0 errors" + COM 0 rows -> accepted' ($v.accept) (J $v)
    $sum2 = [PSCustomObject]@{ found = $true; errors = 2; failedProjects = $null; lines = @('Build complete -- 2 errors') }
    $v = & $verdict (& $com -all 1) 1 0 1 $false $null $null $true $sum2
    Check 'E13 summary says 2 errors, COM list (filtered) shows 1 -> fewer-errors-than-build-summary' (-not $v.accept -and $v.reason -match '^fewer-errors-than-build-summary') (J $v)
    $sumF = [PSCustomObject]@{ found = $true; errors = $null; failedProjects = 1; lines = @('failed 1') }
    $v = & $verdict (& $com -all 0) 0 0 0 $false $null $null $true $sumF
    Check 'E14 MSBuild summary says 1 project failed, COM has no error row -> fewer-errors-than-build-summary' (-not $v.accept -and $v.reason -match '^fewer-errors-than-build-summary') (J $v)
    $v = & $verdict (& $com -all 0) 0 0 0 $false $null $null $false $sumNone
    Check 'E15 without -RequireBuildSummary a missing summary is no reason (diagnostic callers)' ($v.accept) (J $v)

    # --- F: Get-TcErrorListViaCom with a mocked reader ---
    & $mod {
        $script:TcDte = [PSCustomObject]@{ Version = '17.0' }
        $script:TcIdeConnected = $true
        $script:TcIdeProcessId = $PID
        function script:Initialize-TcErrorListComTypes { [CmdletBinding()] param([int]$IdeProcessId) if ($null -ne $global:ComTypes) { $global:ComTypes } else { [PSCustomObject]@{ ok = $true; reason = $null } } }
        function script:Invoke-TcComRetry {
            [CmdletBinding()] param([scriptblock]$ScriptBlock, [int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec)
            if ($OperationName -eq 'DTE.Version') { return $global:DteVersion }
            if ($OperationName -eq 'Read build output') { return $global:PaneRead }
            & $ScriptBlock
        }
        function script:Read-TcErrorListCom { [CmdletBinding()] param([int]$MaxMs) $global:ReadCalls.Add($MaxMs) | Out-Null; $global:ComRead }
        function script:Get-TcBuildOutputPane { [CmdletBinding()] param($Dte) $global:PaneRead }
    }
    $global:ReadCalls = [System.Collections.ArrayList]::new()
    $global:ComTypes = $null
    $global:DteVersion = '17.0'
    $global:PaneRead = [PSCustomObject]@{ status = 'unreadable'; text = '' }
    function Row([int]$Level, [string]$Desc, [string]$File = 'C:\p\Main.TcPOU (Impl)', [int]$Line = 45) {
        [PSCustomObject]@{ Level = $Level; Description = $Desc; FileName = $File; Line = $Line; Column = 1; Project = 'A\B\Plc.plcproj' }
    }
    function Set-Com([hashtable]$o) {
        $d = @{ ok = $true; reason = ''; error = ''; caption = 'Error List'; allCount = 0; flagsRestored = $true; flagsChanged = $true; flagsBefore = @($true, $false, $false); ms = 12.5
            errors = @(); warnings = @(); messages = @() }
        foreach ($k in $o.Keys) { $d[$k] = $o[$k] }
        $global:ComRead = [PSCustomObject]$d
    }
    function ViaCom([hashtable]$p = @{}) { & $mod { param($h) Get-TcErrorListViaCom @h } $p }

    # F1 4026: ErrorLevel is 2 everywhere -> flags decide, no level table
    Set-Com @{ allCount = 4
        errors = @((Row 2 "Identifier 'a' not defined"), (Row 2 "Identifier 'b' not defined" 'C:\p\FB.TcPOU@M (Impl)' 46))
        warnings = @((Row 2 'unused w')); messages = @((Row 2 'msg' '' 0)) }
    $r = ViaCom @{ IncludeMessages = $true; BuildPaneText = "Main.TcPOU(209) : error: C0046: Identifier 'a' not defined`nFB.TcPOU@M(210) : error: C0046: Identifier 'b' not defined" }
    Check 'F1 4026: accepted, source COM, severities from the flags, no level table' ($r.accepted -and $r.data.source -eq 'ErrorList(COM)' -and $r.data.counts.errors -eq 2 -and $r.data.counts.warnings -eq 1 -and $r.data.counts.messages -eq 1 -and $r.data.comRead.severityBy -eq 'ShowFlags' -and $r.data.comRead.levelCheck -eq 'no-table') (J $r)
    Check 'F1 UIA-compatible items: file (Impl), project name, line, column null; codes from the fresh pane' ($r.data.errors[0].file -eq 'Main.TcPOU (Impl)' -and $r.data.errors[0].project -eq 'Plc' -and $r.data.errors[0].line -eq 45 -and $null -eq $r.data.errors[0].column -and $r.data.errors[0].code -eq 'C0046' -and $r.data.errors[1].code -eq 'C0046' -and $r.data.comRead.paneCrossCheck) (J $r.data.errors)
    Check 'F1 scope carried like the UIA result (entire $true), messages present, errorsWithoutCode 0, levels recorded (N6)' ($r.data.scope.entire -eq $true -and @($r.data.messages).Count -eq 1 -and $r.data.comRead.errorsWithoutCode -eq 0 -and $r.data.truncated -eq $false -and $r.data.comRead.levelCounts -match 'Error\[level 2\]=2') (J $r.data.comRead)
    $r2 = ViaCom @{ IncludeWarnings = $false }
    Check 'F1 -IncludeWarnings:$false: no warnings array, no messages array' ($null -eq $r2.data.PSObject.Properties['warnings'] -and $null -eq $r2.data.PSObject.Properties['messages']) ''
    $r3 = ViaCom @{}
    Check 'F1 without a pane the codes stay $null (supplied by nobody), errorsWithoutCode counts them' ($r3.accepted -and $null -eq $r3.data.errors[0].code -and $r3.data.comRead.errorsWithoutCode -eq 2 -and -not $r3.data.comRead.paneCrossCheck) (J $r3.data.comRead)
    $r = ViaCom @{ BuildPaneText = "Main.TcPOU(209) : error: C0046: Identifier 'a' not defined`nFB.TcPOU@M(210) : error: C0046: Identifier 'b' not defined" }
    Check 'F1 the pane is parsed once for the codes (one index, S6): both rows have their code' ($r.accepted -and $r.data.errors[0].code -eq 'C0046' -and $r.data.errors[1].code -eq 'C0046') ''

    # F2 4024 (DTE 15): flags decide, the ErrorLevel table cross-checks (S4)
    $global:DteVersion = '15.0'
    Set-Com @{ allCount = 3; errors = @((Row 4 "Unknown type: 'X'" 'C:\p\MAIN.TcPOU' 42)); warnings = @((Row 2 'warn' 'C:\p\MAIN.TcPOU' 43)); messages = @((Row 1 'info' '' 0)) }
    $r = ViaCom @{ IncludeMessages = $true }
    Check 'F2 4024: isolation read, severity from the flags, level table agrees -> accepted' ($r.accepted -and $r.data.counts.errors -eq 1 -and $r.data.counts.warnings -eq 1 -and $r.data.counts.messages -eq 1 -and $r.data.comRead.severityBy -eq 'ShowFlags' -and $r.data.comRead.levelCheck -eq 'agreed' -and $r.data.errors[0].file -eq 'MAIN.TcPOU') (J $r)
    Set-Com @{ allCount = 2; errors = @((Row 4 'e'), (Row 2 'w read under ShowErrors')); warnings = @() }
    $r = ViaCom @{}
    Check 'F3 4024: a row read under ShowErrors with ErrorLevel 2 -> rejected error-level-mismatch, nothing returned' (-not $r.accepted -and $r.reason -match '^error-level-mismatch' -and $null -eq $r.data) (J $r)
    $global:DteVersion = '17.0'

    # F4..F9 rejects
    Set-Com @{ caption = "Error List - Current Project (BFH_1650)"; allCount = 0 }
    $r = ViaCom @{}
    Check 'F4 Error List scope Current Project (0 rows) -> rejected scope-not-entire, NOT 0 errors' (-not $r.accepted -and $r.reason -match '^scope-not-entire') (J $r)
    Set-Com @{ allCount = 1; warnings = @((Row 2 'w')) }
    $r = ViaCom @{ ExpectErrors = $true }
    Check 'F5 build failed (ExpectErrors), only a warning read -> rejected expected-errors-none-read' (-not $r.accepted -and $r.reason -match '^expected-errors-none-read') (J $r)
    Set-Com @{ allCount = 1; errors = @((Row 2 'e1')) }
    $r = ViaCom @{ BuildPaneText = "A.TcPOU(1) : error: C0046: e1`nA.TcPOU(2) : error: C0046: e2" }
    Check 'F6 the pane of this build has 2 error lines, COM 1 -> rejected fewer-errors-than-build-pane' (-not $r.accepted -and $r.reason -match '^fewer-errors-than-build-pane') (J $r)
    Set-Com @{ ok = $false; reason = 'timeout' }
    $r = ViaCom @{}
    Check 'F7 reader timeout -> rejected com-read-failed:timeout' (-not $r.accepted -and $r.reason -eq 'com-read-failed:timeout') (J $r)
    $global:ComTypes = [PSCustomObject]@{ ok = $false; reason = 'com-helper-unavailable: csc blocked' }
    $before = $global:ReadCalls.Count
    $r = ViaCom @{}
    Check 'F8 helper not compilable -> rejected with its reason, reader not called' (-not $r.accepted -and $r.reason -eq 'com-helper-unavailable: csc blocked' -and $global:ReadCalls.Count -eq $before) (J $r)
    $global:ComTypes = $null
    Set-Com @{ allCount = 0 }
    $r = ViaCom @{}
    Check 'F9 empty list, Entire Solution scope, no failure expected, no summary required -> accepted with 0 / 0 / 0' ($r.accepted -and $r.data.counts.errors -eq 0 -and @($r.data.errors).Count -eq 0) (J $r)
    Set-Com @{ allCount = 3; errors = @((Row 2 'e')); warnings = @((Row 2 'w')) }
    $r = ViaCom @{}
    Check 'F10 isolated reads add up to 2 but all-flags count is 3 -> rejected severity-isolation-mismatch' (-not $r.accepted -and $r.reason -match '^severity-isolation-mismatch') (J $r)
    $saveTde = & $mod { $script:TcDte }
    & $mod { $script:TcDte = $null }
    $r = ViaCom @{}
    Check 'F11 no DTE -> rejected com-unavailable' (-not $r.accepted -and $r.reason -match '^com-unavailable') (J $r)
    & $mod { param($d) $script:TcDte = $d } $saveTde
    # M1 end to end through ViaCom
    Set-Com @{ allCount = 0 }
    $before = $global:ReadCalls.Count
    $r = ViaCom @{ RequireBuildSummary = $true }
    Check 'F12 -RequireBuildSummary without a build pane: rejected build-summary-missing BEFORE the reader runs (no Show* flag touched)' (-not $r.accepted -and $r.reason -match '^build-summary-missing' -and $global:ReadCalls.Count -eq $before) (J $r)
    $r = ViaCom @{ RequireBuildSummary = $true; BuildPaneText = "Generate code...`nBuild complete -- 0 errors, 0 warnings" }
    Check 'F13 -RequireBuildSummary with "Build complete -- 0 errors": accepted, summary recorded in comRead' ($r.accepted -and $r.data.comRead.buildSummary -match '0 errors') (J $r.data.comRead)
    Set-Com @{ ok = $false; reason = 'com-error'; error = 'x'; flagsRestored = $false }
    $r = ViaCom @{}
    Check 'F14 failed read with unrestorable buttons: rejection carries flagsRestored $false' (-not $r.accepted -and $r.flagsRestored -eq $false) (J $r)
    Set-Com @{ ok = $false; reason = 'errorlist-create-failed' }
    $r = ViaCom @{}
    Check 'F15 Error List window could not be created (S7): rejected errorlist-create-failed, nothing created' (-not $r.accepted -and $r.reason -eq 'errorlist-create-failed' -and -not $r.errorListCreated) (J $r)
    Set-Com @{ created = $true; hiddenRestored = $true }
    $r = ViaCom @{}
    Check 'F16 Error List tab created by this read and hidden again: accepted, comRead.errorListCreated = true, errorListHidden = true' ($r.accepted -and $r.errorListCreated -and $r.errorListHidden -and $r.data.comRead.errorListCreated -and $r.data.comRead.errorListHidden) (J $r.data.comRead)
    Set-Com @{ created = $true; hiddenRestored = $false }
    $r = ViaCom @{}
    Check 'F17 created but could not be hidden again: accepted, errorListHidden = false reported (not faked)' ($r.accepted -and $r.errorListCreated -and -not $r.errorListHidden -and -not $r.data.comRead.errorListHidden) (J $r.data.comRead)

    # --- G: Get-TcBuildErrors ---
    & $mod {
        function script:Initialize-TcUiaScanTypes { [CmdletBinding()] param([int]$TimeoutSec) $true }
        function script:Invoke-TcUiaScan {
            [CmdletBinding()] param([scriptblock]$Script, [object[]]$Arguments, [int]$TimeoutSec, [ref]$TimedOut, [ref]$ErrorOut)
            $global:UiaCalls++
            $global:UiaBudgets.Add($TimeoutSec) | Out-Null
            $global:UiaResult
        }
        function script:Clear-TcUiaAbandonedScans { $global:ClearCalls++; $global:StillRunning }
    }
    $global:UiaCalls = 0
    $global:ClearCalls = 0
    $global:StillRunning = 0
    $global:UiaBudgets = [System.Collections.ArrayList]::new()
    $global:UiaResult = [PSCustomObject]@{
        Found = $true; Rows = @(); Truncated = $false; ToggleUsed = $true; Notes = @('mock'); Headers = @()
        Counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }
        Scope = [PSCustomObject]@{ before = 'Entire Solution'; after = 'Entire Solution'; entire = $true; switched = $false }
        CountsTotalForm = $true }
    Set-Com @{ allCount = 2; errors = @((Row 2 'e')); warnings = @((Row 2 'w')) }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G1 COM accepted: success, source COM, the UIA scan was not started' ($r.success -and $r.data.source -eq 'ErrorList(COM)' -and $global:UiaCalls -eq 0 -and $r.data.counts.errors -eq 1 -and @($r.data.warnings).Count -eq 1) (J $r)
    Set-Com @{ caption = 'Error List - Open Documents'; allCount = 1; errors = @((Row 2 'e')) }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G2 COM rejected (scope): the UIA scan reads, source UIA, data.fallbackReason says why' ($r.success -and $r.data.source -eq 'ErrorList(UIA)' -and $global:UiaCalls -eq 1 -and $r.data.fallbackReason -match '^scope-not-entire') (J $r.data)
    Check 'G2 the UIA budget is the caller budget minus what COM used (<= 30)' ($global:UiaBudgets[0] -le 30 -and $global:UiaBudgets[0] -ge 1) "$($global:UiaBudgets -join ',')"
    $before = $global:ReadCalls.Count
    $r = Get-TcBuildErrors -TimeoutSec 30 -Source UIA
    Check '-Source UIA: COM reader not called, no fallbackReason' ($global:ReadCalls.Count -eq $before -and $r.success -and $null -eq $r.data.PSObject.Properties['fallbackReason'] -and $r.data.source -eq 'ErrorList(UIA)') (J $r.data)
    $global:UiaResult = [PSCustomObject]@{ Found = $false; Rows = @(); Truncated = $false; ToggleUsed = $false; Notes = @('no pane'); Headers = @(); Counts = $null }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G3 COM rejected and UIA cannot find the window: ERRORLIST_UNAVAILABLE keeps data.fallbackReason (nothing reads as 0 errors)' (-not $r.success -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE' -and $r.data.fallbackReason -match '^scope-not-entire') (J $r)
    Set-Com @{ ok = $false; reason = 'com-error'; error = 'x' }
    $global:UiaResult = [PSCustomObject]@{
        Found = $true; Rows = @(); Truncated = $false; ToggleUsed = $true; Notes = @('mock'); Headers = @()
        Counts = [PSCustomObject]@{ errors = 2; warnings = 0; messages = 0 }
        Scope = [PSCustomObject]@{ before = 'Entire Solution'; after = 'Entire Solution'; entire = $true; switched = $false }; CountsTotalForm = $true }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G4 COM failed, UIA reads 0 of 2 error rows -> ERRORLIST_INCOMPLETE (the old fail-closed path), fallbackReason on it' (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE' -and $r.data.fallbackReason -match '^com-read-failed') (J $r.error)
    # S1: the buttons could not be restored -> the UIA data says so
    Set-Com @{ ok = $false; reason = 'com-error'; error = 'busy'; flagsRestored = $false }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G5 COM could not put the buttons back: data.comFlagsRestored = $false on the UIA result' ($r.data.comFlagsRestored -eq $false) (J $r.data)
    # S2: a leftover UIA scan is checked BEFORE COM (both toggle the same buttons)
    & $mod { $script:TcErrorListScanBusy = $true; $script:TcUiaCleanupMayBeRunning = $true }
    $global:StillRunning = 1
    $before = $global:ReadCalls.Count
    Set-Com @{ allCount = 0 }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G6 a UIA scan may still be running: ERRORLIST_UNAVAILABLE, the COM reader was NOT called (S2)' (-not $r.success -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE' -and $global:ReadCalls.Count -eq $before -and $global:ClearCalls -ge 1) (J $r.error)
    $global:StillRunning = 0
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G7 dropped leftover scan (mayBeRunning): refused too, COM not called (S2)' (-not $r.success -and $r.data.scanMayBeRunning -eq $true -and $global:ReadCalls.Count -eq $before) (J $r.data)
    & $mod { $script:TcErrorListScanBusy = $false; $script:TcUiaCleanupMayBeRunning = $false }

    # --- H: summary pass-through ---
    & $mod {
        function script:Get-TcBuildErrors { [CmdletBinding()] param([switch]$IncludeWarnings, [int]$TimeoutSec, [switch]$ExpectErrors, [string]$BuildPaneText, [switch]$RequireBuildSummary, [string]$Source)
            $global:SeenArgs = @{ ExpectErrors = [bool]$ExpectErrors; Pane = $BuildPaneText; Timeout = $TimeoutSec; Require = [bool]$RequireBuildSummary; Source = $Source }
            [PSCustomObject]@{ success = $true; error = $null; data = [PSCustomObject]@{
                    counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }; errors = @(); warnings = @(); truncated = $false
                    source = 'ErrorList(UIA)'; fallbackReason = 'scope-not-entire: x' } }
        }
    }
    $s = & $mod { Get-TcErrorListSummary -TimeoutSec 30 -ExpectErrors -BuildPaneText 'PANE' -RequireBuildSummary }
    Check 'H1 summary hands ExpectErrors / BuildPaneText / TimeoutSec / RequireBuildSummary to Get-TcBuildErrors' ($global:SeenArgs.ExpectErrors -and $global:SeenArgs.Pane -eq 'PANE' -and $global:SeenArgs.Timeout -eq 30 -and $global:SeenArgs.Require) (J $global:SeenArgs)
    Check 'H1 summary exposes errorListSource / errorListFallbackReason' ($s.errorListSource -eq 'ErrorList(UIA)' -and $s.errorListFallbackReason -eq 'scope-not-entire: x') (J ($s | Select-Object errorListSource, errorListFallbackReason))
    $null = & $mod { Get-TcErrorListSummary }
    Check 'H2 without the new switches nothing extra is passed (old mocks / callers unchanged)' (-not $global:SeenArgs.ExpectErrors -and [string]::IsNullOrEmpty($global:SeenArgs.Pane) -and -not $global:SeenArgs.Require -and [string]::IsNullOrEmpty($global:SeenArgs.Source)) (J $global:SeenArgs)
    $null = & $mod { Get-TcErrorListSummary -Source UIA }
    Check 'H3 -Source UIA is handed on' ($global:SeenArgs.Source -eq 'UIA') (J $global:SeenArgs)

    # --- I: callers (static) ---
    $pub = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public'
    $build = [IO.File]::ReadAllText((Join-Path $pub 'Build-TcProject.ps1'))
    Check 'I1 Build-TcProject: ExpectErrors from LastBuildInfo > 0, the pane text of this build and -RequireBuildSummary go to the summary' ($build -match '-ExpectErrors:\$elExpectErrors -BuildPaneText\s+\$elPaneText -RequireBuildSummary' -and $build -match '\$elExpectErrors\s*=\s*\(\$null -ne \$failedProjects -and \[int\]\$failedProjects -gt 0\)') ''
    $test = [IO.File]::ReadAllText((Join-Path $pub 'Test-TcPlcProject.ps1'))
    Check 'I2 Test-TcPlcProject (CheckAllObjects): ExpectErrors when the check returned False' ($test -match 'Get-TcErrorListSummary\s+-TimeoutSec\s+\$script:TcBuildErrorListTimeoutSec\s+-SplitRuntimeLog\s+-ExpectErrors:\(\$passed -eq \$false\)') ''

    # --- J: the C# files ---
    $priv = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Private'
    $csCore = [IO.File]::ReadAllText((Join-Path $priv 'ErrorListComCore.cs'))
    $csRead = [IO.File]::ReadAllText((Join-Path $priv 'ErrorListComReader.cs'))
    $strip = { param($t) ($t -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n" }
    $codeAll = (& $strip $csCore) + "`n" + (& $strip $csRead)
    Check 'J1 helper never shows / focuses the window (S7): no ExecuteCommand / Activate / SetFocus / Visible = true / AutoHides = false / Close / WindowState; the only window writes are Visible = false and AutoHides = true (hide again)' ($codeAll -notmatch 'ExecuteCommand|\.Activate\(|\.Visible\s*=\s*true|AutoHides\s*=\s*false|\.Close\(|WindowState|SetFocus|SendKeys' -and ([regex]::Matches($codeAll, '\.Visible\s*=')).Count -eq 1 -and ([regex]::Matches($codeAll, '\.AutoHides\s*=')).Count -eq 1) ''
    Check 'J2 restore in finally, rows 1..Count inclusive' ((& $strip $csCore) -match 'finally' -and (& $strip $csCore) -match 'for \(int i = 1; i <= count; i\+\+\)') ''
    $rd = & $strip $csRead
    $openAt = $rd.IndexOf('public bool Open('); $createAt = $rd.IndexOf('public bool Create(')
    $openBody = $rd.Substring($openAt, $createAt - $openAt)
    Check 'J3 Open() looks the window up in DTE.Windows (FindWindow, ws.Item(i)) before it reads ToolWindows.ErrorList; only Create() reads ToolWindows.ErrorList without a window (S7)' ($rd.IndexOf('ws.Item(i)') -ge 0 -and $openBody.IndexOf('FindWindow') -ge 0 -and $openBody.IndexOf('FindWindow') -lt $openBody.IndexOf('ToolWindows.ErrorList') -and ([regex]::Matches($rd, 'ToolWindows\.ErrorList')).Count -eq 2) ''
    Check 'J4 every RCW the adapter obtains is released (N2): ErrorItem, ErrorItems, ErrorList, Window, Windows' (([regex]::Matches((& $strip $csRead), 'Release\(')).Count -ge 7 -and (& $strip $csRead) -match 'Release\(it\)' -and (& $strip $csRead) -match 'Release\(ws\)') ''
    $paths = & $mod { Get-TcErrorListComAssemblyPaths -IdeProcessId 0 }
    if ($null -eq $paths) {
        Check 'J5 EnvDTE assemblies not installed on this machine: compile check skipped' $true 'no TcXaeShell / Visual Studio PublicAssemblies found'
    }
    else {
        # the real Initialize-TcErrorListComTypes in a child process: compile (references incl. Microsoft.VisualStudio.Interop of
        # VS2022) AND runtime binding (the assemblies are not in the GAC: without the LoadFrom the first Read throws FileNotFoundException)
        $child = Join-Path $env:TCAUTO_STATE_DIR 'j5-child.ps1'
        $modPath = (Resolve-Path (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1')).ProviderPath
        $lines = @(
            '$ErrorActionPreference = ''Stop''',
            "Import-Module '$($modPath.Replace("'", "''"))' -Force -WarningAction SilentlyContinue",
            '$st = & (Get-Module TwinCATAutomation) { Initialize-TcErrorListComTypes }',
            'if (-not $st.ok) { "INIT FAIL: " + $st.reason; return }',
            'try { $r = [TcAutomation.ErrorListComReader]::Read($null, 1, 1, $null); "READ ok=" + $r.Ok + " reason=" + $r.Reason } catch { "RUNTIME FAIL: " + $_.Exception.Message }')
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $child) -Force
        Set-Content -LiteralPath $child -Value $lines -Encoding UTF8
        $out = & powershell.exe -NoProfile -NonInteractive -File $child 2>&1 | Out-String
        Check 'J5 Initialize-TcErrorListComTypes compiles both .cs files against the IDE EnvDTE assemblies and the first Read call binds them (null DTE -> com-error, not FileNotFoundException)' ($out.Trim() -eq 'READ ok=False reason=com-error') $out.Trim()
    }
}
finally {
    if ($tcUnit88OwnDir -and (Test-Path -LiteralPath $env:TCAUTO_STATE_DIR) -and ((Split-Path -Leaf $env:TCAUTO_STATE_DIR) -like 'tcauto-unit-88-*')) {
        Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}
"failed: $fail"
exit $fail
