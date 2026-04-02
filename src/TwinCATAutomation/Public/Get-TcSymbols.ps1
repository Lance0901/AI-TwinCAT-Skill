function Get-TcSymbols {
    <#
    .SYNOPSIS
        Enumerates PLC symbols from the ADS symbol table.
    .PARAMETER Filter
        Optional wildcard filter (e.g., "MAIN.*").
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$Filter
    )

    try { Assert-TcAdsConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    try {
        # Ensure TcAdsHelper is compiled (needs TwinCAT.Ads.dll loaded first)
        if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
            $null = Find-TcAdsAssembly
        }

        # Use C# helper to bypass PowerShell CLS compatibility issues
        # (TcAdsSymbol has both 'Datatype' and 'DataType' which PowerShell cannot distinguish)
        $symbols = [TcAdsHelper]::GetAllSymbols($script:TcAdsClient, $Filter)

        $result = @()
        foreach ($sym in $symbols) {
            $result += [PSCustomObject]@{
                path    = $sym['Name']
                type    = $sym['TypeName']
                size    = $sym['Size']
                comment = $sym['Comment']
            }
        }

        New-TcResult -Success $true -Data $result
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to enumerate symbols: $_" -ErrorCode 'SYMBOL_ENUM_FAILED'
    }
}
