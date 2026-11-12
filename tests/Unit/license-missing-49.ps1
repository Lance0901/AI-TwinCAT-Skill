# Unit: #49 LICENSE_MISSING. The runtime's license failure ('TwinCAT System' (10000) + a license word,
# any language) in a modal dialog / Error List row replaces the generic code (IDE_MODAL_DIALOG,
# SYSTEM_STATE_TIMEOUT ...) of Enable-TcConfig / Set-TcSystemState / ConvertTo-TcAdsErrorCode; the
# lifecycle block of a sent request stays (#68 / #236); nothing presses the dialog.
# The license-failure path is only tested here (mocks): the real license on the test machine is never
# invalidated (#49 brief). Texts: en measured 2026-11-11 (VS2022 4026 + UmRT); the zh-TW / de wording
# around the runtime text is made up for the language-independence check.
# No IDE / ADS / runtime: Set-TcSystemState, the activation and the IDE helpers are stubbed in module
# scope; Set-TcSystemState itself is covered in tests/Unit/systemstate-diagnostics-194.ps1 (case N).
#   powershell.exe -NoProfile -File tests/Unit/license-missing-49.ps1
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

$licEn = "Target system reports a fatal error: 'TwinCAT System' (10000) >> license not found << checking TwinCAT Licenses!"
# zh-TW XAE wording + full-width parentheses (built from code points: ASCII test source)
$zhFatal = -join ([char[]](0x76EE, 0x6A19, 0x7CFB, 0x7D71, 0x56DE, 0x5831, 0x56B4, 0x91CD, 0x932F, 0x8AA4))
$zhLicense = -join ([char[]](0x627E, 0x4E0D, 0x5230, 0x6388, 0x6B0A))
$licZh = "${zhFatal}: 'TwinCAT System' $([char]0xFF08)10000$([char]0xFF09) $zhLicense"
$fatal1809 = "Target system reports a fatal error: 'TwinCAT System' (10000): Sending ams command >> AdsError: 1809 (0x711, ADS ERROR: symbol version invalid) << failed!"
$licHint = & $mod { Get-TcErrorHint -Code 'LICENSE_MISSING' }

# --- A: Test-TcLicenseFailureText
$t = { param($s) & $mod { param($x) Test-TcLicenseFailureText $x } $s }
Check 'A en runtime text -> license failure' (& $t $licEn) ''
Check 'A zh-TW wording, full-width (10000), zh-TW license word -> license failure' (& $t $licZh) $licZh
Check 'A de Lizenz -> license failure' (& $t "'TwinCAT System' (10000): Lizenz nicht gefunden") ''
Check 'A ADS 1809 fatal error (same 10000 prefix, #194) -> not a license failure' (-not (& $t $fatal1809)) ''
Check 'A license word without (10000) -> no' (-not (& $t 'Your 7 day trial license expires soon')) ''
Check 'A bare 10000 (ADS port 10000) + license -> no' (-not (& $t 'ADS port 10000 stays in Config; license server reports expired')) ''
Check 'A empty / null -> no' ((-not (& $t '')) -and (-not (& $t $null))) ''
Check 'A hint names XAE trial / license, ClearLifecycleBlock, never pressing the dialog' ($licHint -match 'Clear-TcLifecycleBlock' -and $licHint -match 'trial' -and $licHint -match 'security code' -and $licHint -match 'data.licenseMissing') $licHint

# --- B: ConvertTo-TcAdsErrorCode (Invoke-TcComRetry / activation watchdog message)
# PR review: ConvertTo-TcAdsErrorCode keeps IDE_MODAL_DIALOG (IDE-blocked code lists elsewhere rely on it)
$m = & $mod { param($x) ConvertTo-TcAdsErrorCode -InputObject $x } "IDE_MODAL_DIALOG: Microsoft Visual Studio | $licEn (operation 'ActivateConfiguration', original error: x)"
Check 'B IDE_MODAL_DIALOG with a license dialog stays IDE_MODAL_DIALOG in ConvertTo-TcAdsErrorCode' ($m.Code -eq 'IDE_MODAL_DIALOG') "$($m.Code)"
$m = & $mod { param($x) ConvertTo-TcAdsErrorCode -InputObject $x } "IDE_MODAL_DIALOG: TwinCAT XAE | $fatal1809"
Check 'B IDE_MODAL_DIALOG with the ADS 1809 dialog -> IDE_MODAL_DIALOG' ($m.Code -eq 'IDE_MODAL_DIALOG') "$($m.Code)"

