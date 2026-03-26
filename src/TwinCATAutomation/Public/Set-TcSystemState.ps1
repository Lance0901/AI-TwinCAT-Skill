function Set-TcSystemState {
    <#
    .SYNOPSIS
        Switches TwinCAT system state (Config/Run) via ADS — no dialog popups.
    .DESCRIPTION
        Uses ADS WriteControl on port 10000 to switch system state.
        AmsNetId is auto-detected from IDE connection if not specified.
    .PARAMETER State
        Target state: Run or Config.
    .PARAMETER AmsNetId
        Target AMS Net ID. Auto-detected from IDE if omitted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Config')]
        [string]$State,

        [Parameter()]
        [string]$AmsNetId
    )

    # Auto-detect AmsNetId
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
        $sm = Get-TcSysManager
        if ($null -ne $sm) {
            try { $AmsNetId = $sm.GetTargetNetId() } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
            return New-TcResult -Success $false -ErrorMessage 'AmsNetId not specified and could not be auto-detected. Connect to IDE first or specify -AmsNetId.' -ErrorCode 'AMS_NETID_REQUIRED'
        }
    }

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return New-TcResult -Success $false -ErrorMessage 'TwinCAT.Ads.dll not found.' -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
    }

    try {
        $sysClient = New-Object TwinCAT.Ads.TcAdsClient
        $sysClient.Connect($AmsNetId, 10000)

        $newState = New-Object TwinCAT.Ads.StateInfo
        if ($State -eq 'Config') {
            # AdsState 16 = Reconfig → switch to Config mode
            $newState.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], 16)
        }
        else {
            # AdsState 2 = Reset → restart into Run mode
            $newState.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], 2)
        }
        $newState.DeviceState = 0
        $sysClient.WriteControl($newState)

        Start-Sleep -Seconds 5

        # Verify
        $stateInfo = $sysClient.ReadState()
        $sysClient.Dispose()

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            requestedState = $State
            currentState   = $stateInfo.AdsState.ToString()
            amsNetId       = $AmsNetId
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to set system state: $_" -ErrorCode 'SYSTEM_STATE_SET_FAILED'
    }
}
