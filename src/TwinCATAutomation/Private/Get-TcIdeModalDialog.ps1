# UI Automation scan that runs INSIDE a separate runspace (see Get-TcIdeModalDialog and
# the watchdog in Invoke-TcComRetry). It must be self-contained: no module functions,
# no $script: state. Arguments: target process id, main window handle (0 = unknown),
# max text length. Emits one PSCustomObject @{ Title; Text; ClassName; IsModal; Hwnd; Buttons }
# for the first dialog found, or nothing. Buttons (added 2026-10-20, additive) lists the
# Win32 'Button' child windows of a #32770 dialog as @{ Id = <control id>; Name = <caption> }
# (empty for any other window): the control id (IDOK 1, IDCANCEL 2, IDYES 6, IDNO 7 ...) is
# what Close-TcMessageBox clicks; the caption is localized (zh-TW XAE: '&Y' style captions).
# The VS2022 WPF message box (AutomationId 'Microsoft.VisualStudio.MessageBox', checked before
# every other heuristic) is reported with ClassName 'Microsoft.VisualStudio.MessageBox', Text =
# its 'Text' element, Buttons = @{ Id = 0; Name; AutomationId } (no Win32 control ids).
#
# Heuristics (a modal dialog blocks every DTE call, so this must be cheap and safe):
#   - only top-level windows of the IDE process (TreeScope Children + ProcessIdProperty)
#   - the main window is excluded by handle when known, otherwise by title
#     ("<solution> - TcXaeShell", "<solution> - Microsoft Visual Studio", with an
#     optional " (Administrator)" suffix)
#   - windows reporting WindowPattern.IsModal win; otherwise a Win32 dialog (#32770)
#     or a title matching the known dialogs (Assertion Failed, account settings,
#     fatal error, license security code) is accepted; floating tool windows are not.
#   - a dialog OWNED by the main window (MessageBox(owner, ...), Help.About) is a UIA child
#     of the main window, not of the desktop: when nothing was found at top level, the main
#     window's direct Window children are checked. IsModal / #32770 children always count;
#     a known title or any other owned window only while the main window is blocked
#     (IsEnabled false, or WindowInteractionState BlockedByModalWindow - the WPF XAE main
#     window stays IsEnabled while modal).
#   - the title is the Win32 caption (GetWindowText) when it differs from the UIA Name (a
#     WPF window's Name can be its content text), cut at 200 chars.
#   - the dialog text is read from Text descendants; when there are none (Win11 message
#     boxes expose the body as Pane/Static and the buttons as Pane/Button) it falls back
#     to Pane / Edit / Document descendants, skipping buttons and the title.
# mcp-server/bridge/modal-probe.ps1 dot-sources this file and runs this same scriptblock
# (-ScanScript), so its parameter list and output shape are a contract.
$script:TcUiaDialogScan = {
    param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText)

    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

    $ae = [System.Windows.Automation.AutomationElement]
    # Top-level windows of the pid: EnumWindows + GetWindowThreadProcessId (no window messages),
    # then AutomationElement.FromHandle per window. RootElement.FindAll(Children, ProcessId)
    # queries every top-level window on the desktop and stalls when a window of ANY other
    # process does not answer: measured 2026-10-25 (Windows 11, fixtures/host-window.ps1 while
    # npm test ran): FindAll 25-50 ms with stalls of ~3000 ms every few seconds, EnumWindows +
    # FromHandle 1-17 ms throughout (#24). Invisible windows, and windows owned by a visible
    # window, are skipped as on the UIA desktop level (UIA lists those under their owner; measured, not documented: the MessageBox(owner) of fixtures/host-window.ps1 is a UIA child of its form, see mcp-server/bridge/modal-probe.ps1). A
    # window whose owner is hidden is kept: skipping every owned window lost the main windows
    # of fixtures/host-window.ps1 and host-window-wpf.ps1 (measured 2026-10-25).
    if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.UiaScanWindows').Type) {
        Add-Type -Namespace TcAutomation -Name UiaScanWindows -MemberDefinition @'
