# #73 / #149: the IDEs this module launched, persisted so that a restarted MCP bridge
# (BRIDGE_TIMEOUT, the restart after IDE_MODAL_DIALOG), ReloadModule or Import-Module -Force still
# knows them:
#   <Get-TcStateDir>\launched-ides.json   ($env:TCAUTO_STATE_DIR or %TEMP%\TwinCATAutomation)
#   [ { launchId; pid; startTime (UTC 'o'); imageName (process name, no .exe); progId;
#       solution (the .sln it was launched for, $null = none / released); pidSource
#       ('rot-identity' | 'main-window' | 'pid-unconfirmed'); launchedAt (UTC 'o'); createdAt
#       (UTC 'o'); updatedAt (UTC 'o'); moduleInstanceId; hostPid; hostStartTime (UTC 'o');
#       ownerId } ]
# hostPid + hostStartTime = the PowerShell process (MCP bridge) whose module wrote / adopted the
# record (#152 M1). ownerId = $env:TCAUTO_OWNER_ID, a GUID the MCP server (node) creates once and
# passes to every bridge child it spawns (first start, BRIDGE_TIMEOUT restart, ReloadModule), so
# it is the same across those restarts and different for every other MCP server / conversation;
# a manual PowerShell has none (#152 round 2 N1). Several sessions share the file: a record
# restores ownership only in its own host ($PID with the same start time), or when its host
# process is gone AND its ownerId equals this process's ownerId (adopted under the lock). Anything
# else - another live session, a session that ended (a later conversation must not take over an
# IDE the user may have kept working in), no ownerId, a host that cannot be verified - still
# blocks a second launch for its .sln (IDE_LAUNCH_PENDING probe 'other-session') but is never
# owned: -Kill is refused.
# Read-modify-write under a named mutex like ide-solutions.json (#51); with TCAUTO_STATE_DIR set the
# mutex name carries the hash of that directory (#118).
# A record only counts while the SAME process is running: pid exists, its start time AND its image
# name equal the record (a recycled pid never matches). Only 'rot-identity' / 'main-window' records
# restore ownership (Test-TcLaunchedIde -> Disconnect-TcIde -Kill); a 'pid-unconfirmed' record
# (pid only guessed from the start time, #147 M2) never does - it only keeps Connect-TcIde from
# launching a second IDE for the same .sln (IDE_LAUNCH_PENDING probe pid-unconfirmed) until that
# process is gone or Disconnect-TcIde -ForgetPendingLaunch drops it.
# Cleanup (every write) drops only records that are certainly another process: pid not running,
# or its start time readable and different (or no usable pid / start time at all). A record that
# cannot be verified (start time not readable) is kept as it is (#152 m3).
# Fail closed: a file that cannot be read or is corrupt restores NOTHING (no IDE becomes owned) and
# never blocks Connect-TcIde; a writer moves a corrupt file aside (.corrupt-<time>). Never throws.
# The module memory ($script:TcLaunchedIdes / $script:TcLaunchedIdeSolutions) is the cache: what
# this module instance launched itself, or restored from the file, is not read again.

$script:TcModuleInstanceId = [guid]::NewGuid().ToString('N')
$script:TcLaunchRecordLockName = 'Local\TwinCATAutomation-launched-ides'
$script:TcLaunchRecordLockTimeoutMs = 2000
$script:TcLaunchRecordWarning = $null   # last failed read / write of the file (reported in data.launchRecordWarning)
$script:TcConfirmedPidSources = @('rot-identity', 'main-window')
$script:TcLaunchHostStartTime = $null   # UTC 'o' start time of this PowerShell process (Get-TcLaunchHostStartTime)

function Get-TcLaunchHostStartTime {
    if ($null -eq $script:TcLaunchHostStartTime) {
        try { $script:TcLaunchHostStartTime = ([DateTime](Get-Process -Id $PID -ErrorAction Stop).StartTime).ToUniversalTime().ToString('o') } catch { $script:TcLaunchHostStartTime = $null }
    }
    $script:TcLaunchHostStartTime
}

# IDE image names a launch record may name (n3): TcXaeShell / devenv (Get-TcIdeExeName).
function Get-TcIdeImageNames { @((Get-TcIdeExeName -ProgId 'TcXaeShell.DTE.15.0'), (Get-TcIdeExeName -ProgId 'VisualStudio.DTE.17.0')) }

