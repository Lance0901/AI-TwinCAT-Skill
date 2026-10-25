function Build-TcProject {
    <#
    .SYNOPSIS
        Builds the PLC project and returns build results including the compiler
        messages of the IDE Error List.
    .DESCRIPTION
        Uses DTE SolutionBuild with retry for RPC_E_CALL_REJECTED (IDE busy).
        Includes license check guidance if IDE remains unresponsive.
        Before the build the IDE is checked for a modal dialog (e.g. the XAE
        "Assertion Failed" box that appears after repeatedly opening/closing a
        solution): the build would then never finish, so IDE_MODAL_DIALOG
        is returned instead (data.dialogTitle / dialogText).
        The build is started asynchronously with SolutionBuild.Build($false) and
        SolutionBuild.BuildState (EnvDTE vsBuildState: 1 NotStarted, 2 InProgress,
        3 Done) is polled every ~750 ms. The synchronous Build($true) never returns
        through out-of-process COM in VS2022 (measured 2026-10-21, XAE 4026.22 in VS2022
        Community: VS idle, no modal, call hung 13 min) and a synchronous call cannot
        be aborted; polling works in VS2022 and in the 4024 32-bit TcXaeShell alike.
        While polling, the IDE is checked for a modal dialog every ~5 s: a dialog
        during the build means the build is stuck, so IDE_MODAL_DIALOG is returned.
        When BuildState does not reach Done within -TimeoutSec, BUILD_TIMEOUT is
        returned (data.buildState / buildSec).
        After the build the Error List window is read with Get-TcBuildErrors (UI
        Automation): data.errorItems lists every error shown there (code / description /
        project / file / line / category) and data.errors counts only the code errors (#23).
        Success is decided in this order:
          (a) SolutionBuild.LastBuildInfo (= number of projects that failed to build,
              data.failedProjects) when it could be read: > 0 = BUILD_FAILED;
          (b) otherwise the Error List: any error that is not a "Library Manager" item
              (file not like '*Library Manager', line > 0) = BUILD_FAILED;
          (c) when neither is readable: BUILD_STATUS_UNKNOWN (success = false) - look at
              the XAE Error List yourself before deciding.
    .OUTPUTS
        data.buildSucceeded  $true / $false (the decision above); $null = BUILD_STATUS_UNKNOWN,
                             or LIBRARY_UNRESOLVED (below)
        data.codeVerified    $true when the Error List was read, lists no library error and no
                             code row without a line number, so a successful build also proves
                             the PLC code was compiled; $false otherwise; $null when the Error
                             List is not readable
        data.warningCodes    every warning code of a successful result, in this order:
                             PROJECT_SKIPPED_BY_CONFIGURATION, LIBRARY_UNRESOLVED (only with
                             -AllowUnresolvedLibrary), CODE_NOT_VERIFIED; data.warningCode is the
                             first of them, data.warning its text (Write-Warning for each)

        Unresolved libraries (#45): with library errors in the Error List the PLC code may not
        have been compiled at all. Measured 2026-10-25 (TcXaeShell 4024, TwinCAT_Festo copy with
        7 unresolved libraries): an undeclared identifier gave no C0046 and LastBuildInfo 0, while
        the same edit in a project without missing libraries gave BUILD_FAILED + C0046. So a
        build that would succeed but lists library errors returns LIBRARY_UNRESOLVED (success =
        false, buildSucceeded = $null, codeVerified = $false). -AllowUnresolvedLibrary keeps
        success = true instead, with data.warningCode = LIBRARY_UNRESOLVED (unless
        PROJECT_SKIPPED_BY_CONFIGURATION is already set) and data.libraryWarning; data.projects
        then still says 'built' (the build result), codeVerified = $false says the code is not proven.
        Not verified otherwise (CODE_NOT_VERIFIED): a successful build whose Error List could not be
        read (codeVerified = $null) or lists a code row without a line number (a row the
        category rules do not recognise, e.g. a Library Manager row in another UI language) keeps
        success = true with data.warningCode = CODE_NOT_VERIFIED.
        A successful result also clears the "build required after a platform switch" state that
        Enable-TcConfig checks before activating (BUILD_REQUIRED).
        data.errors          number of CODE errors (errorItems with category 'code'); Library
                             Manager rows are not counted (fallback when the Error List is not
                             readable: failedProjects)
        data.libraryErrors   number of library errors (category 'library'; $null when the Error
                             List is not readable) - missing / unresolved libraries, they do not
                             decide buildSucceeded
        data.libraryErrorItems  errorItems with category 'library'
        data.warnings        warning count (Error List; fallback: warning lines of the build output)
        data.messages        lines of the DTE build output pane (usually empty)
        data.failedProjects  SolutionBuild.LastBuildInfo ($null when it could not be read)
        data.errorItems      [ @{ severity; code; description; project; file; line; column; category } ]
                             all errors of the Error List; category (Get-TcErrorItemCategory):
                             code (has a file), library (file like '*Library Manager' with no
                             line, or "Could not open library" without a line), other (no file)
        data.codeErrors      errorItems with category 'code' - the PLC code errors
        data.warningItems    same shape as errorItems, the warnings of the Error List (@() when it could not be read)
        data.codeWarnings    warningItems without the "Library Manager" items and without the
                             rows that have no file (XAE build-summary rows such as "Project
                             'plc' build ... failed" stay in the Error List as Warning)
        data.errorListError  only when the Error List could not be read (its error code)
        data.buildSec        seconds from Build($false) until BuildState reported Done

        Coverage (#28): a solution Build only builds the projects that have a Build.0 entry
        for the active solution configuration; a PLC project without it is silently skipped
        and XAE still says "Build succeeded". Before the build the active solution
        configuration's SolutionContexts are read through DTE (SolutionBuild.
        ActiveConfiguration.SolutionContexts; SolutionContext.ShouldBuild "whether the
        current project is built when the solution configuration associated with this
        SolutionContext is selected",
        https://learn.microsoft.com/en-us/previous-versions/visualstudio/visual-studio-2013/1a52ztxh(v=vs.120)).
        Every .plcproj context is one entry of data.projects (the .sln text is not parsed):
          status  built    ShouldBuild and the build had no failed project
                  skipped  ShouldBuild = false: not part of the active solution configuration
                  failed   ShouldBuild and the build failed with an Error List row of this project
                  unknown  ShouldBuild, the build failed but no row names this project
        data.skippedProjects (names), data.coverageComplete (every PLC project 'built').
        Skipped projects without -ExpectedProject: success stays as decided above, plus
        data.warningCode = PROJECT_SKIPPED_BY_CONFIGURATION, data.warning and Write-Warning.
        -ExpectedProject <name>: when one of them is skipped the build is not started and
        PROJECT_SKIPPED_BY_CONFIGURATION is returned (success = false); a name that is no
        PLC project of the solution returns EXPECTED_PROJECT_NOT_FOUND; one that ends
        'failed' fails with BUILD_FAILED, one that ends 'unknown' with BUILD_COVERAGE_UNKNOWN.
        When the contexts cannot be read data.coverageError is set, data.coverageComplete =
        $false; with -ExpectedProject that is BUILD_COVERAGE_UNKNOWN.
        Measured 2026-10-21 (4026 + VS2022): SolutionContext.ProjectName is the unique name
        'RobustSolutionFrameworkDemo\FrameworkUnitTest\FrameworkUnitTest.plcproj'; the
        PLC name is its file name without extension.
    .PARAMETER TimeoutSec
        Maximum time in seconds to wait for the build to finish (BuildState = Done);
        BUILD_TIMEOUT after that. Default 600.
    .PARAMETER ExpectedProject
        PLC project name(s) that must take part in the build (e.g. 'FrameworkUnitTest').
        Matched against the .plcproj file name (without extension).
    .PARAMETER AllowUnresolvedLibrary
        Accept a build whose Error List shows unresolved libraries (missing / not installed)
        as success, with data.warningCode = LIBRARY_UNRESOLVED and codeVerified = $false.
        Without it such a build returns LIBRARY_UNRESOLVED (see above).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [ValidateRange(5, 7200)]
        [int]$TimeoutSec = 600,

        [Parameter()]
        [string[]]$ExpectedProject,

        [Parameter()]
        [switch]$AllowUnresolvedLibrary
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    $dialog = Get-TcIdeModalDialog
    if ($null -ne $dialog) {
        return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Build'
    }

    # --- coverage: which PLC projects the active solution configuration builds (#28) ---
    try { $coverage = Get-TcBuildCoverage }
    catch { return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_FAILED' -MessagePrefix 'Build not started (reading SolutionContexts failed)' }
    $expected = @($ExpectedProject | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($expected.Count -gt 0) {
        $covData = [PSCustomObject]@{
            projects              = @($coverage.projects)
            skippedProjects       = @($coverage.projects | Where-Object { $_.status -eq 'skipped' } | ForEach-Object { $_.name })
            coverageComplete      = $false
            expectedProjects      = $expected
            solutionConfiguration = $coverage.configuration
        }
        if ($null -ne $coverage.error) {
            $covData | Add-Member -NotePropertyName 'coverageError' -NotePropertyValue $coverage.error
            return New-TcResult -Success $false -ErrorMessage "Build not started: the project list of the active solution configuration (SolutionContexts) could not be read ($($coverage.error)), so the participation of $($expected -join ', ') cannot be verified." `
                -ErrorCode 'BUILD_COVERAGE_UNKNOWN' -Hint (Get-TcErrorHint -Code 'BUILD_COVERAGE_UNKNOWN') -Data $covData
        }
        $missing = @($expected | Where-Object { $null -eq (Find-TcBuildCoverageEntry -Projects $coverage.projects -Name $_) })
        if ($missing.Count -gt 0) {
            $known = ($coverage.projects | ForEach-Object { $_.name }) -join ', '
            return New-TcResult -Success $false -ErrorMessage "Build not started: expected PLC project(s) $($missing -join ', ') not in the solution (PLC projects: $known)." `
                -ErrorCode 'EXPECTED_PROJECT_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'EXPECTED_PROJECT_NOT_FOUND') -Data $covData
        }
        $skippedExpected = @($expected | Where-Object { (Find-TcBuildCoverageEntry -Projects $coverage.projects -Name $_).status -eq 'skipped' })
        if ($skippedExpected.Count -gt 0) {
            return New-TcResult -Success $false -ErrorMessage "Build not started: expected PLC project(s) $($skippedExpected -join ', ') are not built by the active solution configuration '$($coverage.configuration)' (no Build.0 entry / 'Build' unticked in Configuration Manager); a solution Build would report success without compiling them." `
                -ErrorCode 'PROJECT_SKIPPED_BY_CONFIGURATION' -Hint (Get-TcErrorHint -Code 'PROJECT_SKIPPED_BY_CONFIGURATION') -Data $covData
        }
    }

    try {
        # Entire build operation wrapped in retry for RPC_E_CALL_REJECTED (IDE busy)
        $solutionBuild = $null
        $buildWatch = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $solutionBuild = Invoke-TcComRetry -MaxRetries 5 -OperationName 'SolutionBuild.Build' -TimeoutSec 60 -ScriptBlock {
                $solution = $script:TcDte.Solution
                $sb = $solution.SolutionBuild
                # $false = start the build and return at once; completion is polled below.
                # Build($true) never returns through out-of-process COM in VS2022.
                $sb.Build($false)
                Write-Output -NoEnumerate $sb
            }
        }
        catch {
            $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
            if ($null -ne $mapped -and $mapped.Code -eq 'IDE_BUSY') {
                return New-TcResult -Success $false `
                    -ErrorMessage 'Build failed: IDE is busy or a dialog is blocking. Check for license dialogs — if no valid license, register a 7-day trial at https://www.beckhoff.com/twincat3/' `
                    -ErrorCode 'IDE_BUSY' `
                    -Hint $mapped.Hint
            }
            throw
        }

        # --- wait for the build: poll SolutionBuild.BuildState (vsBuildState 3 = Done) ---
        # Done is only accepted once InProgress (2) / NotStarted (1) was seen or after a 2 s
        # grace period, so a BuildState still left at Done by the previous build is not taken
        # for the end of this one. A modal dialog is looked for every ~5 s.
        $buildState = $null
        $seenNotDone = $false
        $nextModalCheckSec = 5.0
        while ($true) {
            $state = $null
            try { $state = [int]$solutionBuild.BuildState }
            catch {
                # IDE busy / RPC failure: read again through the retry wrapper (busy retry,
                # IDE_CRASHED detection); its exceptions end in the outer catch.
                $state = [int](Invoke-TcComRetry -MaxRetries 3 -OperationName 'SolutionBuild.BuildState' -ScriptBlock { $solutionBuild.BuildState })
            }
            $buildState = $state
            if ($state -ne 3) { $seenNotDone = $true }
            elseif ($seenNotDone -or $buildWatch.Elapsed.TotalSeconds -ge 2) { break }

            if ($buildWatch.Elapsed.TotalSeconds -ge $nextModalCheckSec) {
                $nextModalCheckSec = $buildWatch.Elapsed.TotalSeconds + 5
                $dialog = Get-TcIdeModalDialog
                if ($null -ne $dialog) {
                    return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Build (build in progress, BuildState never reached Done)' `
                        -Data ([PSCustomObject]@{ buildState = $buildState; buildSec = [math]::Round($buildWatch.Elapsed.TotalSeconds, 1) })
                }
            }
            if ($buildWatch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                $dialog = Get-TcIdeModalDialog
                if ($null -ne $dialog) {
                    return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Build (build in progress, BuildState never reached Done)' `
                        -Data ([PSCustomObject]@{ buildState = $buildState; buildSec = [math]::Round($buildWatch.Elapsed.TotalSeconds, 1) })
                }
                return New-TcResult -Success $false `
                    -ErrorMessage "Build did not finish within $TimeoutSec s (SolutionBuild.BuildState = $buildState; 1 NotStarted, 2 InProgress, 3 Done)." `
                    -ErrorCode 'BUILD_TIMEOUT' -Hint (Get-TcErrorHint -Code 'BUILD_TIMEOUT') `
                    -Data ([PSCustomObject]@{ buildState = $buildState; buildSec = [math]::Round($buildWatch.Elapsed.TotalSeconds, 1) })
            }
            Start-Sleep -Milliseconds 750
        }
        $buildSec = [math]::Round($buildWatch.Elapsed.TotalSeconds, 1)
        Write-Verbose "Build-TcProject: BuildState Done after $buildSec s."

        # LastBuildInfo = number of projects that failed to build (NOT the error count).
        # $null when it cannot be read: a failed read must never count as "0 failed".
        $failedProjects = $null
        try { $failedProjects = [int](Invoke-TcComRetry -OperationName 'LastBuildInfo' -ScriptBlock { $solutionBuild.LastBuildInfo }) }
        catch {
            Write-Verbose "Build-TcProject: LastBuildInfo not readable ($($_.Exception.Message)); success will be decided from the Error List."
            $failedProjects = $null
        }

        $buildOutput = ''
        try {
            $buildOutput = Invoke-TcComRetry -MaxRetries 3 -OperationName 'Read build output' -ScriptBlock {
                $text = ''
                $outputWindow = $script:TcDte.ToolWindows.OutputWindow
                $buildPane = $null
                for ($i = 1; $i -le $outputWindow.OutputWindowPanes.Count; $i++) {
                    $pane = $outputWindow.OutputWindowPanes.Item($i)
                    if ($pane.Name -eq 'Build') {
                        $buildPane = $pane
                        break
                    }
                }

                if ($null -ne $buildPane) {
                    $textDoc = $buildPane.TextDocument
                    $editPoint = $textDoc.StartPoint.CreateEditPoint()
                    $text = $editPoint.GetText($textDoc.EndPoint)
                }
                $text
            }
        }
        catch {
            Write-Verbose "Could not read build output: $_"
        }

        $messages = @($buildOutput -split "`n" | Where-Object { $_.Trim() -ne '' })

        # Error List (UI Automation): the PLC compiler does not report through DTE.
        # A build that is known to have succeeded only needs a short look (leftover
        # Library Manager items); a failed / undecided build gets the default timeout.
        $errorCount = if ($null -ne $failedProjects) { $failedProjects } else { 0 }
        $warningCount = @($messages | Where-Object { $_ -match 'warning' }).Count
        $errorItems = @()
        $warningItems = @()
        $errorListError = $null
        $severityUnknown = $false
        $unclassifiedCount = 0
        $el = if ($null -ne $failedProjects -and $failedProjects -eq 0) { Get-TcBuildErrors -IncludeWarnings -TimeoutSec 8 } else { Get-TcBuildErrors -IncludeWarnings }
        if ($el.success) {
            $errorItems = @($el.data.errors)
            if ($null -ne $el.data.counts.errors) { $errorCount = [int]$el.data.counts.errors } else { $errorCount = $errorItems.Count }
            if ($null -ne $el.data.PSObject.Properties['warnings']) { $warningItems = @($el.data.warnings) }
            if ($null -ne $el.data.counts.warnings) { $warningCount = [int]$el.data.counts.warnings }
            elseif ($warningItems.Count -gt 0) { $warningCount = $warningItems.Count }
            if ($null -ne $el.data.PSObject.Properties['severityUnknown']) { $severityUnknown = [bool]$el.data.severityUnknown }
            if ($null -ne $el.data.PSObject.Properties['unclassified']) { $unclassifiedCount = @($el.data.unclassified).Count }
        }
        else {
            $errorListError = [string]$el.error.code
            Write-Verbose "Build-TcProject: Error List not readable ($($el.error.message)); errors falls back to LastBuildInfo."
        }

        # Category per item (#23): "Library Manager" rows are missing / unresolved libraries,
        # not PLC code errors; they stay listed after a successful build and never fail it on
        # their own, so data.errors counts the code errors only.
        foreach ($item in $errorItems) {
            $item | Add-Member -NotePropertyName 'category' -NotePropertyValue (Get-TcErrorItemCategory $item) -Force
        }
        $codeErrors = @($errorItems | Where-Object { $_.category -eq 'code' })
        $libraryErrorItems = @($errorItems | Where-Object { $_.category -eq 'library' })
        # code + other: what the failure summary and the per-project status look at
        $nonLibraryErrors = @($errorItems | Where-Object { $_.category -ne 'library' })
        $libraryErrorCount = $null
        if ($null -eq $errorListError) {
            $errorCount = $codeErrors.Count
            $libraryErrorCount = $libraryErrorItems.Count
        }
        # Warnings: also drop rows without a file (the XAE build-summary row "... build for
        # platform ... failed" is listed as a Warning without project/file/line and survives
        # the next successful build).
        $codeWarnings = @($warningItems | Where-Object { -not (Test-TcLibraryManagerItem $_) -and -not [string]::IsNullOrWhiteSpace([string]$_.file) })

        # --- success decision: (a) LastBuildInfo, (b) Error List, (c) unknown ---
        $buildSucceeded = $null
        $decidedBy = $null
        if ($null -ne $failedProjects) {
            $buildSucceeded = ($failedProjects -eq 0)
            $decidedBy = 'LastBuildInfo'
        }
        elseif ($null -eq $errorListError) {
            $realErrors = @($codeErrors | Where-Object { $null -ne $_.line -and $_.line -gt 0 })
            if ($realErrors.Count -gt 0) {
                $buildSucceeded = $false
                $decidedBy = 'ErrorList'
            }
            elseif ($severityUnknown -and $unclassifiedCount -gt 0) {
                # rows exist but their severity could not be isolated: not decidable
                $buildSucceeded = $null
            }
            else {
                $buildSucceeded = $true
                $decidedBy = 'ErrorList'
            }
        }

        # --- unresolved libraries (#45): a "successful" build may not have compiled the code ---
        # A code row without a line number is not a located compiler message: it may be a
        # library row in a UI language the category rules do not know (zh-TW file name of the
        # Library Manager not measured), so it does not count as proof that the code compiled.
        $unlocatedCode = @($codeErrors | Where-Object { $n = 0; -not ([int]::TryParse(([string]$_.line).Trim(), [ref]$n) -and $n -gt 0) })
        $codeVerified = $null
        if ($null -eq $errorListError) { $codeVerified = ($libraryErrorItems.Count -eq 0) -and ($unlocatedCode.Count -eq 0) }
        $libraryUnresolved = ($buildSucceeded -eq $true) -and ($libraryErrorItems.Count -gt 0)
        $codeNotVerified = ($buildSucceeded -eq $true) -and -not $libraryUnresolved -and ($codeVerified -ne $true)
        if ($libraryUnresolved -and -not $AllowUnresolvedLibrary) { $buildSucceeded = $null }

        # --- per PLC project status (coverage read before the build) ---
        $projects = @()
        foreach ($p in @($coverage.projects)) {
            $st = $p.status
            if ($st -ne 'skipped') {
                if ($buildSucceeded -eq $true) { $st = 'built' }
                else {
                    $pattern = "[\\/]$([regex]::Escape($p.name))[\\/]"
                    $hit = @($nonLibraryErrors | Where-Object { [string]$_.project -ieq $p.name -or ([string]$_.file -match $pattern) })
                    $st = if ($hit.Count -gt 0) { 'failed' } else { 'unknown' }
                }
            }
            $projects += [PSCustomObject]@{
                name          = $p.name
                uniqueName    = $p.uniqueName
                configuration = $p.configuration
                platform      = $p.platform
                shouldBuild   = $p.shouldBuild
                status        = $st
            }
        }
        $skippedProjects = @($projects | Where-Object { $_.status -eq 'skipped' } | ForEach-Object { $_.name })
        $coverageComplete = ($null -eq $coverage.error) -and ($projects.Count -gt 0) -and (@($projects | Where-Object { $_.status -ne 'built' }).Count -eq 0)

        $data = [PSCustomObject]@{
            buildSucceeded = $buildSucceeded
            projects       = $projects
            skippedProjects = $skippedProjects
            coverageComplete = $coverageComplete
            solutionConfiguration = $coverage.configuration
            errors         = $errorCount
            libraryErrors  = $libraryErrorCount
            warnings       = $warningCount
            messages       = $messages
            failedProjects = $failedProjects
            errorItems     = $errorItems
            codeErrors     = $codeErrors
            libraryErrorItems = $libraryErrorItems
            warningItems   = $warningItems
            codeWarnings   = $codeWarnings
            buildSec       = $buildSec
            codeVerified   = $codeVerified
        }
        if ($null -ne $decidedBy) {
            $data | Add-Member -NotePropertyName 'decidedBy' -NotePropertyValue $decidedBy
        }
        if ($null -ne $errorListError) {
            $data | Add-Member -NotePropertyName 'errorListError' -NotePropertyValue $errorListError
        }
        if ($severityUnknown) {
            $data | Add-Member -NotePropertyName 'severityUnknown' -NotePropertyValue $true
            $data | Add-Member -NotePropertyName 'unclassified' -NotePropertyValue @($el.data.unclassified)
        }
        if ($null -ne $coverage.error) {
            $data | Add-Member -NotePropertyName 'coverageError' -NotePropertyValue $coverage.error
        }
        if ($skippedProjects.Count -gt 0) {
            $warn = "Build-TcProject: PLC project(s) $($skippedProjects -join ', ') are not built by the active solution configuration '$($coverage.configuration)' (PROJECT_SKIPPED_BY_CONFIGURATION); their compiled output is stale. $(Get-TcErrorHint -Code 'PROJECT_SKIPPED_BY_CONFIGURATION')"
            Add-TcBuildWarning -Data $data -Code 'PROJECT_SKIPPED_BY_CONFIGURATION' -Text $warn
        }
        if ($expected.Count -gt 0) {
            $data | Add-Member -NotePropertyName 'expectedProjects' -NotePropertyValue $expected
        }

        $libNames = @($libraryErrorItems | Select-Object -First 3 | ForEach-Object { [string]$_.description }) -join '; '
        if ($libraryErrorItems.Count -gt 3) { $libNames += " ... (+$($libraryErrorItems.Count - 3) more)" }
        if ($libraryUnresolved -and -not $AllowUnresolvedLibrary) {
            return New-TcResult -Success $false -ErrorMessage "Build not verified: the Error List shows $($libraryErrorItems.Count) unresolved library error(s), so the PLC code may not have been compiled (no code error would be reported). $libNames" `
                -ErrorCode 'LIBRARY_UNRESOLVED' -Hint (Get-TcErrorHint -Code 'LIBRARY_UNRESOLVED') -Data $data
        }
        if ($libraryUnresolved) {
            $libWarn = "Build-TcProject: $($libraryErrorItems.Count) unresolved library error(s); the PLC code may not have been compiled (LIBRARY_UNRESOLVED, accepted by -AllowUnresolvedLibrary). $libNames"
            $data | Add-Member -NotePropertyName 'libraryWarning' -NotePropertyValue $libWarn
            Add-TcBuildWarning -Data $data -Code 'LIBRARY_UNRESOLVED' -Text $libWarn
        }
        if ($codeNotVerified) {
            $why = if ($null -ne $errorListError) { "the Error List could not be read ($errorListError)" }
                   else { "the Error List lists $($unlocatedCode.Count) code row(s) without a line number" }
            Add-TcBuildWarning -Data $data -Code 'CODE_NOT_VERIFIED' -Text "Build-TcProject: build reported success but $why, so it is not confirmed that the PLC code was compiled (CODE_NOT_VERIFIED). $(Get-TcErrorHint -Code 'CODE_NOT_VERIFIED')"
        }

        if ($null -eq $buildSucceeded) {
            $why = if ($null -ne $errorListError) { "LastBuildInfo not readable and Error List not readable ($errorListError)" }
                   else { "LastBuildInfo not readable and the Error List rows ($unclassifiedCount) have no usable severity" }
            New-TcResult -Success $false -ErrorMessage "Build result could not be determined: $why." `
                -ErrorCode 'BUILD_STATUS_UNKNOWN' -Hint (Get-TcErrorHint -Code 'BUILD_STATUS_UNKNOWN') -Data $data
        }
        elseif (-not $buildSucceeded) {
            $summary = "Build failed: $($codeErrors.Count) code error(s)"
            if ($libraryErrorItems.Count -gt 0) { $summary += " (+$($libraryErrorItems.Count) library)" }
            if ($nonLibraryErrors.Count -gt 0) {
                $parts = @()
                foreach ($item in @($nonLibraryErrors | Select-Object -First 3)) {
                    $loc = ''
                    if (-not [string]::IsNullOrWhiteSpace($item.file)) {
                        $loc = [IO.Path]::GetFileNameWithoutExtension([string]$item.file)
                        if ($null -ne $item.line -and $item.line -gt 0) { $loc += ":$($item.line)" }
                        $loc = " ($loc)"
                    }
                    $codeText = if ([string]::IsNullOrWhiteSpace($item.code)) { '' } else { "$($item.code) " }
                    $parts += "$codeText$($item.description)$loc"
                }
                $summary += '. ' + ($parts -join '; ')
                if ($nonLibraryErrors.Count -gt 3) { $summary += " ... (+$($nonLibraryErrors.Count - 3) more)" }
            }
            elseif ($null -ne $errorListError) {
                $summary += " ($failedProjects project(s) failed; Error List not readable: $errorListError)"
            }
            elseif ($null -ne $failedProjects) {
                $summary += " ($failedProjects project(s) failed; no code error listed in the Error List)"
            }
            New-TcResult -Success $false -ErrorMessage $summary -ErrorCode 'BUILD_FAILED' -Hint (Get-TcErrorHint -Code 'BUILD_FAILED_COMPILE') -Data $data
        }
        else {
            # -ExpectedProject: each one must have been built (skipped was refused before the build)
            $notBuilt = @($expected | ForEach-Object {
                $e = Find-TcBuildCoverageEntry -Projects $projects -Name $_
                if ($null -eq $e -or $e.status -ne 'built') { $_ }
            })
            if ($notBuilt.Count -gt 0) {
                return New-TcResult -Success $false -ErrorMessage "Build finished but expected PLC project(s) $($notBuilt -join ', ') were not confirmed as built (see data.projects)." `
                    -ErrorCode 'BUILD_COVERAGE_UNKNOWN' -Hint (Get-TcErrorHint -Code 'BUILD_COVERAGE_UNKNOWN') -Data $data
            }
            # the build that Enable-TcConfig waits for after a platform switch (BUILD_REQUIRED)
            $script:TcBuildRequired = $null
            New-TcResult -Success $true -Data $data
        }
    }
    catch {
        $errData = $null
        if ($null -ne $script:TcLastModalDialog) {
            $errData = [PSCustomObject]@{ dialogTitle = [string]$script:TcLastModalDialog.Title; dialogText = [string]$script:TcLastModalDialog.Text }
        }
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_FAILED' -MessagePrefix 'Build failed' -Data $errData
    }
}
