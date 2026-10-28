function Reset-TcSolution {
    <#
    .SYNOPSIS
        Clears the IDE's reload prompts and makes the IDE reload project files from disk:
        answers Yes to the XAE project reload prompt, or closes every document and the
        solution without saving, reopens the solution on the same IDE and reconnects.
    .DESCRIPTION
        Use after project files (.TcPOU, .TcGVL, .TcDUT, .plcproj ...) were changed ON DISK
        by another tool (an AI editor, git checkout, a generator) while the solution is open:
          - a file that is NOT open in a document window is picked up by XAE on its own
            within ~5 s; nothing to do.
          - a file that IS open in a document window makes XAE show the modal "File has
            been changed outside the environment. Reload the new file?" ~1 s after the
            write. It blocks every DTE call (IDE_MODAL_DIALOG, data.dialogKind
            'reload-prompt', reloadTarget 'file'), the Automation Interface has no reload
            command and the VS option AutoloadExternalChanges does not suppress it. Closing
            and reopening the solution is the dialog-free way (2026-10-20, 4024 32-bit XAE:
            20-25 s in total, Solution.Open 7-9 s + Connect-TcIde reconnect 12-13 s, against
            ~45 s for kill + relaunch).
          - a rewritten .plcproj (even with identical content, e.g. a generator) makes XAE
            show "The project file '...plcproj' has been modified outside of TwinCAT XAE. Do
            you want to reload the project?" (Kind 'reload-prompt', reloadTarget 'project').
            This one is answered Yes: XAE reloads the project itself, so no close / reopen
            is needed.
        Write-TcPouCode / Add-TcPou write into the IDE's edit buffer through COM (the file
        on disk is only written when the IDE saves, e.g. before a Build), so they never
        trigger the prompt and never need this.

        Steps:
          1. Get-TcIdeModalDialog, repeated while reload prompts keep coming (at most 5):
             - reloadTarget 'project': Close-TcReloadPrompt -Answer Yes (IDYES clicked by
               control id through Close-TcMessageBox, language independent), waits up to
               15 s until the prompt is gone; data.answeredYes = true.
             - reloadTarget 'file' (or a project prompt whose Yes click failed): WM_CLOSE
               (Close-TcReloadPrompt; the solution is reopened right after, so the answer
               does not matter).
             data.dismissedReloadPrompt = true when any prompt was dismissed. Any other
             dialog is reported as IDE_MODAL_DIALOG (it would block Solution.Close too).
          When only project prompts were answered and our Yes click was really sent for each
          (a prompt that vanished without our click forces the full path): steps 2-4 are
          SKIPPED. Solution.FullName is polled on the DTE we hold (500 ms, up to -TimeoutSec,
          data.reloadWaitSec) until XAE is back from the reload, then step 5 runs
          (data.reopenedSolution = false) and ITcSysManager is probed with
          LookupTreeItem('TIPC'). If Connect-TcIde fails (the previous connection state is
          restored) or the probe fails, the full path below runs on the old DTE
          (data.yesPathError says why).
          2. Documents.CloseAll(vsSaveChangesNo): XAE restores the document windows of
             the last session when a solution is (re)opened, so a changed .TcPOU that
             stays open would trigger the prompt again on the next disk edit.
             data.closedDocuments = number of documents that were open.
          3. Solution.Close($false) in Invoke-TcComRetry; the old ITcSysManager is released.
          4. Solution.Open(<sln>) on the SAME DTE (Invoke-TcComRetry, 7-9 s): an IDE with
             no solution open is never reused by Connect-TcIde -SolutionPath (it belongs
             to whoever opened it), so the reopen must happen on the instance we hold.
             data.reopenedSolution = true.
          5. Connect-TcIde -SolutionPath <sln> -ProgId <current> -NoLaunch: picks the same
             instance as 'solution-match', re-acquires ITcSysManager, re-enables SilentMode.
             data.sameIde tells whether the previous IDE pid was reused.
        The ADS connection is not touched. No dialog, no Start-Sleep beyond the polls.
    .PARAMETER SolutionPath
        Solution file (.sln) to reopen. Default: the solution Connect-TcIde / Open-TcProject opened
        ($script:TcSolutionPath), else the solution currently open in the IDE.
    .PARAMETER TimeoutSec
        Expected upper bound for each of Documents.CloseAll, Solution.Close and
        Solution.Open (Invoke-TcComRetry -TimeoutSec). Default 120.
    .EXAMPLE
        # AI changed MAIN.TcPOU on disk while it was open in an XAE editor:
        Reset-TcSolution
        Build-TcProject
    .EXAMPLE
        # A generator rewrote plc.plcproj; XAE asks "Do you want to reload the project?":
        Reset-TcSolution     # answers Yes, reconnects, data.answeredYes = true, reopenedSolution = false
    .OUTPUTS
        data.solution              path that was reopened
        data.dismissedReloadPrompt a reload prompt was up and was closed by this cmdlet
        data.reloadTarget          'project' | 'file' | $null: which reload prompt was seen
                                   ('project' wins when both were)
        data.answeredYes           the project reload prompt was answered Yes (our click was sent)
        data.reopenedSolution      Solution.Close + Solution.Open were done (false on the
                                   Yes-only path)
        data.closedDocuments       documents closed before Solution.Close
        data.closed                Solution.Close returned
        data.closeSec              seconds for CloseAll + Solution.Close
        data.openSec               seconds Solution.Open took
        data.connectSec            seconds the Connect-TcIde reconnect took
        data.totalSec              seconds in total (measured 20-25 s for close / reopen)
        data.ideProcessId          IDE pid after the reconnect
        data.previousIdeProcessId  IDE pid before
        data.sameIde               both pids equal
        data.selectedBy / sysManagerAvailable / silentMode / amsNetId / warning
                                   as reported by Connect-TcIde
        data.ownedBySession        this session launched the IDE (Disconnect-TcIde -Kill is
                                   allowed), even though selectedBy now says solution-match
        Errors: NOT_CONNECTED, NO_SOLUTION, FILE_NOT_FOUND, IDE_MODAL_DIALOG, RESET_SOLUTION_MISMATCH
        (the IDE has another solution open than the module expected; nothing closed, #29),
        RESET_SOLUTION_UNVERIFIED (the open solution could not be read to compare; nothing closed),
        SOLUTION_CLOSE_FAILED, PROJECT_OPEN_FAILED (or IDE_BUSY / IDE_TIMEOUT /
        IDE_CRASHED from the COM calls), and any Connect-TcIde error code when the
        reconnect fails (data.closed / data.reopened say how far it got).
        BUILD_REQUIRED (#65): once XAE may hold project files reloaded from disk the solution
        ($path, the .sln this call reopens; after a Yes reload - success or failure - ALSO the
        module's solution path at the start and the one RESET_SOLUTION_MISMATCH read, every
        distinct one of them) is recorded as 'code-changed' (Register-TcCodeChange;
        data.buildRequired / data.stateWarning): success on either path; every failure after a
        project reload prompt was answered Yes (data.answeredYes: modal dialog, reload prompt
        handling, reconnect, solution check, Documents.CloseAll, Solution.Close, Solution.Open);
        PROJECT_OPEN_FAILED in any case (the solution may be half open); a failed reconnect
        after Solution.Open. Not recorded: a failure before anything was reloaded (NO_SOLUTION,
        FILE_NOT_FOUND, a dialog / RESET_SOLUTION_* / close failure without a Yes). This cmdlet is the
        way to pick up files changed ON DISK, which the module cannot see, so Enable-TcConfig
        and Enter-TcPlcOnline refuse until a complete Build-TcProject. A disk edit that XAE
        reloads by itself (file not open in an editor, no Reset-TcSolution) is not recorded
        (known limit, docs/troubleshooting.md BUILD_REQUIRED).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 120
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $dte = $script:TcDte
    $progId = $script:TcProgId
    $previousPid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $previousPid = [int]$script:TcIdeProcessId } catch { $previousPid = 0 } }

    # --- resolve the solution to reopen ---
    $path = $SolutionPath
    if ([string]::IsNullOrWhiteSpace($path) -and -not [string]::IsNullOrWhiteSpace($script:TcSolutionPath)) {
        $path = [string]$script:TcSolutionPath
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        try {
            $path = [string](Invoke-TcComRetry -OperationName 'Solution.FullName' -ScriptBlock { [string]$dte.Solution.FullName })
        }
        catch {
            return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NO_SOLUTION' -MessagePrefix 'Could not read the path of the open solution'
        }
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return New-TcResult -Success $false -ErrorMessage 'No solution is open and no -SolutionPath was given; nothing to reopen.' `
            -ErrorCode 'NO_SOLUTION' -Hint (Get-TcErrorHint -Code 'NO_SOLUTION')
    }
    if (-not (Test-Path -LiteralPath $path)) {
        return New-TcResult -Success $false -ErrorMessage "Solution file not found: $path" -ErrorCode 'FILE_NOT_FOUND'
    }
    $path = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $path).Path)

    $progress = [ordered]@{
        solution              = $path
        dismissedReloadPrompt = $false
        reloadTarget          = $null
        answeredYes           = $false
        reopenedSolution      = $false
        closedDocuments       = 0
        closed                = $false
        reopened              = $false
        previousIdeProcessId  = $previousPid
    }
    function Get-ProgressData { param([hashtable]$Extra) $d = [PSCustomObject]$progress; if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $d | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force } }; $d }

    # Connect-TcIde failure -> result that keeps its code / hint / data and says where it happened.
    function New-ReconnectFailedResult {
        param([object]$Connect, [hashtable]$Extra, [string]$Where)
        $err = $Connect.error
        $data = Get-ProgressData -Extra $Extra
        $dp = $Connect.PSObject.Properties['data']
        if ($null -ne $dp -and $null -ne $dp.Value) {
            foreach ($p in $dp.Value.PSObject.Properties) { $data | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        }
        $params = @{
            Success      = $false
            ErrorMessage = "$Where but Connect-TcIde failed: $($err.message)"
            ErrorCode    = [string]$err.code
            Data         = $data
        }
        $hp = $err.PSObject.Properties['hint']
        if ($null -ne $hp -and -not [string]::IsNullOrWhiteSpace([string]$hp.Value)) { $params['Hint'] = [string]$hp.Value }
        New-TcResult @params
    }

    # Successful reconnect -> final data.
    function New-ReconnectedData {
        param([object]$ConnectData, [System.Collections.IDictionary]$Extra, [System.Diagnostics.Stopwatch]$Total)
        $newPid = 0
        try { $newPid = [int]$ConnectData.ideProcessId } catch { $newPid = 0 }
        $sameIde = ($previousPid -gt 0 -and $newPid -eq $previousPid)
        $all = [ordered]@{}
        foreach ($k in $Extra.Keys) { $all[$k] = $Extra[$k] }
        $all['totalSec'] = [math]::Round($Total.Elapsed.TotalSeconds, 1)
        $all['ideProcessId'] = $newPid
        $all['sameIde'] = $sameIde
        $all['selectedBy'] = $ConnectData.selectedBy
        $all['ownedBySession'] = ($script:TcIdeSelectedBy -eq 'launched')
        $all['sysManagerAvailable'] = [bool]$ConnectData.sysManagerAvailable
        $all['silentMode'] = $ConnectData.silentMode
        $data = Get-ProgressData -Extra $all
        foreach ($name in @('amsNetId', 'warning')) {
            $prop = $ConnectData.PSObject.Properties[$name]
            if ($null -ne $prop) { $data | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value -Force }
        }
        if (-not $sameIde) {
            $note = "Connect-TcIde picked IDE pid $newPid instead of the previous pid $previousPid."
            $wp = $data.PSObject.Properties['warning']
            if ($null -ne $wp -and -not [string]::IsNullOrWhiteSpace([string]$wp.Value)) { $note = "$($wp.Value) $note" }
            $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $note -Force
        }
        $data
    }

    # #65: a failure AFTER XAE reloaded the project from disk (answeredYes) is recorded as
    # code-changed for $path (the files XAE now holds may differ from the last complete build);
    # -Always for a failure that may have left the solution half open (Solution.Open).
    # The Yes reload happened in the solution the IDE had open, i.e. the module's
    # $script:TcSolutionPath at the start (Enable-TcConfig / Enter-TcPlcOnline check that key),
    # or the solution the IDE reports (RESET_SOLUTION_MISMATCH). Which one XAE really reloaded is
    # not known for sure, so after a Yes reload EVERY candidate is recorded: $path, the start
    # solution and the reported one (empty ones dropped, one record per solution key).
    $leaf = [IO.Path]::GetFileName([string]$path)
    $startSolution = [string]$script:TcSolutionPath
    function Register-TcResetChange {
        param([object]$Result, [string]$Change, [string[]]$Solutions)
        $seen = @{}
        $warnings = [System.Collections.Generic.List[string]]::new()
        $out = $Result
        foreach ($s in $Solutions) {
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $k = ConvertTo-TcSolutionKey $s
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            # each call may set data.stateWarning: clear it first, collect every one
            if ($null -ne $out -and $null -ne $out.PSObject.Properties['data'] -and $null -ne $out.data -and $out.data -isnot [System.Collections.IDictionary]) {
                $out.data.PSObject.Properties.Remove('stateWarning')
            }
            $out = Register-TcCodeChange -Result $out -SolutionPath $s -Change $Change
            $wp = $out.data.PSObject.Properties['stateWarning']
            if ($null -ne $wp -and -not [string]::IsNullOrWhiteSpace([string]$wp.Value) -and -not $warnings.Contains([string]$wp.Value)) { $warnings.Add([string]$wp.Value) }
        }
        if ($null -ne $out -and $warnings.Count -gt 0) { $out.data | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue ($warnings -join '; ') -Force }
        $out
    }
    function Complete-TcResetFailure {
        param([object]$Result, [string]$Step, [switch]$Always, [string]$ReloadedSolution)
        if ($progress.answeredYes) {
            $change = "Reset-TcSolution $leaf (project reloaded from disk, then $Step failed)"
            return Register-TcResetChange -Result $Result -Change $change -Solutions @($path, $startSolution, $ReloadedSolution)
        }
        if ($Always) {
            return Register-TcCodeChange -Result $Result -SolutionPath $path -Change "Reset-TcSolution $leaf ($Step failed, solution may be half open)"
        }
        $Result
    }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    # --- 1. modal dialogs: reload prompts are answered (project: Yes, file: WM_CLOSE), anything else is reported ---
    $needReopen = $false   # a prompt was closed with WM_CLOSE (answer No) or vanished without our click
    $yesFailed = $false
    $handled = 0
    while ($true) {
        $dialog = Get-TcIdeModalDialog
        if ($null -eq $dialog) { break }
        if ([string]$dialog.Kind -ne 'reload-prompt') {
            $op = if ($progress.dismissedReloadPrompt) { 'Reset-TcSolution (after dismissing the reload prompt)' } else { 'Reset-TcSolution (Documents.CloseAll / Solution.Close)' }
            return Complete-TcResetFailure -Step 'modal dialog check' -Result (New-TcModalDialogResult -Dialog $dialog -Operation $op -Data (Get-ProgressData))
        }
        $handled++
        if ($handled -gt 5) {
            return Complete-TcResetFailure -Step 'reload prompt handling' -Result (New-TcModalDialogResult -Dialog $dialog -Operation 'Reset-TcSolution (reload prompts keep appearing; 5 dismissed)' -Data (Get-ProgressData))
        }
        $target = [string]$dialog.ReloadTarget
        if ($target -eq 'project' -or [string]::IsNullOrWhiteSpace([string]$progress.reloadTarget)) { $progress.reloadTarget = $target }

        if ($target -eq 'project' -and -not $yesFailed) {
            $yes = Close-TcReloadPrompt -Dialog $dialog -Answer Yes -TimeoutSec 15
            if ($yes.Sent -and ($yes.Dismissed -or $null -ne $yes.NextDialog)) {
                # Our click was sent and the prompt closed (another dialog may be up now: the loop
                # reports it). Only an actual click counts as answeredYes.
                $progress.answeredYes = $true
                $progress.dismissedReloadPrompt = $true
                Write-Verbose "Reset-TcSolution: project reload prompt answered Yes ($($yes.Reason))."
                continue
            }
            if ($yes.Dismissed -and -not $yes.Sent) {
                # The prompt vanished without our click: nobody knows whether XAE reloaded, so
                # take the full close / reopen path.
                $needReopen = $true
                Write-Verbose "Reset-TcSolution: project reload prompt was already gone ($($yes.Reason)); doing the full close / reopen."
                continue
            }
            # Yes click failed or the prompt stayed: fall back to WM_CLOSE + close / reopen.
            $yesFailed = $true
            Write-Verbose "Reset-TcSolution: answering Yes failed ($($yes.Reason)); falling back to WM_CLOSE and close / reopen."
            continue
        }

        $closeResult = Close-TcReloadPrompt -Dialog $dialog
        if (-not $closeResult.Dismissed) {
            return Complete-TcResetFailure -Step 'reload prompt dismissal' -Result (New-TcModalDialogResult -Dialog $dialog -Operation "Reset-TcSolution (reload prompt could not be dismissed: $($closeResult.Reason))" `
                -Data (Get-ProgressData))
        }
        $progress.dismissedReloadPrompt = $true
        $needReopen = $true
        Write-Verbose "Reset-TcSolution: reload prompt dismissed ($($closeResult.Reason))."
    }

    # --- Yes-only path: XAE reloaded the project itself; skip CloseAll / Close / Open ---
    if ($progress.answeredYes -and -not $needReopen) {
        # a. Wait on the DTE we hold until XAE answers Solution.FullName with our solution again
        #    (it is busy while it reloads the project). Polled every 500 ms, no blind sleep.
        $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
        $reloaded = $false
        $lastRead = $null
        while ($waitSw.Elapsed.TotalSeconds -lt $TimeoutSec) {
            try {
                $full = [string](Invoke-TcComRetry -OperationName 'Solution.FullName (post-reload wait)' -MaxRetries 1 -ScriptBlock { [string]$dte.Solution.FullName })
                $lastRead = $full
                if (-not [string]::IsNullOrWhiteSpace($full) -and [string]::Equals([IO.Path]::GetFullPath($full), $path, [StringComparison]::OrdinalIgnoreCase)) { $reloaded = $true; break }
            }
            catch { $lastRead = $_.Exception.Message }
            Start-Sleep -Milliseconds 500
        }
        $progress['reloadWaitSec'] = [math]::Round($waitSw.Elapsed.TotalSeconds, 1)
        if (-not $reloaded) { Write-Verbose "Reset-TcSolution: Solution.FullName not back to '$path' after the Yes reload (last: $lastRead); reconnecting anyway." }

        # b. Reconnect; on failure restore the identity and fall back to close / reopen on the old DTE.
        $saved = @{
            Dte = $script:TcDte; ProgId = $script:TcProgId; Pid = $script:TcIdeProcessId; SelectedBy = $script:TcIdeSelectedBy
            Sln = $script:TcSolutionPath; Start = $script:TcIdeStartTime; MainHwnd = $script:TcIdeMainHwnd
            Settings = $script:TcAutomationSettings; Silent = $script:TcSilentMode; SilentOriginal = $script:TcSilentModeOriginal
        }
        if ($null -ne $script:TcSysManager) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
            $script:TcSysManager = $null
        }
        $connectParams = @{ SolutionPath = $path; NoLaunch = $true }
        if (-not [string]::IsNullOrWhiteSpace($progId)) { $connectParams['ProgId'] = $progId }
        $connectSw = [System.Diagnostics.Stopwatch]::StartNew()
        $connect = Connect-TcIde @connectParams
        $connectSec = [math]::Round($connectSw.Elapsed.TotalSeconds, 1)
        $probeError = $null
        if (-not $connect.success) {
            $probeError = "Connect-TcIde failed: [$($connect.error.code)] $($connect.error.message)"
            $script:TcDte = $saved.Dte; $script:TcProgId = $saved.ProgId; $script:TcIdeConnected = ($null -ne $saved.Dte)
            $script:TcIdeProcessId = $saved.Pid; $script:TcIdeSelectedBy = $saved.SelectedBy; $script:TcSolutionPath = $saved.Sln
            $script:TcIdeStartTime = $saved.Start; $script:TcIdeMainHwnd = $saved.MainHwnd
            $script:TcAutomationSettings = $saved.Settings; $script:TcSilentMode = $saved.Silent; $script:TcSilentModeOriginal = $saved.SilentOriginal
        }
        else {
            # Probe the re-bound ITcSysManager the same way other commands use it.
            $sm = $script:TcSysManager
            if ($null -eq $sm) { $probeError = 'ITcSysManager not available after reconnect' }
            else {
                $tipc = $null
                try {
                    $tipc = Invoke-TcComRetry -OperationName 'LookupTreeItem TIPC (post-reload probe)' -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem('TIPC') }
                    if ($null -eq $tipc) { $probeError = "LookupTreeItem('TIPC') returned null" }
                }
                catch { $probeError = $_.Exception.Message }
                if ($null -ne $tipc) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tipc) | Out-Null } catch { } }
            }
            if ($null -eq $probeError) {
                $ok = New-TcResult -Success $true -Data (New-ReconnectedData -ConnectData $connect.data -Extra ([ordered]@{ connectSec = $connectSec }) -Total $sw)
                return Register-TcResetChange -Result $ok -Change "Reset-TcSolution $leaf (project reloaded from disk)" -Solutions @([string]$script:TcSolutionPath, $path, $startSolution)
            }
        }
        Write-Verbose "Reset-TcSolution: reconnect after the Yes reload failed ($probeError); doing the full close / reopen."
        $progress['yesPathError'] = $probeError
        $dte = $script:TcDte
        $progId = $script:TcProgId
        if ($null -eq $dte) {
            return Complete-TcResetFailure -Step 'reconnect' -Result (New-TcResult -Success $false -ErrorMessage "Project reload answered Yes, but the IDE is not usable afterwards: $probeError" `
                -ErrorCode 'NOT_CONNECTED' -Data (Get-ProgressData -Extra @{ connectSec = $connectSec }))
        }
    }

    # --- guard (#29): never close a solution the module did not expect in this IDE ---
    # Connect-TcIde can attach a blocked IDE on evidence such as a session record; when the IDE
    # turns out to have ANOTHER solution open than the module believes, closing it would hit
    # someone else's work. Expected = the solution the module connected / opened (else $path).
    $expected = if (-not [string]::IsNullOrWhiteSpace($script:TcSolutionPath)) { [string]$script:TcSolutionPath } else { $path }
    # Fail closed: poll until Solution.FullName can be read (busy after a reload, $null for a
    # moment), up to -TimeoutSec. Never readable -> RESET_SOLUTION_UNVERIFIED, nothing closed.
    # '' (no solution open) is a valid answer and lets the reset go on.
    $openNow = $null
    $guardRead = $false
    $guardError = $null
    $guardSw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            $raw = Invoke-TcComRetry -MaxRetries 1 -OperationName 'Solution.FullName (guard)' -ScriptBlock { $gSol = $dte.Solution; if ($null -eq $gSol) { $null } else { $gSol.FullName } }
            if ($null -ne $raw) { $openNow = [string]$raw; $guardRead = $true; break }
            $guardError = 'Solution / Solution.FullName answered $null'
        }
        catch { $guardError = $_.Exception.Message }
        if ($guardSw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
        Start-Sleep -Milliseconds 500
    }
    if (-not $guardRead) {
        return Complete-TcResetFailure -Step 'solution check' -Result (New-TcResult -Success $false `
            -ErrorMessage "Reset-TcSolution not attempted: Solution.FullName of the IDE (pid $previousPid) could not be read within $TimeoutSec s ($guardError), so the open solution could not be compared with '$expected'. Nothing was closed." `
            -ErrorCode 'RESET_SOLUTION_UNVERIFIED' -Hint (Get-TcErrorHint -Code 'RESET_SOLUTION_UNVERIFIED') `
            -Data (Get-ProgressData -Extra @{ expectedSolution = $expected; guardError = $guardError; guardSec = [math]::Round($guardSw.Elapsed.TotalSeconds, 1) }))
    }
    if (-not [string]::IsNullOrWhiteSpace($openNow)) {
        $openNorm = try { [IO.Path]::GetFullPath($openNow) } catch { $openNow }
        $expNorm = try { [IO.Path]::GetFullPath($expected) } catch { $expected }
        if (-not [string]::Equals($openNorm, $expNorm, [StringComparison]::OrdinalIgnoreCase)) {
            return Complete-TcResetFailure -Step 'solution check' -ReloadedSolution $openNorm -Result (New-TcResult -Success $false `
                -ErrorMessage "Reset-TcSolution not attempted: the IDE (pid $previousPid) has '$openNorm' open, not '$expNorm' that the module expected. Nothing was closed." `
                -ErrorCode 'RESET_SOLUTION_MISMATCH' -Hint (Get-TcErrorHint -Code 'RESET_SOLUTION_MISMATCH') `
                -Data (Get-ProgressData -Extra @{ openSolution = $openNorm; expectedSolution = $expNorm }))
        }
    }

    $closeSw = [System.Diagnostics.Stopwatch]::StartNew()

    # --- 2. close every document (vsSaveChangesNo = 2) ---
    try {
        $progress.closedDocuments = [int](Invoke-TcComRetry -OperationName 'Documents.CloseAll' -TimeoutSec $TimeoutSec -ScriptBlock {
            $docs = $dte.Documents
            $n = 0
            if ($null -ne $docs) {
                try { $n = [int]$docs.Count } catch { $n = 0 }
                $docs.CloseAll(2)
            }
            $n
        })
    }
    catch {
        return Complete-TcResetFailure -Step 'Documents.CloseAll' -Result (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SOLUTION_CLOSE_FAILED' -MessagePrefix 'Documents.CloseAll failed' -Data (Get-ProgressData))
    }

    # --- 3. close the solution without saving ---
    try {
        Invoke-TcComRetry -OperationName 'Solution.Close' -TimeoutSec $TimeoutSec -ScriptBlock { $dte.Solution.Close($false) } | Out-Null
    }
    catch {
        return Complete-TcResetFailure -Step 'Solution.Close' -Result (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SOLUTION_CLOSE_FAILED' -MessagePrefix 'Solution.Close failed' -Data (Get-ProgressData))
    }
    $progress.closed = $true
    $closeSec = [math]::Round($closeSw.Elapsed.TotalSeconds, 1)

    # The ITcSysManager of the closed solution is dead; Connect-TcIde acquires the new one.
    if ($null -ne $script:TcSysManager) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
        $script:TcSysManager = $null
    }

    # --- 4. reopen on the same DTE ---
    $openSw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TcComRetry -OperationName 'Solution.Open' -TimeoutSec $TimeoutSec -ScriptBlock { $dte.Solution.Open($path) } | Out-Null
    }
    catch {
        return Complete-TcResetFailure -Step 'Solution.Open' -Always -Result (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_OPEN_FAILED' -MessagePrefix 'Solution closed but Solution.Open failed' `
            -Data (Get-ProgressData -Extra @{ closeSec = $closeSec }))
    }
    $progress.reopened = $true
    $progress.reopenedSolution = $true
    # The IDE has $path open now (maybe another .sln than before): keep the #29 record current
    # even if the reconnect below fails.
    $script:TcSolutionPath = $path
    if ($previousPid -gt 0) { Save-TcIdeSolutionRecord -ProcessId $previousPid -Solution $path }
    $openSec = [math]::Round($openSw.Elapsed.TotalSeconds, 1)

    # --- 5. reconnect: the instance now has the target solution open -> 'solution-match' ---
    $connectParams = @{ SolutionPath = $path; NoLaunch = $true }
    if (-not [string]::IsNullOrWhiteSpace($progId)) { $connectParams['ProgId'] = $progId }
    $connectSw = [System.Diagnostics.Stopwatch]::StartNew()
    $connect = Connect-TcIde @connectParams
    $connectSec = [math]::Round($connectSw.Elapsed.TotalSeconds, 1)

    $resetChange = "Reset-TcSolution $([IO.Path]::GetFileName([string]$path)) (solution reopened from disk)"
    if (-not $connect.success) {
        $failed = New-ReconnectFailedResult -Connect $connect -Extra @{ closeSec = $closeSec; openSec = $openSec; connectSec = $connectSec } -Where 'Solution reopened'
        return Register-TcCodeChange -Result $failed -Change $resetChange
    }

    $ok = New-TcResult -Success $true -Data (New-ReconnectedData -ConnectData $connect.data -Total $sw -Extra ([ordered]@{
        closeSec   = $closeSec
        openSec    = $openSec
        connectSec = $connectSec
    }))
    Register-TcCodeChange -Result $ok -Change $resetChange
}
