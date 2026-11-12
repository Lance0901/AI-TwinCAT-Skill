# Unit: #42 modal-dialog scan cold start and incomplete scans, no IDE / runtime needed.
#   A  no desktop-wide RootElement.FindAll left in the dialog scan; the Error List scan lists the
#      IDE windows with EnumWindows (TcAutomation.UiaScanWindows) and keeps FindAll only as fallback
#   B  the real scan against a pid without top-level windows (this process): complete, $null,
#      all P/Invoke types compiled (EnumWindows is the window enumeration; nothing else is listed)
#   C  Find-TcIdeModalDialog with mocked scans ($script:TcUiaDialogScan replaced):
#      C1 slow preparation (cold start) is NOT charged to -TimeoutSec -> complete, $null
#      C2 scan slower than -TimeoutSec -> incomplete marker, reason 'timeout'
#      C3 preparation hangs -> reason 'prepare-timeout' ($script:TcUiaScanPrepareTimeoutSec)
#      C4 scan throws / C5 writes an error and returns nothing -> reason 'error'
#      C6 scan returns a dialog -> dialog record
#   D  helpers: Test-TcModalScanIncomplete, New-TcModalDialogResult -> MODAL_SCAN_INCOMPLETE
#   E  callers treat an incomplete scan as unknown, never as "no dialog":
#      E1 Clear-TcProject pre-check -> MODAL_SCAN_INCOMPLETE, Clean not called
#      E2 Clear-TcProject poll: incomplete scans keep polling, CLEAN_TIMEOUT carries data.modalScan
#      E3 Disconnect-TcIde -Quit -> MODAL_SCAN_INCOMPLETE, Solution.Close / DTE.Quit not called,
#         connection kept
#      E4 tree-item gate (Get-TcTreeItemDialogResult) -> MODAL_SCAN_INCOMPLETE
#   M  #234 the real scan against WPF fixture windows of a child process: the IDE main window (UIA
#      AutomationId VisualStudioMainWindow) is never reported, also with a stale MainHwnd (M1-M6); read failures keep the old checks (M7)
#   powershell.exe -NoProfile -File tests/Unit/modal-scan-incomplete.ps1
# Exit code = number of failed checks. Takes ~20 s.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-msi-{0}" -f [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 5 }

$origScan = & $mod { $script:TcUiaDialogScan }
$origFind = & $mod { ${function:Find-TcIdeModalDialog} }
& $mod { $script:TcIdeProcessId = $null; $script:TcIdeMainHwnd = 0 }   # no watchdog, no main window

