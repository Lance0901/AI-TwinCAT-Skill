function Add-TcPou {
    <#
    .SYNOPSIS
        Adds a POU (Program, Function Block, or Function) to the PLC project.
    .PARAMETER Name
        POU name (e.g., FB_Motor, FC_Add, MAIN).
    .PARAMETER Type
        POU type: Program, FunctionBlock, or Function.
    .PARAMETER ReturnType
        Return type for Functions (e.g., INT, BOOL). Ignored for Program/FunctionBlock.
    .PARAMETER PlcProjectPath
        Tree path of the folder the POU is created in, e.g. TIPC^<Plc>^<Plc> Project^POUs
        (same format on 4024 and 4026). Auto-detected if omitted: <Plc> Project^POUs, or the
        <Plc> Project node itself when it has no POUs folder (see data.folderPath).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter(Mandatory)]
        [ValidateSet('Program', 'FunctionBlock', 'Function')]
        [string]$Type,

        [Parameter()]
        [string]$ReturnType = 'BOOL',

        [Parameter()]
        [string]$PlcProjectPath
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    # Sub types = the ItemType values of InfoSys "ITcSmTreeItem Item Types"
    # (https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425810699.html); the
    # CreateChild page confirms 603 / 604 as CreateChild sub types, 602 is measured (2026-10-25,
    # 4024 TcXaeShell.DTE.15.0 and 4026 VisualStudio.DTE.17.0).
    $pouSubTypes = @{
        'Program'       = 602   # TREEITEMTYPE_PLCPOUPROG
        'Function'      = 603   # TREEITEMTYPE_PLCPOUFUNC
        'FunctionBlock' = 604   # TREEITEMTYPE_PLCPOUFB
    }
    # vInfo = IEC language as integer (IECLANGUAGETYPES); a Function takes string[2]
    # { language, return type } (InfoSys ITcSmTreeItem::CreateChild,
    # https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425844363.html; that
    # page lists 604 and 603, 602 takes the same integer - measured 2026-10-25 on 4024 and 4026).
    # IECLANGUAGE_ST = 1: TCatSysManagerLib 3.4.0.0 interop enum IECLANGUAGETYPES, read by
    # reflection 2026-10-25 (6 is LD). A declaration string as vInfo is parsed as a language
    # name and fails with "Requested value '...' was not found" (E_FAIL, measured 2026-10-25 on 4024).
    $iecLanguageSt = 1

    try {
        # Find POUs folder (TIPC^<Plc>^<Plc> Project^POUs on 4024 and 4026)
        $folderInfo = Resolve-TcPlcProjectFolder -SysManager $sm -FolderName 'POUs' -ExplicitPath $PlcProjectPath

        $subType = $pouSubTypes[$Type]
        # assigned in the branches: an if-expression would unroll the array into object[]
        $vInfo = $iecLanguageSt
        $declPattern = $null
        if ($Type -eq 'Function') {
            [string[]]$vInfo = @([string]$iecLanguageSt, $ReturnType)
            # read back: the header XAE writes is "FUNCTION <name> :<type>" (measured 2026-10-25,
            # 4024 TcXaeShell.DTE.15.0 and 4026 VisualStudio.DTE.17.0)
            $declPattern = '(?im)^\s*FUNCTION\s+' + [regex]::Escape($Name) + '\s*:\s*' + [regex]::Escape($ReturnType) + '(?![A-Za-z0-9_])'
        }

        # the language is read back from the new item (ITcSmTreeItem.Language) and must be ST
        $created = New-TcPlcObject -SysManager $sm -ParentPath $folderInfo.Path -Name $Name -SubType $subType -VInfo $vInfo -ExpectedLanguage 'ST' -DeclarationPattern $declPattern
        if ($created.ContainsKey('ModalDialog')) {
            return New-TcModalDialogResult -Dialog $created.ModalDialog -Operation "CreateChild $Name"
        }
        $kind = Get-TcPlcObjectKind -ItemType $created.ItemType

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name        = $Name
            type        = $Type
            path        = $created.Path
            folderPath  = $folderInfo.Path
            objectKind  = $kind.ObjectKind
            itemType    = $created.ItemType
            language    = $created.Language
            declaration = $created.Declaration
            duplicateCheckScope        = $created.DuplicateCheckScope
            duplicateCheckSkippedNodes = $created.DuplicateCheckSkippedNodes
            duplicateCheckNote         = $created.DuplicateCheckNote
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_CREATE_FAILED' -MessagePrefix 'Failed to add POU'
    }
}
