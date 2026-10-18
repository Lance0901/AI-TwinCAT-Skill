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
        return ,$script:TcSysManager
    }

    try {
        # All DTE/COM access wrapped in Invoke-TcComRetry (IDE busy -> backoff retry)
        $sysManager = Invoke-TcComRetry -OperationName 'Scan solution projects' -ScriptBlock {
            $found = $null
            $solution = $script:TcDte.Solution
            if ($null -eq $solution -or $solution.Projects.Count -eq 0) {
                Write-Verbose 'Get-TcSysManager: No solution or no projects loaded.'
                return $null
            }

            # Find the TwinCAT project (iterate to find one with ITcSysManager)
            for ($i = 1; $i -le $solution.Projects.Count; $i++) {
                $project = $solution.Projects.Item($i)
                try {
                    $candidate = $project.Object
                    if ($null -ne $candidate) {
                        $found = $candidate
                        Write-Verbose "Get-TcSysManager: Found ITcSysManager in project '$($project.Name)'."
                        break
                    }
                }
                catch {
                    # IDE busy must bubble up so the retry wrapper can back off
                    if ($_.Exception.Message -match '0x80010001|RPC_E_CALL_REJECTED|0x8001010A|RPC_E_SERVERCALL_RETRYLATER') { throw }
                    # Not a TwinCAT project, continue
                    continue
                }
            }

            if ($null -eq $found) {
                Write-Verbose "Get-TcSysManager: Scanned $($solution.Projects.Count) project(s), none have ITcSysManager."
            }
            Write-Output -NoEnumerate $found
        }

        if ($null -ne $sysManager) {
            $script:TcSysManager = $sysManager
        }
        return ,$sysManager
    }
    catch {
        Write-Verbose "Get-TcSysManager: Error scanning projects: $_"
        return $null
    }
}
