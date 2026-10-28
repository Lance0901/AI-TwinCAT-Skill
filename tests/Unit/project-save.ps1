# Unit: project file save after Add-* and the Reset-TcSolution guard (#76), no IDE needed.
# A mock DTE whose .tsproj project Save() writes a .plcproj in a temp folder; Reset-TcSolution runs
# with Get-TcUnsavedPlcObject / Save-TcPlcProject / Connect-TcIde replaced inside the module scope;
# Get-TcUnsavedPlcObject itself runs on a mock tree (ChildCount / Child / ItemType / Name / PathName).
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
foreach ($d in 'Sys\Plc\POUs\Sub', 'Sys\Plc\DUTs', 'Sys\Plc2\GVLs', 'Sys\PlcX', 'Sys\_Config\PLC', 'Sys2') { $null = New-Item -ItemType Directory -Path (Join-Path $root $d) -Force }
$root = & $mod { param($p) Get-TcLongPath $p } $root
$env:TCAUTO_STATE_DIR = Join-Path $root 'state'
$tsproj = Join-Path $root 'Sys\Sys.tsproj'
$tsproj2 = Join-Path $root 'Sys2\Sys2.tsproj'
$plcproj = Join-Path $root 'Sys\Plc\Plc.plcproj'
$plcproj2 = Join-Path $root 'Sys\Plc2\Plc2.plcproj'
$plcprojX = Join-Path $root 'Sys\PlcX\PlcX.plcproj'
$sln = Join-Path $root 'Sys.sln'
Set-Content -LiteralPath $sln -Value 'mock' -Encoding ascii
Set-Content -LiteralPath $tsproj -Encoding utf8 -Value @'
<?xml version="1.0"?>
<TcSmProject><Project><Plc><Project GUID="{1}" Name="Plc" PrjFilePath="Plc\Plc.plcproj" TmcFilePath="Plc\Plc.tmc"/><Project GUID="{2}" Name="Plc2" PrjFilePath="Plc2\Plc2.plcproj"/><Project File="PlcX.xti"/></Plc></Project></TcSmProject>
'@
# a second .tsproj that also lists a PLC named Plc (N1: first one wins, warning)
Set-Content -LiteralPath $tsproj2 -Encoding utf8 -Value @'
<?xml version="1.0"?>
<TcSmProject><Project><Plc><Project GUID="{9}" Name="Plc" PrjFilePath="..\Sys\Plc\Plc.plcproj"/></Plc></Project></TcSmProject>
'@
# independent project file: PlcX only in an .xti, PrjFilePath relative to the .xti folder (not verified layout)
Set-Content -LiteralPath (Join-Path $root 'Sys\_Config\PLC\PlcX.xti') -Encoding utf8 -Value @'
<?xml version="1.0"?>
<TcSmItem><Project GUID="{3}" Name="PlcX" PrjFilePath="..\..\PlcX\PlcX.plcproj"/></TcSmItem>
'@
function Write-Plcproj([string[]]$Compile, [string[]]$Lib = @(), [string]$Path = $plcproj) {
    $c = ($Compile | ForEach-Object { "    <Compile Include=""$_""><SubType>Code</SubType></Compile>" }) -join "`r`n"
    $l = ($Lib | ForEach-Object { "    <LibraryReference Include=""$_,newest,Beckhoff Automation GmbH""><Namespace>$_</Namespace></LibraryReference>" }) -join "`r`n"
    Set-Content -LiteralPath $Path -Encoding utf8 -Value @"
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
Write-Plcproj -Compile @('GVLs\GVL_B.TcGVL') -Path $plcproj2
Write-Plcproj -Compile @('POUs\MAIN.TcPOU') -Path $plcprojX

# mock DTE: Solution.Projects = { misc project, tsproj project (Save runs $global:Mock.OnSave), [second tsproj] }
$global:Mock = @{ Saves = 0; Closed = $false; OnSave = $null; SecondTsproj = $false }
$tsProject = New-Object PSObject
$tsProject | Add-Member -NotePropertyName FullName -NotePropertyValue $tsproj
$tsProject | Add-Member -NotePropertyName UniqueName -NotePropertyValue 'Sys\Sys.tsproj'
$tsProject | Add-Member -MemberType ScriptMethod -Name Save -Value { $global:Mock.Saves++; if ($null -ne $global:Mock.OnSave) { & $global:Mock.OnSave } }
$tsProject2 = [PSCustomObject]@{ FullName = $tsproj2; UniqueName = 'Sys2\Sys2.tsproj' }
$misc = [PSCustomObject]@{ FullName = ''; UniqueName = '<MiscFiles>' }
$projects = New-Object PSObject
$projects | Add-Member -MemberType ScriptProperty -Name Count -Value { if ($global:Mock.SecondTsproj) { 3 } else { 2 } }
$projects | Add-Member -MemberType ScriptMethod -Name Item -Value { param($i) switch ($i) { 1 { $misc } 2 { $tsProject } default { $tsProject2 } } }
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
    # Reset tests set $global:Mock.Dialog to make step 1 see (and dismiss) a reload prompt once
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $d = $global:Mock.Dialog; $global:Mock.Dialog = $null; $d }
    function script:Close-TcReloadPrompt { [CmdletBinding()] param($Dialog, [string]$Answer, [int]$TimeoutSec = 15) [PSCustomObject]@{ Dismissed = $true; Sent = $true; Reason = 'mock'; NextDialog = $null } }
} $dte $sln

