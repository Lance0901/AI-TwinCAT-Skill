function Enter-TcPlcOnline {
    <#
    .SYNOPSIS
        Logs into PLC runtime and downloads program — no dialog popups.
    .DESCRIPTION
        Uses ITcSmTreeItem::Login(3) on the PLC Project node.
        Flag 3 = CompileBeforeLogin(1) + SuppressAllDialogs(2).
        This triggers Login + Download automatically if no program is loaded.

        Before Login the IDE is checked for a modal dialog (IDE_MODAL_DIALOG is
        returned instead of issuing a DTE call that would block forever), and the
        AdsState of port 851 is read (module session when it points at <netId>:851,
        otherwise a temporary client). When 851 was already Run/Stop and is unchanged
        after Login, the program was already loaded (data.downloaded = $false);
        otherwise a download is assumed (data.downloaded = $true). This is a
        best-effort indication only.
    .PARAMETER PlcProjectPath
        Tree path to PLC project. Default auto-detects from TIPC.
    .OUTPUTS
        data: online, plcProjectPath, message, downloaded, plcStateBefore, plcStateAfter
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

    # AdsState of port 851 as [int] (Invalid=0 ... Run=5, Stop=6) or $null when unreachable.
    function Get-TcQuietPlcState {
        param([string]$NetId)
        if ([string]::IsNullOrWhiteSpace($NetId)) { return $null }
        try {
            if ($script:TcAdsConnected -and $null -ne $script:TcAdsClient -and
                $script:TcAdsAmsNetId -eq $NetId -and [int]$script:TcAdsPort -eq 851) {
                return [int]$script:TcAdsClient.ReadState().AdsState
            }
            $tmp = $null
            try {
                $tmp = New-TcAdsClient -AmsNetId $NetId -Port 851
                return [int]$tmp.ReadState().AdsState
            }
            finally {
                if ($null -ne $tmp) { try { $tmp.Dispose() } catch { } }
            }
        }
        catch {
            Write-Verbose "Enter-TcPlcOnline: port 851 state unreadable ($($_.Exception.Message))"
            return $null
        }
    }

    function ConvertTo-TcAdsStateName {
        param([object]$State)
        if ($null -eq $State) { return $null }
        try { return ([Enum]::ToObject([TwinCAT.Ads.AdsState], [int]$State)).ToString() } catch { return [string]$State }
    }

    try {
        if ([string]::IsNullOrWhiteSpace($PlcProjectPath)) {
            # Auto-detect: TIPC -> first PLC -> "<Plc> Project" (shared with Exit-TcPlcOnline)
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

        Write-Verbose "Login to: $PlcProjectPath"

        # A modal dialog makes Login() block forever (no COM error) - refuse up front.
        $dialog = Get-TcIdeModalDialog
        if ($null -ne $dialog) {
            return New-TcModalDialogResult -Dialog $dialog -Operation 'Login' -Data ([PSCustomObject]@{ plcProjectPath = $PlcProjectPath })
        }

        # PLC state before login (best effort; $null = port 851 not reachable = nothing loaded)
        $netId = $null
        try { $netId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() } } catch { $netId = $null }
        if ([string]::IsNullOrWhiteSpace($netId)) { $netId = $script:TcAdsAmsNetId }
        $stateBefore = Get-TcQuietPlcState -NetId $netId

        # Use LookupTreeItem with full path — this returns an ITcSmTreeItem
        # that reliably exposes Login(nFlags) method
        $plcProject = Invoke-TcComRetry -OperationName "LookupTreeItem $PlcProjectPath" -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem($PlcProjectPath) }

        # Login(3) = CompileBeforeLogin(1) + SuppressAllDialogs(2)
        # This also triggers Download if runtime has no program
        Invoke-TcComRetry -OperationName 'Login' -TimeoutSec 300 -ScriptBlock { $plcProject.Login(3) } | Out-Null

        $stateAfter = Get-TcQuietPlcState -NetId $netId

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
            message        = $message
            downloaded     = $downloaded
            plcStateBefore = (ConvertTo-TcAdsStateName -State $stateBefore)
            plcStateAfter  = (ConvertTo-TcAdsStateName -State $stateAfter)
        })
    }
    catch {
        if ($_.Exception.Message -match 'already' -and $_.Exception.Message -notmatch 'IDE_MODAL_DIALOG|IDE_TIMEOUT') {
            New-TcResult -Success $true -Data ([PSCustomObject]@{
                online         = $true
                plcProjectPath = $PlcProjectPath
                message        = 'Already logged into PLC runtime.'
                downloaded     = $false
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
