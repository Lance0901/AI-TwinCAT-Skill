# Generic tree item primitives (complete-automation-interface phase 1, task 2.2): path checks and
# ITcSysManager.LookupTreeItem wrapper shared by Get-TcTreeItem, Get-TcTreeItemXml, New-TcTreeItem,
# Set-TcTreeItemXml, Remove-TcTreeItem, Export-TcTreeItem and Import-TcTreeItem.
# TE1000 Automation Interface manual v1.7.0
# (https://download.beckhoff.com/download/document/automation/twincat3/TC3_Automation_Interface_EN.pdf):
#   5.1.1.3 ITcSysManager::LookupTreeItem (p.38): path name separated by '^', TSM_E_ITEMNOTFOUND when it
#           cannot be resolved (numeric value 0x98510001 is measured, see ConvertTo-TcTsmErrorCode).
#   5.2.1   ITcSmTreeItem (p.56): Name, PathName, ItemType, ItemSubType, ItemSubTypeName, ChildCount, Child.

# Top-level abbreviations that are probed when not even the first path segment resolves. Taken from the
# paths used in TE1000 v1.7.0 samples (TIPC, TIID, TIRC, TIRS, TIRT 6.3.1, TINC 6.3.2); only the ones
# that LookupTreeItem actually resolves are reported.
$script:TcTreeRootCandidates = @('TIPC', 'TIID', 'TIRC', 'TIRS', 'TIRT', 'TINC')

# Upper bound of child names listed in data / hints (a TIID with hundreds of terminals stays readable).
$script:TcTreeItemMaxChildNames = 200

function Test-TcTreePath {
    <#
    .SYNOPSIS
        Returns $null when -Path is an acceptable full tree path, else the reason.
    .DESCRIPTION
        Rejected: empty / whitespace, wildcards (* or ?; the modifying tools must never act on a
        pattern), an empty segment (leading / trailing '^' or '^^').
    .PARAMETER Path
        Tree path to check.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return 'path is empty' }
    if ($Path.IndexOfAny([char[]]@('*', '?')) -ge 0) { return "wildcards (* ?) are not accepted, give the full tree path: '$Path'" }
    if ($Path.StartsWith('^') -or $Path.EndsWith('^') -or $Path.Contains('^^')) { return "empty path segment in '$Path'" }
    return $null
}

function Get-TcTreePathParent {
    <#
    .SYNOPSIS
        Parent tree path ('TIRT^PlcTask' -> 'TIRT'); $null for a top-level path.
    .PARAMETER Path
        Full tree path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $i = $Path.LastIndexOf('^')
    if ($i -lt 1) { return $null }
    return $Path.Substring(0, $i)
}

function Get-TcTreePathLeaf {
    <#
    .SYNOPSIS
        Last segment of a tree path ('TIRT^PlcTask' -> 'PlcTask').
    .PARAMETER Path
        Full tree path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    $i = $Path.LastIndexOf('^')
    if ($i -lt 0) { return $Path }
    return $Path.Substring($i + 1)
}

function Get-TcTreeItemChildNames {
    <#
    .SYNOPSIS
        Names of the direct children of a tree item (ITcSmTreeItem.ChildCount / Child(i), 1-based).
    .DESCRIPTION
        At most -Max names. A child that cannot be read is skipped. Returns a string array.
    .PARAMETER Item
        ITcSmTreeItem.
    .PARAMETER Max
        Maximum number of names (default $script:TcTreeItemMaxChildNames).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [int]$Max = 0)
    if ($Max -le 0) { $Max = $script:TcTreeItemMaxChildNames }
    $names = [System.Collections.Generic.List[string]]::new()
    $count = 0
    try { $count = [int]$Item.ChildCount } catch { $count = 0 }
    for ($i = 1; $i -le $count -and $names.Count -lt $Max; $i++) {
        try {
            $c = $Item.Child($i)
            if ($null -ne $c) { $names.Add([string]$c.Name) }
        }
        catch { continue }
    }
    return $names.ToArray()
}

