# Unit: Build-TcProject coverage with PLC projects that are disabled in the TwinCAT project (#104),
# no IDE needed. The DTE / SolutionContexts / Error List / TIPC tree are mocked in the module scope;
# the real Build-TcProject, Get-TcErrorListSummary and Set/Clear-TcBuildRequired run (state file in
# a temp TCAUTO_STATE_DIR). Covers:
#   (a) 2 enabled built + 2 disabled skipped -> completeBuild true, disabledProjects has both
#   (b) 1 enabled skipped + 1 disabled skipped -> unchanged: completeBuild false,
#       PROJECT_SKIPPED_BY_CONFIGURATION listing only the enabled one
#   (c) -ExpectedProject naming a disabled project -> EXPECTED_PROJECT_DISABLED, build not started
#   (d) Get-TcPlcProjectList throws -> old behaviour (all enabled) + data.disabledCheckError
#   plus: a disabled project that IS built stays 'built'; a coverage entry without a tree item is
#   enabled; every PLC disabled + skipped -> not complete (nothing compiled), BUILD_REQUIRED neither
#   recorded nor cleared; a name match that is not one to one fails closed (review M1: two
#   PLC.plcproj, enabled 'Main' with Legacy.plcproj next to a disabled 'Legacy'); an empty PLC
#   list; IDE_CRASHED / IDE_MODAL_DIALOG from the PLC list stop before the build. The match by
#   .plcproj path (Get-TcPlcProjectList projectFile from PlcProjectDef/ProjectPath): swapped names
#   (enabled 'Main' with Legacy.plcproj, disabled 'Legacy' with Main.plcproj), a node without
#   ProjectPath or a path that is not one to one falls back to the name match, 8.3 vs long path.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/build-disabled-plc.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-dis-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
# 8.3 TEMP on CI runners (#43): the state keys are long paths
$stateRoot = & $mod { param($p) Get-TcLongPath $p } $stateRoot
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }
$sln = Join-Path $stateRoot 'Demo\Demo.sln'
$null = New-Item -ItemType Directory -Path (Split-Path -Parent $sln) -Force
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII

# --- the real Get-TcPlcProjectList reads projectFile from the PLC node XML (PlcProjectDef/ProjectPath,
# measured 2026-11-03, 4026 + VS2022), before it is mocked below
function New-PlcNode([string]$Name, [int]$Disabled, [string]$Xml) {
    $n = [PSCustomObject]@{ Name = $Name; PathName = "TIPC^$Name"; Disabled = $Disabled; Xml = $Xml }
    $n | Add-Member -MemberType ScriptMethod -Name ProduceXml -Value { param($x) $this.Xml }
    $n
}
$nodes = @(
    (New-PlcNode 'Main' 0 '<TreeItem><PlcProjectDef><ProjectPath>C:\Sol\Main\Legacy.plcproj</ProjectPath></PlcProjectDef><AdsPort>851</AdsPort></TreeItem>'),
    (New-PlcNode 'Legacy' 1 '<TreeItem><PlcProjectDef><Name>x</Name><ProjectPath>C:\Sol\R&amp;D\Main.plcproj</ProjectPath></PlcProjectDef><AdsPort>852</AdsPort></TreeItem>'),
    (New-PlcNode 'Rel' 0 '<TreeItem><PlcProjectDef><ProjectPath>Rel\Rel.plcproj</ProjectPath></PlcProjectDef></TreeItem>'),
    (New-PlcNode 'None' 0 '<TreeItem><AdsPort>853</AdsPort><ProjectPath>C:\not\in\def.plcproj</ProjectPath></TreeItem>')
)
$tipc = [PSCustomObject]@{ ChildCount = $nodes.Count; Nodes = $nodes }
$tipc | Add-Member -MemberType ScriptMethod -Name Child -Value { param($i) $this.Nodes[$i - 1] }
$smList = [PSCustomObject]@{ Tipc = $tipc }
$smList | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) $this.Tipc }
$list = @(& $mod { param($s) Get-TcPlcProjectList -SysManager $s } $smList)
Check 'Get-TcPlcProjectList projectFile: absolute PlcProjectDef/ProjectPath, XML-decoded' ($list[0].projectFile -eq 'C:\Sol\Main\Legacy.plcproj' -and $list[1].projectFile -eq 'C:\Sol\R&D\Main.plcproj' -and $list[1].disabled -eq $true) (J $list)
Check 'Get-TcPlcProjectList projectFile: relative path or no PlcProjectDef -> null' ($null -eq $list[2].projectFile -and $null -eq $list[3].projectFile -and $list[3].adsPort -eq 853) (J $list)

