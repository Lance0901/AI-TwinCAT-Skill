function Get-TcSystemState {
    <#
    .SYNOPSIS
        Reads the TwinCAT system state (Config/Run) via ADS on port 10000.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AmsNetId = '127.0.0.1.1.1'
    )

    try {
        $loaded = Find-TcAdsAssembly
        if (-not $loaded) {
            return New-TcResult -Success $false -ErrorMessage 'TwinCAT.Ads.dll not found.' -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
        }

        $sysClient = New-Object TwinCAT.Ads.TcAdsClient
        $sysClient.Connect($AmsNetId, 10000)  # Port 10000 = TwinCAT System Service

        $stateInfo = $sysClient.ReadState()
        $sysClient.Dispose()

        $stateName = switch ([int]$stateInfo.AdsState) {
            5 { 'Run' }
            15 { 'Config' }
            default { $stateInfo.AdsState.ToString() }
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            state    = $stateName
            adsState = [int]$stateInfo.AdsState
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to read system state: $_" -ErrorCode 'SYSTEM_STATE_FAILED'
    }
}
