# NC configuration helpers (complete-automation-interface phase 3, task 4.1): Add-TcNcTask,
# Add-TcNcAxis, Set-TcNcAxisParameter, Connect-TcNcAxisToPlc.
# Measured 2026-11-01 4026 VS2022 XAE 3.1.4026.22 / 4024 XAE Shell 3.1.4024.71, self-built client
# (openspec/changes/complete-automation-interface/verification/phase3-probe.md, questions 1-5):
#   - TINC (ItemType 19, name MOTION) holds ONE NC task (ItemType 1, 'NC-Task 1 SAF'); a second
#     CreateChild(<name>, 1) on TINC fails with 0x98510002 "Item already exists!" (question 1).
#   - <task>^Axes.CreateChild(<name>, <axis subType>) creates an axis (ItemType 22) whose children
#     are Enc (23, subType 1 'Simulation encoder'), Drive (24, subType 5) and Ctrl (25, subType 1):
#     a new axis is a simulation axis by default. XAE does NOT refuse a duplicate name (question 2).
#   - the axis ProduceXml holds the whole <NcAxisDef>; ConsumeXml changes only the sent fields but
#     answers S_OK for wrong values ('abc' -> 0) and unknown elements (question 3).
#   - ChangeChildSubType is E_NOTIMPL; the drive / encoder / controller type is switched with
#     ConsumeXml NcAxisDef/Drive/DrvType, Encoder/EncType, Controller/CtrType; an unknown number is
#     accepted too and leaves ItemSubTypeName empty (question 4).
#   - PLC AXIS_REF link: LinkVariables on the whole struct, PLC '<image> Inputs^<var>.NcToPlc' <->
#     NC '<axis>^Outputs^ToPlc' and NC '<axis>^Inputs^FromPlc' <-> PLC '<image> Outputs^<var>.PlcToNc'
#     (question 5). TE1000 v1.7.0 5.1.1.2 p.38 (LinkVariables), 6.3.14 p.217 (NC axes in mappings).
# ItemTypes: TE1000 v1.7.0 5.46.22 TREEITEMTYPES p.179 (NCDEF 19, NCAXIS 22, NCENCODER 23, NCDRIVE 24,
# NCCONTROLLER 25); the NC task's ItemType 1 is measured (question 1).

$script:TcNcTaskItemType = 1
$script:TcNcAxisItemType = 22
# CreateChild subType of an axis below <task>^Axes (measured, question 2; 0 and 8 are refused with
# 0x98510003 "Invalid item sub type").
$script:TcNcAxisSubTypes = [ordered]@{ Continuous = 1; Discrete = 2; Stepper = 3; Encoder = 5 }
# Type numbers that XAE names (ItemSubTypeName not empty), measured with ConsumeXml (question 4).
# Drive 0 is not accepted (XAE stores 5 instead), so it is left out.
$script:TcNcDriveTypes = @(1..17) + @(20..24)
$script:TcNcEncoderTypes = @(0..8) + @(10..21) + @(24..29)
$script:TcNcControllerTypes = @(1..3) + @(5..14)

# Set-TcNcAxisParameter fields: parameter -> NcAxisDef path below TreeItem (measured in the axis
# ProduceXml, question 3). Only Velo/Maximum and Dynamic/Acceleration were written and read back in
# the probe; Deceleration / Jerk are siblings in the same <Dynamic> element (not written there).
$script:TcNcAxisFields = [ordered]@{
    MaxVelocity    = @{ XPath = 'NcAxisDef/AxisParam/Velo/Maximum'; Kind = 'number'; Min = 0.0; MinExclusive = $true }
    Acceleration   = @{ XPath = 'NcAxisDef/AxisParam/Dynamic/Acceleration'; Kind = 'number'; Min = 0.0; MinExclusive = $true }
    Deceleration   = @{ XPath = 'NcAxisDef/AxisParam/Dynamic/Deceleration'; Kind = 'number'; Min = 0.0; MinExclusive = $true }
    Jerk           = @{ XPath = 'NcAxisDef/AxisParam/Dynamic/Jerk'; Kind = 'number'; Min = 0.0; MinExclusive = $false }
    EncoderType    = @{ XPath = 'NcAxisDef/Encoder/EncType'; Kind = 'type'; Child = 'Enc' }
    DriveType      = @{ XPath = 'NcAxisDef/Drive/DrvType'; Kind = 'type'; Child = 'Drive' }
    ControllerType = @{ XPath = 'NcAxisDef/Controller/CtrType'; Kind = 'type'; Child = 'Ctrl' }
}
$script:TcNcAxisNumberMax = 1.0e12