& $mod {
    param($s)
    $script:TcSolutionPath = $s
    $script:UtProjects = @()
    $script:UtPlcList = @()
    $script:UtPlcListThrows = $null
    $script:UtBuildStarted = $false
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [PSCustomObject]@{ Mock = $true } }
    function script:Find-TcIdeModalDialog { $null }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT OS (x64)'; platformSource = 'ActiveConfig' } }
    function script:Get-TcBuildCoverage {
        # fresh objects per call: Build-TcProject marks them (disabled / status)
        $projects = @($script:UtProjects | ForEach-Object {
            [PSCustomObject]@{
                name = $_.name; uniqueName = $(if ($_.unique) { $_.unique } else { "Demo\$($_.name)\$($_.name).plcproj" }); configuration = 'Release'
                platform = 'TwinCAT OS (x64)'; shouldBuild = $_.build; status = $(if ($_.build) { 'pending' } else { 'skipped' })
            }
        })
        @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = $projects }
    }
    function script:Get-TcPlcProjectList {
        param($SysManager)
        if ($script:UtPlcListThrows) { throw [string]$script:UtPlcListThrows }
        @($script:UtPlcList | ForEach-Object {
            [PSCustomObject]@{ name = $_.name; nodePath = "TIPC^$($_.name)"; projectPath = "TIPC^$($_.name)^$($_.name) Project"; adsPort = 851; disabled = [bool]$_.disabled; projectFile = $_.file }
        })
    }
    function script:Get-TcBuildErrors {
        [CmdletBinding()]
        param([switch]$IncludeWarnings, [int]$TimeoutSec = 30)
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }; errors = @(); warnings = @()
        })
    }
    $sb = [PSCustomObject]@{ Mock = $true; Polls = 0 }
    $sb | Add-Member -MemberType ScriptMethod -Name Build -Value { param($wait) $this.Polls = 0; $script:UtBuildStarted = $true }
    $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { $this.Polls++; if ($this.Polls -le 1) { 2 } else { 3 } }
    $sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { 0 }
    $script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = $sb }; ToolWindows = $null }
} $sln

function Set-Scenario($Projects, $PlcList, [string]$Throws = $null) {
    & $mod { param($p, $l, $t) $script:UtProjects = @($p); $script:UtPlcList = @($l); $script:UtPlcListThrows = $t; $script:UtBuildStarted = $false } $Projects $PlcList $Throws
}
function Get-BuildStarted { & $mod { $script:UtBuildStarted } }
function Get-Entry { & $mod { Get-TcBuildRequired } }
function Reset-State {
    & $mod { $script:TcBuildRequiredLocal = @{} }
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue
}
function P([string]$Name, [bool]$Build) { @{ name = $Name; build = $Build } }
function T([string]$Name, [bool]$Disabled) { @{ name = $Name; disabled = $Disabled } }
function Status($r) { (@($r.data.projects | ForEach-Object { "$($_.name)=$($_.status)/$($_.disabled)" })) -join ',' }

