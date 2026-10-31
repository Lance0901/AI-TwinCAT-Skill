# PLC task helpers (complete-automation-interface phase 2, task 3.5): Add-TcPlcTask, Add-TcTaskProgram,
# Remove-TcTaskProgram. Behaviour measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18 (self-built client):
# openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.5.
#   - '<Plc> Project^<task>' is ItemType 621 (TREEITEMTYPE_PLCTASK); its ProduceXml is
#     <PlcTaskDef><LinkedTask>TIRT^<task></LinkedTask></PlcTaskDef>.
#   - a program call below it is ItemType 650 (TREEITEMTYPE_PLCPROGREF, TE1000 v1.7.0 5.46.22 p.184);
#     XAE accepts ANY name for 650 (duplicates, other case, missing names, FBs, GVLs) and only the
#     build reports it, so the module checks the program itself.

$script:TcPlcTaskItemType = 621
$script:TcPlcProgRefItemType = 650
$script:TcPlcProgramItemType = 602
# CycleTimeUs * 10 must fit TaskDef/CycleTime (100 ns units, Int32 in the module's checks)
$script:TcTaskMaxCycleTimeUs = 214748364

function ConvertTo-TcTaskCycleTime {
    <#
    .SYNOPSIS
        Cycle time in microseconds -> TaskDef/CycleTime value (100 ns units): CycleTimeUs * 10.
    .DESCRIPTION
        TaskDef/CycleTime is in 100 ns units (20000 = 2 ms; measured 2026-10-30 4026 VS2022, task 2.1,
        XAE 3.1.4026.18, self-built client, verification/phase1-2.1-consumexml.md; ITcTaskModule.CycleTime "in 100 ns", TE1000 v1.7.0
        5.11 p.95-96).
    .PARAMETER CycleTimeUs
        Cycle time in microseconds.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][long]$CycleTimeUs)
    return [long]($CycleTimeUs * 10)
}

function ConvertFrom-TcTreeItemXmlString {
    <#
    .SYNOPSIS
        ProduceXml text -> XmlDocument without DTD processing and without a resolver, or $null when it
        does not parse.
    .PARAMETER Xml
        ProduceXml text.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Xml)
    if ([string]::IsNullOrWhiteSpace($Xml)) { return $null }
    $settings = New-Object System.Xml.XmlReaderSettings
    $settings.DtdProcessing = [System.Xml.DtdProcessing]::Prohibit
    $settings.XmlResolver = $null
    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $sr = $null
    $reader = $null
    try {
        $sr = New-Object System.IO.StringReader($Xml)
        $reader = [System.Xml.XmlReader]::Create($sr, $settings)
        $doc.Load($reader)
    }
    catch { return $null }
    finally {
        if ($null -ne $reader) { $reader.Dispose() }
        if ($null -ne $sr) { $sr.Dispose() }
    }
    Write-Output -NoEnumerate $doc
}

function Get-TcTreeItemXmlValue {
    <#
    .SYNOPSIS
        InnerText of the first node -XPath selects in the ProduceXml of -Item, or $null.
    .DESCRIPTION
        IDE_* / PLC_LOGGED_IN errors of ProduceXml are rethrown; any other read error gives $null.
    .PARAMETER Item
        ITcSmTreeItem.
    .PARAMETER XPath
        XPath relative to the document, e.g. 'TreeItem/TaskDef/CycleTime'.
    .PARAMETER Path
        Tree path (operation name only).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter(Mandatory)][string]$XPath, [Parameter()][string]$Path = '')
    $xml = $null
    try { $xml = Get-TcTreeItemXmlText -Item $Item -Path $Path }
    catch {
        if ($null -ne (Get-TcTreeItemPassThroughError -ErrorRecord $_)) { throw }
        return $null
    }
    $doc = ConvertFrom-TcTreeItemXmlString -Xml $xml
    if ($null -eq $doc) { return $null }
    $node = $doc.SelectSingleNode($XPath)
    if ($null -eq $node) { return $null }
    return [string]$node.InnerText
}

