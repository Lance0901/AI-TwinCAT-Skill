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

    $stateMap = @{
        'Run'   = 5   # AdsState.Run
        'Stop'  = 6   # AdsState.Stop
        'Reset' = 2   # AdsState.Reset
    }

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
                })
            }
        }

        $targetState = $stateMap[$State]
        $newStateInfo = New-Object TwinCAT.Ads.StateInfo
        $newStateInfo.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], $targetState)
        $newStateInfo.DeviceState = 0
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
}
