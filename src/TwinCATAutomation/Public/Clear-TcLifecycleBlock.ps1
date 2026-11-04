function Clear-TcLifecycleBlock {
    <#
    .SYNOPSIS
        Removes the LIFECYCLE_BLOCKED record of one target. Call it ONLY after the user has seen the block and agreed.
    .DESCRIPTION
        #68 fail-closed guard. When a runtime-changing command (Set-TcSystemState, Enable-TcConfig,
        Set-TcPlcState) sent its request and then failed (the readback did not reach the requested
        state, or the command broke off), the module records a lifecycle block for that target
        AmsNetId (Private/LifecycleBlock.ps1). While it exists, Set-TcSystemState, Enable-TcConfig,
        Enter-TcPlcOnline, Send-TcPlcProgram, Set-TcPlcState, Write-TcVariable, Invoke-TcTest,
        Invoke-TcTestCycle and Set-TcComModuleParameter -Online return LIFECYCLE_BLOCKED and do nothing.

        Do NOT call this on your own to get past LIFECYCLE_BLOCKED. The required flow is:
        stop, report the block (data.lifecycleBlock: command, errorCode, requestedState,
        reachedState, message, time) to the user, and call Clear-TcLifecycleBlock only after the
        user agreed, with their reason in -Reason. A successful command never clears the block by
        itself (the commands that could succeed are refused while it exists).

        Returns data: cleared (the removed record, $null when the key had none), amsNetId, key
        (the record key: the AmsNetId in lower case, '<unknown>' for an empty or loopback
        127.x.x.x.y.z NetId, '<corrupt>'), reason, clearedAt, remaining (the records left, each
        @{ key; record }; an empty array when nothing is left, $null only when they could not be
        read), remainingKeys (their keys, empty array / $null the same way), stillBlocking (keys that still block every target: '<unknown>' /
        '<corrupt>'; after clearing '<unknown>' every remaining key, because a command on an
        unknown / loopback target is blocked by any record; message and data.next name the
        -AmsNetId to pass), receipt (appended to
        lifecycle-block-history.jsonl next to the state file). The state file cannot be updated
        (lock / write failure) -> LIFECYCLE_BLOCKED, nothing removed.
    .PARAMETER AmsNetId
        Target whose block is removed. Default: the IDE target (Connect-TcIde), then the ADS
        session. '<unknown>' removes a record written while the target was not known (or for a
        loopback NetId such as 127.0.0.1.1.1); '<corrupt>' removes the record that replaced an
        unreadable state file. Not resolvable -> AMS_NETID_REQUIRED with data.blocks (every record).
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
            -ErrorMessage 'AmsNetId not given and no IDE target / ADS session to take it from; pass -AmsNetId (data.blocks lists every record with its key).' `
            -Data ([PSCustomObject]@{ blocks = (Get-TcLifecycleBlockList).List })
    }
    $key = ConvertTo-TcLifecycleKey $AmsNetId

    $rm = Remove-TcLifecycleBlock -AmsNetId $AmsNetId
    if (-not [string]::IsNullOrWhiteSpace([string]$rm.Warning)) {
        return New-TcResult -Success $false -ErrorCode 'LIFECYCLE_BLOCKED' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED') `
            -ErrorMessage "Clear-TcLifecycleBlock: $($rm.Warning)" `
            -Data ([PSCustomObject]@{ amsNetId = $AmsNetId; key = $key; cleared = $null; lifecycleBlock = (Get-TcLifecycleBlock -AmsNetId $AmsNetId) })
    }
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $receipt = [PSCustomObject]@{ clearedAt = $now; amsNetId = $AmsNetId; key = $key; netIdSource = $source; reason = $Reason; cleared = $rm.Removed }
    try {
        $hist = Join-Path (Split-Path -Parent (Get-TcLifecycleBlockFile)) 'lifecycle-block-history.jsonl'
        [IO.File]::AppendAllText($hist, (($receipt | ConvertTo-Json -Depth 5 -Compress) + "`r`n"), (New-Object System.Text.UTF8Encoding($false)))
    }
    catch { Write-Verbose "Clear-TcLifecycleBlock: history not written ($($_.Exception.Message))" }
    # V4: an empty list must stay an empty array (an if-expression or a function return would
    # unroll @() into $null, which reads as "could not be read"): plain assignments only
    $rest = Get-TcLifecycleBlockList
    $readable = [bool]$rest.Readable
    $restKeys = $null
    $restList = $null
    if ($readable) {
        $restList = [object[]]$rest.List
        $restKeys = [string[]]@($rest.List | ForEach-Object { [string]$_.key })
    }
    # N1: records that still block every target, and the call that would remove them
    # a command on '<unknown>' (unknown / loopback target) is blocked by ANY record: all of them count
    $globalKeys = [string[]]@()
    if ($readable -and $key -eq '<unknown>') { $globalKeys = [string[]]@($restKeys) }
    elseif ($readable) { $globalKeys = [string[]]@($restKeys | Where-Object { $_ -eq '<unknown>' -or $_ -eq '<corrupt>' }) }
    $next = [string[]]@($globalKeys | ForEach-Object { "Clear-TcLifecycleBlock -AmsNetId '$_' -Reason '<why>'" })
    $msg = if ($null -eq $rm.Removed) { "No lifecycle block was recorded for $AmsNetId (key '$key')." } else { "Lifecycle block of $AmsNetId (key '$key') removed ($($rm.Removed.command) $($rm.Removed.errorCode) at $($rm.Removed.time))." }
    if (-not $readable) { $msg += ' The remaining records could not be read: every target may still be blocked.' }
    elseif ($restKeys.Count -eq 0) { $msg += ' No lifecycle block is left.' }
    elseif ($globalKeys.Count -gt 0) { $msg += " Still blocking EVERY target: $(($globalKeys | ForEach-Object { "'$_'" }) -join ', ') - only after the user agreed: $($next -join '; ')." }
    elseif ($restKeys.Count -gt 0) { $msg += " Records left for other targets: $($restKeys -join ', ')." }
    New-TcResult -Success $true -Data ([PSCustomObject]@{
        cleared       = $rm.Removed
        amsNetId      = $AmsNetId
        key           = $key
        netIdSource   = $source
        reason        = $Reason
        clearedAt     = $now
        remaining     = $restList
        remainingKeys = $restKeys
        stillBlocking = $globalKeys
        next          = $next
        receipt       = $receipt
        message       = $msg
    })
}
