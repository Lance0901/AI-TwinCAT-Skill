function Enter-TcPlcOnline {
    <#
    .SYNOPSIS
        Logs into PLC runtime and downloads program — no dialog popups.
    .DESCRIPTION
        Calls ITcPlcIECProject::Login(PLC_LOGIN_FLAGS) on the "<Plc> Project" tree item.
        PLC_LOGIN_FLAGS (TCatSysManagerLib, TwinCAT 3.1):
          NONE=0  REGULAR=1  FORCEONLINECHANGE=2  FORCEDOWNLOAD=4
          FORCECOMPILECODE=16  FORCEGENERATECODE=32  SILENT=256
        -LoginMode maps to REGULAR / FORCEDOWNLOAD / FORCEONLINECHANGE. SILENT is NOT added
        by default (-SilentFlag adds it): XAE answers its own prompts (e.g. "Application
        'Port_851' does not exist on device ... create it and proceed with download?") with
        the default button through the global ITcAutomationSettings.SilentMode that
        Connect-TcIde enables, instead of blocking the COM call.
        Measured 2026-10-19 (TwinCAT 3.1.4024, 32-bit XAE, empty UmRT):
          Login(3) = REGULAR|FORCEONLINECHANGE -> "Login aborted: Conflicting flag settings
                     ('Regular' and 0x00000002)"; silently aborted under SilentMode, nothing
                     downloaded. (The old "3 = compile + suppress dialogs" comment was wrong.)
          Login(1)/(2)/(4) without SILENT -> blocking "create application?" prompt
          Login(1) with SilentMode -> login + download OK (851 Invalid -> Stop, 37/37 lifecycle)
          Login(257) = REGULAR|SILENT -> returned in 0.5 s, nothing created/downloaded
                     (851 stayed Invalid): the SILENT flag skips the prompt instead of
                     answering it. Not used by default.
          Login(260) = FORCEDOWNLOAD|SILENT -> deployed to the empty runtime too; the next
                     ActivateConfiguration() then took 250 s and failed: the 32-bit XAE crashed
                     with OutOfMemoryException in the CODESYS Visu engine (Windows event 1026),
                     unrelated to the flag; Enable-TcConfig uses Regular.

        Before Login the IDE is checked for a modal dialog (IDE_MODAL_DIALOG is
        returned instead of issuing a DTE call that would block forever), and the
        AdsState of port 851 is read (module session when it points at <netId>:851,
        otherwise a temporary client). When 851 was already Run/Stop and is unchanged
        after Login, the program was already loaded (data.downloaded = $false);
        otherwise a download is assumed (data.downloaded = $true). This is a
        best-effort indication only.

        NOTE: with SilentMode on, calling Enter-TcPlcOnline directly against a PLC that is
        already in Run with a mismatching project lets XAE take its default answer to its own
        "online change / download" prompt; Enable-TcConfig is not affected (login happens
        after the restart). Use -LoginMode Download / OnlineChange explicitly when that matters.
    .PARAMETER PlcProjectPath
        PLC name ('FrameworkUnitTest'), PLC node path ('TIPC^FrameworkUnitTest') or project
        path ('TIPC^FrameworkUnitTest^FrameworkUnitTest Project'). Optional when the solution
        has one PLC project; with several PLC projects PLC_PROJECT_AMBIGUOUS is returned
        instead of logging into the first one (#32). The PLC state before/after is read on
        that PLC's own ADS port (<AdsPort> of the PLC node, 851 when unknown).
    .PARAMETER LoginMode
        Regular (default): PLC_LOGIN_FLAGS_REGULAR - login, download only when the runtime has
        no program (XAE decides). Download: FORCEDOWNLOAD - always a full download
        (used by Send-TcPlcProgram). OnlineChange: FORCEONLINECHANGE.
        SILENT (256) is only OR-ed in with -SilentFlag.
    .PARAMETER SilentFlag
        OR PLC_LOGIN_FLAGS_SILENT (256) into the login flags. Off by default: prompts are
        answered by the global ITcAutomationSettings.SilentMode that Connect-TcIde enables.
    .PARAMETER TimeoutSec
        Expected upper bound of the Login COM call (Invoke-TcComRetry -TimeoutSec), default 300.
        Enable-TcConfig passes the rest of its overall -TimeoutSec budget.
    .OUTPUTS
        data: online, plcProjectPath, plcName, adsPort, loginMode, loginFlags, message,
              downloaded, plcStateBefore, plcStateAfter
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$PlcProjectPath,

        [Parameter()]
        [ValidateSet('Regular', 'Download', 'OnlineChange')]
        [string]$LoginMode = 'Regular',

        [Parameter()]
        [switch]$SilentFlag,

        [Parameter()]
        [ValidateRange(1, 3600)]
        [int]$TimeoutSec = 300
    )

    # PLC_LOGIN_FLAGS. SILENT (256) is NOT added by default: measured 2026-10-19 on an empty
    # UmRT, REGULAR|SILENT (257) returned in 0.5 s without creating/downloading the application
    # (851 stayed Invalid), while REGULAR (1) with the global ITcAutomationSettings.SilentMode
    # (enabled by Connect-TcIde) answered the "create application?" prompt with Yes and
    # downloaded. The flag means "skip anything that would ask", the global setting means
    # "answer with the default button". -SilentFlag adds 256 when that behaviour is wanted.
    $loginFlagMap = @{ Regular = 1; Download = 4; OnlineChange = 2 }
    $PLC_LOGIN_FLAGS_SILENT = 256
    $loginFlags = [int]$loginFlagMap[$LoginMode]
    if ($SilentFlag) { $loginFlags = $loginFlags -bor $PLC_LOGIN_FLAGS_SILENT }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    # AdsState of port 851 as [int] (Invalid=0 ... Run=5, Stop=6) or $null when unreachable.
    function Get-TcQuietPlcState {
        param([string]$NetId, [int]$Port = 851)
        if ([string]::IsNullOrWhiteSpace($NetId)) { return $null }
        try {
            if ($script:TcAdsConnected -and $null -ne $script:TcAdsClient -and
                $script:TcAdsAmsNetId -eq $NetId -and [int]$script:TcAdsPort -eq $Port) {
                return [int]$script:TcAdsClient.ReadState().AdsState
            }
            $tmp = $null
            try {
                $tmp = New-TcAdsClient -AmsNetId $NetId -Port $Port
                return [int]$tmp.ReadState().AdsState
            }
            finally {
                if ($null -ne $tmp) { try { $tmp.Dispose() } catch { } }
            }
        }
        catch {
            Write-Verbose "Enter-TcPlcOnline: port $Port state unreadable ($($_.Exception.Message))"
            return $null
        }
    }

    function ConvertTo-TcAdsStateName {
        param([object]$State)
        if ($null -eq $State) { return $null }
        try { return ([Enum]::ToObject([TwinCAT.Ads.AdsState], [int]$State)).ToString() } catch { return [string]$State }
    }

    try {
        $plcList = @(Get-TcPlcProjectList -SysManager $sm)
        $plcEntry = $null
        if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            # Auto-detect: the only PLC -> "<Plc> Project" (shared with Exit-TcPlcOnline);
            # several PLC projects -> PLC_PROJECT_AMBIGUOUS
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
            if ($PlcProjectPath -ieq $plcEntry.name -or $PlcProjectPath -ieq $plcEntry.nodePath) { $PlcProjectPath = $plcEntry.projectPath }
        }
        $plcPort = if ($null -ne $plcEntry -and $null -ne $plcEntry.adsPort) { [int]$plcEntry.adsPort } else { 851 }
        $plcName = if ($null -ne $plcEntry) { $plcEntry.name } else { $null }

        Write-Verbose "Login to: $PlcProjectPath"

        # A modal dialog makes Login() block forever (no COM error) - refuse up front.
        $dialog = Get-TcIdeModalDialog
        if ($null -ne $dialog) {
            return New-TcModalDialogResult -Dialog $dialog -Operation 'Login' -Data ([PSCustomObject]@{ plcProjectPath = $PlcProjectPath })
        }

        # PLC state before login (best effort; $null = port 851 not reachable = nothing loaded)
        $netId = $null
        try { $netId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() } } catch { if ($_.Exception.Message -match 'IDE_CRASHED') { throw }; $netId = $null }
        if ([string]::IsNullOrWhiteSpace($netId)) { $netId = $script:TcAdsAmsNetId }
        $stateBefore = Get-TcQuietPlcState -NetId $netId -Port $plcPort

        # Use LookupTreeItem with full path — this returns an ITcSmTreeItem
        # that reliably exposes Login(nFlags) method
        $plcProject = Invoke-TcComRetry -OperationName "LookupTreeItem $PlcProjectPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($PlcProjectPath) }

        # PLC_LOGIN_FLAGS: <mode> | SILENT. Never REGULAR|FORCEONLINECHANGE (=3): XAE rejects
        # that combination as conflicting on the download path (see .DESCRIPTION).
        if (-not $script:TcSilentMode -and -not $SilentFlag) {
            Write-Warning 'Enter-TcPlcOnline: ITcAutomationSettings.SilentMode is not enabled on this IDE; Login may block on a dialog when the runtime has no application.'
        }
        Write-Verbose "Login flags: $loginFlags ($LoginMode$(if ($SilentFlag) { ' | SILENT' }))"
        Invoke-TcComRetry -OperationName "Login($loginFlags)" -TimeoutSec $TimeoutSec -ScriptBlock { $plcProject.Login($loginFlags) } | Out-Null

        $stateAfter = Get-TcQuietPlcState -NetId $netId -Port $plcPort

        # Run(5) / Stop(6) before AND unchanged after login -> program was already there.
        $downloaded = $true
        $message = 'Logged into PLC runtime with program download (no dialogs).'
        if ($null -ne $stateBefore -and ($stateBefore -eq 5 -or $stateBefore -eq 6) -and $stateAfter -eq $stateBefore) {
            $downloaded = $false
            $message = 'Logged into PLC runtime (program already loaded, no download).'
        }

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            online         = $true
            plcProjectPath = $PlcProjectPath
            plcName        = $plcName
            adsPort        = $plcPort
            loginMode      = $LoginMode
            loginFlags     = $loginFlags
            message        = $message
            downloaded     = $downloaded
            plcStateBefore = (ConvertTo-TcAdsStateName -State $stateBefore)
            plcStateAfter  = (ConvertTo-TcAdsStateName -State $stateAfter)
        })
    }
    catch {
        if ($_.Exception.Message -match '(?i)already\s+(logged\s*in|online)' -and $_.Exception.Message -notmatch 'IDE_MODAL_DIALOG|IDE_TIMEOUT|IDE_CRASHED|IDE_BUSY') {
            $stateAfterAlready = $null
            try { $stateAfterAlready = Get-TcQuietPlcState -NetId $netId -Port $plcPort } catch { $stateAfterAlready = $null }
            New-TcResult -Success $true -Data ([PSCustomObject]@{
                online         = $true
                plcProjectPath = $PlcProjectPath
                plcName        = $plcName
                adsPort        = $plcPort
                loginMode      = $LoginMode
                loginFlags     = $loginFlags
                message        = 'Already logged into PLC runtime.'
                downloaded     = $false
                plcStateBefore = (ConvertTo-TcAdsStateName -State $stateBefore)
                plcStateAfter  = (ConvertTo-TcAdsStateName -State $stateAfterAlready)
            })
        }
        else {
            $errData = $null
            if ($null -ne $script:TcLastModalDialog) {
                $errData = [PSCustomObject]@{ dialogTitle = [string]$script:TcLastModalDialog.Title; dialogText = [string]$script:TcLastModalDialog.Text }
            }
            New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'LOGIN_FAILED' -MessagePrefix 'PLC login failed' -Data $errData
        }
    }
}
