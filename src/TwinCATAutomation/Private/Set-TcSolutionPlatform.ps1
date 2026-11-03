function Set-TcSolutionPlatform {
    <#
    .SYNOPSIS
        Activates the solution configuration '<Configuration>|<Platform>' of the connected
        IDE (shared by Set-TcTarget and Enable-TcConfig) after checking that the TwinCAT
        project really builds for that platform under it. Never throws.
    .DESCRIPTION
        1. Get-TcSolutionConfigurations lists every configuration with its real SOLUTION
           platform (SolutionConfiguration2.PlatformName, or the .sln by index) and the
           PROJECT platform of every project (SolutionContext.PlatformName). The item whose
           Name is -Configuration and whose solution platform is -Platform (case-insensitive)
           is the match (data.platformMatchedBy = 'solutionPlatform'). When no item with a
           known solution platform matches, items whose solution platform is unknown are
           candidates when the project platform of their first context is -Platform (the old
           behaviour; data.platformMatchedBy = 'projectPlatform'); several candidates are
           tried one after the other and each is verified by the readback (step 4).
           No match -> PLATFORM_NOT_FOUND (data.availablePlatforms = solution platform names).
        2. Project check (also when the target is already the active configuration): every
           .tsproj context of the match must have project platform -Platform. A solution
           platform name can map to a project platform with another name (e.g. solution
           'Release|TwinCAT OS (x64)' -> project 'TwinCAT OS (ARMT2)', ShouldBuild=False);
           activating it would build nothing for the target. Mismatch -> nothing is
           activated, PLATFORM_PROJECT_MISMATCH (data.projectCheck = 'mismatch').
           No .tsproj context at all (nothing to compare; the TwinCAT project is what
           decides the target platform): allowed, data.projectCheck = 'no-tsproj'.
           Otherwise data.projectCheck = 'ok'. The target platform decides what the
           configuration is compiled for, the Configuration Manager whether a sub-project
           is built: InfoSys "Setting the TwinCAT target platform"
           https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html
        3. SolutionConfiguration.Activate() unless the target is already active. No deadline
           runspace: the call returns synchronously within ~30 ms and opens no dialog
           (實測 2026-10-22, TcXaeShell.DTE.15.0 and VisualStudio.DTE.17.0, TwinCAT
           3.1.4026.22); Invoke-TcComRetry handles a busy IDE.
        4. Readback (polled; one budget of 3 s + 1 s per candidate; the switch is synchronous,
           so normally the first read). The solution platform Get-TcSolutionPlatform reads back
           must be -Platform, whatever the match was based on; a readback without any source
           (platformSource $null) never passes. The projectPlatform (.tsproj) must be -Platform
           too (unless 'no-tsproj'). Activate() throwing stops the loop: the readback and the
           restore below still run and the mapped error code (IDE_BUSY ...) is returned. A failed readback of an unknown-platform candidate moves
           on to the next candidate; when none passes, the configuration that was active
           before is re-activated (data.restored) and PLATFORM_SET_FAILED returned. When
           nothing was switched (already active) data.restored stays $null.
        Build selection (#67), between steps 2 and 3 and after step 4: on 4026 the PLC Disabled
        flag (ITcSmTreeItem.Disabled, .tsproj Disabled="true") mirrors whether the ACTIVE
        solution configuration has a Build.0 for that PLC (SolutionContext.ShouldBuild); XAE's
        Disable removes only the active configuration's Build.0, and a platform switch makes
        Disabled follow the ShouldBuild of the new configuration (實測 2026-11-03, 4026 VS2022 +
        TcXaeShell 64-bit, verification/issue67-realmachine.md). ShouldBuild is per configuration
        (InfoSys "Setting the TwinCAT target platform"
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/650882187.html). So a PLC
        disabled under one platform would be built, downloaded and started under another.
          before   Get-TcBuildSelectionState reads the active configuration: ShouldBuild of every
                   .plcproj context (Get-TcBuildCoverage) and Disabled of every PLC tree item
                   (Get-TcPlcProjectList), matched like Build-TcProject (#104,
                   Resolve-TcPlcCoverageNodes: .plcproj path, then name, one to one) - the match
                   is required only when a PLC tree item is disabled. Every .plcproj context of
                   the candidate (same configuration name, the requested platform; the
                   Get-TcSolutionConfigurations item that Activate() would select) is compared
                   with it by project unique name: target ShouldBuild <> current ShouldBuild is a
                   change, and so is a PLC that is disabled now and that the target builds
                   (fail closed, also when its current ShouldBuild is true). A candidate with a
                   change is not activated; no candidate left -> BUILD_SELECTION_CHANGED
                   (data.buildSelectionChanges; preferred over BUILD_SELECTION_UNKNOWN when any
                   candidate has a change), nothing switched. Data not readable (contexts, the
                   TwinCAT project, the PLC tree, a context missing or duplicated under the
                   candidate, ShouldBuild or Disabled not a real bool ($null), PLC tree items
                   without .plcproj context, a disabled tree item without a one-to-one match) ->
                   BUILD_SELECTION_UNKNOWN (IDE_CRASHED / IDE_MODAL_DIALOG / IDE_BUSY keep their
                   code), nothing switched. No .plcproj context and no PLC tree item: nothing
                   to compare, the switch goes on (data.buildSelection = @()).
          after    after a switch that read back correctly, ShouldBuild of every .plcproj context
                   and Disabled of every PLC tree item are read again and compared with before.
                   Different or not readable -> the previous configuration is re-activated
                   (data.restored) and BUILD_SELECTION_CHANGED / BUILD_SELECTION_UNKNOWN returned
                   (IDE_BUSY / IDE_CRASHED / IDE_MODAL_DIALOG of the readback keep their code).
          guard    when that re-activation fails (data.restored = $false) the IDE stays at a
                   configuration whose build selection differs: BUILD_REQUIRED kind
                   'build-selection' is recorded (Set-TcBuildSelectionGuard, with the previous
                   configuration and the changed PLCs), the hint says so, and Build-TcProject /
                   Enable-TcConfig refuse with BUILD_SELECTION_CHANGED until it is cleared. A
                   switch to the previous configuration is always allowed (no build selection
                   block, the readback is only reported); the guard is cleared when the active
                   configuration is the previous one after a successful call (switched back, or
                   already active after a manual switch in XAE).
        Already active: nothing is switched; data.buildSelection is read best effort (no error).
        A candidate left out because of the build selection is named in the PLATFORM_SET_FAILED
        message when the remaining candidates fail.
    .PARAMETER Platform
        Solution platform to activate.
    .PARAMETER Configuration
        Solution configuration name. Default 'Release'.
    .PARAMETER PlatformSource
        Where -Platform came from (e.g. 'target (registryDeviceType)'); only used in the
        PLATFORM_NOT_FOUND message / hint.
    .OUTPUTS
        [PSCustomObject]@{
            success; error (@{ message; code; hint } or $null);
            configuration; previousPlatform; platform; platformChanged;
            projectPlatform (project platform of the .tsproj ACTIVE after the call: the new
                             one after a switch, the unchanged one after an error, the restored
                             one after a restore; $null when there is no .tsproj context);
            requestedProjectPlatform (project platform of the .tsproj under the requested
                             solution platform; $null when none / no match);
            projectCheck ('ok' | 'mismatch' | 'no-tsproj' | $null when no match);
            platformMatchedBy ('solutionPlatform' | 'projectPlatform' | $null);
            platformMap (solution platform -> @{ solutionPlatform; solutionPlatformSource;
                         projectPlatforms = @(@{ project; platform; shouldBuild }) } for every
                         item of -Configuration);
            restored ($true/$false after a failed readback of a switch, else $null);
            buildSelection (@() when there is no PLC project; $null when not read) = @(@{
                plc (PLC tree name, else the .plcproj name); project (SolutionContext unique name);
                nodePath ($null without tree item); configuration ('<Configuration>|<Platform>',
                the target); current = @{ configuration; shouldBuild; disabled };
                target = @{ shouldBuild }; after = @{ shouldBuild; disabled } ($null until read
                back); changed });
            buildSelectionChanges (the buildSelection items with changed = $true, plus PLC tree
                items without .plcproj context whose Disabled changed; @() otherwise);
            availablePlatforms; availableConfigurations }
        error.code: PLATFORM_NOT_FOUND, PLATFORM_PROJECT_MISMATCH, PLATFORM_SET_FAILED
        (activation failed or not visible afterwards), BUILD_SELECTION_CHANGED,
        BUILD_SELECTION_UNKNOWN, or a mapped COM code (IDE_BUSY, IDE_CRASHED, ...).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Platform,

        [Parameter()]
        [string]$Configuration = 'Release',

        [Parameter()]
        [string]$PlatformSource
    )

    $reliableSources = @('ActiveConfig', 'PlatformName')
    $before = Get-TcSolutionPlatform
    $out = [PSCustomObject]@{
        success                  = $false
        error                    = $null
        configuration            = $Configuration
        previousPlatform         = $before.platform
        platform                 = $before.platform
        platformChanged          = $false
        projectPlatform          = $before.projectPlatform
        requestedProjectPlatform = $null
        projectCheck             = $null
        platformMatchedBy        = $null
        platformMap              = $null
        restored                 = $null
        buildSelection           = $null
        buildSelectionChanges    = @()
        stateWarning             = $null   # BUILD_REQUIRED kept in memory only (Set-TcBuildRequired)
        availablePlatforms       = @()
        availableConfigurations  = @()
    }

    $configs = @()
    try {
        $configs = @(Get-TcSolutionConfigurations)
    }
    catch {
        $out.error = (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PLATFORM_SET_FAILED' -MessagePrefix 'Reading the solution configurations failed').error
        return $out
    }

    $res = Resolve-TcPlatformTarget -Configs $configs -Platform $Platform -Configuration $Configuration
    $sameConfig = $res.SameConfig
    $available = $res.Available
    $availableConfigs = $res.AvailableConfigs
    $out.availablePlatforms = $available
    $out.availableConfigurations = $availableConfigs
    $out.platformMap = $res.PlatformMap

    $candidates = @($res.Candidates)
    $alreadyActive = ($reliableSources -contains [string]$before.platformSource) -and ([string]$before.platform -ieq $Platform) -and ([string]$before.configuration -ieq $Configuration)

    if ($candidates.Count -eq 0 -and -not $alreadyActive) {
        $availText = if ($available.Count -gt 0) { "'" + ($available -join "', '") + "'" } else { '(none)' }
        $from = if ([string]::IsNullOrWhiteSpace($PlatformSource)) { '' } else { " (platform reported by the $PlatformSource)" }
        $msg = "Solution platform '$Platform'$from not found for configuration '$Configuration'. Available solution platforms: $availText."
        if ($sameConfig.Count -eq 0) { $msg += " No configuration named '$Configuration'; available configurations: '" + ($availableConfigs -join "', '") + "'." }
        $hint = Get-TcErrorHint -Code 'PLATFORM_NOT_FOUND'
        $hint = "$hint Available: $availText."
        if (-not [string]::IsNullOrWhiteSpace($PlatformSource)) {
            $hint += " '$Platform' was read from the target ($PlatformSource), not typed by you: the solution has no solution platform of that name. Add it in the Configuration Manager with the TwinCAT project (.tsproj) and PLC project mapped to project platform '$Platform', or pass -Platform / -NoPlatformSwitch (Set-TcTarget), -NoPlatformFix (Enable-TcConfig) to skip the automatic switch."
        }
        $out.error = [PSCustomObject]@{ message = $msg; code = 'PLATFORM_NOT_FOUND'; hint = $hint }
        return $out
    }
    $out.platformMatchedBy = if ($candidates.Count -gt 0) { $candidates[0].MatchedBy } else { 'solutionPlatform' }

    # --- project check (before Activate, also when already active) ---
    # Already active with only unknown-platform candidates: the active .tsproj is what counts.
    $checkItems = if ($alreadyActive -and ($candidates.Count -eq 0 -or $candidates[0].MatchedBy -eq 'projectPlatform')) { $null } else { $candidates }
    $badText = $null
    if ($null -eq $checkItems) {
        $out.requestedProjectPlatform = $before.projectPlatform
        if ([string]::IsNullOrWhiteSpace([string]$before.projectPlatform)) { $out.projectCheck = 'no-tsproj' }
        elseif ([string]$before.projectPlatform -ieq $Platform) { $out.projectCheck = 'ok' }
        else { $out.projectCheck = 'mismatch'; $badText = ".tsproj -> '$($before.projectPlatform)'" }
    }
    else {
        $pc = Test-TcCandidateProjects -Candidates $checkItems -Platform $Platform
        $out.projectCheck = $pc.ProjectCheck
        $out.requestedProjectPlatform = $pc.RequestedProjectPlatform
        $badText = $pc.BadText
        if ($pc.ProjectCheck -ne 'mismatch') { $candidates = @($pc.Passing) }
    }
    if ($out.projectCheck -eq 'mismatch') {
        $out.error = New-TcProjectMismatchError -SameConfig $sameConfig -Platform $Platform -Configuration $Configuration -BadText $badText
        return $out
    }

    # --- build selection (#67): before Activate; a candidate that would change it is not used ---
    $targetLabel = "$Configuration|$Platform"
    $beforeLabel = if ([string]::IsNullOrWhiteSpace([string]$before.configuration)) { [string]$before.platform } else { "$($before.configuration)|$($before.platform)" }
    # guard (#67): an earlier switch left the IDE at a configuration with a changed build selection
    # and could not switch back; switching to the configuration it came from is always allowed
    $guard = Get-TcBuildSelectionGuard
    $returning = ($null -ne $guard -and -not [string]::IsNullOrWhiteSpace([string]$guard.previous) -and [string]$guard.previous -ieq $targetLabel)
    $selState = Get-TcBuildSelectionState -ConfigurationLabel $beforeLabel
    $selByIndex = @{}
    $excluded = @()
    if ($alreadyActive) {
        # nothing is switched: informational only, never an error
        if ($null -eq $selState.Error) {
            $out.buildSelection = @($selState.Entries | ForEach-Object {
                    $cur = [PSCustomObject]@{ configuration = $beforeLabel; shouldBuild = $_.shouldBuild; disabled = $_.disabled }
                    [PSCustomObject]@{ plc = $_.plc; project = $_.project; nodePath = $_.nodePath; configuration = $targetLabel; current = $cur
                        target = [PSCustomObject]@{ shouldBuild = $_.shouldBuild }; after = [PSCustomObject]@{ shouldBuild = $_.shouldBuild; disabled = $_.disabled }; changed = $false }
                })
        }
    }
    else {
        if ($null -ne $selState.Error) {
            $out.error = [PSCustomObject]@{
                message = "Build selection of '$beforeLabel' could not be read, so the switch to '$targetLabel' could not be checked for PLC projects that would start or stop being built; nothing was switched: $([string]$selState.Error.message)"
                code    = [string]$selState.Error.code
                hint    = $(if ([string]$selState.Error.code -eq 'BUILD_SELECTION_UNKNOWN') { Get-TcErrorHint -Code 'BUILD_SELECTION_UNKNOWN' } else { [string]$selState.Error.hint })
            }
            return $out
        }
        if (@($selState.Entries).Count -eq 0) { $out.buildSelection = @() }
        else {
            $keep = @()
            $first = $null
            $firstChanged = $null
            foreach ($cand in $candidates) {
                $cmp = Compare-TcBuildSelection -State $selState -Candidate $cand -TargetLabel $targetLabel
                if ($null -eq $first) { $first = $cmp }
                if ($null -eq $cmp.Error -and @($cmp.Changes).Count -gt 0 -and $null -eq $firstChanged) { $firstChanged = $cmp }
                $selByIndex[[int]$cand.Index] = $cmp
                if ($null -eq $cmp.Error -and (@($cmp.Changes).Count -eq 0 -or $returning)) { $keep += $cand }
                else {
                    $why = if ($null -ne $cmp.Error) { "not comparable ($([string]$cmp.Error))" } else { Format-TcBuildSelectionChanges -Changes $cmp.Changes }
                    $excluded += [PSCustomObject]@{ Text = "#$($cand.Index): $why"; Changes = @($cmp.Changes) }
                }
            }
            if ($keep.Count -eq 0) {
                # a candidate with a real change wins over one that could not be compared (N2)
                if ($null -ne $firstChanged) { $first = $firstChanged }
                $out.buildSelection = @($first.Items)
                $out.buildSelectionChanges = @($first.Changes)
                if ($null -eq $firstChanged) {
                    $out.error = [PSCustomObject]@{
                        message = "Build selection under '$targetLabel' could not be compared with '$beforeLabel'; nothing was switched: $([string]$first.Error)"
                        code    = 'BUILD_SELECTION_UNKNOWN'
                        hint    = (Get-TcErrorHint -Code 'BUILD_SELECTION_UNKNOWN')
                    }
                    return $out
                }
                $out.error = [PSCustomObject]@{
                    message = "Switching from '$beforeLabel' to '$targetLabel' would change which PLC projects are built: $(Format-TcBuildSelectionChanges -Changes $first.Changes). On 4026 a PLC is disabled only in the configuration it was disabled in (measured 2026-11-03, 4026 VS2022 + TcXaeShell 64-bit); nothing was switched (data.buildSelectionChanges)."
                    code    = 'BUILD_SELECTION_CHANGED'
                    hint    = (Get-TcErrorHint -Code 'BUILD_SELECTION_CHANGED')
                }
                return $out
            }
            $candidates = @($keep)
            $out.buildSelection = @($selByIndex[[int]$candidates[0].Index].Items)
            if ($returning) { $out.buildSelectionChanges = @($selByIndex[[int]$candidates[0].Index].Changes) }
        }
    }

    # Readback check: the solution platform read back must be -Platform whatever the match was
    # based on ('ActiveConfig' / 'PlatformName'; 'context' = the old project-platform reading,
    # compared as well); nothing readable (platformSource $null) never passes. The active
    # .tsproj must be built for -Platform too (unless 'no-tsproj').
    $requireProj = ($out.projectCheck -ne 'no-tsproj')
    $isOk = {
        param($a)
        if ([string]::IsNullOrWhiteSpace([string]$a.platformSource)) { return $false }
        $solOk = ([string]$a.platform -ieq $Platform)
        $projOk = (-not $requireProj) -or ([string]$a.projectPlatform -ieq $Platform)
        $solOk -and $projOk
    }

    if ($alreadyActive) {
        $after = Get-TcSolutionPlatform
        $out.platform = $after.platform
        $out.projectPlatform = $after.projectPlatform
        if (-not (& $isOk $after)) {
            $out.error = [PSCustomObject]@{
                message = "Solution configuration '$Configuration|$Platform' is already active but reads back as solution platform '$($after.platform)' / project platform '$($after.projectPlatform)'; nothing was switched."
                code    = 'PLATFORM_SET_FAILED'
                hint    = (Get-TcErrorHint -Code 'PLATFORM_SET_FAILED')
            }
            return $out
        }
        if (-not [string]::IsNullOrWhiteSpace($after.configuration)) { $out.configuration = $after.configuration }
        # already at the configuration the guard came from (switched back by hand in XAE)
        if ($null -ne $guard -and [string]$guard.previous -ieq "$($after.configuration)|$($after.platform)") { $out.stateWarning = Clear-TcBuildSelectionGuard }
        $out.success = $true
        return $out
    }

    $prevCom = $null
    try { $prevCom = Invoke-TcComRetry -MaxRetries 2 -OperationName 'SolutionBuild.ActiveConfiguration' -ScriptBlock { $script:TcDte.Solution.SolutionBuild.ActiveConfiguration } }
    catch { $prevCom = $null }

    $after = $before
    $tried = @()
    $activateError = $null
    # One readback budget for all candidates: 3 s + 1 s per candidate (the switch is synchronous,
    # 實測 2026-10-22, so a correct switch normally passes on the first read).
    $deadline = (Get-Date).AddSeconds(3 + $candidates.Count)
    foreach ($cand in $candidates) {
        try {
            Invoke-TcComRetry -OperationName 'SolutionConfiguration.Activate' -ScriptBlock { $cand.Com.Activate() } | Out-Null
        }
        catch {
            # Stop trying; fall through to the readback + restore below with this error code.
            $activateError = (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PLATFORM_SET_FAILED' -MessagePrefix "Activating '$Configuration|$Platform' (#$($cand.Index)) failed").error
            $after = Get-TcSolutionPlatform
            $tried += "#$($cand.Index) -> Activate() failed"
            break
        }
        while ($true) {
            $after = Get-TcSolutionPlatform
            if (& $isOk $after) { break }
            # A reliably read, different solution platform is a definite answer for an
            # unknown-platform candidate (the switch is synchronous): try the next one.
            if ($cand.MatchedBy -eq 'projectPlatform' -and ($reliableSources -contains [string]$after.platformSource)) { break }
            if ((Get-Date) -ge $deadline) { break }
            Start-Sleep -Milliseconds 100
        }
        $tried += "#$($cand.Index) -> '$($after.configuration)|$($after.platform)' / project '$($after.projectPlatform)'"
        if (& $isOk $after) { break }
    }
    $out.platform = $after.platform
    $out.projectPlatform = $after.projectPlatform
    $out.platformChanged = (-not ([string]$before.platform -ieq [string]$after.platform)) -or (-not ([string]$before.configuration -ieq [string]$after.configuration))

    # Re-activates the configuration that was active before (failed readback, build selection
    # changed); sets $out.platform / projectPlatform / platformChanged / restored, returns the text.
    $restore = {
        $restoredOk = $false
        if ($null -ne $prevCom) {
            try {
                Invoke-TcComRetry -OperationName 'SolutionConfiguration.Activate (restore)' -ScriptBlock { $prevCom.Activate() } | Out-Null
                $back = Get-TcSolutionPlatform
                $restoredOk = ([string]$back.platform -ieq [string]$before.platform) -and ([string]$back.configuration -ieq [string]$before.configuration)
                $out.platform = $back.platform
                $out.projectPlatform = $back.projectPlatform
                $out.platformChanged = -not $restoredOk
            }
            catch { $restoredOk = $false }
        }
        $out.restored = $restoredOk
        if ($out.platformChanged) {
            # switch failed AND the previous configuration could not be restored: the active
            # platform is not the one the last build was made for
            $out.stateWarning = Set-TcBuildRequired -Reason "solution platform left at '$($out.platform)' (was '$($before.configuration)|$($before.platform)') after a failed switch to '$Configuration|$Platform' that could not be undone"
        }
        if ($restoredOk) { " The previous configuration '$($before.configuration)|$($before.platform)' was re-activated." } else { ' The previous configuration could not be restored.' }
    }

    if ($null -ne $activateError -or -not (& $isOk $after)) {
        $restoreText = & $restore
        if ($excluded.Count -gt 0) {
            $restoreText += " Not tried because of the build selection (#67, data.buildSelectionChanges): $(($excluded | ForEach-Object { $_.Text }) -join '; ')."
            $out.buildSelectionChanges = @($excluded | ForEach-Object { $_.Changes })
        }
        if ($null -ne $activateError) {
            $hp = $activateError.PSObject.Properties['hint']
            $out.error = [PSCustomObject]@{
                message = "$([string]$activateError.message) (tried: $($tried -join '; ')).$restoreText"
                code    = [string]$activateError.code
                hint    = $(if ($null -ne $hp) { [string]$hp.Value } else { $null })
            }
            return $out
        }
        $out.error = [PSCustomObject]@{
            message = "Solution configuration '$Configuration|$Platform' was activated but does not read back as solution platform '$Platform' with a .tsproj built for it (tried: $($tried -join '; ')).$restoreText"
            code    = 'PLATFORM_SET_FAILED'
            hint    = (Get-TcErrorHint -Code 'PLATFORM_SET_FAILED')
        }
        return $out
    }
    # --- build selection read back (#67): Disabled follows the new configuration's Build.0 ---
    $selCmp = $selByIndex[[int]$cand.Index]
    if ($null -ne $selCmp) {
        $out.buildSelection = @($selCmp.Items)
        $chk = Test-TcBuildSelectionAfter -State $selState -Items $selCmp.Items
        if ($returning) {
            # back to the configuration the guard came from: a selection that differs from the
            # (changed) one before is expected; reported only
            $out.buildSelectionChanges = @($chk.Changes)
        }
        elseif ($null -ne $chk.Error -or @($chk.Changes).Count -gt 0) {
            $out.buildSelectionChanges = @($chk.Changes)
            $leftAt = "$Configuration|$Platform"
            $restoreText = & $restore
            $changeText = if ($null -ne $chk.Error) { "not readable: $([string]$chk.Error)" } else { Format-TcBuildSelectionChanges -Changes $chk.Changes -After }
            $hint = $null
            if ($out.restored -ne $true) {
                # IDE stays at the target with a build selection nobody chose: guard (#67 S1)
                $gw = Set-TcBuildSelectionGuard -Previous $beforeLabel -Left $leftAt -Changes $changeText
                if (-not [string]::IsNullOrWhiteSpace([string]$gw)) { $out.stateWarning = (@($out.stateWarning, $gw) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' ' }
                $hint = Get-TcBuildSelectionStuckHint -Previous $beforeLabel -Left $leftAt -Changes $changeText
            }
            if ($null -ne $chk.Error) {
                $code = if ([string]::IsNullOrWhiteSpace([string]$chk.ErrorCode)) { 'BUILD_SELECTION_UNKNOWN' } else { [string]$chk.ErrorCode }
                if ($null -eq $hint) { $hint = if ($code -eq 'BUILD_SELECTION_UNKNOWN' -or [string]::IsNullOrWhiteSpace([string]$chk.ErrorHint)) { Get-TcErrorHint -Code 'BUILD_SELECTION_UNKNOWN' } else { [string]$chk.ErrorHint } }
                $out.error = [PSCustomObject]@{
                    message = "Switched to '$targetLabel', but the build selection could not be read back ($([string]$chk.Error)).$restoreText"
                    code    = $code
                    hint    = $hint
                }
            }
            else {
                if ($null -eq $hint) { $hint = Get-TcErrorHint -Code 'BUILD_SELECTION_CHANGED' }
                $out.error = [PSCustomObject]@{
                    message = "Switched to '$targetLabel', but the build selection read back differs from '$beforeLabel': $changeText.$restoreText"
                    code    = 'BUILD_SELECTION_CHANGED'
                    hint    = $hint
                }
            }
            return $out
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($after.configuration)) { $out.configuration = $after.configuration }
    if ($out.platformChanged) {
        # The compiled output may still belong to the previous platform (inferred, not
        # measured): Enable-TcConfig refuses to activate until a complete Build-TcProject
        # success (BUILD_REQUIRED, state file: Private/Set-TcBuildRequired.ps1).
        $out.stateWarning = Set-TcBuildRequired -Reason "solution platform switched from '$($before.configuration)|$($before.platform)' to '$($out.configuration)|$($out.platform)'"
    }
    # switched back to the configuration the guard came from (#67): the build selection is that
    # configuration's again
    if ($null -ne $guard -and [string]$guard.previous -ieq "$($out.configuration)|$($out.platform)") {
        $cw = Clear-TcBuildSelectionGuard
        if (-not [string]::IsNullOrWhiteSpace([string]$cw)) { $out.stateWarning = (@($out.stateWarning, $cw) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ' ' }
    }
    $out.success = $true
    return $out
}

function Resolve-TcPlatformTarget {
    <#
    .SYNOPSIS
        Read-only part of the solution platform switch, shared by Set-TcSolutionPlatform and
        Enable-TcConfig -NoPlatformFix: match names, platformMap and the candidates for
        '<Configuration>|<Platform>'. Never touches the IDE.
    .OUTPUTS
        @{ SameConfig; Available (solution platform names of -Configuration); AvailableConfigs;
           PlatformMap; Candidates (the item with that known solution platform, else the
           unknown-platform items whose first-context project platform has that name) }
        Every item of -Configs gets MatchPlatform / MatchedBy ('solutionPlatform' |
        'projectPlatform') note properties.
    #>
    param([object[]]$Configs, [string]$Platform, [string]$Configuration)
    # Name used for matching: the solution platform, or (unknown) the old project-platform reading.
    foreach ($c in @($Configs)) {
        $eff = $c.SolutionPlatform
        $by = 'solutionPlatform'
        if ($c.SolutionPlatformSource -eq 'unknown') {
            $eff = $null
            foreach ($ctx in @($c.Contexts)) { $eff = [string]$ctx.PlatformName; break }
            $by = 'projectPlatform'
        }
        $c | Add-Member -NotePropertyName 'MatchPlatform' -NotePropertyValue $eff -Force
        $c | Add-Member -NotePropertyName 'MatchedBy' -NotePropertyValue $by -Force
    }
    $sameConfig = @(@($Configs) | Where-Object { [string]$_.Name -ieq $Configuration })
    $available = @($sameConfig | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.MatchPlatform) } | ForEach-Object { [string]$_.MatchPlatform } | Select-Object -Unique)
    $availableConfigs = @(@($Configs) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Name) } | ForEach-Object { [string]$_.Name } | Select-Object -Unique)

    # platformMap: every solution platform of -Configuration -> project platforms below it.
    $map = [ordered]@{}
    foreach ($c in $sameConfig) {
        $key = if ([string]::IsNullOrWhiteSpace([string]$c.MatchPlatform)) { "<unknown #$($c.Index)>" } else { [string]$c.MatchPlatform }
        if ($map.Contains($key)) { $key = "$key (#$($c.Index))" }
        $projs = @(@($c.Contexts) | ForEach-Object {
                [PSCustomObject]@{ project = [string]$_.ProjectName; platform = [string]$_.PlatformName; shouldBuild = $_.ShouldBuild }
            })
        $map[$key] = [PSCustomObject]@{
            solutionPlatform       = $c.SolutionPlatform
            solutionPlatformSource = $c.SolutionPlatformSource
            projectPlatforms       = $projs
        }
    }

    # Candidates: the item with that known solution platform, else unknown-platform items whose
    # project platform has that name (old behaviour, each one verified by the readback).
    $candidates = @($sameConfig | Where-Object { $_.MatchedBy -eq 'solutionPlatform' -and [string]$_.MatchPlatform -ieq $Platform } | Select-Object -First 1)
    if ($candidates.Count -eq 0) {
        $candidates = @($sameConfig | Where-Object { $_.MatchedBy -eq 'projectPlatform' -and [string]$_.MatchPlatform -ieq $Platform })
    }
    [PSCustomObject]@{
        SameConfig       = $sameConfig
        Available        = $available
        AvailableConfigs = $availableConfigs
        PlatformMap      = [PSCustomObject]$map
        Candidates       = $candidates
    }
}

function Test-TcCandidateProjects {
    <#
    .SYNOPSIS
        .tsproj check of switch candidates: every .tsproj context must have project platform
        -Platform. A candidate without any .tsproj context passes (nothing to compare against,
        e.g. a host that hides SolutionContexts; projectCheck 'no-tsproj').
    .OUTPUTS
        @{ Passing; ProjectCheck ('ok' | 'mismatch' | 'no-tsproj'); RequestedProjectPlatform;
           BadText (first failing .tsproj -> platform list) }
    #>
    param([object[]]$Candidates, [string]$Platform)
    $passing = @()
    $firstBad = $null
    $anyTs = $false
    $requested = $null
    foreach ($c in @($Candidates)) {
        $tsCtx = Select-TcTsprojContext -Contexts $c.Contexts -All
        if ($tsCtx.Count -eq 0) { $passing += $c; continue }
        $anyTs = $true
        if ($null -eq $requested) { $requested = [string]$tsCtx[0].PlatformName }
        $bad = @($tsCtx | Where-Object { -not ([string]$_.PlatformName -ieq $Platform) })
        if ($bad.Count -eq 0) { $passing += $c }
        elseif ($null -eq $firstBad) { $firstBad = ($bad | ForEach-Object { "$($_.ProjectName) -> '$($_.PlatformName)'" }) -join ', ' }
    }
    $check = $null
    if ($passing.Count -eq 0) { $check = 'mismatch' }
    else {
        $ts0 = Select-TcTsprojContext -Contexts $passing[0].Contexts
        if ($null -ne $ts0) { $check = 'ok'; $requested = [string]$ts0.PlatformName }
        else { $check = if ($anyTs) { 'ok' } else { 'no-tsproj' } }
    }
    [PSCustomObject]@{ Passing = $passing; ProjectCheck = $check; RequestedProjectPlatform = $requested; BadText = $firstBad }
}

function New-TcProjectMismatchError {
    # PLATFORM_PROJECT_MISMATCH error object (@{ message; code; hint }); the hint lists the
    # solution platforms of -Configuration whose .tsproj is built for -Platform.
    param([object[]]$SameConfig, [string]$Platform, [string]$Configuration, [string]$BadText)
    $good = @(@($SameConfig) | Where-Object {
            $t = Select-TcTsprojContext -Contexts $_.Contexts -All
            $t.Count -gt 0 -and @($t | Where-Object { -not ([string]$_.PlatformName -ieq $Platform) }).Count -eq 0
        } | ForEach-Object { [string]$_.MatchPlatform })
    $msg = "Solution platform '$Configuration|$Platform' builds the TwinCAT project for another project platform: $BadText. Activating it would not build for a '$Platform' target; nothing was switched (data.platformMap)."
    $hint = Get-TcErrorHint -Code 'PLATFORM_PROJECT_MISMATCH'
    if ($null -ne $hint) { $hint = $hint.Replace('<platform>', $Platform) }
    if ($good.Count -gt 0) { $hint += " Solution platform(s) of '$Configuration' whose .tsproj is built for '$Platform': '$($good -join "', '")'." }
    else { $hint += " No solution platform of '$Configuration' builds the .tsproj for '$Platform'." }
    [PSCustomObject]@{ message = $msg; code = 'PLATFORM_PROJECT_MISMATCH'; hint = $hint }
}

function Get-TcBuildSelectionState {
    <#
    .SYNOPSIS
        Build selection of the ACTIVE solution configuration (#67): ShouldBuild of every .plcproj
        SolutionContext (Get-TcBuildCoverage) and ITcSmTreeItem.Disabled of every PLC tree item
        (Get-TcPlcProjectList), matched with Resolve-TcPlcCoverageNodes. Never throws.
    .DESCRIPTION
        The match is required only when a PLC tree item is disabled (without one every entry is
        enabled, like Build-TcProject #104); an entry without a tree item counts as enabled.
        Error (@{ message; code; hint }, code BUILD_SELECTION_UNKNOWN or a mapped IDE_* code):
        contexts not readable; .plcproj contexts but no TwinCAT project (ITcSysManager) or PLC
        tree not readable; PLC tree items but no .plcproj context; a disabled tree item and no
        one-to-one match.
    .OUTPUTS
        @{ Error; Configuration; MatchBy;
           Entries = @(@{ plc; project; nodePath; shouldBuild; disabled });
           Nodes = @(@{ name; nodePath; disabled }) }
    #>
    param([string]$ConfigurationLabel)
    $out = [PSCustomObject]@{ Error = $null; Configuration = $ConfigurationLabel; MatchBy = $null; Entries = @(); Nodes = @() }
    $unknown = { param([string]$Msg) [PSCustomObject]@{ message = $Msg; code = 'BUILD_SELECTION_UNKNOWN'; hint = (Get-TcErrorHint -Code 'BUILD_SELECTION_UNKNOWN') } }

    $cov = $null
    try { $cov = Get-TcBuildCoverage }
    catch { $out.Error = (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_SELECTION_UNKNOWN' -MessagePrefix 'SolutionContexts not readable').error; return $out }
    if ($null -ne $cov.error) {
        # IDE_BUSY & co. keep their code (Get-TcBuildCoverage returns them as text)
        $out.Error = (New-TcAdsErrorResult -ErrorRecord ([Exception]::new([string]$cov.error)) -DefaultCode 'BUILD_SELECTION_UNKNOWN' -MessagePrefix 'SolutionContexts of the active configuration not readable').error
        return $out
    }
    $entries = @($cov.projects)
    # #67 M1: ShouldBuild is only used when it was read as a real bool
    $noSb = @($entries | Where-Object { $_.shouldBuild -isnot [bool] })
    if ($noSb.Count -gt 0) { $out.Error = & $unknown "ShouldBuild of $(($noSb | ForEach-Object { "'$($_.uniqueName)'" }) -join ', ') in the active configuration not readable"; return $out }

    $sm = $null
    try { $sm = Get-TcSysManager } catch { $sm = $null }
    if ($null -eq $sm) {
        # no TwinCAT project: no PLC tree; .plcproj contexts without it cannot be checked
        if ($entries.Count -gt 0) { $out.Error = & $unknown 'the TwinCAT project (ITcSysManager) is not readable, so the Disabled state of the PLC projects is unknown' }
        return $out
    }
    $plcList = @()
    try { $plcList = @(Get-TcPlcProjectList -SysManager $sm) }
    catch { $out.Error = (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'BUILD_SELECTION_UNKNOWN' -MessagePrefix 'PLC project list (TIPC) not readable').error; return $out }
    # #67 N3: Disabled $null (not readable) is never taken as enabled here
    $noDis = @($plcList | Where-Object { $_.disabled -isnot [bool] })
    if ($noDis.Count -gt 0) { $out.Error = & $unknown "Disabled of PLC tree item(s) $(($noDis | ForEach-Object { "'$($_.name)'" }) -join ', ') not readable"; return $out }
    $out.Nodes = @($plcList | ForEach-Object { [PSCustomObject]@{ name = [string]$_.name; nodePath = [string]$_.nodePath; disabled = ($_.disabled -eq $true) } })
    if ($entries.Count -eq 0) {
        if ($plcList.Count -gt 0) { $out.Error = & $unknown "PLC tree item(s) $(($plcList | ForEach-Object { "'$($_.name)'" }) -join ', ') but no .plcproj SolutionContext in the active configuration" }
        return $out
    }

    $nodes = [object[]]::new($entries.Count)
    if ($plcList.Count -gt 0) {
        $m = Resolve-TcPlcCoverageNodes -Entries $entries -PlcList $plcList -SolutionPath ([string]$script:TcSolutionPath)
        if ($null -eq $m.Error) { $nodes = $m.Nodes; $out.MatchBy = $m.MatchBy }
        elseif (@($plcList | Where-Object { $_.disabled -eq $true }).Count -gt 0) {
            $out.Error = & $unknown (Get-TcPlcMatchErrorText -Reasons $m.Error -Consequence 'the Disabled state per PLC project is unknown')
            return $out
        }
    }
    $list = @()
    for ($i = 0; $i -lt $entries.Count; $i++) {
        $n = $nodes[$i]
        $list += [PSCustomObject]@{
            plc         = $(if ($null -ne $n) { [string]$n.name } else { [string]$entries[$i].name })
            project     = [string]$entries[$i].uniqueName
            nodePath    = $(if ($null -ne $n) { [string]$n.nodePath } else { $null })
            shouldBuild = $entries[$i].shouldBuild
            disabled    = ($null -ne $n -and $n.disabled -eq $true)
        }
    }
    $out.Entries = $list
    $out
}

function Compare-TcBuildSelection {
    <#
    .SYNOPSIS
        Compares the build selection of the active configuration (Get-TcBuildSelectionState) with
        the .plcproj contexts of a switch candidate (Get-TcSolutionConfigurations item). #67.
    .OUTPUTS
        @{ Error ($null or message: a context missing / duplicated under the candidate, ShouldBuild
           not a bool, a .plcproj only the candidate has); Items (buildSelection items, after = $null);
           Changes (items whose target ShouldBuild differs from the current one, or disabled now and
           built by the target) }
    #>
    param($State, $Candidate, [string]$TargetLabel)
    $ctxs = @(@($Candidate.Contexts) | Where-Object { $null -ne $_ -and [string]$_.ProjectName -match '(?i)\.plcproj$' })
    $items = @()
    $problems = @()
    foreach ($e in @($State.Entries)) {
        $hit = @($ctxs | Where-Object { [string]$_.ProjectName -ieq [string]$e.project })
        $tsb = $null
        if ($hit.Count -ne 1) { $problems += "'$($e.project)' has $($hit.Count) SolutionContexts under '$TargetLabel'" }
        elseif ($hit[0].ShouldBuild -isnot [bool]) { $problems += "ShouldBuild of '$($e.project)' under '$TargetLabel' not readable" }
        else { $tsb = $hit[0].ShouldBuild }
        $items += [PSCustomObject]@{
            plc           = $e.plc
            project       = $e.project
            nodePath      = $e.nodePath
            configuration = $TargetLabel
            current       = [PSCustomObject]@{ configuration = $State.Configuration; shouldBuild = $e.shouldBuild; disabled = $e.disabled }
            target        = [PSCustomObject]@{ shouldBuild = $tsb }
            after         = $null
            # S2: a PLC disabled now that the target builds is a change even when its current
            # ShouldBuild is true (fail closed)
            changed       = ($null -ne $tsb -and (($tsb -ne [bool]$e.shouldBuild) -or ($e.disabled -eq $true -and $tsb)))
        }
    }
    foreach ($c in $ctxs) {
        if (@(@($State.Entries) | Where-Object { [string]$_.project -ieq [string]$c.ProjectName }).Count -eq 0) {
            $problems += "'$($c.ProjectName)' is a .plcproj context only under '$TargetLabel'"
        }
    }
    [PSCustomObject]@{
        Error   = $(if ($problems.Count -gt 0) { $problems -join '; ' } else { $null })
        Items   = $items
        Changes = @($items | Where-Object { $_.changed })
    }
}

function Test-TcBuildSelectionAfter {
    <#
    .SYNOPSIS
        After a switch (#67): reads ShouldBuild of every .plcproj context and Disabled of every PLC
        tree item again and compares them with the state before (by project unique name / tree
        path). Fills Items[].after and .changed. Never throws.
    .OUTPUTS
        @{ Error ($null or message); ErrorCode (BUILD_SELECTION_UNKNOWN, or IDE_BUSY / IDE_CRASHED /
           IDE_MODAL_DIALOG ... mapped by New-TcAdsErrorResult); ErrorHint; Changes (changed
           items, plus tree items without .plcproj context whose Disabled changed) }
    #>
    param($State, [object[]]$Items)
    $fail = {
        param($Rec, [string]$Prefix)
        $e = (New-TcAdsErrorResult -ErrorRecord $Rec -DefaultCode 'BUILD_SELECTION_UNKNOWN' -MessagePrefix $Prefix).error
        $hp = $e.PSObject.Properties['hint']
        [PSCustomObject]@{ Error = [string]$e.message; ErrorCode = [string]$e.code; ErrorHint = $(if ($null -ne $hp) { [string]$hp.Value } else { $null }); Changes = @() }
    }
    $cov = $null
    try { $cov = Get-TcBuildCoverage } catch { return (& $fail $_ 'SolutionContexts not readable') }
    if ($null -ne $cov.error) { return (& $fail ([Exception]::new([string]$cov.error)) 'SolutionContexts not readable') }
    $plcList = @()
    if (@($State.Nodes).Count -gt 0) {
        $sm = $null
        try { $sm = Get-TcSysManager } catch { $sm = $null }
        if ($null -eq $sm) { return [PSCustomObject]@{ Error = 'the TwinCAT project (ITcSysManager) is not readable'; ErrorCode = 'BUILD_SELECTION_UNKNOWN'; ErrorHint = $null; Changes = @() } }
        try { $plcList = @(Get-TcPlcProjectList -SysManager $sm) }
        catch { return (& $fail $_ 'PLC project list (TIPC) not readable') }
    }
    $problems = @()
    $changes = @()
    foreach ($it in @($Items)) {
        $hit = @(@($cov.projects) | Where-Object { [string]$_.uniqueName -ieq [string]$it.project })
        $dis = $false
        if (-not [string]::IsNullOrWhiteSpace([string]$it.nodePath)) {
            $nd = @($plcList | Where-Object { [string]$_.nodePath -ieq [string]$it.nodePath })
            if ($nd.Count -ne 1) { $problems += "PLC tree item '$($it.nodePath)' found $($nd.Count) times after the switch"; continue }
            if ($nd[0].disabled -isnot [bool]) { $problems += "Disabled of '$($it.nodePath)' not readable after the switch"; continue }
            $dis = $nd[0].disabled
        }
        if ($hit.Count -ne 1) { $problems += "'$($it.project)' has $($hit.Count) SolutionContexts after the switch"; continue }
        if ($hit[0].shouldBuild -isnot [bool]) { $problems += "ShouldBuild of '$($it.project)' not readable after the switch"; continue }
        $it.after = [PSCustomObject]@{ shouldBuild = $hit[0].shouldBuild; disabled = $dis }
        $it.changed = ($hit[0].shouldBuild -ne [bool]$it.current.shouldBuild) -or ($dis -ne [bool]$it.current.disabled)
        if ($it.changed) { $changes += $it }
    }
    # tree items that no item covers (no .plcproj context matched): Disabled only
    foreach ($n in @($State.Nodes)) {
        if (@(@($Items) | Where-Object { [string]$_.nodePath -ieq [string]$n.nodePath }).Count -gt 0) { continue }
        $nd = @($plcList | Where-Object { [string]$_.nodePath -ieq [string]$n.nodePath })
        if ($nd.Count -ne 1) { $problems += "PLC tree item '$($n.nodePath)' found $($nd.Count) times after the switch"; continue }
        if ($nd[0].disabled -isnot [bool]) { $problems += "Disabled of '$($n.nodePath)' not readable after the switch"; continue }
        if (($nd[0].disabled -eq $true) -ne [bool]$n.disabled) {
            $changes += [PSCustomObject]@{
                plc           = $n.name
                project       = $null
                nodePath      = $n.nodePath
                configuration = $null
                current       = [PSCustomObject]@{ configuration = $State.Configuration; shouldBuild = $null; disabled = [bool]$n.disabled }
                target        = [PSCustomObject]@{ shouldBuild = $null }
                after         = [PSCustomObject]@{ shouldBuild = $null; disabled = ($nd[0].disabled -eq $true) }
                changed       = $true
            }
        }
    }
    $err = if ($problems.Count -gt 0) { $problems -join '; ' } else { $null }
    [PSCustomObject]@{ Error = $err; ErrorCode = $(if ($null -ne $err) { 'BUILD_SELECTION_UNKNOWN' } else { $null }); ErrorHint = $null; Changes = $changes }
}

function Format-TcBuildSelectionChanges {
    # Changes as one '; '-joined text for error messages.
    param([object[]]$Changes, [switch]$After)
    $tf = { param($v) if ($null -eq $v) { 'null' } else { ([string]$v).ToLowerInvariant() } }
    (@($Changes) | ForEach-Object {
            $name = if ([string]::IsNullOrWhiteSpace([string]$_.project)) { "'$($_.plc)'" } else { "'$($_.plc)' ($($_.project))" }
            if ($After -and $null -ne $_.after) {
                "$name shouldBuild $(& $tf $_.current.shouldBuild) -> $(& $tf $_.after.shouldBuild), disabled $(& $tf $_.current.disabled) -> $(& $tf $_.after.disabled)"
            }
            else {
                "$name shouldBuild $(& $tf $_.current.shouldBuild) -> $(& $tf $_.target.shouldBuild) (disabled $(& $tf $_.current.disabled))"
            }
        }) -join '; '
}

function Get-TcBuildSelectionStuckHint {
    # Hint when the build selection changed after a switch AND the previous configuration could not
    # be re-activated (#67 S1): the IDE stays at -Left; the guard blocks Build / Enable.
    param([string]$Previous, [string]$Left, [string]$Changes)
    $cfg = $Previous; $plat = $Previous
    $i = $Previous.IndexOf('|')
    if ($i -gt 0) { $cfg = $Previous.Substring(0, $i); $plat = $Previous.Substring($i + 1) }
    "切回失敗:XAE 現在停在 '$Left',PLC 的 build selection 與切換前('$Previous')不同($Changes),在一個平台停用的 PLC 可能已被重新啟用。不要 Build-TcProject / Enable-TcConfig(模組已記下 BUILD_REQUIRED kind build-selection,這兩個會回 BUILD_SELECTION_CHANGED 拒絕)。下一步:Set-TcTarget -AmsNetId <id> -Platform '$plat' -Configuration '$cfg' 切回(成功就清除),或在 XAE 工具列手動切回 '$Previous' 後重跑同一個 Set-TcTarget(已是 active 也會清除)。"
}
