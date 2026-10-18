# UI Automation scan that runs INSIDE a separate runspace (see Get-TcIdeModalDialog and
# the watchdog in Invoke-TcComRetry). It must be self-contained: no module functions,
# no $script: state. Arguments: target process id, main window handle (0 = unknown),
# max text length. Emits one PSCustomObject @{ Title; Text; ClassName; IsModal; Hwnd }
# for the first dialog found, or nothing.
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
    $root = $ae::RootElement
    $pidCond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)
    if ($null -eq $windows -or $windows.Count -eq 0) { return }

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

    $mainTitlePattern = '(^|\s-\s)(TcXaeShell|Microsoft Visual Studio)(\s+\(.+\))?$'
    # ASCII only (file has no BOM): localized titles are caught by IsModal / #32770.
    $knownDialogPattern = '(?i)Assertion Failed|Account Settings|fatal error|Security Code|License|Lizenz|TwinCAT XAE|Microsoft Visual Studio'

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

    [PSCustomObject]@{
        Title     = $title
        Text      = $text
        ClassName = $chosen.ClassName
        IsModal   = $chosen.IsModal
        Hwnd      = $chosen.Hwnd
    }
}

function Get-TcIdeModalDialog {
    <#
    .SYNOPSIS
        Detects a modal dialog (Assertion Failed, VS account settings, fatal error,
        license prompt ...) in the connected IDE process via UI Automation.
    .DESCRIPTION
        Lists the top-level windows of the IDE process (default: $script:TcIdeProcessId
        stored by Connect-TcIde), excludes the main window and returns the first
        window that looks like a dialog as @{ Title; Text } (Text = visible text,
        at most 500 chars). Returns $null when the pid is unknown, the process does
        not exist, no dialog is open, or the scan does not finish within -TimeoutSec.

        The UI Automation calls run in a separate runspace with a hard timeout:
        while a modal dialog is up, UIA itself can block on the IDE's message loop.
        This function never throws.
    .PARAMETER ProcessId
        IDE process id. Default: $script:TcIdeProcessId.
    .PARAMETER TimeoutSec
        Maximum time for the UIA scan. Default 5.
    .OUTPUTS
        Hashtable @{ Title = [string]; Text = [string] } or $null.
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
        return @{
            Title = $title
            Text  = [string]$first.Text
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
        Hashtable from Get-TcIdeModalDialog (@{ Title; Text }).
    .PARAMETER Operation
        Name of the operation that was NOT attempted, for the message.
    .PARAMETER Data
        Optional extra data; dialogTitle / dialogText are always added.
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

    $title = [string]$Dialog.Title
    $text = [string]$Dialog.Text
    $short = if ($text.Length -gt 200) { $text.Substring(0, 200) } else { $text }

    if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
    $Data | Add-Member -NotePropertyName 'dialogTitle' -NotePropertyValue $title -Force
    $Data | Add-Member -NotePropertyName 'dialogText' -NotePropertyValue $text -Force

    New-TcResult -Success $false `
        -ErrorMessage "IDE_MODAL_DIALOG: '$Operation' not attempted - the IDE shows a modal dialog: $title | $short" `
        -ErrorCode 'IDE_MODAL_DIALOG' `
        -Hint (Get-TcErrorHint -Code 'IDE_MODAL_DIALOG') `
        -Data $Data
}
