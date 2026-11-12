# Lifecycle block (#68): "a public command sent a runtime-changing request and did not prove that
# the requested state was reached" - fail closed until a person has looked at it.
#
# Written ONLY after a runtime-changing request was sent and the command then failed:
#   Set-TcSystemState  any failure once WriteControl was called (data.requestSent = $true; also
#                      when the write itself was refused on the spot - conservative), records a
#                      block, for example SYSTEM_STATE_TIMEOUT, SYSTEM_STATE_MISMATCH,
#                      RUNTIME_CRASHED or an ADS exception after the write.
#   Enable-TcConfig    any failure once set-config (a Set-TcSystemState with
#                      data.requestSent = $true) or ActivateConfiguration() was sent records a
#                      block, for example ACTIVATE_TIMEOUT, ACTIVATE_FAILED, IDE_CRASHED,
#                      IDE_MODAL_DIALOG, CYCLE_TIMEOUT, LOGIN_FAILED, NOT_CONNECTED or
#                      BUILD_REQUIRED of the nested login, STATE_SET_FAILED, SYSTEM_STATE_*,
#                      RUNTIME_STATE_MISMATCH, BOOT_PACKAGE_MISMATCH, PLC_*; the only exception is
#                      LIFECYCLE_BLOCKED (a nested command was refused, the block exists already).
#   Set-TcPlcState     records a block when WriteControl was sent and the port did not reach Run
#                      / Stop, for example PLC_RUN_TIMEOUT or STATE_SET_FAILED from the readback.
#   Killed process     (#236) Set-TcSystemState and Enable-TcConfig keep an in-flight marker while
#                      their request is pending; a marker whose process died (MCP bridge killed on
#                      IDE_MODAL_DIALOG / BRIDGE_TIMEOUT, crash) becomes a block with errorCode
#                      INTERRUPTED at the next lifecycle check (Private/LifecycleInflight.ps1).
#                      An exception escaping Enable-TcConfig after its request records
#                      UNHANDLED_EXCEPTION.
# Failures before anything was sent (BUILD_REQUIRED, BUILD_SELECTION_*, PLATFORM_*,
# AMS_NETID_REQUIRED, PLC_PROJECT_NOT_FOUND of Enable-TcConfig -PlcProjectPath ...) never write
# one: nothing was changed.
#
# While a record exists for the target, every runtime-changing public command returns
# LIFECYCLE_BLOCKED (success = false, data.lifecycleBlock) and does nothing (Test-TcLifecycleBlock):
# Set-TcSystemState, Enable-TcConfig, Enter-TcPlcOnline (and Send-TcPlcProgram through it),
# Set-TcPlcState, Write-TcVariable, Invoke-TcTest, Invoke-TcTestCycle,
# Set-TcComModuleParameter -Online -DryRun $false. Read-only / diagnostic commands are not blocked.
# Nothing removes a record automatically; only Clear-TcLifecycleBlock does, after the user agreed.
#
# Storage - same directory and the same fail-closed rules as build-required.json
# (Private/Set-TcBuildRequired.ps1):
#   <dir>\lifecycle-block.json  { "<amsnetid lower case>": { amsNetId; command; errorCode; message;
#                                  requestedState; reachedState; step; time }, ... }
#   <dir> = $env:TCAUTO_STATE_DIR (tests) or %TEMP%\TwinCATAutomation.
#   One record per target AmsNetId: another target is not affected.
#   '<unknown>' key: a record written while the AmsNetId was not known, or for a loopback NetId
#   (127.x.x.x.y.z, e.g. 127.0.0.1.1.1: it names "this machine", which may also be reachable
#   under its real AmsNetId, so it cannot be compared). '<unknown>' blocks every target; a command
#   whose target is unknown or a loopback NetId is blocked by ANY record (fail closed).
#   '<corrupt>' key: the file could not be parsed (or was not a JSON object: null, array, text):
#   it is replaced in ONE step ([IO.File]::Replace(tmp, file, lifecycle-block.json.corrupt-<time>))
#   by a '<corrupt>' record that blocks every target; later records are added next to it. Removed
#   only by Clear-TcLifecycleBlock -AmsNetId '<corrupt>'. When that replace fails, every read
#   blocks ('state-unreadable').
#   Read-modify-write under a named mutex (Invoke-TcBuildRequiredLocked with its own name,
#   'Local\TwinCATAutomation.LifecycleBlock[.<hash>]'), file replaced with [IO.File]::Replace /
#   Move (no window without a file).
#   In-memory copy ($script:TcLifecycleBlockLocal): every record this module instance wrote. It
#   keeps blocking in THIS process when the file cannot be written (data.lifecycleBlock.stateWarning),
#   but another process, a new Import-Module or a restarted MCP bridge does not see such a record.
#   It is removed by Clear-TcLifecycleBlock in this process, or (#113, cross-bridge sync) when the
#   file no longer holds the key AND lifecycle-block-history.jsonl has the receipt of THIS record
#   (Test-TcLifecycleClearReceipt: same key, receipt.cleared.createdAtUtc / .command equal to the
#   record's, clearedAtUtc after createdAtUtc and at most $script:TcLifecycleReceiptSkewSec ahead
#   of now; a no-op Clear with cleared = null does not count). Fail closed: no such receipt (e.g. a
#   record removed by hand, a key-only or future-dated line, the receipt of an older record of the
#   same key), a history file that is missing or cannot be read, a line not shaped like {...} or a
#   line naming the key that does not parse, a record without createdAtUtc (older module) -> the
#   in-memory record keeps blocking and the returned copy carries syncNote (why, and that it is
#   cleared through THIS process). The history is not tamper-proof: the sync is a convenience,
#   not a security boundary.
#   Lock time-out / unreadable file -> every target blocked ('state-unreadable').
#   Every Clear-TcLifecycleBlock appends its receipt to lifecycle-block-history.jsonl under the
#   same mutex, with a short retry (#113: reason, fallbackMethod, allowedSideEffects,
#   maxVerifyLevel, clearedAtUtc, cleared, ...); not written -> data.receiptWritten = $false.
#   The history is read with FileShare.ReadWrite | Delete so a reader never makes an append fail.
#
# Windows PowerShell 5.1; this source file is ASCII (the user-facing stop text is
# $script:TcLifecycleStopText in ConvertTo-TcAdsErrorCode.ps1, UTF-8 with BOM).

