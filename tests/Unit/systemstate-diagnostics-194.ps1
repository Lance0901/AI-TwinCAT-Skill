# Unit: #194 Set-TcSystemState stuck in Config (SYSTEM_STATE_TIMEOUT / SYSTEM_STATE_MISMATCH) carries
# data.diagnostics (Get-TcRuntimeFailureDiagnostics, shared with Enable-TcConfig) and a hint decided
# from it: ADS 1809 dialog / Error List row -> symbol version explanation, never "license missing"
# when every license is valid; license problem without dialog -> the license hint as before.
# No IDE / ADS / runtime: TwinCAT.Ads.TcAdsClient is a fake type compiled here; the IDE helpers,
# license reader and Boot comparison are stubbed in module scope.
#   powershell.exe -NoProfile -File tests/Unit/systemstate-diagnostics-194.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    if ($Detail.Length -gt 500) { $Detail = $Detail.Substring(0, 500) }
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# Fake TwinCAT.Ads: 'config' always Config; 'fallback' Config before WriteControl, Run for RunSec
# after it, then Config (runtime falls back, #32 / #40).
Add-Type -TypeDefinition @'
namespace TwinCAT.Ads {
    public enum AdsState { Invalid = 0, Idle = 1, Reset = 2, Init = 3, Start = 4, Run = 5, Stop = 6, Config = 15, Reconfig = 16 }
    public class StateInfo { public AdsState AdsState; public short DeviceState; }
    public class TcAdsClient : System.IDisposable {
        public static string Mode = "config";
        public static bool Written = false;
        public static System.DateTime WrittenAt = System.DateTime.MinValue;
        public static double RunSec = 1.0;
        public void Connect(string netId, int port) { }
        public StateInfo ReadState() {
            StateInfo s = new StateInfo();
            s.AdsState = AdsState.Config;
            if (Mode == "fallback" && Written && (System.DateTime.Now - WrittenAt).TotalSeconds < RunSec) { s.AdsState = AdsState.Run; }
            return s;
        }
        public void WriteControl(StateInfo s) { Written = true; WrittenAt = System.DateTime.Now; }
        public void Dispose() { }
    }
}
'@
$fake = [TwinCAT.Ads.TcAdsClient]
function Set-Ads([string]$Mode) { $fake::Mode = $Mode; $fake::Written = $false }

$net = '5.6.7.8.1.1'
$validLic = [PSCustomObject]@{ licenses = @([PSCustomObject]@{ name = 'TC3 PLC'; valid = $true; expired = $false }); expired = @(); invalid = @(); text = $null }
$badText = "License server (ADS port 30) of $net reports expired: TC3 PLC (expired 2026-10-25T00:00:00Z) - a missing/expired license keeps the runtime in Config; renew it in XAE (System > License, 7 Days Trial License is an interactive dialog)."
$badLic = [PSCustomObject]@{ licenses = @([PSCustomObject]@{ name = 'TC3 PLC'; valid = $true; expired = $true }); expired = @('TC3 PLC (expired 2026-10-25T00:00:00Z)'); invalid = @(); text = $badText }
$fatal = "'TwinCAT System' (10000): Sending ams command >> Init43\IO: Set State TComObj SAFEOP: Check for autostart SafeOp >> AdsError: 1809 (0x711, ADS ERROR: symbol version invalid) << failed!"

