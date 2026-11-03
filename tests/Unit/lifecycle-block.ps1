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
#   (8) block in the file is seen by a fresh module instance; unparseable file blocks every target,
#       Clear moves it aside
#   powershell.exe -NoProfile -File tests/Unit/lifecycle-block.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
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
        public void Connect(string netId, int port) { }
        public StateInfo ReadState() {
            StateInfo s = new StateInfo();
            s.AdsState = (Mode == "run") ? AdsState.Run : AdsState.Config;
            return s;
        }
        public void WriteControl(StateInfo s) { Writes++; if (!string.IsNullOrEmpty(NextMode)) { Mode = NextMode; } }
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
    function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $null }
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
    Check '(1) hint starts with the stop instruction' ($r.error.hint -match '^LIFECYCLE_BLOCKED is now recorded' -and $r.error.hint -match 'Clear-TcLifecycleBlock' -and $r.error.hint -match 'raw ADS') "$($r.error.hint)"
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
        Check "(2) $k -> LIFECYCLE_BLOCKED, data.lifecycleBlock, NOT RUN" ((-not $x.success) -and $x.error.code -eq 'LIFECYCLE_BLOCKED' -and $x.data.notRun -eq $true -and $x.data.lifecycleBlock.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $x.data.command -eq $exp -and $x.error.hint -match 'Clear-TcLifecycleBlock') "code=$($x.error.code) cmd=$($x.data.command)"
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
    $threw = $false
    try { $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason '' } catch { $threw = $true }
    Check '(4) -Reason is required (empty refused)' $threw ''
    $c = Clear-TcLifecycleBlock -Reason 'user checked the license and approved a new Enable-TcConfig -Force'
    Check '(4) Clear (AmsNetId from the IDE target) returns the removed record + receipt' ($c.success -and $c.data.cleared.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and $c.data.amsNetId -eq $A -and $c.data.netIdSource -eq 'resolved' -and $c.data.receipt.reason -match 'approved') (J $c.data)
    $hist = Join-Path $env:TCAUTO_STATE_DIR 'lifecycle-block-history.jsonl'
    Check '(4) receipt appended to lifecycle-block-history.jsonl' ((Test-Path -LiteralPath $hist) -and ((Get-Content -LiteralPath $hist -Raw) -match 'approved')) ''
    Reset-Calls
    $w = Write-TcVariable -Path 'MAIN.bStart' -Value $true
    Check '(4) after Clear, Write-TcVariable is no longer refused' ($w.error.code -ne 'LIFECYCLE_BLOCKED') "code=$($w.error.code)"
    $c2 = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'second call'
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
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'test (5) done'

    # Enable-TcConfig -Force success: the done fields are true and match the facts
    Reset-Calls; $fake::Mode = 'run'
    & $mod { function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) $global:Calls.SetSystemState++; New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State }) } }
    $ok = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check '(5) success: activated / restarted / loggedIn true, reachedState Run, no block' ($ok.success -and $ok.data.activated -and $ok.data.restarted -and $ok.data.loggedIn -and $ok.data.reachedState -eq 'Run' -and $null -eq $ok.data.PSObject.Properties['lifecycleBlock']) "code=$($ok.error.code) msg=$($ok.error.message)"

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
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'reset'
    $global:PlcState = 'Stop'
    $t = Set-TcPlcState -State Run -TimeoutSec 1
    Check '(6) Set-TcPlcState Run not reached -> PLC_RUN_TIMEOUT + block' ($t.error.code -eq 'PLC_RUN_TIMEOUT' -and $t.data.lifecycleBlock.command -eq 'Set-TcPlcState' -and $t.data.lifecycleBlock.requestedState -eq 'Run' -and $t.data.lifecycleBlock.reachedState -eq 'Stop') (J $t.data)
    $null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'reset'
    $null = Clear-TcLifecycleBlock -AmsNetId $B -Reason 'reset'

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
    [IO.File]::WriteAllText($stateFile, '{ not json')
    $cor = & $mod { Get-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' }
    Check '(8) unparseable file blocks every target (state-unreadable)' ($null -ne $cor -and $cor.errorCode -eq 'state-unreadable') (J $cor)
    $cc = Clear-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' -Reason 'user removed the corrupt state'
    Check '(8) Clear moves the unparseable file aside (corruptBackup)' ($cc.success -and -not [string]::IsNullOrWhiteSpace([string]$cc.data.corruptBackup) -and (Test-Path -LiteralPath $cc.data.corruptBackup) -and $null -eq (& $mod { Get-TcLifecycleBlock -AmsNetId '10.6.6.6.1.1' })) (J $cc.data)

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
