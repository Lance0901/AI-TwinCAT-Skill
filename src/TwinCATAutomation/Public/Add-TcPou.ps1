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

    # POU sub-type values for ITcSmTreeItem::CreateChild
    $pouSubTypes = @{
        'Program'       = 604   # CYCLIC_PRG
        'FunctionBlock' = 602   # FUNCTION_BLOCK
        'Function'      = 603   # FUNCTION
    }

    try {
        # Find POUs folder (TIPC^<Plc>^<Plc> Project^POUs on 4024 and 4026)
        $folderInfo = Resolve-TcPlcProjectFolder -SysManager $sm -FolderName 'POUs' -ExplicitPath $PlcProjectPath
        $pouFolder = $folderInfo.Item

        $subType = $pouSubTypes[$Type]

        # Build XML declaration for the POU
        $langId = 'st'  # Structured Text
        $declXml = "<Declaration><![CDATA["
        switch ($Type) {
            'Program' {
                $declXml += "PROGRAM $Name`nVAR`nEND_VAR"
            }
            'FunctionBlock' {
                $declXml += "FUNCTION_BLOCK $Name`nVAR_INPUT`nEND_VAR`nVAR_OUTPUT`nEND_VAR`nVAR`nEND_VAR"
            }
            'Function' {
                $declXml += "FUNCTION $Name : $ReturnType`nVAR_INPUT`nEND_VAR`nVAR`nEND_VAR"
            }
        }
        $declXml += "]]></Declaration>"

        $newItem = Invoke-TcComRetry -OperationName "CreateChild $Name" -ScriptBlock { Write-Output -NoEnumerate $pouFolder.CreateChild($Name, $subType, '', $declXml) }

        $itemPath = try { Invoke-TcComRetry -OperationName 'PathName' -ScriptBlock { $newItem.PathName } } catch { '' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name       = $Name
            type       = $Type
            path       = $itemPath
            folderPath = $folderInfo.Path
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'POU_CREATE_FAILED' -MessagePrefix 'Failed to add POU'
    }
}
