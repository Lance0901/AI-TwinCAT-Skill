function Add-TcPouMember {
    <#
    .SYNOPSIS
        Adds a method, property, property Get / Set accessor or action to a POU or interface and reads it back.
    .DESCRIPTION
        ITcSmTreeItem::CreateChild(name, subType, '', vInfo) on the parent (TE1000 Automation
        Interface manual v1.7.0, 6.5.5 "Creating and handling POUs" p.229-231). Sub type and vInfo
        (TE1000 6.5.5 table; vInfo measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built
        client, openspec/changes/complete-automation-interface/verification/phase2-probe.md 3.6):
          parent PROGRAM / FUNCTION_BLOCK   Method 609 { lang, returnType, access }
                                            Property 611 { lang, type, access }
                                            Action 608 { lang }
          parent INTERFACE                  Method 610 { returnType } (or none)
                                            Property 612 { type }
          parent PROPERTY (611)             Get 613 / Set 614 { lang, access }
        lang = IECLANGUAGETYPES number (TE1000 5.46.5: ST 1, IL 2, SFC 3, FBD 4, CFC 5, LD 6); the
        manual example { name, returnType } fails with "Language type not supported!" (measured).
        Access is checked by the module: XAE silently makes an unknown access PUBLIC (measured).
        A property gets no Get / Set by itself (measured 2026-10-25 and 2026-10-31): add them with
        -Kind Get / Set and the property path as -ParentPath.
        Refused (POU_MEMBER_UNSUPPORTED, nothing created): Get / Set below an INTERFACE property
        (654 / 655): reading the code of such an accessor crashed VS2022 twice (measured
        2026-10-31, 4026 VS2022, devenv.exe KERNELBASE.dll 0xe06d7363); a method without
        -ReturnType with -Access other than PUBLIC or -Language other than ST (only vInfo $null
        is measured for it; its language is reported, not checked); a Get / Set accessor with
        -Access other than PUBLIC or -Language other than ST (only { '1', 'PUBLIC' } is measured,
        reason accessor-not-measured).
        Checks before CreateChild (nothing created on failure): parameters (POU_MEMBER_INVALID),
        parent found (POU_NOT_FOUND / POU_AMBIGUOUS) and of a fitting kind (POU_MEMBER_INVALID),
        no child of the parent with the same name, case-insensitive (POU_MEMBER_EXISTS: XAE's
        own error for a second Get is "SubType mismatch", measured), no modal dialog in XAE
        (IDE_MODAL_DIALOG). After CreateChild the new item is looked up and its ItemType must be
        the sub type; the declaration read back must name the member, its access and its type
        (method / property / ITF method), an accessor's must hold its access, an action has no
        declaration and is not read; action and a method with -ReturnType must report -Language
        (data.language is always the language read back). Only then success.
        A failed readback after CreateChild returns POU_MEMBER_CREATE_FAILED with the step
        (lookup / kind / language / declare) and the member stays in the tree.
        No project save: CreateChild writes the parent's .TcPOU / .TcIO at once and does not
        change the .plcproj (measured 2026-10-31, 4026 VS2022).
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER ParentPath
        The POU, interface or property that gets the member: a full tree path
        (TIPC^<Plc>^<Plc> Project^POUs^FB_Motor, ...^FB_Motor^P_Speed for Get / Set) or a name as
        for Get-TcPouCode -PouName (FB_Motor, FB_Motor.P_Speed). A name several objects carry
        returns POU_AMBIGUOUS with data.candidates.
    .PARAMETER Kind
        Method, Property, Action, Get or Set.
    .PARAMETER Name
        Member name (IEC identifier). Not needed for Get / Set: an accessor is always named Get / Set.
    .PARAMETER ReturnType
        Method: return type (optional; none = a method without return type). Property: its type
        (required). Not allowed for Action / Get / Set.
    .PARAMETER Access
        PUBLIC (default), PRIVATE, PROTECTED or INTERNAL (TE1000 6.5.5 p.231). Anything else
        returns POU_MEMBER_INVALID. Interface members and actions take none; Get / Set only PUBLIC.
    .PARAMETER Language
        Implementation language of a method / action / accessor: ST (default), IL, SFC, FBD, CFC or LD.
    .OUTPUTS
        data.path is the full tree path of the new member: pass it as -PouPath to
        Get-TcPouCode / Write-TcPouCode. data: name, kind, parentPath, parentKind, subType,
        itemType, itemTypeName, objectKind, language, access, returnType, vInfo, declaration
        (null for an action), resolvedBy (how -ParentPath was found).
    .NOTES
        BUILD_REQUIRED (#65): a created member (also one whose readback failed, or a CreateChild
        that failed with IDE_*) records kind code-changed (Register-TcCodeChange); an error
        CreateChild returned itself (XAE refused, nothing created) records nothing.
        PLC_LOGGED_IN: XAE refuses CreateChild while the PLC is logged in (measured 2026-10-29 for
        a GVL, 4026 VS2022; the same CreateChild path): call Exit-TcPlcOnline first.
    .EXAMPLE
        Add-TcPouMember -ParentPath 'TIPC^Plc^Plc Project^POUs^FB_Motor' -Kind Method -Name M_Start -ReturnType BOOL -Access PRIVATE
    .EXAMPLE
        Add-TcPouMember -ParentPath FB_Motor -Kind Property -Name P_Speed -ReturnType LREAL
        Add-TcPouMember -ParentPath FB_Motor.P_Speed -Kind Get
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ParentPath,

        [Parameter(Mandatory)]
        [ValidateSet('Method', 'Property', 'Action', 'Get', 'Set')]
        [string]$Kind,

        [Parameter()]
        [string]$Name,

        [Parameter()]
        [string]$ReturnType,

        [Parameter()]
        [string]$Access = 'PUBLIC',

        [Parameter()]
        [ValidateSet('ST', 'IL', 'SFC', 'FBD', 'CFC', 'LD')]
        [string]$Language = 'ST'
    )

    $data = [PSCustomObject]@{ parentPath = $ParentPath; kind = $Kind; name = $Name }
    # -Access (XAE would turn a wrong value into PUBLIC without an error) is validated in one
    # place only: Get-TcPouMemberSpec, before anything is created

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $createProgress = @{}   # CreateCalled / CreateFailed: set by New-TcPlcObject (#65)
    $changeName = "Add-TcPouMember $ParentPath $Kind $Name".TrimEnd()
    try {
        # parent: explicit path, else by name (Parent.Member, POU_AMBIGUOUS) as Get-TcPouCode does
        $pr = Resolve-TcPouPath -SysManager $sm -Name $ParentPath -PouPath $ParentPath
        if (-not $pr.Found) {
            if ($pr.Ambiguous) { return New-TcPouAmbiguousResult -Name $ParentPath -Resolution $pr }
            return New-TcPouNotFoundResult -Name $ParentPath -Resolution $pr
        }
        $parent = $pr.Item
        $parentPathFull = [string]$pr.Path
        # ItemType only: an ITF property accessor (654 / 655) must not be read further
        $parentType = Get-TcTreeItemTypeNumber -Item $parent
        $parentKind = (Get-TcPlcObjectKind -ItemType $parentType).ObjectKind

        $spec = Get-TcPouMemberSpec -Kind $Kind -ParentItemType $parentType -ParentPath $parentPathFull -Name $Name `
            -ReturnType $ReturnType -Access $Access -Language $Language `
            -AccessGiven:($PSBoundParameters.ContainsKey('Access')) -LanguageGiven:($PSBoundParameters.ContainsKey('Language'))
        if ($null -ne $spec.Error) {
            return New-TcResult -Success $false -ErrorCode $spec.Error.Code -ErrorMessage "$($spec.Error.Message) Nothing was created." `
                -Hint $spec.Error.Hint `
                -Data ([PSCustomObject]@{ parentPath = $parentPathFull; parentKind = $parentKind; parentItemType = $parentType; kind = $Kind; name = $Name; reason = $spec.Error.Reason })
        }
        $memberName = [string]$spec.ItemName
        $changeName = "Add-TcPouMember $parentPathFull^$memberName"

        # same name below the parent (members are scoped to their POU: "already exists within the
        # corresponding namespace", measured 2026-10-31)
        $existing = Invoke-TcComRetry -OperationName "Children of $parentPathFull" -ScriptBlock {
            $__hits = [System.Collections.Generic.List[string]]::new()
            $__cnt = [int]$parent.ChildCount
            for ($__i = 1; $__i -le $__cnt; $__i++) {
                $__c = $parent.Child($__i)
                if ([string]$__c.Name -ieq $memberName) { $__hits.Add([string]$__c.PathName) }
            }
            , $__hits.ToArray()
        }
        if (@($existing).Count -gt 0) {
            $first = @($existing)[0]
            if ([string]::IsNullOrWhiteSpace($first)) { $first = "$parentPathFull^$memberName" }
            return New-TcResult -Success $false -ErrorCode 'POU_MEMBER_EXISTS' `
                -ErrorMessage "'$parentPathFull' already has a child named '$memberName' ($first). Nothing was created." `
                -Hint (Get-TcErrorHint -Code 'POU_MEMBER_EXISTS') `
                -Data ([PSCustomObject]@{ parentPath = $parentPathFull; kind = $Kind; name = $memberName; existingPath = $first })
        }

        $np = @{
            SysManager = $sm; ParentPath = $parentPathFull; Name = $memberName; SubType = $spec.SubType; VInfo = $spec.VInfo
            SkipProjectNameCheck = $true; NoDeclaration = [bool]$spec.NoDeclaration; Progress = $createProgress
        }
        if (-not [string]::IsNullOrWhiteSpace($spec.ExpectedLanguage)) { $np['ExpectedLanguage'] = $spec.ExpectedLanguage }
        if (-not [string]::IsNullOrWhiteSpace($spec.DeclarationPattern)) { $np['DeclarationPattern'] = $spec.DeclarationPattern }
        # dialog check, CreateChild, lookup, ItemType, language, declaration readback
        $created = New-TcPlcObject @np
        if ($created.ContainsKey('ModalDialog')) {
            return New-TcModalDialogResult -Dialog $created.ModalDialog -Operation "CreateChild $parentPathFull^$memberName"
        }
        $kindInfo = Get-TcPlcObjectKind -ItemType $created.ItemType
        $itemTypeName = $null
        $ci = $created.Item
        try { $itemTypeName = [string](Invoke-TcComRetry -OperationName 'ItemSubTypeName' -ScriptBlock { $ci.ItemSubTypeName }) }
        catch {
            if ($_.Exception.Message -match 'IDE_BUSY|IDE_CRASHED|IDE_MODAL_DIALOG|IDE_TIMEOUT') { throw }
            $itemTypeName = $null
        }
        if ([string]::IsNullOrWhiteSpace($itemTypeName)) { $itemTypeName = $null }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            name         = $memberName
            kind         = $Kind
            path         = $created.Path
            parentPath   = $parentPathFull
            parentKind   = $parentKind
            resolvedBy   = $pr.ResolvedBy
            subType      = $spec.SubType
            itemType     = $created.ItemType
            itemTypeName = $itemTypeName
            objectKind   = $kindInfo.ObjectKind
            language     = $created.Language
            access       = $spec.Access
            returnType   = $(if ([string]::IsNullOrWhiteSpace($ReturnType)) { $null } else { $ReturnType.Trim() })
            vInfo        = $(if ($null -eq $spec.VInfo) { $null } else { [string[]]$spec.VInfo })
            declaration  = $created.Declaration
        })
        Register-TcCodeChange -Result $ok -Change $changeName
    }
    catch {
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_MEMBER_CREATE_FAILED' -MessagePrefix 'Failed to add POU member' -Data $data
        if ($_.Exception.Message -like 'PLC_PROJECT_NOT_FOUND*') {
            return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND')
        }
        # conservative (#65): CreateChild was called, the member may exist; not when CreateChild
        # itself returned an error (CreateFailed: XAE refused, e.g. PLC_LOGGED_IN)
        if ($createProgress['CreateCalled'] -and -not $createProgress['CreateFailed']) { return Register-TcCodeChange -Result $res -Change "$changeName [failed after CreateChild]" }
        $res
    }
}
