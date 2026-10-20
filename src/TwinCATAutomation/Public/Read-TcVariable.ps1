function Read-TcVariable {
    <#
    .SYNOPSIS
        Reads PLC variable(s) by symbol name via ADS.
    .DESCRIPTION
        Every entry has path, value and type. By PLC type:
          BOOL / integers / REAL / LREAL / STRING    value is the typed scalar
          TIME/TOD, LTIME/LTOD, DATE/DT, LDATE/LDT  value is the IEC literal ("T#6s", "DT#2026-10-20-12:30:00"); the raw
                                                    integer is in ms (TIME/TOD), ns (LTIME/LTOD/LDATE/LDT) or unix (DATE/DT)
          enum                                      value is the integer, name is the member name (null + hint when unknown)
          STRUCT / ARRAY / other                    value is the raw byte array (int[]), size is the byte count
    .PARAMETER Path
        Variable path(s). Single string or array (e.g., "MAIN.nCounter" or @("MAIN.nCounter","MAIN.bRunning")).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    try { $reconnected = Ensure-TcAdsConnection } catch {
        return New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'NOT_CONNECTED'
    }

    try {
        # Ensure TcAdsHelper is compiled (needs TwinCAT.Ads.dll loaded first)
        if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
            $null = Find-TcAdsAssembly
        }

        $results = @()
        $lastErrorRecord = $null

        foreach ($varPath in $Path) {
            try {
                $entry = Read-TcAdsSymbolValue -VarPath $varPath
                $entry.reconnected = $reconnected
                $results += [PSCustomObject]$entry
            }
            catch {
                $lastErrorRecord = $_
                $entry = [PSCustomObject]@{
                    path  = $varPath
                    error = $_.Exception.Message
                }
                $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
                if ($null -ne $mapped) {
                    $entry | Add-Member -NotePropertyName 'code' -NotePropertyValue $mapped.Code
                    $entry | Add-Member -NotePropertyName 'hint' -NotePropertyValue $mapped.Hint
                }
                $results += $entry
            }
        }

        if ($Path.Count -eq 1) {
            if ($results[0].PSObject.Properties['error']) {
                # Keep the historical code SYMBOL_NOT_FOUND; only the hint comes from ADS_SYMBOL_NOT_FOUND
                New-TcAdsErrorResult -ErrorRecord $lastErrorRecord -DefaultCode 'SYMBOL_NOT_FOUND' -CodeAliases @{ ADS_SYMBOL_NOT_FOUND = 'SYMBOL_NOT_FOUND' }
            }
            else {
                New-TcResult -Success $true -Data $results[0]
            }
        }
        else {
            New-TcResult -Success $true -Data $results
        }
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'ADS_READ_FAILED' -MessagePrefix 'Failed to read variable'
    }
}
