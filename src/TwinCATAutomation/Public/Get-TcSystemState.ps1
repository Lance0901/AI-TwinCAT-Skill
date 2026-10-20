function Get-TcSystemState {
    <#
    .SYNOPSIS
        Reads the TwinCAT system state (Config/Run) of the IDE target via ADS on port 10000.
    .DESCRIPTION
        Reads the ADS state of the TwinCAT System Service (port 10000) of a target.
        When -AmsNetId is omitted the target is resolved in this order:
          1. IDE target   - ITcSysManager.GetTargetNetId() of the connected IDE (Connect-TcIde)
          2. ADS session  - the AmsNetId of the current ADS session (Connect-TcAds)
          3. local        - 127.0.0.1.1.1, the local TwinCAT system
        The local system is only the last fallback and is usually NOT the IDE target
        (e.g. a UmRT or remote CX target has its own AmsNetId): if data.netIdSource is
        'local' you are reading the local TcSysSrv, not your target. Connect the IDE first.
        data.amsNetId and data.netIdSource ('explicit' / 'ide-target' / 'ads-session' /
        'local') report which target was read.
    .PARAMETER AmsNetId
        Target AMS Net ID. Optional; when omitted it is resolved from the IDE target,
        then the ADS session, then the local system 127.0.0.1.1.1 (see DESCRIPTION).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AmsNetId
    )

    # Resolve the target AmsNetId and remember where it came from
    $netIdSource = 'explicit'
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
        $AmsNetId = $null
        $sm = $null
        try { $sm = Get-TcSysManager } catch { Write-Verbose "Get-TcSystemState: no IDE connection ($($_.Exception.Message))" }
        if ($null -ne $sm) {
            try { $AmsNetId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() } } catch { }
        }
        if (-not [string]::IsNullOrWhiteSpace($AmsNetId)) {
            $netIdSource = 'ide-target'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($script:TcAdsAmsNetId)) {
            $AmsNetId = $script:TcAdsAmsNetId
            $netIdSource = 'ads-session'
        }
        else {
            $AmsNetId = '127.0.0.1.1.1'
            $netIdSource = 'local'
        }
    }

    $sysClient = $null
    try {
        $loaded = Find-TcAdsAssembly
        if (-not $loaded) {
            return New-TcResult -Success $false -ErrorMessage 'TwinCAT.Ads.dll not found.' -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
        }

        $sysClient = New-Object TwinCAT.Ads.TcAdsClient
        $sysClient.Connect($AmsNetId, 10000)  # Port 10000 = TwinCAT System Service

        $stateInfo = $sysClient.ReadState()

        $stateName = switch ([int]$stateInfo.AdsState) {
            5 { 'Run' }
            15 { 'Config' }
            default { $stateInfo.AdsState.ToString() }
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            state       = $stateName
            adsState    = [int]$stateInfo.AdsState
            amsNetId    = $AmsNetId
            netIdSource = $netIdSource
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SYSTEM_STATE_FAILED' -MessagePrefix "Failed to read system state of $AmsNetId ($netIdSource)"
    }
    finally {
        if ($null -ne $sysClient) {
            try { $sysClient.Dispose() } catch { }
        }
    }
}
