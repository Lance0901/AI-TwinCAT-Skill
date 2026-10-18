# modal-probe.ps1 - watches an XAE / Visual Studio process for a modal dialog while the
# PowerShell bridge is blocked inside a DTE call (see PROTOCOL.md, "Modal-dialog probe").
#
# Started by the Node MCP server (lib/modal-probe.js) next to a long tool call and killed when
# the call ends. Loop: wait IntervalSec FIRST, then scan the IDE process via UI Automation. When a
# kill-worthy dialog was seen in ConfirmScans consecutive scans, write exactly ONE line to stdout:
#   {"title":"...","text":"...","className":"...","isModal":true,"processId":1234,
#    "mainWindowBlocked":true,"reason":"win32-dialog"}
# and exit 0. Nothing else is ever written to stdout. stderr lines start with "debug: " (routine
# diagnostics) or "error: " (real failures).
# Exit codes: 0 dialog reported / stdin closed / lifetime exceeded, 2 error, 3 process not found.
#
# The scan is the module's $script:TcUiaDialogScan, dot-sourced from -ScanScript
# (src/TwinCATAutomation/Private/Get-TcIdeModalDialog.ps1), so window selection, the known-title
# list and the dialog text heuristics live in one place. This script only adds:
#   - the kill rule: (IsModal or ClassName '#32770') and the IDE main window BLOCKED: IsEnabled
#     false (Win32 / WinForms owners), or WindowPattern.WindowInteractionState
#     BlockedByModalWindow (the XAE main window is WPF: its IsEnabled stays true behind a modal,
#     verified on a real XAE with Help > About), or an owned child window that is modal / #32770
#     (a pure WPF owner reports neither of the first two). A window with a ProgressBar, a
#     title-only match or an unblocked main window is logged, never reported. With no main
#     window found, only an IsModal window is reported.
#   - main window lookup: -MainHwnd, else Process.MainWindowHandle, else the module's title
#     pattern (matched against the UIA Name and the Win32 caption).
#   - owned dialogs: UIA exposes a window OWNED by the main window (MessageBox(owner, ...),
#     WPF ShowDialog) as a child of the main window, not of the desktop, so the module scan
#     (desktop children only) does not see it; the main window's modal / #32770 child windows
#     are checked instead (title + Text descendants only).
#   - titles come from the Win32 caption: the UIA Name of a WPF window is often its content
#     text (XAE Help > About puts the whole About text there); titles are cut at 200 chars.
#
# Orphan protection: Node keeps stdin open and never writes to it. EOF (or any byte) on stdin means
# the parent is gone -> exit 0 within ~250 ms. -MaxLifetimeSec is a second safety net.
#
# Windows PowerShell 5.1, ASCII only, no BOM.
param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [Parameter(Mandatory = $true)]
    [string]$ScanScript,

    [int]$IntervalSec = 5,

    [int]$ScanTimeoutSec = 4,

    # A dialog is reported only after this many consecutive scans saw the same kill-worthy title.
    [int]$ConfirmScans = 2,

    # Handle of the IDE main window (state.ideMainHwnd); 0 = unknown (found by title instead).
    [long]$MainHwnd = 0,

    [int]$MaxLifetimeSec = 7260,

    [int]$MaxText = 500
)

$ErrorActionPreference = 'Stop'

function Write-ProbeDebug([string]$Message) {
    try { [Console]::Error.WriteLine("debug: $Message") } catch { }
}
function Write-ProbeError([string]$Message) {
    try { [Console]::Error.WriteLine("error: $Message") } catch { }
}

if ($ProcessId -le 0) {
    Write-ProbeError "invalid ProcessId $ProcessId"
    exit 2
}
if ($IntervalSec -lt 1) { $IntervalSec = 1 }
if ($IntervalSec -gt 60) { $IntervalSec = 60 }
if ($ScanTimeoutSec -lt 1) { $ScanTimeoutSec = 1 }
if ($ScanTimeoutSec -gt 30) { $ScanTimeoutSec = 30 }
if ($ConfirmScans -lt 1) { $ConfirmScans = 1 }
if ($ConfirmScans -gt 10) { $ConfirmScans = 10 }
if ($MaxLifetimeSec -lt 10) { $MaxLifetimeSec = 10 }
if ($MaxLifetimeSec -gt 86400) { $MaxLifetimeSec = 86400 }
if ($MainHwnd -lt 0) { $MainHwnd = 0 }
if ($MaxText -lt 1) { $MaxText = 500 }

