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
#  - Standalone reads (no pane of THIS build, PR #332 report item 8, 實測 2026-11-24): the search box text made the COM list empty and
#    GetBuildErrors answered success + 0 errors for a list with 6. Such a read is compared with the LAST build summary of the pane
#    (Get-TcErrorListComVerdict -Standalone); 0 rows that nothing proves are not accepted (errors-zero-unverified).
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
#  - Error List window not created yet (review #332 S7, Lance via Dev-G16: "allow creating a hidden tab, readable from
#    the background"): looked up in DTE.Windows; when missing it is created through ToolWindows.ErrorList (no Activate,
#    no SetFocus, never made visible) and read like any other, through the same checks (scope caption, isolation, summary).
#    After the read (flags back first) the window is put back to hidden / auto-hidden and the readback decides:
#    data.comRead.errorListCreated = $true says this read made the tab, errorListHidden = $false says it could not be hidden
#    again (reported as is, 真機未測 2026-11-23). Creation failed -> reason 'errorlist-create-failed', the UIA scan runs.
#  - Deadline (CODING_STANDARDS 1): the read has a cooperative budget (-MaxMs for the fixed work plus 15 ms per fetched row, at
#    most -CapMs; PR #332 real-machine report item 2: 32 rows took 4.7-5.5 s, 202 rows 7.0 s, 529 rows ran out of a flat 7.5 s; rows read
#    before it runs out are kept, marked partial). Checked between COM calls, compile and the
#    pane work included; one COM call that blocks in the IDE (modal dialog) cannot be interrupted, as with
#    Invoke-TcComRetry. Moving it to a background runspace was not done: an abandoned read keeps the user's Show* flags
#    changed (the restore sits in its finally block), which is worse than a late return. Retries are one extra attempt at
#    most and stop at $script:TcComCallDeadline.
#  - File encoding: UTF-8 with BOM (the zh-TW Error List title is still built from code points; the hints of Get-TcErrorListComHint are zh-TW text).

# vsBuildErrorLevel values per IDE host (key = DTE.Version major). 15 = TcXaeShell 15.0 (VS2017 shell); 17.x maps nothing.
$script:TcErrorLevelSeverityByDteMajor = @{
    15 = @{ 4 = 'Error'; 2 = 'Warning'; 1 = 'Message' }
}

# zh-TW pieces as code points (this file stays ASCII)
$script:TcZhErrorListTitle = -join @([char]0x932f, [char]0x8aa4, [char]0x6e05, [char]0x55ae)   # Error List

# Scope part of the Error List window caption (Window.Caption). Entire Solution = the bare window title.
$script:TcErrorListEntireCaptionPattern = '^(Error List|' + $script:TcZhErrorListTitle + ')$'
$script:TcErrorListScopeCaptionPattern = '^(Error List|' + $script:TcZhErrorListTitle + ')\s+-\s+(?<scope>.+)$'

# End summary lines of the build pane (Get-TcBuildOutputPane text of one build):
#   PLC compiler   'Build complete -- 0 errors' (實測, add-semantic-linter verification/xae-corrupt-file-behavior.md)
#   MSBuild / VS   '========== Build: 0 succeeded or up-to-date, 2 failed, 0 skipped ==========' (實測 2026-11-23/24, 4026 XAE + VS2022 + 4024, PR #332 report)
#                  '========== Build: 1 succeeded, 0 failed, 0 up-to-date, 0 skipped ==========' (older VS form, documented)
#   zh-TW VS2022   '========= <Build>: <succeeded-or-up-to-date> 2 <unit>, <Failed> 0 <unit>, <skipped> 0 <unit> ==========' (實測 2026-11-09 / 2026-11-24)
# The MSBuild / VS line is read WITHOUT its words (PR #332 real-machine report item 3: the first pattern wanted 'N succeeded,' and
# did not match 'N succeeded or up-to-date,'): after the '=====' and a label up to the colon (ASCII or full-width), the line is a
# comma list (ASCII or full-width comma) of '<words> N <words>' parts and the SECOND number is the failed count - in every form
# seen (VS 2017-2022 English and zh-TW; the old four-part form also has failed second). Any label counts (Build / Rebuild All /
# Clean): a Clean line of an unrelated action has 0 failed or is a real failure, never a false 'no error'.
$script:TcBuildSummaryPlcPattern = '(?im)^\s*Build complete\s*--\s*(?<e>\d+)\s+errors?\b'
$script:TcBuildSummaryMsbuildPattern = '(?m)^\s*={2,}[^=:\uFF1A\r\n]*[:\uFF1A]\s*[^\d,\uFF0C\r\n]*\d+[^\d,\uFF0C\r\n]*[,\uFF0C]\s*[^\d,\uFF0C\r\n]*(?<f>\d+)'

