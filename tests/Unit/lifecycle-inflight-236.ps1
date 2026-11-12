# Unit: #236 a runtime-changing command whose PROCESS is killed after the request went out (the MCP
# modal probe kills the PowerShell bridge on IDE_MODAL_DIALOG, BRIDGE_TIMEOUT, Ctrl+C, a crash)
# leaves an in-flight marker; the next lifecycle check in ANY process turns it into a lifecycle
# block (fail closed, #68). No IDE / ADS / runtime needed. Covers:
#   (1) child process: Set-TcSystemState hangs inside WriteControl and is killed -> the next
#       Set-TcSystemState in this process is LIFECYCLE_BLOCKED (errorCode INTERRUPTED)
#   (2) child process: Enable-TcConfig (no -Force) hangs inside ActivateConfiguration() and is
#       killed -> blocked, record names Enable-TcConfig
#   (3) successful Set-TcSystemState / Enable-TcConfig leave no marker
#   (4) marker of a live process (same start time) is not promoted; a reused pid (other start
#       time) is; a corrupt marker blocks every target ('<unknown>')
#   (5) a newer record of the same target is kept (not overwritten by the marker)
#   (6) an exception escaping Enable-TcConfig after the request records a block and is rethrown
#   powershell.exe -NoProfile -File tests/Unit/lifecycle-inflight-236.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-state-{0}" -f [guid]::NewGuid().ToString('N'))
$modulePath = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$modulePath = (Resolve-Path $modulePath).Path
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$A = '10.1.2.3.1.1'
$B = '10.9.8.7.1.1'
$null = New-Item -ItemType Directory -Force -Path $env:TCAUTO_STATE_DIR
$work = Join-Path $env:TCAUTO_STATE_DIR 'child'
$null = New-Item -ItemType Directory -Force -Path $work

# Fake ADS client + module stubs, shared by this process and the child processes. HangFile: when
# set, WriteControl writes it and then blocks (a request that went out and never came back).
$fakeAds = @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Config = 15, Reconfig = 16 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public static string Mode = "config";
        public static string HangFile = null;
        public void Connect(string netId, int port) { }
        public StateInfo ReadState() { StateInfo s = new StateInfo(); s.AdsState = (Mode == "run") ? AdsState.Run : AdsState.Config; return s; }
        public void WriteControl(StateInfo s) {
            if (!string.IsNullOrEmpty(HangFile)) { System.IO.File.WriteAllText(HangFile, "sent"); System.Threading.Thread.Sleep(600000); }
            Mode = (s.AdsState == AdsState.Reconfig) ? "config" : "run";
        }
        public void Dispose() { }
    }
}
'@
$stubs = {
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
        $o
    }
    function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Read-TcCurrentVariant { param($SysManager) @{ Value = ''; Error = $null } }
    function script:Get-TcPlcProjectList { param($SysManager) @([PSCustomObject]@{ name = 'P'; nodePath = 'TIPC^P'; projectPath = 'TIPC^P^P Project'; adsPort = 851; disabled = $false }) }
    function script:Get-TcBootPackageDiff { param($SolutionPath, $Platform, $AmsNetId, $AdsPorts, $Variant) $null }
    function script:Invoke-TcActivateWithDeadline {
        param($TimeoutSec, $AmsNetId)
        if ($global:ActivateHangFile) { [IO.File]::WriteAllText($global:ActivateHangFile, 'sent'); [Threading.Thread]::Sleep(600000) }
    }
    $script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = [PSCustomObject]@{ LastBuildInfo = 0 } } }
    $script:TcSolutionPath = 'C:\Demo\Guard.sln'
    $script:TcSilentMode = $true
}