try {
    # --- A: static (code only: comments are dropped) ---
    function Get-CodeText([string]$Text) {
        $tokens = $null; $errs = $null
        $null = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref]$tokens, [ref]$errs)
        (@($tokens | Where-Object { $_.Kind -ne [System.Management.Automation.Language.TokenKind]::Comment } | ForEach-Object { $_.Text }) -join ' ')
    }
    $scanText = Get-CodeText $origScan.ToString()
    Check 'A1 dialog scan: no RootElement.FindAll' ($scanText -notmatch 'RootElement\s*\.\s*FindAll' -and $scanText -match 'RootElement') ''
    Check 'A2 dialog scan: EnumWindows by pid + PrepareOnly mode' ($scanText -match 'TopLevelOf' -and $scanText -match 'EnumWindows' -and $scanText -match 'PrepareOnly') ''
    $elText = Get-CodeText (& $mod { $script:TcUiaErrorListScan }).ToString()
    $elFindAll = [regex]::Matches($elText, 'RootElement\s*\.\s*FindAll').Count
    Check 'A3 Error List scan: TopLevelOf / VisibleOf, desktop FindAll only as the two fallbacks' ($elText -match 'TopLevelOf' -and $elText -match 'VisibleOf' -and $elFindAll -eq 2) "FindAll count $elFindAll"

    # --- A4: Initialize-TcUiaScanTypes is bounded (types not compiled yet in this process) ---
    if (-not ([System.Management.Automation.PSTypeName]'TcAutomation.UiaScanWindows').Type) {
        & $mod { $script:TcUiaDialogScan = { param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [bool]$PrepareOnly = $false) Start-Sleep -Seconds 6 } }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $ok = & $mod { Initialize-TcUiaScanTypes -TimeoutSec 1 }
        $ms = $sw.ElapsedMilliseconds
        & $mod { param($s) $script:TcUiaDialogScan = $s } $origScan
        Check 'A4 Initialize-TcUiaScanTypes: a hanging preparation is abandoned at -TimeoutSec' ($ok -eq $false -and $ms -lt 3000) "$ms ms ok=$ok"
    }
    else { Check 'A4 Initialize-TcUiaScanTypes cap (skipped: types already loaded)' $true '' }

    # --- B: real scan, real EnumWindows, a pid without top-level windows ---
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { param($p) Find-TcIdeModalDialog -ProcessId $p -TimeoutSec 30 } $PID
    $inc = & $mod { param($d) Test-TcModalScanIncomplete $d } $r
    Check 'B1 real scan of a pid without windows -> complete, no dialog' ($null -eq $r -and -not $inc) ("{0} ms {1}" -f $sw.ElapsedMilliseconds, (J $r))
    $types = @('UiaScanWindows', 'UiaScanPidWindows', 'UiaScanNative', 'UiaScanButtonNative') | Where-Object { -not ([System.Management.Automation.PSTypeName]"TcAutomation.$_").Type }
    Check 'B2 all scan types compiled (one Add-Type)' (@($types).Count -eq 0) "missing: $($types -join ',')"
    $own = @([TcAutomation.UiaScanWindows]::TopLevelOf([uint32]$PID))
    $ownAll = @([TcAutomation.UiaScanPidWindows]::VisibleOf([uint32]$PID))
    Check 'B3 EnumWindows lists no window for this console process' ($own.Count -eq 0 -and $ownAll.Count -eq 0) "$($own.Count)/$($ownAll.Count)"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $ok = & $mod { Initialize-TcUiaScanTypes }
    Check 'B4 Initialize-TcUiaScanTypes: types present, fast once compiled' ($ok -eq $true -and $sw.ElapsedMilliseconds -lt 3000) "$($sw.ElapsedMilliseconds) ms"

    # --- C: mocked scans ---
    function Set-Scan([scriptblock]$Sb) { & $mod { param($s) $script:TcUiaDialogScan = $s } $Sb }

    # C1: preparation takes 2.5 s, the scan itself is instant; budget 1 s
    Set-Scan { param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [bool]$PrepareOnly = $false) if ($PrepareOnly) { Start-Sleep -Milliseconds 2500; return } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { param($p) Find-TcIdeModalDialog -ProcessId $p -TimeoutSec 1 } $PID
    $ms = $sw.ElapsedMilliseconds
    $inc = & $mod { param($d) Test-TcModalScanIncomplete $d } $r
    Check 'C1 slow cold start outside the -TimeoutSec budget -> complete, $null' ($null -eq $r -and -not $inc -and $ms -ge 2400) "$ms ms $(J $r)"

    # C2: the scan takes 3 s, budget 1 s
    Set-Scan { param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [bool]$PrepareOnly = $false) if ($PrepareOnly) { return }; Start-Sleep -Milliseconds 3000 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { param($p) Find-TcIdeModalDialog -ProcessId $p -TimeoutSec 1 } $PID
    $ms = $sw.ElapsedMilliseconds
    $inc = & $mod { param($d) Test-TcModalScanIncomplete $d } $r
    Check 'C2 scan over budget -> incomplete marker (not $null), reason timeout, returns at the budget' ($null -ne $r -and $inc -and $r.Reason -eq 'timeout' -and $r.TimeoutSec -eq 1 -and $r.ProcessId -eq $PID -and $ms -lt 2500) "$ms ms $(J $r)"
    Check 'C2 marker reads like an empty dialog record' ($r.Title -eq '' -and $r.Kind -eq 'scan-incomplete' -and $null -eq $r.ReloadTarget -and $r.Hwnd -eq 0) (J $r)

    # C3: preparation hangs; prepare timeout 1 s
    Set-Scan { param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [bool]$PrepareOnly = $false) if ($PrepareOnly) { Start-Sleep -Milliseconds 4000; return } }
    & $mod { $script:TcUiaScanPrepareTimeoutSec = 1 }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { param($p) Find-TcIdeModalDialog -ProcessId $p -TimeoutSec 1 } $PID
    $ms = $sw.ElapsedMilliseconds
    & $mod { $script:TcUiaScanPrepareTimeoutSec = $null }
    Check 'C3 preparation hangs -> incomplete, reason prepare-timeout' ((& $mod { param($d) Test-TcModalScanIncomplete $d } $r) -and $r.Reason -eq 'prepare-timeout' -and $ms -lt 3500) "$ms ms $(J $r)"

    # C4: the scan throws
    Set-Scan { param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [bool]$PrepareOnly = $false) if ($PrepareOnly) { return }; throw 'UIA boom (mock)' }
    $r = & $mod { param($p) Find-TcIdeModalDialog -ProcessId $p -TimeoutSec 5 } $PID
    Check 'C4 throwing scan -> incomplete, reason error' ((& $mod { param($d) Test-TcModalScanIncomplete $d } $r) -and $r.Reason -eq 'error' -and $r.Message -match 'UIA boom') (J $r)

    # C5: the scan writes an error and returns nothing
    Set-Scan { param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [bool]$PrepareOnly = $false) if ($PrepareOnly) { return }; Write-Error 'partial scan (mock)' }
    $r = & $mod { param($p) Find-TcIdeModalDialog -ProcessId $p -TimeoutSec 5 } $PID
    Check 'C5 error and no result -> incomplete, reason error' ((& $mod { param($d) Test-TcModalScanIncomplete $d } $r) -and $r.Reason -eq 'error') (J $r)

    # C6: a dialog
    Set-Scan { param([int]$TargetPid, [long]$MainHwnd, [int]$MaxText, [bool]$PrepareOnly = $false) if ($PrepareOnly) { return }; [PSCustomObject]@{ Title = 'TcXaeShell'; Text = 'Assertion Failed (mock)'; ClassName = '#32770'; IsModal = $true; Hwnd = [long]4242; Buttons = @(@{ Id = 1; Name = 'OK' }) } }
    $r = & $mod { param($p) Find-TcIdeModalDialog -ProcessId $p -TimeoutSec 5 } $PID
    Check 'C6 dialog found -> dialog record, not incomplete' ($r.Title -eq 'TcXaeShell' -and $r.Kind -eq 'unknown' -and $r.Hwnd -eq 4242 -and -not (& $mod { param($d) Test-TcModalScanIncomplete $d } $r)) (J $r)

    # unknown / gone pid: nothing to scan -> $null (unchanged)
    $r = & $mod { Find-TcIdeModalDialog -ProcessId 0 }
    Check 'C7 no pid -> $null' ($null -eq $r) ''
}
finally {
    & $mod { param($s) $script:TcUiaDialogScan = $s; $script:TcUiaScanPrepareTimeoutSec = $null } $origScan
}

