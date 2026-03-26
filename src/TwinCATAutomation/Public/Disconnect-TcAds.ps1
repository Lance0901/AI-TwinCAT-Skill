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

    New-TcResult -Success $true -Data ([PSCustomObject]@{ message = 'ADS connection closed.' })
}
