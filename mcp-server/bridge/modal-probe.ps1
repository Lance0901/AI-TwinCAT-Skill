# modal-probe.ps1 - watches an XAE / Visual Studio process for a modal dialog while the
# PowerShell bridge is blocked inside a DTE call (see PROTOCOL.md, "Modal-dialog probe").
#
# Started by the Node MCP server (lib/modal-probe.js) next to a long tool call and killed when
# the call ends. Loop: wait IntervalSec FIRST, then scan the top-level windows of ProcessId via
# UI Automation. On the first dialog found, write exactly ONE line to stdout:
#   {"title":"...","text":"...","className":"...","isModal":true,"processId":1234}
# and exit 0. Nothing else is ever written to stdout; diagnostics go to stderr.
# Exit codes: 0 dialog reported, 2 unexpected error, 3 process not found.
#
# The scan heuristics are COPIED from $script:TcUiaDialogScan in
# src/TwinCATAutomation/Private/Get-TcIdeModalDialog.ps1 and must be kept in sync with it
# (difference: the main window is always excluded by title, and the known-dialog title list also
# contains 'TwinCAT PLC Control', seen on a real machine, and when no Text descendant is found the
# dialog body is read from Pane / Edit / Document descendants, which Win11 message boxes use).
#
# Windows PowerShell 5.1, ASCII only, no BOM.
param(
    [Parameter(Mandatory = $true)]
    [int]$ProcessId,

    [int]$IntervalSec = 5,

    [int]$ScanTimeoutSec = 4,

    # A dialog is reported only after this many consecutive scans saw the same title, so a
    # transient window (progress / wait box) does not get the bridge killed.
    [int]$ConfirmScans = 2,

    [int]$MaxText = 500
)

$ErrorActionPreference = 'Stop'

function Write-ProbeError([string]$Message) {
    try { [Console]::Error.WriteLine("probe: $Message") } catch { }
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
if ($MaxText -lt 1) { $MaxText = 500 }

# Self-contained: runs in a fresh STA runspace, no access to this script's variables.
$scan = {
    param([int]$TargetPid, [int]$MaxText)

    Add-Type -AssemblyName UIAutomationClient -ErrorAction Stop
    Add-Type -AssemblyName UIAutomationTypes -ErrorAction Stop

    $ae = [System.Windows.Automation.AutomationElement]
    $root = $ae::RootElement
    $pidCond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
    $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $pidCond)
    if ($null -eq $windows -or $windows.Count -eq 0) { return }

    $mainTitlePattern = '(^|\s-\s)(TcXaeShell|Microsoft Visual Studio)(\s+\(.+\))?$'
    $knownDialogPattern = '(?i)Assertion Failed|Account Settings|fatal error|Security Code|License|Lizenz|TwinCAT XAE|Microsoft Visual Studio|TwinCAT PLC Control'

    $modalHit = $null
    $fallbackHit = $null
    foreach ($w in $windows) {
        $cur = $null
        try { $cur = $w.Current } catch { continue }
        $name = [string]$cur.Name
        $className = [string]$cur.ClassName
        if ($cur.ControlType -ne [System.Windows.Automation.ControlType]::Window) { continue }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        if ($name -match $mainTitlePattern -and $className -ne '#32770') { continue }
        if ($cur.IsOffscreen) { continue }

        $isModal = $false
        try {
            $wp = $null
            if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp) -and $null -ne $wp) {
                $isModal = [bool]$wp.Current.IsModal
            }
        }
        catch { }

        $hit = [PSCustomObject]@{ Element = $w; Title = $name; ClassName = $className; IsModal = $isModal }
        if ($isModal) { $modalHit = $hit; break }
        if ($null -eq $fallbackHit -and ($className -eq '#32770' -or $name -match $knownDialogPattern)) { $fallbackHit = $hit }
    }

    $chosen = $modalHit
    if ($null -eq $chosen) { $chosen = $fallbackHit }
    if ($null -eq $chosen) { return }

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
            # Windows 11 message boxes (and some WinForms dialogs) expose the message as a Pane /
            # Edit / Document, not as Text (Get-TcIdeModalDialog does not do this yet). Buttons,
            # the title bar and the title itself are skipped so the text stays the message body.
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
        if ($text.Length -gt $MaxText) { $text = $text.Substring(0, $MaxText) }
    }
    catch { }

    [PSCustomObject]@{
        Title     = $chosen.Title
        Text      = $text
        ClassName = $chosen.ClassName
        IsModal   = $chosen.IsModal
    }
}
$scanText = $scan.ToString()

function Invoke-ProbeScan {
    $ps = $null
    $rs = $null
    try {
        $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
        $rs.ApartmentState = [System.Threading.ApartmentState]::STA
        $rs.ThreadOptions = [System.Management.Automation.Runspaces.PSThreadOptions]::UseNewThread
        $rs.Open()
        $ps = [PowerShell]::Create()
        $ps.Runspace = $rs
        $null = $ps.AddScript($scanText).AddArgument($ProcessId).AddArgument($MaxText)
        $handle = $ps.BeginInvoke()
        if (-not $handle.AsyncWaitHandle.WaitOne($ScanTimeoutSec * 1000)) {
            # Normal while XAE's UI thread is busy (a build keeps it busy for seconds at a time), so
            # the message is written for the first abandoned scan and then only every 10th one.
            $script:AbandonedScans++
            if ($script:AbandonedScans -eq 1 -or ($script:AbandonedScans % 10) -eq 0) {
                Write-ProbeError "UIA scan of pid $ProcessId did not finish within $ScanTimeoutSec s; abandoned ($script:AbandonedScans so far)"
            }
            # Do not block on Stop(): the scan thread may be stuck inside UIA. Leave it to die.
            try { $null = $ps.BeginStop($null, $null) } catch { }
            $ps = $null
            $rs = $null
            return $null
        }
        $out = $ps.EndInvoke($handle)
        if ($ps.Streams.Error.Count -gt 0) {
            Write-ProbeError "scan error: $($ps.Streams.Error[0])"
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

$script:AbandonedScans = 0
$lastTitle = $null
$streak = 0
try {
    while ($true) {
        Start-Sleep -Seconds $IntervalSec

        $proc = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $proc) {
            Write-ProbeError "process $ProcessId not found"
            exit 3
        }

        $hit = Invoke-ProbeScan
        if ($null -eq $hit) {
            $lastTitle = $null
            $streak = 0
            continue
        }
        $title = [string]$hit.Title
        if ($title -eq $lastTitle) { $streak++ } else { $lastTitle = $title; $streak = 1 }
        if ($streak -lt $ConfirmScans) {
            Write-ProbeError "dialog '$title' seen ($streak/$ConfirmScans), waiting for confirmation"
            continue
        }
        if ($null -ne $hit) {
            $line = @{
                title     = [string]$hit.Title
                text      = [string]$hit.Text
                className = [string]$hit.ClassName
                isModal   = [bool]$hit.IsModal
                processId = $ProcessId
            } | ConvertTo-Json -Compress
            # Escape non-ASCII as \uXXXX: the console code page is not UTF-8, Node reads UTF-8.
            $line = [regex]::Replace($line, '[^\x00-\x7F]', { param($m) '\u{0:x4}' -f [int][char]$m.Value })
            [Console]::Out.WriteLine($line)
            [Console]::Out.Flush()
            exit 0
        }
    }
}
catch {
    Write-ProbeError "unexpected error: $($_.Exception.Message)"
    exit 2
}
