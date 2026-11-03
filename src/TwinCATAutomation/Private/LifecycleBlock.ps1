# Lifecycle block (#68): "a public command sent a runtime-changing request and did not prove that
# the requested state was reached" - fail closed until a person has looked at it.
#
# Written ONLY after a runtime-changing request was sent and the command then failed:
#   Set-TcSystemState  after WriteControl: SYSTEM_STATE_TIMEOUT, SYSTEM_STATE_MISMATCH,
#                      RUNTIME_CRASHED and any exception (ADS error) after the write
#   Enable-TcConfig    after set-config / ActivateConfiguration() was sent: every failure code
#                      except $script:TcLifecyclePreconditionCodes (ACTIVATE_TIMEOUT,
#                      ACTIVATE_FAILED, IDE_CRASHED, IDE_MODAL_DIALOG, CYCLE_TIMEOUT, LOGIN_FAILED,
#                      STATE_SET_FAILED, ADS_RECONNECT_FAILED, SYSTEM_STATE_*,
#                      RUNTIME_STATE_MISMATCH, BOOT_PACKAGE_MISMATCH, PLC_* ... all record one).
#                      A set-config whose Set-TcSystemState sent nothing (no data.lifecycleBlock)
#                      does not count as sent.
#   Set-TcPlcState     WriteControl sent, the port did not reach Run / Stop (PLC_RUN_TIMEOUT /
#                      STATE_SET_FAILED from the readback)
# Precondition refusals (BUILD_REQUIRED, BUILD_SELECTION_*, PLATFORM_*, AMS_NETID_REQUIRED ...)
# before anything was sent never write one: nothing was changed.
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
#   It is removed only by Clear-TcLifecycleBlock in this process: a record removed from the file by
#   another process (or by hand) still blocks here until then.
#   Lock time-out / unreadable file -> every target blocked ('state-unreadable').
#   Every Clear-TcLifecycleBlock appends its receipt to lifecycle-block-history.jsonl (best effort).
#
# Windows PowerShell 5.1; this source file is ASCII (the user-facing stop text is
# $script:TcLifecycleStopText in ConvertTo-TcAdsErrorCode.ps1, UTF-8 with BOM).

$script:TcLifecycleBlockLocal = @{}
$script:TcLifecycleUnknownKey = '<unknown>'
$script:TcLifecycleCorruptKey = '<corrupt>'
# Enable-TcConfig failure codes that never record a block: a precondition that refused before
# anything changed (also when returned later, e.g. LIFECYCLE_BLOCKED of a nested command)
$script:TcLifecyclePreconditionCodes = @(
    'NOT_CONNECTED', 'AMS_NETID_REQUIRED', 'LIFECYCLE_BLOCKED',
    'BUILD_REQUIRED', 'BUILD_SELECTION_CHANGED', 'BUILD_SELECTION_UNKNOWN',
    'PLATFORM_MISMATCH', 'PLATFORM_PROJECT_MISMATCH', 'PLATFORM_NOT_FOUND', 'PLATFORM_SET_FAILED', 'PLATFORM_UNKNOWN',
    'VARIANT_READ_FAILED', 'VARIANT_GROUP_ACTIVE'
)

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
        [string]$Step
    )
    $key = ConvertTo-TcLifecycleKey $AmsNetId
    $entry = [PSCustomObject]@{
        amsNetId       = $(if ([string]::IsNullOrWhiteSpace($AmsNetId)) { $null } else { $AmsNetId.Trim() })
        command        = $Command
        errorCode      = $ErrorCode
        message        = $Message
        requestedState = $RequestedState
        reachedState   = $ReachedState
        step           = $Step
        time           = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
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
        $copy | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue "LIFECYCLE_BLOCKED was recorded in this process only, not in $(Get-TcLifecycleBlockFile) ($why): another process (or an MCP bridge restart) will not see it." -Force
        return $copy
    }
    $entry
}

