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
            availablePlatforms; availableConfigurations }
        error.code: PLATFORM_NOT_FOUND, PLATFORM_PROJECT_MISMATCH, PLATFORM_SET_FAILED
        (activation failed or not visible afterwards), or a mapped COM code (IDE_BUSY,
        IDE_CRASHED, ...).
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

    if ($null -ne $activateError -or -not (& $isOk $after)) {
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
        $restoreText = if ($restoredOk) { " The previous configuration '$($before.configuration)|$($before.platform)' was re-activated." } else { ' The previous configuration could not be restored.' }
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
    if (-not [string]::IsNullOrWhiteSpace($after.configuration)) { $out.configuration = $after.configuration }
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
