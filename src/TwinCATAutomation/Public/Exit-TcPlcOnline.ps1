function Exit-TcPlcOnline {
    <#
    .SYNOPSIS
        Logs out from the PLC runtime.
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
        # Same lookup as Enter-TcPlcOnline: the "<Plc> Project" tree item exposes Logout()
        # directly. The old TIPC.Child(1).Object path returns $null after a TwinCAT restart.
        if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            try {
                $PlcProjectPath = Resolve-TcPlcProjectPath -SysManager $sm
            }
            catch {
                if ($_.Exception.Message -match '^PLC_PROJECT_NOT_FOUND') {
                    return New-TcResult -Success $false `
                        -ErrorMessage ($_.Exception.Message -replace '^PLC_PROJECT_NOT_FOUND:\s*', '') `
                        -ErrorCode 'PLC_PROJECT_NOT_FOUND'
                }
                throw
            }
        }
        $plcProject = Invoke-TcComRetry -OperationName "LookupTreeItem $PlcProjectPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($PlcProjectPath) }
        if ($null -eq $plcProject) {
            return New-TcResult -Success $false -ErrorMessage "PLC project tree item '$PlcProjectPath' not found." -ErrorCode 'PLC_PROJECT_NOT_FOUND'
        }

        # Logout() lives on different objects depending on XAE version / node: the
        # "<Plc> Project" tree item exposes Login(nFlags) but on 4026 not Logout; the
        # ITcPlcProject behind the PLC node (TIPC^<Plc>) does. Try in order and
        # remember which one worked.
        # Verified on TwinCAT 3.1.4026 (2026-10-18, Get-Member on the live objects):
        # the online methods Login / Logoff / Start / Stop / Reset are exposed by the
        # PLC node "TIPC^<Plc>" (ITcPlcIECProject via IDispatch). The "<Plc> Project"
        # tree item has no Logoff/Logout, and .Object is $null on both nodes.
        # The method is named Logoff; Logout is tried as a fallback for other versions.
        # No scriptblock indirection: a COM tree item returned through "& { $x }" is
        # unrolled into Object[] (ITcSmTreeItem is enumerable).
        $plcNodePath = ($PlcProjectPath -split '\^')[0..1] -join '^'   # TIPC^<Plc>
        $plcNode = Invoke-TcComRetry -OperationName "LookupTreeItem $plcNodePath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($plcNodePath) }

        $loggedOutVia = $null
        $lastErr = $null
        $fatal = 'IDE_MODAL_DIALOG|IDE_TIMEOUT|IDE_BUSY'
        $attempts = @(
            @{ Via = 'plcNode.Logoff';  Run = { $plcNode.Logoff() } },
            @{ Via = 'plcNode.Logout';  Run = { $plcNode.Logout() } },
            @{ Via = 'treeItem.Logoff'; Run = { $plcProject.Logoff() } },
            @{ Via = 'treeItem.Logout'; Run = { $plcProject.Logout() } }
        )
        foreach ($a in $attempts) {
            if ($null -eq $plcNode -and $a.Via -like 'plcNode.*') { continue }
            try {
                # The script block only invokes a method (returns nothing), so no enumeration issue.
                Invoke-TcComRetry -OperationName "Logout via $($a.Via)" -ScriptBlock $a.Run | Out-Null
                $loggedOutVia = $a.Via
                break
            }
            catch {
                if ($_.Exception.Message -match $fatal) { throw }
                $lastErr = $_
                Write-Verbose "Exit-TcPlcOnline: $($a.Via) failed: $($_.Exception.Message)"
            }
        }

        if ($null -eq $loggedOutVia) {
            if ($null -ne $lastErr) { throw $lastErr }
            throw "No PLC object exposing Logoff()/Logout() found under '$plcNodePath'."
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            online         = $false
            plcProjectPath = $PlcProjectPath
            logoutVia      = $loggedOutVia
            message        = 'Logged out from PLC runtime.'
        })
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'LOGOUT_FAILED' -MessagePrefix 'PLC logout failed'
    }
}
