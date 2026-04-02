function Initialize-TcAdsHelper {
    <#
    .SYNOPSIS
        Compiles the C# ADS helper that bypasses PowerShell CLS compatibility issues.
    .DESCRIPTION
        Tries multiple strategies to compile TcAdsHelper.cs:
        1. Use the explicit DLL path passed as parameter
        2. Search loaded assemblies for TwinCAT.Ads location
        3. Search common TwinCAT installation paths
        This ensures TcAdsHelper is available even if called after Connect-TcAds.
    #>
    param([string]$AdsAssemblyPath)

    if ($null -ne ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) { return }

    $csFile = Join-Path $PSScriptRoot 'TcAdsHelper.cs'
    if (-not (Test-Path $csFile)) {
        Write-Warning "TcAdsHelper.cs not found at: $csFile"
        return
    }

    $csCode = Get-Content -Path $csFile -Raw

    # Strategy 1: Use the provided assembly path
    if (-not [string]::IsNullOrWhiteSpace($AdsAssemblyPath) -and (Test-Path $AdsAssemblyPath)) {
        try {
            Add-Type -TypeDefinition $csCode -ReferencedAssemblies @($AdsAssemblyPath)
            return
        }
        catch {
            Write-Verbose "Add-Type with provided path failed: $_"
        }
    }

    # Strategy 2: Find from already-loaded assemblies
    $loadedAsm = [AppDomain]::CurrentDomain.GetAssemblies() | Where-Object {
        $_.GetName().Name -eq 'TwinCAT.Ads'
    } | Select-Object -First 1

    if ($null -ne $loadedAsm) {
        $loc = try { $loadedAsm.Location } catch { '' }
        if (-not [string]::IsNullOrWhiteSpace($loc) -and (Test-Path $loc)) {
            try {
                Add-Type -TypeDefinition $csCode -ReferencedAssemblies @($loc)
                return
            }
            catch {
                Write-Verbose "Add-Type with loaded assembly location failed: $_"
            }
        }

        # Assembly loaded but Location unavailable (GAC) — try with assembly name reference
        try {
            Add-Type -TypeDefinition $csCode -ReferencedAssemblies @('TwinCAT.Ads')
            return
        }
        catch {
            Write-Verbose "Add-Type with assembly name failed: $_"
        }
    }

    # Strategy 3: Search common paths
    $searchPaths = @(
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v170\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v160\TwinCAT.Ads.dll'
        'C:\Program Files (x86)\Beckhoff\TwinCAT\3.1\Components\Base\v150\TwinCAT.Ads.dll'
    )
    foreach ($p in $searchPaths) {
        if (Test-Path $p) {
            try {
                Add-Type -TypeDefinition $csCode -ReferencedAssemblies @($p)
                return
            }
            catch {
                Write-Verbose "Add-Type with $p failed: $_"
            }
        }
    }

    Write-Warning "Failed to compile TcAdsHelper.cs - all strategies exhausted"
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