# --- (a) issue #104 shape: 2 enabled built + 2 disabled skipped
Reset-State
& $mod { Set-TcBuildRequired -Kind 'unverified-build' -Reason 'unit: previous incomplete build' -WarningAction SilentlyContinue } | Out-Null
Set-Scenario @((P 'RobustSolutionFramework' $true), (P 'FrameworkUnitTest' $true), (P 'RobustSolutionDemoProject' $false), (P 'Polar_II_ChamberDemo' $false)) `
             @((T 'RobustSolutionFramework' $false), (T 'FrameworkUnitTest' $false), (T 'RobustSolutionDemoProject' $true), (T 'Polar_II_ChamberDemo' $true))
$r = Build-TcProject -ExpectedProject 'RobustSolutionFramework', 'FrameworkUnitTest' -WarningAction SilentlyContinue
$d = $r.data
Check '(a) success, completeBuild true, coverageComplete true, codeVerified true' ($r.success -and $d.completeBuild -eq $true -and $d.coverageComplete -eq $true -and $d.codeVerified -eq $true) (J $d)
Check '(a) disabledProjects lists both disabled ones' ((@($d.disabledProjects) -join ',') -eq 'RobustSolutionDemoProject,Polar_II_ChamberDemo') (J $d.disabledProjects)
Check '(a) skippedProjects empty, no warningCode, no buildRequired' (@($d.skippedProjects).Count -eq 0 -and $null -eq $d.PSObject.Properties['warningCode'] -and $null -eq $d.PSObject.Properties['buildRequired']) (J $d)
Check '(a) project status / disabled flags' ((Status $r) -eq 'RobustSolutionFramework=built/False,FrameworkUnitTest=built/False,RobustSolutionDemoProject=disabled/True,Polar_II_ChamberDemo=disabled/True') (Status $r)
Check '(a) no disabledCheckError, matched by name (the mock nodes have no ProjectPath)' ($null -eq $d.PSObject.Properties['disabledCheckError'] -and $d.disabledMatchBy -eq 'name') (J $d)
Check '(a) complete build cleared BUILD_REQUIRED' ($null -eq (Get-Entry)) (J (Get-Entry))

# --- (b) 1 enabled skipped + 1 disabled skipped: #28 protection unchanged
Reset-State
Set-Scenario @((P 'plc' $true), (P 'plc2' $false), (P 'demo' $false)) @((T 'plc' $false), (T 'plc2' $false), (T 'demo' $true))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(b) success but completeBuild false, coverageComplete false, codeVerified false' ($r.success -and $d.completeBuild -eq $false -and $d.coverageComplete -eq $false -and $d.codeVerified -eq $false) (J $d)
Check '(b) PROJECT_SKIPPED_BY_CONFIGURATION, CODE_NOT_VERIFIED' ((@($d.warningCodes) -join ',') -eq 'PROJECT_SKIPPED_BY_CONFIGURATION,CODE_NOT_VERIFIED' -and $d.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION') (J $d.warningCodes)
Check '(b) skippedProjects only the enabled one, warning names only it' ((@($d.skippedProjects) -join ',') -eq 'plc2' -and $d.warning -match 'plc2' -and $d.warning -notmatch 'demo') "$(J $d.skippedProjects) $($d.warning)"
Check '(b) disabledProjects = demo' ((@($d.disabledProjects) -join ',') -eq 'demo') (J $d.disabledProjects)
Check '(b) BUILD_REQUIRED recorded' ($null -ne $d.buildRequired -and $null -ne (Get-Entry)) (J $d)
Set-Scenario @((P 'plc' $true), (P 'plc2' $false), (P 'demo' $false)) @((T 'plc' $false), (T 'plc2' $false), (T 'demo' $true))
$r = Build-TcProject -ExpectedProject 'plc2' -WarningAction SilentlyContinue
Check '(b) -ExpectedProject enabled+skipped -> PROJECT_SKIPPED_BY_CONFIGURATION, not started' ((-not $r.success) -and $r.error.code -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and -not (Get-BuildStarted)) (J $r)

# --- (c) -ExpectedProject naming a disabled project
Reset-State
foreach ($built in $false, $true) {
    Set-Scenario @((P 'plc' $true), (P 'demo' $built)) @((T 'plc' $false), (T 'demo' $true))
    $r = Build-TcProject -ExpectedProject 'plc', 'demo' -WarningAction SilentlyContinue
    Check "(c) disabled expected (shouldBuild=$built) -> EXPECTED_PROJECT_DISABLED, hint, not started" ((-not $r.success) -and $r.error.code -eq 'EXPECTED_PROJECT_DISABLED' -and $r.error.message -match 'demo' -and -not [string]::IsNullOrWhiteSpace([string]$r.error.hint) -and -not (Get-BuildStarted)) (J $r)
    Check "(c) shouldBuild=$built data.disabledProjects / projects[].disabled" ($r.data.projects[1].disabled -eq $true -and (@($r.data.disabledProjects) -join ',') -eq $(if ($built) { '' } else { 'demo' })) (J $r.data)
}
Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @((T 'plc' $false), (T 'demo' $true))
$r = Build-TcProject -ExpectedProject 'TIPC^demo' -WarningAction SilentlyContinue
Check '(c) TIPC^<Plc> form -> EXPECTED_PROJECT_DISABLED too' ($r.error.code -eq 'EXPECTED_PROJECT_DISABLED') (J $r.error)
Check '(c) nothing recorded (build not started)' ($null -eq (Get-Entry)) (J (Get-Entry))

# --- (d) Get-TcPlcProjectList throws: old behaviour + disabledCheckError
Reset-State
Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @((T 'plc' $false), (T 'demo' $true)) 'TIPC not readable (unit mock)'
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(d) disabledCheckError set' ($d.disabledCheckError -match 'TIPC not readable') (J $d)
Check '(d) old behaviour: demo skipped, PROJECT_SKIPPED_BY_CONFIGURATION, completeBuild false' ((Status $r) -eq 'plc=built/False,demo=skipped/False' -and $d.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and $d.completeBuild -eq $false -and @($d.disabledProjects).Count -eq 0) "$(Status $r) $(J $d.warningCodes)"
Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @((T 'plc' $false), (T 'demo' $true)) 'TIPC not readable (unit mock)'
$r = Build-TcProject -ExpectedProject 'demo' -WarningAction SilentlyContinue
Check '(d) -ExpectedProject demo -> old PROJECT_SKIPPED_BY_CONFIGURATION + disabledCheckError' ($r.error.code -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and $r.data.disabledCheckError -match 'TIPC not readable') (J $r)

# --- extra: disabled but built stays built; unmatched entry is enabled; all disabled -> not complete
Reset-State
Set-Scenario @((P 'plc' $true), (P 'demo' $true)) @((T 'plc' $false), (T 'demo' $true))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'disabled + built -> status built, disabled true, completeBuild true' ((Status $r) -eq 'plc=built/False,demo=built/True' -and $r.data.completeBuild -eq $true -and @($r.data.disabledProjects).Count -eq 0) "$(Status $r) $(J $r.data.disabledProjects)"
Set-Scenario @((P 'plc' $true), (P 'Other' $false)) @((T 'plc' $false), (T 'OtherRenamed' $true))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'coverage entry without a matching tree item -> enabled, still skipped' ((Status $r) -eq 'plc=built/False,Other=skipped/False' -and $r.data.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and $r.data.completeBuild -eq $false) (Status $r)
Set-Scenario @((P 'PLC' $true), (P 'DEMO' $false)) @((T 'plc' $false), (T 'demo' $true))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'name match is case-insensitive' ((Status $r) -eq 'PLC=built/False,DEMO=disabled/True' -and $r.data.completeBuild -eq $true) (Status $r)
Reset-State
Set-Scenario @((P 'demo' $false), (P 'demo2' $false)) @((T 'demo' $true), (T 'demo2' $true))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'every PLC disabled + skipped -> coverageComplete false, codeVerified false, CODE_NOT_VERIFIED, no PROJECT_SKIPPED' ($r.success -and $d.coverageComplete -eq $false -and $d.codeVerified -eq $false -and $d.completeBuild -eq $false -and (@($d.warningCodes) -join ',') -eq 'CODE_NOT_VERIFIED' -and $d.warning -match 'every PLC project is disabled') (J $d)
Check 'every PLC disabled + skipped -> BUILD_REQUIRED not recorded (like a solution without PLC project)' ($null -eq $d.PSObject.Properties['buildRequired'] -and $null -eq (Get-Entry)) (J (Get-Entry))
& $mod { Set-TcBuildRequired -Kind 'platform-switch' -Reason 'unit: platform switched' -WarningAction SilentlyContinue } | Out-Null
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'every PLC disabled + skipped -> an existing entry is not cleared either' ($r.data.completeBuild -eq $false -and $null -ne (Get-Entry) -and $null -eq $r.data.PSObject.Properties['buildRequired']) (J (Get-Entry))

# --- M1: the name match must be one to one, else fail closed (every entry enabled + disabledCheckError)
function PU([string]$Name, [bool]$Build, [string]$Unique) { @{ name = $Name; build = $Build; unique = $Unique } }
# A: two folders with PLC.plcproj; tree node 'PLC' disabled, 'Line2' enabled (its file is the second PLC.plcproj)
Reset-State
Set-Scenario @((PU 'PLC' $false 'Demo\PLC\PLC.plcproj'), (PU 'PLC' $false 'Demo\Line2\PLC.plcproj')) @((T 'PLC' $true), (T 'Line2' $false))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'M1 A: two PLC.plcproj + disabled PLC / enabled Line2 -> both skipped (not disabled), completeBuild false' ((Status $r) -eq 'PLC=skipped/False,PLC=skipped/False' -and $d.completeBuild -eq $false -and @($d.disabledProjects).Count -eq 0 -and $d.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION') "$(Status $r) $(J $d.warningCodes)"
Check 'M1 A: disabledCheckError names the ambiguity' ($d.disabledCheckError -match 'one to one' -and $d.disabledCheckError -match "disabled PLC 'PLC' matches 2" -and $d.disabledCheckError -match "enabled PLC 'Line2' matches no") ([string]$d.disabledCheckError)
Check 'M1 A: BUILD_REQUIRED recorded' ($null -ne $d.buildRequired -and $null -ne (Get-Entry)) (J $d)
# B: enabled node 'Main' whose file is Legacy.plcproj; a disabled node 'Legacy' with file OldDemo.plcproj
Reset-State
Set-Scenario @((PU 'Legacy' $false 'Demo\Main\Legacy.plcproj'), (PU 'OldDemo' $false 'Demo\Legacy\OldDemo.plcproj')) @((T 'Main' $false), (T 'Legacy' $true))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'M1 B: enabled Main (Legacy.plcproj) is not marked disabled by the disabled node Legacy' ((Status $r) -eq 'Legacy=skipped/False,OldDemo=skipped/False' -and $d.completeBuild -eq $false -and @($d.disabledProjects).Count -eq 0 -and (@($d.skippedProjects) -join ',') -eq 'Legacy,OldDemo') "$(Status $r)"
Check 'M1 B: disabledCheckError names the unmatched enabled node' ($d.disabledCheckError -match "enabled PLC 'Main' matches no") ([string]$d.disabledCheckError)
Set-Scenario @((PU 'Legacy' $false 'Demo\Main\Legacy.plcproj'), (PU 'OldDemo' $false 'Demo\Legacy\OldDemo.plcproj')) @((T 'Main' $false), (T 'Legacy' $true))
$r = Build-TcProject -ExpectedProject 'Legacy' -WarningAction SilentlyContinue
Check 'M1 B: -ExpectedProject Legacy -> PROJECT_SKIPPED_BY_CONFIGURATION (not EXPECTED_PROJECT_DISABLED)' ($r.error.code -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and $r.data.disabledCheckError -match 'one to one') (J $r.error)
# an entry matching two tree items (case-only duplicates)
Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @((T 'plc' $false), (T 'demo' $true), (T 'DEMO' $false))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'M1: an entry matching two tree items -> fail closed' ((Status $r) -eq 'plc=built/False,demo=skipped/False' -and $r.data.disabledCheckError -match "entry 'Demo\\demo\\demo.plcproj' matches 2") "$(Status $r) $($r.data.disabledCheckError)"
# no disabled node at all: no one-to-one check, no disabledCheckError (an enabled node with another file name is fine)
Set-Scenario @((P 'plc' $true), (P 'Legacy' $true)) @((T 'plc' $false), (T 'Main' $false))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'no disabled node -> no disabledCheckError, complete' ($null -eq $r.data.PSObject.Properties['disabledCheckError'] -and $r.data.completeBuild -eq $true) (J $r.data)

# --- S2: Get-TcPlcProjectList returns nothing -> every entry enabled, old behaviour
Reset-State
Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @()
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'empty PLC list -> all enabled, demo skipped, PROJECT_SKIPPED_BY_CONFIGURATION, no disabledCheckError' ((Status $r) -eq 'plc=built/False,demo=skipped/False' -and $r.data.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and $r.data.completeBuild -eq $false -and $null -eq $r.data.PSObject.Properties['disabledCheckError']) "$(Status $r)"
# --- S2: IDE_CRASHED / IDE_MODAL_DIALOG from the PLC list -> error, build not started
foreach ($code in 'IDE_CRASHED', 'IDE_MODAL_DIALOG') {
    Reset-State
    Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @((T 'plc' $false), (T 'demo' $true)) "${code}: the IDE is gone (unit mock)"
    $r = Build-TcProject -WarningAction SilentlyContinue
    Check "PLC list throws $code -> success false, build not started, nothing recorded" ((-not $r.success) -and $r.error.message -match $code -and -not (Get-BuildStarted) -and $null -eq (Get-Entry)) (J $r)
}


# --- match by .plcproj path (PLC node ProduceXml PlcProjectDef/ProjectPath, Get-TcPlcProjectList projectFile)
$slnDir = Split-Path -Parent $sln
function TF([string]$Name, [bool]$Disabled, [string]$File) { @{ name = $Name; disabled = $Disabled; file = $File } }
# swapped names: enabled node 'Main' uses Legacy.plcproj, disabled node 'Legacy' uses Main.plcproj.
# By name the enabled Legacy.plcproj would be marked disabled (false success); by path it is not.
Reset-State
Set-Scenario @((PU 'Legacy' $false 'Main\Legacy.plcproj'), (PU 'Main' $true 'Legacy\Main.plcproj')) `
             @((TF 'Main' $false (Join-Path $slnDir 'Main\Legacy.plcproj')), (TF 'Legacy' $true (Join-Path $slnDir 'Legacy\Main.plcproj')))
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check 'path: swapped names -> enabled Legacy.plcproj skipped, disabled Main.plcproj built + disabled' ((Status $r) -eq 'Legacy=skipped/False,Main=built/True' -and $d.disabledMatchBy -eq 'path' -and @($d.disabledProjects).Count -eq 0) "$(Status $r) by=$($d.disabledMatchBy)"
Check 'path: swapped names -> completeBuild false + PROJECT_SKIPPED_BY_CONFIGURATION for Legacy, no disabledCheckError' ($d.completeBuild -eq $false -and $d.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and (@($d.skippedProjects) -join ',') -eq 'Legacy' -and $null -eq $d.PSObject.Properties['disabledCheckError']) (J $d.warningCodes)
# path match, issue shape: disabled + skipped by path -> complete
Reset-State
Set-Scenario @((PU 'plc' $true 'plc\plc.plcproj'), (PU 'demo' $false 'demo\demo.plcproj')) `
             @((TF 'plc' $false (Join-Path $slnDir 'PLC\PLC.PLCPROJ')), (TF 'demo' $true (Join-Path $slnDir 'demo\..\demo\demo.plcproj')))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'path: case-insensitive + GetFullPath -> demo disabled, completeBuild true, by path' ((Status $r) -eq 'plc=built/False,demo=disabled/True' -and $r.data.completeBuild -eq $true -and $r.data.disabledMatchBy -eq 'path') "$(Status $r) by=$($r.data.disabledMatchBy)"
# a PLC node without ProjectPath -> back to the name match
Set-Scenario @((PU 'plc' $true 'plc\plc.plcproj'), (PU 'demo' $false 'demo\demo.plcproj')) `
             @((TF 'plc' $false $null), (TF 'demo' $true (Join-Path $slnDir 'demo\demo.plcproj')))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'path: a node without ProjectPath -> name match (disabledMatchBy name)' ((Status $r) -eq 'plc=built/False,demo=disabled/True' -and $r.data.disabledMatchBy -eq 'name') "$(Status $r) by=$($r.data.disabledMatchBy)"
