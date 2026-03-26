function Get-TcPlcState {
    <#
    .SYNOPSIS
        Reads the current PLC runtime state via ADS.
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcAdsConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    try {
        $stateInfo = $script:TcAdsClient.ReadState()
        $adsState = $stateInfo.AdsState
        $deviceState = $stateInfo.DeviceState

        # Map ADS state to friendly name
        $stateName = switch ([int]$adsState) {
            0 { 'Invalid' }
            1 { 'Idle' }
            2 { 'Reset' }
            3 { 'Init' }
            4 { 'Start' }
            5 { 'Run' }
            6 { 'Stop' }
            7 { 'SaveCfg' }
            8 { 'LoadCfg' }
            9 { 'PowerFailure' }
            10 { 'PowerGood' }
            11 { 'Error' }
            12 { 'Shutdown' }
            13 { 'Suspend' }
            14 { 'Resume' }
            15 { 'Config' }
            16 { 'Reconfig' }
            default { "Unknown($adsState)" }
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            state       = $stateName
            adsState    = [int]$adsState
            deviceState = $deviceState
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to read PLC state: $_" -ErrorCode 'STATE_READ_FAILED'
    }
}
