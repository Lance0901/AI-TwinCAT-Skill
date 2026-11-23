# Error List via COM (DTE2.ToolWindows.ErrorList.ErrorItems), the primary source of Get-TcBuildErrors
# (item 88, re #320 / #329 / #300). The UI Automation scan (Get-TcIdeErrorList.ps1) is the fallback.
#
# What was measured (2026-11-23, G16 report item88, VS2022 4026 zh-TW, XAE 64-bit 4026, XAE 32-bit TcXaeShell 15.0):
#  - early binding (C#, ErrorListComReader.cs) reads the full list in the IDE's own process space of the call,
#    same row counts as the UIA scan, no Error List window shown, no foreground change; 529 rows 0.96 s.
#    PowerShell late binding reads a fake 0 (that was the old "ErrorItems is always 0").
#  - ErrorItems follows the Errors / Warnings / Messages buttons (ShowErrors / ShowWarnings / ShowMessages) and the
#    scope filter. The scope is NOT a property of the COM object, but the Error List window caption carries it:
#    'Error List' / 'Error List - Current Project (<proj>)' / '... - Current Document' / '... - Open Documents'
#    (zh-TW: the localized title + the same suffix). Entire Solution = the bare caption. A filtered scope answers 0 or a few
#    rows WITHOUT an error, so a partial scope must never be read as "no errors" (fail closed: UIA fallback).
#  - NOT visible to COM: the Error List search box text and the VS2022 column filters (review #332 M1). A list filtered
#    that way looks like a whole list. Callers whose result decides success (Build-TcProject) therefore accept a COM list
#    only with the end summary line of THIS build's output pane (-RequireBuildSummary); the callers that have no pane
#    (Clear-TcProject, Save-TcArchive, New-TcBootProject) read through UIA, which compares the rows with the button totals.
#  - ErrorLevel (vsBuildErrorLevel): Low = 1, Medium = 2, High = 4
#    (https://learn.microsoft.com/en-us/dotnet/api/envdte80.vsbuilderrorlevel, checked 2026-11-23; the first version of this
#    comment said High 1 / Low 3, which is wrong). 4024 (TcXaeShell 15.0, DTE 15.0) shows error 4 / warning 2 / message 1
#    (= High / Medium / Low, 實測 2026-11-23). 4026 (DTE 17.0) shows 2 for errors, warnings and messages alike (1 only for
#    'Related position' rows, 實測 2026-11-23; no InfoSys source), so there the level cannot give the severity.
#    The severity of EVERY row comes from reading one Show* flag at a time; where the host's levels are known (DTE 15) they
#    only cross-check it (a row whose level disagrees with its flag rejects the COM read, review #332 S4).
#    Which flag exposes the level-1 'Related position' rows of 4026 is not recorded (未測): data.comRead.levelCounts
#    lists the levels seen per severity so the first real run can tell.
#  - Description has no compiler code; FileName is the full path + ' (Impl)' / ' (Decl)' (4026) or the full path (4024);
#    Project is the .plcproj path relative to the solution; Column is always 1; Line like the UIA scan.
#  - The Error List window is only used when it already exists (looked up in DTE.Windows, review #332 S7): the first access
#    to ToolWindows.ErrorList would create it (XAE 64-bit: an auto-hidden tab appears) and change the user's layout.
#    Not created yet -> reason 'errorlist-not-created', the UIA scan runs (it shows the window itself).
#  - Deadline (CODING_STANDARDS 1): the read has a cooperative budget (-MaxMs, checked between COM calls, compile and the
#    pane work included); one COM call that blocks in the IDE (modal dialog) cannot be interrupted, as with
#    Invoke-TcComRetry. Moving it to a background runspace was not done: an abandoned read keeps the user's Show* flags
#    changed (the restore sits in its finally block), which is worse than a late return. Retries are one extra attempt at
#    most and stop at $script:TcComCallDeadline.
#  - File encoding: ASCII (the zh-TW titles are built from code points).

# vsBuildErrorLevel values per IDE host (key = DTE.Version major). 15 = TcXaeShell 15.0 (VS2017 shell); 17.x maps nothing.
$script:TcErrorLevelSeverityByDteMajor = @{
    15 = @{ 4 = 'Error'; 2 = 'Warning'; 1 = 'Message' }
}

# zh-TW pieces as code points (this file stays ASCII)
$script:TcZhErrorListTitle = -join @([char]0x932f, [char]0x8aa4, [char]0x6e05, [char]0x55ae)   # Error List
$script:TcZhBuild = -join @([char]0x7d44, [char]0x5efa)                                          # Build
$script:TcZhFailed = -join @([char]0x5931, [char]0x6557)                                         # Failed

# Scope part of the Error List window caption (Window.Caption). Entire Solution = the bare window title.
$script:TcErrorListEntireCaptionPattern = '^(Error List|' + $script:TcZhErrorListTitle + ')$'
$script:TcErrorListScopeCaptionPattern = '^(Error List|' + $script:TcZhErrorListTitle + ')\s+-\s+(?<scope>.+)$'

# End summary lines of the build pane (Get-TcBuildOutputPane text of one build):
#   PLC compiler   'Build complete -- 0 errors' (實測, add-semantic-linter verification/xae-corrupt-file-behavior.md)
#   MSBuild        '========== Build: 1 succeeded, 0 failed, 0 up-to-date, 0 skipped ==========' (documented form)
#   zh-TW VS2022   '========= <Build>: <succeeded> N <unit>, <Failed> 0 <unit>, ... ==========' (實測 2026-11-09, tests/Unit/build-output-pane-219.ps1)
$script:TcBuildSummaryPlcPattern = '(?im)^\s*Build complete\s*--\s*(?<e>\d+)\s+errors?\b'
$script:TcBuildSummaryMsbuildPattern = '(?im)^\s*={2,}\s*Build:\s*\d+\s+succeeded,\s*(?<f>\d+)\s+failed\b'
$script:TcBuildSummaryZhPattern = '(?m)^\s*={2,}\s*' + $script:TcZhBuild + '\s*[:' + [char]0xff1a + ']\s*.*?' + $script:TcZhFailed + '\s*(?<f>\d+)'

