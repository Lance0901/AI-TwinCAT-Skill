# #196: Connect-TcIde -TakeOverOrphan. An IDE launched by another TcAuto session whose host
# process (MCP bridge / PowerShell) is gone stays blocked forever (IDE_LAUNCH_PENDING probe
# 'other-session', hostState 'gone'). The caller may explicitly take it over, and only when ALL of
# these hold (otherwise nothing is attached or changed):
#   - -SolutionPath given and the newest valid launch record of that .sln (same normalised path,
#     Find-TcLaunchRecordForSolution: pid + start time + image name still the same process) exists;
#   - its host is 'gone' (Get-TcLaunchRecordHostState: hostPid not running, or running with another
#     start time - a recycled pid never counts as the host);
#   - #196 review B1: its owner process (the MCP server / launcher, ownerPid + ownerStartTime) is
#     'gone' too: a gone host alone is only a restarted bridge (BRIDGE_TIMEOUT, IDE_MODAL_DIALOG,
#     ReloadModule) of a session that may still run. A record with an ownerId but no ownerPid /
#     ownerStartTime (written before this check), or an owner whose start time cannot be read, is
#     refused ('owner-unverifiable'). A record without ownerId (a manual PowerShell) has no owner
#     process: the host decides alone, as before;
#   - its pid is confirmed (pidSource rot-identity / main-window), -ProgId (when given) is the
#     ProgID it was launched with;
#   - the ROT has a READY DTE of that very pid that has this .sln open;
#   - no modal dialog and a completed scan (Find-TcIdeModalDialog -ProcessId). #201: a known reload
#     prompt is answered without reloading (Invoke-TcOrphanReloadPromptAnswer, at most 5), then the
#     DTE is read again (ide-busy / solution-mismatch when it does not answer / has another .sln);
#     any other dialog or a prompt that stays up -> IDE_MODAL_DIALOG with the IDE_MODAL_DIALOG_ORPHAN
#     hint (nothing is attached: Reset-TcSolution / Disconnect-TcIde would answer NOT_CONNECTED).
# Returns @{ Result = <failed TcResult> } (refused) or @{ Candidate; Record; OtherSession;
# ReloadPrompts (answers sent, [] when none) }; the
# record itself is changed by the caller (Set-TcLaunchRecordTakeover, under the lock).
# reason: solution-path-required | no-launch-record | owned-by-this-session | host-alive |
# owner-alive | owner-unverifiable | pid-unconfirmed | progid-mismatch | not-in-rot | solution-mismatch | ide-busy (dialog / incomplete
# scan: IDE_MODAL_DIALOG / MODAL_SCAN_INCOMPLETE; record file unreadable: LAUNCH_RECORD_UNAVAILABLE).
function Resolve-TcOrphanTakeover {
    [CmdletBinding()]
    param(
        [AllowNull()][string]$SolutionPath,
        [AllowNull()][string]$ProgId,
        [object[]]$Candidates = @(),
        [object[]]$UnreadableCandidates = @()
    )
    $summary = @(@($Candidates) + @($UnreadableCandidates) | Where-Object { $null -ne $_ } | ForEach-Object { [PSCustomObject]@{ progId = $_.progId; solution = $_.solution; pid = $_.pid } })
    $newData = {
        param([string]$Reason, [object]$Other, [object]$Rec)
        $d = [PSCustomObject][ordered]@{
            reason         = $Reason
            takenOver      = $false
            attached       = $false
            ownedBySession = $false
            launched       = $false
            solution       = $SolutionPath
            ideProcessId   = $(if ($null -ne $Other) { [int]$Other.processId } else { 0 })
            otherSession   = $Other
            candidates     = $summary
        }
        if ($null -ne $Rec) { $d | Add-Member -NotePropertyName 'launchId' -NotePropertyValue ([string]$Rec.launchId) }
        if ($null -ne $script:TcLaunchRecordWarning) { $d | Add-Member -NotePropertyName 'launchRecordWarning' -NotePropertyValue $script:TcLaunchRecordWarning -Force }
        $d
    }
    $refuse = {
        param([string]$Reason, [string]$Why, [object]$Other, [object]$Rec)
        @{ Result = (New-TcResult -Success $false `
                    -ErrorMessage "ORPHAN_TAKEOVER_REFUSED ($Reason): $Why. Nothing was attached, owned or changed." `
                    -ErrorCode 'ORPHAN_TAKEOVER_REFUSED' -Hint (Get-TcErrorHint -Code 'ORPHAN_TAKEOVER_REFUSED') -Data (& $newData $Reason $Other $Rec)) }
    }

    if ([string]::IsNullOrWhiteSpace($SolutionPath)) {
        return (& $refuse 'solution-path-required' '-TakeOverOrphan needs -SolutionPath (the launch record is matched by its solution)' $null $null)
    }
    $file = Get-TcLaunchRecords
    if ($file.State -notin 'ok', 'missing') {
        $d = & $newData 'launch-record-unavailable' $null $null
        $d | Add-Member -NotePropertyName 'launchRecordWarning' -NotePropertyValue ([string]$script:TcLaunchRecordWarning) -Force
        return @{ Result = (New-TcResult -Success $false `
                    -ErrorMessage "LAUNCH_RECORD_UNAVAILABLE: the launch records could not be read ($($file.State): $($file.Error)); -TakeOverOrphan needs them, nothing was attached or taken over." `
                    -ErrorCode 'LAUNCH_RECORD_UNAVAILABLE' -Hint (Get-TcErrorHint -Code 'LAUNCH_RECORD_UNAVAILABLE') -Data $d) }
    }
    $rec = @($file.Records | Where-Object { [string]::Equals([string]$_.solution, $SolutionPath, [StringComparison]::OrdinalIgnoreCase) } | Sort-Object { try { ConvertTo-TcUtcDate $_.createdAt } catch { [DateTime]::MinValue } } -Descending) | Select-Object -First 1
    if ($null -eq $rec) {
        return (& $refuse 'no-launch-record' "no launch record of a still running IDE names '$SolutionPath'" $null $null)
    }
    $hostState = Get-TcLaunchRecordHostState -Record $rec
    $ownerState = Get-TcLaunchRecordOwnerState -Record $rec
    $ownerPid = $null; try { if ($null -ne $rec.PSObject.Properties['ownerPid']) { $ownerPid = $rec.ownerPid } } catch { $ownerPid = $null }
    $other = [PSCustomObject]@{ hostPid = $rec.hostPid; hostState = $hostState; ownerPid = $ownerPid; ownerState = $ownerState; moduleInstanceId = $rec.moduleInstanceId; processId = [int]$rec.pid; pidSource = [string]$rec.pidSource }
    if ($hostState -eq 'self') {
        return (& $refuse 'owned-by-this-session' "the IDE (pid $($rec.pid)) was launched by this session; there is nothing to take over (Connect-TcIde -SolutionPath without -TakeOverOrphan attaches it)" $other $rec)
    }
    if ($hostState -ne 'gone') {
        return (& $refuse 'host-alive' "the TcAuto session that launched the IDE (pid $($rec.pid)) is still running or cannot be verified (host pid $($rec.hostPid), hostState $hostState)" $other $rec)
    }
    if ($ownerState -eq 'self') {
        return (& $refuse 'owned-by-this-session' "the IDE (pid $($rec.pid)) was launched by an earlier bridge of this MCP server (same ownerId); Connect-TcIde -SolutionPath without -TakeOverOrphan attaches it" $other $rec)
    }
    if ($ownerState -eq 'alive') {
        return (& $refuse 'owner-alive' "the bridge that launched the IDE (pid $($rec.pid)) is gone, but its MCP server (owner pid $ownerPid) is still running: that session restarted its bridge (BRIDGE_TIMEOUT / IDE_MODAL_DIALOG / ReloadModule) and still owns the IDE" $other $rec)
    }
    if ($ownerState -eq 'unverifiable') {
        return (& $refuse 'owner-unverifiable' "the bridge that launched the IDE (pid $($rec.pid)) is gone, but whether its MCP server (ownerId $($rec.ownerId), owner pid $(if ($null -ne $ownerPid) { $ownerPid } else { 'not recorded' })) has ended cannot be verified" $other $rec)
    }
    if (-not (Test-TcLaunchRecordConfirmed -Record $rec)) {
        return (& $refuse 'pid-unconfirmed' "the process id of that launch was never confirmed (pidSource '$($rec.pidSource)'), so the IDE cannot be identified" $other $rec)
    }
    if (-not [string]::IsNullOrWhiteSpace($ProgId) -and -not ([string]$rec.progId -ieq $ProgId)) {
        return (& $refuse 'progid-mismatch' "the IDE was launched as $($rec.progId), not the requested -ProgId $ProgId" $other $rec)
    }
    $procId = [int]$rec.pid
    $c = @(@($Candidates) + @($UnreadableCandidates) | Where-Object { $null -ne $_ -and [int]$_.pid -eq $procId }) | Select-Object -First 1
    if ($null -eq $c) {
        return (& $refuse 'not-in-rot' "the IDE (pid $procId) has no DTE in the Running Object Table, so it cannot be attached" $other $rec)
    }
    $isReady = -not ([bool]$c.busy) -and -not ($c.PSObject.Properties['unreadable'] -and [bool]$c.unreadable)
    if ($isReady) {
        $seen = [string]$c.normalizedSolution
        if (-not [string]::Equals($seen, $SolutionPath, [StringComparison]::OrdinalIgnoreCase)) {
            $r = & $refuse 'solution-mismatch' "the IDE (pid $procId) has '$seen' open, not '$SolutionPath'" $other $rec
            $r.Result.data | Add-Member -NotePropertyName 'rotSolution' -NotePropertyValue $seen
            return $r
        }
    }
    # A dialog makes every DTE call block: checked before anything is taken over (busy IDEs too)
    $dialog = Find-TcIdeModalDialog -ProcessId $procId
    # #201: a known reload prompt is answered "do not reload" (every ownership condition above has
    # passed); the IDE keeps what it has in memory - unsaved work of the ended session is not
    # thrown away - and the caller loads the disk state with Reset-TcSolution once it owns the IDE.
    $prompts = [System.Collections.Generic.List[object]]::new()
    $handled = 0
    while ($null -ne $dialog -and -not (Test-TcModalScanIncomplete $dialog) -and [string]$dialog.Kind -eq 'reload-prompt' -and $handled -lt 5) {
        $handled++
        $step = Invoke-TcOrphanReloadPromptAnswer -Dialog $dialog -ProcessId $procId
        foreach ($a in $step.Attempts) { $prompts.Add($a) }
        if (-not $step.Dismissed) { break }
        $dialog = Find-TcOrphanDialogAfterAnswer -ProcessId $procId
    }
    $withPrompts = {
        param([object]$D)
        if ($prompts.Count -gt 0) { $D | Add-Member -NotePropertyName 'reloadPromptAttempts' -NotePropertyValue @($prompts.ToArray()) -Force }
        $D
    }
    if ($null -ne $dialog) {
        $reason = if (Test-TcModalScanIncomplete $dialog) { 'modal-scan-incomplete' } else { 'modal-dialog' }
        $op = if ($prompts.Count -gt 0) { "Connect-TcIde -TakeOverOrphan (IDE pid $procId; $($prompts.Count) answer(s) sent to its reload prompt(s), not taken over)" } else { "Connect-TcIde -TakeOverOrphan (IDE pid $procId; not taken over)" }
        return @{ Result = (New-TcModalDialogResult -Dialog $dialog -Operation $op -HintCode 'IDE_MODAL_DIALOG_ORPHAN' -Data (& $withPrompts (& $newData $reason $other $rec))) }
    }
    if ($prompts.Count -gt 0) {
        # The DTE was blocked while the prompt was up: read it again (busy / unreadable / solution)
        $seen = $null; $readError = $null
        try {
            $seen = Invoke-TcComRetry -MaxRetries 5 -TimeoutSec 30 -OperationName 'Orphan takeover: DTE.Version / Solution.FullName after the reload prompt' -ScriptBlock {
                $ver = [string]$c.Object.Version
                if ([string]::IsNullOrWhiteSpace($ver)) { throw 'DTE.Version is empty' }
                $sol = $c.Object.Solution
                if ($null -ne $sol) { [string]$sol.FullName } else { '' }
            }
        }
        catch { $seen = $null; $readError = $_.Exception.Message }
        if ($null -eq $seen) {
            $r = & $refuse 'ide-busy' "the reload prompt of the IDE (pid $procId) was answered, but its DTE still does not answer ($readError)" $other $rec
            $null = & $withPrompts $r.Result.data
            return $r
        }
        $seenL = if ([string]::IsNullOrWhiteSpace($seen)) { '' } else { try { Get-TcLongPath $seen } catch { $seen } }
        if (-not [string]::Equals($seenL, $SolutionPath, [StringComparison]::OrdinalIgnoreCase)) {
            $r = & $refuse 'solution-mismatch' "the IDE (pid $procId) has '$seenL' open, not '$SolutionPath' (read after its reload prompt was answered)" $other $rec
            $r.Result.data | Add-Member -NotePropertyName 'rotSolution' -NotePropertyValue $seenL
            $null = & $withPrompts $r.Result.data
            return $r
        }
        $c = [PSCustomObject]@{
            progId = $c.progId; solution = $seen; pid = $c.pid; hasTcProject = $false; normalizedSolution = $seenL
            busy = $false; displayName = [string]$c.displayName; Object = $c.Object
        }
        $isReady = $true
    }
    if (-not $isReady) {
        return (& $refuse 'ide-busy' "the IDE (pid $procId) rejects DTE calls ($(if ($c.busy) { 'RPC_E_CALL_REJECTED' } else { 'DTE.Version empty' })) and no modal dialog was found" $other $rec)
    }
    @{ Candidate = $c; Record = $rec; OtherSession = $other; ReloadPrompts = @($prompts.ToArray()) }
}

