# Members of a POU / interface (methods, properties, accessors, actions; task 3.6).
# Sources: TE1000 Automation Interface manual v1.7.0 (2026-09-03) 6.5.5 p.229-231 (CreateChild sub
# types and vInfo of PLC objects), enum 5.46.5 p.160-161 (IECLANGUAGETYPES), 5.46.6 p.161 (PLCACCESS),
# 5.46.22 p.182-184 (TREEITEMTYPES); research: openspec/changes/complete-automation-interface/research/phase2-api.md
# "3.6". Measured: openspec/changes/complete-automation-interface/verification/phase2-probe.md "3.6"
# (self-built client 2026-10-31, 4026 VS2022 XAE 3.1.4026.18).

# ITF property Get / Set (TE1000 5.46.22: 654 TREEITEMTYPE_PLCITFPROPGET, 655 ..._PLCITFPROPSET).
# Reading DeclarationText of a 654 item crashed devenv.exe twice (KERNELBASE.dll, exception code
# 0xe06d7363, offset 0x00000000000c408a; measured 2026-10-31 4026 VS2022, self-built client); 655 was
# not reached. The module never reads or writes the code of these items.
$script:TcItfAccessorItemTypes = @(654, 655)
$script:TcPouMemberProbeDoc = 'openspec/changes/complete-automation-interface/verification/phase2-probe.md'
# IECLANGUAGETYPES (TE1000 5.46.5 p.160-161): the vInfo language element of 608 / 609 / 611 / 613 / 614
$script:TcIecLanguageNumbers = @{ 'ST' = 1; 'IL' = 2; 'SFC' = 3; 'FBD' = 4; 'CFC' = 5; 'LD' = 6 }
# PLCACCESS names (TE1000 6.5.5 p.231; enum 5.46.6 p.161). XAE turns an unknown access text into
# PUBLIC without an error (measured 2026-10-31 4026 VS2022, self-built client), so the module checks it.
$script:TcPouMemberAccess = @('PUBLIC', 'PRIVATE', 'PROTECTED', 'INTERNAL')