$script:TcLifecycleBlockLocal = @{}
$script:TcLifecycleUnknownKey = '<unknown>'
$script:TcLifecycleCorruptKey = '<corrupt>'
# #113: Clear-TcLifecycleBlock -MaxVerifyLevel, lowest to highest (the #68 lifecycle layers that
# can be read back; mcp-server/scripts/Export-ToolSchema.ps1 offers the same list as the enum).
$script:TcLifecycleVerifyLevels = @('None', 'SystemState', 'PlcState', 'VariableRead', 'TestObserved')

function Get-TcLifecycleBlockFile {
    Join-Path (Split-Path -Parent (Get-TcBuildRequiredFile)) 'lifecycle-block.json'
}

function Get-TcLifecycleBlockMutexName {
    (Get-TcBuildRequiredMutexName) -replace '\.BuildRequired', '.LifecycleBlock'
}

# A loopback AmsNetId (127.x.x.x.y.z): "this machine", not comparable with its real AmsNetId.
function Test-TcLoopbackNetId {
    param([string]$AmsNetId)
    -not [string]::IsNullOrWhiteSpace($AmsNetId) -and $AmsNetId.Trim() -match '^127\.\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$'
}

function ConvertTo-TcLifecycleKey {
    param([string]$AmsNetId)
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) { return $script:TcLifecycleUnknownKey }
    $t = $AmsNetId.Trim()
    if ($t -eq $script:TcLifecycleUnknownKey -or $t -eq $script:TcLifecycleCorruptKey) { return $t }
    if (Test-TcLoopbackNetId $t) { return $script:TcLifecycleUnknownKey }
    $t.ToLowerInvariant()
}

# Under the lock. Returns a hashtable key -> entry. A file that cannot be parsed or is not a JSON
# object is replaced in one step by a '<corrupt>' record (old file kept as .corrupt-<time>);
# throws when that replace fails (callers fail closed).
function Read-TcLifecycleBlockState {
    $file = Get-TcLifecycleBlockFile
    $entries = @{}
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $entries }
    $text = [IO.File]::ReadAllText($file)
    $why = $null
    $obj = $null
    if ([string]::IsNullOrWhiteSpace($text)) { $why = 'the file is empty' }
    else {
        try { $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop } catch { $why = $_.Exception.Message }
        if ($null -eq $why -and $obj -isnot [System.Management.Automation.PSCustomObject]) {
            $why = "the content is not a JSON object ($(if ($null -eq $obj) { 'null' } else { $obj.GetType().Name }))"
        }
    }
    if ($null -eq $why) {
        foreach ($p in $obj.PSObject.Properties) {
            if ($p.Value -isnot [System.Management.Automation.PSCustomObject]) { $why = "record '$($p.Name)' is not a JSON object"; break }
            $entries[$p.Name] = $p.Value
        }
    }
    if ($null -eq $why) { return $entries }
    $kept = "$file.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))"
    $entries = @{}
    $entries[$script:TcLifecycleCorruptKey] = [PSCustomObject]@{
        amsNetId = $null; command = $null; errorCode = 'state-corrupt'
        message = "the lifecycle block state file could not be read ($why); kept as $kept (it may have held blocks of any target), so every target is blocked until the user agrees to Clear-TcLifecycleBlock -AmsNetId '<corrupt>'"
        requestedState = $null; reachedState = $null; step = $null; time = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    }
    Write-TcLifecycleBlockState -Entries $entries -Backup $kept
    $entries
}

