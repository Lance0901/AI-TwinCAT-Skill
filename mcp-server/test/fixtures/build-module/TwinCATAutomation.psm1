# Test fixture (no IDE): the real TwinCATAutomation module with the IDE / DTE / Error List /
# runtime access replaced by mocks, so the REAL Build-TcProject and Enable-TcConfig run through
# the REAL bridge (test/build-result.test.js, issues #23 / #45). Loaded by bridge.ps1 as
# TWINCAT_MODULE_PATH; the file name keeps the module name 'TwinCATAutomation' the bridge expects.
#
# Scenario (env TCAUTO_TEST_BUILD_SCENARIO); Error List row sets from build-error-list.json.
# lbi = SolutionBuild.LastBuildInfo; 'unreadable' is no int, so the [int] cast in Build-TcProject
# throws like an unreadable COM property.
#   clean                  lbi 0, no rows
#   library-only           lbi 0, the 7 Library Manager rows (TwinCAT_Festo / GantryCylinder shape;
#                          on 4024 Festo the code is then not compiled at all, #45)
#   c0046                  lbi 1, library + one C0046 code error in MAIN
#   no-lbi                 lbi unreadable, library + C0046 (decided by the Error List)
#   no-lbi-library         lbi unreadable, library rows only
#   errorlist-unavailable  lbi 0, Get-TcBuildErrors fails with ERRORLIST_UNAVAILABLE
#   other-row              lbi 1, library + a build-summary row without file
#   unlocated-code         lbi 0, one code row with a file but line 0
#   skipped-library        lbi 0, library rows; a second PLC project is skipped by the configuration
# Enable-TcConfig: the solution platform starts as 'TwinCAT RT (x64)', the target reports
# 'TwinCAT OS (x64)' (so the first call switches + rebuilds); Set-TcSystemState fails with
# FIXTURE_NO_RUNTIME, which marks "got past the build / platform checks".
#
# Windows PowerShell 5.1, ASCII only.

# The real module. Dot-sourcing its .psm1 from here keeps this file's $PSScriptRoot, so its
# Private / Public files are dot-sourced explicitly (the .psm1 still sets the $script: state).
$realRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\src\TwinCATAutomation')).ProviderPath
. (Join-Path $realRoot 'TwinCATAutomation.psm1')
foreach ($f in @(Get-ChildItem -Path (Join-Path $realRoot 'Private'), (Join-Path $realRoot 'Public') -Filter '*.ps1' -Recurse)) { . $f.FullName }
$publicNames = @(Get-ChildItem -Path (Join-Path $realRoot 'Public') -Filter '*.ps1' -Recurse | ForEach-Object { $_.BaseName })

$script:FixtureScenario = $env:TCAUTO_TEST_BUILD_SCENARIO
if ([string]::IsNullOrWhiteSpace($script:FixtureScenario)) { $script:FixtureScenario = 'library-only' }
$script:FixtureRows = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\build-error-list.json') | ConvertFrom-Json
$script:FixtureScenarios = @{
    'clean'                 = @{ Lbi = 0; Sets = @() }
    'library-only'          = @{ Lbi = 0; Sets = @('library') }
    'c0046'                 = @{ Lbi = 1; Sets = @('library', 'code') }
    'no-lbi'                = @{ Lbi = 'unreadable'; Sets = @('library', 'code') }
    'no-lbi-library'        = @{ Lbi = 'unreadable'; Sets = @('library') }
    'errorlist-unavailable' = @{ Lbi = 0; Sets = @(); ErrorListFails = $true }
    'other-row'             = @{ Lbi = 1; Sets = @('library', 'other') }
    'unlocated-code'        = @{ Lbi = 0; Sets = @('unlocated') }
    'skipped-library'       = @{ Lbi = 0; Sets = @('library'); Skipped = $true }
}
$script:Fixture = $script:FixtureScenarios[$script:FixtureScenario]
if ($null -eq $script:Fixture) { throw "unknown TCAUTO_TEST_BUILD_SCENARIO '$($script:FixtureScenario)'" }

$script:TcSolutionPath = 'C:\Demo\Demo.sln'
$script:FixturePlatform = 'TwinCAT RT (x64)'