# --- D: helpers ---
$marker = & $mod { New-TcModalScanIncomplete -ProcessId 77 -Reason 'timeout' -TimeoutSec 5 -ElapsedMs 5003 -PrepareMs 2100 -Message 'mock' }
$t = & $mod { param($m) @((Test-TcModalScanIncomplete $null), (Test-TcModalScanIncomplete @{ Title = 'x'; Text = '' }), (Test-TcModalScanIncomplete $m), (Test-TcModalScanIncomplete ([PSCustomObject]@{ ScanIncomplete = $true }))) } $marker
Check 'D1 Test-TcModalScanIncomplete: null / dialog false, marker true' ($t[0] -eq $false -and $t[1] -eq $false -and $t[2] -eq $true -and $t[3] -eq $true) ($t -join ',')
$r = & $mod { param($m) New-TcModalDialogResult -Dialog $m -Operation 'SolutionBuild.Build' -Data ([PSCustomObject]@{ x = 1 }) } $marker
Check 'D2 New-TcModalDialogResult(marker) -> MODAL_SCAN_INCOMPLETE, not IDE_MODAL_DIALOG' ((-not $r.success) -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $r.error.message -match "'SolutionBuild.Build' not attempted") (J $r)
Check 'D3 data: scanComplete false, dialog null, modalScan, caller data kept' ($r.data.scanComplete -eq $false -and $null -eq $r.data.dialog -and $r.data.modalScan.reason -eq 'timeout' -and $r.data.modalScan.prepareMs -eq 2100 -and $r.data.modalScan.ideProcessId -eq 77 -and $r.data.x -eq 1) (J $r.data)
Check 'D4 hint names the next step' ($r.error.hint -match 'Get-TcIdeModalDialog -TimeoutSec 15' -and $r.error.hint -match 'GetIdeModalDialog') "$($r.error.hint)"
$r = & $mod { New-TcModalDialogResult -Dialog @{ Title = 'TcXaeShell'; Text = 'Assertion Failed' } -Operation 'op' }
Check 'D5 a real dialog is still IDE_MODAL_DIALOG' ($r.error.code -eq 'IDE_MODAL_DIALOG') $r.error.code

