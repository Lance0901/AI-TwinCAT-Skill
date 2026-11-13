. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
# Unit: #131 Set-TcPlcState reports 'Unreachable' when the last read of the PLC port failed during
# the wait (same rule as Set-TcSystemState #114): data.currentState / finalState = 'Unreachable',
# data.lastState = last state READ (else the original), data.lastError, data.unreachableSeen,
# data.leftOriginal only from states that were actually read; the lifecycle block has an empty
# reachedState with readbackNote 'unreachable'.
# #287 (cases J..T): port 10000 is read before every request (Exception -> SYSTEM_EXCEPTION, unreadable
# -> SYSTEM_STATE_FAILED, nothing sent, no block) and after Run (both ports must stay Run through the
# confirm window, else RUNTIME_STATE_MISMATCH + block). Mock basis: measured 2026-11-13, XAE 4026.22 /
# VS2022, local UmRT (runtime-semantics-measured.md section 7): after a PLC exception port 851 = Stop,
# port 10000 = adsState 19 Exception; WriteControl Run read back Run on 851 after 26 ms, then 851 was
# unreachable (0x6) and port 10000 = Config within ~1.5 s. The fake client answers port 10000 from
# its own Sys sequence (Connect records the port).
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
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Error = 9, Config = 15, Reconfig = 16, Exception = 19 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public static string Before = "Stop";
        public static string[] After = new string[] { "Stop" };
        public static bool Written = false;
        public static int Index = 0;
        public static int Writes = 0;
        // #287: port 10000 (system service) reads Sys in order, the last one repeats; "down7" throws
        public static string[] Sys = new string[] { "Run" };
        public static int SysIndex = 0;
        private int port = 851;
        public void Connect(string netId, int p) { port = p; }
        public StateInfo ReadState() {
            string m;
            if (port == 10000) { m = Sys[System.Math.Min(SysIndex, Sys.Length - 1)]; SysIndex++; }
            else if (!Written) { m = Before; }
            else { m = After[System.Math.Min(Index, After.Length - 1)]; Index++; }
            if (m == "down7") { throw new System.Exception("Ads-Error 0x7 : Target machine could not be found."); }
            if (m == "down6") { throw new System.Exception("Ads-Error 0x6 : Target port could not be found."); }
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
function Set-Case([string]$NetId, [string]$Before, [string[]]$After, [string[]]$Sys = @('Run')) {
    $fake::Before = $Before; $fake::After = $After; $fake::Written = $false; $fake::Index = 0; $fake::Writes = 0
    $fake::Sys = $Sys; $fake::SysIndex = 0
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

# --- H: Run on a PLC that already runs -> alreadyInState, nothing sent, every #131 field present
Set-Case '10.131.0.8.1.1' 'Run' @('Run')
$r = Set-TcPlcState -State Run -TimeoutSec 1
$d = $r.data
$names = @('originalState', 'currentState', 'finalState', 'lastState', 'lastError', 'leftOriginal', 'unreachableSeen')
$missing = @($names | Where-Object { $null -eq $d.PSObject.Properties[$_] })
Check 'H already Run -> success, alreadyInState, no WriteControl' ($r.success -and $d.alreadyInState -eq $true -and $fake::Writes -eq 0) (J $d)
Check 'H already Run -> originalState / currentState / finalState / lastState Run, lastError null, leftOriginal / unreachableSeen false' ($missing.Count -eq 0 -and $d.originalState -eq 'Run' -and $d.currentState -eq 'Run' -and $d.finalState -eq 'Run' -and $d.lastState -eq 'Run' -and $null -eq $d.lastError -and $d.leftOriginal -eq $false -and $d.unreachableSeen -eq $false) "missing=$($missing -join ',') $(J $d)"

# --- I: the wait returns before any probe (TwinCAT.Ads.dll not found for the temporary client):
# currentState 'Unreachable' must come with unreachableSeen = true
Set-Case '10.131.0.9.1.1' 'Stop' @('Stop')
# #287: the port 10000 read before the request still finds the dll (first call), the wait does not
& $mod { $script:UtOrigFind = ${function:script:Find-TcAdsAssembly}; $script:UtFindCalls = 0; function script:Find-TcAdsAssembly { $script:UtFindCalls++; $script:UtFindCalls -le 1 } }
try { $r = Set-TcPlcState -State Run -TimeoutSec 1 }
finally { & $mod { Set-Item -Path function:script:Find-TcAdsAssembly -Value $script:UtOrigFind } }
$d = $r.data
Check 'I dll not found in the wait -> PLC_RUN_TIMEOUT, Unreachable, unreachableSeen true, lastState = original' ($r.error.code -eq 'PLC_RUN_TIMEOUT' -and $d.currentState -eq 'Unreachable' -and $d.unreachableSeen -eq $true -and $d.lastState -eq 'Stop' -and [string]$d.lastError -match 'dll not found') (J $d)

# --- G: JSON shape (MCP bridge serialises with ConvertTo-Json): the new fields survive
Set-Case '10.131.0.7.1.1' 'Stop' @('down7')
$r = Set-TcPlcState -State Run -TimeoutSec 1
$jo = ($r | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json
Check 'G JSON: currentState / finalState Unreachable, lastState, lastError, unreachableSeen, leftOriginal' ($jo.data.currentState -eq 'Unreachable' -and $jo.data.finalState -eq 'Unreachable' -and $jo.data.lastState -eq 'Stop' -and [string]$jo.data.lastError -match '0x7' -and $jo.data.unreachableSeen -eq $true -and $jo.data.leftOriginal -eq $false) (J $jo.data)

# ===== #287: TwinCAT system state (port 10000) =====
& $mod { $script:TcAdsWaitTimeScale = 0.2 }   # confirm window 1500 ms -> 300 ms, same number of rounds
function Get-Block([string]$NetId) { & $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $NetId }
function Get-InflightCount { @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'lifecycle-inflight.*.json' -ErrorAction SilentlyContinue).Count }

# --- J: system in Exception -> SYSTEM_EXCEPTION for Run / Stop / Reset, nothing sent, no block
$i = 0
foreach ($st in @('Run', 'Stop', 'Reset')) {
    $i++
    $nid = "10.287.0.$i.1.1"
    Set-Case $nid 'Stop' @('Run') @('Exception')
    $r = Set-TcPlcState -State $st -TimeoutSec 2
    $d = $r.data
    Check "J$i $st with port 10000 Exception -> SYSTEM_EXCEPTION, no WriteControl" ((-not $r.success) -and $r.error.code -eq 'SYSTEM_EXCEPTION' -and $fake::Writes -eq 0) "code=$($r.error.code) writes=$($fake::Writes)"
    Check "J$i $st data: systemState Exception, adsState 19, readAt, writeControlSent false" ($d.systemState -eq 'Exception' -and $d.adsState -eq 19 -and -not [string]::IsNullOrWhiteSpace([string]$d.readAt) -and $d.writeControlSent -eq $false -and $d.requestedState -eq $st) (J $d)
    Check "J$i $st no lifecycle block, no in-flight marker" ($null -eq $d.PSObject.Properties['lifecycleBlock'] -and $null -eq (Get-Block $nid) -and (Get-InflightCount) -eq 0) (J (Get-Block $nid))
    $h = [string]$r.error.hint
    Check "J$i $st hint: Enable-TcConfig -Force, page fault 0xc0000005 restart, no Clear / raw ADS advice" ($h -match 'Enable-TcConfig -Force' -and $h -match '0xc0000005' -and $h -match 'restart the runtime' -and $h -notmatch 'Clear-TcLifecycleBlock' -and $h -notmatch 'WriteControl') $h
}
# JSON shape over the MCP bridge
Set-Case '10.287.0.4.1.1' 'Stop' @('Run') @('Exception')
$jo = ((Set-TcPlcState -State Run -TimeoutSec 1) | ConvertTo-Json -Depth 50 -Compress) | ConvertFrom-Json
Check 'J4 JSON: error.code SYSTEM_EXCEPTION, data.systemState / adsState survive' ($jo.error.code -eq 'SYSTEM_EXCEPTION' -and $jo.data.systemState -eq 'Exception' -and $jo.data.adsState -eq 19) (J $jo)

# --- M: port 10000 unreadable before the request -> SYSTEM_STATE_FAILED, nothing sent, no block
$i = 0
foreach ($st in @('Run', 'Stop', 'Reset')) {
    $i++
    $nid = "10.287.1.$i.1.1"
    Set-Case $nid 'Stop' @('Run') @('down7')
    $r = Set-TcPlcState -State $st -TimeoutSec 2
    Check "M$i $st port 10000 unreadable -> SYSTEM_STATE_FAILED, no WriteControl, no block" ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_FAILED' -and $fake::Writes -eq 0 -and $null -eq (Get-Block $nid) -and [string]$r.data.readError -match '0x7' -and $r.data.readErrorCode -eq 'ADS_TARGET_NOT_FOUND' -and $null -eq $r.data.systemState -and -not [string]::IsNullOrWhiteSpace([string]$r.error.hint)) (J $r)
}

# --- N: Run reached on 851, then port 10000 falls back to Config inside the confirm window
$nid = '10.287.2.1.1.1'
Set-Case $nid 'Stop' @('Run') @('Run', 'Run', 'Config')
$r = Set-TcPlcState -State Run -TimeoutSec 2
$d = $r.data
Check 'N 10000 -> Config after 851 Run: RUNTIME_STATE_MISMATCH, WriteControl sent once' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $fake::Writes -eq 1) "code=$($r.error.code) writes=$($fake::Writes) $(J $d)"
Check 'N data: systemState Config, runConfirm failedPort 10000, systemStateBefore Run, currentState still the PLC Run' ($d.systemState -eq 'Config' -and $d.systemAdsState -eq 15 -and $d.runConfirm.ok -eq $false -and $d.runConfirm.failedPort -eq 10000 -and $d.systemStateBefore -eq 'Run' -and $d.currentState -eq 'Run') (J $d)
$b = Get-Block $nid
Check 'N lifecycle block recorded: Set-TcPlcState / RUNTIME_STATE_MISMATCH / requested Run / reached Config' ($null -ne $b -and $b.command -eq 'Set-TcPlcState' -and $b.errorCode -eq 'RUNTIME_STATE_MISMATCH' -and $b.requestedState -eq 'Run' -and $b.reachedState -eq 'Config' -and $null -ne $d.lifecycleBlock) (J $b)
Check 'N hint starts with the stop instruction' ($r.error.hint.StartsWith((& $mod { $script:TcLifecycleStopPrefix }))) "$($r.error.hint)"
$again = Set-TcPlcState -State Run -TimeoutSec 1
Check 'N next call LIFECYCLE_BLOCKED, nothing sent' ($again.error.code -eq 'LIFECYCLE_BLOCKED' -and $fake::Writes -eq 1) "$($again.error.code)"

# --- O: Run reached, then the PLC port disappears (0x6) inside the confirm window
Set-Case '10.287.2.2.1.1' 'Stop' @('Run', 'Run', 'down6') @('Run')
$r = Set-TcPlcState -State Run -TimeoutSec 2
$d = $r.data
Check 'O 851 unreachable in the window -> RUNTIME_STATE_MISMATCH, currentState Unreachable, block readbackNote unreachable' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $d.currentState -eq 'Unreachable' -and $d.finalState -eq 'Unreachable' -and $d.unreachableSeen -eq $true -and $d.runConfirm.failedPort -eq 851 -and $d.lifecycleBlock.readbackNote -eq 'unreachable' -and [string]::IsNullOrEmpty([string]$d.lifecycleBlock.reachedState)) (J $d)

