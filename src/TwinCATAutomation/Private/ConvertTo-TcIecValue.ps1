# IEC 61131-3 value conversion helpers shared by Read-/Write-/Watch-TcVariable.
# Keep this file ASCII only (Windows PowerShell 5.1 reads BOM-less files as ANSI).
#
# Time/date types on the wire (TwinCAT 3):
#   TIME, TOD/TIME_OF_DAY            UINT32  milliseconds
#   DATE, DT/DATE_AND_TIME           UINT32  seconds since 1970-01-01 00:00:00 (no time zone)
#   LTIME, LTOD/LTIME_OF_DAY         UINT64  nanoseconds
#   LDATE, LDT/LDATE_AND_TIME        UINT64  nanoseconds since 1970-01-01
# Read/Write report these as the IEC literal ("T#6s", "DT#2026-10-20-12:30:00") in value/written and the
# raw integer in an auxiliary field named by Field: ms (TIME/TOD), ns (LTIME/LTOD/LDATE/LDT), unix (DATE/DT).
# Enums are their base integer type (INT by default); member names come from Get-TcEnumTable.

$script:TcIecTimeTypes = @{
    'TIME'           = @{ Kind = 'TIME';  Family = 'duration'; Unit = 'ms'; Field = 'ms';   Bits = 32; Prefix = 'T#' }
    'LTIME'          = @{ Kind = 'LTIME'; Family = 'duration'; Unit = 'ns'; Field = 'ns';   Bits = 64; Prefix = 'LTIME#' }
    'TOD'            = @{ Kind = 'TOD';   Family = 'tod';      Unit = 'ms'; Field = 'ms';   Bits = 32; Prefix = 'TOD#' }
    'TIME_OF_DAY'    = @{ Kind = 'TOD';   Family = 'tod';      Unit = 'ms'; Field = 'ms';   Bits = 32; Prefix = 'TOD#' }
    'LTOD'           = @{ Kind = 'LTOD';  Family = 'tod';      Unit = 'ns'; Field = 'ns';   Bits = 64; Prefix = 'LTOD#' }
    'LTIME_OF_DAY'   = @{ Kind = 'LTOD';  Family = 'tod';      Unit = 'ns'; Field = 'ns';   Bits = 64; Prefix = 'LTOD#' }
    'DATE'           = @{ Kind = 'DATE';  Family = 'date';     Unit = 's';  Field = 'unix'; Bits = 32; Prefix = 'D#' }
    'LDATE'          = @{ Kind = 'LDATE'; Family = 'date';     Unit = 'ns'; Field = 'ns';   Bits = 64; Prefix = 'LDATE#' }
    'DT'             = @{ Kind = 'DT';    Family = 'dt';       Unit = 's';  Field = 'unix'; Bits = 32; Prefix = 'DT#' }
    'DATE_AND_TIME'  = @{ Kind = 'DT';    Family = 'dt';       Unit = 's';  Field = 'unix'; Bits = 32; Prefix = 'DT#' }
    'LDT'            = @{ Kind = 'LDT';   Family = 'dt';       Unit = 'ns'; Field = 'ns';   Bits = 64; Prefix = 'LDT#' }
    'LDATE_AND_TIME' = @{ Kind = 'LDT';   Family = 'dt';       Unit = 'ns'; Field = 'ns';   Bits = 64; Prefix = 'LDT#' }
}

# Literal prefix -> family (what the text after '#' looks like)
$script:TcIecPrefixFamily = @{
    'T' = 'duration'; 'TIME' = 'duration'; 'LT' = 'duration'; 'LTIME' = 'duration'
    'TOD' = 'tod'; 'TIME_OF_DAY' = 'tod'; 'LTOD' = 'tod'; 'LTIME_OF_DAY' = 'tod'
    'D' = 'date'; 'DATE' = 'date'; 'LD' = 'date'; 'LDATE' = 'date'
    'DT' = 'dt'; 'DATE_AND_TIME' = 'dt'; 'LDT' = 'dt'; 'LDATE_AND_TIME' = 'dt'
}

$script:TcIecEpoch = [DateTime]::new(1970, 1, 1, 0, 0, 0, [DateTimeKind]::Unspecified)

