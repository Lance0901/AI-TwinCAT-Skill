# Unit: task 3.1 (complete-automation-interface phase 2): Library Manager cmdlets Get-TcLibraries,
# Add-TcLibraryPlaceholder, Remove-TcLibraryReference, Install-TcLibrary, Uninstall-TcLibrary,
# Lock-TcLibraryPlaceholder.
# No IDE / runtime: a mock References node (ITcPlcLibraryManager) whose methods behave as XAE did in the
# probe (verification/phase2-probe.md 3.1), an in-memory .plcproj that the mocked project save writes to
# a temp file, and a temp solution directory for the .tcauto-backup folder.
#   powershell.exe -NoProfile -File tests/Unit/library-manager.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Depth 6 -Compress }

$B = 'Beckhoff Automation GmbH'
$RefsPath = 'TIPC^plc^plc Project^References'
$Root = Join-Path $env:TEMP ("tcauto-unit-lib-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'plc') -Force
$Sln = Join-Path $Root 'Lib.sln'
$global:L = @{ PlcProj = (Join-Path $Root 'plc\plc.plcproj') }
$RepoRoot = Join-Path $Root 'Managed Libraries'

function New-LibInfo($lib, $ver, $dist) {
    if (-not $lib) { return $null }
    [PSCustomObject]@{ LibraryName = $lib; Version = $ver; Distributor = $dist; DisplayName = "$lib, $ver ($dist)" }
}
# a placeholder as XAE lists it: Name '#<ph>', LibraryName etc. empty strings (measured)
function New-PhRef($ph, $eff, $def) {
    [PSCustomObject]@{ Name = "#$ph"; PlaceholderName = $ph; LibraryName = ''; Version = ''; Distributor = ''; DisplayName = ''; EffectiveResolution = $eff; DefaultResolution = $def }
}
function New-LibRef($lib, $ver, $dist) { [PSCustomObject]@{ Name = $lib; LibraryName = $lib; Version = $ver; Distributor = $dist; DisplayName = "$lib, $ver ($dist)" } }
function Add-MemPh($ph, $default, $resolution) { $global:L.Mem.Ph[$ph] = @{ Default = $default; Resolution = $resolution } }
# the in-memory .plcproj -> disk (what Project.Save does); MSBuild namespace as in a real .plcproj
function Write-MockPlcProj {
    $x = [System.Text.StringBuilder]::new()
    [void]$x.Append('<?xml version="1.0" encoding="utf-8"?><Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003"><ItemGroup>')
    foreach ($k in $global:L.Mem.Ph.Keys) { [void]$x.Append("<PlaceholderReference Include=""$k""><DefaultResolution>$($global:L.Mem.Ph[$k].Default)</DefaultResolution><Namespace>$k</Namespace></PlaceholderReference>") }
    foreach ($l in $global:L.Mem.Libs) { [void]$x.Append("<LibraryReference Include=""$l""><Namespace>$($l.Split(',')[0])</Namespace></LibraryReference>") }
    [void]$x.Append('</ItemGroup><ItemGroup>')
    foreach ($k in $global:L.Mem.Ph.Keys) { if ($global:L.Mem.Ph[$k].Resolution) { [void]$x.Append("<PlaceholderResolution Include=""$k""><Resolution>$($global:L.Mem.Ph[$k].Resolution)</Resolution></PlaceholderResolution>") } }
    [void]$x.Append('</ItemGroup></Project>')
    [System.IO.File]::WriteAllText($global:L.PlcProj, $x.ToString())
}
function Write-Calls { $global:L.Calls.Add(($args | ForEach-Object { if ($null -eq $_) { '<null>' } else { [string]$_ } }) -join '|') | Out-Null }

function Reset-Mock {
    $global:L.Mode = 'ok'; $global:L.Dialog = $null; $global:L.Saves = 0; $global:L.Scans = 0; $global:L.SaveFailAt = 0; $global:L.RepoThrow = $false
    $global:L.Calls = [System.Collections.ArrayList]::new()
    $global:L.Mem = @{ Ph = [ordered]@{}; Libs = [System.Collections.ArrayList]::new() }
    $global:L.Refs = [System.Collections.ArrayList]::new()
    $null = $global:L.Refs.Add((New-PhRef 'Tc2_Standard' (New-LibInfo 'Tc2_Standard' '3.3.3.0' $B) (New-LibInfo 'Tc2_Standard' '*' $B)))
    $null = $global:L.Refs.Add((New-PhRef 'Tc2_Frozen' (New-LibInfo 'Tc2_Math' '3.5.1.0' $B) (New-LibInfo 'Tc2_Math' '*' $B)))
    $null = $global:L.Refs.Add((New-PhRef 'VisuPH' $null (New-LibInfo 'VisuElems' '*' 'System')))
    $null = $global:L.Refs.Add((New-LibRef 'Tc2_Lib' '1.0.0.0' $B))
    Add-MemPh 'Tc2_Standard' "Tc2_Standard, * ($B)" "Tc2_Standard, * ($B)"
    Add-MemPh 'Tc2_Frozen' "Tc2_Math, * ($B)" "Tc2_Math, 3.5.1.0 ($B)"
    Add-MemPh 'VisuPH' 'VisuElems, * (System)' $null
    $null = $global:L.Mem.Libs.Add("Tc2_Lib,1.0.0.0,$B")
    $global:L.Scan = [System.Collections.ArrayList]::new()
    foreach ($e in @(@('Tc2_Standard', '3.3.3.0', $B), @('Tc2_Math', '3.5.1.0', $B), @('Tc2_Math', '3.4.0.0', $B), @('MyLib', '1.2.3.4', 'My Co'))) {
        # ScanLibraries entries: Name = LibraryName (measured)
        $null = $global:L.Scan.Add([PSCustomObject]@{ Name = $e[0]; LibraryName = $e[0]; Version = $e[1]; Distributor = $e[2]; DisplayName = "$($e[0]), $($e[1]) ($($e[2]))" })
        # repository layout <root>\<Distributor>\<Library>\<Version> (measured), with a nested file
        $vd = Join-Path (Join-Path (Join-Path $RepoRoot $e[2]) $e[0]) $e[1]
        $null = New-Item -ItemType Directory -Path (Join-Path $vd 'sub') -Force
        [System.IO.File]::WriteAllText((Join-Path $vd "$($e[0]).library"), "lib $($e[0]) $($e[1])")
        [System.IO.File]::WriteAllText((Join-Path $vd 'sub\info.txt'), 'x')
    }
    $global:L.RepoFolder = $null
    $global:L.InstallAdds = @('NewLib', '2.0.0.0', 'My Co')
    Write-MockPlcProj
    if (Test-Path -LiteralPath (Join-Path $Root '.tcauto-backup')) { Remove-Item -LiteralPath (Join-Path $Root '.tcauto-backup') -Recurse -Force }
    & $mod { param($s) $script:TcSolutionPath = $s } $Sln
}

$refs = New-Object PSObject
$refs | Add-Member ScriptProperty References { , $global:L.Refs.ToArray() }
$refs | Add-Member ScriptMethod ScanLibraries { $global:L.Scans++; , $global:L.Scan.ToArray() }
$refs | Add-Member ScriptMethod AddPlaceholder {
    Write-Calls 'AddPlaceholder' @args "n=$($args.Count)"
    $ph = [string]$args[0]
    switch ($global:L.Mode) {
        # XAE already has it (e.g. added between the References read and the call): listed, then the error
        'contained' { $null = $global:L.Refs.Add((New-PhRef $ph (New-LibInfo $args[1] '3.5.1.0' $B) $null)); Add-MemPh $ph "$($args[1]), * ($B)" $null; throw [System.ArgumentException]::new("Placeholder '$ph' already contained!") }
        'nodefault' { throw [System.Runtime.InteropServices.COMException]::new("Default Library '$($args[1]), * (Nobody)' not found! (ITcPlcLibraryManager:AddLibrary", [int]0x98510001) }
        'nodevice' { throw [System.ArgumentException]::new("Default Placeholder '$ph' could not be found! (ITcPlcLibraryManager:AddPlaceholder") }
        'loggedin' { throw [System.Runtime.InteropServices.COMException]::new('Cannot add an object because it affects a device you are currently logged into.', -2147467259) }
        'noappear' { return }
    }
    $lib = if ($global:L.Mode -eq 'wronglib') { 'Other_Lib' } else { [string]$args[1] }
    $null = $global:L.Refs.Add((New-PhRef $ph (New-LibInfo $lib '3.5.1.0' $args[3]) (New-LibInfo $lib $args[2] $args[3])))
    if ($global:L.Mode -ne 'memmiss') { Add-MemPh $ph "$lib, $($args[2]) ($($args[3]))" "$lib, $($args[2]) ($($args[3]))" }
}
$refs | Add-Member ScriptMethod RemoveReference {
    Write-Calls 'RemoveReference' @args
    $n = [string]$args[0]
    if ($global:L.Mode -eq 'xaenotfound') { throw [System.Runtime.InteropServices.COMException]::new("Specified library '$n' not found! (ITcPlcLibraryManager:RemoveReference", [int]0x98510001) }
    if ($global:L.Mode -eq 'loggedin') { throw [System.Runtime.InteropServices.COMException]::new('Cannot add an object because it affects a device you are currently logged into.', -2147467259) }
    if ($global:L.Mode -eq 'noremove') { return }
    $bare = $n.TrimStart('#')
    $hasLib = @($global:L.Refs | Where-Object { $_.Name -eq $bare }).Count -gt 0
    $ph = $n.StartsWith('#') -or -not $hasLib
    $drop = if ($ph) { "#$bare" } else { $bare }
    $keep = @($global:L.Refs | Where-Object { $_.Name -ne $drop })
    $global:L.Refs = [System.Collections.ArrayList]::new(); foreach ($k in $keep) { $null = $global:L.Refs.Add($k) }
    if ($global:L.Mode -ne 'memkeep') {
        if ($ph) { $global:L.Mem.Ph.Remove($bare) }
        else { $libs = @($global:L.Mem.Libs | Where-Object { $_.Split(',')[0] -ne $bare }); $global:L.Mem.Libs = [System.Collections.ArrayList]::new(); foreach ($l in $libs) { $null = $global:L.Mem.Libs.Add($l) } }
    }
}
$refs | Add-Member ScriptMethod FreezePlaceholder {
    Write-Calls 'FreezePlaceholder' @args
    if ($global:L.Mode -eq 'nofreeze') { return }
    $n = [string]$args[0]
    foreach ($r in @($global:L.Refs | Where-Object { $_.Name -like '#*' })) {
        if ($n -ne '' -and $r.PlaceholderName -ne $n) { continue }
        # no <PlaceholderReference> (implicit placeholder): XAE writes no Resolution (phase2-3.8.md P3)
        if (-not $global:L.Mem.Ph.Contains($r.PlaceholderName)) { continue }
        $def = $global:L.Mem.Ph[$r.PlaceholderName].Default
        # 'defaultres': as measured with FreezePlaceholder('') (phase2-3.8.md P2): fixed at the DefaultResolution
        if ($global:L.Mode -in @('defaultres', 'nopin', 'pinthrow', 'partial') -and $def -and $def -notmatch ', \* ') {
            $global:L.Mem.Ph[$r.PlaceholderName].Resolution = $def; continue
        }
        # 'partial': only the placeholders with a versioned DefaultResolution are written
        if ($global:L.Mode -eq 'partial') { continue }
        if ($null -eq $r.EffectiveResolution) { continue }
        $e = $r.EffectiveResolution
        $global:L.Mem.Ph[$r.PlaceholderName].Resolution = "$($e.LibraryName), $($e.Version) ($($e.Distributor))"
    }
}
$refs | Add-Member ScriptMethod SetEffectiveResolution {
    Write-Calls 'SetEffectiveResolution' @args
    if ($global:L.Mode -eq 'nopin') { return }
    if ($global:L.Mode -eq 'pinthrow') { throw [System.Runtime.InteropServices.COMException]::new("Placeholder '$($args[0])' not found (mock)", -2147467259) }
    $global:L.Mem.Ph[[string]$args[0]].Resolution = "$($args[1]), $($args[2]) ($($args[3]))"
}
$refs | Add-Member ScriptMethod InstallLibrary {
    Write-Calls 'InstallLibrary' @args
    switch ($global:L.Mode) {
        'exists' { throw [System.IO.IOException]::new('Library already exists.') }
        'norepo' { throw [System.Runtime.InteropServices.COMException]::new("Could not find repository '$($args[0])' (ITcPlcLibraryManager:InstallLibrary", [int]0x98510001) }
        'noinstall' { return }
    }
    $e = $global:L.InstallAdds
    $null = $global:L.Scan.Add([PSCustomObject]@{ Name = $e[0]; LibraryName = $e[0]; Version = $e[1]; Distributor = $e[2]; DisplayName = "$($e[0]), $($e[1]) ($($e[2]))" })
}
$refs | Add-Member ScriptMethod UninstallLibrary {
    Write-Calls 'UninstallLibrary' @args
    if ($global:L.Mode -eq 'nouninstall') { return }
    if ($global:L.Mode -eq 'nullref') { throw [System.NullReferenceException]::new('Object reference not set to an instance of an object.') }
    $a = $args   # $args inside a script block would be that block's own
    for ($i = 0; $i -lt $global:L.Scan.Count; $i++) {
        $s = $global:L.Scan[$i]
        if ($s.LibraryName -eq $a[1] -and $s.Version -eq $a[2] -and $s.Distributor -eq $a[3]) { $global:L.Scan.RemoveAt($i); break }
    }
    if ($global:L.Mode -eq 'keepfolder') { return }
    # XAE deletes the version folder (measured)
    $vd = Join-Path (Join-Path (Join-Path $global:L.RepoUsed $a[3]) $a[1]) $a[2]
    if (Test-Path -LiteralPath $vd) { Remove-Item -LiteralPath $vd -Recurse -Force }
}
# ITcPlcLibraryManager.Repositories: empty in the probe (Count=0); a test sets RepoFolder to return one
$refs | Add-Member ScriptProperty Repositories { if ($global:L.RepoThrow) { throw [System.Runtime.InteropServices.COMException]::new('Repositories failed (mock)', -2147467259) }; if ($global:L.RepoFolder) { , @([PSCustomObject]@{ Name = 'Custom'; Folder = $global:L.RepoFolder }) } else { , @() } }
$global:L.RefsNode = $refs
$global:L.RepoUsed = $RepoRoot
$sm = New-Object PSObject
$sm | Add-Member ScriptMethod LookupTreeItem {
    param($p)
    if ($p -ne 'TIPC^plc^plc Project^References') { throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001) }
    Write-Output -NoEnumerate $global:L.RefsNode
}
$global:L.Sm = $sm

