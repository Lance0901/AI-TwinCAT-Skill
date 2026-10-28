# "A complete build is required before the PLC output is used" (BUILD_REQUIRED, #45 / PR #44 /
# #56). One entry per solution; an entry carries one reason per KIND:
#   platform-switch   Set-TcSolutionPlatform: the active solution platform changed (the compiled
#                     output may still be that of the previous platform; inferred, not measured)
#   unverified-build  Build-TcProject (#56): the last build of this solution finished without a
#                     complete success - LIBRARY_UNRESOLVED (also when accepted with
#                     -AllowUnresolvedLibrary, #61), BUILD_FAILED, BUILD_STATUS_UNKNOWN, BUILD_COVERAGE_UNKNOWN after the build,
#                     or success with data.completeBuild = $false. Activate and Login compile by
#                     themselves (InfoSys "Command Login":
#                     https://infosys.beckhoff.com/content/1033/tc3_plc_intro/2531393419.html), but
#                     nobody checks that compile: measured 2026-10-26 (TcXaeShell 4024, TwinCAT_Festo
#                     copy with 7 unresolved libraries, local UmRT): Enable-TcConfig -Force after a
#                     LIBRARY_UNRESOLVED build activated, downloaded and returned success without a
#                     warning (#56 point 5).
#   code-changed      (#65) a cmdlet changed the PLC code or the PLC project in the IDE after the
#                     last complete build: Write-TcPouCode, Add-TcPou, Add-TcDut, Add-TcGvl,
#                     Add-TcLibrary, New-TcProject, Reset-TcSolution (reloaded from disk). Activate
#                     and Login would compile that change without a check (same InfoSys page).
#                     Recorded through Register-TcCodeChange; the reason lists which cmdlet
#                     changed which object ('PLC code changed by Write-TcPouCode MAIN [...] | ...',
#                     the last $script:TcCodeChangedMaxItems changes, older ones counted).
# The kinds of one entry are kept side by side (reasons); the entry's 'kind' is the first of
# $script:TcBuildRequiredKinds that it has, so a later code-changed never hides a platform switch
# or an unverified build.
# Build-TcProject removes the whole entry after a complete success (data.completeBuild:
# coverageComplete and codeVerified = $true; never a build accepted with -AllowUnresolvedLibrary, #61);
# Enable-TcConfig (before Activate) and Enter-TcPlcOnline (before Login) refuse while an entry
# applies. A solution that was never built or changed through the module has no entry: Activate /
# Login then compile without a check (known limit, docs/troubleshooting.md BUILD_REQUIRED).
#
# Where the state lives - fail-closed everywhere:
#   - a FILE, so it survives Import-Module -Force, one-process-per-call CLI use and a restarted
#     MCP bridge:  <dir>\build-required.json
#       { "<normalized .sln path>": { solution; kind; reason; reasons { <kind>: text }; at }, ... }
#     <dir> = $env:TCAUTO_STATE_DIR (tests) or %TEMP%\TwinCATAutomation. Entries written before
#     #56 have no kind / reasons: read as kind 'platform-switch'.
#   - plus an in-memory copy ($script:TcBuildRequiredLocal) of every entry this module instance
#     recorded: when the file cannot be written (another process or a virus scanner holds it
#     open) the entry still blocks in this process; Get-TcBuildRequired merges both. The memory
#     entry can block LONGER than the file: it is removed only by a complete Build-TcProject in
#     this process (or a new process / MCP bridge restart), even when the file entry was removed
#     by hand or by another process.
#   - read-modify-write runs under a named mutex, timeout $script:TcBuildRequiredLockTimeoutMs:
#     'Local\TwinCATAutomation.BuildRequired' for the default directory (a fixed name: %TEMP% may
#     be spelled with 8.3 short names in one process and long names in another), and
#     'Local\TwinCATAutomation.BuildRequired.<hash of the full TCAUTO_STATE_DIR path>' when the
#     directory is overridden (tests; full path with 8.3 names expanded, Get-TcLongPath).
#     A process WITH TCAUTO_STATE_DIR and one WITHOUT it use DIFFERENT mutexes even when the
#     variable points at the default %TEMP%\TwinCATAutomation directory: do not mix the two
#     for one state directory.
#     A 'Local\' mutex only serialises processes of the SAME logon session; a process in another
#     session (another user, a service in session 0) is not locked out: the file replace stays
#     atomic, but a concurrent read-modify-write from there can lose one update.
#     Without the lock: Set keeps the in-memory entry and returns a warning, Clear changes
#     nothing in the file, Get blocks.
#   - the file is replaced with [IO.File]::Replace (no window without a file); [IO.File]::Move
#     only when it does not exist yet. Short retries; on failure the .tmp is removed and the
#     caller gets a warning (Set-TcSolutionPlatform -> data.warning of Set-TcTarget /
#     Enable-TcConfig; Build-TcProject -> data.stateWarning).
#   - a file that cannot be parsed is replaced in ONE step ([IO.File]::Replace(tmp, file,
#     build-required.json.corrupt-<time>)) by a '<corrupt>' entry that blocks every solution and
#     is removed only by hand (it may have held entries of other solutions); when that replace
#     fails the unreadable file stays as it is and every Get blocks (lock/read failure). See
#     docs/troubleshooting.md "BUILD_REQUIRED".
# Keys: one entry per solution (full path with 8.3 short names expanded through GetLongPathName
# on the longest existing ancestor, lower case; may contain non-ASCII characters, the file is
# UTF-8). Connect-TcIde keeps the path the user gave, so 'C:\Users\RUNNER~1\x\Demo.sln' and the
# long spelling must give the same key, else a refusal would fail open (#56 review S3). A record while no solution path is known goes to '<unknown>', which blocks every
# solution; Enable-TcConfig / Enter-TcPlcOnline without a known solution path are blocked by any
# entry. '<unknown>' is removed by any complete Build-TcProject success, whatever solution is
# open: the trade-off accepted here, because '<unknown>' can only come from a session that never
# knew its .sln (the build that follows is normally in that same solution), and keeping it until
# manual removal would block every other solution for good.
#
# Windows PowerShell 5.1; this source file is ASCII.

