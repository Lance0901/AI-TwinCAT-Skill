function Get-TcPouCode {
    <#
    .SYNOPSIS
        Reads declaration and implementation code from an existing POU.
    .PARAMETER PouName
        Name of the POU to read. A member can be named Parent.Member: FB_X.M_Run, FB_X.P_Value.Get
        (tried only after the name as given found nothing; becomes <FB_X path>^M_Run).
    .PARAMETER PouPath
        Full tree path to the POU, e.g. TIPC^<Plc>^<Plc> Project^POUs^<name> (same format on
        4024 and 4026; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>; a method / property / action
        ...^<FB>^<member>, an accessor ...^<FB>^<property>^Get). If omitted (or not found),
        the POU is looked up by PouName: POUs folder -> project root -> tree search (depth 4)
        -> Parent.Member. data.pouPath / data.resolvedBy report which path was used. A name
        that several objects carry (M_Run in two function blocks) returns POU_AMBIGUOUS with
        data.candidates, never the first hit.
    .NOTES
        The Get / Set accessor of an INTERFACE property (ItemType 654 / 655) is refused with
        POU_MEMBER_UNSUPPORTED after reading only its ItemType; an ItemType that cannot be read
        returns POU_READ_FAILED (data.reason itemtype-unreadable, fail-closed). Reading its DeclarationText
        crashed VS2022 (measured 2026-10-31, 4026 VS2022, self-built client; see
        openspec/changes/complete-automation-interface/verification/phase2-probe.md).
        Members (method, property, accessor, action, interface method / property) are read
        like a POU (measured 2026-10-31, 4026 VS2022, self-built client): an action has no
        declaration (data.declaration null), a property and an interface member have no
        implementation.
    .OUTPUTS
        data.objectKind        POU | DUT | GVL | ITF | METHOD | ACTION | PROPERTY | ... | UNKNOWN
                               (from ItemType, see Get-TcPlcObjectKind); data.pouType Program /
                               Function / FunctionBlock (POU) or Struct / Enum / Union / Alias (DUT)
        data.hasImplementation false for DUT / GVL / ITF: implementation is then $null (the object
                               has none) and implementationReadable is $null. For a POU
                               implementation is a string ('' when empty, implementationReadable
                               true); implementationReadable false = the POU has an
                               implementation part that did not come back as text
                               (implementation $null). A property read that fails shows up as
                               null / implementationReadable=false: Windows PowerShell returned
                               $null for a throwing getter (measured 2026-10-25, PS 5.1.26100,
                               on a property of a compiled class; the COM adapter is not
                               verified). A COM call that throws, or a declaration that reads
                               null, returns POU_READ_FAILED.
        data.language          ST / LD / FBD / SFC / CFC / IL ... (ITcSmTreeItem.Language), $null for
                               DUT / GVL / ITF. For LD / FBD the implementation is XAE's XML
                               (<NWL><XmlArchive>...), not ST text (measured 2026-10-25 on 4024 and 4026).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$PouName,

        [Parameter()]
        [string]$PouPath
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    try {
        $r = Resolve-TcPouPath -SysManager $sm -Name $PouName -PouPath $PouPath
        if (-not $r.Found) {
            if ($r.Ambiguous) { return New-TcPouAmbiguousResult -Name $PouName -Resolution $r }
            return New-TcPouNotFoundResult -Name $PouName -Resolution $r
        }
        $pouItem = $r.Item

        # ItemType alone first: nothing else is read from an ITF property accessor (654 / 655)
        $itemTypeNo = Get-TcTreeItemTypeNumber -Item $pouItem
        # fail-closed: an unreadable ItemType may be a 654 / 655, so nothing else is read
        if ($itemTypeNo -eq -1) {
            return New-TcResult -Success $false -ErrorCode 'POU_READ_FAILED' `
                -ErrorMessage "ItemType of '$($r.Path)' cannot be read, so its code is not read (it could be an interface property accessor, see POU_MEMBER_UNSUPPORTED). Nothing was read." `
                -Hint (Get-TcErrorHint -Code 'POU_READ_FAILED') `
                -Data ([PSCustomObject]@{ pou = $PouName; pouPath = $r.Path; reason = 'itemtype-unreadable' })
        }
        if ($script:TcItfAccessorItemTypes -contains $itemTypeNo) {
            return New-TcItfAccessorUnsupportedResult -Path $r.Path -ItemType $itemTypeNo -Operation 'read' -Pou $PouName
        }

        # objectKind / hasImplementation from ItemType (Get-TcPlcObjectKind): a DUT / GVL / ITF
        # has no implementation part, so implementation = $null means "none", not "read failed"
        $kind = Get-TcPlcObjectKind -Item $pouItem
        $declText = Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $pouItem.DeclarationText }
        # a declaration that reads $null is a failed read for the measured types (POU, DUT, GVL,
        # ITF, method, ITF method, property all return one; an action has none: ItemType 608
        # reads $null, measured 2026-10-25 on 4024 and 4026). 612-616 are not measured: a
        # transition (616) may have no declaration like an action, so it is let through too;
        # measured 2026-10-25 on 4024 and 4026); $null otherwise means the read failed
        if ($null -eq $declText -and $kind.ObjectKind -notin @('ACTION', 'TRANSITION')) {
            return New-TcResult -Success $false -ErrorCode 'POU_READ_FAILED' `
                -ErrorMessage "Failed to read POU code: DeclarationText of '$($r.Path)' ($($kind.ObjectKind)) came back empty (null)." `
                -Hint (Get-TcErrorHint -Code 'POU_READ_FAILED') `
                -Data ([PSCustomObject]@{ pou = $PouName; pouPath = $r.Path; objectKind = $kind.ObjectKind })
        }
        $hasImpl = $kind.HasImplementation
        $implText = $null
        $implReadable = $null
        if ($hasImpl -ne $false) {
            $implText = Invoke-TcComRetry -OperationName 'Get ImplementationText' -ScriptBlock { $pouItem.ImplementationText }
            if ($null -eq $hasImpl) {
                # unknown ItemType: an item without ImplementationText gives $null through late
                # binding (as DUT / GVL / ITF do, measured 2026-10-25 on 4024 and 4026)
                $hasImpl = ($null -ne $implText)
            }
            # an empty ST body reads '' (measured 2026-10-25 on 4024 and 4026); $null on an object
            # that has an implementation part means it could not be read as text
            if ($hasImpl) { $implReadable = ($null -ne $implText) } else { $implReadable = $null }
        }
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            pou                    = $PouName
            pouPath                = $r.Path
            resolvedBy             = $r.ResolvedBy
            objectKind             = $kind.ObjectKind
            pouType                = $kind.PouType
            itemType               = $kind.ItemType
            itemTypeName           = $kind.ItemTypeName
            language               = $kind.Language
            hasImplementation      = $hasImpl
            implementationReadable = $implReadable
            declaration            = $declText
            implementation         = $implText
        })
    }
    catch {
        if ($_.Exception.Message -like 'PLC_PROJECT_NOT_FOUND*') {
            return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND')
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_READ_FAILED' -MessagePrefix 'Failed to read POU code'
    }
}
