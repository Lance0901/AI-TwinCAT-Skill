function Get-TcSysManager {
    <#
    .SYNOPSIS
        Retrieves ITcSysManager from the current DTE connection.
    .DESCRIPTION
        Gets the ITcSysManager interface from the first TwinCAT project in the open solution.
        Returns $null if no TwinCAT project is loaded.
    #>
    [CmdletBinding()]
    param()

    Assert-TcConnection

    if ($null -ne $script:TcSysManager) {
        return $script:TcSysManager
    }

    try {
        $solution = $script:TcDte.Solution
        if ($null -eq $solution -or $solution.Projects.Count -eq 0) {
            return $null
        }

        # Find the TwinCAT project (iterate to find one with ITcSysManager)
        for ($i = 1; $i -le $solution.Projects.Count; $i++) {
            $project = $solution.Projects.Item($i)
            try {
                $sysManager = $project.Object
                if ($null -ne $sysManager) {
                    $script:TcSysManager = $sysManager
                    return $sysManager
                }
            }
            catch {
                # Not a TwinCAT project, continue
                continue
            }
        }

        return $null
    }
    catch {
        return $null
    }
}
