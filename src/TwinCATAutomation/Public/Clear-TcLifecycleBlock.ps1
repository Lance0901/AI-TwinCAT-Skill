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
        user agreed, with their reason in -Reason and the approved continuation in -FallbackMethod,
        -AllowedSideEffects and -MaxVerifyLevel (#113 structured receipt; all four are required,
        a missing, empty or invalid one returns LIFECYCLE_RECEIPT_INCOMPLETE with data.missing /
        data.invalid and nothing is removed). A successful command never clears the block by
        itself (the commands that could succeed are refused while it exists).

        Other processes (another MCP bridge, another PowerShell session) drop their in-memory copy
        of the record once the file no longer holds it and the history has the receipt of exactly
        that record (#113: same key, same createdAtUtc and command, clearedAtUtc not in the
        future); otherwise they keep blocking. This sync is a convenience, not a security
        boundary: the history is not tamper-proof.

        Returns data: cleared (the removed record, $null when the key had none), amsNetId, key
        (the record key: the AmsNetId in lower case, '<unknown>' for an empty or loopback
        127.x.x.x.y.z NetId, '<corrupt>'), reason, fallbackMethod, allowedSideEffects,
        maxVerifyLevel, clearedAt, clearedAtUtc, remaining (the records left, each
        @{ key; record }; an empty array when nothing is left, $null only when they could not be
        read), remainingKeys (their keys, empty array / $null the same way), stillBlocking (keys that still block every target: '<unknown>' /
        '<corrupt>'; after clearing '<unknown>' every remaining key, because a command on an
        unknown / loopback target is blocked by any record; message and data.next name the
        -AmsNetId to pass), receipt (appended to lifecycle-block-history.jsonl next to the state
        file under the state lock), receiptWritten ($false when the receipt could not be
        appended: the record is removed here, but other bridges / processes holding it in memory
        will NOT sync; data.historyWarning says why). The state file cannot be updated (lock /
        write failure) -> LIFECYCLE_BLOCKED, nothing removed.
    .PARAMETER AmsNetId
        Target whose block is removed. Default: the IDE target (Connect-TcIde), then the ADS
        session. '<unknown>' removes a record written while the target was not known (or for a
        loopback NetId such as 127.0.0.1.1.1); '<corrupt>' removes the record that replaced an
        unreadable state file. Not resolvable -> AMS_NETID_REQUIRED with data.blocks (every record).
    .PARAMETER Reason
        Required. Why the block may be lifted, in the user's words (who approved, what was checked). Missing or empty -> LIFECYCLE_RECEIPT_INCOMPLETE.
    .PARAMETER FallbackMethod
        Required (#113). How the work continues after the block is lifted, as the user approved it, e.g. 'rerun Enable-TcConfig -Force through tcauto' or 'user restarts TcSystemServiceUm by hand, then Enable-TcConfig -Force'. Missing or empty -> LIFECYCLE_RECEIPT_INCOMPLETE.
    .PARAMETER AllowedSideEffects
        Required (#113). The side effects the user allowed for that continuation, one entry each, e.g. 'TwinCAT restart', 'PLC download', 'PLC Run'; exactly 'none' (alone) when none are allowed. At least one non-empty entry, 'none' never together with another entry, else LIFECYCLE_RECEIPT_INCOMPLETE.
    .PARAMETER MaxVerifyLevel
        Required (#113). The highest layer the verification after this clear will reach; results must not claim more than it. One of None, SystemState (TwinCAT system state read back), PlcState (PLC port state read back), VariableRead (a PLC variable read back), TestObserved (a test result observed). Missing or another value -> LIFECYCLE_RECEIPT_INCOMPLETE.
    .EXAMPLE
        Clear-TcLifecycleBlock -Reason 'User checked the license in XAE, approved a new Enable-TcConfig -Force' -FallbackMethod 'rerun Enable-TcConfig -Force' -AllowedSideEffects 'TwinCAT restart','PLC download','PLC Run' -MaxVerifyLevel PlcState
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AmsNetId,

        # #113: the four receipt fields are not [Parameter(Mandatory)] on purpose: a missing value
        # must come back as the LIFECYCLE_RECEIPT_INCOMPLETE JSON error (a Mandatory parameter
        # would prompt or throw a binding error instead). MCP marks them required in tools.json
        # (Export-ToolSchema.ps1 $requiredOverrides).
        [Parameter()]
        [string]$Reason,

        [Parameter()]
        [string]$FallbackMethod,

        [Parameter()]
        [string[]]$AllowedSideEffects,

        [Parameter()]
        [string]$MaxVerifyLevel
    )

    # #113 structured receipt: every field is checked before anything is removed
    $sideEffects = [string[]]@($AllowedSideEffects | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    $level = $null
    if (-not [string]::IsNullOrWhiteSpace($MaxVerifyLevel)) { $level = @($script:TcLifecycleVerifyLevels | Where-Object { $_ -eq $MaxVerifyLevel.Trim() })[0] }
    $missing = @()
    $invalid = @()
    if ([string]::IsNullOrWhiteSpace($Reason)) { $missing += 'Reason' }
    if ([string]::IsNullOrWhiteSpace($FallbackMethod)) { $missing += 'FallbackMethod' }
    if ($sideEffects.Count -eq 0) { $missing += 'AllowedSideEffects' }
    elseif ($sideEffects.Count -gt 1 -and @($sideEffects | Where-Object { $_ -eq 'none' }).Count -gt 0) { $invalid += "AllowedSideEffects: 'none' cannot be combined with other entries ($($sideEffects -join ', '))" }
    if ([string]::IsNullOrWhiteSpace($MaxVerifyLevel)) { $missing += 'MaxVerifyLevel' }
    elseif ($null -eq $level) { $invalid += "MaxVerifyLevel: '$MaxVerifyLevel' is not one of $($script:TcLifecycleVerifyLevels -join ', ')" }
    if ($missing.Count -gt 0 -or $invalid.Count -gt 0) {
        $what = @()
        if ($missing.Count -gt 0) { $what += "missing or empty: $($missing -join ', ')" }
        if ($invalid.Count -gt 0) { $what += "invalid: $($invalid -join '; ')" }
        # #130 F1: none of the three #113 fields was passed at all (not passed empty): an MCP
        # server started before #113 still offers the old ClearLifecycleBlock schema and cannot
        # send them. Never fall back to a Reason-only clear; tell the caller to restart the server.
        $stale = -not ($PSBoundParameters.ContainsKey('FallbackMethod') -or $PSBoundParameters.ContainsKey('AllowedSideEffects') -or $PSBoundParameters.ContainsKey('MaxVerifyLevel'))
        $hint = Get-TcErrorHint -Code 'LIFECYCLE_RECEIPT_INCOMPLETE'
        if ($stale) { $hint = "$hint $script:TcLifecycleStaleSchemaText" }
        return New-TcResult -Success $false -ErrorCode 'LIFECYCLE_RECEIPT_INCOMPLETE' -Hint $hint `
            -ErrorMessage "Clear-TcLifecycleBlock NOT RUN: the receipt is incomplete ($($what -join '; ')). Nothing was removed.$(if ($stale) { ' None of -FallbackMethod / -AllowedSideEffects / -MaxVerifyLevel was passed: through MCP the server''s tool schema may be older than the module.' })" `
            -Data ([PSCustomObject]@{ missing = [string[]]$missing; invalid = [string[]]$invalid; allowedVerifyLevels = [string[]]$script:TcLifecycleVerifyLevels; possibleStaleSchema = $stale; notRun = $true })
    }
    $Reason = $Reason.Trim()
    $FallbackMethod = $FallbackMethod.Trim()
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

    # #113 review 2: the receipt is built and appended under the state lock, right after the
    # record left the file (Remove-TcLifecycleBlock)
    $netId = $AmsNetId
    $builder = {
        param($Removed)
        [PSCustomObject][ordered]@{
            clearedAt          = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
            clearedAtUtc       = [DateTime]::UtcNow.ToString('o')
            amsNetId           = $netId
            key                = $key
            netIdSource        = $source
            reason             = $Reason
            fallbackMethod     = $FallbackMethod
            allowedSideEffects = $sideEffects
            maxVerifyLevel     = $level
            pid                = $PID
            cleared            = $Removed
        }
    }.GetNewClosure()
    $rm = Remove-TcLifecycleBlock -AmsNetId $AmsNetId -Receipt $builder
    if (-not [string]::IsNullOrWhiteSpace([string]$rm.Warning)) {
        return New-TcResult -Success $false -ErrorCode 'LIFECYCLE_BLOCKED' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED') `
            -ErrorMessage "Clear-TcLifecycleBlock: $($rm.Warning)" `
            -Data ([PSCustomObject]@{ amsNetId = $AmsNetId; key = $key; cleared = $null; lifecycleBlock = (Get-TcLifecycleBlock -AmsNetId $AmsNetId) })
    }
    $receipt = $rm.Receipt
    if ($null -eq $receipt) { $receipt = & $builder $rm.Removed }
    $now = $receipt.clearedAt
    $nowUtc = $receipt.clearedAtUtc
    $receiptWritten = [bool]$rm.ReceiptWritten
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
    $next = [string[]]@($globalKeys | ForEach-Object { "Clear-TcLifecycleBlock -AmsNetId '$_' -Reason '<why>' -FallbackMethod '<how>' -AllowedSideEffects '<side effect>' -MaxVerifyLevel <level>" })
    $msg = if ($null -eq $rm.Removed) { "No lifecycle block was recorded for $AmsNetId (key '$key')." } else { "Lifecycle block of $AmsNetId (key '$key') removed ($($rm.Removed.command) $($rm.Removed.errorCode) at $($rm.Removed.time))." }
    if (-not $readable) { $msg += ' The remaining records could not be read: every target may still be blocked.' }
    elseif ($restKeys.Count -eq 0) { $msg += ' No lifecycle block is left.' }
    elseif ($globalKeys.Count -gt 0) { $msg += " Still blocking EVERY target: $(($globalKeys | ForEach-Object { "'$_'" }) -join ', ') - only after the user agreed: $($next -join '; ')." }
    elseif ($restKeys.Count -gt 0) { $msg += " Records left for other targets: $($restKeys -join ', ')." }
    if (-not $receiptWritten) { $msg += " WARNING: $($rm.HistoryWarning). Other MCP bridges / processes that still hold this block in memory will NOT sync and keep blocking: clear it there as well (only after the user agreed)." }
    New-TcResult -Success $true -Data ([PSCustomObject]@{
        cleared            = $rm.Removed
        amsNetId           = $AmsNetId
        key                = $key
        netIdSource        = $source
        reason             = $Reason
        fallbackMethod     = $FallbackMethod
        allowedSideEffects = $sideEffects
        maxVerifyLevel     = $level
        clearedAt          = $now
        clearedAtUtc       = $nowUtc
        remaining          = $restList
        remainingKeys      = $restKeys
        stillBlocking      = $globalKeys
        next               = $next
        receipt            = $receipt
        receiptWritten     = $receiptWritten
        historyWarning     = $rm.HistoryWarning
        message            = $msg
    })
}
