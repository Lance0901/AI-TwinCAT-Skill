# Which solution each IDE process had open the last time Connect-TcIde connected to it with a
# solution, kept in a small JSON file shared by every PowerShell process / MCP bridge of this user:
#   $env:LOCALAPPDATA\TwinCATAutomation\ide-solutions.json
#   ($env:TCAUTO_STATE_DIR\ide-solutions.json when that test override is set, so one variable
#   isolates every state file of a test run, #118; mutex name then gets the same path hash as
#   build-required.json)
#   [ { pid; startTime ('o' format); solution; writtenAt (UTC 'o', #127: a pending write never
#     overwrites a record written later by another process; missing = older) } ]
# Connect-TcIde -SolutionPath reads it for an IDE whose DTE cannot be asked (modal dialog / busy,
# issue #29). A record only counts while the same process (pid AND start time) is still running,
# so a recycled pid never matches. Best effort: an I/O error never throws, but a skipped write
# makes the old record of that process untrusted in this module instance (#123).

function Get-TcIdeSolutionRecordPath {
    [CmdletBinding()]
    param()
    # TCAUTO_STATE_DIR (tests) -> the same folder as every other state file (Get-TcStateDir)
    if (-not [string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) { return (Join-Path (Get-TcStateDir) 'ide-solutions.json') }
    Assert-TcRealStateAllowed -What 'the IDE solution records'
    $base = $env:LOCALAPPDATA
    if ([string]::IsNullOrWhiteSpace($base)) { $base = $env:TEMP }
    Join-Path (Join-Path $base 'TwinCATAutomation') 'ide-solutions.json'
}

# Reads the record file. Returns @{ State; Records; Error } with State
#   'ok'         parsed (Records may be empty)
#   'missing'    no file (a normal empty list)
#   'unreadable' still cannot be opened after retries (sharing violation, access denied)
#   'corrupt'    opened but is not valid JSON
# [IO.File]::Replace can make a reader fail for a moment (sharing violation / file briefly
# missing): the open is retried a few times.
function Read-TcIdeSolutionRecordFile {
    [CmdletBinding()]
    param(
        # another JSON list file of the same shape (launched-ides.json, #73 / #149)
        [string]$Path
    )
    $path = if ([string]::IsNullOrWhiteSpace($Path)) { Get-TcIdeSolutionRecordPath } else { $Path }
    $text = $null; $last = $null
    for ($i = 1; $i -le 5; $i++) {
        # No Test-Path first: it says "missing" for a file held open exclusively. A file is only
        # 'missing' when the open itself says not-found.
        try { $text = [IO.File]::ReadAllText($path); $last = $null; break }
        catch {
            $ex = $_.Exception
            if ($ex.InnerException) { $ex = $ex.InnerException }
            if ($ex -is [System.IO.FileNotFoundException] -or $ex -is [System.IO.DirectoryNotFoundException]) {
                return @{ State = 'missing'; Records = @(); Error = $null }
            }
            $last = $ex.Message; Start-Sleep -Milliseconds (20 * $i)
        }
    }
    if ($null -ne $last) { return @{ State = 'unreadable'; Records = @(); Error = $last } }
    try {
        if ([string]::IsNullOrWhiteSpace($text)) { throw 'empty file' }
        # PS 5.1 ConvertFrom-Json emits a JSON array as ONE object: unroll it.
        $parsed = $text | ConvertFrom-Json -ErrorAction Stop
        @{ State = 'ok'; Records = @($parsed | ForEach-Object { $_ } | Where-Object { $null -ne $_ }); Error = $null }
    }
    catch { @{ State = 'corrupt'; Records = @(); Error = $_.Exception.Message } }
}

# Lenient read for lookups: anything unusable is an empty list.
function Read-TcIdeSolutionRecords {
    [CmdletBinding()]
    param()
    $r = Read-TcIdeSolutionRecordFile
    if ($r.State -in 'unreadable', 'corrupt') { Write-Verbose "IDE solution records $($r.State) ($($r.Error))" }
    @($r.Records)
}

# For a writer, UNDER the lock. Returns the records to build on. 'missing' = empty list. Throws
# when the file exists but cannot be read (writing would overwrite the other records). A corrupt
# file is renamed to ide-solutions.json.corrupt-<time> first, like build-required.json.
function Read-TcIdeSolutionRecordsForWrite {
    [CmdletBinding()]
    param(
        # Remove: a corrupt file has no record to remove, so it is left as it is (the next Save moves it aside).
        [switch]$LeaveCorrupt
    )
    $r = Read-TcIdeSolutionRecordFile
    switch ($r.State) {
        'unreadable' { throw "records not read, nothing written ($($r.Error))" }
        'corrupt' {
            if ($LeaveCorrupt) { return @() }
            $path = Get-TcIdeSolutionRecordPath
            $kept = "$path.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))"
            try { [IO.File]::Move($path, $kept) }
            catch { throw "corrupt records not moved aside, nothing written ($($_.Exception.Message))" }
            Write-Verbose "IDE solution records corrupt ($($r.Error)); kept as $kept"
            return @()
        }
        default { return @($r.Records) }
    }
}

# Named mutex + wait limit for the read-modify-write of ide-solutions.json (#51).
# With TCAUTO_STATE_DIR set the name gets the hash of that directory (Get-TcBuildRequiredMutexName),
# so a test run never shares the lock with a real TcAuto session or another test run (#118:
# blocked-solution-ide.ps1 / ide-solutions-lock.ps1 lost a record when another process held the
# one global name longer than the 2 s wait limit).
$script:TcIdeSolutionLockName = 'Local\TwinCATAutomation-ide-solutions'
$script:TcIdeSolutionLockTimeoutMs = 2000

function Get-TcIdeSolutionLockName {
    if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) { return $script:TcIdeSolutionLockName }
    # 'Local\TwinCATAutomation.BuildRequired.<hash>' -> 'Local\TwinCATAutomation-ide-solutions.<hash>'
    "$($script:TcIdeSolutionLockName).$(((Get-TcBuildRequiredMutexName) -split '\.')[-1])"
}

