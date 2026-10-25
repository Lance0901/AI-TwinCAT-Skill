# Test fixture (no IDE): the real TwinCATAutomation module with the IDE / DTE / Error List
# access replaced by mocks, so the REAL Build-TcProject runs through the REAL bridge
# (test/build-result.test.js, issue #23). Loaded by bridge.ps1 as TWINCAT_MODULE_PATH; the file
# name keeps the module name 'TwinCATAutomation' the bridge expects.
#
# Scenario (env TCAUTO_TEST_BUILD_SCENARIO), Error List rows from build-error-list.json:
#   library-only  LastBuildInfo 0, the 7 Library Manager rows (TwinCAT_Festo / GantryCylinder shape)
#   c0046         LastBuildInfo 1, the same 7 rows plus one C0046 code error in MAIN
#   no-lbi        LastBuildInfo not readable, the C0046 rows (decided by the Error List)
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

function Assert-TcConnection { }
function Get-TcSysManager { [PSCustomObject]@{ Mock = $true } }
function Get-TcIdeModalDialog { $null }
function Get-TcBuildCoverage {
    @{
        configuration = 'Release|TwinCAT RT (x64)'
        error         = $null
        projects      = @([PSCustomObject]@{
            name = 'plc'; uniqueName = 'Demo\plc\plc.plcproj'; configuration = 'Release'
            platform = 'TwinCAT RT (x64)'; shouldBuild = $true; status = 'pending'
        })
    }
}

function Get-TcBuildErrors {
    [CmdletBinding()]
    param([switch]$IncludeWarnings, [int]$TimeoutSec = 30)
    $rows = @($script:FixtureRows.library)
    if ($script:FixtureScenario -ne 'library-only') { $rows += @($script:FixtureRows.code) }
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

# DTE: Build($false) returns at once; BuildState reports InProgress once, then Done.
$script:FixtureBuildPolls = 0
$sb = [PSCustomObject]@{ Mock = $true }
$sb | Add-Member -MemberType ScriptMethod -Name Build -Value { param($wait) }
$sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value {
    $script:FixtureBuildPolls++
    if ($script:FixtureBuildPolls -le 1) { 2 } else { 3 }
}
$sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value {
    switch ($script:FixtureScenario) {
        'library-only' { 0 }
        # not an int: the [int] cast in Build-TcProject throws, like an unreadable COM property
        'no-lbi' { 'unreadable' }
        default { 1 }
    }
}
$script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = $sb }; ToolWindows = $null }

Export-ModuleMember -Function $publicNames
