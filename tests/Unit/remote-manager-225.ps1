# Unit (#225 PR #255 review): Remote Manager facts used by Resolve-TcLaunchProgId / Connect-TcIde, no IDE needed.
#   A  Get-TcRemoteManagerBuildList on real temp folders: only Build_<build>.<revision> folders
#      with at least one .dll count; reasons dir-not-found / no-build-folders / read-failed
#   B  Get-TcXaeInstallInfo with a mocked registry seam (Get-TcTwinCatRegistryViews): view
#      priority (WOW6432Node first, then native), TwinCATDir without Build_*, read failures
#   C  Test-TcRemoteManagerMatch: TcRemoteManager.Version read back == expected / mismatch / unreadable
#   D  Resolve-TcLaunchProgId: expectedVersion, major.minor must be 3.1, reason texts
#   powershell.exe -NoProfile -File tests/Unit/remote-manager-225.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-225-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
# <tc>\3.1\Components\Base\<folders>; $Folders: name -> $true (has a .dll) / $false (empty)
function New-TcDir([string]$Name, [hashtable]$Folders) {
    $tc = Join-Path $root $Name
    $base = Join-Path $tc '3.1\Components\Base'
    New-Item -ItemType Directory -Path $base -Force | Out-Null
    foreach ($f in $Folders.Keys) {
        $d = Join-Path $base $f
        New-Item -ItemType Directory -Path $d -Force | Out-Null
        if ($Folders[$f]) { Set-Content -LiteralPath (Join-Path $d 'TcFake.dll') -Value 'x' } else { New-Item -ItemType Directory -Path (Join-Path $d '1033') -Force | Out-Null }
    }
    $tc
}