public delegate bool EnumProc(System.IntPtr hWnd, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool EnumWindows(EnumProc callback, System.IntPtr lParam);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern uint GetWindowThreadProcessId(System.IntPtr hWnd, out uint processId);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr hWnd, uint cmd);
public static System.Collections.Generic.List<System.IntPtr> TopLevelOf(uint targetPid) {
    var list = new System.Collections.Generic.List<System.IntPtr>();
    EnumWindows(delegate (System.IntPtr h, System.IntPtr l) {
        uint p;
        GetWindowThreadProcessId(h, out p);
        if (p != targetPid || !IsWindowVisible(h)) { return true; }
        System.IntPtr owner = GetWindow(h, 4);  // GW_OWNER
        if (owner == System.IntPtr.Zero || !IsWindowVisible(owner)) { list.Add(h); }
        return true;
    }, System.IntPtr.Zero);
    return list;
}
'@ -ErrorAction Stop
    }
    $windows = New-Object System.Collections.ArrayList
    foreach ($wh in [TcAutomation.UiaScanWindows]::TopLevelOf([uint32]$TargetPid)) {
        try {
            $we = $ae::FromHandle($wh)
            if ($null -ne $we) { $null = $windows.Add($we) }
        }
        catch { }
    }
    if ($windows.Count -eq 0) { return }

    # Win32 caption of a window (GetWindowText). The UIA Name of a WPF window can be its
    # content text instead of its title, so the caption is used where the title matters.
    # The P/Invoke type is compiled once per process and only when first needed.
    function Get-TcScanCaption([long]$h) {
        if ($h -le 0) { return '' }
        try {
            if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.UiaScanNative').Type) {
                Add-Type -Namespace TcAutomation -Name UiaScanNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
'@ -ErrorAction Stop
            }
            $csb = New-Object System.Text.StringBuilder 1024
            $null = [TcAutomation.UiaScanNative]::GetWindowText([IntPtr]$h, $csb, $csb.Capacity)
            return $csb.ToString().Trim()
        }
        catch { return '' }
    }

    # Win32 'Button' children of a #32770 dialog: @(@{ Id; Name }). Language independent by
    # design: the id is the dialog control id (GetDlgCtrlID), the name only informational.
    function Get-TcScanButtons([long]$h) {
        $list = New-Object System.Collections.ArrayList
        if ($h -le 0) { return ,$list }
        try {
            if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.UiaScanButtonNative').Type) {
                Add-Type -Namespace TcAutomation -Name UiaScanButtonNative -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern int GetClassName(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern System.IntPtr GetWindow(System.IntPtr hWnd, uint cmd);
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern int GetDlgCtrlID(System.IntPtr hWnd);
'@ -ErrorAction Stop
            }
            $native = [TcAutomation.UiaScanButtonNative]
            $child = $native::GetWindow([IntPtr]$h, 5)   # GW_CHILD
            $guard = 0
            while ($child -ne [IntPtr]::Zero -and $guard -lt 64) {
                $guard++
                $csb = New-Object System.Text.StringBuilder 256
                $null = $native::GetClassName($child, $csb, $csb.Capacity)
                if ($csb.ToString() -eq 'Button') {
                    $tsb = New-Object System.Text.StringBuilder 256
                    $null = $native::GetWindowText($child, $tsb, $tsb.Capacity)
                    $null = $list.Add(@{ Id = [int]$native::GetDlgCtrlID($child); Name = $tsb.ToString() })
                }
                $child = $native::GetWindow($child, 2)   # GW_HWNDNEXT
            }
        }
        catch { }
        return ,$list
    }

    $mainTitlePattern = '(^|\s-\s)(TcXaeShell|Microsoft Visual Studio)(\s+\(.+\))?$'
    # ASCII only (file has no BOM): localized titles are caught by IsModal / #32770.
    $knownDialogPattern = '(?i)Assertion Failed|Account Settings|fatal error|Security Code|License|Lizenz|TwinCAT XAE|Microsoft Visual Studio'

    # --- VS2022 WPF message box (checked FIRST) ---
    # Measured 2026-10-21 (XAE 4026.22 in VS2022 zh-TW, the "Active solution platform ...
    # differs from current target platform" box): ControlType.Window, ClassName 'Window',
    # AutomationId 'Microsoft.VisualStudio.MessageBox', Name 'Microsoft Visual Studio'. Found
    # under the IDE main window element (AutomationId 'VisualStudioMainWindow'), sometimes also
    # as a top-level window of the process. Children: Image 'Image', Edit (TextBox)
    # AutomationId 'Text' whose Name and Value are the full message, Button(s) AutomationId
    # 'OKButton' / 'YesButton' / 'NoButton' / 'CancelButton' with a Text child carrying the
    # localized caption. The generic branches below would only report the caption ('OK' in the
    # local language) as text and no buttons: the buttons have no Win32 control id, so they are
    # listed as @{ Id = 0; Name; AutomationId } (Close-TcMessageBox invokes them through UIA).
    $vsMbId = 'Microsoft.VisualStudio.MessageBox'
    $vsMbCond = New-Object System.Windows.Automation.PropertyCondition($ae::AutomationIdProperty, $vsMbId)
    $vsMb = $null
    foreach ($w in $windows) {
        try {
            if ([string]$w.Current.AutomationId -eq $vsMbId -and -not $w.Current.IsOffscreen) { $vsMb = $w; break }
        }
        catch { }
    }
    if ($null -eq $vsMb) {
        $vsMain = $null
        if ($MainHwnd -ne 0) {
            try {
                $vsMain = $ae::FromHandle([IntPtr]$MainHwnd)
                if ($null -ne $vsMain -and [int]$vsMain.Current.ProcessId -ne $TargetPid) { $vsMain = $null }
            }
            catch { $vsMain = $null }
        }
        if ($null -eq $vsMain) {
            foreach ($w in $windows) {
                try { if ([string]$w.Current.AutomationId -eq 'VisualStudioMainWindow') { $vsMain = $w; break } } catch { }
            }
        }
        if ($null -ne $vsMain) {
            try {
                # Cheap first: children and grandchildren of the main window.
                $vsMb = $vsMain.FindFirst([System.Windows.Automation.TreeScope]::Children, $vsMbCond)
                if ($null -eq $vsMb) {
                    foreach ($ch in $vsMain.FindAll([System.Windows.Automation.TreeScope]::Children, [System.Windows.Automation.Condition]::TrueCondition)) {
                        $vsMb = $ch.FindFirst([System.Windows.Automation.TreeScope]::Children, $vsMbCond)
                        if ($null -ne $vsMb) { break }
                    }
                }
                if ($null -eq $vsMb) {
                    # Full descendant search only while the main window looks blocked (a full
                    # search of the VS2022 tree is slow and this scan runs every 2 s).
                    $vsBlocked = $false
                    try { $vsBlocked = -not [bool]$vsMain.Current.IsEnabled } catch { }
                    if (-not $vsBlocked) {
                        try {
                            $vwp = $null
                            if ($vsMain.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$vwp) -and $null -ne $vwp) {
                                $vsBlocked = ($vwp.Current.WindowInteractionState -eq [System.Windows.Automation.WindowInteractionState]::BlockedByModalWindow)
                            }
                        }
                        catch { }
                    }
                    if ($vsBlocked) { $vsMb = $vsMain.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $vsMbCond) }
                }
            }
            catch { $vsMb = $null }
        }
    }
    if ($null -ne $vsMb) {
        $mbTitle = ''
        $mbHwnd = [long]0
        try { $mbTitle = [string]$vsMb.Current.Name } catch { }
        try { $mbHwnd = [long]$vsMb.Current.NativeWindowHandle } catch { $mbHwnd = 0 }
        if ([string]::IsNullOrWhiteSpace($mbTitle)) { $mbTitle = 'Microsoft Visual Studio' }
        if ($mbTitle.Length -gt 200) { $mbTitle = $mbTitle.Substring(0, 200) }
        $mbText = ''
        try {
            $txtEl = $vsMb.FindFirst([System.Windows.Automation.TreeScope]::Descendants,
                (New-Object System.Windows.Automation.PropertyCondition($ae::AutomationIdProperty, 'Text')))
            if ($null -ne $txtEl) {
                try { $mbText = [string]$txtEl.Current.Name } catch { $mbText = '' }
                if ([string]::IsNullOrWhiteSpace($mbText)) {
                    $vp = $null
                    if ($txtEl.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern, [ref]$vp) -and $null -ne $vp) { $mbText = [string]$vp.Current.Value }
                }
            }
        }
        catch { }
        if ($null -eq $mbText) { $mbText = '' }
        $mbText = $mbText.Trim()
        if ($mbText.Length -gt $MaxText) { $mbText = $mbText.Substring(0, $MaxText) }
        $mbButtons = New-Object System.Collections.ArrayList
        try {
            $mbBtnCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Button)
            foreach ($b in $vsMb.FindAll([System.Windows.Automation.TreeScope]::Descendants, $mbBtnCond)) {
                $bn = ''
                $ba = ''
                try { $bn = [string]$b.Current.Name; $ba = [string]$b.Current.AutomationId } catch { continue }
                $null = $mbButtons.Add(@{ Id = 0; Name = $bn; AutomationId = $ba })
            }
        }
        catch { }
        # Shown with ShowDialog by VS: always modal (blocks every DTE call).
        return [PSCustomObject]@{
            Title     = $mbTitle
            Text      = $mbText
            ClassName = $vsMbId
            IsModal   = $true
            Hwnd      = $mbHwnd
            Buttons   = @($mbButtons)
        }
    }

    $modalHit = $null
    $fallbackHit = $null
    $mainEl = $null
    foreach ($w in $windows) {
        $cur = $null
        try { $cur = $w.Current } catch { continue }
        $name = [string]$cur.Name
        $className = [string]$cur.ClassName
        $hwnd = [long]$cur.NativeWindowHandle
        if ($cur.ControlType -ne [System.Windows.Automation.ControlType]::Window) { continue }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($MainHwnd -ne 0 -and $hwnd -eq $MainHwnd) { $mainEl = $w; continue }
        if ($MainHwnd -eq 0 -and $name -match $mainTitlePattern -and $className -ne '#32770') {
            if ($null -eq $mainEl) { $mainEl = $w }
            continue
        }
        if ($cur.IsOffscreen) { continue }

        $isModal = $false
        try {
            $wp = $null
            if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp) -and $null -ne $wp) {
                $isModal = [bool]$wp.Current.IsModal
            }
        }
        catch { }

        $hit = [PSCustomObject]@{ Element = $w; Title = $name; ClassName = $className; IsModal = $isModal; Hwnd = $hwnd }
        if ($isModal) { $modalHit = $hit; break }
        if ($null -eq $fallbackHit -and ($className -eq '#32770' -or $name -match $knownDialogPattern)) { $fallbackHit = $hit }
    }

    $chosen = $modalHit
    if ($null -eq $chosen) { $chosen = $fallbackHit }

    if ($null -eq $mainEl -and $MainHwnd -eq 0) {
        # No main window by UIA Name: a WPF main window may expose its content text as Name,
        # so try the Win32 caption against the main-title pattern.
        foreach ($w in $windows) {
            $cur = $null
            try { $cur = $w.Current } catch { continue }
            if ($cur.ControlType -ne [System.Windows.Automation.ControlType]::Window -or [string]$cur.ClassName -eq '#32770') { continue }
            if ((Get-TcScanCaption ([long]$cur.NativeWindowHandle)) -match $mainTitlePattern) { $mainEl = $w; break }
        }
    }

    if ($null -eq $chosen) {
        # Owned dialog: UIA puts a window OWNED by the main window (MessageBox(owner, ...), VS
        # Help.About, Tools.Options) under the main window, not under the desktop, so the loop
        # above never sees it. An owned child that is IsModal or a #32770 always counts.
        # Whether the owner looks blocked depends on the framework: a WinForms owner reports
        # IsEnabled = false; the WPF XAE main window keeps IsEnabled = true (UIA shows the WPF
        # property, not the Win32 EnableWindow state) and reports
        # WindowPattern.WindowInteractionState = BlockedByModalWindow (Help.About on a real
        # XAE); a plain WPF owner behind ShowDialog() even stays Running. So "blocked" only
        # widens the match (known title, else any owned window); floating tool windows are
        # owned too and must not be reported while the owner is free.
        if ($null -eq $mainEl -and $MainHwnd -ne 0) {
            try {
                $mainEl = $ae::FromHandle([IntPtr]$MainHwnd)
                if ($null -ne $mainEl -and [int]$mainEl.Current.ProcessId -ne $TargetPid) { $mainEl = $null }
            }
            catch { $mainEl = $null }
        }
        if ($null -ne $mainEl) {
            $mainBlocked = $false
            try { $mainBlocked = -not [bool]$mainEl.Current.IsEnabled } catch { $mainBlocked = $false }
            if (-not $mainBlocked) {
                try {
                    $mwp = $null
                    if ($mainEl.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$mwp) -and $null -ne $mwp) {
                        $mainBlocked = ($mwp.Current.WindowInteractionState -eq [System.Windows.Automation.WindowInteractionState]::BlockedByModalWindow)
                    }
                }
                catch { }
            }
            try {
                $winCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)
                $ownedAny = $null
                foreach ($w in $mainEl.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)) {
                    $cur = $null
                    try { $cur = $w.Current } catch { continue }
                    $name = [string]$cur.Name
                    $className = [string]$cur.ClassName
                    if ([string]::IsNullOrWhiteSpace($name) -or $cur.IsOffscreen) { continue }
                    $isModal = $false
                    try {
                        $wp = $null
                        if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp) -and $null -ne $wp) {
                            $isModal = [bool]$wp.Current.IsModal
                        }
                    }
                    catch { }
                    $hit = [PSCustomObject]@{ Element = $w; Title = $name; ClassName = $className; IsModal = $isModal; Hwnd = [long]$cur.NativeWindowHandle }
                    if ($isModal -or $className -eq '#32770') { $chosen = $hit; break }
                    if ($mainBlocked -and $name -match $knownDialogPattern) { $chosen = $hit; break }
                    if ($mainBlocked -and $null -eq $ownedAny) { $ownedAny = $hit }
                }
                # The owner is blocked, so any remaining owned window is what blocks it.
                if ($null -eq $chosen) { $chosen = $ownedAny }
            }
            catch { }
        }
    }
    if ($null -eq $chosen) { return }

    # Title: the UIA Name of a WPF window is often its content text, not its caption (XAE
    # Help.About puts the whole About text there), so the Win32 caption is preferred; the
    # Name then serves as text when nothing else is collected. Titles are cut at 200 chars.
    $title = [string]$chosen.Title
    $nameAsText = ''
    $caption = Get-TcScanCaption ([long]$chosen.Hwnd)
    if (-not [string]::IsNullOrWhiteSpace($caption) -and $caption -ne $title) {
        $nameAsText = $title
        $title = $caption
    }
    if ($title.Length -gt 200) { $title = $title.Substring(0, 200) }

    # Collect visible text of the dialog (first $MaxText chars).
    $text = ''
    try {
        $textCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
        $texts = $chosen.Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond)
        $sb = New-Object System.Text.StringBuilder
        foreach ($t in $texts) {
            $tn = $null
            try { $tn = [string]$t.Current.Name } catch { $tn = $null }
            if ([string]::IsNullOrWhiteSpace($tn)) { continue }
            if ($sb.Length -gt 0) { $null = $sb.Append(' ') }
            $null = $sb.Append($tn.Trim())
            if ($sb.Length -ge $MaxText) { break }
        }
        if ($sb.Length -eq 0) {
            # Windows 11 message boxes (#32770, e.g. 'TwinCAT PLC Control') and some WinForms
            # dialogs expose the message as a Pane (ClassName 'Static') / Edit / Document, not
            # as Text. Buttons, the title bar and the title itself are skipped so the text
            # stays the message body.
            $all = $chosen.Element.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
            $bodyTypes = @([System.Windows.Automation.ControlType]::Pane, [System.Windows.Automation.ControlType]::Edit, [System.Windows.Automation.ControlType]::Document)
            # Buttons (OK / Abort / Retry ...) are exposed as Pane with ClassName 'Button' on such
            # dialogs; real Button elements are remembered by caption so a wrapping Pane is skipped too.
            $buttonNames = @{}
            foreach ($t in $all) {
                try { if ($t.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button) { $buttonNames[([string]$t.Current.Name).Trim()] = $true } } catch { }
            }
            foreach ($t in $all) {
                $tn = $null
                $tt = $null
                $tc = $null
                try { $tt = $t.Current.ControlType; $tn = [string]$t.Current.Name; $tc = [string]$t.Current.ClassName } catch { continue }
                if ($bodyTypes -notcontains $tt -or $tc -eq 'Button') { continue }
                if ([string]::IsNullOrWhiteSpace($tn) -or $tn.Trim() -eq $chosen.Title -or $buttonNames.ContainsKey($tn.Trim())) { continue }
                if ($sb.Length -gt 0) { $null = $sb.Append(' ') }
                $null = $sb.Append($tn.Trim())
                if ($sb.Length -ge $MaxText) { break }
            }
        }
        $text = $sb.ToString()
        if ([string]::IsNullOrWhiteSpace($text)) { $text = $nameAsText }
        if ($text.Length -gt $MaxText) { $text = $text.Substring(0, $MaxText) }
    }
    catch { }

    $buttons = @()
    if ([string]$chosen.ClassName -eq '#32770') { $btnList = Get-TcScanButtons ([long]$chosen.Hwnd); $buttons = @($btnList) }

    [PSCustomObject]@{
        Title     = $title
        Text      = $text
        ClassName = $chosen.ClassName
        IsModal   = $chosen.IsModal
        Hwnd      = $chosen.Hwnd
        Buttons   = $buttons
    }
}

