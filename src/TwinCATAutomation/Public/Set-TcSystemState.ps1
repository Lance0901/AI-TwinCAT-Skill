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

        Stuck in Config (#194, -State Run only): SYSTEM_STATE_TIMEOUT whose last read was Config and
        SYSTEM_STATE_MISMATCH whose readback / deviation is Config carry data.licenses (license
        server, ADS port 30, Get-TcLicenseDiagnosis) and data.diagnostics { dialog; dialogScanComplete;
        errorList; errorListError; bootPackage; modalScan } (Get-TcRuntimeFailureDiagnostics, the
        same collection as Enable-TcConfig after Activate). Without an IDE connection the dialog
        and the Error List are not read: dialogScanComplete $false, modalScan.reason 'no-ide',
        errorListError 'unavailable: no IDE connection'. The code stays as it is. error.hint
        follows the diagnostics (Get-TcStuckInConfigHint): ADS 1809 / 0x711 / "symbol version" in
        the dialog or an Error List row -> ADS_SYMBOL_VERSION_INVALID explanation (Build +
        Enable-TcConfig -Force); another dialog / row -> its text; a license problem only when the
        license server reported an expired / invalid license. Inside Enable-TcConfig -Force
        (set-run) nothing is collected here: Enable-TcConfig adds its own data.diagnostics.
        Order (PR #200 review): the lifecycle block is written first, then licenses / diagnostics /
        hint are added. The modal dialog is scanned before any DTE read; with a dialog up or an
        incomplete scan DTE is not read (platform from the last Connect-TcIde / Set-TcTarget read,
        bootPackage.warnings says so; errorListError says why the Error List was not read). The
        collection ends by request start + -TimeoutSec + 10 s ($script:TcSystemStateDiagCapSec).

        When the target is the local Usermode Runtime and its TcSystemServiceUm process
        disappears during the wait (process gone and ADS 0x7 for >= 10 s), RUNTIME_CRASHED is
        returned right away instead of SYSTEM_STATE_TIMEOUT after -TimeoutSec (data.lastError,
        data.lastState, data.servicePidAtStart, data.runtimeName, data.unreachableMs). When
        -TimeoutSec ends while the last read of port 10000 fails and no TcSystemServiceUm process of
        that runtime runs any more (process list readable), it is RUNTIME_CRASHED as well,
        whatever the last error and the 0x7 streak (#114; data.crashDetectedBy = 'streak' |
        'deadline'; why the 10 s streak did not fire in the measured case is not confirmed).

        Reported states (#114): data.finalState / currentState is 'Unreachable' when the last
        read failed (ADS error), never the last state read before it (that one is data.lastState);
        the lifecycle block's reachedState is then empty. data.leftOriginal is $true only when a
        read returned a state other than data.originalState ($null when the original could not be
        read); failed reads after the write (leave check, wait or settle) are data.unreachableSeen.
        A failure after the wait also carries the wait's probe log (data.probeErrors: runs of equal
        failed probes { fromMs, toMs, count, code, adsCode, hresult, pidAlive, message }, at most
        50 runs, data.probeErrorsDropped; Wait-TcAdsState .DESCRIPTION) and, for a
        local UmRT, data.deadlineCheck (#114 S1, diagnosis of the crash verdict).

        Fail closed (#68): every failure once WriteControl was called - SYSTEM_STATE_TIMEOUT,
        SYSTEM_STATE_MISMATCH, RUNTIME_CRASHED and an exception (ADS error) from or after the
        write - also records a lifecycle block for the target (data.lifecycleBlock). A
        WriteControl that the target refuses on the spot (ADS error from the call itself) records
        one too: whether part of the request took effect is not known, so this is conservative.
        data.requestSent tells whether WriteControl was called ($false: nothing was sent).
        While a block exists for the target, this command returns LIFECYCLE_BLOCKED and sends
        nothing; only Clear-TcLifecycleBlock (after the user agreed) removes it.
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
            try { $AmsNetId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() }; Save-TcIdeTargetNetId $AmsNetId } catch { }
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

    # #68: a failed postcondition on this target is still unresolved: send nothing
    $blocked = Test-TcLifecycleBlock -AmsNetId $AmsNetId -Command 'Set-TcSystemState'
    if ($null -ne $blocked) { return $blocked }   # data.requestSent = $false (Test-TcLifecycleBlock)

    $loaded = Find-TcAdsAssembly
    if (-not $loaded) {
        return New-TcResult -Success $false -ErrorMessage 'TwinCAT.Ads.dll not found.' -ErrorCode 'ADS_ASSEMBLY_NOT_FOUND'
    }

    $sysClient = $null
    $sent = $false   # #68: WriteControl went out (a later failure records a lifecycle block)
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
        # PR #200 review: diagnostics of a stuck-in-Config failure end by request start + -TimeoutSec +
        # $script:TcSystemStateDiagCapSec (default 10 s), inside the MCP budget max(180 s, -TimeoutSec + 30 s)
        $diagCapSec = 10
        if ($null -ne $script:TcSystemStateDiagCapSec) { try { $diagCapSec = [Math]::Max(0, [int]$script:TcSystemStateDiagCapSec) } catch { $diagCapSec = 10 } }
        $diagDeadline = (Get-Date).AddSeconds($TimeoutSec + $diagCapSec)
        $sent = $true
        $sysClient.WriteControl($newState)  # tcauto-allow(writecontrol): Set-TcSystemState itself; leave / wait / settle readback below, failure -> lifecycle block

        # Original state = target (Run -> Run restart, Config -> Config): the target only
        # counts once the system was seen LEAVING it (other state or port unreachable),
        # otherwise the poll below would succeed on the stale pre-restart state. Polled every
        # 100 ms for at most 10 s (within -TimeoutSec). Measured 2026-10-21 (UmRT): Reset /
        # Reconfig make port 10000 unreachable after ~0.3 s, then Stop, then the target.
        # #114: data.leftOriginal is $true only when a read RETURNED a state other than the original
        # (a failed read is not a state); data.unreachableSeen reports failed reads after the write.
        # The restart counts as observed when either happened. Unknown original ($null) ->
        # leftOriginal $null. Original <> target: decided from the states the wait below reads.
        $leftOriginal = if ($null -eq $stateBefore) { $null } else { $false }
        $unreachableSeen = $false
        if ($stateBefore -eq $State) {
            $leaveSec = [Math]::Min(10, $TimeoutSec)
            while ($requestWatch.Elapsed.TotalSeconds -lt $leaveSec) {
                try {
                    $s = $sysClient.ReadState().AdsState.ToString()
                    if ($s -ne $State) { $leftOriginal = $true; break }
                }
                # port unreachable = restart in progress (observed, but not a state: the wait below
                # can still see e.g. Stop and set leftOriginal). Stop here: this client may stay stale.
                catch { $unreachableSeen = $true; break }
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
            unreachableSeen  = $unreachableSeen
            reached          = $false
            finalState       = $null
            currentState     = $null
            readbackState    = $null
            latencyMs        = $null
            stateTrace       = @()
            amsNetId         = $AmsNetId
            netIdSource      = $netIdSource
            elapsedMs        = [int]$requestWatch.ElapsedMilliseconds
            requestSent      = $true
        }

        if ($stateBefore -eq $State -and -not $leftOriginal -and -not $unreachableSeen) {
            $data.finalState = $State
            $data.currentState = $State
            $res = New-TcResult -Success $false `
                -ErrorMessage "TwinCAT was already in '$State' and never left it within $([Math]::Min(10, $TimeoutSec)) s after the AdsState write $sentName ($sentCode): the restart was not observed, so the current '$State' is the old state, not a confirmed restart." `
                -ErrorCode 'SYSTEM_STATE_MISMATCH' `
                -Hint (Get-TcErrorHint -Code 'SYSTEM_STATE_MISMATCH') `
                -Data $data
            return (Add-TcLifecycleBlockResult -Result $res -Command 'Set-TcSystemState' -AmsNetId $AmsNetId -RequestedState $State -ReachedState $State -Step 'leave-original')
        }

        # Poll port 10000 until the target state is reached (replaces fixed sleep)
        $remaining = [int][Math]::Max(1, [Math]::Ceiling($TimeoutSec - $requestWatch.Elapsed.TotalSeconds))
        # -DetectRuntimeCrash: a local UmRT whose TcSystemServiceUm vanished and that answers ADS 0x7
        # for >= 10 s ends the wait early with RUNTIME_CRASHED (Wait-TcAdsState .DESCRIPTION);
        # remote targets / no UmRT process at the start: unchanged, wait until -TimeoutSec.
        $wait = Wait-TcAdsState -AmsNetId $AmsNetId -Port 10000 -TargetState $State -TimeoutSec $remaining -DetectRuntimeCrash
        # #114: leftOriginal only from states that were actually read (failed probes are not states)
        if ($null -ne $stateBefore -and -not $leftOriginal) {
            $other = @(@($wait.StatesSeen) | Where-Object { -not [string]::IsNullOrEmpty([string]$_) -and [string]$_ -ne $stateBefore })
            if ($other.Count -gt 0) { $leftOriginal = $true; $data.leftOriginal = $true }
        }
        # #114: the last probe failed (ADS error, e.g. 0x7) -> the state is NOT the last value read
        # before; report 'Unreachable' (same word as data.stateTrace / readbackState of the settle
        # loop), the last value read goes to data.lastState
        # S2: a failed probe during the wait is also a failed read after the request
        if ($wait.AnyProbeFailed -eq $true) { $data.unreachableSeen = $true }
        # S1: on a failure, the wait's probe log and deadline check go into data (diagnosis)
        $addProbeData = {
            $data | Add-Member -NotePropertyName 'probeErrors' -NotePropertyValue @($wait.ProbeErrors | Where-Object { $null -ne $_ }) -Force
            $data | Add-Member -NotePropertyName 'probeErrorsDropped' -NotePropertyValue ([int]$wait.ProbeErrorsDropped) -Force
            $data | Add-Member -NotePropertyName 'deadlineCheck' -NotePropertyValue $wait.DeadlineCheck -Force
        }
        # #194: the runtime stays in / fell back to Config: what XAE says about it (modal dialog,
        # Error List, Boot package; Private/Get-TcRuntimeFailureDiagnostics.ps1). Never throws and
        # never changes the result code; without an IDE connection dialog / Error List are marked
        # unavailable. Skipped inside Enable-TcConfig (its set-run failure collects them itself).
        # PR #200 review: the modal scan comes FIRST; DTE (platform, PLC list, variant) is read only when
        # it found no dialog (a DTE call blocked by a dialog may never return). Otherwise the platform is
        # the cached one (Get-TcCachedSolutionPlatform) and the scan goes to the helper (-DialogScan).
        # Everything ends by $diagDeadline.
        $getStuckDiagnostics = {
            try {
                $ide = $true
                try { Assert-TcConnection } catch { $ide = $false }
                $plat = $null; $ports = @(); $variant = $null; $variantError = $null; $scan = $null; $dteNote = $null
                if ($ide) {
                    $scan = Get-TcDiagnosticsDialogScan -Deadline $diagDeadline
                    if ((Test-TcDiagnosticsDialogClear $scan) -and (Get-Date) -lt $diagDeadline) {
                        try { $cur = Get-TcSolutionPlatform; $plat = if ([string]::IsNullOrWhiteSpace($cur.projectPlatform)) { $cur.platform } else { $cur.projectPlatform } } catch { }
                        $smd = $null
                        try { $smd = Get-TcSysManager } catch { }
                        if ($null -ne $smd) {
                            try { $ports = @(Get-TcPlcProjectList -SysManager $smd | Where-Object { -not $_.disabled -and $null -ne $_.adsPort } | ForEach-Object { [int]$_.adsPort }) } catch { $ports = @() }
                            # #89: a variant project has its package in _Boot\<Variant>\<Platform>; unknown variant -> no comparison
                            try { $cv = Read-TcCurrentVariant -SysManager $smd; if ($null -eq $cv.Error) { $variant = [string]$cv.Value } else { $variantError = [string]$cv.Error } } catch { $variantError = $_.Exception.Message }
                        }
                    }
                    else {
                        $plat = Get-TcCachedSolutionPlatform
                        $why = if (Test-TcDiagnosticsDialogClear $scan) { 'the diagnostics deadline was reached' } elseif (Test-TcModalScanIncomplete $scan) { 'the modal dialog scan did not complete' } else { 'a modal dialog is up' }
                        $dteNote = "IDE not read ($why): platform $(if ($null -eq $plat) { 'unknown (no Connect-TcIde / Set-TcTarget read of this solution)' } else { "'$plat' from the last Connect-TcIde / Set-TcTarget read" }); PLC ADS ports and CurrentProjectVariant not read (every Port_*.app of the project package compared, base _Boot\<platform> folder)"
                    }
                }
                $sln = if ($ide) { $script:TcSolutionPath } else { $null }
                $d = Get-TcRuntimeFailureDiagnostics -NoIde:(-not $ide) -DialogScan $scan -Deadline $diagDeadline -SolutionPath $sln -Platform $(if ($null -eq $variantError) { $plat } else { $null }) -AmsNetId $AmsNetId -AdsPorts $ports -Variant $variant
                if ($null -ne $variantError -and $null -ne $d.bootPackage) { $d.bootPackage.reason = "CurrentProjectVariant not readable: $variantError" }
                if ($null -ne $dteNote -and $null -ne $d.bootPackage) {
                    $wp = $d.bootPackage.PSObject.Properties['warnings']
                    $w = if ($null -ne $wp) { @($wp.Value | Where-Object { $null -ne $_ }) } else { @() }
                    $d.bootPackage | Add-Member -NotePropertyName 'warnings' -NotePropertyValue @($w + $dteNote) -Force
                }
                $d
            }
            catch {
                [PSCustomObject]@{ dialog = $null; dialogScanComplete = $false; errorList = @(); errorListError = "diagnostics failed: $($_.Exception.Message)"; bootPackage = $null }
            }
        }
        # #194 / PR #200 review (fail closed first): called AFTER Add-TcLifecycleBlockResult wrote the block.
        # Adds data.licenses / data.diagnostics and replaces the generic hint by the #194 one
        # (Get-TcStuckInConfigHint), behind the stop text. Never throws.
        $addStuckDiagnostics = {
            param([object]$Res, [string]$Code)
            try {
                $base = Get-TcErrorHint -Code $Code
                $rd = $Res.data
                $lic = $null
                try { $lic = Get-TcLicenseDiagnosis -AmsNetId $AmsNetId } catch { }
                if ($null -ne $lic) { $rd | Add-Member -NotePropertyName 'licenses' -NotePropertyValue $lic -Force }
                $hint = $base
                if ($script:TcSystemStateSkipDiagnostics -eq $true) {
                    # nested in Enable-TcConfig: hint as before #194 (Enable-TcConfig adds its own diagnostics)
                    if ($null -ne $lic -and -not [string]::IsNullOrWhiteSpace($lic.text)) { $hint = "$($lic.text) $base" }
                }
                else {
                    $diag = & $getStuckDiagnostics
                    $rd | Add-Member -NotePropertyName 'diagnostics' -NotePropertyValue $diag -Force
                    try { $hint = Get-TcStuckInConfigHint -Code $Code -Diagnostics $diag -License $lic }
                    catch { if ($null -ne $lic -and -not [string]::IsNullOrWhiteSpace($lic.text)) { $hint = "$($lic.text) $base" } }
                }
                Set-TcHintAfterStopText -Result $Res -OldHint $base -NewHint $hint
            }
            catch { Write-Verbose "Set-TcSystemState: stuck-in-Config diagnostics failed ($($_.Exception.Message))" }
        }
        $lastReadFailed = -not [string]::IsNullOrEmpty([string]$wait.LastError)
        $seen = if (-not [string]::IsNullOrWhiteSpace([string]$wait.State)) { [string]$wait.State } else { $stateBefore }
        $shown = if ($lastReadFailed) { 'Unreachable' } else { $wait.State }
        $data.currentState = $shown
        $data.finalState = $shown
        $data.elapsedMs = [int]$requestWatch.ElapsedMilliseconds

        if ($wait.RuntimeCrashed) {
            $pidText = (@($wait.ServicePidAtStart) | ForEach-Object { [string]$_ }) -join ', '
            $data | Add-Member -NotePropertyName 'lastError' -NotePropertyValue $wait.LastError
            $data | Add-Member -NotePropertyName 'lastState' -NotePropertyValue $seen
            $data | Add-Member -NotePropertyName 'servicePidAtStart' -NotePropertyValue @($wait.ServicePidAtStart)
            $data | Add-Member -NotePropertyName 'runtimeName' -NotePropertyValue $wait.RuntimeName
            $data | Add-Member -NotePropertyName 'unreachableMs' -NotePropertyValue $wait.UnreachableMs
            $data | Add-Member -NotePropertyName 'crashDetectedBy' -NotePropertyValue $wait.CrashDetectedBy
            & $addProbeData
            $why = if ([string]$wait.CrashDetectedBy -eq 'deadline') {
                "no TcSystemServiceUm process of this runtime runs any more (pid $pidText at the start) and the last probe at -TimeoutSec $TimeoutSec s failed (last error: $($wait.LastError); ADS 0x7 streak $([int]($wait.UnreachableMs / 1000)) s; data.probeErrors, data.deadlineCheck)."
            }
            else { "TcSystemServiceUm (pid $pidText at the start) no longer exists and port 10000 answered ADS 0x7 for $([int]($wait.UnreachableMs / 1000)) s (last error: $($wait.LastError)). Stopped waiting after $([int]($requestWatch.ElapsedMilliseconds / 1000)) s instead of -TimeoutSec $TimeoutSec s." }
            $res = New-TcResult -Success $false `
                -ErrorMessage "The local UmRT '$($wait.RuntimeName)' disappeared while waiting for '$State' (last state seen: $seen): $why" `
                -ErrorCode 'RUNTIME_CRASHED' `
                -Hint (Get-TcErrorHint -Code 'RUNTIME_CRASHED') `
                -Data $data
            return (Add-TcLifecycleBlockResult -Result $res -Command 'Set-TcSystemState' -AmsNetId $AmsNetId -RequestedState $State -ReachedState $null -ReadbackNote 'runtime-gone' -Step "wait: runtime gone (RUNTIME_CRASHED); last state seen before it vanished: $seen")
        }

        if (-not $wait.Reached) {
            $detail = if ($wait.LastError) { " Last error: $($wait.LastError)" } else { '' }
            # #194: only a Run request that stays in Config (PR #200 review: never for -State Config)
            $stuck = ($State -eq 'Run' -and -not $lastReadFailed -and $wait.State -eq 'Config')
            $data | Add-Member -NotePropertyName 'lastState' -NotePropertyValue $seen
            $data | Add-Member -NotePropertyName 'lastError' -NotePropertyValue $wait.LastError
            if (-not [string]::IsNullOrEmpty([string]$wait.RuntimeName)) {
                # local UmRT, crash check active but not met (process still there / not 0x7): for diagnosis
                $data | Add-Member -NotePropertyName 'servicePidAtStart' -NotePropertyValue @($wait.ServicePidAtStart)
                $data | Add-Member -NotePropertyName 'runtimeName' -NotePropertyValue $wait.RuntimeName
                $data | Add-Member -NotePropertyName 'unreachableMs' -NotePropertyValue $wait.UnreachableMs
            }
            & $addProbeData
            $last = if ($lastReadFailed) { "unreachable (last state read: $seen)" } else { [string]$wait.State }
            $res = New-TcResult -Success $false `
                -ErrorMessage "TwinCAT did not reach state '$State' within $TimeoutSec s (last state: $last).$detail" `
                -ErrorCode 'SYSTEM_STATE_TIMEOUT' `
                -Hint (Get-TcErrorHint -Code 'SYSTEM_STATE_TIMEOUT') `
                -Data $data
            # #114: nothing was read back at the end: reachedState empty like the crash record, the
            # last value read before goes to the step text
            $reachedRb = if ($lastReadFailed) { $null } else { [string]$wait.State }
            $step = if ($lastReadFailed) { "wait: port 10000 unreachable at the deadline; last state read before: $seen" } else { 'wait' }
            $note = if ($lastReadFailed) { 'unreachable' } else { $null }
            # #68 / PR #200 review: the block is written before the (slower) diagnostics
            $res = Add-TcLifecycleBlockResult -Result $res -Command 'Set-TcSystemState' -AmsNetId $AmsNetId -RequestedState $State -ReachedState $reachedRb -ReadbackNote $note -Step $step
            if ($stuck) { & $addStuckDiagnostics $res 'SYSTEM_STATE_TIMEOUT' }
            return $res
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
        # #114: a settle sample that READ another state also counts as having left the original
        if ($null -ne $stateBefore -and -not $data.leftOriginal) {
            if (@($data.stateTrace | Where-Object { [string]$_.state -ne 'Unreachable' -and [string]$_.state -ne $stateBefore }).Count -gt 0) { $data.leftOriginal = $true }
        }
        foreach ($t in $data.stateTrace) { if ([string]$t.state -eq 'Unreachable') { $data.unreachableSeen = $true } }

        if ($null -ne $deviated) {
            $traceText = ($data.stateTrace | ForEach-Object { "+$($_.ms)ms $($_.state)" }) -join ', '
            # #194: only a Run request that fell back to Config (PR #200 review: never for -State Config)
            $stuck = ($State -eq 'Run' -and ($readback -eq 'Config' -or $deviated -eq 'Config'))
            $res = New-TcResult -Success $false `
                -ErrorMessage "TwinCAT reached '$State' but did not stay there: readback '$readback' after $SettleSec s (sent AdsState $sentName ($sentCode); trace $traceText)." `
                -ErrorCode 'SYSTEM_STATE_MISMATCH' `
                -Hint (Get-TcErrorHint -Code 'SYSTEM_STATE_MISMATCH') `
                -Data $data
            # #114: an unreachable final readback is not a state (reachedState empty, see the wait branch)
            $reachedRb = if ([string]$readback -eq 'Unreachable') { $null } else { [string]$readback }
            $step = if ($null -eq $reachedRb) { 'settle: port 10000 unreachable at the final readback' } else { 'settle' }
            $note = if ($null -eq $reachedRb) { 'unreachable' } else { $null }
            & $addProbeData
            # #68 / PR #200 review: the block is written before the (slower) diagnostics
            $res = Add-TcLifecycleBlockResult -Result $res -Command 'Set-TcSystemState' -AmsNetId $AmsNetId -RequestedState $State -ReachedState $reachedRb -ReadbackNote $note -Step $step
            if ($stuck) { & $addStuckDiagnostics $res 'SYSTEM_STATE_MISMATCH' }
            return $res
        }

        New-TcResult -Success $true -Data $data
    }
    catch {
        $res = New-TcAdsErrorResult -AmsNetId $AmsNetId -ErrorRecord $_ -DefaultCode 'SYSTEM_STATE_SET_FAILED' -MessagePrefix 'Failed to set system state'
        $rd = $res.PSObject.Properties['data']
        if ($null -eq $rd -or $null -eq $rd.Value) { $res | Add-Member -NotePropertyName 'data' -NotePropertyValue ([PSCustomObject]@{}) -Force }
        $res.data | Add-Member -NotePropertyName 'requestSent' -NotePropertyValue $sent -Force
        # #68: the request may have changed the runtime: fail closed
        if ($sent) { $res = Add-TcLifecycleBlockResult -Result $res -Command 'Set-TcSystemState' -AmsNetId $AmsNetId -RequestedState $State -ReachedState $null -Step 'after the state request (exception)' }
        $res
    }
    finally {
        if ($null -ne $sysClient) {
            try { $sysClient.Dispose() } catch { }
        }
    }
}