& $mod {
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true
    $script:TcSystemLibraryRepositoryRoot = $global:L.RepoUsed
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:L.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:L.Dialog }
    function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851 }) }
    function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    function script:Get-TcPlcProjectFile {
        [CmdletBinding()] param([string]$PlcName)
        if ($global:L.Mode -eq 'nolocate') { throw "save: locate: no .tsproj of the open solution lists PLC '$PlcName' (mock)" }
        @{ PlcProjFile = $global:L.PlcProj }
    }
    function script:Invoke-TcPlcObjectSave {
        [CmdletBinding()] param([string]$ObjectPath, [string]$ExpectFile, [string]$ExpectLibrary, [string]$What, [string]$Done)
        $global:L.Saves++
        if ($global:L.SaveFailAt -and $global:L.Saves -ge $global:L.SaveFailAt) {
            return @{ Saved = $null; Error = (New-TcResult -Success $false -ErrorCode 'PROJECT_SAVE_FAILED' -ErrorMessage "$What was $Done but not saved (mock)" -Data ([PSCustomObject]@{ objectPath = $ObjectPath; savedToDisk = $false })) }
        }
        Write-MockPlcProj
        @{ Saved = [PSCustomObject]@{ plcproj = $global:L.PlcProj }; Error = $null }
    }
}
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
function Get-BackupFiles { $d = Join-Path $Root '.tcauto-backup'; if (-not (Test-Path -LiteralPath $d)) { return @() }; @(Get-ChildItem -LiteralPath $d -Recurse -File) }
function Get-WriteCalls { @($global:L.Calls | Where-Object { $_ -match '^(AddPlaceholder|RemoveReference|FreezePlaceholder|SetEffectiveResolution|InstallLibrary|UninstallLibrary)\|' }) }