function Get-TcLaunchRecordPath {
    [CmdletBinding()]
    param()
    Join-Path (Get-TcStateDir) 'launched-ides.json'
}

function Get-TcLaunchRecordLockName {
    if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) { return $script:TcLaunchRecordLockName }
    "$($script:TcLaunchRecordLockName).$(((Get-TcBuildRequiredMutexName) -split '\.')[-1])"
}

# 'o' string (pwsh 7 ConvertFrom-Json gives a DateTime already) -> UTC DateTime; throws when unparsable.
function ConvertTo-TcUtcDate {
    param([AllowNull()][object]$Value)
    if ($Value -is [DateTime]) { return ([DateTime]$Value).ToUniversalTime() }
    [DateTime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
}

# Is -Record still the process it names (pid alive, same start time, same image name)?
function Test-TcLaunchRecordValid {
    [CmdletBinding()]
    param([AllowNull()][object]$Record)
    if ($null -eq $Record) { return $false }
    try {
        $procId = [int]$Record.pid
        if ($procId -le 0 -or [string]::IsNullOrWhiteSpace([string]$Record.imageName) -or $null -eq $Record.startTime) { return $false }
        if ((Get-TcIdeImageNames) -notcontains [string]$Record.imageName) { return $false }
        $p = Get-Process -Id $procId -ErrorAction Stop
        if (-not [string]::Equals([string]$p.ProcessName, [string]$Record.imageName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return (([DateTime]$p.StartTime).ToUniversalTime() -eq (ConvertTo-TcUtcDate $Record.startTime))
    }
    catch { return $false }
}

# Is -Record certainly NOT the process it names any more (cleanup may drop it)? Malformed (no
# positive pid / no parsable start time), pid not running, or start time readable and different.
# A start time that cannot be read is not proof: $false (kept).
function Test-TcLaunchRecordStale {
    [CmdletBinding()]
    param([AllowNull()][object]$Record)
    if ($null -eq $Record) { return $true }
    $procId = 0; $recStart = $null
    try { $procId = [int]$Record.pid; $recStart = ConvertTo-TcUtcDate $Record.startTime } catch { return $true }
    if ($procId -le 0) { return $true }
    $p = $null
    try { $p = Get-Process -Id $procId -ErrorAction Stop } catch { return $true }
    if ($null -eq $p) { return $true }
    $st = $null
    try { $st = ([DateTime]$p.StartTime).ToUniversalTime() } catch { return $false }
    return ($st -ne $recStart)
}

# Whose is -Record (#152 M1)? 'self' (hostPid = this process), 'gone' (that host process is not
# running, or runs with another start time), 'alive' (another live process, or not verifiable).
function Get-TcLaunchRecordHostState {
    [CmdletBinding()]
    param([AllowNull()][object]$Record)
    $hp = 0
    try { $hp = [int]$Record.hostPid } catch { $hp = 0 }
    if ($hp -le 0) { return 'alive' }   # no host recorded: not provably free
    if ($hp -eq $PID) {
        $mine = Get-TcLaunchHostStartTime
        $rec = $null; try { $rec = (ConvertTo-TcUtcDate $Record.hostStartTime).ToString('o') } catch { $rec = $null }
        # N2: a record without (parsable) hostStartTime, or our own start time unreadable: not
        # provably ours -> 'alive' (fail closed)
        if ($null -eq $rec -or $null -eq $mine) { return 'alive' }
        if ($rec -eq $mine) { return 'self' }
        return 'gone'   # a recycled pid: the writer was another, earlier process
    }
    $p = $null
    try { $p = Get-Process -Id $hp -ErrorAction Stop } catch { return 'gone' }
    if ($null -eq $p) { return 'gone' }
    $recStart = $null; try { $recStart = ConvertTo-TcUtcDate $Record.hostStartTime } catch { return 'alive' }
    $st = $null; try { $st = ([DateTime]$p.StartTime).ToUniversalTime() } catch { return 'alive' }
    if ($st -ne $recStart) { return 'gone' }
    'alive'
}

# The ownerId of this process ($env:TCAUTO_OWNER_ID, set by the MCP server), or $null.
function Get-TcLaunchOwnerId {
    $o = $env:TCAUTO_OWNER_ID
    if ([string]::IsNullOrWhiteSpace($o)) { return $null }
    $o.Trim()
}

# May this process own / adopt / forget -Record? Its host is this process ('self'), or its host is
# gone and it has the same non-empty ownerId (the same MCP server, N1).
function Test-TcLaunchRecordClaimable {
    [CmdletBinding()]
    param([AllowNull()][object]$Record)
    $state = Get-TcLaunchRecordHostState -Record $Record
    if ($state -eq 'self') { return $true }
    if ($state -ne 'gone') { return $false }
    $mine = Get-TcLaunchOwnerId
    if ($null -eq $mine) { return $false }
    $theirs = $null; try { $theirs = [string]$Record.ownerId } catch { $theirs = $null }
    (-not [string]::IsNullOrWhiteSpace($theirs)) -and [string]::Equals($theirs.Trim(), $mine, [StringComparison]::OrdinalIgnoreCase)
}

function Test-TcLaunchRecordConfirmed {
    [CmdletBinding()]
    param([AllowNull()][object]$Record)
    ($null -ne $Record -and $script:TcConfirmedPidSources -contains [string]$Record.pidSource)
}

# @{ State ('ok' | 'missing' | 'unreadable' | 'corrupt'); Records (VALID records only); Error }.
# Never throws (a refused real state directory under the test guard is 'unreadable').
function Get-TcLaunchRecords {
    [CmdletBinding()]
    param()
    try { $r = Read-TcIdeSolutionRecordFile -Path (Get-TcLaunchRecordPath) }
    catch { $r = @{ State = 'unreadable'; Records = @(); Error = $_.Exception.Message } }
    if ($r.State -in 'unreadable', 'corrupt') {
        $script:TcLaunchRecordWarning = "launch records $($r.State) ($($r.Error)); no IDE is treated as launched by this session from them"
        Write-Verbose $script:TcLaunchRecordWarning
        return @{ State = $r.State; Records = @(); Error = $r.Error }
    }
    @{ State = $r.State; Records = @($r.Records | Where-Object { Test-TcLaunchRecordValid -Record $_ }); Error = $null }
}

# Runs -Mutate { param($records) ... return the new list } on the non-stale records under the lock and
# writes the result. A corrupt file is moved aside first (its records are lost: fail closed), an
# unreadable one is not written. Returns $null or the failure reason; never throws.
function Update-TcLaunchRecordFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)][scriptblock]$Mutate, [string]$What = 'launch record update')
    $failure = $null
    try {
        $path = Get-TcLaunchRecordPath
        $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLaunchRecordLockName) -TimeoutMs $script:TcLaunchRecordLockTimeoutMs -Body {
            $file = Read-TcIdeSolutionRecordFile -Path $path
            $all = @()
            switch ($file.State) {
                'unreadable' { throw "records not read, nothing written ($($file.Error))" }
                'corrupt' {
                    $kept = "$path.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))"
                    try { [IO.File]::Move($path, $kept) } catch { throw "corrupt records not moved aside, nothing written ($($_.Exception.Message))" }
                    Write-Verbose "launch records corrupt ($($file.Error)); kept as $kept"
                }
                default { $all = @($file.Records | Where-Object { -not (Test-TcLaunchRecordStale -Record $_) }) }
            }
            $new = @(& $Mutate $all | Where-Object { $null -ne $_ })
            Write-TcIdeSolutionRecords -Path $path -Records $new
        }
        if (-not $r.Locked) { $failure = "$What skipped ($($r.Error))" }
        elseif ($r.Error) { $failure = "$What failed ($($r.Error))" }
    }
    catch { $failure = "$What failed ($($_.Exception.Message))" }
    if ($null -ne $failure) { $script:TcLaunchRecordWarning = $failure; Write-Verbose $failure }
    $failure
}

