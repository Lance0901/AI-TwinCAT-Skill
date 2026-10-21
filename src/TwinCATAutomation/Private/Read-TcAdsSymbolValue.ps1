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

        # Enum or integer alias. The symbol's DataTypeId is the ELEMENT type for arrays/pointers too
        # (ARRAY [0..7] OF BYTE reports id 17, size 8), so only a scalar whose size matches counts.
        $enum = $null
        $intType = Resolve-TcAdsScalarIntegerType -TypeName $typeName -DataTypeId $typeId -Size $typeSize -Enum ([ref]$enum)
        if ($null -ne $intType) {
            $entry.value = $script:TcAdsClient.ReadAny($handle, $intType)
            if ($null -ne $enum) {
                $entry.name = Get-TcEnumMemberName -Enum $enum -Value $entry.value
                if ($null -eq $entry.name) {
                    $entry.hint = "Value $($entry.value) is not a member of $($enum.Name) (members: $(Format-TcEnumMembers -Enum $enum))."
                }
            }
            elseif ($script:TcAdsEnumCacheError) {
                # Integer-typed symbol with a non-builtin type name and no enum table: probably an enum we cannot name
                $entry.name = $null
                $entry.hint = "Enum member names unavailable: $($script:TcAdsEnumCacheError)"
            }
            return $entry
        }

        # Alias of STRING / BOOL / REAL / LREAL (e.g. T_MaxString, a STRING(255) member typed through a
        # DUT alias): the type name is not a builtin, so decide by the ADS data type id of the symbol
        # (ADST_REAL32 4, ADST_REAL64 5, ADST_STRING 30, ADST_BIT 33) when the size fits a scalar.
        # Arrays keep the element id, hence the ARRAY / POINTER / REFERENCE exclusion (#32 item 6).
        if ($upper -notmatch '^(ARRAY|POINTER TO|REFERENCE TO)\b') {
            if ($typeId -eq 30 -and $typeSize -gt 0) {
                $entry.value = $script:TcAdsClient.ReadAny($handle, [string], @([int]$typeSize))
                return $entry
            }
            if ($typeId -eq 33 -and $typeSize -eq 1) { $entry.value = $script:TcAdsClient.ReadAny($handle, [bool]); return $entry }
            if ($typeId -eq 4 -and $typeSize -eq 4) { $entry.value = $script:TcAdsClient.ReadAny($handle, [float]); return $entry }
            if ($typeId -eq 5 -and $typeSize -eq 8) { $entry.value = $script:TcAdsClient.ReadAny($handle, [double]); return $entry }
        }

        # STRUCT / ARRAY / POINTER / unknown: raw bytes
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

function Resolve-TcAdsScalarIntegerType {
    <#
    .SYNOPSIS
        .NET integer type for a non-builtin symbol type that is a scalar enum or integer alias; $null for
        arrays, pointers, references, structs and anything whose byte size does not match the integer.
        Sets $Enum.Value to the enum descriptor when the type is an enum.
    #>
    param([string]$TypeName, [int]$DataTypeId, [int]$Size, [ref]$Enum)
    $Enum.Value = $null
    if ($TypeName.ToUpperInvariant() -match '^(ARRAY|POINTER TO|REFERENCE TO)\b') { return $null }
    $e = Find-TcEnumType -TypeName $TypeName
    $intType = $null
    if ($null -ne $e) { $intType = Get-TcAdsIntegerType -DataTypeId $DataTypeId -BaseTypeName $e.BaseType -Size $Size }
    elseif ($script:TcAdsIntegerTypeIds.ContainsKey($DataTypeId)) { $intType = $script:TcAdsIntegerTypeIds[$DataTypeId] }
    if ($null -eq $intType) { return $null }
    if ((Get-TcIntegerTypeSize -Type $intType) -ne $Size) { return $null }
    $Enum.Value = $e
    return $intType
}
