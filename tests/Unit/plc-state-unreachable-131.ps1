. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #131 Set-TcPlcState reports 'Unreachable' when the last read of the PLC port failed during
# the wait (same rule as Set-TcSystemState #114): data.currentState / finalState = 'Unreachable',
# data.lastState = last state READ (else the original), data.lastError, data.unreachableSeen,
# data.leftOriginal only from states that were actually read; the lifecycle block has an empty
# reachedState with readbackNote 'unreachable'.
# No IDE / ADS / runtime: TwinCAT.Ads.TcAdsClient is a fake type compiled here (its ReadState throws
# "Ads-Error 0x7" to mock a failed ADS read), Find-TcAdsAssembly and Ensure-TcAdsConnection are
# stubbed in module scope. The real Wait-TcAdsState polls the fake client.
#   powershell.exe -NoProfile -File tests/Unit/plc-state-unreachable-131.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Depth 8 -Compress }

# Fake TwinCAT.Ads. Before = what ReadState returns before WriteControl; After = the reads after it,
# in order (the last one repeats). "down7" throws ADS 0x7 (target not found, e.g. a crashed runtime).
Add-Type -TypeDefinition @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Error = 9, Config = 15, Reconfig = 16 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public static string Before = "Stop";
        public static string[] After = new string[] { "Stop" };
        public static bool Written = false;
        public static int Index = 0;
        public static int Writes = 0;
        public void Connect(string netId, int port) { }
        public StateInfo ReadState() {
            string m;
            if (!Written) { m = Before; }
            else { m = After[System.Math.Min(Index, After.Length - 1)]; Index++; }
            if (m == "down7") { throw new System.Exception("Ads-Error 0x7 : Target machine could not be found."); }
            StateInfo s = new StateInfo();
            s.AdsState = (AdsState)System.Enum.Parse(typeof(AdsState), m);
            return s;
        }
        public void WriteControl(StateInfo s) { Written = true; Writes++; }
        public void Dispose() { }
    }
}
'@
$fake = [TwinCAT.Ads.TcAdsClient]

& $mod {
    function script:Find-TcAdsAssembly { $true }
    function script:Ensure-TcAdsConnection { $false }
}
# One AmsNetId per case: a failed case records a lifecycle block for its target (#68)
function Set-Case([string]$NetId, [string]$Before, [string[]]$After) {
    $fake::Before = $Before; $fake::After = $After; $fake::Written = $false; $fake::Index = 0; $fake::Writes = 0
    & $mod { param($n) $script:TcAdsClient = New-Object TwinCAT.Ads.TcAdsClient; $script:TcAdsConnected = $true; $script:TcAdsAmsNetId = $n; $script:TcAdsPort = 851 } $NetId
}

# --- A: Run requested, Stop read, then the port fails (0x7) until the deadline
Set-Case '10.131.0.1.1.1' 'Stop' @('Stop', 'Stop', 'down7')
$r = Set-TcPlcState -State Run -TimeoutSec 2
$d = $r.data
Check 'A Run: port fails after Stop -> PLC_RUN_TIMEOUT, WriteControl sent once' ((-not $r.success) -and $r.error.code -eq 'PLC_RUN_TIMEOUT' -and $fake::Writes -eq 1) "code=$($r.error.code) writes=$($fake::Writes)"
Check 'A currentState / finalState = Unreachable (not the stale Stop)' ($d.currentState -eq 'Unreachable' -and $d.finalState -eq 'Unreachable') (J $d)
Check 'A lastState = Stop, lastError = ADS 0x7' ($d.lastState -eq 'Stop' -and [string]$d.lastError -match '0x7') "lastState=$($d.lastState) lastError=$($d.lastError)"
Check 'A unreachableSeen = true, leftOriginal = false (only Stop was read), originalState = Stop' ($d.unreachableSeen -eq $true -and $d.leftOriginal -eq $false -and $d.originalState -eq 'Stop') "unreachableSeen=$($d.unreachableSeen) leftOriginal=$($d.leftOriginal) original=$($d.originalState)"
Check 'A message: last state unreachable (last state read: Stop)' ($r.error.message -match 'last state: unreachable \(last state read: Stop\)') "$($r.error.message)"
Check 'A probeErrors carries the 0x7 run' (@($d.probeErrors).Count -ge 1 -and [string]@($d.probeErrors)[0].message -match '0x7' -and $null -ne $d.PSObject.Properties['probeErrorsDropped']) (J $d.probeErrors)
$b = $d.lifecycleBlock
Check 'A lifecycle block: reachedState empty, readbackNote unreachable, step names it' ($null -ne $b -and $b.command -eq 'Set-TcPlcState' -and [string]::IsNullOrEmpty([string]$b.reachedState) -and $b.readbackNote -eq 'unreachable' -and $b.step -match 'unreachable' -and $b.step -match 'Stop') (J $b)
$blocked = Set-TcPlcState -State Run -TimeoutSec 1
Check 'A next call LIFECYCLE_BLOCKED says PLC port unreachable, sends nothing' ($blocked.error.code -eq 'LIFECYCLE_BLOCKED' -and $blocked.error.message -match 'nothing \(PLC port unreachable\)' -and $fake::Writes -eq 1) "$($blocked.error.message)"

