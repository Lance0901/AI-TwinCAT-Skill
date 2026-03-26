function Initialize-TcAdsHelper {
    <#
    .SYNOPSIS
        Compiles the C# ADS helper that bypasses PowerShell CLS compatibility issues.
    #>
    param([string]$AdsAssemblyPath)

    if ($null -ne ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) { return }

    $csFile = Join-Path $PSScriptRoot 'TcAdsHelper.cs'
    if (-not (Test-Path $csFile)) { return }

    try {
        $csCode = Get-Content -Path $csFile -Raw
        Add-Type -TypeDefinition $csCode -ReferencedAssemblies @($AdsAssemblyPath)
    }
    catch {
        Write-Verbose "Failed to compile TcAdsHelper: $_"
    }
}

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
    if ($loaded) {
        Initialize-TcAdsHelper $loaded.Location
        return $true
    }

    # Search paths in priority order (v170 = VS2022 matching DLL first)
    $searchPaths = @(
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v170\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v160\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v150\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\TcDocGen\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\Functions\TE1010-Realtime-Monitor\TwinCAT.Ads.dll'
    )

    foreach ($dllPath in $searchPaths) {
        if (Test-Path $dllPath) {
            try {
                $asm = [System.Reflection.Assembly]::LoadFrom($dllPath)
                Initialize-TcAdsHelper $dllPath
                return $true
            }
            catch {
                continue
            }
        }
    }

    # Fallback: try loading from GAC
    try {
        [System.Reflection.Assembly]::LoadWithPartialName('TwinCAT.Ads') | Out-Null
        $check = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'TwinCAT.Ads' }
        if ($check) {
            Initialize-TcAdsHelper $check.Location
            return $true
        }
    }
    catch { }

    return $false
}
