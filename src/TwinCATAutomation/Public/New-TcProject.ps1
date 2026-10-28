function New-TcProject {
    <#
    .SYNOPSIS
        Creates a new TwinCAT XAE project with a PLC project and default MAIN program.
    .PARAMETER Name
        Project name.
    .PARAMETER Path
        Directory to create the project in. Defaults to current directory.
    .NOTES
        Fail-closed (#70): when the IDE already has a solution open (DTE Solution.IsOpen, or a
        non-empty Solution.FullName; a read that fails counts as open, an RPC-busy IDE gives
        IDE_BUSY) the call returns SOLUTION_ALREADY_OPEN (data.openSolution) and
        Solution.Create is never called: Solution.Create closes the open solution without a
        warning, its unsaved changes are lost (measured 2026-10-28, #70: TwinCAT 3.1.4026.22
        XAE in VS2022 and 4024 32-bit XAE Shell, registered tcauto). The template path of AddFromTemplate is not fixed yet
        (#70), so the MCP server does not offer NewProject for now; the cmdlet stays.
        BUILD_REQUIRED (#65): on success the NEW solution is recorded as 'code-changed'
        (Register-TcCodeChange, after $script:TcSolutionPath points at it): its PLC project was
        never built, so Enable-TcConfig and Enter-TcPlcOnline refuse until a complete
        Build-TcProject. A failure after Solution.Create returned: the IDE now holds the new,
        unsaved and never built solution (and $script:TcSysManager may already be its project)
        while its .sln path is not known for sure, so $script:TcSolutionPath is set to $null, the
        #29 session record of the IDE process is removed (Remove-TcIdeSolutionRecord), and
        code-changed is recorded under '<unknown>' (blocks every solution until a complete
        Build-TcProject; data.buildRequired / data.stateWarning). A failure before or in
        Solution.Create records nothing and leaves $script:TcSolutionPath unchanged.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Name,

        [Parameter()]
        [string]$Path = (Get-Location).Path
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    # #70: never replace an open solution (Solution.Create would close it)
    # Only an explicit IsOpen = false with an empty FullName counts as "no solution"; anything
    # unreadable (no Solution object, IsOpen not a bool, a COM exception) counts as open.
    $openSolution = $null
    $isOpen = $true
    try {
        # Invoke-TcComRetry: an IDE that rejects the call (RPC busy) is IDE_BUSY, not an open solution
        $sol = Invoke-TcComRetry -MaxRetries 3 -OperationName 'DTE.Solution' -ScriptBlock { Write-Output -NoEnumerate $script:TcDte.Solution }
        if ($null -ne $sol) {
            $openSolution = [string](Invoke-TcComRetry -MaxRetries 3 -OperationName 'Solution.FullName' -ScriptBlock { [string]$sol.FullName })
            $rawIsOpen = Invoke-TcComRetry -MaxRetries 3 -OperationName 'Solution.IsOpen' -ScriptBlock { $sol.IsOpen }
            $isOpen = (-not ($rawIsOpen -is [bool] -and $rawIsOpen -eq $false)) -or -not [string]::IsNullOrWhiteSpace($openSolution)
        }
    }
    catch {
        $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
        if ($null -ne $mapped -and $mapped.Code -match '^IDE_(BUSY|CRASHED|TIMEOUT|MODAL_DIALOG)$') {
            # nothing was created; the caller retries once the IDE answers
            return New-TcResult -Success $false -ErrorCode $mapped.Code -Hint $mapped.Hint `
                -ErrorMessage "New-TcProject could not read whether a solution is open: $($mapped.Message)" `
                -Data ([PSCustomObject]@{ openSolution = $null; created = $false })
        }
        $isOpen = $true   # fail-closed: unknown counts as open
        $openSolution = $null
    }
    if ($isOpen) {
        if ([string]::IsNullOrWhiteSpace($openSolution)) { $openSolution = $null }
        return New-TcResult -Success $false -ErrorCode 'SOLUTION_ALREADY_OPEN' -Hint $script:TcErrorHints['SOLUTION_ALREADY_OPEN'] `
            -ErrorMessage "The IDE has a solution open ($(if ($openSolution) { $openSolution } else { 'unknown' })); New-TcProject did not call Solution.Create, which would close it (#70)." `
            -Data ([PSCustomObject]@{ openSolution = $openSolution; created = $false })
    }

    $solutionCreated = $false   # #65: the IDE holds the new solution from here on
    try {
        $solutionPath = Join-Path $Path $Name
        if (-not (Test-Path $solutionPath)) {
            New-Item -Path $solutionPath -ItemType Directory -Force | Out-Null
        }

        $slnFile = Join-Path $solutionPath "$Name.sln"
        $solution = $script:TcDte.Solution
        $solution.Create($solutionPath, "$Name.sln")
        $solutionCreated = $true

        # Add TwinCAT XAE project
        # TwinCAT project template GUID
        $tcProjectTemplate = ''
        $tcProject = $solution.AddFromTemplate($tcProjectTemplate, $solutionPath, $Name, $false)

        # Get ITcSysManager from the new project
        $sysManager = $tcProject.Object
        $script:TcSysManager = $sysManager

        # Add PLC project under the TwinCAT project
        $plcConfig = $sysManager.LookupTreeItem('TIPC')
        $plcProject = $plcConfig.CreateChild("$Name" + '_Plc', 0, '', [System.Guid]::Empty.ToString('B'))

        # Save solution
        $solution.SaveAs($slnFile)
        # The IDE now has this new solution: module state and the #29 session record follow it.
        $script:TcSolutionPath = try { [IO.Path]::GetFullPath($slnFile) } catch { $slnFile }
        if ($null -ne $script:TcIdeProcessId) { Save-TcIdeSolutionRecord -ProcessId ([int]$script:TcIdeProcessId) -Solution $script:TcSolutionPath }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            solution   = $slnFile
            project    = $Name
            plcProject = "$Name" + '_Plc'
            path       = $solutionPath
        })
        Register-TcCodeChange -Result $ok -Change "New-TcProject $Name"
    }
    catch {
        $res = New-TcResult -Success $false -ErrorMessage "Failed to create project: $_" -ErrorCode 'PROJECT_CREATE_FAILED'
        if ($solutionCreated) {
            # the module must not keep the previous .sln as key while the IDE holds another solution
            $script:TcSolutionPath = $null
            # and the #29 session record must not keep saying this IDE has the old solution
            if ($null -ne $script:TcIdeProcessId) { Remove-TcIdeSolutionRecord -ProcessId ([int]$script:TcIdeProcessId) }
            return Register-TcCodeChange -Result $res -Change "New-TcProject $Name [failed after Solution.Create]"
        }
        $res
    }
}