# --- the module scan (single source of truth) ---
if ([string]::IsNullOrWhiteSpace($ScanScript) -or -not (Test-Path -LiteralPath $ScanScript -PathType Leaf)) {
    Write-ProbeError "scan script not found: $ScanScript"
    exit 2
}
try {
    # Also defines the functions Get-TcIdeModalDialog / New-TcModalDialogResult; the probe never
    # calls them (they need module state). Only $script:TcUiaDialogScan is used.
    . $ScanScript
}
catch {
    Write-ProbeError "cannot load scan script ${ScanScript}: $($_.Exception.Message)"
    exit 2
}
if (-not ($script:TcUiaDialogScan -is [scriptblock])) {
    Write-ProbeError "scan script $ScanScript does not define `$script:TcUiaDialogScan as a scriptblock"
    exit 2
}
$scanText = $script:TcUiaDialogScan.ToString()
# Main-window title pattern, read from the module scan source (no second copy). Not found ->
# empty: the main window is then known only by -MainHwnd (fail closed).
$mainTitlePattern = ''
$patternMatch = [regex]::Match($scanText, '\$mainTitlePattern\s*=\s*''([^'']+)''')
if ($patternMatch.Success) { $mainTitlePattern = $patternMatch.Groups[1].Value }
else { Write-ProbeDebug 'main-title pattern not found in the scan script; main window known only by -MainHwnd' }

