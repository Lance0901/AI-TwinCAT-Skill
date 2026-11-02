# Which solution each IDE process had open the last time Connect-TcIde connected to it with a
# solution, kept in a small JSON file shared by every PowerShell process / MCP bridge of this user:
#   $env:LOCALAPPDATA\TwinCATAutomation\ide-solutions.json
#   [ { pid; startTime ('o' format); solution } ]
# Connect-TcIde -SolutionPath reads it for an IDE whose DTE cannot be asked (modal dialog / busy,
# issue #29). A record only counts while the same process (pid AND start time) is still running,
# so a recycled pid never matches. Best effort: any I/O error is ignored.

function Get-TcIdeSolutionRecordPath {
    [CmdletBinding()]
    param()
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
    param()
    $path = Get-TcIdeSolutionRecordPath
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
$script:TcIdeSolutionLockName = 'Local\TwinCATAutomation-ide-solutions'
$script:TcIdeSolutionLockTimeoutMs = 2000

# Runs -Body under the ide-solutions mutex (same helper as build-required.json). Returns $true
# when it ran without error; otherwise writes a verbose line. Best effort: never throws.
function Invoke-TcIdeSolutionLocked {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Body, [string]$What = 'IDE solution record')
    $r = Invoke-TcBuildRequiredLocked -Body $Body -MutexName $script:TcIdeSolutionLockName -TimeoutMs $script:TcIdeSolutionLockTimeoutMs
    if (-not $r.Locked) { Write-Verbose "$What skipped ($($r.Error))"; return $false }
    if ($r.Error) { Write-Verbose "$What failed ($($r.Error))"; return $false }
    $true
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
    try {
        $start = (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToString('o')
        $alive = @{}
        foreach ($r in @(Read-TcIdeSolutionRecords)) { $null = Test-TcIdeRecordAlive -Record $r -Cache $alive }   # outside the lock
        $null = Invoke-TcIdeSolutionLocked -What 'IDE solution record save' -Body {
            $keep = @(Read-TcIdeSolutionRecordsForWrite | Where-Object { [int]$_.pid -ne $ProcessId -and (Test-TcIdeRecordAlive -Record $_ -Cache $alive) })
            $keep += [PSCustomObject]@{ pid = $ProcessId; startTime = $start; solution = $Solution }
            Write-TcIdeSolutionRecords -Records $keep
        }
    }
    catch { Write-Verbose "IDE solution record not saved ($($_.Exception.Message))" }
}

# Replaces the record file with -Records (tmp + move). Throws on failure (callers are best effort).
function Write-TcIdeSolutionRecords {
    [CmdletBinding()]
    param([object[]]$Records)
    $path = Get-TcIdeSolutionRecordPath
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
    try {
        $alive = @{}
        foreach ($r in @(Read-TcIdeSolutionRecords)) { $null = Test-TcIdeRecordAlive -Record $r -Cache $alive }   # outside the lock
        $null = Invoke-TcIdeSolutionLocked -What 'IDE solution record remove' -Body {
            $all = @(Read-TcIdeSolutionRecordsForWrite -LeaveCorrupt)
            if (-not @($all | Where-Object { [int]$_.pid -eq $ProcessId })) { return }
            Write-TcIdeSolutionRecords -Records @($all | Where-Object { [int]$_.pid -ne $ProcessId -and (Test-TcIdeRecordAlive -Record $_ -Cache $alive) })
        }
    }
    catch { Write-Verbose "IDE solution record not removed ($($_.Exception.Message))" }
}

function Get-TcIdeSolutionRecord {
    <#
    .SYNOPSIS
        Solution recorded for the RUNNING process -ProcessId (same start time), or $null.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    try {
        foreach ($r in @(Read-TcIdeSolutionRecords)) {
            if ([int]$r.pid -ne $ProcessId) { continue }
            if (Test-TcIdeRecordAlive -Record $r) { return [string]$r.solution }
        }
    }
    catch { Write-Verbose "IDE solution record lookup failed ($($_.Exception.Message))" }
    $null
}

# --- per-process module state (kept across Connect-TcIde calls, never across processes) ---
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
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return }
    if ($null -eq $script:TcLaunchedIdes) { $script:TcLaunchedIdes = @{} }
    $script:TcLaunchedIdes[$key] = $true
}

function Test-TcLaunchedIde {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($null -eq $script:TcLaunchedIdes) { return $false }
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    ($null -ne $key -and $script:TcLaunchedIdes.ContainsKey($key))
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