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
# content. #127 round 2: a pending write never overwrites a record another process wrote later
# (writtenAt), and one Find syncs once. Get-Process / Find-TcIdeModalDialog / Get-TcSysManager are replaced inside the module
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
    function script:Find-TcIdeModalDialog { [CmdletBinding()] param([int]$ProcessId = 0, [int]$TimeoutSec = 5, [int]$PrepareTimeoutSec = 0) $null }
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

    # 8. #127 round 2: a pending write never overwrites a record another PROCESS wrote later
    $start1231 = [string](@(& $mod { Read-TcIdeSolutionRecords }) | Where-Object { [int]$_.pid -eq 1231 } | Select-Object -First 1).startTime
    $slnD = Join-Path $tmpRoot 'D\Demo.sln'
    # another powershell.exe writes the record file (writtenAt = its own "now" unless -NoWrittenAt)
    function Write-RecordByOtherProcess([string]$Solution, [switch]$NoWrittenAt) {
        $js = @"
`$rec = [ordered]@{ pid = 1231; startTime = '$start1231'; solution = '$Solution' }
if (-not `$$([bool]$NoWrittenAt)) { `$rec.writtenAt = (Get-Date).ToUniversalTime().ToString('o') }
[IO.File]::WriteAllText('$recFile', (ConvertTo-Json -InputObject @([PSCustomObject]`$rec) -Depth 3))
"@
        $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($js))
        $w = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $enc) -WindowStyle Hidden -PassThru
        $null = $w.WaitForExit(60000); $w.Dispose()
    }
    function Fail-Write([scriptblock]$Write) {
        $fs = New-Object IO.FileStream($recFile, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { & $mod $Write } finally { $fs.Dispose() }
    }
    # 8a. pending save D, then another process writes C (newer): the lookup keeps C, trusts it
    Fail-Write ([scriptblock]::Create("Save-TcIdeSolutionRecord -ProcessId 1231 -Solution '$slnD'"))
    $pendingBefore = $null -ne (Get-Warn 1231)
    Start-Sleep -Milliseconds 50   # the other process' clock reading is later than the pending one
    Write-RecordByOtherProcess $slnC
    $rec = Get-Rec 1231
    Check 'pending-save-older-than-other-process-not-written' ($pendingBefore -and $rec -eq $slnC -and (Get-FileSolution 1231) -eq $slnC -and $null -eq (Get-Warn 1231)) "pending=$pendingBefore record=$rec file=$(Get-FileSolution 1231)"
    # 8b. pending remove, then another process writes B (newer): the lookup does not delete it
    Fail-Write { Remove-TcIdeSolutionRecord -ProcessId 1231 }
    $pendingBefore = $null -ne (Get-Warn 1231)
    Start-Sleep -Milliseconds 50
    Write-RecordByOtherProcess $slnB
    $rec = Get-Rec 1231
    Check 'pending-remove-older-than-other-process-not-done' ($pendingBefore -and $rec -eq $slnB -and (Get-FileSolution 1231) -eq $slnB -and $null -eq (Get-Warn 1231)) "pending=$pendingBefore record=$rec file=$(Get-FileSolution 1231)"
    # 8c. a record without writtenAt (older module version) naming ANOTHER solution: conservative,
    #     the pending D is not written and the record stays untrusted (round 3 minor A)
    Fail-Write ([scriptblock]::Create("Save-TcIdeSolutionRecord -ProcessId 1231 -Solution '$slnD'"))
    Write-RecordByOtherProcess $slnC -NoWrittenAt
    $rec = Get-Rec 1231
    Check 'pending-save-over-legacy-other-solution-not-written' ($null -eq $rec -and (Get-FileSolution 1231) -eq $slnC -and (Get-Warn 1231) -match 'not updated') "record=$rec file=$(Get-FileSolution 1231) warn=$(Get-Warn 1231)"
    #     the same solution without writtenAt: the pending D is written (with writtenAt), trusted
    Write-RecordByOtherProcess $slnD -NoWrittenAt
    $rec = Get-Rec 1231
    $wa = [string](@(& $mod { Read-TcIdeSolutionRecords }) | Where-Object { [int]$_.pid -eq 1231 } | Select-Object -First 1).writtenAt
    Check 'pending-save-over-legacy-same-solution-written' ($rec -eq $slnD -and (Get-FileSolution 1231) -eq $slnD -and $null -eq (Get-Warn 1231) -and -not [string]::IsNullOrWhiteSpace($wa)) "record=$rec file=$(Get-FileSolution 1231) writtenAt=$wa"
    # 8d. reason = first failure, retries counted (lock held by the holder process again)
    $hold2 = "tcauto-unit-123-{0}" -f [guid]::NewGuid().ToString('N')
    $rel2 = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "$hold2-release")
    $held2 = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "$hold2-held")
    Fail-Write ([scriptblock]::Create("Save-TcIdeSolutionRecord -ProcessId 1231 -Solution '$slnB'"))   # first failure: file unreadable (lock free)
    $hs = $holderScript.Replace($evName, $hold2)
    $holder2 = Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($hs))) -WindowStyle Hidden -PassThru
    try {
        $null = $held2.WaitOne(30000)
        $null = Get-Rec 1231; $null = Get-Rec 1231   # two retries, lock held: skipped
        $w = Get-Warn 1231
        Check 'pending-first-reason-and-retries' ($w -match 'not read' -and $w -notmatch 'lock not acquired' -and $w -match 'retries so far: 2') "$w"
        # 2 (minor): one Find with two candidates syncs once (loop uses Get-TcIdeSolutionRecord -NoSync)
        $syncs = & $mod {
            $orig = ${function:Sync-TcIdeSolutionRecordPending}
            $script:UnitSyncCount = 0
            Set-Item -Path function:script:Sync-TcIdeSolutionRecordPending -Value { param([int]$TimeoutMs) $script:UnitSyncCount++ }
            try { $null = Find-TcBlockedSolutionIde -Candidates @([PSCustomObject]@{ pid = 1231; busy = $true }, [PSCustomObject]@{ pid = 1232; busy = $true }) -SolutionPath 'C:\x\Demo.sln' -DialogTimeoutSec 1 }
            finally { Set-Item -Path function:script:Sync-TcIdeSolutionRecordPending -Value $orig }
            $script:UnitSyncCount
        }
        Check 'find-syncs-once' ($syncs -eq 1) "syncs=$syncs"
        # nit D: save -> remove pending: reason and retries start over
        & $mod { Remove-TcIdeSolutionRecord -ProcessId 1231 }
        $w = Get-Warn 1231
        Check 'pending-action-change-resets-reason' ($w -match 'remove skipped' -and $w -match 'retries so far: 0') "$w"
    }
    finally {
        $null = $rel2.Set(); if (-not $holder2.WaitForExit(15000)) { $holder2.Kill() }; $holder2.Dispose(); $rel2.Dispose(); $held2.Dispose()
    }
    $null = Get-Rec 1231   # lock free: the pending remove is done
    Check 'pending-written-after-second-release' ((Get-FileSolution 1231) -eq '' -and $null -eq (Get-Warn 1231)) "file=$(Get-FileSolution 1231)"
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
