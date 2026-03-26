function Write-TcVariable {
    <#
    .SYNOPSIS
        Writes a value to a PLC variable by symbol name via ADS.
    .PARAMETER Path
        Variable path (e.g., "MAIN.nSetpoint").
    .PARAMETER Value
        Value to write.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [Parameter(Mandatory)]
        [object]$Value
    )

    try { Assert-TcAdsConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    try {
        $handle = $script:TcAdsClient.CreateVariableHandle($Path)
        $symbolInfo = $script:TcAdsClient.ReadSymbolInfo($Path)
        $typeName = $symbolInfo.Type

        # Convert and write based on type
        switch -Regex ($typeName.ToUpper()) {
            '^BOOL$' { $script:TcAdsClient.WriteAny($handle, [bool]$Value) }
            '^(S?INT|BYTE)$' { $script:TcAdsClient.WriteAny($handle, [int16]$Value) }
            '^(U?INT|WORD)$' { $script:TcAdsClient.WriteAny($handle, [int16]$Value) }
            '^(U?DINT|DWORD)$' { $script:TcAdsClient.WriteAny($handle, [int32]$Value) }
            '^(U?LINT|LWORD)$' { $script:TcAdsClient.WriteAny($handle, [int64]$Value) }
            '^REAL$' { $script:TcAdsClient.WriteAny($handle, [float]$Value) }
            '^LREAL$' { $script:TcAdsClient.WriteAny($handle, [double]$Value) }
            '^STRING' {
                $strLen = if ($symbolInfo.Size -gt 0) { $symbolInfo.Size } else { 255 }
                $script:TcAdsClient.WriteAny($handle, [string]$Value, @([int]$strLen))
            }
            default {
                $script:TcAdsClient.DeleteVariableHandle($handle)
                return New-TcResult -Success $false -ErrorMessage "Unsupported type for write: $typeName" -ErrorCode 'TYPE_MISMATCH'
            }
        }

        $script:TcAdsClient.DeleteVariableHandle($handle)

        New-TcResult -Success $true -Data ([PSCustomObject]@{
            path    = $Path
            written = $Value
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to write variable: $_" -ErrorCode 'ADS_WRITE_FAILED'
    }
}
