# Unit: ActivateConfiguration() deadline (Invoke-TcActivateWithDeadline), no IDE / runtime needed.
# The background call is replaced by -ActivateScript (test hook); the IDE pid is this process.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/activate-timeout.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

& $mod { param($p) $script:TcIdeProcessId = $p } $PID

# 1. call that never returns in time -> ACTIVATE_TIMEOUT at the deadline, diagnostics filled
$sw = [Diagnostics.Stopwatch]::StartNew()
$msg = $null
try { & $mod { Invoke-TcActivateWithDeadline -TimeoutSec 3 -ActivateScript 'Start-Sleep -Seconds 60' } } catch { $msg = $_.Exception.Message }
$sec = $sw.Elapsed.TotalSeconds
$diag = & $mod { $script:TcLastActivateDiagnostics }
Check 'timeout-code' ($msg -match '^ACTIVATE_TIMEOUT') $msg
# #153: the documented bound is -TimeoutSec + diagnostics budget (10 s) + teardown (< 1 s); the loop
# itself must end at the deadline (diag.elapsedSec). Measured 2026-11-06 before the fix, 16 cores +
# 32 busy loops: the unbounded cold UIA scan inside the loop took 2.0-3.7 s, total 5.9-8.7 s
# (2/10 over the old 8 s limit); CI run 42136357332: elapsedSec 29.
Check 'timeout-at-deadline' ($sec -ge 3 -and $sec -lt 14) ("{0:N1} s" -f $sec)
Check 'timeout-loop-ends-at-deadline' ($null -ne $diag -and $diag.elapsedSec -le 4) ("elapsedSec {0}" -f $diag.elapsedSec)
Check 'timeout-diagnostics-within-budget' ($null -ne $diag -and $null -ne $diag.diagnosticsSec -and $diag.diagnosticsSec -le 11) ("diagnosticsSec {0} (budget 10 s + 1 s)" -f $diag.diagnosticsSec)
Check 'timeout-diagnostics' ($null -ne $diag -and $diag.ideAlive -eq $true -and $null -ne $diag.ideResponding) ($diag | ConvertTo-Json -Compress)

# 2. call that returns in time -> no exception
$msg = $null
try { & $mod { Invoke-TcActivateWithDeadline -TimeoutSec 10 -ActivateScript 'Start-Sleep -Milliseconds 500; ''done''' } } catch { $msg = $_.Exception.Message }
Check 'in-time' ($null -eq $msg) "$msg"

# 3. call that fails -> original error rethrown (not a timeout)
$msg = $null
try { & $mod { Invoke-TcActivateWithDeadline -TimeoutSec 10 -ActivateScript 'throw ''Check config failed (mock)''' } } catch { $msg = $_.Exception.Message }
Check 'error-rethrown' ($msg -match 'Check config failed \(mock\)' -and $msg -notmatch 'ACTIVATE_TIMEOUT') "$msg"

# 4. IDE process gone when the call fails -> IDE_CRASHED
$dead = Start-Process -FilePath cmd.exe -ArgumentList '/c exit' -PassThru -WindowStyle Hidden
$dead.WaitForExit()
& $mod { param($p) $script:TcIdeProcessId = $p } $dead.Id
$msg = $null
try { & $mod { Invoke-TcActivateWithDeadline -TimeoutSec 10 -ActivateScript 'throw ''RPC_S_SERVER_UNAVAILABLE (mock)''' } } catch { $msg = $_.Exception.Message }
Check 'ide-crashed' ($msg -match '^IDE_CRASHED') "$msg"

# 5. #153 budget split of Find-TcIdeModalDialogWithin (the real scan replaced by a recorder)
& $mod { param($p) $script:TcIdeProcessId = $p } $PID
& $mod {
    $global:Scan153 = [System.Collections.Generic.List[object]]::new()
    function script:Find-TcIdeModalDialog { param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0) $global:Scan153.Add(@($PrepareTimeoutSec, $TimeoutSec)); $null }
}
$cases = @(@{ b = 1.9; want = $null }, @{ b = 2.5; want = '1/1' }, @{ b = 3.0; want = '2/1' }, @{ b = 10; want = '5/5' }, @{ b = 200; want = '60/5' })
foreach ($k in $cases) {
    $global:Scan153.Clear()
    $r = & $mod { param($b) Find-TcIdeModalDialogWithin -BudgetSec $b } $k.b
    $got = if ($global:Scan153.Count -gt 0) { '{0}/{1}' -f $global:Scan153[0][0], $global:Scan153[0][1] } else { $null }
    $incomplete = & $mod { param($x) Test-TcModalScanIncomplete $x } $r
    # no time left: nothing scanned, Reason 'no-budget' and the real IDE pid (not 0)
    $ok = if ($null -eq $k.want) { $null -eq $got -and $incomplete -and $r.Reason -eq 'no-budget' -and $r.ProcessId -eq $PID } else { $got -eq $k.want }
    Check ("scan-budget-{0}" -f $k.b) $ok ("prepare/scan {0}, incomplete {1}" -f $got, $incomplete)
}

