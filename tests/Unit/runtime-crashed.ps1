# Unit: task 1.8 RUNTIME_CRASHED (phase0-1.7 finding 2): Wait-TcAdsState -DetectRuntimeCrash ends the
# wait early when the local UmRT process vanished and ADS answers 0x7; Set-TcSystemState returns
# RUNTIME_CRASHED; Enable-TcConfig -Force and Invoke-TcTestCycle pass it on.
# No IDE / ADS / runtime: TwinCAT.Ads.TcAdsClient is a fake type compiled here, Find-TcAdsAssembly,
# Get-TcLocalUmRtProcess, Test-TcProcessAlive and the IDE helpers are stubbed in module scope.
#   powershell.exe -NoProfile -File tests/Unit/runtime-crashed.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 400) { $Detail = $Detail.Substring(0, 400) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# Fake TwinCAT.Ads (the real TwinCAT.Ads.dll is never loaded: Find-TcAdsAssembly is stubbed).
# Mode: 'down7' every ReadState throws ADS 0x7; 'timeout' throws 0x745; 'run' / 'config' return
# that state; 'crashAfterWrite' returns Run until WriteControl, then 0x7; 'flap' 0x7 except every
# 3rd read (Config), so a 0x7 streak never lasts. #114: 'crashLate' returns Run until DownAfterSec
# after WriteControl, then 0x7; 'switch' returns Run until WriteControl, then Config; 'blip'
# returns Run, after WriteControl BlipReads reads 0x7, then Run again.
Add-Type -TypeDefinition @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Config = 15, Reconfig = 16 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public static string Mode = "run";
        public static bool Written = false;
        public static int Reads = 0;
        public static System.DateTime WrittenAt = System.DateTime.MinValue;
        public static double DownAfterSec = 0;
        public static int BlipReads = 0;
        public void Connect(string netId, int port) { }
        public StateInfo ReadState() {
            Reads++;
            string m = Mode;
            if (m == "crashAfterWrite") { m = Written ? "down7" : "run"; }
            if (m == "crashLate") { m = (Written && (System.DateTime.Now - WrittenAt).TotalSeconds >= DownAfterSec) ? "down7" : "run"; }
            if (m == "crashLateOther") { m = (Written && (System.DateTime.Now - WrittenAt).TotalSeconds >= DownAfterSec) ? "other" : "run"; }
            if (m == "alt") { m = (Reads % 2 == 0) ? "down7" : "timeout"; }
            if (m == "other") { throw new System.InvalidOperationException("Native call failed in the mock (no ADS code)."); }
            if (m == "switch") { m = Written ? "config" : "run"; }
            if (m == "blip") { if (Written && BlipReads > 0) { BlipReads--; m = "down7"; } else { m = "run"; } }
            if (m == "flap") { m = (Reads % 3 == 0) ? "config" : "down7"; }
            if (m == "down7") { throw new System.Exception("Ads-Error 0x7 : Target machine could not be found."); }
            if (m == "timeout") { throw new System.Exception("Ads-Error 0x745 : Timeout has elapsed."); }
            StateInfo s = new StateInfo();
            s.AdsState = (m == "config") ? AdsState.Config : AdsState.Run;
            return s;
        }
        public void WriteControl(StateInfo s) { Written = true; WrittenAt = System.DateTime.Now; }
        public void Dispose() { }
    }
}
'@
$fake = [TwinCAT.Ads.TcAdsClient]
function Set-Ads([string]$Mode) { $fake::Mode = $Mode; $fake::Written = $false; $fake::Reads = 0; $fake::BlipReads = 0 }