# Dialog kinds (result field Kind, data.dialogKind in IDE_MODAL_DIALOG results):
#   reload-prompt  the VS shell prompt "File has been changed outside the environment. Reload
#                  the new file?" (VS2022 wording: "... changed outside the source editor. Do you
#                  want to reload it?"). A file that is open in a document window was changed
#                  on disk by another tool. 2026-10-20 reload-experiment (4024 32-bit XAE): it
#                  appears ~1 s after the write, blocks every DTE call, and the VS option
#                  AutoloadExternalChanges does not suppress it; a file that is NOT open is
#                  picked up silently within ~5 s. Hint: IDE_MODAL_DIALOG_RELOAD (dismiss it,
#                  then Reset-TcSolution = Solution.Close + Connect-TcIde reopen).
#                  ReloadTarget 'file'.
#                  Also the XAE project prompt "The project file '...\x.plcproj' has been
#                  modified outside of TwinCAT XAE. Do you want to reload the project?" (a
#                  .plcproj rewritten on disk, e.g. by a generator, even with identical
#                  content): same Kind, ReloadTarget 'project'. Reset-TcSolution answers Yes
#                  to it (Close-TcMessageBox -Answer Yes; XAE reloads the project itself).
#   unknown        everything else (hint IDE_MODAL_DIALOG), ReloadTarget $null.
# ConvertTo-TcAdsErrorCode uses the same pattern on error messages (the watchdog puts the
# dialog text into its IDE_MODAL_DIALOG exception).
$script:TcReloadPromptPattern = '(?i)changed outside the (environment|source editor)|Reload the new file|want to reload it|modified outside of TwinCAT XAE|want to reload the project'
# Subset of the pattern above that identifies the PROJECT (.plcproj) prompt.
$script:TcReloadProjectPattern = '(?i)modified outside of TwinCAT XAE|want to reload the project'