# --- E: callers ---
$global:M = @{ Scans = 0; FirstIsClear = $false; Cleaned = $false; Closed = $false; Quit = $false }
& $mod {
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        $global:M.Scans++
        if ($global:M.FirstIsClear -and $global:M.Scans -eq 1) { return $null }
        New-TcModalScanIncomplete -ProcessId 4242 -Reason 'timeout' -TimeoutSec $TimeoutSec -Message 'mock: did not finish'
    }
}
try {
    function Set-CleanDte([switch]$NeverDone) {
        $sb = New-Object PSObject
        $sb | Add-Member -MemberType ScriptMethod -Name Clean -Value { param($wait) $global:M.Cleaned = $true }
        if ($NeverDone) { $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { 2 } }
        else { $sb | Add-Member -MemberType ScriptProperty -Name BuildState -Value { 3 } }
        $sb | Add-Member -MemberType ScriptProperty -Name LastBuildInfo -Value { 0 }
        $dte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ IsOpen = $true; SolutionBuild = $sb } }
        & $mod { param($d) $script:TcDte = $d; $script:TcIdeConnected = $true } $dte
    }

    # E1
    $global:M.Scans = 0; $global:M.FirstIsClear = $false; $global:M.Cleaned = $false
    Set-CleanDte
    $r = Clear-TcProject -TimeoutSec 30
    Check 'E1 Clear-TcProject pre-check, incomplete scan -> MODAL_SCAN_INCOMPLETE, Clean not called' ((-not $r.success) -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and -not $global:M.Cleaned -and $r.data.scanComplete -eq $false) (J $r)

    # E2
    $global:M.Scans = 0; $global:M.FirstIsClear = $true; $global:M.Cleaned = $false
    Set-CleanDte -NeverDone
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Clear-TcProject -TimeoutSec 5
    Check 'E2 Clear-TcProject poll: incomplete scan keeps polling -> CLEAN_TIMEOUT with data.modalScan (not IDE_MODAL_DIALOG)' ((-not $r.success) -and $r.error.code -eq 'CLEAN_TIMEOUT' -and $global:M.Cleaned -and $r.data.modalScan.reason -eq 'timeout' -and $sw.Elapsed.TotalSeconds -lt 15) ("{0:N1}s {1}" -f $sw.Elapsed.TotalSeconds, (J $r))

    # E3
    $global:M.Scans = 0; $global:M.FirstIsClear = $false; $global:M.Closed = $false; $global:M.Quit = $false
    $qsol = [PSCustomObject]@{ Mock = $true }
    $qsol | Add-Member -MemberType ScriptMethod -Name Close -Value { param($s) $global:M.Closed = $true }
    $qdte = [PSCustomObject]@{ Solution = $qsol }
    $qdte | Add-Member -MemberType ScriptMethod -Name Quit -Value { $global:M.Quit = $true }
    & $mod { param($d) $script:TcDte = $d; $script:TcIdeConnected = $true; $script:TcIdeProcessId = 4242; $script:TcIdeSelectedBy = 'launched' } $qdte
    $r = Disconnect-TcIde -Quit
    $still = & $mod { $null -ne $script:TcDte -and $script:TcIdeConnected }
    Check 'E3 Disconnect-TcIde -Quit, incomplete scan -> MODAL_SCAN_INCOMPLETE, nothing attempted, connection kept' ((-not $r.success) -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and -not $global:M.Closed -and -not $global:M.Quit -and $r.data.disconnected -eq $false -and $r.data.modalScan.reason -eq 'timeout' -and $still) (J $r)
    Check 'E3 hint names the Disconnect fallbacks' ($r.error.hint -match 'Get-TcIdeModalDialog -TimeoutSec 15' -and $r.error.hint -match 'data\.ownedBySession = true' -and $r.error.hint -match 'Disconnect-TcIde -Quit -Kill') "$($r.error.hint)"
    # E3b #227: the same IDE NOT launched by this session -> IDE_NOT_OWNED before the scan, nothing attempted, connection kept
    $global:M.Scans = 0
    & $mod { param($d) $script:TcDte = $d; $script:TcIdeConnected = $true; $script:TcIdeProcessId = 4242; $script:TcIdeSelectedBy = 'solution-match' } $qdte
    $r = Disconnect-TcIde -Quit -Kill
    $still = & $mod { $null -ne $script:TcDte -and $script:TcIdeConnected }
    Check 'E3b #227 Disconnect-TcIde -Quit -Kill on a not-owned IDE -> IDE_NOT_OWNED, no scan / close / quit, connection kept' ((-not $r.success) -and $r.error.code -eq 'IDE_NOT_OWNED' -and $global:M.Scans -eq 0 -and -not $global:M.Closed -and -not $global:M.Quit -and $r.data.disconnected -eq $false -and $r.data.ownedBySession -eq $false -and $still) (J $r)
    & $mod { $script:TcIdeProcessId = $null; $script:TcIdeSelectedBy = $null }

    # E4
    $r = & $mod { Get-TcTreeItemDialogResult -Operation 'ConsumeXml TIRC^x' }
    Check 'E4 tree-item gate -> MODAL_SCAN_INCOMPLETE' ($null -ne $r -and $r.error.code -eq 'MODAL_SCAN_INCOMPLETE') (J $r)
}
finally {
    & $mod { param($f) Set-Item -Path function:script:Find-TcIdeModalDialog -Value $f } $origFind
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null }
}