$adsFile = Join-Path $work 'FakeAds.cs'
$stubFile = Join-Path $work 'Stubs.ps1'
[IO.File]::WriteAllText($adsFile, $fakeAds)
[IO.File]::WriteAllText($stubFile, $stubs.ToString())
$childFile = Join-Path $work 'Child.ps1'
[IO.File]::WriteAllText($childFile, @'
param([string]$ModulePath, [string]$AdsFile, [string]$StubFile, [string]$Mode, [string]$HangFile, [string]$NetId)
$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition ([IO.File]::ReadAllText($AdsFile))
Import-Module $ModulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
& $mod ([scriptblock]::Create([IO.File]::ReadAllText($StubFile)))
$global:IdeTarget = $NetId
if ($Mode -eq 'sys') { [TwinCAT.Ads.TcAdsClient]::HangFile = $HangFile; $null = Set-TcSystemState -State Config -AmsNetId $NetId -TimeoutSec 5 -SettleSec 0 }
else { $global:ActivateHangFile = $HangFile; $null = Enable-TcConfig -WarningAction SilentlyContinue }
'@)

function Invoke-KilledChild([string]$Mode, [string]$NetId) {
    $hang = Join-Path $work ("hang-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $p = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-File', "`"$childFile`"",
        '-ModulePath', "`"$modulePath`"", '-AdsFile', "`"$adsFile`"", '-StubFile', "`"$stubFile`"", '-Mode', $Mode, '-HangFile', "`"$hang`"", '-NetId', $NetId
    $deadline = (Get-Date).AddSeconds(90)
    while (-not (Test-Path -LiteralPath $hang) -and -not $p.HasExited -and (Get-Date) -lt $deadline) { [Threading.Thread]::Sleep(200) }
    $reached = Test-Path -LiteralPath $hang
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force; $null = $p.WaitForExit(10000) }
    $reached
}

Add-Type -TypeDefinition $fakeAds
$fake = [TwinCAT.Ads.TcAdsClient]
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
& $mod $stubs
$global:IdeTarget = $A
$inflightGlob = 'lifecycle-inflight.*.json'
function Get-Markers { @(Get-ChildItem -LiteralPath $env:TCAUTO_STATE_DIR -Filter $inflightGlob -ErrorAction SilentlyContinue) }
function Clear-Block([string]$NetId) { $null = Clear-TcLifecycleBlock -AmsNetId $NetId -Reason 'unit test #236 next case' -FallbackMethod 'unit test' -AllowedSideEffects 'none' -MaxVerifyLevel None }

try {
    # --- (1) Set-TcSystemState killed inside WriteControl ---
    $reached = Invoke-KilledChild -Mode 'sys' -NetId $A
    Check '(1) child reached WriteControl and was killed' $reached ''
    $fake::Mode = 'run'   # Config from Run: the restart is observed
    $r = Set-TcSystemState -State Config -AmsNetId $A -TimeoutSec 2 -SettleSec 0
    Check '(1) next Set-TcSystemState is LIFECYCLE_BLOCKED (INTERRUPTED, Set-TcSystemState, Config)' ((-not $r.success) -and $r.error.code -eq 'LIFECYCLE_BLOCKED' -and $r.data.lifecycleBlock.errorCode -eq 'INTERRUPTED' -and $r.data.lifecycleBlock.command -eq 'Set-TcSystemState' -and $r.data.lifecycleBlock.requestedState -eq 'Config' -and $r.data.lifecycleBlock.amsNetId -eq $A) "code=$($r.error.code) block=$(J $r.data.lifecycleBlock)"
    Check '(1) the marker was consumed' ((Get-Markers).Count -eq 0) ((Get-Markers) -join ', ')
    $fake::Mode = 'run'
    $o = Set-TcSystemState -State Config -AmsNetId $B -TimeoutSec 2 -SettleSec 0
    Check '(1) another target is not blocked' ($o.success) "code=$($o.error.code)"
    Clear-Block $A

    # --- (2) Enable-TcConfig killed inside ActivateConfiguration() ---
    $reached = Invoke-KilledChild -Mode 'enable' -NetId $A
    Check '(2) child reached ActivateConfiguration() and was killed' $reached ''
    $e = Enable-TcConfig -WarningAction SilentlyContinue
    Check '(2) next Enable-TcConfig is LIFECYCLE_BLOCKED (INTERRUPTED, Enable-TcConfig, Activated)' ((-not $e.success) -and $e.error.code -eq 'LIFECYCLE_BLOCKED' -and $e.data.lifecycleBlock.errorCode -eq 'INTERRUPTED' -and $e.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and $e.data.lifecycleBlock.requestedState -eq 'Activated') "code=$($e.error.code) block=$(J $e.data.lifecycleBlock)"
    Check '(2) message names the killed process' ([string]$e.data.lifecycleBlock.message -match 'PID \d+') ([string]$e.data.lifecycleBlock.message)
    Clear-Block $A

    # --- (3) success paths leave no marker ---
    $fake::Mode = 'run'   # Config from Run: the restart is observed
    $r = Set-TcSystemState -State Config -AmsNetId $A -TimeoutSec 2 -SettleSec 0
    $e = Enable-TcConfig -WarningAction SilentlyContinue
    Check '(3) Set-TcSystemState / Enable-TcConfig succeed and leave no marker' ($r.success -and $e.success -and (Get-Markers).Count -eq 0) "sys=$($r.error.code) en=$($e.error.code) markers=$((Get-Markers).Count)"
    Check '(3) no block after success' ($null -eq (& $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A)) ''

    # --- (4) live / reused pid / corrupt marker ---
    $live = Start-Process powershell.exe -PassThru -WindowStyle Hidden -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
    try {
        $start = $live.StartTime.ToUniversalTime().ToString('o')
        $m = [PSCustomObject]@{ pid = $live.Id; processStartUtc = $start; command = 'Set-TcSystemState'; amsNetId = $A; requestedState = 'Run'; startedAtUtc = [DateTime]::UtcNow.ToString('o') }
        $f = Join-Path $env:TCAUTO_STATE_DIR ("lifecycle-inflight.{0}.{1}.json" -f $live.Id, [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($f, (J $m))
        $b = & $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A
        Check '(4) marker of a live process (same start time) is not promoted' ($null -eq $b -and (Test-Path -LiteralPath $f)) (J $b)
        $m.processStartUtc = $live.StartTime.ToUniversalTime().AddHours(-1).ToString('o')
        [IO.File]::WriteAllText($f, (J $m))
        $b = & $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A
        Check '(4) reused pid (other start time) is promoted' ($null -ne $b -and $b.errorCode -eq 'INTERRUPTED' -and -not (Test-Path -LiteralPath $f)) (J $b)
        Clear-Block $A
    }
    finally { Stop-Process -Id $live.Id -Force -ErrorAction SilentlyContinue }
    $f = Join-Path $env:TCAUTO_STATE_DIR ("lifecycle-inflight.{0}.{1}.json" -f 999999, [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($f, 'not json {')
    $b = & $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $B
    Check '(4) corrupt marker -> <unknown> block (every target)' ($null -ne $b -and $b.errorCode -eq 'INTERRUPTED' -and $null -eq $b.amsNetId -and -not (Test-Path -LiteralPath $f)) (J $b)
    $null = Clear-TcLifecycleBlock -AmsNetId '<unknown>' -Reason 'unit test #236 next case' -FallbackMethod 'unit test' -AllowedSideEffects 'none' -MaxVerifyLevel None

    # --- (5) a newer record of the same target wins ---
    $old = [DateTime]::UtcNow.AddMinutes(-5).ToString('o')
    $null = & $mod { param($n) Set-TcLifecycleBlock -AmsNetId $n -Command 'Set-TcSystemState' -ErrorCode 'SYSTEM_STATE_TIMEOUT' -RequestedState 'Run' } $A
    $f = Join-Path $env:TCAUTO_STATE_DIR ("lifecycle-inflight.{0}.{1}.json" -f 999999, [guid]::NewGuid().ToString('N'))
    [IO.File]::WriteAllText($f, (J ([PSCustomObject]@{ pid = 999999; processStartUtc = $old; command = 'Set-TcSystemState'; amsNetId = $A; requestedState = 'Run'; startedAtUtc = $old })))
    $b = & $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A
    Check '(5) newer record kept, marker removed' ($b.errorCode -eq 'SYSTEM_STATE_TIMEOUT' -and -not (Test-Path -LiteralPath $f)) (J $b)
    Clear-Block $A

    # --- (6) exception escaping Enable-TcConfig after the request ---
    & $mod { function script:Set-TcSystemState { param([string]$State, [string]$AmsNetId, [int]$TimeoutSec) throw 'boom after set-config (mock)' } }
    $threw = $null
    try { $null = Enable-TcConfig -Force -WarningAction SilentlyContinue } catch { $threw = $_.Exception.Message }
    $b = & $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $A
    Check '(6) exception rethrown' ($threw -match 'boom after set-config') "$threw"
    Check '(6) block recorded (UNHANDLED_EXCEPTION, Enable-TcConfig), no marker left' ($null -ne $b -and $b.errorCode -eq 'UNHANDLED_EXCEPTION' -and $b.command -eq 'Enable-TcConfig' -and (Get-Markers).Count -eq 0) (J $b)
}
finally {
    Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
}
"failed: $fail"
exit $fail