# ADS data type ids (AdsDatatypeId) -> .NET type, used for enums and integer aliases
$script:TcAdsIntegerTypeIds = @{
    16 = [sbyte]; 17 = [byte]; 2 = [int16]; 18 = [uint16]; 3 = [int32]; 19 = [uint32]; 20 = [int64]; 21 = [uint64]
}
$script:TcIecIntegerTypeSizes = @{
    'SByte' = 1; 'Byte' = 1; 'Int16' = 2; 'UInt16' = 2; 'Int32' = 4; 'UInt32' = 4; 'Int64' = 8; 'UInt64' = 8
}
$script:TcIecIntegerTypeNames = @{
    'SINT' = [sbyte]; 'USINT' = [byte]; 'BYTE' = [byte]; 'INT' = [int16]; 'UINT' = [uint16]; 'WORD' = [uint16]
    'DINT' = [int32]; 'UDINT' = [uint32]; 'DWORD' = [uint32]; 'LINT' = [int64]; 'ULINT' = [uint64]; 'LWORD' = [uint64]
}

function Get-TcIecTimeType {
    <#
    .SYNOPSIS
        Returns the time/date descriptor (Kind/Family/Unit/Field/Bits/Prefix) for a PLC type name, or $null.
    #>
    param([string]$TypeName)
    if ([string]::IsNullOrWhiteSpace($TypeName)) { return $null }
    $key = $TypeName.Trim().ToUpperInvariant()
    if ($script:TcIecTimeTypes.ContainsKey($key)) { return $script:TcIecTimeTypes[$key] }
    return $null
}

function Get-TcAdsIntegerType {
    <#
    .SYNOPSIS
        .NET integer type for an ADS DataTypeId / base type name / size, or $null.
    #>
    param([int]$DataTypeId, [string]$BaseTypeName, [int]$Size)
    if ($script:TcAdsIntegerTypeIds.ContainsKey($DataTypeId)) { return $script:TcAdsIntegerTypeIds[$DataTypeId] }
    if (-not [string]::IsNullOrWhiteSpace($BaseTypeName)) {
        $k = $BaseTypeName.Trim().ToUpperInvariant()
        if ($script:TcIecIntegerTypeNames.ContainsKey($k)) { return $script:TcIecIntegerTypeNames[$k] }
    }
    switch ($Size) {
        1 { return [byte] }
        2 { return [int16] }
        4 { return [int32] }
        8 { return [int64] }
    }
    return $null
}

function Get-TcIntegerTypeSize {
    # Byte size of a .NET integer type ([int16] -> 2); 0 when unknown.
    param([type]$Type)
    if ($null -eq $Type) { return 0 }
    if ($script:TcIecIntegerTypeSizes.ContainsKey($Type.Name)) { return $script:TcIecIntegerTypeSizes[$Type.Name] }
    return 0
}

function Unwrap-TcValue {
    # A value that reached a parameter wrapped in a PSObject (pipeline output, (Write-Output 5), 1e3 in
    # command mode) is unwrapped; plain values come back unchanged. $Value.BaseObject would be $null here.
    param($Value)
    if ($Value -is [System.Management.Automation.PSObject]) { return $Value.PSObject.BaseObject }
    return $Value
}

