# Short commit id of the checkout the module runs from, read from the .git files (no subprocess).
# Only when the repository root two levels above ModuleBase really contains this module as
# <root>\src\TwinCATAutomation; otherwise (installed copy, unrelated parent repository) $null.
function Get-TcModuleCommit {
    [CmdletBinding()]
    param([string]$ModuleBase)

    try {
        if ([string]::IsNullOrWhiteSpace($ModuleBase)) { return $null }
        $mb = [System.IO.Path]::GetFullPath($ModuleBase).TrimEnd('\')
        $root = [System.IO.Path]::GetFullPath((Join-Path $mb '..\..')).TrimEnd('\')
        $expected = [System.IO.Path]::GetFullPath((Join-Path $root 'src\TwinCATAutomation')).TrimEnd('\')
        if ($expected -ine $mb) { return $null }
        $dot = Join-Path $root '.git'
        $gitDir = $null
        if (Test-Path -LiteralPath $dot -PathType Container) { $gitDir = $dot }
        elseif (Test-Path -LiteralPath $dot -PathType Leaf) {
            $line = [string](Get-Content -LiteralPath $dot -TotalCount 1)
            if ($line -match '^gitdir:\s*(.+)$') {
                $g = $Matches[1].Trim()
                if (-not [System.IO.Path]::IsPathRooted($g)) { $g = Join-Path $root $g }
                $gitDir = [System.IO.Path]::GetFullPath($g)
            }
        }
        if (-not $gitDir) { return $null }
        $head = ([string](Get-Content -LiteralPath (Join-Path $gitDir 'HEAD') -TotalCount 1)).Trim()
        $sha = $null
        if ($head -match '^[0-9a-f]{40}$') { $sha = $head }
        elseif ($head -match '^ref:\s*(refs/[A-Za-z0-9._/-]+)$' -and $head -notmatch '\.\.') {
            $ref = $Matches[1]
            $dirs = @($gitDir)
            $cd = Join-Path $gitDir 'commondir'
            if (Test-Path -LiteralPath $cd -PathType Leaf) {
                $c = ([string](Get-Content -LiteralPath $cd -TotalCount 1)).Trim()
                if (-not [System.IO.Path]::IsPathRooted($c)) { $c = Join-Path $gitDir $c }
                $dirs += [System.IO.Path]::GetFullPath($c)
            }
            foreach ($d in $dirs) {
                $rf = Join-Path $d ($ref -replace '/', '\')
                if (Test-Path -LiteralPath $rf -PathType Leaf) {
                    $v = ([string](Get-Content -LiteralPath $rf -TotalCount 1)).Trim()
                    if ($v -match '^[0-9a-f]{40}$') { $sha = $v; break }
                }
            }
            if (-not $sha) {
                foreach ($d in $dirs) {
                    $pr = Join-Path $d 'packed-refs'
                    if (-not (Test-Path -LiteralPath $pr -PathType Leaf)) { continue }
                    foreach ($l in (Get-Content -LiteralPath $pr)) {
                        if ($l -match ('^([0-9a-f]{40}) ' + [regex]::Escape($ref) + '$')) { $sha = $Matches[1]; break }
                    }
                    if ($sha) { break }
                }
            }
        }
        if ($sha) { return $sha.Substring(0, 7) }
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
