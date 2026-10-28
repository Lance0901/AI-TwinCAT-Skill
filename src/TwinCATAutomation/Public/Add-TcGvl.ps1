function Add-TcGvl {
    <#
    .SYNOPSIS
        Adds a Global Variable List (GVL) to the PLC project.
    .PARAMETER Name
        GVL name (e.g., GVL_Main).
    .PARAMETER Variables
        Optional hashtable of variable declarations (name = type).
    .NOTES
        Project file (#76): after the readback the project file is saved and the .plcproj is
        read back from disk (as Add-TcPou): success only with a <Compile Include> for
        <folders>\<Name>.TcGVL (relative path; data.projectSaved), otherwise PROJECT_SAVE_FAILED
        (or PROJECT_SAVE_TIMEOUT / IDE_MODAL_DIALOG / IDE_*). What else Project.Save writes
        (measured 2026-10-28, 4026 VisualStudio.DTE.17.0): a dirty plain text document was NOT
        saved; whether unsaved content of a PLC editor (a POU edited in the GUI) is written was
        NOT verified.
        BUILD_REQUIRED (#65): after CreateChild was called (success, or a failure from the
        lookup / kind / language / declare step on, or CreateChild itself failing) the solution
        is recorded as 'code-changed' (Register-TcCodeChange): Enable-TcConfig and
        Enter-TcPlcOnline refuse until a complete Build-TcProject. data.buildRequired /
        data.stateWarning as in Build-TcProject. A failure before CreateChild records nothing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [hashtable]$Variables
    )

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
        if ($Variables) {
            foreach ($var in $Variables.GetEnumerator()) {
                $decl += "    $($var.Key) : $($var.Value);`n"
            }
        }
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
        })
        Register-TcCodeChange -Result $ok -Change "Add-TcGvl $Name"
    }
    catch {
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'GVL_CREATE_FAILED' -MessagePrefix 'Failed to add GVL'
        # conservative (#65): CreateChild was called, the object may exist in the tree
        if ($createProgress['CreateCalled']) { return Register-TcCodeChange -Result $res -Change "Add-TcGvl $Name [failed after CreateChild]" }
        $res
    }
}
