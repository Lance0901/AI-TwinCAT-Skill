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
        # Separate type (#64 review S2): a process that already compiled MessageBoxNative above
        # (module re-imported with -Force) cannot get new members on that type.
        if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.MessageBoxState').Type) {
            Add-Type -Namespace TcAutomation -Name MessageBoxState -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowEnabled(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr hWnd, uint uCmd);
'@ -ErrorAction Stop
        }
        return $null
    }
    catch { return $_.Exception.Message }
}

# UI Automation answer for the VS2022 WPF message box (AutomationId
# 'Microsoft.VisualStudio.MessageBox'), whose buttons have no Win32 control id (GetDlgItem finds
# nothing; measured 2026-10-21, XAE 4026.22 in VS2022 zh-TW). Runs INSIDE a separate STA runspace
# (Invoke-TcMessageBoxUia), so it must be self-contained. Arguments: target pid, dialog handle
# (0 = unknown: the box is looked up under the IDE main window), main window handle (0 =
# unknown), answer Ok|Yes|No|Cancel|Close. Emits ONE PSCustomObject
# @{ Sent; Method; Reason; AutomationId; Name }.
# Button choice: AutomationId OKButton / YesButton / NoButton / CancelButton first, else the
# caption (OK / Yes / No / Cancel or the zh-TW captions, written as \u escapes: ASCII file).
# Close: WindowPattern.Close().
$script:TcUiaMessageBoxAnswer = {
    param([int]$TargetPid, [long]$Hwnd, [long]$MainHwnd, [string]$Answer)

    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $ae = [System.Windows.Automation.AutomationElement]
    $scope = [System.Windows.Automation.TreeScope]
    $vsMbId = 'Microsoft.VisualStudio.MessageBox'
    $res = [PSCustomObject]@{ Sent = $false; Method = $null; Reason = $null; AutomationId = $null; Name = $null }

    $box = $null
    if ($Hwnd -ne 0) {
        try { $box = $ae::FromHandle([IntPtr]$Hwnd) } catch { $box = $null }
    }
    if ($null -eq $box) {
        $vsMbCond = New-Object System.Windows.Automation.PropertyCondition($ae::AutomationIdProperty, $vsMbId)
        $pidCond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
        # The pid's top-level windows through the modal scan's EnumWindows helper when it is
        # loaded (it is after any Find-TcIdeModalDialog in this process): RootElement.FindAll
        # stalls ~3 s on unresponsive windows of other processes (#24, Find-TcIdeModalDialog.ps1).
        if (([System.Management.Automation.PSTypeName]'TcAutomation.UiaScanWindows').Type) {
            $windows = New-Object System.Collections.ArrayList
            foreach ($wh in [TcAutomation.UiaScanWindows]::TopLevelOf([uint32]$TargetPid)) {
                try { $we = $ae::FromHandle($wh); if ($null -ne $we) { $null = $windows.Add($we) } } catch { }
            }
        }
        else {
            $windows = $ae::RootElement.FindAll($scope::Children, $pidCond)
        }
        $main = $null
        foreach ($w in $windows) {
            try {
                $aid = [string]$w.Current.AutomationId
                if ($aid -eq $vsMbId) { $box = $w; break }
                if ($null -eq $main -and $aid -eq 'VisualStudioMainWindow') { $main = $w }
            }
            catch { }
        }
        if ($null -eq $box -and $MainHwnd -ne 0) {
            try { $main = $ae::FromHandle([IntPtr]$MainHwnd) } catch { }
        }
        if ($null -eq $box -and $null -ne $main) {
            try { $box = $main.FindFirst($scope::Descendants, $vsMbCond) } catch { $box = $null }
        }
    }
    if ($null -eq $box) { $res.Reason = 'message box not found through UI Automation'; return $res }
    try {
        if ([int]$box.Current.ProcessId -ne $TargetPid) {
            $res.Reason = "UIA element belongs to pid $($box.Current.ProcessId), not the IDE pid $TargetPid"
            return $res
        }
    }
    catch { $res.Reason = "UIA element not readable: $($_.Exception.Message)"; return $res }

    if ($Answer -eq 'Close') {
        try {
            $wp = $null
            if ($box.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp) -and $null -ne $wp) {
                $wp.Close()
                $res.Sent = $true; $res.Method = 'UIA_CLOSE'; $res.Reason = 'WindowPattern.Close() called'
            }
            else { $res.Reason = 'message box has no WindowPattern' }
        }
        catch { $res.Reason = "WindowPattern.Close() failed: $($_.Exception.Message)" }
        return $res
    }

    $aidMap = @{ Ok = 'OKButton'; Yes = 'YesButton'; No = 'NoButton'; Cancel = 'CancelButton' }
    # zh-TW captions: OK = U+78BA U+5B9A, Yes = U+662F, No = U+5426, Cancel = U+53D6 U+6D88
    $nameMap = @{
        Ok     = '^(OK|\u78BA\u5B9A)$'
        Yes    = '^(Yes|\u662F)$'
        No     = '^(No|\u5426)$'
        Cancel = '^(Cancel|\u53D6\u6D88)$'
    }
    $wantAid = [string]$aidMap[$Answer]
    $wantName = [string]$nameMap[$Answer]
    if ([string]::IsNullOrWhiteSpace($wantAid)) { $res.Reason = "unsupported answer '$Answer'"; return $res }

    $btnCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
    $buttons = @()
    try { $buttons = @($box.FindAll($scope::Descendants, $btnCond)) } catch { $buttons = @() }
    $target = $null
    foreach ($b in $buttons) {
        try { if ([string]$b.Current.AutomationId -eq $wantAid) { $target = $b; break } } catch { }
    }
    if ($null -eq $target) {
        foreach ($b in $buttons) {
            $n = ''
            try { $n = [string]$b.Current.Name } catch { continue }
            # accelerators: '&OK', 'Yes(&Y)' / zh-TW '(Y)' suffixes
            $n = ($n -replace '&', '' -replace '\s*\([A-Za-z]\)\s*$', '').Trim()
            if ($n -match $wantName) { $target = $b; break }
        }
    }
    if ($null -eq $target) {
        $seen = @($buttons | ForEach-Object { try { "$($_.Current.AutomationId)/$($_.Current.Name)" } catch { '?' } }) -join ', '
        $res.Reason = "no '$Answer' button (AutomationId $wantAid) in the message box; buttons: $seen"
        return $res
    }
    try { $res.AutomationId = [string]$target.Current.AutomationId; $res.Name = [string]$target.Current.Name } catch { }
    try {
        $ip = $null
        if (-not ($target.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) -or $null -eq $ip) {
            $res.Reason = "button '$($res.AutomationId)' has no InvokePattern"
            return $res
        }
        $ip.Invoke()
        $res.Sent = $true; $res.Method = 'UIA_INVOKE'; $res.Reason = "InvokePattern.Invoke() on button '$($res.AutomationId)' ($($res.Name))"
    }
    catch { $res.Reason = "InvokePattern.Invoke() failed: $($_.Exception.Message)" }
    return $res
}

