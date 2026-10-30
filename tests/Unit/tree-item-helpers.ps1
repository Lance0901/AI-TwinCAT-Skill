# Unit (Private/TreeItem helpers: path checks, fragment parsing / comparison, field rules, backup): generic tree item tools (complete-automation-interface phase 1, tasks 2.2-2.7):
# Get-TcTreeItem (LookupTreeItem), Get-TcTreeItemXml (ProduceXml), New-TcTreeItem (CreateChild),
# Set-TcTreeItemXml (ConsumeXml), Remove-TcTreeItem (DeleteChild), Export-TcTreeItem (ExportChild),
# Import-TcTreeItem (ImportChild) and the Private/TreeItem helpers. No IDE / runtime: a mock
# ITcSysManager with an in-memory tree replaces Get-TcSysManager; ConsumeXml of the mock merges the
# fragment like XAE did in task 2.1 (or ignores it, to simulate the silent ignore).
#   powershell.exe -NoProfile -File tests/Unit/tree-item-helpers.ps1
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
    $n | Add-Member ScriptMethod ProduceXml { param($rec) $this.Xml }
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
        $this.Xml = $doc.OuterXml
    }
    $n | Add-Member ScriptMethod CreateChild {
        param($name, $sub, $before, $vinfo)
        $global:T.Mods.Add("CreateChild $($this.PathName)^$name/$sub/$before/$vinfo") | Out-Null
        switch ($global:T.CreateMode) {
            'throw' { throw [System.Runtime.InteropServices.COMException]::new('Not implemented', -2147467263) }
            'vanish' { return [PSCustomObject]@{ Name = $name; PathName = "$($this.PathName)^$name" } }
        }
        $finalName = if ($global:T.CreateMode -eq 'rename') { "$name (1)" } else { $name }
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
} $sln
function Backups { @(Get-ChildItem -LiteralPath (Join-Path $work '.tcauto-backup') -Recurse -File -ErrorAction SilentlyContinue) }