# Persists (or replaces, same -LaunchId) the launch of IDE process -ProcessId. -PidSource
# 'rot-identity' / 'main-window' = confirmed; anything else is stored as 'pid-unconfirmed'.
# Returns $null or the failure reason.
function Save-TcLaunchRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LaunchId,
        [Parameter(Mandatory)][int]$ProcessId,
        [string]$PidSource, [string]$ProgId, [AllowNull()][string]$Solution, [AllowNull()][object]$LaunchTime
    )
    # N4: every skip is reported (data.launchRecordWarning): the launch is then not protected
    # across a bridge restart
    $skip = { param($why) $script:TcLaunchRecordWarning = "launch record of pid $ProcessId not written: $why"; Write-Verbose $script:TcLaunchRecordWarning; $script:TcLaunchRecordWarning }
    if ($ProcessId -le 0) { return (& $skip 'no process id') }
    try { $p = Get-Process -Id $ProcessId -ErrorAction Stop } catch { return (& $skip 'the process is not running') }
    $start = $null; try { $start = ([DateTime]$p.StartTime).ToUniversalTime().ToString('o') } catch { $start = $null }
    $image = [string]$p.ProcessName
    if ($null -eq $start -or [string]::IsNullOrWhiteSpace($image)) { return (& $skip 'its start time / image name is not readable, so it could not be validated later') }
    if ((Get-TcIdeImageNames) -notcontains $image) { return (& $skip "its image '$image' is not an IDE ($((Get-TcIdeImageNames) -join ' / '))") }   # n3
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $launchedAt = $now
    if ($null -ne $LaunchTime) { try { $launchedAt = ([DateTime]$LaunchTime).ToUniversalTime().ToString('o') } catch { $launchedAt = $now } }
    $src = if ($script:TcConfirmedPidSources -contains $PidSource) { $PidSource } else { 'pid-unconfirmed' }
    $rec = [PSCustomObject][ordered]@{
        launchId = $LaunchId; pid = $ProcessId; startTime = $start; imageName = $image; progId = $ProgId
        solution = $(if ([string]::IsNullOrWhiteSpace($Solution)) { $null } else { $Solution }); pidSource = $src
        launchedAt = $launchedAt; createdAt = $now; updatedAt = $now
        moduleInstanceId = $script:TcModuleInstanceId; hostPid = $PID; hostStartTime = (Get-TcLaunchHostStartTime)
        ownerId = (Get-TcLaunchOwnerId)
    }
    $isConfirmed = ($src -ne 'pid-unconfirmed')
    $res = @{ blocked = $false }
    $failure = Update-TcLaunchRecordFile -What 'launch record save' -Mutate {
        param($all)
        $old = @($all | Where-Object { [string]$_.launchId -eq $LaunchId }) | Select-Object -First 1
        if ($null -ne $old) {
            # m1: an unconfirmed write never replaces a confirmed record of the same launch
            if (-not $isConfirmed -and (Test-TcLaunchRecordConfirmed -Record $old)) { $res.blocked = $true; return $all }
            try { $rec.createdAt = (ConvertTo-TcUtcDate $old.createdAt).ToString('o') } catch { }
        }
        # same pid, other launch: only a CONFIRMED record replaces it; an unconfirmed one is not
        # written when a confirmed record names that pid (it would replace / shadow it)
        $samePid = @($all | Where-Object { [string]$_.launchId -ne $LaunchId -and (Test-TcLaunchRecordPid -Record $_ -ProcessId $ProcessId) })
        if (-not $isConfirmed -and @($samePid | Where-Object { Test-TcLaunchRecordConfirmed -Record $_ }).Count -gt 0) { $res.blocked = $true; return $all }
        $keep = @($all | Where-Object { [string]$_.launchId -ne $LaunchId })
        if ($isConfirmed) { $keep = @($keep | Where-Object { -not (Test-TcLaunchRecordPid -Record $_ -ProcessId $ProcessId) }) }
        $keep + @($rec)
    }
    if ($null -ne $failure) { return $failure }
    if ($res.blocked) { return (& $skip 'a confirmed record already names this process (an unconfirmed write never replaces it)') }
    $null
}

