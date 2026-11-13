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
$script:TcIdeProcessId = $null     # pid of the connected IDE (Connect-TcIde); used by Find-TcIdeModalDialog
$script:TcIdeMainHwnd = 0          # main window handle of the connected IDE (excluded from dialog scans)
$script:TcIdeStartTime = $null     # StartTime of the TcIdeProcessId process (Connect-TcIde); Disconnect-TcIde -Kill refuses a pid whose start time differs (recycled pid)
$script:TcIdeSelectedBy = $null    # Connect-TcIde data.selectedBy ('launched' | 'solution-match' | ...); Disconnect-TcIde -Kill only kills 'launched'
$script:TcIdeConsentedIdes = @{}   # #281: IDEs bound with Connect-TcIde -ProcessId (key Get-TcIdeProcessKey, memory only): a later Connect-TcIde without parameters may attach them
$script:TcLastModalDialog = $null  # last dialog seen by the Invoke-TcComRetry watchdog: @{ Title; Text; Kind; ReloadTarget; Hwnd; Buttons }
$script:TcSolutionPath = $null     # full path of the .sln opened by Connect-TcIde / Open-TcProject; Reset-TcSolution reopens it
$script:TcAutomationSettings = $null  # ITcAutomationSettings (DTE.GetObject('TcAutomationSettings')), SilentMode enabled by Connect-TcIde
$script:TcSilentMode = $false         # whether SilentMode could be enabled on the connected IDE
$script:TcSilentModeOriginal = $null  # SilentMode value found by Connect-TcIde (restored by Disconnect-TcIde without -Quit); $null = unknown
$script:TcLastIdeCrash = $null        # "<yyyy-MM-dd HH:mm:ss> <message>" of the last IDE_CRASHED detected by Invoke-TcComRetry
$script:TcAdsAssemblyPath = $null        # TwinCAT.Ads.dll actually loaded (Find-TcAdsAssembly)
$script:TcAdsAssemblyVersion = $null     # its FileVersion
$script:TcAdsAssemblyCandidates = $null  # cached candidate list (Get-TcAdsAssemblyCandidates)
$script:TcAdsHelperMode = $null          # 'compiled' | 'reflection' (Initialize-TcAdsHelper)
$script:TcAdsEnumCache = $null           # enum type table of the connected runtime (Get-TcEnumTable); cleared on (re)connect
$script:TcAdsEnumCacheError = $null      # why the enum table could not be read (reported as hint)
$script:TcAdsEnumCacheVersion = $null    # ADS symbol version (0xF008) the cached table belongs to
$script:TcAdsEnumCacheFailedAt = $null   # UTC time of the last failed load (10 s cool-down before retry)
$script:TcAdsEnumIndex = $null           # @{ Full = name -> desc (case-insensitive); Short = unqualified name -> [desc] }
$script:TcLastBuildVerdict = $null       # last SUCCESSFUL Build-TcProject: solution, at, completeBuild, codeVerified, coverageComplete, warningCodes (BUILD_REQUIRED message)
$script:TcSystemStateSkipDiagnostics = $false  # #194: set by Enable-TcConfig around its set-run: the nested Set-TcSystemState collects no data.diagnostics
$script:TcSystemStateDiagCapSec = 10     # PR #200: Set-TcSystemState stuck-in-Config diagnostics end by request start + -TimeoutSec + this
$script:TcLastSolutionPlatform = $null   # #198: last Get-TcSolutionPlatform read { platform; projectPlatform; solutionPath; readAt } (diagnostics without DTE)
# #241: wait lengths that only tests/Unit change (& (Get-Module TwinCATAutomation) { $script:<name> = <small> })
# so a mocked busy IDE / unreachable runtime does not cost real seconds. The values below ARE the
# product behaviour (the constants they replaced); nothing in src/ sets them.
$script:TcComRetryDelayMs = 1000         # Invoke-TcComRetry: first busy backoff, doubled per retry (1, 2, 4, 8 s)
$script:TcSysManagerRetryMs = 1000       # Connect-TcIde: pause between the up to 10 ITcSysManager probes
$script:TcAdsWaitTimeScale = 1.0         # Wait-TcAdsState: factor on -TimeoutSec, -IntervalMs and -CrashUnreachableSec (Get-TcTimeScale)
$script:TcResetTimeScale = 1.0           # Reset-TcSolution / Wait-TcSolutionLoaded: factor on the -TimeoutSec deadline and the 500 ms polls

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
