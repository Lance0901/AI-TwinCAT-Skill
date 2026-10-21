function Invoke-TcActivateWithDeadline {
    <#
    .SYNOPSIS
        ITcSysManager::ActivateConfiguration() with a real deadline (ACTIVATE_TIMEOUT).
    .DESCRIPTION
        Invoke-TcComRetry runs a COM call synchronously on the caller's thread: a call that
        never returns (measured 2026-10-21: ActivateConfiguration() blocked 17 min while the
        target could not write its Boot folder; VS2022 was then reported "not responding")
        cannot be interrupted, its -TimeoutSec only classifies a call that eventually fails.
        Here the call runs in a separate STA runspace on its own thread, on its own reference
        to the SAME IDE: the DTE is taken from the Running Object Table by the IDE pid
        ("!<ProgId>:<pid>", ComRotHelper) and ITcSysManager from Solution.Projects(i).Object,
        exactly like Get-TcSysManager. The caller's thread waits at most -TimeoutSec and
        meanwhile looks for a modal dialog every 2 s (recorded in $script:TcLastModalDialog,
        same as the Invoke-TcComRetry watchdog; never touches a window).
        On timeout the background call is abandoned (it cannot be cancelled either; the IDE
        keeps working on it) and an exception "ACTIVATE_TIMEOUT: ..." is thrown; the
        diagnostics are left in $script:TcLastActivateDiagnostics:
          dialog        modal dialog of the IDE (Title/Text) or $null
          ideAlive      IDE process still exists
          ideResponding Process.Responding (Windows "not responding" = $false)
          runtimeAlive  local UmRT: its TcSystemServiceUm.exe process exists ($null when the
                        target is not a UmRT on this PC)
          systemState   AdsState of port 10000 (or 'unreachable: <error>')
        Errors of the call itself are rethrown with the same classification as
        Invoke-TcComRetry: IDE_CRASHED when the IDE process is gone, IDE_MODAL_DIALOG when a
        dialog was seen, otherwise the original message.
    .PARAMETER TimeoutSec
        Deadline for the call.
    .PARAMETER AmsNetId
        Target NetId (only for the diagnostics).
    .PARAMETER ActivateScript
        Test hook: script text run in the background runspace instead of the real activation
        (param($DtePid)); used by tests/Unit/activate-timeout.ps1 to exercise the timeout path
        without a hanging IDE.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, 86400)][int]$TimeoutSec,
        [string]$AmsNetId,
        [string]$ActivateScript
    )

    $script:TcLastActivateDiagnostics = $null
    $script:TcLastModalDialog = $null
    $idePid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $idePid = [int]$script:TcIdeProcessId } catch { $idePid = 0 } }

    $realScript = @'
