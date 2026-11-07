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
    602 = 'Program'              # TE1000 v1.7.0 6.5.5; measured 4026 2026-10-31 (MAIN, TestCam = PROGRAM)
    603 = 'Function'
    604 = 'FunctionBlock'
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
        TIID section (#186): each node lists only its direct children (Get-TcTreeItemDirectChild,
        shared with GetIoTree / LookupTreeItem). ITcSmTreeItem.Child(i) of an EtherCAT device also
        returns the terminals below a coupler, so a plain Child(i) walk listed them twice: below the
        coupler and again flattened below the device (measured 2026-11-08, 4024 TcXaeShell 32-bit,
        BFH-1650: Device 1 (EtherCAT) = Term 7 (EK1200) with its 8 terminals plus the same 8 again).
        TIPC / TIRS / TIRC keep the plain Child(i) walk: no flattening observed there (measured
        2026-11-08, 4024 TcXaeShell 32-bit, BFH-1650: TIPC tree identical before/after #186).
        Fail closed in every section: a busy / dead-RPC COM error while reading children is retried
        for the whole section (Invoke-TcComRetry) and then fails the call (IDE_BUSY / IDE_CRASHED /
        IDE_MODAL_DIALOG / IDE_TIMEOUT), never a tree with nodes missing.
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
        # $walkPath: the path the caller used to reach $item (TIID section only; used as the parent
        # path when PathName cannot be read). $directOnly: list only the direct children (#186).
        param($item, [int]$depth = 0, [string]$walkPath = '', [bool]$directOnly = $false)

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
        if ($directOnly) {
            # TIID (#186): Child(i) of an EtherCAT device also returns the terminals below a coupler
            # (measured 2026-11-08, 4024 TcXaeShell 32-bit, BFH-1650), so keep only the children whose
            # PathName names this node as parent. Busy / dead RPC must reach Invoke-TcComRetry: a
            # swallowed error would return success with the node's children missing (#184 review).
            # PowerShell variable names are case-insensitive: $own must not be named $parentPath.
            $own = if ($itemPath) { $itemPath } else { $walkPath }
            try {
                foreach ($k in (Get-TcTreeItemDirectChild -Item $item -ParentPath $own)) {
                    $childWalk = [string]$k.Path
                    if (-not $childWalk -and $own) {
                        $childName = try { [string]$k.Item.Name } catch { '' }
                        if ($childName) { $childWalk = "$own^$childName" }
                    }
                    $childNode = Read-TreeItem -item $k.Item -depth ($depth + 1) -walkPath $childWalk -directOnly $true
                    if ($null -ne $childNode) { $kids += $childNode }
                }
            }
            catch {
                if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
            }
        }
        else {
            # TIPC / TIRS / TIRC: plain Child(i). No flattening observed there (measured 2026-11-08,
            # 4024 TcXaeShell 32-bit, BFH-1650: TIPC tree identical before/after #186). The PathName
            # parent rule of the TIID branch was not measured on these sections, so Child(i) is kept
            # as the conservative choice. Busy / dead RPC is rethrown (fail closed, as in TIID).
            for ($i = 1; $i -le $childCount; $i++) {
                try {
                    $child = $item.Child($i)
                    $childNode = Read-TreeItem -item $child -depth ($depth + 1)
                    if ($null -ne $childNode) { $kids += $childNode }
                }
                catch {
                    if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
                    continue
                }
            }
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
                    Read-TreeItem -item $sectionItem -depth 0 -walkPath $section -directOnly ($section -eq 'TIID')
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
        # IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT keep their own code (as GetIoTree, #186).
        $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
        if ($null -ne $mapped -and @('IDE_BUSY', 'IDE_CRASHED', 'IDE_MODAL_DIALOG', 'IDE_TIMEOUT') -contains $mapped.Code) {
            return New-TcResult -Success $false -ErrorMessage "Failed to read project tree: $($_.Exception.Message)" -ErrorCode $mapped.Code -Hint $mapped.Hint
        }
        New-TcResult -Success $false -ErrorMessage "Failed to read project tree: $_" -ErrorCode 'TREE_READ_FAILED'
    }
}
