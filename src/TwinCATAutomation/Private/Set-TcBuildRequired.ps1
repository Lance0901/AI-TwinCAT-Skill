# "Build required after a platform switch" (BUILD_REQUIRED, #45 / PR #44 review).
# Set-TcSolutionPlatform records an entry whenever the active solution platform changed;
# Build-TcProject removes it after a complete success (no skipped PLC project); Enable-TcConfig
# refuses to activate while an entry applies.
#
# Where the state lives - fail-closed everywhere:
#   - a FILE, so it survives Import-Module -Force, one-process-per-call CLI use and a restarted
#     MCP bridge:  <dir>\build-required.json  { "<normalized .sln path>": { solution; reason; at }, ... }
#     <dir> = $env:TCAUTO_STATE_DIR (tests) or %TEMP%\TwinCATAutomation
#   - plus an in-memory copy ($script:TcBuildRequiredLocal) of every entry this module instance
#     recorded: when the file cannot be written (another process or a virus scanner holds it
#     open) the entry still blocks in this process; Get-TcBuildRequired merges both.
#   - read-modify-write runs under a named mutex (Local\TwinCATAutomation.BuildRequired.<hash of
#     the state directory>, so test directories do not share it), timeout
#     $script:TcBuildRequiredLockTimeoutMs. Without the lock: Set keeps the in-memory entry and
#     returns a warning, Clear changes nothing in the file, Get blocks.
#   - the file is replaced with [IO.File]::Replace (no window without a file); [IO.File]::Move
#     only when it does not exist yet. Short retries; on failure the .tmp is removed and the
#     caller gets a warning (Set-TcSolutionPlatform -> data.warning of Set-TcTarget /
#     Enable-TcConfig).
#   - a file that cannot be parsed is renamed to build-required.json.corrupt-<time> and replaced
#     by a '<corrupt>' entry that blocks every solution and is removed only by hand (it may have
#     held entries of other solutions); see docs/troubleshooting.md "BUILD_REQUIRED".
# Keys: one entry per solution (full path, lower case; may contain non-ASCII characters, the file
# is UTF-8). A switch while no solution path is known goes to '<unknown>', which blocks every
# solution; Enable-TcConfig without a known solution path is blocked by any entry. '<unknown>' is
# removed by any complete Build-TcProject success, whatever solution is open: the trade-off
# accepted here, because '<unknown>' can only come from a session that never knew its .sln (the
# build that follows the switch is normally in that same solution), and keeping it until manual
# removal would block every other solution for good.
#
# Windows PowerShell 5.1; this source file is ASCII.

$script:TcUnknownSolutionKey = '<unknown>'
$script:TcCorruptStateKey = '<corrupt>'
$script:TcBuildRequiredLocal = @{}
$script:TcBuildRequiredLockTimeoutMs = 3000

function Get-TcBuildRequiredFile {
    $dir = $env:TCAUTO_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path ([IO.Path]::GetTempPath()) 'TwinCATAutomation' }
    Join-Path $dir 'build-required.json'
}

function ConvertTo-TcSolutionKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $script:TcUnknownSolutionKey }
    $p = $Path.Trim()
    try { $p = [IO.Path]::GetFullPath($p) } catch { }
    return $p.TrimEnd('\', '/').ToLowerInvariant()
}

# Runs $Body under the named mutex of the state directory. Returns @{ Locked; Result; Error }.
function Invoke-TcBuildRequiredLocked {
    param([scriptblock]$Body)
    $dir = (Split-Path -Parent (Get-TcBuildRequiredFile)).ToLowerInvariant()
    $sha = [Security.Cryptography.SHA1]::Create()
    $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($dir))[0..7] | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()
    $mutex = New-Object System.Threading.Mutex($false, "Local\TwinCATAutomation.BuildRequired.$hash")
    $got = $false
    try {
        try { $got = $mutex.WaitOne($script:TcBuildRequiredLockTimeoutMs) }
        catch [System.Threading.AbandonedMutexException] { $got = $true }
        if (-not $got) { return @{ Locked = $false; Result = $null; Error = "lock not acquired within $($script:TcBuildRequiredLockTimeoutMs) ms" } }
        try { return @{ Locked = $true; Result = (& $Body); Error = $null } }
        catch { return @{ Locked = $true; Result = $null; Error = $_.Exception.Message } }
    }
    finally {
        if ($got) { try { $mutex.ReleaseMutex() } catch { } }
        $mutex.Dispose()
    }
}

# Under the lock. Returns @{ Entries = hashtable } ; a corrupt file is renamed and replaced by a
# '<corrupt>' entry (written back right away).
function Read-TcBuildRequiredState {
    $file = Get-TcBuildRequiredFile
    $entries = @{}
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return @{ Entries = $entries } }
    $text = [IO.File]::ReadAllText($file)
    try {
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop
            foreach ($p in $obj.PSObject.Properties) { $entries[$p.Name] = $p.Value }
        }
        return @{ Entries = $entries }
    }
    catch {
        $why = $_.Exception.Message
        $kept = "$file.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))"
        try { [IO.File]::Move($file, $kept) } catch { $kept = "(not renamed: $($_.Exception.Message))" }
        $entries = @{}
        $entries[$script:TcCorruptStateKey] = [PSCustomObject]@{
            solution = ''
            reason   = "the BUILD_REQUIRED state file could not be read ($why); kept as $kept; remove this entry by hand once every solution has been built (docs/troubleshooting.md BUILD_REQUIRED)"
            at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        Write-TcBuildRequiredState -Entries $entries
        return @{ Entries = $entries }
    }
}

