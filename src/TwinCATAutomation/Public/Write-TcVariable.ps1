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
        # Ensure TcAdsHelper is compiled (needs TwinCAT.Ads.dll loaded first)
        if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
            $null = Find-TcAdsAssembly
        }

        # Get symbol info via C# helper (bypasses CLS issue)
        $symInfo = [TcAdsHelper]::GetSymbolInfo($script:TcAdsClient, $Path)
        $typeName = $symInfo['TypeName']
        $typeSize = $symInfo['Size']

        $handle = $script:TcAdsClient.CreateVariableHandle($Path)

        # Convert and write based on PLC type
        switch -Regex ($typeName.ToUpper()) {
            '^BOOL$'           { $script:TcAdsClient.WriteAny($handle, [bool]$Value) }
            '^SINT$'           { $script:TcAdsClient.WriteAny($handle, [sbyte]$Value) }
            '^USINT$|^BYTE$'   { $script:TcAdsClient.WriteAny($handle, [byte]$Value) }
            '^INT$'            { $script:TcAdsClient.WriteAny($handle, [int16]$Value) }
            '^UINT$|^WORD$'    { $script:TcAdsClient.WriteAny($handle, [uint16]$Value) }
            '^DINT$'           { $script:TcAdsClient.WriteAny($handle, [int32]$Value) }
            '^UDINT$|^DWORD$'  { $script:TcAdsClient.WriteAny($handle, [uint32]$Value) }
            '^LINT$'           { $script:TcAdsClient.WriteAny($handle, [int64]$Value) }
            '^ULINT$|^LWORD$'  { $script:TcAdsClient.WriteAny($handle, [uint64]$Value) }
            '^REAL$'           { $script:TcAdsClient.WriteAny($handle, [float]$Value) }
            '^LREAL$'          { $script:TcAdsClient.WriteAny($handle, [double]$Value) }
            '^STRING' {
                $strLen = if ($typeSize -gt 0) { $typeSize } else { 255 }
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
            type    = $typeName
        })
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to write variable: $_" -ErrorCode 'ADS_WRITE_FAILED'
    }
}
