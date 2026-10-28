# Test fixture (no IDE): the real TwinCATAutomation module with the IDE / DTE / Error List /
# runtime access replaced by mocks, so the REAL Build-TcProject and Enable-TcConfig run through
# the REAL bridge (test/build-result.test.js, issues #23 / #45). Loaded by bridge.ps1 as
# TWINCAT_MODULE_PATH; the file name keeps the module name 'TwinCATAutomation' the bridge expects.
#
# Scenario: the content of the file named by env TCAUTO_TEST_BUILD_SCENARIO_FILE, read at every
# Build-TcProject (one server serves many scenarios: fewer powershell.exe in parallel with the
# timing-sensitive modal-probe tests), else env TCAUTO_TEST_BUILD_SCENARIO.
# Error List row sets from build-error-list.json.
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
#   library-unlocated      lbi 0, the library rows + that code row without a line (#56 point 2)
#   build-timeout          BuildState stays InProgress (call with TimeoutSec 5 -> BUILD_TIMEOUT)
#   build-modal            BuildState stays InProgress and a modal dialog shows up once the build
#                          was started (IDE_MODAL_DIALOG at the ~5 s modal check)
#   build-throws           SolutionBuild.Build() throws a non-busy error (outer catch of Build-TcProject)
#   (the last three: #56 review S1, a started build that never finished is recorded too)
# Get-TcPlcProjectList: no PLC child for no-plc, one 'plc' child otherwise (TIPC tree, #56 N1).
#   skipped-library        lbi 0, library rows; a second PLC project is skipped by the configuration
#   skipped                lbi 0, no rows; a second PLC project is skipped by the configuration
#   all-skipped            lbi 0, no rows; the only PLC project is skipped (#58, TwinCAT_Festo shape:
#                          solution platform = the fixture platform, project platform
#                          'TwinCAT OS (ARMT2)', the coverage label carries the project platform
#                          like the old Get-TcBuildCoverage did)
#   coverage-error         lbi 0, no rows; the PLC project list (SolutionContexts) is not readable
#   no-plc                 lbi 0, no rows; the solution has no .plcproj (I/O / NC only)
#   context-platform       lbi 0, no rows; Get-TcSolutionPlatform only has platformSource 'context'
#                          (its platform is the project platform 'TwinCAT OS (ARMT2)')
# GetSymbols / ReadVariable (#57): the real Get-TcSymbols / Read-TcVariable on a fixture symbol
# table (TcAdsHelper type defined here, no ADS); a path containing 'Missing' is not found.
# Enable-TcConfig: the solution platform starts as env TCAUTO_TEST_PLATFORM (default
# 'TwinCAT RT (x64)'), the target reports 'TwinCAT OS (x64)' (so the first call switches +
# rebuilds); Set-TcSystemState fails with FIXTURE_NO_RUNTIME, which marks "got past the build /
# platform checks". The BUILD_REQUIRED state file goes to env TCAUTO_STATE_DIR (set by the test).
# PlcLogin: the real Enter-TcPlcOnline; only its BUILD_REQUIRED refusal (before any COM call) is
# reachable here, a login that gets past it fails on the mock SysManager.
# WritePouCode (#65): the real Write-TcPouCode on one mock item, 'TIPC^plc^plc Project^POUs^MAIN'
# (ItemType 602, declaration + implementation); LookupTreeItem of any other path throws. A
# successful write records BUILD_REQUIRED kind code-changed through the real Set-TcBuildRequired.
#
# Windows PowerShell 5.1, ASCII only.

