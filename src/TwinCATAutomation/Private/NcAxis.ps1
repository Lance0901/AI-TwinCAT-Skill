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
        A path (contains '^') is looked up and must be an axis (ItemType 22); when two axes of the
        Axes children have that same path (duplicate names) -> NC_AXIS_AMBIGUOUS. A name is searched in
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
        # review S8: XAE allows two axes with the same name, so the same path can mean two axes;
        # LookupTreeItem would silently pick one of them
        $same = @(Get-TcNcAxisList -SysManager $SysManager | Where-Object { $_.path -ieq $Axis })
        if ($same.Count -gt 1) {
            $Data | Add-Member -NotePropertyName ncAxes -NotePropertyValue @($same | ForEach-Object { $_.path }) -Force
            return (& $fail 'NC_AXIS_AMBIGUOUS' "$($same.Count) NC axes have the path '$Axis' (XAE allows duplicate names); rename or delete the duplicates first. Nothing was changed.")
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

function Get-TcNcAxisConsistencyWarnings {
    <#
    .SYNOPSIS
        Warnings for planned NcAxisDef values that contradict other fields of the same ProduceXml (review S9).
    .DESCRIPTION
        Checked (the planned value, else the current one): Dynamic/Acceleration <=
        Dynamic/AccelerationMaximum, Dynamic/Deceleration <= Dynamic/DecelerationMaximum, and
        Velo/Maximum >= Velo/Fast, FastManual, SlowManual, RefSearch, RefSync. A field missing in the
        XML is skipped. Not measured: whether the NC refuses, clamps or ignores such values; the
        cmdlet only reports them.
    .PARAMETER Doc
        Axis ProduceXml (XmlDocument).
    .PARAMETER Planned
        XPath below TreeItem -> planned text.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Xml.XmlDocument]$Doc, [Parameter(Mandatory)][System.Collections.IDictionary]$Planned)
    $get = {
        param([string]$x)
        if ($Planned.Contains($x)) { return (ConvertFrom-TcInvariantNumberText -Text ([string]$Planned[$x])) }
        $n = $Doc.SelectSingleNode("TreeItem/$x")
        if ($null -eq $n) { return $null }
        return (ConvertFrom-TcInvariantNumberText -Text ([string]$n.InnerText))
    }
    $out = [System.Collections.Generic.List[string]]::new()
    $dyn = 'NcAxisDef/AxisParam/Dynamic'
    $velo = 'NcAxisDef/AxisParam/Velo'
    foreach ($pair in @(@('Acceleration', 'AccelerationMaximum'), @('Deceleration', 'DecelerationMaximum'))) {
        $v = & $get "$dyn/$($pair[0])"; $m = & $get "$dyn/$($pair[1])"
        if ($null -ne $v -and $null -ne $m -and $v -gt $m) { $out.Add("$($pair[0]) $v is above $($pair[1]) $m (not refused; how the NC treats it is not measured)") }
    }
    $max = & $get "$velo/Maximum"
    if ($null -ne $max) {
        foreach ($f in @('Fast', 'FastManual', 'SlowManual', 'RefSearch', 'RefSync')) {
            $v = & $get "$velo/$f"
            if ($null -ne $v -and $v -gt $max) { $out.Add("Velo/Maximum $max is below Velo/$f $v (not refused; how the NC treats it is not measured)") }
        }
    }
    return $out.ToArray()
}

