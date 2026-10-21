# Unit: ActivateConfiguration() deadline (Invoke-TcActivateWithDeadline), no IDE / runtime needed.
# The background call is replaced by -ActivateScript (test hook); the IDE pid is this process.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/activate-timeout.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
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
Check 'timeout-at-deadline' ($sec -ge 3 -and $sec -lt 8) ("{0:N1} s" -f $sec)
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

"failed: $fail"
exit $fail