# #201: one reload prompt of an orphan IDE (not attached yet), answered without reloading, the way
# Reset-TcSolution already answers these prompts (control ids, any UI language):
#   solution: Ignore (control id 1412; then WM_CLOSE) - measured 2026-11-08, 4024 TcXaeShell en-US,
#             buttons 259 &Reload / 1412 &Ignore (#201); VS2022 zh-TW 2026-11-03 (#106)
#   project:  No (IDNO 7) - the XAE prompt is MB_YESNO, WM_CLOSE has no effect on it (see
#             Close-TcReloadPrompt); No keeps the project in memory
#   file:     WM_CLOSE (= No: the editor keeps its buffer)
# Returns @{ Dismissed = [bool]; Attempts = [object[]] }. Stops after an answer that reached a
# disabled prompt (nested dialog): the caller's next scan reports that dialog.
function Invoke-TcOrphanReloadPromptAnswer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object]$Dialog, [Parameter(Mandatory)][int]$ProcessId)
    $target = [string]$Dialog.ReloadTarget
    $answers = if ($target -eq 'project') { @('No') } elseif ($target -eq 'solution') { @('Ignore', 'Close') } else { @('Close') }
    $attempts = [System.Collections.Generic.List[object]]::new()
    $dismissed = $false
    foreach ($ans in $answers) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $try = Close-TcReloadPrompt -Dialog $Dialog -Answer $ans -TimeoutSec 8 -NoFollowUpScan -ProcessId $ProcessId
        $cid = 0; try { $cid = [int]$try.ControlId } catch { $cid = 0 }
        $attempts.Add([PSCustomObject][ordered]@{
                target    = $target
                answer    = $ans
                sent      = [bool]$try.Sent
                method    = $try.Method
                controlId = $cid
                dismissed = [bool]$try.Dismissed
                reason    = [string]$try.Reason
                sec       = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            })
        if ($try.Dismissed) { $dismissed = $true; break }
        if ([string]$try.WmCommand -eq 'not-posted-disabled') { break }
    }
    @{ Dismissed = $dismissed; Attempts = @($attempts.ToArray()) }
}

