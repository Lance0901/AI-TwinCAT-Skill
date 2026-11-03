# Lifecycle block (#68): "a public command sent a runtime-changing request and the readback did
# not reach the requested state" - fail closed until a person has looked at it.
#
# Written ONLY after a runtime-changing request was sent and its postcondition failed:
#   Set-TcSystemState  WriteControl sent, SYSTEM_STATE_TIMEOUT / SYSTEM_STATE_MISMATCH
#   Enable-TcConfig    after set-config / ActivateConfiguration() was sent:
#                      $script:TcLifecyclePostconditionCodes (SYSTEM_STATE_*, RUNTIME_STATE_MISMATCH,
#                      BOOT_PACKAGE_MISMATCH, PLC_NOT_LOADED, PLC_RUN_TIMEOUT)
#   Set-TcPlcState     WriteControl sent, the port did not reach Run / Stop (PLC_RUN_TIMEOUT /
#                      STATE_SET_FAILED from the readback)
# Precondition refusals (BUILD_REQUIRED, BUILD_SELECTION_*, PLATFORM_*, AMS_NETID_REQUIRED ...)
# never write one: nothing was changed.
#
# While a record exists for the target, every runtime-changing public command returns
# LIFECYCLE_BLOCKED (success = false, data.lifecycleBlock) and does nothing (Test-TcLifecycleBlock):
# Set-TcSystemState, Enable-TcConfig, Enter-TcPlcOnline (and Send-TcPlcProgram through it),
# Set-TcPlcState, Write-TcVariable, Invoke-TcTest, Invoke-TcTestCycle,
# Set-TcComModuleParameter -Online -DryRun $false. Read-only / diagnostic commands are not blocked.
# Nothing removes a record automatically (a later success cannot happen: the commands that could
# succeed are blocked); only Clear-TcLifecycleBlock does, after the user agreed.
#
# Storage - same directory and the same fail-closed rules as build-required.json
# (Private/Set-TcBuildRequired.ps1):
#   <dir>\lifecycle-block.json  { "<amsnetid lower case>": { amsNetId; command; errorCode; message;
#                                  requestedState; reachedState; step; time }, ... }
#   <dir> = $env:TCAUTO_STATE_DIR (tests) or %TEMP%\TwinCATAutomation.
#   One record per target AmsNetId: another target is not affected. A record written while the
#   AmsNetId was not known goes to '<unknown>' and blocks every target; a command that cannot
#   resolve its target AmsNetId is blocked by any record (fail closed).
#   Note: '127.0.0.1.1.1' and the real AmsNetId of the local system are different keys.
#   Read-modify-write under a named mutex (Invoke-TcBuildRequiredLocked with its own name,
#   'Local\TwinCATAutomation.LifecycleBlock[.<hash>]'), file replaced with [IO.File]::Replace /
#   Move (no window without a file). An in-memory copy ($script:TcLifecycleBlockLocal) keeps
#   blocking in this process when the file cannot be written.
#   A file that cannot be read or parsed (or a lock time-out) blocks every target
#   ('state-unreadable'); Clear-TcLifecycleBlock moves an unparseable file aside
#   (lifecycle-block.json.corrupt-<time>).
#   Every Clear-TcLifecycleBlock appends its receipt to lifecycle-block-history.jsonl (best effort).
#
# Windows PowerShell 5.1; this source file is ASCII.

$script:TcLifecycleBlockLocal = @{}
$script:TcLifecycleUnknownKey = '<unknown>'
# Enable-TcConfig failure codes that are a failed postcondition after a runtime-changing request
$script:TcLifecyclePostconditionCodes = @('SYSTEM_STATE_TIMEOUT', 'SYSTEM_STATE_MISMATCH', 'RUNTIME_STATE_MISMATCH', 'BOOT_PACKAGE_MISMATCH', 'PLC_NOT_LOADED', 'PLC_RUN_TIMEOUT')

function Get-TcLifecycleBlockFile {
    Join-Path (Split-Path -Parent (Get-TcBuildRequiredFile)) 'lifecycle-block.json'
}