# Per process: $null (not tried) or @{ ok; reason; at; idePid }. A failure is retried after $script:TcErrorListComRetryAfterSec
# or when another IDE process is connected (review #332 N5).
$script:TcErrorListComTypeState = $null
$script:TcErrorListComRetryAfterSec = 30
$script:TcErrorListComDefaultMaxMs = 10000
$script:TcErrorListComSettleMs = 150

function ConvertFrom-TcErrorListScopeCaption {
    <#
    .SYNOPSIS
        { kind = 'entire' | 'partial' | 'unknown'; scope } of an Error List window caption.
    .DESCRIPTION
        entire   the bare title ('Error List' / zh-TW title): scope Entire Solution
        partial  '<title> - <scope>' ('Current Project (X)', 'Current Document', 'Open Documents', ...): the list is filtered
        unknown  no caption, or a title this module does not know (other UI language): not provably the entire solution
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Caption)
    if ([string]::IsNullOrWhiteSpace($Caption)) { return [PSCustomObject]@{ kind = 'unknown'; scope = $null } }
    $c = $Caption.Trim()
    if ($c -match $script:TcErrorListEntireCaptionPattern) { return [PSCustomObject]@{ kind = 'entire'; scope = $null } }
    if ($c -match $script:TcErrorListScopeCaptionPattern) { return [PSCustomObject]@{ kind = 'partial'; scope = [string]$Matches['scope'] } }
    return [PSCustomObject]@{ kind = 'unknown'; scope = $null }
}

function ConvertFrom-TcErrorLevel {
    <#
    .SYNOPSIS
        'Error' / 'Warning' / 'Message' for an ErrorItem.ErrorLevel of the given IDE host, or $null when the host's
        levels do not tell the severity (4026: every row is 2) or the value is not a known one.
    .PARAMETER DteMajor
        Major of DTE.Version (15 = TcXaeShell 15.0 / 4024, 17 = VS2022 and the 64-bit XAE of 4026); $null = unknown host.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$Level, [AllowNull()][object]$DteMajor)
    if ($null -eq $DteMajor) { return $null }
    $map = $script:TcErrorLevelSeverityByDteMajor[[int]$DteMajor]
    if ($null -eq $map) { return $null }
    if (-not $map.ContainsKey($Level)) { return $null }
    return [string]$map[$Level]
}

function Get-TcErrorLevelMismatchCount {
    <#
    .SYNOPSIS
        Cross-check of the Show*-flag severity against the host's ErrorLevel table: the number of rows whose ErrorLevel is not
        the level the host uses for the severity of the flag that exposed them. 0 for a host without a table (4026).
    #>
    [CmdletBinding()]
    param(
        [AllowNull()][object]$DteMajor,
        [AllowNull()][object[]]$ErrorRows,
        [AllowNull()][object[]]$WarningRows,
        [AllowNull()][object[]]$MessageRows
    )
    if ($null -eq $DteMajor) { return 0 }
    $map = $script:TcErrorLevelSeverityByDteMajor[[int]$DteMajor]
    if ($null -eq $map) { return 0 }
    $bad = 0
    foreach ($pair in @(@('Error', $ErrorRows), @('Warning', $WarningRows), @('Message', $MessageRows))) {
        $want = $null
        foreach ($k in $map.Keys) { if ([string]$map[$k] -eq [string]$pair[0]) { $want = [int]$k } }
        foreach ($r in @($pair[1])) { if ($null -ne $r -and [int]$r.Level -ne $want) { $bad++ } }
    }
    return $bad
}