function Get-TcTreeItemSummary {
    <#
    .SYNOPSIS
        { name; path; itemType; subType; subTypeName; type; childCount } of a tree item.
    .DESCRIPTION
        type: name from $script:TcPlcItemTypeNames (Get-TcProjectTree) when the ItemType is known,
        else the number as text. Unreadable properties are -1 / $null.
    .PARAMETER Item
        ITcSmTreeItem.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    $name = try { [string]$Item.Name } catch { $null }
    $path = try { [string]$Item.PathName } catch { $null }
    $itemType = try { [int]$Item.ItemType } catch { -1 }
    $subType = try { [int]$Item.ItemSubType } catch { -1 }
    $subTypeName = try { [string]$Item.ItemSubTypeName } catch { $null }
    $childCount = try { [int]$Item.ChildCount } catch { 0 }
    $type = [string]$itemType
    if ($null -ne $script:TcPlcItemTypeNames -and $script:TcPlcItemTypeNames.ContainsKey($itemType)) { $type = $script:TcPlcItemTypeNames[$itemType] }
    [PSCustomObject]@{
        name        = $name
        path        = $path
        itemType    = $itemType
        subType     = $subType
        subTypeName = $subTypeName
        type        = $type
        childCount  = $childCount
    }
}

function Find-TcTreeItemNoThrow {
    <#
    .SYNOPSIS
        LookupTreeItem that returns $null for TSM_E_ITEMNOTFOUND instead of throwing.
    .DESCRIPTION
        Any other exception (IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG from Invoke-TcComRetry, other COM
        errors) is rethrown.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Path
        Full tree path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][string]$Path)
    try {
        $item = Invoke-TcComRetry -OperationName "LookupTreeItem $Path" -ScriptBlock { Write-Output -NoEnumerate $SysManager.LookupTreeItem($Path) }
        Write-Output -NoEnumerate $item
    }
    catch {
        $code = ConvertTo-TcTsmErrorCode -InputObject $_ -DefaultCode 'OTHER'
        if ($code -eq 'TREEITEM_NOT_FOUND') { return $null }
        throw
    }
}

function Get-TcTreeItemNotFoundDetail {
    <#
    .SYNOPSIS
        Nearest existing ancestor of a missing path and its children: { nearestPath; children; missingSegment }.
    .DESCRIPTION
        Walks up from the parent of -Path until LookupTreeItem resolves. When not even the first segment
        resolves, nearestPath is $null and children lists the top-level abbreviations that resolve
        ($script:TcTreeRootCandidates). missingSegment is the first segment below nearestPath.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Path
        The full tree path that was not found.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$SysManager, [Parameter(Mandatory)][string]$Path)
    $segments = @($Path -split '\^')
    for ($n = $segments.Count - 1; $n -ge 1; $n--) {
        $prefix = ($segments[0..($n - 1)]) -join '^'
        $item = Find-TcTreeItemNoThrow -SysManager $SysManager -Path $prefix
        if ($null -ne $item) {
            return [PSCustomObject]@{
                nearestPath    = $prefix
                children       = @(Get-TcTreeItemChildNames -Item $item)
                missingSegment = $segments[$n]
            }
        }
    }
    $roots = [System.Collections.Generic.List[string]]::new()
    foreach ($r in $script:TcTreeRootCandidates) {
        try { if ($null -ne (Find-TcTreeItemNoThrow -SysManager $SysManager -Path $r)) { $roots.Add($r) } } catch { continue }
    }
    [PSCustomObject]@{ nearestPath = $null; children = @($roots.ToArray()); missingSegment = $segments[0] }
}

function Format-TcTreeItemNotFoundHint {
    <#
    .SYNOPSIS
        Hint text for TREEITEM_NOT_FOUND from Get-TcTreeItemNotFoundDetail output.
    .PARAMETER Path
        The missing path.
    .PARAMETER Detail
        Output of Get-TcTreeItemNotFoundDetail.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][object]$Detail)
    $kids = @($Detail.children)
    $list = if ($kids.Count -gt 0) { ($kids | ForEach-Object { "'$_'" }) -join ', ' } else { '(none)' }
    # Cmdlet names only, never 'Tool (Cmdlet)': the MCP server rewrites each cmdlet name (and its
    # -Param value) into the tool name, which made 'LookupTreeItem (LookupTreeItem)' (phase1-2.8.md #5).
    if ($null -eq $Detail.nearestPath) {
        return "'$Path' not found: the first segment '$($Detail.missingSegment)' does not exist. Top-level nodes that resolve: $list. Use Get-TcTreeItem on one of them, or Get-TcProjectTree."
    }
    return "'$Path' not found: nearest existing parent is '$($Detail.nearestPath)', '$($Detail.missingSegment)' is not one of its children: $list. Use Get-TcTreeItem -Path '$($Detail.nearestPath)' to browse."
}