function Get-TcLifecycleBlockMutexName {
    (Get-TcBuildRequiredMutexName) -replace '\.BuildRequired', '.LifecycleBlock'
}

function ConvertTo-TcLifecycleKey {
    param([string]$AmsNetId)
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) { return $script:TcLifecycleUnknownKey }
    $AmsNetId.Trim().ToLowerInvariant()
}

# Under the lock. Returns a hashtable key -> entry; throws when the file cannot be parsed.
function Read-TcLifecycleBlockState {
    $file = Get-TcLifecycleBlockFile
    $entries = @{}
    if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { return $entries }
    $text = [IO.File]::ReadAllText($file)
    if ([string]::IsNullOrWhiteSpace($text)) { return $entries }
    $obj = ConvertFrom-Json -InputObject $text -ErrorAction Stop
    foreach ($p in $obj.PSObject.Properties) { $entries[$p.Name] = $p.Value }
    $entries
}

# Under the lock. Throws when the file cannot be replaced after the retries (the .tmp is removed).
function Write-TcLifecycleBlockState {
    param([hashtable]$Entries)
    $file = Get-TcLifecycleBlockFile
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
            [IO.File]::WriteAllText($tmp, ([PSCustomObject]$o | ConvertTo-Json -Depth 5), (New-Object System.Text.UTF8Encoding($false)))
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

function Set-TcLifecycleBlock {
    <#
    .SYNOPSIS
        #68: records the lifecycle block of -AmsNetId (one record per target, the newest wins).
        Never throws: returns the entry; entry.stateWarning is set when only the in-memory copy
        could be kept (file not lockable / writable).
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
            $st = @{}
            try { $st = Read-TcLifecycleBlockState } catch { $st = @{} }   # unparseable: rewritten with this record (the memory copy blocks anyway)
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

function Get-TcLifecycleBlock {
    <#
    .SYNOPSIS
        #68: the record that blocks -AmsNetId, or $null. File and in-memory records are merged
        (memory wins). '<unknown>' blocks every target; an empty -AmsNetId is blocked by any
        record. Lock / read / parse failure -> a synthetic 'state-unreadable' record (fail closed).
    #>
    [CmdletBinding()]
    param([string]$AmsNetId)
    $r = $null
    try { $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -Body { Read-TcLifecycleBlockState } }
    catch { $r = @{ Locked = $false; Error = $_.Exception.Message } }
    if (-not $r.Locked -or $null -ne $r.Error) {
        return [PSCustomObject]@{
            amsNetId = $AmsNetId; command = $null; errorCode = 'state-unreadable'
            message = "the lifecycle block state $(Get-TcLifecycleBlockFile) could not be checked ($($r.Error)); every target is blocked until it is readable (Clear-TcLifecycleBlock moves an unparseable file aside)"
            requestedState = $null; reachedState = $null; step = $null; time = $null
        }
    }
    $entries = @{}
    if ($null -ne $r.Result) { foreach ($k in $r.Result.Keys) { $entries[$k] = $r.Result[$k] } }
    foreach ($k in $script:TcLifecycleBlockLocal.Keys) { $entries[$k] = $script:TcLifecycleBlockLocal[$k] }
    if ($entries.Count -eq 0) { return $null }
    $key = ConvertTo-TcLifecycleKey $AmsNetId
    if ($entries.ContainsKey($key)) { return $entries[$key] }
    if ($entries.ContainsKey($script:TcLifecycleUnknownKey)) { return $entries[$script:TcLifecycleUnknownKey] }
    if ($key -eq $script:TcLifecycleUnknownKey) { return @($entries.Values | Sort-Object { [string]$_.time })[-1] }
    $null
}

function Remove-TcLifecycleBlock {
    <#
    .SYNOPSIS
        #68: removes the record of -AmsNetId (memory and file). Returns @{ Removed (entry or
        $null); Warning; CorruptBackup }. An unparseable file is moved aside first (its records
        are gone: the caller reports CorruptBackup). Never throws.
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
            $backup = $null
            $st = $null
            try { $st = Read-TcLifecycleBlockState }
            catch {
                $file = Get-TcLifecycleBlockFile
                $backup = "$file.corrupt-$((Get-Date).ToString('yyyyMMdd-HHmmss-fff'))"
                [IO.File]::Move($file, $backup)
                $st = @{}
            }
            $old = $null
            if ($st.ContainsKey($key)) { $old = $st[$key]; $null = $st.Remove($key) }
            Write-TcLifecycleBlockState -Entries $st
            @{ Old = $old; Backup = $backup }
        }
    }
    catch { $r = @{ Locked = $false; Error = $_.Exception.Message } }
    if ($null -eq $r -or -not $r.Locked -or $null -ne $r.Error) {
        $why = if ($null -ne $r) { $r.Error } else { 'unknown error' }
        # the memory copy is gone but the file still blocks: put it back, nothing changed
        if ($null -ne $removed) { $script:TcLifecycleBlockLocal[$key] = $removed }
        return @{ Removed = $null; Warning = "$(Get-TcLifecycleBlockFile) not updated ($why); the target stays blocked."; CorruptBackup = $null }
    }
    if ($null -ne $r.Result.Old) { $removed = $r.Result.Old }
    @{ Removed = $removed; Warning = $null; CorruptBackup = $r.Result.Backup }
}