function ConvertTo-TcErrorListComFile {
    <#
    .SYNOPSIS
        UIA-compatible 'file' of an ErrorItem.FileName: the base name, the ' (Impl)' / ' (Decl)' suffix and an
        '@<member>' part kept as the UIA grid shows them ('Main.TcPOU (Impl)', 'FB_X.TcPOU@Method (Impl)', 4024: 'MAIN.TcPOU').
        filePath = the full path without the suffix. Both $null for an empty name.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$FileName)
    if ([string]::IsNullOrWhiteSpace($FileName)) { return [PSCustomObject]@{ file = $null; filePath = $null; part = $null } }
    $t = $FileName.Trim()
    $part = $null
    if ($t -match '^(?<name>.*?)\s+\((?<part>Impl|Decl)\)$') { $t = $Matches['name']; $part = $Matches['part'] }
    $slash = [Math]::Max($t.LastIndexOf('\'), $t.LastIndexOf('/'))
    $base = if ($slash -ge 0) { $t.Substring($slash + 1) } else { $t }
    $file = if ($null -ne $part) { "$base ($part)" } else { $base }
    return [PSCustomObject]@{ file = $file; filePath = $t; part = $part }
}

function ConvertTo-TcErrorListComProject {
    <#
    .SYNOPSIS
        UIA-compatible 'project' of an ErrorItem.Project: the project file name without extension
        ('AxisInterface_Type01_Library\AxisInterface\AxisInterface.plcproj' -> 'AxisInterface'), $null when empty.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Project)
    if ([string]::IsNullOrWhiteSpace($Project)) { return $null }
    $t = $Project.Trim()
    $slash = [Math]::Max($t.LastIndexOf('\'), $t.LastIndexOf('/'))
    $leaf = if ($slash -ge 0) { $t.Substring($slash + 1) } else { $t }
    if ($leaf -match '^(?<n>.+)\.(plcproj|tsproj|tmcproj|sln)$') { return [string]$Matches['n'] }
    return $leaf
}

function ConvertTo-TcErrorListComItem {
    <#
    .SYNOPSIS
        One COM row -> the public item shape of Get-TcBuildErrors (severity, code, description, project, file, line,
        column) plus filePath. code is $null (Resolve-TcErrorItemCode fills it from the build pane); column is $null
        like the UIA scan (the COM column is a constant 1).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Row, [Parameter(Mandatory)][string]$Severity)
    $f = ConvertTo-TcErrorListComFile -FileName ([string]$Row.FileName)
    [PSCustomObject]@{
        severity    = $Severity
        code        = $null
        description = [string]$Row.Description
        project     = ConvertTo-TcErrorListComProject -Project ([string]$Row.Project)
        file        = $f.file
        line        = [int]$Row.Line
        column      = $null
        filePath    = $f.filePath
    }
}

function ConvertFrom-TcBuildPaneDiagnostics {
    <#
    .SYNOPSIS
        The compiler lines of the build pane text as { severity ('Error'|'Warning'), file, line, code, text }.
    .DESCRIPTION
        Line forms (Get-TcBuildWarningLines): '<file>(<line>) : error: C0046: <text>' (TwinCAT PLC compiler) and
        '<file>(<line>,<col>): error C0046: <text>' (MSBuild); the code (Cxxxx / SAxxxx) is optional. The pane line
        number is NOT the Error List line on 4026 (whole object file vs. line inside the Impl section, measured
        2026-11-23: 209-211 vs 45-47), so callers match on file + text and use the line only to choose between equals.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    $out = [System.Collections.Generic.List[object]]::new()
    if ([string]::IsNullOrWhiteSpace($Text)) { return , $out.ToArray() }
    $rx = [regex]'(?i)^\s*(?<file>.+?)\((?<line>\d+)(?:,\d+)?\)\s*:\s*(?<sev>error|warning)\b\s*:?\s*(?:(?<code>[A-Za-z]{1,3}\d{3,5})\b\s*:?\s*)?(?<text>.*?)\s*$'
    foreach ($ln in ($Text -split "`n")) {
        $l = $ln.TrimEnd("`r")
        if ($l.Trim() -eq '') { continue }
        $m = $rx.Match($l)
        if (-not $m.Success) { continue }
        $out.Add([PSCustomObject]@{
                severity = $(if ($m.Groups['sev'].Value -ieq 'error') { 'Error' } else { 'Warning' })
                file     = $m.Groups['file'].Value.Trim()
                line     = [int]$m.Groups['line'].Value
                code     = $(if ($m.Groups['code'].Success) { $m.Groups['code'].Value.ToUpperInvariant() } else { $null })
                text     = $m.Groups['text'].Value
            })
    }
    return , $out.ToArray()
}

function ConvertFrom-TcBuildPaneSummary {
    <#
    .SYNOPSIS
        The end summary of the build pane of ONE build: { found; errors; failedProjects; lines }.
    .DESCRIPTION
        errors          sum of the 'Build complete -- N errors' lines (PLC compiler), $null when there is none
        failedProjects  sum of the failed counts of the MSBuild summary lines (English and zh-TW), $null when there is none
        found           at least one of them. Another UI language / no summary line -> found = $false (not proven).
        Review #332 M1: the only proof a COM list may stand for "no error" besides the row count itself.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text)
    $errors = $null
    $failed = $null
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($ln in ($Text -split "`n")) {
            $l = $ln.TrimEnd("`r")
            $m = [regex]::Match($l, $script:TcBuildSummaryPlcPattern)
            if ($m.Success) { $errors = [int]$errors + [int]$m.Groups['e'].Value; $lines.Add($l.Trim()); continue }
            $m = [regex]::Match($l, $script:TcBuildSummaryMsbuildPattern)
            if (-not $m.Success) { $m = [regex]::Match($l, $script:TcBuildSummaryZhPattern) }
            if ($m.Success) { $failed = [int]$failed + [int]$m.Groups['f'].Value; $lines.Add($l.Trim()) }
        }
    }
    [PSCustomObject]@{ found = ($null -ne $errors -or $null -ne $failed); errors = $errors; failedProjects = $failed; lines = $lines.ToArray() }
}