function Test-TcJsonContainer {
    # JSON objects / arrays coming through the CLI, the bridge or ConvertFrom-Json.
    param($Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    return ($Value -is [System.Management.Automation.PSCustomObject]) -or
           ($Value -is [System.Collections.IDictionary]) -or
           ($Value -is [System.Collections.IList])
}

function ConvertTo-TcTypedValue {
    <#
    .SYNOPSIS
        Converts a user value (JSON number/bool/string, PowerShell scalar) to the .NET type
        that WriteAny needs. Throws a descriptive exception on mismatch or overflow.
    .PARAMETER Value
        Input value.
    .PARAMETER Type
        Target .NET type ([bool], [int16], [uint32], [double], ...).
    .PARAMETER TypeName
        PLC type name used in error messages.
    #>
    param($Value, [type]$Type, [string]$TypeName)

    $Value = Unwrap-TcValue $Value
    if ($null -eq $Value) { throw "Value is null; $TypeName needs a value." }
    if (Test-TcJsonContainer $Value) { throw "Value is a JSON object/array; $TypeName needs a scalar." }

    if ($Type -eq [bool]) {
        if ($Value -is [bool]) { return [bool]$Value }
        if ($Value -is [string]) {
            $s = $Value.Trim()
            if ($s -match '^(?i)(true|1)$') { return $true }
            if ($s -match '^(?i)(false|0)$') { return $false }
            throw "'$Value' is not a BOOL (use true/false)."
        }
        if ($Value -is [ValueType]) {
            $d = [double]$Value
            if ($d -eq 0) { return $false }
            if ($d -eq 1) { return $true }
            throw "$Value is not a BOOL (use true/false or 0/1)."
        }
        throw "Value of type $($Value.GetType().Name) is not a BOOL."
    }

    if ($Type -eq [string]) {
        if ($Value -is [bool]) { if ($Value) { return 'TRUE' } else { return 'FALSE' } }
        return [string]$Value
    }

    # Numeric targets
    if ($Value -is [bool]) { throw "BOOL value $Value cannot be written to $TypeName; send a number." }
    $num = $null
    if ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -notmatch '^[+-]?(\d+(\.\d*)?|\.\d+)([eE][+-]?\d+)?$') {
            throw "'$Value' is not a number ($TypeName expects a numeric value)."
        }
        try {
            if ($s -match '^[+-]?\d+$') { $num = [decimal]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture) }
            else { $num = [double]::Parse($s, [System.Globalization.CultureInfo]::InvariantCulture) }
        }
        catch { throw "'$Value' is not a number $TypeName can hold: $($_.Exception.Message)" }
    }
    elseif ($Value -is [char]) { throw "'$Value' is a character, not a number." }
    elseif ($Value -is [ValueType]) { $num = $Value }
    else { throw "Value of type $($Value.GetType().Name) cannot be written to $TypeName." }

    $isReal = ($Type -eq [double] -or $Type -eq [single])
    try {
        if ($isReal) {
            return [System.Convert]::ChangeType($num, $Type, [System.Globalization.CultureInfo]::InvariantCulture)
        }
        # Integer target: no silent rounding
        $dec = $null
        if ($num -is [double] -or $num -is [single]) {
            $d = [double]$num
            if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -ne [Math]::Truncate($d)) {
                throw "$num is not an integer ($TypeName has no fraction)."
            }
            if ([Math]::Abs($d) -gt 79228162514264337593543950335) { throw "$num is out of range for $TypeName." }
            $dec = [decimal]$d
        }
        else { $dec = [decimal]$num }
        if ($dec -ne [decimal]::Truncate($dec)) { throw "$num is not an integer ($TypeName has no fraction)." }
        return [System.Convert]::ChangeType($dec, $Type, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch [System.OverflowException] {
        $min = $Type.GetField('MinValue').GetValue($null)
        $max = $Type.GetField('MaxValue').GetValue($null)
        throw "$num is out of range for $TypeName ($min..$max)."
    }
}

