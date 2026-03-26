function Enter-TcPlcOnline {
    <#
    .SYNOPSIS
        Logs into the PLC runtime via ITcPlcProject (independent of download).
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

        $plcProject.Login()

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            online = $true
            message = 'Logged into PLC runtime.'
        })
    }
    catch {
        if ($_.Exception.Message -match 'already') {
            New-TcResult -Success $true -Data ([PSCustomObject]@{
                online  = $true
                message = 'Already logged into PLC runtime.'
            })
        }
        else {
            New-TcResult -Success $false -ErrorMessage "PLC login failed: $_" -ErrorCode 'LOGIN_FAILED'
        }
    }
}