# Runs -Body under the ide-solutions mutex (same helper as build-required.json). Returns $null
# when it ran without error; otherwise the reason (string) and a verbose line. Never throws.
function Invoke-TcIdeSolutionLocked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$What = 'IDE solution record', [int]$TimeoutMs = $script:TcIdeSolutionLockTimeoutMs)
    $r = Invoke-TcBuildRequiredLocked -Body $Body -MutexName (Get-TcIdeSolutionLockName) -TimeoutMs $TimeoutMs
    if (-not $r.Locked) { $msg = "$What skipped ($($r.Error))"; Write-Verbose $msg; return $msg }
    if ($r.Error) { $msg = "$What failed ($($r.Error))"; Write-Verbose $msg; return $msg }
    $null
}

# --- #123: a write that could not be done is kept as PENDING; until then the record is untrusted ---
# A skipped / failed Save or Remove leaves the previous record of that IDE process in the file
# (e.g. the solution before Open-TcProject). The write this module instance WANTED to do is kept
# in $script:TcIdeSolutionRecordPending (key pid|start time, Get-TcIdeProcessKey): only what this
# process meant to write, never a record read from the file. While it is pending, this module
# instance does not use the file record of that process (Get-TcIdeSolutionRecord returns $null,
# Find-TcBlockedSolutionIde makes every match of it weak) and the cmdlet that wrote it reports
# data.sessionRecordWarning. Sync-TcIdeSolutionRecordPending (start of Get-TcIdeSolutionRecord,
# Find-TcBlockedSolutionIde and Connect-TcIde) tries the lock again (short wait) and writes the
# pending record / removal; then the record is trusted again (#127 F1: an IDE blocked by a modal
# dialog never gets a new Save, so waiting for one would never end).
# Per module instance: another PowerShell process / MCP bridge still sees the old file record.
$script:TcIdeSolutionPendingRetryMs = 250

