function Get-TcSysManager {
    <#
    .SYNOPSIS
        Retrieves ITcSysManager from the current DTE connection.
    .DESCRIPTION
        Gets the ITcSysManager interface from the first TwinCAT project in the open solution.
        Returns $null if no TwinCAT project is loaded.
    .PARAMETER Refresh
        Force re-scan of solution projects, clearing the cached ITcSysManager.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Refresh
    )

    Assert-TcConnection

    if ($Refresh) {
        $script:TcSysManager = $null
        Write-Verbose 'Get-TcSysManager: cache cleared, re-scanning projects.'
    }

    if ($null -ne $script:TcSysManager) {
        return $script:TcSysManager
    }

    try {
        $solution = $script:TcDte.Solution
        if ($null -eq $solution -or $solution.Projects.Count -eq 0) {
            Write-Verbose 'Get-TcSysManager: No solution or no projects loaded.'
            return $null
        }

        # Find the TwinCAT project (iterate to find one with ITcSysManager)
        for ($i = 1; $i -le $solution.Projects.Count; $i++) {
            $project = $solution.Projects.Item($i)
            try {
                $sysManager = $project.Object
                if ($null -ne $sysManager) {
                    $script:TcSysManager = $sysManager
                    Write-Verbose "Get-TcSysManager: Found ITcSysManager in project '$($project.Name)'."
                    return $sysManager
                }
            }
            catch {
                # Not a TwinCAT project, continue
                continue
            }
        }

        Write-Verbose "Get-TcSysManager: Scanned $($solution.Projects.Count) project(s), none have ITcSysManager."
        return $null
    }
    catch {
        Write-Verbose "Get-TcSysManager: Error scanning projects: $_"
        return $null
    }
}
