# Unit: #231 dialogs seen by the Activate watchdog are reported by Enable-TcConfig (data.dialogsSeen),
# no IDE / ADS / runtime needed. The real Invoke-TcActivateWithDeadline runs with -ActivateScript (the
# background call only sleeps); Find-TcIdeModalDialog is a mock that reports a dialog only while that
# call runs. Mock basis: the dialog record shape of Find-TcIdeModalDialog (Title / Text / Buttons with
# Name, Private/Find-TcIdeModalDialog.ps1 header) and the issue #231 report (VMware vmx86.sys
# real-time start diagnostic, Continue / Cancel, measured 2026-11-11 by the reporter).
# Covers:
#   (1) one dialog seen during Activate -> success, data.dialogsSeen has 1 entry with title / text /
#       buttons / firstSeen / lastSeen / durationSec; the activate step detail has a summary
#   (2) the same dialog scanned several times -> still 1 entry (lastSeen / durationSec updated)
#   (3) no dialog -> data.dialogsSeen is an empty array ('[]' in JSON, not null)
#   (4) steps after Activate that call Invoke-TcComRetry do not clear the record
#   (5) ACTIVATE_TIMEOUT: error code, message and lifecycle block unchanged
#   powershell.exe -NoProfile -File tests/Unit/activate-dialog-log-231.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 600) { $Detail = $Detail.Substring(0, 600) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function J($o) { $o | ConvertTo-Json -Compress -Depth 6 }

$A = '10.1.2.3.1.1'
Add-Type -TypeDefinition @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Config = 15, Reconfig = 16 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
}
'@

# $global:Ut231.Dialog: dialog reported by the scan while Activate runs ($null = none)
# $global:Ut231.ActivateScript: background call of the real Invoke-TcActivateWithDeadline
$global:Ut231 = @{ InActivate = $false; Dialog = $null; ActivateScript = 'Start-Sleep -Milliseconds 4500; ''done'''; ActivateTimeoutSec = 30; Scans = 0; ComRetryAfter = 0 }
& $mod { param($p) $script:TcIdeProcessId = $p } $PID
& $mod {
    $script:Ut231RealActivate = ${function:Invoke-TcActivateWithDeadline}
    function script:Invoke-TcActivateWithDeadline {
        param($TimeoutSec, $AmsNetId)
        $global:Ut231.InActivate = $true
        try { & $script:Ut231RealActivate -TimeoutSec $global:Ut231.ActivateTimeoutSec -AmsNetId $AmsNetId -ActivateScript $global:Ut231.ActivateScript }
        finally { $global:Ut231.InActivate = $false }
    }
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        if (-not $global:Ut231.InActivate -or $null -eq $global:Ut231.Dialog) { return $null }
        $global:Ut231.Scans++
        $d = $global:Ut231.Dialog
        [PSCustomObject]@{ Title = $d.Title; Text = $d.Text; ClassName = '#32770'; IsModal = $true; Hwnd = [long]4242; Buttons = @(@{ Id = 0; Name = 'Continue'; AutomationId = '' }, @{ Id = 0; Name = 'Cancel'; AutomationId = '' }) }
    }
    function script:Assert-TcConnection { }
    function script:Get-TcIdeMemoryInfo { $null }
    function script:Get-TcLicenseDiagnosis { param($AmsNetId) $null }
    function script:Get-TcLocalUmRtProcess { param($AmsNetId) $null }
    function script:Resolve-TcTargetBootDir { param([string]$AmsNetId) $null }
    function script:Get-TcSysManager {
        [CmdletBinding()] param([switch]$Refresh)
        $o = [PSCustomObject]@{ Mock = $true }
        $o | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { '10.1.2.3.1.1' }
        $o | Add-Member -MemberType ScriptMethod -Name LookupTreeItem -Value { param($p) [PSCustomObject]@{} }
        $o
    }
    function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Read-TcCurrentVariant { param($SysManager) @{ Value = ''; Error = $null } }
    function script:Get-TcPlcProjectList { param($SysManager) @([PSCustomObject]@{ name = 'P'; nodePath = 'TIPC^P'; projectPath = 'TIPC^P^P Project'; adsPort = 851; disabled = $false }) }
    function script:Get-TcBootPackageDiff { param($SolutionPath, $Platform, $AmsNetId, $AdsPorts, $Variant) $null }
    function script:Get-TcBuildErrors { param($TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @() }) }
    function script:Ensure-TcAdsConnection { $false }
    function script:Connect-TcAdsSession { param($AmsNetId, $Port) 'Run' }
    function script:Wait-TcAdsState {
        param([string]$AmsNetId, [int]$Port, [string]$TargetState, [int]$TimeoutSec, [switch]$DetectRuntimeCrash)
        [PSCustomObject]@{ Reached = $true; State = $(if ($TargetState -eq 'Any') { 'Run' } else { $TargetState }); LastError = $null; ElapsedMs = 5; RuntimeCrashed = $false }
    }
    # (4) the steps after Activate go through Invoke-TcComRetry (it resets $script:TcLastModalDialog)
    function script:Set-TcSystemState {
        param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
        if ($State -eq 'Run') { $null = Invoke-TcComRetry -OperationName 'mock set-run' -ScriptBlock { 'x' }; $global:Ut231.ComRetryAfter++ }
        New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State })
    }
    function script:Enter-TcPlcOnline { param($LoginMode, $PlcProjectPath, $TimeoutSec) $null = Invoke-TcComRetry -OperationName 'mock login' -ScriptBlock { 'x' }; $global:Ut231.ComRetryAfter++; New-TcResult -Success $true -Data ([PSCustomObject]@{ message = 'mock login' }) }
    function script:New-TcAdsClient {
        param($AmsNetId, $Port)
        $o = [PSCustomObject]@{ P = $Port }
        $o | Add-Member -MemberType ScriptMethod -Name ReadState -Value { $s = New-Object TwinCAT.Ads.StateInfo; $s.AdsState = [TwinCAT.Ads.AdsState]::Run; $s }
        $o | Add-Member -MemberType ScriptMethod -Name WriteControl -Value { param($s) }
        $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value { }
        $o
    }
    $script:TcDte = [PSCustomObject]@{ Solution = [PSCustomObject]@{ SolutionBuild = [PSCustomObject]@{ LastBuildInfo = 0 } } }
    $script:TcSolutionPath = 'C:\Demo\Dialog231.sln'
    $script:TcSilentMode = $true
}
function Get-Step($r, [string]$Name) { @($r.data.steps | Where-Object { $_.step -eq $Name }) | Select-Object -Last 1 }
$vmx = @{ Title = 'TwinCAT System - real-time start diagnostic (mock)'; Text = 'Setting TwinCAT in Run Mode with vmx86.sys running might fail (mock)' }
$iso = '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}'

