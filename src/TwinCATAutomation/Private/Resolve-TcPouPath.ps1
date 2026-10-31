function Resolve-TcPouPath {
    <#
    .SYNOPSIS
        Finds a POU (or DUT/GVL/member) tree item by explicit path or by name.
    .DESCRIPTION
        Order:
          1. -PouPath (when given): LookupTreeItem(PouPath)                    ResolvedBy = 'explicit'
             not found and its LAST segment has a '.': that segment's dots become '^'
             (TIPC^..^POUs^FB_X.M_Run -> ...^POUs^FB_X^M_Run)                ResolvedBy = 'explicit-dot'
          2. "<Plc Project>^POUs^<Name>"                                        ResolvedBy = 'pous-folder'
          3. "<Plc Project>^<Name>"                                             ResolvedBy = 'project-root'
             -Name with a '.' (FB_X.M_Run): also "<Plc Project>^POUs^FB_X^M_Run" and
             "<Plc Project>^FB_X^M_Run", still before the tree walk           ResolvedBy = 'dot-path'
          4. depth-first search below "<Plc Project>" (ChildCount/Child(i)),
             depth <= -MaxDepth (direct children of the project = depth 1),
             every item whose Name equals -Name (case-insensitive)              ResolvedBy = 'tree-search'
             One hit: found. Several hits: hits whose ItemType is known and not a code object
             (folder, task reference 650 ...) are dropped, an unreadable ItemType (-1) stays;
             one left: found; still several: Ambiguous = $true and Candidates = their paths
             (POU_AMBIGUOUS, never the first one). A hit is not searched further down: when a
             folder and an object below it have the same name, only the folder is returned
             (known limit). Paths are built as <parent>^<Name>; PathName is read only for hits.
          ITF property accessors (ItemType 654 / 655): ItemType is read first and their PathName
          is never read (the built path is used); Get-TcPouCode / Write-TcPouCode then refuse them.
          5. -Name with a '.' and still not found (task 3.6): "FB_X.M_Run" / "FB_X.P_Value.Get" ->
             the part before the first '.' is resolved by steps 2-4, the rest is appended with '^'
             (<FB_X path>^M_Run, <FB_X path>^P_Value^Get)                       ResolvedBy = 'dot-path'
             When FB_X itself is ambiguous, the candidates that have the member decide (one:
             found; several: Ambiguous). The original string is always tried first, because a
             folder name may contain a '.' (POU names cannot: IEC identifiers).
        The project node path comes from Resolve-TcPlcProjectPath (works on 4024 and 4026,
        where TIPC^<Plc> only enumerates "<Plc> Instance"). Its PLC_PROJECT_NOT_FOUND
        exception is passed on. IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT
        are always rethrown; any other lookup failure counts as "not found here".
        Same-name members (M_Run in two function blocks, Get of two properties) were returned
        silently as the first hit before (measured 2026-10-31 4026 VS2022, self-built client,
        verification/phase2-probe.md 3.6); the tree search now walks the whole depth instead of
        stopping at the first hit.
        Returns @{ Found; Item; Path; ResolvedBy; ProjectPath; Tried; ProjectChildren; Ambiguous;
        Candidates }.
    .PARAMETER SysManager
        ITcSysManager object (from Get-TcSysManager).
    .PARAMETER Name
        POU name, or Parent.Member (FB_X.M_Run, FB_X.P_Value.Get).
    .PARAMETER PouPath
        Optional full tree path, e.g. TIPC^plc^plc Project^POUs^MAIN.
    .PARAMETER MaxDepth
        Depth limit of the tree search below the project node. Default 4.
    .PARAMETER NoDotPath
        Internal: skip step 5 (used for the part before the '.').
    .PARAMETER ProjectPath
        Optional '<Plc> Project' tree path to search instead of Resolve-TcPlcProjectPath (the first
        PLC); Add-TcTaskProgram passes the PLC its -PlcProjectPath resolved to.
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
        [int]$MaxDepth = 4,

        [Parameter()]
        [switch]$NoDotPath,

        [Parameter()]
        [string]$ProjectPath
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
        Ambiguous       = $false
        Candidates      = [string[]]@()
    }
    $tried = [System.Collections.Generic.List[string]]::new()
    # LookupTreeItem that returns $null for "not there" (IDE_* rethrown)
    $lookup = {
        param([string]$__p)
        try { Invoke-TcComRetry -OperationName "LookupTreeItem $__p" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($__p) } }
        catch {
            if ($_.Exception.Message -match $ideErrorPattern) { throw }
            Write-Verbose "LookupTreeItem('$__p') failed: $($_.Exception.Message)"
            $null
        }
    }
    $found = {
        param($__item, [string]$__path, [string]$__by)
        $result.Found = $true
        $result.Item = $__item
        $result.Path = $__path
        $result.ResolvedBy = $__by
        $result.Tried = [string[]]$tried.ToArray()
        $result
    }

    # 1. explicit path (1b: dots of its last segment as '^')
    if (-not [string]::IsNullOrWhiteSpace($PouPath)) {
        $item = & $lookup $PouPath
        $tried.Add($PouPath)
        if ($null -ne $item) {
            $result.Tried = [string[]]@($PouPath)
            return (& $found $item $PouPath 'explicit')
        }
        $cut = $PouPath.LastIndexOf('^')
        $last = $PouPath.Substring($cut + 1)
        if ($last.Contains('.') -and $last -notmatch '(^|\.)\s*(\.|$)') {
            $alt = $PouPath.Substring(0, $cut + 1) + ($last -replace '\.', '^')
            $item = & $lookup $alt
            $tried.Add($alt)
            if ($null -ne $item) { return (& $found $item $alt 'explicit-dot') }
        }
    }

    # PLC_PROJECT_NOT_FOUND is thrown from here and passed on to the caller.
    $projPath = if ([string]::IsNullOrWhiteSpace($ProjectPath)) { Resolve-TcPlcProjectPath -SysManager $sm } else { $ProjectPath }
    $result.ProjectPath = $projPath
    # ItemType of a found item before anything else: PathName (or code) of an ITF property
    # accessor (654 / 655) is never read (DeclarationText of a 654 crashed VS2022, measured
    # 2026-10-31 4026 VS2022, self-built client; see Private/PouMember.ps1)
    $isItfAccessor = {
        param($__i)
        $__t = -1
        try { $__v = Invoke-TcComRetry -OperationName 'ItemType' -ScriptBlock { $__i.ItemType }; if ($null -ne $__v -and -not [string]::IsNullOrWhiteSpace([string]$__v)) { $__t = [int]$__v } }
        catch {
            if ($_.Exception.Message -match $ideErrorPattern) { throw }
            $__t = -1
        }
        $script:TcItfAccessorItemTypes -contains $__t
    }
    # canonical casing from the item itself (the candidate uses -Name as typed); the built path
    # for an ITF property accessor
    $pathOf = {
        param($__i, [string]$__built)
        if (& $isItfAccessor $__i) { return $__built }
        $__c = $null
        try { $__c = [string]$__i.PathName } catch { $__c = $null }
        if ([string]::IsNullOrWhiteSpace($__c)) { $__built } else { $__c }
    }

    # 2./3. direct lookups (2b./3b.: Parent.Member as a direct path, before the tree walk)
    $candidates = [System.Collections.Generic.List[object]]::new()
    $candidates.Add(@{ Path = "$projPath^POUs^$Name"; By = 'pous-folder' })
    $candidates.Add(@{ Path = "$projPath^$Name"; By = 'project-root' })
    $dotParts = @()
    if (-not $NoDotPath -and $Name.Contains('.')) {
        $dotParts = @($Name -split '\.')
        if (@($dotParts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
            $dotted = $dotParts -join '^'
            $candidates.Add(@{ Path = "$projPath^POUs^$dotted"; By = 'dot-path' })
            $candidates.Add(@{ Path = "$projPath^$dotted"; By = 'dot-path' })
        }
        else { $dotParts = @() }
    }
    foreach ($cand in $candidates) {
        $candPath = $cand.Path
        $item = & $lookup $candPath
        $tried.Add($candPath)
        if ($null -ne $item) {
            return (& $found $item (& $pathOf $item $candPath) $cand.By)
        }
    }

    # 4. tree search below the project node (one COM round trip set): every hit, not only the first.
    # Paths are built as <parent path>^<Name>; PathName is only read for a hit that is not an
    # ITF property accessor (654 / 655, whose ItemType is read first).
    # Known limit: a hit is not searched further down, so when a folder and an object below it
    # have the same name (POUs^FB_X^FB_X), only the folder is returned.
    $itfAcc = $script:TcItfAccessorItemTypes
    $search = Invoke-TcComRetry -OperationName "Search tree for $Name" -ScriptBlock {
        $__root = $sm.LookupTreeItem($projPath)
        $__names = [System.Collections.Generic.List[string]]::new()
        $__hits = [System.Collections.Generic.List[object]]::new()

        $__rootCount = 0
        try { $__rootCount = [int]$__root.ChildCount } catch { $__rootCount = 0 }
        $__level1 = [System.Collections.Generic.List[object]]::new()
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
            $__stack.Push([PSCustomObject]@{ Item = $__level1[$__i]; Depth = 1; Parent = $projPath })
        }
        while ($__stack.Count -gt 0) {
            $__e = $__stack.Pop()
            $__it = $__e.Item
            $__nm = $null
            try { $__nm = [string]$__it.Name } catch { $__nm = $null }
            $__built = "$($__e.Parent)^$__nm"
            if ($null -ne $__nm -and $__nm -eq $Name) {
                $__ht = -1
                try { $__hv = $__it.ItemType; if ($null -ne $__hv -and -not [string]::IsNullOrWhiteSpace([string]$__hv)) { $__ht = [int]$__hv } } catch { $__ht = -1 }
                $__hp = $__built
                if ($itfAcc -notcontains $__ht) {
                    try { $__p = [string]$__it.PathName; if (-not [string]::IsNullOrWhiteSpace($__p)) { $__hp = $__p } } catch { $__hp = $__built }
                }
                $__hits.Add([PSCustomObject]@{ Item = $__it; Path = $__hp; ItemType = $__ht })
                continue
            }
            if ($null -eq $__nm -or $__e.Depth -ge $MaxDepth) { continue }
            $__cnt = 0
            try { $__cnt = [int]$__it.ChildCount } catch { $__cnt = 0 }
            for ($__j = $__cnt; $__j -ge 1; $__j--) {
                try { $__stack.Push([PSCustomObject]@{ Item = $__it.Child($__j); Depth = ($__e.Depth + 1); Parent = $__built }) }
                catch { continue }
            }
        }
        @{ Hits = $__hits.ToArray(); Names = [string[]]$__names.ToArray() }
    }

    $result.ProjectChildren = [string[]]@($search.Names)
    $hits = @($search.Hits)
    if ($hits.Count -gt 1) {
        # a task reference (650) or folder with the POU's name is not a second candidate; a hit
        # whose ItemType could not be read (-1) stays a candidate (it may be code)
        $codeTypes = @(602, 603, 604, 605, 606, 607, 608, 609, 610, 611, 612, 613, 614, 615, 616, 618, 623, 654, 655)
        $code = @($hits | Where-Object { [int]$_.ItemType -eq -1 -or $codeTypes -contains [int]$_.ItemType })
        if ($code.Count -gt 0) { $hits = $code }
    }
    $tried.Add("$projPath (tree search, depth $MaxDepth)")
    if ($hits.Count -eq 1) {
        $tried.RemoveAt($tried.Count - 1)
        return (& $found $hits[0].Item $hits[0].Path 'tree-search')
    }
    if ($hits.Count -gt 1) {
        $result.Ambiguous = $true
        $result.Candidates = [string[]]@($hits | ForEach-Object { [string]$_.Path })
        $result.Tried = [string[]]$tried.ToArray()
        return $result
    }

    # 5. Parent.Member (task 3.6): only after the original string found nothing
    if (-not $NoDotPath -and $Name.Contains('.')) {
        $parts = @($Name -split '\.')
        if (@($parts | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -eq 0) {
            $rest = ($parts[1..($parts.Count - 1)]) -join '^'
            $head = Resolve-TcPouPath -SysManager $sm -Name $parts[0] -MaxDepth $MaxDepth -NoDotPath -ProjectPath $projPath
            $bases = @()
            if ($head.Found) { $bases = @([string]$head.Path) }
            elseif ($head.Ambiguous) { $bases = @($head.Candidates) }
            $hitsDot = [System.Collections.Generic.List[object]]::new()
            foreach ($b in $bases) {
                $p = "$b^$rest"
                $item = & $lookup $p
                $tried.Add($p)
                if ($null -ne $item) { $hitsDot.Add([PSCustomObject]@{ Item = $item; Path = $p }) }
            }
            if ($hitsDot.Count -eq 1) { return (& $found $hitsDot[0].Item $hitsDot[0].Path 'dot-path') }
            if ($hitsDot.Count -gt 1) {
                $result.Ambiguous = $true
                $result.Candidates = [string[]]@($hitsDot | ForEach-Object { [string]$_.Path })
                $result.Tried = [string[]]$tried.ToArray()
                return $result
            }
            if ($bases.Count -eq 0) { $tried.Add("$($parts[0]) (part before '.', not found)") }
        }
    }

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

function New-TcPouAmbiguousResult {
    <#
    .SYNOPSIS
        Builds the POU_AMBIGUOUS result (task 3.6) from a Resolve-TcPouPath resolution with
        Ambiguous = $true: several objects carry -Name, none was picked.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [hashtable]$Resolution
    )

    $cands = [string[]]@($Resolution.Candidates)
    New-TcResult -Success $false -ErrorCode 'POU_AMBIGUOUS' `
        -ErrorMessage "'$Name' matches $($cands.Count) objects: $($cands -join '; '). None was picked; nothing was read or changed." `
        -Hint (Get-TcErrorHint -Code 'POU_AMBIGUOUS') `
        -Data ([PSCustomObject]@{
            pou         = $Name
            projectPath = $Resolution.ProjectPath
            candidates  = $cands
            tried       = [string[]]@($Resolution.Tried)
        })
}
