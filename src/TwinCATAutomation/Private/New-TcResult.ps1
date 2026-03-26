function New-TcResult {
    <#
    .SYNOPSIS
        Creates a standardized result object for JSON output.
    .PARAMETER Success
        Whether the operation succeeded.
    .PARAMETER Data
        The data payload for successful operations.
    .PARAMETER ErrorMessage
        Error message for failed operations.
    .PARAMETER ErrorCode
        Error code for failed operations.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [bool]$Success,

        [Parameter()]
        [object]$Data,

        [Parameter()]
        [string]$ErrorMessage,

        [Parameter()]
        [string]$ErrorCode
    )

    if ($Success) {
        [PSCustomObject]@{
            success = $true
            data    = if ($null -eq $Data) { @{} } else { $Data }
        }
    }
    else {
        $result = [PSCustomObject]@{
            success = $false
            error   = [PSCustomObject]@{
                message = $ErrorMessage
                code    = $ErrorCode
            }
        }
        if ($null -ne $Data) {
            $result | Add-Member -NotePropertyName 'data' -NotePropertyValue $Data
        }
        $result
    }
}
