function Exit-TcPlcOnline {
    <#
    .SYNOPSIS
        Logs out from the PLC runtime.
    .DESCRIPTION
        The PLC is looked up like Enter-TcPlcOnline. -PlcProjectPath accepts the PLC name
        ('FrameworkUnitTest'), the PLC node path ('TIPC^FrameworkUnitTest') or the project
        path ('TIPC^FrameworkUnitTest^FrameworkUnitTest Project'). Without it a solution
        with one PLC uses that PLC; a solution with several PLC projects returns
        PLC_PROJECT_AMBIGUOUS (the old code took TIPC.Child(1) and logged out of the wrong
        PLC or failed, #32).
    .PARAMETER PlcProjectPath
        PLC name or tree path. Required when the solution has more than one PLC project.
        Fail closed (#68 / #232, CODING_STANDARDS 2): the login state is read back with
        Get-TcPlcLoginState (ITcPlcOnline.IsLoggedIn, else ProduceXml
        IECProjectDef/OnlineSettings/LoggedIn of the "<Plc> Project" item) before and after
        Logoff. success = true only when the read back after Logoff is false. Still true ->
        LOGOUT_FAILED; not readable (null) -> LOGOUT_FAILED too: no readback, no success.
        Already logged out (read back false before Logoff) -> success with
        data.alreadyLoggedOut = $true and nothing is sent to the IDE (idempotent). A Logoff()
        without an exception is never taken as proof: Logoff() on a project that is not logged
        in returns without an error as well (實測 2026-11-13, 4026.22 VS2022, local UmRT).
    .OUTPUTS
        data: online, loggedIn (read back: $false on success; $true / $null on LOGOUT_FAILED),
        loginStateSource (IsLoggedIn | ProduceXml | $null), loginStateError, alreadyLoggedOut,
        plcProjectPath (the project actually logged out), plcName, adsPort (<AdsPort> of the
        PLC node, $null when unknown), logoutVia ($null when nothing was sent), message
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
        return New-TcNoSysManagerResult
    }

    try {
        # Same lookup as Enter-TcPlcOnline: the "<Plc> Project" tree item exposes Logout()
        # directly. The old TIPC.Child(1).Object path returns $null after a TwinCAT restart.
        $plcList = @(Get-TcPlcProjectList -SysManager $sm)
        $plcEntry = $null
        if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            try {
                $PlcProjectPath = Resolve-TcPlcProjectPath -SysManager $sm -RequireSingle
            }
            catch {
                if ($_.Exception.Message -match '^(PLC_PROJECT_NOT_FOUND|PLC_PROJECT_AMBIGUOUS)') {
                    $code = $Matches[1]
                    return New-TcResult -Success $false `
                        -ErrorMessage ($_.Exception.Message -replace '^PLC_PROJECT_[A-Z_]+:\s*', '') `
                        -ErrorCode $code -Hint (Get-TcErrorHint -Code $code) `
                        -Data ([PSCustomObject]@{ plcProjects = $plcList })
                }
                throw
            }
            $plcEntry = Find-TcPlcProject -List $plcList -Spec $PlcProjectPath
        }
        else {
            $plcEntry = Find-TcPlcProject -List $plcList -Spec $PlcProjectPath
            if ($null -eq $plcEntry) {
                return New-TcResult -Success $false `
                    -ErrorMessage "PLC project '$PlcProjectPath' not found. PLC projects: $(($plcList | ForEach-Object { $_.projectPath }) -join ', ')" `
                    -ErrorCode 'PLC_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'PLC_PROJECT_NOT_FOUND') `
                    -Data ([PSCustomObject]@{ plcProjects = $plcList })
            }
            # a bare PLC name / node path is turned into the "<Plc> Project" item
            if ($PlcProjectPath -ieq $plcEntry.name -or $PlcProjectPath -ieq $plcEntry.nodePath) { $PlcProjectPath = $plcEntry.projectPath }
        }
        $plcProject = Invoke-TcComRetry -OperationName "LookupTreeItem $PlcProjectPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($PlcProjectPath) }
        if ($null -eq $plcProject) {
            return New-TcResult -Success $false -ErrorMessage "PLC project tree item '$PlcProjectPath' not found." -ErrorCode 'PLC_PROJECT_NOT_FOUND'
        }

        # Where the logout method is (#232). The call that works is Logoff() on the "<Plc> Project"
        # tree item (TIPC^<Plc>^<Plc> Project):
        #   - 實測 2026-11-13, TwinCAT 3.1.4026.22, VS2022 (VisualStudio.DTE.17.0), local UmRT:
        #     Get-Member lists Login / Logoff on the PLC node TIPC^<Plc> and no Log* method on the
        #     "<Plc> Project" item, but calling TIPC^<Plc>.Logoff() / .Logout() fails ("does not
        #     contain a method named 'Logoff'"); "<Plc> Project".Logoff() logs out (LoggedIn
        #     true -> false). Get-Member is not proof for these IDispatch objects.
        #   - 4026.27 TcXaeShell 64-bit (Ming, #232): same call path (treeItem.Logoff).
        #   - @@4024@@
        #   - Logoff() on a project that is not logged in returns without an error (4026.22 and
        #     4026.27), so the call result proves nothing: the login state is read back.
        # The older note (2026-10-18) that the "<Plc> Project" item has no Logoff came from
        # Get-Member only. The order of the attempts does not matter for the result; the method is
        # named Logoff, Logout is kept as a fallback. data.logoutVia names the call that returned.
        # No scriptblock indirection: a COM tree item returned through "& { $x }" is
        # unrolled into Object[] (ITcSmTreeItem is enumerable).
        $plcNodePath = ($PlcProjectPath -split '\^')[0..1] -join '^'   # TIPC^<Plc>
        $plcNode = Invoke-TcComRetry -OperationName "LookupTreeItem $plcNodePath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($plcNodePath) }

        # Login state readback (#232): the entry Get-TcPlcLoginState needs (name, nodePath, projectPath)
        $stateEntry = if ($null -ne $plcEntry) { $plcEntry } else {
            [PSCustomObject]@{ name = ($PlcProjectPath -split '\^')[1]; nodePath = $plcNodePath; projectPath = $PlcProjectPath }
        }
        $plcName = if ($null -ne $plcEntry) { $plcEntry.name } else { $null }
        $adsPort = if ($null -ne $plcEntry) { $plcEntry.adsPort } else { $null }
        $before = Get-TcPlcLoginState -SysManager $sm -Plc $stateEntry
        if ($before.loggedIn -eq $false) {
            # idempotent: nothing to log out of, nothing sent
            return New-TcResult -Success $true -Data ([PSCustomObject]@{
                online           = $false
                loggedIn         = $false
                loginStateSource = $before.source
                loginStateError  = $before.error
                alreadyLoggedOut = $true
                plcProjectPath   = $PlcProjectPath
                plcName          = $plcName
                adsPort          = $adsPort
                logoutVia        = $null
                message          = 'Already logged out (login state read back false); nothing sent.'
            })
        }

        $loggedOutVia = $null
        $lastErr = $null
        $fatal = 'IDE_MODAL_DIALOG|IDE_TIMEOUT|IDE_BUSY|IDE_CRASHED'
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

        $after = Get-TcPlcLoginState -SysManager $sm -Plc $stateEntry
        $data = [PSCustomObject]@{
            online           = ($after.loggedIn -ne $false)
            loggedIn         = $after.loggedIn
            loginStateSource = $after.source
            loginStateError  = $after.error
            alreadyLoggedOut = $false
            plcProjectPath   = $PlcProjectPath
            plcName          = $plcName
            adsPort          = $adsPort
            logoutVia        = $loggedOutVia
            message          = 'Logged out from PLC runtime (login state read back false).'
        }
        if ($after.loggedIn -eq $false) { return New-TcResult -Success $true -Data $data }
        # fail closed (CODING_STANDARDS 2): still logged in, or no readback at all
        $why = if ($after.loggedIn -eq $true) { 'the login state still reads back true' }
               else { "the login state could not be read back (unknown: $($after.error))" }
        $data.message = "Logoff() via $loggedOutVia returned without an error, but $why."
        New-TcResult -Success $false -ErrorCode 'LOGOUT_FAILED' -Hint (Get-TcErrorHint -Code 'LOGOUT_FAILED') `
            -ErrorMessage "PLC logout of '$PlcProjectPath' not verified: $($data.message)" -Data $data
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'LOGOUT_FAILED' -MessagePrefix 'PLC logout failed'
    }
}
