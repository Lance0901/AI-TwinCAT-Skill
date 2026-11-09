function Reset-TcSolution {
    <#
    .SYNOPSIS
        Clears the IDE's reload prompts and makes the IDE reload project files from disk:
        answers Yes to the XAE project reload prompt, or closes every document and the
        solution without saving, reopens the solution on the same IDE and reconnects.
    .DESCRIPTION
        Use after project files (.TcPOU, .TcGVL, .TcDUT, .plcproj ...) were changed ON DISK
        by another tool (an AI editor, git checkout, a generator) while the solution is open:
          - a file that is NOT open in a document window is picked up by XAE on its own
            within ~5 s; nothing to do.
          - a file that IS open in a document window makes XAE show the modal "File has
            been changed outside the environment. Reload the new file?" ~1 s after the
            write. It blocks every DTE call (IDE_MODAL_DIALOG, data.dialogKind
            'reload-prompt', reloadTarget 'file'), the Automation Interface has no reload
            command and the VS option AutoloadExternalChanges does not suppress it. Closing
            and reopening the solution is the dialog-free way (2026-10-20, 4024 32-bit XAE:
            20-25 s in total, Solution.Open 7-9 s + Connect-TcIde reconnect 12-13 s, against
            ~45 s for kill + relaunch).
          - a rewritten .plcproj (even with identical content, e.g. a generator) makes XAE
            show "The project file '...plcproj' has been modified outside of TwinCAT XAE. Do
            you want to reload the project?" (Kind 'reload-prompt', reloadTarget 'project').
            This one is answered Yes: XAE reloads the project itself, so no close / reopen
            is needed.
          - a rewritten .sln makes VS2022 show the solution prompt "solution 'X' was modified
            outside the environment" (zh-TW title "file modification detected"; #32770 with
            button control ids 259 Reload / 1412 Ignore: Kind 'reload-prompt', reloadTarget
            'solution', recognised by those ids only; measured 2026-11-03 VS2022 zh-TW,
            4024 TcXaeShell en-US the same ids, measured 2026-11-09 #201; other languages not
            verified). It is answered Ignore (control id 1412,
            #106) and the solution is closed and reopened from disk. Not Reload (259): measured
            2026-11-07 (4026 VS2022 zh-TW), Reload made VS ask at once "Save changes to the
            following items? X.sln X.tsproj*" (Save / Don't Save / Cancel) because Set-TcTarget
            had left the .tsproj dirty in memory, another modal dialog; Solution.Close($false)
            after Set-TcTarget showed no dialog.
        Write-TcPouCode / Add-TcPou write through COM, so they never trigger the prompt and
        never need this. Add-TcPou / Add-TcDut / Add-TcGvl / Add-TcLibrary save the project file
        (.plcproj) themselves (#76); a new object whose .plcproj entry was never saved (e.g.
        created in the XAE GUI or through raw COM) would be dropped by Solution.Close, which is
        what step 1b guards against.

        Steps:
          0. Memory baseline (#135 F5): when no dialog is up (that scan's dialog is step 1's
             first one), Get-TcSolutionLoadBaseline reads the PLC names below TIPC
             (Get-TcSysManager -Refresh). Only the fallback of step 6 when the .tsproj on disk
             names no PLC.
          1. Find-TcIdeModalDialog, repeated while reload prompts keep coming (at most 5):
             - reloadTarget 'project': Close-TcReloadPrompt -Answer Yes (IDYES clicked by
               control id through Close-TcMessageBox, language independent), waits up to
               15 s until the prompt is gone; data.answeredYes = true. After a Yes that closed
               the prompt step 1 ends without another dialog scan (#174: while XAE reloads the
               project the UI Automation scan ran into its 5 s timeout, measured 2026-11-08,
               4026 VS2022). The first DTE read after that Yes (the Yes-path wait, or the
               Solution.FullName read of the path / guard) scans FIRST and reads only after a
               complete scan found no dialog; an incomplete scan there means keep waiting, not
               failure (a DTE call blocked by a modal never returns). Yes failed: Yes once
               more, then -Answer No (IDNO 7; the full close / reopen reads the project from
               disk). No WM_CLOSE (#135 F4): the XAE prompt is an MB_YESNO box, which ignores
               WM_CLOSE - measured 2026-11-07, Windows 11 26200; MessageBox docs: without a
               Cancel button ESC / close has no effect,
               https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-messagebox.
               After a failed Yes, later project prompts start at No. A Yes that was sent
               (data.possiblyReloaded) makes every later failure record code-changed.
             - reloadTarget 'solution' (#106): -Answer Ignore (control id 1412), then WM_CLOSE;
               the full close / reopen reads the .sln from disk (why not Reload: see above).
             - reloadTarget 'file': WM_CLOSE (Close-TcReloadPrompt; the solution is reopened
               right after, so the answer does not matter).
             Each answer waits Min(15 s (WM_CLOSE 8 s), what is left of -TimeoutSec), at least
             1 s; with less than 1 s left no answer is tried. Still shown after every answer ->
             IDE_MODAL_DIALOG (fail closed). Every attempt is in data.reloadPromptAttempts.
             data.dismissedReloadPrompt = true when any prompt was dismissed. Any other
             dialog is reported as IDE_MODAL_DIALOG (it would block Solution.Close too); a
             scan that did not complete as MODAL_SCAN_INCOMPLETE, nothing closed (#42; inside
             a poll an incomplete scan only means "keep polling").
             Step 1 runs before every Solution / Solution.FullName read (also before the path
             of the open solution is read when neither -SolutionPath nor a module solution is
             known), and again whenever such a poll gets no answer and a reload prompt is up
             (#87: XAE shows the prompt some time after the file changed on disk, and while it
             is up Solution.FullName answered $null; real-machine check of this fix pending).
             A non-reload dialog seen in such a poll ends it with IDE_MODAL_DIALOG at once.
             The prompt can also come up after the guard (2026-11-02, 4026 VS2022: 3 of 4 runs).
             So the dialog is checked again when step 1b fails or reads back incomplete (a PLC
             not compared), right before Documents.CloseAll and Solution.Close, and when either
             fails (DTE.Solution answering $null counts as a failure, no method is called on it):
             a reload prompt runs step 1 and everything after it again (Yes-only path when only
             project prompts were answered), any other dialog returns IDE_MODAL_DIALOG instead
             of PROJECT_SAVE_FAILED / SOLUTION_CLOSE_FAILED. The polls share -TimeoutSec, the
             5-prompt limit covers the whole call. Real-machine check pending.
          When only project prompts were answered and our Yes click was really sent for each
          (a prompt that vanished without our click, or one answered No / Ignore / WM_CLOSE,
          forces the full path): steps 2-4 are
          SKIPPED. Solution.FullName is polled on the DTE we hold (500 ms, up to -TimeoutSec,
          data.reloadWaitSec; each round reads only after a complete dialog scan found no dialog)
          until XAE is back from the reload, then step 5 runs
          (data.reopenedSolution = false) and ITcSysManager is probed with
          LookupTreeItem('TIPC'). If Connect-TcIde fails (the previous connection state is
          restored) or the probe fails, the full path below runs on the old DTE
          (data.yesPathError says why). The reconnect, and the readback of step 6, run before
          success here too.
          1b. unsaved project structure (#76; skipped with -DiscardProjectChanges; the
             ITcSysManager is always taken fresh, Get-TcSysManager -Refresh: after a solution
             reload the cached one throws "System Manager already disposed!", #106): DTE
             Project.Saved / IsDirty do not report an unsaved CreateChild (measured 2026-10-28,
             4026 VisualStudio.DTE.17.0), so Get-TcUnsavedPlcObject compares the top-level PLC
             objects in XAE (POU / DUT / GVL / ITF) with the <Compile Include>
             list of each PLC's .plcproj on disk (data.projectCheck: per PLC checked / reason,
             missingOnDisk [file, relativePath, path, fileExists], extraOnDisk, complete).
             A PLC whose .plcproj cannot be located or read (e.g. an independent project file,
             an .xti; not verified) gets checked = false + reason and is skipped, not an error.
             "XAE has an object the .plcproj on disk does not list" cannot be told apart from
             "someone deleted it on disk", so nothing is saved by default:
             - no difference, or only extraOnDisk (the .plcproj lists objects XAE does not
               have: the reopen loads the disk version, XAE loses nothing; recorded in
               data.projectCheck only): go on.
             - missingOnDisk not empty, no switch: PROJECT_UNSAVED_CHANGES,
               nothing saved, nothing closed (the message and data list the differences).
             - -SaveProjectChanges (the caller keeps the XAE version): Save-TcPlcProject (DTE
               Project.Save of the .tsproj, deadline -> PROJECT_SAVE_TIMEOUT) and the .plcproj is
               read back with the relative path of each object; data.savedProjects. Still
               REFUSED (PROJECT_UNSAVED_CHANGES, data.saveRefused, nothing saved or closed) when a
               reload prompt was handled in step 1 (dismissedReloadPrompt), when an object of
               missingOnDisk has no .TcPOU / .TcDUT / .TcGVL / .TcIO on disk at its relative
               path (deleted on disk), or when ANY PLC of the same .tsproj (Project.Save writes
               the .tsproj and every .plcproj below it; a PLC whose .tsproj is unknown counts as
               the same) could not be compared (checked = false), was compared incompletely
               (complete = false) or has extraOnDisk.
               Save / readback failure -> PROJECT_SAVE_FAILED (or IDE_MODAL_DIALOG), nothing closed.
             - -DiscardProjectChanges (the disk version wins): step 1b is skipped.
             Unsaved library references, tasks or I/O changes are not detected (known limit).
             What Project.Save writes (measured 2026-10-28, 4026 VisualStudio.DTE.17.0): the
             project files .tsproj and .plcproj; a dirty plain text document was NOT saved. Whether unsaved
             content of a PLC editor (a POU edited in the GUI) is written was NOT verified.
          2. Documents.CloseAll(vsSaveChangesNo): XAE restores the document windows of
             the last session when a solution is (re)opened, so a changed .TcPOU that
             stays open would trigger the prompt again on the next disk edit.
             data.closedDocuments = number of documents that were open.
          3. Solution.Close($false) in Invoke-TcComRetry; the old ITcSysManager is released.
          4. Solution.Open(<sln>) on the SAME DTE (Invoke-TcComRetry, 7-9 s): an IDE with
             no solution open is never reused by Connect-TcIde -SolutionPath (it belongs
             to whoever opened it), so the reopen must happen on the instance we hold.
             data.reopenedSolution = true.
          5. Connect-TcIde -SolutionPath <sln> -ProgId <current> -NoLaunch: picks the same
             instance as 'solution-match', re-acquires ITcSysManager, re-enables SilentMode.
             data.sameIde tells whether the previous IDE pid was reused. Connect-TcIde answering
             MODAL_SCAN_INCOMPLETE (the UI Automation scan timed out; measured 2026-11-07, 4024
             XAE, right after Solution.Open) is retried at once with the same parameters (the
             scan inside takes its own time), at most 3 times, while -TimeoutSec is not used up
             (also on the Yes path); other codes are not retried. data.reconnectAttempts.
             After Solution.Open, IDE_MODAL_DIALOG with dialogKind 'reload-prompt' (an outside
             process rewrote a project file at the end of Solution.Open, #180) goes back to step 1
             while fewer than 5 prompts were handled, provided a fresh scan of the IDE that reopened
             the solution (by its pid) still shows a reload prompt; only then is the module IDE
             identity restored to that IDE. Else (or another dialog) the reconnect failure is returned.
          6. Readback (#135 F5, both paths): Wait-TcSolutionLoaded. Expected from DISK: the
             files (.tsproj) the .sln references and the PLC names they list (<Plc><Project
             Name>); no .tsproj or a .tsproj without PLC names -> the memory baseline of step 0
             (TIPC required); no .tsproj and no baseline -> TIPC is not required; a .tsproj
             without names and no baseline -> TIPC with at least one child
             (data.loadCheck.expectedFrom / expectationSource 'disk' | 'memory' | 'none'). Polled every 500 ms
             (shared -TimeoutSec) until Solution.FullName is this .sln, Solution.IsOpen,
             Solution.Projects (without Miscellaneous Files) >= 1, Solution.SolutionBuild and its
             ActiveConfiguration are set and (when required) LookupTreeItem('TIPC') answers with
             the expected PLCs below it. A reload prompt seen while a read gets no answer (or in
             a last scan at the deadline) goes back to step 1 (#176; the 5-prompt limit covers the
             whole call; the answers and the Solution.FullName / readback polls share what is left of
             -TimeoutSec, while Documents.CloseAll, Solution.Close and Solution.Open are each capped
             by -TimeoutSec on their own, so a rerun can take longer than -TimeoutSec in total.
             The full guard / 1b / close / reopen path runs again only when NeedReopen (a No /
             Ignore / WM_CLOSE answer, or the prompt went away by itself) or YesPathDone (the Yes
             path was done) is set; with neither (e.g. no prompt at first, a project prompt only
             after the reopen readback, answered Yes) the Yes-only path runs; data.* keeps
             accumulating); any other dialog, or a reload prompt with 5 already
             handled -> IDE_MODAL_DIALOG; IDE_CRASHED during a read -> IDE_CRASHED
             at once; not loaded in time -> SOLUTION_RELOAD_INCOMPLETE. Every one is recorded as
             code-changed (the files may have been reloaded).
        The ADS connection is not touched. No dialog, no Start-Sleep beyond the polls.
    .PARAMETER SolutionPath
        Solution file (.sln) to reopen. Default: the solution Connect-TcIde / Open-TcProject opened
        ($script:TcSolutionPath), else the solution currently open in the IDE.
    .PARAMETER TimeoutSec
        Expected upper bound for each of Documents.CloseAll, Solution.Close and
        Solution.Open (Invoke-TcComRetry -TimeoutSec), and the total time Solution.FullName
        is polled in one call (path read, wait after a Yes reload, guard). Default 120.
    .PARAMETER DiscardProjectChanges
        Skip step 1b: close without saving even when PLC objects in XAE are missing from
        the .plcproj on disk (they are dropped). Use after PROJECT_UNSAVED_CHANGES when the disk
        version is the one to keep. Not together with -SaveProjectChanges (INVALID_PARAMS).
    .PARAMETER SaveProjectChanges
        Step 1b keeps the XAE version: objects that XAE has and the .plcproj on disk does not
        list are saved (project files only) before closing, unless the disk shows a change
        (see step 1b: refused with PROJECT_UNSAVED_CHANGES, data.saveRefused). Use after
        PROJECT_UNSAVED_CHANGES when the objects in XAE are the ones to keep.
    .EXAMPLE
        # AI changed MAIN.TcPOU on disk while it was open in an XAE editor:
        Reset-TcSolution
        Build-TcProject
    .EXAMPLE
        # A generator rewrote plc.plcproj; XAE asks "Do you want to reload the project?":
        Reset-TcSolution     # answers Yes, reconnects, data.answeredYes = true, reopenedSolution = false
    .OUTPUTS
        data.solution              path that was reopened
        data.dismissedReloadPrompt a reload prompt was up and was closed by this cmdlet, or (PR #209)
                                   Connect-TcIde -TakeOverOrphan answered one without reloading
                                   (BUILD_REQUIRED kind reset-required, data.resetRequired): the full
                                   close / reopen runs and -SaveProjectChanges is refused as after
                                   a prompt handled here
        data.resetRequiredCleared  (only with a reset-required record) true = the reopen succeeded
                                   without saving and the record was removed; false = kept (a save,
                                   another .sln, or the state file could not be written:
                                   data.stateWarning)
        data.reloadTarget          'solution' | 'project' | 'file' | $null: which reload prompt was
                                   seen (several: 'solution' wins over 'project' over 'file')
        data.answeredYes           the project reload prompt was answered Yes (our click was sent)
        data.possiblyReloaded      a Yes click was sent (even if the prompt did not close in time):
                                   XAE may have reloaded the project
        data.reloadPromptAttempts  every answer tried on a reload prompt: [{target, answer
                                   (Yes | No | Ignore | Close = WM_CLOSE), sent, method, controlId,
                                   bmClick, wmCommand, dismissed, reason, sendReason, timeoutSec,
                                   sec}]
        data.reconnectAttempts     every Connect-TcIde of step 5 / the Yes path:
                                   [{step ('reload-path' | 'reopen'), code ('success' or the error
                                   code), sec}]
        data.loadCheck             readback before success (step 6): complete, sec, polls,
                                   expectedFrom ('disk' | 'memory' | 'none'), expectationSource
                                   (same value; 'none' = no PLC names expected), expected{requireTipc,
                                   plcs, minPlcCount, tsproj}, expectationError, last{fullName, isOpen,
                                   projectCount, solutionBuild, activeConfiguration, tipc, plcs},
                                   lastError
        data.reopenedSolution      Solution.Close + Solution.Open were done (false on the
                                   Yes-only path)
        data.projectCheck          step 1b: checked, plcs[] (plc, checked, reason, plcproj, tsproj,
                                   warning, missingOnDisk[], extraOnDisk, complete, visited),
                                   visited, sec; or checked = false + reason ($null on the
                                   Yes-only path)
        data.savedProjects         project files saved by step 1b (-SaveProjectChanges only): plc,
                                   plcproj, tsproj, savedFiles, savedObjects, plcprojChanged,
                                   saveSec, warning (empty when nothing was saved)
        data.saveRefused           -SaveProjectChanges refused: [{plc, reason}] (plc '*' = not one
                                   PLC, e.g. a reload prompt handled in step 1)
        data.closedDocuments       documents closed before Solution.Close
        data.closed                Solution.Close returned
        data.closeSec              seconds for CloseAll + Solution.Close
        data.openSec               seconds Solution.Open took
        data.connectSec            seconds the Connect-TcIde reconnect took
        data.totalSec              seconds in total (measured 20-25 s for close / reopen)
        data.ideProcessId          IDE pid after the reconnect
        data.previousIdeProcessId  IDE pid before
        data.sameIde               both pids equal
        data.selectedBy / sysManagerAvailable / silentMode / amsNetId / warning
                                   as reported by Connect-TcIde
        data.ownedBySession        this session launched the IDE (Disconnect-TcIde -Kill is
                                   allowed), even though selectedBy now says solution-match
        Errors: INVALID_PARAMS (both -SaveProjectChanges and -DiscardProjectChanges), NOT_CONNECTED, NO_SOLUTION, FILE_NOT_FOUND, IDE_MODAL_DIALOG,
        SOLUTION_RELOAD_INCOMPLETE (step 6: not loaded again within -TimeoutSec, data.loadCheck; IDE_CRASHED
        when the IDE died during it), RESET_SOLUTION_MISMATCH
        (the IDE has another solution open than the module expected; nothing closed, #29),
        RESET_SOLUTION_UNVERIFIED (the open solution could not be read to compare; nothing closed),
        PROJECT_SAVE_FAILED / PROJECT_SAVE_TIMEOUT / PROJECT_UNSAVED_CHANGES (step 1b, nothing closed),
        SOLUTION_CLOSE_FAILED, PROJECT_OPEN_FAILED (or IDE_BUSY / IDE_TIMEOUT /
        IDE_CRASHED from the COM calls), and any Connect-TcIde error code when the
        reconnect fails (data.closed / data.reopened say how far it got).
        BUILD_REQUIRED (#65): once XAE may hold project files reloaded from disk the solution
        ($path, the .sln this call reopens; after a Yes reload - success or failure - ALSO the
        module's solution path at the start and the one RESET_SOLUTION_MISMATCH read, every
        distinct one of them) is recorded as 'code-changed' (Register-TcCodeChange;
        data.buildRequired / data.stateWarning): success on either path; every failure after a
        project reload prompt was answered Yes or a Yes click was at least sent (data.answeredYes /
        data.possiblyReloaded: modal dialog, reload prompt handling, reconnect, solution check,
        Documents.CloseAll, Solution.Close, Solution.Open, load check);
        PROJECT_OPEN_FAILED in any case (the solution may be half open); a failed reconnect or load check
        after Solution.Open, and any failure after a reload prompt in that readback sent the call back to
        step 1 (#176). Not recorded: a failure before anything was reloaded (NO_SOLUTION,
        FILE_NOT_FOUND, a dialog / RESET_SOLUTION_* / close failure without a Yes). This cmdlet is the
        way to pick up files changed ON DISK, which the module cannot see, so Enable-TcConfig
        and Enter-TcPlcOnline refuse until a complete Build-TcProject. A disk edit that XAE
        reloads by itself (file not open in an editor, no Reset-TcSolution) is not recorded
        (known limit, docs/troubleshooting.md BUILD_REQUIRED).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [ValidateRange(5, 600)]
        [int]$TimeoutSec = 120,

        [Parameter()]
        [switch]$DiscardProjectChanges,

        [Parameter()]
        [switch]$SaveProjectChanges
    )

    if ($DiscardProjectChanges -and $SaveProjectChanges) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' `
            -ErrorMessage '-SaveProjectChanges (keep the XAE version) and -DiscardProjectChanges (keep the disk version) exclude each other; nothing was done.'
    }

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $dte = $script:TcDte
    $progId = $script:TcProgId
    $previousPid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $previousPid = [int]$script:TcIdeProcessId } catch { $previousPid = 0 } }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    $path = $SolutionPath
    if ([string]::IsNullOrWhiteSpace($path) -and -not [string]::IsNullOrWhiteSpace($script:TcSolutionPath)) {
        $path = [string]$script:TcSolutionPath
    }

    $progress = [ordered]@{
        solution              = $path
        dismissedReloadPrompt = $false
        reloadTarget          = $null
        answeredYes           = $false
        possiblyReloaded      = $false
        reopenedSolution      = $false
        reloadPromptAttempts  = [System.Collections.Generic.List[object]]::new()
        reconnectAttempts     = [System.Collections.Generic.List[object]]::new()
        closedDocuments       = 0
        closed                = $false
        reopened              = $false
        previousIdeProcessId  = $previousPid
    }
    function Get-ProgressData { param([hashtable]$Extra) $d = [PSCustomObject]$progress; $d.reloadPromptAttempts = $progress.reloadPromptAttempts.ToArray(); $d.reconnectAttempts = $progress.reconnectAttempts.ToArray(); if ($null -ne $Extra) { foreach ($k in $Extra.Keys) { $d | Add-Member -NotePropertyName $k -NotePropertyValue $Extra[$k] -Force } }; $d }

    # Connect-TcIde failure -> result that keeps its code / hint / data and says where it happened.
    function New-ReconnectFailedResult {
        param([object]$Connect, [hashtable]$Extra, [string]$Where)
        $err = $Connect.error
        $data = Get-ProgressData -Extra $Extra
        $dp = $Connect.PSObject.Properties['data']
        if ($null -ne $dp -and $null -ne $dp.Value) {
            foreach ($p in $dp.Value.PSObject.Properties) { $data | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
        }
        $params = @{
            Success      = $false
            ErrorMessage = "$Where but Connect-TcIde failed: $($err.message)"
            ErrorCode    = [string]$err.code
            Data         = $data
        }
        $hp = $err.PSObject.Properties['hint']
        if ($null -ne $hp -and -not [string]::IsNullOrWhiteSpace([string]$hp.Value)) { $params['Hint'] = [string]$hp.Value }
        New-TcResult @params
    }

    # Successful reconnect -> final data.
    function New-ReconnectedData {
        param([object]$ConnectData, [System.Collections.IDictionary]$Extra, [System.Diagnostics.Stopwatch]$Total)
        $newPid = 0
        try { $newPid = [int]$ConnectData.ideProcessId } catch { $newPid = 0 }
        $sameIde = ($previousPid -gt 0 -and $newPid -eq $previousPid)
        $all = [ordered]@{}
        foreach ($k in $Extra.Keys) { $all[$k] = $Extra[$k] }
        $all['totalSec'] = [math]::Round($Total.Elapsed.TotalSeconds, 1)
        $all['ideProcessId'] = $newPid
        $all['sameIde'] = $sameIde
        $all['selectedBy'] = $ConnectData.selectedBy
        $all['ownedBySession'] = ($script:TcIdeSelectedBy -eq 'launched')
        $all['sysManagerAvailable'] = [bool]$ConnectData.sysManagerAvailable
        $all['silentMode'] = $ConnectData.silentMode
        $data = Get-ProgressData -Extra $all
        foreach ($name in @('amsNetId', 'warning', 'sessionRecordWarning')) {   # #123: Connect-TcIde could not update the session record
            $prop = $ConnectData.PSObject.Properties[$name]
            if ($null -ne $prop) { $data | Add-Member -NotePropertyName $name -NotePropertyValue $prop.Value -Force }
        }
        if (-not $sameIde) {
            $note = "Connect-TcIde picked IDE pid $newPid instead of the previous pid $previousPid."
            $wp = $data.PSObject.Properties['warning']
            if ($null -ne $wp -and -not [string]::IsNullOrWhiteSpace([string]$wp.Value)) { $note = "$($wp.Value) $note" }
            $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $note -Force
        }
        $data
    }

    # #65: a failure AFTER XAE reloaded the project from disk (answeredYes) is recorded as
    # code-changed for $path (the files XAE now holds may differ from the last complete build);
    # -Always for a failure that may have left the solution half open (Solution.Open).
    # The Yes reload happened in the solution the IDE had open, i.e. the module's
    # $script:TcSolutionPath at the start (Enable-TcConfig / Enter-TcPlcOnline check that key),
    # or the solution the IDE reports (RESET_SOLUTION_MISMATCH). Which one XAE really reloaded is
    # not known for sure, so after a Yes reload EVERY candidate is recorded: $path, the start
    # solution and the reported one (empty ones dropped, one record per solution key).
    # $path may still be unknown here (a prompt answered before the path was read, #87).
    $startSolution = [string]$script:TcSolutionPath
    function Register-TcResetChange {
        param([object]$Result, [string]$Change, [string[]]$Solutions)
        $seen = @{}
        $warnings = [System.Collections.Generic.List[string]]::new()
        $out = $Result
        foreach ($s in $Solutions) {
            if ([string]::IsNullOrWhiteSpace($s)) { continue }
            $k = ConvertTo-TcSolutionKey $s
            if ($seen.ContainsKey($k)) { continue }
            $seen[$k] = $true
            # each call may set data.stateWarning: clear it first, collect every one
            if ($null -ne $out -and $null -ne $out.PSObject.Properties['data'] -and $null -ne $out.data -and $out.data -isnot [System.Collections.IDictionary]) {
                $out.data.PSObject.Properties.Remove('stateWarning')
            }
            $out = Register-TcCodeChange -Result $out -SolutionPath $s -Change $Change
            $wp = $out.data.PSObject.Properties['stateWarning']
            if ($null -ne $wp -and -not [string]::IsNullOrWhiteSpace([string]$wp.Value) -and -not $warnings.Contains([string]$wp.Value)) { $warnings.Add([string]$wp.Value) }
        }
        if ($null -ne $out -and $warnings.Count -gt 0) { $out.data | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue ($warnings -join '; ') -Force }
        $out
    }
    function Complete-TcResetFailure {
        param([object]$Result, [string]$Step, [switch]$Always, [string]$ReloadedSolution)
        $leafNow = if ([string]::IsNullOrWhiteSpace([string]$path)) { '<solution>' } else { [IO.Path]::GetFileName([string]$path) }
        if ($progress.answeredYes -or $progress.possiblyReloaded) {
            $change = "Reset-TcSolution $leafNow (project reloaded from disk, then $Step failed)"
            return Register-TcResetChange -Result $Result -Change $change -Solutions @($path, $startSolution, $ReloadedSolution)
        }
        if ($progress.reopened) {
            # #176: a failure in a later round of the main loop (a reload prompt during the readback
            # sent it back to step 1): the solution was already reopened from disk.
            return Register-TcCodeChange -Result $Result -SolutionPath $path -Change "Reset-TcSolution $leafNow (solution reopened from disk, then $Step failed)"
        }
        if ($Always) {
            return Register-TcCodeChange -Result $Result -SolutionPath $path -Change "Reset-TcSolution $leafNow ($Step failed, solution may be half open)"
        }
        $Result
    }

    # --- 1. modal dialogs: reload prompts are answered (project: Yes, solution: Ignore, file: WM_CLOSE), anything else is reported ---
    # Runs before every DTE read that a modal dialog can block (Solution / Solution.FullName),
    # and again for a reload prompt that comes up while such a read is polled (#87: XAE shows the
    # prompt some time after the file changed on disk; meanwhile Solution.FullName answers $null).
    # Returns $null when no dialog is left, else the failed result.
    $state = @{
        NeedReopen  = $false   # a prompt was answered No / Ignore / closed with WM_CLOSE or vanished without our click
        YesFailed   = $false   # a Yes click on a project prompt failed: later project prompts start at No
        Handled     = 0
        YesPathDone = $false   # the Yes-only reconnect was attempted (it failed: full path from now on)
        ResetRequiredSolution = $null   # PR #209 review M1: the .sln whose reset-required record this reset may clear
        ScanBeforeRead = $false   # a Yes was answered and no complete scan has shown "no modal" since (#181 review)
    }
    # PR #209 review M1: Connect-TcIde -TakeOverOrphan answered a reload prompt of this solution
    # 'do not reload' (BUILD_REQUIRED kind reset-required): that counts as a handled reload prompt
    # (-SaveProjectChanges is refused like after a prompt handled here) and forces the full close /
    # reopen (never the Yes-only path); the record is removed only after that reopen succeeded
    # without saving anything (end of this function).
    $resetGuard = Get-TcResetRequiredGuard -SolutionPath $path
    if ($null -ne $resetGuard) {
        $progress.dismissedReloadPrompt = $true
        $progress['resetRequired'] = $resetGuard
        $state.NeedReopen = $true
        $state.ResetRequiredSolution = $(if (-not [string]::IsNullOrWhiteSpace([string]$path)) { [string]$path } else { [string]$resetGuard.solution })
    }
    # One answer to a reload prompt (Close = Close-TcReloadPrompt's default WM_CLOSE), recorded in
    # data.reloadPromptAttempts (#135 F4: every attempt and how BM_CLICK / WM_COMMAND ended).
    # -TimeoutSec of each attempt = Min(its default, what is left of the Reset-TcSolution
    # -TimeoutSec), at least 1 s; less than 1 s left -> $null, nothing sent (the caller fails closed).
    function Invoke-TcResetPromptAnswer {
        param([object]$Dialog, [string]$Target, [string]$Answer)
        $default = if ($Answer -eq 'Close') { 8 } else { 15 }
        $left = [int][math]::Floor($TimeoutSec - $sw.Elapsed.TotalSeconds)
        if ($left -lt 1) { return $null }
        $budget = [math]::Min($default, $left)
        $asw = [System.Diagnostics.Stopwatch]::StartNew()
        # #174: right after a Yes the follow-up UI Automation scan ran into its 5 s timeout (measured
        # 2026-11-08, 4026 VS2022), so it is skipped. Why: XAE is probably still reloading the
        # project (inference, not measured).
        $r = if ($Answer -eq 'Close') { Close-TcReloadPrompt -Dialog $Dialog -TimeoutSec $budget }
             elseif ($Answer -eq 'Yes') { Close-TcReloadPrompt -Dialog $Dialog -Answer $Answer -TimeoutSec $budget -NoFollowUpScan }
             else { Close-TcReloadPrompt -Dialog $Dialog -Answer $Answer -TimeoutSec $budget }
        $get = { param($n) if ($r -is [System.Collections.IDictionary]) { if ($r.Contains($n)) { $r[$n] } else { $null } } else { $p = $r.PSObject.Properties[$n]; if ($null -ne $p) { $p.Value } else { $null } } }
        $cid = 0
        try { $cid = [int](& $get 'ControlId') } catch { $cid = 0 }
        $sent = [bool](& $get 'Sent')
        # #135 review S7: a Yes that was sent may have made XAE reload the project even when the
        # prompt did not close in time: every later failure is recorded as code-changed.
        if ($sent -and $Answer -eq 'Yes') { $progress.possiblyReloaded = $true }
        $progress.reloadPromptAttempts.Add([PSCustomObject]@{
            target     = $Target
            answer     = $Answer
            sent       = $sent
            method     = & $get 'Method'
            controlId  = $cid
            bmClick    = & $get 'BmClick'
            wmCommand  = & $get 'WmCommand'
            dismissed  = [bool](& $get 'Dismissed')
            reason     = & $get 'Reason'
            sendReason = & $get 'SendReason'
            timeoutSec = $budget
            sec        = [math]::Round($asw.Elapsed.TotalSeconds, 1)
        })
        $r
    }
    function Invoke-TcResetDialogStep {
        param([object]$FirstDialog)
        $pending = $FirstDialog
        while ($true) {
            $dialog = if ($null -ne $pending) { $pending } else { Find-TcIdeModalDialog }
            $pending = $null
            if ($null -eq $dialog) { $state.ScanBeforeRead = $false; return $null }   # a complete scan, no dialog
            if ([string]$dialog.Kind -ne 'reload-prompt') {
                $op = if ($progress.dismissedReloadPrompt) { 'Reset-TcSolution (after dismissing the reload prompt)' } else { 'Reset-TcSolution (Documents.CloseAll / Solution.Close)' }
                return Complete-TcResetFailure -Step 'modal dialog check' -Result (New-TcModalDialogResult -Dialog $dialog -Operation $op -Data (Get-ProgressData))
            }
            $state.Handled++
            if ($state.Handled -gt 5) {
                return Complete-TcResetFailure -Step 'reload prompt handling' -Result (New-TcModalDialogResult -Dialog $dialog -Operation 'Reset-TcSolution (reload prompts keep appearing; 5 dismissed)' -Data (Get-ProgressData))
            }
            $target = [string]$dialog.ReloadTarget
            # data.reloadTarget: the strongest prompt seen ('solution' > 'project' > 'file')
            $rank = @{ file = 1; project = 2; solution = 3 }
            $haveRank = if ($null -ne $progress.reloadTarget -and $rank.ContainsKey([string]$progress.reloadTarget)) { $rank[[string]$progress.reloadTarget] } else { 0 }
            $newRank = if ($rank.ContainsKey($target)) { $rank[$target] } else { 0 }
            if ($newRank -gt $haveRank -or [string]::IsNullOrWhiteSpace([string]$progress.reloadTarget)) { $progress.reloadTarget = $target }

            # Answers tried in order:
            # project (#135 F4): Yes, Yes again, then No (No keeps the old project in XAE, so the
            #   full close / reopen reads it from disk). NO WM_CLOSE: the XAE project prompt is an
            #   MB_YESNO box, and an MB_YESNO box ignores WM_CLOSE (measured 2026-11-07, Windows 11
            #   26200; MessageBox docs: without a Cancel button ESC / close has no effect,
            #   https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-messagebox).
            #   After a failed Yes (YesFailed) later project prompts start at No.
            # solution (#106): Ignore (control id 1412), then WM_CLOSE; the full close / reopen
            #   reads the .sln from disk. Not Reload (259): measured 2026-11-07, 4026 VS2022 zh-TW,
            #   Reload made VS ask at once "Save changes to the following items? X.sln X.tsproj*"
            #   (Save / Don't Save / Cancel; the .tsproj was dirty in memory after Set-TcTarget),
            #   another modal dialog; Solution.Close($false) after Set-TcTarget showed no dialog.
            # file: WM_CLOSE (the reopen reads the file from disk, so the answer does not matter).
            $answers = if ($target -eq 'project') { if ($state.YesFailed) { @('No') } else { @('Yes', 'Yes', 'No') } }
                       elseif ($target -eq 'solution') { @('Ignore', 'Close') }
                       else { @('Close') }
            $last = $null
            $handled = $false
            foreach ($ans in $answers) {
                $try = Invoke-TcResetPromptAnswer -Dialog $dialog -Target $target -Answer $ans
                if ($null -eq $try) {
                    # #135 review S1: the -TimeoutSec budget is used up: no further answer is tried
                    $last = 'no time left within -TimeoutSec for another answer'
                    break
                }
                $last = [string]$try.Reason
                if ($try.Sent -and ($try.Dismissed -or $null -ne $try.NextDialog)) {
                    # Our click was sent and the prompt closed (another dialog may be up now: the loop
                    # reports it). Only an actual Yes click counts as answeredYes.
                    $progress.dismissedReloadPrompt = $true
                    if ($ans -eq 'Yes') { $progress.answeredYes = $true }
                    else { $state.NeedReopen = $true }   # No / Ignore / WM_CLOSE: the reopen reads the disk
                    Write-Verbose "Reset-TcSolution: $target reload prompt answered $ans ($($try.Reason))."
                    # Defensive: after a Yes NextDialog is always $null (Close-TcReloadPrompt -NoFollowUpScan
                    # never scans); should it ever carry a dialog, this loop scans again and reports it.
                    if ($ans -eq 'Yes' -and $null -eq $try.NextDialog) {
                        # #174: no scan right after a Yes here (measured 2026-11-08, 4026 VS2022: the UI
                        # Automation scan ran into its 5 s timeout right after the Yes, and an incomplete
                        # scan in step 1 fails closed).
                        # ScanBeforeRead: the FIRST DTE call after this Yes must come after a complete
                        # scan that found no modal dialog (CODING_STANDARDS section 1: a DTE call blocked by a
                        # modal never returns, Invoke-TcComRetry cannot interrupt it). The next DTE
                        # reader scans first and treats an incomplete scan as "unknown, keep waiting"
                        # (no DTE read, no failure): the Yes-path Solution.FullName wait, or
                        # Read-TcResetSolutionName (path read / guard). On the full path (NeedReopen /
                        # YesPathDone already set) the scans right before Documents.CloseAll and before
                        # Solution.Close (Find-TcResetDialog) run every round and do NOT tolerate an
                        # incomplete scan: MODAL_SCAN_INCOMPLETE, fail closed.
                        $state.ScanBeforeRead = $true
                        return $null
                    }
                    $handled = $true
                    break
                }
                if ($try.Dismissed -and -not $try.Sent) {
                    # The prompt vanished without our click: nobody knows whether it reloaded, so
                    # take the full close / reopen path.
                    $state.NeedReopen = $true
                    Write-Verbose "Reset-TcSolution: $target reload prompt was already gone ($($try.Reason)); doing the full close / reopen."
                    $handled = $true
                    break
                }
                if ($ans -eq 'Yes') { $state.YesFailed = $true }
                if ([string]$try.WmCommand -eq 'not-posted-disabled') {
                    # PR #173 review: the BM_CLICK reached a prompt that is disabled or has a nested
                    # modal over it (Close-TcMessageBox, #64). The click may still act once the nested
                    # dialog is gone, so the same hwnd never gets another (opposite) answer: one scan,
                    # then fail closed.
                    $nested = Find-TcIdeModalDialog
                    $nestedHwnd = [long]0; $promptHwnd = [long]0
                    try { $nestedHwnd = [long]$nested.Hwnd } catch { $nestedHwnd = 0 }
                    try { $promptHwnd = [long]$dialog.Hwnd } catch { $promptHwnd = 0 }
                    if ($null -ne $nested -and -not (Test-TcModalScanIncomplete $nested) -and $nestedHwnd -ne $promptHwnd) {
                        $progress.possiblyReloaded = $true
                        Write-Verbose "Reset-TcSolution: a nested dialog is up over the $target reload prompt after $ans ($($nested.Title)); no further answer."
                        return Complete-TcResetFailure -Step 'reload prompt dismissal' -Result (New-TcModalDialogResult -Dialog $nested -Operation "Reset-TcSolution (a dialog is up over the $target reload prompt after answering $ans; no further answer sent)" `
                            -Data (Get-ProgressData))
                    }
                    $last = "$($try.Reason); the prompt is disabled, no further answer sent"
                    Write-Verbose "Reset-TcSolution: the $target reload prompt is disabled after $ans ($($try.Reason)); no further answer."
                    break
                }
                Write-Verbose "Reset-TcSolution: answering $ans to the $target reload prompt failed ($($try.Reason))."
            }
            if ($handled) { continue }
            # every answer failed (or no time was left): fail closed
            return Complete-TcResetFailure -Step 'reload prompt dismissal' -Result (New-TcModalDialogResult -Dialog $dialog -Operation "Reset-TcSolution (reload prompt could not be dismissed: $last)" `
                -Data (Get-ProgressData))
        }
    }

    # Polls Solution.FullName on the DTE we hold (500 ms, up to -TimeoutSec; each read is one
    # Invoke-TcComRetry attempt). Fail closed: $null (busy after a reload, or a modal dialog up)
    # is not an answer; '' (no solution open) is. After every read that gave no answer the IDE is
    # checked for a modal dialog (#87): a reload prompt is returned in .Dialog for
    # Invoke-TcResetDialogStep, any other dialog ends the poll with IDE_MODAL_DIALOG in .Failure.
    # Right after a Yes ($state.ScanBeforeRead, #181 review) the order is reversed: scan FIRST and read
    # Solution.FullName only after a complete scan found no modal dialog (CODING_STANDARDS section 1: a DTE
    # call blocked by a modal never returns and Invoke-TcComRetry cannot interrupt it; this scan is the
    # only protection). An incomplete scan then means "unknown": no read, no failure (#174), keep
    # waiting within -TimeoutSec (no read at all -> .Read = $false, the caller fails closed).
    # Otherwise (no Yes since the last complete scan, e.g. step 1 just scanned and found no dialog)
    # the read comes first as before (#87).
    function Read-TcResetSolutionName {
        param([string]$Operation)
        $rsw = [System.Diagnostics.Stopwatch]::StartNew()
        $out = @{ Read = $false; Value = $null; Error = $null; ErrorRecord = $null; Sec = 0; Dialog = $null; Failure = $null }
        while ($true) {
            if ($state.ScanBeforeRead) {
                $d = Find-TcIdeModalDialog
                if (Test-TcModalScanIncomplete $d) {
                    $out.Error = 'modal dialog scan did not complete after the Yes reload; Solution.FullName not read'
                    $out.ErrorRecord = $null
                    if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
                    Start-Sleep -Milliseconds 500
                    continue
                }
                if ($null -ne $d) {
                    if ([string]$d.Kind -eq 'reload-prompt') { $out.Dialog = $d }
                    else { $out.Failure = New-TcModalDialogResult -Dialog $d -Operation "Reset-TcSolution ($Operation; nothing closed)" -Data (Get-ProgressData) }
                    break
                }
                $state.ScanBeforeRead = $false
            }
            # DTE call: guarded by the complete scan just above (after a Yes) or by step 1's / the previous round's scan.
            try {
                $raw = Invoke-TcComRetry -MaxRetries 1 -OperationName $Operation -ScriptBlock { $gSol = $dte.Solution; if ($null -eq $gSol) { $null } else { $gSol.FullName } }
                if ($null -ne $raw) { $out.Read = $true; $out.Value = [string]$raw; break }
                $out.Error = 'Solution / Solution.FullName answered $null'
                $out.ErrorRecord = $null
            }
            catch {
                $out.Error = $_.Exception.Message
                $out.ErrorRecord = $_
                # a crashed IDE never answers again: stop polling it
                if ($out.Error -match '^IDE_CRASHED') { break }
            }
            $d = Find-TcIdeModalDialog
            # #42: an incomplete scan while polling is unknown, not "no dialog": keep polling (the
            # poll ends on an answer or -TimeoutSec; without an answer nothing is closed).
            if (Test-TcModalScanIncomplete $d) { $d = $null }
            if ($null -ne $d) {
                if ([string]$d.Kind -eq 'reload-prompt') { $out.Dialog = $d }
                else { $out.Failure = New-TcModalDialogResult -Dialog $d -Operation "Reset-TcSolution ($Operation; nothing closed)" -Data (Get-ProgressData) }
                break
            }
            # -TimeoutSec bounds the whole call: every poll shares it (#87, the steps may run again)
            if ($sw.Elapsed.TotalSeconds -ge $TimeoutSec) { break }
            Start-Sleep -Milliseconds 500
        }
        $out.Sec = [math]::Round($rsw.Elapsed.TotalSeconds, 1)
        $out
    }

    # After a DTE call failed (or read back incomplete): is a dialog up? $null = no; .Dialog = a
    # reload prompt for Invoke-TcResetDialogStep (the caller runs the steps again); .Failure =
    # IDE_MODAL_DIALOG for any other dialog (#87).
    function Find-TcResetDialog {
        param([string]$Operation)
        $d = Find-TcIdeModalDialog
        if ($null -eq $d) { return $null }
        if ([string]$d.Kind -eq 'reload-prompt') {
            Write-Verbose "Reset-TcSolution: a reload prompt ($($d.ReloadTarget)) is up after '$Operation'; running the steps again."
            return @{ Dialog = $d; Failure = $null }
        }
        @{ Dialog = $null; Failure = (Complete-TcResetFailure -Step 'modal dialog check' -Result (New-TcModalDialogResult -Dialog $d -Operation "Reset-TcSolution ($Operation)" -Data (Get-ProgressData))) }
    }

    # --- resolve the solution to reopen ---
    $pendingDialog = $null
    if ([string]::IsNullOrWhiteSpace($path)) {
        # The path has to come from the DTE: clear reload prompts first, the read would only see $null (#87).
        $pathRead = $null
        while ($true) {
            $stepFail = Invoke-TcResetDialogStep -FirstDialog $pendingDialog
            $pendingDialog = $null
            if ($null -ne $stepFail) { return $stepFail }
            $pathRead = Read-TcResetSolutionName -Operation 'Solution.FullName'
            if ($null -ne $pathRead.Failure) { return Complete-TcResetFailure -Step 'modal dialog check' -Result $pathRead.Failure }
            if ($null -ne $pathRead.Dialog) { $pendingDialog = $pathRead.Dialog; continue }
            break
        }
        if (-not $pathRead.Read) {
            if ($null -ne $pathRead.ErrorRecord) {
                return Complete-TcResetFailure -Step 'solution path read' -Result (New-TcAdsErrorResult -ErrorRecord $pathRead.ErrorRecord -DefaultCode 'NO_SOLUTION' -MessagePrefix 'Could not read the path of the open solution')
            }
            return Complete-TcResetFailure -Step 'solution path read' -Result (New-TcResult -Success $false -ErrorCode 'NO_SOLUTION' -Hint (Get-TcErrorHint -Code 'NO_SOLUTION') `
                -ErrorMessage "Could not read the path of the open solution within $TimeoutSec s ($($pathRead.Error)); nothing to reopen.")
        }
        $path = $pathRead.Value
    }
    if ([string]::IsNullOrWhiteSpace($path)) {
        return New-TcResult -Success $false -ErrorMessage 'No solution is open and no -SolutionPath was given; nothing to reopen.' `
            -ErrorCode 'NO_SOLUTION' -Hint (Get-TcErrorHint -Code 'NO_SOLUTION')
    }
    if (-not (Test-Path -LiteralPath $path)) {
        return New-TcResult -Success $false -ErrorMessage "Solution file not found: $path" -ErrorCode 'FILE_NOT_FOUND'
    }
    $path = Get-TcLongPath (Resolve-Path -LiteralPath $path).Path
    $progress.solution = $path
    $leaf = [IO.Path]::GetFileName([string]$path)

    $guard = $null
    $expected = $path
    $reloadWaitSec = 0.0

    # #135 F5 memory baseline: the PLC names below TIPC before the reset, the fallback of the
    # readback when the .tsproj on disk names no PLC (Wait-TcSolutionLoaded reads the disk first).
    # Taken once, only when no dialog is up right now (a dialog blocks the reads); a dialog found
    # here goes to step 1 as the first dialog (no second scan).
    $baseline = [PSCustomObject]@{ known = $false; plcs = @(); error = 'not taken: a dialog was up (or the scan did not complete)' }
    if ($null -eq $pendingDialog) {
        $pendingDialog = Find-TcIdeModalDialog
        if ($null -eq $pendingDialog) { $baseline = Get-TcSolutionLoadBaseline }
    }
    # Step 5 / reload-path reconnect. Connect-TcIde answering MODAL_SCAN_INCOMPLETE (the UI Automation
    # dialog scan timed out; real machine 2026-11-07, 4024 XAE: 5 s scan timeout right after
    # Solution.Open, prepareMs 187, a Build right after worked) is retried at once with the same
    # parameters (the scan inside Connect-TcIde takes its own time), at most 3 times, while
    # -TimeoutSec is not used up. Any other code is not retried.
    # Still fail closed: only a Connect-TcIde success goes on (and Wait-TcSolutionLoaded after it).
    # Every attempt: data.reconnectAttempts [{step, code ('success' or the error code), sec}].
    function Invoke-TcResetConnect {
        param([hashtable]$Params, [string]$Step)
        $retries = 0
        while ($true) {
            $csw = [System.Diagnostics.Stopwatch]::StartNew()
            $c = Connect-TcIde @Params
            $code = if ($c.success) { 'success' } else { [string]$c.error.code }
            $progress.reconnectAttempts.Add([PSCustomObject]@{ step = $Step; code = $code; sec = [math]::Round($csw.Elapsed.TotalSeconds, 1) })
            if ($code -ne 'MODAL_SCAN_INCOMPLETE') { return $c }
            if ($retries -ge 3 -or $sw.Elapsed.TotalSeconds -ge $TimeoutSec) { return $c }
            $retries++
            Write-Verbose "Reset-TcSolution: Connect-TcIde answered MODAL_SCAN_INCOMPLETE ($Step); retry $retries of 3."
        }
    }

    # Module IDE identity around a reconnect: a failed Connect-TcIde leaves it cleared (it drops the
    # old one first) or bound to the IDE it chose (failure at its modal check), while the IDE we
    # hold ($dte) is still the one to act on (Yes path; #180 reopen reconnect).
    function Get-TcResetIdeIdentity {
        @{
            Dte = $script:TcDte; ProgId = $script:TcProgId; Pid = $script:TcIdeProcessId; SelectedBy = $script:TcIdeSelectedBy
            Sln = $script:TcSolutionPath; Start = $script:TcIdeStartTime; MainHwnd = $script:TcIdeMainHwnd
            Settings = $script:TcAutomationSettings; Silent = $script:TcSilentMode; SilentOriginal = $script:TcSilentModeOriginal
        }
    }
    function Restore-TcResetIdeIdentity {
        param([hashtable]$Saved)
        $script:TcDte = $Saved.Dte; $script:TcProgId = $Saved.ProgId; $script:TcIdeConnected = ($null -ne $Saved.Dte)
        $script:TcIdeProcessId = $Saved.Pid; $script:TcIdeSelectedBy = $Saved.SelectedBy; $script:TcSolutionPath = $Saved.Sln
        $script:TcIdeStartTime = $Saved.Start; $script:TcIdeMainHwnd = $Saved.MainHwnd
        $script:TcAutomationSettings = $Saved.Settings; $script:TcSilentMode = $Saved.Silent; $script:TcSilentModeOriginal = $Saved.SilentOriginal
    }

    # Readback before success (#135 F5). $null = loaded; @{ ReloadPrompt = <dialog> } = a reload
    # prompt came up meanwhile and fewer than 5 prompts were handled (#176): the caller hands it to
    # step 1 (main loop, $pendingDialog; Invoke-TcResetDialogStep keeps the 5-prompt limit and
    # -TimeoutSec); else the failed result: any other dialog, or a reload prompt past the limit ->
    # IDE_MODAL_DIALOG; the IDE crashed -> IDE_CRASHED (review S4); not loaded within -TimeoutSec ->
    # SOLUTION_RELOAD_INCOMPLETE. Every failure is recorded as code-changed by the caller (the files
    # may have been reloaded).
    function Test-TcResetLoaded {
        param([string]$Where)
        $wait = Wait-TcSolutionLoaded -SolutionPath $path -MemoryBaseline $baseline -Stopwatch $sw -TimeoutSec $TimeoutSec
        $progress['loadCheck'] = $wait.LoadCheck
        if ($wait.Complete) { return $null }
        if (-not [string]::IsNullOrWhiteSpace([string]$wait.Crashed)) {
            return New-TcResult -Success $false -ErrorCode 'IDE_CRASHED' -Hint (Get-TcErrorHint -Code 'IDE_CRASHED') -Data (Get-ProgressData) `
                -ErrorMessage "Reset-TcSolution: the IDE crashed while the solution was read back after $($Where): $($wait.Crashed)"
        }
        if ($null -ne $wait.Dialog) {
            if ([string]$wait.Dialog.Kind -eq 'reload-prompt' -and $state.Handled -lt 5) {
                Write-Verbose "Reset-TcSolution: a reload prompt ($($wait.Dialog.ReloadTarget)) came up while the solution was read back after $Where; handling it (#176)."
                return @{ ReloadPrompt = $wait.Dialog }
            }
            return New-TcModalDialogResult -Dialog $wait.Dialog -Operation "Reset-TcSolution (waiting for the solution to load after $Where)" -Data (Get-ProgressData)
        }
        New-TcResult -Success $false -ErrorCode 'SOLUTION_RELOAD_INCOMPLETE' -Hint (Get-TcErrorHint -Code 'SOLUTION_RELOAD_INCOMPLETE') -Data (Get-ProgressData) `
            -ErrorMessage "Reset-TcSolution: after $Where the solution '$path' was not loaded again within $TimeoutSec s ($($wait.LoadCheck.lastError)). The IDE may still be loading it (#135, an inference)."
    }

    # Steps 1, Yes-only path, guard, 1b, Documents.CloseAll and Solution.Close run again whenever a
    # reload prompt comes up while Solution.FullName is polled or one of these steps fails / reads
    # back incomplete (at most 5 prompts in total, Invoke-TcResetDialogStep; the polls share
    # -TimeoutSec: the answers and the polls share what is left of it, Documents.CloseAll /
    # Solution.Close / Solution.Open are each capped by it, so a rerun can exceed it in total). XAE notices a disk change with a delay, so the prompt may come up after the
    # guard (#87, 2026-11-02). Nothing is closed before Solution.Close succeeds.
    # Solution.Open, the reconnect and the readback run inside the loop too: a reload prompt seen by
    # the readback (either path) sends it back to step 1 (#176). Every pass either returns or
    # continues on a dialog that step 1 counts, so the loop ends within 5 prompts (or -TimeoutSec running out in a poll).
    while ($true) {
        $stepFail = Invoke-TcResetDialogStep -FirstDialog $pendingDialog
        $pendingDialog = $null
        if ($null -ne $stepFail) { return $stepFail }

        # --- Yes-only path: XAE reloaded the project itself; skip CloseAll / Close / Open ---
        if ($progress.answeredYes -and -not $state.NeedReopen -and -not $state.YesPathDone) {
            # a. Wait on the DTE we hold until XAE answers Solution.FullName with our solution again
            #    (it is busy while it reloads the project). Polled every 500 ms, no blind sleep; a
            #    dialog that comes up meanwhile (another reload prompt) is handled first (#87).
            $waitSw = [System.Diagnostics.Stopwatch]::StartNew()
            $reloaded = $false
            $lastRead = $null
            # Every round scans FIRST and reads Solution.FullName only after a complete scan found no
            # modal dialog (#181 review; CODING_STANDARDS section 1: step 1 did not scan after the Yes (#174),
            # and a DTE call blocked by a modal never returns, Invoke-TcComRetry cannot interrupt it).
            # An incomplete scan (#42; XAE probably still reloading, inference) means "unknown": no read,
            # no failure, keep waiting. Not reloaded within -TimeoutSec -> the reconnect below runs
            # anyway; Connect-TcIde scans before its own DTE calls and fails closed on an incomplete scan.
            while ($sw.Elapsed.TotalSeconds -lt $TimeoutSec) {
                $pendingDialog = Find-TcIdeModalDialog
                if (Test-TcModalScanIncomplete $pendingDialog) {
                    $pendingDialog = $null
                    $lastRead = 'modal dialog scan did not complete; Solution.FullName not read'
                    Start-Sleep -Milliseconds 500
                    continue
                }
                if ($null -ne $pendingDialog) { break }
                $state.ScanBeforeRead = $false
                try {
                    # DTE call: guarded by the complete scan just above.
                    $full = [string](Invoke-TcComRetry -OperationName 'Solution.FullName (post-reload wait)' -MaxRetries 1 -ScriptBlock { [string]$dte.Solution.FullName })
                    $lastRead = $full
                    if (-not [string]::IsNullOrWhiteSpace($full) -and [string]::Equals((Get-TcLongPath $full), $path, [StringComparison]::OrdinalIgnoreCase)) { $reloaded = $true; break }
                }
                catch { $lastRead = $_.Exception.Message }
                Start-Sleep -Milliseconds 500
            }
            $reloadWaitSec += $waitSw.Elapsed.TotalSeconds
            $progress['reloadWaitSec'] = [math]::Round($reloadWaitSec, 1)
            if ($null -ne $pendingDialog) {
                Write-Verbose "Reset-TcSolution: a dialog came up while waiting for the Yes reload ($($pendingDialog.Kind)); handling it first."
                continue
            }
            if (-not $reloaded) { Write-Verbose "Reset-TcSolution: Solution.FullName not back to '$path' after the Yes reload (last: $lastRead); reconnecting anyway." }
            $state.YesPathDone = $true

            # b. Reconnect; on failure restore the identity and fall back to close / reopen on the old DTE.
            $saved = Get-TcResetIdeIdentity
            if ($null -ne $script:TcSysManager) {
                try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
                $script:TcSysManager = $null
            }
            $connectParams = @{ SolutionPath = $path; NoLaunch = $true }
            if (-not [string]::IsNullOrWhiteSpace($progId)) { $connectParams['ProgId'] = $progId }
            $connectSw = [System.Diagnostics.Stopwatch]::StartNew()
            $connect = Invoke-TcResetConnect -Params $connectParams -Step 'reload-path'
            $connectSec = [math]::Round($connectSw.Elapsed.TotalSeconds, 1)
            $probeError = $null
            if (-not $connect.success) {
                $probeError = "Connect-TcIde failed: [$($connect.error.code)] $($connect.error.message)"
                Restore-TcResetIdeIdentity $saved
            }
            else {
                # Probe the re-bound ITcSysManager the same way other commands use it.
                $sm = $script:TcSysManager
                if ($null -eq $sm) { $probeError = 'ITcSysManager not available after reconnect' }
                else {
                    $tipc = $null
                    try {
                        $tipc = Invoke-TcComRetry -OperationName 'LookupTreeItem TIPC (post-reload probe)' -ScriptBlock { Write-Output -NoEnumerate $sm.LookupTreeItem('TIPC') }
                        if ($null -eq $tipc) { $probeError = "LookupTreeItem('TIPC') returned null" }
                    }
                    catch { $probeError = $_.Exception.Message }
                    if ($null -ne $tipc) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($tipc) | Out-Null } catch { } }
                }
                if ($null -eq $probeError) {
                    $loadFail = Test-TcResetLoaded -Where 'the project reload'
                    if ($loadFail -is [System.Collections.IDictionary]) {
                        # #176: a reload prompt came up during the readback: step 1 answers it. The
                        # Yes path was done (YesPathDone), so the loop goes on with the full guard / 1b /
                        # close / reopen path on the IDE Connect-TcIde re-bound.
                        $pendingDialog = $loadFail.ReloadPrompt
                        if ($null -ne $script:TcDte) { $dte = $script:TcDte; $progId = $script:TcProgId }
                        continue
                    }
                    if ($null -ne $loadFail) {
                        foreach ($k in @('connectSec')) { $loadFail.data | Add-Member -NotePropertyName $k -NotePropertyValue $connectSec -Force }
                        return Complete-TcResetFailure -Step 'load check' -Result $loadFail
                    }
                    $ok = New-TcResult -Success $true -Data (New-ReconnectedData -ConnectData $connect.data -Extra ([ordered]@{ connectSec = $connectSec }) -Total $sw)
                    return Register-TcResetChange -Result $ok -Change "Reset-TcSolution $leaf (project reloaded from disk)" -Solutions @([string]$script:TcSolutionPath, $path, $startSolution)
                }
            }
            Write-Verbose "Reset-TcSolution: reconnect after the Yes reload failed ($probeError); doing the full close / reopen."
            $progress['yesPathError'] = $probeError
            # PR #185 review A: the reconnect / probe may have failed because a dialog came up (e.g. another
            # reload prompt, Connect-TcIde IDE_MODAL_DIALOG). The guard below is the next DTE reader: it
            # must scan FIRST (CODING_STANDARDS section 1: a DTE call blocked by a modal never returns).
            # A reload prompt found there goes back to step 1 (5-prompt limit, #64), any other dialog ->
            # IDE_MODAL_DIALOG, an incomplete scan -> keep waiting without a read (Read-TcResetSolutionName).
            $state.ScanBeforeRead = $true
            $dte = $script:TcDte
            $progId = $script:TcProgId
            if ($null -eq $dte) {
                return Complete-TcResetFailure -Step 'reconnect' -Result (New-TcResult -Success $false -ErrorMessage "Project reload answered Yes, but the IDE is not usable afterwards: $probeError" `
                    -ErrorCode 'NOT_CONNECTED' -Data (Get-ProgressData -Extra @{ connectSec = $connectSec }))
            }
        }

        # --- guard (#29): never close a solution the module did not expect in this IDE ---
        # Connect-TcIde can attach a blocked IDE on evidence such as a session record; when the IDE
        # turns out to have ANOTHER solution open than the module believes, closing it would hit
        # someone else's work. Never readable within -TimeoutSec -> RESET_SOLUTION_UNVERIFIED,
        # nothing closed. A reload prompt that comes up during the poll is handled (loop again),
        # any other dialog ends it with IDE_MODAL_DIALOG (#87).
        # Expected = the solution the module connected / opened (else $path).
        $expected = if (-not [string]::IsNullOrWhiteSpace($script:TcSolutionPath)) { [string]$script:TcSolutionPath } else { $path }
        $guard = Read-TcResetSolutionName -Operation 'Solution.FullName (guard)'
        if ($null -ne $guard.Failure) { return Complete-TcResetFailure -Step 'modal dialog check' -Result $guard.Failure }
        if ($null -ne $guard.Dialog) {
            Write-Verbose "Reset-TcSolution: a reload prompt ($($guard.Dialog.ReloadTarget)) came up while reading Solution.FullName; handling it."
            $pendingDialog = $guard.Dialog
            continue
        }
        if (-not $guard.Read) {
            return Complete-TcResetFailure -Step 'solution check' -Result (New-TcResult -Success $false `
                -ErrorMessage "Reset-TcSolution not attempted: Solution.FullName of the IDE (pid $previousPid) could not be read within $TimeoutSec s ($($guard.Error)), so the open solution could not be compared with '$expected'. Nothing was closed." `
                -ErrorCode 'RESET_SOLUTION_UNVERIFIED' -Hint (Get-TcErrorHint -Code 'RESET_SOLUTION_UNVERIFIED') `
                -Data (Get-ProgressData -Extra @{ expectedSolution = $expected; guardError = $guard.Error; guardSec = $guard.Sec }))
        }
        $openNow = $guard.Value
        if (-not [string]::IsNullOrWhiteSpace($openNow)) {
            $openNorm = try { Get-TcLongPath $openNow } catch { $openNow }
            $expNorm = try { Get-TcLongPath $expected } catch { $expected }
            if (-not [string]::Equals($openNorm, $expNorm, [StringComparison]::OrdinalIgnoreCase)) {
                return Complete-TcResetFailure -Step 'solution check' -ReloadedSolution $openNorm -Result (New-TcResult -Success $false `
                    -ErrorMessage "Reset-TcSolution not attempted: the IDE (pid $previousPid) has '$openNorm' open, not '$expNorm' that the module expected. Nothing was closed." `
                    -ErrorCode 'RESET_SOLUTION_MISMATCH' -Hint (Get-TcErrorHint -Code 'RESET_SOLUTION_MISMATCH') `
                    -Data (Get-ProgressData -Extra @{ openSolution = $openNorm; expectedSolution = $expNorm }))
            }
        }

        # --- 1b. unsaved project structure (#76): never save by default, never save editor documents ---
        # "XAE has it, the .plcproj on disk does not" cannot be told apart from "someone deleted it on
        # disk", so a difference stops the reset (PROJECT_UNSAVED_CHANGES) unless the caller chose a side.
        $progress['projectCheck'] = $null
        $progress['savedProjects'] = @()
        if ($DiscardProjectChanges) {
            $progress.projectCheck = [PSCustomObject]@{ checked = $false; reason = 'DiscardProjectChanges' }
        }
        else {
            # #106: never the cached ITcSysManager: after a solution reload (Reload clicked on the VS2022 solution prompt, e.g. by the user;
            # one the user clicked) the cached one throws "System Manager already disposed!".
            $checkSm = Get-TcSysManager -Refresh
            if ($null -eq $checkSm) {
                $progress.projectCheck = [PSCustomObject]@{ checked = $false; reason = 'no ITcSysManager (no TwinCAT project in the solution)' }
            }
            else {
                $unsaved = $null
                $checkError = $null
                try { $unsaved = Get-TcUnsavedPlcObject -SysManager $checkSm }
                catch { $checkError = $_ }
                if ($null -ne $checkError) {
                    # #87: a reload prompt that came up after the guard blocks the tree walk (RPC_E_CALL_REJECTED)
                    $found = Find-TcResetDialog -Operation 'comparing the PLC objects with the .plcproj on disk; nothing closed'
                    if ($null -ne $found -and $null -ne $found.Failure) { return $found.Failure }
                    if ($null -ne $found) { $pendingDialog = $found.Dialog; continue }
                    return Complete-TcResetFailure -Step 'project check' -Result (New-TcAdsErrorResult -ErrorRecord $checkError -DefaultCode 'PROJECT_SAVE_FAILED' -MessagePrefix 'Reset-TcSolution not attempted: comparing the PLC objects in XAE with the .plcproj on disk failed, nothing was closed' -Data (Get-ProgressData))
                }
                $plcInfo = @($unsaved.Plcs | ForEach-Object {
                    [PSCustomObject]@{ plc = $_.plc; checked = $_.checked; reason = $_.reason; plcproj = $_.plcproj; tsproj = $_.tsproj; warning = $_.warning
                        missingOnDisk = @($_.missingOnDisk | ForEach-Object { [PSCustomObject]@{ file = $_.file; relativePath = $_.relativePath; path = $_.path; fileExists = $_.fileExists } })
                        extraOnDisk = @($_.extraOnDisk); complete = $_.complete; visited = $_.visited }
                })
                $progress.projectCheck = [PSCustomObject]@{ checked = $true; plcs = $plcInfo; visited = $unsaved.Visited; sec = $unsaved.Sec }
                # Only missingOnDisk stops the reset: extraOnDisk alone (the .plcproj lists objects XAE
                # does not have) loses nothing, the reopen loads the disk version (it stays in projectCheck).
                $diffs = @($unsaved.Plcs | Where-Object { $_.checked -and @($_.missingOnDisk).Count -gt 0 })
                if ($diffs.Count -gt 0) {
                    $describe = @($diffs | ForEach-Object {
                        $m = @($_.missingOnDisk | ForEach-Object { $_.file }); $x = @($_.extraOnDisk)
                        $mText = if ($m.Count -gt 0) { $m -join ', ' } else { '-' }
                        $xText = if ($x.Count -gt 0) { $x -join ', ' } else { '-' }
                        "PLC '$($_.plc)' ($($_.plcproj)): in XAE but not in the .plcproj on disk: $mText; in the .plcproj but not in XAE: $xText"
                    }) -join '; '
                    if (-not $SaveProjectChanges) {
                        return Complete-TcResetFailure -Step 'project check' -Result (New-TcResult -Success $false -ErrorCode 'PROJECT_UNSAVED_CHANGES' -Hint (Get-TcErrorHint -Code 'PROJECT_UNSAVED_CHANGES') -Data (Get-ProgressData) `
                            -ErrorMessage ("Reset-TcSolution not attempted: the PLC objects in XAE and the .plcproj on disk differ. $describe. " +
                                'Not saved (that could overwrite a change made on disk) and not closed (that would drop the XAE objects). Choose: -SaveProjectChanges keeps the XAE version, -DiscardProjectChanges the disk version.'))
                    }
                    # -SaveProjectChanges: still refuse when the disk shows signs of a deliberate change.
                    $refused = [System.Collections.Generic.List[object]]::new()
                    if ($null -ne $resetGuard) {
                        $refused.Add([PSCustomObject]@{ plc = '*'; reason = "a reload prompt was answered without reloading by Connect-TcIde -TakeOverOrphan (reset-required: $($resetGuard.reason)): files were changed on disk while the solution was open" })
                    }
                    elseif ($progress.dismissedReloadPrompt) {
                        $refused.Add([PSCustomObject]@{ plc = '*'; reason = "a reload prompt ($($progress.reloadTarget)) was handled in step 1: files were changed on disk while the solution was open" })
                    }
                    foreach ($d in $diffs) {
                        $gone = @($d.missingOnDisk | Where-Object { -not $_.fileExists } | ForEach-Object { $_.relativePath })
                        if ($gone.Count -gt 0) { $refused.Add([PSCustomObject]@{ plc = $d.plc; reason = "object file(s) not on disk (deleted on disk?): $($gone -join ', ')" }) }
                    }
                    # Project.Save() writes the whole .tsproj and every .plcproj below it: every PLC of the
                    # same .tsproj (an unknown .tsproj counts as the same) must be fully compared and clean
                    # of extraOnDisk, else the save could overwrite a change on disk of another PLC.
                    $affected = [ordered]@{}
                    foreach ($d in $diffs) {
                        foreach ($q in @($unsaved.Plcs)) {
                            $qTs = [string]$q.tsproj
                            $same = [string]::IsNullOrWhiteSpace($qTs) -or [string]::Equals($qTs, [string]$d.tsproj, [StringComparison]::OrdinalIgnoreCase)
                            if ($same -and -not $affected.Contains([string]$q.plc)) { $affected[[string]$q.plc] = $q }
                        }
                    }
                    foreach ($q in $affected.Values) {
                        $via = if (@($diffs | Where-Object { $_.plc -eq $q.plc }).Count -gt 0) { '' } else { ' (same .tsproj as a PLC to save: Project.Save writes its .plcproj too)' }
                        if (-not $q.checked) { $refused.Add([PSCustomObject]@{ plc = $q.plc; reason = "its .plcproj could not be compared ($($q.reason))$via" }); continue }
                        if (@($q.extraOnDisk).Count -gt 0) { $refused.Add([PSCustomObject]@{ plc = $q.plc; reason = "the .plcproj on disk lists objects XAE does not have: $(@($q.extraOnDisk) -join ', ')$via" }) }
                        if (-not $q.complete) { $refused.Add([PSCustomObject]@{ plc = $q.plc; reason = "the comparison is incomplete ($($q.reason))$via" }) }
                    }
                    if ($refused.Count -gt 0) {
                        $why = @($refused | ForEach-Object { if ($_.plc -and $_.plc -ne '*') { "PLC '$($_.plc)': $($_.reason)" } else { $_.reason } }) -join '; '
                        return Complete-TcResetFailure -Step 'project check' -Result (New-TcResult -Success $false -ErrorCode 'PROJECT_UNSAVED_CHANGES' -Hint (Get-TcErrorHint -Code 'PROJECT_UNSAVED_CHANGES') `
                            -Data (Get-ProgressData -Extra @{ saveRefused = $refused.ToArray() }) `
                            -ErrorMessage "Reset-TcSolution not attempted: -SaveProjectChanges was given but saving is refused: $why. $describe. Nothing was saved or closed.")
                    }
                    $saved = [System.Collections.Generic.List[object]]::new()
                    foreach ($p in @($diffs | Where-Object { @($_.missingOnDisk).Count -gt 0 })) {
                        $files = @($p.missingOnDisk | ForEach-Object { $_.relativePath })
                        try {
                            $s = Save-TcPlcProject -PlcName $p.plc -ExpectFile $files
                            if ($s.Contains('ModalDialog')) {
                                $progress.savedProjects = $saved.ToArray()
                                return Complete-TcResetFailure -Step 'project save' -Result (New-TcModalDialogResult -Dialog $s.ModalDialog -Operation "Reset-TcSolution (saving the project file of PLC '$($p.plc)' before closing; nothing closed)" -Data (Get-ProgressData))
                            }
                            $saved.Add([PSCustomObject]@{ plc = $p.plc; plcproj = $s.plcproj; tsproj = $s.tsproj; savedFiles = $s.savedFiles; savedObjects = $files; plcprojChanged = $s.plcprojChanged; saveSec = $s.saveSec; warning = $s.warning })
                        }
                        catch {
                            $progress.savedProjects = $saved.ToArray()
                            $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_SAVE_FAILED' -MessagePrefix "Reset-TcSolution not attempted: PLC '$($p.plc)' has unsaved objects ($($files -join ', ')) and saving its project file failed, nothing was closed" -Data (Get-ProgressData)
                            if ($res.error.code -eq 'PROJECT_SAVE_TIMEOUT' -and $null -ne $script:TcLastProjectSaveDiagnostics) {
                                $res.data | Add-Member -NotePropertyName 'saveDiagnostics' -NotePropertyValue $script:TcLastProjectSaveDiagnostics -Force
                            }
                            return Complete-TcResetFailure -Step 'project save' -Result $res
                        }
                    }
                    $progress.savedProjects = $saved.ToArray()
                }
            }
        }

        # #87: check for a dialog right before closing anything. A project check that could not
        # read the project (no ITcSysManager, a PLC not located) is what a reload prompt that came
        # up after the guard looked like (2026-11-02); a reload prompt runs the steps again.
        $pc = $progress.projectCheck
        $incomplete = (-not $DiscardProjectChanges) -and ($null -ne $pc) -and ((-not $pc.checked) -or @($pc.plcs | Where-Object { -not $_.checked }).Count -gt 0)
        $preOp = if ($incomplete) { 'project check incomplete; nothing closed' } else { 'before Documents.CloseAll; nothing closed' }
        $found = Find-TcResetDialog -Operation $preOp
        if ($null -ne $found -and $null -ne $found.Failure) { return $found.Failure }
        if ($null -ne $found) { $pendingDialog = $found.Dialog; continue }

        $closeSw = [System.Diagnostics.Stopwatch]::StartNew()

        # --- 2. close every document (vsSaveChangesNo = 2) ---
        try {
            $progress.closedDocuments = [int](Invoke-TcComRetry -OperationName 'Documents.CloseAll' -TimeoutSec $TimeoutSec -ScriptBlock {
                $docs = $dte.Documents
                $n = 0
                if ($null -ne $docs) {
                    try { $n = [int]$docs.Count } catch { $n = 0 }
                    $docs.CloseAll(2)
                }
                $n
            })
        }
        catch {
            $closeError = $_
            $found = Find-TcResetDialog -Operation 'Documents.CloseAll failed; the solution was not closed'
            if ($null -ne $found -and $null -ne $found.Failure) { return $found.Failure }
            if ($null -ne $found) { $pendingDialog = $found.Dialog; continue }
            return Complete-TcResetFailure -Step 'Documents.CloseAll' -Result (New-TcAdsErrorResult -ErrorRecord $closeError -DefaultCode 'SOLUTION_CLOSE_FAILED' -MessagePrefix 'Documents.CloseAll failed' -Data (Get-ProgressData))
        }

        # --- 3. close the solution without saving ---
        # DTE.Solution answered $null here while a reload prompt was up (#87, 2026-11-02): never call
        # a method on it, check the dialog instead (also right before the call).
        $found = Find-TcResetDialog -Operation 'before Solution.Close; documents closed, the solution was not closed'
        if ($null -ne $found -and $null -ne $found.Failure) { return $found.Failure }
        if ($null -ne $found) { $pendingDialog = $found.Dialog; continue }
        try {
            Invoke-TcComRetry -OperationName 'Solution.Close' -TimeoutSec $TimeoutSec -ScriptBlock {
                $cSol = $dte.Solution
                if ($null -eq $cSol) { throw 'DTE.Solution answered $null before Solution.Close' }
                $cSol.Close($false)
            } | Out-Null
        }
        catch {
            $closeError = $_
            $found = Find-TcResetDialog -Operation 'Solution.Close failed; documents closed, the solution was not closed'
            if ($null -ne $found -and $null -ne $found.Failure) { return $found.Failure }
            if ($null -ne $found) { $pendingDialog = $found.Dialog; continue }
            return Complete-TcResetFailure -Step 'Solution.Close' -Result (New-TcAdsErrorResult -ErrorRecord $closeError -DefaultCode 'SOLUTION_CLOSE_FAILED' -MessagePrefix 'Solution.Close failed' -Data (Get-ProgressData))
        }
        $progress.closed = $true
        $closeSec = [math]::Round($closeSw.Elapsed.TotalSeconds, 1)

        # The ITcSysManager of the closed solution is dead; Connect-TcIde acquires the new one.
        if ($null -ne $script:TcSysManager) {
            try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcSysManager) | Out-Null } catch { }
            $script:TcSysManager = $null
        }

        # --- 4. reopen on the same DTE ---
        $openSw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-TcComRetry -OperationName 'Solution.Open' -TimeoutSec $TimeoutSec -ScriptBlock { $dte.Solution.Open($path) } | Out-Null
        }
        catch {
            return Complete-TcResetFailure -Step 'Solution.Open' -Always -Result (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_OPEN_FAILED' -MessagePrefix 'Solution closed but Solution.Open failed' `
                -Data (Get-ProgressData -Extra @{ closeSec = $closeSec }))
        }
        $progress.reopened = $true
        $progress.reopenedSolution = $true
        # The IDE has $path open now (maybe another .sln than before): keep the #29 record current
        # even if the reconnect below fails.
        $script:TcSolutionPath = $path
        if ($previousPid -gt 0) { Save-TcIdeSolutionRecord -ProcessId $previousPid -Solution $path }
        $openSec = [math]::Round($openSw.Elapsed.TotalSeconds, 1)

        # --- 5. reconnect: the instance now has the target solution open -> 'solution-match' ---
        $connectParams = @{ SolutionPath = $path; NoLaunch = $true }
        if (-not [string]::IsNullOrWhiteSpace($progId)) { $connectParams['ProgId'] = $progId }
        $connectSw = [System.Diagnostics.Stopwatch]::StartNew()
        $reopenIde = Get-TcResetIdeIdentity
        $connect = Invoke-TcResetConnect -Params $connectParams -Step 'reopen'
        $connectSec = [math]::Round($connectSw.Elapsed.TotalSeconds, 1)

        $resetChange = "Reset-TcSolution $([IO.Path]::GetFileName([string]$path)) (solution reopened from disk)"
        if (-not $connect.success) {
            # #180: a reload prompt that came up during this reconnect (measured 2026-11-08, 4026 VS2022
            # zh-TW: an outside process rewrote the .plcproj at the end of Solution.Open (trigger used:
            # rewrite it with the same bytes in the background); Connect-TcIde answered IDE_MODAL_DIALOG
            # with dialogKind reload-prompt) goes back to step 1 like one seen by the readback (#176),
            # while fewer than 5 prompts were handled. Connect-TcIde has bound the IDE it chose by then
            # (TcDte / TcIdeProcessId, Connect-TcIde.ps1 at its modal check); the IDE that reopened the
            # solution ($reopenIde, pid taken before the reconnect) is scanned again by its pid: step 1
            # needs that scan's dialog (window handle) to answer it. Only a reload prompt found by that
            # scan goes back, and only then is the module IDE identity restored to that IDE (step 1 counts
            # the prompt, so the loop stays bounded; its answers keep the #64 disabled-prompt rule and the
            # scan-before-read after a Yes, #181 review). A prompt gone by then, another dialog, an
            # incomplete scan or an unknown pid -> the reconnect failure below with the module state
            # Connect-TcIde left (fail closed, the same as any other reconnect failure).
            $cdp = $connect.PSObject.Properties['data']
            $connectKind = if ($null -ne $cdp -and $null -ne $cdp.Value -and $null -ne $cdp.Value.PSObject.Properties['dialogKind']) { [string]$cdp.Value.dialogKind } else { '' }
            if ([string]$connect.error.code -eq 'IDE_MODAL_DIALOG' -and $connectKind -eq 'reload-prompt' -and $state.Handled -lt 5) {
                $reopenPid = 0
                if ($null -ne $reopenIde.Pid) { try { $reopenPid = [int]$reopenIde.Pid } catch { $reopenPid = 0 } }
                $again = if ($reopenPid -gt 0) { Find-TcIdeModalDialog -ProcessId $reopenPid } else { $null }
                if ($null -ne $again -and -not (Test-TcModalScanIncomplete $again) -and [string]$again.Kind -eq 'reload-prompt') {
                    Write-Verbose "Reset-TcSolution: a reload prompt ($($again.ReloadTarget)) came up during the reconnect after Solution.Open; handling it (#180)."
                    Restore-TcResetIdeIdentity $reopenIde
                    $pendingDialog = $again
                    $dte = $script:TcDte; $progId = $script:TcProgId
                    continue
                }
                $why = if ($reopenPid -le 0) { 'pid of the IDE unknown, not scanned' } elseif ($null -eq $again) { 'no dialog' } else { [string]$again.Kind }
                Write-Verbose "Reset-TcSolution: the reconnect after Solution.Open saw a reload prompt, the scan after it did not ($why); failing closed."
                if ($null -ne $again) {
                    # PR #185 review B: report what the rescan saw - another dialog -> IDE_MODAL_DIALOG for
                    # THAT dialog, an incomplete scan -> MODAL_SCAN_INCOMPLETE (New-TcModalDialogResult).
                    $seen = New-TcModalDialogResult -Dialog $again -Operation 'Reset-TcSolution (reconnect after Solution.Open; the solution was reopened)' `
                        -Data (Get-ProgressData -Extra @{ closeSec = $closeSec; openSec = $openSec; connectSec = $connectSec })
                    return Register-TcCodeChange -Result $seen -Change $resetChange
                }
            }
            $failed = New-ReconnectFailedResult -Connect $connect -Extra @{ closeSec = $closeSec; openSec = $openSec; connectSec = $connectSec } -Where 'Solution reopened'
            return Register-TcCodeChange -Result $failed -Change $resetChange
        }

        $loadFail = Test-TcResetLoaded -Where 'Solution.Open'
        if ($loadFail -is [System.Collections.IDictionary]) {
            # #176: a reload prompt came up during the readback after the reopen: back to step 1
            # (Invoke-TcResetDialogStep: the 5-prompt limit covers the whole call; answers and polls share what
            # is left of -TimeoutSec, the COM steps are each capped by it on their own).
            # The state stays: NeedReopen / YesPathDone send the loop down the full guard / 1b /
            # close / reopen path again; only when neither is set (no prompt before) can a Yes
            # take the Yes-only path. The loop runs on the IDE Connect-TcIde re-bound.
            $pendingDialog = $loadFail.ReloadPrompt
            if ($null -ne $script:TcDte) { $dte = $script:TcDte; $progId = $script:TcProgId }
            continue
        }
        if ($null -ne $loadFail) {
            foreach ($kv in @(@('closeSec', $closeSec), @('openSec', $openSec), @('connectSec', $connectSec))) { $loadFail.data | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force }
            return Register-TcCodeChange -Result $loadFail -Change $resetChange
        }

        $ok = New-TcResult -Success $true -Data (New-ReconnectedData -ConnectData $connect.data -Total $sw -Extra ([ordered]@{
            closeSec   = $closeSec
            openSec    = $openSec
            connectSec = $connectSec
        }))
        $ok = Register-TcCodeChange -Result $ok -Change $resetChange
        # PR #209 review M1: the solution was reopened from disk and nothing was saved -> the
        # reset-required record of the takeover is removed (a save, or another .sln reopened, keeps it)
        if ($null -ne $state.ResetRequiredSolution) {
            $savedAny = @($progress['savedProjects']).Count -gt 0
            $samePath = [string]::Equals((ConvertTo-TcSolutionKey $state.ResetRequiredSolution), (ConvertTo-TcSolutionKey $path), [StringComparison]::OrdinalIgnoreCase)
            if (-not $savedAny -and $samePath) {
                $cw = Clear-TcResetRequired -SolutionPath $state.ResetRequiredSolution
                $ok.data | Add-Member -NotePropertyName 'resetRequiredCleared' -NotePropertyValue ($null -eq $cw) -Force
                if ($null -ne $cw) {
                    $prev = $ok.data.PSObject.Properties['stateWarning']
                    $ok.data | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue $(if ($null -ne $prev -and -not [string]::IsNullOrWhiteSpace([string]$prev.Value)) { "$($prev.Value); $cw" } else { $cw }) -Force
                }
            }
            else { $ok.data | Add-Member -NotePropertyName 'resetRequiredCleared' -NotePropertyValue $false -Force }
        }
        return $ok
    }
}
