# Test fixture (#41, no IDE): the smallest module the REAL bridge/bridge.ps1 can load to exercise
# op 'retire' (ReloadModule). It dot-sources the REAL state code of the module
# (Private/Set-TcBuildRequired.ps1 and Private/LifecycleBlock.ps1), so $script:TcBuildRequiredLocal,
# $script:TcLifecycleBlockLocal and the build-required.json helpers are exactly the shipped ones
# (a rename there fails test/reload.test.js). State files go to $env:TCAUTO_STATE_DIR (the test sets
# a temp directory). Shared body of reload-module\TwinCATAutomation.psm1 (current format) and
# reload-module-old\TwinCATAutomation.psm1 ($script:TcFixtureOldFormat = $true: a module from before
# #41, i.e. the variables but neither Get-TcLifecycleBlockLocalForReload nor
# Merge-TcBuildRequiredEntry, like the branches #42 / #114 / #119 / #120 / #122 / #127).
#
# env TCAUTO_TEST_RELOAD_DROP_VAR = 'lifecycle' | 'build': remove that variable after loading, to
# prove that a module without it is refused (fail closed).

$privateDir = Join-Path $PSScriptRoot '..\..\..\..\src\TwinCATAutomation\Private'
. (Join-Path $privateDir 'Set-TcBuildRequired.ps1')
. (Join-Path $privateDir 'LifecycleBlock.ps1')

if ($script:TcFixtureOldFormat) {
    Remove-Item -Path 'Function:\Get-TcLifecycleBlockLocalForReload'
    Remove-Item -Path 'Function:\Merge-TcBuildRequiredEntry'
}
if ($env:TCAUTO_TEST_RELOAD_DROP_VAR -eq 'lifecycle') { Remove-Variable -Name TcLifecycleBlockLocal -Scope Script }
if ($env:TCAUTO_TEST_RELOAD_DROP_VAR -eq 'build') { Remove-Variable -Name TcBuildRequiredLocal -Scope Script }

$script:TcDte = $null
$script:TcAdsConnected = $false
$script:TcIdeProcessId = $null

function Connect-TcIde {
    <#
    .SYNOPSIS
        Fixture: marks the IDE as connected.
    #>
    [CmdletBinding()]
    param()
    $script:TcDte = [PSCustomObject]@{ fake = $true }
    $script:TcIdeProcessId = 4242
    [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 4242 } }
}

function Disconnect-TcIde {
    <#
    .SYNOPSIS
        Fixture: releases the fake IDE reference.
    #>
    [CmdletBinding()]
    param()
    $script:TcDte = $null
    $script:TcIdeProcessId = $null
    [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{} }
}

function Disconnect-TcAds {
    <#
    .SYNOPSIS
        Fixture: drops the fake ADS connection.
    #>
    [CmdletBinding()]
    param()
    $script:TcAdsConnected = $false
    [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{} }
}

function Set-TcSystemState {
    <#
    .SYNOPSIS
        Fixture: records an in-memory lifecycle block only (as when the state file cannot be written) and fails.
    .PARAMETER AmsNetId
        Target of the fake block.
    #>
    [CmdletBinding()]
    param([string]$AmsNetId = '5.1.2.3.1.1')
    $script:TcLifecycleBlockLocal[(ConvertTo-TcLifecycleKey $AmsNetId)] = [PSCustomObject]@{ amsNetId = $AmsNetId; command = 'Set-TcSystemState'; errorCode = 'SYSTEM_STATE_TIMEOUT' }
    [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SYSTEM_STATE_TIMEOUT'; message = 'fixture: state not reached' } }
}

function Register-TcCodeChange {
    <#
    .SYNOPSIS
        Fixture: records a code-changed BUILD_REQUIRED entry for a solution.
    .PARAMETER SolutionPath
        Solution the entry is for.
    .PARAMETER LocalOnly
        Keep the entry in memory only (as when build-required.json could not be written).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SolutionPath, [switch]$LocalOnly)
    if ($LocalOnly) {
        $reasons = [ordered]@{ 'code-changed' = 'PLC code changed by fixture' }
        $key = ConvertTo-TcSolutionKey $SolutionPath
        $script:TcBuildRequiredLocal[$key] = New-TcBuildRequiredEntry -Solution $SolutionPath -Reasons $reasons -Kind 'code-changed' -At ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        return [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ key = $key; localOnly = $true } }
    }
    if ($script:TcFixtureOldFormat) {
        # Set-TcBuildRequired needs Merge-TcBuildRequiredEntry, removed here: record memory + file directly
        $reasons = [ordered]@{ 'code-changed' = 'PLC code changed by fixture' }
        $key = ConvertTo-TcSolutionKey $SolutionPath
        $entry = New-TcBuildRequiredEntry -Solution $SolutionPath -Reasons $reasons -Kind 'code-changed' -At ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
        $script:TcBuildRequiredLocal[$key] = $entry
        $null = Invoke-TcBuildRequiredLocked -Body { $st = Read-TcBuildRequiredState; $st.Entries[$key] = $entry; Write-TcBuildRequiredState -Entries $st.Entries }
        return [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ key = $key; localOnly = $false } }
    }
    $w = Set-TcBuildRequired -Reason 'PLC code changed by fixture' -Kind 'code-changed' -SolutionPath $SolutionPath 3>$null
    [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ key = (ConvertTo-TcSolutionKey $SolutionPath); localOnly = $false; warning = $w } }
}

