function Enter-TcPlcOnline {
    <#
    .SYNOPSIS
        Logs into PLC runtime and downloads program — no dialog popups.
    .DESCRIPTION
        Uses ITcSmTreeItem::Login(3) on the PLC Project node.
        Flag 3 = CompileBeforeLogin(1) + SuppressAllDialogs(2).
        This triggers Login + Download automatically if no program is loaded.
    .PARAMETER PlcProjectPath
        Tree path to PLC project. Default auto-detects from TIPC.
    #>
    [CmdletBinding()]
    param(
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

    try {
        if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            # Auto-detect: TIPC → first child → first sub-child (the PLC Project)
            $tipc = $sm.LookupTreeItem('TIPC')
            $plcNode = $tipc.Child(1)
            $plcProject = $plcNode.Child(1)  # e.g., "LoggerPLC Project"
            $PlcProjectPath = $plcProject.PathName
        }
        else {
            $plcProject = $sm.LookupTreeItem($PlcProjectPath)
        }

        Write-Verbose "Login to: $PlcProjectPath"

        # Login(3) = CompileBeforeLogin(1) + SuppressAllDialogs(2)
        # This also triggers Download if runtime has no program
        $plcProject.Login(3)

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            online         = $true
            plcProjectPath = $PlcProjectPath
            message        = 'Logged into PLC runtime with program download (no dialogs).'
        })
    }
    catch {
        if ($_.Exception.Message -match 'already') {
            New-TcResult -Success $true -Data ([PSCustomObject]@{
                online         = $true
                plcProjectPath = $PlcProjectPath
                message        = 'Already logged into PLC runtime.'
            })
        }
        else {
            New-TcResult -Success $false -ErrorMessage "PLC login failed: $_" -ErrorCode 'LOGIN_FAILED'
        }
    }
}