# --- (1) + (2) + (4) -Force: one dialog, scanned at ~2 s and ~4 s ---
$global:Ut231.Dialog = $vmx; $global:Ut231.Scans = 0; $global:Ut231.ComRetryAfter = 0
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
$ds = @($r.data.dialogsSeen)
Check '(1) -Force success' ($r.success) "code=$($r.error.code) msg=$($r.error.message)"
Check '(2) scanned at least twice during Activate' ($global:Ut231.Scans -ge 2) "scans=$($global:Ut231.Scans)"
Check '(1)(2) data.dialogsSeen has exactly 1 entry' ($null -ne $r.data.PSObject.Properties['dialogsSeen'] -and $ds.Count -eq 1) (J $r.data.dialogsSeen)
$d = if ($ds.Count -gt 0) { $ds[0] } else { $null }
Check '(1) entry: title / text / buttons' ($null -ne $d -and $d.title -eq $vmx.Title -and $d.text -eq $vmx.Text -and (@($d.buttons) -join ',') -eq 'Continue,Cancel') (J $d)
Check '(1) entry: firstSeen / lastSeen ISO 8601, durationSec >= 1' ($null -ne $d -and [string]$d.firstSeen -match $iso -and [string]$d.lastSeen -match $iso -and $d.durationSec -ge 1 -and [DateTime]::Parse($d.lastSeen) -gt [DateTime]::Parse($d.firstSeen)) (J $d)
$st = Get-Step $r 'activate'
Check '(1) activate step detail has the summary' ($null -ne $st -and [string]$st.detail -match 'dialogs seen during Activate: 1 ' -and [string]$st.detail -match [regex]::Escape("'$($vmx.Title)'")) "detail=$($st.detail)"
Check '(4) steps after Activate called Invoke-TcComRetry and the record stayed' ($global:Ut231.ComRetryAfter -ge 1 -and $ds.Count -eq 1) "comRetryAfter=$($global:Ut231.ComRetryAfter)"
$json = $r | ConvertTo-Json -Depth 8 -Compress
Check '(1) JSON: dialogsSeen is an array even with one entry' ($json -match '"dialogsSeen":\[\{') ($json.Substring([Math]::Max(0, $json.IndexOf('"dialogsSeen"')), 80))

