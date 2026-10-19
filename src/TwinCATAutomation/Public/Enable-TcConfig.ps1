function Enable-TcConfig {
    <#
    .SYNOPSIS
        Activates the TwinCAT configuration; with -Force runs the full gated
        Config -> Activate -> Run -> Login -> PLC Run cycle (no dialog popups).
    .DESCRIPTION
        Without -Force only ITcSysManager::ActivateConfiguration() is called.

        With -Force every step is gated on the previous one and recorded in
        data.steps (@{ step; ok; elapsedMs; detail }). The first failing step stops
        the cycle: the result is success=false with that step's error code + hint and
        the steps completed so far.
          1. set-config     Set-TcSystemState -State Config (ADS WriteControl, port 10000)
          2. activate       ActivateConfiguration() (COM, retried when the IDE is busy)
          3. set-run        Set-TcSystemState -State Run  (waits until port 10000 = Run)
          4. login          Enter-TcPlcOnline (Login + download, skipped with -NoLogin)
          5. wait-plc-port  Wait until PLC port 851 answers (= program loaded). With
                            -NoLogin only 10 s are spent; no port 851 is then not an
                            error (step ok, detail 'skipped (no PLC port, -NoLogin)').
          6. set-plc-run    WriteControl Run on port 851, then wait-plc-run until
                            851 = Run (skipped with -NoLogin). The module ADS session
                            is used only when it points at <netId>:851; otherwise a
                            temporary 851 client sends Run and the session (e.g. port
                            10000 or another NetId) is left untouched.
          7. reconnect      Re-open the module ADS session if one existed before the
                            restart (skipped when step 6 already auto-reconnected it).
        -TimeoutSec is ONE overall deadline for the whole cycle: every wait gets the
        remaining time (min 1 s), and a step that would start after the deadline
        fails with CYCLE_TIMEOUT.
        The AmsNetId is taken from ITcSysManager.GetTargetNetId(), falling back to
        the AmsNetId cached by Connect-TcAds.
    .PARAMETER Force
        Run the full cycle described above instead of only activating.
    .PARAMETER NoLogin
        With -Force: skip login/download (steps 4 and 6). Step 5 then only waits up
        to 10 s for a boot project to bring port 851 up; if it does not, the step is
        recorded as skipped and the cycle still succeeds (plcState = $null).
    .PARAMETER TimeoutSec
        Overall time limit for the whole -Force cycle (single deadline). Default 120.
    .EXAMPLE
        Enable-TcConfig
        Activate only (TwinCAT keeps its current state).
    .EXAMPLE
        Enable-TcConfig -Force
        Config -> Activate -> Run -> Login/download -> PLC Run, reconnecting ADS afterwards.
    .EXAMPLE
        Enable-TcConfig -Force -NoLogin -TimeoutSec 180
        Restart TwinCAT with the new configuration without logging in; waits briefly
        for a boot project on 851 but does not fail when there is none.
    .OUTPUTS
        data: activated, restarted, loggedIn, reconnected, plcState (last AdsState seen
        on port 851), amsNetId, steps[].
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$NoLogin,

        [Parameter()]
        [ValidateRange(10, 3600)]
        [int]$TimeoutSec = 120
    )

    try { Assert-TcConnection } catch {
        return New-TcResult -Success $false -ErrorMessage $_.Exception.Message -ErrorCode 'NOT_CONNECTED'
    }

    $sm = Get-TcSysManager
    if ($null -eq $sm) {
        return New-TcNoSysManagerResult
    }

    # --- cycle state (read by the nested helpers below via dynamic scope) ---
    $steps = New-Object System.Collections.ArrayList
    $activated = $false
    $restarted = $false
    $loggedIn = $false
    $reconnected = $false
    $plcState = $null
    $netId = $null
    $wasConnected = [bool]$script:TcAdsConnected
    $origNetId = $script:TcAdsAmsNetId
    $origPort = $script:TcAdsPort
    $ideMemoryMB = $null

    function Add-TcStepRecord {
        param([string]$Name, [bool]$Ok, [System.Diagnostics.Stopwatch]$Watch, [string]$Detail)
        $null = $steps.Add([PSCustomObject]@{
            step      = $Name
            ok        = $Ok
            elapsedMs = [int]$Watch.ElapsedMilliseconds
            detail    = $Detail
        })
    }

    function Get-TcCycleData {
        [PSCustomObject]@{
            activated   = $activated
            restarted   = $restarted
            loggedIn    = $loggedIn
            reconnected = $reconnected
            plcState    = $plcState
            amsNetId    = $netId
            ideMemoryMB = $ideMemoryMB
            steps       = @($steps.ToArray())
        }
    }

    # Reads the IDE working set before Activate (a 32-bit XAE crashes with OutOfMemory
    # around 1.5 GB in the CODESYS Visu engine). Warns, never fails.
    function Read-TcIdeMemoryBeforeActivate {
        $mem = Get-TcIdeMemoryInfo
        if ($null -eq $mem) { return }
        Set-Variable -Name ideMemoryMB -Value $mem.MemoryMB -Scope 1
        if ($mem.Is32Bit -and $mem.MemoryMB -gt 1500) {
            Write-Warning "Enable-TcConfig: the 32-bit XAE uses $($mem.MemoryMB) MB (limit ~2-4 GB); ActivateConfiguration() may crash it with OutOfMemoryException. Consider Disconnect-TcIde -Quit and a fresh Connect-TcIde first."
        }
    }

    function New-TcStepFailure {
        param([string]$Message, [string]$Code, [string]$Hint)
        $params = @{ Success = $false; ErrorMessage = $Message; ErrorCode = $Code; Data = (Get-TcCycleData) }
        if ([string]::IsNullOrWhiteSpace($Hint)) { $Hint = Get-TcErrorHint -Code $Code }
        if (-not [string]::IsNullOrWhiteSpace($Hint)) { $params['Hint'] = $Hint }
        New-TcResult @params
    }

    # A modal dialog (Assertion Failed, fatal error ...) makes ActivateConfiguration()
    # block forever, so it is checked BEFORE each COM step. Returns a failure result
    # (code IDE_MODAL_DIALOG, data.dialogTitle/dialogText) or $null.
    function Test-TcStepModalDialog {
        param([string]$Name)
        $dlg = Get-TcIdeModalDialog
        if ($null -eq $dlg) { return $null }
        Add-TcStepRecord -Name $Name -Ok $false -Watch ([System.Diagnostics.Stopwatch]::StartNew()) -Detail "not started: IDE shows modal dialog '$($dlg.Title)'"
        $short = [string]$dlg.Text
        if ($short.Length -gt 200) { $short = $short.Substring(0, 200) }
        $res = New-TcStepFailure -Message "IDE_MODAL_DIALOG: step '$Name' not attempted - the IDE shows a modal dialog: $($dlg.Title) | $short" -Code 'IDE_MODAL_DIALOG'
        $res.data | Add-Member -NotePropertyName 'dialogTitle' -NotePropertyValue ([string]$dlg.Title) -Force
        $res.data | Add-Member -NotePropertyName 'dialogText' -NotePropertyValue ([string]$dlg.Text) -Force
        return $res
    }

    # Failure of a nested cmdlet result: keep its code + hint
    function New-TcStepFailureFromResult {
        param([object]$Result, [string]$Prefix, [string]$DefaultCode)
        $code = $DefaultCode
        $hint = $null
        $msg = ''
        if ($null -ne $Result -and $null -ne $Result.error) {
            if (-not [string]::IsNullOrWhiteSpace($Result.error.code)) { $code = $Result.error.code }
            $msg = [string]$Result.error.message
            $hp = $Result.error.PSObject.Properties['hint']
            if ($null -ne $hp) { $hint = [string]$hp.Value }
        }
        New-TcStepFailure -Message "${Prefix}: $msg" -Code $code -Hint $hint
    }

    # ------------------------------------------------------------------
    # Activate only (no -Force): behaviour unchanged
    # ------------------------------------------------------------------
    if (-not $Force) {
        $fail = Test-TcStepModalDialog -Name 'activate'
        if ($null -ne $fail) { return $fail }
        Read-TcIdeMemoryBeforeActivate
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-TcComRetry -OperationName 'ActivateConfiguration' -TimeoutSec 300 -ScriptBlock { $sm.ActivateConfiguration() } | Out-Null
            $activated = $true
            Add-TcStepRecord -Name 'activate' -Ok $true -Watch $sw -Detail 'ActivateConfiguration() done'
        }
        catch {
            Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $_.Exception.Message
            $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
            $code = if ($_.Exception.Message -match 'IDE_CRASHED') { 'IDE_CRASHED' } elseif ($null -ne $mapped) { $mapped.Code } else { 'ACTIVATION_FAILED' }
            $hint = if ($null -ne $mapped) { $mapped.Hint } else { $null }
            return New-TcStepFailure -Message "Activation failed: $($_.Exception.Message)" -Code $code -Hint $hint
        }

        $data = Get-TcCycleData
        $data | Add-Member -NotePropertyName 'message' -NotePropertyValue 'Configuration activated. Call with -Force to restart TwinCAT, download and start the PLC.'
        return New-TcResult -Success $true -Data $data
    }

    # ------------------------------------------------------------------
    # Full gated cycle (-Force)
    # ------------------------------------------------------------------
    # One overall deadline: each wait gets the remaining budget (min 1 s).
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

    function Get-TcRemainingSec {
        $left = [int][Math]::Ceiling(($deadline - (Get-Date)).TotalSeconds)
        if ($left -lt 1) { 1 } else { $left }
    }

    # Returns a failure result when the deadline has passed before step $Name starts, else $null.
    function Test-TcCycleDeadline {
        param([string]$Name)
        if ((Get-Date) -lt $deadline) { return $null }
        Add-TcStepRecord -Name $Name -Ok $false -Watch ([System.Diagnostics.Stopwatch]::StartNew()) -Detail "not started: -TimeoutSec $TimeoutSec s budget exhausted"
        New-TcStepFailure -Message "Enable-TcConfig -Force exceeded -TimeoutSec $TimeoutSec s before step '$Name'." -Code 'CYCLE_TIMEOUT'
    }

    # Resolve AmsNetId (same source as Set-TcSystemState, then the cached ADS session)
    try { $netId = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() } } catch { Write-Verbose "Enable-TcConfig: GetTargetNetId failed: $($_.Exception.Message)" }
    if ([string]::IsNullOrWhiteSpace($netId)) { $netId = $script:TcAdsAmsNetId }
    if ([string]::IsNullOrWhiteSpace($netId)) {
        return New-TcStepFailure -Message 'AmsNetId could not be determined from the IDE target or a previous Connect-TcAds.' -Code 'AMS_NETID_REQUIRED'
    }

    # 1. set-config
    $fail = Test-TcCycleDeadline -Name 'set-config'
    if ($null -ne $fail) { return $fail }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Set-TcSystemState -State Config -AmsNetId $netId -TimeoutSec (Get-TcRemainingSec)
    if (-not $r.success) {
        Add-TcStepRecord -Name 'set-config' -Ok $false -Watch $sw -Detail ([string]$r.error.message)
        return New-TcStepFailureFromResult -Result $r -Prefix 'Failed to switch to Config' -DefaultCode 'CONFIG_SWITCH_FAILED'
    }
    Add-TcStepRecord -Name 'set-config' -Ok $true -Watch $sw -Detail "system state $($r.data.currentState)"

    # 2. activate
    $fail = Test-TcCycleDeadline -Name 'activate'
    if ($null -ne $fail) { return $fail }
    $fail = Test-TcStepModalDialog -Name 'activate'
    if ($null -ne $fail) { return $fail }
    Read-TcIdeMemoryBeforeActivate
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TcComRetry -OperationName 'ActivateConfiguration' -TimeoutSec 300 -ScriptBlock { $sm.ActivateConfiguration() } | Out-Null
        $activated = $true
        Add-TcStepRecord -Name 'activate' -Ok $true -Watch $sw -Detail 'ActivateConfiguration() done'
    }
    catch {
        Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $_.Exception.Message
        $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
        $code = if ($_.Exception.Message -match 'IDE_CRASHED') { 'IDE_CRASHED' } elseif ($null -ne $mapped) { $mapped.Code } else { 'ACTIVATION_FAILED' }
        $hint = if ($null -ne $mapped) { $mapped.Hint } else { $null }
        return New-TcStepFailure -Message "Activation failed: $($_.Exception.Message)" -Code $code -Hint $hint
    }

    # 3. set-run (Set-TcSystemState waits until port 10000 reports Run)
    $fail = Test-TcCycleDeadline -Name 'set-run'
    if ($null -ne $fail) { return $fail }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Set-TcSystemState -State Run -AmsNetId $netId -TimeoutSec (Get-TcRemainingSec)
    if (-not $r.success) {
        Add-TcStepRecord -Name 'set-run' -Ok $false -Watch $sw -Detail ([string]$r.error.message)
        return New-TcStepFailureFromResult -Result $r -Prefix 'Failed to switch to Run' -DefaultCode 'RUN_SWITCH_FAILED'
    }
    $restarted = $true
    Add-TcStepRecord -Name 'set-run' -Ok $true -Watch $sw -Detail "system state $($r.data.currentState)"

    # 4. login (Enter-TcPlcOnline -LoginMode Regular: PLC_LOGIN_FLAGS REGULAR = 1, prompts answered by ITcAutomationSettings.SilentMode)
    if (-not $NoLogin) {
        $fail = Test-TcCycleDeadline -Name 'login'
        if ($null -ne $fail) { return $fail }
        # e.g. "Target system reports a fatal error" shown by the XAE after Activate
        $fail = Test-TcStepModalDialog -Name 'login'
        if ($null -ne $fail) { return $fail }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # Re-scan the solution: the system restart can leave cached tree items stale.
        # Only "no project / scan failed" is ignored here; an IDE crash must not be swallowed.
        try { $null = Get-TcSysManager -Refresh }
        catch {
            if ($_.Exception.Message -match 'IDE_CRASHED') {
                Add-TcStepRecord -Name 'login' -Ok $false -Watch $sw -Detail ([string]$_.Exception.Message)
                return New-TcStepFailure -Message ([string]$_.Exception.Message) -Code 'IDE_CRASHED'
            }
        }
        # REGULAR (1) + global SilentMode: XAE decides (downloads when the runtime has no application,
        # otherwise attaches). Verified 2026-10-19 on an empty UmRT and on a re-deploy
        # (lifecycle-smoke 37/37 twice). FORCEDOWNLOAD | SILENT (260) also deployed to the
        # empty runtime, but on the following cycle ActivateConfiguration() blocked for
        # 250 s: the 32-bit XAE crashed (OutOfMemoryException in the CODESYS Visu engine,
        # Windows event 1026), unrelated to the login flag. Regular is used here.
        $r = Enter-TcPlcOnline -LoginMode Regular
        if (-not $r.success) {
            Add-TcStepRecord -Name 'login' -Ok $false -Watch $sw -Detail ([string]$r.error.message)
            return New-TcStepFailureFromResult -Result $r -Prefix 'PLC login/download failed' -DefaultCode 'LOGIN_FAILED'
        }
        $loggedIn = $true
        Add-TcStepRecord -Name 'login' -Ok $true -Watch $sw -Detail ([string]$r.data.message)
    }

    # 5. wait-plc-port: 851 reachable = program loaded
    $fail = Test-TcCycleDeadline -Name 'wait-plc-port'
    if ($null -ne $fail) { return $fail }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $tPort = Get-TcRemainingSec
    if ($NoLogin) {
        # No download was done: only a boot project can bring 851 up. Short probe, not an error.
        $tPort = [Math]::Min(10, $tPort)
    }
    $wait = Wait-TcAdsState -AmsNetId $netId -Port 851 -TargetState Any -TimeoutSec $tPort
    $plcState = $wait.State
    if (-not $wait.Reached) {
        if ($NoLogin) {
            Add-TcStepRecord -Name 'wait-plc-port' -Ok $true -Watch $sw -Detail 'skipped (no PLC port, -NoLogin)'
        }
        else {
            $detail = "port 851 not reachable within $tPort s"
            if ($wait.LastError) { $detail += " (last error: $($wait.LastError))" }
            Add-TcStepRecord -Name 'wait-plc-port' -Ok $false -Watch $sw -Detail $detail
            return New-TcStepFailure -Message "PLC program not loaded: $detail" -Code 'PLC_NOT_LOADED'
        }
    }
    else {
        Add-TcStepRecord -Name 'wait-plc-port' -Ok $true -Watch $sw -Detail "port 851 state $($wait.State)"
    }

    # 6. set-plc-run + wait-plc-run
    $reconnectedInStep6 = $false
    if (-not $NoLogin) {
        $fail = Test-TcCycleDeadline -Name 'set-plc-run'
        if ($null -ne $fail) { return $fail }
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        # Use the module session only when it targets this NetId on port 851. A session on
        # port 10000 (or another NetId) would otherwise receive WriteControl Run and
        # restart TwinCAT itself / start the wrong target.
        $sessionIsPlc = (-not [string]::IsNullOrWhiteSpace($script:TcAdsAmsNetId)) -and
                        ($script:TcAdsPort -eq 851) -and
                        ($script:TcAdsAmsNetId -eq $netId)

        if ($sessionIsPlc) {
            $r = Set-TcPlcState -State Run -TimeoutSec (Get-TcRemainingSec)
            if (-not $r.success) {
                Add-TcStepRecord -Name 'set-plc-run' -Ok $false -Watch $sw -Detail ([string]$r.error.message)
                return New-TcStepFailureFromResult -Result $r -Prefix 'Failed to start PLC' -DefaultCode 'STATE_SET_FAILED'
            }
            $reconnectedInStep6 = [bool]$script:TcAdsReconnected
            $note = if ($reconnectedInStep6) { ', module session auto-reconnected' } else { '' }
            Add-TcStepRecord -Name 'set-plc-run' -Ok $true -Watch $sw -Detail "WriteControl Run sent via module session ${netId}:851, state $($r.data.currentState)$note"
        }
        else {
            $sessionDesc = if ([string]::IsNullOrWhiteSpace($script:TcAdsAmsNetId)) { 'none' } else { "$($script:TcAdsAmsNetId):$($script:TcAdsPort)" }
            $tmpClient = $null
            try {
                $tmpClient = New-TcAdsClient -AmsNetId $netId -Port 851
                $before = $tmpClient.ReadState()
                if ([int]$before.AdsState -eq 0) {
                    Add-TcStepRecord -Name 'set-plc-run' -Ok $false -Watch $sw -Detail 'port 851 reports AdsState Invalid (no program)'
                    return New-TcStepFailure -Message 'PLC runtime reports AdsState Invalid - no PLC program has been downloaded.' -Code 'PLC_NOT_LOADED'
                }
                if ([int]$before.AdsState -eq 5) {
                    # Boot project autostart already put the PLC in Run; WriteControl Run would
                    # answer ADS 0x712 "invalid state".
                    Add-TcStepRecord -Name 'set-plc-run' -Ok $true -Watch $sw -Detail "port 851 already in Run (boot project autostart), WriteControl skipped"
                }
                else {
                    $runInfo = New-Object TwinCAT.Ads.StateInfo
                    $runInfo.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], 5)  # AdsState.Run
                    $runInfo.DeviceState = 0
                    $tmpClient.WriteControl($runInfo)
                    Add-TcStepRecord -Name 'set-plc-run' -Ok $true -Watch $sw -Detail "WriteControl Run sent via temporary ${netId}:851 client (module session '$sessionDesc' untouched)"
                }
            }
            catch {
                Add-TcStepRecord -Name 'set-plc-run' -Ok $false -Watch $sw -Detail "Run via temporary ${netId}:851 client failed: $($_.Exception.Message)"
                $err = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'STATE_SET_FAILED' -MessagePrefix "WriteControl Run on ${netId}:851 failed"
                return New-TcStepFailureFromResult -Result $err -Prefix 'Failed to start PLC' -DefaultCode 'STATE_SET_FAILED'
            }
            finally {
                if ($null -ne $tmpClient) { try { $tmpClient.Dispose() } catch { } }
            }
        }

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $tPlcRun = Get-TcRemainingSec
        $wait = Wait-TcAdsState -AmsNetId $netId -Port 851 -TargetState Run -TimeoutSec $tPlcRun
        $plcState = $wait.State
        if (-not $wait.Reached) {
            $detail = "PLC did not reach Run within $tPlcRun s (last state: $($wait.State))"
            if ($wait.LastError) { $detail += " (last error: $($wait.LastError))" }
            Add-TcStepRecord -Name 'wait-plc-run' -Ok $false -Watch $sw -Detail $detail
            return New-TcStepFailure -Message $detail -Code 'PLC_RUN_TIMEOUT'
        }
        Add-TcStepRecord -Name 'wait-plc-run' -Ok $true -Watch $sw -Detail "port 851 state $($wait.State)"
    }

    # 7. reconnect the module ADS session that existed before the restart
    if ($reconnectedInStep6) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $reconnected = $true
        Add-TcStepRecord -Name 'reconnect' -Ok $true -Watch $sw -Detail 'already reconnected in step 6'
    }
    elseif ($wasConnected -and -not [string]::IsNullOrWhiteSpace($origNetId) -and $origPort -gt 0) {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $state = Connect-TcAdsSession -AmsNetId $origNetId -Port $origPort
            $reconnected = $true
            Add-TcStepRecord -Name 'reconnect' -Ok $true -Watch $sw -Detail "ADS session ${origNetId}:${origPort} reconnected (state $state)"
        }
        catch {
            Add-TcStepRecord -Name 'reconnect' -Ok $false -Watch $sw -Detail $_.Exception.Message
            $err = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'ADS_RECONNECT_FAILED' -MessagePrefix "ADS reconnect to ${origNetId}:${origPort} failed"
            return New-TcStepFailureFromResult -Result $err -Prefix 'Cycle completed but ADS reconnect failed' -DefaultCode 'ADS_RECONNECT_FAILED'
        }
    }

    $data = Get-TcCycleData
    $summary = if ($NoLogin) {
        if ($null -ne $plcState) { "Configuration activated, TwinCAT restarted, PLC port 851 reachable (state $plcState, no login)." }
        else { 'Configuration activated, TwinCAT restarted (no login; port 851 not present - no boot project).' }
    }
    else { "Configuration activated, TwinCAT restarted, program downloaded, PLC state $plcState." }
    $data | Add-Member -NotePropertyName 'message' -NotePropertyValue $summary
    New-TcResult -Success $true -Data $data
}
