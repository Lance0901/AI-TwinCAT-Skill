# Unit: a timed-out Error List scan must not break Get-TcBuildErrors for good (issue #75),
# no IDE / runtime needed.
#   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Unit/errorlist-abandoned-scan.ps1
# Exit code = number of failed checks.
# The abandoned entries are real PowerShell/Runspace pairs that already finished; only the UIA
# scan itself (Invoke-TcUiaScan) and View.ErrorList (Invoke-TcComRetry) are replaced.
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# Probe: does this host reproduce #75 (measured 2026-10-28, PS 5.1.26100.9711: @() around a
# non-empty List[object] built with New-Object throws ArgumentException)?
$reproduces = $false
try {
    $probe = New-Object System.Collections.Generic.List[object]
    $probe.Add(1)
    $null = @($probe)
}
catch { $reproduces = $true }
"host reproduces #75: {0} (PowerShell {1})" -f $(if ($reproduces) { 'yes' } else { 'no' }), $PSVersionTable.PSVersion

# A finished (Completed) PowerShell/Runspace pair, shaped like Invoke-TcUiaScan parks it.
function New-StoppedEntry {
    $rs = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $rs.Open()
    $ps = [PowerShell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript('1').Invoke()
    [PSCustomObject]@{ PowerShell = $ps; Runspace = $rs; Started = (Get-Date).ToString('s') }
}

# Parks entries the way the module did before #75: a List[object] built with New-Object, on
# which @() threw ArgumentException in Windows PowerShell 5.1.26100.
function Set-Abandoned([object[]]$Entries, [switch]$NullList) {
    & $mod {
        param($e, $n)
        if ($n) { $script:TcUiaAbandonedScans = $null }
        else {
            $script:TcUiaAbandonedScans = New-Object System.Collections.Generic.List[object]
            foreach ($x in $e) { $script:TcUiaAbandonedScans.Add($x) }
        }
        $script:TcErrorListScanBusy = $true
    } $Entries ([bool]$NullList)
}
function Get-ScanState { & $mod { [PSCustomObject]@{ busy = $script:TcErrorListScanBusy; count = $script:TcUiaAbandonedScans.Count; warning = $script:TcUiaCleanupWarning } } }

# 1. one stopped entry: disposed, busy cleared, no warning
$entry = New-StoppedEntry
Set-Abandoned @($entry)
$threw = $null
try { $left = & $mod { Clear-TcUiaAbandonedScans } } catch { $threw = $_.Exception.Message }
$s = Get-ScanState
Check 'Clear: stopped entry does not throw' ($null -eq $threw) "$threw"
Check 'Clear: returns 0 still running' ($left -eq 0) "got $left"
Check 'Clear: busy cleared, list empty' ((-not $s.busy) -and $s.count -eq 0) "busy=$($s.busy) count=$($s.count)"
Check 'Clear: no warning for a clean dispose' ($null -eq $s.warning) "$($s.warning)"
Check 'Clear: runspace disposed' ($entry.Runspace.RunspaceStateInfo.State -eq 'Closed') "$($entry.Runspace.RunspaceStateInfo.State)"

# 2. an entry that cannot be disposed is dropped (not retried) and reported
Set-Abandoned @([PSCustomObject]@{ PowerShell = $null; Runspace = $null; Started = 'broken' })
$threw = $null
try { $left = & $mod { Clear-TcUiaAbandonedScans } } catch { $threw = $_.Exception.Message }
$s = Get-ScanState
Check 'Clear: broken entry does not throw' ($null -eq $threw) "$threw"
Check 'Clear: broken entry dropped, busy cleared' ((-not $s.busy) -and $s.count -eq 0) "busy=$($s.busy) count=$($s.count)"
Check 'Clear: broken entry reported' ([string]$s.warning -match '#75') "$($s.warning)"
Check 'Clear: unreadable state => may be running' ((& $mod { $script:TcUiaCleanupMayBeRunning }) -eq $true) ''

# 2b. state read as Completed but both Dispose calls fail: each is tried on its own, dropped,
#     reported, and NOT treated as possibly running (the thread is known to be stopped)
$script:disposeCalls = 0
$psFake = [PSCustomObject]@{ InvocationStateInfo = [PSCustomObject]@{ State = [System.Management.Automation.PSInvocationState]::Completed } }
$rsFake = [PSCustomObject]@{}
$psFake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:disposeCalls++; throw 'ps dispose failed' }
$rsFake | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $script:disposeCalls++; throw 'rs dispose failed' }
Set-Abandoned @([PSCustomObject]@{ PowerShell = $psFake; Runspace = $rsFake; Started = 'disposefail' })
$threw = $null
try { $left = & $mod { Clear-TcUiaAbandonedScans } } catch { $threw = $_.Exception.Message }
$s = Get-ScanState
Check 'Clear: dispose failure does not throw' ($null -eq $threw) "$threw"
Check 'Clear: both Dispose calls attempted' ($script:disposeCalls -eq 2) "calls=$($script:disposeCalls)"
Check 'Clear: dispose failure dropped, busy cleared, reported' ((-not $s.busy) -and $s.count -eq 0 -and [string]$s.warning -match '#75') "busy=$($s.busy) count=$($s.count) warning=$($s.warning)"
Check 'Clear: dispose failure is not "may be running"' ((& $mod { $script:TcUiaCleanupMayBeRunning }) -eq $false) ''