function Test-TcLaunchRecordPid {
    param([AllowNull()][object]$Record, [int]$ProcessId)
    $p = 0; try { $p = [int]$Record.pid } catch { $p = 0 }
    $p -eq $ProcessId
}

# #152 M1 / N1: may this module instance own the IDE of -Record? Only a record of this host ($PID,
# same start time), or of a host process that is gone with the SAME ownerId (the same MCP server:
# a bridge restart / ReloadModule). Such a record is adopted under the lock (hostPid /
# hostStartTime / moduleInstanceId become this process) so another bridge cannot claim it too;
# when that write fails the answer is $false (fail closed).
function Request-TcLaunchRecordOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record)
    $state = Get-TcLaunchRecordHostState -Record $Record
    if ($state -eq 'self') { return $true }
    if (-not (Test-TcLaunchRecordClaimable -Record $Record)) { return $false }
    $res = @{ adopted = $false }
    $lid = [string]$Record.launchId
    $failure = Update-TcLaunchRecordFile -What 'launch record adopt' -Mutate {
        param($all)
        foreach ($r in $all) {
            if ([string]$r.launchId -eq $lid -and (Test-TcLaunchRecordClaimable -Record $r)) {
                $r.hostPid = $PID; $r.hostStartTime = (Get-TcLaunchHostStartTime); $r.moduleInstanceId = $script:TcModuleInstanceId
                $r.updatedAt = (Get-Date).ToUniversalTime().ToString('o')
                $res.adopted = $true
            }
            $r
        }
    }
    ($null -eq $failure -and $res.adopted)
}