function Get-TcModalDialogKind {
    <#
    .SYNOPSIS
        Classifies a dialog by its title and text: 'reload-prompt' or 'unknown'.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Title = '',

        [Parameter()]
        [string]$Text = ''
    )
    if ("$Title $Text" -match $script:TcReloadPromptPattern) { return 'reload-prompt' }
    return 'unknown'
}

function Get-TcReloadTarget {
    <#
    .SYNOPSIS
        For a reload prompt: 'project' (XAE "project file ... modified outside of TwinCAT
        XAE. Do you want to reload the project?") or 'file' (VS "File has been changed
        outside the environment. Reload the new file?"); $null for any other dialog.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Title = '',

        [Parameter()]
        [string]$Text = ''
    )
    $all = "$Title $Text"
    if ($all -notmatch $script:TcReloadPromptPattern) { return $null }
    if ($all -match $script:TcReloadProjectPattern) { return 'project' }
    return 'file'
}

function Add-TcDialogKind {
    <#
    .SYNOPSIS
        Normalises a dialog record to @{ Title; Text; Kind; ReloadTarget; Hwnd; Buttons },
        classifying it when Kind / ReloadTarget are missing (the Invoke-TcComRetry watchdog
        runspace only produces the raw scan output).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object]$Dialog
    )
    if ($null -eq $Dialog) { return $null }
    $title = ''
    $text = ''
    $kind = ''
    if ($Dialog -is [System.Collections.IDictionary]) {
        $title = [string]$Dialog['Title']
        $text = [string]$Dialog['Text']
        if ($Dialog.Contains('Kind')) { $kind = [string]$Dialog['Kind'] }
    }
    else {
        try { $title = [string]$Dialog.Title } catch { $title = '' }
        try { $text = [string]$Dialog.Text } catch { $text = '' }
        $kp = $Dialog.PSObject.Properties['Kind']
        if ($null -ne $kp) { $kind = [string]$kp.Value }
    }
    if ([string]::IsNullOrWhiteSpace($kind)) { $kind = Get-TcModalDialogKind -Title $title -Text $text }
    $hwnd = [long]0
    try {
        if ($Dialog -is [System.Collections.IDictionary]) { if ($Dialog.Contains('Hwnd')) { $hwnd = [long]$Dialog['Hwnd'] } }
        else { $hp = $Dialog.PSObject.Properties['Hwnd']; if ($null -ne $hp) { $hwnd = [long]$hp.Value } }
    }
    catch { $hwnd = 0 }
    $target = $null
    $buttons = @()
    try {
        if ($Dialog -is [System.Collections.IDictionary]) {
            if ($Dialog.Contains('ReloadTarget')) { $target = $Dialog['ReloadTarget'] }
            if ($Dialog.Contains('Buttons') -and $null -ne $Dialog['Buttons']) { $buttons = @($Dialog['Buttons']) }
        }
        else {
            $tp = $Dialog.PSObject.Properties['ReloadTarget']; if ($null -ne $tp) { $target = $tp.Value }
            $bp = $Dialog.PSObject.Properties['Buttons']; if ($null -ne $bp -and $null -ne $bp.Value) { $buttons = @($bp.Value) }
        }
    }
    catch { $target = $null }
    if ([string]::IsNullOrWhiteSpace([string]$target)) {
        $target = if ($kind -eq 'reload-prompt') { Get-TcReloadTarget -Title $title -Text $text } else { $null }
        # Kind 'reload-prompt' given without a matching text (should not happen): assume the file prompt.
        if ($kind -eq 'reload-prompt' -and $null -eq $target) { $target = 'file' }
    }
    return @{ Title = $title; Text = $text; Kind = $kind; ReloadTarget = $target; Hwnd = $hwnd; Buttons = $buttons }
}

