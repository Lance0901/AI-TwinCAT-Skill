# Unit: ide-solutions.json read-modify-write is serialized and atomic (issue #51), no IDE needed.
# $env:LOCALAPPDATA points at a temp folder. Two runspaces (own module instance each, same named
# mutex) write / remove records at the same time; a third checks that a held mutex makes Save skip
# (verbose, no throw) instead of waiting forever. Records only survive for a live pid, so a pid
# missing at the end is excused only when that process has exited meanwhile.
# $env:TCAUTO_UNIT_MODULE overrides the module path (used to run this against the unfixed code).
#   powershell.exe -NoProfile -File tests/Unit/ide-solutions-lock.ps1
# Exit code = number of failed checks.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'lib\UnitIsolation.ps1') -Caller $PSCommandPath -CallerArgs $PSBoundParameters; if ($null -ne $TcUnitChildExit) { exit $TcUnitChildExit }   # #118: own TCAUTO_STATE_DIR, never the real state
$modulePath = if ($env:TCAUTO_UNIT_MODULE) { $env:TCAUTO_UNIT_MODULE } else { Join-Path $PSScriptRoot '..\..\src\TwinCATAutomation\TwinCATAutomation.psm1' }
$origLocalAppData = $env:LOCALAPPDATA
$tmpRoot = Join-Path $env:TEMP ("tcauto-unit-idesol-{0}" -f [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $tmpRoot -Force
$env:LOCALAPPDATA = $tmpRoot            # module versions before #118 (TCAUTO_UNIT_MODULE) keep the records here
$origStateDir = $env:TCAUTO_STATE_DIR
$env:TCAUTO_STATE_DIR = $tmpRoot         # #118: records + mutex name follow TCAUTO_STATE_DIR
Import-Module $modulePath -Force -WarningAction SilentlyContinue
$mod = Get-Module TwinCATAutomation
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail) {
    "{0} {1} {2}" -f $(if ($Ok) { 'PASS' } else { 'FAIL' }), $Name, $Detail
    if (-not $Ok) { $script:fail++ }
}
function Read-Pids { @(& $mod { Read-TcIdeSolutionRecords } | ForEach-Object { [int]$_.pid }) }

# Starts a runspace running -Script with -ArgumentList; returns @{ PS; Handle; Runspace }.
function Start-Worker([scriptblock]$Script, [object[]]$ArgumentList) {
    $rs = [runspacefactory]::CreateRunspace()
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    $null = $ps.AddScript($Script.ToString())
    foreach ($a in $ArgumentList) { $null = $ps.AddArgument($a) }
    @{ PS = $ps; Handle = $ps.BeginInvoke(); Runspace = $rs }
}
function Stop-Worker($W) {
    try { $msgs = @($W.PS.EndInvoke($W.Handle) | ForEach-Object { "$_" }) } catch { $msgs = @() }
    foreach ($m in ($msgs | Select-Object -First 3)) { "  worker: $m" }
    foreach ($e in @($W.PS.Streams.Error | Select-Object -First 3)) { "  worker error: $e" }
    $W.PS.Dispose(); $W.Runspace.Dispose()
}
function Wait-Workers($Ws, [int]$Sec = 120) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    foreach ($w in $Ws) {
        while (-not $w.Handle.IsCompleted -and $sw.Elapsed.TotalSeconds -lt $Sec) { Start-Sleep -Milliseconds 50 }
    }
    @($Ws | Where-Object { -not $_.Handle.IsCompleted }).Count -eq 0
}

# Both workers: import their own module copy, wait for the go signal, then run $Action.
$workerScript = {
    param($ModulePath, $GoName, $Action, $Pids)
    Import-Module $ModulePath -Force -WarningAction SilentlyContinue
    $m = Get-Module TwinCATAutomation
    $go = [Threading.EventWaitHandle]::OpenExisting($GoName)
    $null = $go.WaitOne(60000)
    foreach ($id in $Pids) {
        # verbose lines (skipped / failed writes) are returned for diagnosis
        if ($Action -eq 'save') { & $m { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution "C:\x\$i.sln" -Verbose 4>&1 } $id }
        else { & $m { param($i) Remove-TcIdeSolutionRecord -ProcessId $i -Verbose 4>&1 } $id }
    }
}

