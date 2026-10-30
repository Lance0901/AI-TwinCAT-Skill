# Unit (public cmdlets and MCP tools.json entries): generic tree item tools (complete-automation-interface phase 1, tasks 2.2-2.7):
# Get-TcTreeItem (LookupTreeItem), Get-TcTreeItemXml (ProduceXml), New-TcTreeItem (CreateChild),
# Set-TcTreeItemXml (ConsumeXml), Remove-TcTreeItem (DeleteChild), Export-TcTreeItem (ExportChild),
# Import-TcTreeItem (ImportChild) and the Private/TreeItem helpers. No IDE / runtime: a mock
# ITcSysManager with an in-memory tree replaces Get-TcSysManager; ConsumeXml of the mock merges the
# fragment like XAE did in task 2.1 (or ignores it, to simulate the silent ignore).
#   powershell.exe -NoProfile -File tests/Unit/tree-item-tools.ps1
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

$work = Join-Path $env:TEMP ("tcauto-unit-tree-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path (Join-Path $work 'Plc1') -Force
Set-Content -LiteralPath (Join-Path $work 'Plc1\PlcTask.TcTTO') -Value '<TcTTO CycleTime="2000"/>' -Encoding ASCII
$sln = Join-Path $work 'Test.sln'
Set-Content -LiteralPath $sln -Value '' -Encoding ASCII

$taskXml = '<TreeItem><ItemName>PlcTask</ItemName><PathName>TIRT^PlcTask</PathName><ItemType>19</ItemType><TaskDef><CycleTime>20000</CycleTime><Priority>20</Priority><CPUs><CPU>0</CPU><CPU>1</CPU></CPUs></TaskDef><TcModuleInstance><Module><Context><CycleTime>2000000</CycleTime></Context><ParameterValues><Value>#x1e8480</Value></ParameterValues></Module></TcModuleInstance></TreeItem>'

$global:T = @{}
function New-MockNode([string]$Path, [int]$ItemType = 0, [string]$Xml = '') {
    $name = ($Path -split '\^')[-1]
    if ([string]::IsNullOrEmpty($Xml)) { $Xml = "<TreeItem><ItemName>$name</ItemName><PathName>$Path</PathName></TreeItem>" }
    $n = [PSCustomObject]@{ Name = $name; PathName = $Path; ItemType = $ItemType; ItemSubType = 0; ItemSubTypeName = 'TREEITEMTYPE_MOCK'; Xml = $Xml; Kids = [System.Collections.ArrayList]::new() }
    $n | Add-Member ScriptProperty ChildCount { $this.Kids.Count }
    $n | Add-Member ScriptMethod Child { param($i) $global:T.Nodes[$this.Kids[$i - 1]] }
    $n | Add-Member ScriptMethod ProduceXml {
        param($rec)
        $global:T.Produce.Add("$($this.PathName)|$rec") | Out-Null
        if ($rec -and $null -ne $global:T.ProduceRecThrows) { throw $global:T.ProduceRecThrows }
        $this.Xml
    }
    $n | Add-Member ScriptMethod ConsumeXml {
        param($x)
        $global:T.Mods.Add("ConsumeXml $($this.PathName)") | Out-Null
        switch ($global:T.ConsumeMode) {
            'ignore' { return }
            'throw' { throw [System.Runtime.InteropServices.COMException]::new('No TreeItem found.', -2147467259) }
        }
        $doc = New-Object System.Xml.XmlDocument; $doc.LoadXml($this.Xml)
        $f = New-Object System.Xml.XmlDocument; $f.LoadXml($x)
        foreach ($leaf in $f.SelectNodes('//*[not(*)]')) {
            $names = @(); $p = $leaf
            while ($null -ne $p -and $p -ne $f.DocumentElement) { $names = @($p.Name) + $names; $p = $p.ParentNode }
            $t = $doc.DocumentElement
            foreach ($nm in $names) { if ($null -ne $t) { $t = $t.SelectSingleNode($nm) } }
            if ($null -ne $t) {
                $t.InnerText = $leaf.InnerText
                if (($names -join '/') -eq 'TaskDef/CycleTime') {
                    $ctx = $doc.SelectSingleNode('TreeItem/TcModuleInstance/Module/Context/CycleTime')
                    if ($null -ne $ctx) { $ctx.InnerText = [string]([long]$leaf.InnerText * 100) }
                }
            }
        }
        if ($global:T.ConsumeMode -eq 'sideeffect') { $pr = $doc.SelectSingleNode('TreeItem/TaskDef/Priority'); if ($null -ne $pr) { $pr.InnerText = '99' } }
        $this.Xml = $doc.OuterXml
    }
    $n | Add-Member ScriptMethod CreateChild {
        param($name, $sub, $before, $vinfo)
        $global:T.Mods.Add("CreateChild $($this.PathName)^$name/$sub/$before/$vinfo") | Out-Null
        switch ($global:T.CreateMode) {
            'throw' { throw [System.Runtime.InteropServices.COMException]::new('Not implemented', -2147467263) }
            'loggedin' { throw [System.Runtime.InteropServices.COMException]::new('Cannot add an object because it affects a device you are currently logged into.', -2147467259) }
            'vanish' { return [PSCustomObject]@{ Name = $name; PathName = "$($this.PathName)^$name" } }
        }
        $finalName = if ($global:T.CreateMode -eq 'rename') { "$name (1)" } else { $name }
        if ($global:T.ParentMode -eq 'change') { $this.Xml = $this.Xml.Replace('</ItemName>', 'X</ItemName>') }
        if ($global:T.ParentMode -eq 'add') { $this.Xml = $this.Xml.Replace('</TreeItem>', "<Child>$name</Child></TreeItem>") }
        $c = Add-MockNode "$($this.PathName)^$finalName"
        Write-Output -NoEnumerate $c
    }
    $n | Add-Member ScriptMethod DeleteChild {
        param($name)
        $global:T.Mods.Add("DeleteChild $($this.PathName)^$name") | Out-Null
        if ($global:T.DeleteMode -eq 'noop') { return }
        if ($global:T.DeleteMode -eq 'throw') { throw [System.Runtime.InteropServices.COMException]::new('Access denied', -2147024891) }
        $p = "$($this.PathName)^$name"
        $this.Kids.Remove($p) | Out-Null
        $global:T.Nodes.Remove($p)
    }
    $n | Add-Member ScriptMethod ExportChild {
        param($name, $file)
        $global:T.Exports.Add("$($this.PathName)|$name|$file") | Out-Null
        if ($global:T.ExportMode -eq 'throw') { throw [System.Runtime.InteropServices.COMException]::new('E_INVALIDARG', -2147024809) }
        if ($global:T.ExportMode -eq 'nofile') { return }
        Set-Content -LiteralPath $file -Value "<TreeItem><ItemName>$name</ItemName></TreeItem>" -Encoding ASCII
    }
    $n | Add-Member ScriptMethod ImportChild {
        param($file, $before, $reconnect, $name)
        $global:T.Mods.Add("ImportChild $($this.PathName)|$file|$before|$reconnect|$name") | Out-Null
        if ($global:T.ImportMode -eq 'throw') { throw [System.Runtime.InteropServices.COMException]::new('E_FAIL', -2147467259) }
        $nm = if ([string]::IsNullOrEmpty($name)) { 'Imported' } else { $name }
        if ($global:T.ParentMode -eq 'change') { $this.Xml = $this.Xml.Replace('</ItemName>', 'X</ItemName>') }
        if ($global:T.ParentMode -eq 'add') { $this.Xml = $this.Xml.Replace('</TreeItem>', "<Child>$nm</Child></TreeItem>") }
        $c = Add-MockNode "$($this.PathName)^$nm"
        if ($global:T.ImportMode -eq 'nullreturn') { return $null }
        Write-Output -NoEnumerate $c
    }
    $n
}
function Add-MockNode([string]$Path, [int]$ItemType = 0, [string]$Xml = '') {
    $n = New-MockNode -Path $Path -ItemType $ItemType -Xml $Xml
    $global:T.Nodes[$Path] = $n
    $i = $Path.LastIndexOf('^')
    if ($i -gt 0) { $null = $global:T.Nodes[$Path.Substring(0, $i)].Kids.Add($Path) }
    Write-Output -NoEnumerate $n
}
function Reset-Mock {
    Remove-Item -LiteralPath (Join-Path $work '.tcauto-backup') -Recurse -Force -ErrorAction SilentlyContinue
    $global:T.Nodes = @{}
    $global:T.Mods = [System.Collections.ArrayList]::new()
    $global:T.Exports = [System.Collections.ArrayList]::new()
    $global:T.Lookups = [System.Collections.ArrayList]::new()
    $global:T.ConsumeMode = 'apply'; $global:T.CreateMode = 'ok'; $global:T.DeleteMode = 'ok'; $global:T.ExportMode = 'ok'; $global:T.ImportMode = 'ok'
    $global:T.LookupThrows = $null
    $global:T.Produce = [System.Collections.ArrayList]::new(); $global:T.ProduceRecThrows = $null; $global:T.ParentMode = 'none'; $global:T.Dialog = $null
    foreach ($r in 'TIRT', 'TIPC', 'TIID') { $null = Add-MockNode $r }
    $null = Add-MockNode 'TIRT^PlcTask' 19 $taskXml
    $null = Add-MockNode 'TIPC^P' 56
    $null = Add-MockNode 'TIPC^P^P Project' 600
    $null = Add-MockNode 'TIPC^P^P Project^POUs' 601
    $null = Add-MockNode 'TIPC^P^P Project^POUs^MAIN' 604
    $sm = New-Object PSObject
    $sm | Add-Member ScriptMethod LookupTreeItem {
        param($p)
        $global:T.Lookups.Add($p) | Out-Null
        if ($null -ne $global:T.LookupThrows) { throw $global:T.LookupThrows }
        if (-not $global:T.Nodes.ContainsKey($p)) { throw [System.Runtime.InteropServices.COMException]::new("Item '$p' not found", [int]0x98510001) }
        Write-Output -NoEnumerate $global:T.Nodes[$p]
    }
    $global:T.Sm = $sm
}
Reset-Mock
& $mod {
    $script:TcIdeProcessId = $null
    $script:TcSolutionPath = $args[0]
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) , $global:T.Sm }
    function script:Get-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $global:T.Dialog }
} $sln
function Backups { @(Get-ChildItem -LiteralPath (Join-Path $work '.tcauto-backup') -Recurse -File -ErrorAction SilentlyContinue) }

