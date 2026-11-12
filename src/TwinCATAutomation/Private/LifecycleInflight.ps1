# In-flight marker of a runtime-changing request (#236, fail closed #68).
#
# A lifecycle block is written by the command itself when it fails after its request went out
# (LifecycleBlock.ps1). That cannot happen when the PROCESS dies while the request is pending: the
# MCP server kills the PowerShell bridge when its modal probe sees a dialog (IDE_MODAL_DIALOG,
# e.g. "license not found" after ActivateConfiguration(), measured 2026-11-11 with VS2022 4026 +
# UmRT), on BRIDGE_TIMEOUT or a crash. Without a record the next agent could run
# Enable-TcConfig again on a runtime that was left in Config. (A stopped pipeline - Ctrl+C - skips
# catch but runs finally: Enable-TcConfig and Set-TcSystemState record INTERRUPTED there.)
#
# So right before the request is sent the command (Set-TcSystemState, Set-TcPlcState,
# Enable-TcConfig) writes a marker file - <name>.tmp first, then renamed, so it is never read
# half-written - and removes it when it returns (whatever the result; a failure writes its own
# block first):
#   <state dir>\lifecycle-inflight.<pid>.<guid>.json
#     { pid; processName; processStartUtc; command; amsNetId; requestedState; step; startedAtUtc }
#   One file per request (nested commands, e.g. Enable-TcConfig -> Set-TcSystemState, each own one).
# Every lifecycle check (Get-TcLifecycleBlockEntries, in any process) first promotes the markers
# whose owner is gone - no process with that pid, one with another name or another start time
# (pid reused, also this process's own pid) - to a lifecycle block (errorCode INTERRUPTED, the
# marker's command / target / requested state). A record of the same target created after the
# marker started is newer and kept as it is. A marker that cannot be read is judged by the pid in
# its file name: alive -> left alone, gone -> a '<unknown>' record (blocks every target). The
# marker file is removed only once the block is in the state file; a dead owner's marker that
# cannot be promoted (lock, write) or a directory that cannot be listed makes the check fail
# (state-unreadable: every target blocked) and the marker is promoted again next time.
# Markers of live processes (another bridge in the middle of its request) are left alone.
#
# Never throws. Windows PowerShell 5.1; ASCII source.

$script:TcLifecycleInflightPrefix = 'lifecycle-inflight.'

function Get-TcLifecycleInflightDir {
    Split-Path -Parent (Get-TcLifecycleBlockFile)
}

function Enter-TcLifecycleInflight {
    <#
    .SYNOPSIS
        #236: writes the in-flight marker of a runtime-changing request; returns its path (the
        token for Exit-TcLifecycleInflight) or $null when it could not be written (Write-Verbose;
        the command still runs: the in-process failure paths keep writing their own block).
        Written atomically: <name>.tmp first, then File.Move to <name>.json, so a reader never
        sees a half-written marker.
    #>
    param([Parameter(Mandatory)][string]$Command, [string]$AmsNetId, [string]$RequestedState, [string]$Step)
    $tmp = $null
    try {
        $dir = Get-TcLifecycleInflightDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $dir }
        $me = $null
        try { $me = Get-Process -Id $PID -ErrorAction Stop } catch { $me = $null }
        $start = $null
        if ($null -ne $me) { try { $start = $me.StartTime.ToUniversalTime() } catch { $start = $null } }
        $m = [PSCustomObject]@{
            pid             = $PID
            processName     = $(if ($null -ne $me) { [string]$me.ProcessName } else { $null })
            processStartUtc = $(if ($null -ne $start) { $start.ToString('o') } else { $null })
            command         = $Command
            amsNetId        = $(if ([string]::IsNullOrWhiteSpace($AmsNetId)) { $null } else { $AmsNetId.Trim() })
            requestedState  = $RequestedState
            step            = $Step
            startedAtUtc    = [DateTime]::UtcNow.ToString('o')
        }
        $base = Join-Path $dir ("{0}{1}.{2}" -f $script:TcLifecycleInflightPrefix, $PID, [guid]::NewGuid().ToString('N'))
        $tmp = "$base.tmp"
        $path = "$base.json"
        [IO.File]::WriteAllText($tmp, ($m | ConvertTo-Json -Compress))
        [IO.File]::Move($tmp, $path)
        $tmp = $null
        $path
    }
    catch {
        Write-Verbose "Enter-TcLifecycleInflight: marker not written ($($_.Exception.Message))"
        if ($null -ne $tmp) { try { [IO.File]::Delete($tmp) } catch { Write-Verbose "Enter-TcLifecycleInflight: $($_.Exception.Message)" } }
        $null
    }
}

