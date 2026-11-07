# #196: Connect-TcIde -TakeOverOrphan. An IDE launched by another TcAuto session whose host
# process (MCP bridge / PowerShell) is gone stays blocked forever (IDE_LAUNCH_PENDING probe
# 'other-session', hostState 'gone'). The caller may explicitly take it over, and only when ALL of
# these hold (otherwise nothing is attached or changed):
#   - -SolutionPath given and the newest valid launch record of that .sln (same normalised path,
#     Find-TcLaunchRecordForSolution: pid + start time + image name still the same process) exists;
#   - its host is 'gone' (Get-TcLaunchRecordHostState: hostPid not running, or running with another
#     start time - a recycled pid never counts as the host);
#   - its pid is confirmed (pidSource rot-identity / main-window), -ProgId (when given) is the
#     ProgID it was launched with;
#   - the ROT has a READY DTE of that very pid that has this .sln open;
#   - no modal dialog and a completed scan (Find-TcIdeModalDialog -ProcessId).
# Returns @{ Result = <failed TcResult> } (refused) or @{ Candidate; Record; OtherSession }; the
# record itself is changed by the caller (Set-TcLaunchRecordTakeover, under the lock).
# reason: solution-path-required | no-launch-record | owned-by-this-session | host-alive |
# pid-unconfirmed | progid-mismatch | not-in-rot | solution-mismatch | ide-busy (dialog / incomplete
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
    $other = [PSCustomObject]@{ hostPid = $rec.hostPid; hostState = $hostState; moduleInstanceId = $rec.moduleInstanceId; processId = [int]$rec.pid; pidSource = [string]$rec.pidSource }
    if ($hostState -eq 'self') {
        return (& $refuse 'owned-by-this-session' "the IDE (pid $($rec.pid)) was launched by this session; there is nothing to take over (Connect-TcIde -SolutionPath without -TakeOverOrphan attaches it)" $other $rec)
    }
    if ($hostState -ne 'gone') {
        return (& $refuse 'host-alive' "the TcAuto session that launched the IDE (pid $($rec.pid)) is still running or cannot be verified (host pid $($rec.hostPid), hostState $hostState)" $other $rec)
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
    if ($null -ne $dialog) {
        $reason = if (Test-TcModalScanIncomplete $dialog) { 'modal-scan-incomplete' } else { 'modal-dialog' }
        return @{ Result = (New-TcModalDialogResult -Dialog $dialog -Operation "Connect-TcIde -TakeOverOrphan (IDE pid $procId; not taken over)" -Data (& $newData $reason $other $rec)) }
    }
    if (-not $isReady) {
        return (& $refuse 'ide-busy' "the IDE (pid $procId) rejects DTE calls ($(if ($c.busy) { 'RPC_E_CALL_REJECTED' } else { 'DTE.Version empty' })) and no modal dialog was found" $other $rec)
    }
    @{ Candidate = $c; Record = $rec; OtherSession = $other }
}
