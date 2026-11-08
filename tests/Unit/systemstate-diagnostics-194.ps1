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
$global:BootStatus = 'mismatch'
$global:DteCalls = 0
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
        [PSCustomObject]@{ status = $global:BootStatus; reason = $null; mismatches = $(if ($global:BootStatus -eq 'mismatch') { @('CurrentConfig.xml') } else { @() }); files = @(); warnings = @() }
    }
    # DTE readers: counted (PR #200 review: never called while a dialog is up / the scan is incomplete)
    function script:Get-TcSolutionPlatform { $global:DteCalls++; [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Get-TcSysManager { param([switch]$Refresh) $global:DteCalls++; [PSCustomObject]@{ mock = $true } }
    function script:Get-TcPlcProjectList { param($SysManager) $global:DteCalls++; @([PSCustomObject]@{ name = 'P1'; adsPort = 851; disabled = $false }, [PSCustomObject]@{ name = 'P2'; adsPort = 852; disabled = $false }) }
    function script:Read-TcCurrentVariant { param($SysManager) $global:DteCalls++; @{ Value = ''; Error = $null; Supported = $false } }
}
# connected IDE + the platform cache an earlier Connect-TcIde / Set-TcTarget left (Get-TcSolutionPlatform)
function Set-Ide([bool]$On) {
    & $mod { param($o) if ($o) { $script:TcIdeConnected = $true; $script:TcDte = [PSCustomObject]@{ mock = $true }; $script:TcSolutionPath = 'C:\Demo\Fallback.sln'; $script:TcLastSolutionPlatform = [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; solutionPath = 'C:\Demo\Fallback.sln'; readAt = (Get-Date) } } else { $script:TcIdeConnected = $false; $script:TcDte = $null } } $On
}
function Reset-Case { $global:DlgCalls = 0; $global:ElCalls = 0; $global:DteCalls = 0; $global:BootArgs = $null; $global:BootStatus = 'mismatch'; $global:ElThrows = $false; $global:BootThrows = $false; $global:ElRows = @(); $global:Dlg = $null; $global:Lic = $validLic }
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
Check 'A Error List not read while a dialog is up, errorListError says so (#198: never [] + null)' ($global:ElCalls -eq 0 -and @($d.errorList).Count -eq 0 -and $d.errorListError -match '^unavailable: not read while a modal dialog is up') "$($d.errorListError)"
Check 'A dialog up: no DTE call (platform / PLC list / variant), Boot compared with the cached platform, warning says so' ($global:DteCalls -eq 0 -and $d.bootPackage.status -eq 'mismatch' -and $global:BootArgs.Platform -eq 'TwinCAT OS (x64)' -and @($global:BootArgs.AdsPorts).Count -eq 0 -and $global:BootArgs.SolutionPath -eq 'C:\Demo\Fallback.sln' -and $global:BootArgs.AmsNetId -eq $net -and (@($d.bootPackage.warnings) -join ' ') -match 'IDE not read \(a modal dialog is up\)') "dte=$($global:DteCalls) $($global:BootArgs | ConvertTo-Json -Compress) $(@($d.bootPackage.warnings) -join ' ')"
Check 'A hint: ADS 1809 / symbol version explanation with the dialog text, Build + Enable-TcConfig -Force, troubleshooting section' ($r.error.hint -match 'ADS 1809' -and $r.error.hint -match 'ADS_SYMBOL_VERSION_INVALID' -and $r.error.hint -match 'Enable-TcConfig -Force' -and $r.error.hint -match 'Build-TcProject' -and $r.error.hint -match [regex]::Escape('AdsError: 1809') -and $r.error.hint -match 'CurrentConfig.xml') "$($r.error.hint)"
Check 'A hint does not blame a missing license, licenses kept in data.licenses' ($r.error.hint -notmatch $noLicenseClaim -and $r.error.hint -notmatch 'License 節點' -and $null -ne $r.data.licenses -and $null -eq $r.data.licenses.text) "$($r.error.hint)"
Clear-Block

# --- B: every license valid, no dialog, empty Error List -> no "license missing"
Reset-Case; Set-Ide $true; Set-Ads 'config'
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
Check 'B licenses valid, no dialog: code kept, Error List read, diagnostics present' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $global:DlgCalls -eq 1 -and $global:ElCalls -eq 1 -and $null -ne $r.data.diagnostics -and $null -eq $r.data.diagnostics.dialog -and @($r.data.diagnostics.errorList).Count -eq 0) ($r.data.diagnostics | ConvertTo-Json -Compress -Depth 4)
Check 'B no dialog: DTE read after the scan (platform / ports from the IDE)' ($global:DteCalls -gt 0 -and (@($global:BootArgs.AdsPorts) -join ',') -eq '851,852') "dte=$($global:DteCalls)"
Check 'B hint: "已讀到的 1 個授權都有效", unlisted TF licenses not judged' ($r.error.hint -match '已讀到的 1 個授權都有效' -and $r.error.hint -match '沒列出的 TF 授權不在這次判斷範圍內') "$($r.error.hint)"
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
Check 'J Enable-TcConfig: set-run wrapped in the skip flag, New-TcRuntimeFailure uses the shared helper' ($src -match '(?s)\$script:TcSystemStateSkipDiagnostics = \$true\s*try \{ \$r = Set-TcSystemState -State Run' -and $src -match 'Get-TcRuntimeFailureDiagnostics -DialogScan \$scan -Deadline \$deadline') ''
# PR #200 review: New-TcRuntimeFailure scans first; the DTE platform read only when the scan found no dialog
$nrf = [regex]::Match($src, '(?s)function New-TcRuntimeFailure \{.*?Get-TcRuntimeFailureDiagnostics -DialogScan').Value
Check 'J New-TcRuntimeFailure: scan before the DTE platform read, DTE only when clear, cached platform otherwise' ($nrf.IndexOf('Get-TcDiagnosticsDialogScan') -ge 0 -and $nrf.IndexOf('Get-TcDiagnosticsDialogScan') -lt $nrf.IndexOf('Get-TcSolutionPlatform') -and $nrf -match 'if \(Test-TcDiagnosticsDialogClear \$scan\) \{ try \{ \$cur = Get-TcSolutionPlatform' -and $nrf -match 'Get-TcCachedSolutionPlatform') ''
Check 'J Enable-TcConfig uses the shared 1809 pattern' ($src -match '\$_ -match \$script:TcSymbolVersionPattern' -and $src -notmatch "symbol description does not match\|1809") ''
Check 'J the skip flag is off after import' ((& $mod { $script:TcSystemStateSkipDiagnostics }) -eq $false) ''

