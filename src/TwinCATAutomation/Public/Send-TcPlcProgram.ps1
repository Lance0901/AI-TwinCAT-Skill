function Send-TcPlcProgram {
    <#
    .SYNOPSIS
        Downloads the compiled PLC program to the target runtime.
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

        # Login and download via ITcPlcProject
        $plcProject = $plcProjectItem.Object
        $plcProject.Login()
        $plcProject.Download()

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            downloaded = $true
            message    = 'PLC program downloaded to target runtime.'
        })
    }
    catch {
        if ($_.Exception.Message -match 'target' -or $_.Exception.Message -match 'ADS') {
            New-TcResult -Success $false -ErrorMessage "Target not reachable: $_" -ErrorCode 'TARGET_UNREACHABLE'
        }
        else {
            New-TcResult -Success $false -ErrorMessage "Download failed: $_" -ErrorCode 'DOWNLOAD_FAILED'
        }
    }
}
