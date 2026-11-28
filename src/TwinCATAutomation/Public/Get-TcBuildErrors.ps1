function Get-TcBuildErrors {
    <#
    .SYNOPSIS
        Reads the compiler messages of the IDE "Error List" (errors, and optionally warnings /
        messages) through COM (DTE2 ErrorList.ErrorItems). UI Automation only on request (-Source Auto / UIA).
    .DESCRIPTION
        Source 1, COM (data.source 'ErrorList(COM)'; item 88, re #320 / #329 / #300): the Error List
        of the connected IDE is read with an early-bound C# helper (ErrorListComReader.cs; PowerShell
        late binding reads a fake 0, 實測 2026-11-23). It needs no visible window and no foreground and
        takes about 2 ms per row (529 rows 0.96 s; the UIA scan timed out on the same list, #329). The
        Errors / Warnings / Messages buttons are set on for the read (ShowErrors / ShowWarnings /
        ShowMessages) and put back afterwards. The result is accepted only when it is provably the whole
        list (fail closed: a filtered Error List answers 0 rows without an error); a rejected read is ERRORLIST_UNVERIFIED /
        ERRORLIST_UNAVAILABLE with data.comReason (Source Auto, opt-in: the UIA scan reads instead):
          - the Error List window caption is the bare title (Entire Solution); 'Error List - Current
            Project (X)' / '- Current Document' / '- Open Documents' or an unknown caption -> rejected
          - severity: every host by reading one Show* flag at a time (each read after an all-off step that must
            show 0 rows); the three reads must add up to the all-flags count. 4024 (TcXaeShell 15.0, ErrorLevel
            error 4 / warning 2 / message 1 = High / Medium / Low, vsBuildErrorLevel) also cross-checks every row's
            level against its flag; 4026 (ErrorLevel is 2 for every row) has no such table
          - -ExpectErrors (the build / check failed) and no error row read -> rejected
          - -BuildPaneText (the pane of this build): more error lines there than error rows, or an error line without a
            row of the same file and text -> rejected
          - -RequireBuildSummary (callers that decide success from the list): no end summary line in the pane of this
            build ('Build complete -- N errors' / MSBuild 'Build: .. failed'), or fewer error rows than it says -> rejected.
            COM cannot see the Error List search box or column filters; the summary is what rules a filtered list out
          - the Error List window does not exist and could not be created ('errorlist-create-failed'): ERRORLIST_UNAVAILABLE
            (a missing window is created hidden through ToolWindows.ErrorList, never activated: data.comRead.errorListCreated)
          - nothing proves the list is not filtered (PR #332 report item 8: text in the Error List search box shows 0 rows to COM,
            it looked like a clean build): a standalone read (no -BuildPaneText) is compared with the LAST build summary of the
            build pane; more errors / failed projects there than rows read -> 'fewer-errors-than-last-build-summary', and 0 error
            rows with no summary and no -ZeroErrorsKnown -> 'errors-zero-unverified'. Both are ERRORLIST_UNVERIFIED (Source Auto: the
            UIA scan compares the rows with the button totals); never success with 0 errors that nothing proves
        Budget, measured 2026-11-28 (VS2022, hidden IDE, 215 rows): the time goes into the IDE refiltering the list after each
        Show* flag change (400-550 ms, paid by the first ErrorItems.Count after it); Count itself, the flag writes and the row reads
        are a few ms each (data.comRead.timing: refilters / refilterMs).
        The compiler code (Cxxxx / SAxxxx) is not in the COM description: it is taken from the build
        pane line with the same file and text, else $null. file / project / line have the UIA form
        (file = base name + ' (Impl)' / ' (Decl)' as the grid shows it, project = project name, line =
        the Error List line, column = $null; data.errors[].filePath = the full path).
        Source 2, UI Automation (data.source 'ErrorList(UIA)'; data.fallbackReason says why COM was not
        used). The TwinCAT PLC compiler does not report through DTE when read with late binding, so the
        Error List tool window of the XAE is scanned. The scan never shows, activates or restores a window
        (PR #332 real-machine report item 4: View.ErrorList restored a minimized VS2022 and took the
        foreground; it is no longer run): the Error List must already be on screen in the IDE, otherwise the
        result is ERRORLIST_UNAVAILABLE ('open View > Error List once'). A UI Automation scan (separate STA
        runspace, hard -TimeoutSec) reads
          - the summary buttons ("9 Errors", "8 Warnings", "0 of 10 Messages") -> counts
          - every row of the (virtualised) grid, scrolling page by page, de-duplicated
            on description+project+file+line.
        Severity is isolated by toggling the summary buttons one at a time (the row icon
        has no readable name); the original button states are restored afterwards.
        The TwinCAT error code (Cxxxx / SAxxxx) is parsed from the description when it
        is part of it; the IDE's own "Code" column is used when that column is shown.
        Requires the IDE process id stored by Connect-TcIde and a visible Error List
        (not auto-hidden, not closed); otherwise ERRORLIST_UNAVAILABLE is returned.
        English and zh-TW VS2022 UIs are recognised (pane name / count button labels
        such as "0 / 2" + the localized word; the total is reported). The scope filter is
        read from the scope ComboBox's own selection (also while it is collapsed, #117); when it
        is not "Entire Solution" ("Current Project" / "Current Document" / "Open Documents") the
        scan switches it to "Entire Solution" first (leaves it switched) and reads it back.
        Readback: when fewer rows are read than the summary buttons count, or the scope could not
        be switched, the result is ERRORLIST_INCOMPLETE, never success with a partial list.
    .PARAMETER IncludeWarnings
        Default on; -IncludeWarnings:$false skips the warning toggle (saves 1-2 s of UIA).
        Also reads warning rows (data.warnings, always present when on, possibly empty).
    .PARAMETER IncludeMessages
        Also read message rows (data.messages).
    .PARAMETER TimeoutSec
        Limit for the whole call. Source COM (default): all of it goes to the COM read (fixed work and rows; 529 rows took 5.1-5.7 s,
        PR #332 round 3). Source Auto: the COM path gets a quarter of it (8 s at most) for the fixed work (compile, flags, pane,
        codes; checked between COM calls) plus time for every row it fetches, in all at most 60 % of it (18 s of the
        default 30: 529 rows need more than a flat 7.5 s, PR #332 report item 2); the UI Automation scan gets what is
        left (at least 1 s),
        including the one-time preparation of its helper types (the first call in a process). The UIA scan is hard;
        one COM call that blocks inside the IDE (modal dialog) cannot be interrupted, the same limit as
        Invoke-TcComRetry (it runs under its modal-dialog watchdog). Default 30.
    .PARAMETER Source
        COM (default): the COM read only. When it cannot be accepted the result is ERRORLIST_UNVERIFIED (read, but not provably the
        whole list: search box text, scope filter, fewer rows than the build summary, 0 rows nothing proves, severities not isolated)
        or ERRORLIST_UNAVAILABLE (not read: COM error, timeout, helper not compiled, Error List not creatable), with data.comReason,
        data.uiaFallback = 'off' and a hint for that reason; the rows a COM read that stopped early had read stay in data (partial).
        No window is touched (PR #332 round 3: every UI Automation fallback brought a minimized or covered IDE to the front).
        Auto (opt-in): COM first, the UI Automation scan when the COM read cannot be accepted (old behaviour; it can bring the
        IDE window to the front). UIA: UI Automation only (diagnosis; the COM read is skipped; same foreground effect).
    .PARAMETER ExpectErrors
        The caller knows the build / check failed (LastBuildInfo > 0, CheckAllObjects False): a COM list
        without any error row is then not accepted (ERRORLIST_UNVERIFIED; Source Auto: the UIA scan reads).
    .PARAMETER ZeroErrorsKnown
        Internal (Test-TcPlcProject passes it when CheckAllObjects returned True; not an MCP parameter): the caller knows there
        is no error, so a COM list with no error row is consistent and needs no build summary.
    .PARAMETER BuildPaneText
        Internal (Build-TcProject passes it; not an MCP parameter): the build pane text of the build that was
        just run. The COM read is cross-checked against its error lines and takes the compiler codes from it.
        Without it the pane is only used for the codes.
    .PARAMETER RequireBuildSummary
        Internal (Build-TcProject passes it; not an MCP parameter): the result decides success, so a COM list is
        accepted only when -BuildPaneText has an end summary line (see .DESCRIPTION). Without it COM is not used.
    .OUTPUTS
        data.counts      @{ errors; warnings; messages } from the summary buttons
        data.errors      [ @{ severity; code; description; project; file; line; column } ]
        data.warnings    same shape, present unless -IncludeWarnings:$false (may be empty)
        data.messages    same shape, only with -IncludeMessages
        data.truncated   $true when not every row could be read (no ScrollPattern / cap)
        data.source      'ErrorList(COM)' or 'ErrorList(UIA)'
        data.fallbackReason  only on a UIA result after a COM attempt (failures included): why COM was not used, e.g.
                         'scope-not-entire: ...', 'scope-unknown: ...', 'expected-errors-none-read: ...',
                         'build-summary-missing: ...', 'fewer-errors-than-build-summary: ...',
                         'fewer-errors-than-build-pane: ...', 'build-pane-error-not-in-list: ...',
                         'severity-isolation-mismatch: ...', 'error-level-mismatch: ...', 'errorlist-create-failed',
                         'com-read-failed:<why>', 'com-helper-unavailable: ...', 'com-budget-exceeded: ...', 'com-error: ...'
        data.comFlagsRestored  $false (only then present) on a UIA result: the COM read changed the Error List Errors /
                         Warnings / Messages buttons and could not put them back
        data.comErrorListCreated  $true (only then present) on a UIA result: the COM attempt created the Error List tab
        data.comErrorListHidden   $false (only then present) on a UIA result: that new tab could not be hidden again
        data.comRead     COM results only: severityBy ('ShowFlags'), levelCheck, levelCounts ('not-read' on hosts without a level
                         table), dteMajor, readMs, budgetMs, timing (flagSets / counts / rows / sleeps with their ms: where the
                         read time went), rows, flagsRestored (the three buttons read back equal, twice), errorListCreated (this
                         read created the hidden Error List tab), errorListHidden ($false = the new tab could not be hidden /
                         auto-hidden again, reported as is), layoutChanged (= errorListCreated: this read changed the IDE's
                         window list), verifiedBy ('build-summary' | 'last-build-summary' | 'caller-expects-errors' |
                         'caller-confirmed-no-errors' | 'none' = error rows read but nothing to compare with, see notes),
                         errorsWithoutCode (error rows whose code the build pane could not give), paneCrossCheck, buildSummary, notes
        data.partial     $true on a FAILED result (never on success) when the COM read stopped before the end and its rows are
                         shown here: data.errors / warnings / messages hold the rows read so far, data.truncated = $true,
                         data.source = 'ErrorList(COM)', data.partialRead = @{ reason; errorsComplete; warningsComplete;
                         messagesComplete; expected; readMs; timing }. The rows are NOT the whole list: never read them as 0 errors
                         or as complete (the result is success = $false)
        data.severityUnknown  $true when the rows could not be assigned a severity (the
                         filter buttons were not toggleable and more than one is on);
                         those rows are then in data.unclassified, NOT in data.errors
        data.unclassified  rows of unknown severity (only when there are any)
        ERRORLIST_UNAVAILABLE is also returned when the previous scan has not finished
        yet (timed-out UIA thread still running; $script:TcErrorListScanBusy).
        data.scanMayBeRunning    $true (with scanBusy = $false) when a dropped leftover scan may still be running:
                         this call starts no new scan (ERRORLIST_UNAVAILABLE), the next call scans (#75)
        data.scanCleanupWarning  set when leftover timed-out scans could not be inspected /
                         disposed and were dropped instead (#75); on success and failure results
        data.scope       @{ before; after; entire; switched }: the scope filter read from the scope
                         ComboBox's own selection (#117); entire = $null when no scope combo was recognised
        ERRORLIST_INCOMPLETE (#117): fewer rows were read than the summary buttons count (per requested
                         severity), or the scope stayed on another filter than Entire Solution; data then
                         carries the partial rows, data.incomplete = $true, data.missingRows
                         [ @{ severity; expected; read } ], data.errorsTotalUnknown, data.scope and data.notes.
                         Never success with a partial list (callers decide with Get-TcErrorListReadState
                         whether the ERROR rows are complete anyway, #138).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeWarnings = $true,

        [Parameter()]
        [switch]$IncludeMessages,

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 30,

        [Parameter()]
        [ValidateSet('COM', 'Auto', 'UIA')]
        [string]$Source = 'COM',

        [Parameter()]
        [switch]$ExpectErrors,

        [Parameter()]
        [switch]$ZeroErrorsKnown,

        [Parameter()]
        [string]$BuildPaneText,

        [Parameter()]
        [switch]$RequireBuildSummary
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $idePid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $idePid = [int]$script:TcIdeProcessId } catch { $idePid = 0 } }
    if ($idePid -le 0) {
        return New-TcResult -Success $false `
            -ErrorMessage 'IDE process id unknown (Connect-TcIde could not determine it); the Error List cannot be located.' `
            -ErrorCode 'NOT_CONNECTED' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED')
    }
    if ($null -eq (Get-Process -Id $idePid -ErrorAction SilentlyContinue)) {
        return New-TcResult -Success $false -ErrorMessage "IDE process $idePid no longer exists." -ErrorCode 'NOT_CONNECTED' `
            -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED')
    }

    # A previous scan that timed out may still be stuck inside UIA on its STA thread;
    # a second scan would compete for the same window (and toggle the same buttons). The COM read toggles the same
    # Show* flags, so this guard comes BEFORE it (review #332 S2).
    $comFallbackReason = $null
    $comFlagsNotRestored = $false
    $comCreated = $false
    $comNotHidden = $false
    $comPartial = $null
    # A COM read that stopped before the end (timeout, count kept changing) keeps its rows. When the UIA scan cannot read the
    # list either, they are returned marked partial / truncated on the FAILED result - never an empty list, never success.
    # A UIA result that has rows of its own keeps them; the COM rows only add data.comPartial then.
    $addPartial = {
        param($Data, [bool]$Promote)
        if ($null -eq $comPartial) { return }
        $Data | Add-Member -NotePropertyName 'comPartial' -NotePropertyValue $comPartial -Force
        if ($Promote) {
            $Data | Add-Member -NotePropertyName 'partial' -NotePropertyValue $true -Force
            $Data | Add-Member -NotePropertyName 'truncated' -NotePropertyValue $true -Force
            $Data | Add-Member -NotePropertyName 'source' -NotePropertyValue 'ErrorList(COM)' -Force
            $Data | Add-Member -NotePropertyName 'errors' -NotePropertyValue @($comPartial.errors) -Force
            if ($IncludeWarnings) { $Data | Add-Member -NotePropertyName 'warnings' -NotePropertyValue @($comPartial.warnings) -Force }
            if ($IncludeMessages) { $Data | Add-Member -NotePropertyName 'messages' -NotePropertyValue @($comPartial.messages) -Force }
            $Data | Add-Member -NotePropertyName 'partialRead' -NotePropertyValue ([PSCustomObject]@{
                    reason = $comPartial.reason; errorsComplete = $comPartial.errorsComplete; warningsComplete = $comPartial.warningsComplete
                    messagesComplete = $comPartial.messagesComplete; expected = $comPartial.expected; readMs = $comPartial.readMs; timing = $comPartial.timing
                }) -Force
        }
    }
    $partialText = {
        param([string]$Message)
        if ($null -eq $comPartial) { return $Message }
        $n = @($comPartial.errors).Count
        return "$Message The COM read stopped early ($([string]$comPartial.reason)) after $n error row(s) / $(@($comPartial.warnings).Count) warning row(s): they are in data.errors / data.warnings with partial = true, truncated = true. They are NOT the whole list: do not read them as complete or as 0 errors."
    }
    $addFallback = {
        param($Data)
        if ($null -ne $comFallbackReason) { $Data | Add-Member -NotePropertyName 'fallbackReason' -NotePropertyValue $comFallbackReason -Force }
        if ($comFlagsNotRestored) { $Data | Add-Member -NotePropertyName 'comFlagsRestored' -NotePropertyValue $false -Force }
        if ($comCreated) { $Data | Add-Member -NotePropertyName 'comErrorListCreated' -NotePropertyValue $true -Force }
        if ($comNotHidden) { $Data | Add-Member -NotePropertyName 'comErrorListHidden' -NotePropertyValue $false -Force }
    }
    $cleanupWarning = $null
    if ($script:TcErrorListScanBusy) {
        $stillRunning = Clear-TcUiaAbandonedScans
        $cleanupWarning = $script:TcUiaCleanupWarning
        if ($stillRunning -gt 0) {
            $busyData = [PSCustomObject]@{ ideProcessId = $idePid; source = 'ErrorList(UIA)'; scanBusy = $true }
            & $addFallback $busyData
            if ($null -ne $cleanupWarning) { $busyData | Add-Member -NotePropertyName 'scanCleanupWarning' -NotePropertyValue $cleanupWarning }
            return New-TcResult -Success $false `
                -ErrorMessage "ERRORLIST_UNAVAILABLE: the previous Error List scan has not finished yet ($stillRunning UIA thread(s) still running after a timeout); retry later or reconnect the IDE." `
                -ErrorCode 'ERRORLIST_UNAVAILABLE' -Hint (Get-TcErrorHint -Code 'ERRORLIST_UNAVAILABLE') `
                -Data $busyData
        }
        if ($script:TcUiaCleanupMayBeRunning) {
            # A dropped entry may still be running its UIA thread. Scanning now could race it for
            # the filter buttons and read a list with the Errors filter off (errors = 0 on a failed
            # build, a false success). Refuse this call; the next one scans (#75).
            $mayData = [PSCustomObject]@{ ideProcessId = $idePid; source = 'ErrorList(UIA)'; scanBusy = $false; scanMayBeRunning = $true }
            & $addFallback $mayData
            if ($null -ne $cleanupWarning) { $mayData | Add-Member -NotePropertyName 'scanCleanupWarning' -NotePropertyValue $cleanupWarning }
            return New-TcResult -Success $false `
                -ErrorMessage 'ERRORLIST_UNAVAILABLE: a leftover Error List scan from an earlier timeout was dropped and its UIA thread may still be running; no new scan was started in this call. Retry.' `
                -ErrorCode 'ERRORLIST_UNAVAILABLE' -Hint (Get-TcErrorHint -Code 'ERRORLIST_UNAVAILABLE') `
                -Data $mayData
        }
    }

    # COM first (item 88): needs no window, no foreground, no UIA thread. Anything that is not provably the whole
    # list is NOT accepted (fail closed). Source COM (default, PR #332 round 3: every UIA fallback took the foreground, a minimized or
    # covered IDE came to the front): the result is ERRORLIST_UNVERIFIED / ERRORLIST_UNAVAILABLE with data.comReason and a hint for
    # that reason, the screen is never touched. Source Auto (opt-in): the UIA scan below reads instead, data.fallbackReason says why.
    $uiaTimeoutSec = $TimeoutSec
    if ($Source -ne 'UIA') {
        $comWatch = [System.Diagnostics.Stopwatch]::StartNew()
        if ($Source -eq 'COM') {
            # no UIA scan after it: the COM read gets the whole limit (fixed work and rows; 529 rows took 5.1-5.7 s, round 3)
            $comMaxMs = [int]($TimeoutSec * 1000)
            $comCapMs = $comMaxMs
        }
        else {
            $comMaxMs = [int][Math]::Min(8000, [Math]::Max(1000, $TimeoutSec * 250))
            $comCapMs = [int][Math]::Max($comMaxMs, $TimeoutSec * 600)
        }
        $com = Get-TcErrorListViaCom -IncludeWarnings ([bool]$IncludeWarnings) -IncludeMessages ([bool]$IncludeMessages) -MaxMs $comMaxMs -CapMs $comCapMs `
            -ExpectErrors:$ExpectErrors -ZeroErrorsKnown:$ZeroErrorsKnown -BuildPaneText $BuildPaneText -RequireBuildSummary:$RequireBuildSummary
        if ($com.accepted) { return (New-TcResult -Success $true -Data $com.data) }
        $comFallbackReason = [string]$com.reason
        if ($null -ne $com.PSObject.Properties['partial'] -and $null -ne $com.partial) { $comPartial = $com.partial }
        if ($null -ne $com.PSObject.Properties['flagsRestored'] -and -not [bool]$com.flagsRestored) { $comFlagsNotRestored = $true }
        if ($null -ne $com.PSObject.Properties['errorListCreated'] -and [bool]$com.errorListCreated) { $comCreated = $true }
        if ($null -ne $com.PSObject.Properties['errorListHidden'] -and -not [bool]$com.errorListHidden) { $comNotHidden = $true }
        if ($Source -eq 'COM') {
            $code = Get-TcErrorListComFailureCode -Reason $comFallbackReason
            $data = [PSCustomObject]@{ ideProcessId = $idePid; source = 'ErrorList(COM)'; comReason = $comFallbackReason; uiaFallback = 'off' }
            if ($comFlagsNotRestored) { $data | Add-Member -NotePropertyName 'comFlagsRestored' -NotePropertyValue $false }
            if ($comCreated) { $data | Add-Member -NotePropertyName 'comErrorListCreated' -NotePropertyValue $true }
            if ($comNotHidden) { $data | Add-Member -NotePropertyName 'comErrorListHidden' -NotePropertyValue $false }
            if ($null -ne $cleanupWarning) { $data | Add-Member -NotePropertyName 'scanCleanupWarning' -NotePropertyValue $cleanupWarning }
            & $addPartial $data $true
            $msg = & $partialText "${code}: the Error List was read through COM but not accepted ($comFallbackReason). No UI Automation scan was made (Source COM, the default: it would bring the IDE window to the front)."
            return New-TcResult -Success $false -ErrorMessage $msg -ErrorCode $code -Hint (Get-TcErrorListComHint -Reason $comFallbackReason) -Data $data
        }
        $uiaTimeoutSec = [Math]::Max(1, $TimeoutSec - [int][Math]::Ceiling($comWatch.Elapsed.TotalSeconds))
        Write-Verbose "Get-TcBuildErrors: COM read not used ($comFallbackReason); UI Automation scan (Source Auto)."
    }
    # The Error List is NOT opened here (PR #332 real-machine report item 4): ExecuteCommand('View.ErrorList') restored a minimized
    # VS2022 and pulled it to the foreground. An Error List that is not on screen is invisible to UIA: ERRORLIST_UNAVAILABLE below,
    # with the instruction to open it. (The COM read above creates the window hidden, it never shows it.)

    $timedOut = $false
    $scanError = $null
    # The scan lists the IDE windows with TcAutomation.UiaScanWindows (EnumWindows by pid, #42):
    # compile it here, before the scan budget starts (it touches no window); bounded by the same
    # -TimeoutSec in its own runspace, so the call never waits without a deadline. The time it took
    # is taken off the scan budget: preparation + scan stay within -TimeoutSec (+ at most 1 s, the
    # scan always gets at least 1 s).
    $prepWatch = [System.Diagnostics.Stopwatch]::StartNew()
    $null = Initialize-TcUiaScanTypes -TimeoutSec ([Math]::Min(600, [Math]::Max(1, $uiaTimeoutSec)))
    $scanBudgetSec = [Math]::Max(1, $uiaTimeoutSec - [int][Math]::Ceiling($prepWatch.Elapsed.TotalSeconds))
    # @(): a single PSCustomObject has no usable .Count in PS 5.1
    $out = @(Invoke-TcUiaScan -Script $script:TcUiaErrorListScan -TimeoutSec $scanBudgetSec `
        -Arguments @($idePid, $true, [bool]$IncludeWarnings, [bool]$IncludeMessages, 2000, 150) `
        -TimedOut ([ref]$timedOut) -ErrorOut ([ref]$scanError))

    $scan = $null
    if ($out.Count -gt 0) { $scan = $out[$out.Count - 1] }

    if ($timedOut -or $null -eq $scan -or -not $scan.Found) {
        $why = if ($timedOut) { "UI Automation scan did not finish within $TimeoutSec s" }
               elseif ($null -ne $scanError) { "UI Automation scan failed: $scanError" }
               elseif ($null -ne $scan -and $scan.Notes.Count -gt 0) { [string]($scan.Notes -join '; ') }
               else { 'Error List window not found in the IDE process (not on screen; TcAuto does not open it, that would restore / activate the IDE window: open View > Error List once in the IDE, then retry)' }
        $data = [PSCustomObject]@{ ideProcessId = $idePid; source = 'ErrorList(UIA)' }
        & $addFallback $data
        & $addPartial $data $true
        $why = & $partialText $why
        if ($null -ne $scan) { $data | Add-Member -NotePropertyName 'notes' -NotePropertyValue @($scan.Notes) }
        if ($null -ne $cleanupWarning) { $data | Add-Member -NotePropertyName 'scanCleanupWarning' -NotePropertyValue $cleanupWarning }
        return New-TcResult -Success $false -ErrorMessage "ERRORLIST_UNAVAILABLE: $why" -ErrorCode 'ERRORLIST_UNAVAILABLE' `
            -Hint (Get-TcErrorHint -Code 'ERRORLIST_UNAVAILABLE') -Data $data
    }

    $errors = [System.Collections.Generic.List[object]]::new()
    $warnings = [System.Collections.Generic.List[object]]::new()
    $messages = [System.Collections.Generic.List[object]]::new()
    $unclassified = [System.Collections.Generic.List[object]]::new()
    foreach ($row in @($scan.Rows)) {
        $item = ConvertTo-TcErrorListItem -Row $row
        switch ($item.severity) {
            'Error'   { $errors.Add($item) }
            'Warning' { $warnings.Add($item) }
            'Message' { $messages.Add($item) }
            default   { $unclassified.Add($item) }   # severity not isolatable: never report as errors
        }
    }
    $severityUnknown = ($unclassified.Count -gt 0 -and ($errors.Count + $warnings.Count + $messages.Count) -eq 0)

    $counts = [PSCustomObject]@{
        errors   = if ($null -ne $scan.Counts -and $null -ne $scan.Counts.errors) { [int]$scan.Counts.errors } else { $errors.Count }
        warnings = if ($null -ne $scan.Counts -and $null -ne $scan.Counts.warnings) { [int]$scan.Counts.warnings } else { $null }
        messages = if ($null -ne $scan.Counts -and $null -ne $scan.Counts.messages) { [int]$scan.Counts.messages } else { $null }
    }

    # --- readback (#117): the rows read must add up to the totals on the summary buttons ---
    # A filtered list (scope 'Current Project', a filter that could not be switched, rows the
    # scroll could not reach) shows fewer rows than the button totals; returning it as success
    # would hide errors / warnings (false success, CODING_STANDARDS section 2). Fail closed with
    # ERRORLIST_INCOMPLETE; the partial rows stay in data for diagnosis.
    $shortfall = Get-TcErrorListShortfall -Scan $scan -Errors $errors.Count -Warnings $warnings.Count -Messages $messages.Count `
        -Unclassified $unclassified.Count -IncludeWarnings ([bool]$IncludeWarnings) -IncludeMessages ([bool]$IncludeMessages)
    $scopeData = $null
    if ($null -ne $scan.PSObject.Properties['Scope'] -and $null -ne $scan.Scope) {
        $scopeData = [PSCustomObject]@{
            before   = $scan.Scope.before
            after    = $scan.Scope.after
            entire   = $scan.Scope.entire
            switched = [bool]$scan.Scope.switched
        }
    }
    $scopeFiltered = ($null -ne $scopeData -and $scopeData.entire -eq $false)

    # .ToArray(): @(<generic List>) inside a [PSCustomObject]@{} literal fails in PS 5.1
    # ("argument types incompatible")
    $data = [PSCustomObject]@{
        counts    = $counts
        errors    = $errors.ToArray()
        truncated = [bool]$scan.Truncated
        source    = 'ErrorList(UIA)'
    }
    if ($IncludeWarnings) { $data | Add-Member -NotePropertyName 'warnings' -NotePropertyValue $warnings.ToArray() }
    if ($IncludeMessages) { $data | Add-Member -NotePropertyName 'messages' -NotePropertyValue $messages.ToArray() }
    if (-not $scan.ToggleUsed) {
        $data | Add-Member -NotePropertyName 'severityIsolated' -NotePropertyValue $false
    }
    if ($unclassified.Count -gt 0) {
        $data | Add-Member -NotePropertyName 'unclassified' -NotePropertyValue $unclassified.ToArray()
    }
    if ($severityUnknown) {
        $data | Add-Member -NotePropertyName 'severityUnknown' -NotePropertyValue $true
    }
    if ($null -ne $cleanupWarning) {
        $data | Add-Member -NotePropertyName 'scanCleanupWarning' -NotePropertyValue $cleanupWarning
    }
    if ($null -ne $scopeData) {
        $data | Add-Member -NotePropertyName 'scope' -NotePropertyValue $scopeData
    }
    & $addFallback $data
    if ($shortfall.Count -gt 0 -or $scopeFiltered) {
        # the COM rows that were read before it stopped are kept next to the UIA rows (comPartial), never dropped
        & $addPartial $data $false
        $data | Add-Member -NotePropertyName 'incomplete' -NotePropertyValue $true
        # $true when a count button read "X / Y" (shown / total): the totals do not depend on the scope
        $data | Add-Member -NotePropertyName 'countsTotalForm' -NotePropertyValue ($null -ne $scan.PSObject.Properties['CountsTotalForm'] -and [bool]$scan.CountsTotalForm)
        $data | Add-Member -NotePropertyName 'missingRows' -NotePropertyValue $shortfall.ToArray()
        # $true when the Errors button total was not readable: the error rows cannot be checked
        $data | Add-Member -NotePropertyName 'errorsTotalUnknown' -NotePropertyValue ($null -eq $scan.Counts -or $null -eq $scan.Counts.errors)
        $data | Add-Member -NotePropertyName 'notes' -NotePropertyValue @($scan.Notes) -Force
        $parts = @($shortfall | ForEach-Object { "$($_.severity): $($_.read) of $($_.expected) row(s) read" })
        if ($scopeFiltered) {
            $parts += "scope filter is '$($scopeData.after)' (was '$($scopeData.before)'), not Entire Solution, and could not be switched"
        }
        return New-TcResult -Success $false `
            -ErrorMessage ('ERRORLIST_INCOMPLETE: the Error List rows read do not cover the whole list (' + ($parts -join '; ') + '); a partial read proves neither 0 errors nor the warning list.') `
            -ErrorCode 'ERRORLIST_INCOMPLETE' -Hint (Get-TcErrorHint -Code 'ERRORLIST_INCOMPLETE') -Data $data
    }
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $data | Add-Member -NotePropertyName 'notes' -NotePropertyValue @($scan.Notes)
        $data | Add-Member -NotePropertyName 'columns' -NotePropertyValue @($scan.Headers)
    }

    New-TcResult -Success $true -Data $data
}