# --- R: port 10000 unreadable inside the confirm window -> RUNTIME_STATE_MISMATCH + block (Run was sent)
Set-Case '10.287.2.3.1.1' 'Stop' @('Run') @('Run', 'down7')
$r = Set-TcPlcState -State Run -TimeoutSec 2
$d = $r.data
Check 'R 10000 unreadable in the window -> RUNTIME_STATE_MISMATCH, block with empty reachedState, no unreachable note' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $d.runConfirm.failedPort -eq 10000 -and $null -eq $d.systemState -and $null -ne $d.lifecycleBlock -and [string]::IsNullOrEmpty([string]$d.lifecycleBlock.reachedState) -and [string]::IsNullOrEmpty([string]$d.lifecycleBlock.readbackNote)) (J $d)

# --- P: normal Run -> success after the confirm window, both ports Run in every round
$nid = '10.287.3.1.1.1'
Set-Case $nid 'Stop' @('Run') @('Run')
$r = Set-TcPlcState -State Run -TimeoutSec 2
$d = $r.data
$minS = & $mod { $script:TcPlcRunConfirmMinSamples }
Check 'P normal Run -> success, WriteControl once, systemState Run, no block' ($r.success -and $fake::Writes -eq 1 -and $d.systemState -eq 'Run' -and $d.systemAdsState -eq 5 -and $d.currentState -eq 'Run' -and $null -eq $d.PSObject.Properties['lifecycleBlock'] -and $null -eq (Get-Block $nid)) (J $d)
Check 'P runConfirm ok, samples >= minSamples, windowMs 1500' ($d.runConfirm.ok -eq $true -and $d.runConfirm.samples -ge $minS -and $d.runConfirm.windowMs -eq 1500 -and $null -eq $d.runConfirm.failedPort) (J $d.runConfirm)
Check 'P port 10000 read before and in every confirm round (>= 1 + minSamples reads)' ($fake::SysIndex -ge (1 + $minS)) "sysReads=$($fake::SysIndex)"

