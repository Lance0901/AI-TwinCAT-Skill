function Close-TcReloadPrompt {
    <#
    .SYNOPSIS
        Answers the IDE's reload prompt (Kind 'reload-prompt': the VS "File has been changed
        outside the environment. Reload the new file?" or the XAE "The project file ... has
        been modified outside of TwinCAT XAE. Do you want to reload the project?") through
        Close-TcMessageBox, then waits until that dialog is gone.
    .DESCRIPTION
        -Answer Close (default, the original behaviour) posts WM_CLOSE: Reset-TcSolution
        closes and reopens the whole solution right afterwards, so the answer does not matter.
        -Answer Yes clicks IDYES by control id (language independent); Reset-TcSolution uses
        it for the project prompt so XAE reloads the project itself. -Answer No (IDNO 7) is
        Reset-TcSolution's fallback for a project prompt whose Yes failed twice: an MB_YESNO box
        ignores WM_CLOSE (measured 2026-11-07, Windows 11 26200: MB_YESNO stayed open, MB_YESNOCANCEL
        closed; MessageBox docs: without a Cancel button ESC / close has no effect,
        https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-messagebox).
        -Answer Reload clicks control id 259 of the VS2022 solution reload prompt (ReloadTarget
        'solution', #106; measured 2026-11-03 VS2022 zh-TW, TcXaeShell / other languages not
        verified).
        The window must belong to the connected IDE process ($script:TcIdeProcessId); any
        other window is refused (Close-TcMessageBox).
        Measured 2026-10-20 (4024 32-bit XAE): the file prompt is gone ~2 s after WM_CLOSE.

        Poll: every 500 ms until the dialog window no longer exists. IsWindow on the original
        handle is the only proof (the scan may not complete: Find-TcIdeModalDialog then returns
        the incomplete-scan record, #42).
        Once it is gone, the scan result is reported: a reload prompt that appears right after
        (another file / project) is returned as NextDialog with Dismissed = true; any other
        dialog as NextDialog with Dismissed = false. Timeout -> Dismissed = false.
    .PARAMETER Dialog
        Dialog record from Find-TcIdeModalDialog (@{ Title; Text; Kind; ReloadTarget; Hwnd }).
    .PARAMETER Answer
        Yes | No | Ok | Cancel | Reload | Close. Default Close.
    .PARAMETER TimeoutSec
        How long to wait for the dialog to disappear. Default 8.
    .OUTPUTS
        Hashtable @{ Dismissed = [bool]; Reason = [string]; Method = [string]; Sent = [bool];
        Answer = [string]; NextDialog = <dialog record or $null>; ControlId = [int]; BmClick;
        WmCommand; SendReason }. ControlId / BmClick / WmCommand / SendReason are passed on from
        Close-TcMessageBox (SendReason = its Reason; see its OUTPUTS).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Dialog,

        [Parameter()]
        [ValidateSet('Yes', 'No', 'Ok', 'Cancel', 'Reload', 'Close')]
        [string]$Answer = 'Close',

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
    $out = @{ Dismissed = $false; Reason = $null; Method = $null; Sent = $false; Answer = $Answer; NextDialog = $null
        ControlId = 0; BmClick = $null; WmCommand = $null; SendReason = $null }
    if ($hwnd -le 0) { $out.Reason = 'dialog window handle unknown'; return $out }

    $send = Close-TcMessageBox -Hwnd ([IntPtr]$hwnd) -Answer $Answer
    $out.Method = $send.Method
    $out.Sent = [bool]$send.Sent
    $out.SendReason = [string]$send.Reason
    try { $out.ControlId = [int]$send.ControlId } catch { $out.ControlId = 0 }
    $out.BmClick = $send.BmClick
    $out.WmCommand = $send.WmCommand
    if (-not $send.Sent) {
        if ($send.Reason -eq 'dialog already gone') { $out.Dismissed = $true }
        $out.Reason = $send.Reason
        return $out
    }
    Write-Verbose "Close-TcReloadPrompt: $($send.Reason) (hwnd $hwnd)."

    $null = Initialize-TcMessageBoxNative
    $h = [IntPtr]$hwnd
    $deadline = [DateTime]::Now.AddSeconds($TimeoutSec)
    while ([DateTime]::Now -lt $deadline) {
        Start-Sleep -Milliseconds 500
        $gone = $false
        try { $gone = -not [TcAutomation.MessageBoxNative]::IsWindow($h) } catch { $gone = $false }
        if (-not $gone) { continue }   # IsWindow is the authority; the scan may not complete (#42)
        $again = Find-TcIdeModalDialog
        if ($null -eq $again) { $out.Dismissed = $true; $out.Reason = 'dialog closed'; return $out }
        if (Test-TcModalScanIncomplete $again) {
            # #42: our dialog is gone (IsWindow); what is up now is unknown. NextDialog stays
            # $null: the caller's next step scans again and fails closed on another incomplete scan.
            $out.Dismissed = $true
            $out.Reason = "dialog closed; the follow-up modal-dialog scan did not complete ($([string]$again.Reason))"
            return $out
        }
        $out.NextDialog = $again
        if ([string]$again.Kind -eq 'reload-prompt') {
            $out.Dismissed = $true
            $out.Reason = "dialog closed; another reload prompt ($($again.ReloadTarget)) is up: $($again.Title)"
        }
        else {
            $out.Dismissed = $false
            $out.Reason = "another dialog is up: $($again.Title)"
        }
        return $out
    }
    $out.Reason = "dialog still shown after $TimeoutSec s"
    return $out
}
