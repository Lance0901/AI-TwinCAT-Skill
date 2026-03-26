function New-TcProject {
    <#
    .SYNOPSIS
        Creates a new TwinCAT XAE project with a PLC project and default MAIN program.
    .PARAMETER Name
        Project name.
    .PARAMETER Path
        Directory to create the project in. Defaults to current directory.
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

    try {
        $solutionPath = Join-Path $Path $Name
        if (-not (Test-Path $solutionPath)) {
            New-Item -Path $solutionPath -ItemType Directory -Force | Out-Null
        }

        $slnFile = Join-Path $solutionPath "$Name.sln"
        $solution = $script:TcDte.Solution
        $solution.Create($solutionPath, "$Name.sln")

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

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            solution   = $slnFile
            project    = $Name
            plcProject = "$Name" + '_Plc'
            path       = $solutionPath
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to create project: $_" -ErrorCode 'PROJECT_CREATE_FAILED'
    }
}