# Runs in a fresh STA runspace: no access to this script's variables.
$wrapper = {
    param([string]$ScanText, [int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [string]$MainTitlePattern)

    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop
    $ae = [System.Windows.Automation.AutomationElement]
    $ct = [System.Windows.Automation.ControlType]
    $scope = [System.Windows.Automation.TreeScope]
    $wpat = [System.Windows.Automation.WindowPattern]

    # Win32 caption of a window. The UIA Name of a WPF window is often its content text, not its
    # title (XAE Help > About puts the whole About text there), so the caption is read directly.
    if (-not ([System.Management.Automation.PSTypeName]'TcProbeNative').Type) {
        Add-Type -Namespace TcProbe -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern int GetWindowText(System.IntPtr hWnd, System.Text.StringBuilder text, int maxCount);
'@ -ErrorAction SilentlyContinue
    }
    function Get-Caption([long]$h) {
        if ($h -le 0) { return '' }
        try {
            $sb = New-Object System.Text.StringBuilder 1024
            $null = [TcProbe.Native]::GetWindowText([IntPtr]$h, $sb, $sb.Capacity)
            return $sb.ToString()
        }
        catch { return '' }
    }
    function Test-ModalPattern($w) {
        try {
            $wp = $null
            if ($w.TryGetCurrentPattern($wpat::Pattern, [ref]$wp) -and $null -ne $wp) { return [bool]$wp.Current.IsModal }
        }
        catch { }
        return $false
    }

    $scan = [scriptblock]::Create($ScanText)
    $hit = $null
    foreach ($o in @(& $scan $TargetPid $MainHwnd $MaxText)) {
        if ($null -ne $o -and -not [string]::IsNullOrWhiteSpace([string]$o.Title)) { $hit = $o; break }
    }
    $hitHwnd = [long]0
    if ($null -ne $hit) { try { $hitHwnd = [long]$hit.Hwnd } catch { $hitHwnd = 0 } }

    # IDE main window: -MainHwnd, else the process' main window handle (first visible unowned
    # top-level window, i.e. never an owned dialog), else the module's main-title pattern.
    $main = $null
    $mainHandle = [long]$MainHwnd
    if ($mainHandle -le 0) {
        try { $mainHandle = [long](Get-Process -Id $TargetPid -ErrorAction Stop).MainWindowHandle } catch { $mainHandle = 0 }
    }
    if ($mainHandle -gt 0 -and $mainHandle -ne $hitHwnd) {
        try {
            $main = $ae::FromHandle([IntPtr]$mainHandle)
            if ($null -ne $main -and [int]$main.Current.ProcessId -ne $TargetPid) { $main = $null }
        }
        catch { $main = $null }
    }
    if ($null -eq $main -and -not [string]::IsNullOrEmpty($MainTitlePattern)) {
        try {
            $pidCond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
            foreach ($w in $ae::RootElement.FindAll($scope::Children, $pidCond)) {
                $c = $null
                try { $c = $w.Current } catch { continue }
                if ($c.ControlType -ne $ct::Window -or [string]$c.ClassName -eq '#32770') { continue }
                if ([long]$c.NativeWindowHandle -eq $hitHwnd -and $hitHwnd -gt 0) { continue }
                $cap = Get-Caption ([long]$c.NativeWindowHandle)
                if ([string]$c.Name -match $MainTitlePattern -or $cap -match $MainTitlePattern) { $main = $w; break }
            }
        }
        catch { $main = $null }
    }

    # Blocked = IsEnabled false (Win32 / WinForms owners), or WindowInteractionState
    # BlockedByModalWindow (the XAE main window is WPF and keeps IsEnabled true), or an owned
    # child window that is modal / a Win32 dialog (a pure WPF owner reports neither).
    $mainBlocked = $null
    if ($null -ne $main) {
        try { $mainBlocked = -not [bool]$main.Current.IsEnabled } catch { $mainBlocked = $null }
        if ($mainBlocked -ne $true) {
            try {
                $mwp = $null
                if ($main.TryGetCurrentPattern($wpat::Pattern, [ref]$mwp) -and $null -ne $mwp) {
                    if ($mwp.Current.WindowInteractionState -eq [System.Windows.Automation.WindowInteractionState]::BlockedByModalWindow) { $mainBlocked = $true }
                    elseif ($null -eq $mainBlocked) { $mainBlocked = $false }
                }
            }
            catch { }
        }
    }

    # Owned dialog: UIA exposes a window OWNED by the main window as a child of the main window,
    # not of the desktop, so the module scan (desktop children only) never sees it. Only modal /
    # #32770 children count; floating tool windows are owned too and must not be reported.
    $owned = $null
    if ($null -ne $main) {
        try {
            $winCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Window)
            foreach ($w in $main.FindAll($scope::Children, $winCond)) {
                $c = $null
                try { $c = $w.Current } catch { continue }
                if ($c.IsOffscreen) { continue }
                $wm = Test-ModalPattern $w
                if (-not $wm -and [string]$c.ClassName -ne '#32770') { continue }
                $owned = @{ Element = $w; Title = [string]$c.Name; ClassName = [string]$c.ClassName; IsModal = $wm; Hwnd = [long]$c.NativeWindowHandle }
                break
            }
        }
        catch { }
        if ($null -ne $owned) { $mainBlocked = $true }
    }

    $element = $null
    $title = $null; $text = ''; $className = ''; $isModal = $false; $hwnd = [long]0
    if ($null -ne $hit) {
        $title = [string]$hit.Title; $text = [string]$hit.Text; $className = [string]$hit.ClassName
        $isModal = [bool]$hit.IsModal; $hwnd = $hitHwnd
        if ($hwnd -gt 0) { try { $element = $ae::FromHandle([IntPtr]$hwnd) } catch { $element = $null } }
    }
    elseif ($null -ne $owned) {
        $element = $owned.Element; $title = $owned.Title; $className = $owned.ClassName
        $isModal = $owned.IsModal; $hwnd = $owned.Hwnd
        try {
            $textCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Text)
            $sb = New-Object System.Text.StringBuilder
            foreach ($t in $element.FindAll($scope::Descendants, $textCond)) {
                $tn = $null
                try { $tn = [string]$t.Current.Name } catch { $tn = $null }
                if ([string]::IsNullOrWhiteSpace($tn)) { continue }
                if ($sb.Length -gt 0) { $null = $sb.Append(' ') }
                $null = $sb.Append($tn.Trim())
                if ($sb.Length -ge $MaxText) { break }
            }
            $text = $sb.ToString()
        }
        catch { }
    }
    # Prefer the Win32 caption as title; a WPF window's UIA Name (content text) then becomes the
    # text when nothing else was collected.
    $caption = Get-Caption $hwnd
    if (-not [string]::IsNullOrWhiteSpace($caption) -and $caption.Trim() -ne [string]$title) {
        if ([string]::IsNullOrWhiteSpace($text) -and -not [string]::IsNullOrWhiteSpace($title)) { $text = [string]$title }
        $title = $caption.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($title)) { return }
    if ($title.Length -gt 200) { $title = $title.Substring(0, 200) }
    if ($text.Length -gt $MaxText) { $text = $text.Substring(0, $MaxText) }

    $hasProgress = $false
    if ($null -ne $element) {
        try {
            $pbCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::ProgressBar)
            $hasProgress = $null -ne $element.FindFirst($scope::Descendants, $pbCond)
        }
        catch { }
    }

    $reason = $null
    if ($className -eq '#32770') { $reason = 'win32-dialog' } elseif ($isModal) { $reason = 'modal' }
    $why = $null
    if ($null -eq $reason) { $why = 'title match only, not modal and not #32770' }
    elseif ($hasProgress) { $why = 'contains a progress bar' }
    elseif ($mainBlocked -eq $false) { $why = 'IDE main window is not blocked by a modal window' }
    elseif ($null -eq $mainBlocked -and -not $isModal) { $why = 'IDE main window not found and the window is not modal' }

    [PSCustomObject]@{
        Title             = $title
        Text              = $text
        ClassName         = $className
        IsModal           = $isModal
        Hwnd              = $hwnd
        MainWindowBlocked = $mainBlocked
        Reason            = $reason
        KillWorthy        = ($null -eq $why)
        NotKillWorthyWhy  = $why
    }
}
$wrapperText = $wrapper.ToString()