# Is the record's writtenAt later than -Than (both 'o' strings)? A record without writtenAt (the
# format before #127 round 2) or an unparsable one counts as older. writtenAt is wall-clock time:
# a clock that jumps back can make this comparison wrong (known limit).
function Test-TcIdeRecordNewer {
    [CmdletBinding()]
    param([AllowNull()][object]$Record, [string]$Than)
    if ($null -eq $Record -or [string]::IsNullOrWhiteSpace($Than)) { return $false }
    $w = $Record.PSObject.Properties['writtenAt']
    if ($null -eq $w -or $null -eq $w.Value -or [string]::IsNullOrWhiteSpace([string]$w.Value)) { return $false }
    try {
        $rs = [Globalization.DateTimeStyles]::RoundtripKind
        $recAt = if ($w.Value -is [DateTime]) { [DateTime]$w.Value } else { [DateTime]::Parse([string]$w.Value, [Globalization.CultureInfo]::InvariantCulture, $rs) }
        $thanAt = [DateTime]::Parse($Than, [Globalization.CultureInfo]::InvariantCulture, $rs)
        return ($recAt.ToUniversalTime() -gt $thanAt.ToUniversalTime())
    }
    catch { return $false }
}

# Does the write. -Action save: the record { pid; startTime; solution; writtenAt } replaces the one
# of -ProcessId; remove: the record of -ProcessId is dropped. -WrittenAt = when the write was
# wanted (UTC 'o'). -IfNotSuperseded (pending writes): when the file record of -ProcessId was
# written LATER than -WrittenAt (another process wrote a newer one, #127 round 2), nothing is
# written and $Superseded.Value is set. Returns $null or the failure reason.
function Invoke-TcIdeSolutionRecordWrite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('save', 'remove')][string]$Action,
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$StartTime, [string]$Solution,
        [string]$WrittenAt = (Get-Date).ToUniversalTime().ToString('o'),
        [switch]$IfNotSuperseded,
        [ref]$Superseded,
        [int]$TimeoutMs = $script:TcIdeSolutionLockTimeoutMs
    )
    $state = @{ superseded = $false }
    try {
        $alive = @{}
        foreach ($r in @(Read-TcIdeSolutionRecords)) { $null = Test-TcIdeRecordAlive -Record $r -Cache $alive }   # outside the lock
        if ($Action -eq 'save') {
            $failure = Invoke-TcIdeSolutionLocked -What 'IDE solution record save' -TimeoutMs $TimeoutMs -Body {
                $all = @(Read-TcIdeSolutionRecordsForWrite)
                if ($IfNotSuperseded) {
                    $mine = @($all | Where-Object { [int]$_.pid -eq $ProcessId })
                    if (@($mine | Where-Object { Test-TcIdeRecordNewer -Record $_ -Than $WrittenAt }).Count -gt 0) { $state.superseded = $true; return }
                    # conservative (#127 round 3 minor A): a record without writtenAt (older module
                    # version, maybe written AFTER our failed write) naming another solution is not
                    # overwritten; the record stays untrusted until a new Save of this module succeeds
                    $legacyOther = @($mine | Where-Object { $null -eq $_.PSObject.Properties['writtenAt'] -or [string]::IsNullOrWhiteSpace([string]$_.writtenAt) } | Where-Object { -not [string]::Equals([string]$_.solution, $Solution, [StringComparison]::OrdinalIgnoreCase) })
                    if ($legacyOther.Count -gt 0) { throw "the file record of pid $ProcessId has no writtenAt (older module version) and names another solution ('$($legacyOther[0].solution)'); pending save not written" }
                }
                $keep = @($all | Where-Object { [int]$_.pid -ne $ProcessId -and (Test-TcIdeRecordAlive -Record $_ -Cache $alive) })
                $keep += [PSCustomObject]@{ pid = $ProcessId; startTime = $StartTime; solution = $Solution; writtenAt = $WrittenAt }
                Write-TcIdeSolutionRecords -Records $keep
            }
        }
        else {
            $failure = Invoke-TcIdeSolutionLocked -What 'IDE solution record remove' -TimeoutMs $TimeoutMs -Body {
                $all = @(Read-TcIdeSolutionRecordsForWrite -LeaveCorrupt)
                $mine = @($all | Where-Object { [int]$_.pid -eq $ProcessId })
                if (-not $mine) { return }
                if ($IfNotSuperseded -and @($mine | Where-Object { Test-TcIdeRecordNewer -Record $_ -Than $WrittenAt }).Count -gt 0) { $state.superseded = $true; return }
                Write-TcIdeSolutionRecords -Records @($all | Where-Object { [int]$_.pid -ne $ProcessId -and (Test-TcIdeRecordAlive -Record $_ -Cache $alive) })
            }
        }
    }
    catch { $failure = "IDE solution record $Action failed ($($_.Exception.Message))"; Write-Verbose $failure }
    if ($null -ne $Superseded) { $Superseded.Value = [bool]$state.superseded }
    $failure
}

