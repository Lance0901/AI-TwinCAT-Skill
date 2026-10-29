function Add-TcDut {
    <#
    .SYNOPSIS
        Adds a Data Unit Type (STRUCT, ENUM, ALIAS, UNION) to the PLC project.
    .PARAMETER Name
        DUT name (e.g., ST_MotorData, E_State).
    .PARAMETER DutType
        DUT type: Struct, Enum, Alias, Union.
    .PARAMETER Fields
        Optional members, in declaration order (#47). Struct / Union: an array of
        @{ name; type; init (optional); comment (optional) } entries, e.g.
        @(@{ name = 'bStart'; type = 'BOOL' }, @{ name = 'nCount'; type = 'INT'; init = '0' }),
        or [ordered]@{ bStart = 'BOOL'; nCount = 'INT' }. Enum: an array of
        @{ name; value (optional); comment (optional) } entries, or [ordered]@{ eIdle = 0; eRun = 1 }.
        A plain hashtable with more than one member is INVALID_PARAMS (a hashtable does not keep
        the input order); a single-member hashtable is accepted.
    .PARAMETER AliasType
        Base type for Alias DUT.
    .NOTES
        Member order (#47): after the project file is saved the declaration read back from XAE is
        parsed (Get-TcDeclarationMemberOrder) and its member order compared with the input order
        (case-insensitive): any difference is MEMBER_ORDER_MISMATCH (data.expectedOrder,
        data.actualOrder, data.declaration; the DUT exists and is recorded code-changed), never
        success. On success data.memberOrder lists the members read back.
        Project file (#76): after the readback the project file is saved and the .plcproj is
        read back from disk (as Add-TcPou): success only with a <Compile Include> for
        <folders>\<Name>.TcDUT (relative path; data.projectSaved), otherwise PROJECT_SAVE_FAILED
        (or PROJECT_SAVE_TIMEOUT / IDE_MODAL_DIALOG / IDE_*). What else Project.Save writes
        (measured 2026-10-28, 4026 VisualStudio.DTE.17.0): a dirty plain text document was NOT
        saved; whether unsaved content of a PLC editor (a POU edited in the GUI) is written was
        NOT verified.
        BUILD_REQUIRED (#65): after CreateChild was called (success, or a failure from the
        lookup / kind / language / declare step on, or CreateChild failing with an IDE_* busy /
        crash / modal / timeout error) the solution
        is recorded as 'code-changed' (Register-TcCodeChange): Enable-TcConfig and
        Enter-TcPlcOnline refuse until a complete Build-TcProject. data.buildRequired /
        data.stateWarning as in Build-TcProject. A failure before CreateChild, or an error
        returned by CreateChild itself (XAE refused it, nothing created), records nothing.
        PLC_LOGGED_IN: XAE refuses CreateChild while the PLC is logged in ("... affects a device
        you are currently logged into", measured 2026-10-29, 4026 XAE in VS2022): call
        Exit-TcPlcOnline first, then add the object again.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Struct', 'Enum', 'Alias', 'Union')]
        [string]$DutType,

        [Parameter()]
        [object]$Fields,

        [Parameter()]
        [string]$AliasType
    )

    # #47: ordered member input, checked before anything touches the IDE
    $memberKind = if ($DutType -eq 'Enum') { 'Enum' } else { 'Var' }
    $memberList = @()
    if ($DutType -ne 'Alias') {
        $conv = ConvertTo-TcMemberList -InputObject $Fields -Kind $memberKind -ParameterName 'Fields'
        if ($null -ne $conv.Error) {
            return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -ErrorMessage $conv.Error `
                -Hint 'Pass Fields as an array in declaration order: Struct / Union [{"name":"bStart","type":"BOOL"},{"name":"nCount","type":"INT","init":"0"}], Enum [{"name":"eIdle","value":0},{"name":"eRun","value":1}] (PowerShell: an array of hashtables or [ordered]@{}); nothing was created.'
        }
        $memberList = @($conv.Members)
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    # Sub types = the ItemType values of InfoSys "ITcSmTreeItem Item Types"
    # (https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html); using
    # them as CreateChild sub types for DUTs is measured (2026-10-25, 4024 TcXaeShell.DTE.15.0
    # and 4026 VisualStudio.DTE.17.0), the CreateChild page only names 603 / 604.
    # 610-613 (used before #17) are interface method / property types: XAE answers
    # "Creating the child type 'TREEITEMTYPE_PLCITFMETH' is not possible on parent node type
    # 'TREEITEMTYPE_PLCFOLDER'" (E_FAIL, measured 2026-10-25 on 4024).
    $dutSubTypes = @{
        'Enum'   = 605   # TREEITEMTYPE_PLCDUTENUM
        'Struct' = 606   # TREEITEMTYPE_PLCDUTSTRUCT
        'Union'  = 607   # TREEITEMTYPE_PLCDUTUNION
        'Alias'  = 623   # TREEITEMTYPE_PLCDUTALIAS
    }

    $createProgress = @{}   # CreateCalled: set by New-TcPlcObject (#65)
    try {
        # TIPC^<Plc>^<Plc> Project^DUTs (falls back to the <Plc> Project node)
        $folderInfo = Resolve-TcPlcProjectFolder -SysManager $sm -FolderName 'DUTs'

        # Build declaration
        switch ($DutType) {
            'Struct' {
                $decl = "TYPE $Name :`nSTRUCT`n"
                foreach ($line in (Format-TcMemberDeclaration -Members $memberList -Kind 'Var')) { $decl += "$line`n" }
                $decl += "END_STRUCT`nEND_TYPE"
            }
            'Enum' {
                $decl = "TYPE $Name :`n(`n"
                if ($memberList.Count -gt 0) {
                    $decl += ((Format-TcMemberDeclaration -Members $memberList -Kind 'Enum') -join "`n") + "`n"
                }
                else {
                    # an ENUM needs at least one member to compile; same placeholder XAE writes for
                    # CreateChild 605 without vInfo ("enum_member := 0", measured 2026-10-25 on 4024
                    # TcXaeShell.DTE.15.0)
                    $decl += "    enum_member := 0`n"
                }
                $decl += ");`nEND_TYPE"
            }
            'Alias' {
                $baseType = if ($AliasType) { $AliasType } else { 'INT' }
                $decl = "TYPE $Name : $baseType;`nEND_TYPE"
            }
            'Union' {
                $decl = "TYPE $Name :`nUNION`n"
                foreach ($line in (Format-TcMemberDeclaration -Members $memberList -Kind 'Var')) { $decl += "$line`n" }
                $decl += "END_UNION`nEND_TYPE"
            }
        }

        # created without vInfo (XAE writes its default declaration), then the declaration is
        # written and read back by New-TcPlcObject (CreateChild documents no vInfo for DUTs:
        # https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425844363.html)
        # Exception: an alias needs its base type as vInfo, without it XAE answers "Base class
        # not specified! Parameter name: baseClass" (measured 2026-10-25 on 4024).
        $vInfo = $null
        if ($DutType -eq 'Alias') { $vInfo = $baseType }
        $created = New-TcPlcObject -SysManager $sm -ParentPath $folderInfo.Path -Name $Name -SubType $dutSubTypes[$DutType] -VInfo $vInfo -Declaration $decl -Progress $createProgress
        if ($created.ContainsKey('ModalDialog')) {
            return New-TcModalDialogResult -Dialog $created.ModalDialog -Operation "CreateChild $Name"
        }
        $kind = Get-TcPlcObjectKind -ItemType $created.ItemType

        # #76: save the project file and read the new <Compile Include> back from disk
        $save = Invoke-TcPlcObjectSave -ObjectPath $created.Path -ExpectFile "$Name.TcDUT" -What "DUT '$Name'"
        if ($null -ne $save.Error) { return Register-TcCodeChange -Result $save.Error -Change "Add-TcDut $Name [created, project file not saved]" }

        # #47: the member order read back must be the input order
        $order = Test-TcMemberOrder -Members $memberList -Declaration $created.Declaration -Kind $memberKind
        if (-not $order.Ok) {
            $bad = New-TcResult -Success $false -ErrorCode 'MEMBER_ORDER_MISMATCH' -Hint $script:TcErrorHints['MEMBER_ORDER_MISMATCH'] `
                -ErrorMessage "DUT '$Name' was created, but the member order read back ($($order.Actual -join ', ')) differs from the input order ($($order.Expected -join ', '))." `
                -Data ([PSCustomObject]@{ name = $Name; path = $created.Path; expectedOrder = $order.Expected; actualOrder = $order.Actual; declaration = $created.Declaration; projectSaved = $save.Saved })
            return Register-TcCodeChange -Result $bad -Change "Add-TcDut $Name [member order mismatch]"
        }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            name        = $Name
            dutType     = $DutType
            path        = $created.Path
            folderPath  = $folderInfo.Path
            objectKind  = $kind.ObjectKind
            itemType    = $created.ItemType
            declaration = $created.Declaration
            duplicateCheckScope        = $created.DuplicateCheckScope
            duplicateCheckSkippedNodes = $created.DuplicateCheckSkippedNodes
            duplicateCheckNote         = $created.DuplicateCheckNote
            projectSaved               = $save.Saved
            memberOrder                = $order.Actual
        })
        Register-TcCodeChange -Result $ok -Change "Add-TcDut $Name"
    }
    catch {
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'DUT_CREATE_FAILED' -MessagePrefix 'Failed to add DUT'
        # conservative (#65): CreateChild was called, the object may exist in the tree; not when
        # CreateChild itself returned an error (CreateFailed: XAE refused, e.g. PLC_LOGGED_IN, task 1.8)
        if ($createProgress['CreateCalled'] -and -not $createProgress['CreateFailed']) { return Register-TcCodeChange -Result $res -Change "Add-TcDut $Name [failed after CreateChild]" }
        $res
    }
}