# a node path that matches no entry -> not one to one -> name match
Set-Scenario @((PU 'plc' $true 'plc\plc.plcproj'), (PU 'demo' $false 'demo\demo.plcproj')) `
             @((TF 'plc' $false (Join-Path $slnDir 'elsewhere\plc.plcproj')), (TF 'demo' $true (Join-Path $slnDir 'demo\demo.plcproj')))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'path: a node path without entry -> name match' ($r.data.disabledMatchBy -eq 'name' -and (Status $r) -eq 'plc=built/False,demo=disabled/True') "$(Status $r) by=$($r.data.disabledMatchBy)"
# two nodes on the same path -> not one to one -> name match
Set-Scenario @((PU 'plc' $true 'plc\plc.plcproj'), (PU 'demo' $false 'demo\demo.plcproj')) `
             @((TF 'plc' $false (Join-Path $slnDir 'demo\demo.plcproj')), (TF 'demo' $true (Join-Path $slnDir 'demo\demo.plcproj')))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'path: two nodes on one path -> name match' ($r.data.disabledMatchBy -eq 'name') "by=$($r.data.disabledMatchBy)"
# path not one to one AND name not one to one -> fail closed
Set-Scenario @((PU 'PLC' $false 'PLC\PLC.plcproj'), (PU 'PLC' $false 'Line2\PLC.plcproj')) `
             @((TF 'PLC' $true $null), (TF 'Line2' $false (Join-Path $slnDir 'Line2\PLC.plcproj')))
$r = Build-TcProject -WarningAction SilentlyContinue
Check 'path and name both ambiguous -> fail closed, disabledMatchBy null, disabledCheckError' ($null -eq $r.data.disabledMatchBy -and $r.data.disabledCheckError -match 'neither by .plcproj path' -and @($r.data.disabledProjects).Count -eq 0 -and $r.data.completeBuild -eq $false) "by=$($r.data.disabledMatchBy) $($r.data.disabledCheckError)"
# 8.3 short path of the node vs the long uniqueName of the entry
$longDir = Join-Path $slnDir 'Long Folder Name For Demo PLC'
$null = New-Item -ItemType Directory -Path $longDir -Force
$longFile = Join-Path $longDir 'DemoProjectWithLongName.plcproj'
Set-Content -LiteralPath $longFile -Value '' -Encoding ASCII
$shortFile = (& cmd.exe /c "for %I in (`"$longFile`") do @echo %~sI" | Select-Object -First 1)
if (-not [string]::IsNullOrWhiteSpace($shortFile)) { $shortFile = $shortFile.Trim() } else { $shortFile = $longFile }
"INFO 8.3 path: $shortFile (equals the long path when 8.3 names are off on this volume)"
Reset-State
Set-Scenario @((PU 'plc' $true 'plc\plc.plcproj'), (PU 'DemoProjectWithLongName' $false 'Long Folder Name For Demo PLC\DemoProjectWithLongName.plcproj')) `
             @((TF 'plc' $false (Join-Path $slnDir 'plc\plc.plcproj')), (TF 'OtherName' $true $shortFile))
$r = Build-TcProject -WarningAction SilentlyContinue
Check '8.3 node path matches the long entry path (by path, the names differ)' ((Status $r) -eq 'plc=built/False,DemoProjectWithLongName=disabled/True' -and $r.data.disabledMatchBy -eq 'path' -and $r.data.completeBuild -eq $true) "$(Status $r) by=$($r.data.disabledMatchBy) short=$shortFile"

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
