function Get-TcIssueEnvironment {
    <#
    .SYNOPSIS
        #78: environment facts for New-TcIssueReport, taken ONLY from module state that is already in
        memory plus local machine facts. No COM / DTE call (an IDE blocked by a modal dialog would hang
        it), no ADS call, no network.
    #>
    [CmdletBinding()]
    param()

    $env_ = [ordered]@{}

    $mod = Get-Module -Name TwinCATAutomation | Select-Object -First 1
    # the manifest holds the version when the module was imported through the .psm1 (Version is then 0.0)
    $ver = $null
    if ($null -ne $mod) {
        $ver = [string]$mod.Version
        try {
            $psd1 = Join-Path $mod.ModuleBase 'TwinCATAutomation.psd1'
            if (Test-Path -LiteralPath $psd1) { $mv = (Import-PowerShellDataFile -LiteralPath $psd1).ModuleVersion; if ($mv) { $ver = [string]$mv } }
        }
        catch { $null = $_ }
    }
    $env_['module'] = $(if ($ver) { 'TwinCATAutomation ' + $ver } else { 'TwinCATAutomation (version unknown)' })

    # git commit of the checkout the module runs from (skipped when it is not a git checkout or git is missing)
    $commit = $null
    if ($null -ne $mod -and -not [string]::IsNullOrWhiteSpace($mod.ModuleBase)) {
        try {
            $root = Split-Path -Parent (Split-Path -Parent $mod.ModuleBase)
            if ($root -and (Test-Path -LiteralPath (Join-Path $root '.git')) -and (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
                $out = & git -C $root rev-parse --short HEAD 2>$null
                if ($LASTEXITCODE -eq 0 -and $out -match '^[0-9a-f]{7,40}$') { $commit = [string]$out }
            }
        }
        catch { $commit = $null }
    }
    if ($commit) { $env_['commit'] = $commit }

    $env_['powershell'] = '{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion
    $env_['os'] = [string][Environment]::OSVersion.Version + $(if ([Environment]::Is64BitProcess) { ' (64-bit process)' } else { ' (32-bit process)' })
    $env_['culture'] = [System.Globalization.CultureInfo]::CurrentUICulture.Name

    $env_['ideConnected'] = [bool]$script:TcIdeConnected
    if ($script:TcIdeConnected) {
        if ($script:TcProgId) { $env_['ideProgId'] = [string]$script:TcProgId }
        if ($script:TcIdeSelectedBy) { $env_['ideSelectedBy'] = [string]$script:TcIdeSelectedBy }
        if ($script:TcSolutionPath) {
            try { $env_['solutionFile'] = [System.IO.Path]::GetFileName([string]$script:TcSolutionPath) } catch { }
        }
        $env_['silentMode'] = [bool]$script:TcSilentMode
    }
    $env_['adsConnected'] = [bool]$script:TcAdsConnected
    if ($script:TcAdsAssemblyVersion) { $env_['adsDllVersion'] = [string]$script:TcAdsAssemblyVersion }
    if ($script:TcAdsHelperMode) { $env_['adsHelperMode'] = [string]$script:TcAdsHelperMode }
    return $env_
}