function Get-TcRealTimeTaskNames {
    <#
    .SYNOPSIS
        Names of the real-time tasks: the children of TIRT, then the PLC tasks (ItemType 621) of the PLC project. Distinct, never throws.
    .DESCRIPTION
        Used to build '<instance>^<task> Inputs' / 'Outputs' (phase3-4.6 B1): the PLC instance
        (ItemType 57) reports ChildCount 0 on real COM and its process images are only reachable by
        LookupTreeItem of the full path (measured 2026-11-01, 4026.22 VS2022 and 4024.71 XAE Shell,
        verification/phase3-4.6.md B1). The children of TIRT are enumerable on real COM and carry
        the names used in '<task> Inputs' / 'Outputs' (實測 2026-11-01, registered tcauto,
        phase3-4.6.md Retest B1 / N3): 4026.22 VS2022 TIRT childCount 1 = [PlcTask]; 4024.71 XAE
        Shell childCount 2 = [PlcTask, MotionTask]; on both the links went to 'PlcTask Inputs' /
        'PlcTask Outputs' and were read back as linked.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER ProjectPath
        'TIPC^<Plc>^<Plc> Project' (optional; its 621 children are added).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter()][string]$ProjectPath)
    $names = [System.Collections.Generic.List[string]]::new()
    $found = [System.Collections.Generic.List[object]]::new()
    $tirt = Find-TcTreeItemNoThrow -SysManager $SysManager -Path 'TIRT'
    if ($null -ne $tirt) { foreach ($c in @(Get-TcTreeItemChildList -Item $tirt)) { $found.Add($c) } }
    if (-not [string]::IsNullOrEmpty($ProjectPath)) {
        $prj = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $ProjectPath
        if ($null -ne $prj) { foreach ($c in @(Get-TcTreeItemChildList -Item $prj | Where-Object { $_.itemType -eq $script:TcPlcTaskItemType })) { $found.Add($c) } }
    }
    foreach ($c in $found) {
        $n = [string]$c.name
        if ([string]::IsNullOrEmpty($n)) { continue }
        if (@($names | Where-Object { $_ -ieq $n }).Count -eq 0) { $names.Add($n) }
    }
    return $names.ToArray()
}

function Get-TcPlcInstanceImageNames {
    <#
    .SYNOPSIS
        Candidate task names of the process images of a PLC instance ('<task>' of '<task> Inputs' / '<task> Outputs'), distinct, in order.
    .DESCRIPTION
        The tasks of the enumerated '* Inputs' / '* Outputs' children come first (when the
        enumeration returns any), then every task name. The enumeration alone is not enough: on
        real COM it is empty (phase3-4.6 B1). The caller pairs '<task> Inputs' with
        '<task> Outputs' of the SAME task (review S4).
    .PARAMETER Item
        ITcSmTreeItem of the PLC instance.
    .PARAMETER TaskNames
        Real-time task names (Get-TcRealTimeTaskNames).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter()][string[]]$TaskNames = @())
    $kids = @(Get-TcTreeItemChildList -Item $Item | ForEach-Object { [string]$_.name })
    $bases = [System.Collections.Generic.List[string]]::new()
    $cands = @(foreach ($k in $kids) { if ($k -match '^(.+) (Inputs|Outputs)$') { $Matches[1] } }) + @($TaskNames)
    foreach ($b in $cands) {
        if ([string]::IsNullOrEmpty([string]$b)) { continue }
        if (@($bases | Where-Object { $_ -ieq $b }).Count -eq 0) { $bases.Add([string]$b) }
    }
    return $bases.ToArray()
}

function Find-TcPlcAxisRefImage {
    <#
    .SYNOPSIS
        PLC side of an AXIS_REF: @{ NcToPlc = '<instance>^<task> Inputs^<var>.NcToPlc' | $null; PlcToNc = '<instance>^<task> Outputs^<var>.PlcToNc' | $null; Task; Instance; Tried; Found }.
    .DESCRIPTION
        The process image names are not hard-coded (phase3-probe.md question 5: the task was called
        PlcTask in that project only). Candidate tasks (Get-TcPlcInstanceImageNames): those of the
        enumerated '* Inputs' / '* Outputs' children of the instance, then each real-time task
        (phase3-4.6 B1: the instance enumerates no children on real COM, LookupTreeItem of the full
        path works). review S4: NcToPlc and PlcToNc must come from the SAME task; for each task both
        '<task> Inputs^<var>.NcToPlc' and '<task> Outputs^<var>.PlcToNc' are looked up, the first task
        with both wins. No such task -> NcToPlc / PlcToNc $null, Found = every path that was found
        (one side only), Tried = every path looked up.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER InstancePath
        'TIPC^<Plc>^<Plc> Instance'.
    .PARAMETER PlcVariable
        Symbol of the AXIS_REF, e.g. 'MAIN.axis'.
    .PARAMETER TaskNames
        Real-time task names (Get-TcRealTimeTaskNames).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][string]$InstancePath, [Parameter(Mandatory)][string]$PlcVariable, [Parameter()][string[]]$TaskNames = @())
    $out = @{ NcToPlc = $null; PlcToNc = $null; Task = $null; Instance = $null; Tried = @(); Found = @() }
    $tried = [System.Collections.Generic.List[string]]::new()
    $found = [System.Collections.Generic.List[string]]::new()
    $inst = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $InstancePath
    if ($null -eq $inst) { $tried.Add($InstancePath); $out.Tried = $tried.ToArray(); return $out }
    $out.Instance = $InstancePath
    foreach ($t in @(Get-TcPlcInstanceImageNames -Item $inst -TaskNames $TaskNames)) {
        $pin = "$InstancePath^$t Inputs^$PlcVariable.NcToPlc"
        $pout = "$InstancePath^$t Outputs^$PlcVariable.PlcToNc"
        $tried.Add($pin); $tried.Add($pout)
        $hasIn = $null -ne (Find-TcTreeItemNoThrow -SysManager $SysManager -Path $pin)
        $hasOut = $null -ne (Find-TcTreeItemNoThrow -SysManager $SysManager -Path $pout)
        if ($hasIn -and $hasOut) { $out.NcToPlc = $pin; $out.PlcToNc = $pout; $out.Task = $t; $found.Clear(); break }
        if ($hasIn) { $found.Add($pin) }
        if ($hasOut) { $found.Add($pout) }
    }
    $out.Tried = $tried.ToArray()
    $out.Found = $found.ToArray()
    return $out
}