# -Failure $null: the write is done, nothing pending. Otherwise the write is kept as pending
# { action; pid; startTime; solution; at (= writtenAt it was meant to have); reason (the FIRST
# failure while pending); retries }.
function Set-TcIdeSolutionRecordPending {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [AllowNull()][string]$Failure,
        [string]$Action = 'save', [string]$StartTime, [string]$Solution, [string]$At
    )
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return }   # process gone: its record no longer counts anyway
    if ($null -eq $script:TcIdeSolutionRecordPending) { $script:TcIdeSolutionRecordPending = @{} }
    if ([string]::IsNullOrWhiteSpace($Failure)) { $script:TcIdeSolutionRecordPending.Remove($key); return }
    $old = $script:TcIdeSolutionRecordPending[$key]
    # the first failure is kept while the SAME action stays pending; save <-> remove starts over
    $same = ($null -ne $old -and $old.action -eq $Action)
    $reason = if ($same) { $old.reason } else { $Failure }
    $retries = if ($same) { [int]$old.retries } else { 0 }
    $script:TcIdeSolutionRecordPending[$key] = [PSCustomObject]@{ action = $Action; pid = $ProcessId; startTime = $StartTime; solution = $Solution; at = $At; reason = $reason; retries = $retries }
}

# Retries every pending write once (short lock wait). Done -> trusted again; the file record of
# that process is newer than the pending write (another process wrote it later) -> the pending
# write is dropped unwritten and the record is trusted; still not possible -> stays pending
# (retries + 1, reason = the first failure). A pending entry of a process that is gone (or
# restarted) is dropped. Never throws.
function Sync-TcIdeSolutionRecordPending {
    [CmdletBinding()]
    param([int]$TimeoutMs = $script:TcIdeSolutionPendingRetryMs)
    if ($null -eq $script:TcIdeSolutionRecordPending -or $script:TcIdeSolutionRecordPending.Count -eq 0) { return }
    foreach ($key in @($script:TcIdeSolutionRecordPending.Keys)) {
        $p = $script:TcIdeSolutionRecordPending[$key]
        try {
            if ((Get-TcIdeProcessKey -ProcessId ([int]$p.pid)) -ne $key) { $script:TcIdeSolutionRecordPending.Remove($key); continue }
            $sup = $false
            $failure = Invoke-TcIdeSolutionRecordWrite -Action $p.action -ProcessId ([int]$p.pid) -StartTime $p.startTime -Solution $p.solution -WrittenAt $p.at -IfNotSuperseded -Superseded ([ref]$sup) -TimeoutMs $TimeoutMs
            if ($null -eq $failure) {
                $script:TcIdeSolutionRecordPending.Remove($key)
                Write-Verbose $(if ($sup) { "IDE solution record of pid $($p.pid): pending $($p.action) dropped, the file has a newer record" } else { "IDE solution record of pid $($p.pid): pending $($p.action) written" })
            }
            else { $p.retries = [int]$p.retries + 1 }
        }
        catch { Write-Verbose "IDE solution record pending $($p.action) not written ($($_.Exception.Message))" }
    }
}