function Get-TcErrorListFileKey {
    # base name of a file column / pane file without ' (Impl)' / ' (Decl)' and without '@<member>', lower case
    param([AllowNull()][string]$File)
    if ([string]::IsNullOrWhiteSpace($File)) { return '' }
    $t = $File.Trim() -replace '\s+\((Impl|Decl)\)$', ''
    $slash = [Math]::Max($t.LastIndexOf('\'), $t.LastIndexOf('/'))
    if ($slash -ge 0) { $t = $t.Substring($slash + 1) }
    $at = $t.IndexOf('@')
    if ($at -ge 0) { $t = $t.Substring(0, $at) }
    return $t.ToLowerInvariant()
}

function Get-TcPaneIndexKey {
    # severity | file key | text (case sensitive, trimmed): the key a COM row and a pane line share
    param([string]$Severity, [AllowNull()][string]$File, [AllowNull()][string]$Text)
    return ($Severity + '|' + (Get-TcErrorListFileKey -File $File) + '|' + ([string]$Text).Trim())
}

function New-TcPaneLineIndex {
    <#
    .SYNOPSIS
        Pane lines (ConvertFrom-TcBuildPaneDiagnostics) grouped by Get-TcPaneIndexKey: ordinal Dictionary key -> List of lines.
        Built once, so the code lookup of N rows is O(N), not O(N x pane lines) (review #332 S6).
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$PaneLines)
    $idx = [System.Collections.Generic.Dictionary[string, System.Collections.Generic.List[object]]]::new([System.StringComparer]::Ordinal)
    foreach ($l in @($PaneLines)) {
        if ($null -eq $l) { continue }
        $k = Get-TcPaneIndexKey -Severity ([string]$l.severity) -File ([string]$l.file) -Text ([string]$l.text)
        if (-not $idx.ContainsKey($k)) { $idx[$k] = [System.Collections.Generic.List[object]]::new() }
        $idx[$k].Add($l)
    }
    return , $idx
}

function Resolve-TcErrorItemCode {
    <#
    .SYNOPSIS
        The compiler code (Cxxxx / SAxxxx) of one COM item from the build pane lines, or $null when it cannot be
        told (no matching line, or matching lines with different codes).
    .DESCRIPTION
        Candidates = pane lines of the same severity, same file (base name) and the same text. Several candidates:
        those with the same line number win; the result is the code only when the remaining candidates agree on one.
        Never inferred from the description text (the old UIA inference stays in the UIA path only).
    .PARAMETER Index
        New-TcPaneLineIndex of the pane lines (pass it when resolving many items); built from -PaneLines when omitted.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [AllowNull()][object[]]$PaneLines, [AllowNull()][object]$Index = $null)
    if ($null -eq $Index) { $Index = New-TcPaneLineIndex -PaneLines $PaneLines }
    if ($Index.Count -eq 0) { return $null }
    if ((Get-TcErrorListFileKey -File ([string]$Item.file)) -eq '') { return $null }
    $k = Get-TcPaneIndexKey -Severity ([string]$Item.severity) -File ([string]$Item.file) -Text ([string]$Item.description)
    if (-not $Index.ContainsKey($k)) { return $null }
    $cand = @($Index[$k])
    $sameLine = @($cand | Where-Object { [int]$_.line -eq [int]$Item.line })
    if ($sameLine.Count -gt 0) { $cand = $sameLine }
    $codes = @($cand | ForEach-Object { $_.code } | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique)
    if ($codes.Count -eq 1 -and @($cand | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.code) }).Count -eq 0) { return [string]$codes[0] }
    return $null
}

function Get-TcUnmatchedPaneErrorCount {
    <#
    .SYNOPSIS
        How many error lines of the pane of THIS build have no error row (same file, same text) in the COM list.
        A filter that hides the compile errors but shows other rows (a Library Manager row) fails here (review #332 M1).
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$PaneLines, [AllowNull()][object[]]$ErrorItems)
    $have = [System.Collections.Generic.Dictionary[string, int]]::new([System.StringComparer]::Ordinal)
    foreach ($i in @($ErrorItems)) {
        if ($null -eq $i) { continue }
        $k = Get-TcPaneIndexKey -Severity 'Error' -File ([string]$i.file) -Text ([string]$i.description)
        $n = 0
        if ($have.TryGetValue($k, [ref]$n)) { $have[$k] = $n + 1 } else { $have[$k] = 1 }
    }
    $missing = 0
    foreach ($l in @($PaneLines)) {
        if ($null -eq $l -or [string]$l.severity -ne 'Error') { continue }
        $k = Get-TcPaneIndexKey -Severity 'Error' -File ([string]$l.file) -Text ([string]$l.text)
        $n = 0
        if ($have.TryGetValue($k, [ref]$n) -and $n -gt 0) { $have[$k] = $n - 1 } else { $missing++ }
    }
    return $missing
}

