function Exit-TcPlcOnline {
    <#
    .SYNOPSIS
        Logs out from the PLC runtime.
    #>
    [CmdletBinding()]
    param()

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcResult -Success $false -ErrorMessage 'No TwinCAT project loaded.' -ErrorCode 'NO_PROJECT'
    }

    try {
        $plcConfig = $sm.LookupTreeItem('TIPC')
        $plcProjectItem = $plcConfig.Child(1)
        $plcProject = $plcProjectItem.Object

        $plcProject.Logout()

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            online  = $false
            message = 'Logged out from PLC runtime.'
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "PLC logout failed: $_" -ErrorCode 'LOGOUT_FAILED'
    }
}
