function Add-TcLibrary {
    <#
    .SYNOPSIS
        Adds a library reference to the PLC project.
    .PARAMETER Name
        Library name (e.g., Tc2_Standard, Tc3_Module).
    .PARAMETER Version
        Optional library version. Uses latest if omitted.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Version = '*'
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    try {
        # Get the References node (COM calls wrapped in Invoke-TcComRetry)
        $refs = Invoke-TcComRetry -OperationName 'Lookup References' -ScriptBlock {
            $plcConfig = $sm.LookupTreeItem('TIPC')
            $plcProject = $plcConfig.Child(1)
            Write-Output -NoEnumerate $plcProject.LookupChild('References')
        }
        if ($null -eq $refs) {
            return New-TcResult -Success $false -ErrorMessage 'Cannot find References node in PLC project.' -ErrorCode 'REFS_NOT_FOUND'
        }

        # Add library reference
        $libRef = "$Name, $Version (Beckhoff Automation GmbH)"
        Invoke-TcComRetry -OperationName "Add library $Name" -ScriptBlock { Write-Output -NoEnumerate $refs.CreateChild($libRef, 0) } | Out-Null

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            library = $Name
            version = $Version
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_ADD_FAILED' -MessagePrefix 'Failed to add library'
    }
}