# M  #234: the real scan never reports the IDE main window as a dialog, also with a stale cached main
#    window handle. A child powershell.exe (STA, started by this test) shows WPF fixture windows; the real
#    scan ($origScan) runs against that child pid. Before #234 a stale non-zero MainHwnd switched the
#    title rule off and the main window caption '<sln> - Microsoft Visual Studio' matched the known-dialog
#    pattern: reported as kind unknown (measured 2026-11-13, VS2022 4026 zh-TW, $script:TcIdeMainHwnd set
#    to a handle that is no window). Now a non-modal window with UIA AutomationId VisualStudioMainWindow is
#    the main window. Fixture spec: 'title|automationId|owned' per window; 'owned' = that window opens an
#    owned ShowDialog child 'Fixture234 Options' (the shape of VS Tools.Options / Help.About).
#    M1 main window (id), stale MainHwnd -> no dialog        M2 the same, MainHwnd 0 (title rule) -> no dialog
#    M3 main window + 'TwinCAT XAE' window, stale -> that window, not the main window
#    M4 solution-title window WITHOUT the id, stale -> still reported (the title alone does not exclude it)
#    M5 main window (id) with an owned modal child, stale -> the child is reported (before #234 the stale
#       handle left $mainEl empty and the owned-dialog search never ran)
$fixtureScript = @'
param([string]$Spec, [string]$Signal, [string]$Stop)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$wins = @()
$i = 0
foreach ($item in ($Spec -split ';')) {
    $parts = $item -split '\|'
    $w = New-Object System.Windows.Window
    $w.Title = $parts[0]
    # UIA Name of a WPF window defaults to its content text; the VS2022 main window exposes its caption
    [System.Windows.Automation.AutomationProperties]::SetName($w, $parts[0])
    if ($parts.Count -gt 1 -and $parts[1]) { [System.Windows.Automation.AutomationProperties]::SetAutomationId($w, $parts[1]) }
    $w.Width = 320; $w.Height = 160; $w.Left = 40 + 30 * $i; $w.Top = 40 + 30 * $i
    $w.ShowActivated = $false; $w.ShowInTaskbar = $false
    $w.Content = New-Object System.Windows.Controls.TextBlock -Property @{ Text = 'tcauto #234 fixture' }
    $wins += $w
    if ($parts.Count -gt 2 -and $parts[2] -eq 'dialog') {
        # PR #278 S2: a top-level modal (ShowDialog, NO Owner) - shown once the dispatcher runs
        $dlg = $w
        $dlg.Add_Loaded({ Set-Content -LiteralPath $Signal -Value 'ready' })
        $null = $w.Dispatcher.BeginInvoke([Action]{ $null = $dlg.ShowDialog() })
        $i++
        continue
    }
    $w.Show()
    if ($parts.Count -gt 2 -and $parts[2] -eq 'owned') {
        $owner = $w
        $null = $w.Dispatcher.BeginInvoke([Action]{
            $c = New-Object System.Windows.Window
            $c.Title = 'Fixture234 Options'
            [System.Windows.Automation.AutomationProperties]::SetName($c, 'Fixture234 Options')
            $c.Owner = $owner; $c.Width = 200; $c.Height = 100; $c.ShowInTaskbar = $false
            $c.Content = New-Object System.Windows.Controls.TextBlock -Property @{ Text = 'owned modal' }
            $c.Add_Loaded({ Set-Content -LiteralPath $Signal -Value 'ready' })
            $script:wins += $c
            $null = $c.ShowDialog()
        })
    }
    $i++
}
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$deadline = (Get-Date).AddSeconds(60)
$timer.Add_Tick({ if ((Test-Path -LiteralPath $Stop) -or (Get-Date) -gt $deadline) { foreach ($x in @($script:wins)) { try { $x.Close() } catch { } }; [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } })
$timer.Start()
if ($Spec -notmatch '\|(owned|dialog)') { Set-Content -LiteralPath $Signal -Value 'ready' }
[System.Windows.Threading.Dispatcher]::Run()
'@
$work = Join-Path $env:TEMP ("tcauto-unit-234-{0}" -f [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $work | Out-Null
    $fixturePath = Join-Path $work 'fixture.ps1'
    Set-Content -LiteralPath $fixturePath -Value $fixtureScript -Encoding UTF8
    function Invoke-WithFixture([string]$Spec, [long[]]$MainHwnds) {
        $id = [guid]::NewGuid().ToString('N')
        $signal = Join-Path $work "$id.ready"
        $stop = Join-Path $work "$id.stop"
        $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-File', "`"$fixturePath`"", '-Spec', "`"$Spec`"", '-Signal', "`"$signal`"", '-Stop', "`"$stop`""
        $out = @{ error = $null }
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $signal) -and $sw.Elapsed.TotalSeconds -lt 45 -and -not $p.HasExited) { [System.Threading.Thread]::Sleep(100) }   # waits for the fixture's signal file, not a blind wait
            if (-not (Test-Path -LiteralPath $signal)) { $out.error = "fixture not ready (exited $($p.HasExited))"; return $out }
            foreach ($h in $MainHwnds) { $out[[string]$h] = & $origScan $p.Id $h 2000 }
        }
        finally {
            Set-Content -LiteralPath $stop -Value 'stop'
            if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }   # only the fixture process this test started
        }
        return $out
    }
    function Show-Hit($r, [string]$Key) { $h = $r[$Key]; "fixtureError=$($r.error) hit=" + $(if ($null -eq $h) { 'null' } else { ($h | Select-Object Title, Kind, ClassName | ConvertTo-Json -Compress) }) }
    $stale = [long]99999   # not a window handle: what a stale cached handle looks like to the scan
    $mainTitle = 'Fixture234 - Microsoft Visual Studio'

    $r = Invoke-WithFixture "$mainTitle|VisualStudioMainWindow" @($stale, 0)
    Check 'M1 main window (AutomationId VisualStudioMainWindow), stale MainHwnd -> no dialog' ($null -eq $r.error -and $null -eq $r[[string]$stale]) (Show-Hit $r ([string]$stale))
    Check 'M2 main window, MainHwnd 0 (title rule) -> no dialog' ($null -eq $r.error -and $null -eq $r['0']) (Show-Hit $r '0')

    $r = Invoke-WithFixture "$mainTitle|VisualStudioMainWindow;TwinCAT XAE|" @($stale)
    Check 'M3 main window + TwinCAT XAE window, stale MainHwnd -> the TwinCAT XAE window is reported' ($null -eq $r.error -and $null -ne $r[[string]$stale] -and [string]$r[[string]$stale].Title -eq 'TwinCAT XAE') (Show-Hit $r ([string]$stale))

    $r = Invoke-WithFixture "$mainTitle|" @($stale)
    Check 'M4 solution-title window without the AutomationId, stale MainHwnd -> still reported (fail closed)' ($null -eq $r.error -and $null -ne $r[[string]$stale] -and [string]$r[[string]$stale].Title -eq $mainTitle) (Show-Hit $r ([string]$stale))

    $r = Invoke-WithFixture "$mainTitle|VisualStudioMainWindow|owned" @($stale)
    Check 'M5 main window with an owned modal child, stale MainHwnd -> the child is reported' ($null -eq $r.error -and $null -ne $r[[string]$stale] -and [string]$r[[string]$stale].Title -eq 'Fixture234 Options') (Show-Hit $r ([string]$stale))

    # PR #278 S2: a top-level modal (ShowDialog, no owner) next to the main window with the id is reported. Measured
    # 2026-11-13 with this fixture: UIA reads IsModal = false for such a WPF window (also with the id), so a window
    # with the id AND IsModal = true cannot be built with WPF; that branch is covered by M7e (mocked UIA objects).
    $r = Invoke-WithFixture "$mainTitle|VisualStudioMainWindow;TwinCAT XAE||dialog" @($stale)
    Check 'M6 top-level ShowDialog window (TwinCAT XAE) + main window with the id, stale MainHwnd -> the dialog is reported' ($null -eq $r.error -and $null -ne $r[[string]$stale] -and [string]$r[[string]$stale].Title -eq 'TwinCAT XAE') (Show-Hit $r ([string]$stale))

    # PR #278 N2 / S2: Test-TcScanVsMainWindow (defined inside the real scan block) excludes a window only when the
    # id AND IsModal were read; any read failure leaves the window to the old checks. Mock UIA objects.
    $fnAst = $origScan.Ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Test-TcScanVsMainWindow' }, $true) | Select-Object -First 1
    Check 'M7 Test-TcScanVsMainWindow is defined in the scan block' ($null -ne $fnAst) ''
    if ($null -ne $fnAst) {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        . ([scriptblock]::Create($fnAst.Extent.Text))
        function New-MockCur([string]$Id, [switch]$Throw) {
            $c = New-Object PSObject
            if ($Throw) { $c | Add-Member -MemberType ScriptProperty -Name AutomationId -Value { throw 'AutomationId (mock)' } }
            else { $c | Add-Member -MemberType NoteProperty -Name AutomationId -Value $Id }
            $c
        }
        function New-MockEl([string]$Mode) {
            $e = New-Object PSObject
            $e | Add-Member -MemberType NoteProperty -Name Mode -Value $Mode
            $e | Add-Member -MemberType ScriptMethod -Name TryGetCurrentPattern -Value {
                switch ($this.Mode) {
                    'throw'      { throw 'TryGetCurrentPattern (mock)' }
                    'none'       { return $false }
                    'modalThrow' { $p = New-Object PSObject; $cur = New-Object PSObject; $cur | Add-Member -MemberType ScriptProperty -Name IsModal -Value { throw 'IsModal (mock)' }; $p | Add-Member NoteProperty Current $cur; $args[1].Value = $p; return $true }
                    default      { $args[1].Value = [PSCustomObject]@{ Current = [PSCustomObject]@{ IsModal = ($this.Mode -eq 'modal') } }; return $true }
                }
            }
            $e
        }
        $id = 'VisualStudioMainWindow'
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur -Throw) -Element (New-MockEl 'free') -ClassName 'HwndWrapper'
        Check 'M7a AutomationId read throws -> not excluded (old path)' (-not $t.IsMain -and -not $t.ModalRead) (J $t)
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur $id) -Element (New-MockEl 'throw') -ClassName 'HwndWrapper'
        Check 'M7b TryGetCurrentPattern throws -> not excluded, IsModal not handed on' (-not $t.IsMain -and -not $t.ModalRead) (J $t)
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur $id) -Element (New-MockEl 'modalThrow') -ClassName 'HwndWrapper'
        Check 'M7c IsModal getter fails (PowerShell hands back null) -> not excluded' (-not $t.IsMain -and -not $t.ModalRead) (J $t)
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur $id) -Element (New-MockEl 'none') -ClassName 'HwndWrapper'
        Check 'M7d no WindowPattern -> not excluded' (-not $t.IsMain -and -not $t.ModalRead) (J $t)
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur $id) -Element (New-MockEl 'modal') -ClassName 'HwndWrapper'
        Check 'M7e IsModal true -> not excluded, IsModal handed on' (-not $t.IsMain -and $t.ModalRead -and $t.IsModal) (J $t)
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur $id) -Element (New-MockEl 'free') -ClassName '#32770'
        Check 'M7f #32770 with the id -> not excluded' (-not $t.IsMain) (J $t)
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur 'Other') -Element (New-MockEl 'free') -ClassName 'HwndWrapper'
        Check 'M7g another id -> not excluded' (-not $t.IsMain -and -not $t.ModalRead) (J $t)
        $t = Test-TcScanVsMainWindow -Cur (New-MockCur $id) -Element (New-MockEl 'free') -ClassName 'HwndWrapper'
        Check 'M7h id read, IsModal false -> main window' ($t.IsMain -and $t.ModalRead -and -not $t.IsModal) (J $t)
    }
}
finally {
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
}

Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
