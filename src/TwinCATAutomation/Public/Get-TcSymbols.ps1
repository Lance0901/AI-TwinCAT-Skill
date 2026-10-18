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

        $result = @()
        foreach ($sym in $symbols) {
            $result += [PSCustomObject]@{
                path    = $sym['Name']
                type    = $sym['TypeName']
                size    = $sym['Size']
                comment = $sym['Comment']
            }
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