# Under the lock. Throws when the file cannot be replaced after the retries (the .tmp is removed).
function Write-TcBuildRequiredState {
    param([hashtable]$Entries)
    $file = Get-TcBuildRequiredFile
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $last = $null
    for ($i = 1; $i -le 5; $i++) {
        $tmp = "$file.$PID.tmp"
        try {
            if ($Entries.Count -eq 0) {
                if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
                return
            }
            $o = [ordered]@{}
            foreach ($k in ($Entries.Keys | Sort-Object)) { $o[$k] = $Entries[$k] }
            [IO.File]::WriteAllText($tmp, ([PSCustomObject]$o | ConvertTo-Json -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
            if (Test-Path -LiteralPath $file) { [IO.File]::Replace($tmp, $file, [NullString]::Value) }
            else { [IO.File]::Move($tmp, $file) }
            return
        }
        catch {
            $last = $_.Exception.Message
            try { if (Test-Path -LiteralPath $tmp) { [IO.File]::Delete($tmp) } } catch { }
            Start-Sleep -Milliseconds (50 * $i)
        }
    }
    throw "could not write ${file}: $last"
}

function Set-TcBuildRequired {
    <#
    .SYNOPSIS
        Records that the solution platform of the current solution ($script:TcSolutionPath)
        changed and a complete Build-TcProject success is needed before Enable-TcConfig
        activates. Never throws: returns $null, or a warning text when only the in-memory
        record could be kept (the file could not be locked or written).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Reason)
    $key = ConvertTo-TcSolutionKey $script:TcSolutionPath
    $entry = [PSCustomObject]@{
        solution = [string]$script:TcSolutionPath
        reason   = $Reason
        at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    $script:TcBuildRequiredLocal[$key] = $entry
    $r = Invoke-TcBuildRequiredLocked -Body {
        $st = Read-TcBuildRequiredState
        $st.Entries[$key] = $entry
        Write-TcBuildRequiredState -Entries $st.Entries
    }
    if ($r.Locked -and $null -eq $r.Error) { return $null }
    $w = "BUILD_REQUIRED was recorded in this process only, not in $(Get-TcBuildRequiredFile) ($($r.Error)): another process (or an MCP bridge restart) will not see it; run Build-TcProject before Enable-TcConfig."
    Write-Warning $w
    return $w
}

function Clear-TcBuildRequired {
    <#
    .SYNOPSIS
        Removes the entry of the current solution and the '<unknown>' entry (see the file
        header) from memory and from the file. The '<corrupt>' entry stays. Never throws:
        returns $null or a warning text (the file still blocks then: fail-closed).
    #>
    [CmdletBinding()]
    param()
    $key = ConvertTo-TcSolutionKey $script:TcSolutionPath
    $null = $script:TcBuildRequiredLocal.Remove($key)
    $null = $script:TcBuildRequiredLocal.Remove($script:TcUnknownSolutionKey)
    $r = Invoke-TcBuildRequiredLocked -Body {
        $st = Read-TcBuildRequiredState
        $null = $st.Entries.Remove($key)
        $null = $st.Entries.Remove($script:TcUnknownSolutionKey)
        Write-TcBuildRequiredState -Entries $st.Entries
    }
    if ($r.Locked -and $null -eq $r.Error) { return $null }
    $w = "Clear-TcBuildRequired: $(Get-TcBuildRequiredFile) not updated ($($r.Error)); Enable-TcConfig stays blocked until a later Build-TcProject can update it."
    Write-Warning $w
    return $w
}

function Get-TcBuildRequired {
    <#
    .SYNOPSIS
        The entry that blocks activation of the current solution, or $null. File and
        in-memory entries are merged; then: the '<corrupt>' entry, the solution's own entry,
        the '<unknown>' entry, any entry when no solution path is known. Lock or read
        failure -> a synthetic blocking entry (fail-closed).
    #>
    [CmdletBinding()]
    param()
    $r = Invoke-TcBuildRequiredLocked -Body { (Read-TcBuildRequiredState).Entries }
    if (-not $r.Locked -or $null -ne $r.Error) {
        return [PSCustomObject]@{ solution = [string]$script:TcSolutionPath; reason = "the BUILD_REQUIRED state could not be checked ($($r.Error))"; at = $null }
    }
    $entries = @{}
    foreach ($k in $r.Result.Keys) { $entries[$k] = $r.Result[$k] }
    foreach ($k in $script:TcBuildRequiredLocal.Keys) { $entries[$k] = $script:TcBuildRequiredLocal[$k] }
    if ($entries.Count -eq 0) { return $null }
    if ($entries.ContainsKey($script:TcCorruptStateKey)) { return $entries[$script:TcCorruptStateKey] }
    $key = ConvertTo-TcSolutionKey $script:TcSolutionPath
    if ($entries.ContainsKey($key)) { return $entries[$key] }
    if ($entries.ContainsKey($script:TcUnknownSolutionKey)) { return $entries[$script:TcUnknownSolutionKey] }
    if ($key -eq $script:TcUnknownSolutionKey) { return @($entries.Values)[0] }
    return $null
}
