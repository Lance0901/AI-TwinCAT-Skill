function Get-TcProjectTree {
    <#
    .SYNOPSIS
        Reads and returns the full TwinCAT project structure as a JSON tree.
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    function Read-TreeItem {
        param($item, [int]$depth = 0)

        if ($depth -gt 10) { return $null }

        $itemName = try { $item.Name } catch { 'unknown' }
        $itemPath = try { $item.PathName } catch { '' }
        $itemType = try { $item.ItemSubType.ToString() } catch { '' }

        $node = [PSCustomObject]@{
            name     = $itemName
            path     = $itemPath
            type     = $itemType
            children = @()
        }

        try {
            $childCount = $item.ChildCount
            for ($i = 1; $i -le $childCount; $i++) {
                try {
                    $child = $item.Child($i)
                    $childNode = Read-TreeItem -item $child -depth ($depth + 1)
                    if ($null -ne $childNode) {
                        $node.children += $childNode
                    }
                }
                catch { continue }
            }
        }
        catch { }

        $node
    }

    try {
        # Read main tree sections
        $sections = @('TIPC', 'TIID', 'TIRS', 'TIRC')
        $tree = @()

        foreach ($section in $sections) {
            try {
                $item = $sm.LookupTreeItem($section)
                $tree += Read-TreeItem -item $item
            }
            catch { continue }
        }

        New-TcResult -Success $true -Data $tree
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to read project tree: $_" -ErrorCode 'TREE_READ_FAILED'
    }
}