# 6. #153 worst case: every scan blocks for its whole prepare + scan cap (cold UIA on a slow CI
# runner; old code: prepare cap 60 s). ACTIVATE_TIMEOUT must still come within
# -TimeoutSec + diagnostics budget + 1 s, and the loop must end at the deadline.
& $mod {
    function script:Find-TcIdeModalDialog {
        param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        $p = if ($PrepareTimeoutSec -gt 0) { $PrepareTimeoutSec } else { 60 }
        Start-Sleep -Seconds ($p + $TimeoutSec)
        New-TcModalScanIncomplete -ProcessId $ProcessId -Reason 'prepare-timeout' -Message 'mock: cold prepare'
    }
    function script:Resolve-TcTargetBootDir { param([string]$AmsNetId) @{ Dir = 'C:\none-153'; Kind = 'umrt:Mock153' } }
    $script:TcActivateDiagBudgetSec = 4
}
$sw = [Diagnostics.Stopwatch]::StartNew()
$msg = $null
try { & $mod { Invoke-TcActivateWithDeadline -TimeoutSec 6 -AmsNetId '192.0.2.1.1.1' -ActivateScript 'Start-Sleep -Seconds 60' } } catch { $msg = $_.Exception.Message }
$sec = $sw.Elapsed.TotalSeconds
$diag = & $mod { $script:TcLastActivateDiagnostics }
Check 'worst-case-code' ($msg -match '^ACTIVATE_TIMEOUT') $msg
# documented bound: -TimeoutSec 6 + diagnostics budget 4 + teardown 1 = 11 s; plus 1 s slack for a
# loaded CI runner (measured 2026-11-06, 16 cores + 32 busy loops: 9.6-10.6 s)
$bound = 6 + 4 + 1
$ciSlack = 1
Check 'worst-case-bound' ($sec -ge 6 -and $sec -lt ($bound + $ciSlack)) ("{0:N1} s (bound {1} s + {2} s CI slack)" -f $sec, $bound, $ciSlack)
Check 'worst-case-loop-at-deadline' ($null -ne $diag -and $diag.elapsedSec -le 7) ("elapsedSec {0}" -f $diag.elapsedSec)
Check 'worst-case-scan-reported' ($null -ne $diag -and $diag.dialogScanComplete -eq $false -and $null -ne $diag.modalScan) ($diag | ConvertTo-Json -Compress -Depth 4)
Check 'worst-case-ads-skipped' ($null -ne $diag -and [string]$diag.systemState -like 'skipped:*') ("systemState {0}" -f $diag.systemState)
Check 'worst-case-runtime-skipped' ($null -ne $diag -and $null -eq $diag.runtimeAlive -and [string]$diag.runtimeCheck -like 'skipped:*') ("runtimeCheck {0}" -f $diag.runtimeCheck)
& $mod { $script:TcActivateDiagBudgetSec = $null }

# 7. #153 review: a dialog seen during the wait is reported even when the scan after the deadline
# is incomplete (same as Save-TcPlcProject); a failing UmRT check is runtimeCheck 'error: ...'
& $mod {
    $global:Scan153Calls = 0
    function script:Find-TcIdeModalDialog {
        param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0)
        $global:Scan153Calls++
        if ($global:Scan153Calls -eq 1) { return @{ Title = 'Mock dialog 153'; Text = 'seen during the wait'; Kind = 'unknown'; ReloadTarget = $null; Hwnd = [long]0; Buttons = @() } }
        New-TcModalScanIncomplete -ProcessId $ProcessId -Reason 'timeout' -Message 'mock: scan timed out'
    }
    function script:Resolve-TcTargetBootDir { param([string]$AmsNetId) throw 'mock: registry not readable' }
    function script:New-TcAdsClient { param([string]$AmsNetId, [int]$Port) throw 'mock: no ADS router' }
}
$msg = $null
try { & $mod { Invoke-TcActivateWithDeadline -TimeoutSec 5 -AmsNetId '192.0.2.1.1.1' -ActivateScript 'Start-Sleep -Seconds 60' } } catch { $msg = $_.Exception.Message }
$diag = & $mod { $script:TcLastActivateDiagnostics }
Check 'seen-during-wait-code' ($msg -match '^ACTIVATE_TIMEOUT' -and $msg -match 'Mock dialog 153') $msg
Check 'seen-during-wait-dialog' ($null -ne $diag -and [string]$diag.dialog.title -eq 'Mock dialog 153' -and $diag.dialogSeenDuringWait -eq $true -and $diag.dialogScanComplete -eq $false) ($diag | ConvertTo-Json -Compress -Depth 4)
Check 'runtime-check-error' ($null -ne $diag -and $null -eq $diag.runtimeAlive -and [string]$diag.runtimeCheck -like 'error: *mock: registry not readable*') ("runtimeCheck {0}" -f $diag.runtimeCheck)
Check 'ads-unreachable' ($null -ne $diag -and [string]$diag.systemState -like 'unreachable: *') ("systemState {0}" -f $diag.systemState)

"failed: $fail"
exit [Math]::Min($fail, 255)
