function Connect-TcIde {
    <#
    .SYNOPSIS
        Connects to a running TwinCAT 3 IDE instance via the Running Object Table.
    .DESCRIPTION
        Obtains the EnvDTE and ITcSysManager interfaces. Enumerates every DTE
        registered in the ROT (XAE Shell 15.0 / 17.0 and VS2022 alike) and picks one:
          - with -SolutionPath: ONLY the instance that already has that .sln open
            (path compared case-insensitively after normalisation; selectedBy
            'solution-match'). An empty IDE or one with another solution is never
            reused - it belongs to whoever opened it (opening the target there would
            hijack it and -Quit would close it) - so otherwise a new IDE is launched
            (selectedBy 'launched'). Exception (#29): an instance whose DTE is blocked (busy
            RPC_E_CALL_REJECTED, or an empty Version with a modal dialog up) is checked without
            COM (Find-TcBlockedSolutionIde): a session record of that process with this
            solution, or a dialog text naming a path inside the solution folder, is strong
            evidence - nothing is launched, the instance is attached (selectedBy
            'solution-blocked', ITcSysManager $null, data.attached = true) and Find-TcIdeModalDialog
            / Reset-TcSolution work on it right away; a main window title starting with the
            solution name is weak evidence (same-named copies look alike) - nothing is launched
            and nothing is attached (data.attached = false). Either way IDE_MODAL_DIALOG (dialog
            found; data.dialog, ideProcessId, rotDisplayName, windowTitle, matchedBy, probe) or
            IDE_BUSY (no dialog) is returned; after the dialog is closed the same Connect-TcIde
            call connects normally. Every successful connect with a solution writes the session
            record (Save-TcIdeSolutionRecord; Open-TcProject / New-TcProject update it). A
            record / module state contradicted by the window title or the dialog paths, or two
            IDEs with strong evidence, attach nothing (data.notAttachedReason). The previous
            connection (TcDte / TcIdeConnected / TcSysManager) is cleared first, so a call that
            fails before an IDE is chosen leaves no connection at all; a failure after that
            (modal check, Solution.Open) leaves the chosen IDE connected;
          - without -SolutionPath: an instance that has a TwinCAT project loaded,
            otherwise the first instance (busy ones last).
        For every ROT entry DTE.Version and Solution.FullName are read: an instance
        that stays busy (RPC_E_CALL_REJECTED) after a short retry is kept as a
        last-resort candidate (solution '<busy>', only used without -SolutionPath); an
        instance failing with any other COM error (dead RPC server 0x800706BA, E_FAIL
        0x80004005 - typically an IDE that is shutting down) is skipped. When no DTE
        instance qualifies a new IDE is launched (#72, data.progIdSelectedBy): the single -ProgId
        given ('explicit'); else the IDE of the TwinCAT build the .tsproj files of -SolutionPath
        were saved with (root attribute TcVersion; 'tsproj-version', evidence in
        data.solutionVersion): build >= 4026 -> TcXaeShell.DTE.17.0, else VisualStudio.DTE.17.0
        (only with the TwinCAT XAE integrated); build < 4026 -> TcXaeShell.DTE.15.0; launched only
        when the TwinCAT XAE Base version found in its install folder (via the ProgID's
        LocalServer32) EQUALS the TcVersion, revision included. A solution without any .tsproj (or no -SolutionPath)
        and a single registered IDE -> 'only-one-registered'. Otherwise nothing is launched:
        IDE_VERSION_NOT_REGISTERED (build known, no IDE confirmed for it) or PROGID_REQUIRED (the
        version of a .tsproj unreadable / conflicting, XAE build not confirmable, several IDEs). #136:
        an IDE this session launched for -SolutionPath that can still be alive is waited for (max
        60 s, also with -NoLaunch) and attached (selectedBy 'session-launched') - never a second
        IDE for the same .sln, not even with -LaunchIfBlocked; if it does not answer, its pid is
        not confirmed or -ProgId names another ProgID, IDE_LAUNCH_PENDING. The pid of a launched
        IDE is taken from the ROT entry holding the identical DTE object (data.pidSource
        'rot-identity') or the DTE main window; a pid only guessed from the start time is never
        owned or attached (IDE_LAUNCH_PENDING, data.pidConfirmed = false). A launched IDE is polled (500 ms, max
        60 s) until DTE.Version and DTE.Solution are readable, then UserControl is
        set so it stays visible; if it never becomes ready it is quit / killed again
        (no orphan) and IDE_LAUNCH_FAILED is returned.
        When -SolutionPath is specified, the solution is opened automatically after
        connecting and ITcSysManager is obtained in one step (up to 10 x 1 s).
        Before touching the solution the IDE process is checked for a modal dialog
        (Find-TcIdeModalDialog); if one is open IDE_MODAL_DIALOG is returned.
    .PARAMETER ProgId
        COM ProgID to connect to / launch. When given, running instances with this
        ProgID are preferred and only this ProgID is used for launching. Without it the IDE to
        launch is derived from the .tsproj TcVersion of -SolutionPath; on a machine with several
        IDEs pass -SolutionPath or -ProgId (else PROGID_REQUIRED). An IDE this session launched
        for the same solution with another ProgID is not attached (IDE_LAUNCH_PENDING,
        data.progIdMismatch).
    .PARAMETER SolutionPath
        Path to a .sln file. If specified, the IDE will open this solution
        automatically after connecting (or connect to an instance already
        running this solution).
    .PARAMETER NoLaunch
        If set, do not launch a new IDE instance if none is running. With -SolutionPath an IDE
        this session launched for that solution and that is still starting is still waited for
        (up to 60 s) before IDE_LAUNCH_PENDING is returned.
    .PARAMETER LaunchIfBlocked
        With -SolutionPath: ignore a blocked IDE that matches only by window title
        (matchedBy 'window-title', i.e. a same-named solution that may be someone else's) and
        go on as if it were not there (launch unless -NoLaunch). A blocked IDE recognised by
        strong evidence (module-state, session-record, dialog-path) is still reported.
    .PARAMETER TakeOverOrphan
        With -SolutionPath (#196): take over the IDE that another TcAuto session launched for that
        solution after that session ended (IDE_LAUNCH_PENDING probe 'other-session', hostState
        'gone'), so this session owns it (Disconnect-TcIde -Quit / -Kill). Only when the launch record
        of that .sln names a host process (bridge) that is gone AND an owner process (MCP server,
        ownerPid) that is gone too - a restarted bridge of a running session is refused
        (owner-alive / owner-unverifiable) -, its pid is confirmed, the ROT has that pid's
        DTE with this .sln open and no modal dialog is up; otherwise nothing is attached
        (ORPHAN_TAKEOVER_REFUSED with data.reason, IDE_MODAL_DIALOG / MODAL_SCAN_INCOMPLETE, or
        LAUNCH_RECORD_UNAVAILABLE). #201: a known reload prompt (kind reload-prompt) of that IDE
        is answered without reloading (solution: Ignore only, project: No, file: WM_CLOSE; at most
        5 prompts) only when: -SolutionPath given, a launch record of that .sln, its host and owner
        processes gone, its pid confirmed, -ProgId (when given) the launch ProgID, the pid's DTE in
        the ROT, and either that DTE answered with this .sln open or - DTE blocked - the dialog
        text names only files inside the solution folder, or (no drive path in the text at all)
        the solution name in quotes ('<name>'). Then the DTE is read again and BUILD_REQUIRED
        kind reset-required is recorded for the .sln (Build-TcProject, Enable-TcConfig,
        Enter-TcPlcOnline, New-TcBootProject, Save-TcPlcLibrary and every project-file save
        refuse with RESET_REQUIRED until Reset-TcSolution reopened it from disk). On success
        data.reloadPromptAttempts, data.diskChangesNotLoaded = true, data.resetRequired (the
        record: the field that says a prompt of this .sln was answered, now or by an earlier
        takeover) and data.nextStep; every takeover also lists unsaved editor documents
        (data.dirtyDocuments, Document.Saved = false; data.dirtyDocumentsError when unreadable):
        Reset-TcSolution would close them without saving and refuses while any exists unless
        -DiscardProjectChanges. Any other dialog (also one found after the attach), a prompt
        without that evidence or one that stays up: IDE_MODAL_DIALOG with the
        IDE_MODAL_DIALOG_ORPHAN hint (nothing attached, so not Reset-TcSolution /
        Disconnect-TcIde); every failed exit carries data.reloadPromptAttempts /
        data.resetRequired like the success. Only after the attach, the modal check and the project scan have
        passed does the record get this process as owner plus a takeovers[] entry;
        data.takenOver = true, data.previousOwner. Use it only after the user confirmed nobody still
        works in that IDE.
    .EXAMPLE
        Connect-TcIde
        Connect-TcIde -ProgId "VisualStudio.DTE.17.0"
        Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"
    .OUTPUTS
        data.progId       ProgID actually used (parsed from the ROT moniker, else DTE.RegistryRoot)
        data.progIdSelectedBy  explicit | running-instance | tsproj-version | only-one-registered
        data.ideProcessId pid of the connected IDE (0 when it could not be determined)
        data.pidSource    rot-identity | main-window | known-pid | start-time (guess) | ''
        data.candidates   every DTE instance seen in the ROT: @{ progId; solution; pid }
        data.connectSec   seconds the whole call took (every successful path)
        data.solutionPlatform / solutionConfiguration  active solution platform and
                          configuration ($null when unreadable); see Set-TcTarget -Platform
        data.projectPlatform  project platform the .tsproj is built for under the active
                          solution platform (may differ from solutionPlatform, e.g. solution
                          'TwinCAT OS (x64)' -> project 'TwinCAT OS (ARMT2)')
        data.launchSec    seconds from starting a new IDE until its DTE answered (only when selectedBy = 'launched')
        data.ownedBySession  this session (or an earlier module instance / bridge, launched-ides.json) launched the IDE
        data.launchRecordWarning  launched-ides.json could not be read / written (only when that happened)
        data.takenOver / data.previousOwner  -TakeOverOrphan only (#196): true, and the ended owner
                          { hostPid; hostStartTime; moduleInstanceId; ownerId; hostState; ownerPid; ownerState } (selectedBy 'orphan-takeover')
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ProgId,

        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [switch]$NoLaunch,

        [Parameter()]
        [switch]$LaunchIfBlocked,

        [Parameter()]
        [switch]$TakeOverOrphan
    )

    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    $launchSec = $null

    # Forget the pid / HWND of a previous connection: Invoke-TcComRetry checks that pid after an
    # RPC failure, and a stale pid (IDE that has since exited) would turn a busy call against the
    # new instance into a false IDE_CRASHED.
    # An IDE this session launched stays 'owned' (Disconnect-TcIde -Kill) whatever a later
    # Connect-TcIde (a failed one included) finds: Add-TcLaunchedIde / Test-TcLaunchedIde keep the
    # pid + start time of every IDE this module launched, independent of TcIdeSelectedBy, and
    # (#73 / #149) launched-ides.json keeps them across a bridge restart / ReloadModule.
    # Also kept for #29: the IDE this module was connected to and its solution
    # (Find-TcBlockedSolutionIde 'module-state': recognises our own blocked IDE without file I/O).
    # #127 F1: a session-record write that was skipped earlier (lock busy) is retried first
    Sync-TcIdeSolutionRecordPending
    $script:TcLaunchRecordWarning = $null   # #73: set by a failed read / write of launched-ides.json during this call
    $previousIdePid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $previousIdePid = [int]$script:TcIdeProcessId } catch { $previousIdePid = 0 } }
    $previousSolution = [string]$script:TcSolutionPath
    $previousIdeStart = $script:TcIdeStartTime   # module-state needs pid AND start time (no recycled pid)
    $script:TcIdeSelectedBy = $null
    $script:TcIdeProcessId = $null
    $script:TcIdeStartTime = $null
    $script:TcIdeMainHwnd = 0
    $script:TcSolutionPath = $null
    # The old connection is dropped as well: a Connect-TcIde that fails before it binds an IDE
    # must not leave TcDte pointing at the previous IDE (a hint such as Reset-TcSolution would
    # then act on that one). Reset-TcSolution saves and restores its own state around its
    # reconnect. Settings / SilentMode belong to that IDE too.
    $script:TcDte = $null
    $script:TcIdeConnected = $false
    $script:TcSysManager = $null
    # The settings RCW is not released here: Reset-TcSolution restores it when its reconnect
    # fails. The SilentMode ORIGINAL value of that IDE is not lost: Connect-TcIde keeps it per
    # process (Get-TcIdeSilentOriginal) and reuses it the next time it connects to that process.
    $script:TcAutomationSettings = $null
    $script:TcSilentMode = $false
    $script:TcSilentModeOriginal = $null

    # Validate SolutionPath if provided
    $normalizedSolutionPath = $null
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        if (-not (Test-Path $SolutionPath)) {
            return New-TcResult -Success $false -ErrorMessage "Solution file not found: $SolutionPath" -ErrorCode 'FILE_NOT_FOUND'
        }
        $SolutionPath = (Resolve-Path $SolutionPath).Path
        $normalizedSolutionPath = Get-TcLongPath $SolutionPath   # 8.3 short names expanded (#63)
    }

    $progIds = @($script:TcKnownIdeProgIds)
    if (-not [string]::IsNullOrWhiteSpace($ProgId)) {
        $progIds = @($ProgId)
    }

    $dte = $null
    $usedProgId = $null
    $selectionReason = $null
    $launchTime = $null
    # #72: how the ProgID was chosen: explicit (-ProgId), running-instance (an IDE found in the
    # ROT), tsproj-version / only-one-registered (launch, Resolve-TcLaunchProgId)
    $progIdSelectedBy = $null
    $progIdEvidence = $null

    # --- Enumerate ALL running IDE instances via ROT ---
    # (Marshal.GetActiveObject only returns ONE per ProgID; ROT enumeration finds ALL)
    $rotEntries = @(Get-AllComObjects -IncludeDisplayName)
    Write-Verbose "ROT enumeration found $($rotEntries.Count) DTE instance(s)"

    # Build candidate list; every COM property read is guarded.
    # - DTE.Version and Solution.FullName are read with a short busy-retry. An instance
    #   that is still busy afterwards (modal dialog, loading) is KEPT as a last-resort
    #   candidate with solution '<busy>', so a single busy IDE is reused instead of
    #   launching a second one.
    # - Instances failing with any other error are skipped: an IDE that is shutting
    #   down stays in the ROT for a while and answers RPC_S_SERVER_UNAVAILABLE
    #   (0x800706BA) or E_FAIL (0x80004005); picking it makes Solution.Open return null.
    $readyCandidates = @()
    $busyCandidates = @()
    $unreadableCandidates = @()
    foreach ($entry in $rotEntries) {
        $obj = $entry['Object']
        if ($null -eq $obj) { continue }

        $solution = $null
        $isBusy = $false
        try {
            $solution = Invoke-TcComRetry -MaxRetries 3 -OperationName 'Read DTE.Version / Solution.FullName' -ScriptBlock {
                $ver = [string]$obj.Version
                if ([string]::IsNullOrWhiteSpace($ver)) { throw 'DTE.Version is empty (stale ROT entry)' }
                $sol = $obj.Solution
                if ($null -ne $sol) { [string]$sol.FullName } else { '' }
            }
        }
        catch {
            $mappedErr = ConvertTo-TcAdsErrorCode -InputObject $_
            if ($null -ne $mappedErr -and $mappedErr.Code -eq 'IDE_BUSY') {
                $isBusy = $true
                $solution = '<busy>'
                Write-Verbose "DTE '$($entry['DisplayName'])' is busy, keeping it as last-resort candidate ($($_.Exception.Message))"
            }
            else {
                Write-Verbose "Skipping DTE '$($entry['DisplayName'])': Version/Solution unreadable, probably shutting down ($($_.Exception.Message))"
                # #29: an IDE showing a modal dialog can also answer an EMPTY DTE.Version instead of
                # RPC_E_CALL_REJECTED (measured 2026-10-25, 4024 32-bit XAE Shell with the XAE
                # "project file ... modified outside of TwinCAT XAE" prompt up). Kept aside: it only
                # counts as the blocked owner of -SolutionPath when a modal dialog is found in it.
                $unreadableCandidates += [PSCustomObject]@{
                    progId      = $entry['ProgId']
                    solution    = '<unreadable>'
                    pid         = $entry['ProcessId']
                    busy        = $false
                    unreadable  = $true
                    displayName = [string]$entry['DisplayName']
                    Object      = $obj
                }
                continue
            }
        }

        $candidateProgId = $entry['ProgId']
        if ([string]::IsNullOrWhiteSpace($candidateProgId) -and -not $isBusy) {
            $candidateProgId = try { [string]$obj.RegistryRoot } catch { $null }
        }

        $hasTcProject = $false
        if (-not $isBusy) {
            try {
                $sol = $obj.Solution
                if ($null -ne $sol -and $sol.Projects.Count -gt 0) {
                    for ($i = 1; $i -le $sol.Projects.Count; $i++) {
                        try {
                            $smProbe = $sol.Projects.Item($i).Object
                            if ($null -ne $smProbe) { $hasTcProject = $true; break }
                        }
                        catch { continue }
                    }
                }
            }
            catch { }
        }

        $normalizedSolution = $null
        if (-not $isBusy -and -not [string]::IsNullOrWhiteSpace($solution)) {
            $normalizedSolution = try { Get-TcLongPath $solution } catch { $solution }
        }

        $candidate = [PSCustomObject]@{
            progId             = $candidateProgId
            solution           = $solution
            pid                = $entry['ProcessId']
            hasTcProject       = $hasTcProject
            normalizedSolution = $normalizedSolution
            busy               = $isBusy
            displayName        = [string]$entry['DisplayName']
            Object             = $obj
        }
        if ($isBusy) { $busyCandidates += $candidate } else { $readyCandidates += $candidate }
    }
    # Busy instances are sorted last: only chosen when no readable instance exists.
    $candidates = @($readyCandidates) + @($busyCandidates)

    # When -ProgId is given, prefer instances of that ProgID (fall back to all if none match)
    $pool = $candidates
    if (-not [string]::IsNullOrWhiteSpace($ProgId) -and $candidates.Count -gt 0) {
        $matching = @($candidates | Where-Object { $_.progId -and ($_.progId -ieq $ProgId) })
        if ($matching.Count -gt 0) { $pool = $matching }
    }

    $chosen = $null
    if ($pool.Count -gt 0) {
        if ($null -ne $normalizedSolutionPath) {
            # With -SolutionPath only the instance that already has THAT solution open is reused.
            # An empty IDE, one with another solution, or a busy one (solution unknown) belongs to
            # whoever opened it: opening the target solution there would hijack it, and a later
            # Disconnect-TcIde -Quit would close it. When no instance matches, a new IDE is
            # launched (tests/Integration/multi-ide.ps1 covers the three-IDE desktop).
            $chosen = $pool | Where-Object {
                $_.normalizedSolution -and ([string]::Equals($_.normalizedSolution, $normalizedSolutionPath, [StringComparison]::OrdinalIgnoreCase))
            } | Select-Object -First 1
            if ($null -ne $chosen) { $selectionReason = 'solution-match' }
        }
        else {
            # No SolutionPath: prefer an instance that already has a TwinCAT project,
            # otherwise the first usable instance (busy ones last).
            $chosen = $pool | Where-Object { $_.hasTcProject } | Select-Object -First 1
            if ($null -ne $chosen) { $selectionReason = 'twincat-project-loaded' }
            if ($null -eq $chosen) {
                $chosen = $pool | Select-Object -First 1
                $selectionReason = if ($chosen.busy) { 'busy-instance' } else { 'first-instance' }
            }
        }
    }

    if ($null -ne $chosen) {
        $dte = $chosen.Object
        $usedProgId = $chosen.progId
        $progIdSelectedBy = if (-not [string]::IsNullOrWhiteSpace($ProgId) -and $usedProgId -ieq $ProgId) { 'explicit' } else { 'running-instance' }
        Write-Verbose "Connected to DTE pid=$($chosen.pid) progId=$usedProgId solution='$($chosen.solution)' ($selectionReason)"
    }

    # --- #196: explicit takeover of an IDE whose launching TcAuto session has ended ---
    # Every condition is checked by Resolve-TcOrphanTakeover; any failure is returned as it is
    # (never another selection path). The record is rewritten under the lock (fail closed) only
    # after the attach, the modal check and the project scan below have passed (#196 review M2):
    # a Connect-TcIde that fails on the way never moves the ownership.
    $takeover = $null
    $orphan = $null
    if ($TakeOverOrphan) {
        $orphan = Resolve-TcOrphanTakeover -SolutionPath $normalizedSolutionPath -ProgId $ProgId -Candidates $candidates -UnreadableCandidates $unreadableCandidates
        if ($null -ne $orphan.Result) { return $orphan.Result }
        $oc = $orphan.Candidate
        $chosen = $oc
        $dte = $oc.Object
        $usedProgId = $oc.progId
        if ([string]::IsNullOrWhiteSpace($usedProgId)) { $usedProgId = [string]$orphan.Record.progId }
        $selectionReason = 'orphan-takeover'
        $progIdSelectedBy = if (-not [string]::IsNullOrWhiteSpace($ProgId)) { 'explicit' } else { 'running-instance' }
        Write-Verbose "Taking over IDE pid $($oc.pid) for '$normalizedSolutionPath' from the ended TcAuto session (host pid $($orphan.Record.hostPid)) once the attach has passed (#196)"
    }

    # --- #136: this session already launched an IDE for -SolutionPath and it can still be alive ---
    # (cold VS2022 start: the first Connect-TcIde answered MODAL_SCAN_INCOMPLETE before the
    # solution was opened, so neither solution-match nor the session record knows it). Checked
    # before the #29 blocked-IDE evidence: never launch a second IDE for the same .sln (not with
    # -LaunchIfBlocked either). Wait for that IDE (Wait-TcSessionLaunchedIde, max 60 s, also with
    # -NoLaunch) and attach to it, or return IDE_LAUNCH_PENDING / IDE_MODAL_DIALOG. Not attached:
    #  - its pid is not confirmed (ROT identity / main window) - another IDE that came up at the same
    #    time must never be taken for it (#147 M2);
    #  - -ProgId names another ProgID than the one it was launched with (data.progIdMismatch, M1).
    # Released only when it meanwhile has ANOTHER solution open or its process is gone.
    if ($null -eq $chosen -and $null -ne $normalizedSolutionPath) {
        $own = Find-TcSessionLaunchedIde -Solution $normalizedSolutionPath
        # #152 R3-1: a record of ANOTHER session no longer blocks this .sln when that IDE (same pid,
        # read above from the ROT - no new COM call) now has another solution open; when its host
        # is gone, also when it has no solution open. A live host with an empty solution may still
        # be cold-starting: kept. A busy / unreadable IDE (solution unknown): kept.
        if ($null -ne $own -and $null -ne $own.otherSession) {
            $op = 0; try { $op = [int]$own.otherSession.processId } catch { $op = 0 }
            $seen = @($readyCandidates | Where-Object { $op -gt 0 -and [int]$_.pid -eq $op }) | Select-Object -First 1
            if ($null -ne $seen) {
                $seenSol = [string]$seen.normalizedSolution
                $release = if (-not [string]::IsNullOrWhiteSpace($seenSol)) { -not [string]::Equals($seenSol, $normalizedSolutionPath, [StringComparison]::OrdinalIgnoreCase) } else { $own.otherSession.hostState -eq 'gone' -and $own.otherSession.ownerState -in 'none', 'gone' }   # #196 review: a restarted bridge of a running server still blocks
                if ($release) {
                    Write-Verbose "Launch record of another session (IDE pid $op) does not block '$normalizedSolutionPath': that IDE now has '$seenSol' open"
                    $own = $null
                }
            }
        }
        if ($null -ne $own) {
            $mismatch = $null
            if (-not [string]::IsNullOrWhiteSpace($ProgId) -and -not ([string]$own.progId -ieq $ProgId)) {
                $mismatch = [PSCustomObject]@{ requested = $ProgId; launched = [string]$own.progId }
            }
            # #152 M1: launched by another live TcAuto session -> blocks a second launch, never attached / owned
            $other = $own.otherSession
            $wait = if ($null -eq $mismatch -and $null -eq $other) { Wait-TcSessionLaunchedIde -Record $own } else { $null }
            if ($null -ne $wait -and $wait.state -eq 'ready') {
                $dte = $wait.entry['Object']
                $usedProgId = [string]$wait.entry['ProgId']
                if ([string]::IsNullOrWhiteSpace($usedProgId)) { $usedProgId = [string]$own.progId }
                $selectionReason = 'session-launched'
                $progIdSelectedBy = if (-not [string]::IsNullOrWhiteSpace($ProgId)) { 'explicit' } else { 'running-instance' }
                $chosen = [PSCustomObject]@{ pid = [int]$own.processId; progId = $usedProgId; solution = $wait.solution }
                Write-Verbose "Attached to IDE pid $($own.processId) launched by this session for '$normalizedSolutionPath' (#136)"
            }
            elseif ($null -ne $wait -and $wait.state -in 'other-solution', 'gone') {
                Clear-TcSessionLaunchedIde -Solution $normalizedSolutionPath   # no longer the IDE of this solution
            }
            else {
                # Still starting / blocked / not ours to attach: a CONFIRMED pid is kept (no DTE
                # calls), so Get-TcIdeModalDialog -ProcessId and Disconnect-TcIde -Quit -Kill can act
                # on it; nothing is launched.
                $ownPid = if ($null -ne $other) { 0 } else { [int]$own.processId }
                if ($ownPid -gt 0) {
                    $script:TcIdeProcessId = $ownPid
                    $script:TcIdeSelectedBy = 'launched'
                    try { $script:TcIdeStartTime = (Get-Process -Id $ownPid -ErrorAction Stop).StartTime } catch { $script:TcIdeStartTime = $null }
                }
                $probe = if ($null -ne $other) { 'other-session' } elseif ($null -ne $mismatch) { 'progid-mismatch' } else { $wait.state }
                $pendingData = [PSCustomObject]@{
                    ideProcessId      = $ownPid
                    ideStartTime      = $(if ($null -ne $own.processKey) { ($own.processKey -split '\|', 2)[1] } else { $null })
                    pidConfirmed      = ($ownPid -gt 0)
                    progId            = [string]$own.progId
                    progIdMismatch    = $mismatch
                    probe             = $probe
                    waitedSec         = $(if ($null -ne $wait) { $wait.waitedSec } else { 0 })
                    launchedBySession = ($null -eq $other)
                    ownedBySession    = ($ownPid -gt 0)
                    attached          = $false
                    launched          = $false
                    solution          = $normalizedSolutionPath
                    candidates        = @($candidates | ForEach-Object { [PSCustomObject]@{ progId = $_.progId; solution = $_.solution; pid = $_.pid } })
                    connectSec        = [math]::Round($swTotal.Elapsed.TotalSeconds, 1)
                }
                # m2: a pid only guessed (restored pid-unconfirmed record) is reported apart, never as ideProcessId
                if ($null -ne $own.guessedRecord) { $pendingData | Add-Member -NotePropertyName 'guessedProcessId' -NotePropertyValue ([int]$own.guessedRecord.pid) }
                if ($null -ne $other) { $pendingData | Add-Member -NotePropertyName 'otherSession' -NotePropertyValue $other }
                if ($probe -eq 'dialog') {
                    return New-TcModalDialogResult -Dialog $wait.dialog -Operation "Connect-TcIde -SolutionPath (IDE pid $ownPid launched by this session for this solution; no second IDE launched)" -Data $pendingData
                }
                if ($probe -eq 'scan-incomplete') {
                    $pendingData | Add-Member -NotePropertyName 'scanComplete' -NotePropertyValue $false
                    $pendingData | Add-Member -NotePropertyName 'modalScan' -NotePropertyValue (ConvertTo-TcModalScanInfo -Scan $wait.dialog)
                }
                $why = switch ($probe) {
                    'progid-mismatch' { "it was launched as $($own.progId), not the requested -ProgId $ProgId; it is not attached" }
                    'pid-unconfirmed' { 'its process id is not confirmed (the ROT has no entry with that DTE object yet), so no IDE is attached' }
                    'other-session' {
                        if ($other.hostState -eq 'gone' -and $other.ownerState -in 'none', 'gone') { "it was launched by another TcAuto session that has ended (host pid $($other.hostPid) is gone); it is not attached and not owned here (Connect-TcIde -TakeOverOrphan can take it over)" }
                        elseif ($other.hostState -eq 'gone') { "it was launched by another TcAuto session whose bridge (host pid $($other.hostPid)) is gone but whose MCP server is still running or cannot be verified (owner pid $($other.ownerPid), ownerState $($other.ownerState)); it is not attached and not owned here" }
                        else { "it was launched by another TcAuto session that is still running or cannot be verified (host pid $($other.hostPid), hostState $($other.hostState)); it is not attached and not owned here" }
                    }
                    default { "its DTE did not answer within $($wait.waitedSec) s ($probe)" }
                }
                # N5: <pid> = the process the caller should look at (own pid, the other session's IDE, or the guessed pid)
                $hintPid = if ($ownPid -gt 0) { [string]$ownPid } elseif ($null -ne $other) { [string]$other.processId } elseif ($null -ne $own.guessedRecord) { [string]([int]$own.guessedRecord.pid) } else { '<data.ideProcessId>' }
                $hint = ([string](Get-TcErrorHint -Code 'IDE_LAUNCH_PENDING')).Replace('<pid>', $hintPid)
                # #196: an ended session's IDE can be taken over explicitly
                if ($null -ne $other -and $other.hostState -eq 'gone' -and $other.ownerState -in 'none', 'gone') { $hint = ([string]$script:TcHintFragments['IDE_LAUNCH_PENDING_ORPHAN']).Replace('<pid>', $hintPid) + $hint }
                if ($null -ne $script:TcLaunchRecordWarning) { $pendingData | Add-Member -NotePropertyName 'launchRecordWarning' -NotePropertyValue $script:TcLaunchRecordWarning -Force }
                return New-TcResult -Success $false `
                    -ErrorMessage "IDE_LAUNCH_PENDING: $(if ($null -ne $other) { 'another TcAuto session' } else { 'this session' }) launched an IDE$(if ($ownPid -gt 0) { " (pid $ownPid)" }) for '$normalizedSolutionPath' that may still be running, but $why. No second IDE was launched." `
                    -ErrorCode 'IDE_LAUNCH_PENDING' -Hint $hint -Data $pendingData
            }
        }
    }

    # --- #29: the IDE that has -SolutionPath open may be blocked (modal dialog / busy) ---
    # Its DTE answered RPC_E_CALL_REJECTED or an empty Version, so it never matched above.
    # Launching a second IDE for the same .sln (or, with -NoLaunch, answering IDE_NOT_FOUND) would
    # be wrong: identify it without COM (Find-TcBlockedSolutionIde) and report it instead.
    #  - strong evidence: module-state / session-record corroborated by a current fact (a title
    #    that starts with the solution name while no same-named .sln is known elsewhere, or a
    #    dialog path inside the folder) and not contradicted, or an uncontradicted dialog-path.
    #    The blocked instance is ATTACHED (module state points at it, ITcSysManager stays $null)
    #    so that Find-TcIdeModalDialog and Reset-TcSolution can act on it right away;
    #  - weak / contradicted / ambiguous evidence (title only, stale record, two strong IDEs):
    #    nothing is launched and nothing is attached - another agent's IDE must never become ours
    #    (a later Disconnect-TcIde -Quit would close it).
    if ($null -eq $chosen -and $null -ne $normalizedSolutionPath) {
        $busyPool = @($pool | Where-Object { $_.busy })
        $unreadablePool = @($unreadableCandidates)
        if (-not [string]::IsNullOrWhiteSpace($ProgId)) {
            $unreadableMatching = @($unreadablePool | Where-Object { $_.progId -and ($_.progId -ieq $ProgId) })
            if ($unreadableMatching.Count -gt 0) { $unreadablePool = $unreadableMatching }
        }
        $busyPool = @($busyPool) + @($unreadablePool)
        if ($busyPool.Count -gt 0) {
            $blocked = @(Find-TcBlockedSolutionIde -Candidates $busyPool -SolutionPath $normalizedSolutionPath -PreviousProcessId $previousIdePid -PreviousStartTime $previousIdeStart -PreviousSolution $previousSolution -KnownSolutions @($readyCandidates | ForEach-Object { $_.normalizedSolution } | Where-Object { $_ }))
            # -LaunchIfBlocked: the caller knows the title-only match is someone else's IDE.
            if ($LaunchIfBlocked) { $blocked = @($blocked | Where-Object { $_.Strong }) }
            if ($blocked.Count -gt 0) {
                $hit = $blocked[0]
                $bc = $hit.Candidate
                # #42: the dialog scan of the blocked IDE may not have completed (unknown, not "no dialog")
                $hitScanIncomplete = Test-TcModalScanIncomplete $hit.Dialog
                $hitDialog = if ($hitScanIncomplete) { $null } else { $hit.Dialog }
                $blockedPid = [int]$bc.pid
                # Two IDEs with strong evidence for the same .sln: ambiguous, attach none.
                $strongCount = @($blocked | Where-Object { $_.Strong }).Count
                $attach = [bool]$hit.Strong -and $strongCount -eq 1
                if ($attach) {
                    $script:TcDte = $bc.Object
                    $script:TcProgId = $bc.progId
                    $script:TcIdeConnected = $true
                    $script:TcSysManager = $null
                    $script:TcLastModalDialog = $hitDialog
                    $script:TcSolutionPath = $normalizedSolutionPath
                    $script:TcIdeProcessId = $blockedPid
                    $script:TcIdeSelectedBy = if (Test-TcLaunchedIde -ProcessId $blockedPid) { 'launched' } else { 'solution-blocked' }
                    $script:TcIdeMainHwnd = 0
                    try { $p = Get-Process -Id $blockedPid -ErrorAction Stop; $script:TcIdeMainHwnd = [long]$p.MainWindowHandle; $script:TcIdeStartTime = $p.StartTime } catch { $script:TcIdeStartTime = $null }
                }

                $whyNot = if ($strongCount -gt 1) { "$strongCount IDEs match with strong evidence" } elseif ($null -ne $hit.Contradiction) { [string]$hit.Contradiction } else { "window title '$($hit.WindowTitle)' only: could also be a same-named solution in another folder" }
                $evidence = if ($attach) { "has the solution open, matched by $($hit.MatchedBy)" } else { "may have the solution open (matched by $($hit.MatchedBy), but $whyNot; not attached)" }
                $blockedData = [PSCustomObject]@{
                    progId            = $bc.progId
                    ideProcessId      = $blockedPid
                    rotDisplayName    = $bc.displayName
                    windowTitle       = $hit.WindowTitle
                    matchedBy         = $hit.MatchedBy
                    probe             = $(if ($bc.busy) { 'busy (RPC_E_CALL_REJECTED after 3 attempts)' } else { 'unreadable (DTE.Version empty)' })
                    attached          = $attach
                    notAttachedReason = $(if ($attach) { $null } else { $whyNot })
                    corroboratedBy    = $hit.CorroboratedBy
                    launchedBySession = (Test-TcLaunchedIde -ProcessId $blockedPid)
                    ownedBySession    = ($attach -and $script:TcIdeSelectedBy -eq 'launched')
                    launched          = $false
                    solution          = $normalizedSolutionPath
                    blockedCandidates = @($blocked | ForEach-Object { [PSCustomObject]@{ pid = $_.Candidate.pid; progId = $_.Candidate.progId; windowTitle = $_.WindowTitle; matchedBy = $_.MatchedBy; strong = [bool]$_.Strong; contradiction = $_.Contradiction; corroboratedBy = $_.CorroboratedBy; dialogTitle = $(if ($null -ne $_.Dialog -and -not (Test-TcModalScanIncomplete $_.Dialog)) { $_.Dialog.Title } else { $null }); dialogScanComplete = (-not (Test-TcModalScanIncomplete $_.Dialog)) } })
                    candidates        = @($candidates | ForEach-Object { [PSCustomObject]@{ progId = $_.progId; solution = $_.solution; pid = $_.pid } })
                    connectSec        = [math]::Round($swTotal.Elapsed.TotalSeconds, 1)
                }
                if (-not $attach) {
                    $weakText = if ($null -ne $hitDialog) { "shows the modal dialog '$($hitDialog.Title)'" }
                    elseif ($hitScanIncomplete) { 'rejects every DTE call (RPC_E_CALL_REJECTED) and the modal-dialog scan did not complete (unknown whether a dialog is up)' }
                    else { 'rejects every DTE call (RPC_E_CALL_REJECTED) and no modal dialog was found' }
                    # #127 F2: same dialog shape as the strong path (New-TcModalDialogResult)
                    if ($null -ne $hitDialog) { $blockedData = Add-TcModalDialogData -Dialog $hitDialog -Data $blockedData }
                    else { $blockedData | Add-Member -NotePropertyName 'dialog' -NotePropertyValue $null }
                    if ($hitScanIncomplete) {
                        $blockedData | Add-Member -NotePropertyName 'scanComplete' -NotePropertyValue $false
                        $blockedData | Add-Member -NotePropertyName 'modalScan' -NotePropertyValue (ConvertTo-TcModalScanInfo -Scan $hit.Dialog)
                    }
                    $weakCode = if ($null -ne $hitDialog) { 'IDE_MODAL_DIALOG' } elseif ($hitScanIncomplete) { 'MODAL_SCAN_INCOMPLETE' } else { 'IDE_BUSY' }
                    $weakHint = Get-TcErrorHint -Code $(if ($blockedData.launchedBySession) { 'IDE_BLOCKED_OWN' } else { 'IDE_BLOCKED_SAME_NAME' })
                    if ($hitScanIncomplete) { $weakHint = ([string]$script:TcHintFragments['IDE_BLOCKED_SCAN_INCOMPLETE']).Replace('<pid>', [string]$blockedPid) + $weakHint }
                    return New-TcResult -Success $false `
                        -ErrorMessage "IDE_BLOCKED_SAME_NAME (weak / ambiguous evidence): the IDE pid $blockedPid $evidence and $weakText. No second IDE was launched and nothing was attached." `
                        -ErrorCode $weakCode -Hint $weakHint -Data $blockedData
                }
                # attached: a dialog -> IDE_MODAL_DIALOG, an incomplete scan -> MODAL_SCAN_INCOMPLETE (#42)
                if ($null -ne $hit.Dialog) {
                    return New-TcModalDialogResult -Dialog $hit.Dialog -Operation "Connect-TcIde -SolutionPath (IDE pid $blockedPid $evidence; no second IDE launched)" -Data $blockedData
                }
                return New-TcResult -Success $false `
                    -ErrorMessage "IDE_BUSY: the IDE pid $blockedPid $evidence, but it rejects every DTE call (RPC_E_CALL_REJECTED 0x80010001 after 3 attempts) and no modal dialog was found. No second IDE was launched." `
                    -ErrorCode 'IDE_BUSY' -Hint (Get-TcErrorHint -Code 'IDE_BUSY') -Data $blockedData
            }
        }
    }

    # --- Fallback: try GetActiveObject for specific ProgIDs (if ROT enumeration returned nothing) ---
    if ($null -eq $dte -and $rotEntries.Count -eq 0) {
        foreach ($candidateProgId in $progIds) {
            $candidateObj = Get-ComObject -ProgId $candidateProgId
            if ($null -ne $candidateObj) {
                $dte = $candidateObj
                $usedProgId = $candidateProgId
                $selectionReason = 'get-active-object'
                $progIdSelectedBy = if (-not [string]::IsNullOrWhiteSpace($ProgId)) { 'explicit' } else { 'running-instance' }
                Write-Verbose "Fallback: found IDE via GetActiveObject ($candidateProgId)"
                break
            }
        }
    }

    # --- Strategy 4: Launch new instance if not found ---
    if ($null -eq $dte) {
        if ($NoLaunch) {
            return New-TcResult -Success $false -ErrorMessage 'No running TwinCAT IDE instance found.' -ErrorCode 'IDE_NOT_FOUND' `
                -Data ([PSCustomObject]@{ candidates = @($candidates | Select-Object progId, solution, pid) })
        }

        # #72: -ProgId, else the IDE of the TwinCAT build the solution's .tsproj was saved with
        # (TcVersion), else the only registered IDE; otherwise nothing is launched (never the
        # first registered ProgID: that opened 4026 solutions in the 4024 XAE).
        $pick = Resolve-TcLaunchProgId -ProgId $ProgId -SolutionPath $normalizedSolutionPath
        $progIdEvidence = $pick.evidence
        if ($null -ne $pick.errorCode) {
            $pickData = [PSCustomObject]@{
                registeredProgIds = @($pick.registered)
                solutionVersion   = $pick.evidence
                candidates        = @($candidates | ForEach-Object { [PSCustomObject]@{ progId = $_.progId; solution = $_.solution; pid = $_.pid } })
            }
            return New-TcResult -Success $false -ErrorMessage $pick.errorMessage -ErrorCode $pick.errorCode `
                -Hint (Get-TcErrorHint -Code $pick.errorCode) -Data $pickData
        }
        $launchProgId = $pick.progId
        $progIdSelectedBy = $pick.selectedBy

        # Launch. Right after CreateInstance the DTE is not usable yet: touching
        # MainWindow.Visible at that point fails with "property 'Visible' cannot be
        # found" and leaves an orphan IDE. Poll until Version + Solution are readable
        # (500 ms, max 60 s), then set UserControl so the IDE stays visible and does
        # not close when the COM reference is released.
        $swLaunch = [System.Diagnostics.Stopwatch]::StartNew()
        $launchTime = [DateTime]::Now
        try {
            Write-Verbose "Launching IDE via ProgID $launchProgId"
            $dte = New-TcIdeInstance -ProgId $launchProgId
        }
        catch {
            return New-TcResult -Success $false -ErrorMessage "Failed to launch TwinCAT IDE ($launchProgId): $($_.Exception.Message)" `
                -ErrorCode 'IDE_LAUNCH_FAILED' -Hint (Get-TcErrorHint -Code 'IDE_LAUNCH_FAILED')
        }

        $launchTimeoutSec = 60
        $launchDeadline = [DateTime]::Now.AddSeconds($launchTimeoutSec)
        $launchReady = $false
        $lastLaunchError = ''
        while ([DateTime]::Now -lt $launchDeadline) {
            try {
                $launchReady = [bool](Invoke-TcComRetry -MaxRetries 1 -OperationName 'IDE launch poll' -ScriptBlock {
                    $v = [string]$dte.Version
                    (-not [string]::IsNullOrWhiteSpace($v)) -and ($null -ne $dte.Solution)
                })
            }
            catch {
                # busy, "property not found", RPC not ready ... all mean "not yet"
                $launchReady = $false
                $lastLaunchError = $_.Exception.Message
            }
            if ($launchReady) { break }
            Start-Sleep -Milliseconds 500
        }

        if (-not $launchReady) {
            $killed = @(Stop-TcLaunchedIde -Dte $dte -ProgId $launchProgId -StartedAfter $launchTime)
            $dte = $null
            $killedNote = if ($killed.Count -gt 0) { " Orphan process(es) stopped: $($killed -join ', ')." } else { '' }
            return New-TcResult -Success $false `
                -ErrorMessage "TwinCAT IDE ($launchProgId) was launched but DTE did not become ready within $launchTimeoutSec s (last error: $lastLaunchError).$killedNote" `
                -ErrorCode 'IDE_LAUNCH_FAILED' -Hint (Get-TcErrorHint -Code 'IDE_LAUNCH_FAILED')
        }

        $launchSec = [math]::Round($swLaunch.Elapsed.TotalSeconds, 1)
        try { $dte.UserControl = $true } catch { Write-Verbose "DTE.UserControl could not be set ($($_.Exception.Message))" }
        try { $dte.SuppressUI = $false } catch { }
        $usedProgId = $launchProgId
        $selectionReason = 'launched'
        # #147 M2: the pid of the launched IDE comes from the ROT entry whose object IS this DTE
        # (moniker '!<ProgId>:<pid>'), polled briefly; Get-TcIdeProcessId below may confirm it via
        # the DTE's own main window instead. A pid only guessed from the start time is never owned.
        $rotDeadline = [DateTime]::Now.AddSeconds($script:TcLaunchRotWaitSec)
        while ($true) {
            $rotHit = Find-TcRotEntryForDte -Dte $dte
            if ($null -ne $rotHit -and [int]$rotHit['ProcessId'] -gt 0) {
                $chosen = [PSCustomObject]@{ pid = [int]$rotHit['ProcessId']; progId = $launchProgId; solution = '' }
                break
            }
            if ([DateTime]::Now -ge $rotDeadline) { break }
            Start-Sleep -Milliseconds 500
        }
    }

    if ([string]::IsNullOrWhiteSpace($usedProgId)) {
        $usedProgId = try { [string]$dte.RegistryRoot } catch { 'DTE' }
    }

    # Store in module scope
    $script:TcDte = $dte
    $script:TcProgId = $usedProgId
    $script:TcIdeConnected = $true
    $script:TcLastModalDialog = $null
    # Who chose this instance; Disconnect-TcIde -Quit -Kill only kills an IDE this session launched.
    $script:TcIdeSelectedBy = $selectionReason

    # IDE process id + main window handle (for Find-TcIdeModalDialog / the COM watchdog)
    $knownPid = 0
    if ($null -ne $chosen -and $null -ne $chosen.pid) { try { $knownPid = [int]$chosen.pid } catch { $knownPid = 0 } }
    $ideInfo = Get-TcIdeProcessId -Dte $dte -ProgId $usedProgId -KnownPid $knownPid -StartedAfter $launchTime
    $script:TcIdeProcessId = if ($ideInfo.ProcessId -gt 0) { [int]$ideInfo.ProcessId } else { $null }
    $script:TcIdeMainHwnd = [long]$ideInfo.MainHwnd
    $ideProcessId = if ($null -ne $script:TcIdeProcessId) { $script:TcIdeProcessId } else { 0 }
    # 'rot-identity' (ROT entry of this very DTE), 'main-window' (DTE.MainWindow.HWnd), 'known-pid',
    # 'start-time' (a guess: the youngest IDE process started since the launch)
    $pidSource = if ($selectionReason -eq 'launched' -and $null -ne $chosen -and $ideInfo.Source -eq 'known-pid') { 'rot-identity' } else { [string]$ideInfo.Source }
    if ($selectionReason -eq 'launched') {
        $launchId = [guid]::NewGuid().ToString('N')
        if ($ideProcessId -gt 0 -and $pidSource -in 'rot-identity', 'main-window') {
            Add-TcLaunchedIde -ProcessId $ideProcessId
            # #136: remembered with the solution it was launched for (Find-TcSessionLaunchedIde)
            if ($null -ne $normalizedSolutionPath) { $null = Register-TcSessionLaunch -Solution $normalizedSolutionPath -ProgId $usedProgId -Dte $dte -ProcessId $ideProcessId -LaunchTime $launchTime -LaunchId $launchId }
            # #73 / #149: persisted, so a restarted bridge / ReloadModule still owns it
            $null = Save-TcLaunchRecord -LaunchId $launchId -ProcessId $ideProcessId -PidSource $pidSource -ProgId $usedProgId -Solution $normalizedSolutionPath -LaunchTime $launchTime
        }
        else {
            # #147 M2: the pid could only be guessed (or not found at all): it might be the user's
            # IDE that came up at the same time. Nothing is owned or attached; the DTE object is kept
            # in the launch record so a retry recognises the IDE once the ROT lists it.
            if ($null -ne $normalizedSolutionPath) {
                $null = Register-TcSessionLaunch -Solution $normalizedSolutionPath -ProgId $usedProgId -Dte $dte -ProcessId 0 -LaunchTime $launchTime -LaunchId $launchId
                # #149: persisted as 'pid-unconfirmed' (guessed pid): after a bridge restart it only
                # keeps a second IDE from being launched for this .sln, it never makes an IDE owned
                $null = Save-TcLaunchRecord -LaunchId $launchId -ProcessId $ideProcessId -PidSource 'pid-unconfirmed' -ProgId $usedProgId -Solution $normalizedSolutionPath -LaunchTime $launchTime
            }
            $script:TcDte = $null; $script:TcIdeConnected = $false; $script:TcIdeSelectedBy = $null
            $script:TcIdeProcessId = $null; $script:TcIdeMainHwnd = 0; $script:TcIdeStartTime = $null
            return New-TcResult -Success $false `
                -ErrorMessage "IDE_LAUNCH_PENDING: an IDE ($usedProgId) was launched, but its process id could not be confirmed (no ROT entry with this DTE object, no main window; pid source '$pidSource'). Nothing was attached and the IDE is not treated as owned by this session." `
                -ErrorCode 'IDE_LAUNCH_PENDING' -Hint (([string](Get-TcErrorHint -Code 'IDE_LAUNCH_PENDING')).Replace('<pid>', '<data.ideProcessId>')) `
                -Data ([PSCustomObject]@{
                    ideProcessId      = 0
                    guessedProcessId  = $ideProcessId
                    pidConfirmed      = $false
                    pidSource         = $pidSource
                    progId            = $usedProgId
                    progIdSelectedBy  = $progIdSelectedBy
                    probe             = 'pid-unconfirmed'
                    launchedBySession = $true
                    ownedBySession    = $false
                    attached          = $false
                    launched          = $true
                    solution          = $normalizedSolutionPath
                    connectSec        = [math]::Round($swTotal.Elapsed.TotalSeconds, 1)
                    launchRecordWarning = $script:TcLaunchRecordWarning
                })
        }
    }
    if ($ideProcessId -gt 0 -and (Test-TcLaunchedIde -ProcessId $ideProcessId)) { $script:TcIdeSelectedBy = 'launched' }
    # Start time of that process: Disconnect-TcIde -Kill compares it so a recycled pid is never killed.
    $script:TcIdeStartTime = $null
    if ($ideProcessId -gt 0) { try { $script:TcIdeStartTime = (Get-Process -Id $ideProcessId -ErrorAction Stop).StartTime } catch { $script:TcIdeStartTime = $null } }
    Write-Verbose "IDE process id $ideProcessId, main HWND $($ideInfo.MainHwnd)"

    $candidateSummary = @($candidates | ForEach-Object { [PSCustomObject]@{ progId = $_.progId; solution = $_.solution; pid = $_.pid } })
    # PR #209 review M2: data of every failed -TakeOverOrphan exit after the attach (the attach is
    # released there: nothing attached / taken over), with the same reloadPromptAttempts /
    # resetRequired / stateWarning fields as the exits in Resolve-TcOrphanTakeover; $null without
    # -TakeOverOrphan (those exits keep their data). -Data: extra fields to start from.
    $orphanFailData = {
        param([object]$Data)
        if ($null -eq $orphan) { return $Data }
        if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
        foreach ($kv in @(@('takenOver', $false), @('attached', $false), @('ownedBySession', $false), @('ideProcessId', [int]$orphan.Candidate.pid), @('launchId', [string]$orphan.Record.launchId), @('otherSession', $orphan.OtherSession))) {
            $Data | Add-Member -NotePropertyName $kv[0] -NotePropertyValue $kv[1] -Force
        }
        Add-TcOrphanResetData -Data $Data -Prompts @($orphan.ReloadPrompts) -SolutionPath $normalizedSolutionPath -StateWarning ([string]$orphan.ResetRequiredWarning)
    }

    # A modal dialog (Assertion Failed, VS account settings, fatal error ...) blocks every
    # DTE call forever (no RPC_E_CALL_REJECTED), so check before Solution.Open / project scan.
    $dialog = Find-TcIdeModalDialog
    if ($null -ne $dialog) {
        $dlgData = [PSCustomObject]@{ progId = $usedProgId; progIdSelectedBy = $progIdSelectedBy; selectedBy = $selectionReason; ownedBySession = ($script:TcIdeSelectedBy -eq 'launched'); ideProcessId = $ideProcessId; candidates = $candidateSummary; launchRecordWarning = $script:TcLaunchRecordWarning; takenOver = $false; previousOwner = $null }
        if ($null -ne $orphan) {
            # #196 review: nothing stays attached. PR #209 review M2: so the hint must not send the caller
            # to Reset-TcSolution (IDE_MODAL_DIALOG_RELOAD -> NOT_CONNECTED, the #201 dead end)
            Reset-TcOrphanTakeoverAttach
            return New-TcModalDialogResult -Dialog $dialog -Operation "Connect-TcIde -TakeOverOrphan (IDE pid $ideProcessId; dialog after the attach, attach released, not taken over)" `
                -HintCode 'IDE_MODAL_DIALOG_ORPHAN' -Data (& $orphanFailData $dlgData)
        }
        return New-TcModalDialogResult -Dialog $dialog -Operation 'Connect-TcIde (Solution.Open / project scan)' -Data $dlgData
    }

    # Automation Interface silent mode: ITcAutomationSettings.SilentMode = true makes XAE answer
    # its own message boxes with the default button instead of blocking. Verified 2026-10-19 on
    # TwinCAT 3.1.4024 (32-bit XAE): with SilentMode the "Application 'Port_851' does not exist on
    # device ... create it and proceed with download?" prompt of Login(1) is answered Yes and the
    # program is downloaded to an empty runtime; without it Login blocks forever.
    # Done after the pid is known (COM watchdog / crash detection) and the modal check passed.
    # The original value is kept so Disconnect-TcIde (without -Quit) can restore it.
    $silentMode = $false
    $script:TcSilentModeOriginal = $null
    try {
        $settings = Invoke-TcComRetry -OperationName 'GetObject TcAutomationSettings' -ScriptBlock { Write-Output -NoEnumerate $dte.GetObject('TcAutomationSettings') }
        if ($null -ne $settings) {
            # The original is read once per IDE process: on a later connect the IDE already shows
            # the SilentMode = true we set, so the remembered value is used instead.
            # An original that could not be read is remembered as 'unknown': after we set true,
            # a later read would wrongly take that true for the original (then nothing is restored).
            $silentOriginal = Get-TcIdeSilentOriginal -ProcessId $ideProcessId
            if ($silentOriginal -is [string]) { $silentOriginal = $null }   # 'unknown'
            elseif ($null -eq $silentOriginal) {
                try { $silentOriginal = [bool](Invoke-TcComRetry -OperationName 'SilentMode read (original)' -ScriptBlock { $settings.SilentMode }) }
                catch { $silentOriginal = $null; Write-Verbose "SilentMode original value unreadable ($($_.Exception.Message))" }
                if ($ideProcessId -gt 0) { Set-TcIdeSilentOriginal -ProcessId $ideProcessId -Value $(if ($null -eq $silentOriginal) { 'unknown' } else { $silentOriginal }) }
            }
            $script:TcSilentModeOriginal = $silentOriginal
            Invoke-TcComRetry -OperationName 'SilentMode' -ScriptBlock { $settings.SilentMode = $true } | Out-Null
            $script:TcAutomationSettings = $settings
            $silentMode = [bool](Invoke-TcComRetry -OperationName 'SilentMode read' -ScriptBlock { $settings.SilentMode })
        }
    }
    catch {
        Write-Verbose "TcAutomationSettings.SilentMode could not be enabled ($($_.Exception.Message))"
    }
    $script:TcSilentMode = $silentMode

    # --- Auto-open solution if -SolutionPath specified and not already open ---
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        $currentSln = try { [string]$dte.Solution.FullName } catch { '' }
        $currentNormalized = if ([string]::IsNullOrWhiteSpace($currentSln)) { '' } else { try { Get-TcLongPath $currentSln } catch { $currentSln } }
        if (-not [string]::Equals($currentNormalized, $normalizedSolutionPath, [StringComparison]::OrdinalIgnoreCase)) {
            try {
                Write-Verbose "Opening solution: $SolutionPath"
                Invoke-TcComRetry -OperationName 'Solution.Open' -ScriptBlock { $dte.Solution.Open($normalizedSolutionPath) } | Out-Null
            }
            catch {
                if ($null -ne $orphan) { Reset-TcOrphanTakeoverAttach }   # #196 review: nothing stays attached
                return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_OPEN_FAILED' -MessagePrefix 'Failed to open solution' -Data (& $orphanFailData $null)
            }

            # Poll until the solution is open and has projects (max 60 s, 500 ms interval).
            # The DTE frequently answers RPC_E_CALL_REJECTED while a large solution is
            # loading, so each poll iteration is a single attempt: a busy answer just
            # means "not ready yet" and the loop continues; only the overall deadline
            # ends the wait. Any other COM error aborts immediately.
            $openTimeoutSec = 60
            $openDeadline = [DateTime]::Now.AddSeconds($openTimeoutSec)
            $solutionReady = $false
            $busyPolls = 0
            while ([DateTime]::Now -lt $openDeadline) {
                try {
                    $solutionReady = [bool](Invoke-TcComRetry -MaxRetries 1 -OperationName 'Solution load poll' -ScriptBlock {
                        [bool]($dte.Solution.IsOpen -and $dte.Solution.Projects.Count -gt 0)
                    })
                }
                catch {
                    $mappedPoll = ConvertTo-TcAdsErrorCode -InputObject $_
                    if ($null -ne $mappedPoll -and $mappedPoll.Code -eq 'IDE_BUSY') {
                        $busyPolls++
                        Write-Verbose "Solution load poll: IDE busy ($busyPolls), still waiting..."
                        $solutionReady = $false
                    }
                    else {
                        if ($null -ne $orphan) { Reset-TcOrphanTakeoverAttach }   # #196 review: nothing stays attached
                        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_OPEN_FAILED' -MessagePrefix 'Solution did not become ready' -Data (& $orphanFailData $null)
                    }
                }
                if ($solutionReady) { break }
                Start-Sleep -Milliseconds 500
            }

            if (-not $solutionReady) {
                if ($null -ne $orphan) { Reset-TcOrphanTakeoverAttach }   # #196 review: nothing stays attached
                return New-TcResult -Success $false `
                    -ErrorMessage "Solution '$SolutionPath' did not finish loading within $openTimeoutSec s (Solution.IsOpen / Projects.Count never became ready; IDE busy on $busyPolls poll(s))." `
                    -ErrorCode 'PROJECT_OPEN_TIMEOUT' `
                    -Hint (Get-TcErrorHint -Code 'PROJECT_OPEN_TIMEOUT') -Data (& $orphanFailData $null)
            }
            # The IDE has this solution open from now on: record it right away (#29), so a later
            # Connect-TcIde recognises it even if the steps below fail or a dialog comes up.
            if ($ideProcessId -gt 0) { Save-TcIdeSolutionRecord -ProcessId $ideProcessId -Solution $normalizedSolutionPath }
        }
    }

    # Try to obtain ITcSysManager (force refresh after potential solution open).
    # Right after Solution.Open the project objects can still be $null for a few
    # seconds, so retry up to 10 x 1 s whenever a solution with projects is loaded.
    $script:TcSysManager = $null
    $sysManagerAvailable = $false
    $hasProjects = $false
    try { $hasProjects = [bool]($dte.Solution.Projects.Count -gt 0) } catch { $hasProjects = $false }
    $smAttempts = if ($hasProjects -or -not [string]::IsNullOrWhiteSpace($SolutionPath)) { 10 } else { 1 }
    for ($smTry = 1; $smTry -le $smAttempts; $smTry++) {
        $smProbe = $null
        try { $smProbe = Get-TcSysManager -Refresh }
        catch {
            if ($_.Exception.Message -match 'IDE_CRASHED') {
                if ($null -ne $orphan) { Reset-TcOrphanTakeoverAttach }   # #196 review: nothing stays attached
                return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'IDE_CRASHED' -MessagePrefix 'Connect-TcIde (ITcSysManager scan)' -Data (& $orphanFailData $null)
            }
            $smProbe = $null
        }
        if ($null -ne $smProbe) {
            $sysManagerAvailable = $true
            break
        }
        if ($smTry -lt $smAttempts) {
            Write-Verbose "ITcSysManager not available yet (attempt $smTry/$smAttempts), retrying in 1 s..."
            Start-Sleep -Seconds 1
        }
    }

    # Right after Solution.Open / the project scan the DTE occasionally answers $null for Version
    # and Solution.FullName although the solution is loaded (multi-ide.ps1 saw solution = null
    # 128 ms before a ROT read of the same instance returned the path). Retry briefly; when the
    # solution was opened / matched by -SolutionPath it is reported as that path.
    $ideVersion = ''
    $ideSolution = ''
    for ($readTry = 1; $readTry -le 3; $readTry++) {
        try { $ideVersion = [string]$dte.Version } catch { $ideVersion = '' }
        try { $ideSolution = [string]$dte.Solution.FullName } catch { $ideSolution = '' }
        if (-not [string]::IsNullOrWhiteSpace($ideVersion) -and -not [string]::IsNullOrWhiteSpace($ideSolution)) { break }
        if ($readTry -lt 3) { Start-Sleep -Milliseconds 300 }
    }
    if ([string]::IsNullOrWhiteSpace($ideVersion)) { $ideVersion = 'unknown' }
    if ([string]::IsNullOrWhiteSpace($ideSolution) -and -not [string]::IsNullOrWhiteSpace($SolutionPath)) { $ideSolution = $normalizedSolutionPath }

    # Remembered for Reset-TcSolution (Solution.Close + reopen); only a solution that is really open.
    if (-not [string]::IsNullOrWhiteSpace($ideSolution)) {
        $script:TcSolutionPath = try { Get-TcLongPath ([string]$ideSolution) } catch { [string]$ideSolution }
        # Remembered across processes: a later Connect-TcIde can recognise this IDE while a modal
        # dialog blocks its DTE (#29, Find-TcBlockedSolutionIde 'session-record').
        if ($ideProcessId -gt 0) { Save-TcIdeSolutionRecord -ProcessId $ideProcessId -Solution $script:TcSolutionPath }
    }

    # #196 review M2: -TakeOverOrphan writes the new owner only now - attach, modal check and project
    # scan have passed. A refusal / failed write releases the connection (nothing attached or owned).
    if ($null -ne $orphan) {
        $oc = $orphan.Candidate
        $tk = Set-TcLaunchRecordTakeover -Record $orphan.Record -Reason 'orphan-takeover'
        if ($null -ne $tk.Failure -or -not $tk.TakenOver) {
            Reset-TcOrphanTakeoverAttach
            $tkData = & $orphanFailData ([PSCustomObject]@{
                takenOver = $false; attached = $false; ownedBySession = $false; launched = $false; solution = $normalizedSolutionPath
                ideProcessId = [int]$oc.pid; launchId = [string]$orphan.Record.launchId; otherSession = $orphan.OtherSession
                candidates = $candidateSummary
            })
            if ($null -ne $tk.Failure) {
                $tkData | Add-Member -NotePropertyName 'reason' -NotePropertyValue 'launch-record-write-failed'
                $tkData | Add-Member -NotePropertyName 'launchRecordWarning' -NotePropertyValue $tk.Failure
                return New-TcResult -Success $false `
                    -ErrorMessage "LAUNCH_RECORD_UNAVAILABLE: the takeover of IDE pid $($oc.pid) could not be written to the launch records ($($tk.Failure)); nothing was attached or taken over." `
                    -ErrorCode 'LAUNCH_RECORD_UNAVAILABLE' -Hint (Get-TcErrorHint -Code 'LAUNCH_RECORD_UNAVAILABLE') -Data $tkData
            }
            $tkData | Add-Member -NotePropertyName 'reason' -NotePropertyValue ([string]$tk.Refusal)
            return New-TcResult -Success $false `
                -ErrorMessage "ORPHAN_TAKEOVER_REFUSED ($($tk.Refusal)): the launch record of IDE pid $($oc.pid) changed, or its host / owner process is no longer gone, when it was rewritten. No launch record was changed (the IDE's SilentMode stays true)." `
                -ErrorCode 'ORPHAN_TAKEOVER_REFUSED' -Hint (Get-TcErrorHint -Code 'ORPHAN_TAKEOVER_REFUSED') -Data $tkData
        }
        $takeover = $tk.Previous
        Add-TcLaunchedIde -ProcessId ([int]$oc.pid)
        $null = Register-TcSessionLaunch -Solution $normalizedSolutionPath -ProgId ([string]$orphan.Record.progId) -Dte $oc.Object -ProcessId ([int]$oc.pid) -LaunchId ([string]$orphan.Record.launchId) -Restored
        $script:TcIdeSelectedBy = 'launched'
        Write-Verbose "Took over IDE pid $($oc.pid) for '$normalizedSolutionPath' from the ended TcAuto session (host pid $($takeover.hostPid)) (#196)"
    }

    $data = [PSCustomObject]@{
        progId              = $usedProgId
        progIdSelectedBy    = $progIdSelectedBy
        version             = $ideVersion
        solution            = $ideSolution
        sysManagerAvailable = $sysManagerAvailable
        selectedBy          = $selectionReason
        ownedBySession      = ($script:TcIdeSelectedBy -eq 'launched')
        ideProcessId        = $ideProcessId
        pidSource           = $pidSource
        silentMode          = $script:TcSilentMode
        candidates          = $candidateSummary
    }
    # #123: the session record could not be updated (lock busy): say so, the old one is not used
    $recWarn = if ($ideProcessId -gt 0) { Get-TcIdeSolutionRecordWarning -ProcessId $ideProcessId } else { $null }
    if ($null -ne $recWarn) { $data | Add-Member -NotePropertyName 'sessionRecordWarning' -NotePropertyValue $recWarn }
    # #73: the launch record file could not be read / written during this call (ownership may not survive a bridge restart)
    if ($null -ne $script:TcLaunchRecordWarning) { $data | Add-Member -NotePropertyName 'launchRecordWarning' -NotePropertyValue $script:TcLaunchRecordWarning }
    # #196: -TakeOverOrphan took the IDE over from an ended TcAuto session
    if ($null -ne $takeover) {
        $data | Add-Member -NotePropertyName 'takenOver' -NotePropertyValue $true
        $data | Add-Member -NotePropertyName 'previousOwner' -NotePropertyValue $takeover
        # #201: reload prompts of the orphan were answered without reloading: the IDE still has the
        # old in-memory state while the files on disk changed. PR #209 review M2 / m4: the
        # reset-required record is persistent, so a takeover that is retried after a failure (the
        # prompt answered by the earlier call) still reports it (data.resetRequired: the field that
        # says "answered"; data.reloadPromptAttempts lists this call's attempts only)
        $data = Add-TcOrphanResetData -Data $data -Prompts @($orphan.ReloadPrompts) -SolutionPath $normalizedSolutionPath -StateWarning ([string]$orphan.ResetRequiredWarning)
        # PR #209 review M1: the ended session may have left unsaved editor content in the IDE; the
        # Reset-TcSolution that loads the disk state closes every document WITHOUT saving
        # (Documents.CloseAll(vsSaveChangesNo)), so they are listed here and Reset-TcSolution refuses
        # while any exists (PROJECT_UNSAVED_CHANGES) unless -DiscardProjectChanges. Read after the
        # modal check above passed; a read failure never fails the takeover (dirtyDocumentsError).
        $dirty = Get-TcDirtyDocuments -Dte $oc.Object
        if ($null -ne $dirty.Error) { $data | Add-Member -NotePropertyName 'dirtyDocumentsError' -NotePropertyValue $dirty.Error }
        else { $data | Add-Member -NotePropertyName 'dirtyDocuments' -NotePropertyValue @($dirty.Documents) }
        if ($null -ne $data.PSObject.Properties['resetRequired']) {
            $data | Add-Member -NotePropertyName 'diskChangesNotLoaded' -NotePropertyValue $true
            $data | Add-Member -NotePropertyName 'nextStep' -NotePropertyValue 'A reload prompt of the taken-over IDE was answered without reloading (data.resetRequired, now or by an earlier takeover attempt; data.reloadPromptAttempts lists the attempts of this call only): the IDE keeps its in-memory solution while files on disk changed. Build-TcProject, Enable-TcConfig, PLC login, boot project, library save and every project-file save refuse with RESET_REQUIRED until Reset-TcSolution (MCP: ResetSolution, without -SaveProjectChanges) reopened the solution from disk; or quit the IDE with Disconnect-TcIde -Quit (-Kill) if it is no longer needed. Reset-TcSolution closes every document without saving: while data.dirtyDocuments is not empty (or data.dirtyDocumentsError is set) it refuses with PROJECT_UNSAVED_CHANGES; have the user look at those documents in XAE first, then -DiscardProjectChanges.'
        }
    }
    if ($selectionReason -eq 'launched' -and $null -ne $launchSec) {
        $data | Add-Member -NotePropertyName 'launchSec' -NotePropertyValue $launchSec
    }
    # #72: what the launched ProgID was derived from (.tsproj TcVersion per project, .sln VisualStudioVersion)
    if ($null -ne $progIdEvidence) { $data | Add-Member -NotePropertyName 'solutionVersion' -NotePropertyValue $progIdEvidence }
    # Active solution platform / configuration ($null when unreadable or no solution).
    $solPlatform = Get-TcSolutionPlatform
    $data | Add-Member -NotePropertyName 'solutionPlatform' -NotePropertyValue $solPlatform.platform
    $data | Add-Member -NotePropertyName 'solutionConfiguration' -NotePropertyValue $solPlatform.configuration
    $data | Add-Member -NotePropertyName 'projectPlatform' -NotePropertyValue $solPlatform.projectPlatform

    # Add target info if ITcSysManager is available
    if ($sysManagerAvailable) {
        try {
            $amsNetId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $script:TcSysManager.GetTargetNetId() }
            Save-TcIdeTargetNetId $amsNetId
            $data | Add-Member -NotePropertyName 'amsNetId' -NotePropertyValue $amsNetId
        }
        catch { }
    }
    else {
        $nextAction = if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
            "Solution opened but ITcSysManager was not available after $smAttempts attempt(s) - no TwinCAT project found in '$SolutionPath', or the IDE is still loading it. Verify the .sln contains a TwinCAT project, or rerun Connect-TcIde -SolutionPath."
        }
        else {
            'No TwinCAT project loaded. Use Connect-TcIde -SolutionPath "path\to\project.sln" to open a project, or call Open-TcProject.'
        }
        $data | Add-Member -NotePropertyName 'warning' -NotePropertyValue $nextAction
    }

    $data | Add-Member -NotePropertyName 'connectSec' -NotePropertyValue ([math]::Round($swTotal.Elapsed.TotalSeconds, 1))
    New-TcResult -Success $true -Data $data
}
