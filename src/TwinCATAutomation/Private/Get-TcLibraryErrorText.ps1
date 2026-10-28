function Get-TcLibraryErrorText {
    <#
    .SYNOPSIS
        HRESULT + message of an AddLibrary error and its inner exceptions, as one string
        ('0x98510001 Managed Library ... not found! || ...').
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()][object]$ErrorRecord)
    $ex = if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) { $ErrorRecord.Exception } else { $ErrorRecord }
    if ($ex -is [string]) { return $ex }
    $parts = @()
    while ($null -ne $ex -and $ex -is [System.Exception]) {
        $parts += ('0x{0:X8} {1}' -f $ex.HResult, $ex.Message)
        $ex = $ex.InnerException
    }
    $parts -join ' || '
}