function Exit-TcLifecycleInflight {
    param([string]$Token)
    if ([string]::IsNullOrWhiteSpace($Token)) { return }
    try { [IO.File]::Delete($Token) } catch { Write-Verbose "Exit-TcLifecycleInflight: $($_.Exception.Message)" }
}

function Get-TcLifecycleInflightOwnerState {
    <#
    .SYNOPSIS
        #236: 'alive' | 'gone' for the owner of an in-flight marker (-Marker; or only -ProcessId
        when the marker cannot be read: then the pid alone decides). 'gone' = no process with
        that pid, a process with another name (pid reused by another program; processName is
        recorded), or one whose start time differs by 2 s or more (pid reused; also for this
        process's own pid: a restarted bridge can get the pid of the killed one). Same name but
        the start time cannot be read (e.g. access denied to an elevated process): 'alive' by
        pid alone - a running request is never reported as interrupted.
    #>
    param($Marker, [int]$ProcessId = 0)
    $id = $ProcessId
    if ($null -ne $Marker) {
        $id = 0
        if (-not [int]::TryParse([string]$Marker.pid, [ref]$id) -or $id -le 0) { return 'gone' }
    }
    if ($id -le 0) { return 'gone' }
    $p = $null
    try { $p = Get-Process -Id $id -ErrorAction Stop } catch { return 'gone' }
    if ($null -eq $Marker) { return 'alive' }
    $name = if ($null -ne $Marker.PSObject.Properties['processName']) { [string]$Marker.processName } else { '' }
    if (-not [string]::IsNullOrWhiteSpace($name) -and $name -ne [string]$p.ProcessName) { return 'gone' }
    $start = $null
    try { $start = $p.StartTime.ToUniversalTime() } catch { return 'alive' }
    $want = ConvertTo-TcLifecycleUtc $Marker.processStartUtc
    if ($null -eq $want) { return 'alive' }   # start time unknown when written: trust the pid
    if ([Math]::Abs(($start - $want).TotalSeconds) -lt 2) { 'alive' } else { 'gone' }
}

function Get-TcLifecycleInflightFilePid {
    # pid from the file name lifecycle-inflight.<pid>.<guid>.json, else 0
    param([string]$Name)
    if ($Name -match '^lifecycle-inflight\.(\d+)\.[0-9a-fA-F]+\.json$') { return [int]$Matches[1] }
    0
}

