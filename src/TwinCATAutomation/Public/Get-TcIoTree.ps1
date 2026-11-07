function Get-TcIoTree {
    <#
    .SYNOPSIS
        Reads the current I/O device tree (TIID subtree) and returns as JSON. Every node has name, path, disabled, disabledState and children; disabledState is the ITcSmTreeItem.Disabled DISABLED_STATE name (SMDS_NOT_DISABLED / SMDS_DISABLED / SMDS_PARENT_DISABLED), disabled is true for the last two, both null when Disabled cannot be read.
    .DESCRIPTION
        disabled / disabledState: Get-TcTreeItemDisabledState (#172). DISABLED_STATE values: InfoSys
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842771467.html.

        Every path appears once (#177): an EtherCAT device's Child(i) also returns the terminals
        below a coupler (measured 2026-11-08, 4024 TcXaeShell 32-bit, BFH-1650: Device 1 ChildCount 9 =
        EK1200 + its 8 terminals). The children of a node are Get-TcTreeItemDirectChild (shared with
        LookupTreeItem, #182): a child is listed only under the node its PathName names as parent
        (PathName without its last '^' segment); a child without a readable PathName is kept. When the
        node's own PathName cannot be read (TIID is assumed for the root), only the children with the
        fewest path segments are kept (Get-TcTreeItemDirectChild rule 3). A path already listed elsewhere in the tree is skipped.
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    $seenPaths = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    function Read-IoItem {
        param($item, [int]$depth = 0)
        if ($depth -gt 8) { return $null }

        $itemName = try { $item.Name } catch { 'unknown' }
        $itemPath = try { [string]$item.PathName } catch { '' }
        $parentPath = if ($itemPath) { $itemPath } elseif ($depth -eq 0) { 'TIID' } else { '' }
        if ($itemPath -and -not $seenPaths.Add($itemPath)) { return $null }

        $dis = Get-TcTreeItemDisabledState -Item $item

        $node = [PSCustomObject]@{
            name          = $itemName
            path          = $itemPath
            disabled      = $dis.disabled
            disabledState = $dis.disabledState
            children      = @()
        }

        try {
            foreach ($k in (Get-TcTreeItemDirectChild -Item $item -ParentPath $parentPath)) {
                $childNode = Read-IoItem -item $k.Item -depth ($depth + 1)
                if ($null -ne $childNode) { $node.children += $childNode }
            }
        }
        catch { }

        $node
    }

    try {
        $ioDevices = $sm.LookupTreeItem('TIID')
        $tree = Read-IoItem -item $ioDevices
        New-TcResult -Success $true -Data $tree
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to read I/O tree: $_" -ErrorCode 'IO_TREE_FAILED'
    }
}
