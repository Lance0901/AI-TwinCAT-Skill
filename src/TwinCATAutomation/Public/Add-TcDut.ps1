function Add-TcDut {
    <#
    .SYNOPSIS
        Adds a Data Unit Type (STRUCT, ENUM, ALIAS, UNION) to the PLC project.
    .PARAMETER Name
        DUT name (e.g., ST_MotorData, E_State).
    .PARAMETER DutType
        DUT type: Struct, Enum, Alias, Union.
    .PARAMETER Fields
        Optional hashtable of field declarations (name = type) for Struct/Union.
    .PARAMETER AliasType
        Base type for Alias DUT.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Struct', 'Enum', 'Alias', 'Union')]
        [string]$DutType,

        [Parameter()]
        [hashtable]$Fields,

        [Parameter()]
        [string]$AliasType
    )

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

    try {
        # TIPC^<Plc>^<Plc> Project^DUTs (falls back to the <Plc> Project node)
        $folderInfo = Resolve-TcPlcProjectFolder -SysManager $sm -FolderName 'DUTs'

        # Build declaration
        switch ($DutType) {
            'Struct' {
                $decl = "TYPE $Name :`nSTRUCT`n"
                if ($Fields) {
                    foreach ($f in $Fields.GetEnumerator()) {
                        $decl += "    $($f.Key) : $($f.Value);`n"
                    }
                }
                $decl += "END_STRUCT`nEND_TYPE"
            }
            'Enum' {
                $decl = "TYPE $Name :`n(`n"
                if ($Fields) {
                    $entries = $Fields.GetEnumerator() | ForEach-Object { "    $($_.Key) := $($_.Value)" }
                    $decl += ($entries -join ",`n") + "`n"
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
                if ($Fields) {
                    foreach ($f in $Fields.GetEnumerator()) {
                        $decl += "    $($f.Key) : $($f.Value);`n"
                    }
                }
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
        $created = New-TcPlcObject -SysManager $sm -ParentPath $folderInfo.Path -Name $Name -SubType $dutSubTypes[$DutType] -VInfo $vInfo -Declaration $decl
        if ($created.ContainsKey('ModalDialog')) {
            return New-TcModalDialogResult -Dialog $created.ModalDialog -Operation "CreateChild $Name"
        }
        $kind = Get-TcPlcObjectKind -ItemType $created.ItemType

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name        = $Name
            dutType     = $DutType
            path        = $created.Path
            folderPath  = $folderInfo.Path
            objectKind  = $kind.ObjectKind
            itemType    = $created.ItemType
            declaration = $created.Declaration
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'DUT_CREATE_FAILED' -MessagePrefix 'Failed to add DUT'
    }
}
