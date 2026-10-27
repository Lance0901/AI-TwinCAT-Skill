# Unit: solution platform vs project platform (issue #33), no IDE / runtime needed.
# A mock DTE (PSCustomObject + ScriptMethod) replaces $script:TcDte; the .sln goes to $env:TEMP.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/platform-project-mismatch.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# BUILD_REQUIRED state file of this run (never the real %TEMP%\TwinCATAutomation one).
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))

# No modal-dialog watchdog in Invoke-TcComRetry (no IDE process).
& $mod { $script:TcIdeProcessId = $null }

$OS = 'TwinCAT OS (x64)'
$RT = 'TwinCAT RT (x64)'
$ARMT2 = 'TwinCAT OS (ARMT2)'
$CE7 = 'TwinCAT CE7 (ARMV7)'

# Rows: @{ Name; Sol (solution platform); Proj (project platform of tsproj + plcproj); SB }
# -NoPlatformName: cfg.PlatformName = $null (VS2022). -SlnRows: what goes into the .sln
# (default = the rows themselves). -Broken: indices whose Activate() does not take effect.
function New-MockDte {
    param([object[]]$Rows, [int]$Active, [switch]$NoPlatformName, [object[]]$SlnRows, [int[]]$Broken = @(), [string]$Folder = 'Demo', [switch]$NoTsproj, [switch]$Unsaved)
    if ($null -eq $SlnRows) { $SlnRows = $Rows }
    $sln = Join-Path $env:TEMP ("tcauto-unit-{0}.sln" -f [guid]::NewGuid().ToString('N'))
    $lines = @('Microsoft Visual Studio Solution File, Format Version 12.00', 'Global', "`tGlobalSection(SolutionConfigurationPlatforms) = preSolution")
    foreach ($r in $SlnRows) { $lines += "`t`t$($r.Name)|$($r.Sol) = $($r.Name)|$($r.Sol)" }
    $lines += "`tEndGlobalSection", 'EndGlobal'
    [IO.File]::WriteAllLines($sln, $lines)
    $script:tempFiles += $sln

    $global:MockState = @{ Active = $Active; Activations = (New-Object System.Collections.ArrayList); Broken = $Broken }
    $cfgs = @()
    for ($i = 0; $i -lt $Rows.Count; $i++) {
        $r = $Rows[$i]
        $ctx = @()
        if (-not $NoTsproj) { $ctx += [PSCustomObject]@{ ProjectName = "$Folder\$Folder.tsproj"; ConfigurationName = $r.Name; PlatformName = $r.Proj; ShouldBuild = [bool]$r.SB } }
        $ctx += [PSCustomObject]@{ ProjectName = "$Folder\plc\plc.plcproj"; ConfigurationName = $r.Name; PlatformName = $r.Proj; ShouldBuild = [bool]$r.SB }
        $c = [PSCustomObject]@{
            Name             = $r.Name
            PlatformName     = $(if ($NoPlatformName) { $null } else { $r.Sol })
            SolutionContexts = $ctx
            MockIndex        = $i
            MockSol          = $r.Sol
        }
        $c | Add-Member -MemberType ScriptMethod -Name Activate -Value {
            $null = $global:MockState.Activations.Add($this.MockIndex)
            if ($global:MockState.Broken -notcontains $this.MockIndex) { $global:MockState.Active = $this.MockIndex }
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
    $solObj = [PSCustomObject]@{ FullName = $sln; SolutionBuild = $sb; Properties = $props }
    if ($Unsaved) { $solObj | Add-Member -NotePropertyName Saved -NotePropertyValue $false }
    $dte = [PSCustomObject]@{ Solution = $solObj }
    & $mod { param($d) $script:TcDte = $d } $dte
}
$script:tempFiles = @()

try {
    # --- (a) Festo: solution Release|OS (x64) -> project ARMT2 (ShouldBuild False) ---
    $festo = @(
        @{ Name = 'Debug'; Sol = $RT; Proj = $RT; SB = $true }
        @{ Name = 'Release'; Sol = $CE7; Proj = $CE7; SB = $true }
        @{ Name = 'Release'; Sol = $ARMT2; Proj = $ARMT2; SB = $true }
        @{ Name = 'Release'; Sol = $OS; Proj = $ARMT2; SB = $false }
        @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true }
    )
    New-MockDte -Rows $festo -Active 4 -Folder 'TwinCAT_Festo'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' -Configuration 'Release' }
    $pmOs = $r.platformMap.$OS
    Check 'festo-code' ($r.error.code -eq 'PLATFORM_PROJECT_MISMATCH') "$($r.error.code): $($r.error.message)"
    Check 'festo-no-activate' ($global:MockState.Activations.Count -eq 0) "activations: $($global:MockState.Activations -join ',')"
    Check 'festo-projectCheck' ($r.projectCheck -eq 'mismatch' -and $r.requestedProjectPlatform -eq $ARMT2 -and $r.projectPlatform -eq $RT) "$($r.projectCheck) / requested $($r.requestedProjectPlatform) / active $($r.projectPlatform)"
    Check 'festo-platformMap' ($null -ne $pmOs -and $pmOs.solutionPlatform -eq $OS -and @($pmOs.projectPlatforms).Count -eq 2 -and
        @($pmOs.projectPlatforms | Where-Object { $_.platform -eq $ARMT2 -and $_.shouldBuild -eq $false }).Count -eq 2 -and
        @($r.platformMap.PSObject.Properties).Count -eq 4) ($r.platformMap | ConvertTo-Json -Depth 5 -Compress)
    Check 'festo-available' ((@($r.availablePlatforms) -join '|') -eq "$CE7|$ARMT2|$OS|$RT") (@($r.availablePlatforms) -join ', ')
    Check 'festo-hint' ($r.error.hint -match 'Configuration Manager' -and $r.error.hint -match [regex]::Escape("'$OS'") -and $r.error.hint -notmatch '<platform>') $r.error.hint

    # Already active Release|OS (x64): the project check still runs.
    New-MockDte -Rows $festo -Active 3 -Folder 'TwinCAT_Festo'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' -Configuration 'Release' }
    Check 'festo-already-active' ($r.error.code -eq 'PLATFORM_PROJECT_MISMATCH' -and $global:MockState.Activations.Count -eq 0) "$($r.error.code)"

    # --- (e) Get-TcSolutionPlatform: real solution platform + project platform ---
    $s = & $mod { Get-TcSolutionPlatform }
    Check 'get-solution-platform' ($s.platform -eq $OS -and $s.configuration -eq 'Release' -and $s.platformSource -eq 'ActiveConfig') ($s | ConvertTo-Json -Compress)
    Check 'get-project-platform' ($s.projectPlatform -eq $ARMT2) "$($s.projectPlatform)"

    # --- (e2) Get-TcBuildCoverage label (#58): solution platform, never the PLC context's project platform ---
    $cov = & $mod { Get-TcBuildCoverage }
    Check 'coverage-label-solution-platform' ($cov.configuration -eq "Release|$OS" -and @($cov.projects | Where-Object { $_.status -eq 'skipped' -and $_.platform -eq $ARMT2 }).Count -eq 1) "$($cov.configuration) / $(($cov.projects | ForEach-Object { "$($_.name):$($_.platform):$($_.status)" }) -join ',')"
    New-MockDte -Rows $festo -Active 3 -Folder 'TwinCAT_Festo' -NoPlatformName
    $cov = & $mod { Get-TcBuildCoverage }
    Check 'coverage-label-vs2022-no-project-platform' ($cov.configuration -eq 'Release') "$($cov.configuration)"

    # --- (b) RobustDemo: every solution platform = project platform, RT -> OS ---
    $robust = @(
        @{ Name = 'Debug'; Sol = $OS; Proj = $OS; SB = $true }
        @{ Name = 'Debug'; Sol = $RT; Proj = $RT; SB = $true }
        @{ Name = 'Release'; Sol = $OS; Proj = $OS; SB = $true }
        @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true }
    )
    New-MockDte -Rows $robust -Active 3
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $ms = $sw.ElapsedMilliseconds
    Check 'robust-success' ($r.success -and $null -eq $r.error) "$($r.error.code) $($r.error.message)"
    Check 'robust-activated' (($global:MockState.Activations -join ',') -eq '2' -and $global:MockState.Active -eq 2) "activations: $($global:MockState.Activations -join ',')"
    Check 'robust-readback' ($r.platform -eq $OS -and $r.projectPlatform -eq $OS -and $r.previousPlatform -eq $RT -and $r.platformChanged -and $r.projectCheck -eq 'ok' -and $r.platformMatchedBy -eq 'solutionPlatform') ($r | Select-Object platform, projectPlatform, previousPlatform, platformChanged, projectCheck, platformMatchedBy | ConvertTo-Json -Compress)
    Check 'robust-no-blind-wait' ($ms -lt 900) "$ms ms"

    # --- (c) VS2022: cfg.PlatformName = $null -> solution platform from the .sln by index ---
    $c = @(
        @{ Name = 'Debug'; Sol = $OS; Proj = $OS; SB = $true }
        @{ Name = 'Release'; Sol = $OS; Proj = $RT; SB = $false }
        @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true }
    )
    New-MockDte -Rows $c -Active 2 -NoPlatformName
    $list = @(& $mod { Get-TcSolutionConfigurations })
    Check 'vs2022-sln-names' ((($list | ForEach-Object { $_.SolutionPlatform }) -join '|') -eq "$OS|$OS|$RT" -and @($list | Where-Object { $_.SolutionPlatformSource -ne 'sln' }).Count -eq 0) (($list | ForEach-Object { "$($_.Name)|$($_.SolutionPlatform) ($($_.SolutionPlatformSource))" }) -join ', ')
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'vs2022-mismatch' ($r.error.code -eq 'PLATFORM_PROJECT_MISMATCH' -and $r.requestedProjectPlatform -eq $RT -and $global:MockState.Activations.Count -eq 0) "$($r.error.code) / $($r.projectPlatform)"
    $s = & $mod { Get-TcSolutionPlatform }
    Check 'vs2022-get' ($s.platform -eq $RT -and $s.projectPlatform -eq $RT) ($s | ConvertTo-Json -Compress)

    # .sln does not match the COM list (line count differs) -> 'unknown', old ctx matching.
    New-MockDte -Rows $robust -Active 3 -NoPlatformName -SlnRows @($robust[0], $robust[1])
    $list = @(& $mod { Get-TcSolutionConfigurations })
    Check 'vs2022-sln-mismatch-unknown' (@($list | Where-Object { $_.SolutionPlatformSource -eq 'unknown' -and $null -eq $_.SolutionPlatform }).Count -eq 4) (($list | ForEach-Object { $_.SolutionPlatformSource }) -join ',')
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'vs2022-unknown-fallback' ($r.success -and $r.platformMatchedBy -eq 'projectPlatform' -and $global:MockState.Active -eq 2) "$($r.error.code) $($r.platformMatchedBy)"

    # Same .sln line count but another configuration name at an index -> 'unknown'.
    $swapped = @($robust[2], $robust[1], $robust[0], $robust[3])
    New-MockDte -Rows $robust -Active 3 -NoPlatformName -SlnRows $swapped
    $list = @(& $mod { Get-TcSolutionConfigurations })
    Check 'vs2022-sln-name-differs-unknown' (@($list | Where-Object { $_.SolutionPlatformSource -eq 'unknown' }).Count -eq 4) (($list | ForEach-Object { $_.SolutionPlatformSource }) -join ',')

    # --- (d) Activate does not take effect -> PLATFORM_SET_FAILED, previous config restored ---
    New-MockDte -Rows $robust -Active 3 -Broken @(2)
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'set-failed-code' ($r.error.code -eq 'PLATFORM_SET_FAILED') "$($r.error.code): $($r.error.message)"
    Check 'set-failed-restored' ($r.restored -eq $true -and $r.projectPlatform -eq $RT -and $r.platform -eq $RT -and ($global:MockState.Activations -join ',') -eq '2,3' -and $global:MockState.Active -eq 3) "restored=$($r.restored) activations: $($global:MockState.Activations -join ',')"

    # --- BUILD_REQUIRED state (#45 / PR #44): the real Set-TcSolutionPlatform writes the file ---
    $stateFile = Join-Path $env:TCAUTO_STATE_DIR 'build-required.json'
    & $mod { $script:TcSolutionPath = 'C:\Demo\Unit.sln' }
    Remove-Item -LiteralPath $stateFile -Force -ErrorAction SilentlyContinue
    # restored switch (d above, again): nothing changed -> no entry
    New-MockDte -Rows $robust -Active 3 -Broken @(2)
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'br-restored-no-entry' ($r.restored -eq $true -and -not (Test-Path -LiteralPath $stateFile)) "restored=$($r.restored) file=$(Test-Path -LiteralPath $stateFile)"
    # switch lands on another configuration (Debug|RT) AND the restore throws -> platformChanged, entry written
    New-MockDte -Rows $robust -Active 3
    $global:MockCfgs[2] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { $null = $global:MockState.Activations.Add($this.MockIndex); $global:MockState.Active = 1 }
    $global:MockCfgs[3] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { $null = $global:MockState.Activations.Add($this.MockIndex); throw 'restore boom (mock)' }
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $req = & $mod { Get-TcBuildRequired }
    Check 'br-restore-failed-entry' (-not $r.success -and $r.restored -eq $false -and $r.platformChanged -and $null -ne $req -and $req.reason -match 'could not be undone' -and $req.solution -eq 'C:\Demo\Unit.sln') "success=$($r.success) restored=$($r.restored) changed=$($r.platformChanged) req=$($req | ConvertTo-Json -Compress)"
    # the entry is a file: a fresh module import (Import-Module -Force) still sees it
    Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
    $mod = Get-Module TwinCATAutomation
    & $mod { $script:TcIdeProcessId = $null; $script:TcSolutionPath = 'C:\DEMO\unit.sln' }
    $req = & $mod { Get-TcBuildRequired }
    Check 'br-survives-reimport' ($null -ne $req -and $req.reason -match 'could not be undone') "req=$($req | ConvertTo-Json -Compress)"
    # other solution: not blocked; no solution known: blocked (conservative)
    & $mod { $script:TcSolutionPath = 'C:\Other\Other.sln' }
    Check 'br-other-solution-free' ($null -eq (& $mod { Get-TcBuildRequired })) 'entry of another solution applied'
    & $mod { $script:TcSolutionPath = $null }
    Check 'br-unknown-solution-blocked' ($null -ne (& $mod { Get-TcBuildRequired })) 'no solution path but nothing blocks'
    # successful switch records too, one entry per solution; Clear-TcBuildRequired removes only its own
    & $mod { $script:TcSolutionPath = 'C:\Other\Other.sln' }
    New-MockDte -Rows $robust -Active 3
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $keys = @((Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json).PSObject.Properties.Name)
    Check 'br-two-entries' ($r.success -and $keys.Count -eq 2 -and $keys -contains 'c:\demo\unit.sln' -and $keys -contains 'c:\other\other.sln') "keys: $($keys -join ', ') success=$($r.success) changed=$($r.platformChanged) warn=$($r.stateWarning) err=$($r.error.message)"
    & $mod { Clear-TcBuildRequired }
    $keys = @((Get-Content -Raw -LiteralPath $stateFile | ConvertFrom-Json).PSObject.Properties.Name)
    Check 'br-clear-own' (($keys -join ',') -eq 'c:\demo\unit.sln') "keys: $($keys -join ', ')"
    # corrupt state file: kept as .corrupt-<time>, replaced by a '<corrupt>' entry that blocks
    # every solution; a complete build (Clear) does not remove it
    Set-Content -LiteralPath $stateFile -Value '{ not json' -Encoding ASCII
    $req = & $mod { Get-TcBuildRequired }
    $kept = @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'build-required.json.corrupt-*')
    Check 'br-corrupt-blocks' ($null -ne $req -and $req.reason -match 'could not be read' -and $kept.Count -eq 1 -and (Get-Content -Raw -LiteralPath $kept[0].FullName).Trim() -eq '{ not json') "req=$($req | ConvertTo-Json -Compress) kept=$($kept.Count)"
    $null = & $mod { Clear-TcBuildRequired }
    $req = & $mod { Get-TcBuildRequired }
    Check 'br-corrupt-survives-clear' ($null -ne $req -and $req.reason -match 'could not be read' -and (Test-Path -LiteralPath $stateFile)) "req=$($req | ConvertTo-Json -Compress)"
    & $mod { $script:TcSolutionPath = 'C:\Other\Andere.sln' }
    Check 'br-corrupt-blocks-all' ($null -ne (& $mod { Get-TcBuildRequired })) 'other solution not blocked by <corrupt>'
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue

    # corrupt file that cannot be replaced (#56 / PR #44 nit): [IO.File]::Replace(tmp, file, kept)
    # fails as one step -> the unreadable file stays untouched, no .corrupt-* / .tmp, Get blocks
    Set-Content -LiteralPath $stateFile -Value '{ still not json' -Encoding ASCII
    $fs = [IO.File]::Open($stateFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $req = & $mod { Get-TcBuildRequired }
        # -Filter 'x.json.*' would also match x.json itself (Win32 wildcard rules)
        $left = @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR | Where-Object { $_.Name -like 'build-required.json.?*' })
        Check 'br-corrupt-replace-fails-closed' ($null -ne $req -and $req.reason -match 'could not be checked' -and $left.Count -eq 0) "req=$($req | ConvertTo-Json -Compress) left=$(($left | ForEach-Object { $_.Name }) -join ',')"
    }
    finally { $fs.Dispose() }
    Check 'br-corrupt-kept-as-is' ((Get-Content -Raw -LiteralPath $stateFile).Trim() -eq '{ still not json') 'unreadable file changed'
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue

    # kinds (#56): a platform switch and an unverified build of the same solution keep both reasons;
    # an entry written before #56 (no kind / reasons) reads as platform-switch; Clear removes all
    & $mod { $script:TcSolutionPath = 'C:\Demo\Kinds.sln' }
    $null = & $mod { Set-TcBuildRequired -Reason 'unit switch' }
    $null = & $mod { Set-TcBuildRequired -Kind 'unverified-build' -Reason 'unit unverified' }
    $req = & $mod { Get-TcBuildRequired }
    $cons = & $mod { param($e) Get-TcBuildRequiredConsequence -Entry $e } $req
    # kind = the first of TcBuildRequiredKinds the entry has (#65), not the newest one
    Check 'br-kinds-both' ($req.reason -eq 'unit switch; and unit unverified' -and $req.kind -eq 'platform-switch' -and $cons -match 'previous platform' -and $cons -match 'did not prove') "req=$($req | ConvertTo-Json -Compress) cons=$cons"
    Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
    $mod = Get-Module TwinCATAutomation
    & $mod { $script:TcIdeProcessId = $null; $script:TcSolutionPath = 'C:\Demo\Kinds.sln' }
    $req = & $mod { Get-TcBuildRequired }
    Check 'br-kinds-file' ($req.reason -eq 'unit switch; and unit unverified') "req=$($req | ConvertTo-Json -Compress)"
    $null = & $mod { Clear-TcBuildRequired }
    Check 'br-kinds-cleared' ($null -eq (& $mod { Get-TcBuildRequired })) 'entry left after Clear'
    $legacy = '{ "c:\\demo\\kinds.sln": { "solution": "C:\\Demo\\Kinds.sln", "reason": "old switch", "at": "2026-10-25 10:00:00" } }'
    [IO.File]::WriteAllText($stateFile, $legacy)
    $null = & $mod { Set-TcBuildRequired -Kind 'unverified-build' -Reason 'new build' }
    $req = & $mod { Get-TcBuildRequired }
    $cons = & $mod { param($e) Get-TcBuildRequiredConsequence -Entry $e } $req
    Check 'br-kinds-legacy' ($req.reason -eq 'old switch; and new build' -and $cons -match 'previous platform') "req=$($req | ConvertTo-Json -Compress)"
    $null = & $mod { Clear-TcBuildRequired; $script:TcSolutionPath = $null }
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue

    # 8.3 short names (#56 review S3): Connect-TcIde keeps the path the user gave; a short and a
    # long spelling of one .sln must hit the same entry, both ways, also for a .sln that does not
    # exist (yet) in an existing folder. Needs 8.3 name generation on the volume (on in CI).
    $longDir = Join-Path $env:TCAUTO_STATE_DIR 'Long Solution Folder Name'
    $null = New-Item -ItemType Directory -Force -Path $longDir
    $longSln = Join-Path $longDir 'Demo Long Name.sln'
    Set-Content -LiteralPath $longSln -Value 'x' -Encoding ASCII
    $fso = New-Object -ComObject Scripting.FileSystemObject
    $shortSln = $fso.GetFile($longSln).ShortPath
    $shortDir = $fso.GetFolder($longDir).ShortPath
    if ($shortSln -eq $longSln -or $shortDir -eq $longDir) {
        Write-Host "SKIP br-83-* (no 8.3 names on this volume: $shortSln)"
    }
    else {
        $pairs = @(
            @{ Name = 'short-then-long'; Write = $shortSln; Read = $longSln },
            @{ Name = 'long-then-short'; Write = $longSln; Read = $shortSln },
            @{ Name = 'missing-file'; Write = (Join-Path $shortDir 'NotYet.sln'); Read = (Join-Path $longDir 'NotYet.sln') }
        )
        foreach ($p in $pairs) {
            & $mod { param($w) $script:TcSolutionPath = $w; $null = Set-TcBuildRequired -Kind 'unverified-build' -Reason 'unit 8.3' } $p.Write
            $req = & $mod { param($r) $script:TcSolutionPath = $r; Get-TcBuildRequired } $p.Read
            Check "br-83-$($p.Name)" ($null -ne $req -and $req.reason -eq 'unit 8.3') "write=$($p.Write) read=$($p.Read) req=$($req | ConvertTo-Json -Compress)"
            $null = & $mod { Clear-TcBuildRequired }
            $req = & $mod { param($w) $script:TcSolutionPath = $w; Get-TcBuildRequired } $p.Write
            Check "br-83-$($p.Name)-cleared" ($null -eq $req) "clear through the other spelling left $($req | ConvertTo-Json -Compress)"
        }
    }
    & $mod { $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $longDir -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path (Join-Path $env:TCAUTO_STATE_DIR 'build-required.json*') -Force -ErrorAction SilentlyContinue

    # non-ASCII solution path: key and file round-trip (UTF-8)
    $uni = 'C:\' + [char]0x6574 + [char]0x7406 + '\Demo.sln'
    & $mod { param($p) $script:TcSolutionPath = $p } $uni
    $w = & $mod { Set-TcBuildRequired -Reason 'unit non-ascii' }
    Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
    $mod = Get-Module TwinCATAutomation
    & $mod { param($p) $script:TcIdeProcessId = $null; $script:TcSolutionPath = $p } $uni
    $req = & $mod { Get-TcBuildRequired }
    Check 'br-non-ascii-key' ($null -eq $w -and $null -ne $req -and $req.reason -eq 'unit non-ascii' -and $req.solution -eq $uni) "w=$w req=$($req | ConvertTo-Json -Compress)"
    $null = & $mod { Clear-TcBuildRequired }
    Check 'br-non-ascii-cleared' (-not (Test-Path -LiteralPath $stateFile) -and $null -eq (& $mod { Get-TcBuildRequired })) "file=$(Test-Path -LiteralPath $stateFile)"

    # lock held by another process: Get blocks (fail-closed), Set keeps the entry in memory + warning
    # mutex name (#56): fixed without TCAUTO_STATE_DIR, else a hash of the full path (a relative
    # spelling of the same directory gives the same name)
    $mutexName = & $mod { Get-TcBuildRequiredMutexName }
    $savedDir = $env:TCAUTO_STATE_DIR
    try {
        Remove-Item Env:\TCAUTO_STATE_DIR
        $fixedName = & $mod { Get-TcBuildRequiredMutexName }
        Push-Location (Split-Path -Parent $savedDir)
        try {
            $env:TCAUTO_STATE_DIR = '.\' + (Split-Path -Leaf $savedDir) + '\'
            [IO.Directory]::SetCurrentDirectory((Get-Location).ProviderPath)
            $relName = & $mod { Get-TcBuildRequiredMutexName }
        }
        finally { Pop-Location; [IO.Directory]::SetCurrentDirectory((Get-Location).ProviderPath) }
    }
    finally { $env:TCAUTO_STATE_DIR = $savedDir }
    Check 'br-mutex-fixed-default' ($fixedName -eq 'Local\TwinCATAutomation.BuildRequired') "$fixedName"
    Check 'br-mutex-normalized' ($relName -eq $mutexName -and $mutexName -match '^Local\\TwinCATAutomation\.BuildRequired\.[0-9a-f]{16}$') "rel=$relName full=$mutexName"

    $ready = Join-Path $env:TCAUTO_STATE_DIR 'holder.ready'
    $holder = Start-Process powershell.exe -WindowStyle Hidden -PassThru -ArgumentList @('-NoProfile', '-Command',
        "`$m = New-Object System.Threading.Mutex(`$false, '$mutexName'); `$null = `$m.WaitOne(); Set-Content -LiteralPath '$ready' -Value 1; Start-Sleep -Seconds 20")
    try {
        $t0 = Get-Date
        while (-not (Test-Path -LiteralPath $ready) -and ((Get-Date) - $t0).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 100 }
        & $mod { $script:TcBuildRequiredLockTimeoutMs = 300; $script:TcSolutionPath = 'C:\Demo\Lock.sln' }
        $req = & $mod { Get-TcBuildRequired }
        Check 'br-lock-get-blocks' ((Test-Path -LiteralPath $ready) -and $null -ne $req -and $req.reason -match 'could not be checked') "req=$($req | ConvertTo-Json -Compress)"
        $w = & $mod { Set-TcBuildRequired -Reason 'unit lock' }
        Check 'br-lock-set-warns' ($w -match 'this process only' -and -not (Test-Path -LiteralPath $stateFile)) "w=$w"
    }
    finally {
        Stop-Process -Id $holder.Id -Force -ErrorAction SilentlyContinue
        $null = $holder.WaitForExit(5000)
    }
    $req = & $mod { Get-TcBuildRequired }
    Check 'br-lock-memory-entry' ($null -ne $req -and $req.reason -eq 'unit lock') "req=$($req | ConvertTo-Json -Compress)"
    $null = & $mod { Clear-TcBuildRequired; $script:TcBuildRequiredLockTimeoutMs = 3000 }
    Remove-Item -LiteralPath $ready -Force -ErrorAction SilentlyContinue
    & $mod { $script:TcSolutionPath = $null }

    # --- PLATFORM_NOT_FOUND lists solution platform names ---
    New-MockDte -Rows $festo -Active 4 -Folder 'TwinCAT_Festo'
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64-E)' -PlatformSource 'target (adsTargetInfo)' }
    Check 'not-found' ($r.error.code -eq 'PLATFORM_NOT_FOUND' -and $r.error.message -match [regex]::Escape("'$OS'") -and $r.error.hint -notmatch '4024') "$($r.error.message)"

    # --- no .tsproj context: allowed, projectCheck 'no-tsproj' ---
    New-MockDte -Rows $robust -Active 3 -NoTsproj
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'no-tsproj' ($r.success -and $r.projectCheck -eq 'no-tsproj') "$($r.error.code) $($r.projectCheck)"

    # --- B1: all solution platforms unknown (VS2022 + .sln one line short), C-type rows ---
    $cOnly = @(@{ Name = 'Release'; Sol = $OS; Proj = $RT; SB = $false })
    $cOnlySln = @(@{ Name = 'Release'; Sol = $OS; Proj = $RT; SB = $false }, @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true })
    New-MockDte -Rows $cOnly -Active 0 -NoPlatformName -SlnRows $cOnlySln
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    $ac = & $mod { $script:TcDte.Solution.Properties.Item('ActiveConfig').Value }
    Check 'b1-no-false-success' (-not $r.success -and $r.error.code -eq 'PLATFORM_SET_FAILED' -and $r.platformMatchedBy -eq 'projectPlatform') "$($r.error.code) success=$($r.success) ActiveConfig=$ac"
    Check 'b1-restored' ($r.restored -eq $true -and $ac -eq "Release|$OS") "restored=$($r.restored) activations: $($global:MockState.Activations -join ',')"

    $cTwo = @(
        @{ Name = 'Release'; Sol = $OS; Proj = $RT; SB = $false }
        @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true }
    )
    New-MockDte -Rows $cTwo -Active 0 -NoPlatformName -SlnRows @($cTwo[0])
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    $ac = & $mod { $script:TcDte.Solution.Properties.Item('ActiveConfig').Value }
    Check 'b1-multi-candidate' ($r.success -and $ac -eq "Release|$RT" -and $r.platform -eq $RT -and ($global:MockState.Activations -join ',') -eq '0,1') "success=$($r.success) ActiveConfig=$ac activations: $($global:MockState.Activations -join ',')"

    # --- S1: .sln anchor. Same names per index but other order -> ActiveConfig row differs -> unknown ---
    $rel = @(
        @{ Name = 'Release'; Sol = $OS; Proj = $OS; SB = $true }
        @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true }
    )
    New-MockDte -Rows $rel -Active 1 -NoPlatformName -SlnRows @($rel[1], $rel[0])
    $list = @(& $mod { Get-TcSolutionConfigurations })
    Check 's1-anchor-unknown' (@($list | Where-Object { $_.SolutionPlatformSource -eq 'unknown' }).Count -eq 2) (($list | ForEach-Object { "$($_.SolutionPlatform) ($($_.SolutionPlatformSource))" }) -join ', ')
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    $ac = & $mod { $script:TcDte.Solution.Properties.Item('ActiveConfig').Value }
    Check 's1-switch-verified' ($r.success -and $ac -eq "Release|$OS") "$($r.error.code) ActiveConfig=$ac"
    New-MockDte -Rows $rel -Active 1 -NoPlatformName -Unsaved
    $list = @(& $mod { Get-TcSolutionConfigurations })
    Check 's1-unsaved-unknown' (@($list | Where-Object { $_.SolutionPlatformSource -eq 'unknown' }).Count -eq 2) (($list | ForEach-Object { $_.SolutionPlatformSource }) -join ',')
    New-MockDte -Rows $rel -Active 1 -NoPlatformName
    $list = @(& $mod { Get-TcSolutionConfigurations })
    Check 's1-anchor-ok' ((($list | ForEach-Object { "$($_.SolutionPlatform)/$($_.SolutionPlatformSource)" }) -join '|') -eq "$OS/sln|$RT/sln") (($list | ForEach-Object { "$($_.SolutionPlatform)/$($_.SolutionPlatformSource)" }) -join '|')

    # --- S2: no .tsproj -> Get-TcSolutionPlatform projectPlatform = $null ---
    New-MockDte -Rows $rel -Active 1 -NoTsproj
    $s = & $mod { Get-TcSolutionPlatform }
    Check 's2-no-tsproj-null' ($null -eq $s.projectPlatform -and $s.platform -eq $RT) ($s | ConvertTo-Json -Compress)

    # --- Activate() throws on a candidate -> readback + restore still run ---
    $three = @(
        @{ Name = 'Release'; Sol = $OS; Proj = $RT; SB = $false }
        @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true }
        @{ Name = 'Release'; Sol = $CE7; Proj = $CE7; SB = $true }
    )
    New-MockDte -Rows $three -Active 2 -NoPlatformName -SlnRows @($three[0])
    $global:MockCfgs[1] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { $null = $global:MockState.Activations.Add($this.MockIndex); throw 'boom (mock)' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    $ms = $sw.ElapsedMilliseconds
    $ac = & $mod { $script:TcDte.Solution.Properties.Item('ActiveConfig').Value }
    Check 'throw-2nd-restored' (-not $r.success -and $r.restored -eq $true -and $ac -eq "Release|$CE7" -and $r.platform -eq $CE7 -and -not $r.platformChanged -and ($global:MockState.Activations -join ',') -eq '0,1,2') "code=$($r.error.code) restored=$($r.restored) platform=$($r.platform) ActiveConfig=$ac activations: $($global:MockState.Activations -join ',')"
    Check 'throw-2nd-message' ($r.error.message -match 'boom \(mock\)' -and $r.error.message -match 'tried:' -and $r.error.message -match 're-activated') "$($r.error.message)"
    Check 'throw-2nd-fast' ($ms -lt 2000) "$ms ms"

    New-MockDte -Rows $three -Active 2 -NoPlatformName -SlnRows @($three[0])
    $global:MockCfgs[0] | Add-Member -Force -MemberType ScriptMethod -Name Activate -Value { $null = $global:MockState.Activations.Add($this.MockIndex); throw 'boom first (mock)' }
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT RT (x64)' }
    $ac = & $mod { $script:TcDte.Solution.Properties.Item('ActiveConfig').Value }
    Check 'throw-1st-readback' (-not $r.success -and $r.restored -eq $true -and $r.platform -eq $CE7 -and $ac -eq "Release|$CE7" -and ($global:MockState.Activations -join ',') -eq '0,2') "code=$($r.error.code) restored=$($r.restored) platform=$($r.platform) activations: $($global:MockState.Activations -join ',')"

    # --- no ActiveConfig, no PlatformName, no .tsproj: the readback must not pass by default ---
    $two = @(
        @{ Name = 'Release'; Sol = $OS; Proj = $OS; SB = $true }
        @{ Name = 'Release'; Sol = $RT; Proj = $RT; SB = $true }
    )
    New-MockDte -Rows $two -Active 1 -NoPlatformName -NoTsproj -Broken @(0)
    & $mod { $script:TcDte.Solution.Properties | Add-Member -Force -MemberType ScriptMethod -Name Item -Value { throw 'no ActiveConfig (mock)' } }
    $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' }
    Check 'unreliable-no-tsproj-not-ok' (-not $r.success -and $r.error.code -eq 'PLATFORM_SET_FAILED' -and $r.projectCheck -eq 'no-tsproj' -and $global:MockState.Active -eq 1) "success=$($r.success) code=$($r.error.code) platform=$($r.platform) active=$($global:MockState.Active)"

    # --- hints: new code registered, PLATFORM_UNKNOWN no longer picks a platform by XAE version ---
    $h = & $mod { Get-TcErrorHint -Code 'PLATFORM_PROJECT_MISMATCH' }
    Check 'hint-registered' (-not [string]::IsNullOrWhiteSpace($h)) "$h"
    $h = & $mod { Get-TcErrorHint -Code 'PLATFORM_UNKNOWN' }
    $h2 = & $mod { Get-TcErrorHint -Code 'PLATFORM_PROJECT_MISMATCH' }
    Check 'hint-mismatch-escape' ($h2 -match 'NoPlatformSwitch') "$h2"
    Check 'hint-unknown-no-xae-rule' ($h -notmatch '4024' -and $h -match 'PLATFORM_PROJECT_MISMATCH') "$h"

    # --- Enable-TcConfig -NoPlatformFix (no IDE): connection, SysManager and TARGETINFO are
    # replaced in the module scope; nothing after this block may rely on the real functions.
    & $mod {
        function script:Assert-TcConnection { }
        function script:Get-TcSysManager { $o = [PSCustomObject]@{}; $o | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '1.2.3.4.1.1' }; $o }
        function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
    }
    # A3b: Festo active Release|RT, target OS (x64) -> its .tsproj is ARMT2 -> PLATFORM_PROJECT_MISMATCH
    New-MockDte -Rows $festo -Active 4 -Folder 'TwinCAT_Festo'
    $r = & $mod { Enable-TcConfig -NoPlatformFix -WarningAction SilentlyContinue }
    Check 'enable-nofix-project-mismatch' (-not $r.success -and $r.error.code -eq 'PLATFORM_PROJECT_MISMATCH' -and $r.data.requestedProjectPlatform -eq $ARMT2 -and $r.data.projectPlatform -eq $RT -and $null -ne $r.data.platformMap.$OS -and -not $r.data.activated -and $global:MockState.Activations.Count -eq 0) "code=$($r.error.code) requested=$($r.data.requestedProjectPlatform) active=$($r.data.projectPlatform) activations=$($global:MockState.Activations -join ',')"
    Check 'enable-nofix-hint' ($r.error.hint -match 'Configuration Manager' -and $r.error.hint -match 'platformMap' -and $r.error.hint -match '1\.2\.3\.4\.1\.1') "$($r.error.hint)"
    # RobustDemo: OS (x64) really builds for OS (x64) -> plain PLATFORM_MISMATCH
    New-MockDte -Rows $robust -Active 3
    $r = & $mod { Enable-TcConfig -NoPlatformFix -WarningAction SilentlyContinue }
    Check 'enable-nofix-mismatch' (-not $r.success -and $r.error.code -eq 'PLATFORM_MISMATCH' -and $global:MockState.Activations.Count -eq 0) "code=$($r.error.code)"

    # --- state file not writable (held open with FileShare.Read, like a reader / virus scanner):
    # the switch reports stateWarning, no .tmp is left, Enable-TcConfig still refuses (in-memory entry)
    $stateFile = Join-Path $env:TCAUTO_STATE_DIR 'build-required.json'
    & $mod { $script:TcSolutionPath = 'C:\Other\Other.sln'; $null = Set-TcBuildRequired -Reason 'unit other' }
    & $mod { $script:TcSolutionPath = 'C:\Demo\Held.sln' }
    $fs = [IO.File]::Open($stateFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        New-MockDte -Rows $robust -Active 3
        $r = & $mod { Set-TcSolutionPlatform -Platform 'TwinCAT OS (x64)' -WarningAction SilentlyContinue }
        $tmpLeft = @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter '*.tmp')
        Check 'br-held-switch-warns' ($r.success -and $r.stateWarning -match 'this process only' -and $tmpLeft.Count -eq 0) "success=$($r.success) stateWarning=$($r.stateWarning) tmp=$($tmpLeft.Count)"
        $onDisk = (Get-Content -Raw -LiteralPath $stateFile) -match 'held\.sln'
        $r = & $mod { Enable-TcConfig -NoPlatformFix -WarningAction SilentlyContinue }
        Check 'br-held-enable-blocked' (-not $onDisk -and -not $r.success -and $r.error.code -eq 'BUILD_REQUIRED' -and -not $r.data.activated) "onDisk=$onDisk code=$($r.error.code) msg=$($r.error.message)"
    }
    finally { $fs.Dispose() }
    $null = & $mod { Clear-TcBuildRequired }

    # --- #56 point 1: Enter-TcPlcOnline refuses every LoginMode while BUILD_REQUIRED applies,
    # before any COM call (Get-TcPlcProjectList would throw on this mock SysManager)
    & $mod { $script:TcSolutionPath = 'C:\Demo\Login.sln'; $null = Set-TcBuildRequired -Kind 'unverified-build' -Reason 'unit login' -WarningAction SilentlyContinue }
    foreach ($mode in @('Regular', 'Download', 'OnlineChange')) {
        $r = & $mod { param($m) Enter-TcPlcOnline -LoginMode $m -WarningAction SilentlyContinue } $mode
        Check "login-build-required-$mode" (-not $r.success -and $r.error.code -eq 'BUILD_REQUIRED' -and $r.error.message -match 'unit login' -and $r.error.message -match 'did not prove' -and $r.data.online -eq $false -and $r.error.hint -match 'Enter-TcPlcOnline') "code=$($r.error.code) msg=$($r.error.message)"
    }
    $null = & $mod { Clear-TcBuildRequired }
    $r = & $mod { Enter-TcPlcOnline -LoginMode Download -WarningAction SilentlyContinue }
    Check 'login-no-entry-passes-gate' ($r.error.code -ne 'BUILD_REQUIRED') "code=$($r.error.code) msg=$($r.error.message)"
    & $mod { $script:TcSolutionPath = $null }
}
finally {
    & $mod { $script:TcDte = $null }
    foreach ($f in $script:tempFiles) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue }
    Remove-Variable -Name MockState, MockCfgs -Scope Global -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