function Get-TcNcTaskList {
    <#
    .SYNOPSIS
        NC tasks below TINC: @{ Tinc = <item> | $null; Tasks = @(@{ name; path }) }.
    .DESCRIPTION
        A task is a TINC child with ItemType 1 (measured, phase3-probe.md question 1). TINC not
        found -> Tinc $null, no task. IDE_* errors are thrown.
    .PARAMETER SysManager
        ITcSysManager.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager)
    $tinc = Find-TcTreeItemNoThrow -SysManager $SysManager -Path 'TINC'
    $tasks = [System.Collections.Generic.List[object]]::new()
    if ($null -ne $tinc) {
        $count = 0
        try { $count = [int]$tinc.ChildCount } catch { $count = 0 }
        for ($i = 1; $i -le $count; $i++) {
            $c = $null
            try { $c = $tinc.Child($i) } catch { continue }
            if ($null -eq $c) { continue }
            $t = try { [int]$c.ItemType } catch { -1 }
            if ($t -ne $script:TcNcTaskItemType) { continue }
            $n = [string](Get-TcTreeItemPropertyNoThrow -Item $c -Name 'Name' -Default '')
            $p = [string](Get-TcTreeItemPropertyNoThrow -Item $c -Name 'PathName' -Default '')
            if ([string]::IsNullOrWhiteSpace($p)) { $p = "TINC^$n" }
            $tasks.Add([PSCustomObject]@{ name = $n; path = $p })
        }
    }
    return @{ Tinc = $tinc; Tasks = $tasks.ToArray() }
}

