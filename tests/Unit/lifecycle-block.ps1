# Unit: #68 fail-closed lifecycle guard (#32 regression), no IDE / ADS / runtime needed.
# TwinCAT.Ads.TcAdsClient is a fake type compiled here (WriteControl never throws, ReadState
# returns $global:AdsMode), Find-TcAdsAssembly / Wait-TcAdsState / the IDE helpers are stubbed in
# module scope. Covers:
#   (1) #32 shape: Set-TcSystemState Run, WriteControl without exception, readback Config
#       -> success=false (SYSTEM_STATE_TIMEOUT) + block recorded for that AmsNetId
#   (2) afterwards Enter-TcPlcOnline, Set-TcPlcState Run, Write-TcVariable, Enable-TcConfig -Force,
#       Set-TcSystemState, Invoke-TcTestCycle, Invoke-TcTest, Send-TcPlcProgram, Set-TcComModuleParameter -Online:
#       LIFECYCLE_BLOCKED, nothing sent (no WriteControl, Login, Activate, WriteAny, Build)
#   (3) another AmsNetId is not blocked; read-only commands are not blocked
#   (4) Clear-TcLifecycleBlock (Reason required, receipt, history) -> commands run again
#   (5) Enable-TcConfig -Force: set-run ok but verify reads Config -> RUNTIME_STATE_MISMATCH,
#       block recorded, restarted / activated not true (activateReturned / runReached keep the facts)
#   (6) precondition failure (BUILD_REQUIRED) writes no block; SYSTEM_STATE_MISMATCH writes one;
#       Set-TcPlcState PLC_RUN_TIMEOUT writes one
#   (7) Invoke-TcTestCycle never calls Connect-TcIde after Activate (#68 point 5)
#   (8) block in the file is seen by a fresh module instance; an unparseable / non-object file is
#       replaced by a '<corrupt>' record (S5, N4) that keeps blocking A after B is written; Clear
#       names what still blocks every target (N1)
#   (9) S4 loopback NetId (127.x.x.x.y.z) is '<unknown>': compared with every record
#   (10) M1 / S3 Invoke-TcTestCycle: failing PLC Stop / Run fails the cycle, NOT RUN steps
#   (11) S1 ACTIVATE_TIMEOUT / CYCLE_TIMEOUT after set-config record a block; a set-config that
#        sent nothing does not
#   (12) S2 Set-TcSystemState exception after WriteControl -> block, before it -> none
#   (13) N2 ADS commands: never connected -> NOT_CONNECTED; failed reconnect of a blocked NetId -> blocked
#   powershell.exe -NoProfile -File tests/Unit/lifecycle-block.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$A = '10.1.2.3.1.1'   # blocked target
$B = '10.9.8.7.1.1'   # other target

Add-Type -TypeDefinition @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Config = 15, Reconfig = 16 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public static string Mode = "config";
        public static int Writes = 0;
        public static string NextMode = null;   // Mode after WriteControl (null / empty = unchanged; PowerShell assigns $null as "")
        public static bool ThrowOnWrite = false;
        public static bool ThrowOnConnect = false;
        public void Connect(string netId, int port) { if (ThrowOnConnect) { throw new System.Exception("Ads-Error 0x7 : Target machine could not be found (mock)."); } }
        public StateInfo ReadState() {
            StateInfo s = new StateInfo();
            s.AdsState = (Mode == "run") ? AdsState.Run : AdsState.Config;
            return s;
        }
        public void WriteControl(StateInfo s) { Writes++; if (ThrowOnWrite) { throw new System.Exception("Ads-Error 0x745 : Timeout has elapsed (mock)."); } if (!string.IsNullOrEmpty(NextMode)) { Mode = NextMode; } }
        public void Dispose() { }
    }
}
'@
$fake = [TwinCAT.Ads.TcAdsClient]

$global:Calls = @{}
function Reset-Calls { $global:Calls = @{ WriteControl = 0; Login = 0; Activate = 0; WriteAny = 0; Build = 0; ConnectIde = 0; SetSystemState = 0; WaitPort = 0 } }
Reset-Calls

& $mod {
    function script:Find-TcAdsAssembly { $true }
    function script:Assert-TcConnection { }
    function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0) $null }
    function script:Get-TcIdeMemoryInfo { $null }
    function script:Get-TcLicenseDiagnosis { param($AmsNetId) $null }
    function script:Get-TcLocalUmRtProcess { param($AmsNetId) $null }
    function script:Get-TcSysManager {
        [CmdletBinding()] param([switch]$Refresh)
        $o = [PSCustomObject]@{ Mock = $true }
        $o | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { $global:IdeTarget }
        $o | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) $global:Calls.Login++; [PSCustomObject]@{} }
        $o
    }
    function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Read-TcCurrentVariant { param($SysManager) @{ Value = ''; Error = $null } }
    function script:Get-TcPlcProjectList { param($SysManager) @([PSCustomObject]@{ name = 'P'; nodePath = 'TIPC^P'; projectPath = 'TIPC^P^P Project'; adsPort = 851; disabled = $false }) }
    function script:Get-TcBootPackageDiff { param($SolutionPath, $Platform, $AmsNetId, $AdsPorts, $Variant) $null }
    function script:Get-TcBuildErrors { param($TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @() }) }
    function script:Invoke-TcActivateWithDeadline { param($TimeoutSec, $AmsNetId) $global:Calls.Activate++ }
    function script:Build-TcProject { $global:Calls.Build++; New-TcResult -Success $true -Data ([PSCustomObject]@{ completeBuild = $true }) }
    function script:Connect-TcIde { $global:Calls.ConnectIde++; New-TcResult -Success $true -Data ([PSCustomObject]@{ amsNetId = $global:IdeTarget }) }
    function script:Ensure-TcAdsConnection { $false }
    function script:Connect-TcAdsSession { param($AmsNetId, $Port) 'Run' }
    # Wait-TcAdsState: port 10000 / PLC ports report $global:AdsMode; never reached unless it equals the target
    function script:Wait-TcAdsState {
        param([string]$AmsNetId, [int]$Port, [string]$TargetState, [int]$TimeoutSec, [switch]$DetectRuntimeCrash)
        $global:Calls.WaitPort++
        $st = if ($Port -eq 10000) { if ([TwinCAT.Ads.TcAdsClient]::Mode -eq 'run') { 'Run' } else { 'Config' } } else { $global:PlcState }
        [PSCustomObject]@{ Reached = ($TargetState -eq 'Any' -or $st -eq $TargetState); State = $st; LastError = $null; ElapsedMs = 5; RuntimeCrashed = $false }
    }
    $script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = [PSCustomObject]@{ LastBuildInfo = 0 } } }
    $script:TcSolutionPath = 'C:\Demo\Guard.sln'
    $script:TcSilentMode = $true
}
# fake module ADS session (Write-TcVariable / Set-TcPlcState / Invoke-TcTest use $script:TcAdsClient)
$session = [PSCustomObject]@{}
$session | Add-Member -MemberType ScriptMethod -Name ReadState -Value { $s = New-Object TwinCAT.Ads.StateInfo; $s.AdsState = [TwinCAT.Ads.AdsState]::Stop; $s }
$session | Add-Member -MemberType ScriptMethod -Name WriteControl -Value { param($s) $global:Calls.WriteControl++ }
$session | Add-Member -MemberType ScriptMethod -Name WriteAny -Value { $global:Calls.WriteAny++ }
function Set-Session([string]$NetId) { & $mod { param($c, $n) $script:TcAdsClient = $c; $script:TcAdsConnected = $true; $script:TcAdsAmsNetId = $n; $script:TcAdsPort = 851 } $session $NetId }

$global:IdeTarget = $A
$global:PlcState = 'Run'
Set-Session $A
$stateFile = Join-Path $env:TCAUTO_STATE_DIR 'lifecycle-block.json'

