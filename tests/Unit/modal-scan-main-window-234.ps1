# Unit: #234 the dialog scan never reports the IDE main window as a dialog, even when the cached
# main window handle ($script:TcIdeMainHwnd) is stale. No IDE needed: a child powershell.exe (STA)
# shows WPF fixture windows; the real scan ($script:TcUiaDialogScan) runs against that child pid.
# Before #234 a stale non-zero MainHwnd switched off the title rule, the real main window
# (caption '<solution> - Microsoft Visual Studio') matched the known-dialog pattern and came back as
# kind unknown with the Solution Explorer / Error List text (measured 2026-11-13, VS2022 4026 zh-TW,
# by setting $script:TcIdeMainHwnd to a handle that is no window). The IDE main window is now also
# recognised by its UIA AutomationId 'VisualStudioMainWindow' (the WPF main window of VS2022), not
# only by the cached handle or the title. Fail closed: only a NON-modal window with that id.
#   M1 main window (AutomationId VisualStudioMainWindow), MainHwnd stale -> no dialog
#   M2 the same with MainHwnd 0 (title rule, unchanged) -> no dialog
#   M3 main window + a second window titled 'TwinCAT XAE' (no id), MainHwnd stale -> that window is
#      reported, the main window is not
#   M4 a solution-title window WITHOUT the AutomationId, MainHwnd stale -> still reported (the title
#      alone does not exclude a window while a handle is cached)
#   powershell.exe -NoProfile -File tests/Unit/modal-scan-main-window-234.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# Child process: shows the requested WPF windows (title|automationId pairs), writes 'ready' to
# the signal file, runs the dispatcher until the stop file exists (at most 60 s).
$fixtureScript = @'
param([string]$Spec, [string]$Signal, [string]$Stop)
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
$wins = @()
$i = 0
foreach ($item in ($Spec -split ';')) {
    $parts = $item -split '\|', 2
    $w = New-Object System.Windows.Window
    $w.Title = $parts[0]
    # UIA Name of a WPF window defaults to its content text; the VS2022 main window exposes its caption
    [System.Windows.Automation.AutomationProperties]::SetName($w, $parts[0])
    if ($parts.Count -gt 1 -and $parts[1]) { [System.Windows.Automation.AutomationProperties]::SetAutomationId($w, $parts[1]) }
    $w.Width = 320; $w.Height = 160; $w.Left = 40 + 30 * $i; $w.Top = 40 + 30 * $i
    $w.ShowActivated = $false; $w.ShowInTaskbar = $false
    $w.Content = New-Object System.Windows.Controls.TextBlock -Property @{ Text = 'tcauto #234 fixture' }
    $w.Show()
    $wins += $w
    $i++
}
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$deadline = (Get-Date).AddSeconds(60)
$timer.Add_Tick({ if ((Test-Path -LiteralPath $Stop) -or (Get-Date) -gt $deadline) { foreach ($x in $wins) { $x.Close() }; [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } })
$timer.Start()
Set-Content -LiteralPath $Signal -Value 'ready'
[System.Windows.Threading.Dispatcher]::Run()
'@
$work = Join-Path $env:TEMP ("tcauto-unit-234-{0}" -f [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
$fixturePath = Join-Path $work 'fixture.ps1'
Set-Content -LiteralPath $fixturePath -Value $fixtureScript -Encoding UTF8

function Invoke-WithFixture([string]$Spec, [long[]]$MainHwnds) {
    $id = [guid]::NewGuid().ToString('N')
    $signal = Join-Path $work "$id.ready"
    $stop = Join-Path $work "$id.stop"
    $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-STA', '-File', "`"$fixturePath`"", '-Spec', "`"$Spec`"", '-Signal', "`"$signal`"", '-Stop', "`"$stop`""
    $out = @{}
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not (Test-Path -LiteralPath $signal) -and $sw.Elapsed.TotalSeconds -lt 45 -and -not $p.HasExited) { [System.Threading.Thread]::Sleep(100) }   # wait for the fixture process, not a blind wait
        if (-not (Test-Path -LiteralPath $signal)) { $out['error'] = "fixture not ready (exited $($p.HasExited))"; return $out }
        foreach ($h in $MainHwnds) {
            $out[[string]$h] = & $mod { param($fpid, $hw) & $script:TcUiaDialogScan $fpid $hw 2000 } $p.Id $h
        }
    }
    finally {
        Set-Content -LiteralPath $stop -Value 'stop'
        if (-not $p.WaitForExit(10000)) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }   # only the fixture process this test started
    }
    return $out
}
function Show([object]$Hit) { if ($null -eq $Hit) { 'null' } else { ($Hit | Select-Object Title, Kind, ClassName | ConvertTo-Json -Compress) } }

$stale = [long]99999   # not a window handle: what a stale cached handle looks like to the scan
$mainTitle = 'Fixture234 - Microsoft Visual Studio'

$r = Invoke-WithFixture "$mainTitle|VisualStudioMainWindow" @($stale, 0)
Check 'fixture started' (-not $r.ContainsKey('error')) "$($r['error'])"
Check 'M1 main window (AutomationId VisualStudioMainWindow), stale MainHwnd -> no dialog' ($null -eq $r[[string]$stale] -and -not $r.ContainsKey('error')) (Show $r[[string]$stale])
Check 'M2 main window, MainHwnd 0 (title rule) -> no dialog' ($null -eq $r['0'] -and -not $r.ContainsKey('error')) (Show $r['0'])

$r = Invoke-WithFixture "$mainTitle|VisualStudioMainWindow;TwinCAT XAE|" @($stale)
$hit = $r[[string]$stale]
Check 'M3 main window + TwinCAT XAE window, stale MainHwnd -> the TwinCAT XAE window is reported' ($null -ne $hit -and [string]$hit.Title -eq 'TwinCAT XAE') (Show $hit)

$r = Invoke-WithFixture "$mainTitle|" @($stale)
$hit = $r[[string]$stale]
Check 'M4 solution-title window without the AutomationId, stale MainHwnd -> still reported (fail closed)' ($null -ne $hit -and [string]$hit.Title -eq $mainTitle) (Show $hit)

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
"$fail failed"
exit $fail