# --- Get-TcLocalUmRtProcess: local / UmRT decision (real function: tested before it is stubbed below)
& $mod {
    function script:Resolve-TcTargetBootDir { param([string]$AmsNetId) $global:BootDir }
    function script:Get-CimInstance { param($ClassName, $Filter, $ErrorAction) $global:Procs }
}
$global:BootDir = $null
$u = & $mod { Get-TcLocalUmRtProcess -AmsNetId '5.6.7.8.1.1' }
Check 'Get-TcLocalUmRtProcess: remote target -> $null' ($null -eq $u) "$u"
$global:BootDir = @{ Dir = 'C:\ProgramData\Beckhoff\TwinCAT\3.1\Boot'; Kind = 'local-xar' }
$u = & $mod { Get-TcLocalUmRtProcess -AmsNetId '192.168.1.2.1.1' }
Check 'Get-TcLocalUmRtProcess: local XAR -> $null' ($null -eq $u) "$u"
$global:BootDir = @{ Dir = 'x'; Kind = 'umrt:UmRT_Default' }
$global:Procs = @(
    [PSCustomObject]@{ ProcessId = 11; CommandLine = 'TcSystemServiceUm.exe -t bin -i path -n "UmRT_Other" -c .\3.1' },
    [PSCustomObject]@{ ProcessId = 12; CommandLine = 'TcSystemServiceUm.exe -t bin -i path -n "UmRT_Default" -c .\3.1' })
$u = & $mod { Get-TcLocalUmRtProcess -AmsNetId '199.5.42.250.1.1' }
Check 'Get-TcLocalUmRtProcess: pid of the matching -n name' ($u.RuntimeName -eq 'UmRT_Default' -and (@($u.Pids) -join ',') -eq '12' -and $u.PidSource -eq 'commandline') ($u | ConvertTo-Json -Compress)
$global:Procs = @([PSCustomObject]@{ ProcessId = 13; CommandLine = $null })
$u = & $mod { Get-TcLocalUmRtProcess -AmsNetId '199.5.42.250.1.1' }
Check 'Get-TcLocalUmRtProcess: unreadable command line -> that pid' ((@($u.Pids) -join ',') -eq '13' -and $u.PidSource -eq 'unreadable-commandline') ($u | ConvertTo-Json -Compress)
$global:Procs = @()
$u = & $mod { Get-TcLocalUmRtProcess -AmsNetId '199.5.42.250.1.1' }
Check 'Get-TcLocalUmRtProcess: UmRT not running -> no pids' ($null -ne $u -and @($u.Pids).Count -eq 0) ($u | ConvertTo-Json -Compress)

$global:UmRt = $null          # what Get-TcLocalUmRtProcess returns
$global:UmRtLater = $null     # #114: when set, what it returns from the 2nd call on (the deadline check)
$global:UmRtCalls = 0
$global:AlivePids = @()       # pids Test-TcProcessAlive reports as running
& $mod {
    function script:Find-TcAdsAssembly { $true }
    function script:Get-TcLocalUmRtProcess { param([string]$AmsNetId) $global:UmRtCalls++; if ($null -ne $global:UmRtLater -and $global:UmRtCalls -gt 1) { $global:UmRtLater } else { $global:UmRt } }
    function script:Test-TcProcessAlive { param([int]$Id) $global:AlivePids -contains $Id }
}
$localUmRt = [PSCustomObject]@{ RuntimeName = 'UmRT_Default'; Pids = [int[]]@(4242); PidSource = 'commandline' }
function Invoke-Wait([int]$TimeoutSec, [switch]$Detect) {
    & $mod { param($t, $d) Wait-TcAdsState -AmsNetId '199.5.42.250.1.1' -Port 10000 -TargetState Run -TimeoutSec $t -IntervalMs 100 -CrashUnreachableSec 1 -DetectRuntimeCrash:$d } $TimeoutSec ([bool]$Detect)
}

# --- A: local UmRT, its pid gone, ADS 0x7 -> early RuntimeCrashed
Set-Ads 'down7'; $global:UmRt = $localUmRt; $global:AlivePids = @()
$w = Invoke-Wait -TimeoutSec 20 -Detect
Check 'local UmRT gone + 0x7 -> RuntimeCrashed early' ($w.RuntimeCrashed -and -not $w.Reached -and $w.ElapsedMs -lt 4000 -and $w.UnreachableMs -ge 1000) "crashed=$($w.RuntimeCrashed) elapsed=$($w.ElapsedMs) unreach=$($w.UnreachableMs)"
Check 'crash data: servicePidAtStart, runtimeName, lastError 0x7' ((@($w.ServicePidAtStart) -join ',') -eq '4242' -and $w.RuntimeName -eq 'UmRT_Default' -and $w.LastError -match '0x7') "pids=$($w.ServicePidAtStart -join ',') name=$($w.RuntimeName) err=$($w.LastError)"