function ConvertFrom-TcIecLiteral {
    <#
    .SYNOPSIS
        Converts a user value to the raw unsigned integer of a TIME/TOD/DATE/DT (and L*) symbol.
    .DESCRIPTION
        Accepts
          * integers: TIME/TOD = ms, LTIME/LTOD = ns, DATE/DT = seconds since 1970, LDATE/LDT = ns since 1970
          * IEC literals: T#5s, T#1m30s500ms, LTIME#1us, TOD#12:30:00.500, D#2026-10-20,
            DT#2026-10-20-12:30:00, LDT#2026-10-20-12:30:00.123456789 (prefix optional)
          * ISO 8601 for DATE/DT: 2026-10-20, 2026-10-20T12:30:00, 2026-10-20T12:30:00+08:00 (offset -> UTC)
          * [DateTime] objects for DATE/DT (clock value taken as is)
        Returns [uint64]; throws with a descriptive message on bad input.
    #>
    param($Value, [hashtable]$TypeInfo)

    $kind = $TypeInfo.Kind
    $family = $TypeInfo.Family
    $unit = $TypeInfo.Unit
    $max = if ($TypeInfo.Bits -eq 64) { [uint64]::MaxValue } else { [uint64][uint32]::MaxValue }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    $Value = Unwrap-TcValue $Value
    if ($null -eq $Value) { throw "Value is null; $kind needs a value." }
    if (Test-TcJsonContainer $Value) { throw "Value is a JSON object/array; $kind needs an integer or a literal string." }

    $rawNs = $null      # [decimal] nanoseconds (duration / tod / dt / date) when parsed from text
    $raw = $null        # [uint64] when given as a number

    if ($Value -is [DateTime]) {
        if ($family -ne 'date' -and $family -ne 'dt') { throw "A DateTime cannot be written to $kind." }
        $dtv = [DateTime]::SpecifyKind($Value, [DateTimeKind]::Unspecified)
        if ($family -eq 'date') { $dtv = $dtv.Date }
        if ($dtv -lt $script:TcIecEpoch) { throw "$($dtv.ToString('yyyy-MM-dd HH:mm:ss')) is before 1970-01-01; not representable in $kind." }
        $rawNs = [decimal]($dtv - $script:TcIecEpoch).Ticks * 100
    }
    elseif ($Value -is [bool]) { throw "BOOL value $Value cannot be written to $kind." }
    elseif ($Value -is [string]) {
        $s = $Value.Trim()
        if ($s -match '^\+?\d+$') {
            try { $raw = [uint64]::Parse($s.TrimStart('+'), $inv) }
            catch { throw "'$s' is out of range for $kind (max $max $unit)." }
        }
        else {
            $prefix = $null
            $body = $s
            if ($s -match '^(?i)([A-Z_]+)#(.*)$') {
                $prefix = $Matches[1].ToUpperInvariant()
                $body = $Matches[2].Trim()
                if (-not $script:TcIecPrefixFamily.ContainsKey($prefix)) {
                    throw "'$s' has an unknown IEC literal prefix '$prefix#'."
                }
                $litFamily = $script:TcIecPrefixFamily[$prefix]
                if ($litFamily -ne $family) {
                    throw "'$s' is a $litFamily literal but the symbol is $kind."
                }
            }
            if ($body.StartsWith('-')) { throw "'$s': $kind is unsigned, negative values are not supported." }
            switch ($family) {
                'duration' { $rawNs = ConvertFrom-TcDurationBody -Body $body -Original $s }
                'tod'      { $rawNs = ConvertFrom-TcTodBody -Body $body -Original $s }
                'date'     { $rawNs = ConvertFrom-TcDateBody -Body $body -Original $s }
                'dt'       { $rawNs = ConvertFrom-TcDtBody -Body $body -Original $s }
            }
        }
    }
    elseif ($Value -is [char]) { throw "'$Value' is a character; $kind needs an integer or a literal string." }
    elseif ($Value -is [ValueType]) {
        $d = $null
        if ($Value -is [double] -or $Value -is [single]) {
            $d = [double]$Value
            if ([double]::IsNaN($d) -or [double]::IsInfinity($d) -or $d -ne [Math]::Truncate($d)) {
                throw "$Value is not an integer; $kind takes whole $unit (or a literal like T#2.5s)."
            }
        }
        if ($null -ne $d -and [Math]::Abs($d) -gt 79228162514264337593543950335) { throw "$Value is out of range for $kind." }
        $dec = [decimal]$Value
        if ($dec -ne [decimal]::Truncate($dec)) { throw "$Value is not an integer; $kind takes whole $unit (or a literal like T#2.5s)." }
        if ($dec -lt 0) { throw "$Value is negative; $kind is unsigned." }
        if ($dec -gt [decimal][uint64]::MaxValue) { throw "$Value is out of range for $kind." }
        $raw = [uint64]$dec
    }
    else { throw "Value of type $($Value.GetType().Name) cannot be written to $kind." }

    if ($null -ne $rawNs) {
        # text -> raw in the symbol's unit; the text must be representable
        $div = switch ($unit) { 'ns' { [decimal]1 } 'ms' { [decimal]1000000 } 's' { [decimal]1000000000 } }
        $q = $rawNs / $div
        if ($q -ne [decimal]::Truncate($q)) {
            throw "'$Value' is finer than the $unit resolution of $kind (use the L-type, e.g. LTIME/LTOD/LDT, or round it)."
        }
        if ($q -gt [decimal]$max) { throw "'$Value' is out of range for $kind (max $max $unit)." }
        $raw = [uint64]$q
    }
    if ($raw -gt $max) { throw "$raw is out of range for $kind (max $max $unit)." }
    return [uint64]$raw
}