# Drops the records of -ProcessId (Disconnect-TcIde: quit, killed or already exited) and the
# module cache of that pid. Returns $null or the failure reason.
function Remove-TcLaunchRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    if ($null -ne $script:TcLaunchedIdes) { foreach ($k in @($script:TcLaunchedIdes.Keys)) { if ($k -like "$ProcessId|*") { $script:TcLaunchedIdes.Remove($k) } } }
    if ($null -ne $script:TcLaunchedIdeSolutions) {
        foreach ($k in @($script:TcLaunchedIdeSolutions.Keys)) { if ([int]$script:TcLaunchedIdeSolutions[$k].processId -eq $ProcessId) { $script:TcLaunchedIdeSolutions.Remove($k) } }
    }
    Update-TcLaunchRecordFile -What 'launch record remove' -Mutate { param($all) @($all | Where-Object { [int]$_.pid -ne $ProcessId }) }
}

# The .sln of these records is no longer theirs (the IDE has another solution open, or is gone):
# a confirmed record keeps its ownership with solution $null, an unconfirmed one is dropped.
function Clear-TcLaunchRecordSolution {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Solution)
    Update-TcLaunchRecordFile -What 'launch record release' -Mutate {
        param($all)
        foreach ($r in $all) {
            if (-not [string]::Equals([string]$r.solution, $Solution, [StringComparison]::OrdinalIgnoreCase)) { $r; continue }
            if (-not (Test-TcLaunchRecordClaimable -Record $r)) { $r; continue }   # another live session's record
            if (Test-TcLaunchRecordConfirmed -Record $r) { $r.solution = $null; $r.updatedAt = (Get-Date).ToUniversalTime().ToString('o'); $r }
        }
    }
}

# Drops the unconfirmed records of this host or of a host that is gone (Disconnect-TcIde
# -ForgetPendingLaunch); those of another live TcAuto session are kept (#152 M1).
# Returns @{ Dropped; Kept (other sessions); Failure }.
function Clear-TcUnconfirmedLaunchRecords {
    [CmdletBinding()]
    param()
    $dropped = [System.Collections.ArrayList]::new()
    $kept = [System.Collections.ArrayList]::new()
    $failure = Update-TcLaunchRecordFile -What 'launch record forget' -Mutate {
        param($all)
        foreach ($r in $all) {
            if (Test-TcLaunchRecordConfirmed -Record $r) { $r; continue }
            if (-not (Test-TcLaunchRecordClaimable -Record $r)) {
                $kp = 0; try { $kp = [int]$r.pid } catch { $kp = 0 }
                [void]$kept.Add([PSCustomObject]@{ solution = $r.solution; launchId = $r.launchId; processId = $kp; hostPid = $r.hostPid })
                $r; continue
            }
            [void]$dropped.Add([PSCustomObject]@{ solution = $r.solution; progId = $r.progId; launchTime = $r.launchedAt; launchId = $r.launchId; processId = [int]$r.pid; persisted = $true })
        }
    }
    @{ Dropped = @($dropped); Kept = @($kept); Failure = $failure }
}

# The newest valid persisted record for -Solution, or $null (also when the file is unusable).
function Find-TcLaunchRecordForSolution {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Solution)
    $r = Get-TcLaunchRecords
    if ($r.State -notin 'ok', 'missing') { return $null }
    @($r.Records | Where-Object { [string]::Equals([string]$_.solution, $Solution, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { try { ConvertTo-TcUtcDate $_.createdAt } catch { [DateTime]::MinValue } } -Descending) | Select-Object -First 1
}

# A confirmed, valid persisted record of IDE process -ProcessId, or $null (any host: the caller
# decides with Request-TcLaunchRecordOwnership).
function Find-TcConfirmedLaunchRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    $r = Get-TcLaunchRecords
    if ($r.State -notin 'ok', 'missing') { return $null }
    @($r.Records | Where-Object { [int]$_.pid -eq $ProcessId -and (Test-TcLaunchRecordConfirmed -Record $_) }) | Select-Object -First 1
}