function Get-TcTreeItemChildList {
    <#
    .SYNOPSIS
        Direct children of a tree item as @{ name; itemType } (ItemType -1 when unreadable).
    .PARAMETER Item
        ITcSmTreeItem.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    $list = [System.Collections.Generic.List[object]]::new()
    $count = 0
    try { $count = [int]$Item.ChildCount } catch { $count = 0 }
    for ($i = 1; $i -le $count -and $list.Count -lt $script:TcTreeItemMaxChildNames; $i++) {
        try {
            $c = $Item.Child($i)
            if ($null -eq $c) { continue }
            $t = try { [int]$c.ItemType } catch { -1 }
            $list.Add([PSCustomObject]@{ name = [string]$c.Name; itemType = $t })
        }
        catch { continue }
    }
    return $list.ToArray()
}

function Resolve-TcPlcTaskNode {
    <#
    .SYNOPSIS
        '<Plc> Project^<PlcTask>' -> @{ Result = $null | TASK_NOT_FOUND result; Item; Path }.
    .DESCRIPTION
        TASK_NOT_FOUND (data.reason not-found / not-a-task, data.plcTasks = the 621 children of the PLC
        project) when the node does not exist or is not a PLC task (ItemType 621). IDE_* errors are thrown.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER PlcProjectPath
        Resolved '<Plc> Project' tree path.
    .PARAMETER PlcTask
        Name of the PLC task, e.g. 'PlcTask'.
    .PARAMETER Data
        Data object of the cmdlet (plcTasks / reason are added on failure).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SysManager,
        [Parameter(Mandatory)][string]$PlcProjectPath,
        [Parameter(Mandatory)][string]$PlcTask,
        [Parameter(Mandatory)][object]$Data
    )
    $path = "$PlcProjectPath^$PlcTask"
    $item = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $path
    $reason = $null
    if ($null -eq $item) { $reason = 'not-found' }
    else {
        $t = try { [int]$item.ItemType } catch { -1 }
        if ($t -ne $script:TcPlcTaskItemType) { $reason = 'not-a-task'; $Data | Add-Member -NotePropertyName itemType -NotePropertyValue $t -Force }
    }
    if ($null -eq $reason) { return @{ Result = $null; Item = $item; Path = $path } }
    $tasks = @()
    $prj = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $PlcProjectPath
    if ($null -ne $prj) { $tasks = @(Get-TcTreeItemChildList -Item $prj | Where-Object { $_.itemType -eq $script:TcPlcTaskItemType } | ForEach-Object { $_.name }) }
    $Data | Add-Member -NotePropertyName reason -NotePropertyValue $reason -Force
    $Data | Add-Member -NotePropertyName plcTasks -NotePropertyValue $tasks -Force
    $what = if ($reason -eq 'not-found') { 'does not exist' } else { "is not a PLC task (ItemType $($Data.itemType), expected 621)" }
    $list = if ($tasks.Count -gt 0) { ($tasks | ForEach-Object { "'$_'" }) -join ', ' } else { '(none)' }
    $res = New-TcResult -Success $false -ErrorCode 'TASK_NOT_FOUND' -Data $Data `
        -ErrorMessage "PLC task '$path' $what; nothing was changed. PLC tasks of '$PlcProjectPath': $list" `
        -Hint (Get-TcErrorHint -Code 'TASK_NOT_FOUND')
    return @{ Result = $res; Item = $null; Path = $path }
}