# Under the lock. Throws when the file cannot be replaced after the retries (the .tmp is removed).
# -Backup: the existing file is replaced (never deleted) and kept under that name.
function Write-TcLifecycleBlockState {
    param([hashtable]$Entries, [string]$Backup)
    $file = Get-TcLifecycleBlockFile
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

function Set-TcLifecycleBlock {
    <#
    .SYNOPSIS
        #68: records the lifecycle block of -AmsNetId (one record per target, the newest wins; a
        loopback / empty NetId goes to '<unknown>'). Records of other targets and a '<corrupt>'
        record are kept. Never throws: returns the entry; entry.stateWarning is set when only the
        in-memory copy could be kept (file not lockable / writable).
    #>
    [CmdletBinding()]
    param(
        [string]$AmsNetId,
        [Parameter(Mandatory)][string]$Command,
        [string]$ErrorCode,
        [string]$Message,
        [string]$RequestedState,
        [string]$ReachedState,
        [string]$Step,
        # #114 N5: why reachedState is empty: 'unreachable' (last read failed), 'runtime-gone'
        [string]$ReadbackNote
    )
    $key = ConvertTo-TcLifecycleKey $AmsNetId
    $entry = [PSCustomObject]@{
        amsNetId       = $(if ([string]::IsNullOrWhiteSpace($AmsNetId)) { $null } else { $AmsNetId.Trim() })
        command        = $Command
        errorCode      = $ErrorCode
        message        = $Message
        requestedState = $RequestedState
        reachedState   = $ReachedState
        readbackNote   = $(if ([string]::IsNullOrWhiteSpace($ReadbackNote)) { $null } else { $ReadbackNote })
        step           = $Step
        time           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        # #113: exact creation time, compared with a Clear receipt's clearedAtUtc (cross-bridge sync)
        createdAtUtc   = [DateTime]::UtcNow.ToString('o')
    }
    $script:TcLifecycleBlockLocal[$key] = $entry
    $r = $null
    try {
        $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -Body {
            $st = Read-TcLifecycleBlockState
            $st[$key] = $entry
            Write-TcLifecycleBlockState -Entries $st
        }
    }
    catch { $r = @{ Locked = $false; Error = $_.Exception.Message } }
    if ($null -eq $r -or -not $r.Locked -or $null -ne $r.Error) {
        $why = if ($null -ne $r) { $r.Error } else { 'unknown error' }
        $copy = $entry.PSObject.Copy()
        $copy | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue "LIFECYCLE_BLOCKED was recorded in this process only, not in $(Get-TcStateFileLabel 'lifecycle-block.json') ($why): another process (or an MCP bridge restart) will not see it." -Force
        return $copy
    }
    $entry
}

function Get-TcLifecycleHistoryFile {
    Join-Path (Split-Path -Parent (Get-TcLifecycleBlockFile)) 'lifecycle-block-history.jsonl'
}

# A UTC time written with ToString('o'), or $null when missing / not parseable.
function ConvertTo-TcLifecycleUtc {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTime]) { return $Value.ToUniversalTime() }
    $s = [string]$Value
    if ([string]::IsNullOrWhiteSpace($s)) { return $null }
    $d = [DateTime]::MinValue
    $styles = [Globalization.DateTimeStyles]::AdjustToUniversal -bor [Globalization.DateTimeStyles]::AssumeUniversal
    if ([DateTime]::TryParse($s, [Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$d)) { return $d }
    $null
}

# #113 review 2: read the history without blocking a concurrent AppendAllText of another
# process (ReadAllText opens with FileShare.Read only, so the writer's append failed).
function Read-TcLifecycleHistoryText {
    param([string]$Path)
    $fs = New-Object System.IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    try {
        $sr = New-Object System.IO.StreamReader($fs, (New-Object System.Text.UTF8Encoding($false)), $true)
        $sr.ReadToEnd()
    }
    finally { $fs.Dispose() }
}

# A clearedAtUtc more than this many seconds ahead of this machine's clock is not accepted
# (forged or clock-skewed receipt; it could otherwise be replayed against later blocks).
$script:TcLifecycleReceiptSkewSec = 5
# Tries to append a Clear receipt (Remove-TcLifecycleBlock, under the lock; 40 ms * try between).
$script:TcLifecycleHistoryRetries = 5