function ConvertTo-TcDialogButtonList {
    <#
    .SYNOPSIS
        Converts scan button records (@{ Id; Name } hashtables or objects) into
        [PSCustomObject]@{ id; name } for JSON output. Never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [AllowNull()]
        [object[]]$Buttons
    )
    $out = New-Object System.Collections.ArrayList
    foreach ($b in @($Buttons)) {
        if ($null -eq $b) { continue }
        $id = 0
        $name = ''
        $aid = ''
        try {
            if ($b -is [System.Collections.IDictionary]) {
                $id = [int]$b['Id']; $name = [string]$b['Name']
                if ($b.Contains('AutomationId')) { $aid = [string]$b['AutomationId'] }
            }
            else {
                $id = [int]$b.Id; $name = [string]$b.Name
                $ap = $b.PSObject.Properties['AutomationId']; if ($null -ne $ap) { $aid = [string]$ap.Value }
            }
        }
        catch { continue }
        $rec = [PSCustomObject][ordered]@{ id = $id; name = $name }
        # VS2022 WPF message box buttons have no control id (id 0): their UIA AutomationId
        # (OKButton / YesButton / NoButton / CancelButton) is added. #32770 buttons unchanged.
        if (-not [string]::IsNullOrWhiteSpace($aid)) { $rec | Add-Member -NotePropertyName 'automationId' -NotePropertyValue $aid }
        $null = $out.Add($rec)
    }
    return $out.ToArray()
}