$global:Lic = $validLic
$global:Dlg = $null
$global:ElRows = @()
$global:ElThrows = $false
$global:BootThrows = $false
$global:DlgCalls = 0
$global:ElCalls = 0
$global:BootArgs = $null
& $mod {
    function script:Find-TcAdsAssembly { $true }
    function script:Get-TcLocalUmRtProcess { param([string]$AmsNetId) $null }
    function script:Get-TcLicenseDiagnosis { param([string]$AmsNetId) $global:Lic }
    function script:Find-TcIdeModalDialog { $global:DlgCalls++; $global:Dlg }
    function script:Get-TcBuildErrors {
        param($TimeoutSec)
        $global:ElCalls++
        if ($global:ElThrows) { throw 'Error List mock failure' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @($global:ElRows | ForEach-Object { [PSCustomObject]@{ description = $_ } }) })
    }
    function script:Get-TcBootPackageDiff {
        param($SolutionPath, $Platform, $AmsNetId, $AdsPorts, $Variant)
        if ($global:BootThrows) { throw 'boot mock failure' }
        $global:BootArgs = [PSCustomObject]@{ SolutionPath = $SolutionPath; Platform = $Platform; AmsNetId = $AmsNetId; AdsPorts = @($AdsPorts); Variant = $Variant }
        if ([string]::IsNullOrWhiteSpace($Platform)) { return [PSCustomObject]@{ status = 'unavailable'; reason = 'solution platform unknown'; mismatches = @() } }
        [PSCustomObject]@{ status = 'mismatch'; reason = $null; mismatches = @('CurrentConfig.xml'); files = @() }
    }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Get-TcSysManager { param([switch]$Refresh) [PSCustomObject]@{ mock = $true } }
    function script:Get-TcPlcProjectList { param($SysManager) @([PSCustomObject]@{ name = 'P1'; adsPort = 851; disabled = $false }, [PSCustomObject]@{ name = 'P2'; adsPort = 852; disabled = $false }) }
    function script:Read-TcCurrentVariant { param($SysManager) @{ Value = ''; Error = $null; Supported = $false } }
}
function Set-Ide([bool]$On) {
    & $mod { param($o) if ($o) { $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{ mock = $true }; $script:TcSolutionPath = 'C:\Demo\Fallback.sln' } else { $script:TcIdeConnected = $false; $script:TcDte = $null } } $On
}
function Reset-Case { $global:DlgCalls = 0; $global:ElCalls = 0; $global:BootArgs = $null; $global:ElThrows = $false; $global:BootThrows = $false; $global:ElRows = @(); $global:Dlg = $null; $global:Lic = $validLic }
function Clear-Block { $null = Clear-TcLifecycleBlock -AmsNetId $net -Reason 'unit test: next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None }
$baseTimeout = & $mod { Get-TcErrorHint -Code 'SYSTEM_STATE_TIMEOUT' }
$baseMismatch = & $mod { Get-TcErrorHint -Code 'SYSTEM_STATE_MISMATCH' }
$noLicenseClaim = 'license 不足|常見原因是 license'

# --- A: SYSTEM_STATE_TIMEOUT, IDE fatal dialog with ADS 1809, every license valid
Reset-Case; Set-Ide $true; Set-Ads 'config'
$global:Dlg = @{ Title = 'TwinCAT XAE'; Text = "Target system reports a fatal error`r`n$fatal"; Kind = 'unknown' }
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
$d = $r.data.diagnostics
Check 'A 1809 dialog: code SYSTEM_STATE_TIMEOUT kept, success false, lifecycle block recorded' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $r.data.lifecycleBlock.errorCode -eq 'SYSTEM_STATE_TIMEOUT') "code=$($r.error.code)"
Check 'A data.diagnostics carries the dialog (title / text), dialogScanComplete true' ($null -ne $d -and $d.dialog.text -match '0x711' -and $d.dialog.title -eq 'TwinCAT XAE' -and $d.dialogScanComplete -eq $true) ($d | ConvertTo-Json -Compress -Depth 4)
Check 'A shape: dialog, dialogScanComplete, errorList, errorListError, bootPackage' ((@($d.PSObject.Properties.Name) -join ',') -eq 'dialog,dialogScanComplete,errorList,errorListError,bootPackage') (@($d.PSObject.Properties.Name) -join ',')
Check 'A Error List not read while a dialog is up; Boot compared with IDE platform / ports / solution' ($global:ElCalls -eq 0 -and $d.bootPackage.status -eq 'mismatch' -and $global:BootArgs.Platform -eq 'TwinCAT OS (x64)' -and (@($global:BootArgs.AdsPorts) -join ',') -eq '851,852' -and $global:BootArgs.SolutionPath -eq 'C:\Demo\Fallback.sln' -and $global:BootArgs.AmsNetId -eq $net) ($global:BootArgs | ConvertTo-Json -Compress)
Check 'A hint: ADS 1809 / symbol version explanation with the dialog text, Build + Enable-TcConfig -Force, troubleshooting section' ($r.error.hint -match 'ADS 1809' -and $r.error.hint -match 'ADS_SYMBOL_VERSION_INVALID' -and $r.error.hint -match 'Enable-TcConfig -Force' -and $r.error.hint -match 'Build-TcProject' -and $r.error.hint -match [regex]::Escape('AdsError: 1809') -and $r.error.hint -match 'CurrentConfig.xml') "$($r.error.hint)"
Check 'A hint does not blame a missing license, licenses kept in data.licenses' ($r.error.hint -notmatch $noLicenseClaim -and $r.error.hint -notmatch 'License 節點' -and $null -ne $r.data.licenses -and $null -eq $r.data.licenses.text) "$($r.error.hint)"
Clear-Block

