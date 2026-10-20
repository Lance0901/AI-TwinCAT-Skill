function Connect-TcIde {
    <#
    .SYNOPSIS
        Connects to a running TwinCAT 3 IDE instance via the Running Object Table.
    .DESCRIPTION
        Obtains the EnvDTE and ITcSysManager interfaces. Enumerates every DTE
        registered in the ROT (XAE Shell 15.0 / 17.0 and VS2022 alike) and picks one:
          - with -SolutionPath: the instance that already has that .sln open
            (path compared case-insensitively after normalisation), otherwise an
            instance with no solution open, otherwise the first instance;
          - without -SolutionPath: an instance that has a TwinCAT project loaded,
            otherwise the first instance.
        For every ROT entry DTE.Version and Solution.FullName are read: an instance
        that stays busy (RPC_E_CALL_REJECTED) after a short retry is kept as a
        last-resort candidate (solution '<busy>'); an instance failing with any other
        COM error (dead RPC server 0x800706BA, E_FAIL 0x80004005 - typically an IDE
        that is shutting down) is skipped. Only when no DTE instance is usable a new
        IDE is launched from the first registered ProgID in TcXaeShell.DTE.15.0
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
    .EXAMPLE
        Connect-TcIde
        Connect-TcIde -ProgId "VisualStudio.DTE.17.0"
        Connect-TcIde -SolutionPath "C:\Projects\MyProject.sln"
    .OUTPUTS
        data.progId       ProgID actually used (parsed from the ROT moniker, else DTE.RegistryRoot)
        data.ideProcessId pid of the connected IDE (0 when it could not be determined)
        data.candidates   every DTE instance seen in the ROT: @{ progId; solution; pid }
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$ProgId,

        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [switch]$NoLaunch
    )

    # Forget the pid / HWND of a previous connection: Invoke-TcComRetry checks that pid after an
    # RPC failure, and a stale pid (IDE that has since exited) would turn a busy call against the
    # new instance into a false IDE_CRASHED.
    $script:TcIdeProcessId = $null
    $script:TcIdeMainHwnd = 0

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
            # Strategy 1: instance already running the target solution
            $chosen = $pool | Where-Object {
                $_.normalizedSolution -and ([string]::Equals($_.normalizedSolution, $normalizedSolutionPath, [StringComparison]::OrdinalIgnoreCase))
            } | Select-Object -First 1
            if ($null -ne $chosen) { $selectionReason = 'solution-match' }

            # Strategy 2: instance with no solution open
            if ($null -eq $chosen) {
                $chosen = $pool | Where-Object { [string]::IsNullOrWhiteSpace($_.solution) } | Select-Object -First 1
                if ($null -ne $chosen) { $selectionReason = 'no-solution-open' }
            }
        }
        else {
            # No SolutionPath: prefer an instance that already has a TwinCAT project
            $chosen = $pool | Where-Object { $_.hasTcProject } | Select-Object -First 1
            if ($null -ne $chosen) { $selectionReason = 'twincat-project-loaded' }
        }

        # Strategy 3: first usable instance
        if ($null -eq $chosen) {
            $chosen = $pool | Select-Object -First 1
            $selectionReason = if ($chosen.busy) { 'busy-instance' } else { 'first-instance' }
        }
    }

    if ($null -ne $chosen) {
        $dte = $chosen.Object
        $usedProgId = $chosen.progId
        Write-Verbose "Connected to DTE pid=$($chosen.pid) progId=$usedProgId solution='$($chosen.solution)' ($selectionReason)"
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

    # IDE process id + main window handle (for Get-TcIdeModalDialog / the COM watchdog)
    $knownPid = 0
    if ($null -ne $chosen -and $null -ne $chosen.pid) { try { $knownPid = [int]$chosen.pid } catch { $knownPid = 0 } }
    $ideInfo = Get-TcIdeProcessId -Dte $dte -ProgId $usedProgId -KnownPid $knownPid -StartedAfter $launchTime
    $script:TcIdeProcessId = if ($ideInfo.ProcessId -gt 0) { [int]$ideInfo.ProcessId } else { $null }
    $script:TcIdeMainHwnd = [long]$ideInfo.MainHwnd
    $ideProcessId = if ($null -ne $script:TcIdeProcessId) { $script:TcIdeProcessId } else { 0 }
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

    $ideVersion = try { $dte.Version } catch { 'unknown' }
    $ideSolution = try { $dte.Solution.FullName } catch { '' }

    $data = [PSCustomObject]@{
        progId              = $usedProgId
        version             = $ideVersion
        solution            = $ideSolution
        sysManagerAvailable = $sysManagerAvailable
        selectedBy          = $selectionReason
        ideProcessId        = $ideProcessId
        silentMode          = $script:TcSilentMode
        candidates          = $candidateSummary
    }

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

    New-TcResult -Success $true -Data $data
}
