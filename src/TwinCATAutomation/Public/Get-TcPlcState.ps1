function Get-TcPlcState {
    <#
    .SYNOPSIS
        Reads the current PLC runtime state via ADS.
    .DESCRIPTION
        data.state / adsState / deviceState are the PLC port of the module ADS session (851 by
        default). #287: data.systemState / systemAdsState / systemStateReadAt are the TwinCAT system
        service (port 10000) of the same target, read once more right after; 'Exception' (adsState
        19) there means a PLC-level Run / Reset cannot recover it (Set-TcPlcState refuses with
        SYSTEM_EXCEPTION). A failed port 10000 read does not fail this command: systemState is then
        $null and data.systemStateError has the reason.
    #>
    [CmdletBinding()]
    param()

    try { $reconnected = Ensure-TcAdsConnection } catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
    }

    try {
        $stateInfo = $script:TcAdsClient.ReadState()
        $adsState = $stateInfo.AdsState
        $deviceState = $stateInfo.DeviceState
        $sys = Read-TcSystemAdsState -AmsNetId ([string]$script:TcAdsAmsNetId)   # #287, never throws

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
            reconnected = $reconnected
            systemState       = $sys.state
            systemAdsState    = $sys.adsState
            systemStateReadAt = $sys.readAt
            systemStateError  = $sys.error
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'STATE_READ_FAILED' -MessagePrefix 'Failed to read PLC state'
    }
}