function Invoke-TcMessageBoxUia {
    <#
    .SYNOPSIS
        Runs $script:TcUiaMessageBoxAnswer in a new STA runspace with a hard timeout (UIA can
        block on a busy IDE). Returns its result object, or @{ Sent = $false; Reason } on
        timeout / failure. Never throws.
    #>
    [CmdletBinding()]
    param(
        [int]$ProcessId,
        [long]$Hwnd,
        [string]$Answer,
        [int]$TimeoutSec = 10
    )
    $fail = [PSCustomObject]@{ Sent = $false; Method = $null; Reason = $null; AutomationId = $null; Name = $null }
    $mainHwnd = [long]0
    if ($null -ne $script:TcIdeMainHwnd -and $null -ne $script:TcIdeProcessId -and $ProcessId -eq [int]$script:TcIdeProcessId) {
        try { $mainHwnd = [long]$script:TcIdeMainHwnd } catch { $mainHwnd = 0 }
    }
    if ($mainHwnd -eq 0) {
        try { $mainHwnd = [long](Get-Process -Id $ProcessId -ErrorAction Stop).MainWindowHandle } catch { $mainHwnd = 0 }
    }
    $ps = $null
    $rs = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($script:TcUiaMessageBoxAnswer.ToString()).AddArgument($ProcessId).AddArgument($Hwnd).AddArgument($mainHwnd).AddArgument($Answer)
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
            try { $null = $ps.BeginStop($null, $null) } catch { }
            $ps = $null
            $rs = $null
            $fail.Reason = "UI Automation answer did not finish within $TimeoutSec s"
            return $fail
        }
        $out = $ps.EndInvoke($handle)
        if ($null -ne $out -and $out.Count -gt 0 -and $null -ne $out[0]) { return $out[0] }
        $fail.Reason = 'UI Automation answer returned nothing'
        if ($ps.Streams.Error.Count -gt 0) { $fail.Reason += ": $($ps.Streams.Error[0])" }
        return $fail
    }
    catch {
        $fail.Reason = "UI Automation answer failed: $($_.Exception.Message)"
        return $fail
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        if ($null -ne $rs) { try { $rs.Dispose() } catch { } }
    }
}