# All records (file + memory), for Clear-TcLifecycleBlock's report; $null when unreadable.
function Get-TcLifecycleBlockList {
    $r = $null
    try { $r = Invoke-TcBuildRequiredLocked -MutexName (Get-TcLifecycleBlockMutexName) -Body { Read-TcLifecycleBlockState } } catch { return $null }
    if (-not $r.Locked -or $null -ne $r.Error) { return $null }
    $entries = @{}
    if ($null -ne $r.Result) { foreach ($k in $r.Result.Keys) { $entries[$k] = $r.Result[$k] } }
    foreach ($k in $script:TcLifecycleBlockLocal.Keys) { $entries[$k] = $script:TcLifecycleBlockLocal[$k] }
    @($entries.Keys | Sort-Object | ForEach-Object { $entries[$_] })
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
    $target = if ([string]::IsNullOrWhiteSpace($AmsNetId)) { '<target AmsNetId unknown>' } else { $AmsNetId }
    $what = if ([string]$b.errorCode -eq 'state-unreadable') { [string]$b.message }
            else { "$($b.command) failed at $($b.time) with $($b.errorCode) (requested '$($b.requestedState)', read back '$($b.reachedState)') on $($b.amsNetId)" }
    New-TcResult -Success $false -ErrorCode 'LIFECYCLE_BLOCKED' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED') `
        -ErrorMessage "$Command NOT RUN on ${target}: the lifecycle is blocked because $what. Nothing was sent." `
        -Data ([PSCustomObject]@{ command = $Command; amsNetId = $AmsNetId; notRun = $true; lifecycleBlock = $b })
}

function Add-TcLifecycleBlockResult {
    <#
    .SYNOPSIS
        #68: records the block for a failed postcondition and returns -Result with
        data.lifecycleBlock and the hint prefixed by the stop instruction. Never throws.
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
        $marker = ' Diagnosis for the user:'
        if ($old.StartsWith('LIFECYCLE_BLOCKED is now recorded') -and $old.Contains($marker)) { $old = $old.Substring($old.IndexOf($marker) + $marker.Length).Trim() }
        $stop ="LIFECYCLE_BLOCKED is now recorded for $(if ([string]::IsNullOrWhiteSpace($AmsNetId)) { 'every target (AmsNetId unknown)' } else { $AmsNetId }) (data.lifecycleBlock): stop here, mark the remaining steps NOT RUN and report this result to the user. Every runtime-changing command is refused until the user agrees to Clear-TcLifecycleBlock -Reason '<why>'; do not try another control channel (raw ADS, COM, DTE, GUI, console). Diagnosis for the user:"
        $Result.error | Add-Member -NotePropertyName 'hint' -NotePropertyValue "$stop $old".TrimEnd() -Force
    }
    $Result
}
