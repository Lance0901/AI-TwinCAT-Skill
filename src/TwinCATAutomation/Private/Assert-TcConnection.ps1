function Assert-TcConnection {
    <#
    .SYNOPSIS
        Checks for an active TwinCAT IDE connection. Throws if not connected.
    #>
    [CmdletBinding()]
    param()

    if (-not $script:TcIdeConnected -or $null -eq $script:TcDte) {
        throw "Not connected to TwinCAT IDE. Call Connect-TcIde first."
    }
}