try {
    # --- Get-TcPlcProjectContent: Compile leaf names, paths and library names from a namespaced .plcproj ---
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'GVLs/GVL_A.TcGVL') -Lib @('Tc2_DataExchange')
    $c = & $mod { param($p) Get-TcPlcProjectContent -Path $p } $plcproj
    Check 'content-compile' ($c.CompileLeaf.Contains('main.tcpou') -and $c.CompileLeaf.Contains('GVL_A.TcGVL') -and $c.Compile.Count -eq 2 -and $c.CompilePath.Contains('gvls\gvl_a.tcgvl')) "compile=$($c.Compile -join ',')"
    Check 'content-libraries' ($c.Libraries.Contains('Tc2_Standard') -and $c.Libraries.Contains('Tc2_DataExchange')) "libs=$(@($c.Libraries) -join ',')"
    $rel = & $mod { @((Get-TcPlcObjectRelativeFile -TreePath 'TIPC^Plc^Plc Project^POUs^Sub^FB_X' -Extension '.TcPOU'), (Get-TcPlcObjectRelativeFile -TreePath 'TIPC^Plc^Plc Project^FB_Top' -Extension '.TcPOU'), (Get-TcPlcObjectRelativeFile -TreePath 'Odd^Path' -Extension '.TcDUT')) }
    Check 'relative-file' (($rel -join '|') -eq 'POUs\Sub\FB_X.TcPOU|FB_Top.TcPOU|Path.TcDUT') ($rel -join '|')

    # --- Invoke-TcProjectSaveWithDeadline (S2): the real deadline helper with the -SaveScript test hook ---
    $msg = $null
    try { & $mod { Invoke-TcProjectSaveWithDeadline -TsProjFile 'x.tsproj' -TimeoutSec 10 -SaveScript '''done''' } } catch { $msg = $_.Exception.Message }
    Check 'deadline-in-time' ($null -eq $msg) "$msg"
    $msg = $null
    try { & $mod { Invoke-TcProjectSaveWithDeadline -TsProjFile 'x.tsproj' -TimeoutSec 10 -SaveScript 'throw ''disk full (mock)''' } } catch { $msg = $_.Exception.Message }
    Check 'deadline-error' ($msg -match '^save: Project\.Save of ''x\.tsproj'' failed \(disk full \(mock\)\)') "$msg"
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU')
    Set-ItemProperty -LiteralPath $plcproj -Name IsReadOnly -Value $true
    $msg = $null; $sw = [Diagnostics.Stopwatch]::StartNew()
    try { & $mod { param($t, $p) Invoke-TcProjectSaveWithDeadline -TsProjFile $t -PlcProjFile $p -TimeoutSec 2 -SaveScript 'Start-Sleep -Seconds 60' } $tsproj $plcproj } catch { $msg = $_.Exception.Message }
    $sec = $sw.Elapsed.TotalSeconds
    Set-ItemProperty -LiteralPath $plcproj -Name IsReadOnly -Value $false
    $diag = & $mod { $script:TcLastProjectSaveDiagnostics }
    Check 'deadline-timeout' ($msg -match '^PROJECT_SAVE_TIMEOUT' -and $sec -lt 8 -and (@($diag.readOnlyFiles) -contains $plcproj)) ("{0:N1} s {1} diag={2}" -f $sec, $msg, ($diag | ConvertTo-Json -Compress))
    $mapped = & $mod { param($m) New-TcAdsErrorResult -ErrorRecord $m -DefaultCode 'PROJECT_SAVE_FAILED' } $msg
    Check 'deadline-timeout-code' ($mapped.error.code -eq 'PROJECT_SAVE_TIMEOUT' -and -not [string]::IsNullOrWhiteSpace($mapped.error.hint)) "code=$($mapped.error.code)"

    # From here on the save runs synchronously on the mock project (no ROT / IDE pid in a unit test).
    & $mod {
        function script:Invoke-TcProjectSaveWithDeadline { [CmdletBinding()] param([string]$TsProjFile, [string]$PlcProjFile, [int]$TimeoutSec, [string]$SaveScript)
            if ($null -ne $global:Mock.SaveThrows) { $script:TcLastProjectSaveDiagnostics = [PSCustomObject]@{ dialog = $null; readOnlyFiles = @($PlcProjFile) }; throw $global:Mock.SaveThrows }
            $global:Mock.SavedTs = $TsProjFile; $global:MockTsProject.Save() }
    }
    $global:MockTsProject = $tsProject

    # --- Save-TcPlcProject (S7): relative path, preExisting, hash ---
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU')
    $global:Mock.OnSave = { Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'POUs\FB_New.TcPOU') }
    $r = & $mod { Save-TcPlcProject -PlcName 'Plc' -ExpectFile 'POUs\FB_New.TcPOU' }
    Check 'save-verified' ($global:Mock.Saves -eq 1 -and $r.plcproj -eq $plcproj -and $r.verifiedFiles[0].file -eq 'POUs\FB_New.TcPOU' -and $r.verifiedFiles[0].preExisting -eq $false -and $r.plcprojChanged -eq $true -and $null -eq $r.warning -and $r.resolvedVia -eq 'tsproj') "saves=$($global:Mock.Saves) $($r.verifiedFiles | ConvertTo-Json -Compress) changed=$($r.plcprojChanged)"

    Write-Plcproj -Compile @('POUs\MAIN.TcPOU')
    $global:Mock.OnSave = { Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'FB_New.TcPOU') }   # right name, wrong folder
    $msg = $null
    try { & $mod { Save-TcPlcProject -PlcName 'Plc' -ExpectFile 'POUs\FB_New.TcPOU' } } catch { $msg = $_.Exception.Message }
    Check 'save-wrong-folder' ($msg -match 'no <Compile Include> for POUs\\FB_New\.TcPOU') "$msg"

    Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'POUs\FB_Old.TcPOU')
    $global:Mock.OnSave = $null   # the save changes nothing: the entry was already there
    $r = & $mod { Save-TcPlcProject -PlcName 'Plc' -ExpectFile 'POUs\FB_Old.TcPOU' }
    Check 'save-preexisting' ($r.verifiedFiles[0].preExisting -eq $true -and $r.plcprojChanged -eq $false -and $r.warning -match 'already listed' -and $r.warning -match 'did not change') "$($r.warning)"

    # Save() returns but the file on disk does not have the entry: never success (#76)
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU')
    $global:Mock.OnSave = $null
    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Plc^Plc Project^POUs^FB_Lost' -ExpectFile 'FB_Lost.TcPOU' -What "POU 'FB_Lost'" }
    Check 'save-readback-missing' ($null -eq $r.Saved -and -not $r.Error.success -and $r.Error.error.code -eq 'PROJECT_SAVE_FAILED' -and $r.Error.error.message -match 'POUs\\FB_Lost.TcPOU' -and -not [string]::IsNullOrWhiteSpace($r.Error.error.hint) -and $r.Error.data.savedToDisk -eq $false) "code=$($r.Error.error.code) msg=$($r.Error.error.message)"

    # Invoke-TcPlcObjectSave turns the file name into the relative path of the object (nested folder)
    $global:Mock.OnSave = { Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'POUs\Sub\FB_Deep.TcPOU') }
    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Plc^Plc Project^POUs^Sub^FB_Deep' -ExpectFile 'FB_Deep.TcPOU' -What "POU 'FB_Deep'" }
    Check 'save-nested-relative' ($null -eq $r.Error -and $r.Saved.verifiedFiles[0].file -eq 'POUs\Sub\FB_Deep.TcPOU') "error=$($r.Error.error.message)"

    $global:Mock.OnSave = { Write-Plcproj -Compile @('POUs\MAIN.TcPOU') -Lib @('Tc2_DataExchange') }
    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Plc^Plc Project^References' -ExpectLibrary 'Tc2_DataExchange' -What 'lib' }
    Check 'save-library' ($null -eq $r.Error -and (@($r.Saved.verifiedLibraries) -join ',') -eq 'Tc2_DataExchange') "error=$($r.Error.error.code)"

    # S1: no .plcproj for the PLC -> PROJECT_SAVE_FAILED with an actionable hint (manual save)
    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Other^Other Project^POUs^X' -ExpectFile 'X.TcPOU' -What 'x' }
    Check 'save-unknown-plc' ($r.Error.error.code -eq 'PROJECT_SAVE_FAILED' -and $r.Error.error.message -match 'no \.tsproj' -and $r.Error.error.hint -match 'Save' -and $r.Error.error.hint -match 'Get-TcProjectTree') "msg=$($r.Error.error.message)"

    # S2: a save timeout keeps its code and carries data.saveDiagnostics
    $global:Mock.SaveThrows = "PROJECT_SAVE_TIMEOUT: Project.Save of 'x' did not return within 60 s (mock)"
    $r = & $mod { Invoke-TcPlcObjectSave -ObjectPath 'TIPC^Plc^Plc Project^POUs^FB_T' -ExpectFile 'FB_T.TcPOU' -What 'x' }
    $global:Mock.SaveThrows = $null
    Check 'save-timeout-result' ($r.Error.error.code -eq 'PROJECT_SAVE_TIMEOUT' -and $null -ne $r.Error.data.saveDiagnostics -and $r.Error.data.savedToDisk -eq $false) "code=$($r.Error.error.code)"

    # N1: two .tsproj list PLC 'Plc' -> the first is used, warning
    $global:Mock.SecondTsproj = $true
    $f = & $mod { Get-TcPlcProjectFile -PlcName 'Plc' }
    $global:Mock.SecondTsproj = $false
    Check 'locate-duplicate-warning' ($f.TsProjFile -eq $tsproj -and $f.Warning -match '2 project files') "warning=$($f.Warning)"
    # S1: PLC only in an independent project file (.xti)
    $f = & $mod { Get-TcPlcProjectFile -PlcName 'PlcX' }
    Check 'locate-xti' ($f.PlcProjFile -eq $plcprojX -and $f.ResolvedVia -eq 'xti' -and $f.Warning -match 'not verified') "plcproj=$($f.PlcProjFile) via=$($f.ResolvedVia)"

    # --- Get-TcUnsavedPlcObject (S3 / S4 / N2) on a mock tree ---
    $global:Tree = @{}
    function New-Node([string]$Path, [int]$Type, [switch]$ThrowChild) {
        $o = [PSCustomObject]@{ PathName = $Path; Name = ($Path -split '\^')[-1]; ItemType = $Type; Kids = [System.Collections.Generic.List[object]]::new(); ThrowChild = [bool]$ThrowChild }
        $o | Add-Member -MemberType ScriptProperty -Name ChildCount -Value { $this.Kids.Count }
        $o | Add-Member -MemberType ScriptMethod -Name Child -Value { param($i) if ($this.ThrowChild -and $i -eq 2) { throw 'child read failed (mock)' }; $this.Kids[$i - 1] }
        $parent = $Path.Substring(0, [Math]::Max(0, $Path.LastIndexOf('^')))
        if ($global:Tree.ContainsKey($parent)) { $global:Tree[$parent].Kids.Add($o) }
        $global:Tree[$Path] = $o
    }
    $P = 'TIPC^Plc^Plc Project'
    New-Node $P 601
    New-Node "$P^POUs" 601
    New-Node "$P^POUs^MAIN" 602
    New-Node "$P^POUs^FB_Case" 604            # .plcproj says fb_case.TcPOU: names compare case-insensitively
    New-Node "$P^POUs^Sub" 601                # folder: its name never counts as an object file (S4)
    New-Node "$P^POUs^Sub^FB_Deep" 604        # not in the .plcproj, file on disk
    New-Node "$P^POUs^FB_NoFile" 604          # not in the .plcproj, no file on disk
    New-Node "$P^POUs^Sub^FB_Deep^M_Run" 609  # method below a POU: not walked
    New-Node "$P^DUTs" 601
    New-Node "$P^DUTs^ST_A" 606
    New-Node "$P^Visu1" 9999                  # unknown ItemType: same base name in the .plcproj is not an extra
    $P2 = 'TIPC^Plc2^Plc2 Project'
    New-Node $P2 601 -ThrowChild
    New-Node "$P2^GVLs" 601
    New-Node "$P2^X" 601                      # Child(2) throws -> skipped -> complete = false
    New-Node "$P2^GVLs^GVL_B" 615
    $mockSm = [PSCustomObject]@{}
    $mockSm | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) $global:Tree[$p] }
    & $mod {
        function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager)
            @('Plc', 'Plc2', 'Plc3') | ForEach-Object { [PSCustomObject]@{ name = $_; nodePath = "TIPC^$_"; projectPath = "TIPC^$_^$_ Project" } } }
    }
    $global:Tree['TIPC^Plc3^Plc3 Project'] = $global:Tree[$P2]   # Plc3: tree readable, but no .tsproj lists it
    Write-Plcproj -Compile @('POUs\MAIN.TcPOU', 'POUs\fb_case.TcPOU', 'DUTs\ST_A.TcDUT', 'POUs\FB_Gone.TcPOU', 'POUs\Sub.TcPOU', 'Visu1.TcPOU', 'POUs\Notes.txt')
    Set-Content -LiteralPath (Join-Path $root 'Sys\Plc\POUs\Sub\FB_Deep.TcPOU') -Value 'x' -Encoding ascii
    $u = & $mod { param($s) Get-TcUnsavedPlcObject -SysManager $s } $mockSm
    $p1 = $u.Plcs | Where-Object { $_.plc -eq 'Plc' }
    $p2 = $u.Plcs | Where-Object { $_.plc -eq 'Plc2' }
    $p3 = $u.Plcs | Where-Object { $_.plc -eq 'Plc3' }
    $miss = @($p1.missingOnDisk | ForEach-Object { "$($_.file)=$($_.relativePath)=$($_.fileExists)" }) -join ','
    Check 'unsaved-missing-nested' ($miss -eq 'FB_NoFile.TcPOU=POUs\FB_NoFile.TcPOU=False,FB_Deep.TcPOU=POUs\Sub\FB_Deep.TcPOU=True') $miss
    Check 'unsaved-extra-files-only' ((@($p1.extraOnDisk) -join ',') -eq 'POUs\FB_Gone.TcPOU,POUs\Sub.TcPOU') "extra=$(@($p1.extraOnDisk) -join ',')"
    Check 'unsaved-complete' ($p1.checked -and $p1.complete -and $null -eq $p1.reason -and $p1.plcproj -eq $plcproj) "complete=$($p1.complete) reason=$($p1.reason)"
    Check 'unsaved-multi-plc' ($p2.checked -and @($p2.missingOnDisk).Count -eq 0 -and @($p2.extraOnDisk).Count -eq 0 -and $p2.plcproj -eq $plcproj2) "plc2 missing=$(@($p2.missingOnDisk).Count)"
    Check 'unsaved-incomplete' (-not $p2.complete -and $p2.skipped -eq 1 -and $p2.reason -match 'could not be read') "reason=$($p2.reason)"
    Check 'unsaved-unlocated-skipped' (-not $p3.checked -and $p3.reason -match 'not compared' -and @($p3.missingOnDisk).Count -eq 0) "reason=$($p3.reason)"
    $u = & $mod { param($s) Get-TcUnsavedPlcObject -SysManager $s -MaxNodes 3 } $mockSm
    $p1 = $u.Plcs | Where-Object { $_.plc -eq 'Plc' }
    Check 'unsaved-node-limit' (-not $p1.complete -and $p1.reason -match 'node limit') "reason=$($p1.reason)"
    $u = & $mod { param($s) Get-TcUnsavedPlcObject -SysManager $s -MaxSec 0 } $mockSm
    $p1 = $u.Plcs | Where-Object { $_.plc -eq 'Plc' }
    Check 'unsaved-time-limit' (-not $p1.complete -and $p1.reason -match 'time limit') "reason=$($p1.reason)"

    # --- Reset-TcSolution step 1b (M1) ---
    & $mod {
        function script:Connect-TcIde { [CmdletBinding()] param([string]$SolutionPath, [string]$ProgId, [switch]$NoLaunch)
            $script:TcSysManager = [PSCustomObject]@{ Mock = $true }   # Reset released it
            [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ ideProcessId = 0; selectedBy = 'solution-match'; sysManagerAvailable = $true; silentMode = $true } } }
        function script:Save-TcPlcProject { [CmdletBinding()] param([string]$PlcName, [string[]]$ExpectFile, [string[]]$ExpectLibrary, [int]$TimeoutSec = 60)
            $global:Mock.GuardSave = @($ExpectFile)
            if ($global:Mock.GuardSaveThrows) { throw "save: Project.Save returned but 'x.plcproj' read back from disk has no <Compile Include> for $($ExpectFile -join ', ')." }
            [ordered]@{ plc = $PlcName; plcproj = 'p.plcproj'; tsproj = 't.tsproj'; savedFiles = @('t.tsproj', 'p.plcproj'); plcprojChanged = $true; saveSec = 0.1; warning = $null } }
        function script:Get-TcUnsavedPlcObject { [CmdletBinding()] param($SysManager, [int]$MaxNodes = 5000, [double]$MaxSec = 60) $global:Mock.Unsaved }
    }
    function Set-Unsaved([string[]]$Missing, [string[]]$Extra = @(), [bool]$Complete = $true, [bool]$FileExists = $true, [bool]$Checked = $true) {
        $global:Mock.Unsaved = @{ Visited = 10; Sec = 0.1; Plcs = @([ordered]@{ plc = 'Plc'; projectPath = 'TIPC^Plc^Plc Project'; checked = $Checked; reason = $(if ($Complete) { $null } else { 'incomplete: mock' }); plcproj = $plcproj; tsproj = $tsproj; warning = $null
            missingOnDisk = @($Missing | ForEach-Object { [PSCustomObject]@{ name = $_; path = "TIPC^Plc^Plc Project^POUs^$_"; file = "$_.TcPOU"; relativePath = "POUs\$_.TcPOU"; fileExists = $FileExists } }); extraOnDisk = [string[]]$Extra; complete = $Complete; visited = 10; skipped = 0 }) }
        $global:Mock.Closed = $false; $global:Mock.GuardSave = $null; $global:Mock.GuardSaveThrows = $false; $global:Mock.Dialog = $null
    }

    Set-Unsaved -Missing @('FB_Guard')
    $r = Reset-TcSolution
    Check 'reset-default-no-save' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and $null -eq $global:Mock.GuardSave -and -not $global:Mock.Closed -and $r.error.message -match 'FB_Guard' -and $r.error.hint -match 'SaveProjectChanges' -and $r.error.hint -match 'DiscardProjectChanges' -and @($r.data.projectCheck.plcs[0].missingOnDisk).Count -eq 1) "code=$($r.error.code) saved=$($global:Mock.GuardSave) closed=$($global:Mock.Closed)"

    Set-Unsaved -Missing @('FB_Guard')
    $r = Reset-TcSolution -SaveProjectChanges
    Check 'reset-save-switch' ($r.success -and (@($global:Mock.GuardSave) -join ',') -eq 'POUs\FB_Guard.TcPOU' -and @($r.data.savedProjects).Count -eq 1 -and (@($r.data.savedProjects[0].savedObjects) -join ',') -eq 'POUs\FB_Guard.TcPOU' -and $global:Mock.Closed) "success=$($r.success) saved=$(@($r.data.savedProjects).Count) closed=$($global:Mock.Closed) err=$($r.error.message)"

    Set-Unsaved -Missing @('FB_Gone') -FileExists $false
    $r = Reset-TcSolution -SaveProjectChanges
    Check 'reset-save-refused-file-deleted' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and $null -eq $global:Mock.GuardSave -and -not $global:Mock.Closed -and (@($r.data.saveRefused | ForEach-Object { $_.reason }) -join ';') -match 'not on disk') "code=$($r.error.code) closed=$($global:Mock.Closed) refused=$(@($r.data.saveRefused).Count)"

    Set-Unsaved -Missing @('FB_Guard') -Extra @('POUs\FB_Disk.TcPOU')
    $r = Reset-TcSolution -SaveProjectChanges
    Check 'reset-save-refused-extra' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and $null -eq $global:Mock.GuardSave -and -not $global:Mock.Closed -and $r.error.message -match 'FB_Disk') "code=$($r.error.code)"

    Set-Unsaved -Missing @() -Extra @('POUs\FB_Disk.TcPOU')
    $r = Reset-TcSolution
    Check 'reset-extra-only-no-switch' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and -not $global:Mock.Closed) "code=$($r.error.code)"

    Set-Unsaved -Missing @('FB_Guard') -Complete $false
    $r = Reset-TcSolution -SaveProjectChanges
    Check 'reset-save-refused-incomplete' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and $null -eq $global:Mock.GuardSave -and -not $global:Mock.Closed) "code=$($r.error.code)"

    Set-Unsaved -Missing @('FB_Guard')
    $global:Mock.Dialog = [PSCustomObject]@{ Kind = 'reload-prompt'; ReloadTarget = 'file'; Title = 'Microsoft Visual Studio'; Text = 'File has been changed outside the environment. Reload the new file?' }
    $r = Reset-TcSolution -SaveProjectChanges
    Check 'reset-save-refused-reload' (-not $r.success -and $r.error.code -eq 'PROJECT_UNSAVED_CHANGES' -and $r.data.dismissedReloadPrompt -and $null -eq $global:Mock.GuardSave -and -not $global:Mock.Closed -and $r.error.message -match 'reload prompt') "code=$($r.error.code) dismissed=$($r.data.dismissedReloadPrompt)"

    Set-Unsaved -Missing @()
    $r = Reset-TcSolution
    Check 'reset-clean-no-save' ($r.success -and $null -eq $global:Mock.GuardSave -and @($r.data.savedProjects).Count -eq 0 -and $r.data.projectCheck.checked -and $global:Mock.Closed) "saved=$(@($r.data.savedProjects).Count)"

    Set-Unsaved -Missing @('FB_Guard') -Checked $false
    $r = Reset-TcSolution
    Check 'reset-unchecked-plc-not-blocking' ($r.success -and $global:Mock.Closed -and $null -eq $global:Mock.GuardSave) "success=$($r.success) err=$($r.error.message)"

    Set-Unsaved -Missing @('FB_Guard')
    $global:Mock.GuardSaveThrows = $true
    $r = Reset-TcSolution -SaveProjectChanges
    Check 'reset-save-failed-not-closed' (-not $r.success -and $r.error.code -eq 'PROJECT_SAVE_FAILED' -and -not $global:Mock.Closed) "code=$($r.error.code) closed=$($global:Mock.Closed)"

    Set-Unsaved -Missing @('FB_Guard') -Extra @('POUs\FB_Disk.TcPOU')
    $r = Reset-TcSolution -DiscardProjectChanges
    Check 'reset-discard' ($r.success -and $global:Mock.Closed -and $null -eq $global:Mock.GuardSave -and -not $r.data.projectCheck.checked) "success=$($r.success)"

    Set-Unsaved -Missing @('FB_Guard')
    $r = Reset-TcSolution -SaveProjectChanges -DiscardProjectChanges
    Check 'reset-switches-exclusive' (-not $r.success -and $r.error.code -eq 'INVALID_PARAMS' -and -not $global:Mock.Closed -and $null -eq $global:Mock.GuardSave) "code=$($r.error.code)"
}
catch {
    Check 'no-exception' $false "$($_.Exception.Message) @ $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
exit $fail
