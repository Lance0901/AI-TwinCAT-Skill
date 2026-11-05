# Unit: a skipped ide-solutions.json write is not silent (issue #123), no IDE needed.
# Another PROCESS (powershell.exe child) holds the ide-solutions mutex of this test's own
# TCAUTO_STATE_DIR (name from Get-TcIdeSolutionLockName) longer than the 2 s wait limit. Save /
# Remove then skip the write as before, but the old record of that IDE process must no longer be
# used: Get-TcIdeSolutionRecord returns $null, Find-TcBlockedSolutionIde makes the match weak
# (contradiction = the warning) and Open-TcProject reports data.sessionRecordWarning. Once a write
# succeeds again, the record counts again. A write that fails INSIDE the lock (file unreadable,
# Replace blocked by a reader) marks the record untrusted the same way. #127 F1: the write that
# could not be done is kept as PENDING (what this module meant to write, never the old file
# record) and the next lookup (Find-TcBlockedSolutionIde / Get-TcIdeSolutionRecord) writes it
# once the lock is free, so a blocked IDE (no new Save ever) is recognised again by the pending
# content. Get-Process / Find-TcIdeModalDialog / Get-TcSysManager are replaced inside the module
# scope (fake pids), as in blocked-solution-ide.ps1.
#   powershell.exe -NoProfile -File tests/Unit/ide-solution-record-untrusted.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$tmpRoot = Join-Path $env:TEMP ("tcauto-unit-123-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force
$origStateDir = $env:TCAUTO_STATE_DIR
$env:TCAUTO_STATE_DIR = Join-Path $tmpRoot 'state'   # records + mutex name follow it (#118)
$null = New-Item -ItemType Directory -Path $env:TCAUTO_STATE_DIR -Force
Import-Module (Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1') -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}

# Two copies of the same-named solution: the IDE switched from A\Demo.sln to B\Demo.sln, so the
# window title 'Demo - TcXaeShell' fits both (the case where a stale record looks corroborated).
$slnA = Join-Path $tmpRoot 'A\Demo.sln'; $slnB = Join-Path $tmpRoot 'B\Demo.sln'
foreach ($s in $slnA, $slnB) { $null = New-Item -ItemType Directory -Path (Split-Path -Parent $s) -Force; Set-Content -LiteralPath $s -Value 'Microsoft Visual Studio Solution File, Format Version 12.00' }
$slnA = & $mod { param($p) Get-TcLongPath $p } $slnA
$slnB = & $mod { param($p) Get-TcLongPath $p } $slnB

$global:FakeIde123 = @{ 1231 = 'Demo - TcXaeShell'; 1232 = 'Other - TcXaeShell' }
& $mod {
    function script:Get-Process {
        [CmdletBinding()] param([int]$Id)
        if ($global:FakeIde123.ContainsKey($Id)) { return [PSCustomObject]@{ Id = $Id; MainWindowTitle = $global:FakeIde123[$Id]; MainWindowHandle = [IntPtr]::Zero; StartTime = [DateTime]'2026-01-01T00:00:00' } }
        Microsoft.PowerShell.Management\Get-Process @PSBoundParameters
    }
    function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5) $null }
    function script:Get-TcSysManager { [CmdletBinding()] param([switch]$Refresh) $null }
}
function Get-Rec([int]$Id) { & $mod { param($i) Get-TcIdeSolutionRecord -ProcessId $i } $Id }
function Get-Warn([int]$Id) { & $mod { param($i) Get-TcIdeSolutionRecordWarning -ProcessId $i } $Id }
function Get-FileSolution([int]$Id) { @(& $mod { Read-TcIdeSolutionRecords } | Where-Object { [int]$_.pid -eq $Id } | ForEach-Object { [string]$_.solution }) -join ',' }
function Find-Hit([string]$Sln) {
    @(& $mod { param($s) Find-TcBlockedSolutionIde -Candidates @([PSCustomObject]@{ pid = 1231; progId = 'Fake.DTE.1'; busy = $true }) -SolutionPath $s -DialogTimeoutSec 1 } $Sln)
}

