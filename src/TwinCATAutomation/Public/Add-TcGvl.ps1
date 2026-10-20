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
        $plcProject = Invoke-TcComRetry -OperationName 'Lookup PLC project' -ScriptBlock {
            $plcConfig = $sm.LookupTreeItem('TIPC')
            Write-Output -NoEnumerate $plcConfig.Child(1)
        }

        # Build declaration
        $decl = "VAR_GLOBAL`n"
        if ($Variables) {
            foreach ($var in $Variables.GetEnumerator()) {
                $decl += "    $($var.Key) : $($var.Value);`n"
            }
        }
        $decl += "END_VAR"

        $declXml = "<Declaration><![CDATA[$decl]]></Declaration>"

        # GVL sub-type
        $newItem = Invoke-TcComRetry -OperationName "CreateChild $Name" -ScriptBlock { Write-Output -NoEnumerate $plcProject.CreateChild($Name, 615, '', $declXml) }

        $itemPath = try { Invoke-TcComRetry -OperationName 'PathName' -ScriptBlock { $newItem.PathName } } catch { '' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{
            name = $Name
            path = $itemPath
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'GVL_CREATE_FAILED' -MessagePrefix 'Failed to add GVL'
    }
}
