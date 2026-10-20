function Initialize-TcMessageBoxNative {
    <#
    .SYNOPSIS
        Compiles the user32 P/Invoke helper TcAutomation.MessageBoxNative once per process.
        Returns $null on success, else the error message.
    #>
    [CmdletBinding()]
    param()
    try {
        if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.MessageBoxNative').Type) {
            Add-Type -Namespace TcAutomation -Name MessageBoxNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool PostMessage(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint msg, System.IntPtr wParam, System.IntPtr lParam, uint flags, uint timeoutMs, out System.IntPtr result);
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr GetDlgItem(System.IntPtr hDlg, int nIDDlgItem);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindow(System.IntPtr hWnd);
'@ -ErrorAction Stop
        }
        return $null
    }
    catch { return $_.Exception.Message }
}

function Close-TcMessageBox {
    <#
    .SYNOPSIS
        Answers a Win32 message box (#32770) of the connected IDE by DIALOG CONTROL ID, so it
        works on any UI language.
    .DESCRIPTION
        -Answer Yes|No|Ok|Cancel clicks the button with control id IDYES 6 / IDNO 7 / IDOK 1 /
        IDCANCEL 2: GetDlgItem(hwnd, id), then BM_CLICK (0x00F5) through SendMessageTimeout
        (SMTO_ABORTIFHUNG, 5000 ms; a plain SendMessage would hang when the dialog thread is
        busy). Only when that send fails / times out on an existing button, WM_COMMAND (0x0111)
        with wParam = MAKEWPARAM(id, BN_CLICKED 0) = id is posted to the dialog instead. A
        dialog without that control id is not answered (Sent = false, 'control id N not found').
        -Answer Close (default) posts WM_CLOSE (0x0010), i.e. the title-bar X (= Cancel / No).

        Captions and UIA names are never used: on a zh-TW Windows the XAE message box buttons
        are UIA ControlType.Pane named with localized captions, AutomationId 6 / 7 (= IDYES /
        IDNO); only the control id is stable.

        The window must belong to the IDE process (-ProcessId, default $script:TcIdeProcessId);
        any other window is refused. This function only sends; it does not wait for the dialog
        to close (Close-TcReloadPrompt polls).
    .PARAMETER Hwnd
        Native handle of the dialog (Get-TcIdeModalDialog .Hwnd).
    .PARAMETER Answer
        Yes | No | Ok | Cancel | Close. Default Close.
    .PARAMETER ProcessId
        Process that must own the window. Default: $script:TcIdeProcessId.
    .OUTPUTS
        Hashtable @{ Sent = [bool]; Method = 'BM_CLICK' | 'WM_COMMAND' | 'WM_CLOSE' | $null;
        ControlId = [int]; Reason = [string] }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Hwnd,

        [Parameter()]
        [ValidateSet('Yes', 'No', 'Ok', 'Cancel', 'Close')]
        [string]$Answer = 'Close',

        [Parameter()]
        [int]$ProcessId = 0
    )

    $result = @{ Sent = $false; Method = $null; ControlId = 0; Reason = $null }
    if ($Hwnd -eq [IntPtr]::Zero) { $result.Reason = 'dialog window handle unknown'; return $result }

    if ($ProcessId -le 0 -and $null -ne $script:TcIdeProcessId) {
        try { $ProcessId = [int]$script:TcIdeProcessId } catch { $ProcessId = 0 }
    }
    if ($ProcessId -le 0) { $result.Reason = 'IDE process id unknown'; return $result }

    $initError = Initialize-TcMessageBoxNative
    if ($null -ne $initError) { $result.Reason = "native helper unavailable: $initError"; return $result }
    $native = [TcAutomation.MessageBoxNative]

    if (-not $native::IsWindow($Hwnd)) { $result.Reason = 'dialog already gone'; return $result }
    $ownerPid = [uint32]0
    $null = $native::GetWindowThreadProcessId($Hwnd, [ref]$ownerPid)
    if ([int]$ownerPid -ne $ProcessId) {
        $result.Reason = "dialog belongs to pid $ownerPid, not the IDE pid $ProcessId"
        return $result
    }

    if ($Answer -eq 'Close') {
        $WM_CLOSE = [uint32]0x0010
        if ($native::PostMessage($Hwnd, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)) {
            $result.Sent = $true; $result.Method = 'WM_CLOSE'; $result.Reason = 'WM_CLOSE posted'
        }
        else { $result.Reason = 'PostMessage WM_CLOSE failed' }
        Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd, pid $ProcessId)."
        return $result
    }

    $ids = @{ Ok = 1; Cancel = 2; Yes = 6; No = 7 }
    $id = [int]$ids[$Answer]
    $result.ControlId = $id

    $hBtn = $native::GetDlgItem($Hwnd, $id)
    if ($hBtn -eq [IntPtr]::Zero) {
        $result.Reason = "control id $id ($Answer) not found in the dialog"
        Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd)."
        return $result
    }
    $BM_CLICK = [uint32]0x00F5
    $SMTO_ABORTIFHUNG = [uint32]0x0002
    $smResult = [IntPtr]::Zero
    $ret = $native::SendMessageTimeout($hBtn, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero, $SMTO_ABORTIFHUNG, [uint32]5000, [ref]$smResult)
    if ($ret -ne [IntPtr]::Zero) {
        $result.Sent = $true; $result.Method = 'BM_CLICK'; $result.Reason = "BM_CLICK sent to control $id ($Answer)"
        Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd, pid $ProcessId)."
        return $result
    }
    # Timed out / hung: the click may still be processed; fall back to the posted command.
    Write-Verbose "Close-TcMessageBox: SendMessageTimeout BM_CLICK to control $id failed or timed out; posting WM_COMMAND."

    $WM_COMMAND = [uint32]0x0111
    # MAKEWPARAM(id, BN_CLICKED = 0) = id; lParam = the button handle.
    if ($native::PostMessage($Hwnd, $WM_COMMAND, [IntPtr]$id, $hBtn)) {
        $result.Sent = $true; $result.Method = 'WM_COMMAND'; $result.Reason = "WM_COMMAND $id ($Answer) posted"
    }
    else { $result.Reason = "PostMessage WM_COMMAND $id failed" }
    Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd, pid $ProcessId)."
    return $result
}
