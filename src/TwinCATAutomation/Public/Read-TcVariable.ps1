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
        One path: data is the entry; an unreadable symbol fails with SYMBOL_NOT_FOUND.
        Several paths (#60, fail closed): data is an array with one entry per path, an unreadable
        path is {path, error, code, hint}. The result also has the top-level fields partial ($true
        when at least one path failed) and failedPaths (the paths that failed, in input order).
        Any failed path makes the result success = false with PARTIAL_READ_FAILED; data still holds
        every entry, including the values that were read.
        #26: an entry also has symbolsReloaded. A read refused with ADS 0x711 (symbol version invalid,
        e.g. a handle of this ADS connection that is older than a new download) reopens the ADS
        session once and reads again; symbolsReloaded is $true from that entry on.
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
        $symbolsReloaded = $false
        $lastErrorRecord = $null

        foreach ($varPath in $Path) {
            try {
                # #26: ADS 0x711 after a new download -> reopen the session once and read again
                $reloaded = $false
                $entry = Invoke-TcAdsSymbolRetry -Reloaded ([ref]$reloaded) -Action { Read-TcAdsSymbolValue -VarPath $varPath }
                if ($reloaded) { $symbolsReloaded = $true }
                $entry.reconnected = $reconnected
                $entry.symbolsReloaded = $symbolsReloaded
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
            # #60: several paths, fail closed. data stays the array of every entry (#57); the
            # top-level partial / failedPaths say whether any path failed (data is an array, so they
            # cannot go inside it). Any failed path -> success = false, PARTIAL_READ_FAILED.
            $failed = @($results | Where-Object { $null -ne $_.PSObject.Properties['error'] } | ForEach-Object { [string]$_.path })
            if ($failed.Count -gt 0) {
                $detail = (@($results | Where-Object { $null -ne $_.PSObject.Properties['error'] } | ForEach-Object {
                    $c = if ($null -ne $_.PSObject.Properties['code']) { [string]$_.code } else { 'unmapped' }
                    "$($_.path) ($c)"
                })) -join ', '
                $res = New-TcResult -Success $false `
                    -ErrorMessage "$($failed.Count) of $($Path.Count) paths could not be read: $detail. The values that were read are in data; every failed entry has error / code / hint." `
                    -ErrorCode 'PARTIAL_READ_FAILED' `
                    -Hint (Get-TcErrorHint -Code 'PARTIAL_READ_FAILED') `
                    -Data $results
            }
            else {
                # (,$results): keep data an array (New-TcResult unrolls -Data, #57)
                $res = New-TcResult -Success $true -Data (,$results)
            }
            $res | Add-Member -NotePropertyName 'partial' -NotePropertyValue ($failed.Count -gt 0) -Force
            $res | Add-Member -NotePropertyName 'failedPaths' -NotePropertyValue ([string[]]$failed) -Force
            $res
        }
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'ADS_READ_FAILED' -MessagePrefix 'Failed to read variable'
    }
}