# --- P2: normal Stop / Reset unchanged (system Run / Config), no confirm window for them
Set-Case '10.287.3.2.1.1' 'Run' @('Stop') @('Run')
$r = Set-TcPlcState -State Stop -TimeoutSec 2
Check 'P2 Stop with system Run -> success, one 10000 read, no runConfirm' ($r.success -and $fake::Writes -eq 1 -and $fake::SysIndex -eq 1 -and $null -eq $r.data.PSObject.Properties['runConfirm'] -and $r.data.systemStateBefore -eq 'Run') (J $r.data)
Set-Case '10.287.3.3.1.1' 'Stop' @('Stop') @('Config')
$r = Set-TcPlcState -State Reset -TimeoutSec 2
Check 'P2 Reset with system Config (not Exception) -> sent as before' ($r.success -and $fake::Writes -eq 1) (J $r)

# --- Q: PLC already Run but port 10000 not Run -> RUNTIME_STATE_MISMATCH, nothing sent, no block
$nid = '10.287.4.1.1.1'
Set-Case $nid 'Run' @('Run') @('Config')
$r = Set-TcPlcState -State Run -TimeoutSec 1
Check 'Q already Run, system Config -> RUNTIME_STATE_MISMATCH, no WriteControl, no block' ((-not $r.success) -and $r.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $fake::Writes -eq 0 -and $null -eq (Get-Block $nid) -and $r.data.systemState -eq 'Config' -and $r.data.writeControlSent -eq $false) (J $r)
Set-Case '10.287.4.2.1.1' 'Run' @('Run') @('Run')
$r = Set-TcPlcState -State Run -TimeoutSec 1
Check 'Q2 already Run, system Run -> success alreadyInState with systemState Run' ($r.success -and $r.data.alreadyInState -eq $true -and $r.data.systemState -eq 'Run' -and $fake::Writes -eq 0) (J $r.data)

