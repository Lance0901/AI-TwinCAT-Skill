# #73 / #149: the IDEs this module launched, persisted so that a restarted MCP bridge
# (BRIDGE_TIMEOUT, the restart after IDE_MODAL_DIALOG), ReloadModule or Import-Module -Force still
# knows them:
#   <Get-TcStateDir>\launched-ides.json   ($env:TCAUTO_STATE_DIR or %TEMP%\TwinCATAutomation)
#   [ { launchId; pid; startTime (UTC 'o'); imageName (process name, no .exe); progId;
#       solution (the .sln it was launched for, $null = none / released); pidSource
#       ('rot-identity' | 'main-window' | 'pid-unconfirmed'); launchedAt (UTC 'o'); createdAt
#       (UTC 'o'); updatedAt (UTC 'o'); moduleInstanceId; hostPid } ]
# Read-modify-write under a named mutex like ide-solutions.json (#51); with TCAUTO_STATE_DIR set the
# mutex name carries the hash of that directory (#118).
# A record only counts while the SAME process is running: pid exists, its start time AND its image
# name equal the record (a recycled pid never matches). Only 'rot-identity' / 'main-window' records
# restore ownership (Test-TcLaunchedIde -> Disconnect-TcIde -Kill); a 'pid-unconfirmed' record
# (pid only guessed from the start time, #147 M2) never does - it only keeps Connect-TcIde from
# launching a second IDE for the same .sln (IDE_LAUNCH_PENDING probe pid-unconfirmed) until that
# process is gone or Disconnect-TcIde -ForgetPendingLaunch drops it.
# Fail closed: a file that cannot be read or is corrupt restores NOTHING (no IDE becomes owned) and
# never blocks Connect-TcIde; a writer moves a corrupt file aside (.corrupt-<time>). Never throws.
# The module memory ($script:TcLaunchedIdes / $script:TcLaunchedIdeSolutions) is the cache: what
# this module instance launched itself, or restored from the file, is not read again.

$script:TcModuleInstanceId = [guid]::NewGuid().ToString('N')
$script:TcLaunchRecordLockName = 'Local\TwinCATAutomation-launched-ides'
$script:TcLaunchRecordLockTimeoutMs = 2000
$script:TcLaunchRecordWarning = $null   # last failed read / write of the file (reported in data.launchRecordWarning)
$script:TcConfirmedPidSources = @('rot-identity', 'main-window')

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
        $p = Get-Process -Id $procId -ErrorAction Stop
        if (-not [string]::Equals([string]$p.ProcessName, [string]$Record.imageName, [StringComparison]::OrdinalIgnoreCase)) { return $false }
        return (([DateTime]$p.StartTime).ToUniversalTime() -eq (ConvertTo-TcUtcDate $Record.startTime))
    }
    catch { return $false }
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

# Runs -Mutate { param($records) ... return the new list } on the VALID records under the lock and
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
                default { $all = @($file.Records | Where-Object { Test-TcLaunchRecordValid -Record $_ }) }
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
    if ($ProcessId -le 0) { return $null }
    try { $p = Get-Process -Id $ProcessId -ErrorAction Stop } catch { return $null }   # gone: nothing to record
    $start = $null; try { $start = ([DateTime]$p.StartTime).ToUniversalTime().ToString('o') } catch { $start = $null }
    $image = [string]$p.ProcessName
    if ($null -eq $start -or [string]::IsNullOrWhiteSpace($image)) { return $null }   # cannot be validated later
    $now = (Get-Date).ToUniversalTime().ToString('o')
    $launchedAt = $now
    if ($null -ne $LaunchTime) { try { $launchedAt = ([DateTime]$LaunchTime).ToUniversalTime().ToString('o') } catch { $launchedAt = $now } }
    $src = if ($script:TcConfirmedPidSources -contains $PidSource) { $PidSource } else { 'pid-unconfirmed' }
    $rec = [PSCustomObject][ordered]@{
        launchId = $LaunchId; pid = $ProcessId; startTime = $start; imageName = $image; progId = $ProgId
        solution = $(if ([string]::IsNullOrWhiteSpace($Solution)) { $null } else { $Solution }); pidSource = $src
        launchedAt = $launchedAt; createdAt = $now; updatedAt = $now
        moduleInstanceId = $script:TcModuleInstanceId; hostPid = $PID
    }
    Update-TcLaunchRecordFile -What 'launch record save' -Mutate {
        param($all)
        $old = @($all | Where-Object { [string]$_.launchId -eq $LaunchId }) | Select-Object -First 1
        if ($null -ne $old -and $null -ne $old.createdAt) { $rec.createdAt = [string]$old.createdAt; $rec.moduleInstanceId = [string]$old.moduleInstanceId; $rec.hostPid = $old.hostPid }
        # one record per launch and per process (same pid + start time)
        # (every record left in $all is valid, so the same pid means the same process)
        @($all | Where-Object { [string]$_.launchId -ne $LaunchId -and [int]$_.pid -ne $ProcessId }) + @($rec)
    }
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
            if (Test-TcLaunchRecordConfirmed -Record $r) { $r.solution = $null; $r.updatedAt = (Get-Date).ToUniversalTime().ToString('o'); $r }
        }
    }
}

# Drops every unconfirmed record (Disconnect-TcIde -ForgetPendingLaunch). Returns @{ Dropped; Failure }.
function Clear-TcUnconfirmedLaunchRecords {
    [CmdletBinding()]
    param()
    $dropped = [System.Collections.ArrayList]::new()
    $failure = Update-TcLaunchRecordFile -What 'launch record forget' -Mutate {
        param($all)
        foreach ($r in $all) {
            if (Test-TcLaunchRecordConfirmed -Record $r) { $r; continue }
            [void]$dropped.Add([PSCustomObject]@{ solution = $r.solution; progId = $r.progId; launchTime = $r.launchedAt; launchId = $r.launchId; processId = [int]$r.pid; persisted = $true })
        }
    }
    @{ Dropped = @($dropped); Failure = $failure }
}

# The newest valid persisted record for -Solution, or $null (also when the file is unusable).
function Find-TcLaunchRecordForSolution {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Solution)
    $r = Get-TcLaunchRecords
    if ($r.State -notin 'ok', 'missing') { return $null }
    @($r.Records | Where-Object { [string]::Equals([string]$_.solution, $Solution, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { try { ConvertTo-TcUtcDate $_.createdAt } catch { [DateTime]::MinValue } } -Descending) | Select-Object -First 1
}

# A confirmed, valid persisted record of IDE process -ProcessId, or $null.
function Find-TcConfirmedLaunchRecord {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    if ($ProcessId -le 0) { return $null }
    $r = Get-TcLaunchRecords
    if ($r.State -notin 'ok', 'missing') { return $null }
    @($r.Records | Where-Object { [int]$_.pid -eq $ProcessId -and (Test-TcLaunchRecordConfirmed -Record $_) }) | Select-Object -First 1
}