# --- C: Enable-TcConfig -Force (Set-TcSystemState / activation / IDE stubbed)
$net = '5.6.7.8.1.1'
$global:Dlg = $null            # dialog Find-TcIdeModalDialog reports once $global:Activated
$global:Activated = $false
$global:ActivateThrows = $null
$global:RunResult = 'ok'
$global:DialogPressed = 0
& $mod {
    param($n)
    $script:TcUnitNet = $n
    function script:Assert-TcConnection { }
    function script:Get-TcSysManager { param([switch]$Refresh) $o = [PSCustomObject]@{}; $o | Add-Member -MemberType ScriptMethod -Name GetTargetNetId -Value { $script:TcUnitNet }; $o }
    function script:Get-TcTargetPlatform { param($AmsNetId) [PSCustomObject]@{ targetPlatform = 'TwinCAT OS (x64)'; source = 'adsTargetInfo'; adsError = $null; detail = 'mock' } }
    function script:Get-TcSolutionPlatform { [PSCustomObject]@{ platform = 'TwinCAT OS (x64)'; projectPlatform = 'TwinCAT OS (x64)'; configuration = 'Release' } }
    function script:Find-TcIdeModalDialog { param($TimeoutSec, $ProcessId) if ($global:Activated) { $global:Dlg } else { $null } }
    function script:Find-TcIdeModalDialogWithin { param($BudgetSec, $ProcessId) if ($global:Activated) { $global:Dlg } else { $null } }
    function script:Close-TcIdeModalDialog { $global:DialogPressed++ }
    function script:Get-TcIdeMemoryInfo { $null }
    function script:Invoke-TcActivateWithDeadline {
        param($TimeoutSec, $AmsNetId)
        $global:Activated = $true
        if ($null -ne $global:ActivateThrows) { throw $global:ActivateThrows }
    }
    function script:Get-TcPlcProjectList { param($SysManager) @() }
    function script:Get-TcBootPackageDiff {
        param($SolutionPath, $Platform, $AmsNetId, $AdsPorts, $Variant)
        # $global:BootMismatchFrom = n: the n-th call and later report a mismatch (1st call = boot-package step)
        $global:BootCalls++
        if ($global:BootMismatchFrom -gt 0 -and $global:BootCalls -ge $global:BootMismatchFrom) {
            return [PSCustomObject]@{ status = 'mismatch'; reason = $null; mismatches = @('CurrentConfig.xml'); files = @(); warnings = @(); targetDir = 'T'; localDir = 'L'; targetKind = 'mock' }
        }
        $null
    }
    function script:Get-TcBuildErrors { param($TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @() }) }
    function script:Set-TcSystemState {
        param([string]$State, [string]$AmsNetId, [int]$TimeoutSec)
        if ($State -eq 'Config' -or $global:RunResult -eq 'ok') { return New-TcResult -Success $true -Data ([PSCustomObject]@{ currentState = $State; sentAdsState = 'x'; readbackState = $State; requestSent = $true }) }
        New-TcResult -Success $false -ErrorCode 'SYSTEM_STATE_TIMEOUT' -ErrorMessage 'TwinCAT did not reach Run within 2 s (mock)' -Hint (Get-TcErrorHint -Code 'SYSTEM_STATE_TIMEOUT') `
            -Data ([PSCustomObject]@{ currentState = 'Config'; finalState = 'Config'; readbackState = 'Config'; requestSent = $true })
    }
    $script:TcDte = $null
    $script:TcSolutionPath = 'C:\Demo\License.sln'
} $net
function Reset-Case { $global:Dlg = $null; $global:Activated = $false; $global:ActivateThrows = $null; $global:RunResult = 'ok'; $global:BootCalls = 0; $global:BootMismatchFrom = 0; $global:ElRows49 = @() }
$global:ElRows49 = @()
& $mod { function script:Get-TcBuildErrors { param($TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @($global:ElRows49 | ForEach-Object { [PSCustomObject]@{ description = $_ } }) }) } }
function Clear-Block { $null = Clear-TcLifecycleBlock -AmsNetId $net -Reason 'unit test: next case' -FallbackMethod 'unit test: rerun through tcauto' -AllowedSideEffects 'none' -MaxVerifyLevel None }
function Assert-LicenseResult([string]$Name, $r, [string]$Original) {
    Check "$Name code LICENSE_MISSING, success false" ((-not $r.success) -and $r.error.code -eq 'LICENSE_MISSING') "code=$($r.error.code) msg=$($r.error.message)"
    Check "$Name message starts with 'LICENSE_MISSING: ' (PR #259 N1)" ([string]$r.error.message).StartsWith('LICENSE_MISSING: ') "$($r.error.message)"
    Check "$Name lifecycle block kept, recorded as LICENSE_MISSING" ($null -ne $r.data.lifecycleBlock -and $r.data.lifecycleBlock.errorCode -eq 'LICENSE_MISSING' -and $r.data.lifecycleBlock.command -eq 'Enable-TcConfig') ($r.data.lifecycleBlock | ConvertTo-Json -Compress)
    Check "$Name hint = stop text + LICENSE_MISSING hint" ($r.error.hint.EndsWith($licHint) -and $r.error.hint -ne $licHint) "$($r.error.hint)"
    Check "$Name data.licenseMissing evidence + originalCode $Original" ($r.data.licenseMissing.originalCode -eq $Original -and (& $mod { param($x) Test-TcLicenseFailureText $x } ([string]$r.data.licenseMissing.evidence))) ($r.data.licenseMissing | ConvertTo-Json -Compress)
    Check "$Name dialog not pressed" ($global:DialogPressed -eq 0) "$($global:DialogPressed)"
    $b = Enable-TcConfig -Force -WarningAction SilentlyContinue
    Check "$Name next Enable-TcConfig -> LIFECYCLE_BLOCKED (block not bypassed)" ($b.error.code -eq 'LIFECYCLE_BLOCKED') "$($b.error.code)"
}

# C1: the activation watchdog saw the license dialog (Invoke-TcActivateWithDeadline throws IDE_MODAL_DIALOG)
Reset-Case
$global:ActivateThrows = "IDE_MODAL_DIALOG: Microsoft Visual Studio | $licEn (operation 'ActivateConfiguration', original error: x)"
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Assert-LicenseResult 'C1 activate dialog (en):' $r 'IDE_MODAL_DIALOG'
Check 'C1 activated false, activate step failed' ((-not $r.data.activated) -and @($r.data.steps | Where-Object { $_.step -eq 'activate' -and -not $_.ok }).Count -eq 1) ''
Clear-Block

# C2: Activate returned, set-run timed out, the zh-TW fatal error dialog is up (New-TcRuntimeFailure)
Reset-Case
$global:RunResult = 'timeout'
$global:Dlg = @{ Title = 'Microsoft Visual Studio'; Text = $licZh; Kind = 'unknown' }
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Assert-LicenseResult 'C2 set-run + zh-TW dialog:' $r 'SYSTEM_STATE_TIMEOUT'
Check 'C2 data.diagnostics.dialog carries the dialog' ($r.data.diagnostics.dialog.text -eq $licZh) ($r.data.diagnostics | ConvertTo-Json -Compress -Depth 4)
Clear-Block

# C3: Activate returned, set-run Run, the license dialog is up before login (Test-TcStepModalDialog)
Reset-Case
$global:Dlg = @{ Title = 'Microsoft Visual Studio'; Text = $licEn; Kind = 'unknown' }
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Assert-LicenseResult 'C3 dialog before login:' $r 'IDE_MODAL_DIALOG'
Check 'C3 data.dialogTitle / dialogText kept' ($r.data.dialogTitle -eq 'Microsoft Visual Studio' -and $r.data.dialogText -eq $licEn) ''
Clear-Block

# C4: ADS 1809 dialog after set-run -> not LICENSE_MISSING (#194 keeps its code)
Reset-Case
$global:RunResult = 'timeout'
$global:Dlg = @{ Title = 'TwinCAT XAE'; Text = $fatal1809; Kind = 'unknown' }
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'C4 ADS 1809 dialog: code stays SYSTEM_STATE_TIMEOUT, no data.licenseMissing, block kept' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $null -eq $r.data.PSObject.Properties['licenseMissing'] -and $r.data.lifecycleBlock.errorCode -eq 'SYSTEM_STATE_TIMEOUT') "code=$($r.error.code)"
Clear-Block

# C6: PR review E - Error List rows of different sources are not joined: an ADS 1809 row with (10000)
# and another row with a license word -> no LICENSE_MISSING
Reset-Case
$global:RunResult = 'timeout'
$global:Dlg = $null
& $mod { function script:Get-TcBuildErrors { param($TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @([PSCustomObject]@{ description = "'TwinCAT System' (10000): AdsError: 1809 (0x711)" }, [PSCustomObject]@{ description = 'PLC log: license check of my own FB failed' }) }) } }
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'C6 1809 row + unrelated license row: not LICENSE_MISSING' ($r.error.code -ne 'LICENSE_MISSING' -and $null -eq $r.data.PSObject.Properties['licenseMissing']) "code=$($r.error.code) msg=$($r.error.message)"
& $mod { function script:Get-TcBuildErrors { param($TimeoutSec) New-TcResult -Success $true -Data ([PSCustomObject]@{ errors = @($global:ElRows49 | ForEach-Object { [PSCustomObject]@{ description = $_ } }) }) } }
Clear-Block

# C7: PR review C - IDE_CRASHED keeps its code even when the message carries license text
Reset-Case
$global:ActivateThrows = "IDE_CRASHED: the IDE process (pid 1) no longer exists after 'ActivateConfiguration' failed (original error: $licEn)"
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'C7 IDE_CRASHED with license text keeps IDE_CRASHED, block recorded' ($r.error.code -eq 'IDE_CRASHED' -and $r.data.lifecycleBlock.errorCode -eq 'IDE_CRASHED') "code=$($r.error.code)"
Clear-Block

# --- PR #259 S1: an Error List row alone (it may be left from an earlier activation) never changes
# the code; it is only a reference (data.licenseErrorListEvidence + a note after the original hint)
$staleRow = "11/12/2026 9:00:00 PM | 'TwinCAT System' (10000): >> license not found << checking TwinCAT Licenses!"
$tsHint = & $mod { Get-TcErrorHint -Code 'SYSTEM_STATE_TIMEOUT' }
$bootHint = & $mod { Get-TcErrorHint -Code 'BOOT_PACKAGE_MISMATCH' }

# C8: no dialog, stale license row, set-run timeout, Boot mismatch in the diagnostics -> BOOT_PACKAGE_MISMATCH kept
Reset-Case
$global:RunResult = 'timeout'
$global:BootMismatchFrom = 2
$global:ElRows49 = @($staleRow)
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'C8 stale license row + Boot mismatch: BOOT_PACKAGE_MISMATCH kept (code, block), no data.licenseMissing' ($r.error.code -eq 'BOOT_PACKAGE_MISMATCH' -and $r.data.lifecycleBlock.errorCode -eq 'BOOT_PACKAGE_MISMATCH' -and $null -eq $r.data.PSObject.Properties['licenseMissing']) "code=$($r.error.code) msg=$($r.error.message)"
Check 'C8 row kept as reference: data.licenseErrorListEvidence, original hint kept, note after it' ($r.data.licenseErrorListEvidence -match 'license not found' -and (-not [string]::IsNullOrEmpty($bootHint)) -and $r.error.hint.Contains($bootHint) -and $r.error.hint.IndexOf('licenseErrorListEvidence') -gt $r.error.hint.IndexOf($bootHint)) "$($r.error.hint)"
Clear-Block

# C9: no dialog, stale license row, set-run timeout -> SYSTEM_STATE_TIMEOUT kept with its hint
Reset-Case
$global:RunResult = 'timeout'
$global:ElRows49 = @('Some other row', $staleRow)
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'C9 stale license row + set-run timeout: SYSTEM_STATE_TIMEOUT kept, its hint kept, row as reference' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $r.error.hint.Contains($tsHint) -and $r.data.licenseErrorListEvidence -match 'license not found' -and $null -eq $r.data.PSObject.Properties['licenseMissing']) "code=$($r.error.code) hint=$($r.error.hint)"
Clear-Block

# C10: ADS 1809 dialog + license Error List row in data.diagnostics -> not LICENSE_MISSING
$origDiag = & $mod { ${function:Get-TcRuntimeFailureDiagnostics} }
& $mod { param($t1809, $row) $script:TcUnit1809 = $t1809; $script:TcUnitRow = $row
    function script:Get-TcRuntimeFailureDiagnostics { param($DialogScan, $Deadline, $SolutionPath, $Platform, $AmsNetId, $AdsPorts, $Variant, [switch]$NoIde)
        [PSCustomObject]@{ dialog = [PSCustomObject]@{ title = 'TwinCAT XAE'; text = $script:TcUnit1809 }; dialogScanComplete = $true; errorList = @($script:TcUnitRow); errorListError = $null; bootPackage = $null } } } $fatal1809 $staleRow
Reset-Case
$global:RunResult = 'timeout'
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'C10 ADS 1809 dialog + license row: not LICENSE_MISSING, code / hint of the failure kept' ($r.error.code -eq 'SYSTEM_STATE_TIMEOUT' -and $null -eq $r.data.PSObject.Properties['licenseMissing'] -and $r.error.hint.Contains($tsHint) -and $r.data.licenseErrorListEvidence -match 'license not found') "code=$($r.error.code) hint=$($r.error.hint)"
& $mod { param($f) Set-Item -Path function:script:Get-TcRuntimeFailureDiagnostics -Value $f } $origDiag
Clear-Block

# C5: license dialog already up BEFORE set-config: nothing sent -> LICENSE_MISSING without a block
Reset-Case
$global:Activated = $true
$global:Dlg = @{ Title = 'Microsoft Visual Studio'; Text = $licEn; Kind = 'unknown' }
$r = Enable-TcConfig -Force -WarningAction SilentlyContinue
Check 'C5 dialog before set-config: LICENSE_MISSING, no lifecycle block (nothing sent)' ($r.error.code -eq 'LICENSE_MISSING' -and $null -eq $r.data.PSObject.Properties['lifecycleBlock'] -and $r.error.hint -eq $licHint) "code=$($r.error.code) hint=$($r.error.hint)"
Check 'C5 no block recorded' ($null -eq (& $mod { param($n) Get-TcLifecycleBlock -AmsNetId $n } $net)) ''

exit [Math]::Min($fail, 255)
