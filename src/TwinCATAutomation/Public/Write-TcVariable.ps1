function Write-TcVariable {
    <#
    .SYNOPSIS
        Writes a value to a PLC variable by symbol name via ADS.
    .DESCRIPTION
        The value is converted to the PLC type of the symbol (read via ADS symbol info):
          BOOL                       true/false, 0/1, "true"/"false"
          SINT..ULINT, BYTE..LWORD   integer (JSON number or numeric string; no fraction, range checked)
          REAL/LREAL                 number or numeric string
          STRING                     string
          TIME/TOD                   IEC literal T#6s / T#1m30s500ms / TOD#12:30:00.500 (integer ms also accepted)
          LTIME/LTOD                 LTIME#1us / LTOD#12:30:00.000000001 (integer ns also accepted)
          DATE/DT                    D#2026-10-20 / DT#2026-10-20-12:30:00 or ISO 8601 (2026-10-20T12:30:00+08:00
                                     is converted to UTC); integer seconds since 1970 also accepted
          LDATE/LDT                  the L-literals / ISO 8601 (integer ns since 1970 also accepted)
          enum                       integer, or the member name ("READY")
        STRUCT/ARRAY symbols are not written as a whole (TYPE_MISMATCH); write their members.
        data.written is the value actually written (converted, not the input echoed): for time types the
        normalized IEC literal (T#6000ms -> T#6s) plus the raw integer in data.ms / data.ns / data.unix;
        enums add data.name.
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

    try { $reconnected = Ensure-TcAdsConnection } catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
    }

    try {
        # Ensure TcAdsHelper is compiled (needs TwinCAT.Ads.dll loaded first)
        if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
            $null = Find-TcAdsAssembly
        }

        # Get symbol info via C# helper (bypasses CLS issue)
        $symInfo = [TcAdsHelper]::GetSymbolInfo($script:TcAdsClient, $Path)
        $typeName = [string]$symInfo['TypeName']
        $typeSize = [int]$symInfo['Size']
        $typeId = [int]$symInfo['DataTypeId']
        $upper = $typeName.ToUpperInvariant()

        # --- Decide how to convert (no ADS access yet, so a bad value never touches the PLC) ---
        $typed = $null          # value handed to WriteAny
        $written = $null        # value reported back
        $rawField = $null       # ms / ns / unix for time types
        $rawValue = $null
        $enumName = $null       # member name for enums
        $strLen = 0

        try {
            $timeType = Get-TcIecTimeType -TypeName $typeName
            if ($null -ne $timeType) {
                $raw = ConvertFrom-TcIecLiteral -Value $Value -TypeInfo $timeType
                $typed = if ($typeSize -ge 8) { [uint64]$raw } else { [uint32]$raw }
                $written = Format-TcIecLiteral -Raw $raw -TypeInfo $timeType
                $rawField = $timeType.Field
                $rawValue = $typed
            }
            else {
                switch -Regex ($upper) {
                    '^BOOL$'           { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([bool]) -TypeName $typeName }
                    '^SINT$'           { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([sbyte]) -TypeName $typeName }
                    '^USINT$|^BYTE$'   { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([byte]) -TypeName $typeName }
                    '^INT$'            { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([int16]) -TypeName $typeName }
                    '^UINT$|^WORD$'    { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([uint16]) -TypeName $typeName }
                    '^DINT$'           { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([int32]) -TypeName $typeName }
                    '^UDINT$|^DWORD$'  { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([uint32]) -TypeName $typeName }
                    '^LINT$'           { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([int64]) -TypeName $typeName }
                    '^ULINT$|^LWORD$'  { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([uint64]) -TypeName $typeName }
                    '^REAL$'           { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([float]) -TypeName $typeName }
                    '^LREAL$'          { $typed = ConvertTo-TcTypedValue -Value $Value -Type ([double]) -TypeName $typeName }
                    '^STRING' {
                        $strLen = if ($typeSize -gt 0) { $typeSize } else { 255 }
                        $typed = ConvertTo-TcTypedValue -Value $Value -Type ([string]) -TypeName $typeName
                    }
                    default {
                        # Enum (or integer alias): scalar only; ARRAY/POINTER symbols report the element's
                        # DataTypeId and must not be written as one integer (Resolve-TcAdsScalarIntegerType).
                        $enum = $null
                        $intType = Resolve-TcAdsScalarIntegerType -TypeName $typeName -DataTypeId $typeId -Size $typeSize -Enum ([ref]$enum)
                        if ($null -eq $intType) {
                            $hint = Get-TcErrorHint 'TYPE_MISMATCH'
                            $why = "Write the members of a STRUCT/ARRAY individually."
                            if ($script:TcAdsEnumCacheError) { $why += " Enum table unavailable: $($script:TcAdsEnumCacheError)" }
                            return New-TcResult -Success $false -ErrorCode 'TYPE_MISMATCH' -Hint $hint `
                                -ErrorMessage "Unsupported type for write: $typeName (size $typeSize, dataTypeId $typeId). $why"
                        }
                        $v = Unwrap-TcValue $Value
                        if ($v -is [string] -and $v.Trim() -notmatch '^[+-]?\d+$') {
                            if ($null -eq $enum) {
                                $why = if ($script:TcAdsEnumCacheError) { " (enum table unavailable: $($script:TcAdsEnumCacheError))" } else { '' }
                                throw "'$v' is not a number and $typeName has no known enum members$why."
                            }
                            $v = Resolve-TcEnumMemberValue -Enum $enum -Name $v
                        }
                        $typed = ConvertTo-TcTypedValue -Value $v -Type $intType -TypeName $typeName
                        if ($null -ne $enum) { $enumName = Get-TcEnumMemberName -Enum $enum -Value $typed }
                    }
                }
                $written = $typed
            }
        }
        catch {
            $hint = Get-TcErrorHint 'TYPE_MISMATCH'
            return New-TcResult -Success $false -ErrorCode 'TYPE_MISMATCH' -Hint $hint `
                -ErrorMessage "Cannot convert value for $Path ($typeName): $($_.Exception.Message)"
        }

        # --- Write ---
        $handle = $script:TcAdsClient.CreateVariableHandle($Path)
        try {
            if ($strLen -gt 0) { $script:TcAdsClient.WriteAny($handle, [string]$typed, @([int]$strLen)) }
            else { $script:TcAdsClient.WriteAny($handle, $typed) }
        }
        finally {
            try { $script:TcAdsClient.DeleteVariableHandle($handle) } catch { }
        }

        $data = [ordered]@{
            path    = $Path
            written = $written
            type    = $typeName
        }
        if ($null -ne $rawField) { $data[$rawField] = $rawValue }
        if ($null -ne $enumName) { $data.name = $enumName }
        $data.reconnected = $reconnected
        New-TcResult -Success $true -Data ([PSCustomObject]$data)
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'ADS_WRITE_FAILED' -MessagePrefix 'Failed to write variable'
    }
}
