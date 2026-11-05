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
        a missing or empty one returns LIFECYCLE_RECEIPT_INCOMPLETE and nothing is removed). A
        successful command never clears the block by itself (the commands that could succeed are
        refused while it exists).

        Other processes (another MCP bridge, another PowerShell session) drop their in-memory copy
        of the record once the file no longer holds it and the history has this receipt (#113);
        without the receipt (record removed by hand, history unreadable or corrupt) they keep
        blocking.

        Returns data: cleared (the removed record, $null when the key had none), amsNetId, key
        (the record key: the AmsNetId in lower case, '<unknown>' for an empty or loopback
        127.x.x.x.y.z NetId, '<corrupt>'), reason, fallbackMethod, allowedSideEffects,
        maxVerifyLevel, clearedAt, clearedAtUtc, remaining (the records left, each
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
    .PARAMETER FallbackMethod
        Required (#113). How the work continues after the block is lifted, as the user approved it, e.g. 'rerun Enable-TcConfig -Force through tcauto' or 'user restarts TcSystemServiceUm by hand, then Enable-TcConfig -Force'. Missing or empty -> LIFECYCLE_RECEIPT_INCOMPLETE.
    .PARAMETER AllowedSideEffects
        Required (#113). The side effects the user allowed for that continuation, one entry each, e.g. 'TwinCAT restart', 'PLC download', 'PLC Run'; 'none' when none are allowed. At least one non-empty entry, else LIFECYCLE_RECEIPT_INCOMPLETE.
    .PARAMETER MaxVerifyLevel
        Required (#113). The highest layer that will be verified after the continuation: None, SystemState (TwinCAT system state read back), PlcState (PLC port state), VariableRead (a PLC variable read back), TestObserved (a test result observed). Missing or another value -> LIFECYCLE_RECEIPT_INCOMPLETE.
    .EXAMPLE
        Clear-TcLifecycleBlock -Reason 'User checked the license in XAE, approved a new Enable-TcConfig -Force' -FallbackMethod 'rerun Enable-TcConfig -Force' -AllowedSideEffects 'TwinCAT restart','PLC download','PLC Run' -MaxVerifyLevel PlcState
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$AmsNetId,

        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Reason,

        # #113: not [Parameter(Mandatory)] on purpose: a missing value must come back as the
        # LIFECYCLE_RECEIPT_INCOMPLETE JSON error (a Mandatory parameter would prompt or throw a
        # binding error instead). MCP marks them required in tools.json (Export-ToolSchema.ps1).
        [Parameter()]
        [string]$FallbackMethod,

        [Parameter()]
        [string[]]$AllowedSideEffects,

        [Parameter()]
        [string]$MaxVerifyLevel
    )

    if ([string]::IsNullOrWhiteSpace($Reason)) {
        return New-TcResult -Success $false -ErrorCode 'INVALID_PARAMS' -ErrorMessage '-Reason must say why the user approved lifting the block.'
    }
    # #113 structured receipt: every field is checked before anything is removed
    $sideEffects = [string[]]@($AllowedSideEffects | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | ForEach-Object { ([string]$_).Trim() })
    $level = $null
    if (-not [string]::IsNullOrWhiteSpace($MaxVerifyLevel)) { $level = @($script:TcLifecycleVerifyLevels | Where-Object { $_ -eq $MaxVerifyLevel.Trim() })[0] }
    $missing = @()
    if ([string]::IsNullOrWhiteSpace($FallbackMethod)) { $missing += 'FallbackMethod' }
    if ($sideEffects.Count -eq 0) { $missing += 'AllowedSideEffects' }
    if ($null -eq $level) { $missing += 'MaxVerifyLevel' }
    if ($missing.Count -gt 0) {
        $badLevel = if (-not [string]::IsNullOrWhiteSpace($MaxVerifyLevel) -and $null -eq $level) { " -MaxVerifyLevel '$MaxVerifyLevel' is not one of $($script:TcLifecycleVerifyLevels -join ', ')." } else { '' }
        return New-TcResult -Success $false -ErrorCode 'LIFECYCLE_RECEIPT_INCOMPLETE' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_RECEIPT_INCOMPLETE') `
            -ErrorMessage "Clear-TcLifecycleBlock NOT RUN: the receipt is incomplete, missing or empty: $(@($missing) -join ', ').$badLevel Nothing was removed." `
            -Data ([PSCustomObject]@{ missing = [string[]]@($missing); allowedVerifyLevels = [string[]]$script:TcLifecycleVerifyLevels; notRun = $true })
    }
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

    $rm = Remove-TcLifecycleBlock -AmsNetId $AmsNetId
    if (-not [string]::IsNullOrWhiteSpace([string]$rm.Warning)) {
        return New-TcResult -Success $false -ErrorCode 'LIFECYCLE_BLOCKED' -Hint (Get-TcErrorHint -Code 'LIFECYCLE_BLOCKED') `
            -ErrorMessage "Clear-TcLifecycleBlock: $($rm.Warning)" `
            -Data ([PSCustomObject]@{ amsNetId = $AmsNetId; key = $key; cleared = $null; lifecycleBlock = (Get-TcLifecycleBlock -AmsNetId $AmsNetId) })
    }
    $now = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $nowUtc = [DateTime]::UtcNow.ToString('o')
    $receipt = [PSCustomObject][ordered]@{
        clearedAt          = $now
        clearedAtUtc       = $nowUtc
        amsNetId           = $AmsNetId
        key                = $key
        netIdSource        = $source
        reason             = $Reason
        fallbackMethod     = $FallbackMethod
        allowedSideEffects = $sideEffects
        maxVerifyLevel     = $level
        pid                = $PID
        cleared            = $rm.Removed
    }
    try {
        $hist = Get-TcLifecycleHistoryFile
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
    $next = [string[]]@($globalKeys | ForEach-Object { "Clear-TcLifecycleBlock -AmsNetId '$_' -Reason '<why>' -FallbackMethod '<how>' -AllowedSideEffects '<side effect>' -MaxVerifyLevel <level>" })
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
        fallbackMethod     = $FallbackMethod
        allowedSideEffects = $sideEffects
        maxVerifyLevel     = $level
        clearedAt     = $now
        clearedAtUtc  = $nowUtc
        remaining     = $restList
        remainingKeys = $restKeys
        stillBlocking = $globalKeys
        next          = $next
        receipt       = $receipt
        message       = $msg
    })
}