function Get-TcPouMemberSpec {
    <#
    .SYNOPSIS
        Validates an Add-TcPouMember request and builds CreateChild sub type, vInfo and the readback rules.
    .DESCRIPTION
        Pure function (no COM). Sub type by -Kind and the ItemType of the parent (TE1000 6.5.5 table):
          parent 602 Program / 604 FB:  Method 609, Property 611, Action 608
          parent 618 interface:         Method 610, Property 612 (no action)
          parent 611 property:          Get 613, Set 614
          parent 612 ITF property:      Get / Set (654 / 655) refused: POU_MEMBER_UNSUPPORTED
        vInfo (string[]; element 0 is the IEC language number, measured 2026-10-31 4026 VS2022,
        self-built client: the manual example { name, returnType } fails with "Language type not
        supported!"):
          609 { lang, returnType, access }   611 { lang, type, access }   613 / 614 { lang, access }
          608 { lang }                       610 { returnType } or $null  612 { type }
        A method without return type is created with vInfo $null (measured: "METHOD M_Null"), which
        carries neither language nor access; { lang, '', access } is not measured, so a method
        without return type with another -Access or -Language is POU_MEMBER_UNSUPPORTED.
        An interface method / property takes no language and no access (vInfo is only the type).
        Returns @{ Error = $null | @{ Code; Message; Hint; Reason }; SubType; VInfo; ItemName;
        ExpectedLanguage; DeclarationPattern; NoDeclaration; Access; Language }.
    .PARAMETER Kind
        Method, Property, Action, Get or Set.
    .PARAMETER ParentItemType
        ItemType of the parent tree item.
    .PARAMETER ParentPath
        Tree path of the parent (for the messages).
    .PARAMETER Name
        Name of the member; for Get / Set empty or equal to the kind.
    .PARAMETER ReturnType
        Return type (Method) or type (Property).
    .PARAMETER Access
        PUBLIC, PRIVATE, PROTECTED or INTERNAL (case-insensitive).
    .PARAMETER Language
        ST, IL, SFC, FBD, CFC or LD.
    .PARAMETER AccessGiven
        -Access was passed by the caller (not the default).
    .PARAMETER LanguageGiven
        -Language was passed by the caller (not the default).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Method', 'Property', 'Action', 'Get', 'Set')]
        [string]$Kind,

        [Parameter(Mandatory)]
        [int]$ParentItemType,

        [Parameter()]
        [string]$ParentPath,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$ReturnType,

        [Parameter()]
        [string]$Access = 'PUBLIC',

        [Parameter()]
        [string]$Language = 'ST',

        [Parameter()]
        [switch]$AccessGiven,

        [Parameter()]
        [switch]$LanguageGiven
    )

    $spec = @{
        Error = $null; SubType = 0; VInfo = $null; ItemName = $Name; ExpectedLanguage = $null
        DeclarationPattern = $null; NoDeclaration = $false; Access = $null; Language = $null
    }
    $fail = {
        param([string]$Code, [string]$Reason, [string]$Message, [string]$Hint)
        $spec.Error = @{ Code = $Code; Reason = $Reason; Message = $Message; Hint = $Hint }
        $spec
    }
    $isAccessor = $Kind -in @('Get', 'Set')

    # name: an IEC identifier (XAE answers others with "... not possible on node (Name mismatch)",
    # measured 2026-10-31); an accessor is always named Get / Set
    if ($isAccessor) {
        if (-not [string]::IsNullOrWhiteSpace($Name) -and $Name -ine $Kind) {
            return & $fail 'POU_MEMBER_INVALID' 'name' "A $Kind accessor is always named '$Kind' (got -Name '$Name')." "Omit -Name (or pass -Name $Kind) for -Kind $Kind."
        }
        $spec.ItemName = $Kind
    }
    elseif ([string]::IsNullOrWhiteSpace($Name) -or $Name -notmatch '^[A-Za-z_][A-Za-z0-9_]*$') {
        return & $fail 'POU_MEMBER_INVALID' 'name' "-Name '$Name' is not an IEC identifier (letters, digits, '_', not starting with a digit)." "Pass -Name with a valid identifier, e.g. M_Run / P_Value / A_Reset."
    }

    $acc = ([string]$Access).Trim().ToUpperInvariant()
    if ($script:TcPouMemberAccess -notcontains $acc) {
        return & $fail 'POU_MEMBER_INVALID' 'access' "-Access '$Access' is not one of $($script:TcPouMemberAccess -join ', ') (XAE would silently make it PUBLIC)." "Pass -Access PUBLIC, PRIVATE, PROTECTED or INTERNAL."
    }
    $lang = ([string]$Language).Trim().ToUpperInvariant()
    if (-not $script:TcIecLanguageNumbers.ContainsKey($lang)) {
        return & $fail 'POU_MEMBER_INVALID' 'language' "-Language '$Language' is not one of $(@($script:TcIecLanguageNumbers.Keys | Sort-Object) -join ', ')." 'Pass -Language ST (default), LD, FBD, SFC, CFC or IL.'
    }
    $langNo = [string]$script:TcIecLanguageNumbers[$lang]
    $spec.Access = $acc
    $spec.Language = $lang
    $rt = if ($null -eq $ReturnType) { '' } else { $ReturnType.Trim() }
    $where = if ([string]::IsNullOrWhiteSpace($ParentPath)) { 'the parent' } else { "'$ParentPath'" }

    # parent kind -> sub type
    $parentName = switch ($ParentItemType) { 602 { 'PROGRAM' } 604 { 'FUNCTION_BLOCK' } 618 { 'INTERFACE' } 611 { 'PROPERTY' } 612 { 'ITF_PROPERTY' } default { "ItemType $ParentItemType" } }
    $isItf = $false
    switch ($ParentItemType) {
        { $_ -in 602, 604 } {
            switch ($Kind) {
                'Method' { $spec.SubType = 609 }
                'Property' { $spec.SubType = 611 }
                'Action' { $spec.SubType = 608 }
                default { return & $fail 'POU_MEMBER_INVALID' 'parent-kind' "A $Kind accessor belongs below a property, but $where is a $parentName." "Pass -ParentPath '<POU path>^<property>' (create the property first with Add-TcPouMember -Kind Property)." }
            }
        }
        618 {
            $isItf = $true
            switch ($Kind) {
                'Method' { $spec.SubType = 610 }
                'Property' { $spec.SubType = 612 }
                'Action' { return & $fail 'POU_MEMBER_INVALID' 'parent-kind' "An interface has no actions ($where is an INTERFACE)." 'Add the action to the function block or program that implements the interface.' }
                default { return & $fail 'POU_MEMBER_INVALID' 'parent-kind' "A $Kind accessor belongs below a property, but $where is an INTERFACE." "Pass the interface property as -ParentPath (note: Get / Set of an interface property are not supported, see POU_MEMBER_UNSUPPORTED)." }
            }
        }
        611 {
            if (-not $isAccessor) { return & $fail 'POU_MEMBER_INVALID' 'parent-kind' "Below a property only Get / Set can be created ($where is a PROPERTY), not a $Kind." 'Pass the POU itself as -ParentPath, or -Kind Get / Set.' }
            $spec.SubType = if ($Kind -eq 'Get') { 613 } else { 614 }
        }
        612 {
            if ($isAccessor) {
                return & $fail 'POU_MEMBER_UNSUPPORTED' 'itf-property-accessor' "Get / Set below an interface property (654 / 655) are not supported: reading the code of such an accessor crashed VS2022 (measured 2026-10-31, 4026 VS2022, see $($script:TcPouMemberProbeDoc))." "Not supported because reading such an accessor crashed VS2022 (devenv.exe, KERNELBASE.dll 0xe06d7363; details in $($script:TcPouMemberProbeDoc), 3.6). Leave the interface property without accessors and implement Get / Set in the function block that implements the interface (Add-TcPouMember -ParentPath '<FB path>^<property>' -Kind $Kind)."
            }
            return & $fail 'POU_MEMBER_INVALID' 'parent-kind' "Below an interface property nothing but Get / Set exists ($where), not a $Kind." 'Pass the interface itself as -ParentPath.'
        }
        default {
            return & $fail 'POU_MEMBER_INVALID' 'parent-kind' "$where is a ${parentName}: members can be added to a PROGRAM, FUNCTION_BLOCK or INTERFACE (Get / Set to a property)." 'Look the parent up with Get-TcProjectTree -PlcOnly and pass its path as -ParentPath.'
        }
    }

    # parameters that have no meaning for the target
    if (($isItf -or $Kind -eq 'Action') -and $AccessGiven -and $acc -ne 'PUBLIC') {
        return & $fail 'POU_MEMBER_INVALID' 'access' "-Access $acc has no effect on $(if ($isItf) { 'an interface member' } else { 'an action' }) (CreateChild takes no access modifier for it)." 'Omit -Access.'
    }
    if ($isItf -and $LanguageGiven -and $lang -ne 'ST') {
        return & $fail 'POU_MEMBER_INVALID' 'language' "-Language $lang has no effect on an interface member (it has no implementation)." 'Omit -Language.'
    }
    if (($isAccessor -or $Kind -eq 'Action') -and $rt -ne '') {
        return & $fail 'POU_MEMBER_INVALID' 'return-type' "-ReturnType has no meaning for -Kind $Kind." "Omit -ReturnType$(if ($isAccessor) { ' (the accessor uses the type of its property)' })."
    }
    if ($Kind -eq 'Property' -and $rt -eq '') {
        return & $fail 'POU_MEMBER_INVALID' 'return-type' '-ReturnType (the property type) is required for -Kind Property.' 'Pass -ReturnType, e.g. INT or LREAL.'
    }

    $n = [regex]::Escape($spec.ItemName)
    $t = [regex]::Escape($rt)
    $end = '(?![A-Za-z0-9_])'
    $accPat = if ($acc -eq 'PUBLIC') { '(PUBLIC\s+)?' } else { [regex]::Escape($acc) + '\s+' }
    switch ($spec.SubType) {
        609 {
            if ($rt -eq '') {
                if ($acc -ne 'PUBLIC' -or $lang -ne 'ST') {
                    return & $fail 'POU_MEMBER_UNSUPPORTED' 'method-no-return-type' "A method without -ReturnType is only created with Access PUBLIC and Language ST (vInfo null, measured 2026-10-31 4026 VS2022); { language, '', access } is not measured." 'Pass -ReturnType (e.g. BOOL), or omit -Access / -Language; the declaration can be changed afterwards with Write-TcPouCode.'
                }
                $spec.VInfo = $null
                $spec.DeclarationPattern = '(?im)^\s*METHOD\s+(PUBLIC\s+)?' + $n + $end
            }
            else {
                $spec.VInfo = [string[]]@($langNo, $rt, $acc)
                # "METHOD PRIVATE M_LangRet : BOOL" (measured 2026-10-31 4026 VS2022)
                $spec.DeclarationPattern = '(?im)^\s*METHOD\s+' + $accPat + $n + '\s*:\s*' + $t + $end
            }
            $spec.ExpectedLanguage = $lang
        }
        611 {
            $spec.VInfo = [string[]]@($langNo, $rt, $acc)
            # "PROPERTY PUBLIC P_LangType : INT" (measured 2026-10-31 4026 VS2022)
            $spec.DeclarationPattern = '(?im)^\s*PROPERTY\s+' + $accPat + $n + '\s*:\s*' + $t + $end
        }
        { $_ -in 613, 614 } {
            $spec.VInfo = [string[]]@($langNo, $acc)
            # declaration "PUBLIC / VAR / END_VAR" (measured 2026-10-31 4026 VS2022 with PUBLIC;
            # the other access values are not measured)
            $spec.DeclarationPattern = '(?im)^\s*' + [regex]::Escape($acc) + '\s*$'
        }
        608 {
            # an action has no declaration (DeclarationText does not exist, measured 2026-10-31)
            $spec.VInfo = [string[]]@($langNo)
            $spec.NoDeclaration = $true
            $spec.ExpectedLanguage = $lang
        }
        610 {
            # only the return type: a name in the array is joined into the return type
            # ("METHOD M_ItfNR : M_ItfNR" + "BOOL", measured 2026-10-31 4026 VS2022)
            if ($rt -eq '') {
                $spec.VInfo = $null
                $spec.DeclarationPattern = '(?im)^\s*METHOD\s+' + $n + $end
            }
            else {
                $spec.VInfo = [string[]]@($rt)
                $spec.DeclarationPattern = '(?im)^\s*METHOD\s+' + $n + '\s*:\s*' + $t + $end
            }
            $spec.Language = $null
            $spec.Access = $null
        }
        612 {
            $spec.VInfo = [string[]]@($rt)
            # the type in the header is not checked: the probe read back another type than the
            # vInfo it gave (phase2-probe.md 3.6, "612 ITF property" row), the cause is not known
            $spec.DeclarationPattern = '(?im)^\s*PROPERTY\s+([A-Za-z_]+\s+)?' + $n + $end
            $spec.Language = $null
            $spec.Access = $null
        }
    }
    return $spec
}

