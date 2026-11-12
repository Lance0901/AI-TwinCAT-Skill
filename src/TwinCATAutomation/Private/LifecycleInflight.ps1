# In-flight marker of a runtime-changing request (#236, fail closed #68).
#
# A lifecycle block is written by the command itself when it fails after its request went out
# (LifecycleBlock.ps1). That cannot happen when the PROCESS dies while the request is pending: the
# MCP server kills the PowerShell bridge when its modal probe sees a dialog (IDE_MODAL_DIALOG,
# e.g. "license not found" after ActivateConfiguration(), measured 2026-11-11 with VS2022 4026 +
# UmRT), on BRIDGE_TIMEOUT or a crash. Without a record the next agent could run
# Enable-TcConfig again on a runtime that was left in Config. (A stopped pipeline - Ctrl+C - skips
# catch but runs finally: Enable-TcConfig records INTERRUPTED there itself; Set-TcSystemState
# does not cover that case.)
#
# So right before the request is sent the command writes a marker file, and removes it when it
# returns (whatever the result; a failure writes its own block first):
#   <state dir>\lifecycle-inflight.<pid>.<guid>.json
#     { pid; processStartUtc; command; amsNetId; requestedState; step; startedAtUtc }
#   One file per request (nested commands, e.g. Enable-TcConfig -> Set-TcSystemState, each own one).
# Every lifecycle check (Get-TcLifecycleBlockEntries, in any process) first promotes the markers
# whose owner is gone - no process with that pid, or one with another start time (pid reused,
# also this process' own pid) - to a lifecycle block (errorCode INTERRUPTED, the marker's command / target / requested state).
# A record of the same target created after the marker started is newer and kept as it is. An
# unreadable marker becomes a '<unknown>' record (blocks every target). The marker file is removed
# only once the block is in the state file; otherwise it stays and is promoted again next time.
# Markers of live processes (another bridge in the middle of its request) are left alone.
#
# Never throws. Windows PowerShell 5.1; ASCII source.

$script:TcLifecycleInflightPrefix = 'lifecycle-inflight.'

function Get-TcLifecycleInflightDir {
    Split-Path -Parent (Get-TcLifecycleBlockFile)
}

function Get-TcProcessStartUtc {
    param([int]$ProcessId)
    try { (Get-Process -Id $ProcessId -ErrorAction Stop).StartTime.ToUniversalTime() } catch { $null }
}

function Enter-TcLifecycleInflight {
    <#
    .SYNOPSIS
        #236: writes the in-flight marker of a runtime-changing request; returns its path (the
        token for Exit-TcLifecycleInflight) or $null when it could not be written (Write-Verbose;
        the command still runs: the in-process failure paths keep writing their own block).
    #>
    param([Parameter(Mandatory)][string]$Command, [string]$AmsNetId, [string]$RequestedState, [string]$Step)
    try {
        $dir = Get-TcLifecycleInflightDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { $null = New-Item -ItemType Directory -Force -Path $dir }
        $start = Get-TcProcessStartUtc -ProcessId $PID
        $m = [PSCustomObject]@{
            pid             = $PID
            processStartUtc = $(if ($null -ne $start) { $start.ToString('o') } else { $null })
            command         = $Command
            amsNetId        = $(if ([string]::IsNullOrWhiteSpace($AmsNetId)) { $null } else { $AmsNetId.Trim() })
            requestedState  = $RequestedState
            step            = $Step
            startedAtUtc    = [DateTime]::UtcNow.ToString('o')
        }
        $path = Join-Path $dir ("{0}{1}.{2}.json" -f $script:TcLifecycleInflightPrefix, $PID, [guid]::NewGuid().ToString('N'))
        [IO.File]::WriteAllText($path, ($m | ConvertTo-Json -Compress))
        $path
    }
    catch {
        Write-Verbose "Enter-TcLifecycleInflight: marker not written ($($_.Exception.Message))"
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
        #236: 'alive' | 'gone' for the owner of an in-flight marker. 'gone' = no process with that
        pid, or one whose start time differs by 2 s or more (pid reused; also for this process'
        own pid: a restarted bridge can get the pid of the killed one). A process whose start
        time cannot be read (e.g. access denied to an elevated process) counts as 'alive' by pid
        alone: a running request is never reported as interrupted.
    #>
    param($Marker)
    $id = 0
    if (-not [int]::TryParse([string]$Marker.pid, [ref]$id) -or $id -le 0) { return 'gone' }
    $p = $null
    try { $p = Get-Process -Id $id -ErrorAction Stop } catch { return 'gone' }
    $start = $null
    try { $start = $p.StartTime.ToUniversalTime() } catch { return 'alive' }
    $want = ConvertTo-TcLifecycleUtc $Marker.processStartUtc
    if ($null -eq $want) { return 'alive' }   # start time unknown when written: trust the pid
    if ([Math]::Abs(($start - $want).TotalSeconds) -lt 2) { 'alive' } else { 'gone' }
}

function Sync-TcLifecycleInflight {
    <#
    .SYNOPSIS
        #236: promotes the in-flight markers of dead processes to lifecycle blocks (see the file
        header). Called by Get-TcLifecycleBlockEntries before it reads the state. Oldest marker
        first, so of the two markers a killed Enable-TcConfig leaves (its own and the nested
        Set-TcSystemState one) the outer command's record is written and the nested one is then
        older than that record and only removed. Check, write and marker removal run under the
        lifecycle block mutex in one step (two processes never promote the same marker twice).
        Lock not taken -> nothing changes, the marker stays for the next check. Never throws.
    #>
    param([int]$TimeoutMs = 0)
    try {
        $dir = Get-TcLifecycleInflightDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
        $files = @(Get-ChildItem -LiteralPath $dir -Filter ($script:TcLifecycleInflightPrefix + '*.json') -File -ErrorAction SilentlyContinue)
    }
    catch { return }
    if ($files.Count -eq 0) { return }
    $dead = @()
    foreach ($f in $files) {
        $m = $null
        try { $m = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($f.FullName)) -ErrorAction Stop } catch { $m = $null }
        if ($null -ne $m -and $m -isnot [System.Management.Automation.PSCustomObject]) { $m = $null }
        if ($null -ne $m -and (Get-TcLifecycleInflightOwnerState $m) -eq 'alive') { continue }
        $t = if ($null -ne $m) { ConvertTo-TcLifecycleUtc $m.startedAtUtc } else { $null }
        $dead += [PSCustomObject]@{ File = $f.FullName; Name = $f.Name; Marker = $m; Started = $(if ($null -ne $t) { $t } else { [DateTime]::MinValue }) }
    }
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
                        message = "An in-flight marker of a runtime-changing request ($($d.Name)) could not be read; the request may have changed the runtime of any target and was never read back."
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
            if (-not $r.Locked -or $null -ne $r.Error) { Write-Verbose "Sync-TcLifecycleInflight: $($d.Name) not promoted now ($($r.Error)); kept for the next check" }
        }
        catch { Write-Verbose "Sync-TcLifecycleInflight: $($d.Name): $($_.Exception.Message)" }
    }
}