$holder = $null; $release = $null; $held = $null
try {
    # 1. lock free: the record of A is written and is strong evidence for A
    & $mod { param($a) Save-TcIdeSolutionRecord -ProcessId 1231 -Solution $a; Save-TcIdeSolutionRecord -ProcessId 1232 -Solution 'C:\Elsewhere\Other.sln' } $slnA
    Check 'seed-record' ((Get-Rec 1231) -eq $slnA -and $null -eq (Get-Warn 1231)) "record=$(Get-Rec 1231)"
    $h = @(Find-Hit $slnA)
    Check 'seed-find-strong' ($h.Count -eq 1 -and $h[0].Strong -and $h[0].MatchedBy -eq 'session-record') "hits=$(@($h | ForEach-Object { "$($_.MatchedBy) strong=$($_.Strong)" }) -join ',')"

    # 2. another process holds the mutex (name of THIS state dir, never the global one)
    $lockName = & $mod { Get-TcIdeSolutionLockName }
    $globalName = & $mod { $script:TcIdeSolutionLockName }
    Check 'lock-name-isolated' ($lockName -ne $globalName -and $lockName -match '^Local\\TwinCATAutomation-ide-solutions\.[0-9a-f]{16}$') $lockName
    $evName = "tcauto-unit-123-{0}" -f [guid]::NewGuid().ToString('N')
    $release = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "$evName-release")
    $held = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "$evName-held")
    $holderScript = @"
