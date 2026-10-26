# Integration: lifecycle smoke test against a real runtime (UmRT / local XAR).
# Steps: Connect IDE -> set target -> Build -> Enable-TcConfig -Force -> ADS -> state/symbols/read
#        -> P0-2 auto-reconnect after re-activate -> P0-5 error codes -> P0-3 -NoLogin guard
#        -> restore PLC Run -> close IDE without saving.
# Every step appends one JSON line (step, cmdlet, elapsedMs, pass, code, result) to -LogPath;
# console prints only "PASS/FAIL <step> [cmdlet] <code> <ms>".
# Run in a fresh Windows PowerShell 5.1 process (clean COM state):
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Integration/lifecycle-smoke.ps1 `
#       -SolutionPath <sln> -ProgId TcXaeShell.DTE.15.0 -PlcProject plc -LogPath tests/Integration/logs/A.log
# Never sends ADS Reset (port 10000 or 851): Enable-TcConfig -Force / Set-TcSystemState -State Run
# use AdsState.Reset on port 10000, which UmRT ignores and must not receive, so the activation
# cycle uses ITcSysManager.StartRestartTwinCAT() instead (Invoke-UmRtCycle).
# Does not modify or save the solution.

param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [Parameter(Mandatory)][string]$ProgId,
    [string]$AmsNetId = '199.5.42.250.1.1',
    [string]$PlcProject,
    [Parameter(Mandatory)][string]$LogPath,
    [switch]$PreLaunch,
    # EnableForce: Enable-TcConfig -Force (system Run via ADS on port 10000).
    # StartRestart: Config -> ActivateConfiguration -> StartRestartTwinCAT() (Invoke-UmRtCycle).
    [ValidateSet('EnableForce', 'StartRestart')][string]$CycleMode = 'EnableForce',
    # Attach to an IDE this test session launched earlier (pid); it is treated as the own IDE
    # (watched, and closed at the end). Use instead of -PreLaunch.
    [int]$AttachPid = 0,
    # Optional: activate this solution platform right after "set target" (step 02b-platform),
    # e.g. 'TwinCAT OS (x64)' for a UmRT (Usermode Runtime). Step 02-set-target uses -NoPlatformSwitch (NetId only).
    [string]$SolutionPlatform,
    # Stop after 03b (Connect, target, Clean, Build): no Activate. For runs where the runtime must not
    # be activated (e.g. no valid license: a failing Activate pops 'Target system reports a fatal
    # error' in EVERY XAE connected to the target, other sessions included; measured 2026-10-25,
    # 4024 32-bit XAE Shell and 4026 VS2022 on the local UmRT).
    [switch]$StopAfterBuild,
    # Pass -AllowUnresolvedLibrary to Clear-TcProject (03a) and Build-TcProject (03): accept
    # LIBRARY_UNRESOLVED for a project copy that is known to miss libraries (A group: the Festo copy
    # without its Visu libraries, #45), see troubleshooting 'CLEAN_LIBRARY_UNRESOLVED' / 'LIBRARY_UNRESOLVED'.
    [switch]$AllowUnresolvedLibrary
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force
$mod = Get-Module TwinCATAutomation

$logDir = Split-Path -Parent $LogPath
if ($logDir -and -not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
Set-Content -Path $LogPath -Value '' -Encoding UTF8

$script:failCount = 0
# IDE processes the user already had open: never attached to, never closed, ignored in checks.
$script:preIdePids = @(Get-Process TcXaeShell*, devenv -ErrorAction SilentlyContinue | ForEach-Object { [int]$_.Id } | Where-Object { $_ -ne $AttachPid })
$script:ownIdePid = if ($AttachPid -gt 0) { $AttachPid } else { $null }

Add-Type -TypeDefinition @'
using System; using System.Collections.Generic; using System.Runtime.InteropServices; using System.Text;
public static class SmokeWin {
    delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    public static string[] Titles(int pid) {
        var list = new List<string>();
        EnumWindows((h, p) => { uint wp; GetWindowThreadProcessId(h, out wp);
            if (wp == (uint)pid && IsWindowVisible(h)) { var sb = new StringBuilder(512); GetWindowText(h, sb, 512); if (sb.Length > 0) list.Add(sb.ToString()); }
            return true; }, IntPtr.Zero);
        return list.ToArray();
    }
}
'@

function Write-StepLog {
    param([string]$Step, [string]$Cmdlet, [int]$ElapsedMs, [bool]$Pass, $Result, [string]$Note)
    $code = $null
    if ($null -ne $Result -and $Result.PSObject.Properties['error'] -and $null -ne $Result.error) { $code = $Result.error.code }
    $entry = [PSCustomObject]@{
        time      = (Get-Date).ToString('s')
        step      = $Step
        cmdlet    = $Cmdlet
        elapsedMs = $ElapsedMs
        pass      = $Pass
        code      = $code
        note      = $Note
        result    = $Result
    }
    Add-Content -Path $LogPath -Value ($entry | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
    if ($Pass) { $tag = 'PASS' } else { $tag = 'FAIL'; $script:failCount++ }
    $codeText = if ($code) { " $code" } else { '' }
    Write-Host ("{0} {1} [{2}]{3} {4}ms" -f $tag, $Step, $Cmdlet, $codeText, $ElapsedMs)
}

# Runs $Block, logs it, returns the result. $Check(result) decides pass/fail (default: success).
function Invoke-Step {
    param([string]$Step, [string]$Cmdlet, [scriptblock]$Block, [scriptblock]$Check, [string]$Note)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = $null
    $script:uiSync.step = $Step; $script:uiSync.stepStart = Get-Date
    try { $r = & $Block }
    catch { $r = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SCRIPT_EXCEPTION'; message = $_.Exception.Message } } }
    $script:uiSync.stepStart = $null
    if ($null -ne $script:uiSync.modal) {
        # Watchdog killed the IDE during this step: record it and abort the attempt.
        $sw.Stop()
        $r = [PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = $script:uiSync.modal; message = "$($script:uiSync.text) (own IDE killed at $($script:uiSync.killedAt))" }; stepResult = $r }
        Write-StepLog -Step $Step -Cmdlet $Cmdlet -ElapsedMs ([int]$sw.ElapsedMilliseconds) -Pass $false -Result $r -Note $Note
        throw 'ABORT_ATTEMPT'
    }
    $sw.Stop()
    $pass = if ($Check) { [bool](& $Check $r) } else { [bool]$r.success }
    Write-StepLog -Step $Step -Cmdlet $Cmdlet -ElapsedMs ([int]$sw.ElapsedMilliseconds) -Pass $pass -Result $r -Note $Note
    return $r
}

function Test-Abort {
    param($Result, [string]$Step)
    if ($null -ne $Result -and -not $Result.success -and $Result.error.code -eq 'IDE_BUSY') {
        $wins = @(Get-Process TcXaeShell*, devenv -ErrorAction SilentlyContinue | Select-Object Id, ProcessName, MainWindowTitle)
        Write-StepLog -Step "$Step-abort" -Cmdlet 'IDE_BUSY' -ElapsedMs 0 -Pass $false -Result $wins -Note 'IDE_BUSY: window titles recorded, aborting group'
        return $true
    }
    return $false
}

function Close-Ide {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $dte = & $mod { $script:TcDte }
    $note = ''
    # Never quit an IDE that is not ours: Connect-TcIde can hold an IDE that was already open
    # (solution-match / solution-blocked, #29), e.g. another agent's copy of the same solution.
    # Ours = the pid PreLaunch / -AttachPid recorded, or an IDE the module itself launched
    # (selectedBy launched / ownedBySession). "Not in preIdePids" is not enough: another agent
    # may have started an IDE during the run.
    $modPid = & $mod { $script:TcIdeProcessId }
    $modLaunched = [bool](& $mod { $script:TcIdeSelectedBy -eq 'launched' })
    $isOurs = ($null -ne $modPid) -and ((($script:ownIdePid) -and [int]$modPid -eq $script:ownIdePid) -or $modLaunched)
    if ($null -ne $dte -and -not $isOurs) {
        $note += "module IDE pid '$modPid' is not proven to be this run's IDE, not closed; "
        $dte = $null
    }
    if ($null -eq $dte) { $dte = $script:keepDte }
    if ($script:ownIdePid) {
        $titles = @([SmokeWin]::Titles($script:ownIdePid))
        Write-StepLog -Step '11y-ide-windows' -Cmdlet 'EnumWindows(own IDE pid)' -ElapsedMs 0 -Pass $true -Result ([PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ pid = $script:ownIdePid; titles = $titles } }) -Note 'visible top-level windows before close (dialogs show up here)'
    }
    try { & $mod { if ($script:TcAdsClient) { try { $script:TcAdsClient.Dispose() } catch { } } } } catch { }
    if ($null -ne $dte) {
        # Close without saving (SetTargetNetId / activate may have dirtied the project)
        try { $dte.Solution.Close($false); $note += 'Solution.Close(false); ' } catch { $note += "Solution.Close failed: $($_.Exception.Message); " }
        try { $dte.Quit(); $note += 'DTE.Quit(); ' } catch { $note += "Quit failed: $($_.Exception.Message); " }
    } else { $note += 'no DTE reference; ' }
    $null = Disconnect-TcIde
    $dte = $null
    $script:keepDte = $null
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    $left = @()
    for ($i = 0; $i -lt 60; $i++) {
        # Only our own IDE counts; IDEs the user opens during the run are ignored.
        $left = @(Get-Process TcXaeShell*, devenv -ErrorAction SilentlyContinue | Where-Object {
            if ($script:ownIdePid) { [int]$_.Id -eq $script:ownIdePid } else { $script:preIdePids -notcontains [int]$_.Id } })
        if ($left.Count -eq 0) { break }
        Start-Sleep -Milliseconds 500
    }
    $sw.Stop()
    $res = [PSCustomObject]@{ success = ($left.Count -eq 0); remaining = @($left | Select-Object Id, ProcessName, MainWindowTitle) }
    Write-StepLog -Step '11z-close-ide' -Cmdlet 'Solution.Close(false)+DTE.Quit' -ElapsedMs ([int]$sw.ElapsedMilliseconds) -Pass $res.success -Result $res -Note $note
}

$loginPath = $null
if ($PlcProject) { $loginPath = "TIPC^$PlcProject^$PlcProject Project" }

# Background UIAutomation watcher + watchdog (separate runspace, every 2 s):
#  - logs the own IDE's top-level windows to <LogPath>.ui.log when they change (read-only UIA);
#  - modal "Assertion Failed" / license / trial / security-code window -> record the text and
#    Stop-Process the OWN IDE pid (never another IDE, never TcSystemServiceUm);
#  - current step running longer than 240 s -> same kill (code STEP_TIMEOUT).
# Why a kill instead of waiting: while such a modal is up, the DTE call in progress (e.g.
# SolutionBuild.Build) blocks indefinitely - it does NOT return RPC_E_CALL_REJECTED, so
# Invoke-TcComRetry never gets a chance to retry. Killing the IDE makes the blocked COM call
# fail, the step returns, and Invoke-Step marks it IDE_MODAL_DIALOG / STEP_TIMEOUT.
# COM calls stay on the main thread (the DTE objects live there); only the watchdog is threaded.
$script:uiSync = [hashtable]::Synchronized(@{ license = $false; stop = $false; text = $null; modal = $null; step = $null; stepStart = $null; killedAt = $null })
$script:uiPs = $null
function Start-UiWatcher {
    if (-not $script:ownIdePid) { return }
    $uiLog = "$LogPath.ui.log"
    $rs = [runspacefactory]::CreateRunspace(); $rs.Open()
    $script:uiPs = [powershell]::Create(); $script:uiPs.Runspace = $rs
    $null = $script:uiPs.AddScript({
        param($procId, $uiLog, $sync)
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
        $A = [System.Windows.Automation.AutomationElement]
        $last = ''
        while (-not $sync.stop) {
            $snap = @()
            try {
                $cond = New-Object System.Windows.Automation.AndCondition(
                    (New-Object System.Windows.Automation.PropertyCondition($A::ProcessIdProperty, [int]$procId)),
                    (New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Window)))
                $textCond = New-Object System.Windows.Automation.PropertyCondition($A::ControlTypeProperty, [System.Windows.Automation.ControlType]::Text)
                foreach ($w in $A::RootElement.FindAll([System.Windows.Automation.TreeScope]::Children, $cond)) {
                    $texts = ''
                    try { $texts = (@($w.FindAll([System.Windows.Automation.TreeScope]::Descendants, $textCond) | ForEach-Object { $_.Current.Name } | Where-Object { $_ }) -join ' | ') } catch { $texts = "<FindAll failed>" }
                    $full = $texts
                    if ($texts.Length -gt 300) { $texts = $texts.Substring(0, 300) }
                    $snap += [PSCustomObject]@{ title = $w.Current.Name; texts = $texts }
                    if ($null -eq $sync.modal) {
                        if ("$($w.Current.Name) $full" -match 'licen|trial|security code') { $sync.license = $true; $sync.modal = 'IDE_MODAL_DIALOG'; $sync.text = "$($w.Current.Name) :: $full" }
                        elseif ($w.Current.Name -match 'Assertion Failed|Account Settings|帳戶設定') { $sync.modal = 'IDE_MODAL_DIALOG'; $sync.text = "$($w.Current.Name) :: $full" }
                    }
                }
            } catch { $snap += [PSCustomObject]@{ title = '<uia error>'; texts = $_.Exception.Message } }
            if ($null -eq $sync.modal -and $null -ne $sync.stepStart -and ((Get-Date) - $sync.stepStart).TotalSeconds -gt 240) {
                $sync.modal = 'STEP_TIMEOUT'; $sync.text = "step '$($sync.step)' exceeded 240 s"
            }
            if ($null -ne $sync.modal -and $null -eq $sync.killedAt) {
                $sync.killedAt = (Get-Date).ToString('s')
                $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
                if ($p -and $p.ProcessName -match '^(TcXaeShell|devenv)$') { try { Stop-Process -Id $procId -Force -Confirm:$false } catch { } }
                Add-Content -Path $uiLog -Value (([PSCustomObject]@{ time = $sync.killedAt; pid = $procId; action = 'Stop-Process own IDE'; reason = $sync.modal; step = $sync.step; text = $sync.text }) | ConvertTo-Json -Compress) -Encoding UTF8
            }
            $key = $snap | ConvertTo-Json -Compress -Depth 3
            if ($key -ne $last) {
                Add-Content -Path $uiLog -Value (([PSCustomObject]@{ time = (Get-Date).ToString('s'); pid = $procId; windows = $snap; license = $sync.license; licenseText = $sync.text }) | ConvertTo-Json -Compress -Depth 4) -Encoding UTF8
                $last = $key
            }
            Start-Sleep -Seconds 2
        }
    }).AddArgument($script:ownIdePid).AddArgument($uiLog).AddArgument($script:uiSync)
    $null = $script:uiPs.BeginInvoke()
}
function Stop-UiWatcher {
    if ($null -eq $script:uiPs) { return }
    $script:uiSync.stop = $true
    Start-Sleep -Seconds 3
    try { $script:uiPs.Stop(); $script:uiPs.Dispose() } catch { }
    $script:uiPs = $null
}
# Abort the group when the watcher saw a license / trial dialog.
function Test-LicenseAbort {
    param([string]$Step)
    if ($script:uiSync.license) {
        Write-StepLog -Step "$Step-license-abort" -Cmdlet 'UIAutomation watcher' -ElapsedMs 0 -Pass $false -Result ([PSCustomObject]@{ success = $false; data = [PSCustomObject]@{ text = $script:uiSync.text } }) -Note 'license/trial dialog in IDE: group stopped, nothing clicked'
        return $true
    }
    return $false
}

# Read-only dump of the IDE Error List (EnvDTE80 ToolWindows.ErrorList.ErrorItems), first 30 items.
function Write-ErrorList {
    param([string]$Step)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $items = @(); $err = $null
    try {
        $dte = & $mod { $script:TcDte }
        $ei = $dte.ToolWindows.ErrorList.ErrorItems
        $n = $ei.Count
        for ($i = 1; $i -le [Math]::Min($n, 30); $i++) {
            $it = $ei.Item($i)
            $d = [string]$it.Description; if ($d.Length -gt 300) { $d = $d.Substring(0, 300) }
            $items += [PSCustomObject]@{ level = [int]$it.ErrorLevel; description = $d; project = [string]$it.Project; file = [string]$it.FileName; line = [int]$it.Line }
        }
    } catch { $err = $_.Exception.Message }
    Write-StepLog -Step $Step -Cmdlet 'DTE.ToolWindows.ErrorList.ErrorItems' -ElapsedMs ([int]$sw.ElapsedMilliseconds) -Pass $true -Result ([PSCustomObject]@{ success = ($null -eq $err); data = [PSCustomObject]@{ count = $n; items = $items; error = $err } }) -Note 'ErrorLevel: 1=High(error) 2=Medium(warning) 4=Low(message)'
}

function Write-UmRt {
    param([string]$Step)
    $p = @(Get-Process TcSystemServiceUm -ErrorAction SilentlyContinue | Select-Object Id, StartTime, MainWindowTitle)
    Write-StepLog -Step $Step -Cmdlet 'Get-Process TcSystemServiceUm' -ElapsedMs 0 -Pass ($p.Count -gt 0) -Result ([PSCustomObject]@{ success = ($p.Count -gt 0); data = $p })
    return ($p.Count -gt 0)
}

# UmRT-safe activation cycle. Enable-TcConfig -Force switches to Run through
# Set-TcSystemState -State Run = ADS WriteControl AdsState.Reset(2) on port 10000, which UmRT
# ignores (stays in Config) and which must not be sent to UmRT. Instead:
#   Config (Reconfig, port 10000) -> ActivateConfiguration() -> poll 20 s
#   -> if still Config: ITcSysManager.StartRestartTwinCAT() -> wait port 10000 = Run
#   -> [Login] Enter-TcPlcOnline -> wait 851 -> PLC Run via temporary 851 client (AdsState.Run)
# The module ADS session is NOT touched, so the P0-2 auto-reconnect can be observed afterwards.
function Invoke-UmRtCycle {
    param([string]$P, [bool]$Login)
    $r = Invoke-Step "$P-set-config" 'Set-TcSystemState -State Config' { Set-TcSystemState -State Config -AmsNetId $AmsNetId -TimeoutSec 60 }
    if (-not $r.success) { return $false }
    $r = Invoke-Step "$P-activate" 'Enable-TcConfig (ActivateConfiguration only)' { Enable-TcConfig }
    if (Test-Abort $r $P) { return $false }
    if (-not $r.success) { return $false }

    $poll = Invoke-Step "$P-poll-20s" 'Get-TcSystemState (poll 20 s after activate)' {
        $trace = New-Object System.Collections.ArrayList
        $sw = [Diagnostics.Stopwatch]::StartNew(); $last = $null
        while ($sw.Elapsed.TotalSeconds -lt 20) {
            $s = Get-TcSystemState -AmsNetId $AmsNetId
            $st = if ($s.success) { $s.data.state } else { "ERR:$($s.error.code)" }
            if ($st -ne $last) { $null = $trace.Add([PSCustomObject]@{ ms = [int]$sw.ElapsedMilliseconds; state = $st }); $last = $st }
            if ($st -eq 'Run') { break }
            Start-Sleep -Milliseconds 500
        }
        [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ finalState = $last; trace = @($trace) } }
    } -Note 'does ActivateConfiguration() alone leave Config on UmRT?'

    if ($poll.data.finalState -ne 'Run') {
        $r = Invoke-Step "$P-startrestart" 'ITcSysManager.StartRestartTwinCAT()' {
            & $mod { Invoke-TcComRetry -OperationName 'StartRestartTwinCAT' -ScriptBlock { (Get-TcSysManager).StartRestartTwinCAT() } | Out-Null }
            [PSCustomObject]@{ success = $true }
        }
        if (Test-Abort $r $P) { return $false }
        if (-not $r.success) { return $false }
        $r = Invoke-Step "$P-wait-run" 'Wait-TcAdsState -Port 10000 -TargetState Run' {
            $w = & $mod { param($n) Wait-TcAdsState -AmsNetId $n -Port 10000 -TargetState Run -TimeoutSec 120 } $AmsNetId
            [PSCustomObject]@{ success = [bool]$w.Reached; data = [PSCustomObject]$w }
        }
        if (-not $r.success) { $null = Write-UmRt "$P-umrt-alive"; return $false }
    }
    $null = Write-UmRt "$P-umrt-alive"

    if ($Login) {
        & $mod { try { $null = Get-TcSysManager -Refresh } catch { } }
        $r = Invoke-Step "$P-login" 'Enter-TcPlcOnline' { if ($loginPath) { Enter-TcPlcOnline -PlcProjectPath $loginPath } else { Enter-TcPlcOnline } }
        if (Test-Abort $r $P) { return $false }
        if (-not $r.success) { return $false }
        $r = Invoke-Step "$P-wait-851" 'Wait-TcAdsState -Port 851 -TargetState Any' {
            $w = & $mod { param($n) Wait-TcAdsState -AmsNetId $n -Port 851 -TargetState Any -TimeoutSec 60 } $AmsNetId
            [PSCustomObject]@{ success = [bool]$w.Reached; data = [PSCustomObject]$w }
        }
        if (-not $r.success) { return $false }
        $r = Invoke-Step "$P-plc-run" 'WriteControl Run via temporary 851 client' {
            $w = & $mod {
                param($n)
                $c = New-TcAdsClient -AmsNetId $n -Port 851
                try {
                    $si = New-Object TwinCAT.Ads.StateInfo
                    $si.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], 5)  # Run (never Reset)
                    $si.DeviceState = 0
                    $c.WriteControl($si)
                } finally { try { $c.Dispose() } catch { } }
                Wait-TcAdsState -AmsNetId $n -Port 851 -TargetState Run -TimeoutSec 60
            } $AmsNetId
            [PSCustomObject]@{ success = [bool]$w.Reached; data = [PSCustomObject]$w }
        }
        if (-not $r.success) { return $false }
    }
    else {
        $null = Invoke-Step "$P-wait-851-10s" 'Wait-TcAdsState -Port 851 -TargetState Any (10 s, no login)' {
            $w = & $mod { param($n) Wait-TcAdsState -AmsNetId $n -Port 851 -TargetState Any -TimeoutSec 10 } $AmsNetId
            [PSCustomObject]@{ success = $true; data = [PSCustomObject]$w }
        } -Note 'Reached=false means no boot project (port 851 absent)'
    }
    return $true
}

try {
    $null = Write-UmRt '00-umrt-alive-start'
    $null = Invoke-Step '00-system-state-start' 'Get-TcSystemState' { Get-TcSystemState -AmsNetId $AmsNetId } { param($x) $true }
    # 0. Optional pre-launch (workaround for the Connect-TcIde launch race: right after
    #    CreateInstance, DTE.MainWindow can still be null -> "property 'Visible' cannot be found"
    #    -> IDE_LAUNCH_FAILED plus an orphan IDE). Launch here, wait until MainWindow/Solution
    #    are ready, keep the reference alive; Connect-TcIde then attaches through the ROT.
    if ($PreLaunch) {
        $null = Invoke-Step '00-prelaunch' "CreateInstance($ProgId)" {
            $t = [Type]::GetTypeFromProgID($ProgId)
            $script:keepDte = [Activator]::CreateInstance($t)
            $ready = $false; $polls = 0; $deadline = (Get-Date).AddSeconds(120)
            while ((Get-Date) -lt $deadline) {
                $polls++
                try {
                    if ($null -ne $script:keepDte.MainWindow -and $null -ne $script:keepDte.Solution) {
                        $script:keepDte.MainWindow.Visible = $true; $ready = $true; break
                    }
                } catch { }
                Start-Sleep -Milliseconds 500
            }
            # Wait until OUR new IDE process (not one the user already had open) is in the ROT
            $inRot = $false
            while ($ready -and (Get-Date) -lt $deadline -and -not $inRot) {
                # The pid of THE instance we created (its main window), not just any new ROT entry:
                # another agent may launch an IDE at the same time.
                $kpid = 0
                try { $kpid = [int](& $mod { param($d, $p) (Get-TcIdeProcessId -Dte $d -ProgId $p).ProcessId } $script:keepDte $ProgId) } catch { $kpid = 0 }
                $own = @(& $mod { Get-AllComObjects -IncludeDisplayName } | Where-Object { $_['ProcessId'] -and [int]$_['ProcessId'] -eq $kpid })
                if ($kpid -gt 0 -and $own.Count -gt 0) { $inRot = $true; $script:ownIdePid = $kpid }
                else { Start-Sleep -Milliseconds 500 }
            }
            # Connect-TcIde -SolutionPath only attaches to an instance that already has the solution
            # open (an empty IDE is never reused: it could be the user's). Open the solution in OUR
            # instance first so that Connect-TcIde selects it by 'solution-match'.
            $preOpened = $false
            if ($inRot) {
                try { $script:keepDte.Solution.Open($SolutionPath) } catch { }
                $openDeadline = (Get-Date).AddSeconds(180)
                while ((Get-Date) -lt $openDeadline) {
                    try { if ($script:keepDte.Solution.IsOpen -and $script:keepDte.Solution.Projects.Count -gt 0) { $preOpened = $true; break } } catch { }
                    Start-Sleep -Milliseconds 500
                }
            }
            [PSCustomObject]@{ success = ($ready -and $inRot); data = [PSCustomObject]@{ ready = $ready; inRot = $inRot; polls = $polls; version = $script:keepDte.Version; ownPid = $script:ownIdePid; preExistingIdePids = $script:preIdePids; solutionPreOpened = $preOpened } }
        }
    }

    Start-UiWatcher

    # 1. Connect IDE
    $r = Invoke-Step '01-connect-ide' 'Connect-TcIde' { Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId } { param($x) $x.success -and $x.data.sysManagerAvailable }
    if (Test-Abort $r '01') { return }
    if (-not $r.success) { return }
    # Known race (4024): sysManagerAvailable=false + 'no TwinCAT project found' warning right after
    # the solution opens; later cmdlets resolve the SysManager lazily, so this does not stop the flow.

    # 2. Set target
    $null = Invoke-Step '02-set-target' 'Set-TcTarget' { Set-TcTarget -AmsNetId $AmsNetId -NoPlatformSwitch }
    if (-not [string]::IsNullOrWhiteSpace($SolutionPlatform)) {
        # 4026: the active solution platform must match the target platform ('TwinCAT OS (x64)'
        # for a local UmRT), otherwise ActivateConfiguration() silently fails (ACTIVATE_FAILED).
        $null = Invoke-Step '02b-platform' 'Set-TcTarget -Platform' { Set-TcTarget -AmsNetId $AmsNetId -Platform $SolutionPlatform } -Note "platform '$SolutionPlatform'"
    }
    $null = Invoke-Step '02b-verify-target' 'ITcSysManager.GetTargetNetId' {
        $sm = & $mod { $script:TcSysManager }
        [PSCustomObject]@{ success = $true; data = [PSCustomObject]@{ targetNetId = $sm.GetTargetNetId() } }
    } { param($x) $x.data.targetNetId -eq $AmsNetId }

    # 3a. Clean before build (repeated open/close of the solution left the XAE in a state where
    #     Build raised a modal "Assertion Failed" window).
    #     Public cmdlet (#18): the old inline $script:TcDte.Solution.SolutionBuild.Clean() hit a
    #     $null Solution / SolutionBuild right after Connect-TcIde; Clear-TcProject polls them
    #     (data.nullReads) and then waits for BuildState = Done.
    $null = Invoke-Step '03a-clean' 'Clear-TcProject' { Clear-TcProject -TimeoutSec 120 -AllowUnresolvedLibrary:$AllowUnresolvedLibrary }

    # 3. Build (build output text dropped from the log; only counts kept)
    $r = Invoke-Step '03-build' 'Build-TcProject' { $b = Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary; if ($b.data -and $b.data.PSObject.Properties['messages']) { $b.data.PSObject.Properties.Remove('messages') }; $b }
    Write-ErrorList '03b-errorlist-after-build'
    if (Test-Abort $r '03') { return }
    if (-not $r.success) { return }
    if ($StopAfterBuild) { return }

    # 4. Activate full cycle
    if ($CycleMode -eq 'EnableForce') {
        $r = Invoke-Step '04-enable-force' 'Enable-TcConfig -Force -TimeoutSec 180' { Enable-TcConfig -Force -TimeoutSec 180 }
        $null = Write-UmRt '04-umrt-alive'
        if (-not $r.success) { Write-ErrorList '04b-errorlist-after-activate' }
        if (Test-LicenseAbort '04') { return }
        if (Test-Abort $r '04') { return }
        # Known module issue: step set-plc-run sends WriteControl Run although 851 already reports
        # Run (boot project autostart) -> ADS 0x712 ADS_INVALID_STATE. When the system restarted and
        # the PLC is in Run anyway, keep going so the remaining checks still run.
        if (-not $r.success -and -not ($r.data.restarted -and $r.data.plcState -eq 'Run')) { return }
    }
    elseif (-not (Invoke-UmRtCycle -P '04' -Login $true)) { return }

    # 5. ADS
    $null = Invoke-Step '05-connect-ads' 'Connect-TcAds' { Connect-TcAds }

    # 6. State + symbols
    $null = Invoke-Step '06-plc-state' 'Get-TcPlcState' { Get-TcPlcState } { param($x) $x.success -and $x.data.state -eq 'Run' }
    $sym = Invoke-Step '06b-symbols' 'Get-TcSymbols' {
        $s = Get-TcSymbols
        if (-not $s.success) { return $s }
        $all = @($s.data)
        # Prefer symbols starting with MAIN (MAIN., MAIN_GantryCylinder., ...); otherwise any symbol
        # outside TwinCAT_SystemInfoVarList / *Constants. Pick the first basic-typed one.
        $main = @($all | Where-Object { $_.path -match '^MAIN' })
        $other = @($all | Where-Object { $_.path -notmatch 'TwinCAT_SystemInfoVarList|Constants' })
        $isPrim = { param($s) $s.type -match '^(BOOL|INT|DINT|REAL|LREAL)$' }
        $pick = @($main | Where-Object { & $isPrim $_ }) | Select-Object -First 1
        if ($null -eq $pick) { $pick = @($other | Where-Object { & $isPrim $_ }) | Select-Object -First 1 }
        $first = if ($main.Count -gt 0) { $main[0] } else { $null }
        [PSCustomObject]@{ success = ($null -ne $pick); data = [PSCustomObject]@{
            total = $all.Count; mainCount = $main.Count; firstMain = $first; picked = $pick } }
    }
    $symPath = $sym.data.picked.path
    if (-not $symPath) { return }

    # 7. Read
    $null = Invoke-Step '07-read' 'Read-TcVariable' { Read-TcVariable -Path $symPath }

    # 8. P0-2: re-activate, then read WITHOUT Connect-TcAds
    if ($CycleMode -eq 'EnableForce') {
        $r = Invoke-Step '08-enable-force-2' 'Enable-TcConfig -Force -TimeoutSec 180' { Enable-TcConfig -Force -TimeoutSec 180 }
        $script:enable8 = $r
        $null = Write-UmRt '08-umrt-alive'
        if (Test-LicenseAbort '08') { return }
        if (Test-Abort $r '08') { return }
    }
    elseif (-not (Invoke-UmRtCycle -P '08' -Login $true)) { return }
    $null = Invoke-Step '08b-read-after-restart' 'Read-TcVariable (no Connect-TcAds)' { Read-TcVariable -Path $symPath } {
        param($x)
        # Either Read auto-reconnected, or Enable-TcConfig's reconnect step already restored the session.
        $enableReconnected = @($script:enable8.data.steps | Where-Object { $_.step -eq 'reconnect' -and $_.ok }).Count -gt 0
        $x.success -and (($x.data.reconnected -eq $true) -or $enableReconnected)
    } -Note 'expect success and (reconnected=true or Enable-TcConfig steps contain reconnect ok)'

    # 9. P0-5 error codes
    $null = Invoke-Step '09-ads-port-853' 'Connect-TcAds -Port 853' { Connect-TcAds -AmsNetId $AmsNetId -Port 853 } { param($x) (-not $x.success) -and $x.error.code -eq 'ADS_PORT_NOT_FOUND' -and $x.error.hint }
    $sess = & $mod { [PSCustomObject]@{ netId = $script:TcAdsAmsNetId; port = $script:TcAdsPort; connected = $script:TcAdsConnected } }
    Write-StepLog -Step '09a-session-after-853' -Cmdlet '(module state)' -ElapsedMs 0 -Pass $true -Result $sess -Note 'cached session after failed 853 connect'
    $null = Invoke-Step '09b-symbol-missing-direct' 'Read-TcVariable MAIN.__not_exist__ (right after 853 fail)' { Read-TcVariable -Path 'MAIN.__not_exist__' } { param($x) (-not $x.success) -and $x.error.code -eq 'SYMBOL_NOT_FOUND' -and $x.error.hint } -Note 'informational: does auto-reconnect recover after a failed 853 connect'
    $null = Invoke-Step '09c-reconnect-851' 'Connect-TcAds' { Connect-TcAds }
    $null = Invoke-Step '09d-symbol-missing' 'Read-TcVariable MAIN.__not_exist__' { Read-TcVariable -Path 'MAIN.__not_exist__' } { param($x) (-not $x.success) -and $x.error.code -eq 'SYMBOL_NOT_FOUND' -and $x.error.hint }

    # 10. P0-3 -NoLogin guard
    $null = Invoke-Step '10-logout' 'Exit-TcPlcOnline' { Exit-TcPlcOnline }
    if ($CycleMode -eq 'EnableForce') {
        $r = Invoke-Step '10b-enable-nologin' 'Enable-TcConfig -Force -NoLogin -TimeoutSec 120' { Enable-TcConfig -Force -NoLogin -TimeoutSec 120 }
        $null = Write-UmRt '10b-umrt-alive'
        if (Test-LicenseAbort '10b') { return }
        if (Test-Abort $r '10b') { return }
    }
    elseif (-not (Invoke-UmRtCycle -P '10b' -Login $false)) { return }
    $null = Invoke-Step '10c-connect-ads' 'Connect-TcAds' { Connect-TcAds } { param($x) $true } -Note 'informational: 851 may not exist without boot project'
    $null = Invoke-Step '10d-plc-run-nologin' 'Set-TcPlcState -State Run' { Set-TcPlcState -State Run } { param($x) ($x.success) -or $x.error.code -eq 'PLC_NOT_LOADED' } -Note 'expect PLC_NOT_LOADED, or success if UmRT kept a boot project'

    # 11. Restore PLC Run
    $r = Invoke-Step '11-login' 'Enter-TcPlcOnline' { if ($loginPath) { Enter-TcPlcOnline -PlcProjectPath $loginPath } else { Enter-TcPlcOnline } }
    if (Test-Abort $r '11') { return }
    $null = Invoke-Step '11b-connect-ads' 'Connect-TcAds' { Connect-TcAds }
    $null = Invoke-Step '11c-plc-run' 'Set-TcPlcState -State Run' { Set-TcPlcState -State Run }
    $null = Invoke-Step '11d-plc-state' 'Get-TcPlcState' { Get-TcPlcState } { param($x) $x.success -and $x.data.state -eq 'Run' }
    $null = Invoke-Step '11e-disconnect-ads' 'Disconnect-TcAds' { Disconnect-TcAds }
}
catch {
    if ("$_" -match 'ABORT_ATTEMPT') {
        Write-StepLog -Step 'abort' -Cmdlet 'watchdog' -ElapsedMs 0 -Pass $false -Result ([PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = $script:uiSync.modal; message = $script:uiSync.text }; data = [PSCustomObject]@{ step = $script:uiSync.step; killedAt = $script:uiSync.killedAt } }) -Note 'attempt aborted by watchdog'
    }
    else {
        Write-StepLog -Step 'abort' -Cmdlet 'script' -ElapsedMs 0 -Pass $false -Result ([PSCustomObject]@{ success = $false; error = [PSCustomObject]@{ code = 'SCRIPT_EXCEPTION'; message = "$_" } })
    }
}
finally {
    Stop-UiWatcher
    Close-Ide
    $null = Write-UmRt '12-umrt-alive-end'
    Write-Host "DONE failures=$script:failCount log=$LogPath"
}
