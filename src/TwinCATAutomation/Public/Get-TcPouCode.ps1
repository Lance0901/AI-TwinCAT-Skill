function Get-TcPouCode {
    <#
    .SYNOPSIS
        Reads declaration and implementation code from an existing POU.
    .PARAMETER PouName
        Name of the POU to read.
    .PARAMETER PouPath
        Full tree path to the POU, e.g. TIPC^<Plc>^<Plc> Project^POUs^<name> (same format on
        4024 and 4026; DUT ...^DUTs^<name>, GVL ...^GVLs^<name>). If omitted (or not found),
        the POU is looked up by PouName: POUs folder -> project root -> tree search (depth 4).
        data.pouPath / data.resolvedBy report which path was used.
    .OUTPUTS
        data.objectKind        POU | DUT | GVL | ITF | METHOD | ACTION | PROPERTY | ... | UNKNOWN
                               (from ItemType, see Get-TcPlcObjectKind); data.pouType Program /
                               Function / FunctionBlock (POU) or Struct / Enum / Union / Alias (DUT)
        data.hasImplementation false for DUT / GVL / ITF: implementation is then $null (the object
                               has none) and implementationReadable is $null. For a POU
                               implementation is a string ('' when empty, implementationReadable
                               true); implementationReadable false = the POU has an
                               implementation part that did not come back as text
                               (implementation $null; also how a failing property get ends up,
                               since Windows PowerShell turns a throwing getter into $null). A
                               COM call that throws returns POU_READ_FAILED.
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
            return New-TcPouNotFoundResult -Name $PouName -Resolution $r
        }
        $pouItem = $r.Item

        # objectKind / hasImplementation from ItemType (Get-TcPlcObjectKind): a DUT / GVL / ITF
        # has no implementation part, so implementation = $null means "none", not "read failed"
        $kind = Get-TcPlcObjectKind -Item $pouItem
        $declText = Invoke-TcComRetry -OperationName 'Get DeclarationText' -ScriptBlock { $pouItem.DeclarationText }
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
            $implReadable = ($null -ne $implText)
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