function Resolve-TcNcTask {
    <#
    .SYNOPSIS
        -Task of an NC cmdlet -> @{ Result = $null | <failed result>; Path; Tasks }.
    .DESCRIPTION
        Empty -Task: the only NC task (NC_TASK_NOT_FOUND when there is none, NC_TASK_AMBIGUOUS when
        there are several; XAE allows only one per TINC, measured question 1, so the second case is
        not reproducible). A name or 'TINC^<name>' must be one of the tasks (NC_TASK_NOT_FOUND).
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Task
        Task name / tree path, or empty.
    .PARAMETER Data
        Data of the cmdlet (ncTasks is added).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter()][AllowEmptyString()][AllowNull()][string]$Task, [Parameter(Mandatory)][object]$Data)
    $list = Get-TcNcTaskList -SysManager $SysManager
    $tasks = @($list.Tasks)
    $Data | Add-Member -NotePropertyName ncTasks -NotePropertyValue @($tasks | ForEach-Object { $_.path }) -Force
    if ($tasks.Count -eq 0) {
        $why = if ($null -eq $list.Tinc) { "the NC configuration 'TINC' is not in this project" } else { "'TINC' has no NC task" }
        return @{ Path = $null; Tasks = $tasks; Result = (New-TcResult -Success $false -ErrorCode 'NC_TASK_NOT_FOUND' -Data $Data `
                    -ErrorMessage "No NC task: $why; nothing was changed." -Hint (Get-TcErrorHint -Code 'NC_TASK_NOT_FOUND')) }
    }
    if ([string]::IsNullOrWhiteSpace($Task)) {
        if ($tasks.Count -gt 1) {
            return @{ Path = $null; Tasks = $tasks; Result = (New-TcResult -Success $false -ErrorCode 'NC_TASK_AMBIGUOUS' -Data $Data `
                        -ErrorMessage "Several NC tasks ($(($tasks | ForEach-Object { "'$($_.path)'" }) -join ', ')); give -Task." -Hint (Get-TcErrorHint -Code 'NC_TASK_AMBIGUOUS')) }
        }
        return @{ Path = $tasks[0].path; Tasks = $tasks; Result = $null }
    }
    $hit = @($tasks | Where-Object { $_.path -ieq $Task -or $_.name -ieq $Task })
    if ($hit.Count -ne 1) {
        return @{ Path = $null; Tasks = $tasks; Result = (New-TcResult -Success $false -ErrorCode 'NC_TASK_NOT_FOUND' -Data $Data `
                    -ErrorMessage "-Task '$Task' is not an NC task; NC tasks: $(($tasks | ForEach-Object { "'$($_.path)'" }) -join ', '). Nothing was changed." -Hint (Get-TcErrorHint -Code 'NC_TASK_NOT_FOUND')) }
    }
    return @{ Path = $hit[0].path; Tasks = $tasks; Result = $null }
}

function Get-TcNcAxisList {
    <#
    .SYNOPSIS
        Axes of every NC task: @(@{ name; path; task }).
    .PARAMETER SysManager
        ITcSysManager.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager)
    $out = [System.Collections.Generic.List[object]]::new()
    foreach ($t in @((Get-TcNcTaskList -SysManager $SysManager).Tasks)) {
        $axes = Find-TcTreeItemNoThrow -SysManager $SysManager -Path "$($t.path)^Axes"
        if ($null -eq $axes) { continue }
        foreach ($c in @(Get-TcTreeItemChildList -Item $axes)) {
            if ($c.itemType -ne $script:TcNcAxisItemType) { continue }
            $out.Add([PSCustomObject]@{ name = $c.name; path = "$($t.path)^Axes^$($c.name)"; task = $t.path })
        }
    }
    return $out.ToArray()
}

function Resolve-TcNcAxis {
    <#
    .SYNOPSIS
        -Axis (tree path or axis name) -> @{ Result = $null | <failed result>; Path; Item }.
    .DESCRIPTION
        A path (contains '^') is looked up and must be an axis (ItemType 22). A name is searched in
        the Axes of every NC task (exact case first, then case-insensitive); several axes with that
        name (XAE allows duplicates, phase3-probe.md question 2) -> NC_AXIS_AMBIGUOUS, none ->
        NC_AXIS_NOT_FOUND (data.ncAxes lists the axes).
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Axis
        Tree path or name.
    .PARAMETER Data
        Data of the cmdlet.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][AllowEmptyString()][string]$Axis, [Parameter(Mandatory)][object]$Data)
    $fail = {
        param([string]$Code, [string]$Msg)
        @{ Path = $null; Item = $null; Result = (New-TcResult -Success $false -ErrorCode $Code -Data $Data -ErrorMessage $Msg -Hint (Get-TcErrorHint -Code $Code)) }
    }
    if ([string]::IsNullOrWhiteSpace($Axis)) { return (& $fail 'INVALID_PARAMS' '-Axis must be an axis name or its tree path (TINC^<task>^Axes^<axis>); nothing was changed.') }
    if ($Axis.Contains('^')) {
        $r = Resolve-TcTreeItem -SysManager $SysManager -Path $Axis -Data $Data -ParameterName 'Axis'
        if ($null -ne $r.Result) { return @{ Path = $null; Item = $null; Result = $r.Result } }
        $t = try { [int]$r.Item.ItemType } catch { -1 }
        if ($t -ne $script:TcNcAxisItemType) {
            $Data | Add-Member -NotePropertyName itemType -NotePropertyValue $t -Force
            return (& $fail 'NC_AXIS_NOT_FOUND' "-Axis '$Axis' is not an NC axis (ItemType $t, expected 22); nothing was changed.")
        }
        return @{ Path = $Axis; Item = $r.Item; Result = $null }
    }
    $all = @(Get-TcNcAxisList -SysManager $SysManager)
    $Data | Add-Member -NotePropertyName ncAxes -NotePropertyValue @($all | ForEach-Object { $_.path }) -Force
    $hit = @($all | Where-Object { $_.name -ceq $Axis })
    if ($hit.Count -eq 0) { $hit = @($all | Where-Object { $_.name -ieq $Axis }) }
    if ($hit.Count -eq 0) { return (& $fail 'NC_AXIS_NOT_FOUND' "No NC axis named '$Axis'; axes: $(if ($all.Count) { ($all | ForEach-Object { "'$($_.path)'" }) -join ', ' } else { '(none)' }). Nothing was changed.") }
    if ($hit.Count -gt 1) { return (& $fail 'NC_AXIS_AMBIGUOUS' "$($hit.Count) NC axes are named '$Axis' ($(($hit | ForEach-Object { "'$($_.path)'" }) -join ', ')); XAE allows duplicate names, so give the tree path of one of them, or rename the duplicates. Nothing was changed.") }
    $item = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $hit[0].path
    if ($null -eq $item) { return (& $fail 'NC_AXIS_NOT_FOUND' "NC axis '$($hit[0].path)' could not be looked up; nothing was changed.") }
    return @{ Path = $hit[0].path; Item = $item; Result = $null }
}

function Get-TcNcAxisChildTypes {
    <#
    .SYNOPSIS
        Encoder / drive / controller of an axis: @{ encoder; drive; controller } each @{ subType; subTypeName } or $null.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER AxisPath
        Tree path of the axis.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][string]$AxisPath)
    $out = [ordered]@{}
    foreach ($pair in @(@('encoder', 'Enc'), @('drive', 'Drive'), @('controller', 'Ctrl'))) {
        $c = Find-TcTreeItemNoThrow -SysManager $SysManager -Path "$AxisPath^$($pair[1])"
        if ($null -eq $c) { $out[$pair[0]] = $null; continue }
        $out[$pair[0]] = [PSCustomObject]@{
            path        = "$AxisPath^$($pair[1])"
            subType     = $(try { [int]$c.ItemSubType } catch { -1 })
            subTypeName = [string](Get-TcTreeItemPropertyNoThrow -Item $c -Name 'ItemSubTypeName' -Default '')
        }
    }
    return [PSCustomObject]$out
}

function Test-TcNcSimulationEncoder {
    <#
    .SYNOPSIS
        True when an encoder summary (Get-TcNcAxisChildTypes .encoder) is the simulation encoder.
    .DESCRIPTION
        EncType / ItemSubType 0 and 1 are both 'Simulation encoder' (measured, phase3-probe.md
        question 4). The number decides; ItemSubTypeName is not compared (it may be localized).
    .PARAMETER Encoder
        Encoder summary or $null.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Encoder)
    if ($null -eq $Encoder) { return $false }
    return (@(0, 1) -contains [int]$Encoder.subType)
}

function ConvertTo-TcInvariantNumberText {
    <#
    .SYNOPSIS
        [double] -> text with '.' as decimal separator (round-trip).
    .PARAMETER Value
        Number.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][double]$Value)
    return $Value.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
}

function ConvertFrom-TcInvariantNumberText {
    <#
    .SYNOPSIS
        Text -> [double] (invariant culture) or $null.
    .PARAMETER Text
        Text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Text)
    $d = 0.0
    if ([double]::TryParse([string]$Text, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    return $null
}

function New-TcNcAxisFragment {
    <#
    .SYNOPSIS
        <TreeItem><NcAxisDef>...</NcAxisDef></TreeItem> fragment for the planned fields (XmlDocument, no string concatenation of values).
    .PARAMETER Values
        Ordered hashtable XPath (below TreeItem) -> text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary]$Values)
    $doc = New-Object System.Xml.XmlDocument
    $root = $doc.AppendChild($doc.CreateElement('TreeItem'))
    foreach ($k in $Values.Keys) {
        $node = $root
        foreach ($seg in @(([string]$k) -split '/')) {
            $next = $node.SelectSingleNode($seg)
            if ($null -eq $next) { $next = $node.AppendChild($doc.CreateElement($seg)) }
            $node = $next
        }
        $node.InnerText = [string]$Values[$k]
    }
    return $doc.OuterXml
}

function Find-TcPlcAxisRefImage {
    <#
    .SYNOPSIS
        PLC side of an AXIS_REF: @{ NcToPlc = '<instance>^<x> Inputs^<var>.NcToPlc' | $null; PlcToNc = '<instance>^<x> Outputs^<var>.PlcToNc' | $null; Instance; Images }.
    .DESCRIPTION
        The process image names ('PlcTask Inputs' ...) are taken from the children of the PLC
        instance, not hard-coded (phase3-probe.md question 5: the task was called PlcTask in that
        project only). Every '* Inputs' / '* Outputs' child is tried with LookupTreeItem.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER InstancePath
        'TIPC^<Plc>^<Plc> Instance'.
    .PARAMETER PlcVariable
        Symbol of the AXIS_REF, e.g. 'MAIN.axis'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][string]$InstancePath, [Parameter(Mandatory)][string]$PlcVariable)
    $out = @{ NcToPlc = $null; PlcToNc = $null; Instance = $null; Images = @() }
    $inst = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $InstancePath
    if ($null -eq $inst) { return $out }
    $out.Instance = $InstancePath
    $kids = @(Get-TcTreeItemChildList -Item $inst | ForEach-Object { $_.name })
    $out.Images = $kids
    foreach ($k in @($kids | Where-Object { $_ -like '* Inputs' })) {
        $p = "$InstancePath^$k^$PlcVariable.NcToPlc"
        if ($null -ne (Find-TcTreeItemNoThrow -SysManager $SysManager -Path $p)) { $out.NcToPlc = $p; break }
    }
    foreach ($k in @($kids | Where-Object { $_ -like '* Outputs' })) {
        $p = "$InstancePath^$k^$PlcVariable.PlcToNc"
        if ($null -ne (Find-TcTreeItemNoThrow -SysManager $SysManager -Path $p)) { $out.PlcToNc = $p; break }
    }
    return $out
}

function Invoke-TcNcAxisRollback {
    <#
    .SYNOPSIS
        Deletes a tree item this call created (Remove-TcTreeItem -AllowNoExport): @{ path; removed; code; message }. Never throws.
    .PARAMETER Path
        Tree path of the created item.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $rr = $null
    try { $rr = Remove-TcTreeItem -Path $Path -ConfirmName (Get-TcTreePathLeaf -Path $Path) -DryRun $false -AllowNoExport }
    catch { $rr = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'TREEITEM_DELETE_FAILED'; message = $_.Exception.Message } } }
    [PSCustomObject]@{
        path    = $Path
        removed = [bool]$rr.success
        code    = $(if ($rr.success) { $null } else { [string]$rr.error.code })
        message = $(if ($rr.success) { $null } else { [string]$rr.error.message })
    }
}
