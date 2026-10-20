function New-TcNoSysManagerResult {
    <#
    .SYNOPSIS
        Builds the failed result for "Get-TcSysManager returned $null".
    .DESCRIPTION
        Get-TcSysManager never throws; when its project scan failed it records the
        exception message in $script:TcLastSysManagerError. This helper turns that into
        the real error code instead of a misleading NO_PROJECT:
            IDE_MODAL_DIALOG -> New-TcModalDialogResult (when the watchdog captured the
                                dialog in $script:TcLastModalDialog) or a plain result
            IDE_CRASHED      -> code IDE_CRASHED
            IDE_BUSY         -> code IDE_BUSY
            IDE_TIMEOUT      -> code IDE_TIMEOUT
            otherwise        -> NO_PROJECT 'No TwinCAT project loaded.'
        Hints come from the central table (Get-TcErrorHint).
        Usage in a public cmdlet:
            $sm = Get-TcSysManager
            if ($null -eq $sm) { return New-TcNoSysManagerResult }
    .PARAMETER Data
        Optional data payload attached to the failed result.
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [object]$Data
    )

    $lastError = [string]$script:TcLastSysManagerError

    if (-not [string]::IsNullOrWhiteSpace($lastError)) {
        # Order matters: a modal-dialog message also carries the original busy text.
        $code = $null
        if ($lastError -match 'IDE_MODAL_DIALOG') { $code = 'IDE_MODAL_DIALOG' }
        elseif ($lastError -match 'IDE_CRASHED') { $code = 'IDE_CRASHED' }
        elseif ($lastError -match 'IDE_TIMEOUT') { $code = 'IDE_TIMEOUT' }
        elseif ($lastError -match 'IDE_BUSY') { $code = 'IDE_BUSY' }

        if ($code -eq 'IDE_MODAL_DIALOG' -and $null -ne $script:TcLastModalDialog) {
            $params = @{ Dialog = $script:TcLastModalDialog; Operation = 'Scan solution projects' }
            if ($null -ne $Data) { $params['Data'] = $Data }
            return New-TcModalDialogResult @params
        }

        if ($null -ne $code) {
            $params = @{
                Success      = $false
                ErrorMessage = $lastError
                ErrorCode    = $code
            }
            $hint = Get-TcErrorHint -Code $code
            if (-not [string]::IsNullOrWhiteSpace($hint)) { $params['Hint'] = $hint }
            if ($null -ne $Data) { $params['Data'] = $Data }
            return New-TcResult @params
        }
    }

    $params = @{
        Success      = $false
        ErrorMessage = 'No TwinCAT project loaded.'
        ErrorCode    = 'NO_PROJECT'
    }
    if ($null -ne $Data) { $params['Data'] = $Data }
    New-TcResult @params
}