function Get-TcErrorListComVerdict {
    <#
    .SYNOPSIS
        Decides whether a COM read may stand for the whole Error List: { accept; reason; notes; flagsRestored }.
        Fail closed: anything that cannot be proven falls back to the UIA scan (the result carries the reason).
    .DESCRIPTION
        A COM read is rejected when
          - it failed (reason com-read-failed:<why>; errorlist-not-created when the Error List window never existed)
          - the Error List scope is not provably Entire Solution (scope-not-entire / scope-unknown): the list is filtered
            and a filtered list answers 0 rows without an error
          - isolation (severity by one Show* flag at a time) does not add up: sum of the three reads != all-flags count
          - the host's ErrorLevel table (DTE 15) disagrees with the flag a row was read under (error-level-mismatch)
          - the caller knows the build / check failed (-ExpectErrors) and no error row was read
          - -RequireBuildSummary and the pane of THIS build has no end summary (build-summary-missing), or the summary says
            more errors than rows were read (fewer-errors-than-build-summary)
          - the fresh build pane (-PaneLines of THIS build) lists more error lines than error rows were read, or an error
            line has no row with the same file and text (build-pane-error-not-in-list)
        Not a reason: a row count of 0 on its own (a clean build can have an empty list) - the scope check above is what
        tells an empty list from a hidden one, and for -RequireBuildSummary callers the pane summary does.
        What COM cannot see: the search box text and column filters of the Error List (review #332 M1); only the pane
        cross-checks above catch them, which is why the deciding callers require the summary.
    .PARAMETER Com
        Read-TcErrorListCom result: ok, reason, caption, allCount, flagsRestored.
    .PARAMETER ErrorRows
        Number of rows read under ShowErrors only.
    .PARAMETER LevelMismatchRows
        Rows whose ErrorLevel disagrees with the host's table (Get-TcErrorLevelMismatchCount).
    .PARAMETER IsolatedTotal
        Sum of the three isolated reads.
    .PARAMETER ExpectErrors
        The caller knows at least one error exists (LastBuildInfo > 0, CheckAllObjects False).
    .PARAMETER PaneLines
        ConvertFrom-TcBuildPaneDiagnostics of a pane that belongs to THIS build, or $null (no cross-check).
    .PARAMETER ErrorItems
        The error items of the COM read (for the pane line match).
    .PARAMETER RequireBuildSummary
        The result decides success: a COM list is accepted only with a parsed end summary in -PaneSummary.
    .PARAMETER PaneSummary
        ConvertFrom-TcBuildPaneSummary of the pane of THIS build.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Com,
        [int]$ErrorRows = 0,
        [int]$LevelMismatchRows = 0,
        [int]$IsolatedTotal = 0,
        [switch]$ExpectErrors,
        [AllowNull()][object[]]$PaneLines = $null,
        [AllowNull()][object[]]$ErrorItems = $null,
        [switch]$RequireBuildSummary,
        [AllowNull()][object]$PaneSummary = $null
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    $flagsOk = $true
    if ($null -ne $Com.PSObject.Properties['flagsRestored']) { $flagsOk = [bool]$Com.flagsRestored }
    $verdict = { param([bool]$Accept, [string]$Reason) [PSCustomObject]@{ accept = $Accept; reason = $Reason; notes = $notes.ToArray(); flagsRestored = $flagsOk } }
    if (-not [bool]$Com.ok) {
        if ([string]$Com.reason -eq 'errorlist-not-created') { return (& $verdict $false 'errorlist-not-created') }
        $why = [string]$Com.reason
        if (-not [string]::IsNullOrWhiteSpace([string]$Com.error)) { $why += ": $([string]$Com.error)" }
        if (-not $flagsOk) { $why += '; the Error List Errors / Warnings / Messages buttons could not be set back to their earlier state' }
        return (& $verdict $false "com-read-failed:$why")
    }
    $scope = ConvertFrom-TcErrorListScopeCaption -Caption ([string]$Com.caption)
    if ($scope.kind -eq 'partial') { return (& $verdict $false "scope-not-entire: the Error List caption is '$([string]$Com.caption)' (scope '$($scope.scope)'), the list is filtered") }
    if ($scope.kind -eq 'unknown') { return (& $verdict $false "scope-unknown: the Error List caption '$([string]$Com.caption)' is not a known Entire Solution caption") }
    if ($IsolatedTotal -ne [int]$Com.allCount) {
        return (& $verdict $false "severity-isolation-mismatch: errors+warnings+messages read one flag at a time = $IsolatedTotal, all flags on = $([int]$Com.allCount)")
    }
    if ($LevelMismatchRows -gt 0) {
        return (& $verdict $false "error-level-mismatch: $LevelMismatchRows row(s) have an ErrorLevel that does not fit the Show* flag they were read under")
    }
    if ($ExpectErrors -and $ErrorRows -eq 0) {
        return (& $verdict $false 'expected-errors-none-read: the build / check failed but the COM list has no error row')
    }
    if ($RequireBuildSummary) {
        if ($null -eq $PaneSummary -or -not [bool]$PaneSummary.found) {
            return (& $verdict $false 'build-summary-missing: the build pane of this build has no end summary line (Build complete -- N errors / Build: ... failed), so a filtered Error List (search box, column filter) cannot be ruled out')
        }
        if ($null -ne $PaneSummary.errors -and [int]$PaneSummary.errors -gt $ErrorRows) {
            return (& $verdict $false "fewer-errors-than-build-summary: the build summary says $([int]$PaneSummary.errors) error(s), the COM list has $ErrorRows error row(s)")
        }
        if ($null -ne $PaneSummary.failedProjects -and [int]$PaneSummary.failedProjects -gt 0 -and $ErrorRows -eq 0) {
            return (& $verdict $false "fewer-errors-than-build-summary: the build summary says $([int]$PaneSummary.failedProjects) project(s) failed, the COM list has no error row")
        }
    }
    if ($null -ne $PaneLines) {
        $paneErrors = @($PaneLines | Where-Object { $_.severity -eq 'Error' }).Count
        if ($paneErrors -gt $ErrorRows) {
            return (& $verdict $false "fewer-errors-than-build-pane: the build pane lists $paneErrors error line(s), the COM list has $ErrorRows error row(s)")
        }
        $unmatched = Get-TcUnmatchedPaneErrorCount -PaneLines $PaneLines -ErrorItems $ErrorItems
        if ($unmatched -gt 0) {
            return (& $verdict $false "build-pane-error-not-in-list: $unmatched error line(s) of the build pane have no row with the same file and text in the COM list")
        }
    }
    if (-not $flagsOk) { $notes.Add('the Error List Errors / Warnings / Messages buttons could not be set back to their earlier state') }
    return (& $verdict $true $null)
}

function Get-TcErrorListComAssemblyPaths {
    <#
    .SYNOPSIS
        EnvDTE.dll / EnvDTE80.dll of the connected IDE (...\Common7\IDE\PublicAssemblies next to the IDE exe), else of an
        installed TcXaeShell / VS2022; $null when none is found.
    #>
    [CmdletBinding()]
    param([int]$IdeProcessId = 0)
    $dirs = [System.Collections.Generic.List[string]]::new()
    if ($IdeProcessId -gt 0) {
        try {
            $exe = [string](Get-Process -Id $IdeProcessId -ErrorAction Stop).MainModule.FileName
            if (-not [string]::IsNullOrWhiteSpace($exe)) { $dirs.Add((Join-Path (Split-Path -Parent $exe) 'PublicAssemblies')) }
        }
        catch { Write-Verbose "Get-TcErrorListComAssemblyPaths: IDE exe path not readable ($($_.Exception.Message))" }
    }
    $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    if (-not [string]::IsNullOrWhiteSpace($pf86)) { $dirs.Add((Join-Path $pf86 'Beckhoff\TcXaeShell\Common7\IDE\PublicAssemblies')) }
    foreach ($pf in @($env:ProgramFiles, $pf86)) {
        if ([string]::IsNullOrWhiteSpace($pf)) { continue }
        foreach ($d in @(Get-ChildItem -LiteralPath (Join-Path $pf 'Microsoft Visual Studio') -Directory -ErrorAction SilentlyContinue)) {
            foreach ($ed in @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)) {
                $dirs.Add((Join-Path $ed.FullName 'Common7\IDE\PublicAssemblies'))
            }
        }
    }
    foreach ($dir in $dirs) {
        $a = Join-Path $dir 'EnvDTE.dll'
        $b = Join-Path $dir 'EnvDTE80.dll'
        if ((Test-Path -LiteralPath $a -PathType Leaf) -and (Test-Path -LiteralPath $b -PathType Leaf)) {
            # VS2022 EnvDTE80 type-forwards DTE2 / ErrorList to Microsoft.VisualStudio.Interop (same folder): compile and load need it too
            $c = Join-Path $dir 'Microsoft.VisualStudio.Interop.dll'
            if (Test-Path -LiteralPath $c -PathType Leaf) { return @($a, $b, $c) }
            return @($a, $b)
        }
    }
    return $null
}