function ConvertFrom-TcDurationBody {
    # "1m30s500ms", "2.5s", "1_000ms" -> [decimal] ns
    param([string]$Body, [string]$Original)
    $b = $Body -replace '[_\s]', ''
    if ([string]::IsNullOrEmpty($b)) { throw "'$Original' has no duration." }
    $m = [regex]::Matches($b, '(?i)(\d+(?:\.\d+)?)(ms|us|ns|d|h|m|s)')
    $joined = ''
    foreach ($x in $m) { $joined += $x.Value }
    if ($m.Count -eq 0 -or $joined -ne $b) {
        throw "'$Original' is not a duration literal (expected e.g. T#1m30s500ms; units d h m s ms us ns)."
    }
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $ns = [decimal]0
    foreach ($x in $m) {
        $n = [decimal]::Parse($x.Groups[1].Value, $inv)
        $factor = switch ($x.Groups[2].Value.ToLowerInvariant()) {
            'd'  { [decimal]86400000000000 }
            'h'  { [decimal]3600000000000 }
            'm'  { [decimal]60000000000 }
            's'  { [decimal]1000000000 }
            'ms' { [decimal]1000000 }
            'us' { [decimal]1000 }
            'ns' { [decimal]1 }
        }
        $ns += $n * $factor
    }
    return $ns
}

function ConvertFrom-TcTodBody {
    # "12:30:00.500" -> [decimal] ns since midnight
    param([string]$Body, [string]$Original)
    if ($Body -notmatch '^(\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?$') {
        throw "'$Original' is not a time-of-day literal (expected TOD#HH:MM:SS[.fff])."
    }
    $h = [int]$Matches[1]; $mi = [int]$Matches[2]
    $sec = if ($Matches[3]) { [int]$Matches[3] } else { 0 }
    $frac = if ($Matches[4]) { $Matches[4] } else { '' }
    if ($h -gt 23 -or $mi -gt 59 -or $sec -gt 59) { throw "'$Original' is not a valid time of day." }
    $ns = ([decimal]($h * 3600 + $mi * 60 + $sec)) * 1000000000
    if ($frac.Length -gt 0) { $ns += [decimal]::Parse($frac.PadRight(9, '0'), [System.Globalization.CultureInfo]::InvariantCulture) }
    return $ns
}

function ConvertFrom-TcDateBody {
    # "2026-10-20" -> [decimal] ns since 1970-01-01
    param([string]$Body, [string]$Original)
    if ($Body -notmatch '^(\d{4})-(\d{2})-(\d{2})$') {
        throw "'$Original' is not a date literal (expected D#yyyy-MM-dd or ISO yyyy-MM-dd)."
    }
    try { $d = [DateTime]::new([int]$Matches[1], [int]$Matches[2], [int]$Matches[3], 0, 0, 0, [DateTimeKind]::Unspecified) }
    catch { throw "'$Original' is not a valid date." }
    if ($d -lt $script:TcIecEpoch) { throw "'$Original' is before 1970-01-01; not representable." }
    return [decimal]($d - $script:TcIecEpoch).Ticks * 100
}

function ConvertFrom-TcDtBody {
    # IEC "2026-10-20-12:30:00[.fff]" or ISO "2026-10-20T12:30[:00[.fff]][Z|+08:00]" -> [decimal] ns since 1970-01-01
    param([string]$Body, [string]$Original)
    $iec = '^(\d{4})-(\d{2})-(\d{2})-(\d{1,2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?$'
    $iso = '^(\d{4})-(\d{2})-(\d{2})[T ](\d{1,2}):(\d{2})(?::(\d{2})(?:\.(\d{1,9}))?)?(Z|[+-]\d{2}:?\d{2})?$'
    $offsetMin = 0
    if ($Body -match $iec) {
        $y = [int]$Matches[1]; $mo = [int]$Matches[2]; $d = [int]$Matches[3]
        $h = [int]$Matches[4]; $mi = [int]$Matches[5]; $sec = [int]$Matches[6]
        $frac = if ($Matches[7]) { $Matches[7] } else { '' }
    }
    elseif ($Body -match $iso) {
        $y = [int]$Matches[1]; $mo = [int]$Matches[2]; $d = [int]$Matches[3]
        $h = [int]$Matches[4]; $mi = [int]$Matches[5]
        $sec = if ($Matches[6]) { [int]$Matches[6] } else { 0 }
        $frac = if ($Matches[7]) { $Matches[7] } else { '' }
        $tz = $Matches[8]
        if ($tz -and $tz -ne 'Z') {
            $sign = if ($tz[0] -eq '-') { -1 } else { 1 }
            $digits = $tz.Substring(1) -replace ':', ''
            $offsetMin = $sign * ([int]$digits.Substring(0, 2) * 60 + [int]$digits.Substring(2, 2))
        }
    }
    else {
        throw "'$Original' is not a date-and-time literal (expected DT#yyyy-MM-dd-HH:MM:SS or ISO yyyy-MM-ddTHH:MM:SS[Z|+hh:mm])."
    }
    if ($h -gt 23 -or $mi -gt 59 -or $sec -gt 59) { throw "'$Original' is not a valid time of day." }
    try { $dtv = [DateTime]::new($y, $mo, $d, $h, $mi, $sec, [DateTimeKind]::Unspecified) }
    catch { throw "'$Original' is not a valid date." }
    if ($offsetMin -ne 0) { $dtv = $dtv.AddMinutes(-$offsetMin) }   # local-with-offset -> UTC clock
    $ns = [decimal]($dtv - $script:TcIecEpoch).Ticks * 100
    if ($frac.Length -gt 0) { $ns += [decimal]::Parse($frac.PadRight(9, '0'), [System.Globalization.CultureInfo]::InvariantCulture) }
    if ($ns -lt 0) { throw "'$Original' is before 1970-01-01; not representable." }
    return $ns
}

