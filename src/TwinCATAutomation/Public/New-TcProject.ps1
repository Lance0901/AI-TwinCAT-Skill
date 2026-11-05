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
        XAE in VS2022 and 4024 32-bit XAE Shell, registered tcauto).
        Templates (#70): AddFromTemplate got an empty template string (STG_E_FILENOTFOUND on 4026,
        ArgumentException on 4024). It now gets the full path of 'TwinCAT Project.tsproj' from
        Resolve-TcProjectTemplate (InfoSys "Accessing TwinCAT configuration":
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html),
        and CreateChild gets the template NAME 'Standard PLC Template' (InfoSys "How to create a
        PLC project": only the template name for standard Beckhoff templates:
        https://infosys.beckhoff.com/content/1033/tc3_automationinterface/21842439947.html).
        No template file -> TEMPLATE_NOT_FOUND (data.searched), resolved BEFORE Solution.Create so
        the IDE state is untouched. An existing <Path>\<Name> -> PROJECT_DIR_EXISTS (before
        Solution.Create). The TwinCAT project is saved (Project.Save(), then Solution.SaveAs, as in InfoSys) and
        success needs a read-back (.sln, .tsproj and .plcproj on disk, the .tsproj CONTENT has a <Plc>
        node with PrjFilePath to <Name>_Plc.plcproj, and the TIPC^<Name>_Plc node in the tree),
        otherwise PROJECT_CREATE_UNVERIFIED (data.missing). Check order: solution open, template,
        folder exists, then Solution.Create (an open solution + an existing folder gives SOLUTION_ALREADY_OPEN).
        Measured 2026-11-05 (4024 32-bit XAE Shell and 4026.22 XAE in VS2022; the project was
        created with a self-made client, the Build ran through the registered tcauto): create and
        a complete Build succeed on both, no dialog, about 5 s. The MCP server keeps NewProject
        off for the reasons that remain: Solution.Create closes the solution the IDE has open,
        and the cmdlet was not yet driven through tcauto itself. The cmdlet stays.
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

    # #70: resolve the XAE project template before Solution.Create; nothing is touched when it is missing
    $template = Resolve-TcProjectTemplate
    if ($null -eq $template -or [string]::IsNullOrWhiteSpace([string]$template.Path)) {
        return New-TcResult -Success $false -ErrorCode 'TEMPLATE_NOT_FOUND' -Hint $script:TcErrorHints['TEMPLATE_NOT_FOUND'] `
            -ErrorMessage "TwinCAT project template 'TwinCAT Project.tsproj' not found; New-TcProject did not call Solution.Create (#70)." `
            -Data ([PSCustomObject]@{ searched = @($template.Searched); created = $false })
    }
    $tcProjectTemplate = [string]$template.Path

    # #70: an existing <Path>\<Name> is never reused (the template would write into a foreign folder)
    $solutionPath = Join-Path $Path $Name
    if (Test-Path -LiteralPath $solutionPath) {
        return New-TcResult -Success $false -ErrorCode 'PROJECT_DIR_EXISTS' -Hint $script:TcErrorHints['PROJECT_DIR_EXISTS'] `
            -ErrorMessage "The folder '$solutionPath' already exists; New-TcProject did not call Solution.Create (#70)." `
            -Data ([PSCustomObject]@{ path = $solutionPath; created = $false })
    }

    $solutionCreated = $false   # #65: the IDE holds the new solution from here on
    $missing = @()               # #70: files / nodes the read-back did not find
    try {
        New-Item -Path $solutionPath -ItemType Directory -Force | Out-Null

        $slnFile = Join-Path $solutionPath "$Name.sln"
        $solution = $script:TcDte.Solution
        $solution.Create($solutionPath, "$Name.sln")
        $solutionCreated = $true

        # Add TwinCAT XAE project
        # full path of 'TwinCAT Project.tsproj' (InfoSys 242721803: AddFromTemplate(template, destination, name))
        $tcProject = $solution.AddFromTemplate($tcProjectTemplate, $solutionPath, $Name)

        # Get ITcSysManager from the new project
        $sysManager = $tcProject.Object
        $script:TcSysManager = $sysManager

        # Add PLC project under the TwinCAT project
        $plcConfig = $sysManager.LookupTreeItem('TIPC')
        # CreateChild(name, subType 0, '', vInfo): standard Beckhoff templates are given by NAME only (InfoSys 21842439947)
        $plcProject = $plcConfig.CreateChild("$Name" + '_Plc', 0, '', 'Standard PLC Template')

        # Save the TwinCAT project first, then the solution. InfoSys "Accessing TwinCAT configuration"
        # does the same (C# project.Save(); solution.SaveAs(...), PowerShell $project.Save(); $sln.SaveAs(...)):
        # https://infosys.beckhoff.com/content/1033/tc3_automationinterface/242721803.html
        # Measured 2026-11-05 (4024 and 4026.22, #70 re-verification): without Project.Save() the
        # .tsproj stays a 329 byte skeleton with no <Plc> node until the first Build, so closing the
        # solution unsaved loses the PLC project (Build: "no PLC project").
        $tcProject.Save()
        $solution.SaveAs($slnFile)

        # #70 read-back: success only when the files are on disk and the PLC node is in the tree.
        # No wall-clock deadline on these calls (nor on Solution.Create / AddFromTemplate /
        # CreateChild above): they are synchronous STA calls into the IDE that cannot be cancelled
        # from here (a deadline would only abandon a call the IDE keeps executing), and the whole
        # create took about 5 s on 4024 and 4026.22 (measured 2026-11-05). An RPC-busy IDE is
        # retried by Invoke-TcComRetry; any exception lands in the catch below, which records the
        # unknown solution state.
        if (-not (Test-Path -LiteralPath $slnFile -PathType Leaf)) { $missing += $slnFile }
        if (@(Get-ChildItem -LiteralPath $solutionPath -Filter '*.tsproj' -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0) { $missing += "$solutionPath\**\*.tsproj" }
        if (@(Get-ChildItem -LiteralPath $solutionPath -Filter '*.plcproj' -File -Recurse -ErrorAction SilentlyContinue).Count -eq 0) { $missing += "$solutionPath\**\*.plcproj" }
        # content, not only existence: some .tsproj must have a <Plc> node that references <Name>_Plc.plcproj
        # (a 329 byte skeleton without it is what an unsaved project looks like)
        $tsprojFiles = @(Get-ChildItem -LiteralPath $solutionPath -Filter '*.tsproj' -File -Recurse -ErrorAction SilentlyContinue)
        if ($tsprojFiles.Count -gt 0) {
            $refPattern = 'PrjFilePath\s*=\s*"[^"]*' + [regex]::Escape("$Name`_Plc.plcproj") + '"'
            $hasPlc = $false
            foreach ($tf in $tsprojFiles) {
                $txt = ''
                try { $txt = [System.IO.File]::ReadAllText($tf.FullName) } catch { $null = $_ }
                if ($txt -match '<Plc[\s>/]' -and $txt -match $refPattern) { $hasPlc = $true; break }
            }
            if (-not $hasPlc) { $missing += "$($tsprojFiles[0].FullName): no <Plc> node with PrjFilePath to $Name`_Plc.plcproj (project not saved)" }
        }
        $plcNode = $null
        try { $plcNode = Invoke-TcComRetry -MaxRetries 3 -OperationName 'LookupTreeItem' -ScriptBlock { Write-Output -NoEnumerate $sysManager.LookupTreeItem("TIPC^$Name" + '_Plc') } }
        catch { $null = $_ }   # not found counts as missing below
        if ($null -eq $plcNode) { $missing += "TIPC^$Name`_Plc" }
        if ($missing.Count -gt 0) { throw "read-back after create found nothing for: $($missing -join '; ')" }

        # The IDE now has this new solution: module state and the #29 session record follow it.
        $script:TcSolutionPath = try { Get-TcLongPath $slnFile } catch { $slnFile }
        if ($null -ne $script:TcIdeProcessId) { Save-TcIdeSolutionRecord -ProcessId ([int]$script:TcIdeProcessId) -Solution $script:TcSolutionPath }

        $ok = New-TcResult -Success $true -Data ([PSCustomObject]@{
            solution   = $slnFile
            project    = $Name
            plcProject = "$Name" + '_Plc'
            path       = $solutionPath
        })
        # #123: the record could not be updated (lock busy): say so, the old one is not used
        $recWarn = if ($null -ne $script:TcIdeProcessId) { Get-TcIdeSolutionRecordWarning -ProcessId ([int]$script:TcIdeProcessId) } else { $null }
        if ($null -ne $recWarn) { $ok.data | Add-Member -NotePropertyName 'sessionRecordWarning' -NotePropertyValue $recWarn }
        Register-TcCodeChange -Result $ok -Change "New-TcProject $Name"
    }
    catch {
        if ($missing.Count -gt 0) {
            $res = New-TcResult -Success $false -ErrorMessage "New-TcProject finished but the read-back failed: $_" -ErrorCode 'PROJECT_CREATE_UNVERIFIED' `
                -Hint $script:TcErrorHints['PROJECT_CREATE_UNVERIFIED'] -Data ([PSCustomObject]@{ missing = @($missing); path = $solutionPath })
        }
        else {
            $res = New-TcResult -Success $false -ErrorMessage "Failed to create project: $_" -ErrorCode 'PROJECT_CREATE_FAILED'
        }
        if ($solutionCreated) {
            # the module must not keep the previous .sln as key while the IDE holds another solution
            $script:TcSolutionPath = $null
            # and the #29 session record must not keep saying this IDE has the old solution
            if ($null -ne $script:TcIdeProcessId) {
                Remove-TcIdeSolutionRecord -ProcessId ([int]$script:TcIdeProcessId)
                # #123: the remove was skipped (lock busy): say so, the old record is not used
                $recWarn = Get-TcIdeSolutionRecordWarning -ProcessId ([int]$script:TcIdeProcessId)
                if ($null -ne $recWarn) {
                    $res = New-TcResult -Success $false -ErrorMessage ([string]$res.error.message) -ErrorCode 'PROJECT_CREATE_FAILED' -Data ([PSCustomObject]@{ sessionRecordWarning = $recWarn })
                }
            }
            return Register-TcCodeChange -Result $res -Change "New-TcProject $Name [failed after Solution.Create]"
        }
        $res
    }
}
