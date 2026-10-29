# Unit: task 1.8 RUNTIME_CRASHED (phase0-1.7 finding 2): Wait-TcAdsState -DetectRuntimeCrash ends the
# wait early when the local UmRT process vanished and ADS answers 0x7; Set-TcSystemState returns
# RUNTIME_CRASHED; Enable-TcConfig -Force and Invoke-TcTestCycle pass it on.
# No IDE / ADS / runtime: TwinCAT.Ads.TcAdsClient is a fake type compiled here, Find-TcAdsAssembly,
# Get-TcLocalUmRtProcess, Test-TcProcessAlive and the IDE helpers are stubbed in module scope.
#   powershell.exe -NoProfile -File tests/Unit/runtime-crashed.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
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
# 3rd read (Config), so a 0x7 streak never lasts.
Add-Type -TypeDefinition @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Config = 15, Reconfig = 16 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public static string Mode = "run";
        public static bool Written = false;
        public static int Reads = 0;
        public void Connect(string netId, int port) { }
        public StateInfo ReadState() {
            Reads++;
            string m = Mode;
            if (m == "crashAfterWrite") { m = Written ? "down7" : "run"; }
            if (m == "flap") { m = (Reads % 3 == 0) ? "config" : "down7"; }
            if (m == "down7") { throw new System.Exception("Ads-Error 0x7 : Target machine could not be found."); }
            if (m == "timeout") { throw new System.Exception("Ads-Error 0x745 : Timeout has elapsed."); }
            StateInfo s = new StateInfo();
            s.AdsState = (m == "config") ? AdsState.Config : AdsState.Run;
            return s;
        }
        public void WriteControl(StateInfo s) { Written = true; }
        public void Dispose() { }
    }
}
'@
$fake = [TwinCAT.Ads.TcAdsClient]
function Set-Ads([string]$Mode) { $fake::Mode = $Mode; $fake::Written = $false; $fake::Reads = 0 }

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
$global:UmRtCalls = 0
$global:AlivePids = @()       # pids Test-TcProcessAlive reports as running
& $mod {
    function script:Find-TcAdsAssembly { $true }
    function script:Get-TcLocalUmRtProcess { param([string]$AmsNetId) $global:UmRtCalls++; $global:UmRt }
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

# remote target: Set-TcSystemState keeps SYSTEM_STATE_TIMEOUT
Set-Ads 'crashAfterWrite'; $global:UmRt = $null
$r = Set-TcSystemState -State Config -AmsNetId '5.6.7.8.1.1' -TimeoutSec 3
Check 'Set-TcSystemState remote target -> SYSTEM_STATE_TIMEOUT (unchanged)' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $null -eq $r.data.PSObject.Properties['servicePidAtStart']) "code=$($r.error.code)"

# --- Enable-TcConfig -Force passes RUNTIME_CRASHED on (set-config and set-run)
$global:CrashOn = 'Config'
& $mod {
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { param([switch]$Refresh) $o = [PSCustomObject]@{}; $o | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '199.5.42.250.1.1' }; $o }
    function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Get-TcIdeModalDialog { $null }
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
Check 'Enable-TcConfig set-run: RUNTIME_CRASHED passed on, no Error List diagnostics' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_CRASHED' -and $r.error.hint -eq $hint -and $r.data.activated -and $r.data.runtimeCrash.runtimeName -eq 'UmRT_Default' -and @($r.data.steps | Where-Object { $_.step -eq 'set-run' -and -not $_.ok }).Count -eq 1) "code=$($r.error.code) msg=$($r.error.message)"

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
