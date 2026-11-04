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
    .PARAMETER Hint
        Optional next-action hint for failed operations. Emitted as error.hint
        only when non-empty, so the existing JSON shape is unchanged otherwise.
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
        [string]$ErrorCode,

        [Parameter()]
        [string]$Hint
    )

    if ($Success) {
        [PSCustomObject]@{
            success = $true
            data    = if ($null -eq $Data) { @{} } else { $Data }
        }
    }
    else {
        $errorObj = [PSCustomObject]@{
            message = $ErrorMessage
            code    = $ErrorCode
        }
        # #68 side findings 3 / 4: while the target has a lifecycle block, a hint that would send the
        # agent to a blocked (runtime-changing) command is replaced by the stop text; the block is
        # attached as data.lifecycleBlock
        $advice = $null
        if (-not [string]::IsNullOrWhiteSpace($ErrorCode)) { $advice = Get-TcLifecycleBlockAdvice -Code $ErrorCode }
        if ($null -ne $advice) {
            $orig = if ([string]::IsNullOrWhiteSpace($Hint)) { '' } else { " $Hint" }
            $Hint = "$($script:TcLifecycleReadOnlyText)$orig"
            if ($null -eq $Data) { $Data = [PSCustomObject]@{} }
            if ($Data -is [System.Collections.IDictionary]) { $Data['lifecycleBlock'] = $advice }
            elseif ($Data -is [System.Management.Automation.PSCustomObject]) { $Data | Add-Member -NotePropertyName 'lifecycleBlock' -NotePropertyValue $advice -Force }
        }
        if (-not [string]::IsNullOrWhiteSpace($Hint)) {
            $errorObj | Add-Member -NotePropertyName 'hint' -NotePropertyValue $Hint
        }
        $result = [PSCustomObject]@{
            success = $false
            error   = $errorObj
        }
        if ($null -ne $Data) {
            $result | Add-Member -NotePropertyName 'data' -NotePropertyValue $Data
        }
        $result
    }
}
