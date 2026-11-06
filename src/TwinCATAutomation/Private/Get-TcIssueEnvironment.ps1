# Short commit id of the checkout the module runs from (ReportIssue commit line, #78). Only when the
# repository root two levels above ModuleBase really contains this module as
# <root>\src\TwinCATAutomation; otherwise (installed copy, unrelated parent repository) $null.
# The .git files are read by Read-TcGitCommit (Private/InstallManifest.ps1, #148): UTF-8 (#140),
# worktree .git file + commondir, loose ref / packed-refs / detached HEAD, SHA-1 and SHA-256.
function Get-TcModuleCommit {
    [CmdletBinding()]
    param([string]$ModuleBase)

    try {
        if ([string]::IsNullOrWhiteSpace($ModuleBase)) { return $null }
        $mb = [System.IO.Path]::GetFullPath($ModuleBase).TrimEnd('\')
        $root = [System.IO.Path]::GetFullPath((Join-Path $mb '..\..')).TrimEnd('\')
        $expected = [System.IO.Path]::GetFullPath((Join-Path $root 'src\TwinCATAutomation')).TrimEnd('\')
        if ($expected -ine $mb) { return $null }
        $git = Read-TcGitCommit -RepoRoot $root
        if ($null -ne $git -and $git.commit) { return ([string]$git.commit).Substring(0, 7) }
    }
    catch { return $null }
    return $null
}

# Names that identify the customer project and are known from module memory only (no IDE call):
# the base name of the solution that Connect-TcIde / Open-TcProject recorded. They are added to the
# mask list of New-TcIssueReport.
function Get-TcIssueKnownNames {
    [CmdletBinding()]
    param()
    $names = [System.Collections.Generic.List[string]]::new()
    if ($script:TcSolutionPath) {
        try {
            $n = [System.IO.Path]::GetFileNameWithoutExtension([string]$script:TcSolutionPath)
            if ($n -and $n.Length -ge 2) { $names.Add($n) }
        }
        catch { $null = $_ }
    }
    return , $names.ToArray()
}

function Get-TcIssueEnvironment {
    <#
    .SYNOPSIS
        #78: environment facts for New-TcIssueReport, taken ONLY from module state that is already in
        memory plus local machine facts. No COM / DTE call (an IDE blocked by a modal dialog would hang
        it), no ADS call, no network, no subprocess. The solution file name is only included with
        -IncludeSolutionName.
    #>
    [CmdletBinding()]
    param([switch]$IncludeSolutionName)

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

    $commit = $null
    if ($null -ne $mod) { $commit = Get-TcModuleCommit -ModuleBase $mod.ModuleBase }
    if ($commit) { $env_['commit'] = $commit }

    $env_['powershell'] = '{0} {1}' -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion
    $env_['os'] = [string][Environment]::OSVersion.Version + $(if ([Environment]::Is64BitProcess) { ' (64-bit process)' } else { ' (32-bit process)' })
    $env_['culture'] = [System.Globalization.CultureInfo]::CurrentUICulture.Name

    $env_['ideConnected'] = [bool]$script:TcIdeConnected
    if ($script:TcIdeConnected) {
        if ($script:TcProgId) { $env_['ideProgId'] = [string]$script:TcProgId }
        if ($script:TcIdeSelectedBy) { $env_['ideSelectedBy'] = [string]$script:TcIdeSelectedBy }
        if ($IncludeSolutionName -and $script:TcSolutionPath) {
            try { $env_['solutionFile'] = [System.IO.Path]::GetFileName([string]$script:TcSolutionPath) } catch { $null = $_ }
        }
        $env_['silentMode'] = [bool]$script:TcSilentMode
    }
    $env_['adsConnected'] = [bool]$script:TcAdsConnected
    if ($script:TcAdsAssemblyVersion) { $env_['adsDllVersion'] = [string]$script:TcAdsAssemblyVersion }
    if ($script:TcAdsHelperMode) { $env_['adsHelperMode'] = [string]$script:TcAdsHelperMode }
    return $env_
}
