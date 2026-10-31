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
        With -RequireSingle (Enter-TcPlcOnline / Exit-TcPlcOnline) a solution with more than
        one PLC project throws PLC_PROJECT_AMBIGUOUS instead of silently taking the first
        one: logging in / out of the wrong PLC reports success for the other PLC (#32).
    .PARAMETER SysManager
        ITcSysManager object (from Get-TcSysManager).
    .PARAMETER RequireSingle
        Throw PLC_PROJECT_AMBIGUOUS (listing the candidates) when TIPC has more than one PLC.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager,

        [Parameter()]
        [switch]$RequireSingle
    )

    $sm = $SysManager
    if ($RequireSingle) {
        $all = @(Get-TcPlcProjectList -SysManager $sm)
        # disabled PLCs (ITcSmTreeItem.Disabled) are not candidates
        $plcs = @($all | Where-Object { -not $_.disabled })
        if ($plcs.Count -eq 1 -and $all.Count -gt 1) { return $plcs[0].projectPath }
        if ($plcs.Count -gt 1) {
            $names = ($plcs | ForEach-Object { "'$($_.projectPath)' (port $($_.adsPort))" }) -join ', '
            throw "PLC_PROJECT_AMBIGUOUS: the solution has $($plcs.Count) PLC projects; pass -PlcProjectPath (PLC name or tree path). Candidates: $names"
        }
    }
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
        if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED') { throw }
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

function Resolve-TcPlcProjectSpec {
    <#
    .SYNOPSIS
        -PlcProjectPath of a cmdlet -> '<Plc> Project' tree path: @{ Result = $null | <failed result>; PlcProjectPath; PlcProjects }.
    .DESCRIPTION
        Empty: the single PLC project (Resolve-TcPlcProjectPath -RequireSingle), else
        PLC_PROJECT_NOT_FOUND / PLC_PROJECT_AMBIGUOUS (data.plcProjects). A PLC name or tree path is
        looked up with Find-TcPlcProject (name, 'TIPC^<Plc>' or 'TIPC^<Plc>^<Plc> Project'); not
        found -> PLC_PROJECT_NOT_FOUND. Other errors are thrown (the caller's catch maps them).
        Shared by the Library Manager cmdlets (Resolve-TcLibraryManager), Test-TcPlcProject and the
        PLC task cmdlets.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER PlcProjectPath
        PLC name or tree path; empty = the only PLC project.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$SysManager,
        [Parameter()][string]$PlcProjectPath
    )
    $plcList = @(Get-TcPlcProjectList -SysManager $SysManager)
    if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
        try { $p = Resolve-TcPlcProjectPath -SysManager $SysManager -RequireSingle }
        catch {
            if ($_.Exception.Message -match '^(PLC_PROJECT_NOT_FOUND|PLC_PROJECT_AMBIGUOUS)') {
                $code = $Matches[1]
                return @{ PlcProjectPath = $null; PlcProjects = $plcList; Result = (New-TcResult -Success $false -ErrorMessage ($_.Exception.Message -replace '^PLC_PROJECT_[A-Z_]+:\s*', '') `
                            -ErrorCode $code -Hint (Get-TcErrorHint -Code $code) -Data ([PSCustomObject]@{ plcProjects = $plcList })) }
            }
            throw
        }
        return @{ Result = $null; PlcProjectPath = $p; PlcProjects = $plcList }
    }
    $plcEntry = Find-TcPlcProject -List $plcList -Spec $PlcProjectPath
    if ($null -eq $plcEntry) {
        return @{ PlcProjectPath = $null; PlcProjects = $plcList; Result = (New-TcResult -Success $false `
                    -ErrorMessage "PLC project '$PlcProjectPath' not found. PLC projects: $(($plcList | ForEach-Object { $_.projectPath }) -join ', ')" `
                    -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND') `
                    -Data ([PSCustomObject]@{ plcProjects = $plcList })) }
    }
    return @{ Result = $null; PlcProjectPath = [string]$plcEntry.projectPath; PlcProjects = $plcList }
}