# --- K: dialog scan incomplete -> no DTE call either; Error List still read (bounded), scan reported
Reset-Case; Set-Ide $true; Set-Ads 'config'
$global:Dlg = & $mod { New-TcModalScanIncomplete -Reason 'timeout' -Message 'mock: scan timed out' }
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
$d = $r.data.diagnostics
Check 'K scan incomplete: no DTE call, dialogScanComplete false, modalScan reported, warning names the incomplete scan' ($global:DteCalls -eq 0 -and $d.dialogScanComplete -eq $false -and $null -ne $d.modalScan -and (@($d.bootPackage.warnings) -join ' ') -match 'scan did not complete') "dte=$($global:DteCalls) $($d | ConvertTo-Json -Compress -Depth 4)"
Check 'K scan incomplete: Error List not read (no View.ErrorList / DTE), errorListError unavailable: modal scan incomplete' ($global:ElCalls -eq 0 -and @($d.errorList).Count -eq 0 -and $d.errorListError -eq 'unavailable: modal scan incomplete') "el=$($global:ElCalls) $($d.errorListError)"
Clear-Block
# same rule on the Enable-TcConfig path (New-TcRuntimeFailure passes its scan as -DialogScan)
Reset-Case; Set-Ide $true
$inc = & $mod { New-TcModalScanIncomplete -Reason 'timeout' -Message 'mock: scan timed out' }
$d = & $mod { param($s, $n) Get-TcRuntimeFailureDiagnostics -DialogScan $s -Deadline ((Get-Date).AddSeconds(60)) -SolutionPath 'C:\Demo\Fallback.sln' -Platform 'TwinCAT OS (x64)' -AmsNetId $n } $inc $net
Check 'K helper with an incomplete -DialogScan (Enable-TcConfig path): no Error List call, no scan, errorListError unavailable: modal scan incomplete' ($global:ElCalls -eq 0 -and $global:DlgCalls -eq 0 -and $d.dialogScanComplete -eq $false -and $d.errorListError -eq 'unavailable: modal scan incomplete') "el=$($global:ElCalls) dlg=$($global:DlgCalls) $($d.errorListError)"

