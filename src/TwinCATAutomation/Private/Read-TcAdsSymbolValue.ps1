# Typed ADS read of one symbol, shared by Read-TcVariable (and through it Watch-TcVariable).
# Keep this file ASCII only.

function Read-TcAdsSymbolValue {
    <#
    .SYNOPSIS
        Reads one symbol and converts it by PLC type. Returns an [ordered] hashtable:
          path, value, type                      always
          ms / ns / unix                         TIME/TOD (ms), LTIME/LTOD/LDATE/LDT (ns), DATE/DT (unix seconds): the raw
                                                 integer; value is the IEC literal ("T#6s", "DT#2026-10-20-12:30:00")
          name                                   enum: member name (null when unknown, see hint)
          size                                   STRUCT/ARRAY/unknown: byte count (value is the raw byte array as int[])
          hint                                   only when an enum member name could not be produced
        Throws on ADS errors (symbol not found, read failed); the caller maps them.
    .PARAMETER VarPath
        Symbol path.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$VarPath)

    $symInfo = [TcAdsHelper]::GetSymbolInfo($script:TcAdsClient, $VarPath)
    $typeName = [string]$symInfo['TypeName']
    $typeSize = [int]$symInfo['Size']
    $typeId = [int]$symInfo['DataTypeId']
    $upper = $typeName.ToUpperInvariant()

    $entry = [ordered]@{ path = $VarPath; value = $null; type = $typeName }
    $handle = $script:TcAdsClient.CreateVariableHandle($VarPath)
    try {
        $timeType = Get-TcIecTimeType -TypeName $typeName
        if ($null -ne $timeType) {
            $raw = if ($typeSize -ge 8) { [uint64]$script:TcAdsClient.ReadAny($handle, [uint64]) }
                   else { [uint64]$script:TcAdsClient.ReadAny($handle, [uint32]) }
            $entry.value = Format-TcIecLiteral -Raw $raw -TypeInfo $timeType
            $entry[$timeType.Field] = if ($typeSize -ge 8) { [uint64]$raw } else { [uint32]$raw }
            return $entry
        }

        switch -Regex ($upper) {
            '^BOOL$'           { $entry.value = $script:TcAdsClient.ReadAny($handle, [bool]); return $entry }
            '^SINT$'           { $entry.value = $script:TcAdsClient.ReadAny($handle, [sbyte]); return $entry }
            '^USINT$|^BYTE$'   { $entry.value = $script:TcAdsClient.ReadAny($handle, [byte]); return $entry }
            '^INT$'            { $entry.value = $script:TcAdsClient.ReadAny($handle, [int16]); return $entry }
            '^UINT$|^WORD$'    { $entry.value = $script:TcAdsClient.ReadAny($handle, [uint16]); return $entry }
            '^DINT$'           { $entry.value = $script:TcAdsClient.ReadAny($handle, [int32]); return $entry }
            '^UDINT$|^DWORD$'  { $entry.value = $script:TcAdsClient.ReadAny($handle, [uint32]); return $entry }
            '^LINT$'           { $entry.value = $script:TcAdsClient.ReadAny($handle, [int64]); return $entry }
            '^ULINT$|^LWORD$'  { $entry.value = $script:TcAdsClient.ReadAny($handle, [uint64]); return $entry }
            '^REAL$'           { $entry.value = $script:TcAdsClient.ReadAny($handle, [float]); return $entry }
            '^LREAL$'          { $entry.value = $script:TcAdsClient.ReadAny($handle, [double]); return $entry }
            '^STRING' {
                $strLen = if ($typeSize -gt 0) { $typeSize } else { 255 }
                $entry.value = $script:TcAdsClient.ReadAny($handle, [string], @([int]$strLen))
                return $entry
            }
        }

        # Enum or integer alias: the symbol's DataTypeId tells the base integer type
        $enum = Find-TcEnumType -TypeName $typeName
        $intType = $null
        if ($null -ne $enum) { $intType = Get-TcAdsIntegerType -DataTypeId $typeId -BaseTypeName $enum.BaseType -Size $typeSize }
        elseif ($script:TcAdsIntegerTypeIds.ContainsKey($typeId)) { $intType = $script:TcAdsIntegerTypeIds[$typeId] }

        if ($null -ne $intType) {
            $entry.value = $script:TcAdsClient.ReadAny($handle, $intType)
            if ($null -ne $enum) {
                $entry.name = Get-TcEnumMemberName -Enum $enum -Value $entry.value
                if ($null -eq $entry.name) {
                    $entry.hint = "Value $($entry.value) is not a member of $($enum.Name) (members: $(($enum.Values.Keys | ForEach-Object { "$_=$($enum.Values[$_])" }) -join ', '))."
                }
            }
            elseif ($script:TcAdsEnumCacheError -and ($null -eq $script:TcAdsEnumCache -or $script:TcAdsEnumCache.Count -eq 0)) {
                # Integer-typed symbol with a non-builtin type name and no enum table: probably an enum we cannot name
                $entry.name = $null
                $entry.hint = "Enum member names unavailable: $($script:TcAdsEnumCacheError)"
            }
            return $entry
        }

        # STRUCT / ARRAY / unknown: raw bytes
        $buffer = New-Object byte[] $typeSize
        $null = $script:TcAdsClient.Read($handle, $buffer)
        $entry.value = [int[]]$buffer
        $entry.size = $typeSize
        return $entry
    }
    finally {
        try { $script:TcAdsClient.DeleteVariableHandle($handle) } catch { }
    }
}
