# Unit: build selection check of the solution platform switch (#67), no IDE / runtime needed.
# On 4026 a PLC's Disabled mirrors whether the ACTIVE configuration has a Build.0 for it (measured
# 2026-11-03, openspec/changes/complete-automation-interface/verification/issue67-realmachine.md), so
# Set-TcSolutionPlatform (Set-TcTarget, Enable-TcConfig platform-fix) compares ShouldBuild per PLC
# under the target configuration with the active one before switching and reads it back after.
# A mock DTE (SolutionConfigurations with per-project ShouldBuild) replaces $script:TcDte; the PLC
# tree (Get-TcPlcProjectList / Get-TcSysManager) is mocked in the module scope. Covers:
#   (a) disabled now, target ShouldBuild true  -> BUILD_SELECTION_CHANGED, nothing activated
#   (b) enabled now, target ShouldBuild false  -> BUILD_SELECTION_CHANGED, nothing activated
#   (c) selection the same                     -> switched, data.buildSelection (before/target/after)
#   (d) contexts / PLC tree not readable, no one-to-one PLC match, context missing under the target
#       -> BUILD_SELECTION_UNKNOWN, nothing activated
#   (e) Disabled differs after the switch      -> restored + BUILD_SELECTION_CHANGED (also: readback
#       not readable -> restored + BUILD_SELECTION_UNKNOWN)
#   (f) Enable-TcConfig platform-fix blocked   -> no Build, no Activate, code passed on (also
#       Set-TcTarget passes it on)
#   (g) no PLC project                         -> switched as before, buildSelection = @()
#   plus: unknown-platform candidates (one changes, one does not), already active.
#   Review round 2: ShouldBuild $null in the DTE context (real Get-TcSolutionConfigurations /
#   Get-TcBuildCoverage, Build-TcProject fails closed), Disabled not readable (real
#   Get-TcPlcProjectList -> $null), a disabled PLC that the target builds (S2), restore failure ->
#   build-selection guard (Build-TcProject / Enable-TcConfig refuse, switching back clears it),
#   IDE_* during the readback keeps its code, match by .plcproj path, candidates (one excluded by a
#   change, the other fails the readback; change preferred over not comparable).
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/platform-build-selection.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$OS = 'TwinCAT OS (x64)'
$RT = 'TwinCAT RT (x64)'
$script:tempFiles = @()

# Rows: @{ Name; Sol; SB = @{ <plc> = <bool> } }; every row has the .tsproj (project
# platform = Sol) and one context Demo\<plc>\<plc>.plcproj per key of SB. -NoPlatformName / -SlnRows
# as in platform-project-mismatch.ps1 (unknown solution platform -> project-platform candidates).
function New-MockDte {
    param([object[]]$Rows, [int]$Active, [switch]$NoPlatformName, [object[]]$SlnRows, [hashtable]$Proj = @{})
    if ($null -eq $SlnRows) { $SlnRows = $Rows }
    $sln = Join-Path $env:TEMP ("tcauto-unit-{0}.sln" -f [guid]::NewGuid().ToString('N'))
    $lines = @('Microsoft Visual Studio Solution File, Format Version 12.00', 'Global', "`tGlobalSection(SolutionConfigurationPlatforms) = preSolution")
    foreach ($r in $SlnRows) { $lines += "`t`t$($r.Name)|$($r.Sol) = $($r.Name)|$($r.Sol)" }
    $lines += "`tEndGlobalSection", 'EndGlobal'
    [IO.File]::WriteAllLines($sln, $lines)
    $script:tempFiles += $sln

    $global:MockState = @{ Active = $Active; Initial = $Active; Activations = (New-Object System.Collections.ArrayList) }
    $cfgs = @()
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $r = $Rows[$i]
        $pp = if ($Proj.ContainsKey($i)) { $Proj[$i] } else { $r.Sol }
        $ctx = @([PSCustomObject]@{ ProjectName = 'Demo\Demo.tsproj'; ConfigurationName = $r.Name; PlatformName = $pp; ShouldBuild = $true })
        foreach ($k in @($r.SB.Keys | Sort-Object)) {
            $ctx += [PSCustomObject]@{ ProjectName = "Demo\$k\$k.plcproj"; ConfigurationName = $r.Name; PlatformName = $pp; ShouldBuild = $r.SB[$k] }
        }
        $c = [PSCustomObject]@{ Name = $r.Name; PlatformName = $(if ($NoPlatformName) { $null } else { $r.Sol }); SolutionContexts = $ctx; MockIndex = $i; MockSol = $r.Sol }
        $c | Add-Member -MemberType ScriptMethod -Name Activate -Value {
            $null = $global:MockState.Activations.Add($this.MockIndex)
            $global:MockState.Active = $this.MockIndex
        }
        $cfgs += $c
    }
    $global:MockCfgs = $cfgs
    $sb = [PSCustomObject]@{ SolutionConfigurations = $cfgs }
    $sb | Add-Member -MemberType ScriptProperty -Name ActiveConfiguration -Value { $global:MockCfgs[$global:MockState.Active] }
    $props = [PSCustomObject]@{}
    $props | Add-Member -MemberType ScriptMethod -Name Item -Value {
        param($n)
        if ($n -ne 'ActiveConfig') { throw "no property $n" }
        $a = $global:MockCfgs[$global:MockState.Active]
        [PSCustomObject]@{ Value = "$($a.Name)|$($a.MockSol)" }
    }
    $dte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ FullName = $sln; SolutionBuild = $sb; Properties = $props } }
    & $mod { param($d) $script:TcDte = $d; $script:TcSolutionPath = $null } $dte
}