# 3. a list that cannot be walked is reset and reported
Set-Abandoned @() -NullList
$threw = $null
try { $left = & $mod { Clear-TcUiaAbandonedScans } } catch { $threw = $_.Exception.Message }
$s = Get-ScanState
Check 'Clear: unwalkable list does not throw' ($null -eq $threw) "$threw"
Check 'Clear: unwalkable list reset, busy cleared' ((-not $s.busy) -and $s.count -eq 0) "busy=$($s.busy) count=$($s.count)"
Check 'Clear: unwalkable list reported' ([string]$s.warning -match 'reset') "$($s.warning)"
Check 'Clear: unwalkable list => may be running' ((& $mod { $script:TcUiaCleanupMayBeRunning }) -eq $true) ''

# 4. Get-TcBuildErrors after a timed-out scan: runs the next scan instead of throwing
& $mod {
    $script:TcDte = [PSCustomObject]@{}
    $script:TcIdeConnected = $true
    $script:TcIdeProcessId = $PID   # an existing process
    function script:Invoke-TcComRetry { [CmdletBinding()] param([scriptblock]$ScriptBlock, [int]$MaxRetries, [string]$OperationName, [int]$TimeoutSec) $null }
    function script:Invoke-TcUiaScan {
        [CmdletBinding()] param([scriptblock]$Script, [object[]]$Arguments, [int]$TimeoutSec, [ref]$TimedOut, [ref]$ErrorOut)
        $global:UiaScanCalls++
        [PSCustomObject]@{ Found = $true; Rows = @(); Counts = [PSCustomObject]@{ errors = 0; warnings = 0; messages = 0 }; Truncated = $false; ToggleUsed = $true; Notes = @(); Headers = @() }
    }
}
$global:UiaScanCalls = 0
Set-Abandoned @(New-StoppedEntry)
foreach ($n in 1..2) {
    $threw = $null; $r = $null
    try { $r = Get-TcBuildErrors -TimeoutSec 5 } catch { $threw = $_.Exception.Message }
    $s = Get-ScanState
    Check "Get-TcBuildErrors #$($n): no exception" ($null -eq $threw) "$threw"
    Check "Get-TcBuildErrors #$($n): success, 0 errors" ($null -ne $r -and $r.success -and $r.data.counts.errors -eq 0) $(if ($null -ne $r) { $r | ConvertTo-Json -Depth 4 -Compress } else { '' })
    Check "Get-TcBuildErrors #$($n): busy cleared" (-not $s.busy) "busy=$($s.busy)"
}
Check 'Get-TcBuildErrors: scan ran each time' ($global:UiaScanCalls -eq 2) "calls=$($global:UiaScanCalls)"

# 5. dropped entry whose thread is known to be stopped (dispose failed): scan still runs, warning visible
$before = $global:UiaScanCalls
$script:disposeCalls = 0
Set-Abandoned @([PSCustomObject]@{ PowerShell = $psFake; Runspace = $rsFake; Started = 'disposefail' })
$r = Get-TcBuildErrors -TimeoutSec 5
Check 'Get-TcBuildErrors: scan ran after a dispose failure' ($r.success -and $global:UiaScanCalls -eq $before + 1) "calls=$($global:UiaScanCalls) before=$before"
Check 'Get-TcBuildErrors: data.scanCleanupWarning after a dropped entry' ($r.success -and [string]$r.data.scanCleanupWarning -match '#75') "$($r.data.scanCleanupWarning)"