# --- B: remote target / local XAR (not a local UmRT) -> old behaviour, waits until TimeoutSec
Set-Ads 'down7'; $global:UmRt = $null
$w = Invoke-Wait -TimeoutSec 2 -Detect
Check 'remote target -> no crash detection, waits the timeout' (-not $w.RuntimeCrashed -and -not $w.Reached -and $w.ElapsedMs -ge 1900) "crashed=$($w.RuntimeCrashed) elapsed=$($w.ElapsedMs)"

# --- C: local UmRT whose process is still alive (e.g. 0x7 for another reason) -> no early exit
Set-Ads 'down7'; $global:UmRt = $localUmRt; $global:AlivePids = @(4242)
$w = Invoke-Wait -TimeoutSec 2 -Detect
Check 'UmRT process alive -> not crashed, waits the timeout' (-not $w.RuntimeCrashed -and $w.ElapsedMs -ge 1900) "crashed=$($w.RuntimeCrashed) elapsed=$($w.ElapsedMs)"

# --- D: local UmRT that was not running at the start -> no detection
Set-Ads 'down7'; $global:UmRt = [PSCustomObject]@{ RuntimeName = 'UmRT_Default'; Pids = [int[]]@(); PidSource = 'commandline' }; $global:AlivePids = @()
$w = Invoke-Wait -TimeoutSec 2 -Detect
Check 'no UmRT process at the start -> not crashed' (-not $w.RuntimeCrashed -and $w.ElapsedMs -ge 1900 -and @($w.ServicePidAtStart).Count -eq 0) "crashed=$($w.RuntimeCrashed) elapsed=$($w.ElapsedMs)"

# --- E: pid gone but the error is not 0x7 (ADS timeout 0x745) -> not crashed
Set-Ads 'timeout'; $global:UmRt = $localUmRt; $global:AlivePids = @()
$w = Invoke-Wait -TimeoutSec 2 -Detect
Check 'pid gone but ADS 0x745 (not 0x7) -> not crashed' (-not $w.RuntimeCrashed -and $w.ElapsedMs -ge 1900) "crashed=$($w.RuntimeCrashed) elapsed=$($w.ElapsedMs)"

# --- F: 0x7 streak interrupted by a real state every 3rd read -> never crashed
Set-Ads 'flap'; $global:UmRt = $localUmRt; $global:AlivePids = @()
$w = Invoke-Wait -TimeoutSec 2 -Detect
Check '0x7 streak reset by a readable state -> not crashed' (-not $w.RuntimeCrashed -and $w.ElapsedMs -ge 1900 -and $w.State -eq 'Config') "crashed=$($w.RuntimeCrashed) state=$($w.State) elapsed=$($w.ElapsedMs)"

# --- G: without -DetectRuntimeCrash nothing changes (Get-TcLocalUmRtProcess not even called)
Set-Ads 'down7'; $global:UmRt = $localUmRt; $global:AlivePids = @(); $global:UmRtCalls = 0
$w = Invoke-Wait -TimeoutSec 2
Check 'no -DetectRuntimeCrash -> old behaviour' (-not $w.RuntimeCrashed -and $w.ElapsedMs -ge 1900 -and $global:UmRtCalls -eq 0) "crashed=$($w.RuntimeCrashed) calls=$($global:UmRtCalls)"

# --- H: target reached -> Reached, no crash fields set
Set-Ads 'run'; $global:UmRt = $localUmRt; $global:AlivePids = @(4242)
$w = Invoke-Wait -TimeoutSec 5 -Detect
Check 'target reached -> Reached, not crashed' ($w.Reached -and -not $w.RuntimeCrashed -and $w.State -eq 'Run') "reached=$($w.Reached) state=$($w.State)"

