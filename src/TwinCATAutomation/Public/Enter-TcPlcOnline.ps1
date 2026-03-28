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
            # Auto-detect: TIPC → first PLC → find Project node
            # Strategy: Try direct LookupTreeItem with constructed path first (more reliable),
            # then fall back to child enumeration.
            # After TwinCAT restart, child enumeration may not show "Project" node,
            # but LookupTreeItem with full path still finds it.
            $tipc = $sm.LookupTreeItem('TIPC')
            $plcNode = $tipc.Child(1)
            $plcName = $plcNode.Name  # e.g., "LoggerPLC"

            $foundProject = $false

            # Strategy 1: Direct LookupTreeItem with constructed path "<PlcName> Project"
            $candidatePath = "TIPC^${plcName}^${plcName} Project"
            try {
                $projItem = $sm.LookupTreeItem($candidatePath)
                if ($null -ne $projItem) {
                    $PlcProjectPath = $candidatePath
                    $foundProject = $true
                    Write-Verbose "Found via LookupTreeItem: $PlcProjectPath"
                }
            }
            catch {
                Write-Verbose "LookupTreeItem('$candidatePath') failed: $_"
            }

            # Strategy 2: Enumerate children for "Project" keyword
            if (-not $foundProject) {
                for ($i = 1; $i -le $plcNode.ChildCount; $i++) {
                    $child = $plcNode.Child($i)
                    if ($child.Name -match 'Project') {
                        $PlcProjectPath = $child.PathName
                        $foundProject = $true
                        Write-Verbose "Found via enumeration: $PlcProjectPath"
                        break
                    }
                }
            }

            if (-not $foundProject) {
                $childNames = @()
                for ($i = 1; $i -le $plcNode.ChildCount; $i++) { $childNames += $plcNode.Child($i).Name }
                return New-TcResult -Success $false `
                    -ErrorMessage "Could not find PLC Project node. Tried: '$candidatePath'. Children of $($plcNode.PathName): $($childNames -join ', ')" `
                    -ErrorCode 'PLC_PROJECT_NOT_FOUND'
            }
        }

        Write-Verbose "Login to: $PlcProjectPath"

        # Use LookupTreeItem with full path — this returns an ITcSmTreeItem
        # that reliably exposes Login(nFlags) method
        $plcProject = $sm.LookupTreeItem($PlcProjectPath)

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