function Initialize-TcErrorListComTypes {
    <#
    .SYNOPSIS
        Compiles ErrorListComReader.cs once per process (Add-Type). Returns { ok; reason }.
        A failure is cached only for $script:TcErrorListComRetryAfterSec seconds and for the IDE process it happened with
        (assemblies of another IDE, or a transient load error, may work later, review #332 N5).
    #>
    [CmdletBinding()]
    param([int]$IdeProcessId = 0)
    $st = $script:TcErrorListComTypeState
    if ($null -ne $st) {
        if ($st.ok) { return $st }
        $age = ([DateTime]::UtcNow - [DateTime]$st.at).TotalSeconds
        if ($age -lt [double]$script:TcErrorListComRetryAfterSec -and [int]$st.idePid -eq $IdeProcessId) { return $st }
    }
    $state = [PSCustomObject]@{ ok = $false; reason = $null; at = [DateTime]::UtcNow; idePid = $IdeProcessId }
    if (([System.Management.Automation.PSTypeName]'TcAutomation.ErrorListComReader').Type) {
        $state.ok = $true
        $script:TcErrorListComTypeState = $state
        return $state
    }
    try {
        $csPaths = @((Join-Path $PSScriptRoot 'ErrorListComCore.cs'), (Join-Path $PSScriptRoot 'ErrorListComReader.cs'))
        foreach ($cs in $csPaths) {
            if (-not (Test-Path -LiteralPath $cs -PathType Leaf)) { throw "$([IO.Path]::GetFileName($cs)) not found next to the module ($cs)" }
        }
        $paths = Get-TcErrorListComAssemblyPaths -IdeProcessId $IdeProcessId
        # the compiled assembly binds EnvDTE / EnvDTE80 (and Interop) by identity at the first call: they are not in the GAC,
        # so load them from the IDE folder first (measured 2026-11-23: without this the first Read fails with FileNotFoundException)
        if ($null -ne $paths) { foreach ($p in $paths) { [void][System.Reflection.Assembly]::LoadFrom($p) } }
        $refs = if ($null -ne $paths) { @($paths) } else { @('EnvDTE', 'EnvDTE80') }
        Add-Type -Path $csPaths -ReferencedAssemblies $refs -ErrorAction Stop
        $state.ok = $true
    }
    catch {
        $state.reason = "com-helper-unavailable: $($_.Exception.Message)"
    }
    $script:TcErrorListComTypeState = $state
    return $state
}

function Read-TcErrorListCom {
    <#
    .SYNOPSIS
        Calls the C# reader on the connected DTE (through Invoke-TcComRetry: busy / dead RPC retried once, IDE_* classified).
        Returns { ok; reason; error; caption; allCount; flagsRestored; flagsChanged; flagsBefore; ms; errors; warnings; messages }.
        Never throws: an exception of Invoke-TcComRetry (IDE_BUSY, IDE_CRASHED, IDE_MODAL_DIALOG, CALL_DEADLINE_EXCEEDED)
        becomes ok = $false with the text in error, and flagsRestored of the last attempt is kept (review #332 S1).
        Mocked in unit tests.
    .DESCRIPTION
        Retry rule (S1): the flags of the FIRST attempt are passed to every later one, so a retry never reads the user's view
        from a state the helper changed. An attempt that changed the flags and could not put them back is not retried.
    #>
    [CmdletBinding()]
    param([int]$MaxMs)
    $dte = $script:TcDte
    $settle = [int]$script:TcErrorListComSettleMs
    $ctx = @{ orig = $null; last = $null }
    $prevDeadline = $script:TcComCallDeadline
    $mine = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(1000, $MaxMs * 2))
    if ($null -eq $prevDeadline -or $mine -lt [DateTime]$prevDeadline) { $script:TcComCallDeadline = $mine }
    $r = $null
    $thrown = $null
    try {
        $r = Invoke-TcComRetry -MaxRetries 2 -OperationName 'ErrorList.ErrorItems' -ScriptBlock {
            $res = [TcAutomation.ErrorListComReader]::Read($dte, $settle, $MaxMs, [bool[]]$ctx.orig)
            $ctx.last = $res
            if ($null -eq $ctx.orig -and $res.FlagsRead) { $ctx.orig = [bool[]]@($res.FlagsBefore) }
            $kind = Get-TcComRpcFailureKind -Exception ([PSCustomObject]@{ Message = [string]$res.Error; HResult = [int]$res.HResult; InnerException = $null })
            if ($res.Reason -eq 'com-error' -and ($kind.Busy -or $kind.DeadRpc)) {
                # damaged view: never read the flags again, hand the result back as it is
                if ($res.FlagsChanged -and -not $res.FlagsRestored) { return $res }
                # busy / dead RPC reaches Invoke-TcComRetry (retry, IDE_BUSY / IDE_CRASHED)
                throw [System.Runtime.InteropServices.COMException]::new([string]$res.Error, [int]$res.HResult)
            }
            $res
        }
    }
    catch { $thrown = $_ }
    finally { $script:TcComCallDeadline = $prevDeadline }
    $rowsOf = { param($list) @(@($list) | Where-Object { $null -ne $_ }) }
    if ($null -eq $r) {
        $last = $ctx.last
        $msg = if ($null -ne $thrown) { [string]$thrown.Exception.Message } else { 'no result' }
        $restored = $true
        $changed = $false
        if ($null -ne $last) { $restored = [bool]$last.FlagsRestored; $changed = [bool]$last.FlagsChanged }
        return [PSCustomObject]@{
            ok = $false; reason = 'com-error'; error = $msg; caption = ''; allCount = 0
            flagsRestored = $restored; flagsChanged = $changed; flagsBefore = @(if ($null -ne $ctx.orig) { $ctx.orig }); ms = 0
            errors = @(); warnings = @(); messages = @()
        }
    }
    [PSCustomObject]@{
        ok            = [bool]$r.Ok
        reason        = [string]$r.Reason
        error         = [string]$r.Error
        caption       = [string]$r.Caption
        allCount      = [int]$r.AllCount
        flagsRestored = [bool]$r.FlagsRestored
        flagsChanged  = [bool]$r.FlagsChanged
        flagsBefore   = @($r.FlagsBefore)
        ms            = [Math]::Round([double]$r.Ms, 1)
        errors        = & $rowsOf $r.Errors
        warnings      = & $rowsOf $r.Warnings
        messages      = & $rowsOf $r.Messages
    }
}

function Get-TcErrorListViaCom {
    <#
    .SYNOPSIS
        The COM read of the Error List as the data of a Get-TcBuildErrors result.
        Returns { accepted; reason; data; elapsedMs; flagsRestored }: accepted = $true -> data is complete and may be returned
        as is; $false -> reason says why the UIA scan must read instead (data is $null; flagsRestored $false when the user's
        Error List buttons could not be put back).
    .PARAMETER ExpectErrors
        The caller knows the build / check failed (see Get-TcErrorListComVerdict).
    .PARAMETER BuildPaneText
        Build pane text of THIS build (Build-TcProject): cross-checked against the error rows and used for the codes.
        Without it the pane is read here for the codes only (it may belong to an earlier build: matches on file + text).
    .PARAMETER RequireBuildSummary
        The caller decides success from the result (Build-TcProject): accept only with an end summary of -BuildPaneText.
    .PARAMETER MaxMs
        Budget of the whole COM path (compile of the helper, read, pane, codes); checked between steps.
    #>
    [CmdletBinding()]
    param(
        [bool]$IncludeWarnings = $true,
        [bool]$IncludeMessages = $false,
        [int]$MaxMs = 0,
        [switch]$ExpectErrors,
        [AllowNull()][string]$BuildPaneText = $null,
        [switch]$RequireBuildSummary
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $flagsRestored = $true
    $reject = { param([string]$Why) [PSCustomObject]@{ accepted = $false; reason = $Why; data = $null; elapsedMs = [int]$sw.ElapsedMilliseconds; flagsRestored = $flagsRestored } }
    if ($null -eq $script:TcDte) { return (& $reject 'com-unavailable: no DTE connection') }
    if ($MaxMs -le 0) { $MaxMs = [int]$script:TcErrorListComDefaultMaxMs }
    try {
        # a deciding caller needs the summary of THIS build before anything is read (cheap, and no flag is touched without it)
        $paneSummary = $null
        if ($RequireBuildSummary) {
            $paneSummary = ConvertFrom-TcBuildPaneSummary -Text $BuildPaneText
            if (-not $paneSummary.found) {
                return (& $reject 'build-summary-missing: the build pane of this build has no end summary line (Build complete -- N errors / Build: ... failed), so a filtered Error List (search box, column filter) cannot be ruled out')
            }
        }
        $idePid = 0
        if ($null -ne $script:TcIdeProcessId) { try { $idePid = [int]$script:TcIdeProcessId } catch { $idePid = 0 } }
        $ts = Initialize-TcErrorListComTypes -IdeProcessId $idePid
        if (-not $ts.ok) { return (& $reject ([string]$ts.reason)) }
        if ($sw.ElapsedMilliseconds -gt $MaxMs) { return (& $reject "com-budget-exceeded: $([int]$sw.ElapsedMilliseconds) ms used before the read (budget $MaxMs ms)") }

        $dteMajor = $null
        try {
            $ver = [string](Invoke-TcComRetry -MaxRetries 2 -OperationName 'DTE.Version' -ScriptBlock { $script:TcDte.Version })
            if ($ver -match '^(\d+)\.') { $dteMajor = [int]$Matches[1] }
        }
        catch { if (Test-TcComMustRethrow -ErrorRecord $_) { throw } }

        $com = Read-TcErrorListCom -MaxMs ([Math]::Max(500, $MaxMs - [int]$sw.ElapsedMilliseconds))
        if ($null -eq $com) { return (& $reject 'com-read-failed:no result') }
        if ($null -ne $com.PSObject.Properties['flagsRestored']) { $flagsRestored = [bool]$com.flagsRestored }

        $items = @{ Error = [System.Collections.Generic.List[object]]::new(); Warning = [System.Collections.Generic.List[object]]::new(); Message = [System.Collections.Generic.List[object]]::new() }
        $isolatedTotal = 0
        $levelMismatch = 0
        $levelCounts = ''
        if ($com.ok) {
            $isolatedTotal = @($com.errors).Count + @($com.warnings).Count + @($com.messages).Count
            foreach ($r in @($com.errors)) { $items.Error.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Error')) }
            foreach ($r in @($com.warnings)) { $items.Warning.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Warning')) }
            foreach ($r in @($com.messages)) { $items.Message.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Message')) }
            $levelMismatch = Get-TcErrorLevelMismatchCount -DteMajor $dteMajor -ErrorRows $com.errors -WarningRows $com.warnings -MessageRows $com.messages
            $lc = [System.Collections.Generic.List[string]]::new()
            foreach ($pair in @(@('Error', $com.errors), @('Warning', $com.warnings), @('Message', $com.messages))) {
                foreach ($g in @(@($pair[1]) | Group-Object -Property Level | Sort-Object Name)) { $lc.Add("$($pair[0])[level $($g.Name)]=$($g.Count)") }
            }
            $levelCounts = $lc -join ' '
        }

        $freshPane = $false
        $paneLines = $null
        $paneText = $BuildPaneText
        if ($com.ok -and $sw.ElapsedMilliseconds -gt $MaxMs) { return (& $reject "com-budget-exceeded: $([int]$sw.ElapsedMilliseconds) ms used after the read (budget $MaxMs ms)") }
        if ($com.ok -and [string]::IsNullOrWhiteSpace($paneText)) {
            # codes only: the pane may be older than the list, so no count cross-check from it
            try {
                $pr = Invoke-TcComRetry -MaxRetries 2 -OperationName 'Read build output' -ScriptBlock { Get-TcBuildOutputPane }
                if ($null -ne $pr -and [string]$pr.status -eq 'read') { $paneText = [string]$pr.text }
            }
            catch { if (Test-TcComMustRethrow -ErrorRecord $_) { throw } }
        }
        elseif ($com.ok) { $freshPane = $true }
        if (-not [string]::IsNullOrWhiteSpace($paneText)) { $paneLines = ConvertFrom-TcBuildPaneDiagnostics -Text $paneText }

        $verdict = Get-TcErrorListComVerdict -Com $com -ErrorRows $items.Error.Count -LevelMismatchRows $levelMismatch -IsolatedTotal $isolatedTotal `
            -ExpectErrors:$ExpectErrors -PaneLines $(if ($freshPane) { $paneLines } else { $null }) -ErrorItems $items.Error.ToArray() `
            -RequireBuildSummary:$RequireBuildSummary -PaneSummary $paneSummary
        if (-not $verdict.accept) { return (& $reject ([string]$verdict.reason)) }

        # Compiler codes from the build pane (Error and Warning rows); no match -> $null. One index for all rows (S6).
        if ($null -ne $paneLines -and @($paneLines).Count -gt 0) {
            $paneIndex = New-TcPaneLineIndex -PaneLines $paneLines
            foreach ($sev in @('Error', 'Warning')) {
                foreach ($it in $items[$sev]) { $it.code = Resolve-TcErrorItemCode -Item $it -PaneLines $paneLines -Index $paneIndex }
            }
        }
        $unresolvedCodes = @($items.Error | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.code) }).Count

        $counts = [PSCustomObject]@{ errors = $items.Error.Count; warnings = $items.Warning.Count; messages = $items.Message.Count }
        $data = [PSCustomObject]@{
            counts    = $counts
            errors    = $items.Error.ToArray()
            truncated = $false
            source    = 'ErrorList(COM)'
            scope     = [PSCustomObject]@{ before = [string]$com.caption; after = [string]$com.caption; entire = $true; switched = $false }
        }
        if ($IncludeWarnings) { $data | Add-Member -NotePropertyName 'warnings' -NotePropertyValue $items.Warning.ToArray() }
        if ($IncludeMessages) { $data | Add-Member -NotePropertyName 'messages' -NotePropertyValue $items.Message.ToArray() }
        $data | Add-Member -NotePropertyName 'comRead' -NotePropertyValue ([PSCustomObject]@{
                severityBy        = 'ShowFlags'
                levelCheck        = $(if ($null -ne $dteMajor -and $null -ne $script:TcErrorLevelSeverityByDteMajor[$dteMajor]) { 'agreed' } else { 'no-table' })
                levelCounts       = $levelCounts
                dteMajor          = $dteMajor
                readMs            = $com.ms
                rows              = ($items.Error.Count + $items.Warning.Count + $items.Message.Count)
                flagsRestored     = [bool]$com.flagsRestored
                errorsWithoutCode = $unresolvedCodes
                paneCrossCheck    = [bool]$freshPane
                buildSummary      = $(if ($null -ne $paneSummary) { [string]($paneSummary.lines -join ' | ') } else { $null })
                notes             = @($verdict.notes)
            })
        return [PSCustomObject]@{ accepted = $true; reason = $null; data = $data; elapsedMs = [int]$sw.ElapsedMilliseconds; flagsRestored = $flagsRestored }
    }
    catch {
        # IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG from Invoke-TcComRetry: the COM source is not usable now; the UIA
        # scan decides what it can still read (it reports ERRORLIST_UNAVAILABLE when it cannot)
        return (& $reject "com-error: $($_.Exception.Message)")
    }
}