# --- Set-TcSystemState: RUNTIME_CRASHED with hint and data (uses the default 10 s 0x7 window)
Set-Ads 'crashAfterWrite'; $global:UmRt = $localUmRt; $global:AlivePids = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 60
$sw.Stop()
Check 'Set-TcSystemState -> RUNTIME_CRASHED before -TimeoutSec' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_CRASHED' -and $sw.Elapsed.TotalSeconds -lt 25) "code=$($r.error.code) elapsed=$([int]$sw.Elapsed.TotalSeconds)s msg=$($r.error.message)"
Check 'RUNTIME_CRASHED data: lastError, lastState, servicePidAtStart' ($r.data.lastError -match '0x7' -and $r.data.lastState -eq 'Run' -and (@($r.data.servicePidAtStart) -join ',') -eq '4242' -and $r.data.runtimeName -eq 'UmRT_Default' -and $r.data.unreachableMs -ge 10000) ($r.data | ConvertTo-Json -Compress -Depth 3)
Check 'RUNTIME_CRASHED hint: restart UmRT, Enable-TcConfig -Force, #21' ($r.error.hint -match 'TcSystemServiceUm' -and $r.error.hint -match 'Enable-TcConfig -Force' -and $r.error.hint -match '#21' -and $r.error.hint -match 'SYSTEM_STATE_TIMEOUT') "$($r.error.hint)"
# #68 (S2): RUNTIME_CRASHED after WriteControl records a lifecycle block; the hint says to leave the restart to the user
Check 'RUNTIME_CRASHED recorded a lifecycle block, hint: user decides, no own restart' ($r.data.lifecycleBlock.errorCode -eq 'RUNTIME_CRASHED' -and $r.data.lifecycleBlock.amsNetId -eq '199.5.42.250.1.1' -and $r.error.hint -match 'LIFECYCLE_BLOCKED' -and $r.error.hint -match 'Stop-Process' -and $r.error.hint -match 'console') "$($r.data.lifecycleBlock | ConvertTo-Json -Compress)"
Check 'RUNTIME_CRASHED block: reachedState empty (runtime gone), step names it, requested = sent state' ([string]::IsNullOrEmpty([string]$r.data.lifecycleBlock.reachedState) -and $r.data.lifecycleBlock.step -match 'runtime gone' -and $r.data.lifecycleBlock.requestedState -eq 'Config') "$($r.data.lifecycleBlock | ConvertTo-Json -Compress)"
$tb = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 1
Check 'RUNTIME_CRASHED block message: nothing read back, no success-like wording' ($tb.error.code -eq 'LIFECYCLE_BLOCKED' -and $tb.error.message -match 'nothing \(runtime gone\)' -and $tb.error.message -notmatch "read back 'Run'") "$($tb.error.message)"
$null = Clear-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' -Reason 'unit test: next case'

