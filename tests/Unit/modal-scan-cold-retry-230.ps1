# Unit: #230 the one-shot modal-dialog gates (Connect-TcIde before Solution.Open, Build-TcProject
# before the build) repeat a scan that timed out once with a longer budget. No IDE needed.
#   1  first scan timeout, retry complete (no dialog) -> $null, 2 scans, retry with 15 s
#   2  first scan timeout, retry finds a dialog -> the dialog record
#   3  both scans time out -> incomplete (callers fail closed: MODAL_SCAN_INCOMPLETE)
#   4  other incomplete reasons (error, prepare-timeout) are not retried
#   5  a complete first scan is not repeated
#   6  Connect-TcIde and Build-TcProject use the retrying gate
#   powershell.exe -NoProfile -File tests/Unit/modal-scan-cold-retry-230.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
$env:TCAUTO_STATE_DIR = Join-Path $env:TEMP ("tcauto-unit-230-{0}" -f [guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# $global:ScanPlan: one entry per scan, 'none' | 'dialog' | an incomplete reason
& $mod {
    function script:Find-TcIdeModalDialog {
        [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$MaxTextLength = 2000, [int]$PrepareTimeoutSec = 0)
        $global:ScanCalls += , $TimeoutSec
        $global:PrepCalls += , $PrepareTimeoutSec
        $next = $global:ScanPlan[0]; $global:ScanPlan = @($global:ScanPlan | Select-Object -Skip 1)
        if ($next -eq 'none') { return $null }
        if ($next -eq 'dialog') { return @{ Title = 'License'; Text = 'license not found'; Hwnd = 1; Buttons = @() } }
        New-TcModalScanIncomplete -Reason $next -TimeoutSec $TimeoutSec -Message 'mock'
    }
}
function Run([string[]]$Plan) {
    $global:ScanPlan = $Plan; $global:ScanCalls = @(); $global:PrepCalls = @()
    & $mod { Find-TcIdeModalDialogColdRetry }
}
function Inc($d) { & $mod { param($x) Test-TcModalScanIncomplete $x } $d }

$r = Run @('timeout', 'none')
Check '1 timeout then complete -> $null, 2 scans (5 s default, 15 s retry)' ($null -eq $r -and $global:ScanCalls.Count -eq 2 -and $global:ScanCalls[0] -eq 5 -and $global:ScanCalls[1] -eq 15) "calls=$($global:ScanCalls -join ',')"
$retried = & $mod { $script:TcLastModalScanRetried }
Check '1 retry caps phase 1 at 5 s (PrepareTimeoutSec 5) and sets TcLastModalScanRetried' ($global:PrepCalls[1] -eq 5 -and $retried -eq $true) "prep=$($global:PrepCalls -join ',') retried=$retried"
$r = Run @('timeout', 'dialog')
Check '2 timeout then dialog -> dialog record' ($null -ne $r -and -not (Inc $r) -and $r.Title -eq 'License') "calls=$($global:ScanCalls -join ',')"
$r = Run @('timeout', 'timeout')
Check '3 two timeouts -> incomplete, no third scan' ((Inc $r) -and $global:ScanCalls.Count -eq 2) "calls=$($global:ScanCalls -join ',')"
foreach ($reason in @('error', 'prepare-timeout')) {
    $r = Run @($reason, 'none')
    Check "4 reason '$reason' is not retried" ((Inc $r) -and $global:ScanCalls.Count -eq 1) "calls=$($global:ScanCalls -join ',')"
}
$r = Run @('none', 'none')
Check '5 complete first scan -> one scan' ($null -eq $r -and $global:ScanCalls.Count -eq 1) "calls=$($global:ScanCalls -join ',')"
Check '5 no retry -> TcLastModalScanRetried false' ((& $mod { $script:TcLastModalScanRetried }) -eq $false) ''

$src = Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\Public'
foreach ($f in @('Connect-TcIde.ps1', 'Build-TcProject.ps1')) {
    $t = [IO.File]::ReadAllText((Join-Path $src $f))
    Check "6 $f uses Find-TcIdeModalDialogColdRetry and reports data.modalScanRetried" ($t -match '\$dialog = Find-TcIdeModalDialogColdRetry' -and $t -match 'modalScanRetried') ''
}
Remove-Item -LiteralPath $env:TCAUTO_STATE_DIR -Recurse -Force -ErrorAction SilentlyContinue
"failed: $fail"
exit $fail