function Test-TcPlcInstanceHasImage {
    <#
    .SYNOPSIS
        $true when a tree item has a process image: an enumerated '* Inputs' / '* Outputs' child, or '<Path>^<task> Inputs' / 'Outputs' found by LookupTreeItem.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Path
        Tree path of the candidate instance.
    .PARAMETER Item
        Its ITcSmTreeItem.
    .PARAMETER TaskNames
        Real-time task names (Get-TcRealTimeTaskNames).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Item, [Parameter()][string[]]$TaskNames = @())
    if (@(Get-TcTreeItemChildList -Item $Item | Where-Object { $_.name -like '* Inputs' -or $_.name -like '* Outputs' }).Count -gt 0) { return $true }
    foreach ($t in @($TaskNames)) {
        foreach ($img in @("$t Inputs", "$t Outputs")) {
            if ($null -ne (Find-TcTreeItemNoThrow -SysManager $SysManager -Path "$Path^$img")) { return $true }
        }
    }
    return $false
}

function Resolve-TcPlcInstancePath {
    <#
    .SYNOPSIS
        Tree path of the PLC instance below 'TIPC^<Plc>' (review N6: not hard-coded as '<Plc> Instance').
    .DESCRIPTION
        Candidates: the enumerated children of the PLC node (other than '<Plc> Project') and
        '<Plc> Instance' (the usual name, also tried when the enumeration is empty). A candidate counts
        when it has a process image (Test-TcPlcInstanceHasImage: an enumerated '* Inputs' / '* Outputs'
        child, or '<task> Inputs' / 'Outputs' found by LookupTreeItem; phase3-4.6 B1, the instance
        enumerates no children on real COM). Exactly one candidate is returned; none or several ->
        'TIPC^<Plc>^<Plc> Instance' and Note says why.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER PlcNodePath
        'TIPC^<Plc>'.
    .PARAMETER ProjectPath
        'TIPC^<Plc>^<Plc> Project' (skipped).
    .PARAMETER TaskNames
        Real-time task names (Get-TcRealTimeTaskNames).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][string]$PlcNodePath, [Parameter()][string]$ProjectPath, [Parameter()][string[]]$TaskNames = @())
    $leaf = Get-TcTreePathLeaf -Path $PlcNodePath
    $default = "$PlcNodePath^$leaf Instance"
    $node = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $PlcNodePath
    if ($null -eq $node) { return @{ Path = $default; Note = "'$PlcNodePath' not found" } }
    $paths = [System.Collections.Generic.List[string]]::new()
    foreach ($c in @(Get-TcTreeItemChildList -Item $node)) { $paths.Add("$PlcNodePath^$($c.name)") }
    if (@($paths | Where-Object { $_ -ieq $default }).Count -eq 0) { $paths.Add($default) }
    $cands = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $paths) {
        if (-not [string]::IsNullOrEmpty($ProjectPath) -and $p -ieq $ProjectPath) { continue }
        $ci = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $p
        if ($null -eq $ci) { continue }
        if (Test-TcPlcInstanceHasImage -SysManager $SysManager -Path $p -Item $ci -TaskNames $TaskNames) { $cands.Add($p) }
    }
    if ($cands.Count -eq 1) { return @{ Path = $cands[0]; Note = $null } }
    return @{ Path = $default; Note = "$($cands.Count) children of '$PlcNodePath' have process images; '$default' is assumed" }
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
