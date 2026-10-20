# Enum member names of the connected runtime (ADS data type table), cached per ADS session
# and keyed by the runtime's symbol version (ADSIGRP_SYM_VERSION 0xF008), so a download /
# online change that changes the program invalidates it. Keep this file ASCII only.

function Get-TcAdsSymbolVersion {
    <#
    .SYNOPSIS
        Symbol table version byte of the connected runtime (0xF008), or $null when unreadable.
    #>
    try {
        $stream = New-Object TwinCAT.Ads.AdsStream 1
        $null = $script:TcAdsClient.Read([uint32]0xF008, [uint32]0, $stream)
        return [int]$stream.ToArray()[0]
    }
    catch { return $null }
}

function Get-TcEnumTable {
    <#
    .SYNOPSIS
        Returns a hashtable  typeName -> @{ Name; BaseType; Size; Values ([ordered] name -> value); ByValue (string(value) -> name) }
        for every enum type the runtime publishes.
    .DESCRIPTION
        The table is loaded once per ADS session and symbol version; a changed symbol version
        (download / online change) reloads it. A failed load is NOT cached: the error is kept in
        $script:TcAdsEnumCacheError and the next call retries after a 10 s cool-down. Never throws.
    #>
    [CmdletBinding()]
    param([switch]$Refresh)

    $version = $null
    if ($null -ne $script:TcAdsClient) { $version = Get-TcAdsSymbolVersion }
    $cacheValid = ($null -ne $script:TcAdsEnumCache) -and -not $Refresh -and
                  ($null -eq $version -or $version -eq $script:TcAdsEnumCacheVersion)
    if ($cacheValid) { return $script:TcAdsEnumCache }

    if ($null -ne $script:TcAdsEnumCacheFailedAt -and -not $Refresh -and
        ([DateTime]::UtcNow - $script:TcAdsEnumCacheFailedAt).TotalSeconds -lt 10) {
        # still in the cool-down after a failed load
        if ($null -ne $script:TcAdsEnumCache) { return $script:TcAdsEnumCache }
        return @{}
    }

    $table = @{}
    $full = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    $short = New-Object 'System.Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    try {
        if ($null -eq $script:TcAdsClient) { throw 'ADS session not connected.' }
        $helper = ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type
        if ($null -eq $helper) { throw 'TcAdsHelper is not compiled.' }
        if ($null -eq $helper.GetMethod('GetEnumTypes')) {
            throw 'TcAdsHelper has no GetEnumTypes (compiled by an older module in this process; restart PowerShell).'
        }
        $list = [TcAdsHelper]::GetEnumTypes($script:TcAdsClient)
        foreach ($e in $list) {
            $values = [ordered]@{}
            $byValue = @{}
            foreach ($v in $e['Values']) {
                $n = [string]$v['Name']
                $val = [long]$v['Value']
                $values[$n] = $val
                $key = [string]$val
                if (-not $byValue.ContainsKey($key)) { $byValue[$key] = $n }
            }
            $name = [string]$e['Name']
            $desc = @{
                Name     = $name
                BaseType = [string]$e['BaseType']
                Size     = [int]$e['Size']
                Values   = $values
                ByValue  = $byValue
            }
            $table[$name] = $desc
            $full[$name] = $desc
            $shortName = $name
            if ($shortName.Contains('.')) { $shortName = $shortName.Substring($shortName.LastIndexOf('.') + 1) }
            if (-not $short.ContainsKey($shortName)) { $short[$shortName] = New-Object System.Collections.ArrayList }
            $null = $short[$shortName].Add($desc)
        }
    }
    catch {
        $script:TcAdsEnumCacheError = $_.Exception.Message
        $script:TcAdsEnumCacheFailedAt = [DateTime]::UtcNow
        if ($null -ne $script:TcAdsEnumCache) { return $script:TcAdsEnumCache }   # keep the previous table
        return @{}
    }
    $script:TcAdsEnumCache = $table
    $script:TcAdsEnumIndex = @{ Full = $full; Short = $short }
    $script:TcAdsEnumCacheVersion = $version
    $script:TcAdsEnumCacheError = $null
    $script:TcAdsEnumCacheFailedAt = $null
    return $table
}

function Find-TcEnumType {
    <#
    .SYNOPSIS
        Enum descriptor (see Get-TcEnumTable) for a symbol's type name, or $null when the type is not an enum.
    .DESCRIPTION
        Case-insensitive full-name lookup first, then by unqualified name (library enums are listed as
        "Tc2_MC2.MC_Direction" in the type table) when that is unambiguous. O(1) dictionary lookups.
    #>
    param([string]$TypeName)
    if ([string]::IsNullOrWhiteSpace($TypeName)) { return $null }
    $t = Get-TcEnumTable
    if ($t.Count -eq 0 -or $null -eq $script:TcAdsEnumIndex) { return $null }
    $idx = $script:TcAdsEnumIndex
    if ($idx.Full.ContainsKey($TypeName)) { return $idx.Full[$TypeName] }
    $shortName = $TypeName
    if ($shortName.Contains('.')) { $shortName = $shortName.Substring($shortName.LastIndexOf('.') + 1) }
    if ($idx.Short.ContainsKey($shortName) -and $idx.Short[$shortName].Count -eq 1) { return $idx.Short[$shortName][0] }
    return $null
}

function Get-TcEnumMemberName {
    <#
    .SYNOPSIS
        Member name for a raw enum value, or $null.
    #>
    param([hashtable]$Enum, $Value)
    if ($null -eq $Enum -or $null -eq $Value) { return $null }
    $key = [string]$Value      # integer types print as plain digits; no [long] cast so ULINT values above 2^63 do not throw
    if ($Enum.ByValue.ContainsKey($key)) { return $Enum.ByValue[$key] }
    return $null
}

function Resolve-TcEnumMemberValue {
    <#
    .SYNOPSIS
        Raw value for an enum member name (case-insensitive). Throws listing the members when unknown.
    #>
    param([hashtable]$Enum, [string]$Name)
    $n = $Name.Trim()
    foreach ($k in $Enum.Values.Keys) {
        if ($k -ieq $n) { return [long]$Enum.Values[$k] }
    }
    $members = @()
    foreach ($k in $Enum.Values.Keys) { $members += ('{0}={1}' -f $k, $Enum.Values[$k]) }
    throw "'$Name' is not a member of $($Enum.Name) (members: $($members -join ', '))."
}

function Format-TcEnumMembers {
    # "M50=0, M80=1, ..." for hints
    param([hashtable]$Enum)
    $members = @()
    foreach ($k in $Enum.Values.Keys) { $members += ('{0}={1}' -f $k, $Enum.Values[$k]) }
    return ($members -join ', ')
}