# remote target: Set-TcSystemState keeps SYSTEM_STATE_TIMEOUT
Set-Ads 'crashAfterWrite'; $global:UmRt = $null
$r = Set-TcSystemState -State Config -AmsNetId '5.6.7.8.1.1' -TimeoutSec 3
Check 'Set-TcSystemState remote target -> SYSTEM_STATE_TIMEOUT (unchanged)' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $null -eq $r.data.PSObject.Properties['servicePidAtStart']) "code=$($r.error.code)"
# #68: SYSTEM_STATE_TIMEOUT after WriteControl records a lifecycle block (RUNTIME_CRASHED does not); lift it for the next cases
Check 'SYSTEM_STATE_TIMEOUT recorded a lifecycle block for that target only' ($r.data.lifecycleBlock.amsNetId -eq '5.6.7.8.1.1' -and $null -eq (& $mod { Get-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' })) "$($r.data.lifecycleBlock | ConvertTo-Json -Compress)"
$null = Clear-TcLifecycleBlock -AmsNetId '5.6.7.8.1.1' -Reason 'unit test: next case'

# --- #114: crash late in the wait. The process vanished, the 0x7 streak is still shorter than the
# 10 s window when -TimeoutSec ends (measured 2026-11-04: gone 46 s into a 60 s wait). Old code:
# SYSTEM_STATE_TIMEOUT, finalState 'Run', block reachedState 'Run', leftOriginal true.
$noUmRtNow = [PSCustomObject]@{ RuntimeName = 'UmRT_Default'; Pids = [int[]]@(); PidSource = 'commandline' }
Set-Ads 'crashLate'; $fake::DownAfterSec = 1.5; $global:UmRt = $localUmRt; $global:UmRtLater = $noUmRtNow; $global:UmRtCalls = 0; $global:AlivePids = @()
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 4 -SettleSec 0
$sw.Stop()
Check '#114 crash late (0x7 streak < 10 s at the deadline, no UmRT process left) -> RUNTIME_CRASHED' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_CRASHED' -and $r.data.crashDetectedBy -eq 'deadline' -and $sw.Elapsed.TotalSeconds -lt 15) "code=$($r.error.code) by=$($r.data.crashDetectedBy) elapsed=$([int]$sw.Elapsed.TotalSeconds)s msg=$($r.error.message)"
Check '#114 crash late: finalState / currentState Unreachable, lastState Run, leftOriginal false' ($r.data.finalState -eq 'Unreachable' -and $r.data.currentState -eq 'Unreachable' -and $r.data.lastState -eq 'Run' -and $r.data.leftOriginal -eq $false -and $r.data.lastError -match '0x7') ($r.data | ConvertTo-Json -Compress -Depth 3)
Check '#114 crash late: block reachedState empty, crash hint, message names the deadline' ([string]::IsNullOrEmpty([string]$r.data.lifecycleBlock.reachedState) -and $r.data.lifecycleBlock.errorCode -eq 'RUNTIME_CRASHED' -and $r.error.hint -match 'TcSystemServiceUm' -and $r.error.message -match 'at -TimeoutSec' -and $r.data.lifecycleBlock.readbackNote -eq 'runtime-gone') "$($r.data.lifecycleBlock | ConvertTo-Json -Compress) msg=$($r.error.message)"
Check '#114 S1 crash late: probeErrors (0x7 mapped, pidAlive false), deadlineCheck, unreachableSeen (S2)' (@($r.data.probeErrors).Count -gt 0 -and @($r.data.probeErrors)[-1].code -eq 'ADS_TARGET_NOT_FOUND' -and @($r.data.probeErrors)[-1].pidAlive -eq $false -and $r.data.deadlineCheck.processListReadable -eq $true -and @($r.data.deadlineCheck.pidsNow).Count -eq 0 -and $r.data.unreachableSeen -eq $true) ($r.data | Select-Object probeErrors, deadlineCheck, unreachableSeen | ConvertTo-Json -Compress -Depth 4)
$null = Clear-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' -Reason 'unit test: next case'

# R2-S1 / R2-S2: equal failures are one run; hresult / message come from the innermost exception
$last = @($r.data.probeErrors)[-1]
Check '#114 R2 probe runs: the 0x7 phase is one run (count > 1, fromMs < toMs), innermost message / hresult' (@($r.data.probeErrors).Count -le 3 -and $last.count -gt 1 -and $last.fromMs -lt $last.toMs -and $last.message -like 'Ads-Error 0x7*' -and $last.hresult -eq '0x80131500') ($r.data.probeErrors | ConvertTo-Json -Compress -Depth 3)
Set-Ads 'alt'; $global:UmRt = $null
$w = & $mod { Wait-TcAdsState -AmsNetId '5.6.7.8.1.1' -Port 10000 -TargetState Run -TimeoutSec 7 -IntervalMs 20 }
$pe = @($w.ProbeErrors)
Check '#114 R2 probe runs capped at 50 (first 10 + last 40), dropped counted' ($pe.Count -eq 50 -and $w.ProbeErrorsDropped -gt 0 -and $pe[0].fromMs -le $pe[1].fromMs -and $pe[9].toMs -lt $pe[10].fromMs -and ($pe | Measure-Object -Property count -Sum).Sum -lt ($pe.Count + $w.ProbeErrorsDropped + 1)) "runs=$($pe.Count) dropped=$($w.ProbeErrorsDropped)"

# S1 (b): the failure after the crash is not mapped to ADS_TARGET_NOT_FOUND (0x7 streak never starts)
Set-Ads 'crashLateOther'; $fake::DownAfterSec = 1.0; $global:UmRt = $localUmRt; $global:UmRtLater = $noUmRtNow; $global:UmRtCalls = 0; $global:AlivePids = @()
$r = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 3 -SettleSec 0
Check '#114 S1(b) unmapped error after the crash, no UmRT process left -> RUNTIME_CRASHED (deadline), probe code null' ($r.error.code -eq 'RUNTIME_CRASHED' -and $r.data.crashDetectedBy -eq 'deadline' -and $null -eq @($r.data.probeErrors)[-1].code -and $r.data.unreachableMs -eq 0 -and $r.data.deadlineCheck.lastProbeCode -eq $null) "code=$($r.error.code) $($r.data | Select-Object probeErrors, deadlineCheck | ConvertTo-Json -Compress -Depth 4)"
$null = Clear-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' -Reason 'unit test: next case'

# S1 (c): Test-TcProcessAlive still reports the start pid, but the process list has no process of the runtime
Set-Ads 'crashLate'; $fake::DownAfterSec = 1.0; $global:UmRt = $localUmRt; $global:UmRtLater = $noUmRtNow; $global:UmRtCalls = 0; $global:AlivePids = @(4242)
$r = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 3 -SettleSec 0
Check '#114 S1(c) start pid still "alive", process list empty -> RUNTIME_CRASHED (deadline), startPidsAlive / pidAlive recorded' ($r.error.code -eq 'RUNTIME_CRASHED' -and $r.data.crashDetectedBy -eq 'deadline' -and (@($r.data.deadlineCheck.startPidsAlive) -join ',') -eq '4242' -and @($r.data.probeErrors)[-1].pidAlive -eq $true) "code=$($r.error.code) $($r.data | Select-Object probeErrors, deadlineCheck | ConvertTo-Json -Compress -Depth 4)"
$null = Clear-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' -Reason 'unit test: next case'

# S7: the process list cannot be read at the deadline (empty Pids, ProcessListReadable false) -> no crash verdict
Set-Ads 'crashLate'; $fake::DownAfterSec = 1.0; $global:UmRt = $localUmRt; $global:UmRtCalls = 0; $global:AlivePids = @()
$global:UmRtLater = [PSCustomObject]@{ RuntimeName = 'UmRT_Default'; Pids = [int[]]@(); PidSource = 'commandline'; ProcessListReadable = $false }
$r = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 3 -SettleSec 0
Check '#114 S7 process list unreadable at the deadline -> SYSTEM_STATE_TIMEOUT, deadlineCheck.processListReadable false' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $r.data.deadlineCheck.processListReadable -eq $false -and $r.data.finalState -eq 'Unreachable') "code=$($r.error.code) $($r.data.deadlineCheck | ConvertTo-Json -Compress)"
$null = Clear-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' -Reason 'unit test: next case'
$global:UmRtLater = $null

# same, but a TcSystemServiceUm of this runtime runs again under a new pid (restart, not a crash)
# -> SYSTEM_STATE_TIMEOUT, but still no 'Run' for a target that did not answer
Set-Ads 'crashLate'; $fake::DownAfterSec = 1.0; $global:UmRt = $localUmRt; $global:UmRtCalls = 0; $global:AlivePids = @()
$global:UmRtLater = [PSCustomObject]@{ RuntimeName = 'UmRT_Default'; Pids = [int[]]@(5151); PidSource = 'commandline' }
$r = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 3 -SettleSec 0
Check '#114 0x7 at the deadline, UmRT runs under a new pid -> SYSTEM_STATE_TIMEOUT (not crashed)' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT') "code=$($r.error.code) msg=$($r.error.message)"
Check '#114 timeout with a failed last read: finalState / currentState Unreachable, lastState Run, leftOriginal false' ($r.data.finalState -eq 'Unreachable' -and $r.data.currentState -eq 'Unreachable' -and $r.data.lastState -eq 'Run' -and $r.data.leftOriginal -eq $false -and $r.data.unreachableMs -gt 0 -and $r.error.message -match 'unreachable \(last state read: Run\)') ($r.data | ConvertTo-Json -Compress -Depth 3)
Check '#114 timeout block: reachedState empty, step says unreachable (not Run)' ([string]::IsNullOrEmpty([string]$r.data.lifecycleBlock.reachedState) -and $r.data.lifecycleBlock.step -match 'unreachable' -and $r.data.lifecycleBlock.readbackNote -eq 'unreachable' -and $r.data.lifecycleBlock.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and @($r.data.probeErrors).Count -gt 0) "$($r.data.lifecycleBlock | ConvertTo-Json -Compress)"
$tb = Set-TcSystemState -State Config -AmsNetId '199.5.42.250.1.1' -TimeoutSec 1
Check '#114 LIFECYCLE_BLOCKED message: nothing read back (unreachable), requestSent false' ($tb.error.code -eq 'LIFECYCLE_BLOCKED' -and $tb.error.message -match 'nothing \(port 10000 unreachable\)' -and $tb.error.message -notmatch "read back 'Run'" -and $tb.data.requestSent -eq $false) "$($tb.error.message)"
$null = Clear-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' -Reason 'unit test: next case'
$global:UmRtLater = $null

# leftOriginal (#114 point 3): only a read that returned another state counts
Set-Ads 'run'; $global:UmRt = $null
$r = Set-TcSystemState -State Config -AmsNetId '5.6.7.8.1.1' -TimeoutSec 2 -SettleSec 0
Check '#114 original Run, target Config, every read Run -> timeout, leftOriginal false, finalState Run' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $r.data.leftOriginal -eq $false -and $r.data.unreachableSeen -eq $false -and $r.data.finalState -eq 'Run' -and [string]$r.data.lifecycleBlock.reachedState -eq 'Run') ($r.data | ConvertTo-Json -Compress -Depth 3)
$null = Clear-TcLifecycleBlock -AmsNetId '5.6.7.8.1.1' -Reason 'unit test: next case'
Set-Ads 'switch'; $global:UmRt = $null
$r = Set-TcSystemState -State Config -AmsNetId '5.6.7.8.1.1' -TimeoutSec 5 -SettleSec 0
Check '#114 original Run, a read returned Config -> success, leftOriginal true' ($r.success -and $r.data.leftOriginal -eq $true -and $r.data.finalState -eq 'Config' -and $r.data.unreachableSeen -eq $false) ($r | ConvertTo-Json -Compress -Depth 3)
Set-Ads 'blip'; $fake::BlipReads = 2; $global:UmRt = $null
$r = Set-TcSystemState -State Run -AmsNetId '5.6.7.8.1.1' -TimeoutSec 5 -SettleSec 0
Check '#114 Run -> Run restart seen only as unreachable -> success, leftOriginal false, unreachableSeen true' ($r.success -and $r.data.leftOriginal -eq $false -and $r.data.unreachableSeen -eq $true -and $r.data.finalState -eq 'Run') ($r | ConvertTo-Json -Compress -Depth 3)

# --- Enable-TcConfig -Force passes RUNTIME_CRASHED on (set-config and set-run)
$global:CrashOn = 'Config'
& $mod {
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { param([switch]$Refresh) $o = [PSCustomObject]@{}; $o | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '199.5.42.250.1.1' }; $o }
    function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Find-TcIdeModalDialog { $null }
    function script:Get-TcIdeMemoryInfo { $null }
    function script:Invoke-TcActivateWithDeadline { param($TimeoutSec, $AmsNetId) }
    function script:Get-TcPlcProjectList { param($SysManager) @() }
    function script:Get-TcBootPackageDiff { param($SolutionPath, $Platform, $AmsNetId, $AdsPorts) $null }
    function script:Get-TcBuildErrors { param($TimeoutSec) throw 'Get-TcBuildErrors must not run for RUNTIME_CRASHED' }
    function script:Set-TcSystemState {
        param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
        if ($State -ne $global:CrashOn) { return New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State }) }
        New-TcResult -Success $false -ErrorCode 'RUNTIME_CRASHED' -ErrorMessage 'The local UmRT disappeared (mock)' -Hint (Get-TcErrorHint -Code 'RUNTIME_CRASHED') `
            -Data ([PSCustomObject]@{ lastError = 'Ads-Error 0x7'; lastState = 'Run'; servicePidAtStart = @(4242); runtimeName = 'UmRT_Default'; unreachableMs = 10100 })
    }
    $script:TcDte = $null
    $script:TcSolutionPath = 'C:\Demo\Crash.sln'
}
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
$hint = & $mod { Get-TcErrorHint -Code 'RUNTIME_CRASHED' }
Check 'Enable-TcConfig set-config: RUNTIME_CRASHED code + hint passed on' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_CRASHED' -and $r.error.hint -eq $hint -and $r.error.message -match 'Failed to switch to Config') "code=$($r.error.code) msg=$($r.error.message)"
Check 'Enable-TcConfig set-config: data.runtimeCrash' ((@($r.data.runtimeCrash.servicePidAtStart) -join ',') -eq '4242' -and $r.data.runtimeCrash.lastError -match '0x7' -and -not $r.data.activated) ($r.data.runtimeCrash | ConvertTo-Json -Compress)
$global:CrashOn = 'Run'
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'Enable-TcConfig set-run: RUNTIME_CRASHED passed on, no Error List diagnostics' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_CRASHED' -and $r.error.hint.EndsWith($hint) -and $r.data.activateReturned -and -not $r.data.activated -and $r.data.runtimeCrash.runtimeName -eq 'UmRT_Default' -and @($r.data.steps | Where-Object { $_.step -eq 'set-run' -and -not $_.ok }).Count -eq 1) "code=$($r.error.code) msg=$($r.error.message)"

# #68 (S1): the set-run RUNTIME_CRASHED came after set-config / Activate: Enable-TcConfig recorded a block
Check 'Enable-TcConfig set-run RUNTIME_CRASHED recorded a lifecycle block (requested Run, nothing read back)' ($r.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and $r.data.lifecycleBlock.errorCode -eq 'RUNTIME_CRASHED' -and $r.data.lifecycleBlock.requestedState -eq 'Run' -and [string]::IsNullOrEmpty([string]$r.data.lifecycleBlock.reachedState)) "$($r.data.lifecycleBlock | ConvertTo-Json -Compress)"
$null = Clear-TcLifecycleBlock -AmsNetId '199.5.42.250.1.1' -Reason 'unit test: next case'

# --- Invoke-TcTestCycle keeps RUNTIME_CRASHED (not ACTIVATION_FAILED)
& $mod {
    function script:Enable-TcConfig { param([switch]$Force)
        $res = New-TcResult -Success $false -ErrorCode 'RUNTIME_CRASHED' -ErrorMessage 'Failed to switch to Run: gone (mock)' -Hint 'restart (mock)' -Data ([PSCustomObject]@{ runtimeCrash = [PSCustomObject]@{ servicePidAtStart = @(4242) } })
        $res
    }
    $script:TcSysManager = $null
}
$tc = New-TcTestCase -Name 'n' -WaitUntil @{ Path = 'MAIN.b'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.n'; Expected = 1 })
$r = Invoke-TcTestCycle -TestCases @($tc) -SkipBuild
Check 'Invoke-TcTestCycle: RUNTIME_CRASHED kept with hint and data.runtimeCrash' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_CRASHED' -and $r.error.hint -eq 'restart (mock)' -and (@($r.data.runtimeCrash.servicePidAtStart) -join ',') -eq '4242') ($r | ConvertTo-Json -Compress -Depth 4)

# --- registration: hint key exists
Check 'RUNTIME_CRASHED hint registered' (-not [string]::IsNullOrWhiteSpace($hint)) "$hint"

Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
"failed: $fail"
exit [Math]::Min($fail, 255)
