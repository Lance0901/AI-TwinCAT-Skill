# Unit: task 3.5 (complete-automation-interface phase 2): Add-TcPlcTask (MCP AddPlcTask),
# Add-TcTaskProgram (LinkProgramToTask), Remove-TcTaskProgram (UnlinkProgramFromTask).
# No IDE / runtime: a mock ITcSysManager with an in-memory tree whose CreateChild behaves as XAE did in the
# probe (verification/phase2-probe.md 3.5): 621 needs a TIRT task of the same name and links to it by
# itself, 650 accepts any name. A temp solution directory holds PlcTask.TcTTO for the backup.
#   powershell.exe -NoProfile -File tests/Unit/plc-task.ps1
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

$Root = Join-Path $env:TEMP ("tcauto-unit-task-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $Root 'plc') -Force
$Sln = Join-Path $Root 'Task.sln'
[System.IO.File]::WriteAllText($Sln, '')
[System.IO.File]::WriteAllText((Join-Path $Root 'plc\PlcTask.TcTTO'), '<TcPlcObject><Task Name="PlcTask"><PouCall><Name>MAIN</Name></PouCall></Task></TcPlcObject>')
[System.IO.File]::WriteAllText((Join-Path $Root 'plc\plc.plcproj'), '<Project><ItemGroup><Compile Include="PlcTask.TcTTO" /></ItemGroup></Project>')
$P = 'TIPC^plc^plc Project'

$global:T = @{}
function New-TaskXml([string]$Path, [string]$Cycle = '100000', [string]$Prio = '20') {
    $name = ($Path -split '\^')[-1]
    "<TreeItem><ItemName>$name</ItemName><PathName>$Path</PathName><TaskDef><CycleTime>$Cycle</CycleTime><Priority>$Prio</Priority></TaskDef></TreeItem>"
}
function New-PlcTaskXml([string]$Path, [string]$Linked) {
    $name = ($Path -split '\^')[-1]
    "<TreeItem><ItemName>$name</ItemName><PathName>$Path</PathName><PlcTaskDef><LinkedTask>$Linked</LinkedTask></PlcTaskDef></TreeItem>"
}
function Add-MockNode([string]$Path, [int]$ItemType = 0, [string]$Xml = '') {
    $name = ($Path -split '\^')[-1]
    if ([string]::IsNullOrEmpty($Xml)) { $Xml = "<TreeItem><ItemName>$name</ItemName><PathName>$Path</PathName></TreeItem>" }
    $n = [PSCustomObject]@{ Name = $name; PathName = $Path; ItemType = $ItemType; ItemSubType = 0; ItemSubTypeName = 'TREEITEMTYPE_MOCK'; Xml = $Xml; Kids = [System.Collections.ArrayList]::new() }
    $n | Add-Member ScriptProperty ChildCount { $this.Kids.Count }
    $n | Add-Member ScriptMethod Child { param($i) $global:T.Nodes[$this.Kids[$i - 1]] }
    $n | Add-Member ScriptMethod ProduceXml { param($rec) $this.Xml }
    $n | Add-Member ScriptMethod ConsumeXml {
        param($x)
        $global:T.Mods.Add("ConsumeXml $($this.PathName)") | Out-Null
        if ($global:T.Mode -eq 'consume-ignore') { return }
        $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($this.Xml)
        $f = New-Object System.Xml.XmlDocument; $f.LoadXml($x)
        foreach ($leaf in $f.SelectNodes('//*[not(*)]')) {
            $names = @(); $q = $leaf
            while ($null -ne $q -and $q -ne $f.DocumentElement) { $names = @($q.Name) + $names; $q = $q.ParentNode }
            $t = $doc.DocumentElement
            foreach ($nm in $names) { if ($null -ne $t) { $t = $t.SelectSingleNode($nm) } }
            if ($null -ne $t) { $t.InnerText = $leaf.InnerText }
        }
        $this.Xml = $doc.OuterXml
    }
    $n | Add-Member ScriptMethod CreateChild {
        param($cname, $sub, $before, $vinfo)
        $global:T.Mods.Add("CreateChild $($this.PathName)^$cname/$sub") | Out-Null
        $cp = "$($this.PathName)^$cname"
        if ($this.PathName -eq 'TIRT') {
            if ($global:T.Mode -eq 'tirt-fail') { throw [System.Runtime.InteropServices.COMException]::new('Cannot create task (mock)', -2147467259) }
            $c = Add-MockNode $cp 19 (New-TaskXml $cp)
            Write-Output -NoEnumerate $c
            return
        }
        if ([int]$sub -eq 621) {
            if ($global:T.Mode -eq 'plc-fail') { throw [System.Runtime.InteropServices.COMException]::new("Couldn't create PLC task (mock)", -2147467259) }
            # XAE: needs the TIRT task of the same name (measured)
            if (-not $global:T.Nodes.ContainsKey("TIRT^$cname")) { throw [System.Runtime.InteropServices.COMException]::new("No task '$cname' found in Realtime-Settings!", -2147467259) }
            $linked = if ($global:T.Mode -eq 'badlink' -or $global:T.Mode -eq 'badlink-nodelete') { 'TIRT^PlcTask' } else { "TIRT^$cname" }
            if ($global:T.Mode -eq 'rename-plc') { $cp = "$cp (1)" }
            $c = Add-MockNode $cp 621 (New-PlcTaskXml $cp $linked)
            if ($global:T.Mode -eq 'badlink-nodelete') { $this | Add-Member ScriptMethod DeleteChild { param($n) $global:T.Mods.Add("DeleteChild $($this.PathName)^$n (ignored)") | Out-Null } -Force }
            Write-Output -NoEnumerate $c
            return
        }
        if ([int]$sub -eq 650) {
            if ($global:T.Mode -eq 'link-fail') { throw [System.Runtime.InteropServices.COMException]::new('E_FAIL (mock)', -2147467259) }
            # XAE accepts any name (measured); the mock rewrites the .TcTTO like XAE does
            $c = Add-MockNode $cp 650
            Write-Output -NoEnumerate $c
            return
        }
        throw [System.Runtime.InteropServices.COMException]::new('Not implemented', -2147467263)
    }
    $n | Add-Member ScriptMethod DeleteChild {
        param($cname)
        $global:T.Mods.Add("DeleteChild $($this.PathName)^$cname") | Out-Null
        if ($global:T.Mode -eq 'nodelete') { return }
        $cp = "$($this.PathName)^$cname"
        $real = @($this.Kids | Where-Object { $_ -eq $cp })[0]
        $this.Kids.Remove($real) | Out-Null
        $global:T.Nodes.Remove($real)
    }
    $n | Add-Member ScriptMethod ExportChild {
        param($cname, $file)
        $global:T.Exports.Add("$($this.PathName)|$cname|$file") | Out-Null
        if ($global:T.ExportMode -eq 'throw') { throw [System.Runtime.InteropServices.COMException]::new('Cannot export child (mock)', -2147467259) }
        if ($this.PathName -like 'TIPC^*' -and [System.IO.Path]::GetExtension($file) -ine '.zip') { throw [System.Runtime.InteropServices.COMException]::new("The filename '$file' doesn't specify a zip archive!", -2147467259) }
        [System.IO.File]::WriteAllText($file, "export $cname")
    }
    $global:T.Nodes[$Path] = $n
    $i = $Path.LastIndexOf('^')
    if ($i -gt 0) { $null = $global:T.Nodes[$Path.Substring(0, $i)].Kids.Add($Path) }
    Write-Output -NoEnumerate $n
}
function Reset-Mock {
    Remove-Item -LiteralPath (Join-Path $Root '.tcauto-backup') -Recurse -Force -ErrorAction SilentlyContinue
    $global:T.Nodes = @{}   # case-insensitive keys, like LookupTreeItem resolved MAIN for 'main' in this mock
    $global:T.Mods = [System.Collections.ArrayList]::new()
    $global:T.Exports = [System.Collections.ArrayList]::new()
    $global:T.SaveMode = 'ok'; $global:T.Saves = [System.Collections.ArrayList]::new()
    $global:T.Mode = 'ok'; $global:T.ExportMode = 'ok'; $global:T.Dialog = $null; $global:T.DialogThrows = $false; $global:T.ThrowOnLookup = $null
    $null = Add-MockNode 'TIRT'
    $null = Add-MockNode 'TIRT^PlcTask' 19 (New-TaskXml 'TIRT^PlcTask' '100000' '20')
    $null = Add-MockNode 'TIPC'
    $null = Add-MockNode 'TIPC^plc' 56
    $null = Add-MockNode $P 600
    $null = Add-MockNode "$P^POUs" 601
    $null = Add-MockNode "$P^POUs^MAIN" 602
    $null = Add-MockNode "$P^POUs^PRG_Fast" 602
    $null = Add-MockNode "$P^POUs^FB_Motor" 604
    $null = Add-MockNode "$P^GVLs" 601
    $null = Add-MockNode "$P^GVLs^GVL_X" 615
    $null = Add-MockNode "$P^PlcTask" 621 (New-PlcTaskXml "$P^PlcTask" 'TIRT^PlcTask')
    $null = Add-MockNode "$P^PlcTask^MAIN" 650
}
$sm = New-Object PSObject
$sm | Add-Member ScriptMethod LookupTreeItem {
    param($p)
    if ($null -ne $global:T.ThrowOnLookup -and $p -eq $global:T.ThrowOnLookup -and $global:T.Nodes.ContainsKey($p)) { throw 'IDE_BUSY: mock lookup rejected' }
    if (-not $global:T.Nodes.ContainsKey($p)) { throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001) }
    Write-Output -NoEnumerate $global:T.Nodes[$p]
}
$global:T.Sm = $sm

