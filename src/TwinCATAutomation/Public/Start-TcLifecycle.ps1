function Start-TcLifecycle {
    <#
    .SYNOPSIS
        Full PLC lifecycle in one call: Connect-TcIde -> [Set-TcTarget] -> [Build-TcProject] ->
        Enable-TcConfig -Force -> Connect-TcAds -> Get-TcPlcState (readback).
    .DESCRIPTION
        PowerShell counterpart of the MCP composite tool RunLifecycle (#27): same parameters, same
        step order, same data fields. Changes the running machine (TwinCAT restarts, the PLC program
        is downloaded and started): confirm with the user first.

        Steps (each one only after the previous one returned success = $true):
          ConnectIde    Connect-TcIde (-SolutionPath, -ProgId, -NoLaunch).
          SetTarget     Only with -TargetAmsNetId or -Platform. With -Platform: Set-TcTarget -Platform
                        (AmsNetId = -TargetAmsNetId, else data.amsNetId of ConnectIde, else
                        AMS_NETID_REQUIRED); with -TargetAmsNetId only: Set-TcTarget -NoPlatformSwitch
                        (the platform check is left to Enable-TcConfig).
          BuildProject  Build-TcProject (-ExpectedProject, -BuildTimeoutSec as -TimeoutSec); skipped
                        with -SkipBuild. Coverage errors (PROJECT_SKIPPED_BY_CONFIGURATION,
                        EXPECTED_PROJECT_NOT_FOUND, ...) come from Build-TcProject itself.
          EnableConfig  Enable-TcConfig -Force (-TimeoutSec, -NoLogin, -Platform, -PlcProjectPath).
          ConnectAds    Connect-TcAds [-Port]. The port: -AdsPort when given; otherwise the adsPort of
                        the one PLC in Enable-TcConfig data.plcs when -PlcProjectPath selected exactly
                        one; otherwise no -Port (Connect-TcAds default 851). -AdsPort that differs from
                        the adsPort of that one selected PLC: PLC_PORT_MISMATCH, nothing is connected.
          GetPlcState   Get-TcPlcState readback. Without -NoLogin the state must be 'Run', otherwise
                        RUNTIME_STATE_MISMATCH; with -NoLogin the state is only reported.

        Fail closed (#68): the first step that does not return success = $true ends the call; later
        steps do not run, nothing is retried and no other control channel is tried. The error is that
        step's error as it is (LIFECYCLE_BLOCKED included; its data.lifecycleBlock is copied to
        data.lifecycleBlock). Report it and data.steps to the user.

        data: steps[] ({name, success, code, durationMs, result}; code = error code of a failed step,
        else $null; result = the raw result of the step's cmdlet), failedStep (step name or $null),
        plcProjects (Enable-TcConfig data.plcs), adsPort (Connect-TcAds data.port), loggedIn
        (Enable-TcConfig data.loggedIn), plcState (Get-TcPlcState data.state), lifecycleBlock;
        fields of steps that did not run are $null.
    .PARAMETER SolutionPath
        Solution (.sln) to open on Connect-TcIde. Omit to attach to the running XAE.
    .PARAMETER ProgId
        Visual Studio / XAE shell ProgId passed to Connect-TcIde.
    .PARAMETER NoLaunch
        Do not launch XAE if it is not running (Connect-TcIde -NoLaunch).
    .PARAMETER TargetAmsNetId
        AmsNetId to select with Set-TcTarget before the build. Omit to keep the target the IDE has.
    .PARAMETER Platform
        Solution platform passed to Set-TcTarget and Enable-TcConfig, e.g. 'TwinCAT OS (x64)' for a
        Usermode Runtime (UmRT) or TwinCAT/BSD, 'TwinCAT RT (x64)' for a Windows RT target. Needed only
        when the target does not report its platform (TARGETINFO, ADS 0x702).
    .PARAMETER SkipBuild
        Skip Build-TcProject. Enable-TcConfig still refuses with BUILD_REQUIRED when no complete build
        was recorded.
    .PARAMETER TimeoutSec
        Enable-TcConfig -TimeoutSec (default 120, 10..3600).
    .PARAMETER NoLogin
        Enable-TcConfig -NoLogin: activate only, no PLC login / download / Run. The readback then only
        reports the PLC state.
    .PARAMETER PlcProjectPath
        Enable-TcConfig -PlcProjectPath: PLC project(s) to log into and start (name like
        'FrameworkUnitTest' or tree path). Default: every enabled PLC project.
    .PARAMETER ExpectedProject
        Build-TcProject -ExpectedProject: PLC project(s) that must be part of the build. Not derived
        from -PlcProjectPath; pass both for a multi-PLC solution.
    .PARAMETER AdsPort
        ADS port for Connect-TcAds (1..65535). Default: the port of the one PLC selected with
        -PlcProjectPath, else 851.
    .PARAMETER BuildTimeoutSec
        Build-TcProject -TimeoutSec (5..7200). Default: the Build-TcProject default.
    .EXAMPLE
        Start-TcLifecycle -SolutionPath C:\Proj\Machine.sln -TargetAmsNetId $netId -Platform 'TwinCAT OS (x64)'
        Connect, select the target and platform, build, activate, log in, start and read back Run.
    .EXAMPLE
        Start-TcLifecycle -PlcProjectPath FrameworkUnitTest -ExpectedProject FrameworkUnitTest -AdsPort 852
        Multi-PLC solution: build must include FrameworkUnitTest, only that PLC is logged in and
        started, ADS connects to its port 852 (PLC_PORT_MISMATCH when that PLC has another port).
    .EXAMPLE
        Start-TcLifecycle -SkipBuild -NoLogin
        Activate the configuration of the last complete build without PLC login; report the PLC state.
    .NOTES
        No SupportsShouldProcess, like Enable-TcConfig and Invoke-TcTestCycle: the confirmation is
        the caller's (AI agent: ask the user before calling it).
    #>
    [CmdletBinding()]
    param(
        [Parameter()]
        [string]$SolutionPath,

        [Parameter()]
        [string]$ProgId,

        [Parameter()]
        [switch]$NoLaunch,

        [Parameter()]
        [string]$TargetAmsNetId,

        [Parameter()]
        [string]$Platform,

        [Parameter()]
        [switch]$SkipBuild,

        [Parameter()]
        [ValidateRange(10, 3600)]
        [int]$TimeoutSec = 120,

        [Parameter()]
        [switch]$NoLogin,

        [Parameter()]
        [string[]]$PlcProjectPath,

        [Parameter()]
        [string[]]$ExpectedProject,

        [Parameter()]
        [ValidateRange(1, 65535)]
        [int]$AdsPort,

        [Parameter()]
        [ValidateRange(5, 7200)]
        [int]$BuildTimeoutSec
    )

    $steps = [System.Collections.Generic.List[object]]::new()
    $data = [PSCustomObject]@{
        steps          = @()
        failedStep     = $null
        plcProjects    = $null
        adsPort        = $null
        loggedIn       = $null
        plcState       = $null
        lifecycleBlock = $null
    }

    # Runs one step: the last object with a 'success' property is its result; a throw or no result
    # becomes INTERNAL_ERROR (the lifecycle stops there like on any other failure).
    $runStep = {
        param([string]$Name, [scriptblock]$Call)
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $r = $null
        try {
            $r = @(& $Call) | Where-Object { $null -ne $_ -and $null -ne $_.PSObject.Properties['success'] } | Select-Object -Last 1
            if ($null -eq $r) { $r = New-TcResult -Success $false -ErrorMessage "$Name returned no result object" -ErrorCode 'INTERNAL_ERROR' }
        }
        catch {
            $r = New-TcResult -Success $false -ErrorMessage "$Name threw: $($_.Exception.Message)" -ErrorCode 'INTERNAL_ERROR'
        }
        $sw.Stop()
        $ok = ($r.success -eq $true)
        $code = $null
        if (-not $ok) { $code = if ($null -ne $r.error -and -not [string]::IsNullOrWhiteSpace([string]$r.error.code)) { [string]$r.error.code } else { 'STEP_FAILED' } }
        $s = [PSCustomObject]@{ name = $Name; success = $ok; code = $code; durationMs = [int]$sw.ElapsedMilliseconds; result = $r }
        $steps.Add($s)
        $s
    }
    # A step that fails without calling its cmdlet (precondition): result = the error result
    $addFailedStep = {
        param([string]$Name, [object]$Result)
        $s = [PSCustomObject]@{ name = $Name; success = $false; code = [string]$Result.error.code; durationMs = 0; result = $Result }
        $steps.Add($s)
        $s
    }
    # Overall failure. The error object is the step's error as it is (it already went through
    # New-TcResult in that cmdlet, hint and lifecycle-block advice included): wrapping it in
    # New-TcResult again would rewrite the hint a second time.
    $finish = {
        param([object]$Step, [object]$ErrorObject)
        $data.steps = $steps.ToArray()
        $data.failedStep = $Step.name
        $res = $Step.result
        if ($null -ne $res -and $null -ne $res.PSObject.Properties['data'] -and $null -ne $res.data -and $null -ne $res.data.PSObject.Properties['lifecycleBlock']) {
            $data.lifecycleBlock = $res.data.lifecycleBlock
        }
        $err = $ErrorObject
        if ($null -eq $err -and $null -ne $res) { $err = $res.error }
        if ($null -eq $err) { $err = (New-TcResult -Success $false -ErrorMessage "$($Step.name) failed" -ErrorCode 'STEP_FAILED').error }
        [PSCustomObject]@{ success = $false; error = $err; data = $data }
    }

    # 1. ConnectIde
    $connectArgs = @{}
    if ($PSBoundParameters.ContainsKey('SolutionPath')) { $connectArgs['SolutionPath'] = $SolutionPath }
    if ($PSBoundParameters.ContainsKey('ProgId')) { $connectArgs['ProgId'] = $ProgId }
    if ($NoLaunch) { $connectArgs['NoLaunch'] = $true }
    $step = & $runStep 'ConnectIde' { Connect-TcIde @connectArgs }
    if (-not $step.success) { return (& $finish $step) }

    # 2. SetTarget (only with -TargetAmsNetId or -Platform)
    $hasTarget = -not [string]::IsNullOrEmpty($TargetAmsNetId)
    $hasPlatform = -not [string]::IsNullOrEmpty($Platform)
    if ($hasTarget -or $hasPlatform) {
        $netId = $TargetAmsNetId
        if (-not $hasTarget -and $null -ne $step.result.data -and $null -ne $step.result.data.PSObject.Properties['amsNetId']) { $netId = [string]$step.result.data.amsNetId }
        if ([string]::IsNullOrEmpty($netId)) {
            $r = New-TcResult -Success $false -ErrorCode 'AMS_NETID_REQUIRED' `
                -ErrorMessage 'Platform was given without TargetAmsNetId and Connect-TcIde reported no target AmsNetId.' `
                -Hint 'Pass -TargetAmsNetId together with -Platform (Find-TcAdsTarget / Get-TcAdsRoutes list the targets).'
            $step = & $addFailedStep 'SetTarget' $r
            return (& $finish $step)
        }
        $setArgs = @{ AmsNetId = $netId }
        # Without -Platform only the NetId is set: Set-TcTarget would otherwise return PLATFORM_UNKNOWN on
        # runtimes without TARGETINFO; Enable-TcConfig does the platform check.
        if ($hasPlatform) { $setArgs['Platform'] = $Platform } else { $setArgs['NoPlatformSwitch'] = $true }
        $step = & $runStep 'SetTarget' { Set-TcTarget @setArgs }
        if (-not $step.success) { return (& $finish $step) }
    }

    # 3. BuildProject
    if (-not $SkipBuild) {
        $buildArgs = @{}
        if ($PSBoundParameters.ContainsKey('ExpectedProject')) { $buildArgs['ExpectedProject'] = $ExpectedProject }
        if ($PSBoundParameters.ContainsKey('BuildTimeoutSec')) { $buildArgs['TimeoutSec'] = $BuildTimeoutSec }
        $step = & $runStep 'BuildProject' { Build-TcProject @buildArgs }
        if (-not $step.success) { return (& $finish $step) }
    }

    # 4. EnableConfig
    $enableArgs = @{ Force = $true; TimeoutSec = $TimeoutSec }
    if ($NoLogin) { $enableArgs['NoLogin'] = $true }
    if ($hasPlatform) { $enableArgs['Platform'] = $Platform }
    $hasPlcPath = $PSBoundParameters.ContainsKey('PlcProjectPath') -and @($PlcProjectPath | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0
    if ($hasPlcPath) { $enableArgs['PlcProjectPath'] = $PlcProjectPath }
    $step = & $runStep 'EnableConfig' { Enable-TcConfig @enableArgs }
    $ed = $step.result.data
    if ($null -ne $ed) {
        if ($null -ne $ed.PSObject.Properties['plcs']) { $data.plcProjects = @($ed.plcs) }
        if ($null -ne $ed.PSObject.Properties['loggedIn']) { $data.loggedIn = $ed.loggedIn }
    }
    if (-not $step.success) { return (& $finish $step) }

    # 5. ConnectAds: -AdsPort, else the port of the one PLC selected with -PlcProjectPath, else 851
    $onePlc = $null
    if ($hasPlcPath -and $null -ne $data.plcProjects -and @($data.plcProjects).Count -eq 1) {
        $p = @($data.plcProjects)[0]
        if ($null -ne $p -and $null -ne $p.PSObject.Properties['adsPort'] -and $null -ne $p.adsPort) { $onePlc = $p }
    }
    $adsArgs = @{}
    if ($PSBoundParameters.ContainsKey('AdsPort')) {
        if ($null -ne $onePlc -and [int]$onePlc.adsPort -ne $AdsPort) {
            $r = New-TcResult -Success $false -ErrorCode 'PLC_PORT_MISMATCH' `
                -ErrorMessage "-AdsPort $AdsPort differs from ADS port $([int]$onePlc.adsPort) of PLC project '$($onePlc.name)' (-PlcProjectPath); ADS was not connected." `
                -Hint (Get-TcErrorHint -Code 'PLC_PORT_MISMATCH') `
                -Data ([PSCustomObject]@{ adsPort = $AdsPort; plcAdsPort = [int]$onePlc.adsPort; plc = $onePlc.name; projectPath = $onePlc.projectPath })
            $step = & $addFailedStep 'ConnectAds' $r
            return (& $finish $step)
        }
        $adsArgs['Port'] = $AdsPort
    }
    elseif ($null -ne $onePlc) {
        $adsArgs['Port'] = [int]$onePlc.adsPort
    }
    $step = & $runStep 'ConnectAds' { Connect-TcAds @adsArgs }
    if ($null -ne $step.result.data -and $null -ne $step.result.data.PSObject.Properties['port']) { $data.adsPort = $step.result.data.port }
    if (-not $step.success) { return (& $finish $step) }

    # 6. GetPlcState readback (CODING_STANDARDS 2: success only after the readback)
    $step = & $runStep 'GetPlcState' { Get-TcPlcState }
    if ($null -ne $step.result.data -and $null -ne $step.result.data.PSObject.Properties['state']) { $data.plcState = $step.result.data.state }
    if (-not $step.success) { return (& $finish $step) }
    if (-not $NoLogin -and [string]$data.plcState -ne 'Run') {
        # the raw Get-TcPlcState result stays in step.result; the step itself failed
        $step.success = $false
        $step.code = 'RUNTIME_STATE_MISMATCH'
        $mm = New-TcResult -Success $false -ErrorCode 'RUNTIME_STATE_MISMATCH' `
            -ErrorMessage "PLC state on ADS port $($data.adsPort) is '$($data.plcState)' after Enable-TcConfig -Force, expected 'Run'." `
            -Hint 'Report data.steps to the user; do not retry through another channel. Check the EnableConfig step result (data.finalCheck, data.plcs) and Get-TcIdeModalDialog; with several PLC projects pass -PlcProjectPath / -AdsPort for the PLC you need.'
        return (& $finish $step $mm.error)
    }

    $data.steps = $steps.ToArray()
    New-TcResult -Success $true -Data $data
}
