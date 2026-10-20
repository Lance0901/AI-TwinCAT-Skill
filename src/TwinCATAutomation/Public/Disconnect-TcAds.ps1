function Disconnect-TcAds {
    <#
    .SYNOPSIS
        Closes the ADS connection and releases resources.
    #>
    [CmdletBinding()]
    param()

    if ($null -ne $script:TcAdsClient) {
        try { $script:TcAdsClient.Dispose() } catch { }
        $script:TcAdsClient = $null
    }

    $script:TcAdsConnected = $false
    # Explicit disconnect: drop the cached endpoint so Ensure-TcAdsConnection
    # does not silently auto-reconnect afterwards.
    $script:TcAdsAmsNetId = $null
    $script:TcAdsPort = 0
    $script:TcAdsReconnected = $false
    $script:TcAdsEnumCache = $null
    $script:TcAdsEnumCacheError = $null

    New-TcResult -Success $true -Data ([PSCustomObject]@{ message = 'ADS connection closed.' })
}