# PLC tree: @{ name; disabled; flip (Disabled toggles once another configuration is active) }.
# $global:PlcListThrows: 'always' | 'after-switch' | $null. $global:CoverageError: Get-TcBuildCoverage error.
# disabled $null = not readable. $global:PlcListThrowMsg: the text thrown (default 'TIPC not readable (mock)').
function Set-Tree([object[]]$Nodes) { $global:PlcTree = @($Nodes); $global:PlcListThrows = $null; $global:PlcListThrowMsg = $null; $global:CoverageError = $null }
function N([string]$Name, $Disabled, [switch]$Flip, [string]$File) { @{ name = $Name; disabled = $Disabled; flip = [bool]$Flip; file = $(if ($File) { $File } else { $null }) } }

& $mod {
    $script:TcIdeProcessId = $null
    $script:UtOrigCoverage = ${function:Get-TcBuildCoverage}
    $script:UtOrigPlcList = ${function:Get-TcPlcProjectList}
    function script:Assert-TcConnection { }
    function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $null }
    function script:Get-TcSysManager {
        [CmdletBinding()] param([switch]$Refresh)
        $o = [PSCustomObject]@{ Mock = $true }
        $o | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '199.5.42.250.1.1' }
        $o | Add-Member -MemberType ScriptMethod -Name SetTargetNetId -Value { param($id) }
        $o
    }
    function script:Get-TcPlcProjectList {
        [CmdletBinding()] param($SysManager)
        $switched = ($global:MockState.Active -ne $global:MockState.Initial)
        if ($global:PlcListThrows -eq 'always' -or ($global:PlcListThrows -eq 'after-switch' -and $switched)) {
            if ($global:PlcListThrowMsg) { throw $global:PlcListThrowMsg } else { throw 'TIPC not readable (mock)' }
        }
        @($global:PlcTree | ForEach-Object {
                $d = $_.disabled
                if ($null -ne $d) { $d = [bool]$d; if ($_.flip -and $switched) { $d = -not $d } }
                [PSCustomObject]@{ name = $_.name; nodePath = "TIPC^$($_.name)"; projectPath = "TIPC^$($_.name)^$($_.name) Project"; adsPort = 851; disabled = $d; projectFile = $_.file }
            })
    }
    # $global:NullShouldBuild = '<SolutionPlatform>|<project>': that context's ShouldBuild reads $null
    # (a failing COM getter, caught in Get-TcSolutionConfigurations)
    $script:UtOrigConfigs = ${function:Get-TcSolutionConfigurations}
    function script:Get-TcSolutionConfigurations {
        $list = @(& $script:UtOrigConfigs)
        if ($null -ne $global:NullShouldBuild) {
            foreach ($c in $list) {
                foreach ($x in @($c.Contexts)) { if ("$($c.SolutionPlatform)|$($x.ProjectName)" -eq $global:NullShouldBuild) { $x.ShouldBuild = $null } }
            }
        }
        $list
    }
    function script:Get-TcBuildCoverage {
        if ($null -ne $global:CoverageError) { return @{ configuration = $null; error = $global:CoverageError; projects = @() } }
        & $script:UtOrigCoverage
    }
}