try {
    # --- A: folder listing ---
    $list = { param($b) & $mod { param($x) Get-TcRemoteManagerBuildList -BaseDir $x } $b }
    $tcA = New-TcDir 'a' @{ 'Build_4024.71' = $true; 'Build_4024.59' = $false; 'Build_4024.71_old' = $true; 'Build_x' = $true; 'Other' = $true; 'Build_4026.22' = $true }
    $r = & $list (Join-Path $tcA '3.1\Components\Base')
    Check 'A1 only Build_<build>.<revision> with a .dll' ((@($r.builds) -join ',') -eq '4024.71,4026.22' -and $null -eq $r.reason) ($r | ConvertTo-Json -Compress -Depth 4)
    $ign = @($r.ignored | ForEach-Object { "$($_.name)=$($_.why)" }) -join ','
    Check 'A2 empty Build_4024.59 and odd names are listed as ignored with the reason' ($ign -match 'Build_4024\.59=no-dll' -and $ign -match 'Build_4024\.71_old=name' -and $ign -match 'Build_x=name' -and $ign -notmatch 'Other') $ign
    $r = & $list (Join-Path $root 'missing\3.1\Components\Base')
    Check 'A3 base folder missing -> dir-not-found' (@($r.builds).Count -eq 0 -and $r.reason -eq 'dir-not-found') "$($r.reason)"
    $tcB = New-TcDir 'b' @{ 'Build_4024.71' = $false }
    $r = & $list (Join-Path $tcB '3.1\Components\Base')
    Check 'A4 only an empty Build folder -> no-build-folders' (@($r.builds).Count -eq 0 -and $r.reason -eq 'no-build-folders') "$($r.reason)"
    $tcC = New-TcDir 'c' @{}
    $r = & $list (Join-Path $tcC '3.1\Components\Base')
    Check 'A5 no Build_* at all -> no-build-folders' (@($r.builds).Count -eq 0 -and $r.reason -eq 'no-build-folders') "$($r.reason)"
    # --- B: Get-TcXaeInstallInfo, registry seam mocked ---
    $real = @(& $mod { Get-TcTwinCatRegistryViews })
    Check 'B0 real registry seam returns the two views in priority order (WOW6432Node, native)' ((@($real | ForEach-Object { $_.view }) -join ',') -eq 'WOW6432Node,native') ($real | ConvertTo-Json -Compress)
    $global:Views225 = @()
    & $mod { function script:Get-TcTwinCatRegistryViews { [CmdletBinding()] param() $global:Views225 } }
    $inst = { & $mod { Get-TcXaeInstallInfo } }
    $tcW = New-TcDir 'w' @{ 'Build_4024.71' = $true }
    $tcN = New-TcDir 'n' @{ 'Build_4024.59' = $true }
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $tcW; build = 4026; error = $null }, [PSCustomObject]@{ view = 'native'; twinCatDir = $tcN; build = 4024; error = $null })
    $r = & $inst
    Check 'B1 both views usable -> WOW6432Node wins (builds and installedBuild)' ((@($r.remoteManagerBuilds) -join ',') -eq '4024.71' -and $r.remoteManagerRoot -eq (Join-Path $tcW '3.1\Components\Base') -and $r.installedBuild -eq 4026 -and $null -eq $r.remoteManagerReason) ($r | ConvertTo-Json -Compress -Depth 5)
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $tcC; build = $null; error = $null }, [PSCustomObject]@{ view = 'native'; twinCatDir = $tcN; build = 4024; error = $null })
    $r = & $inst
    Check 'B2 WOW6432Node TwinCATDir without Build_* -> native view used; installedBuild from native' ((@($r.remoteManagerBuilds) -join ',') -eq '4024.59' -and $r.remoteManagerRoot -eq (Join-Path $tcN '3.1\Components\Base') -and $r.installedBuild -eq 4024 -and @($r.remoteManagerSearched).Count -eq 2) ($r | ConvertTo-Json -Compress -Depth 5)
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $tcC; build = 4026; error = $null })
    $r = & $inst
    Check 'B3 TwinCATDir set but no Build_* -> root null, reason no-build-folders' (@($r.remoteManagerBuilds).Count -eq 0 -and $null -eq $r.remoteManagerRoot -and $r.remoteManagerReason -eq 'no-build-folders') ($r | ConvertTo-Json -Compress -Depth 5)
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $tcB; build = 4026; error = $null })
    $r = & $inst
    Check 'B4 only an empty Build_4024.71 -> not a Remote Manager build' (@($r.remoteManagerBuilds).Count -eq 0 -and $null -eq $r.remoteManagerRoot -and $r.remoteManagerReason -eq 'no-build-folders') ($r | ConvertTo-Json -Compress -Depth 5)
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = (Join-Path $root 'nope'); build = 4026; error = $null })
    $r = & $inst
    Check 'B5 TwinCATDir folder missing -> dir-not-found' (@($r.remoteManagerBuilds).Count -eq 0 -and $r.remoteManagerReason -eq 'dir-not-found') "$($r.remoteManagerReason)"
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $null; build = $null; error = 'Requested registry access is not allowed.' }, [PSCustomObject]@{ view = 'native'; twinCatDir = $null; build = $null; error = $null })
    $r = & $inst
    Check 'B6 registry read failed, no TwinCATDir anywhere -> read-failed' (@($r.remoteManagerBuilds).Count -eq 0 -and $null -eq $r.remoteManagerRoot -and $r.remoteManagerReason -eq 'read-failed' -and $null -eq $r.installedBuild) ($r | ConvertTo-Json -Compress -Depth 5)
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $null; build = $null; error = $null })
    $r = & $inst
    Check 'B7 no TwinCATDir value at all -> dir-not-found' ($r.remoteManagerReason -eq 'dir-not-found') "$($r.remoteManagerReason)"

    # --- C: read back of TcRemoteManager.Version ---
    function New-RmDte([string]$Mode, [string]$Version = '3.1.4024.71') {
        $o = New-Object PSObject
        $o | Add-Member NoteProperty Mode $Mode
        $o | Add-Member NoteProperty RmVersion $Version
        $o | Add-Member ScriptMethod GetObject { param($n) if ($this.Mode -eq 'throw') { throw 'Unknown name (0x80020006)' }; [PSCustomObject]@{ Version = $this.RmVersion } }
        $o
    }
    $rmi = [PSCustomObject]@{ build = '4024.71'; expectedVersion = '3.1.4024.71'; path = 'C:\x\Build_4024.71'; xaeVersion = '3.1.4026.22'; progId = 'TcXaeShell.DTE.15.0' }
    $t = { param($d, $i) & $mod { param($a, $b) Test-TcRemoteManagerMatch -Dte $a -RemoteManager $b } $d $i }
    $r = & $t (New-RmDte 'ok') $rmi
    Check 'C1 read back equals expected -> verified' ($r.verified -eq $true -and $r.mismatch -eq $false -and $r.actual -eq '3.1.4024.71' -and $r.expected -eq '3.1.4024.71') ($r | ConvertTo-Json -Compress)
    $r = & $t (New-RmDte 'ok' '3.1.4026.22') $rmi
    Check 'C2 other version -> mismatch, not verified' ($r.verified -eq $false -and $r.mismatch -eq $true -and $r.actual -eq '3.1.4026.22') ($r | ConvertTo-Json -Compress)
    $r = & $t (New-RmDte 'throw') $rmi
    Check 'C3 unreadable -> not verified, no mismatch, error kept' ($r.verified -eq $false -and $r.mismatch -eq $false -and $null -eq $r.actual -and $r.error -match '0x80020006') ($r | ConvertTo-Json -Compress)
    $r = & $t (New-RmDte 'ok' '') $rmi
    Check 'C4 empty Version -> unreadable (not a mismatch)' ($r.verified -eq $false -and $r.mismatch -eq $false -and $null -eq $r.actual) ($r | ConvertTo-Json -Compress)

    # --- D: resolver details ---
    & $mod {
        function script:Test-TcProgIdRegistered { [CmdletBinding()] param([string]$ProgId) $true }
        function script:Get-TcProgIdIdeInfo { [CmdletBinding()] param([string]$ProgId) [PSCustomObject]@{ progId = $ProgId; exePath = "C:\fake\$ProgId.exe"; installRoot = "C:\fake\$ProgId"; xaeVersion = '3.1.4026.22'; xaeBuild = 4026 } }
    }
    function New-Sln225([string]$Name, [string]$TcVersion) {
        $dir = Join-Path $root $Name; New-Item -ItemType Directory -Path (Join-Path $dir 'P1') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $dir 'P1\P1.tsproj') -Value "<?xml version=`"1.0`"?>`r`n<TcSmProject TcVersion=`"$TcVersion`"><Project/></TcSmProject>" -Encoding UTF8
        $sln = Join-Path $dir "$Name.sln"
        Set-Content -LiteralPath $sln -Value @('Microsoft Visual Studio Solution File, Format Version 12.00', 'Project("{B1E792BE-AA5F-4E3C-8C82-674BF9C0715B}") = "P1", "P1\P1.tsproj", "{10112974-92E6-3C4B-560E-B30614E05491}"', 'EndProject') -Encoding UTF8
        $sln
    }
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $tcA; build = 4026; error = $null })
    $res = { param($s) & $mod { param($x) Resolve-TcLaunchProgId -SolutionPath $x } $s }
    $r = & $res (New-Sln225 'd1' '3.1.4024.71')
    Check 'D1 match carries expectedVersion 3.1.4024.71 and the folder' ($r.selectedBy -eq 'remote-manager-match' -and $r.remoteManager.expectedVersion -eq '3.1.4024.71' -and $r.remoteManager.path -eq (Join-Path $tcA '3.1\Components\Base\Build_4024.71')) ($r.remoteManager | ConvertTo-Json -Compress)
    $r = & $res (New-Sln225 'd2' '3.2.4024.71')
    Check 'D2 TcVersion 3.2.x is never matched through the Remote Manager -> PROGID_REQUIRED' ($null -eq $r.progId -and $r.errorCode -eq 'PROGID_REQUIRED') "$($r.selectedBy)/$($r.errorCode)"
    $r = & $res (New-Sln225 'd3' '3.1.4024.59')
    Check 'D3 4024.59 project, Build_4024.59 empty (no .dll) -> PROGID_REQUIRED naming the folder' ($null -eq $r.progId -and $r.errorCode -eq 'PROGID_REQUIRED' -and $r.errorMessage -match 'Build_4024\.59') $r.errorMessage
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = (Join-Path $root 'nope'); build = 4026; error = $null })
    $r = & $res (New-Sln225 'd4' '3.1.4024.71')
    Check 'D4 TwinCAT folder missing -> PROGID_REQUIRED says the folder does not exist' ($r.errorCode -eq 'PROGID_REQUIRED' -and $r.errorMessage -match 'does not exist') $r.errorMessage
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $tcC; build = 4026; error = $null })
    $r = & $res (New-Sln225 'd5' '3.1.4024.71')
    Check 'D5 no Build_* folder -> PROGID_REQUIRED says no Build_* folder' ($r.errorCode -eq 'PROGID_REQUIRED' -and $r.errorMessage -match 'no Build_\*') $r.errorMessage
    $global:Views225 = @([PSCustomObject]@{ view = 'WOW6432Node'; twinCatDir = $null; build = $null; error = 'denied' })
    $r = & $res (New-Sln225 'd6' '3.1.4024.71')
    Check 'D6 registry / folder read failed -> PROGID_REQUIRED says could not be read' ($r.errorCode -eq 'PROGID_REQUIRED' -and $r.errorMessage -match 'could not be read') $r.errorMessage
    # A6 last: it replaces Get-ChildItem inside the module for the rest of this script
    $r = & $mod {
        param($x)
        function script:Get-ChildItem { param([string]$LiteralPath, [switch]$Directory, [switch]$File, [string]$Filter, $ErrorAction) throw 'Access to the path is denied.' }
        Get-TcRemoteManagerBuildList -BaseDir $x
    } (Join-Path $tcA '3.1\Components\Base')
    Check 'A6 listing throws -> read-failed with the error' (@($r.builds).Count -eq 0 -and $r.reason -eq 'read-failed' -and $r.error -match 'denied') "$($r.reason) $($r.error)"

}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit $fail
