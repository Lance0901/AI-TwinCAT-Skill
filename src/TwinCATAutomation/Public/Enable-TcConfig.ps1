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
        The check passes only when the active solution platform AND the project platform of
        the .tsproj under it (Get-TcSolutionPlatform projectPlatform; only the solution
        platform is compared when it is unreadable) equal the reference: a solution platform
        name can map to a project platform with another name (solution 'TwinCAT OS (x64)'
        -> project 'TwinCAT OS (ARMT2)').
        When they differ:
          platform-fix        the solution configuration '<active configuration>|<target
                              platform>' is activated (same helper as Set-TcTarget); with
                              -NoPlatformFix PLATFORM_MISMATCH is returned instead and
                              nothing is activated. With -NoPlatformFix it is
                              PLATFORM_PROJECT_MISMATCH instead (data.platformMap,
                              requestedProjectPlatform; nothing switched) when the solution
                              platform name already matches but its .tsproj is built for another
                              project platform, or when the .tsproj under '<configuration>|<wanted>'
                              is (read-only look-up with Get-TcSolutionConfigurations; unreadable
                              -> PLATFORM_MISMATCH): a switch cannot fix either. Platform missing from the solution ->
                              PLATFORM_NOT_FOUND; its .tsproj built for another project
                              platform -> PLATFORM_PROJECT_MISMATCH (nothing switched,
                              data.platformMap); activation failed -> PLATFORM_SET_FAILED.
          platform-fix-build  Build-TcProject (same build as the cmdlet), because the PLC
                              output of the old platform must not be activated; a failing
                              build stops here with its code (BUILD_FAILED ...).
        Both steps are recorded in data.steps and are not part of the -TimeoutSec budget.
        The post-Activate LastBuildInfo check below (ACTIVATE_FAILED) stays in place and
        still catches a mismatch on the 'skipped' path.
        After the platform check (both modes) nothing is activated while the BUILD_REQUIRED
        state of the solution has an entry (Private/Set-TcBuildRequired.ps1): a solution
        platform switch, or (#56) a Build-TcProject that finished without a complete success
        (LIBRARY_UNRESOLVED, BUILD_FAILED, BUILD_STATUS_UNKNOWN, success with completeBuild =
        false), with no complete Build-TcProject since. -AllowUnresolvedLibrary does not lift
        that entry by itself; only a build does (the platform-fix-build, or a separate
        Build-TcProject). A solution never built through the module has no entry: Activate
        compiles it without a check (known limit, docs/troubleshooting.md BUILD_REQUIRED).

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
          2b. boot-package  The project's _Boot\<platform> package is compared (SHA-256) with
                            the Boot folder of the target when the target runs on this PC
                            (Get-TcBootPackageDiff: CurrentConfig.xml, CurrentConfig.tszip,
                            CurrentConfig\*.tpzip, Plc\Port_*.app). A mismatch means Activate
                            did not write the new configuration: BOOT_PACKAGE_MISMATCH
                            (data.bootPackage lists every file with size / time / hash).
                            Remote targets: data.bootPackage.status = 'unavailable', step ok.
                            Also done without -Force.
          4. login          Enter-TcPlcOnline for EVERY PLC project of the solution (or the
                            ones given with -PlcProjectPath), skipped with -NoLogin
          5. wait-plc-port  Wait until each PLC's ADS port (<AdsPort> of the PLC node:
                            851, 852, ...) answers (= program loaded). With -NoLogin only
                            10 s are spent; no port is then not an error (step ok, detail
                            'skipped (no PLC port, -NoLogin)').
          6. set-plc-run    WriteControl Run on each PLC port, then wait-plc-run until the
                            port = Run (skipped with -NoLogin). The module ADS session
                            is used only when it points at <netId>:<that port>; otherwise a
                            temporary client sends Run and the session (e.g. port
                            10000 or another NetId) is left untouched.
          6b. verify        Final readback: port 10000 must still be Run and every PLC port
                            Run (-NoLogin: system only), and no modal dialog may be up
                            (e.g. "Target system reports a fatal error"). Otherwise
                            RUNTIME_STATE_MISMATCH (data.finalCheck). A runtime can reach
                            Run and fall back to Config when a PLC fails to start (ADS 1809
                            "symbol version invalid", #32), so nothing earlier counts as
                            proof.
          7. reconnect      Re-open the module ADS session if one existed before the
                            restart (skipped when step 6 already auto-reconnected it).
        When a step after Activate fails (set-run, wait-plc-port, wait-plc-run, verify),
        data.diagnostics is filled: dialog (modal dialog title/text), errorList (first error
        rows of the XAE Error List), bootPackage (fresh comparison). A Boot package
        mismatch turns the code into BOOT_PACKAGE_MISMATCH.
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
    .PARAMETER AllowUnresolvedLibrary
        Passed to the platform-fix-build (Build-TcProject -AllowUnresolvedLibrary): accept a
        build whose Error List shows unresolved libraries (LIBRARY_UNRESOLVED) as success.
    .PARAMETER NoPlatformFix
        Do not switch the solution platform: a known mismatch returns PLATFORM_MISMATCH
        before anything is activated.
    .PARAMETER ActivateTimeoutSec
        Deadline of ActivateConfiguration() (default 180; with -Force also bounded by the rest of
        -TimeoutSec). The call runs on its own thread (Invoke-TcActivateWithDeadline); when it does
        not return in time ACTIVATE_TIMEOUT is returned with data.activateDiagnostics (dialog,
        ideAlive, ideResponding, runtimeAlive, systemState) instead of waiting forever.
    .PARAMETER PlcProjectPath
        PLC project(s) to log into and start (name like 'FrameworkUnitTest' or tree path).
        Default: every PLC project under TIPC.
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
        on the first PLC port, 851 in a one-PLC solution), plcs[] (@{ name; projectPath;
        adsPort; loggedIn; state }), bootPackage, finalCheck (@{ systemState; plcs;
        dialog; ok }), diagnostics (only on a failure after Activate), amsNetId,
        ideMemoryMB, solutionPlatform (active solution platform
        at Activate time, after an automatic fix; $null when unreadable), projectPlatform
        (project platform of the ACTIVE .tsproj; $null without .tsproj), platformMap and
        requestedProjectPlatform (only after a failed platform-fix: solution platform ->
        project platforms; .tsproj project platform under the requested solution platform),
        targetPlatform
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
        [switch]$AllowUnresolvedLibrary,

        [Parameter()]
        [string]$Platform,

        [Parameter()]
        [string[]]$PlcProjectPath,

        [Parameter()]
        [ValidateRange(10, 3600)]
        [int]$ActivateTimeoutSec = 180
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
    $projectPlatform = $null
    $requestedProjectPlatform = $null
    $platformMap = $null
    $targetPlatform = $null
    $targetPlatformSource = $null
    $platformFixed = $false
    $platformCheck = 'skipped'
    $platformWarning = $null
    $plcs = @()
    $skippedPlcs = @()
    $bootPackage = $null
    $finalCheck = $null
    $diagnostics = $null

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
            projectPlatform = $projectPlatform
            requestedProjectPlatform = $requestedProjectPlatform
            platformMap = $platformMap
            targetPlatform = $targetPlatform
            targetPlatformSource = $targetPlatformSource
            platformFixed = $platformFixed
            platformCheck = $platformCheck
            warning     = $platformWarning
            plcs        = @($plcs)
            skippedPlcs = @($skippedPlcs)
            bootPackage = $bootPackage
            finalCheck  = $finalCheck
            diagnostics = $diagnostics
            steps       = @($steps.ToArray())
        }
    }

    # Project _Boot\<platform> vs the target's Boot folder (step boot-package). Sets
    # $bootPackage of the cmdlet scope; returns a failure result on a mismatch, else $null.
    function Test-TcBootPackage {
        param([string]$TargetNetId)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        # _Boot\<platform>: the project platform first (what the old SolutionContexts reading returned).
        $plat = $projectPlatform
        if ([string]::IsNullOrWhiteSpace($plat)) { $plat = $solutionPlatform }
        if ([string]::IsNullOrWhiteSpace($plat)) { $cur = Get-TcSolutionPlatform; $plat = if ([string]::IsNullOrWhiteSpace($cur.projectPlatform)) { $cur.platform } else { $cur.projectPlatform } }
        $bp = $null
        $ports = @()
        try { $ports = @(Get-TcPlcProjectList -SysManager $sm | Where-Object { -not $_.disabled -and $null -ne $_.adsPort } | ForEach-Object { [int]$_.adsPort }) } catch { $ports = @() }
        try { $bp = Get-TcBootPackageDiff -SolutionPath $script:TcSolutionPath -Platform $plat -AmsNetId $TargetNetId -AdsPorts $ports }
        catch { Write-Verbose "Enable-TcConfig: boot package check failed ($($_.Exception.Message))" }
        Set-Variable -Name bootPackage -Value $bp -Scope 1
        if ($null -eq $bp -or $bp.status -ne 'mismatch') {
            $why = if ($null -eq $bp) { 'check failed' } elseif ($bp.status -eq 'match') { "$(@($bp.files).Count) file(s) identical ($($bp.targetKind))" } else { "not compared: $($bp.reason)" }
            Add-TcStepRecord -Name 'boot-package' -Ok $true -Watch $sw -Detail $why
            return $null
        }
        $msg = "Boot package on the target ($($bp.targetDir)) differs from the project package ($($bp.localDir)) after Activate: $($bp.mismatches -join ', '). The target keeps an old configuration; the runtime would start with a stale CurrentConfig (ADS 1809 'symbol version invalid' / 'symbol description does not match')."
        Add-TcStepRecord -Name 'boot-package' -Ok $false -Watch $sw -Detail $msg
        return (New-TcStepFailure -Message $msg -Code 'BOOT_PACKAGE_MISMATCH')
    }

    # Failure of a step after Activate: collect modal dialog, Error List errors and a fresh
    # Boot package comparison into data.diagnostics; a Boot package mismatch wins as code.
    function New-TcRuntimeFailure {
        param([string]$Message, [string]$Code, [string]$Hint)
        $diag = [ordered]@{ dialog = $null; errorList = @(); errorListError = $null; bootPackage = $null }
        try {
            $dlg = Get-TcIdeModalDialog
            if ($null -ne $dlg) { $diag.dialog = [PSCustomObject]@{ title = [string]$dlg.Title; text = [string]$dlg.Text } }
        } catch { }
        if ($null -ne $deadline -and (Get-Date) -ge $deadline) {
            $diag.errorListError = 'skipped: -TimeoutSec budget exhausted'
        }
        elseif ($null -eq $diag.dialog) {
            try {
                $el = Get-TcBuildErrors -TimeoutSec 8
                if ($el.success) { $diag.errorList = @(@($el.data.errors) | Select-Object -First 10 | ForEach-Object { [string]$_.description }) }
                else { $diag.errorListError = [string]$el.error.code }
            } catch { $diag.errorListError = $_.Exception.Message }
        }
        $plat = $projectPlatform
        if ([string]::IsNullOrWhiteSpace($plat)) { $plat = $solutionPlatform }
        if ([string]::IsNullOrWhiteSpace($plat)) { try { $cur = Get-TcSolutionPlatform; $plat = if ([string]::IsNullOrWhiteSpace($cur.projectPlatform)) { $cur.platform } else { $cur.projectPlatform } } catch { } }
        $ports = @($plcs | Where-Object { $null -ne $_.adsPort } | ForEach-Object { [int]$_.adsPort })
        try { $diag.bootPackage = Get-TcBootPackageDiff -SolutionPath $script:TcSolutionPath -Platform $plat -AmsNetId $netId -AdsPorts $ports } catch { }
        Set-Variable -Name diagnostics -Value ([PSCustomObject]$diag) -Scope 1
        $extra = @()
        if ($null -ne $diag.dialog) { $extra += "dialog: $($diag.dialog.title) | $(([string]$diag.dialog.text) -replace '\s+', ' ')" }
        if (@($diag.errorList).Count -gt 0) { $extra += "Error List: $(@($diag.errorList | Select-Object -First 3) -join ' / ')" }
        if ($null -ne $diag.bootPackage -and $diag.bootPackage.status -eq 'mismatch') {
            $extra += "Boot package mismatch: $($diag.bootPackage.mismatches -join ', ')"
            # IDE_CRASHED / IDE_MODAL_DIALOG say more about what to do next: keep them
            if ($Code -notin @('IDE_CRASHED', 'IDE_MODAL_DIALOG')) {
                $Code = 'BOOT_PACKAGE_MISMATCH'
                $Hint = $null
            }
        }
        elseif (@($diag.errorList | Where-Object { $_ -match '(?i)symbol description does not match|1809|0x711|symbol version' }).Count -gt 0 -and $Code -ne 'IDE_MODAL_DIALOG') {
            $extra += 'symbol description / application mismatch (ADS 1809)'
        }
        if ($extra.Count -gt 0) { $Message = "$Message [diagnostics: $($extra -join '; ')]" }
        New-TcStepFailure -Message $Message -Code $Code -Hint $Hint
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

    # Before ActivateConfiguration(): XAE refuses to activate when the active solution
    # platform differs from the target platform (measured on 4026 XAE: ACTIVATE_FAILED);
    # the target decides the platform. Reference = TARGETINFO of the
    # target, else -Platform, else nothing (platformCheck 'skipped' + warning, old
    # behaviour). On a mismatch: switch the solution platform and rebuild (steps
    # platform-fix, platform-fix-build), or PLATFORM_MISMATCH with -NoPlatformFix.
    # Sets solutionPlatform / targetPlatform / targetPlatformSource / platformCheck /
    # platformWarning / platformFixed of the cmdlet scope. Returns a failure result or $null.
    function Invoke-TcPlatformCheck {
        param([string]$TargetNetId)
        $sol = Get-TcSolutionPlatform
        Set-Variable -Name solutionPlatform -Value $sol.platform -Scope 1
        Set-Variable -Name projectPlatform -Value $sol.projectPlatform -Scope 1
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
        # Both must match: the solution platform name and the project platform the .tsproj is
        # built for under it (unreadable project platform: only the solution platform counts).
        $projOk = [string]::IsNullOrWhiteSpace([string]$sol.projectPlatform) -or ([string]$sol.projectPlatform -ieq $wanted)
        if (([string]$sol.platform -ieq $wanted) -and $projOk) { return $null }
        $solText = if ([string]::IsNullOrWhiteSpace([string]$sol.projectPlatform) -or ([string]$sol.projectPlatform -ieq [string]$sol.platform)) { "'$($sol.platform)'" } else { "'$($sol.platform)' (project platform '$($sol.projectPlatform)')" }

        $swFix = [System.Diagnostics.Stopwatch]::StartNew()
        if ($NoPlatformFix) {
            Add-TcStepRecord -Name 'platform-fix' -Ok $false -Watch $swFix -Detail "not done (-NoPlatformFix): solution $solText <> '$wanted' ($srcText)"
            $idText = if ([string]::IsNullOrWhiteSpace($TargetNetId)) { '<id>' } else { $TargetNetId }
            if ([string]$sol.platform -ieq $wanted) {
                # Same solution platform name, other project platform: switching cannot help
                # (Set-TcTarget -Platform would return the same), the project settings must change.
                $hint = Get-TcErrorHint -Code 'PLATFORM_PROJECT_MISMATCH'
                if ($null -ne $hint) { $hint = $hint.Replace('<id>', $idText).Replace('<platform>', $wanted) }
                Set-Variable -Name requestedProjectPlatform -Value $sol.projectPlatform -Scope 1
                return New-TcStepFailure -Message "Active solution platform '$($sol.platform)' has the target's name ($srcText) but its .tsproj is built for project platform '$($sol.projectPlatform)'. Activating would not build for a '$wanted' target; nothing was activated (-NoPlatformFix)." -Code 'PLATFORM_PROJECT_MISMATCH' -Hint $hint
            }
            # Read-only look at '<configuration>|<wanted>': when its .tsproj is built for another
            # project platform, Set-TcTarget -Platform would only return PLATFORM_PROJECT_MISMATCH,
            # so say that now. Unreadable -> the plain PLATFORM_MISMATCH below.
            $confNow = if ([string]::IsNullOrWhiteSpace($sol.configuration)) { 'Release' } else { [string]$sol.configuration }
            try {
                $res = Resolve-TcPlatformTarget -Configs @(Get-TcSolutionConfigurations) -Platform $wanted -Configuration $confNow
                if (@($res.Candidates).Count -gt 0) {
                    $pc = Test-TcCandidateProjects -Candidates $res.Candidates -Platform $wanted
                    if ($pc.ProjectCheck -eq 'mismatch') {
                        $e = New-TcProjectMismatchError -SameConfig $res.SameConfig -Platform $wanted -Configuration $confNow -BadText $pc.BadText
                        Set-Variable -Name requestedProjectPlatform -Value $pc.RequestedProjectPlatform -Scope 1
                        Set-Variable -Name platformMap -Value $res.PlatformMap -Scope 1
                        $h = ([string]$e.hint).Replace('<id>', $idText)
                        return New-TcStepFailure -Message "Active solution platform $solText differs from '$wanted' ($srcText), and switching would not help: $([string]$e.message) (-NoPlatformFix: nothing was activated.)" -Code 'PLATFORM_PROJECT_MISMATCH' -Hint $h
                    }
                }
            }
            catch { Write-Verbose "Enable-TcConfig: project platform look-up skipped ($($_.Exception.Message))" }
            $hint = Get-TcErrorHint -Code 'PLATFORM_MISMATCH'
            if ($null -ne $hint) { $hint = $hint.Replace('<id>', $idText).Replace('<platform>', $wanted) }
            return New-TcStepFailure -Message "Active solution platform $solText differs from '$wanted' ($srcText). ActivateConfiguration() would fail with 'Check config failed!'; nothing was activated (-NoPlatformFix)." -Code 'PLATFORM_MISMATCH' -Hint $hint
        }

        $conf = if ([string]::IsNullOrWhiteSpace($sol.configuration)) { 'Release' } else { [string]$sol.configuration }
        $srcArg = if ($null -ne $tp -and $wanted -eq [string]$tp.targetPlatform) { $srcText } else { $null }
        $r = Set-TcSolutionPlatform -Platform $wanted -Configuration $conf -PlatformSource $srcArg
        $swp = $r.PSObject.Properties['stateWarning']
        if ($null -ne $swp -and -not [string]::IsNullOrWhiteSpace([string]$swp.Value)) {
            # BUILD_REQUIRED only in memory (state file not writable): reported on the success AND
            # the failure path (a failed switch that could not be undone records it too), still
            # enforced in this process
            Set-Variable -Name platformWarning -Value ([string]$swp.Value) -Scope 1
        }
        if (-not $r.success) {
            Set-Variable -Name platformMap -Value $r.platformMap -Scope 1
            # projectPlatform stays the ACTIVE one (unchanged / restored); the one under the
            # requested solution platform goes to requestedProjectPlatform.
            if (-not [string]::IsNullOrWhiteSpace([string]$r.projectPlatform)) { Set-Variable -Name projectPlatform -Value $r.projectPlatform -Scope 1 }
            Set-Variable -Name requestedProjectPlatform -Value $r.requestedProjectPlatform -Scope 1
            Add-TcStepRecord -Name 'platform-fix' -Ok $false -Watch $swFix -Detail "$solText -> '$wanted' ($srcText) failed: $([string]$r.error.message)"
            $code = if ([string]::IsNullOrWhiteSpace([string]$r.error.code)) { 'PLATFORM_SET_FAILED' } else { [string]$r.error.code }
            $hp = $r.error.PSObject.Properties['hint']
            $hint = if ($null -ne $hp) { [string]$hp.Value } else { $null }
            if ($null -ne $hint) { $hint = $hint.Replace('<id>', $(if ([string]::IsNullOrWhiteSpace($TargetNetId)) { '<id>' } else { $TargetNetId })) }
            return New-TcStepFailure -Message "Automatic solution platform switch to '$wanted' ($srcText) failed: $([string]$r.error.message)" -Code $code -Hint $hint
        }
        Set-Variable -Name solutionPlatform -Value $r.platform -Scope 1
        Set-Variable -Name projectPlatform -Value $r.projectPlatform -Scope 1
        Set-Variable -Name platformFixed -Value $true -Scope 1
        Add-TcStepRecord -Name 'platform-fix' -Ok $true -Watch $swFix -Detail "$solText -> $($r.platform) (project platform $($r.projectPlatform); $srcText, configuration $($r.configuration))"

        # The PLC output of the old platform must not be activated: same build as Build-TcProject.
        $swBuild = [System.Diagnostics.Stopwatch]::StartNew()
        $b = Build-TcProject -AllowUnresolvedLibrary:$AllowUnresolvedLibrary
        $bsw = if ($null -ne $b.data) { $b.data.PSObject.Properties['stateWarning'] } else { $null }
        if ($null -ne $bsw -and -not [string]::IsNullOrWhiteSpace([string]$bsw.Value)) {
            # keep both: the switch's and the build's state warning (review N6)
            $joined = if ([string]::IsNullOrWhiteSpace($platformWarning)) { [string]$bsw.Value }
                      elseif ($platformWarning -eq [string]$bsw.Value) { $platformWarning }
                      else { "$platformWarning | $([string]$bsw.Value)" }
            Set-Variable -Name platformWarning -Value $joined -Scope 1
        }
        if (-not $b.success) {
            Add-TcStepRecord -Name 'platform-fix-build' -Ok $false -Watch $swBuild -Detail ([string]$b.error.message)
            # The platform IS switched now: running Enable-TcConfig again would find the platforms
            # equal and skip this build, so the module keeps BUILD_REQUIRED until a COMPLETE build
            # (Build-TcProject data.completeBuild: coverageComplete and codeVerified = $true, or
            # -AllowUnresolvedLibrary with library rows only).
            $f = New-TcStepFailureFromResult -Result $b -Prefix "Build after the automatic platform switch to '$($r.platform)' failed (the solution platform stays switched; Enable-TcConfig refuses to activate until a complete Build-TcProject)" -DefaultCode 'BUILD_FAILED'
            $platHint = "The solution platform was switched to '$($r.platform)'. A complete Build-TcProject (data.completeBuild = true: coverageComplete and codeVerified = true, or the AllowUnresolvedLibrary switch with library errors only) must succeed before Enable-TcConfig activates again (with unresolved libraries: install them; only if the user accepts that the code may not be compiled: Build-TcProject -AllowUnresolvedLibrary). $([string]$f.error.hint)".TrimEnd()
            $f.error | Add-Member -NotePropertyName 'hint' -NotePropertyValue $platHint -Force
            return $f
        }
        $verdict = Format-TcBuildVerdict -Data $b.data
        Add-TcStepRecord -Name 'platform-fix-build' -Ok $true -Watch $swBuild -Detail "Build-TcProject after the platform switch succeeded ($($b.data.buildSec) s); $verdict"
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

    # A platform switch (Set-TcTarget / platform-fix) or a build that was not a complete success
    # (#56), without a complete build since then. Platform switch: the PLC output may still be
    # that of the previous platform (inferred, not measured). Unverified build: Activate would
    # compile again without anybody checking the result (measured 2026-10-26, TcXaeShell 4024,
    # TwinCAT_Festo copy, local UmRT: activated + success after LIBRARY_UNRESOLVED). A solution
    # never built through the module has no entry and is not refused (known limit). Returns a
    # failure or $null.
    function Test-TcBuildRequired {
        $req = Get-TcBuildRequired
        if ($null -eq $req) { return $null }
        $at = if ([string]::IsNullOrWhiteSpace([string]$req.at)) { '' } else { " at $($req.at)" }
        $sln = if ([string]::IsNullOrWhiteSpace([string]$req.solution)) { 'unknown solution' } else { [string]$req.solution }
        # Why the last successful build of this session did not count (complete = coverageComplete
        # and codeVerified = true, or -AllowUnresolvedLibrary with library rows only).
        $last = ''
        $lv = $script:TcLastBuildVerdict
        if ($null -ne $lv -and -not $lv.completeBuild) {
            $last = " The last successful Build-TcProject ($($lv.at)) did not count as complete: $(Format-TcBuildVerdict -Data $lv)."
        }
        Add-TcStepRecord -Name 'build-required' -Ok $false -Watch ([System.Diagnostics.Stopwatch]::StartNew()) -Detail "$($req.reason)$at ($sln); no complete Build-TcProject since.$last"
        return New-TcStepFailure -Message "Not activated: $($req.reason)$at ($sln) and no complete Build-TcProject since; $(Get-TcBuildRequiredConsequence -Entry $req).$last" -Code 'BUILD_REQUIRED'
    }

    # "completeBuild=..., codeVerified=..., coverageComplete=..., warningCodes=[...]" of a
    # Build-TcProject result data / $script:TcLastBuildVerdict.
    function Format-TcBuildVerdict {
        param([object]$Data)
        $fmt = { param($v) if ($null -eq $v) { 'null' } else { ([string]$v).ToLowerInvariant() } }
        $wc = @()
        if ($null -ne $Data.PSObject.Properties['warningCodes']) { $wc = @($Data.warningCodes) }
        $cb = if ($null -ne $Data.PSObject.Properties['completeBuild']) { $Data.completeBuild } else { $null }
        "completeBuild=$(& $fmt $cb), codeVerified=$(& $fmt $Data.codeVerified), coverageComplete=$(& $fmt $Data.coverageComplete), warningCodes=[$($wc -join ', ')]"
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
        $fail = Test-TcBuildRequired
        if ($null -ne $fail) { return $fail }
        $fail = Test-TcStepModalDialog -Name 'activate'
        if ($null -ne $fail) { return $fail }
        Read-TcIdeMemoryBeforeActivate
        $failedBefore = Read-TcLastBuildInfo
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            Invoke-TcActivateWithDeadline -TimeoutSec $ActivateTimeoutSec -AmsNetId $netId
        }
        catch {
            Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $_.Exception.Message
            $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
            $code = if ($_.Exception.Message -match 'IDE_CRASHED') { 'IDE_CRASHED' } elseif ($_.Exception.Message -match '^ACTIVATE_TIMEOUT') { 'ACTIVATE_TIMEOUT' } elseif ($null -ne $mapped) { $mapped.Code } else { 'ACTIVATION_FAILED' }
            $hint = if ($code -eq 'ACTIVATE_TIMEOUT') { Get-TcErrorHint -Code 'ACTIVATE_TIMEOUT' } elseif ($null -ne $mapped) { $mapped.Hint } else { $null }
            $res = New-TcStepFailure -Message "Activation failed: $($_.Exception.Message)" -Code $code -Hint $hint
            if ($code -eq 'ACTIVATE_TIMEOUT' -and $null -ne $script:TcLastActivateDiagnostics) {
                $res.data | Add-Member -NotePropertyName 'activateDiagnostics' -NotePropertyValue $script:TcLastActivateDiagnostics -Force
            }
            return $res
        }
        $checkFail = Get-TcActivateCheckFailure -FailedBefore $failedBefore
        if ($null -ne $checkFail) {
            Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $checkFail.Message
            return New-TcStepFailure -Message $checkFail.Message -Code 'ACTIVATE_FAILED' -Hint $checkFail.Hint
        }
        $activated = $true
        Add-TcStepRecord -Name 'activate' -Ok $true -Watch $sw -Detail 'ActivateConfiguration() done'
        $fail = Test-TcBootPackage -TargetNetId $netId
        if ($null -ne $fail) { return $fail }

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
    $fail = Test-TcBuildRequired
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
        Invoke-TcActivateWithDeadline -TimeoutSec ([Math]::Min($ActivateTimeoutSec, (Get-TcRemainingSec))) -AmsNetId $netId
    }
    catch {
        Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $_.Exception.Message
        $mapped = ConvertTo-TcAdsErrorCode -InputObject $_
        $code = if ($_.Exception.Message -match 'IDE_CRASHED') { 'IDE_CRASHED' } elseif ($_.Exception.Message -match '^ACTIVATE_TIMEOUT') { 'ACTIVATE_TIMEOUT' } elseif ($null -ne $mapped) { $mapped.Code } else { 'ACTIVATION_FAILED' }
        $hint = if ($code -eq 'ACTIVATE_TIMEOUT') { Get-TcErrorHint -Code 'ACTIVATE_TIMEOUT' } elseif ($null -ne $mapped) { $mapped.Hint } else { $null }
        $res = New-TcStepFailure -Message "Activation failed: $($_.Exception.Message)" -Code $code -Hint $hint
        if ($code -eq 'ACTIVATE_TIMEOUT' -and $null -ne $script:TcLastActivateDiagnostics) {
            $res.data | Add-Member -NotePropertyName 'activateDiagnostics' -NotePropertyValue $script:TcLastActivateDiagnostics -Force
        }
        return $res
    }
    # Check config failed silently (LastBuildInfo > 0): stop the cycle here like any failing step.
    $checkFail = Get-TcActivateCheckFailure -FailedBefore $failedBefore
    if ($null -ne $checkFail) {
        Add-TcStepRecord -Name 'activate' -Ok $false -Watch $sw -Detail $checkFail.Message
        return New-TcStepFailure -Message $checkFail.Message -Code 'ACTIVATE_FAILED' -Hint $checkFail.Hint
    }
    $activated = $true
    Add-TcStepRecord -Name 'activate' -Ok $true -Watch $sw -Detail 'ActivateConfiguration() done'

    # 2b. boot-package
    $fail = Test-TcBootPackage -TargetNetId $netId
    if ($null -ne $fail) { return $fail }

    # 3. set-run (Set-TcSystemState waits until port 10000 reports Run)
    $fail = Test-TcCycleDeadline -Name 'set-run'
    if ($null -ne $fail) { return $fail }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = Set-TcSystemState -State Run -AmsNetId $netId -TimeoutSec (Get-TcRemainingSec)
    if (-not $r.success) {
        Add-TcStepRecord -Name 'set-run' -Ok $false -Watch $sw -Detail ([string]$r.error.message)
        $code = if ([string]::IsNullOrWhiteSpace([string]$r.error.code)) { 'RUN_SWITCH_FAILED' } else { [string]$r.error.code }
        $hp = if ($null -ne $r.error) { $r.error.PSObject.Properties['hint'] } else { $null }
        return New-TcRuntimeFailure -Message "Failed to switch to Run: $([string]$r.error.message)" -Code $code -Hint $(if ($null -ne $hp) { [string]$hp.Value } else { $null })
    }
    $restarted = $true
    Add-TcStepRecord -Name 'set-run' -Ok $true -Watch $sw -Detail "system state $($r.data.currentState) (sent $($r.data.sentAdsState), held $($r.data.readbackState))"

    # PLC projects of the solution (or -PlcProjectPath): name, tree path, ADS port
    try { $null = Get-TcSysManager -Refresh }
    catch {
        if ($_.Exception.Message -match 'IDE_CRASHED') {
            return New-TcStepFailure -Message ([string]$_.Exception.Message) -Code 'IDE_CRASHED'
        }
    }
    $allPlcs = @()
    try { $allPlcs = @(Get-TcPlcProjectList -SysManager (Get-TcSysManager)) }
    catch {
        if ($_.Exception.Message -match 'IDE_CRASHED|IDE_MODAL_DIALOG') { return New-TcStepFailureFromResult -Result (New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'PLC_PROJECT_NOT_FOUND' -MessagePrefix 'Reading the PLC projects failed') -Prefix 'PLC lookup' -DefaultCode 'PLC_PROJECT_NOT_FOUND' }
        Write-Verbose "Enable-TcConfig: PLC project list not readable ($($_.Exception.Message)); using port 851"
    }
    $selected = @()
    if (@($PlcProjectPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        foreach ($spec in $PlcProjectPath) {
            if ([string]::IsNullOrWhiteSpace($spec)) { continue }
            $hit = Find-TcPlcProject -List $allPlcs -Spec $spec
            if ($null -eq $hit) {
                return New-TcStepFailure -Message "PLC project '$spec' not found. PLC projects: $(($allPlcs | ForEach-Object { $_.projectPath }) -join ', ')" -Code 'PLC_PROJECT_NOT_FOUND'
            }
            $selected += $hit
        }
    }
    else {
        # disabled PLC projects (ITcSmTreeItem.Disabled) are not activated: not logged in, not waited for
        $selected = @($allPlcs | Where-Object { -not $_.disabled })
        $skippedPlcs = @($allPlcs | Where-Object { $_.disabled } | ForEach-Object { $_.name })
        if ($skippedPlcs.Count -gt 0) { Write-Verbose "Enable-TcConfig: disabled PLC project(s) skipped: $($skippedPlcs -join ', ')" }
    }
    $plcs = @($selected | ForEach-Object {
        [PSCustomObject]@{
            name        = $_.name
            projectPath = $_.projectPath
            adsPort     = if ($null -ne $_.adsPort) { [int]$_.adsPort } else { 851 }
            loggedIn    = $false
            state       = $null
        }
    })
    if ($plcs.Count -eq 0) {
        # no PLC found under TIPC: keep the old single-PLC behaviour on port 851
        $plcs = @([PSCustomObject]@{ name = $null; projectPath = $null; adsPort = 851; loggedIn = $false; state = $null })
    }

    # 4. login (Enter-TcPlcOnline -LoginMode Regular: PLC_LOGIN_FLAGS REGULAR = 1, prompts answered by ITcAutomationSettings.SilentMode)
    if (-not $NoLogin) {
        $fail = Test-TcCycleDeadline -Name 'login'
        if ($null -ne $fail) { return $fail }
        # e.g. "Target system reports a fatal error" shown by the XAE after Activate
        $fail = Test-TcStepModalDialog -Name 'login'
        if ($null -ne $fail) { return $fail }
        # REGULAR (1) + global SilentMode: XAE decides (downloads when the runtime has no application,
        # otherwise attaches). Verified 2026-10-19 on an empty UmRT and on a re-deploy
        # (lifecycle-smoke 37/37 twice). FORCEDOWNLOAD | SILENT (260) also deployed to the
        # empty runtime, but on the following cycle ActivateConfiguration() blocked for
        # 250 s: the 32-bit XAE crashed (OutOfMemoryException in the CODESYS Visu engine,
        # Windows event 1026), unrelated to the login flag. Regular is used here.
        # Every PLC project is logged in on its own (multi-PLC solutions, #32).
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $loginDetails = @()
        foreach ($p in $plcs) {
            $fail = Test-TcCycleDeadline -Name 'login'
            if ($null -ne $fail) { return $fail }
            $tLogin = Get-TcRemainingSec
            $r = if ($null -ne $p.projectPath) { Enter-TcPlcOnline -LoginMode Regular -PlcProjectPath $p.projectPath -TimeoutSec $tLogin } else { Enter-TcPlcOnline -LoginMode Regular -TimeoutSec $tLogin }
            if (-not $r.success) {
                Add-TcStepRecord -Name 'login' -Ok $false -Watch $sw -Detail "$($p.name): $([string]$r.error.message)"
                return New-TcStepFailureFromResult -Result $r -Prefix "PLC login/download of '$($p.name)' (port $($p.adsPort)) failed" -DefaultCode 'LOGIN_FAILED'
            }
            $p.loggedIn = $true
            $loginDetails += "$($p.name):$($p.adsPort) $([string]$r.data.message)"
        }
        $loggedIn = $true
        Add-TcStepRecord -Name 'login' -Ok $true -Watch $sw -Detail ($loginDetails -join ' | ')
    }

    # 5. wait-plc-port: each PLC port reachable = program loaded
    $fail = Test-TcCycleDeadline -Name 'wait-plc-port'
    if ($null -ne $fail) { return $fail }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $portDetails = @()
    $noPortDetails = @()
    foreach ($p in $plcs) {
        $tPort = Get-TcRemainingSec
        if ($NoLogin) {
            # No download was done: only a boot project can bring the port up. Short probe, not an error.
            $tPort = [Math]::Min(10, $tPort)
        }
        $wait = Wait-TcAdsState -AmsNetId $netId -Port $p.adsPort -TargetState Any -TimeoutSec $tPort
        $p.state = $wait.State
        if (-not $wait.Reached) {
            $detail = "port $($p.adsPort) not reachable within $tPort s"
            if ($wait.LastError) { $detail += " (last error: $($wait.LastError))" }
            if ($NoLogin) { $noPortDetails += $detail; continue }
            Add-TcStepRecord -Name 'wait-plc-port' -Ok $false -Watch $sw -Detail $detail
            $plcState = $plcs[0].state
            return New-TcRuntimeFailure -Message "PLC program '$($p.name)' not loaded: $detail" -Code 'PLC_NOT_LOADED'
        }
        $portDetails += "port $($p.adsPort) state $($wait.State)"
    }
    $plcState = $plcs[0].state
    if ($portDetails.Count -eq 0 -and $NoLogin) {
        Add-TcStepRecord -Name 'wait-plc-port' -Ok $true -Watch $sw -Detail 'skipped (no PLC port, -NoLogin)'
    }
    else {
        $all = @($portDetails) + @($noPortDetails | ForEach-Object { "$_ (-NoLogin)" })
        Add-TcStepRecord -Name 'wait-plc-port' -Ok $true -Watch $sw -Detail ($all -join ', ')
    }

    # 6. set-plc-run + wait-plc-run, per PLC port
    $reconnectedInStep6 = $false
    if (-not $NoLogin) {
        foreach ($p in $plcs) {
            $port = [int]$p.adsPort
            $fail = Test-TcCycleDeadline -Name 'set-plc-run'
            if ($null -ne $fail) { return $fail }
            $sw = [System.Diagnostics.Stopwatch]::StartNew()

            # Use the module session only when it targets this NetId on this PLC port. A
            # session on port 10000 (or another NetId / PLC) would otherwise receive
            # WriteControl Run and restart TwinCAT itself / start the wrong target.
            $sessionIsPlc = (-not [string]::IsNullOrWhiteSpace($script:TcAdsAmsNetId)) -and
                            ($script:TcAdsPort -eq $port) -and
                            ($script:TcAdsAmsNetId -eq $netId)

            if ($sessionIsPlc) {
                $r = Set-TcPlcState -State Run -TimeoutSec (Get-TcRemainingSec)
                if (-not $r.success) {
                    Add-TcStepRecord -Name 'set-plc-run' -Ok $false -Watch $sw -Detail "port ${port}: $([string]$r.error.message)"
                    return New-TcStepFailureFromResult -Result $r -Prefix "Failed to start PLC '$($p.name)' (port $port)" -DefaultCode 'STATE_SET_FAILED'
                }
                $reconnectedInStep6 = $reconnectedInStep6 -or [bool]$script:TcAdsReconnected
                $note = if ([bool]$script:TcAdsReconnected) { ', module session auto-reconnected' } else { '' }
                Add-TcStepRecord -Name 'set-plc-run' -Ok $true -Watch $sw -Detail "WriteControl Run sent via module session ${netId}:${port}, state $($r.data.currentState)$note"
            }
            else {
                $sessionDesc = if ([string]::IsNullOrWhiteSpace($script:TcAdsAmsNetId)) { 'none' } else { "$($script:TcAdsAmsNetId):$($script:TcAdsPort)" }
                $tmpClient = $null
                try {
                    $tmpClient = New-TcAdsClient -AmsNetId $netId -Port $port
                    $before = $tmpClient.ReadState()
                    if ([int]$before.AdsState -eq 0) {
                        Add-TcStepRecord -Name 'set-plc-run' -Ok $false -Watch $sw -Detail "port $port reports AdsState Invalid (no program)"
                        return New-TcRuntimeFailure -Message "PLC runtime port $port ('$($p.name)') reports AdsState Invalid - no PLC program has been downloaded." -Code 'PLC_NOT_LOADED'
                    }
                    if ([int]$before.AdsState -eq 5) {
                        # Boot project autostart already put the PLC in Run; WriteControl Run would
                        # answer ADS 0x712 "invalid state".
                        Add-TcStepRecord -Name 'set-plc-run' -Ok $true -Watch $sw -Detail "port $port already in Run (boot project autostart), WriteControl skipped"
                    }
                    else {
                        $runInfo = New-Object TwinCAT.Ads.StateInfo
                        $runInfo.AdsState = [Enum]::ToObject([TwinCAT.Ads.AdsState], 5)  # AdsState.Run
                        $runInfo.DeviceState = 0
                        $tmpClient.WriteControl($runInfo)
                        Add-TcStepRecord -Name 'set-plc-run' -Ok $true -Watch $sw -Detail "WriteControl Run sent via temporary ${netId}:${port} client (module session '$sessionDesc' untouched)"
                    }
                }
                catch {
                    Add-TcStepRecord -Name 'set-plc-run' -Ok $false -Watch $sw -Detail "Run via temporary ${netId}:${port} client failed: $($_.Exception.Message)"
                    $err = New-TcAdsErrorResult -ErrorRecord $_ -DefaultCode 'STATE_SET_FAILED' -MessagePrefix "WriteControl Run on ${netId}:${port} failed"
                    $hp = $err.error.PSObject.Properties['hint']
                    return New-TcRuntimeFailure -Message "Failed to start PLC '$($p.name)': $([string]$err.error.message)" -Code ([string]$err.error.code) -Hint $(if ($null -ne $hp) { [string]$hp.Value } else { $null })
                }
                finally {
                    if ($null -ne $tmpClient) { try { $tmpClient.Dispose() } catch { } }
                }
            }

            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $tPlcRun = Get-TcRemainingSec
            $wait = Wait-TcAdsState -AmsNetId $netId -Port $port -TargetState Run -TimeoutSec $tPlcRun
            $p.state = $wait.State
            $plcState = $plcs[0].state
            if (-not $wait.Reached) {
                $detail = "PLC '$($p.name)' (port $port) did not reach Run within $tPlcRun s (last state: $($wait.State))"
                if ($wait.LastError) { $detail += " (last error: $($wait.LastError))" }
                Add-TcStepRecord -Name 'wait-plc-run' -Ok $false -Watch $sw -Detail $detail
                return New-TcRuntimeFailure -Message $detail -Code 'PLC_RUN_TIMEOUT'
            }
            Add-TcStepRecord -Name 'wait-plc-run' -Ok $true -Watch $sw -Detail "port $port state $($wait.State)"
        }
    }

    # 6b. verify: final readback of the system and every PLC port + modal dialog check
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $sysState = $null
    $sysErr = $null
    $probe = $null
    try {
        $probe = New-TcAdsClient -AmsNetId $netId -Port 10000
        $sysState = $probe.ReadState().AdsState.ToString()
    }
    catch { $sysErr = $_.Exception.Message }
    finally { if ($null -ne $probe) { try { $probe.Dispose() } catch { } } }
    $plcChecks = @()
    $bad = @()
    if ($sysState -ne 'Run') { $bad += "system (port 10000) $(if ($sysState) { $sysState } else { "unreachable: $sysErr" })" }
    foreach ($p in $plcs) {
        $st = $null
        $probe = $null
        try {
            $probe = New-TcAdsClient -AmsNetId $netId -Port ([int]$p.adsPort)
            $st = $probe.ReadState().AdsState.ToString()
        }
        catch { $st = $null }
        finally { if ($null -ne $probe) { try { $probe.Dispose() } catch { } } }
        $p.state = $st
        $plcChecks += [PSCustomObject]@{ name = $p.name; adsPort = $p.adsPort; state = $st }
        if (-not $NoLogin -and $st -ne 'Run') { $bad += "PLC '$($p.name)' port $($p.adsPort) $(if ($st) { $st } else { 'unreachable' })" }
    }
    $plcState = $plcs[0].state
    $dlg = $null
    try { $dlg = Get-TcIdeModalDialog } catch { }
    $dlgInfo = if ($null -ne $dlg) { [PSCustomObject]@{ title = [string]$dlg.Title; text = [string]$dlg.Text } } else { $null }
    if ($null -ne $dlg) { $bad += "modal dialog '$($dlg.Title)'" }
    $finalCheck = [PSCustomObject]@{ systemState = $sysState; plcs = $plcChecks; dialog = $dlgInfo; ok = ($bad.Count -eq 0) }
    if ($bad.Count -gt 0) {
        $detail = "final readback: $($bad -join ', ')"
        Add-TcStepRecord -Name 'verify' -Ok $false -Watch $sw -Detail $detail
        return New-TcRuntimeFailure -Message "Cycle steps reported success but the $detail." -Code 'RUNTIME_STATE_MISMATCH'
    }
    Add-TcStepRecord -Name 'verify' -Ok $true -Watch $sw -Detail "system Run; $((($plcChecks | ForEach-Object { "port $($_.adsPort) $($_.state)" }) -join ', '))"

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
    $plcText = (($plcs | ForEach-Object { "port $($_.adsPort) $(if ($_.state) { $_.state } else { 'not present' })" }) -join ', ')
    $summary = if ($NoLogin) {
        if ($null -ne $plcState) { "Configuration activated, TwinCAT restarted, PLC port(s) reachable ($plcText, no login)." }
        else { "Configuration activated, TwinCAT restarted (no login; $plcText - no boot project)." }
    }
    else { "Configuration activated, TwinCAT restarted, program(s) downloaded, PLC state $plcText (verified by readback)." }
    $data | Add-Member -NotePropertyName 'message' -NotePropertyValue $summary
    New-TcResult -Success $true -Data $data
}
