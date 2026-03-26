function Assert-TcAdsConnection {
    <#
    .SYNOPSIS
        Checks for an active ADS connection. Throws if not connected.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:TcAdsConnected -or $null -eq $script:TcAdsClient) {
        throw "Not connected to TwinCAT ADS. Call Connect-TcAds first."
    }
}