function Get-TcIdeModalDialog {
    <#
    .SYNOPSIS
        Detects a modal dialog (Assertion Failed, VS account settings, fatal error,
        license prompt ...) in the connected IDE process via UI Automation.
    .DESCRIPTION
        Lists the top-level windows of the IDE process (default: $script:TcIdeProcessId
        stored by Connect-TcIde), excludes the main window and returns the first
        window that looks like a dialog as @{ Title; Text; Kind; ReloadTarget; Hwnd; Buttons }
        (Text = visible text, at most 500 chars; Kind = 'reload-prompt' for the VS
        "changed outside the environment / Reload the new file?" prompt (ReloadTarget
        'file') and for the XAE "project file ... modified outside of TwinCAT XAE. Do you
        want to reload the project?" prompt (ReloadTarget 'project'), else 'unknown' with
        ReloadTarget $null).
        Returns $null when the pid is unknown, the process does
        not exist, no dialog is open, or the scan does not finish within -TimeoutSec.

        The UI Automation calls run in a separate runspace with a hard timeout:
        while a modal dialog is up, UIA itself can block on the IDE's message loop.
        This function never throws.
    .PARAMETER ProcessId
        IDE process id. Default: $script:TcIdeProcessId.
    .PARAMETER TimeoutSec
        Maximum time for the UIA scan. Default 5.
    .OUTPUTS
        Hashtable @{ Title = [string]; Text = [string]; Kind = [string]; ReloadTarget = [string|$null];
        Hwnd = [long]; Buttons = @(@{ Id = [int]; Name = [string] }) } or $null
        (Hwnd = native window handle of the dialog, 0 when unknown; used by Close-TcReloadPrompt /
        Close-TcMessageBox. Buttons = Win32 button children of a #32770 message box, by control
        id: 1 OK, 2 Cancel, 6 Yes, 7 No; empty for other windows; for the VS2022 WPF message box
        @{ Id = 0; Name; AutomationId = 'OKButton' | 'YesButton' | ... }).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [int]$ProcessId = 0,

        [Parameter()]
        [ValidateRange(1, 60)]
        [int]$TimeoutSec = 5
    )

    if ($ProcessId -le 0 -and $null -ne $script:TcIdeProcessId) {
        try { $ProcessId = [int]$script:TcIdeProcessId } catch { $ProcessId = 0 }
    }
    if ($ProcessId -le 0) { return $null }

    $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $proc) {
        Write-Verbose "Get-TcIdeModalDialog: process $ProcessId not found."
        return $null
    }

    $mainHwnd = [long]0
    if ($null -ne $script:TcIdeMainHwnd -and $ProcessId -eq $script:TcIdeProcessId) {
        try { $mainHwnd = [long]$script:TcIdeMainHwnd } catch { $mainHwnd = 0 }
        if ($mainHwnd -eq 0) {
            # DTE.MainWindow.HWnd is often 0 right after launch; the process knows its main window by now.
            try { $mainHwnd = [long]$proc.MainWindowHandle } catch { $mainHwnd = 0 }
            if ($mainHwnd -ne 0) { $script:TcIdeMainHwnd = $mainHwnd }
        }
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
        $null = $ps.AddScript($script:TcUiaDialogScan.ToString()).AddArgument($ProcessId).AddArgument($mainHwnd).AddArgument(500)
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) {
            Write-Verbose "Get-TcIdeModalDialog: UIA scan of pid $ProcessId did not finish within $TimeoutSec s."
            # Do not block on Stop(): the scan thread may be stuck inside UIA. Leave it to die.
            try { $null = $ps.BeginStop($null, $null) } catch { }
            $ps = $null
            $rs = $null
            return $null
        }
        $out = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count -gt 0) {
            Write-Verbose "Get-TcIdeModalDialog: scan error: $($ps.Streams.Error[0])"
        }
        if ($null -eq $out -or $out.Count -eq 0) { return $null }
        $first = $out[0]
        if ($null -eq $first) { return $null }
        $title = [string]$first.Title
        if ([string]::IsNullOrWhiteSpace($title)) { return $null }
        $text = [string]$first.Text
        $hwnd = [long]0
        try { $hwnd = [long]$first.Hwnd } catch { $hwnd = 0 }
        $buttons = @()
        try { $bp = $first.PSObject.Properties['Buttons']; if ($null -ne $bp -and $null -ne $bp.Value) { $buttons = @($bp.Value) } } catch { $buttons = @() }
        return @{
            Title        = $title
            Text         = $text
            Kind         = (Get-TcModalDialogKind -Title $title -Text $text)
            ReloadTarget = (Get-TcReloadTarget -Title $title -Text $text)
            Hwnd         = $hwnd
            Buttons      = $buttons
        }
    }
    catch {
        Write-Verbose "Get-TcIdeModalDialog: $($_.Exception.Message)"
        return $null
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        if ($null -ne $rs) { try { $rs.Dispose() } catch { } }
    }
}