try {
    # --- (1) #32: WriteControl does not throw, readback stays Config ---
    $fake::Mode = 'config'; $fake::NextMode = $null; $fake::Writes = 0
    $r = Set-TcSystemState -State Run -AmsNetId $A -TimeoutSec 2 -SettleSec 0
    Check '(1) Set-TcSystemState Run, readback Config -> success=false SYSTEM_STATE_TIMEOUT' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $fake::Writes -eq 1) "code=$($r.error.code) writes=$($fake::Writes)"
    Check '(1) block recorded: command, code, requested Run, reached Config' ($r.data.lifecycleBlock.command -eq 'Set-TcSystemState' -and $r.data.lifecycleBlock.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $r.data.lifecycleBlock.requestedState -eq 'Run' -and $r.data.lifecycleBlock.reachedState -eq 'Config' -and $r.data.lifecycleBlock.amsNetId -eq $A) (J $r.data.lifecycleBlock)
    Check '(1) hint starts with the stop instruction' ($r.error.hint.StartsWith((& $mod { $script:TcLifecycleStopPrefix })) -and $r.error.hint -match 'Clear-TcLifecycleBlock' -and $r.error.hint -match 'raw ADS') "$($r.error.hint)"
    $onDisk = (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json)
    Check '(1) block written to lifecycle-block.json under the AmsNetId key' ($null -ne $onDisk.PSObject.Properties[$A]) (Get-Content -LiteralPath $stateFile -Raw)

    # --- (2) every runtime-changing command is refused, nothing is sent ---
    Reset-Calls; $fake::Writes = 0
    $blockedRuns = [ordered]@{
        'Enter-TcPlcOnline'        = { Enter-TcPlcOnline }
        'Send-TcPlcProgram'        = { Send-TcPlcProgram }
        'Set-TcPlcState'           = { Set-TcPlcState -State Run }
        'Set-TcPlcState Stop'      = { Set-TcPlcState -State Stop }
        'Write-TcVariable'         = { Write-TcVariable -Path 'MAIN.bStart' -Value $true }
        'Enable-TcConfig'          = { Enable-TcConfig -Force -WarningAction SilentlyContinue }
        'Enable-TcConfig (no -Force)' = { Enable-TcConfig -WarningAction SilentlyContinue }
        'Set-TcSystemState'        = { Set-TcSystemState -State Config }
        'Invoke-TcTest'            = { Invoke-TcTest -TestCase (New-TcTestCase -Name 't' -Setup @(@{ Path = 'MAIN.x'; Value = 1 }) -WaitUntil @{ Path = 'MAIN.b'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.n'; Expected = 1 })) }
        'Invoke-TcTestCycle'       = { Invoke-TcTestCycle -TestCases @((New-TcTestCase -Name 't' -WaitUntil @{ Path = 'MAIN.b'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.n'; Expected = 1 }))) }
        'Set-TcComModuleParameter -Online' = { Set-TcComModuleParameter -Module M -Name P -Value 1 -Online -DryRun $false }
    }
    foreach ($k in $blockedRuns.Keys) {
        $x = & $blockedRuns[$k]
        $exp = ($k -replace ' .*$', '')
        if ($k -eq 'Send-TcPlcProgram') { $exp = 'Enter-TcPlcOnline' }
        # #114 minor 7: every refusal says requestSent = false (not only Set-TcSystemState)
        Check "(2) $k -> LIFECYCLE_BLOCKED, data.lifecycleBlock, NOT RUN, requestSent false" ((-not $x.success) -and $x.error.code -eq 'LIFECYCLE_BLOCKED' -and $x.data.notRun -eq $true -and $x.data.requestSent -eq $false -and $x.data.lifecycleBlock.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $x.data.command -eq $exp -and $x.error.hint -match 'Clear-TcLifecycleBlock') "code=$($x.error.code) cmd=$($x.data.command)"
    }
    Check '(2) nothing sent: no WriteControl / Login / Activate / WriteAny / Build / state switch' ($fake::Writes -eq 0 -and $global:Calls.WriteControl -eq 0 -and $global:Calls.Login -eq 0 -and $global:Calls.Activate -eq 0 -and $global:Calls.WriteAny -eq 0 -and $global:Calls.Build -eq 0 -and $global:Calls.WaitPort -eq 0) (J $global:Calls)
    $e = & $blockedRuns['Enable-TcConfig']
    Check '(2) Enable-TcConfig refusal has activated=false' ($e.data.activated -eq $false) (J $e.data)

    # --- (3) other target and read-only commands ---
    Reset-Calls; $fake::Mode = 'config'; $fake::NextMode = 'run'; $fake::Writes = 0
    $r = Set-TcSystemState -State Run -AmsNetId $B -TimeoutSec 5 -SettleSec 0
    $fake::NextMode = $null
    Check '(3) other AmsNetId is not blocked (Set-TcSystemState runs and succeeds)' ($r.success -and $fake::Writes -eq 1) "code=$($r.error.code) writes=$($fake::Writes) msg=$($r.error.message)"
    Set-Session $B
    $global:PlcState = 'Stop'
    $w = Set-TcPlcState -State Stop
    $global:PlcState = 'Run'
    Check '(3) Set-TcPlcState on the other target runs' ($w.success -and $global:Calls.WriteControl -eq 1) (J $w)
    Set-Session $A
    $g = Get-TcSystemState -AmsNetId $A
    Check '(3) Get-TcSystemState (read-only) is not blocked' ($g.error.code -ne 'LIFECYCLE_BLOCKED') (J $g)

    # --- (4) Clear-TcLifecycleBlock ---
    $e = Clear-TcLifecycleBlock -AmsNetId $A -Reason '' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(4) -Reason is required (empty refused, #113: LIFECYCLE_RECEIPT_INCOMPLETE)' ((-not $e.success) -and $e.error.code -eq 'LIFECYCLE_RECEIPT_INCOMPLETE' -and (@($e.data.missing) -contains 'Reason')) (J $e)
    $c = Clear-TcLifecycleBlock -Reason 'user checked the license and approved a new Enable-TcConfig -Force' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(4) Clear (AmsNetId from the IDE target) returns the removed record + receipt' ($c.success -and $c.data.cleared.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $c.data.amsNetId -eq $A -and $c.data.netIdSource -eq 'resolved' -and $c.data.receipt.reason -match 'approved') (J $c.data)
    $hist = Join-Path $env:TCAUTO_STATE_DIR 'lifecycle-block-history.jsonl'
    Check '(4) receipt appended to lifecycle-block-history.jsonl' ((Test-Path -LiteralPath $hist) -and ((Get-Content -LiteralPath $hist -Raw) -match 'approved')) ''
    Reset-Calls
    $w = Write-TcVariable -Path 'MAIN.bStart' -Value $true
    Check '(4) after Clear, Write-TcVariable is no longer refused' ($w.error.code -ne 'LIFECYCLE_BLOCKED') "code=$($w.error.code)"
    $c2 = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'second call' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(4) Clear without a record -> success, cleared=$null' ($c2.success -and $null -eq $c2.data.cleared) (J $c2.data)

    # --- (5) Enable-TcConfig -Force: set-run reached Run, verify reads Config ---
    & $mod {
        function script:Set-TcSystemState {
            param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
            $global:Calls.SetSystemState++
            if ($State -eq 'Run') { [TwinCAT.Ads.TcAdsClient]::Mode = 'config' }   # falls back right after set-run (#32)
            New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State })
        }
        function script:Enter-TcPlcOnline { param($LoginMode, $PlcProjectPath, $TimeoutSec) $global:Calls.Login++; New-TcResult -Success $true -Data ([PSCustomObject]@{ message = 'mock login' }) }
        function script:New-TcAdsClient {
            param($AmsNetId, $Port)
            $o = [PSCustomObject]@{ P = $Port }
            $o | Add-Member -MemberType ScriptMethod -Name ReadState -Value { $s = New-Object TwinCAT.Ads.StateInfo; $s.AdsState = $(if ($this.P -eq 10000 -and [TwinCAT.Ads.TcAdsClient]::Mode -ne 'run') { [TwinCAT.Ads.AdsState]::Config } else { [TwinCAT.Ads.AdsState]::Run }); $s }
            $o | Add-Member -MemberType ScriptMethod -Name WriteControl -Value { param($s) $global:Calls.WriteControl++ }
            $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
            $o
        }
    }
    Reset-Calls; $fake::Mode = 'run'; $global:PlcState = 'Run'
    & $mod { $script:TcAdsAmsNetId = $null; $script:TcAdsConnected = $false; $script:TcAdsPort = 0 }
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(5) verify reads Config -> RUNTIME_STATE_MISMATCH' ((-not $e.success) -and $e.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $e.data.finalCheck.systemState -eq 'Config') "code=$($e.error.code) msg=$($e.error.message)"
    Check '(5) restarted / activated / loggedIn / platformFixed are not true' ($e.data.restarted -eq $false -and $e.data.activated -eq $false -and $e.data.loggedIn -eq $false -and $e.data.platformFixed -eq $false) (J ($e.data | Select-Object activated, restarted, loggedIn, platformFixed))
    Check '(5) facts kept: activateSent, activateReturned, runSent, runReached, reachedState=Config' ($e.data.activateSent -and $e.data.activateReturned -and $e.data.runSent -and $e.data.runReached -and $e.data.loginCompleted -and $e.data.reachedState -eq 'Config' -and $e.data.requestedState -eq 'Run') (J ($e.data | Select-Object activateSent, activateReturned, runSent, runReached, loginCompleted, requestedState, reachedState))
    Check '(5) block recorded by Enable-TcConfig (step verify)' ($e.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and $e.data.lifecycleBlock.errorCode -eq 'RUNTIME_STATE_MISMATCH' -and $e.data.lifecycleBlock.step -eq 'verify' -and $e.data.lifecycleBlock.reachedState -eq 'Config' -and $e.data.lifecycleBlock.amsNetId -eq $A) (J $e.data.lifecycleBlock)
    Reset-Calls
    $e2 = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(5) second Enable-TcConfig -Force -> LIFECYCLE_BLOCKED, no state switch, no Activate' ($e2.error.code -eq 'LIFECYCLE_BLOCKED' -and $global:Calls.SetSystemState -eq 0 -and $global:Calls.Activate -eq 0) "code=$($e2.error.code) calls=$(J $global:Calls)"
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'test (5) done' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None

    # Enable-TcConfig -Force success: the done fields are true and match the facts
    Reset-Calls; $fake::Mode = 'run'
    & $mod { function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) $global:Calls.SetSystemState++; New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State }) } }
    $ok = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(5) success: activated / restarted / loggedIn true, reachedState Run, no block' ($ok.success -and $ok.data.activated -and $ok.data.restarted -and $ok.data.loggedIn -and $ok.data.reachedState -eq 'Run' -and $null -eq $ok.data.PSObject.Properties['lifecycleBlock']) "code=$($ok.error.code) msg=$($ok.error.message)"

    # --- (5b) #42: the modal scan does not complete ---
    # $global:Scan.From: 'verify' = incomplete only after the login (the verify readback), 'start' = always
    $global:Scan = @{ From = 'verify'; Calls = [System.Collections.Generic.List[int]]::new() }
    & $mod {
        $script:UtOrigFind42 = ${function:Find-TcIdeModalDialog}
        function script:Find-TcIdeModalDialog {
            [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
            if ($global:Scan.From -eq 'start' -or ($global:Scan.From -eq 'verify' -and $global:Calls.Login -gt 0) -or ($global:Scan.From -eq 'after-config' -and $global:Calls.SetSystemState -gt 0)) {
                $global:Scan.Calls.Add($TimeoutSec)
                return (New-TcModalScanIncomplete -ProcessId 4242 -Reason 'timeout' -TimeoutSec $TimeoutSec -Message 'mock: scan did not finish')
            }
            $null
        }
    }
    # (a1) verify: system and PLC Run, scan incomplete -> one rescan (<= 15 s), MODAL_SCAN_INCOMPLETE + block
    Reset-Calls; $fake::Mode = 'run'; $global:PlcState = 'Run'; $global:Scan.Calls.Clear(); $global:Scan.From = 'verify'
    $v = Enable-TcConfig -Force -TimeoutSec 120 -WarningAction SilentlyContinue
    $scans = @($global:Scan.Calls)
    Check '(5b) verify scan incomplete -> MODAL_SCAN_INCOMPLETE, not success' ((-not $v.success) -and $v.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $v.data.finalCheck.dialogScanComplete -eq $false -and $v.data.finalCheck.modalScan.reason -eq 'timeout') "code=$($v.error.code) msg=$($v.error.message)"
    Check '(5b) exactly one rescan, bounded by Min(15, remaining); no third scan in the failure diagnostics' ($scans.Count -eq 2 -and $scans[1] -le 15 -and $scans[1] -ge 1) "scans=$($scans -join ',')"
    Check '(5b) block recorded (runtime was changed), step verify' ($v.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and $v.data.lifecycleBlock.errorCode -eq 'MODAL_SCAN_INCOMPLETE' -and $v.data.lifecycleBlock.step -eq 'verify') (J $v.data.lifecycleBlock)
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'test (5b) a1 done' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    # (a2) verify: scan incomplete AND the system fell back to Config -> RUNTIME_STATE_MISMATCH
    & $mod {
        $script:UtOrigSss42 = ${function:Set-TcSystemState}
        function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) $global:Calls.SetSystemState++; if ($State -eq 'Run') { [TwinCAT.Ads.TcAdsClient]::Mode = 'config' }; New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State }) }
    }
    Reset-Calls; $fake::Mode = 'run'; $global:Scan.Calls.Clear()
    $v = Enable-TcConfig -Force -TimeoutSec 120 -WarningAction SilentlyContinue
    Check '(5b) verify scan incomplete + state mismatch -> RUNTIME_STATE_MISMATCH, block' ((-not $v.success) -and $v.error.code -eq 'RUNTIME_STATE_MISMATCH' -and $v.data.finalCheck.dialogScanComplete -eq $false -and $v.data.lifecycleBlock.errorCode -eq 'RUNTIME_STATE_MISMATCH') "code=$($v.error.code) msg=$($v.error.message)"
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'test (5b) a2 done' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    & $mod { Set-Item -Path function:script:Set-TcSystemState -Value $script:UtOrigSss42 }
    # (b) Activate only (no -Force): the pre-Activate gate sees an incomplete scan -> MODAL_SCAN_INCOMPLETE, nothing sent, NO block
    Reset-Calls; $fake::Mode = 'run'; $global:Scan.Calls.Clear(); $global:Scan.From = 'start'
    $v = Enable-TcConfig -WarningAction SilentlyContinue
    $blk = Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue
    Check '(5b) pre-Activate gate incomplete -> MODAL_SCAN_INCOMPLETE, no Activate, no block' ((-not $v.success) -and $v.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $global:Calls.Activate -eq 0 -and $null -eq $v.data.PSObject.Properties['lifecycleBlock'] -and ($null -eq $blk -or $blk -notmatch [regex]::Escape($A))) "code=$($v.error.code) activate=$($global:Calls.Activate) block=$($null -ne $v.data.PSObject.Properties['lifecycleBlock'])"
    # (c) -Force, incomplete before set-config -> stops at the new set-config gate: no state switch, no block
    Reset-Calls; $fake::Mode = 'run'; $global:Scan.Calls.Clear(); $global:Scan.From = 'start'
    $v = Enable-TcConfig -Force -WarningAction SilentlyContinue
    $blk = Get-Content -LiteralPath $stateFile -Raw -ErrorAction SilentlyContinue
    Check '(5b) -Force, scan incomplete before set-config -> MODAL_SCAN_INCOMPLETE, no Set-TcSystemState, no Activate, no block' ((-not $v.success) -and $v.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $global:Calls.SetSystemState -eq 0 -and $global:Calls.Activate -eq 0 -and $null -eq $v.data.PSObject.Properties['lifecycleBlock'] -and ($null -eq $blk -or $blk -notmatch [regex]::Escape($A)) -and @($v.data.steps | Where-Object { $_.step -eq 'set-config' -and -not $_.ok }).Count -eq 1) "code=$($v.error.code) sss=$($global:Calls.SetSystemState) block=$($null -ne $v.data.PSObject.Properties['lifecycleBlock']) steps=$(J $v.data.steps)"
    # (d) -Force, scan incomplete only after set-config was sent -> pre-activate gate fails, block recorded (step activate)
    Reset-Calls; $fake::Mode = 'run'; $global:Scan.Calls.Clear(); $global:Scan.From = 'after-config'
    $v = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(5b) -Force, scan incomplete after set-config -> MODAL_SCAN_INCOMPLETE, no Activate, block (step activate)' ((-not $v.success) -and $v.error.code -eq 'MODAL_SCAN_INCOMPLETE' -and $global:Calls.SetSystemState -ge 1 -and $global:Calls.Activate -eq 0 -and $v.data.lifecycleBlock.errorCode -eq 'MODAL_SCAN_INCOMPLETE' -and $v.data.lifecycleBlock.step -eq 'activate') "code=$($v.error.code) sss=$($global:Calls.SetSystemState) block=$(J $v.data.lifecycleBlock)"
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'test (5b) d done' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    & $mod { Set-Item -Path function:script:Find-TcIdeModalDialog -Value $script:UtOrigFind42 }

    # --- (6) precondition failure writes nothing; SYSTEM_STATE_MISMATCH / PLC_RUN_TIMEOUT write ---
    & $mod { $script:UtOrigBR = ${function:Get-TcBuildRequired} }
    & $mod { function script:Get-TcBuildRequired { [PSCustomObject]@{ solution = 'C:\Demo\Guard.sln'; kind = 'code-changed'; reason = 'PLC code changed by mock'; reasons = [PSCustomObject]@{ 'code-changed' = 'PLC code changed by mock' }; at = 'now' } } }
    $p = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(6) BUILD_REQUIRED (nothing changed) -> no block' ($p.error.code -eq 'BUILD_REQUIRED' -and $null -eq $p.data.PSObject.Properties['lifecycleBlock'] -and -not (Test-Path -LiteralPath $stateFile)) "code=$($p.error.code)"
    & $mod { Set-Item -Path function:script:Get-TcBuildRequired -Value $script:UtOrigBR }
    # top-level calls reach the exported (unmocked) Set-TcSystemState
    $fake::Mode = 'run'; $fake::Writes = 0
    $m = Set-TcSystemState -State Run -AmsNetId $B -TimeoutSec 1 -SettleSec 0
    Check '(6) Run -> Run never left -> SYSTEM_STATE_MISMATCH + block for that target' ($m.error.code -eq 'SYSTEM_STATE_MISMATCH' -and $m.data.lifecycleBlock.amsNetId -eq $B -and $m.data.lifecycleBlock.step -eq 'leave-original') (J $m.data.lifecycleBlock)
    Set-Session $A
    $q = Set-TcSystemState -State Config -AmsNetId $A -TimeoutSec 1 -SettleSec 0
    Check '(6) target A still free while B is blocked' ($q.error.code -ne 'LIFECYCLE_BLOCKED') "code=$($q.error.code)"
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'reset' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $global:PlcState = 'Stop'
    $t = Set-TcPlcState -State Run -TimeoutSec 1
    Check '(6) Set-TcPlcState Run not reached -> PLC_RUN_TIMEOUT + block' ($t.error.code -eq 'PLC_RUN_TIMEOUT' -and $t.data.lifecycleBlock.command -eq 'Set-TcPlcState' -and $t.data.lifecycleBlock.requestedState -eq 'Run' -and $t.data.lifecycleBlock.reachedState -eq 'Stop') (J $t.data)
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'reset' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $null = Clear-TcLifecycleBlock -AmsNetId $B -Reason 'reset' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None

    # --- (7) Invoke-TcTestCycle: no Connect-TcIde after Activate ---
    & $mod {
        function script:Enable-TcConfig { param([switch]$Force) $global:Calls.Activate++; New-TcResult -Success $true -Data ([PSCustomObject]@{ amsNetId = $global:IdeTarget; activated = $true }) }
        function script:Connect-TcAds { param($AmsNetId) New-TcResult -Success $true -Data ([PSCustomObject]@{ amsNetId = $AmsNetId }) }
        function script:Set-TcPlcState { param($State, $TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State }) }
        function script:Invoke-TcTest { param($TestCase) New-TcResult -Success $true -Data ([PSCustomObject]@{ name = $TestCase.name; result = 'Pass' }) }
        $script:TcSysManager = Get-TcSysManager
    }
    Reset-Calls
    $cy = Invoke-TcTestCycle -TestCases @((New-TcTestCase -Name 't' -WaitUntil @{ Path = 'MAIN.b'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.n'; Expected = 1 }))) -SkipBuild -KeepRunning
    Check '(7) Invoke-TcTestCycle: Activate ran, Connect-TcIde never called' ($global:Calls.Activate -eq 1 -and $global:Calls.ConnectIde -eq 0 -and $cy.success) "calls=$(J $global:Calls) code=$($cy.error.code)"
    $src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Invoke-TcTestCycle.ps1') -Raw
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($src, [ref]$null, [ref]$null)
    $cmds = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() })
    Check '(7) Invoke-TcTestCycle source has no Connect-TcIde command at all' ($cmds -notcontains 'Connect-TcIde') ($cmds -join ',')


    # --- (10) M1 / S3: Invoke-TcTestCycle PLC Run / Stop failures fail the cycle ---
    $blk = [PSCustomObject]@{ amsNetId = $A; command = 'Set-TcPlcState'; errorCode = 'X'; requestedState = 'Stop'; reachedState = 'Run' }
    & $mod {
        param($b)
        $script:UtBlk = $b
        function script:Set-TcPlcState {
            param($State, $TimeoutSec)
            if ($State -eq $global:PlcFailOn) {
                $code = if ($State -eq 'Run') { 'PLC_RUN_TIMEOUT' } else { 'STATE_SET_FAILED' }
                return New-TcResult -Success $false -ErrorCode $code -ErrorMessage "PLC did not reach '$State' (mock)" -Hint 'mock hint' -Data ([PSCustomObject]@{ lifecycleBlock = $script:UtBlk })
            }
            New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State })
        }
        $script:UtTests = 0
        function script:Invoke-TcTest { param($TestCase) $script:UtTests++; New-TcResult -Success $true -Data ([PSCustomObject]@{ name = $TestCase.name; result = 'Pass' }) }
    } $blk
    $tcs = @((New-TcTestCase -Name 't' -WaitUntil @{ Path = 'MAIN.b'; Operator = 'IsTrue' } -Assertions @(@{ Path = 'MAIN.n'; Expected = 1 })))
    $global:PlcFailOn = 'Stop'
    $cy = Invoke-TcTestCycle -TestCases $tcs -SkipBuild
    $stop = @($cy.data.steps | Where-Object { $_.step -eq 'Stop' })
    Check '(10) M1 Stop fails -> cycle success=false with its code / hint / lifecycleBlock' ((-not $cy.success) -and $cy.error.code -eq 'STATE_SET_FAILED' -and $cy.error.hint -eq 'mock hint' -and $cy.data.lifecycleBlock.command -eq 'Set-TcPlcState' -and $stop.Count -eq 1 -and $stop[0].success -eq $false -and $cy.data.passed -eq 1) (J $cy)
    $global:PlcFailOn = 'Run'
    $cy = Invoke-TcTestCycle -TestCases $tcs -SkipBuild
    $nr = @($cy.data.steps | Where-Object { $_.status -eq 'NOT RUN' } | ForEach-Object { $_.step })
    $ran = & $mod { $script:UtTests }
    Check '(10) S3 Run fails -> returned at once (PLC_RUN_TIMEOUT, lifecycleBlock), Tests + Stop NOT RUN, no test ran' ((-not $cy.success) -and $cy.error.code -eq 'PLC_RUN_TIMEOUT' -and $cy.data.lifecycleBlock.command -eq 'Set-TcPlcState' -and ($nr -join ',') -eq 'Tests,Stop' -and $ran -eq 1) "tests=$ran $(J $cy)"
    $global:PlcFailOn = $null

    # --- (11) S1: every failure after set-config / Activate records a block ---
    & $mod { function script:Invoke-TcActivateWithDeadline { param($TimeoutSec, $AmsNetId) throw 'ACTIVATE_TIMEOUT: ActivateConfiguration() did not return within 10 s (mock)' } }
    $fake::Mode = 'run'
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(11) ACTIVATE_TIMEOUT after set-config -> block (Enable-TcConfig, step activate)' ($e.error.code -eq 'ACTIVATE_TIMEOUT' -and $e.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and $e.data.lifecycleBlock.errorCode -eq 'ACTIVATE_TIMEOUT' -and $e.data.lifecycleBlock.step -eq 'activate' -and $e.data.activateSent -and -not $e.data.activated) (J $e.data.lifecycleBlock)
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test (11) next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $e = Enable-TcConfig -WarningAction SilentlyContinue
    Check '(11) ACTIVATE_TIMEOUT without -Force (Activate sent) -> block' ($e.error.code -eq 'ACTIVATE_TIMEOUT' -and $e.data.lifecycleBlock.errorCode -eq 'ACTIVATE_TIMEOUT') (J $e.data.lifecycleBlock)
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test (11) next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    & $mod {
        function script:Invoke-TcActivateWithDeadline { param($TimeoutSec, $AmsNetId) $global:Calls.Activate++ }
        function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) Start-Sleep -Milliseconds 10500; New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State }) }
    }
    $e = Enable-TcConfig -Force -TimeoutSec 10 -WarningAction SilentlyContinue
    Check '(11) CYCLE_TIMEOUT after set-config -> block (step activate)' ($e.error.code -eq 'CYCLE_TIMEOUT' -and $e.data.lifecycleBlock.errorCode -eq 'CYCLE_TIMEOUT' -and $e.data.lifecycleBlock.step -eq 'activate' -and $e.data.reachedState -eq 'Config') (J $e.data.lifecycleBlock)
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test (11) next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    & $mod { function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) New-TcResult -Success $false -ErrorCode 'ADS_TARGET_NOT_FOUND' -ErrorMessage 'connect failed before WriteControl (mock)' -Data ([PSCustomObject]@{}) } }
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(11) set-config that sent nothing (no lifecycleBlock from Set-TcSystemState) -> no block' ($e.error.code -eq 'ADS_TARGET_NOT_FOUND' -and $null -eq $e.data.PSObject.Properties['lifecycleBlock'] -and $null -eq (& $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A)) (J $e.data)
    & $mod { function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State }) } }

    # --- (12) S2: Set-TcSystemState exception after WriteControl -> block; before it -> none ---
    $fake::Mode = 'config'; $fake::ThrowOnWrite = $true
    $x = Set-TcSystemState -State Run -AmsNetId $B -TimeoutSec 2 -SettleSec 0
    $fake::ThrowOnWrite = $false
    Check '(12) exception from WriteControl (request may have gone out) -> failure + block, requestSent=true' ((-not $x.success) -and $x.data.lifecycleBlock.amsNetId -eq $B -and $x.data.lifecycleBlock.step -match 'exception' -and $x.data.requestSent -eq $true) (J $x)
    $null = Clear-TcLifecycleBlock -AmsNetId $B -Reason 'unit test (12) next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $fake::ThrowOnConnect = $true
    $x = Set-TcSystemState -State Run -AmsNetId $B -TimeoutSec 2 -SettleSec 0
    $fake::ThrowOnConnect = $false
    Check '(12) exception before WriteControl (connect) -> failure, no block, requestSent=false' ((-not $x.success) -and $x.data.requestSent -eq $false -and $null -eq (& $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $B)) (J $x)
    $fake::Mode = 'config'; $fake::NextMode = 'run'
    $x = Set-TcSystemState -State Run -AmsNetId $B -TimeoutSec 5 -SettleSec 0
    $fake::NextMode = $null
    Check '(12) nit-3 success reports requestSent=true' ($x.success -and $x.data.requestSent -eq $true) (J $x.data)

    # --- (13) N2: ADS commands check the block with the session NetId after Ensure-TcAdsConnection ---
    $null = & $mod { param($n) Set-TcLifecycleBlock -AmsNetId $n -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' } $B
    & $mod { function script:Ensure-TcAdsConnection { if ($global:EnsureThrows) { throw 'Not connected to ADS (mock)' }; $false } }
    $global:EnsureThrows = $true
    & $mod { $script:TcAdsAmsNetId = $null; $script:TcAdsConnected = $false }
    $w = Write-TcVariable -Path 'MAIN.x' -Value 1
    Check '(13) never connected (no session NetId) -> original NOT_CONNECTED, nothing sent' ($w.error.code -eq 'NOT_CONNECTED') "code=$($w.error.code)"
    Set-Session $B
    $w = Write-TcVariable -Path 'MAIN.x' -Value 1
    $t = Set-TcPlcState -State Stop
    Check '(13) reconnect failed but the session NetId is blocked -> LIFECYCLE_BLOCKED (fail closed)' ($w.error.code -eq 'LIFECYCLE_BLOCKED' -and $t.error.code -eq 'LIFECYCLE_BLOCKED') "write=$($w.error.code) plc=$($t.error.code)"
    $global:EnsureThrows = $false
    Set-Session $A
    $w = Write-TcVariable -Path 'MAIN.x' -Value 1
    Check '(13) connected to another target -> not refused' ($w.error.code -ne 'LIFECYCLE_BLOCKED') "code=$($w.error.code)"
    $null = Clear-TcLifecycleBlock -AmsNetId $B -Reason 'unit test (13) done' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None

    # --- (14) review 2: S-A nested precondition codes after set-config, S-B -PlcProjectPath, nit-3 requestSent ---
    & $mod {
        $script:UtSss = 0
        function script:Set-TcSystemState {
            param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
            $script:UtSss++
            if ($null -ne $global:SetConfigFail -and $State -eq 'Config') {
                return New-TcResult -Success $false -ErrorCode 'ADS_TIMEOUT' -ErrorMessage 'mock failure' -Data ([PSCustomObject]@{ requestSent = [bool]$global:SetConfigFail })
            }
            New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State; requestSent = $true })
        }
        function script:Enter-TcPlcOnline {
            param($LoginMode, $PlcProjectPath, $TimeoutSec)
            if ($global:LoginCode) { return New-TcResult -Success $false -ErrorCode $global:LoginCode -ErrorMessage 'login refused (mock)' }
            New-TcResult -Success $true -Data ([PSCustomObject]@{ message = 'mock login' })
        }
    }
    $fake::Mode = 'run'; $global:PlcState = 'Run'
    foreach ($lc in @('NOT_CONNECTED', 'BUILD_REQUIRED')) {
        $global:LoginCode = $lc
        $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
        Check "(14) S-A login returns $lc after set-config / Activate -> block recorded" ($e.error.code -eq $lc -and $e.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and $e.data.lifecycleBlock.errorCode -eq $lc -and $e.data.lifecycleBlock.step -eq 'login') (J $e.data.lifecycleBlock)
        $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test (14) next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    }
    $global:LoginCode = $null
    & $mod { $script:UtSss = 0 }
    $e = Enable-TcConfig -Force -PlcProjectPath 'NoSuchPlc' -WarningAction SilentlyContinue
    $sss = & $mod { $script:UtSss }
    Check '(14) S-B -PlcProjectPath typo -> PLC_PROJECT_NOT_FOUND before set-config, no block, runtime untouched; hint: check the name (side finding 5)' ($e.error.code -eq 'PLC_PROJECT_NOT_FOUND' -and $e.error.hint -match '-PlcProjectPath' -and $e.error.hint -match 'Get-TcProjectTree' -and $e.error.hint -notmatch 'Activate' -and $sss -eq 0 -and $null -eq $e.data.PSObject.Properties['lifecycleBlock'] -and $null -eq (& $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A) -and -not $e.data.activateSent) "sss=$sss $(J $e.data.steps)"
    $e = Enable-TcConfig -Force -PlcProjectPath 'P' -WarningAction SilentlyContinue
    Check '(14) S-B existing -PlcProjectPath passes the early check' ($e.success) "$($e.error.code) $($e.error.message)"
    $global:SetConfigFail = $true
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(14) nit-3 set-config failed with data.requestSent=true -> block (no lifecycleBlock needed)' ($e.error.code -eq 'ADS_TIMEOUT' -and $e.data.lifecycleBlock.step -eq 'set-config' -and $e.data.lifecycleBlock.requestedState -eq 'Config') (J $e.data.lifecycleBlock)
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test (14) next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $global:SetConfigFail = $false
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(14) nit-3 set-config failed with data.requestSent=false -> no block' ($e.error.code -eq 'ADS_TIMEOUT' -and $null -eq $e.data.PSObject.Properties['lifecycleBlock'] -and $null -eq (& $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A)) (J $e.data)
    $global:SetConfigFail = $null

    # --- (14b) S-2: nested stop / read-only texts are collapsed into exactly one stop text ---
    & $mod {
        function script:Set-TcSystemState {
            param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
            if ($State -eq 'Config') {
                # the real Set-TcSystemState path: ADS 0x7 after WriteControl -> block + stop text
                $res = New-TcResult -Success $false -ErrorCode 'ADS_TARGET_NOT_FOUND' -ErrorMessage 'Ads-Error 0x7 (mock)' -Hint (Get-TcErrorHint -Code 'ADS_TARGET_NOT_FOUND') -Data ([PSCustomObject]@{ requestSent = $true }) -LifecycleNetId $AmsNetId
                return (Add-TcLifecycleBlockResult -Result $res -Command 'Set-TcSystemState' -AmsNetId $AmsNetId -RequestedState $State -Step 'after the state request (exception)')
            }
            New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State; requestSent = $true })
        }
    }
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    $stopP = & $mod { $script:TcLifecycleStopPrefix }
    $roP = & $mod { $script:TcLifecycleReadOnlyPrefix }
    $nStop = ([regex]::Matches([string]$e.error.hint, [regex]::Escape($stopP))).Count
    $nRo = ([regex]::Matches([string]$e.error.hint, [regex]::Escape($roP))).Count
    Check '(14b) S-2 set-config ADS_TARGET_NOT_FOUND through the nested path -> stop text exactly once, no read-only text' ($e.error.code -eq 'ADS_TARGET_NOT_FOUND' -and $nStop -eq 1 -and $nRo -eq 0 -and $e.data.lifecycleBlock.command -eq 'Enable-TcConfig') "stop=$nStop ro=$nRo hint=$($e.error.hint)"
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test (14b) cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None

    # --- (14c) #114 N1 / N2: set-config timed out with port 10000 unreachable -> Enable-TcConfig keeps
    # reachedState empty and readbackNote 'unreachable' (not 'Unreachable' as a state, not lost)
    & $mod {
        function script:Set-TcSystemState {
            param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
            if ($State -eq 'Config') {
                $res = New-TcResult -Success $false -ErrorCode 'SYSTEM_STATE_TIMEOUT' -ErrorMessage 'did not reach Config (last state: unreachable) (mock)' -Data ([PSCustomObject]@{ requestSent = $true; currentState = 'Unreachable'; finalState = 'Unreachable'; readbackState = $null; lastState = 'Run' })
                return (Add-TcLifecycleBlockResult -Result $res -Command 'Set-TcSystemState' -AmsNetId $AmsNetId -RequestedState $State -ReadbackNote 'unreachable' -Step 'wait: port 10000 unreachable at the deadline; last state read before: Run')
            }
            New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State; requestSent = $true })
        }
    }
    $e = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(14c) #114 set-config unreachable timeout -> Enable-TcConfig block: reachedState empty, readbackNote unreachable, data.reachedState empty' ($e.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $e.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and [string]::IsNullOrEmpty([string]$e.data.lifecycleBlock.reachedState) -and $e.data.lifecycleBlock.readbackNote -eq 'unreachable' -and [string]::IsNullOrEmpty([string]$e.data.reachedState)) (J $e.data.lifecycleBlock)
    $tb = & $mod { param($n) Test-TcLifecycleBlock -AmsNetId $n -Command 'Set-TcPlcState' } $A
    Check '(14c) #114 N5 block message from readbackNote: nothing (port 10000 unreachable)' ($tb.error.message -match 'nothing \(port 10000 unreachable\)' -and $tb.error.message -notmatch "read back 'Unreachable'") "$($tb.error.message)"
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test (14c) cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    & $mod { function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State; requestSent = $true }) } }

    # --- (8) persistence and corrupt state ---
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.5.5.5.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' -RequestedState 'Run' -ReachedState 'Config' }
    Import-Module $modulePath -Force -WarningAction SilentlyContinue
    $mod = Get-Module TwinCATAutomation
    $seen = & $mod { Get-TcLifecycleBlock -AmsNetId '10.5.5.5.1.1' }
    Check '(8) block survives Import-Module -Force (file)' ($null -ne $seen -and $seen.errorCode -eq 'SYSTEM_STATE_TIMEOUT') (J $seen)
    $none = & $mod { Get-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' }
    Check '(8) other target: no block' ($null -eq $none) (J $none)
    $unk = & $mod { Get-TcLifecycleBlock -AmsNetId '' }
    Check '(8) unknown AmsNetId is blocked by any record (fail closed)' ($null -ne $unk) (J $unk)
    # --- (8) S5 / N4 / N1: unreadable state file ---
    [IO.File]::WriteAllText($stateFile, '{ not json')
    $cor = & $mod { Get-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' }
    $kept = @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter 'lifecycle-block.json.corrupt-*')
    Check '(8) unparseable file -> <corrupt> record blocks every target, old file kept' ($null -ne $cor -and $cor.errorCode -eq 'state-corrupt' -and $kept.Count -eq 1) (J $cor)
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.7.7.7.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' }
    $onDisk = (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json)
    $stillA = & $mod { Get-TcLifecycleBlock -AmsNetId '10.5.5.5.1.1' }
    Check '(8) S5 target B written after the file broke: <corrupt> kept, B added, A still blocked' ($null -ne $onDisk.PSObject.Properties['<corrupt>'] -and $null -ne $onDisk.PSObject.Properties['10.7.7.7.1.1'] -and $null -ne $stillA) (Get-Content -LiteralPath $stateFile -Raw)
    $cc = Clear-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' -Reason 'user looked at the corrupt state' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(8) N1 Clear of another key names what still blocks every target' ($cc.success -and @($cc.data.stillBlocking) -contains '<corrupt>' -and $cc.data.message -match "-AmsNetId '<corrupt>'" -and @($cc.data.next).Count -eq 1) (J $cc.data)
    $cc = Clear-TcLifecycleBlock -AmsNetId '<corrupt>' -Reason 'user removed the corrupt state' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(8) Clear <corrupt> -> the <corrupt> record is gone, B still blocked' ($cc.success -and $cc.data.cleared.errorCode -eq 'state-corrupt' -and $null -ne (& $mod { Get-TcLifecycleBlock -AmsNetId '10.7.7.7.1.1' }) -and $null -eq (& $mod { Get-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' })) (J $cc.data)
    $null = Clear-TcLifecycleBlock -AmsNetId '10.7.7.7.1.1' -Reason 'unit test cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    foreach ($bad in @('null', '[1, 2]', '"text"', '{ "10.1.1.1.1.1": 5 }')) {
        [IO.File]::WriteAllText($stateFile, $bad)
        $g = & $mod { Get-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' }
        Check "(8) N4 content $bad -> treated as corrupt (blocks)" ($null -ne $g -and $g.errorCode -eq 'state-corrupt') (J $g)
        $null = Clear-TcLifecycleBlock -AmsNetId '<corrupt>' -Reason 'unit test cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    }

    # --- (9) S4: loopback NetId is compared with every record ---
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '127.0.0.1.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' }
    $any = & $mod { Get-TcLifecycleBlock -AmsNetId '10.8.8.8.1.1' }
    $key = & $mod { ConvertTo-TcLifecycleKey '127.0.0.1.1.1' }
    Check '(9) block written for 127.0.0.1.1.1 goes to <unknown> and blocks every target' ($key -eq '<unknown>' -and $null -ne $any) (J $any)
    $cc = Clear-TcLifecycleBlock -AmsNetId '10.8.8.8.1.1' -Reason 'user checked target 10.8.8.8' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(9) N1 Clear of a real target names <unknown> still blocking' (@($cc.data.stillBlocking) -contains '<unknown>' -and $cc.data.message -match "-AmsNetId '<unknown>'") (J $cc.data)
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.4.4.4.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' }
    $cc = Clear-TcLifecycleBlock -AmsNetId '<unknown>' -Reason 'user checked the loopback target' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(9) nit-1 Clear <unknown> lists every remaining key as still blocking' ($cc.data.cleared.amsNetId -eq '127.0.0.1.1.1' -and @($cc.data.stillBlocking) -contains '10.4.4.4.1.1' -and $cc.data.message -match "-AmsNetId '10.4.4.4.1.1'") (J $cc.data)
    $null = Clear-TcLifecycleBlock -AmsNetId '10.4.4.4.1.1' -Reason 'unit test cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.9.9.9.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' }
    $lb = & $mod { Get-TcLifecycleBlock -AmsNetId '127.0.0.1.1.1' }
    $lb2 = & $mod { Get-TcLifecycleBlock -AmsNetId '127.1.2.3.1.1' }
    Check '(9) command on a loopback NetId is blocked by any record' ($null -ne $lb -and $null -ne $lb2 -and $lb.amsNetId -eq '10.9.9.9.1.1') (J $lb)
    $null = Clear-TcLifecycleBlock -AmsNetId '10.9.9.9.1.1' -Reason 'unit test cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $null = Clear-TcLifecycleBlock -AmsNetId '10.5.5.5.1.1' -Reason 'unit test cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None

    # --- (15) V4 (real machine 2026-11-04): clearing the LAST record must not read as "could not be read" ---
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' }
    $cc = Clear-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Reason 'user approved after the real-machine check' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    $js = $cc.data | ConvertTo-Json -Compress -Depth 6
    Check '(15) V4 clear the only record -> no "could not be read", remaining / remainingKeys / stillBlocking are empty arrays' ($cc.success -and $cc.data.cleared.amsNetId -eq '10.3.3.3.1.1' -and $cc.data.message -notmatch 'could not be read' -and $cc.data.message -match 'No lifecycle block is left' -and $null -ne $cc.data.remaining -and $cc.data.remaining -is [array] -and @($cc.data.remaining).Count -eq 0 -and $cc.data.remainingKeys -is [array] -and @($cc.data.remainingKeys).Count -eq 0 -and $cc.data.stillBlocking -is [array] -and @($cc.data.stillBlocking).Count -eq 0) $js
    Check '(15) V4 JSON has "remaining":[] and "remainingKeys":[]' ($js -match '"remaining":\[\]' -and $js -match '"remainingKeys":\[\]' -and $js -match '"stillBlocking":\[\]') $js
    $lst = (& $mod { $x = Get-TcLifecycleBlockList; @{ V = $x } }).V
    Check '(15) V4 / nit-5 Get-TcLifecycleBlockList with no record -> Readable, List = empty array' ($lst.Readable -eq $true -and $lst.List -is [array] -and $lst.List.Count -eq 0) (J $lst)
    $nb = & $mod { Get-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' }
    Check '(15) V4 Get-TcLifecycleBlock with no record -> $null (not blocked)' ($null -eq $nb) (J $nb)
    # control: the state file really cannot be read (held open without sharing) -> fail closed
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' }
    $fs = [IO.File]::Open($stateFile, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        $lst = (& $mod { $x = Get-TcLifecycleBlockList; @{ V = $x } }).V
        $gb = & $mod { Get-TcLifecycleBlock -AmsNetId '10.2.2.2.1.1' }
        $cc = Clear-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Reason 'control: file locked' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    }
    finally { $fs.Dispose() }
    Check '(15) control: unreadable file -> list $null, every target blocked (state-unreadable), Clear fails closed' ($lst.Readable -eq $false -and $gb.errorCode -eq 'state-unreadable' -and -not $cc.success -and $cc.error.code -eq 'LIFECYCLE_BLOCKED') "list=$(J $lst) clear=$(J $cc)"
    $cc = Clear-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Reason 'unit test cleanup after the control' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    Check '(15) after the lock is gone the record clears normally' ($cc.success -and $cc.data.cleared.amsNetId -eq '10.3.3.3.1.1' -and @($cc.data.remaining).Count -eq 0 -and $cc.data.message -notmatch 'could not be read') (J $cc.data)

    # --- (16) side findings 3 / 4: hints that point at blocked commands are replaced while blocked ---
    & $mod { $script:TcAdsAmsNetId = '10.3.3.3.1.1' }
    $plain = & $mod { New-TcResult -Success $false -ErrorCode 'ADS_TARGET_NOT_FOUND' -ErrorMessage 'no answer (mock)' -Hint (Get-TcErrorHint -Code 'ADS_TARGET_NOT_FOUND') }
    $orig = & $mod { Get-TcErrorHint -Code 'ADS_TARGET_NOT_FOUND' }
    Check '(16) no block -> ADS_TARGET_NOT_FOUND keeps its usual hint, no lifecycleBlock' ($plain.error.hint -eq $orig -and $null -eq $plain.PSObject.Properties['data']) (J $plain)
    $null = & $mod { Set-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Command 'Set-TcSystemState' -ErrorCode 'RUNTIME_CRASHED' -RequestedState 'Config' }
    $pre = & $mod { $script:TcLifecycleReadOnlyPrefix }
    foreach ($code in @('ADS_TARGET_NOT_FOUND', 'ADS_PORT_NOT_FOUND', 'NOT_CONNECTED', 'PLC_NOT_LOADED')) {
        $x = & $mod { param($c) New-TcResult -Success $false -ErrorCode $c -ErrorMessage 'mock' -Hint (Get-TcErrorHint -Code $c) } $code
        Check "(16) block on the session target -> $code hint starts with the stop text, data.lifecycleBlock attached" ($x.error.code -eq $code -and $x.error.hint.StartsWith($pre) -and $x.error.hint -match 'Clear-TcLifecycleBlock' -and $x.data.lifecycleBlock.errorCode -eq 'RUNTIME_CRASHED') (J $x)
    }
    $ae = & $mod { $e = $null; try { throw 'Ads-Error 0x7 : Target machine could not be found.' } catch { $e = $_ }; New-TcAdsErrorResult -ErrorRecord $e -DefaultCode 'ADS_CONNECT_FAILED' -MessagePrefix 'mock' }
    Check '(16) the same through New-TcAdsErrorResult (ADS 0x7 -> ADS_TARGET_NOT_FOUND)' ($ae.error.code -eq 'ADS_TARGET_NOT_FOUND' -and $ae.error.hint.StartsWith($pre)) (J $ae)
    # S-1: the hint follows the failing call's target, not just any record
    $nc = & $mod { Get-TcErrorHint -Code 'NOT_CONNECTED' }
    & $mod { $script:TcAdsAmsNetId = $null }
    $u = & $mod { New-TcResult -Success $false -ErrorCode 'NOT_CONNECTED' -ErrorMessage 'mock' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED') }
    Check '(16) S-1 session target unknown, block on another target -> NOT_CONNECTED hint kept (one note appended), no lifecycleBlock' ($u.error.hint.StartsWith($nc) -and $u.error.hint -match '#68' -and -not $u.error.hint.StartsWith($pre) -and $null -eq $u.PSObject.Properties['data']) (J $u)
    # #114 minor 5: no ADS session, but the connected IDE's target IS the blocked one -> "this target"
    # (read-only prefix + data.lifecycleBlock), not "another target"
    $ideSaved = $global:IdeTarget
    $global:IdeTarget = '10.3.3.3.1.1'
    # S5: the hint path makes no COM call; it uses the NetId an earlier command read from the IDE.
    # GetTargetNetId throws here: it must not be called.
    & $mod { $script:TcIdeConnected = $true; $sm = [PSCustomObject]@{ Mock = $true }; $sm | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { throw 'GetTargetNetId must not be called on the hint path' }; $script:TcSysManager = $sm; Save-TcIdeTargetNetId '10.3.3.3.1.1' }
    $ui = & $mod { New-TcResult -Success $false -ErrorCode 'NOT_CONNECTED' -ErrorMessage 'mock' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED') }
    Check '(16) #114 no ADS session, IDE target blocked -> NOT_CONNECTED hint starts with the read-only text, data.lifecycleBlock, no "another target" note' ($ui.error.hint.StartsWith($pre) -and $ui.error.hint.Contains($nc) -and $ui.data.lifecycleBlock.amsNetId -eq '10.3.3.3.1.1' -and -not $ui.error.hint.Contains((& $mod { $script:TcLifecycleOtherBlockNote }))) (J $ui)
    & $mod { Save-TcIdeTargetNetId '10.4.4.4.1.1' }
    $uo = & $mod { New-TcResult -Success $false -ErrorCode 'NOT_CONNECTED' -ErrorMessage 'mock' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED') }
    Check '(16) #114 no ADS session, IDE target NOT blocked (block on another target) -> hint kept + note, no lifecycleBlock' ($uo.error.hint.StartsWith($nc) -and $uo.error.hint.Contains((& $mod { $script:TcLifecycleOtherBlockNote })) -and $null -eq $uo.PSObject.Properties['data']) (J $uo)
    & $mod { $script:TcIdeConnected = $true; $script:TcSysManager = [PSCustomObject]@{ Other = $true } }
    $ux = & $mod { New-TcResult -Success $false -ErrorCode 'NOT_CONNECTED' -ErrorMessage 'mock' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED') }
    Check '(16) #114 S5 cached NetId of another ITcSysManager (IDE reconnected) is not used -> note only' ($ux.error.hint.Contains((& $mod { $script:TcLifecycleOtherBlockNote })) -and $null -eq $ux.PSObject.Properties['data']) (J $ux)
    & $mod { $script:TcIdeConnected = $false; $script:TcIdeTargetNetIdCache = $null }
    $global:IdeTarget = $ideSaved
    & $mod { $script:TcAdsAmsNetId = '10.9.9.9.1.1' }
    $nb = & $mod { New-TcResult -Success $false -ErrorCode 'NOT_CONNECTED' -ErrorMessage 'mock' -Hint (Get-TcErrorHint -Code 'NOT_CONNECTED') }
    Check '(16) S-1 session on target B (no block) -> hint unchanged' ($nb.error.hint -eq $nc -and $null -eq $nb.PSObject.Properties['data']) (J $nb)
    $ae2 = & $mod { $e = $null; try { throw 'Ads-Error 0x7 : Target machine could not be found.' } catch { $e = $_ }; New-TcAdsErrorResult -AmsNetId '10.3.3.3.1.1' -ErrorRecord $e -DefaultCode 'SYSTEM_STATE_FAILED' -MessagePrefix 'mock' }
    Check '(16) S-1 session on B, the failing call names target A (blocked) -> hint replaced, data.lifecycleBlock' ($ae2.error.code -eq 'ADS_TARGET_NOT_FOUND' -and $ae2.error.hint.StartsWith($pre) -and $ae2.data.lifecycleBlock.amsNetId -eq '10.3.3.3.1.1') (J $ae2)
    & $mod { $script:TcAdsAmsNetId = '10.3.3.3.1.1' }
    $sy = & $mod { New-TcResult -Success $false -ErrorCode 'SYMBOL_NOT_FOUND' -ErrorMessage 'mock' -Hint (Get-TcErrorHint -Code 'SYMBOL_NOT_FOUND') }
    $syh = & $mod { Get-TcErrorHint -Code 'SYMBOL_NOT_FOUND' }
    Check '(16) nit-3 SYMBOL_NOT_FOUND with a block -> hint kept, data.lifecycleBlock attached' ($sy.error.hint -eq $syh -and $sy.data.lifecycleBlock.amsNetId -eq '10.3.3.3.1.1') (J $sy)
    $nic = & $mod { $script:TcLifecycleHintCodes -contains 'NOT_CONNECTED_IDE' }
    Check '(16) S-1 NOT_CONNECTED_IDE is not in the replace list' (-not $nic) ''
    $din = [PSCustomObject]@{ a = 1 }
    $dr = & $mod { param($d) New-TcResult -Success $false -ErrorCode 'ADS_PORT_NOT_FOUND' -ErrorMessage 'mock' -Data $d } $din
    Check '(16) nit-1 the caller''s -Data object is not changed (copy gets lifecycleBlock)' ($null -eq $din.PSObject.Properties['lifecycleBlock'] -and $null -ne $dr.data.lifecycleBlock -and $dr.data.a -eq 1) (J $din)
    $other = & $mod { New-TcResult -Success $false -ErrorCode 'BUILD_FAILED' -ErrorMessage 'mock' -Hint 'build hint' }
    Check '(16) codes whose hint is not a runtime-changing step are left alone' ($other.error.hint -eq 'build hint') (J $other)
    $tb = & $mod { Test-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Command 'Set-TcPlcState' }
    Check '(16) side finding 2: block message of a crash says nothing was read back, no success-like wording' ($tb.error.message -match "requested 'Config'" -and $tb.error.message -match 'nothing \(runtime gone\)' -and $tb.error.message -match 'did NOT succeed' -and $tb.error.message -notmatch "read back '") "$($tb.error.message)"
    $null = Clear-TcLifecycleBlock -AmsNetId '10.3.3.3.1.1' -Reason 'unit test (16) cleanup' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None
    & $mod { $script:TcAdsAmsNetId = $null }

    # --- registration ---
    $h = & $mod { Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED' }
    Check 'LIFECYCLE_BLOCKED hint registered' ($h -match 'Clear-TcLifecycleBlock' -and $h -match 'NOT RUN') "$h"
}
finally {
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\TCAUTO_STATE_DIR -ErrorAction SilentlyContinue
}
"failed: $fail"
exit [Math]::Min($fail, 255)
