function Get-TcIdeInfo {
    <#
    .SYNOPSIS
        Returns information about the connected TwinCAT IDE instance.
    #>
    [CmdletBinding()]
    param()

    try {
        Assert-TcConnection
    }
    catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $ideVersion = try { $script:TcDte.Version } catch { 'unknown' }
    $ideEdition = try { $script:TcDte.Edition } catch { 'unknown' }
    $ideSolution = try { $script:TcDte.Solution.FullName } catch { '' }
    # Active solution platform / configuration ($null when unreadable) and the project platform
    # of the .tsproj under it. Both must match the target platform ('TwinCAT OS (x64)' for a
    # local UmRT), see Set-TcTarget -Platform.
    $sol = Get-TcSolutionPlatform

    $data = [PSCustomObject]@{
        progId                = $script:TcProgId
        version               = $ideVersion
        edition               = $ideEdition
        solution              = $ideSolution
        sysManagerAvailable   = ($null -ne $script:TcSysManager)
        solutionPlatform      = $sol.platform
        solutionConfiguration = $sol.configuration
        projectPlatform       = $sol.projectPlatform
    }

    New-TcResult -Success $true -Data $data
}
