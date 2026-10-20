# ITcSmTreeItem.ItemType -> readable name (Get-TcProjectTree "type").
# Measured on TwinCAT 4024 (TcXaeShell 15.0, 2026-10-20): PLC items report their kind in
# ItemType and ItemSubType is always 0; the 6xx values equal the CreateChild sub types.
# One entry per line; unknown types are reported as the number.
$script:TcPlcItemTypeNames = @{
    14  = 'PlcConfig'            # TIPC
    56  = 'Plc'                  # TIPC^<Plc>
    57  = 'PlcInstance'          # TIPC^<Plc>^<Plc> Instance
    600 = 'Project'              # TIPC^<Plc>^<Plc> Project
    601 = 'Folder'               # POUs / DUTs / GVLs / Libs / user folders
    602 = 'FunctionBlock'
    603 = 'Function'
    604 = 'Program'
    606 = 'Dut'                  # STRUCT / ENUM / ALIAS / UNION (CreateChild 605-607 all yield 606)
    609 = 'Method'
    610 = 'InterfaceMethod'
    611 = 'Property'
    612 = 'InterfaceProperty'
    615 = 'Gvl'
    617 = 'References'
    621 = 'Task'                 # PlcTask
    625 = 'GlobalTextList'
    650 = 'TaskPou'              # POU referenced under PlcTask
    652 = 'ExternalTypes'
    653 = 'Tmc'                  # <Plc>.tmc
    656 = 'LibraryReference'
    657 = 'PlaceholderReference' # Tc2_Standard, Tc2_System, Tc3_Module ...
}

function Get-TcProjectTree {
    <#
    .SYNOPSIS
        Reads and returns the TwinCAT project structure as a JSON tree.
    .DESCRIPTION
        Every node is { name, path, type, itemType, subType, children }:
          path      full tree path; can be passed as-is to Get-TcPouCode / Write-TcPouCode -PouPath
          itemType  ITcSmTreeItem.ItemType (-1 when unreadable)
          subType   ITcSmTreeItem.ItemSubType (-1 when unreadable)
          type      name of itemType when known (Project, Folder, FunctionBlock, Function,
                    Program, Dut, Gvl, Task ...; see $script:TcPlcItemTypeNames), otherwise
                    "<itemType>" or "<itemType>/<subType>" when subType is set
        A node at the depth limit that still has children returns children = @() and
        truncated = true (only such nodes carry the truncated property).
        TIPC^<Plc> only enumerates "<Plc> Instance" on 4024/4026; the "<Plc> Project" node
        (with POUs / DUTs / GVLs) is looked up by path and added to the PLC node's children.
    .PARAMETER Depth
        Number of levels below each root node (1-10, default 4). 4 reaches the POUs:
        TIPC(0)^plc(1)^plc Project(2)^POUs(3)^<POU>(4).
    .PARAMETER PlcOnly
        Return only the TIPC (PLC) subtree instead of TIPC, TIID, TIRS and TIRC.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(1, 10)]
        [int]$Depth = 4,

        [Parameter()]
        [switch]$PlcOnly
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    $maxDepth = $Depth

    function Read-TreeItem {
        param($item, [int]$depth = 0)

        if ($depth -gt $maxDepth) { return $null }

        $itemName = try { [string]$item.Name } catch { 'unknown' }
        $itemPath = try { [string]$item.PathName } catch { '' }
        $itemTypeNum = try { [int]$item.ItemType } catch { -1 }
        $subTypeNum = try { [int]$item.ItemSubType } catch { -1 }
        if ($script:TcPlcItemTypeNames.ContainsKey($itemTypeNum)) { $typeName = $script:TcPlcItemTypeNames[$itemTypeNum] }
        elseif ($subTypeNum -gt 0) { $typeName = "$itemTypeNum/$subTypeNum" }
        else { $typeName = [string]$itemTypeNum }

        $node = [PSCustomObject]@{
            name     = $itemName
            path     = $itemPath
            type     = $typeName
            itemType = $itemTypeNum
            subType  = $subTypeNum
            children = @()
        }

        $childCount = 0
        try { $childCount = [int]$item.ChildCount } catch { $childCount = 0 }

        if ($depth -ge $maxDepth) {
            if ($childCount -gt 0) {
                $node | Add-Member -NotePropertyName 'truncated' -NotePropertyValue $true
            }
            return $node
        }

        $kids = @()
        for ($i = 1; $i -le $childCount; $i++) {
            try {
                $child = $item.Child($i)
                $childNode = Read-TreeItem -item $child -depth ($depth + 1)
                if ($null -ne $childNode) { $kids += $childNode }
            }
            catch { continue }
        }
        $node.children = $kids
        $node
    }

    try {
        if ($PlcOnly) { $sections = @('TIPC') }
        else { $sections = @('TIPC', 'TIID', 'TIRS', 'TIRC') }
        $tree = @()

        foreach ($section in $sections) {
            $sectionNode = $null
            try {
                $sectionNode = Invoke-TcComRetry -OperationName "Read tree $section" -ScriptBlock {
                    $sectionItem = $sm.LookupTreeItem($section)
                    Read-TreeItem -item $sectionItem -depth 0
                }
            }
            catch {
                if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
                continue
            }
            if ($null -eq $sectionNode) { continue }

            # Graft "<Plc> Project" under each PLC node (hidden from TIPC^<Plc> enumeration).
            if ($section -eq 'TIPC' -and $maxDepth -ge 2) {
                foreach ($plc in @($sectionNode.children)) {
                    $projPath = "TIPC^$($plc.name)^$($plc.name) Project"
                    $projName = "$($plc.name) Project"
                    $already = @($plc.children | Where-Object { $_.name -eq $projName }).Count -gt 0
                    if ($already) { continue }
                    $projNode = $null
                    try {
                        $projNode = Invoke-TcComRetry -OperationName "Read tree $projPath" -ScriptBlock {
                            $projItem = $sm.LookupTreeItem($projPath)
                            if ($null -ne $projItem) { Read-TreeItem -item $projItem -depth 2 }
                        }
                    }
                    catch {
                        if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
                        Write-Verbose "LookupTreeItem('$projPath') failed: $($_.Exception.Message)"
                        $projNode = $null
                    }
                    if ($null -ne $projNode) {
                        $plc.children = @($plc.children) + @($projNode)
                    }
                }
            }

            $tree += $sectionNode
        }

        # (,$tree): keep data an array also when only one section (-PlcOnly) was read
        New-TcResult -Success $true -Data (,$tree)
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to read project tree: $_" -ErrorCode 'TREE_READ_FAILED'
    }
}
