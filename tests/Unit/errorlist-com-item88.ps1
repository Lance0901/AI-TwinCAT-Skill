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
#   K  PR #332 real-machine report (head 6f4dfd2 / 456c5e7), the five points:
#        item 8  standalone GetBuildErrors with text in the search box: never success + 0 errors that nothing proves (E16-E23, F19-F22, G8)
#        item 2  rows read before a timeout are kept and marked partial (F23, G9, G10), budget / fetch / level options reach the reader (F25-F27)
#        item 3  build summary regex: English / zh-TW real strings, language independent, last-summary-only (E0b / R*)
#        item 4  the UIA fallback never opens, shows or activates a window (G11, J6)
#        item 5  restore proven by its own readback: errorlist-com-reader-332.ps1 N1 / N3
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
$zhSkipped = -join @([char]0x7565, [char]0x904e)
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
    # PR #332 real-machine report item 3: the REAL strings of the build pane (4026 XAE, VS2022, 4024; 2026-11-23/24)
    $realFail = '========== Build: 0 succeeded or up-to-date, 2 failed, 0 skipped =========='
    $s = & $sm $realFail
    Check 'R1 real English MSBuild line with failures ("0 succeeded or up-to-date, 2 failed, 0 skipped") -> found, failedProjects 2 (the old pattern did not match "or up-to-date")' ($s.found -and $s.failedProjects -eq 2 -and $null -eq $s.errors) (J $s)
    $s = & $sm '========== Build: 2 succeeded or up-to-date, 0 failed, 0 skipped =========='
    Check 'R2 real English MSBuild line, clean -> found, failedProjects 0' ($s.found -and $s.failedProjects -eq 0) (J $s)
    $zhReal = "========= ${zhBuild}: ${zhSucceeded} 2 ${zhUnit}${zhComma}${zhFailed} 0 ${zhUnit}${zhComma}${zhSkipped} 0 ${zhUnit} =========="
    $s = & $sm $zhReal
    Check 'R3 real zh-TW VS2022 line (succeeded-or-updated 2, failed 0, skipped 0) -> found, failedProjects 0' ($s.found -and $s.failedProjects -eq 0) (J $s)
    $s = & $sm "========= ${zhBuild}: ${zhSucceeded} 0 ${zhUnit}${zhComma}${zhFailed} 2 ${zhUnit}${zhComma}${zhSkipped} 0 ${zhUnit} =========="
    Check 'R3 zh-TW line with 2 failed -> failedProjects 2' ($s.found -and $s.failedProjects -eq 2) (J $s)
    $s = & $sm "========= ${zhBuild}$([char]0xff1a) ${zhSucceeded} 0 ${zhUnit}${zhComma}${zhFailed} 3 ${zhUnit} =========="
    Check 'R3 full-width colon after the label is accepted too' ($s.found -and $s.failedProjects -eq 3) (J $s)
    $s = & $sm '========== Erstellen: 0 erfolgreich oder aktuell, 2 fehlgeschlagen, 0 uebersprungen =========='
    Check 'R4 language independent: a German line (no word the module knows) -> failedProjects 2 (the second count is the failed count)' ($s.found -and $s.failedProjects -eq 2) (J $s)
    $s = & $sm '========== Rebuild All: 1 succeeded, 1 failed, 0 skipped =========='
    Check 'R5 Rebuild All label -> failedProjects 1' ($s.found -and $s.failedProjects -eq 1) (J $s)
    $s = & $sm "========== Something without numbers ==========`r`n===== not a summary`r`nBuild: 3 succeeded"
    Check 'R6 lines that are not a comma list of counts are not a summary' (-not $s.found) (J $s)
    $two = "Build complete -- 6 errors, 25 warnings`r`n$realFail`r`nBuild complete -- 0 errors, 11 warnings`r`n========== Build: 2 succeeded or up-to-date, 0 failed, 0 skipped =========="
    $sumAll = & $sm $two
    $sumLast = & $mod { param($t) ConvertFrom-TcBuildPaneSummary -Text $t -LastOnly } $two
    Check 'R7 pane of two builds: the default SUMS them (6 errors / 2 failed), -LastOnly takes the last of each (0 / 0)' ($sumAll.errors -eq 6 -and $sumAll.failedProjects -eq 2 -and $sumLast.errors -eq 0 -and $sumLast.failedProjects -eq 0 -and $sumLast.found) ("all=$(J $sumAll) last=$(J $sumLast)")
    $s = & $sm $realFail
    Check 'R8 PLC online (XAE does not compile): the MSBuild line alone is a summary' ($s.found -and $null -eq $s.errors -and $s.failedProjects -eq 2) (J $s)
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

    # --- E16-E23: standalone verdict (PR #332 real-machine report item 8: search box text -> 0 rows looked like a clean build) ---
    $verdictS = { param($c, $e, $iso, $stale, $zk = $false, $expect = $false, $standalone = $true)
        & $mod { param($c, $e, $iso, $stale, $zk, $expect, $sa) Get-TcErrorListComVerdict -Com $c -ErrorRows $e -IsolatedTotal $iso -Standalone:$sa -StaleSummary $stale -ZeroErrorsKnown:$zk -ExpectErrors:$expect } $c $e $iso $stale $zk $expect $standalone }
    $stSix = [PSCustomObject]@{ found = $true; errors = 6; failedProjects = $null; lines = @('Build complete -- 6 errors') }
    $stFail = [PSCustomObject]@{ found = $true; errors = $null; failedProjects = 2; lines = @('failed 2') }
    $stZero = [PSCustomObject]@{ found = $true; errors = 0; failedProjects = $null; lines = @('Build complete -- 0 errors') }
    $stNone = [PSCustomObject]@{ found = $false; errors = $null; failedProjects = $null; lines = @() }
    $v = & $verdictS (& $com -all 0) 0 0 $stSix
    Check 'E16 standalone, COM 0 rows, the last build summary says 6 errors (search box text hides them) -> fewer-errors-than-last-build-summary' (-not $v.accept -and $v.reason -match '^fewer-errors-than-last-build-summary') (J $v)
    $v = & $verdictS (& $com -all 0) 0 0 $stFail
    Check 'E17 standalone, COM 0 rows, the last MSBuild summary says 2 failed -> fewer-errors-than-last-build-summary' (-not $v.accept -and $v.reason -match '^fewer-errors-than-last-build-summary') (J $v)
    $v = & $verdictS (& $com -all 0) 0 0 $stNone
    Check 'E18 standalone, COM 0 rows, no summary anywhere -> errors-zero-unverified (never an accepted 0)' (-not $v.accept -and $v.reason -match '^errors-zero-unverified') (J $v)
    $v = & $verdictS (& $com -all 0) 0 0 $null
    Check 'E18 standalone, no pane at all ($null summary) -> errors-zero-unverified' (-not $v.accept -and $v.reason -match '^errors-zero-unverified') (J $v)
    $v = & $verdictS (& $com -all 0) 0 0 $stZero
    Check 'E19 standalone, COM 0 rows, the last summary says 0 errors -> accepted, verifiedBy last-build-summary' ($v.accept -and $v.verifiedBy -eq 'last-build-summary') (J $v)
    $v = & $verdictS (& $com -all 0) 0 0 $stNone $true
    Check 'E20 standalone, COM 0 rows, -ZeroErrorsKnown (CheckAllObjects returned True) -> accepted, verifiedBy caller-confirmed-no-errors' ($v.accept -and $v.verifiedBy -eq 'caller-confirmed-no-errors') (J $v)
    $v = & $verdictS (& $com -all 3) 3 3 $stNone
    Check 'E21 standalone, 3 error rows, no summary -> accepted (a filter only hides rows), verifiedBy none, a note says it is a lower bound' ($v.accept -and $v.verifiedBy -eq 'none' -and (@($v.notes) -join ' ') -match 'lower bound') (J $v)
    $v = & $verdictS (& $com -all 6) 6 6 $stSix
    Check 'E22 standalone, 6 rows and the summary says 6 -> accepted' ($v.accept -and $v.verifiedBy -eq 'last-build-summary') (J $v)
    $stEight = [PSCustomObject]@{ found = $true; errors = 8; failedProjects = $null; lines = @('Build complete -- 8 errors') }
    $v = & $verdictS (& $com -all 6) 6 6 $stEight
    Check 'E22 standalone, 6 rows but the summary says 8 -> rejected' (-not $v.accept -and $v.reason -match '^fewer-errors-than-last-build-summary') (J $v)
    $v = & $verdictS (& $com -all 0) 0 0 $stNone $false $false $false
    Check 'E23 NOT standalone (the caller has its own proof): 0 rows with no summary stays accepted as before' ($v.accept) (J $v)
    $v = & $verdictS (& $com -all 0) 0 0 $stNone $false $true
    Check 'E23 -ExpectErrors with 0 rows is still rejected first (expected-errors-none-read)' (-not $v.accept -and $v.reason -match '^expected-errors-none-read') (J $v)
    $comRestore = & $com -restored $false
    $comRestore | Add-Member -NotePropertyName restoreNote -NotePropertyValue 'buttons before the read = True/False/True, after the restore = True/True/True'
    $v = & $verdict $comRestore
    Check 'E24 buttons not restored: the verdict note carries the before / after text of the readback (PR #332 item 5)' ($v.accept -and -not $v.flagsRestored -and (@($v.notes) -join ' ') -match 'after the restore = True/True/True') (J $v)

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
            if ($OperationName -eq 'View.ErrorList') { $global:ViewErrorListCalls++ }
            & $ScriptBlock
        }
        function script:Read-TcErrorListCom { [CmdletBinding()] param([int]$MaxMs, [int]$CapMs, [bool]$FetchWarnings = $true, [bool]$FetchMessages = $true, [bool]$ReadLevel = $true) $global:ReadCalls.Add($MaxMs) | Out-Null; $global:ReadArgs = @{ MaxMs = $MaxMs; CapMs = $CapMs; W = $FetchWarnings; M = $FetchMessages; L = $ReadLevel }; $global:ComRead }
        function script:Get-TcBuildOutputPane { [CmdletBinding()] param($Dte) $global:PaneRead }
    }
    $global:ReadCalls = [System.Collections.ArrayList]::new()

    $global:ReadArgs = $null
    $global:ViewErrorListCalls = 0
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
    # the counts of the isolated reads (the C# reader reports them; the rows alone were enough before it fetched only what is asked for)
    if (-not $d.ContainsKey('errorCount')) { $d['errorCount'] = @($d.errors).Count }
    if (-not $d.ContainsKey('warningCount')) { $d['warningCount'] = @($d.warnings).Count }
    if (-not $d.ContainsKey('messageCount')) { $d['messageCount'] = @($d.messages).Count }
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
    Check 'F1 scope carried like the UIA result (entire $true), messages present, errorsWithoutCode 0, levels not read on a host without a level table (item 2: one COM call less per row)' ($r.data.scope.entire -eq $true -and @($r.data.messages).Count -eq 1 -and $r.data.comRead.errorsWithoutCode -eq 0 -and $r.data.truncated -eq $false -and $r.data.comRead.levelCounts -eq 'not-read') (J $r.data.comRead)
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
    $r = ViaCom @{ ZeroErrorsKnown = $true }
    Check 'F9 empty list, Entire Solution scope, the caller knows there is no error (-ZeroErrorsKnown) -> accepted with 0 / 0 / 0' ($r.accepted -and $r.data.counts.errors -eq 0 -and @($r.data.errors).Count -eq 0) (J $r)
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
    Set-Com @{ created = $true; hiddenRestored = $true; errors = @((Row 2 'e')); allCount = 1 }
    $r = ViaCom @{}
    Check 'F16 Error List tab created by this read and hidden again: accepted, comRead.errorListCreated = true, errorListHidden = true' ($r.accepted -and $r.errorListCreated -and $r.errorListHidden -and $r.data.comRead.errorListCreated -and $r.data.comRead.errorListHidden) (J $r.data.comRead)
    Check 'F16 the result says the IDE window list was changed (layoutChanged = true) and that the tab is hidden again, so the visible layout is as before' ($r.data.comRead.layoutChanged -eq $true -and (@($r.data.comRead.notes) -join ' ') -match 'put it back to hidden') (J $r.data.comRead)
    Set-Com @{ created = $true; hiddenRestored = $false; errors = @((Row 2 'e')); allCount = 1 }
    $r = ViaCom @{}
    Check 'F17 created but could not be hidden again: accepted, errorListHidden = false reported (not faked)' ($r.accepted -and $r.errorListCreated -and -not $r.errorListHidden -and -not $r.data.comRead.errorListHidden) (J $r.data.comRead)
    Check 'F17 layoutChanged = true and a note says the window may be visible' ($r.data.comRead.layoutChanged -eq $true -and (@($r.data.comRead.notes) -join ' ') -match 'may be visible') (J $r.data.comRead)
    Set-Com @{ allCount = 1; errors = @((Row 2 'e')) }
    $r = ViaCom @{}
    Check 'F17b window already there (c2 path): layoutChanged = false, no layout note, errorListCreated false' ($r.accepted -and $r.data.comRead.layoutChanged -eq $false -and -not $r.errorListCreated -and (@($r.data.comRead.notes) -join ' ') -notmatch 'hidden') (J $r.data.comRead)

    # --- F18-F27: PR #332 real-machine report ---
    $msbuildOnly = '========== Build: 0 succeeded or up-to-date, 2 failed, 0 skipped =========='
    Set-Com @{ allCount = 2; errors = @((Row 2 "Identifier 'a' not defined"), (Row 2 "Identifier 'b' not defined" 'C:\p\Main.TcPOU (Impl)' 46)) }
    $r = ViaCom @{ RequireBuildSummary = $true; BuildPaneText = $msbuildOnly }
    Check 'F18 item 3 / 7: PLC online (XAE does not compile), only the real MSBuild line in the pane: accepted by -RequireBuildSummary (before: build-summary-missing)' ($r.accepted -and $r.data.comRead.buildSummary -match 'Build: 0 succeeded or up-to-date, 2 failed') (J $r)
    $paneSix = "Build complete -- 6 errors, 25 warnings : No download possible`n$msbuildOnly"
    $global:PaneRead = [PSCustomObject]@{ status = 'read'; text = $paneSix }
    Set-Com @{ allCount = 0 }
    $r = ViaCom @{}
    Check 'F19 item 8: search box text, COM 0 rows, the pane of the last build says 6 errors -> NOT accepted, fewer-errors-than-last-build-summary (the report: success, 0 errors)' (-not $r.accepted -and $r.reason -match '^fewer-errors-than-last-build-summary') (J $r)
    $global:PaneRead = [PSCustomObject]@{ status = 'unreadable'; text = '' }
    $r = ViaCom @{}
    Check 'F20 COM 0 rows, no readable pane -> errors-zero-unverified, no partial' (-not $r.accepted -and $r.reason -match '^errors-zero-unverified' -and $null -eq $r.partial) (J $r)
    $global:PaneRead = [PSCustomObject]@{ status = 'read'; text = "Build complete -- 0 errors, 12 warnings : Ready for download" }
    $r = ViaCom @{}
    Check 'F21 COM 0 rows and the last build summary says 0 errors -> accepted, verifiedBy last-build-summary, the summary line is in comRead.buildSummary' ($r.accepted -and $r.data.comRead.verifiedBy -eq 'last-build-summary' -and $r.data.comRead.buildSummary -match '0 errors') (J $r.data.comRead)
    $global:PaneRead = [PSCustomObject]@{ status = 'unreadable'; text = '' }
    $r = ViaCom @{ ZeroErrorsKnown = $true }
    Check 'F22 -ZeroErrorsKnown: accepted without a pane' ($r.accepted -and $r.data.comRead.verifiedBy -eq 'caller-confirmed-no-errors') (J $r.data.comRead)
    $r = ViaCom @{ ExpectErrors = $true }
    Check 'F22b -ExpectErrors with 0 rows: still expected-errors-none-read' (-not $r.accepted -and $r.reason -match '^expected-errors-none-read') (J $r)

    # partial: the read stopped (timeout) after some rows
    Set-Com @{ ok = $false; reason = 'timeout'; errorsComplete = $false; warningsComplete = $false; messagesComplete = $false; errorCount = -1; warningCount = -1; messageCount = -1
        errors = @((Row 2 'e1'), (Row 2 'e2'), (Row 2 'e3')); warnings = @() }
    $r = ViaCom @{}
    Check 'F23 item 2: a COM read that ran out of time is rejected, but the 3 error rows it read are in partial (not an empty list), errorsComplete = false, no expected count' (-not $r.accepted -and $r.reason -eq 'com-read-failed:timeout' -and $null -ne $r.partial -and @($r.partial.errors).Count -eq 3 -and -not $r.partial.errorsComplete -and $null -eq $r.partial.expected.errors -and $r.partial.reason -eq 'timeout') (J $r.partial)
    Set-Com @{ ok = $false; reason = 'timeout' }
    $r = ViaCom @{}
    Check 'F23 nothing read -> no partial object' (-not $r.accepted -and $null -eq $r.partial) (J $r)

    # options reach the reader
    Set-Com @{ allCount = 1; errors = @((Row 2 'e')); timing = 'flagSets=10 flagSetMs=1'; budgetMs = 9100 }
    $r = ViaCom @{ MaxMs = 2000; CapMs = 9000 }
    Check 'F25 timing text and the budget are in comRead; the reader got MaxMs <= 2000 and a CapMs above it (the budget grows with the rows)' ($r.accepted -and $r.data.comRead.timing -eq 'flagSets=10 flagSetMs=1' -and $r.data.comRead.budgetMs -eq 9100 -and $global:ReadArgs.MaxMs -le 2000 -and $global:ReadArgs.CapMs -gt 2000 -and $global:ReadArgs.CapMs -le 9000) (J @{ args = $global:ReadArgs })
    $r = ViaCom @{}
    Check 'F26 4026 (DTE 17), warnings on, messages off: the reader fetches warnings, only counts messages, does not read ErrorLevel' ($global:ReadArgs.W -eq $true -and $global:ReadArgs.M -eq $false -and $global:ReadArgs.L -eq $false) (J $global:ReadArgs)
    $r = ViaCom @{ IncludeWarnings = $false; IncludeMessages = $true }
    Check 'F26 -IncludeWarnings:$false -IncludeMessages: the flags follow' ($global:ReadArgs.W -eq $false -and $global:ReadArgs.M -eq $true) (J $global:ReadArgs)
    $global:DteVersion = '15.0'
    Set-Com @{ allCount = 2; errors = @((Row 4 'e')); warnings = @((Row 2 'w')) }
    $r = ViaCom @{}
    Check 'F27 4024 (DTE 15) has a level table: ErrorLevel is read (it is the cross-check), levelCheck agreed' ($global:ReadArgs.L -eq $true -and $r.accepted -and $r.data.comRead.levelCheck -eq 'agreed' -and $r.data.comRead.levelCounts -match 'Error\[level 4\]=1') (J $r.data.comRead)
    $global:DteVersion = '17.0'
    Set-Com @{ allCount = 6; errors = @((Row 2 'e')); warningCount = 5; warnings = @() }
    $r = ViaCom @{ IncludeWarnings = $false }
    Check 'F28 warnings counted but not fetched: counts.warnings = 5 (the sum check uses the count), no warnings array' ($r.accepted -and $r.data.counts.warnings -eq 5 -and $null -eq $r.data.PSObject.Properties['warnings']) (J $r.data.counts)

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

    # G8 item 8 end to end: search box text -> COM 0 rows, pane of the last build says 6 errors; the UIA scan compares with the button total (6)
    $global:PaneRead = [PSCustomObject]@{ status = 'read'; text = "Build complete -- 6 errors, 25 warnings`n$msbuildOnly" }
    Set-Com @{ allCount = 0 }
    $global:UiaResult = [PSCustomObject]@{
        Found = $true; Rows = @(); Truncated = $false; ToggleUsed = $true; Notes = @('mock'); Headers = @()
        Counts = [PSCustomObject]@{ errors = 6; warnings = 0; messages = 0 }
        Scope = [PSCustomObject]@{ before = 'Entire Solution'; after = 'Entire Solution'; entire = $true; switched = $false }; CountsTotalForm = $true }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G8 item 8: standalone GetBuildErrors with a search text: NOT success with 0 errors; the UIA scan decides (0 of 6 -> ERRORLIST_INCOMPLETE), fallbackReason names the summary' (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE' -and $r.data.fallbackReason -match '^fewer-errors-than-last-build-summary' -and $r.data.source -eq 'ErrorList(UIA)') (J $r.error)
    $global:PaneRead = [PSCustomObject]@{ status = 'unreadable'; text = '' }
    $global:UiaResult = [PSCustomObject]@{ Found = $false; Rows = @(); Truncated = $false; ToggleUsed = $false; Notes = @(); Headers = @(); Counts = $null }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G8 COM 0 rows, no pane, UIA cannot read: ERRORLIST_UNAVAILABLE with fallbackReason errors-zero-unverified (the answer is "not known", not "0 errors")' (-not $r.success -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE' -and $r.data.fallbackReason -match '^errors-zero-unverified') (J $r.error)

    # G9 / G10 item 2: partial rows are kept when the COM read stopped and UIA cannot do better

    Set-Com @{ ok = $false; reason = 'timeout'; errorsComplete = $false; warningsComplete = $false; messagesComplete = $false; errorCount = -1; warningCount = -1; messageCount = -1
        errors = @((Row 2 'e1'), (Row 2 'e2'), (Row 2 'e3')); warnings = @((Row 2 'w1'), (Row 2 'w2')) }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G9 COM stopped after 3 error / 2 warning rows, UIA cannot find the window: success = $false, ERRORLIST_UNAVAILABLE, but data.errors holds the 3 rows with partial = true / truncated = true' (-not $r.success -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE' -and $r.data.partial -eq $true -and $r.data.truncated -eq $true -and @($r.data.errors).Count -eq 3 -and @($r.data.warnings).Count -eq 2 -and $r.data.source -eq 'ErrorList(COM)') (J $r.data)
    Check 'G9 partialRead says why and which severity is complete; the message says the rows are not the whole list' ($r.data.partialRead.reason -eq 'timeout' -and $r.data.partialRead.errorsComplete -eq $false -and $r.error.message -match 'partial = true' -and $r.error.message -match 'NOT the whole list') (J $r.data.partialRead)
    Check 'G9 the callers (Get-TcErrorListReadState) do not take rows of an UNAVAILABLE result' (-not ((& $mod { param($x) Get-TcErrorListReadState -Result $x } $r).usable)) ''
    $global:UiaResult = [PSCustomObject]@{
        Found = $true; Rows = @(); Truncated = $false; ToggleUsed = $true; Notes = @('mock'); Headers = @()
        Counts = [PSCustomObject]@{ errors = 529; warnings = 0; messages = 0 }
        Scope = [PSCustomObject]@{ before = 'Entire Solution'; after = 'Entire Solution'; entire = $true; switched = $false }; CountsTotalForm = $true }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G10 COM partial and UIA reads 0 of 529: ERRORLIST_INCOMPLETE keeps its own data; the COM rows are next to it in data.comPartial (3 error rows)' (-not $r.success -and $r.error.code -eq 'ERRORLIST_INCOMPLETE' -and @($r.data.comPartial.errors).Count -eq 3 -and $r.data.comPartial.reason -eq 'timeout') (J $r.data)

    # G11 item 4: the UIA fallback never runs View.ErrorList (it restored a minimized VS2022 and took the foreground)
    $global:UiaResult = [PSCustomObject]@{ Found = $false; Rows = @(); Truncated = $false; ToggleUsed = $false; Notes = @(); Headers = @(); Counts = $null }
    Set-Com @{ caption = 'Error List - Open Documents'; allCount = 1; errors = @((Row 2 'e')) }
    $r = Get-TcBuildErrors -TimeoutSec 30
    Check 'G11 item 4: Error List not on screen, UIA cannot find it: ERRORLIST_UNAVAILABLE that says TcAuto does not open it (View > Error List once); View.ErrorList was never executed in any Get-TcBuildErrors run of section G' (-not $r.success -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE' -and $r.error.message -match 'does not open it' -and $r.error.message -match 'View > Error List' -and $global:ViewErrorListCalls -eq 0) (J $r.error)

    # --- H: summary pass-through ---
    & $mod {
        function script:Get-TcBuildErrors { [CmdletBinding()] param([switch]$IncludeWarnings, [int]$TimeoutSec, [switch]$ExpectErrors, [switch]$ZeroErrorsKnown, [string]$BuildPaneText, [switch]$RequireBuildSummary, [string]$Source)
            $global:SeenArgs = @{ ExpectErrors = [bool]$ExpectErrors; Zero = [bool]$ZeroErrorsKnown; Pane = $BuildPaneText; Timeout = $TimeoutSec; Require = [bool]$RequireBuildSummary; Source = $Source }
            [PSCustomObject]@{ success = $true; error = $null; data = [PSCustomObject]@{
                    counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }; errors = @(); warnings = @(); truncated = $false
                    source = 'ErrorList(UIA)'; fallbackReason = 'scope-not-entire: x' } }
        }
    }
    $s = & $mod { Get-TcErrorListSummary -TimeoutSec 30 -ExpectErrors -BuildPaneText 'PANE' -RequireBuildSummary }
    Check 'H1 summary hands ExpectErrors / BuildPaneText / TimeoutSec / RequireBuildSummary to Get-TcBuildErrors' ($global:SeenArgs.ExpectErrors -and $global:SeenArgs.Pane -eq 'PANE' -and $global:SeenArgs.Timeout -eq 30 -and $global:SeenArgs.Require) (J $global:SeenArgs)
    Check 'H1 summary exposes errorListSource / errorListFallbackReason' ($s.errorListSource -eq 'ErrorList(UIA)' -and $s.errorListFallbackReason -eq 'scope-not-entire: x') (J ($s | Select-Object errorListSource, errorListFallbackReason))
    $null = & $mod { Get-TcErrorListSummary -ZeroErrorsKnown }
    Check 'H1b -ZeroErrorsKnown is handed on' ($global:SeenArgs.Zero -eq $true) (J $global:SeenArgs)
    $null = & $mod { Get-TcErrorListSummary }
    Check 'H2 without the new switches nothing extra is passed (old mocks / callers unchanged)' (-not $global:SeenArgs.Zero -and -not $global:SeenArgs.ExpectErrors -and [string]::IsNullOrEmpty($global:SeenArgs.Pane) -and -not $global:SeenArgs.Require -and [string]::IsNullOrEmpty($global:SeenArgs.Source)) (J $global:SeenArgs)
    $null = & $mod { Get-TcErrorListSummary -Source UIA }
    Check 'H3 -Source UIA is handed on' ($global:SeenArgs.Source -eq 'UIA') (J $global:SeenArgs)

    # --- I: callers (static) ---
    $pub = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public'
    $build = [IO.File]::ReadAllText((Join-Path $pub 'Build-TcProject.ps1'))
    Check 'I1 Build-TcProject: ExpectErrors from LastBuildInfo > 0, the pane text of this build and -RequireBuildSummary go to the summary' ($build -match '-ExpectErrors:\$elExpectErrors -BuildPaneText\s+\$elPaneText -RequireBuildSummary' -and $build -match '\$elExpectErrors\s*=\s*\(\$null -ne \$failedProjects -and \[int\]\$failedProjects -gt 0\)') ''
    $test = [IO.File]::ReadAllText((Join-Path $pub 'Test-TcPlcProject.ps1'))
    Check 'I2 Test-TcPlcProject (CheckAllObjects): ExpectErrors when the check returned False, ZeroErrorsKnown when it returned True' ($test -match 'Get-TcErrorListSummary\s+-TimeoutSec\s+\$script:TcBuildErrorListTimeoutSec\s+-SplitRuntimeLog\s+-ExpectErrors:\(\$passed -eq \$false\)\s+-ZeroErrorsKnown:\(\$passed -eq \$true\)') ''

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
    # J6 item 4: no code path of the COM / UIA read shows, restores or activates a window
    $codeLines = { param($t) $t = [regex]::Replace($t, '(?s)<#.*?#>', ''); ($t -split "`n" | Where-Object { $_ -notmatch '^\s*(#|//)' }) -join "`n" }
    $gbe = & $codeLines ([IO.File]::ReadAllText((Join-Path $pub 'Get-TcBuildErrors.ps1')))
    $uiaSrc = & $codeLines ([IO.File]::ReadAllText((Join-Path $priv 'Get-TcIdeErrorList.ps1')))
    $windowCalls = 'ExecuteCommand|View\.ErrorList|SetForegroundWindow|ShowWindow|SwitchToThisWindow|SetFocus|\.Activate\(|AppActivate|BringWindowToTop|WindowPattern|SetWindowVisualState|\.Restore\('
    Check 'J6 item 4: Get-TcBuildErrors.ps1 has no ExecuteCommand / View.ErrorList / activate call in code (comments excluded)' ($gbe -notmatch $windowCalls) ([regex]::Match($gbe, $windowCalls).Value)
    Check 'J6 item 4: the UIA scan (Get-TcIdeErrorList.ps1) never shows, focuses, restores or activates a window' ($uiaSrc -notmatch $windowCalls) ([regex]::Match($uiaSrc, $windowCalls).Value)
    Check 'J7 item 2: the DTE adapter reads no Column (constant 1, unused) and ErrorLevel only under withLevel' ((& $strip $csRead) -notmatch '\.Column\b' -and (& $strip $csRead) -match 'if \(withLevel\) r\.Level = \(int\)it\.ErrorLevel') ''
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
