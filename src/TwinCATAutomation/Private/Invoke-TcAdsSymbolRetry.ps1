# One retry after ADS 0x711 (symbol version invalid) for Read-TcVariable / Write-TcVariable (#26).
# Keep this file ASCII only.

function Invoke-TcAdsSymbolRetry {
    <#
    .SYNOPSIS
        Runs one ADS symbol access; on ADS 0x711 reopens the module ADS session once and runs it again.
    .DESCRIPTION
        Measured 2026-11-08 (4026 VS2022, local UmRT, #26): after a new download (AppTimestamp and
        symbol version 0xF008 changed) a variable handle created before the download answers ADS 0x711
        "Symbol version is invalid", and in the same ADS connection CreateVariableHandle for that same
        symbol name returns the SAME handle number (855638551 both times), so the new handle answers
        0x711 too (reads and writes), until the old handle is released or the connection is reopened.
        Other symbols of the same connection read correctly. No read returned a wrong value: the failure is
        always the 0x711 error, never a misplaced offset.
        A fresh TcAdsClient (Connect-TcAdsSession with the cached AmsNetId / Port) has no old handles,
        so the access is repeated once on it. A second 0x711 is thrown to the caller unchanged.
        Only 0x711 (mapped to ADS_SYMBOL_VERSION_INVALID) triggers the retry; any other error is
        rethrown as is. The access must not have had an effect when it failed with 0x711 (a handle
        read / write that the runtime refused), so repeating it is safe.
    .PARAMETER Action
        Script block doing the ADS access with $script:TcAdsClient; its output is returned.
    .PARAMETER Reloaded
        [ref] bool set to $true when the session was reopened.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [Parameter(Mandatory)][ref]$Reloaded
    )

    try {
        return (& $Action)
    }
    catch {
        $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
        $canReconnect = (-not [string]::IsNullOrWhiteSpace([string]$script:TcAdsAmsNetId)) -and ($script:TcAdsPort -gt 0)
        if ($null -eq $mapped -or $mapped.Code -ne 'ADS_SYMBOL_VERSION_INVALID' -or -not $canReconnect) { throw }
        Write-Verbose "Invoke-TcAdsSymbolRetry: ADS 0x711, reopening $($script:TcAdsAmsNetId):$($script:TcAdsPort) and retrying once."
        $null = Connect-TcAdsSession -AmsNetId $script:TcAdsAmsNetId -Port $script:TcAdsPort
        $Reloaded.Value = $true
        return (& $Action)
    }
}