function Test-TcTaskProgramTarget {
    <#
    .SYNOPSIS
        Checks that -ProgramName names a PROGRAM of the PLC project exactly: @{ Result = $null | failed result; Path; Name }.
    .DESCRIPTION
        XAE's CreateChild 650 accepts any name (measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client,
        phase2-probe.md 3.5: same name twice, other case, missing name, FB, GVL all OK; the build then
        fails with C0046 / C0035 / C0080 / C0036 in <task>.TcTTO), so this is checked here.
        Resolve-TcPouPath -ProjectPath finds the object (a 650 program reference of the same name is
        not the program), Get-TcPlcObjectKind reads its ItemType. TASK_PROGRAM_INVALID data.reason:
          not-found      no object of that name in the PLC project
          not-a-program  the object is not a PROGRAM (ItemType 602); data.objectKind / itemType / pouType
          case-mismatch  a PROGRAM exists, its name differs in case (data.actualName)
        Several objects of that name -> POU_AMBIGUOUS (New-TcPouAmbiguousResult), unless every one of
        them is a program call (650): then not-found.
        Measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER PlcProjectPath
        Resolved '<Plc> Project' tree path.
    .PARAMETER ProgramName
        Program name as given.
    .PARAMETER Data
        Data object of the cmdlet.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SysManager,
        [Parameter(Mandatory)][string]$PlcProjectPath,
        [Parameter(Mandatory)][string]$ProgramName,
        [Parameter(Mandatory)][object]$Data
    )
    $fail = {
        param([string]$Reason, [string]$Message)
        $Data | Add-Member -NotePropertyName reason -NotePropertyValue $Reason -Force
        @{ Result = (New-TcResult -Success $false -ErrorCode 'TASK_PROGRAM_INVALID' -Data $Data -ErrorMessage $Message -Hint (Get-TcErrorHint -Code 'TASK_PROGRAM_INVALID')); Path = $null; Name = $null }
    }
    $res = Resolve-TcPouPath -SysManager $SysManager -Name $ProgramName -ProjectPath $PlcProjectPath
    if ($res.Ambiguous) {
        # Several hits that are ALL program calls (650, e.g. the name linked in two tasks while the
        # program itself is missing): there is no program, so not-found, not POU_AMBIGUOUS.
        $candTypes = @(@($res.Candidates) | ForEach-Object {
                $ci = Find-TcTreeItemNoThrow -SysManager $SysManager -Path ([string]$_)
                if ($null -eq $ci) { -1 } else { try { [int]$ci.ItemType } catch { -1 } }
            })
        if ($candTypes.Count -gt 0 -and @($candTypes | Where-Object { $_ -ne $script:TcPlcProgRefItemType }).Count -eq 0) {
            $Data | Add-Member -NotePropertyName tried -NotePropertyValue @($res.Tried) -Force
            $Data | Add-Member -NotePropertyName programCalls -NotePropertyValue @($res.Candidates) -Force
            return (& $fail 'not-found' "No PROGRAM '$ProgramName' in '$PlcProjectPath', only program calls of that name ($(@($res.Candidates) -join '; ')); nothing was linked.")
        }
        return @{ Result = (New-TcPouAmbiguousResult -Name $ProgramName -Resolution $res); Path = $null; Name = $null }
    }
    $kind = $null
    if ($res.Found) { $kind = Get-TcPlcObjectKind -Item $res.Item }
    if (-not $res.Found -or $kind.ItemType -eq $script:TcPlcProgRefItemType) {
        $Data | Add-Member -NotePropertyName tried -NotePropertyValue @($res.Tried) -Force
        return (& $fail 'not-found' "No PROGRAM '$ProgramName' in '$PlcProjectPath' (XAE would link the name anyway and only the build reports it); nothing was linked.")
    }
    $actual = try { [string]$res.Item.Name } catch { Get-TcTreePathLeaf -Path ([string]$res.Path) }
    if ([string]::IsNullOrWhiteSpace($actual)) { $actual = Get-TcTreePathLeaf -Path ([string]$res.Path) }
    $Data | Add-Member -NotePropertyName programPath -NotePropertyValue ([string]$res.Path) -Force
    $Data | Add-Member -NotePropertyName actualName -NotePropertyValue $actual -Force
    if ($kind.ItemType -ne $script:TcPlcProgramItemType) {
        $Data | Add-Member -NotePropertyName objectKind -NotePropertyValue $kind.ObjectKind -Force
        $Data | Add-Member -NotePropertyName itemType -NotePropertyValue $kind.ItemType -Force
        $Data | Add-Member -NotePropertyName pouType -NotePropertyValue $kind.PouType -Force
        $what = if ($kind.ObjectKind -eq 'POU' -and $kind.PouType) { $kind.PouType } elseif ($kind.ObjectKind) { $kind.ObjectKind } else { "ItemType $($kind.ItemType)" }
        return (& $fail 'not-a-program' "'$($res.Path)' is a $what, not a PROGRAM (ItemType 602); a task can only call a PROGRAM. Nothing was linked.")
    }
    if ($actual -cne $ProgramName) {
        return (& $fail 'case-mismatch' "The PROGRAM is named '$actual', not '$ProgramName' (the name must match exactly, case included); nothing was linked.")
    }
    return @{ Result = $null; Path = [string]$res.Path; Name = $actual }
}

