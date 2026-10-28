# Experiment: does a running XAE pick up a .TcPOU that was changed ON DISK by another tool
# (git checkout, a generator, an editor) - and which mechanism makes it do so without a human?
#
# One run = one scenario on a freshly launched IDE:
#   S0a  baseline, POU not open in an editor          -> change disk -> observe
#   S0b  baseline, POU opened first (ItemOperations.OpenFile) -> change disk -> observe
#   S2a  Tools/Options Environment>Documents DetectFileChangesOutsideIDE + AutoloadExternalChanges = true, POU not open
#   S2b  same options, POU open in an editor
#   S3   change disk -> Solution.Close($false) -> Connect-TcIde -SolutionPath (reopen)  -> observe
#   S3b  change disk -> select the project -> Project.UnloadProject + Project.ReloadProject -> observe
# Judgement (same for every scenario), after injecting "nReloadTest_Undefined := 1;" as the
# last line of the POU body ON DISK (file I/O, UTF-8 BOM + CRLF kept):
#   1. reload dialog: UI Automation list of the IDE's top-level windows + the main window's
#      owned windows, polled 5 s, then the main window is activated (VS checks files on
#      activation) and polled 10 s more; any new window is logged with title/text. When a
#      dialog with a "Yes"/"Reload" button shows up, that button is clicked (logged) so the
#      remaining checks can run - such a scenario is NOT dialog-free.
#   2. Get-TcPouCode implementation contains the line (PLC object model picked it up)
#   3. Build-TcProject codeErrors contain C0046 on nReloadTest_Undefined (the compiler used the file)
#   plus: does the file on disk still contain the line after the build ("save all before
#   build" may write the IDE's stale copy back).
# Harness-only intervention: an XAE "Assertion Failed" box (CODESYS code optimizer, independent of
# the reload question) is dismissed with Ignore by a background watchdog; every press is logged.
# Results 4024 (2026-10-20): S0a/S2a/S3/S3b picked the change up with no dialog; S0b/S2b (file open
# in a document window) show the modal "File has been changed outside the environment. Reload the
# new file?" ~1 s after the change, AutoloadExternalChanges does not suppress it.
# Then the .bak is copied back (same mechanism as the scenario), checks 1-3 again (expect the
# line gone and codeErrors empty).
#
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Integration/reload-experiment.ps1 `
#       -SolutionPath C:\Temp\TcReloadTest\TwinCAT_Festo.sln -Scenario S0a -IUnderstandThisModifiesTheProject
# Log: tests/Integration/logs/reload-<Scenario>.log (one JSON line per step, last line "summary").
# Safety: refuses OneDrive paths (exit 3), needs -IUnderstandThisModifiesTheProject (exit 2),
# refuses to run while any TcXaeShell is running (exit 4: it must not attach to someone else's
# IDE), quits / kills only the IDE it launched, restores the .bak in finally. Run under an
# outer deadline (a modal dialog can block a DTE call forever; the .bak is then left next to
# the POU for a manual restore). Does not Activate / Login / touch the PLC runtime.

param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [Parameter(Mandatory)][ValidateSet('S0a', 'S0b', 'S2a', 'S2b', 'S3', 'S3b')][string]$Scenario,
    [string]$ProgId = 'TcXaeShell.DTE.15.0',
    [string]$PlcProject = 'plc',
    [string]$PouName = 'MAIN_GantryCylinder',
    [string]$PouPath,
    [string]$LogPath,
    [int]$ObserveSec = 15,
    [switch]$IUnderstandThisModifiesTheProject,
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing
    # libraries, #45 / #56). The C0046 check (3.) is then weak: with missing libraries XAE may not
    # compile the code at all (tests/Integration/README.md).
    # Since #61 that build is never complete (completeBuild=false): a later Enable-TcConfig / login still refuses with
    # BUILD_REQUIRED, so Activate needs the libraries installed first.
    [switch]$AllowUnresolvedLibrary
)

if (-not $IUnderstandThisModifiesTheProject) {
    Write-Host "reload-experiment.ps1 MODIFIES $PouName.TcPOU ON DISK (a .bak copy is made and restored)."
    Write-Host "Run it only against a local COPY of a solution and pass -IUnderstandThisModifiesTheProject."
    exit 2
}
if ($SolutionPath -match '(?i)OneDrive') {
    Write-Host "REFUSED: the solution path is inside a OneDrive folder ($SolutionPath). Copy it to C:\Temp first."
    exit 3
}
if (@(Get-Process TcXaeShell -ErrorAction SilentlyContinue).Count -gt 0) {
    Write-Host "REFUSED: a TcXaeShell process is already running; this experiment needs its own fresh IDE."
    exit 4
}

$ErrorActionPreference = 'Continue'
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $scriptDir "logs\reload-$Scenario.log" }
$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Import-Module (Join-Path $scriptDir '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
if ([string]::IsNullOrWhiteSpace($PouPath)) { $PouPath = "TIPC^$PlcProject^$PlcProject Project^POUs^$PouName" }
$SolutionPath = (Resolve-Path $SolutionPath).Path
$injectLine = 'nReloadTest_Undefined := 1;'
$utf8Bom = New-Object System.Text.UTF8Encoding($true)

Add-Content -Path $LogPath -Value ("# reload-experiment.ps1 $Scenario " + (Get-Date).ToString('s') + " solution=$SolutionPath") -Encoding UTF8

$script:idePid = 0
$script:ownIde = $false
$script:connected = $false
$script:pouFile = $null
$script:pouBackup = $null
$script:summary = [ordered]@{ scenario = $Scenario }

function Write-Log {
    param([string]$Step, $Data, [int]$Ms = 0)
    $entry = [PSCustomObject]@{ time = (Get-Date).ToString('s'); step = $Step; ms = $Ms; data = $Data }
    Add-Content -Path $LogPath -Value ($entry | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
    $short = ($Data | ConvertTo-Json -Depth 4 -Compress)
    if ($short.Length -gt 300) { $short = $short.Substring(0, 300) + '...' }
    Write-Host ("{0} {1}ms {2}" -f $Step, $Ms, $short)
}

function Get-Dte { & $mod { $script:TcDte } }

# DTE call with a small retry on RPC_E_CALL_REJECTED / RPC_E_SERVERCALL_RETRYLATER.
function Invoke-Dte {
    param([scriptblock]$Block)
    for ($i = 0; $i -lt 6; $i++) {
        try { return (& $Block) }
        catch {
            $hr = 0; try { $hr = $_.Exception.HResult } catch { }
            if (($hr -eq -2147418111 -or $hr -eq -2147417846) -and $i -lt 5) { Start-Sleep -Seconds ([math]::Pow(2, $i)); continue }
            throw
        }
    }
}

# UI Automation listing of all windows of the IDE: top-level + direct Window children of the
# main window (owned dialogs live there). Runs in its own STA runspace with a timeout because
# UIA can block on a hung message loop.
$script:WindowScan = {
    param([int]$TargetPid, [int]$MaxText)
    Add-Type -AssemblyName UIAutomationClient
    Add-Type -AssemblyName UIAutomationTypes
    $ae = [System.Windows.Automation.AutomationElement]
    $ct = [System.Windows.Automation.ControlType]
    $mainHwnd = [long](Get-Process -Id $TargetPid).MainWindowHandle
    $cond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
    $winCond = New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Window)
    function Describe($w, [string]$where) {
        $c = $w.Current
        $modal = $null
        try { $wp = $null; if ($w.TryGetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern, [ref]$wp)) { $modal = [bool]$wp.Current.IsModal } } catch { }
        $text = ''
        try {
            $parts = foreach ($t in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, (New-Object System.Windows.Automation.PropertyCondition($ae::ControlTypeProperty, $ct::Text)))) { [string]$t.Current.Name }
            $text = (@($parts) -join ' ')
            if ($text.Length -gt $MaxText) { $text = $text.Substring(0, $MaxText) }
        } catch { }
        $buttons = @()
        try {
            # Win11 #32770 boxes expose buttons as Pane ClassName 'Button' and the body as Pane 'Static'
            $desc = @($w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition))
            $buttons = @($desc | Where-Object { $_.Current.ControlType -eq $ct::Button -or $_.Current.ClassName -eq 'Button' } | ForEach-Object { [string]$_.Current.Name } | Where-Object { $_ } | Select-Object -First 12)
            if ([string]::IsNullOrWhiteSpace($text)) {
                $text = (@($desc | Where-Object { $_.Current.ClassName -eq 'Static' } | ForEach-Object { [string]$_.Current.Name } | Where-Object { $_ }) -join ' ') -replace '\s+', ' '
                if ($text.Length -gt $MaxText) { $text = $text.Substring(0, $MaxText) }
            }
        } catch { }
        [PSCustomObject]@{ where = $where; title = [string]$c.Name; cls = [string]$c.ClassName; hwnd = [long]$c.NativeWindowHandle; modal = $modal; offscreen = [bool]$c.IsOffscreen; text = $text; buttons = @($buttons) }
    }
    $out = @()
    $main = $null
    foreach ($w in $ae::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
        $h = [long]$w.Current.NativeWindowHandle
        if ($h -eq $mainHwnd) { $main = $w; $out += [PSCustomObject]@{ where = 'main'; title = [string]$w.Current.Name; cls = [string]$w.Current.ClassName; hwnd = $h; modal = $null; offscreen = $false; text = ''; buttons = @() }; continue }
        $out += Describe $w 'top'
    }
    if ($null -ne $main) {
        foreach ($w in $main.FindAll([System.Windows.Automation.TreeScope]::Children, $winCond)) { $out += Describe $w 'owned' }
    }
    $out
}

function Get-IdeWindows {
    param([int]$TimeoutSec = 8)
    if ($script:idePid -le 0 -or -not (Get-Process -Id $script:idePid -ErrorAction SilentlyContinue)) { return @() }
    $rs = [RunspaceFactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'UseNewThread'; $rs.Open()
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript($script:WindowScan.ToString()).AddArgument($script:idePid).AddArgument(400)
    $h = $ps.BeginInvoke()
    if (-not $h.AsyncWaitHandle.WaitOne($TimeoutSec * 1000)) { try { $null = $ps.BeginStop($null, $null) } catch { }; return @([PSCustomObject]@{ where = 'scan'; title = '<UIA scan timeout>' }) }
    $r = @($ps.EndInvoke($h)); $ps.Dispose(); $rs.Dispose()
    return $r
}

# Click a reload-type button of a dialog (Yes / Reload / Yes to All, en + zh). Returns the clicked name or $null.
function Invoke-DialogButton {
    param([long]$Hwnd)
    Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes
    $ae = [System.Windows.Automation.AutomationElement]
    try {
        $w = $ae::FromHandle([IntPtr]$Hwnd)
        $btns = @($w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition) | Where-Object { $_.Current.ControlType -eq [System.Windows.Automation.ControlType]::Button -or $_.Current.ClassName -eq 'Button' })
        foreach ($pat in @('^(&)?Yes to All$|^全部皆是', '^(&)?Yes$|^是', '(?i)reload|重新載入')) {
            foreach ($b in $btns) {
                $n = [string]$b.Current.Name
                if ($n -match $pat) {
                    $ip = $null
                    if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke(); return $n }
                    $null = Set-IdeForeground   # loads TcReloadExp.Native
                    $null = [TcReloadExp.Native]::PostMessage([IntPtr][long]$b.Current.NativeWindowHandle, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero)
                    return "$n (BM_CLICK)"
                }
            }
        }
    } catch { return "click failed: $($_.Exception.Message)" }
    return $null
}

function Set-IdeForeground {
    if (-not ([System.Management.Automation.PSTypeName]'TcReloadExp.Native').Type) {
        Add-Type -Namespace TcReloadExp -Name Native -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool SetForegroundWindow(System.IntPtr h);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern System.IntPtr GetForegroundWindow();
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);
[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, System.UIntPtr extra);
'@
    }
    try {
        $h = (Get-Process -Id $script:idePid).MainWindowHandle
        [TcReloadExp.Native]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [TcReloadExp.Native]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)  # ALT tap unlocks SetForegroundWindow
        $null = [TcReloadExp.Native]::ShowWindow($h, 9)
        $ok = [TcReloadExp.Native]::SetForegroundWindow($h)
        Start-Sleep -Milliseconds 300
        return "set=$ok isForeground=$([TcReloadExp.Native]::GetForegroundWindow() -eq $h)"
    } catch { return "error: $($_.Exception.Message)" }
}

# Known XAE quirk: a compile can pop "Assertion Failed: Abort=Quit, Retry=Debug, Ignore=Continue"
# (#32770) and the Build DTE call then never returns. During Build-TcProject a background
# runspace watches the IDE for that box, logs its text and presses Ignore (Continue) so the
# experiment can go on; every press is reported in assertDuringBuild.
$script:AssertWatch = {
    param([int]$TargetPid, $State, $Hits)
    Add-Type -AssemblyName UIAutomationClient; Add-Type -AssemblyName UIAutomationTypes
    $ae = [System.Windows.Automation.AutomationElement]
    $cond = New-Object System.Windows.Automation.PropertyCondition($ae::ProcessIdProperty, $TargetPid)
    # zh-TW Win11 message boxes expose the buttons as Pane '中止(A)' / '重試(R)' / '略過(I)' and the body as a Pane.
    $all = [System.Windows.Automation.Condition]::TrueCondition
    if (-not ([System.Management.Automation.PSTypeName]'TcReloadExp.WdNative').Type) {
        Add-Type -Namespace TcReloadExp -Name WdNative -MemberDefinition '[System.Runtime.InteropServices.DllImport("user32.dll")] public static extern bool PostMessage(System.IntPtr h, uint m, System.IntPtr w, System.IntPtr l);'
    }
    while (-not $State.stop) {
        try {
            foreach ($w in $ae::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
                $n = [string]$w.Current.Name
                if ($n -notlike 'Assertion Failed*') { continue }
                $els = @($w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $all))
                $txt = (@($els | ForEach-Object { [string]$_.Current.Name } | Where-Object { $_.Length -gt 20 }) -join ' ')
                $txt = ($txt -replace '\s+', ' ')
                if ($txt.Length -gt 300) { $txt = $txt.Substring(0, 300) }
                $pressed = $null
                foreach ($b in $els) {
                    if ([string]$b.Current.Name -match '(?i)^&?Ignore|略過|忽略') {
                        $ip = $null
                        if ($b.TryGetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern, [ref]$ip)) { $ip.Invoke(); $pressed = [string]$b.Current.Name; break }
                        # the #32770 button Pane exposes no pattern: BM_CLICK on its HWND
                        $bh = [long]$b.Current.NativeWindowHandle
                        if ($bh -ne 0) { $null = [TcReloadExp.WdNative]::PostMessage([IntPtr]$bh, 0x00F5, [IntPtr]::Zero, [IntPtr]::Zero); $pressed = [string]$b.Current.Name + ' (BM_CLICK)'; break }
                    }
                }
                [void]$Hits.Add("$((Get-Date).ToString('HH:mm:ss')) '$n' text='$txt' pressed=$pressed")
                Start-Sleep -Milliseconds 800
            }
        } catch { }
        Start-Sleep -Milliseconds 500
    }
}
function Start-AssertWatchdog {
    $state = [hashtable]::Synchronized(@{ stop = $false })
    $hits = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    $rs = [RunspaceFactory]::CreateRunspace(); $rs.ApartmentState = 'STA'; $rs.ThreadOptions = 'UseNewThread'; $rs.Open()
    $ps = [PowerShell]::Create(); $ps.Runspace = $rs
    $null = $ps.AddScript($script:AssertWatch.ToString()).AddArgument($script:idePid).AddArgument($state).AddArgument($hits)
    $h = $ps.BeginInvoke()
    return @{ state = $state; hits = $hits; ps = $ps; rs = $rs; h = $h }
}
function Stop-AssertWatchdog($wd) {
    $wd.state.stop = $true
    $null = $wd.h.AsyncWaitHandle.WaitOne(5000)
    try { $wd.ps.Dispose(); $wd.rs.Dispose() } catch { }
    return @($wd.hits)
}

$script:baselineHwnds = @{}
# Poll the IDE windows: first half without, second half after activating the main window.
# Returns @{ dialogs = [new windows]; clicked = [...]; activated = bool }.
function Watch-ReloadDialog {
    param([string]$Phase, [int]$Seconds = $ObserveSec)
    $seen = @{}; $dialogs = @(); $clicked = @()
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $activated = $false
    while ($sw.Elapsed.TotalSeconds -lt $Seconds) {
        if (-not $activated -and $sw.Elapsed.TotalSeconds -ge [math]::Min(5, $Seconds / 3)) {
            # Read the POU once BEFORE activating the main window (only when no dialog is up).
            if ($null -eq $script:earlyRead) {
                if (& $mod { Get-TcIdeModalDialog }) { $script:earlyRead = 'skipped (modal dialog)' }
                else {
                    $eg = Get-TcPouCode -PouName $PouName -PouPath $PouPath
                    $script:earlyRead = if ($eg.success) { ([string]$eg.data.implementation).Contains($injectLine) } else { "error $($eg.error.code)" }
                }
                Write-Log "$Phase-early-read" @{ pouHasLineBeforeActivate = $script:earlyRead; atSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }
            }
            # Win32, not DTE: a DTE call would block forever if a modal dialog is already up.
            $activated = $true
            $fg = Set-IdeForeground
            Write-Log "$Phase-activate-main" @{ foreground = $fg }
        }
        foreach ($w in @(Get-IdeWindows)) {
            if ($w.where -eq 'main') { continue }
            $key = "$($w.hwnd)|$($w.title)"
            if ($script:baselineHwnds.ContainsKey($key) -or $seen.ContainsKey($key)) { continue }
            if ($w.where -ne 'scan' -and $w.offscreen) { continue }
            if ($w.cls -eq 'VisualStudioGlowWindow') { continue }   # VS window-border chrome, not a dialog
            if ($w.title -like 'Assertion Failed*') { $seen[$key] = $true; Write-Log "$Phase-assert-window" @{ title = $w.title; atSec = [math]::Round($sw.Elapsed.TotalSeconds, 1) }; continue }
            $seen[$key] = $true
            $w | Add-Member -NotePropertyName atSec -NotePropertyValue ([math]::Round($sw.Elapsed.TotalSeconds, 1)) -Force
            $dialogs += $w
            Write-Log "$Phase-new-window" $w
            if ($w.hwnd -gt 0 -and (@($w.buttons) -join '|') -match '(?i)yes|reload|是|重新載入') {
                $c = Invoke-DialogButton -Hwnd $w.hwnd
                if ($c) { $clicked += $c; Write-Log "$Phase-clicked" @{ title = $w.title; button = $c } }
            }
        }
        Start-Sleep -Milliseconds 700
    }
    return @{ dialogs = $dialogs; clicked = $clicked; activated = $activated }
}

function Set-BaselineWindows {
    $script:baselineHwnds = @{}
    $all = @(Get-IdeWindows)
    foreach ($w in $all) { $script:baselineHwnds["$($w.hwnd)|$($w.title)"] = $true }
    Write-Log 'baseline-windows' @($all | Select-Object where, title, cls, modal, offscreen)
}

function Connect-Ide {
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $c = Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId
        $sw.Stop()
        Write-Log "connect-$attempt" ([PSCustomObject]@{ success = $c.success; code = $c.error.code; message = $c.error.message; selectedBy = $c.data.selectedBy; ideProcessId = $c.data.ideProcessId; silentMode = $c.data.silentMode; dialog = $c.data.dialogTitle }) ([int]$sw.ElapsedMilliseconds)
        if ($c.data.ideProcessId -gt 0 -and $script:idePid -eq 0) { $script:idePid = [int]$c.data.ideProcessId; $script:ownIde = ($c.data.selectedBy -eq 'launched') }
        if ($c.success) { $script:connected = $true; return $c }
        if ($c.error.code -eq 'IDE_MODAL_DIALOG' -and $script:ownIde -and $attempt -lt 3) {
            Write-Host "modal dialog at connect -> kill own IDE $($script:idePid) and retry"
            Stop-Process -Id $script:idePid -Force -ErrorAction SilentlyContinue
            $null = Disconnect-TcIde
            $script:idePid = 0; $script:ownIde = $false
            Start-Sleep -Seconds 3
            continue
        }
        return $c
    }
}

function Find-PouFile {
    $slnDir = Split-Path -Parent $SolutionPath
    $c = @(Get-ChildItem -Path $slnDir -Recurse -Filter "$PouName.TcPOU" -File | Where-Object { $_.FullName -like "*\$PlcProject\*" })
    if ($c.Count -eq 0) { throw "$PouName.TcPOU not found under $slnDir" }
    return $c[0].FullName
}

# Insert the line before the "]]>" that closes the POU's own <Implementation><ST> CDATA
# (the first one; method bodies follow later in the file). BOM / CRLF stay as they were.
function Write-Injection {
    $text = [IO.File]::ReadAllText($script:pouFile)
    $iImpl = $text.IndexOf('<Implementation>')
    if ($iImpl -lt 0) { throw 'no <Implementation> in POU file' }
    $iEnd = $text.IndexOf(']]></ST>', $iImpl)
    if ($iEnd -lt 0) { throw 'no ]]></ST> after <Implementation>' }
    $new = $text.Substring(0, $iEnd) + "`r`n" + $injectLine + $text.Substring($iEnd)
    [IO.File]::WriteAllText($script:pouFile, $new, $utf8Bom)
}

function Test-DiskHasLine { return ([IO.File]::ReadAllText($script:pouFile)).Contains($injectLine) }

function Restore-Disk {
    if ($script:pouBackup -and (Test-Path -LiteralPath $script:pouBackup)) {
        Copy-Item -LiteralPath $script:pouBackup -Destination $script:pouFile -Force
        return ((Get-FileHash -LiteralPath $script:pouBackup).Hash -eq (Get-FileHash -LiteralPath $script:pouFile).Hash)
    }
    return $false
}

# Open the POU in an editor (sub-state b). Logs which documents are open.
function Open-PouInEditor {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = [ordered]@{}
    try { $win = Invoke-Dte { (Get-Dte).ItemOperations.OpenFile($script:pouFile) }; $r.openFile = 'ok'; try { $r.windowCaption = [string]$win.Caption } catch { } }
    catch { $r.openFile = "error: $($_.Exception.Message)" }
    $r.documents = Get-OpenDocuments
    Write-Log 'open-pou-in-editor' $r ([int]$sw.ElapsedMilliseconds)
}

function Get-OpenDocuments {
    try { return @(Invoke-Dte { foreach ($d in (Get-Dte).Documents) { "$($d.FullName) saved=$($d.Saved)" } }) } catch { return @("error: $($_.Exception.Message)") }
}

function Set-AutoReloadOptions {
    $r = [ordered]@{}
    try {
        $docs = Invoke-Dte { (Get-Dte).Properties('Environment', 'Documents') }
        $r.names = @(foreach ($p in $docs) { try { "$($p.Name)=$($p.Value)" } catch { "$($p.Name)=?" } })
        # Properties.Item('<name>') does not bind from PowerShell (it wants an Int32): use the enumerated objects.
        foreach ($n in 'DetectFileChangesOutsideIDE', 'AutoloadExternalChanges') {
            $prop = $null
            foreach ($p in $docs) { if ($p.Name -eq $n) { $prop = $p } }
            if ($null -eq $prop) { $r[$n] = 'not found'; continue }
            try { $prop.Value = $true; $r[$n] = [string]$prop.Value } catch { $r[$n] = "error: $($_.Exception.Message)" }
        }
    }
    catch { $r.error = $_.Exception.Message }
    Write-Log 'set-options' $r
}

# Scenario mechanism applied after the disk change (and again after the restore).
function Invoke-Mechanism {
    param([string]$Phase)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = [ordered]@{}
    switch ($Scenario) {
        'S3' {
            try { Invoke-Dte { (Get-Dte).Solution.Close($false) } | Out-Null; $r.close = 'ok' } catch { $r.close = "error: $($_.Exception.Message)" }
            $r.closeMs = [int]$sw.ElapsedMilliseconds
            $c = Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId
            $r.reopen = if ($c.success) { "ok selectedBy=$($c.data.selectedBy) pid=$($c.data.ideProcessId)" } else { "error $($c.error.code): $($c.error.message)" }
        }
        'S3b' {
            $projName = $null
            try {
                $dte = Get-Dte
                $proj = Invoke-Dte { foreach ($p in $dte.Solution.Projects) { if ($p.FullName -like '*.tsproj') { $p } } } | Select-Object -First 1
                $projName = [string]$proj.Name
                $r.project = "$projName ($($proj.FullName))"
                $se = Invoke-Dte { $dte.Windows.Item('{3AE79031-E1BC-11D0-8F78-00A0C9110057}').Object }
                $slnName = [IO.Path]::GetFileNameWithoutExtension($SolutionPath)
                $item = Invoke-Dte { $se.GetItem("$slnName\$projName") }
                Invoke-Dte { $item.Select(1) } | Out-Null   # vsUISelectionTypeSelect
                $r.select = 'ok'
            }
            catch { $r.select = "error: $($_.Exception.Message)" }
            foreach ($cmd in 'Project.UnloadProject', 'Project.ReloadProject') {
                $t = [Diagnostics.Stopwatch]::StartNew()
                try { Invoke-Dte { (Get-Dte).ExecuteCommand($cmd) } | Out-Null; $r[$cmd] = "ok $([int]$t.ElapsedMilliseconds)ms" }
                catch { $r[$cmd] = "error: $($_.Exception.Message)" }
            }
            # the module caches ITcSysManager of the old project object
            try { & $mod { $script:TcSysManager = $null; $null = Get-TcSysManager -Refresh }; $r.sysManager = 'refreshed' } catch { $r.sysManager = "error: $($_.Exception.Message)" }
        }
        default { $r.mechanism = 'none (wait + activate main window)' }
    }
    $sw.Stop()
    Write-Log "$Phase-mechanism" $r ([int]$sw.ElapsedMilliseconds)
    return [int]$sw.ElapsedMilliseconds
}

# Checks 1-3 + disk state after the build. $Expect = $true: line expected present.
function Invoke-Judgement {
    param([string]$Phase)
    $res = [ordered]@{ phase = $Phase }
    $mechMs = Invoke-Mechanism -Phase $Phase
    $res.mechanismMs = $mechMs
    $script:earlyRead = $null
    $watch = Watch-ReloadDialog -Phase $Phase
    $res.pouHasLineBeforeActivate = $script:earlyRead
    $res.assertSoFar = @($script:wd.hits)
    $res.dialogs = @($watch.dialogs | ForEach-Object { "$($_.where):'$($_.title)' [$($_.cls)] modal=$($_.modal) text='$($_.text)' buttons=$(@($_.buttons) -join '/') at $($_.atSec)s" })
    $res.clicked = @($watch.clicked)
    Start-Sleep -Seconds 2   # let the watchdog dismiss an assertion box first
    $modal = & $mod { Get-TcIdeModalDialog }
    $res.moduleModal = if ($modal) { "$($modal.Title) | $($modal.Text)" } else { $null }
    if ($modal -and @($watch.clicked).Count -eq 0) {
        $res.blocked = $true
        Write-Log "$Phase-judgement" $res
        return $res
    }
    Write-Host "  [$Phase] read docs"; $res.documents = Get-OpenDocuments

    Write-Host "  [$Phase] Get-TcPouCode"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $g = Get-TcPouCode -PouName $PouName -PouPath $PouPath
    $res.getPouMs = [int]$sw.ElapsedMilliseconds
    $res.getPouOk = [bool]$g.success
    $res.pouHasLine = if ($g.success) { ([string]$g.data.implementation).Contains($injectLine) } else { "error $($g.error.code)" }

    $res.diskHasLineBeforeBuild = Test-DiskHasLine
    $sw = [Diagnostics.Stopwatch]::StartNew()
    Write-Host "  [$Phase] Build-TcProject"
    $b = Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
    $res.assertPressedSoFar = @($script:wd.hits)
    $res.buildMs = [int]$sw.ElapsedMilliseconds
    $res.buildSucceeded = $b.data.buildSucceeded
    $res.buildCode = $b.error.code
    $res.codeErrors = @($b.data.codeErrors | Select-Object -First 5 | ForEach-Object { "$($_.code) $($_.file):$($_.line) $($_.description)" })
    $res.c0046 = @($b.data.codeErrors | Where-Object { $_.code -eq 'C0046' -and ([string]$_.description) -match 'nReloadTest_Undefined' }).Count -gt 0
    $res.diskHasLineAfterBuild = Test-DiskHasLine
    Write-Log "$Phase-judgement" $res
    return $res
}

function Invoke-Main {
    # Same starting point for every scenario: no compile cache from an earlier run.
    $ci = Join-Path (Split-Path -Parent $SolutionPath) "$([IO.Path]::GetFileNameWithoutExtension($SolutionPath))\$PlcProject\_CompileInfo"
    if (Test-Path $ci) { Remove-Item $ci -Recurse -Force; Write-Log 'clean-compileinfo' @{ removed = $ci } }
    $c = Connect-Ide
    if (-not $c.success) { Write-Host 'ABORT: cannot connect'; return 1 }
    $script:summary.silentMode = $c.data.silentMode
    $script:wd = Start-AssertWatchdog
    $script:pouFile = Find-PouFile
    $g = Get-TcPouCode -PouName $PouName -PouPath $PouPath
    if (-not $g.success) { Write-Host "ABORT: POU not readable: $($g.error.message)"; return 1 }
    if (([string]$g.data.implementation).Contains($injectLine) -or (Test-DiskHasLine)) { Write-Host 'ABORT: injected line already present (leftover?)'; return 1 }
    Write-Log 'start' ([ordered]@{ pouFile = $script:pouFile; documents = Get-OpenDocuments; ideProcessId = $script:idePid; ownIde = $script:ownIde })

    if ($Scenario -like 'S2*') { Set-AutoReloadOptions }
    if ($Scenario -in 'S0b', 'S2b') { Open-PouInEditor }
    Set-BaselineWindows

    $script:pouBackup = $script:pouFile + '.bak-' + (Get-Date).ToString('yyyyMMdd-HHmmss')
    Copy-Item -LiteralPath $script:pouFile -Destination $script:pouBackup -Force
    Write-Injection
    Write-Log 'inject-disk' @{ diskHasLine = (Test-DiskHasLine); backup = $script:pouBackup }

    $j1 = Invoke-Judgement -Phase 'inject'
    $script:summary.inject = $j1
    if ($j1.blocked) { Write-Host 'modal dialog left open -> stop here (IDE killed in finally)'; return 0 }

    $ok = Restore-Disk
    Write-Log 'restore-disk' @{ verified = $ok; diskHasLine = (Test-DiskHasLine) }
    Set-BaselineWindows
    $j2 = Invoke-Judgement -Phase 'restore'
    $script:summary.restore = $j2
    return 0
}

$exitCode = 1
try {
    $out = @(Invoke-Main)
    $exitCode = [int]$out[$out.Count - 1]
}
catch { Write-Log 'exception' @{ message = $_.Exception.Message; at = $_.InvocationInfo.PositionMessage } }
finally {
    if ($script:wd) { $script:summary.assertionsIgnored = @(Stop-AssertWatchdog $script:wd); Write-Log 'assertions' $script:summary.assertionsIgnored }
    if ($script:connected) {
        $modal = & $mod { Get-TcIdeModalDialog }
        if ($modal -and $script:ownIde) { Stop-Process -Id $script:idePid -Force -ErrorAction SilentlyContinue; $null = Disconnect-TcIde; Write-Host 'finally: killed own IDE (modal dialog)' }
        else { try { $null = Disconnect-TcIde -Quit:$script:ownIde } catch { } }
    }
    if ($script:ownIde -and $script:idePid -gt 0) {
        $p = Get-Process -Id $script:idePid -ErrorAction SilentlyContinue
        if ($p) { $null = $p.WaitForExit(20000); if (-not $p.HasExited) { Stop-Process -Id $script:idePid -Force -ErrorAction SilentlyContinue; Write-Host 'finally: killed own IDE (did not exit)' } }
    }
    # IDE is gone: put the original file back by plain copy, delete the .bak once verified.
    if ($script:pouBackup -and (Test-Path -LiteralPath $script:pouBackup)) {
        if (Restore-Disk) { Remove-Item -LiteralPath $script:pouBackup -Force; Write-Host 'finally: POU restored, bak deleted' }
        else { Write-Host "WARNING: restore did not verify; backup kept at $($script:pouBackup)" }
    }
    Write-Log 'summary' $script:summary
    Write-Host "DONE log=$LogPath"
}
exit $exitCode