# The real module: its $script: state block runs here and its Private / Public files are
# dot-sourced explicitly below (they are .ps1, so dot-sourcing them is safe).
$realRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..\..\src\TwinCATAutomation')).ProviderPath
# NEVER invoke the .psm1 path ('. x.psm1' / '& x.psm1'): PowerShell 5.1 runs only .ps1 as a script
# and hands any other file to the shell, which opens it in Notepad on the user's desktop
# (measured 2026-10-26, Windows PowerShell 5.1: dot-sourcing the .psm1 from this fixture opened
# it in Notepad on every build-result.test.js run). The $script: state block (everything before
# '# Import private functions') is read as text instead.
$realPsm1Text = Get-Content -Raw -LiteralPath (Join-Path $realRoot 'TwinCATAutomation.psm1')
$stateEnd = $realPsm1Text.IndexOf('# Import private functions')
if ($stateEnd -lt 0) { throw 'fixture: state block marker not found in TwinCATAutomation.psm1' }
# Self-check: every module-level $script: assignment must be inside that block, else the fixture
# would silently miss state that a later change to the real .psm1 adds after the marker.
foreach ($m in [regex]::Matches($realPsm1Text, '(?m)^\s*(\[[^\]]+\]\s*)?\$script:\w+\s*[+\-]?=')) {
    if ($m.Index -ge $stateEnd) { throw "fixture: '$($m.Value.Trim())' in TwinCATAutomation.psm1 is after the state block marker; move it before '# Import private functions'" }
}
. ([scriptblock]::Create($realPsm1Text.Substring(0, $stateEnd)))
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
    'library-unlocated'     = @{ Lbi = 0; Sets = @('library', 'unlocated') }
    'build-timeout'         = @{ Lbi = 0; Sets = @(); BuildState = 'stuck' }
    'build-modal'           = @{ Lbi = 0; Sets = @(); BuildState = 'stuck'; ModalWhileBuilding = $true }
    'build-throws'          = @{ Lbi = 0; Sets = @(); BuildState = 'throws' }
    'skipped-library'       = @{ Lbi = 0; Sets = @('library'); Skipped = $true }
    'skipped'               = @{ Lbi = 0; Sets = @(); Skipped = $true }
    'all-skipped'           = @{ Lbi = 0; Sets = @(); AllSkipped = $true; ProjectPlatform = 'TwinCAT OS (ARMT2)' }
    'coverage-error'        = @{ Lbi = 0; Sets = @(); CoverageError = 'SolutionContexts not readable (fixture)' }
    'no-plc'                = @{ Lbi = 0; Sets = @(); NoPlc = $true }
    'context-platform'      = @{ Lbi = 0; Sets = @(); PlatformSource = 'context'; ProjectPlatform = 'TwinCAT OS (ARMT2)' }
}
function Get-FixtureScenario {
    $name = $script:FixtureScenario
    $file = $env:TCAUTO_TEST_BUILD_SCENARIO_FILE
    if (-not [string]::IsNullOrWhiteSpace($file) -and (Test-Path -LiteralPath $file)) { $name = (Get-Content -Raw -LiteralPath $file).Trim() }
    $sc = $script:FixtureScenarios[$name]
    if ($null -eq $sc) { throw "unknown fixture scenario '$name'" }
    $sc
}

$script:TcSolutionPath = 'C:\Demo\Demo.sln'
$script:FixturePlatform = if ([string]::IsNullOrWhiteSpace($env:TCAUTO_TEST_PLATFORM)) { 'TwinCAT RT (x64)' } else { $env:TCAUTO_TEST_PLATFORM }

