function Add-TcGvl {
    <#
    .SYNOPSIS
        Adds a Global Variable List (GVL) to the PLC project.
    .PARAMETER Name
        GVL name (e.g., GVL_Main).
    .PARAMETER Variables
        Optional hashtable of variable declarations (name = type).
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
        $created = New-TcPlcObject -SysManager $sm -ParentPath $folderInfo.Path -Name $Name -SubType 615 -Declaration $decl
        if ($created.ContainsKey('ModalDialog')) {
            return New-TcModalDialogResult -Dialog $created.ModalDialog -Operation "CreateChild $Name"
        }
        $kind = Get-TcPlcObjectKind -ItemType $created.ItemType

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name        = $Name
            path        = $created.Path
            folderPath  = $folderInfo.Path
            objectKind  = $kind.ObjectKind
            itemType    = $created.ItemType
            declaration = $created.Declaration
            duplicateCheckScope        = $created.DuplicateCheckScope
            duplicateCheckSkippedNodes = $created.DuplicateCheckSkippedNodes
            duplicateCheckNote         = $created.DuplicateCheckNote
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'GVL_CREATE_FAILED' -MessagePrefix 'Failed to add GVL'
    }
}