# 6. dropped entry that MAY STILL BE RUNNING (state unreadable): this call starts no scan
#    (it could race the old thread for the filter buttons => errors = 0 => false success);
#    the next call scans
$before = $global:UiaScanCalls
Set-Abandoned @([PSCustomObject]@{ PowerShell = $null; Runspace = $null; Started = 'broken' })
$r = Get-TcBuildErrors -TimeoutSec 5
Check 'may-be-running: ERRORLIST_UNAVAILABLE, not success' ((-not $r.success) -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE') "$($r.error.code)"
Check 'may-be-running: no scan started' ($global:UiaScanCalls -eq $before) "calls=$($global:UiaScanCalls) before=$before"
Check 'may-be-running: data.scanBusy false, scanMayBeRunning true, warning present' ($r.data.scanBusy -eq $false -and $r.data.scanMayBeRunning -eq $true -and [string]$r.data.scanCleanupWarning -match '#75') ($r.data | ConvertTo-Json -Compress)
$r = Get-TcBuildErrors -TimeoutSec 5
Check 'may-be-running: next call scans normally' ($r.success -and $global:UiaScanCalls -eq $before + 1 -and $null -eq $r.data.PSObject.Properties['scanCleanupWarning']) "calls=$($global:UiaScanCalls) before=$before"
# same for a list that cannot be walked
$before = $global:UiaScanCalls
Set-Abandoned @() -NullList
$r = Get-TcBuildErrors -TimeoutSec 5
Check 'may-be-running (list reset): no scan, ERRORLIST_UNAVAILABLE' ((-not $r.success) -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE' -and $global:UiaScanCalls -eq $before) "calls=$($global:UiaScanCalls) before=$before"
$r = Get-TcBuildErrors -TimeoutSec 5
Check 'may-be-running (list reset): next call scans' ($r.success -and $global:UiaScanCalls -eq $before + 1) "calls=$($global:UiaScanCalls) before=$before"

# 7. an entry that is really still running (Start-Sleep 30): stays tracked, no scan, scanBusy true
$live = [powershell]::Create()
try {
    $null = $live.AddScript('Start-Sleep 30')
    $handle = $live.BeginInvoke()
    $liveRs = $live.Runspace
    # BeginInvoke opens the runspace asynchronously: wait until the script is really running
    $deadline = (Get-Date).AddSeconds(15)
    while ((($liveRs.RunspaceStateInfo.State -ne 'Opened') -or ($live.InvocationStateInfo.State -ne 'Running')) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 50 }
    $before = $global:UiaScanCalls
    Set-Abandoned @([PSCustomObject]@{ PowerShell = $live; Runspace = $liveRs; Started = 'live' })
    $threw = $null
    try { $left = & $mod { Clear-TcUiaAbandonedScans } } catch { $threw = $_.Exception.Message }
    $s = Get-ScanState
    Check 'running entry: Clear does not throw' ($null -eq $threw) "$threw"
    Check 'running entry: Clear returns 1' ($left -eq 1) "got $left"
    Check 'running entry: busy stays true, still tracked' ($s.busy -eq $true -and $s.count -eq 1) "busy=$($s.busy) count=$($s.count)"
    Check 'running entry: runspace still Opened' ($liveRs.RunspaceStateInfo.State -eq 'Opened') "$($liveRs.RunspaceStateInfo.State)"
    $r = Get-TcBuildErrors -TimeoutSec 5
    Check 'running entry: ERRORLIST_UNAVAILABLE with data.scanBusy' ((-not $r.success) -and $r.error.code -eq 'ERRORLIST_UNAVAILABLE' -and $r.data.scanBusy -eq $true) ($r | ConvertTo-Json -Depth 4 -Compress)
    Check 'running entry: no scan started' ($global:UiaScanCalls -eq $before) "calls=$($global:UiaScanCalls) before=$before"
    $live.Stop()
    $left = & $mod { Clear-TcUiaAbandonedScans }
    $s = Get-ScanState
    Check 'running entry: after Stop(), Clear returns 0' ($left -eq 0) "got $left"
    Check 'running entry: after Stop(), busy cleared, runspace closed' ((-not $s.busy) -and $s.count -eq 0 -and $liveRs.RunspaceStateInfo.State -eq 'Closed') "busy=$($s.busy) count=$($s.count) rs=$($liveRs.RunspaceStateInfo.State)"
}
finally {
    # never leave a runspace behind
    try { if ($live.InvocationStateInfo.State -eq 'Running') { $live.Stop() } } catch { }
    try { $live.Dispose() } catch { }
    try { if ($null -ne $liveRs) { $liveRs.Dispose() } } catch { }
    foreach ($e in @(& $mod { $script:TcUiaAbandonedScans.ToArray() })) { try { $e.PowerShell.Dispose() } catch { }; try { $e.Runspace.Dispose() } catch { } }
    & $mod { $script:TcUiaAbandonedScans = [System.Collections.Generic.List[object]]::new(); $script:TcErrorListScanBusy = $false }
}

& $mod { $script:TcDte = $null; $script:TcIdeConnected = $false; $script:TcIdeProcessId = $null }
"failed: $fail"
exit [Math]::Min($fail, 255)
