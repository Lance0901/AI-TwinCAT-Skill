# TwinCATAutomation PowerShell Module
# Provides cmdlets for automating TwinCAT 3 IDE via TwinCAT Automation Interface

# Module-scoped state for IDE and ADS connections
$script:TcDte = $null
$script:TcSysManager = $null
$script:TcLastSysManagerError = $null  # message of the exception that made Get-TcSysManager return $null (IDE_CRASHED / IDE_BUSY / IDE_MODAL_DIALOG ...); read by New-TcNoSysManagerResult
$script:TcAdsClient = $null
$script:TcAdsConnected = $false
$script:TcAdsAmsNetId = $null      # cached for auto-reconnect (Ensure-TcAdsConnection)
$script:TcAdsPort = 0              # cached for auto-reconnect (Ensure-TcAdsConnection)
$script:TcAdsReconnected = $false  # set by Ensure-TcAdsConnection when it had to reconnect
$script:TcIdeConnected = $false
$script:TcProgId = $null
$script:TcIdeProcessId = $null     # pid of the connected IDE (Connect-TcIde); used by Get-TcIdeModalDialog
$script:TcIdeMainHwnd = 0          # main window handle of the connected IDE (excluded from dialog scans)
$script:TcLastModalDialog = $null  # last dialog seen by the Invoke-TcComRetry watchdog: @{ Title; Text }
$script:TcAutomationSettings = $null  # ITcAutomationSettings (DTE.GetObject('TcAutomationSettings')), SilentMode enabled by Connect-TcIde
$script:TcSilentMode = $false         # whether SilentMode could be enabled on the connected IDE
$script:TcSilentModeOriginal = $null  # SilentMode value found by Connect-TcIde (restored by Disconnect-TcIde without -Quit); $null = unknown
$script:TcLastIdeCrash = $null        # "<yyyy-MM-dd HH:mm:ss> <message>" of the last IDE_CRASHED detected by Invoke-TcComRetry
$script:TcAdsAssemblyPath = $null        # TwinCAT.Ads.dll actually loaded (Find-TcAdsAssembly)
$script:TcAdsAssemblyVersion = $null     # its FileVersion
$script:TcAdsAssemblyCandidates = $null  # cached candidate list (Get-TcAdsAssemblyCandidates)
$script:TcAdsHelperMode = $null          # 'compiled' | 'reflection' (Initialize-TcAdsHelper)

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
