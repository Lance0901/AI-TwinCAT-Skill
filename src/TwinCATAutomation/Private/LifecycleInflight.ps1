# In-flight marker of a runtime-changing request (#236, fail closed #68).
#
# A lifecycle block is written by the command itself when it fails after its request went out
# (LifecycleBlock.ps1). That cannot happen when the PROCESS dies while the request is pending: the
# MCP server kills the PowerShell bridge when its modal probe sees a dialog (IDE_MODAL_DIALOG,
# e.g. "license not found" after ActivateConfiguration(), measured 2026-11-11 with VS2022 4026 +
# UmRT), on BRIDGE_TIMEOUT, on Ctrl+C or a crash. Without a record the next agent could run
# Enable-TcConfig again on a runtime that was left in Config.
#
# So right before the request is sent the command writes a marker file, and removes it when it
# returns (whatever the result; a failure writes its own block first):
#   <state dir>\lifecycle-inflight.<pid>.<guid>.json
#     { pid; processStartUtc; command; amsNetId; requestedState; step; startedAtUtc }
#   One file per request (nested commands, e.g. Enable-TcConfig -> Set-TcSystemState, each own one).
# Every lifecycle check (Get-TcLifecycleBlockEntries, in any process) first promotes the markers
# whose owner is gone - no process with that pid, or one with another start time (pid reused) -
# to a lifecycle block (errorCode INTERRUPTED, the marker's command / target / requested state).
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

function Test-TcLifecycleInflightOwnerAlive {
    param($Marker)
    $id = 0
    if (-not [int]::TryParse([string]$Marker.pid, [ref]$id) -or $id -le 0) { return $false }
    $start = Get-TcProcessStartUtc -ProcessId $id
    if ($null -eq $start) { return $false }
    $want = [string]$Marker.processStartUtc
    if ([string]::IsNullOrWhiteSpace($want)) { return $true }   # start time unknown when written: trust the pid
    $t = [DateTime]::MinValue
    if (-not [DateTime]::TryParse($want, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$t)) { return $false }
    [Math]::Abs(($start - $t.ToUniversalTime()).TotalSeconds) -lt 2
}

function Sync-TcLifecycleInflight {
    <#
    .SYNOPSIS
        #236: promotes the in-flight markers of dead processes to lifecycle blocks (see the file
        header). Called by Get-TcLifecycleBlockEntries before it reads the state. Never throws.
    #>
    try {
        $dir = Get-TcLifecycleInflightDir
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) { return }
        $files = @(Get-ChildItem -LiteralPath $dir -Filter ($script:TcLifecycleInflightPrefix + '*.json') -File -ErrorAction SilentlyContinue)
    }
    catch { return }
    foreach ($f in $files) {
        try {
            $m = $null
            try { $m = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText($f.FullName)) -ErrorAction Stop } catch { $m = $null }
            if ($null -ne $m -and $m -isnot [System.Management.Automation.PSCustomObject]) { $m = $null }
            if ($null -ne $m -and [string]$m.pid -eq [string]$PID) { continue }   # own request, still running here
            if ($null -ne $m -and (Test-TcLifecycleInflightOwnerAlive $m)) { continue }
            if ($null -eq $m) {
                $b = Set-TcLifecycleBlock -AmsNetId $null -Command 'unknown' -ErrorCode 'INTERRUPTED' -Step 'interrupted (unreadable in-flight marker)' `
                    -Message "An in-flight marker of a runtime-changing request ($($f.Name)) could not be read; the request may have changed the runtime of any target and was never read back."
            }
            else {
                $netId = [string]$m.amsNetId
                # a record of this target written after the marker started is newer: keep it
                $existing = $null
                try {
                    $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -Body { Read-TcLifecycleBlockState }
                    if ($r.Locked -and $null -eq $r.Error -and $null -ne $r.Result) {
                        $k = ConvertTo-TcLifecycleKey $netId
                        if ($r.Result.ContainsKey($k)) { $existing = $r.Result[$k] }
                    }
                }
                catch { $existing = $null }
                if ($null -ne $existing -and -not [string]::IsNullOrWhiteSpace([string]$existing.createdAtUtc) -and [string]$existing.createdAtUtc -ge [string]$m.startedAtUtc) {
                    [IO.File]::Delete($f.FullName)
                    continue
                }
                $b = Set-TcLifecycleBlock -AmsNetId $netId -Command ([string]$m.command) -ErrorCode 'INTERRUPTED' -RequestedState ([string]$m.requestedState) `
                    -Step "interrupted$(if ($m.step) { " in step '$($m.step)'" }) (process ended before the readback)" `
                    -Message "PID $($m.pid) ended (killed or crashed; e.g. the MCP bridge killed on IDE_MODAL_DIALOG / BRIDGE_TIMEOUT) while $($m.command) was waiting for its runtime-changing request (sent $($m.startedAtUtc) UTC); the runtime may have been changed and was never read back."
            }
            if ($null -eq $b.PSObject.Properties['stateWarning']) { [IO.File]::Delete($f.FullName) }
        }
        catch { Write-Verbose "Sync-TcLifecycleInflight: $($f.Name): $($_.Exception.Message)" }
    }
}
