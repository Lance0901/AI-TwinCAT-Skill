function Get-TcIoTree {
    <#
    .SYNOPSIS
        Reads the current I/O device tree (TIID subtree) and returns as JSON.
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

    function Read-IoItem {
        param($item, [int]$depth = 0)
        if ($depth -gt 8) { return $null }

        $node = [PSCustomObject]@{
            name     = try { $item.Name } catch { 'unknown' }
            path     = try { $item.PathName } catch { '' }
            children = @()
        }

        try {
            for ($i = 1; $i -le $item.ChildCount; $i++) {
                $child = $item.Child($i)
                $childNode = Read-IoItem -item $child -depth ($depth + 1)
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
