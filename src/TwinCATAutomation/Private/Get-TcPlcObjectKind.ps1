function Get-TcPlcObjectKind {
    <#
    .SYNOPSIS
        Classifies a PLC tree item by its ItemType (POU / DUT / GVL / ITF / METHOD ...).
    .DESCRIPTION
        PLC objects report their kind in ITcSmTreeItem.ItemType (602 = Program, 606 = DUT struct,
        615 = GVL ...); ItemSubType is 0 for all of them and ItemSubTypeName holds the
        TREEITEMTYPE_* name (measured 2026-10-25 on 4024 TcXaeShell.DTE.15.0 and 4026
        VisualStudio.DTE.17.0). ItemType values: InfoSys "ITcSmTreeItem Item Types",
        https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html
        hasImplementation = whether the item has an implementation part (ImplementationText
        returns a string; '' for an empty ST body). Measured 2026-10-25 (ImplementationText read
        on items created through CreateChild):
          true   602 / 603 / 604 POU (4024, 4026), 608 action (4024, 4026), 609 method (4026)
          false  605 / 606 DUT enum / struct (4024, 4026), 607 union / 623 alias (4026),
                 615 GVL (4024, 4026), 618 interface (4024, 4026), 610 interface method (4026),
                 611 property (4024, 4026; the property itself, its Get / Set accessors are child
                 items and CreateChild 611 creates none)
        Not measured: 612 interface property, 613 / 614 property get / set, 616 transition:
        HasImplementation is $null for them (as for an unknown ItemType), so Get-TcPouCode /
        Write-TcPouCode read ImplementationText to decide.
        654 / 655 (Get / Set of an interface property, TE1000 v1.7.0 enum 5.46.22): reading
        DeclarationText of a 654 item crashed VS2022 (measured 2026-10-31 4026 VS2022, self-built
        client); Get-TcPouCode / Write-TcPouCode refuse them (POU_MEMBER_UNSUPPORTED) after
        reading only ItemType, so pass -ItemType (not -Item) for them.
        Measured 2026-10-31 (4026 VS2022, self-built client) for 612 / 613 / 614: Get-TcPouCode
        reads them (ITF_PROPERTY, PROPERTY_GET / PROPERTY_SET); HasImplementation stays $null.
        Language: ITcSmTreeItem.Language of a POU / method / action, mapped through the
        TCatSysManagerLib IECLANGUAGETYPES enum (ST = 1, FBD = 4, LD = 6 ...; values read by
        reflection from the TCatSysManagerLib 3.4.0.0 interop assembly, 2026-10-25). The property
        reads 1 / 6 / 4 for ST / LD / FBD POUs and $null for DUT / GVL / ITF / property (measured
        2026-10-25 on 4024 and 4026). Language is $null when there is none.
        IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT from reading -Item are rethrown.
        Returns @{ ObjectKind; ItemType; ItemTypeName; PouType; HasImplementation; Language }.
    .PARAMETER Item
        ITcSmTreeItem (or anything with ItemType / ItemSubTypeName / Language properties).
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

    $ideErrorPattern = 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT'
    $typeName = $null
    $language = $null
    if ($null -ne $Item) {
        $it = $Item
        try { $ItemType = [int](Invoke-TcComRetry -OperationName 'ItemType' -ScriptBlock { $it.ItemType }) }
        catch {
            if ($_.Exception.Message -match $ideErrorPattern) { throw }
            $ItemType = -1
        }
        try { $typeName = [string](Invoke-TcComRetry -OperationName 'ItemSubTypeName' -ScriptBlock { $it.ItemSubTypeName }) }
        catch {
            if ($_.Exception.Message -match $ideErrorPattern) { throw }
            $typeName = $null
        }
        if ([string]::IsNullOrWhiteSpace($typeName)) { $typeName = $null }
        $langValue = $null
        try { $langValue = Invoke-TcComRetry -OperationName 'Language' -ScriptBlock { $it.Language } }
        catch {
            if ($_.Exception.Message -match $ideErrorPattern) { throw }
            $langValue = $null
        }
        $language = ConvertTo-TcIecLanguageName -Value $langValue
    }

    # ItemType -> kind, pouType, hasImplementation (see .DESCRIPTION for what is measured)
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
        612 = @('ITF_PROPERTY', $null, $null)
        613 = @('PROPERTY_GET', $null, $null)
        614 = @('PROPERTY_SET', $null, $null)
        616 = @('TRANSITION', $null, $null)
        654 = @('ITF_PROPERTY_GET', $null, $null)
        655 = @('ITF_PROPERTY_SET', $null, $null)
        601 = @('FOLDER', $null, $false)
    }
    if ($table.ContainsKey($ItemType)) {
        $e = $table[$ItemType]
        return @{ ObjectKind = $e[0]; ItemType = $ItemType; ItemTypeName = $typeName; PouType = $e[1]; HasImplementation = $e[2]; Language = $language }
    }
    return @{ ObjectKind = 'UNKNOWN'; ItemType = $ItemType; ItemTypeName = $typeName; PouType = $null; HasImplementation = $null; Language = $language }
}

function ConvertTo-TcIecLanguageName {
    <#
    .SYNOPSIS
        Maps an IECLANGUAGETYPES value (ITcSmTreeItem.Language) to its short name, or $null.
    .DESCRIPTION
        TCatSysManagerLib IECLANGUAGETYPES (read by reflection from the TCatSysManagerLib
        3.4.0.0 interop assembly, 2026-10-25): NONE 0, ST 1, IL 2, SFC 3, FBD 4, CFC 5, LD 6,
        UMLCD 7, UMLSC 8, UMLAD 9. $null / '' / NONE -> $null; an unknown number -> 'LANG_<n>'.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        $Value
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return $null }
    # an enum value (e.g. TCatSysManagerLib.IECLANGUAGETYPES) is compared by its number
    if ($Value -is [System.Enum]) { $Value = [int]$Value }
    $n = 0
    if (-not [int]::TryParse([string]$Value, [ref]$n)) { return [string]$Value }
    $names = @{ 1 = 'ST'; 2 = 'IL'; 3 = 'SFC'; 4 = 'FBD'; 5 = 'CFC'; 6 = 'LD'; 7 = 'UMLCD'; 8 = 'UMLSC'; 9 = 'UMLAD' }
    if ($n -eq 0) { return $null }
    if ($names.ContainsKey($n)) { return $names[$n] }
    return "LANG_$n"
}