# --- B: every license valid, no dialog, empty Error List -> no "license missing"
Reset-Case; Set-Ide $true; Set-Ads 'config'
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
Check 'B licenses valid, no dialog: code kept, Error List read, diagnostics present' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $global:DlgCalls -eq 1 -and $global:ElCalls -eq 1 -and $null -ne $r.data.diagnostics -and $null -eq $r.data.diagnostics.dialog -and @($r.data.diagnostics.errorList).Count -eq 0) ($r.data.diagnostics | ConvertTo-Json -Compress -Depth 4)
Check 'B hint: no "license missing", says licenses are valid, points at data.diagnostics' ($r.error.hint -notmatch $noLicenseClaim -and $r.error.hint -notmatch 'License 節點' -and $r.error.hint -match '授權都有效' -and $r.error.hint -match 'data.diagnostics' -and $r.error.hint -notmatch [regex]::Escape($baseTimeout)) "$($r.error.hint)"
Clear-Block

# --- C: license expired, no dialog -> license hint as before (license text + generic hint)
Reset-Case; Set-Ide $true; Set-Ads 'config'; $global:Lic = $badLic
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
Check 'C license expired, no dialog: hint = license text + unchanged SYSTEM_STATE_TIMEOUT hint' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $r.error.hint.EndsWith("$badText $baseTimeout") -and $null -ne $r.data.diagnostics -and $r.data.licenses.text -eq $badText) "$($r.error.hint)"
Clear-Block

# --- D: no IDE connection (ADS only) -> dialog / Error List unavailable, code kept
Reset-Case; Set-Ide $false; Set-Ads 'config'
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
$d = $r.data.diagnostics
Check 'D no IDE: SYSTEM_STATE_TIMEOUT kept, success false' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT') "code=$($r.error.code) msg=$($r.error.message)"
Check 'D no IDE: dialog not scanned (dialogScanComplete false, modalScan.reason no-ide), Error List unavailable' ($null -ne $d -and $d.dialogScanComplete -eq $false -and $d.modalScan.reason -eq 'no-ide' -and $d.errorListError -eq 'unavailable: no IDE connection' -and $null -eq $d.dialog -and $global:DlgCalls -eq 0 -and $global:ElCalls -eq 0) ($d | ConvertTo-Json -Compress -Depth 4)
Check 'D no IDE: Boot comparison has no solution / platform -> unavailable' ($d.bootPackage.status -eq 'unavailable' -and [string]::IsNullOrEmpty($global:BootArgs.SolutionPath)) ($d.bootPackage | ConvertTo-Json -Compress)
Check 'D no IDE, licenses valid: hint does not blame a license' ($r.error.hint -notmatch $noLicenseClaim -and $r.error.hint -notmatch 'License 節點') "$($r.error.hint)"
Clear-Block

# --- E: SYSTEM_STATE_MISMATCH (Run, then back to Config), 1809 only in an Error List row
Reset-Case; Set-Ide $true; Set-Ads 'fallback'; $fake::RunSec = 1.0
$global:ElRows = @('Some other error', 'The loaded symbol description does not match the plc application (0x711)')
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 20 -SettleSec 2
Check 'E fallback to Config -> SYSTEM_STATE_MISMATCH with diagnostics.errorList' ($r.error.code -eq 'SYSTEM_STATE_MISMATCH' -and @($r.data.diagnostics.errorList).Count -eq 2 -and $null -eq $r.data.diagnostics.dialog) "code=$($r.error.code) $($r.data.diagnostics | ConvertTo-Json -Compress -Depth 4)"
Check 'E hint: 1809 explanation from the Error List row, no license claim' ($r.error.hint -match 'XAE Error List 回報 ADS 1809' -and $r.error.hint -match 'symbol description does not match' -and $r.error.hint -notmatch $noLicenseClaim) "$($r.error.hint)"
Clear-Block

