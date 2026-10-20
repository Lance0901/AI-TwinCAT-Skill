function Close-TcReloadPrompt {
    <#
    .SYNOPSIS
        Dismisses the IDE's "File has been changed outside the environment. Reload the new
        file?" prompt (Kind 'reload-prompt') by sending WM_CLOSE to that dialog window, then
        waits until Get-TcIdeModalDialog no longer sees it.
    .DESCRIPTION
        Only used by Reset-TcSolution, which closes and reopens the whole solution right
        afterwards, so the answer to the prompt does not matter. The window must belong to
        the connected IDE process ($script:TcIdeProcessId); any other window is refused.
        Measured 2026-10-20 (4024 32-bit XAE): the prompt is gone ~2 s after WM_CLOSE.
    .PARAMETER Dialog
        Dialog record from Get-TcIdeModalDialog (@{ Title; Text; Kind; Hwnd }).
    .PARAMETER TimeoutSec
        How long to wait for the dialog to disappear. Default 8.
    .OUTPUTS
        Hashtable @{ Dismissed = [bool]; Reason = [string] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Dialog,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$TimeoutSec = 8
    )

    $hwnd = [long]0
    try {
        if ($Dialog -is [System.Collections.IDictionary]) { if ($Dialog.Contains('Hwnd')) { $hwnd = [long]$Dialog['Hwnd'] } }
        else { $hp = $Dialog.PSObject.Properties['Hwnd']; if ($null -ne $hp) { $hwnd = [long]$hp.Value } }
    }
    catch { $hwnd = 0 }
    if ($hwnd -le 0) { return @{ Dismissed = $false; Reason = 'dialog window handle unknown' } }

    $idePid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $idePid = [int]$script:TcIdeProcessId } catch { $idePid = 0 } }
    if ($idePid -le 0) { return @{ Dismissed = $false; Reason = 'IDE process id unknown' } }

    try {
        if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.ReloadPromptNative').Type) {
            Add-Type -Namespace TcAutomation -Name ReloadPromptNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindow(System.IntPtr hWnd);
'@ -ErrorAction Stop
        }
    }
    catch { return @{ Dismissed = $false; Reason = "native helper unavailable: $($_.Exception.Message)" } }

    $h = [IntPtr]$hwnd
    if (-not [TcAutomation.ReloadPromptNative]::IsWindow($h)) { return @{ Dismissed = $true; Reason = 'dialog already gone' } }
    $ownerPid = [uint32]0
    $null = [TcAutomation.ReloadPromptNative]::GetWindowThreadProcessId($h, [ref]$ownerPid)
    if ([int]$ownerPid -ne $idePid) { return @{ Dismissed = $false; Reason = "dialog belongs to pid $ownerPid, not the IDE pid $idePid" } }

    $WM_CLOSE = [uint32]0x0010
    if (-not [TcAutomation.ReloadPromptNative]::PostMessage($h, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)) {
        return @{ Dismissed = $false; Reason = 'PostMessage WM_CLOSE failed' }
    }
    Write-Verbose "Close-TcReloadPrompt: WM_CLOSE posted to hwnd $hwnd (pid $idePid)."

    # Poll until the scan no longer reports a dialog (the IDE needs ~2 s).
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $again = Get-TcIdeModalDialog
        if ($null -eq $again) { return @{ Dismissed = $true; Reason = 'dialog closed' } }
        if ([string]$again.Kind -ne 'reload-prompt') { return @{ Dismissed = $false; Reason = "another dialog is up: $($again.Title)" } }
    }
    return @{ Dismissed = $false; Reason = "dialog still shown after $TimeoutSec s" }
}
