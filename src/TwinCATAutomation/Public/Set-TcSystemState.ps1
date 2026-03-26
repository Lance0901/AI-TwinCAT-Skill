function Set-TcSystemState {
    <#
    .SYNOPSIS
        Switches TwinCAT system state (Config/Run).
    .PARAMETER State
        Target state: Run or Config.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Config')]
        [string]$State,

        [Parameter()]
        [string]$AmsNetId = '127.0.0.1.1.1'
    )

    try {
        $loaded = Find-TcAdsAssembly
        if (-not $loaded) {
            return New-TcResult -Success $false -ErrorMessage 'TwinCAT.Ads.dll not found.' -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
        }

        $stateMap = @{
            'Run'    = 5   # AdsState.Run
            'Config' = 15  # AdsState.Reconfig
        }

        $sysClient = New-Object TwinCAT.Ads.TcAdsClient
        $sysClient.Connect($AmsNetId, 10000)

        $targetState = $stateMap[$State]
        $sysClient.WriteControl(
            [TwinCAT.Ads.AdsState]$targetState,
            0,
            [byte[]]@()
        )

        Start-Sleep -Milliseconds 500
        $stateInfo = $sysClient.ReadState()
        $sysClient.Dispose()

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            requestedState = $State
            currentState   = $stateInfo.AdsState.ToString()
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to set system state: $_" -ErrorCode 'SYSTEM_STATE_SET_FAILED'
    }
}