function Test-TcLifecycleClearReceipt {
    <#
    .SYNOPSIS
        #113 cross-bridge sync: @{ Ok; Note }. Ok = $true only when lifecycle-block-history.jsonl
        has a receipt of THIS record instance: same key, cleared not $null (a no-op Clear does
        not count), cleared.createdAtUtc equal to -Entry.createdAtUtc, cleared.command equal to
        -Entry.command, clearedAtUtc later than createdAtUtc and not more than
        $script:TcLifecycleReceiptSkewSec ahead of now. Fail closed (Ok = $false, Note = why):
        the entry has no readable createdAtUtc, the history is missing or cannot be read, a line
        is not shaped like a JSON object ({...}) or a line naming the key does not parse, no
        matching receipt. The history is not tamper-proof: this is a convenience, not a security
        boundary (docs/troubleshooting.md "LIFECYCLE_BLOCKED"). Never throws.
    #>
    param([string]$Key, $Entry)
    try {
        $created = $null
        if ($null -ne $Entry -and $null -ne $Entry.PSObject.Properties['createdAtUtc']) { $created = ConvertTo-TcLifecycleUtc $Entry.createdAtUtc }
        if ($null -eq $created) { return @{ Ok = $false; Note = 'the record has no createdAtUtc (written by an older module version)' } }
        $hist = Get-TcLifecycleHistoryFile
        if (-not (Test-Path -LiteralPath $hist -PathType Leaf)) { return @{ Ok = $false; Note = 'lifecycle-block-history.jsonl does not exist (no Clear receipt)' } }
        $text = $null
        try { $text = Read-TcLifecycleHistoryText -Path $hist }
        catch { return @{ Ok = $false; Note = "lifecycle-block-history.jsonl could not be read ($($_.Exception.Message))" } }
        $limit = [DateTime]::UtcNow.AddSeconds($script:TcLifecycleReceiptSkewSec)
        # pre-filter (review 4): only lines that name the key are parsed; both the plain and the
        # JSON-escaped spelling ('<unknown>' is written as <unknown> by PS 5.1)
        $needles = @(('"key":"' + $Key + '"'), ('"key":' + (ConvertTo-Json -InputObject $Key -Compress)))
        $command = [string]$Entry.command
        $n = 0
        $future = $false
        $found = $false
        foreach ($line in ($text -split "`r?`n")) {
            $n++
            $t = $line.Trim()
            if ($t.Length -eq 0) { continue }
            if (-not ($t.StartsWith('{') -and $t.EndsWith('}'))) { return @{ Ok = $false; Note = "lifecycle-block-history.jsonl line $n is corrupt (not a JSON object)" } }
            $hit = $false
            foreach ($nd in $needles) { if ($t.Contains($nd)) { $hit = $true; break } }
            if (-not $hit) { continue }
            $o = $null
            try { $o = ConvertFrom-Json -InputObject $t -ErrorAction Stop } catch { return @{ Ok = $false; Note = "lifecycle-block-history.jsonl line $n is corrupt ($($_.Exception.Message))" } }
            if ($o -isnot [System.Management.Automation.PSCustomObject]) { return @{ Ok = $false; Note = "lifecycle-block-history.jsonl line $n is corrupt (not a JSON object)" } }
            if ([string]$o.key -cne $Key) { continue }
            $rec = $o.cleared
            if ($null -eq $rec -or $rec -isnot [System.Management.Automation.PSCustomObject]) { continue }
            $recCreated = ConvertTo-TcLifecycleUtc $rec.createdAtUtc
            if ($null -eq $recCreated -or $recCreated.Ticks -ne $created.Ticks) { continue }
            if ([string]$rec.command -cne $command) { continue }
            $cleared = $null
            if ($null -ne $o.PSObject.Properties['clearedAtUtc']) { $cleared = ConvertTo-TcLifecycleUtc $o.clearedAtUtc }
            if ($null -eq $cleared -or $cleared -le $created) { continue }
            if ($cleared -gt $limit) { $future = $true; continue }
            $found = $true
        }
        if ($found) { return @{ Ok = $true; Note = $null } }
        if ($future) { return @{ Ok = $false; Note = "the receipt of this record has a clearedAtUtc more than $($script:TcLifecycleReceiptSkewSec) s in the future (clock skew or forged); not accepted" } }
        @{ Ok = $false; Note = 'lifecycle-block-history.jsonl has no Clear receipt of this record (the record was removed from the state file without Clear-TcLifecycleBlock, or a receipt names another record of the same key)' }
    }
    catch { @{ Ok = $false; Note = "lifecycle-block-history.jsonl could not be checked ($($_.Exception.Message))" } }
}

# File + memory records as one hashtable (memory wins), or @{ Error = text } when unreadable.
# -TimeoutMs: lock wait (default: the build-required default; the hint-only path passes a short one).
# #113: an in-memory record whose key is no longer in the file is dropped when another process
# cleared it (Test-TcLifecycleClearReceipt); otherwise it keeps blocking (fail closed).
function Get-TcLifecycleBlockEntries {
    param([int]$TimeoutMs = 0)
    # #236: in-flight markers of processes that died during their request become blocks first
    Sync-TcLifecycleInflight
    $r = $null
    try { $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -TimeoutMs $TimeoutMs -Body { Read-TcLifecycleBlockState } }
    catch { $r = @{ Locked = $false; Error = $_.Exception.Message } }
    if (-not $r.Locked -or $null -ne $r.Error) { return @{ Error = [string]$r.Error; Entries = $null } }
    $entries = @{}
    if ($null -ne $r.Result) { foreach ($k in $r.Result.Keys) { $entries[$k] = $r.Result[$k] } }
    foreach ($k in @($script:TcLifecycleBlockLocal.Keys)) {
        $local = $script:TcLifecycleBlockLocal[$k]
        if (-not $entries.ContainsKey($k)) {
            $sync = Test-TcLifecycleClearReceipt -Key $k -Entry $local
            if ($sync.Ok) {
                Write-Verbose "lifecycle block '$k': not in the file any more and the history has the Clear receipt of this record; in-memory copy dropped (#113)"
                $null = $script:TcLifecycleBlockLocal.Remove($k)
                continue
            }
            # review 5: say why the copy is kept and where it can be cleared (the stored copy is not changed)
            $copy = $local.PSObject.Copy()
            $copy | Add-Member -NotePropertyName 'syncNote' -NotePropertyValue "This record is not in $(Get-TcStateFileLabel 'lifecycle-block.json') (any more), but this process (PID $PID, e.g. this MCP bridge) still holds it in memory and keeps blocking: $($sync.Note). Cross-bridge sync (#113) only accepts the Clear receipt of exactly this record. Only after the user agreed: run Clear-TcLifecycleBlock in THIS process / MCP bridge (the one reporting the block)." -Force
            $entries[$k] = $copy
            continue
        }
        $entries[$k] = $local
    }
    @{ Error = $null; Entries = $entries }
}

