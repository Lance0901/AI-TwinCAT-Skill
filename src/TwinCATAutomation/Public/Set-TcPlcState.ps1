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

    try { $reconnected = Ensure-TcAdsConnection } catch {
        if ($State -eq 'Run') {
            $mappedEnsure = ConvertTo-TcAdsErrorCode -InputObject $_
            if ($null -ne $mappedEnsure -and $mappedEnsure.Code -eq 'ADS_PORT_NOT_FOUND') {
                return New-TcResult -Success $false `
                    -ErrorMessage "PLC runtime port $($script:TcAdsPort) not found - no PLC program has been downloaded: $($_.Exception.Message)" `
                    -ErrorCode 'PLC_NOT_LOADED' `
                    -Hint (Get-TcErrorHint -Code 'PLC_NOT_LOADED') `
                    -Data ([PSCustomObject]@{ requestedState = $State; currentState = $null; reconnected = $false })
            }
        }
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
    }

    $stateMap = @{
        'Run'   = 5   # AdsState.Run
        'Stop'  = 6   # AdsState.Stop
        'Reset' = 2   # AdsState.Reset
    }

    try {
        # Run requires a downloaded program: check before sending WriteControl
        if ($State -eq 'Run') {
            $stateBefore = $null
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
                return New-TcResult -Success $true -Data ([PSCustomObject]@{
                    requestedState = $State
                    currentState   = 'Run'
                    reconnected    = $reconnected
                    elapsedMs      = 0
                    alreadyInState = $true
                })
            }
        }

        $targetState = $stateMap[$State]
        $newStateInfo = New-Object TwinCAT.Ads.StateInfo
        $newStateInfo.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], $targetState)
        $newStateInfo.DeviceState = 0
        $script:TcAdsClient.WriteControl($newStateInfo)

        if ($State -eq 'Run' -or $State -eq 'Stop') {
            # Poll the port until it reports the target state (separate temporary client)
            $wait = Wait-TcAdsState -AmsNetId $script:TcAdsAmsNetId -Port $script:TcAdsPort -TargetState $State -TimeoutSec $TimeoutSec
            $data = [PSCustomObject]@{
                requestedState = $State
                currentState   = $wait.State
                reconnected    = $reconnected
                elapsedMs      = $wait.ElapsedMs
            }
            if (-not $wait.Reached) {
                $detail = if ($wait.LastError) { " Last error: $($wait.LastError)" } else { '' }
                $code = if ($State -eq 'Run') { 'PLC_RUN_TIMEOUT' } else { 'STATE_SET_FAILED' }
                $params = @{
                    Success      = $false
                    ErrorMessage = "PLC did not reach '$State' within $TimeoutSec s (last state: $($wait.State)).$detail"
                    ErrorCode    = $code
                    Data         = $data
                }
                $hint = Get-TcErrorHint -Code $code
                if (-not [string]::IsNullOrWhiteSpace($hint)) { $params['Hint'] = $hint }
                return New-TcResult @params
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