$script:TcUnknownSolutionKey = '<unknown>'
$script:TcCorruptStateKey = '<corrupt>'
$script:TcBuildRequiredLocal = @{}
$script:TcBuildRequiredLockTimeoutMs = 3000
# Order in which the reasons of one entry are reported; the first one an entry has is its 'kind'.
$script:TcBuildRequiredKinds = @('platform-switch', 'unverified-build', 'code-changed')
# code-changed reason: at most this many changes are listed, older ones are counted (#65).
$script:TcCodeChangedPrefix = 'PLC code changed by '
$script:TcCodeChangedMaxItems = 8
$script:TcCodeChangedSeparator = ' | '

function Get-TcBuildRequiredFile {
    $dir = $env:TCAUTO_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { $dir = Join-Path ([IO.Path]::GetTempPath()) 'TwinCATAutomation' }
    Join-Path $dir 'build-required.json'
}

# Name of the mutex that guards the state file (see the file header).
function Get-TcBuildRequiredMutexName {
    $dir = $env:TCAUTO_STATE_DIR
    if ([string]::IsNullOrWhiteSpace($dir)) { return 'Local\TwinCATAutomation.BuildRequired' }
    $full = (Get-TcLongPath $dir).TrimEnd('\', '/').ToLowerInvariant()
    $sha = [Security.Cryptography.SHA1]::Create()
    try { $hash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($full))[0..7] | ForEach-Object { $_.ToString('x2') }) }
    finally { $sha.Dispose() }
    "Local\TwinCATAutomation.BuildRequired.$hash"
}

# Win32 GetLongPathName (kernel32): expands 8.3 short names (C:\Users\RUNNER~1\...). Only works
# for a path that exists; Get-TcLongPath applies it to the longest existing ancestor.
if ($null -eq ([System.Management.Automation.PSTypeName]'TwinCATAutomation.TcLongPathNative').Type) {
    Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
using System.Text;
namespace TwinCATAutomation {
    public static class TcLongPathNative {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetLongPathName(string shortPath, StringBuilder longPath, uint size);
        public static string Get(string p) {
            var sb = new StringBuilder(1024);
            uint n = GetLongPathName(p, sb, (uint)sb.Capacity);
            if (n > sb.Capacity) { sb = new StringBuilder((int)n); n = GetLongPathName(p, sb, (uint)sb.Capacity); }
            return (n > 0 && n <= sb.Capacity) ? sb.ToString() : null;
        }
    }
}
'@
}

