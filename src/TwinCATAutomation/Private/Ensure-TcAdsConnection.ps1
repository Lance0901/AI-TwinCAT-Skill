function Ensure-TcAdsConnection {
    <#
    .SYNOPSIS
        Verifies the module ADS session is alive, reconnecting once if it is not.
    .DESCRIPTION
        Replaces the former Assert-TcAdsConnection.
        1. If there is no client or the session is flagged disconnected: when an
           AmsNetId/Port were cached by a previous Connect-TcAds, reconnect once via
           Connect-TcAdsSession; otherwise throw NOT_CONNECTED.
        2. If a client exists: probe it with ReadState(). If the probe fails
           (typically 0x6 port not found / 0x7 target not found / 0x745 timeout after
           a TwinCAT restart, or a disposed client) reconnect once the same way.
        Sets $script:TcAdsReconnected and returns $true when a reconnect happened,
        $false when the existing session was healthy. Throws (message starts with
        "Not connected to TwinCAT ADS") when no usable session can be established;
        when the reconnect fails because the ADS port does not exist (0x6) the
        message instead reads "ADS target port <n> not found (ADS error 0x6)" so it
        maps to ADS_PORT_NOT_FOUND.
    .OUTPUTS
        [bool] $true if the session was re-established during this call.
    #>
    [CmdletBinding()]
    param()

    $script:TcAdsReconnected = $false
    $notConnectedMessage = 'Not connected to TwinCAT ADS. Call Connect-TcAds first.'

    $needReconnect = $false
    $probeError = $null

    if ($null -eq $script:TcAdsClient -or -not $script:TcAdsConnected) {
        $needReconnect = $true
    }
    else {
        try {
            $null = $script:TcAdsClient.ReadState()
        }
        catch {
            $probeError = $_
            $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
            if ($null -ne $mapped -and @('ADS_PORT_NOT_FOUND', 'ADS_TARGET_NOT_FOUND', 'ADS_TIMEOUT') -contains $mapped.Code) {
                Write-Verbose "Ensure-TcAdsConnection: probe failed ($($mapped.Code)), attempting reconnect."
                $needReconnect = $true
            }
            elseif ($_.Exception -is [System.ObjectDisposedException] -or $_.Exception.InnerException -is [System.ObjectDisposedException]) {
                Write-Verbose 'Ensure-TcAdsConnection: client disposed, attempting reconnect.'
                $needReconnect = $true
            }
            else {
                # Unknown probe failure: treat the session as dead and try once as well.
                Write-Verbose "Ensure-TcAdsConnection: probe failed ($($_.Exception.Message)), attempting reconnect."
                $needReconnect = $true
            }
        }
    }

    if (-not $needReconnect) {
        return $false
    }

    $canReconnect = (-not [string]::IsNullOrWhiteSpace($script:TcAdsAmsNetId)) -and ($script:TcAdsPort -gt 0)
    if (-not $canReconnect) {
        $script:TcAdsConnected = $false
        throw $notConnectedMessage
    }

    try {
        Write-Verbose "Ensure-TcAdsConnection: reconnecting to $($script:TcAdsAmsNetId):$($script:TcAdsPort)"
        $null = Connect-TcAdsSession -AmsNetId $script:TcAdsAmsNetId -Port $script:TcAdsPort
        $script:TcAdsReconnected = $true
        return $true
    }
    catch {
        $script:TcAdsConnected = $false
        # Port missing (ADS 0x6, e.g. 851 before any download) is a distinct condition:
        # keep it recognisable as ADS_PORT_NOT_FOUND instead of folding it into
        # NOT_CONNECTED, so callers (Set-TcPlcState -> PLC_NOT_LOADED) can react.
        # The message deliberately omits the NOT_CONNECTED phrase and the probe error
        # text (which could match a higher-priority pattern such as ADS_TIMEOUT).
        $reconnectMapped = ConvertTo-TcAdsErrorCode -InputObject $_
        if ($null -ne $reconnectMapped -and $reconnectMapped.Code -eq 'ADS_PORT_NOT_FOUND') {
            throw "ADS target port $($script:TcAdsPort) not found (ADS error 0x6) on $($script:TcAdsAmsNetId): auto-reconnect failed: $($_.Exception.Message)"
        }
        $detail = $_.Exception.Message
        if ($null -ne $probeError) { $detail = "$($probeError.Exception.Message); reconnect failed: $detail" }
        throw "$notConnectedMessage (auto-reconnect to $($script:TcAdsAmsNetId):$($script:TcAdsPort) failed: $detail)"
    }
}
