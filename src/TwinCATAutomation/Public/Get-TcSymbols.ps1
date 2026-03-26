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
        $symbolLoader = $script:TcAdsClient.CreateSymbolInfoLoader()
        $symbols = $symbolLoader.GetSymbols($false)  # $false = don't get sub-symbols

        $result = @()
        foreach ($sym in $symbols) {
            $symPath = $sym.Name

            if (-not [string]::IsNullOrWhiteSpace($Filter)) {
                if ($symPath -notlike $Filter) { continue }
            }

            $result += [PSCustomObject]@{
                path    = $symPath
                type    = $sym.Type
                size    = $sym.Size
                comment = try { $sym.Comment } catch { '' }
            }
        }

        New-TcResult -Success $true -Data $result
    }
    catch {
        New-TcResult -Success $false -ErrorMessage "Failed to enumerate symbols: $_" -ErrorCode 'SYMBOL_ENUM_FAILED'
    }
}
