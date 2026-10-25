function New-TcPlcObject {
    <#
    .SYNOPSIS
        Creates a PLC object (POU / DUT / GVL) below a PLC folder and reads it back.
    .DESCRIPTION
        ITcSmTreeItem::CreateChild(name, subType, '', vInfo) on the folder item, InfoSys:
        https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425844363.html
        -SubType is the ItemType value of the new object from InfoSys "ITcSmTreeItem Item
        Types" (https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html):
        602 Program, 603 Function, 604 Function block, 605 DUT enum, 606 DUT struct,
        607 DUT union, 623 DUT alias, 615 GVL. The CreateChild page confirms 603 / 604 as
        CreateChild sub types; the others are measured (2026-10-25, 4024 and 4026). The parent
        must be a PLC folder (TREEITEMTYPE_PLCFOLDER, e.g. TIPC^<Plc>^<Plc> Project^POUs) or the
        <Plc> Project node. vInfo is passed through unchanged (see Add-TcPou / Add-TcDut /
        Add-TcGvl).
        Steps; each failure throws a message that starts with the step name:
          1. exists    no object with -Name in the PLC project (Resolve-TcPouPath: POUs folder,
                       project root, tree search) and none at "<ParentPath>^<Name>"
          -  dialog    a modal dialog in the IDE (Get-TcIdeModalDialog): returns
                       @{ ModalDialog = <dialog> } without calling CreateChild; the caller returns
                       New-TcModalDialogResult (IDE_MODAL_DIALOG), as Build-TcProject does.
                       Invoke-TcComRetry only classifies a call after it returned, so a dialog
                       must be caught before the synchronous CreateChild.
          2. create    CreateChild (no deadline: it returns within 1 s on 4024 and 4026 when no
                       dialog is up, measured 2026-10-25 TcXaeShell.DTE.15.0 /
                       VisualStudio.DTE.17.0)
          3. lookup    LookupTreeItem("<ParentPath>^<Name>")
          4. kind      ItemType of the new item equals -SubType
          5. language  only with -ExpectedLanguage: ITcSmTreeItem.Language read back (see
                       Get-TcPlcObjectKind) equals it
          6. declare   with -Declaration: DeclarationText = Declaration, read back and compared
                       (line endings and trailing white space ignored); with
                       -DeclarationPattern: the declaration read back matches the regex
        From step 3 on the object has been created and stays in the tree: the messages say so
        and name the way out (Write-TcPouCode -PouPath <path> to correct it, or delete it in XAE).
        Returns @{ Item; Path; ItemType; Declaration; Language } or @{ ModalDialog }.
    .PARAMETER SysManager
        ITcSysManager object (from Get-TcSysManager).
    .PARAMETER ParentPath
        Tree path of the parent folder.
    .PARAMETER Name
        Name of the new object.
    .PARAMETER SubType
        CreateChild sub type (see above).
    .PARAMETER VInfo
        CreateChild vInfo ($null = none).
    .PARAMETER Declaration
        Optional declaration text written after the object is created.
    .PARAMETER DeclarationPattern
        Optional regex the declaration read back must match (e.g. the return type of a Function).
    .PARAMETER ExpectedLanguage
        Optional language name (ST, LD ...) the new object must report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $SysManager,

        [Parameter(Mandatory)]
        [string]$ParentPath,

        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [int]$SubType,

        [Parameter()]
        [AllowNull()]
        $VInfo = $null,

        [Parameter()]
        [string]$Declaration,

        [Parameter()]
        [string]$DeclarationPattern,

        [Parameter()]
        [string]$ExpectedLanguage
    )

    $sm = $SysManager
    $ideErrorPattern = 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT'
    $path = "$ParentPath^$Name"
    $stays = "The object was created and stays in the tree: correct it with Write-TcPouCode -PouPath '$path', or delete it in XAE before creating it again."

    # 1. exists: same name anywhere in the PLC project, then the target path itself
    $found = $null
    try { $found = Resolve-TcPouPath -SysManager $sm -Name $Name }
    catch {
        if ($_.Exception.Message -match $ideErrorPattern) { throw }
        $found = $null
    }
    if ($null -ne $found -and $found.Found) {
        throw "exists: an object named '$Name' already exists at '$($found.Path)'. Pick another name, or change it with Write-TcPouCode -PouPath '$($found.Path)'."
    }
    $existing = $null
    try { $existing = Invoke-TcComRetry -OperationName "LookupTreeItem $path" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($path) } }
    catch {
        if ($_.Exception.Message -match $ideErrorPattern) { throw }
        $existing = $null
    }
    if ($null -ne $existing) { throw "exists: '$path' already exists. Pick another name, or change it with Write-TcPouCode -PouPath '$path'." }

    $parent = Invoke-TcComRetry -OperationName "LookupTreeItem $ParentPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($ParentPath) }

    # dialog check right before the synchronous CreateChild (it cannot be interrupted)
    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) { return @{ ModalDialog = $dialog } }

    # 2. create
    $vi = $VInfo
    $null = Invoke-TcComRetry -OperationName "CreateChild $Name" -ScriptBlock { Write-Output -NoEnumerate $parent.CreateChild($Name, $SubType, '', $vi) }

    # 3. lookup
    $item = $null
    try { $item = Invoke-TcComRetry -OperationName "LookupTreeItem $path" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($path) } }
    catch {
        throw "lookup: CreateChild returned but '$path' cannot be found ($($_.Exception.Message)). CreateChild may still have created it under another path: check with Get-TcProjectTree -PlcOnly, then correct it with Write-TcPouCode or delete it in XAE."
    }
    if ($null -eq $item) { throw "lookup: CreateChild returned but '$path' cannot be found. CreateChild may still have created it under another path: check with Get-TcProjectTree -PlcOnly, then correct it with Write-TcPouCode or delete it in XAE." }

    # 4. kind (and 5. language)
    $kind = $null
    try { $kind = Get-TcPlcObjectKind -Item $item }
    catch { throw "kind: reading ItemType of '$path' failed ($($_.Exception.Message)). $stays" }
    $itemType = [int]$kind.ItemType
    if ($itemType -ne $SubType) { throw "kind: '$path' was created with ItemType $itemType, expected $SubType. $stays" }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedLanguage) -and $kind.Language -ne $ExpectedLanguage) {
        throw "language: '$path' reports language '$($kind.Language)', expected '$ExpectedLanguage'. $stays"
    }

    # 6. declare
    $decl = $null
    if (-not [string]::IsNullOrWhiteSpace($Declaration)) {
        $d = $Declaration
        try {
            Invoke-TcComRetry -OperationName 'Set DeclarationText' -ScriptBlock { $item.DeclarationText = $d } | Out-Null
            $decl = [string](Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $item.DeclarationText })
        }
        catch { throw "declare: '$path' was created but writing / reading its declaration failed ($($_.Exception.Message)). $stays" }
        $norm = { param([string]$s) (($s -replace "`r`n", "`n") -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n" }
        if ((& $norm $decl).Trim() -ne (& $norm $Declaration).Trim()) {
            throw "declare: '$path' was created but its declaration reads back different from what was written (read it with Get-TcPouCode -PouPath '$path'). $stays"
        }
    }
    else {
        try { $decl = [string](Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $item.DeclarationText }) }
        catch { throw "declare: '$path' was created but reading its declaration failed ($($_.Exception.Message)). $stays" }
    }
    if (-not [string]::IsNullOrWhiteSpace($DeclarationPattern) -and $decl -notmatch $DeclarationPattern) {
        throw "declare: '$path' was created but its declaration does not match '$DeclarationPattern' (read back: $decl). $stays"
    }

    return @{ Item = $item; Path = $path; ItemType = $itemType; Declaration = $decl; Language = $kind.Language }
}
