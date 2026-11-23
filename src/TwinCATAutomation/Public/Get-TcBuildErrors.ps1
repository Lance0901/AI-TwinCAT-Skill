function Get-TcBuildErrors {
    <#
    .SYNOPSIS
        Reads the compiler messages of the IDE "Error List" (errors, and optionally warnings /
        messages): through COM (DTE2 ErrorList.ErrorItems) first, UI Automation as the fallback.
    .DESCRIPTION
        Source 1, COM (data.source 'ErrorList(COM)'; item 88, re #320 / #329 / #300): the Error List
        of the connected IDE is read with an early-bound C# helper (ErrorListComReader.cs; PowerShell
        late binding reads a fake 0, 實測 2026-11-23). It needs no visible window and no foreground and
        takes about 2 ms per row (529 rows 0.96 s; the UIA scan timed out on the same list, #329). The
        Errors / Warnings / Messages buttons are set on for the read (ShowErrors / ShowWarnings /
        ShowMessages) and put back afterwards. The result is accepted only when it is provably the whole
        list (fail closed: a filtered Error List answers 0 rows without an error):
          - the Error List window caption is the bare title (Entire Solution); 'Error List - Current
            Project (X)' / '- Current Document' / '- Open Documents' or an unknown caption -> UIA
          - severity: every host by reading one Show* flag at a time (each read after an all-off step that must
            show 0 rows); the three reads must add up to the all-flags count. 4024 (TcXaeShell 15.0, ErrorLevel
            error 4 / warning 2 / message 1 = High / Medium / Low, vsBuildErrorLevel) also cross-checks every row's
            level against its flag; 4026 (ErrorLevel is 2 for every row) has no such table
          - -ExpectErrors (the build / check failed) and no error row read -> UIA
          - -BuildPaneText (the pane of this build): more error lines there than error rows, or an error line without a
            row of the same file and text -> UIA
          - -RequireBuildSummary (callers that decide success from the list): no end summary line in the pane of this
            build ('Build complete -- N errors' / MSBuild 'Build: .. failed'), or fewer error rows than it says -> UIA.
            COM cannot see the Error List search box or column filters; the summary is what rules a filtered list out
          - the Error List window does not exist yet ('errorlist-not-created'): COM does not create it, UIA shows it
        The compiler code (Cxxxx / SAxxxx) is not in the COM description: it is taken from the build
        pane line with the same file and text, else $null. file / project / line have the UIA form
        (file = base name + ' (Impl)' / ' (Decl)' as the grid shows it, project = project name, line =
        the Error List line, column = $null; data.errors[].filePath = the full path).
        Source 2, UI Automation (data.source 'ErrorList(UIA)'; data.fallbackReason says why COM was not
        used). The TwinCAT PLC compiler does not report through DTE when read with late binding, so the
        Error List tool window of the XAE is scanned: the window is made visible with View.ErrorList,
        then a UI Automation scan (separate STA runspace, hard -TimeoutSec) reads
          - the summary buttons ("9 Errors", "8 Warnings", "0 of 10 Messages") -> counts
          - every row of the (virtualised) grid, scrolling page by page, de-duplicated
            on description+project+file+line.
        Severity is isolated by toggling the summary buttons one at a time (the row icon
        has no readable name); the original button states are restored afterwards.
        The TwinCAT error code (Cxxxx / SAxxxx) is parsed from the description when it
        is part of it; the IDE's own "Code" column is used when that column is shown.
        Requires the IDE process id stored by Connect-TcIde and a visible Error List
        (not auto-hidden); otherwise ERRORLIST_UNAVAILABLE is returned.
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
        Limit for the whole call: the COM path gets at most a quarter of it (8 s at most; compile, read, pane and
        codes are checked against it between COM calls), the UI Automation scan what is left (at least 1 s),
        including the one-time preparation of its helper types (the first call in a process). The UIA scan is hard;
        one COM call that blocks inside the IDE (modal dialog) cannot be interrupted, the same limit as
        Invoke-TcComRetry (it runs under its modal-dialog watchdog). Default 30.
    .PARAMETER Source
        Auto (default): COM first, UIA when the COM read cannot be accepted. UIA: UI Automation only
        (diagnosis; the COM read is skipped).
    .PARAMETER ExpectErrors
        The caller knows the build / check failed (LastBuildInfo > 0, CheckAllObjects False): a COM list
        without any error row is then not accepted (falls back to UIA).
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
                         'severity-isolation-mismatch: ...', 'error-level-mismatch: ...', 'errorlist-not-created',
                         'com-read-failed:<why>', 'com-helper-unavailable: ...', 'com-budget-exceeded: ...', 'com-error: ...'
        data.comFlagsRestored  $false (only then present) on a UIA result: the COM read changed the Error List Errors /
                         Warnings / Messages buttons and could not put them back
        data.comRead     COM results only: severityBy ('ShowFlags'), levelCheck, levelCounts, dteMajor, readMs, rows,
                         flagsRestored, errorsWithoutCode (error rows whose code the build pane could not give),
                         paneCrossCheck, buildSummary, notes
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
        [ValidateSet('Auto', 'UIA')]
        [string]$Source = 'Auto',

        [Parameter()]
        [switch]$ExpectErrors,

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
    $addFallback = {
        param($Data)
        if ($null -ne $comFallbackReason) { $Data | Add-Member -NotePropertyName 'fallbackReason' -NotePropertyValue $comFallbackReason -Force }
        if ($comFlagsNotRestored) { $Data | Add-Member -NotePropertyName 'comFlagsRestored' -NotePropertyValue $false -Force }
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
    # list falls back to the UIA scan below, with the reason in data.fallbackReason (fail closed).
    $uiaTimeoutSec = $TimeoutSec
    if ($Source -eq 'Auto') {
        $comWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $comMaxMs = [int][Math]::Min(8000, [Math]::Max(1000, $TimeoutSec * 250))
        $com = Get-TcErrorListViaCom -IncludeWarnings ([bool]$IncludeWarnings) -IncludeMessages ([bool]$IncludeMessages) -MaxMs $comMaxMs `
            -ExpectErrors:$ExpectErrors -BuildPaneText $BuildPaneText -RequireBuildSummary:$RequireBuildSummary
        if ($com.accepted) { return (New-TcResult -Success $true -Data $com.data) }
        $comFallbackReason = [string]$com.reason
        if ($null -ne $com.PSObject.Properties['flagsRestored'] -and -not [bool]$com.flagsRestored) { $comFlagsNotRestored = $true }
        $uiaTimeoutSec = [Math]::Max(1, $TimeoutSec - [int][Math]::Ceiling($comWatch.Elapsed.TotalSeconds))
        Write-Verbose "Get-TcBuildErrors: COM read not used ($comFallbackReason); UI Automation scan."
    }
    # Make sure the tool window is shown (auto-hidden / closed windows are invisible to UIA).
    try {
        Invoke-TcComRetry -MaxRetries 2 -OperationName 'View.ErrorList' -TimeoutSec 30 -ScriptBlock {
            $script:TcDte.ExecuteCommand('View.ErrorList')  # tcauto-allow(executecommand): opens the XAE Error List window to read it, no TwinCAT command
        } | Out-Null
        Start-Sleep -Milliseconds 300
    }
    catch {
        Write-Verbose "Get-TcBuildErrors: View.ErrorList failed ($($_.Exception.Message)); reading whatever is visible."
    }

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
               else { 'Error List window not found in the IDE process' }
        $data = [PSCustomObject]@{ ideProcessId = $idePid; source = 'ErrorList(UIA)' }
        & $addFallback $data
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
