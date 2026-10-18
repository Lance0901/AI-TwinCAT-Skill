function Invoke-TcComRetry {
    <#
    .SYNOPSIS
        Runs a COM/DTE call with exponential-backoff retry when the IDE reports busy,
        and a modal-dialog watchdog while the call is running.
    .DESCRIPTION
        Executes -ScriptBlock synchronously on the caller's thread (dynamic scoping:
        $sm, $dte, parameters ... of the caller are visible inside it). If it throws
        an exception whose message (or HResult) matches RPC_E_CALL_REJECTED
        (0x80010001) or RPC_E_SERVERCALL_RETRYLATER (0x8001010A), waits 1, 2, 4, 8,
        16 ... seconds and retries, up to -MaxRetries attempts in total. Any other
        exception is rethrown immediately.

        Watchdog: when the IDE process id is known ($script:TcIdeProcessId, set by
        Connect-TcIde) a background runspace scans the IDE for a modal dialog every
        2 s (same UI Automation scan as Get-TcIdeModalDialog). It only records what
        it sees in $script:TcLastModalDialog - it never touches any window.
          - call failed + dialog seen  -> throws "IDE_MODAL_DIALOG: <Title> | <Text>"
          - call failed + ran longer than -TimeoutSec -> throws "IDE_TIMEOUT: ..."
          - call failed, busy exhausted -> throws "IDE_BUSY: ..."
          - call succeeded + dialog seen -> result returned, warning written
        Limitation: a DTE call that is blocked by a modal dialog (e.g. the XAE
        "Assertion Failed" box) does NOT return and cannot be interrupted from here;
        callers check Get-TcIdeModalDialog BEFORE issuing such calls.

        Internal variables are prefixed with __tc to avoid shadowing caller variables.
    .PARAMETER ScriptBlock
        The COM call(s) to execute.
    .PARAMETER MaxRetries
        Total number of attempts. Default 5.
    .PARAMETER OperationName
        Name used in verbose/error messages.
    .PARAMETER TimeoutSec
        Expected upper bound of the call. It cannot abort the synchronous call; when
        the call eventually fails after running longer than this, the error is
        reported as IDE_TIMEOUT. Default 120.
    .EXAMPLE
        $item = Invoke-TcComRetry -OperationName 'LookupTreeItem' -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem('TIPC') }
        COM objects that are enumerable (tree items) must be emitted with
        Write-Output -NoEnumerate or ,$x inside the script block, otherwise they are
        unrolled into their children before this wrapper sees them.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0)]
        [scriptblock]$ScriptBlock,

        [Parameter()]
        [ValidateRange(1, 20)]
        [int]$MaxRetries = 5,

        [Parameter()]
        [string]$OperationName = 'COM call',

        [Parameter()]
        [ValidateRange(1, 86400)]
        [int]$TimeoutSec = 120
    )

    $__tcBusyPattern = '0x80010001|RPC_E_CALL_REJECTED|0x8001010A|RPC_E_SERVERCALL_RETRYLATER'
    $__tcBusyHResults = @([int64]0x80010001, [int64]0x8001010A)
    $__tcDelaySec = 1
    $__tcStopwatch = [System.Diagnostics.Stopwatch]::StartNew()

    # --- watchdog (only when the IDE pid is known; never fails the call) ---
    $script:TcLastModalDialog = $null
    $__tcSync = $null
    $__tcWatchPs = $null
    $__tcWatchRs = $null
    $__tcIdePid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $__tcIdePid = [int]$script:TcIdeProcessId } catch { $__tcIdePid = 0 } }
    if ($__tcIdePid -gt 0 -and $null -ne $script:TcUiaDialogScan) {
        try {
            $__tcSync = [hashtable]::Synchronized(@{ Stop = $false; Dialog = $null; Error = $null })
            $__tcMainHwnd = [long]0
            if ($null -ne $script:TcIdeMainHwnd) { try { $__tcMainHwnd = [long]$script:TcIdeMainHwnd } catch { $__tcMainHwnd = 0 } }
            if ($__tcMainHwnd -eq 0) {
                # DTE.MainWindow.HWnd was 0 at connect time (fresh IDE); ask the process once and remember it.
                try { $__tcMainHwnd = [long](Get-Process -Id $__tcIdePid -ErrorAction Stop).MainWindowHandle } catch { $__tcMainHwnd = 0 }
                if ($__tcMainHwnd -ne 0) { $script:TcIdeMainHwnd = $__tcMainHwnd }
            }
            $__tcWatchRs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
            $__tcWatchRs.ApartmentState = [System.Threading.ApartmentState]::STA
            $__tcWatchRs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
            $__tcWatchRs.Open()
            $__tcWatchPs = [PowerShell]::Create()
            $__tcWatchPs.Runspace = $__tcWatchRs
            $__tcWatchScript = @'
param($Sync, $ScanText, $TargetPid, $MainHwnd)
$scan = [scriptblock]::Create($ScanText)
# First scan after 2 s: short calls never pay for a UIA scan.
$next = [DateTime]::Now.AddSeconds(2)
while (-not $Sync.Stop) {
    if ([DateTime]::Now -ge $next) {
        try {
            $hit = & $scan $TargetPid $MainHwnd 500
            if ($null -ne $hit -and -not [string]::IsNullOrWhiteSpace([string]$hit.Title)) {
                $Sync.Dialog = @{ Title = [string]$hit.Title; Text = [string]$hit.Text }
                break
            }
        }
        catch { $Sync.Error = $_.Exception.Message }
        $next = [DateTime]::Now.AddSeconds(2)
    }
    Start-Sleep -Milliseconds 200
}
'@
            $null = $__tcWatchPs.AddScript($__tcWatchScript).AddArgument($__tcSync).AddArgument($script:TcUiaDialogScan.ToString()).AddArgument($__tcIdePid).AddArgument($__tcMainHwnd)
            $null = $__tcWatchPs.BeginInvoke()
        }
        catch {
            Write-Verbose "Invoke-TcComRetry [$OperationName]: watchdog not started ($($_.Exception.Message))"
            $__tcSync = $null
            if ($null -ne $__tcWatchPs) { try { $__tcWatchPs.Dispose() } catch { } }
            if ($null -ne $__tcWatchRs) { try { $__tcWatchRs.Dispose() } catch { } }
            $__tcWatchPs = $null
            $__tcWatchRs = $null
        }
    }

    try {
        for ($__tcAttempt = 1; $__tcAttempt -le $MaxRetries; $__tcAttempt++) {
            try {
                # COM tree items (ITcSmTreeItem) expose _NewEnum, so PowerShell would unroll
                # them into their children on output. Callers emit COM objects with
                # Write-Output -NoEnumerate (or ,$x); here the collected result is passed on
                # unenumerated as well.
                $__tcResult = & $ScriptBlock
                if ($null -ne $__tcSync -and $null -ne $__tcSync.Dialog) {
                    $script:TcLastModalDialog = $__tcSync.Dialog
                    Write-Warning "Invoke-TcComRetry [$OperationName]: a modal dialog was seen while the call ran ($($__tcSync.Dialog.Title)); the call still returned."
                }
                Write-Output -NoEnumerate $__tcResult
                return
            }
            catch {
                # Inspect the whole exception chain (MethodInvocationException wraps COMException)
                $__tcIsBusy = $false
                $__tcEx = $_.Exception
                while ($null -ne $__tcEx) {
                    if ($__tcEx.Message -match $__tcBusyPattern) { $__tcIsBusy = $true; break }
                    $__tcHr = $__tcEx.PSObject.Properties['HResult']
                    if ($null -ne $__tcHr -and $null -ne $__tcHr.Value) {
                        try {
                            if ($__tcBusyHResults -contains ([int64]$__tcHr.Value -band 0xFFFFFFFF)) { $__tcIsBusy = $true; break }
                        }
                        catch { }
                    }
                    $__tcEx = $__tcEx.InnerException
                }

                $__tcDialog = $null
                if ($null -ne $__tcSync) { $__tcDialog = $__tcSync.Dialog }
                if ($null -ne $__tcDialog) {
                    $script:TcLastModalDialog = $__tcDialog
                    $__tcText = [string]$__tcDialog.Text
                    if ($__tcText.Length -gt 200) { $__tcText = $__tcText.Substring(0, 200) }
                    throw "IDE_MODAL_DIALOG: $($__tcDialog.Title) | $__tcText (operation '$OperationName', original error: $($_.Exception.Message))"
                }

                if (-not $__tcIsBusy) {
                    if ($__tcStopwatch.Elapsed.TotalSeconds -gt $TimeoutSec) {
                        throw "IDE_TIMEOUT: '$OperationName' did not return within $TimeoutSec s (took $([int]$__tcStopwatch.Elapsed.TotalSeconds) s, original error: $($_.Exception.Message))"
                    }
                    throw
                }

                if ($__tcAttempt -ge $MaxRetries) {
                    throw "IDE_BUSY: '$OperationName' failed after $MaxRetries attempts - the IDE rejected the call (RPC_E_CALL_REJECTED 0x80010001). A modal dialog or license window is probably blocking the XAE. Original error: $($_.Exception.Message)"
                }

                Write-Verbose "Invoke-TcComRetry [$OperationName] attempt $__tcAttempt/$MaxRetries - IDE busy, retrying in $__tcDelaySec s..."
                Start-Sleep -Seconds $__tcDelaySec
                $__tcDelaySec = $__tcDelaySec * 2
            }
        }
    }
    finally {
        if ($null -ne $__tcSync) {
            $__tcSync.Stop = $true
            if ($null -ne $__tcSync.Dialog -and $null -eq $script:TcLastModalDialog) { $script:TcLastModalDialog = $__tcSync.Dialog }
        }
        if ($null -ne $__tcWatchPs) {
            # Never block on Stop(): a scan stuck inside UIA would hang the caller.
            try { $null = $__tcWatchPs.BeginStop($null, $null) } catch { }
            # Dispose after a short grace period so a normal loop exit is cleaned up
            # synchronously; a stuck scan is abandoned (its runspace is collected later).
            $__tcGrace = [DateTime]::Now.AddMilliseconds(500)
            while ($__tcWatchPs.InvocationStateInfo.State -eq 'Running' -and [DateTime]::Now -lt $__tcGrace) { Start-Sleep -Milliseconds 50 }
            if ($__tcWatchPs.InvocationStateInfo.State -ne 'Running') {
                try { $__tcWatchPs.Dispose() } catch { }
                if ($null -ne $__tcWatchRs) { try { $__tcWatchRs.Dispose() } catch { } }
            }
        }
    }
}