# Per process: $null (not tried) or @{ ok; reason; at; idePid }. A failure is retried after $script:TcErrorListComRetryAfterSec
# or when another IDE process is connected (review #332 N5).
$script:TcErrorListComTypeState = $null
$script:TcErrorListComRetryAfterSec = 30
$script:TcErrorListComDefaultMaxMs = 10000
$script:TcErrorListComSettleMs = 100
# time each FETCHED row adds to the budget (measured about 12 ms per row on 4026 / VS2022, 2026-11-23, PR #332 report item 2)
$script:TcErrorListComPerRowMs = 15

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
    # saBlock: number of the static analysis section the line is in (0 = before any). See Select-TcCurrentPaneDiagnostics.
    $saBlock = 0
    foreach ($ln in ($Text -split "`n")) {
        $l = $ln.TrimEnd("`r")
        if ($l.Trim() -eq '') { continue }
        if ($l -match $script:TcPaneStaticAnalysisStartPattern) { $saBlock++; continue }
        $m = $rx.Match($l)
        if (-not $m.Success) { continue }
        $out.Add([PSCustomObject]@{
                severity = $(if ($m.Groups['sev'].Value -ieq 'error') { 'Error' } else { 'Warning' })
                file     = $m.Groups['file'].Value.Trim()
                line     = [int]$m.Groups['line'].Value
                code     = $(if ($m.Groups['code'].Success) { $m.Groups['code'].Value.ToUpperInvariant() } else { $null })
                text     = $m.Groups['text'].Value
                saBlock  = $saBlock
            })
    }
    return , $out.ToArray()
}

# Start line of a static analysis section of the PLC compiler in the build pane (English in every UI language seen).
# 實測 2026-11-28 (VS2022 zh-TW + XAE 4026, TE1200 project, one BuildProject): the pane has 'Additional code checks ...' (342 SA error
# lines, 'Additional code checks complete -- 342 errors') and later 'Static analysis...' (190 SA error lines, 'Static analysis complete --
# 190 errors'); the Error List keeps only the 190 rows of the last section. Counting both made 529 pane errors against 190 rows.
$script:TcPaneStaticAnalysisStartPattern = '^\s*(Additional code checks|Static analysis)\s*\.\.\.\s*$'

function Select-TcCurrentPaneDiagnostics {
    <#
    .SYNOPSIS
        The pane lines (ConvertFrom-TcBuildPaneDiagnostics) the Error List can be compared with: every compiler line, but of the static
        analysis lines (code SAxxxx) only those of the LAST static analysis section of the pane.
    .DESCRIPTION
        One build can run the TE1200 checks twice ('Additional code checks ...' while compiling, 'Static analysis...' after it); the Error
        List shows the rows of the last run only (實測 2026-11-28, see $script:TcPaneStaticAnalysisStartPattern). SA lines outside any
        section (saBlock 0) are kept when no section exists. Non-SA lines are never dropped (a compile error is always in the list).
    #>
    [CmdletBinding()]
    param([AllowNull()][object[]]$PaneLines)
    $lines = @($PaneLines | Where-Object { $null -ne $_ })
    $isSa = { param($l) -not [string]::IsNullOrWhiteSpace([string]$l.code) -and ([string]$l.code) -match '^SA\d' }
    $last = 0
    foreach ($l in $lines) {
        if ((& $isSa $l) -and $null -ne $l.PSObject.Properties['saBlock'] -and [int]$l.saBlock -gt $last) { $last = [int]$l.saBlock }
    }
    if ($last -eq 0) { return , $lines }
    return , @($lines | Where-Object { -not (& $isSa $_) -or [int]$_.saBlock -eq $last })
}