# --- B: Run requested, every read after the write fails -> lastState = the original state
Set-Case '10.131.0.2.1.1' 'Stop' @('down7')
$r = Set-TcPlcState -State Run -TimeoutSec 1
$d = $r.data
Check 'B nothing read after the write -> Unreachable, lastState = original Stop, leftOriginal false' ($r.error.code -eq 'PLC_RUN_TIMEOUT' -and $d.currentState -eq 'Unreachable' -and $d.lastState -eq 'Stop' -and $d.leftOriginal -eq $false -and $d.unreachableSeen -eq $true) (J $d)

# --- C: Stop requested from Run, Init read (another state), then 0x7 -> leftOriginal true
Set-Case '10.131.0.3.1.1' 'Run' @('Run', 'Init', 'down7')
$r = Set-TcPlcState -State Stop -TimeoutSec 2
$d = $r.data
Check 'C Stop: Init read then 0x7 -> STATE_SET_FAILED, Unreachable, lastState Init' ($r.error.code -eq 'STATE_SET_FAILED' -and $d.currentState -eq 'Unreachable' -and $d.finalState -eq 'Unreachable' -and $d.lastState -eq 'Init') (J $d)
Check 'C leftOriginal = true (Init was READ), originalState Run, unreachableSeen' ($d.leftOriginal -eq $true -and $d.originalState -eq 'Run' -and $d.unreachableSeen -eq $true) (J $d)

# --- D: Run requested, one failed read, then Run -> success, the failure is still reported
Set-Case '10.131.0.4.1.1' 'Stop' @('down7', 'Run')
$r = Set-TcPlcState -State Run -TimeoutSec 5
$d = $r.data
Check 'D blip then Run -> success, currentState / finalState Run, lastError null' ($r.success -and $d.currentState -eq 'Run' -and $d.finalState -eq 'Run' -and $null -eq $d.lastError -and $d.lastState -eq 'Run') (J $d)
Check 'D unreachableSeen = true, leftOriginal = true (Run read), no lifecycle block' ($d.unreachableSeen -eq $true -and $d.leftOriginal -eq $true -and $null -eq $d.PSObject.Properties['lifecycleBlock']) (J $d)

# --- E: Stop requested, the port keeps answering Run (no failed read) -> old behaviour, real state
Set-Case '10.131.0.5.1.1' 'Run' @('Run')
$r = Set-TcPlcState -State Stop -TimeoutSec 1
$d = $r.data
Check 'E readable Run until the deadline -> STATE_SET_FAILED, currentState Run (not Unreachable)' ($r.error.code -eq 'STATE_SET_FAILED' -and $d.currentState -eq 'Run' -and $d.finalState -eq 'Run' -and $null -eq $d.lastError -and $d.unreachableSeen -eq $false -and $d.leftOriginal -eq $false) (J $d)
Check 'E lifecycle block reachedState = Run, no readbackNote' ($d.lifecycleBlock.reachedState -eq 'Run' -and $null -eq $d.lifecycleBlock.readbackNote -and $r.error.message -match 'last state: Run\)') (J $d.lifecycleBlock)

# --- F: original state unreadable -> originalState / leftOriginal $null; Stop reached
Set-Case '10.131.0.6.1.1' 'down7' @('Stop')
$r = Set-TcPlcState -State Stop -TimeoutSec 2
$d = $r.data
Check 'F original unreadable -> success, originalState null, leftOriginal null' ($r.success -and $d.currentState -eq 'Stop' -and $null -eq $d.originalState -and $null -eq $d.leftOriginal -and $d.unreachableSeen -eq $false) (J $d)

# --- G: JSON shape (MCP bridge serialises with ConvertTo-Json): the new fields survive
Set-Case '10.131.0.7.1.1' 'Stop' @('down7')
$r = Set-TcPlcState -State Run -TimeoutSec 1
$jo = ($r | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json
Check 'G JSON: currentState / finalState Unreachable, lastState, lastError, unreachableSeen, leftOriginal' ($jo.data.currentState -eq 'Unreachable' -and $jo.data.finalState -eq 'Unreachable' -and $jo.data.lastState -eq 'Stop' -and [string]$jo.data.lastError -match '0x7' -and $jo.data.unreachableSeen -eq $true -and $jo.data.leftOriginal -eq $false) (J $jo.data)

"failed: $fail"
exit $fail
