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

function Read-TcIdeSolutionRecords {
    [CmdletBinding()]
    param()
    $path = Get-TcIdeSolutionRecordPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    # PS 5.1 ConvertFrom-Json emits a JSON array as ONE object: unroll it.
    try { $parsed = Get-Content -LiteralPath $path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop; return @($parsed | ForEach-Object { $_ } | Where-Object { $null -ne $_ }) }
    catch { Write-Verbose "IDE solution records unreadable ($($_.Exception.Message))"; return @() }
}

function Test-TcIdeRecordAlive {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Record)
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
        $keep = @(Read-TcIdeSolutionRecords | Where-Object { [int]$_.pid -ne $ProcessId -and (Test-TcIdeRecordAlive -Record $_) })
        $keep += [PSCustomObject]@{ pid = $ProcessId; startTime = $start; solution = $Solution }
        Write-TcIdeSolutionRecords -Records $keep
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
    $tmp = "$path.$PID.tmp"
    Set-Content -LiteralPath $tmp -Value (ConvertTo-Json -InputObject @($Records) -Depth 3) -Encoding UTF8
    try { Move-Item -LiteralPath $tmp -Destination $path -Force -ErrorAction Stop }
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
        $all = @(Read-TcIdeSolutionRecords)
        if (-not @($all | Where-Object { [int]$_.pid -eq $ProcessId })) { return }
        Write-TcIdeSolutionRecords -Records @($all | Where-Object { [int]$_.pid -ne $ProcessId -and (Test-TcIdeRecordAlive -Record $_) })
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