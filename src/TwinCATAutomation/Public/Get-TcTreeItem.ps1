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
        item types), childCount, children[] (name, path, itemType, subType, type), childrenTruncated.
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
            $kids = [System.Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le $s.childCount -and $kids.Count -lt $MaxChildren; $i++) {
                try {
                    $c = $item.Child($i)
                    if ($null -eq $c) { continue }
                    $cs = Get-TcTreeItemSummary -Item $c
                    $kids.Add([PSCustomObject]@{ name = $cs.name; path = $cs.path; itemType = $cs.itemType; subType = $cs.subType; type = $cs.type })
                }
                catch {
                    if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
                    continue
                }
            }
            [PSCustomObject]@{ Summary = $s; Children = $kids.ToArray() }
        }
        $s = $info.Summary
        $out = [PSCustomObject]@{
            name              = $s.name
            path              = if ([string]::IsNullOrWhiteSpace($s.path)) { $Path } else { $s.path }
            itemType          = $s.itemType
            subType           = $s.subType
            subTypeName       = $s.subTypeName
            type              = $s.type
            childCount        = $s.childCount
            children          = @($info.Children)
            childrenTruncated = ($s.childCount -gt @($info.Children).Count)
        }
        New-TcResult -Success $true -Data $out
    }
    catch {
        New-TcTreeItemErrorResult -ErrorRecord $_ -DefaultCode 'TREEITEM_READ_FAILED' -Data $data -Operation "LookupTreeItem '$Path'"
    }
}
