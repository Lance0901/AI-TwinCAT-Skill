# Enum member names of the connected runtime (ADS data type table), cached per ADS session.
# Keep this file ASCII only.

function Get-TcEnumTable {
    <#
    .SYNOPSIS
        Returns a hashtable  typeName -> @{ Name; BaseType; Size; Values ([ordered] name -> value); ByValue (string(value) -> name) }
        for every enum type the runtime publishes. Cached in $script:TcAdsEnumCache until the ADS
        session is (re)connected or -Refresh is given. Never throws: when the table cannot be read the
        result is empty and $script:TcAdsEnumCacheError holds the reason.
    #>
    [CmdletBinding()]
    param([switch]$Refresh)

    if (-not $Refresh -and $null -ne $script:TcAdsEnumCache) { return $script:TcAdsEnumCache }

    $table = @{}
    $script:TcAdsEnumCacheError = $null
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
            $table[[string]$e['Name']] = @{
                Name     = [string]$e['Name']
                BaseType = [string]$e['BaseType']
                Size     = [int]$e['Size']
                Values   = $values
                ByValue  = $byValue
            }
        }
    }
    catch {
        $script:TcAdsEnumCacheError = $_.Exception.Message
    }
    $script:TcAdsEnumCache = $table
    return $table
}

function Find-TcEnumType {
    <#
    .SYNOPSIS
        Enum descriptor (see Get-TcEnumTable) for a symbol's type name, or $null when the type is not an enum.
    .DESCRIPTION
        Exact match first, then case-insensitive, then by unqualified name (library enums are listed as
        "Tc2_MC2.MC_Direction" in the type table).
    #>
    param([string]$TypeName)
    if ([string]::IsNullOrWhiteSpace($TypeName)) { return $null }
    $t = Get-TcEnumTable
    if ($t.Count -eq 0) { return $null }
    if ($t.ContainsKey($TypeName)) { return $t[$TypeName] }
    foreach ($k in $t.Keys) { if ($k -ieq $TypeName) { return $t[$k] } }
    $short = $TypeName
    if ($short.Contains('.')) { $short = $short.Substring($short.LastIndexOf('.') + 1) }
    $pattern = '(^|\.)' + [regex]::Escape($short) + '$'
    $hits = @($t.Keys | Where-Object { $_ -imatch $pattern })
    if ($hits.Count -eq 1) { return $t[$hits[0]] }
    return $null
}

function Get-TcEnumMemberName {
    <#
    .SYNOPSIS
        Member name for a raw enum value, or $null.
    #>
    param([hashtable]$Enum, $Value)
    if ($null -eq $Enum) { return $null }
    $key = [string]([long]$Value)
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
