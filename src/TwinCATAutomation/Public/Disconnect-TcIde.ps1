function Disconnect-TcIde {
    <#
    .SYNOPSIS
        Disconnects from the TwinCAT IDE and releases COM references.
    .DESCRIPTION
        Without -Quit only the COM references are released; the IDE keeps running.

        With -Quit:
          1. Get-TcIdeModalDialog first. A modal dialog blocks Solution.Close / DTE.Quit
             forever, so with a dialog up (and no -Kill) nothing is attempted (no 60 s
             retries) and NOTHING is released: the connection stays usable. Result:
             success = false, code IDE_QUIT_FAILED, data.disconnected = false, data.quit =
             false, data.quitError = 'modal dialog is up: <title>', data.dialog = {title,
             text, kind, reloadTarget}. A reload prompt (kind reload-prompt): run
             Reset-TcSolution, then Disconnect-TcIde -Quit again. Anything else: -Quit -Kill
             (launched IDE) or Stop-Process -Id data.ideProcessId.
          2. Solution.Close($false) + DTE.Quit(). When the quit does not succeed the result
             is success = false, code IDE_QUIT_FAILED (data.solutionClosed / quit / quitError /
             ideProcessId / selectedBy, data.disconnected = true); the COM references are
             released, the IDE process is still running.
        With -Quit -Kill: when a dialog is up or DTE.Quit failed, the IDE process is killed
        (Stop-Process -Force, then up to 10 s until it is gone; data.killed = true,
        success = true). Only for an IDE this session launched (data.ownedBySession, i.e.
        Connect-TcIde selectedBy 'launched'; this survives Reset-TcSolution's internal
        reconnect); for any other IDE nothing is killed and the result is IDE_NOT_OWNED
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
        session is connected to. Use this to clean up an IDE that Connect-TcIde
        launched; do not use it on an IDE the user opened themselves.
    .PARAMETER Kill
        Only with -Quit: if the IDE cannot be quit (modal dialog, DTE.Quit failed, or an
        earlier -Quit already failed), kill the IDE process. Refused with IDE_NOT_OWNED
        unless this session launched that IDE (data.ownedBySession). -Kill without -Quit
        is INVALID_PARAMS.
    .EXAMPLE
        Disconnect-TcIde -Quit          # IDE_QUIT_FAILED (modal up, connection kept) ...
        Disconnect-TcIde -Quit -Kill    # ... then kill it, no reconnect needed
    .OUTPUTS
        data.message, and with -Quit: data.solutionClosed, data.quit, data.quitError,
        data.ideProcessId, data.selectedBy, data.ownedBySession, data.disconnected,
        data.dialog (when a modal was seen), data.killed / data.alreadyExited (kill path),
        data.reason ('not connected' when there was nothing to quit).
        Errors: INVALID_PARAMS, IDE_QUIT_FAILED, IDE_NOT_OWNED.
    #>
    [CmdletBinding()]
    param(
        [switch]$Quit,

        [switch]$Kill
    )

    if ($Kill -and -not $Quit) {
        return New-TcResult -Success $false -ErrorMessage '-Kill requires -Quit (Disconnect-TcIde -Quit -Kill).' -ErrorCode 'INVALID_PARAMS'
    }

    $ideProcessId = 0
    if ($null -ne $script:TcIdeProcessId) { try { $ideProcessId = [int]$script:TcIdeProcessId } catch { $ideProcessId = 0 } }
    $selectedBy = $script:TcIdeSelectedBy
    $ownedBySession = ($selectedBy -eq 'launched')

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
        if ($null -ne $Dialog) {
            $rec = Add-TcDialogKind -Dialog $Dialog
            $d | Add-Member -NotePropertyName 'dialog' -NotePropertyValue ([PSCustomObject][ordered]@{
                    title = $rec.Title; text = $rec.Text; kind = $rec.Kind; reloadTarget = $rec.ReloadTarget
                })
        }
        $d
    }

    $quitResult = $null
    $dialog = $null
    $wantKill = $false
    if ($Quit -and ($null -eq $script:TcDte -or -not $script:TcIdeConnected)) {
        if ($Kill -and $ideProcessId -gt 0) {
            # A previous -Quit failed (state kept) or the COM link is gone: kill what we still know.
            $quitResult = @{ solutionClosed = $false; quit = $false; error = 'not connected (COM references already released); quit not attempted'; reason = $null }
            $dialog = Get-TcIdeModalDialog
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
        $dialog = Get-TcIdeModalDialog
        if ($null -ne $dialog) {
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
        Clear-IdeIdentity
        $data.message = 'Disconnected and IDE quit.'
        return New-TcResult -Success $true -Data $data
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
        Clear-IdeIdentity
        $data | Add-Member -NotePropertyName 'alreadyExited' -NotePropertyValue $true
        $data.message = "Disconnected; IDE pid $ideProcessId had already exited, nothing to kill."
        return New-TcResult -Success $true -Data $data
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
    Clear-IdeIdentity
    $data.killed = $true
    $data.message = "Disconnected; IDE could not be quit and was killed (pid $ideProcessId)."
    New-TcResult -Success $true -Data $data
}
