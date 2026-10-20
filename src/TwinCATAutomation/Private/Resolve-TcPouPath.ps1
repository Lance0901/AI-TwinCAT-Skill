function Resolve-TcPouPath {
    <#
    .SYNOPSIS
        Finds a POU (or DUT/GVL) tree item by explicit path or by name.
    .DESCRIPTION
        Order:
          1. -PouPath (when given): LookupTreeItem(PouPath)                    ResolvedBy = 'explicit'
          2. "<Plc Project>^POUs^<Name>"                                        ResolvedBy = 'pous-folder'
          3. "<Plc Project>^<Name>"                                             ResolvedBy = 'project-root'
          4. depth-first search below "<Plc Project>" (ChildCount/Child(i)),
             depth <= -MaxDepth (direct children of the project = depth 1),
             first item whose Name equals -Name (case-insensitive)              ResolvedBy = 'tree-search'
        The project node path comes from Resolve-TcPlcProjectPath (works on 4024 and 4026,
        where TIPC^<Plc> only enumerates "<Plc> Instance"). Its PLC_PROJECT_NOT_FOUND
        exception is passed on. IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT
        are always rethrown; any other lookup failure counts as "not found here".
        Returns @{ Found; Item; Path; ResolvedBy; ProjectPath; Tried; ProjectChildren }.
    .PARAMETER SysManager
        ITcSysManager object (from Get-TcSysManager).
    .PARAMETER Name
        POU name.
    .PARAMETER PouPath
        Optional full tree path, e.g. TIPC^plc^plc Project^POUs^MAIN.
    .PARAMETER MaxDepth
        Depth limit of the tree search below the project node. Default 4.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$PouPath,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxDepth = 4
    )

    $sm = $SysManager
    $ideErrorPattern = 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT'
    $result = @{
        Found           = $false
        Item            = $null
        Path            = $null
        ResolvedBy      = $null
        ProjectPath     = $null
        Tried           = [string[]]@()
        ProjectChildren = [string[]]@()
    }
    $tried = New-Object System.Collections.Generic.List[string]

    # 1. explicit path
    if (-not [string]::IsNullOrWhiteSpace($PouPath)) {
        $item = $null
        try {
            $item = Invoke-TcComRetry -OperationName "LookupTreeItem $PouPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($PouPath) }
        }
        catch {
            if ($_.Exception.Message -match $ideErrorPattern) { throw }
            Write-Verbose "LookupTreeItem('$PouPath') failed: $($_.Exception.Message)"
            $item = $null
        }
        if ($null -ne $item) {
            $result.Found = $true
            $result.Item = $item
            $result.Path = $PouPath
            $result.ResolvedBy = 'explicit'
            $result.Tried = [string[]]@($PouPath)
            return $result
        }
        $tried.Add($PouPath)
    }

    # PLC_PROJECT_NOT_FOUND is thrown from here and passed on to the caller.
    $projPath = Resolve-TcPlcProjectPath -SysManager $sm
    $result.ProjectPath = $projPath

    # 2./3. direct lookups
    $candidates = @(
        @{ Path = "$projPath^POUs^$Name"; By = 'pous-folder' },
        @{ Path = "$projPath^$Name"; By = 'project-root' }
    )
    foreach ($cand in $candidates) {
        $candPath = $cand.Path
        $item = $null
        try {
            $item = Invoke-TcComRetry -OperationName "LookupTreeItem $candPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($candPath) }
        }
        catch {
            if ($_.Exception.Message -match $ideErrorPattern) { throw }
            Write-Verbose "LookupTreeItem('$candPath') failed: $($_.Exception.Message)"
            $item = $null
        }
        if ($null -ne $item) {
            $tried.Add($candPath)
            # canonical casing from the item itself (the candidate uses -Name as typed)
            $canonical = $null
            try { $canonical = [string]$item.PathName } catch { $canonical = $null }
            $result.Found = $true
            $result.Item = $item
            $result.Path = if ([string]::IsNullOrWhiteSpace($canonical)) { $candPath } else { $canonical }
            $result.ResolvedBy = $cand.By
            $result.Tried = [string[]]$tried.ToArray()
            return $result
        }
        $tried.Add($candPath)
    }

    # 4. tree search below the project node (one COM round trip set)
    $search = Invoke-TcComRetry -OperationName "Search tree for $Name" -ScriptBlock {
        $__root = $sm.LookupTreeItem($projPath)
        $__names = New-Object System.Collections.Generic.List[string]
        $__hit = $null
        $__hitPath = $null

        $__rootCount = 0
        try { $__rootCount = [int]$__root.ChildCount } catch { $__rootCount = 0 }
        $__level1 = New-Object System.Collections.Generic.List[object]
        for ($__i = 1; $__i -le $__rootCount; $__i++) {
            try {
                $__c = $__root.Child($__i)
                $__names.Add([string]$__c.Name)
                $__level1.Add($__c)
            }
            catch { continue }
        }

        # iterative DFS, children pushed in reverse so the first child is visited first
        $__stack = New-Object System.Collections.Stack
        for ($__i = $__level1.Count - 1; $__i -ge 0; $__i--) {
            $__stack.Push([PSCustomObject]@{ Item = $__level1[$__i]; Depth = 1 })
        }
        while ($__stack.Count -gt 0) {
            $__e = $__stack.Pop()
            $__it = $__e.Item
            $__nm = $null
            try { $__nm = [string]$__it.Name } catch { $__nm = $null }
            if ($null -ne $__nm -and $__nm -eq $Name) {
                $__hit = $__it
                try { $__hitPath = [string]$__it.PathName } catch { $__hitPath = $null }
                break
            }
            if ($__e.Depth -ge $MaxDepth) { continue }
            $__cnt = 0
            try { $__cnt = [int]$__it.ChildCount } catch { $__cnt = 0 }
            for ($__j = $__cnt; $__j -ge 1; $__j--) {
                try { $__stack.Push([PSCustomObject]@{ Item = $__it.Child($__j); Depth = ($__e.Depth + 1) }) }
                catch { continue }
            }
        }
        @{ Hit = $__hit; HitPath = $__hitPath; Names = [string[]]$__names.ToArray() }
    }

    $result.ProjectChildren = [string[]]@($search.Names)
    if ($null -ne $search.Hit) {
        $result.Found = $true
        $result.Item = $search.Hit
        $result.Path = $search.HitPath
        $result.ResolvedBy = 'tree-search'
        $result.Tried = [string[]]$tried.ToArray()
        return $result
    }

    $tried.Add("$projPath (tree search, depth $MaxDepth)")
    $result.Tried = [string[]]$tried.ToArray()
    return $result
}

function New-TcPouNotFoundResult {
    <#
    .SYNOPSIS
        Builds the POU_NOT_FOUND result from a Resolve-TcPouPath resolution.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Resolution
    )

    $tried = @($Resolution.Tried)
    $children = @($Resolution.ProjectChildren)
    $hint = Get-TcErrorHint -Code 'POU_NOT_FOUND'
    if ($children.Count -gt 0) {
        # file is UTF-8 with BOM (Windows PowerShell 5.1 reads BOM-less files as ANSI)
        $hint = "$hint。$($Resolution.ProjectPath) 第一層子節點:$($children -join ', ')"
    }
    New-TcResult -Success $false -ErrorCode 'POU_NOT_FOUND' `
        -ErrorMessage "POU '$Name' not found. Tried: $($tried -join '; ')" `
        -Hint $hint `
        -Data ([PSCustomObject]@{
            pou             = $Name
            projectPath     = $Resolution.ProjectPath
            tried           = [string[]]$tried
            projectChildren = [string[]]$children
        })
}
