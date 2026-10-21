function Set-TcSystemState {
    <#
    .SYNOPSIS
        Switches TwinCAT system state (Config/Run) via ADS — no dialog popups.
    .DESCRIPTION
        Uses ADS WriteControl on port 10000 to switch system state, then polls
        port 10000 (Wait-TcAdsState) until the requested state is reached instead
        of sleeping a fixed time.
        When -AmsNetId is omitted it is resolved from the IDE target (Connect-TcIde,
        GetTargetNetId), then from the ADS session (Connect-TcAds). There is NO local
        fallback: if both are empty AMS_NETID_REQUIRED is returned, because switching
        the wrong machine's state is destructive. data.netIdSource reports the source
        ('explicit' / 'ide-target' / 'ads-session').

        AdsState written to port 10000 (data.sentAdsState / sentAdsStateCode):
          Config -> Reconfig (16)  InfoSys TwinCAT.Ads AdsState: "System should restart in
                                    config mode" https://infosys.beckhoff.com/content/1033/tc3_ads.net/9408236299.html
          Run    -> Reset (2)       restart of the TwinCAT system; InfoSys does not document
                                    which AdsState restarts port 10000 into Run (measured).
        Measured 2026-10-21 on the local UmRT (TcSystemServiceUm.exe 3.1.0.2649): Run (5) is
        refused with ADS 0x701 "Service is not supported by server"; Reset (2) goes
        Config -> (unreachable) -> Stop -> Run in ~1.3 s; Reconfig (16) goes -> Stop -> Config.
        So "Run" sends Reset by design; data.requestedState is the requested target state and
        data.sentAdsState the AdsState actually written.

        Reaching the target once is not enough: a system that fails to start (e.g. a PLC
        whose symbol description does not match its application, ADS 1809 / 0x711) can show
        Run for a moment and fall back to Config/Stop (#32). After the target was seen the
        state is sampled for -SettleSec and read back once more (data.readbackState,
        data.stateTrace); any sample that differs returns SYSTEM_STATE_MISMATCH
        (success = false) instead of success.
    .PARAMETER State
        Target state: Run or Config.
    .PARAMETER AmsNetId
        Target AMS Net ID. Optional; resolved from the IDE target, then the ADS session.
        Never falls back to the local system 127.0.0.1.1.1.
    .PARAMETER TimeoutSec
        Maximum time to wait for the target state. Default 60.
    .PARAMETER SettleSec
        After the target state was reached, keep sampling port 10000 this long (every 250 ms)
        and fail with SYSTEM_STATE_MISMATCH when it leaves the target state. Default 3, 0 = only
        the final readback.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Run', 'Config')]
        [string]$State,

        [Parameter()]
        [string]$AmsNetId,

        [Parameter()]
        [int]$TimeoutSec = 60,

        [Parameter()]
        [ValidateRange(0, 60)]
        [int]$SettleSec = 3
    )

    # Auto-detect AmsNetId: IDE target, then ADS session (never local: destructive)
    $netIdSource = 'explicit'
    if ([string]::IsNullOrWhiteSpace($AmsNetId)) {
        $AmsNetId = $null
        $sm = $null
        try { $sm = Get-TcSysManager } catch { Write-Verbose "Set-TcSystemState: no IDE connection ($($_.Exception.Message))" }
        if ($null -ne $sm) {
            try { $AmsNetId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() } } catch { }
        }
        if (-not [string]::IsNullOrWhiteSpace($AmsNetId)) {
            $netIdSource = 'ide-target'
        }
        elseif (-not [string]::IsNullOrWhiteSpace($script:TcAdsAmsNetId)) {
            $AmsNetId = $script:TcAdsAmsNetId
            $netIdSource = 'ads-session'
        }
        else {
            return New-TcResult -Success $false `
                -ErrorMessage 'AmsNetId not specified and could not be auto-detected (no IDE target, no ADS session). Connect to IDE first or specify -AmsNetId.' `
                -ErrorCode 'AMS_NETID_REQUIRED' `
                -Hint (Get-TcErrorHint -Code 'AMS_NETID_REQUIRED')
        }
    }

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return New-TcResult -Success $false -ErrorMessage 'TwinCAT.Ads.dll not found.' -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
    }

    $sysClient = $null
    try {
        $sysClient = New-Object TwinCAT.Ads.TcAdsClient
        $sysClient.Connect($AmsNetId, 10000)

        # Remember the state before the request: when it already equals the target
        # (e.g. Run -> Run = restart) the system transiently leaves and re-enters it.
        $stateBefore = $null
        try { $stateBefore = $sysClient.ReadState().AdsState.ToString() } catch { }

        $newState = New-Object TwinCAT.Ads.StateInfo
        # Config: AdsState 16 = Reconfig ("restart in config mode"); Run: AdsState 2 = Reset
        # (restart; Run (5) itself is refused with ADS 0x701 on port 10000, see .DESCRIPTION)
        $sentCode = if ($State -eq 'Config') { 16 } else { 2 }
        $newState.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], $sentCode)
        $sentName = $newState.AdsState.ToString()
        $newState.DeviceState = 0
        $requestWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $sysClient.WriteControl($newState)

        # Original state = target (Run -> Run restart, Config -> Config): the target only
        # counts once the system was seen LEAVING it (other state or port unreachable),
        # otherwise the poll below would succeed on the stale pre-restart state. Polled every
        # 100 ms for at most 10 s (within -TimeoutSec). Measured 2026-10-21 (UmRT): Reset /
        # Reconfig make port 10000 unreachable after ~0.3 s, then Stop, then the target.
        # Original <> target: seeing the target is already a change, leftOriginal = $true.
        $leftOriginal = ($stateBefore -ne $State)
        if (-not $leftOriginal) {
            $leaveSec = [Math]::Min(10, $TimeoutSec)
            while ($requestWatch.Elapsed.TotalSeconds -lt $leaveSec) {
                try {
                    $s = $sysClient.ReadState().AdsState.ToString()
                    if ($s -ne $State) { $leftOriginal = $true; break }
                }
                catch { $leftOriginal = $true; break }  # port unreachable = restart in progress
                Start-Sleep -Milliseconds 100
            }
        }

        $sysClient.Dispose()
        $sysClient = $null

        $data = [PSCustomObject]@{
            requestedState   = $State
            sentAdsState     = $sentName
            sentAdsStateCode = $sentCode
            originalState    = $stateBefore
            stateBefore      = $stateBefore
            leftOriginal     = $leftOriginal
            reached          = $false
            finalState       = $null
            currentState     = $null
            readbackState    = $null
            latencyMs        = $null
            stateTrace       = @()
            amsNetId         = $AmsNetId
            netIdSource      = $netIdSource
            elapsedMs        = [int]$requestWatch.ElapsedMilliseconds
        }

        if (-not $leftOriginal) {
            $data.finalState = $State
            $data.currentState = $State
            return New-TcResult -Success $false `
                -ErrorMessage "TwinCAT was already in '$State' and never left it within $([Math]::Min(10, $TimeoutSec)) s after WriteControl $sentName ($sentCode): the restart was not observed, so the current '$State' is the old state, not a confirmed restart." `
                -ErrorCode 'SYSTEM_STATE_MISMATCH' `
                -Hint (Get-TcErrorHint -Code 'SYSTEM_STATE_MISMATCH') `
                -Data $data
        }

        # Poll port 10000 until the target state is reached (replaces fixed sleep)
        $remaining = [int][Math]::Max(1, [Math]::Ceiling($TimeoutSec - $requestWatch.Elapsed.TotalSeconds))
        $wait = Wait-TcAdsState -AmsNetId $AmsNetId -Port 10000 -TargetState $State -TimeoutSec $remaining
        $data.currentState = $wait.State
        $data.finalState = $wait.State
        $data.elapsedMs = [int]$requestWatch.ElapsedMilliseconds

        if (-not $wait.Reached) {
            $detail = if ($wait.LastError) { " Last error: $($wait.LastError)" } else { '' }
            $hint = Get-TcErrorHint -Code 'SYSTEM_STATE_TIMEOUT'
            $lic = if ($wait.State -eq 'Config') { Get-TcLicenseDiagnosis -AmsNetId $AmsNetId } else { $null }
            if ($null -ne $lic) {
                $data | Add-Member -NotePropertyName 'licenses' -NotePropertyValue $lic
                if (-not [string]::IsNullOrWhiteSpace($lic.text)) { $hint = "$($lic.text) $hint" }
            }
            return New-TcResult -Success $false `
                -ErrorMessage "TwinCAT did not reach state '$State' within $TimeoutSec s (last state: $($wait.State)).$detail" `
                -ErrorCode 'SYSTEM_STATE_TIMEOUT' `
                -Hint $hint `
                -Data $data
        }
        $data.reached = $true
        $data.latencyMs = [int]$requestWatch.ElapsedMilliseconds

        # Settle + final readback: the target state must hold (see .DESCRIPTION).
        $trace = New-Object System.Collections.ArrayList
        $settleWatch = [System.Diagnostics.Stopwatch]::StartNew()
        $deviated = $null
        $readback = $null
        $probe = $null
        $unreachableRun = 0
        # The settle window stays inside -TimeoutSec (an overall deadline of the caller).
        $settleLimit = [Math]::Min([double]$SettleSec, [Math]::Max(0.0, $TimeoutSec - $requestWatch.Elapsed.TotalSeconds))
        try {
            while ($true) {
                $s = $null
                try {
                    if ($null -eq $probe) { $probe = New-TcAdsClient -AmsNetId $AmsNetId -Port 10000 }
                    $s = $probe.ReadState().AdsState.ToString()
                }
                catch {
                    $s = 'Unreachable'
                    if ($null -ne $probe) { try { $probe.Dispose() } catch { }; $probe = $null }
                }
                if ($trace.Count -eq 0 -or $trace[$trace.Count - 1].state -ne $s) {
                    $null = $trace.Add([PSCustomObject]@{ ms = [int]$settleWatch.ElapsedMilliseconds; state = $s })
                }
                $readback = $s
                # One failed read (ADS router hiccup on the fresh probe) is not a state change;
                # two in a row (>= 250 ms unreachable) or any other real state is.
                if ($s -eq 'Unreachable') { $unreachableRun++ } else { $unreachableRun = 0 }
                if ($null -eq $deviated -and $s -ne $State -and ($s -ne 'Unreachable' -or $unreachableRun -ge 2)) { $deviated = $s }
                if ($settleWatch.Elapsed.TotalSeconds -ge $settleLimit -and $s -ne 'Unreachable') { break }
                if ($settleWatch.Elapsed.TotalSeconds -ge ($settleLimit + 1)) { break }
                Start-Sleep -Milliseconds 250
            }
        }
        finally {
            if ($null -ne $probe) { try { $probe.Dispose() } catch { } }
        }
        $data.readbackState = $readback
        $data.currentState = $readback
        $data.finalState = $readback
        $data.stateTrace = @($trace.ToArray())
        $data.elapsedMs = [int]$requestWatch.ElapsedMilliseconds
        $data | Add-Member -NotePropertyName 'held' -NotePropertyValue ($null -eq $deviated)

        if ($null -ne $deviated) {
            $traceText = ($data.stateTrace | ForEach-Object { "+$($_.ms)ms $($_.state)" }) -join ', '
            $hint = Get-TcErrorHint -Code 'SYSTEM_STATE_MISMATCH'
            $lic = if ($readback -eq 'Config' -or $deviated -eq 'Config') { Get-TcLicenseDiagnosis -AmsNetId $AmsNetId } else { $null }
            if ($null -ne $lic) {
                $data | Add-Member -NotePropertyName 'licenses' -NotePropertyValue $lic
                if (-not [string]::IsNullOrWhiteSpace($lic.text)) { $hint = "$($lic.text) $hint" }
            }
            return New-TcResult -Success $false `
                -ErrorMessage "TwinCAT reached '$State' but did not stay there: readback '$readback' after $SettleSec s (sent AdsState $sentName ($sentCode); trace $traceText)." `
                -ErrorCode 'SYSTEM_STATE_MISMATCH' `
                -Hint $hint `
                -Data $data
        }

        New-TcResult -Success $true -Data $data
    }
    catch {
        New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'SYSTEM_STATE_SET_FAILED' -MessagePrefix 'Failed to set system state'
    }
    finally {
        if ($null -ne $sysClient) {
            try { $sysClient.Dispose() } catch { }
        }
    }
}