function Get-TcTreeItemTypeNumber {
    <#
    .SYNOPSIS
        Reads only ITcSmTreeItem.ItemType of -Item; -1 when it cannot be read.
    .DESCRIPTION
        Used before anything else is read from an item that may be an ITF property accessor
        (654 / 655), whose DeclarationText crashed VS2022 (see $script:TcItfAccessorItemTypes).
        IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG / IDE_TIMEOUT are rethrown.
    .PARAMETER Item
        ITcSmTreeItem.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Item)
    $it = $Item
    try { return [int](Invoke-TcComRetry -OperationName 'ItemType' -ScriptBlock { $it.ItemType }) }
    catch {
        if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
        return -1
    }
}

function New-TcItfAccessorUnsupportedResult {
    <#
    .SYNOPSIS
        POU_MEMBER_UNSUPPORTED for an ITF property Get / Set (654 / 655) that Get-TcPouCode /
        Write-TcPouCode must not touch.
    .PARAMETER Path
        Tree path of the item.
    .PARAMETER ItemType
        654 or 655.
    .PARAMETER Operation
        'read' or 'write'.
    .PARAMETER Pou
        -PouName as given.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][int]$ItemType,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter()][string]$Pou
    )
    $kind = if ($ItemType -eq 654) { 'ITF_PROPERTY_GET' } else { 'ITF_PROPERTY_SET' }
    New-TcResult -Success $false -ErrorCode 'POU_MEMBER_UNSUPPORTED' `
        -ErrorMessage "'$Path' is the $(if ($ItemType -eq 654) { 'Get' } else { 'Set' }) accessor of an interface property (ItemType $ItemType): its code is not $Operation, reading DeclarationText of such an item crashed VS2022 (measured 2026-10-31, 4026 VS2022, see $($script:TcPouMemberProbeDoc)). Nothing was $(if ($Operation -eq 'read') { 'read' } else { 'written' })." `
        -Hint (Get-TcErrorHint -Code 'POU_MEMBER_UNSUPPORTED') `
        -Data ([PSCustomObject]@{ pou = $Pou; pouPath = $Path; itemType = $ItemType; objectKind = $kind; reason = 'itf-property-accessor' })
}
