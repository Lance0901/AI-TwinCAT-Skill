function Get-TcSymbols {
    <#
    .SYNOPSIS
        Enumerates PLC symbols from the ADS symbol table.
    .PARAMETER Filter
        Optional wildcard filter (e.g., "MAIN.*").
    .DESCRIPTION
        Each entry has path, type, size, comment; enum-typed symbols also carry enumValues
        (member name -> integer value).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Filter
    )

    try { $reconnected = Ensure-TcAdsConnection } catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
    }

    try {
        # Ensure TcAdsHelper is compiled (needs TwinCAT.Ads.dll loaded first)
        if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
            $null = Find-TcAdsAssembly
        }

        # Use C# helper to bypass PowerShell CLS compatibility issues
        # (TcAdsSymbol has both 'Datatype' and 'DataType' which PowerShell cannot distinguish)
        $symbols = [TcAdsHelper]::GetAllSymbols($script:TcAdsClient, $Filter)

        # Enum types get their member table (name -> value) from the runtime's data type table,
        # loaded once per ADS session (Get-TcEnumTable); non-enum symbols have no enumValues key.
        $enumTable = Get-TcEnumTable
        $result = @()
        foreach ($sym in $symbols) {
            $entry = [ordered]@{
                path    = $sym['Name']
                type    = $sym['TypeName']
                size    = $sym['Size']
                comment = $sym['Comment']
            }
            if ($enumTable.Count -gt 0) {
                $enum = Find-TcEnumType -TypeName ([string]$sym['TypeName'])
                if ($null -ne $enum) { $entry.enumValues = [PSCustomObject]$enum.Values }
            }
            $result += [PSCustomObject]$entry
        }

        # NOTE: data stays an array (consumers iterate it directly), so the
        # 'reconnected' flag is not added here; $reconnected is still evaluated
        # so Ensure-TcAdsConnection can heal the session before enumeration.
        New-TcResult -Success $true -Data $result
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SYMBOL_ENUM_FAILED' -MessagePrefix 'Failed to enumerate symbols'
    }
}
