function Find-TcAdsAssembly {
    <#
    .SYNOPSIS
        Locates and loads TwinCAT.Ads.dll from TwinCAT installation paths.
    .OUTPUTS
        $true if loaded successfully, $false otherwise.
    #>
    [CmdletBinding()]
    param()

    # Check if already loaded
    $loaded = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        $_.GetName().Name -eq 'TwinCAT.Ads'
    }
    if ($loaded) { return $true }

    # Common paths for TwinCAT.Ads.dll
    $searchPaths = @(
        "$env:TwinCATDir\..\AdsApi\.NET\v4.0.30319\TwinCAT.Ads.dll"
        'C:\TwinCAT\AdsApi\.NET\v4.0.30319\TwinCAT.Ads.dll'
        'C:\TwinCAT\3.1\Components\AdsApi\.NET\v4.0.30319\TwinCAT.Ads.dll'
        "$env:ProgramFiles\Beckhoff\TwinCAT\AdsApi\.NET\v4.0.30319\TwinCAT.Ads.dll"
        'C:\TwinCAT\AdsApi\.NET\v4.5.0\TwinCAT.Ads.dll'
        'C:\TwinCAT\3.1\Components\AdsApi\.NET\v4.5.0\TwinCAT.Ads.dll'
    )

    foreach ($dllPath in $searchPaths) {
        $resolved = [Environment]::ExpandEnvironmentVariables($dllPath)
        if (Test-Path $resolved) {
            try {
                Add-Type -Path $resolved
                return $true
            }
            catch {
                continue
            }
        }
    }

    return $false
}
