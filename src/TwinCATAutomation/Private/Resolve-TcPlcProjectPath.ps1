function Resolve-TcPlcProjectPath {
    <#
    .SYNOPSIS
        Finds the tree path of the PLC Project node ("TIPC^<Plc>^<Plc> Project").
    .DESCRIPTION
        Shared by Enter-TcPlcOnline / Exit-TcPlcOnline. Strategy 1 builds the path from the
        first PLC node name and resolves it with LookupTreeItem (works even after a TwinCAT
        restart, when child enumeration may hide the Project node). Strategy 2 enumerates the
        PLC node's children for a name containing "Project".
        Returns the path string, or throws with a PLC_PROJECT_NOT_FOUND message.
    .PARAMETER SysManager
        ITcSysManager object (from Get-TcSysManager).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager
    )

    $sm = $SysManager
    $plcNode = Invoke-TcComRetry -OperationName 'LookupTreeItem TIPC' -ScriptBlock {
        $tipc = $sm.LookupTreeItem('TIPC')
        Write-Output -NoEnumerate $tipc.Child(1)
    }
    $plcName = Invoke-TcComRetry -OperationName 'PLC node name' -ScriptBlock { $plcNode.Name }

    # Strategy 1: direct LookupTreeItem with constructed path
    $candidatePath = "TIPC^${plcName}^${plcName} Project"
    try {
        $projItem = Invoke-TcComRetry -OperationName "LookupTreeItem $candidatePath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($candidatePath) }
        if ($null -ne $projItem) {
            Write-Verbose "PLC project found via LookupTreeItem: $candidatePath"
            return $candidatePath
        }
    }
    catch {
        if ($_.Exception.Message -match 'IDE_BUSY') { throw }
        Write-Verbose "LookupTreeItem('$candidatePath') failed: $_"
    }

    # Strategy 2: enumerate children for "Project"
    $found = Invoke-TcComRetry -OperationName 'Enumerate PLC children' -ScriptBlock {
        $hit = $null
        for ($i = 1; $i -le $plcNode.ChildCount; $i++) {
            $child = $plcNode.Child($i)
            if ($child.Name -match 'Project') {
                $hit = $child.PathName
                break
            }
        }
        $hit
    }
    if (-not [string]::IsNullOrWhiteSpace($found)) {
        Write-Verbose "PLC project found via enumeration: $found"
        return $found
    }

    $childNames = @()
    $plcNodePath = ''
    try {
        $childInfo = Invoke-TcComRetry -OperationName 'List PLC children' -ScriptBlock {
            $names = @()
            for ($i = 1; $i -le $plcNode.ChildCount; $i++) { $names += $plcNode.Child($i).Name }
            @{ Names = $names; Path = $plcNode.PathName }
        }
        $childNames = $childInfo.Names
        $plcNodePath = $childInfo.Path
    }
    catch { }
    throw "PLC_PROJECT_NOT_FOUND: Could not find PLC Project node. Tried: '$candidatePath'. Children of ${plcNodePath}: $($childNames -join ', ')"
}