# File + memory records as one hashtable (memory wins), or @{ Error = text } when unreadable.
function Get-TcLifecycleBlockEntries {
    $r = $null
    try { $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -Body { Read-TcLifecycleBlockState } }
    catch { $r = @{ Locked = $false; Error = $_.Exception.Message } }
    if (-not $r.Locked -or $null -ne $r.Error) { return @{ Error = [string]$r.Error; Entries = $null } }
    $entries = @{}
    if ($null -ne $r.Result) { foreach ($k in $r.Result.Keys) { $entries[$k] = $r.Result[$k] } }
    foreach ($k in $script:TcLifecycleBlockLocal.Keys) { $entries[$k] = $script:TcLifecycleBlockLocal[$k] }
    @{ Error = $null; Entries = $entries }
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
    param([string]$AmsNetId)
    $all = Get-TcLifecycleBlockEntries
    if ($null -ne $all.Error) {
        return [PSCustomObject]@{
            amsNetId = $AmsNetId; command = $null; errorCode = 'state-unreadable'
            message = "the lifecycle block state $(Get-TcLifecycleBlockFile) could not be checked ($($all.Error)); every target is blocked until it is readable"
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
        name). Returns @{ Removed (entry or $null); Warning }. Never throws.
    #>
    param([string]$AmsNetId)
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
            @{ Old = $old }
        }
    }
    catch { $r = @{ Locked = $false; Error = $_.Exception.Message } }
    if ($null -eq $r -or -not $r.Locked -or $null -ne $r.Error) {
        $why = if ($null -ne $r) { $r.Error } else { 'unknown error' }
        # the memory copy is gone but the file still blocks: put it back, nothing changed
        if ($null -ne $removed) { $script:TcLifecycleBlockLocal[$key] = $removed }
        return @{ Removed = $null; Warning = "$(Get-TcLifecycleBlockFile) not updated ($why); the target stays blocked." }
    }
    if ($null -ne $r.Result.Old) { $removed = $r.Result.Old }
    @{ Removed = $removed; Warning = $null }
}

# All records (file + memory) as @{ key; record }, for Clear-TcLifecycleBlock's report; $null when unreadable.
function Get-TcLifecycleBlockList {
    $all = Get-TcLifecycleBlockEntries
    if ($null -ne $all.Error) { return $null }
    @($all.Entries.Keys | Sort-Object | ForEach-Object { [PSCustomObject]@{ key = $_; record = $all.Entries[$_] } })
}

# Target AmsNetId of the IDE (GetTargetNetId), else the ADS session, else $null. Never throws.
function Resolve-TcLifecycleNetId {
    param($SysManager)
    $id = $null
    try {
        $sm = $SysManager
        if ($null -eq $sm) { $sm = Get-TcSysManager }
        if ($null -ne $sm) { $id = [string](Invoke-TcComRetry -OperationName 'GetTargetNetId' -MaxRetries 2 -ScriptBlock { $sm.GetTargetNetId() }) }
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
        data.notRun = $true). The caller returns it and does nothing else.
    #>
    param([string]$AmsNetId, [Parameter(Mandatory)][string]$Command)
    $b = Get-TcLifecycleBlock -AmsNetId $AmsNetId
    if ($null -eq $b) { return $null }
    $target = if ([string]::IsNullOrWhiteSpace($AmsNetId)) { '<target AmsNetId unknown>' } elseif (Test-TcLoopbackNetId $AmsNetId) { "$AmsNetId (loopback: compared with every record)" } else { $AmsNetId }
    $what = if ([string]$b.errorCode -in @('state-unreadable', 'state-corrupt')) { [string]$b.message }
            else { "$($b.command) failed at $($b.time) with $($b.errorCode) (requested '$($b.requestedState)', read back '$($b.reachedState)') on $(if ($b.amsNetId) { $b.amsNetId } else { 'an unknown target' })" }
    New-TcResult -Success $false -ErrorCode 'LIFECYCLE_BLOCKED' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED') `
        -ErrorMessage "$Command NOT RUN on ${target}: the lifecycle is blocked because $what. Nothing was sent." `
        -Data ([PSCustomObject]@{ command = $Command; amsNetId = $AmsNetId; notRun = $true; lifecycleBlock = $b })
}

function Add-TcLifecycleBlockResult {
    <#
    .SYNOPSIS
        #68: records the block for a failed command after a runtime-changing request and returns
        -Result with data.lifecycleBlock and the hint prefixed by the stop instruction
        ($script:TcLifecycleStopText). Never throws.
    #>
    param([object]$Result, [Parameter(Mandatory)][string]$Command, [string]$AmsNetId, [string]$RequestedState, [string]$ReachedState, [string]$Step)
    if ($null -eq $Result) { return $Result }
    $code = $null; $msg = $null
    if ($null -ne $Result.error) { $code = [string]$Result.error.code; $msg = [string]$Result.error.message }
    $b = Set-TcLifecycleBlock -AmsNetId $AmsNetId -Command $Command -ErrorCode $code -Message $msg -RequestedState $RequestedState -ReachedState $ReachedState -Step $Step
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
        $marker = $script:TcLifecycleStopMarker
        if ($old.StartsWith($script:TcLifecycleStopPrefix) -and $old.Contains($marker)) { $old = $old.Substring($old.IndexOf($marker) + $marker.Length).Trim() }
        $tgt = if ([string]::IsNullOrWhiteSpace($AmsNetId)) { '<unknown>' } elseif (Test-TcLoopbackNetId $AmsNetId) { "$AmsNetId (<unknown>)" } else { $AmsNetId }
        $stop = $script:TcLifecycleStopText.Replace('{target}', $tgt)
        $Result.error | Add-Member -NotePropertyName 'hint' -NotePropertyValue "$stop $old".TrimEnd() -Force
    }
    $Result
}