function New-TcTreeItemNotFoundResult {
    <#
    .SYNOPSIS
        TREEITEM_NOT_FOUND result whose hint names the nearest existing parent and its children.
    .DESCRIPTION
        data gets nearestPath / nearestChildren. When the lookup of the ancestors itself fails the hint
        falls back to the static table entry.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Path
        The missing path.
    .PARAMETER Data
        Data object of the failing cmdlet (PSCustomObject); nearestPath / nearestChildren are added.
    .PARAMETER ParameterName
        Parameter that carried the path (message only).
    .PARAMETER Message
        Original exception message, if any.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SysManager,
        [Parameter(Mandatory)][string]$Path,
        [Parameter()][object]$Data,
        [Parameter()][string]$ParameterName = 'Path',
        [Parameter()][string]$Message
    )
    if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
    $hint = $null
    try {
        $detail = Get-TcTreeItemNotFoundDetail -SysManager $SysManager -Path $Path
        $Data | Add-Member -NotePropertyName nearestPath -NotePropertyValue $detail.nearestPath -Force
        $Data | Add-Member -NotePropertyName nearestChildren -NotePropertyValue @($detail.children) -Force
        $hint = Format-TcTreeItemNotFoundHint -Path $Path -Detail $detail
    }
    catch {
        $hint = Get-TcErrorHint -Code 'TREEITEM_NOT_FOUND'
    }
    $msg = "-$ParameterName tree item not found: $Path"
    if (-not [string]::IsNullOrWhiteSpace($Message)) { $msg += " ($Message)" }
    New-TcResult -Success $false -ErrorCode 'TREEITEM_NOT_FOUND' -ErrorMessage $msg -Hint $hint -Data $Data
}