try {
    # --- (a) #67 shape: PLC B disabled under RT (no Build.0 there), built under OS ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true; B = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $false } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $true))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $ch = @($r.buildSelectionChanges)
    Check '(a) disabled -> built: BUILD_SELECTION_CHANGED' ($r.error.code -eq 'BUILD_SELECTION_CHANGED' -and -not $r.success) "$($r.error.code): $($r.error.message)"
    Check '(a) nothing activated, platform unchanged' ($global:MockState.Activations.Count -eq 0 -and $r.platform -eq $RT -and -not $r.platformChanged) "activations: $($global:MockState.Activations -join ',') platform=$($r.platform)"
    Check '(a) buildSelectionChanges = B, current false/disabled, target true, target configuration' ($ch.Count -eq 1 -and $ch[0].plc -eq 'B' -and $ch[0].project -eq 'Demo\B\B.plcproj' -and $ch[0].current.shouldBuild -eq $false -and $ch[0].current.disabled -eq $true -and $ch[0].target.shouldBuild -eq $true -and $ch[0].configuration -eq "Release|$OS" -and $ch[0].current.configuration -eq "Release|$RT") (J $ch)
    Check '(a) buildSelection lists both PLCs' (@($r.buildSelection).Count -eq 2 -and @($r.buildSelection | Where-Object { $_.plc -eq 'A' -and -not $_.changed }).Count -eq 1) (J $r.buildSelection)
    Check '(a) message names B, hint says Configuration Manager' ($r.error.message -match "'B'" -and $r.error.message -match 'shouldBuild false -> true' -and $r.error.hint -match 'Configuration Manager' -and $r.error.hint -match '650882187') "$($r.error.message) | $($r.error.hint)"

    # --- (b) enabled now, target does not build it ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $false } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $ch = @($r.buildSelectionChanges)
    Check '(b) enabled -> not built: BUILD_SELECTION_CHANGED, nothing activated' ($r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $global:MockState.Activations.Count -eq 0) "$($r.error.code) activations: $($global:MockState.Activations -join ',')"
    Check '(b) change: current true / not disabled, target false' ($ch.Count -eq 1 -and $ch[0].current.shouldBuild -eq $true -and $ch[0].current.disabled -eq $false -and $ch[0].target.shouldBuild -eq $false) (J $ch)

    # --- (c) the same selection: switched, buildSelection with before / target / after ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true; B = $false } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $false } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $true))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $bs = @($r.buildSelection)
    Check '(c) switched' ($r.success -and $null -eq $r.error -and ($global:MockState.Activations -join ',') -eq '0' -and $r.platform -eq $OS -and $r.platformChanged) "$($r.error.code) $($r.error.message) activations: $($global:MockState.Activations -join ',')"
    Check '(c) buildSelection: 2 entries, after = current, none changed' ($bs.Count -eq 2 -and @($bs | Where-Object { $_.changed }).Count -eq 0 -and @($r.buildSelectionChanges).Count -eq 0 -and
        @($bs | Where-Object { $_.plc -eq 'B' -and $_.current.disabled -eq $true -and $_.target.shouldBuild -eq $false -and $_.after.shouldBuild -eq $false -and $_.after.disabled -eq $true -and $_.nodePath -eq 'TIPC^B' }).Count -eq 1) (J $bs)

    # --- (d) not readable -> BUILD_SELECTION_UNKNOWN, nothing activated ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false))
    $global:PlcListThrows = 'always'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(d) PLC tree not readable -> BUILD_SELECTION_UNKNOWN' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0 -and $r.error.message -match 'TIPC not readable' -and $r.error.hint -match 'fail closed') "$($r.error.code): $($r.error.message)"

    Set-Tree @((N 'A' $false))
    $global:CoverageError = 'SolutionContexts boom (mock)'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(d) contexts not readable -> BUILD_SELECTION_UNKNOWN' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0 -and $r.error.message -match 'boom') "$($r.error.code): $($r.error.message)"

    # disabled 'Legacy' + enabled 'Main' whose .plcproj is named otherwise (no ProjectPath): not one to one
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ Legacy = $false; Other = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ Legacy = $false; Other = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'Main' $false), (N 'Legacy' $true))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(d) PLC match not one to one -> BUILD_SELECTION_UNKNOWN' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0 -and $r.error.message -match 'one to one' -and $r.error.message -match "enabled PLC 'Main' matches no") "$($r.error.code): $($r.error.message)"
    # the same names without a disabled PLC: nothing to attribute, the switch goes on
    Set-Tree @((N 'Main' $false), (N 'Legacy' $false))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(d) no disabled PLC: no one-to-one match needed' ($r.success -and ($global:MockState.Activations -join ',') -eq '0') "$($r.error.code): $($r.error.message)"

    # PLC context missing under the target configuration
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $false))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(d) context missing under the target -> BUILD_SELECTION_UNKNOWN' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0 -and $r.error.message -match 'B\.plcproj') "$($r.error.code): $($r.error.message)"
    # ShouldBuild not readable under the target
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false))
    $global:NullShouldBuild = "$OS|Demo\A\A.plcproj"
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $global:NullShouldBuild = $null
    Check '(d) target ShouldBuild null (wrapper) -> BUILD_SELECTION_UNKNOWN' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0) "$($r.error.code): $($r.error.message)"
    # M1: ShouldBuild $null in the DTE context itself, through the real Get-TcSolutionConfigurations
    # (reviewer S2 shape: target ShouldBuild null, Disabled read as false) -> never success
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true; B = $null } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $false } }
    )
    New-MockDte -Rows $rows -Active 1
    $cfgs = @(& $mod { Get-TcSolutionConfigurations })
    $bOs = @($cfgs[0].Contexts | Where-Object { $_.ProjectName -match 'B\.plcproj' })
    Check 'M1 Get-TcSolutionConfigurations keeps ShouldBuild $null' ($bOs.Count -eq 1 -and $null -eq $bOs[0].ShouldBuild) (J $bOs)
    Set-Tree @((N 'A' $false), (N 'B' $false))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'M1 target ShouldBuild $null (DTE) -> BUILD_SELECTION_UNKNOWN, not switched' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0) "$($r.error.code): $($r.error.message)"
    # active ShouldBuild $null: Get-TcBuildCoverage 'unreadable', the switch and Build-TcProject fail closed
    New-MockDte -Rows $rows -Active 0
    $cov = & $mod { Get-TcBuildCoverage }
    $covB = @($cov.projects | Where-Object { $_.name -eq 'B' })
    Check 'M1 Get-TcBuildCoverage: ShouldBuild $null -> status unreadable' ($covB.Count -eq 1 -and $null -eq $covB[0].shouldBuild -and $covB[0].status -eq 'unreadable') (J $cov.projects)
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'M1 active ShouldBuild $null -> BUILD_SELECTION_UNKNOWN, not switched' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0 -and $r.error.message -match 'B\.plcproj') "$($r.error.code): $($r.error.message)"
    $b = Build-TcProject
    Check 'M1 Build-TcProject: ShouldBuild $null -> BUILD_COVERAGE_UNKNOWN, build not started' ((-not $b.success) -and $b.error.code -eq 'BUILD_COVERAGE_UNKNOWN' -and (@($b.data.unreadableProjects) -join ',') -eq 'B' -and $b.data.coverageComplete -eq $false) "$($b.error.code): $($b.error.message)"
    # N3: Disabled not readable
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $null))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'N3 Disabled $null -> BUILD_SELECTION_UNKNOWN, not switched' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0 -and $r.error.message -match 'Disabled') "$($r.error.code): $($r.error.message)"
    $nodeNoDis = [PSCustomObject]@{ Name = 'X'; PathName = 'TIPC^X'; Xml = '<TreeItem><AdsPort>851</AdsPort></TreeItem>' }
    $nodeNoDis | Add-Member -MemberType ScriptMethod -Name ProduceXml -Value { param($x) $this.Xml }
    $tipc = [PSCustomObject]@{ ChildCount = 1; Nodes = @($nodeNoDis) }
    $tipc | Add-Member -MemberType ScriptMethod -Name Child -Value { param($i) $this.Nodes[$i - 1] }
    $smList = [PSCustomObject]@{ Tipc = $tipc }
    $smList | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) $this.Tipc }
    $real = @(& $mod { param($s) & $script:UtOrigPlcList -SysManager $s } $smList)
    Check 'N3 Get-TcPlcProjectList: Disabled not readable -> $null (not enabled)' ($real.Count -eq 1 -and $null -eq $real[0].disabled) (J $real)

    # S6: match by .plcproj path (node names differ from the .plcproj names, a disabled node)
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $false; B = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $false; B = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    & $mod { $script:TcSolutionPath = 'C:\UnitSol\Demo.sln' }
    Set-Tree @((N 'Main' $true -File 'C:\UnitSol\Demo\A\A.plcproj'), (N 'Other' $false -File 'C:\UnitSol\Demo\B\B.plcproj'))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $mainSel = @($r.buildSelection | Where-Object { $_.project -eq 'Demo\A\A.plcproj' })
    Check 'S6 match by .plcproj path: switched, A attributed to disabled node Main' ($r.success -and $mainSel.Count -eq 1 -and $mainSel[0].plc -eq 'Main' -and $mainSel[0].current.disabled -eq $true -and $mainSel[0].nodePath -eq 'TIPC^Main') "$($r.error.code) $($r.error.message) $(J $r.buildSelection)"

    # PLC tree item but no .plcproj context at all
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{} }
        @{ Name = 'Release'; Sol = $RT; SB = @{} }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(d) PLC tree item without .plcproj context -> BUILD_SELECTION_UNKNOWN' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:MockState.Activations.Count -eq 0) "$($r.error.code): $($r.error.message)"

    # --- (e) Disabled differs after the switch -> restore + BUILD_SELECTION_CHANGED ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true; B = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $true } }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $false -Flip))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $ch = @($r.buildSelectionChanges)
    $ac = & $mod { $script:TcDte.Solution.Properties.Item('ActiveConfig').Value }
    Check '(e) readback differs -> BUILD_SELECTION_CHANGED' ($r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $r.error.message -match 're-activated') "$($r.error.code): $($r.error.message)"
    Check '(e) restored to the previous configuration' ($r.restored -eq $true -and ($global:MockState.Activations -join ',') -eq '0,1' -and $ac -eq "Release|$RT" -and $r.platform -eq $RT -and -not $r.platformChanged) "restored=$($r.restored) activations: $($global:MockState.Activations -join ',') ActiveConfig=$ac"
    Check '(e) change: B disabled false -> true after' ($ch.Count -eq 1 -and $ch[0].plc -eq 'B' -and $ch[0].current.disabled -eq $false -and $ch[0].after.disabled -eq $true) (J $ch)
    Check '(e) restored: no guard, generic hint' ($null -eq (& $mod { Get-TcBuildSelectionGuard }) -and $r.error.hint -notmatch 'Set-TcTarget -AmsNetId') "$($r.error.hint)"

    # S2: disabled now (current ShouldBuild true) and built by the target -> change (fail closed)
    Set-Tree @((N 'A' $false), (N 'B' $true))
    New-MockDte -Rows $rows -Active 1
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'S2 disabled + target builds -> BUILD_SELECTION_CHANGED, nothing activated' ($r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $global:MockState.Activations.Count -eq 0 -and @($r.buildSelectionChanges).Count -eq 1 -and $r.buildSelectionChanges[0].plc -eq 'B') "$($r.error.code) $(J $r.buildSelectionChanges)"

    # S3: IDE_CRASHED while reading back -> restored, the code and its hint are kept
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $false))
    $global:PlcListThrows = 'after-switch'; $global:PlcListThrowMsg = 'IDE_CRASHED: the IDE is gone (unit mock)'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'S3 readback IDE_CRASHED keeps its code and hint, restored' ($r.error.code -eq 'IDE_CRASHED' -and $r.error.hint -match 'Connect-TcIde' -and $r.restored -eq $true) "$($r.error.code) restored=$($r.restored) $($r.error.hint)"

    # S1 / S6: change read back AND the restore fails -> guard, stuck hint; Build / Enable refuse;
    # switching back is allowed and clears the guard
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $false -Flip))
    $global:MockCfgs[1] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { $null = $global:MockState.Activations.Add($this.MockIndex); throw 'restore boom (mock)' }
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $g = & $mod { Get-TcBuildSelectionGuard }
    Check 'S1 restore failed -> BUILD_SELECTION_CHANGED, restored false' ($r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $r.restored -eq $false -and $r.platform -eq $OS -and $r.error.message -match 'could not be restored') "$($r.error.code) restored=$($r.restored) platform=$($r.platform)"
    Check 'S1 stuck hint: stays at target, Set-TcTarget back, no Build / Enable' ($r.error.hint -match [regex]::Escape("Release|$OS") -and $r.error.hint -match [regex]::Escape("Set-TcTarget -AmsNetId <id> -Platform '$RT' -Configuration 'Release'") -and $r.error.hint -match 'Build-TcProject / Enable-TcConfig' -and $r.error.hint -notmatch '\u5DF2\u5207\u56DE') "$($r.error.hint)"
    Check 'S1 guard recorded with the previous configuration' ($null -ne $g -and $g.previous -eq "Release|$RT" -and $g.reason -match "'B'") (J $g)
    $b = Build-TcProject
    Check 'S1 Build-TcProject refused while the guard is recorded' ((-not $b.success) -and $b.error.code -eq 'BUILD_SELECTION_CHANGED' -and $b.data.buildSelectionGuard.previous -eq "Release|$RT" -and $b.error.hint -match [regex]::Escape("-Platform '$RT'")) "$($b.error.code) $($b.error.message)"
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check 'S1 Enable-TcConfig refused while the guard is recorded, nothing activated' ((-not $e.success) -and $e.error.code -eq 'BUILD_SELECTION_CHANGED' -and $e.data.activated -eq $false -and ($global:MockState.Activations -join ',') -eq '0,1') "$($e.error.code) activations: $($global:MockState.Activations -join ',')"
    $global:MockCfgs[1] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { $null = $global:MockState.Activations.Add($this.MockIndex); $global:MockState.Active = $this.MockIndex }
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'S1 switching back to the previous configuration: allowed, guard cleared' ($r.success -and $r.platform -eq $RT -and $null -eq (& $mod { Get-TcBuildSelectionGuard })) "$($r.error.code) $($r.error.message)"
    # guard cleared also when the previous configuration is already active (switched back in XAE)
    & $mod { param($p) Set-TcBuildSelectionGuard -PreviousConfiguration 'Release' -PreviousPlatform $p -Left 'Release|X' -Changes 'unit' } $RT | Out-Null
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'S1 already at the previous configuration clears the guard' ($r.success -and $null -eq (& $mod { Get-TcBuildSelectionGuard })) "$($r.error.code)"
    # a guard for another configuration is not cleared by an unrelated switch
    & $mod { Set-TcBuildSelectionGuard -PreviousConfiguration 'Debug' -PreviousPlatform 'Y' -Left 'Release|X' -Changes 'unit' } | Out-Null
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'S1 guard of another configuration stays' ($null -ne (& $mod { Get-TcBuildSelectionGuard })) 'guard gone'
    & $mod { Clear-TcBuildSelectionGuard } | Out-Null

    # --- round 3 ---
    # S-C: the refusal hint is the guard's own text, not the generic BUILD_SELECTION_CHANGED hint
    & $mod { param($p) Set-TcBuildSelectionGuard -PreviousConfiguration 'Release' -PreviousPlatform $p -Left 'Release|X' -Changes 'unit change' } $RT | Out-Null
    $b = Build-TcProject
    $generic = & $mod { Get-TcErrorHint -Code 'BUILD_SELECTION_CHANGED' }
    Check 'S-C guard refusal hint: own text with the way back, not the generic hint' ($b.error.code -eq 'BUILD_SELECTION_CHANGED' -and -not $b.error.hint.Contains($generic) -and $b.error.hint -match [regex]::Escape("-Platform '$RT' -Configuration 'Release'") -and $b.error.hint -match 'unit change') "$($b.error.hint)"
    # G5 / S-B: a complete build (Clear-TcBuildRequired) keeps the build-selection record, drops the rest
    & $mod { Set-TcBuildRequired -Kind 'code-changed' -Reason 'unit code change' -WarningAction SilentlyContinue } | Out-Null
    & $mod { Clear-TcBuildRequired } | Out-Null
    $g = & $mod { Get-TcBuildSelectionGuard }
    $br = & $mod { Get-TcBuildRequired }
    $kinds = @((& $mod { param($e) Get-TcBuildRequiredReasons $e } $br).Keys)
    Check 'G5 Clear-TcBuildRequired keeps build-selection only (with its fields)' ($null -ne $g -and $g.previousPlatform -eq $RT -and $g.previousConfiguration -eq 'Release' -and -not $g.legacy -and ($kinds -join ',') -eq 'build-selection') "kinds=$($kinds -join ',') g=$(J $g)"
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'G5 guard then cleared by the (already active) previous configuration' ($r.success -and $null -eq (& $mod { Get-TcBuildSelectionGuard })) "$($r.error.code)"

    # N-a: names with an apostrophe; previous configuration without name matches by platform
    & $mod { param($p) Set-TcBuildSelectionGuard -PreviousConfiguration "Rel'ease" -PreviousPlatform $p -Left 'x' -Changes 'y' } $RT | Out-Null
    $g = & $mod { Get-TcBuildSelectionGuard }
    $hint = & $mod { param($x) Get-TcBuildSelectionGuardHint -Guard $x } $g
    $m1 = & $mod { param($x, $p) Test-TcBuildSelectionGuardTarget -Guard $x -Configuration "Rel'ease" -Platform $p } $g $RT
    $m2 = & $mod { param($x, $p) Test-TcBuildSelectionGuardTarget -Guard $x -Configuration 'Release' -Platform $p } $g $RT
    Check "N-a Rel'ease: stored as a field, matched exactly, quoted in the hint" ($g.previousConfiguration -eq "Rel'ease" -and $g.previous -eq "Rel'ease|$RT" -and $m1 -and -not $m2 -and $hint -match [regex]::Escape("-Configuration 'Rel''ease'")) "g=$(J $g) m1=$m1 m2=$m2 hint=$hint"
    & $mod { Clear-TcBuildSelectionGuard } | Out-Null
    & $mod { param($p) Set-TcBuildSelectionGuard -PreviousConfiguration '' -PreviousPlatform $p -Left 'x' -Changes 'y' } $RT | Out-Null
    $g = & $mod { Get-TcBuildSelectionGuard }
    $m = & $mod { param($x, $p) Test-TcBuildSelectionGuardTarget -Guard $x -Configuration 'Release' -Platform $p } $g $RT
    Check 'N-a previous without configuration: matched by platform' ($m -and $g.previous -eq $RT) "g=$(J $g) m=$m"
    & $mod { Clear-TcBuildSelectionGuard } | Out-Null
    # legacy record (no buildSelectionGuard field): never matched, hint names the state file
    & $mod { Set-TcBuildRequired -Kind 'build-selection' -Reason "old text previous configuration 'Release|TwinCAT RT (x64)'" -WarningAction SilentlyContinue } | Out-Null
    $g = & $mod { Get-TcBuildSelectionGuard }
    $hint = & $mod { param($x) Get-TcBuildSelectionGuardHint -Guard $x } $g
    $m = & $mod { param($x, $p) Test-TcBuildSelectionGuardTarget -Guard $x -Configuration 'Release' -Platform $p } $g $RT
    $file = & $mod { Get-TcBuildRequiredFile }
    Check 'N-a legacy record: not matched, hint = manual removal of build-required.json' ($g.legacy -and -not $m -and $hint.Contains($file)) "g=$(J $g) hint=$hint"
    & $mod { Clear-TcBuildSelectionGuard } | Out-Null

    # G4 / S-A: guard recorded by an unreadable readback whose restore failed; switching back with
    # the build selection still unreadable is allowed and clears the guard
    $rowsG = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true; B = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $true } }
    )
    New-MockDte -Rows $rowsG -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $false))
    $global:PlcListThrows = 'after-switch'
    $global:MockCfgs[1] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { if ($global:RestoreBroken) { throw 'restore boom (mock)' }; $null = $global:MockState.Activations.Add($this.MockIndex); $global:MockState.Active = $this.MockIndex }
    $global:RestoreBroken = $true
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $g = & $mod { Get-TcBuildSelectionGuard }
    Check 'G4 unreadable readback + restore failed -> guard' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $r.restored -eq $false -and $null -ne $g -and $g.previous -eq "Release|$RT") "$($r.error.code) restored=$($r.restored) g=$(J $g)"
    # IDE error while switching back: still blocked, hint names the guard and the manual way back
    $global:RestoreBroken = $false
    $global:PlcListThrows = 'always'; $global:PlcListThrowMsg = 'IDE_CRASHED: the IDE is gone (unit mock)'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'G4 IDE_CRASHED while switching back: blocked, hint names guard + manual switch' ($r.error.code -eq 'IDE_CRASHED' -and $r.error.hint -match 'guard' -and $r.error.hint -match 'Set-TcTarget' -and $global:MockState.Active -eq 0) "$($r.error.code) $($r.error.hint)"
    $global:PlcListThrowMsg = $null
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'G4 switching back with the build selection unreadable: allowed, guard cleared' ($r.success -and $r.platform -eq $RT -and -not [string]::IsNullOrWhiteSpace([string]$r.buildSelectionError) -and $null -eq (& $mod { Get-TcBuildSelectionGuard })) "$($r.error.code) $($r.error.message)"
    $global:PlcListThrows = $null

    # S-D: Enable-TcConfig refuses before anything when a PLC's Disabled cannot be read
    New-MockDte -Rows $rowsG -Active 0
    Set-Tree @((N 'A' $false), (N 'B' $null))
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check 'S-D Enable-TcConfig: Disabled $null -> BUILD_SELECTION_UNKNOWN, nothing done' ((-not $e.success) -and $e.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and (@($e.data.plcsWithoutDisabled) -join ',') -eq 'B' -and $e.data.activated -eq $false -and $global:MockState.Activations.Count -eq 0 -and $e.error.hint -match 'Disabled') "$($e.error.code): $($e.error.message)"
    Set-Tree @((N 'A' $false), (N 'B' $false))
    # readback not readable -> restore + BUILD_SELECTION_UNKNOWN
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $false))
    $global:PlcListThrows = 'after-switch'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(e) readback not readable -> restored + BUILD_SELECTION_UNKNOWN' ($r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $r.restored -eq $true -and ($global:MockState.Activations -join ',') -eq '0,1') "$($r.error.code) restored=$($r.restored) activations: $($global:MockState.Activations -join ',')"

    # --- (g) no PLC project: switched as before ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{} }
        @{ Name = 'Release'; Sol = $RT; SB = @{} }
    )
    New-MockDte -Rows $rows -Active 1
    Set-Tree @()
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check '(g) no PLC project: switched, buildSelection empty' ($r.success -and ($global:MockState.Activations -join ',') -eq '0' -and $null -ne $r.buildSelection -and @($r.buildSelection).Count -eq 0 -and @($r.buildSelectionChanges).Count -eq 0) "$($r.error.code) $($r.error.message) bs=$(J $r.buildSelection)"

    # --- already active: nothing switched, buildSelection informational ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $false } }
    )
    New-MockDte -Rows $rows -Active 0
    Set-Tree @((N 'A' $false))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'already active: success, no activation, buildSelection' ($r.success -and $global:MockState.Activations.Count -eq 0 -and @($r.buildSelection).Count -eq 1 -and $r.buildSelection[0].after.shouldBuild -eq $true) "$($r.error.code) bs=$(J $r.buildSelection)"

    # --- unknown solution platforms (VS2022, .sln unusable): the candidate whose selection would
    # change is not activated, the other one is ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true } }
        @{ Name = 'Release'; Sol = 'X1'; SB = @{ A = $false } }
        @{ Name = 'Release'; Sol = 'X2'; SB = @{ A = $true } }
    )
    New-MockDte -Rows $rows -Active 0 -NoPlatformName -SlnRows @($rows[0]) -Proj @{ 0 = $OS; 1 = $RT; 2 = $RT }
    $global:MockCfgs[1].MockSol = $RT; $global:MockCfgs[2].MockSol = $RT
    Set-Tree @((N 'A' $false))
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'candidates: the changing one is skipped' ($r.success -and ($global:MockState.Activations -join ',') -eq '2' -and $r.platformMatchedBy -eq 'projectPlatform') "$($r.error.code) $($r.error.message) activations: $($global:MockState.Activations -join ',')"
    New-MockDte -Rows @($rows[0], $rows[1]) -Active 0 -NoPlatformName -SlnRows @($rows[0]) -Proj @{ 0 = $OS; 1 = $RT }
    $global:MockCfgs[1].MockSol = $RT
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'candidates: all change -> BUILD_SELECTION_CHANGED' ($r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $global:MockState.Activations.Count -eq 0) "$($r.error.code) activations: $($global:MockState.Activations -join ',')"
    # the candidate with a change is left out, the other one fails the readback -> PLATFORM_SET_FAILED
    # naming the left-out candidate (N2)
    New-MockDte -Rows $rows -Active 0 -NoPlatformName -SlnRows @($rows[0]) -Proj @{ 0 = $OS; 1 = $RT; 2 = $RT }
    $global:MockCfgs[1].MockSol = $RT; $global:MockCfgs[2].MockSol = $RT
    $global:MockCfgs[2] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { $null = $global:MockState.Activations.Add($this.MockIndex) }
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'candidates: left-out change named in PLATFORM_SET_FAILED' ($r.error.code -eq 'PLATFORM_SET_FAILED' -and ($global:MockState.Activations -join ',') -eq '2,0' -and $r.error.message -match 'Not tried because of the build selection' -and $r.error.message -match '#1' -and @($r.buildSelectionChanges).Count -eq 1) "$($r.error.code) activations: $($global:MockState.Activations -join ',') $($r.error.message)"
    # one candidate not comparable, the other with a change -> BUILD_SELECTION_CHANGED (N2)
    $rows3 = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true } }
        @{ Name = 'Release'; Sol = 'X1'; SB = @{ A = $true; C = $true } }
        @{ Name = 'Release'; Sol = 'X2'; SB = @{ A = $false } }
    )
    New-MockDte -Rows $rows3 -Active 0 -NoPlatformName -SlnRows @($rows3[0]) -Proj @{ 0 = $OS; 1 = $RT; 2 = $RT }
    $global:MockCfgs[1].MockSol = $RT; $global:MockCfgs[2].MockSol = $RT
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    Check 'candidates: change preferred over not comparable' ($r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $global:MockState.Activations.Count -eq 0 -and @($r.buildSelectionChanges).Count -eq 1) "$($r.error.code) $($r.error.message)"

    # --- (f) Set-TcTarget and Enable-TcConfig pass the codes on; Enable-TcConfig stops before Build ---
    $rows = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true; B = $true } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $false } }
    )
    & $mod {
        $global:Calls = @{ Build = 0; Activate = 0; SystemState = 0 }
        function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
        function script:Build-TcProject { $global:Calls.Build++; New-TcResult -Success $true -Data ([PSCustomObject]@{ completeBuild = $true; buildSec = 0 }) }
        function script:Invoke-TcActivateWithDeadline { param($TimeoutSec, $AmsNetId) $global:Calls.Activate++ }
        function script:Set-TcSystemState { $global:Calls.SystemState++; New-TcResult -Success $true -Data ([PSCustomObject]@{}) }
        function script:Get-TcIdeMemoryInfo { $null }
    }
    New-MockDte -Rows $rows -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $true))
    $r = Set-TcTarget -AmsNetId '199.5.42.250.1.1' -Platform 'TwinCAT OS (x64)'
    Check '(f) Set-TcTarget: BUILD_SELECTION_CHANGED passed on with data' ((-not $r.success) -and $r.error.code -eq 'BUILD_SELECTION_CHANGED' -and @($r.data.buildSelectionChanges).Count -eq 1 -and $r.data.buildSelectionChanges[0].plc -eq 'B' -and @($r.data.buildSelection).Count -eq 2 -and $global:MockState.Activations.Count -eq 0 -and $r.error.hint -match 'Configuration Manager') "$($r.error.code) $(J $r.data.buildSelectionChanges)"

    New-MockDte -Rows $rows -Active 1
    $r = Enable-TcConfig -Force -WarningAction SilentlyContinue
    $fix = @($r.data.steps | Where-Object { $_.step -eq 'platform-fix' })
    Check '(f) Enable-TcConfig -Force: BUILD_SELECTION_CHANGED passed on' ((-not $r.success) -and $r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $r.error.hint -match 'Configuration Manager') "$($r.error.code): $($r.error.message)"
    Check '(f) Enable-TcConfig -Force: no Build, no Activate, no state change, nothing switched' ($global:Calls.Build -eq 0 -and $global:Calls.Activate -eq 0 -and $global:Calls.SystemState -eq 0 -and $global:MockState.Activations.Count -eq 0 -and -not $r.data.activated -and -not $r.data.platformFixed) (J $global:Calls)
    Check '(f) Enable-TcConfig -Force: data.buildSelectionChanges, step platform-fix failed' (@($r.data.buildSelectionChanges).Count -eq 1 -and $r.data.buildSelectionChanges[0].plc -eq 'B' -and $fix.Count -eq 1 -and -not $fix[0].ok -and @($r.data.steps | Where-Object { $_.step -eq 'platform-fix-build' }).Count -eq 0) (J $r.data.steps)

    New-MockDte -Rows $rows -Active 1
    $r = Enable-TcConfig -WarningAction SilentlyContinue
    Check '(f) Enable-TcConfig (no -Force): blocked the same way' ((-not $r.success) -and $r.error.code -eq 'BUILD_SELECTION_CHANGED' -and $global:Calls.Build -eq 0 -and $global:Calls.Activate -eq 0) "$($r.error.code) $(J $global:Calls)"

    New-MockDte -Rows $rows -Active 1
    $global:PlcListThrows = 'always'
    $r = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(f) Enable-TcConfig -Force: BUILD_SELECTION_UNKNOWN passed on, no Build' ((-not $r.success) -and $r.error.code -eq 'BUILD_SELECTION_UNKNOWN' -and $global:Calls.Build -eq 0 -and $global:Calls.Activate -eq 0 -and $global:MockState.Activations.Count -eq 0) "$($r.error.code): $($r.error.message)"

    # selection the same: platform-fix goes on to the build (buildSelection reported)
    $same = @(
        @{ Name = 'Release'; Sol = $OS; SB = @{ A = $true; B = $false } }
        @{ Name = 'Release'; Sol = $RT; SB = @{ A = $true; B = $false } }
    )
    New-MockDte -Rows $same -Active 1
    Set-Tree @((N 'A' $false), (N 'B' $true))
    $r = Enable-TcConfig -NoLogin -WarningAction SilentlyContinue
    # #68: this run fails later (BUILD_REQUIRED: the mocked build does not clear the switch record), so
    # platformFixed is $false on the failure result; platformSwitched keeps the fact
    Check '(f) Enable-TcConfig: selection the same -> switched and built, buildSelection in data' ($global:Calls.Build -eq 1 -and ($global:MockState.Activations -join ',') -eq '0' -and @($r.data.buildSelection).Count -eq 2 -and $r.data.platformSwitched -and -not $r.success -and $r.error.code -eq 'BUILD_REQUIRED' -and -not $r.data.platformFixed) "$($r.error.code) $($r.error.message) calls=$(J $global:Calls)"
}
finally {
    foreach ($f in $script:tempFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
}

"failed: $fail"
exit $fail
