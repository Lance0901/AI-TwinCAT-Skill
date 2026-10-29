function Add-TcGvl {
    <#
    .SYNOPSIS
        Adds a Global Variable List (GVL) to the PLC project.
    .PARAMETER Name
        GVL name (e.g., GVL_Main).
    .PARAMETER Variables
        Optional variables, in declaration order (#47): an array of
        @{ name; type; init (optional); comment (optional) } entries, e.g.
        @(@{ name = 'bStart'; type = 'BOOL' }, @{ name = 'nCount'; type = 'INT'; init = '0' }),
        or [ordered]@{ bStart = 'BOOL'; nCount = 'INT' }. A plain hashtable with more than one
        member is INVALID_PARAMS (a hashtable does not keep the input order); a single-member
        hashtable is accepted.
    .NOTES
        Member order (#47): after the project file is saved the declaration read back from XAE is
        parsed (Get-TcDeclarationMemberOrder) and its variable order compared with the input order
        (case-insensitive): any difference is MEMBER_ORDER_MISMATCH (data.expectedOrder,
        data.actualOrder, data.declaration; the GVL exists and is recorded code-changed), never
        success. On success data.memberOrder lists the variables read back.
        Project file (#76): after the readback the project file is saved and the .plcproj is
        read back from disk (as Add-TcPou): success only with a <Compile Include> for
        <folders>\<Name>.TcGVL (relative path; data.projectSaved), otherwise PROJECT_SAVE_FAILED
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

        [Parameter()]
        [object]$Variables
    )

    # #47: ordered member input, checked before anything touches the IDE
    $conv = ConvertTo-TcMemberList -InputObject $Variables -Kind 'Var' -ParameterName 'Variables'
    if ($null -ne $conv.Error) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -ErrorMessage $conv.Error `
            -Hint 'Pass Variables as an array in declaration order: [{"name":"bStart","type":"BOOL"},{"name":"nCount","type":"INT","init":"0"}] (PowerShell: an array of hashtables or [ordered]@{}); nothing was created.'
    }
    $memberList = @($conv.Members)

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    $createProgress = @{}   # CreateCalled: set by New-TcPlcObject (#65)
    try {
        # TIPC^<Plc>^<Plc> Project^GVLs (falls back to the <Plc> Project node)
        $folderInfo = Resolve-TcPlcProjectFolder -SysManager $sm -FolderName 'GVLs'

        # Build declaration
        $decl = "VAR_GLOBAL`n"
        foreach ($line in (Format-TcMemberDeclaration -Members $memberList -Kind 'Var')) { $decl += "$line`n" }
        $decl += "END_VAR"

        # 615 = TREEITEMTYPE_PLCGVL, ItemType value from https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html
        # (used as CreateChild sub type: measured 2026-10-25 on 4024 and 4026).
        # Created without vInfo, then the declaration is written and read back. A string vInfo
        # is stored verbatim as declaration: the old '<Declaration><![CDATA[...]]>' wrapper ended
        # up in the GVL source (measured 2026-10-25 on 4024).
        $created = New-TcPlcObject -SysManager $sm -ParentPath $folderInfo.Path -Name $Name -SubType 615 -Declaration $decl -Progress $createProgress
        if ($created.ContainsKey('ModalDialog')) {
            return New-TcModalDialogResult -Dialog $created.ModalDialog -Operation "CreateChild $Name"
        }
        $kind = Get-TcPlcObjectKind -ItemType $created.ItemType

        # #76: save the project file and read the new <Compile Include> back from disk
        $save = Invoke-TcPlcObjectSave -ObjectPath $created.Path -ExpectFile "$Name.TcGVL" -What "GVL '$Name'"
        if ($null -ne $save.Error) { return Register-TcCodeChange -Result $save.Error -Change "Add-TcGvl $Name [created, project file not saved]" }

        # #47: the variable order read back must be the input order
        $order = Test-TcMemberOrder -Members $memberList -Declaration $created.Declaration -Kind 'Var'
        if (-not $order.Ok) {
            $bad = New-TcResult -Success $false -ErrorCode 'MEMBER_ORDER_MISMATCH' -Hint $script:TcErrorHints['MEMBER_ORDER_MISMATCH'] `
                -ErrorMessage "GVL '$Name' was created, but the variable order read back ($($order.Actual -join ', ')) differs from the input order ($($order.Expected -join ', '))." `
                -Data ([PSCustomObject]@{ name = $Name; path = $created.Path; expectedOrder = $order.Expected; actualOrder = $order.Actual; declaration = $created.Declaration; projectSaved = $save.Saved })
            return Register-TcCodeChange -Result $bad -Change "Add-TcGvl $Name [member order mismatch]"
        }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            name        = $Name
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
        Register-TcCodeChange -Result $ok -Change "Add-TcGvl $Name"
    }
    catch {
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'GVL_CREATE_FAILED' -MessagePrefix 'Failed to add GVL'
        # conservative (#65): CreateChild was called, the object may exist in the tree; not when
        # CreateChild itself returned an error (CreateFailed: XAE refused, e.g. PLC_LOGGED_IN, task 1.8)
        if ($createProgress['CreateCalled'] -and -not $createProgress['CreateFailed']) { return Register-TcCodeChange -Result $res -Change "Add-TcGvl $Name [failed after CreateChild]" }
        $res
    }
}