# Full path with every 8.3 short name expanded (#56 review S3: Connect-TcIde stores the path the
# user gave, which may be a short name, and the same .sln must map to one key). The longest
# existing ancestor is expanded and the rest appended; nothing exists -> GetFullPath only.
function Get-TcLongPath {
    param([string]$Path)
    $full = $Path.Trim()
    try { $full = [IO.Path]::GetFullPath($full) } catch { return $full }
    $cur = $full.TrimEnd('\', '/')
    $rest = ''
    while (-not [string]::IsNullOrEmpty($cur)) {
        if ([IO.File]::Exists($cur) -or [IO.Directory]::Exists($cur)) {
            $long = $null
            try { $long = [TwinCATAutomation.TcLongPathNative]::Get($cur) } catch { $long = $null }
            if ([string]::IsNullOrEmpty($long)) { return $full }
            return ($long.TrimEnd('\') + $rest)
        }
        $parent = [IO.Path]::GetDirectoryName($cur)
        if ([string]::IsNullOrEmpty($parent) -or $parent -eq $cur) { break }
        $rest = '\' + [IO.Path]::GetFileName($cur) + $rest
        $cur = $parent.TrimEnd('\')
        if ($cur.Length -eq 2 -and $cur[1] -eq ':') { $cur += '\' }
    }
    return $full
}

function ConvertTo-TcSolutionKey {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $script:TcUnknownSolutionKey }
    $p = Get-TcLongPath $Path
    return $p.TrimEnd('\', '/').ToLowerInvariant()
}

# The reasons of an entry as an ordered kind -> text map (entries without 'reasons': one
# 'platform-switch' reason, or the entry's own kind).
function Get-TcBuildRequiredReasons {
    param([object]$Entry)
    $map = [ordered]@{}
    if ($null -eq $Entry) { return $map }
    $rp = $Entry.PSObject.Properties['reasons']
    if ($null -ne $rp -and $null -ne $rp.Value) {
        $src = $rp.Value
        $pairs = if ($src -is [System.Collections.IDictionary]) { @($src.Keys | ForEach-Object { @{ K = [string]$_; V = [string]$src[$_] } }) }
                 else { @($src.PSObject.Properties | ForEach-Object { @{ K = [string]$_.Name; V = [string]$_.Value } }) }
        foreach ($p in $pairs) { if (-not [string]::IsNullOrWhiteSpace($p.V)) { $map[$p.K] = $p.V } }
    }
    if ($map.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace([string]$Entry.reason)) {
        $kp = $Entry.PSObject.Properties['kind']
        $k = if ($null -ne $kp -and -not [string]::IsNullOrWhiteSpace([string]$kp.Value)) { [string]$kp.Value } else { 'platform-switch' }
        $map[$k] = [string]$Entry.reason
    }
    return $map
}

# One entry from a reasons map: reason = the texts in $script:TcBuildRequiredKinds order.
function New-TcBuildRequiredEntry {
    param([string]$Solution, [System.Collections.IDictionary]$Reasons, [string]$Kind, [string]$At)
    $ordered = [ordered]@{}
    foreach ($k in $script:TcBuildRequiredKinds) { if ($Reasons.Contains($k)) { $ordered[$k] = $Reasons[$k] } }
    foreach ($k in $Reasons.Keys) { if (-not $ordered.Contains($k)) { $ordered[$k] = $Reasons[$k] } }
    [PSCustomObject]@{
        solution = $Solution
        kind     = $Kind
        reason   = (@($ordered.Values) -join '; and ')
        reasons  = [PSCustomObject]$ordered
        at       = $At
    }
}

# Two code-changed reasons as one: every change once (a repeated one moves to the end), the
# last $script:TcCodeChangedMaxItems listed, the dropped ones counted as '(+N earlier)'.
# Merging the same entry twice (file + memory copy) gives the same text. The changes are
# separated by ' | ' ($script:TcCodeChangedSeparator): '|' cannot appear in a Windows file name
# or an IEC identifier, and Register-TcCodeChange replaces any '|' in a change text, so a name
# such as 'A, B.sln' is never split. N is approximate: when the two texts were capped
# separately the larger count is kept (dropped changes cannot be compared), so N may be low.
function Join-TcCodeChangedReason {
    param([string]$Older, [string]$Newer)
    $items = New-Object System.Collections.Generic.List[string]
    $earlier = 0
    foreach ($t in @($Older, $Newer)) {
        if ([string]::IsNullOrWhiteSpace($t)) { continue }
        $body = if ($t.StartsWith($script:TcCodeChangedPrefix)) { $t.Substring($script:TcCodeChangedPrefix.Length) } else { $t }
        foreach ($part in ($body -split [regex]::Escape($script:TcCodeChangedSeparator))) {
            $part = $part.Trim()
            if ($part -match '^\(\+(\d+) earlier\)$') { $earlier = [Math]::Max($earlier, [int]$Matches[1]); continue }
            if ([string]::IsNullOrWhiteSpace($part)) { continue }
            $null = $items.Remove($part)
            $items.Add($part)
        }
    }
    while ($items.Count -gt $script:TcCodeChangedMaxItems) { $items.RemoveAt(0); $earlier++ }
    $sep = $script:TcCodeChangedSeparator
    $head = if ($earlier -gt 0) { "(+$earlier earlier)$sep" } else { '' }
    "$($script:TcCodeChangedPrefix)$head$($items -join $sep)"
}

# $Newer wins per kind (code-changed: both lists joined); solution / at from $Newer; kind = the
# first of $script:TcBuildRequiredKinds the merged entry has (#65: a code-changed does not hide
# a platform-switch / unverified-build).
function Merge-TcBuildRequiredEntry {
    param([object]$Older, [object]$Newer)
    if ($null -eq $Older) { return $Newer }
    if ($null -eq $Newer) { return $Older }
    $r = Get-TcBuildRequiredReasons $Older
    $n = Get-TcBuildRequiredReasons $Newer
    foreach ($k in $n.Keys) {
        if ($k -eq 'code-changed' -and $r.Contains($k)) { $r[$k] = Join-TcCodeChangedReason -Older $r[$k] -Newer $n[$k] }
        else { $r[$k] = $n[$k] }
    }
    $kp = $Newer.PSObject.Properties['kind']
    $kind = if ($null -ne $kp) { [string]$kp.Value } else { 'platform-switch' }
    foreach ($k in $script:TcBuildRequiredKinds) { if ($r.Contains($k)) { $kind = $k; break } }
    $sol = if (-not [string]::IsNullOrWhiteSpace([string]$Newer.solution)) { [string]$Newer.solution } else { [string]$Older.solution }
    New-TcBuildRequiredEntry -Solution $sol -Reasons $r -Kind $kind -At ([string]$Newer.at)
}

# Runs $Body under the named mutex of the state directory. Returns @{ Locked; Result; Error }.
function Invoke-TcBuildRequiredLocked {
    param([scriptblock]$Body)
    $mutex = New-Object System.Threading.Mutex($false, (Get-TcBuildRequiredMutexName))
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

# Under the lock. Returns @{ Entries = hashtable }; a corrupt file is replaced in one step by a
# '<corrupt>' entry (the old file kept as .corrupt-<time>). Throws when that replace fails: the
# unreadable file then stays and the caller fails closed.
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
        $entries = @{}
        $entries[$script:TcCorruptStateKey] = [PSCustomObject]@{
            solution = ''
            kind     = 'corrupt'
            reason   = "the BUILD_REQUIRED state file could not be read ($why); kept as $kept; remove this entry by hand once every solution has been built (docs/troubleshooting.md BUILD_REQUIRED)"
            at       = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        Write-TcBuildRequiredState -Entries $entries -Backup $kept
        return @{ Entries = $entries }
    }
}

# Under the lock. Throws when the file cannot be replaced after the retries (the .tmp is removed).
# -Backup: the existing file must be replaced (never moved / deleted) and is kept under that name.
function Write-TcBuildRequiredState {
    param([hashtable]$Entries, [string]$Backup)
    $file = Get-TcBuildRequiredFile
    $dir = Split-Path -Parent $file
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $last = $null
    for ($i = 1; $i -le 5; $i++) {
        $tmp = "$file.$PID.tmp"
        try {
            if ($Entries.Count -eq 0 -and [string]::IsNullOrEmpty($Backup)) {
                if (Test-Path -LiteralPath $file) { [IO.File]::Delete($file) }
                return
            }
            $o = [ordered]@{}
            foreach ($k in ($Entries.Keys | Sort-Object)) { $o[$k] = $Entries[$k] }
            [IO.File]::WriteAllText($tmp, ([PSCustomObject]$o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
            if (-not [string]::IsNullOrEmpty($Backup)) { [IO.File]::Replace($tmp, $file, $Backup) }
            elseif (Test-Path -LiteralPath $file) { [IO.File]::Replace($tmp, $file, [NullString]::Value) }
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
        Records that the current solution ($script:TcSolutionPath) needs a complete
        Build-TcProject success before Enable-TcConfig activates or Enter-TcPlcOnline logs in.
        -Kind: platform-switch (default, Set-TcSolutionPlatform), unverified-build
        (Build-TcProject, #56) or code-changed (Register-TcCodeChange, #65); the reasons of
        every kind are kept side by side. Never throws:
        returns $null, or a warning text when only the in-memory record could be kept (the
        file could not be locked or written).
        -SolutionPath: record for this .sln instead of $script:TcSolutionPath (Reset-TcSolution
        failing after it closed the module's solution and while it was opening -SolutionPath).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Reason,
        [ValidateSet('platform-switch', 'unverified-build', 'code-changed')][string]$Kind = 'platform-switch',
        [string]$SolutionPath
    )
    $sln = if ($PSBoundParameters.ContainsKey('SolutionPath')) { $SolutionPath } else { [string]$script:TcSolutionPath }
    $key = ConvertTo-TcSolutionKey $sln
    $reasons = [ordered]@{}
    $reasons[$Kind] = $Reason
    $new = New-TcBuildRequiredEntry -Solution ([string]$sln) -Reasons $reasons -Kind $Kind -At ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))
    $script:TcBuildRequiredLocal[$key] = Merge-TcBuildRequiredEntry -Older $script:TcBuildRequiredLocal[$key] -Newer $new
    $r = Invoke-TcBuildRequiredLocked -Body {
        $st = Read-TcBuildRequiredState
        $st.Entries[$key] = Merge-TcBuildRequiredEntry -Older $st.Entries[$key] -Newer $new
        Write-TcBuildRequiredState -Entries $st.Entries
    }
    if ($r.Locked -and $null -eq $r.Error) { return $null }
    $w = "BUILD_REQUIRED was recorded in this process only, not in $(Get-TcBuildRequiredFile) ($($r.Error)): another process (or an MCP bridge restart) will not see it; run Build-TcProject before Enable-TcConfig or a PLC login."
    Write-Warning $w
    return $w
}

function Clear-TcBuildRequired {
    <#
    .SYNOPSIS
        Removes the entry of the current solution (every kind) and the '<unknown>' entry (see
        the file header) from memory and from the file. The '<corrupt>' entry stays. Never
        throws: returns $null or a warning text (the file still blocks then: fail-closed).
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
    $w = "Clear-TcBuildRequired: $(Get-TcBuildRequiredFile) not updated ($($r.Error)); Enable-TcConfig and PLC logins stay blocked until a later Build-TcProject can update it."
    Write-Warning $w
    return $w
}

function Get-TcBuildRequired {
    <#
    .SYNOPSIS
        The entry that blocks the current solution, or $null. File and in-memory entries are
        merged (per key, the reasons of both); then: the '<corrupt>' entry, the solution's own
        entry, the '<unknown>' entry, any entry when no solution path is known. Lock or read
        failure -> a synthetic blocking entry (fail-closed).
    #>
    [CmdletBinding()]
    param()
    $r = Invoke-TcBuildRequiredLocked -Body { (Read-TcBuildRequiredState).Entries }
    if (-not $r.Locked -or $null -ne $r.Error) {
        return [PSCustomObject]@{ solution = [string]$script:TcSolutionPath; kind = 'state-unreadable'; reason = "the BUILD_REQUIRED state could not be checked ($($r.Error))"; at = $null }
    }
    $entries = @{}
    foreach ($k in $r.Result.Keys) { $entries[$k] = $r.Result[$k] }
    foreach ($k in $script:TcBuildRequiredLocal.Keys) {
        $entries[$k] = Merge-TcBuildRequiredEntry -Older $entries[$k] -Newer $script:TcBuildRequiredLocal[$k]
    }
    if ($entries.Count -eq 0) { return $null }
    if ($entries.ContainsKey($script:TcCorruptStateKey)) { return $entries[$script:TcCorruptStateKey] }
    $key = ConvertTo-TcSolutionKey $script:TcSolutionPath
    if ($entries.ContainsKey($key)) { return $entries[$key] }
    if ($entries.ContainsKey($script:TcUnknownSolutionKey)) { return $entries[$script:TcUnknownSolutionKey] }
    if ($key -eq $script:TcUnknownSolutionKey) { return @($entries.Values)[0] }
    return $null
}

# Text for a BUILD_REQUIRED refusal: what each recorded kind means for the PLC output.
function Get-TcBuildRequiredConsequence {
    param([object]$Entry)
    $kinds = @((Get-TcBuildRequiredReasons $Entry).Keys)
    $parts = @()
    if ($kinds -contains 'platform-switch') { $parts += 'the compiled PLC output may still be that of the previous platform' }
    if ($kinds -contains 'unverified-build') { $parts += 'the last build did not prove that the PLC code was compiled (an Activate or Login would compile again without anybody checking the result, #56)' }
    if ($kinds -contains 'code-changed') { $parts += 'the PLC code or project was changed after the last complete build (an Activate or Login would compile that change without anybody checking the result, #65)' }
    if ($parts.Count -eq 0) { $parts += 'the state of the compiled PLC output is not known' }
    $parts -join '; '
}

# Hint for a BUILD_REQUIRED refusal: the recorded kinds with their reasons (which cmdlet changed
# what, #65), then the general hint (Get-TcErrorHint BUILD_REQUIRED).
function Get-TcBuildRequiredHint {
    param([object]$Entry)
    $reasons = Get-TcBuildRequiredReasons $Entry
    $recorded = @($reasons.Keys | ForEach-Object { "$_ ($($reasons[$_]))" }) -join '; '
    $general = Get-TcErrorHint -Code 'BUILD_REQUIRED'
    # lock / read failure: not a build problem (Enter-TcPlcOnline says so in its message)
    $kp = if ($null -ne $Entry) { $Entry.PSObject.Properties['kind'] } else { $null }
    if ($null -ne $kp -and [string]$kp.Value -eq 'state-unreadable') { return $general }
    if ([string]::IsNullOrWhiteSpace($recorded)) { return $general }
    "Recorded: $recorded. Run Build-TcProject until data.completeBuild = true, then retry. $general".TrimEnd()
}

function Register-TcCodeChange {
    <#
    .SYNOPSIS
        #65: records BUILD_REQUIRED kind 'code-changed' for the current solution
        ($script:TcSolutionPath, '<unknown>' when not known: same keys as every other kind)
        after a cmdlet changed the PLC code / project in the IDE ($Change = '<cmdlet> <object>',
        e.g. 'Write-TcPouCode MAIN [implementation]'), and adds data.buildRequired (the recorded
        reason) and, when the state file could not be written, data.stateWarning to $Result
        (same fields as Build-TcProject). Returns $Result. Never throws: a failed write keeps the
        in-memory entry (Set-TcBuildRequired) and is reported in data.stateWarning, it never
        turns into "nothing recorded": should Set-TcBuildRequired itself throw, a '<unknown>'
        entry (blocks every solution) is put into the in-memory state directly.
        '|' in $Change is replaced by '/' (it separates the changes in the reason).
        -SolutionPath: passed to Set-TcBuildRequired (record for that .sln).
    #>
    [CmdletBinding()]
    param([object]$Result, [Parameter(Mandatory)][string]$Change, [string]$SolutionPath)
    $reason = "$($script:TcCodeChangedPrefix)$($Change.Replace('|', '/'))"
    $sw = $null
    try {
        $p = @{ Kind = 'code-changed'; Reason = $reason; WarningAction = 'SilentlyContinue' }
        if ($PSBoundParameters.ContainsKey('SolutionPath')) { $p['SolutionPath'] = $SolutionPath }
        $sw = Set-TcBuildRequired @p
    }
    catch {
        $why = $_.Exception.Message
        $key = $script:TcUnknownSolutionKey
        $plain = [PSCustomObject]@{
            solution = ''; kind = 'code-changed'; reason = $reason
            reasons = [PSCustomObject]@{ 'code-changed' = $reason }; at = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        }
        try { $script:TcBuildRequiredLocal[$key] = Merge-TcBuildRequiredEntry -Older $script:TcBuildRequiredLocal[$key] -Newer $plain }
        catch { if ($null -eq $script:TcBuildRequiredLocal[$key]) { $script:TcBuildRequiredLocal[$key] = $plain } }
        $sw = "BUILD_REQUIRED could not be recorded for this solution ($why); kept in this process only as '<unknown>' (blocks every solution); run Build-TcProject before Enable-TcConfig or a PLC login."
    }
    if ($null -eq $Result) { return $Result }
    $data = $null
    $dp = $Result.PSObject.Properties['data']
    if ($null -ne $dp) { $data = $dp.Value }
    if ($data -is [System.Collections.IDictionary]) { $data = [PSCustomObject]$data }
    if ($null -eq $data) { $data = [PSCustomObject]@{} }
    $data | Add-Member -NotePropertyName 'buildRequired' -NotePropertyValue $reason -Force
    if (-not [string]::IsNullOrWhiteSpace([string]$sw)) { $data | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue ([string]$sw) -Force }
    $Result | Add-Member -NotePropertyName 'data' -NotePropertyValue $data -Force
    return $Result
}
