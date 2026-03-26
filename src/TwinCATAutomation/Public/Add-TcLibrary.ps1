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
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    try {
        $plcConfig = $sm.LookupTreeItem('TIPC')
        $plcProject = $plcConfig.Child(1)

        # Get the References node
        $refs = $plcProject.LookupChild('References')
        if ($null -eq $refs) {
            return New-TcResult -Success $false -ErrorMessage 'Cannot find References node in PLC project.' -ErrorCode 'REFS_NOT_FOUND'
        }

        # Add library reference
        $libRef = "$Name, $Version (Beckhoff Automation GmbH)"
        $refs.CreateChild($libRef, 0)

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            library = $Name
            version = $Version
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to add library: $_" -ErrorCode 'LIBRARY_ADD_FAILED'
    }
}
