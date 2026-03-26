function Set-TcPlcState {
    <#
    .SYNOPSIS
        Sets the PLC runtime state (Run, Stop, Reset) via ADS.
    .PARAMETER State
        Target state: Run, Stop, or Reset.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Stop', 'Reset')]
        [string]$State
    )

    try { Assert-TcAdsConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $stateMap = @{
        'Run'   = 5   # AdsState.Run
        'Stop'  = 6   # AdsState.Stop
        'Reset' = 2   # AdsState.Reset
    }

    try {
        $targetState = $stateMap[$State]
        $newStateInfo = New-Object TwinCAT.Ads.StateInfo
        $newStateInfo.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], $targetState)
        $newStateInfo.DeviceState = 0
        $script:TcAdsClient.WriteControl($newStateInfo)

        # Verify new state
        Start-Sleep -Milliseconds 200
        $stateInfo = $script:TcAdsClient.ReadState()

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            requestedState = $State
            currentState   = $stateInfo.AdsState.ToString()
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to set PLC state: $_" -ErrorCode 'STATE_SET_FAILED'
    }
}