# The reason the record of process -ProcessId is not trusted (a write is pending), or $null.
function Get-TcIdeSolutionRecordWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($null -eq $script:TcIdeSolutionRecordPending -or $script:TcIdeSolutionRecordPending.Count -eq 0) { return $null }
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key -or -not $script:TcIdeSolutionRecordPending.ContainsKey($key)) { return $null }
    $p = $script:TcIdeSolutionRecordPending[$key]
    "session record of IDE process $ProcessId not updated: $($p.reason); its previous record is not used as evidence by this session (the $($p.action) is retried on the next lookup; retries so far: $([int]$p.retries))"
}

# -Cache (hashtable) memoizes the answer per record: the writers fill it BEFORE taking the mutex
# (Get-Process + StartTime per record is slow) so the locked section stays short (#51).
function Test-TcIdeRecordAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record, [hashtable]$Cache)
    if ($null -ne $Cache) {
        $key = "$($Record.pid)|$($Record.startTime)"
        if (-not $Cache.ContainsKey($key)) { $Cache[$key] = Test-TcIdeRecordAlive -Record $Record }
        return [bool]$Cache[$key]
    }
    try {
        $p = Get-Process -Id ([int]$Record.pid) -ErrorAction Stop
        # Compare as DateTime: pwsh 7 ConvertFrom-Json turns the ISO string into a DateTime itself.
        $recStart = if ($Record.startTime -is [DateTime]) { [DateTime]$Record.startTime } else { [DateTime]::Parse([string]$Record.startTime, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind) }
        return ($p.StartTime.ToUniversalTime() -eq $recStart.ToUniversalTime())
    }
    catch { return $false }
}

function Save-TcIdeSolutionRecord {
    <#
    .SYNOPSIS
        Remembers that IDE process -ProcessId has -Solution open (see the file header).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$ProcessId,
        [Parameter(Mandatory)][string]$Solution
    )
    try { $start = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToString('o') }
    catch { Write-Verbose "IDE solution record not saved ($($_.Exception.Message))"; return }   # process gone: nothing to record
    $at = (Get-Date).ToUniversalTime().ToString('o')
    $failure = Invoke-TcIdeSolutionRecordWrite -Action save -ProcessId $ProcessId -StartTime $start -Solution $Solution -WrittenAt $at
    # #123: not silent: a skipped write is kept as pending, the old record is untrusted meanwhile
    Set-TcIdeSolutionRecordPending -ProcessId $ProcessId -Failure $failure -Action save -StartTime $start -Solution $Solution -At $at
}

# Replaces the record file with -Records (tmp + move). Throws on failure (callers are best effort).
function Write-TcIdeSolutionRecords {
    [CmdletBinding()]
    param([object[]]$Records, [string]$Path)
    $path = if ([string]::IsNullOrWhiteSpace($Path)) { Get-TcIdeSolutionRecordPath } else { $Path }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$path.$PID.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject @($Records) -Depth 3) -Encoding UTF8
        # Atomic replace (no window without a file); Move only when there is nothing to replace.
        # Readers do not take the mutex and may hold the file open for a moment: retry the replace.
        for ($i = 1; $i -le 5; $i++) {
            try {
                if ([IO.File]::Exists($path)) { [IO.File]::Replace($tmp, $path, [NullString]::Value) }
                else { [IO.File]::Move($tmp, $path) }
                return
            }
            catch { if ($i -ge 5) { throw }; Start-Sleep -Milliseconds (50 * $i) }
        }
    }
    catch { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue; throw }
}

function Remove-TcIdeSolutionRecord {
    <#
    .SYNOPSIS
        Forgets the solution of IDE process -ProcessId (it has a solution whose path is not
        known, e.g. New-TcProject failed after Solution.Create). Best effort, never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $at = (Get-Date).ToUniversalTime().ToString('o')
    $failure = Invoke-TcIdeSolutionRecordWrite -Action remove -ProcessId $ProcessId -WrittenAt $at
    # #123: a record that should be gone but is still in the file must not be used (pending remove)
    Set-TcIdeSolutionRecordPending -ProcessId $ProcessId -Failure $failure -Action remove -At $at
}

