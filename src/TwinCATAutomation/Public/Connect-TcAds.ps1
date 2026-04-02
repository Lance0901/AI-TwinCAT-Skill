function Connect-TcAds {
    <#
    .SYNOPSIS
        Establishes an ADS connection to a TwinCAT PLC runtime.
    .DESCRIPTION
        Connects to a TwinCAT PLC runtime via ADS. The AmsNetId is target-dependent
        and changes based on the connected target (local UM Runtime, remote CX, etc.).
        When no AmsNetId is specified, the system auto-detects it from the active IDE
        connection via ITcSysManager.GetTargetNetId().
    .PARAMETER AmsNetId
        Target AMS Net ID. If omitted, auto-detected from active IDE connection.
    .PARAMETER Port
        ADS port. Default: 851 (PLC Runtime 1).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AmsNetId,

        [Parameter()]
        [int]$Port = 851
    )

    # Load ADS assembly + compile TcAdsHelper
    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return New-TcResult -Success $false `
            -ErrorMessage 'TwinCAT.Ads.dll not found. Ensure TwinCAT 3 is installed.' `
            -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
    }

    # Verify TcAdsHelper is available (needed by Get-TcSymbols, Read/Write-TcVariable)
    if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
        Write-Warning "TcAdsHelper could not be compiled. Get-TcSymbols, Read-TcVariable, Write-TcVariable may fail."
    }

    # Auto-detect AmsNetId from IDE connection if not specified
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
        if ($null -ne $script:TcSysManager) {
            try {
                $AmsNetId = $script:TcSysManager.GetTargetNetId()
                Write-Verbose "Auto-detected AmsNetId from IDE: $AmsNetId"
            }
            catch {
                Write-Verbose "Could not auto-detect AmsNetId: $_"
            }
        }

        if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
            return New-TcResult -Success $false `
                -ErrorMessage 'AmsNetId not specified and could not be auto-detected. Connect to IDE first (Connect-TcIde) or specify -AmsNetId.' `
                -ErrorCode 'AMS_NETID_REQUIRED'
        }
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