function New-TcModalDialogResult {
    <#
    .SYNOPSIS
        Builds the failed result (code IDE_MODAL_DIALOG) for a detected dialog.
    .PARAMETER Dialog
        Hashtable from Get-TcIdeModalDialog (@{ Title; Text; Kind }); Kind is derived
        from Title / Text when missing.
    .PARAMETER Operation
        Name of the operation that was NOT attempted, for the message.
    .PARAMETER Data
        Optional extra data; dialogTitle / dialogText / dialogKind / dialogReloadTarget
        ('file' | 'project' | $null) / dialogButtons (@{ id; name }) are always added, plus
        data.dialog = @{ title; text; kind; reloadTarget; buttons } (same shape as the MCP
        GetIdeModalDialog data.dialog).
        The hint is IDE_MODAL_DIALOG_RELOAD for Kind 'reload-prompt', else IDE_MODAL_DIALOG.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object]$Dialog,

        [Parameter()]
        [string]$Operation = 'COM call',

        [Parameter()]
        [object]$Data
    )

    $rec = Add-TcDialogKind -Dialog $Dialog
    $title = [string]$rec.Title
    $text = [string]$rec.Text
    $kind = [string]$rec.Kind
    $short = if ($text.Length -gt 200) { $text.Substring(0, 200) } else { $text }

    if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
    $Data | Add-Member -NotePropertyName 'dialogTitle' -NotePropertyValue $title -Force
    $Data | Add-Member -NotePropertyName 'dialogText' -NotePropertyValue $text -Force
    $Data | Add-Member -NotePropertyName 'dialogKind' -NotePropertyValue $kind -Force
    $Data | Add-Member -NotePropertyName 'dialogReloadTarget' -NotePropertyValue $rec.ReloadTarget -Force
    $buttonsOut = @(ConvertTo-TcDialogButtonList -Buttons $rec.Buttons)
    $Data | Add-Member -NotePropertyName 'dialogButtons' -NotePropertyValue $buttonsOut -Force
    $Data | Add-Member -NotePropertyName 'dialog' -NotePropertyValue ([PSCustomObject][ordered]@{
            title        = $title
            text         = $text
            kind         = $kind
            reloadTarget = $rec.ReloadTarget
            buttons      = $buttonsOut
        }) -Force

    $hintCode = if ($kind -eq 'reload-prompt') { 'IDE_MODAL_DIALOG_RELOAD' } else { 'IDE_MODAL_DIALOG' }
    New-TcResult -Success $false `
        -ErrorMessage "IDE_MODAL_DIALOG: '$Operation' not attempted - the IDE shows a modal dialog ($kind): $title | $short" `
        -ErrorCode 'IDE_MODAL_DIALOG' `
        -Hint (Get-TcErrorHint -Code $hintCode) `
        -Data $Data
}