function Format-TcIecLiteral {
    <#
    .SYNOPSIS
        Formats the raw value of a TIME/TOD/DATE/DT (and L*) symbol as its IEC literal.
    #>
    param([uint64]$Raw, [hashtable]$TypeInfo)

    $kind = $TypeInfo.Kind
    $prefix = $TypeInfo.Prefix
    $mult = switch ($TypeInfo.Unit) { 'ns' { [decimal]1 } 'ms' { [decimal]1000000 } 's' { [decimal]1000000000 } }
    $ns = [decimal]$Raw * $mult
    $inv = [System.Globalization.CultureInfo]::InvariantCulture

    switch ($TypeInfo.Family) {
        'duration' {
            $rest = $ns
            $parts = @()
            foreach ($u in @(@('d', [decimal]86400000000000), @('h', [decimal]3600000000000), @('m', [decimal]60000000000),
                             @('s', [decimal]1000000000), @('ms', [decimal]1000000), @('us', [decimal]1000), @('ns', [decimal]1))) {
                $n = [decimal]::Truncate($rest / $u[1])
                if ($n -gt 0) { $parts += ("{0}{1}" -f $n.ToString($inv), $u[0]); $rest -= $n * $u[1] }
            }
            if ($parts.Count -eq 0) { $parts = @($(if ($TypeInfo.Unit -eq 'ns') { '0ns' } else { '0ms' })) }
            return $prefix + ($parts -join '')
        }
        'tod' {
            $totalSec = [decimal]::Truncate($ns / 1000000000)
            $fracNs = $ns - $totalSec * 1000000000
            $h = [decimal]::Truncate($totalSec / 3600)
            $mi = [decimal]::Truncate(($totalSec - $h * 3600) / 60)
            $sec = $totalSec - $h * 3600 - $mi * 60
            $text = '{0:00}:{1:00}:{2:00}' -f [int]$h, [int]$mi, [int]$sec
            $text += Format-TcIecFraction -FracNs $fracNs -Unit $TypeInfo.Unit
            return $prefix + $text
        }
        'date' {
            $ticks = [long][decimal]::Truncate($ns / 100)
            $d = $script:TcIecEpoch.AddTicks($ticks)
            return $prefix + $d.ToString('yyyy-MM-dd', $inv)
        }
        'dt' {
            $ticks = [long][decimal]::Truncate($ns / 100)
            $d = $script:TcIecEpoch.AddTicks($ticks)
            $wholeSec = [decimal]::Truncate($ns / 1000000000)
            $fracNs = $ns - $wholeSec * 1000000000
            $text = $d.ToString('yyyy-MM-dd-HH:mm:ss', $inv)
            $text += Format-TcIecFraction -FracNs $fracNs -Unit $TypeInfo.Unit
            return $prefix + $text
        }
    }
    return "$prefix$Raw"
}

function Format-TcIecFraction {
    # sub-second part: ".500" for ms types, ".123456789" (trailing zeros trimmed) for ns types; "" when zero
    param([decimal]$FracNs, [string]$Unit)
    if ($FracNs -le 0) { return '' }
    if ($Unit -eq 'ms') {
        $ms = [int][decimal]::Truncate($FracNs / 1000000)
        return '.' + ('{0:000}' -f $ms)
    }
    $digits = ('{0:000000000}' -f [long]$FracNs).TrimEnd('0')
    if ($digits.Length -eq 0) { return '' }
    return '.' + $digits
}