function Copy-TcDataFields {
    <#
    .SYNOPSIS
        Copies the listed properties of -From (when present) onto -To (Add-Member -Force); 'warnings'
        is appended, not replaced.
    .PARAMETER From
        Source data object (or $null).
    .PARAMETER To
        Target data object.
    .PARAMETER Names
        Property names.
    .PARAMETER Prefix
        Optional prefix of the target names.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$From, [Parameter(Mandatory)][object]$To, [Parameter(Mandatory)][string[]]$Names, [Parameter()][string]$Prefix = '')
    if ($null -eq $From) { return }
    foreach ($n in $Names) {
        $p = $From.PSObject.Properties[$n]
        if ($null -eq $p) { continue }
        $target = if ($Prefix) { $Prefix + $n.Substring(0, 1).ToUpperInvariant() + $n.Substring(1) } else { $n }
        if ($n -eq 'warnings' -and -not $Prefix) {
            $old = $To.PSObject.Properties['warnings']
            $prev = if ($null -ne $old -and $null -ne $old.Value) { @($old.Value) } else { @() }
            $To | Add-Member -NotePropertyName warnings -NotePropertyValue @($prev + @($p.Value | Where-Object { $null -ne $_ })) -Force
            continue
        }
        $To | Add-Member -NotePropertyName $target -NotePropertyValue $p.Value -Force
    }
}

function Test-TcWriteCalled {
    <#
    .SYNOPSIS
        $true when the generic tree cmdlet that returned -Result called its COM write (data.writeCalled,
        set right before CreateChild / ConsumeXml / DeleteChild). A request refused before the call
        (checks, backup, modal dialog, parent-mismatch, an exception before the call) gives $false.
    .PARAMETER Result
        Result of New-TcTreeItem / Set-TcTreeItemXml / Remove-TcTreeItem.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][object]$Result)
    if ($null -eq $Result) { return $false }
    $dp = $Result.PSObject.Properties['data']
    if ($null -eq $dp -or $null -eq $dp.Value) { return $false }
    $w = $dp.Value.PSObject.Properties['writeCalled']
    return ($null -ne $w -and $w.Value -eq $true)
}

function Format-TcPlcTaskRollback {
    <#
    .SYNOPSIS
        One sentence about an Add-TcPlcTask rollback (data.rollback[]) for the error message.
    .DESCRIPTION
        Nothing created / rolled back (the removed paths) / ROLLBACK INCOMPLETE with the paths still
        present; a TIRT task skipped because its PLC task could not be deleted (SKIPPED_DEPENDENT) is
        named with "delete the PLC task first".
    .PARAMETER Rollback
        data.rollback[] entries (path, removed, code, message).
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyCollection()][object[]]$Rollback = @())
    $rb = @($Rollback | Where-Object { $null -ne $_ })
    if ($rb.Count -eq 0) { return 'nothing had been created' }
    $left = @($rb | Where-Object { -not $_.removed })
    if ($left.Count -eq 0) { return 'rolled back: removed ' + (($rb | ForEach-Object { "'$($_.path)'" }) -join ', ') }
    $text = 'ROLLBACK INCOMPLETE, still present: ' + (($left | ForEach-Object { "'$($_.path)' ($($_.code))" }) -join ', ')
    if (@($left | Where-Object { $_.code -eq 'SKIPPED_DEPENDENT' }).Count -gt 0) {
        $text += '; delete the PLC task first, then the TIRT task (SKIPPED_DEPENDENT)'
    }
    return $text
}