`$m = New-Object Threading.Mutex(`$false, '$lockName')
`$null = `$m.WaitOne()
([Threading.EventWaitHandle]::OpenExisting('$evName-held')).Set() | Out-Null
`$null = ([Threading.EventWaitHandle]::OpenExisting('$evName-release')).WaitOne(120000)
`$m.ReleaseMutex(); `$m.Dispose()
"@
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($holderScript))
    $holder = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) -WindowStyle Hidden -PassThru
    $gotHeld = $held.WaitOne(30000)
    Check 'holder-process-has-mutex' ($gotHeld -and $holder.Id -ne $PID) "holder pid=$($holder.Id)"

    # 3. Save while held: the write is skipped (file still says A) but NOT silently
    $threw = $false
    try { & $mod { param($b) Save-TcIdeSolutionRecord -ProcessId 1231 -Solution $b } $slnB } catch { $threw = $true }
    Check 'held-save-no-throw' (-not $threw) ''
    Check 'held-save-file-unchanged' ((Get-FileSolution 1231) -eq $slnA) "file=$(Get-FileSolution 1231)"
    Check 'held-save-record-untrusted' ($null -eq (Get-Rec 1231)) "record=$(Get-Rec 1231)"
    $w = Get-Warn 1231
    Check 'held-save-warning' ($w -match 'not updated' -and $w -match 'skipped') "$w"
    $h = @(Find-Hit $slnA)
    Check 'held-find-not-strong' ($h.Count -eq 1 -and -not $h[0].Strong -and $h[0].Contradiction -match 'not updated') "hits=$(@($h | ForEach-Object { "$($_.MatchedBy) strong=$($_.Strong) why=$($_.Contradiction)" }) -join ',')"

    # 4. Remove while held: the record that should be gone is not used either
    & $mod { param($i) Remove-TcIdeSolutionRecord -ProcessId $i } 1232
    Check 'held-remove-file-unchanged' ((Get-FileSolution 1232) -eq 'C:\Elsewhere\Other.sln') "file=$(Get-FileSolution 1232)"
    Check 'held-remove-record-untrusted' ($null -eq (Get-Rec 1232) -and (Get-Warn 1232) -match 'remove skipped') "warn=$(Get-Warn 1232)"

    # 5. Open-TcProject while held: data.sessionRecordWarning tells the caller
    & $mod {
        param($b)
        $sol = [PSCustomObject]@{ FullName = $b }
        $sol | Add-Member -MemberType ScriptMethod -Name Open -Value { param($p) }
        $script:TcDte = [PSCustomObject]@{ Solution = $sol }
        $script:TcIdeConnected = $true; $script:TcIdeProcessId = 1231
    } $slnB
    $r = Open-TcProject -Path $slnB
    Check 'open-project-warning' ($r.success -and $r.data.sessionRecordWarning -match 'not updated') "success=$($r.success) warn=$($r.data.sessionRecordWarning)"

    # 6. released (#127 F1): no new Save comes (blocked IDE); the next lookup writes the pending
    #    save (B, what this module meant to write) and the pending remove, then trusts the record
    $null = $release.Set()
    $null = $holder.WaitForExit(30000)
    Check 'released-still-pending-before-lookup' ((Get-FileSolution 1231) -eq $slnA -and $null -ne (Get-Warn 1231) -and $null -ne (Get-Warn 1232)) "file=$(Get-FileSolution 1231)"
    $h = @(Find-Hit $slnB)
    Check 'released-find-writes-pending' ((Get-FileSolution 1231) -eq $slnB -and (Get-FileSolution 1232) -eq '' -and $null -eq (Get-Warn 1231) -and $null -eq (Get-Warn 1232)) "file1231=$(Get-FileSolution 1231) file1232=$(Get-FileSolution 1232) warn=$(Get-Warn 1231)"
    Check 'released-find-strong-by-pending-content' ($h.Count -eq 1 -and $h[0].Strong -and $h[0].MatchedBy -eq 'session-record' -and $h[0].CorroboratedBy -eq 'window-title') "hits=$(@($h | ForEach-Object { "$($_.MatchedBy) strong=$($_.Strong) why=$($_.Contradiction)" }) -join ',')"
    $h = @(Find-Hit $slnA)
    Check 'released-find-old-file-record-not-used' (@($h | Where-Object { $_.Strong }).Count -eq 0) "hits=$(@($h | ForEach-Object { "$($_.MatchedBy) strong=$($_.Strong)" }) -join ',')"
    $r = Open-TcProject -Path $slnB
    Check 'released-open-no-warning' ($r.success -and $null -eq $r.data.PSObject.Properties['sessionRecordWarning']) "warn=$($r.data.sessionRecordWarning)"
    Check 'released-record-trusted' ((Get-Rec 1231) -eq $slnB -and $null -eq (Get-Warn 1231)) "record=$(Get-Rec 1231)"
    $h = @(Find-Hit $slnA)
    Check 'released-find-old-solution-not-strong' (@($h | Where-Object { $_.Strong }).Count -eq 0) "hits=$(@($h | ForEach-Object { "$($_.MatchedBy) strong=$($_.Strong)" }) -join ',')"
    & $mod { param($i) Remove-TcIdeSolutionRecord -ProcessId $i } 1232
    Check 'released-remove' ((Get-FileSolution 1232) -eq '' -and $null -eq (Get-Warn 1232)) "file=$(Get-FileSolution 1232)"

    # 7. lock taken, but the write fails inside it: the record is untrusted as well
    $recFile = & $mod { Get-TcIdeSolutionRecordPath }
    $slnC = Join-Path $tmpRoot 'C\Demo.sln'
    # 7a. file held open without sharing: the records cannot be read under the lock
    $fs = New-Object IO.FileStream($recFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try { & $mod { param($c) Save-TcIdeSolutionRecord -ProcessId 1231 -Solution $c } $slnC }
    finally { $fs.Dispose() }
    $w = Get-Warn 1231
    Check 'unreadable-in-lock-untrusted' ((Get-FileSolution 1231) -eq $slnB -and $w -match 'save failed' -and $w -match 'not read') "file=$(Get-FileSolution 1231) warn=$w"
    $rec = Get-Rec 1231   # lookup: file free again -> the pending save (C) is written first
    Check 'unreadable-pending-written-on-lookup' ($rec -eq $slnC -and (Get-FileSolution 1231) -eq $slnC -and $null -eq (Get-Warn 1231)) "record=$rec file=$(Get-FileSolution 1231)"
    & $mod { param($b) Save-TcIdeSolutionRecord -ProcessId 1231 -Solution $b } $slnB
    Check 'unreadable-then-saved-trusted' ((Get-Rec 1231) -eq $slnB -and $null -eq (Get-Warn 1231)) "record=$(Get-Rec 1231)"
    # 7b. file held open by a reader: [IO.File]::Replace keeps failing
    $fs = New-Object IO.FileStream($recFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try { & $mod { param($c) Save-TcIdeSolutionRecord -ProcessId 1231 -Solution $c } $slnC }
    finally { $fs.Dispose() }
    $w = Get-Warn 1231
    Check 'replace-blocked-untrusted' ((Get-FileSolution 1231) -eq $slnB -and $w -match 'save failed') "file=$(Get-FileSolution 1231) warn=$w"
    $rec = Get-Rec 1231
    Check 'replace-blocked-pending-written-on-lookup' ($rec -eq $slnC -and (Get-FileSolution 1231) -eq $slnC -and $null -eq (Get-Warn 1231)) "record=$rec file=$(Get-FileSolution 1231)"
    & $mod { param($b) Save-TcIdeSolutionRecord -ProcessId 1231 -Solution $b } $slnB
    Check 'replace-blocked-then-saved-trusted' ((Get-Rec 1231) -eq $slnB -and $null -eq (Get-Warn 1231)) "record=$(Get-Rec 1231)"
}
finally {
    if ($null -ne $release) { try { $null = $release.Set() } catch { } }
    if ($null -ne $holder) { try { if (-not $holder.WaitForExit(10000)) { $holder.Kill() } } catch { }; $holder.Dispose() }
    if ($null -ne $release) { $release.Dispose() }
    if ($null -ne $held) { $held.Dispose() }
    & $mod { $script:TcIdeConnected = $false; $script:TcDte = $null; $script:TcIdeProcessId = $null }
    $env:TCAUTO_STATE_DIR = $origStateDir
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit $fail