& $mod {
    param($s)
    $script:TcIdeProcessId = $null; $script:TcIdeConnected = $true; $script:TcSolutionPath = $s
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:T.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) if ($global:T.DialogThrows) { throw 'IDE_CRASHED: mock dialog scan' }; $global:T.Dialog }
    function script:Get-TcPlcProjectList { [CmdletBinding()] param($SysManager) @([PSCustomObject]@{ name = 'plc'; nodePath = 'TIPC^plc'; projectPath = 'TIPC^plc^plc Project'; adsPort = 851 }) }
    function script:Resolve-TcPlcProjectPath { [CmdletBinding()] param($SysManager, [switch]$RequireSingle) 'TIPC^plc^plc Project' }
    # Project.Save as XAE does it (phase2-3.8.md P4): the .tsproj gets every TIRT task, unless SaveMode says otherwise
    function script:Invoke-TcPlcObjectSave {
        [CmdletBinding()] param([string]$ObjectPath, [string]$ExpectFile, [string]$ExpectLibrary, [string[]]$ExpectFiles, [string]$What, [string]$Done)
        $null = $global:T.Saves.Add("$ObjectPath|$ExpectFile")
        if ($global:T.SaveMode -eq 'fail') {
            return @{ Saved = $null; Error = (New-TcResult -Success $false -ErrorCode 'PROJECT_SAVE_FAILED' -ErrorMessage "$What was created in XAE but the project file was not saved (mock)" -Data ([PSCustomObject]@{ objectPath = $ObjectPath; createdInMemory = $true; savedToDisk = $false })) }
        }
        $root = Split-Path -Parent $script:TcSolutionPath
        $ts = Join-Path $root 'Task.tsproj'
        $names = if ($global:T.SaveMode -eq 'no-tsproj') { @('PlcTask') } else { @($global:T.Nodes['TIRT'].Kids | ForEach-Object { ($_ -split '\^')[-1] }) }
        [System.IO.File]::WriteAllText($ts, '<TcSmProject><Project><System><Tasks>' + (($names | ForEach-Object { "<Task Id=`"1`"><Name>$_</Name></Task>" }) -join '') + '</Tasks></System></Project></TcSmProject>')
        @{ Saved = [PSCustomObject]@{ tsproj = $ts; plcproj = (Join-Path $root 'plc\plc.plcproj'); verifiedFiles = @($ExpectFile) }; Error = $null }
    }
} $Sln
function Get-CodeChanged { & $mod { $e = Get-TcBuildRequired; if ($null -eq $e) { return $null }; (Get-TcBuildRequiredReasons $e)['code-changed'] } }
function Reset-BuildRequired { & $mod { $null = Clear-TcBuildRequired } }
function Get-Writes { @($global:T.Mods | Where-Object { $_ -match '^(CreateChild|ConsumeXml|DeleteChild) ' }) }

try {
    # ===== CycleTime unit (100 ns)
    $c1 = & $mod { ConvertTo-TcTaskCycleTime -CycleTimeUs 1000 }
    $c2 = & $mod { ConvertTo-TcTaskCycleTime -CycleTimeUs 2000 }
    $c3 = & $mod { ConvertTo-TcTaskCycleTime -CycleTimeUs 50 }
    Check 'CycleTime: us * 10 (1 ms = 10000, 2 ms = 20000, 50 us = 500)' ($c1 -eq 10000 -and $c2 -eq 20000 -and $c3 -eq 500) "$c1 $c2 $c3"

    # ===== Add-TcPlcTask: argument checks, dry-run
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 0
    Check 'AddPlcTask CycleTimeUs 0 -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS' -and (Get-Writes).Count -eq 0) (J $r.error)
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs -5
    Check 'AddPlcTask CycleTimeUs negative -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcPlcTask -Name 'a^b' -CycleTimeUs 1000
    Check 'AddPlcTask name with ^ -> INVALID_PARAMS' ($r.error.code -eq 'INVALID_PARAMS') (J $r.error)
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -Priority 10
    Check 'AddPlcTask dry-run: success, nothing written, CycleTime 10000 in the fragment' ($r.success -and $r.data.dryRun -and (Get-Writes).Count -eq 0 -and $r.data.cycleTime -eq 10000 -and $r.data.xml -eq '<TreeItem><TaskDef><CycleTime>10000</CycleTime><Priority>10</Priority></TaskDef></TreeItem>' -and @($r.data.plannedSteps).Count -eq 5) (J $r.data)
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000
    Check 'AddPlcTask dry-run without Priority: fragment has CycleTime only' ($r.success -and $r.data.xml -eq '<TreeItem><TaskDef><CycleTime>10000</CycleTime></TaskDef></TreeItem>' -and $null -eq $r.data.priority) (J $r.data)
    Check 'AddPlcTask dry-run records no BUILD_REQUIRED' ($null -eq (Get-CodeChanged)) "$(Get-CodeChanged)"
    $r = Add-TcPlcTask -Name plctask -CycleTimeUs 1000
    Check 'AddPlcTask existing name (other case) -> TASK_ALREADY_EXISTS in TIRT and plc' ($r.error.code -eq 'TASK_ALREADY_EXISTS' -and @($r.data.existingIn) -contains 'TIRT' -and @($r.data.existingIn) -contains 'plc' -and (Get-Writes).Count -eq 0) (J $r)

    # ===== Add-TcPlcTask: live success
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -Priority 10 -DryRun $false
    $tx = $global:T.Nodes['TIRT^FastTask']; $px = $global:T.Nodes["$P^FastTask"]
    Check 'AddPlcTask live: success, verified' ($r.success -and $r.data.verified) (J $r)
    Check 'AddPlcTask live: TIRT task with CycleTime 10000 / Priority 10' ($null -ne $tx -and $tx.Xml -match '<CycleTime>10000</CycleTime>' -and $tx.Xml -match '<Priority>10</Priority>' -and $r.data.readCycleTime -eq '10000' -and $r.data.readPriority -eq '10') "$($tx.Xml)"
    Check 'AddPlcTask live: PLC task 621 linked to TIRT^FastTask' ($null -ne $px -and $px.ItemType -eq 621 -and $r.data.linkedTask -eq 'TIRT^FastTask') (J $r.data)
    Check 'AddPlcTask live: order TIRT create -> ConsumeXml -> 621 create' ((Get-Writes) -join ';' -eq "CreateChild TIRT^FastTask/1;ConsumeXml TIRT^FastTask;CreateChild $P^FastTask/621") ((Get-Writes) -join ';')
    Check 'AddPlcTask live: verifyHint names _TaskInfo[n].CycleCount' ($r.data.verifyHint -match '_TaskInfo\[n\]\.CycleCount' -and $r.data.verifyHint -match 'not the TIRT order') "$($r.data.verifyHint)"
    Check 'AddPlcTask live: BUILD_REQUIRED code-changed recorded' ((Get-CodeChanged) -match 'Add-TcPlcTask FastTask' -and $r.data.buildRequired -match 'Add-TcPlcTask') "$(Get-CodeChanged)"
    Check 'P4 AddPlcTask live: project saved for <Name>.TcTTO, .tsproj read back' (@($global:T.Saves).Count -eq 1 -and $global:T.Saves[0] -eq "$P^FastTask|FastTask.TcTTO" -and $null -ne $r.data.projectSaved -and @($r.data.steps | Where-Object { $_.step -eq 'save' -and $_.success }).Count -eq 1) "$(J $r.data) $($global:T.Saves -join ';')"
    Check 'AddPlcTask live: steps recorded' (@($r.data.steps).Count -eq 5 -and @($r.data.steps | Where-Object { -not $_.success }).Count -eq 0) (J $r.data.steps)

    # P4: the save fails -> its error, objects kept in XAE memory (as Add-TcPou), task paths in data, recorded
    Reset-Mock; Reset-BuildRequired; $global:T.SaveMode = 'fail'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'P4 AddPlcTask save fails -> PROJECT_SAVE_FAILED, no rollback, plcTaskPath in data, recorded' ((-not $r.success) -and $r.error.code -eq 'PROJECT_SAVE_FAILED' -and $r.data.createdInMemory -eq $true -and $r.data.plcTaskPath -eq "$P^FastTask" -and $global:T.Nodes.ContainsKey("$P^FastTask") -and @(Get-Writes | Where-Object { $_ -like 'DeleteChild*' }).Count -eq 0 -and (Get-CodeChanged) -match 'project file not saved') "$(J $r)"
    # P4: saved, but the .tsproj on disk has no such task -> TASK_VERIFY_FAILED save-verify, rolled back
    Reset-Mock; Reset-BuildRequired; $global:T.SaveMode = 'no-tsproj'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'P4 AddPlcTask .tsproj without the task -> TASK_VERIFY_FAILED step save-verify, rolled back' ((-not $r.success) -and $r.error.code -eq 'TASK_VERIFY_FAILED' -and $r.data.step -eq 'save-verify' -and @($r.data.mismatches | Where-Object { $_.field -eq '.tsproj TIRT task' }).Count -eq 1 -and $r.data.rolledBack -and -not $global:T.Nodes.ContainsKey('TIRT^FastTask')) "$(J $r.data)"
    $h = & $mod { param($p) Test-TcTsProjHasTask -Path $p -Name 'fasttask' } (Join-Path $Root 'Task.tsproj')
    Check 'P4 Test-TcTsProjHasTask: case-sensitive name' (-not $h.Found) "$($h | ConvertTo-Json -Compress)"

    # ===== Add-TcPlcTask: rollback
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'plc-fail'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'AddPlcTask 621 fails -> TASK_CREATE_FAILED step plc-create' ($r.error.code -eq 'TASK_CREATE_FAILED' -and $r.data.step -eq 'plc-create' -and $null -ne $r.data.stepError) (J $r.error)
    Check 'AddPlcTask 621 fails -> TIRT task rolled back' (-not $global:T.Nodes.ContainsKey('TIRT^FastTask') -and $r.data.rolledBack -and @($r.data.rollback).Count -eq 1 -and $r.data.rollback[0].path -eq 'TIRT^FastTask' -and $r.data.rollback[0].removed) (J $r.data.rollback)
    Check 'AddPlcTask 621 fails -> message says rolled back, BUILD_REQUIRED recorded' ($r.error.message -match 'rolled back' -and (Get-CodeChanged) -match 'Add-TcPlcTask FastTask \[failed at plc-create\]') "$($r.error.message) | $(Get-CodeChanged)"

    Reset-Mock; $global:T.Mode = 'badlink'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'AddPlcTask wrong LinkedTask -> TASK_VERIFY_FAILED, both objects rolled back' ($r.error.code -eq 'TASK_VERIFY_FAILED' -and $r.data.step -eq 'verify' -and -not $global:T.Nodes.ContainsKey('TIRT^FastTask') -and -not $global:T.Nodes.ContainsKey("$P^FastTask") -and $r.data.rolledBack -and @($r.data.rollback).Count -eq 2 -and $r.data.rollback[0].path -eq "$P^FastTask") (J $r.data)
    Check 'AddPlcTask wrong LinkedTask -> mismatches name the field' (@($r.data.mismatches | Where-Object { $_.field -eq 'PlcTaskDef/LinkedTask' -and $_.actual -eq 'TIRT^PlcTask' }).Count -eq 1) (J $r.data.mismatches)

    Reset-Mock; $global:T.Mode = 'consume-ignore'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'AddPlcTask CycleTime not applied -> TASK_CREATE_FAILED step cycle-time, TIRT task rolled back' ($r.error.code -eq 'TASK_CREATE_FAILED' -and $r.data.step -eq 'cycle-time' -and -not $global:T.Nodes.ContainsKey('TIRT^FastTask') -and $r.data.rolledBack) (J $r.data)

    Reset-Mock; $global:T.Mode = 'tirt-fail'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'AddPlcTask TIRT create fails -> TASK_CREATE_FAILED step tirt-create, nothing to roll back' ($r.error.code -eq 'TASK_CREATE_FAILED' -and $r.data.step -eq 'tirt-create' -and @($r.data.rollback).Count -eq 0 -and $r.data.rolledBack) (J $r.data)

    # rollback that cannot delete (TIRT DeleteChild does nothing): reported, not hidden
    Reset-Mock; $global:T.Mode = 'plc-fail'
    $r = & {
        $global:T.Nodes['TIRT'] | Add-Member ScriptMethod DeleteChild { param($cname) $global:T.Mods.Add("DeleteChild TIRT^$cname") | Out-Null } -Force
        Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    }
    Check 'AddPlcTask rollback that fails -> rolledBack false, message says ROLLBACK INCOMPLETE' ($r.error.code -eq 'TASK_CREATE_FAILED' -and -not $r.data.rolledBack -and $r.error.message -match 'ROLLBACK INCOMPLETE' -and $global:T.Nodes.ContainsKey('TIRT^FastTask')) (J $r.data.rollback)

    # S1: a modal dialog before the first CreateChild -> nothing called, nothing recorded
    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = [PSCustomObject]@{ Title = 'Microsoft Visual Studio'; Text = 'Assertion Failed'; Kind = 'unknown'; Buttons = @('OK') }
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'AddPlcTask modal dialog -> IDE_MODAL_DIALOG, nothing created, BUILD_REQUIRED not recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-Writes).Count -eq 0 -and $null -eq (Get-CodeChanged) -and $null -eq $r.data.PSObject.Properties['buildRequired']) "$(J $r.error) | $(Get-CodeChanged)"

    # S2: XAE renames the PLC task -> failure, the renamed object (data.createdPath) is rolled back
    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'rename-plc'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'AddPlcTask PLC task renamed by XAE -> TASK_CREATE_FAILED plc-create, renamed path and TIRT task rolled back' ($r.error.code -eq 'TASK_CREATE_FAILED' -and $r.data.step -eq 'plc-create' -and $r.data.rollback[0].path -eq "$P^FastTask (1)" -and $r.data.rolledBack -and -not $global:T.Nodes.ContainsKey("$P^FastTask (1)") -and -not $global:T.Nodes.ContainsKey('TIRT^FastTask')) (J $r.data.rollback)

    # S3: the PLC task cannot be deleted -> the TIRT task is left, SKIPPED_DEPENDENT
    Reset-Mock; $global:T.Mode = 'badlink-nodelete'
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    $skip = @($r.data.rollback | Where-Object { $_.path -eq 'TIRT^FastTask' })[0]
    Check 'AddPlcTask PLC task not deletable -> TIRT task SKIPPED_DEPENDENT, not deleted, message says delete the PLC task first' ($r.error.code -eq 'TASK_VERIFY_FAILED' -and -not $r.data.rolledBack -and $skip.code -eq 'SKIPPED_DEPENDENT' -and -not $skip.removed -and $global:T.Nodes.ContainsKey('TIRT^FastTask') -and @(Get-Writes | Where-Object { $_ -like 'DeleteChild TIRT^*' }).Count -eq 0 -and $r.error.message -match 'delete the PLC task first' -and $r.error.hint -match 'SKIPPED_DEPENDENT') "$(J $r.data.rollback) | $($r.error.message)"

    # S5: name only below TIRT -> the TIRT-only hint
    Reset-Mock
    $null = Add-MockNode 'TIRT^Lonely' 19 (New-TaskXml 'TIRT^Lonely')
    $r = Add-TcPlcTask -Name Lonely -CycleTimeUs 1000
    $h = & $mod { Get-TcErrorHint -Code 'TASK_ALREADY_EXISTS_TIRT' }
    Check 'AddPlcTask name only in TIRT -> TASK_ALREADY_EXISTS with the TIRT-only hint' ($r.error.code -eq 'TASK_ALREADY_EXISTS' -and (@($r.data.existingIn) -join ',') -eq 'TIRT' -and $r.error.hint -eq $h -and $r.error.hint -notmatch 'Add-TcTaskProgram') "$(J $r.error)"
    $r = Add-TcPlcTask -Name PlcTask -CycleTimeUs 1000
    Check 'AddPlcTask name in plc -> TASK_ALREADY_EXISTS hint names Add-TcTaskProgram' ($r.error.code -eq 'TASK_ALREADY_EXISTS' -and $r.error.hint -match 'Add-TcTaskProgram') "$(J $r.error)"

    # N5: an exception after the first steps -> data.steps and the rollback are still in the result
    Reset-Mock; Reset-BuildRequired; $global:T.ThrowOnLookup = "$P^FastTask"
    $r = Add-TcPlcTask -Name FastTask -CycleTimeUs 1000 -DryRun $false
    Check 'AddPlcTask exception path -> data.steps, rollback of the TIRT task, BUILD_REQUIRED recorded' ((-not $r.success) -and @($r.data.steps).Count -eq 3 -and $null -ne $r.data.PSObject.Properties['rollback'] -and @($r.data.rollback | Where-Object { $_.path -eq 'TIRT^FastTask' -and $_.removed }).Count -eq 1 -and (Get-CodeChanged) -match 'Add-TcPlcTask FastTask') "$(J $r)"

    # ===== Add-TcTaskProgram
    Reset-Mock; Reset-BuildRequired
    $r = Add-TcTaskProgram -ProgramName PRG_Fast
    Check 'Link dry-run: success, nothing created' ($r.success -and $r.data.plannedPath -eq "$P^PlcTask^PRG_Fast" -and (Get-Writes).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.data)
    $r = Add-TcTaskProgram -ProgramName NoSuchProg
    Check 'Link: missing name -> TASK_PROGRAM_INVALID not-found' ($r.error.code -eq 'TASK_PROGRAM_INVALID' -and $r.data.reason -eq 'not-found' -and (Get-Writes).Count -eq 0) (J $r)
    $r = Add-TcTaskProgram -ProgramName FB_Motor
    Check 'Link: function block -> TASK_PROGRAM_INVALID not-a-program' ($r.error.code -eq 'TASK_PROGRAM_INVALID' -and $r.data.reason -eq 'not-a-program' -and $r.data.itemType -eq 604) (J $r)
    $r = Add-TcTaskProgram -ProgramName GVL_X
    Check 'Link: GVL -> TASK_PROGRAM_INVALID not-a-program' ($r.error.code -eq 'TASK_PROGRAM_INVALID' -and $r.data.reason -eq 'not-a-program' -and $r.data.objectKind -eq 'GVL') (J $r)
    $r = Add-TcTaskProgram -ProgramName prg_fast
    Check 'Link: other case -> TASK_PROGRAM_INVALID case-mismatch with actualName' ($r.error.code -eq 'TASK_PROGRAM_INVALID' -and $r.data.reason -eq 'case-mismatch' -and $r.data.actualName -eq 'PRG_Fast' -and (Get-Writes).Count -eq 0) (J $r)
    $r = Add-TcTaskProgram -ProgramName MAIN
    Check 'Link: already linked -> TASK_PROGRAM_ALREADY_LINKED' ($r.error.code -eq 'TASK_PROGRAM_ALREADY_LINKED' -and $r.data.existingLink -eq 'MAIN' -and (Get-Writes).Count -eq 0) (J $r)
    $r = Add-TcTaskProgram -ProgramName PRG_Fast -PlcTask NoTask
    Check 'Link: task missing -> TASK_NOT_FOUND with plcTasks' ($r.error.code -eq 'TASK_NOT_FOUND' -and $r.data.reason -eq 'not-found' -and @($r.data.plcTasks) -contains 'PlcTask') (J $r)
    $r = Add-TcTaskProgram -ProgramName PRG_Fast -PlcTask POUs
    Check 'Link: -PlcTask not a 621 -> TASK_NOT_FOUND not-a-task' ($r.error.code -eq 'TASK_NOT_FOUND' -and $r.data.reason -eq 'not-a-task') (J $r)
    Check 'Link: refused requests record nothing' ($null -eq (Get-CodeChanged) -and (Get-Writes).Count -eq 0) "$(Get-CodeChanged)"

    $r = Add-TcTaskProgram -ProgramName PRG_Fast -DryRun $false
    Check 'Link live: success, 650 below the task, verified' ($r.success -and $r.data.verified -and $global:T.Nodes["$P^PlcTask^PRG_Fast"].ItemType -eq 650 -and @($r.data.linkedPrograms) -contains 'PRG_Fast') (J $r.data)
    Check 'Link live: .TcTTO of the task backed up' (@($r.data.backupFiles | Where-Object { $_ -like '*PlcTask.TcTTO' -and (Test-Path -LiteralPath $_) }).Count -eq 1) (J $r.data.backupFiles)
    Check 'Link live: BUILD_REQUIRED code-changed' ((Get-CodeChanged) -match 'Add-TcTaskProgram PRG_Fast -> PlcTask') "$(Get-CodeChanged)"

    Reset-Mock; Reset-BuildRequired; $global:T.Mode = 'link-fail'
    $r = Add-TcTaskProgram -ProgramName PRG_Fast -DryRun $false
    Check 'Link live, XAE refuses -> TREEITEM_CREATE_FAILED, recorded (the API was called)' ($r.error.code -eq 'TREEITEM_CREATE_FAILED' -and $r.data.step -eq 'create' -and (Get-CodeChanged) -match 'Add-TcTaskProgram PRG_Fast -> PlcTask \[failed\]') "$(J $r.error) | $(Get-CodeChanged)"

    Reset-Mock; Reset-BuildRequired; $global:T.Dialog = [PSCustomObject]@{ Title = 'Microsoft Visual Studio'; Text = 'Assertion Failed'; Kind = 'unknown'; Buttons = @('OK') }
    $r = Add-TcTaskProgram -ProgramName PRG_Fast -DryRun $false
    Check 'Link live, modal dialog -> IDE_MODAL_DIALOG, nothing created, nothing recorded' ($r.error.code -eq 'IDE_MODAL_DIALOG' -and (Get-Writes).Count -eq 0 -and $null -eq (Get-CodeChanged)) (J $r.error)

    # S4: the hint names data.existingLink
    Reset-Mock
    $r = Add-TcTaskProgram -ProgramName MAIN
    Check 'Link already linked -> hint uses -ProgramName <data.existingLink>' ($r.error.code -eq 'TASK_PROGRAM_ALREADY_LINKED' -and $r.error.hint -match '-ProgramName <data.existingLink>') "$($r.error.hint)"

    # N3: the name is only linked (650 in two tasks), the program itself is missing -> not-found
    Reset-Mock
    $null = Add-MockNode "$P^PlcTask^Ghost" 650
    $null = Add-MockNode "$P^Task2" 621 (New-PlcTaskXml "$P^Task2" 'TIRT^Task2')
    $null = Add-MockNode "$P^Task2^Ghost" 650
    $r = Add-TcTaskProgram -ProgramName Ghost -PlcTask Task2
    Check 'Link: only program calls of that name (650 x2) -> TASK_PROGRAM_INVALID not-found, not POU_AMBIGUOUS' ($r.error.code -eq 'TASK_PROGRAM_INVALID' -and $r.data.reason -eq 'not-found' -and @($r.data.programCalls).Count -eq 2) (J $r)

    # N2: an exception before CreateChild -> not recorded
    Reset-Mock; Reset-BuildRequired; $global:T.DialogThrows = $true
    $r = Add-TcTaskProgram -ProgramName PRG_Fast -DryRun $false
    Check 'Link: exception before CreateChild -> error, nothing created, BUILD_REQUIRED not recorded' ((-not $r.success) -and (Get-Writes).Count -eq 0 -and $null -eq (Get-CodeChanged)) "$(J $r.error) | $(Get-CodeChanged)"

    # ===== Remove-TcTaskProgram
    Reset-Mock; Reset-BuildRequired
    $r = Remove-TcTaskProgram -ProgramName MAIN
    Check 'Unlink dry-run: success, nothing removed' ($r.success -and $r.data.callPath -eq "$P^PlcTask^MAIN" -and $r.data.itemType -eq 650 -and (Get-Writes).Count -eq 0 -and $global:T.Nodes.ContainsKey("$P^PlcTask^MAIN")) (J $r.data)
    $r = Remove-TcTaskProgram -ProgramName main
    Check 'Unlink: other case -> TASK_PROGRAM_NOT_LINKED with caseMatches' ($r.error.code -eq 'TASK_PROGRAM_NOT_LINKED' -and @($r.data.caseMatches) -contains 'MAIN' -and (Get-Writes).Count -eq 0) (J $r)
    $r = Remove-TcTaskProgram -ProgramName PRG_Fast
    Check 'Unlink: not linked -> TASK_PROGRAM_NOT_LINKED' ($r.error.code -eq 'TASK_PROGRAM_NOT_LINKED') (J $r.error)
    $r = Remove-TcTaskProgram -ProgramName MAIN -PlcTask NoTask
    Check 'Unlink: task missing -> TASK_NOT_FOUND' ($r.error.code -eq 'TASK_NOT_FOUND') (J $r.error)

    $r = Remove-TcTaskProgram -ProgramName MAIN -DryRun $false
    Check 'Unlink live: success, call removed, verified' ($r.success -and $r.data.verified -and -not $global:T.Nodes.ContainsKey("$P^PlcTask^MAIN") -and $r.data.remainingCalls -eq 0) (J $r.data)
    Check 'Unlink live: .TcTTO backed up and the call exported (.zip) before DeleteChild' (@($r.data.taskBackupFiles | Where-Object { $_ -like '*PlcTask.TcTTO' -and (Test-Path -LiteralPath $_) }).Count -eq 1 -and [string]$r.data.exportPath -like '*.zip' -and (Test-Path -LiteralPath ([string]$r.data.exportPath))) (J $r.data)
    Check 'Unlink live: the program itself stays' ($global:T.Nodes.ContainsKey("$P^POUs^MAIN")) ''
    Check 'Unlink live: BUILD_REQUIRED code-changed' ((Get-CodeChanged) -match 'Remove-TcTaskProgram MAIN <- PlcTask') "$(Get-CodeChanged)"

    Reset-Mock; $global:T.ExportMode = 'throw'
    $r = Remove-TcTaskProgram -ProgramName MAIN -DryRun $false
    $tto = @($r.data.taskBackupFiles)[0]
    $w = @($r.data.warnings | Where-Object { $_ -match 'restorable backup is the \.TcTTO copy' })
    Check 'Unlink live, ExportChild fails but .TcTTO copied -> removed, warning names the .TcTTO copy and the restore (not measured)' ($r.success -and -not $global:T.Nodes.ContainsKey("$P^PlcTask^MAIN") -and $w.Count -eq 1 -and $w[0].Contains([string]$tto) -and $w[0] -match 'Reset-TcSolution' -and $w[0] -match 'not measured yet' -and $w[0] -match 'ExportChild backup failed') (J $r.data.warnings)
    Check 'Unlink live, ExportChild fails: the misleading generic -AllowNoExport warning is gone' (@($r.data.warnings | Where-Object { $_ -match '-AllowNoExport: deleting with only the ProduceXml' }).Count -eq 0) (J $r.data.warnings)

    Reset-Mock; $global:T.ExportMode = 'throw'
    Remove-Item -LiteralPath (Join-Path $Root 'plc\PlcTask.TcTTO') -Force
    $r = Remove-TcTaskProgram -ProgramName MAIN -DryRun $false
    Check 'Unlink live, ExportChild fails and no .TcTTO -> TREEITEM_BACKUP_FAILED, nothing removed' ($r.error.code -eq 'TREEITEM_BACKUP_FAILED' -and $global:T.Nodes.ContainsKey("$P^PlcTask^MAIN") -and @(Get-Writes | Where-Object { $_ -like 'DeleteChild*' }).Count -eq 0) (J $r.error)
    [System.IO.File]::WriteAllText((Join-Path $Root 'plc\PlcTask.TcTTO'), '<TcPlcObject/>')

    Reset-Mock; $global:T.Mode = 'nodelete'
    $r = Remove-TcTaskProgram -ProgramName MAIN -DryRun $false
    Check 'Unlink live, DeleteChild does nothing -> TREEITEM_VERIFY_FAILED' ($r.error.code -eq 'TREEITEM_VERIFY_FAILED' -and $global:T.Nodes.ContainsKey("$P^PlcTask^MAIN")) (J $r.error)

    # N2: parent-mismatch is refused before DeleteChild -> not recorded
    Reset-Mock; Reset-BuildRequired
    $global:T.Nodes["$P^PlcTask^MAIN"].PathName = "$P^OtherTask^MAIN"
    $r = Remove-TcTaskProgram -ProgramName MAIN -DryRun $false
    Check 'Unlink: parent-mismatch -> TREEITEM_DELETE_FAILED, nothing deleted, BUILD_REQUIRED not recorded' ($r.error.code -eq 'TREEITEM_DELETE_FAILED' -and @(Get-Writes | Where-Object { $_ -like 'DeleteChild*' }).Count -eq 0 -and $null -eq (Get-CodeChanged)) "$(J $r.error) | $(Get-CodeChanged)"

    # ===== backup rule: a PLC task node (621) backs up its .TcTTO
    $d = & $mod { param($root, $p) Find-TcTreeItemDiskFile -SolutionDir $root -Path "$p^PlcTask" -Name 'PlcTask' -ItemType 621 } $Root $P
    Check 'disk file rule: 621 -> <task>.TcTTO' (@($d.Files).Count -eq 1 -and $d.Files[0] -like '*PlcTask.TcTTO') (J $d)

    # ===== hints / tools.json
    $codes = @('TASK_ALREADY_EXISTS', 'TASK_NOT_FOUND', 'TASK_PROGRAM_INVALID', 'TASK_PROGRAM_ALREADY_LINKED', 'TASK_PROGRAM_NOT_LINKED', 'TASK_CREATE_FAILED', 'TASK_VERIFY_FAILED')
    $missing = @($codes | Where-Object { [string]::IsNullOrWhiteSpace((& $mod { param($c) Get-TcErrorHint -Code $c } $_)) })
    Check 'hints exist for every new TASK_* code' ($missing.Count -eq 0) ($missing -join ',')
    $tj = Join-Path $PSScriptRoot '..\..\mcp-server\tools.json'
    $tools = @((Get-Content -LiteralPath $tj -Raw -Encoding UTF8 | ConvertFrom-Json).tools)
    $byName = @{}; foreach ($t in $tools) { $byName[$t.name] = $t }
    $t = $byName['AddPlcTask']
    Check 'tools.json AddPlcTask: Add-TcPlcTask, not destructive, Name + CycleTimeUs required, DryRun true' ($null -ne $t -and $t.cmdlet -eq 'Add-TcPlcTask' -and $t.annotations.destructiveHint -eq $false -and @($t.inputSchema.required) -contains 'CycleTimeUs' -and @($t.inputSchema.required) -contains 'Name' -and $t.inputSchema.properties.DryRun.default -eq $true -and $null -eq $t.inputSchema.properties.Priority.default) (J $t.inputSchema)
    $t = $byName['LinkProgramToTask']
    Check 'tools.json LinkProgramToTask: Add-TcTaskProgram, PlcTask default PlcTask, DryRun true' ($null -ne $t -and $t.cmdlet -eq 'Add-TcTaskProgram' -and $t.inputSchema.properties.PlcTask.default -eq 'PlcTask' -and $t.inputSchema.properties.DryRun.default -eq $true) (J $t.inputSchema)
    $t = $byName['UnlinkProgramFromTask']
    Check 'tools.json UnlinkProgramFromTask: Remove-TcTaskProgram, destructive, DryRun true' ($null -ne $t -and $t.cmdlet -eq 'Remove-TcTaskProgram' -and $t.annotations.destructiveHint -eq $true -and $t.inputSchema.properties.DryRun.default -eq $true) (J $t.annotations)
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