function Close-TcMessageBox {
    <#
    .SYNOPSIS
        Answers a Win32 message box (#32770) of the connected IDE by DIALOG CONTROL ID, so it
        works on any UI language.
    .DESCRIPTION
        -Answer Yes|No|Ok|Cancel|Reload clicks the button with control id IDYES 6 / IDNO 7 / IDOK 1 /
        IDCANCEL 2 / Reload 259: GetDlgItem(hwnd, id), then BM_CLICK (0x00F5) through SendMessageTimeout
        (SMTO_ABORTIFHUNG, 5000 ms; a plain SendMessage would hang when the dialog thread is
        busy). A processed BM_CLICK is not proof of a click: "If the button is in a dialog box
        and the dialog box is not active, the BM_CLICK message might fail"
        (https://learn.microsoft.com/en-us/windows/win32/controls/bm-click). #64 (CI run
        40185005290) only showed that the send succeeded and the fixture host never printed
        its answer; that the dialog stayed open is an inference from those remarks, not
        observed. So the dialog handle is polled for up to 2 s afterwards; when it still exists,
        or when the send itself fails / times out, WM_COMMAND (0x0111) with wParam =
        MAKEWPARAM(id, BN_CLICKED 0) = id and lParam = the button handle (the notification a
        real click sends to the dialog) is posted instead, and the handle is polled again for
        2 s (Closed). Before posting, on both paths (send processed or timed out): a dialog that
        is disabled or has an enabled popup (the Yes handler of a custom #32770 dialog opened a
        nested modal: the click did land, and its synchronous BN_CLICKED is what made the send
        time out) gets no WM_COMMAND: Sent = true, Method BM_CLICK, Closed = false. A dialog
        that is gone (before posting, or PostMessage failed because it closed meanwhile) is
        Sent = true, Method BM_CLICK, Closed = true only after a PROCESSED BM_CLICK; after a
        send that timed out nobody knows who closed it (user, XAE, hung thread): Sent = false,
        Reason 'dialog already gone' (Close-TcReloadPrompt: Dismissed, not answered). A
        dialog without that control id (a WPF window such as the VS2022 message box,
        AutomationId 'Microsoft.VisualStudio.MessageBox', 2026-10-21) is answered through UI
        Automation instead: the Button with AutomationId OKButton / YesButton / NoButton /
        CancelButton (second choice: the caption OK / Yes / No / Cancel or its zh-TW text) gets
        InvokePattern.Invoke() (Method 'UIA_INVOKE'; runs in an STA runspace, 10 s timeout).
        Only when that also fails the result is Sent = false ('control id N not found ...').
        -Answer Close (default) posts WM_CLOSE (0x0010), i.e. the title-bar X (= Cancel / No).
        -Hwnd 0 (dialog handle unknown): the VS2022 message box is looked up by AutomationId
        under the IDE main window and answered through UI Automation (Close =
        WindowPattern.Close(), Method 'UIA_CLOSE').

        For #32770 boxes captions and UIA names are never used: on a zh-TW Windows the XAE message box buttons
        are UIA ControlType.Pane named with localized captions, AutomationId 6 / 7 (= IDYES /
        IDNO); only the control id is stable.

        The window must belong to the IDE process (-ProcessId, default $script:TcIdeProcessId);
        any other window is refused. Apart from the 2 s checks of the control-id path above it
        does not wait for the dialog to close (Close-TcReloadPrompt polls).
    .PARAMETER Hwnd
        Native handle of the dialog (Find-TcIdeModalDialog .Hwnd).
    .PARAMETER Answer
        Yes | No | Ok | Cancel | Reload | Close. Default Close. Reload = control id 259, the
        Reload (&R) button of the VS2022 solution reload prompt (#106; measured 2026-11-03,
        VS2022 zh-TW; TcXaeShell and other languages not verified). The UI Automation fallback
        has no mapping for Reload: a dialog without control 259 gives Sent = false.
    .PARAMETER ProcessId
        Process that must own the window. Default: $script:TcIdeProcessId.
    .OUTPUTS
        Hashtable @{ Sent = [bool]; Method = 'BM_CLICK' | 'WM_COMMAND' | 'WM_CLOSE' | 'UIA_INVOKE' | 'UIA_CLOSE' | $null;
        ControlId = [int]; Reason = [string]; Closed = [bool] or $null; BmClick; WmCommand }. Closed
        (control-id path only, else $null): the dialog handle was gone within the 2 s check after
        the last send. Diagnostics of the control-id path ($null on every other path):
          BmClick   'closed' (processed, dialog gone within 2 s) | 'processed-still-open' |
                    'timeout' (SendMessageTimeout failed or timed out)
          WmCommand 'not-needed' (BM_CLICK closed it, or it was gone before posting) |
                    'not-posted-disabled' (dialog disabled / nested modal) | 'posted-closed' |
                    'posted-still-open' | 'post-failed' (PostMessage failed)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [IntPtr]$Hwnd,

        [Parameter()]
        [ValidateSet('Yes', 'No', 'Ok', 'Cancel', 'Reload', 'Close')]
        [string]$Answer = 'Close',

        [Parameter()]
        [int]$ProcessId = 0
    )

    $result = @{ Sent = $false; Method = $null; ControlId = 0; Reason = $null; Closed = $null; BmClick = $null; WmCommand = $null }

    if ($ProcessId -le 0 -and $null -ne $script:TcIdeProcessId) {
        try { $ProcessId = [int]$script:TcIdeProcessId } catch { $ProcessId = 0 }
    }
    if ($Hwnd -eq [IntPtr]::Zero) {
        if ($ProcessId -le 0) { $result.Reason = 'dialog window handle unknown'; return $result }
        # No handle (the VS2022 WPF message box is sometimes reported with Hwnd 0): look it up
        # by AutomationId under the IDE main window and answer it through UI Automation.
        $uia = Invoke-TcMessageBoxUia -ProcessId $ProcessId -Hwnd 0 -Answer $Answer
        $result.Sent = [bool]$uia.Sent
        $result.Method = $uia.Method
        $result.Reason = if ($uia.Sent) { [string]$uia.Reason } else { "dialog window handle unknown; UI Automation fallback: $($uia.Reason)" }
        Write-Verbose "Close-TcMessageBox: $($result.Reason) (no hwnd, pid $ProcessId)."
        return $result
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

    # Reload = 259: the VS2022 solution reload prompt (#106, measured 2026-11-03 VS2022 zh-TW:
    # 259 = Reload (&R), 1412 = Ignore (&I); TcXaeShell / other languages not verified).
    $ids = @{ Ok = 1; Cancel = 2; Yes = 6; No = 7; Reload = 259 }
    $id = [int]$ids[$Answer]
    $result.ControlId = $id

    $hBtn = $native::GetDlgItem($Hwnd, $id)
    if ($hBtn -eq [IntPtr]::Zero) {
        # No Win32 control with that id: a WPF dialog such as the VS2022 message box
        # (AutomationId 'Microsoft.VisualStudio.MessageBox'). Fall back to UI Automation:
        # the button by AutomationId (OKButton / YesButton / NoButton / CancelButton), else
        # by caption, then InvokePattern.Invoke().
        $uia = Invoke-TcMessageBoxUia -ProcessId $ProcessId -Hwnd ([long]$Hwnd) -Answer $Answer
        if ($uia.Sent) {
            $result.Sent = $true; $result.Method = $uia.Method; $result.Reason = [string]$uia.Reason
        }
        else {
            $result.Reason = "control id $id ($Answer) not found in the dialog; UI Automation fallback: $($uia.Reason)"
        }
        Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd)."
        return $result
    }
    $BM_CLICK = [uint32]0x00F5
    $SMTO_ABORTIFHUNG = [uint32]0x0002
    $smResult = [IntPtr]::Zero
    $ret = $native::SendMessageTimeout($hBtn, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero, $SMTO_ABORTIFHUNG, [uint32]5000, [ref]$smResult)
    $why = $null
    if ($ret -ne [IntPtr]::Zero) {
        # Processed is not clicked (BM_CLICK docs, #64): the answer counts once the dialog is gone.
        if (Wait-TcDialogGone -Native $native -Hwnd $Hwnd -TimeoutMs 2000) {
            $result.BmClick = 'closed'; $result.WmCommand = 'not-needed'
            $result.Sent = $true; $result.Method = 'BM_CLICK'; $result.Closed = $true; $result.Reason = "BM_CLICK sent to control $id ($Answer)"
            Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd, pid $ProcessId)."
            return $result
        }
        $why = "BM_CLICK to control $id was processed but the dialog was still open 2000 ms later (BM_CLICK can fail on a dialog that is not active)"
        $result.BmClick = 'processed-still-open'
    }
    else {
        # Timed out / hung: the click may still be processed; fall back to the posted command.
        $why = "SendMessageTimeout BM_CLICK to control $id failed or timed out"
        $result.BmClick = 'timeout'
    }
    # Both paths (#64 review S2 / round 2 M1): BM_CLICK processed but the dialog still open, AND a
    # send that timed out. A Yes handler of a custom #32770 dialog that opens a nested modal keeps
    # the synchronous BN_CLICKED from returning, so the send times out although the click landed.
    # The dialog is then disabled (the nested modal owns it) or has an enabled popup: posting
    # WM_COMMAND would answer a second time, re-entrantly. Not posted then.
    # Dialog gone: only a PROCESSED BM_CLICK may count as our answer. After a send that timed out
    # (#64 review round 3 M2) the dialog may have been closed by anything (the user pressed No,
    # XAE closed it, the thread was hung): reported like a dialog that was already gone, the
    # string Close-TcReloadPrompt recognizes (Dismissed, not answered).
    if (-not $native::IsWindow($Hwnd)) {
        $result.WmCommand = 'not-needed'   # gone before posting
        if ($ret -ne [IntPtr]::Zero) {
            $result.Sent = $true; $result.Method = 'BM_CLICK'; $result.Closed = $true
            $result.Reason = "BM_CLICK sent to control $id ($Answer); the dialog closed after the 2000 ms check"
        }
        else {
            $result.Sent = $false; $result.Closed = $true
            $result.Reason = 'dialog already gone'
        }
        Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd, pid $ProcessId; $why)."
        return $result
    }
    $state = [TcAutomation.MessageBoxState]
    $GW_ENABLEDPOPUP = [uint32]6
    # GetWindow(GW_ENABLEDPOPUP) returns the window itself when it has no enabled popup
    # (https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-getwindow);
    # measured 0 instead (2026-11-05, Windows 11 26200, PS 5.1): both mean "no popup".
    $popup = $state::GetWindow($Hwnd, $GW_ENABLEDPOPUP)
    if (-not $state::IsWindowEnabled($Hwnd) -or ($popup -ne [IntPtr]::Zero -and $popup -ne $Hwnd)) {
        $result.Sent = $true; $result.Method = 'BM_CLICK'; $result.Closed = $false; $result.WmCommand = 'not-posted-disabled'
        $sendState = if ($ret -ne [IntPtr]::Zero) { 'send processed' } else { 'send timed out' }
        $result.Reason = "BM_CLICK to control $id ($Answer): $sendState ($why); dialog disabled / nested modal, WM_COMMAND not posted"
        Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd, pid $ProcessId)."
        return $result
    }
    Write-Verbose "Close-TcMessageBox: $why; posting WM_COMMAND."

    $WM_COMMAND = [uint32]0x0111
    # MAKEWPARAM(id, BN_CLICKED = 0) = id; lParam = the button handle. For a MessageBox a second
    # answer to a box that is already closing is harmless: the same id ends the same box (the
    # nested-modal case of custom dialogs is excluded above).
    if ($native::PostMessage($Hwnd, $WM_COMMAND, [IntPtr]$id, $hBtn)) {
        $result.Sent = $true; $result.Method = 'WM_COMMAND'
        $result.Closed = Wait-TcDialogGone -Native $native -Hwnd $Hwnd -TimeoutMs 2000
        $result.WmCommand = if ($result.Closed) { 'posted-closed' } else { 'posted-still-open' }
        $result.Reason = "$why; WM_COMMAND $id ($Answer) posted"
    }
    elseif (-not $native::IsWindow($Hwnd)) {
        # The dialog closed in the meantime. A processed BM_CLICK took effect late (#64 review S1);
        # after a timed-out send nobody knows who closed it (round 3 M2).
        $result.Closed = $true
        $result.WmCommand = 'post-failed'
        if ($ret -ne [IntPtr]::Zero) {
            $result.Sent = $true; $result.Method = 'BM_CLICK'
            $result.Reason = "BM_CLICK sent to control $id ($Answer); the dialog closed after the 2000 ms check"
        }
        else { $result.Reason = 'dialog already gone' }
    }
    else { $result.WmCommand = 'post-failed'; $result.Reason = "$why; PostMessage WM_COMMAND $id failed" }
    Write-Verbose "Close-TcMessageBox: $($result.Reason) (hwnd $Hwnd, pid $ProcessId, closed $($result.Closed))."
    return $result
}

# true once the dialog handle no longer exists (polled every 50 ms up to -TimeoutMs).
function Wait-TcDialogGone {
    [CmdletBinding()]
    param($Native, [IntPtr]$Hwnd, [int]$TimeoutMs = 2000)
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Native::IsWindow($Hwnd)) {
        if ($sw.ElapsedMilliseconds -ge $TimeoutMs) { return $false }
        Start-Sleep -Milliseconds 50
    }
    return $true
}