function Assert-TcConnection { }
# RunLifecycle starts with ConnectIde: no IDE here.
function Connect-TcIde {
    [CmdletBinding()]
    param([string]$ProgId, [string]$SolutionPath, [switch]$NoLaunch)
    New-TcResult -Success $true -Data ([PSCustomObject]@{ amsNetId = '127.0.0.1.1.1'; solution = $script:TcSolutionPath })
}
$script:FixtureMainPath = 'TIPC^plc^plc Project^POUs^MAIN'
$script:FixtureMain = [PSCustomObject]@{
    PathName = $script:FixtureMainPath; Name = 'MAIN'; ItemType = 602; ItemSubType = 0; ItemSubTypeName = 'TREEITEMTYPE_PLCPOUPROG'
    Language = 1; DeclarationText = "PROGRAM MAIN`nVAR`n    n : INT;`nEND_VAR"; ImplementationText = ''
}
function Get-TcSysManager {
    $sm = [PSCustomObject]@{ Mock = $true }
    $sm | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '127.0.0.1.1.1' }
    $sm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value {
        param($path)
        if ($path -eq $script:FixtureMainPath) { return $script:FixtureMain }
        throw "Item not found: $path (fixture)"
    }
    $sm
}
$script:FixtureBuilding = $false
function Get-TcIdeModalDialog {
    if ($script:FixtureBuilding -and (Get-FixtureScenario).ModalWhileBuilding) {
        return @{ Title = 'TcXaeShell'; Text = 'Assertion Failed (fixture)'; Kind = 'unknown'; Hwnd = 0; Buttons = @() }
    }
    $null
}
function Get-TcPlcProjectList {
    param($SysManager)
    if ((Get-FixtureScenario).NoPlc) { return @() }
    @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851; disabled = $false })
}
function Get-TcBuildCoverage {
    $sc = Get-FixtureScenario
    if ($sc.CoverageError) { return @{ configuration = $null; error = $sc.CoverageError; projects = @() } }
    if ($sc.NoPlc) { return @{ configuration = 'Release'; error = $null; projects = @() } }
    if ($sc.AllSkipped) {
        $projects = @([PSCustomObject]@{
            name = 'plc'; uniqueName = 'Demo\plc\plc.plcproj'; configuration = 'Release'
            platform = $sc.ProjectPlatform; shouldBuild = $false; status = 'skipped'
        })
        return @{ configuration = "Release|$($sc.ProjectPlatform)"; error = $null; projects = $projects }
    }
    $projects = @([PSCustomObject]@{
        name = 'plc'; uniqueName = 'Demo\plc\plc.plcproj'; configuration = 'Release'
        platform = 'TwinCAT RT (x64)'; shouldBuild = $true; status = 'pending'
    })
    if ((Get-FixtureScenario).Skipped) {
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
    $sc = Get-FixtureScenario
    if ($sc.ErrorListFails) {
        return New-TcResult -Success $false -ErrorMessage 'Error List window not found (fixture)' -ErrorCode 'ERRORLIST_UNAVAILABLE'
    }
    $rows = @()
    foreach ($set in $sc.Sets) { $rows += @($script:FixtureRows.$set) }
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
# DTE solution configurations (covered by tests/Unit/platform-project-mismatch.ps1); this mock
# switches the fixture platform and records the pending build through the real Set-TcBuildRequired.
function Get-TcSolutionPlatform {
    # Scenario from the file only (EnableConfig tests run without one and keep the defaults).
    $projPlat = $script:FixturePlatform
    $plat = $script:FixturePlatform
    $source = 'ActiveConfig'
    $file = $env:TCAUTO_TEST_BUILD_SCENARIO_FILE
    if (-not [string]::IsNullOrWhiteSpace($file) -and (Test-Path -LiteralPath $file)) {
        $sc = $script:FixtureScenarios[(Get-Content -Raw -LiteralPath $file).Trim()]
        if ($null -ne $sc -and $sc.ProjectPlatform) { $projPlat = $sc.ProjectPlatform }
        # 'context': the real Get-TcSolutionPlatform's last resort returns a context's PROJECT platform
        if ($null -ne $sc -and $sc.PlatformSource) { $source = $sc.PlatformSource; if ($source -eq 'context') { $plat = $projPlat } }
    }
    [PSCustomObject]@{ platform = $plat; configuration = 'Release'; projectPlatform = $projPlat; platformSource = $source }
}

# ADS for GetSymbols / ReadVariable (#57). Ensure-TcAdsConnection: "connected, no reconnect".
function Ensure-TcAdsConnection { $false }
function Get-TcEnumTable { @{} }
$script:FixtureSymbols = @(
    @{ Name = 'MAIN.nCounter'; TypeName = 'INT'; Size = 2; Comment = '' }
    @{ Name = 'MAIN.bRun'; TypeName = 'BOOL'; Size = 1; Comment = 'run flag' }
    @{ Name = 'MAIN.fSpeed'; TypeName = 'LREAL'; Size = 8; Comment = '' }
    @{ Name = 'GVL.nMode'; TypeName = 'INT'; Size = 2; Comment = '' }
)
if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
    Add-Type -TypeDefinition @'
using System.Collections.Generic;
public static class TcAdsHelper {
    public static List<Dictionary<string, object>> Symbols = new List<Dictionary<string, object>>();
    // Fixture filter: substring match after removing '*' (the real helper reads the ADS symbol table).
    public static List<Dictionary<string, object>> GetAllSymbols(object client, string filter) {
        string f = (filter ?? "").Replace("*", "");
        var r = new List<Dictionary<string, object>>();
        foreach (var s in Symbols) { if (((string)s["Name"]).Contains(f)) r.Add(s); }
        return r;
    }
}
'@
    foreach ($s in $script:FixtureSymbols) {
        $d = [System.Collections.Generic.Dictionary[string,object]]::new()
        foreach ($k in $s.Keys) { $d[$k] = $s[$k] }
        [TcAdsHelper]::Symbols.Add($d)
    }
}
function Read-TcAdsSymbolValue {
    param([string]$VarPath)
    if ($VarPath -match 'Missing') { throw "Symbol '$VarPath' not found (fixture)" }
    @{ path = $VarPath; value = 7; type = 'DINT' }
}
function Get-TcTargetPlatform {
    param([string]$AmsNetId)
    [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'TARGETINFO'; adsError = $null }
}
function Set-TcSolutionPlatform {
    param([string]$Platform, [string]$Configuration, [string]$PlatformSource)
    $before = $script:FixturePlatform
    $script:FixturePlatform = $Platform
    $w = Set-TcBuildRequired -Reason "solution platform switched from 'Release|$before' to 'Release|$Platform'"
    [PSCustomObject]@{ success = $true; error = $null; configuration = 'Release'; previousPlatform = $before; platform = $Platform; platformChanged = $true; projectPlatform = $Platform; stateWarning = $w }
}
function Set-TcSystemState {
    param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
    New-TcResult -Success $false -ErrorMessage 'no runtime in the fixture' -ErrorCode 'FIXTURE_NO_RUNTIME'
}

# DTE: Build($false) returns at once; BuildState reports InProgress once, then Done.
$script:FixtureBuildPolls = 0
$sb = [PSCustomObject]@{ Mock = $true }
# 'throws': the Build call itself fails with a non-busy COM error (a throwing ScriptProperty getter
# would read as $null in PowerShell and the poll would run into BUILD_TIMEOUT instead).
$sb | Add-Member -MemberType ScriptMethod -Name Build -Value {
    param($wait)
    $script:FixtureBuildPolls = 0
    $script:FixtureBuilding = $true
    if ((Get-FixtureScenario).BuildState -eq 'throws') { $script:FixtureBuilding = $false; throw 'Build failed inside XAE (fixture)' }
}
$sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value {
    $script:FixtureBuildPolls++
    $mode = (Get-FixtureScenario).BuildState
    if ($mode -eq 'stuck') { return 2 }
    if ($script:FixtureBuildPolls -le 1) { 2 } else { $script:FixtureBuilding = $false; 3 }
}
$sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { (Get-FixtureScenario).Lbi }
$script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = $sb }; ToolWindows = $null }

Export-ModuleMember -Function $publicNames
