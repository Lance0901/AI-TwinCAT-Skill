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

    $data = [PSCustomObject]@{
        progId              = $script:TcProgId
        version             = try { $script:TcDte.Version } catch { 'unknown' }
        edition             = try { $script:TcDte.Edition } catch { 'unknown' }
        solution            = try { $script:TcDte.Solution.FullName } catch { '' }
        sysManagerAvailable = ($null -ne $script:TcSysManager)
    }

    New-TcResult -Success $true -Data $data
}
