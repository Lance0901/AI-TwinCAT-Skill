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
                             code row without a line number, and every PLC project of the active
                             solution configuration took part in the build, so a successful build
                             also proves the PLC code was compiled; $false otherwise (also when a
                             PLC project was skipped by the configuration or the solution has no
                             PLC project, #58); $null when the Error List or the PLC project list
                             (coverageError) is not readable. This applies to BUILD_FAILED results
                             too (a failed build with a skipped PLC project has codeVerified $false), except a
                             BUILD_FAILED whose Error List lists no error row at all: $null instead of
                             $true (#188; $null also when the PLC is found logged in)
        data.solutionConfiguration  '<configuration>|<solution platform>' of the active solution
                             configuration, read like Get-TcIdeInfo (Solution.Properties
                             ('ActiveConfig')); data.solutionPlatform is its platform (same value
                             as Get-TcIdeInfo data.solutionPlatform) and data.projectPlatform the
                             project platform of the .tsproj under it (#58). The platform of each
                             PLC project is in data.projects[].platform. data.platformSource is
                             how the solution platform was read (Get-TcSolutionPlatform:
                             ActiveConfig | PlatformName | context); with 'context' (a project
                             platform, last resort) solutionConfiguration is only the
                             configuration name.
        data.warningCodes    every warning code of a successful result, in this order:
                             PROJECT_SKIPPED_BY_CONFIGURATION, LIBRARY_UNRESOLVED (only with
                             -AllowUnresolvedLibrary), CODE_NOT_VERIFIED (also next to
                             LIBRARY_UNRESOLVED when a code row has no line number); data.warningCode is the
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
        category rules do not recognise, e.g. a Library Manager row in another UI language), or
        in which a PLC project was skipped by the configuration (all of them: no PLC code was
        compiled at all) keeps success = true with data.warningCodes containing CODE_NOT_VERIFIED
        (after PROJECT_SKIPPED_BY_CONFIGURATION, #58).
        A complete success (coverageComplete and codeVerified = $true - never a build accepted with
        -AllowUnresolvedLibrary, #61) also clears the "build required after
        a platform switch" state that Enable-TcConfig checks before activating (BUILD_REQUIRED, a
        state file per solution: Private/Set-TcBuildRequired.ps1). A skipped PLC project, an
        unreadable project list or Error List, a code row without a line number or a solution
        without PLC project does not clear it. data.completeBuild (successful results only) says
        whether this build counted as complete.
        A build that finished WITHOUT a complete success (#56) - LIBRARY_UNRESOLVED, BUILD_FAILED,
        BUILD_STATUS_UNKNOWN, BUILD_COVERAGE_UNKNOWN after the build, success with
        completeBuild = $false, and a started build that never finished (BUILD_TIMEOUT,
        IDE_MODAL_DIALOG during the build, an exception during the build) - records the same state (kind 'unverified-build'), so that
        Enable-TcConfig and Enter-TcPlcOnline refuse with BUILD_REQUIRED until a complete build:
        Activate and Login compile by themselves, but nothing checks that compile (measured
        2026-10-26, TcXaeShell 4024, TwinCAT_Festo copy, local UmRT: Enable-TcConfig -Force after
        a LIBRARY_UNRESOLVED build activated and returned success without a warning). data.buildRequired
        is the recorded reason, data.stateWarning is set when the state file could not be
        written (the entry then lives in this process only). Not recorded for a solution
        without PLC project (SolutionContexts and the TIPC tree both list none: there is no
        PLC code to verify), nor when the build was never started (checks before the build,
        IDE_BUSY on Build($false)).
        data.warningCodes with accepted library rows AND a code row without a line number:
        LIBRARY_UNRESOLVED, then CODE_NOT_VERIFIED (both, #56).
        data.errors          number of CODE errors (errorItems with category 'code'); Library
                             Manager rows are not counted (fallback when the Error List is not
                             readable: failedProjects)
        data.libraryErrors   number of library errors (category 'library'; $null when the Error
                             List is not readable) - missing / unresolved libraries, they do not
                             decide buildSucceeded
        data.libraryErrorItems  errorItems with category 'library'
        data.warnings        warning count (Error List; fallback: data.warningLines.Count)
        data.messages        lines of the build pane of the Output window (the old field, kept for compatibility;
                             the same capped list as data.buildPaneMessages; @() when the pane was not read,
                             see data.buildPaneStatus). Both fields are capped to the LAST 400 lines or 32000
                             characters (whichever is reached first); when capped, data.buildPaneTruncated = true
                             and data.buildPaneLineCount = the line count before the cap (both appear ONLY when capped, absent otherwise; same for warningLinesTruncated / warningLinesCount)
        data.buildPaneStatus read | not-found | unreadable (#219): the build pane is found by its GUID
                             {1BD8A850-02D1-11D1-BEE7-00A0C913D1F8} (VSConstants.OutputWindowPaneGuid.BuildOutputPane_guid),
                             never by its localized name; not-found / unreadable add data.buildPaneError
                             (and data.buildPanes = the panes seen) and leave buildPaneMessages / warningLines @()
        data.buildPaneName   the pane's name as the IDE shows it ("Build", zh-TW "建置"); $null when not read
        data.buildPaneMessages  non-empty lines of the build pane (#218)
        data.warningLines    lines of the FULL build pane with a compiler / MSBuild warning (": warning" after a file / location, or at the line start), then capped to 200 (data.warningLinesTruncated = true,
                             data.warningLinesCount = the total); the structured warnings are data.warningItems
                             (Error List). 實測 2026-11-09: zh-TW VS2022 and English XAE 4024 print the English
                             "warning:"; other UI languages are not verified
        data.failedProjects  SolutionBuild.LastBuildInfo ($null when it could not be read): the number of projects
                             of the SOLUTION that failed, not only PLC projects - the TwinCAT project (.tsproj) counts
                             too (實測 2026-11-06, #66 O12: 2 with one PLC project while the PLC was logged in;
                             that the second one is the .tsproj is 推論)
        data.errorItems      [ @{ severity; code; description; project; file; line; column; category } ]
                             all errors of the Error List; category (Get-TcErrorItemCategory):
                             code (has a file), library (file like '*Library Manager' with no
                             line, or "Could not open library" without a line), other (no file)
                             Runtime / system log rows are NOT in errorItems (#66, see data.runtimeMessages)
        data.codeErrors      errorItems with category 'code' - the PLC code errors
        data.runtimeMessages runtime / system log rows of the Error List (#66): TcUnit / ADSLOGSTR output of the
                             PLC, also rows such as 'TCOM Server' (10): / 'TwinCAT System' (10000):. Same shape with
                             category 'runtime': description "'<source>' (<number>): ..." (optionally after "<timestamp> | ",
                             實測 2026-11-06) and no file, no line, no
                             compiler code, no library message (Get-TcRuntimeLogKind). Error and warning rows; never
                             in errorItems / warningItems / codeErrors; @() when none. InfoSys: ADSLOGSTR messages
                             from the PLC application are shown in the XAE Error List
                             (https://infosys.beckhoff.com/content/1033/tf6500_tc3_iec60870_5_10x/984578315.html);
                             the row form is 實測 (#66, 2026-10-27, VS2022 4026, local UmRT, TcUnit project); what
                             the number in the brackets means is not confirmed.
                             Such rows mean the PLC (or the system) was running while it was built: #66 measured a
                             failed build whose compiler error was not in the Error List at all. So when the
                             Error List decides the result (decidedBy = ErrorList, LastBuildInfo not readable)
                             and runtimeMessages is not empty, codeVerified = $null and a successful build gets
                             CODE_NOT_VERIFIED (not complete, BUILD_REQUIRED stays; review #150 F3).
        data.plcOnlineSuspected  always present ($false unless set, O13); $true (BUILD_FAILED only, codeVerified then
                             $null, O12) when the Error List was read and lists no error row at all (no code,
                             library or other error row) and either a built PLC project reads back as logged in
                             (data.plcOnlineEvidence 'login-state', #188) or every built PLC project is 'unknown'
                             and runtime / system log rows are present ('runtime-log', #66 / O9, 實測 2026-11-06;
                             also when a PLC reads back as NOT logged in: that read is not trusted, never measured
                             while logged in) -
                             XAE did not compile while logged in (hint BUILD_FAILED_PLC_ONLINE)
        data.plcOnlineEvidence  always present: 'login-state' | 'runtime-log' | $null (not suspected)
        data.plcLoginState   always present; $null unless the build failed with a readable Error List without any
                             error row: then one entry per built (not skipped / disabled) PLC project
                             @{ plc; loggedIn ($true | $false | $null = unknown); source ('IsLoggedIn' | 'ProduceXml'
                             | $null); error } (Get-TcPlcLoginState: TE1000 ITcPlcOnline.IsLoggedIn, else the
                             "<Plc> Project" ProduceXml IECProjectDef/OnlineSettings/LoggedIn, 實測 2026-11-08 4026
                             VS2022: IsLoggedIn of TIPC^<Plc> read back null there, ProduceXml decided). Such a BUILD_FAILED always has codeVerified $null, logged in or not (#188:
                             XAE logged in, no runtime log row, the build failed without listing an error)
        data.runtimeMessageNote  only when a row has that prefix AND a file, line, code or library message: it
                             cannot be told apart, so it stays in errorItems / warningItems (fail closed) with a
                             'note' on the row
        data.warningItems    same shape as errorItems, the warnings of the Error List (@() when it could not be read)
        data.codeWarnings    warningItems without the "Library Manager" items and without the
                             rows that have no file (XAE build-summary rows such as "Project
                             'plc' build ... failed" stay in the Error List as Warning)
        data.errorListError  only when the Error List could not be read (its error code), or its ERROR rows
                             were read only in part (ERRORLIST_INCOMPLETE: errors / total short of the button
                             totals, Errors total unreadable, or a filtered scope with rows missing, #117);
                             codeVerified = $null then, but errorItems / codeErrors still list the rows read (#138)
        data.errorListScope  the Error List scope filter @{ before; after; entire; switched } (#117)
        data.missingRows     with an incomplete read: [ @{ severity; expected; read } ]
        data.errorListNote   warnings (only) read short, or a filtered scope whose counts all match: the error
                             rows are complete; warnings short also adds WARNINGS_INCOMPLETE to warningCodes
        data.scanCleanupWarning  only when Get-TcBuildErrors dropped leftover timed-out UIA scans (#75); when one may still
                             be running the Error List is not read in that call (errorListError = ERRORLIST_UNAVAILABLE, codeVerified = $null)
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
                  disabled ShouldBuild = false AND the PLC project is disabled in the TwinCAT
                           project (#104, see below); not counted as skipped
        data.projects[].disabled  $true when the PLC tree item (TIPC^<name>) is disabled
                  (ITcSmTreeItem.Disabled, .tsproj <Project Disabled="true">, read with
                  Get-TcPlcProjectList like Enable-TcConfig); a disabled project that the
                  configuration builds keeps status 'built' / 'failed' / 'unknown' and counts
                  like any other.
        data.skippedProjects (names, status 'skipped' only), data.disabledProjects (names, status
        'disabled'), data.coverageComplete (every PLC project except the 'disabled' ones 'built',
        and at least one such project).
        Disabled PLC projects (#104): XAE does not activate a disabled PLC project and Enable-TcConfig
        leaves it out, so a disabled project that the configuration skips is no coverage gap: it
        is not in skippedProjects, does not raise PROJECT_SKIPPED_BY_CONFIGURATION and does not
        keep coverageComplete / codeVerified / completeBuild false. An ENABLED project that is
        skipped still does (#28). Coverage entries are matched to PLC tree items first by .plcproj
        path: the PLC node's ProduceXml PlcProjectDef/ProjectPath (absolute; measured 2026-11-03,
        4026 + VS2022 + local UmRT, Get-TcPlcProjectList projectFile) against the entry's uniqueName
        joined to the solution directory, both normalised with Get-TcLongPath (GetFullPath, 8.3 short
        names to long) and compared case-insensitively. The path match is used only when every PLC
        node has a ProjectPath, each node matches exactly one entry and no entry matches two nodes;
        else by name (.plcproj file name = TIPC child name), where an entry with no matching tree
        item counts as enabled. The name match must be one to one too (fail closed): when a
        disabled tree item matches more than one entry, an enabled tree item matches none, or an
        entry matches more than one tree item, every project counts as enabled (old behaviour) and
        data.disabledCheckError says why. data.disabledMatchBy is 'path', 'name' or $null (no
        disabled tree item, list not readable, or no one-to-one match). When
        the PLC project list cannot be read every project counts as enabled (old behaviour) and
        data.disabledCheckError holds the message. When every PLC project is disabled and skipped,
        nothing was compiled: coverageComplete, codeVerified and completeBuild are $false
        (CODE_NOT_VERIFIED), like a solution without PLC project - and like it, BUILD_REQUIRED is
        neither recorded nor cleared by such a build (no PLC code is activated).
        InfoSys on disabling: https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425861515.html
        (that .tsproj Disabled="true" reads back as ITcSmTreeItem.Disabled <> 0 on the PLC node is
        not measured yet).
        Skipped projects without -ExpectedProject: success stays as decided above, plus
        data.warningCode = PROJECT_SKIPPED_BY_CONFIGURATION, data.warning and Write-Warning.
        -ExpectedProject <name>: when one of them is skipped the build is not started and
        PROJECT_SKIPPED_BY_CONFIGURATION is returned (success = false); a name that is no
        PLC project of the solution returns EXPECTED_PROJECT_NOT_FOUND; a disabled one (#104,
        built or not) returns EXPECTED_PROJECT_DISABLED (build not started); one that ends
        'failed' fails with BUILD_FAILED, one that ends 'unknown' with BUILD_COVERAGE_UNKNOWN.
        When the contexts cannot be read data.coverageError is set, data.coverageComplete =
        $false; with -ExpectedProject that is BUILD_COVERAGE_UNKNOWN. A PLC project whose
        ShouldBuild is not read as a real bool (status 'unreadable', #67) is neither built nor
        skipped: the build is not started, BUILD_COVERAGE_UNKNOWN (data.unreadableProjects),
        with or without -ExpectedProject. A PLC tree item whose Disabled cannot be read ($null)
        counts as enabled (it stays in the coverage).
        While a solution platform switch left a changed PLC build selection that could not be
        undone (#67, Get-TcBuildSelectionGuard), nothing is built: BUILD_SELECTION_CHANGED
        (data.buildSelectionGuard); switch back with Set-TcTarget first.
        Measured 2026-10-21 (4026 + VS2022): SolutionContext.ProjectName is the unique name
        'RobustSolutionFrameworkDemo\FrameworkUnitTest\FrameworkUnitTest.plcproj'; the
        PLC name is its file name without extension.
    .PARAMETER TimeoutSec
        Maximum time in seconds to wait for the build to finish (BuildState = Done);
        BUILD_TIMEOUT after that. Default 600.
    .PARAMETER ExpectedProject
        PLC project name(s) that must take part in the build (e.g. 'FrameworkUnitTest').
        Matched against the .plcproj file name (without extension). A disabled PLC project
        is refused with EXPECTED_PROJECT_DISABLED.
    .PARAMETER AllowUnresolvedLibrary
        Accept a build whose Error List shows unresolved libraries (missing / not installed)
        as success, with data.warningCode = LIBRARY_UNRESOLVED and codeVerified = $false.
        Without it such a build returns LIBRARY_UNRESOLVED (see above). The accepted build is
        never complete (data.completeBuild = $false, #61): it records BUILD_REQUIRED
        (unverified-build), so Enable-TcConfig and Enter-TcPlcOnline still refuse until the
        library is installed and a complete Build-TcProject succeeds.
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

    $dialog = Find-TcIdeModalDialogColdRetry   # #230: one longer retry when the first scan timed out
    if ($null -ne $dialog) {
        return New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Build'
    }

    # #201: TakeOverOrphan answered a reload prompt 'do not reload': the IDE holds the old in-memory
    # solution; building / downloading it (or saving it back) is refused until Reset-TcSolution
    $resetGuard = Get-TcResetRequiredGuard
    if ($null -ne $resetGuard) { return New-TcResetRequiredResult -Guard $resetGuard -Operation 'Build-TcProject' }
    # #67: a platform switch left a changed PLC build selection that could not be undone
    $selGuard = Get-TcBuildSelectionGuard
    if ($null -ne $selGuard) { return New-TcBuildSelectionGuardResult -Guard $selGuard -Operation 'Build-TcProject' }

    # set again only by a successful build (Enable-TcConfig BUILD_REQUIRED message)
    $script:TcLastBuildVerdict = $null

    # --- coverage: which PLC projects the active solution configuration builds (#28) ---
    try { $coverage = Get-TcBuildCoverage }
    catch { return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_FAILED' -MessagePrefix 'Build not started (reading SolutionContexts failed)' }
    # --- disabled PLC projects (#104): ITcSmTreeItem.Disabled of the TIPC child (Get-TcPlcProjectList),
    # the same reading Enable-TcConfig and Resolve-TcPlcProjectPath use to leave them out (a disabled
    # tree item is not activated: InfoSys "How to disable/enable a tree item",
    # https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425861515.html). A coverage
    # entry is matched to a PLC tree item by .plcproj path first (see below), else by name (the .plcproj file name without extension = the
    # TIPC child name, the same assumption as Find-TcBuildCoverageEntry's 'TIPC^<Plc>' form); an
    # entry without a matching tree item counts as enabled (old behaviour). The name is not a
    # reliable key (two folders with PLC.plcproj; an enabled node 'Main' whose file is Legacy.plcproj
    # next to a disabled node 'Legacy'), so the match must be one to one, else fail closed: when a
    # disabled node matches more than one entry, an enabled node matches no entry, or an entry
    # matches more than one node, every entry counts as enabled (old behaviour) and
    # data.disabledCheckError says why. A disabled entry that the configuration skips gets status
    # 'disabled' (not 'skipped'): it is not part of the coverage, so it does not keep
    # coverageComplete false. A disabled entry that IS built stays 'built'. When the list cannot be
    # read every entry counts as enabled (data.disabledCheckError).
    $disabledCheckError = $null
    # 'path' | 'name' | $null (no disabled tree item, list not readable, or no one-to-one match)
    $disabledMatchBy = $null
    # also used for the login state of a BUILD_FAILED without error rows (#188)
    $plcList = $null
    foreach ($p in @($coverage.projects)) { $p | Add-Member -NotePropertyName 'disabled' -NotePropertyValue $false -Force }
    if ($null -eq $coverage.error -and @($coverage.projects).Count -gt 0) {
        $plcList = $null
        try { $plcList = @(Get-TcPlcProjectList -SysManager $sm) }
        catch {
            if ($_.Exception.Message -match 'IDE_CRASHED|IDE_MODAL_DIALOG') {
                return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_FAILED' -MessagePrefix 'Build not started (reading the PLC project list failed)'
            }
            $disabledCheckError = $_.Exception.Message
            Write-Verbose "Build-TcProject: PLC project list not readable ($disabledCheckError); every PLC project counts as enabled."
        }
        # without any disabled tree item nothing is marked, so the one-to-one check is not needed
        if ($null -ne $plcList -and @($plcList | Where-Object { $_.disabled -eq $true }).Count -gt 0) {
            # .plcproj path first, then name; not one to one -> fail closed (Resolve-TcPlcCoverageNodes,
            # shared with Set-TcSolutionPlatform #67)
            $entries = @($coverage.projects)
            $m = Resolve-TcPlcCoverageNodes -Entries $entries -PlcList $plcList -SolutionPath ([string]$script:TcSolutionPath)
            if ($null -ne $m.Error) {
                $disabledCheckError = Get-TcPlcMatchErrorText -Reasons $m.Error -Consequence 'every PLC project counts as enabled'
                Write-Verbose "Build-TcProject: $disabledCheckError"
            }
            else {
                for ($i = 0; $i -lt $entries.Count; $i++) {
                    if ($null -ne $m.Nodes[$i] -and $m.Nodes[$i].disabled -eq $true) {
                        $entries[$i].disabled = $true
                        if ($entries[$i].status -eq 'skipped') { $entries[$i].status = 'disabled' }
                    }
                }
                $disabledMatchBy = $m.MatchBy
            }
        }
    }
    $disabledProjects = @($coverage.projects | Where-Object { $_.status -eq 'disabled' } | ForEach-Object { $_.name })
    # Solution configuration of the result (#58): the same reading as Get-TcIdeInfo / Connect-TcIde
    # data.solutionPlatform (Get-TcSolutionPlatform, DTE Solution.Properties('ActiveConfig')), not
    # the platform of the PLC project contexts, which is the PROJECT platform (solution
    # 'TwinCAT OS (x64)' -> project 'TwinCAT OS (ARMT2)', measured 2026-10-26, VisualStudio.DTE.17.0,
    # TwinCAT_Festo 4026 copy). Get-TcBuildCoverage's label is only the fallback.
    # platformSource 'context' means Get-TcSolutionPlatform fell back to a SolutionContext, i.e. a
    # PROJECT platform: then only the configuration name is reported (data.platformSource says why).
    $solPlat = Get-TcSolutionPlatform
    $solutionConfiguration = $coverage.configuration
    if (-not [string]::IsNullOrWhiteSpace([string]$solPlat.configuration)) {
        if ([string]$solPlat.platformSource -ne 'context' -and -not [string]::IsNullOrWhiteSpace([string]$solPlat.platform)) {
            $solutionConfiguration = "$($solPlat.configuration)|$($solPlat.platform)"
        }
        else { $solutionConfiguration = [string]$solPlat.configuration }
    }
    # #67 M1: a PLC project whose ShouldBuild was not read as a bool is neither built nor skipped:
    # the build is not started (fail closed), with or without -ExpectedProject
    $unreadable = @($coverage.projects | Where-Object { $_.status -eq 'unreadable' })
    if ($null -eq $coverage.error -and $unreadable.Count -gt 0) {
        $names = @($unreadable | ForEach-Object { $_.name })
        return New-TcResult -Success $false -ErrorCode 'BUILD_COVERAGE_UNKNOWN' -Hint (Get-TcErrorHint -Code 'BUILD_COVERAGE_UNKNOWN') `
            -ErrorMessage "Build not started: ShouldBuild of PLC project(s) $($names -join ', ') in '$solutionConfiguration' could not be read, so it is not known whether the build covers them." `
            -Data ([PSCustomObject]@{ projects = @($coverage.projects); unreadableProjects = $names; coverageComplete = $false; solutionConfiguration = $solutionConfiguration; disabledProjects = $disabledProjects; disabledMatchBy = $disabledMatchBy })
    }
    $expected = @($ExpectedProject | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    if ($expected.Count -gt 0) {
        $covData = [PSCustomObject]@{
            projects              = @($coverage.projects)
            skippedProjects       = @($coverage.projects | Where-Object { $_.status -eq 'skipped' } | ForEach-Object { $_.name })
            coverageComplete      = $false
            expectedProjects      = $expected
            solutionConfiguration = $solutionConfiguration
            solutionPlatform      = $solPlat.platform
            projectPlatform       = $solPlat.projectPlatform
            platformSource        = $solPlat.platformSource
            disabledProjects      = $disabledProjects
            disabledMatchBy       = $disabledMatchBy
        }
        if ($null -ne $disabledCheckError) {
            $covData | Add-Member -NotePropertyName 'disabledCheckError' -NotePropertyValue $disabledCheckError
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
        # #104: a disabled PLC project is never activated (Enable-TcConfig leaves it out; InfoSys
        # https://infosys.beckhoff.com/content/1033/tcautomationinterface/12425861515.html), so
        # expecting it is a mistake - refused whether or not the configuration builds it.
        $disabledExpected = @($expected | Where-Object { (Find-TcBuildCoverageEntry -Projects $coverage.projects -Name $_).disabled -eq $true })
        if ($disabledExpected.Count -gt 0) {
            return New-TcResult -Success $false -ErrorMessage "Build not started: expected PLC project(s) $($disabledExpected -join ', ') are disabled in the TwinCAT project (ITcSmTreeItem.Disabled, .tsproj Disabled=""true""); a disabled PLC project is not activated, so it cannot be an expected project." `
                -ErrorCode 'EXPECTED_PROJECT_DISABLED' -Hint (Get-TcErrorHint -Code 'EXPECTED_PROJECT_DISABLED') -Data $covData
        }
        $skippedExpected = @($expected | Where-Object { (Find-TcBuildCoverageEntry -Projects $coverage.projects -Name $_).status -eq 'skipped' })
        if ($skippedExpected.Count -gt 0) {
            return New-TcResult -Success $false -ErrorMessage "Build not started: expected PLC project(s) $($skippedExpected -join ', ') are not built by the active solution configuration '$solutionConfiguration' (no Build.0 entry / 'Build' unticked in Configuration Manager); a solution Build would report success without compiling them." `
                -ErrorCode 'PROJECT_SKIPPED_BY_CONFIGURATION' -Hint (Get-TcErrorHint -Code 'PROJECT_SKIPPED_BY_CONFIGURATION') -Data $covData
        }
    }

    # #56: a build that was started and did not end in a complete success is remembered per
    # solution (Set-TcBuildRequired -Kind unverified-build), so a later Enable-TcConfig / PLC
    # login does not use output that nobody verified: LIBRARY_UNRESOLVED, BUILD_FAILED,
    # BUILD_STATUS_UNKNOWN, BUILD_COVERAGE_UNKNOWN after the build, success with completeBuild =
    # $false, and also BUILD_TIMEOUT, IDE_MODAL_DIALOG during the build and any exception after
    # the build was asked to start (outer catch). Not recorded: the checks before the build
    # (nothing changed) and IDE_BUSY when Build($false) itself was rejected. Not for a solution
    # without PLC project - the coverage list (SolutionContexts) read without error AND the TIPC
    # tree has no PLC child (Get-TcPlcProjectList; unreadable -> recorded): there is no PLC code
    # to verify, and such a solution can never reach completeBuild, so the entry could only be
    # removed by hand. The same holds when every PLC project is disabled and not built (#104,
    # status 'disabled', the disabled check itself without disabledCheckError): no PLC code is
    # activated, so it is treated like a solution without PLC project (not recorded; completeBuild
    # stays $false and an existing entry is not cleared, as for a solution without PLC project).
    $noPlcChecked = $false
    $noPlcProject = $false
    $allDisabled = ($null -eq $coverage.error) -and ($null -eq $disabledCheckError) -and (@($coverage.projects).Count -gt 0) -and
        (@($coverage.projects | Where-Object { $_.status -ne 'disabled' }).Count -eq 0)
    $recordUnverified = {
        param([string]$What, [object]$Target)
        if (-not $noPlcChecked) {
            $noPlc = ($null -eq $coverage.error) -and (@($coverage.projects).Count -eq 0)
            if ($allDisabled) { $noPlc = $true }
            elseif ($noPlc) {
                try { $noPlc = (@(Get-TcPlcProjectList -SysManager $sm).Count -eq 0) } catch { $noPlc = $false }
            }
            Set-Variable -Name noPlcProject -Value $noPlc -Scope 1
            Set-Variable -Name noPlcChecked -Value $true -Scope 1
        }
        if ($noPlcProject) { return }
        $reason = "the last Build-TcProject ($What) did not prove that the PLC code was compiled"
        $sw = Set-TcBuildRequired -Kind 'unverified-build' -Reason $reason
        if ($null -ne $Target) {
            $Target | Add-Member -NotePropertyName 'buildRequired' -NotePropertyValue $reason -Force
            if (-not [string]::IsNullOrWhiteSpace([string]$sw)) { $Target | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue ([string]$sw) -Force }
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
                $dialog = Find-TcIdeModalDialog
                # An incomplete scan (#42) while polling: unknown, keep polling BuildState (the
                # build result is decided by BuildState, not by this check).
                if ($null -ne $dialog -and -not (Test-TcModalScanIncomplete $dialog)) {
                    $res = New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Build (build in progress, BuildState never reached Done)' `
                        -Data ([PSCustomObject]@{ buildState = $buildState; buildSec = [math]::Round($buildWatch.Elapsed.TotalSeconds, 1) })
                    & $recordUnverified 'IDE_MODAL_DIALOG during the build' $res.data
                    return $res
                }
            }
            if ($buildWatch.Elapsed.TotalSeconds -ge $TimeoutSec) {
                $dialog = Find-TcIdeModalDialog
                $scanIncomplete = Test-TcModalScanIncomplete $dialog
                if ($null -ne $dialog -and -not $scanIncomplete) {
                    $res = New-TcModalDialogResult -Dialog $dialog -Operation 'SolutionBuild.Build (build in progress, BuildState never reached Done)' `
                        -Data ([PSCustomObject]@{ buildState = $buildState; buildSec = [math]::Round($buildWatch.Elapsed.TotalSeconds, 1) })
                    & $recordUnverified 'IDE_MODAL_DIALOG during the build' $res.data
                    return $res
                }
                $toData = [PSCustomObject]@{ buildState = $buildState; buildSec = [math]::Round($buildWatch.Elapsed.TotalSeconds, 1) }
                # BUILD_TIMEOUT either way; an incomplete scan is reported, not read as "no dialog".
                if ($scanIncomplete) { $toData | Add-Member -NotePropertyName 'modalScan' -NotePropertyValue (ConvertTo-TcModalScanInfo -Scan $dialog) }
                & $recordUnverified 'BUILD_TIMEOUT' $toData
                return New-TcResult -Success $false `
                    -ErrorMessage "Build did not finish within $TimeoutSec s (SolutionBuild.BuildState = $buildState; 1 NotStarted, 2 InProgress, 3 Done)." `
                    -ErrorCode 'BUILD_TIMEOUT' -Hint (Get-TcErrorHint -Code 'BUILD_TIMEOUT') `
                    -Data $toData
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

        # Build pane of the Output window (#219): found by its GUID, never by the localized name ("Build",
        # zh-TW "建置"), and read through IDispatch - $dte.ToolWindows is $null out of process on VS2022, so
        # the old 'Build' name loop never saw a pane at all (實測 2026-11-09, VS2022 zh-TW + 4026).
        # No deadline here on purpose: this runs after BuildState is Done (the build is over), only reads
        # properties (no build / no UI action), and Invoke-TcComRetry already runs its modal-dialog watchdog
        # and bounds the retries (-MaxRetries 3), so a stuck read ends in IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG.
        $buildPaneRead = $null
        try {
            $buildPaneRead = Invoke-TcComRetry -MaxRetries 3 -OperationName 'Read build output' -ScriptBlock { Get-TcBuildOutputPane }
        }
        catch {
            Write-Verbose "Could not read build output: $_"
        }
        if ($null -eq $buildPaneRead) {
            $buildPaneRead = [PSCustomObject]@{ status = 'unreadable'; name = $null; guid = $null; index = $null; matchedBy = $null; text = ''; panes = @(); error = 'Get-TcBuildOutputPane failed' }
        }
        $allMessages = @([string]$buildPaneRead.text -split "`n" | ForEach-Object { $_.TrimEnd("`r") } | Where-Object { $_.Trim() -ne '' })
        # warning lines are filtered from the FULL pane first, then capped on their own (a long build log must
        # not push the warnings out of the kept tail)
        $allWarningLines = @(Get-TcBuildWarningLines -Lines $allMessages)
        $buildPaneLineCount = $allMessages.Count
        # cap: keep the LAST 400 lines or 32000 characters, whichever is reached first (the end of the log has the result)
        $paneMaxLines = 400; $paneMaxChars = 32000; $warnMaxLines = 200
        $messages = $allMessages
        $buildPaneTruncated = $false
        if ($allMessages.Count -gt 0) {
            $kept = [System.Collections.Generic.List[string]]::new()
            $chars = 0
            for ($mi = $allMessages.Count - 1; $mi -ge 0 -and $kept.Count -lt $paneMaxLines; $mi--) {
                $chars += $allMessages[$mi].Length + 1
                if ($chars -gt $paneMaxChars -and $kept.Count -gt 0) { break }
                $kept.Insert(0, $allMessages[$mi])
            }
            if ($kept.Count -lt $allMessages.Count) {
                $buildPaneTruncated = $true
                $messages = @($kept.ToArray())
            }
        }
        $warningLinesTruncated = $allWarningLines.Count -gt $warnMaxLines
        # @() around the if: an if-expression unrolls its output (0 items -> AutomationNull -> JSON {}, 1 item -> a string)
        $warningLines = @(if ($warningLinesTruncated) { $allWarningLines | Select-Object -First $warnMaxLines } else { $allWarningLines })

        # Error List (UI Automation): the PLC compiler does not report through DTE.
        # Every build gets the full Error List budget ($script:TcBuildErrorListTimeoutSec, 30 s):
        # the success path used to get 8 s, but the scan (show the pane, switch the scope, toggle
        # the severities, read the grid) took 16.5-17.8 s on a 4026 VS2022 XAE after a build that
        # succeeded, so a good build came back CODE_NOT_VERIFIED (#107, 實測 by the issue reporter).
        # The budget is an upper bound, not a wait: the scan returns as soon as it has read the list.
        # Read and classified by Get-TcErrorListSummary (shared with Test-TcPlcProject, task 3.7):
        # every error row gets a category (#23); "Library Manager" rows are missing / unresolved
        # libraries, not PLC code errors, so data.errors counts the code errors only.
        $fallbackErrors = if ($null -ne $failedProjects) { [int]$failedProjects } else { 0 }
        $fallbackWarnings = $allWarningLines.Count
        $els = Get-TcErrorListSummary -TimeoutSec $script:TcBuildErrorListTimeoutSec -SplitRuntimeLog -FallbackErrorCount $fallbackErrors -FallbackWarningCount $fallbackWarnings
        $errorItems = $els.errorItems
        $warningItems = $els.warningItems
        $errorCount = $els.errorCount
        $warningCount = $els.warningCount
        $errorListError = $els.errorListError
        $severityUnknown = $els.severityUnknown
        $unclassifiedCount = $els.unclassifiedCount
        if ($null -ne $errorListError) {
            Write-Verbose "Build-TcProject: Error List not readable ($($els.errorListMessage)); errors falls back to LastBuildInfo."
        }
        $codeErrors = $els.codeErrors
        $libraryErrorItems = $els.libraryErrorItems
        # code + other: what the failure summary and the per-project status look at
        $nonLibraryErrors = $els.nonLibraryErrors
        $libraryErrorCount = $els.libraryErrorCount
        $codeWarnings = $els.codeWarnings

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
        if ($libraryUnresolved -and -not $AllowUnresolvedLibrary) { $buildSucceeded = $null }

        # --- per PLC project status (coverage read before the build) ---
        $projects = @()
        foreach ($p in @($coverage.projects)) {
            $st = $p.status
            if ($st -ne 'skipped' -and $st -ne 'disabled') {
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
                disabled      = [bool]$p.disabled
            }
        }
        $skippedProjects = @($projects | Where-Object { $_.status -eq 'skipped' } | ForEach-Object { $_.name })
        # #104: disabled + skipped PLC projects ('disabled') are not part of the coverage; at least
        # one enabled PLC project must remain, else nothing was compiled (like a solution without PLC).
        $activeProjects = @($projects | Where-Object { $_.status -ne 'disabled' })
        $coverageComplete = ($null -eq $coverage.error) -and ($activeProjects.Count -gt 0) -and (@($activeProjects | Where-Object { $_.status -ne 'built' }).Count -eq 0)

        # --- coverage decides codeVerified too (#58) ---
        # A clean Error List only proves the code of the PLC projects that were compiled. With a
        # PLC project skipped by the configuration (XAE still says Build succeeded, its output is
        # stale) or no PLC project in the solution, codeVerified is never true: $false. When the
        # project list could not be read (coverageError) it is unknown: $null.
        $coverageWhy = $null
        if ($codeVerified -eq $true) {
            if ($null -ne $coverage.error) {
                $codeVerified = $null
                $coverageWhy = "the PLC project list of the active solution configuration could not be read ($($coverage.error))"
            }
            elseif ($projects.Count -eq 0) {
                $codeVerified = $false
                $coverageWhy = 'the solution has no PLC project (.plcproj) in the active solution configuration'
            }
            elseif ($activeProjects.Count -eq 0) {
                $codeVerified = $false
                $coverageWhy = "no PLC project was compiled (every PLC project is disabled and not built: $($disabledProjects -join ', '))"
            }
            elseif ($skippedProjects.Count -gt 0) {
                $codeVerified = $false
                $builtCount = @($projects | Where-Object { $_.status -eq 'built' }).Count
                $coverageWhy = if ($builtCount -eq 0) { "no PLC project was compiled (all skipped by the active solution configuration: $($skippedProjects -join ', '))" }
                               else { "PLC project(s) $($skippedProjects -join ', ') were skipped by the active solution configuration" }
            }
        }
        # With accepted library rows (-AllowUnresolvedLibrary) LIBRARY_UNRESOLVED already says the
        # code is not proven; a code row without a line number is a second, independent gap
        # (#56 point 2), so CODE_NOT_VERIFIED is added after LIBRARY_UNRESOLVED in that case.
        # #66 / review #150 F3: runtime / system log rows mean the PLC was running during the build, and
        # #66 measured a failed build whose compiler error was missing from the Error List. With
        # LastBuildInfo unreadable the Error List alone decided the result, so it is not proof.
        $runtimeWhy = $null
        if ($decidedBy -eq 'ErrorList' -and @($els.runtimeMessages).Count -gt 0) {
            $codeVerified = $null
            $runtimeWhy = "runtime log rows present (PLC online, or rows left from an earlier online session) (#66): $(@($els.runtimeMessages).Count) runtime / system log row(s) are in the Error List (data.runtimeMessages) and LastBuildInfo was not readable, so the Error List alone is not reliable (#66)"
        }
        $codeNotVerified = ($buildSucceeded -eq $true) -and ($codeVerified -ne $true) -and (-not $libraryUnresolved -or $unlocatedCode.Count -gt 0)

        $data = [PSCustomObject]@{
            buildSucceeded = $buildSucceeded
            projects       = $projects
            skippedProjects = $skippedProjects
            disabledProjects = $disabledProjects
            disabledMatchBy  = $disabledMatchBy
            coverageComplete = $coverageComplete
            solutionConfiguration = $solutionConfiguration
            solutionPlatform = $solPlat.platform
            projectPlatform  = $solPlat.projectPlatform
            platformSource   = $solPlat.platformSource
            errors         = $errorCount
            libraryErrors  = $libraryErrorCount
            warnings       = $warningCount
            messages       = $messages
            buildPaneStatus   = $buildPaneRead.status
            buildPaneName     = $buildPaneRead.name
            buildPaneMessages = $messages
            warningLines      = $warningLines
            failedProjects = $failedProjects
            errorItems     = $errorItems
            codeErrors     = $codeErrors
            libraryErrorItems = $libraryErrorItems
            warningItems   = $warningItems
            codeWarnings   = $codeWarnings
            runtimeMessages = @($els.runtimeMessages)
            # O13: always present; $true only on the BUILD_FAILED path below (#66 / O9)
            plcOnlineSuspected = $false
            # #188: always present; set only on a BUILD_FAILED without any error row (below)
            plcOnlineEvidence  = $null
            plcLoginState      = $null
            buildSec      = $buildSec
            codeVerified   = $codeVerified
        }
        # #66: rows with the log prefix that also have a file / line / code / library message stay build rows (fail closed)
        if (@($els.ambiguousRows).Count -gt 0) {
            $data | Add-Member -NotePropertyName 'runtimeMessageNote' -NotePropertyValue "$(@($els.ambiguousRows).Count) Error List row(s) look like runtime / system log output ('<source>' (<number>): ...) but have a file, line, compiler code or library message; they are kept in errorItems / warningItems as build rows (see their 'note')"
        }
        if ($null -ne $decidedBy) {
            $data | Add-Member -NotePropertyName 'decidedBy' -NotePropertyValue $decidedBy
        }
        # #219: a build pane that was not read is stated, never an empty list that looks like "no output"
        if ($buildPaneTruncated) {
            $data | Add-Member -NotePropertyName 'buildPaneTruncated' -NotePropertyValue $true
            $data | Add-Member -NotePropertyName 'buildPaneLineCount' -NotePropertyValue $buildPaneLineCount
        }
        if ($warningLinesTruncated) {
            $data | Add-Member -NotePropertyName 'warningLinesTruncated' -NotePropertyValue $true
            $data | Add-Member -NotePropertyName 'warningLinesCount' -NotePropertyValue $allWarningLines.Count
        }
        if ($buildPaneRead.status -ne 'read') {
            $data | Add-Member -NotePropertyName 'buildPaneError' -NotePropertyValue ([string]$buildPaneRead.error)
            $data | Add-Member -NotePropertyName 'buildPanes' -NotePropertyValue @($buildPaneRead.panes | ForEach-Object { [PSCustomObject]@{ index = $_.index; name = $_.name; guid = $_.guid } })
        }
        if ($null -ne $errorListError) {
            $data | Add-Member -NotePropertyName 'errorListError' -NotePropertyValue $errorListError
        }
        # #117 / #138: what the Error List read covered (scope filter, rows short of the button totals)
        if ($null -ne $els.scope) { $data | Add-Member -NotePropertyName 'errorListScope' -NotePropertyValue $els.scope }
        if ($els.incomplete) { $data | Add-Member -NotePropertyName 'missingRows' -NotePropertyValue @($els.missingRows) }
        if ($null -ne $els.errorListNote) { $data | Add-Member -NotePropertyName 'errorListNote' -NotePropertyValue $els.errorListNote }
        # Leftover timed-out Error List scans that were dropped (#75); on a failed read it also
        # explains ERRORLIST_UNAVAILABLE (codeVerified stays $null then).
        $elScanWarning = $els.scanCleanupWarning
        if ($null -ne $elScanWarning) {
            $data | Add-Member -NotePropertyName 'scanCleanupWarning' -NotePropertyValue $elScanWarning
        }
        if ($severityUnknown) {
            $data | Add-Member -NotePropertyName 'severityUnknown' -NotePropertyValue $true
            $data | Add-Member -NotePropertyName 'unclassified' -NotePropertyValue @($els.unclassified)
        }
        if ($null -ne $coverage.error) {
            $data | Add-Member -NotePropertyName 'coverageError' -NotePropertyValue $coverage.error
        }
        if ($null -ne $disabledCheckError) {
            $data | Add-Member -NotePropertyName 'disabledCheckError' -NotePropertyValue $disabledCheckError
        }
        if ($skippedProjects.Count -gt 0) {
            $warn = "Build-TcProject: PLC project(s) $($skippedProjects -join ', ') are not built by the active solution configuration '$solutionConfiguration' (PROJECT_SKIPPED_BY_CONFIGURATION); their compiled output is stale. $(Get-TcErrorHint -Code 'PROJECT_SKIPPED_BY_CONFIGURATION')"
            Add-TcBuildWarning -Data $data -Code 'PROJECT_SKIPPED_BY_CONFIGURATION' -Text $warn
        }
        if ($expected.Count -gt 0) {
            $data | Add-Member -NotePropertyName 'expectedProjects' -NotePropertyValue $expected
        }

        $libNames = @($libraryErrorItems | Select-Object -First 3 | ForEach-Object { [string]$_.description }) -join '; '
        if ($libraryErrorItems.Count -gt 3) { $libNames += " ... (+$($libraryErrorItems.Count - 3) more)" }
        if ($libraryUnresolved -and -not $AllowUnresolvedLibrary) {
            & $recordUnverified "LIBRARY_UNRESOLVED, $($libraryErrorItems.Count) unresolved library error(s)" $data
            return New-TcResult -Success $false -ErrorMessage "Build not verified: the Error List shows $($libraryErrorItems.Count) unresolved library error(s), so the PLC code may not have been compiled (no code error would be reported). $libNames" `
                -ErrorCode 'LIBRARY_UNRESOLVED' -Hint (Get-TcErrorHint -Code 'LIBRARY_UNRESOLVED') -Data $data
        }
        if ($libraryUnresolved) {
            $libWarn = "Build-TcProject: $($libraryErrorItems.Count) unresolved library error(s); the PLC code may not have been compiled (LIBRARY_UNRESOLVED, accepted by -AllowUnresolvedLibrary; not a complete build, so Enable-TcConfig / Enter-TcPlcOnline refuse with BUILD_REQUIRED until the library is installed and the build is complete). $libNames"
            $data | Add-Member -NotePropertyName 'libraryWarning' -NotePropertyValue $libWarn
            Add-TcBuildWarning -Data $data -Code 'LIBRARY_UNRESOLVED' -Text $libWarn
        }
        if ($codeNotVerified) {
            $why = if ($null -ne $errorListError -and $els.incomplete) { "the Error List was read only in part ($errorListError, data.missingRows)" }
                   elseif ($null -ne $errorListError) { "the Error List could not be read ($errorListError)" }
                   elseif ($null -ne $runtimeWhy) { $runtimeWhy }
                   elseif ($unlocatedCode.Count -gt 0) { "the Error List lists $($unlocatedCode.Count) code row(s) without a line number" }
                   else { $coverageWhy }
            Add-TcBuildWarning -Data $data -Code 'CODE_NOT_VERIFIED' -Text "Build-TcProject: build reported success but $why, so it is not confirmed that the PLC code was compiled (CODE_NOT_VERIFIED). $(Get-TcErrorHint -Code 'CODE_NOT_VERIFIED')"
        }
        # after the codes that decide completeBuild: WARNINGS_INCOMPLETE never does (#138)
        if ($els.warningsIncomplete) {
            Add-TcBuildWarning -Data $data -Code 'WARNINGS_INCOMPLETE' -Text "Build-TcProject: $($els.errorListNote); data.warningItems is not the whole list (WARNINGS_INCOMPLETE). The error rows are complete, so this does not affect codeVerified. $(Get-TcErrorHint -Code 'WARNINGS_INCOMPLETE')"
        }

        if ($null -eq $buildSucceeded) {
            $why = if ($null -ne $errorListError) { "LastBuildInfo not readable and Error List not readable ($errorListError)" }
                   else { "LastBuildInfo not readable and the Error List rows ($unclassifiedCount) have no usable severity" }
            & $recordUnverified 'BUILD_STATUS_UNKNOWN' $data
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
            # #66: TcUnit / ADSLOGSTR rows are not build errors; say so, so they are not read as the cause
            if (@($els.runtimeMessages).Count -gt 0) {
                $summary += ". $(@($els.runtimeMessages).Count) runtime / system log row(s) of the Error List (data.runtimeMessages, '<source>' (<number>): ..., e.g. TcUnit / ADSLOGSTR output) are not build errors and were left out"
            }
            # #66 problem 2 / O9 (實測 2026-11-06, VS2022 4026 + local UmRT; InfoSys: no source found): with
            # the PLC logged in XAE does not compile at all (0.8 s, LastBuildInfo > 0, the real C0046 is not
            # in the Error List; after PlcLogout the build lists C0046 / C0018). Two kinds of evidence, both
            # only when the Error List lists no error row at all: the login state read back (#188, below) or,
            # from data already read, every built project 'unknown' and runtime / system log rows present.
            $buildHint = Get-TcErrorHint -Code 'BUILD_FAILED_COMPILE'
            $activeStatus = @($projects | Where-Object { $_.status -ne 'skipped' -and $_.status -ne 'disabled' } | ForEach-Object { $_.status })
            # review #150 round 3 M1: ANY other error row (code without a file, an XAE error without a code)
            # rules it out - it may be the real cause, and old log rows stay after a logout
            $noErrorRow = ($null -eq $errorListError) -and ($codeErrors.Count -eq 0) -and ($libraryErrorItems.Count -eq 0) -and ($nonLibraryErrors.Count -eq 0)
            $allUnknown = ($activeStatus.Count -gt 0) -and (@($activeStatus | Where-Object { $_ -ne 'unknown' }).Count -eq 0)
            # #188 (實測 2026-11-08, 4026 VS2022 + local UmRT): logged in after Enable-TcConfig, no runtime
            # log row at all - only the 'TwinCAT XAE' ... failed warning - so the runtime-log rule below
            # did not fire and codeVerified stayed $true. A failed build without any error row proves
            # nothing about the code: codeVerified $null, and the login state of each built PLC project
            # is read (Get-TcPlcLoginState: ITcPlcOnline.IsLoggedIn, else ProduceXml OnlineSettings/
            # LoggedIn). Only on this path: a normal build does not pay for the extra COM calls.
            $plcLoginState = $null
            $loggedInPlcs = @()
            if ($noErrorRow) {
                # $false (skipped project, no PLC project, #58) is kept: it is already "not verified"
                if ($data.codeVerified -eq $true) { $data.codeVerified = $null }
                if ($activeStatus.Count -gt 0) {
                    # PLC tree item per built project: the list read for the disabled check, else read now
                    # (IDE_* exceptions end in the outer catch like any other COM failure of the build)
                    $loginPlcList = $null
                    $loginListError = $null
                    if ($null -ne $plcList) { $loginPlcList = @($plcList) }
                    else {
                        try { $loginPlcList = @(Get-TcPlcProjectList -SysManager $sm) }
                        catch {
                            if ($_.Exception.Message -match 'IDE_MODAL_DIALOG|IDE_TIMEOUT|IDE_BUSY|IDE_CRASHED') { throw }
                            $loginListError = $_.Exception.Message
                        }
                    }
                    # entries in the order of $coverage.projects (= $projects): .plcproj path first, then name
                    # (Resolve-TcPlcCoverageNodes). Not one to one -> no PLC is guessed: every entry gets
                    # loggedIn $null with the match error (fail closed, never a name fallback then).
                    $loginNodes = $null
                    $loginMatchError = $null
                    if ($null -ne $loginPlcList) {
                        $lm = Resolve-TcPlcCoverageNodes -Entries @($coverage.projects) -PlcList $loginPlcList -SolutionPath ([string]$script:TcSolutionPath)
                        if ($null -eq $lm.Error) { $loginNodes = $lm.Nodes }
                        else { $loginMatchError = Get-TcPlcMatchErrorText -Reasons $lm.Error -Consequence 'the login state is not read' }
                    }
                    $states = [System.Collections.Generic.List[object]]::new()
                    for ($i = 0; $i -lt $projects.Count; $i++) {
                        $pj = $projects[$i]
                        if ($pj.status -eq 'skipped' -or $pj.status -eq 'disabled') { continue }
                        $node = $null
                        if ($null -ne $loginNodes -and $i -lt $loginNodes.Count) { $node = $loginNodes[$i] }
                        # an entry the match left without a node: by name, but never a node already
                        # assigned to another entry (the same PLC would be read twice)
                        if ($null -eq $node -and $null -ne $loginNodes) {
                            $free = @($loginPlcList | Where-Object { $n = $_; @($loginNodes | Where-Object { [object]::ReferenceEquals($_, $n) }).Count -eq 0 })
                            $node = Find-TcPlcProject -List $free -Spec ([string]$pj.name)
                            # Find-TcPlcProject builds an entry from a 'TIPC^..' spec when the list is empty;
                            # a bare name never matches that, so $null stays $null
                        }
                        if ($null -eq $node) {
                            $why = if ($null -ne $loginListError) { "PLC project list not readable ($loginListError)" }
                                   elseif ($null -ne $loginMatchError) { $loginMatchError }
                                   else { "no PLC tree item (not already matched to another .plcproj entry) matches the .plcproj entry '$($pj.uniqueName)'" }
                            $states.Add([PSCustomObject]@{ plc = [string]$pj.name; loggedIn = $null; source = $null; error = $why })
                            continue
                        }
                        $states.Add((Get-TcPlcLoginState -SysManager $sm -Plc $node))
                    }
                    $plcLoginState = @($states)
                    $loggedInPlcs = @($plcLoginState | Where-Object { $_.loggedIn -eq $true } | ForEach-Object { $_.plc })
                }
            }
            $data.plcLoginState = $plcLoginState
            # loggedIn $false never rules the runtime-log evidence out: a false read while logged in was never
            # measured (IsLoggedIn never read back a bool on 4026 VS2022; 4024 logged in not measured), so it
            # is not trusted enough to drop the Logout hint (fail closed, #188 review). It is only reported.
            $loginText = if ($null -eq $plcLoginState) { 'not read' } else { (@($plcLoginState | ForEach-Object { "$($_.plc)=$(if ($null -eq $_.loggedIn) { 'unknown' } else { ([string]$_.loggedIn).ToLowerInvariant() })" }) -join ', ') }
            if ($noErrorRow -and $loggedInPlcs.Count -gt 0) {
                # appended, the summary above is kept (review #150 round 3 M1)
                $summary += ". XAE listed no compiler error row at all and PLC project(s) $($loggedInPlcs -join ', ') are logged in (data.plcLoginState): XAE does not compile while the PLC is logged in (#188, 實測 2026-11-08: the real errors appear after PlcLogout)"
                $buildHint = Get-TcErrorHint -Code 'BUILD_FAILED_PLC_ONLINE'
                $data.plcOnlineSuspected = $true
                $data.plcOnlineEvidence = 'login-state'
                $data.codeVerified = $null
            }
            elseif ($noErrorRow -and $allUnknown -and @($els.runtimeMessages).Count -gt 0) {
                # #66 / O9: no PLC read back as logged in, but runtime / system log rows are present
                $summary += ". XAE listed no compiler error row at all: the PLC is probably logged in, so XAE probably did not compile (#66, 實測 2026-11-06: no compile while logged in, the real errors appear after PlcLogout); no error row names a PLC project; PLC login state: $loginText (data.plcLoginState)"
                $buildHint = Get-TcErrorHint -Code 'BUILD_FAILED_PLC_ONLINE'
                $data.plcOnlineSuspected = $true
                $data.plcOnlineEvidence = 'runtime-log'
                # O12: XAE did not compile, so a clean Error List proves nothing
                $data.codeVerified = $null
            }
            elseif ($noErrorRow) {
                $summary += ". XAE listed no error row at all, so it does not show why the build failed and the PLC code is not verified; PLC login state: $loginText (data.plcLoginState)"
            }
            & $recordUnverified 'BUILD_FAILED' $data
            New-TcResult -Success $false -ErrorMessage $summary -ErrorCode 'BUILD_FAILED' -Hint $buildHint -Data $data
        }
        else {
            # -ExpectedProject: each one must have been built (skipped was refused before the build)
            $notBuilt = @($expected | ForEach-Object {
                $e = Find-TcBuildCoverageEntry -Projects $projects -Name $_
                if ($null -eq $e -or $e.status -ne 'built') { $_ }
            })
            if ($notBuilt.Count -gt 0) {
                & $recordUnverified 'BUILD_COVERAGE_UNKNOWN' $data
                return New-TcResult -Success $false -ErrorMessage "Build finished but expected PLC project(s) $($notBuilt -join ', ') were not confirmed as built (see data.projects)." `
                    -ErrorCode 'BUILD_COVERAGE_UNKNOWN' -Hint (Get-TcErrorHint -Code 'BUILD_COVERAGE_UNKNOWN') -Data $data
            }
            # The build that Enable-TcConfig waits for after a platform switch (BUILD_REQUIRED) must
            # prove that every PLC project was compiled: coverageComplete (none skipped, the project
            # list was read, the solution has PLC projects) and codeVerified. A skipped PLC project
            # may still have the output of the previous platform (inferred, not measured). There is
            # no exception (#61): a build accepted with -AllowUnresolvedLibrary has codeVerified =
            # $false, so it is NOT complete and records 'unverified-build' below - otherwise the
            # platform-fix-build of Enable-TcConfig cleared BUILD_REQUIRED and activated, downloaded
            # and started code nobody had proven compiled (measured 2026-10-28, TcXaeShell 4024,
            # BFH-1650 copy with an injected unresolved library, local UmRT).
            $completeBuild = [bool]($coverageComplete -and ($codeVerified -eq $true))
            $data | Add-Member -NotePropertyName 'completeBuild' -NotePropertyValue $completeBuild
            if ($completeBuild) {
                $cw = Clear-TcBuildRequired
                if (-not [string]::IsNullOrWhiteSpace([string]$cw)) { $data | Add-Member -NotePropertyName 'stateWarning' -NotePropertyValue ([string]$cw) -Force }
            }
            else {
                $wcText = @($(if ($null -ne $data.PSObject.Properties['warningCodes']) { $data.warningCodes } else { @() })) -join ', '
                & $recordUnverified "success with completeBuild=false, warningCodes=[$wcText]" $data
            }
            # Why a successful build did not count, for the BUILD_REQUIRED message of Enable-TcConfig
            $script:TcLastBuildVerdict = [PSCustomObject]@{
                solution         = [string]$script:TcSolutionPath
                at               = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
                completeBuild    = $completeBuild
                codeVerified     = $codeVerified
                coverageComplete = $coverageComplete
                warningCodes     = @($(if ($null -ne $data.PSObject.Properties['warningCodes']) { $data.warningCodes } else { @() }))
            }
            New-TcResult -Success $true -Data $data
        }
    }
    catch {
        $errData = $null
        if ($null -ne $script:TcLastModalDialog) {
            $errData = [PSCustomObject]@{ dialogTitle = [string]$script:TcLastModalDialog.Title; dialogText = [string]$script:TcLastModalDialog.Text }
        }
        $res = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_FAILED' -MessagePrefix 'Build failed' -Data $errData
        if ($null -eq $res.data) { $res | Add-Member -NotePropertyName 'data' -NotePropertyValue ([PSCustomObject]@{}) -Force }
        $code = if ($null -ne $res.error) { [string]$res.error.code } else { 'BUILD_FAILED' }
        try { & $recordUnverified "$code, exception during the build" $res.data } catch { Write-Verbose "Build-TcProject: BUILD_REQUIRED not recorded ($($_.Exception.Message))" }
        $res
    }
}