# --- F: other fatal dialog (no 1809), licenses valid -> the dialog text, cut to 300 chars
Reset-Case; Set-Ide $true; Set-Ads 'fallback'; $fake::RunSec = 1.0
$global:Dlg = @{ Title = 'TwinCAT XAE'; Text = ('Target system reports a fatal error: Init4\IO: ' + ('x' * 600)); Kind = 'unknown' }
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 20 -SettleSec 2
Check 'F other dialog: SYSTEM_STATE_MISMATCH, hint quotes the dialog (cut), says licenses valid, no 1809, no license claim' ($r.error.code -eq 'SYSTEM_STATE_MISMATCH' -and $r.error.hint -match 'Target system reports a fatal error' -and $r.error.hint -match ([regex]::Escape(('x' * 50) + '...')) -and $r.error.hint -notmatch ('x' * 400) -and $r.error.hint -notmatch '1809' -and $r.error.hint -match '授權都有效' -and $r.error.hint -notmatch $noLicenseClaim) "$($r.error.hint)"
Clear-Block

# --- G: MISMATCH, every license valid, no dialog -> mismatch hint without the license cause
Reset-Case; Set-Ide $true; Set-Ads 'fallback'; $fake::RunSec = 1.0
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 20 -SettleSec 2
Check 'G mismatch, licenses valid, nothing found: hint names no license cause' ($r.error.code -eq 'SYSTEM_STATE_MISMATCH' -and $r.error.hint -notmatch $noLicenseClaim -and $r.error.hint -notmatch 'license 不足' -and $r.error.hint -notmatch [regex]::Escape($baseMismatch) -and $r.error.hint -match 'data.diagnostics') "$($r.error.hint)"
Clear-Block

# --- H: diagnostics collection fails -> still failure with the original code
Reset-Case; Set-Ide $true; Set-Ads 'config'; $global:ElThrows = $true; $global:BootThrows = $true
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
Check 'H Error List / Boot comparison throw: SYSTEM_STATE_TIMEOUT kept, errorListError set, bootPackage null' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $r.data.diagnostics.errorListError -match 'Error List mock failure' -and $null -eq $r.data.diagnostics.bootPackage) ($r.data.diagnostics | ConvertTo-Json -Compress -Depth 4)
Clear-Block
Reset-Case; Set-Ide $true; Set-Ads 'config'
$origHelper = & $mod { ${function:Get-TcRuntimeFailureDiagnostics} }
& $mod { function script:Get-TcRuntimeFailureDiagnostics { throw 'helper mock failure' } }
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
Check 'H helper throws: SYSTEM_STATE_TIMEOUT kept, diagnostics say it failed' ((-not $r.success) -and $r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $r.data.diagnostics.errorListError -match 'diagnostics failed: helper mock failure' -and $r.data.diagnostics.dialogScanComplete -eq $false) ($r.data.diagnostics | ConvertTo-Json -Compress -Depth 4)
Clear-Block
& $mod { param($b) Set-Item -Path 'Function:\script:Get-TcRuntimeFailureDiagnostics' -Value $b } $origHelper

# --- I: nested in Enable-TcConfig (skip flag) -> nothing collected, hint as before #194
Reset-Case; Set-Ads 'config'
$r = & $mod { param($n) $script:TcSystemStateSkipDiagnostics = $true; try { Set-TcSystemState -State Run -AmsNetId $n -TimeoutSec 2 -SettleSec 0 } finally { $script:TcSystemStateSkipDiagnostics = $false } } $net
Check 'I skip flag: no data.diagnostics, no dialog scan, licenses kept, hint = unchanged generic hint' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $null -eq $r.data.PSObject.Properties['diagnostics'] -and $global:DlgCalls -eq 0 -and $null -ne $r.data.licenses -and $r.error.hint.EndsWith($baseTimeout)) "$($r.error.hint)"
Clear-Block

# --- J: Enable-TcConfig passes the skip flag to its set-run and still builds data.diagnostics itself
$src = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public\Enable-TcConfig.ps1') -Raw
Check 'J Enable-TcConfig: set-run wrapped in the skip flag, New-TcRuntimeFailure uses the shared helper' ($src -match '(?s)\$script:TcSystemStateSkipDiagnostics = \$true\s*try \{ \$r = Set-TcSystemState -State Run' -and $src -match 'Get-TcRuntimeFailureDiagnostics -DialogScan \$DialogScan -Deadline \$deadline') ''
Check 'J the skip flag is off after import' ((& $mod { $script:TcSystemStateSkipDiagnostics }) -eq $false) ''

"failed: $fail"
exit [Math]::Min($fail, 255)