# --- orphan protection ---
$lifetime = [System.Diagnostics.Stopwatch]::StartNew()
$stdinTask = $null
try {
    $stdin = [Console]::OpenStandardInput()
    $stdinBuf = New-Object byte[] 1
    $stdinTask = $stdin.ReadAsync($stdinBuf, 0, 1)
}
catch {
    Write-ProbeDebug "stdin not watched: $($_.Exception.Message)"
    $stdinTask = $null
}

function Test-ProbeShouldExit {
    if ($null -ne $stdinTask -and $stdinTask.IsCompleted) {
        Write-ProbeDebug 'stdin closed; exiting'
        exit 0
    }
    if ($lifetime.Elapsed.TotalSeconds -ge $MaxLifetimeSec) {
        Write-ProbeDebug "max lifetime of $MaxLifetimeSec s exceeded; exiting"
        exit 0
    }
}

function Wait-ProbeSliced([int]$Milliseconds) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $Milliseconds) {
        Test-ProbeShouldExit
        $left = $Milliseconds - $sw.ElapsedMilliseconds
        if ($left -gt 250) { $left = 250 }
        if ($left -gt 0) { Start-Sleep -Milliseconds $left }
    }
    Test-ProbeShouldExit
}

# --- scans ---
# Scans abandoned after ScanTimeoutSec (UIA stuck on the IDE's busy UI thread) are kept so they can
# be disposed once they finish; while 10 are still hanging no new scan is started.
$script:Abandoned = New-Object System.Collections.ArrayList
$script:AbandonedScans = 0

function Clear-ProbeAbandoned {
    foreach ($a in @($script:Abandoned)) {
        $st = $null
        try { $st = $a.PS.InvocationStateInfo.State } catch { $st = $null }
        # Stopping = BeginStop waits for the stuck UIA call: still hanging, Dispose() would block.
        if ($st -eq [System.Management.Automation.PSInvocationState]::Running -or $st -eq [System.Management.Automation.PSInvocationState]::Stopping) { continue }
        try { $a.PS.Dispose() } catch { }
        try { $a.RS.Dispose() } catch { }
        $script:Abandoned.Remove($a)
    }
}