# #201: the scan right after a prompt closed may not complete while the IDE settles (#174): up to 3
# scans; still incomplete -> that record (the caller fails closed with MODAL_SCAN_INCOMPLETE).
function Find-TcOrphanDialogAfterAnswer {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int]$ProcessId)
    $d = $null
    for ($i = 0; $i -lt 3; $i++) {
        $d = Find-TcIdeModalDialog -ProcessId $ProcessId
        if ($null -eq $d -or -not (Test-TcModalScanIncomplete $d)) { return $d }
    }
    $d
}

# #196 review M2: Connect-TcIde -TakeOverOrphan attached the IDE, but a later step failed or writing
# the takeover was refused / failed: release the attach again (every COM reference and the IDE
# identity dropped) so nothing stays attached or owned. SilentMode is NOT touched: another session
# may have taken the IDE over meanwhile (record-changed) and relies on SilentMode = true; the
# session that launched the IDE had set it to true already.
function Reset-TcOrphanTakeoverAttach {
    [CmdletBinding()]
    param()
    foreach ($name in 'TcAutomationSettings', 'TcSysManager', 'TcDte') {
        $o = Get-Variable -Name $name -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $o -and [System.Runtime.InteropServices.Marshal]::IsComObject($o)) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($o) | Out-Null } catch { } }
        Set-Variable -Name $name -Scope Script -Value $null
    }
    $script:TcSilentMode = $false; $script:TcSilentModeOriginal = $null
    $script:TcIdeConnected = $false; $script:TcProgId = $null; $script:TcIdeMainHwnd = 0; $script:TcLastModalDialog = $null
    $script:TcSolutionPath = $null; $script:TcIdeProcessId = $null; $script:TcIdeStartTime = $null; $script:TcIdeSelectedBy = $null
}