function Resolve-TcTreeItem {
    <#
    .SYNOPSIS
        Checks -Path (Test-TcTreePath) and looks it up: @{ Item = <ITcSmTreeItem>; Result = $null } or
        @{ Item = $null; Result = <failed result> }.
    .DESCRIPTION
        Failed results: TREEITEM_PATH_INVALID (wildcard, empty segment) or TREEITEM_NOT_FOUND
        (New-TcTreeItemNotFoundResult). Exceptions other than "not found" (IDE_BUSY ...) are rethrown.
    .PARAMETER SysManager
        ITcSysManager.
    .PARAMETER Path
        Full tree path.
    .PARAMETER Data
        Data object attached to a failed result.
    .PARAMETER ParameterName
        Parameter name used in the message (default Path).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$SysManager,
        [Parameter()][AllowEmptyString()][AllowNull()][string]$Path,
        [Parameter()][object]$Data,
        [Parameter()][string]$ParameterName = 'Path'
    )
    $bad = Test-TcTreePath -Path $Path
    if ($null -ne $bad) {
        return @{ Item = $null; Result = (New-TcResult -Success $false -ErrorCode 'TREEITEM_PATH_INVALID' -Data $Data `
                    -ErrorMessage "-$ParameterName $bad" -Hint (Get-TcErrorHint -Code 'TREEITEM_PATH_INVALID')) }
    }
    $msg = $null
    $item = $null
    try {
        $item = Invoke-TcComRetry -OperationName "LookupTreeItem $Path" -ScriptBlock { Write-Output -NoEnumerate $SysManager.LookupTreeItem($Path) }
    }
    catch {
        $code = ConvertTo-TcTsmErrorCode -InputObject $_ -DefaultCode 'OTHER'
        if ($code -ne 'TREEITEM_NOT_FOUND') { throw }
        $msg = $_.Exception.Message
        $item = $null
    }
    if ($null -eq $item) {
        return @{ Item = $null; Result = (New-TcTreeItemNotFoundResult -SysManager $SysManager -Path $Path -Data $Data -ParameterName $ParameterName -Message $msg) }
    }
    return @{ Item = $item; Result = $null }
}

# Error codes a tree item cmdlet passes through unchanged (instead of its own default code), and that
# Invoke-TcTreeItemBackup and the best-effort catches rethrow instead of turning them into a warning.
$script:TcTreeItemPassThroughCodes = @('IDE_MODAL_DIALOG', 'IDE_CRASHED', 'IDE_TIMEOUT', 'IDE_BUSY', 'PLC_LOGGED_IN')

function Get-TcTreeItemPassThroughError {
    <#
    .SYNOPSIS
        ConvertTo-TcAdsErrorCode result (@{ Code; Hint; Message }) when the error maps to one of
        $script:TcTreeItemPassThroughCodes, else $null. Never throws.
    .PARAMETER ErrorRecord
        ErrorRecord, exception or message.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$ErrorRecord)
    if ($null -eq $ErrorRecord) { return $null }
    $mapped = $null
    try { $mapped = ConvertTo-TcAdsErrorCode -InputObject $ErrorRecord } catch { $mapped = $null }
    if ($null -ne $mapped -and $script:TcTreeItemPassThroughCodes -contains $mapped.Code) { return $mapped }
    return $null
}

function Test-TcTreeItemFilePath {
    <#
    .SYNOPSIS
        Checks the -FilePath of ExportChild / ImportChild without throwing: $null when usable, else
        @{ Reason = 'not-absolute' | 'invalid-path'; Message }.
    .DESCRIPTION
        invalid-path: characters invalid in a path or in a file name (e.g. < > | " * ?), a path that
        GetFullPath rejects (e.g. a ':' inside a segment), or a path without a file name (a root such
        as C:\ or a path ending in a separator). Existence is checked by the caller.
    .PARAMETER FilePath
        The path to check.
    #>
    [CmdletBinding()]
    param([Parameter()][AllowNull()][AllowEmptyString()][string]$FilePath)
    $notAbsolute = @{ Reason = 'not-absolute'; Message = "-FilePath must be an absolute path (got '$FilePath')" }
    if ([string]::IsNullOrWhiteSpace($FilePath)) { return $notAbsolute }
    try {
        if ($FilePath.IndexOfAny([System.IO.Path]::GetInvalidPathChars()) -ge 0) { throw 'it contains characters that are invalid in a path' }
        if (-not [System.IO.Path]::IsPathRooted($FilePath)) { return $notAbsolute }
        $full = [System.IO.Path]::GetFullPath($FilePath)
        $leaf = [System.IO.Path]::GetFileName($full)
        if ([string]::IsNullOrEmpty($leaf)) { throw 'it has no file name (a root folder, or a path ending in a separator)' }
        if ($leaf.IndexOfAny([System.IO.Path]::GetInvalidFileNameChars()) -ge 0) { throw 'the file name contains characters that are invalid in a file name' }
        if ([string]::IsNullOrEmpty([System.IO.Path]::GetDirectoryName($full))) { throw 'it has no folder' }
    }
    catch {
        return @{ Reason = 'invalid-path'; Message = "-FilePath '$FilePath' is not a valid file path: $($_.Exception.Message)" }
    }
    return $null
}

function Get-TcTreeItemDialogResult {
    <#
    .SYNOPSIS
        IDE_MODAL_DIALOG result when a modal dialog is open in the IDE (Get-TcIdeModalDialog), else $null.
    .DESCRIPTION
        Called right before each synchronous modifying COM call of the tree tools (ConsumeXml,
        CreateChild, DeleteChild, ExportChild, ImportChild), as New-TcPlcObject does before CreateChild:
        Invoke-TcComRetry only classifies a call after it returned, so a dialog has to be caught
        before a call that cannot be interrupted (CODING_STANDARDS.md section 1).
    .PARAMETER Operation
        The operation that was NOT attempted (message).
    .PARAMETER Data
        Data attached to the result.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Operation, [Parameter()][object]$Data)
    $dialog = Get-TcIdeModalDialog
    if ($null -eq $dialog) { return $null }
    $p = @{ Dialog = $dialog; Operation = $Operation }
    if ($null -ne $Data) { $p['Data'] = $Data }
    return New-TcModalDialogResult @p
}

function New-TcTreeItemErrorResult {
    <#
    .SYNOPSIS
        Failed result for an exception thrown inside a tree item cmdlet.
    .DESCRIPTION
        The codes in $script:TcTreeItemPassThroughCodes are kept (Get-TcTreeItemPassThroughError):
        IDE_MODAL_DIALOG (with the watchdog record: New-TcModalDialogResult) / IDE_CRASHED / IDE_TIMEOUT /
        IDE_BUSY / PLC_LOGGED_IN; TSM_E_ITEMNOTFOUND becomes TREEITEM_NOT_FOUND; everything else
        -DefaultCode. Hint from the central table; PLC_LOGGED_IN gets $script:TcTreeItemPlcLoggedInHint
        (PlcLogout, then rerun the same tool, named by -Operation).
    .PARAMETER ErrorRecord
        The caught ErrorRecord.
    .PARAMETER DefaultCode
        Code when nothing more specific matches.
    .PARAMETER Data
        Data attached to the result.
    .PARAMETER Operation
        Operation name used in the message.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$ErrorRecord,
        [Parameter(Mandatory)][string]$DefaultCode,
        [Parameter()][object]$Data,
        [Parameter()][string]$Operation = 'tree item operation'
    )
    $message = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception.Message } else { [string]$ErrorRecord }
    $code = $null
    $mapped = Get-TcTreeItemPassThroughError -ErrorRecord $ErrorRecord
    if ($null -ne $mapped) {
        $code = $mapped.Code
        if ($code -eq 'IDE_MODAL_DIALOG' -and $null -ne $script:TcLastModalDialog) {
            $p = @{ Dialog = $script:TcLastModalDialog; Operation = $Operation }
            if ($null -ne $Data) { $p['Data'] = $Data }
            return New-TcModalDialogResult @p
        }
        $hint = $mapped.Hint
        # The central PLC_LOGGED_IN hint names Add-TcPou / AddPou; a tree tool reruns itself.
        if ($code -eq 'PLC_LOGGED_IN') { $hint = ([string]$script:TcTreeItemPlcLoggedInHint).Replace('{operation}', $Operation) }
    }
    else {
        $code = ConvertTo-TcTsmErrorCode -InputObject $ErrorRecord -DefaultCode $DefaultCode
        if (@('LINK_INVALID_ITEM_TYPE', 'LINK_TYPE_MISMATCH') -contains $code) { $code = $DefaultCode }
        $hint = Get-TcErrorHint -Code $code
    }
    $p = @{ Success = $false; ErrorCode = $code; ErrorMessage = "$Operation failed: $message" }
    if (-not [string]::IsNullOrWhiteSpace($hint)) { $p['Hint'] = $hint }
    if ($null -ne $Data) { $p['Data'] = $Data }
    New-TcResult @p
}

function Get-TcTreeItemXmlText {
    <#
    .SYNOPSIS
        ITcSmTreeItem.ProduceXml(bRecursive) as string (TE1000 v1.7.0 5.2.1.8, p.61: root node TreeItem).
    .PARAMETER Item
        ITcSmTreeItem.
    .PARAMETER Recursive
        bRecursive argument (default $false, as used by Invoke-TcIoScan; $true includes the subtree).
    .PARAMETER Path
        Path for the operation name only.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item, [Parameter()][bool]$Recursive = $false, [Parameter()][string]$Path = '')
    $xml = Invoke-TcComRetry -OperationName "ProduceXml $Path" -ScriptBlock { $Item.ProduceXml($Recursive) }
    return [string]$xml
}

function Test-TcTreePathIsPlc {
    <#
    .SYNOPSIS
        True for a path below TIPC: a change there is recorded as BUILD_REQUIRED code-changed (#65).
    .PARAMETER Path
        Full tree path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return ($Path -ieq 'TIPC' -or $Path -like 'TIPC^*')
}

function Get-TcTreeItemExportExtension {
    <#
    .SYNOPSIS
        File extension ExportChild needs for a tree path: '.zip' below TIPC (a node inside a PLC
        project), else '.xti'.
    .DESCRIPTION
        For a node below TIPC XAE refuses any other file name: "The filename '...xti' doesn't specify
        a zip archive! (ITcSmTreeItem:ExportChild)"; the same node exported to a .zip file and
        imported again with ImportChild (registered tcauto measured 2026-10-30, 4026 VS2022 XAE
        3.1.4026.22, a PLC folder below TIPC^<Plc>^<Plc> Project; phase1-2.8.md issue #2). TE1000
        v1.7.0 5.2.1.4 does not mention it.
    .PARAMETER Path
        Full tree path of the node to export.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    if ($Path -like 'TIPC^*') { return '.zip' }
    return '.xti'
}
