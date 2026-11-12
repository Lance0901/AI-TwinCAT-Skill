# #233: the ITcAutomationSettings.SilentMode value an IDE process had before this module first set
# it to true. Kept in memory AND in <Get-TcStateDir>\silent-originals.json, so a later PowerShell
# process (a new agent tool call, a restarted MCP bridge, ReloadModule) that connects to the same IDE
# still restores the real original instead of the true it finds there:
#   [ { pid; startTime (UTC 'o', the IDE process start time); imageName (process name, no .exe);
#       original (true | false | 'unknown' = the getter failed | 'assumed-false' = it read true without
#       a record: unknown, restored to false); recordedAt (UTC 'o') } ]
# Key = pid + start time (Get-TcIdeProcessKey): a recycled pid never matches. A record whose process
# is gone (or runs with another start time) is dropped on every write (Test-TcLaunchRecordStale).
# Writes go to a temp file + replace (Write-TcIdeSolutionRecords) under a named mutex (one name per
# TCAUTO_STATE_DIR, like launched-ides.json).
# Fail closed: a file that cannot be read (unreadable / corrupt) gives "no record" plus
# $script:TcSilentOriginalWarning; Connect-TcIde then treats a SilentMode it reads as true as an
# UNKNOWN original (never as the original, data.silentModeOriginalUnknown) and Disconnect-TcIde
# restores false (see Connect-TcIde). A write that fails keeps the value in memory for this process
# (same warning): a later process then sees "no record" -> unknown -> false again, never "true".

$script:TcSilentOriginalLockName = 'Local\TwinCATAutomation-silent-originals'
$script:TcSilentOriginalLockTimeoutMs = 2000

function Get-TcSilentOriginalPath { Join-Path (Get-TcStateDir) 'silent-originals.json' }

function Get-TcSilentOriginalLockName {
    if ([string]::IsNullOrWhiteSpace($env:TCAUTO_STATE_DIR)) { return $script:TcSilentOriginalLockName }
    "$($script:TcSilentOriginalLockName).$(((Get-TcBuildRequiredMutexName) -split '\.')[-1])"
}

# The record of IDE process -ProcessId in the file (same pid AND start time), or $null.
function Find-TcSilentOriginalRecord {
    [CmdletBinding()]
    param([object[]]$Records, [Parameter(Mandatory)][int]$ProcessId, [Parameter(Mandatory)][string]$StartTime)
    foreach ($r in @($Records)) {
        try {
            if ([int]$r.pid -ne $ProcessId) { continue }
            if ((ConvertTo-TcUtcDate $r.startTime).ToString('o') -ne $StartTime) { continue }
            return $r
        }
        catch { continue }
    }
    $null
}

function Get-TcIdeSilentOriginal {
    <#
    .SYNOPSIS
        The SilentMode value IDE process -ProcessId had before this module first set it: $true /
        $false, 'unknown' when it could not be read then, 'assumed-false' when it read true without a
        record (unknown; Disconnect-TcIde restores false), or $null when there is no record (this
        process' memory first, then silent-originals.json, #233).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return $null }
    if ($null -ne $script:TcSilentOriginals -and $script:TcSilentOriginals.ContainsKey($key)) {
        $v = $script:TcSilentOriginals[$key]
        if ($v -is [string]) { return [string]$v }
        return [bool]$v
    }
    $file = $null
    try { $file = Read-TcIdeSolutionRecordFile -Path (Get-TcSilentOriginalPath) }
    catch { $file = @{ State = 'unreadable'; Records = @(); Error = $_.Exception.Message } }
    if ($file.State -in 'unreadable', 'corrupt') {
        $script:TcSilentOriginalWarning = "SilentMode originals $($file.State) ($($file.Error)); no original is taken from them"
        Write-Verbose $script:TcSilentOriginalWarning
        return $null
    }
    $rec = Find-TcSilentOriginalRecord -Records $file.Records -ProcessId $ProcessId -StartTime (($key -split '\|', 2)[1])
    if ($null -eq $rec) { return $null }
    $o = $rec.original
    $value = if ($o -is [bool]) { [bool]$o } elseif ([string]$o -in 'unknown', 'assumed-false') { [string]$o } else { $null }
    if ($null -eq $value) { return $null }   # malformed: no record
    if ($null -eq $script:TcSilentOriginals) { $script:TcSilentOriginals = @{} }
    $script:TcSilentOriginals[$key] = $value
    $value
}

function Set-TcIdeSilentOriginal {
    <#
    .SYNOPSIS
        Remembers (-Value $true / $false / 'unknown' / 'assumed-false') or forgets ($null) the SilentMode original of
        IDE process -ProcessId, in memory and in silent-originals.json. Returns $null or the reason
        the file could not be written (also in $script:TcSilentOriginalWarning); never throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId, [Parameter()][AllowNull()][object]$Value)
    $key = Get-TcIdeProcessKey -ProcessId $ProcessId
    if ($null -eq $key) { return $null }
    if ($null -eq $script:TcSilentOriginals) { $script:TcSilentOriginals = @{} }
    $stored = $null
    if ($null -eq $Value) { $script:TcSilentOriginals.Remove($key) }
    elseif ($Value -is [string]) { $stored = $(if ([string]$Value -eq 'assumed-false') { 'assumed-false' } else { 'unknown' }); $script:TcSilentOriginals[$key] = $stored }
    else { $stored = [bool]$Value; $script:TcSilentOriginals[$key] = $stored }

    $start = ($key -split '\|', 2)[1]
    $image = $null
    try { $image = [string](Get-Process -Id $ProcessId -ErrorAction Stop).ProcessName } catch { $image = $null }
    $failure = $null
    try {
        $path = Get-TcSilentOriginalPath
        $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcSilentOriginalLockName) -TimeoutMs $script:TcSilentOriginalLockTimeoutMs -Body {
            $file = Read-TcIdeSolutionRecordFile -Path $path
            $all = @()
            switch ($file.State) {
                'unreadable' { throw "records not read, nothing written ($($file.Error))" }
                'corrupt' {
                    $kept = "$path.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))"
                    try { [IO.File]::Move($path, $kept) } catch { throw "corrupt records not moved aside, nothing written ($($_.Exception.Message))" }
                    Write-Verbose "SilentMode originals corrupt ($($file.Error)); kept as $kept"
                }
                default { $all = @($file.Records | Where-Object { -not (Test-TcLaunchRecordStale -Record $_) }) }
            }
            $mine = Find-TcSilentOriginalRecord -Records $all -ProcessId $ProcessId -StartTime $start
            $new = @($all | Where-Object { -not [object]::ReferenceEquals($_, $mine) })
            if ($null -ne $stored) {
                $new += [PSCustomObject][ordered]@{ pid = $ProcessId; startTime = $start; imageName = $image; original = $stored; recordedAt = [DateTime]::UtcNow.ToString('o') }
            }
            Write-TcIdeSolutionRecords -Path $path -Records $new
        }
        if (-not $r.Locked) { $failure = "SilentMode original not saved ($($r.Error))" }
        elseif ($r.Error) { $failure = "SilentMode original not saved ($($r.Error))" }
    }
    catch { $failure = "SilentMode original not saved ($($_.Exception.Message))" }
    if ($null -ne $failure) { $script:TcSilentOriginalWarning = $failure; Write-Verbose $failure }
    $failure
}