# --- S: Get-TcPlcState reports the system state; a failed port 10000 read does not fail it
Set-Case '10.287.5.1.1.1' 'Stop' @('Stop') @('Exception')
$g = Get-TcPlcState
Check 'S Get-TcPlcState: state Stop (unchanged), systemState Exception, systemAdsState 19' ($g.success -and $g.data.state -eq 'Stop' -and $g.data.adsState -eq 6 -and $g.data.systemState -eq 'Exception' -and $g.data.systemAdsState -eq 19 -and $null -eq $g.data.systemStateError) (J $g.data)
Set-Case '10.287.5.2.1.1' 'Run' @('Run') @('down7')
$g = Get-TcPlcState
Check 'S Get-TcPlcState: port 10000 unreadable -> still success, systemState null, systemStateError set' ($g.success -and $g.data.state -eq 'Run' -and $null -eq $g.data.systemState -and [string]$g.data.systemStateError -match '0x7') (J $g.data)

# --- T: the constants are the documented values
$c = & $mod { [PSCustomObject]@{ ex = $script:TcAdsStateException; run = $script:TcAdsStateRun; ms = $script:TcPlcRunConfirmMs; iv = $script:TcPlcRunConfirmIntervalMs; n = $script:TcPlcRunConfirmMinSamples } }
Check 'T constants: Exception 19, Run 5, window 1500 ms / 250 ms / 3 rounds' ($c.ex -eq 19 -and $c.run -eq 5 -and $c.ms -eq 1500 -and $c.iv -eq 250 -and $c.n -eq 3) (J $c)
& $mod { $script:TcAdsWaitTimeScale = 1.0 }

# --- U: Enable-TcConfig (the recovery from Exception) never meets the new check before Activate:
# its only Set-TcPlcState call is the set-plc-run step, after the system already reads Run
$ecSrc = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Enable-TcConfig.ps1') -Raw
$ecAst = [System.Management.Automation.Language.Parser]::ParseInput($ecSrc, [ref]$null, [ref]$null)
$ecCalls = @($ecAst.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Set-TcPlcState' }, $true))
$runStepAt = $ecSrc.IndexOf("# 6. set-plc-run")
Check 'U Enable-TcConfig: one Set-TcPlcState call, Run, inside step 6 set-plc-run (after the system Run wait)' ($ecCalls.Count -eq 1 -and $runStepAt -gt 0 -and $ecCalls[0].Extent.StartOffset -gt $runStepAt -and $ecCalls[0].Extent.Text -match '-State Run') "calls=$($ecCalls.Count) at=$(@($ecCalls | ForEach-Object { $_.Extent.StartOffset }) -join ',') step6=$runStepAt"

"failed: $fail"
exit $fail