function Get-TcLifecycleBlockLocalForReload {
    <#
    .SYNOPSIS
        #41: the lifecycle block records ONLY this module instance holds in memory
        ($script:TcLifecycleBlockLocal), for the MCP bridge op 'retire' (ReloadModule): a reload
        drops them, so the bridge refuses while this returns any record. File records are not
        listed: they survive a reload. Returns @{ List = <object[]> of @{ key; record } }.
        Throws when the variable is missing or not a hashtable; the bridge then refuses (fail closed).
        A module older than #41 has no such function: the bridge then reads the variable itself.
        #113 / #130: the cross-bridge sync runs first (Get-TcLifecycleBlockEntries), so a record
        that another bridge already cleared is dropped here too. The sync only removes a record
        whose Clear receipt is bound to it (same key, createdAtUtc and command, clearedAtUtc not
        in the future, cleared not null; Test-TcLifecycleClearReceipt); every other record stays
        and keeps the reload refused. When the state cannot be read the sync does nothing and the
        records are listed as they are (fail closed).
    #>
    $v = Get-Variable -Name 'TcLifecycleBlockLocal' -Scope Script -ErrorAction SilentlyContinue
    if ($null -eq $v) { throw '$script:TcLifecycleBlockLocal is not defined' }
    if ($v.Value -is [System.Collections.IDictionary] -and $v.Value.Count -gt 0) {
        try { $null = Get-TcLifecycleBlockEntries } catch { Write-Verbose "Get-TcLifecycleBlockLocalForReload: cross-bridge sync skipped ($($_.Exception.Message))" }
    }
    $local = $v.Value
    if ($local -isnot [System.Collections.IDictionary]) {
        throw "`$script:TcLifecycleBlockLocal is not a hashtable ($(if ($null -eq $local) { 'null' } else { $local.GetType().FullName }))"
    }
    $list = [object[]]@($local.Keys | Sort-Object | ForEach-Object { @{ key = [string]$_; record = $local[$_] } })
    @{ List = $list }
}

function Get-TcLifecycleBlock {
    <#
    .SYNOPSIS
        #68: the record that blocks -AmsNetId, or $null. File and in-memory records are merged
        (memory wins). Order: '<corrupt>', the target's own record, '<unknown>'; an empty or
        loopback -AmsNetId is blocked by any record. Lock / read failure -> a synthetic
        'state-unreadable' record (fail closed).
    #>
    [CmdletBinding()]
    param([string]$AmsNetId, [int]$TimeoutMs = 0)
    $all = Get-TcLifecycleBlockEntries -TimeoutMs $TimeoutMs
    if ($null -ne $all.Error) {
        return [PSCustomObject]@{
            amsNetId = $AmsNetId; command = $null; errorCode = 'state-unreadable'
            message = "the lifecycle block state $(Get-TcStateFileLabel 'lifecycle-block.json') could not be checked ($($all.Error)); every target is blocked until it is readable"
            requestedState = $null; reachedState = $null; step = $null; time = $null
        }
    }
    $entries = $all.Entries
    if ($entries.Count -eq 0) { return $null }
    if ($entries.ContainsKey($script:TcLifecycleCorruptKey)) { return $entries[$script:TcLifecycleCorruptKey] }
    $key = ConvertTo-TcLifecycleKey $AmsNetId
    if ($key -ne $script:TcLifecycleUnknownKey -and $entries.ContainsKey($key)) { return $entries[$key] }
    if ($entries.ContainsKey($script:TcLifecycleUnknownKey)) { return $entries[$script:TcLifecycleUnknownKey] }
    if ($key -eq $script:TcLifecycleUnknownKey) { return @($entries.Values | Sort-Object { [string]$_.time })[-1] }
    $null
}

