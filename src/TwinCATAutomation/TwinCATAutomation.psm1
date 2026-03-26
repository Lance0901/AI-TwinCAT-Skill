# TwinCATAutomation PowerShell Module
# Provides cmdlets for automating TwinCAT 3 IDE via TwinCAT Automation Interface

# Module-scoped state for IDE and ADS connections
$script:TcDte = $null
$script:TcSysManager = $null
$script:TcAdsClient = $null
$script:TcAdsConnected = $false
$script:TcIdeConnected = $false
$script:TcProgId = $null

# Import private functions
$privatePath = Join-Path $PSScriptRoot 'Private'
if (Test-Path $privatePath) {
    Get-ChildItem -Path $privatePath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

# Import public functions
$publicPath = Join-Path $PSScriptRoot 'Public'
if (Test-Path $publicPath) {
    Get-ChildItem -Path $publicPath -Filter '*.ps1' -Recurse | ForEach-Object {
        . $_.FullName
    }
}

# Export all public functions
$publicFunctions = Get-ChildItem -Path $publicPath -Filter '*.ps1' -Recurse -ErrorAction SilentlyContinue |
    ForEach-Object { $_.BaseName }
if ($publicFunctions) {
    Export-ModuleMember -Function $publicFunctions
}
