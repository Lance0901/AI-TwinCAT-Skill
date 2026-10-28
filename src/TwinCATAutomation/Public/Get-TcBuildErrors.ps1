function Get-TcBuildErrors {
    <#
    .SYNOPSIS
        Reads the compiler messages shown in the IDE "Error List" window (errors, and
        optionally warnings / messages) via UI Automation.
    .DESCRIPTION
        The TwinCAT PLC compiler does not report through DTE (ErrorList.ErrorItems and
        OutputWindow stay empty), so the only source is the Error List tool window of
        the XAE. The window is made visible with View.ErrorList, then a UI Automation
        scan (separate STA runspace, hard -TimeoutSec) reads
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
        such as "0 / 2" + the localized word; the total is reported). When the VS2022
        scope filter shows "Current Project" / "Current Document" / "Open Documents",
        the scan switches it to "Entire Solution" first (leaves it switched).
    .PARAMETER IncludeWarnings
        Default on; -IncludeWarnings:$false skips the warning toggle (saves 1-2 s of UIA).
        Also reads warning rows (data.warnings, always present when on, possibly empty).
    .PARAMETER IncludeMessages
        Also read message rows (data.messages).
    .PARAMETER TimeoutSec
        Hard limit for the UI Automation scan. Default 30.
    .OUTPUTS
        data.counts      @{ errors; warnings; messages } from the summary buttons
        data.errors      [ @{ severity; code; description; project; file; line; column } ]
        data.warnings    same shape, present unless -IncludeWarnings:$false (may be empty)
        data.messages    same shape, only with -IncludeMessages
        data.truncated   $true when not every row could be read (no ScrollPattern / cap)
        data.source      'ErrorList(UIA)'
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
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$IncludeWarnings = $true,

        [Parameter()]
        [switch]$IncludeMessages,

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 30
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
    # a second scan would compete for the same window (and toggle the same buttons).
    $cleanupWarning = $null
    if ($script:TcErrorListScanBusy) {
        $stillRunning = Clear-TcUiaAbandonedScans
        $cleanupWarning = $script:TcUiaCleanupWarning
        if ($stillRunning -gt 0) {
            $busyData = [PSCustomObject]@{ ideProcessId = $idePid; source = 'ErrorList(UIA)'; scanBusy = $true }
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
            if ($null -ne $cleanupWarning) { $mayData | Add-Member -NotePropertyName 'scanCleanupWarning' -NotePropertyValue $cleanupWarning }
            return New-TcResult -Success $false `
                -ErrorMessage 'ERRORLIST_UNAVAILABLE: a leftover Error List scan from an earlier timeout was dropped and its UIA thread may still be running; no new scan was started in this call. Retry.' `
                -ErrorCode 'ERRORLIST_UNAVAILABLE' -Hint (Get-TcErrorHint -Code 'ERRORLIST_UNAVAILABLE') `
                -Data $mayData
        }
    }

    # Make sure the tool window is shown (auto-hidden / closed windows are invisible to UIA).
    try {
        Invoke-TcComRetry -MaxRetries 2 -OperationName 'View.ErrorList' -TimeoutSec 30 -ScriptBlock {
            $script:TcDte.ExecuteCommand('View.ErrorList')
        } | Out-Null
        Start-Sleep -Milliseconds 300
    }
    catch {
        Write-Verbose "Get-TcBuildErrors: View.ErrorList failed ($($_.Exception.Message)); reading whatever is visible."
    }

    $timedOut = $false
    $scanError = $null
    # @(): a single PSCustomObject has no usable .Count in PS 5.1
    $out = @(Invoke-TcUiaScan -Script $script:TcUiaErrorListScan -TimeoutSec $TimeoutSec `
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
    if ($VerbosePreference -ne 'SilentlyContinue') {
        $data | Add-Member -NotePropertyName 'notes' -NotePropertyValue @($scan.Notes)
        $data | Add-Member -NotePropertyName 'columns' -NotePropertyValue @($scan.Headers)
    }

    New-TcResult -Success $true -Data $data
}
