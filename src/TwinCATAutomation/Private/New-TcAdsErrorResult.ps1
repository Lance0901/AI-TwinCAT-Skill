function New-TcAdsErrorResult {
    <#
    .SYNOPSIS
        Builds a failed New-TcResult from a caught error, mapping ADS/COM errors to
        specific codes + hints via ConvertTo-TcAdsErrorCode.
    .DESCRIPTION
        Used in catch blocks of ADS-related cmdlets:
            catch { New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'ADS_READ_FAILED' -MessagePrefix 'Failed to read variable' }
        When ConvertTo-TcAdsErrorCode recognises the error, its Code/Hint are used;
        otherwise -DefaultCode (and the hint registered for it, if any) is used.
    .PARAMETER ErrorRecord
        The caught ErrorRecord ($_) or Exception.
    .PARAMETER DefaultCode
        Generic error code to use when the error is not a known ADS/COM condition.
    .PARAMETER MessagePrefix
        Optional prefix; result message becomes "<prefix>: <error message>".
    .PARAMETER Data
        Optional data payload to attach to the failed result.
    .PARAMETER CodeAliases
        Optional map of mapped code -> legacy code. When the mapped code is a key,
        the legacy code is returned (backward compatible) together with the hint of
        the mapped code, e.g. @{ ADS_SYMBOL_NOT_FOUND = 'SYMBOL_NOT_FOUND' }.
    .PARAMETER Port
        ADS port the failing call used (for hints that name the port). Default: the
        module session port, else 851.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowNull()]
        [object]$ErrorRecord,

        [Parameter(Mandatory)]
        [string]$DefaultCode,

        [Parameter()]
        [string]$MessagePrefix,

        [Parameter()]
        [object]$Data,

        [Parameter()]
        [hashtable]$CodeAliases,

        [Parameter()]
        [int]$Port = 0
    )

    # Hints such as ADS_PORT_NOT_FOUND name the port that was actually used: an
    # explicit -Port wins, otherwise the port of the module ADS session.
    if ($Port -le 0 -and $null -ne $script:TcAdsPort) {
        try { $Port = [int]$script:TcAdsPort } catch { $Port = 0 }
    }

    $rawMessage = ''
    if ($ErrorRecord -is [System.Management.Automation.ErrorRecord]) {
        $rawMessage = $ErrorRecord.Exception.Message
    }
    elseif ($ErrorRecord -is [System.Exception]) {
        $rawMessage = $ErrorRecord.Message
    }
    elseif ($null -ne $ErrorRecord) {
        $rawMessage = [string]$ErrorRecord
    }

    $fullMessage = if ([string]::IsNullOrWhiteSpace($MessagePrefix)) { $rawMessage } else { "${MessagePrefix}: $rawMessage" }

    $code = $DefaultCode
    $hint = Get-TcErrorHint -Code $DefaultCode -Port $Port

    $mapped = ConvertTo-TcAdsErrorCode -InputObject $ErrorRecord -Port $Port
    if ($null -ne $mapped) {
        $code = $mapped.Code
        $hint = $mapped.Hint
        if ($null -ne $CodeAliases -and $CodeAliases.ContainsKey($mapped.Code)) {
            $code = [string]$CodeAliases[$mapped.Code]
        }
    }

    $params = @{
        Success      = $false
        ErrorMessage = $fullMessage
        ErrorCode    = $code
    }
    if (-not [string]::IsNullOrWhiteSpace($hint)) { $params['Hint'] = $hint }
    if ($null -ne $Data) { $params['Data'] = $Data }

    New-TcResult @params
}
