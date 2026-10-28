<#
.SYNOPSIS
    Experiment: which nFlags value does ITcSmTreeItem.Login(nFlags) accept on TwinCAT 3.1.4026?
.DESCRIPTION
    2026-10-19: Login(3) made the XAE show the modal
    "TwinCAT PLC Control - Login aborted: Conflicting flag settings detected ('Regular' and '0x00000002')"
    every time the IDE was launched with UserControl=true. This script activates the config
    without login (Enable-TcConfig -Force -NoLogin), then calls Login(<Flag>) directly on the
    "<Plc> Project" tree item and records: exception text, port 851 state before/after, any modal
    dialog, and whether Set-TcPlcState Run + Read-TcVariable work afterwards.
    Changes the running machine (Activate + download). Use a solution you own.
.EXAMPLE
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Integration\login-flag-experiment.ps1 -Flag 1
#>
param(
    [Parameter(Mandatory)][string]$SolutionPath,
    [int]$Flag = 1,
    [string]$ProgId = 'TcXaeShell.DTE.15.0',
    [string]$AmsNetId = '199.5.42.250.1.1',
    [string]$Symbol = 'MAIN_GantryCylinder.Acc',
    [string]$LogPath = '',
    [switch]$SilentMode,
    [switch]$SuppressUI,
    # Pass -AllowUnresolvedLibrary to Build-TcProject: accept LIBRARY_UNRESOLVED (project with missing libraries, #45 / #56). Since #61 that build is never complete: a later Enable-TcConfig / login still refuses with BUILD_REQUIRED.
    [switch]$AllowUnresolvedLibrary
)

# $PSScriptRoot is empty inside param() defaults on PS 5.1 -File, so resolve here.
$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
if ([string]::IsNullOrWhiteSpace($LogPath)) { $LogPath = Join-Path $scriptRoot "logs\login-flag-$Flag.txt" }

$VerbosePreference = 'SilentlyContinue'
Import-Module (Join-Path $scriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$dir = Split-Path $LogPath
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
function L($m) {
    $line = '{0} {1}' -f (Get-Date -Format 'HH:mm:ss.fff'), $m
    [IO.File]::AppendAllText($LogPath, $line + [Environment]::NewLine)
    Write-Output $line
}
function J($o) { try { ($o | ConvertTo-Json -Compress -Depth 4) } catch { [string]$o } }

L "=== Login($Flag) experiment start pid=$PID ==="
try {
    $c = Connect-TcIde -SolutionPath $SolutionPath -ProgId $ProgId
    L ("connect: " + (J $c))
    if (-not $c.success) { exit 1 }
    L ("settarget: " + (J (Set-TcTarget -AmsNetId $AmsNetId -NoPlatformSwitch)))

    # Automation Interface "silent mode": ITcAutomationSettings via DTE.GetObject("TcAutomationSettings")
    if ($SilentMode -or $SuppressUI) {
        & (Get-Module TwinCATAutomation) {
            param($silent, $suppress, $logFn)
            $dte = $script:TcDte
            if ($suppress) {
                try { $dte.SuppressUI = $true; & $logFn "DTE.SuppressUI = true" } catch { & $logFn ("SuppressUI ERR: " + $_.Exception.Message) }
            }
            if ($silent) {
                try {
                    $settings = $dte.GetObject('TcAutomationSettings')
                    & $logFn ("TcAutomationSettings members: " + (($settings | Get-Member -MemberType Property | ForEach-Object { $_.Name }) -join ', '))
                    & $logFn ("SilentMode before: " + $settings.SilentMode)
                    $settings.SilentMode = $true
                    & $logFn ("SilentMode after: " + $settings.SilentMode)
                }
                catch { & $logFn ("TcAutomationSettings ERR: " + $_.Exception.Message) }
            }
        } ([bool]$SilentMode) ([bool]$SuppressUI) ${function:L}
    }
    $b = Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
    L ("build: success=$($b.success) codeErrors=$(@($b.data.codeErrors).Count)")
    $e = Enable-TcConfig -Force -NoLogin -TimeoutSec 120
    L ("enable-nologin: success=$($e.success) steps=" + ((@($e.data.steps) | ForEach-Object { "$($_.step):$($_.ok)" }) -join ','))
    if (-not $e.success) { L ("enable error: " + (J $e.error)); exit 1 }

    $mod = Get-Module TwinCATAutomation
    $sm = & $mod { Get-TcSysManager }
    $path = & $mod { param($s) Resolve-TcPlcProjectPath -SysManager $s } $sm
    L "plc project path: $path"
    $item = $sm.LookupTreeItem($path)

    $st0 = & $mod { param($n) Wait-TcAdsState -AmsNetId $n -Port 851 -TargetState Any -TimeoutSec 3 } $AmsNetId
    L ("851 before login: reached=$($st0.Reached) state=$($st0.State)")

    # Watcher: a separate STA process polls Get-TcIdeModalDialog (sees dialogs owned by the
    # main window too) every 3 s and appends to the log, because a blocked Login() never returns.
    $idePid = [int]$c.data.ideProcessId
    $modulePath = Join-Path $scriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
    $watchScript = "Import-Module '$modulePath' -Force -WarningAction SilentlyContinue; " +
        "`$m = Get-Module TwinCATAutomation; `$end = (Get-Date).AddSeconds(240); " +
        "while ((Get-Date) -lt `$end) { `$d = & `$m { param(`$p) Get-TcIdeModalDialog -ProcessId `$p -TimeoutSec 5 } $idePid; " +
        "if (`$d) { [IO.File]::AppendAllText('$LogPath', ('{0} WATCHER dialog: {1} | {2}' -f (Get-Date -Format 'HH:mm:ss.fff'), `$d.Title, `$d.Text) + [Environment]::NewLine); break }; " +
        "if (-not (Get-Process -Id $idePid -ErrorAction SilentlyContinue)) { break }; Start-Sleep -Seconds 3 }"
    $watcher = Start-Process powershell.exe -ArgumentList "-NoProfile -STA -ExecutionPolicy Bypass -Command `"$($watchScript -replace '"','\"')`"" -PassThru -WindowStyle Hidden
    L "watcher pid $($watcher.Id) started for IDE pid $idePid"

    L "Login($Flag) start"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $item.Login($Flag); L "Login($Flag) returned OK after $($sw.ElapsedMilliseconds) ms" }
    catch { L ("Login($Flag) ERR after $($sw.ElapsedMilliseconds) ms: " + $_.Exception.Message) }
    try { if ($watcher -and -not $watcher.HasExited) { Stop-Process -Id $watcher.Id -Force } } catch { }

    $st1 = & $mod { param($n) Wait-TcAdsState -AmsNetId $n -Port 851 -TargetState Any -TimeoutSec 20 } $AmsNetId
    L ("851 after login: reached=$($st1.Reached) state=$($st1.State)")
    L ("modal: " + (J (& $mod { Get-TcIdeModalDialog })))

    $a = Connect-TcAds
    L ("connect-ads: success=$($a.success) $(if(-not $a.success){ J $a.error })")
    $r = Set-TcPlcState -State Run
    L ("plc run: " + (J $r))
    $v = Read-TcVariable -Path $Symbol
    L ("read $Symbol : " + (J $v))
    Disconnect-TcAds | Out-Null
}
catch {
    L ("FATAL: " + $_.Exception.Message)
}
finally {
    L ("quit: " + (J (Disconnect-TcIde -Quit)))
    L "=== end ==="
}
