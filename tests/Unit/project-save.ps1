# Unit: project file save after Add-* and the Reset-TcSolution guard (#76), no IDE needed.
# A mock DTE whose .tsproj project Save() writes a .plcproj in a temp folder; Reset-TcSolution runs
# with Get-TcUnsavedPlcObject / Save-TcPlcProject / Connect-TcIde replaced inside the module scope.
# The state file goes to a temp TCAUTO_STATE_DIR.
#   powershell.exe -NoProfile -File tests/Unit/project-save.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

$root = Join-Path $env:TEMP ("tcauto-unit-ps-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $root 'Sys\Plc') -Force
$root = & $mod { param($p) Get-TcLongPath $p } $root
$env:TCAUTO_STATE_DIR = Join-Path $root 'state'
$tsproj = Join-Path $root 'Sys\Sys.tsproj'
$plcproj = Join-Path $root 'Sys\Plc\Plc.plcproj'
$sln = Join-Path $root 'Sys.sln'
Set-Content -LiteralPath $sln -Value 'mock' -Encoding ascii
Set-Content -LiteralPath $tsproj -Encoding utf8 -Value @'
<?xml version="1.0"?>
<TcSmProject><Project><Plc><Project GUID="{1}" Name="Plc" PrjFilePath="Plc\Plc.plcproj" TmcFilePath="Plc\Plc.tmc"/></Plc></Project></TcSmProject>
'@
function Write-Plcproj([string[]]$Compile, [string[]]$Lib = @()) {
    $c = ($Compile | ForEach-Object { "    <Compile Include=""$_""><SubType>Code</SubType></Compile>" }) -join "`r`n"
    $l = ($Lib | ForEach-Object { "    <LibraryReference Include=""$_,newest,Beckhoff Automation GmbH""><Namespace>$_</Namespace></LibraryReference>" }) -join "`r`n"
    Set-Content -LiteralPath $plcproj -Encoding utf8 -Value @"
<?xml version="1.0" encoding="utf-8"?>
<Project DefaultTargets="Build" xmlns="http://schemas.microsoft.com/developer/msbuild/2003">
  <ItemGroup>
$c
  </ItemGroup>
  <ItemGroup>
    <PlaceholderReference Include="Tc2_Standard"><DefaultResolution>Tc2_Standard, * (Beckhoff Automation GmbH)</DefaultResolution><Namespace>Tc2_Standard</Namespace></PlaceholderReference>
$l
  </ItemGroup>
</Project>
"@
}
Write-Plcproj -Compile @('POUs\MAIN.TcPOU')

# mock DTE: Solution.Projects = { tsproj project (Save writes $global:Mock.OnSave), misc project }
$global:Mock = @{ Saves = 0; Closed = $false; OnSave = $null }
$tsProject = New-Object PSObject
$tsProject | Add-Member -NotePropertyName FullName -NotePropertyValue $tsproj
$tsProject | Add-Member -NotePropertyName UniqueName -NotePropertyValue 'Sys\Sys.tsproj'
$tsProject | Add-Member -MemberType ScriptMethod -Name Save -Value { $global:Mock.Saves++; if ($null -ne $global:Mock.OnSave) { & $global:Mock.OnSave } }
$misc = [PSCustomObject]@{ FullName = ''; UniqueName = '<MiscFiles>' }
$projects = New-Object PSObject
$projects | Add-Member -NotePropertyName Count -NotePropertyValue 2
$projects | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) if ($i -eq 1) { $misc } else { $tsProject } }
$solution = New-Object PSObject
$solution | Add-Member -NotePropertyName Projects -NotePropertyValue $projects
$solution | Add-Member -NotePropertyName FullName -NotePropertyValue $sln
$solution | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) $global:Mock.Closed = $true }
$solution | Add-Member -MemberType ScriptMethod -Name Open -Value { param($p) $global:Mock.Opened = $true }
$docs = New-Object PSObject
$docs | Add-Member -NotePropertyName Count -NotePropertyValue 0
$docs | Add-Member -MemberType ScriptMethod -Name CloseAll -Value { param($x) $global:Mock.ClosedAll = $true }
$dte = [PSCustomObject]@{ Solution = $solution; Documents = $docs }

