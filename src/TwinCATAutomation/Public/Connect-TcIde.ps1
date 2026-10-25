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
            'solution-blocked', ITcSysManager $null, data.attached = true) and Get-TcIdeModalDialog
            / Reset-TcSolution work on it right away; a main window title starting with the
            solution name is weak evidence (same-named copies look alike) - nothing is launched
            and nothing is attached (data.attached = false). Either way IDE_MODAL_DIALOG (dialog
            found; data.dialog, ideProcessId, rotDisplayName, windowTitle, matchedBy, probe) or
            IDE_BUSY (no dialog) is returned; after the dialog is closed the same Connect-TcIde
            call connects normally. Every successful connect with a solution writes the session
            record (Save-TcIdeSolutionRecord);
          - without -SolutionPath: an instance that has a TwinCAT project loaded,
            otherwise the first instance (busy ones last).
        For every ROT entry DTE.Version and Solution.FullName are read: an instance
        that stays busy (RPC_E_CALL_REJECTED) after a short retry is kept as a
        last-resort candidate (solution '<busy>', only used without -SolutionPath); an
        instance failing with any other COM error (dead RPC server 0x800706BA, E_FAIL
        0x80004005 - typically an IDE that is shutting down) is skipped. When no DTE
        instance qualifies a new IDE is launched from the first registered ProgID in TcXaeShell.DTE.15.0
        (4024, 32-bit XAE Shell), TcXaeShell.DTE.17.0, VisualStudio.DTE.17.0 (4026 /
        VS2022) - or the single -ProgId given. A launched IDE is polled (500 ms, max
        60 s) until DTE.Version and DTE.Solution are readable, then UserControl is
        set so it stays visible; if it never becomes ready it is quit / killed again
        (no orphan) and IDE_LAUNCH_FAILED is returned.
        When -SolutionPath is specified, the solution is opened automatically after
        connecting and ITcSysManager is obtained in one step (up to 10 x 1 s).
        Before touching the solution the IDE process is checked for a modal dialog
        (Get-TcIdeModalDialog); if one is open IDE_MODAL_DIALOG is returned.
    .PARAMETER ProgId
        COM ProgID to connect to / launch. When given, running instances with this
        ProgID are preferred and only this ProgID is used for launching.
    .PARAMETER SolutionPath
        Path to a .sln file. If specified, the IDE will open this solution
        automatically after connecting (or connect to an instance already
        running this solution).
    .PARAMETER NoLaunch
        If set, do not launch a new IDE instance if none is running.
    .PARAMETER LaunchIfBlocked
        With -SolutionPath: ignore a blocked IDE that matches only by window title
        (matchedBy 'window-title', i.e. a same-named solution that may be someone else's) and
        go on as if it were not there (launch unless -NoLaunch). A blocked IDE recognised by
        strong evidence (module-state, session-record, dialog-path) is still reported.
    .EXAMPLE
        Connect-TcIde
        Connect-TcIde -ProgId "VisualStudio.DTE.17.0"
        Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"
    .OUTPUTS
        data.progId       ProgID actually used (parsed from the ROT moniker, else DTE.RegistryRoot)
        data.ideProcessId pid of the connected IDE (0 when it could not be determined)
        data.candidates   every DTE instance seen in the ROT: @{ progId; solution; pid }
        data.connectSec   seconds the whole call took (every successful path)
        data.solutionPlatform / solutionConfiguration  active solution platform and
                          configuration ($null when unreadable); see Set-TcTarget -Platform
        data.projectPlatform  project platform the .tsproj is built for under the active
                          solution platform (may differ from solutionPlatform, e.g. solution
                          'TwinCAT OS (x64)' -> project 'TwinCAT OS (ARMT2)')
        data.launchSec    seconds from starting a new IDE until its DTE answered (only when selectedBy = 'launched')
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
        [switch]$LaunchIfBlocked
    )

    $swTotal = [System.Diagnostics.Stopwatch]::StartNew()
    $launchSec = $null

    # Forget the pid / HWND of a previous connection: Invoke-TcComRetry checks that pid after an
    # RPC failure, and a stale pid (IDE that has since exited) would turn a busy call against the
    # new instance into a false IDE_CRASHED.
    # An IDE this session launched stays 'owned' (Disconnect-TcIde -Kill) when a later
    # Connect-TcIde (e.g. the Reset-TcSolution reconnect) picks the same process again.
    $ownedLaunchedPid = 0
    if ($script:TcIdeSelectedBy -eq 'launched' -and $null -ne $script:TcIdeProcessId) { try { $ownedLaunchedPid = [int]$script:TcIdeProcessId } catch { $ownedLaunchedPid = 0 } }
    # Also kept for #29: the IDE this module was connected to and its solution
    # (Find-TcBlockedSolutionIde 'module-state': recognises our own blocked IDE without file I/O).
    $previousIdePid = 0
    if ($null -ne $script:TcIdeProcessId) { try { $previousIdePid = [int]$script:TcIdeProcessId } catch { $previousIdePid = 0 } }
    $previousSolution = [string]$script:TcSolutionPath
    $script:TcIdeSelectedBy = $null
    $script:TcIdeProcessId = $null
    $script:TcIdeStartTime = $null
    $script:TcIdeMainHwnd = 0
    $script:TcSolutionPath = $null

    # Validate SolutionPath if provided
    $normalizedSolutionPath = $null
    if (-not [string]::IsNullOrWhiteSpace($SolutionPath)) {
        if (-not (Test-Path $SolutionPath)) {
            return New-TcResult -Success $false -ErrorMessage "Solution file not found: $SolutionPath" -ErrorCode 'FILE_NOT_FOUND'
        }
        $SolutionPath = (Resolve-Path $SolutionPath).Path
        $normalizedSolutionPath = [IO.Path]::GetFullPath($SolutionPath)
    }

    $progIds = @('TcXaeShell.DTE.15.0', 'TcXaeShell.DTE.17.0', 'VisualStudio.DTE.17.0')
    if (-not [string]::IsNullOrWhiteSpace($ProgId)) {
        $progIds = @($ProgId)
    }

    $dte = $null
    $usedProgId = $null
    $selectionReason = $null
    $launchTime = $null

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
            $normalizedSolution = try { [IO.Path]::GetFullPath($solution) } catch { $solution }
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
        Write-Verbose "Connected to DTE pid=$($chosen.pid) progId=$usedProgId solution='$($chosen.solution)' ($selectionReason)"
    }

    # --- #29: the IDE that has -SolutionPath open may be blocked (modal dialog / busy) ---
    # Its DTE answered RPC_E_CALL_REJECTED or an empty Version, so it never matched above.
    # Launching a second IDE for the same .sln (or, with -NoLaunch, answering IDE_NOT_FOUND) would
    # be wrong: identify it without COM (Find-TcBlockedSolutionIde) and report it instead.
    #  - strong evidence (session record of this very process, or a dialog path inside the
    #    solution folder): the blocked instance is ATTACHED (module state points at it,
    #    ITcSysManager stays $null) so that Get-TcIdeModalDialog and Reset-TcSolution can act on
    #    it right away;
    #  - weak evidence (window title = solution name only, could be a same-named copy elsewhere):
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
            $blocked = @(Find-TcBlockedSolutionIde -Candidates $busyPool -SolutionPath $normalizedSolutionPath -PreviousProcessId $previousIdePid -PreviousSolution $previousSolution)
            # -LaunchIfBlocked: the caller knows the title-only match is someone else's IDE.
            if ($LaunchIfBlocked) { $blocked = @($blocked | Where-Object { $_.Strong }) }
            if ($blocked.Count -gt 0) {
                $hit = $blocked[0]
                $bc = $hit.Candidate
                $blockedPid = [int]$bc.pid
                $attach = [bool]$hit.Strong
                if ($attach) {
                    $script:TcDte = $bc.Object
                    $script:TcProgId = $bc.progId
                    $script:TcIdeConnected = $true
                    $script:TcSysManager = $null
                    # SilentMode belongs to the IDE it was set on; the next successful connect sets it again.
                    if ($null -ne $script:TcAutomationSettings) { try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($script:TcAutomationSettings) | Out-Null } catch { } }
                    $script:TcAutomationSettings = $null
                    $script:TcSilentMode = $false
                    $script:TcSilentModeOriginal = $null
                    $script:TcLastModalDialog = $hit.Dialog
                    $script:TcSolutionPath = $normalizedSolutionPath
                    $script:TcIdeProcessId = $blockedPid
                    $script:TcIdeSelectedBy = if ($ownedLaunchedPid -gt 0 -and $blockedPid -eq $ownedLaunchedPid) { 'launched' } else { 'solution-blocked' }
                    $script:TcIdeMainHwnd = 0
                    try { $p = Get-Process -Id $blockedPid -ErrorAction Stop; $script:TcIdeMainHwnd = [long]$p.MainWindowHandle; $script:TcIdeStartTime = $p.StartTime } catch { $script:TcIdeStartTime = $null }
                }

                $evidence = if ($attach) { "has the solution open, matched by $($hit.MatchedBy)" } else { "may have the solution open (window title '$($hit.WindowTitle)' only: could also be a same-named solution in another folder; not attached)" }
                $blockedData = [PSCustomObject]@{
                    progId            = $bc.progId
                    ideProcessId      = $blockedPid
                    rotDisplayName    = $bc.displayName
                    windowTitle       = $hit.WindowTitle
                    matchedBy         = $hit.MatchedBy
                    probe             = $(if ($bc.busy) { 'busy (RPC_E_CALL_REJECTED after 3 attempts)' } else { 'unreadable (DTE.Version empty)' })
                    attached          = $attach
                    ownedBySession    = ($attach -and $script:TcIdeSelectedBy -eq 'launched')
                    launched          = $false
                    solution          = $normalizedSolutionPath
                    blockedCandidates = @($blocked | ForEach-Object { [PSCustomObject]@{ pid = $_.Candidate.pid; progId = $_.Candidate.progId; windowTitle = $_.WindowTitle; matchedBy = $_.MatchedBy; dialogTitle = $(if ($null -ne $_.Dialog) { $_.Dialog.Title } else { $null }) } })
                    candidates        = @($candidates | ForEach-Object { [PSCustomObject]@{ progId = $_.progId; solution = $_.solution; pid = $_.pid } })
                    connectSec        = [math]::Round($swTotal.Elapsed.TotalSeconds, 1)
                }
                if (-not $attach) {
                    $weakText = if ($null -ne $hit.Dialog) { "shows the modal dialog '$($hit.Dialog.Title)'" } else { 'rejects every DTE call (RPC_E_CALL_REJECTED) and no modal dialog was found' }
                    $blockedData | Add-Member -NotePropertyName 'dialog' -NotePropertyValue $hit.Dialog
                    return New-TcResult -Success $false `
                        -ErrorMessage "IDE_BLOCKED_SAME_NAME: the IDE pid $blockedPid $evidence and $weakText. No second IDE was launched and nothing was attached." `
                        -ErrorCode $(if ($null -ne $hit.Dialog) { 'IDE_MODAL_DIALOG' } else { 'IDE_BUSY' }) -Hint (Get-TcErrorHint -Code 'IDE_BLOCKED_SAME_NAME') -Data $blockedData
                }
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

        # First registered ProgID wins (4024: TcXaeShell.DTE.15.0, 4026: VisualStudio.DTE.17.0)
        $launchProgId = $null
        $launchType = $null
        foreach ($candidateProgId in $progIds) {
            $t = try { [Type]::GetTypeFromProgID($candidateProgId) } catch { $null }
            if ($null -ne $t) {
                $launchProgId = $candidateProgId
                $launchType = $t
                break
            }
        }
        if ($null -eq $launchType) {
            return New-TcResult -Success $false `
                -ErrorMessage "TwinCAT 3 XAE is not installed. None of the ProgIDs are registered: $($progIds -join ', '). Install TwinCAT 3 XAE from https://www.beckhoff.com/twincat3/ or pass -ProgId." `
                -ErrorCode 'TWINCAT_NOT_FOUND'
        }

        # Launch. Right after CreateInstance the DTE is not usable yet: touching
        # MainWindow.Visible at that point fails with "property 'Visible' cannot be
        # found" and leaves an orphan IDE. Poll until Version + Solution are readable
        # (500 ms, max 60 s), then set UserControl so the IDE stays visible and does
        # not close when the COM reference is released.
        $swLaunch = [System.Diagnostics.Stopwatch]::StartNew()
        $launchTime = [DateTime]::Now
        try {
            Write-Verbose "Launching IDE via ProgID $launchProgId"
            $dte = [Activator]::CreateInstance($launchType)
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

    # IDE process id + main window handle (for Get-TcIdeModalDialog / the COM watchdog)
    $knownPid = 0
    if ($null -ne $chosen -and $null -ne $chosen.pid) { try { $knownPid = [int]$chosen.pid } catch { $knownPid = 0 } }
    $ideInfo = Get-TcIdeProcessId -Dte $dte -ProgId $usedProgId -KnownPid $knownPid -StartedAfter $launchTime
    $script:TcIdeProcessId = if ($ideInfo.ProcessId -gt 0) { [int]$ideInfo.ProcessId } else { $null }
    $script:TcIdeMainHwnd = [long]$ideInfo.MainHwnd
    $ideProcessId = if ($null -ne $script:TcIdeProcessId) { $script:TcIdeProcessId } else { 0 }
    if ($ownedLaunchedPid -gt 0 -and $ideProcessId -eq $ownedLaunchedPid) { $script:TcIdeSelectedBy = 'launched' }
    # Start time of that process: Disconnect-TcIde -Kill compares it so a recycled pid is never killed.
    $script:TcIdeStartTime = $null
    if ($ideProcessId -gt 0) { try { $script:TcIdeStartTime = (Get-Process -Id $ideProcessId -ErrorAction Stop).StartTime } catch { $script:TcIdeStartTime = $null } }
    Write-Verbose "IDE process id $ideProcessId, main HWND $($ideInfo.MainHwnd)"

    $candidateSummary = @($candidates | ForEach-Object { [PSCustomObject]@{ progId = $_.progId; solution = $_.solution; pid = $_.pid } })

    # A modal dialog (Assertion Failed, VS account settings, fatal error ...) blocks every
    # DTE call forever (no RPC_E_CALL_REJECTED), so check before Solution.Open / project scan.
    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) {
        return New-TcModalDialogResult -Dialog $dialog -Operation 'Connect-TcIde (Solution.Open / project scan)' `
            -Data ([PSCustomObject]@{ progId = $usedProgId; ideProcessId = $ideProcessId; candidates = $candidateSummary })
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
            $silentOriginal = $null
            try { $silentOriginal = [bool](Invoke-TcComRetry -OperationName 'SilentMode read (original)' -ScriptBlock { $settings.SilentMode }) }
            catch { $silentOriginal = $null; Write-Verbose "SilentMode original value unreadable ($($_.Exception.Message))" }
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
        $currentNormalized = if ([string]::IsNullOrWhiteSpace($currentSln)) { '' } else { try { [IO.Path]::GetFullPath($currentSln) } catch { $currentSln } }
        if (-not [string]::Equals($currentNormalized, $normalizedSolutionPath, [StringComparison]::OrdinalIgnoreCase)) {
            try {
                Write-Verbose "Opening solution: $SolutionPath"
                Invoke-TcComRetry -OperationName 'Solution.Open' -ScriptBlock { $dte.Solution.Open($SolutionPath) } | Out-Null
            }
            catch {
                return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_OPEN_FAILED' -MessagePrefix 'Failed to open solution'
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
                        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PROJECT_OPEN_FAILED' -MessagePrefix 'Solution did not become ready'
                    }
                }
                if ($solutionReady) { break }
                Start-Sleep -Milliseconds 500
            }

            if (-not $solutionReady) {
                return New-TcResult -Success $false `
                    -ErrorMessage "Solution '$SolutionPath' did not finish loading within $openTimeoutSec s (Solution.IsOpen / Projects.Count never became ready; IDE busy on $busyPolls poll(s))." `
                    -ErrorCode 'PROJECT_OPEN_TIMEOUT' `
                    -Hint (Get-TcErrorHint -Code 'PROJECT_OPEN_TIMEOUT')
            }
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
                return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'IDE_CRASHED' -MessagePrefix 'Connect-TcIde (ITcSysManager scan)'
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
    if ([string]::IsNullOrWhiteSpace($ideSolution) -and -not [string]::IsNullOrWhiteSpace($SolutionPath)) { $ideSolution = $SolutionPath }

    # Remembered for Reset-TcSolution (Solution.Close + reopen); only a solution that is really open.
    if (-not [string]::IsNullOrWhiteSpace($ideSolution)) {
        $script:TcSolutionPath = try { [IO.Path]::GetFullPath([string]$ideSolution) } catch { [string]$ideSolution }
        # Remembered across processes: a later Connect-TcIde can recognise this IDE while a modal
        # dialog blocks its DTE (#29, Find-TcBlockedSolutionIde 'session-record').
        if ($ideProcessId -gt 0) { Save-TcIdeSolutionRecord -ProcessId $ideProcessId -Solution $script:TcSolutionPath }
    }

    $data = [PSCustomObject]@{
        progId              = $usedProgId
        version             = $ideVersion
        solution            = $ideSolution
        sysManagerAvailable = $sysManagerAvailable
        selectedBy          = $selectionReason
        ownedBySession      = ($script:TcIdeSelectedBy -eq 'launched')
        ideProcessId        = $ideProcessId
        silentMode          = $script:TcSilentMode
        candidates          = $candidateSummary
    }
    if ($selectionReason -eq 'launched' -and $null -ne $launchSec) {
        $data | Add-Member -NotePropertyName 'launchSec' -NotePropertyValue $launchSec
    }
    # Active solution platform / configuration ($null when unreadable or no solution).
    $solPlatform = Get-TcSolutionPlatform
    $data | Add-Member -NotePropertyName 'solutionPlatform' -NotePropertyValue $solPlatform.platform
    $data | Add-Member -NotePropertyName 'solutionConfiguration' -NotePropertyValue $solPlatform.configuration
    $data | Add-Member -NotePropertyName 'projectPlatform' -NotePropertyValue $solPlatform.projectPlatform

    # Add target info if ITcSysManager is available
    if ($sysManagerAvailable) {
        try {
            $amsNetId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $script:TcSysManager.GetTargetNetId() }
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