try {
    # Records are kept only for a live pid, so the test spawns its own child processes (idle ping.exe,
    # stopped in the finally block) instead of borrowing system processes whose StartTime is
    # unreadable or unstable.
    $need = 44
    $children = New-Object System.Collections.ArrayList
    for ($n = 0; $n -lt $need; $n++) {
        $psi = New-Object Diagnostics.ProcessStartInfo('ping.exe', '-n 300 127.0.0.1')
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
        $psi.RedirectStandardOutput = $true
        $null = $children.Add([Diagnostics.Process]::Start($psi))
    }
    $live = @($children | ForEach-Object { $_.Id })
    if ($live.Count -ne $need) { Check 'precondition' $false "only $($live.Count) of $need child processes started"; exit 1 }
    $setA = $live[0..14]; $setB = $live[15..29]          # concurrent Save of two sets of 15
    $setC = $live[30..35]; $setD = $live[36..39]         # C pre-seeded, removed while D is saved

    function Missing-Alive([int[]]$Expected, [int[]]$Have) {
        # pids that are absent although their process is still running = lost records
        @($Expected | Where-Object { $Have -notcontains $_ -and (Get-Process -Id $_ -ErrorAction SilentlyContinue) })
    }

    # 1. two runspaces save 50 different pids each at the same time
    $goName = "tcauto-go-{0}" -f [guid]::NewGuid().ToString('N')
    $go = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $goName)
    $w1 = Start-Worker $workerScript @($modulePath, $goName, 'save', $setA)
    $w2 = Start-Worker $workerScript @($modulePath, $goName, 'save', $setB)
    Start-Sleep -Milliseconds 1500   # both modules imported and waiting on $go
    $null = $go.Set()
    $done = Wait-Workers @($w1, $w2)
    Stop-Worker $w1; Stop-Worker $w2; $go.Dispose()
    $have = Read-Pids
    $lost = Missing-Alive ($setA + $setB) $have
    Check 'workers-finished' $done ''
    Check 'concurrent-save-keeps-all' ($lost.Count -eq 0) "records=$($have.Count) of 30 (lost while process alive: $($lost.Count))"

    # 2. Remove (set C, pre-seeded) races with Save (set D); unrelated records must survive
    foreach ($id in $setC) { & $mod { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution "C:\c\$i.sln" } $id }
    $goName = "tcauto-go-{0}" -f [guid]::NewGuid().ToString('N')
    $go = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $goName)
    $w1 = Start-Worker $workerScript @($modulePath, $goName, 'remove', $setC)
    $w2 = Start-Worker $workerScript @($modulePath, $goName, 'save', $setD)
    Start-Sleep -Milliseconds 1500
    $null = $go.Set()
    $done = Wait-Workers @($w1, $w2)
    Stop-Worker $w1; Stop-Worker $w2; $go.Dispose()
    $have = Read-Pids
    $lostD = Missing-Alive $setD $have
    $lostA = Missing-Alive ($setA + $setB) $have
    $leftC = @($setC | Where-Object { $have -contains $_ })
    Check 'remove-vs-save-keeps-others' ($done -and $lostD.Count -eq 0 -and $lostA.Count -eq 0) "saved set lost=$($lostD.Count), earlier records lost=$($lostA.Count)"
    Check 'remove-removed' ($leftC.Count -eq 0) "removed pids still present: $($leftC.Count)"

    # 3. no .tmp left behind, file is valid JSON
    $dir = Split-Path -Parent (& $mod { Get-TcIdeSolutionRecordPath })
    $tmps = @(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -ErrorAction SilentlyContinue)
    Check 'no-tmp-left' ($tmps.Count -eq 0) "tmp files: $($tmps.Count)"

    # 4a. #118: the lock name of a TCAUTO_STATE_DIR run is its own, never the global name a real
    #     TcAuto session (or another test run) holds; the record file is in TCAUTO_STATE_DIR
    $lockName = & $mod { if (Get-Command Get-TcIdeSolutionLockName -ErrorAction SilentlyContinue) { Get-TcIdeSolutionLockName } else { $script:TcIdeSolutionLockName } }
    $globalName = & $mod { $script:TcIdeSolutionLockName }
    if (-not $env:TCAUTO_UNIT_MODULE) {
        Check 'lock-name-per-state-dir' ($lockName -ne $globalName -and $lockName -match '^Local\\TwinCATAutomation-ide-solutions\.[0-9a-f]{16}$') "$lockName"
        $recPath = & $mod { Get-TcIdeSolutionRecordPath }
        Check 'record-file-in-state-dir' ([string]::Equals((Split-Path -Parent $recPath).TrimEnd('\'), $tmpRoot.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) "$recPath"
    }

    # 4. mutex held by another holder longer than the wait limit: Save skips, writes verbose, no throw
    $holdName = "tcauto-hold-{0}" -f [guid]::NewGuid().ToString('N')
    $hold = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, $holdName)
    $held = New-Object Threading.EventWaitHandle($false, [Threading.EventResetMode]::ManualReset, "$holdName-held")
    $holder = Start-Worker {
        param($Name, $Release, $Held)
        $r = [Threading.EventWaitHandle]::OpenExisting($Release); $h = [Threading.EventWaitHandle]::OpenExisting($Held)
        $m = New-Object Threading.Mutex($false, $Name)
        $null = $m.WaitOne(); $null = $h.Set()
        $null = $r.WaitOne(30000)
        $m.ReleaseMutex(); $m.Dispose()
    } @($lockName, $holdName, "$holdName-held")
    $null = $held.WaitOne(10000)
    $before = Read-Pids
    $probe = $live[40]
    $threw = $false; $sw = [Diagnostics.Stopwatch]::StartNew()
    try { $out = & $mod { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution 'C:\held.sln' -Verbose 4>&1 } $probe }
    catch { $threw = $true; $out = @() }
    $sw.Stop()
    $verbose = @($out | Where-Object { $_ -is [Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
    $after = Read-Pids
    Check 'held-mutex-no-throw' (-not $threw) ''
    Check 'held-mutex-skipped' ($after -notcontains $probe -and $after.Count -eq $before.Count) "records $($before.Count) -> $($after.Count)"
    Check 'held-mutex-waited-then-gave-up' ($sw.ElapsedMilliseconds -ge 1500 -and $sw.ElapsedMilliseconds -lt 30000) "$($sw.ElapsedMilliseconds) ms"
    Check 'held-mutex-verbose' (@($verbose | Where-Object { $_ -match 'skipped' }).Count -eq 1) ($verbose -join ' | ')
    $null = $hold.Set(); Stop-Worker $holder; $hold.Dispose(); $held.Dispose()
    # once released, Save works again
    & $mod { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution 'C:\held.sln' } $probe
    Check 'save-after-release' ((Read-Pids) -contains $probe) ''

    # 5. file exists but cannot be read (held open without sharing): no write, content unchanged
    $file = & $mod { Get-TcIdeSolutionRecordPath }
    $origText = [IO.File]::ReadAllText($file)
    $p2 = $live[41]
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try {
        $threw = $false
        try { $out = & $mod { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution 'C:\locked.sln' -Verbose 4>&1 } $p2 }
        catch { $threw = $true; $out = @() }
    }
    finally { $fs.Dispose() }
    $verbose = @($out | Where-Object { $_ -is [Management.Automation.VerboseRecord] } | ForEach-Object { $_.Message })
    Check 'unreadable-no-throw' (-not $threw) ''
    Check 'unreadable-content-unchanged' ([IO.File]::ReadAllText($file) -ceq $origText) ''
    Check 'unreadable-verbose' (@($verbose | Where-Object { $_ -match 'not read|unreadable' }).Count -ge 1) ($verbose -join ' | ')
    Check 'unreadable-no-tmp' (@(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -ErrorAction SilentlyContinue).Count -eq 0) ''

    # 6. Replace target held open by a reader: short retries, still failing -> no throw, tmp removed
    $fs = New-Object IO.FileStream($file, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $threw = $false
        try { $out = & $mod { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution 'C:\replace.sln' -Verbose 4>&1 } $p2 }
        catch { $threw = $true; $out = @() }
    }
    finally { $fs.Dispose() }
    Check 'replace-blocked-no-throw' (-not $threw) ''
    Check 'replace-blocked-no-tmp' (@(Get-ChildItem -LiteralPath $dir -Filter '*.tmp' -ErrorAction SilentlyContinue).Count -eq 0) ''
    Check 'replace-blocked-content-unchanged' ([IO.File]::ReadAllText($file) -ceq $origText) ''

    # 7. corrupt JSON: old file kept as .corrupt-<time>, new file holds only the new record
    [IO.File]::WriteAllText($file, '[ { "pid": 1, "startTi')
    & $mod { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution 'C:\fresh.sln' } $p2
    $kept = @(Get-ChildItem -LiteralPath $dir -Filter 'ide-solutions.json.corrupt-*' -ErrorAction SilentlyContinue)
    $now = @(Read-Pids)
    Check 'corrupt-renamed' ($kept.Count -eq 1 -and [IO.File]::ReadAllText($kept[0].FullName) -ceq '[ { "pid": 1, "startTi') "kept files: $($kept.Count)"
    Check 'corrupt-new-file-only-new-record' ($now.Count -eq 1 -and $now[0] -eq $p2) "records: $($now -join ',')"

    # 8. missing file is a normal empty list
    Remove-Item -LiteralPath $file -Force
    & $mod { param($i) Save-TcIdeSolutionRecord -ProcessId $i -Solution 'C:\new.sln' } $live[42]
    Check 'missing-file-written' ((Read-Pids) -contains $live[42]) ''
}
finally {
    foreach ($c in $children) { try { if (-not $c.HasExited) { $c.Kill() } } catch { }; try { $c.Dispose() } catch { } }
    $env:LOCALAPPDATA = $origLocalAppData
    $env:TCAUTO_STATE_DIR = $origStateDir
    Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
}
exit $fail
