function Connect-TcAdsSession {
    <#
    .SYNOPSIS
        Opens the module-wide ADS session and caches its parameters for auto-reconnect.
    .DESCRIPTION
        Shared by Connect-TcAds (initial connect) and Ensure-TcAdsConnection (reconnect).
        Disposes any existing module client, connects a new TcAdsClient, verifies it with
        ReadState() and stores:
            $script:TcAdsClient, $script:TcAdsConnected,
            $script:TcAdsAmsNetId, $script:TcAdsPort
        Returns the AdsState name (e.g. 'Run'). Throws on failure (and marks the
        session as disconnected).
    .PARAMETER AmsNetId
        Target AMS Net ID.
    .PARAMETER Port
        ADS port. Default 851.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AmsNetId,

        [Parameter()]
        [int]$Port = 851
    )

    # Disconnect existing if any
    if ($null -ne $script:TcAdsClient) {
        try { $script:TcAdsClient.Dispose() } catch { }
        $script:TcAdsClient = $null
    }
    $script:TcAdsConnected = $false

    try {
        $client = New-TcAdsClient -AmsNetId $AmsNetId -Port $Port

        # Verify connection by reading state
        try {
            $stateInfo = $client.ReadState()
        }
        catch {
            try { $client.Dispose() } catch { }
            throw
        }

        $script:TcAdsClient = $client
        $script:TcAdsConnected = $true
        $script:TcAdsAmsNetId = $AmsNetId
        $script:TcAdsPort = $Port

        return $stateInfo.AdsState.ToString()
    }
    catch {
        $script:TcAdsConnected = $false
        throw
    }
}
