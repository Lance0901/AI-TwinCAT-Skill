function Add-TcLibrary {
    <#
    .SYNOPSIS
        Adds a library reference to the PLC project.
    .PARAMETER Name
        Library name (e.g., Tc2_Standard, Tc3_Module).
    .PARAMETER Version
        Optional library version. Uses latest if omitted.
    .NOTES
        BUILD_REQUIRED (#65): after CreateChild on the References node was called (success, or
        CreateChild failing) the solution is recorded as 'code-changed' (Register-TcCodeChange):
        Enable-TcConfig and Enter-TcPlcOnline refuse until a complete Build-TcProject.
        data.buildRequired / data.stateWarning as in Build-TcProject.
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

    $createCalled = $false
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
        $createCalled = $true   # #65: the References may change from here on
        Invoke-TcComRetry -OperationName "Add library $Name" -ScriptBlock { Write-Output -NoEnumerate $refs.CreateChild($libRef, 0) } | Out-Null

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            library = $Name
            version = $Version
        })
        Register-TcCodeChange -Result $ok -Change "Add-TcLibrary $Name (version $Version)"
    }
    catch {
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'LIBRARY_ADD_FAILED' -MessagePrefix 'Failed to add library'
        # conservative (#65): CreateChild was called, the reference may have been added
        if ($createCalled) { return Register-TcCodeChange -Result $res -Change "Add-TcLibrary $Name (version $Version) [failed after CreateChild]" }
        $res
    }
}
