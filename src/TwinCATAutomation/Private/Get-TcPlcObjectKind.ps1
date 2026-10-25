function Get-TcPlcObjectKind {
    <#
    .SYNOPSIS
        Classifies a PLC tree item by its ItemType (POU / DUT / GVL / ITF / METHOD ...).
    .DESCRIPTION
        PLC objects report their kind in ITcSmTreeItem.ItemType (602 = Program, 606 = DUT struct,
        615 = GVL ...); ItemSubType is 0 for all of them and ItemSubTypeName holds the
        TREEITEMTYPE_* name (measured 2026-10-25 on 4024 TcXaeShell.DTE.15.0 and 4026
        VisualStudio.DTE.17.0). Numbers and names: InfoSys "ITcSmTreeItem Item Types",
        https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html
        hasImplementation: objects with an implementation part (POU, method, action, property
        get / set, transition). DUT, GVL, interface and interface method / property only have a
        declaration (their tree item has no ImplementationText property, measured 2026-10-25 on
        4024 and 4026). For an unknown ItemType hasImplementation is $null.
        Returns @{ ObjectKind; ItemType; ItemTypeName; PouType; HasImplementation }.
    .PARAMETER Item
        ITcSmTreeItem (or anything with ItemType / ItemSubTypeName properties).
    .PARAMETER ItemType
        ItemType number instead of -Item.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        $Item,

        [Parameter()]
        [int]$ItemType = -1
    )

    if ($null -ne $Item) {
        try { $ItemType = [int]$Item.ItemType } catch { $ItemType = -1 }
    }
    $typeName = $null
    if ($null -ne $Item) {
        try { $typeName = [string]$Item.ItemSubTypeName } catch { $typeName = $null }
        if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = $null }
    }

    # ItemType -> kind, pouType, hasImplementation
    $table = @{
        602 = @('POU', 'Program', $true)
        603 = @('POU', 'Function', $true)
        604 = @('POU', 'FunctionBlock', $true)
        605 = @('DUT', 'Enum', $false)
        606 = @('DUT', 'Struct', $false)
        607 = @('DUT', 'Union', $false)
        623 = @('DUT', 'Alias', $false)
        615 = @('GVL', $null, $false)
        618 = @('ITF', $null, $false)
        608 = @('ACTION', $null, $true)
        609 = @('METHOD', $null, $true)
        610 = @('ITF_METHOD', $null, $false)
        611 = @('PROPERTY', $null, $false)
        612 = @('ITF_PROPERTY', $null, $false)
        613 = @('PROPERTY_GET', $null, $true)
        614 = @('PROPERTY_SET', $null, $true)
        616 = @('TRANSITION', $null, $true)
        601 = @('FOLDER', $null, $false)
    }
    if ($table.ContainsKey($ItemType)) {
        $e = $table[$ItemType]
        return @{ ObjectKind = $e[0]; ItemType = $ItemType; ItemTypeName = $typeName; PouType = $e[1]; HasImplementation = [bool]$e[2] }
    }
    return @{ ObjectKind = 'UNKNOWN'; ItemType = $ItemType; ItemTypeName = $typeName; PouType = $null; HasImplementation = $null }
}
