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

    $data = [PSCustomObject]@{
        progId              = $script:TcProgId
        version             = $ideVersion
        edition             = $ideEdition
        solution            = $ideSolution
        sysManagerAvailable = ($null -ne $script:TcSysManager)
    }

    New-TcResult -Success $true -Data $data
}
