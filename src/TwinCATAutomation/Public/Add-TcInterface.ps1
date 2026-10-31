function Add-TcInterface {
    <#
    .SYNOPSIS
        Adds an interface (INTERFACE ... [EXTENDS ...]) to the PLC project and reads it back.
    .DESCRIPTION
        ITcSmTreeItem::CreateChild(name, 618, '', vInfo) on the folder (TE1000 Automation Interface
        manual v1.7.0, 6.5.5 p.229-231: 618 = interface, vInfo [0] = the interface it extends).
        vInfo is $null without -Extends and the string -Extends with it: an array is refused by XAE
        ("vInfo (Type: String[]) is not supported for creating TreeItem type 'TREEITEMTYPE_PLCITF'",
        measured 2026-10-31 4026 VS2022 XAE 3.1.4026.18, self-built client; a string gives
        "INTERFACE ITF_P2Ext EXTENDS ITF_P2Probe"). Steps as Add-TcPou (New-TcPlcObject): no
        POU / DUT / GVL / ITF with the same name in the PLC project, no modal dialog, CreateChild,
        lookup, ItemType 618, the declaration read back must be "INTERFACE <Name>" (with
        "EXTENDS <Extends>" when given), then the project file is saved and the .plcproj read back
        (<Compile Include> <folders>\<Name>.TcIO, #76). Add methods / properties with
        Add-TcPouMember -ParentPath <data.path>.
        Not verified through the registered MCP server yet (task 3.8).
    .PARAMETER Name
        Interface name (e.g. I_Motor).
    .PARAMETER Extends
        Optional interface it extends, as one string (e.g. I_Base; several: 'I_A, I_B' is passed
        as given, not measured). Must be identifiers separated by commas.
    .PARAMETER PlcProjectPath
        Tree path of the folder the interface is created in, e.g. TIPC^<Plc>^<Plc> Project^POUs
        (alias -Folder; same as Add-TcPou -PlcProjectPath). Auto-detected if omitted: <Plc>
        Project^POUs, or the <Plc> Project node itself when it has no POUs folder (data.folderPath).
    .NOTES
        BUILD_REQUIRED (#65), project file save (#76), PLC_LOGGED_IN and the failure codes
        (POU_CREATE_FAILED with the step, PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT) are the same
        as for Add-TcPou.
    .EXAMPLE
        Add-TcInterface -Name I_Motor
        Add-TcInterface -Name I_Servo -Extends I_Motor
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Extends,

        [Parameter()]
        [Alias('Folder')]
        [string]$PlcProjectPath
    )

    $ext = if ($null -eq $Extends) { '' } else { $Extends.Trim() }
    if ($ext -ne '' -and $ext -notmatch '^[A-Za-z_][A-Za-z0-9_.]*(\s*,\s*[A-Za-z_][A-Za-z0-9_.]*)*$') {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' `
            -ErrorMessage "-Extends '$Extends' is not an interface name (or a comma-separated list of names). Nothing was created." `
            -Hint 'Pass the name of the interface to extend, e.g. -Extends I_Base, or leave -Extends out.' `
            -Data ([PSCustomObject]@{ name = $Name; extends = $Extends })
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }
    $sm = Get-TcSysManager
    if ($null -eq $sm) { return New-TcNoSysManagerResult }

    $createProgress = @{}   # CreateCalled / CreateFailed: set by New-TcPlcObject (#65)
    try {
        $folderInfo = Resolve-TcPlcProjectFolder -SysManager $sm -FolderName 'POUs' -ExplicitPath $PlcProjectPath

        # vInfo: $null or the string (an array is refused, see .DESCRIPTION)
        $vInfo = $null
        $declPattern = '(?im)^\s*INTERFACE\s+' + [regex]::Escape($Name) + '\s*$'
        if ($ext -ne '') {
            [string]$vInfo = $ext
            $extPat = (($ext -split '\s*,\s*') | ForEach-Object { [regex]::Escape($_) }) -join '\s*,\s*'
            $declPattern = '(?im)^\s*INTERFACE\s+' + [regex]::Escape($Name) + '\s+EXTENDS\s+' + $extPat + '\s*$'
        }

        $created = New-TcPlcObject -SysManager $sm -ParentPath $folderInfo.Path -Name $Name -SubType 618 -VInfo $vInfo -DeclarationPattern $declPattern -Progress $createProgress
        if ($created.ContainsKey('ModalDialog')) {
            return New-TcModalDialogResult -Dialog $created.ModalDialog -Operation "CreateChild $Name"
        }
        $kind = Get-TcPlcObjectKind -ItemType $created.ItemType

        # #76: CreateChild only changes the .plcproj in XAE memory (an interface file is .TcIO)
        $save = Invoke-TcPlcObjectSave -ObjectPath $created.Path -ExpectFile "$Name.TcIO" -What "interface '$Name'"
        if ($null -ne $save.Error) { return Register-TcCodeChange -Result $save.Error -Change "Add-TcInterface $Name [created, project file not saved]" }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            name                       = $Name
            extends                    = $(if ($ext -eq '') { $null } else { $ext })
            path                       = $created.Path
            folderPath                 = $folderInfo.Path
            objectKind                 = $kind.ObjectKind
            itemType                   = $created.ItemType
            declaration                = $created.Declaration
            duplicateCheckScope        = $created.DuplicateCheckScope
            duplicateCheckSkippedNodes = $created.DuplicateCheckSkippedNodes
            duplicateCheckNote         = $created.DuplicateCheckNote
            projectSaved               = $save.Saved
        })
        Register-TcCodeChange -Result $ok -Change "Add-TcInterface $Name"
    }
    catch {
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_CREATE_FAILED' -MessagePrefix 'Failed to add interface'
        # conservative (#65): CreateChild was called, the object may exist in the tree; not when
        # CreateChild itself returned an error (CreateFailed: XAE refused, e.g. PLC_LOGGED_IN)
        if ($createProgress['CreateCalled'] -and -not $createProgress['CreateFailed']) { return Register-TcCodeChange -Result $res -Change "Add-TcInterface $Name [failed after CreateChild]" }
        $res
    }
}