function Get-TcIdeSolutionRecord {
    <#
    .SYNOPSIS
        Solution recorded for the RUNNING process -ProcessId (same start time), or $null.
        $null as well while a write of that process is still pending (#123, see
        Set-TcIdeSolutionRecordPending); the pending write is retried first unless -NoSync
        (the caller already ran Sync-TcIdeSolutionRecordPending for this lookup).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId, [switch]$NoSync)
    if (-not $NoSync) { Sync-TcIdeSolutionRecordPending }
    $untrusted = Get-TcIdeSolutionRecordWarning -ProcessId $ProcessId
    if ($null -ne $untrusted) { Write-Verbose $untrusted; return $null }
    try {
        foreach ($r in @(Read-TcIdeSolutionRecords)) {
            if ([int]$r.pid -ne $ProcessId) { continue }
            if (Test-TcIdeRecordAlive -Record $r) { return [string]$r.solution }
        }
    }
    catch { Write-Verbose "IDE solution record lookup failed ($($_.Exception.Message))" }
    $null
}

# --- per-process module state (kept across Connect-TcIde calls; launches also persisted, #73) ---
# Key = "<pid>|<start time 'o'>", so a recycled pid never matches.
function Get-TcIdeProcessKey {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    try { return "$ProcessId|$((Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime().ToString('o'))" }
    catch { return $null }
}

function Add-TcLaunchedIde {
    <#
    .SYNOPSIS
        Remembers that this module launched IDE process -ProcessId (Disconnect-TcIde -Kill is
        allowed for it), independent of $script:TcIdeSelectedBy, which a later Connect-TcIde resets.
        Module memory only; Connect-TcIde persists it with Save-TcLaunchRecord (#73).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return }
    if ($null -eq $script:TcLaunchedIdes) { $script:TcLaunchedIdes = @{} }
    $script:TcLaunchedIdes[$key] = $true
}

# #73: not in the module memory (a restarted bridge / ReloadModule / Import-Module -Force) ->
# the persisted launch record of that process (TcLaunchRecordStore.ps1): only a VALID one (pid +
# start time + image name) whose pid was CONFIRMED (rot-identity / main-window) restores the
# ownership - and only when it is this host's record or its host process is gone (#152 M1,
# Request-TcLaunchRecordOwnership) - and it is cached in memory. An unreadable / corrupt file
# restores nothing.
function Test-TcLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return $false }
    if ($null -ne $script:TcLaunchedIdes -and $script:TcLaunchedIdes.ContainsKey($key)) { return $true }
    $rec = Find-TcConfirmedLaunchRecord -ProcessId $ProcessId
    if ($null -eq $rec) { return $false }
    # #152 M1: launched by another LIVE TcAuto session (bridge) -> not ours
    if (-not (Request-TcLaunchRecordOwnership -Record $rec)) { Write-Verbose "IDE pid $ProcessId was launched by another TcAuto session (host pid $($rec.hostPid)); not owned"; return $false }
    if ($null -eq $script:TcLaunchedIdes) { $script:TcLaunchedIdes = @{} }
    $script:TcLaunchedIdes[$key] = $true
    Write-Verbose "IDE pid $ProcessId owned by this session: launch record restored from the state file ($($rec.pidSource), module instance $($rec.moduleInstanceId))"
    $true
}

function Get-TcIdeSilentOriginal {
    <#
    .SYNOPSIS
        The ITcAutomationSettings.SilentMode value IDE process -ProcessId had before this module
        first set it, 'unknown' when it could not be read then, or $null when not recorded.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($null -eq $script:TcSilentOriginals) { return $null }
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key -or -not $script:TcSilentOriginals.ContainsKey($key)) { return $null }
    $v = $script:TcSilentOriginals[$key]
    if ($v -is [string]) { return [string]$v }   # 'unknown': the original could not be read
    [bool]$v
}

function Set-TcIdeSilentOriginal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId, [Parameter()][AllowNull()][object]$Value)
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return }
    if ($null -eq $script:TcSilentOriginals) { $script:TcSilentOriginals = @{} }
    if ($null -eq $Value) { $script:TcSilentOriginals.Remove($key) }
    elseif ($Value -is [string]) { $script:TcSilentOriginals[$key] = 'unknown' }
    else { $script:TcSilentOriginals[$key] = [bool]$Value }
}