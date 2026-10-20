function Enable-TcConfig {
    <#
    .SYNOPSIS
        Activates the TwinCAT configuration; with -Force runs the full gated
        Config -> Activate -> Run -> Login -> PLC Run cycle (no dialog popups).
    .DESCRIPTION
        Without -Force only ITcSysManager::ActivateConfiguration() is called.

        Before ActivateConfiguration() (both modes) the active solution platform
        (Get-TcSolutionPlatform) is compared with a reference platform
        (data.platformCheck):
          'target'     the platform the IDE target reports through TARGETINFO
                       (Get-TcTargetPlatform: port 200 IG 0x700, InfoSys "Runtime type (ADS)"
                       https://infosys.beckhoff.com/content/1033/tc170x_tc3_usermode_runtime/11687997963.html);
          'parameter'  TARGETINFO not readable, -Platform given: -Platform;
          'skipped'    TARGETINFO not readable and no -Platform (TcSystemServiceUm.exe
                       3.1.0.2649 / TwinCAT 3.1.4026.21-22 and the Windows XAR answer ADS
                       error 0x702): nothing is compared, Activate runs as before, a warning
                       is written (Write-Warning and data.warning, same hint as
                       PLATFORM_UNKNOWN). Also used when the solution platform is unreadable.
        When the reference and the solution platform differ:
          platform-fix        the solution configuration '<active configuration>|<target
                              platform>' is activated (same helper as Set-TcTarget); with
                              -NoPlatformFix PLATFORM_MISMATCH is returned instead and
                              nothing is activated. Platform missing from the solution ->
                              PLATFORM_NOT_FOUND, activation failed -> PLATFORM_SET_FAILED.
          platform-fix-build  Build-TcProject (same build as the cmdlet), because the PLC
                              output of the old platform must not be activated; a failing
                              build stops here with its code (BUILD_FAILED ...).
        Both steps are recorded in data.steps and are not part of the -TimeoutSec budget.
        The post-Activate LastBuildInfo check below (ACTIVATE_FAILED) stays in place and
        still catches a mismatch on the 'skipped' path.

        With -Force every step is gated on the previous one and recorded in
        data.steps (@{ step; ok; elapsedMs; detail }). The first failing step stops
        the cycle: the result is success=false with that step's error code + hint and
        the steps completed so far.
          1. set-config     Set-TcSystemState -State Config (ADS WriteControl, port 10000)
          2. activate       ActivateConfiguration() (COM, retried when the IDE is busy);
                            then SolutionBuild.LastBuildInfo is read: > 0 means XAE's
                            "Check config" failed silently (4026: active solution
                            platform differs from the target platform) -> ACTIVATE_FAILED
                            (same check without -Force)
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
        The platform-fix / platform-fix-build steps run before the deadline starts.
    .PARAMETER NoPlatformFix
        Do not switch the solution platform: a known mismatch returns PLATFORM_MISMATCH
        before anything is activated.
    .PARAMETER Platform
        Reference platform used only when the target does not report one through
        TARGETINFO, e.g. 'TwinCAT OS (x64)' for a Usermode Runtime (UmRT) or TwinCAT/BSD,
        'TwinCAT RT (x64)' for a Windows RT target. A platform the target reports wins.
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
        on port 851), amsNetId, ideMemoryMB, solutionPlatform (active solution platform
        at Activate time, after an automatic fix; $null when unreadable), targetPlatform
        ($null when not readable) / targetPlatformSource ('adsTargetInfo' | 'unavailable'),
        platformCheck ('target' | 'parameter' | 'skipped'), platformFixed (bool: the
        solution platform was switched and rebuilt), warning (only set on the 'skipped'
        path), steps[].
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [switch]$Force,

        [Parameter()]
        [switch]$NoLogin,

        [Parameter()]
        [ValidateRange(10, 3600)]
        [int]$TimeoutSec = 120,

        [Parameter()]
        [switch]$NoPlatformFix,

        [Parameter()]
        [string]$Platform
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
    $solutionPlatform = $null
    $targetPlatform = $null
    $targetPlatformSource = $null
    $platformFixed = $false
    $platformCheck = 'skipped'
    $platformWarning = $null

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
            solutionPlatform = $solutionPlatform
            targetPlatform = $targetPlatform
            targetPlatformSource = $targetPlatformSource
            platformFixed = $platformFixed
            platformCheck = $platformCheck
            warning     = $platformWarning
            steps       = @($steps.ToArray())
        }
    }

    # SolutionBuild.LastBuildInfo (number of failed projects), $null when unreadable.
    function Read-TcLastBuildInfo {
        try { return [int](Invoke-TcComRetry -MaxRetries 2 -OperationName 'LastBuildInfo' -ScriptBlock { $script:TcDte.Solution.SolutionBuild.LastBuildInfo }) }
        catch {
            Write-Verbose "Enable-TcConfig: LastBuildInfo not readable ($($_.Exception.Message))"
            return $null
        }
    }

    # 4026: when XAE's "Check config" fails (typically: active solution platform 'TwinCAT RT
    # (x64)' differs from the target platform 'TwinCAT OS (x64)' of a UmRT), SilentMode
    # auto-dismisses the warning box, the Output window only shows 'Check config failed!',
    # ActivateConfiguration() returns WITHOUT throwing and nothing is written to the target.
    # The only trace through COM is SolutionBuild.LastBuildInfo > 0 (measured 2026-10-21,
    # XAE 4026.22 in VS2022). Must run right after ActivateConfiguration(): it captures the
    # watchdog's $script:TcLastModalDialog before the next Invoke-TcComRetry resets it.
    # Returns $null when the activation looks good, else @{ Message; Hint }.
    function Get-TcActivateCheckFailure {
        param($FailedBefore)
        $dlg = $script:TcLastModalDialog
        $failed = Read-TcLastBuildInfo
        if ($null -eq $failed -or $failed -le 0) { return $null }
        $plat = if ([string]::IsNullOrWhiteSpace($solutionPlatform)) { '<unknown>' } else { $solutionPlatform }
        $tgt = if ([string]::IsNullOrWhiteSpace($targetPlatform)) { "not readable from the target; a Usermode Runtime (UmRT) is 'TwinCAT OS (x64)', a Windows RT target 'TwinCAT RT (x64)'" } else { "'$targetPlatform' reported by the target" }
        $msg = "ActivateConfiguration() returned but XAE reported $failed failed project(s) ('Check config failed!' in the Output window); nothing was written to the target. Most common cause: active solution platform '$plat' does not match the target platform ($tgt)."
        if ($null -ne $FailedBefore) { $msg += " (LastBuildInfo before Activate: $FailedBefore.)" }
        if ($null -ne $dlg) {
            $dlgText = [string]$dlg.Text
            if ($dlgText.Length -gt 300) { $dlgText = $dlgText.Substring(0, 300) }
            $msg += " Dialog seen during Activate: $([string]$dlg.Title) | $dlgText"
        }
        $id = $netId
        if ([string]::IsNullOrWhiteSpace($id)) {
            try { $id = [string]$sm.GetTargetNetId() } catch { $id = $null }
        }
        if ([string]::IsNullOrWhiteSpace($id)) { $id = '<id>' }
        $hint = Get-TcErrorHint -Code 'ACTIVATE_FAILED'
        if ($null -ne $hint) { $hint = $hint.Replace('<id>', $id) }
        return @{ Message = $msg; Hint = $hint }
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

    # Before ActivateConfiguration(): TwinCAT 4026 XAE refuses to activate when the active
    # solution platform differs from the target platform. Reference = TARGETINFO of the
    # target, else -Platform, else nothing (platformCheck 'skipped' + warning, old
    # behaviour). On a mismatch: switch the solution platform and rebuild (steps
    # platform-fix, platform-fix-build), or PLATFORM_MISMATCH with -NoPlatformFix.
    # Sets solutionPlatform / targetPlatform / targetPlatformSource / platformCheck /
    # platformWarning / platformFixed of the cmdlet scope. Returns a failure result or $null.
    function Invoke-TcPlatformCheck {
        param([string]$TargetNetId)
        $sol = Get-TcSolutionPlatform
        Set-Variable -Name solutionPlatform -Value $sol.platform -Scope 1
        $tp = $null
        if (-not [string]::IsNullOrWhiteSpace($TargetNetId)) {
            $tp = Get-TcTargetPlatform -AmsNetId $TargetNetId
            Set-Variable -Name targetPlatform -Value $tp.targetPlatform -Scope 1
            Set-Variable -Name targetPlatformSource -Value $tp.source -Scope 1
        }
        else {
            Set-Variable -Name targetPlatformSource -Value 'unavailable' -Scope 1
        }

        $wanted = $null
        $srcText = $null
        if ($null -ne $tp -and -not [string]::IsNullOrWhiteSpace($tp.targetPlatform)) {
            $wanted = [string]$tp.targetPlatform
            $srcText = "target $($tp.source)"
            Set-Variable -Name platformCheck -Value 'target' -Scope 1
        }
        elseif (-not [string]::IsNullOrWhiteSpace($Platform)) {
            $wanted = $Platform
            $srcText = 'parameter -Platform'
            Set-Variable -Name platformCheck -Value 'parameter' -Scope 1
        }

        if ($null -eq $wanted -or [string]::IsNullOrWhiteSpace($sol.platform)) {
            Set-Variable -Name platformCheck -Value 'skipped' -Scope 1
            $why = if ($null -eq $wanted) {
                $ads = if ($null -ne $tp -and -not [string]::IsNullOrWhiteSpace($tp.adsError)) { " (ADS $($tp.adsError))" } else { '' }
                "the target platform is not readable$ads and -Platform was not given"
            } else { 'the active solution platform is not readable' }
            $hint = Get-TcErrorHint -Code 'PLATFORM_UNKNOWN'
            if ($null -ne $hint -and $null -ne $tp -and -not [string]::IsNullOrWhiteSpace($tp.adsError)) { $hint = $hint.Replace('ADS 0x702', "ADS $($tp.adsError)") }
            $warn = "Enable-TcConfig: solution platform check skipped: $why; activating without it (a mismatch shows up as ACTIVATE_FAILED). $hint"
            Set-Variable -Name platformWarning -Value $warn -Scope 1
            Write-Warning $warn
            return $null
        }
        if ([string]$sol.platform -ieq $wanted) { return $null }

        $swFix = [System.Diagnostics.Stopwatch]::StartNew()
        if ($NoPlatformFix) {
            Add-TcStepRecord -Name 'platform-fix' -Ok $false -Watch $swFix -Detail "not done (-NoPlatformFix): solution '$($sol.platform)' <> '$wanted' ($srcText)"
            $hint = Get-TcErrorHint -Code 'PLATFORM_MISMATCH'
            $idText = if ([string]::IsNullOrWhiteSpace($TargetNetId)) { '<id>' } else { $TargetNetId }
            if ($null -ne $hint) { $hint = $hint.Replace('<id>', $idText).Replace('<platform>', $wanted) }
            return New-TcStepFailure -Message "Active solution platform '$($sol.platform)' differs from '$wanted' ($srcText). ActivateConfiguration() would fail with 'Check config failed!'; nothing was activated (-NoPlatformFix)." -Code 'PLATFORM_MISMATCH' -Hint $hint
        }

        $conf = if ([string]::IsNullOrWhiteSpace($sol.configuration)) { 'Release' } else { [string]$sol.configuration }
        $srcArg = if ($null -ne $tp -and $wanted -eq [string]$tp.targetPlatform) { $srcText } else { $null }
        $r = Set-TcSolutionPlatform -Platform $wanted -Configuration $conf -PlatformSource $srcArg
        if (-not $r.success) {
            Add-TcStepRecord -Name 'platform-fix' -Ok $false -Watch $swFix -Detail "'$($sol.platform)' -> '$wanted' ($srcText) failed: $([string]$r.error.message)"
            $code = if ([string]::IsNullOrWhiteSpace([string]$r.error.code)) { 'PLATFORM_SET_FAILED' } else { [string]$r.error.code }
            $hp = $r.error.PSObject.Properties['hint']
            $hint = if ($null -ne $hp) { [string]$hp.Value } else { $null }
            return New-TcStepFailure -Message "Automatic solution platform switch to '$wanted' ($srcText) failed: $([string]$r.error.message)" -Code $code -Hint $hint
        }
        Set-Variable -Name solutionPlatform -Value $r.platform -Scope 1
        Set-Variable -Name platformFixed -Value $true -Scope 1
        Add-TcStepRecord -Name 'platform-fix' -Ok $true -Watch $swFix -Detail "$($sol.platform) -> $($r.platform) ($srcText, configuration $($r.configuration))"

        # The PLC output of the old platform must not be activated: same build as Build-TcProject.
        $swBuild = [System.Diagnostics.Stopwatch]::StartNew()
        $b = Build-TcProject
        if (-not $b.success) {
            Add-TcStepRecord -Name 'platform-fix-build' -Ok $false -Watch $swBuild -Detail ([string]$b.error.message)
            return New-TcStepFailureFromResult -Result $b -Prefix 'Build after the automatic platform switch failed' -DefaultCode 'BUILD_FAILED'
        }
        Add-TcStepRecord -Name 'platform-fix-build' -Ok $true -Watch $swBuild -Detail "Build-TcProject after the platform switch succeeded ($($b.data.buildSec) s)"
        return $null
    }

    # Resolves the IDE target AmsNetId (ITcSysManager.GetTargetNetId, then the ADS session), $null when unknown.
    function Resolve-TcCycleNetId {
        $id = $null
        try { $id = Invoke-TcComRetry -OperationName 'GetTargetNetId' -ScriptBlock { $sm.GetTargetNetId() } } catch { Write-Verbose "Enable-TcConfig: GetTargetNetId failed: $($_.Exception.Message)" }
        if ([string]::IsNullOrWhiteSpace($id)) { $id = $script:TcAdsAmsNetId }
        if ([string]::IsNullOrWhiteSpace($id)) { return $null }
        return [string]$id
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
        $netId = Resolve-TcCycleNetId
        $fail = Invoke-TcPlatformCheck -TargetNetId $netId
        if ($null -ne $fail) { return $fail }
        $fail = Test-TcStepModalDialog -Name 'activate'
        if ($null -ne $fail) { return $fail }
        Read-TcIdeMemoryBeforeActivate
        $failedBefore = Read-TcLastBuildInfo
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-TcComRetry -OperationName 'ActivateConfiguration' -TimeoutSec 300 -ScriptBlock { $sm.ActivateConfiguration() } | Out-Null
        }
        catch {
            Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $_.Exception.Message
            $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
            $code = if ($_.Exception.Message -match 'IDE_CRASHED') { 'IDE_CRASHED' } elseif ($null -ne $mapped) { $mapped.Code } else { 'ACTIVATION_FAILED' }
            $hint = if ($null -ne $mapped) { $mapped.Hint } else { $null }
            return New-TcStepFailure -Message "Activation failed: $($_.Exception.Message)" -Code $code -Hint $hint
        }
        $checkFail = Get-TcActivateCheckFailure -FailedBefore $failedBefore
        if ($null -ne $checkFail) {
            Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $checkFail.Message
            return New-TcStepFailure -Message $checkFail.Message -Code 'ACTIVATE_FAILED' -Hint $checkFail.Hint
        }
        $activated = $true
        Add-TcStepRecord -Name 'activate' -Ok $true -Watch $sw -Detail 'ActivateConfiguration() done'

        $data = Get-TcCycleData
        $data | Add-Member -NotePropertyName 'message' -NotePropertyValue 'Configuration activated. Call with -Force to restart TwinCAT, download and start the PLC.'
        return New-TcResult -Success $true -Data $data
    }

    # ------------------------------------------------------------------
    # Full gated cycle (-Force)
    # ------------------------------------------------------------------
    # One overall deadline (set after the platform check below): each wait gets the
    # remaining budget (min 1 s).
    $deadline = $null

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
    $netId = Resolve-TcCycleNetId
    if ([string]::IsNullOrWhiteSpace($netId)) {
        return New-TcStepFailure -Message 'AmsNetId could not be determined from the IDE target or a previous Connect-TcAds.' -Code 'AMS_NETID_REQUIRED'
    }
    # Solution platform vs target platform (may switch + rebuild; not part of -TimeoutSec)
    $fail = Invoke-TcPlatformCheck -TargetNetId $netId
    if ($null -ne $fail) { return $fail }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)

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
    $failedBefore = Read-TcLastBuildInfo
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        Invoke-TcComRetry -OperationName 'ActivateConfiguration' -TimeoutSec 300 -ScriptBlock { $sm.ActivateConfiguration() } | Out-Null
    }
    catch {
        Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $_.Exception.Message
        $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
        $code = if ($_.Exception.Message -match 'IDE_CRASHED') { 'IDE_CRASHED' } elseif ($null -ne $mapped) { $mapped.Code } else { 'ACTIVATION_FAILED' }
        $hint = if ($null -ne $mapped) { $mapped.Hint } else { $null }
        return New-TcStepFailure -Message "Activation failed: $($_.Exception.Message)" -Code $code -Hint $hint
    }
    # Check config failed silently (LastBuildInfo > 0): stop the cycle here like any failing step.
    $checkFail = Get-TcActivateCheckFailure -FailedBefore $failedBefore
    if ($null -ne $checkFail) {
        Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $checkFail.Message
        return New-TcStepFailure -Message $checkFail.Message -Code 'ACTIVATE_FAILED' -Hint $checkFail.Hint
    }
    $activated = $true
    Add-TcStepRecord -Name 'activate' -Ok $true -Watch $sw -Detail 'ActivateConfiguration() done'

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
