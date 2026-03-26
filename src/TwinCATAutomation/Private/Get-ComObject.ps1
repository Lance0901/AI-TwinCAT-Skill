function Get-ComObject {
    <#
    .SYNOPSIS
        Retrieves a running COM object from the Running Object Table (ROT) by ProgID.
    .PARAMETER ProgId
        The ProgID to look up (e.g., 'TcXaeShell.DTE.17.0').
    .OUTPUTS
        The COM object if found, $null otherwise.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$ProgId
    )

    try {
        [System.Runtime.InteropServices.Marshal]::GetActiveObject($ProgId)
    }
    catch {
        $null
    }
}