try {
    # --- 2.2 path helpers ---
    $r = & $mod { @((Test-TcTreePath -Path 'TIRT^*'), (Test-TcTreePath -Path 'TIRT^Plc?ask'), (Test-TcTreePath -Path ''), (Test-TcTreePath -Path 'TIRT^^X'), (Test-TcTreePath -Path 'TIRT^PlcTask')) }
    Check 'path-wildcard-star' ($r[0] -match 'wildcard') $r[0]
    Check 'path-wildcard-question' ($r[1] -match 'wildcard') $r[1]
    Check 'path-empty' ($r[2] -match 'empty') $r[2]
    Check 'path-empty-segment' ($r[3] -match 'empty path segment') $r[3]
    Check 'path-ok' ($null -eq $r[4]) "$($r[4])"
    $r = & $mod { @((Get-TcTreePathParent -Path 'TIRT^PlcTask'), (Get-TcTreePathParent -Path 'TIRT'), (Get-TcTreePathLeaf -Path 'TIPC^P^P Project')) }
    Check 'path-parent-leaf' ($r[0] -eq 'TIRT' -and $null -eq $r[1] -and $r[2] -eq 'P Project') ($r -join '|')

    # --- 2.2 fragment parsing / comparison (pure XML) ---
    $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml '<TreeItem><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>' }
    Check 'frag-leaf' ($null -eq $f.Error -and @($f.Leaves).Count -eq 1 -and $f.Leaves[0].path -eq 'TreeItem/TaskDef/CycleTime' -and $f.Leaves[0].value -eq '40000') ($f.Leaves | ConvertTo-Json -Depth 5 -Compress)
    $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml '<NotTreeItem><TaskDef/></NotTreeItem>' }
    Check 'frag-root' ($f.Reason -eq 'root') $f.Error
    $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml '<TreeItem><TaskDef><CycleTime>40000</TaskDef>' }
    Check 'frag-syntax' ($f.Reason -eq 'syntax') $f.Error
    $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml '<TreeItem/>' }
    Check 'frag-empty' ($f.Reason -eq 'empty') $f.Error
    $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml '<TreeItem><TaskDef><CPUs><CPU>5</CPU><CPU>6</CPU></CPUs></TaskDef><TcModuleInstance><Module><Context><CycleTime>1</CycleTime></Context></Module></TcModuleInstance></TreeItem>' }
    $paths = @($f.Leaves | ForEach-Object { $_.path })
    Check 'frag-repeated-index' ($paths[0] -eq 'TreeItem/TaskDef/CPUs/CPU[1]' -and $paths[1] -eq 'TreeItem/TaskDef/CPUs/CPU[2]' -and $f.Leaves[0].key -eq 'TreeItem/TaskDef/CPUs/CPU') ($paths -join ', ')
    Check 'frag-derived' ($f.Leaves[2].derived -and -not $f.Leaves[0].derived) ($f.Leaves | ForEach-Object { "$($_.path)=$($_.derived)" })
    $cmp = & $mod { Compare-TcTreeItemFragment -Leaves $args[0] -CurrentXml $args[1] } $f.Leaves $taskXml
    Check 'compare-repeated' (@($cmp.Missing).Count -eq 0 -and $cmp.Changes[0].current -eq '0' -and $cmp.Changes[1].current -eq '1') ($cmp.Changes | ConvertTo-Json -Compress)
    Check 'compare-derived-not-mismatch' (@($cmp.Mismatches | Where-Object { $_.path -like '*Context*' }).Count -eq 0 -and @($cmp.Mismatches).Count -eq 2) ($cmp.Mismatches | ConvertTo-Json -Compress)
    $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml '<TreeItem><TaskDef><NoSuchElement>1</NoSuchElement></TaskDef><NoSuchDef><CycleTime>1</CycleTime></NoSuchDef></TreeItem>' }
    $cmp = & $mod { Compare-TcTreeItemFragment -Leaves $args[0] -CurrentXml $args[1] } $f.Leaves $taskXml
    Check 'compare-missing' (@($cmp.Missing).Count -eq 2 -and @($cmp.Missing) -contains 'TreeItem/TaskDef/NoSuchElement' -and @($cmp.Missing) -contains 'TreeItem/NoSuchDef/CycleTime') (@($cmp.Missing) -join ', ')
    $eq = & $mod { @((Test-TcXmlValueEqual -Expected '40000' -Actual ' 40000 '), (Test-TcXmlValueEqual -Expected '#x1E' -Actual '#x1e'), (Test-TcXmlValueEqual -Expected '1.0' -Actual '1'), (Test-TcXmlValueEqual -Expected '1' -Actual '2'), (Test-TcXmlValueEqual -Expected 'abc' -Actual '0')) }
    Check 'value-equal' ($eq[0] -and $eq[1] -and $eq[2] -and -not $eq[3] -and -not $eq[4]) ($eq -join ',')

    # --- review item 9: ordinal first, numbers only when both sides parse, #x prefix case-insensitive ---
    $eq = & $mod { @(
            (Test-TcXmlValueEqual -Expected 'abc' -Actual 'ABC'),
            (Test-TcXmlValueEqual -Expected 'TRUE' -Actual 'true'),
            (Test-TcXmlValueEqual -Expected '#X1E' -Actual '#x1e'),
            (Test-TcXmlValueEqual -Expected '#x1E' -Actual '30'),
            (Test-TcXmlValueEqual -Expected '1e3' -Actual '1000'),
            (Test-TcXmlValueEqual -Expected 'PlcTask' -Actual 'plctask'),
            (Test-TcXmlValueEqual -Expected '#xZZ' -Actual '#xzz'),
            (Test-TcXmlValueEqual -Expected '' -Actual '  ')) }
    Check 'value-equal-text-case-sensitive' (-not $eq[0] -and -not $eq[1] -and -not $eq[5]) ($eq -join ',')
    Check 'value-equal-hex-prefix-case-insensitive' ($eq[2] -and $eq[3]) ($eq -join ',')
    Check 'value-equal-numeric-only-when-both-parse' ($eq[4] -and -not $eq[6] -and $eq[7]) ($eq -join ',')

    # --- review item 1: structure mismatch (fragment leaf = element with children now; mixed text) ---
    foreach ($case in @(
            @('empty-element', '<TreeItem><TaskDef/></TreeItem>', 'TreeItem/TaskDef'),
            @('text-on-parent', '<TreeItem><TaskDef>123</TaskDef></TreeItem>', 'TreeItem/TaskDef'),
            @('empty-cpus', '<TreeItem><TaskDef><CPUs/></TaskDef></TreeItem>', 'TreeItem/TaskDef/CPUs'))) {
        $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml $args[0] } $case[1]
        $cmp = & $mod { Compare-TcTreeItemFragment -Leaves $args[0] -CurrentXml $args[1] } $f.Leaves $taskXml
        Check "compare-structure-mismatch-$($case[0])" (@($cmp.StructureMismatch) -contains $case[2] -and @($cmp.Changes).Count -eq 0) ($cmp | ConvertTo-Json -Depth 4 -Compress)
    }
    $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml '<TreeItem><TaskDef>123<CycleTime>40000</CycleTime></TaskDef></TreeItem>' }
    Check 'frag-mixed-content-structure-mismatch' ($f.Reason -eq 'structure-mismatch' -and @($f.Paths) -contains 'TreeItem/TaskDef') ($f.Error)

    # --- review item 3a: repeated count must equal the current XML ---
    foreach ($case in @(@('fewer', '<TreeItem><TaskDef><CPUs><CPU>5</CPU></CPUs></TaskDef></TreeItem>', 1), @('more', '<TreeItem><TaskDef><CPUs><CPU>5</CPU><CPU>6</CPU><CPU>7</CPU></CPUs></TaskDef></TreeItem>', 3))) {
        $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml $args[0] } $case[1]
        $cmp = & $mod { Compare-TcTreeItemFragment -Leaves $args[0] -CurrentXml $args[1] } $f.Leaves $taskXml
        $rc = @($cmp.RepeatedCountMismatch)
        Check "compare-repeated-count-$($case[0])" ($rc.Count -eq 1 -and $rc[0].path -eq 'TreeItem/TaskDef/CPUs/CPU' -and $rc[0].fragmentCount -eq $case[2] -and $rc[0].currentCount -eq 2 -and @($cmp.Changes).Count -eq 0) ($rc | ConvertTo-Json -Compress)
    }

    # --- review item 4: attributes are refused ---
    foreach ($x in '<TreeItem><TaskDef><CycleTime unit="100ns">40000</CycleTime></TaskDef></TreeItem>', '<TreeItem xmlns="urn:x"><TaskDef><CycleTime>40000</CycleTime></TaskDef></TreeItem>') {
        $f = & $mod { ConvertFrom-TcTreeItemFragment -Xml $args[0] } $x
        Check "frag-attributes-$(@($f.Paths)[0])" ($f.Reason -eq 'attributes-not-supported' -and @($f.Paths).Count -eq 1 -and $null -eq $f.Leaves) $f.Error
    }

    # --- review item 3b: whole-XML comparison ---
    $before = '<TreeItem a="1"><X>1</X><Y>2</Y><L><I>1</I><I>2</I></L><TcModuleInstance><Context><C>1</C></Context></TcModuleInstance></TreeItem>'
    $full = @(& $mod { Compare-TcTreeItemXmlFull -BeforeXml $args[0] -AfterXml $args[0] -ExcludePaths @() } $before)
    Check 'full-compare-identical' ($full.Count -eq 0) ($full | ConvertTo-Json -Compress)
    $after = '<TreeItem a="2"><X>9</X><Y>3</Y><L><I>1</I></L><Z>new</Z><TcModuleInstance><Context><C>7</C></Context></TcModuleInstance></TreeItem>'
    $full = @(& $mod { Compare-TcTreeItemXmlFull -BeforeXml $args[0] -AfterXml $args[1] -ExcludePaths @('TreeItem/X') } $before $after)
    $byPath = @{}; foreach ($u in $full) { $byPath[$u.path] = $u.kind }
    Check 'full-compare-changes-outside-fragment' ($byPath['TreeItem/Y'] -eq 'changed' -and $byPath['TreeItem/@a'] -eq 'changed' -and $byPath['TreeItem/Z'] -eq 'added' -and $byPath['TreeItem/L/I[1]'] -eq 'removed' -and $byPath['TreeItem/L/I'] -eq 'added') ($full | ConvertTo-Json -Compress)
    Check 'full-compare-excludes-fragment-and-derived' (-not $byPath.ContainsKey('TreeItem/X') -and @($full | Where-Object { $_.path -like '*Context*' }).Count -eq 0) ($full | ConvertTo-Json -Compress)
    $parentBefore = '<TreeItem><Name>TIRT</Name><Children><Child>A</Child></Children></TreeItem>'
    $full = @(& $mod { Compare-TcTreeItemXmlFull -BeforeXml $args[0] -AfterXml $args[1] -AdditionsOnly } $parentBefore '<TreeItem><Name>TIRT</Name><Children><Child>New</Child><Child>A</Child></Children></TreeItem>')
    Check 'full-compare-additions-only-insert-ok' ($full.Count -eq 0) ($full | ConvertTo-Json -Compress)
    $full = @(& $mod { Compare-TcTreeItemXmlFull -BeforeXml $args[0] -AfterXml $args[1] -AdditionsOnly } $parentBefore '<TreeItem><Name>TIRT2</Name><Children><Child>A</Child><Child>New</Child></Children></TreeItem>')
    Check 'full-compare-additions-only-change-flagged' ($full.Count -eq 1 -and $full[0].path -eq 'TreeItem/Name' -and $full[0].kind -eq 'removed' -and $full[0].after -eq 'TIRT2') ($full | ConvertTo-Json -Compress)

    # --- extra: one pass-through list (PLC_LOGGED_IN included), used by the backup and the error result ---
    $codes = & $mod { $script:TcTreeItemPassThroughCodes }
    $mapped = & $mod { (Get-TcTreeItemPassThroughError -ErrorRecord 'Cannot add an object because it affects a device you are currently logged into').Code }
    Check 'passthrough-list-plc-logged-in' (@($codes) -contains 'PLC_LOGGED_IN' -and @($codes) -contains 'IDE_BUSY' -and $mapped -eq 'PLC_LOGGED_IN') (@($codes) -join ',')

    # --- review item 6: file path checks never throw ---
    $fp = & $mod { @('C:\', 'C:\a<b.xti', 'C:\a|b.xti', 'C:\dir\', 'rel.xti', 'C:\Temp\ok.xti') | ForEach-Object { $r = Test-TcTreeItemFilePath -FilePath $_; if ($null -eq $r) { 'ok' } else { $r.Reason } } }
    Check 'filepath-invalid' ($fp[0] -eq 'invalid-path' -and $fp[1] -eq 'invalid-path' -and $fp[2] -eq 'invalid-path' -and $fp[3] -eq 'invalid-path' -and $fp[4] -eq 'not-absolute' -and $fp[5] -eq 'ok') ($fp -join ',')

    # --- 2.2 known-field rules ---
    foreach ($case in @(@('0', $true), @('-10000', $true), @('abc', $true), @('12.5', $true), @('40000', $false), @('12345', $false))) {
        $leaves = & $mod { @((ConvertFrom-TcTreeItemFragment -Xml "<TreeItem><TaskDef><CycleTime>$($args[0])</CycleTime></TaskDef></TreeItem>").Leaves) } $case[0]
        $bad = @(& $mod { Test-TcTreeItemFieldValues -Leaves $args[0] } $leaves)
        Check "rule-cycletime-$($case[0])" (($bad.Count -gt 0) -eq $case[1]) ($bad | ConvertTo-Json -Compress)
    }
    $leaves = & $mod { @((ConvertFrom-TcTreeItemFragment -Xml '<TreeItem><TaskDef><Priority>-5</Priority></TaskDef></TreeItem>').Leaves) }
    Check 'rule-other-field-untouched' (@(& $mod { Test-TcTreeItemFieldValues -Leaves $args[0] } $leaves).Count -eq 0) ''

    # --- 2.2 backup helpers ---
    $safe = & $mod { @((ConvertTo-TcSafeFileName -Name 'TIRT^PlcTask'), (ConvertTo-TcSafeFileName -Name 'TIID^Dev 1 (EtherCAT)^Term:1'), (ConvertTo-TcSafeFileName -Name ('A^' * 100))) }
    Check 'safe-name' ($safe[0] -eq 'TIRT_PlcTask' -and $safe[1] -eq 'TIID_Dev 1 (EtherCAT)_Term_1' -and $safe[2].Length -eq 120) ($safe -join ' | ')
    $now = [datetime]'2026-10-30T12:34:56'
    $b1 = & $mod { New-TcTreeItemBackup -SolutionDir $args[0] -Path 'TIRT^PlcTask' -Xml '<TreeItem/>' -Now $args[1] } $work $now
    $b2 = & $mod { New-TcTreeItemBackup -SolutionDir $args[0] -Path 'TIRT^PlcTask' -Xml '<TreeItem>2</TreeItem>' -Now $args[1] } $work $now
    $expected = Join-Path $work '.tcauto-backup\20261030-123456\TIRT_PlcTask.xml'
    Check 'backup-path' ($b1.backupPath -eq $expected -and (Get-Content -LiteralPath $expected -Raw) -eq '<TreeItem/>') $b1.backupPath
    Check 'backup-no-overwrite' ($b2.backupPath -like '*TIRT_PlcTask-2.xml' -and (Get-Content -LiteralPath $b1.backupPath -Raw) -eq '<TreeItem/>') $b2.backupPath
    $d = & $mod { Find-TcTreeItemDiskFile -SolutionDir $args[0] -Path 'TIRT^PlcTask' -Name 'PlcTask' -ItemType 19 } $work
    Check 'diskfile-task-one' (@($d.Files).Count -eq 1 -and $d.Files[0] -like '*Plc1\PlcTask.TcTTO' -and @($d.Warnings).Count -eq 0) (($d.Files + $d.Warnings) -join ' | ')
    $d = & $mod { Find-TcTreeItemDiskFile -SolutionDir $args[0] -Path 'TIRT^Other' -Name 'Other' -ItemType 19 } $work
    Check 'diskfile-task-none-warning' (@($d.Files).Count -eq 0 -and @($d.Warnings).Count -eq 1 -and $d.Warnings[0] -match 'NOT in the backup') ($d.Warnings -join ' | ')
    $null = New-Item -ItemType Directory -Path (Join-Path $work 'Plc2') -Force
    Set-Content -LiteralPath (Join-Path $work 'Plc2\MAIN.TcPOU') -Value 'x' -Encoding ASCII
    Set-Content -LiteralPath (Join-Path $work 'Plc1\MAIN.TcPOU') -Value 'y' -Encoding ASCII
    $d = & $mod { Find-TcTreeItemDiskFile -SolutionDir $args[0] -Path 'TIPC^P^P Project^POUs^MAIN' -Name 'MAIN' -ItemType 604 } $work
    Check 'diskfile-ambiguous-warning' (@($d.Files).Count -eq 0 -and $d.Warnings[0] -match '2 files') ($d.Warnings -join ' | ')
    $d = & $mod { Find-TcTreeItemDiskFile -SolutionDir $args[0] -Path 'TIID^Dev' -Name 'Dev' -ItemType 0 } $work
    Check 'diskfile-no-rule' (@($d.Files).Count -eq 0 -and @($d.Warnings).Count -eq 0) ''
    Remove-Item -LiteralPath (Join-Path $work '.tcauto-backup') -Recurse -Force

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