function Assert-TcConnection { }
# RunLifecycle starts with ConnectIde: no IDE here.
function Connect-TcIde {
    [CmdletBinding()]
    param([string]$ProgId, [string]$SolutionPath, [switch]$NoLaunch)
    New-TcResult -Success $true -Data ([PSCustomObject]@{ amsNetId = '127.0.0.1.1.1'; solution = $script:TcSolutionPath })
}
function Get-TcSysManager {
    $sm = [PSCustomObject]@{ Mock = $true }
    $sm | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '127.0.0.1.1.1' }
    $sm
}
function Get-TcIdeModalDialog { $null }
function Get-TcBuildCoverage {
    $projects = @([PSCustomObject]@{
        name = 'plc'; uniqueName = 'Demo\plc\plc.plcproj'; configuration = 'Release'
        platform = 'TwinCAT RT (x64)'; shouldBuild = $true; status = 'pending'
    })
    if ($script:Fixture.Skipped) {
        $projects += [PSCustomObject]@{
            name = 'plc2'; uniqueName = 'Demo\plc2\plc2.plcproj'; configuration = 'Release'
            platform = 'TwinCAT RT (x64)'; shouldBuild = $false; status = 'skipped'
        }
    }
    @{ configuration = 'Release|TwinCAT RT (x64)'; error = $null; projects = $projects }
}

function Get-TcBuildErrors {
    [CmdletBinding()]
    param([switch]$IncludeWarnings, [int]$TimeoutSec = 30)
    if ($script:Fixture.ErrorListFails) {
        return New-TcResult -Success $false -ErrorMessage 'Error List window not found (fixture)' -ErrorCode 'ERRORLIST_UNAVAILABLE'
    }
    $rows = @()
    foreach ($set in $script:Fixture.Sets) { $rows += @($script:FixtureRows.$set) }
    $errors = @($rows | ForEach-Object { [PSCustomObject]@{
        severity = 'Error'; code = $_.code; description = $_.description; project = $_.project
        file = $_.file; line = $_.line; column = $_.column
    } })
    New-TcResult -Success $true -Data ([PSCustomObject]@{
        counts   = [PSCustomObject]@{ errors = $errors.Count; warnings = 0; messages = 0 }
        errors   = $errors
        warnings = @()
    })
}

# Platform (Enable-TcConfig platform check / platform-fix). The real Set-TcSolutionPlatform needs
# DTE solution configurations; this mock switches the fixture platform and records the pending
# build exactly as the real one does after a switch ($script:TcBuildRequired).
function Get-TcSolutionPlatform {
    [PSCustomObject]@{ platform = $script:FixturePlatform; configuration = 'Release'; projectPlatform = $script:FixturePlatform; source = 'ActiveConfig' }
}
function Get-TcTargetPlatform {
    param([string]$AmsNetId)
    [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'TARGETINFO'; adsError = $null }
}
function Set-TcSolutionPlatform {
    param([string]$Platform, [string]$Configuration, [string]$PlatformSource)
    $before = $script:FixturePlatform
    $script:FixturePlatform = $Platform
    $script:TcBuildRequired = [PSCustomObject]@{
        Solution = $script:TcSolutionPath
        Reason   = "solution platform switched from 'Release|$before' to 'Release|$Platform'"
        At       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    [PSCustomObject]@{ success = $true; error = $null; configuration = 'Release'; previousPlatform = $before; platform = $Platform; platformChanged = $true; projectPlatform = $Platform }
}
function Set-TcSystemState {
    param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
    New-TcResult -Success $false -ErrorMessage 'no runtime in the fixture' -ErrorCode 'FIXTURE_NO_RUNTIME'
}

# DTE: Build($false) returns at once; BuildState reports InProgress once, then Done.
$script:FixtureBuildPolls = 0
$sb = [PSCustomObject]@{ Mock = $true }
$sb | Add-Member -MemberType ScriptMethod -Name Build -Value { param($wait) $script:FixtureBuildPolls = 0 }
$sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value {
    $script:FixtureBuildPolls++
    if ($script:FixtureBuildPolls -le 1) { 2 } else { 3 }
}
$sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { $script:Fixture.Lbi }
$script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = $sb }; ToolWindows = $null }

Export-ModuleMember -Function $publicNames
