function Set-TcPlcState {
    <#
    .SYNOPSIS
        Sets the PLC runtime state (Run, Stop, Reset) via ADS.
    .DESCRIPTION
        Sends ADS WriteControl to the module PLC session (port 851 by default).
        For -State Run the current state is read first: when the runtime reports
        AdsState Invalid, or port 851 does not exist yet (ADS 0x6, also when the
        auto-reconnect fails for that reason), no program has been downloaded and
        PLC_NOT_LOADED is returned without sending WriteControl.
        Use Enter-TcPlcOnline (or Enable-TcConfig -Force) to download first.
        For Run and Stop the port is then polled until it reports the target state;
        if it does not within -TimeoutSec, PLC_RUN_TIMEOUT (Run) or STATE_SET_FAILED
        (Stop) is returned. Reset is verified with a single read after 200 ms.
        Reported states for Run / Stop (#131, same rule as Set-TcSystemState #114): data.currentState /
        finalState is 'Unreachable' when the last read of the port failed (ADS error, e.g. a runtime
        crash during the wait), never the last state read before it (that one is data.lastState, the
        error data.lastError; both always present, lastError $null when the last read succeeded).
        data.originalState is the state read before WriteControl ($null when it could not be read);
        data.leftOriginal is $true only when a read RETURNED a state other than it ($null when the
        original is unknown); failed reads during the wait are data.unreachableSeen ($true whenever
        currentState is 'Unreachable', also when the wait could not probe at all). Run on a PLC that
        already runs returns the same fields (alreadyInState, nothing sent). A failure also
        carries the wait's probe log (data.probeErrors, data.probeErrorsDropped), and the lifecycle
        block's reachedState is then empty (readbackNote 'unreachable').
        Fail closed (#68): those two readback failures come after WriteControl was sent and also
        record a lifecycle block for the session's AmsNetId (data.lifecycleBlock). While a block
        exists for it, Set-TcPlcState returns LIFECYCLE_BLOCKED and sends nothing (every -State);
        only Clear-TcLifecycleBlock (after the user agreed) removes it.
        TwinCAT system state (#287): before any WriteControl (every -State) port 10000 of the same
        target is read once. AdsState 19 Exception -> SYSTEM_EXCEPTION (data.systemState, adsState,
        readAt; measured 2026-11-13: PLC-level Run and Reset did not recover it, Enable-TcConfig
        -Force did; Stop is refused as well, conservatively, since nothing PLC-level helps; on a
        local UmRT the same runtime process crashed after ANY PLC exception even after that
        Activate, so the hint asks for a runtime restart first); an
        unreadable port 10000 -> SYSTEM_STATE_FAILED (data.readError, fail closed). Both send
        nothing and record no lifecycle block. Run postcondition: after the PLC port reached Run,
        the PLC port AND port 10000 must both read Run in every round of a short confirm window
        (1500 ms and at least 3 rounds, Confirm-TcPlcRunStable; measured 2026-11-13: TwinCAT fell
        back from Run to Config within about one second); the first round that is not Run on
        either port ends it with RUNTIME_STATE_MISMATCH and a lifecycle block (Run was sent).
        data.systemState / systemAdsState / systemStateReadAt are the last port 10000 read,
        data.runConfirm the window (ok, samples, elapsedMs, windowMs, minSamples, failedPort,
        plcState, error), data.systemStateBefore the read before the request. A PLC already in Run
        already in Run (nothing sent) gets the same check: port 10000 not Run, or a confirm round
        that is not Run, is RUNTIME_STATE_MISMATCH without a block. On a confirm failure
        data.currentState / finalState stay the last PLC port read (Run when port 10000 failed),
        data.reached = $false. The confirm window is not part of -TimeoutSec (up to ~1.5 s more).
    .PARAMETER State
        Target state: Run, Stop, or Reset.
    .PARAMETER TimeoutSec
        Maximum wait for Run/Stop to be reached. Default 30.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Stop', 'Reset')]
        [string]$State,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 30
    )

    $ensureError = $null
    $reconnected = $false
    try { $reconnected = Ensure-TcAdsConnection } catch { $ensureError = $_ }
    # #68 (N2): checked with the session's AmsNetId after Ensure-TcAdsConnection. A failed
    # (re)connect with a known AmsNetId is still checked (fail closed); a session that never had
    # an AmsNetId returns the connect error as before (nothing can be sent without a session).
    if ($null -eq $ensureError -or -not [string]::IsNullOrWhiteSpace([string]$script:TcAdsAmsNetId)) {
        $blocked = Test-TcLifecycleBlock -AmsNetId ([string]$script:TcAdsAmsNetId) -Command 'Set-TcPlcState'
        if ($null -ne $blocked) { $blocked.data | Add-Member -NotePropertyName 'requestedState' -NotePropertyValue $State -Force; return $blocked }
    }
    if ($null -ne $ensureError) {
        if ($State -eq 'Run') {
            $mappedEnsure = ConvertTo-TcAdsErrorCode -InputObject $ensureError
            if ($null -ne $mappedEnsure -and $mappedEnsure.Code -eq 'ADS_PORT_NOT_FOUND') {
                return New-TcResult -Success $false `
                    -ErrorMessage "PLC runtime port $($script:TcAdsPort) not found - no PLC program has been downloaded: $($ensureError.Exception.Message)" `
                    -ErrorCode 'PLC_NOT_LOADED' `
                    -Hint (Get-TcErrorHint -Code 'PLC_NOT_LOADED') `
                    -Data ([PSCustomObject]@{ requestedState = $State; currentState = $null; reconnected = $false })
            }
        }
        return New-TcAdsErrorResult -ErrorRecord $ensureError -DefaultCode 'NOT_CONNECTED'
    }

    # #287: the TwinCAT system state (port 10000) decides first, before any WriteControl. A system in
    # Exception (AdsState 19) is not recovered by a PLC-level Run / Stop / Reset (measured 2026-11-13,
    # Private/Read-TcSystemAdsState.ps1), and an unreadable port 10000 is no evidence that it is safe
    # (fail closed). Nothing was sent in either case: no in-flight marker, no lifecycle block.
    $netIdNow = [string]$script:TcAdsAmsNetId
    $sysBefore = Read-TcSystemAdsState -AmsNetId $netIdNow
    if (-not $sysBefore.ok) {
        return New-TcResult -Success $false `
            -ErrorMessage "Could not read the TwinCAT system state (ADS port 10000) of $netIdNow before the PLC '$State' request: $($sysBefore.error). Nothing was sent to the PLC." `
            -ErrorCode 'SYSTEM_STATE_FAILED' `
            -Hint $script:TcPlcSystemUnreadableHint `
            -Data ([PSCustomObject]@{
                requestedState   = $State
                systemState      = $null
                adsState         = $null
                readAt           = $sysBefore.readAt
                port             = 10000
                amsNetId         = $netIdNow
                readError        = $sysBefore.error
                readErrorCode    = $sysBefore.errorCode
                writeControlSent = $false
                reconnected      = $reconnected
            })
    }
    if ($sysBefore.adsState -eq $script:TcAdsStateException) {
        return New-TcResult -Success $false `
            -ErrorMessage "TwinCAT system (ADS port 10000 of $netIdNow) is in Exception (adsState $($sysBefore.adsState)); the PLC '$State' request was not sent." `
            -ErrorCode 'SYSTEM_EXCEPTION' `
            -Hint (Get-TcErrorHint -Code 'SYSTEM_EXCEPTION') `
            -Data ([PSCustomObject]@{
                requestedState   = $State
                systemState      = $sysBefore.state
                adsState         = $sysBefore.adsState
                readAt           = $sysBefore.readAt
                port             = 10000
                amsNetId         = $netIdNow
                writeControlSent = $false
                reconnected      = $reconnected
            })
    }

    $stateMap = @{
        'Run'   = 5   # AdsState.Run
        'Stop'  = 6   # AdsState.Stop
        'Reset' = 2   # AdsState.Reset
    }

    $inflight = $null   # #236: marker while the request is pending (a killed process leaves it -> block)
    try {
        # #131: state before the request (data.originalState / leftOriginal); Run reads it below
        $stateBefore = $null
        if ($State -eq 'Stop') {
            try { $stateBefore = $script:TcAdsClient.ReadState() } catch { $stateBefore = $null }
        }
        # Run requires a downloaded program: check before sending WriteControl
        if ($State -eq 'Run') {
            try {
                $stateBefore = $script:TcAdsClient.ReadState()
            }
            catch {
                $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
                if ($null -ne $mapped -and $mapped.Code -eq 'ADS_PORT_NOT_FOUND') {
                    return New-TcResult -Success $false `
                        -ErrorMessage "PLC runtime port $($script:TcAdsPort) not found - no PLC program has been downloaded: $($_.Exception.Message)" `
                        -ErrorCode 'PLC_NOT_LOADED' `
                        -Hint (Get-TcErrorHint -Code 'PLC_NOT_LOADED') `
                        -Data ([PSCustomObject]@{ requestedState = $State; currentState = $null; reconnected = $reconnected })
                }
                throw
            }
            if ([int]$stateBefore.AdsState -eq 0) {
                return New-TcResult -Success $false `
                    -ErrorMessage 'PLC runtime reports AdsState Invalid - no PLC program has been downloaded.' `
                    -ErrorCode 'PLC_NOT_LOADED' `
                    -Hint (Get-TcErrorHint -Code 'PLC_NOT_LOADED') `
                    -Data ([PSCustomObject]@{ requestedState = $State; currentState = 'Invalid'; reconnected = $reconnected })
            }
            # Already running (e.g. boot project autostart): WriteControl Run would answer
            # ADS 0x712 "invalid state", so treat it as done.
            if ([int]$stateBefore.AdsState -eq 5) {
                # #287: a PLC port in Run is only "Run" when the system is in Run too, through the same
                # confirm window as the polled path (nothing sent: a failure records no block)
                $confirm = $null
                if ($sysBefore.adsState -eq $script:TcAdsStateRun) {
                    $confirm = Confirm-TcPlcRunStable -AmsNetId $netIdNow -Port ([int]$script:TcAdsPort)
                }
                if ($null -eq $confirm -or -not $confirm.ok) {
                    $sysNow = if ($null -ne $confirm) { $confirm } else { [PSCustomObject]@{ systemState = $sysBefore.state; systemAdsState = $sysBefore.adsState; systemStateReadAt = $sysBefore.readAt; error = "port 10000 reads $($sysBefore.state) (adsState $($sysBefore.adsState)), expected Run"; plcState = 'Run'; failedPort = 10000 } }
                    $plcNow = if ($sysNow.failedPort -eq [int]$script:TcAdsPort) { $sysNow.plcState } else { 'Run' }
                    $mm = [PSCustomObject]@{
                        requestedState    = $State
                        originalState     = 'Run'
                        currentState      = $plcNow
                        finalState        = $plcNow
                        reached           = $false
                        systemState       = $sysNow.systemState
                        systemAdsState    = $sysNow.systemAdsState
                        systemStateReadAt = $sysNow.systemStateReadAt
                        systemStateBefore = $sysBefore.state
                        writeControlSent  = $false
                        reconnected       = $reconnected
                    }
                    if ($null -ne $confirm) { $mm | Add-Member -NotePropertyName 'runConfirm' -NotePropertyValue $confirm -Force }
                    return New-TcResult -Success $false `
                        -ErrorMessage "PLC port $($script:TcAdsPort) was already in Run, but Run is not confirmed: $($sysNow.error); nothing was sent." `
                        -ErrorCode 'RUNTIME_STATE_MISMATCH' `
                        -Hint $script:TcPlcRunSystemMismatchHint `
                        -Data $mm
                }
                # #131: same fields as the polled path (nothing sent, the read before is the readback)
                return New-TcResult -Success $true -Data ([PSCustomObject]@{
                    requestedState  = $State
                    originalState   = 'Run'
                    currentState    = 'Run'
                    finalState      = 'Run'
                    lastState       = 'Run'
                    lastError       = $null
                    leftOriginal    = $false
                    unreachableSeen = $false
                    reconnected     = $reconnected
                    elapsedMs       = 0
                    alreadyInState  = $true
                    systemState       = $confirm.systemState
                    systemAdsState    = $confirm.systemAdsState
                    systemStateReadAt = $confirm.systemStateReadAt
                    systemStateBefore = $sysBefore.state
                    runConfirm        = [PSCustomObject]@{
                        ok = $confirm.ok; samples = $confirm.samples; elapsedMs = $confirm.elapsedMs
                        windowMs = $confirm.windowMs; minSamples = $confirm.minSamples
                        failedPort = $confirm.failedPort; plcState = $confirm.plcState; error = $confirm.error
                    }
                })
            }
        }

        $targetState = $stateMap[$State]
        $newStateInfo = New-Object TwinCAT.Ads.StateInfo
        $newStateInfo.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], $targetState)
        $newStateInfo.DeviceState = 0
        # #236 (PR #244 review): RunTestCycle / PlcLogin can be killed by the MCP modal probe while this waits
        $inflight = Enter-TcLifecycleInflight -Command 'Set-TcPlcState' -AmsNetId ([string]$script:TcAdsAmsNetId) -RequestedState $State -Step "PLC state request (port $($script:TcAdsPort))"
        $script:TcAdsClient.WriteControl($newStateInfo)  # tcauto-allow(writecontrol): Set-TcPlcState itself; Run / Stop polled until reached, failure -> lifecycle block

        if ($State -eq 'Run' -or $State -eq 'Stop') {
            # Poll the port until it reports the target state (separate temporary client)
            $wait = Wait-TcAdsState -AmsNetId $script:TcAdsAmsNetId -Port $script:TcAdsPort -TargetState $State -TimeoutSec $TimeoutSec
            # #131 (same rule as Set-TcSystemState #114): Wait-TcAdsState.State is the last state READ;
            # a later failed probe keeps it. When the last probe failed the state is 'Unreachable',
            # the last value read goes to data.lastState (the original state when nothing was read).
            $original = if ($null -ne $stateBefore) { [string]$stateBefore.AdsState } else { $null }
            $lastReadFailed = -not [string]::IsNullOrEmpty([string]$wait.LastError)
            $seen = if (-not [string]::IsNullOrWhiteSpace([string]$wait.State)) { [string]$wait.State } else { $original }
            $shown = if ($lastReadFailed) { 'Unreachable' } else { [string]$wait.State }
            # leftOriginal only from states that were actually read (failed probes are not states)
            $leftOriginal = $null
            if ($null -ne $original) {
                $leftOriginal = (@(@($wait.StatesSeen) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) -and [string]$_ -ne $original }).Count -gt 0)
            }
            $data = [PSCustomObject]@{
                requestedState  = $State
                originalState   = $original
                currentState    = $shown
                finalState      = $shown
                lastState       = $seen
                lastError       = $(if ($lastReadFailed) { [string]$wait.LastError } else { $null })
                leftOriginal    = $leftOriginal
                # also when the wait returned before any probe (TwinCAT.Ads.dll not found: LastError set,
                # AnyProbeFailed false): currentState is 'Unreachable' then, so this must agree
                unreachableSeen = (($wait.AnyProbeFailed -eq $true) -or $lastReadFailed)
                reconnected     = $reconnected
                elapsedMs       = $wait.ElapsedMs
            }
            if (-not $wait.Reached) {
                $detail = if ($wait.LastError) { " Last error: $($wait.LastError)" } else { '' }
                $code = if ($State -eq 'Run') { 'PLC_RUN_TIMEOUT' } else { 'STATE_SET_FAILED' }
                $last = if ($lastReadFailed) { "unreachable (last state read: $seen)" } else { $shown }
                $data | Add-Member -NotePropertyName 'probeErrors' -NotePropertyValue @($wait.ProbeErrors | Where-Object { $null -ne $_ }) -Force
                $data | Add-Member -NotePropertyName 'probeErrorsDropped' -NotePropertyValue ([int]$wait.ProbeErrorsDropped) -Force
                $params = @{
                    Success      = $false
                    ErrorMessage = "PLC did not reach '$State' within $TimeoutSec s (last state: $last).$detail"
                    ErrorCode    = $code
                    Data         = $data
                }
                $hint = Get-TcErrorHint -Code $code
                if (-not [string]::IsNullOrWhiteSpace($hint)) { $params['Hint'] = $hint }
                # nothing was read back at the end: reachedState empty, the last value read goes to the step text
                $reachedRb = if ($lastReadFailed) { $null } else { $shown }
                $step = if ($lastReadFailed) { "port $($script:TcAdsPort) unreachable at the deadline; last state read before: $seen" } else { "port $($script:TcAdsPort)" }
                $note = if ($lastReadFailed) { 'unreachable' } else { $null }
                return (Add-TcLifecycleBlockResult -Result (New-TcResult @params) -Command 'Set-TcPlcState' -AmsNetId ([string]$script:TcAdsAmsNetId) -RequestedState $State -ReachedState $reachedRb -ReadbackNote $note -Step $step)
            }
            $data | Add-Member -NotePropertyName 'systemStateBefore' -NotePropertyValue $sysBefore.state -Force
            if ($State -eq 'Run') {
                # #287 postcondition: 851 = Run is a snapshot; port 10000 must be Run as well and both
                # must stay Run for the confirm window (Confirm-TcPlcRunStable, constants and the
                # measurement they come from in Private/Read-TcSystemAdsState.ps1).
                $confirm = Confirm-TcPlcRunStable -AmsNetId ([string]$script:TcAdsAmsNetId) -Port ([int]$script:TcAdsPort)
                $data | Add-Member -NotePropertyName 'systemState' -NotePropertyValue $confirm.systemState -Force
                $data | Add-Member -NotePropertyName 'systemAdsState' -NotePropertyValue $confirm.systemAdsState -Force
                $data | Add-Member -NotePropertyName 'systemStateReadAt' -NotePropertyValue $confirm.systemStateReadAt -Force
                $data | Add-Member -NotePropertyName 'runConfirm' -NotePropertyValue ([PSCustomObject]@{
                        ok = $confirm.ok; samples = $confirm.samples; elapsedMs = $confirm.elapsedMs
                        windowMs = $confirm.windowMs; minSamples = $confirm.minSamples
                        failedPort = $confirm.failedPort; plcState = $confirm.plcState; error = $confirm.error
                    }) -Force
                if (-not $confirm.ok) {
                    $data | Add-Member -NotePropertyName 'reached' -NotePropertyValue $false -Force
                    # the PLC state fields describe the last PLC read of the confirm window
                    if ($confirm.failedPort -eq [int]$script:TcAdsPort) {
                        $data.currentState = $confirm.plcState; $data.finalState = $confirm.plcState
                        if ($confirm.plcState -eq 'Unreachable') { $data.unreachableSeen = $true; $data.lastError = $confirm.error }
                        else { $data.lastState = $confirm.plcState }
                    }
                    $sysText = if ($null -ne $confirm.systemState) { "$($confirm.systemState) (adsState $($confirm.systemAdsState))" } else { 'unreadable' }
                    $params = @{
                        Success      = $false
                        ErrorMessage = "PLC port $($script:TcAdsPort) reached Run but did not stay there with the TwinCAT system in Run: $($confirm.error) (after $($confirm.elapsedMs) ms, $($confirm.samples) good round(s)). Run was sent, the runtime changed."
                        ErrorCode    = 'RUNTIME_STATE_MISMATCH'
                        Hint         = $script:TcPlcRunSystemMismatchHint
                        Data         = $data
                    }
                    $reachedRb = if ($confirm.failedPort -eq 10000) { $confirm.systemState } else { $confirm.plcState }
                    if ($reachedRb -eq 'Unreachable') { $reachedRb = $null }
                    # 'unreachable' = the PLC port (block text "nothing (PLC port unreachable)"); an
                    # unreadable port 10000 leaves reachedState and the note empty ("nothing")
                    $note = if ($null -eq $reachedRb -and $confirm.failedPort -ne 10000) { 'unreachable' } else { $null }
                    $step = "port $($script:TcAdsPort) read Run, then within the $($confirm.windowMs) ms confirm window: $($confirm.error); system state $sysText"
                    return (Add-TcLifecycleBlockResult -Result (New-TcResult @params) -Command 'Set-TcPlcState' -AmsNetId ([string]$script:TcAdsAmsNetId) -RequestedState $State -ReachedState $reachedRb -ReadbackNote $note -Step $step)
                }
            }
            return New-TcResult -Success $true -Data $data
        }

        # Reset: single verification read
        Start-Sleep -Milliseconds 200
        $stateInfo = $script:TcAdsClient.ReadState()

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            requestedState = $State
            currentState   = $stateInfo.AdsState.ToString()
            reconnected    = $reconnected
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'STATE_SET_FAILED' -MessagePrefix 'Failed to set PLC state'
    }
    finally {
        Exit-TcLifecycleInflight -Token $inflight
    }
}