function Invoke-ProbeScan {
    Clear-ProbeAbandoned
    if ($script:Abandoned.Count -ge 10) {
        Write-ProbeDebug "$($script:Abandoned.Count) UIA scans still hanging; skipping"
        return $null
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
        $null = $ps.AddScript($wrapperText).AddArgument($scanText).AddArgument($ProcessId).AddArgument($MainHwnd).AddArgument($MaxText).AddArgument($mainTitlePattern)
        $handle = $ps.BeginInvoke()
        $deadline = [System.Diagnostics.Stopwatch]::StartNew()
        $finished = $false
        while ($true) {
            if ($handle.AsyncWaitHandle.WaitOne(250)) { $finished = $true; break }
            if ($deadline.Elapsed.TotalSeconds -ge $ScanTimeoutSec) { break }
            Test-ProbeShouldExit
        }
        if (-not $finished) {
            # Normal while XAE's UI thread is busy (a build keeps it busy for seconds at a time), so
            # the message is written for the first abandoned scan and then only every 10th one.
            $script:AbandonedScans++
            if ($script:AbandonedScans -eq 1 -or ($script:AbandonedScans % 10) -eq 0) {
                Write-ProbeDebug "UIA scan of pid $ProcessId did not finish within $ScanTimeoutSec s; abandoned ($script:AbandonedScans so far)"
            }
            # Do not block on Stop(): the scan thread may be stuck inside UIA. Disposed later.
            try { $null = $ps.BeginStop($null, $null) } catch { }
            $null = $script:Abandoned.Add([PSCustomObject]@{ PS = $ps; RS = $rs })
            $ps = $null
            $rs = $null
            return $null
        }
        $out = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count -gt 0) {
            Write-ProbeDebug "scan error: $($ps.Streams.Error[0])"
        }
        if ($null -eq $out -or $out.Count -eq 0) { return $null }
        $first = $out[0]
        if ($null -eq $first) { return $null }
        if ([string]::IsNullOrWhiteSpace([string]$first.Title)) { return $null }
        return $first
    }
    finally {
        if ($null -ne $ps) { try { $ps.Dispose() } catch { } }
        if ($null -ne $rs) { try { $rs.Dispose() } catch { } }
    }
}

Write-ProbeDebug "watching pid $ProcessId (interval $IntervalSec s, confirm $ConfirmScans, mainHwnd $MainHwnd, lifetime $MaxLifetimeSec s)"
$lastTitle = $null
$streak = 0
try {
    while ($true) {
        Wait-ProbeSliced ($IntervalSec * 1000)

        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
            Write-ProbeError "process $ProcessId not found"
            exit 3
        }

        $hit = Invoke-ProbeScan
        Test-ProbeShouldExit
        if ($null -eq $hit) {
            $lastTitle = $null
            $streak = 0
            continue
        }
        $title = [string]$hit.Title
        if (-not [bool]$hit.KillWorthy) {
            # Not counted toward confirmation.
            Write-ProbeDebug "dialog '$title' seen but not kill-worthy ($($hit.NotKillWorthyWhy))"
            $lastTitle = $null
            $streak = 0
            continue
        }
        if ($title -eq $lastTitle) { $streak++ } else { $lastTitle = $title; $streak = 1 }
        if ($streak -lt $ConfirmScans) {
            Write-ProbeDebug "dialog '$title' seen ($streak/$ConfirmScans), waiting for confirmation"
            continue
        }
        $mwb = $null
        if ($null -ne $hit.MainWindowBlocked) { $mwb = [bool]$hit.MainWindowBlocked }
        $line = [ordered]@{
            title             = $title
            text              = [string]$hit.Text
            className         = [string]$hit.ClassName
            isModal           = [bool]$hit.IsModal
            processId         = $ProcessId
            mainWindowBlocked = $mwb
            reason            = [string]$hit.Reason
        } | ConvertTo-Json -Compress
        # Escape non-ASCII as \uXXXX: the console code page is not UTF-8, Node reads UTF-8.
        $line = [regex]::Replace($line, '[^\x00-\x7F]', { param($mm) '\u{0:x4}' -f [int][char]$mm.Value })
        [Console]::Out.WriteLine($line)
        [Console]::Out.Flush()
        exit 0
    }
}
catch {
    Write-ProbeError "unexpected error: $($_.Exception.Message)"
    exit 2
}