# --- (1) without -Force ---
$global:Ut231.Scans = 0
$r = Enable-TcConfig -WarningAction SilentlyContinue
$ds = @($r.data.dialogsSeen)
Check '(1) no -Force: success, 1 entry, summary in the activate step' ($r.success -and $ds.Count -eq 1 -and [string](Get-Step $r 'activate').detail -match 'dialogs seen during Activate: 1 ') "code=$($r.error.code) seen=$(J $r.data.dialogsSeen)"

# --- (2) two different dialogs one after the other -> 2 entries ---
$global:Ut231.Dialog = $null
& $mod {
    $script:Ut231Find = ${function:Find-TcIdeModalDialog}
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        if (-not $global:Ut231.InActivate) { return $null }
        $global:Ut231.Scans++
        [PSCustomObject]@{ Title = "Mock dialog $($global:Ut231.Scans)"; Text = 'different text'; ClassName = '#32770'; IsModal = $true; Hwnd = [long]4242; Buttons = @() }
    }
}
$global:Ut231.Scans = 0
$r = Enable-TcConfig -WarningAction SilentlyContinue
$ds = @($r.data.dialogsSeen)
Check '(2) different dialogs -> one entry each' ($r.success -and $ds.Count -eq $global:Ut231.Scans -and $ds.Count -ge 2 -and $ds[0].title -ne $ds[1].title) "scans=$($global:Ut231.Scans) seen=$(J $r.data.dialogsSeen)"
Check '(2) summary counts both' ([string](Get-Step $r 'activate').detail -match "dialogs seen during Activate: $($ds.Count) ") "detail=$((Get-Step $r 'activate').detail)"
& $mod { Set-Item -Path function:script:Find-TcIdeModalDialog -Value $script:Ut231Find }

# --- (3) no dialog -> empty array ---
$global:Ut231.Dialog = $null
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
$json = $r | ConvertTo-Json -Depth 8 -Compress
Check '(3) no dialog: success, dialogsSeen present and empty' ($r.success -and $null -ne $r.data.PSObject.Properties['dialogsSeen'] -and $null -ne $r.data.dialogsSeen -and @($r.data.dialogsSeen).Count -eq 0) (J $r.data.dialogsSeen)
Check '(3) JSON: "dialogsSeen":[]' ($json -match '"dialogsSeen":\[\]') ($json.Substring([Math]::Max(0, $json.IndexOf('"dialogsSeen"')), 30))
Check '(3) activate detail unchanged without dialogs' ([string](Get-Step $r 'activate').detail -eq 'ActivateConfiguration() done') "detail=$((Get-Step $r 'activate').detail)"

# --- (5) ACTIVATE_TIMEOUT: code / message / block as before ---
$global:Ut231.Dialog = $vmx; $global:Ut231.ActivateScript = 'Start-Sleep -Seconds 60'; $global:Ut231.ActivateTimeoutSec = 3
& $mod { $script:TcActivateDiagBudgetSec = 3 }
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check '(5) ACTIVATE_TIMEOUT code' ((-not $r.success) -and $r.error.code -eq 'ACTIVATE_TIMEOUT') "code=$($r.error.code)"
Check '(5) message unchanged' ([string]$r.error.message -match '^Activation failed: ACTIVATE_TIMEOUT: ActivateConfiguration\(\) did not return within 3 s; the call was abandoned \(it keeps running inside the IDE\)\. ' -and [string]$r.error.message -match [regex]::Escape("modal dialog '$($vmx.Title)'")) "$($r.error.message)"
Check '(5) lifecycle block (activate step) and activateDiagnostics as before' ($r.data.lifecycleBlock.command -eq 'Enable-TcConfig' -and $r.data.lifecycleBlock.errorCode -eq 'ACTIVATE_TIMEOUT' -and $r.data.lifecycleBlock.step -eq 'activate' -and [string]$r.data.activateDiagnostics.dialog.title -eq $vmx.Title -and $r.data.activated -eq $false -and $r.data.activateSent) (J $r.data.lifecycleBlock)
Check '(5) failure result also carries dialogsSeen (additive)' (@($r.data.dialogsSeen).Count -eq 1 -and @($r.data.dialogsSeen)[0].title -eq $vmx.Title) (J $r.data.dialogsSeen)
$null = Clear-TcLifecycleBlock -AmsNetId $A -Reason 'unit test 231 done' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None

"failed: $fail"
exit [Math]::Min($fail, 255)
