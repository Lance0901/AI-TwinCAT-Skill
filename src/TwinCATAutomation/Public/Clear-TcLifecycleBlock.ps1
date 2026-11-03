function Clear-TcLifecycleBlock {
    <#
    .SYNOPSIS
        Removes the LIFECYCLE_BLOCKED record of one target. Call it ONLY after the user has seen the block and agreed.
    .DESCRIPTION
        #68 fail-closed guard. When a runtime-changing command (Set-TcSystemState, Enable-TcConfig,
        Set-TcPlcState) sent its request and the readback did not reach the requested state, the
        module records a lifecycle block for that target AmsNetId (Private/LifecycleBlock.ps1).
        While it exists, Set-TcSystemState, Enable-TcConfig, Enter-TcPlcOnline, Send-TcPlcProgram,
        Set-TcPlcState, Write-TcVariable, Invoke-TcTest, Invoke-TcTestCycle and
        Set-TcComModuleParameter -Online return LIFECYCLE_BLOCKED and do nothing.

        Do NOT call this on your own to get past LIFECYCLE_BLOCKED. The required flow is:
        stop, report the block (data.lifecycleBlock: command, errorCode, requestedState,
        reachedState, message, time) to the user, and call Clear-TcLifecycleBlock only after the
        user agreed, with their reason in -Reason. A successful command never clears the block by
        itself (the commands that could succeed are refused while it exists).

        Returns data: cleared (the removed record, $null when the target had none), amsNetId,
        reason, clearedAt, remaining (records left for other targets), corruptBackup (an
        unparseable state file was moved there; its records are gone), receipt (what was
        appended to lifecycle-block-history.jsonl next to the state file). The state file cannot
        be updated (lock / write failure) -> LIFECYCLE_BLOCKED, nothing removed.
    .PARAMETER AmsNetId
        Target whose block is removed. Default: the IDE target (Connect-TcIde), then the ADS
        session. '<unknown>' removes a record written while the target was not known.
        Not resolvable -> AMS_NETID_REQUIRED with data.blocks (every record).
    .PARAMETER Reason
        Why the block may be lifted, in the user's words (who approved, what was checked). Required.
    .EXAMPLE
        Clear-TcLifecycleBlock -Reason 'User checked the license in XAE, approved a new Enable-TcConfig -Force'
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AmsNetId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -ErrorMessage '-Reason must say why the user approved lifting the block.'
    }
    $source = 'explicit'
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
        $AmsNetId = Resolve-TcLifecycleNetId
        $source = 'resolved'
    }
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
        return New-TcResult -Success $false -ErrorCode 'AMS_NETID_REQUIRED' -Hint (Get-TcErrorHint -Code 'AMS_NETID_REQUIRED') `
            -ErrorMessage 'AmsNetId not given and no IDE target / ADS session to take it from; pass -AmsNetId (data.blocks lists every record).' `
            -Data ([PSCustomObject]@{ blocks = (Get-TcLifecycleBlockList) })
    }

    $rm = Remove-TcLifecycleBlock -AmsNetId $AmsNetId
    if (-not [string]::IsNullOrWhiteSpace([string]$rm.Warning)) {
        return New-TcResult -Success $false -ErrorCode 'LIFECYCLE_BLOCKED' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED') `
            -ErrorMessage "Clear-TcLifecycleBlock: $($rm.Warning)" `
            -Data ([PSCustomObject]@{ amsNetId = $AmsNetId; cleared = $null; lifecycleBlock = (Get-TcLifecycleBlock -AmsNetId $AmsNetId) })
    }
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $receipt = [PSCustomObject]@{ clearedAt = $now; amsNetId = $AmsNetId; netIdSource = $source; reason = $Reason; cleared = $rm.Removed; corruptBackup = $rm.CorruptBackup }
    try {
        $hist = Join-Path (Split-Path -Parent (Get-TcLifecycleBlockFile)) 'lifecycle-block-history.jsonl'
        [IO.File]::AppendAllText($hist, (($receipt | ConvertTo-Json -Depth 5 -Compress) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Verbose "Clear-TcLifecycleBlock: history not written ($($_.Exception.Message))" }
    $rest = Get-TcLifecycleBlockList
    New-TcResult -Success $true -Data ([PSCustomObject]@{
        cleared       = $rm.Removed
        amsNetId      = $AmsNetId
        netIdSource   = $source
        reason        = $Reason
        clearedAt     = $now
        remaining     = $(if ($null -eq $rest) { $null } else { @($rest).Count })
        corruptBackup = $rm.CorruptBackup
        receipt       = $receipt
        message       = $(if ($null -eq $rm.Removed) { "No lifecycle block was recorded for $AmsNetId." } else { "Lifecycle block of $AmsNetId removed ($($rm.Removed.command) $($rm.Removed.errorCode) at $($rm.Removed.time))." })
    })
}
