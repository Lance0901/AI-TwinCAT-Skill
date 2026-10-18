function Set-TcSystemState {
    <#
    .SYNOPSIS
        Switches TwinCAT system state (Config/Run) via ADS — no dialog popups.
    .DESCRIPTION
        Uses ADS WriteControl on port 10000 to switch system state, then polls
        port 10000 (Wait-TcAdsState) until the requested state is reached instead
        of sleeping a fixed time.
        AmsNetId is auto-detected from IDE connection if not specified.
    .PARAMETER State
        Target state: Run or Config.
    .PARAMETER AmsNetId
        Target AMS Net ID. Auto-detected from IDE if omitted.
    .PARAMETER TimeoutSec
        Maximum time to wait for the target state. Default 60.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Config')]
        [string]$State,

        [Parameter()]
        [string]$AmsNetId,

        [Parameter()]
        [int]$TimeoutSec = 60
    )

    # Auto-detect AmsNetId
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
        $sm = $null
        try { $sm = Get-TcSysManager } catch { Write-Verbose "Set-TcSystemState: no IDE connection ($($_.Exception.Message))" }
        if ($null -ne $sm) {
            try { $AmsNetId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() } } catch { }
        }
        if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
            return New-TcResult -Success $false `
                -ErrorMessage 'AmsNetId not specified and could not be auto-detected. Connect to IDE first or specify -AmsNetId.' `
                -ErrorCode 'AMS_NETID_REQUIRED' `
                -Hint (Get-TcErrorHint -Code 'AMS_NETID_REQUIRED')
        }
    }

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return New-TcResult -Success $false -ErrorMessage 'TwinCAT.Ads.dll not found.' -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
    }

    $sysClient = $null
    try {
        $sysClient = New-Object TwinCAT.Ads.TcAdsClient
        $sysClient.Connect($AmsNetId, 10000)

        # Remember the state before the request: when it already equals the target
        # (e.g. Run -> Run = restart) the system transiently leaves and re-enters it.
        $stateBefore = $null
        try { $stateBefore = $sysClient.ReadState().AdsState.ToString() } catch { }

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

        # Restart case: wait (max 10 s) until the system actually leaves the current
        # state, otherwise the poll below would succeed on the stale pre-restart state.
        if ($stateBefore -eq $State) {
            $leaveDeadline = [DateTime]::Now.AddSeconds(10)
            while ([DateTime]::Now -lt $leaveDeadline) {
                try {
                    $s = $sysClient.ReadState().AdsState.ToString()
                    if ($s -ne $State) { break }
                }
                catch { break }  # port unreachable = restart in progress
                Start-Sleep -Milliseconds 250
            }
        }

        $sysClient.Dispose()
        $sysClient = $null

        # Poll port 10000 until the target state is reached (replaces fixed sleep)
        $wait = Wait-TcAdsState -AmsNetId $AmsNetId -Port 10000 -TargetState $State -TimeoutSec $TimeoutSec

        $data = [PSCustomObject]@{
            requestedState = $State
            currentState   = $wait.State
            amsNetId       = $AmsNetId
            elapsedMs      = $wait.ElapsedMs
        }

        if (-not $wait.Reached) {
            $detail = if ($wait.LastError) { " Last error: $($wait.LastError)" } else { '' }
            return New-TcResult -Success $false `
                -ErrorMessage "TwinCAT did not reach state '$State' within $TimeoutSec s (last state: $($wait.State)).$detail" `
                -ErrorCode 'SYSTEM_STATE_TIMEOUT' `
                -Hint (Get-TcErrorHint -Code 'SYSTEM_STATE_TIMEOUT') `
                -Data $data
        }

        New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SYSTEM_STATE_SET_FAILED' -MessagePrefix 'Failed to set system state'
    }
    finally {
        if ($null -ne $sysClient) {
            try { $sysClient.Dispose() } catch { }
        }
    }
}
