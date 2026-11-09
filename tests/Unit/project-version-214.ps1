# Unit: Get-TcProjectVersion (#214), no IDE needed. Generated .sln / .tsproj fixtures in %TEMP%;
# ProgID registration and the IDE install facts are mocked inside the module scope (the same seams
# as tests/Unit/connect-ide-launch-72.ps1), so nothing real is read or started.
#   A  4026 / 4024 / several .tsproj / mixed builds: data.projects, major/minor/build/revision
#   B  data.launch is exactly what Resolve-TcLaunchProgId (the helper Connect-TcIde uses) answers
#   C  error codes with hints: SOLUTION_NOT_FOUND, TSPROJ_NOT_FOUND, TCVERSION_UNKNOWN
#   powershell.exe -NoProfile -File tests/Unit/project-version-214.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-214-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null

# $TcVersions: one entry per .tsproj: a version, '' (no TcVersion attribute), '<missing>' (file not on disk) or '<corrupt>' (not XML)
function New-Sln([string]$Name, [string[]]$TcVersions) {
    $dir = Join-Path $root $Name
    New-Item -ItemType Directory -Path $dir | Out-Null
    $lines = @('', 'Microsoft Visual Studio Solution File, Format Version 12.00', 'VisualStudioVersion = 17.14.36930.0')
    $i = 0
    foreach ($v in $TcVersions) {
        $i++
        $sub = Join-Path $dir "P$i"
        New-Item -ItemType Directory -Path $sub | Out-Null
        $file = Join-Path $sub "P$i.tsproj"
        if ($v -eq '<corrupt>') { Set-Content -LiteralPath $file -Value 'this is <not xml' -Encoding UTF8 }
        elseif ($v -ne '<missing>') {
            $attr = if ($v) { " TcVersion=`"$v`"" } else { '' }
            Set-Content -LiteralPath $file -Value "<?xml version=`"1.0`"?>`r`n<TcSmProject TcSmVersion=`"1.0`"$attr>`r`n<Project/>`r`n</TcSmProject>" -Encoding UTF8
        }
        $lines += "Project(`"{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}`") = `"P$i`", `"P$i\P$i.tsproj`", `"{10112974-92E6-3C4B-560E-B30614E0549$i}`""
        $lines += 'EndProject'
    }
    $sln = Join-Path $dir "$Name.sln"
    Set-Content -LiteralPath $sln -Value $lines -Encoding UTF8
    $sln
}

$sln26 = New-Sln 's4026' @('3.1.4026.22')
$sln24 = New-Sln 's4024' @('3.1.4024.71')
$slnTwo = New-Sln 'stwo' @('3.1.4026.22', '3.1.4026.22')
$slnMixed = New-Sln 'smixed' @('3.1.4024.71', '3.1.4026.22')
$slnNoVer = New-Sln 'snover' @('')
$slnHalf = New-Sln 'shalf' @('3.1.4026.22', '')
$slnMissing = New-Sln 'smissing' @('<missing>')
$slnCorrupt = New-Sln 'scorrupt' @('<corrupt>')
$slnBadFmt = New-Sln 'sbadfmt' @('abc')
$slnNoTs = New-Sln 'snots' @()

$global:Reg214 = @(); $global:Ide214 = @{}
& $mod {
    function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $global:Reg214 -contains $ProgId }
    function script:Get-TcProgIdIdeInfo {
        [CmdletBinding()] param([string]$ProgId)
        if ($global:Reg214 -notcontains $ProgId) { return $null }
        $v = $global:Ide214[$ProgId]
        [PSCustomObject]@{ progId = $ProgId; exePath = "C:\fake\$ProgId.exe"; installRoot = "C:\fake\$ProgId"; xaeVersion = $v; xaeBuild = (ConvertTo-TcBuildNumber $v) }
    }
    function script:Get-TcXaeInstallInfo { [CmdletBinding()] param() [PSCustomObject]@{ installedBuild = 4026; remoteManagerBuilds = @('4024.71', '4026.22') } }
}
function Set-Machine([string[]]$Reg, [hashtable]$Ide) { $global:Reg214 = $Reg; $global:Ide214 = $Ide }
$all3 = @('TcXaeShell.DTE.15.0', 'TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')
$dev = @{ 'TcXaeShell.DTE.15.0' = '3.1.4026.22'; 'TcXaeShell.DTE.17.0' = '3.1.4026.22'; 'VisualStudio.DTE.17.0' = '3.1.4026.22' }

# exported, helper private
Check 'exported' ($null -ne (Get-Command -Module TwinCATAutomation -Name Get-TcProjectVersion -ErrorAction SilentlyContinue)) ''
Check 'helper-private' ($null -eq (Get-Command -Module TwinCATAutomation -Name ConvertFrom-TcVersionString -ErrorAction SilentlyContinue)) ''

# A1 4026 project on a 4026 machine
Set-Machine $all3 $dev
$r = Get-TcProjectVersion -SolutionPath $sln26
$p = @($r.data.projects)
Check 'A1 success' ($r.success -eq $true) ($r | ConvertTo-Json -Depth 6 -Compress)
Check 'A1 solutionPath' ($r.data.solutionPath -eq (& $mod { param($x) Get-TcLongPath $x } $sln26)) "$($r.data.solutionPath)"
Check 'A1 one project, raw string + parts' ($p.Count -eq 1 -and $p[0].tcVersion -eq '3.1.4026.22' -and $p[0].major -eq 3 -and $p[0].minor -eq 1 -and $p[0].build -eq 4026 -and $p[0].revision -eq 22 -and $p[0].path -like '*P1.tsproj') ($p | ConvertTo-Json -Compress)
Check 'A1 builds / vs' (@($r.data.builds).Count -eq 1 -and $r.data.builds[0] -eq 4026 -and $r.data.visualStudioVersion -eq '17.14.36930.0') "$($r.data.builds) $($r.data.visualStudioVersion)"
Check 'A1 wanted = 17.0 hosts' ((@($r.data.launch.wantedProgIds) -join ',') -eq 'TcXaeShell.DTE.17.0,VisualStudio.DTE.17.0') "$($r.data.launch.wantedProgIds)"
Check 'A1 matching = both 17.0 hosts' ((@($r.data.launch.matchingProgIds) -join ',') -eq 'TcXaeShell.DTE.17.0,VisualStudio.DTE.17.0') "$($r.data.launch.matchingProgIds)"
Check 'A1 progId / selectedBy' ($r.data.launch.progId -eq 'TcXaeShell.DTE.17.0' -and $r.data.launch.selectedBy -eq 'tsproj-version' -and $null -eq $r.data.launch.errorCode) "$($r.data.launch.progId) $($r.data.launch.selectedBy)"
Check 'A1 ide[] lists the registered IDEs' (@($r.data.launch.ide).Count -eq 3 -and @($r.data.launch.registeredProgIds).Count -eq 3) ''

# A2 4024 project, machine with the 4024 XAE Shell
Set-Machine @('TcXaeShell.DTE.15.0') @{ 'TcXaeShell.DTE.15.0' = '3.1.4024.71' }
$r = Get-TcProjectVersion -SolutionPath $sln24
Check 'A2 4024' ($r.success -and $r.data.projects[0].build -eq 4024 -and $r.data.projects[0].revision -eq 71 -and (@($r.data.launch.wantedProgIds) -join ',') -eq 'TcXaeShell.DTE.15.0' -and (@($r.data.launch.matchingProgIds) -join ',') -eq 'TcXaeShell.DTE.15.0' -and $r.data.launch.progId -eq 'TcXaeShell.DTE.15.0') ($r | ConvertTo-Json -Depth 6 -Compress)

# A3 4024 project on the dev machine (XAE 4026 everywhere): ConnectIde would answer PROGID_REQUIRED; no match, still success
Set-Machine $all3 $dev
$r = Get-TcProjectVersion -SolutionPath $sln24
Check 'A3 4024 on 4026 machine: no match, PROGID_REQUIRED as data' ($r.success -and @($r.data.launch.matchingProgIds).Count -eq 0 -and $null -eq $r.data.launch.progId -and $r.data.launch.errorCode -eq 'PROGID_REQUIRED' -and -not [string]::IsNullOrWhiteSpace($r.data.launch.hint) -and (@($r.data.launch.wantedProgIds) -join ',') -eq 'TcXaeShell.DTE.15.0') ($r.data.launch | ConvertTo-Json -Depth 4 -Compress)

# A4 4026 project, only the 32-bit TcXaeShell registered
Set-Machine @('TcXaeShell.DTE.15.0') @{ 'TcXaeShell.DTE.15.0' = '3.1.4024.71' }
$r = Get-TcProjectVersion -SolutionPath $sln26
Check 'A4 IDE_VERSION_NOT_REGISTERED as data' ($r.success -and $r.data.launch.errorCode -eq 'IDE_VERSION_NOT_REGISTERED' -and @($r.data.launch.matchingProgIds).Count -eq 0) "$($r.data.launch.errorCode)"

# A5 nothing registered
Set-Machine @() @{}
$r = Get-TcProjectVersion -SolutionPath $sln26
Check 'A5 TWINCAT_NOT_FOUND as data' ($r.success -and $r.data.launch.errorCode -eq 'TWINCAT_NOT_FOUND' -and $null -eq $r.data.launch.progId) "$($r.data.launch.errorCode)"

# A6 / A7 several .tsproj
Set-Machine $all3 $dev
$r = Get-TcProjectVersion -SolutionPath $slnTwo
Check 'A6 two .tsproj, same version' ($r.success -and @($r.data.projects).Count -eq 2 -and @($r.data.builds).Count -eq 1 -and $r.data.launch.progId -eq 'TcXaeShell.DTE.17.0') ($r | ConvertTo-Json -Depth 5 -Compress)
$r = Get-TcProjectVersion -SolutionPath $slnMixed
Check 'A7 two .tsproj, different builds: both listed, ConnectIde would need -ProgId' ($r.success -and @($r.data.projects).Count -eq 2 -and @($r.data.builds).Count -eq 2 -and $r.data.launch.errorCode -eq 'PROGID_REQUIRED' -and $null -eq $r.data.launch.progId) "$($r.data.builds) $($r.data.launch.errorCode)"

# B  the launch block is Resolve-TcLaunchProgId's own answer
$parity = $true; $detail = ''
foreach ($case in @(@($sln26, $dev, $all3), @($sln24, $dev, $all3), @($slnMixed, $dev, $all3), @($sln26, @{ 'TcXaeShell.DTE.15.0' = '3.1.4024.71' }, @('TcXaeShell.DTE.15.0')), @($slnTwo, @{}, @()))) {
    Set-Machine $case[2] $case[1]
    $r = Get-TcProjectVersion -SolutionPath $case[0]
    $res = & $mod { param($s) Resolve-TcLaunchProgId -SolutionPath (Get-TcLongPath $s) } $case[0]
    if ($r.data.launch.progId -ne $res.progId -or $r.data.launch.errorCode -ne $res.errorCode -or $r.data.launch.selectedBy -ne $res.selectedBy -or (@($r.data.launch.matchingProgIds) -join ',') -ne (@($res.matchingProgIds) -join ',')) { $parity = $false; $detail += " $($case[0])" }
}
Check 'B launch == Resolve-TcLaunchProgId for 5 machine / solution combinations' $parity $detail
Check 'B Connect-TcIde and Get-TcProjectVersion call the same helper' ((Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Connect-TcIde.ps1')) -match 'Resolve-TcLaunchProgId' -and (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Get-TcProjectVersion.ps1')) -match 'Resolve-TcLaunchProgId -SolutionPath') ''

# C  errors with hints
$r = Get-TcProjectVersion -SolutionPath (Join-Path $root 'nope.sln')
Check 'C1 SOLUTION_NOT_FOUND + hint' ($r.success -eq $false -and $r.error.code -eq 'SOLUTION_NOT_FOUND' -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) ($r | ConvertTo-Json -Compress)
$r = Get-TcProjectVersion -SolutionPath $root
Check 'C2 a folder is not a solution: SOLUTION_NOT_FOUND' ($r.success -eq $false -and $r.error.code -eq 'SOLUTION_NOT_FOUND') "$($r.error.code)"
$r = Get-TcProjectVersion -SolutionPath $slnNoTs
Check 'C3 TSPROJ_NOT_FOUND + hint' ($r.success -eq $false -and $r.error.code -eq 'TSPROJ_NOT_FOUND' -and -not [string]::IsNullOrWhiteSpace($r.error.hint) -and $null -ne $r.data) ($r | ConvertTo-Json -Compress)
foreach ($c in @(@('snover', $slnNoVer, 'no TcVersion attribute'), @('shalf', $slnHalf, 'no TcVersion attribute'), @('smissing', $slnMissing, 'file not found'), @('scorrupt', $slnCorrupt, 'unreadable'), @('sbadfmt', $slnBadFmt, 'is not 3.1'))) {
    $r = Get-TcProjectVersion -SolutionPath $c[1]
    Check "C4 $($c[0]): TCVERSION_UNKNOWN + hint + the reason" ($r.success -eq $false -and $r.error.code -eq 'TCVERSION_UNKNOWN' -and -not [string]::IsNullOrWhiteSpace($r.error.hint) -and $r.error.message -like "*$($c[2])*" -and @($r.data.projects).Count -ge 1) "$($r.error.message)"
}
$r = Get-TcProjectVersion -SolutionPath $slnHalf
Check 'C5 half known: the readable one keeps its parts, the other is null' ($r.data.projects[0].build -eq 4026 -and $null -eq $r.data.projects[1].build -and $null -eq $r.data.projects[1].tcVersion) ''

# D relative path
Push-Location (Split-Path -Parent $sln26)
try { $r = Get-TcProjectVersion -SolutionPath '.\s4026.sln' } finally { Pop-Location }
Check 'D relative path resolved' ($r.success -and $r.data.projects[0].build -eq 4026) ($r | ConvertTo-Json -Depth 3 -Compress)

# E read-only: the fixture folder is unchanged
Check 'E nothing written next to the solution' (((@(Get-ChildItem -LiteralPath (Split-Path -Parent $sln26) -Recurse -File | ForEach-Object { $_.Name }) | Sort-Object) -join ',') -eq 'P1.tsproj,s4026.sln') ''

Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
Remove-Variable -Name Reg214, Ide214 -Scope Global -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