try {
    # --- 2.3 LookupTreeItem ---
    $res = Get-TcTreeItem -Path 'TIRT'
    Check 'lookup-ok' ($res.success -and $res.data.childCount -eq 1 -and $res.data.children[0].name -eq 'PlcTask' -and $res.data.children[0].path -eq 'TIRT^PlcTask') ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = Get-TcTreeItem -Path 'TIPC^P^P Project^POUs^MAIN'
    Check 'lookup-type-name' ($res.success -and $res.data.type -eq 'Program' -and $res.data.itemType -eq 604) ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = Get-TcTreeItem -Path 'TIRT^NoSuchTask'
    Check 'lookup-not-found-code' (-not $res.success -and $res.error.code -eq 'TREEITEM_NOT_FOUND') ($res | ConvertTo-Json -Depth 5 -Compress)
    Check 'lookup-not-found-hint-nearest' ($res.error.hint -match "nearest existing parent is 'TIRT'" -and $res.error.hint -match "'PlcTask'" -and $res.data.nearestPath -eq 'TIRT' -and @($res.data.nearestChildren) -contains 'PlcTask') $res.error.hint
    $res = Get-TcTreeItem -Path 'TIPC^P^P Project^POUs^Nope^Deeper'
    Check 'lookup-not-found-deep' ($res.data.nearestPath -eq 'TIPC^P^P Project^POUs' -and @($res.data.nearestChildren) -contains 'MAIN' -and $res.error.hint -match "'Nope'") $res.error.hint
    $res = Get-TcTreeItem -Path 'XXXX^Y'
    Check 'lookup-not-found-root' ($null -eq $res.data.nearestPath -and @($res.data.nearestChildren) -contains 'TIRT' -and @($res.data.nearestChildren) -notcontains 'TINC' -and $res.error.hint -match 'first segment') $res.error.hint
    $global:T.Lookups.Clear()
    $res = Get-TcTreeItem -Path 'TIRT^*'
    Check 'lookup-wildcard' ($res.error.code -eq 'TREEITEM_PATH_INVALID' -and $global:T.Lookups.Count -eq 0) "lookups=$($global:T.Lookups.Count) $($res.error.code)"
    $global:T.LookupThrows = 'IDE_BUSY: ''LookupTreeItem TIRT'' failed after 5 attempts (mock)'
    $res = Get-TcTreeItem -Path 'TIRT'
    Check 'lookup-ide-busy' ($res.error.code -eq 'IDE_BUSY') ($res | ConvertTo-Json -Depth 5 -Compress)
    $global:T.LookupThrows = $null

    # --- 2.3 ProduceXml ---
    $res = Get-TcTreeItemXml -Path 'TIRT^PlcTask'
    Check 'producexml-ok' ($res.success -and $res.data.xml -eq $taskXml -and $res.data.length -eq $taskXml.Length) ($res.data | ConvertTo-Json -Compress)
    $res = Get-TcTreeItemXml -Path 'TIRT^Missing'
    Check 'producexml-not-found' ($res.error.code -eq 'TREEITEM_NOT_FOUND' -and $res.error.hint -match 'PlcTask') $res.error.hint

    # --- 2.4 ConsumeXml ---
    $frag = '<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>'
    Reset-Mock
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag
    $ch = @($res.data.changes)
    Check 'consume-dryrun-default' ($res.success -and $res.data.dryRun -eq $true -and $res.data.changedCount -eq 1 -and $ch[0].current -eq '20000' -and $ch[0].planned -eq '40000' -and $ch[0].changed) ($res | ConvertTo-Json -Depth 6 -Compress)
    Check 'consume-dryrun-no-write' ($global:T.Mods.Count -eq 0 -and $global:T.Nodes['TIRT^PlcTask'].Xml -eq $taskXml -and (Backups).Count -eq 0 -and $res.data.currentXml -eq $taskXml) ($global:T.Mods -join ';')
    $after = Get-TcTreeItemXml -Path 'TIRT^PlcTask'
    Check 'consume-dryrun-producexml-unchanged' ($after.data.xml -eq $taskXml) ''

    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag -DryRun $false
    Check 'consume-write-verified' ($res.success -and $res.data.verified -eq $true -and $res.data.written -eq $true -and $res.data.dryRun -eq $false) ($res | ConvertTo-Json -Depth 6 -Compress)
    Check 'consume-write-backup' ((Test-Path -LiteralPath $res.data.backupPath) -and (Get-Content -LiteralPath $res.data.backupPath -Raw) -eq $taskXml -and $res.data.backupPath -like (Join-Path $work '.tcauto-backup\*\TIRT_PlcTask.xml')) "$($res.data.backupPath)"
    Check 'consume-write-backup-tctto' (@($res.data.backupFiles).Count -eq 1 -and $res.data.backupFiles[0] -like '*TIRT_PlcTask.PlcTask.TcTTO' -and (Test-Path -LiteralPath $res.data.backupFiles[0])) (@($res.data.backupFiles) -join ' | ')
    $nx = [xml]$global:T.Nodes['TIRT^PlcTask'].Xml
    Check 'consume-one-field-others-kept' ($nx.TreeItem.TaskDef.CycleTime -eq '40000' -and $nx.TreeItem.TaskDef.Priority -eq '20' -and @($nx.TreeItem.TaskDef.CPUs.CPU).Count -eq 2) $global:T.Nodes['TIRT^PlcTask'].Xml
    Check 'consume-derived-ignored' ($nx.TreeItem.TcModuleInstance.Module.Context.CycleTime -eq '4000000') ''
    Check 'consume-no-buildrequired-outside-tipc' ($null -eq $res.data.PSObject.Properties['buildRequired']) ''

    Reset-Mock
    $global:T.ConsumeMode = 'ignore'
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag -DryRun $false
    $m = @($res.data.mismatches)
    Check 'consume-ignored-verify-failed' (-not $res.success -and $res.error.code -eq 'TREEITEM_VERIFY_FAILED' -and $m.Count -eq 1 -and $m[0].expected -eq '40000' -and $m[0].actual -eq '20000' -and $res.data.verified -eq $false) ($res | ConvertTo-Json -Depth 6 -Compress)
    Check 'consume-ignored-has-backup' (Test-Path -LiteralPath $res.data.backupPath) "$($res.data.backupPath)"

    Reset-Mock
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><NoSuchElement>1</NoSuchElement></TaskDef></TreeItem>' -DryRun $false
    Check 'consume-unknown-element-merge-failed' ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'paths-not-in-current-xml' -and @($res.data.missingPaths) -contains 'TreeItem/TaskDef/NoSuchElement' -and $global:T.Mods.Count -eq 0) ($res | ConvertTo-Json -Depth 6 -Compress)
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<NotTreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></NotTreeItem>' -DryRun $false
    Check 'consume-bad-root' ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'root' -and $global:T.Mods.Count -eq 0) $res.error.message
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><CycleTime>40000</TaskDef>' -DryRun $false
    Check 'consume-syntax' ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'syntax' -and $global:T.Mods.Count -eq 0) $res.error.message
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><CycleTime>0</CycleTime></TaskDef></TreeItem>' -DryRun $false
    Check 'consume-invalid-value' ($res.error.code -eq 'TREEITEM_INVALID_VALUE' -and $res.data.invalidFields[0].path -eq 'TreeItem/TaskDef/CycleTime' -and $global:T.Mods.Count -eq 0 -and (Backups).Count -eq 0) ($res | ConvertTo-Json -Depth 6 -Compress)
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTa*' -Xml $frag -DryRun $false
    Check 'consume-wildcard' ($res.error.code -eq 'TREEITEM_PATH_INVALID' -and $global:T.Mods.Count -eq 0) $res.error.message
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><CycleTime>20000</CycleTime></TaskDef></TreeItem>' -DryRun $false
    Check 'consume-nothing-to-change' ($res.success -and $res.data.written -eq $false -and $global:T.Mods.Count -eq 0 -and (Backups).Count -eq 0) ($res | ConvertTo-Json -Depth 6 -Compress)
    $global:T.ConsumeMode = 'throw'
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag -DryRun $false
    Check 'consume-xae-error' ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.written -eq $false -and (Test-Path -LiteralPath $res.data.backupPath)) ($res | ConvertTo-Json -Depth 6 -Compress)
    $global:T.ConsumeMode = 'apply'
    & $mod { $script:TcSolutionPath = $null; $script:TcDte = $null }
    $global:T.Mods.Clear()
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag -DryRun $false
    Check 'consume-no-solution-backup-failed' ($res.error.code -eq 'TREEITEM_BACKUP_FAILED' -and $global:T.Mods.Count -eq 0) ($res | ConvertTo-Json -Depth 6 -Compress)
    & $mod { $script:TcSolutionPath = $args[0] } $sln

    # --- 2.4 CreateChild ---
    Reset-Mock
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task 2' -SubType 1
    Check 'create-dryrun-default' ($res.success -and $res.data.dryRun -eq $true -and $res.data.plannedPath -eq 'TIRT^Task 2' -and @($res.data.currentChildren) -contains 'PlcTask' -and $global:T.Mods.Count -eq 0) ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task 2' -SubType 1 -DryRun $false
    Check 'create-ok' ($res.success -and $res.data.verified -and $res.data.createdPath -eq 'TIRT^Task 2' -and $global:T.Nodes.ContainsKey('TIRT^Task 2') -and $global:T.Mods[0] -eq 'CreateChild TIRT^Task 2/1//') ($res | ConvertTo-Json -Depth 5 -Compress)
    Check 'create-backup-parent' ($res.data.backupPath -like '*TIRT.parent.xml' -and (Test-Path -LiteralPath $res.data.backupPath)) "$($res.data.backupPath)"
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task 2' -SubType 1 -DryRun $false
    Check 'create-already-exists' ($res.error.code -eq 'TREEITEM_ALREADY_EXISTS' -and $global:T.Mods.Count -eq 1) $res.error.message
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task 3' -Before 'Nope' -DryRun $false
    Check 'create-before-missing' ($res.error.code -eq 'TREEITEM_NOT_FOUND' -and $res.error.hint -match 'PlcTask' -and $global:T.Mods.Count -eq 1) $res.error.hint
    $res = New-TcTreeItem -Path 'TIRT^Missing' -Name 'X' -DryRun $false
    Check 'create-parent-missing' ($res.error.code -eq 'TREEITEM_NOT_FOUND' -and $res.data.nearestPath -eq 'TIRT') $res.error.hint
    $res = New-TcTreeItem -Path 'TIRT' -Name 'A^B'
    Check 'create-bad-name' ($res.error.code -eq 'INVALID_PARAMS') $res.error.message
    $global:T.CreateMode = 'throw'
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task 4' -DryRun $false
    Check 'create-xae-refused' ($res.error.code -eq 'TREEITEM_CREATE_FAILED' -and $res.error.hint -match 'E_NOTIMPL') ($res | ConvertTo-Json -Depth 5 -Compress)
    $global:T.CreateMode = 'vanish'
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task 5' -DryRun $false
    Check 'create-vanish-verify-failed' ($res.error.code -eq 'TREEITEM_VERIFY_FAILED' -and $res.data.verified -eq $false) ($res | ConvertTo-Json -Depth 5 -Compress)
    $global:T.CreateMode = 'rename'
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task 6' -DryRun $false
    Check 'create-renamed-warning' ($res.success -and $res.data.createdName -eq 'Task 6 (1)' -and (@($res.data.warnings) -join ' ') -match "named the new child") ($res | ConvertTo-Json -Depth 5 -Compress)
    $global:T.CreateMode = 'ok'
    $res = New-TcTreeItem -Path 'TIPC^P^P Project^POUs' -Name 'FB_X' -SubType 602 -DryRun $false
    Check 'create-tipc-build-required' ($res.success -and -not [string]::IsNullOrEmpty([string]$res.data.buildRequired)) ($res | ConvertTo-Json -Depth 5 -Compress)

    # --- 2.5 DeleteChild ---
    Reset-Mock
    $null = Add-MockNode 'TIRT^Task 2' 19
    $res = Remove-TcTreeItem -Path 'TIRT^Task 2' -ConfirmName 'Task 3' -DryRun $false
    Check 'delete-name-mismatch' ($res.error.code -eq 'TREEITEM_DELETE_NAME_MISMATCH' -and $res.data.nodeName -eq 'Task 2' -and $global:T.Mods.Count -eq 0 -and $global:T.Nodes.ContainsKey('TIRT^Task 2') -and (Backups).Count -eq 0) ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = Remove-TcTreeItem -Path 'TIRT^Task 2' -ConfirmName 'task 2' -DryRun $false
    Check 'delete-name-case' ($res.error.code -eq 'TREEITEM_DELETE_NAME_MISMATCH' -and $global:T.Mods.Count -eq 0) $res.error.message
    $res = Remove-TcTreeItem -Path 'TIRT^Task 2' -ConfirmName '' -DryRun $false
    Check 'delete-name-empty' ($res.error.code -eq 'TREEITEM_DELETE_NAME_MISMATCH' -and $global:T.Mods.Count -eq 0) $res.error.message
    $global:T.Lookups.Clear()
    $res = Remove-TcTreeItem -Path 'TIRT^Task*' -ConfirmName 'Task 2' -DryRun $false
    Check 'delete-wildcard' ($res.error.code -eq 'TREEITEM_PATH_INVALID' -and $global:T.Mods.Count -eq 0 -and $global:T.Lookups.Count -eq 0) $res.error.message
    $res = Remove-TcTreeItem -Path 'TIRT' -ConfirmName 'TIRT' -DryRun $false
    Check 'delete-top-level' ($res.error.code -eq 'TREEITEM_PATH_INVALID' -and $global:T.Mods.Count -eq 0) $res.error.message
    $res = Remove-TcTreeItem -Path 'TIRT^Task 9' -ConfirmName 'Task 9' -DryRun $false
    Check 'delete-not-found' ($res.error.code -eq 'TREEITEM_NOT_FOUND' -and $res.error.hint -match 'Task 2') $res.error.hint
    $res = Remove-TcTreeItem -Path 'TIRT^Task 2' -ConfirmName 'Task 2'
    Check 'delete-dryrun-default' ($res.success -and $res.data.dryRun -eq $true -and $res.data.nodeName -eq 'Task 2' -and $global:T.Mods.Count -eq 0 -and $global:T.Nodes.ContainsKey('TIRT^Task 2')) ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = Remove-TcTreeItem -Path 'TIRT^Task 2' -ConfirmName 'Task 2' -DryRun $false
    Check 'delete-ok' ($res.success -and $res.data.verified -and -not $global:T.Nodes.ContainsKey('TIRT^Task 2') -and $global:T.Mods[0] -eq 'DeleteChild TIRT^Task 2') ($res | ConvertTo-Json -Depth 5 -Compress)
    Check 'delete-backup-xml-and-xti' ((Test-Path -LiteralPath $res.data.backupPath) -and $res.data.exportPath -like '*TIRT_Task 2.xti' -and (Test-Path -LiteralPath $res.data.exportPath) -and $global:T.Exports[0] -like 'TIRT|Task 2|*') "$($res.data.backupPath) $($res.data.exportPath)"
    Check 'delete-task-no-tctto-warning' ((@($res.data.warnings) -join ' ') -match 'Task 2.TcTTO') (@($res.data.warnings) -join ' | ')
    $null = Add-MockNode 'TIRT^Task 3' 19
    $global:T.DeleteMode = 'noop'
    $res = Remove-TcTreeItem -Path 'TIRT^Task 3' -ConfirmName 'Task 3' -DryRun $false
    Check 'delete-still-exists-verify-failed' ($res.error.code -eq 'TREEITEM_VERIFY_FAILED' -and $res.data.verified -eq $false) ($res | ConvertTo-Json -Depth 5 -Compress)
    $global:T.DeleteMode = 'throw'
    $res = Remove-TcTreeItem -Path 'TIRT^Task 3' -ConfirmName 'Task 3' -DryRun $false
    Check 'delete-xae-refused' ($res.error.code -eq 'TREEITEM_DELETE_FAILED' -and (Test-Path -LiteralPath $res.data.exportPath)) ($res | ConvertTo-Json -Depth 5 -Compress)

    # --- 2.6 ExportChild / ImportChild ---
    Reset-Mock
    $xti = Join-Path $work 'PlcTask.xti'
    $res = Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath $xti
    Check 'export-ok' ($res.success -and $res.data.exported -and $res.data.fileSize -gt 0 -and $global:T.Exports[0] -eq "TIRT|PlcTask|$xti") ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath $xti
    Check 'export-file-exists' ($res.error.code -eq 'TREEITEM_EXPORT_FAILED' -and $res.data.reason -eq 'file-exists' -and $global:T.Exports.Count -eq 1) $res.error.message
    $res = Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath (Join-Path $work 'nodir\x.xti')
    Check 'export-folder-missing' ($res.data.reason -eq 'folder-missing') $res.error.message
    $res = Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath 'rel.xti'
    Check 'export-relative' ($res.data.reason -eq 'not-absolute') $res.error.message
    $global:T.ExportMode = 'nofile'
    $res = Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath (Join-Path $work 'none.xti')
    Check 'export-not-written' ($res.error.code -eq 'TREEITEM_EXPORT_FAILED' -and $res.data.reason -eq 'file-not-written') $res.error.message
    $global:T.ExportMode = 'ok'
    $res = Export-TcTreeItem -Path 'TIRT' -FilePath (Join-Path $work 'tirt.xti')
    Check 'export-top-level-empty-name' ($res.success -and $global:T.Exports[-1] -like 'TIRT||*') ($global:T.Exports -join ';')

    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti -Name 'PlcTask Copy'
    Check 'import-dryrun-default' ($res.success -and $res.data.dryRun -eq $true -and $global:T.Mods.Count -eq 0 -and -not $global:T.Nodes.ContainsKey('TIRT^PlcTask Copy')) ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti -Name 'PlcTask Copy' -DryRun $false
    Check 'import-ok' ($res.success -and $res.data.verified -and $res.data.importedPath -eq 'TIRT^PlcTask Copy' -and $global:T.Mods[0] -eq "ImportChild TIRT|$xti||True|PlcTask Copy" -and (Test-Path -LiteralPath $res.data.backupPath)) ($res | ConvertTo-Json -Depth 5 -Compress)
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti -Name 'PlcTask Copy' -DryRun $false
    Check 'import-name-exists' ($res.error.code -eq 'TREEITEM_ALREADY_EXISTS' -and $global:T.Mods.Count -eq 1) $res.error.message
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath (Join-Path $work 'missing.xti') -DryRun $false
    Check 'import-file-missing' ($res.error.code -eq 'TREEITEM_IMPORT_FAILED' -and $res.data.reason -eq 'file-missing' -and $global:T.Mods.Count -eq 1) $res.error.message
    $global:T.ImportMode = 'nullreturn'
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti -DryRun $false -Reconnect $false
    Check 'import-new-child-detected' ($res.success -and $res.data.importedPath -eq 'TIRT^Imported' -and $global:T.Mods[-1] -like '*|False|') ($res | ConvertTo-Json -Depth 5 -Compress)
    $global:T.ImportMode = 'throw'
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti -Name 'Another' -DryRun $false
    Check 'import-xae-refused' ($res.error.code -eq 'TREEITEM_IMPORT_FAILED') $res.error.message

    # === code review of tasks 2.2-2.7 (one block per review item) ===
    function Json($o) { $o | ConvertTo-Json -Depth 6 -Compress }
    # 1. structure mismatch: refused before anything is sent
    Reset-Mock
    $i = 0
    foreach ($x in '<TreeItem><TaskDef/></TreeItem>', '<TreeItem><TaskDef>123</TaskDef></TreeItem>', '<TreeItem><TaskDef>123<CycleTime>40000</CycleTime></TaskDef></TreeItem>') {
        $i++
        $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $x -DryRun $false
        Check "review1-structure-mismatch-$i" ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'structure-mismatch' -and @($res.data.structurePaths) -contains 'TreeItem/TaskDef' -and $global:T.Mods.Count -eq 0 -and (Backups).Count -eq 0 -and $global:T.Nodes['TIRT^PlcTask'].Xml -eq $taskXml) (Json $res)
    }
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef/></TreeItem>'
    Check 'review1-structure-mismatch-dryrun' ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'structure-mismatch') (Json $res)

    # 2. derived fields only: refused (nothing could be read back)
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TcModuleInstance><Module><Context><CycleTime>5</CycleTime></Context></Module></TcModuleInstance></TreeItem>' -DryRun $false
    Check 'review2-derived-only' ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'derived-only' -and @($res.data.derivedPaths) -contains 'TreeItem/TcModuleInstance/Module/Context/CycleTime' -and $global:T.Mods.Count -eq 0 -and (Backups).Count -eq 0 -and $res.error.hint -match 'TaskDef/CycleTime') (Json $res)
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef><TcModuleInstance><Module><Context><CycleTime>4000000</CycleTime></Context></Module></TcModuleInstance></TreeItem>' -DryRun $false
    Check 'review2-derived-with-source-ok' ($res.success -and $res.data.verified -and (@($res.data.warnings) -join ' ') -match 'not read back' -and @($res.data.skippedDerived).Count -eq 1) (Json $res)

    # 3a. repeated element count differs: refused
    Reset-Mock
    foreach ($x in '<TreeItem><TaskDef><CPUs><CPU>5</CPU></CPUs></TaskDef></TreeItem>', '<TreeItem><TaskDef><CPUs><CPU>5</CPU><CPU>6</CPU><CPU>7</CPU></CPUs></TaskDef></TreeItem>') {
        $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $x -DryRun $false
        $rc = @($res.data.repeatedCountMismatches)
        Check "review3a-repeated-count-$(([xml]$x).TreeItem.TaskDef.CPUs.CPU.Count)" ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'repeated-count-mismatch' -and $rc.Count -eq 1 -and $rc[0].currentCount -eq 2 -and $global:T.Mods.Count -eq 0) (Json $res)
    }
    # same count: accepted (dry-run; the mock's merge does not handle repeated elements)
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><CPUs><CPU>0</CPU><CPU>3</CPU></CPUs></TaskDef></TreeItem>'
    Check 'review3a-repeated-same-count-ok' ($res.success -and $res.data.changedCount -eq 1 -and @($res.data.changes | Where-Object { $_.changed })[0].path -eq 'TreeItem/TaskDef/CPUs/CPU[2]') (Json $res)

    # 3b. whole-XML check after the write: a field outside the fragment changed
    Reset-Mock
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag -DryRun $false
    Check 'review3b-clean-write-no-unexpected' ($res.success -and $null -eq $res.data.PSObject.Properties['unexpectedChanges']) (Json $res)
    Reset-Mock
    $global:T.ConsumeMode = 'sideeffect'
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag -DryRun $false
    $u = @($res.data.unexpectedChanges)
    Check 'review3b-side-effect-verify-failed' (-not $res.success -and $res.error.code -eq 'TREEITEM_VERIFY_FAILED' -and $res.data.verified -eq $false -and $u.Count -eq 1 -and $u[0].path -eq 'TreeItem/TaskDef/Priority' -and $u[0].kind -eq 'changed' -and $u[0].before -eq '20' -and $u[0].after -eq '99' -and $null -eq $res.data.PSObject.Properties['mismatches']) (Json $res)
    Reset-Mock
    $global:T.ParentMode = 'change'
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task P' -DryRun $false
    Check 'review3b-create-parent-changed' ($res.error.code -eq 'TREEITEM_VERIFY_FAILED' -and $res.data.parentUnchanged -eq $false -and $res.data.verified -eq $false -and @($res.data.unexpectedChanges)[0].path -eq 'TreeItem/ItemName' -and $global:T.Nodes.ContainsKey('TIRT^Task P')) (Json $res)
    $global:T.ParentMode = 'add'
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task Q' -DryRun $false
    Check 'review3b-create-parent-addition-ok' ($res.success -and $res.data.verified -and $res.data.parentUnchanged -eq $true) (Json $res)
    $xti = Join-Path $work 'review.xti'
    Set-Content -LiteralPath $xti -Value '<TreeItem/>' -Encoding ASCII
    $global:T.ParentMode = 'change'
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti -Name 'Imp P' -DryRun $false
    Check 'review3b-import-parent-changed' ($res.error.code -eq 'TREEITEM_VERIFY_FAILED' -and $res.data.parentUnchanged -eq $false -and @($res.data.unexpectedChanges).Count -ge 1) (Json $res)
    $global:T.ParentMode = 'add'
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti -Name 'Imp Q' -DryRun $false
    Check 'review3b-import-parent-addition-ok' ($res.success -and $res.data.parentUnchanged -eq $true) (Json $res)

    # 4. attributes: refused, hint says only element values are supported
    Reset-Mock
    $res = Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml '<TreeItem><TaskDef><CycleTime unit="100ns">40000</CycleTime></TaskDef></TreeItem>' -DryRun $false
    Check 'review4-attributes-not-supported' ($res.error.code -eq 'XML_MERGE_FAILED' -and $res.data.reason -eq 'attributes-not-supported' -and @($res.data.attributePaths) -contains 'TreeItem/TaskDef/CycleTime/@unit' -and $res.error.hint -match 'element' -and $global:T.Mods.Count -eq 0) (Json $res)

    # 5. DeleteChild backup: export required, -AllowNoExport, recursive ProduceXml
    Reset-Mock
    $null = Add-MockNode 'TIRT^Task 5' 19
    $global:T.ExportMode = 'throw'
    $res = Remove-TcTreeItem -Path 'TIRT^Task 5' -ConfirmName 'Task 5' -DryRun $false
    Check 'review5-export-failed-no-delete' ($res.error.code -eq 'TREEITEM_BACKUP_FAILED' -and $res.data.reason -eq 'export-failed' -and $global:T.Nodes.ContainsKey('TIRT^Task 5') -and @($global:T.Mods | Where-Object { $_ -like 'DeleteChild*' }).Count -eq 0) (Json $res)
    $global:T.ExportMode = 'nofile'
    $res = Remove-TcTreeItem -Path 'TIRT^Task 5' -ConfirmName 'Task 5' -DryRun $false
    Check 'review5-export-missing-no-delete' ($res.error.code -eq 'TREEITEM_BACKUP_FAILED' -and $res.data.reason -eq 'export-missing' -and $global:T.Nodes.ContainsKey('TIRT^Task 5') -and $global:T.Mods.Count -eq 0) (Json $res)
    $global:T.ExportMode = 'throw'
    $global:T.Produce.Clear()
    $res = Remove-TcTreeItem -Path 'TIRT^Task 5' -ConfirmName 'Task 5' -DryRun $false -AllowNoExport
    Check 'review5-allow-no-export-deletes-with-warning' ($res.success -and $res.data.verified -and -not $global:T.Nodes.ContainsKey('TIRT^Task 5') -and (@($res.data.warnings) -join ' ') -match 'AllowNoExport' -and $res.data.allowNoExport -eq $true) (Json $res)
    Check 'review5-backup-recursive' (@($global:T.Produce) -contains 'TIRT^Task 5|True') (@($global:T.Produce) -join ';')

    # 6. invalid file paths: TREEITEM_EXPORT_FAILED / TREEITEM_IMPORT_FAILED invalid-path, no EXECUTION_ERROR
    Reset-Mock
    foreach ($p in 'C:\', 'C:\a<b.xti', 'C:\a|b.xti') {
        $res = Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath $p
        Check "review6-export-invalid-path-$p" ($res.error.code -eq 'TREEITEM_EXPORT_FAILED' -and $res.data.reason -eq 'invalid-path' -and $global:T.Exports.Count -eq 0) (Json $res)
        $res = Import-TcTreeItem -Path 'TIRT' -FilePath $p -DryRun $false
        Check "review6-import-invalid-path-$p" ($res.error.code -eq 'TREEITEM_IMPORT_FAILED' -and $res.data.reason -eq 'invalid-path' -and $global:T.Mods.Count -eq 0) (Json $res)
    }

    # 7. a modal dialog is checked right before every synchronous modifying COM call
    Reset-Mock
    $null = Add-MockNode 'TIRT^Task 7' 19
    $global:T.Dialog = @{ Title = 'Mock dialog'; Text = 'Mock text'; Kind = 'unknown'; ReloadTarget = $null; Hwnd = 0; Buttons = @() }
    $xti7 = Join-Path $work 'review7.xti'
    Set-Content -LiteralPath $xti7 -Value '<TreeItem/>' -Encoding ASCII
    $r7 = @(
        @('consume', (Set-TcTreeItemXml -Path 'TIRT^PlcTask' -Xml $frag -DryRun $false)),
        @('create', (New-TcTreeItem -Path 'TIRT' -Name 'Task D' -DryRun $false)),
        @('delete', (Remove-TcTreeItem -Path 'TIRT^Task 7' -ConfirmName 'Task 7' -DryRun $false)),
        @('export', (Export-TcTreeItem -Path 'TIRT^PlcTask' -FilePath (Join-Path $work 'review7-out.xti'))),
        @('import', (Import-TcTreeItem -Path 'TIRT' -FilePath $xti7 -Name 'Imp D' -DryRun $false)))
    foreach ($c in $r7) { Check "review7-dialog-before-$($c[0])" ($c[1].error.code -eq 'IDE_MODAL_DIALOG') (Json $c[1]) }
    Check 'review7-dialog-nothing-called' ($global:T.Mods.Count -eq 0 -and $global:T.Exports.Count -eq 0 -and $global:T.Nodes.ContainsKey('TIRT^Task 7') -and $global:T.Nodes['TIRT^PlcTask'].Xml -eq $taskXml) "mods=$($global:T.Mods -join ';') exports=$($global:T.Exports -join ';')"
    $global:T.Dialog = $null
    $comments = @('Set-TcTreeItemXml', 'New-TcTreeItem', 'Remove-TcTreeItem', 'Export-TcTreeItem', 'Import-TcTreeItem') | ForEach-Object {
        $src = Get-Content -LiteralPath (Join-Path $PSScriptRoot "..\..\src\TwinCATAutomation\Public\$_.ps1") -Raw
        [regex]::Matches($src, 'No deadline \(CODING_STANDARDS\.md section 1\)').Count
    }
    Check 'review7-no-deadline-comment-per-call' ($comments[0] -ge 1 -and $comments[1] -ge 1 -and $comments[2] -ge 2 -and $comments[3] -ge 1 -and $comments[4] -ge 1) ($comments -join ',')

    # 8. PLC_LOGGED_IN: hint = PlcLogout, then rerun the same tool (named)
    Reset-Mock
    $global:T.CreateMode = 'loggedin'
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task L' -DryRun $false
    Check 'review8-plc-logged-in-hint' ($res.error.code -eq 'PLC_LOGGED_IN' -and $res.error.hint -match 'PlcLogout' -and $res.error.hint.Contains("CreateChild 'TIRT^Task L'") -and $res.error.hint -notmatch 'AddPou') (Json $res)
    $global:T.CreateMode = 'ok'
    # extra: the backup step rethrows PLC_LOGGED_IN (same pass-through list) instead of TREEITEM_BACKUP_FAILED
    $null = Add-MockNode 'TIRT^Task 8' 19
    $global:T.Mods.Clear()
    $global:T.ProduceRecThrows = 'Cannot add an object because it affects a device you are currently logged into.'
    $res = Remove-TcTreeItem -Path 'TIRT^Task 8' -ConfirmName 'Task 8' -DryRun $false
    Check 'review-extra-backup-passthrough-plc-logged-in' ($res.error.code -eq 'PLC_LOGGED_IN' -and $res.error.hint -match 'PlcLogout' -and $global:T.Nodes.ContainsKey('TIRT^Task 8') -and $global:T.Mods.Count -eq 0) (Json $res)
    $global:T.ProduceRecThrows = $null

    # 9. value comparison: see tree-item-helpers.ps1 value-equal-*; here a case-only change is a real change
    Reset-Mock
    $null = Add-MockNode 'TIRT^Named' 19 '<TreeItem><ItemName>Named</ItemName><TaskDef><Comment>abc</Comment></TaskDef></TreeItem>'
    $res = Set-TcTreeItemXml -Path 'TIRT^Named' -Xml '<TreeItem><TaskDef><Comment>ABC</Comment></TaskDef></TreeItem>'
    Check 'review9-case-change-counts' ($res.success -and $res.data.changedCount -eq 1) (Json $res)

    # 10. -Before beyond the truncated child list is looked up directly
    Reset-Mock
    $null = Add-MockNode 'TIRT^Second' 19
    & $mod { $script:TcTreeItemMaxChildNames = 1 }
    $res = New-TcTreeItem -Path 'TIRT' -Name 'Task B' -Before 'Second'
    Check 'review10-create-before-beyond-list' ($res.success -and @($res.data.currentChildren) -notcontains 'Second') (Json $res)
    $xti10 = Join-Path $work 'review10.xti'
    Set-Content -LiteralPath $xti10 -Value '<TreeItem/>' -Encoding ASCII
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti10 -Before 'Second'
    Check 'review10-import-before-beyond-list' ($res.success) (Json $res)
    $res = Import-TcTreeItem -Path 'TIRT' -FilePath $xti10 -Before 'Nope'
    Check 'review10-import-before-missing' ($res.error.code -eq 'TREEITEM_NOT_FOUND') (Json $res)
    & $mod { $script:TcTreeItemMaxChildNames = 200 }

    # extra: DeleteChild checks the item's own parent against the parent derived from -Path
    Reset-Mock
    $odd = Add-MockNode 'TIRT^Odd' 19
    $odd.PathName = 'TIID^Odd'
    $res = Remove-TcTreeItem -Path 'TIRT^Odd' -ConfirmName 'Odd'
    Check 'review-extra-parent-mismatch-dryrun' ($res.error.code -eq 'TREEITEM_DELETE_FAILED' -and $res.data.reason -eq 'parent-mismatch' -and $res.data.itemParentPath -eq 'TIID') (Json $res)
    $res = Remove-TcTreeItem -Path 'TIRT^Odd' -ConfirmName 'Odd' -DryRun $false
    Check 'review-extra-parent-mismatch-no-delete' ($res.data.reason -eq 'parent-mismatch' -and $global:T.Mods.Count -eq 0 -and $global:T.Exports.Count -eq 0 -and (Backups).Count -eq 0) (Json $res)

    # 11. documentation: cmdlet counts, new reasons and AllowNoExport documented
    $exported = @($mod.ExportedCommands.Keys).Count
    $root = Join-Path $PSScriptRoot '..\..'
    $readme = Get-Content -LiteralPath (Join-Path $root 'README.md') -Raw -Encoding UTF8
    $readmeZh = Get-Content -LiteralPath (Join-Path $root 'README.zh-TW.md') -Raw -Encoding UTF8
    $nums = @()
    foreach ($m in [regex]::Matches($readme, 'providing (\d+) cmdlets|# (\d+) exported cmdlets')) { $nums += [int]("$($m.Groups[1].Value)$($m.Groups[2].Value)") }
    foreach ($m in [regex]::Matches($readmeZh, '(\d+)\s*[^\x00-\x7F]+\s*cmdlet')) { $nums += [int]$m.Groups[1].Value }
    Check 'review11-readme-cmdlet-counts' ($nums.Count -ge 5 -and @($nums | Where-Object { $_ -ne $exported }).Count -eq 0) "exported=$exported found=$($nums -join ',')"
    $ts = Get-Content -LiteralPath (Join-Path $root 'docs\troubleshooting.md') -Raw -Encoding UTF8
    $missingDoc = @('structure-mismatch', 'derived-only', 'repeated-count-mismatch', 'attributes-not-supported', 'invalid-path', 'export-failed', 'export-missing', 'parent-mismatch', 'AllowNoExport', 'unexpectedChanges') | Where-Object { -not $ts.Contains($_) }
    Check 'review11-troubleshooting-documents-new-reasons' ($missingDoc.Count -eq 0) ($missingDoc -join ', ')
    $helpText = [string](Get-Help Remove-TcTreeItem -Parameter AllowNoExport | Out-String)
    Check 'review11-cmdlet-help-allownoexport' ($helpText -match 'ExportChild') $helpText
    $toolsJson = (Get-Content -LiteralPath (Join-Path $root 'mcp-server\tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tools
    $delTool = @($toolsJson | Where-Object { $_.name -eq 'DeleteChild' })[0]
    Check 'review11-tools-json-allownoexport' ($delTool.inputSchema.properties.AllowNoExport.type -eq 'boolean' -and $delTool.description -match 'AllowNoExport') (Json $delTool.inputSchema.properties.AllowNoExport)

    # --- 2.7 hint table and tools.json ---
    $codes = 'TREEITEM_NOT_FOUND', 'TREEITEM_PATH_INVALID', 'TREEITEM_READ_FAILED', 'TREEITEM_ALREADY_EXISTS', 'TREEITEM_CREATE_FAILED', 'TREEITEM_VERIFY_FAILED',
        'TREEITEM_DELETE_NAME_MISMATCH', 'TREEITEM_DELETE_FAILED', 'TREEITEM_INVALID_VALUE', 'TREEITEM_BACKUP_FAILED', 'TREEITEM_EXPORT_FAILED', 'TREEITEM_IMPORT_FAILED', 'XML_MERGE_FAILED'
    $missingHints = @(& $mod { param($c) $c | Where-Object { [string]::IsNullOrWhiteSpace((Get-TcErrorHint -Code $_)) } } $codes)
    Check 'hints-present' ($missingHints.Count -eq 0) ($missingHints -join ', ')
    $tools = (Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\mcp-server\tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json).tools
    $want = @{ LookupTreeItem = 'ro'; ProduceXml = 'ro'; CreateChild = 'destructive'; ConsumeXml = 'destructive'; DeleteChild = 'destructive'; ImportChild = 'destructive'; ExportChild = 'plain' }
    foreach ($k in $want.Keys) {
        $t = @($tools | Where-Object { $_.name -eq $k })
        $ok = $t.Count -eq 1
        if ($ok) {
            switch ($want[$k]) {
                'ro' { $ok = ($t[0].annotations.readOnlyHint -eq $true) }
                'destructive' { $ok = ($t[0].annotations.destructiveHint -eq $true -and $t[0].inputSchema.properties.DryRun.default -eq $true) }
                'plain' { $ok = ($t[0].annotations.readOnlyHint -eq $false -and $t[0].annotations.destructiveHint -eq $false) }
            }
        }
        Check "tools-json-$k" $ok ($t | ConvertTo-Json -Depth 3 -Compress)
    }
    $del = @($tools | Where-Object { $_.name -eq 'DeleteChild' })[0]
    Check 'tools-json-deletechild-confirmname-required' (@($del.inputSchema.required) -contains 'ConfirmName' -and @($del.inputSchema.required) -contains 'Path') (@($del.inputSchema.required) -join ',')
}
catch {
    Check 'unexpected-exception' $false "$($_.Exception.Message) at $($_.InvocationInfo.ScriptLineNumber)"
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
}

"failed: $fail"
exit $fail
