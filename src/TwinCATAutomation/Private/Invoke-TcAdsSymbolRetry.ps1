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
        rethrown as is. Repeating a write assumes that a write refused with 0x711 had no effect
        (inference, not verified by a readback; InfoSys does not say). A failed reopen throws a
        "Not connected to TwinCAT ADS" message (maps to NOT_CONNECTED) that names the 0x711, and
        $Reloaded is set before the reopen so the caller knows the old session is gone.
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
        $Reloaded.Value = $true
        try {
            $null = Connect-TcAdsSession -AmsNetId $script:TcAdsAmsNetId -Port $script:TcAdsPort
        }
        catch {
            throw "Not connected to TwinCAT ADS. Call Connect-TcAds first. (reopen of $($script:TcAdsAmsNetId):$($script:TcAdsPort) after ADS 0x711 failed: $($_.Exception.Message))"
        }
        return (& $Action)
    }
}
