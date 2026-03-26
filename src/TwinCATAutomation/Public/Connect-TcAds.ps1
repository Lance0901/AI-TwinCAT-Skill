function Connect-TcAds {
    <#
    .SYNOPSIS
        Establishes an ADS connection to a TwinCAT PLC runtime.
    .PARAMETER AmsNetId
        Target AMS Net ID. Default: 127.0.0.1.1.1 (local).
    .PARAMETER Port
        ADS port. Default: 851 (PLC Runtime 1).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AmsNetId = '127.0.0.1.1.1',

        [Parameter()]
        [int]$Port = 851
    )

    # Load ADS assembly
    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return New-TcResult -Success $false `
            -ErrorMessage 'TwinCAT.Ads.dll not found. Ensure TwinCAT 3 is installed.' `
            -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
    }

    try {
        # Disconnect existing if any
        if ($null -ne $script:TcAdsClient) {
            try { $script:TcAdsClient.Dispose() } catch { }
        }

        $client = New-Object TwinCAT.Ads.TcAdsClient
        $client.Connect($AmsNetId, $Port)

        # Verify connection by reading state
        $stateInfo = $client.ReadState()
        $adsState = $stateInfo.AdsState

        $script:TcAdsClient = $client
        $script:TcAdsConnected = $true

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            amsNetId = $AmsNetId
            port     = $Port
            state    = $adsState.ToString()
        })
    }
    catch {
        $script:TcAdsConnected = $false
        New-TcResult -Success $false -ErrorMessage "ADS connection failed: $_" -ErrorCode 'ADS_CONNECT_FAILED'
    }
}
