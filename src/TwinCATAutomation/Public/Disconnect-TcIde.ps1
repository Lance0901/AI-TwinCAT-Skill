function Disconnect-TcIde {
    <#
    .SYNOPSIS
        Disconnects from the TwinCAT IDE and releases COM references.
    .DESCRIPTION
        Without -Quit only the COM references are released; the IDE keeps running.

        With -Quit:
          0. #227: only for an IDE this session launched (data.ownedBySession). Any other IDE
             (Connect-TcIde selectedBy solution-match / first-instance / process-id ... on an IDE
             the user opened) is refused BEFORE anything else - with or without -Kill: success =
             false, code IDE_NOT_OWNED, data.quit = false, data.disconnected = false, data.reason
             'not launched by this session'; nothing is closed and the connection is kept
             (Disconnect-TcIde without -Quit releases it). The user closes that IDE.
          1. Find-TcIdeModalDialog first. A modal dialog blocks Solution.Close / DTE.Quit
             forever, so with a dialog up (and no -Kill) nothing is attempted (no 60 s
             retries) and NOTHING is released: the connection stays usable. Result:
             success = false, code IDE_QUIT_FAILED, data.disconnected = false, data.quit =
             false, data.quitError = 'modal dialog is up: <title>', data.dialog = {title,
             text, kind, reloadTarget}. A reload prompt (kind reload-prompt): run
             Reset-TcSolution, then Disconnect-TcIde -Quit again. Anything else: -Quit -Kill
             (launched IDE) or Stop-Process -Id data.ideProcessId.
             A dialog scan that did not complete (#42) is treated the same way, as unknown:
             nothing attempted, connection kept, code MODAL_SCAN_INCOMPLETE (data.modalScan);
             with -Kill the kill path is taken.
          2. Solution.Close($false) + DTE.Quit(). When the quit does not succeed the result
             is success = false, code IDE_QUIT_FAILED (data.solutionClosed / quit / quitError /
             ideProcessId / selectedBy, data.disconnected = true); the COM references are
             released, the IDE process is still running.
        With -Quit -Kill: when a dialog is up or DTE.Quit failed, the IDE process is killed
        (Stop-Process -Force, then up to 10 s until it is gone; data.killed = true,
        success = true). Only for an IDE this session launched (data.ownedBySession, i.e.
        Connect-TcIde selectedBy 'launched'; this survives Reset-TcSolution's internal
        reconnect and, #73, a bridge restart / ReloadModule via launched-ides.json); for any other IDE nothing is killed and the result is IDE_NOT_OWNED
        (kill it yourself with Stop-Process -Id data.ideProcessId if that is really intended).
        Before Stop-Process the pid must still be a TcXaeShell / devenv process started at
        the time Connect-TcIde recorded (+-2 s); otherwise the stored pid is stale, it is
        forgotten and the result is IDE_QUIT_FAILED (killed = false). A pid that no longer
        exists at all means the IDE already exited: success, killed = false,
        alreadyExited = true.

        State: on the paths that attempted Solution.Close / DTE.Quit (and the kill path) the
        COM references are released. On their failure paths (IDE_QUIT_FAILED, IDE_NOT_OWNED)
        the IDE identity (process id, start time, selectedBy, solution path) is KEPT so that
        `Disconnect-TcIde -Quit -Kill` can follow directly without a reconnect. It is cleared
        after a successful quit or kill, after a plain Disconnect-TcIde (no -Quit), and
        overwritten by Connect-TcIde. A -Quit -Kill call with no COM connection but a kept
        process id goes straight to the kill path; -Quit alone then reports 'not connected'.
    .PARAMETER Quit
        Also close the solution (without saving) and quit the IDE instance this
        session is connected to. Only for an IDE that Connect-TcIde launched in this session
        (data.ownedBySession); any other IDE -> IDE_NOT_OWNED, nothing closed (#227).
    .PARAMETER Kill
        Only with -Quit: if the IDE cannot be quit (modal dialog, DTE.Quit failed, or an
        earlier -Quit already failed), kill the IDE process. Refused with IDE_NOT_OWNED
        unless this session launched that IDE (data.ownedBySession). -Kill without -Quit
        is INVALID_PARAMS.
    .PARAMETER ForgetPendingLaunch
        Only forget the launch records of IDEs this session launched whose process id could not
        be confirmed (Connect-TcIde IDE_LAUNCH_PENDING with data.probe 'pid-unconfirmed'), also
        the ones persisted in launched-ides.json by an earlier module instance / bridge (#149),
        so the next Connect-TcIde -SolutionPath may launch again. Closes nothing, keeps the
        connection (data.forgottenLaunches; LAUNCH_RECORD_UNAVAILABLE when the file could not be
        updated; records of another TcAuto session that is still running are kept,
        data.otherSessionLaunches). Close that IDE yourself first if it is still running. Not with -Quit / -Kill
        (INVALID_PARAMS).
    .EXAMPLE
        Disconnect-TcIde -Quit          # IDE_QUIT_FAILED (modal up, connection kept) ...
        Disconnect-TcIde -Quit -Kill    # ... then kill it, no reconnect needed
    .OUTPUTS
        data.message, and with -Quit: data.solutionClosed, data.quit, data.quitError,
        data.ideProcessId, data.selectedBy, data.ownedBySession, data.disconnected,
        data.dialog (when a modal was seen), data.killed / data.alreadyExited (kill path),
        data.reason ('not connected' when there was nothing to quit), data.launchRecordWarning
        (launched-ides.json could not be read / written).
        Errors: INVALID_PARAMS, IDE_QUIT_FAILED, IDE_NOT_OWNED, MODAL_SCAN_INCOMPLETE,
        LAUNCH_RECORD_UNAVAILABLE (-ForgetPendingLaunch).
    #>
    [CmdletBinding()]
    param(
        [switch]$Quit,

        [switch]$Kill,

        [switch]$ForgetPendingLaunch
    )

    $script:TcLaunchRecordWarning = $null   # #73: set by a failed read / write of launched-ides.json during this call
    if ($Kill -and -not $Quit) {
        return New-TcResult -Success $false -ErrorMessage '-Kill requires -Quit (Disconnect-TcIde -Quit -Kill).' -ErrorCode 'INVALID_PARAMS'
    }
    if ($ForgetPendingLaunch) {
        if ($Quit) { return New-TcResult -Success $false -ErrorMessage '-ForgetPendingLaunch cannot be combined with -Quit / -Kill.' -ErrorCode 'INVALID_PARAMS' }
        # #147 m-b: the exit for IDE_LAUNCH_PENDING probe 'pid-unconfirmed'; the connection and
        # every IDE process are left alone; #149: the persisted unconfirmed records too
        $cleared = Clear-TcUnconfirmedLaunches
        $forgotten = @($cleared.Dropped)
        $keptOther = @($cleared.Kept)
        $fdata = [PSCustomObject]@{
            message           = "Forgot $($forgotten.Count) launch record(s) with an unconfirmed process id$(if ($keptOther.Count -gt 0) { "; kept $($keptOther.Count) of another TcAuto session that is still running" }); no IDE was closed and the connection is unchanged."
            forgottenLaunches = $forgotten
            otherSessionLaunches = $keptOther
        }
        if ($null -ne $cleared.Failure) {
            # fail closed: the module records are gone, but the file could not be updated
            $fdata | Add-Member -NotePropertyName 'launchRecordWarning' -NotePropertyValue $cleared.Failure
            return New-TcResult -Success $false -ErrorMessage "LAUNCH_RECORD_UNAVAILABLE: the persisted launch records could not be updated ($($cleared.Failure)); a restarted bridge may still refuse to launch for that solution. Retry Disconnect-TcIde -ForgetPendingLaunch." `
                -ErrorCode 'LAUNCH_RECORD_UNAVAILABLE' -Hint (Get-TcErrorHint -Code 'LAUNCH_RECORD_UNAVAILABLE') -Data $fdata
        }
        return New-TcResult -Success $true -Data $fdata
    }

    $ideProcessId = 0
    if ($null -ne $script:TcIdeProcessId) { try { $ideProcessId = [int]$script:TcIdeProcessId } catch { $ideProcessId = 0 } }
    $selectedBy = $script:TcIdeSelectedBy
    # Owned = launched by this module: selectedBy, or the per-process list that survives a failed
    # / later Connect-TcIde (pid + start time, Add-TcLaunchedIde) and, #73, a bridge restart /
    # ReloadModule (launched-ides.json, confirmed pid only; unreadable file = not owned).
    $ownedBySession = ($selectedBy -eq 'launched') -or ($null -ne $script:TcIdeProcessId -and (Test-TcLaunchedIde -ProcessId ([int]$script:TcIdeProcessId)))

    function New-QuitData {
        param([hashtable]$QuitResult, [object]$Dialog, [bool]$Disconnected)
        $d = [PSCustomObject][ordered]@{
            message        = ''
            solutionClosed = $QuitResult.solutionClosed
            quit           = $QuitResult.quit
            quitError      = $QuitResult.error
            ideProcessId   = $ideProcessId
            selectedBy     = $selectedBy
            ownedBySession = $ownedBySession
            disconnected   = $Disconnected
        }
        if ($null -ne $QuitResult.reason) { $d | Add-Member -NotePropertyName 'reason' -NotePropertyValue $QuitResult.reason }
        if (Test-TcModalScanIncomplete $Dialog) {
            # #42: the scan did not complete - reported as unknown, not as a dialog
            $d | Add-Member -NotePropertyName 'scanComplete' -NotePropertyValue $false
            $d | Add-Member -NotePropertyName 'modalScan' -NotePropertyValue (ConvertTo-TcModalScanInfo -Scan $Dialog)
        }
        elseif ($null -ne $Dialog) {
            $rec = Add-TcDialogKind -Dialog $Dialog
            $d | Add-Member -NotePropertyName 'dialog' -NotePropertyValue ([PSCustomObject][ordered]@{
                    title = $rec.Title; text = $rec.Text; kind = $rec.Kind; reloadTarget = $rec.ReloadTarget
                })
        }
        $d
    }
    # #73: launched-ides.json could not be read / written during this call
    function Add-LaunchRecordWarning([object]$D) {
        if ($null -ne $script:TcLaunchRecordWarning) { $D | Add-Member -NotePropertyName 'launchRecordWarning' -NotePropertyValue $script:TcLaunchRecordWarning -Force }
        $D
    }

    # #227: -Quit (with or without -Kill) only for an IDE this session launched. Any other IDE
    # (solution-match / first-instance / process-id #210 ... on an IDE the user opened) is refused
    # before the modal check, Solution.Close or DTE.Quit: nothing is closed, the connection is kept.
    # Not connected and no pid kept: nothing to quit (the 'not connected' success below).
    $hasIde = ($null -ne $script:TcDte -and $script:TcIdeConnected) -or $ideProcessId -gt 0
    if ($Quit -and $hasIde -and -not $ownedBySession) {
        $data = New-QuitData -QuitResult @{ solutionClosed = $false; quit = $false; error = $null; reason = 'not launched by this session' } -Dialog $null -Disconnected $false
        $data.message = "NOT disconnected; IDE NOT quit: it was not launched by this session (selectedBy '$selectedBy'). The connection is kept; Disconnect-TcIde without -Quit releases it."
        return New-TcResult -Success $false `
            -ErrorMessage "IDE_NOT_OWNED: the IDE (pid $ideProcessId, selectedBy '$selectedBy') was not launched by this session; -Quit$(if ($Kill) { ' -Kill' }) refused, nothing was closed." `
            -ErrorCode 'IDE_NOT_OWNED' -Hint (Get-TcErrorHint -Code 'IDE_NOT_OWNED') -Data $data
    }

    $quitResult = $null
    $dialog = $null
    $wantKill = $false
    if ($Quit -and ($null -eq $script:TcDte -or -not $script:TcIdeConnected)) {
        if ($Kill -and $ideProcessId -gt 0) {
            # A previous -Quit failed (state kept) or the COM link is gone: kill what we still know.
            $quitResult = @{ solutionClosed = $false; quit = $false; error = 'not connected (COM references already released); quit not attempted'; reason = $null }
            $dialog = Find-TcIdeModalDialog
            $wantKill = $true
        }
        else {
            # Nothing to quit: never connected, already disconnected, or the IDE state was reset
            # after IDE_CRASHED. Reported as success with quit = false instead of a COM error text.
            $quitResult = @{ solutionClosed = $false; quit = $false; error = $null; reason = 'not connected' }
        }
    }
    elseif ($Quit) {
        $quitResult = @{ solutionClosed = $false; quit = $false; error = $null; reason = $null }
        # A modal dialog blocks Solution.Close / DTE.Quit forever: check first, do not spend
        # 2 x 60 s in Invoke-TcComRetry.
        $dialog = Find-TcIdeModalDialog
        if (Test-TcModalScanIncomplete $dialog) {
            # #42: unknown whether a dialog blocks Solution.Close / DTE.Quit - never read as "no dialog".
            # -Kill: the kill path (as for a dialog); otherwise nothing is attempted, connection kept.
            $quitResult.error = 'modal dialog scan incomplete: unknown whether a dialog is up'
            if ($Kill) { $wantKill = $true }
            else {
                $data = New-QuitData -QuitResult $quitResult -Dialog $dialog -Disconnected $false
                $data.message = 'NOT disconnected; IDE NOT quit: the modal-dialog scan did not complete, Solution.Close / DTE.Quit not attempted. The connection is kept.'
                return New-TcModalScanIncompleteResult -Scan $dialog -Operation 'Disconnect-TcIde -Quit (Solution.Close / DTE.Quit; connection kept)' -Data $data `
                    -HintSuffix ([string]$script:TcHintFragments['MODAL_SCAN_INCOMPLETE_QUIT'])
            }
        }
        elseif ($null -ne $dialog) {
            $quitResult.error = "modal dialog is up: $($dialog.Title)"
            if ($Kill) { $wantKill = $true }
            else {
                # Nothing was attempted, so the DTE is still valid: keep the whole connection
                # (Reset-TcSolution can clear a reload prompt, then -Quit again).
                $data = New-QuitData -QuitResult $quitResult -Dialog $dialog -Disconnected $false
                $data.message = "NOT disconnected; IDE NOT quit: a modal dialog ($($data.dialog.kind)) is up, Solution.Close / DTE.Quit not attempted. The connection is kept."
                return New-TcResult -Success $false `
                    -ErrorMessage "IDE_QUIT_FAILED: the IDE (pid $ideProcessId) shows a modal dialog ($($data.dialog.kind)): '$($data.dialog.title)'; quit not attempted, connection kept" `
                    -ErrorCode 'IDE_QUIT_FAILED' -Hint (Get-TcErrorHint -Code 'IDE_QUIT_FAILED') -Data $data
            }
        }
        else {
            $dte = $script:TcDte
            try {
                Invoke-TcComRetry -OperationName 'Solution.Close' -TimeoutSec 60 -ScriptBlock {
                    $sol = $dte.Solution
                    if ($null -eq $sol) { throw 'DTE.Solution is null (the DTE reference is no longer usable)' }
                    $sol.Close($false)
                } | Out-Null
                $quitResult.solutionClosed = $true
            }
            catch { $quitResult.error = "Solution.Close: $($_.Exception.Message)" }
            try {
                Invoke-TcComRetry -OperationName 'DTE.Quit' -TimeoutSec 60 -ScriptBlock { $dte.Quit() } | Out-Null
                $quitResult.quit = $true
            }
            catch {
                # The IDE drops the RPC connection while it exits, so DTE.Quit() itself usually fails
                # with a dead-RPC error (or IDE_CRASHED from Invoke-TcComRetry once the process is
                # gone). That is the expected outcome of a successful quit, not a crash.
                if ($_.Exception.Message -match 'IDE_CRASHED|0x80010108|0x800706BE|0x800706BA') {
                    $quitResult.quit = $true
                }
                else {
                    $quitResult.error = (($quitResult.error, "DTE.Quit: $($_.Exception.Message)") -ne $null) -join '; '
                }
            }
            if (-not $quitResult.quit -and $Kill) { $wantKill = $true }
        }
    }

    # Restore the SilentMode value Connect-TcIde found, unless the IDE was quit (or is blocked).
    if (-not $Quit -and $null -ne $script:TcAutomationSettings -and $null -ne $script:TcSilentModeOriginal) {
        $settingsRestore = $script:TcAutomationSettings
        $silentRestore = [bool]$script:TcSilentModeOriginal
        try {
            Invoke-TcComRetry -OperationName 'SilentMode restore' -ScriptBlock { $settingsRestore.SilentMode = $silentRestore } | Out-Null
            # Restored: the next connect reads the (now original) value again.
            if ($null -ne $script:TcIdeProcessId) { Set-TcIdeSilentOriginal -ProcessId ([int]$script:TcIdeProcessId) -Value $null }
        }
        catch { Write-Verbose "SilentMode could not be restored to $silentRestore ($($_.Exception.Message))" }
    }

    # --- release every COM reference; the IDE identity is cleared separately ---
    if ($null -ne $script:TcAutomationSettings) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcAutomationSettings) | Out-Null } catch { }
    }
    $script:TcAutomationSettings = $null
    $script:TcSilentMode = $false
    $script:TcSilentModeOriginal = $null

    if ($null -ne $script:TcSysManager) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
        $script:TcSysManager = $null
    }

    if ($null -ne $script:TcDte) {
        try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcDte) | Out-Null } catch { }
        $script:TcDte = $null
    }

    $script:TcIdeConnected = $false
    $script:TcProgId = $null
    $script:TcIdeMainHwnd = 0
    $script:TcLastModalDialog = $null

    # Forget the IDE identity. Not done on the failure paths, so a following
    # `Disconnect-TcIde -Quit -Kill` still knows which process to kill.
    function Clear-IdeIdentity {
        $script:TcSolutionPath = $null
        $script:TcIdeProcessId = $null
        $script:TcIdeStartTime = $null
        $script:TcIdeSelectedBy = $null
    }

    if ($null -eq $quitResult) {
        Clear-IdeIdentity
        return New-TcResult -Success $true -Data ([PSCustomObject]@{ message = 'Disconnected from TwinCAT IDE.' })
    }

    $data = New-QuitData -QuitResult $quitResult -Dialog $dialog -Disconnected $true

    if ($quitResult.reason -eq 'not connected') {
        $data.message = 'Not connected to an IDE; nothing to quit.'
        return New-TcResult -Success $true -Data $data
    }
    if ($quitResult.quit) {
        # #73: the IDE is gone (or going): its launch record no longer belongs to anyone
        if ($ideProcessId -gt 0) { $null = Remove-TcLaunchRecord -ProcessId $ideProcessId }
        Clear-IdeIdentity
        $data.message = 'Disconnected and IDE quit.'
        return New-TcResult -Success $true -Data (Add-LaunchRecordWarning $data)
    }

    # --- quit did not happen (identity kept for a follow-up -Quit -Kill) ---
    if (-not $wantKill) {
        $data.message = 'Disconnected; IDE quit failed (see quitError). The IDE process is still running.'
        return New-TcResult -Success $false -ErrorMessage "IDE_QUIT_FAILED: the IDE (pid $ideProcessId) could not be quit: $($quitResult.error)" `
            -ErrorCode 'IDE_QUIT_FAILED' -Hint (Get-TcErrorHint -Code 'IDE_QUIT_FAILED') -Data $data
    }

    # --- kill path (-Quit -Kill) ---
    $data | Add-Member -NotePropertyName 'killed' -NotePropertyValue $false
    if (-not $ownedBySession) {
        $data.message = "Disconnected; IDE NOT quit and NOT killed: it was not launched by this session (selectedBy '$selectedBy')."
        $data = Add-LaunchRecordWarning $data
        return New-TcResult -Success $false `
            -ErrorMessage "IDE_NOT_OWNED: the IDE (pid $ideProcessId, selectedBy '$selectedBy') was not launched by this session; -Kill refused. Quit failed: $($quitResult.error)" `
            -ErrorCode 'IDE_NOT_OWNED' -Hint (Get-TcErrorHint -Code 'IDE_NOT_OWNED') -Data $data
    }
    if ($ideProcessId -le 0) {
        $data.message = 'Disconnected; IDE quit failed and its process id is unknown, nothing killed.'
        return New-TcResult -Success $false -ErrorMessage "IDE_QUIT_FAILED: IDE process id unknown, cannot kill. Quit failed: $($quitResult.error)" `
            -ErrorCode 'IDE_QUIT_FAILED' -Hint (Get-TcErrorHint -Code 'IDE_QUIT_FAILED') -Data $data
    }

    # Safety: the stored pid must still be the IDE process Connect-TcIde saw (TcXaeShell.exe /
    # devenv.exe, see Get-TcIdeExeName, same start time +-2 s); a recycled pid is never killed.
    $proc = Get-Process -Id $ideProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        $null = Remove-TcLaunchRecord -ProcessId $ideProcessId   # #73: already exited
        Clear-IdeIdentity
        $data | Add-Member -NotePropertyName 'alreadyExited' -NotePropertyValue $true
        $data.message = "Disconnected; IDE pid $ideProcessId had already exited, nothing to kill."
        return New-TcResult -Success $true -Data (Add-LaunchRecordWarning $data)
    }
    $procName = [string]$proc.ProcessName
    $why = $null
    if (@('TcXaeShell', 'devenv') -notcontains $procName) { $why = "is now '$procName', not an IDE" }
    elseif ($null -ne $script:TcIdeStartTime) {
        $start = $null
        try { $start = $proc.StartTime } catch { $start = $null }
        if ($null -ne $start -and [math]::Abs(($start - [DateTime]$script:TcIdeStartTime).TotalSeconds) -gt 2) {
            $why = "was started at $($start.ToString('HH:mm:ss')), not at $(([DateTime]$script:TcIdeStartTime).ToString('HH:mm:ss')) as recorded by Connect-TcIde"
        }
    }
    if ($null -ne $why) {
        Clear-IdeIdentity
        $data.message = "Disconnected; nothing killed: pid $ideProcessId $why (stale pid, forgotten)."
        return New-TcResult -Success $false -ErrorMessage "IDE_QUIT_FAILED: stored IDE pid $ideProcessId $why; not killed (stale pid)." `
            -ErrorCode 'IDE_QUIT_FAILED' -Hint (Get-TcErrorHint -Code 'IDE_QUIT_FAILED') -Data $data
    }

    try { Stop-Process -Id $ideProcessId -Force -ErrorAction Stop } catch { Write-Verbose "Stop-Process $ideProcessId : $($_.Exception.Message)" }
    $deadline = [DateTime]::Now.AddSeconds(10)
    $gone = $false
    while ($true) {
        if ($null -eq (Get-Process -Id $ideProcessId -ErrorAction SilentlyContinue)) { $gone = $true; break }
        if ([DateTime]::Now -ge $deadline) { break }
        Start-Sleep -Milliseconds 250
    }
    if (-not $gone) {
        $data.message = "Disconnected; IDE quit failed and pid $ideProcessId is still running 10 s after Stop-Process."
        return New-TcResult -Success $false -ErrorMessage "IDE_QUIT_FAILED: IDE pid $ideProcessId still running 10 s after Stop-Process -Force." `
            -ErrorCode 'IDE_QUIT_FAILED' -Hint (Get-TcErrorHint -Code 'IDE_QUIT_FAILED') -Data $data
    }
    $null = Remove-TcLaunchRecord -ProcessId $ideProcessId   # #73: killed
    Clear-IdeIdentity
    $data.killed = $true
    $data.message = "Disconnected; IDE could not be quit and was killed (pid $ideProcessId)."
    New-TcResult -Success $true -Data (Add-LaunchRecordWarning $data)
}
