function New-TcAdsClient {
    <#
    .SYNOPSIS
        Creates and connects a TwinCAT.Ads.TcAdsClient (not stored in module state).
    .DESCRIPTION
        Loads TwinCAT.Ads.dll via Find-TcAdsAssembly, creates a TcAdsClient and calls
        Connect(AmsNetId, Port). The caller owns the returned client and must Dispose()
        it. Throws when the assembly cannot be loaded or Connect() fails.
    .PARAMETER AmsNetId
        Target AMS Net ID.
    .PARAMETER Port
        ADS port (851 = PLC runtime 1, 10000 = TwinCAT system service).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$AmsNetId,

        [Parameter(Mandatory)]
        [int]$Port
    )

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        throw 'TwinCAT.Ads.dll not found. Ensure TwinCAT 3 is installed.'
    }

    $client = New-Object TwinCAT.Ads.TcAdsClient
    try {
        $client.Connect($AmsNetId, $Port)
    }
    catch {
        try { $client.Dispose() } catch { }
        throw
    }
    return $client
}
