function New-TcPlcObject {
    <#
    .SYNOPSIS
        Creates a PLC object (POU / DUT / GVL) below a PLC folder and reads it back.
    .DESCRIPTION
        ITcSmTreeItem::CreateChild(name, subType, '', vInfo) on the folder item, InfoSys:
        https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425844363.html
        Sub types (InfoSys "ITcSmTreeItem Item Types",
        https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html):
        602 Program, 603 Function, 604 Function block, 605 DUT enum, 606 DUT struct,
        607 DUT union, 623 DUT alias, 615 GVL. The parent must be a PLC folder
        (TREEITEMTYPE_PLCFOLDER, e.g. TIPC^<Plc>^<Plc> Project^POUs) or the <Plc> Project node.
        vInfo is passed through unchanged (see Add-TcPou / Add-TcDut / Add-TcGvl).
        Steps, each one throws on failure (message starts with the step):
          1. exists   "<ParentPath>^<Name>" must not exist yet
          2. create   CreateChild
          3. lookup   LookupTreeItem("<ParentPath>^<Name>")
          4. kind     ItemType of the new item equals -SubType
          5. declare  only with -Declaration: DeclarationText = Declaration, read back and compared
                      (line endings and trailing white space ignored)
        No deadline around CreateChild: it returns within 1 s on 4024 and 4026 (measured
        2026-10-25, TcXaeShell.DTE.15.0 / VisualStudio.DTE.17.0) and Invoke-TcComRetry reports
        a modal dialog that blocks it as IDE_MODAL_DIALOG.
        Returns @{ Item; Path; ItemType; Declaration }.
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
        [string]$Declaration
    )

    $sm = $SysManager
    $ideErrorPattern = 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT'
    $path = "$ParentPath^$Name"

    $existing = $null
    try { $existing = Invoke-TcComRetry -OperationName "LookupTreeItem $path" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($path) } }
    catch {
        if ($_.Exception.Message -match $ideErrorPattern) { throw }
        $existing = $null
    }
    if ($null -ne $existing) { throw "exists: '$path' already exists. Pick another name, or change it with Write-TcPouCode -PouPath '$path'." }

    $parent = Invoke-TcComRetry -OperationName "LookupTreeItem $ParentPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($ParentPath) }
    $vi = $VInfo
    $null = Invoke-TcComRetry -OperationName "CreateChild $Name" -ScriptBlock { Write-Output -NoEnumerate $parent.CreateChild($Name, $SubType, '', $vi) }

    $item = $null
    try { $item = Invoke-TcComRetry -OperationName "LookupTreeItem $path" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($path) } }
    catch {
        if ($_.Exception.Message -match $ideErrorPattern) { throw }
        throw "lookup: CreateChild returned but '$path' cannot be found: $($_.Exception.Message)"
    }
    if ($null -eq $item) { throw "lookup: CreateChild returned but '$path' cannot be found." }

    $itemType = -1
    try { $itemType = [int](Invoke-TcComRetry -OperationName 'ItemType' -ScriptBlock { $item.ItemType }) } catch { $itemType = -1 }
    if ($itemType -ne $SubType) { throw "kind: '$path' was created with ItemType $itemType, expected $SubType." }

    $decl = $null
    if (-not [string]::IsNullOrWhiteSpace($Declaration)) {
        $d = $Declaration
        Invoke-TcComRetry -OperationName 'Set DeclarationText' -ScriptBlock { $item.DeclarationText = $d } | Out-Null
        $decl = [string](Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $item.DeclarationText })
        $norm = { param([string]$s) (($s -replace "`r`n", "`n") -split "`n" | ForEach-Object { $_.TrimEnd() }) -join "`n" }
        if ((& $norm $decl).Trim() -ne (& $norm $Declaration).Trim()) {
            throw "declare: declaration of '$path' reads back different from what was written. Read it with Get-TcPouCode -PouPath '$path'."
        }
    }
    else {
        try { $decl = [string](Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $item.DeclarationText }) } catch { $decl = $null }
    }

    return @{ Item = $item; Path = $path; ItemType = $itemType; Declaration = $decl }
}