function Remove-TcLifecycleBlock {
    <#
    .SYNOPSIS
        #68: removes the record of -AmsNetId's key (memory and file; '<unknown>' / '<corrupt>' by
        name). Returns @{ Removed (entry or $null); Warning; Receipt; ReceiptWritten;
        HistoryWarning }. Never throws.
        #113 review 2: -Receipt (scriptblock, gets the removed record or $null, returns the receipt
        object) is built and appended to lifecycle-block-history.jsonl UNDER THE SAME MUTEX, right
        after the state file was written, with a short retry; ReceiptWritten = $false and
        HistoryWarning when it still could not be appended (the record is removed anyway).
    #>
    param([string]$AmsNetId, [scriptblock]$Receipt)
    $key = ConvertTo-TcLifecycleKey $AmsNetId
    $removed = $null
    if ($script:TcLifecycleBlockLocal.ContainsKey($key)) {
        $removed = $script:TcLifecycleBlockLocal[$key]
        $null = $script:TcLifecycleBlockLocal.Remove($key)
    }
    $r = $null
    try {
        $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -Body {
            $st = Read-TcLifecycleBlockState
            $old = $null
            if ($st.ContainsKey($key)) { $old = $st[$key]; $null = $st.Remove($key) }
            Write-TcLifecycleBlockState -Entries $st
            $rec = $null; $written = $false; $hw = $null
            if ($null -ne $Receipt) {
                $gone = if ($null -ne $old) { $old } else { $removed }
                # the state file is already written: nothing below may throw out of the lock
                try {
                    $rec = & $Receipt $gone
                    $hist = Get-TcLifecycleHistoryFile
                    $json = ($rec | ConvertTo-Json -Depth 5 -Compress) + "`r`n"
                    for ($i = 1; $i -le $script:TcLifecycleHistoryRetries -and -not $written; $i++) {
                        try { [IO.File]::AppendAllText($hist, $json, (New-Object System.Text.UTF8Encoding($false))); $written = $true }
                        catch { $hw = $_.Exception.Message; if ($i -lt $script:TcLifecycleHistoryRetries) { Start-Sleep -Milliseconds (40 * $i) } }
                    }
                }
                catch { $hw = $_.Exception.Message }
            }
            @{ Old = $old; Receipt = $rec; Written = $written; HistoryError = $hw }
        }
    }
    catch { $r = @{ Locked = $false; Error = $_.Exception.Message } }
    if ($null -eq $r -or -not $r.Locked -or $null -ne $r.Error) {
        $why = if ($null -ne $r) { $r.Error } else { 'unknown error' }
        # the memory copy is gone but the file still blocks: put it back, nothing changed
        if ($null -ne $removed) { $script:TcLifecycleBlockLocal[$key] = $removed }
        return @{ Removed = $null; Warning = "$(Get-TcStateFileLabel 'lifecycle-block.json') not updated ($why); the target stays blocked." }
    }
    if ($null -ne $r.Result.Old) { $removed = $r.Result.Old }
    $hw = $null
    if ($null -ne $Receipt -and -not $r.Result.Written) {
        $hw = "the receipt could not be appended to $(Get-TcStateFileLabel 'lifecycle-block-history.jsonl') after $($script:TcLifecycleHistoryRetries) tries ($($r.Result.HistoryError))"
    }
    @{ Removed = $removed; Warning = $null; Receipt = $r.Result.Receipt; ReceiptWritten = [bool]$r.Result.Written; HistoryWarning = $hw }
}

# All records (file + memory), for Clear-TcLifecycleBlock's report, as
# @{ Readable = <bool>; List = <object[]> of @{ key; record } }. Wrapped in a hashtable so that an
# empty list can never be unrolled into $null on the way out (V4, measured 2026-11-04: an unrolled
# empty list made Clear report "could not be read" after it removed the last record).
# Readable = $false: List is an empty array and the records are not known.
function Get-TcLifecycleBlockList {
    $all = Get-TcLifecycleBlockEntries
    if ($null -ne $all.Error) { return @{ Readable = $false; List = [object[]]@() } }
    $list = [object[]]@($all.Entries.Keys | Sort-Object | ForEach-Object { [PSCustomObject]@{ key = $_; record = $all.Entries[$_] } })
    @{ Readable = $true; List = $list }
}

# Target AmsNetId of the IDE (GetTargetNetId), else the ADS session, else $null. Never throws.
function Resolve-TcLifecycleNetId {
    param($SysManager)
    $id = $null
    try {
        $sm = $SysManager
        if ($null -eq $sm) { $sm = Get-TcSysManager }
        if ($null -ne $sm) { $id = [string](Invoke-TcComRetry -OperationName 'GetTargetNetId' -MaxRetries 2 -ScriptBlock { $sm.GetTargetNetId() }); Save-TcIdeTargetNetId $id }
    }
    catch { $id = $null }
    if ([string]::IsNullOrWhiteSpace($id)) { $id = [string]$script:TcAdsAmsNetId }
    if ([string]::IsNullOrWhiteSpace($id)) { return $null }
    $id
}

