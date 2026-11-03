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
#   enabled; every PLC disabled + skipped -> not complete (nothing compiled).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/build-disabled-plc.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$stateRoot = Join-Path $env:TEMP ("tcauto-unit-dis-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $stateRoot -Force
$env:TCAUTO_STATE_DIR = Join-Path $stateRoot 'state'
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

& $mod {
    param($s)
    $script:TcSolutionPath = $s
    $script:UtProjects = @()
    $script:UtPlcList = @()
    $script:UtPlcListThrows = $false
    $script:UtBuildStarted = $false
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [PSCustomObject]@{ Mock = $true } }
    function script:Find-TcIdeModalDialog { $null }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; configuration = 'Release'; projectPlatform = 'TwinCAT OS (x64)'; platformSource = 'ActiveConfig' } }
    function script:Get-TcBuildCoverage {
        # fresh objects per call: Build-TcProject marks them (disabled / status)
        $projects = @($script:UtProjects | ForEach-Object {
            [PSCustomObject]@{
                name = $_.name; uniqueName = "Demo\$($_.name)\$($_.name).plcproj"; configuration = 'Release'
                platform = 'TwinCAT OS (x64)'; shouldBuild = $_.build; status = $(if ($_.build) { 'pending' } else { 'skipped' })
            }
        })
        @{ configuration = 'Release|TwinCAT OS (x64)'; error = $null; projects = $projects }
    }
    function script:Get-TcPlcProjectList {
        param($SysManager)
        if ($script:UtPlcListThrows) { throw 'TIPC not readable (unit mock)' }
        @($script:UtPlcList | ForEach-Object {
            [PSCustomObject]@{ name = $_.name; nodePath = "TIPC^$($_.name)"; projectPath = "TIPC^$($_.name)^$($_.name) Project"; adsPort = 851; disabled = [bool]$_.disabled }
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

function Set-Scenario($Projects, $PlcList, [bool]$Throws = $false) {
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
Check '(a) no disabledCheckError' ($null -eq $d.PSObject.Properties['disabledCheckError']) (J $d)
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
Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @((T 'plc' $false), (T 'demo' $true)) $true
$r = Build-TcProject -WarningAction SilentlyContinue
$d = $r.data
Check '(d) disabledCheckError set' ($d.disabledCheckError -match 'TIPC not readable') (J $d)
Check '(d) old behaviour: demo skipped, PROJECT_SKIPPED_BY_CONFIGURATION, completeBuild false' ((Status $r) -eq 'plc=built/False,demo=skipped/False' -and $d.warningCode -eq 'PROJECT_SKIPPED_BY_CONFIGURATION' -and $d.completeBuild -eq $false -and @($d.disabledProjects).Count -eq 0) "$(Status $r) $(J $d.warningCodes)"
Set-Scenario @((P 'plc' $true), (P 'demo' $false)) @((T 'plc' $false), (T 'demo' $true)) $true
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

Remove-Item -LiteralPath $stateRoot -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