# --- L: fail closed first (#68): the lifecycle block exists before the collection starts; slow
# scan / Error List stay within request start + -TimeoutSec + $script:TcSystemStateDiagCapSec
Reset-Case; Set-Ide $true; Set-Ads 'config'
$global:BlockAtScan = $null; $global:BlockAtLicense = $null; $global:ElBudget = $null
& $mod {
    $script:TcSystemStateDiagCapSec = 4
    function script:Test-UnitBlockWritten { param([string]$NetId) $f = Get-TcLifecycleBlockFile; (Test-Path -LiteralPath $f) -and ([IO.File]::ReadAllText($f) -match [regex]::Escape($NetId)) }
    function script:Get-TcLicenseDiagnosis { param([string]$AmsNetId) $global:BlockAtLicense = Test-UnitBlockWritten $AmsNetId; $global:Lic }
    # every scan blocks for its whole prepare + scan cap, then "no dialog"
    function script:Find-TcIdeModalDialog {
        param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        $global:DlgCalls++
        $global:BlockAtScan = Test-UnitBlockWritten '5.6.7.8.1.1'
        $p = if ($PrepareTimeoutSec -gt 0) { $PrepareTimeoutSec } else { 60 }
        Start-Sleep -Seconds ($p + $TimeoutSec)
        $null
    }
    function script:Get-TcBuildErrors { param($TimeoutSec) $global:ElCalls++; $global:ElBudget = $TimeoutSec; Start-Sleep -Seconds $TimeoutSec; New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @() }) }
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Set-TcSystemState -State Run -AmsNetId $net -TimeoutSec 2 -SettleSec 0
$sec = $sw.Elapsed.TotalSeconds
Check 'L block written before the license read and the dialog scan' ($global:BlockAtLicense -eq $true -and $global:BlockAtScan -eq $true -and $r.data.lifecycleBlock.errorCode -eq 'SYSTEM_STATE_TIMEOUT') "license=$($global:BlockAtLicense) scan=$($global:BlockAtScan)"
# bound: -TimeoutSec 2 + cap 4 = 6 s after the request; +1.5 s runspace / CI slack
Check 'L collection ends by the deadline (TimeoutSec + cap), Error List skipped when < 5 s are left' ($sec -lt 7.5 -and $global:ElCalls -eq 0 -and $r.data.diagnostics.errorListError -eq 'skipped: -TimeoutSec budget exhausted') ("{0:N1} s, el={1} {2}" -f $sec, $global:ElCalls, $r.data.diagnostics.errorListError)
Check 'L hint keeps the stop text in front, #194 hint after it' ($r.error.hint -match '授權都有效' -and $r.error.hint -notmatch [regex]::Escape($baseTimeout) -and $r.error.hint.IndexOf('授權都有效') -gt 0) "$($r.error.hint)"
Clear-Block
& $mod {
    $script:TcSystemStateDiagCapSec = 10
    function script:Get-TcLicenseDiagnosis { param([string]$AmsNetId) $global:Lic }
    function script:Find-TcIdeModalDialog { $global:DlgCalls++; $global:Dlg }
    function script:Get-TcBuildErrors {
        param($TimeoutSec)
        $global:ElCalls++
        if ($global:ElThrows) { throw 'Error List mock failure' }
        New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @($global:ElRows | ForEach-Object { [PSCustomObject]@{ description = $_ } }) })
    }
}

# --- M: hint rules (PR #200 review items 3-5, 9), Get-TcStuckInConfigHint directly
$dlg1809 = [PSCustomObject]@{ title = 'TwinCAT XAE'; text = $fatal }
function Hint($Code, $Boot, $Lic, $Rows = @(), $Dialog = $dlg1809) { & $mod { param($c, $b, $l, $rw, $dg) Get-TcStuckInConfigHint -Code $c -License $l -Diagnostics ([PSCustomObject]@{ dialog = $dg; errorList = @($rw); bootPackage = $b }) } $Code $Boot $Lic $Rows $Dialog }
$h = Hint 'SYSTEM_STATE_TIMEOUT' ([PSCustomObject]@{ status = 'match'; mismatches = @() }) $validLic
Check 'M 1809 + bootPackage match: says Boot is consistent, no stale-CurrentConfig claim' ($h -match '比對一致' -and $h -match '不是 target 上 CurrentConfig 舊版造成' -and $h -notmatch '可能是') "$h"
$h = Hint 'SYSTEM_STATE_TIMEOUT' ([PSCustomObject]@{ status = 'unavailable'; reason = 'solution platform unknown'; mismatches = @() }) $validLic
Check 'M 1809 + bootPackage unavailable: only "可能是", reason named' ($h -match '可能是 target Boot' -and $h -match 'solution platform unknown' -and $h -notmatch '比出不一致') "$h"
$h = Hint 'SYSTEM_STATE_TIMEOUT' ([PSCustomObject]@{ status = 'mismatch'; mismatches = @('CurrentConfig.xml') }) $validLic
Check 'M 1809 + bootPackage mismatch: stated, files listed' ($h -match '比出不一致的檔案 CurrentConfig.xml' -and $h -notmatch '可能是') "$h"
$noLic = [PSCustomObject]@{ licenses = @(); expired = @(); invalid = @(); text = $null }
$h = Hint 'SYSTEM_STATE_TIMEOUT' $null $noLic @() $null
Check 'M no license read at all: never "授權都有效", generic hint' ($h -notmatch '授權都有效' -and $h -eq $baseTimeout) "$h"
$h = Hint 'SYSTEM_STATE_MISMATCH' $null $validLic @() $null
Check 'M mismatch, nothing found: no "通常是", measured example dated' ($h -notmatch '通常是' -and $h -match '2026-11-08' -and $h -match '已讀到的 1 個授權都有效') "$h"
$h = Hint 'SYSTEM_STATE_TIMEOUT' $null $validLic @('C0032: line 1809 of MAIN: type mismatch') $null
Check 'M a bare 1809 (line number) is not ADS 1809' ($h -notmatch 'ADS 1809' -and $h -match 'XAE Error List') "$h"
$h = Hint 'SYSTEM_STATE_TIMEOUT' $null $validLic @('Init4: AdsError: 1809 failed') $null
Check 'M "AdsError: 1809" in an Error List row is ADS 1809' ($h -match 'XAE Error List 回報 ADS 1809') "$h"

"failed: $fail"
exit [Math]::Min($fail, 255)