function Test-TcLifecycleBlock {
    <#
    .SYNOPSIS
        #68: $null when -AmsNetId is not blocked, else the LIFECYCLE_BLOCKED result of -Command
        (success = false; data.lifecycleBlock = the record, data.command, data.amsNetId,
        data.notRun = $true, data.requestSent = $false for every command, #114). The caller returns
        it and does nothing else.
    #>
    param([string]$AmsNetId, [Parameter(Mandatory)][string]$Command)
    $b = Get-TcLifecycleBlock -AmsNetId $AmsNetId
    if ($null -eq $b) { return $null }
    $target = if ([string]::IsNullOrWhiteSpace($AmsNetId)) { '<target AmsNetId unknown>' } elseif (Test-TcLoopbackNetId $AmsNetId) { "$AmsNetId (loopback: compared with every record)" } else { $AmsNetId }
    $what = if ([string]$b.errorCode -in @('state-unreadable', 'state-corrupt')) { [string]$b.message }
            else { "$($b.command) did NOT succeed: it failed at $($b.time) with $($b.errorCode)$(if ($b.step) { " in step '$($b.step)'" }) on $(if ($b.amsNetId) { $b.amsNetId } else { 'an unknown target' }) ($(Format-TcLifecycleBlockStates $b))" }
    New-TcResult -Success $false -ErrorCode 'LIFECYCLE_BLOCKED' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED') `
        -ErrorMessage "$Command NOT RUN on ${target}: the lifecycle is blocked because $what. Nothing was sent.$(if ($null -ne $b.PSObject.Properties['syncNote']) { " $($b.syncNote)" })" `
        -Data ([PSCustomObject]@{ command = $Command; amsNetId = $AmsNetId; notRun = $true; requestSent = $false; lifecycleBlock = $b })
}

# "requested 'Config'; system state read back afterwards: nothing (runtime gone)" - never in a
# form that reads like success (side finding 2).
function Format-TcLifecycleBlockStates {
    param($Block)
    $req = if ([string]::IsNullOrWhiteSpace([string]$Block.requestedState)) { 'unknown' } else { "'$($Block.requestedState)'" }
    $rb = if (-not [string]::IsNullOrWhiteSpace([string]$Block.reachedState)) { "'$($Block.reachedState)'" }
          elseif ([string]$Block.readbackNote -eq 'runtime-gone' -or [string]$Block.errorCode -eq 'RUNTIME_CRASHED') { 'nothing (runtime gone)' }
          elseif ([string]$Block.readbackNote -eq 'unreachable' -and [string]$Block.command -eq 'Set-TcPlcState') { 'nothing (PLC port unreachable)' }   # #131
          elseif ([string]$Block.readbackNote -eq 'unreachable') { 'nothing (port 10000 unreachable)' }   # #114 N5
          else { 'nothing' }
    "requested $req; system state read back afterwards: $rb"
}

# Side findings 3 / 4: error codes whose usual hint points at a runtime-changing command (Connect
# then SetSystemState / PlcLogin / SetPlcState / EnableConfig). New-TcResult replaces their hint by
# $script:TcLifecycleReadOnlyText while THEIR target has a lifecycle block.
# Rule (#114 minor 6): the read-only prefix is put in front ONLY when the code's usual hint suggests
# a command that the block refuses (Set-TcSystemState, Enter-TcPlcOnline, Set-TcPlcState,
# Enable-TcConfig ...). A code whose usual hint is already a read-only step keeps it unchanged and
# only gets data.lifecycleBlock attached (no prefix): ADS_SYMBOL_NOT_FOUND / SYMBOL_NOT_FOUND
# ("check with Get-TcSymbols"). A new code goes into exactly one of the two lists by that rule.
$script:TcLifecycleHintCodes = @('ADS_TARGET_NOT_FOUND', 'ADS_PORT_NOT_FOUND', 'NOT_CONNECTED', 'PLC_NOT_LOADED', 'ADS_INVALID_STATE')
# Codes whose hint is kept (it is a read-only step) but which get data.lifecycleBlock attached.
$script:TcLifecycleAttachOnlyCodes = @('ADS_SYMBOL_NOT_FOUND', 'SYMBOL_NOT_FOUND')
# Lock wait of this hint-only path (ms): a busy lock adds no advice; the refusals
# (Test-TcLifecycleBlock) keep their normal wait and fail closed.
$script:TcLifecycleAdviceLockMs = 300

function Get-TcLifecycleBlockAdvice {
    <#
    .SYNOPSIS
        For New-TcResult (side findings 3 / 4): $null, or @{ Mode = 'replace' | 'attach' | 'note';
        Block }. The target is -AmsNetId when the caller knows it, else the ADS session's AmsNetId,
        else (#114 minor 5: e.g. NOT_CONNECTED before any Connect-TcAds) the IDE target
        (Resolve-TcLifecycleIdeNetId), which Connect-TcAds would connect to.
        A known target with a block (its own, '<unknown>' or '<corrupt>') -> 'replace' for
        $script:TcLifecycleHintCodes, 'attach' for $script:TcLifecycleAttachOnlyCodes. A target that
        stays unknown (or loopback) never gets the hint replaced: 'note' when any record exists (one
        sentence is appended). Short lock wait; unreadable / busy -> $null. Never throws.
    #>
    param([string]$Code, [string]$AmsNetId)
    $replace = $script:TcLifecycleHintCodes -contains $Code
    $attach = $script:TcLifecycleAttachOnlyCodes -contains $Code
    if (-not $replace -and -not $attach) { return $null }
    $id = if (-not [string]::IsNullOrWhiteSpace($AmsNetId)) { $AmsNetId } else { [string]$script:TcAdsAmsNetId }
    $b = $null
    try { $b = Get-TcLifecycleBlock -AmsNetId $id -TimeoutMs $script:TcLifecycleAdviceLockMs } catch { return $null }
    if ($null -eq $b -or [string]$b.errorCode -eq 'state-unreadable') { return $null }
    if ((ConvertTo-TcLifecycleKey $id) -eq $script:TcLifecycleUnknownKey) {
        # #114 minor 5: only asked when some record exists; the IDE target's own block (or
        # '<unknown>' / '<corrupt>') is "this target", not "another target"
        $ide = Resolve-TcLifecycleIdeNetId
        if ($null -eq $ide -or (ConvertTo-TcLifecycleKey $ide) -eq $script:TcLifecycleUnknownKey) { return @{ Mode = 'note'; Block = $b } }
        $bi = $null
        try { $bi = Get-TcLifecycleBlock -AmsNetId $ide -TimeoutMs $script:TcLifecycleAdviceLockMs } catch { return @{ Mode = 'note'; Block = $b } }
        if ($null -eq $bi -or [string]$bi.errorCode -eq 'state-unreadable') { return @{ Mode = 'note'; Block = $b } }
        $b = $bi
    }
    @{ Mode = $(if ($replace) { 'replace' } else { 'attach' }); Block = $b }
}

# #114 minor 5 / S5: target AmsNetId of the connected IDE for the hint-only path, or $null.
# It makes NO COM call: a synchronous GetTargetNetId on a hung XAE has no deadline
# (CODING_STANDARDS 1), and a hint must never block. It returns the NetId that an earlier command
# read from the IDE (Save-TcIdeTargetNetId: Resolve-TcLifecycleNetId, Connect-TcIde, Connect-TcAds,
# Get-TcSystemState, Set-TcSystemState, Enable-TcConfig, Set-TcTarget), only while the IDE is still
# connected with the same cached ITcSysManager. Never throws.
# N-a: the cache can be stale - the target may have been changed in the XAE GUI or by another
# process since it was read. That is acceptable only because this feeds hint text: the refusals
# (Test-TcLifecycleBlock callers) never use this cache, they resolve their target live
# (Resolve-TcLifecycleNetId, the ADS session or their own -AmsNetId).
$script:TcIdeTargetNetIdCache = $null
function Save-TcIdeTargetNetId {
    param([string]$AmsNetId)
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) { return }
    $script:TcIdeTargetNetIdCache = @{ NetId = $AmsNetId.Trim(); SysManager = $script:TcSysManager }
}
function Resolve-TcLifecycleIdeNetId {
    $c = $script:TcIdeTargetNetIdCache
    if (-not $script:TcIdeConnected -or $null -eq $c -or $null -eq $script:TcSysManager) { return $null }
    if (-not [object]::ReferenceEquals($c.SysManager, $script:TcSysManager)) { return $null }
    [string]$c.NetId
}

function Add-TcLifecycleBlockResult {
    <#
    .SYNOPSIS
        #68: records the block for a failed command after a runtime-changing request and returns
        -Result with data.lifecycleBlock and the hint prefixed by the stop instruction
        ($script:TcLifecycleStopText). Never throws.
    #>
    param([object]$Result, [Parameter(Mandatory)][string]$Command, [string]$AmsNetId, [string]$RequestedState, [string]$ReachedState, [string]$Step, [string]$ReadbackNote)
    if ($null -eq $Result) { return $Result }
    $code = $null; $msg = $null
    if ($null -ne $Result.error) { $code = [string]$Result.error.code; $msg = [string]$Result.error.message }
    $b = Set-TcLifecycleBlock -AmsNetId $AmsNetId -Command $Command -ErrorCode $code -Message $msg -RequestedState $RequestedState -ReachedState $ReachedState -Step $Step -ReadbackNote $ReadbackNote
    $data = $null
    $dp = $Result.PSObject.Properties['data']
    if ($null -ne $dp) { $data = $dp.Value }
    if ($data -is [System.Collections.IDictionary]) { $data = [PSCustomObject]$data }
    if ($null -eq $data) { $data = [PSCustomObject]@{} }
    $data | Add-Member -NotePropertyName 'lifecycleBlock' -NotePropertyValue $b -Force
    $Result | Add-Member -NotePropertyName 'data' -NotePropertyValue $data -Force
    if ($null -ne $Result.error) {
        $hp = $Result.error.PSObject.Properties['hint']
        $old = if ($null -ne $hp) { [string]$hp.Value } else { '' }
        # a nested Set-TcSystemState already put the stop instruction in front: replace it, do not repeat it
        # S-2: strip every leading stop / read-only text (in any order, nested results can stack
        # them) until none is left, then put exactly one stop text in front
        $pairs = @(@($script:TcLifecycleStopPrefix, $script:TcLifecycleStopMarker), @($script:TcLifecycleReadOnlyPrefix, $script:TcLifecycleReadOnlyMarker))
        $changed = $true
        while ($changed) {
            $changed = $false
            foreach ($pm in $pairs) {
                if ($old.StartsWith($pm[0]) -and $old.Contains($pm[1])) { $old = $old.Substring($old.IndexOf($pm[1]) + $pm[1].Length).Trim(); $changed = $true }
            }
        }
        $tgt = if ([string]::IsNullOrWhiteSpace($AmsNetId)) { '<unknown>' } elseif (Test-TcLoopbackNetId $AmsNetId) { "$AmsNetId (<unknown>)" } else { $AmsNetId }
        $stop = $script:TcLifecycleStopText.Replace('{target}', $tgt)
        $Result.error | Add-Member -NotePropertyName 'hint' -NotePropertyValue "$stop $old".TrimEnd() -Force
    }
    $Result
}