function ConvertFrom-TcBuildPaneSummary {
    <#
    .SYNOPSIS
        The end summary of the build pane of ONE build: { found; errors; failedProjects; lines }.
    .DESCRIPTION
        errors          sum of the 'Build complete -- N errors' lines (PLC compiler), $null when there is none
        failedProjects  sum of the failed counts of the MSBuild summary lines (English and zh-TW), $null when there is none
        found           at least one of them. Another UI language of the PLC line / no summary line -> found = $false (not proven).
        -LastOnly       the pane text is not known to be of ONE build (Get-TcErrorListViaCom without -BuildPaneText reads the
                        pane as it is): only the LAST 'Build complete' count and the LAST MSBuild failed count are taken,
                        not the sum of every build in the pane.
        Review #332 M1: the only proof a COM list may stand for "no error" besides the row count itself.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Text, [switch]$LastOnly)
    $errors = $null
    $failed = $null
    $lines = [System.Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace($Text)) {
        foreach ($ln in ($Text -split "`n")) {
            $l = $ln.TrimEnd("`r")
            $m = [regex]::Match($l, $script:TcBuildSummaryPlcPattern)
            if ($m.Success) {
                if ($LastOnly) { $errors = [int]$m.Groups['e'].Value } else { $errors = [int]$errors + [int]$m.Groups['e'].Value }
                $lines.Add($l.Trim()); continue
            }
            $m = [regex]::Match($l, $script:TcBuildSummaryMsbuildPattern)
            if ($m.Success) {
                if ($LastOnly) { $failed = [int]$m.Groups['f'].Value } else { $failed = [int]$failed + [int]$m.Groups['f'].Value }
                $lines.Add($l.Trim())
            }
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
          - it failed (reason com-read-failed:<why>; errorlist-create-failed when the Error List window did not exist and could not be created)
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
    .PARAMETER Standalone
        The caller has no proof of its own and no pane of THIS build (GetBuildErrors called by itself). PR #332 real-machine
        report item 8: with text in the Error List search box the COM list is empty and looked like a clean build
        (success, 0 errors, although 6 existed). COM cannot see that filter, so a standalone read is accepted only when
          - -StaleSummary (the end summary of the LAST build pane, ConvertFrom-TcBuildPaneSummary -LastOnly) does not say more
            errors / failed projects than rows were read (fewer-errors-than-last-build-summary), or
          - it has error rows (a filter can only hide rows; the rows are the lower bound, data.comRead.verifiedBy = 'none' and a note), or
          - something else says 0 is true: the caller (-ZeroErrorsKnown, CheckAllObjects returned True) or a summary that says 0.
        Zero error rows and nothing proving them -> 'errors-zero-unverified', the UIA scan reads (it compares the rows with the
        button totals, which a search text does not change) and reports ERRORLIST_INCOMPLETE / ERRORLIST_UNAVAILABLE instead of a clean 0.
    .PARAMETER StaleSummary
        ConvertFrom-TcBuildPaneSummary -LastOnly of the pane as it is now (it may belong to an earlier build).
    .PARAMETER ZeroErrorsKnown
        The caller knows there is no error (CheckAllObjects returned True): 0 error rows are consistent, not unverified.
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
        [AllowNull()][object]$PaneSummary = $null,
        [switch]$Standalone,
        [AllowNull()][object]$StaleSummary = $null,
        [switch]$ZeroErrorsKnown
    )
    $notes = [System.Collections.Generic.List[string]]::new()
    $flagsOk = $true
    if ($null -ne $Com.PSObject.Properties['flagsRestored']) { $flagsOk = [bool]$Com.flagsRestored }
    $restoreText = 'the Error List Errors / Warnings / Messages buttons could not be set back to their earlier state'
    if ($null -ne $Com.PSObject.Properties['restoreNote'] -and -not [string]::IsNullOrWhiteSpace([string]$Com.restoreNote)) { $restoreText += " ($([string]$Com.restoreNote))" }
    $by = $null
    $verdict = { param([bool]$Accept, [string]$Reason) [PSCustomObject]@{ accept = $Accept; reason = $Reason; notes = $notes.ToArray(); flagsRestored = $flagsOk; verifiedBy = $by } }
    if (-not [bool]$Com.ok) {
        if ([string]$Com.reason -eq 'errorlist-create-failed') { return (& $verdict $false 'errorlist-create-failed') }
        $why = [string]$Com.reason
        if (-not [string]::IsNullOrWhiteSpace([string]$Com.error)) { $why += ": $([string]$Com.error)" }
        if (-not $flagsOk) { $why += "; $restoreText" }
        return (& $verdict $false "com-read-failed:$why")
    }
    if ($null -ne $Com.PSObject.Properties['created'] -and [bool]$Com.created -and $null -ne $Com.PSObject.Properties['hiddenRestored'] -and -not [bool]$Com.hiddenRestored) {
        $notes.Add('the Error List window was created by this read and could not be set back to hidden / auto-hidden (it may be visible)')
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
    if ($ExpectErrors) { $by = 'caller-expects-errors' }
    elseif ($ZeroErrorsKnown -and $ErrorRows -eq 0) { $by = 'caller-confirmed-no-errors' }
    if ($Standalone -and -not $RequireBuildSummary) {
        if ($null -ne $StaleSummary -and [bool]$StaleSummary.found) {
            if ($null -ne $StaleSummary.errors -and [int]$StaleSummary.errors -gt $ErrorRows) {
                return (& $verdict $false "fewer-errors-than-last-build-summary: the last build summary in the build pane says $([int]$StaleSummary.errors) error(s), the COM list has $ErrorRows error row(s) (an Error List search text or column filter hides rows from COM)")
            }
            if ($null -ne $StaleSummary.failedProjects -and [int]$StaleSummary.failedProjects -gt 0 -and $ErrorRows -eq 0) {
                return (& $verdict $false "fewer-errors-than-last-build-summary: the last build summary says $([int]$StaleSummary.failedProjects) project(s) failed, the COM list has no error row (an Error List search text or column filter hides rows from COM)")
            }
            if ($null -eq $by) { $by = 'last-build-summary' }
        }
        elseif ($null -eq $by) {
            if ($ErrorRows -eq 0) {
                return (& $verdict $false 'errors-zero-unverified: the COM list has no error row and nothing proves that it is the whole list (no build summary in the build pane, the caller knows nothing about the build); an Error List search text or column filter shows 0 rows too')
            }
            $by = 'none'
            $notes.Add('no build summary in the build pane to compare with: an Error List search text or column filter cannot be ruled out, the error rows read are a lower bound')
        }
    }
    if ($RequireBuildSummary) {
        $by = 'build-summary'
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
        # static analysis lines of an earlier section of the same build are not in the Error List (Select-TcCurrentPaneDiagnostics)
        $current = Select-TcCurrentPaneDiagnostics -PaneLines $PaneLines
        $dropped = @($PaneLines | Where-Object { $null -ne $_ -and $_.severity -eq 'Error' }).Count - @($current | Where-Object { $_.severity -eq 'Error' }).Count
        if ($dropped -gt 0) { $notes.Add("$dropped static analysis error line(s) of an earlier static analysis section of this build pane were not compared (the Error List keeps the last section only)") }
        $paneErrors = @($current | Where-Object { $_.severity -eq 'Error' }).Count
        if ($paneErrors -gt $ErrorRows) {
            return (& $verdict $false "fewer-errors-than-build-pane: the build pane lists $paneErrors error line(s) (last static analysis section only), the COM list has $ErrorRows error row(s)")
        }
        $unmatched = Get-TcUnmatchedPaneErrorCount -PaneLines $current -ErrorItems $ErrorItems
        if ($unmatched -gt 0) {
            return (& $verdict $false "build-pane-error-not-in-list: $unmatched error line(s) of the build pane have no row with the same file and text in the COM list")
        }
    }
    if (-not $flagsOk) { $notes.Add($restoreText) }
    return (& $verdict $true $null)
}

function Get-TcErrorListComFailureCode {
    <#
    .SYNOPSIS
        Error code of a COM read that was not accepted (Get-TcBuildErrors -Source COM, the default; no UIA fallback):
        ERRORLIST_UNAVAILABLE when the list was not read (COM error, timeout, helper, Error List not creatable),
        ERRORLIST_UNVERIFIED when it was read but is not provably the whole list (filter, summary, isolation).
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Reason)
    $r = [string]$Reason
    if ($r -match '^(com-error|com-read-failed|com-helper-unavailable|com-budget-exceeded|com-unavailable|errorlist-create-failed)') { return 'ERRORLIST_UNAVAILABLE' }
    return 'ERRORLIST_UNVERIFIED'
}

function Get-TcErrorListComHint {
    <#
    .SYNOPSIS
        The next step for a COM read that was not accepted, by its reason (data.comReason). Never asks to click anything in
        the IDE on its own: the user decides; Source=Auto (UIA, brings the IDE window to the front) is named as the opt-in.
    #>
    [CmdletBinding()]
    param([AllowNull()][string]$Reason)
    $r = [string]$Reason
    $uia = 'Source=Auto 會改用 UI Automation 掃 Error List,但會把 IDE 視窗帶到前景，只在使用者同意時用。'
    if ($r -match '^scope-(not-entire|unknown)') { return "Error List 的範圍不是「整個方案」(Entire Solution,data.comReason 有視窗標題):請使用者在 IDE 的 Error List 把範圍選回整個方案再重跑,tcAuto 不會自己切。$uia" }
    if ($r -match '^(fewer-errors-than-last-build-summary|errors-zero-unverified)') { return "單獨讀 Error List 時證明不了是整份清單(搜尋框有字、欄位篩選，或窗格沒有 build 摘要):先跑 BuildProject(用這次 build 的摘要驗證),或請使用者清空 Error List 搜尋框與篩選後重跑 GetBuildErrors。不要把這次結果當成 0 個錯誤。$uia" }
    if ($r -match '^(build-summary-missing|fewer-errors-than-build-summary|fewer-errors-than-build-pane|build-pane-error-not-in-list|expected-errors-none-read)') { return "Error List 的列和這次 build 窗格對不上(data.comReason 有數字):多半是 Error List 搜尋框或欄位篩選藏了列。請使用者清空後重跑 BuildProject;持續出現就把 data.comReason 回報。$uia" }
    if ($r -match '^(severity-isolation-mismatch|error-level-mismatch)') { return 'Error List 在讀取途中變了(build 或 Check 還在寫入?):等 IDE 閒下來再重跑 GetBuildErrors;持續出現就回報 data.comReason。' }
    if ($r -match '^(com-read-failed:timeout|com-budget-exceeded|com-read-failed:count-)') { return "COM 讀取在時限內沒讀完(清單大或 IDE 忙):加大 TimeoutSec(預設 30)或 IncludeWarnings=false 再重跑。data.partial = true 時 data.errors 是已讀到的列，不是整份清單。" }
    if ($r -match '^com-helper-unavailable') { return "COM 讀取元件編譯失敗(找不到 IDE 的 EnvDTE.dll,見 data.comReason):回報這段訊息。$uia" }
    if ($r -match '^errorlist-create-failed') { return "IDE 沒有 Error List 視窗，背景也建不出來：請使用者在 IDE 開一次「檢視 > 錯誤清單」(View > Error List)再重跑。" }
    if ($r -match '^com-read-failed:flags-') { return '切 Error List 的錯誤/警告/訊息按鈕沒有生效(IDE 忙或清單被鎖住):等 IDE 閒下來重跑;data.comFlagsRestored = false 時請使用者看一下這三顆按鈕是否和原本一樣。' }
    return 'COM 呼叫失敗或 IDE 忙(data.comReason):先 GetIdeModalDialog 看有沒有對話框擋著，沒有就稍後重跑 GetBuildErrors。'
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
        Returns { ok; reason; error; caption; allCount; errorCount; warningCount; messageCount; partial; errorsComplete;
        warningsComplete; messagesComplete; flagsRestored; flagsChanged; flagsBefore; flagsAfter; restoreNote; created;
        hiddenRestored; ms; budgetMs; timing; errors; warnings; messages }.
        Never throws: an exception of Invoke-TcComRetry (IDE_BUSY, IDE_CRASHED, IDE_MODAL_DIALOG, CALL_DEADLINE_EXCEEDED)
        becomes ok = $false with the text in error, and flagsRestored of the last attempt is kept (review #332 S1).
        Mocked in unit tests.
    .DESCRIPTION
        Retry rule (S1): the flags of the FIRST attempt are passed to every later one, so a retry never reads the user's view
        from a state the helper changed. An attempt that changed the flags and could not put them back is not retried.
        Budget: -MaxMs covers the fixed work (flags, polls); every row that is fetched adds its own time up to -CapMs
        (PR #332 real-machine report item 2: 529 rows need more than a flat 7.5 s). A read that runs out of time keeps the rows
        it has (partial = $true, errors / warnings / messages hold them), it never answers with an empty list.
        -FetchWarnings:$false / -FetchMessages:$false: those rows are only counted (the count still enters the isolation sum).
        -ReadLevel:$false: ErrorItem.ErrorLevel is not read (hosts without a level table, one COM call less per row).
    #>
    [CmdletBinding()]
    param(
        [int]$MaxMs,
        [int]$CapMs = 0,
        [bool]$FetchWarnings = $true,
        [bool]$FetchMessages = $true,
        [bool]$ReadLevel = $true
    )
    $dte = $script:TcDte
    $settle = [int]$script:TcErrorListComSettleMs
    $perRowMs = [int]$script:TcErrorListComPerRowMs
    $cap = [Math]::Max($MaxMs, $CapMs)
    $opts = [TcAutomation.ErrorListComOptions]::new()
    $opts.SettleMs = $settle
    $opts.MaxMs = $MaxMs
    $opts.CapMs = $cap
    $opts.PerRowMs = $perRowMs
    $opts.FetchWarnings = $FetchWarnings
    $opts.FetchMessages = $FetchMessages
    $opts.ReadLevel = $ReadLevel
    $ctx = @{ orig = $null; last = $null; created = $false; hiddenOk = $true }
    $prevDeadline = $script:TcComCallDeadline
    $mine = [DateTime]::UtcNow.AddMilliseconds([Math]::Max(1000, $cap * 2))
    if ($null -eq $prevDeadline -or $mine -lt [DateTime]$prevDeadline) { $script:TcComCallDeadline = $mine }
    $r = $null
    $thrown = $null
    try {
        $r = Invoke-TcComRetry -MaxRetries 2 -OperationName 'ErrorList.ErrorItems' -ScriptBlock {
            $res = [TcAutomation.ErrorListComReader]::Read($dte, $opts, [bool[]]$ctx.orig)
            $ctx.last = $res
            # a retry finds the window the first attempt created (hidden again): the creation is not lost
            if ($res.Created) { $ctx.created = $true }
            if (-not $res.HiddenRestored) { $ctx.hiddenOk = $false }
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
            errorCount = -1; warningCount = -1; messageCount = -1
            partial = $false; errorsComplete = $false; warningsComplete = $false; messagesComplete = $false
            flagsRestored = $restored; flagsChanged = $changed; flagsBefore = @(if ($null -ne $ctx.orig) { $ctx.orig }); flagsAfter = @(); restoreNote = ''
            ms = 0; budgetMs = $cap; timing = ''
            created = [bool]$ctx.created; hiddenRestored = [bool]$ctx.hiddenOk
            errors = @(); warnings = @(); messages = @()
        }
    }
    [PSCustomObject]@{
        ok            = [bool]$r.Ok
        reason        = [string]$r.Reason
        error         = [string]$r.Error
        caption       = [string]$r.Caption
        allCount      = [int]$r.AllCount
        errorCount    = [int]$r.ErrorCount
        warningCount  = [int]$r.WarningCount
        messageCount  = [int]$r.MessageCount
        partial       = [bool]$r.Partial
        errorsComplete   = [bool]$r.ErrorsComplete
        warningsComplete = [bool]$r.WarningsComplete
        messagesComplete = [bool]$r.MessagesComplete
        flagsRestored = [bool]$r.FlagsRestored
        flagsChanged  = [bool]$r.FlagsChanged
        flagsBefore   = @($r.FlagsBefore)
        flagsAfter    = @($r.FlagsAfter)
        restoreNote   = [string]$r.RestoreNote
        created       = [bool]($ctx.created -or $r.Created)
        hiddenRestored = [bool]($ctx.hiddenOk -and $r.HiddenRestored)
        ms            = [Math]::Round([double]$r.Ms, 1)
        budgetMs      = [int]$r.BudgetMs
        timing        = [string]$r.Timing
        errors        = & $rowsOf $r.Errors
        warnings      = & $rowsOf $r.Warnings
        messages      = & $rowsOf $r.Messages
    }
}

function Get-TcErrorListViaCom {
    <#
    .SYNOPSIS
        The COM read of the Error List as the data of a Get-TcBuildErrors result.
        Returns { accepted; reason; data; partial; elapsedMs; flagsRestored; errorListCreated; errorListHidden }: accepted = $true
        -> data is complete and may be returned as is; $false -> reason says why the UIA scan must read instead (data is $null;
        flagsRestored $false when the user's Error List buttons could not be put back). partial = the rows a COM read that did
        not finish had read (errors / warnings / messages / counts / *Complete / reason), $null when none: the caller shows
        them if the UIA scan cannot do better, marked partial. errorListCreated = this read created the Error List tab;
        errorListHidden = $false when that new tab could not be hidden / auto-hidden again (also on rejections).
    .PARAMETER ExpectErrors
        The caller knows the build / check failed (see Get-TcErrorListComVerdict).
    .PARAMETER ZeroErrorsKnown
        The caller knows there is no error (CheckAllObjects returned True): 0 error rows need no further proof.
    .PARAMETER BuildPaneText
        Build pane text of THIS build (Build-TcProject): cross-checked against the error rows and used for the codes.
        Without it the pane is read here for the codes and for the standalone check (the pane may belong to an earlier build:
        matches on file + text, the last summary only, see Get-TcErrorListComVerdict -Standalone).
    .PARAMETER RequireBuildSummary
        The caller decides success from the result (Build-TcProject): accept only with an end summary of -BuildPaneText.
    .PARAMETER MaxMs
        Budget of the fixed work of the COM path (compile of the helper, flags, polls, pane); checked between steps.
    .PARAMETER CapMs
        Hard cap of the whole COM path including the time each fetched row adds (default = MaxMs: no extension).
    #>
    [CmdletBinding()]
    param(
        [bool]$IncludeWarnings = $true,
        [bool]$IncludeMessages = $false,
        [int]$MaxMs = 0,
        [int]$CapMs = 0,
        [switch]$ExpectErrors,
        [switch]$ZeroErrorsKnown,
        [AllowNull()][string]$BuildPaneText = $null,
        [switch]$RequireBuildSummary
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $flagsRestored = $true
    $errorListCreated = $false
    $errorListHidden = $true
    $partial = $null
    $reject = { param([string]$Why) [PSCustomObject]@{ accepted = $false; reason = $Why; data = $null; partial = $partial; elapsedMs = [int]$sw.ElapsedMilliseconds; flagsRestored = $flagsRestored; errorListCreated = $errorListCreated; errorListHidden = $errorListHidden } }
    if ($null -eq $script:TcDte) { return (& $reject 'com-unavailable: no DTE connection') }
    if ($MaxMs -le 0) { $MaxMs = [int]$script:TcErrorListComDefaultMaxMs }
    $capEff = [Math]::Max($MaxMs, $CapMs)
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
        if ($sw.ElapsedMilliseconds -gt $capEff) { return (& $reject "com-budget-exceeded: $([int]$sw.ElapsedMilliseconds) ms used before the read (budget $capEff ms)") }

        $dteMajor = $null
        try {
            $ver = [string](Invoke-TcComRetry -MaxRetries 2 -OperationName 'DTE.Version' -ScriptBlock { $script:TcDte.Version })
            if ($ver -match '^(\d+)\.') { $dteMajor = [int]$Matches[1] }
        }
        catch { if (Test-TcComMustRethrow -ErrorRecord $_) { throw } }
        # ErrorLevel only where the host has a level table (it is the cross-check there); one COM call less per row elsewhere
        $readLevel = ($null -ne $dteMajor -and $null -ne $script:TcErrorLevelSeverityByDteMajor[$dteMajor])

        $com = Read-TcErrorListCom -MaxMs ([Math]::Max(500, $MaxMs - [int]$sw.ElapsedMilliseconds)) -CapMs ([Math]::Max(500, $capEff - [int]$sw.ElapsedMilliseconds)) `
            -FetchWarnings $IncludeWarnings -FetchMessages $IncludeMessages -ReadLevel $readLevel
        if ($null -eq $com) { return (& $reject 'com-read-failed:no result') }
        if ($null -ne $com.PSObject.Properties['flagsRestored']) { $flagsRestored = [bool]$com.flagsRestored }
        if ($null -ne $com.PSObject.Properties['created']) { $errorListCreated = [bool]$com.created }
        if ($null -ne $com.PSObject.Properties['hiddenRestored']) { $errorListHidden = [bool]$com.hiddenRestored }

        $items = @{ Error = [System.Collections.Generic.List[object]]::new(); Warning = [System.Collections.Generic.List[object]]::new(); Message = [System.Collections.Generic.List[object]]::new() }
        foreach ($r in @($com.errors)) { $items.Error.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Error')) }
        foreach ($r in @($com.warnings)) { $items.Warning.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Warning')) }
        foreach ($r in @($com.messages)) { $items.Message.Add((ConvertTo-TcErrorListComItem -Row $r -Severity 'Message')) }
        if (-not $com.ok -and $items.Error.Count + $items.Warning.Count + $items.Message.Count -gt 0) {
            # the read did not finish: what it read is kept, marked partial (never an empty list that hides it)
            $partial = [PSCustomObject]@{
                reason           = [string]$com.reason
                errors           = $items.Error.ToArray()
                warnings         = $items.Warning.ToArray()
                messages         = $items.Message.ToArray()
                errorsComplete   = [bool]$com.errorsComplete
                warningsComplete = [bool]$com.warningsComplete
                messagesComplete = [bool]$com.messagesComplete
                expected         = [PSCustomObject]@{ errors = $(if ([int]$com.errorCount -ge 0) { [int]$com.errorCount } else { $null }); warnings = $(if ([int]$com.warningCount -ge 0) { [int]$com.warningCount } else { $null }); messages = $(if ([int]$com.messageCount -ge 0) { [int]$com.messageCount } else { $null }) }
                readMs           = $com.ms
                timing           = [string]$com.timing
            }
        }
        $isolatedTotal = 0
        $levelMismatch = 0
        $levelCounts = 'not-read'
        if ($com.ok) {
            $isolatedTotal = [int]$com.errorCount + [int]$com.warningCount + [int]$com.messageCount
            if ($readLevel) {
                $levelMismatch = Get-TcErrorLevelMismatchCount -DteMajor $dteMajor -ErrorRows $com.errors -WarningRows $com.warnings -MessageRows $com.messages
                $lc = [System.Collections.Generic.List[string]]::new()
                foreach ($pair in @(@('Error', $com.errors), @('Warning', $com.warnings), @('Message', $com.messages))) {
                    foreach ($g in @(@($pair[1]) | Group-Object -Property Level | Sort-Object Name)) { $lc.Add("$($pair[0])[level $($g.Name)]=$($g.Count)") }
                }
                $levelCounts = $lc -join ' '
            }
        }

        $freshPane = $false
        $paneLines = $null
        $paneText = $BuildPaneText
        if ($com.ok -and $sw.ElapsedMilliseconds -gt $capEff) { return (& $reject "com-budget-exceeded: $([int]$sw.ElapsedMilliseconds) ms used after the read (budget $capEff ms)") }
        if ($com.ok -and [string]::IsNullOrWhiteSpace($paneText)) {
            # codes and the standalone check: the pane may be older than the list, so no count cross-check from its lines
            try {
                $pr = Invoke-TcComRetry -MaxRetries 2 -OperationName 'Read build output' -ScriptBlock { Get-TcBuildOutputPane }
                if ($null -ne $pr -and [string]$pr.status -eq 'read') { $paneText = [string]$pr.text }
            }
            catch { if (Test-TcComMustRethrow -ErrorRecord $_) { throw } }
        }
        elseif ($com.ok) { $freshPane = $true }
        if (-not [string]::IsNullOrWhiteSpace($paneText)) { $paneLines = ConvertFrom-TcBuildPaneDiagnostics -Text $paneText }
        # PR #332 report item 8: a read of GetBuildErrors by itself has no pane of THIS build; the last summary of the pane is
        # the only thing that can show rows hidden by a search text (Get-TcErrorListComVerdict -Standalone)
        $standalone = ($com.ok -and -not $freshPane)
        $staleSummary = $null
        if ($standalone) { $staleSummary = ConvertFrom-TcBuildPaneSummary -Text $paneText -LastOnly }

        $verdict = Get-TcErrorListComVerdict -Com $com -ErrorRows ([int]$com.errorCount) -LevelMismatchRows $levelMismatch -IsolatedTotal $isolatedTotal `
            -ExpectErrors:$ExpectErrors -PaneLines $(if ($freshPane) { $paneLines } else { $null }) -ErrorItems $items.Error.ToArray() `
            -RequireBuildSummary:$RequireBuildSummary -PaneSummary $paneSummary `
            -Standalone:$standalone -StaleSummary $staleSummary -ZeroErrorsKnown:$ZeroErrorsKnown
        if (-not $verdict.accept) { return (& $reject ([string]$verdict.reason)) }

        # Compiler codes from the build pane (Error and Warning rows); no match -> $null. One index for all rows (S6).
        if ($null -ne $paneLines -and @($paneLines).Count -gt 0) {
            $paneIndex = New-TcPaneLineIndex -PaneLines $paneLines
            foreach ($sev in @('Error', 'Warning')) {
                foreach ($it in $items[$sev]) { $it.code = Resolve-TcErrorItemCode -Item $it -PaneLines $paneLines -Index $paneIndex }
            }
        }
        $unresolvedCodes = @($items.Error | Where-Object { [string]::IsNullOrWhiteSpace([string]$_.code) }).Count

        $counts = [PSCustomObject]@{ errors = [int]$com.errorCount; warnings = [int]$com.warningCount; messages = [int]$com.messageCount }
        $data = [PSCustomObject]@{
            counts    = $counts
            errors    = $items.Error.ToArray()
            truncated = $false
            source    = 'ErrorList(COM)'
            scope     = [PSCustomObject]@{ before = [string]$com.caption; after = [string]$com.caption; entire = $true; switched = $false }
        }
        if ($IncludeWarnings) { $data | Add-Member -NotePropertyName 'warnings' -NotePropertyValue $items.Warning.ToArray() }
        if ($IncludeMessages) { $data | Add-Member -NotePropertyName 'messages' -NotePropertyValue $items.Message.ToArray() }
        $notes = [System.Collections.Generic.List[string]]::new()
        foreach ($n in @($verdict.notes)) { $notes.Add([string]$n) }
        if ($errorListCreated -and $errorListHidden) { $notes.Add('the Error List window did not exist: this read created it and put it back to hidden / auto-hidden (read back); the IDE window list was changed, the visible layout is as before') }
        $data | Add-Member -NotePropertyName 'comRead' -NotePropertyValue ([PSCustomObject]@{
                severityBy        = 'ShowFlags'
                levelCheck        = $(if ($readLevel) { 'agreed' } else { 'no-table' })
                levelCounts       = $levelCounts
                dteMajor          = $dteMajor
                readMs            = $com.ms
                budgetMs          = [int]$com.budgetMs
                timing            = [string]$com.timing
                rows              = ($items.Error.Count + $items.Warning.Count + $items.Message.Count)
                flagsRestored     = [bool]$com.flagsRestored
                errorListCreated  = $errorListCreated
                errorListHidden   = $errorListHidden
                layoutChanged     = $errorListCreated
                verifiedBy        = [string]$verdict.verifiedBy
                errorsWithoutCode = $unresolvedCodes
                paneCrossCheck    = [bool]$freshPane
                buildSummary      = $(if ($null -ne $paneSummary) { [string]($paneSummary.lines -join ' | ') } elseif ($null -ne $staleSummary) { [string]($staleSummary.lines -join ' | ') } else { $null })
                notes             = $notes.ToArray()
            })
        return [PSCustomObject]@{ accepted = $true; reason = $null; data = $data; partial = $null; elapsedMs = [int]$sw.ElapsedMilliseconds; flagsRestored = $flagsRestored; errorListCreated = $errorListCreated; errorListHidden = $errorListHidden }
    }
    catch {
        # IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG from Invoke-TcComRetry: the COM source is not usable now; the UIA
        # scan decides what it can still read (it reports ERRORLIST_UNAVAILABLE when it cannot)
        return (& $reject "com-error: $($_.Exception.Message)")
    }
}
