function Get-TcTreeItem {
    <#
    .SYNOPSIS
        Looks up one tree item by its full path (LookupTreeItem) and returns name, type and direct children. Read-only.
    .DESCRIPTION
        Generic tree tool (MCP LookupTreeItem). ITcSysManager::LookupTreeItem (TE1000 Automation
        Interface manual v1.7.0, 5.1.1.3, p.38): the path is the full tree path separated by '^', e.g.
        TIRT^PlcTask, TIPC^MyPlc^MyPlc Project^POUs^MAIN, TIID^Device 1 (EtherCAT). Wildcards are not
        accepted (TREEITEM_PATH_INVALID).
        data: name, path (PathName), itemType, subType, subTypeName, type (readable name for known PLC
        item types), disabled, disabledState, childCount, children[] (name, path, itemType, subType,
        type, disabled, disabledState), childrenTruncated, childrenUnreadable.
        childCount and children[] are the DIRECT children only (#182; Get-TcTreeItemDirectChild): Child(i)
        of an EtherCAT device also returns the terminals below a coupler (measured 2026-11-08, 4024
        BFH-1650: ITcSmTreeItem.ChildCount 9 for Device 1 = EK1200 + its 8 terminals; childCount is 1).
        childrenTruncated: children has fewer entries than childCount (more than -MaxChildren, or a child
        could not be read). childrenUnreadable: number of Child(i) that could not be read (counted in
        childCount: they cannot be placed, so they may be direct children); -1 when ChildCount itself
        could not be read. A busy / dead-RPC COM error of Child(i) is never counted here: it is retried
        and then reported as IDE_BUSY / IDE_CRASHED (#184 review).
        disabledState is the ITcSmTreeItem.Disabled DISABLED_STATE name (SMDS_NOT_DISABLED /
        SMDS_DISABLED / SMDS_PARENT_DISABLED, InfoSys
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842771467.html); disabled is
        $true for the last two. Both $null when Disabled cannot be read (#172).
        A missing path returns TREEITEM_NOT_FOUND; error.hint and data.nearestPath / nearestChildren
        name the nearest existing parent and its children.
        Prefer the dedicated tools (GetProjectTree, GetIoTree, GetPouCode) when they cover the node.
    .PARAMETER Path
        Full tree path, e.g. "TIRT^PlcTask" or "TIPC^MyPlc^MyPlc Project^POUs". No wildcards.
    .PARAMETER MaxChildren
        Maximum number of children listed (1-1000, default 200).
    .EXAMPLE
        Get-TcTreeItem -Path 'TIRT'
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter()]
        [ValidateRange(1, 1000)]
        [int]$MaxChildren = 200
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $data = [PSCustomObject]@{ path = $Path }
    try {
        $r = Resolve-TcTreeItem -SysManager $sm -Path $Path -Data $data
        if ($null -ne $r.Result) { return $r.Result }
        $item = $r.Item
        $info = Invoke-TcComRetry -OperationName "Read tree item $Path" -ScriptBlock {
            $s = Get-TcTreeItemSummary -Item $item
            # Direct children only (#182): Child(i) of an EtherCAT device also returns the terminals below
            # a coupler. The resolved -Path is the parent path when PathName cannot be read.
            $parentPath = if ([string]::IsNullOrWhiteSpace($s.path)) { $Path } else { $s.path }
            $stats = @{}
            $direct = @(Get-TcTreeItemDirectChild -Item $item -ParentPath $parentPath -Stats $stats)
            $unreadable = [int]$stats['Unreadable']
            $kids = [System.Collections.Generic.List[object]]::new()
            foreach ($k in $direct) {
                if ($kids.Count -ge $MaxChildren) { break }
                try {
                    $cs = Get-TcTreeItemSummary -Item $k.Item
                    $kids.Add([PSCustomObject]@{ name = $cs.name; path = $cs.path; itemType = $cs.itemType; subType = $cs.subType; type = $cs.type; disabled = $cs.disabled; disabledState = $cs.disabledState })
                }
                catch {
                    if (Test-TcComMustRethrow -ErrorRecord $_) { throw }
                    continue
                }
            }
            $s.childCount = $direct.Count + $unreadable
            if ($stats['ChildCountUnreadable']) { $unreadable = -1 }
            [PSCustomObject]@{ Summary = $s; Children = $kids.ToArray(); Unreadable = $unreadable }
        }
        $s = $info.Summary
        $out = [PSCustomObject]@{
            name              = $s.name
            path              = if ([string]::IsNullOrWhiteSpace($s.path)) { $Path } else { $s.path }
            itemType          = $s.itemType
            subType           = $s.subType
            subTypeName       = $s.subTypeName
            type              = $s.type
            disabled          = $s.disabled
            disabledState     = $s.disabledState
            childCount        = $s.childCount
            children          = @($info.Children)
            childrenTruncated = (($s.childCount -gt @($info.Children).Count) -or ($info.Unreadable -ne 0))
            childrenUnreadable = $info.Unreadable
        }
        New-TcResult -Success $true -Data $out
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_READ_FAILED' -Data $data -Operation "LookupTreeItem '$Path'"
    }
}
