# Unit: Error List read through COM (DTE2 ErrorList.ErrorItems), item 88, re #320 / #329 / #300.
# No IDE / runtime: the C# reader's result and the UIA scan are MOCKED; the parsing, mapping and fallback decisions
# are the real code.
#   A  caption -> scope kind (entire / partial / unknown), English and zh-TW
#   B  ErrorLevel -> severity per IDE host (4024 = DTE 15: 4 / 2 / 1; 4026 = DTE 17: no mapping)
#   C  file / project / item conversion to the UIA form ((Impl) / (Decl) suffix, base name, project name, column $null)
#   D  build pane lines -> code (file + text, line only to choose between equals; no match -> $null)
#   E  Get-TcErrorListComVerdict: every fallback reason, and the accepted cases
#   F  Get-TcErrorListViaCom end to end with a mocked reader (4026 isolation, 4024 level mode, rejects)
#   G  Get-TcBuildErrors: COM accepted (UIA not started) / COM rejected -> UIA with data.fallbackReason / -Source UIA
#   H  Get-TcErrorListSummary hands -ExpectErrors / -BuildPaneText on and exposes the source
#   I  callers: Build / CheckAllObjects / Clean pass what the COM cross-check needs; Save-TcArchive row key has no code
#   J  the C# helper only reads (no ExecuteCommand, no window state) and compiles when the EnvDTE assemblies exist
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
# zh-TW Error List title (built from code points: this file stays ASCII)
$zhTitle = -join @([char]0x932f, [char]0x8aa4, [char]0x6e05, [char]0x55ae)
$zhProject = -join @([char]0x76ee, [char]0x524d, [char]0x7684, [char]0x5c08, [char]0x6848)

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

    # --- B: ErrorLevel -> severity ---
    $lvl = { param($l, $h) & $mod { param($a, $b) ConvertFrom-TcErrorLevel -Level $a -DteMajor $b } $l $h }
    Check 'B1 DTE 15 (4024): 4 -> Error, 2 -> Warning, 1 -> Message' ((& $lvl 4 15) -eq 'Error' -and (& $lvl 2 15) -eq 'Warning' -and (& $lvl 1 15) -eq 'Message') ''
    Check 'B2 DTE 15: a level outside 4 / 2 / 1 -> $null' ($null -eq (& $lvl 3 15) -and $null -eq (& $lvl 0 15)) ''
    Check 'B3 DTE 17 (4026): ErrorLevel 2 is every severity -> $null for every level' ($null -eq (& $lvl 2 17) -and $null -eq (& $lvl 1 17) -and $null -eq (& $lvl 4 17)) ''
    Check 'B3 unknown host -> $null' ($null -eq (& $lvl 4 $null)) ''

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

    # --- E: verdict ---
    $com = { param($ok = $true, $caption = 'Error List', $isolated = $true, $all = 3, $restored = $true, $reason = '', $err = '')
        [PSCustomObject]@{ ok = $ok; reason = $reason; error = $err; caption = $caption; isolated = $isolated; allCount = $all; flagsRestored = $restored } }
    $verdict = { param($c, $e = 1, $u = 0, $iso = 3, $expect = $false, $paneLines = $null)
        & $mod { param($c, $e, $u, $iso, $expect, $pl) Get-TcErrorListComVerdict -Com $c -ErrorRows $e -UnmappedRows $u -IsolatedTotal $iso -ExpectErrors:$expect -PaneLines $pl } $c $e $u $iso $expect $paneLines }
    $v = & $verdict (& $com)
    Check 'E1 whole list (Entire Solution, isolation adds up) -> accepted' ($v.accept -and [string]::IsNullOrEmpty($v.reason)) (J $v)
    $v = & $verdict (& $com -ok $false -reason 'timeout')
    Check 'E2 reader failed -> com-read-failed:timeout' (-not $v.accept -and $v.reason -eq 'com-read-failed:timeout') (J $v)
    $v = & $verdict (& $com -ok $false -reason 'com-error' -err 'boom')
    Check 'E2 reader exception text kept' (-not $v.accept -and $v.reason -eq 'com-read-failed:com-error: boom') (J $v)
    $v = & $verdict (& $com -caption "$zhTitle - $zhProject (X)") 0 0 3
    Check 'E3 scope Current Project: 0 error rows is NOT "no errors" -> scope-not-entire' (-not $v.accept -and $v.reason -match '^scope-not-entire') (J $v)
    $v = & $verdict (& $com -caption 'Fehlerliste')
    Check 'E4 caption of an unknown language -> scope-unknown' (-not $v.accept -and $v.reason -match '^scope-unknown') (J $v)
    $v = & $verdict (& $com -all 4) 1 0 3
    Check 'E5 isolated reads (3) do not add up to the all-flags count (4) -> severity-isolation-mismatch' (-not $v.accept -and $v.reason -match '^severity-isolation-mismatch') (J $v)
    $v = & $verdict (& $com -isolated $false -all 3) 1 1 0
    Check 'E6 level mode and a row with an unknown ErrorLevel -> error-level-unmapped' (-not $v.accept -and $v.reason -match '^error-level-unmapped') (J $v)
    $v = & $verdict (& $com -all 1) 0 0 1 $true
    Check 'E7 the build failed (ExpectErrors) and the COM list has no error row -> expected-errors-none-read' (-not $v.accept -and $v.reason -match '^expected-errors-none-read') (J $v)
    $v = & $verdict (& $com -all 1) 0 0 1 $false
    Check 'E7 same list without ExpectErrors (clean build) -> accepted: 0 errors is a result' ($v.accept) (J $v)
    $v = & $verdict (& $com -all 0) 0 0 0 $false
    Check 'E8 completely empty list in the Entire Solution scope -> accepted (the caption proves the scope)' ($v.accept) (J $v)
    $paneErr = & $mod { ConvertFrom-TcBuildPaneDiagnostics -Text "A.TcPOU(1) : error: C0046: a`nA.TcPOU(2) : error: C0046: b`nA.TcPOU(3) : error: C0046: c" }
    $v = & $verdict (& $com -all 2) 2 0 2 $true $paneErr
    Check 'E9 fresh build pane lists 3 error lines, COM has 2 error rows -> fewer-errors-than-build-pane' (-not $v.accept -and $v.reason -match '^fewer-errors-than-build-pane') (J $v)
    $v = & $verdict (& $com -all 3) 3 0 3 $true $paneErr
    Check 'E9 3 error lines, 3 error rows -> accepted' ($v.accept) (J $v)
    $v = & $verdict (& $com -restored $false)
    Check 'E10 flags could not be put back: accepted, with a note' ($v.accept -and @($v.notes).Count -eq 1) (J $v)

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
        function script:Read-TcErrorListCom { [CmdletBinding()] param([bool]$Isolate, [int]$MaxMs) $global:ReadCalls.Add($Isolate) | Out-Null; $global:ComRead }
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
        $d = @{ ok = $true; reason = ''; error = ''; caption = 'Error List'; isolated = $true; allCount = 0; flagsRestored = $true; flagsBefore = @($true, $false, $false); ms = 12.5
            all = @(); errors = @(); warnings = @(); messages = @() }
        foreach ($k in $o.Keys) { $d[$k] = $o[$k] }
        $global:ComRead = [PSCustomObject]$d
    }
    function ViaCom([hashtable]$p = @{}) { & $mod { param($h) Get-TcErrorListViaCom @h } $p }

    # F1 4026: ErrorLevel is 2 everywhere -> isolation
    Set-Com @{ allCount = 4
        errors = @((Row 2 "Identifier 'a' not defined"), (Row 2 "Identifier 'b' not defined" 'C:\p\FB.TcPOU@M (Impl)' 46))
        warnings = @((Row 2 'unused w')); messages = @((Row 2 'msg' '' 0)) }
    $r = ViaCom @{ IncludeMessages = $true; BuildPaneText = "Main.TcPOU(209) : error: C0046: Identifier 'a' not defined`nFB.TcPOU@M(210) : error: C0046: Identifier 'b' not defined" }
    Check 'F1 4026: isolation read accepted, source COM, severities from the flags, DTE 17 read isolated' ($r.accepted -and $r.data.source -eq 'ErrorList(COM)' -and $r.data.counts.errors -eq 2 -and $r.data.counts.warnings -eq 1 -and $r.data.counts.messages -eq 1 -and $global:ReadCalls[0] -eq $true -and $r.data.comRead.severityBy -eq 'ShowFlags') (J $r)
    Check 'F1 UIA-compatible items: file (Impl), project name, line, column null; codes from the fresh pane' ($r.data.errors[0].file -eq 'Main.TcPOU (Impl)' -and $r.data.errors[0].project -eq 'Plc' -and $r.data.errors[0].line -eq 45 -and $null -eq $r.data.errors[0].column -and $r.data.errors[0].code -eq 'C0046' -and $r.data.errors[1].code -eq 'C0046' -and $r.data.comRead.paneCrossCheck) (J $r.data.errors)
    Check 'F1 scope carried like the UIA result (entire $true), messages present, errorsWithoutCode 0' ($r.data.scope.entire -eq $true -and @($r.data.messages).Count -eq 1 -and $r.data.comRead.errorsWithoutCode -eq 0 -and $r.data.truncated -eq $false) (J $r.data.scope)
    $r2 = ViaCom @{ IncludeWarnings = $false }
    Check 'F1 -IncludeWarnings:$false: no warnings array, no messages array' ($null -eq $r2.data.PSObject.Properties['warnings'] -and $null -eq $r2.data.PSObject.Properties['messages']) ''
    $r3 = ViaCom @{}
    Check 'F1 without a pane the codes stay $null (supplied by nobody), errorsWithoutCode counts them' ($r3.accepted -and $null -eq $r3.data.errors[0].code -and $r3.data.comRead.errorsWithoutCode -eq 2 -and -not $r3.data.comRead.paneCrossCheck) (J $r3.data.comRead)

    # F2 4024: ErrorLevel 4 / 2 / 1
    $global:DteVersion = '15.0'
    $global:ReadCalls.Clear()
    Set-Com @{ isolated = $false; allCount = 3; all = @((Row 4 "Unknown type: 'X'" 'C:\p\MAIN.TcPOU' 42), (Row 2 'warn' 'C:\p\MAIN.TcPOU' 43), (Row 1 'info' '' 0)) }
    $r = ViaCom @{ IncludeMessages = $true }
    Check 'F2 4024 (DTE 15): one read, severity from ErrorLevel 4 / 2 / 1' ($r.accepted -and $global:ReadCalls[0] -eq $false -and $r.data.counts.errors -eq 1 -and $r.data.counts.warnings -eq 1 -and $r.data.counts.messages -eq 1 -and $r.data.comRead.severityBy -eq 'ErrorLevel' -and $r.data.errors[0].file -eq 'MAIN.TcPOU') (J $r)
    Set-Com @{ isolated = $false; allCount = 2; all = @((Row 4 'e'), (Row 3 'x')) }
    $r = ViaCom @{}
    Check 'F3 4024 with ErrorLevel 3 (not in the 4 / 2 / 1 table) -> rejected error-level-unmapped, nothing returned' (-not $r.accepted -and $r.reason -match '^error-level-unmapped' -and $null -eq $r.data) (J $r)
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
    $r = ViaCom @{}
    Check 'F8 helper not compilable -> rejected with its reason, reader not called' (-not $r.accepted -and $r.reason -eq 'com-helper-unavailable: csc blocked') (J $r)
    $global:ComTypes = $null
    Set-Com @{ allCount = 0 }
    $r = ViaCom @{}
    Check 'F9 empty list, Entire Solution scope, no failure expected -> accepted with 0 / 0 / 0' ($r.accepted -and $r.data.counts.errors -eq 0 -and @($r.data.errors).Count -eq 0) (J $r)
    Set-Com @{ allCount = 3; errors = @((Row 2 'e')); warnings = @((Row 2 'w')) }
    $r = ViaCom @{}
    Check 'F10 isolated reads add up to 2 but all-flags count is 3 -> rejected severity-isolation-mismatch' (-not $r.accepted -and $r.reason -match '^severity-isolation-mismatch') (J $r)
    $saveTde = & $mod { $script:TcDte }
    & $mod { $script:TcDte = $null }
    $r = ViaCom @{}
    Check 'F11 no DTE -> rejected com-unavailable' (-not $r.accepted -and $r.reason -match '^com-unavailable') (J $r)
    & $mod { param($d) $script:TcDte = $d } $saveTde

    # --- G: Get-TcBuildErrors ---
    & $mod {
        function script:Initialize-TcUiaScanTypes { [CmdletBinding()] param([int]$TimeoutSec) $true }
        function script:Invoke-TcUiaScan {
            [CmdletBinding()] param([scriptblock]$Script, [object[]]$Arguments, [int]$TimeoutSec, [ref]$TimedOut, [ref]$ErrorOut)
            $global:UiaCalls++
            $global:UiaBudgets.Add($TimeoutSec) | Out-Null
            $global:UiaResult
        }
    }
    $global:UiaCalls = 0
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

    # --- H: summary pass-through ---
    & $mod {
        function script:Get-TcBuildErrors { [CmdletBinding()] param([switch]$IncludeWarnings, [int]$TimeoutSec, [switch]$ExpectErrors, [string]$BuildPaneText)
            $global:SeenArgs = @{ ExpectErrors = [bool]$ExpectErrors; Pane = $BuildPaneText; Timeout = $TimeoutSec }
            [PSCustomObject]@{ success = $true; error = $null; data = [PSCustomObject]@{
                    counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }; errors = @(); warnings = @(); truncated = $false
                    source = 'ErrorList(UIA)'; fallbackReason = 'scope-not-entire: x' } }
        }
    }
    $s = & $mod { Get-TcErrorListSummary -TimeoutSec 30 -ExpectErrors -BuildPaneText 'PANE' }
    Check 'H1 summary hands ExpectErrors / BuildPaneText / TimeoutSec to Get-TcBuildErrors' ($global:SeenArgs.ExpectErrors -and $global:SeenArgs.Pane -eq 'PANE' -and $global:SeenArgs.Timeout -eq 30) (J $global:SeenArgs)
    Check 'H1 summary exposes errorListSource / errorListFallbackReason' ($s.errorListSource -eq 'ErrorList(UIA)' -and $s.errorListFallbackReason -eq 'scope-not-entire: x') (J ($s | Select-Object errorListSource, errorListFallbackReason))
    $null = & $mod { Get-TcErrorListSummary }
    Check 'H2 without the new switches nothing extra is passed (old mocks / callers unchanged)' (-not $global:SeenArgs.ExpectErrors -and [string]::IsNullOrEmpty($global:SeenArgs.Pane)) (J $global:SeenArgs)

    # --- I: callers (static) ---
    $pub = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public'
    $build = [IO.File]::ReadAllText((Join-Path $pub 'Build-TcProject.ps1'))
    Check 'I1 Build-TcProject: ExpectErrors from LastBuildInfo > 0 and the pane text of this build go to the summary' ($build -match '-ExpectErrors:\$elExpectErrors' -and $build -match '-BuildPaneText\s+\$elPaneText' -and $build -match '\$elExpectErrors\s*=\s*\(\$null -ne \$failedProjects -and \[int\]\$failedProjects -gt 0\)') ''
    $test = [IO.File]::ReadAllText((Join-Path $pub 'Test-TcPlcProject.ps1'))
    Check 'I2 Test-TcPlcProject (CheckAllObjects): ExpectErrors when the check returned False' ($test -match 'Get-TcErrorListSummary\s+-TimeoutSec\s+\$script:TcBuildErrorListTimeoutSec\s+-SplitRuntimeLog\s+-ExpectErrors:\(\$passed -eq \$false\)') ''
    $clear = [IO.File]::ReadAllText((Join-Path $pub 'Clear-TcProject.ps1'))
    Check 'I3 Clear-TcProject: ExpectErrors (it only reads the list when LastBuildInfo > 0)' ($clear -match 'Get-TcBuildErrors\s+-TimeoutSec\s+\$script:TcBuildErrorListTimeoutSec\s+-ExpectErrors') ''
    $arch = [IO.File]::ReadAllText((Join-Path $pub 'Save-TcArchive.ps1'))
    Check 'I4 Save-TcArchive row key has no code (the COM and the UIA read of one row must compare equal)' ($arch -match '\$rowKey\s*=\s*\{\s*param\(\$i\)\s*"\$\(\[string\]\$i\.description\)\|' -and $arch -notmatch '\$rowKey\s*=\s*\{[^}]*\$i\.code') ''

    # --- J: the C# helper ---
    $csPath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Private\ErrorListComReader.cs'
    $cs = [IO.File]::ReadAllText($csPath)
    $csCode = ($cs -split "`n" | Where-Object { $_ -notmatch '^\s*//' }) -join "`n"
    Check 'J1 helper reads and sets the three Show* flags only: no ExecuteCommand / Activate / Visible / AutoHides / Close / WindowState' ($csCode -notmatch 'ExecuteCommand|\.Activate\(|\.Visible\s*=|AutoHides|\.Close\(|WindowState|SetFocus|SendKeys') ''
    Check 'J2 helper restores the flags in finally and iterates 1..Count inclusive' ($csCode -match 'finally' -and $csCode -match 'el\.ShowErrors = res\.FlagsBefore\[0\]' -and $csCode -match 'for \(int i = 1; i <= count; i\+\+\)') ''
    $paths = & $mod { Get-TcErrorListComAssemblyPaths -IdeProcessId 0 }
    if ($null -eq $paths) {
        Check 'J3 EnvDTE assemblies not installed on this machine: compile check skipped' $true 'no TcXaeShell / Visual Studio PublicAssemblies found'
    }
    else {
        $code = @"
`$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition ([IO.File]::ReadAllText('$($csPath.Replace("'", "''"))')) -ReferencedAssemblies @('$($paths[0].Replace("'", "''"))', '$($paths[1].Replace("'", "''"))')
`$m = [TcAutomation.ErrorListComReader].GetMethod('Read')
'{0}|{1}' -f `$m.ReturnType.Name, ((`$m.GetParameters() | ForEach-Object { `$_.ParameterType.Name }) -join ',')
"@
        $out = & powershell.exe -NoProfile -NonInteractive -Command $code 2>&1 | Out-String
        Check 'J3 ErrorListComReader.cs compiles (Add-Type against the IDE EnvDTE assemblies): Read(object, bool, int, int) -> ErrorListComResult' ($out.Trim() -eq 'ErrorListComResult|Object,Boolean,Int32,Int32') $out.Trim()
    }
}
finally {
    if ($tcUnit88OwnDir -and (Test-Path -LiteralPath $env:TCAUTO_STATE_DIR) -and ((Split-Path -Leaf $env:TCAUTO_STATE_DIR) -like 'tcauto-unit-88-*')) {
        Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    }
}
"failed: $fail"
exit $fail