function Sync-TcLifecycleInflight {
    <#
    .SYNOPSIS
        #236: promotes the in-flight markers of dead processes to lifecycle blocks (see the file
        header). Called by Get-TcLifecycleBlockEntries before it reads the state. Returns $null,
        or an error text when a marker whose owner is gone could not be promoted (lock not
        taken, state not writable) or the directory could not be listed: the caller then blocks
        every target (state-unreadable, fail closed) and the marker stays for the next check.
        Oldest marker first, so of the two markers a killed Enable-TcConfig leaves (its own and
        the nested Set-TcSystemState one) the outer command's record is written and the nested
        one is then older than that record and only removed. Check, write and marker removal run
        under the lifecycle block mutex in one step (two processes never promote the same marker
        twice). A marker that cannot be read is judged by the pid in its file name: alive ->
        left alone; gone -> a '<unknown>' record. Never throws.
    #>
    param([int]$TimeoutMs = 0)
    $files = @()
    try {
        $dir = Get-TcLifecycleInflightDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return $null }
        $files = @(Get-ChildItem -LiteralPath $dir -Filter ($script:TcLifecycleInflightPrefix + '*.json') -File -ErrorAction Stop)
    }
    catch { return "the in-flight markers of runtime-changing requests could not be listed ($($_.Exception.Message))" }
    if ($files.Count -eq 0) { return $null }
    $dead = @()
    foreach ($f in $files) {
        $m = $null
        try { $m = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($f.FullName)) -ErrorAction Stop } catch { $m = $null }
        if ($null -ne $m -and $m -isnot [System.Management.Automation.PSCustomObject]) { $m = $null }
        if ($null -eq $m -and -not (Test-Path -LiteralPath $f.FullName -PathType Leaf)) { continue }   # removed meanwhile (Exit)
        $owner = if ($null -ne $m) { Get-TcLifecycleInflightOwnerState -Marker $m } else { Get-TcLifecycleInflightOwnerState -ProcessId (Get-TcLifecycleInflightFilePid $f.Name) }
        if ($owner -eq 'alive') { continue }
        $t = if ($null -ne $m) { ConvertTo-TcLifecycleUtc $m.startedAtUtc } else { $null }
        $dead += [PSCustomObject]@{ File = $f.FullName; Name = $f.Name; Marker = $m; Started = $(if ($null -ne $t) { $t } else { [DateTime]::MinValue }) }
    }
    $errors = @()
    foreach ($d in @($dead | Sort-Object Started)) {
        try {
            $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -TimeoutMs $TimeoutMs -Body {
                if (-not (Test-Path -LiteralPath $d.File -PathType Leaf)) { return 'gone' }   # promoted by another process
                $st = Read-TcLifecycleBlockState
                $m = $d.Marker
                $netId = if ($null -ne $m) { [string]$m.amsNetId } else { $null }
                $key = ConvertTo-TcLifecycleKey $netId
                $existing = if ($st.ContainsKey($key)) { $st[$key] } else { $null }
                $exCreated = if ($null -ne $existing -and $null -ne $existing.PSObject.Properties['createdAtUtc']) { ConvertTo-TcLifecycleUtc $existing.createdAtUtc } else { $null }
                if ($null -ne $m -and $null -ne $exCreated -and $exCreated -ge $d.Started) {
                    [IO.File]::Delete($d.File)   # a newer record of this target exists: keep it
                    return 'kept'
                }
                $entry = if ($null -eq $m) {
                    [PSCustomObject]@{
                        amsNetId = $null; command = 'unknown'; errorCode = 'INTERRUPTED'
                        message = "An in-flight marker of a runtime-changing request ($($d.Name)) could not be read and its process is gone; the request may have changed the runtime of any target and was never read back."
                        requestedState = $null; reachedState = $null; readbackNote = $null; step = 'interrupted (unreadable in-flight marker)'
                        time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); createdAtUtc = [DateTime]::UtcNow.ToString('o')
                    }
                }
                else {
                    [PSCustomObject]@{
                        amsNetId = $(if ([string]::IsNullOrWhiteSpace($netId)) { $null } else { $netId.Trim() })
                        command = [string]$m.command; errorCode = 'INTERRUPTED'
                        message = "PID $($m.pid) ended (killed or crashed; e.g. the MCP bridge killed on IDE_MODAL_DIALOG / BRIDGE_TIMEOUT) while $($m.command) was waiting for its runtime-changing request (sent $($m.startedAtUtc) UTC); the runtime may have been changed and was never read back."
                        requestedState = [string]$m.requestedState; reachedState = $null; readbackNote = $null
                        step = "interrupted$(if ($m.step) { " in step '$($m.step)'" }) (process ended before the readback)"
                        time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'); createdAtUtc = [DateTime]::UtcNow.ToString('o')
                    }
                }
                $st[$key] = $entry
                Write-TcLifecycleBlockState -Entries $st
                [IO.File]::Delete($d.File)
                'promoted'
            }
            if ($null -eq $r -or -not $r.Locked -or $null -ne $r.Error) {
                $why = if ($null -eq $r) { 'no result' } elseif (-not $r.Locked) { 'lock not taken' } else { [string]$r.Error }
                $errors += "$($d.Name) ($why)"
            }
        }
        catch { $errors += "$($d.Name) ($($_.Exception.Message))" }
    }
    if ($errors.Count -gt 0) { return "in-flight marker(s) of an interrupted runtime-changing request could not be recorded as a lifecycle block: $($errors -join '; ')" }
    $null
}
