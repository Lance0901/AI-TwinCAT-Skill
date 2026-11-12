# Unit: #241 test-only wait knobs. The module variables the unit tests lower must hold the product
# values after import (the constants they replaced), Get-TcTimeScale must fall back to 1.0 for
# anything but a number in (0, 1], and the knobs must really drive the waits (default = real seconds).
# No IDE / ADS: Invoke-TcComRetry runs a script block that is "busy" once; Wait-TcAdsState gets a fake
# TwinCAT.Ads.TcAdsClient (Find-TcAdsAssembly stubbed) that never answers.
#   powershell.exe -NoProfile -File tests/Unit/time-knobs-241.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# --- product values after import (= the constants before #241)
$v = & $mod { [PSCustomObject]@{ Delay = $script:TcComRetryDelayMs; SysMgr = $script:TcSysManagerRetryMs; Ads = $script:TcAdsWaitTimeScale; Reset = $script:TcResetTimeScale } }
Check 'defaults: TcComRetryDelayMs 1000 (backoff 1, 2, 4, 8 s)' ($v.Delay -is [int] -and $v.Delay -eq 1000) "$($v.Delay)"
Check 'defaults: TcSysManagerRetryMs 1000 (Connect-TcIde ITcSysManager probes 1 s apart)' ($v.SysMgr -is [int] -and $v.SysMgr -eq 1000) "$($v.SysMgr)"
Check 'defaults: TcAdsWaitTimeScale 1.0' ($v.Ads -is [double] -and $v.Ads -eq 1.0) "$($v.Ads)"
Check 'defaults: TcResetTimeScale 1.0' ($v.Reset -is [double] -and $v.Reset -eq 1.0) "$($v.Reset)"
$setters = @(Select-String -Path (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\*\*.ps1') -Pattern '\$script:(TcComRetryDelayMs|TcSysManagerRetryMs|TcAdsWaitTimeScale|TcResetTimeScale)\s*=')
Check 'only the .psm1 assigns them (no code path in src changes them)' ($setters.Count -eq 0) (@($setters | ForEach-Object { "$($_.Filename):$($_.LineNumber)" }) -join ', ')

# --- Get-TcTimeScale: (0, 1] only
foreach ($c in @(@{ In = $null; Out = 1.0 }, @{ In = 1; Out = 1.0 }, @{ In = 0.25; Out = 0.25 }, @{ In = '0.5'; Out = 0.5 }, @{ In = 0; Out = 1.0 }, @{ In = -0.5; Out = 1.0 }, @{ In = 4; Out = 1.0 }, @{ In = 'x'; Out = 1.0 }, @{ In = [double]::NaN; Out = 1.0 })) {
    $got = & $mod { param($x) Get-TcTimeScale -Value $x } $c.In
    Check "Get-TcTimeScale $(if ($null -eq $c.In) { '$null' } else { "'$($c.In)'" }) -> $($c.Out)" ($got -eq $c.Out) "$got"
}

# --- Invoke-TcComRetry: one busy answer, then success -> exactly one backoff of TcComRetryDelayMs
function Measure-BusyOnce {
    $global:Busy241 = 1
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = & $mod { Invoke-TcComRetry -OperationName 'unit busy once' -ScriptBlock { if ($global:Busy241 -gt 0) { $global:Busy241--; throw (New-Object System.Runtime.InteropServices.COMException('busy (mock)', [int]0x80010001)) }; 'done' } }
    [PSCustomObject]@{ Result = $r; Sec = $sw.Elapsed.TotalSeconds }
}
$m = Measure-BusyOnce
Check 'Invoke-TcComRetry default: busy once -> retried after 1 s' ($m.Result -eq 'done' -and $m.Sec -ge 0.95) ("{0:N2} s" -f $m.Sec)
& $mod { $script:TcComRetryDelayMs = 20 }
$m = Measure-BusyOnce
Check 'Invoke-TcComRetry TcComRetryDelayMs 20: busy once -> retried after 20 ms' ($m.Result -eq 'done' -and $m.Sec -lt 0.9) ("{0:N2} s" -f $m.Sec)
& $mod { $script:TcComRetryDelayMs = 1000 }

# --- Wait-TcAdsState: -TimeoutSec 1 against a target that never answers
Add-Type -TypeDefinition @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Run = 5, Config = 15 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public void Connect(string netId, int port) { }
        public StateInfo ReadState() { throw new System.Exception("Ads-Error 0x745 : Timeout has elapsed."); }
        public void Dispose() { }
    }
}
'@
& $mod { function script:Find-TcAdsAssembly { $true } }
function Measure-AdsWait { & $mod { Wait-TcAdsState -AmsNetId '5.6.7.8.1.1' -Port 10000 -TargetState Run -TimeoutSec 1 -IntervalMs 100 } }
$w = Measure-AdsWait
Check 'Wait-TcAdsState default: -TimeoutSec 1 waits 1 s (real seconds)' (-not $w.Reached -and $w.ElapsedMs -ge 950) "$($w.ElapsedMs) ms"
& $mod { $script:TcAdsWaitTimeScale = 0.25 }
$w = Measure-AdsWait
Check 'Wait-TcAdsState TcAdsWaitTimeScale 0.25: -TimeoutSec 1 waits 0.25 s' (-not $w.Reached -and $w.ElapsedMs -ge 240 -and $w.ElapsedMs -lt 900) "$($w.ElapsedMs) ms"
& $mod { $script:TcAdsWaitTimeScale = 1.0 }

Remove-Variable -Name Busy241 -Scope Global -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
