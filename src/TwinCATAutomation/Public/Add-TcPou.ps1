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
        Tree path to the PLC project's POUs folder. Auto-detected if omitted.
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
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    # POU sub-type values for ITcSmTreeItem::CreateChild
    $pouSubTypes = @{
        'Program'       = 604   # CYCLIC_PRG
        'FunctionBlock' = 602   # FUNCTION_BLOCK
        'Function'      = 603   # FUNCTION
    }

    try {
        # Find POUs folder
        if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            # Auto-detect: look under TIPC for first PLC project
            $plcConfig = $sm.LookupTreeItem('TIPC')
            $plcProject = $plcConfig.Child(1)
            $pouFolder = $plcProject.LookupChild('POUs')
            if ($null -eq $pouFolder) {
                $pouFolder = $plcProject
            }
        }
        else {
            $pouFolder = $sm.LookupTreeItem($PlcProjectPath)
        }

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

        $newItem = $pouFolder.CreateChild($Name, $subType, '', $declXml)

        $itemPath = try { $newItem.PathName } catch { '' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name = $Name
            type = $Type
            path = $itemPath
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to add POU: $_" -ErrorCode 'POU_CREATE_FAILED'
    }
}
