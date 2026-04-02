function Read-TcVariable {
    <#
    .SYNOPSIS
        Reads PLC variable(s) by symbol name via ADS.
    .PARAMETER Path
        Variable path(s). Single string or array (e.g., "MAIN.nCounter" or @("MAIN.nCounter","MAIN.bRunning")).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string[]]$Path
    )

    try { Assert-TcAdsConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    try {
        # Ensure TcAdsHelper is compiled (needs TwinCAT.Ads.dll loaded first)
        if ($null -eq ([System.Management.Automation.PSTypeName]'TcAdsHelper').Type) {
            $null = Find-TcAdsAssembly
        }

        $results = @()

        foreach ($varPath in $Path) {
            try {
                # Get symbol info via C# helper (bypasses CLS issue)
                $symInfo = [TcAdsHelper]::GetSymbolInfo($script:TcAdsClient, $varPath)
                $typeName = $symInfo['TypeName']
                $typeSize = $symInfo['Size']

                $handle = $script:TcAdsClient.CreateVariableHandle($varPath)

                # Read based on PLC type
                $value = $null
                switch -Regex ($typeName.ToUpper()) {
                    '^BOOL$'           { $value = $script:TcAdsClient.ReadAny($handle, [bool]) }
                    '^SINT$'           { $value = $script:TcAdsClient.ReadAny($handle, [sbyte]) }
                    '^USINT$|^BYTE$'   { $value = $script:TcAdsClient.ReadAny($handle, [byte]) }
                    '^INT$'            { $value = $script:TcAdsClient.ReadAny($handle, [int16]) }
                    '^UINT$|^WORD$'    { $value = $script:TcAdsClient.ReadAny($handle, [uint16]) }
                    '^DINT$'           { $value = $script:TcAdsClient.ReadAny($handle, [int32]) }
                    '^UDINT$|^DWORD$'  { $value = $script:TcAdsClient.ReadAny($handle, [uint32]) }
                    '^LINT$'           { $value = $script:TcAdsClient.ReadAny($handle, [int64]) }
                    '^ULINT$|^LWORD$'  { $value = $script:TcAdsClient.ReadAny($handle, [uint64]) }
                    '^REAL$'           { $value = $script:TcAdsClient.ReadAny($handle, [float]) }
                    '^LREAL$'          { $value = $script:TcAdsClient.ReadAny($handle, [double]) }
                    '^STRING' {
                        $strLen = if ($typeSize -gt 0) { $typeSize } else { 255 }
                        $value = $script:TcAdsClient.ReadAny($handle, [string], @([int]$strLen))
                    }
                    default {
                        # Read as byte array for structs/unknown types
                        $buffer = New-Object byte[] $typeSize
                        $script:TcAdsClient.Read($handle, $buffer)
                        $value = $buffer
                    }
                }

                $script:TcAdsClient.DeleteVariableHandle($handle)

                $results += [PSCustomObject]@{
                    path  = $varPath
                    value = $value
                    type  = $typeName
                }
            }
            catch {
                $results += [PSCustomObject]@{
                    path  = $varPath
                    error = $_.Exception.Message
                }
            }
        }

        if ($Path.Count -eq 1) {
            if ($results[0].PSObject.Properties['error']) {
                New-TcResult -Success $false -ErrorMessage $results[0].error -ErrorCode 'SYMBOL_NOT_FOUND'
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
        New-TcResult -Success $false -ErrorMessage "Failed to read variable: $_" -ErrorCode 'ADS_READ_FAILED'
    }
}
