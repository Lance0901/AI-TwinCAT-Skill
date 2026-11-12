function Get-TcIdeInfo {
    <#
    .SYNOPSIS
        Returns information about the connected TwinCAT IDE instance.
    .DESCRIPTION
        data.remoteManagerVersion (#225): the TwinCAT Remote Manager version the IDE currently uses,
        read (never set) as DTE.GetObject('TcRemoteManager').Version (InfoSys "Accessing TwinCAT
        Remote Manager", https://infosys.beckhoff.com/content/1033/tc3_automationinterface/2507904267.html);
        $null with data.remoteManagerError when the IDE does not answer it.
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
    # #225: which Remote Manager version the IDE runs (read-only; setting Version switches the XAE).
    # No own deadline (CODING_STANDARDS 1): it is one more synchronous DTE read right after the
    # DTE.Version / Solution reads above, which block first when the IDE is blocked; a COM error
    # (also RPC_E_CALL_REJECTED of a busy IDE) is reported as its text in remoteManagerError.
    $rmRead = Get-TcRemoteManagerVersion -Dte $script:TcDte
    $rmVersion = $rmRead.version; $rmError = $rmRead.error

    $data = [PSCustomObject]@{
        progId                = $script:TcProgId
        version               = $ideVersion
        edition               = $ideEdition
        solution              = $ideSolution
        sysManagerAvailable   = ($null -ne $script:TcSysManager)
        solutionPlatform      = $sol.platform
        solutionConfiguration = $sol.configuration
        projectPlatform       = $sol.projectPlatform
        remoteManagerVersion  = $rmVersion
        remoteManagerError    = $rmError
    }

    New-TcResult -Success $true -Data $data
}