param($DtePid)
$entry = $null
foreach ($e in [ComRotHelper]::GetAllDteInstances()) {
    if ([string]$e['DisplayName'] -match (':' + $DtePid + '\s*$')) { $entry = $e; break }
}
if ($null -eq $entry) { throw "DTE of pid $DtePid not found in the Running Object Table" }
$dte = $entry['Object']
$sm = $null
for ($i = 1; $i -le $dte.Solution.Projects.Count; $i++) {
    try { $o = $dte.Solution.Projects.Item($i).Object; if ($null -ne $o) { $sm = $o; break } } catch { }
}
if ($null -eq $sm) { throw 'No TwinCAT project (ITcSysManager) in the solution of that IDE' }
$sm.ActivateConfiguration()
'done'
'@
    $scriptText = if ([string]::IsNullOrWhiteSpace($ActivateScript)) { $realScript } else { $ActivateScript }
    if ([string]::IsNullOrWhiteSpace($ActivateScript)) {
        if ($idePid -le 0) { throw 'ACTIVATE_TIMEOUT: IDE process id unknown (Connect-TcIde first); cannot run ActivateConfiguration() with a deadline.' }
        $null = Get-AllComObjects   # loads ComRotHelper into this AppDomain (shared with the runspace)
    }

    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.ApartmentState = [System.Threading.ApartmentState]::STA
    $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($scriptText).AddArgument($idePid)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $async = $ps.BeginInvoke()
    $nextScan = 2.0
    $completed = $false
    try {
        while ($true) {
            if ($async.AsyncWaitHandle.WaitOne(250)) { $completed = $true; break }
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
            if ($sw.Elapsed.TotalSeconds -ge $nextScan) {
                $nextScan = $sw.Elapsed.TotalSeconds + 2
                try {
                    $dlg = Get-TcIdeModalDialog
                    if ($null -ne $dlg) { $script:TcLastModalDialog = $dlg }
                } catch { }
            }
        }

        if ($completed) {
            $out = $null
            $err = $null
            try { $out = $ps.EndInvoke($async) } catch { $err = $_.Exception }
            if ($null -eq $err -and $ps.HadErrors -and $ps.Streams.Error.Count -gt 0) { $err = $ps.Streams.Error[0].Exception }
            if ($null -ne $err) {
                $msg = $err.Message
                if ($null -ne $err.InnerException) { $msg = "$msg | $($err.InnerException.Message)" }
                $ideGone = $false
                if ($idePid -gt 0) { try { $null = Get-Process -Id $idePid -ErrorAction Stop } catch { $ideGone = $true } }
                if ($ideGone) {
                    $script:TcLastIdeCrash = "$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss')) $msg"
                    $script:TcIdeConnected = $false
                    $script:TcSysManager = $null
                    $script:TcDte = $null
                    $script:TcIdeProcessId = $null
                    throw "IDE_CRASHED: the IDE process (pid $idePid) no longer exists after 'ActivateConfiguration' failed ($([int]$sw.Elapsed.TotalSeconds) s, original error: $msg). The XAE crashed; module IDE state was reset."
                }
                if ($null -ne $script:TcLastModalDialog) {
                    $t = [string]$script:TcLastModalDialog.Text
                    if ($t.Length -gt 200) { $t = $t.Substring(0, 200) }
                    throw "IDE_MODAL_DIALOG: $($script:TcLastModalDialog.Title) | $t (operation 'ActivateConfiguration', original error: $msg)"
                }
                throw $msg
            }
            return
        }

        # --- deadline passed: collect diagnostics, abandon the call ---
        $diag = [ordered]@{ dialog = $null; ideAlive = $null; ideResponding = $null; runtimeAlive = $null; systemState = $null; elapsedSec = [int]$sw.Elapsed.TotalSeconds }
        try {
            $dlg = Get-TcIdeModalDialog
            if ($null -ne $dlg) { $script:TcLastModalDialog = $dlg; $diag.dialog = [PSCustomObject]@{ title = [string]$dlg.Title; text = [string]$dlg.Text } }
        } catch { }
        if ($idePid -gt 0) {
            try { $proc = Get-Process -Id $idePid -ErrorAction Stop; $diag.ideAlive = $true; $diag.ideResponding = [bool]$proc.Responding }
            catch { $diag.ideAlive = $false }
        }
        if (-not [string]::IsNullOrWhiteSpace($AmsNetId)) {
            try {
                $boot = Resolve-TcTargetBootDir -AmsNetId $AmsNetId
                if ($null -ne $boot -and $boot.Kind -like 'umrt:*') {
                    $name = $boot.Kind.Substring(5)
                    $diag.runtimeAlive = @(Get-CimInstance Win32_Process -Filter "Name='TcSystemServiceUm.exe'" -ErrorAction Stop | Where-Object { $_.CommandLine -match [regex]::Escape($name) }).Count -gt 0
                }
            } catch { }
            $c = $null
            try { $c = New-TcAdsClient -AmsNetId $AmsNetId -Port 10000; $diag.systemState = $c.ReadState().AdsState.ToString() }
            catch { $diag.systemState = "unreachable: $($_.Exception.Message)" }
            finally { if ($null -ne $c) { try { $c.Dispose() } catch { } } }
        }
        $script:TcLastActivateDiagnostics = [PSCustomObject]$diag
        $parts = @()
        if ($null -ne $diag.dialog) { $parts += "modal dialog '$($diag.dialog.title)'" }
        if ($diag.ideAlive -eq $false) { $parts += 'IDE process gone' }
        elseif ($diag.ideResponding -eq $false) { $parts += 'IDE not responding' }
        if ($diag.runtimeAlive -eq $false) { $parts += 'UmRT process (TcSystemServiceUm) not running' }
        if ($null -ne $diag.systemState) { $parts += "system state $($diag.systemState)" }
        throw "ACTIVATE_TIMEOUT: ActivateConfiguration() did not return within $TimeoutSec s; the call was abandoned (it keeps running inside the IDE). $($parts -join '; ')"
    }
    finally {
        if ($completed) {
            try { $ps.Dispose() } catch { }
            try { $rs.Dispose() } catch { }
        }
        else {
            # Never block on a call that does not return: stop asynchronously and leave the runspace.
            try { $null = $ps.BeginStop($null, $null) } catch { }
        }
    }
}