try {
    # ===== pure helpers
    $p = & $mod { ConvertFrom-TcLibraryResolution -Text 'Tc2_Math, 3.5.1.0 (Beckhoff Automation GmbH)' }
    Check 'resolution text parsed' ($p.libraryName -eq 'Tc2_Math' -and $p.version -eq '3.5.1.0' -and $p.distributor -eq $B) (J $p)
    $p = & $mod { ConvertFrom-TcLibraryResolution -Text 'Tc2_Math, * (Beckhoff Automation GmbH)' }
    Check 'resolution text with * parsed' ($p.version -eq '*') (J $p)

    # ===== Get-TcLibraries
    Reset-Mock; Reset-BuildRequired
    $r = Get-TcLibraries
    $std = @($r.data.libraries | Where-Object { $_.name -eq '#Tc2_Standard' })[0]
    $frz = @($r.data.libraries | Where-Object { $_.name -eq '#Tc2_Frozen' })[0]
    $vis = @($r.data.libraries | Where-Object { $_.name -eq '#VisuPH' })[0]
    $lib = @($r.data.libraries | Where-Object { $_.name -eq 'Tc2_Lib' })[0]
    Check 'GetLibraries: 4 references, mode references' ($r.success -and $r.data.mode -eq 'references' -and $r.data.count -eq 4 -and $r.data.projectFile -eq $global:L.PlcProj) (J $r.data)
    Check 'GetLibraries: placeholder fields from EffectiveResolution (LibraryName reads empty)' ($std.isPlaceholder -and $std.placeholderName -eq 'Tc2_Standard' -and $std.libraryName -eq 'Tc2_Standard' -and $std.version -eq '3.3.3.0' -and $std.distributor -eq $B -and $std.resolvedFrom -eq 'effective') (J $std)
    Check 'GetLibraries: frozen read from .plcproj PlaceholderResolution' ($frz.frozen -eq $true -and $frz.projectResolution -eq "Tc2_Math, 3.5.1.0 ($B)" -and $std.frozen -eq $false) "$(J $frz) $(J $std)"
    Check 'GetLibraries: visu placeholder without EffectiveResolution -> default, not frozen' ($null -eq $vis.effectiveResolution -and $vis.resolvedFrom -eq 'default' -and $vis.libraryName -eq 'VisuElems' -and $vis.frozen -eq $false) (J $vis)
    Check 'GetLibraries: library reference' ((-not $lib.isPlaceholder) -and $lib.libraryName -eq 'Tc2_Lib' -and $lib.version -eq '1.0.0.0' -and $lib.frozen -eq $false) (J $lib)
    $r = Get-TcLibraries -Filter 'tc2_f*'
    Check 'GetLibraries -Filter on placeholder name' ($r.success -and $r.data.count -eq 1 -and $r.data.totalCount -eq 4 -and $r.data.libraries[0].name -eq '#Tc2_Frozen') (J $r.data)
    $global:L.Mode = 'nolocate'
    $r = Get-TcLibraries
    Check 'GetLibraries: .plcproj not located -> frozen null + warning, still success' ($r.success -and $null -eq $r.data.libraries[0].frozen -and @($r.data.warnings).Count -eq 1) (J $r.data)
    $global:L.Mode = 'ok'
    $r = Get-TcLibraries -Repository -Filter 'Tc2_M*'
    Check 'GetLibraries -Repository -Filter: ScanLibraries, 2 Tc2_Math versions' ($r.success -and $r.data.mode -eq 'repository' -and $r.data.count -eq 2 -and $r.data.totalCount -eq 4 -and @($r.data.libraries | ForEach-Object { $_.version }) -join ',' -eq '3.4.0.0,3.5.1.0' -and $global:L.Scans -eq 1) (J $r.data)
    Check 'GetLibraries wrote nothing' ((Get-WriteCalls).Count -eq 0 -and $global:L.Saves -eq 0 -and $null -eq (Get-CodeChanged)) (@($global:L.Calls) -join ';')

    # ===== Add-TcLibraryPlaceholder
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcLibraryPlaceholder -Placeholder '#P_Math' -LibraryName Tc2_Math
    Check 'AddPlaceholder: # stripped, 4-argument call' ($r.success -and @(Get-WriteCalls)[0] -eq "AddPlaceholder|P_Math|Tc2_Math|*|$B|n=4") (@($global:L.Calls) -join ';')
    Check 'AddPlaceholder: readback References + .plcproj, saved, buildRequired' ($r.data.reference.name -eq '#P_Math' -and $r.data.projectEntry.placeholder -eq 'P_Math' -and $r.data.alreadyPresent -eq $false -and $global:L.Saves -eq 1 -and $r.data.buildRequired -like '*Add-TcLibraryPlaceholder P_Math*') (J $r.data)
    Reset-Mock; Reset-BuildRequired
    foreach ($n in 'Tc2_Standard', '#tc2_standard') {
        $r = Add-TcLibraryPlaceholder -Placeholder $n -LibraryName Tc2_Standard
        Check "AddPlaceholder '$n' existing -> alreadyPresent, no call, NOT saved, .plcproj entry read, nothing recorded, no warning" ($r.success -and $r.data.alreadyPresent -eq $true -and $global:L.Saves -eq 0 -and $r.data.projectEntry.placeholder -eq 'Tc2_Standard' -and (Get-WriteCalls).Count -eq 0 -and $null -eq (Get-CodeChanged) -and $null -eq $r.data.warnings) (J $r)
    }
    $r = Add-TcLibraryPlaceholder -Placeholder Tc2_Frozen -LibraryName Tc2_Other -Version 9.9.9.9
    Check 'AddPlaceholder existing with another default library -> warning, data = values read, requested = parameters (#11)' ($r.success -and $r.data.alreadyPresent -and $r.data.libraryName -eq 'Tc2_Math' -and $r.data.version -eq '*' -and $r.data.requested.libraryName -eq 'Tc2_Other' -and $r.data.requested.version -eq '9.9.9.9' -and @($r.data.warnings | Where-Object { $_ -like '*Tc2_Math*Tc2_Other*' }).Count -eq 1 -and (Get-WriteCalls).Count -eq 0) (J $r.data)
    $global:L.Mode = 'contained'
    $r = Add-TcLibraryPlaceholder -Placeholder P_Other -LibraryName Tc2_Math
    Check 'AddPlaceholder: XAE already contained -> success alreadyPresent, recorded (AddPlaceholder was called)' ($r.success -and $r.data.alreadyPresent -eq $true -and $null -ne (Get-CodeChanged)) "$(J $r)"
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'nodefault'
    $r = Add-TcLibraryPlaceholder -Placeholder P_X -LibraryName NoSuchLib
    Check 'AddPlaceholder: default library not installed -> PLACEHOLDER_ADD_FAILED reason, no save, recorded (called) (#4)' ((-not $r.success) -and $r.error.code -eq 'PLACEHOLDER_ADD_FAILED' -and $r.data.reason -eq 'default-library-not-installed' -and $global:L.Saves -eq 0 -and (Get-CodeChanged) -like '*P_X*called*' -and $r.error.hint -like '*Install-TcLibrary*') (J $r)
    $global:L.Mode = 'nodevice'
    $r = Add-TcLibraryPlaceholder -Placeholder P_Dev
    Check 'AddPlaceholder without -LibraryName: 1-argument call; no device placeholder -> reason no-device-placeholder' ((-not $r.success) -and $r.data.reason -eq 'no-device-placeholder' -and @(Get-WriteCalls)[-1] -eq 'AddPlaceholder|P_Dev|n=1') (@($global:L.Calls) -join ';')
    $n0 = (Get-WriteCalls).Count
    $r = Add-TcLibraryPlaceholder -Placeholder P_V -Version '1.0.0.0'
    Check 'AddPlaceholder -Version without -LibraryName -> LIBRARY_INVALID_ARGUMENT, no call' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'no-library-name' -and (Get-WriteCalls).Count -eq $n0) (J $r)
    $r = Add-TcLibraryPlaceholder -Placeholder '#'
    Check 'AddPlaceholder empty name -> LIBRARY_INVALID_ARGUMENT name' ((-not $r.success) -and $r.data.reason -eq 'name') (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Dialog = @{ Title = 'Microsoft Visual Studio'; Text = 'Save changes?'; Kind = 'other' }
    $r = Add-TcLibraryPlaceholder -Placeholder P_D -LibraryName Tc2_Math
    Check 'AddPlaceholder: modal dialog -> IDE_MODAL_DIALOG, no call' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-WriteCalls).Count -eq 0) (J $r.error)
    $global:L.Dialog = $null
    $global:L.Mode = 'noappear'
    $r = Add-TcLibraryPlaceholder -Placeholder P_N -LibraryName Tc2_Math
    Check 'AddPlaceholder readback: not in References -> LIBRARY_VERIFY_FAILED step references, recorded' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.step -eq 'references' -and (Get-CodeChanged) -like '*P_N*readback failed*') (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'wronglib'
    $r = Add-TcLibraryPlaceholder -Placeholder P_W -LibraryName Tc2_Math
    Check 'AddPlaceholder readback: resolves to another library -> LIBRARY_VERIFY_FAILED step library' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.step -eq 'library') (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'memmiss'
    $r = Add-TcLibraryPlaceholder -Placeholder P_M -LibraryName Tc2_Math
    Check 'AddPlaceholder readback: .plcproj on disk lacks it -> LIBRARY_VERIFY_FAILED step project-file, recorded' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.step -eq 'project-file' -and $null -ne (Get-CodeChanged)) (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'loggedin'
    $r = Add-TcLibraryPlaceholder -Placeholder P_L -LibraryName Tc2_Math
    Check 'AddPlaceholder: PLC_LOGGED_IN passes through, hint names Exit-TcPlcOnline and the cmdlet' ((-not $r.success) -and $r.error.code -eq 'PLC_LOGGED_IN' -and $r.error.hint -like '*Exit-TcPlcOnline*Add-TcLibraryPlaceholder*') (J $r.error)

    # ===== Remove-TcLibraryReference
    Reset-Mock; Reset-BuildRequired
    $r = Remove-TcLibraryReference -Name Tc2_Nope -DryRun $false
    Check 'Remove: not in References -> LIBRARY_NOT_FOUND, data.references, no call, no backup' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_NOT_FOUND' -and @($r.data.references) -contains '#Tc2_Standard' -and (Get-WriteCalls).Count -eq 0 -and (Get-BackupFiles).Count -eq 0 -and $r.error.hint -like '*Get-TcLibraries*') (J $r)
    foreach ($n in 'Tc2_Standard', '#Tc2_Standard') {
        $r = Remove-TcLibraryReference -Name $n
        Check "Remove '$n' dry-run (default): success, no write call, no save, no backup" ($r.success -and $r.data.dryRun -eq $true -and $r.data.reference.name -eq '#Tc2_Standard' -and (Get-WriteCalls).Count -eq 0 -and $global:L.Saves -eq 0 -and (Get-BackupFiles).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.data)
    }
    $orig = [System.IO.File]::ReadAllText($global:L.PlcProj)
    $r = Remove-TcLibraryReference -Name '#Tc2_Standard' -DryRun $false
    Check 'Remove placeholder: RemoveReference called with #name (#1)' ($r.success -and @(Get-WriteCalls)[-1] -eq 'RemoveReference|#Tc2_Standard' -and $r.data.removeArgument -eq '#Tc2_Standard' -and $r.data.kind -eq 'Placeholder') (@($global:L.Calls) -join ';')
    $bf = @($r.data.backupFiles)
    Check 'Remove: .plcproj backed up below <sln dir>\.tcauto-backup before the write (byte copy = original)' ($bf.Count -eq 1 -and $bf[0] -like "$Root\.tcauto-backup\*" -and [System.IO.File]::ReadAllText($bf[0]) -eq $orig -and (Test-Path -LiteralPath $r.data.backupPath)) (J $r.data)
    Check 'Remove: verified (References + .plcproj), buildRequired' ($r.data.verified -eq $true -and [System.IO.File]::ReadAllText($global:L.PlcProj) -notmatch 'Include="Tc2_Standard"' -and (Get-CodeChanged) -like '*Remove-TcLibraryReference Tc2_Standard*') (J $r.data)
    $r = Remove-TcLibraryReference -Name Tc2_Lib -DryRun $false
    Check 'Remove library reference: LibraryReference gone from .plcproj' ($r.success -and $r.data.verified -and @(Get-WriteCalls)[-1] -eq 'RemoveReference|Tc2_Lib' -and [System.IO.File]::ReadAllText($global:L.PlcProj) -notmatch 'Tc2_Lib') (J $r.data)
    $r = Remove-TcLibraryReference -Name '#Tc2_Lib'
    Check "Remove '#Tc2_Lib' matches only placeholders -> LIBRARY_NOT_FOUND" ((-not $r.success) -and $r.error.code -eq 'LIBRARY_NOT_FOUND') (J $r.error)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'noremove'
    $r = Remove-TcLibraryReference -Name Tc2_Frozen -DryRun $false
    Check 'Remove readback: still in References -> LIBRARY_VERIFY_FAILED step references, recorded' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.step -eq 'references' -and $r.data.verified -eq $false -and $null -ne (Get-CodeChanged)) (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'memkeep'
    $r = Remove-TcLibraryReference -Name Tc2_Frozen -DryRun $false
    Check 'Remove readback: .plcproj still lists it -> LIBRARY_VERIFY_FAILED step project-file' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.step -eq 'project-file') (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'xaenotfound'
    $r = Remove-TcLibraryReference -Name Tc2_Frozen -DryRun $false
    Check 'Remove: XAE "Specified library ... not found!" -> LIBRARY_NOT_FOUND, recorded (called) (#4)' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_NOT_FOUND' -and (Get-CodeChanged) -like '*Tc2_Frozen*not found*') (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'loggedin'
    $r = Remove-TcLibraryReference -Name Tc2_Frozen -DryRun $false
    Check 'Remove: PLC_LOGGED_IN passes through with the cmdlet in the hint' ((-not $r.success) -and $r.error.code -eq 'PLC_LOGGED_IN' -and $r.error.hint -like '*Remove-TcLibraryReference*') (J $r.error)
    Reset-Mock; Reset-BuildRequired
    & $mod { $script:TcSolutionPath = $null; $script:TcDte = $null }
    $r = Remove-TcLibraryReference -Name Tc2_Frozen -DryRun $false
    Check 'Remove: no solution path -> LIBRARY_BACKUP_FAILED, no call' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_BACKUP_FAILED' -and (Get-WriteCalls).Count -eq 0) (J $r)
    Reset-Mock
    $global:L.Dialog = @{ Title = 'Microsoft Visual Studio'; Text = 'x'; Kind = 'other' }
    $r = Remove-TcLibraryReference -Name Tc2_Frozen -DryRun $false
    Check 'Remove: modal dialog -> IDE_MODAL_DIALOG, no call (backup already written)' ((-not $r.success) -and $r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-WriteCalls).Count -eq 0) (J $r.error)
    Reset-Mock
    $null = $global:L.Refs.Add((New-LibRef 'Tc2_Standard' '3.3.3.0' $B))
    $r = Remove-TcLibraryReference -Name Tc2_Standard -DryRun $false
    Check 'Remove: library + placeholder of the same name -> LIBRARY_INVALID_ARGUMENT ambiguous' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'ambiguous' -and (Get-WriteCalls).Count -eq 0) (J $r)
    $r = Remove-TcLibraryReference -Name Tc2_Standard -Kind Library -DryRun $false
    Check 'Remove -Kind Library with both present -> ambiguous-library-not-measured, no call (#1)' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'ambiguous-library-not-measured' -and (Get-WriteCalls).Count -eq 0) (J $r)
    $r = Remove-TcLibraryReference -Name '#Tc2_Standard' -Kind Library
    Check "Remove '#x' -Kind Library -> kind-conflict" ((-not $r.success) -and $r.data.reason -eq 'kind-conflict') (J $r)
    $r = Remove-TcLibraryReference -Name '#Tc2_Standard' -DryRun $false
    $left = @($global:L.Refs | ForEach-Object { $_.Name })
    Check "Remove '#x' with library x present: RemoveReference('#Tc2_Standard'), library stays, .plcproj checked for the placeholder only (#1)" ($r.success -and @(Get-WriteCalls)[-1] -eq 'RemoveReference|#Tc2_Standard' -and $left -contains 'Tc2_Standard' -and $left -notcontains '#Tc2_Standard' -and $r.data.verified) "$(J $r.data) $($left -join ',')"
    Reset-Mock
    $null = $global:L.Refs.Add((New-LibRef 'Tc2_Standard' '3.3.3.0' $B)); $null = $global:L.Mem.Libs.Add("Tc2_Standard,3.3.3.0,$B")
    $r = Remove-TcLibraryReference -Name Tc2_Standard -Kind Placeholder -DryRun $false
    Check 'Remove -Kind Placeholder with both present: #name, LibraryReference of the same name does not fail the readback' ($r.success -and @(Get-WriteCalls)[-1] -eq 'RemoveReference|#Tc2_Standard' -and [System.IO.File]::ReadAllText($global:L.PlcProj) -match 'LibraryReference Include="Tc2_Standard,') (J $r.data)
    Reset-Mock
    $r = Remove-TcLibraryReference -Name Tc2_Lib -Kind Placeholder
    Check 'Remove -Kind Placeholder for a library-only name -> LIBRARY_NOT_FOUND' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_NOT_FOUND') (J $r.error)

    # ===== Install-TcLibrary
    Reset-Mock; Reset-BuildRequired
    $libDir = Join-Path $Root 'libs'; $null = New-Item -ItemType Directory -Path $libDir -Force
    $known = Join-Path $libDir 'MyLib_1.2.3.4.library'; [System.IO.File]::WriteAllText($known, 'x')
    $newf = Join-Path $libDir 'NewLib_2.0.0.0.library'; [System.IO.File]::WriteAllText($newf, 'x')
    $odd = Join-Path $libDir 'Anything.compiled-library'; [System.IO.File]::WriteAllText($odd, 'x')
    $r = Install-TcLibrary -LibraryPath 'libs\NewLib_2.0.0.0.library'
    Check 'Install: relative path -> LIBRARY_INVALID_ARGUMENT path' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'path') (J $r)
    $r = Install-TcLibrary -LibraryPath (Join-Path $libDir 'x.zip')
    Check 'Install: wrong extension -> reason extension' ($r.data.reason -eq 'extension') (J $r)
    $r = Install-TcLibrary -LibraryPath (Join-Path $libDir 'Missing_1.0.0.0.library')
    Check 'Install: missing file -> reason missing' ($r.data.reason -eq 'missing') (J $r)
    $r = Install-TcLibrary -LibraryPath $known
    Check 'Install dry-run: file name MyLib_1.2.3.4 listed -> success, alreadyInstalled + warning, no call (#2)' ($r.success -and $r.data.alreadyInstalled -eq $true -and @($r.data.installed).Count -eq 1 -and @($r.data.warnings).Count -eq 1 -and (Get-WriteCalls).Count -eq 0) (J $r)
    $global:L.InstallAdds = @('MyLib', '1.2.3.4', 'Other Co')
    $r = Install-TcLibrary -LibraryPath $known -DryRun $false
    Check 'Install DryRun=false: same name / version, other distributor -> not blocked, XAE installs, new entry (#2)' ($r.success -and @(Get-WriteCalls)[-1] -like 'InstallLibrary|System|*MyLib_1.2.3.4.library|False' -and @($r.data.installed).Count -eq 1 -and $r.data.installed[0].distributor -eq 'Other Co') (J $r.data)
    Reset-Mock
    $r = Install-TcLibrary -LibraryPath $newf
    Check 'Install dry-run (default): not installed yet, no call' ($r.success -and $r.data.dryRun -and $r.data.alreadyInstalled -eq $false -and $r.data.identityFromFileName.name -eq 'NewLib' -and (Get-WriteCalls).Count -eq 0) (J $r.data)
    $r = Install-TcLibrary -LibraryPath $newf -DryRun $false
    Check 'Install: InstallLibrary(System, path, false), ScanLibraries readback lists the new entry, nothing recorded' ($r.success -and @(Get-WriteCalls)[-1] -eq "InstallLibrary|System|$([System.IO.Path]::GetFullPath($newf))|False" -and @($r.data.installed).Count -eq 1 -and $r.data.installed[0].name -eq 'NewLib' -and $null -eq (Get-CodeChanged)) "$(J $r.data) $(@($global:L.Calls) -join ';')"
    Reset-Mock
    $global:L.Mode = 'exists'
    $r = Install-TcLibrary -LibraryPath $odd -DryRun $false
    Check 'Install: file name without version, XAE "Library already exists." -> LIBRARY_ALREADY_INSTALLED preCheck xae' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_ALREADY_INSTALLED' -and $r.data.preCheck -eq 'xae' -and $null -eq $r.data.identityFromFileName) (J $r)
    # P8 + review S2: three states of the repository check in the dry run
    $global:L.Mode = 'ok'; $wcBefore = (Get-WriteCalls).Count
    $r = Install-TcLibrary -LibraryPath $newf -Repository NoSuchRepo
    Check 'S2 Install dry-run: Repositories lists none -> not-verified, success with a warning, no call' ($r.success -and $r.data.repositoryCheck.state -eq 'not-verified' -and $r.data.repositoryCheck.readable -eq $true -and @($r.data.warnings | Where-Object { $_ -like "*NoSuchRepo*not verified*listed none*" }).Count -eq 1 -and (Get-WriteCalls).Count -eq $wcBefore) (J $r.data)
    $global:L.RepoThrow = $true
    $r = Install-TcLibrary -LibraryPath $newf -Repository NoSuchRepo
    Check 'S2 Install dry-run: Repositories not readable -> not-verified, readable false, warning' ($r.success -and $r.data.repositoryCheck.state -eq 'not-verified' -and $r.data.repositoryCheck.readable -eq $false -and @($r.data.warnings | Where-Object { $_ -like '*could not be read*' }).Count -eq 1) (J $r.data)
    $global:L.RepoThrow = $false
    $r = Install-TcLibrary -LibraryPath $newf -Repository system
    Check 'P8 Install dry-run: System (any case) known although Repositories lists none' ($r.success -and $r.data.repositoryCheck.state -eq 'known' -and @($r.data.repositoryCheck.listed).Count -eq 0) (J $r.data)
    $global:L.RepoFolder = $RepoRoot
    $r = Install-TcLibrary -LibraryPath $newf -Repository custom
    Check 'P8 Install dry-run: a repository Repositories lists is known' ($r.success -and $r.data.repositoryCheck.state -eq 'known' -and (@($r.data.repositoryCheck.listed) -join ',') -eq 'Custom') (J $r.data)
    $r = Install-TcLibrary -LibraryPath $newf -Repository NoSuchRepo
    Check 'S2 Install dry-run: Repositories lists others, not this one -> LIBRARY_INSTALL_FAILED repository-not-found (as DryRun=false), no call' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INSTALL_FAILED' -and $r.data.reason -eq 'repository-not-found' -and $r.data.repositoryCheck.state -eq 'not-found' -and (Get-WriteCalls).Count -eq $wcBefore -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) (J $r)
    $global:L.RepoFolder = $null
    $global:L.Mode = 'norepo'
    $r = Install-TcLibrary -LibraryPath $newf -Repository NoSuchRepo -DryRun $false
    Check 'Install: unknown repository -> LIBRARY_INSTALL_FAILED reason repository-not-found' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INSTALL_FAILED' -and $r.data.reason -eq 'repository-not-found') (J $r)
    $global:L.Mode = 'noinstall'
    $r = Install-TcLibrary -LibraryPath $newf -DryRun $false
    Check 'Install readback: nothing new in ScanLibraries -> LIBRARY_VERIFY_FAILED' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.reason -eq 'not-listed') (J $r)

    # ===== Uninstall-TcLibrary
    Reset-Mock; Reset-BuildRequired
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 9.9.9.9 -Distributor $B -DryRun $false
    Check 'Uninstall: version not installed -> LIBRARY_NOT_INSTALLED, candidates, no call' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_NOT_INSTALLED' -and @($r.data.candidates).Count -eq 2 -and (Get-WriteCalls).Count -eq 0) (J $r)
    $r = Uninstall-TcLibrary -LibraryName tc2_math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall: name case differs -> LIBRARY_NOT_INSTALLED (exact match)' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_NOT_INSTALLED' -and (Get-WriteCalls).Count -eq 0) (J $r.error)
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version '*' -Distributor $B -DryRun $false
    Check 'Uninstall: wildcard version -> LIBRARY_INVALID_ARGUMENT wildcard' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'wildcard') (J $r)
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.4.0.0 -Distributor $B
    $vd = Join-Path $RepoRoot "$B\Tc2_Math\3.4.0.0"
    Check 'Uninstall dry-run (default): found, repositoryFolder derived, no call, no backup' ($r.success -and $r.data.dryRun -and $r.data.library.version -eq '3.4.0.0' -and $r.data.repositoryFolder -eq $vd -and $r.data.repositoryFolderSource -eq 'measured-default' -and (Get-WriteCalls).Count -eq 0 -and (Get-BackupFiles).Count -eq 0) (J $r.data)
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.4.0.0 -Distributor $B -DryRun $false
    Check 'Uninstall: UninstallLibrary(System, name, version, dist), verified by ScanLibraries, nothing recorded' ($r.success -and $r.data.verified -and @(Get-WriteCalls)[-1] -eq "UninstallLibrary|System|Tc2_Math|3.4.0.0|$B" -and $null -eq (Get-CodeChanged)) (J $r.data)
    $bp = [string]$r.data.backupPath
    Check 'Uninstall: version folder copied whole to .tcauto-backup\<ts>\library-repo\<name>\<version> before the call' ($bp -like "$Root\.tcauto-backup\*\library-repo\Tc2_Math\3.4.0.0" -and (Test-Path -LiteralPath (Join-Path $bp 'Tc2_Math.library')) -and [System.IO.File]::ReadAllText((Join-Path $bp 'Tc2_Math.library')) -eq 'lib Tc2_Math 3.4.0.0' -and (Test-Path -LiteralPath (Join-Path $bp 'sub\info.txt')) -and $r.data.backupFileCount -eq 2 -and -not (Test-Path -LiteralPath $vd)) (J $r.data)
    Reset-Mock
    Remove-Item -LiteralPath (Join-Path $RepoRoot "$B\Tc2_Math\3.4.0.0") -Recurse -Force
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.4.0.0 -Distributor $B -DryRun $false
    Check 'Uninstall: version folder not found -> LIBRARY_BACKUP_FAILED, not uninstalled' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_BACKUP_FAILED' -and $null -eq $r.data.repositoryFolder -and $r.error.message -like '*3.4.0.0*' -and (Get-WriteCalls).Count -eq 0) (J $r)
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -Repository Custom
    Check 'Uninstall dry-run, other repository without a known folder: repositoryFolder null + warning' ($r.success -and $null -eq $r.data.repositoryFolder -and @($r.data.warnings).Count -eq 1) (J $r.data)
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -Repository Custom -DryRun $false
    Check 'Uninstall: other repository without a known folder -> LIBRARY_BACKUP_FAILED, not uninstalled' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_BACKUP_FAILED' -and (Get-WriteCalls).Count -eq 0) (J $r.error)
    $global:L.RepoFolder = $RepoRoot
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -Repository Custom
    Check 'Uninstall: folder from ITcPlcLibraryManager.Repositories (Name / Folder)' ($r.success -and $r.data.repositoryFolderSource -eq 'repositories' -and $r.data.repositoryFolder -eq (Join-Path $RepoRoot "$B\Tc2_Math\3.5.1.0")) (J $r.data)
    $global:L.RepoFolder = $null
    & $mod { $script:TcSolutionPath = $null; $script:TcDte = $null }
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall: no solution path -> LIBRARY_BACKUP_FAILED, not uninstalled' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_BACKUP_FAILED' -and (Get-WriteCalls).Count -eq 0) (J $r.error)
    Reset-Mock
    $global:L.Mode = 'nouninstall'
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall readback: still listed -> LIBRARY_VERIFY_FAILED still-installed' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.reason -eq 'still-installed') (J $r)
    # same version in two repositories: ScanLibraries lists it twice, one call removes one (#3)
    Reset-Mock
    $null = $global:L.Scan.Add([PSCustomObject]@{ Name = 'Tc2_Math'; LibraryName = 'Tc2_Math'; Version = '3.5.1.0'; Distributor = $B; DisplayName = "Tc2_Math, 3.5.1.0 ($B)" })
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall: same version listed twice, one removed -> success (count dropped 2 -> 1), warning (#3)' ($r.success -and $r.data.matchesBefore -eq 2 -and $r.data.matchesAfter -eq 1 -and $r.data.verified -and @($r.data.warnings | Where-Object { $_ -like '*another repository*' }).Count -eq 1) (J $r.data)
    Reset-Mock
    $global:L.Mode = 'keepfolder'
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall: backed-up folder still exists afterwards -> success with warning (backup may be another copy) (#3)' ($r.success -and @($r.data.warnings | Where-Object { $_ -like '*may not be the copy*' }).Count -eq 1) (J $r.data)
    Reset-Mock
    $global:L.Mode = 'nullref'
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall: NullReferenceException -> LIBRARY_UNINSTALL_FAILED reason null-reference, cause in the message, hint = next step (#5)' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_UNINSTALL_FAILED' -and $r.data.reason -eq 'null-reference' -and $r.error.message -like '*another repository*' -and $r.error.hint -notlike '*NullReference*' -and $r.error.hint -like '*Get-TcLibraries -Repository*') (J $r.error)
    Reset-Mock
    & $mod { function script:Copy-Item { [CmdletBinding()] param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force) throw 'access denied (mock)' } }
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall: Copy-Item fails -> LIBRARY_BACKUP_FAILED, not uninstalled (#3)' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_BACKUP_FAILED' -and $r.error.message -like '*access denied*' -and (Get-WriteCalls).Count -eq 0) (J $r.error)
    & $mod { function script:Copy-Item { [CmdletBinding()] param([string]$LiteralPath, [string]$Destination, [switch]$Recurse, [switch]$Force)
            Microsoft.PowerShell.Management\Copy-Item -LiteralPath $LiteralPath -Destination $Destination -Recurse -Force
            Remove-Item -LiteralPath (Join-Path $Destination 'sub\info.txt') -Force } }
    $r = Uninstall-TcLibrary -LibraryName Tc2_Math -Version 3.5.1.0 -Distributor $B -DryRun $false
    Check 'Uninstall: copy with fewer files -> LIBRARY_BACKUP_FAILED, not uninstalled (#3)' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_BACKUP_FAILED' -and $r.error.message -like '*1 files*2*' -and (Get-WriteCalls).Count -eq 0) (J $r.error)
    & $mod { Remove-Item -LiteralPath Function:\Copy-Item -ErrorAction SilentlyContinue }

    # ===== Lock-TcLibraryPlaceholder
    Reset-Mock; Reset-BuildRequired
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc2_Standard -All
    Check 'Freeze: -Placeholder and -All together -> LIBRARY_INVALID_ARGUMENT target' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'target') (J $r)
    $r = Lock-TcLibraryPlaceholder
    Check 'Freeze: neither -Placeholder nor -All -> LIBRARY_INVALID_ARGUMENT target' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'target') (J $r)
    $r = Lock-TcLibraryPlaceholder -Placeholder P_None -DryRun $false
    Check 'Freeze: unknown placeholder -> LIBRARY_NOT_FOUND, no call' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_NOT_FOUND' -and (Get-WriteCalls).Count -eq 0) (J $r)
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc2_Lib -DryRun $false
    Check 'Freeze: library reference -> LIBRARY_INVALID_ARGUMENT not-placeholder' ((-not $r.success) -and $r.data.reason -eq 'not-placeholder') (J $r)
    $r = Lock-TcLibraryPlaceholder -Placeholder '#Tc2_Standard'
    Check 'Freeze dry-run (default): target with current .plcproj state, no call, no backup' ($r.success -and $r.data.dryRun -and $r.data.targets[0].placeholder -eq 'Tc2_Standard' -and $r.data.targets[0].frozen -eq $false -and (Get-WriteCalls).Count -eq 0 -and (Get-BackupFiles).Count -eq 0) (J $r.data)
    $r = Lock-TcLibraryPlaceholder -All
    Check 'Freeze -All dry-run: placeholder without EffectiveResolution -> warning up front (#10)' ($r.success -and @($r.data.skippedUnresolved) -contains 'VisuPH' -and @($r.data.warnings | Where-Object { $_ -like '*VisuPH*' }).Count -eq 1 -and (Get-WriteCalls).Count -eq 0) (J $r.data)
    $r = Lock-TcLibraryPlaceholder -Placeholder '#Tc2_Standard' -DryRun $false
    Check 'Freeze: FreezePlaceholder(name), backup, readback from .plcproj Resolution = fixed version, recorded' ($r.success -and @(Get-WriteCalls)[-1] -eq 'FreezePlaceholder|Tc2_Standard' -and @($r.data.backupFiles).Count -eq 1 -and $r.data.targets[0].frozen -eq $true -and $r.data.targets[0].projectResolution -eq "Tc2_Standard, 3.3.3.0 ($B)" -and (Get-CodeChanged) -like '*Lock-TcLibraryPlaceholder Tc2_Standard*') (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'nofreeze'
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc2_Standard -DryRun $false
    Check 'Freeze readback: Resolution still * -> LIBRARY_VERIFY_FAILED not-frozen, recorded' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $r.data.reason -eq 'not-frozen' -and @($r.data.notFrozen) -contains 'Tc2_Standard' -and $null -ne (Get-CodeChanged)) (J $r)
    Reset-Mock; Reset-BuildRequired
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    Check 'Freeze -All: FreezePlaceholder(''), resolved placeholders frozen, visu placeholder skipped with warning' ($r.success -and @(Get-WriteCalls)[-1] -eq 'FreezePlaceholder|' -and @($r.data.skippedUnresolved) -contains 'VisuPH' -and @($r.data.notFrozen).Count -eq 0 -and @($r.data.targets | Where-Object { $_.frozen }).Count -eq 2 -and @($r.data.warnings | Where-Object { $_ -like '*VisuPH*' }).Count -eq 1) (J $r.data)

    # ===== phase2-3.8.md P2 / P3: FreezePlaceholder('') fixes at DefaultResolution; implicit placeholder
    function Add-P2Placeholders {
        # frozen at 3.10.1.0 while DefaultResolution names 3.9.1.0 (#Tc2_System on 4026, measured)
        $null = $global:L.Refs.Add((New-PhRef 'Tc2_System' (New-LibInfo 'Tc2_System' '3.10.1.0' $B) (New-LibInfo 'Tc2_System' '3.9.1.0' $B)))
        Add-MemPh 'Tc2_System' "Tc2_System, 3.9.1.0 ($B)" "Tc2_System, 3.10.1.0 ($B)"
        # listed in References, no <PlaceholderReference> in the .plcproj (#Tc3_GlobalTypes, measured)
        $null = $global:L.Refs.Add((New-PhRef 'Tc3_GlobalTypes' (New-LibInfo 'Tc3_GlobalTypes' '3.1.0.0' $B) (New-LibInfo 'Tc3_GlobalTypes' '*' $B)))
        Write-MockPlcProj
    }
    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $r = Lock-TcLibraryPlaceholder -All
    $sys = @($r.data.targets | Where-Object { $_.placeholder -eq 'Tc2_System' })[0]
    $std = @($r.data.targets | Where-Object { $_.placeholder -eq 'Tc2_Standard' })[0]
    Check 'P2 Freeze -All dry-run: willFreezeTo = DefaultResolution, versionWillChange + warning' ($r.success -and $sys.willFreezeTo -eq "Tc2_System, 3.9.1.0 ($B)" -and $sys.versionWillChange -eq $true -and $null -eq $std.versionWillChange -and $null -eq $std.willFreezeTo -and @($r.data.warnings | Where-Object { $_ -like "*'Tc2_System'*3.9.1.0*3.10.1.0*" }).Count -eq 1 -and (Get-WriteCalls).Count -eq 0) (J $r.data)
    Check 'N5 Freeze -All dry-run: DefaultResolution * -> versionWillChange / willFreezeTo null; the pin warning is always there' ($null -eq $std.versionWillChange -and $null -eq $std.willFreezeTo -and @($r.data.warnings | Where-Object { $_ -like '*partial prediction*SetEffectiveResolution*2026-11-01*' }).Count -eq 1) (J $r.data)
    $r2 = Lock-TcLibraryPlaceholder -Placeholder Tc2_System
    Check 'N5 Freeze -Placeholder dry-run: no prediction (null) even with a versioned DefaultResolution; pin warning' ($r2.success -and $null -eq $r2.data.targets[0].versionWillChange -and $null -eq $r2.data.targets[0].willFreezeTo -and @($r2.data.warnings | Where-Object { $_ -like "*FreezePlaceholder('') is expected*" }).Count -eq 0 -and @($r2.data.warnings | Where-Object { $_ -like '*partial prediction*' }).Count -eq 1) (J $r2.data)
    Check 'P2 Freeze -All dry-run: visu warning no longer claims XAE cannot freeze it' (@($r.data.warnings | Where-Object { $_ -like '*VisuPH*' -and $_ -notlike '*cannot freeze*' -and $_ -like '*DefaultResolution*' }).Count -eq 1) (J $r.data.warnings)
    Check 'P3 Freeze -All dry-run: implicit and unresolved placeholders in data.skipped with reasons' (@($r.data.skipped | Where-Object { $_.placeholder -eq 'Tc3_GlobalTypes' -and $_.reason -eq 'implicit' }).Count -eq 1 -and @($r.data.skipped | Where-Object { $_.placeholder -eq 'VisuPH' -and $_.reason -eq 'no-effective-resolution' }).Count -eq 1) (J $r.data.skipped)

    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $global:L.Mode = 'defaultres'
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    $wc = @(Get-WriteCalls)
    Check 'P2 Freeze -All: moved placeholder pinned back with SetEffectiveResolution(name, lib, version, distributor), saved again, success' ($r.success -and $wc[0] -eq 'FreezePlaceholder|' -and $wc[1] -eq "SetEffectiveResolution|Tc2_System|Tc2_System|3.10.1.0|$B" -and $wc.Count -eq 2 -and @($r.data.pinned) -contains 'Tc2_System' -and $global:L.Saves -eq 2 -and [System.IO.File]::ReadAllText($global:L.PlcProj) -match "<Resolution>Tc2_System, 3\.10\.1\.0 \($B\)</Resolution>") "$(J $r) $($wc -join ';')"
    Check 'P3 Freeze -All: implicit placeholder skipped, not notFrozen' (@($r.data.notFrozen).Count -eq 0 -and @($r.data.skipped | Where-Object { $_.placeholder -eq 'Tc3_GlobalTypes' -and $_.reason -eq 'implicit' }).Count -eq 1) (J $r.data)

    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $global:L.Mode = 'nopin'
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    $vc = @($r.data.versionChanges)
    Check 'P2 Freeze -All: version still moved after the pin -> LIBRARY_VERSION_CHANGED with before / after, hint' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERSION_CHANGED' -and $vc.Count -eq 1 -and $vc[0].placeholder -eq 'Tc2_System' -and $vc[0].before -eq "Tc2_System, 3.10.1.0 ($B)" -and $vc[0].after -eq "Tc2_System, 3.9.1.0 ($B)" -and $vc[0].pinCalled -eq $true -and -not [string]::IsNullOrWhiteSpace($r.error.hint)) (J $r)
    Check 'P2/P3 partial write: data.changed, backup and restore named, recorded' (@($r.data.changed | Where-Object { $_.placeholder -eq 'Tc2_System' -and $_.after -like '*3.9.1.0*' }).Count -eq 1 -and @($r.data.backupFiles).Count -eq 1 -and $r.data.restore -like "*$(@($r.data.backupFiles)[0])*" -and $r.error.message -like "*$(@($r.data.backupFiles)[0])*" -and (Get-CodeChanged) -like '*version changed*') (J $r.data)

    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $global:L.Mode = 'pinthrow'
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    Check 'P2 Freeze -All: SetEffectiveResolution throws -> LIBRARY_VERSION_CHANGED with pinError, no second save' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERSION_CHANGED' -and @($r.data.versionChanges)[0].pinError -like '*not found*' -and @($r.data.versionChanges)[0].pinCalled -eq $false -and $global:L.Saves -eq 1) (J $r)

    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $global:L.Mode = 'nopin'
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc2_System -DryRun $false
    Check 'P2 single placeholder: same version check -> LIBRARY_VERSION_CHANGED' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERSION_CHANGED' -and @($r.data.versionChanges)[0].placeholder -eq 'Tc2_System') (J $r)
    Reset-Mock; Reset-BuildRequired
    $global:L.Mode = 'nofreeze'
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc2_Standard -DryRun $false
    Check 'P3 not-frozen failure names changed[] and restore' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and $null -ne $r.data.PSObject.Properties['changed'] -and $r.data.restore -like '*Reset-TcSolution*') (J $r.data)

    # ===== review B1: a placeholder -All skips that was frozen before must keep its <Resolution>
    function Set-VisuFrozen {
        $global:L.Mem.Ph['VisuPH'].Default = 'VisuElems, 2.0.0.0 (System)'
        $global:L.Mem.Ph['VisuPH'].Resolution = 'VisuElems, 1.0.0.0 (System)'
        Write-MockPlcProj
    }
    Reset-Mock; Reset-BuildRequired; Set-VisuFrozen
    $global:L.Mode = 'nopin'
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    $v = @($r.data.versionChanges | Where-Object { $_.placeholder -eq 'VisuPH' })[0]
    Check 'B1 Freeze -All: skipped visu placeholder frozen before at 1.0.0.0, moved to DefaultResolution -> LIBRARY_VERSION_CHANGED' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERSION_CHANGED' -and $v.before -eq 'VisuElems, 1.0.0.0 (System)' -and $v.after -eq 'VisuElems, 2.0.0.0 (System)' -and $v.comparedWith -eq 'resolution-before' -and @($r.data.changed | Where-Object { $_.placeholder -eq 'VisuPH' }).Count -eq 1 -and $r.data.restore -like '*Reset-TcSolution*') (J $r.data)
    Reset-Mock; Reset-BuildRequired; Set-VisuFrozen
    $global:L.Mode = 'defaultres'
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    Check 'B1 Freeze -All: the same placeholder pinned back to its earlier <Resolution> -> success, data.changed on success' ($r.success -and @($r.data.pinned) -contains 'VisuPH' -and @(Get-WriteCalls) -contains 'SetEffectiveResolution|VisuPH|VisuElems|1.0.0.0|System' -and $null -ne $r.data.PSObject.Properties['changed'] -and @($r.data.changed | Where-Object { $_.placeholder -eq 'VisuPH' }).Count -eq 0) (J $r.data)
    Reset-Mock; Reset-BuildRequired
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc2_Standard -DryRun $false
    Check 'B1 success lists data.changed (Tc2_Standard * -> 3.3.3.0)' ($r.success -and @($r.data.changed).Count -eq 1 -and $r.data.changed[0].placeholder -eq 'Tc2_Standard' -and $r.data.changed[0].after -like '*3.3.3.0*') (J $r.data.changed)

    # ===== review S4: every failure after the call carries changed[], restore, backupFiles
    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $global:L.SaveFailAt = 1
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    Check 'S4 first save fails -> save error with changed, restore, backupFiles' ((-not $r.success) -and $r.error.code -eq 'PROJECT_SAVE_FAILED' -and $null -ne $r.data.PSObject.Properties['changed'] -and $r.data.restore -like '*Reset-TcSolution*' -and @($r.data.backupFiles).Count -eq 1) (J $r.data)
    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $global:L.Mode = 'defaultres'; $global:L.SaveFailAt = 2
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    Check 'S4 second save (after the pin) fails -> changed[] from the first readback' ((-not $r.success) -and $r.error.code -eq 'PROJECT_SAVE_FAILED' -and @($r.data.changed | Where-Object { $_.placeholder -eq 'Tc2_System' -and $_.after -like '*3.9.1.0*' }).Count -eq 1 -and @($r.data.backupFiles).Count -eq 1) (J $r.data)

    # ===== review N3: -Placeholder of an implicit placeholder; notFrozen together with moved versions
    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc3_GlobalTypes
    Check 'N3 single implicit placeholder dry-run -> warning' ($r.success -and @($r.data.warnings | Where-Object { $_ -like '*Tc3_GlobalTypes*implicit-placeholder*' }).Count -eq 1) (J $r.data.warnings)
    $r = Lock-TcLibraryPlaceholder -Placeholder Tc3_GlobalTypes -DryRun $false
    Check 'N3 single implicit placeholder -> LIBRARY_INVALID_ARGUMENT implicit-placeholder before the call, nothing recorded' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_INVALID_ARGUMENT' -and $r.data.reason -eq 'implicit-placeholder' -and (Get-WriteCalls).Count -eq 0 -and $null -eq (Get-CodeChanged) -and (Get-BackupFiles).Count -eq 0) (J $r)
    Reset-Mock; Reset-BuildRequired; Add-P2Placeholders
    $global:L.Mode = 'partial'
    $r = Lock-TcLibraryPlaceholder -All -DryRun $false
    Check 'N3 notFrozen and a moved version together -> LIBRARY_VERIFY_FAILED with versionChanges, no pin' ((-not $r.success) -and $r.error.code -eq 'LIBRARY_VERIFY_FAILED' -and @($r.data.notFrozen) -contains 'Tc2_Standard' -and @($r.data.versionChanges | Where-Object { $_.placeholder -eq 'Tc2_System' }).Count -eq 1 -and @(Get-WriteCalls | Where-Object { $_ -like 'SetEffectiveResolution*' }).Count -eq 0) (J $r.data)

    # ===== XXE: .plcproj with a DOCTYPE is never parsed (#7)
    Reset-Mock
    $secret = Join-Path $Root 'secret.txt'; [System.IO.File]::WriteAllText($secret, 'TOPSECRET')
    $evil = '<?xml version="1.0"?><!DOCTYPE Project [<!ENTITY x SYSTEM "file:///' + $secret.Replace('\', '/') + '">]><Project xmlns="http://schemas.microsoft.com/developer/msbuild/2003"><ItemGroup><PlaceholderReference Include="P_X"><DefaultResolution>&x;</DefaultResolution></PlaceholderReference></ItemGroup></Project>'
    [System.IO.File]::WriteAllText($global:L.PlcProj, $evil)
    $thrown = $null
    try { $null = & $mod { param($p) Get-TcPlcProjectLibraryEntries -Path $p } $global:L.PlcProj } catch { $thrown = $_.Exception.Message }
    Check 'XXE: Get-TcPlcProjectLibraryEntries refuses a .plcproj with DOCTYPE' ($null -ne $thrown -and $thrown -match 'DTD|DOCTYPE') "$thrown"
    $thrown = $null
    try { $null = & $mod { param($p) Get-TcPlcProjectContent -Path $p } $global:L.PlcProj } catch { $thrown = $_.Exception.Message }
    Check 'XXE: Get-TcPlcProjectContent (Save-TcPlcProject readback) refuses it too' ($null -ne $thrown) "$thrown"
    $r = Get-TcLibraries
    Check 'XXE: Get-TcLibraries -> frozen null + warning, secret never in the result' ($r.success -and $null -eq $r.data.libraries[0].frozen -and @($r.data.warnings).Count -eq 1 -and (J $r) -notmatch 'TOPSECRET') (J $r.data.warnings)
    [System.IO.File]::WriteAllText((Join-Path $Root 'plc\clean.xml'), '<Project><A/></Project>')
    $ok = & $mod { param($p) $d = Read-TcXmlFile -Path $p; $d.get_DocumentElement().get_LocalName() } (Join-Path $Root 'plc\clean.xml')
    Check 'Read-TcXmlFile reads a plain file' ($ok -eq 'Project') "$ok"

    # ===== tools.json
    $tj = Join-Path $PSScriptRoot '..\..\mcp-server\tools.json'
    $tools = @((Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($t in $tools) { $byName[$t.name] = $t }
    Check 'tools.json GetLibraries: readOnly' ($byName['GetLibraries'].cmdlet -eq 'Get-TcLibraries' -and $byName['GetLibraries'].annotations.readOnlyHint -eq $true) (J $byName['GetLibraries'].annotations)
    Check 'tools.json AddPlaceholder: not read-only, not destructive, Placeholder required' ($byName['AddPlaceholder'].cmdlet -eq 'Add-TcLibraryPlaceholder' -and $byName['AddPlaceholder'].annotations.destructiveHint -eq $false -and @($byName['AddPlaceholder'].inputSchema.required) -contains 'Placeholder') (J $byName['AddPlaceholder'])
    foreach ($pair in @(@('RemoveReference', 'Remove-TcLibraryReference'), @('InstallLibrary', 'Install-TcLibrary'), @('UninstallLibrary', 'Uninstall-TcLibrary'), @('FreezePlaceholder', 'Lock-TcLibraryPlaceholder'))) {
        $t = $byName[$pair[0]]
        Check "tools.json $($pair[0]): destructive, DryRun default true" ($null -ne $t -and $t.cmdlet -eq $pair[1] -and $t.annotations.destructiveHint -eq $true -and $t.inputSchema.properties.DryRun.default -eq $true) (J $t.annotations)
    }
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    & $mod { $script:TcIdeConnected = $false; $script:TcSolutionPath = $null }
    Remove-Item -LiteralPath $Root -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}

"failed: $fail"
exit [Math]::Min($fail, 255)
