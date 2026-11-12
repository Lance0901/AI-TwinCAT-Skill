function Get-TcProjectVersion {
    <#
    .SYNOPSIS
        Reads the TwinCAT version a solution's .tsproj files were saved with and says which local IDE Connect-TcIde would launch for it (#214). Offline: reads files, needs no IDE.
    .DESCRIPTION
        Reads the .sln and the TcVersion attribute of the root element of every referenced .tsproj
        (the same Get-TcSolutionTcVersion that Connect-TcIde uses, InfoSys "Selection of a TwinCAT 3
        version before loading a project",
        https://infosys.beckhoff.com/content/1033/tc3_remote_manager/3154642571.html), then asks the
        same Resolve-TcLaunchProgId as Connect-TcIde (without -ProgId) which IDE that version needs.
        Nothing is started, written or connected: no IDE, no ADS, no registry write.

        data: solutionPath, visualStudioVersion (from the .sln), builds (distinct build numbers),
        projects[] { path, tcVersion (raw string), major, minor, build, revision (null when the
        string cannot be parsed), error }, launch { selectedBy, progId (the IDE Connect-TcIde would
        launch, null when it would refuse), connectIdeWouldLaunch (bool; false = do not pick a ProgId
        yourself and call Connect-TcIde, ask the user), wantedProgIds (build >= 4026: TcXaeShell.DTE.17.0 /
        VisualStudio.DTE.17.0, else TcXaeShell.DTE.15.0; empty when the build is not decidable), matchingProgIds (registered ProgIDs among
        those whose XAE version equals the project TcVersion exactly, revision included),
        registeredProgIds, ide[] { progId, xaeVersion, xaeBuild, exePath }, errorCode / errorMessage /
        hint (what Connect-TcIde would answer: TWINCAT_NOT_FOUND, IDE_VERSION_NOT_REGISTERED or
        PROGID_REQUIRED; a launch refusal is part of the answer, not a failure of this cmdlet) }.

        Errors: SOLUTION_NOT_FOUND (file missing or unreadable), TSPROJ_NOT_FOUND (the .sln references
        no .tsproj), TCVERSION_UNKNOWN (a referenced .tsproj has no readable TcVersion; data.projects
        says which and why). Each carries error.hint.
    .PARAMETER SolutionPath
        The TwinCAT .sln (relative paths are resolved from the current directory).
    .EXAMPLE
        Get-TcProjectVersion -SolutionPath C:\Temp\Verify-4026-axis\AxisInterface_Type01_Library.sln
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$SolutionPath
    )

    if (-not (Test-Path -LiteralPath $SolutionPath -PathType Leaf)) {
        return New-TcResult -Success $false -ErrorCode 'SOLUTION_NOT_FOUND' -Hint (Get-TcErrorHint -Code 'SOLUTION_NOT_FOUND') `
            -ErrorMessage "Solution file not found: $SolutionPath"
    }
    # 8.3 short names expanded like Connect-TcIde (#63); -LiteralPath like Connect-TcIde (#224): a
    # path with [ ] is taken literally.
    $full = Get-TcLongPath ((Resolve-Path -LiteralPath $SolutionPath).ProviderPath)

    # One read of the files: Resolve-TcLaunchProgId (the decision Connect-TcIde makes, no -ProgId) reads
    # the .sln / .tsproj itself and hands it back as .evidence. Only when it returns before reading
    # (no IDE registered: TWINCAT_NOT_FOUND) is Get-TcSolutionTcVersion called here. Connect-TcIde's own
    # path is not touched.
    $pick = Resolve-TcLaunchProgId -SolutionPath $full
    $ev = if ($null -ne $pick.evidence) { $pick.evidence } else { Get-TcSolutionTcVersion -SolutionPath $full }
    $projects = @($ev.tsprojects | ForEach-Object {
            $v = ConvertFrom-TcVersionString $_.tcVersion
            $path = try { [System.IO.Path]::GetFullPath($_.path) } catch { $_.path }   # collapses .. segments of the .sln's relative reference
            [ordered]@{
                path      = $path
                tcVersion = $_.tcVersion
                major     = $(if ($null -ne $v) { $v.major } else { $null })
                minor     = $(if ($null -ne $v) { $v.minor } else { $null })
                build     = $(if ($null -ne $v) { $v.build } else { $null })
                revision  = $(if ($null -ne $v) { $v.revision } else { $null })
                error     = $_.error
            }
        })
    $data = [ordered]@{
        solutionPath        = $full
        visualStudioVersion = $ev.visualStudioVersion
        builds              = @($ev.builds)
        projects            = $projects
        launch              = $null
    }

    if ($projects.Count -eq 0) {
        $unreadable = [string]$ev.reason -like 'solution unreadable*'
        $code = if ($unreadable) { 'SOLUTION_NOT_FOUND' } else { 'TSPROJ_NOT_FOUND' }
        return New-TcResult -Success $false -ErrorCode $code -Hint (Get-TcErrorHint -Code $code) -ErrorMessage "$($ev.reason): $full" -Data $data
    }
    $unknown = @($projects | Where-Object { $null -eq $_.build })
    if ($unknown.Count -gt 0) {
        return New-TcResult -Success $false -ErrorCode 'TCVERSION_UNKNOWN' -Hint (Get-TcErrorHint -Code 'TCVERSION_UNKNOWN') `
            -ErrorMessage "The TwinCAT version of $($unknown.Count) of $($projects.Count) referenced .tsproj file(s) is unknown: $(@($unknown | ForEach-Object { "$($_.path): $(if ($_.error) { $_.error } else { "TcVersion '$($_.tcVersion)' is not 3.1.<build>.<revision>" })" }) -join '; ')" -Data $data
    }

    $data.launch = [ordered]@{
        selectedBy            = $pick.selectedBy
        progId                = $pick.progId
        connectIdeWouldLaunch = ($null -ne $pick.progId -and $null -eq $pick.errorCode)
        wantedProgIds         = @($pick.wantedProgIds)
        matchingProgIds       = @($pick.matchingProgIds)
        # #225: set when the 32-bit TcXaeShell is picked for a < 4026 project through the Remote
        # Manager folder of exactly the project version (selectedBy remote-manager-match)
        remoteManager         = $(if ($null -ne $pick.remoteManager) { [ordered]@{ build = $pick.remoteManager.build; path = $pick.remoteManager.path; xaeVersion = $pick.remoteManager.xaeVersion; progId = $pick.remoteManager.progId } } else { $null })
        registeredProgIds     = @($pick.registered)
        ide                   = @($pick.ide | ForEach-Object { [ordered]@{ progId = $_.progId; xaeVersion = $_.xaeVersion; xaeBuild = $_.xaeBuild; exePath = $_.exePath } })
        errorCode             = $pick.errorCode
        errorMessage          = $pick.errorMessage
        hint                  = $(if ($null -ne $pick.errorCode) { $script:TcProjectVersionLaunchHint } else { $null })
    }
    return New-TcResult -Success $true -Data $data
}
