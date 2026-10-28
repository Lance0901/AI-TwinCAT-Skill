function New-TcProject {
    <#
    .SYNOPSIS
        Creates a new TwinCAT XAE project with a PLC project and default MAIN program.
    .PARAMETER Name
        Project name.
    .PARAMETER Path
        Directory to create the project in. Defaults to current directory.
    .NOTES
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