& $mod {
    param($d, $s)
    $script:TcDte = $d; $script:TcIdeConnected = $true; $script:TcIdeProcessId = $null; $script:TcSolutionPath = $s
    $script:TcSysManager = [PSCustomObject]@{ Mock = $true }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $null }
} $dte $sln

try {
    # --- Get-TcPlcProjectContent: Compile leaf names and library names from a namespaced .plcproj ---
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'GVLs\GVL_A.TcGVL') -Lib @('Tc2_DataExchange')
    $c = & $mod { param($p) Get-TcPlcProjectContent -Path $p } $plcproj
    Check 'content-compile' ($c.CompileLeaf.Contains('main.tcpou') -and $c.CompileLeaf.Contains('GVL_A.TcGVL') -and $c.Compile.Count -eq 2) "compile=$($c.Compile -join ',')"
    Check 'content-libraries' ($c.Libraries.Contains('Tc2_Standard') -and $c.Libraries.Contains('Tc2_DataExchange')) "libs=$(@($c.Libraries) -join ',')"

    # --- Save-TcPlcProject: success only when the .plcproj read back from disk lists the new file ---
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU')
    $global:Mock.OnSave = { Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'POUs\FB_New.TcPOU') }
    $r = & $mod { Save-TcPlcProject -PlcName 'Plc' -ExpectFile 'FB_New.TcPOU' }
    Check 'save-verified' ($global:Mock.Saves -eq 1 -and $r.plcproj -eq $plcproj -and (@($r.verifiedFiles) -join ',') -eq 'FB_New.TcPOU') "saves=$($global:Mock.Saves) plcproj=$($r.plcproj)"

    # Save() returns but the file on disk does not have the entry: never success (#76)
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU')
    $global:Mock.OnSave = $null
    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Plc^Plc Project^POUs^FB_Lost' -ExpectFile 'FB_Lost.TcPOU' -What "POU 'FB_Lost'" }
    Check 'save-readback-missing' ($null -eq $r.Saved -and -not $r.Error.success -and $r.Error.error.code -eq 'PROJECT_SAVE_FAILED' -and $r.Error.error.message -match 'FB_Lost.TcPOU' -and -not [string]::IsNullOrWhiteSpace($r.Error.error.hint) -and $r.Error.data.savedToDisk -eq $false) "code=$($r.Error.error.code)"

    $global:Mock.OnSave = { Write-Plcproj -Compile @('POUs\MAIN.TcPOU') -Lib @('Tc2_DataExchange') }
    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Plc^Plc Project^References' -ExpectLibrary 'Tc2_DataExchange' -What 'lib' }
    Check 'save-library' ($null -eq $r.Error -and (@($r.Saved.verifiedLibraries) -join ',') -eq 'Tc2_DataExchange') "error=$($r.Error.error.code)"

    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Other^Other Project^POUs^X' -ExpectFile 'X.TcPOU' -What 'x' }
    Check 'save-unknown-plc' ($r.Error.error.code -eq 'PROJECT_SAVE_FAILED' -and $r.Error.error.message -match 'no \.tsproj') "msg=$($r.Error.error.message)"

    # --- Reset-TcSolution guard ---
    & $mod {
        function script:Connect-TcIde { [CmdletBinding()] param([string]$SolutionPath, [string]$ProgId, [switch]$NoLaunch)
            $script:TcSysManager = [PSCustomObject]@{ Mock = $true }   # Reset released it
            [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 0; selectedBy = 'solution-match'; sysManagerAvailable = $true; silentMode = $true } } }
        function script:Save-TcPlcProject { [CmdletBinding()] param([string]$PlcName, [string[]]$ExpectFile, [string[]]$ExpectLibrary, [int]$TimeoutSec = 60)
            $global:Mock.GuardSave = @($ExpectFile)
            if ($global:Mock.GuardSaveThrows) { throw "save: Project.Save returned but 'x.plcproj' read back from disk has no <Compile Include> for $($ExpectFile -join ', ')." }
            [ordered]@{ plc = $PlcName; plcproj = 'p.plcproj'; tsproj = 't.tsproj'; savedFiles = @('t.tsproj', 'p.plcproj'); saveSec = 0.1 } }
        function script:Get-TcUnsavedPlcObject { [CmdletBinding()] param($SysManager, [int]$MaxNodes = 5000) $global:Mock.Unsaved }
    }
    function Set-Unsaved([string[]]$Missing, [string[]]$Extra = @(), [bool]$Complete = $true) {
        $global:Mock.Unsaved = @{ Visited = 10; Sec = 0.1; Plcs = @([ordered]@{ plc = 'Plc'; projectPath = 'TIPC^Plc^Plc Project'; plcproj = $plcproj; tsproj = $tsproj
            missingOnDisk = @($Missing | ForEach-Object { [PSCustomObject]@{ name = $_; path = "TIPC^Plc^Plc Project^$_"; file = "$_.TcPOU" } }); extraOnDisk = [string[]]$Extra; complete = $Complete; visited = 10; skipped = 0 }) }
        $global:Mock.Closed = $false; $global:Mock.GuardSave = $null; $global:Mock.GuardSaveThrows = $false
    }

    Set-Unsaved -Missing @('FB_Guard')
    $r = Reset-TcSolution
    Check 'reset-saves-first' ($r.success -and (@($global:Mock.GuardSave) -join ',') -eq 'FB_Guard.TcPOU' -and @($r.data.savedProjects).Count -eq 1 -and (@($r.data.savedProjects[0].savedObjects) -join ',') -eq 'FB_Guard.TcPOU' -and $global:Mock.Closed) "success=$($r.success) saved=$(@($r.data.savedProjects).Count) closed=$($global:Mock.Closed)"

    Set-Unsaved -Missing @()
    $r = Reset-TcSolution
    Check 'reset-clean-no-save' ($r.success -and $null -eq $global:Mock.GuardSave -and @($r.data.savedProjects).Count -eq 0 -and $r.data.projectCheck.checked) "saved=$(@($r.data.savedProjects).Count)"

    Set-Unsaved -Missing @('FB_Guard')
    $global:Mock.GuardSaveThrows = $true
    $r = Reset-TcSolution
    Check 'reset-save-failed-not-closed' (-not $r.success -and $r.error.code -eq 'PROJECT_SAVE_FAILED' -and -not $global:Mock.Closed) "code=$($r.error.code) closed=$($global:Mock.Closed)"

    Set-Unsaved -Missing @('FB_Guard') -Extra @('POUs\FB_Disk.TcPOU')
    $r = Reset-TcSolution
    Check 'reset-conflict-not-closed' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and $null -eq $global:Mock.GuardSave -and -not $global:Mock.Closed -and $r.error.message -match 'FB_Disk') "code=$($r.error.code) closed=$($global:Mock.Closed)"

    Set-Unsaved -Missing @('FB_Guard') -Complete $false
    $r = Reset-TcSolution
    Check 'reset-incomplete-not-closed' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and -not $global:Mock.Closed) "code=$($r.error.code)"

    Set-Unsaved -Missing @('FB_Guard') -Extra @('POUs\FB_Disk.TcPOU')
    $r = Reset-TcSolution -DiscardProjectChanges
    Check 'reset-discard' ($r.success -and $global:Mock.Closed -and $null -eq $global:Mock.GuardSave -and -not $r.data.projectCheck.checked) "success=$($r.success)"
}
catch {
    Check 'no-exception' $false $_.Exception.Message
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
exit $fail
